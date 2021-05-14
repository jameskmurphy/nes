import logging

#from nes import LOG_MEMORY


OAM_SIZE_BYTES = 256


class MemoryBase:
    """
    Basic memory controller interface
    """
    def __init__(self):
        pass

    def read(self, address):
        raise NotImplementedError()

    def read_block(self, address, bytes):
        rval = bytearray(bytes)
        for i in range(bytes):
            rval[i] = self.read(address + i)
        return rval

    def write(self, address, value):
        raise NotImplementedError()

    def print(self, address, bytes, width_bytes=16):
        for off in range(bytes):
            if off % width_bytes == 0:
                if off > 0:
                    print()
                print("${0:04X}:   ".format(address + off), end="")
            v = self.read(address + off)
            print("{0:02X}".format(v), end=" ")


class BigEmptyRAM(MemoryBase):
    """
    Just a big empty bank of 64kB of RAM
    """
    def __init__(self):
        super().__init__()
        self.ram = bytearray(2 ** 16)

    def read(self, address):
        return self.ram[address]

    def read_block(self, address, bytes):
        # this is so simple, we can do a more efficient read_block
        return self.ram[address:(address + bytes)]

    def write(self, address, value):
        self.ram[address] = value


class NESMappedRAM(MemoryBase):
    """
    NES memory following NES CPU memory map pattern

    References:
        [1] CPU memory map:  https://wiki.nesdev.com/w/index.php/CPU_memory_map
    """
    RAM_SIZE = 0x800            # 2kB of internal RAM
    NUM_PPU_REGISTERS = 8       # number of ppu registers

    RAM_END = 0x0800            # NES main ram to here
    PPU_END = 0x4000            # PPU registers to here
    APU_END = 0x4018            # APU registers (+OAM DMA reg) to here
    APU_UNUSED_END = 0x4020     # generally unused APU and I/O functionality
    OAM_DMA = 0x4014            # OAM DMA register address
    CONTROLLER1 = 0x4016        # port for controller (read controller 1 / write both controllers)
    CONTROLLER2 = 0x4017        # port for controller 2 (read only, writes to this port go to the APU)
    CART_START = 0x4020         # start of cartridge address space

    def __init__(self, ppu=None, apu=None, cart=None, controller1=None, controller2=None, interrupt_listener=None):
        super().__init__()
        self.ram = bytearray(self.RAM_SIZE)  # 2kb of internal RAM
        self.ppu = ppu
        self.apu = apu
        self.cart = cart
        self.controller1 = controller1
        self.controller2 = controller2
        self.interrupt_listener = interrupt_listener

        # internal variable used for open bus behaviour
        self._last_bus = 0

    def read(self, address):
        """
        Read one byte of memory from the NES address space
        """
        if address < self.RAM_END:    # RAM and its mirrors
            region = "ram"
            value = self.ram[address % self.RAM_SIZE]
        elif address < self.PPU_END:  # PPU registers
            region = "ppu"
            register_ix = address % self.NUM_PPU_REGISTERS
            if self.ppu is not None:
                value = self.ppu.read_register(register_ix)
            else:
                value = 0
        elif address < self.APU_END:
            region = "apu/oam"
            if address == self.OAM_DMA and self.ppu:
                # write only
                value = 0
            elif address == self.CONTROLLER1:
                value = (self.controller1.read_bit() & 0b00011111) + (0x40 & 0b11100000)
                #print("{:08b}".format(value))
                #print("{:08b}".format(self._last_bus))
                # todo: deal with open bus behaviour of upper control lines
            elif address == self.CONTROLLER2:
                # todo: deal with open bus behaviour of upper control lines
                value = (self.controller2.read_bit() & 0b00011111) + (0x40 & 0b11100000)
            else:
                # todo: APU registers
                value = 0
        elif address < self.APU_UNUSED_END:
            # todo: generally unused APU and I/O functionality
            region = "apu-unused"
            value = 0
        else:
            # cartridge space; pass this to the cart, which might do its own mapping
            region = "cart"
            value = self.cart.read(address)

        #logging.log(LOG_MEMORY, "read {:04X}  (= {:02X})  region={:10s}".format(address, value, region), extra={"source": "mem"})
        return value

    def write(self, address, value):
        """
        Write one byte of memory in the NES address space
        """
        #logging.log(LOG_MEMORY, "write {:02X} --> {:04X}".format(value, address), extra={"source": "mem"})

        if address < self.RAM_END:    # RAM and its mirrors
            self.ram[address % self.RAM_SIZE] = value
        elif address < self.PPU_END:  # PPU registers
            register_ix = address % self.NUM_PPU_REGISTERS
            if self.ppu:
                self.ppu.write_register(register_ix, value)
        elif address < self.APU_END:
            if address == self.OAM_DMA:
                if self.ppu:
                    self.run_oam_dma(value)
            elif address == self.CONTROLLER1:
                self.controller1.set_strobe(value)
                self.controller2.set_strobe(value)
            else:
                # todo: APU registers
                pass
        elif address < self.APU_UNUSED_END:
            # todo: generally unused APU and I/O functionality
            pass
        else:
            # cartridge space; pass this to the cart, which might do its own mapping
            self.cart.write(address, value)

    def run_oam_dma(self, page):
        """
        OAM DMA copies an entire page (wrapping at the page boundary if the start address in ppu's oam_addr is not zero)
        from RAM to ppu OAM.  This also causes the cpu to pause for 513 or 514 cycles.
        :param page:
        :return:
        """
        logging.debug("OAM DMA from page {:02X}".format(page), extra={"source": "mem"})
        # done in two parts to correctly account for wrapping at page end
        data_block = bytearray(256)
        data_block[self.ppu.oam_addr:OAM_SIZE_BYTES] = self.read_block(page << 8, OAM_SIZE_BYTES - self.ppu.oam_addr)
        data_block[0:self.ppu.oam_addr] = self.read_block(page << 8, self.ppu.oam_addr)
        self.ppu.write_oam(data_block)

        #self.ppu.oam[self.ppu.oam_addr:OAM_SIZE_BYTES] = self.read_block(page << 8, OAM_SIZE_BYTES - self.ppu.oam_addr)
        #self.ppu.oam[0:self.ppu.oam_addr] = self.read_block(page << 8, self.ppu.oam_addr)
        # tell the interrupt listener that the CPU should pause due to OAM DMA
        self.interrupt_listener.raise_oam_dma_pause()


