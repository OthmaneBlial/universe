/* SDK only: actual pipes, terminal modes and guest control callbacks. */
#include <windows.h>
static HANDLE event_handle;
static volatile DWORD order,counter,expected_event;
static void require(int condition,DWORD code) { if(!condition)ExitProcess(code); }
static void output(const void *bytes,DWORD size) {
    DWORD count=0;require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),bytes,size,&count,0) && count==size,200);
}
static int mode(const char *name) {
    const char *line=GetCommandLineA();unsigned length=0,size=0;
    while(line[length])++length;while(name[size])++size;
    if(length<size+2 || line[length-1]!='"' || line[length-size-2]!='"')return 0;
    for(unsigned n=0;n<size;++n)if(line[length-size-1+n]!=name[n])return 0;return 1;
}
static BOOL WINAPI oldest(DWORD type) {
    require(type==expected_event,100);order=order*10+1;output("1",1);
    require(SetEvent(event_handle),101);SetLastError(555);return TRUE;
}
static BOOL WINAPI middle(DWORD type) { require(type==expected_event,102);order=order*10+2;output("2",1);return FALSE; }
static BOOL WINAPI newest(DWORD type) { require(type==expected_event,103);order=order*10+3;output("3",1);return FALSE; }
static BOOL WINAPI threshold(DWORD type) {
    require(type==CTRL_C_EVENT,104);char byte=(char)('0'+(++counter));output(&byte,1);return counter<3;
}
void mainCRTStartup(void) {
    HANDLE input=GetStdHandle(STD_INPUT_HANDLE),out=GetStdHandle(STD_OUTPUT_HANDLE);
    if(mode("tty") || mode("tty-fault")) {
        DWORD flags=99,count=0;SetLastError(777);
        require(GetFileType(input)==FILE_TYPE_CHAR && GetConsoleMode(input,&flags) && flags==7 && GetLastError()==777,1);
        require(!SetConsoleMode(input,ENABLE_ECHO_INPUT) && GetLastError()==ERROR_INVALID_PARAMETER,2);
        require(!SetConsoleMode(input,ENABLE_WINDOW_INPUT) && GetLastError()==ERROR_NOT_SUPPORTED,3);
        require(GetConsoleMode(input,&flags) && flags==7 && SetConsoleMode(input,0),4);
        require(GetConsoleMode(input,&flags) && flags==0,5);output("RAW\n",4);
        char bytes[16];require(ReadFile(input,bytes,1,&count,0) && count==1 && bytes[0]=='Z',6);
        if(mode("tty-fault")) { *(volatile DWORD *)0=1;ExitProcess(11); }
        require(SetConsoleMode(input,ENABLE_LINE_INPUT|ENABLE_PROCESSED_INPUT),7);output("LINE\n",5);
        require(ReadFile(input,bytes,sizeof(bytes),&count,0) && count==2 && bytes[0]=='a' && bytes[1]=='\n',8);
        flags=99;CONSOLE_SCREEN_BUFFER_INFO info;
        require(!GetConsoleMode(out,&flags) && flags==99 && GetLastError()==ERROR_NOT_SUPPORTED,9);
        require(!GetConsoleScreenBufferInfo(out,&info) && GetLastError()==ERROR_NOT_SUPPORTED,10);
        const char message[]="windows console: terminal raw/cooked input and restored modes ok\n";output(message,sizeof(message)-1);ExitProcess(0);
    }
    if(mode("signal") || mode("break") || mode("ignore") || mode("ignore-read") || mode("remove") || mode("read") || mode("threshold") || mode("default")) {
        require(SetConsoleCtrlHandler(0,FALSE),20);
        if(mode("threshold"))require(SetConsoleCtrlHandler(threshold,TRUE),21);
        else if(!mode("default")) {
            event_handle=CreateEventW(0,TRUE,FALSE,0);require(event_handle!=0,22);
            require(SetConsoleCtrlHandler(oldest,TRUE) && SetConsoleCtrlHandler(middle,TRUE) && SetConsoleCtrlHandler(newest,TRUE),23);
            if(mode("remove"))require(SetConsoleCtrlHandler(middle,FALSE),24);
            if(mode("ignore") || mode("ignore-read"))require(SetConsoleCtrlHandler(0,TRUE),25);
            expected_event=(mode("break") || mode("ignore") || mode("ignore-read"))?CTRL_BREAK_EVENT:CTRL_C_EVENT;
        }
        output("READY\n",6);SetLastError(1234);
        if(mode("read")) {
            char byte;DWORD count=99;
            require(!ReadFile(input,&byte,1,&count,0) && count==0 && GetLastError()==ERROR_OPERATION_ABORTED,26);
        }
        if(mode("ignore-read")) {
            char byte;DWORD count=0;require(ReadFile(input,&byte,1,&count,0) && count==1 && byte=='a',34);
            require(SetConsoleCtrlHandler(0,FALSE),35);output("WAIT\n",5);
        }
        if(mode("default") || mode("threshold")) {
            WaitForSingleObject(GetCurrentProcess(),INFINITE);ExitProcess(27);
        }
        require(WaitForSingleObject(event_handle,INFINITE)==WAIT_OBJECT_0 && order==(mode("remove")?31:321),28);
        require(GetLastError()==(mode("read")?ERROR_OPERATION_ABORTED:1234),29);
        require(SetConsoleCtrlHandler(oldest,FALSE) && SetConsoleCtrlHandler(newest,FALSE),30);
        if(!mode("remove"))require(SetConsoleCtrlHandler(middle,FALSE),31);
        require(!SetConsoleCtrlHandler(oldest,FALSE) && GetLastError()==ERROR_INVALID_PARAMETER,32);
        require(CloseHandle(event_handle),33);output(" ok\n",4);ExitProcess(0);
    }
    DWORD flags=99;CONSOLE_SCREEN_BUFFER_INFO info;
    DWORD input_type=GetFileType(input),output_type=GetFileType(out);
    require(input_type>=FILE_TYPE_DISK && input_type<=FILE_TYPE_PIPE && output_type>=FILE_TYPE_DISK && output_type<=FILE_TYPE_PIPE,40);
    if(mode("pipes"))require(input_type==FILE_TYPE_PIPE && output_type==FILE_TYPE_PIPE,51);
    if(GetConsoleMode(input,&flags))require(input_type==FILE_TYPE_CHAR && flags<=7,41);
    else {
        require(flags==99 && GetLastError()==ERROR_INVALID_HANDLE,41);
        require(!SetConsoleMode(input,7) && GetLastError()==ERROR_INVALID_HANDLE,42);
    }
    flags=99;require(!GetConsoleMode(out,&flags) && flags==99 && !GetConsoleScreenBufferInfo(out,&info) && (GetLastError()==ERROR_INVALID_HANDLE || GetLastError()==ERROR_NOT_SUPPORTED),43);
    SetLastError(777);require(AreFileApisANSI() && GetConsoleCP()==65001 && GetConsoleOutputCP()==65001,44);
    SetFileApisToOEM();require(!AreFileApisANSI() && GetOEMCP()==65001 && GetACP()==65001,45);
    SetFileApisToANSI();require(AreFileApisANSI() && SetConsoleCP(65001) && SetConsoleOutputCP(65001) && GetLastError()==777,46);
    require(!SetConsoleCP(0) && GetLastError()==ERROR_INVALID_PARAMETER && !SetConsoleOutputCP(437) && GetLastError()==ERROR_NOT_SUPPORTED && GetConsoleOutputCP()==65001,47);
    require(SetConsoleCtrlHandler(newest,TRUE) && SetConsoleCtrlHandler(newest,TRUE) && SetConsoleCtrlHandler(newest,FALSE) && SetConsoleCtrlHandler(newest,FALSE),48);
    require(!SetConsoleCtrlHandler(newest,FALSE) && GetLastError()==ERROR_INVALID_PARAMETER,49);
    require(CloseHandle(input) && GetFileType(input)==FILE_TYPE_UNKNOWN && GetLastError()==ERROR_INVALID_HANDLE && !GetConsoleMode(input,&flags),50);
    const char message[]="windows console: stream types, UTF-8 policy and handler registration ok\n";output(message,sizeof(message)-1);ExitProcess(0);
}
