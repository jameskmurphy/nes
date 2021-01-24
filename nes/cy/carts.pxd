from .memory cimport MemoryBase

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
    cdef unsigned char ram[CART_RAM_SIZE]
    cdef unsigned char prg_rom[PRG_ROM_SIZE]
    cdef unsigned char chr_mem[CHR_MEM_SIZE]
    cdef int prg_start_addr
    cpdef int nametable_mirror_pattern[4]

    cpdef unsigned char read(self, int address)
    cpdef void write(self, int address, unsigned char value)
    cpdef unsigned char read_ppu(self, int address)
    cpdef void write_ppu(self, int address, unsigned char value)


