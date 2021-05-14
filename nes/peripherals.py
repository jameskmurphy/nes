import logging

# would like to make this not depend on pygame
try:
    import pygame
    import pygame.freetype
    has_pygame = True
except ImportError:
    has_pygame = False

try:
    from OpenGL.GL import *
    has_opengl = True
except ImportError:
    has_opengl = False

class ScreenBase:
    """
    Base class for screens.  Not library specific.
    """
    WIDTH_PX = 256
    HEIGHT_PX = 240
    VISIBLE_HEIGHT_PX = 224
    VISIBLE_WIDTH_PX = 240

    def __init__(self, ppu, scale=3, vertical_overscan=False, horizontal_overscan=False):
        self.ppu = ppu
        self.width = self.WIDTH_PX if horizontal_overscan else self.VISIBLE_WIDTH_PX
        self.height = self.HEIGHT_PX if vertical_overscan else self.VISIBLE_HEIGHT_PX
        self.scale = scale
        self.vertical_overscan = vertical_overscan
        self.horizontal_overscan = horizontal_overscan

        self._text_buffer = []

    def show(self):
        raise NotImplementedError()

    def clear(self):
        raise NotImplementedError()

    def add_text(self, text, position, color, ttl=1):
        self._text_buffer.append((text, position, color, ttl))

    def update_text(self):
        self._text_buffer = [(txt, pos, col, ttl - 1) for (txt, pos, col, ttl) in self._text_buffer if ttl > 1]


class Screen(ScreenBase):
    """
    PyGame based screen.
    Keep PyGame-specific stuff in here (don't want PyGame specific stuff all over the rest of the code)
    """
    def __init__(self, ppu, scale=3, vsync=False, vertical_overscan=False, horizontal_overscan=False, nametable_panel=False, py_compatibility_mode=False):
        super().__init__(ppu, scale, vertical_overscan, horizontal_overscan)

        self.nametable_panel = nametable_panel
        self.py_compatibility_mode = py_compatibility_mode

        if nametable_panel:
            # if including the nametable panel, make a buffer for it
            self.nt_buffer_surf = pygame.Surface((32 * 8 * 2, 30 * 8 * 2))

        # screens and buffers
        self.buffer_surf = pygame.Surface((self.width, self.height))

        # todo: this introduces a dependency on NumPy, so we might want to refactor to remove that
        self.buffer_sa = pygame.surfarray.pixels2d(self.buffer_surf)

        if nametable_panel:
            # if including the nametable panel, make the window large enough to show it
            scr_width = self.width * self.scale + 32 * 8 * 2
            scr_height = max(self.height * self.scale, 30 * 8 * 2)
        else:
            scr_width = self.width * self.scale
            scr_height = self.height * self.scale

        self.screen = pygame.display.set_mode((scr_width, scr_height), vsync=vsync)

        # font for writing to HUD
        pygame.freetype.init()
        self.font = pygame.freetype.SysFont(pygame.font.get_default_font(), 12 * self.scale)

    def write_at(self, x, y, color):
        # only used in py_compatibility_mode
        self.buffer_surf.set_at((x, y), color)

    def add_text(self, text, position, color, ttl=1):
        self._text_buffer.append((text, (position[0], position[1]), color, ttl))

    def _render_text(self, surf):
        for (text, position, color, _) in self._text_buffer:
            self.font.render_to(surf, (position[0] * self.scale, position[1] * self.scale), text, color)

    def show(self):
        if not self.py_compatibility_mode:
            # the old version of the ppu wrote directly to the screen via write_at
            self.ppu.copy_screen_buffer_to(self.buffer_sa, self.vertical_overscan, self.horizontal_overscan)
        if self.nametable_panel:
            self.ppu.debug_render_nametables(pygame.surfarray.pixels2d(self.nt_buffer_surf))
            scaled = pygame.transform.scale(self.buffer_surf, (self.width * self.scale, self.height * self.scale))
            self.screen.blit(scaled, (0,0))
            self.screen.blit(self.nt_buffer_surf, (self.width * self.scale, 0))
        else:
            pygame.transform.scale(self.buffer_surf, (self.width * self.scale, self.height * self.scale), self.screen)
        self._render_text(self.screen)
        pygame.display.flip()
        self.update_text()

    def clear(self, color=(0, 0, 0)):
        self.buffer_surf.fill(color)