class NESVRAM(MemoryBase):
    """
    NES video (PPU) RAM, following the PPU memory map pattern

    References:
        [1] PPU memory map: https://wiki.nesdev.com/w/index.php/PPU_memory_map
    """
    PATTERN_TABLE_SIZE_BYTES = 4096   # provided by the rom
    NAMETABLES_SIZE_BYTES = 2048
    PALETTE_SIZE_BYTES = 32
    NAMETABLE_LENGTH_BYTES = 1024  # single nametime is this big

    # memory map
    NAMETABLE_START = 0x2000
    ATTRIBUTE_TABLE_OFFSET = 0x3C0  # offset of the attribute table from the start of the corresponding nametable
    PALETTE_START = 0x3F00

    # Mirror patterns
    # The mirror pattern specifies the underlying nametable at locations 0x2000, 0x2400, 0x2800 and 0x3200
    MIRROR_HORIZONTAL = (0, 0, 1, 1)
    MIRROR_VERTICAL = (0, 1, 0, 1)
    #MIRROR_SINGLE = (0, 0, 0, 0)
    MIRROR_FOUR_SCREEN = (0, 1, 2, 3)
    #MIRROR_DIAGONAL = (0, 1, 1, 0)
    #MIRROR_L_SHAPED = (0, 1, 1, 1)
    #MIRROR_3_SCREEN_V = (0, 2, 1, 2)
    #MIRROR_3_SCREEN_H = (0, 1, 2, 2)
    #MIRROR_3_SCREEN_DIAG = (0, 1, 1, 2)

    def __init__(self, cart, nametable_size_bytes=2048):
        super().__init__()
        self.cart = cart
        # self._pattern_table = bytearray(self.PATTERN_TABLE_SIZE_BYTES)
        self._nametables = bytearray(nametable_size_bytes)
        self.palette_ram = bytearray(self.PALETTE_SIZE_BYTES)
        self.nametable_mirror_pattern = cart.nametable_mirror_pattern

    def decode_address(self, address):
        if address < self.NAMETABLE_START:
            # pattern table - provided by the rom
            #return self._pattern_table, address
            return self.cart.chr_mem, address % len(self.cart.chr_mem)  # todo: need something better here via the read_ppu/wrtie_ppu in order to implement mappers
        elif address < self.PALETTE_START:
            # nametable
            page = int((address - self.NAMETABLE_START) / self.NAMETABLE_LENGTH_BYTES)  # which nametable?
            offset = (address - self.NAMETABLE_START) % self.NAMETABLE_LENGTH_BYTES  # offset in that table

            # some of the pages (e.g. 2 and 3) are mirrored, so for these, find the underlying
            # namepage that they point to based on the mirror pattern
            true_page = self.nametable_mirror_pattern[page]
            return self._nametables, true_page * self.NAMETABLE_LENGTH_BYTES + offset
        else:
            # palette table
            if address == 0x3F10 or address == 0x3F14 or address == 0x3F18 or address == 0x3F1C:
                # "addresses $3F10/$3F14/$3F18/$3F1C are mirrors of $3F00/$3F04/$3F08/$3F0C"
                # (https://wiki.nesdev.com/w/index.php/PPU_palettes)
                address -= 0x10
            return self.palette_ram, address % self.PALETTE_SIZE_BYTES

    def read(self, address):
        memory, address_decoded = self.decode_address(address)
        value = memory[address_decoded]
        #logging.log(LOG_MEMORY, "read {:04X} [{:04X}]  (= {:02X})".format(address, address_decoded, value), extra={"source": "vram"})
        return value

    def write(self, address, value):
        #logging.log(LOG_MEMORY, "write {:02X} --> {:04X}".format(value, address), extra={"source": "vram"})
        memory, address = self.decode_address(address)
        memory[address] = value
