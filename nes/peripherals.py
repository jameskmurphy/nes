import logging

import pygame
import pygame.freetype


class Screen:
    """
    PyGame based screen.
    Keep all PyGame-specific stuff in here (don't want PyGame specific stuff all over the rest of the code)
    """

    def __init__(self, ppu, width=256, height=240, scale=3):
        self.ppu = ppu
        self.width = width
        self.height = height
        self.scale = scale

        # screens and buffers
        self.buffer_surf = pygame.Surface((self.width, self.height))
        self.buffer_sa = pygame.surfarray.pixels2d(self.buffer_surf)
        self.screen = pygame.display.set_mode((self.width * self.scale, self.height * self.scale))

        # font for writing to HUD
        pygame.freetype.init()
        self.font = pygame.freetype.SysFont(pygame.font.get_default_font(), 24)
        self._text_buffer = []

    def add_text(self, text, position, color):
        self._text_buffer.append((text, position, color))

    def _render_text(self, surf):
        for (text, position, color) in self._text_buffer:
            self.font.render_to(surf, position, text, color)

    def show(self):
        self.ppu.copy_screen_buffer_to(self.buffer_sa)
        #pygame.transform.scale(self.buffer.surface, (self.width * self.scale, self.height * self.scale), self.screen)
        pygame.transform.scale(self.buffer_surf, (self.width * self.scale, self.height * self.scale), self.screen)
        self._render_text(self.screen)
        pygame.display.flip()
        self._text_buffer = []

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

    NAMES = ['A', 'B', 'select', 'start', 'up', 'down', 'left', 'right']

    NUM_BUTTONS = 8

    def __init__(self, active=True):
        self.is_pressed = [0] * 8   # array to store key status
        self._current_bit = 0
        self.strobe = False
        self.active = active  # allows the gamepad to be turned off (acting as if it were disconnected)

    def update(self):
        pass

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

        #if self.strobe:
        #    self._current_bit = 0
        v = self.is_pressed[self._current_bit] if self._current_bit < self.NUM_BUTTONS else 1
        #logging.log(logging.DEBUG, "Controller bit {} is {}".format(self._current_bit, v), extra={"source": "cntrlr"})
        #print("Controller read bit ({:6s}) {} is {}".format(self.NAMES[self._current_bit], self._current_bit, v))
        self._current_bit += 1 #min((self._current_bit + 1), self.NUM_BUTTONS) # don't want this to overflow (very unlikely)
        return v


class KeyboardController(ControllerBase):
    """
    PyGame keyboard-based controller
    """
    DEFAULT_KEY_MAP = {
        pygame.K_w: ControllerBase.UP,
        pygame.K_a: ControllerBase.LEFT,
        pygame.K_s: ControllerBase.DOWN,
        pygame.K_d: ControllerBase.RIGHT,
        pygame.K_g: ControllerBase.SELECT,
        pygame.K_h: ControllerBase.START,
        pygame.K_l: ControllerBase.B,
        pygame.K_p: ControllerBase.A,
    }

    def __init__(self, active=True, key_map=DEFAULT_KEY_MAP):
        super().__init__(active=active)
        self.key_map = key_map

    def update(self):
        """
        This should get called once every game loop and updates the internal status of the gamepad
        Read the keyboard and put the status of the keys into the key_pressed array.
        """
        keys = pygame.key.get_pressed()
        for k, v in self.key_map.items():
            self.is_pressed[v] = keys[k]
