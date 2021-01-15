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

    def show(self):
        pygame.transform.scale(self.buffer, (self.width * self.scale, self.height * self.scale), self.screen)
        pygame.display.flip()

    def clear(self, color=(0, 0, 0)):
        self.buffer.fill(color)


class Gamepad:
    """
    NES Gamepad

    References:
        [1] https://wiki.nesdev.com/w/index.php/Standard_controller
    """
    # code for each button
    # this is not just an enum, this is the bit order that they are fed out of the controller
    A = 0
    B = 1
    SELECT = 2
    START = 3
    UP = 4
    DOWN = 5
    LEFT = 6
    RIGHT = 7

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

    def __init__(self, key_map=DEFAULT_KEY_MAP, active=True):
        self.key_pressed = [0] * 8   # array to store key status
        self.key_map = key_map
        self._current_bit = 0
        self.strobe = False
        self.active = active  # allows the gamepad to be turned off (acting as if it were disconnected)

    def update(self):
        """
        This gets called once every game loop and updates the internal status of the gamepad
        Read the keyboard and put the status of the keys into the key_pressed array.
        """
        print("UPDATE CONTROLLER!")
        print(self.key_pressed)
        keys = pygame.key.get_pressed()
        for k, v in self.key_map.items():
            self.key_pressed[v] = keys[k]

    def set_strobe(self, value):
        """
        Set the strobe bit to the given value
        """
        # we don't need to do much with the strobe, just reset the status bit if strobe is high so that we start
        # out at bit 0.  If strobe is low, do nothing; then we can read out the data from the ouptut port.
        print("WRITE CONTROLLER!")
        self.strobe = value
        if value == 1:
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
        v = self.key_pressed[self._current_bit] if self._current_bit < 8 else 1
        print("READ CONTROLLER! bit {} is {}".format(self._current_bit, v))
        self._current_bit = (self._current_bit + 1) % 8  # don't want this to overflow (very unlikely)
        return v
