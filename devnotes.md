Development Notes
=================

Development notes for the project listing todos, corrections and improvements that are still outstanding.

Improvements and Corrections
----------------------------

### Errors

* Duck Tales scrolls the wrong way on vertical scroll!
  * Okay, this is due to complex reasons in the handling of y-scroll in the ppu.  The y-scroll is updated
              from the scroll register writes at some point in the frame, but if instead writes to ppuaddr are used
              the update happens IMMEDIATELY on the second write, allowing y-scroll to be updated mid-frame.
              So, we need to change the implementation to deal with this properly
  * ~~We've got it better, but we now have this off-by-6 bug described here, due to the scroll not updating
              during render:  https://emudev.de/nes-emulator/unrom-mapper-duck-tales-and-scrolling-again/~~
  * Fixed the off-by-6 as described
  * Mostly good, but lumpy at the start and possibly showing a bug described here: https://www.gridbugs.org/zelda-screen-transitions-are-undefined-behaviour/
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
* PPU refactor
  * change to use updating v register during render (violates single source of truth for line, though)
* APU Tests
  * Test DMC
  * Test IRQ
* Code tidy up and comments
  * Tidy up pxd headers and constants
  * Localize class variables related to bkg latches if not needed
  * Tidy up PPU code
  * Tidy up unused code in ppu
  * initialize cython arrays
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
* check IRQ implementation works
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
