# Pyntendo

    pip install pyntendo

A Nintendo Entertainment System (NES) emulator written in Python and Cython.
* All core components are implemented, including audio, and the most important mappers.
* Performant (runs at 60fps on modern machines)
* Fully headless operation is supported
  * NumPy-based input/output
  * Very limited external dependencies (really just NumPy)
  * See [Headless Demo](Headless%20Demo.ipynb) for a minimal example
* Pure Python/Cython, fully compatible with CPython (>3.6)

Although most games I have tested seem to run without issues, there are still some open issues that would improve
performance and accuracy and probably make some hard to emulate games work or work better.
* Several popular(ish) mappers are not implemented (along with lots of less popular ones)
* Some fine timing is not quite right, which might cause issues in some sensitive games
* This is not a cycle-accurate emulator, so sub-instruction level timing is not correctly emulated, and some parts of
  other systems are not emulated in a cycle-correct way
* See my [devnotes](devnotes.md) for known issues and planned work

I would like to give huge thanks and kudos to everyone who contributed to the amazing [NESDev Wiki](wiki.nesdev.com)
and all the other fantastic sources (most listed in the code), tests and forums for NES emulator development and 6502
progamming.  Without these resources it would have been impossible to develop this emulator.

### Usage

Basic usage:

    from nes import NES
    nes = NES("my_rom.nes")
    nes.run()

Full set of options:

    from nes import NES, SYNC_AUDIO, SYNC_NONE, SYNC_PYGAME, SYNC_VSYNC

    nes = NES(rom_file,                  # the rom file to load
              screen_scale=3,            # factor by which to scale the screen (NES screen is 256x240 pixels with overscan)
              log_file=None,             # file to log to (logging is largely turned off by default and is exceptionally slow for high-volume parts of the system)
              log_level=None,            # level of logging (logging is largely turned off by default)
              opengl=False,              # use opengl for screen rendering
              sync_mode=SYNC_AUDIO,      # audio / video sync mode  (one of SYNC_AUDIO, SYNC_NONE, SYNC_PYGAME, SYNC_VSYNC; see below)
              verbose=True,              # whether to print out cartridge info at startup
              show_nametables=False,     # shows the nametables alongside the main screen (for debug, not compatible with opengl=True)
              vertical_overscan=False,   # show the top and bottom 8 pixels (not usually visible on CRT TVs)
              horizontal_overscan=False, # show the left and right 8 pixels (often not visible on CRT TVs)
              palette_file=None,         # supply a palette file to use; None gives default
              headless=False,            # runs the nes in headless mode without the pygame screen being started
              )

Sync mode controls how the framerate is controlled and synced to screen/audio.  The available modes are as follows:

    SYNC_NONE = 0  # no sync: runs very fast, unplayable, music is choppy
    SYNC_AUDIO = 1  # sync to audio: rate is perfect, can glitch sometimes, screen tearing can be bad
    SYNC_PYGAME = 2  # sync to pygame's clock, adaptive audio: generally reliable, some screen tearing
    SYNC_VSYNC = 3  # sync to external vsync, adaptive audio: requires ~60Hz vsync, no tearing


Pure python version:

(This is purely for interest and comparison to the Cython version.  It is very slow, has no APU, is not up to date, has some (more) bugs than the cython version and has not been developed for a while.):

    from nes.pycore.system import NES as pyNES
    pynes = pyNES("my_rom.nes")
    pynes.run()



### Screenshots

Here are some screenshots of the emulator in action: Super Mario Brothers, Donkey Kong, MegaMan

<img src="/img/mario.png" height="300">
<img src="/img/donkeykong.png" height="300">
<img src="/img/megaman.png" height="300">

### Controls

Default keymap is:

    Up, Left, Down, Right: W, A, S, D
    Select, Start:  G, H
    A, B: P, L

OSD/Volume controls:

    Turn off OSD:  1
    Start CPU logging (very slow): 2
    Volume Down/Up: -, =
    Mute: 0



### Dependencies

Depends on the following libraries for key functionality:
* numpy (optional?)
  * headless operation
  * (possibly also required by pygame surfarray, used in rendering)
* pygame (optional)
  * timing
  * rendering
  * input
  * (without pygame, only headless operation is possible)
* pyaudio (optional)
  * audio playing
  * sync to audio
* pyopengl (optional)
  * OpenGL rendering
  * (not essential; can use SDL rendering via pygame)

### License

Distributed under the MIT License (see [here](LICENSE))