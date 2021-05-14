#import pyximport; pyximport.install()

from .bitwise cimport bit_high
try:
    import pyaudio
    has_audio = False
except ImportError:
    has_audio = True

from .system cimport DMC_DMA

#### Length Table and other constant arrays ############################################################################

cdef int[32] LENGTH_TABLE = [ 10, 254, 20,  2, 40,  4, 80,  6, 160,  8, 60, 10, 14, 12, 26, 14,
                              12,  16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30 ]

#### Basic components ##################################################################################################

cdef class APUUnit:
    """
    Base class for the APU's sound generation units providing some basic common functionality
    """
    def __init__(self):
        self.enable = False
        self.length_ctr = 0
        self.ctr_halt = False
        for i in range(SAMPLE_RATE):
            self.output[i] = 0

    cdef void update_length_ctr(self):
        if not self.ctr_halt:
            self.length_ctr = (self.length_ctr - 1) if self.length_ctr > 0 else 0

    cdef void set_enable(self, bint value):
        self.enable = value
        if not self.enable:
            self.length_ctr = 0

    cdef void set_length_ctr(self, int value):
        if self.enable:
            self.length_ctr = LENGTH_TABLE[value & 0b11111]


cdef class APUEnvelope:
    """
    Volume envelope unit used in pulse and noise APU units
    Reference:
        [6] envelope:  https://wiki.nesdev.com/w/index.php/APU_Envelope
    """
    def __init__(self):
        self.start_flag = False
        self.loop_flag = False
        self.decay_level = 0
        self.divider = 0
        self.volume = 0

    cdef void restart(self):
        self.start_flag = False
        self.decay_level = 15
        self.divider = self.volume

    cdef void update(self):
        if not self.start_flag:   # if start flag is clear
            # clock divider
            if self.divider == 0:
                # When divider is clocked while at 0, it is loaded with volume and clocks the decay level counter [6]
                self.divider = self.volume
                # clock decay counter:
                #   if the counter is non-zero, it is decremented, otherwise if the loop flag is set, the decay level
                #   counter is loaded with 15. [6]
                if self.decay_level > 0:
                    self.decay_level -=1
                elif self.loop_flag:
                    self.decay_level = 15
            else:
                # clock divider (is this right?)
                self.divider -= 1
        else:
            self.restart()


#### Sound generation units ############################################################################################

cdef class APUTriangle(APUUnit):
    """
    APU unit for generating triangle waveform
    Reference:
        [4] triangle:  https://wiki.nesdev.com/w/index.php/APU_Triangle
    """
    def __init__(self):
        super().__init__()
        self.period = 0
        self.phase = 0

        self.linear_reload_flag = False
        self.linear_reload_value = 0
        self.linear_ctr = 0

    cdef void write_register(self, int address, unsigned char value):
        """
        Set properties of the triangle waveform generator from a write to its registers.
        """
        if address == 0x4008:
            self.ctr_halt = bit_high(value, 7)
            # don't set the counter directly, just set the reload value for now
            self.linear_reload_value = value & 0b01111111
        elif address == 0x400A:
            self.period = (self.period & 0xFF00) + value
        elif address == 0x400B:
            self.period = (self.period & 0xFF) + ((value & 0b00000111) << 8)
            self.set_length_ctr(value >> 3)
            self.linear_reload_flag = True

    cdef void quarter_frame(self):

        # Update triangle linear counter.  This is a bit complicated and occurs as follows [4]:
        # if counter reload flag is set:
        #     linear counter <-- counter reload value
        # elif linear counter > 0:
        #     decrement linear counter
        # if control flag clear:
        #     counter reload flag cleared
        if self.linear_reload_flag:
            self.linear_ctr = self.linear_reload_value
        elif self.linear_ctr > 0:
             self.linear_ctr -= 1

        if not self.ctr_halt:  # this is also the control flag
            self.linear_reload_flag = False

    cdef void half_frame(self):
        self.update_length_ctr()

    cdef int generate_sample(self):
        """
        Generate a single sample of the triangle wave and advance the phase appropriately
        """
        cdef double freq_hz
        cdef int v

        # frequency of the triangle wave is given by timer as follows [4]:
        freq_hz = CPU_FREQ_HZ * 1. / (32. * (self.period + 1))

        # how much phase we step with each cycle is given by
        #   phase_per_samp = cycles per sample = (freq_hz / samples per second)
        # unit of phase here is CYCLES not radians (i.e. 1 cycle = 2pi radians)
        phase_per_samp = freq_hz / SAMPLE_RATE

        # if the triangle wave is not enabled or its linear or length counter is zero, this is zero.
        # Also added here is an exclusion for ultrasonic frequencies, which is used in MegaMan to silence the triangle
        # this is not entirely accurate, but probably produces nicer sounds.
        if (not self.enable) or self.length_ctr == 0 or self.linear_ctr == 0 or self.period < 2:
            v = 0
        else:
            v = int(31.999999 * abs(0.5 - self.phase))    # int cast rounds down, should never be 16
            self.phase = (self.phase + phase_per_samp) % 1.

        return v


