import pyximport; pyximport.install()


import logging
from nes.cycore.system import NES
from nes import LOG_CPU, LOG_PPU

# Mapper 0
#nes = NES("./roms/Super Mario Bros. (Japan, USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Balloon_fight.nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/donkey kong.nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Ice Climber.nes", log_file="./logs/nes.log", log_level=logging.INFO)

# Mapper 2
#nes = NES("./roms/Mega Man (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/DuckTales (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)

# Mapper 1
#nes = NES("./roms/Silk Worm (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Metroid (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Legend of Zelda, The (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
nes = NES("./roms/Dragon Warrior 3 (U).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Castlevania II - Simon's Quest (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)
#nes = NES("./roms/Ikari III - The Rescue (USA).nes", log_file="./logs/nes.log", log_level=logging.INFO)


#nes = NES.load("test.p")

# Test ROMS

# nes = NES("./testroms/nestest/nestest.  nes", log_file="./logs/nes.log", log_level=logging.INFO)

# passed
# nes = NES("./testroms/instr_test-v5/rom_singles/01-basics.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/02-implied.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/04-zero_page.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/05-zp_xy.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/06-absolute.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/08-ind_x.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/10-branches.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/11-stack.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/12-jmp_jsr.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/13-rts.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/14-rti.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/16-special.nes", log_file="./logs/nes.log", log_level=logging.INFO)

# passed except undocumented level 2 failures
# nes = NES("./testroms/instr_test-v5/rom_singles/03-immediate.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/07-abs_xy.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/instr_test-v5/rom_singles/09-ind_y.nes", log_file="./logs/nes.log", log_level=logging.INFO)

# ************ FAILED ***************
# nes = NES("./testroms/instr_test-v5/rom_singles/15-brk.nes", log_file="./logs/nes.log", log_level=logging.INFO)


# not sure
# nes = NES("./testroms/nmi_sync/demo_ntsc.nes", log_file="./logs/nes.log", log_level=logging.INFO)

# passed
# nes = NES("./testroms/blargg_ppu_tests_2005.09.15b/palette_ram.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/blargg_ppu_tests_2005.09.15b/sprite_ram.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/blargg_ppu_tests_2005.09.15b/vram_access.nes", log_file="./logs/nes.log", log_level=logging.INFO)

# ************ FAILED ***************
# nes = NES("./testroms/blargg_ppu_tests_2005.09.15b/vbl_clear_time.nes", log_file="./logs/nes.log", log_level=logging.INFO)
#  \-- fails with vbl cleared too late, but not too worried as vbl period is showing up as 2274, which is about right


# APU Tests
# passed
# nes = NES("./testroms/blargg_apu_2005.07.30/02.len_table.nes", log_file="./logs/nes.log", log_level=logging.INFO)


# nes = NES("./testroms/test_tri_lin_ctr/lin_ctr.nes", log_file="./logs/nes.log", log_level=logging.INFO)


# ************ FAILED ***************
# nes = NES("./testroms/blargg_apu_2005.07.30/01.len_ctr.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/blargg_apu_2005.07.30/03.irq_flag.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/blargg_apu_2005.07.30/04.clock_jitter.nes", log_file="./logs/nes.log", log_level=logging.INFO)


#nes = NES("./testroms/square_timer_div2/square_timer_div2.nes", log_file="./logs/nes.log", log_level=logging.INFO)

#nes = NES("./testroms/test_apu_timers/noise_pitch.nes", log_file="./logs/nes.log", log_level=logging.INFO)


# not sure
# nes = NES("./testroms/test_apu_timers/square_pitch.nes", log_file="./logs/nes.log", log_level=logging.INFO)
# nes = NES("./testroms/test_apu_timers/triangle_pitch.nes", log_file="./logs/nes.log", log_level=logging.INFO)


nes.run()

