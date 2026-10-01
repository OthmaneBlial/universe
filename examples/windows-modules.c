/* SDK declarations only; executable and DLL paths come from our own PE loader. */
#include <windows.h>
static void require(int condition,DWORD code) { if(!condition)ExitProcess(code); }
static int mode(const char *name) {
    const char *line=GetCommandLineA();unsigned length=0,size=0;
    while(line[length])++length;while(name[size])++size;
    if(length<size+2 || line[length-1]!='"' || line[length-size-2]!='"')return 0;
    for(unsigned n=0;n<size;++n)if(line[length-size-1+n]!=name[n])return 0;
    return 1;
}
static void output(const void *bytes,DWORD size) {
    DWORD done=0;require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),bytes,size,&done,0) && done==size,201);
}
static void missing(HMODULE module,DWORD error) {
    WCHAR wide[2]={0xcafe,0xcafe};char bytes[2]={(char)0xab,(char)0xcd};
    require(!GetModuleFileNameW(module,wide,2) && GetLastError()==error && wide[0]==0xcafe && wide[1]==0xcafe,10);
    require(!GetModuleFileNameA(module,bytes,2) && GetLastError()==error && bytes[0]==(char)0xab && bytes[1]==(char)0xcd,11);
}
static void records(HMODULE module) {
    static char path[4096];static WCHAR wide[4096];SetLastError(777);
    DWORD length=GetModuleFileNameA(module,path,4096);require(length && length<4096 && GetLastError()==777,12);
    output(&length,4);output(path,length);
    DWORD units=GetModuleFileNameW(module,wide,4096);require(units && units<4096 && GetLastError()==777,13);
    for(DWORD kind=0;kind<2;++kind)for(DWORD capacity=0;capacity<=(kind?units:length)+2;++capacity) {
        static unsigned char buffer[8200];DWORD bytes=capacity*(kind?2:1)+8;
        for(DWORD n=0;n<bytes;++n)buffer[n]=0xaa;
        struct { DWORD wide,capacity,result,error,bytes; } record={kind,capacity,0,0,bytes};
        SetLastError(777);
        record.result=kind?GetModuleFileNameW(module,(WCHAR *)buffer,capacity):GetModuleFileNameA(module,(char *)buffer,capacity);
        record.error=GetLastError();output(&record,sizeof(record));output(buffer,bytes);
    }
}
void mainCRTStartup(void) {
    HMODULE main=GetModuleHandleW(0);require(main && main==GetModuleHandleA(0),1);
    static WCHAR buffer[4096];SetLastError(777);
    require(GetModuleFileNameW(0,buffer,4096) && buffer[0]=='/' && GetLastError()==777,2);
    missing((HMODULE)0x1234,ERROR_MOD_NOT_FOUND);
    missing(GetModuleHandleW(L"kernel32.dll"),ERROR_NOT_SUPPORTED);
    require(!GetModuleFileNameW(0,0,4) && GetLastError()==ERROR_INVALID_PARAMETER,3);
    require(!GetModuleFileNameA(0,0,0) && GetLastError()==ERROR_INSUFFICIENT_BUFFER,4);
    buffer[0]=0xcafe;buffer[1]=0xcafe;
    require(GetModuleFileNameW(0,buffer,1)==1 && GetLastError()==ERROR_INSUFFICIENT_BUFFER && !buffer[0] && buffer[1]==0xcafe,15);
    char short_name[3]={(char)0xaa,(char)0xaa,(char)0xaa};
    require(GetModuleFileNameA(0,short_name,2)==2 && GetLastError()==ERROR_INSUFFICIENT_BUFFER && short_name[0]=='/' && !short_name[1] && short_name[2]==(char)0xaa,16);
    if(mode("fault")) {
        char *page=VirtualAlloc(0,4096,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);require(page!=0,5);
        GetModuleFileNameW(main,(WCHAR *)(page+4094),4096);ExitProcess(6);
    }
    if(mode("paths")) { records(0);records(main);ExitProcess(0); }
    if(mode("load") || mode("mutate")) {
        HMODULE module=LoadLibraryW(L"module é🚀.dll");require(module!=0,GetLastError());
        if(mode("mutate")) {
            output("READY\n",6);char byte;DWORD count=0;
            require(ReadFile(GetStdHandle(STD_INPUT_HANDLE),&byte,1,&count,0) && count==1,7);
        }
        records(main);records(module);require(FreeLibrary(module),8);missing(module,ERROR_MOD_NOT_FOUND);
        if(mode("load")) {
            module=LoadLibraryW(L"another é🚀.dll");require(module!=0,9);
            records(module);require(FreeLibrary(module),14);missing(module,ERROR_MOD_NOT_FOUND);
        }
        ExitProcess(0);
    }
    const char message[]="windows modules: loaded paths, Unicode, truncation and errors ok\n";
    output(message,sizeof(message)-1);ExitProcess(0);
}
