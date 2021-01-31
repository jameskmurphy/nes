from .ppu cimport NESPPU
from .apu cimport NESAPU
from .carts cimport NESCart
from .memory cimport NESMappedRAM
from .mos6502 cimport MOS6502


cdef class InterruptListener:
    cdef int _nmi, _irq, oam_dma_pause

    cdef void raise_nmi(self)
    cdef void reset_nmi(self)
    cdef void raise_irq(self)
    cdef void reset_irq(self)
    cdef void reset_oam_dma_pause(self)
    cdef void raise_oam_dma_pause(self)
    cdef int any_active(self)
    cdef int nmi_active(self)
    cdef int irq_active(self)


cdef enum:
    PPU_CYCLES_PER_CPU_CYCLE = 3


cdef class NES:

    cdef:
        NESPPU ppu
        NESAPU apu
        NESCart cart
        MOS6502 cpu
        NESMappedRAM memory
        InterruptListener interrupt_listener

        object controller1, controller2
        object screen

        int screen_scale

    cdef int step(self, int log_cpu)
    cpdef void run(self)
