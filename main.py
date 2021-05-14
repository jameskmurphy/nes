import logging
from nes import NES, SYNC_AUDIO, SYNC_NONE, SYNC_PYGAME, SYNC_VSYNC
from nes.pycore.system import NES as pyNES
from tests.blargg_tests import run_tests

#run_tests()

nes = None

# Mapper 0
nes = NES("./roms/Super Mario Bros. (Japan, USA).nes", sync_mode=SYNC_AUDIO, opengl=True)
#nes = NES("./roms/Balloon_fight.nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/donkey kong.nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Ice Climber.nes", log_file="./logs/nes.log", log_level=logging.INFO)

# Mapper 2
#nes = NES("./roms/Mega Man (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO, sync_mode=SYNC_VSYNC, opengl=True)
#nes = NES("./roms/DuckTales (USA).nes")#, log_file="./logs/nes.log", log_level=logging.INFO)

# Mapper 1
#nes = NES("./roms/Silk Worm (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Metroid (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Legend of Zelda, The (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Dragon Warrior 3 (U).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Castlevania II - Simon's Quest (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Ikari III - The Rescue (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Genghis Khan (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)

# Mapper 4 (MMC3)
#nes = NES("./roms/Super Mario Bros. 3 (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO, show_nametables=False, palette_file="./palettes/Wavebeam.pal")
#nes = NES("./roms/Double Dragon III - The Sacred Stones (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Bubble Bobble Part 2 (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Gauntlet (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Mega Man 3 (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Jurassic Park (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)

#nes = NES("./roms/Gun Nac (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO, show_nametables=True)
#nes = NES("./roms/Gun Nac (U).nes", log_file="./logs/nes.log", log_level=logging.INFO, show_nametables=True)
#nes = NES("./roms/Bucky O'Hare (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Teenage Mutant Ninja Turtles III - The Manhattan Project (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Tiny Toon Adventures (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Battletoads (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)


# Test ROMS

#nes = NES("./testroms/nes-test-roms-master/mmc3_test/1-clocking.nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./testroms/nes-test-roms-master/mmc3_test/2-details.nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./testroms/nes-test-roms-master/mmc3_test/3-A12_clocking.nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./testroms/nes-test-roms-master/mmc3_test/4-scanline_timing.nes", log_file="./logs/nes.log", log_level=logging.INFO)


###### NESTEST
# all passed
# nes = NES("./testroms/nestest/nestest.nes", log_file="./logs/nes.log", log_level=logging.INFO)

##### BLARGG'S CPU TESTS
# passed
# nes = NES("./testroms/instr_test-v5/rom_singles/01-basics.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/01-basics.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/02-implied.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/04-zero_page.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/05-zp_xy.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/06-absolute.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/08-ind_x.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/09-ind_y.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/10-branches.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/11-stack.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/12-jmp_jsr.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/13-rts.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/14-rti.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/15-brk.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/official_only.nes", log_file="./logs/nes.log", log_level=logging.INFO)

# passed except undocumented level 2 failures
# nes = NES("./testroms/instr_test-v5/rom_singles/03-immediate.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/07-abs_xy.nes", log_file="./logs/nes.log", log_level=logging.INFO)

##### BLARGG'S PPU TESTS
# passed
# nes = NES("./testroms/blargg_ppu_tests_2005.09.15b/palette_ram.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/blargg_ppu_tests_2005.09.15b/sprite_ram.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/blargg_ppu_tests_2005.09.15b/vram_access.nes", log_file="./logs/nes.log", log_level=logging.INFO)

# ************ FAILED ***************
# nes = NES("./testroms/blargg_ppu_tests_2005.09.15b/vbl_clear_time.nes", log_file="./logs/nes.log", log_level=logging.INFO)
#  \-- fails with vbl cleared too late, but not too worried as vbl period is showing up as 2274, which is about right
# nes = NES("./testroms/blargg_ppu_tests_2005.09.15b/power_up_palette.nes", log_file="./logs/nes.log", log_level=logging.INFO)
#  \-- probably not relevant

##### OTHER PPU TESTS
# not sure - doesn't look like it is working
# relies on monochrome mode - not showing up (though ppu_mask change times look fairly stable)
# nes = NES("./testroms/nmi_sync/demo_ntsc.nes", log_file="./logs/nes.log", log_level=logging.INFO)


##### BLARGG'S APU TESTS
# passed
# nes = NES("./testroms/blargg_apu_2005.07.30/01.len_ctr.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/blargg_apu_2005.07.30/02.len_table.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/blargg_apu_2005.07.30/03.irq_flag.nes", log_file="./logs/nes.log", log_level=logging.INFO)

# ************ FAILED ***************
# nes = NES("./testroms/blargg_apu_2005.07.30/03.irq_flag.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/blargg_apu_2005.07.30/08.irq_timing.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/blargg_apu_2005.07.30/04.clock_jitter.nes", log_file="./logs/nes.log", log_level=logging.INFO)

##### OTHER APU TESTS
# nes = NES("./testroms/test_tri_lin_ctr/lin_ctr.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/square_timer_div2/square_timer_div2.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/test_apu_timers/noise_pitch.nes", log_file="./logs/nes.log", log_level=logging.INFO)

# not sure
# nes = NES("./testroms/test_apu_timers/square_pitch.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/test_apu_timers/triangle_pitch.nes", log_file="./logs/nes.log", log_level=logging.INFO)


#nes.run_frame_headless(run_frames=1)
#nes.run_frame_headless(run_frames=1)
#buffer = nes.run_frame_headless(run_frames=1)

#python version:
#nes = pyNES("./roms/Super Mario Bros. (Japan, USA).nes")




if nes is not None:
    nes.run()

