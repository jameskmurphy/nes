Development Notes
=================

Development notes for the project listing todos, corrections and improvements that are still outstanding.


Corrections
-----------

### Game and Other Errors

* APU
  * Some popping at end of pulse notes?  Especially noticeable on stage 1-2 of SMB.  Possibly also a missed note?
* MMC3
  * Gun Nac doesn't boot

### Test Failures

* Test failures:
  * BRK test failure (is this right?)
  * VBlank timing
* APU test failures


### Bad Behaviour

* A bit short (about 50) of CPU cycles per cycle.


Improvements
------------

### Emulator Improvements

* ALE sytle interface
  * Find lives, score counters, start point for a few games
* Debug features
  * (made tricky by pygame one window limit)
  * ~~nametable viewer~~
    * make the config for this nicer
  * vram viewer
  * memory viewer
* Save / load emulator state
* Record / replay keypresses



### New Features

* OpenGL shaders
  * CRT shader (nice NTSC info here: https://wiki.nesdev.com/w/index.php/NTSC_video)
  * smoothing shader
  * blur shader


### Major Todo

* Check APU IRQ handling against new IRQ system
* Mappers  (currently support ~75% of games)
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
  * automation of some test roms
     * ~~blargg instruction tests~~
     * blargg ppu tests
     * blargg apu tests
     * mmc3 tests
     * nestest
  * make all these tests pass!
  * make some tests (use cc65?) of our own


### Medium Todo

* MMC 1
  * reject sequential writes to serial port (not ram)
  * open bus behaviour when prg_ram not enabled
* Interrut handling
  * could it be better?  e.g. should the IRQ line remain always high if never reset?  Should this keep triggering
    cpu IRQs? Should we just connect the CPU to the IRQ/NMI lines directly (e.g. it reads them from the
    appropriate devices each cycle) and then let the devices/cpu take care of clearing the flags?
* Change OAM DMA handling to cycle-timed
  * this will allow more accurate handling of DMC DMA pauses and can remove some complexity from APU run_cycles
* PPU Details
  * Colours boost if ppu_mask bits set (https://wiki.nesdev.com/w/index.php/Colour_emphasis)
  * implement sprite overflow incorrect behaviour
  * sprite zero hit details
  * odd nametable fetches used by MMC5
* Open bus behaviour on memory
  * including controllers
* Check IRQ implementation works
  * is used in a few places on the NES:  https://wiki.nesdev.com/w/index.php/IRQ
* Fine timing details
  * can some of these be improved?
  * vsync length
  * frame length



### Minor Todo

* Colliding and lost interrupts
  * http://visual6502.org/wiki/index.php?title=6502_Timing_of_Interrupt_Handling
* Background palette hack
* OAMDATA read behaviour during render
* Performance
  * Palette cache (don't need to invalidate all, check hit rate)
  * Could move more of run_instr -> meta
* Unodocumented instruction failures in blargg's tests:
  * 0xAB ATX in 03-immediate
  * 0xCB AXS in 03-immediate
  * 0x9C SYA in 07-abs-xy
  * 0x9E SXA in 07-abs-xy
