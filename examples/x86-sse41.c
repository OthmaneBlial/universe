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

static uint64_t lane64(const volatile uint8_t *bytes, unsigned size) {
    uint64_t value = 0;
    for (unsigned byte = 0; byte < size; ++byte) value |= (uint64_t)bytes[byte] << (byte * 8);
    return value;
}

static int check_extend(const volatile uint8_t *actual, const uint8_t *source, unsigned destination_size, unsigned source_size, int sign) {
    const unsigned source_bits = source_size * 8;
    for (unsigned lane_index = 0; lane_index < 16 / destination_size; ++lane_index) {
        const uint64_t raw = lane(source + lane_index * source_size, source_size);
        int64_t expected = (int64_t)raw;
        if (sign && (raw & (UINT64_C(1) << (source_bits - 1)))) expected -= (int64_t)(UINT64_C(1) << source_bits);
        const uint64_t mask = destination_size == 8 ? UINT64_MAX : (UINT64_C(1) << (destination_size * 8)) - 1;
        if (lane64(actual + lane_index * destination_size, destination_size) != ((uint64_t)expected & mask)) return 0;
    }
    return 1;
}

static uint16_t clamp_unsigned_word(int64_t value) {
    if (value < 0) return 0;
    if (value > UINT16_MAX) return UINT16_MAX;
    return (uint16_t)value;
}

