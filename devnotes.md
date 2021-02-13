Development Notes
=================

Development notes for the project listing todos, corrections and improvements that are still outstanding.

Improvements and Corrections
----------------------------

### Errors

* Duck Tales has some sort of problem that causes status bar to disappear when character gets on it
  * This actually might be correct behaviour - verify
  * There is a slight timing problem leading to status bar ending in the mid-cycle
  * When the main character gets to the bottom line of the status bar, sprite zero doesn't draw and the
              status bar split seems to move up one line
* Test failures:
  * BRK test failure (is this right?)
  * VBlank timing
* A bit short (about 50) of CPU cycles per cycle.  Why?



### Emulator Improvements

* Save / load emulator state
* Record / replay keypresses
* run frame by frame
  * take input keypresses
  * output frame bitmap, audio
* options file
* GUI for startup?


### New Features

* OpenGL shaders
  * CRT shader
  * smoothing shader
* Mappers
  * MMC 1
  * MMC 3


### Major Todo

* Still some sync problems sometimes
  * OpenGL adaptive audio sync is sometimes problematic
  * Syncing in all modes seems to be problematic with external monitor plugged in (MBP / 1x4k external on Thunderbolt )
* APU Tests
  * Test DMC
  * Test IRQ
* Code tidy up and comments
  * initialize cython arrays
  * ppu comments could be better
  * some hard coded values could be replaced with named constants (ppu, apu)
* Test coverage
  * try more test ROMS
  * make some tests (use cc65?) of our own
  * automation of testing


### Medium Todo

* Interrut handling
  * could it be better?  e.g. should the IRQ line remain always high if never reset?  Should this keep triggering
    cpu IRQs? Should we just connect the CPU to the IRQ/NMI lines directly (e.g. it reads them from the
    appropriate devices each cycle) and then let the devices/cpu take care of clearing the flags?
* Change OAM DMA handling to cycle-timed
  * this will allow more accurate handling of DMC DMA pauses and can remove some complexity from APU run
    cycles
* Screen
  * nicer OSD
  * more efficient copy to texture?
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