cdef class APUPulse(APUUnit):
    """
    APU pulse unit; there are two of these in the APU
    Reference:
        [5] pulse: https://wiki.nesdev.com/w/index.php/APU_Pulse
        [12] http://nesdev.com/apu_ref.txt
        [13] https://wiki.nesdev.com/w/index.php/APU_Sweep
    """
    # Duty cycles for the pulse generators [5]
    DUTY_CYCLES = [[0, 1, 0, 0,  0, 0, 0, 0],
                   [0, 1, 1, 0,  0, 0, 0, 0],
                   [0, 1, 1, 1,  1, 0, 0, 0],
                   [1, 0, 0, 1,  1, 1, 1, 1]]

    def __init__(self, is_unit_1):
        super().__init__()
        self.constant_volume = False
        self.period = 1
        self.adjusted_period = 1   # period adjusted by the sweep units
        self.duty = 0
        self.phase = 0
        self.env = APUEnvelope()
        self.is_unit_1 = is_unit_1

        self.sweep_enable = False
        self.sweep_negate = False
        self.sweep_reload = False
        self.sweep_period = 1
        self.sweep_shift = 0
        self.sweep_divider = 0

        # copy the pulse duty cycle patterns into an int array
        # todo: is there a way to have shared cython class-level variables or constants?
        for i in range(4):
            for j in range(8):
                self.duty_waveform[i][j] = self.DUTY_CYCLES[i][j]

    cdef void write_register(self, int address, unsigned char value):
        """
        Set properties of the pulse waveform generators from a write to one of their registers; assumes address has been
        mapped to the 0x4000-0x4003 range (i.e. if this is pulse 1, subtract 4)
        """
        address -= 4 if not self.is_unit_1 else 0
        if address == 0x4000:
            self.duty = (value & 0b11000000) >> 6
            self.ctr_halt = bit_high(value, 5)         # } these are the same
            self.env.loop_flag = bit_high(value, 5)    # }
            self.constant_volume = bit_high(value, 4)
            self.env.volume = value & 0b00001111
        elif address == 0x4001:
            self.sweep_enable = bit_high(value, 7)
            self.sweep_period = ((value & 0b01110000) >> 4) + 1
            self.sweep_negate = bit_high(value, 3)
            self.sweep_shift = value & 0b00000111
            self.sweep_reload = True
            #print("sweep: {:08b}".format(value))
        elif address == 0x4002:
            # timer low
            self.period = (self.period & 0xFF00) + value
            self.adjusted_period = self.period
        elif address == 0x4003:
            self.period = (self.period & 0xFF) + ((value & 0b00000111) << 8)
            self.adjusted_period = self.period
            self.set_length_ctr(value >> 3)
            # side effect: the sequencer is restarted at the first value of the sequence and envelope is restarted [5]
            self.phase = 0
            # side effect: restart envelope and set the envelope start flag
            self.env.restart()
            self.env.start_flag = True

    cdef void quarter_frame(self):
        self.env.update()

    cdef void half_frame(self):
        self.sweep_update()
        self.update_length_ctr()

    cdef void sweep_update(self):
        """
        Adjust the period based on the sweep unit.  Part of the functionality here is based on the following paragraph
        from [12]:
            "When the channel's period is less than 8 or the result of the shifter is
             greater than $7FF, the channel's DAC receives 0 and the sweep unit doesn't
             change the channel's period. Otherwise, if the sweep unit is enabled and the
             shift count is greater than 0, when the divider outputs a clock, the channel's
             period in the third and fourth registers are updated with the result of the
             shifter."
        This seems to disagree a little with [13] in that the description in [13] permits zero as a shift
        value (and even uses it as an example), whereas the above text excludes it.  This makes a difference in the
        game Ghengis Khan, which if 0 is permitted as a shift has background music which sounds wrong (and differs from
        FCEUX) in the main game screens.

        In the system here, adjusted_period is used to determine whether or not the period has been changed outside of
        the permitted range, silencing the channel (without adjusting period outside that range).  Don't know if this is
        correct, but it seems to be what is implied in [12].

        Finally, should the change amount be based on the non-adjusted period or the adjusted period?  I.e. should the
        period be irrevocably altered by the sweep unit, or is the original period retained somewhere and used to
        calculate the shift each time?  In a recurring multiple shift, this changes the frequency change rate from
        exponential to linear.  No clear idea of what is correct.
        """
        cdef int change_amount
        if self.sweep_reload:
            # If [the divider's counter is zero or] the reload flag is true, the counter is set to P and the reload flag
            # is cleared. [7]
            self.sweep_divider = self.sweep_period
            self.sweep_reload = False
            return

        if self.sweep_divider > 0:
            # Otherwise, the counter is decremented. [7]
            self.sweep_divider -= 1
        else: # self.sweep_divider == 0:
            # If the divider's counter is zero [...], the counter is set to P and the reload flag is cleared. [7]
            self.sweep_divider = self.sweep_period
            self.sweep_reload = False

            if self.sweep_enable and self.sweep_shift > 0:
                # in this case, trigger a period adjustment
                change_amount = self.period >> self.sweep_shift
                if self.sweep_negate:
                    change_amount = -change_amount
                    if not self.is_unit_1:
                        change_amount -= 1

                # check if the adjusted period would go outside range; if so, don't update main period, but channel
                # will be silenced (see description above)
                self.adjusted_period = self.period + change_amount
                if 8 < self.adjusted_period <= 0x7FF:
                    self.period += change_amount

    cdef int generate_sample(self):
        """
        Generate one output sample from the pulse unit.
        """
        cdef double freq_hz
        cdef int v, volume, change_amount

        freq_hz = CPU_FREQ_HZ * 1. / (16. * (self.period + 1))

        # how much phase we step with each cycle is given by
        #   phase_per_samp = cycles per sample = (freq_hz / samples per second)
        # unit of phase here is CYCLES not radians (i.e. 1 cycle = 2pi radians)
        phase_per_samp = freq_hz / SAMPLE_RATE

        # there are several conditions under which the channel is muted.  [7] and others.
        if ( not self.enable
             or self.length_ctr == 0
             or self.adjusted_period < 8
             or self.adjusted_period > 0x7FF
            ):
            v = 0
        else:
            volume = self.env.volume if self.constant_volume else self.env.decay_level
            v = volume * self.duty_waveform[self.duty][int(7.999999 * self.phase)]
            self.phase = (self.phase + phase_per_samp) % 1.
        return v


