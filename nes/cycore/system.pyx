# cython: profile=True, boundscheck=False, nonecheck=False

import pyximport; pyximport.install()

from nes.cycore.mos6502 import MOS6502
from nes.cycore.memory import NESMappedRAM
from nes.cycore.ppu import NESPPU
from nes.cycore.apu import NESAPU
from nes.rom import ROM
from nes.peripherals import Screen, ScreenGL, KeyboardController, ControllerBase
from nes import LOG_CPU, LOG_PPU, LOG_MEMORY
import pickle

import logging

import pygame
import pyaudio  # unfortunately, pygame's audio handling does not do what we need with gapless playback of short samples

import time

from .apu cimport SAMPLE_RATE


cdef class InterruptListener:
    def __init__(self):
        self._nmi = False
        self._irq = False   # the actual IRQ line on the 6502 rests high and is low-triggered
        self.dma_pause = False
        self.dma_pause_count = 0

    cdef void raise_nmi(self):
        self._nmi = True

    cdef void reset_nmi(self):
        self._nmi = False

    cdef void raise_irq(self):
        self._irq = True

    cdef void reset_irq(self):
        self._irq = False

    cdef void reset_dma_pause(self):
        self.dma_pause = 0
        self.dma_pause_count = 0

    cdef void raise_dma_pause(self, int type):
        self.dma_pause = type
        self.dma_pause_count += 1  # can (and this will be rare) get multiple DMC DMA pauses during OAM DMA

    cdef int any_active(self):
        return self._nmi or self._irq or self.dma_pause

    cdef int nmi_active(self):
        return self._nmi

    cdef int irq_active(self):
        return self._irq


