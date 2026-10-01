/* SDK declarations only; messages and allocated buffers come from our own APIs. */
#include <windows.h>
#include <stdarg.h>
static void require(int condition,DWORD code) { if(!condition)ExitProcess(code); }
static void same(const WCHAR *actual,const WCHAR *expected,DWORD code) {
    for(unsigned n=0;;++n) { require(actual[n]==expected[n],code);if(!expected[n])break; }
}
static DWORD variadic(WCHAR *buffer,const WCHAR *source,...) {
    va_list arguments;va_start(arguments,source);
    DWORD count=FormatMessageW(FORMAT_MESSAGE_FROM_STRING,source,0,0,buffer,128,&arguments);
    va_end(arguments);return count;
}
static int mode(const char *name) {
    const char *line=GetCommandLineA();unsigned length=0,size=0;
    while(line[length])++length;while(name[size])++size;
    if(length<size+2 || line[length-1]!='"' || line[length-size-2]!='"')return 0;
    for(unsigned n=0;n<size;++n)if(line[length-size-1+n]!=name[n])return 0;
    return 1;
}
static int input(void *bytes,DWORD size,int eof) {
    DWORD offset=0;
    while(offset<size) {
        DWORD count=0;require(ReadFile(GetStdHandle(STD_INPUT_HANDLE),(char *)bytes+offset,size-offset,&count,0),198);
        if(!count) { require(eof && !offset,199);return 0; }offset+=count;
    }
    return 1;
}
static void output(const void *bytes,DWORD size) {
    DWORD count=0;require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),bytes,size,&count,0) && count==size,201);
}
static void oracle(void) {
    struct { DWORD flags,capacity,length,unused;ULONGLONG values[4];DWORD lengths[4]; } request;
    while(input(&request,sizeof(request),1)) {
        static WCHAR source[65536],strings[4][65536],buffer[65540];
        require(request.length<=65535,190);input(source,request.length*2,0);source[request.length]=0;
        for(unsigned n=0;n<4;++n)if(request.lengths[n]!=0xffffffff) {
            DWORD size=request.lengths[n]&0x7fffffff;require(size<=65535,191);
            if(request.lengths[n]&0x80000000) { input(strings[n],size,0);((char *)strings[n])[size]=0; }
            else { input(strings[n],size*2,0);strings[n][size]=0; }
            request.values[n]=(ULONGLONG)strings[n];
        }
        DWORD units=request.capacity<65536?request.capacity:65536;
        for(DWORD n=0;n<units+4;++n)buffer[n]=0xcafe;
        struct { ULONGLONG pointer,guard; } allocated={0xcafecafecafecafeULL,0xcafecafecafecafeULL};
        va_list arguments=(va_list)request.values;
        SetLastError(777);
        struct { DWORD result,error,units,allocation; } record={0,0,units+4,0};
        record.result=FormatMessageW(request.flags,source,0,0,request.flags&FORMAT_MESSAGE_ALLOCATE_BUFFER?(WCHAR *)&allocated.pointer:buffer+2,request.capacity,request.flags&FORMAT_MESSAGE_ARGUMENT_ARRAY?(va_list *)request.values:&arguments);
        record.error=GetLastError();
        if(request.flags&FORMAT_MESSAGE_ALLOCATE_BUFFER) {
            require(allocated.guard==0xcafecafecafecafeULL,192);
            if(allocated.pointer!=0xcafecafecafecafeULL) {
                require(allocated.pointer!=0 && (record.result || record.error==777),193);
                record.units=record.result+1;record.allocation=(DWORD)LocalSize((HLOCAL)allocated.pointer);
                output(&record,sizeof(record));output((void *)allocated.pointer,record.units*2);require(!LocalFree((HLOCAL)allocated.pointer),194);
            } else { require(!record.result,195);record.units=0;output(&record,sizeof(record)); }
        } else { output(&record,sizeof(record));output(buffer,record.units*2); }
    }
}
static void basic(void) {
    WCHAR buffer[128];SetLastError(777);
    DWORD count=FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM|FORMAT_MESSAGE_IGNORE_INSERTS,0,ERROR_ACCESS_DENIED,0,buffer,128,0);
    require(count==20 && GetLastError()==777,1);same(buffer,L"Access was denied.\r\n",2);
    buffer[0]=0xcafe;
    require(!FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM,0,0xffffffff,0,buffer,128,0) && GetLastError()==ERROR_MR_MID_NOT_FOUND && buffer[0]==0xcafe,3);
    require(!FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM,0,ERROR_ACCESS_DENIED,0x40c,buffer,128,0) && GetLastError()==ERROR_RESOURCE_LANG_NOT_FOUND && buffer[0]==0xcafe,4);
    require(!FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM,0,ERROR_ACCESS_DENIED,0,buffer,3,0) && GetLastError()==ERROR_INSUFFICIENT_BUFFER && buffer[0]==0xcafe,5);
    const WCHAR *source=L"é🚀 %% %1!s!%nnext%r%t%.%!%?%0ignored";
    const WCHAR *expected=L"é🚀 % %1!s!\r\nnext\r\t.!?";
    SetLastError(777);count=FormatMessageW(FORMAT_MESSAGE_FROM_STRING|FORMAT_MESSAGE_IGNORE_INSERTS,source,0xffffffff,0xffffffff,buffer,128,(va_list *)1);
    require(count!=0 && GetLastError()==777,6);same(buffer,expected,7);
    WCHAR *allocated=(WCHAR *)0xcafecafe;
    count=FormatMessageW(FORMAT_MESSAGE_FROM_STRING|FORMAT_MESSAGE_IGNORE_INSERTS|FORMAT_MESSAGE_ALLOCATE_BUFFER,source,0,0,(WCHAR *)&allocated,256,(va_list *)1);
    require(count!=0 && allocated && allocated!=(WCHAR *)0xcafecafe && LocalSize(allocated)>=512 && GetLastError()==777,8);
    same(allocated,expected,9);require(!LocalFree(allocated),10);
    count=FormatMessageW(FORMAT_MESSAGE_FROM_STRING|FORMAT_MESSAGE_MAX_WIDTH_MASK,L"one\r\ntwo%nthree",0,0,buffer,128,0);
    require(count==14,11);same(buffer,L"one two\r\nthree",12);
    count=FormatMessageW(FORMAT_MESSAGE_FROM_STRING|7,L"one two three%nlongerword end",0,0,buffer,128,0);
    require(count!=0,13);same(buffer,L"one two\r\nthree\r\nlongerword\r\nend",14);
    DWORD_PTR args[]={4,2,(DWORD_PTR)L"Bill",(DWORD_PTR)L"Bob",6,(DWORD_PTR)L"Bill"};
    count=FormatMessageW(FORMAT_MESSAGE_FROM_STRING|FORMAT_MESSAGE_ARGUMENT_ARRAY,L"%1!*.*s! %4 %5!*s!",0,0,buffer,128,(va_list *)args);
    require(count==15,15);same(buffer,L"  Bi Bob   Bill",16);
    count=variadic(buffer,L"%1!I64d! %2!08X! %3",(long long)(-9223372036854775807LL-1),0xabcdef,L"é🚀");
    require(count!=0,17);same(buffer,L"-9223372036854775808 00ABCDEF é🚀",18);
    DWORD_PTR last[99];for(unsigned n=0;n<99;++n)last[n]=(DWORD_PTR)L"z";last[98]=(DWORD_PTR)L"last";
    count=FormatMessageW(FORMAT_MESSAGE_FROM_STRING|FORMAT_MESSAGE_ARGUMENT_ARRAY,L"%99 %1 %99",0,0,buffer,128,(va_list *)last);
    require(count==11,19);same(buffer,L"last z last",20);
    buffer[0]=0xcafe;
    require(!FormatMessageW(FORMAT_MESSAGE_FROM_STRING,L"%1",0,0,buffer,128,0) && GetLastError()==ERROR_INVALID_PARAMETER && buffer[0]==0xcafe,27);
}
void mainCRTStartup(void) {
    basic();
    if(mode("oracle")) { oracle();ExitProcess(0); }
    if(mode("bad-arguments") || mode("bad-valist") || mode("bad-source")) {
        WCHAR buffer[128];DWORD flags=FORMAT_MESSAGE_FROM_STRING|(mode("bad-valist")?0:FORMAT_MESSAGE_ARGUMENT_ARRAY);
        FormatMessageW(flags,mode("bad-source")?(void *)1:L"%1",0,0,buffer,128,(va_list *)1);ExitProcess(28);
    }
    if(mode("precision")) {
        char *page=VirtualAlloc(0,4096,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);require(page!=0,23);
        page[4095]='Z';DWORD_PTR args[]={(DWORD_PTR)(page+4095)};WCHAR buffer[4];
        require(FormatMessageW(FORMAT_MESSAGE_FROM_STRING|FORMAT_MESSAGE_ARGUMENT_ARRAY,L"%1!.1hs!",0,0,buffer,4,(va_list *)args)==1 && buffer[0]=='Z' && !buffer[1],24);
        *(WCHAR *)(page+4094)='Z';args[0]=(DWORD_PTR)(page+4094);
        require(FormatMessageW(FORMAT_MESSAGE_FROM_STRING|FORMAT_MESSAGE_ARGUMENT_ARRAY,L"%1!.1s!",0,0,buffer,4,(va_list *)args)==1 && buffer[0]=='Z' && !buffer[1],25);
        args[0]=1;
        require(!FormatMessageW(FORMAT_MESSAGE_FROM_STRING|FORMAT_MESSAGE_ARGUMENT_ARRAY,L"%1!.0hs!",0,0,buffer,4,(va_list *)args) && !buffer[0],26);
        ExitProcess(0);
    }
    if(mode("fault")) {
        WCHAR *page=VirtualAlloc(0,4096,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);require(page!=0,21);
        FormatMessageW(FORMAT_MESSAGE_FROM_STRING,L"abcdef",0,0,page+2047,32,0);ExitProcess(22);
    }
    const char message[]="windows messages: diagnostics, typed inserts, escapes, line widths and local buffers ok\n";
    output(message,sizeof(message)-1);
    ExitProcess(0);
}
