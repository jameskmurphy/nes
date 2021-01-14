import logging

from .memory import NESVRAM
from .bitwise import bit_high, set_bit, clear_bit

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

    # bit numbers of some important bits in registers
    # ppu_status
    V_BLANK_BIT = 7             # same for ppu_ctrl

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
        self.ppu_scroll = bytearray(2)  # this contains x-scroll and y-scroll accumulated over two writes
        self._ppu_scroll_ix = 0         # this is a double-write register, so keep track of which byte
        self.ppu_addr = 0               # the accumulated **16-bit** address
        self._ppu_addr_byte = 0         # this is a double-write register, so keep track of which byte

        # last write/valid read of the ppu registers, sometimes reflected in read statuses
        self._io_latch = 0

        # internal statuses
        self.in_vblank = False
        self.sprite_zero_hit = False
        self.sprite_overflow = False

        # status used by emulator
        self.cycles_since_reset = 0
        self.cycles_since_frame = 0  # number of cycles since the frame start
        self.frames_since_reset = 0  # need all three counters (not really, but easier) because frame lengths vary
        self.visible = False         # is the ppu currently outputting to the screen

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

        # tell the screen what rgb value the ppu is using to represent transparency
        if self.screen:
            self.screen.transparent_color = self.transparent_color

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
                trans_c = (trans_c[0]+1, trans_c[1]+1, trans_c[2]+1)

    @property
    def ppu_status(self):
        """
        The ppu status register value (without io latch noise in lower bits)
        :return:
        """
        return (self.VBLANK_MASK * self.in_vblank
         + self.SPRITE0_HIT_MASK * self.sprite_zero_hit
         + self.SPRITE_OVERFLOW_MASK * self.sprite_overflow)

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
            self._ppu_addr_byte = 0
            self._ppu_scroll_ix = 0
            #vblank = self.in_vblank
            #print(self.ppu_status, vblank)

            #self.ppu_status &= ~self.VBLANK_MASK
            #v = (  self.VBLANK_MASK * vblank
            #     + self.SPRITE0_HIT_MASK * self.sprite_zero_hit
            #     + self.SPRITE_OVERFLOW_MASK * self.sprite_overflow
            #     + (0x00011111 & self._io_latch)
            #     )
            #print("ppu status", v)

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
            # todo: PPUDATA read buffer (might be okay not to do this)
            v = self.vram.read(self.ppu_addr)
            self._increment_vram_address()
            self._io_latch = v
            return v

    def write_register(self, register, value):
        """
        Write one of the PPU registers with byte value and do whatever else that entails
        """
        # need to store the last write because it affects the value read on ppu_status
        # "Writing any value to any PPU port, even to the nominally read-only PPUSTATUS, will fill this latch"  [6]

        self._io_latch = value & 0xFF

        #print("write ppu reg: {:02X} --> {} ".format(value, register))

        if register == self.PPU_CTRL:
            # write only
            # can trigger an immediate NMI if we are in vblank and the (allow) vblank NMI trigger flag is flipped high
            trigger_nmi = self.in_vblank \
                          and (value & self.VBLANK_MASK) > 0 \
                          and (self.ppu_ctrl & self.VBLANK_MASK) == 0
            self.ppu_ctrl = value & 0xFF
            if trigger_nmi:
                self._trigger_nmi()
        elif register == self.PPU_MASK:
            # write only
            self.ppu_mask = value & 0xFF
        elif register == self.PPU_STATUS:
            # read only
            pass
        elif register == self.OAM_ADDR:
            # write only
            self.oam_addr = value & 0xFF
        elif register == self.OAM_DATA:
            # read/write
            self.oam[self.oam_addr] = value
            self.oam_addr = (self.oam_addr + 1) & 0xFF
        elif register == self.PPU_SCROLL:
            # write only
            self.ppu_scroll[self._ppu_scroll_ix] = value
            # flip which byte is pointed to on each write; reset on ppu status read
            self._ppu_scroll_ix = 1 - self._ppu_scroll_ix
        elif register == self.PPU_ADDR:
            # write only
            # high byte first
            if self._ppu_addr_byte == 0:
                self.ppu_addr = (self.ppu_addr & 0x00FF) + (value << 8)
            else:
                self.ppu_addr = (self.ppu_addr & 0xFF00) + value
            # flip which byte is pointed to on each write; reset on ppu status read
            self._ppu_addr_byte = 1 - self._ppu_addr_byte
        elif register == self.PPU_DATA:
            # read/write
            self.vram.write(self.ppu_addr, value)
            self._increment_vram_address()

    def pre_render(self):
        self.sprite_zero_hit = False
        self.sprite_overflow = False

    def _increment_vram_address(self):
        self.ppu_addr += 1 if (self.ppu_ctrl & self.VRAM_INCREMENT_MASK) == 0 else 32

    def _trigger_nmi(self):
        self.interrupt_listener.raise_nmi()

    def run_cycles(self, num_cycles):
        # cycles correspond to screen pixels during the screen-drawing phase of the ppu
        # there are three ppu cycles per cpu cycles, at least on NTSC systems
        for cyc in range(num_cycles):
            # current scanline of the frame we are on - this determines behaviour during the line
            line, pixel = self._get_line_and_pixel()

            if line <= 239 and (self.ppu_mask & self.RENDERING_ENABLED_MASK) > 0:
                # visible scanline, set a flag so we can note any interaction during visible periods
                self.visible = True

                # todo: if this line contains sprite zero (and no sprite zero hit already), need to
                # figure out if there has been a sprite zero hit.
                # Idea:  pre-render background (before frame start), check sprite hit, adjust background for scroll things


            else:
                # non-visible
                self.visible = False

            if line == 0 and pixel == 65:
                self._oam_addr_held = self.oam_addr

            # TODO: THIS IS A MASSIVE HACK - REMOVE THIS    ******************************************************
            elif line==50 and pixel == 25:
                self.sprite_zero_hit = True



            elif line == 240 and pixel == 0:
                # post-render scanline, ppu is idle
                # in this emulator, this is when we render the screen
                self.render_screen()
            elif line == 241 and pixel == 1:
                # set vblank flag
                self.in_vblank = True   # set the vblank flag in ppu_status register
                # trigger NMI (if NMI is enabled)
                if (self.ppu_ctrl & self.VBLANK_MASK) > 0:
                    self._trigger_nmi()
            elif line <= 260:
                # during vblank, ppu does no memory accesses; most of the CPU accesses happens here
                pass
            elif line == 261:
                # pre-render scanline for next frame; at dot 1, reset vblank flag in ppu_status
                if pixel == 1:
                    self.in_vblank = False
                elif pixel == self.PIXELS_PER_LINE - 1 - self.frames_since_reset % 2:
                    # this is the last pixel in the frame, so trigger the end-of-frame
                    self._new_frame()

            self.cycles_since_reset += 1
            self.cycles_since_frame += 1

            logging.debug(self.log_line(), extra={"source": "PPU"})

    def log_line(self):
        log = "{:5d}, {:3d}, {:3d}   ".format(self.frames_since_reset, *self._get_line_and_pixel())
        log += "C:{:02X} M:{:02X} S:{:02X} OA:{:02X} OD:{:02X} ".format(self.ppu_ctrl,
                                                                                  self.ppu_mask,
                                                                                  self.ppu_status,
                                                                                  self.oam_addr,
                                                                                  self.oam_data)

        log += "SC:{:02X},{:02X} PA:{:04X}".format(self.ppu_scroll[0],
                                                                   self.ppu_scroll[1],
                                                                   self.ppu_addr)

        return log

    def _get_line_and_pixel(self):
        """
        Determine the current line (up to 261) and pixel of that line (up to 341) we are on given the
        number of cycles that have been run since the start of the frame
        """
        line = int(self.cycles_since_frame / self.PIXELS_PER_LINE)
        pixel = self.cycles_since_frame - self.PIXELS_PER_LINE * line
        return line, pixel

    def _new_frame(self):
        """
        Things to do at the start of a frame
        """
        print("new frame")
        self.frames_since_reset += 1
        self.cycles_since_frame = 0
        # todo: "Vertical scroll bits are reloaded if rendering is enabled" - don't know what this means
        # maybe resets/loads bits 1 and 0 of ppu_ctrl, which controls the base nametable

    def render_screen(self):
        """
        Render the screen in a single go
        """
        # clear to the background color
        background_color = self.rgb_palette[self.vram.read(self.vram.PALETTE_START)]
        self.screen.clear(color=background_color)

        # render the background tiles
        self.render_background()

        # render the sprite tiles
        self.render_sprites()

        # show the screen
        self.screen.show()

    def render_background(self):
        """
        Reads the nametable and attribute table and then sends the result of that for each
        tile on the screen to render_tile to actually render the tile (reading the pattern tables, etc.)
        """
        # which nametable is active?
        nametable = self.ppu_ctrl & self.NAMETABLE_MASK
        addr_base = self.vram.NAMETABLE_START + nametable * self.vram.NAMETABLE_LENGTH_BYTES
        for row in range(self.SCREEN_TILE_ROWS):
            vblock = int(row / 2)
            v_subblock_ix = vblock % 2
            for col in range(self.SCREEN_TILE_COLS):
                # todo: do we need to deal with scrolling and mirroring here?
                tile_index = self.vram.read(addr_base + row * self.SCREEN_TILE_COLS + col)

                # get attribute byte from the attribute table at the end of the nametable
                # these tables compress the palette id into two bits for each 2x2 tile block of 16x16px.
                # the attribute bytes each contain the palette id for a 2x2 block of these 16x16 blocks
                # so get the correct byte and then extract the actual palette id from that
                hblock = int(col / 2)
                attribute_byte = self.vram.read(addr_base
                                                + self.vram.ATTRIBUTE_TABLE_OFFSET
                                                + (int(vblock / 2) * 8 + int(hblock / 2))
                                                )
                h_subblock_ix = hblock % 2
                shift = 4 * v_subblock_ix + 2 * h_subblock_ix
                mask = 0b00000011 << shift
                palette_id = (attribute_byte & mask) >> shift
                palette = self.decode_palette(palette_id, is_sprite=False)
                # ppu_ctrl tells us whether to read the left or right pattern table, so let's fetch that
                tile_bank = (self.ppu_ctrl & self.BKG_PATTERN_TABLE_MASK) > 0
                tile = self.decode_tile(tile_index, tile_bank, palette)
                self.screen.render_tile(col * 8, row * 8, tile)

    def decode_palette(self, palette_id, is_sprite=False):
        """
        If is_sprite is true, then decodes palette from the sprite palettes, otherwise
        decodes from the background palette tables.
        """
        # get the palette colours (these are in hue (chroma) / value (luma) format.)
        # palette_id is in range 0..3, and gives an offset into one of the four background palettes,
        # each of which consists of three colors, each of which is represented by a singe byte
        palette_address = self.vram.PALETTE_START + 16 * is_sprite + 4 * palette_id
        palette = []
        for i in range(4):
            palette.append(self.rgb_palette[self.vram.read(palette_address + i) & 0b00111111])
        return palette

    def decode_tile(self, tile_index, tile_bank, palette, flip_h=False, flip_v=False):
        """
        Decodes a tile given by tile_index from the pattern table specified by tile_bank to an array of RGB color value,
        using the palette supplied.  Transparent pixels (value 0 in the tile) are replaced with self.transparent_color.
        This makes them ready to be blitted to the screen.
        """
        # now decode the tile
        table_base = tile_bank * 0x1000

        # tile index tells us which pattern table to read
        tile_base = table_base + tile_index * self.PATTERN_SIZE_BYTES

        # the (palettized) tile is stored as 2x8byte bit planes, each representing an 8x8 bitmap of depth 1 bit
        # tile here is indexed tile[row][column], *not* tile[x][y]
        tile = [[0] * self.TILE_WIDTH_PX for _ in range(self.TILE_HEIGHT_PX)]

        # todo: this is not very efficient; should probably pre-decode all these tiles as this is slow

        for y in range(self.TILE_HEIGHT_PX):
            for x in range(self.TILE_WIDTH_PX):
                xx = x if not flip_h else self.TILE_WIDTH_PX - 1 - x
                yy = y if not flip_v else self.TILE_HEIGHT_PX - 1 - y
                pixel_color_ix = 0
                for plane in range(2):
                    pixel_color_ix += ((self.vram.read(tile_base + plane * 8 + y) & (0x1 << (7 - x))) > 0) * (plane + 1)
                tile[yy][xx] = palette[pixel_color_ix] if pixel_color_ix > 0 else self.transparent_color
        return tile

    def decode_oam(self):
        """
        Reads the object attribute memory (OAM) to get info about the sprites.  Decodes them and returns
        a list of the sprites in priority order as (x, y, tile, bkg_priority) tuples.
        """
        sprites = []

        # if using 8x16 sprites (True), or 8x8 sprite (False)
        double_sprites = (self.ppu_ctrl & self.SPRITE_SIZE_MASK) > 0
        # pattern table to use for 8x8 sprites, ignored for 8x16 sprites
        tile_bank = (self.ppu_ctrl & self.SPRITE_PATTERN_TABLE_MASK) > 0

        # start here in the OAM
        address = self._oam_addr_held
        for i in range(64):   # up to 64 sprites in OAM  (= 256 bytes / 4 bytes per sprite)
            y = self.oam[address & 0xFF]
            attribs = self.oam[(address + 2) & 0xFF]
            palette_ix = attribs & 0b00000011
            palette = self.decode_palette(palette_ix, is_sprite=True)
            flip_v       = bit_high(attribs, bit=7)      # (attribs & 0b10000000) > 0
            flip_h       = bit_high(attribs, bit=6)      # (attribs & 0b01000000) > 0
            bkg_priority = bit_high(attribs, bit=5)      # (attribs & 0b00100000) > 0
            if not double_sprites:
                tile_ix = self.oam[(address + 1) & 0xFF]
                tile = self.decode_tile(tile_ix, tile_bank, palette, flip_h, flip_v)
            else:
                tile_upper_ix = self.oam[(address + 1) & 0xFF] & 0b11111110
                tile_upper = self.decode_tile(tile_upper_ix, tile_bank, palette, flip_h, flip_v)
                tile_lower = self.decode_tile(tile_upper_ix + 1, tile_bank, palette, flip_h, flip_v)
                tile = tile_upper + tile_lower if not flip_v else tile_lower + tile_upper
            #print((address + 3) & 0xFF)
            x = self.oam[(address + 3) & 0xFF]
            sprites.append((x, y, tile, bkg_priority))
            address += 4
        return sprites

    def render_sprites(self):
        """
        Renders the sprites all in one go.  Still a work in progress!
        """
        # todo: currently renders all sprites on top of everything, starting with lowest priority
        # todo: there are at least two major problems with this:
        #   1. No background priority
        #   2. No max number of sprites
        sprites = self.decode_oam()
        for (x, y, tile, bkg_priority) in reversed(sprites):
            self.screen.render_tile(x, y, tile)


