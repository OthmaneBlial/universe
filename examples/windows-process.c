#include "windows-guest.h"

static void output(const char *text, DWORD size) {
    DWORD written = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, size, &written, 0) || written != size) ExitProcess(20);
}
void mainCRTStartup(void) {
    if (GetACP() != 65001 || !GetCommandLineA() || !GetCommandLineW()) ExitProcess(1);
    if (!GetModuleHandleW(0) || GetModuleHandleW(0) != GetModuleHandleA(0)) ExitProcess(12);
    SetLastError(123);
    HANDLE heap = GetProcessHeap();
    unsigned char *p = HeapAlloc(heap, HEAP_ZERO_MEMORY, 33);
    if (!p || GetLastError() != 123 || ((ULONG_PTR)p & 15) || HeapSize(heap, 0, p) < 33) ExitProcess(2);
    for (int i = 0; i < 33; i++) { if (p[i]) ExitProcess(3); p[i] = (unsigned char)(i + 1); }
    unsigned char *q = HeapReAlloc(heap, HEAP_ZERO_MEMORY, p, 8193);
    if (!q || HeapSize(heap, 0, q) < 8193) ExitProcess(4);
    for (int i = 0; i < 33; i++) if (q[i] != i + 1) ExitProcess(5);
    for (int i = 33; i < 8193; i++) if (q[i]) ExitProcess(6);
    if (HeapReAlloc(heap, HEAP_REALLOC_IN_PLACE_ONLY, q, 20000)) ExitProcess(7);
    if (q[32] != 33 || HeapSize(heap, 0, q) < 8193) ExitProcess(8);
    if (VirtualFree(q, 0, MEM_RELEASE) || GetLastError() != 487) ExitProcess(9);
    if (!HeapFree(heap, 0, q) || HeapFree(heap, 0, q)) ExitProcess(10);
    p = HeapAlloc(heap, 0, 0);
    if (!p || !HeapFree(heap, 0, p)) ExitProcess(11);
    const char *line = GetCommandLineA();
    DWORD length = 0; while (line[length]) length++;
    output("command A: ", 11); output(line, length); output("\ncommand W: ", 12);
    const WCHAR *wide = GetCommandLineW();
    for (DWORD i = 0; wide[i]; i++) {
        unsigned long cp = wide[i];
        if (cp >= 0xd800 && cp <= 0xdbff) cp = 0x10000 + ((cp - 0xd800) << 10) + (wide[++i] - 0xdc00);
        char bytes[4]; DWORD count;
        if (cp < 0x80) { bytes[0] = (char)cp; count = 1; }
        else if (cp < 0x800) { bytes[0] = (char)(0xc0 | (cp >> 6)); bytes[1] = (char)(0x80 | (cp & 63)); count = 2; }
        else if (cp < 0x10000) { bytes[0] = (char)(0xe0 | (cp >> 12)); bytes[1] = (char)(0x80 | ((cp >> 6) & 63)); bytes[2] = (char)(0x80 | (cp & 63)); count = 3; }
        else { bytes[0] = (char)(0xf0 | (cp >> 18)); bytes[1] = (char)(0x80 | ((cp >> 12) & 63)); bytes[2] = (char)(0x80 | ((cp >> 6) & 63)); bytes[3] = (char)(0x80 | (cp & 63)); count = 4; }
        output(bytes, count);
    }
    output("\nwindows process: ok\n", 21);
    ExitProcess(0);
}
