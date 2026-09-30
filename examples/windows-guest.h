/* Freestanding Windows x64 API declarations; guests have no linked CRT. */
typedef void *HANDLE;
typedef unsigned long DWORD;
typedef unsigned long long ULONG_PTR;
typedef unsigned short WCHAR;
typedef int BOOL;
typedef struct { long long QuadPart; } LARGE_INTEGER;
#define INVALID_HANDLE_VALUE ((HANDLE)~0ULL)
#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define GENERIC_READ 0x80000000UL
#define GENERIC_WRITE 0x40000000UL
#define FILE_SHARE_READ 1
#define FILE_ATTRIBUTE_NORMAL 0x80
#define CREATE_NEW 1
#define CREATE_ALWAYS 2
#define OPEN_EXISTING 3
#define OPEN_ALWAYS 4
#define FILE_BEGIN 0
#define MEM_RELEASE 0x8000
#define HEAP_ZERO_MEMORY 8
#define HEAP_REALLOC_IN_PLACE_ONLY 16
#define ERROR_ACCESS_DENIED 5
#define ERROR_INVALID_HANDLE 6
#define ERROR_SHARING_VIOLATION 32
#define ERROR_ALREADY_EXISTS 183
__declspec(dllimport) void ExitProcess(DWORD);
__declspec(dllimport) HANDLE GetStdHandle(DWORD);
__declspec(dllimport) DWORD GetLastError(void);
__declspec(dllimport) void SetLastError(DWORD);
__declspec(dllimport) HANDLE GetModuleHandleA(const char *);
__declspec(dllimport) HANDLE GetModuleHandleW(const WCHAR *);
__declspec(dllimport) DWORD GetACP(void);
__declspec(dllimport) char *GetCommandLineA(void);
__declspec(dllimport) WCHAR *GetCommandLineW(void);
__declspec(dllimport) HANDLE GetProcessHeap(void);
__declspec(dllimport) void *HeapAlloc(HANDLE, DWORD, ULONG_PTR);
__declspec(dllimport) void *HeapReAlloc(HANDLE, DWORD, void *, ULONG_PTR);
__declspec(dllimport) BOOL HeapFree(HANDLE, DWORD, void *);
__declspec(dllimport) ULONG_PTR HeapSize(HANDLE, DWORD, const void *);
__declspec(dllimport) BOOL VirtualFree(void *, ULONG_PTR, DWORD);
__declspec(dllimport) HANDLE CreateFileW(const WCHAR *, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
__declspec(dllimport) HANDLE CreateFileA(const char *, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
__declspec(dllimport) BOOL CloseHandle(HANDLE);
__declspec(dllimport) BOOL ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
__declspec(dllimport) BOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
__declspec(dllimport) BOOL GetFileSizeEx(HANDLE, LARGE_INTEGER *);
__declspec(dllimport) BOOL SetFilePointerEx(HANDLE, LARGE_INTEGER, LARGE_INTEGER *, DWORD);
__declspec(dllimport) BOOL FlushFileBuffers(HANDLE);
