"""
Cython declarations for the NES cartridges
"""
from .system cimport InterruptListener   # used by MMC3 to generate IRQs


cdef enum:
    BYTES_PER_KB = 1024

cdef enum:
    # cart memory map - note that some memory is connected to CPU bus, others to PPU bus
    RAM_START = 0x6000      # address in the CPU memory space
    PRG_ROM_START = 0x8000  # address in the CPU memory space
    CHR_ROM_START = 0x0000  # address in the PPU memory space


cdef class NESCart:
    """
    NES Cartridge interface
    """
    cdef int nametable_mirror_pattern[4]

    cdef unsigned char read(self, int address)
    cdef void write(self, int address, unsigned char value)
    cdef unsigned char read_ppu(self, int address)
    cdef void write_ppu(self, int address, unsigned char value)

    cdef void irq_tick(self)


### Mapper 0 (aka NROM) ################################################################################################

# would be nicer to have these in a named enum, but that seems to generate Cython compile error "Array dimension not
# integer", so it's not clear what that is ending up doing.  For now, just name the constants with the mapper number.
cdef enum:
    # maximum memory sizes; these are allocated but might not all be used (but are so small it doesn't matter)
    M0_MAX_CART_RAM_SIZE = 8 * BYTES_PER_KB   # up to 8kB of RAM
    M0_MAX_PRG_ROM_SIZE = 32 * BYTES_PER_KB   # up to 32kB of program ROM
    M0_CHR_MEM_SIZE = 8 * BYTES_PER_KB        # always (?) 8kB of chr memory (can be RAM or always ROM?)


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


### Mapper 1 (aka MMC1, SxROM) #########################################################################################
# ref: https://wiki.nesdev.com/w/index.php/MMC1

cdef enum:
    # maximum memory sizes; these are allocated but might not all be used (but are so small it doesn't matter)
    M1_PRG_RAM_BANK_SIZE = 8 * BYTES_PER_KB    # 8kB RAM banks (can be zero of these)
    M1_MAX_PRG_RAM_BANKS = 4                   # can have up to 4 x 8kb RAM banks, but only on SXROM
    M1_PRG_ROM_BANK_SIZE = 16 * BYTES_PER_KB   # Each bank is 16kB of program ROM
    M1_MAX_PRG_BANKS = 16                      # up to 256kB of program ROM (16x16kb) - 512kb MMC1 ROMs not supported
    M1_CHR_ROM_BANK_SIZE = 4 * BYTES_PER_KB    # chr rom in 4kB banks
    M1_MAX_CHR_BANKS = 32                      # up to 128kb of CHR rom in (up to 32 x 4kb)

    # main memory map (read)
    # 0x6000-0x7FFF 8kb PRG RAM
    # 0x8000-0xBFFF 16kb PRG ROM bank 0 (read only)
    # 0xC000-0xFFFF 16kb PRG ROM bank 1 (read only)
    M1_PRG_RAM_START = 0x6000
    M1_PRG_ROM_BANK0_START = 0x8000
    M1_PRG_ROM_BANK1_START = 0xC000

    # main memory map (write)
    # 0x8000-0xFFFF write only: write a bit to shift register; fifth write commits shift -> internal register, depending
    #                           on address of that fifth write only.
    # Fifth-write addresses:
    # 0x8000-0x9FFF control register
    # 0xA000-0xBFFF CHR bank 0 register
    # 0xC000-0xDFFF CHR bank 1 register
    # 0xE000-0xFFFF PRG bank register
    M1_CTRL_REG_START = 0x8000
    M1_CHR_REG_0_START = 0xA000
    M1_CHR_REG_1_START = 0xC000
    M1_PRG_REG_START = 0xE000

    # vram memory map
    # 0x0000-0x0FFF 4kb CHR ROM bank 0
    # 0x1000-0x1FFF 4kb CHR ROM bank 1
    M1_CHR_ROM_BANK0_START = 0x0000
    M1_CHR_ROM_BANK1_START = 0x1000


