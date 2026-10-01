#include <tmmintrin.h>
#include <stdint.h>
#include "guest.h"

long guest_main(long *sp) {
    (void)sp;
    uint8_t input[33] __attribute__((aligned(16)));
    if (sys(NR_read, 0, (long)input, sizeof(input), 0, 0, 0) != sizeof(input)) return 10;

    const __m128i data = _mm_loadu_si128((const __m128i *)input);
    const __m128i control = _mm_loadu_si128((const __m128i *)(input + 16));
    volatile __m128i result[2];
    __m128i register_source = data;
    __asm__ volatile("pshufb %1, %0" : "+x"(register_source) : "x"(control));
    result[0] = register_source;

    const uint8_t *memory_source = input + (input[32] ? 1 : 16);
    __m128i memory_operand = data;
    __asm__ volatile("pshufb %1, %0" : "+x"(memory_operand) : "m"(*(const __m128i *)memory_source));
    result[1] = memory_operand;

    for (unsigned form = 0; form < 2; ++form) {
        const volatile uint8_t *actual = (const volatile uint8_t *)&result[form];
        for (unsigned lane = 0; lane < 16; ++lane) {
            const uint8_t mask = input[16 + lane];
            const uint8_t expected = mask & 0x80 ? 0 : input[mask & 0x0f];
            if (actual[lane] != expected) return 11;
        }
    }

    const char message[] = "SSSE3 PSHUFB register and memory: ok\n";
    text(message, sizeof(message) - 1);
    return 0;
}