long guest_main(long *sp) {
    (void)sp;
    uint8_t input[32] __attribute__((aligned(16)));
    if (sys(NR_read, 0, (long)input, sizeof(input), 0, 0, 0) != sizeof(input)) return 10;

    const __m128i left = _mm_loadu_si128((const __m128i *)input);
    const __m128i right = _mm_loadu_si128((const __m128i *)(input + 16));
    const uint8_t *unaligned_vector = input + 1;
    uint8_t ptest_carry, ptest_zero;
    __asm__ volatile("ptest %3, %2\n\tsetc %0\n\tsetz %1"
        : "=q"(ptest_carry), "=q"(ptest_zero)
        : "x"(left), "m"(*(const __m128i *)unaligned_vector)
        : "cc");
    volatile __m128i result[33];
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
    __m128i equal_qword = left;
    __asm__ volatile("pcmpeqq %1, %0" : "+x"(equal_qword) : "m"(*(const __m128i *)(input + 16)));
    result[9] = equal_qword;
    const uint8_t *unaligned = input + 17;
    __m128i signed_bw; __asm__ volatile("pmovsxbw %1, %0" : "=x"(signed_bw) : "x"(left)); result[10] = signed_bw;
    __m128i signed_bd; __asm__ volatile("pmovsxbd %1, %0" : "=x"(signed_bd) : "x"(left)); result[11] = signed_bd;
    __m128i signed_bq; __asm__ volatile("pmovsxbq %1, %0" : "=x"(signed_bq) : "x"(left)); result[12] = signed_bq;
    __m128i signed_wd; __asm__ volatile("pmovsxwd %1, %0" : "=x"(signed_wd) : "x"(left)); result[13] = signed_wd;
    __m128i signed_wq; __asm__ volatile("pmovsxwq %1, %0" : "=x"(signed_wq) : "x"(left)); result[14] = signed_wq;
    __m128i signed_dq; __asm__ volatile("pmovsxdq %1, %0" : "=x"(signed_dq) : "x"(left)); result[15] = signed_dq;
    __m128i unsigned_bw; __asm__ volatile("pmovzxbw %1, %0" : "=x"(unsigned_bw) : "m"(*(const __m128i *)unaligned)); result[16] = unsigned_bw;
    __m128i unsigned_bd; __asm__ volatile("pmovzxbd %1, %0" : "=x"(unsigned_bd) : "m"(*(const __m128i *)unaligned)); result[17] = unsigned_bd;
    __m128i unsigned_bq; __asm__ volatile("pmovzxbq %1, %0" : "=x"(unsigned_bq) : "m"(*(const __m128i *)unaligned)); result[18] = unsigned_bq;
    __m128i unsigned_wd; __asm__ volatile("pmovzxwd %1, %0" : "=x"(unsigned_wd) : "m"(*(const __m128i *)unaligned)); result[19] = unsigned_wd;
    __m128i unsigned_wq; __asm__ volatile("pmovzxwq %1, %0" : "=x"(unsigned_wq) : "m"(*(const __m128i *)unaligned)); result[20] = unsigned_wq;
    __m128i unsigned_dq; __asm__ volatile("pmovzxdq %1, %0" : "=x"(unsigned_dq) : "m"(*(const __m128i *)unaligned)); result[21] = unsigned_dq;
    __m128i signed_even = left; __asm__ volatile("pmuldq %1, %0" : "+x"(signed_even) : "m"(*(const __m128i *)unaligned_vector)); result[22] = signed_even;
    __m128i packed_unsigned = left; __asm__ volatile("packusdw %1, %0" : "+x"(packed_unsigned) : "m"(*(const __m128i *)unaligned_vector)); result[23] = packed_unsigned;
    __m128i min_position; __asm__ volatile("phminposuw %1, %0" : "=x"(min_position) : "m"(*(const __m128i *)unaligned_vector)); result[24] = min_position;
    __m128i blended = left; __asm__ volatile("pblendw $0xa5, %1, %0" : "+x"(blended) : "m"(*(const __m128i *)unaligned_vector)); result[25] = blended;
    __m128i blended_ps = left; __asm__ volatile("blendps $0x5, %1, %0" : "+x"(blended_ps) : "x"(right)); result[26] = blended_ps;
    __m128i blended_pd = left; __asm__ volatile("blendpd $0x2, %1, %0" : "+x"(blended_pd) : "m"(*(const __m128i *)unaligned_vector)); result[27] = blended_pd;
    const uint32_t insert_byte_value = 0x1a5;
    __m128i inserted_byte = left; __asm__ volatile("pinsrb $7, %1, %0" : "+x"(inserted_byte) : "r"(insert_byte_value)); result[28] = inserted_byte;
    __m128i inserted_dword = left; __asm__ volatile("pinsrd $1, %1, %0" : "+x"(inserted_dword) : "m"(*(const uint32_t *)(input + 1))); result[29] = inserted_dword;
    const uint64_t insert_qword_value = UINT64_C(0x0123456789abcdef);
    __m128i inserted_qword = left; __asm__ volatile("pinsrq $0, %1, %0" : "+x"(inserted_qword) : "r"(insert_qword_value)); result[30] = inserted_qword;
    __m128i sad_register = left; __asm__ volatile("mpsadbw $0x02, %1, %0" : "+x"(sad_register) : "x"(right)); result[31] = sad_register;
    __m128i sad_memory = left; __asm__ volatile("mpsadbw $0x85, %1, %0" : "+x"(sad_memory) : "m"(*(const __m128i *)unaligned_vector)); result[32] = sad_memory;
    volatile uint64_t extracted_byte, extracted_dword, extracted_qword, preserved_qword;
    volatile uint8_t extracted_memory_byte;
    volatile uint16_t extracted_memory_word;
    __asm__ volatile("pextrq $1, %1, %0" : "=r"(preserved_qword) : "x"(inserted_qword));
    __asm__ volatile("pextrb $14, %1, %k0" : "=r"(extracted_byte) : "x"(right));
    __asm__ volatile("pextrb $15, %1, %0" : "=m"(extracted_memory_byte) : "x"(right));
    __asm__ volatile("pextrw $6, %1, %0" : "=m"(extracted_memory_word) : "x"(left));
    __asm__ volatile("pextrd $2, %1, %k0" : "=r"(extracted_dword) : "x"(left));
    __asm__ volatile("pextrq $1, %1, %0" : "=r"(extracted_qword) : "x"(right));

    const volatile uint8_t *actual_product = (const volatile uint8_t *)&result[0];
    const volatile uint8_t *actual_minimum_signed = (const volatile uint8_t *)&result[1];
    const volatile uint8_t *actual_maximum_signed = (const volatile uint8_t *)&result[2];
    const volatile uint8_t *actual_minimum_unsigned_dword = (const volatile uint8_t *)&result[7];
    const volatile uint8_t *actual_maximum_unsigned_dword = (const volatile uint8_t *)&result[8];
    const volatile uint8_t *actual_equal_qword = (const volatile uint8_t *)&result[9];
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
    for (unsigned qword = 0; qword < 2; ++qword) {
        const unsigned offset = qword * 8;
        const uint64_t a = lane(input + offset, 4) | ((uint64_t)lane(input + offset + 4, 4) << 32);
        const uint64_t b = lane(input + 16 + offset, 4) | ((uint64_t)lane(input + 20 + offset, 4) << 32);
        const uint32_t expected = a == b ? UINT32_MAX : 0;
        if (lane(actual_equal_qword + offset, 4) != expected ||
            lane(actual_equal_qword + offset + 4, 4) != expected) return 14;
    }
    if (!check_extend((const volatile uint8_t *)&result[10], input, 2, 1, 1) ||
        !check_extend((const volatile uint8_t *)&result[11], input, 4, 1, 1) ||
        !check_extend((const volatile uint8_t *)&result[12], input, 8, 1, 1) ||
        !check_extend((const volatile uint8_t *)&result[13], input, 4, 2, 1) ||
        !check_extend((const volatile uint8_t *)&result[14], input, 8, 2, 1) ||
        !check_extend((const volatile uint8_t *)&result[15], input, 8, 4, 1) ||
        !check_extend((const volatile uint8_t *)&result[16], unaligned, 2, 1, 0) ||
        !check_extend((const volatile uint8_t *)&result[17], unaligned, 4, 1, 0) ||
        !check_extend((const volatile uint8_t *)&result[18], unaligned, 8, 1, 0) ||
        !check_extend((const volatile uint8_t *)&result[19], unaligned, 4, 2, 0) ||
        !check_extend((const volatile uint8_t *)&result[20], unaligned, 8, 2, 0) ||
        !check_extend((const volatile uint8_t *)&result[21], unaligned, 8, 4, 0)) return 15;

    const volatile uint8_t *actual_signed_even = (const volatile uint8_t *)&result[22];
    for (unsigned lane_index = 0; lane_index < 2; ++lane_index) {
        const int64_t a = signed_dword(lane(input + lane_index * 8, 4));
        const int64_t b = signed_dword(lane(unaligned_vector + lane_index * 8, 4));
        if (lane64(actual_signed_even + lane_index * 8, 8) != (uint64_t)(a * b)) return 16;
    }
    const volatile uint8_t *actual_packed_unsigned = (const volatile uint8_t *)&result[23];
    for (unsigned vector = 0; vector < 2; ++vector) {
        const uint8_t *source = vector == 0 ? input : unaligned_vector;
        for (unsigned lane_index = 0; lane_index < 4; ++lane_index) {
            const int64_t value = signed_dword(lane(source + lane_index * 4, 4));
            if (lane(actual_packed_unsigned + (vector * 4 + lane_index) * 2, 2) != clamp_unsigned_word(value)) return 17;
        }
    }
    const volatile uint8_t *actual_min_position = (const volatile uint8_t *)&result[24];
    uint16_t minimum = UINT16_MAX;
    uint16_t position = 0;
    for (unsigned lane_index = 0; lane_index < 8; ++lane_index) {
        const uint16_t candidate = (uint16_t)lane(unaligned_vector + lane_index * 2, 2);
        if (candidate < minimum) { minimum = candidate; position = (uint16_t)lane_index; }
    }
    if (lane(actual_min_position, 2) != minimum || lane(actual_min_position + 2, 2) != position) return 18;
    for (unsigned byte = 4; byte < 16; ++byte) if (actual_min_position[byte] != 0) return 19;
    int expected_carry = 1, expected_zero = 1;
    for (unsigned byte = 0; byte < 16; ++byte) {
        expected_carry &= (unaligned_vector[byte] & (uint8_t)~input[byte]) == 0;
        expected_zero &= (unaligned_vector[byte] & input[byte]) == 0;
    }
    if (ptest_carry != expected_carry || ptest_zero != expected_zero) return 20;
    const volatile uint8_t *actual_blended = (const volatile uint8_t *)&result[25];
    for (unsigned lane_index = 0; lane_index < 8; ++lane_index) {
        const uint8_t *source = (0xa5u & (1u << lane_index)) ? unaligned_vector : input;
        if (lane(actual_blended + lane_index * 2, 2) != lane(source + lane_index * 2, 2)) return 21;
    }
    const volatile uint8_t *actual_blended_ps = (const volatile uint8_t *)&result[26];
    for (unsigned lane_index = 0; lane_index < 4; ++lane_index) {
        const uint8_t *source = (0x5u & (1u << lane_index)) ? input + 16 : input;
        if (lane(actual_blended_ps + lane_index * 4, 4) != lane(source + lane_index * 4, 4)) return 22;
    }
    const volatile uint8_t *actual_blended_pd = (const volatile uint8_t *)&result[27];
    for (unsigned lane_index = 0; lane_index < 2; ++lane_index) {
        const uint8_t *source = (0x2u & (1u << lane_index)) ? unaligned_vector : input;
        if (lane64(actual_blended_pd + lane_index * 8, 8) != lane64(source + lane_index * 8, 8)) return 23;
    }
    const volatile uint8_t *actual_inserted_byte = (const volatile uint8_t *)&result[28];
    for (unsigned byte = 0; byte < 16; ++byte) {
        const uint8_t expected = byte == 7 ? (uint8_t)insert_byte_value : input[byte];
        if (actual_inserted_byte[byte] != expected) return 24;
    }
    const volatile uint8_t *actual_inserted_dword = (const volatile uint8_t *)&result[29];
    for (unsigned lane_index = 0; lane_index < 4; ++lane_index) {
        const uint32_t expected = lane_index == 1 ? lane(input + 1, 4) : lane(input + lane_index * 4, 4);
        if (lane(actual_inserted_dword + lane_index * 4, 4) != expected) return 25;
    }
    const volatile uint8_t *actual_inserted_qword = (const volatile uint8_t *)&result[30];
    if (lane64(actual_inserted_qword, 8) != insert_qword_value) return 26;
    sys(NR_write, 1, (long)&result[28], 80, 0, 0, 0);
    sys(NR_write, 1, (long)&preserved_qword, 8, 0, 0, 0);
    sys(NR_write, 1, (long)&extracted_byte, 8, 0, 0, 0);
    sys(NR_write, 1, (long)&extracted_memory_byte, 1, 0, 0, 0);
    sys(NR_write, 1, (long)&extracted_memory_word, 2, 0, 0, 0);
    sys(NR_write, 1, (long)&extracted_dword, 8, 0, 0, 0);
    sys(NR_write, 1, (long)&extracted_qword, 8, 0, 0, 0);

    const char message[] = "SSE4.1 integer lanes, transfers, blends and flags: ok\n";
    text(message, sizeof(message) - 1);
    return 0;
}
