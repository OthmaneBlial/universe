#include <emmintrin.h>
#include <stdint.h>
#include "guest.h"

static uint16_t u16(const uint8_t *p) {
    return (uint16_t)p[0] | (uint16_t)p[1] << 8;
}

static int32_t s16(uint16_t value) {
    return (value & 0x8000) ? (int32_t)value - 65536 : value;
}

static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static int matches(const volatile uint8_t *actual, unsigned offset, uint64_t expected, unsigned size) {
    for (unsigned byte = 0; byte < size; ++byte) if (actual[offset + byte] != (uint8_t)(expected >> (byte * 8))) return 0;
    return 1;
}

long guest_main(long *sp) {
    (void)sp;
    uint8_t input[32];
    if (sys(NR_read, 0, (long)input, sizeof(input), 0, 0, 0) != sizeof(input)) return 10;
    const __m128i left = _mm_loadu_si128((const __m128i *)input);
    const __m128i right = _mm_loadu_si128((const __m128i *)(input + 16));
    volatile __m128i results[5];
    results[0] = _mm_mullo_epi16(left, right);
    results[1] = _mm_mulhi_epi16(left, right);
    results[2] = _mm_mulhi_epu16(left, right);
    results[3] = _mm_mul_epu32(left, right);
    results[4] = _mm_madd_epi16(left, right);
    const volatile uint8_t *mul_low = (const volatile uint8_t *)&results[0];
    const volatile uint8_t *mul_high_signed = (const volatile uint8_t *)&results[1];
    const volatile uint8_t *mul_high_unsigned = (const volatile uint8_t *)&results[2];
    const volatile uint8_t *mul_even = (const volatile uint8_t *)&results[3];
    const volatile uint8_t *multiply_add = (const volatile uint8_t *)&results[4];
    for (unsigned lane = 0; lane < 8; ++lane) {
        const uint16_t a = u16(input + lane * 2), b = u16(input + 16 + lane * 2);
        const int32_t signed_a = s16(a), signed_b = s16(b);
        const uint32_t product = (uint32_t)a * b;
        if (!matches(mul_low, lane * 2, product, 2) ||
            !matches(mul_high_signed, lane * 2, (uint32_t)(signed_a * signed_b) >> 16, 2) ||
            !matches(mul_high_unsigned, lane * 2, product >> 16, 2)) return 11;
    }
    for (unsigned lane = 0; lane < 2; ++lane) {
        const uint64_t product = (uint64_t)u32(input + lane * 8) * u32(input + 16 + lane * 8);
        if (!matches(mul_even, lane * 8, product, 8)) return 12;
    }
    for (unsigned lane = 0; lane < 4; ++lane) {
        const unsigned word = lane * 2;
        const int32_t a0 = s16(u16(input + word * 2)), a1 = s16(u16(input + (word + 1) * 2));
        const int32_t b0 = s16(u16(input + 16 + word * 2)), b1 = s16(u16(input + 16 + (word + 1) * 2));
        const uint32_t sum = (uint32_t)((int64_t)a0 * b0 + (int64_t)a1 * b1);
        if (!matches(multiply_add, lane * 4, sum, 4)) return 13;
    }
    const char result[] = "SSE2 packed multiply: ok\n";
    text(result, sizeof(result) - 1);
    return 0;
}
