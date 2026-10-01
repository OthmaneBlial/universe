#include <stdint.h>
#include "guest.h"

static void emit(const void *bytes, long size) {
    sys(NR_write, 1, (long)bytes, size, 0, 0, 0);
}

#define BINARY(op) do { \
    uint64_t result; \
    __asm__ volatile("movq %1, %%mm0\n\tmovq %2, %%mm1\n\t" op " %%mm1, %%mm0\n\tmovq %%mm0, %0" \
                     : "=m"(result) : "m"(left), "m"(right) : "mm0", "mm1", "memory"); \
    emit(&result, 8); \
    __asm__ volatile("movq %1, %%mm0\n\t" op " %2, %%mm0\n\tmovq %%mm0, %0" \
                     : "=m"(result) : "m"(left), "m"(right) : "mm0", "memory"); \
    emit(&result, 8); \
} while (0)

#define SHIFT(op) do { \
    uint64_t result; \
    __asm__ volatile("movq %1, %%mm0\n\tmovq %2, %%mm1\n\t" op " %%mm1, %%mm0\n\tmovq %%mm0, %0" \
                     : "=m"(result) : "m"(left), "m"(count) : "mm0", "mm1", "memory"); \
    emit(&result, 8); \
    __asm__ volatile("movq %1, %%mm0\n\t" op " %2, %%mm0\n\tmovq %%mm0, %0" \
                     : "=m"(result) : "m"(left), "m"(count) : "mm0", "memory"); \
    emit(&result, 8); \
} while (0)

#define IMMEDIATE(op, count) do { \
    uint64_t result; \
    __asm__ volatile("movq %1, %%mm0\n\t" op " $" #count ", %%mm0\n\tmovq %%mm0, %0" \
                     : "=m"(result) : "m"(left) : "mm0", "memory"); \
    emit(&result, 8); \
} while (0)

static void pairs(void) {
    for (unsigned match = 0; match < 2; match++) {
        struct { uint32_t low, high; } value = { 0x89abcdef, 0x76543210 };
        uint64_t a = UINT64_C(0xaabbccdd89abcdef) ^ !match;
        uint64_t d = UINT64_C(0x1122334476543210);
        uint8_t equal;
        __asm__ volatile("lock cmpxchg8b %0\n\tsete %3"
                         : "+m"(value), "+&a"(a), "+&d"(d), "=m"(equal)
                         : "b"(UINT64_C(0x8877665544332211)), "c"(UINT64_C(0x1122334455667788)) : "cc", "memory");
        uint64_t result[] = { value.low, value.high, a, d, equal };
        emit(result, sizeof(result));
    }
    for (unsigned match = 0; match < 2; match++) {
        struct { uint64_t low, high; } __attribute__((aligned(16))) value = {
            UINT64_C(0x0123456789abcdef), UINT64_C(0xfedcba9876543210)
        };
        uint64_t a = value.low ^ !match, d = value.high;
        uint8_t equal;
        __asm__ volatile("lock cmpxchg16b %0\n\tsete %3"
                         : "+m"(value), "+&a"(a), "+&d"(d), "=m"(equal)
                         : "b"(UINT64_C(0x8877665544332211)), "c"(UINT64_C(0x1122334455667788)) : "cc", "memory");
        uint64_t result[] = { value.low, value.high, a, d, equal };
        emit(result, sizeof(result));
    }
}

static void mmx(void) {
    const uint64_t values[][2] = {
        { UINT64_C(0x80007fff0001ffff), UINT64_C(0x7fff8000ffff0001) },
        { UINT64_C(0xff0100807f00ff80), UINT64_C(0x0101ff7f80ff007f) },
        { UINT64_C(0x800000007fffffff), UINT64_C(0x7fffffff80000000) },
        { UINT64_C(0x8000800080008000), UINT64_C(0x8000800080008000) }
    };
    for (unsigned n = 0; n < sizeof(values) / sizeof(values[0]); n++) {
        uint64_t left = values[n][0], right = values[n][1];
        BINARY("paddb"); BINARY("paddw"); BINARY("paddd");
        BINARY("psubb"); BINARY("psubw"); BINARY("psubd");
        BINARY("paddsb"); BINARY("paddsw"); BINARY("paddusb"); BINARY("paddusw");
        BINARY("psubsb"); BINARY("psubsw"); BINARY("psubusb"); BINARY("psubusw");
        BINARY("pcmpeqb"); BINARY("pcmpeqw"); BINARY("pcmpeqd");
        BINARY("pcmpgtb"); BINARY("pcmpgtw"); BINARY("pcmpgtd");
        BINARY("pand"); BINARY("pandn"); BINARY("por"); BINARY("pxor");
        BINARY("packsswb"); BINARY("packuswb"); BINARY("packssdw");
        BINARY("punpcklbw"); BINARY("punpcklwd"); BINARY("punpckldq");
        BINARY("punpckhbw"); BINARY("punpckhwd"); BINARY("punpckhdq");
        BINARY("pmullw"); BINARY("pmulhw"); BINARY("pmaddwd");
    }
    const uint64_t counts[] = { 0, 1, 15, 16, 31, 32, 63, 64, 65, 256 };
    uint64_t left = UINT64_C(0x80017fff89abcdef);
    for (unsigned n = 0; n < sizeof(counts) / sizeof(counts[0]); n++) {
        uint64_t count = counts[n];
        SHIFT("psrlw"); SHIFT("psrld"); SHIFT("psrlq");
        SHIFT("psraw"); SHIFT("psrad");
        SHIFT("psllw"); SHIFT("pslld"); SHIFT("psllq");
    }
    IMMEDIATE("psrlw", 3); IMMEDIATE("psrld", 3); IMMEDIATE("psrlq", 3);
    IMMEDIATE("psraw", 3); IMMEDIATE("psrad", 3);
    IMMEDIATE("psllw", 3); IMMEDIATE("pslld", 3); IMMEDIATE("psllq", 3);
    uint32_t dword = 0x89abcdef, copied = 0;
    uint64_t widened;
    __asm__ volatile("movd %2, %%mm7\n\tmovq %%mm7, %0\n\tmovd %%mm7, %1"
                     : "=m"(widened), "=m"(copied) : "m"(dword) : "mm7", "memory");
    emit(&widened, 8); emit(&copied, 4);
    __asm__ volatile("emms" : : : "memory");
}

