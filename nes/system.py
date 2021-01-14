from .mos6502 import MOS6502
from .memory import NESMappedRAM
from .ppu import NESPPU
from .rom import ROM
from .peripherals import Screen

import logging


class InterruptListener:
    def __init__(self):
        self._nmi = False
        self._irq = False   # the actual IRQ line on the 6502 rests high and is low-triggered

    def raise_nmi(self):
        self._nmi = True

    def reset_nmi(self):
        self._nmi = False

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

    def __init__(self, rom_file, screen_scale=3, logfile=None, prg_start=None):
        """
        Build a NES and cartridge from the bits and pieces we have lying around plus some rom data!  Also do some things
        like set up logging, etc.
        """

        # set up logging to the format as we required
        logging.basicConfig(filename=logfile,
                            level=logging.DEBUG,
                            format='%(asctime)-15s %(source)-5s %(message)s',
                            )

        rom = ROM(rom_file)
        # the cartridge must come first because it supplies bits all over the system
        self.cart = rom.get_cart(prg_start)
        self.screen = Screen(scale=screen_scale)
        self.interrupt_listener = InterruptListener()
        self.ppu = NESPPU(cart=self.cart, screen=self.screen, interrupt_listener=self.interrupt_listener)
        self.memory = NESMappedRAM(ppu=self.ppu, apu=None, cart=self.cart)
        self.cpu = MOS6502(memory=self.memory, support_BCD=False, undocumented_support_level=1)
        self.cpu.reset()

    def step(self):
        """
        The heartbeat of the system.  Run one instruction on the CPU and the corresponding amount of cycles on the
        PPU (three per CPU cycle, at least on NTSC systems).
        """
        if self.interrupt_listener.nmi_active:
            print("NMI Triggered")
            cpu_cycles = self.cpu.trigger_nmi()
            print("CPU PC: {:X}".format(self.cpu.PC))
            self.interrupt_listener.reset_nmi()    # should we do this here or leave this up to the triggerer?
        elif self.interrupt_listener.irq_active:
            raise NotImplementedError("IRQ is not implemented")
        else:
            cpu_cycles = self.cpu.run_next_instr()

        self.ppu.run_cycles(cpu_cycles * self.PPU_CYCLES_PER_CPU_CYCLE)


"""
TODO:

- IRQ is not implemented (and is used in a few places on the NES:  https://wiki.nesdev.com/w/index.php/IRQ)
- colliding and lost interrupts:  http://visual6502.org/wiki/index.php?title=6502_Timing_of_Interrupt_Handling

"""


