"""
Cython declarations for the NES cartridges
"""

cdef enum:
    # cart memory map - note that some memory is connected to CPU bus, others to PPU bus
    RAM_START = 0x6000      # address in the CPU memory space
    PRG_ROM_START = 0x8000  # address in the CPU memory space
    CHR_ROM_START = 0x0000  # address in the PPU memory space


cdef class NESCart:
    """
    NES Cartridge interface
    """
    cpdef int nametable_mirror_pattern[4]

    cdef unsigned char read(self, int address)
    cdef void write(self, int address, unsigned char value)
    cdef unsigned char read_ppu(self, int address)
    cdef void write_ppu(self, int address, unsigned char value)


### Mapper 000 (aka NROM) ##############################################################################################

# would be nicer to have these in a named enum, but that seems to generate Cython compile error "Array dimension not
# integer", so it's not clear what that is ending up doing.  For now, just name the constants with the mapper number.
cdef enum:
    # maximum memory sizes; these are allocated but might not all be used (but are so small it doesn't matter)
    M0_MAX_CART_RAM_SIZE = 8 * 1024   # up to 8kB of RAM
    M0_MAX_PRG_ROM_SIZE = 32 * 1024   # up to 32kB of programme ROM
    M0_CHR_MEM_SIZE = 8 * 1024        # always (?) 8kB of chr memory (can be RAM or always ROM?)


cdef class NESCart0(NESCart):
    """
    Basic NES Cartridge (Type 0 / MMC0).  Consists of up to 8kB RAM, 32kB PRG ROM, 8kB CHR ROM
    """
    cdef unsigned char ram[M0_MAX_CART_RAM_SIZE]
    cdef unsigned char prg_rom[M0_MAX_PRG_ROM_SIZE]
    cdef unsigned char chr_mem[M0_CHR_MEM_SIZE]
    cdef int prg_start_addr, prg_rom_size, ram_size, chr_mem_writeable, prg_rom_writeable     # cart metadata

    cdef unsigned char read(self, int address)
    cdef void write(self, int address, unsigned char value)
    cdef unsigned char read_ppu(self, int address)
    cdef void write_ppu(self, int address, unsigned char value)


