# cython: profile=True, boundscheck=True, nonecheck=False, language_level=3
#import pyximport; pyximport.install()

import logging

DEF MIRROR_HORIZONTAL = (0, 0, 1, 1)
DEF MIRROR_VERTICAL = (0, 1, 0, 1)
DEF MIRROR_ONE_LOWER = (0, 0, 0, 0)
DEF MIRROR_ONE_UPPER = (1, 1, 1, 1)

from .bitwise cimport bit_high

cdef class NESCart:
    """
    NES Cartridge interface
    """
    def __init__(self):
        pass

    cdef unsigned char read(self, int address):
        """
        Read from cartridge memory attached to the CPU's memory bus at the (CPU) address specified
        """
        raise NotImplementedError()

    cdef void write(self, int address, unsigned char value):
        """
        Write the given byte to cartridge memory attached to the CPU's memory bus at the (CPU) address specified
        """
        raise NotImplementedError()

    cdef unsigned char read_ppu(self, int address):
        """
        Read from cartridge memory attached to the PPU's memory bus (i.e. in the VRAM address space) at the address
        specified
        """
        raise NotImplementedError()

    cdef void write_ppu(self, int address, unsigned char value):
        """
        Write a byte to the cartridge memory attached to the PPU's memory bus (i.e. in the VRAM address space) at the
        address specified
        """
        raise NotImplementedError()

    cdef void irq_tick(self):
        """
        Function called on rising edges of PPU address line A12, which is used in some carts (MMC3 and derivatives) to
        tick an IRQ counter.  Carts without PPU triggered IRQ functionality can ignore this.
        """
        pass


### Mapper 0 (aka NROM) ################################################################################################

cdef class NESCart0(NESCart):
    """
    Basic NES Cartridge (Type 0 / MMC0).  Consists of up to 8kB RAM, 32kB PRG ROM, 8kB CHR ROM
    """
    def __init__(self,
                 prg_rom_data=None,
                 chr_rom_data=None,
                 prg_rom_writeable=False,   # whether or not the program memory is ROM or RAM
                 ram_size_kb=8,
                 nametable_mirror_pattern=(0, 0, 1, 1)
                 ):
        super().__init__()

        # initialize ram (this ram is on the CPU bus)
        if ram_size_kb not in [2, 4, 8]:
            raise ValueError("Cart 0 ram size should be exactly 2, 4 or 8kB")
        self.ram_size = ram_size_kb * 1024

        # initialize prg rom from supplied data  (CPU connected)
        if prg_rom_data:
            # can use a None value to skip this initializing if calling from e.g. other mappers
            self.prg_rom_size = len(prg_rom_data)
            if self.prg_rom_size not in [16 * 1024, 32 * 1024]:
                raise ValueError("Cart 0 program rom size should be exactly 16 or 32kB")
            for i in range(self.prg_rom_size):
                # could use e.g. memcpy, but this syntax is clearer and don't care about speed here
                self.prg_rom[i] = prg_rom_data[i]   # copy prg rom data into the prg ROM

        # initialize chr rom from supplied data (or create empty RAM if no data supplied)
        if chr_rom_data:
            if len(chr_rom_data) != M0_CHR_MEM_SIZE:
                raise ValueError("Cart 0 chr rom size should be exactly 8kB")
            for i in range(M0_CHR_MEM_SIZE):
                self.chr_mem[i] = chr_rom_data[i]
            # ROM data was supplied, so this is a ROM chip and is not writeable
            self.chr_mem_writeable = False
        else:
            # if no chr_rom_data is supplied, chr_mem should be a RAM chip
            self.chr_mem_writeable = True

        self.prg_start_addr = PRG_ROM_START
        for i in range(4):
            self.nametable_mirror_pattern[i] = nametable_mirror_pattern[i]
        self.prg_rom_writeable = prg_rom_writeable

    cdef unsigned char read(self, int address):
        if address < PRG_ROM_START:
            # RAM access
            return self.ram[address % self.ram_size]
        else:
            # program ROM access
            return self.prg_rom[address % self.prg_rom_size]

    cdef void write(self, int address, unsigned char value):
        if address < PRG_ROM_START:
            # RAM access
            self.ram[address % self.ram_size] = value
        elif self.prg_rom_writeable:
            # program ROM access (but only if allowed to be written, otherwise ignored)
            self.prg_rom[address % self.prg_rom_size] = value

    cdef unsigned char read_ppu(self, int address):
        return self.chr_mem[address % M0_CHR_MEM_SIZE]

    cdef void write_ppu(self, int address, unsigned char value):
        if self.chr_mem_writeable:
            self.chr_mem[address % M0_CHR_MEM_SIZE] = value