cdef class APUNoise(APUUnit):
    """
    APU pulse unit; there are two of these in the APU
    Reference:
        [8] noise: https://wiki.nesdev.com/w/index.php/APU_Noise

    """
    TIMER_TABLE = [4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068]

    def __init__(self):
        super().__init__()
        self.constant_volume = False
        self.mode = False
        self.period = 4
        self.feedback = 1  # loaded with 1 on power up [8]
        self.timer = 0
        self.env = APUEnvelope()
        for i in range(16):
            self.timer_table[i] = self.TIMER_TABLE[i]

    cdef void write_register(self, int address, unsigned char value):
        """
        Set properties of the noise waveform generators from a write to its registers.
        """
        if address == 0x400C:
            self.ctr_halt = bit_high(value, 5)    # } these are the same
            self.env.loop_flag = bit_high(value, 5)     # }
            self.constant_volume = bit_high(value, 4)
            self.env.volume = value & 0b00001111
        elif address == 0x400E:
            self.mode = bit_high(value, 7)
            self.period = self.timer_table[value & 0b00001111]
        elif address == 0x400F:
            self.set_length_ctr(value >> 3)
            # side effect: restart envelope and set the envelope start flag
            self.env.restart()
            self.env.start_flag = True

    cdef void quarter_frame(self):
        self.env.update()

    cdef void half_frame(self):
        self.update_length_ctr()

    cdef void update_cycles(self, int cycles):
        cdef int xor_bit, feedback_bit
        self.timer += cycles

        if self.timer >= 2 * self.period:
            self.timer -= 2 * self.period
            xor_bit = 6 if self.mode else 1
            feedback_bit = bit_high(self.feedback, 0) ^ bit_high(self.feedback, xor_bit)
            self.feedback >>= 1
            self.feedback |= (feedback_bit << 14)

    cdef int generate_sample(self):
        """
        Generates a noise sample.  Updates a shift register to create pseudo-random samples and applies the
        noise volume envelope.
        """
        # clock the feedback register 0.5 * CPU_FREQ / SAMPLE_RATE / noise_period times per sample
        volume = self.env.volume if self.constant_volume else self.env.decay_level
        if not self.enable or self.length_ctr==0:
            return 0
        return volume * (self.feedback & 1)   # bit here should actually be negated, but doesn't matter


