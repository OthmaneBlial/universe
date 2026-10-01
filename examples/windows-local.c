/* SDK declarations only; all memory and handles belong to UNIVERSE. */
#include <windows.h>
static void require(int condition,DWORD code) { if(!condition)ExitProcess(code); }
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
void mainCRTStartup(void) {
    basic();
    const char message[]="windows local: fixed/movable memory, locks, discarded handles and ownership ok\n";
    DWORD count=0;require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),message,sizeof(message)-1,&count,0) && count==sizeof(message)-1,201);
    ExitProcess(0);
}
