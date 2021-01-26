from .memory cimport NESVRAM

### NES PPU Constants ##################################################################################################

# this odd mechanism allows (integer) constants to be shared between pyx files via pxd files
# if these constants also need to be used from python use cpdef in place of cdef here
cdef enum:
    OAM_SIZE_BYTES = 256


### NES PPU prototype ##################################################################################################
cdef class NESPPU:
    cdef:
        unsigned char ppu_ctrl, ppu_mask, oam_addr, oam_data, _ppu_data_buffer, _io_latch
        unsigned char ppu_scroll[2]
        unsigned int _oam_addr_held, ppu_addr, _ppu_byte_latch

        int _palette[2][4]
        unsigned int _pattern_lo, _pattern_hi

        unsigned char oam[OAM_SIZE_BYTES]
        unsigned char _oam[32]
        list _sprite_pattern          # this might be inefficient
        unsigned char _sprite_bkg_priority[8]
        list _active_sprites

        # track current screen position.  Screen drawing starts at pixel 1 (not 0) and runs to pixel 256.
        int line, pixel

        # used in bkg latch precalc
        unsigned char nx0, ny0, _nx, _ny, _tile_row, _tile_col, _row_off, _col_off, _last_row

        int in_vblank, sprite_zero_hit, sprite_overflow

        int cycles_since_reset, frames_since_reset, time_at_new_frame

        NESVRAM vram
        object interrupt_listener

        unsigned int screen_buffer[256][240]

        int rgb_palette[64][3]
        int hex_palette[64]
        int transparent_color, bkg_color

        int _palette_cache[8][4]
        int _palette_cache_valid[8]

    ########### functions ##############################################

    cpdef unsigned char read_register(self, int register)
    cpdef void write_register(self, int register, unsigned char value)
    cpdef int run_cycles(self, int num_cycles)
    cpdef void write_oam(self, unsigned char* data)
    cpdef copy_screen_buffer_to(self, unsigned int[:, :] dest)

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
