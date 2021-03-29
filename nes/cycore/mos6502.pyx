# cython: profile=True, boundscheck=True, nonecheck=False, language_level=3
#import pyximport; pyximport.install()

from .system cimport OAM_DMA, DMC_DMA, DMC_DMA_DURING_OAM_DMA
from nes.instructions import INSTRUCTION_SET, NamedInstruction, AddressModes

cdef class MOS6502:
    """
    Software emulator for MOS Technologies 6502 CPU.  The chip in the NES is a modified version of the 6502 that does
    not support BCD mode (which makes it a bit simpler).

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
    def __init__(self, memory, undocumented_support_level=1, aax_sets_flags=False, stack_underflow_causes_exception=True):

        # memory is user-supplied object with read and write methods, allowing for memory mappers, bank switching, etc.
        self.memory = memory

        # create a map from bytecodes to functions for the instruction set
        self.instructions = self._make_bytecode_dict()
        self.make_instruction_data_tables()

        # User-accessible registers
        self.A = 0  # accumulator
        self.X = 0  # X register
        self.Y = 0  # Y register

        # Indirectly accessible registers
        self.PC = 0     # program counter (not valid until a reset() has occurred)
        self.SP = 0     # stack pointer (8-bit, but the stack is in page 1 of mem, starting at 0x01FF and counting backwards to 0x0100)

        # Flags
        # (stored as an 8-bit register in the CPU)
        # (use _status_[to/from]_byte to convert to 8-bit byte for storage on stack)
        self.N = 0
        self.V = 0
        self.D = 0
        self.I = 0
        self.Z = 0
        self.C = 0

        # CPU cycles since the processor was started or reset
        self.cycles_since_reset = 0

        # control behaviour of the cpu
        self.aax_sets_flags = aax_sets_flags
        self.undocumented_support_level = undocumented_support_level
        self.stack_underflow_causes_exception = stack_underflow_causes_exception

        # reset the cpu
        self.reset()


    def reset(self):
        """
        Resets the CPU
        """
        # read the program counter from the RESET_VECTOR_ADDR
        self.PC = self._read_word(RESET_VECTOR_ADDR, wrap_at_page=False)

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

    cdef int dma_pause(self, int pause_type, int count):
        cdef int cycles
        if pause_type == OAM_DMA:
            cycles = OAM_DMA_CPU_CYCLES + self.cycles_since_reset % 2
        elif pause_type == DMC_DMA:
            #todo: there are some special cases detailed here: https://wiki.nesdev.com/w/index.php/APU_DMC
            cycles = 4
        elif pause_type == DMC_DMA_DURING_OAM_DMA:
            #todo: there are some special cases detailed here: https://wiki.nesdev.com/w/index.php/APU_DMC
            cycles = 2 * count
        self.cycles_since_reset += cycles
        return cycles

    @property
    def cycles_since_reset(self):
        return self.cycles_since_reset

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
                        instructions[bytecode] = NamedInstruction(name=instr_set.name,
                                                                  bytecode=bytecode,
                                                                  mode=mode,
                                                                  size_bytes=instr.size_bytes,
                                                                  cycles=instr.cycles,
                                                                 )
                else:
                    instructions[instr.bytecode] = NamedInstruction(name=instr_set.name,
                                                                    bytecode=instr.bytecode,
                                                                    mode=mode,
                                                                    size_bytes=instr.size_bytes,
                                                                    cycles=instr.cycles,
                                                                   )
        return instructions

    cdef void make_instruction_data_tables(self):
        """
        Fills in some data tables about the instructions in cdef variables; replaces the more pythonic version
        make_bytecode_dict.
        """
        for _, instr_set in INSTRUCTION_SET.items():
            for mode, instr in instr_set.modes.items():
                bytecodes = instr.bytecode if type(instr.bytecode) == list else [instr.bytecode]
                for bytecode in bytecodes:
                    self.instr_size_bytes[bytecode] = instr.size_bytes

    def format_instruction(self, instr, data, caps=True):
        """
        Formats an instruction for logline in the form of nestest logs
        """
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

    def log_line(self, ppu_line="---", ppu_pixel="---"):
        """
        Generates a log line in the format of nestest
        """
        str = "{0:04X}  ".format(self.PC)
        bytecode = self.memory.read(self.PC)

        instr = self.instructions[bytecode]
        data = bytearray(2)
        for i in range(instr.size_bytes - 1):
            data[i] = self.memory.read(self.PC + 1 + i)

        str += "{0:02X} ".format(bytecode)
        str += "{0:02X} ".format(data[0]) if len(data) > 0 else "   "
        str += "{0:02X}  ".format(data[1]) if len(data) > 1 else "    "
        str += self.format_instruction(instr, data)

        while len(str) < 48:
            str += " "

        str += "A:{:02X} X:{:02X} Y:{:02X} P:{:02X} SP:{:02X} PPU:{},{} CYC:{:d}".format(self.A,
                                                                                         self.X,
                                                                                         self.Y,
                                                                                         self._status_to_byte(b_flag=0),
                                                                                         self.SP,
                                                                                         ppu_line,
                                                                                         ppu_pixel,
                                                                                         self.cycles_since_reset
                                                                                        )
        return str

    def set_reset_vector(self, reset_vector):
        """
        Sets the reset vector (at fixed mem address), which tells the program counter where to start on a reset
        :param reset_vector: 16-bit address to which PC will be set after a reset
        """
        self.memory.write(RESET_VECTOR_ADDR, reset_vector & 0x00FF)  # low byte
        self.memory.write(RESET_VECTOR_ADDR + 1, (reset_vector & 0xFF00) >> 8)  # high byte

    cdef int _from_le(self, unsigned char* data):
        """
        Create an integer from a little-endian two byte array
        :param data: two-byte little endian array
        :return: an integer in the range 0-65535
        """
        return (data[HI_BYTE] << 8) + data[LO_BYTE]

    cdef int _read_word(self, int addr, int wrap_at_page):
        """
        Read a word at an address and return it as an integer
        If wrap_at_page is True then if the address is 0xppFF, then the word will be read from 0xppFF and 0xpp00
        """
        cdef unsigned char byte_lo, byte_hi

        if wrap_at_page and (addr & 0xFF) == 0xFF:
            # will wrap at page boundary
            byte_lo = self.memory.read(addr)
            byte_hi = self.memory.read(addr & 0xFF00)  # read the second (hi) byte from the start of the page
        else:
            #data = self.memory.read_block(addr, bytes=2)
            byte_lo = self.memory.read(addr)
            byte_hi = self.memory.read(addr + 1)
        return byte_lo + (byte_hi << 8)

    cdef int trigger_nmi(self):
        """
        Trigger a non maskable interrupt (NMI)
        """
        self._interrupt(NMI_VECTOR_ADDR, is_brk=False)
        self.cycles_since_reset += INTERRUPT_REQUEST_CYCLES
        return INTERRUPT_REQUEST_CYCLES

    cdef int trigger_irq(self):
        """
        Trigger a maskable hardware interrupt (IRQ); if interrupt disable bit (self.I) is set, ignore
        """
        if not self.I:
            self._interrupt(IRQ_BRK_VECTOR_ADDR, is_brk=False)
            self.cycles_since_reset += INTERRUPT_REQUEST_CYCLES
            return INTERRUPT_REQUEST_CYCLES
        else:
            return 0  # ignored!

    cdef int run_next_instr(self):
        """
        Decode and run the next instruction at the program counter, updating the number of processor
        cycles that have elapsed.  Instructions are taken as atomic, since the 6502 will complete them
        before it responds to interrupts.
        """
        cdef int i, cycles
        cdef unsigned char bytecode
        cdef unsigned char data[2]

        bytecode = self.memory.read(self.PC)
        # surprisingly, loop unrolling here helped quite a bit
        if self.instr_size_bytes[bytecode] >= 2:
            data[0] = self.memory.read(self.PC + 1)
        if self.instr_size_bytes[bytecode] == 3:
            data[1] = self.memory.read(self.PC + 2)

        # upon retrieving the opcode, the 6502 immediately increments PC by the opcode size:
        self.PC += self.instr_size_bytes[bytecode]

        cycles = self.run_instr(bytecode, data)
        self.cycles_since_reset += cycles
        return cycles

    cdef unsigned char _status_to_byte(self, bint b_flag):
        """
        Puts the status register into an 8-bit value.  Bit 6 is set high always, bit 5 (the "B flag") is set according
        to the b_flag argument.  This should be high if called from an instruction (PHP or BRK) instruction, low if
        the call came from a hardware interrupt (IRQ or NMI).
        """
        return (  self.N * SR_N_MASK
                + self.V * SR_V_MASK
                + SR_X_MASK              # the unused bit should always be set high
                + b_flag * SR_B_MASK     # the "B flag" should be set high if called from PHP or BRK [10] low o/w
                + self.D * SR_D_MASK
                + self.I * SR_I_MASK
                + self.Z * SR_Z_MASK
                + self.C * SR_C_MASK) & 0xFF   # this final and forces it to be treated as unsigned

    cdef void _status_from_byte(self, unsigned char sr_byte):
        """
        Sets the processor status from an 8-bit value as found on the stack.
        Bit 5 (B flag) is NEVER set in the status register (but is on the stack), so it is ignored here
        """
        self.N = (sr_byte & SR_N_MASK) > 0
        self.V = (sr_byte & SR_V_MASK) > 0
        self.D = (sr_byte & SR_D_MASK) > 0
        self.I = (sr_byte & SR_I_MASK) > 0
        self.Z = (sr_byte & SR_Z_MASK) > 0
        self.C = (sr_byte & SR_C_MASK) > 0

    cdef void push_stack(self, unsigned char v):
        """
        Push a byte value onto the stack
        """
        self.memory.write(STACK_PAGE + self.SP, v)
        self.SP = (self.SP - 1) & 0xFF

    cdef unsigned char pop_stack(self):
        """
        Pop (aka 'pull' in 6502 parlance) a byte from the stack
        """
        cdef unsigned char v
        if self.SP == 0xFF and self.stack_underflow_causes_exception:
            raise OverflowError("Stack underflow")
        self.SP = (self.SP + 1) & 0xFF
        v = self.memory.read(STACK_PAGE + self.SP)
        return v

    cdef int _neg(self, int v):
        """
        Is the value of v negative in 2s complement (i.e. is bit 7 high)?
        :return: true if v is negative (true if bit 7 of v is 1)
        """
        return (v & 0b10000000) > 0

    cdef int _from_2sc(self, unsigned char v):
        """
        Convert a 2's complement number to a signed integer
        """
        #neg = (v & 0b10000000) > 0
        #return (v & 0b01111111) if not neg else (v & 0b01111111) - 128
        return (v & 0b01111111) - (v & 0b10000000)

    cdef void _set_zn(self, int v):
        """
        Sets the Z and N flags from a result value v
        """
        self.Z = (v & 0xFF) == 0  # only care about the bottom 8 bits being zero
        self.N = (v & 0b10000000) > 0

    ##################  The instructions (and their helper functions)  #################################################

    cdef int _adc(self, int arg, int immediate):
        """
        Add to accumulator with carry.  Result goes into accumulator.
        :param arg: value to be added to accumulator (cannot be None)
        """
        cdef unsigned char v
        cdef int result

        v = self.memory.read(arg) if not immediate else arg

        # binary mode (standard)
        result = self.A + v + self.C
        self.C = result > 255
        self.V = (self._neg(self.A) == self._neg(v)) and (self._neg(self.A) != self._neg(result))

        # status
        # setting N and Z flags in the usual way is valid in BCD mode because "the N flag contains the high bit of
        # the result of the instruction" [5] (having said that, BCD mode is removed on the NES)
        self._set_zn(result)

        # result
        self.A = result & 0xFF

        return 0

    cdef int _and(self, int arg, int immediate):
        """
        Bitwise AND of accumulator and arg.  Result goes into accumulator.
        """
        cdef unsigned char v
        v = self.memory.read(arg) if not immediate else arg
        self.A = self.A & v
        self._set_zn(self.A)
        return 0

    cdef int _asl(self, int addr, int _):
        """
        Shift left one bit.
        """
        cdef unsigned char v, res_8bit
        cdef int result
        v = self.A if addr==ARG_NONE else self.memory.read(addr)
        result = v << 1

        # status
        self.C = result > 255    # top bit of original is put into carry flag
        self._set_zn(result)

        res_8bit = result & 0xFF

        if addr==ARG_NONE:
            # target the accumulator
            self.A = res_8bit
        else:
            self.memory.write(addr, res_8bit)
        return 0

    cdef int _jump_relative(self, int condition, int offset_2sc):
        """
        Jump by offset_2sc (in 2s complement) if the condition is true
        :return: number of extra cycles incurred by this branch conditional
        """
        cdef int extra_cycles, prev_pc_page

        extra_cycles = 0
        if condition:
            #print("jump")
            extra_cycles = 1  # taking a branch takes at least 1 extra cycle
            prev_pc_page = self.PC & 0xFF00  # should this be the PC before the branch instruction or after it?
            self.PC += self._from_2sc(offset_2sc)  # jumps to the address of the branch + 2 + offset (which is correct)
            if prev_pc_page != self.PC & 0xFF00:
                # but it takes two extra cycles if the memory page changes
                extra_cycles = 2
        #else:
        #    print("no jump")
        return extra_cycles

    cdef int _bcc(self, int offset, int _):
        """
        Branch on carry clear
        """
        return self._jump_relative(not self.C, offset)

    cdef int _bcs(self, int offset, int _):
        """
        Branch on carry set
        """
        return self._jump_relative(self.C, offset)

    cdef int _beq(self, int offset, int _):
        """
        Branch if zero flag is set
        """
        return self._jump_relative(self.Z, offset)

    cdef int _bit(self, int addr, int _):
        """
        Manipulates the status register by setting the N and V flags to those bits of the value in the address
        given, and sets the zero flag if A & v == 0
        """
        cdef unsigned char v
        v = self.memory.read(addr)
        self.N = (v & SR_N_MASK) > 0
        self.V = (v & SR_V_MASK) > 0
        self.Z = (self.A & v) == 0
        return 0

    cdef int _bmi(self, int offset, int _):
        """
        Branch on result minus (i.e. negative flag N is set)
        """
        return self._jump_relative(self.N, offset)

    cdef int _bne(self, int offset, int _):
        """
        Branch if zero flag is not set
        """
        return self._jump_relative(not self.Z, offset)

    cdef int _bpl(self, int offset, int _):
        """
        Branch on result positive (i.e. negative flag N is not set)
        """
        #print(self.N, not self.N)
        return self._jump_relative(not self.N, offset)

    cdef _interrupt(self, int interrupt_vector, int is_brk):
        """
        Interrupt routine, followed (with variations) by NMI, IRQ and BRK
          1)
        """
        cdef int v, addr
        cdef unsigned char sr
        # push PC (+1 if BRK) to the stack, high bit first
        v = self.PC + (1 if is_brk else 0)
        self.push_stack((v & 0xFF00) >> 8)  # high byte
        self.push_stack(v & 0xFF)  # low byte
        # push the processor status to the stack
        # BUT note that the B flag ON THE STACK COPY ONLY is now set
        sr = self._status_to_byte(b_flag=True if is_brk else False)
        self.push_stack(sr)
        addr = self._read_word(interrupt_vector, wrap_at_page=False)
        self.PC = addr
        # Set the interrupt disable flag.  But there seems to be disagreement in the sources as to whether or not the
        # I flag is set if this is a BRK instruction.
        # The following sources have it set:
        #   https://www.masswerk.at/6502/6502_instruction_set.html#BRK
        #   blargg's instruction tests (15-brk)
        # The following have it unaffected:
        #   http://www.obelisk.me.uk/6502/reference.html#BRK
        #   http://www.6502.org/tutorials/6502opcodes.html#BRK
        #   https://www.csh.rit.edu/~moffitt/docs/6502.html#BRK
        # Since blargg's tests run on a hardware NES, we follow that behaviour
        self.I = True

    cdef int _brk(self, int _, int __):
        """
        Force break, which simulates an interrupt request (IRQ).
        BRK, unlike other interrupts (IRQ and NMI), pushes PC + 1 to the stack (high byte first as usual).
        The reason for this may have been to allow brk to be dropped in in place of two byte instructions to allow
        debugging, but it is a quirk of the BRK instruction.  BRK also sets the B flag in the value of SR pushed to
        the stack
        """
        self._interrupt(IRQ_BRK_VECTOR_ADDR, is_brk=True)
        return 0

    cdef int _bvc(self, int offset, int _):
        """
        Branch on on overflow clear (V == 0)
        """
        return self._jump_relative(not self.V, offset)

    cdef int _bvs(self, int offset, int _):
        """
        Branch on on overflow set (V == 1)
        """
        return self._jump_relative(self.V, offset)

    cdef int _clc(self, int _, int __):
        """
        Clear carry flag (set C:=0)
        """
        self.C = False
        return 0

    cdef int _cld(self, int _, int __):
        """
        Clear decimal flag (set D:=0)
        """
        self.D = False
        return 0

    cdef int _cli(self, int _, int __):
        """
        Clear interrupt disable flag (set I:=0)
        """
        self.I = False
        return 0

    cdef int _clv(self, int _, int __):
        """
        Clear value flag (set V:=0)
        """
        self.V = False
        return 0

    cdef void _compare(self, int v0, int v):
        self._set_zn(v0 - v)
        self.C = v0 >= v

    cdef int _cmp(self, int arg, int immediate):
        """
        Sets flags as if a subtraction A - v was performed.  The N flag is valid iff the numbers are signed.
        :return:
        """
        cdef unsigned char v
        v = self.memory.read(arg) if not immediate else arg
        self._compare(self.A, v)
        return 0

    cdef int _cpx(self, int arg, int immediate):
        """
        Sets flags as if a subtraction A - v was performed.  The N flag is valid iff the numbers are signed.
        :return:
        """
        cdef unsigned char v
        v = self.memory.read(arg) if not immediate else arg
        self._compare(self.X, v)
        return 0

    cdef int _cpy(self, int arg, int immediate):
        """
        Sets flags as if a subtraction A - v was performed.  The N flag is valid iff the numbers are signed.
        :return:
        """
        cdef unsigned char v
        v = self.memory.read(arg) if not immediate else arg
        self._compare(self.Y, v)
        return 0

    cdef int _dec(self, int addr, int _):
        """
        Decrement memory in addr by 1
        :param addr:
        :param _:
        :return:
        """
        cdef unsigned char v
        v = (self.memory.read(addr) - 1) & 0xFF
        self._set_zn(v)
        self.memory.write(addr, v)
        return 0

    cdef int _dex(self, int _, int __):
        """
        Decrement X by 1
        :param addr:
        :param _:
        :return:
        """
        self.X = (self.X - 1) & 0xFF
        self._set_zn(self.X)
        return 0

    cdef int _dey(self, int _, int __):
        """
        Decrement Y by 1
        :param addr:
        :param _:
        :return:
        """
        self.Y = (self.Y - 1) & 0xFF
        self._set_zn(self.Y)
        return 0

    cdef int _eor(self, int arg, int immediate):
        """
        XOR A with value and put result back into A
        :param addr:
        :param _:
        :return:
        """
        cdef unsigned char v
        v = self.memory.read(arg) if not immediate else arg
        self.A = v ^ self.A
        self._set_zn(self.A)
        return 0

    cdef int _inc(self, int addr, int _):
        """
        Increment memory in addr by 1
        :param addr:
        :param _:
        :return:
        """
        cdef unsigned char v
        v = (self.memory.read(addr) + 1) & 0xFF
        self._set_zn(v)
        self.memory.write(addr, v)
        return 0

    cdef int _inx(self, int _, int __):
        """
        Increment X by 1
        :param addr:
        :param _:
        :return:
        """
        self.X = (self.X + 1) & 0xFF
        self._set_zn(self.X)
        return 0

    cdef int _iny(self, int _, int __):
        """
        Increment Y by 1
        :param addr:
        :param _:
        :return:
        """
        self.Y = (self.Y + 1) & 0xFF
        self._set_zn(self.Y)
        return 0

    cdef int _jmp(self, int addr, int _):
        """
        Jump to the (16 bit) address addr.  In the case of jump instructions jmp and jsr,
        "absolute" addressing is more like immediate addressing, in that the jump goes directly
        to the memory address specified rather than reading the value there and using that (which
        is "indirect" addressing in the case of jumps, so this function behaves always like it got
        an immediate address
        """
        self.PC = addr
        return 0

    cdef int _jsr(self, int addr, int _):
        """
        Jump to a subroutine at the value in memory[addr].  Addr here is an absolute (16 bit) location.
        In the case of jump instructions jmp and jsr,
        "absolute" addressing is more like immediate addressing, in that the jump goes directly
        to the memory address specified rather than reading the value there and using that (which
        is "indirect" addressing in the case of jumps, so this function behaves always like it got
        an immediate address
        """
        # save PC - 1 to the stack, high byte first
        cdef int v
        v = self.PC - 1
        self.push_stack((v & 0xFF00) >> 8)
        self.push_stack(v & 0x00FF)
        self.PC = addr
        return 0

    cdef int _lda(self, int arg, int immediate):
        """
        Load A from value / memory
        :return:
        """
        self.A = self.memory.read(arg) if not immediate else arg
        self._set_zn(self.A)
        return 0

    cdef int _ldx(self, int arg, int immediate):
        """
        Load X from value / memory
        :return:
        """
        self.X = self.memory.read(arg) if not immediate else arg
        self._set_zn(self.X)
        return 0

    cdef int _ldy(self, int arg, int immediate):
        """
        Load Y from value / memory
        :return:
        """
        self.Y = self.memory.read(arg) if not immediate else arg
        self._set_zn(self.Y)
        return 0

    cdef int _lsr(self, int addr, int _):
        """
        Logical shift right
        :param addr:
        :param _:
        :return:
        """
        cdef unsigned char v, result
        v = self.A if addr==ARG_NONE else self.memory.read(addr)
        result = (v >> 1) & 0xFF

        # status
        self.C = v & 0x01
        self.N = False
        self.Z = result == 0

        if addr==ARG_NONE:
            # target the accumulator
            self.A = result
        else:
            self.memory.write(addr, result)
        return 0

    cdef int _nop(self, int _, int __):
        """
        No-op.  This one is easy.
        :return:
        """
        return 0

    cdef int _ora(self, int arg, int immediate):
        """
        Bitwise OR with accumulator; result put into accumulator.
        :return:
        """
        cdef unsigned char v
        v = self.memory.read(arg) if not immediate else arg
        self.A = self.A | v
        self._set_zn(self.A)
        return 0

    cdef int _pha(self, int _, int __):
        """
        Push A onto stack
        :param _:
        :param __:
        :return:
        """
        self.push_stack(self.A)
        return 0

    cdef int _php(self, int _, int __):
        """
        Push status register onto stack
        :param _:
        :param __:
        :return:
        """
        cdef unsigned char v

        v = self._status_to_byte(b_flag=True)  # b-flag should be set True in this case [10]
        self.push_stack(v)
        return 0

    cdef int _pla(self, int _, int __):
        """
        Pull A from stack
        :param _:
        :param __:
        :return:
        """
        self.A = self.pop_stack()
        self._set_zn(self.A)
        return 0

    cdef int _plp(self, int _, int __):
        """
        Pull processor status from the stack
        :return:
        """
        cdef unsigned char v
        v = self.pop_stack()
        self._status_from_byte(v)
        return 0

    cdef int _rol(self, int addr, int _):
        """
        Rotate one bit left (including carry bit in the rotation, i.e. C rotates into lsb and msb rotates into C)
        :return:
        """
        cdef unsigned char v
        cdef int result

        v = self.A if addr==ARG_NONE else self.memory.read(addr)
        result = (v << 1) + self.C

        # status
        self.C = result > 255
        self._set_zn(result)

        if addr==ARG_NONE:
            # target the accumulator
            self.A = result & 0xFF
        else:
            self.memory.write(addr, result & 0xFF)
        return 0

    cdef int _ror(self, int addr, int _):
        """
        Rotate one bit right (including carry bit in the rotation, i.e. C rotates into msb and lsb rotates into C)
        :return:
        """
        cdef unsigned char v
        cdef int result
        v = self.A if addr==ARG_NONE else self.memory.read(addr)
        result = (v >> 1) + (self.C << 7)

        # status
        self.C = v & 0x01
        self._set_zn(result)

        if addr==ARG_NONE:
            # target the accumulator
            self.A = result & 0xFF
        else:
            self.memory.write(addr, result & 0xFF)
        return 0

    cdef int _rti(self, int _, int __):
        """
        Return from an interrupt.  Gets the PC of the last execution point and the flag register from the
        stack.  (PC is stored on the stack, not PC-1 as with jsr/rts)
        :return:
        """
        cdef unsigned char flags, addr_lo, addr_hi
        flags = self.pop_stack()
        addr_lo = self.pop_stack()
        addr_hi = self.pop_stack()
        self._status_from_byte(flags)
        self.PC = (addr_hi << 8) + addr_lo
        return 0

    cdef int _rts(self, int _, int __):
        """
        Returns from a subroutine (see jsr for the jump subroutine)
        :return:
        """
        cdef unsigned char addr_lo, addr_hi
        # fetch PC-1 from the stack, low byte first
        addr_lo = self.pop_stack()
        addr_hi = self.pop_stack()
        # restore PC to the stack
        self.PC = (addr_hi << 8) + addr_lo + 1
        return 0

    cdef int _sbc(self, int arg, int immediate):
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
        cdef unsigned char v, borrow
        cdef int result
        v = self.memory.read(arg) if not immediate else arg
        borrow = not self.C   # incoming borrow is indicated by not Carry  (borrow is either 0 or 1)

        result = self.A - v - borrow     # arithmetic is done unsigned
        self.C = result >= 0  # not Carry == borrow; borrow if res<0, so C==not(res<0) == res>=0
        # overflow - see notes in description above
        # I think this is correct and that the borrow doesn't matter here
        self.V = (self._neg(self.A) != self._neg(v)) and (self._neg(v) == self._neg(result))
        self._set_zn(result)
        self.A = result & 0xFF
        return 0

    cdef int _sec(self, int _, int __):
        """
        Set carry flag
        """
        self.C = True
        return 0

    cdef int _sed(self, int _, int __):
        """
        Set decimal flag
        """
        self.D = True
        return 0

    cdef int _sei(self, int _, int __):
        """
        Set interrupt disable flag
        """
        self.I = True
        return 0

    cdef int _sta(self, int addr, int _):
        """
        Store A in memory.  No flags are set.
        :return:
        """
        self.memory.write(addr, self.A)
        return 0

    cdef int _stx(self, int addr, int _):
        """
        Store X in memory.  No flags are set.
        :return:
        """
        self.memory.write(addr, self.X)
        return 0

    cdef int _sty(self, int addr, int _):
        """
        Store Y in memory.  No flags are set.
        :return:
        """
        self.memory.write(addr, self.Y)
        return 0

    cdef int _tax(self, int _, int __):
        """
        Transfer A to X
        :return:
        """
        self.X = self.A
        self._set_zn(self.X)
        return 0

    cdef int _tay(self, int _, int __):
        """
        Transfer A to Y
        :return:
        """
        self.Y = self.A
        self._set_zn(self.Y)
        return 0

    cdef int _tsx(self, int _, int __):
        """
        Transfer SP to X
        :return:
        """
        self.X = self.SP
        self._set_zn(self.X)
        return 0

    cdef int _txa(self, int _, int __):
        """
        Transfer X to A
        :return:
        """
        self.A = self.X
        self._set_zn(self.A)
        return 0

    cdef int _txs(self, int _, int __):
        """
        Transfer X to SP
        :return:
        """
        self.SP = self.X
        return 0

    cdef int _tya(self, int _, int __):
        """
        Transfer Y to A
        :return:
        """
        self.A = self.Y
        self._set_zn(self.A)
        return 0

    ################################## The undocumented instructions (see [13] and others) #############################

    def _dop(self, _, __):
        """
        Undocumented.
        Double NOP instruction.  Luckily it is easy to implement!
        """
        return 0

    def _top(self, _, __):
        """
        Undocumented.
        Triple NOP instruction.
        """
        return 0

    def _kil(self, _, __):
        """
        Undocumented.
        Shuts down the processor.  No recovery is possible after this has executed, short of a reset.
        """
        if self.undocumented_support_level >= 1:
            raise ValueError("KIL instruction.  Processor halted.")
        return 0

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
        return 0

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
        return 0

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
        return 0

    def _isc(self, addr, _):
        """
        Undocumented.
        Increase memory by one, then subtract memory from accumulator (with borrow). Status flags: N,V,Z,C
        """
        if self.undocumented_support_level >= 1:
            v = (self.memory.read(addr) + 1) & 0xFF
            self.memory.write(addr, v)
            self._sbc(v, immediate=True)
        return 0

    def _slo(self, addr, _):
        """
        Undocumented.
        Shift left one bit in memory, then OR accumulator with memory.  Status flags: N,Z,C
        Equivalent to ASL, ORA
        """
        if self.undocumented_support_level >= 1:
            self._asl(addr, ARG_NONE)
            self._ora(self.memory.read(addr), immediate=True)
        return 0

    def _rla(self, addr, _):
        """
        Undocumented.
        RLA ROLs the contents of a memory location and then ANDs the result with the accumulator.
        Equivalent to ROL, AND
        """
        if self.undocumented_support_level >= 1:
            self._rol(addr, ARG_NONE)
            self._and(self.memory.read(addr), immediate=True)
        return 0

    def _rra(self, addr, _):
        """
        Undocumented.
        RRA RORs the contents of a memory location and then ADCs the result with the accumulator.
        Equivalent to ROR, ADC
        """
        if self.undocumented_support_level >= 1:
            self._ror(addr, ARG_NONE)
            self._adc(self.memory.read(addr), immediate=True)
        return 0

    def _sre(self, addr, _):
        """
        Undocumented.
        Shift right one bit in memory, then EOR accumulator with memory.
        Equivalent to LSR, EOR
        """
        if self.undocumented_support_level >= 1:
            self._lsr(addr, ARG_NONE)
            self._eor(self.memory.read(addr), immediate=True)
        return 0

    ##################### The arcane undocumented instructions (see [13] and others) ###################################

    def _arr(self, arg, _):
        """
        Undocumented.  Mostly used for piracy (jk).
        ANDs the contents of the A register with an immediate value and then RORs the result, and check bit 5 and 6:
            If both bits are 1: set C, clear V.
            If both bits are 0: clear C and V.
            If only bit 5 is 1: set V, clear C.
            If only bit 6 is 1: set C and V.
        Equivalent to AND oper, ROR A
        """
        if self.undocumented_support_level >= 2:
            self._and(arg, immediate=True)
            self._ror(ARG_NONE, ARG_NONE)
            if ((self.A >> 5) & 1) and ((self.A >> 6) & 1):
                self.C = True
                self.V = False
            elif ((self.A >> 5) & 1) == 0 and ((self.A >> 6) & 1) == 0:
                self.C = False
                self.V = False
            elif ((self.A >> 5) & 1) and ((self.A >> 6) & 1) == 0:
                self.C = False
                self.V = True
            elif ((self.A >> 5) & 1) == 0 and ((self.A >> 6) & 1):
                self.C = True
                self.V = True
        return 0

    def _asr(self, arg, _):
        """
        UNTESTED
        Undocumented.
        ANDs the contents of the A register with an immediate value and then LSRs the result.
        Equivalent to AND oper, LSR A
        """
        if self.undocumented_support_level >= 2:
            self._and(arg, immediate=True)
            self._lsr(ARG_NONE, ARG_NONE)
        return 0

    def _atx(self, arg, _):
        """
        Undocumented.
        FAILS BLARGG'S INSTRUCTION TEST 03-immediate (both variants here)

        Following http://nesdev.com/undocumented_opcodes.txt:
            AND byte with accumulator, then transfer accumulator to X register.
            Status flags: N,Z

        Following http://www.ffd2.com/fridge/docs/6502-NMOS.extra.opcodes (where this is OAL):
            ORs the A register with #$EE, ANDs the result with an immediate value, and then stores the result in
            both A and X.
            Equivalent to ORA #$EE, AND oper, TAX

        The latter causes blargg's test 03-immediate to fail for opcode 0xAB
        """
        if self.undocumented_support_level >= 2:
            #self.A &= arg
            #self.X = self.A
            #self._set_zn(self.A)
            self._and(arg | 0xEE, immediate=True)
            self.X = self.A
        return 0

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
        return 0

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
        return 0

    def _axs(self, arg, immediate):
        """
        FAILS BLARGG'S INSTRUCTION TEST 03-immediate
        Undocumented.
        AND the contents of the A and X registers (without changing the contents of either register) and
        stores the result in memory. [16]
        """
        self.A = self.memory.read(arg) if not immediate else arg

        if self.undocumented_support_level >= 2:

            if immediate:
                # AND X register with accumulator and store result in X regis-ter, then subtract byte from X register
                # (without borrow).  Status flags: N,Z,C   (http://nesdev.com/undocumented_opcodes.txt)
                self.X = self.A & self.X
                t = self.X - arg
                self.C = t >= 0
                self.X = t & 0xFF
                self._set_zn(self.X)
            else:
                self.memory.write(arg, self.A & self.X)
                self._set_zn(self.A & self.X)
        return 0

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
        return 0

    def _sxa(self, addr, _):
        """
        FAILS BLARGG'S TEST 07-abs_xy
        Undocumented.
        AND X register with the high byte of the target address of the argument + 1. Store the result in memory. [16]
        """
        if self.undocumented_support_level >= 2:
            hp1 = (((addr & 0xFF00) >> 8) + 1) & 0xFF
            self.memory.write(addr, self.X & hp1)
        return 0

    def _sya(self, addr, _):
        """
        FAILS BLARGG'S TEST 07-abs_xy
        Undocumented.
        AND Y register with the high byte of the target address of the argument + 1. Store the result in memory. [16]
        """
        if self.undocumented_support_level >= 2:
            v = self.Y & ((((addr & 0xFF00) >> 8) + 1) & 0xFF)
            self.memory.write(addr, v & 0xFF)
        return 0

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
        return 0

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
        return 0

    cdef int run_instr(self, unsigned char opcode, unsigned char data[2]):
        # *********** AUTOGENERATED BY meta.py - DO NOT EDIT DIRECTLY ***********
        cdef int cycles=0, arg, immediate=False, m

        #print("{:02X} {:02X} {:02X}".format(opcode, data[0], data[1]))

        if opcode==0x69:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._adc(arg, immediate)
        elif opcode==0x65:
            cycles = 3
            arg = data[0]
            cycles += self._adc(arg, immediate)
        elif opcode==0x75:
            cycles = 4
            arg = (data[0] + self.X) & 0xFF
            cycles += self._adc(arg, immediate)
        elif opcode==0x6D:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._adc(arg, immediate)
        elif opcode==0x7D:
            cycles = 4
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.X) > 0xFF else 0
            cycles += self._adc(arg, immediate)
        elif opcode==0x79:
            cycles = 4
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.Y) > 0xFF else 0
            cycles += self._adc(arg, immediate)
        elif opcode==0x61:
            cycles = 6
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._adc(arg, immediate)
        elif opcode==0x71:
            cycles = 5
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += 1 if ((m & 0xFF) + self.Y) > 0xFF else 0
            cycles += self._adc(arg, immediate)
        elif opcode==0x29:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._and(arg, immediate)
        elif opcode==0x25:
            cycles = 3
            arg = data[0]
            cycles += self._and(arg, immediate)
        elif opcode==0x35:
            cycles = 4
            arg = (data[0] + self.X) & 0xFF
            cycles += self._and(arg, immediate)
        elif opcode==0x2D:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._and(arg, immediate)
        elif opcode==0x3D:
            cycles = 4
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.X) > 0xFF else 0
            cycles += self._and(arg, immediate)
        elif opcode==0x39:
            cycles = 4
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.Y) > 0xFF else 0
            cycles += self._and(arg, immediate)
        elif opcode==0x21:
            cycles = 6
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._and(arg, immediate)
        elif opcode==0x31:
            cycles = 5
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += 1 if ((m & 0xFF) + self.Y) > 0xFF else 0
            cycles += self._and(arg, immediate)
        elif opcode==0x0A:
            cycles = 2
            arg = ARG_NONE
            cycles += self._asl(arg, immediate)
        elif opcode==0x06:
            cycles = 5
            arg = data[0]
            cycles += self._asl(arg, immediate)
        elif opcode==0x16:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._asl(arg, immediate)
        elif opcode==0x0E:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._asl(arg, immediate)
        elif opcode==0x1E:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._asl(arg, immediate)
        elif opcode==0x90:
            cycles = 2
            arg = data[0]

            cycles += self._bcc(arg, immediate)
        elif opcode==0xB0:
            cycles = 2
            arg = data[0]

            cycles += self._bcs(arg, immediate)
        elif opcode==0xF0:
            cycles = 2
            arg = data[0]

            cycles += self._beq(arg, immediate)
        elif opcode==0x24:
            cycles = 3
            arg = data[0]
            cycles += self._bit(arg, immediate)
        elif opcode==0x2C:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._bit(arg, immediate)
        elif opcode==0x30:
            cycles = 2
            arg = data[0]

            cycles += self._bmi(arg, immediate)
        elif opcode==0xD0:
            cycles = 2
            arg = data[0]

            cycles += self._bne(arg, immediate)
        elif opcode==0x10:
            cycles = 2
            arg = data[0]

            cycles += self._bpl(arg, immediate)
        elif opcode==0x00:
            cycles = 7
            arg = ARG_NONE
            cycles += self._brk(arg, immediate)
        elif opcode==0x50:
            cycles = 2
            arg = data[0]

            cycles += self._bvc(arg, immediate)
        elif opcode==0x70:
            cycles = 2
            arg = data[0]

            cycles += self._bvs(arg, immediate)
        elif opcode==0x18:
            cycles = 2
            arg = ARG_NONE
            cycles += self._clc(arg, immediate)
        elif opcode==0xD8:
            cycles = 2
            arg = ARG_NONE
            cycles += self._cld(arg, immediate)
        elif opcode==0x58:
            cycles = 2
            arg = ARG_NONE
            cycles += self._cli(arg, immediate)
        elif opcode==0xB8:
            cycles = 2
            arg = ARG_NONE
            cycles += self._clv(arg, immediate)
        elif opcode==0xC9:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._cmp(arg, immediate)
        elif opcode==0xC5:
            cycles = 3
            arg = data[0]
            cycles += self._cmp(arg, immediate)
        elif opcode==0xD5:
            cycles = 4
            arg = (data[0] + self.X) & 0xFF
            cycles += self._cmp(arg, immediate)
        elif opcode==0xCD:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._cmp(arg, immediate)
        elif opcode==0xDD:
            cycles = 4
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.X) > 0xFF else 0
            cycles += self._cmp(arg, immediate)
        elif opcode==0xD9:
            cycles = 4
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.Y) > 0xFF else 0
            cycles += self._cmp(arg, immediate)
        elif opcode==0xC1:
            cycles = 6
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._cmp(arg, immediate)
        elif opcode==0xD1:
            cycles = 5
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += 1 if ((m & 0xFF) + self.Y) > 0xFF else 0
            cycles += self._cmp(arg, immediate)
        elif opcode==0xE0:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._cpx(arg, immediate)
        elif opcode==0xE4:
            cycles = 3
            arg = data[0]
            cycles += self._cpx(arg, immediate)
        elif opcode==0xEC:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._cpx(arg, immediate)
        elif opcode==0xC0:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._cpy(arg, immediate)
        elif opcode==0xC4:
            cycles = 3
            arg = data[0]
            cycles += self._cpy(arg, immediate)
        elif opcode==0xCC:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._cpy(arg, immediate)
        elif opcode==0xC6:
            cycles = 5
            arg = data[0]
            cycles += self._dec(arg, immediate)
        elif opcode==0xD6:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._dec(arg, immediate)
        elif opcode==0xCE:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._dec(arg, immediate)
        elif opcode==0xDE:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._dec(arg, immediate)
        elif opcode==0xCA:
            cycles = 2
            arg = ARG_NONE
            cycles += self._dex(arg, immediate)
        elif opcode==0x88:
            cycles = 2
            arg = ARG_NONE
            cycles += self._dey(arg, immediate)
        elif opcode==0x49:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._eor(arg, immediate)
        elif opcode==0x45:
            cycles = 3
            arg = data[0]
            cycles += self._eor(arg, immediate)
        elif opcode==0x55:
            cycles = 4
            arg = (data[0] + self.X) & 0xFF
            cycles += self._eor(arg, immediate)
        elif opcode==0x4D:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._eor(arg, immediate)
        elif opcode==0x5D:
            cycles = 4
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.X) > 0xFF else 0
            cycles += self._eor(arg, immediate)
        elif opcode==0x59:
            cycles = 4
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.Y) > 0xFF else 0
            cycles += self._eor(arg, immediate)
        elif opcode==0x41:
            cycles = 6
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._eor(arg, immediate)
        elif opcode==0x51:
            cycles = 5
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += 1 if ((m & 0xFF) + self.Y) > 0xFF else 0
            cycles += self._eor(arg, immediate)
        elif opcode==0xE6:
            cycles = 5
            arg = data[0]
            cycles += self._inc(arg, immediate)
        elif opcode==0xF6:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._inc(arg, immediate)
        elif opcode==0xEE:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._inc(arg, immediate)
        elif opcode==0xFE:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._inc(arg, immediate)
        elif opcode==0xE8:
            cycles = 2
            arg = ARG_NONE
            cycles += self._inx(arg, immediate)
        elif opcode==0xC8:
            cycles = 2
            arg = ARG_NONE
            cycles += self._iny(arg, immediate)
        elif opcode==0x4C:
            cycles = 3
            arg = self._from_le(data)
            cycles += self._jmp(arg, immediate)
        elif opcode==0x6C:
            cycles = 5
            arg = self._read_word(self._from_le(data), wrap_at_page=True)
            cycles += self._jmp(arg, immediate)
        elif opcode==0x20:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._jsr(arg, immediate)
        elif opcode==0xA9:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._lda(arg, immediate)
        elif opcode==0xA5:
            cycles = 3
            arg = data[0]
            cycles += self._lda(arg, immediate)
        elif opcode==0xB5:
            cycles = 4
            arg = (data[0] + self.X) & 0xFF
            cycles += self._lda(arg, immediate)
        elif opcode==0xAD:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._lda(arg, immediate)
        elif opcode==0xBD:
            cycles = 4
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.X) > 0xFF else 0
            cycles += self._lda(arg, immediate)
        elif opcode==0xB9:
            cycles = 4
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.Y) > 0xFF else 0
            cycles += self._lda(arg, immediate)
        elif opcode==0xA1:
            cycles = 6
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._lda(arg, immediate)
        elif opcode==0xB1:
            cycles = 5
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += 1 if ((m & 0xFF) + self.Y) > 0xFF else 0
            cycles += self._lda(arg, immediate)
        elif opcode==0xA2:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._ldx(arg, immediate)
        elif opcode==0xA6:
            cycles = 3
            arg = data[0]
            cycles += self._ldx(arg, immediate)
        elif opcode==0xB6:
            cycles = 4
            arg = (data[0] + self.Y) & 0xFF
            cycles += self._ldx(arg, immediate)
        elif opcode==0xAE:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._ldx(arg, immediate)
        elif opcode==0xBE:
            cycles = 4
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.Y) > 0xFF else 0
            cycles += self._ldx(arg, immediate)
        elif opcode==0xA0:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._ldy(arg, immediate)
        elif opcode==0xA4:
            cycles = 3
            arg = data[0]
            cycles += self._ldy(arg, immediate)
        elif opcode==0xB4:
            cycles = 4
            arg = (data[0] + self.X) & 0xFF
            cycles += self._ldy(arg, immediate)
        elif opcode==0xAC:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._ldy(arg, immediate)
        elif opcode==0xBC:
            cycles = 4
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.X) > 0xFF else 0
            cycles += self._ldy(arg, immediate)
        elif opcode==0x4A:
            cycles = 2
            arg = ARG_NONE
            cycles += self._lsr(arg, immediate)
        elif opcode==0x46:
            cycles = 5
            arg = data[0]
            cycles += self._lsr(arg, immediate)
        elif opcode==0x56:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._lsr(arg, immediate)
        elif opcode==0x4E:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._lsr(arg, immediate)
        elif opcode==0x5E:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._lsr(arg, immediate)
        elif opcode==0xEA or opcode==0x1A or opcode==0x3A or opcode==0x5A or opcode==0x7A or opcode==0xDA or opcode==0xFA:
            cycles = 2
            arg = ARG_NONE
            cycles += self._nop(arg, immediate)
        elif opcode==0x09:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._ora(arg, immediate)
        elif opcode==0x05:
            cycles = 3
            arg = data[0]
            cycles += self._ora(arg, immediate)
        elif opcode==0x15:
            cycles = 4
            arg = (data[0] + self.X) & 0xFF
            cycles += self._ora(arg, immediate)
        elif opcode==0x0D:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._ora(arg, immediate)
        elif opcode==0x1D:
            cycles = 4
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.X) > 0xFF else 0
            cycles += self._ora(arg, immediate)
        elif opcode==0x19:
            cycles = 4
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.Y) > 0xFF else 0
            cycles += self._ora(arg, immediate)
        elif opcode==0x01:
            cycles = 6
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._ora(arg, immediate)
        elif opcode==0x11:
            cycles = 5
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += 1 if ((m & 0xFF) + self.Y) > 0xFF else 0
            cycles += self._ora(arg, immediate)
        elif opcode==0x48:
            cycles = 3
            arg = ARG_NONE
            cycles += self._pha(arg, immediate)
        elif opcode==0x08:
            cycles = 3
            arg = ARG_NONE
            cycles += self._php(arg, immediate)
        elif opcode==0x68:
            cycles = 4
            arg = ARG_NONE
            cycles += self._pla(arg, immediate)
        elif opcode==0x28:
            cycles = 4
            arg = ARG_NONE
            cycles += self._plp(arg, immediate)
        elif opcode==0x2A:
            cycles = 2
            arg = ARG_NONE
            cycles += self._rol(arg, immediate)
        elif opcode==0x26:
            cycles = 5
            arg = data[0]
            cycles += self._rol(arg, immediate)
        elif opcode==0x36:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._rol(arg, immediate)
        elif opcode==0x2E:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._rol(arg, immediate)
        elif opcode==0x3E:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._rol(arg, immediate)
        elif opcode==0x6A:
            cycles = 2
            arg = ARG_NONE
            cycles += self._ror(arg, immediate)
        elif opcode==0x66:
            cycles = 5
            arg = data[0]
            cycles += self._ror(arg, immediate)
        elif opcode==0x76:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._ror(arg, immediate)
        elif opcode==0x6E:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._ror(arg, immediate)
        elif opcode==0x7E:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._ror(arg, immediate)
        elif opcode==0x40:
            cycles = 6
            arg = ARG_NONE
            cycles += self._rti(arg, immediate)
        elif opcode==0x60:
            cycles = 6
            arg = ARG_NONE
            cycles += self._rts(arg, immediate)
        elif opcode==0xE9 or opcode==0xEB:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._sbc(arg, immediate)
        elif opcode==0xE5:
            cycles = 3
            arg = data[0]
            cycles += self._sbc(arg, immediate)
        elif opcode==0xF5:
            cycles = 4
            arg = (data[0] + self.X) & 0xFF
            cycles += self._sbc(arg, immediate)
        elif opcode==0xED:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._sbc(arg, immediate)
        elif opcode==0xFD:
            cycles = 4
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.X) > 0xFF else 0
            cycles += self._sbc(arg, immediate)
        elif opcode==0xF9:
            cycles = 4
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.Y) > 0xFF else 0
            cycles += self._sbc(arg, immediate)
        elif opcode==0xE1:
            cycles = 6
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._sbc(arg, immediate)
        elif opcode==0xF1:
            cycles = 5
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += 1 if ((m & 0xFF) + self.Y) > 0xFF else 0
            cycles += self._sbc(arg, immediate)
        elif opcode==0x38:
            cycles = 2
            arg = ARG_NONE
            cycles += self._sec(arg, immediate)
        elif opcode==0xF8:
            cycles = 2
            arg = ARG_NONE
            cycles += self._sed(arg, immediate)
        elif opcode==0x78:
            cycles = 2
            arg = ARG_NONE
            cycles += self._sei(arg, immediate)
        elif opcode==0x85:
            cycles = 3
            arg = data[0]
            cycles += self._sta(arg, immediate)
        elif opcode==0x95:
            cycles = 4
            arg = (data[0] + self.X) & 0xFF
            cycles += self._sta(arg, immediate)
        elif opcode==0x8D:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._sta(arg, immediate)
        elif opcode==0x9D:
            cycles = 5
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._sta(arg, immediate)
        elif opcode==0x99:
            cycles = 5
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += self._sta(arg, immediate)
        elif opcode==0x81:
            cycles = 6
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._sta(arg, immediate)
        elif opcode==0x91:
            cycles = 6
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += self._sta(arg, immediate)
        elif opcode==0x86:
            cycles = 3
            arg = data[0]
            cycles += self._stx(arg, immediate)
        elif opcode==0x96:
            cycles = 4
            arg = (data[0] + self.Y) & 0xFF
            cycles += self._stx(arg, immediate)
        elif opcode==0x8E:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._stx(arg, immediate)
        elif opcode==0x84:
            cycles = 3
            arg = data[0]
            cycles += self._sty(arg, immediate)
        elif opcode==0x94:
            cycles = 4
            arg = (data[0] + self.X) & 0xFF
            cycles += self._sty(arg, immediate)
        elif opcode==0x8C:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._sty(arg, immediate)
        elif opcode==0xAA:
            cycles = 2
            arg = ARG_NONE
            cycles += self._tax(arg, immediate)
        elif opcode==0xA8:
            cycles = 2
            arg = ARG_NONE
            cycles += self._tay(arg, immediate)
        elif opcode==0xBA:
            cycles = 2
            arg = ARG_NONE
            cycles += self._tsx(arg, immediate)
        elif opcode==0x8A:
            cycles = 2
            arg = ARG_NONE
            cycles += self._txa(arg, immediate)
        elif opcode==0x9A:
            cycles = 2
            arg = ARG_NONE
            cycles += self._txs(arg, immediate)
        elif opcode==0x98:
            cycles = 2
            arg = ARG_NONE
            cycles += self._tya(arg, immediate)
        elif opcode==0x04 or opcode==0x14 or opcode==0x44 or opcode==0x64:
            cycles = 3
            arg = data[0]
            cycles += self._dop(arg, immediate)
        elif opcode==0x14 or opcode==0x34 or opcode==0x54 or opcode==0x74 or opcode==0xD4 or opcode==0xF4:
            cycles = 4
            arg = (data[0] + self.X) & 0xFF
            cycles += self._dop(arg, immediate)
        elif opcode==0x80 or opcode==0x82 or opcode==0x89 or opcode==0xC2 or opcode==0xE2:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._dop(arg, immediate)
        elif opcode==0x0C:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._top(arg, immediate)
        elif opcode==0x1C or opcode==0x3C or opcode==0x5C or opcode==0x7C or opcode==0xDC or opcode==0xFC:
            cycles = 4
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.X) > 0xFF else 0
            cycles += self._top(arg, immediate)
        elif opcode==0x02 or opcode==0x12 or opcode==0x22 or opcode==0x32 or opcode==0x42 or opcode==0x52 or opcode==0x62 or opcode==0x72 or opcode==0x92 or opcode==0xB2 or opcode==0xD2 or opcode==0xF2:
            cycles = 1
            arg = ARG_NONE
            cycles += self._kil(arg, immediate)
        elif opcode==0xA7:
            cycles = 3
            arg = data[0]
            cycles += self._lax(arg, immediate)
        elif opcode==0xB7:
            cycles = 4
            arg = (data[0] + self.Y) & 0xFF
            cycles += self._lax(arg, immediate)
        elif opcode==0xAF:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._lax(arg, immediate)
        elif opcode==0xBF:
            cycles = 4
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.Y) > 0xFF else 0
            cycles += self._lax(arg, immediate)
        elif opcode==0xA3:
            cycles = 6
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._lax(arg, immediate)
        elif opcode==0xB3:
            cycles = 5
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += 1 if ((m & 0xFF) + self.Y) > 0xFF else 0
            cycles += self._lax(arg, immediate)
        elif opcode==0x87:
            cycles = 3
            arg = data[0]
            cycles += self._aax(arg, immediate)
        elif opcode==0x97:
            cycles = 4
            arg = (data[0] + self.Y) & 0xFF
            cycles += self._aax(arg, immediate)
        elif opcode==0x83:
            cycles = 6
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._aax(arg, immediate)
        elif opcode==0x8F:
            cycles = 4
            arg = self._from_le(data)
            cycles += self._aax(arg, immediate)
        elif opcode==0xC7:
            cycles = 5
            arg = data[0]
            cycles += self._dcp(arg, immediate)
        elif opcode==0xD7:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._dcp(arg, immediate)
        elif opcode==0xCF:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._dcp(arg, immediate)
        elif opcode==0xDF:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._dcp(arg, immediate)
        elif opcode==0xDB:
            cycles = 7
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += self._dcp(arg, immediate)
        elif opcode==0xC3:
            cycles = 8
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._dcp(arg, immediate)
        elif opcode==0xD3:
            cycles = 8
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += self._dcp(arg, immediate)
        elif opcode==0xE7:
            cycles = 5
            arg = data[0]
            cycles += self._isc(arg, immediate)
        elif opcode==0xF7:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._isc(arg, immediate)
        elif opcode==0xEF:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._isc(arg, immediate)
        elif opcode==0xFF:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._isc(arg, immediate)
        elif opcode==0xFB:
            cycles = 7
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += self._isc(arg, immediate)
        elif opcode==0xE3:
            cycles = 8
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._isc(arg, immediate)
        elif opcode==0xF3:
            cycles = 8
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += self._isc(arg, immediate)
        elif opcode==0x07:
            cycles = 5
            arg = data[0]
            cycles += self._slo(arg, immediate)
        elif opcode==0x17:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._slo(arg, immediate)
        elif opcode==0x0F:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._slo(arg, immediate)
        elif opcode==0x1F:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._slo(arg, immediate)
        elif opcode==0x1B:
            cycles = 7
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += self._slo(arg, immediate)
        elif opcode==0x03:
            cycles = 8
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._slo(arg, immediate)
        elif opcode==0x13:
            cycles = 8
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += self._slo(arg, immediate)
        elif opcode==0x27:
            cycles = 5
            arg = data[0]
            cycles += self._rla(arg, immediate)
        elif opcode==0x37:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._rla(arg, immediate)
        elif opcode==0x2F:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._rla(arg, immediate)
        elif opcode==0x3F:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._rla(arg, immediate)
        elif opcode==0x3B:
            cycles = 7
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += self._rla(arg, immediate)
        elif opcode==0x23:
            cycles = 8
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._rla(arg, immediate)
        elif opcode==0x33:
            cycles = 8
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += self._rla(arg, immediate)
        elif opcode==0x47:
            cycles = 5
            arg = data[0]
            cycles += self._sre(arg, immediate)
        elif opcode==0x57:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._sre(arg, immediate)
        elif opcode==0x4F:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._sre(arg, immediate)
        elif opcode==0x5F:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._sre(arg, immediate)
        elif opcode==0x5B:
            cycles = 7
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += self._sre(arg, immediate)
        elif opcode==0x43:
            cycles = 8
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._sre(arg, immediate)
        elif opcode==0x53:
            cycles = 8
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += self._sre(arg, immediate)
        elif opcode==0x67:
            cycles = 5
            arg = data[0]
            cycles += self._rra(arg, immediate)
        elif opcode==0x77:
            cycles = 6
            arg = (data[0] + self.X) & 0xFF
            cycles += self._rra(arg, immediate)
        elif opcode==0x6F:
            cycles = 6
            arg = self._from_le(data)
            cycles += self._rra(arg, immediate)
        elif opcode==0x7F:
            cycles = 7
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._rra(arg, immediate)
        elif opcode==0x7B:
            cycles = 7
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += self._rra(arg, immediate)
        elif opcode==0x63:
            cycles = 8
            arg = self._read_word((data[0] + self.X) & 0xFF, wrap_at_page=True)
            cycles += self._rra(arg, immediate)
        elif opcode==0x73:
            cycles = 8
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += self._rra(arg, immediate)
        elif opcode==0x6B:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._arr(arg, immediate)
        elif opcode==0x4B:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._asr(arg, immediate)
        elif opcode==0xAB:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._atx(arg, immediate)
        elif opcode==0x0B or opcode==0x2B:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._aac(arg, immediate)
        elif opcode==0x9F:
            cycles = 5
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += self._axa(arg, immediate)
        elif opcode==0x93:
            cycles = 6
            m = self._read_word(data[0], wrap_at_page=True)
            arg = (m + self.Y) & 0xFFFF
            cycles += self._axa(arg, immediate)
        elif opcode==0xCB:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._axs(arg, immediate)
        elif opcode==0xBB:
            cycles = 4
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += 1 if (data[LO_BYTE] + self.Y) > 0xFF else 0
            cycles += self._lar(arg, immediate)
        elif opcode==0x9E:
            cycles = 5
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += self._sxa(arg, immediate)
        elif opcode==0x9C:
            cycles = 5
            arg = (self._from_le(data) + self.X) & 0xFFFF
            cycles += self._sya(arg, immediate)
        elif opcode==0x8B:
            cycles = 2
            arg = data[0]
            immediate = True
            cycles += self._xaa(arg, immediate)
        elif opcode==0x9B:
            cycles = 5
            arg = (self._from_le(data) + self.Y) & 0xFFFF
            cycles += self._xas(arg, immediate)

        return cycles