#include <stdint.h>
#include "guest.h"

struct query { uint32_t operation, control; uint64_t significand, exponent; };
struct extended { uint64_t significand; uint16_t exponent; } __attribute__((packed));
struct answer { unsigned char value[10]; uint16_t status; uint32_t control, mxcsr; uint8_t tag, padding[3]; } __attribute__((packed));
static _Alignas(16) unsigned char reset[512], image[512];
#define LOAD_OP(text) __asm__ volatile(text " %0" : : "m"(q.significand) : "memory")
#define STORE_OP(text) __asm__ volatile(text " %0" : "=m"(result.value) : : "memory")

long guest_main(long *sp) {
    (void)sp;
    reset[0] = 0x7f; reset[1] = 3;
    reset[24] = 0x80; reset[25] = 0x1f;
    for (;;) {
        struct query q;
        unsigned used = 0;
        while (used < sizeof(q)) {
            long n = sys(NR_read, 0, (long)((char *)&q + used), sizeof(q) - used, 0, 0, 0);
            if (n == 0) return used == 0 ? 0 : 90;
            if (n < 0) return 91;
            used += (unsigned)n;
        }
        struct extended input = { q.significand, (uint16_t)q.exponent };
        struct answer result = { { 0 }, 0, 0, 0, 0, { 0 } };
        unsigned stored = 0, slot = 0;
        __asm__ volatile("fxrstor64 %0\n\tfninit\n\tfldcw %1" : : "m"(reset), "m"(q.control) : "memory");
        if (q.operation >= 6 && q.operation <= 34)
            __asm__ volatile("fldt %0" : : "m"(input) : "memory");
        switch (q.operation) {
            case 0: LOAD_OP("flds"); break;
            case 1: LOAD_OP("fldl"); break;
            case 2: __asm__ volatile("fldt %0" : : "m"(input) : "memory"); break;
            case 3: LOAD_OP("filds"); break;
            case 4: LOAD_OP("fildl"); break;
            case 5: LOAD_OP("fildll"); break;
            case 6: STORE_OP("fsts"); stored = 1; break;
            case 7: STORE_OP("fstl"); stored = 1; break;
            case 8: STORE_OP("fstps"); stored = 1; break;
            case 9: STORE_OP("fstpl"); stored = 1; break;
            case 10: STORE_OP("fists"); stored = 1; break;
            case 11: STORE_OP("fistl"); stored = 1; break;
            case 12: STORE_OP("fistps"); stored = 1; break;
            case 13: STORE_OP("fistpl"); stored = 1; break;
            case 14: STORE_OP("fistpll"); stored = 1; break;
            case 15: STORE_OP("fisttps"); stored = 1; break;
            case 16: STORE_OP("fisttpl"); stored = 1; break;
            case 17: STORE_OP("fisttpll"); stored = 1; break;
            case 18: __asm__ volatile("fchs" : : : "memory"); break;
            case 19: __asm__ volatile("fabs" : : : "memory"); break;
            case 20: __asm__ volatile("fxam" : : : "memory"); break;
            case 21: __asm__ volatile("fld %%st(0)" : : : "memory"); break;
            case 22: __asm__ volatile("fst %%st(3)" : : : "memory"); break;
            case 23: __asm__ volatile("fstp %%st(1)" : : : "memory"); break;
            case 24: __asm__ volatile("ffree %%st(0)" : : : "memory"); break;
            case 25: __asm__ volatile("fincstp" : : : "memory"); slot = 7; break;
            case 26: __asm__ volatile("fdecstp" : : : "memory"); slot = 1; break;
            case 27: __asm__ volatile("fninit\n\tfldcw %0\n\tfld1" : : "m"(q.control) : "memory"); break;
            case 28: __asm__ volatile("fninit\n\tfldcw %0\n\tfldz" : : "m"(q.control) : "memory"); break;
            case 29: __asm__ volatile("fnop" : : : "memory"); break;
            case 30: __asm__ volatile("ffree %%st(0)\n\tfxam" : : : "memory"); break;
            case 31: __asm__ volatile("ffree %%st(0)\n\tfchs" : : : "memory"); break;
            case 32: STORE_OP("fstpt"); stored = 1; break;
            case 33: __asm__ volatile("fxch %%st(3)" : : : "memory"); break;
            case 34: __asm__ volatile("fxch %%st(0)" : : : "memory"); break;
            default: return 92;
        }
        __asm__ volatile("fnstsw %0\n\tfnstcw %1\n\tfxsave64 %2" : "=m"(result.status), "=m"(result.control), "=m"(image) : : "memory");
        if (!stored) for (unsigned n = 0; n < 10; ++n) result.value[n] = image[32 + slot * 16 + n];
        result.mxcsr = (uint32_t)image[24] | ((uint32_t)image[25] << 8) | ((uint32_t)image[26] << 16) | ((uint32_t)image[27] << 24);
        result.tag = image[4];
        if (sys(NR_write, 1, (long)&result, sizeof(result), 0, 0, 0) != sizeof(result)) return 93;
    }
}
