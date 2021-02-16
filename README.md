# NES-PY

A Nintendo Entertainment System (NES) emulator written in Python and Cython.  Currently in development.  All
core components are implemented, although several important mappers are still to do and known bugs remain (along
with lots of unknown ones!).

With huge thanks to everyone who contributed to the amazing [NESDev Wiki](wiki.nesdev.com) and all the other fantastic
sources, tests and forums for NES emulator development and 6502 progamming.

### Screenshots

Super Mario Brothers:

![Mario](/img/mario.png)


Donkey Kong:

![DonkeyKong](/img/donkeykong.png)


MegaMan:

![MegaMan](/img/megaman.png)

### Usage

Basic usage:

    from nes.cycore.system import NES
    nes = NES([rom_filename])
    nes.run()


### Dependencies

Depends on the following libraries for key functionality:
* pygame
  * timing
  * rendering
  * input
* pyaudio
  * audio playing
  * sync to audio
* (pyopengl)
  * OpenGL rendering
  * (not essential; can use SDL rendering via pygame)


### Development Notes

Development notes, including current known errors and todo lists (i.e. unimplemented features)
are [here](devnotes.md).


### License

Distributed under the MIT License (see [here](LICENSE))