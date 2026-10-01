#include "guest.h"
#define AT_FDCWD 0xffffff9cL
#define AT_REMOVEDIR 0x200

long guest_main(long *sp) {
    (void)sp;
    long initial_mask = call3(NR_umask, 0077, 0, 0);
    if (call3(NR_umask, 010022, 0, 0) != 0077 || call3(NR_umask, 0027, 0, 0) != 0022) return 30;
    if (call3(NR_mkdirat, AT_FDCWD, (long)"created", 0700) != 0) return 10;
    long fd = sys(NR_openat, AT_FDCWD, (long)"created/item", 64 | 1 | 512, 0600, 0, 0);
    if (fd < 0) return 11;
    if (call3(NR_close, fd, 0, 0) != 0) return 12;
    long dirfd = sys(NR_openat, AT_FDCWD, (long)"created", O_DIRECTORY, 0, 0, 0);
    if (dirfd < 0) return 22;
#if defined(__x86_64__)
    if (call3(NR_rename, (long)"created/item", (long)"created/interim", 0) != 0) return 20;
    if (sys(NR_renameat, dirfd, (long)"interim", dirfd, (long)"renamed", 0, 0) != 0) return 21;
#else
    if (sys(NR_renameat, dirfd, (long)"item", dirfd, (long)"renamed", 0, 0) != 0) return 20;
#endif
    if (sys(NR_renameat, AT_FDCWD, (long)"created/renamed", -100, (long)"created/interim", 0, 0) != 0 || sys(NR_renameat, -100, (long)"created/interim", AT_FDCWD, (long)"created/renamed", 0, 0) != 0) return 39;
    if (sys(NR_openat, 0xffffff9bL, (long)"created/renamed", 0, 0, 0, 0) != -9) return 40;
#if defined(__x86_64__)
    if (call3(NR_access, (long)"created/renamed", 0, 0) != 0) return 18;
    if (call3(NR_access, (long)"created/item", 0, 0) != -2) return 19;
#endif
    if (sys(NR_faccessat, dirfd, (long)"renamed", 0, 0, 0, 0) != 0) return 16;
    if (sys(NR_faccessat, AT_FDCWD, (long)"created/renamed", 0, 0, 0, 0) != 0) return 41;
    if (sys(NR_faccessat, dirfd, (long)"missing", 0, 0, 0, 0) != -2) return 17;
    long times[4] = { 123, 456, 789, 1234 };
    long stat[18];
    if (sys(NR_utimensat, dirfd, (long)"renamed", (long)times, 0, 0, 0) != 0) return 24;
    if (sys(NR_newfstatat, dirfd, (long)"renamed", (long)stat, 0, 0, 0) != 0 || stat[11] != 789 || stat[12] != 1234) return 25;
    times[1] = 1073741822; times[3] = 1073741823;
    if (sys(NR_utimensat, dirfd, (long)"renamed", (long)times, 0, 0, 0) != 0) return 26;
    if (sys(NR_newfstatat, dirfd, (long)"renamed", (long)stat, 0, 0, 0) != 0 || stat[9] != 123 || stat[10] != 456 || stat[11] <= 789) return 27;
    times[1] = 1000000000;
    if (sys(NR_utimensat, dirfd, (long)"renamed", (long)times, 0, 0, 0) != -22) return 28;
    if (sys(NR_utimensat, dirfd, (long)"renamed", 0, 0x100, 0, 0) != 0) return 29;
    if (call3(NR_unlinkat, dirfd, (long)"renamed", 0) != 0) return 13;
    if (call3(NR_close, dirfd, 0, 0) != 0) return 23;
    if (call3(NR_unlinkat, AT_FDCWD, (long)"created", AT_REMOVEDIR) != 0) return 14;
    if (call3(NR_unlinkat, AT_FDCWD, (long)"missing", 0) != -2) return 15;
    long mode_offset =
#if defined(__x86_64__)
        3;
#else
        2;
#endif
    if (call3(NR_mkdirat, AT_FDCWD, (long)"created", 0777) != 0) return 31;
    if (sys(NR_newfstatat, AT_FDCWD, (long)"created", (long)stat, 0, 0, 0) != 0 || (stat[mode_offset] & 0777) != 0750) return 32;
    fd = sys(NR_openat, AT_FDCWD, (long)"created/item", 64 | 1, 0666, 0, 0);
    if (fd < 0 || call3(NR_fstat, fd, (long)stat, 0) != 0 || (stat[mode_offset] & 0777) != 0640) return 33;
    if (call3(NR_close, fd, 0, 0) != 0 || call3(NR_umask, 0, 0, 0) != 0027) return 34;
    // Reopening an existing file must not apply a new mode or creation mask.
    fd = sys(NR_openat, AT_FDCWD, (long)"created/item", 64 | 1 | 512, 0777, 0, 0);
    if (fd < 0 || call3(NR_fstat, fd, (long)stat, 0) != 0 || (stat[mode_offset] & 0777) != 0640) return 35;
    if (call3(NR_close, fd, 0, 0) != 0 || call3(NR_unlinkat, AT_FDCWD, (long)"created/item", 0) != 0 || call3(NR_unlinkat, AT_FDCWD, (long)"created", AT_REMOVEDIR) != 0) return 36;
    if (call3(NR_mkdirat, AT_FDCWD, (long)"created", 0777) != 0 || sys(NR_newfstatat, AT_FDCWD, (long)"created", (long)stat, 0, 0, 0) != 0 || (stat[mode_offset] & 0777) != 0777) return 37;
    if (call3(NR_unlinkat, AT_FDCWD, (long)"created", AT_REMOVEDIR) != 0 || call3(NR_umask, initial_mask, 0, 0) != 0) return 38;
    text("filesystem mutation: ok\n", 24);
    return 0;
}
