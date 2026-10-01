#include <emmintrin.h>
#include <stdint.h>
#include "guest.h"

static uint16_t u16(const uint8_t *p) {
    return (uint16_t)p[0] | (uint16_t)p[1] << 8;
}

static uint32_t u32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static int64_t signed_value(uint64_t value, unsigned bits) {
    const uint64_t sign = UINT64_C(1) << (bits - 1);
    return value & sign ? (int64_t)value - (int64_t)(sign << 1) : (int64_t)value;
}

static int matches(const volatile uint8_t *actual, unsigned offset, uint64_t expected, unsigned size) {
    for (unsigned byte = 0; byte < size; ++byte) if (actual[offset + byte] != (uint8_t)(expected >> (byte * 8))) return 0;
    return 1;
}

long guest_main(long *sp) {
    (void)sp;
    uint8_t input[48];
    if (sys(NR_read, 0, (long)input, sizeof(input), 0, 0, 0) != sizeof(input)) return 10;
    const __m128i left = _mm_loadu_si128((const __m128i *)input);
    const __m128i right = _mm_loadu_si128((const __m128i *)(input + 16));
    volatile __m128i results[12];
    results[0] = _mm_packs_epi16(left, right);
    results[1] = _mm_packs_epi32(left, right);
    results[2] = _mm_packus_epi16(left, right);
    const volatile uint8_t *signed_bytes = (const volatile uint8_t *)&results[0];
    const volatile uint8_t *signed_words = (const volatile uint8_t *)&results[1];
    const volatile uint8_t *unsigned_bytes = (const volatile uint8_t *)&results[2];
    for (unsigned vector = 0; vector < 2; ++vector) {
        const uint8_t *source = input + vector * 16;
        for (unsigned lane = 0; lane < 8; ++lane) {
            const int64_t value = signed_value(u16(source + lane * 2), 16);
            const int64_t signed_result = value < -128 ? -128 : value > 127 ? 127 : value;
            const int64_t unsigned_result = value < 0 ? 0 : value > 255 ? 255 : value;
            if (!matches(signed_bytes, vector * 8 + lane, (uint8_t)signed_result, 1) ||
                !matches(unsigned_bytes, vector * 8 + lane, (uint8_t)unsigned_result, 1)) return 11;
        }
        for (unsigned lane = 0; lane < 4; ++lane) {
            const int64_t value = signed_value(u32(source + lane * 4), 32);
            const int64_t result = value < -32768 ? -32768 : value > 32767 ? 32767 : value;
            if (!matches(signed_words, (vector * 4 + lane) * 2, (uint16_t)result, 2)) return 12;
        }
    }
#define INSERT_RESULT(LANE) do { \
    __m128i inserted = left; \
    const uint32_t word = u16(input + 32 + (LANE) * 2); \
    __asm__ volatile("pinsrw $" #LANE ", %1, %0" : "+x"(inserted) : "r"(word)); \
    results[3 + (LANE)] = inserted; \
} while (0)
    INSERT_RESULT(0);
    INSERT_RESULT(1);
    INSERT_RESULT(2);
    INSERT_RESULT(3);
    INSERT_RESULT(4);
    INSERT_RESULT(5);
    INSERT_RESULT(6);
    INSERT_RESULT(7);
#undef INSERT_RESULT
    __m128i memory_insert = left;
    __asm__ volatile("pinsrw $4, %1, %0" : "+x"(memory_insert) : "m"(*(const uint16_t *)(input + 32)));
    results[11] = memory_insert;
    for (unsigned inserted_lane = 0; inserted_lane < 9; ++inserted_lane) {
        const unsigned lane = inserted_lane == 8 ? 4 : inserted_lane;
        const uint16_t inserted = inserted_lane == 8 ? u16(input + 32) : u16(input + 32 + inserted_lane * 2);
        const volatile uint8_t *actual = (const volatile uint8_t *)&results[3 + inserted_lane];
        for (unsigned original_lane = 0; original_lane < 8; ++original_lane) {
            const uint16_t expected = original_lane == lane ? inserted : u16(input + original_lane * 2);
            if (!matches(actual, original_lane * 2, expected, 2)) return 13;
        }
    }
    const char result[] = "SSE2 saturating pack and insert: ok\n";
    text(result, sizeof(result) - 1);
    return 0;
}