class ScreenGL(ScreenBase):
    """
    PyGame / OpenGL based screen.
    Keep *all* OpenGL-specific stuff in here
    Keep PyGame-specific stuff in here (don't want PyGame specific stuff all over the rest of the code)
    """

    def __init__(self, ppu, scale=3, vsync=False, vertical_overscan=False, horizontal_overscan=False):
        super().__init__(ppu, scale, vertical_overscan, horizontal_overscan)

        # screens and buffers
        self.buffer_surf = pygame.Surface((self.width, self.height))
        self.buffer_sa = pygame.surfarray.pixels2d(self.buffer_surf)
        self.screen = pygame.display.set_mode((self.width * scale, self.height * scale),
                                              flags = pygame.DOUBLEBUF | pygame.OPENGL,
                                              vsync=vsync
                                              )

        self.arr = bytearray([0] * (self.width * self.height * 3))
        self.gltex = None   # the texture that we will use for the screen
        self.opengl_init()

        # font for writing to HUD
        pygame.freetype.init()
        self.font = pygame.freetype.SysFont(pygame.font.get_default_font(), 12)
        self._text_buffer = []

    def opengl_init(self):
        """
        Set up the OpenGL boilerplate to get going
        """
        self.gltex = glGenTextures(1)
        glViewport(0, 0, self.width * self.scale, self.height * self.scale)
        glDepthRange(0, 1)
        glMatrixMode(GL_PROJECTION)
        glMatrixMode(GL_MODELVIEW)
        glLoadIdentity()
        glShadeModel(GL_SMOOTH)
        glClearColor(0.0, 0.0, 0.0, 0.0)
        glClearDepth(1.0)
        glDisable(GL_DEPTH_TEST)
        glDisable(GL_LIGHTING)
        glDepthFunc(GL_LEQUAL)
        glHint(GL_PERSPECTIVE_CORRECTION_HINT, GL_NICEST)
        glEnable(GL_BLEND)

    def show_gl(self):
        """
        Show the screen by copying the buffer to an OpenGL texture and displaying a rectangle with that texture
        :return:
        """
        # prepare to render the texture-mapped rectangle
        glClear(GL_COLOR_BUFFER_BIT)
        glLoadIdentity()
        glDisable(GL_LIGHTING)
        glEnable(GL_TEXTURE_2D)

        # draw texture openGL Texture
        self.surface_to_texture(self.buffer_surf)
        glBindTexture(GL_TEXTURE_2D, self.gltex)
        glBegin(GL_QUADS)
        glTexCoord2f(0, 0); glVertex2f(-1, 1)
        glTexCoord2f(0, 1); glVertex2f(-1, -1)
        glTexCoord2f(1, 1); glVertex2f(1, -1)
        glTexCoord2f(1, 0); glVertex2f(1, 1)
        glEnd()

    def surface_to_texture(self, pygame_surface):
        """
        Copy a PyGame surface to an OpenGL texture.  This came from a StackOverflow answer that I sadly can't find now.
        There is probably a faster way to do this, but this works for now
        """
        rgb_surface = pygame.image.tostring(pygame_surface, 'RGB')
        glBindTexture(GL_TEXTURE_2D, self.gltex)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP)
        surface_rect = pygame_surface.get_rect()
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, surface_rect.width, surface_rect.height, 0, GL_RGB, GL_UNSIGNED_BYTE,
                     rgb_surface)
        glGenerateMipmap(GL_TEXTURE_2D)
        glBindTexture(GL_TEXTURE_2D, 0)

    def _render_text(self, surf):
        for (text, position, color, _) in self._text_buffer:
            self.font.render_to(surf, position, text, color)

    def show(self):
        self.ppu.copy_screen_buffer_to(self.buffer_sa)
        self._render_text(self.buffer_surf)
        self.show_gl()
        pygame.display.flip()
        self.update_text()

    def clear(self, color=(0, 0, 0)):
        self.buffer_surf.fill(color)


