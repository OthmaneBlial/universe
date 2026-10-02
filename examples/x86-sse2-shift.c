#include <emmintrin.h>
#include <stdint.h>
#include "guest.h"

static uint64_t lane(const uint8_t *p, unsigned size) {
    uint64_t value = 0;
    for (unsigned byte = 0; byte < size; ++byte) value |= (uint64_t)p[byte] << (byte * 8);
    return value;
}

static int matches(const volatile uint8_t *actual, unsigned offset, uint64_t expected, unsigned size) {
    for (unsigned byte = 0; byte < size; ++byte) if (actual[offset + byte] != (uint8_t)(expected >> (byte * 8))) return 0;
    return 1;
}

static uint64_t shifted(uint64_t value, unsigned bits, uint64_t count, unsigned op) {
    const uint64_t mask = bits == 64 ? UINT64_MAX : (UINT64_C(1) << bits) - 1;
    const int negative = (value & (UINT64_C(1) << (bits - 1))) != 0;
    if (count >= bits) return op == 3 || op == 4 ? (negative ? mask : 0) : 0;
    if (op < 3) return value >> count;
    if (op < 5) {
        value >>= count;
        if (negative && count) value |= mask ^ (mask >> count);
        return value & mask;
    }
    return (value << count) & mask;
}

// Emit every imm8, including values above the 16-byte saturation boundary.
// Inline assembly keeps the compiler from replacing these with scalar shifts.
#define BYTE_SHIFT(n) do { \
    __asm__ volatile("movdqu %1, %%xmm9; pslldq %2, %%xmm9; movdqu %%xmm9, %0" \
        : "=m" (byte_results[n][0]) : "m" (input), "i" (n) : "xmm9"); \
    __asm__ volatile("movdqu %1, %%xmm9; psrldq %2, %%xmm9; movdqu %%xmm9, %0" \
        : "=m" (byte_results[n][1]) : "m" (input), "i" (n) : "xmm9"); \
} while (0)
#define BYTE_GROUP(n) \
    BYTE_SHIFT(n); BYTE_SHIFT((n)+1); BYTE_SHIFT((n)+2); BYTE_SHIFT((n)+3); \
    BYTE_SHIFT((n)+4); BYTE_SHIFT((n)+5); BYTE_SHIFT((n)+6); BYTE_SHIFT((n)+7); \
    BYTE_SHIFT((n)+8); BYTE_SHIFT((n)+9); BYTE_SHIFT((n)+10); BYTE_SHIFT((n)+11); \
    BYTE_SHIFT((n)+12); BYTE_SHIFT((n)+13); BYTE_SHIFT((n)+14); BYTE_SHIFT((n)+15)

long guest_main(long *sp) {
    (void)sp;
    uint8_t input[32];
    if (sys(NR_read, 0, (long)input, sizeof(input), 0, 0, 0) != sizeof(input)) return 10;
    const __m128i data = _mm_loadu_si128((const __m128i *)input);
    const __m128i count = _mm_loadu_si128((const __m128i *)(input + 16));
    volatile __m128i results[8];
    results[0] = _mm_srl_epi16(data, count);
    results[1] = _mm_srl_epi32(data, count);
    results[2] = _mm_srl_epi64(data, count);
    results[3] = _mm_sra_epi16(data, count);
    results[4] = _mm_sra_epi32(data, count);
    results[5] = _mm_sll_epi16(data, count);
    results[6] = _mm_sll_epi32(data, count);
    results[7] = _mm_sll_epi64(data, count);
    const unsigned sizes[8] = { 2, 4, 8, 2, 4, 2, 4, 8 };
    const uint64_t shift = lane(input + 16, 8);
    for (unsigned op = 0; op < 8; ++op) {
        const volatile uint8_t *actual = (const volatile uint8_t *)&results[op];
        const unsigned size = sizes[op];
        for (unsigned offset = 0; offset < 16; offset += size) {
            const uint64_t expected = shifted(lane(input + offset, size), size * 8, shift, op);
            if (!matches(actual, offset, expected, size)) return 11 + op;
        }
    }
    uint8_t byte_results[256][2][16];
    BYTE_GROUP(0); BYTE_GROUP(16); BYTE_GROUP(32); BYTE_GROUP(48);
    BYTE_GROUP(64); BYTE_GROUP(80); BYTE_GROUP(96); BYTE_GROUP(112);
    BYTE_GROUP(128); BYTE_GROUP(144); BYTE_GROUP(160); BYTE_GROUP(176);
    BYTE_GROUP(192); BYTE_GROUP(208); BYTE_GROUP(224); BYTE_GROUP(240);
    if (sys(NR_write, 1, (long)byte_results, sizeof(byte_results), 0, 0, 0) != sizeof(byte_results)) return 19;
    const char result[] = "SSE2 variable and byte shifts: ok\n";
    text(result, sizeof(result) - 1);
    return 0;
}
