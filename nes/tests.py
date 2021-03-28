from .mos6502 import MOS6502
from .memory import BigEmptyRAM, NESMappedRAM
from .rom import ROM

from .utils import load_rom_raw

def setup_machine_basic():
    program_start = 0xC000
    load_at = 0xC000 - 16   # don't know why the rom starts here, but it does
    memory = BigEmptyRAM()
    cpu = MOS6502(memory, support_BCD=False)  # don't support BCD on NES
    rom, header = load_rom_raw("./testroms/nestest/nestest.nes")

    # note that the rom is too long and overruns the memory so have to add the reset vector after
    # I don't know why this is (it is a NES rom) or how it should be loaded properly
    memory.ram[load_at:load_at + len(rom)] = rom

    cpu.set_reset_vector(program_start)

    return cpu

def setup_machine_nes():
    rom = ROM("./testroms/nestest/nestest.nes")
    cart = rom.get_cart(prg_start=0xC000)  #NESCart0(rom_data=rom_data, load_rom_at=0xC000-16)
    cart.prg_start_addr = 0xC000
    memory = NESMappedRAM(cart=cart)
    cpu = MOS6502(memory, support_BCD=False)  # don't support BCD on NES
    cpu.set_reset_vector(0xC000)

    return cpu

def nestest(num_instrs, suppress_until=0):
    cpu = setup_machine_nes()

    error_lines = []

    # begin the test
    with open("./testroms/nestest/nestest.log", "rt") as f:

        cpu.reset()

        cpulog = cpu.log_line()
        truelog = f.readline()
        if suppress_until <= 0:
            print(cpulog)
            print(truelog[:-1])

        # compare the crucial last bit of the lines, excluding the PPU location:
        if cpulog[48:74] != truelog[48:74] or cpulog[87:] != truelog[87:-1]:
            error_lines.append(0)
            print(" *************** ERROR ")

        for i in range(1, num_instrs):

            if i >= suppress_until:
                print()
                print(i)
            cpu.run_next_instr()

            cpulog = cpu.log_line()
            truelog = f.readline()

            if len(truelog) == 0:
                print("FINISHED ALL TESTS - CONGRATULATIONS")
                break

            if i >= suppress_until:
                print(cpulog[:46] + cpulog[48:])   # cut out some whitespace to make it fit on a line
                print(truelog[:46] + truelog[48:-1])
                # memory.print(0x00, 256)
                # print("NV-BDIZC")
                # print("{:08b}".format(cpu._status_to_byte()))

            # compare the crucial last bit of the lines, excluding (for now) the PPU states:
            if cpulog[48:74] != truelog[48:74] or cpulog[87:] != truelog[87:-1]:
                error_lines.append(i)
                if i >= suppress_until:
                    print("\033[93m***** ERROR *************** ERROR *************** ERROR *************** ERROR ***************\033[0m")

    print()
    print("ERRORS AT:")
    print(error_lines)

