import pygame
from nes.system import NES


pygame.init()

nes = NES("./roms/donkey kong.nes")

for i in range(100000):
    nes.step()