static long state_images(void) {
    uint8_t input[16][16], image[512] __attribute__((aligned(16))), restored[512] __attribute__((aligned(16)));
    for (unsigned reg = 0; reg < 16; reg++) {
        for (unsigned byte = 0; byte < 16; byte++) input[reg][byte] = reg * 16 + byte;
    }
    for (unsigned byte = 0; byte < 512; byte++) image[byte] = restored[byte] = 0xa5;
    const uint64_t low = UINT64_C(0x0123456789abcdef), high = UINT64_C(0xfedcba9876543210);
    __asm__ volatile("movq %0, %%mm0\n\tmovq %1, %%mm7" : : "m"(low), "m"(high) : "mm0", "mm7", "memory");
    __asm__ volatile(
        "movdqu 0(%0), %%xmm0\n\tmovdqu 16(%0), %%xmm1\n\tmovdqu 32(%0), %%xmm2\n\tmovdqu 48(%0), %%xmm3\n\t"
        "movdqu 64(%0), %%xmm4\n\tmovdqu 80(%0), %%xmm5\n\tmovdqu 96(%0), %%xmm6\n\tmovdqu 112(%0), %%xmm7\n\t"
        "movdqu 128(%0), %%xmm8\n\tmovdqu 144(%0), %%xmm9\n\tmovdqu 160(%0), %%xmm10\n\tmovdqu 176(%0), %%xmm11\n\t"
        "movdqu 192(%0), %%xmm12\n\tmovdqu 208(%0), %%xmm13\n\tmovdqu 224(%0), %%xmm14\n\tmovdqu 240(%0), %%xmm15"
        : : "r"(input) : "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7",
          "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15", "memory");
    __asm__ volatile("fxsave64 %0" : "+m"(image) : : "memory");
    __asm__ volatile("pxor %%mm0, %%mm0\n\tpxor %%mm7, %%mm7\n\tpxor %%xmm0, %%xmm0\n\tpxor %%xmm15, %%xmm15"
                     : : : "mm0", "mm7", "xmm0", "xmm15", "memory");
    __asm__ volatile("fxrstor64 %1\n\tfxsave64 %0" : "+m"(restored) : "m"(image) : "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7",
                       "xmm8", "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15",
                       "mm0", "mm1", "mm2", "mm3", "mm4", "mm5", "mm6", "mm7", "memory");
    for (unsigned reg = 0; reg < 16; reg++) {
        for (unsigned byte = 0; byte < 16; byte++) if (restored[160 + reg * 16 + byte] != input[reg][byte]) return 20;
    }
    for (unsigned byte = 416; byte < 512; byte++) if (restored[byte] != 0xa5) return 21;
    const uint16_t *header = (const uint16_t *)restored;
    uint64_t facts[] = { header[0], header[1], restored[4], *(const uint32_t *)(restored + 24), *(const uint32_t *)(restored + 28) };
    emit(facts, sizeof(facts)); emit(restored + 160, 256); emit(restored + 32, 10); emit(restored + 144, 10); emit(restored + 416, 96);
    __asm__ volatile("emms\n\tfxsave64 %0" : "+m"(restored) : : "memory");
    emit(restored + 4, 1);
    uint32_t control = 0x1f83, queried = 0;
    __asm__ volatile("ldmxcsr %1\n\tstmxcsr %0" : "=m"(queried) : "m"(control) : "memory");
    emit(&queried, 4);
    return 0;
}

long guest_main(long *sp) {
    (void)sp;
    uint32_t a, b, c, d;
    __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(1), "c"(0));
    uint32_t features[] = { c, d };
    emit(features, sizeof(features));
    pairs(); mmx();
    long result = state_images();
    if (result) return result;
    const char message[] = "x86 baseline atomics, MMX and state images: ok\n";
    text(message, sizeof(message) - 1);
    return 0;
}
