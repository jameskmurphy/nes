from .memory import NESVRAM
from .carts import NESCart0
from .bitwise import upper_nibble, lower_nibble

class ROM:

    # header byte 6
    MIRROR_MASK        = 0b00000001
    PERSISTENT_MASK    = 0b00000010
    TRAINER_MASK       = 0b00000100
    MIRROR_IGNORE_MASK = 0b00001000
    MAPPER_ID_MASK     = 0b11110000  # shared with header byte 7

    # header byte 7
    NES2_FORMAT_MASK   = 0b00001100

    def __init__(self, filename):
        self.prg_rom_bytes = None
        self.chr_rom_bytes = None
        self.mirror_pattern = None
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

        if filename is not None:
            self.load(filename)

    def load(self, filename):
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
        self.prg_rom_bytes = nesheader[4] * 16384  # in 16kB banks
        self.chr_rom_bytes = nesheader[5] * 8192  # in 8kB banks

        # header byte 6
        self.mirror_pattern = NESVRAM.MIRROR_HORIZONTAL if (nesheader[6] & self.MIRROR_MASK) == 0 \
            else NESVRAM.MIRROR_VERTICAL
        self.has_persistent = (nesheader[6] & self.PERSISTENT_MASK) > 0
        self.has_trainer = (nesheader[6] & self.TRAINER_MASK) > 0
        if (nesheader[6] & self.MIRROR_IGNORE_MASK) > 0:  # if this is set provide 4-page vram
            self.mirror_pattern = NESVRAM.MIRROR_FOUR_SCREEN

        #self.mapper_id = (nesheader[7] & self.MAPPER_ID_MASK) + ((nesheader[6] & self.MAPPER_ID_MASK) >> 4)
        self.mapper_id = upper_nibble(nesheader[7]) * 16 + upper_nibble(nesheader[6])
        self.nes2 = (nesheader[7] & self.NES2_FORMAT_MASK) > 0

        if not self.nes2:
            # header byte 8 (apparently often unused)
            self.prg_ram_size = min(1, nesheader[8]) * 8192
        else:
            # NES 2.0 format
            # https://wiki.nesdev.com/w/index.php/NES_2.0

            # header byte 8
            self.mapper_id += lower_nibble(nesheader[8]) * 256   #  (nesheader[8] & 0b00001111) * 256
            self.submapper_id = upper_nibble(nesheader[8])       #  (nesheader[8] & 0b11110000) >> 4

            # header byte 9
            prg_rom_msb = lower_nibble(nesheader[9])             # (nesheader[9] & 0b00001111)
            if prg_rom_msb == 0xF:
                raise NotImplementedError("NES2 decoding for PRG_ROM_SIZE MSB nibble = 0xF")
            chr_rom_msb = upper_nibble(nesheader[9])             # nesheader[9] & 0b11110000)
            if chr_rom_msb == 0xF:
                raise NotImplementedError("NES2 decoding for CHR_ROM_SIZE MSB nibble = 0xF")

            # header byte 10
            self.prg_ram_bytes = 64 << lower_nibble(nesheader[10])   #(nesheader[10] & 0b00001111)
            self.prg_nvram_bytes = 64 << upper_nibble(nesheader[10]) #((nesheader[10] & 0b11110000) >> 4)

            # header byte 11
            self.chr_ram_bytes = 64 << lower_nibble(nesheader[11])   #(nesheader[11] & 0b00001111)
            self.chr_nvram_bytes = 64 << upper_nibble(nesheader[11]) #((nesheader[11] & 0b11110000) >> 4)

    def get_cart(self, prg_start):
        if self.mapper_id == 0:
            return NESCart0(prg_rom_data=self.prg_rom_data,
                            chr_rom_data=self.chr_rom_data,
                            nametable_mirror_pattern=self.mirror_pattern,
                            prg_start_addr=prg_start
                            )
        else:
            print("Mapper {} not currently supported".format(self.mapper_id))
