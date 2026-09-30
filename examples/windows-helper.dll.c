#include "windows-guest.h"
__declspec(dllexport) volatile long helper_data = 5;
static volatile long *volatile address = &helper_data; /* Forces a real DIR64 relocation. */
static volatile long *journal;
BOOL DllMain(HANDLE module, DWORD reason, void *reserved) {
    if (!module) return 0;
    (void)reserved;
    if (reason == 1) helper_data += 3;
    if (reason == 0 && journal) journal[1] = journal[0] + 1;
    return 1;
}
__declspec(dllexport) long helper_add(long n) { return n + *address; }
__declspec(dllexport) void helper_watch(volatile long *events) { journal = events; }
