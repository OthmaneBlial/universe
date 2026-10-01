/* Windows SDK IOCTL declarations; no vendor runtime or device driver code. */
#include <windows.h>
#include <winioctl.h>
_Static_assert(FSCTL_GET_REPARSE_POINT==0x900a8,"reparse control code");
_Static_assert(IO_REPARSE_TAG_SYMLINK==0xa000000c,"symlink reparse tag");
_Static_assert(MAXIMUM_REPARSE_DATA_BUFFER_SIZE==16384,"reparse size limit");
static WCHAR path[32768];static BYTE output[16392];static HANDLE handles[4];
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
    if(mode("denied")) {
        require(!DeviceIoControl((HANDLE)1,FSCTL_GET_REPARSE_POINT,(void *)1,1,(void *)1,16384,(DWORD *)1,(OVERLAPPED *)1)&&GetLastError()==ERROR_ACCESS_DENIED,203);
        const char text[]="windows device: denied\n";emit(text,sizeof(text)-1);ExitProcess(0);
    }
    if(mode("output-fault")||mode("count-fault")) {
        HANDLE h=CreateFileW(L"file-link",0,7,0,OPEN_EXISTING,FILE_FLAG_OPEN_REPARSE_POINT|FILE_FLAG_BACKUP_SEMANTICS,0);require(h!=INVALID_HANDLE_VALUE,204);
        BYTE *p=VirtualAlloc(0,4096,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);require(p!=0,205);DWORD count;
        DeviceIoControl(h,FSCTL_GET_REPARSE_POINT,0,0,mode("output-fault")?p+4094:output+4,16384,mode("count-fault")?(DWORD *)(p+4094):&count,0);ExitProcess(206);
    }
    for(;;) {
        DWORD request[6],done=0;
        while(done<sizeof(request)) { DWORD n;require(ReadFile(GetStdHandle(STD_INPUT_HANDLE),(char *)request+done,sizeof(request)-done,&n,0),207);
            if(!n) { require(!done,208);ExitProcess(0); }done+=n; }
        require(request[1]<4&&request[5]<32768,209);read_all(path,request[5]*2);path[request[5]]=0;
        read_all(output,sizeof(output)); // Native-fed guards avoid millions of guest memset instructions.
        HANDLE *slot=&handles[request[1]];DWORD argument=request[4],count=0xa5a5a5a5;SetLastError(777);ULONGLONG result=0;
        switch(request[0]) {
            case 0: case 7: *slot=CreateFileW(path,(argument&1?GENERIC_READ:0)|(argument&2?GENERIC_WRITE:0),(argument>>2)&7,0,OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS|(request[0]==0?FILE_FLAG_OPEN_REPARSE_POINT:0),0);result=(ULONGLONG)*slot;break;
            case 1: case 8: {
                HANDLE h=request[0]==1?*slot:argument==0?0:argument==1?INVALID_HANDLE_VALUE:argument==2?GetStdHandle(STD_OUTPUT_HANDLE):GetCurrentThread();
                result=DeviceIoControl(h,request[2],argument&64?(void *)1:0,argument&32?1:0,
                    argument&1?0:argument&4?(void *)1:output+4,request[3],argument&2?0:argument&8?(DWORD *)1:&count,argument&16?(OVERLAPPED *)1:0);break;
            }
            case 2: result=CloseHandle(*slot);break;
            case 3: *slot=CreateEventW(0,0,1,0);result=(ULONGLONG)*slot;break;
            case 4: *slot=FindFirstFileW(path,(WIN32_FIND_DATAW *)(output+4));result=(ULONGLONG)*slot;break;
            case 5: result=MoveFileW(path,L"moved-link");break;
            case 6: result=DeleteFileW(path);break;
            case 9: result=FindClose(*slot);break;
            default:ExitProcess(210);
        }
        DWORD reply[]={GetLastError(),count};emit(&result,sizeof(result));emit(reply,sizeof(reply));emit(output,sizeof(output));
    }
}
