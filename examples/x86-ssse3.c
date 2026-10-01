#include <tmmintrin.h>
#include <stdint.h>
#include "guest.h"

static uint32_t lane(const volatile uint8_t *bytes, unsigned size) {
    uint32_t value = 0;
    for (unsigned byte = 0; byte < size; ++byte) value |= (uint32_t)bytes[byte] << (byte * 8);
    return value;
}

static int matches_sign(const volatile uint8_t *actual, const uint8_t *data, const uint8_t *control, unsigned size) {
    const uint32_t sign_bit = UINT32_C(1) << (size * 8 - 1);
    const uint32_t mask = size == 4 ? UINT32_MAX : (UINT32_C(1) << (size * 8)) - 1;
    for (unsigned offset = 0; offset < 16; offset += size) {
        const uint32_t source = lane(data + offset, size);
        const uint32_t sign = lane(control + offset, size);
        const uint32_t expected = sign == 0 ? 0 : sign & sign_bit ? (0u - source) & mask : source;
        if (lane(actual + offset, size) != expected) return 0;
    }
    return 1;
}

static int matches_abs(const volatile uint8_t *actual, const uint8_t *source, unsigned size) {
    const uint32_t sign_bit = UINT32_C(1) << (size * 8 - 1);
    const uint32_t mask = size == 4 ? UINT32_MAX : (UINT32_C(1) << (size * 8)) - 1;
    for (unsigned offset = 0; offset < 16; offset += size) {
        const uint32_t value = lane(source + offset, size);
        const uint32_t expected = value & sign_bit ? (0u - value) & mask : value;
        if (lane(actual + offset, size) != expected) return 0;
    }
    return 1;
}

static int signed_byte(uint8_t value) {
    return value & 0x80 ? (int)value - 256 : value;
}

static int matches_maddubsw(const volatile uint8_t *actual, const uint8_t *data, const uint8_t *control) {
    for (unsigned lane_index = 0; lane_index < 8; ++lane_index) {
        const unsigned offset = lane_index * 2;
        const int sum = (int)data[offset] * signed_byte(control[offset]) + (int)data[offset + 1] * signed_byte(control[offset + 1]);
        const int16_t saturated = sum < -32768 ? -32768 : sum > 32767 ? 32767 : (int16_t)sum;
        if (lane(actual + offset, 2) != (uint16_t)saturated) return 0;
    }
    return 1;
}

static int32_t signed_word(uint16_t value) {
    return value & 0x8000 ? (int32_t)value - 65536 : value;
}

static int matches_horizontal(const volatile uint8_t *actual, const uint8_t *dest, const uint8_t *src, unsigned size, int subtract, int saturate) {
    const uint8_t *halves[2] = { dest, src };
    const uint32_t mask = size == 4 ? UINT32_MAX : (UINT32_C(1) << (size * 8)) - 1;
    for (unsigned half = 0; half < 2; ++half) {
        for (unsigned pair = 0; pair < 8 / size; ++pair) {
            const unsigned offset = pair * size * 2;
            const uint32_t left = lane(halves[half] + offset, size);
            const uint32_t right = lane(halves[half] + offset + size, size);
            uint32_t expected;
            if (saturate) {
                const int32_t a = signed_word((uint16_t)left);
                const int32_t b = signed_word((uint16_t)right);
                const int32_t value = subtract ? a - b : a + b;
                expected = (uint16_t)(value < -32768 ? -32768 : value > 32767 ? 32767 : value);
            } else {
                expected = (subtract ? left - right : left + right) & mask;
            }
            if (lane(actual + half * 8 + pair * size, size) != expected) return 0;
        }
    }
    return 1;
}

static int32_t floor_shift_15(int64_t value) {
    return value >= 0 ? (int32_t)(value / 32768) : -(int32_t)((-value + 32767) / 32768);
}

static int matches_mulhrs(const volatile uint8_t *actual, const uint8_t *left, const uint8_t *right) {
    for (unsigned offset = 0; offset < 16; offset += 2) {
        const int64_t a = signed_word((uint16_t)lane(left + offset, 2));
        const int64_t b = signed_word((uint16_t)lane(right + offset, 2));
        const uint16_t expected = (uint16_t)floor_shift_15(a * b + 0x4000);
        if (lane(actual + offset, 2) != expected) return 0;
    }
    return 1;
}

