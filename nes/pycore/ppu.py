import logging
import time

import pyximport; pyximport.install()

from nes.pycore.memory import NESVRAM
from nes.pycore.bitwise import bit_high, bit_low, set_bit, clear_bit, set_high_byte, set_low_byte
#from nes import LOG_PPU

class NESPPU:
    """
    NES Picture Processing Unit (PPU), the 2C02

    References:
        [1] Overall reference:  https://wiki.nesdev.com/w/index.php/PPU_programmer_reference
        [2] Rendering timing: https://wiki.nesdev.com/w/index.php/PPU_rendering
        [3] OAM layout:  https://wiki.nesdev.com/w/index.php/PPU_OAM

        [4] Detailed operation: http://nesdev.com/2C02%20technical%20operation.TXT

        [5] Palette generator: https://bisqwit.iki.fi/utils/nespalette.php

        [6] Register behaviour: https://wiki.nesdev.com/w/index.php/PPU_registers
        [7] Scrolling: https://wiki.nesdev.com/w/index.php/PPU_scrolling
    """
    NUM_REGISTERS = 8
    OAM_SIZE_BYTES = 256

    # Register indices
    # (this is not just an enum, this is the offset of the register in the CPU memory map from 0x2000)
    PPU_CTRL = 0
    PPU_MASK = 1
    PPU_STATUS = 2
    OAM_ADDR = 3
    OAM_DATA = 4
    PPU_SCROLL = 5
    PPU_ADDR = 6
    PPU_DATA = 7

    # masks for the bits in ppu registers
    # ppu_status
    VBLANK_MASK =               0b10000000  # same for ppu_ctrl
    SPRITE0_HIT_MASK =          0b01000000
    SPRITE_OVERFLOW_MASK =      0b00100000

    # ppu_ctrl
    SPRITE_SIZE_MASK =          0b00100000
    BKG_PATTERN_TABLE_MASK =    0b00010000
    SPRITE_PATTERN_TABLE_MASK = 0b00001000
    VRAM_INCREMENT_MASK =       0b00000100
    NAMETABLE_MASK =            0b00000011

    # ppu_mask
    RENDERING_ENABLED_MASK =    0b00011000
    RENDER_SPRITES_MASK =       0b00010000
    RENDER_BACKGROUND_MASK =    0b00001000
    RENDER_LEFT8_SPRITES_MASK = 0b00000100
    RENDER_LEFT8_BKG_MASK =     0b00000010
    GREYSCALE_MASK =            0b00000001


    # bit numbers of some important bits in registers
    # ppu_status
    V_BLANK_BIT = 7             # same for ppu_ctrl

    # ppu mask
    RENDER_LEFT8_BKG_BIT = 1
    RENDER_LEFT8_SPRITES_BIT = 2

    # byte numbers in ppu scroll
    PPU_SCROLL_X = 0
    PPU_SCROLL_Y = 1

    # screen and sprite/tile sizes:
    PIXELS_PER_LINE = 341       # number of pixels per ppu scanline; only 256 of thes are visible
    SCREEN_HEIGHT_PX = 240      # visible screen height (number of visible rows)
    SCREEN_WIDTH_PX = 256       # visible screen width (number of visible pixels per row)
    TILE_HEIGHT_PX = int(8)          # height of a tile/standard sprite in pixels
    TILE_WIDTH_PX = int(8)           # width of tile/standard sprite in pixels
    SCREEN_TILE_ROWS = 30       # number of rows of background tiles in a single screen
    SCREEN_TILE_COLS = 32       # number of columns of tiles in a single screen
    PATTERN_BITS_PER_PIXEL = 2  # number of bits used to represent each pixel in the patterns

    # the total size of a tile in the pattern table in bytes (== 16)
    PATTERN_SIZE_BYTES = int(TILE_WIDTH_PX * TILE_HEIGHT_PX * PATTERN_BITS_PER_PIXEL / 8)

    # A NES rgb palette mapping from NES color values to RGB; others are possible.
    DEFAULT_NES_PALETTE = [
        ( 82,  82,  82), (  1,  26,  81), ( 15,  15, 101), ( 35,   6,  99),
        ( 54,   3,  75), ( 64,   4,  38), ( 63,   9,   4), ( 50,  19,   0),
        ( 31,  32,   0), ( 11,  42,   0), (  0,  47,   0), (  0,  46,  10),
        (  0,  38,  45), (  0,   0,   0), (  0,   0,   0), (  0,   0,   0),
        (160, 160, 160), ( 30,  74, 157), ( 56,  55, 188), ( 88,  40, 184),
        (117,  33, 148), (132,  35,  92), (130,  46,  36), (111,  63,   0),
        ( 81,  82,   0), ( 49,  99,   0), ( 26, 107,   5), ( 14, 105,  46),
        ( 16,  92, 104), (  0,   0,   0), (  0,   0,   0), (  0,   0,   0),
        (254, 255, 255), (105, 158, 252), (137, 135, 255), (174, 118, 255),
        (206, 109, 241), (224, 112, 178), (222, 124, 112), (200, 145,  62),
        (166, 167,  37), (129, 186,  40), ( 99, 196,  70), ( 84, 193, 125),
        ( 86, 179, 192), ( 60,  60,  60), (  0,   0,   0), (  0,   0,   0),
        (254, 255, 255), (190, 214, 253), (204, 204, 255), (221, 196, 255),
        (234, 192, 249), (242, 193, 223), (241, 199, 194), (232, 208, 170),
        (217, 218, 157), (201, 226, 158), (188, 230, 174), (180, 229, 199),
        (181, 223, 228), (169, 169, 169), (  0,   0,   0), (  0,   0,   0),
    ]

    def __init__(self, cart=None, screen=None, interrupt_listener=None):

        # Registers
        self.ppu_ctrl = 0
        self.ppu_mask = 0
        self.oam_addr = 0
        self._oam_addr_held = 0         # this holds the oam_addr value at a certain point in the frame, when it is fixed for the whole frame
        self.oam_data = 0
        self.ppu_scroll = bytearray(2)  # this contains x-scroll (byte 0) and y-scroll (byte 1) accumulated over two writes
        self.ppu_addr = 0               # the accumulated **16-bit** address
        self._ppu_byte_latch = 0        # latch to keep track of which byte is being written in ppu_scroll and ppu_addr; latch is shared

        # internal latches to deal with open bus and buffering behaviour
        self._ppu_data_buffer = 0       # data to hold buffered reads from VRAM (see read of ppu_data)
        self._io_latch = 0              # last write/valid read of the ppu registers, sometimes reflected in read status

        # internal latches used in background rendering
        self._palette = [self.DEFAULT_NES_PALETTE[0:3], self.DEFAULT_NES_PALETTE[3:6]]     # 2 x palette latches
        self._pattern_lo = 0   # 16 bit patterns register to hold 2 x 8 bit patterns
        self._pattern_hi = 0   # 16 bit patterns register to hold 2 x 8 bit patterns

        # internal memory and latches used in sprite rendering
        self._oam = bytearray(32)      # this is a secondary internal array of OAM used to store sprite that will be active on the next scanline
        self._sprite_pattern = [[None] * 8 for _ in range(8)]
        self._sprite_bkg_priority = [0] * 8
        self._active_sprites = []

        # some state used in rendering to tell us where on the screen we are drawing
        self.line = 0
        self.pixel = 0
        self.row = 0
        self.col = 0
        #self._t = 0
        #self._tN = 0
        #self._tX = 0
        #self._tY = 0

        # internal statuses
        self.in_vblank = False
        self.sprite_zero_hit = False
        self.sprite_overflow = False

        # status used by emulator
        self.cycles_since_reset = 0
        self.cycles_since_frame = 0  # number of cycles since the frame start
        self.frames_since_reset = 0  # need all three counters (not really, but easier) because frame lengths vary
        self.time_at_new_frame = None

        # memory
        self.vram = NESVRAM(cart=cart)
        self.oam = bytearray(self.OAM_SIZE_BYTES)

        # screen attached to PPU
        self.screen = screen

        # interrupt listener
        self.interrupt_listener = interrupt_listener

        # palette: use the default, but can be replaced using utils.load_palette
        self.rgb_palette = self.DEFAULT_NES_PALETTE
        self.transparent_color = self._get_non_palette_color()
        self._palette_cache = [[None] * 4, [None] * 4]

        # tell the screen what rgb value the ppu is using to represent transparency
        if self.screen:
            self.screen.transparent_color = self.transparent_color

    def write_oam(self, data):
        for i in range(self.OAM_SIZE_BYTES):
            self.oam[i] = data[i]

    def invalidate_palette_cache(self):
        self._palette_cache = [[None] * 4, [None] * 4]

    def _get_non_palette_color(self):
        """
        Find a non-palette color in order to represent transparent pixels for blitting
        """
        trans_c = (1, 1, 1)
        while True:
            found = False
            for c in self.rgb_palette:
                if trans_c == c:
                    found = True
                    break
            if not found:
                return trans_c
            else:
                # just explore the grays, there are only 64 colors in palette, so even all
                # greys cannot be represented
                trans_c = (trans_c[0] + 1, trans_c[1] + 1, trans_c[2] + 1)

    @property
    def ppu_status(self):
        """
        The ppu status register value (without io latch noise in lower bits)
        :return:
        """
        return self.VBLANK_MASK * self.in_vblank \
               + self.SPRITE0_HIT_MASK * self.sprite_zero_hit \
               + self.SPRITE_OVERFLOW_MASK * self.sprite_overflow

    def read_register(self, register):
        """
        Read the specified PPU register (and take the correct actions along with that)
        This is mostly (always?) triggered by the CPU reading memory mapped ram at 0x2000-0x3FFF
        "Reading a nominally wrtie-only register will return the latch's current value" [6].
        The "latch" here refers to the capacitance
        of the PPU lines, which leads to some degree of "memory" on the lines, which will hold the last
        value written to a port (including read only ones), or the last value read from a read-only port
        """
        if register == self.PPU_CTRL:
            # write only
            print("WARNING: reading i/o latch")
            return self._io_latch
        elif register == self.PPU_MASK:
            # write only
            print("WARNING: reading i/o latch")
            return self._io_latch
        elif register == self.PPU_STATUS:
            # clear ppu_scroll and ppu_addr latches
            self._ppu_byte_latch = 0   # this is a shared latch between scroll and addr
            #self._ppu_scroll_ix = 0   # ^^^^
            v = self.ppu_status + (0x00011111 & self._io_latch)
            self.in_vblank = False  # clear vblank in ppu_status
            self._io_latch = v
            return v
        elif register == self.OAM_ADDR:
            # write only
            print("WARNING: reading i/o latch")
            return self._io_latch
        elif register == self.OAM_DATA:
            # todo: does not properly implement the weird results of this read during rendering
            v = self.oam[self.oam_addr]
            self._io_latch = v
            return v
        elif register == self.PPU_SCROLL:
            # write only
            print("WARNING: reading i/o latch")
            return self._io_latch
        elif register == self.PPU_ADDR:
            # write only
            print("WARNING: reading i/o latch")
            return self._io_latch
        elif register == self.PPU_DATA:
            if self.ppu_addr < self.vram.PALETTE_START:
                v = self._ppu_data_buffer
                self._ppu_data_buffer = self.vram.read(self.ppu_addr)
            else:
                v = self.vram.read(self.ppu_addr)
                # palette reads will return the palette without buffering, but will put the mirrored NT byte in the read buffer.
                # i.e. reading $3F00 will give you the palette entry at $3F00 and will put the byte in VRAM[$2F00] in the read buffer
                # source: http://forums.nesdev.com/viewtopic.php?t=1721
                self._ppu_data_buffer = self.vram.read(self.ppu_addr - 0x1000)
            self._increment_vram_address()
            self._io_latch = self._ppu_data_buffer
            return v

    def write_register(self, register, value):
        """
        Write one of the PPU registers with byte value and do whatever else that entails
        """
        # need to store the last write because it affects the value read on ppu_status
        # "Writing any value to any PPU port, even to the nominally read-only PPUSTATUS, will fill this latch"  [6]
        self._io_latch = value & 0xFF

        value &= 0xFF  # can only write a byte here

        if register == self.PPU_CTRL:
            # write only
            # writes to ppu_ctrl are ignored at first
            if self.cycles_since_reset < 29658:
                return
            # can trigger an immediate NMI if we are in vblank and the (allow) vblank NMI trigger flag is flipped high
            trigger_nmi = self.in_vblank \
                          and (value & self.VBLANK_MASK) > 0 \
                          and (self.ppu_ctrl & self.VBLANK_MASK) == 0
            self.ppu_ctrl = value
            if trigger_nmi:
                self._trigger_nmi()
        elif register == self.PPU_MASK:
            # write only
            self.ppu_mask = value
        elif register == self.PPU_STATUS:
            # read only
            pass
        elif register == self.OAM_ADDR:
            # write only
            self.oam_addr = value
        elif register == self.OAM_DATA:
            # read/write
            self.oam[self.oam_addr] = value
            # increment the OAM address and wrap around if necessary (wraps to start of page since OAM addr specifies
            # sub-page address)
            self.oam_addr = (self.oam_addr + 1) & 0xFF
        elif register == self.PPU_SCROLL:
            # write only
            self.ppu_scroll[self._ppu_byte_latch] = value
            # flip which byte is pointed to on each write; reset on ppu status read.  Latch shared with ppu_addr.
            self._ppu_byte_latch = 1 - self._ppu_byte_latch
        elif register == self.PPU_ADDR:
            # write only
            # high byte first
            if self._ppu_byte_latch == 0:
                self.ppu_addr = (self.ppu_addr & 0x00FF) + (value << 8)
                # Writes here overwrite the current nametable bits in ppu_ctrl (or at least overwrite bits in an
                # internal latch that is equivalent to this); see [7].  Some games, e.g. SMB, rely on this behaviour
                self.ppu_ctrl = (self.ppu_ctrl & 0b11111100) + ((value & 0b00001100) >> 2)
                # a write here also has a very unusual effect on the coarse and fine y scroll [7]
                self.ppu_scroll[self.PPU_SCROLL_Y] = (self.ppu_scroll[self.PPU_SCROLL_Y] & 0b00111100) + \
                                                     ((value & 0b00000011) << 6) + ((value & 0b00110000) >> 4)
            else:
                self.ppu_addr = (self.ppu_addr & 0xFF00) + value
                # writes here have a weird effect on the x and y scroll values [7]
                # here we just directly change the values of the scroll registers since they are write only and are used
                # only for this (rather than accumulating in a different internal latch _t like shown in [7]).  I think
                # that this is okay.
                self.ppu_scroll[self.PPU_SCROLL_X] = (self.ppu_scroll[self.PPU_SCROLL_X] & 0b00000111) + ((value & 0b00011111) << 3)
                self.ppu_scroll[self.PPU_SCROLL_Y] = (self.ppu_scroll[self.PPU_SCROLL_Y] & 0b11000111) + ((value & 0b11100000) >> 2)
            # flip which byte is pointed to on each write; reset on ppu status read
            self._ppu_byte_latch = 1 - self._ppu_byte_latch
        elif register == self.PPU_DATA:
            # read/write
            self.vram.write(self.ppu_addr, value)
            self._increment_vram_address()
            # invalidate the palette cache if this is a write to the palette memory.  Could be more careful about what
            # is invalidated here so that potentially less recalculation is needed.
            if self.ppu_addr >= self.vram.PALETTE_START:
                self.invalidate_palette_cache()

    def _increment_vram_address(self):
        """
        Increment vram address after reads/writes by an amount specified by a value in ppu_ctrl
        """
        self.ppu_addr += 1 if (self.ppu_ctrl & self.VRAM_INCREMENT_MASK) == 0 else 32

    def _trigger_nmi(self):
        """
        Do whatever is necessary to trigger an NMI to the CPU; note that it is up to the caller to check whether NMIs
        should be generated by the PPU at this time (a flag in ppu_ctrl), and respecting this is critically important.
        """
        self.interrupt_listener.raise_nmi()

    def _prefetch_active_sprites(self, line):
        """
        Non cycle-correct detector for active sprites on the given line.  Returns a list of the indices of the start
        address of the sprite in the OAM
        """
        # scan through the sprites, starting at oam_start_addr, seeing if they are visible in the line given
        # (note that should be the next line); if so, add them to the list of active sprites, until that gets full.
        # if using 8x16 sprites (True), or 8x8 sprite (False)
        double_sprites = (self.ppu_ctrl & self.SPRITE_SIZE_MASK) > 0
        sprite_height = 16 if double_sprites else 8

        self._active_sprites = []
        sprite_line = []
        for n in range(64):
            addr = (self._oam_addr_held + n * 4) % self.OAM_SIZE_BYTES
            sprite_y = self.oam[addr]
            if sprite_y <= line < sprite_y + sprite_height:
                self._active_sprites.append(addr)
                sprite_line.append(line - sprite_y)
                if len(self._active_sprites) >= 9:
                    break
        if len(self._active_sprites) > 8:
            # todo: this implements the *correct* behaviour of sprite overflow, but not the buggy behaviour
            # (and even then it is not cycle correct, so could screw up games that rely on timing of this very exactly)
            self.sprite_overflow = True
            self._active_sprites = self._active_sprites[:8]
            sprite_line = sprite_line[:8]

        self._fill_sprite_latches(self._active_sprites, sprite_line, double_sprites)

    def _fill_sprite_latches(self, active_sprite_addrs, sprite_line, double_sprites):
        """
        Non cycle-correct way to pre-fetch the sprite lines for the next scanline
        """
        table_base = ((self.ppu_ctrl & self.SPRITE_PATTERN_TABLE_MASK) > 0) * 0x1000

        for i, address in enumerate(active_sprite_addrs):
            attribs = self.oam[(address + 2) & 0xFF]
            palette_ix = attribs & 0b00000011
            palette = self.decode_palette(palette_ix, is_sprite=True)
            flip_v = bit_high(attribs, bit=7)
            flip_h = bit_high(attribs, bit=6)
            self._sprite_bkg_priority[i] = bit_high(attribs, bit=5)

            if not double_sprites:
                tile_ix = self.oam[(address + 1) & 0xFF]
                line = sprite_line[i] if not flip_v else 7 - sprite_line[i]
            else:
                line = sprite_line[i] if not flip_v else 15 - sprite_line[i]
                tile_ix = self.oam[(address + 1) & 0xFF] & 0b11111110
                if line >= 8:
                    # in the lower tile
                    tile_ix += 1
                    line -= 8

            tile_base = table_base + tile_ix * self.PATTERN_SIZE_BYTES
            sprite_pattern_lo = self.vram.read(tile_base + line)
            sprite_pattern_hi = self.vram.read(tile_base + 8 + line)

            for x in range(8):
                c = bit_high(sprite_pattern_hi, x) * 2 + bit_high(sprite_pattern_lo, x)
                self._sprite_pattern[i][x if flip_h else 7 - x] = palette[c] if c else None

            #print(self.line, i, sprite_line[i], self._sprite_pattern[i], self.oam[address + 3], self._sprite_bkg_priority[i])

    def _overlay_sprites(self, bkg_pixel):
        """
        Cycle-correct (ish) sprite rendering for the pixel at y=line, pixel=pixel.  Includes sprite 0 collision detection.
        """
        c_out = bkg_pixel
        if (self.ppu_mask & self.RENDER_SPRITES_MASK) == 0 \
            or (self.pixel - 1 < 8 and bit_low(self.ppu_mask, self.RENDER_LEFT8_SPRITES_BIT)):
            return c_out

        sprite_c_out, top_sprite = None, None
        s0_visible = False
        for i in reversed(range(len(self._active_sprites))):
            # render in reverse to make overwriting easier
            sprite_addr = self._active_sprites[i]
            sprite_x = self.oam[sprite_addr + 3]
            if sprite_x <= self.pixel - 1 < sprite_x + 8:
                #print(self.line, i, sprite_x, sprite_addr, self._sprite_bkg_priority[i])
                pix = self.pixel - 1 - sprite_x
                # this sprite is visible now
                c = self._sprite_pattern[i][pix]
                if c:
                    top_sprite = i
                    sprite_c_out = c
                    if sprite_addr == 0:
                        s0_visible = True

        # sprite zero collision detection
        # Details: https://wiki.nesdev.com/w/index.php/PPU_OAM#Sprite_zero_hits
        if s0_visible and bkg_pixel != self.transparent_color:
            # todo: there are some more fine details here
            self.sprite_zero_hit = True

        # now decide whether to keep sprite or bkg pixel
        if sprite_c_out and (not self._sprite_bkg_priority[top_sprite] or bkg_pixel == self.transparent_color):
            c_out = sprite_c_out

        return c_out if c_out != self.transparent_color else self.decode_palette(0)[0]  # background color

    def run_cycles(self, num_cycles):
        # cycles correspond to screen pixels during the screen-drawing phase of the ppu
        # there are three ppu cycles per cpu cycles, at least on NTSC systems
        frame_ended = False
        for cyc in range(num_cycles):
            # current scanline of the frame we are on - this determines behaviour during the line
            if self.line <= 239 and (self.ppu_mask & self.RENDERING_ENABLED_MASK) > 0:
                # visible scanline
                if 0 < self.pixel <= 256:  # pixels 1 - 256
                    # render pixel - 1
                    if (self.pixel - 1) % 8 == 0 and self.pixel > 1:
                        # fill background data latches
                        # todo: this is not cycle-correct, since the read is done atomically at the eighth pixel rather than throughout the cycle.
                        self.shift_bkg_latches()  # move the data from the upper latches into the current ones
                        self.fill_bkg_latches(self.line, self.col + 1)   # get some more data for the upper latches

                    # render background from latches
                    bkg_pixel = self._get_bkg_pixel()
                    # overlay srpite from latches
                    final_pixel = self._overlay_sprites(bkg_pixel)
                    if final_pixel != self.transparent_color:
                        self.screen.write_at(x=self.pixel - 1, y=self.line, color=final_pixel)
                    #self.shift_bkg_latches()
                elif self.pixel == 257:   # pixels 257 - 320
                    # sprite data fetching: fetch data from OAM for sprites on the next scanline
                    # NOTE:  "evaluation applies to the next line's sprite rendering, ... and this is why
                    # there is a 1 line offset on a sprite's Y coordinate."
                    # source: https://wiki.nesdev.com/w/index.php/PPU_sprite_evaluation  (note 1)
                    # this is implemented by passing line + 1 - 1 == line to the prefetch function for next line
                    self._prefetch_active_sprites(self.line)
                elif 321 <= self.pixel <= 336:   # pixels 321 - 336
                    # fill background data latches with data for first two tiles of next scanline
                    if self.pixel % 8 == 1:  # will happen at 321 and 329
                        # fill latches
                        self.shift_bkg_latches()  # move the data from the upper latches into the current ones
                        self.fill_bkg_latches(self.line + 1, int((self.pixel - 321) / 8))  # get some more data for the upper latches
                    #self.shift_bkg_latches()
                else:  # pixels 337 - 340
                    # todo: unknown nametable fetches (used by MMC5)
                    pass

            if self.line == 0 and self.pixel == 65:
                # The OAM address is fixed after this point  [citation needed]
                self._oam_addr_held = self.oam_addr
            elif self.line == 240 and self.pixel == 0:
                # post-render scanline, ppu is idle
                pass
            elif self.line == 241 and self.pixel == 1:
                # set vblank flag
                self.in_vblank = True   # set the vblank flag in ppu_status register
                # trigger NMI (if NMI is enabled)
                if (self.ppu_ctrl & self.VBLANK_MASK) > 0:
                    self._trigger_nmi()
            elif 241 <= self.line <= 260:
                # during vblank, ppu does no memory accesses; most of the CPU accesses happens here
                pass
            elif self.line == 261:
                # pre-render scanline for next frame; at dot 1, reset vblank flag in ppu_status
                if self.pixel == 1:
                    self.in_vblank = False
                    self.sprite_zero_hit = False
                    self.sprite_overflow = False
                elif self.pixel == 257:
                    # load sprite data for next scanline
                    # self._prefetch_active_sprites(line=0)
                    # "Sprite evaluation does not happen on the pre-render scanline. Because evaluation applies to the
                    # next line's sprite rendering, no sprites will be rendered on the first scanline, and this is why
                    # there is a 1 line offset on a sprite's Y coordinate."
                    # source: https://wiki.nesdev.com/w/index.php/PPU_sprite_evaluation  (note 1)
                    self._active_sprites = []
                elif 321 <= self.pixel <= 336:
                    # load data for next scanline
                    if self.pixel % 8 == 1:  # will happen at 321 and 329
                        # fill latches
                        self.shift_bkg_latches()  # move the data from the upper latches into the current ones
                        self.fill_bkg_latches(line=0, col=int((self.pixel - 321) / 8))  # get some more data for the upper latches
                elif self.pixel == self.PIXELS_PER_LINE - 1 - self.frames_since_reset % 2:
                    # this is the last pixel in the frame, so trigger the end-of-frame
                    # (do it below all the counter updates below, though)
                    frame_ended=True

            self.cycles_since_reset += 1
            self.cycles_since_frame += 1
            self.pixel += 1
            if self.pixel > 1 and self.pixel % 8 == 1:
                self.col += 1
            if self.pixel >= self.PIXELS_PER_LINE:
                self.line += 1
                self.pixel = 0
                self.col = 0
                if self.line > 0 and self.line % 8 == 0:
                    self.row += 1

            if frame_ended:
                self._new_frame()

            #logging.log(LOG_PPU, self.log_line(), extra={"source": "PPU"})
        return frame_ended

    def fill_bkg_latches(self, line, col):
        """
        Fill the ppu's rendering latches with the next tile to be rendered
        :return:
        """
        # todo: optimization - a lot of this can be precalculated once and then invalidated if anything changes, since that might only happen once per frame (or never)
        # get the tile from the nametable
        row = int(line / 8)

        # x and y coords of the nametable
        nx0 = bit_high(self.ppu_ctrl, 0)
        ny0 = bit_high(self.ppu_ctrl, 1)

        total_row = (row + ny0 * self.SCREEN_TILE_ROWS + ((self.ppu_scroll[self.PPU_SCROLL_Y] & 0b11111000) >> 3)) % (2 * self.SCREEN_TILE_ROWS)
        total_col = (col + nx0 * self.SCREEN_TILE_COLS + ((self.ppu_scroll[self.PPU_SCROLL_X] & 0b11111000) >> 3)) % (2 * self.SCREEN_TILE_COLS)

        ny = int(total_row / self.SCREEN_TILE_ROWS)
        nx = int(total_col / self.SCREEN_TILE_COLS)

        tile_row = total_row - ny * self.SCREEN_TILE_ROWS
        tile_col = total_col - nx * self.SCREEN_TILE_COLS

        ntbl_base = self.vram.NAMETABLE_START + (ny * 2 + nx) * self.vram.NAMETABLE_LENGTH_BYTES
        tile_addr = ntbl_base + tile_row * self.SCREEN_TILE_COLS + tile_col

        tile_index = self.vram.read(tile_addr)

        tile_bank = (self.ppu_ctrl & self.BKG_PATTERN_TABLE_MASK) > 0
        table_base = tile_bank * 0x1000
        tile_base = table_base + tile_index * self.PATTERN_SIZE_BYTES

        attribute_byte = self.vram.read(ntbl_base
                                        + self.vram.ATTRIBUTE_TABLE_OFFSET
                                        + (int(tile_row / 4) * 8 + int(tile_col / 4))
                                        )

        shift = 4 * (int(tile_row / 2) % 2) + 2 * (int(tile_col / 2) % 2)
        mask = 0b00000011 << shift
        palette_id = (attribute_byte & mask) >> shift

        self._palette[0] = self._palette[1]
        self._palette[1] = self.decode_palette(palette_id, is_sprite=False)

        tile_line = line - 8 * row

        self._pattern_lo = set_low_byte(self._pattern_lo, self.vram.read(tile_base + tile_line))
        self._pattern_hi = set_low_byte(self._pattern_hi, self.vram.read(tile_base + tile_line + 8))

    def shift_bkg_latches(self):
        self._pattern_hi <<= 8
        self._pattern_lo <<= 8

    def _get_bkg_pixel(self):
        if (   self.ppu_mask & self.RENDER_BACKGROUND_MASK) == 0 \
            or (self.pixel - 1 < 8 and bit_low(self.ppu_mask, self.RENDER_LEFT8_BKG_BIT)):
            return self.transparent_color

        fine_x = self.ppu_scroll[self.PPU_SCROLL_X] & 0b00000111
        px = (self.pixel - 1) % 8 + fine_x
        mask = 1 << (15 - px)
        v = ((self._pattern_lo & mask) > 0) + ((self._pattern_hi & mask) > 0) * 2
        return self._palette[int(px / 8)][v] if v > 0 else self.transparent_color

    def log_line(self):
        log = "{:5d}, {:3d}, {:3d}   ".format(self.frames_since_reset, self.line, self.pixel)
        log += "C:{:02X} M:{:02X} S:{:02X} OA:{:02X} OD:{:02X} ".format(self.ppu_ctrl,
                                                                                  self.ppu_mask,
                                                                                  self.ppu_status,
                                                                                  self.oam_addr,
                                                                                  self.oam_data)

        log += "SC:{:02X},{:02X} PA:{:04X}".format(self.ppu_scroll[0],
                                                                   self.ppu_scroll[1],
                                                                   self.ppu_addr)

        return log

    def _new_frame(self):
        """
        Things to do at the start of a frame
        """
        self.frames_since_reset += 1
        self.cycles_since_frame = 0
        self.pixel = 0
        self.line = 0
        self.row = 0
        self.col = 0

        #logging.log(logging.INFO, "PPU frame {} starting".format(self.frames_since_reset), extra={"source": "PPU"})
        # todo: "Vertical scroll bits are reloaded if rendering is enabled" - don't know what this means

    def decode_palette(self, palette_id, is_sprite=False):
        """
        If is_sprite is true, then decodes palette from the sprite palettes, otherwise
        decodes from the background palette tables.
        """
        if self._palette_cache[is_sprite][palette_id]:
            return self._palette_cache[is_sprite][palette_id]

        # get the palette colours (these are in hue (chroma) / value (luma) format.)
        # palette_id is in range 0..3, and gives an offset into one of the four background palettes,
        # each of which consists of three colors, each of which is represented by a singe byte
        palette_address = self.vram.PALETTE_START + 16 * is_sprite + 4 * palette_id
        palette = []
        for i in range(4):
            palette.append(self.rgb_palette[self.vram.read(palette_address + i) & 0b00111111])
        self._palette_cache[is_sprite][palette_id] = palette
        return palette