"""
Development Notes
-----------------

TODO before can boot
--------------------
  - Trigger NMI
     \-- can do this easily by return value of PPU run and then just pass to CPU for NMI that is generated from vsync
         but NMI can also be generated from a register write, so have to figure out how to deal with that case.  Could
         just use an interrupt controller that the ppu can write to and the cpu can check.  Or let the ppu have a ref
         to the cpu, and implement a function there that can receive NMI.
  - Write screen renderer
     \-- sprite 0 collision detection (needs to be done during line scan, not render, so can CPU can detect at correct
         time).   One thought on this is to decode sprite 0 early in frame, so then we know where it will render and
         then check the nametable to see if it looks like it is going to collide with something.  It is then possible
         that a mid-frame scroll change could disrupt that but only after the scroll changes, so need to recalculate
         when scroll changes).
  - Gather data about PPU changes during visible period
     |-- scrolling is most important one of these; let's say we draw the bkg at the start of the frame, then when we
     |   see a scroll change, we have to throw away the part of the screen below that and re-render from there.
     \-- Do any other PPU changes matter mid-frame?
  - Scrolling!
     |-- basic scrolling (not during visible period)
     \-- scrolling that accounts for changes during visible (split screen)


Improvements and Corrections
----------------------------
  - Major:  Sprite bkg priority
  - Major:  Max 8 sprites per line  (how does this work when sprites at various y-offsets?)
  - Major:  OAM DMA suspends CPU for 513/514 cycles

  - Minor:  PPUDATA read buffer (might be okay to not do this)
  - Minor:  Background palette hack
  - Minor:  OAMDATA read behaviour during render
  - Minor:  Sprite priority quirk
  - Minor:  Ignore writes to PPUCTRL for 30k cycles after reset

  - Unknown: Vertical scroll bits reloaded at cycles 280-304 of scanline 261 (see _new_frame())

  - Performance:  pre decode tiles if necessary

"""


"""
Plan:
 - Finish ppu renderer
    \--- sprite 0 collision detection
 - PPU NMI trigger
 - Connect ppu and cpu in loop
 - Try to boot!
"""

