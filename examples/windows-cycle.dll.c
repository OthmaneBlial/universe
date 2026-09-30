#include "windows-guest.h"
static volatile long value;
static volatile long *volatile address=&value;
static volatile long *journal;
static long (*late)(long);
#ifdef CYCLE_A
__declspec(dllexport) long cycle_a(void) { return 17; }
__declspec(dllimport) long cycle_b(void);
#else
__declspec(dllexport) long cycle_b(void) { return 29; }
__declspec(dllimport) long cycle_a(void);
#endif
BOOL DllMain(HANDLE module, DWORD reason, void *reserved) {
    if (!module || reserved) return 0;
    if (reason==1) {
#ifdef CYCLE_BOOTSTRAP
        value=1; /* First build supplies A's import library; the final A imports B. */
#elif defined(CYCLE_A)
        value=cycle_b()+17;
#else
        value=cycle_a()+29;
#endif
    }
    if (reason==0 && journal) {
#ifdef CYCLE_A
        journal[0]=!late || late(5)==50 ? 1 : -1;
#else
        journal[1]=journal[0]==1 ? 2 : -1;
#endif
    }
    return 1;
}
__declspec(dllexport) long cycle_value(void) { return *address; }
__declspec(dllexport) void cycle_watch(volatile long *events) { journal=events; }
__declspec(dllexport) void cycle_late_watch(long (*function)(long)) { late=function; }
