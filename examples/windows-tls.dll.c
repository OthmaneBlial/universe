#define UNIVERSE_TLS_INITIAL_VALUE 0x87654321UL
#include "windows-tls.h"

static volatile DWORD callback_seen;
static volatile DWORD attached;
static volatile DWORD *detach_journal;
static void tls_callback(HANDLE module, DWORD reason, void *reserved) {
    if (module && reason == 1 && reserved == 0) callback_seen = 1;
    if (module && reason == 0 && reserved == 0 && detach_journal) (*detach_journal)++;
}
__attribute__((section(".CRT$XLB"), used)) static TlsCallback callback_entry = tls_callback;

BOOL DllMain(HANDLE module, DWORD reason, void *reserved) {
    if (reason == 1) {
        if (!module || callback_seen != 1 || universe_tls_value != 0x87654321) return 0;
        attached = 1;
    }
    if (reason == 0) {
        attached = 0;
        if (detach_journal) *detach_journal = 2;
    }
    return 1;
}

__declspec(dllexport) DWORD tls_helper(void) {
    if (!attached || callback_seen != 1) return 0;
    return universe_tls_value++;
}

__declspec(dllexport) void tls_watch(volatile DWORD *journal) {
    detach_journal = journal;
}