cdef class APUDMC(APUUnit):
    """
    The delta modulation channel (DMC) of the APU.  This allows delta-coded 1-bit samples to be played
    directly from memory.  It operates in a different way to the other channels, so is not based on them.
    References:
        [9] DMC: https://wiki.nesdev.com/w/index.php/APU_DMC
        [10] DMC interrupt flag reset: http://www.slack.net/~ant/nes-emu/apu_ref.txt
        [11] interesting DMC model: http://www.slack.net/~ant/nes-emu/dmc/
    """
    RATE_TABLE = [428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106,  84,  72,  54]

    def __init__(self, interrupt_listener):
        super().__init__()

        self.interrupt_listener = interrupt_listener

        self.enable = False
        self.silence = True
        self.irq_enable = False
        self.loop_flag = False
        self.interrupt_flag = False

        self.rate = 0
        self.output_level = 0
        self.sample_address = 0
        self.address = 0
        self.sample_length = 0
        self.bytes_remaining = 0
        self.sample = 0
        self.timer = 0

        # copy the rate table lookup into the cdef'ed variable for speed
        for i in range(16):
            self.rate_table[i] = self.RATE_TABLE[i]

    cdef void write_register(self, int address, unsigned char value):
        """
        Write a value to one of the dmc's control registers; called from APU write register.  Address must be in the
        0x4010 - 0x4013 range (inclusive); if not the write is ignored
        """
        if address == 0x4010:
            self.irq_enable = bit_high(value, 7)
            if not self.irq_enable:
                self.interrupt_flag = False
            self.loop_flag = bit_high(value, 6)
            self.rate = self.rate_table[value & 0b00001111]
        elif address == 0x4011:
            self.output_level = value & 0b01111111
        elif address == 0x4012:
            self.sample_address = 0xC000 + (value << 6)
            self.address = self.sample_address
        elif address == 0x4013:
            self.sample_length = (value << 4) + 1
            self.bytes_remaining = self.sample_length

    cdef void update_cycles(self, int cpu_cycles):
        """
        Update that occurs on every CPU clock tick, run cpu_cycles times
        """
        cdef int v
        self.timer += cpu_cycles

        if self.timer < 2 * self.rate:
            return

        # now the unit's timer has ticked, so update the unit
        self.timer -= 2 * self.rate

        # update bits_remaining counter
        if self.bits_remaining == 0:
            # cycle end; a new cycle can start
            self.bits_remaining = 8
            self.read_advance()

        # read the bit
        v = self.sample & 1

        if not self.silence:
            if v == 0 and self.output_level >= 2:
                self.output_level -= 2
            elif v == 1 and self.output_level <= 125:
                self.output_level += 2

        # clock the shift register one place to the right
        self.sample >>= 1
        self.bits_remaining -= 1

    cdef void read_advance(self):
        """
        Reads a byte of memory and places it into the sample buffer; advances memory pointer, wrapping if necessary.
        """
        if self.bytes_remaining == 0:
            if self.loop_flag:
                # if looping and have run out of data, go back to the start
                self.bytes_remaining = self.sample_length
                self.address = self.sample_address
            else:
                self.silence = True

        if self.bytes_remaining > 0:
            self.sample = self.memory.read(self.address)
            self.address = (self.address + 1) & 0xFFFF
            self.bytes_remaining -= 1
            self.silence = False
            if self.bytes_remaining == 0 and self.irq_enable:
                # this was the last byte that we just read
                # "the IRQ is generated when the last byte of the sample is read, not when the last sample of the
                # sample plays" [9]
                self.interrupt_listener.raise_irq()
                self.interrupt_flag = True

            # a DMC memory read should stall the CPU here for a variable number of cycles
            self.interrupt_listener.raise_dma_pause(DMC_DMA)

    cdef int generate_sample(self):
        """
        Generate the next DMC sample.
        """
        return self.output_level


