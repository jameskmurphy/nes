# cython: profile=True, boundscheck=False, nonecheck=False

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


### Mapper 000 (aka NROM) ##############################################################################################

cdef class NESCart0(NESCart):
    """
    Basic NES Cartridge (Type 0 / MMC0).  Consists of up to 8kB RAM, 32kB PRG ROM, 8kB CHR ROM
    """
    def __init__(self,
                 prg_rom_data=None,
                 chr_rom_data=None,
                 prg_rom_writeable=False,   # whether or not the program memory is ROM or RAM
                 ram_size_kb=8,
                 nametable_mirror_pattern=[0, 0, 1, 1]
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
        self.nametable_mirror_pattern = nametable_mirror_pattern
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
             nametable_mirror_pattern=[0, 0, 1, 1],
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
