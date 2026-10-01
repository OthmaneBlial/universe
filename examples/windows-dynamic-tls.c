#include "windows-guest.h"

static DWORD teb_last_error(void) {
    DWORD value;
    __asm__ volatile("movl %%gs:0x68, %0" : "=r"(value));
    return value;
}

void mainCRTStartup(void) {
    DWORD indices[64];
    DWORD first = TlsAlloc();
    if (first == TLS_OUT_OF_INDEXES || first >= 64) ExitProcess(1);

    SetLastError(123);
    if (teb_last_error() != 123) ExitProcess(2);
    if (TlsGetValue(first) != 0 || GetLastError() != 0 || teb_last_error() != 0) ExitProcess(2);
    if (!TlsSetValue(first, (void *)0x12345678) || TlsGetValue(first) != (void *)0x12345678) ExitProcess(3);
    if (!TlsSetValue(first, 0)) ExitProcess(4);
    SetLastError(123);
    if (TlsGetValue(first) != 0 || GetLastError() != 0) ExitProcess(5);

    indices[0] = first;
    for (DWORD i = 1; i < 64; i++) {
        indices[i] = TlsAlloc();
        if (indices[i] == TLS_OUT_OF_INDEXES || indices[i] >= 64) ExitProcess(6);
    }
    if (TlsAlloc() != TLS_OUT_OF_INDEXES || GetLastError() != 8) ExitProcess(7);

    if (!TlsFree(first) || TlsGetValue(first) != 0 || GetLastError() != ERROR_INVALID_PARAMETER) ExitProcess(8);
    if (TlsAlloc() != first || TlsGetValue(first) != 0 || GetLastError() != 0) ExitProcess(9);
    if (TlsSetValue(64, (void *)1) || GetLastError() != ERROR_INVALID_PARAMETER || teb_last_error() != ERROR_INVALID_PARAMETER) ExitProcess(10);
    if (TlsFree(64) || GetLastError() != ERROR_INVALID_PARAMETER) ExitProcess(11);

    for (DWORD i = 0; i < 64; i++) if (!TlsFree(indices[i])) ExitProcess(12);
    const char text[] = "windows dynamic TLS: allocation, values, reuse and errors ok\n";
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, sizeof(text) - 1, &written, 0) || written != sizeof(text) - 1) ExitProcess(13);
    ExitProcess(0);
}
