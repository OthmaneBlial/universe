/* SDK ABI only; no CRT implementation, external threads or vendor DLLs. */
#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <stddef.h>
_Static_assert(sizeof(CRITICAL_SECTION)==40 && offsetof(CRITICAL_SECTION,RecursionCount)==12 && offsetof(CRITICAL_SECTION,OwningThread)==16,"Windows x64 critical section ABI");
static void require(int condition,DWORD code) { if (!condition) ExitProcess(code); }
static int mode(const char *suffix) {
    const char *line=GetCommandLineA(); unsigned length=0,count=0;
    while(line[length])++length; while(suffix[count])++count;
    if (count>length) return 0;
    for(unsigned n=0;n<count;++n) if(line[length-count+n]!=suffix[n])return 0;
    return 1;
}
void mainCRTStartup(void) {
    HANDLE pending=CreateEventW(0,FALSE,FALSE,0); require(pending!=0,1);
    if (mode("\"infinite\"") || mode("\"long-wait\"")) {
        WaitForSingleObject(pending,mode("\"infinite\"")?INFINITE:1000); ExitProcess(100);
    }
    if (mode("\"timed\"")) {
        ULONGLONG before=GetTickCount64();
        require(WaitForSingleObject(pending,40)==WAIT_TIMEOUT && GetTickCount64()-before>=40,2);
        require(CloseHandle(pending),3); ExitProcess(0);
    }
    if (mode("\"bad-critical\"")) { CRITICAL_SECTION uninitialized; EnterCriticalSection(&uninitialized); ExitProcess(101); }
    require(GetCurrentProcessId()==1 && GetCurrentThreadId()==1 && GetCurrentThread()==(HANDLE)-2,4);
    require(ResumeThread(GetCurrentThread())==0 && ResumeThread((HANDLE)123)==(DWORD)-1 && GetLastError()==ERROR_INVALID_HANDLE,5);
    require(SetThreadAffinityMask(GetCurrentThread(),1)==1 && !SetThreadAffinityMask(GetCurrentThread(),2) && GetLastError()==ERROR_INVALID_PARAMETER,6);
    DWORD_PTR process=99,system=99;
    require(GetProcessAffinityMask(GetCurrentProcess(),&process,&system) && process==1 && system==1 && SetProcessAffinityMask(GetCurrentProcess(),1),7);
    require(!SetProcessAffinityMask(GetCurrentProcess(),0) && GetLastError()==ERROR_INVALID_PARAMETER && CloseHandle(GetCurrentThread()),8);
    LARGE_INTEGER frequency,first,last;
    SetLastError(555);
    require(QueryPerformanceFrequency(&frequency) && frequency.QuadPart==1000000000 && QueryPerformanceCounter(&first),9);
    require(QueryPerformanceCounter(&last) && last.QuadPart>=first.QuadPart && GetLastError()==555,10);
    DWORD version=GetVersion();
    require(LOBYTE(LOWORD(version))==6 && HIBYTE(LOWORD(version))==2 && HIWORD(version)==9200 && !GetLargePageMinimum() && GetOEMCP()==GetACP(),11);
    DWORD ticks=GetTickCount(); ULONGLONG ticks64=GetTickCount64(); require((DWORD)ticks64-ticks<100,12);
    HANDLE manual=CreateEventW(0,TRUE,FALSE,L"Local\\宇宙🚀"); require(manual && GetLastError()==0,13);
    HANDLE alias=CreateEventW(0,FALSE,TRUE,L"宇宙🚀"); require(alias && alias!=manual && GetLastError()==ERROR_ALREADY_EXISTS,14);
    require(WaitForSingleObject(alias,0)==WAIT_TIMEOUT && SetEvent(alias) && WaitForSingleObject(manual,0)==WAIT_OBJECT_0,15);
    require(WaitForSingleObject(alias,0)==WAIT_OBJECT_0 && ResetEvent(manual) && WaitForSingleObject(alias,0)==WAIT_TIMEOUT,16);
    HANDLE query=OpenEventW(SYNCHRONIZE,FALSE,L"宇宙🚀"),modify=OpenEventW(EVENT_MODIFY_STATE,FALSE,L"Local\\宇宙🚀");
    require(query && modify && query!=manual && !SetEvent(query) && GetLastError()==ERROR_ACCESS_DENIED,17);
    require(WaitForSingleObject(modify,0)==WAIT_FAILED && GetLastError()==ERROR_ACCESS_DENIED && SetEvent(modify) && WaitForSingleObject(query,0)==WAIT_OBJECT_0,18);
    require(!OpenEventW(SYNCHRONIZE,FALSE,L"missing") && GetLastError()==ERROR_FILE_NOT_FOUND,19);
    require(!CreateSemaphoreW(0,0,1,L"宇宙🚀") && GetLastError()==ERROR_INVALID_HANDLE,20);
    require(!CreateEventW(0,TRUE,TRUE,L"Global\\outside") && GetLastError()==ERROR_NOT_SUPPORTED,21);
    SECURITY_ATTRIBUTES attributes={sizeof(attributes),0,FALSE};
    require(!CreateEventW(&attributes,FALSE,FALSE,0) && GetLastError()==ERROR_NOT_SUPPORTED && !OpenEventW(SYNCHRONIZE,TRUE,L"宇宙🚀"),22);
    require(CloseHandle(manual) && CloseHandle(alias) && CloseHandle(query) && CloseHandle(modify),23);
    require(!OpenEventW(SYNCHRONIZE,FALSE,L"宇宙🚀") && GetLastError()==ERROR_FILE_NOT_FOUND && !SetEvent(manual) && GetLastError()==ERROR_INVALID_HANDLE,24);
    HANDLE auto_event=CreateEventW(0,FALSE,TRUE,0);
    require(auto_event && WaitForSingleObject(auto_event,0)==WAIT_OBJECT_0 && WaitForSingleObject(auto_event,0)==WAIT_TIMEOUT,25);
    require(SetEvent(auto_event) && SetEvent(auto_event) && WaitForSingleObject(auto_event,0)==WAIT_OBJECT_0 && WaitForSingleObject(auto_event,0)==WAIT_TIMEOUT,26);
    HANDLE sem=CreateSemaphoreW(0,1,3,L"tokens"),sem_alias=CreateSemaphoreW(0,-1,-1,L"tokens");
    require(sem && sem_alias && GetLastError()==ERROR_ALREADY_EXISTS,27);
    LONG previous=99;
    require(WaitForSingleObject(sem_alias,0)==WAIT_OBJECT_0 && WaitForSingleObject(sem,0)==WAIT_TIMEOUT && ReleaseSemaphore(sem,2,&previous) && previous==0,28);
    previous=99; require(!ReleaseSemaphore(sem,2,&previous) && GetLastError()==ERROR_TOO_MANY_POSTS && previous==99,29);
    require(!ReleaseSemaphore(sem,-1,0) && GetLastError()==ERROR_INVALID_PARAMETER && !SetEvent(sem) && GetLastError()==ERROR_INVALID_HANDLE,30);
    HANDLE sem_query=OpenSemaphoreW(SYNCHRONIZE,FALSE,L"tokens"); require(sem_query && !ReleaseSemaphore(sem_query,1,0) && GetLastError()==ERROR_ACCESS_DENIED,31);
    HANDLE both[]={sem,auto_event};
    require(WaitForMultipleObjects(2,both,TRUE,0)==WAIT_TIMEOUT && WaitForSingleObject(sem,0)==WAIT_OBJECT_0,32); /* Wait-all did not consume a token. */
    require(SetEvent(auto_event) && WaitForMultipleObjects(2,both,TRUE,0)==WAIT_OBJECT_0 && WaitForSingleObject(sem,0)==WAIT_TIMEOUT && WaitForSingleObject(auto_event,0)==WAIT_TIMEOUT,33);
    require(ReleaseSemaphore(sem,1,0) && SetEvent(auto_event) && WaitForMultipleObjects(2,both,FALSE,0)==WAIT_OBJECT_0 && WaitForSingleObject(auto_event,0)==WAIT_OBJECT_0,34);
    require(SetEvent(auto_event),35); both[0]=pending; both[1]=auto_event;
    require(WaitForMultipleObjects(2,both,FALSE,0)==WAIT_OBJECT_0+1 && WaitForSingleObject(auto_event,0)==WAIT_TIMEOUT,36);
    both[0]=sem; both[1]=sem; require(WaitForMultipleObjects(2,both,TRUE,0)==WAIT_FAILED && GetLastError()==ERROR_INVALID_PARAMETER,37);
    both[1]=sem_alias; require(WaitForMultipleObjects(2,both,TRUE,0)==WAIT_FAILED && GetLastError()==ERROR_NOT_SUPPORTED,38);
    both[0]=auto_event; both[1]=(HANDLE)123; require(SetEvent(auto_event) && WaitForMultipleObjects(2,both,FALSE,0)==WAIT_FAILED && GetLastError()==ERROR_INVALID_HANDLE && WaitForSingleObject(auto_event,0)==WAIT_OBJECT_0,39);
    require(WaitForMultipleObjects(0,both,FALSE,0)==WAIT_FAILED && GetLastError()==ERROR_INVALID_PARAMETER,40);
    require(WaitForSingleObject(GetCurrentProcess(),0)==WAIT_TIMEOUT && WaitForSingleObject(GetCurrentThread(),0)==WAIT_TIMEOUT,41);
    CRITICAL_SECTION critical;
    require(InitializeCriticalSectionAndSpinCount(&critical,4000) && !critical.SpinCount && !critical.RecursionCount,42);
    EnterCriticalSection(&critical); require(TryEnterCriticalSection(&critical) && critical.RecursionCount==2 && critical.OwningThread==(HANDLE)1,43);
    require(SetCriticalSectionSpinCount(&critical,8000)==0 && !critical.SpinCount,44);
    LeaveCriticalSection(&critical); LeaveCriticalSection(&critical); require(!critical.RecursionCount && !critical.OwningThread,45);
    DeleteCriticalSection(&critical); InitializeCriticalSection(&critical); EnterCriticalSection(&critical); LeaveCriticalSection(&critical); DeleteCriticalSection(&critical);
    require(CloseHandle(pending) && CloseHandle(auto_event) && CloseHandle(sem) && CloseHandle(sem_alias) && CloseHandle(sem_query),46);
    require(!OpenSemaphoreW(SYNCHRONIZE,FALSE,L"tokens") && GetLastError()==ERROR_FILE_NOT_FOUND,47);
    for(unsigned n=0;n<1100;++n) { HANDLE handle=CreateEventW(0,FALSE,FALSE,L"reuse"); require(handle && CloseHandle(handle),48); }
    const char message[]="windows sync: shared events/semaphores, waits, recursive locks and virtual CPU clocks ok\n";
    DWORD written=0; require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),message,sizeof(message)-1,&written,0) && written==sizeof(message)-1,49); ExitProcess(0);
}
