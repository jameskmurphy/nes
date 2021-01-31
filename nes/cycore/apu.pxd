from .system cimport InterruptListener



cdef enum:

    # sound synthesis constants
    SAMPLE_RATE = 48000
    CPU_FREQ_HZ = 1789773   # https://wiki.nesdev.com/w/index.php/Cycle_reference_chart#Clock_rates

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




cdef class NESAPU:
    """
    References:
        [1] https://wiki.nesdev.com/w/index.php/APU#Registers
        [2] https://wiki.nesdev.com/w/index.php/APU_Frame_Counter
    """
    cdef:

        #### apu state variables
        int cycles  # cycle within the current frame (counted in CPU cycles NOT APU cycles as specified in [2]
        int frame_segment  # which segment of the frame the apu is in

        #### system interrupt listener
        InterruptListener interrupt_listener

        #### buffers for up to 1s of data for each of the waveform generators
        short triangle[SAMPLE_RATE]
        short pulse[2][SAMPLE_RATE]
        short output[SAMPLE_RATE]  # final output from the mixer

        #### status register
        bint enable_dmc, enable_noise, enable_triangle
        bint enable_pulse[2]
        bint mode, irq_inhibit

        #### pulse registers x2
        int pulse_duty[2]
        bint pulse_length_ctr_halt[2]
        bint pulse_constant_volume[2]
        int pulse_volume_envelope[2]
        bint pulse_sweep_enable[2]
        int pulse_sweep_period[2]
        bint pulse_sweep_negate[2]
        int pulse_sweep_shift[2]
        int pulse_timer[2]
        int pulse_length_ctr[2]

        double pulse_phase[2]


        #### triangle registers  0x4008-0x400B
        bint tri_length_ctr_halt
        int tri_linear_reload_value
        bint tri_linear_reload_flag
        int tri_timer, tri_linear_ctr, tri_length_ctr

        double tri_phase

        #### noise registers
        bint noise_length_ctr_halt
        bint noise_constant_volume
        int noise_volume_envelope
        bint noise_loop
        int noise_period
        int noise_length_ctr

        #### DMC registers
        int dmc_length_ctr

        #### lookup tables
        int length_table[32]   # timer length lookup
        int duty[4][8]         # duty cycle sequences


        #### Frame counters
        int frame_counter

    ##########################################################################

    # register control functions
    cdef char read_register(self, int address)
    cdef void write_register(self, int address, unsigned char value)

    cdef void _set_status(self, unsigned char value)
    cdef void _set_pulse(self, int address, unsigned char value)
    cdef void _set_triangle(self, int address, unsigned char value)
    cdef void _set_noise(self, int address, unsigned char value)

    # synchronous update functions
    cdef void run_cycles(self, int cpu_cycles)
    cdef void quarter_frame_tick(self)
    cdef void half_frame_tick(self)

    # triangle generation
    cdef int _tri_by_phase(self, double phase_cyc)
    cdef void generate_triangle(self, int samples)

    # pulse generation
    cdef int _pulse_by_phase(self, double phase_cyc, int duty_ix)
    cdef void generate_pulse(self, int pulse_ix, int samples)

    # mixer
    cdef void mixer(self, int num_samples)

    # output
    cpdef short[:] get_sound(self, int samples)
