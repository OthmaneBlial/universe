#include <emmintrin.h>
#include <stdint.h>
#include "guest.h"

long guest_main(long *sp) {
    (void)sp;
    uint8_t input[240];
    if (sys(NR_read, 0, (long)input, sizeof(input), 0, 0, 0) != sizeof(input)) return 10;
    const __m128i lhs = _mm_loadu_si128((const __m128i *)input);
    const __m128i zero = _mm_setzero_si128();
    const __m128i all = _mm_cmpeq_epi32(zero, zero);
    volatile __m128i results[26];
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
    const __m128i unpack_left = _mm_loadu_si128((const __m128i *)(input + 176));
    const __m128i unpack_right = _mm_loadu_si128((const __m128i *)(input + 192));
    for (unsigned n = 0, width = 1; n < 4; ++n, width *= 2) {
        const __m128i unpacked = n == 0 ? _mm_unpackhi_epi8(unpack_left, unpack_right) : n == 1 ? _mm_unpackhi_epi16(unpack_left, unpack_right) : n == 2 ? _mm_unpackhi_epi32(unpack_left, unpack_right) : _mm_unpackhi_epi64(unpack_left, unpack_right);
        results[19 + n] = unpacked;
        const volatile uint8_t *actual = (const volatile uint8_t *)&results[19 + n];
        for (unsigned lane = 0; lane < 8 / width; ++lane) for (unsigned byte = 0; byte < width; ++byte) {
            const unsigned source = 8 + lane * width + byte;
            if (actual[(2 * lane) * width + byte] != input[176 + source] || actual[(2 * lane + 1) * width + byte] != input[192 + source]) return 24 + n;
        }
    }
    const __m128i average_left = _mm_loadu_si128((const __m128i *)(input + 208));
    const __m128i average_right = _mm_loadu_si128((const __m128i *)(input + 224));
    results[23] = _mm_avg_epu8(average_left, average_right);
    results[24] = _mm_avg_epu16(average_left, average_right);
    results[25] = _mm_sad_epu8(average_left, average_right);
    const volatile uint8_t *average_bytes = (const volatile uint8_t *)&results[23];
    const volatile uint8_t *average_words = (const volatile uint8_t *)&results[24];
    const volatile uint8_t *absolute_sums = (const volatile uint8_t *)&results[25];
    for (unsigned lane = 0; lane < 16; ++lane) {
        const unsigned a = input[208 + lane], b = input[224 + lane];
        if (average_bytes[lane] != (a + b + 1) / 2) return 28;
    }
    for (unsigned lane = 0; lane < 8; ++lane) {
        const unsigned a = input[208 + lane * 2] | (unsigned)input[209 + lane * 2] << 8;
        const unsigned b = input[224 + lane * 2] | (unsigned)input[225 + lane * 2] << 8;
        if (((unsigned)average_words[lane * 2] | (unsigned)average_words[lane * 2 + 1] << 8) != (a + b + 1) / 2) return 29;
    }
    for (unsigned group = 0; group < 2; ++group) {
        unsigned sum = 0;
        for (unsigned lane = 0; lane < 8; ++lane) {
            const unsigned a = input[208 + group * 8 + lane], b = input[224 + group * 8 + lane];
            sum += a > b ? a - b : b - a;
        }
        if (((unsigned)absolute_sums[group * 8] | (unsigned)absolute_sums[group * 8 + 1] << 8) != sum) return 30;
        for (unsigned byte = 2; byte < 8; ++byte) if (absolute_sums[group * 8 + byte] != 0) return 31;
    }
    const char result[] = "SSE2 arithmetic, unpack, average and SAD: ok\n";
    text(result, sizeof(result) - 1);
    return 0;
}
