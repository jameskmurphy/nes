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


### Mapper 0 (aka NROM) ################################################################################################

# would be nicer to have these in a named enum, but that seems to generate Cython compile error "Array dimension not
# integer", so it's not clear what that is ending up doing.  For now, just name the constants with the mapper number.
cdef enum:
    # maximum memory sizes; these are allocated but might not all be used (but are so small it doesn't matter)
    M0_MAX_CART_RAM_SIZE = 8 * 1024   # up to 8kB of RAM
    M0_MAX_PRG_ROM_SIZE = 32 * 1024   # up to 32kB of program ROM
    M0_CHR_MEM_SIZE = 8 * 1024        # always (?) 8kB of chr memory (can be RAM or always ROM?)


cdef class NESCart0(NESCart):
    """
    Basic NES Cartridge (Type 0 / MMC0)
    Consists of up to 8kB RAM, 32kB PRG ROM, 8kB CHR ROM
    """
    cdef unsigned char ram[M0_MAX_CART_RAM_SIZE]
    cdef unsigned char prg_rom[M0_MAX_PRG_ROM_SIZE]
    cdef unsigned char chr_mem[M0_CHR_MEM_SIZE]
    cdef int prg_start_addr, prg_rom_size, ram_size, chr_mem_writeable, prg_rom_writeable     # cart metadata

    cdef unsigned char read(self, int address)
    cdef void write(self, int address, unsigned char value)
    cdef unsigned char read_ppu(self, int address)
    cdef void write_ppu(self, int address, unsigned char value)


### Mapper 2 (aka UNROM, UOROM) ########################################################################################
# ref: https://wiki.nesdev.com/w/index.php/UxROM

cdef enum:
    # maximum memory sizes; these are allocated but might not all be used (but are so small it doesn't matter)
    M2_MAX_PRG_BANKS = 16              # Max number of banks; up to 8 in UNROM, up to 16 in UOROM
    M2_PRG_ROM_BANK_SIZE = 16 * 1024   # Each bank is 16kB of program ROM

    # memory map
    # 0x8000-0xBFFF:  banked prg_rom
    # 0xC000-0xFFFF:  a single 16kB prg_rom bank fixed to the last bank
    M2_FIXED_PRG_ROM_START = 0xC000


cdef class NESCart2(NESCart0):
    """
    NES Cartridge Type 2 (UNROM / UOROM)
    Much like Mapper 0 above, but has switchable banks of 16kB prg_rom
    """
    # Cython does not let us redefine attributes, so there are a few choices here:
    #   1) use a pointer and allocate memory at instantiation
    #   2) redefine the whole class without inheriting from NESCart0
    #   3) use a different name for prg_rom and waste the 32kB of memory in prg_rom of NESCart0
    # I opt for the third one here because the read and write functions are being rewritten anyway, and this way dynamic
    # memory allocation can be avoided, making the code simpler and safer.  And 32kB is not too much memory to waste.
    cdef unsigned char banked_prg_rom[M2_MAX_PRG_BANKS][M2_PRG_ROM_BANK_SIZE]
    cdef unsigned char prg_bank, num_prg_banks

    cdef unsigned char read(self, int address)
    cdef void write(self, int address, unsigned char value)


