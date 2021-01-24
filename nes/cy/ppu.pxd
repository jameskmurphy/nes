from .memory cimport NESVRAM


#################################### CONSTANTS #########################################################################
DEF NUM_REGISTERS = 8
DEF OAM_SIZE_BYTES = 256

# Register indices
# (this is not just an enum, this is the offset of the register in the CPU memory map from 0x2000)
DEF PPU_CTRL = 0
DEF PPU_MASK = 1
DEF PPU_STATUS = 2
DEF OAM_ADDR = 3
DEF OAM_DATA = 4
DEF PPU_SCROLL = 5
DEF PPU_ADDR = 6
DEF PPU_DATA = 7

# masks for the bits in ppu registers
# ppu_status
DEF VBLANK_MASK =               0b10000000  # same for ppu_ctrl
DEF SPRITE0_HIT_MASK =          0b01000000
DEF SPRITE_OVERFLOW_MASK =      0b00100000

# ppu_ctrl
DEF SPRITE_SIZE_MASK =          0b00100000
DEF BKG_PATTERN_TABLE_MASK =    0b00010000
DEF SPRITE_PATTERN_TABLE_MASK = 0b00001000
DEF VRAM_INCREMENT_MASK =       0b00000100
DEF NAMETABLE_MASK =            0b00000011

# ppu_mask
DEF RENDERING_ENABLED_MASK =    0b00011000
DEF RENDER_SPRITES_MASK =       0b00010000
DEF RENDER_BACKGROUND_MASK =    0b00001000
DEF RENDER_LEFT8_SPRITES_MASK = 0b00000100
DEF RENDER_LEFT8_BKG_MASK =     0b00000010
DEF GREYSCALE_MASK =            0b00000001


# bit numbers of some important bits in registers
# ppu_status
DEF V_BLANK_BIT = 7             # same for ppu_ctrl

# ppu mask
DEF RENDER_LEFT8_BKG_BIT = 1
DEF RENDER_LEFT8_SPRITES_BIT = 2

# byte numbers in ppu scroll
DEF PPU_SCROLL_X = 0
DEF PPU_SCROLL_Y = 1

# screen and sprite/tile sizes:
DEF PIXELS_PER_LINE = 341       # number of pixels per ppu scanline; only 256 of thes are visible
DEF SCREEN_HEIGHT_PX = 240      # visible screen height (number of visible rows)
DEF SCREEN_WIDTH_PX = 256       # visible screen width (number of visible pixels per row)
DEF TILE_HEIGHT_PX = 8          # height of a tile/standard sprite in pixels
DEF TILE_WIDTH_PX  = 8          # width of tile/standard sprite in pixels
DEF SCREEN_TILE_ROWS = 30       # number of rows of background tiles in a single screen
DEF SCREEN_TILE_COLS = 32       # number of columns of tiles in a single screen
DEF PATTERN_BITS_PER_PIXEL = 2  # number of bits used to represent each pixel in the patterns

# the total size of a tile in the pattern table in bytes (== 16)
DEF PATTERN_SIZE_BYTES = TILE_WIDTH_PX * TILE_HEIGHT_PX * PATTERN_BITS_PER_PIXEL / 8

cdef class NESPPU:
    cdef unsigned char ppu_ctrl, ppu_mask, oam_addr, oam_data, _ppu_data_buffer, _io_latch
    cdef unsigned char ppu_scroll[2]
    cdef unsigned int _oam_addr_held, ppu_addr, _ppu_byte_latch

    cdef int _palette[2][4]
    cdef unsigned int _pattern_lo, _pattern_hi

    cdef unsigned char oam[OAM_SIZE_BYTES]
    cdef unsigned char _oam[32]
    cdef list _sprite_pattern          # this might be inefficient
    cdef unsigned char _sprite_bkg_priority[8]
    cdef list _active_sprites

    cdef int line, pixel, row, col

    # used in bkg latch precalc
    cdef unsigned char nx0, ny0, _nx, _ny, _tile_row, _tile_col, _row_off, _col_off, _last_row

    cdef int in_vblank, sprite_zero_hit, sprite_overflow

    cdef int cycles_since_reset, frames_since_reset, time_at_new_frame

    cdef NESVRAM vram
    cdef object screen
    cdef object interrupt_listener

    cdef int screen_buffer[256][240]

    cdef int rgb_palette[64][3]
    cdef int hex_palette[64]
    cdef int transparent_color, bkg_color

    cdef int _palette_cache[8][4]
    cdef int _palette_cache_valid[8]

    cpdef unsigned char read_register(self, int register)
    cpdef void write_register(self, int register, unsigned char value)
    cpdef int run_cycles(self, int num_cycles)
    cpdef void write_oam(self, unsigned char* data)

    cdef void precalc_offsets(self)
    cdef void inc_bkg_latches(self)


    cdef void invalidate_palette_cache(self)
    cdef void _get_non_palette_color(self, int* non_pal_col)
    cdef unsigned char ppu_status(self)
    cdef void _clear_to_bkg(self)
    cdef void _increment_vram_address(self)
    cdef void _trigger_nmi(self)
    cdef void _prefetch_active_sprites(self, int line)
    cdef void _fill_sprite_latches(self, list active_sprite_addrs, list sprite_line, int double_sprites)
    cdef int _overlay_sprites(self, int bkg_pixel)
    cdef int _run_cycles(self, int num_cycles)
    cdef void fill_bkg_latches(self, int line, int col)
    cdef int _get_bkg_pixel(self)
    cdef void _new_frame(self)
    cdef void decode_palette(self, int* palette_out, int palette_id, int is_sprite=?)
