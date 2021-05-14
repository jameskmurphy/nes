import logging

from nes.instructions import INSTRUCTION_SET, PyNamedInstruction, AddressModes

#from nes import LOG_CPU

class MOS6502:
    """
    Software emulator for MOS Technologies 6502 CPU

    References:
       [1] https://www.masswerk.at/6502/6502_instruction_set.html
       [2] http://www.obelisk.me.uk/6502/addressing.html
       [3] https://www.csh.rit.edu/~moffitt/docs/6502.html

       [4] V-flag:  http://www.6502.org/tutorials/vflag.html
       [5] Decimal mode: http://www.6502.org/tutorials/decimal_mode.html
       [6] PC: http://6502.org/tutorials/6502opcodes.html#PC
       [7] http://forum.6502.org/viewtopic.php?t=1708

       [8] Assembler online: https://www.masswerk.at/6502/assembler.html
       [9] CPU startup sequence:  https://www.pagetable.com/?p=410
       [10] B-flag: http://wiki.nesdev.com/w/index.php/Status_flags#The_B_flag
       [11] V-flag: http://www.righto.com/2012/12/the-6502-overflow-flag-explained.html
       [12] JMP indirect 'bug':  http://forum.6502.org/viewtopic.php?f=2&t=6170

       [13] Undocumented opcodes: http://nesdev.com/undocumented_opcodes.txt
       [14] Undocumented opcodes: http://www.ffd2.com/fridge/docs/6502-NMOS.extra.opcodes

       [15] Amazing timing data: http://www.6502.org/users/andre/petindex/local/64doc.txt

       [16] Undocumented opcodes: http://hitmen.c02.at/files/docs/c64/NoMoreSecrets-NMOS6510UnintendedOpcodes-20162412.pdf

    """

    # Masks for the bits in the status register
    SR_N_MASK = 0b10000000  # negative
    SR_V_MASK = 0b01000000  # overflow
    SR_X_MASK = 0b00100000  # unused, but should be set to 1
    SR_B_MASK = 0b00010000  # the "break" flag (indicates BRK was executed, only set on the stack copy)
    SR_D_MASK = 0b00001000  # decimal
    SR_I_MASK = 0b00000100  # interrupt disable
    SR_Z_MASK = 0b00000010  # zero
    SR_C_MASK = 0b00000001  # carry

    # some useful memory locations
    STACK_PAGE = 0x0100           # stack is held on page 1, from 0x0100 to 0x01FF
    IRQ_BRK_VECTOR_ADDR = 0xFFFE  # start of 16 bit location containing the address of the IRQ/BRK interrupt handler
    RESET_VECTOR_ADDR = 0xFFFC    # start of 16 bit location containing the address of the RESET handler
    NMI_VECTOR_ADDR = 0xFFFA      # start of 16 bit location of address of the NMI (non maskable interrupt) handler

    # 6502 is little endian (least significant byte first in 16bit words)
    LO_BYTE = 0
    HI_BYTE = 1

    # cycles taken to do the NMI or IRQ interrupt - (this is a guess, based on BRK, couldn't find a ref for this!)
    INTERRUPT_REQUEST_CYCLES = 7

    OAM_DMA_CPU_CYCLES = 513

    def __init__(self, memory, support_BCD=False, undocumented_support_level=1, aax_sets_flags=False, stack_underflow_causes_exception=True):

        # memory is user-supplied object with read and write methods, allowing for memory mappers, bank switching, etc.
        self.memory = memory

        # create a map from bytecodes to functions for the instruction set
        self.instructions = self._make_bytecode_dict()

        # User-accessible registers
        self.A = None  # accumulator
        self.X = None  # X register
        self.Y = None  # Y register

        # Indirectly accessible registers
        self.PC = None     # program counter (not valid until a reset() has occurred)
        self.SP = None     # stack pointer (8-bit, but the stack is in page 1 of mem, starting at 0x01FF and counting backwards to 0x0100)

        # Flags
        # (stored as an 8-bit register in the CPU)
        # (use _status_[to/from]_byte to convert to 8-bit byte for storage on stack)
        self.N = None
        self.V = None
        self.D = None
        self.I = None
        self.Z = None
        self.C = None

        # CPU cycles since the processor was started or reset
        self.cycles_since_reset = None
        self.started = False

        # debug
        self._previous_PC = 0

        # control behaviour of the cpu
        self.support_BCD = support_BCD
        self.aax_sets_flags = aax_sets_flags
        self.undocumented_support_level = undocumented_support_level
        self.stack_underflow_causes_exception = stack_underflow_causes_exception


    def reset(self):
        """
        Resets the CPU
        """
        # read the program counter from the RESET_VECTOR_ADDR
        self.PC = self._read_word(self.RESET_VECTOR_ADDR)

        # clear the registers
        self.A = 0  # accumulator
        self.X = 0  # X register
        self.Y = 0  # Y register

        # stack pointer (8-bit, but the stack is in page 1 of mem, starting at 0x01FF and counting backwards to 0x0100)
        # reset does three stack pops, so this is set to 0xFD after reset [9]
        self.SP = 0xFD

        # Flags
        # (use _status_[to/from]_byte to convert to 8-bit byte for storage on stack)
        self.N = False
        self.V = False
        self.D = False
        self.I = True   # CPU should "come up with interrupt disable bit set" [7]
        self.Z = False
        self.C = False

        # CPU cycles since the processor was started or reset
        # reset takes 7 cycles [9]
        self.cycles_since_reset = 7


    def _make_bytecode_dict(self):
        """
        Translates the instruction sets into a bytecode->instr dictionary and links the instruction opcodes
        to the functions in this object that execute them (this is done by instruction name).
        """
        instructions = [None] * 256
        for _, instr_set in INSTRUCTION_SET.items():
            for mode, instr in instr_set.modes.items():
                if type(instr.bytecode) == list:
                    # some of the undocumented opcodes have multiple aliases, so in that case a list of
                    # opcodes is supplied
                    for bytecode in instr.bytecode:
                        instructions[bytecode] = PyNamedInstruction(name=instr_set.name,
                                                             bytecode=bytecode,
                                                             mode=mode,
                                                             size_bytes=instr.size_bytes,
                                                             cycles=instr.cycles,
                                                             function=getattr(self, "_{}".format(instr_set.name)),
                                                             )

                else:
                    instructions[instr.bytecode] = PyNamedInstruction(name=instr_set.name,
                                                               bytecode=instr.bytecode,
                                                               mode=mode,
                                                               size_bytes=instr.size_bytes,
                                                               cycles=instr.cycles,
                                                               function=getattr(self, "_{}".format(instr_set.name)),
                                                               )
        return instructions

    def print_status(self):
        """
        Prints a human-readable summary of the CPU status
        """
        print("A: ${0:02x}     X: ${0:02x}     Y: ${0:02x}".format(self.A, self.X, self.Y))
        print("SP: ${:x}".format(self.SP))
        print("STACK: (head) ${0:02x}".format(self.memory.read(self.STACK_PAGE + self.SP)))
        if 0xFF - self.SP > 0:
            print("              ${:x}".format(self.memory.read(self.STACK_PAGE + self.SP + 1)))
        if 0xFF - self.SP > 1:
            print("              ${:x}".format(self.memory.read(self.STACK_PAGE + self.SP + 2)))
        print("Flags:  NV-BDIZC      as byte:  ${:x}".format(self._status_to_byte()))
        print("        {0:08b}".format(self._status_to_byte()))

        print()
        cur_bytecode = self.memory.read(self._previous_PC)
        cur_instr = self.instructions[cur_bytecode]
        cur_data = self.memory.read_block(self._previous_PC + 1, bytes=cur_instr.size_bytes - 1)
        print("last PC: ${:x}    Instr @ last PC: ${:x} - ".format(self._previous_PC, cur_bytecode), end="")
        print(self.format_instruction(cur_instr, cur_data))

        bytecode = self.memory.read(self.PC)
        instr = self.instructions[bytecode]
        data = self.memory.read_block(self.PC + 1, bytes=instr.size_bytes - 1)
        print("next PC: ${:x}    Instr @ next PC: ${:x} - ".format(self.PC, bytecode), end="")
        print(self.format_instruction(instr, data))
        print("cycles: {}".format(self.cycles_since_reset))

    def format_instruction(self, instr, data, caps=True):
        line = ""
        name = instr.name if not caps else instr.name.upper()
        line += '{} '.format(name)
        if instr.mode == AddressModes.IMMEDIATE:
            line += '#${0:02X}'.format(data[0])
        elif instr.mode == AddressModes.ZEROPAGE:
            line += '${0:02X}'.format(data[0])
        elif instr.mode == AddressModes.ZEROPAGE_X:
            line += '${0:02X},X'.format(data[0])
        elif instr.mode == AddressModes.ZEROPAGE_Y:
            line += '${0:02X},Y'.format(data[0])
        elif instr.mode == AddressModes.ABSOLUTE:
            line += '${0:04X}'.format(self._from_le(data))
        elif instr.mode == AddressModes.ABSOLUTE_X:
            line += '${0:04X},X'.format(self._from_le(data))
        elif instr.mode == AddressModes.ABSOLUTE_Y:
            line += '${0:04X},Y'.format(self._from_le(data))
        elif instr.mode == AddressModes.INDIRECT_X:
            line += '(${:02X},X) @ {:02X} = {:04X}'.format(data[0], data[0], self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True))
        elif instr.mode == AddressModes.INDIRECT_Y:
            line += '(${:02X}),Y = {:04X} @ {:04X}'.format(data[0], self._read_word(data[0], wrap_at_page=True), (self._read_word(data[0], wrap_at_page=True) + self.Y) & 0xFFFF)
        elif instr.mode == AddressModes.INDIRECT:
            line += '(${0:04X})'.format(self._from_le(data))
        elif instr.mode == AddressModes.IMPLIED:
            line += ''
        elif instr.mode == AddressModes.ACCUMULATOR:
            line += 'A'
        elif instr.mode == AddressModes.RELATIVE:
            line += '${0:02X} (-> ${1:04X})'.format(self._from_2sc(data[0]), self.PC + 2 + self._from_2sc(data[0]))
        return line

    def log_line(self):
        """
        Generates a log line in the format of nestest
        """
        str = "{0:04X}  ".format(self.PC)
        bytecode = self.memory.read(self.PC)

        instr = self.instructions[bytecode]
        data = self.memory.read_block(self.PC + 1, bytes=instr.size_bytes - 1)

        str += "{0:02X} ".format(bytecode)
        str += "{0:02X} ".format(data[0]) if len(data) > 0 else "   "
        str += "{0:02X}  ".format(data[1]) if len(data) > 1 else "    "
        str += self.format_instruction(instr, data)

        while len(str) < 48:
            str += " "

        str += "A:{:02X} X:{:02X} Y:{:02X} P:{:02X} SP:{:02X} PPU:---,--- CYC:{:d}".format(self.A,
                                                                                           self.X,
                                                                                           self.Y,
                                                                                           self._status_to_byte(),
                                                                                           self.SP,
                                                                                           self.cycles_since_reset
                                                                                           )
        return str

    def oam_dma_pause(self):
        cycles = self.OAM_DMA_CPU_CYCLES + self.cycles_since_reset % 2
        self.cycles_since_reset += cycles
        return cycles

    def set_reset_vector(self, reset_vector):
        """
        Sets the reset vector (at fixed mem address), which tells the program counter where to start on a reset
        :param reset_vector: 16-bit address to which PC will be set after a reset
        """
        self.memory.write(self.RESET_VECTOR_ADDR, reset_vector & 0x00FF)  # low byte
        self.memory.write(self.RESET_VECTOR_ADDR + 1, (reset_vector & 0xFF00) >> 8)  # high byte

    @staticmethod
    def _from_le(data):
        """
        Create an integer from a little-endian two byte array
        :param data: two-byte little endian array
        :return: an integer in the range 0-65535
        """
        return (data[MOS6502.HI_BYTE] << 8) + data[MOS6502.LO_BYTE]

    def _read_word(self, addr, wrap_at_page=False):
        """
        Read a word at an address and return it as an integer
        If wrap_at_page is True then if the address is 0xppFF, then the word will be read from 0xppFF and 0xpp00
        """
        if wrap_at_page and (addr & 0xFF) == 0xFF:
            # will wrap at page boundary
            byte_lo = self.memory.read(addr)
            byte_hi = self.memory.read(addr & 0xFF00)  # read the second (hi) byte from the start of the page
        else:
            byte_lo = self.memory.read(addr)
            byte_hi = self.memory.read(addr + 1)
        return byte_lo + (byte_hi << 8)

    def trigger_nmi(self):
        """
        Trigger a non maskable interrupt (NMI)
        """
        self._interrupt(self.NMI_VECTOR_ADDR)
        self.cycles_since_reset += self.INTERRUPT_REQUEST_CYCLES
        return self.INTERRUPT_REQUEST_CYCLES

    def trigger_irq(self):
        """
        Trigger a maskable hardware interrupt (IRQ); if interrupt disable bit (self.I) is set, ignore
        """
        if not self.I:
            self._interrupt(self.IRQ_BRK_VECTOR_ADDR)
            self.cycles_since_reset += self.INTERRUPT_REQUEST_CYCLES
            return self.INTERRUPT_REQUEST_CYCLES
        else:
            return 0  # ignored!

    def run_next_instr(self):
        """
        Decode and run the next instruction at the program counter, updating the number of processor
        cycles that have elapsed.  Instructions are taken as atomic, since the 6502 will complete them
        before it responds to interrupts.
        """
        # if the CPU has not yet been started, reset it, which will correctly initialize the PC.
        if not self.started:
            self.started=True
            self.reset()

        # count any extra cycles we incur due to page overruns and branches
        extra_cycles = 0

        # read instruction at current PC
        bytecode = self.memory.read(self.PC)

        # translate to instruction (+ data if needed)
        instr = self.instructions[bytecode]
        #data = self.memory.read_block(self.PC + 1, bytes=instr.size_bytes - 1)
        data = bytearray(2)
        if instr.size_bytes >= 2:
            data[0] = self.memory.read(self.PC + 1)
        if instr.size_bytes == 3:
            data[1] = self.memory.read(self.PC + 2)


        # upon retrieving the opcode, the 6502 immediately increments PC by the opcode size:
        self._previous_PC = self.PC
        self.PC += instr.size_bytes

        # create the right argument based on the addressing mode
        # don't need to know yet if the argument is an address or a literal - the instruction determines this
        immediate = False
        if instr.mode == AddressModes.IMPLIED:
            # all implied instructions are self-contained 1-byte instructions
            arg = None
        elif instr.mode == AddressModes.ACCUMULATOR:
            # the instructions with accumulator targets usually have a memory address as a target, if
            # None is supplied, they target the accumulator
            arg = None
        elif instr.mode == AddressModes.RELATIVE:
            # all relative instructions are control flow instructions that take a relative address
            arg = data[0]
        elif instr.mode == AddressModes.IMMEDIATE:
            arg = data[0]
            immediate = True
        else:
            # memory loading modes:
            address = None
            if instr.mode == AddressModes.ZEROPAGE:
                address = data[0]
            elif instr.mode == AddressModes.ZEROPAGE_X:
                address = (data[0] + self.X) & 0xFF
            elif instr.mode == AddressModes.ZEROPAGE_Y:
                address = (data[0] + self.Y) & 0xFF
            elif instr.mode == AddressModes.ABSOLUTE:
                address = self._from_le(data)
            elif instr.mode == AddressModes.ABSOLUTE_X:
                address = (self._from_le(data) + self.X) & 0xFFFF
                if data[self.LO_BYTE] + self.X > 0xFF and instr.cycles > int(instr.cycles):
                    # extra cycles if cross the page boundary
                    extra_cycles += 1
            elif instr.mode == AddressModes.ABSOLUTE_Y:
                address = (self._from_le(data) + self.Y) & 0xFFFF
                if data[self.LO_BYTE] + self.Y > 0xFF and instr.cycles > int(instr.cycles):
                    # extra cycles if cross the page boundary
                    extra_cycles += 1
            elif instr.mode == AddressModes.INDIRECT:
                # only used for jmp instructions
                # has the jump indirect bug [12] which means it cannot cross page boundaries and instead
                # wraps around, e.g. read from 0x12ff reads 0x12ff and 0x1200
                #address =
                address = self._read_word(self._from_le(data), wrap_at_page=True)
                #address = self._from_le(self.memory.read_block(self._from_le(data), bytes=2))
            elif instr.mode == AddressModes.INDIRECT_X:
                address = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            elif instr.mode == AddressModes.INDIRECT_Y:
                m = self._read_word(data[0], wrap_at_page=True)
                address = (m + self.Y) & 0xFFFF
                if (m & 0xFF) + self.Y > 0xFF and instr.cycles > int(instr.cycles):
                    # extra cycles if cross the page boundary
                    extra_cycles += 1

            arg = address

        add_cycles = instr.function(arg, immediate)
        extra_cycles += add_cycles if add_cycles else 0

        # update cycle count
        self.cycles_since_reset += int(instr.cycles) + extra_cycles

        # logging
        #logging.log(LOG_CPU, self.log_line(), extra={"source": "CPU"})

        return int(instr.cycles) + extra_cycles

    def _status_to_byte(self, b_flag=0):
        """
        Puts the status register into an 8-bit value.  Bit 6 is set high always, bit 5 (the "B flag") is set according
        to the b_flag argument.  This should be high if called from an instruction (PHP or BRK) instruction, low if
        the call (to push the status to the stack, which is the only use of this instruction within the CPU) came from
        a hardware interrupt (IRQ or NMI).
        """
        return (  self.N * self.SR_N_MASK
                + self.V * self.SR_V_MASK
                + self.SR_X_MASK              # the unused bit should always be set high
                + b_flag * self.SR_B_MASK     # the "B flag" should be set high if called from PHP or BRK [10] low o/w
                + self.D * self.SR_D_MASK
                + self.I * self.SR_I_MASK
                + self.Z * self.SR_Z_MASK
                + self.C * self.SR_C_MASK) & 0xFF   # this final and forces it to be treated as unsigned

    def _status_from_byte(self, sr_byte):
        """
        Sets the processor status from an 8-bit value as found on the stack.
        Bit 5 (B flag) is NEVER set in the status register (but is on the stack), so it is ignored here
        """
        self.N = (sr_byte & self.SR_N_MASK) > 0
        self.V = (sr_byte & self.SR_V_MASK) > 0
        self.D = (sr_byte & self.SR_D_MASK) > 0
        self.I = (sr_byte & self.SR_I_MASK) > 0
        self.Z = (sr_byte & self.SR_Z_MASK) > 0
        self.C = (sr_byte & self.SR_C_MASK) > 0

    def push_stack(self, v):
        """
        Push a byte value onto the stack
        """
        self.memory.write(self.STACK_PAGE + self.SP, v)
        #if self.SP == 0:
        #    if self.stack_overflow_causes_exception:
        #        raise OverflowError("Stack overflow")
        #    else:
        #        self.SP = 0xFF
        self.SP = (self.SP - 1) & 0xFF

    def pop_stack(self):
        """
        Pop (aka 'pull' in 6502 parlance) a byte from the stack
        """
        if self.SP == 0xFF and self.stack_underflow_causes_exception:
            raise OverflowError("Stack underflow")
        self.SP = (self.SP + 1) & 0xFF
        v = self.memory.read(self.STACK_PAGE + self.SP)
        return v

    @staticmethod
    def _neg(v):
        """
        Is the value of v negative in 2s complement (i.e. is bit 7 high)?
        :return: true if v is negative (true if bit 7 of v is 1)
        """
        return (v & 0b10000000) > 0

    @staticmethod
    def _from_2sc(v):
        """
        Convert a 2's complement number to a signed integer
        """
        #neg = (v & 0b10000000) > 0
        #return (v & 0b01111111) if not neg else (v & 0b01111111) - 128
        return (v & 0b01111111) - (v & 0b10000000)

    @staticmethod
    def _to_bcd(v):
        """
        Convert v from an integer (in range 0-100) to (8 bit) binary coded decimal (BCD) representation
        """
        h = int(v / 10) % 10
        l = v - h * 10
        return (h << 4) + l

    @staticmethod
    def _from_bcd(v):
        """
        Convert from 8 bit BCD to integer
        """
        tens = (v & 0xF0) >> 4
        ones = v & 0x0F
        return tens * 10 + ones

    def _set_zn(self, v):
        """
        Sets the Z and N flags from a result value v
        """
        self.Z = (v & 0xFF) == 0  # only care about the bottom 8 bits being zero
        self.N = (v & 0b10000000) > 0

    ##################  The instructions (and their helper functions)  #################################################

    def _adc(self, arg, immediate):
        """
        Add to accumulator with carry.  Result goes into accumulator.
        :param arg: value to be added to accumulator (cannot be None)
        """
        v = self.memory.read(arg) if not immediate else arg

        if self.D and self.support_BCD:
            # On the NES, the D flag has no effect - set support_BCD to False
            # the following horror is based on the behaviour described in [5], Appendix A
            result_bin = (self.A + v + self.C) & 0xFF
            al = (self.A & 0x0F) + (v & 0x0F) + self.C
            if al >= 0x0A:
                al = ((al + 0x06) & 0x0F) + 0x10
            a1 = (self.A & 0xF0) + (v & 0xF0) + al
            a2 = self._from_2sc(self.A & 0xF0) + self._from_2sc(v & 0xF0) + al

            # the value of the V flag in bcd mode is undocumented on the 6502
            # but, according to [5] the following should be correct:
            self.N = (a2 & 0b10000000) > 0
            self.V = ~(-128 <= a2 <= 127)

            if a1 >= 0xA0:
                a1 += 0x60
            self.C = a1 > 255
            result = a1 & 0xFF
            self.Z = result_bin == 0
        else:
            # binary mode (standard)
            result = self.A + v + self.C
            self.C = result > 255
            self.V = (self._neg(self.A) == self._neg(v)) and (self._neg(self.A) != self._neg(result))
            self._set_zn(result)

        # status
        # setting N and Z flags in the usual way is valid in BCD mode because "the N flag contains the high bit of
        # the result of the instruction" [5]


        # result
        self.A = result & 0xFF

    def _and(self, arg, immediate):
        """
        Bitwise AND of accumulator and arg.  Result goes into accumulator.
        """
        v = self.memory.read(arg) if not immediate else arg
        self.A = self.A & v
        self._set_zn(self.A)

    def _asl(self, addr, _):
        """
        Shift left one bit.
        """
        v = self.A if addr is None else self.memory.read(addr)
        result = v << 1

        # status
        self.C = result > 255    # top bit of original is put into carry flag
        self._set_zn(result)

        res_8bit = result & 0xFF

        if addr is None:
            # target the accumulator
            self.A = res_8bit
        else:
            self.memory.write(addr, res_8bit)

    def _jump_relative(self, condition, offset_2sc):
        """
        Jump by offset_2sc (in 2s complement) if the condition is true
        :return: number of extra cycles incurred by this branch conditional
        """
        extra_cycles = 0
        if condition:
            #print("jump")
            extra_cycles = 1  # taking a branch takes at least 1 cycle
            prev_pc_page = self.PC & 0xFF00  # should this be the PC before the branch instruction or after it?
            self.PC += self._from_2sc(offset_2sc)  # jumps to the address of the branch + 2 + offset (which is correct)
            if prev_pc_page != self.PC & 0xFF00:
                # but it takes two cycles if the memory page changes
                extra_cycles = 2
        #else:
        #    print("no jump")
        return extra_cycles

    def _bcc(self, offset, _):
        """
        Branch on carry clear
        """
        return self._jump_relative(not self.C, offset)

    def _bcs(self, offset, _):
        """
        Branch on carry set
        """
        return self._jump_relative(self.C, offset)

    def _beq(self, offset, _):
        """
        Branch if zero flag is set
        """
        return self._jump_relative(self.Z, offset)

    def _bit(self, addr, _):
        """
        Manipulates the status register by setting the N and V flags to those bits of the value in the address
        given, and sets the zero flag if A & v == 0
        """
        v = self.memory.read(addr)
        self.N = (v & self.SR_N_MASK) > 0
        self.V = (v & self.SR_V_MASK) > 0
        self.Z = (self.A & v) == 0

    def _bmi(self, offset, _):
        """
        Branch on result minus (i.e. negative flag N is set)
        """
        return self._jump_relative(self.N, offset)

    def _bne(self, offset, _):
        """
        Branch if zero flag is not set
        """
        return self._jump_relative(not self.Z, offset)

    def _bpl(self, offset, _):
        """
        Branch on result positive (i.e. negative flag N is not set)
        """
        #print(self.N, not self.N)
        return self._jump_relative(not self.N, offset)

    def _interrupt(self, interrupt_vector, is_brk=False):
        """
        Interrupt routine, followed (with variations) by NMI, IRQ and BRK
          1)
        """
        # push PC + 1 to the stack, high bit first
        v = self.PC + (1 if is_brk else 0)
        self.push_stack((v & 0xFF00) >> 8)  # high byte
        self.push_stack(v & 0x00FF)  # low byte
        # push the processor status to the stack
        # BUT note that the B flag ON THE STACK COPY ONLY is now set
        sr = self._status_to_byte(b_flag=True if is_brk else False)
        self.push_stack(sr)
        #addr = self._from_le(self.memory.read_block(interrupt_vector, bytes=2))
        addr = self._read_word(interrupt_vector)
        self.PC = addr
        if not is_brk:
            # if this is not a brk instruction, set the interrupt disable flag
            self.I = True

    def _brk(self, _, __):
        """
        Force break, which simulates an interrupt request.
        BRK, unlike other interrupts (IRQ and NMI), pushes PC + 1 to the stack (high byte first as usual).
        The reason for this may have been to allow brk to be dropped in in place of two byte instructions to allow
        debugging, but it is a quirk of the BRK instruction.  BRK also sets the B flag in the value of SR pushed to
        the stack
        """
        #
        self._interrupt(self.IRQ_BRK_VECTOR_ADDR, is_brk=True)

    def _bvc(self, offset, _):
        """
        Branch on on overflow clear (V == 0)
        """
        return self._jump_relative(not self.V, offset)

    def _bvs(self, offset, _):
        """
        Branch on on overflow set (V == 1)
        """
        return self._jump_relative(self.V, offset)

    def _clc(self, _, __):
        """
        Clear carry flag (set C:=0)
        """
        self.C = False

    def _cld(self, _, __):
        """
        Clear decimal flag (set D:=0)
        """
        self.D = False

    def _cli(self, _, __):
        """
        Clear interrupt disable flag (set I:=0)
        """
        self.I = False

    def _clv(self, _, __):
        """
        Clear value flag (set V:=0)
        """
        self.V = False

    def _compare(self, v0, v):
        self._set_zn(v0 - v)
        self.C = v0 >= v

    def _cmp(self, arg, immediate):
        """
        Sets flags as if a subtraction A - v was performed.  The N flag is valid iff the numbers are signed.
        :return:
        """
        v = self.memory.read(arg) if not immediate else arg
        self._compare(self.A, v)

    def _cpx(self, arg, immediate):
        """
        Sets flags as if a subtraction A - v was performed.  The N flag is valid iff the numbers are signed.
        :return:
        """
        v = self.memory.read(arg) if not immediate else arg
        self._compare(self.X, v)

    def _cpy(self, arg, immediate):
        """
        Sets flags as if a subtraction A - v was performed.  The N flag is valid iff the numbers are signed.
        :return:
        """
        v = self.memory.read(arg) if not immediate else arg
        self._compare(self.Y, v)

    def _dec(self, addr, _):
        """
        Decrement memory in addr by 1
        :param addr:
        :param _:
        :return:
        """
        v = (self.memory.read(addr) - 1) & 0xFF
        self._set_zn(v)
        self.memory.write(addr, v)

    def _dex(self, _, __):
        """
        Decrement X by 1
        :param addr:
        :param _:
        :return:
        """
        self.X = (self.X - 1) & 0xFF
        self._set_zn(self.X)

    def _dey(self, _, __):
        """
        Decrement Y by 1
        :param addr:
        :param _:
        :return:
        """
        self.Y = (self.Y - 1) & 0xFF
        self._set_zn(self.Y)

    def _eor(self, arg, immediate):
        """
        XOR A with value and put result back into A
        :param addr:
        :param _:
        :return:
        """
        v = self.memory.read(arg) if not immediate else arg
        self.A = v ^ self.A
        self._set_zn(self.A)

    def _inc(self, addr, _):
        """
        Increment memory in addr by 1
        :param addr:
        :param _:
        :return:
        """
        v = (self.memory.read(addr) + 1) & 0xFF
        self._set_zn(v)
        self.memory.write(addr, v)

    def _inx(self, _, __):
        """
        Increment X by 1
        :param addr:
        :param _:
        :return:
        """
        self.X = (self.X + 1) & 0xFF
        self._set_zn(self.X)

    def _iny(self, _, __):
        """
        Increment Y by 1
        :param addr:
        :param _:
        :return:
        """
        self.Y = (self.Y + 1) & 0xFF
        self._set_zn(self.Y)

    def _jmp(self, addr, _):
        """
        Jump to the (16 bit) address addr.  In the case of jump instructions jmp and jsr,
        "absolute" addressing is more like immediate addressing, in that the jump goes directly
        to the memory address specified rather than reading the value there and using that (which
        is "indirect" addressing in the case of jumps, so this function behaves always like it got
        an immediate address
        """
        self.PC = addr

    def _jsr(self, addr, _):
        """
        Jump to a subroutine at the value in memory[addr].  Addr here is an absolute (16 bit) location.
        In the case of jump instructions jmp and jsr,
        "absolute" addressing is more like immediate addressing, in that the jump goes directly
        to the memory address specified rather than reading the value there and using that (which
        is "indirect" addressing in the case of jumps, so this function behaves always like it got
        an immediate address
        """
        # save PC - 1 to the stack, high byte first
        v = self.PC - 1
        self.push_stack((v & 0xFF00) >> 8)
        self.push_stack(v & 0x00FF)
        self.PC = addr

    def _lda(self, arg, immediate):
        """
        Load A from value / memory
        :return:
        """
        self.A = self.memory.read(arg) if not immediate else arg
        self._set_zn(self.A)

    def _ldx(self, arg, immediate):
        """
        Load X from value / memory
        :return:
        """
        self.X = self.memory.read(arg) if not immediate else arg
        self._set_zn(self.X)

    def _ldy(self, arg, immediate):
        """
        Load Y from value / memory
        :return:
        """
        self.Y = self.memory.read(arg) if not immediate else arg
        self._set_zn(self.Y)

    def _lsr(self, addr, _):
        """
        Logical shift right
        :param addr:
        :param _:
        :return:
        """
        v = self.A if addr is None else self.memory.read(addr)
        result = (v >> 1) & 0xFF

        # status
        self.C = v & 0x01
        self.N = False
        self.Z = result == 0

        if addr is None:
            # target the accumulator
            self.A = result
        else:
            self.memory.write(addr, result)

    def _nop(self, _, __):
        """
        No-op.  This one is easy.
        :return:
        """
        pass

    def _ora(self, arg, immediate):
        """
        Bitwise OR with accumulator; result put into accumulator.
        :return:
        """
        v = self.memory.read(arg) if not immediate else arg
        self.A = self.A | v
        self._set_zn(self.A)

    def _pha(self, _, __):
        """
        Push A onto stack
        :param _:
        :param __:
        :return:
        """
        self.push_stack(self.A)

    def _php(self, _, __):
        """
        Push status register onto stack
        :param _:
        :param __:
        :return:
        """
        v = self._status_to_byte(b_flag=True)  # b-flag should be set True in this case [10]
        self.push_stack(v)

    def _pla(self, _, __):
        """
        Pull A from stack
        :param _:
        :param __:
        :return:
        """
        self.A = self.pop_stack()
        self._set_zn(self.A)

    def _plp(self, _, __):
        """
        Pull processor status from the stack
        :return:
        """
        v = self.pop_stack()
        self._status_from_byte(v)

    def _rol(self, addr, _):
        """
        Rotate one bit left (including carry bit in the rotation, i.e. C rotates into lsb and msb rotates into C)
        :return:
        """
        v = self.A if addr is None else self.memory.read(addr)
        result = (v << 1) + self.C

        # status
        self.C = result > 255
        self._set_zn(result)

        if addr is None:
            # target the accumulator
            self.A = result & 0xFF
        else:
            self.memory.write(addr, result & 0xFF)

    def _ror(self, addr, _):
        """
        Rotate one bit right (including carry bit in the rotation, i.e. C rotates into msb and lsb rotates into C)
        :return:
        """
        v = self.A if addr is None else self.memory.read(addr)
        result = (v >> 1) + (self.C << 7)

        # status
        self.C = v & 0x01
        self._set_zn(result)

        if addr is None:
            # target the accumulator
            self.A = result & 0xFF
        else:
            self.memory.write(addr, result & 0xFF)

    def _rti(self, _, __):
        """
        Return from an interrupt.  Gets the PC of the last execution point and the flag register from the
        stack.  (PC is stored on the stack, not PC-1 as with jsr/rts)
        :return:
        """
        flags = self.pop_stack()
        addr_lo = self.pop_stack()
        addr_hi = self.pop_stack()
        self._status_from_byte(flags)
        self.PC = (addr_hi << 8) + addr_lo

    def _rts(self, _, __):
        """
        Returns from a subroutine (see jsr for the jump subroutine)
        :return:
        """
        # fetch PC-1 from the stack, low byte first
        addr_lo = self.pop_stack()
        addr_hi = self.pop_stack()
        # restore PC to the stack
        self.PC = (addr_hi << 8) + addr_lo + 1

    def _sbc(self, arg, immediate):
        """
        Subtract memory plus carry flag from A and put the result in A (i.e. A := A - M - ~C).
        The carry flag is set if A - M - ~C >= 0, i.e. if no borrow is necessary (allows chaining of
        subtract instructions).
        The overflow (V) flag is set if there is a (signed) overflow.
        Overflow occurs when the result is either too negative or too positive to be held in the available 8 bits.
        This can happen in two cases:
          1) when A is +ve and v is -ve; this should create a +ve number, so if result is -ve that is overflow
          2) when A is -ve and v is +ve; this should create a -ve number, so if result is +ve that is overflow
        """
        v = self.memory.read(arg) if not immediate else arg
        borrow = not self.C   # incoming borrow is indicated by not Carry  (borrow is either 0 or 1)

        result = self.A - v - borrow     # arithmetic is done unsigned
        self.C = result >= 0  # not Carry == borrow; borrow if res<0, so C==not(res<0) == res>=0
        # overflow - see notes in description above
        # I think this is correct and that the borrow doesn't matter here
        self.V = (self._neg(self.A) != self._neg(v)) and (self._neg(v) == self._neg(result))
        self._set_zn(result)

        if self.D and self.support_BCD:
            # according to [5], all the flags behave as if in binary mode on the 6502 even in BCD mode
            al = (self.A & 0x0F) - (v & 0x0F) + self.C - 1
            if al < 0:
                al = ((al - 0x06) & 0x0F) - 0x10
            a = (self.A & 0xF0) - (v & 0xF0) + al
            if a < 0:
                a -= 0x60
            result = a
        else:
            # the NES can have the D bit set and acts as in binary mode (I think)
            pass
            #raise Exception("BCD mode not supported (start CPU with support_BCD=True)")

        self.A = result & 0xFF

    def _sec(self, _, __):
        """
        Set carry flag
        """
        self.C = True

    def _sed(self, _, __):
        """
        Set decimal flag
        """
        self.D = True

    def _sei(self, _, __):
        """
        Set interrupt disable flag
        """
        self.I = True

    def _sta(self, addr, _):
        """
        Store A in memory.  No flags are set.
        :return:
        """
        self.memory.write(addr, self.A)

    def _stx(self, addr, _):
        """
        Store X in memory.  No flags are set.
        :return:
        """
        self.memory.write(addr, self.X)

    def _sty(self, addr, _):
        """
        Store Y in memory.  No flags are set.
        :return:
        """
        self.memory.write(addr, self.Y)

    def _tax(self, _, __):
        """
        Transfer A to X
        :return:
        """
        self.X = self.A
        self._set_zn(self.X)

    def _tay(self, _, __):
        """
        Transfer A to Y
        :return:
        """
        self.Y = self.A
        self._set_zn(self.Y)

    def _tsx(self, _, __):
        """
        Transfer SP to X
        :return:
        """
        self.X = self.SP
        self._set_zn(self.X)

    def _txa(self, _, __):
        """
        Transfer X to A
        :return:
        """
        self.A = self.X
        self._set_zn(self.A)

    def _txs(self, _, __):
        """
        Transfer X to SP
        :return:
        """
        self.SP = self.X

    def _tya(self, _, __):
        """
        Transfer Y to A
        :return:
        """
        self.A = self.Y
        self._set_zn(self.A)

    ################################## The undocumented instructions (see [13] and others) #############################
    # todo: add the undocumented-level feature to the instruction list and remove the per-function tests here

    def _dop(self, _, __):
        """
        Undocumented.
        Double NOP instruction.  Luckily it is easy to implement!
        """
        pass

    def _top(self, _, __):
        """
        Undocumented.
        Triple NOP instruction.
        """
        pass

    def _kil(self, _, __):
        """
        Undocumented.
        Shuts down the processor.  No recovery is possible after this has executed, short of a reset.
        """
        if self.undocumented_support_level >= 1:
            raise ValueError("KIL instruction.  Processor halted.")

    def _lax(self, arg, immediate):
        """
        Undocumented.
        Load A and X from value / memory
        :return:
        """
        if self.undocumented_support_level >= 1:
            v = self.memory.read(arg) if not immediate else arg
            self.A = v
            self.X = v
            self._set_zn(self.A)

    def _aax(self, addr, _):
        """
        Undocumented.
        AND X register with accumulator and store result in memory.
        Status flags: N,Z  (or are they?  nestest does not think so...)
        """
        if self.undocumented_support_level >= 1:
            v = self.A & self.X
            self.memory.write(addr, v)
            if self.aax_sets_flags:
                # the behaviour of this seems unclear, nestest does not think it does this, [13] does
                self._set_zn(v)

    def _dcp(self, addr, _):
        """
        Undocumented.
        This opcode DECs the contents of a memory location and then CMPs the result with the A register.
        Equivalent to DEC oper, CMP oper [14]
        """
        if self.undocumented_support_level >= 1:
            v = (self.memory.read(addr) - 1) & 0xFF
            self.memory.write(addr, v)
            self._compare(self.A, v)

    def _isc(self, addr, _):
        """
        Undocumented.
        Increase memory by one, then subtract memory from accumulator (with borrow). Status flags: N,V,Z,C
        """
        if self.undocumented_support_level >= 1:
            v = (self.memory.read(addr) + 1) & 0xFF
            self.memory.write(addr, v)
            self._sbc(v, immediate=True)

    def _slo(self, addr, _):
        """
        Undocumented.
        Shift left one bit in memory, then OR accumulator with memory.  Status flags: N,Z,C
        Equivalent to ASL, ORA
        """
        if self.undocumented_support_level >= 1:
            self._asl(addr, None)
            self._ora(self.memory.read(addr), immediate=True)

    def _rla(self, addr, _):
        """
        Undocumented.
        RLA ROLs the contents of a memory location and then ANDs the result with the accumulator.
        Equivalent to ROL, AND
        """
        if self.undocumented_support_level >= 1:
            self._rol(addr, None)
            self._and(self.memory.read(addr), immediate=True)

    def _rra(self, addr, _):
        """
        Undocumented.
        RRA RORs the contents of a memory location and then ADCs the result with the accumulator.
        Equivalent to ROR, ADC
        """
        if self.undocumented_support_level >= 1:
            self._ror(addr, None)
            self._adc(self.memory.read(addr), immediate=True)

    def _sre(self, addr, _):
        """
        Undocumented.
        Shift right one bit in memory, then EOR accumulator with memory.
        Equivalent to LSR, EOR
        """
        if self.undocumented_support_level >= 1:
            self._lsr(addr, None)
            self._eor(self.memory.read(addr), immediate=True)

    ##################### The arcane undocumented instructions (see [13] and others) ###################################

    def _arr(self, arg, _):
        """
        UNTESTED
        Undocumented.  Mostly used for piracy (jk).
        ANDs the contents of the A register with an immediate value and then RORs the result.
        Equivalent to AND oper, ROR A
        """
        if self.undocumented_support_level >= 2:
            self._and(arg, immediate=True)
            self._ror(None, None)

    def _asr(self, arg, _):
        """
        UNTESTED
        Undocumented.
        ANDs the contents of the A register with an immediate value and then LSRs the result.
        Equivalent to AND oper, LSR A
        """
        if self.undocumented_support_level >= 2:
            self._and(arg, immediate=True)
            self._lsr(None, None)

    def _atx(self, arg, _):
        """
        UNTESTED
        Undocumented.
        ORs the A register with #$EE, ANDs the result with an immediate value, and then stores the result in
        both A and X.
        Equivalent to ORA #$EE, AND oper, TAX
        """
        if self.undocumented_support_level >= 2:
            self._and(arg | 0xEE, immediate=True)
            self.X = self.A

    def _aac(self, arg, _):
        """
        UNTESTED
        Undocumented.
        ANDs the contents of the A register with an immediate value and then
        moves bit 7 of A into the Carry flag.  This opcode works basically
        identically to AND #immed. except that the Carry flag is set to the same
        state that the Negative flag is set to.  [14]
        """
        if self.undocumented_support_level >= 2:
            self.A = self.A & arg
            self._set_zn(self.A)
            self.C = (self.A & 0b10000000) > 0

    def _axa(self, addr, _):
        """
        UNTESTED
        Undocumented.
        Sores the result of A AND X AND the high byte of the target address of the operand +1 in memory [14, 15]
        WARNING:  There seem to be multiple conflicting descriptions of this opcode. (see e.g. [13])
        """
        if self.undocumented_support_level >= 2:
            hp1 = (((addr & 0xFF00) >> 8) + 1) & 0xFF
            v = (self.X & self.A) & hp1
            self.memory.write(addr, v)

    def _axs(self, addr, _):
        """
        UNTESTED
        Undocumented.
        AND the contents of the A and X registers (without changing the contents of either register) and
        stores the result in memory. [16]
        """
        if self.undocumented_support_level >= 2:
            self.memory.write(addr, self.A & self.X)

    def _lar(self, addr, _):
        """
        UNTESTED
        Undocumented.
        AND memory with stack pointer, transfer result to accumulator, X register and stack pointer. [16]
        """
        if self.undocumented_support_level >= 2:
            v = self.memory.read(addr) & self.SP
            self.A = v
            self.X = v
            self.SP = v

    def _sxa(self, addr, _):
        """
        UNTESTED
        Undocumented.
        AND X register with the high byte of the target address of the argument + 1. Store the result in memory. [16]
        """
        if self.undocumented_support_level >= 2:
            hp1 = (((addr & 0xFF00) >> 8) + 1) & 0xFF
            self.memory.write(addr, self.X & hp1)

    def _sya(self, addr, _):
        """
        UNTESTED
        Undocumented.
        AND Y register with the high byte of the target address of the argument + 1. Store the result in memory. [16]
        """
        if self.undocumented_support_level >= 2:
            v = self.Y & ((((addr & 0xFF00) >> 8) + 1) & 0xFF)
            self.memory.write(addr, v)
            self._set_zn(v)

    def _xaa(self, arg, _):
        """
        UNTESTED
        Undocumented.
        This opcode ORs the A register with CONST, ANDs the result with X. ANDs the result with an immediate value, and
        then stores the result in A.
        Known to be extremely unstable, including temperature dependent! [16]
        """
        if self.undocumented_support_level >= 2:
            CONST = 0x00
            self.A = (self.A | CONST) & self.X & arg

    def _xas(self, addr, _):
        """
        UNTESTED
        Undocumented.
        ANDs the contents of the A and X registers (without changing the contents
        of either register) and transfers the result to the stack pointer. It then ANDs that result with the
        contents of the high byte of the target address of the operand +1 and stores that final result in
        memory
        """
        if self.undocumented_support_level >= 2:
            hp1 = (((addr & 0xFF00) >> 8) + 1) & 0xFF
            self.SP = self.A & self.X
            self.memory.write(addr, self.SP & hp1)

