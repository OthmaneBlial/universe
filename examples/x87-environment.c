#include <stdint.h>
#include "guest.h"

struct query { uint32_t operation, short_image, padding[2]; unsigned char state[512], image[108]; };
struct answer { unsigned char state[512], image[110], environment[28]; };
static _Alignas(16) struct query q;
static _Alignas(16) struct answer result;
#define ENV(prefix, opcode, modrm) __asm__ volatile(prefix ".byte " opcode "," modrm : : "D"(result.image + 1) : "memory")
#define OPERATE(prefix) switch (operation) { \
    case 0: ENV(prefix, "0xd9", "0x37"); break; \
    case 1: ENV(prefix, "0xd9", "0x27"); break; \
    case 2: ENV(prefix, "0xdd", "0x37"); break; \
    case 3: ENV(prefix, "0xdd", "0x27"); break; \
    case 4: ENV(".byte 0x9b; " prefix, "0xd9", "0x37"); break; \
    case 5: ENV(".byte 0x9b; " prefix, "0xdd", "0x37"); break; \
    default: return 92; \
}

long guest_main(long *sp) {
    (void)sp;
    for (unsigned n = 0; n < sizeof(result); ++n) ((unsigned char *)&result)[n] = 0xa5;
    for (;;) {
        unsigned used = 0;
        while (used < sizeof(q)) {
            long n = sys(NR_read, 0, (long)((char *)&q + used), sizeof(q) - used, 0, 0, 0);
            if (n == 0) return used == 0 ? 0 : 90;
            if (n < 0) return 91;
            used += (unsigned)n;
        }
        for (unsigned n = 0; n < sizeof(q.image); ++n) result.image[n + 1] = q.image[n];
        __asm__ volatile("fninit\n\tfxrstor64 %0" : : "m"(q.state) : "memory");
        unsigned operation = q.operation == 6 ? 2 : q.operation == 7 ? 0 : q.operation;
        if (q.short_image) { OPERATE(".byte 0x66; "); }
        else { OPERATE(""); }
        if (q.operation == 6 || q.operation == 7) {
            operation = q.operation == 6 ? 3 : 1;
            if (q.short_image) { OPERATE(".byte 0x66; "); }
            else { OPERATE(""); }
        }
        __asm__ volatile("fxsave64 %0\n\tfnstenv %1" : "=m"(result.state), "=m"(result.environment) : : "memory");
        if (sys(NR_write, 1, (long)&result, sizeof(result), 0, 0, 0) != sizeof(result)) return 93;
    }
}
