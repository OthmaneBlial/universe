#include <stdint.h>
#include "guest.h"

/* Binary input records keep the oracle outside the guest and exercise real encodings. */
struct query { uint32_t operation, control; uint64_t left, right; };
struct answer { uint64_t value; uint32_t control; } __attribute__((packed));

#define OP(single, doubled) do { \
    if (wide) __asm__ volatile(doubled " %%xmm1, %%xmm0" : : : "xmm0", "memory"); \
    else __asm__ volatile(single " %%xmm1, %%xmm0" : : : "xmm0", "memory"); \
} while (0)
#define COMPARE(single, doubled) do { \
    uint8_t carry, parity, zero; \
    if (wide) __asm__ volatile(doubled " %%xmm1, %%xmm0\n\tsetb %0\n\tsetp %1\n\tsete %2" \
                              : "=qm"(carry), "=qm"(parity), "=qm"(zero) : : "cc", "memory"); \
    else __asm__ volatile(single " %%xmm1, %%xmm0\n\tsetb %0\n\tsetp %1\n\tsete %2" \
                          : "=qm"(carry), "=qm"(parity), "=qm"(zero) : : "cc", "memory"); \
    result.value = carry | ((uint64_t)parity << 2) | ((uint64_t)zero << 6); \
    integer_result = 1; \
} while (0)

long guest_main(long *sp) {
    (void)sp;
    for (;;) {
        struct query q;
        unsigned used = 0;
        while (used < sizeof(q)) {
            long size = sys(NR_read, 0, (long)((char *)&q + used), sizeof(q) - used, 0, 0, 0);
            if (size == 0) return used == 0 ? 0 : 90;
            if (size < 0) return 91;
            used += (unsigned)size;
        }
        const unsigned wide = q.operation & 256;
        uint64_t a = wide ? q.left : (uint32_t)q.left | ((uint64_t)(uint32_t)q.left << 32);
        uint64_t b = wide ? q.right : (uint32_t)q.right | ((uint64_t)(uint32_t)q.right << 32);
        uint64_t left[2] = { a, a }, right[2] = { b, b };
        __asm__ volatile("ldmxcsr %2\n\tmovdqu %0, %%xmm0\n\tmovdqu %1, %%xmm1"
                         : : "m"(left), "m"(right), "m"(q.control) : "xmm0", "xmm1", "memory");
        struct answer result = { 0, 0 };
        unsigned integer_result = 0;
        switch (q.operation & 255) {
            case 0: OP("addss", "addsd"); break;
            case 1: OP("subss", "subsd"); break;
            case 2: OP("mulss", "mulsd"); break;
            case 3: OP("divss", "divsd"); break;
            case 4: OP("sqrtss", "sqrtsd"); break;
            case 5: OP("minss", "minsd"); break;
            case 6: OP("maxss", "maxsd"); break;
            case 7:
                if (wide) __asm__ volatile("cvtsi2sd %0, %%xmm0" : : "r"(q.left) : "xmm0", "memory");
                else __asm__ volatile("cvtsi2ss %0, %%xmm0" : : "r"(q.left) : "xmm0", "memory");
                break;
            case 8:
                if (wide) __asm__ volatile("cvtsd2si %%xmm0, %0" : "=r"(result.value) : : "memory");
                else __asm__ volatile("cvtss2si %%xmm0, %0" : "=r"(result.value) : : "memory");
                integer_result = 1; break;
            case 9:
                if (wide) __asm__ volatile("cvttsd2si %%xmm0, %0" : "=r"(result.value) : : "memory");
                else __asm__ volatile("cvttss2si %%xmm0, %0" : "=r"(result.value) : : "memory");
                integer_result = 1; break;
            case 10:
                if (wide) __asm__ volatile("cvtsd2ss %%xmm0, %%xmm0" : : : "xmm0", "memory");
                else __asm__ volatile("cvtss2sd %%xmm0, %%xmm0" : : : "xmm0", "memory");
                break;
            case 11: OP("roundss $4,", "roundsd $4,"); break;
            case 12: OP("roundss $12,", "roundsd $12,"); break;
            case 13: COMPARE("comiss", "comisd"); break;
            case 14: COMPARE("ucomiss", "ucomisd"); break;
            case 15: OP("cmpss $0,", "cmpsd $0,"); break;
            case 16: OP("cmpss $1,", "cmpsd $1,"); break;
            case 17: OP("cmpss $2,", "cmpsd $2,"); break;
            case 18: OP("cmpss $3,", "cmpsd $3,"); break;
            case 19: OP("cmpss $4,", "cmpsd $4,"); break;
            case 20: OP("cmpss $5,", "cmpsd $5,"); break;
            case 21: OP("cmpss $6,", "cmpsd $6,"); break;
            case 22: OP("cmpss $7,", "cmpsd $7,"); break;
            case 23: OP("haddps", "haddpd"); break;
            case 24: OP("hsubps", "hsubpd"); break;
            case 25: OP("addsubps", "addsubpd"); break;
            case 26: OP("dpps $255,", "dppd $255,"); break;
            case 27: OP("addps", "addpd"); break;
            case 28: OP("divps", "divpd"); break;
            case 29: OP("sqrtps", "sqrtpd"); break;
            default: return 92;
        }
        if (!integer_result) {
            __asm__ volatile("movq %%xmm0, %0" : "=r"(result.value) : : "memory");
            if ((q.operation & 255) == 10) {
                if (wide) result.value &= UINT32_MAX;
            } else if (!wide) result.value &= UINT32_MAX;
        }
        __asm__ volatile("stmxcsr %0" : "=m"(result.control) : : "memory");
        if (sys(NR_write, 1, (long)&result, sizeof(result), 0, 0, 0) != sizeof(result)) return 93;
    }
}
