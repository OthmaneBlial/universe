#include <stdint.h>
#include "guest.h"

#define POPCNT_CAPTURE(CONSTRAINT, SOURCE, RESULT, FLAGS) \
    __asm__ volatile("cmpq %[right], %[left]\n\t" \
                     "popcnt %[source], %[result]\n\t" \
                     "setc %[carry]\n\tsetz %[zero]\n\tsetp %[parity]\n\tseto %[overflow]\n\tsets %[sign]" \
                     : [result] "=r"(RESULT), [carry] "=m"((FLAGS)[0]), [zero] "=m"((FLAGS)[1]), \
                       [parity] "=m"((FLAGS)[2]), [overflow] "=m"((FLAGS)[3]), [sign] "=m"((FLAGS)[4]) \
                     : [source] CONSTRAINT(SOURCE), [left] "r"(flag_left), [right] "r"(flag_right) \
                     : "cc")

long guest_main(long *sp) {
    (void)sp;
    const uint64_t flag_left = UINT64_C(0x7fffffffffffffff);
    const uint64_t flag_right = UINT64_MAX;
    const uint16_t source16 = 0x8101;
    const uint32_t source32 = UINT32_C(0xf0f0a5a5);
    const uint64_t source64 = UINT64_C(0x8000000000000101);
    const uint32_t source_zero = 0;
    struct { uint16_t word; uint32_t dword; uint64_t qword; uint32_t zero; } result;
    uint8_t flags[4][5];

    POPCNT_CAPTURE("r", source16, result.word, flags[0]);
    POPCNT_CAPTURE("m", source32, result.dword, flags[1]);
    POPCNT_CAPTURE("r", source64, result.qword, flags[2]);
    POPCNT_CAPTURE("r", source_zero, result.zero, flags[3]);

    sys(NR_write, 1, (long)&result.word, sizeof(result.word), 0, 0, 0);
    sys(NR_write, 1, (long)&result.dword, sizeof(result.dword), 0, 0, 0);
    sys(NR_write, 1, (long)&result.qword, sizeof(result.qword), 0, 0, 0);
    sys(NR_write, 1, (long)&result.zero, sizeof(result.zero), 0, 0, 0);
    sys(NR_write, 1, (long)flags, sizeof(flags), 0, 0, 0);
    const char message[] = "POPCNT widths and flags: ok\n";
    text(message, sizeof(message) - 1);
    return 0;
}

#undef POPCNT_CAPTURE
