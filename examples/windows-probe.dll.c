#include "windows-guest.h"
__declspec(dllimport) long helper_add(long);
__declspec(dllimport) volatile long helper_data;
__declspec(dllexport) volatile long probe_data = 21;
static HANDLE instance;
static volatile long *journal;
static long (*late)(long);
__declspec(dllexport) long probe_reserved;
static volatile long *volatile address = &probe_data;
BOOL DllMain(HANDLE module, DWORD reason, void *reserved) {
    if (reason == 1) {
        if (helper_data != 8 || helper_add(1) != 9) return 0;
        instance = module;
        probe_reserved = reserved != 0;
        probe_data += 3;
    }
    if (reason == 0 && journal) journal[0] = helper_add(1) == 9 && (!late || late(5)==50) ? 1 : -1;
    return 1;
}
__declspec(dllexport) long probe(long n) { return helper_add(n) + *address; }
__declspec(dllexport) HANDLE probe_module(void) { return instance; }
__declspec(dllexport) void probe_watch(volatile long *events) { journal = events; }
__declspec(dllexport) void probe_late_watch(long (*function)(long)) { late = function; }