### Mapper 1 (aka MMC1, SxROM) #########################################################################################

cdef class NESCart1(NESCart):
    """
    NES Cartridge type 1 (MMC1).  Common cartridge with bank-switched prg and chr rom.  Controlled by an internal shift
    register that writes one of four five-bit internal registers (ctrl, prg_bank, chr_bank[2]) depending on the address
    of the fifth write.

    There are several MMC1 variants!  Not sure how to tell these all of these apart from iNES v1 header...
        MMC1A always has PRG RAM enabled
        MMC1B has PRG RAM enabled by default
        MMC1C has PRG RAM disabled by default

    Of the many MMC1 (SxROM) variants [4], a few have unusual properties that require additional modelling:

        - SOROM, SXROM and SZROM have bank switched RAM, and of these, only SOROM was available outside Japan [4].

        - SOROM has 16kb of PRG RAM (2 banks); bank selection is by bit 3 of the chr_bank register
          - this is the only bank-switched prg_ram variant supported at present

        - SXROM only has two Japan only games [5] and so it is not supported

        - SUROM has 512kb PRG ROM
           - there are only two games listed for this config in the cart database [2], and only a couple in the list [3]
             therefore, it is not (yet?) supported

        - SZROM (not implemented) has a different control bit for PRG RAM

    References:
        [1] https://wiki.nesdev.com/w/index.php/MMC1
        [2] http://bootgod.dyndns.org:7777/
        [3] http://tuxnes.sourceforge.net/nesmapper.txt
        [4] https://wiki.nesdev.com/w/index.php/SxROM
        [5] http://bootgod.dyndns.org:7777/search.php?unif_op=LIKE+`%25%40%25`&unif=SXROM
    """
    def __init__(self,
                 prg_rom_data=None,
                 chr_rom_data=None,
                 chr_mem_writeable=False, # if True, the CHR memory is actually RAM, not ROM
                 prg_ram_size_kb=8,       # size of prg RAM; must be in 8kb multiples, can be 0. RAM is at 0x6000-0x7FFF
                 nametable_mirror_pattern=MIRROR_HORIZONTAL,
                ):
        super().__init__()

        # copy the prg rom data to the memory banks
        self.num_prg_banks = int(len(prg_rom_data) / M1_PRG_ROM_BANK_SIZE)
        if self.num_prg_banks * M1_PRG_ROM_BANK_SIZE != len(prg_rom_data):
            raise ValueError("prg_rom_data size ({} bytes) is not an exact multiple of bank size ({} bytes)".format(len(prg_rom_data), M1_PRG_ROM_BANK_SIZE))

        for bnk in range(self.num_prg_banks):
            for i in range(M1_PRG_ROM_BANK_SIZE):
                self.banked_prg_rom[bnk][i] = prg_rom_data[bnk * M1_PRG_ROM_BANK_SIZE + i]

        if self.num_prg_banks > M1_MAX_PRG_BANKS:
            # this is a 512kb prg rom ROM
            raise ValueError("512kb MMC1 ROMs are not currently supported.  Sorry Dragon Warrior III/IV.")

        # copy the chr rom data to the memory banks
        self.num_chr_banks = int(len(chr_rom_data) / M1_CHR_ROM_BANK_SIZE)
        if self.num_chr_banks * M1_CHR_ROM_BANK_SIZE != len(chr_rom_data):
            raise ValueError("chr_rom_data size ({} bytes) is not an exact multiple of bank size ({} bytes)".format(len(chr_rom_data), M1_CHR_ROM_BANK_SIZE))

        for bnk in range(self.num_chr_banks):
            for i in range(M1_CHR_ROM_BANK_SIZE):
                self.banked_chr_rom[bnk][i] = chr_rom_data[bnk * M1_CHR_ROM_BANK_SIZE + i]

        self.chr_mem_writeable = chr_mem_writeable

        # todo is this the right thing to do here?
        if self.num_chr_banks == 0:
            # if there is no chr rom, make an 8kb bank of ram
            self.num_chr_banks = 2
            self.chr_mem_writeable = True

        # set the startup state of the cart
        self.shift_ctr = 0  # shift counter, triggers when it reaches 5
        self.shift = 0      # shift register to accumulate writes to registers
        # there is only one prg bank switch, which can have one of three different effects depending on ctrl register
        self.prg_bank = 0
        self.chr_bank[:] = [0, 0]  # two chr bank registers
        self.prg_ram_bank = 0
        self.ctrl = 0

        self.num_prg_ram_banks = int(prg_ram_size_kb * BYTES_PER_KB / M1_PRG_RAM_BANK_SIZE)
        if self.num_prg_ram_banks * M1_PRG_RAM_BANK_SIZE != prg_ram_size_kb * BYTES_PER_KB:
            raise ValueError("PRG RAM size must be a multiple of 8kb")
        if self.num_prg_ram_banks > 2:
            raise ValueError("PRG RAM with more than two banks (>16kb) is not supported.  This seems to be a rare format (SUROM or SXROM).")

        # set the nametable mirror pattern
        self.nametable_mirror_pattern[:] = nametable_mirror_pattern

        # set the nametable mirror bits (bottom two) of ctrl to the correct value
        if tuple(nametable_mirror_pattern) == MIRROR_ONE_LOWER:
            self.ctrl |= 0
        elif tuple(nametable_mirror_pattern) == MIRROR_ONE_UPPER:
            self.ctrl |= 1
        elif tuple(nametable_mirror_pattern) == MIRROR_VERTICAL:
            self.ctrl |= 2
        elif tuple(nametable_mirror_pattern) == MIRROR_HORIZONTAL:
            self.ctrl |= 3

        # sets the PRG ROM bank mode to 3 (fix last bank at 0xC000, switch 16kb bank at 0x8000)
        # see control register section in [1], which has a note on startup condition of ctrl
        self.ctrl |= 0b00001100

    cdef void write(self, int address, unsigned char value):
        cdef int bank=0

        if address < M1_PRG_RAM_START:
            # shouldn't be writing here
            pass
        elif M1_PRG_RAM_START <= address < M1_CTRL_REG_START:
            if self.prg_bank & 0b10000 == 0:  # bit 4 being low is prg_ram enable
                if self.num_prg_ram_banks > 1 and (self.chr_bank[0] & 0b1000) > 0:
                    # bank-switched prg ram; only SOROM is supported of this type, and this has the selection bit in
                    # bit 3 of the chr_bank register
                    bank = (self.chr_bank[0] >> 3) & 1
                self.ram[bank][address % M1_PRG_RAM_BANK_SIZE] = value
        elif address >= M1_CTRL_REG_START:
            # everything else is a write to the shift register:
            self._write_shift(address, value)

    cdef void _write_shift(self, int address, unsigned char value):
        """
        Writes one bit to the internal shift register, or resets it.  On the fifth (non-reset) write, the value in the
        shift register is written to one of the internal registers; which one is determined by the address of that
        fifth write.
        :param address:  address to write to; used on fifth write to select register to be written
        :param value: value to write, only msb (reset) and lsb (data) bits are used
        """
        cdef unsigned char data, reset

        data = value & 1          # lsb of value is the data
        reset = (value >> 7) & 1  # msb of value is reset bit

        if reset:
            # "Reset shift register and write Control with (Control OR $0C), locking PRG ROM at $C000-$FFFF to the
            # last bank."
            self.shift = 0
            self.shift_ctr = 0
            self.ctrl |= 0x0C   # sets the PRG ROM bank mode to 3 (fix last bank at 0xC000, switch 16kb bank at 0x8000)
            return

        # put the data into the shift register, shifting the register right and putting the data in 4 (i.e. the 5th bit)
        self.shift = (self.shift >> 1) | (data << 4)
        self.shift_ctr += 1

        #print("{:06b} in shift (#{})".format(self.shift, self.shift_ctr))

        if self.shift_ctr == 5:
            # this was the final write to the register and we can now transfer the contents of the shift register to the
            # internal register in question.  We also reset the shift register (to 0) and counter.
            if M1_CTRL_REG_START <= address < M1_CHR_REG_0_START:
                self.ctrl = self.shift
                # if we've written ctrl, we might have to update the mirror pattern:
                self._set_nametable_mirror_pattern()
                #print("{:06b} written to ctrl".format(self.ctrl))
            elif M1_CHR_REG_0_START <= address < M1_CHR_REG_1_START:
                self.chr_bank[0] = self.shift
                #print("{} written to chr_bank[0]".format(self.chr_bank[0]))
            elif M1_CHR_REG_1_START <= address < M1_PRG_REG_START:
                self.chr_bank[1] = self.shift
                #print("{} written to chr_bank[1]".format(self.chr_bank[1]))
            elif M1_PRG_REG_START <= address:
                self.prg_bank = self.shift
                #print("{} written to prg_bank".format(self.prg_bank))
            #else:
                #print("UNMATCHED SHIFT FINISH {:04X}".format(address))

            self.shift_ctr = 0
            self.shift = 0

    cdef void _set_nametable_mirror_pattern(self):
        """
        Updates the nametable mirror pattern to correspond to the value in ctrl
        """
        cdef int mirror_pattern
        mirror_pattern = self.ctrl & 0b11
        if mirror_pattern == 0:
            self.nametable_mirror_pattern[:] = MIRROR_ONE_LOWER
        elif mirror_pattern == 1:
            self.nametable_mirror_pattern[:] = MIRROR_ONE_UPPER
        elif mirror_pattern == 2:
            self.nametable_mirror_pattern[:] = MIRROR_VERTICAL
        elif mirror_pattern == 3:
            self.nametable_mirror_pattern[:] = MIRROR_HORIZONTAL

    cdef unsigned char read(self, int address):
        """
        Read from the PRG memory (connected to CPU).  The address and the internal state of the ctrl and prg_bank
        registers determine the exact location of the memory read.
        :param address: address to read from
        :return: the one byte contents of the memory at address
        """
        cdef int bank=0, mode=-1
        cdef unsigned char value

        if M1_PRG_RAM_START <= address < M1_PRG_ROM_BANK0_START:
            # There might be more than 1 bank of RAM or non at all, need to check it is enabled
            if self.prg_bank & 0b10000 == 0:  # bit 4 being low is prg_ram enable
                # prg-ram enabled
                if self.num_prg_ram_banks > 1 and (self.chr_bank[0] & 0b1000) > 0:
                    # bank-switched prg ram; only SOROM is supported of this type, and this has the selection bit in
                    # bit 3 of the chr_bank register
                    bank = (self.chr_bank[0] >> 3) & 1
                value = self.ram[bank][address % M1_PRG_RAM_BANK_SIZE]
            else:
                # open-bus behaviour
                # todo: should be open bus behaviour, but not sure yet how to implement this
                value = 0
            return value
        elif M1_PRG_ROM_BANK0_START <= address < M1_PRG_ROM_BANK1_START:
            # read from prg rom bank 0 (this is an address between 0x8000 and 0xBFFF)
            # which bank is bank 0 is determined by the prg rom mode (in ctrl) and the prg_bank register
            mode = (self.ctrl & 0b1100) >> 2
            if mode == 0 or mode == 1:   # 32 kb mode
                # in 32kb mode, ignore lower bit (and in this case we are in the lower of the two 16kb banks, so lsb=0)
                bank = (self.prg_bank & 0b1110) % self.num_prg_banks
            elif mode == 2:
                # bank 0 is fixed to first bank at 0x8000 (but that is the area that address is in, so read first bank)
                # (in 512kb ROMs, even this "fixed" bank is switched to the second page)
                bank = 0
            elif mode == 3:
                # bank 0 is switched according to prg_bank
                bank = (self.prg_bank & 0b1111) % self.num_prg_banks
        elif M1_PRG_ROM_BANK1_START <= address:
            # read from prg rom bank 1 (this is an address between 0xC000 and 0xFFFF)
            # which bank is bank 1 is determined by the prg rom mode (in ctrl) and the prg_bank register
            mode = (self.ctrl & 0b1100) >> 2
            if mode == 0 or mode == 1:  # 32 kb mode
                # in 32kb mode, ignore lower bit of the prg_bank, but now we are in the upper of the two banks, so the
                # lsb must be set to 1
                bank = ((self.prg_bank & 0b1110) + 1) % self.num_prg_banks
            elif mode == 2:
                # bank 1 is switched according to prg_bank
                bank = (self.prg_bank & 0b1111) % self.num_prg_banks
            elif mode == 3:
                # bank 1 is fixed to last bank
                bank = self.num_prg_banks - 1

        value = self.banked_prg_rom[bank][address % M1_PRG_ROM_BANK_SIZE]
        return value

    cdef int _get_chr_bank(self, int address):
        """
        Get the bank in the case of a read/write to the chr memory
        :param address:
        :return:
        """
        cdef int mode_8kb, mask
        # which addressing mode?  8kb or (if this is false) 4kb
        mode_8kb = (self.ctrl & 0b10000) == 0
        # is the address in bank 0 or bank 1?
        address_bank = address >= M1_CHR_ROM_BANK1_START
        # just use the lower line for addressing if only have 2 banks; higher lines might be in use for other things
        mask = 0b00001 if self.num_chr_banks <= 2 else 0b11111
        if mode_8kb:
            # use the address in chr_bank[0], ignoring the low bit.
            # in this case bank (chr_bank[0] & 0b11110) is at 0x0000
            #               and (chr_bank[0] & 0b11110) + 1 is at 0x1000
            mask &= 0b11110
            return (self.chr_bank[0] & mask) + address_bank
        else:
            # 4kb mode
            return self.chr_bank[address_bank] & mask

    cdef void write_ppu(self, int address, unsigned char value):
        """
        Write a byte to CHR memory; should only work in carts with RAM here.
        """
        if not self.chr_mem_writeable:
            # this is a ROM, so do nothing
            return
        self.banked_chr_rom[self._get_chr_bank(address)][address % M1_CHR_ROM_BANK_SIZE] = value

    cdef unsigned char read_ppu(self, int address):
        """
        Read from the chr rom; the exact piece of chr rom read depends on the internal state of the chr_bank registers
        :param address: address to read from
        :return: a byte read from chr rom
        """
        return self.banked_chr_rom[self._get_chr_bank(address)][address % M1_CHR_ROM_BANK_SIZE]


