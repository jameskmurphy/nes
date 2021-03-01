# cython: profile=True, boundscheck=False, nonecheck=False

from .memory cimport NESMappedRAM


cdef enum:

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

    # Used to represent None for integer arguments in some places
    ARG_NONE = -1


cdef class MOS6502:
    cdef NESMappedRAM memory        # the main memory; important that type is decalared so can use c-calling
    cdef object instructions        # the instructions in the original python format; still used for logging etc.

    cdef unsigned char A, X, Y      # registers
    cdef int PC, SP                 # program and stack pointers
    cdef int N, V, D, I, Z, C       # status bits

    cdef long long cycles_since_reset     # cycles since the processor was reset
    cdef int aax_sets_flags, undocumented_support_level, stack_underflow_causes_exception

    # instruction size data table
    cdef int instr_size_bytes[256]


    cdef void make_instruction_data_tables(self)
    cdef int run_instr(self, unsigned char opcode, unsigned char data[2])
    cdef int dma_pause(self, int pause_type, int count)
    cdef int _from_le(self, unsigned char* data)
    cdef int _read_word(self, int addr, int wrap_at_page)
    cdef int trigger_nmi(self)
    cdef int trigger_irq(self)
    cdef int run_next_instr(self)
    cdef unsigned char _status_to_byte(self, bint b_flag)
    cdef void _status_from_byte(self, unsigned char sr_byte)
    cdef void push_stack(self, unsigned char v)
    cdef unsigned char pop_stack(self)
    cdef int _neg(self, int v)
    cdef int _from_2sc(self, unsigned char v)
    cdef void _set_zn(self, int v)

    ##################  The instructions (and their helper functions)  #################################################
    # only the documented instructions are here for now

    cdef int _adc(self, int arg, int immediate)
    cdef int _and(self, int arg, int immediate)
    cdef int _asl(self, int addr, int _)
    cdef int _jump_relative(self, int condition, int offset_2sc)
    cdef int _bcc(self, int offset, int _)
    cdef int _bcs(self, int offset, int _)
    cdef int _beq(self, int offset, int _)
    cdef int _bit(self, int addr, int _)
    cdef int _bmi(self, int offset, int _)
    cdef int _bne(self, int offset, int _)
    cdef int _bpl(self, int offset, int _)
    cdef _interrupt(self, int interrupt_vector, int is_brk)
    cdef int _brk(self, int _, int __)
    cdef int _bvc(self, int offset, int _)
    cdef int _bvs(self, int offset, int _)
    cdef int _clc(self, int _, int __)
    cdef int _cld(self, int _, int __)
    cdef int _cli(self, int _, int __)
    cdef int _clv(self, int _, int __)
    cdef void _compare(self, int v0, int v)
    cdef int _cmp(self, int arg, int immediate)
    cdef int _cpx(self, int arg, int immediate)
    cdef int _cpy(self, int arg, int immediate)
    cdef int _dec(self, int addr, int _)
    cdef int _dex(self, int _, int __)
    cdef int _dey(self, int _, int __)
    cdef int _eor(self, int arg, int immediate)
    cdef int _inc(self, int addr, int _)
    cdef int _inx(self, int _, int __)
    cdef int _iny(self, int _, int __)
    cdef int _jmp(self, int addr, int _)
    cdef int _jsr(self, int addr, int _)
    cdef int _lda(self, int arg, int immediate)
    cdef int _ldx(self, int arg, int immediate)
    cdef int _ldy(self, int arg, int immediate)
    cdef int _lsr(self, int addr, int _)
    cdef int _nop(self, int _, int __)
    cdef int _ora(self, int arg, int immediate)
    cdef int _pha(self, int _, int __)
    cdef int _php(self, int _, int __)
    cdef int _pla(self, int _, int __)
    cdef int _plp(self, int _, int __)
    cdef int _rol(self, int addr, int _)
    cdef int _ror(self, int addr, int _)
    cdef int _rti(self, int _, int __)
    cdef int _rts(self, int _, int __)
    cdef int _sbc(self, int arg, int immediate)
    cdef int _sec(self, int _, int __)
    cdef int _sed(self, int _, int __)
    cdef int _sei(self, int _, int __)
    cdef int _sta(self, int addr, int _)
    cdef int _stx(self, int addr, int _)
    cdef int _sty(self, int addr, int _)
    cdef int _tax(self, int _, int __)
    cdef int _tay(self, int _, int __)
    cdef int _tsx(self, int _, int __)
    cdef int _txa(self, int _, int __)
    cdef int _txs(self, int _, int __)
    cdef int _tya(self, int _, int __)