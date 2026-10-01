/* SDK declarations only: calendar, clock and file-time calls use our own runtime. */
#include <windows.h>
_Static_assert(sizeof(FILETIME)==8 && sizeof(SYSTEMTIME)==16,"Win32 time ABI");
static void require(int condition,DWORD code) { if(!condition)ExitProcess(code); }
static FILETIME stamp(ULONGLONG ticks) { FILETIME time={(DWORD)ticks,(DWORD)(ticks>>32)};return time; }
static ULONGLONG ticks(FILETIME time) { return ((ULONGLONG)time.dwHighDateTime<<32)|time.dwLowDateTime; }
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
static int input(void *bytes,DWORD size) {
    DWORD total=0;
    while(total<size) {
        DWORD count=0;require(ReadFile(GetStdHandle(STD_INPUT_HANDLE),(char *)bytes+total,size-total,&count,0),202);
        if(!count) { require(!total,203);return 0; }total+=count;
    }
    return 1;
}
static void calendar_stream(void) {
    if(mode("ticks")) {
        FILETIME time;
        while(input(&time,sizeof(time))) {
            struct { DWORD ok,error;SYSTEMTIME fields; } result={0,0,{0xcafe,0xcafe,0xcafe,0xcafe,0xcafe,0xcafe,0xcafe,0xcafe}};
            SetLastError(777);result.ok=FileTimeToSystemTime(&time,&result.fields);result.error=GetLastError();output(&result,sizeof(result));
        }
    } else if(mode("system")) {
        SYSTEMTIME fields;
        while(input(&fields,sizeof(fields))) {
            struct { DWORD ok,error;FILETIME time; } result={0,0,{0x89abcdef,0x1234567}};
            SetLastError(777);result.ok=SystemTimeToFileTime(&fields,&result.time);result.error=GetLastError();output(&result,sizeof(result));
        }
    } else {
        WORD words[2];
        while(input(words,sizeof(words))) {
            struct { DWORD ok,error;FILETIME time;WORD date,clock; } result={0,0,{0x89abcdef,0x1234567},0xcafe,0xcafe};
            SetLastError(777);result.ok=DosDateTimeToFileTime(words[0],words[1],&result.time);result.error=GetLastError();
            if(result.ok)require(FileTimeToDosDateTime(&result.time,&result.date,&result.clock),204);
            output(&result,sizeof(result));
        }
    }
    ExitProcess(0);
}
static void file_times(void) {
    const WCHAR *name=L"time é🚀.bin";
    HANDLE file=CreateFileW(name,GENERIC_READ|GENERIC_WRITE,7,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
    if(file==INVALID_HANDLE_VALUE) {
        require(GetLastError()==ERROR_ACCESS_DENIED,50);
        const char message[]="windows file time: denied\n";output(message,sizeof(message)-1);ExitProcess(0);
    }
    DWORD count=0;require(WriteFile(file,"abc",3,&count,0) && count==3,51);
    HANDLE read=CreateFileW(name,GENERIC_READ|FILE_READ_ATTRIBUTES,7,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    HANDLE attributes=CreateFileW(name,FILE_WRITE_ATTRIBUTES,7,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
    require(read!=INVALID_HANDLE_VALUE && attributes!=INVALID_HANDLE_VALUE,52);
    SYSTEMTIME fields={1999,12,0,31,23,59,59,123};FILETIME created,access,write;
    require(SystemTimeToFileTime(&fields,&created),53);
    fields.wYear=2000;fields.wMonth=2;fields.wDay=29;require(SystemTimeToFileTime(&fields,&access),54);
    fields.wYear=2001;require(!SystemTimeToFileTime(&fields,&write) && GetLastError()==ERROR_INVALID_PARAMETER,55);
    fields.wMonth=3;fields.wDay=1;require(SystemTimeToFileTime(&fields,&write),56);
    require(!SetFileTime(read,0,0,&write) && GetLastError()==ERROR_ACCESS_DENIED,57);
    if(!SetFileTime(attributes,&created,&access,&write)) {
        require(GetLastError()==ERROR_NOT_SUPPORTED,58); /* Linux host cannot set birth time. */
        require(SetFileTime(attributes,0,&access,&write),59);
    }
    FILETIME zero=stamp(0),freeze=stamp(~(ULONGLONG)0),bad=stamp(0x8000000000000000ULL);
    require(SetFileTime(attributes,&zero,&zero,&zero) && GetFileTime(file,0,0,0),60);
    FILETIME got[3];require(GetFileTime(file,&got[0],&got[1],&got[2]) && ticks(got[1])==ticks(access) && ticks(got[2])==ticks(write),61);
    require(!SetFileTime(attributes,&bad,0,0) && GetLastError()==ERROR_INVALID_PARAMETER,62);
    require(!SetFileTime(attributes,0,&zero,&bad) && GetLastError()==ERROR_INVALID_PARAMETER,63);
    require(SetFileTime(file,0,&freeze,&freeze),64);
    require(SetFilePointer(file,0,0,FILE_BEGIN)==0,65);char byte=0;
    require(ReadFile(file,&byte,1,&count,0) && byte=='a' && count==1,66);
    require(WriteFile(file,"Z",1,&count,0) && count==1 && SetFilePointer(file,5,0,FILE_BEGIN)==5 && SetEndOfFile(file),67);
    require(GetFileTime(file,0,&got[1],&got[2]) && ticks(got[1])==ticks(access) && ticks(got[2])==ticks(write),68);
    fields.wYear=2002;fields.wMonth=4;fields.wDay=5;require(SystemTimeToFileTime(&fields,&write),69);
    require(SetFileTime(attributes,0,0,&write) && SetFileTime(file,0,&zero,&zero),70);
    require(WriteFile(file,"!",1,&count,0) && GetFileTime(file,&got[0],&got[1],&got[2]) && ticks(got[1])==ticks(access) && ticks(got[2])==ticks(write),71);
    output(got,sizeof(got));require(CloseHandle(attributes) && CloseHandle(read) && CloseHandle(file),72);ExitProcess(0);
}
void mainCRTStartup(void) {
    if(mode("ticks") || mode("system") || mode("dos"))calendar_stream();
    if(mode("files"))file_times();
    FILETIME time=stamp(0),back=stamp(0);SYSTEMTIME fields;
    require(FileTimeToSystemTime(&time,&fields) && fields.wYear==1601 && fields.wMonth==1 && fields.wDay==1 && fields.wDayOfWeek==1,1);
    fields.wDayOfWeek=65535;require(SystemTimeToFileTime(&fields,&back) && ticks(back)==0,2);
    time=stamp(0x8000000000000000ULL);fields.wYear=1234;
    require(!FileTimeToSystemTime(&time,&fields) && GetLastError()==ERROR_INVALID_PARAMETER && fields.wYear==1234,3);
    fields=(SYSTEMTIME){2000,2,0,29,23,59,59,987};SetLastError(777);
    require(SystemTimeToFileTime(&fields,&time) && GetLastError()==777,4);
    WORD date=0,clock=0;require(FileTimeToDosDateTime(&time,&date,&clock) && DosDateTimeToFileTime(date,clock,&back) && ticks(time)-ticks(back)==19870000,5);
    back=stamp(99);require(!DosDateTimeToFileTime(0,0,&back) && GetLastError()==ERROR_INVALID_PARAMETER && ticks(back)==99,6);
    require(!DosDateTimeToFileTime(date,31,&back) && GetLastError()==ERROR_INVALID_PARAMETER,7);
    require(!FileTimeToLocalFileTime(&time,&time) && !LocalFileTimeToFileTime(&time,&time) && GetLastError()==ERROR_INVALID_PARAMETER,8);
    time=stamp(116444736000000123ULL);SetLastError(777);
    require(FileTimeToLocalFileTime(&time,&back) && LocalFileTimeToFileTime(&back,&back)==0 && GetLastError()==ERROR_INVALID_PARAMETER,9);
    FILETIME epoch_local=back,roundtrip;require(LocalFileTimeToFileTime(&back,&roundtrip) && ticks(roundtrip)==ticks(time),10);
    SetLastError(777);require(CompareFileTime(&back,&back)==0 && CompareFileTime(&time,&roundtrip)==0 && GetLastError()==777,11);
    time=stamp(ticks(roundtrip)+1);require(CompareFileTime(&time,&roundtrip)==1 && CompareFileTime(&roundtrip,&time)==-1,12);
    FILETIME before_kernel,before_user,created,exited;
    require(GetProcessTimes(GetCurrentProcess(),&created,&exited,&before_kernel,&before_user),13);
    volatile DWORD work=0;for(DWORD n=0;n<10000;++n)work+=n;
    FILETIME values[10];GetSystemTimeAsFileTime(&values[0]);GetSystemTimePreciseAsFileTime(&values[2]);
    GetSystemTime(&fields);require(SystemTimeToFileTime(&fields,&values[3]),14);
    GetLocalTime(&fields);require(SystemTimeToFileTime(&fields,&values[9]) && LocalFileTimeToFileTime(&values[9],&values[4]),15);
    require(GetProcessTimes(GetCurrentProcess(),&values[5],&values[6],&values[7],&values[8]),16);
    require(!GetProcessTimes((HANDLE)1234,&created,&exited,&before_kernel,&before_user) && GetLastError()==ERROR_INVALID_HANDLE,17);
    GetSystemTimeAsFileTime(&values[1]);
    require(ticks(values[5])<=ticks(values[0]) && ticks(values[6])==0 && ticks(values[7])>=ticks(before_kernel) && ticks(values[8])>=ticks(before_user),18);
    if(mode("clocks")) { output(values,sizeof(values));output(&epoch_local,sizeof(epoch_local)); }
    const char message[]="windows time: checked calendars, local/UTC conversion and process clocks ok\n";
    output(message,sizeof(message)-1);ExitProcess(0);
}