cdef class NESCart1(NESCart):
    cdef int num_prg_banks, num_chr_banks, num_prg_ram_banks   # number of available memory banks in this cart
    cdef bint chr_mem_writeable                 # whether or not CHR memory is writeable (i.e. RAM)
    cdef unsigned char ctrl                     # control register
    cdef unsigned char chr_bank[2]              # active chr rom banks
    cdef unsigned char prg_bank, prg_ram_bank   # currently active prg rom/ram bank
    cdef unsigned char shift                    # internal shift register
    cdef int shift_ctr                          # which shift register bit we are currently on

    cdef unsigned char banked_prg_rom[M1_MAX_PRG_BANKS][M1_PRG_ROM_BANK_SIZE]
    cdef unsigned char banked_chr_rom[M1_MAX_CHR_BANKS][M1_CHR_ROM_BANK_SIZE]
    cdef unsigned char ram[M1_MAX_PRG_RAM_BANKS][M1_PRG_RAM_BANK_SIZE]

    cdef unsigned char read(self, int address)
    cdef void write(self, int address, unsigned char value)
    cdef unsigned char read_ppu(self, int address)
    cdef void write_ppu(self, int address, unsigned char value)

    cdef void _write_shift(self, int address, unsigned char value)
    cdef void _set_nametable_mirror_pattern(self)
    cdef int _get_chr_bank(self, int address)


### Mapper 2 (aka UNROM, UOROM) ########################################################################################
# ref: https://wiki.nesdev.com/w/index.php/UxROM

cdef enum:
    # maximum memory sizes; these are allocated but might not all be used (but are so small it doesn't matter)
    M2_MAX_PRG_BANKS = 16                      # Max number of banks; up to 8 in UNROM, up to 16 in UOROM
    M2_PRG_ROM_BANK_SIZE = 16 * BYTES_PER_KB   # Each bank is 16kB of program ROM

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
    cdef bint emulate_bus_conflicts   # whether or not to emulate bus conflicts

    cdef unsigned char read(self, int address)
    cdef void write(self, int address, unsigned char value)


### Mapper 4 (aka MMC3) ########################################################################################
# ref: https://wiki.nesdev.com/w/index.php/MMC3

cdef enum:
    M4_PRG_RAM_SIZE = 8 * BYTES_PER_KB
    M4_PRG_ROM_BANK_SIZE = 8 * BYTES_PER_KB
    M4_CHR_ROM_BANK_SIZE = 1 * BYTES_PER_KB

    M4_MAX_PRG_BANKS = 64
    M4_MAX_CHR_BANKS = 256

    # Main memory map
    M4_PRG_RAM_START = 0x6000
    M4_PRG_ROM_START = 0x8000

    # Registers
    # All these register ranges have two purposes, depending on whether it is an even or odd address
    BANK_REG_START = 0x8000              # even -> bank select, odd -> bank data
    MIRROR_PROTECT_REG_START = 0xA000    # even -> mirroring, odd -> ram protect
    IRQ_LATCH_RELOAD_REG_START = 0xC000  # even -> irq latch, odd -> irq reload
    IRQ_ACTIVATE_START = 0xE000          # even -> irq disable, odd -> irq enable


cdef class NESCart4(NESCart):
    cdef InterruptListener interrupt_listener
    cdef int num_prg_banks, num_chr_banks       # number of available memory banks in this cart
    cdef bint chr_mem_writeable                 # whether or not CHR memory is writeable (i.e. RAM)
    cdef unsigned char bank_register[8]         # bank registers (both chr and prg)

    cdef bint chr_a12_inversion, prg_bank_mode  # mode selectors that determine how bank switching works
    cdef unsigned char bank_select              # determines which bank register to update on next write to bank_data
    cdef bint prg_ram_enable, prg_ram_protect   # prg ram protection flags
    cdef bint mirror_pattern_fixed              # whether the mirror pattern is hard-wired or can be adjusted

    cdef unsigned char irq_reload_value         # the value loaded into the irq latch on reload
    cdef bint irq_reload                        # reload irq counter to reload value at next tick
    cdef bint irq_enabled                       # irq enabled or not?
    cdef int irq_counter                        # counter used to count down to IRQ trigger

    cdef unsigned char banked_prg_rom[M4_MAX_PRG_BANKS][M4_PRG_ROM_BANK_SIZE]
    cdef unsigned char banked_chr_rom[M4_MAX_CHR_BANKS][M4_CHR_ROM_BANK_SIZE]
    cdef unsigned char ram[M4_PRG_RAM_SIZE]

    cdef unsigned char read(self, int address)
    cdef void write(self, int address, unsigned char value)
    cdef unsigned int _get_ppu_bank(self, int address)
    cdef unsigned char read_ppu(self, int address)
    cdef void write_ppu(self, int address, unsigned char value)
    cdef void irq_tick(self)
