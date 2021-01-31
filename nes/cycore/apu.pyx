from .bitwise cimport bit_high
import numpy as np
import pyaudio
import math

cdef class NESAPU:
    """
    NES APU

    Sources:
        [1] https://wiki.nesdev.com/w/index.php/APU#Registers
        [2] https://wiki.nesdev.com/w/index.php/APU_Frame_Counter
        [3] https://wiki.nesdev.com/w/index.php/APU_Length_Counter
        [4] triangle:  https://wiki.nesdev.com/w/index.php/APU_Triangle
        [5] pulse: https://wiki.nesdev.com/w/index.php/APU_Pulse
    """

    # length table is a lookup from the value written to the length counter and the value
    # loaded into the length counter [3]
    LENGTH_TABLE = [10,254, 20,  2, 40,  4, 80,  6, 160,  8, 60, 10, 14, 12, 26, 14,
                    12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30]

    # Duty cycles for the pulse generators [5]
    DUTY_CYCLES = [[0, 1, 0, 0,  0, 0, 0, 0],
                   [0, 1, 1, 0,  0, 0, 0, 0],
                   [0, 1, 1, 1,  1, 0, 0, 0],
                   [1, 0, 0, 1,  1, 1, 1, 1]]


    def __init__(self, interrupt_listener):

        # Power-up and reset have the effect of writing $00 to apu status (0x4015), silencing all channels [1]
        self.enable_dmc = False
        self.enable_noise = False
        self.enable_triangle = False
        self.enable_pulse = [False, False]

        self.tri_linear_reload_flag = False
        self.tri_linear_reload_value = 0

        self.pulse_length_ctr = [0, 0]

        self.frame_segment = 0
        self.cycles = 0

        self.interrupt_listener = interrupt_listener

        # copy the length table to a int array (avoid python interaction)
        for i in range(32):
            self.length_table[i] = self.LENGTH_TABLE[i]

        # copy the pulse duty cycle patterns into an int array
        for i in range(4):
            for j in range(8):
                self.duty[i][j] = self.DUTY_CYCLES[i][j]

        self.tri_phase = 0
        self.pulse_phase[0] = 0
        self.pulse_phase[1] = 0

    ######## interfacing with pyaudio #####################

    #def f_sound(self, t):
    #    freq = 500
    #    return np.sin(t * freq * 2. * np.pi)

    #def get_soundX(self, samples):
    #    data = np.zeros((samples), dtype=np.int16)
    #    for i in range(samples):
    #        sa = self.s + i
    #        data[i] = int(self.f_sound(sa / 48000) * 16383)
    #    self.s += samples
    #    return data

    cpdef short[:] get_sound(self, int samples):

        samples = min(samples, SAMPLE_RATE)  # don't request more than 1s of audio or we can create buffer overruns

        # generate each of the waveforms
        self.generate_triangle(samples)
        self.generate_pulse(0, samples)
        self.generate_pulse(1, samples)

        # mix them
        self.mixer(samples)

        # return a memoryview to the buffer
        # todo: is this safe enough or would be be better off using cython arrays?
        cdef short[:] data = <short[:samples]>self.output
        return data

    def pyaudio_callback(self, in_data, frame_count, time_info, status):
        data = self.get_sound(frame_count)
        return (data, pyaudio.paContinue)

    ########################################################

    cdef void run_cycles(self, int cpu_cycles):
        """
        Updates the APU by the given number of cpu cycles.  This updates the frame counter if
        necessary (every quarter or fifth video frame).  Timings from [2].
        """

        cdef int new_segment

        # 7457,     14913,         22371,                29829
        # 7456 + 1, 7456 * 2 + 1,  7456 * 3 - 1 (wut!?), 7456 * 4 + 5

        self.cycles += cpu_cycles
        if self.cycles < 7457:
            new_segment = 0
        elif self.cycles < 14913:
            new_segment = 1
        elif self.cycles < 22371:
            new_segment = 2
        elif self.cycles <= 29829:   # this should be <, but logic is easier this way
            new_segment = 3
        else:
            if self.mode == FOUR_STEP:
                new_segment = 0
                self.cycles -= 29830
                if not self.irq_inhibit:
                    self.interrupt_listener.raise_irq()
            else:  # five-step counter
                if self.cycles <= 37281:
                    new_segment = 5
                else:
                    new_segment = 0
                    self.cycles -= 37282

        if self.frame_segment != new_segment:
            self.quarter_frame_tick()
            if new_segment == 0 or new_segment == 2:
                self.half_frame_tick()

        self.frame_segment = new_segment

    cdef void quarter_frame_tick(self):
        """
        This is a tick that happens four times every (video) frame.  It updates the envelopes and the
        linear counter of the triange generator [2].
        """
        # update the envelopes
        # todo update envelopes

        # Update triangle linear counter.  This is a bit complicated and occurs as follows [4]:
        # if counter reload flag is set:
        #     linear counter <-- counter reload value
        # elif linear counter > 0:
        #     decrement linear counter
        # if control flag clear:
        #     counter reload flag cleared

        if self.tri_linear_reload_flag:
            self.tri_linear_ctr = self.tri_linear_reload_value
        elif self.tri_linear_ctr > 0:
             self.tri_linear_ctr -= 1

        if not self.tri_length_ctr_halt:  # this is also the control flag
            self.tri_linear_reload_flag = False

        print("tri: ", self.tri_linear_ctr, self.tri_length_ctr, self.tri_timer)


    cdef void half_frame_tick(self):
        """
        This is a tick that happens twice every (video) frame.  It updates the length counters and the
        sweep units [2].
        """
        # sweep units
        # todo: update the sweep units

        # length counter decrement
        if not self.noise_length_ctr_halt:
            self.noise_length_ctr = (self.noise_length_ctr - 1) if self.noise_length_ctr > 0 else 0
        if not self.tri_length_ctr_halt:
            self.tri_length_ctr = (self.tri_length_ctr - 1) if self.tri_length_ctr > 0 else 0
        if not self.pulse_length_ctr_halt[0]:
            self.pulse_length_ctr[0] = (self.pulse_length_ctr[0] - 1) if self.pulse_length_ctr[0] > 0 else 0
        if not self.pulse_length_ctr_halt[1]:
            self.pulse_length_ctr[1] = (self.pulse_length_ctr[1] - 1) if self.pulse_length_ctr[1] > 0 else 0


    cdef char read_register(self, int address):

        if address == STATUS:
            # todo
            pass

        print("apu read: {:04X}".format(address))

    cdef void write_register(self, int address, unsigned char value):
        cdef int pulse_ix, pulse_reg

        if address == STATUS:
            self._set_status(value)
        elif address == FRAME_COUNTER:
            self.mode = bit_high(value, BIT_MODE)
            self.irq_inhibit = bit_high(value, BIT_IRQ_INHIBIT)
        elif 0x4000 <= address <= 0x4007:
            # a pulse register
            self._set_pulse(address, value)
        elif 0x4008 <= address <= 0x400B:
            # a triangle register
            self._set_triangle(address, value)
        elif 0x400C <= address <= 0x400F:
            self._set_noise(address, value)

        print("apu write: {:02X} -> {:04X}".format(value, address))

    cdef void _set_status(self, unsigned char value):
        self.enable_dmc = bit_high(value, BIT_ENABLE_DMC)
        if not self.enable_dmc:
            self.dmc_length_ctr = 0
        self.enable_noise = bit_high(value, BIT_ENABLE_NOISE)
        if not self.enable_noise:
            self.noise_length_ctr = 0
        self.enable_triangle = bit_high(value, BIT_ENABLE_TRIANGLE)
        if not self.enable_triangle:
            self.tri_length_ctr = 0
        self.enable_pulse[0] = bit_high(value, BIT_ENABLE_PULSE1)
        if not self.enable_pulse[0]:
            self.pulse_length_ctr[0] = 0
        self.enable_pulse[1] = bit_high(value, BIT_ENABLE_PULSE2)
        if not self.enable_pulse[1]:
            self.pulse_length_ctr[1] = 0

    cdef void _set_pulse(self, int address, unsigned char value):
        # there are two pulse registers set by 0x4000-0x4003 and 0x4004-0x4007
        pulse_ix = 0 if address < 0x4004 else 1  # set the correct register
        address -= 4 * pulse_ix  #  map down to the 0x4000-0x4003 range
        if address == 0x4000:
            self.pulse_duty[pulse_ix] = (value & 0b11000000) >> 6
            self.pulse_length_ctr_halt[pulse_ix] = bit_high(value, 5)
            self.pulse_constant_volume[pulse_ix] = bit_high(value, 4)
            self.pulse_volume_envelope[pulse_ix] = value & 0b00001111
        elif address == 0x4001:
            self.pulse_sweep_enable[pulse_ix] = bit_high(value, 7)
            self.pulse_sweep_period[pulse_ix] = (value & 0b01110000) >> 4
            self.pulse_sweep_negate[pulse_ix] = bit_high(value, 3)
            self.pulse_sweep_shift[pulse_ix] = value & 0b00000111
        elif address == 0x4002:
            # timer low
            self.pulse_timer[pulse_ix] = (self.pulse_timer[pulse_ix] & 0xFF00) + value
        elif address == 0x4003:
            self.pulse_timer[pulse_ix] = (self.pulse_timer[pulse_ix] & 0xFF) + ((value & 0b00000111) << 8)
            self.pulse_length_ctr[pulse_ix] = self.length_table[value >> 3]
            # side effect:  the sequencer is restarted at the first value of the sequence and envelope is restarted [5]
            self.pulse_phase[pulse_ix] = 0
            # todo: restart envelope

    cdef void _set_triangle(self, int address, unsigned char value):
        if address == 0x4008:
            self.tri_length_ctr_halt = bit_high(value, 7)
            # don't set the counter directly, just set the reload value for now
            self.tri_linear_reload_value = value & 0b01111111
        elif address == 0x400A:
            self.tri_timer = (self.tri_timer & 0xFF00) + value
        elif address == 0x400B:
            self.tri_timer = (self.tri_timer & 0xFF) + ((value & 0b00000111) << 8)
            self.tri_length_ctr = self.length_table[value >> 3]
            self.tri_linear_reload_flag = True

    cdef void _set_noise(self, int address, unsigned char value):
        if address == 0x400C:
            self.noise_length_ctr_halt = bit_high(value, 5)
            self.noise_constant_volume = bit_high(value, 4)
            self.noise_volume_envelope = value & 0b00001111
        elif address == 0x400E:
            self.noise_loop = bit_high(value, 4)
            self.noise_period = value & 0b00001111
        elif address == 0x400F:
            self.noise_length_ctr = self.length_table[value >> 3]

    cdef int _tri_by_phase(self, double phase_cyc):
        # phase_cyc is the phase in CYCLES not radians
        return int(31.999999 * abs(0.5 - phase_cyc))    # int cast rounds down, should never be 16

    cdef void generate_triangle(self, int samples):
        # generating number of samples given by samples
        cdef double t, freq_hz
        cdef int i

        # requesting this much time
        t = samples * 1. / SAMPLE_RATE

        # frequency of the triangle wave is given by timer as follows [4]:
        freq_hz = CPU_FREQ_HZ * 1. / (32. * (self.tri_timer + 1))

        # how much phase we step with each cycle is given by
        # freq_hz = cycles per second
        # phase_per_samp = cycles per sample = (freq_hz / samples per second)
        # unit of phase here is CYCLES not radians (i.e. 1 cycle = 2pi radians)
        phase_per_samp = freq_hz / SAMPLE_RATE

        # if the triangle wave is not enabled or its linear or length counter is zero,
        # this is all zeros:
        if (not self.enable_triangle) or self.tri_length_ctr == 0 or self.tri_linear_ctr == 0:
            for i in range(samples):
                self.triangle[i] = 8   # todo: this should probably be 0 in the end
            self.tri_phase = (self.tri_phase + samples * phase_per_samp) % 1.
            return

        # generate the samples and advance the phase of the triangle wave
        for i in range(samples):
            self.tri_phase = (self.tri_phase + phase_per_samp) % 1.
            self.triangle[i] = self._tri_by_phase(self.tri_phase)

    cdef int _pulse_by_phase(self, double phase_cyc, int duty_ix):
        # phase_cyc is the phase in CYCLES not radians
        return self.duty[duty_ix][int(7.999999 * phase_cyc)]    # index must never be 8

    cdef void generate_pulse(self, int pulse_ix, int samples):
        """
        Generate the output of the pulse unit specified by pulse_ix and put it into the supplied
        buffer output.  samples gives the number of samples to generate.
        """
        cdef double t, freq_hz
        cdef int i

        # requesting this much time
        t = samples * 1. / SAMPLE_RATE

        # frequency of the triangle wave is given by timer as follows [4]:
        freq_hz = CPU_FREQ_HZ * 1. / (16. * (self.pulse_timer[pulse_ix] + 1))

        # how much phase we step with each cycle is given by
        # freq_hz = cycles per second
        # phase_per_samp = cycles per sample = (freq_hz / samples per second)
        # unit of phase here is CYCLES not radians (i.e. 1 cycle = 2pi radians)
        phase_per_samp = freq_hz / SAMPLE_RATE

        if (not self.enable_pulse[pulse_ix]) or self.pulse_length_ctr[pulse_ix] == 0 or self.pulse_timer[pulse_ix] < 8:
            for i in range(samples):
                self.pulse[pulse_ix][i] = 0
            self.pulse_phase[pulse_ix] = (self.pulse_phase[pulse_ix] + samples * phase_per_samp) % 1.
            return

        # generate the samples and advance the phase of the triangle wave
        for i in range(samples):
            self.pulse_phase[pulse_ix] = (self.pulse_phase[pulse_ix] + phase_per_samp) % 1.
            self.pulse[pulse_ix][i] = self._pulse_by_phase(self.pulse_phase[pulse_ix], self.pulse_duty[pulse_ix])

    cdef void mixer(self, int num_samples):
        # mix the channels into signed 16-bit audio samples
        cdef int i

        for i in range(num_samples):
            self.output[i] = ((self.triangle[i] - 8) * 1000
                         + self.pulse[0][i] * 10000 - 5000
                         + self.pulse[1][i] * 10000 - 5000
                         )


"""
TODO:


- Envelopes
- Sweep units
- DMC
- Noise
- Mixer


"""





