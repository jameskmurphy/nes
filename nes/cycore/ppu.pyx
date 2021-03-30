# cython: profile=True, boundscheck=True, nonecheck=False, language_level=3
# import pyximport; pyximport.install()

# important to cimport these rather than import them because that makes them have a lot less python interaction
from .bitwise cimport bit_high, bit_low, set_bit, clear_bit, set_high_byte, set_low_byte
from .memory cimport NESVRAM, PALETTE_START, NAMETABLE_START, NAMETABLE_LENGTH_BYTES, ATTRIBUTE_TABLE_OFFSET

# A NES rgb palette mapping from NES color values to RGB; others are possible.
cdef int[64][3] DEFAULT_NES_PALETTE = [
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

cdef class NESPPU:
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
    def __init__(self, cart=None, interrupt_listener=None, palette=None):

        # Registers
        self.ppu_ctrl = 0
        self.ppu_mask = 0
        self.oam_addr = 0
        self.oam_data = 0
        self.ppu_scroll[:] = [0, 0]     # this contains x-scroll (byte 0) and y-scroll (byte 1) accumulated over two writes
        self.ppu_addr = 0               # the accumulated **16-bit** address
        self._ppu_byte_latch = 0        # latch to keep track of which byte is being written in ppu_scroll and ppu_addr; latch is shared

        # internal latches to deal with open bus and buffering behaviour
        self._ppu_data_buffer = 0       # data to hold buffered reads from VRAM (see read of ppu_data)
        self._io_latch = 0              # last write/valid read of the ppu registers, sometimes reflected in read status

        # internal latches used in background rendering
        self._palette = [[0, 1, 2, 3], [4, 5, 6, 7]]
        self._pattern_lo = 0   # 16 bit patterns register to hold 2 x 8 bit patterns
        self._pattern_hi = 0   # 16 bit patterns register to hold 2 x 8 bit patterns

        # internal memory and latches used in sprite rendering
        self._sprite_pattern = [[0] * 8 for _ in range(8)]
        self._sprite_bkg_priority = [0] * 8
        self._num_active_sprites = 0

        # some state used in rendering to tell us where on the screen we are drawing
        self.line = 0
        self.pixel = 0

        # internal statuses
        self.in_vblank = False
        self.sprite_zero_hit = False
        self.sprite_overflow = False
        self.ignore_ppu_ctrl = True   # on startup, ignore writes to ppu_ctrl for about 30k cycles

        # status used by emulator
        self.cycles_since_reset = 0
        self.frames_since_reset = 0  # need all three counters (not really, but easier) because frame lengths vary

        # memory
        self.vram = NESVRAM(cart=cart)

        # interrupt listener
        self.interrupt_listener = interrupt_listener

        # palette: use the default, but can be replaced using utils.load_palette
        self.set_hex_palette(palette if palette is not None else DEFAULT_NES_PALETTE)
        self.transparent_color = -1

        self._palette_cache_valid[:] = [0, 0, 0, 0, 0, 0, 0, 0]
        self.irq_tick_triggers[:] = [False] * 68

    def set_hex_palette(self, rgb_palette):
        for i, c in enumerate(rgb_palette):
            self.hex_palette[i] = (c[0] << 16) + (c[1] << 8) + c[2]

    ################ Copy OAM data #####################################################################################

    cdef void write_oam(self, unsigned char* data):
        cdef int i
        for i in range(OAM_SIZE_BYTES):
            self.oam[i] = data[i]

    ################ Register reading and writing ######################################################################

    cdef unsigned char ppu_status(self):
        """
        The ppu status register value (without io latch noise in lower bits)
        :return:
        """
        return VBLANK_MASK * self.in_vblank \
               + SPRITE0_HIT_MASK * self.sprite_zero_hit \
               + SPRITE_OVERFLOW_MASK * self.sprite_overflow

    cdef unsigned char read_register(self, int register):
        """
        Read the specified PPU register (and take the correct actions along with that)
        This is mostly (always?) triggered by the CPU reading memory mapped ram at 0x2000-0x3FFF
        "Reading a nominally write-only register will return the latch's current value" [6].
        The "latch" here refers to the capacitance
        of the PPU lines, which leads to some degree of "memory" on the lines, which will hold the last
        value written to a port (including read only ones), or the last value read from a read-only port
        """

        cdef unsigned char v

        if register == PPU_CTRL:
            # write only
            return self._io_latch
        elif register == PPU_MASK:
            # write only
            return self._io_latch
        elif register == PPU_STATUS:
            # clear ppu_scroll and ppu_addr latches
            self._ppu_byte_latch = 0   # this is a shared latch between scroll and addr
            v = self.ppu_status() + (0x00011111 & self._io_latch)
            self.in_vblank = False  # clear vblank in ppu_status
            self._io_latch = v
            return v
        elif register == OAM_ADDR:
            # write only
            return self._io_latch
        elif register == OAM_DATA:
            # todo: does not properly implement the weird results of this read during rendering
            v = self.oam[self.oam_addr]
            self._io_latch = v
            return v
        elif register == PPU_SCROLL:
            # write only
            return self._io_latch
        elif register == PPU_ADDR:
            # write only
            return self._io_latch
        elif register == PPU_DATA:
            if self.ppu_addr < PALETTE_START:
                v = self._ppu_data_buffer
                self._ppu_data_buffer = self.vram.read(self.ppu_addr)
            else:
                v = self.vram.read(self.ppu_addr)
                # palette reads will return the palette without buffering, but will put the mirrored NT byte in the
                # read buffer, i.e. reading $3F00 will give you the palette entry at $3F00 and will put the byte in
                # VRAM[$2F00] in the read buffer
                # source: http://forums.nesdev.com/viewtopic.php?t=1721
                self._ppu_data_buffer = self.vram.read(self.ppu_addr - 0x1000)
            self._increment_vram_address()
            self._io_latch = self._ppu_data_buffer
            return v

    cdef void write_register(self, int register, unsigned char value):
        """
        Write one of the PPU registers with byte value and do whatever else that entails
        """
        # need to store the last write because it affects the value read on ppu_status
        # "Writing any value to any PPU port, even to the nominally read-only PPUSTATUS, will fill this latch"  [6]
        cdef int trigger_nmi, n_chng, prev_ppu_addr
        value &= 0xFF  # can only write a byte here
        self._io_latch = value

        if register == PPU_CTRL:
            # write only
            # writes to ppu_ctrl are ignored at first
            # this is a slightly safer mechanism to implement this rather than relying on cycles_since_reset, which
            # caused a bug by overflowing
            if self.ignore_ppu_ctrl:
                if self.cycles_since_reset < 29658:
                    return
                else:
                    self.ignore_ppu_ctrl = False
            # can trigger an immediate NMI if we are in vblank and the (allow) vblank NMI trigger flag is flipped high
            trigger_nmi = self.in_vblank \
                          and (value & VBLANK_MASK) > 0 \
                          and (self.ppu_ctrl & VBLANK_MASK) == 0
            self.ppu_ctrl = value
            if trigger_nmi:
                self._trigger_nmi()
        elif register == PPU_MASK:
            # write only
            self.ppu_mask = value
        elif register == PPU_STATUS:
            # read only
            pass
        elif register == OAM_ADDR:
            # write only
            self.oam_addr = value
        elif register == OAM_DATA:
            # read/write
            self.oam[self.oam_addr] = value
            # increment the OAM address and wrap around if necessary (wraps to start of page since OAM addr specifies
            # sub-page address)
            self.oam_addr = (self.oam_addr + 1) & 0xFF
        elif register == PPU_SCROLL:
            # write only
            self.ppu_scroll[self._ppu_byte_latch] = value
            # flip which byte is pointed to on each write; reset on ppu status read.  Latch shared with ppu_addr.
            self._ppu_byte_latch = 1 - self._ppu_byte_latch
            #print("set scroll: line {}, px {}, y-scroll: {}".format(self.line, self.pixel, self.ppu_scroll[PPU_SCROLL_Y]))
        elif register == PPU_ADDR:
            # write only
            # high byte first
            if self._ppu_byte_latch == 0:
                prev_ppu_addr = self.ppu_addr
                self.ppu_addr = (self.ppu_addr & 0x00FF) + (value << 8)
                # Writes here overwrite the current nametable bits in ppu_ctrl (or at least overwrite bits in an
                # internal latch that is equivalent to this); see [7].  Some games, e.g. SMB, rely on this behaviour
                self.ppu_ctrl = (self.ppu_ctrl & 0b11111100) + ((value & 0b00001100) >> 2)

                # a write here also has a very unusual effect on the coarse and fine y scroll [7]
                # (note that bit 2 of PPU_SCROLL_Y is always set to 0 by this)
                self.ppu_scroll[PPU_SCROLL_Y] = (self.ppu_scroll[PPU_SCROLL_Y] & 0b00111000) + \
                                                     ((value & 0b00000011) << 6) + ((value & 0b00110000) >> 4)
                if bit_low(prev_ppu_addr, 12) and bit_high(self.ppu_addr, 12):
                    self.vram.cart.irq_tick()

                #print("set scroll: line {}, px {}, y-scroll: {}".format(self.line, self.pixel, self.ppu_scroll[PPU_SCROLL_Y]))
            else:
                self.ppu_addr = (self.ppu_addr & 0xFF00) + value
                # writes here have a weird effect on the x and y scroll values [7]
                self.ppu_scroll[PPU_SCROLL_X] = (self.ppu_scroll[PPU_SCROLL_X] & 0b00000111) + ((value & 0b00011111) << 3)
                self.ppu_scroll[PPU_SCROLL_Y] = (self.ppu_scroll[PPU_SCROLL_Y] & 0b11000111) + ((value & 0b11100000) >> 2)

                # side effect is that y-scroll is changed immediately, allowing mid-frame y-scroll changes
                # this only happens on the second write to ppu_addr
                self._reset_effective_y()
                #print("set scroll: line {}, px {}, y-scroll: {} (IMMEDIATE)".format(self.line, self.pixel, self.ppu_scroll[PPU_SCROLL_Y]))

            # flip which byte is pointed to on each write; reset on ppu status read
            self._ppu_byte_latch = 1 - self._ppu_byte_latch
        elif register == PPU_DATA:
            # read/write
            #print("write {:02X} to {:04X}".format(value, self.ppu_addr))
            self.vram.write(self.ppu_addr, value)
            self._increment_vram_address()
            # invalidate the palette cache if this is a write to the palette memory.  Could be more careful about what
            # is invalidated here so that potentially less recalculation is needed.
            if self.ppu_addr >= PALETTE_START:
                self.invalidate_palette_cache()


    ################ Screen buffer copy and clear ######################################################################

    cdef int get_background_color(self):
        """
        Get the background color for the screen (set by color zero of palette zero)
        :return:
        """
        cdef int p0[4]
        self.decode_palette(p0, 0, False)
        return self.hex_palette[p0[0]]

    cdef void _clear_to_bkg(self):
        """
        Clears the screen buffer to the background color (which is set by palette 0)
        :return:
        """
        cdef int cc, x, y

        cc = self.get_background_color()
        for x in range(SCREEN_WIDTH_PX):
            for y in range(SCREEN_HEIGHT_PX):
                self.screen_buffer[x][y] = cc

    cpdef void copy_screen_buffer_to(self, unsigned int[:, :] dest, bint v_overscan=False, bint h_overscan=False):
        """
        Copy the screen buffer to a supplied destination.  Up to the caller to ensure that the destination buffer
        has sufficient space to write into.
        """
        cdef start_line=VERTICAL_OVERSCAN_PX, end_line=SCREEN_HEIGHT_PX - VERTICAL_OVERSCAN_PX
        cdef start_row=HORIZONTAL_OVERSCAN_PX, end_row=SCREEN_WIDTH_PX - HORIZONTAL_OVERSCAN_PX
        if v_overscan:
            start_line = 0
            end_line = SCREEN_HEIGHT_PX
        if h_overscan:
            start_row = 0
            end_row = SCREEN_WIDTH_PX
        # create a memory view to the screen to allow it to be treated as a buffer in the Numpy-esque style
        cdef unsigned int[:, :] scr_mv = <unsigned int[:SCREEN_WIDTH_PX, :SCREEN_HEIGHT_PX]>self.screen_buffer
        dest[:, :] = scr_mv[start_row:end_row, start_line:end_line]


    ################ Main cycle running ################################################################################

    cdef int run_cycles(self, int num_cycles):
        """
        The main function of the PPU that steps it forward the specified number of cycles.  Cycles correspond to screen
        pixels during the screen-drawing phase of the ppu there are three ppu cycles per cpu cycles, at least on NTSC
        systems.
        :param num_cycles: the number of PPU cycles (not cpu cycles!).
        :return: whether vblank started during the cycles run
        """
        cdef int cyc
        cdef bint vblank_started=False

        for cyc in range(num_cycles):
            # current scanline of the frame we are on - this determines behaviour during the line
            if self.line <= 239 and (self.ppu_mask & RENDERING_ENABLED_MASK) > 0:
                self.render_visible_scanline()
            elif self.line == 241 and self.pixel == 1:
                # set vblank flag
                vblank_started = True   # this is used by the emulator to know when it can flip the screen
                self.in_vblank = True   # set the vblank flag in ppu_status register
                # trigger NMI (if NMI is enabled)
                if (self.ppu_ctrl & VBLANK_MASK) > 0:
                    self._trigger_nmi()
            elif self.line == 261:
                # line 261 is also sometimes called line -1 and is the pre-render scanline
                self.prerender_scanline()

            self.increment_pixel()

        return vblank_started

    cdef void prerender_scanline(self):
        """
        The pre-render scanline (line 261) has some special things that happen on it like turning off vblank and
        starting to do the background pre-fetch.
        """
        if self.pixel == 1:
            # At dot 1, reset vblank flag in ppu_status
            self.in_vblank = False
            self.sprite_zero_hit = False
            self.sprite_overflow = False
        elif self.pixel == 257:
            # "Sprite evaluation does not happen on the pre-render scanline. Because evaluation applies to the
            # next line's sprite rendering, no sprites will be rendered on the first scanline, and this is why
            # there is a 1 line offset on a sprite's Y coordinate."
            # source: https://wiki.nesdev.com/w/index.php/PPU_sprite_evaluation  (note 1)
            self._num_active_sprites = 0
            # reset the x counter to the start of the line
            self._effective_x = self.ppu_scroll[PPU_SCROLL_X] + (bit_high(self.ppu_ctrl, BIT_NAMETABLE_X) << 8)
        elif self.pixel == 260 and (self.ppu_mask & RENDERING_ENABLED_MASK) > 0:
            # for simplicity, always trigger the irq_tick once at pixel 260 on the pre-render scanline; this might be
            # wrong by a few pixels for this line, but it probably won't matter most of the time
            # todo: more correct behaviour here (what is it in the case of double-height sprites?)
            self.vram.cart.irq_tick()
        elif self.pixel == 280:
            # "Vertical scroll bits are reloaded if rendering is enabled"
            self._reset_effective_y()
        elif self.pixel == 328 or self.pixel == 336:
            # load background data for next scanline
            self.fill_bkg_latches()  # get some more data for the upper latches
        elif self.pixel == 339:
            # about the last pixel of the pre-render, so clear the display ready for the next frame
            self._clear_to_bkg()

    cdef void render_visible_scanline(self):
        """
        Render a pixel on a visible scanline (lines 0-239 inclusive)
        """
        cdef int bkg_pixel, final_pixel, coarse_y, cmask, double_sprites, sprite_table

        if 0 < self.pixel <= 256:  # pixels 1 - 256
            # render pixel - 1
            if (self.pixel - 1) % 8 == 0 and self.pixel > 1:
                # fill background data latches
                # todo: this is not cycle-correct, since the read is done atomically at the eighth pixel rather than throughout the cycle.
                self.fill_bkg_latches()   # get some more data for the upper latches
            # render background from latches
            bkg_pixel = self._get_bkg_pixel()
            # overlay sprite from latches
            final_pixel = self._overlay_sprites(bkg_pixel)
            # monochrome mode if bit 0 of ppu_mask is set
            cmask = 0x30 if (self.ppu_mask & 1) else 0xFF
            if final_pixel != self.transparent_color:
                self.screen_buffer[self.pixel - 1][self.line] = self.hex_palette[final_pixel & cmask]
        elif self.pixel == 257:   # pixels 257 - 320
            # sprite data fetching: fetch data from OAM for sprites on the next scanline
            # NOTE:  "evaluation applies to the next line's sprite rendering, ... and this is why
            # there is a 1 line offset on a sprite's Y coordinate."
            # source: https://wiki.nesdev.com/w/index.php/PPU_sprite_evaluation  (note 1)
            self._prefetch_active_sprites()
            # reset the x counter to the start of the line
            self._effective_x = self.ppu_scroll[PPU_SCROLL_X] + (bit_high(self.ppu_ctrl, BIT_NAMETABLE_X) << 8)
        elif self.pixel == 280:
            # increment y to next row
            if (self._effective_y & 0xFF) == 239:  # can only go up to 239 before wrapping to 256
                self._effective_y += 17  # skip over the attribute table to the next nametable (equivalent to 2 rows)
            elif (self._effective_y & 0xFF) == 255:  # but if scroll is set into the "illegal zone"
                # if scroll is set into the out-of-bounds zone between lines 240-255, that is okay, which causes the
                # attribute table to be read as tile data; this achieves a sort of negative scroll that some games use
                # especially noticable in the bouncing of the SMB3 logo in the title sequence of SMB3, which will not
                # work properly without this obscure behaviour. See https://wiki.nesdev.com/w/index.php/PPU_scrolling
                self._effective_y &= 0x100
            else:
                self._effective_y += 1
        elif self.pixel == 328 or self.pixel == 336:   # pixels 321 - 336
            # fill background data latches with data for first two tiles of next scanline
            self.fill_bkg_latches()  # get some more data for the upper latches
        else:  # pixels 337 - 340
            # todo: garbage nametable fetches (used by MMC5)
            pass

        if 257 <= self.pixel <= 324:  # sprite fetching period
            # sprite fetch has already happened on pixel 257 (above), but it is possible that, if using double sprites
            # irq ticks could be triggered here; the timings of these were precalculated during sprite fetch and put
            # into the irq_tick_triggers array, so all we have to do here is test if this pixel has the trigger be true
            if self.irq_tick_triggers[self.pixel - 257]:
                self.vram.cart.irq_tick()

    cdef void increment_pixel(self):
        """
        Increment the current pixel by 1 and, if necessary, move to the next line or even frame.
        """
        self.cycles_since_reset += 1
        self.pixel += 1
        # need to check if we are in the last *two* pixels because the frame sometimes ends one pixel early
        if self.pixel >= PIXELS_PER_LINE - 1:
            if self.line == 261 and self.pixel == PIXELS_PER_LINE - self.frames_since_reset % 2:
                # frame has ended
                self.pixel = 0
                self.line = 0
                self.frames_since_reset += 1
            elif self.pixel == PIXELS_PER_LINE:
                # just this line has ended
                self.line += 1
                self.pixel = 0

    cdef void _increment_vram_address(self):
        """
        Increment vram address after reads/writes by an amount specified by a value in ppu_ctrl
        """
        cdef int prev_ppu_addr = self.ppu_addr
        self.ppu_addr += 1 if (self.ppu_ctrl & VRAM_INCREMENT_MASK) == 0 else 32
        if bit_low(prev_ppu_addr, 12) and bit_high(self.ppu_addr, 12):
            # if line A12 changes from low to high, trigger an irq counter tick in the cartridge (MMC3 and derivatives)
            self.vram.cart.irq_tick()

    cdef void _trigger_nmi(self):
        """
        Do whatever is necessary to trigger an NMI to the CPU; note that it is up to the caller to check whether NMIs
        should be generated by the PPU at this time (a flag in ppu_ctrl), and respecting this is critically important.
        """
        self.interrupt_listener.raise_nmi()

    cdef void _reset_effective_y(self):
        # slightly complicated by the 30 (x 8px) row height of the screen, so if y >= 240, should bump it by 16 to
        # account for the fact that the attribute table has been crossed.
        self._effective_y = (self.ppu_scroll[PPU_SCROLL_Y] + (bit_high(self.ppu_ctrl, BIT_NAMETABLE_Y) << 8)) & 0x1FF
        if self.ppu_scroll[PPU_SCROLL_Y] >= 240:
            pass
            #self._effective_y += 16
        #if self.line==261:
         #   print(self.line, self.pixel, self._effective_y, self.ppu_scroll[PPU_SCROLL_Y], bit_high(self.ppu_ctrl, BIT_NAMETABLE_Y))


    ################ Sprite decoding and rendering #####################################################################

    cdef void _prefetch_active_sprites(self):
        """
        Non cycle-correct detector for active sprites on the given line.  Returns a list of the indices of the start
        address of the sprite in the OAM
        """
        cdef int double_sprites, sprite_height, n, addr, sprite_y
        cdef list sprite_line

        # scan through the sprites, starting at oam_start_addr, seeing if they are visible in the line given
        # (note that should be the next line); if so, add them to the list of active sprites, until that gets full.
        # if using 8x16 sprites (True), or 8x8 sprite (False)
        double_sprites = (self.ppu_ctrl & SPRITE_SIZE_MASK) > 0
        sprite_height = 16 if double_sprites else 8

        self._num_active_sprites = 0
        for n in range(64):
            addr = (self.oam_addr + n * 4) & 0xFF  # wrap around the address if need be
            sprite_y = self.oam[addr]
            if sprite_y <= self.line < sprite_y + sprite_height:
                if self._num_active_sprites < 8:
                    self._active_sprite_addrs[self._num_active_sprites] = addr
                    self._sprite_line[self._num_active_sprites] = self.line - sprite_y
                    self._num_active_sprites += 1
                    #sprite_line.append(line - sprite_y)
                else:
                    # overflow
                    # todo: this implements the *correct* behaviour of sprite overflow, but not the buggy behaviour
                    # (and even then it is not cycle correct, so could screw up games that rely on timing of this very exactly)
                    self.sprite_overflow = True
                    break
        self._fill_sprite_latches(double_sprites)

    cdef void _fill_sprite_latches(self, int double_sprites):
        """
        Non cycle-correct way to pre-fetch the sprite lines for the next scanline
        """
        cdef int table_base, prev_table_base, palette_ix, attribs, flip_v, flip_h, tile_ix, line, tile_base, x, c
        cdef int palette[4]
        cdef unsigned char sprite_pattern_lo, sprite_pattern_hi
        cdef int i, address

        # previously the ppu was fetching background tiles, so address line A12 was set by the bkg table base; this is
        # used for triggering irq ticks for MMC3 type cartridges.
        table_base = ((self.ppu_ctrl & BKG_PATTERN_TABLE_MASK) > 0) * 0x1000

        # the IRQ tick triggers for MMC3 are handled on the scanline renderers themselves, but they are related to
        # the rendering of sprites and associated pattern table switching, so they are calculated here
        self.irq_tick_triggers[:] = [False] * 68
        if not double_sprites:
            if table_base == 0:
                self.irq_tick_triggers[67] = True   # trigger once at pixel 324
            else:
                self.irq_tick_triggers[3] = True    # trigger once at pixel 260

        for i in range(self._num_active_sprites):
            address = self._active_sprite_addrs[i]

            attribs = self.oam[(address + 2) & 0xFF]
            palette_ix = attribs & 0b00000011

            self.decode_palette(palette, palette_ix, is_sprite=True)
            flip_v = bit_high(attribs, bit=7)
            flip_h = bit_high(attribs, bit=6)
            self._sprite_bkg_priority[i] = bit_high(attribs, bit=5)

            if not double_sprites:
                # sprite table select bit is only used in single-height (8x8) mode
                table_base = ((self.ppu_ctrl & SPRITE_PATTERN_TABLE_MASK) > 0) * 0x1000
                tile_ix = self.oam[(address + 1) & 0xFF]
                line = self._sprite_line[i] if not flip_v else 7 - self._sprite_line[i]
            else:
                line = self._sprite_line[i] if not flip_v else 15 - self._sprite_line[i]
                tile_ix = self.oam[(address + 1) & 0xFF] & 0b11111110
                # in double-height mode, sprite table is set by bottom bit of 2nd byte in OAM
                prev_table_base = table_base
                table_base = (self.oam[(address + 1) & 0xFF] & 1) * 0x1000
                if prev_table_base==0 and table_base > 0:
                    # rising edge on the table selecting address line triggers the irq_counter
                    self.irq_tick_triggers[i * 8] = True

                if line >= 8:
                    # in the lower tile
                    tile_ix += 1
                    line -= 8

            tile_base = table_base + tile_ix * PATTERN_SIZE_BYTES
            sprite_pattern_lo = self.vram.read(tile_base + line)
            sprite_pattern_hi = self.vram.read(tile_base + 8 + line)

            for x in range(8):
                c = bit_high(sprite_pattern_hi, x) * 2 + bit_high(sprite_pattern_lo, x)
                self._sprite_pattern[i][x if flip_h else 7 - x] = palette[c] if c else self.transparent_color

        if double_sprites and self._num_active_sprites < 8:
            # at this point, the PPU does some reads from table 1 that are discarded, but that means that if the table
            # base was zero, it will then go high, triggering an irq tick
            if table_base == 0:
                self.irq_tick_triggers[self._num_active_sprites * 8] = True

    cdef int _overlay_sprites(self, int bkg_pixel):
        """
        Cycle-correct (ish) sprite rendering for the pixel at y=line, pixel=pixel.  Includes sprite 0 collision detection.
        """
        cdef int sprite_c_out, c
        cdef int top_sprite, sprite_addr, sprite_x, pix, s0_visible=False

        c_out = bkg_pixel
        if (self.ppu_mask & RENDER_SPRITES_MASK) == 0 \
            or (self.pixel - 1 < 8 and bit_low(self.ppu_mask, RENDER_LEFT8_SPRITES_BIT)):
            return c_out

        sprite_c_out = self.transparent_color
        top_sprite = -1
        for i in range(self._num_active_sprites - 1, -1, -1):  # iterate from backmost to frontmost sprite #reversed(range(self._num_active_sprites)):
            # render in reverse to make overwriting easier
            sprite_addr = self._active_sprite_addrs[i]
            sprite_x = self.oam[sprite_addr + 3]
            if sprite_x <= self.pixel - 1 < sprite_x + 8:
                pix = self.pixel - 1 - sprite_x
                # this sprite is visible now
                c = self._sprite_pattern[i][pix]
                if c != self.transparent_color:
                    top_sprite = i
                    sprite_c_out = c
                    if sprite_addr == 0:
                        s0_visible = True

        # sprite zero collision detection
        # Details: https://wiki.nesdev.com/w/index.php/PPU_OAM#Sprite_zero_hits
        if not self.sprite_zero_hit and s0_visible and bkg_pixel != self.transparent_color:
            # todo: there are some more fine details here
            #print("s0 hit ", self.line, self.pixel)
            self.sprite_zero_hit = True

        # now decide whether to keep sprite or bkg pixel
        if sprite_c_out != self.transparent_color and (not self._sprite_bkg_priority[top_sprite] or bkg_pixel == self.transparent_color):
            c_out = sprite_c_out

        return c_out #if c_out != self.transparent_color else self.bkg_color  # background color


    ################ Background rendering ##############################################################################

    cdef void fill_bkg_latches(self):
        """
        Fill the ppu's rendering latches with the next tile to be rendered.  Relies on the correct values in
        the internal _effective_x and _effective_y variables.
        """
        cdef int ntbl_base, tile_addr, tile_line, tile_index, tile_bank, tile_base
        cdef int i, shift, palette_id, table_base, attr_addr
        cdef unsigned char attribute_byte, mask

        # which nametable are we currently on?
        ntbl_base = (NAMETABLE_START                                  # nametable start
                     + (((self._effective_y >> 8) & 1) << 11)         # y nametable bit
                     + (((self._effective_x >> 8) & 1) << 10)         # x nametable bit
                     )

        ##### Tile reading

        tile_addr = (ntbl_base
                     + (((self._effective_y >> 3) & 0b11111) << 5)    # coarse y   { & 0b11111 necessary because of
                     + ((self._effective_x >> 3) & 0b11111)           # coarse x   { nametable carry in effective x/y
                     )

        tile_line = self._effective_y & 0b111                         # offset within the tile

        # read the tile id from the nametable
        tile_index = self.vram.read(tile_addr)
        # now figure out where the data for that tile is located in the memory
        tile_bank = (self.ppu_ctrl & BKG_PATTERN_TABLE_MASK) > 0
        table_base = tile_bank * 0x1000
        tile_base = table_base + tile_index * PATTERN_SIZE_BYTES

        # shift up the lower bits of the background latches ready to be refilled
        self._pattern_hi <<= 8
        self._pattern_lo <<= 8
        # then read the new lower pattern byte
        self._pattern_lo = (self._pattern_lo & 0xFF00) + self.vram.read(tile_base + tile_line)
        self._pattern_hi = (self._pattern_hi & 0xFF00) + self.vram.read(tile_base + tile_line + 8)

        ##### Attribute (palette) for this block

        attr_addr = (ntbl_base
                     + ATTRIBUTE_TABLE_OFFSET                         # go to the attribute table
                     + (((self._effective_y >> 5) & 0b111) << 3)      # top 3 bits of coarse y  (== coarse y / 4)
                     + ((self._effective_x >> 5) & 0b111)             # top 3 bits of coarse x  (== coarse x / 4)
                     )

        attribute_byte = self.vram.read(attr_addr)

        shift = (((self._effective_y >> 4) & 1) * 4                   # 4th bit of effective_y gives 2-tile block
                 + ((self._effective_x >> 4) & 1) * 2)                # 4th bit of effective_x gives 2-tile block
        mask = 0b00000011 << shift
        palette_id = (attribute_byte & mask) >> shift

        for i in range(4):
            self._palette[0][i] = self._palette[1][i]
        self.decode_palette(self._palette[1], palette_id, False)

        # after a read, increment the effective x so that we can read the next tile along next time
        self._effective_x += 8

    cdef int _get_bkg_pixel(self):
        """
        Determine the current background pixel to draw based on the current internal state of the PPU
        :return:
        """
        cdef int fine_x, px, v, mask

        if (   self.ppu_mask & RENDER_BACKGROUND_MASK) == 0 \
            or (self.pixel - 1 < 8 and bit_low(self.ppu_mask, RENDER_LEFT8_BKG_BIT)):
            # in this case, background rendering is off for this pixel, so just return
            return self.transparent_color

        fine_x = self.ppu_scroll[PPU_SCROLL_X] & 0b00000111
        px = (self.pixel - 1) % 8 + fine_x
        mask = 1 << (15 - px)
        v = ((self._pattern_lo & mask) > 0) + ((self._pattern_hi & mask) > 0) * 2
        return self._palette[px >> 3][v] if v > 0 else self.transparent_color


    ################ Palette Decoder ###################################################################################

    cdef void invalidate_palette_cache(self):
        """
        Invalidates the entire palette cache; could be more efficient by only invalidating entries that have been
        rewritten.
        """
        cdef int i
        for i in range(8):
            self._palette_cache_valid[i] = False

    cdef void decode_palette(self, int* palette_out, int palette_id, bint is_sprite):
        """
        If is_sprite is true, then decodes palette from the sprite palettes, otherwise
        decodes from the background palette tables.
        """
        cdef int palette_address, i, cmask

        if self._palette_cache_valid[is_sprite * 4 + palette_id]:
            palette_out[0] = self._palette_cache[is_sprite * 4 + palette_id][0]
            palette_out[1] = self._palette_cache[is_sprite * 4 + palette_id][1]
            palette_out[2] = self._palette_cache[is_sprite * 4 + palette_id][2]
            palette_out[3] = self._palette_cache[is_sprite * 4 + palette_id][3]

        # get the palette colours (these are in hue (chroma) / value (luma) format.)
        # palette_id is in range 0..3, and gives an offset into one of the four background palettes,
        # each of which consists of three colors, each of which is represented by a singe byte
        palette_address = PALETTE_START + 16 * is_sprite + 4 * palette_id
        for i in range(4):
            palette_out[i] = (self.vram.read(palette_address + i) & 0b00111111)
            self._palette_cache[is_sprite * 4 + palette_id][i] = palette_out[i]
        self._palette_cache_valid[is_sprite * 4 + palette_id] = True


    ################ Logging ###########################################################################################

    def log_line(self):
        """
        Generate a log line from the CPU
        """
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

    ################ Debug #############################################################################################

    cpdef void debug_render_nametables(self, unsigned int[:, :] dest):
        """
        Reads the nametable and attribute table and then sends the result of that for each
        tile on the screen to render_tile to actually render the tile (reading the pattern tables, etc.)
        """
        cdef int nx, ny, nametable, addr_base, row, vblock, v_subblock_ix, col, tile_index, hblock, h_subblock_ix, shift
        cdef int mask, palette_id, tile_bank, x, y, x0, xe, y0, ye
        cdef unsigned char attribute_byte

        dest[:, :] = self.get_background_color()

        for ny in range(2):
            for nx in range(2):
                nametable = ny * 2 + nx
                addr_base = NAMETABLE_START + nametable * NAMETABLE_LENGTH_BYTES
                for row in range(SCREEN_TILE_ROWS):
                    vblock = int(row / 2)
                    v_subblock_ix = vblock % 2
                    for col in range(SCREEN_TILE_COLS):
                        tile_index = self.vram.read(addr_base + row * SCREEN_TILE_COLS + col)

                        # get attribute byte from the attribute table at the end of the nametable
                        # these tables compress the palette id into two bits for each 2x2 tile block of 16x16px.
                        # the attribute bytes each contain the palette id for a 2x2 block of these 16x16 blocks
                        # so get the correct byte and then extract the actual palette id from that
                        hblock = int(col / 2)
                        attribute_byte = self.vram.read(addr_base
                                                        + ATTRIBUTE_TABLE_OFFSET
                                                        + (int(vblock / 2) * 8 + int(hblock / 2))
                                                       )
                        h_subblock_ix = hblock % 2
                        shift = 4 * v_subblock_ix + 2 * h_subblock_ix
                        mask = 0b00000011 << shift
                        palette_id = (attribute_byte & mask) >> shift
                        # ppu_ctrl tells us whether to read the left or right pattern table, so let's fetch that
                        tile_bank = (self.ppu_ctrl & BKG_PATTERN_TABLE_MASK) > 0
                        tile = self.debug_render_tile(dest,
                                                      (nx * SCREEN_TILE_COLS + col) * TILE_WIDTH_PX,
                                                      (ny * SCREEN_TILE_ROWS + row) * TILE_HEIGHT_PX,
                                                      tile_index,
                                                      tile_bank,
                                                      -1,
                                                      #palette_id,
                                                      False,
                                                      False
                                                     )
        # draw a box around the active window
        x0 = (self.ppu_scroll[PPU_SCROLL_X] + (bit_high(self.ppu_ctrl, BIT_NAMETABLE_X) << 8)) % 512
        y0 = (self.ppu_scroll[PPU_SCROLL_Y] + (bit_high(self.ppu_ctrl, BIT_NAMETABLE_Y) * 240)) % 480

        xe = (x0 + 256) % 512
        ye = (y0 + 240) % 480

        dest[x0:min(512, x0 + 256), y0] = 255 << 8
        dest[x0:min(512, x0 + 256), ye] = 255 << 8
        if x0 + 256 > 512:
            dest[0:xe, y0] = 255 << 8
            dest[0:xe, ye] = 255 << 8

        dest[x0, y0:min(480, y0 + 240)] = 255 << 8
        dest[xe, y0:min(480, y0 + 240)] = 255 << 8
        if y0 + 240 > 480:
            dest[x0, 0:ye] = 255 << 8
            dest[xe, 0:ye] = 255 << 8


    cpdef void debug_render_tile(self, unsigned int[:, :] dest, int x0, int y0, int tile_index, int tile_bank, int palette_id, bint flip_h, bint flip_v):
        """
        Decodes a tile given by tile_index from the pattern table specified by tile_bank to an array of RGB color value,
        using the palette supplied.  Transparent pixels (value 0 in the tile) are replaced with self.transparent_color.
        This makes them ready to be blitted to the screen.
        """
        cdef int x, y, xx, yy, pixel_color_ix, plane, table_base, tile_base
        cdef int palette[4]

        if palette_id > 0:
            self.decode_palette(palette, palette_id, is_sprite=False)
        else:
            palette[0] = 0x01
            palette[1] = 0x11
            palette[2] = 0x21
            palette[3] = 0x31

        # now decode the tile
        table_base = tile_bank * 0x1000

        # tile index tells us which pattern table to read
        tile_base = table_base + tile_index * PATTERN_SIZE_BYTES

        # the (palettized) tile is stored as 2x8byte bit planes, each representing an 8x8 bitmap of depth 1 bit
        # tile here is indexed tile[row][column], *not* tile[x][y]
        #tile = [[0] * TILE_WIDTH_PX for _ in range(TILE_HEIGHT_PX)]

        for y in range(TILE_HEIGHT_PX):
            for x in range(TILE_WIDTH_PX):
                xx = x if not flip_h else TILE_WIDTH_PX - 1 - x
                yy = y if not flip_v else TILE_HEIGHT_PX - 1 - y
                pixel_color_ix = 0
                for plane in range(2):
                    pixel_color_ix += ((self.vram.read(tile_base + plane * 8 + y) & (0x1 << (7 - x))) > 0) * (plane + 1)

                if pixel_color_ix > 0:
                    dest[x0 + xx, y0 + yy] = self.hex_palette[palette[pixel_color_ix]]


