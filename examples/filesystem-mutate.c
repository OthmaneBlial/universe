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
    if (call3(NR_unlinkat, dirfd, (long)"renamed", 0) != 0) return 13;
    if (call3(NR_close, dirfd, 0, 0) != 0) return 23;
    if (call3(NR_unlinkat, AT_FDCWD, (long)"created", AT_REMOVEDIR) != 0) return 14;
    if (call3(NR_unlinkat, AT_FDCWD, (long)"missing", 0) != -2) return 15;
    text("filesystem mutation: ok\n", 24);
    return 0;
}
