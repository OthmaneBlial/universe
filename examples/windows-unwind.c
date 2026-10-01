/* SDK declarations only. The compiler emits the real PE function table. */
#include <windows.h>
#include <stddef.h>
#include <stdint.h>
_Static_assert(sizeof(RUNTIME_FUNCTION)==12 && offsetof(RUNTIME_FUNCTION,EndAddress)==4 && offsetof(RUNTIME_FUNCTION,UnwindData)==8,"Win64 runtime function layout");
static void require(int condition,DWORD code) { if (!condition) ExitProcess(code); }
__declspec(noinline) static unsigned stackFrame(unsigned value) {
    volatile unsigned slots[64]; slots[63]=value; return slots[63]+1;
}
void mainCRTStartup(void) {
    require(stackFrame(41)==42,1);
    DWORD64 pc=(DWORD64)(uintptr_t)stackFrame,base=0xaaaaaaaaaaaaaaaaULL;
    SetLastError(777);
    PRUNTIME_FUNCTION entry=RtlLookupFunctionEntry(pc,&base,0);
    require(entry && base==(DWORD64)(uintptr_t)GetModuleHandleA(0),2);
    require(base+entry->BeginAddress==pc && pc<base+entry->EndAddress && entry->UnwindData && !(entry->UnwindData&3),3);
    DWORD64 again=0;
    require(RtlLookupFunctionEntry(base+entry->EndAddress-1,&again,0)==entry && again==base,4);
    base=0xaaaaaaaaaaaaaaaaULL;
    require(!RtlLookupFunctionEntry(0,&base,0) && base==0xaaaaaaaaaaaaaaaaULL,5);
    DWORD64 gateway=(DWORD64)(uintptr_t)GetProcAddress(GetModuleHandleA("kernel32.dll"),"WriteFile");
    require(gateway && !RtlLookupFunctionEntry(gateway,&base,0) && base==0xaaaaaaaaaaaaaaaaULL && GetLastError()==777,6);
    const char message[]="windows unwind: compiler function table lookup and checked module identity ok\n";
    DWORD written=0;
    require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),message,sizeof(message)-1,&written,0) && written==sizeof(message)-1,7);
    ExitProcess(0);
}
