/* SDK declarations/layout; freestanding guest, no linked CRT or vendor DLL. */
#include <windows.h>
#include <oleauto.h>
_Static_assert(sizeof(VARIANT) == 24, "Windows x64 VARIANT layout");
_Static_assert(__builtin_offsetof(VARIANT, bstrVal) == 8, "BSTR union offset");
static WCHAR large[2057];
static void require(int condition, DWORD code) { if (!condition) ExitProcess(code); }
void mainCRTStartup(void) {
    HANDLE ole = LoadLibraryA("OLEAUT32"), kernel = GetModuleHandleA("kernel32.dll");
    require(ole && kernel && ole != kernel, 1);
    require(GetModuleHandleW(L"OlEaUt32.dll") == ole && LoadLibraryW(L"oleaut32.dll") == ole, 2);
    require(GetProcAddress(ole, "SysAllocString") == (void *)SysAllocString, 3);
    require(GetProcAddress(ole, (const char *)2) == (void *)SysAllocString, 4);
    require(GetProcAddress(ole, (const char *)4) == (void *)SysAllocStringLen, 5);
    require(GetProcAddress(ole, (const char *)6) == (void *)SysFreeString, 6);
    require(GetProcAddress(ole, (const char *)7) == (void *)SysStringLen, 7);
    require(GetProcAddress(ole, (const char *)8) == (void *)VariantInit, 8);
    require(GetProcAddress(ole, (const char *)9) == (void *)VariantClear, 9);
    require(GetProcAddress(ole, (const char *)10) == (void *)VariantCopy, 10);
    require(!GetProcAddress(ole, "ExitProcess") && GetLastError() == 127, 11);
    require(!GetProcAddress(kernel, "SysAllocString") && GetLastError() == 127, 12);
    require(!GetProcAddress(ole, (const char *)3) && GetLastError() == 127, 13);
    require(!GetProcAddress(ole, "sysallocstring") && GetLastError() == 127, 14);
    require(FreeLibrary(ole) && GetModuleHandleA("oleaut32.dll") == ole, 15);

    const WCHAR raw[] = {0xe9, 0, 0xd83d, 0xde80, 0xd800, 'z'};
    require(!SysAllocString(0) && !SysStringLen(0), 16);
    SysFreeString(0);
    BSTR text = SysAllocStringLen(raw, 6);
    require(text && SysStringLen(text) == 6 && ((DWORD *)text)[-1] == 12 && !text[6], 17);
    for (int n=0; n<6; ++n) require(text[n] == raw[n], 18);
    BSTR short_text = SysAllocString(raw);
    require(short_text && SysStringLen(short_text) == 1 && short_text[0] == 0xe9 && !short_text[1], 19);
    SysFreeString(short_text);
    BSTR empty = SysAllocString(L""), blank = SysAllocStringLen(0, 3);
    require(empty && !SysStringLen(empty) && !empty[0], 20);
    require(blank && SysStringLen(blank) == 3 && !blank[3], 21);
    SysFreeString(empty); SysFreeString(blank);
    require(!SysAllocStringLen(0, 0xffffffffU), 22);
    for (int n=0; n<2057; ++n) large[n] = (WCHAR)(n+1);
    BSTR long_text = SysAllocStringLen(large, 2057);
    require(long_text && SysStringLen(long_text) == 2057 && !long_text[2057], 23);
    for (int n=0; n<2057; ++n) require(long_text[n] == large[n], 24);
    SysFreeString(long_text);

    VARIANT src, dst;
    VariantInit(&src); VariantInit(&dst);
    src.vt = VT_BSTR; src.bstrVal = text;
    dst.vt = VT_BSTR; dst.bstrVal = SysAllocString(L"old destination");
    require(VariantCopy(&dst, &src) == S_OK && dst.vt == VT_BSTR && dst.bstrVal != text, 25);
    require(SysStringLen(dst.bstrVal) == 6 && dst.bstrVal[2] == 0xd83d, 26);
    text[2] = 'x'; require(dst.bstrVal[2] == 0xd83d, 27);
    BSTR saved = dst.bstrVal;
    require(VariantCopy(&dst, &dst) == S_OK && dst.bstrVal == saved, 28);
    require(VariantClear(&src) == S_OK && src.vt == VT_EMPTY, 29);
    require(VariantClear(&dst) == S_OK && dst.vt == VT_EMPTY && VariantClear(&dst) == S_OK, 30);
    src.vt = VT_BSTR; src.bstrVal = 0;
    require(VariantCopy(&dst, &src) == S_OK && dst.vt == VT_BSTR && !dst.bstrVal, 31);
    require(VariantClear(&src) == S_OK && VariantClear(&dst) == S_OK, 32);

    const unsigned short types[] = {VT_EMPTY, VT_NULL, VT_I2, VT_I4, VT_R4, VT_R8, VT_CY, VT_DATE,
        VT_ERROR, VT_BOOL, VT_DECIMAL, VT_I1, VT_UI1, VT_UI2, VT_UI4, VT_I8, VT_UI8, VT_INT, VT_UINT,
        VT_I4|VT_BYREF, VT_BSTR|VT_BYREF, VT_VARIANT|VT_BYREF, VT_DISPATCH|VT_BYREF,
        VT_UNKNOWN|VT_BYREF, VT_ARRAY|VT_I4|VT_BYREF};
    for (unsigned n=0; n<sizeof(types)/sizeof(types[0]); ++n) {
        unsigned char *bytes = (unsigned char *)&src;
        for (unsigned i=0; i<sizeof(src); ++i) bytes[i]=(unsigned char)(0xa0+i);
        src.vt = types[n];
        require(VariantCopy(&dst, &src) == S_OK, 33);
        for (unsigned i=0; i<sizeof(src); ++i) require(((unsigned char *)&dst)[i] == bytes[i], 34);
        require(VariantClear(&src) == S_OK && VariantClear(&dst) == S_OK, 35);
    }
    src.vt = 0xffff;
    require(VariantCopy(&dst, &src) == DISP_E_BADVARTYPE && src.vt == 0xffff && dst.vt == VT_EMPTY, 36);
    require(VariantClear(&src) == DISP_E_BADVARTYPE && src.vt == 0xffff, 37);
    const unsigned short unsupported[] = {VT_UNKNOWN, VT_DISPATCH, VT_ARRAY|VT_I4, VT_RECORD};
    for (int n=0; n<4; ++n) {
        src.vt = unsupported[n];
        require(VariantCopy(&dst, &src) == E_NOTIMPL && dst.vt == VT_EMPTY, 38);
        require(VariantClear(&src) == E_NOTIMPL && src.vt == unsupported[n], 39);
    }
    require(VariantClear(0) == E_INVALIDARG && VariantCopy(0, &dst) == E_INVALIDARG && VariantCopy(&dst, 0) == E_INVALIDARG, 40);
    const char output[] = "windows automation: named/ordinal imports, BSTR ownership and variants ok\n";
    DWORD written;
    require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), output, sizeof(output)-1, &written, 0), 41);
    ExitProcess(written == sizeof(output)-1 ? 0 : 42);
}
