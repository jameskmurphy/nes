from .mos6502 import MOS6502
from .memory import NESMappedRAM
from .ppu import NESPPU
from .rom import ROM
from .peripherals import Screen, Gamepad

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

        # todo: ugly way to handle this, will remove
        self._has_updated_gamepad = False   # whether or not the gamepad status has been updated on this loop

        # set up logging to the format as we required
        logging.basicConfig(filename=logfile,
                            level=logging.DEBUG,
                            format='%(asctime)-15s %(source)-5s %(message)s',
                            )

        rom = ROM(rom_file)

        # the cartridge is a piece of hardware (unlike the ROM, which is just data) and must come first because it
        # supplies bits of hardware (memory in most cases, both ROM and potentially RAM) all over the system, so it
        # affects the actual hardware configuration of the system.
        self.cart = rom.get_cart(prg_start)

        # screen has no dependencies
        self.screen = Screen(scale=screen_scale)

        # game controllers have no dependencies
        self.controller1 = Gamepad()
        self.controller2 = Gamepad(active=False)   # connect a second gamepad, but make it inactive for now

        # the interrupt listener here is not a NES hardware device, it is an interrupt handler that is used to pass
        # interrupts between the PPU and CPU in this emulator
        self.interrupt_listener = InterruptListener()
        self.ppu = NESPPU(cart=self.cart,
                          screen=self.screen,
                          interrupt_listener=self.interrupt_listener)

        # due to memory mapping, lots of things are connected to the main memory
        self.memory = NESMappedRAM(ppu=self.ppu,
                                   apu=None,
                                   cart=self.cart,
                                   controller1=self.controller1,
                                   controller2=self.controller2
                                   )

        # only the memory is connected to the cpu, all access to other devices is done through memory mapping
        self.cpu = MOS6502(memory=self.memory,
                           support_BCD=False,  # the NES cpu is a MOS6502 workalike that does not support the 6502's decimal modes
                           undocumented_support_level=1  # a few NES games make use of some more common undocumented instructions
                           )

        # Let's get started!  Reset the cpu so we are ready to go...
        self.cpu.reset()

    def step(self):
        """
        The heartbeat of the system.  Run one instruction on the CPU and the corresponding amount of cycles on the
        PPU (three per CPU cycle, at least on NTSC systems).
        """
        if self.interrupt_listener.nmi_active:
            print("NMI Triggered")
            cpu_cycles = self.cpu.trigger_nmi()  # raises an NMI on the CPU, but this does take some CPU cycles
            print("CPU PC: {:X}".format(self.cpu.PC))

            # should we do this here or leave this up to the triggerer?  It's really up to the triggerer to put the NMI
            # line into its "off" position, but if the line remains in the same state the CPU will not trigger another
            # NMI anyway.  Electronics lend themselves to edge-triggered events, whereas software is more naturally
            # pulse triggered in some ways (a thing happens then returns).
            self.interrupt_listener.reset_nmi()
        elif self.interrupt_listener.irq_active:
            raise NotImplementedError("IRQ is not implemented")
        else:
            cpu_cycles = self.cpu.run_next_instr()

        frame_ended = self.ppu.run_cycles(cpu_cycles * self.PPU_CYCLES_PER_CPU_CYCLE)


        # todo: this is ugly and should be handled better
        if self.ppu.in_vblank and not self._has_updated_gamepad:
            self.controller1.update()
            if self.controller2:
                self.controller2.update()
            self._has_updated_gamepad = True
        if frame_ended:
            self._has_updated_gamepad = False

    def run(self):
        """
        Run the NES indefinitely (or until some quit signal); this will only exit on quit.
        There is some PyGame specific stuff in here in order to handle frame timing and checking for exits
        """
        pass



"""
TODO:

- IRQ is not implemented (and is used in a few places on the NES:  https://wiki.nesdev.com/w/index.php/IRQ)
- colliding and lost interrupts:  http://visual6502.org/wiki/index.php?title=6502_Timing_of_Interrupt_Handling

"""


