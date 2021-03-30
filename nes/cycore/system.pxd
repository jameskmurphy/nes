# cython: profile=True, boundscheck=True, nonecheck=False, language_level=3
from .ppu cimport NESPPU
from .apu cimport NESAPU
from .carts cimport NESCart
from .memory cimport NESMappedRAM
from .mos6502 cimport MOS6502

cdef enum:
    OAM_DMA = 1
    DMC_DMA = 2
    DMC_DMA_DURING_OAM_DMA = 3


cdef class InterruptListener:
    cdef bint _nmi, _irq
    cdef int dma_pause, dma_pause_count

    cdef void raise_nmi(self)
    cdef void reset_nmi(self)
    cdef void raise_irq(self)
    cdef void reset_irq(self)
    cdef void reset_dma_pause(self)
    cdef void raise_dma_pause(self, int type)
    cdef int any_active(self)
    cdef int nmi_active(self)
    cdef int irq_active(self)


cdef enum:
    PPU_CYCLES_PER_CPU_CYCLE = 3
    TARGET_AUDIO_BUFFER_SAMPLES = 2400   # increase this if you get frequent audio glitches, decrease if sound is laggy
    AUDIO_CHUNK_SAMPLES = 400         # how many audio samples go over in each chunk, a frame has 800 samples at 48kHz
    MAX_RATE_DELTA = 3000               # maximum deviation of sample rate +/- from target rate when adaptive
    TARGET_FPS = 60                   # system's target framerate (NTSC)

    # sync modes that are available, each with advantages and disadvantages
    SYNC_NONE = 0      # no sync: runs very fast, unplayable, music is choppy
    SYNC_AUDIO = 1     # sync to audio: rate is perfect, can glitch sometimes, screen tearing can be bad
    SYNC_PYGAME = 2    # sync to pygame's clock, adaptive audio: generally reliable, some screen tearing
    SYNC_VSYNC = 3     # sync to external vsync, adaptive audio: requires ~60Hz vsync, no tearing


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

        int screen_scale, sync_mode
        bint v_overscan, h_overscan

    cdef int step(self, int log_cpu)
    cpdef void run(self)
    cpdef object run_frame_headless(self, int run_frames=?, object controller1_state=?, object controller2_state=?)
