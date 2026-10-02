#include <stdint.h>
#include "guest.h"

struct query { uint32_t operation, control; uint8_t left[16], right[16]; };
struct answer { uint8_t value[16]; uint32_t control; uint16_t status; uint8_t tag, reserved; uint64_t changed_flags; };

#define XMM(op) __asm__ volatile( \
    "movdqu %[left], %%xmm8\n\tmovdqu %[right], %%xmm15\n\tpushfq\n\tpopq %[before]\n\t" op \
    "\n\tpushfq\n\tpopq %[after]\n\tmovdqu %%xmm8, %[value]" \
    : [before] "=&r"(before), [after] "=&r"(after), [value] "=m"(result.value) \
    : [left] "m"(left), [right] "m"(q.right), [source] "r"(source + offset) \
    : "xmm8", "xmm15", "memory")

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
        uint8_t left[16] __attribute__((aligned(16))), source[32] __attribute__((aligned(16)));
        uint8_t image[512] __attribute__((aligned(16)));
        struct answer result;
        unsigned offset = (q.operation >> 8) & 15;
        for (unsigned n = 0; n < 16; ++n) { left[n] = q.left[n]; source[n + offset] = q.right[n]; }
        uint64_t before, after;
        __asm__ volatile("fninit\n\tldmxcsr %0" : : "m"(q.control) : "memory");
        switch (q.operation & 255) {
            case 0: XMM("rcpps %%xmm15, %%xmm8"); break;
            case 1: XMM("rcpps (%[source]), %%xmm8"); break;
            case 2: XMM("rcpps %%xmm8, %%xmm8"); break;
            case 3: XMM("rcpss %%xmm15, %%xmm8"); break;
            case 4: XMM("rcpss (%[source]), %%xmm8"); break;
            case 5: XMM("rcpss %%xmm8, %%xmm8"); break;
            case 6: XMM("rsqrtps %%xmm15, %%xmm8"); break;
            case 7: XMM("rsqrtps (%[source]), %%xmm8"); break;
            case 8: XMM("rsqrtps %%xmm8, %%xmm8"); break;
            case 9: XMM("rsqrtss %%xmm15, %%xmm8"); break;
            case 10: XMM("rsqrtss (%[source]), %%xmm8"); break;
            case 11: XMM("rsqrtss %%xmm8, %%xmm8"); break;
            default: return 92;
        }
        result.changed_flags = before ^ after;
        result.reserved = 0;
        __asm__ volatile("fnstsw %0\n\tstmxcsr %1\n\tfxsave64 %2" : "=m"(result.status), "=m"(result.control), "=m"(image) : : "memory");
        result.tag = image[4];
        if (sys(NR_write, 1, (long)&result, sizeof(result), 0, 0, 0) != sizeof(result)) return 93;
    }
}
