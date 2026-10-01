/* SDK declarations only; messages and allocated buffers come from our own APIs. */
#include <windows.h>
static void require(int condition,DWORD code) { if(!condition)ExitProcess(code); }
static void same(const WCHAR *actual,const WCHAR *expected,DWORD code) {
    for(unsigned n=0;;++n) { require(actual[n]==expected[n],code);if(!expected[n])break; }
}
void mainCRTStartup(void) {
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
    const char message[]="windows messages: system/string diagnostics, escapes, line widths and local buffers ok\n";
    DWORD written=0;require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),message,sizeof(message)-1,&written,0) && written==sizeof(message)-1,201);
    ExitProcess(0);
}
