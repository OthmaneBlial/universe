/* SDK declarations only; all memory and handles belong to UNIVERSE. */
#include <windows.h>
static void require(int condition,DWORD code) { if(!condition)ExitProcess(code); }
static void output(const void *bytes,DWORD size) {
    DWORD count=0;require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),bytes,size,&count,0) && count==size,201);
}
static int mode(const char *name) {
    const char *line=GetCommandLineA();unsigned length=0,size=0;
    while(line[length])++length;while(name[size])++size;
    if(length<size+2 || line[length-1]!='"' || line[length-size-2]!='"')return 0;
    for(unsigned n=0;n<size;++n)if(line[length-size-1+n]!=name[n])return 0;
    return 1;
}
static void basic(void) {
    SetLastError(777);require(!LocalFree(0) && GetLastError()==777,1);
    for(unsigned movable=0;movable<2;++movable) {
        HLOCAL handle=LocalAlloc(LMEM_ZEROINIT|(movable?LMEM_MOVEABLE:0),17);
        require(handle!=0 && GetLastError()==777,2);
        unsigned char *bytes=LocalLock(handle);require(bytes!=0 && (movable?(void *)handle!=bytes:(void *)handle==bytes),3);
        require(LocalSize(handle)>=17 && LocalHandle(bytes)==handle,4);
        for(unsigned n=0;n<17;++n)require(!bytes[n],5);
        require(LocalLock(handle)==bytes && (LocalFlags(handle)&LMEM_LOCKCOUNT)==(movable?2:0),6);
        if(movable) {
            require(LocalUnlock(handle) && GetLastError()==777,7);
            require(!LocalUnlock(handle) && GetLastError()==NO_ERROR,8);
        }
        require(!LocalUnlock(handle) && GetLastError()==ERROR_NOT_LOCKED,9);
        require(LocalLock(handle)==bytes && !LocalFree(handle),10);
        require(LocalFree(handle)==handle && GetLastError()==ERROR_INVALID_HANDLE,11);
        require(LocalFlags(handle)==LMEM_INVALID_HANDLE && GetLastError()==ERROR_INVALID_HANDLE,12);
        SetLastError(777);
    }
    HLOCAL discarded=LocalAlloc(LMEM_MOVEABLE,0);require(discarded!=0,13);
    require(LocalFlags(discarded)&LMEM_DISCARDED,14);
    require(!LocalSize(discarded) && !LocalLock(discarded) && !LocalFree(discarded),15);
    HLOCAL fixed=LocalAlloc(LMEM_FIXED,0);require(fixed!=0 && !LocalLock(fixed) && !LocalFree(fixed),16);
    void *foreign=HeapAlloc(GetProcessHeap(),0,17);require(foreign!=0,17);
    require(LocalFree(foreign)==foreign && HeapFree(GetProcessHeap(),0,foreign),18);
    require(!LocalAlloc(0x80000000,17) && GetLastError()==ERROR_INVALID_PARAMETER,19);
    require(!LocalAlloc(0,(SIZE_T)-1) && GetLastError()==ERROR_NOT_ENOUGH_MEMORY,20);
}
static void resize(void) {
    HLOCAL handle=LocalAlloc(LHND,17);require(handle!=0,21);
    unsigned char *bytes=LocalLock(handle);require(bytes!=0,22);bytes[0]=93;
    require(!LocalReAlloc(handle,8193,0) && GetLastError()==ERROR_NOT_ENOUGH_MEMORY,23);
    require(bytes[0]==93 && LocalSize(handle)>=17,24);
    require(LocalReAlloc(handle,(SIZE_T)-1,LMEM_MODIFY)==handle && bytes[0]==93,25);
    require(!LocalReAlloc(handle,(SIZE_T)-1,LMEM_MOVEABLE) && GetLastError()==ERROR_NOT_ENOUGH_MEMORY && bytes[0]==93,26);
    require(!LocalReAlloc(handle,0,LMEM_MOVEABLE) && GetLastError()==ERROR_LOCKED,27);
    require(LocalReAlloc(handle,8193,LHND)==handle && (LocalFlags(handle)&LMEM_LOCKCOUNT)==1,28);
    bytes=LocalLock(handle);require(bytes!=0 && bytes[0]==93 && !bytes[8192],29);
    require(LocalUnlock(handle) && !LocalUnlock(handle),30);
    require(LocalDiscard(handle)==handle && (LocalFlags(handle)&LMEM_DISCARDED),31);
    require(LocalReAlloc(handle,31,LHND)==handle,32);
    bytes=LocalLock(handle);require(bytes!=0,33);
    for(unsigned n=0;n<31;++n)require(!bytes[n],34);
    require(!LocalFree(handle),35);
}
static void records(void) {
    const DWORD initial[]={0,1,17,4095,4096,4097},sizes[]={7,4095,4097,8193,3,0,19};
    for(DWORD movable=0;movable<2;++movable)for(DWORD start=0;start<6;++start) {
        HLOCAL handle=LocalAlloc(LMEM_ZEROINIT|(movable?LMEM_MOVEABLE:0),initial[start]);require(handle!=0,40);
        DWORD old_size=initial[start],seed=movable*41+start;
        unsigned char *bytes=old_size?LocalLock(handle):0;
        for(DWORD n=0;n<old_size;++n)bytes[n]=(unsigned char)(n*37+seed);
        if(movable && old_size)require(!LocalUnlock(handle),41);
        for(DWORD step=0;step<7;++step) {
            HLOCAL old=handle;SetLastError(777);
            handle=LocalReAlloc(handle,sizes[step],LHND);require(handle!=0,42);
            struct { DWORD movable,start,step,size,flags,error,stable; } record={movable,start,step,(DWORD)LocalSize(handle),LocalFlags(handle),GetLastError(),handle==old};
            output(&record,sizeof(record));
            bytes=record.size?LocalLock(handle):0;
            if(record.size) { require(bytes!=0 && LocalHandle(bytes)==handle,43);output(bytes,record.size); }
            seed+=17;
            for(DWORD n=0;n<record.size;++n)bytes[n]=(unsigned char)(n*37+seed);
            if(movable && record.size)require(!LocalUnlock(handle),44);
        }
        require(!LocalFree(handle),45);
    }
}
void mainCRTStartup(void) {
    basic();resize();
    if(mode("records")) { records();ExitProcess(0); }
    if(mode("fault")) {
        HLOCAL handle=LocalAlloc(LPTR,17);require(handle!=0,46);
        volatile unsigned char *bytes=LocalLock(handle);require(bytes!=0 && !LocalFree(handle),47);
        *bytes=1;ExitProcess(48);
    }
    const char message[]="windows local: fixed/movable memory, resize, locks, discard and ownership ok\n";
    output(message,sizeof(message)-1);
    ExitProcess(0);
}
