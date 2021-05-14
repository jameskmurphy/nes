import pyximport; pyximport.install()

from nes.pycore.mos6502 import MOS6502
#from .cycore.mos6502 import MOS6502
from nes.pycore.memory import NESMappedRAM
#from .cycore.memory import NESMappedRAM
from nes.pycore.ppu import NESPPU
#from .cycore.ppu import NESPPU
from nes.rom import ROM
from nes.peripherals import Screen, KeyboardController, ControllerBase
#from nes import LOG_CPU, LOG_PPU, LOG_MEMORY
import pickle

import logging

import pygame

class InterruptListener:
    def __init__(self):
        self._nmi = False
        self._irq = False   # the actual IRQ line on the 6502 rests high and is low-triggered
        self.oam_dma_pause = False

    def raise_nmi(self):
        self._nmi = True

    def reset_nmi(self):
        self._nmi = False

    def reset_oam_dma_pause(self):
        self.oam_dma_pause = False

    def raise_oam_dma_pause(self):
        self.oam_dma_pause = True

    def any_active(self):
        return self._nmi or self._irq or self.oam_dma_pause

    @property
    def nmi_active(self):
        return self._nmi

    @property
    def irq_active(self):
        return self._irq


class NES:
    """
    The NES system itself, combining all of the parts, and the interlinks
    """
    PPU_CYCLES_PER_CPU_CYCLE = 3
    FRAMERATE_FPS = 240

    def __init__(self, rom_file, screen_scale=3, log_file=None, log_level=None, prg_start=None):
        """
        Build a NES and cartridge from the bits and pieces we have lying around plus some rom data!  Also do some things
        like set up logging, etc.
        """
        # set up the logger
        self.init_logging(log_file, log_level)

        rom = ROM(rom_file, py_compatibility_mode=True)

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

        # screen needs to have the PPU
        self.screen = Screen(ppu=self.ppu, scale=screen_scale, py_compatibility_mode=True)
        self.ppu.screen = self.screen
        self.screen_scale = screen_scale

        # due to memory mapping, lots of things are connected to the main memory
        self.memory = NESMappedRAM(ppu=self.ppu,
                                   apu=None,
                                   cart=self.cart,
                                   controller1=self.controller1,
                                   controller2=self.controller2,
                                   interrupt_listener=self.interrupt_listener
                                   )

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

    def step(self):
        """
        The heartbeat of the system.  Run one instruction on the CPU and the corresponding amount of cycles on the
        PPU (three per CPU cycle, at least on NTSC systems).
        """
        if self.interrupt_listener.any_active():
            # do it this way for speed
            if self.interrupt_listener.nmi_active:
                print("NMI Triggered")
                cpu_cycles = self.cpu.trigger_nmi()  # raises an NMI on the CPU, but this does take some CPU cycles
                #print("CPU PC: {:X}".format(self.cpu.PC))

                # should we do this here or leave this up to the triggerer?  It's really up to the triggerer to put the NMI
                # line into its "off" position, but if the line remains in the same state the CPU will not trigger another
                # NMI anyway.  Electronics lend themselves to edge-triggered events, whereas software is more naturally
                # pulse triggered in some ways (a thing happens then returns).
                self.interrupt_listener.reset_nmi()
            elif self.interrupt_listener.irq_active:
                raise NotImplementedError("IRQ is not implemented")
            elif self.interrupt_listener.oam_dma_pause:
                # https://wiki.nesdev.com/w/index.php/PPU_OAM#DMA
                cpu_cycles = self.cpu.oam_dma_pause()
                #cpu_cycles = self.OAM_DMA_CPU_CYCLES + self.cpu.cycles_since_reset % 2
                #self.cpu.cycles_since_reset += cpu_cycles  #todo: should we do this - don't think it matters
                self.interrupt_listener.reset_oam_dma_pause()
        else:
            cpu_cycles = self.cpu.run_next_instr()

        #print(cpu_cycles, self.ppu.line, self.ppu.pixel)
        vblank_started = self.ppu.run_cycles(cpu_cycles * self.PPU_CYCLES_PER_CPU_CYCLE)
        #print(cpu_cycles, self.ppu.line, self.ppu.pixel)
        return vblank_started

    def run(self):
        """
        Run the NES indefinitely (or until some quit signal); this will only exit on quit.
        There is some PyGame specific stuff in here in order to handle frame timing and checking for exits
        """
        pygame.init()
        clock = pygame.time.Clock()

        show_hud = True

        while True:
            vblank_started=False
            while not vblank_started:
                if self.interrupt_listener.any_active():
                    # do it this way for speed
                    if self.interrupt_listener.nmi_active:
                        cpu_cycles = self.cpu.trigger_nmi()  # raises an NMI on the CPU, but this does take some CPU cycles
                        # print("CPU PC: {:X}".format(self.cpu.PC))

                        # should we do this here or leave this up to the triggerer?  It's really up to the triggerer to put the NMI
                        # line into its "off" position, but if the line remains in the same state the CPU will not trigger another
                        # NMI anyway.  Electronics lend themselves to edge-triggered events, whereas software is more naturally
                        # pulse triggered in some ways (a thing happens then returns).
                        self.interrupt_listener.reset_nmi()
                    elif self.interrupt_listener.irq_active:
                        raise NotImplementedError("IRQ is not implemented")
                    elif self.interrupt_listener.oam_dma_pause:
                        # https://wiki.nesdev.com/w/index.php/PPU_OAM#DMA
                        cpu_cycles = self.cpu.oam_dma_pause()
                        # cpu_cycles = self.OAM_DMA_CPU_CYCLES + self.cpu.cycles_since_reset % 2
                        # self.cpu.cycles_since_reset += cpu_cycles  #todo: should we do this - don't think it matters
                        self.interrupt_listener.reset_oam_dma_pause()
                else:
                    cpu_cycles = self.cpu.run_next_instr()

                #print(self.cpu.log_line())

                vblank_started = self.ppu.run_cycles(cpu_cycles * self.PPU_CYCLES_PER_CPU_CYCLE)

            # update the controllers once per frame
            self.controller1.update()
            self.controller2.update()

            fps = clock.get_fps()
            if show_hud:
                self.screen.add_text("{:.0f} fps".format(clock.get_fps()), (10, 10), (0, 255, 0) if fps > 55 else (255, 0, 0))

            # Check for an exit
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    pygame.quit()
                    return
                elif event.type == pygame.KEYDOWN:
                    if event.key == pygame.K_1:
                        show_hud = not show_hud
                    if event.key == pygame.K_0:
                        self.save()
                        self.screen.add_text("saved", (100, 10), (255, 128, 0))

            self.screen.show()
            clock.tick(self.FRAMERATE_FPS)
            #print("frame end:  {:.1f} fps".format(clock.get_fps()))






"""
TODO:

- IRQ is not implemented (and is used in a few places on the NES:  https://wiki.nesdev.com/w/index.php/IRQ)
- colliding and lost interrupts:  http://visual6502.org/wiki/index.php?title=6502_Timing_of_Interrupt_Handling

"""


