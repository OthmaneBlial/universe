#include <stdint.h>
#include "guest.h"

struct query { uint32_t operation, control; uint8_t left[16], right[16]; };
struct answer { uint8_t memory[64], value[16]; uint32_t control; uint16_t status; uint8_t tag, reserved; uint64_t changed_flags; };

#define XMM(op) __asm__ volatile( \
    "movdqu %[left], %%xmm8\n\tmovdqu %[right], %%xmm15\n\tpushfq\n\tpopq %[before]\n\t" op \
    "\n\tsfence\n\tpushfq\n\tpopq %[after]\n\tmovdqu %%xmm8, %[value]" \
    : [before] "=&r"(before), [after] "=&r"(after), [value] "=m"(result.value) \
    : [left] "m"(left), [right] "m"(right), "D"(target) : "rax", "xmm8", "xmm15", "memory")
#define MMX(op) __asm__ volatile( \
    "movq %[left], %%mm7\n\tmovq %[right], %%mm6\n\tpushfq\n\tpopq %[before]\n\t" op \
    "\n\tsfence\n\tpushfq\n\tpopq %[after]\n\tmovq %%mm7, %[value]" \
    : [before] "=&r"(before), [after] "=&r"(after), [value] "=m"(result.value) \
    : [left] "m"(left), [right] "m"(right), "D"(target) : "mm7", "mm6", "memory")

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
        uint8_t left[16] __attribute__((aligned(16))), right[16] __attribute__((aligned(16)));
        uint8_t image[512] __attribute__((aligned(16)));
        struct answer result __attribute__((aligned(16)));
        for (unsigned n = 0; n < sizeof(result); ++n) ((uint8_t *)&result)[n] = 0;
        for (unsigned n = 0; n < 64; ++n) result.memory[n] = 0xa5;
        for (unsigned n = 0; n < 16; ++n) { left[n] = q.left[n]; right[n] = q.right[n]; }
        unsigned offset = (q.operation >> 8) & 15;
        uint8_t *target = result.memory + 16 + offset;
        uint64_t before, after;
        __asm__ volatile("fninit\n\tldmxcsr %0" : : "m"(q.control) : "memory");
        switch (q.operation & 255) {
            case 0: XMM("andnps %%xmm15, %%xmm8"); break;
            case 1: XMM("andnpd %%xmm15, %%xmm8"); break;
            case 2: XMM("andnps %[right], %%xmm8"); break;
            case 3: XMM("andnpd %[right], %%xmm8"); break;
            case 4: XMM("andnps %%xmm8, %%xmm8"); break;
            case 5: XMM("andnpd %%xmm8, %%xmm8"); break;
            case 6: XMM("movntps %%xmm8, (%%rdi)"); break;
            case 7: XMM("movntpd %%xmm8, (%%rdi)"); break;
            case 8: XMM("movntdq %%xmm8, (%%rdi)"); break;
            case 9: XMM("movl %[left], %%eax\n\tmovnti %%eax, (%%rdi)"); break;
            case 10: XMM("movq %[left], %%rax\n\tmovnti %%rax, (%%rdi)"); break;
            case 11: XMM("maskmovdqu %%xmm15, %%xmm8"); break;
            case 12: XMM("maskmovdqu %%xmm15, %%xmm15"); break;
            case 13: MMX("movntq %%mm7, (%%rdi)"); break;
            case 14: MMX("maskmovq %%mm6, %%mm7"); break;
            case 15: MMX("maskmovq %%mm7, %%mm7"); break;
            case 16: XMM("pushfw\n\tpopw %%ax"); break;
            default: return 92;
        }
        result.changed_flags = before ^ after;
        __asm__ volatile("fnstsw %0\n\tstmxcsr %1\n\tfxsave64 %2" : "=m"(result.status), "=m"(result.control), "=m"(image) : : "memory");
        result.tag = image[4];
        if (sys(NR_write, 1, (long)&result, sizeof(result), 0, 0, 0) != sizeof(result)) return 93;
    }
}
