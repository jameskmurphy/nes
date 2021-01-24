# cython: profile=True, boundscheck=False, nonecheck=False

from nes.cy.memory cimport MemoryBase

    # CPU memory space
DEF    RAM_START = 0x6000
DEF    PRG_ROM_START = 0x8000

    # PPU memory space
DEF    CHR_ROM_START = 0x0000


DEF CART_RAM_SIZE = 8192
DEF PRG_ROM_SIZE = 32 * 1024
DEF CHR_MEM_SIZE = 8192


cdef class NESCart0:
    """
    Basic NES Cartridge (Type 0 / MMC0).  Consists of up to 8kB RAM, 32kB PRG ROM, 8kB CHR ROM
    """
    def __init__(self, prg_rom_data=None, chr_rom_data=None, ram_size_kb=8, prg_start_addr=None, nametable_mirror_pattern=[0,0,1,1]):
        super().__init__()

        # initialize ram (CPU connected)
        if ram_size_kb not in [2, 4, 8]:
            raise ValueError("Cart 0 ram size should be 2, 4 or 8kB")
        #self.ram = bytearray(ram_size_kb * 1024)

        # initialize prg rom from supplied data  (CPU connected)
        for i in range(len(prg_rom_data)):
            self.prg_rom[i] = prg_rom_data[i]


        #if len(self.prg_rom) not in [16 * 1024, 32 * 1024]:
        #    raise ValueError("Cart 0 prg rom size should be 16 or 32kB")

        # initialize chr rom from supplied data  (PPU connected)
        # or create ram if there isn't one
        if chr_rom_data:

            for i in range(len(chr_rom_data)):
                self.chr_mem[i] = chr_rom_data[i]


            #self.chr_mem = bytearray(chr_rom_data)


            #if len(self.chr_mem) != 8 * 1024:
            #    raise ValueError("Cart 0 chr rom size should be 8kB")
            pass
        else:
            pass
            #self.chr_mem = bytearray(8 * 1024)   # make a RAM

        self.prg_start_addr = PRG_ROM_START#prg_start_addr if prg_start_addr else PRG_ROM_START
        self.nametable_mirror_pattern = nametable_mirror_pattern
        #rom_data_start = load_rom_at - self.PRG_ROM_START
        #self.rom[rom_data_start:rom_data_start + len(rom_data)] = rom_data

    cpdef unsigned char read(self, int address):
        if address < PRG_ROM_START:
            # ram access
            return self.ram[address % CART_RAM_SIZE]
        else:
            return self.prg_rom[(address - self.prg_start_addr) % PRG_ROM_SIZE]

    cpdef void write(self, int address, unsigned char value):
        if address < PRG_ROM_START:
            # ram access
            self.ram[address % CART_RAM_SIZE] = value
        else:
            # should not be able to write to ROM, write here has no effect
            print("WARNING: OVERWRITING PRG ROM")
            self.prg_rom[(address - self.prg_start_addr) % PRG_ROM_SIZE] = value

    cpdef unsigned char read_ppu(self, int address):
        return self.chr_mem[address % CHR_MEM_SIZE]

    cpdef void write_ppu(self, int address, unsigned char value):
        print("WARNING: OVERWRITING CHR ROM")
        self.chr_mem[address % CHR_MEM_SIZE] = value

    @property
    def nametable_mirror_pattern(self):
        return self.nametable_mirror_pattern