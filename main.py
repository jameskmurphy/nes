import logging
from nes.system import NES
from nes import LOG_CPU, LOG_PPU

nes = NES("./roms/donkey kong.nes", log_file="./logs/nes.log", log_level=logging.INFO)
nes.run()

