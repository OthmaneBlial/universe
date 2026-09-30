typedef void *HANDLE;typedef unsigned long DWORD;typedef int BOOL;
__declspec(dllimport) HANDLE GetStdHandle(DWORD);
__declspec(dllimport) BOOL WriteFile(HANDLE,const void *,DWORD,DWORD *,void *);
__declspec(dllimport) BOOL ReadFile(HANDLE,void *,DWORD,DWORD *,void *);
__declspec(dllimport) void ExitProcess(DWORD);
void mainCRTStartup(void){char buf[32];DWORD n=0,written=0;if(!ReadFile(GetStdHandle((DWORD)-10),buf,32,&n,0))ExitProcess(1);if(!WriteFile(GetStdHandle((DWORD)-11),buf,n,&written,0)||written!=n)ExitProcess(2);ExitProcess(0);}
