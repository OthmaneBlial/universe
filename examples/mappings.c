#include "guest.h"
long guest_main(long *sp) {
    if (sp[0] != 2 && sp[0] != 3) return 1;
    long fd = sys(NR_openat, -100, sp[2], 0, 0, 0, 0);
    if (fd == -13) return 77;
    if (fd < 0) return 2;
    if (call3(NR_lseek, fd, 2, 0) != 2) return 3;
    long mapped = sys(NR_mmap, 0, sp[0] == 3 ? 8192 : 4096, 3, 2, fd, 4096);
    if (mapped < 0) return 4;
    volatile char *file = (char *)mapped;
    const char *expected = "mapped!";
    for (long i = 0; i < 7; i++) if (file[i] != expected[i]) return 5;
    if (file[7] || file[4095] || call3(NR_lseek, fd, 0, 1) != 2) return 6;
    if (sp[0] == 3) { (void)file[4096]; return 16; } // Must fault on the whole page beyond EOF.
    file[0] = 'Z';
    char byte = 0;
    if (call3(NR_lseek, fd, 4096, 0) != 4096 || call3(NR_read, fd, (long)&byte, 1) != 1 || byte != 'm') return 7;
    long reserved = sys(NR_mmap, 0, 8192, 3, 0x22, -1, 0);
    if (reserved < 0) return 8;
    volatile char *pages = (char *)reserved;
    pages[0] = 42; pages[4096] = 99;
    if (sys(NR_mmap, reserved + 4096, 4096, 1, 0x12, fd, 4096) != reserved + 4096) return 9;
    if (pages[0] != 42 || pages[4096] != 'm') return 10;
    if (sys(NR_mmap, reserved, 4096, 3, 0x12, -1, 0) != -9 || pages[0] != 42) return 11;
    if (sys(NR_mmap, reserved, 4096, 3, 0x12, fd, 1) != -22 || pages[0] != 42) return 12;
    if (sys(NR_mmap, reserved, 4096, 3, 0x100022, -1, 0) != -17 || pages[0] != 42) return 13;
    if (sys(NR_mmap, reserved, 4096, 3, 1, fd, 0) != -22 || pages[0] != 42) return 17;
    if (sys(NR_mmap, reserved, 4096, 3, 0x32, -1, 0) != reserved || pages[0] || pages[4096] != 'm') return 14;
    if (call3(NR_close, fd, 0, 0) || call3(NR_munmap, mapped, 4096, 0) || call3(NR_munmap, reserved, 8192, 0)) return 15;
    text("mappings: ok\n", 13);
    return 0;
}
