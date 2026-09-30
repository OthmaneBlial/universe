#include "windows-guest.h"
__declspec(dllimport) long helper_add(long);
__declspec(dllimport) volatile long helper_data;
__declspec(dllexport) volatile long probe_data = 21;
static HANDLE instance;
static volatile long *volatile address = &probe_data;
BOOL DllMain(HANDLE module, DWORD reason, void *reserved) {
    if (!reserved) return 0;
    if (reason == 1) {
        if (helper_data != 8 || helper_add(1) != 9) return 0;
        instance = module;
        probe_data += 3;
    }
    return 1;
}
__declspec(dllexport) long probe(long n) { return helper_add(n) + *address; }
__declspec(dllexport) HANDLE probe_module(void) { return instance; }
