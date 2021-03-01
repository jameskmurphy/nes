# cython: language_level=3

import pyximport; pyximport.install()

from nes.cycore.system cimport NES, SYNC_NONE

DEF MAX_INSTR_TEST_FRAMES = 1800  # this is 30s of runtime
DEF PASS = 1
DEF FAIL = 0
DEF ERROR = 2

INSTR_TESTS = ["01-basics", "02-implied", "03-immediate", "04-zero_page", "05-zp_xy", "06-absolute", "07-abs_xy",
               "08-ind_x", "09-ind_y", "10-branches", "11-stack", "12-jmp_jsr", "13-rts", "14-rti", "15-brk",
               "16-special"]

cpdef object get_nametables(NES nes):
    cdef int nx, ny, x, y

    ntbls = []

    for ny in range(2):
        for nx in range(2):
            base = 0x2000 + 0x800 * ny + 0x400 * nx
            ntbl = ""
            for y in range(30):
                for x in range(32):
                    tile = nes.ppu.vram.read(base + 32 * y + x)
                    ntbl += chr(tile)
                ntbl += "\n"
            ntbls.append(ntbl)
    return ntbls


cpdef int run_instr_test(test_name):
    nes = NES("./testroms/instr_test-v5/rom_singles/{}.nes".format(test_name), sync_mode=SYNC_NONE, verbose=False)
    found_pass, found_fail, frame = -1, -1, 0

    while found_pass < 0 and found_fail < 0 and frame < MAX_INSTR_TEST_FRAMES:

        nes.run_frame_headless()
        ntbls = get_nametables(nes)
        ntbls_all = ""
        for ntbl in ntbls:
            ntbls_all += ntbl
        found_pass = ntbls_all.find("Passed")
        found_fail = ntbls_all.find("Failed")
        frame +=1

    if found_fail > 0:
        return FAIL
    elif found_pass > 0:
        return PASS
    else:
        return ERROR


cpdef void run_tests():
    for test in INSTR_TESTS:
        result = run_instr_test(test)
        print("test {}: {}".format(test, "pass" if result==PASS else "***====> FAIL <====***" if result==FAIL else "****!!!!! unknown error !!!!!****"))

