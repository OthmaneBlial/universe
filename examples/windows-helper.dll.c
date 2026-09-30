#include "windows-guest.h"
__declspec(dllexport) volatile long helper_data = 5;
static volatile long *volatile address = &helper_data; /* Forces a real DIR64 relocation. */
BOOL DllMain(HANDLE module, DWORD reason, void *reserved) {
    if (!module || !reserved) return 0;
    if (reason == 1) helper_data += 3;
    return 1;
}
__declspec(dllexport) long helper_add(long n) { return n + *address; }
