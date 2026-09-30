#include "windows-guest.h"
static volatile long value = 42;
static volatile long *volatile address = &value;
static volatile long *journal;
BOOL DllMain(HANDLE module, DWORD reason, void *reserved) {
    if (!module || (reason == 1 && reserved)) return 0;
    if (reason == 1) value += 3;
    if (reason == 0 && journal) journal[2] = 3;
    if (reason == 0) value = -100;
    return 1;
}
__declspec(dllexport) long late_add(long n) { return *address + n; }
__declspec(dllexport) void late_watch(volatile long *events) { journal = events; }
