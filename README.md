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

### Screenshots

Here are some screenshots of the emulator in action: Super Mario Brothers, Donkey Kong, MegaMan

<img src="/img/mario.png" height="300">
<img src="/img/donkeykong.png" height="300">
<img src="/img/megaman.png" height="300">

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