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
                 chr_mem_writeable=False,   # whether or not the chr memory is ROM or RAM
                 ram_size_kb=8,
                 prg_start_addr=None,
                 nametable_mirror_pattern=[0, 0, 1, 1]
                 ):
        super().__init__()

        # initialize ram (this ram is on the CPU bus)
        if ram_size_kb not in [2, 4, 8]:
            raise ValueError("Cart 0 ram size should be exactly 2, 4 or 8kB")
        self.ram_size = ram_size_kb * 1024

        # initialize prg rom from supplied data  (CPU connected)
        self.prg_rom_size = len(prg_rom_data)
        if self.prg_rom_size not in [16 * 1024, 32 * 1024]:
            raise ValueError("Cart 0 program rom size should be exactly 16 or 32kB")
        for i in range(self.prg_rom_size):
            # could use e.g. memcpy, but this syntax is clearer and don't care about speed here
            self.prg_rom[i] = prg_rom_data[i]   # copy prg rom data into the prg ROM

        # initialize chr rom from supplied data (otherwise this is just left as empty RAM)
        if chr_rom_data:
            if len(chr_rom_data) != M0_CHR_MEM_SIZE:
                raise ValueError("Cart 0 chr rom size should be exactly 8kB")
            for i in range(M0_CHR_MEM_SIZE):
                self.chr_mem[i] = chr_rom_data[i]

        self.prg_start_addr = PRG_ROM_START if prg_start_addr is None else prg_start_addr
        self.nametable_mirror_pattern = nametable_mirror_pattern
        self.chr_mem_writeable = chr_mem_writeable
        self.prg_rom_writeable = prg_rom_writeable

    cdef unsigned char read(self, int address):
        if address < PRG_ROM_START:
            # RAM access
            return self.ram[address % self.ram_size]
        else:
            # program ROM access
            return self.prg_rom[(address - self.prg_start_addr) % self.prg_rom_size]

    cdef void write(self, int address, unsigned char value):
        if address < PRG_ROM_START:
            # RAM access
            self.ram[address % self.ram_size] = value
        elif self.prg_rom_writeable:
            # program ROM access (but only if allowed to be written, otherwise ignored)
            self.prg_rom[(address - self.prg_start_addr) % self.prg_rom_size] = value

    cdef unsigned char read_ppu(self, int address):
        return self.chr_mem[address % M0_CHR_MEM_SIZE]

    cdef void write_ppu(self, int address, unsigned char value):
        if self.chr_mem_writeable:
            self.chr_mem[address % M0_CHR_MEM_SIZE] = value


### Mapper 002 (aka UNROM) #############################################################################################

#todo!