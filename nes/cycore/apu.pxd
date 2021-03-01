from .system cimport InterruptListener
from .memory cimport NESMappedRAM

cdef enum:
    # sound synthesis constants
    SAMPLE_RATE = 48000     # 48kHz sample rate
    SAMPLE_SCALE = 65536    # 16 bit samples
    SAMPLE_OFFSET = 32768
    CPU_FREQ_HZ = 1789773   # https://wiki.nesdev.com/w/index.php/Cycle_reference_chart#Clock_rates
    MAX_CPU_CYCLES_PER_LOOP = 24  # if the cpu has done more than this many cycles, complete them in loops

    # control registers
    STATUS = 0x4015
    FRAME_COUNTER = 0x4017

    # counter modes
    FOUR_STEP = 0
    FIVE_STEP = 1

    # bits in the status register during read
    BIT_DMC_INTERRUPT = 7
    BIT_FRAME_INTERRUPT = 6
    BIT_DMC_ACTIVE = 4
    BIT_LENGTH_NOISE = 3
    BIT_LENGTH_TRIANGLE = 2
    BIT_LENGTH_PULSE2 = 1
    BIT_LENGTH_PULSE1 = 0

    # Bits in the status register during write
    BIT_ENABLE_DMC = 4
    BIT_ENABLE_NOISE = 3
    BIT_ENABLE_TRIANGLE = 2
    BIT_ENABLE_PULSE2 = 1
    BIT_ENABLE_PULSE1 = 0

    # Bits in the frame counter register
    BIT_MODE = 7
    BIT_IRQ_INHIBIT = 6

    # envelopes
    NUM_ENVELOPES = 3
    PULSE0 = 0  # } use 0 and 1 for the pulse to match with pulse_ix
    PULSE1 = 1  # }
    NOISE = 2

    # buffer length of the APU's output buffer; must be a power of 2
    APU_BUFFER_LENGTH = 65536
    CHUNK_SIZE = 10000


cdef class APUEnvelope:
    cdef:
        bint start_flag, loop_flag
        unsigned int decay_level, divider, volume

    cdef void update(self)
    cdef void restart(self)


cdef class APUUnit:
    cdef:
        bint enable, ctr_halt
        int length_ctr
        short output[SAMPLE_RATE]

    cdef void update_length_ctr(self)
    cdef void set_enable(self, bint value)
    cdef void set_length_ctr(self, int value)


cdef class APUTriangle(APUUnit):
    cdef:
        bint linear_reload_flag
        int linear_reload_value, period, linear_ctr
        double phase

    cdef void write_register(self, int address, unsigned char value)
    cdef void quarter_frame(self)
    cdef void half_frame(self)
    cdef int generate_sample(self)


cdef class APUPulse(APUUnit):
    cdef:
        bint constant_volume, is_unit_1
        int period, adjusted_period, duty
        double phase
        APUEnvelope env
        bint sweep_enable, sweep_negate, sweep_reload
        int sweep_period, sweep_shift, sweep_divider

        int duty_waveform[4][8]  # duty cycle sequences

    cdef void write_register(self, int address, unsigned char value)
    cdef void sweep_update(self)
    cdef void quarter_frame(self)
    cdef void half_frame(self)
    cdef int generate_sample(self)


cdef class APUNoise(APUUnit):
    cdef:
        bint constant_volume, mode
        int period, feedback, timer
        #double shift_ctr
        APUEnvelope env

        unsigned int timer_table[16]    # noise timer periods

    cdef void write_register(self, int address, unsigned char value)
    cdef void update_cycles(self, int cycles)
    cdef void quarter_frame(self)
    cdef void half_frame(self)
    cdef int generate_sample(self)


cdef class APUDMC(APUUnit):
    """
    The DMC unit is pretty different to the other APU units
    """
    cdef:
        NESMappedRAM memory
        InterruptListener interrupt_listener

        bint irq_enable, loop_flag, silence, interrupt_flag
        unsigned int sample_address, sample_length, address, bytes_remaining
        unsigned int rate, timer
        int output_level, bits_remaining
        unsigned char sample

        unsigned int rate_table[16]    # sample consumption rates for the dmc

    cdef void write_register(self, int address, unsigned char value)
    cdef void update_cycles(self, int cycles)
    cdef void read_advance(self)
    cdef int generate_sample(self)


cdef class NESAPU:
    """
    References:
        [1] https://wiki.nesdev.com/w/index.php/APU#Registers
        [2] https://wiki.nesdev.com/w/index.php/APU_Frame_Counter
    """
    cdef:
        #### master volume
        double master_volume

        #### apu state variables
        int cycles,rate  # cycle within the current frame (counted in CPU cycles NOT APU cycles as specified in [2]
        int frame_segment  # which segment of the frame the apu is in
        int _reset_timer_in  # after this number of cycles, reset the timer; ignored if < 0
        double samples_per_cycle  # number of output samples to generate per output cycle (will be <1)
        double samples_required  # number of samples currently required, once this gets over 1, generate a sample
        unsigned long long _buffer_start, _buffer_end  # start and end index of the sample ring buffer

        #### system interrupt listener
        InterruptListener interrupt_listener

        #### buffers for up to 1s of data for each of the waveform generators
        short output[APU_BUFFER_LENGTH]   # final output from the mixer; power of two sized to make ring buffer easier to implement
        short buffer[CHUNK_SIZE]

        #### status register
        bint mode, irq_inhibit, frame_interrupt_flag

        #### Sound units
        APUTriangle triangle
        APUPulse pulse1, pulse2
        APUNoise noise
        APUDMC dmc

        #### Frame counters
        int frame_counter

    ##########################################################################

    # register control functions
    cdef unsigned char read_register(self, int address)
    cdef void write_register(self, int address, unsigned char value)
    cdef void _set_status(self, unsigned char value)

    # synchronous update functions
    cdef int run_cycles(self, int cpu_cycles)
    cdef void quarter_frame_tick(self)
    cdef void half_frame_tick(self)

    # mixer
    cdef int mix(self, int tri, int p1, int p2, int noise, int dmc)

    # output
    cdef void generate_sample(self)
    cpdef short[:] get_sound(self, int samples)
    cpdef void set_volume(self, float volume)

    cpdef int buffer_remaining(self)

    cpdef void set_rate(self, int rate)
    cpdef int get_rate(self)

