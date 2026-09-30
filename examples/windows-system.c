typedef void *HANDLE;typedef unsigned long DWORD;typedef int BOOL;
__declspec(dllimport) HANDLE GetStdHandle(DWORD);
__declspec(dllimport) BOOL WriteFile(HANDLE,const void *,DWORD,DWORD *,void *);
__declspec(dllimport) void ExitProcess(DWORD);
__declspec(dllimport) void *VirtualAlloc(void *,unsigned long long,DWORD,DWORD);
__declspec(dllimport) BOOL VirtualFree(void *,unsigned long long,DWORD);
__declspec(dllimport) void *GetModuleHandleA(const char *);
__declspec(dllimport) DWORD GetLastError(void);
void mainCRTStartup(void){volatile long long *p=VirtualAlloc(0,8192,0x3000,4);if(!p)ExitProcess(1);for(long long i=0;i<1024;i++)p[i]=i;if(p[999]!=999||!GetModuleHandleA(0))ExitProcess(2);if(!VirtualFree((void *)p,0,0x8000))ExitProcess(3);if(VirtualFree((void *)p,0,0x8000)||GetLastError()!=487)ExitProcess(4);DWORD n;WriteFile(GetStdHandle((DWORD)-11),"windows system: ok\n",19,&n,0);ExitProcess(n==19?0:5);}
