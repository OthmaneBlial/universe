/* Windows SDK declarations and layout, with no vendor runtime or DLL code. */
#include <windows.h>
#include <stddef.h>
_Static_assert(sizeof(WIN32_FIND_DATAW)==592,"find record size");
_Static_assert(offsetof(WIN32_FIND_DATAW,cFileName)==44,"long filename offset");
_Static_assert(offsetof(WIN32_FIND_DATAW,cAlternateFileName)==564,"short filename offset");
static WCHAR path[32768];static BYTE output[600];static HANDLE searches[4];
static void require(int ok,DWORD code) { if(!ok)ExitProcess(code); }
static int mode(const char *name) {
    const char *line=GetCommandLineA();unsigned n=0,size=0;while(line[n])++n;while(name[size])++size;
    if(n<size+2||line[n-1]!='"'||line[n-size-2]!='"')return 0;
    for(unsigned i=0;i<size;++i)if(line[n-size-1+i]!=name[i])return 0;return 1;
}
static void emit(const void *bytes,DWORD size) {
    DWORD done=0;while(done<size) { DWORD n;require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),(const char *)bytes+done,size-done,&n,0)&&n,201);done+=n; }
}
static void read_all(void *bytes,DWORD size) {
    DWORD done=0;while(done<size) { DWORD n;require(ReadFile(GetStdHandle(STD_INPUT_HANDLE),(char *)bytes+done,size-done,&n,0)&&n,202);done+=n; }
}
void mainCRTStartup(void) {
    WIN32_FIND_DATAW *data=(WIN32_FIND_DATAW *)(output+4);
    if(mode("source-fault")) { FindFirstFileW((WCHAR *)1,data);ExitProcess(203); }
    if(mode("first-fault")||mode("next-fault")) {
        BYTE *p=VirtualAlloc(0,4096,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);require(p!=0,204);
        if(mode("first-fault"))FindFirstFileW(L"*",(WIN32_FIND_DATAW *)(p+4094));
        else { HANDLE h=FindFirstFileW(L"*",data);require(h!=INVALID_HANDLE_VALUE,205);FindNextFileW(h,(WIN32_FIND_DATAW *)(p+4094)); }
        ExitProcess(206);
    }
    if(mode("oracle")) {
        for(;;) {
            DWORD request[4],done=0;
            while(done<sizeof(request)) { DWORD n;
                require(ReadFile(GetStdHandle(STD_INPUT_HANDLE),(char *)request+done,sizeof(request)-done,&n,0),207);
                if(!n) { require(!done,208);ExitProcess(0); }done+=n;
            }
            require(request[1]<4&&request[3]<32768,209);read_all(path,request[3]*2);path[request[3]]=0;
            for(unsigned i=0;i<sizeof(output);++i)output[i]=0xa5;
            HANDLE *slot=&searches[request[1]];SetLastError(777);ULONGLONG result=0;
            switch(request[0]) {
                case 0: *slot=FindFirstFileW(path,data);result=(ULONGLONG)*slot;break;
                case 1: result=FindNextFileW(*slot,data);break;
                case 2: result=FindClose(*slot);break;
                case 3: result=CloseHandle(*slot);break;
                case 4: result=FindNextFileW(request[2]==0?0:request[2]==1?GetStdHandle(STD_OUTPUT_HANDLE):INVALID_HANDLE_VALUE,data);break;
                case 5: result=FindClose(request[2]==0?0:request[2]==1?GetStdHandle(STD_OUTPUT_HANDLE):INVALID_HANDLE_VALUE);break;
                case 6: result=SetCurrentDirectoryW(path);break;
                case 7: result=MoveFileW(path,L"renamed-directory");break;
                case 8: result=(ULONGLONG)FindFirstFileW(0,data);break;
                case 9: result=(ULONGLONG)FindFirstFileW(path,0);break;
                case 10: result=FindNextFileW(*slot,0);break;
                default:ExitProcess(210);
            }
            DWORD reply[]={GetLastError(),sizeof(output)};emit(&result,sizeof(result));emit(reply,sizeof(reply));emit(output,sizeof(output));
        }
    }
    require(FindFirstFileW((WCHAR *)1,data)==INVALID_HANDLE_VALUE&&GetLastError()==ERROR_ACCESS_DENIED,211);
    require(!FindNextFileW((HANDLE)1,(WIN32_FIND_DATAW *)1)&&GetLastError()==ERROR_ACCESS_DENIED,212);
    require(!FindClose((HANDLE)1)&&GetLastError()==ERROR_INVALID_HANDLE,213);
    const char message[]="windows enumeration: denied\n";emit(message,sizeof(message)-1);ExitProcess(0);
}
