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

long guest_main(long *sp) {
    (void)sp;
    uint8_t input[97] __attribute__((aligned(16)));
    if (sys(NR_read, 0, (long)input, sizeof(input), 0, 0, 0) != sizeof(input)) return 10;

    const __m128i data = _mm_loadu_si128((const __m128i *)input);
    const __m128i control = _mm_loadu_si128((const __m128i *)(input + 16));
    const __m128i sign_data = _mm_loadu_si128((const __m128i *)(input + 32));
    const __m128i byte_sign = _mm_loadu_si128((const __m128i *)(input + 48));
    const __m128i word_sign = _mm_loadu_si128((const __m128i *)(input + 64));
    volatile __m128i result[5];

    __m128i shuffled = data;
    __asm__ volatile("pshufb %1, %0" : "+x"(shuffled) : "x"(control));
    result[0] = shuffled;
    const uint8_t *shuffle_memory = input + (input[96] ? 1 : 16);
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

    const char message[] = "SSSE3 PSHUFB and PSIGN: ok\n";
    text(message, sizeof(message) - 1);
    return 0;
}
