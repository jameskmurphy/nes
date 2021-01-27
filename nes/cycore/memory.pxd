from .ppu cimport NESPPU
from .carts cimport NESCart

######## memory base ##################################################

cdef class MemoryBase:
    cpdef unsigned char read(self, int address)
    cpdef void write(self, int address, unsigned char value)


######## NES Main Memoroy #############################################

cdef enum:
    RAM_SIZE = 0x800            # 2kB of internal RAM

cdef class NESMappedRAM(MemoryBase):
    cdef unsigned char ram[RAM_SIZE]
    cdef unsigned char _last_bus
    cdef NESPPU ppu
    cdef object apu, controller1, controller2, interrupt_listener
    cdef NESCart cart

    ###### functions ##########################
    cpdef unsigned char read(self, int address)
    cpdef void write(self, int address, unsigned char value)

    cdef void run_oam_dma(self, int page)


######## NES VRAM #####################################################

cdef enum:
    PATTERN_TABLE_SIZE_BYTES = 4096   # provided by the rom
    NAMETABLES_SIZE_BYTES = 2048
    PALETTE_SIZE_BYTES = 32
    NAMETABLE_LENGTH_BYTES = 1024  # single nametime is this big

    # memory map
    PALETTE_START = 0x3F00
    NAMETABLE_START = 0x2000
    ATTRIBUTE_TABLE_OFFSET = 0x3C0  # offset of the attribute table from the start of the corresponding nametable

cdef class NESVRAM(MemoryBase):
    cdef unsigned char _nametables[NAMETABLES_SIZE_BYTES]
    cdef unsigned char palette_ram[PALETTE_SIZE_BYTES]
    cdef NESCart cart
    cdef int nametable_mirror_pattern[4]

    ###### functions ##########################
    cpdef unsigned char read(self, int address)
    cpdef void write(self, int address, unsigned char value)

    cdef _set_nametable_mirror_pattern(self)