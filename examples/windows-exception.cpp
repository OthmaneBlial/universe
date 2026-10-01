/* Own source: HOST_PROBE provides an independent native cleanup/catch oracle. */
#ifdef HOST_PROBE
#include <stdio.h>
#define NOINLINE __attribute__((noinline))
#else
#define NOINLINE __declspec(noinline)
extern "C" __declspec(dllimport) void ExitProcess(unsigned);
extern "C" __declspec(dllimport) void *GetStdHandle(unsigned);
extern "C" __declspec(dllimport) int WriteFile(void *, const void *, unsigned, unsigned *, void *);
// MSVC's descriptors reference a statically linked type_info vtable. Our own
// one-method bridge routes any RTTI invocation to the runtime's explicit fault.
extern "C" __declspec(dllimport) void unsupportedTypeInfo(void *) asm("??1type_info@@UEAA@XZ");
extern "C" void typeInfoFailure(void *value) { unsupportedTypeInfo(value); }
extern "C" const void *const typeInfoVtable[] asm("??_7type_info@@6B@") = { (const void *)typeInfoFailure };
#endif
volatile unsigned sequence;
struct CSystemException { int value; };
struct OtherException { int value; };
struct Marker { unsigned id; ~Marker() { sequence = sequence * 10 + id; } };
NOINLINE int throwing(int value) { Marker marker{2}; throw CSystemException{value}; }
NOINLINE int middle(int value) { Marker marker{3}; return throwing(value); }
NOINLINE int caught(int value) {
    Marker outer{4};
    try { Marker inner{1}; return middle(value); }
    catch (const OtherException &) { return 99; }
    catch (const CSystemException &error) { sequence = sequence * 10 + 5; return error.value; }
}
#ifdef HOST_PROBE
int main() { int result = caught(42); printf("result=%d cleanup=%u\n", result, sequence); return result != 42 || sequence != 23154; }
#else
extern "C" void mainCRTStartup() {
    int result = caught(42);
    if (result != 42 || sequence != 23154) ExitProcess(1);
    const char text[] = "result=42 cleanup=23154\n";
    unsigned written = 0;
    if (!WriteFile(GetStdHandle(-11u), text, sizeof(text) - 1, &written, 0) || written != sizeof(text) - 1) ExitProcess(2);
    ExitProcess(0);
}
#endif
