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

