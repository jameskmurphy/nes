from .ppu cimport NESPPU
from .carts cimport NESCart0



DEF OAM_SIZE_BYTES = 256   # todo: should move to a header because is shared with PPU

DEF RAM_SIZE = 0x800            # 2kB of internal RAM
DEF NUM_PPU_REGISTERS = 8       # number of ppu registers

DEF RAM_END = 0x0800            # NES main ram to here
DEF PPU_END = 0x4000            # PPU registers to here
DEF APU_END = 0x4018            # APU registers (+OAM DMA reg) to here
DEF APU_UNUSED_END = 0x4020     # generally unused APU and I/O functionality
DEF OAM_DMA = 0x4014            # OAM DMA register address
DEF CONTROLLER1 = 0x4016        # port for controller (read controller 1 / write both controllers)
DEF CONTROLLER2 = 0x4017        # port for controller 2 (read only, writes to this port go to the APU)
DEF CART_START = 0x4020         # start of cartridge address space


cdef class MemoryBase:
    cpdef unsigned char read(self, int address)
    cpdef void write(self, int address, unsigned char value)


cdef class NESMappedRAM(MemoryBase):
    cdef unsigned char ram[RAM_SIZE]
    cdef unsigned char _last_bus
    cdef NESPPU ppu
    cdef object apu, controller1, controller2, interrupt_listener
    cdef NESCart0 cart

    cpdef unsigned char read(self, int address)
    cpdef void write(self, int address, unsigned char value)
    cdef void run_oam_dma(self, int page)

DEF PATTERN_TABLE_SIZE_BYTES = 4096   # provided by the rom
DEF NAMETABLES_SIZE_BYTES = 2048
DEF PALETTE_SIZE_BYTES = 32
DEF NAMETABLE_LENGTH_BYTES = 1024  # single nametime is this big

# memory map
DEF NAMETABLE_START = 0x2000
DEF ATTRIBUTE_TABLE_OFFSET = 0x3C0  # offset of the attribute table from the start of the corresponding nametable
DEF PALETTE_START = 0x3F00

# Mirror patterns
# The mirror pattern specifies the underlying nametable at locations 0x2000, 0x2400, 0x2800 and 0x3200
DEF MIRROR_HORIZONTAL = [0, 0, 1, 1]
DEF MIRROR_VERTICAL = [0, 1, 0, 1]
DEF MIRROR_FOUR_SCREEN = [0, 1, 2, 3]


cdef class NESVRAM(MemoryBase):
    cdef unsigned char _nametables[NAMETABLES_SIZE_BYTES]
    cdef unsigned char palette_ram[PALETTE_SIZE_BYTES]
    cdef NESCart0 cart
    cdef int nametable_mirror_pattern[4]

    cpdef unsigned char read(self, int address)
    cpdef void write(self, int address, unsigned char value)