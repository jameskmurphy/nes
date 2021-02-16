Development Notes
=================

Development notes for the project listing todos, corrections and improvements that are still outstanding.


Corrections
-----------

### Game and Other Errors

* APUPulse division by zero in generate_sample sometimes
  * is fixed, but is it due to problem in sweep units?  Ghengis Khan reliably caused this.

### Test Failures

* Test failures:
  * BRK test failure (is this right?)
  * VBlank timing


### Bad Behaviour

* A bit short (about 50) of CPU cycles per cycle.  Why?


Improvements
------------

### Emulator Improvements

* Save / load emulator state
* Record / replay keypresses
* run frame by frame
  * take input keypresses
  * output frame bitmap, audio
* Config via options file
  * pass this to NES on instantiation, also have a default one that is used otherwise
  * config options
    * sync mode
    * input devices and keymaps
    * resolution and scale
    * fullscreen
* GUI for startup?
* ALE sytle interface
  * Find lives, score counters for a few major games
  * fully headless operation
  * eliminate pygame, pyaudio dependency when headless
* pip installable
* Debug features
  * nametable viewer
  * vram viewer
  * memory viewer
  * (made tricky by pygame one window limit)


### New Features

* OpenGL shaders
  * CRT shader
  * smoothing shader

### Major Todo

* Mappers  (currently support ~50% of games)
  * MMC 3  (+ 25% ish of games)
  * Mappers 3, 7 and 11 (all quite simple with quite a few games ~10% ish between them)
  * Mapper 206 if easy from MMC3  (~2%)
* Still some sync problems sometimes
  * OpenGL adaptive audio sync is sometimes problematic
  * Syncing in all modes seems to be problematic with external monitor plugged in (MBP / 1x4k external on Thunderbolt )
* APU Tests
  * Test DMC
  * Test IRQ
* Code tidy up and comments
  * initialize cython arrays - can just do with lists
  * ppu comments could be better
  * some hard coded values could be replaced with named constants (ppu, apu)
* Test coverage
  * try more test ROMS
  * make some tests (use cc65?) of our own
  * automation of testing


### Medium Todo

* MMC 1
  * reject sequential writes to serial port (not ram)
  * open bus behaviour when prg_ram not enabled
* Interrut handling
  * could it be better?  e.g. should the IRQ line remain always high if never reset?  Should this keep triggering
    cpu IRQs? Should we just connect the CPU to the IRQ/NMI lines directly (e.g. it reads them from the
    appropriate devices each cycle) and then let the devices/cpu take care of clearing the flags?
* Change OAM DMA handling to cycle-timed
  * this will allow more accurate handling of DMC DMA pauses and can remove some complexity from APU run
    cycles
* Screen
  * nicer OSD
  * more efficient copy to texture for OGL mode?
* Fine timing details
  * can some of these be improved?
  * vsync length
  * frame length
* PPU Details
  * Greyscale mode
  * Colours boost if ppu_mask bits set
  * implement sprite overflow incorrect behaviour
  * sprite zero hit details
  * odd nametable fetches used by MMC5
* Open bus behaviour on memory
  * including controllers
* Check IRQ implementation works
  * is used in a few places on the NES:  https://wiki.nesdev.com/w/index.php/IRQ

### Minor Todo

* Colliding and lost interrupts
  * http://visual6502.org/wiki/index.php?title=6502_Timing_of_Interrupt_Handling
* Background palette hack
* OAMDATA read behaviour during render
* Performance
  * Background latches
  * Palette cache (don't need to invalidate all, check hit rate)
  * Could move more of run_instr -> meta
