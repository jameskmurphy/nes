
cdef enum:
    # memory sizes (these eventually need to not be fixed)
    CART_RAM_SIZE = 8192
    PRG_ROM_SIZE = 32 * 1024
    CHR_MEM_SIZE = 8192

    # cart memory map
    RAM_START = 0x6000
    PRG_ROM_START = 0x8000
    CHR_ROM_START = 0x0000


cdef class NESCart0:
    """
    Basic NES Cartridge (Type 0 / MMC0).  Consists of up to 8kB RAM, 32kB PRG ROM, 8kB CHR ROM
    """
    cdef unsigned char ram[CART_RAM_SIZE]
    cdef unsigned char prg_rom[PRG_ROM_SIZE]
    cdef unsigned char chr_mem[CHR_MEM_SIZE]
    cdef int prg_start_addr, prg_rom_size
    cpdef int nametable_mirror_pattern[4]

    cpdef unsigned char read(self, int address)
    cpdef void write(self, int address, unsigned char value)
    cpdef unsigned char read_ppu(self, int address)
    cpdef void write_ppu(self, int address, unsigned char value)


