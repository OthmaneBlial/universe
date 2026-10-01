#include <stdint.h>
#include "guest.h"

long guest_main(long *sp) {
    (void)sp;
    const uint64_t flag_left = UINT64_C(0x7fffffffffffffff);
    const uint64_t flag_right = UINT64_MAX;
    uint32_t dword = UINT32_C(0x01234567);
    const uint64_t qword_source = UINT64_C(0x0123456789abcdef);
    const uint64_t extended_source = UINT64_C(0xaabbccdd11223344);
    uint64_t qword;
    uint64_t extended_dword;
    uint8_t flags[5];

    __asm__ volatile("cmpq %[right], %[left]\n\tbswap %[result]\n\tsetc %[carry]\n\tsetz %[zero]\n\tsetp %[parity]\n\tseto %[overflow]\n\tsets %[sign]"
                     : [result] "+&r"(dword), [carry] "=m"(flags[0]), [zero] "=m"(flags[1]),
                       [parity] "=m"(flags[2]), [overflow] "=m"(flags[3]), [sign] "=m"(flags[4])
                     : [left] "r"(flag_left), [right] "r"(flag_right) : "cc");
    __asm__ volatile("movq %1, %%r8\n\tbswap %%r8\n\tmovq %%r8, %0"
                     : "=r"(qword) : "r"(qword_source) : "r8");
    __asm__ volatile("movq %1, %%r8\n\tbswap %%r8d\n\tmovq %%r8, %0"
                     : "=r"(extended_dword) : "r"(extended_source) : "r8");

    sys(NR_write, 1, (long)&dword, sizeof(dword), 0, 0, 0);
    sys(NR_write, 1, (long)&qword, sizeof(qword), 0, 0, 0);
    sys(NR_write, 1, (long)&extended_dword, sizeof(extended_dword), 0, 0, 0);
    sys(NR_write, 1, (long)flags, sizeof(flags), 0, 0, 0);
    const char message[] = "BSWAP widths and extended registers: ok\n";
    text(message, sizeof(message) - 1);
    return 0;
}