long guest_main(long *sp) {
    (void)sp;
    uint8_t input[129] __attribute__((aligned(16)));
    if (sys(NR_read, 0, (long)input, sizeof(input), 0, 0, 0) != sizeof(input)) return 10;

    const __m128i data = _mm_loadu_si128((const __m128i *)input);
    const __m128i control = _mm_loadu_si128((const __m128i *)(input + 16));
    const __m128i sign_data = _mm_loadu_si128((const __m128i *)(input + 32));
    const __m128i byte_sign = _mm_loadu_si128((const __m128i *)(input + 48));
    const __m128i word_sign = _mm_loadu_si128((const __m128i *)(input + 64));
    const __m128i madd_data = _mm_loadu_si128((const __m128i *)(input + 96));
    const __m128i madd_control = _mm_loadu_si128((const __m128i *)(input + 112));
    volatile __m128i result[18];

    __m128i shuffled = data;
    __asm__ volatile("pshufb %1, %0" : "+x"(shuffled) : "x"(control));
    result[0] = shuffled;
    const uint8_t *shuffle_memory = input + (input[128] ? 1 : 16);
    __m128i shuffled_memory = data;
    __asm__ volatile("pshufb %1, %0" : "+x"(shuffled_memory) : "m"(*(const __m128i *)shuffle_memory));
    result[1] = shuffled_memory;

    __m128i signed_bytes = sign_data;
    __asm__ volatile("psignb %1, %0" : "+x"(signed_bytes) : "x"(byte_sign));
    result[2] = signed_bytes;
    __m128i signed_words = sign_data;
    __asm__ volatile("psignw %1, %0" : "+x"(signed_words) : "x"(word_sign));
    result[3] = signed_words;
    __m128i signed_dwords = sign_data;
    __asm__ volatile("psignd %1, %0" : "+x"(signed_dwords) : "m"(*(const __m128i *)(input + 80)));
    result[4] = signed_dwords;

    __m128i absolute_bytes = sign_data;
    __asm__ volatile("pabsb %1, %0" : "+x"(absolute_bytes) : "x"(sign_data));
    result[5] = absolute_bytes;
    __m128i absolute_words = sign_data;
    __asm__ volatile("pabsw %1, %0" : "+x"(absolute_words) : "x"(sign_data));
    result[6] = absolute_words;
    __m128i absolute_dwords = sign_data;
    __asm__ volatile("pabsd %1, %0" : "+x"(absolute_dwords) : "m"(*(const __m128i *)(input + 32)));
    result[7] = absolute_dwords;

    __m128i pair_sum_register = madd_data;
    __asm__ volatile("pmaddubsw %1, %0" : "+x"(pair_sum_register) : "x"(madd_control));
    result[8] = pair_sum_register;
    __m128i pair_sum_memory = madd_data;
    __asm__ volatile("pmaddubsw %1, %0" : "+x"(pair_sum_memory) : "m"(*(const __m128i *)(input + 112)));
    result[9] = pair_sum_memory;

    __m128i rounded_register = sign_data;
    __asm__ volatile("pmulhrsw %1, %0" : "+x"(rounded_register) : "x"(word_sign));
    result[10] = rounded_register;
    __m128i rounded_memory = sign_data;
    __asm__ volatile("pmulhrsw %1, %0" : "+x"(rounded_memory) : "m"(*(const __m128i *)(input + 64)));
    result[11] = rounded_memory;

    __m128i horizontal_add_words = sign_data;
    __asm__ volatile("phaddw %1, %0" : "+x"(horizontal_add_words) : "x"(word_sign));
    result[12] = horizontal_add_words;
    __m128i horizontal_add_dwords = sign_data;
    __asm__ volatile("phaddd %1, %0" : "+x"(horizontal_add_dwords) : "x"(word_sign));
    result[13] = horizontal_add_dwords;
    __m128i horizontal_add_sat = sign_data;
    __asm__ volatile("phaddsw %1, %0" : "+x"(horizontal_add_sat) : "m"(*(const __m128i *)(input + 64)));
    result[14] = horizontal_add_sat;
    __m128i horizontal_sub_words = sign_data;
    __asm__ volatile("phsubw %1, %0" : "+x"(horizontal_sub_words) : "x"(word_sign));
    result[15] = horizontal_sub_words;
    __m128i horizontal_sub_dwords = sign_data;
    __asm__ volatile("phsubd %1, %0" : "+x"(horizontal_sub_dwords) : "x"(word_sign));
    result[16] = horizontal_sub_dwords;
    __m128i horizontal_sub_sat = sign_data;
    __asm__ volatile("phsubsw %1, %0" : "+x"(horizontal_sub_sat) : "m"(*(const __m128i *)(input + 64)));
    result[17] = horizontal_sub_sat;

    const volatile uint8_t *shuffled_result = (const volatile uint8_t *)&result[0];
    const volatile uint8_t *shuffled_memory_result = (const volatile uint8_t *)&result[1];
    for (unsigned lane_index = 0; lane_index < 16; ++lane_index) {
        const uint8_t mask = input[16 + lane_index];
        const uint8_t expected = mask & 0x80 ? 0 : input[mask & 0x0f];
        if (shuffled_result[lane_index] != expected || shuffled_memory_result[lane_index] != expected) return 11;
    }
    if (!matches_sign((const volatile uint8_t *)&result[2], input + 32, input + 48, 1) ||
        !matches_sign((const volatile uint8_t *)&result[3], input + 32, input + 64, 2) ||
        !matches_sign((const volatile uint8_t *)&result[4], input + 32, input + 80, 4)) return 12;
    if (!matches_abs((const volatile uint8_t *)&result[5], input + 32, 1) ||
        !matches_abs((const volatile uint8_t *)&result[6], input + 32, 2) ||
        !matches_abs((const volatile uint8_t *)&result[7], input + 32, 4)) return 13;
    if (!matches_maddubsw((const volatile uint8_t *)&result[8], input + 96, input + 112) ||
        !matches_maddubsw((const volatile uint8_t *)&result[9], input + 96, input + 112)) return 14;
    if (!matches_mulhrs((const volatile uint8_t *)&result[10], input + 32, input + 64) ||
        !matches_mulhrs((const volatile uint8_t *)&result[11], input + 32, input + 64)) return 15;
    if (!matches_horizontal((const volatile uint8_t *)&result[12], input + 32, input + 64, 2, 0, 0) ||
        !matches_horizontal((const volatile uint8_t *)&result[13], input + 32, input + 64, 4, 0, 0) ||
        !matches_horizontal((const volatile uint8_t *)&result[14], input + 32, input + 64, 2, 0, 1) ||
        !matches_horizontal((const volatile uint8_t *)&result[15], input + 32, input + 64, 2, 1, 0) ||
        !matches_horizontal((const volatile uint8_t *)&result[16], input + 32, input + 64, 4, 1, 0) ||
        !matches_horizontal((const volatile uint8_t *)&result[17], input + 32, input + 64, 2, 1, 1)) return 16;

    const char message[] = "SSSE3 shuffle, sign, abs, multiply and horizontal arithmetic: ok\n";
    text(message, sizeof(message) - 1);
    return 0;
}