### Mapper 2 (aka UNROM, UOROM) ########################################################################################
# ref: https://wiki.nesdev.com/w/index.php/UxROM

cdef class NESCart2(NESCart0):
    """
    NES Cartridge Type 2 (UNROM / UOROM)
    Much like Mapper 0 above, but has switchable banks of 16kB prg_rom
    """
    def __init__(self,
             prg_rom_data=None,
             chr_rom_data=None,
             prg_rom_writeable=False,   # whether or not the program memory is ROM or RAM
             ram_size_kb=8,
             nametable_mirror_pattern=(0, 0, 1, 1),
             emulate_bus_conflicts=False   # whether or not to emulate bus conflicts on prg_bank select writes
             ):
        super().__init__(prg_rom_data=None,    # don't want to write prg_rom_data to the prg_rom because will be too big
                         chr_rom_data=chr_rom_data,
                         prg_rom_writeable=prg_rom_writeable,
                         ram_size_kb=ram_size_kb,
                         nametable_mirror_pattern=nametable_mirror_pattern,
                         )

        self.prg_bank = 0

        # Write the prg_rom_data to the ROM banks 16kB at a time.  Hopefully the ROM size is divisible by 16kB...
        self.num_prg_banks = int(len(prg_rom_data) / M2_PRG_ROM_BANK_SIZE)

        if self.num_prg_banks * M2_PRG_ROM_BANK_SIZE != len(prg_rom_data):
            raise ValueError("prg_rom_data size is not an integer multiple of 16kB")
        if not self.num_prg_banks in [2**i for i in range(5)]:
            raise ValueError("Number of banks should be a power of two <=16.")

        # Copy the data to the banked_prg_rom banks
        for bnk in range(self.num_prg_banks):
            for i in range(16 * 1024):
                self.banked_prg_rom[bnk][i] = prg_rom_data[bnk * 16 * 1024 + i]

        self.emulate_bus_conflicts = emulate_bus_conflicts

    cdef unsigned char read(self, int address):
        if address < PRG_ROM_START:
            # RAM access
            return self.ram[address % self.ram_size]
        elif address < M2_FIXED_PRG_ROM_START:
            # 0x8000 - 0xBFFF is access to banked prg_rom
            return self.banked_prg_rom[self.prg_bank][address % M2_PRG_ROM_BANK_SIZE]
        else:
            # 0xC000 - 0xFFFF is access to the last 16kB bank
            return self.banked_prg_rom[self.num_prg_banks - 1][address % M2_PRG_ROM_BANK_SIZE]

    cdef void write(self, int address, unsigned char value):
        if address < PRG_ROM_START:
            # RAM access
            self.ram[address % self.ram_size] = value
        else:
            # any write to 0x8000 - 0xFFFF is treated as a write to the bank select register
            if self.emulate_bus_conflicts:
                # Bus conflicts occur because in some carts the ROM outputs the value in the ROM at the given address at the
                # same time as the CPU is trying to write a value to this prg_bank register.  If they are not in agreement
                # a bus conflict occurs and undefined behaviour can result.  A lot of programs get around this by writing to
                # a location containing a value that agrees with the value being written (e.g. write 1 to 0x8000 when 0x8000
                # contains 1, etc.).  It seems like in general 0 wins in bus conflicts, so they can be implemented by ANDing
                # the value being written with the contents of the memory at the given address.
                # see: https://wiki.nesdev.com/w/index.php/UxROM
                #      https://wiki.nesdev.com/w/index.php/Bus_conflict
                value &= self.read(address)

            self.prg_bank = value % self.num_prg_banks


