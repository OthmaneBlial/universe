#include <emmintrin.h>
#include <stdint.h>
#include "guest.h"

long guest_main(long *sp) {
    (void)sp;
    uint8_t input[80];
    if (sys(NR_read, 0, (long)input, sizeof(input), 0, 0, 0) != sizeof(input)) return 10;
    const __m128i lhs = _mm_loadu_si128((const __m128i *)input);
    const __m128i zero = _mm_setzero_si128();
    const __m128i all = _mm_cmpeq_epi32(zero, zero);
    volatile __m128i results[8];
    for (unsigned n = 0, offset = 16, width = 1; width <= 8; ++n, width *= 2, offset += 16) {
        const __m128i rhs = _mm_loadu_si128((const __m128i *)(input + offset));
        const __m128i sum = n == 0 ? _mm_add_epi8(lhs, rhs) : n == 1 ? _mm_add_epi16(lhs, rhs) : n == 2 ? _mm_add_epi32(lhs, rhs) : _mm_add_epi64(lhs, rhs);
        const __m128i difference = n == 0 ? _mm_sub_epi8(zero, rhs) : n == 1 ? _mm_sub_epi16(zero, rhs) : n == 2 ? _mm_sub_epi32(zero, rhs) : _mm_sub_epi64(zero, rhs);
        results[2 * n] = sum;
        results[2 * n + 1] = difference;
        if (_mm_movemask_epi8(_mm_cmpeq_epi8(results[2 * n], zero)) != 0xffff) return 11 + n;
        if (_mm_movemask_epi8(_mm_cmpeq_epi8(results[2 * n + 1], all)) != 0xffff) return 15 + n;
    }
    const char result[] = "SSE2 packed add/sub: ok\n";
    text(result, sizeof(result) - 1);
    return 0;
}
