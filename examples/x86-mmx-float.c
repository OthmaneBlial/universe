#include <stdint.h>
#include "guest.h"

struct query { uint32_t operation, control; uint16_t status; uint8_t tag, reserved; uint8_t left[16], right[16]; };
struct answer { uint8_t value[16]; uint32_t control; uint16_t status, x87_control; uint64_t changed_flags; uint8_t raw[80], tag, reserved[7]; };
_Static_assert(sizeof(struct query) == 44 && sizeof(struct answer) == 120, "wire sizes");

/* Seed MMX through FXRSTOR: MOVQ would erase the incoming TOP and tags. */
#define RUN(op) __asm__ volatile( \
    "fxrstor64 %[image]\n\tpushfq\n\tpopq %[before]\n\t" op \
    "\n\tpushfq\n\tpopq %[after]\n\tfxsave64 %[image]" \
    : [image] "+m"(image), [before] "=&r"(before), [after] "=&r"(after) \
    : [source] "r"(source + offset) \
    : "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7", \
      "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15", \
      "mm0", "mm1", "mm2", "mm3", "mm4", "mm5", "mm6", "mm7", "memory")

long guest_main(long *sp) {
    (void)sp;
    for (;;) {
        struct query q;
        unsigned used = 0;
        while (used < sizeof(q)) {
            long n = sys(NR_read, 0, (long)((char *)&q + used), sizeof(q) - used, 0, 0, 0);
            if (n == 0) return used == 0 ? 0 : 90;
            if (n < 0) return 91;
            used += (unsigned)n;
        }
        uint8_t image[512] __attribute__((aligned(16))), source[32] __attribute__((aligned(16)));
        struct answer result;
        unsigned op = q.operation & 255, offset = (q.operation >> 8) & 15, top = (q.status >> 11) & 7;
        for (unsigned n = 0; n < 512; ++n) image[n] = 0;
        for (unsigned n = 0; n < sizeof(result); ++n) ((uint8_t *)&result)[n] = 0;
        image[0] = (q.operation & (1u << 24)) ? 0x7e : 0x7f;
        image[1] = 3;
        image[2] = q.status; image[3] = q.status >> 8; image[4] = q.tag;
        for (unsigned n = 0; n < 4; ++n) image[24 + n] = q.control >> (n * 8);
        for (unsigned slot = 0; slot < 8; ++slot) {
            unsigned physical = (top + slot) & 7;
            for (unsigned n = 0; n < 10; ++n) image[32 + slot * 16 + n] = (physical * 31 + n * 19) ^ 0x5a;
            if (physical == 7) for (unsigned n = 0; n < 8; ++n)
                image[32 + slot * 16 + n] = (op == 1 || op == 2 || op == 4) ? q.right[n] : q.left[n];
        }
        for (unsigned n = 0; n < 16; ++n) {
            image[160 + 8 * 16 + n] = q.left[n];
            image[160 + 15 * 16 + n] = q.right[n];
            source[offset + n] = q.right[n];
        }
        uint64_t before, after;
        switch (op) {
            case 0: RUN("movdq2q %%xmm15, %%mm7"); break;
            case 1: RUN("movq2dq %%mm7, %%xmm8"); break;
            case 2: RUN("cvtpi2ps %%mm7, %%xmm8"); break;
            case 3: RUN("cvtpi2ps (%[source]), %%xmm8"); break;
            case 4: RUN("cvtpi2pd %%mm7, %%xmm8"); break;
            case 5: RUN("cvtpi2pd (%[source]), %%xmm8"); break;
            case 6: RUN("cvtps2pi %%xmm15, %%mm7"); break;
            case 7: RUN("cvtps2pi (%[source]), %%mm7"); break;
            case 8: RUN("cvttps2pi %%xmm15, %%mm7"); break;
            case 9: RUN("cvttps2pi (%[source]), %%mm7"); break;
            case 10: RUN("cvtpd2pi %%xmm15, %%mm7"); break;
            case 11: RUN("cvtpd2pi (%[source]), %%mm7"); break;
            case 12: RUN("cvttpd2pi %%xmm15, %%mm7"); break;
            case 13: RUN("cvttpd2pi (%[source]), %%mm7"); break;
            default: return 92;
        }
        for (unsigned n = 0; n < 16; ++n) result.value[n] = image[160 + 8 * 16 + n];
        result.control = (uint32_t)image[24] | (uint32_t)image[25] << 8 | (uint32_t)image[26] << 16 | (uint32_t)image[27] << 24;
        result.status = (uint16_t)image[2] | (uint16_t)image[3] << 8;
        result.x87_control = (uint16_t)image[0] | (uint16_t)image[1] << 8;
        result.tag = image[4]; result.changed_flags = before ^ after;
        top = (result.status >> 11) & 7;
        for (unsigned slot = 0; slot < 8; ++slot) for (unsigned n = 0; n < 10; ++n)
            result.raw[((top + slot) & 7) * 10 + n] = image[32 + slot * 16 + n];
        if (sys(NR_write, 1, (long)&result, sizeof(result), 0, 0, 0) != sizeof(result)) return 93;
    }
}
