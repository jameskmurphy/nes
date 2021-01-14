import logging

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
    CART_START = 0x4020         # start of cartridge address space

    def __init__(self, ppu=None, apu=None, cart=None):
        super().__init__()
        self.ram = bytearray(self.RAM_SIZE)  # 2kb of internal RAM
        self.ppu = ppu
        self.apu = apu
        self.cart = cart

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

        logging.debug("read {:04X}  (= {:02X})  region={:10s}".format(address, value, region), extra={"source": "mem"})

        return value

    def write(self, address, value):
        """
        Write one byte of memory in the NES address space
        """
        logging.debug("write {:02X} --> {:04X}".format(value, address), extra={"source": "mem"})

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
        logging.debug("OAM DMA from page {:02X}".format(page), extra={"source": "mem"})
        self.ppu.oam[0:self.ppu.OAM_SIZE_BYTES] = self.read_block(page << 8, self.ppu.OAM_SIZE_BYTES)
        # todo: this should cause the CPU to suspend for 513 or 514 cycles


class NESVRAM(MemoryBase):
    """
    NES video (PPU) RAM, following the PPU memory map pattern

    References:
        [1] PPU memory map: https://wiki.nesdev.com/w/index.php/PPU_memory_map
    """

    PATTERN_TABLE_SIZE_BYTES = 4096   # provided by the rom
    NAMETABLES_SIZE_BYTES = 2048
    PALETTE_SIZE_BYTES = 32
    NAMETABLE_LENGTH_BYTES = 1024  # single nametime is this big   #todo: this name is misleading; is really length of a single nametable in bytes

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
        logging.debug("read {:04X} [{:04X}]  (= {:02X})".format(address, address_decoded, value), extra={"source": "vram"})
        return value

    def write(self, address, value):
        logging.debug("write {:02X} --> {:04X}".format(value, address), extra={"source": "vram"})
        memory, address = self.decode_address(address)
        memory[address] = value

"""
    def readX(self, address):
        if address < self.NAMETABLE_START:
            # pattern table
            return self.pattern_table[address]
        elif address < self.PALETTE_START:
            # nametable
            page = int((address - self.NAMETABLE_START) / self.NAMETABLE_WIDTH)  # which nametable?
            offset = (address - self.NAMETABLE_START) % self.NAMETABLE_WIDTH     # offset in that table

            # some of the pages (e.g. 2 and 3) are mirrored, so for these, find the underlying
            # namepage that they point to based on the mirror pattern
            true_page = self.nametable_mirror_pattern[page]
            return self.nametables[true_page * self.NAMETABLE_WIDTH + offset]
        else:
            # palette table
            return self.palette_ram[address % self.PALETTE_SIZE_BYTES]

    def writeX(self, address, value):
        if address < self.NAMETABLE_START:
            # pattern table
            self.pattern_table[address] = value
        elif address < self.PALETTE_START:
            # nametable
            page = int((address - self.NAMETABLE_START) / self.NAMETABLE_WIDTH)  # which nametable?
            offset = (address - self.NAMETABLE_START) % self.NAMETABLE_WIDTH  # offset in that table

            # some of the pages (e.g. 2 and 3) are mirrored, so for these, find the underlying
            # namepage that they point to based on the mirror pattern
            true_page = self.nametable_mirror_pattern[page]
            self.nametables[true_page * self.NAMETABLE_WIDTH + offset] = value
        else:
            # palette table
            self.palette_ram[address % self.PALETTE_SIZE_BYTES] = value
"""


"""
class MemoryMappedRAM(MemoryBase):
    def __init__(self):
        super().__init__()
        pass

    def decode_address(self, address):
        raise NotImplementedError()

    def read(self, address):
        memory_area, address = self.decode_address(address)
        return memory_area[address]

    def write(self, address, value):
        memory_area, address = self.decode_address(address)
        memory_area[address] = value
"""
