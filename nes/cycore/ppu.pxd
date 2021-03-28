from .memory cimport NESVRAM
from .system cimport InterruptListener

### NES PPU Constants ##################################################################################################

# this odd mechanism allows (integer) constants to be shared between pyx files via pxd files
# if these constants also need to be used from python use cpdef in place of cdef here
cdef enum:
    NUM_PPU_REGISTERS = 8

    # Register indices (this is not just an enum, this is the offset of the register in the CPU memory map from 0x2000)
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
    SPRITE0_HIT_MASK =          0b01000000  #
    SPRITE_OVERFLOW_MASK =      0b00100000  #

    # ppu_ctrl
    SPRITE_SIZE_MASK =          0b00100000  #
    BKG_PATTERN_TABLE_MASK =    0b00010000  #
    SPRITE_PATTERN_TABLE_MASK = 0b00001000  #
    VRAM_INCREMENT_MASK =       0b00000100  #
    #NAMETABLE_MASK =            0b00000011

    BIT_NAMETABLE_X = 0
    BIT_NAMETABLE_Y = 1

    # ppu_mask
    RENDERING_ENABLED_MASK =    0b00011000
    RENDER_SPRITES_MASK =       0b00010000
    RENDER_BACKGROUND_MASK =    0b00001000
    #GREYSCALE_MASK =            0b00000001

     # bit numbers of some important bits in registers
    # ppu_status
    V_BLANK_BIT = 7             # same for ppu_ctrl

    # ppu mask
    RENDER_LEFT8_BKG_BIT     = 1
    RENDER_LEFT8_SPRITES_BIT = 2

    # byte indices in ppu scroll
    PPU_SCROLL_X = 0
    PPU_SCROLL_Y = 1

    # size of the OAM memory
    OAM_SIZE_BYTES = 256

    # screen and sprite/tile sizes:
    PIXELS_PER_LINE = 341       # number of pixels per ppu scanline; only 256 of thes are visible
    SCREEN_WIDTH_PX = 256       # visible screen width (number of visible pixels per row)
    SCREEN_HEIGHT_PX = 240      # visible screen height (number of visible rows)
    VERTICAL_OVERSCAN_PX = 8    # The NES assumes that the top and bottom 8 rows will not be visible due to CRT overscan
    HORIZONTAL_OVERSCAN_PX = 8  # Some games look better with horizontal overscan s
                                # see https://wiki.nesdev.com/w/index.php/Overscan
    PRERENDER_LINE = 261        # prerender scanline

    SCREEN_TILE_ROWS = 30
    SCREEN_TILE_COLS = 32
    TILE_HEIGHT_PX = 8
    TILE_WIDTH_PX = 8

    # size of a tile in the pattern table in bytes (width_px(8) x height_px(8) x bits_per_px(2) / bits_per_byte(8) == 16)
    PATTERN_SIZE_BYTES = 16


### NES PPU prototype ##################################################################################################
cdef class NESPPU:
    cdef:
        # ppu registers
        unsigned char ppu_ctrl, ppu_mask, oam_addr, oam_data, _ppu_data_buffer, _io_latch
        unsigned char ppu_scroll[2]
        unsigned int ppu_addr, _ppu_byte_latch

        # ppu current position
        int line, pixel  # screen drawing starts at pixel 1 (not 0) and runs to pixel 256.

        # status flags
        bint in_vblank, sprite_zero_hit, sprite_overflow, ignore_ppu_ctrl

        # internal tracking counters
        int frames_since_reset, time_at_new_frame
        long long cycles_since_reset

        # Sprite rendering
        unsigned char oam[OAM_SIZE_BYTES]      # main internal OAM memory
        unsigned char _oam[32]                 # a secondary internal OAM array to store sprites active on next scanline
        int _active_sprite_addrs[8]            # addresses of the active sprites
        unsigned char _sprite_bkg_priority[8]  # a buffer to hold whether a given sprite has priority over background
        int _sprite_line[8]                    # lines of the active sprite that we are on
        char _sprite_pattern[8][8]             # decoded patterns for the active sprites
        int _num_active_sprites                # how many sprites are active in this current line
        bint irq_tick_triggers[68]             # whether or not an irq tick is triggered on this pixel of sprite fetch

        # Background rendering
        unsigned int _pattern_lo, _pattern_hi   # 16-bit bkg pattern registers (only bottom 16 bits relevant)
        int _effective_x, _effective_y          # current background tile position being fetched
        int _palette[2][4]                      # palettes for next tiles

        # access to other bits of the system - vram and interrupts
        NESVRAM vram
        InterruptListener interrupt_listener

        # the screen buffer itself; currently uses a packed 32 bit int with pixel format xRGB
        unsigned int screen_buffer[256][240]

        # palettes for all the colors the NES can display
        #unsigned int rgb_palette[64][3]    # in standard RGB format
        unsigned int hex_palette[64]       # in packed 32 bit xRGB format

        # special colors that are in use
        int transparent_color, bkg_color

        # caches for palettes, since decoding them is a bit slow
        int _palette_cache[8][4]
        int _palette_cache_valid[8]

    ########### functions ##############################################

    # write OAM data (called from OAM DMA)
    cdef void write_oam(self, unsigned char* data)

    # screen buffer copy and clear
    cdef int get_background_color(self)
    cpdef void copy_screen_buffer_to(self, unsigned int[:, :] dest, bint v_overscan=?, bint h_overscan=?)
    cdef void _clear_to_bkg(self)

    # registers read/write
    cdef unsigned char read_register(self, int register)
    cdef void write_register(self, int register, unsigned char value)
    cdef unsigned char ppu_status(self)

    # running ppu cycles
    cdef int run_cycles(self, int num_cycles)
    cdef void prerender_scanline(self)
    cdef void render_visible_scanline(self)
    cdef void increment_pixel(self)
    cdef void _increment_vram_address(self)
    cdef void _trigger_nmi(self)
    cdef void _reset_effective_y(self)

    # sprite rendering
    cdef void _prefetch_active_sprites(self)
    cdef void _fill_sprite_latches(self, int double_sprites)
    cdef int _overlay_sprites(self, int bkg_pixel)

    # background rendering
    cdef void fill_bkg_latches(self)
    cdef int _get_bkg_pixel(self)

    # palette decoding and caching
    cdef void decode_palette(self, int* palette_out, int palette_id, bint is_sprite)
    cdef void invalidate_palette_cache(self)

    # debug
    cpdef void debug_render_nametables(self, unsigned int[:, :] dest)
    cpdef void debug_render_tile(self, unsigned int[:, :] dest, int x0, int y0, int tile_index, int tile_bank, int palette_id, bint flip_h, bint flip_v)


