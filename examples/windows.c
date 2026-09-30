typedef void *HANDLE;typedef unsigned long DWORD;typedef int BOOL;
__declspec(dllimport) HANDLE GetStdHandle(DWORD);
__declspec(dllimport) BOOL WriteFile(HANDLE,const void *,DWORD,DWORD *,void *);
__declspec(dllimport) void ExitProcess(DWORD);
void mainCRTStartup(void){const char text[]="Hello from Windows x86-64!\n";DWORD written=0;BOOL ok=WriteFile(GetStdHandle((DWORD)-11),text,sizeof(text)-1,&written,0);ExitProcess(ok&&written==sizeof(text)-1?0:1);}
