#include <nmmintrin.h>
#include <stdint.h>
#include "guest.h"

static uint32_t reference(uint32_t crc, uint64_t value, unsigned bits) {
    for (unsigned bit = 0; bit < bits; ++bit) {
        const uint32_t mix = (crc ^ (uint32_t)value) & 1;
        crc = (crc >> 1) ^ (mix ? UINT32_C(0x82f63b78) : 0);
        value >>= 1;
    }
    return crc;
}

long guest_main(long *sp) {
    (void)sp;
    volatile uint8_t byte = 0xa6;
    volatile uint16_t word = 0x9182;
    volatile uint32_t dword = UINT32_C(0x87654321);
    volatile uint64_t qword = UINT64_C(0xfedcba9876543210);
    uint32_t crc = UINT32_C(0x12345678);
    uint32_t expected = crc;

    expected = reference(expected, byte, 8);
    crc = _mm_crc32_u8(crc, byte);
    if (crc != expected) return 1;
    expected = reference(expected, word, 16);
    crc = _mm_crc32_u16(crc, word);
    if (crc != expected) return 2;
    expected = reference(expected, dword, 32);
    crc = _mm_crc32_u32(crc, dword);
    if (crc != expected) return 3;

    const uint64_t initial64 = UINT64_C(0xdeadbeef12345678);
    const uint32_t expected64 = reference((uint32_t)initial64, qword, 64);
    const uint64_t crc64 = _mm_crc32_u64(initial64, qword);
    if (crc64 != expected64) return 4;

    uint32_t known = UINT32_MAX;
    static const uint8_t check[] = "123456789";
    for (unsigned i = 0; i < sizeof(check) - 1; ++i) known = _mm_crc32_u8(known, check[i]);
    if (known != UINT32_C(0x1cf96d7c)) return 5;

    uint64_t zero_extended = UINT64_MAX;
    __asm__ volatile("crc32l %1, %k0" : "+r"(zero_extended) : "m"(dword) : "cc");
    if (zero_extended != reference(UINT32_MAX, dword, 32)) return 6;

    uint32_t high_byte_crc = UINT32_C(0x12345678);
    __asm__ volatile("crc32b %%ah, %%eax" : "=a"(high_byte_crc) : "0"(high_byte_crc) : "cc");
    if (high_byte_crc != reference(UINT32_C(0x12345678), 0x56, 8)) return 7;

    const uint64_t flags_left = 0;
    uint32_t flags_crc = 7;
    uint8_t flags[5];
    __asm__ volatile("cmpq $1, %[left]\n\tcrc32b %[source], %[crc]\n\tsetc %[carry]\n\tsetz %[zero]\n\tsetp %[parity]\n\tseto %[overflow]\n\tsets %[sign]"
        : [crc] "+r"(flags_crc), [carry] "=qm"(flags[0]), [zero] "=qm"(flags[1]), [parity] "=qm"(flags[2]), [overflow] "=qm"(flags[3]), [sign] "=qm"(flags[4])
        : [left] "r"(flags_left), [source] "r"(byte)
        : "cc");
    if (flags[0] != 1 || flags[1] != 0 || flags[2] != 1 || flags[3] != 0 || flags[4] != 1) return 8;

    const char message[] = "SSE4.2 CRC32C widths and flags: ok\n";
    text(message, sizeof(message) - 1);
    return 0;
}
