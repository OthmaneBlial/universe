#include "windows-guest.h"
__declspec(dllimport) long probe(long);
__declspec(dllimport) volatile long probe_data;
__declspec(dllimport) HANDLE probe_module(void);
__declspec(dllimport) long forwarded_add(long);
__declspec(dllimport) BOOL forwarded_write(HANDLE, const void *, DWORD, DWORD *, void *);
__declspec(dllimport) void *GetProcAddress(HANDLE, const char *);
void mainCRTStartup(void) {
    HANDLE module = GetModuleHandleA("WINDOWS-PROBE.DLL");
    if (!module || module != probe_module() || GetModuleHandleW((const WCHAR *)L"windows-probe.dll") != module) ExitProcess(1);
    if (probe_data != 24 || probe(4) != 36 || forwarded_add(5) != 13) ExitProcess(2);
    long (*named)(long) = (long (*)(long))GetProcAddress(module, "probe");
    long (*ordinal)(long) = (long (*)(long))GetProcAddress(module, (const char *)7);
    volatile long *data = GetProcAddress(module, "probe_data");
    if (!named || named != ordinal || named(5) != 37 || data != &probe_data) ExitProcess(3);
    *data += 1;
    if (probe(5) != 38) ExitProcess(4);
    if (GetProcAddress(module, "missing") || GetLastError() != 127) ExitProcess(5);
    HANDLE kernel = GetModuleHandleA("kernel32.dll");
    if (!kernel || GetProcAddress(kernel, "WriteFile") != (void *)WriteFile) ExitProcess(6);
    DWORD written;
    const char text[] = "windows DLL: imports, exports, relocations and initialization ok\n";
    forwarded_write(GetStdHandle(STD_OUTPUT_HANDLE), text, sizeof(text)-1, &written, 0);
    ExitProcess(written == sizeof(text)-1 ? 0 : 7);
}