#### The APU ###########################################################################################################

cdef class NESAPU:
    """
    NES APU

    Sources:
        [1] https://wiki.nesdev.com/w/index.php/APU#Registers
        [2] https://wiki.nesdev.com/w/index.php/APU_Frame_Counter
        [3] https://wiki.nesdev.com/w/index.php/APU_Length_Counter

        [10] DMC interrupt flag reset: http://www.slack.net/~ant/nes-emu/apu_ref.txt
    """
    def __init__(self, interrupt_listener, master_volume=0.5):
        self.interrupt_listener = interrupt_listener

        # Power-up and reset have the effect of writing $00 to apu status (0x4015), silencing all channels [1]
        self.frame_segment = 0
        self.cycles = 0
        self._reset_timer_in = -1
        self.samples_per_cycle = SAMPLE_RATE * 1. / CPU_FREQ_HZ
        self.samples_required = 0
        self.rate=SAMPLE_RATE
        self.irq_inhibit = True

        # the frame_interrupt_flag is connected to the CPU's IRQ line, so changes to this flag should be accompanied by
        # a change to the interrupt_listener's state
        self.frame_interrupt_flag = False

        # sound output buffer (this is a ring buffer, so these variables track the current start and end position)
        self._buffer_start = 0
        self._buffer_end = 1600  # give it some bonus sound to start with

        self.master_volume = master_volume
        self.mode = FOUR_STEP

        # sound production units
        self.triangle = APUTriangle()
        self.pulse1 = APUPulse(is_unit_1=True)
        self.pulse2 = APUPulse(is_unit_1=False)
        self.noise = APUNoise()
        self.dmc = APUDMC(interrupt_listener)

        for i in range(APU_BUFFER_LENGTH):
            self.output[i] = 0

    cpdef short[:] get_sound(self, int samples):
        """
        Generate samples of audio using the current audio settings.  The number of samples generated
        should be small (probably at most about 1/4 frame - 200 samples at 48kHz - to allow all effects to be
        reproduced, however, somewhat longer windows can probably be used; there are 800 samples in a frame at 48kHz).
        The absolute maximum that will be returned is 1s of audio.
        """
        cdef int i
        samples = min(samples, CHUNK_SIZE, self._buffer_end - self._buffer_start)
        for i in range(samples):
            self.buffer[i] = self.output[(self._buffer_start + i) & (APU_BUFFER_LENGTH - 1)]
        self._buffer_start += samples
        cdef short[:] data = <short[:samples]>self.buffer
        return data

    cdef void generate_sample(self):
        tri = self.triangle.generate_sample()
        p1 = self.pulse1.generate_sample()
        p2 = self.pulse2.generate_sample()
        noise = self.noise.generate_sample()
        dmc = self.dmc.generate_sample()

        v = self.mix(tri, p1, p2, noise, dmc)

        self.output[self._buffer_end & (APU_BUFFER_LENGTH - 1)] = v
        self._buffer_end += 1

    cpdef int buffer_remaining(self):
        return self._buffer_end - self._buffer_start

    cpdef void set_volume(self, float volume):
        self.master_volume = volume

    cpdef void set_rate(self, int rate):
        self.rate = rate
        self.samples_per_cycle = self.rate * 1. / CPU_FREQ_HZ

    cpdef int get_rate(self):
        return self.rate

    ######## interfacing with pyaudio #####################
    # keep all pyaudio code in this section

    def pyaudio_callback(self, in_data, frame_count, time_info, status):
        if self.buffer_remaining() > 0:
            data = self.get_sound(frame_count)
            return (data, pyaudio.paContinue)
        else:
            return (None, pyaudio.paAbort)

    ########################################################

    cdef int run_cycles(self, int cpu_cycles):
        """
        Updates the APU by the given number of cpu cycles.  This updates the frame counter if
        necessary (every quarter or fifth video frame).  Timings from [2].
        """
        cdef int new_segment, cpu_cycles_per_loop, cycles
        cdef bint quarter_frame = False, force_ticks = False

        while cpu_cycles > 0:
            cycles = cpu_cycles if cpu_cycles < MAX_CPU_CYCLES_PER_LOOP else MAX_CPU_CYCLES_PER_LOOP
            self.cycles += cycles
            cpu_cycles -= MAX_CPU_CYCLES_PER_LOOP

            self.dmc.update_cycles(cycles)
            self.noise.update_cycles(cycles)

            self.samples_required += cycles * self.samples_per_cycle
            while self.samples_required > 1:
                self.generate_sample()
                self.samples_required -= 1

            if self._reset_timer_in >= 0:
                self._reset_timer_in -= cycles
                if self._reset_timer_in < 0:
                    self.cycles = 0
                    if self.mode == FIVE_STEP:
                        force_ticks = True
                    else: # four step mode
                        # If mode is FOUR_STEP, do *not* generate frame ticks
                        self.frame_segment = 0

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
                        self.frame_interrupt_flag = True
                else:  # five-step counter
                    if self.cycles <= 37281:
                        new_segment = 5
                    else:
                        new_segment = 0
                        self.cycles -= 37282

            if self.frame_segment != new_segment or force_ticks:
                if self.mode == FOUR_STEP or new_segment != 3:
                    # the quarter frame tick happens on the 0, 1, 2, 4 ticks in FIVE_STEP mode
                    # source: (https://wiki.nesdev.com/w/index.php/APU) section on Frame Counter
                    self.quarter_frame_tick()
                quarter_frame = True
                if new_segment == 0 or new_segment == 2 or force_ticks:
                    self.half_frame_tick()

            self.frame_segment = new_segment
        return quarter_frame

    cdef void quarter_frame_tick(self):
        """
        This is a tick that happens four times every (video) frame.  It updates the envelopes and the
        linear counter of the triange generator [2].
        """
        self.triangle.quarter_frame()
        self.pulse1.quarter_frame()
        self.pulse2.quarter_frame()
        self.noise.quarter_frame()

    cdef void half_frame_tick(self):
        """
        This is a tick that happens twice every (video) frame.  It updates the length counters and the
        sweep units [2].
        """
        self.triangle.half_frame()
        self.pulse1.half_frame()
        self.pulse2.half_frame()
        self.noise.half_frame()

    cdef unsigned char read_register(self, int address):
        """
        Read an APU register.  Actually the only one you can read is STATUS (0x4015).
        """
        cdef unsigned char value
        cdef bint dmc_active = False

        dmc_active = self.dmc.bytes_remaining > 0

        if address == STATUS:
            value = (  (self.dmc.interrupt_flag << 7)
                     + (self.frame_interrupt_flag << 6)
                     + (dmc_active << 4)
                     + ((self.noise.length_ctr > 0) << 3)
                     + ((self.triangle.length_ctr > 0) << 2)
                     + ((self.pulse2.length_ctr > 0) << 1)
                     + (self.pulse1.length_ctr > 0)
                    )
            self.frame_interrupt_flag = False
            # "When $4015 is written to, the channels' length counter enable flags are set,
            # the DMC is possibly started or stopped, and the DMC's IRQ occurred flag is cleared." [10]
            self.dmc.interrupt_flag = False
            self.interrupt_listener.reset_irq()
            return value

        print("apu read: {:04X}".format(address))

    cdef void write_register(self, int address, unsigned char value):
        """
        Write to one of the APU registers.
        """
        cdef APUPulse pulse

        if address == STATUS:
            self._set_status(value)
        elif address == FRAME_COUNTER:
            self.mode = bit_high(value, BIT_MODE)
            self.irq_inhibit = bit_high(value, BIT_IRQ_INHIBIT)
            if self.irq_inhibit:
                self.frame_interrupt_flag = False
                self.interrupt_listener.reset_irq()
            # side effects:  reset timer (in 3-4 cpu cycles' time, if mode set generate quarter and half frame signals)
            self._reset_timer_in = 3 + self.cycles % 2
        elif 0x4000 <= address <= 0x4007:
            # a pulse register
            # there are two pulse registers set by 0x4000-0x4003 and 0x4004-0x4007; select the correct one to update
            pulse = self.pulse1 if address < 0x4004 else self.pulse2
            pulse.write_register(address, value)
        elif 0x4008 <= address <= 0x400B:
            # a triangle register
            self.triangle.write_register(address, value)
        elif 0x400C <= address <= 0x400F:
            self.noise.write_register(address, value)
        elif 0x4010 <= address <= 0x4013:
            self.dmc.write_register(address, value)

    cdef void _set_status(self, unsigned char value):
        """
        Sets up the status register from a write to the status register 0x4015
        """
        self.triangle.set_enable(bit_high(value, BIT_ENABLE_TRIANGLE))
        self.pulse1.set_enable(bit_high(value, BIT_ENABLE_PULSE1))
        self.pulse2.set_enable(bit_high(value, BIT_ENABLE_PULSE2))
        self.noise.set_enable(bit_high(value, BIT_ENABLE_NOISE))
        self.dmc.set_enable(bit_high(value, BIT_ENABLE_DMC))

    cdef int mix(self, int triangle, int pulse1, int pulse2, int noise, int dmc):
        """
        Mix the channels into signed 16-bit audio samples
        """
        cdef double pulse_out, tnd_out, sum_pulse, sum_tnd

        sum_pulse = pulse1 + pulse2
        sum_tnd = (triangle / 8227.) + (noise / 12241.) + (dmc / 22638.)
        pulse_out = 95.88 / ((8128. / sum_pulse) + 100.) if sum_pulse != 0 else 0
        tnd_out = 159.79 / (1. / sum_tnd + 100.) if sum_tnd != 0 else 0
        return int( ((pulse_out + tnd_out) ) * self.master_volume * SAMPLE_SCALE)
