/* SDK declarations only; conversion is provided by UNIVERSE, without Windows DLL code. */
#include <windows.h>
static void require(int condition,DWORD code) { if(!condition)ExitProcess(code); }
static void output(const void *bytes,DWORD size) {
    while(size) {
        DWORD done=0,chunk=size>1048576?1048576:size;
        require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),bytes,chunk,&done,0) && done==chunk,201);
        bytes=(const char *)bytes+done;size-=done;
    }
}
static int input(void *bytes,DWORD size) {
    DWORD total=0;
    while(total<size) {
        DWORD count=0,chunk=size-total;if(chunk>1048576)chunk=1048576;
        require(ReadFile(GetStdHandle(STD_INPUT_HANDLE),(char *)bytes+total,chunk,&count,0),202);
        if(!count) { require(!total,203);return 0; }total+=count;
    }
    return 1;
}
void mainCRTStartup(void) {
    WCHAR text[8]={0};char back[16]={0};SetLastError(777);
    require(MultiByteToWideChar(CP_UTF8,MB_ERR_INVALID_CHARS,"é🚀",-1,text,8)==4 && GetLastError()==777,1);
    require(text[0]==0xe9 && text[1]==0xd83d && text[2]==0xde80 && text[3]==0,2);
    require(WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,text,-1,back,16,0,0)==7 && GetLastError()==777,3);
    require(back[0]==(char)0xc3 && back[1]==(char)0xa9 && back[6]==0,4);
    struct { DWORD wide,page,flags;int count,capacity;DWORD size,options; } request;
    unsigned char *source=VirtualAlloc(0,8388608,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    unsigned char *destination=VirtualAlloc(0,8388608,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    require(source && destination,5);
    while(input(&request,sizeof(request))) {
        DWORD bytes=request.capacity>0?(DWORD)request.capacity*(request.wide?1:2):0;
        require(request.wide<=1 && request.size<=8388608 && bytes<=8388600,6);
        if(request.size)require(input(source,request.size),7);
        if(bytes<=512)for(DWORD n=0;n<bytes;++n)destination[n]=0xaa;
        for(DWORD n=bytes;n<bytes+8;++n)destination[n]=0xaa;
        const void *from=request.options&1?0:source;
        void *to=request.options&2?0:request.options&4?source:destination;
        struct { int result;DWORD error,bytes,used; } response;
        response.used=0xaaaaaaaa;
        SetLastError(777);
        response.result=request.wide?
            WideCharToMultiByte(request.page,request.flags,from,request.count,to,request.capacity,request.options&8?"?":0,request.options&16?(BOOL *)&response.used:0):
            MultiByteToWideChar(request.page,request.flags,from,request.count,to,request.capacity);
        response.error=GetLastError();response.bytes=bytes+8;output(&response,sizeof(response));output(destination,bytes+8);
    }
    require(VirtualFree(source,0,MEM_RELEASE) && VirtualFree(destination,0,MEM_RELEASE),8);
    ExitProcess(0);
}
