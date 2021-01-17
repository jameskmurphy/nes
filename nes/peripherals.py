import logging

import pygame


class Screen:
    """
    PyGame based screen.
    Keep all PyGame-specific stuff in here (don't want PyGame specific stuff all over the rest of the code)
    """

    def __init__(self, width=256, height=240, scale=3):
        self.width = width
        self.height = height
        self.scale = scale
        self.buffer = pygame.Surface((self.width, self.height))
        self.screen = pygame.display.set_mode((self.width * self.scale, self.height * self.scale))
        self.transparent_color = None

    def render_tile(self, x, y, tile):
        # todo:  this works, but could be prohibitively slow?
        tile_height = len(tile)
        sfc = pygame.Surface((8, tile_height))
        sfc.set_colorkey(self.transparent_color)
        source = pygame.PixelArray(sfc)
        for yy in range(tile_height):
            # todo: there should be a better way to do this without a loop
            source[0:8, yy] = tile[yy]
        del source
        self.buffer.blit(sfc, dest=(x, y))

    def write_at(self, x, y, color):
        self.buffer.set_at((x, y), color)

    def show(self):
        pygame.transform.scale(self.buffer, (self.width * self.scale, self.height * self.scale), self.screen)
        pygame.display.flip()

    def clear(self, color=(0, 0, 0)):
        self.buffer.fill(color)


class ControllerBase:
    """
    NES Controller (no Pygame code in here)

    References:
        [1] https://wiki.nesdev.com/w/index.php/Standard_controller
    """
    # code for each button
    # this is not just an enum, this is the bit position that they are fed out of the controller
    A = 7
    B = 6
    SELECT = 5
    START = 4
    UP = 3
    DOWN = 2
    LEFT = 1
    RIGHT = 0

    NUM_BUTTONS = 8

    DEFAULT_KEY_MAP = {
        pygame.K_w: UP,
        pygame.K_a: LEFT,
        pygame.K_s: DOWN,
        pygame.K_d: RIGHT,
        pygame.K_g: SELECT,
        pygame.K_h: START,
        pygame.K_l: B,
        pygame.K_p: A,
    }

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

        if self.strobe:
            self._current_bit = 0
        v = self.is_pressed[self._current_bit] if self._current_bit < self.NUM_BUTTONS else 1
        #logging.log(logging.DEBUG, "Controller bit {} is {}".format(self._current_bit, v), extra={"source": "cntrlr"})
        self._current_bit = min((self._current_bit + 1), self.NUM_BUTTONS) # don't want this to overflow (very unlikely)
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
