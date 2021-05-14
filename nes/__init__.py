SYNC_NONE = 0  # no sync: runs very fast, unplayable, music is choppy
SYNC_AUDIO = 1  # sync to audio: rate is perfect, can glitch sometimes, screen tearing can be bad
SYNC_PYGAME = 2  # sync to pygame's clock, adaptive audio: generally reliable, some screen tearing
SYNC_VSYNC = 3  # sync to external vsync, adaptive audio: requires ~60Hz vsync, no tearing

from nes.cycore.system import NES   # make the key NES object available at the top level


