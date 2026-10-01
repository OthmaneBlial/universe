#include "guest.h"
#define AT_FDCWD -100
#define AT_REMOVEDIR 0x200

long guest_main(long *sp) {
    (void)sp;
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
#if defined(__x86_64__)
    if (call3(NR_access, (long)"created/renamed", 0, 0) != 0) return 18;
    if (call3(NR_access, (long)"created/item", 0, 0) != -2) return 19;
#endif
    if (sys(NR_faccessat, dirfd, (long)"renamed", 0, 0, 0, 0) != 0) return 16;
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
    text("filesystem mutation: ok\n", 24);
    return 0;
}
