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
NOINLINE int scalar(int value) { try { throw value; } catch (int error) { return error; } }
NOINLINE int byValue(int value) { try { throw CSystemException{value}; } catch (CSystemException error) { return error.value; } }
NOINLINE int anyType() { try { throw OtherException{11}; } catch (...) { return 11; } }
NOINLINE int nested(int value) {
    Marker outer{6};
    try {
        Marker middle{7};
        try { Marker inner{8}; throw CSystemException{value}; }
        catch (const OtherException &) { return 99; }
    } catch (const CSystemException &error) { sequence = sequence * 10 + 9; return error.value; }
    return 99;
}
static int verifyMore() {
    for (int value = -8; value <= 8; ++value)
        if (scalar(value) != value || byValue(value) != value || anyType() != 11) return 1;
    sequence = 0;
    if (nested(42) != 42 || sequence != 8796) return 2;
    return 0;
}
#ifdef HOST_PROBE
int main() {
    int result = caught(42);
    printf("result=%d cleanup=%u\n", result, sequence);
    if (result != 42 || sequence != 23154 || verifyMore()) return 1;
    printf("value/scalar/catch-all: 51 throws ok; nested cleanup=%u\n", sequence);
    return 0;
}
#else
extern "C" void mainCRTStartup() {
    int result = caught(42);
    if (result != 42 || sequence != 23154) ExitProcess(1);
    const char text[] = "result=42 cleanup=23154\n";
    unsigned written = 0;
    if (!WriteFile(GetStdHandle(-11u), text, sizeof(text) - 1, &written, 0) || written != sizeof(text) - 1) ExitProcess(2);
    if (verifyMore()) ExitProcess(3);
    const char more[] = "value/scalar/catch-all: 51 throws ok; nested cleanup=8796\n";
    if (!WriteFile(GetStdHandle(-11u), more, sizeof(more) - 1, &written, 0) || written != sizeof(more) - 1) ExitProcess(4);
    ExitProcess(0);
}
#endif
