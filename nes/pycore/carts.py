from .memory import MemoryBase

class CartBase(MemoryBase):
    """
    Cartridges can provide memory (with separate address spaces) to the CPU and the PPU.
    To accommodate this, additional read_ppu and write_ppu methods provide access to the PPU-linked memory.
    """

    def __init__(self):
        super().__init__()
        self.nametable_mirror_pattern=None

    def read_ppu(self, address):
        raise NotImplementedError()

    def write_ppu(self, address, v):
        raise NotImplementedError()



class NESCart0(CartBase):
    """
    Basic NES Cartridge (Type 0 / MMC0).  Consists of up to 8kB RAM, 32kB PRG ROM, 8kB CHR ROM
    """
    # CPU memory space
    RAM_START = 0x6000
    PRG_ROM_START = 0x8000

    # PPU memory space
    CHR_ROM_START = 0x0000

    def __init__(self, prg_rom_data=None, chr_rom_data=None, ram_size_kb=8, prg_start_addr=None, nametable_mirror_pattern=(0,0,1,1)):
        super().__init__()

        # initialize ram (CPU connected)
        if ram_size_kb not in [2, 4, 8]:
            raise ValueError("Cart 0 ram size should be 2, 4 or 8kB")
        self.ram = bytearray(ram_size_kb * 1024)

        # initialize prg rom from supplied data  (CPU connected)
        self.prg_rom = bytearray(prg_rom_data)

        if len(self.prg_rom) not in [16 * 1024, 32 * 1024]:
            raise ValueError("Cart 0 prg rom size should be 16 or 32kB")

        # initialize chr rom from supplied data  (PPU connected)
        # or create ram if there isn't one
        if chr_rom_data:
            self.chr_mem = bytearray(chr_rom_data)
            if len(self.chr_mem) != 8 * 1024:
                raise ValueError("Cart 0 chr rom size should be 8kB")
        else:
            self.chr_mem = bytearray(8 * 1024)   # make a RAM

        self.prg_start_addr = prg_start_addr if prg_start_addr else self.PRG_ROM_START
        self.nametable_mirror_pattern = nametable_mirror_pattern
        #rom_data_start = load_rom_at - self.PRG_ROM_START
        #self.rom[rom_data_start:rom_data_start + len(rom_data)] = rom_data

    def read(self, address):
        if address < self.PRG_ROM_START:
            # ram access
            return self.ram[address % len(self.ram)]
        else:
            return self.prg_rom[(address - self.prg_start_addr) % len(self.prg_rom)]

    def write(self, address, value):
        if address < self.PRG_ROM_START:
            # ram access
            self.ram[address % len(self.ram)] = value
        else:
            # should not be able to write to ROM, write here has no effect
            print("WARNING: OVERWRITING PRG ROM")
            self.prg_rom[(address - self.prg_start_addr) % len(self.prg_rom)] = value

    def read_ppu(self, address):
        return self.chr_mem[address % len(self.chr_mem)]

    def write_ppu(self, address, value):
        print("WARNING: OVERWRITING CHR ROM")
        self.chr_mem[address % len(self.chr_mem)] = value
