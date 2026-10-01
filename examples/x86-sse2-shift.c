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
    const char result[] = "SSE2 variable shifts: ok\n";
    text(result, sizeof(result) - 1);
    return 0;
}
