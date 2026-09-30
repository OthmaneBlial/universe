typedef unsigned long DWORD;
__declspec(dllimport) DWORD GetTickCount(void);
__declspec(dllimport) void ExitProcess(DWORD);
void mainCRTStartup(void){ExitProcess(GetTickCount());}
