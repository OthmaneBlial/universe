/* Windows SDK declarations and layout, with no vendor runtime or DLL code. */
#include <windows.h>
#include <stddef.h>
_Static_assert(sizeof(WIN32_FIND_DATAW)==592,"find record size");
_Static_assert(offsetof(WIN32_FIND_DATAW,cFileName)==44,"long filename offset");
_Static_assert(offsetof(WIN32_FIND_DATAW,cAlternateFileName)==564,"short filename offset");
_Static_assert(sizeof(WIN32_FIND_STREAM_DATA)==600,"stream record size");
_Static_assert(offsetof(WIN32_FIND_STREAM_DATA,cStreamName)==8,"stream filename offset");
static WCHAR path[32768];static char ansi_path[131072];static BYTE output[608];static HANDLE searches[4],many[1024];
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
    if(mode("stream-source-fault")) { FindFirstStreamW((WCHAR *)1,FindStreamInfoStandard,output+4,0);ExitProcess(214); }
    if(mode("stream-fault")) {
        BYTE *p=VirtualAlloc(0,4096,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);require(p!=0,215);
        FindFirstStreamW(L"regular.bin",FindStreamInfoStandard,p+4094,0);ExitProcess(216);
    }
    if(mode("stream-limit")) {
        for(unsigned i=0;i<1024;++i) { many[i]=FindFirstStreamW(L"regular.bin",FindStreamInfoStandard,output+4,0);
            require(many[i]!=INVALID_HANDLE_VALUE&&(!i||(ULONGLONG)many[i]>(ULONGLONG)many[i-1]),217); }
        for(unsigned i=0;i<sizeof(output);++i)output[i]=0xa5;
        require(FindFirstStreamW(L"regular.bin",FindStreamInfoStandard,output+4,0)==INVALID_HANDLE_VALUE&&GetLastError()==ERROR_TOO_MANY_OPEN_FILES,218);
        require(FindFirstFileW(L"*",data)==INVALID_HANDLE_VALUE&&GetLastError()==ERROR_TOO_MANY_OPEN_FILES,219);
        for(unsigned i=0;i<sizeof(output);++i)require(output[i]==0xa5,220);
        require(FindClose(many[0]),221);HANDLE file_search=FindFirstFileW(L"regular.bin",data);
        require(file_search!=INVALID_HANDLE_VALUE&&(ULONGLONG)file_search>(ULONGLONG)many[1023],222);
        require(!FindNextStreamW(file_search,output+4)&&GetLastError()==ERROR_INVALID_HANDLE,223);
        require(!CloseHandle(file_search)&&GetLastError()==ERROR_INVALID_HANDLE,224);
        require(!FindNextFileW(file_search,data)&&GetLastError()==ERROR_NO_MORE_FILES&&FindClose(file_search),225);
        for(unsigned i=1;i<1024;++i)require(FindClose(many[i]),226);
        const char message[]="windows stream limit: 1024 shared searches and checked kinds ok\n";emit(message,sizeof(message)-1);ExitProcess(0);
    }
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
                case 11: *slot=FindFirstStreamW(path,(STREAM_INFO_LEVELS)(request[2]&0xffff),output+4,request[2]>>16);result=(ULONGLONG)*slot;break;
                case 12: result=FindNextStreamW(*slot,request[2]==1?(void *)1:request[2]==2?0:output+4);break;
                case 13: result=(ULONGLONG)FindFirstStreamW(path,FindStreamInfoStandard,0,0);break;
                case 14: result=(ULONGLONG)FindFirstStreamW(0,FindStreamInfoStandard,output+4,0);break;
                case 15: result=FindNextStreamW(request[2]==0?0:request[2]==1?GetStdHandle(STD_OUTPUT_HANDLE):request[2]==2?INVALID_HANDLE_VALUE:GetCurrentThread(),(void *)1);break;
                case 16: *slot=CreateFileW(path,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);result=(ULONGLONG)*slot;break;
                case 17: *slot=CreateEventW(0,0,1,0);result=(ULONGLONG)*slot;break;
                case 18: result=DeleteFileW(path);break;
                case 19: result=MoveFileW(path,L"moved-stream.bin");break;
                case 20: { LARGE_INTEGER position;position.QuadPart=request[2];result=SetFilePointerEx(*slot,position,0,FILE_BEGIN)&&SetEndOfFile(*slot);break; }
                case 21: { DWORD n=0;require(request[2]<=600,229);result=ReadFile(*slot,output+4,request[2],&n,0)?n:(ULONGLONG)INVALID_HANDLE_VALUE;break; }
                case 22: { DWORD n=0;const char text[]="guest stream write";result=WriteFile(*slot,text,sizeof(text)-1,&n,0)?n:(ULONGLONG)INVALID_HANDLE_VALUE;break; }
                case 23: require(WideCharToMultiByte(CP_UTF8,0,path,-1,ansi_path,sizeof(ansi_path),0,0)>0,230);
                    *slot=CreateFileA(ansi_path,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);result=(ULONGLONG)*slot;break;
                case 24: *slot=CreateFileW(path,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE|FILE_SHARE_DELETE,0,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);result=(ULONGLONG)*slot;break;
                case 25: *slot=CreateFileW(path,GENERIC_READ,0,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);result=(ULONGLONG)*slot;break;
                case 26: *slot=CreateFileW(path,request[2]&1?GENERIC_READ:0,request[2]&2?0:7,0,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS,0);result=(ULONGLONG)*slot;break;
                case 27: require(WideCharToMultiByte(CP_UTF8,0,path,-1,ansi_path,sizeof(ansi_path),0,0)>0,231);
                    *slot=CreateFileA(ansi_path,GENERIC_READ,7,0,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_ATTRIBUTE_NORMAL,0);result=(ULONGLONG)*slot;break;
                case 28: result=GetFileInformationByHandle(*slot,(BY_HANDLE_FILE_INFORMATION *)(output+4));break;
                case 29: result=(ULONGLONG)CreateFileMappingW(*slot,0,PAGE_READONLY,0,4096,0);break;
                default:ExitProcess(210);
            }
            DWORD reply[]={GetLastError(),request[0]>=11?sizeof(output):600};emit(&result,sizeof(result));emit(reply,sizeof(reply));emit(output,reply[1]);
        }
    }
    require(FindFirstFileW((WCHAR *)1,data)==INVALID_HANDLE_VALUE&&GetLastError()==ERROR_ACCESS_DENIED,211);
    require(!FindNextFileW((HANDLE)1,(WIN32_FIND_DATAW *)1)&&GetLastError()==ERROR_ACCESS_DENIED,212);
    require(!FindClose((HANDLE)1)&&GetLastError()==ERROR_INVALID_HANDLE,213);
    require(FindFirstStreamW((WCHAR *)1,FindStreamInfoStandard,(void *)1,0)==INVALID_HANDLE_VALUE&&GetLastError()==ERROR_ACCESS_DENIED,227);
    require(!FindNextStreamW((HANDLE)1,(void *)1)&&GetLastError()==ERROR_ACCESS_DENIED,228);
    const char message[]="windows enumeration: denied\n";emit(message,sizeof(message)-1);ExitProcess(0);
}