cdef class NES:
    """
    The NES system itself, combining all of the parts, and the interlinks
    """
    OSD_Y = 3
    OSD_FPS_X = 5
    OSD_VOL_X = 110
    OSD_MUTE_X = 200
    OSD_NOTE_X = 100

    OSD_TEXT_COLOR = (0, 255, 0)
    OSD_NOTE_COLOR = (255, 128, 0)
    OSD_WARN_COLOR = (255, 0, 0)



    def __init__(self, rom_file, screen_scale=3, log_file=None, log_level=None, prg_start=None, sync_mode=SYNC_AUDIO):
        """
        Build a NES and cartridge from the bits and pieces we have lying around plus some rom data!  Also do some things
        like set up logging, etc.
        """
        self.sync_mode = sync_mode

        # set up the logger
        self.init_logging(log_file, log_level)

        rom = ROM(rom_file)

        # the cartridge is a piece of hardware (unlike the ROM, which is just data) and must come first because it
        # supplies bits of hardware (memory in most cases, both ROM and potentially RAM) all over the system, so it
        # affects the actual hardware configuration of the system.
        self.cart = rom.get_cart(prg_start)

        # game controllers have no dependencies
        self.controller1 = KeyboardController()
        self.controller2 = ControllerBase(active=False)   # connect a second gamepad, but make it inactive for now

        # the interrupt listener here is not a NES hardware device, it is an interrupt handler that is used to pass
        # interrupts between the PPU and CPU in this emulator
        self.interrupt_listener = InterruptListener()
        self.ppu = NESPPU(cart=self.cart, interrupt_listener=self.interrupt_listener)
        self.apu = NESAPU(interrupt_listener=self.interrupt_listener)

        # screen needs to have the PPU
        self.screen = ScreenGL(ppu=self.ppu, scale=screen_scale, vsync=True if sync_mode == SYNC_VSYNC else False)
        self.screen_scale = screen_scale

        # due to memory mapping, lots of things are connected to the main memory
        self.memory = NESMappedRAM(ppu=self.ppu,
                                   apu=self.apu,
                                   cart=self.cart,
                                   controller1=self.controller1,
                                   controller2=self.controller2,
                                   interrupt_listener=self.interrupt_listener
                                   )

        # one nasty wrinkle here is that we have to give the apu's dmc channel access to the memory:
        self.apu.dmc.memory = self.memory

        # only the memory is connected to the cpu, all access to other devices is done through memory mapping
        self.cpu = MOS6502(memory=self.memory,
                           undocumented_support_level=2,  # a few NES games make use of some more common undocumented instructions
                           stack_underflow_causes_exception=False
                           )

        # Let's get started!  Reset the cpu so we are ready to go...
        self.cpu.reset()

    def init_logging(self, log_file, log_level):
        """
        Initialize the logging; set the log file and the logging level (LOG_MEMORY, LOG_PPU, LOG_CPU are all below
        logging.DEBUG)
        """
        if log_file is None or log_level is None:
            logging.disable()
            return

        logging.addLevelName(LOG_MEMORY, "MEMORY")  # set a low level for memory logging because it is so intense
        logging.addLevelName(LOG_PPU, "PPU")
        logging.addLevelName(LOG_CPU, "CPU")
        # set up logging to the format as we required
        logging.basicConfig(filename=log_file,
                            level=logging.NOTSET,
                            format='%(asctime)-15s %(source)-5s %(message)s',
                            filemode='w',
                            )
        logging.root.setLevel(log_level)

    def __getstate__(self):
        state = self.memory.__getstate__() #(self.cart, self.controller1, self.controller2, self.interrupt_listener, self.cpu, self.memory, self.screen_scale)
        return state

    def __setstate__(self, state):
        self.cart, self.controller1, self.controller2, self.interrupt_listener, self.cpu, self.memory, self.screen_scale = state
        self.screen = Screen(scale=self.screen_scale)

    def save(self):
        with open("test.p", "wb") as f:
            pickle.dump(self, f, protocol=4)

    @staticmethod
    def load(file):
        with open(file, "rb") as f:
            nes = pickle.load(f)
        nes.screen._special_init()
        return nes

    cdef int step(self, int log_cpu):
        """
        The heartbeat of the system.  Run one instruction on the CPU and the corresponding amount of cycles on the
        PPU (three per CPU cycle, at least on NTSC systems).
        """
        cdef int cpu_cycles=0
        cdef bint vblank_started=False

        if self.interrupt_listener.any_active():
            # do it this way for speed
            if self.interrupt_listener.nmi_active():
                cpu_cycles = self.cpu.trigger_nmi()  # raises an NMI on the CPU, but this does take some CPU cycles
                # should we do this here or leave this up to the triggerer?  It's really up to the triggerer to put the NMI
                # line into its "off" position, but if the line remains in the same state the CPU will not trigger another
                # NMI anyway.  Electronics lend themselves to edge-triggered events, whereas software is more naturally
                # pulse triggered in some ways (a thing happens then returns).
                self.interrupt_listener.reset_nmi()
                if log_cpu:
                    logging.log(logging.INFO, "NMI Triggered", extra={"source": "Interrupt"})
            elif self.interrupt_listener.irq_active():
                # note, cpu_cycles can be zero here if the cpu is set to ignore irq
                cpu_cycles = self.cpu.trigger_irq()
                self.interrupt_listener.reset_irq()
                if log_cpu:
                    logging.log(logging.INFO, "IRQ Triggered", extra={"source": "Interrupt"})
            elif self.interrupt_listener.dma_pause:
                # https://wiki.nesdev.com/w/index.php/PPU_OAM#DMA
                cpu_cycles = self.cpu.dma_pause(self.interrupt_listener.dma_pause,
                                                self.interrupt_listener.dma_pause_count
                                                )
                self.interrupt_listener.reset_dma_pause()
                had_dma_pause = True
                if log_cpu:
                    logging.log(logging.INFO, "OAM DMA", extra={"source": "Interrupt"})

        if cpu_cycles == 0:
            cpu_cycles = self.cpu.run_next_instr()

        if log_cpu:
            logging.log(logging.INFO, self.cpu.log_line(self.ppu.line, self.ppu.pixel) , extra={"source": "CPU"})

        vblank_started = self.ppu.run_cycles(cpu_cycles * PPU_CYCLES_PER_CPU_CYCLE)
        self.apu.run_cycles(cpu_cycles)
        if had_dma_pause and self.interrupt_listener.dma_pause:
            # any apu dmc dma pause that occurred during an oam dma pause should average 2 rather than 4 cycles
            self.interrupt_listener.dma_pause = DMC_DMA_DURING_OAM_DMA
        return vblank_started

    cpdef void run(self):
        """
        Run the NES indefinitely (or until some quit signal); this will only exit on quit.
        There is some PyGame specific stuff in here in order to handle frame timing and checking for exits
        """
        cdef int vblank_started
        cdef float volume = 0.5
        cdef double fps, t_start=0.
        cdef bint show_hud, log_cpu, mute
        cdef int frame=0, frame_start=0, cpu_cycles=0, last_sound_buffer=0

        p = pyaudio.PyAudio()

        pygame.init()
        clock = pygame.time.Clock()

        # this has to come after pygame init for some reason, or pygame won't start :(
        player = p.open(format=pyaudio.paInt16,
                        channels=1,
                        rate=SAMPLE_RATE,
                        output=True,
                        frames_per_buffer=AUDIO_CHUNK_SAMPLES,  # 400 is a half-frame at 60Hz, 48kHz sound
                        stream_callback=self.apu.pyaudio_callback,
                        )

        show_hud = True
        log_cpu = False
        mute = False

        player.start_stream()

        t_start = time.time()

        while True:
            vblank_started=False
            while not vblank_started:
                vblank_started = self.step(log_cpu)

            # update the controllers once per frame
            self.controller1.update()
            self.controller2.update()

            fps = (frame - frame_start) * 1.0 / (time.time() - t_start)
            #print(self.cpu.cycles_since_reset - cpu_cycles)
            cpu_cycles = self.cpu.cycles_since_reset

            if time.time() - t_start > 10.0:
                frame_start = frame
                t_start = time.time()
            if show_hud:
                self.screen.add_text("{:.0f} fps, {}Hz".format(fps, self.apu.get_rate()), (self.OSD_FPS_X, self.OSD_Y), self.OSD_TEXT_COLOR if fps > TARGET_FPS-3 else self.OSD_WARN_COLOR)
                if log_cpu:
                    self.screen.add_text("logging cpu", (self.OSD_NOTE_X, self.OSD_Y), self.OSD_NOTE_COLOR)
                if mute:
                    self.screen.add_text("MUTE", (self.OSD_MUTE_X, self.OSD_Y), self.OSD_TEXT_COLOR)

            # Check for an exit
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    pygame.quit()
                    player.stop_stream()
                    player.close()
                    p.terminate()
                    return
                elif event.type == pygame.KEYDOWN:
                    if event.key == pygame.K_1:
                        show_hud = not show_hud
                    if event.key == pygame.K_3:
                        self.save()
                        self.screen.add_text("saved", (self.OSD_NOTE_X, self.OSD_Y), self.OSD_NOTE_COLOR)
                    if event.key == pygame.K_0:
                        if not mute:
                            self.apu.set_volume(0)
                            mute = True
                        else:
                            self.apu.set_volume(volume)
                            mute=False
                    if event.key == pygame.K_MINUS:
                        volume = max(0, volume - 0.1)
                        self.apu.set_volume(volume)
                        self.screen.add_text("volume: " + "|" * int(10 * volume), (self.OSD_VOL_X, self.OSD_Y), self.OSD_TEXT_COLOR, ttl=30)
                        mute=False
                    if event.key == pygame.K_EQUALS:
                        volume = min(1, volume + 0.1)
                        self.apu.set_volume(volume)
                        self.screen.add_text("volume: " + "|" * int(10 * volume), (self.OSD_VOL_X, self.OSD_Y), self.OSD_TEXT_COLOR, ttl=30)
                        mute=False
                    if event.key == pygame.K_2:
                        log_cpu = not log_cpu

            if self.sync_mode == SYNC_AUDIO:
                # wait for the audio buffer to empty, but only if the audio is playing
                while self.apu.buffer_remaining() > MIN_AUDIO_BUFFER_SAMPLES and player.is_active():
                    clock.tick(500)  # wait for about 2ms (~= 96 samples)
            elif self.sync_mode == SYNC_VSYNC or self.sync_mode == SYNC_PYGAME:
                # here we rely on an external sync source, but allow the audio to adapt to it
                if frame > 20:
                    if self.apu.buffer_remaining() > last_sound_buffer:
                        # if the rate is elevated and the sound buffer is growing, try reducing the rate
                        if self.apu.get_rate() > SAMPLE_RATE:
                            self.apu.set_rate(self.apu.get_rate() - 480)
                    elif self.apu.buffer_remaining() < last_sound_buffer:
                        self.apu.set_rate(self.apu.get_rate() + 480)

                    last_sound_buffer = self.apu.buffer_remaining()
            else:
                # no sync at all, go as fast as we can!
                pass

            if self.sync_mode == SYNC_PYGAME:
                # if we are using pygame sync, we have to supply our own clock tick here
                clock.tick(TARGET_FPS)

            if not player.is_active() and self.apu.buffer_remaining() > MIN_AUDIO_BUFFER_SAMPLES:
                # try to (re)start the stream if it is not running if there is audio waiting
                print("audio dropped, attempting restart")
                player = p.open(format=pyaudio.paInt16,
                                channels=1,
                                rate=SAMPLE_RATE,
                                output=True,
                                frames_per_buffer=AUDIO_CHUNK_SAMPLES,  # 400 is a half-frame at 60Hz, 48kHz sound
                                stream_callback=self.apu.pyaudio_callback,
                                )
                player.start_stream()

            #0self.debug_draw_nametables()

            self.screen.show()
            frame += 1

    cdef void debug_draw_nametables(self):
        cdef int nx, ny, x, y
        line = ""

        for ny in range(2):
            for y in range(30):
                line = ""
                for nx in range(2):
                    base = 0x2000 + 0x800 * ny + 0x400 * nx
                    for x in range(32):
                        tile = self.ppu.vram.read(base + 32 * y + x)
                        line += "{:2X} ".format(tile)
                    line += "     "
                print(line)
            print()
        print()


