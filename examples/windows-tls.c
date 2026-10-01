#define UNIVERSE_TLS_INITIAL_VALUE 0x12345678UL
#include "windows-tls.h"

static volatile DWORD callback_seen;
static void tls_callback(HANDLE module, DWORD reason, void *reserved) {
    if (module && reason == 1 && reserved == 0) callback_seen = 1;
}
__attribute__((section(".CRT$XLB"), used)) static TlsCallback callback_entry = tls_callback;

__declspec(dllimport) DWORD tls_helper(void);

void mainCRTStartup(void) {
    if (universe_tls_value != 0x12345678 || callback_seen != 1) ExitProcess(1);
    universe_tls_value++;
    if (tls_helper() != 0x87654321 || tls_helper() != 0x87654322) ExitProcess(2);
    if (universe_tls_value != 0x12345679) ExitProcess(3);
    const char text[] = "windows TLS: executable, DLL and callbacks ok\n";
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, sizeof(text) - 1, &written, 0) || written != sizeof(text) - 1) ExitProcess(4);
    ExitProcess(0);
}
