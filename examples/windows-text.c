/* Source-built USER32 guest; SDK declarations only, no CRT or native DLL. */
#include <windows.h>
static WCHAR scalar[65536], text[65536];
static void require(int condition, DWORD code) { if (!condition) ExitProcess(code); }
static int argument(const char *word) {
    const char *line=GetCommandLineA();
    for (;*line;++line) if (*line==' ') {
        const char *p=line+1; if (*p=='"') ++p;
        int n=0; while (word[n] && p[n]==word[n]) ++n;
        if (!word[n] && (!p[n] || (p[n]=='"' && !p[n+1]))) return 1;
    }
    return 0;
}
void mainCRTStartup(void) {
    if (argument("oracle")) {
        for (unsigned n=0; n<65536; ++n) scalar[n]=(WCHAR)(ULONG_PTR)CharUpperW((WCHAR *)(ULONG_PTR)n);
        for (unsigned n=0; n<65535; ++n) text[n]=(WCHAR)(n+1);
        text[65535]=0;
        require(CharUpperW(text)==text, 1);
        DWORD written;
        require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),scalar,sizeof(scalar),&written,0) && written==sizeof(scalar),2);
        require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,sizeof(text),&written,0) && written==sizeof(text),3);
        ExitProcess(0);
    }
    HANDLE user=LoadLibraryA("USER32"), kernel=GetModuleHandleA("KERNEL32.dll"), ole=GetModuleHandleA("OLEAUT32.dll");
    require(user && user!=kernel && user!=ole && GetModuleHandleW(L"UsEr32.DlL")==user,4);
    require(GetProcAddress(user,"CharUpperW")== (void *)CharUpperW && GetProcAddress(user,"CharPrevExA")== (void *)CharPrevExA,5);
    require(!GetProcAddress(kernel,"CharUpperW") && GetLastError()==127,6);
    require(!GetProcAddress(user,"WriteFile") && GetLastError()==127,7);
    require(!GetProcAddress(user,(const char *)1) && GetLastError()==127,8);
    require(FreeLibrary(user) && GetModuleHandleA("USER32.dll")==user,9);
    const WCHAR input[]={ 'a','z',0xe9,0xff,0xdf,0x131,0x17f,0x1f3,0x3c2,0x3c9,0xb5,
        0x1f80,0x1fb3,0x451,0x561,0x10d0,0xff41,0xd83d,0xde80,0xd800,0xffff,0 };
    const WCHAR expected[]={ 'A','Z',0xc9,0x178,0xdf,'I','S',0x1f1,0x3a3,0x3a9,0x39c,
        0x1f88,0x1fbc,0x401,0x531,0x1c90,0xff21,0xd83d,0xde80,0xd800,0xffff,0 };
    WCHAR *buffer=VirtualAlloc(0,8192,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    require(buffer && (ULONG_PTR)buffer>0xffffffffULL,10);
    for (unsigned n=0; n<sizeof(input)/sizeof(input[0]); ++n) {
        buffer[n]=input[n];
        require((ULONG_PTR)CharUpperW((WCHAR *)(ULONG_PTR)input[n])==expected[n],11);
    }
    require(CharUpperW(buffer)==buffer,12);
    for (unsigned n=0; n<sizeof(input)/sizeof(input[0]); ++n) require(buffer[n]==expected[n],13);
    require(CharUpperW(buffer)==buffer && !CharUpperW(0),14);
    require(VirtualFree(buffer,0,MEM_RELEASE),15);
    WCHAR empty[]={0};require(CharUpperW(empty)==empty && !empty[0],16);

    char dbcs[]={'a',(char)0x81,(char)0x40,(char)0x81,(char)0x81,'z',0};
    const int previous[]={0,0,1,1,3,3,5};
    for (int n=0; n<=6; ++n) require(CharPrevExA(932,dbcs,dbcs+n,0)==dbcs+previous[n],17);
    for (int n=1; n<=6; ++n) require(CharPrevExA(1252,dbcs,dbcs+n,0)==dbcs+n-1,18);
    const WORD pages[]={932,936,949,950,1361};
    /* Expected lead-byte sets from original code-page metadata, independent of the runtime switch. */
    const unsigned long long leads[][4]={
        {0x0000000000000000ULL,0x0000000000000000ULL,0x00000000fffffffeULL,0x1fffffff00000000ULL},
        {0x0000000000000000ULL,0x0000000000000000ULL,0xfffffffffffffffeULL,0x7fffffffffffffffULL},
        {0x0000000000000000ULL,0x0000000000000000ULL,0xfffffffffffffffeULL,0x7fffffffffffffffULL},
        {0x0000000000000000ULL,0x0000000000000000ULL,0xfffffffffffffffeULL,0x7fffffffffffffffULL},
        {0x0000000000000000ULL,0x0000000000000000ULL,0xfffffffffffffff0ULL,0x03ffffff7f0fffffULL},
    };
    for (int p=0; p<5; ++p) for (int byte=1; byte<=255; ++byte) {
        char pair[]={(char)byte,'A',0};
        int lead=(int)((leads[p][byte/64]>>(byte%64))&1);
        require(CharPrevExA(pages[p],pair,pair+2,0)==pair+(lead?0:1),19);
    }
    const char utf8[]={(char)0xc3,(char)0xa9,(char)0xf0,(char)0x9f,(char)0x9a,(char)0x80,0};
    for (int n=1; n<=6; ++n) {
        require(CharPrevExA(65001,utf8,utf8+n,0)==utf8+n-1,20);
        require(CharPrevExA(CP_ACP,utf8,utf8+n,0)==utf8+n-1,21);
    }
    const char gb[]={(char)0x81,(char)0x30,(char)0x81,(char)0x30,0};
    require(CharPrevExA(54936,gb,gb+4,0)==gb+3,22);
    if (argument("bad-flags")) { CharPrevExA(932,dbcs,dbcs+6,1);ExitProcess(23); }
    if (argument("bad-cursor")) { CharPrevExA(932,dbcs,dbcs+7,0);ExitProcess(24); }
    const char output[]="windows text: Unicode units, pointer/character forms and DBCS navigation ok\n";
    DWORD written;
    require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),output,sizeof(output)-1,&written,0),25);
    ExitProcess(written==sizeof(output)-1 ? 0 : 26);
}
