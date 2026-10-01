#include <smmintrin.h>
#include <stdint.h>
#include "guest.h"

static uint32_t lane(const volatile uint8_t *bytes, unsigned size) {
    uint32_t value = 0;
    for (unsigned byte = 0; byte < size; ++byte) value |= (uint32_t)bytes[byte] << (byte * 8);
    return value;
}

static int64_t signed_dword(uint32_t value) {
    return value & UINT32_C(0x80000000) ? (int64_t)value - INT64_C(0x100000000) : value;
}

static int signed_byte(uint8_t value) {
    return value & 0x80 ? (int)value - 0x100 : value;
}

long guest_main(long *sp) {
    (void)sp;
    uint8_t input[32] __attribute__((aligned(16)));
    if (sys(NR_read, 0, (long)input, sizeof(input), 0, 0, 0) != sizeof(input)) return 10;

    const __m128i left = _mm_loadu_si128((const __m128i *)input);
    const __m128i right = _mm_loadu_si128((const __m128i *)(input + 16));
    volatile __m128i result[9];
    __m128i product = left;
    __asm__ volatile("pmulld %1, %0" : "+x"(product) : "x"(right));
    result[0] = product;
    __m128i minimum_signed = left;
    __asm__ volatile("pminsd %1, %0" : "+x"(minimum_signed) : "x"(right));
    result[1] = minimum_signed;
    __m128i maximum_signed = left;
    __asm__ volatile("pmaxsd %1, %0" : "+x"(maximum_signed) : "m"(*(const __m128i *)(input + 16)));
    result[2] = maximum_signed;
    __m128i minimum_unsigned = left;
    __asm__ volatile("pminuw %1, %0" : "+x"(minimum_unsigned) : "x"(right));
    result[3] = minimum_unsigned;
    __m128i maximum_unsigned = left;
    __asm__ volatile("pmaxuw %1, %0" : "+x"(maximum_unsigned) : "m"(*(const __m128i *)(input + 16)));
    result[4] = maximum_unsigned;
    __m128i minimum_signed_byte = left;
    __asm__ volatile("pminsb %1, %0" : "+x"(minimum_signed_byte) : "x"(right));
    result[5] = minimum_signed_byte;
    __m128i maximum_signed_byte = left;
    __asm__ volatile("pmaxsb %1, %0" : "+x"(maximum_signed_byte) : "m"(*(const __m128i *)(input + 16)));
    result[6] = maximum_signed_byte;
    __m128i minimum_unsigned_dword = left;
    __asm__ volatile("pminud %1, %0" : "+x"(minimum_unsigned_dword) : "x"(right));
    result[7] = minimum_unsigned_dword;
    __m128i maximum_unsigned_dword = left;
    __asm__ volatile("pmaxud %1, %0" : "+x"(maximum_unsigned_dword) : "m"(*(const __m128i *)(input + 16)));
    result[8] = maximum_unsigned_dword;

    const volatile uint8_t *actual_product = (const volatile uint8_t *)&result[0];
    const volatile uint8_t *actual_minimum_signed = (const volatile uint8_t *)&result[1];
    const volatile uint8_t *actual_maximum_signed = (const volatile uint8_t *)&result[2];
    const volatile uint8_t *actual_minimum_unsigned_dword = (const volatile uint8_t *)&result[7];
    const volatile uint8_t *actual_maximum_unsigned_dword = (const volatile uint8_t *)&result[8];
    for (unsigned word = 0; word < 4; ++word) {
        const unsigned offset = word * 4;
        const uint32_t a = lane(input + offset, 4);
        const uint32_t b = lane(input + 16 + offset, 4);
        if (lane(actual_product + offset, 4) != (uint32_t)((uint64_t)a * b) ||
            lane(actual_minimum_signed + offset, 4) != (uint32_t)(signed_dword(a) < signed_dword(b) ? signed_dword(a) : signed_dword(b)) ||
            lane(actual_maximum_signed + offset, 4) != (uint32_t)(signed_dword(a) > signed_dword(b) ? signed_dword(a) : signed_dword(b)) ||
            lane(actual_minimum_unsigned_dword + offset, 4) != (a < b ? a : b) ||
            lane(actual_maximum_unsigned_dword + offset, 4) != (a > b ? a : b)) return 11;
    }
    const volatile uint8_t *actual_minimum_unsigned = (const volatile uint8_t *)&result[3];
    const volatile uint8_t *actual_maximum_unsigned = (const volatile uint8_t *)&result[4];
    const volatile uint8_t *actual_minimum_signed_byte = (const volatile uint8_t *)&result[5];
    const volatile uint8_t *actual_maximum_signed_byte = (const volatile uint8_t *)&result[6];
    for (unsigned word = 0; word < 8; ++word) {
        const unsigned offset = word * 2;
        const uint16_t a = (uint16_t)lane(input + offset, 2);
        const uint16_t b = (uint16_t)lane(input + 16 + offset, 2);
        if (lane(actual_minimum_unsigned + offset, 2) != (a < b ? a : b) ||
            lane(actual_maximum_unsigned + offset, 2) != (a > b ? a : b)) return 12;
    }
    for (unsigned byte = 0; byte < 16; ++byte) {
        const int a = signed_byte(input[byte]);
        const int b = signed_byte(input[16 + byte]);
        if (actual_minimum_signed_byte[byte] != (uint8_t)(a < b ? a : b) ||
            actual_maximum_signed_byte[byte] != (uint8_t)(a > b ? a : b)) return 13;
    }

    const char message[] = "SSE4.1 integer lanes: ok\n";
    text(message, sizeof(message) - 1);
    return 0;
}
