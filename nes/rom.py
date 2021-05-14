import pyximport; pyximport.install()

from .cycore.carts import NESCart0, NESCart1, NESCart2, NESCart4
from nes.pycore.carts import NESCart0 as pyNESCart0
from .pycore.bitwise import upper_nibble, lower_nibble, bit_low, bit_high

class ROM:
    """
    Class for reading ROM data and generating cartridges from it.
    """
    # header byte 6
    MIRROR_BIT = 0
    PERSISTENT_BIT = 1
    TRAINER_BIT = 2
    MIRROR_IGNORE_BIT = 3

    # header byte 7
    NES2_FORMAT_MASK   = 0b00001100

    # mirror patterns
    # The mirror pattern specifies the underlying nametable at locations 0x2000, 0x2400, 0x2800 and 0x3200
    MIRROR_HORIZONTAL = [0, 0, 1, 1]
    MIRROR_VERTICAL = [0, 1, 0, 1]
    MIRROR_FOUR_SCREEN = [0, 1, 2, 3]

    def __init__(self, filename, verbose=True, py_compatibility_mode=False):
        self.py_compatibility_mode = py_compatibility_mode

        self.prg_rom_bytes = None
        self.chr_rom_bytes = None
        self.mirror_pattern = None
        self.mirror_ignore = None
        self.has_persistent = None
        self.has_trainer = None
        self.mapper_id = None
        self.submapper_id = None

        self.nes2 = None

        self.prg_ram_bytes = None
        self.prg_nvram_bytes = None
        self.chr_ram_bytes = None
        self.chr_nvram_bytes = None

        # the data itself
        self.trainer_data = None    # load at 0x7000  (not original data, used for compatibility code)
        self.prg_rom_data = None    # load at 0x8000
        self.chr_rom_data = None
        self.misc_rom_data = None

        # verbose?
        self.verbose = verbose

        if filename is not None:
            self.load(filename)

    def load(self, filename, ):
        """
        Load a ROM in the standard .nes file format
        """
        with open(filename, "rb") as f:
            nesheader = f.read(16)
            self.decode_header(nesheader)
            if self.has_trainer:
                self.trainer_data = f.read(512)
            self.prg_rom_data = f.read(self.prg_rom_bytes)
            self.chr_rom_data = f.read(self.chr_rom_bytes)
            self.misc_rom_data = f.read()  # likely to be empty in almost all cases
            if len(self.misc_rom_data) > 0:
                print("WARNING: MISC ROM DATA IS NOT EMPTY")

    def decode_header(self, nesheader):
        """
        Decode the standard .nes file format header.  Includes support for NES 2.0 format.
        """
        # header bytes 0-3 are fixed to ascii N E S <eof>
        #if not (nesheader[0] == 'N' and nesheader[1] == 'E' and nesheader[2] == 'S' and nesheader[3] == 0x1A):
            #raise ValueError("Invalid .nes file header")

        # header bytes 4 and 5
        self.prg_rom_bytes = nesheader[4] * 16384  # in 16kB banks
        self.chr_rom_bytes = nesheader[5] * 8192   # in 8kB banks

        # header byte 6
        self.mirror_pattern = self.MIRROR_HORIZONTAL if bit_low(nesheader[6], self.MIRROR_BIT) \
            else self.MIRROR_VERTICAL
        self.has_persistent = bit_high(nesheader[6], self.PERSISTENT_BIT)
        self.has_trainer = bit_high(nesheader[6], self.TRAINER_BIT)
        self.mirror_ignore = bit_high(nesheader[6], self.MIRROR_IGNORE_BIT)
        if self.mirror_ignore:  # if this is set, cart provides a 4-page vram
            self.mirror_pattern = self.MIRROR_FOUR_SCREEN

        # header byte 7
        self.mapper_id = upper_nibble(nesheader[7]) * 16 + upper_nibble(nesheader[6])
        self.nes2 = (nesheader[7] & self.NES2_FORMAT_MASK) > 0

        if not self.nes2:
            # header byte 8 (apparently often unused)
            self.prg_ram_bytes = max(1, nesheader[8]) * 8192
            if self.verbose:
                print("iNES (v1) Header")
        else:
            # NES 2.0 format
            # https://wiki.nesdev.com/w/index.php/NES_2.0
            if self.verbose:
                print("NES 2.0 Header")
            # header byte 8
            self.mapper_id += lower_nibble(nesheader[8]) * 256
            self.submapper_id = upper_nibble(nesheader[8])

            # header byte 9
            prg_rom_msb = lower_nibble(nesheader[9])
            if prg_rom_msb == 0xF:
                raise NotImplementedError("NES2 decoding for PRG_ROM_SIZE MSB nibble = 0xF")
            chr_rom_msb = upper_nibble(nesheader[9])
            if chr_rom_msb == 0xF:
                raise NotImplementedError("NES2 decoding for CHR_ROM_SIZE MSB nibble = 0xF")

            # header byte 10
            self.prg_ram_bytes = 64 << lower_nibble(nesheader[10])
            self.prg_nvram_bytes = 64 << upper_nibble(nesheader[10])

            # header byte 11
            self.chr_ram_bytes = 64 << lower_nibble(nesheader[11])
            self.chr_nvram_bytes = 64 << upper_nibble(nesheader[11])

        if self.verbose:
            print("Mapper: {}".format(self.mapper_id))
            print("prg_ram_bytes: {}".format(self.prg_ram_bytes))
            print("chr_ram_bytes: {}".format(self.chr_ram_bytes))
            print("prg_rom_bytes: {}".format(self.prg_rom_bytes))
            print("chr_rom_bytes: {}".format(self.chr_rom_bytes))
            print("mirror pattern: {}".format(self.mirror_pattern))
            #print("chr_ram_bytes: {}".format(self.chr_ram_bytes))

    def get_cart(self, interrupt_listener):
        """
        Get the correct type of cartridge object from this ROM, ready to be plugged into the NES system
        """
        if self.py_compatibility_mode:
            if self.mapper_id==0:
                return pyNESCart0(prg_rom_data=self.prg_rom_data,
                                chr_rom_data=self.chr_rom_data,
                                nametable_mirror_pattern=self.mirror_pattern,
                                )
            else:
                print("Mapper {} not currently supported in py_compatibility_mode".format(self.mapper_id))

        if self.mapper_id == 0:
            return NESCart0(prg_rom_data=self.prg_rom_data,
                            chr_rom_data=self.chr_rom_data,
                            nametable_mirror_pattern=self.mirror_pattern,
                            )
        elif self.mapper_id == 1:
            if self.chr_ram_bytes and (self.chr_ram_bytes != len(self.chr_rom_data)):
                raise ValueError("CHR RAM requested, but have not allocated the correct amount.")
            return NESCart1(prg_rom_data=self.prg_rom_data,
                            chr_rom_data=self.chr_rom_data,
                            prg_ram_size_kb=self.prg_ram_bytes / 1024,
                            chr_mem_writeable=True if self.chr_ram_bytes else False,
                            nametable_mirror_pattern=self.mirror_pattern,
                           )
        elif self.mapper_id == 2:
            return NESCart2(prg_rom_data=self.prg_rom_data,
                            chr_rom_data=self.chr_rom_data,
                            nametable_mirror_pattern=self.mirror_pattern,
                           )
        elif self.mapper_id == 4:
            # MMC 3
            return NESCart4(prg_rom_data=self.prg_rom_data,
                            chr_rom_data=self.chr_rom_data,
                            prg_ram_size_kb=self.prg_ram_bytes / 1024,
                            chr_mem_writeable=True if self.chr_ram_bytes else False,
                            nametable_mirror_pattern=self.mirror_pattern,
                            mirror_pattern_fixed=self.mirror_ignore,
                            interrupt_listener=interrupt_listener
                           )
        else:
            print("Mapper {} not currently supported".format(self.mapper_id))
