# cython: profile=True, boundscheck=False, nonecheck=False

import pyximport; pyximport.install()

#from .pycore.mos6502 import MOS6502
from nes.cycore.mos6502 import MOS6502
#from .pycore.memory import NESMappedRAM
from nes.cycore.memory import NESMappedRAM
#from .pycore..ppu import NESPPU
from nes.cycore.ppu import NESPPU
from nes.cycore.apu import NESAPU
from nes.rom import ROM
from nes.peripherals import Screen, KeyboardController, ControllerBase
from nes import LOG_CPU, LOG_PPU, LOG_MEMORY
import pickle

import logging

import pygame
import pyaudio

import time

cdef class InterruptListener:
    def __init__(self):
        self._nmi = False
        self._irq = False   # the actual IRQ line on the 6502 rests high and is low-triggered
        self.oam_dma_pause = False

    cdef void raise_nmi(self):
        self._nmi = True

    cdef void reset_nmi(self):
        self._nmi = False

    cdef void raise_irq(self):
        self._irq = True

    cdef void reset_irq(self):
        self._irq = False

    cdef void reset_oam_dma_pause(self):
        self.oam_dma_pause = False

    cdef void raise_oam_dma_pause(self):
        self.oam_dma_pause = True

    cdef int any_active(self):
        return self._nmi or self._irq or self.oam_dma_pause

    cdef int nmi_active(self):
        return self._nmi

    cdef int irq_active(self):
        return self._irq


cdef class NES:
    """
    The NES system itself, combining all of the parts, and the interlinks
    """
    FRAMERATE_FPS = 100

    def __init__(self, rom_file, screen_scale=3, log_file=None, log_level=None, prg_start=None):
        """
        Build a NES and cartridge from the bits and pieces we have lying around plus some rom data!  Also do some things
        like set up logging, etc.
        """
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
        self.screen = Screen(ppu=self.ppu, scale=screen_scale)
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
        cdef bint vblank_started=False, quarter_frame=False

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
            elif self.interrupt_listener.oam_dma_pause:
                # https://wiki.nesdev.com/w/index.php/PPU_OAM#DMA
                cpu_cycles = self.cpu.oam_dma_pause()
                self.interrupt_listener.reset_oam_dma_pause()
                if log_cpu:
                    logging.log(logging.INFO, "OAM DMA", extra={"source": "Interrupt"})

        if cpu_cycles == 0:
            cpu_cycles = self.cpu.run_next_instr()

        if log_cpu:
            logging.log(logging.INFO, self.cpu.log_line() + ", {}".format(self.ppu.cycles_since_reset) , extra={"source": "CPU"})

        vblank_started = self.ppu.run_cycles(cpu_cycles * PPU_CYCLES_PER_CPU_CYCLE)
        quarter_frame = self.apu.run_cycles(cpu_cycles)
        return quarter_frame + 2 * vblank_started

    cpdef void run(self):
        """
        Run the NES indefinitely (or until some quit signal); this will only exit on quit.
        There is some PyGame specific stuff in here in order to handle frame timing and checking for exits
        """
        cdef int vblank_started
        cdef float volume = 0.5
        cdef double fps, t_start=0.
        cdef bint show_hud, log_cpu, mute
        cdef int frame=0, frame_start=0, cpu_cycles=0

        p = pyaudio.PyAudio()

        pygame.init()
        clock = pygame.time.Clock()

        # this has to come after pygame init for some reason, or pygame won't start :(
        player = p.open(format=pyaudio.paInt16,
                        channels=1,
                        rate=48000,
                        output=True,
                        frames_per_buffer=400,  # 400 is a half-frame at 60Hz, 48kHz sound
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
                rval = self.step(log_cpu)
                if rval % 2 == 1:
                    # quarter frame
                    #clock.tick(self.FRAMERATE_FPS * 4)
                    pass
                vblank_started = rval >= 2

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
                self.screen.add_text("{:.0f} fps".format(fps), (10, 10), (0, 255, 0) if fps > 55 else (255, 0, 0))
                if log_cpu:
                    self.screen.add_text("logging cpu", (100, 10), (255, 128, 0))
                if mute:
                    self.screen.add_text("MUTE", (200 * self.screen_scale, 10), (0, 255, 0))

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
                        self.screen.add_text("saved", (100, 10), (255, 128, 0))
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
                        self.screen.add_text("volume: " + "|" * int(10 * volume), (100 * self.screen_scale, 10), (0, 255, 0), ttl=30)
                        mute=False
                    if event.key == pygame.K_EQUALS:
                        volume = min(1, volume + 0.1)
                        self.apu.set_volume(volume)
                        self.screen.add_text("volume: " + "|" * int(10 * volume), (100 * self.screen_scale, 10), (0, 255, 0), ttl=30)
                        mute=False
                    if event.key == pygame.K_2:
                        log_cpu = not log_cpu


            self.screen.show()
            frame += 1
            self.apu.wait_until_buffer_empty()  # sync on audio

            #clock.tick(self.FRAMERATE_FPS)
            #print("frame end:  {:.1f} fps".format(clock.get_fps()))