class ControllerBase:
    """
    NES Controller (no Pygame code in here)

    References:
        [1] https://wiki.nesdev.com/w/index.php/Standard_controller
    """
    # code for each button
    # this is not just an enum, this is the bit position that they are fed out of the controller
    A = 0
    B = 1
    SELECT = 2
    START = 3
    UP = 4
    DOWN = 5
    LEFT = 6
    RIGHT = 7

    NUM_BUTTONS = 8
    NAMES = ['A', 'B', 'select', 'start', 'up', 'down', 'left', 'right']

    def __init__(self, active=True):
        self.is_pressed = [0] * 8   # array to store key status
        self._current_bit = 0
        self.strobe = False
        self.active = active  # allows the gamepad to be turned off (acting as if it were disconnected)

    def update(self):
        pass

    def set_state(self, state):
        """
        Sets the controller state from a length-8 array of boolean values.  Set this way to support any type of array as
        input state.
        """
        self.is_pressed[self.A] = state[self.A]
        self.is_pressed[self.B] = state[self.B]
        self.is_pressed[self.SELECT] = state[self.SELECT]
        self.is_pressed[self.START] = state[self.START]
        self.is_pressed[self.UP] = state[self.UP]
        self.is_pressed[self.DOWN] = state[self.DOWN]
        self.is_pressed[self.LEFT] = state[self.LEFT]
        self.is_pressed[self.RIGHT] = state[self.RIGHT]

    def set_strobe(self, value):
        """
        Set the strobe bit to the given value
        """
        # we don't need to do much with the strobe, just reset the status bit if strobe is high so that we start
        # out at bit 0.  If strobe is low, do nothing; then we can read out the data from the ouptut port.
        self.strobe = value
        if value:
            self._current_bit = 0

    def read_bit(self):
        """
        Read a bit from the gamepad.  Buttons are read through a series of serial reads.
        "The first 8 reads will indicate which buttons or directions are pressed (1 if pressed, 0 if not pressed).
        All subsequent reads will return 1 on official Nintendo brand controllers but may return 0 on third party
        controllers" [1]
        :return:
        """
        if not self.active:
            return 0

        # todo: it seems like the following behviour should be correct, but it doesn't work, whereas removing this does
        #if self.strobe:
        #    self._current_bit = 0

        v = self.is_pressed[self._current_bit] if self._current_bit < self.NUM_BUTTONS else 1
        #logging.log(logging.DEBUG, "Controller bit {} is {}".format(self._current_bit, v), extra={"source": "cntrlr"})
        self._current_bit = min((self._current_bit + 1), self.NUM_BUTTONS) # don't want this to overflow (very unlikely)
        return v


class KeyboardController(ControllerBase):
    """
    PyGame keyboard-based controller
    Keep PyGame specific stuff in here
    """
    def __init__(self, active=True, key_map=None):
        super().__init__(active=active)
        self.key_map = key_map if key_map is not None else self._default_key_map()

    def _default_key_map(self):
        """
        Make a default key map; done this way to avoid using pygame in a class-level constant, which causes an error
        if pygame is not available.
        """
        return {
            pygame.K_w: ControllerBase.UP,
            pygame.K_a: ControllerBase.LEFT,
            pygame.K_s: ControllerBase.DOWN,
            pygame.K_d: ControllerBase.RIGHT,
            pygame.K_g: ControllerBase.SELECT,
            pygame.K_h: ControllerBase.START,
            pygame.K_l: ControllerBase.B,
            pygame.K_p: ControllerBase.A,
        }

    def update(self):
        """
        This should get called once every game loop and updates the internal status of the gamepad
        Read the keyboard and put the status of the keys into the key_pressed array.
        """
        keys = pygame.key.get_pressed()
        for k, v in self.key_map.items():
            self.is_pressed[v] = keys[k]
