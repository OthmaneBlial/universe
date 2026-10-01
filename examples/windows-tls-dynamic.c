#include "windows-guest.h"

typedef DWORD (*TlsHelper)(void);
typedef void (*TlsWatch)(volatile DWORD *);
static volatile DWORD detach_seen;

static void loadHelper(void) {
    HANDLE module = LoadLibraryA("windows-tls.dll");
    if (!module) ExitProcess(GetLastError());
    TlsHelper helper = (TlsHelper)GetProcAddress(module, "tls_helper");
    TlsWatch watch = (TlsWatch)GetProcAddress(module, "tls_watch");
    if (!helper || !watch || helper() != 0x87654321 || helper() != 0x87654322) ExitProcess(1);
    watch(&detach_seen);
    if (!FreeLibrary(module) || detach_seen != 3) ExitProcess(2);
}

void mainCRTStartup(void) {
    loadHelper();
    loadHelper();
    const char text[] = "windows dynamic TLS: callbacks, unload and fresh template ok\n";
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, sizeof(text) - 1, &written, 0) || written != sizeof(text) - 1) ExitProcess(3);
    ExitProcess(0);
}
