/* SDK declarations and unchanged PE machine code; no linked CRT implementation. */
#define _NO_CRT_STDIO_INLINE
#define __MSVCRT_VERSION__ 0x700
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <errno.h>
#include <io.h>
#include <fcntl.h>
#include <process.h>
#include <corecrt_startup.h>
#include <stddef.h>
typedef struct { int newmode; } startupinfo;
__declspec(dllimport) int __cdecl __getmainargs(int *,char ***,char ***,int,startupinfo *);
__declspec(dllimport) _onexit_t __cdecl __dllonexit(_onexit_t,_onexit_t **,_onexit_t **);
#undef _iob
#undef _fmode
__declspec(dllimport) extern FILE _iob[20];
__declspec(dllimport) extern int _fmode, _commode;
__declspec(dllimport) extern char **__initenv;
_Static_assert(sizeof(FILE)==48 && offsetof(FILE,_flag)==24 && offsetof(FILE,_file)==28,"Legacy x64 MSVCRT FILE layout");
static void require(int condition,DWORD code) { if (!condition) ExitProcess(code); }
static void output(const char *bytes,DWORD count) {
    DWORD written=0; require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),bytes,count,&written,0) && written==count,100);
}
static unsigned sequence;
static void inner(void) { sequence=sequence*10+2; }
static void first(void) { sequence=sequence*10+1; _PVFV nested[]={0,inner,0}; _initterm(nested,nested+3); }
static void last(void) { sequence=sequence*10+3; }
static int a(void) { require(fputs("A",stdout)>=0,101); return 0; }
static int c(void) { require(fputs("C",stdout)>=0,102); return 0; }
static int b(void) { require(_onexit(c)==c && fputs("B",stdout)>=0,103); return 0; }
static int local_a(void) { sequence=sequence*10+4; return 0; }
static int local_b(void) { sequence=sequence*10+5; return 0; }
static unsigned __stdcall thread(void *unused) { (void)unused; ExitProcess(104); return 0; }
void mainCRTStartup(void) {
    int argc=0; char **argv=0,**env=0; startupinfo info={0};
    require(__getmainargs(&argc,&argv,&env,0,&info)==0 && argc>=2 && argv && !argv[argc] && env && !env[0],1);
    require(__initenv==env && __iob_func()==_iob && stdout==_iob+1 && stdin==_iob && stderr==_iob+2,2);
    require(_fmode==_O_TEXT && __p__fmode()==&_fmode && !_commode,3);
    _commode=17; require(_commode==17,4); _commode=0;
    if (!strcmp(argv[1],"text") || !strcmp(argv[1],"binary")) {
        if (argv[1][0]=='b') require(_setmode(0,_O_BINARY)==_O_TEXT && _setmode(1,_O_BINARY)==_O_TEXT,5);
        int value; while ((value=fgetc(stdin))!=EOF) require(fputc(value,stdout)==value,6);
        require(fgetc(stdin)==EOF && (stdin->_flag & _IOEOF) && fflush(stdout)==0,7);
        _exit(0);
    }
    if (!strcmp(argv[1],"puts")) {
        char *bytes=malloc(9001); require(bytes!=0,46);
        for (unsigned n=0;n<9000;++n) bytes[n]=n%17==0?'\n':'x'; bytes[9000]=0;
        require(fputs(bytes,stdout)>=0 && fflush(stdout)==0,47); free(bytes); _exit(0);
    }
    if (!strcmp(argv[1],"wildcards")) { __getmainargs(&argc,&argv,&env,1,&info); ExitProcess(105); }
    if (!strcmp(argv[1],"newmode")) { info.newmode=1; __getmainargs(&argc,&argv,&env,0,&info); ExitProcess(106); }
    if (!strcmp(argv[1],"exception") || !strcmp(argv[1],"rtti")) {
        void (*function)(void)=(void *)GetProcAddress(GetModuleHandleA("msvcrt.dll"),argv[1][0]=='e'?"__C_specific_handler":"??1type_info@@UEAA@XZ");
        require(function!=0,8); function(); ExitProcess(107);
    }
    if (!strcmp(argv[1],"exit") || !strcmp(argv[1],"quick")) {
        require(_onexit(a)==a && _onexit(b)==b,9);
        if (argv[1][0]=='q') _exit(43); else exit(42);
    }
    require(!strcmp(argv[1],"core") && argc==7,10);
    const char *expected[]={"","a b","a\"b","tail\\","é🚀"};
    for (unsigned n=0;n<5;++n) require(!strcmp(argv[n+2],expected[n]),11);
    HMODULE crt=GetModuleHandleA("MSVCRT.DLL"),kernel=GetModuleHandleA("kernel32.dll");
    require(crt && (void *)GetProcAddress(crt,"_iob")==_iob && (void *)GetProcAddress(crt,"__initenv")==&__initenv && (void *)GetProcAddress(crt,"_fmode")==&_fmode,12);
    require(!GetProcAddress(kernel,"malloc") && !GetProcAddress(crt,"WriteFile"),13);
    SetLastError(1234); errno=777;
    require(_fileno(stdin)==0 && _fileno(stdout)==1 && _fileno(stderr)==2 && _get_osfhandle(1)==(intptr_t)GetStdHandle(STD_OUTPUT_HANDLE),14);
    require(_isatty(1)==0 && errno==777 && GetLastError()==1234,15);
    require(_get_osfhandle(3)==-1 && errno==EBADF && _setmode(1,123)==-1 && errno==EINVAL,16);
    require(_setmode(1,_O_BINARY)==_O_TEXT && _setmode(1,_O_TEXT)==_O_BINARY && fflush(0)==0,17);
    require(fputc('!',stdin)==EOF && errno==EBADF && (stdin->_flag & _IOERR),18);
    require(fgetc(stdout)==EOF && errno==EBADF && (stdout->_flag & _IOERR),19);
    unsigned tid=123;
    require(!_beginthreadex(0,0,thread,0,0,&tid) && errno==EAGAIN && _doserrno==ERROR_NOT_SUPPORTED && tid==123,20);
    char *memory=malloc(12000); require(memory!=0 && !((uintptr_t)memory & 15),21);
    for (unsigned n=0;n<12000;++n) memory[n]=(char)(n*17+3);
    require(memmove(memory+1,memory,9000)==memory+1,22);
    for (unsigned n=0;n<9000;++n) require((unsigned char)memory[n+1]==(unsigned char)(n*17+3),23);
    require(memmove(memory,memory+1,9000)==memory,24);
    for (unsigned n=0;n<9000;++n) require((unsigned char)memory[n]==(unsigned char)(n*17+3),25);
    char *copy=calloc(12000,1); require(copy && !copy[0] && !copy[11999],26);
    require(memcpy(copy,memory,9000)==copy && !memcmp(copy,memory,9000),27);
    copy[8191]=(char)((unsigned char)memory[8191]+1); require(memcmp(copy,memory,9000)>0,28);
    copy[8191]=memory[8191]; require(memset(copy,255,12000)==copy && (unsigned char)copy[11999]==255,29);
    free(copy); free(0);
    char *grown=realloc(memory,24000); require(grown!=0,30);
    for (unsigned n=0;n<9000;++n) require((unsigned char)grown[n]==(unsigned char)(n*17+3),31);
    require(realloc(grown,(size_t)1<<40)==0 && errno==ENOMEM && (unsigned char)grown[1]==20,32);
    require(realloc(grown,0)==0 && calloc((size_t)-1,2)==0 && errno==ENOMEM,33);
    char *zero=malloc(0); require(zero!=0,34); free(zero);
    zero=realloc(0,16); require(zero!=0,35); free(zero);
    require(strlen("é🚀")==6 && strcmp("\x80","\x7f")>0 && strcmp("abc","abcd")<0 && !strcmp("same","same"),36);
    require(wcscmp(L"\x8000",L"\x7fff")>0 && !wcscmp(L"é🚀",L"é🚀"),37);
    const wchar_t *wide=L"abaé🚀aba";
    require(wcsstr(wide,L"é🚀")==wide+3 && wcsstr(wide,L"")==wide && !wcsstr(wide,L"missing"),38);
    _PVFV initializers[]={first,0,last}; _initterm(initializers,initializers+3); require(sequence==123,39);
    _onexit_t *start=0,*end=0;
    require(__dllonexit(local_a,&start,&end)==local_a && __dllonexit(local_b,&start,&end)==local_b && end-start==2,40);
    require(start[0]==local_a && start[1]==local_b,41);
    end[-1](); end[-2](); require(sequence==12354,42); free(start);
    require(_onexit(a)==a && _onexit(b)==b,43);
    _c_exit(); require(_fileno(stdout)==1,44);
    _cexit(); require(_fileno(stdout)==-1 && errno==EBADF && !stdout->_flag,45);
    const char message[]=" windows CRT: memory, argv/data, streams and nested/LIFO callbacks ok\n";
    output(message,sizeof(message)-1); ExitProcess(0);
}
