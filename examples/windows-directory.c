/* SDK declarations only; filesystem operations execute through UNIVERSE. */
#include <windows.h>
static WCHAR path[32770],output[32770];
static void require(int value,DWORD code) { if(!value)ExitProcess(code); }
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
    if(mode("drive-fault") || mode("drive-ansi-fault")) {
        char *p=VirtualAlloc(0,4096,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);require(p!=0,215);
        if(mode("drive-ansi-fault"))GetLogicalDriveStringsA(5,p+4095);else GetLogicalDriveStringsW(5,(WCHAR *)(p+4094));ExitProcess(216);
    }
    if(mode("fault") || mode("temp-fault")) {
        WCHAR *p=VirtualAlloc(0,4096,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);require(p!=0,203);
        if(mode("temp-fault"))GetTempPathW(32768,p+2047);else GetCurrentDirectoryW(32768,p+2047);ExitProcess(204);
    }
    if(mode("source-fault")) { SetCurrentDirectoryW((WCHAR *)1);ExitProcess(205); }
    if(mode("oracle")) {
        for(;;) {
            DWORD request[3],done=0;
            while(done<sizeof(request)) { DWORD n;
                require(ReadFile(GetStdHandle(STD_INPUT_HANDLE),(char *)request+done,sizeof(request)-done,&n,0),206);
                if(!n) { require(!done,207);ExitProcess(0); }done+=n;
            }
            require(request[1]<32768&&request[2]<=32768,207);
            read_all(path,request[1]*2);path[request[1]]=0;
            for(DWORD i=0;i<request[2]+2;++i)output[i]=0xa55a;
            SetLastError(777);DWORD result=0,units=0;
            switch(request[0]) {
                case 0:result=GetCurrentDirectoryW(request[2],output);units=request[2]+2;break;
                case 1:result=SetCurrentDirectoryW(path);break;
                case 2: {
                    HANDLE file=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,0,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,0);
                    result=file!=INVALID_HANDLE_VALUE;
                    if(result) { const char bytes[]="directory bytes";DWORD written;
                        require(WriteFile(file,bytes,sizeof(bytes)-1,&written,0)&&written==sizeof(bytes)-1&&CloseHandle(file),208); }
                    break;
                }
                case 3:result=RemoveDirectoryW(path);break;
                case 4:result=MoveFileW(path,L"moved-current");break;
                case 5:result=SetCurrentDirectoryW(0);break;
                case 6:result=GetCurrentDirectoryW(request[2],(WCHAR *)1);break;
                case 7:result=GetTempPathW(request[2],output);units=request[2]+2;break;
                case 8:result=GetTempPathW(request[2],(WCHAR *)1);break;
                case 9: {
                    HMODULE module=LoadLibraryW(path);require(module!=0,213);
                    long (*add)(long)=(long (*)(long))GetProcAddress(module,"helper_add");
                    require(add && add(5)==13 && FreeLibrary(module),214);
                    result=1;SetLastError(777);break;
                }
                case 10:result=GetLogicalDriveStringsW(request[2],output);units=request[2]+2;break;
                case 11:result=GetLogicalDriveStringsA(request[2],(char *)output);units=request[2]+2;break;
                case 12:result=GetLogicalDrives();break;
                case 13:result=GetLogicalDriveStringsW(request[2],(WCHAR *)1);break;
                case 14:result=GetLogicalDriveStringsA(request[2],(char *)1);break;
                case 15:result=GetLogicalDriveStringsW(request[2],0);break;
                case 16:result=GetLogicalDriveStringsA(request[2],0);break;
                case 17: {
                    WCHAR drive[5];require(GetLogicalDriveStringsW(5,drive)==4&&GetLogicalDrives()==4&&SetCurrentDirectoryW(drive),217);
                    result=GetCurrentDirectoryW(request[2],output);units=request[2]+2;break;
                }
                case 18: {
                    WCHAR drive[5];require(GetLogicalDriveStringsW(5,drive)==4,218);
                    result=GetDiskFreeSpaceExW(drive,(ULARGE_INTEGER *)(output+2),(ULARGE_INTEGER *)(output+6),(ULARGE_INTEGER *)(output+10));units=request[2]+2;break;
                }
                case 19: {
                    WCHAR drive[5];require(GetLogicalDriveStringsW(5,drive)==4,219);result=GetFileAttributesW(drive);break;
                }
                default:ExitProcess(209);
            }
            DWORD reply[]={result,GetLastError(),units,0};emit(reply,sizeof(reply));if(units)emit(output,units*2);
        }
    }
    require(!GetCurrentDirectoryW(0,0)&&GetLastError()==ERROR_ACCESS_DENIED,210);
    require(!SetCurrentDirectoryW((WCHAR *)1)&&GetLastError()==ERROR_ACCESS_DENIED,211);
    require(!GetTempPathW(0,0)&&GetLastError()==ERROR_ACCESS_DENIED,212);
    require(!GetLogicalDriveStringsW(5,(WCHAR *)1)&&GetLastError()==ERROR_ACCESS_DENIED,220);
    require(!GetLogicalDriveStringsA(5,(char *)1)&&GetLastError()==ERROR_ACCESS_DENIED,221);
    require(!GetLogicalDrives()&&GetLastError()==ERROR_ACCESS_DENIED,222);
    const char message[]="windows directories: denied\n";emit(message,sizeof(message)-1);ExitProcess(0);
}
