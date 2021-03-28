# cython: profile=True, boundscheck=True, nonecheck=False, language_level=3
import pyximport; pyximport.install()


from .ppu cimport NESPPU
from .carts cimport NESCart
from .system cimport InterruptListener
from .apu cimport NESAPU


######## memory base ##################################################

cdef class MemoryBase:
    cdef unsigned char read(self, int address)
    cdef void write(self, int address, unsigned char value)


######## NES Main Memoroy #############################################

cpdef enum:
    RAM_SIZE = 2048             # 2kB of internal RAM

    # NES Main Memory locations
    RAM_END = 0x2000            # NES main ram to here  (2kb mirrored 4x)
    PPU_END = 0x4000            # PPU registers to here
    APU_END = 0x4018            # APU registers (+OAM DMA reg and controllers) to here
    APU_UNUSED_END = 0x4020     # generally unused APU and I/O functionality
    OAM_DMA_REG = 0x4014        # OAM DMA register address
    CONTROLLER1 = 0x4016        # port for controller (read controller 1 / write both controllers)
    CONTROLLER2 = 0x4017        # port for controller 2 (read only, writes to this port go to the APU)
    CART_START = 0x4020         # start of cartridge address space


cdef class NESMappedRAM(MemoryBase):
    cdef unsigned char ram[RAM_SIZE]
    cdef unsigned char _last_bus
    cdef NESPPU ppu
    cdef NESAPU apu
    cdef NESCart cart
    cdef InterruptListener interrupt_listener
    cdef object controller1, controller2

    ###### functions ##########################
    cdef unsigned char read(self, int address)
    cdef void write(self, int address, unsigned char value)

    cdef void run_oam_dma(self, int page)


######## NES VRAM #####################################################

cdef enum:
    PATTERN_TABLE_SIZE_BYTES = 4096   # provided by the rom

    # the NES VRAM only has 2kb for nametables, but some carts provide for up to 4kb using fixed four-page nametable
    # mirroring.  If we provide enough space for that here, using a mirror pattern of [0, 1, 2, 3] will produce the four
    # page mirroring, and the other mirroring patterns will work as intended, since the addresses will just map to pages
    # 0 and 1 as specified by the mirror pattern supplied by the cartridge.
    XX_NAMETABLES_SIZE_BYTES = 4096
    PALETTE_SIZE_BYTES = 32
    NAMETABLE_LENGTH_BYTES = 1024  # single nametime is this big

    # memory map
    PALETTE_START = 0x3F00
    NAMETABLE_START = 0x2000
    ATTRIBUTE_TABLE_OFFSET = 0x3C0  # offset of the attribute table from the start of the corresponding nametable

cdef class NESVRAM(MemoryBase):
    cdef unsigned char _nametables[XX_NAMETABLES_SIZE_BYTES]
    cdef unsigned char palette_ram[PALETTE_SIZE_BYTES]
    cdef NESCart cart
    cdef int nametable_mirror_pattern[4]

    ###### functions ##########################
    cdef unsigned char read(self, int address)
    cdef void write(self, int address, unsigned char value)
