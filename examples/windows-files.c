#include "windows-guest.h"

// The test supplies one path. The runtime quotes each argv element for the CRT.
static WCHAR *path(void) {
    WCHAR *line = GetCommandLineW();
    if (*line++ != '"') ExitProcess(1);
    while (*line && *line != '"') line++;
    if (*line++ != '"' || *line++ != ' ' || *line++ != '"') ExitProcess(2);
    WCHAR *copy = HeapAlloc(GetProcessHeap(), 0, 65536);
    if (!copy) ExitProcess(3);
    DWORD i = 0;
    while (*line && *line != '"') { if (i >= 32766) ExitProcess(4); copy[i++] = *line++; }
    if (*line != '"') ExitProcess(5);
    copy[i] = 0; return copy;
}
void mainCRTStartup(void) {
    WCHAR *name = path();
    const char *command = GetCommandLineA() + 1;
    while (*command && *command != '"') command++;
    command += 3;
    char *narrow = HeapAlloc(GetProcessHeap(), 0, 131072);
    if (!narrow) ExitProcess(19);
    DWORD length = 0;
    while (*command && *command != '"') narrow[length++] = *command++;
    narrow[length] = 0;
    HANDLE h = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ, 0, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE) {
        if (GetLastError() != ERROR_ACCESS_DENIED) ExitProcess(6);
        DWORD n; WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), "windows files: denied\n", 22, &n, 0); ExitProcess(0);
    }
    DWORD n;
    if (!WriteFile(h, "Windows file\n", 13, &n, 0) || n != 13 || !FlushFileBuffers(h)) ExitProcess(7);
    LARGE_INTEGER size, offset; offset.QuadPart = 0;
    if (!GetFileSizeEx(h, &size) || size.QuadPart != 13) ExitProcess(8);
    HANDLE conflict = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 3, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (conflict != INVALID_HANDLE_VALUE || GetLastError() != ERROR_SHARING_VIOLATION) ExitProcess(9);
    if (!GetFileSizeEx(h, &size) || size.QuadPart != 13) ExitProcess(10);
    HANDLE duplicate = CreateFileA(narrow, GENERIC_READ, 3, 0, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (duplicate == INVALID_HANDLE_VALUE || !CloseHandle(duplicate)) ExitProcess(11);
    if (CreateFileA(narrow, GENERIC_READ | GENERIC_WRITE, 3, 0, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, 0) != INVALID_HANDLE_VALUE || GetLastError() != 80) ExitProcess(21);
    offset.QuadPart = -7;
    if (!SetFilePointerEx(h, offset, &size, 2) || size.QuadPart != 6) ExitProcess(22);
    offset.QuadPart = -6;
    if (!SetFilePointerEx(h, offset, &size, 1) || size.QuadPart != 0) ExitProcess(23);
    offset.QuadPart = -1;
    if (SetFilePointerEx(h, offset, 0, FILE_BEGIN) || GetLastError() != 131) ExitProcess(24);
    offset.QuadPart = 0;
    if (!SetFilePointerEx(h, offset, 0, FILE_BEGIN)) ExitProcess(12);
    char buffer[14];
    if (!ReadFile(h, buffer, 14, &n, 0) || n != 13) ExitProcess(13);
    const char expected[] = "Windows file\n";
    for (DWORD i = 0; i < n; i++) if (buffer[i] != expected[i]) ExitProcess(14);
    if (!ReadFile(h, buffer, 1, &n, 0) || n != 0) ExitProcess(15);
    if (!CloseHandle(h) || CloseHandle(h) || GetLastError() != ERROR_INVALID_HANDLE) ExitProcess(16);
    h = CreateFileW(name, GENERIC_READ, 3, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE || GetLastError() != ERROR_ALREADY_EXISTS) ExitProcess(17);
    n = 123;
    if (WriteFile(h, "x", 1, &n, 0) || n != 0 || GetLastError() != ERROR_ACCESS_DENIED || !CloseHandle(h)) ExitProcess(25);
    h = CreateFileW(name, GENERIC_READ | GENERIC_WRITE, 3, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE_VALUE || GetLastError() != ERROR_ALREADY_EXISTS || !GetFileSizeEx(h, &size) || size.QuadPart != 0) ExitProcess(26);
    if (!WriteFile(h, expected, 13, &n, 0) || n != 13 || !CloseHandle(h)) ExitProcess(27);
    HeapFree(GetProcessHeap(), 0, name);
    HeapFree(GetProcessHeap(), 0, narrow);
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), "windows files: ok\n", 18, &n, 0);
    ExitProcess(n == 18 ? 0 : 18);
}
