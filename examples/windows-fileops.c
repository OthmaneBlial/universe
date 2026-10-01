/* Windows SDK declarations only; every operation executes through UNIVERSE. */
#include <windows.h>
#include <stddef.h>
_Static_assert(sizeof(BY_HANDLE_FILE_INFORMATION)==52 && offsetof(BY_HANDLE_FILE_INFORMATION,nFileIndexLow)==48,"Windows file metadata ABI");
static void require(int condition,DWORD code) { if (!condition) ExitProcess(code); }
static int mode(const char *name) {
    const char *line=GetCommandLineA(); unsigned length=0;
    while(line[length])++length;
    unsigned size=0;while(name[size])++size;
    if(length<size+2 || line[length-1]!='"' || line[length-size-2]!='"')return 0;
    for(unsigned n=0;n<size;++n)if(line[length-size-1+n]!=name[n])return 0;
    return 1;
}
static const WCHAR *raw[]={L"ops é🚀",L"moved é🚀",L"ops é🚀/source.bin",L"ops é🚀/renamed.bin",L"ops é🚀/collision.bin",L"ops é🚀/alias.bin",L"ops é🚀/replacement.bin",L"ops é🚀/information.bin",L"pending",L"pending/file.bin",L"relocated",L"exit-pending.bin",L"link.bin"};
static WCHAR names[sizeof(raw)/sizeof(*raw)][80];
static HANDLE open_file(unsigned index,DWORD access,DWORD share,DWORD disposition) { return CreateFileW(names[index],access,share,0,disposition,FILE_ATTRIBUTE_NORMAL,0); }
static void write_bytes(HANDLE handle,const void *bytes,DWORD size,DWORD code) { DWORD written=0;require(WriteFile(handle,bytes,size,&written,0) && written==size,code); }
typedef struct { ULARGE_INTEGER available,total,free;DWORD sectors,bytes,free_clusters,clusters; } DiskRecord;
_Static_assert(sizeof(DiskRecord)==40,"disk query oracle record");
static void disk_query(const WCHAR *path,DiskRecord *record) {
    SetLastError(777);
    require(GetDiskFreeSpaceExW(path,&record->available,&record->total,&record->free) && GetLastError()==777,100);
    require(GetDiskFreeSpaceW(path,&record->sectors,&record->bytes,&record->free_clusters,&record->clusters) && GetLastError()==777,101);
}
static DWORD WINAPI progress(LARGE_INTEGER total,LARGE_INTEGER transferred,LARGE_INTEGER stream,LARGE_INTEGER done,DWORD number,DWORD reason,HANDLE source,HANDLE destination,LPVOID data) {
    (void)total;(void)transferred;(void)stream;(void)done;(void)number;(void)reason;(void)source;(void)destination;(void)data; ExitProcess(200);
}
void mainCRTStartup(void) {
    unsigned absolute=mode("absolute") || mode("disk-absolute") || mode("drive-absolute") || mode("disk-drive-absolute");
    unsigned drive=mode("drive-relative") || mode("drive-absolute") || mode("disk-drive-relative") || mode("disk-drive-absolute");
    unsigned prefix=drive?2+absolute:absolute;
    for(unsigned n=0;n<sizeof(raw)/sizeof(*raw);++n) {
        if(drive) { names[n][0]=absolute?'c':'C';names[n][1]=':'; }
        if(absolute)names[n][prefix-1]=drive?'\\':'/';
        unsigned count=0;while(raw[n][count]) { names[n][prefix+count]=raw[n][count];++count; }
        names[n][prefix+count]=0;
    }
    if(mode("disk") || mode("disk-absolute") || mode("disk-drive-relative") || mode("disk-drive-absolute") || mode("disk-fault")) {
        DiskRecord records[3];records[0].available.QuadPart=11;records[0].total.QuadPart=22;records[0].free.QuadPart=33;
        if(!GetDiskFreeSpaceExW(0,&records[0].available,&records[0].total,&records[0].free)) {
            require(GetLastError()==ERROR_ACCESS_DENIED && records[0].available.QuadPart==11 && records[0].total.QuadPart==22 && records[0].free.QuadPart==33,102);
            require(!GetDiskFreeSpaceW(0,0,0,0,0) && GetLastError()==ERROR_ACCESS_DENIED,103);
            const char message[]="windows disk: denied\n";write_bytes(GetStdHandle(STD_OUTPUT_HANDLE),message,sizeof(message)-1,104);ExitProcess(0);
        }
        if(mode("disk-fault")) { GetDiskFreeSpaceW(0,&records[0].sectors,&records[0].bytes,&records[0].free_clusters,0);ExitProcess(105); }
        disk_query(0,&records[0]);disk_query(names[0],&records[1]);disk_query(names[1],&records[2]);
        for(unsigned mask=0;mask<8;++mask) {
            ULARGE_INTEGER available,total,free;available.QuadPart=11;total.QuadPart=22;free.QuadPart=33;SetLastError(777);
            require(GetDiskFreeSpaceExW(names[0],mask&1?&available:0,mask&2?&total:0,mask&4?&free:0) && GetLastError()==777,106);
            require((mask&1 || available.QuadPart==11) && (mask&2 || total.QuadPart==22) && (mask&4 || free.QuadPart==33),107);
        }
        ULARGE_INTEGER available,total,free;available.QuadPart=11;total.QuadPart=22;free.QuadPart=33;
        require(!GetDiskFreeSpaceExW(names[2],&available,&total,&free) && GetLastError()==ERROR_DIRECTORY && available.QuadPart==11 && total.QuadPart==22 && free.QuadPart==33,108);
        require(!GetDiskFreeSpaceExW(L"missing-disk-dir",0,0,0) && GetLastError()==ERROR_PATH_NOT_FOUND,109);
        require(!GetDiskFreeSpaceExW(L"",0,0,0) && GetLastError()==ERROR_PATH_NOT_FOUND,110);
        require(!GetDiskFreeSpaceExW(L"D:\\",0,0,0) && GetLastError()==ERROR_INVALID_DRIVE,111);
        require(!GetDiskFreeSpaceExW(L"\\\\server\\share\\",0,0,0) && GetLastError()==ERROR_NOT_SUPPORTED,112);
        write_bytes(GetStdHandle(STD_OUTPUT_HANDLE),records,sizeof(records),113);ExitProcess(0);
    }
    if(!CreateDirectoryW(names[0],0)) {
        require(GetLastError()==ERROR_ACCESS_DENIED,1);
        require(!MoveFileW(names[2],names[3]) && GetLastError()==ERROR_ACCESS_DENIED,2);
        require(!MoveFileExW(names[2],names[3],0) && !MoveFileWithProgressW(names[2],names[3],0,0,0),3);
        require(!CreateHardLinkW(names[5],names[2],0) && !DeleteFileW(names[2]) && !RemoveDirectoryW(names[0]),4);
        require(GetFileAttributesW(names[2])==INVALID_FILE_ATTRIBUTES && GetLastError()==ERROR_ACCESS_DENIED && !SetFileAttributesW(names[2],FILE_ATTRIBUTE_READONLY),5);
        const char message[]="windows fileops: denied\n";write_bytes(GetStdHandle(STD_OUTPUT_HANDLE),message,sizeof(message)-1,6);ExitProcess(0);
    }
    require(GetFileAttributesW(names[0])==FILE_ATTRIBUTE_DIRECTORY && !CreateDirectoryW(names[0],0) && GetLastError()==ERROR_ALREADY_EXISTS,7);
    require(!CreateDirectoryW(L"missing-parent/child",0) && GetLastError()==ERROR_PATH_NOT_FOUND && !DeleteFileW(names[0]) && GetLastError()==ERROR_ACCESS_DENIED,8);
    SECURITY_ATTRIBUTES security={sizeof(security),0,FALSE};
    require(!CreateDirectoryW(names[8],&security) && GetLastError()==ERROR_NOT_SUPPORTED,9);
    HANDLE file=open_file(2,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,CREATE_NEW);
    require(file!=INVALID_HANDLE_VALUE,10);write_bytes(file,"alpha",5,11);
    require(!MoveFileW(names[2],names[3]) && GetLastError()==ERROR_SHARING_VIOLATION && !DeleteFileW(names[2]) && GetLastError()==ERROR_SHARING_VIOLATION,12);
    require(CreateHardLinkW(names[5],names[2],0) && CloseHandle(file),13);
    HANDLE collision=open_file(4,GENERIC_WRITE,3,CREATE_NEW);require(collision!=INVALID_HANDLE_VALUE,14);write_bytes(collision,"omega",5,15);require(CloseHandle(collision),16);
    require(!MoveFileW(names[2],names[4]) && GetLastError()==ERROR_ALREADY_EXISTS && GetFileAttributesW(names[2])==FILE_ATTRIBUTE_NORMAL,17);
    require(MoveFileW(names[2],names[3]) && GetFileAttributesW(names[2])==INVALID_FILE_ATTRIBUTES && GetLastError()==ERROR_FILE_NOT_FOUND,18);
    file=open_file(3,GENERIC_READ|GENERIC_WRITE,7,OPEN_EXISTING);HANDLE alias=open_file(5,GENERIC_READ,7,OPEN_EXISTING);
    require(file!=INVALID_HANDLE_VALUE && alias!=INVALID_HANDLE_VALUE,19);
    BY_HANDLE_FILE_INFORMATION info,alias_info;
    require(GetFileInformationByHandle(file,&info) && GetFileInformationByHandle(alias,&alias_info) && info.nNumberOfLinks==2 && info.nFileSizeLow==5 && info.nFileSizeHigh==0,20);
    require(info.dwVolumeSerialNumber==alias_info.dwVolumeSerialNumber && info.nFileIndexHigh==alias_info.nFileIndexHigh && info.nFileIndexLow==alias_info.nFileIndexLow,21);
    DWORD high=99;require(GetFileSize(file,&high)==5 && !high && GetFileSize(file,0)==5,22);
    require(SetFilePointer(file,2,0,FILE_BEGIN)==2 && SetEndOfFile(file),23);write_bytes(file,"Z",1,24);
    require(SetFilePointer(file,8,0,FILE_BEGIN)==8 && SetEndOfFile(file),25);
    require(SetFilePointer(file,-9,0,FILE_CURRENT)==INVALID_SET_FILE_POINTER && GetLastError()==ERROR_NEGATIVE_SEEK && SetFilePointer(file,0,0,FILE_CURRENT)==8,26);
    LONG upper=0;SetLastError(555);
    require(SetFilePointer(file,-1,&upper,FILE_BEGIN)==0xffffffff && GetLastError()==NO_ERROR && upper==0 && SetEndOfFile(file),27);
    SetLastError(555);require(GetFileSize(file,&high)==0xffffffff && GetLastError()==NO_ERROR && high==0,28);
    upper=1;require(SetFilePointer(file,7,&upper,FILE_BEGIN)==7 && upper==1 && SetEndOfFile(file) && GetFileSize(file,&high)==7 && high==1,29);
    require(SetFilePointer(file,0,0,FILE_END)==INVALID_SET_FILE_POINTER && GetLastError()==ERROR_INVALID_PARAMETER,30);
    upper=0;require(SetFilePointer(file,0,&upper,FILE_CURRENT)==7 && upper==1,31);
    require(SetFilePointer(file,8,0,FILE_BEGIN)==8 && SetEndOfFile(file) && CloseHandle(alias) && CloseHandle(file),32);
    require(DeleteFileW(names[5]) && !DeleteFileW(names[5]) && GetLastError()==ERROR_FILE_NOT_FOUND,33);
    require(SetFileAttributesW(names[3],FILE_ATTRIBUTE_READONLY) && GetFileAttributesW(names[3])==FILE_ATTRIBUTE_READONLY && !DeleteFileW(names[3]) && GetLastError()==ERROR_ACCESS_DENIED,34);
    require(open_file(3,GENERIC_WRITE,7,OPEN_EXISTING)==INVALID_HANDLE_VALUE && GetLastError()==ERROR_ACCESS_DENIED && SetFileAttributesW(names[3],FILE_ATTRIBUTE_NORMAL),35);
    require(!SetFileAttributesW(names[3],FILE_ATTRIBUTE_HIDDEN) && GetLastError()==ERROR_NOT_SUPPORTED && GetFileAttributesW(names[3])==FILE_ATTRIBUTE_NORMAL,36);
    file=open_file(3,GENERIC_READ,7,OPEN_EXISTING);require(file!=INVALID_HANDLE_VALUE && !SetEndOfFile(file) && GetLastError()==ERROR_ACCESS_DENIED && GetFileInformationByHandle(file,&info),37);
    HANDLE record=open_file(7,GENERIC_WRITE,3,CREATE_NEW);require(record!=INVALID_HANDLE_VALUE,38);write_bytes(record,&info,sizeof(info),39);require(CloseHandle(record) && CloseHandle(file),40);
    HANDLE replacement=open_file(6,GENERIC_WRITE,3,CREATE_NEW);require(replacement!=INVALID_HANDLE_VALUE,41);write_bytes(replacement,"beta",4,42);require(CloseHandle(replacement),43);
    require(!MoveFileWithProgressW(names[6],names[4],progress,0,MOVEFILE_REPLACE_EXISTING) && GetLastError()==ERROR_NOT_SUPPORTED,44);
    require(!MoveFileExW(names[6],names[4],MOVEFILE_DELAY_UNTIL_REBOOT) && GetLastError()==ERROR_NOT_SUPPORTED,45);
    require(MoveFileWithProgressW(names[6],names[4],0,0,MOVEFILE_REPLACE_EXISTING|MOVEFILE_WRITE_THROUGH),46);
    require(!RemoveDirectoryW(names[4]) && GetLastError()==ERROR_DIRECTORY && !RemoveDirectoryW(names[0]) && GetLastError()==ERROR_DIR_NOT_EMPTY,47);
    require(MoveFileExW(names[0],names[1],MOVEFILE_COPY_ALLOWED) && GetFileAttributesW(names[1])==FILE_ATTRIBUTE_DIRECTORY,48);
    require(CreateDirectoryW(names[8],0),49);
    file=open_file(9,GENERIC_READ|GENERIC_WRITE,7,CREATE_NEW);HANDLE second=open_file(9,GENERIC_READ,7,OPEN_EXISTING);require(file!=INVALID_HANDLE_VALUE && second!=INVALID_HANDLE_VALUE,50);write_bytes(file,"pending",7,51);
    require(DeleteFileW(names[9]) && !DeleteFileW(names[9]) && GetLastError()==ERROR_ACCESS_DENIED && open_file(9,GENERIC_READ,7,OPEN_EXISTING)==INVALID_HANDLE_VALUE && GetLastError()==ERROR_ACCESS_DENIED,52);
    require(!MoveFileW(names[9],names[11]) && GetLastError()==ERROR_ACCESS_DENIED && CloseHandle(file) && GetFileSize(second,0)==7,53);
    require(MoveFileW(names[8],names[10]) && CloseHandle(second) && RemoveDirectoryW(names[10]),54);
    require(DeleteFileW(names[12]),55); /* Host supplies a symlink; only the link must disappear. */
    file=open_file(11,GENERIC_WRITE,7,CREATE_NEW);require(file!=INVALID_HANDLE_VALUE && DeleteFileW(names[11]),56); /* Process termination closes and deletes it. */
    const char message[]="windows fileops: no-overwrite moves, links, pending deletion, metadata and sparse seeks ok\n";
    write_bytes(GetStdHandle(STD_OUTPUT_HANDLE),message,sizeof(message)-1,57);ExitProcess(0);
}
