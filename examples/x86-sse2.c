#include <emmintrin.h>
#include <stdint.h>
#include "guest.h"

long guest_main(long *sp) {
    (void)sp;
    uint8_t input[176];
    if (sys(NR_read, 0, (long)input, sizeof(input), 0, 0, 0) != sizeof(input)) return 10;
    const __m128i lhs = _mm_loadu_si128((const __m128i *)input);
    const __m128i zero = _mm_setzero_si128();
    const __m128i all = _mm_cmpeq_epi32(zero, zero);
    volatile __m128i results[19];
    for (unsigned n = 0, offset = 16, width = 1; width <= 8; ++n, width *= 2, offset += 16) {
        const __m128i rhs = _mm_loadu_si128((const __m128i *)(input + offset));
        const __m128i sum = n == 0 ? _mm_add_epi8(lhs, rhs) : n == 1 ? _mm_add_epi16(lhs, rhs) : n == 2 ? _mm_add_epi32(lhs, rhs) : _mm_add_epi64(lhs, rhs);
        const __m128i difference = n == 0 ? _mm_sub_epi8(zero, rhs) : n == 1 ? _mm_sub_epi16(zero, rhs) : n == 2 ? _mm_sub_epi32(zero, rhs) : _mm_sub_epi64(zero, rhs);
        results[2 * n] = sum;
        results[2 * n + 1] = difference;
        if (_mm_movemask_epi8(_mm_cmpeq_epi8(results[2 * n], zero)) != 0xffff) return 11 + n;
        if (_mm_movemask_epi8(_mm_cmpeq_epi8(results[2 * n + 1], all)) != 0xffff) return 15 + n;
    }
    const __m128i compare_left = _mm_loadu_si128((const __m128i *)(input + 80));
    const __m128i compare_right = _mm_loadu_si128((const __m128i *)(input + 96));
    for (unsigned n = 0, width = 1; n < 3; ++n, width *= 2) {
        const __m128i greater = n == 0 ? _mm_cmpgt_epi8(compare_left, compare_right) : n == 1 ? _mm_cmpgt_epi16(compare_left, compare_right) : _mm_cmpgt_epi32(compare_left, compare_right);
        results[8 + n] = greater;
        const volatile uint8_t *actual = (const volatile uint8_t *)&results[8 + n];
        const unsigned bits = width * 8;
        const uint64_t sign = UINT64_C(1) << (bits - 1);
        for (unsigned lane = 0; lane < 16 / width; ++lane) {
            uint64_t left = 0, right = 0;
            for (unsigned byte = 0; byte < width; ++byte) {
                left |= (uint64_t)input[80 + lane * width + byte] << (byte * 8);
                right |= (uint64_t)input[96 + lane * width + byte] << (byte * 8);
            }
            const uint8_t expected = (left ^ sign) > (right ^ sign) ? 0xff : 0;
            for (unsigned byte = 0; byte < width; ++byte) if (actual[lane * width + byte] != expected) return 19 + n;
        }
    }
    for (unsigned n = 0, width = 1; n < 2; ++n, width *= 2) {
        const unsigned offset = n == 0 ? 112 : 144;
        const __m128i saturate_left = _mm_loadu_si128((const __m128i *)(input + offset));
        const __m128i saturate_right = _mm_loadu_si128((const __m128i *)(input + offset + 16));
        const __m128i signed_add = n == 0 ? _mm_adds_epi8(saturate_left, saturate_right) : _mm_adds_epi16(saturate_left, saturate_right);
        const __m128i unsigned_add = n == 0 ? _mm_adds_epu8(saturate_left, saturate_right) : _mm_adds_epu16(saturate_left, saturate_right);
        const __m128i signed_sub = n == 0 ? _mm_subs_epi8(saturate_left, saturate_right) : _mm_subs_epi16(saturate_left, saturate_right);
        const __m128i unsigned_sub = n == 0 ? _mm_subs_epu8(saturate_left, saturate_right) : _mm_subs_epu16(saturate_left, saturate_right);
        results[11 + n * 4] = signed_add;
        results[12 + n * 4] = unsigned_add;
        results[13 + n * 4] = signed_sub;
        results[14 + n * 4] = unsigned_sub;
        const unsigned bits = width * 8;
        const uint64_t sign = UINT64_C(1) << (bits - 1), mask = (sign << 1) - 1;
        for (unsigned lane = 0; lane < 16 / width; ++lane) {
            uint64_t left = 0, right = 0;
            for (unsigned byte = 0; byte < width; ++byte) {
                left |= (uint64_t)input[offset + lane * width + byte] << (byte * 8);
                right |= (uint64_t)input[offset + 16 + lane * width + byte] << (byte * 8);
            }
            const int64_t signed_left = (left & sign) ? (int64_t)left - (int64_t)(mask + 1) : (int64_t)left;
            const int64_t signed_right = (right & sign) ? (int64_t)right - (int64_t)(mask + 1) : (int64_t)right;
            int64_t expected_signed_add = signed_left + signed_right;
            int64_t expected_signed_sub = signed_left - signed_right;
            if (expected_signed_add > (int64_t)sign - 1) expected_signed_add = (int64_t)sign - 1;
            if (expected_signed_add < -(int64_t)sign) expected_signed_add = -(int64_t)sign;
            if (expected_signed_sub > (int64_t)sign - 1) expected_signed_sub = (int64_t)sign - 1;
            if (expected_signed_sub < -(int64_t)sign) expected_signed_sub = -(int64_t)sign;
            const uint64_t expected[4] = {
                (uint64_t)expected_signed_add & mask,
                left + right > mask ? mask : left + right,
                (uint64_t)expected_signed_sub & mask,
                left < right ? 0 : left - right,
            };
            for (unsigned op = 0; op < 4; ++op) {
                const volatile uint8_t *actual = (const volatile uint8_t *)&results[11 + n * 4 + op];
                for (unsigned byte = 0; byte < width; ++byte) if (actual[lane * width + byte] != (uint8_t)(expected[op] >> (byte * 8))) return 22 + n;
            }
        }
    }
    const char result[] = "SSE2 packed arithmetic: ok\n";
    text(result, sizeof(result) - 1);
    return 0;
}
