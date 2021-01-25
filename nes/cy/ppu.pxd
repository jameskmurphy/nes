from .memory cimport NESVRAM

### NES PPU Constants ##################################################################################################

# this odd mechanism allows (integer) constants to be shared between pyx files via pxd files, which is a bit neater
# if these constants also need to be used from python use cpdef in place of cdef here
cdef enum:
    OAM_SIZE_BYTES = 256


### NES PPU prototype ##################################################################################################
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

    ########### functions ##############################################

    cpdef unsigned char read_register(self, int register)
    cpdef void write_register(self, int register, unsigned char value)
    cpdef int run_cycles(self, int num_cycles)
    cpdef void write_oam(self, unsigned char* data)

    cdef void precalc_offsets(self)
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