### Mapper 4 (aka MMC3) ################################################################################################
# ref: https://wiki.nesdev.com/w/index.php/MMC3

cdef class NESCart4(NESCart):
    def __init__(self,
                 prg_rom_data=None,
                 chr_rom_data=None,
                 chr_mem_writeable=False, # if True, the CHR memory is actually RAM, not ROM
                 prg_ram_size_kb=8,       # size of prg RAM; must 8kb or 0
                 nametable_mirror_pattern=MIRROR_HORIZONTAL,
                 mirror_pattern_fixed=False,  # if true, the mirror pattern cannot be changed dynamically
                 interrupt_listener=None,
                ):
        super().__init__()

        if prg_ram_size_kb != 8 and prg_ram_size_kb != 0:
            raise ValueError("PRG RAM size must be 8kb or 0")

        # copy the prg rom data to the memory banks
        self.num_prg_banks = int(len(prg_rom_data) / M4_PRG_ROM_BANK_SIZE)
        print("PRG bytes: {}".format(len(prg_rom_data)))
        print("Num PRG banks: {}".format(self.num_prg_banks))
        if self.num_prg_banks * M4_PRG_ROM_BANK_SIZE != len(prg_rom_data):
            raise ValueError("prg_rom_data size ({} bytes) is not an exact multiple of bank size ({} bytes)".format(len(prg_rom_data), M4_PRG_ROM_BANK_SIZE))
        if self.num_prg_banks > M4_MAX_PRG_BANKS:
            raise ValueError("Too much prg rom data ({} bytes) for a MMC3 cartridge (max is 512kb)".format(len(prg_rom_data)))

        for bnk in range(self.num_prg_banks):
            for i in range(M4_PRG_ROM_BANK_SIZE):
                self.banked_prg_rom[bnk][i] = prg_rom_data[bnk * M4_PRG_ROM_BANK_SIZE + i]

        # copy the chr rom data to the memory banks
        self.num_chr_banks = int(len(chr_rom_data) / M4_CHR_ROM_BANK_SIZE)
        print("CHR bytes: {}".format(len(chr_rom_data)))
        print("Num CHR banks: {}".format(self.num_chr_banks))
        if self.num_chr_banks * M4_CHR_ROM_BANK_SIZE != len(chr_rom_data):
            raise ValueError("chr_rom_data size ({} bytes) is not an exact multiple of bank size ({} bytes)".format(len(chr_rom_data), M4_CHR_ROM_BANK_SIZE))

        for bnk in range(self.num_chr_banks):
            for i in range(M4_CHR_ROM_BANK_SIZE):
                self.banked_chr_rom[bnk][i] = chr_rom_data[bnk * M4_CHR_ROM_BANK_SIZE + i]

        self.chr_mem_writeable = chr_mem_writeable

        # todo is this the right thing to do here?
        if self.num_chr_banks == 0:
            # if there is no chr rom, make a full-sized block of chr ram (overwrites user requested chr_mem_writeable)
            self.num_chr_banks = 256
            self.chr_mem_writeable = True

        # set the startup state of the cart
        self.interrupt_listener = interrupt_listener
        self.bank_register[:] = [0, 2, 4, 5, 6, 7, 0, 1]   # copied these from somewhere (didn't help with GunNac)
        self.chr_a12_inversion = False
        self.prg_bank_mode = 0
        self.bank_select = 0
        self.prg_ram_enable = True
        self.prg_ram_protect = False
        self.irq_reload_value = 0xFF
        self.irq_enabled = True
        self.irq_counter = 0xFF

        # set the nametable mirror pattern
        self.nametable_mirror_pattern[:] = nametable_mirror_pattern
        self.mirror_pattern_fixed = mirror_pattern_fixed

    cdef unsigned char read(self, int address):
        cdef int window_slot
        cdef int banks[4]

        if M4_PRG_RAM_START <= address < M4_PRG_ROM_START:
            if self.prg_ram_enable:
                return self.ram[address % M4_PRG_RAM_SIZE]
            else:
                # todo: open bus behaviour
                return 0
        elif M4_PRG_ROM_START <= address:
            if self.prg_bank_mode == 0:
                # bank map in mode 0
                banks[0] = self.bank_register[6] & 0b00111111
                banks[1] = self.bank_register[7] & 0b00111111
                banks[2] = self.num_prg_banks - 2
                banks[3] = self.num_prg_banks - 1
            else:
                # bank map in mode 1
                banks[0] = self.num_prg_banks - 2
                banks[1] = self.bank_register[7] & 0b00111111
                banks[2] = self.bank_register[6] & 0b00111111
                banks[3] = self.num_prg_banks - 1

            window_slot = (address >> 13) & 0b11     # address lines A13 and A14 determine the prg rom slot of address
            return self.banked_prg_rom[banks[window_slot] % self.num_prg_banks][address % M4_PRG_ROM_BANK_SIZE]

    cdef void write(self, int address, unsigned char value):
        if M4_PRG_RAM_START <= address < M4_PRG_ROM_START:
            # ram write
            if self.prg_ram_enable and not self.prg_ram_protect:
                self.ram[address % M4_PRG_RAM_SIZE] = value
        elif BANK_REG_START <= address < MIRROR_PROTECT_REG_START:
            if address & 1 == 0:
                # even address => bank select write
                self.chr_a12_inversion = bit_high(value, 7)
                self.prg_bank_mode = bit_high(value, 6)
                self.bank_select = value & 0b111
            else:
                # odd address => bank data write (write one of the bank registers)
                self.bank_register[self.bank_select] = value

        elif MIRROR_PROTECT_REG_START <= address < IRQ_LATCH_RELOAD_REG_START:
            if address & 1 == 0 and not self.mirror_pattern_fixed:
                # sets nametable mirror pattern
                if value & 1:
                    self.nametable_mirror_pattern[:] = MIRROR_HORIZONTAL
                else:
                    self.nametable_mirror_pattern[:] = MIRROR_VERTICAL
            else:
                # set prg_ram access
                self.prg_ram_enable = bit_high(value, 7)
                self.prg_ram_protect = bit_high(value, 6)
        elif IRQ_LATCH_RELOAD_REG_START <= address < IRQ_ACTIVATE_START:
            if address & 1 == 0:
                self.irq_reload_value = value
            else:
                self.irq_reload = True   # reload irq at next tick
        else:
            # irq is disabled by any write to an even address in this range and activated by a write to any odd address
            # in this range, so we can just use the bottom bit of the address line to set the irq_enabled flag
            self.irq_enabled = address & 1
            if not self.irq_enabled:
                # if interrupts are disabled, any pending interrupts are acknowledged;
                # todo: this will also clear pending interrupts from other IRQ producing devices (the APU), but these
                # should not both be in operation at the same time anyway, since then they can be attempting to drive
                # the line in different directions anyway.
                self.interrupt_listener.reset_irq()

    cdef unsigned int _get_ppu_bank(self, int address):
        cdef int window_slot  # the 1kb slot in the window that this address belongs to
        cdef int banks[8]     # the banks that are mapped to each of the eight slots in the chr address space (each 1kb)
        cdef int double_bank_start, single_bank_start  # which slots the 2kb and 1kb banks start in, respectively

        if not self.chr_a12_inversion:
            double_bank_start, single_bank_start = 0, 4
        else:
            double_bank_start, single_bank_start = 4, 0

        # the chr memory banks corresponding to the 1kb window slots
        banks[double_bank_start + 0] = self.bank_register[0] & 0b11111110
        banks[double_bank_start + 1] = (self.bank_register[0] & 0b11111110) + 1
        banks[double_bank_start + 2] = self.bank_register[1] & 0b11111110
        banks[double_bank_start + 3] = (self.bank_register[1] & 0b11111110) + 1
        banks[single_bank_start + 0] = self.bank_register[2]
        banks[single_bank_start + 1] = self.bank_register[3]
        banks[single_bank_start + 2] = self.bank_register[4]
        banks[single_bank_start + 3] = self.bank_register[5]

        window_slot = (address >> 10) & 0b111   # address lines A10, A11 and A12 determine the slot
        return banks[window_slot] % self.num_chr_banks

    cdef unsigned char read_ppu(self, int address):
        cdef unsigned int bank = self._get_ppu_bank(address)
        return self.banked_chr_rom[bank][address % M4_CHR_ROM_BANK_SIZE]

    cdef void write_ppu(self, int address, unsigned char value):
        cdef unsigned int bank
        if self.chr_mem_writeable:
            bank = self._get_ppu_bank(address)
            self.banked_chr_rom[bank][address % M4_CHR_ROM_BANK_SIZE] = value

    cdef void irq_tick(self):
        if self.irq_reload:
            # if a reload has been triggered, do that and reset the reload flag
            # (add 1 to the counter here because this will be immediately decremented below and there should be N + 1
            # periods between IRQs)
            self.irq_counter = self.irq_reload_value + 1
            self.irq_reload = False

        if self.irq_counter > 0:
            self.irq_counter -= 1

        logging.log(logging.INFO, "IRQ counter = {}".format(self.irq_counter), extra={"source": "Cart"})

        # currently, this implements "normal" or "new" behaviour (https://wiki.nesdev.com/w/index.php/MMC3), so that if
        # the reload value is zero, an irq will be triggered every cycle rather than only once, but this can vary
        # between MMC3 cartridges because on some the irq is only triggered as the counter is decremented to zero.
        # For those old-style chips, writing to reload with the counter at zero will trigger another single IRQ
        # todo: support "old" MMC3A behaviour
        if self.irq_counter == 0:
            self.irq_reload = True  # reload counter next time
            if self.irq_enabled:
                self.interrupt_listener.raise_irq()



