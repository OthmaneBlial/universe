typedef unsigned long DWORD;
__declspec(dllimport) int GetComputerNameA(char *,DWORD *);
__declspec(dllimport) void ExitProcess(DWORD);
void mainCRTStartup(void){DWORD length=0;ExitProcess(GetComputerNameA(0,&length));}
