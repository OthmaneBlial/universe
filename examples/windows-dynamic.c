#include "windows-guest.h"
static volatile long journal[3];
static int argument(const char *word) {
    const char *line=GetCommandLineA();
    for (;*line;++line) if (*line==' ') {
        const char *p=line+1;
        if (*p=='"') ++p;
        int n=0;
        while (word[n] && p[n]==word[n]) ++n;
        if (!word[n] && (!p[n] || (p[n]=='"' && !p[n+1]))) return 1;
    }
    return 0;
}
void mainCRTStartup(void) {
    if (argument("rollback")) {
        HANDLE helper = LoadLibraryA("windows-helper");
        if (!helper) ExitProcess(40);
        if (LoadLibraryA("windows-probe") || GetLastError()!=1114) ExitProcess(41);
        if (GetModuleHandleA("windows-probe.dll") || GetModuleHandleA("windows-helper.dll")!=helper) ExitProcess(42);
        volatile long *data = GetProcAddress(helper,"helper_data");
        if (!data || *data!=8 || !FreeLibrary(helper) || GetModuleHandleA("windows-helper.dll")) ExitProcess(43);
        const char text[]="windows dynamic DLL: rollback ok\n";
        DWORD written;
        WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,sizeof(text)-1,&written,0);
        ExitProcess(written==sizeof(text)-1 ? 0 : 44);
    }
    if (argument("forward-fail")) {
        HANDLE module=LoadLibraryA("windows-probe");
        if (!module) ExitProcess(45);
        if (GetProcAddress(module,"forwarded_late")) ExitProcess(46);
        DWORD error=GetLastError();
        if (error!=126 && error!=1114 && error!=193 && error!=50 && error!=5) ExitProcess(47);
        if (GetModuleHandleA("windows-late.dll")) ExitProcess(48);
        long (*probe)(long)=GetProcAddress(module,"probe");
        if (!probe || probe(5)!=37 || !FreeLibrary(module) || GetModuleHandleA("windows-helper.dll")) ExitProcess(49);
        ExitProcess(error);
    }
    if (LoadLibraryA(0) || GetLastError()!=87) ExitProcess(16);
    if (LoadLibraryA("../windows-probe") || GetLastError()!=123) ExitProcess(17);
    if (FreeLibrary(0) || GetLastError()!=6) ExitProcess(18);
    if (GetModuleHandleA("windows-probe.dll")) ExitProcess(1);
    if (LoadLibraryA("not-present")) ExitProcess(2);
    DWORD missing=GetLastError();
    if (missing==5) ExitProcess(5);
    if (missing!=126) ExitProcess(2);
    HANDLE module=LoadLibraryA("windows-probe");
    if (!module) ExitProcess(GetLastError());
    if (LoadLibraryW((const WCHAR *)L"WINDOWS-PROBE.DLL")!=module) ExitProcess(3);
    long (*probe)(long)=GetProcAddress(module,"probe");
    volatile long *data=GetProcAddress(module,"probe_data");
    volatile long *reserved=GetProcAddress(module,"probe_reserved");
    if (!probe || !data || !reserved || *reserved || *data!=24 || probe(5)!=37) ExitProcess(4);
    void (*watch)(volatile long *)=GetProcAddress(module,"probe_watch");
    HANDLE helper=GetModuleHandleW((const WCHAR *)L"windows-helper.dll");
    void (*helper_watch)(volatile long *)=GetProcAddress(helper,"helper_watch");
    if (!watch || !helper_watch) ExitProcess(5);
    watch(journal);helper_watch(journal);
    if (!FreeLibrary(module) || GetModuleHandleA("windows-probe.dll")!=module || *data!=24 || journal[0]) ExitProcess(6);
    long (*late)(long)=GetProcAddress(module,"forwarded_late");
    if (!late || late(5)!=50) ExitProcess(7);
    HANDLE retained=LoadLibraryW((const WCHAR *)L"windows-late");
    void (*late_watch)(volatile long *)=GetProcAddress(retained,"late_watch");
    if (!retained || !late_watch) ExitProcess(8);
    late_watch(journal);
    if (!FreeLibrary(module) || journal[0]!=1 || journal[1]!=2 || journal[2]) ExitProcess(9);
    if (GetModuleHandleA("windows-probe.dll") || GetModuleHandleA("windows-helper.dll") || GetProcAddress(module,"probe") || GetLastError()!=6) ExitProcess(10);
    if (late(5)!=50 || !FreeLibrary(retained) || journal[2]!=3 || GetModuleHandleA("windows-late.dll")) ExitProcess(11);
    if (FreeLibrary(retained) || GetLastError()!=6) ExitProcess(12);
    module=LoadLibraryA("windows-probe");
    late=GetProcAddress(module,"forwarded_late");
    void (*set_late)(long (*)(long))=GetProcAddress(module,"probe_late_watch");
    watch=GetProcAddress(module,"probe_watch");
    helper_watch=GetProcAddress(GetModuleHandleA("windows-helper.dll"),"helper_watch");
    late_watch=GetProcAddress(GetModuleHandleA("windows-late.dll"),"late_watch");
    if (!module || !late || !set_late || !watch || !helper_watch || !late_watch) ExitProcess(24);
    journal[0]=0;journal[1]=0;journal[2]=0;
    set_late(late);watch(journal);helper_watch(journal);late_watch(journal);
    if (!FreeLibrary(module) || journal[0]!=1 || journal[1]!=2 || journal[2]!=3 || GetModuleHandleA("windows-late.dll")) ExitProcess(25);
    module=LoadLibraryA("windows-cycle-a");
    HANDLE cycle=LoadLibraryA("windows-cycle-b");
    long (*cycle_a)(void)=GetProcAddress(module,"cycle_value");
    long (*cycle_b)(void)=GetProcAddress(cycle,"cycle_value");
    void (*watch_a)(volatile long *)=GetProcAddress(module,"cycle_watch");
    void (*watch_b)(volatile long *)=GetProcAddress(cycle,"cycle_watch");
    if (!module || !cycle || !cycle_a || !cycle_b || !watch_a || !watch_b || cycle_a()!=46 || cycle_b()!=46) ExitProcess(21);
    late=GetProcAddress(module,"cycle_forward");
    set_late=GetProcAddress(module,"cycle_late_watch");
    late_watch=GetProcAddress(GetModuleHandleA("windows-late.dll"),"late_watch");
    if (!late || !set_late || !late_watch) ExitProcess(26);
    journal[0]=0;journal[1]=0;journal[2]=0;
    watch_a(journal);watch_b(journal);set_late(late);late_watch(journal);
    if (!FreeLibrary(module) || GetModuleHandleA("windows-cycle-a.dll")!=module || journal[0]) ExitProcess(22);
    if (!FreeLibrary(cycle) || journal[0]!=1 || journal[1]!=2 || journal[2]!=3 || GetModuleHandleA("windows-cycle-a.dll") || GetModuleHandleA("windows-cycle-b.dll") || GetModuleHandleA("windows-late.dll")) ExitProcess(23);
    for (int n=0;n<80;n++) {
        module=LoadLibraryA("windows-probe.dll");
        probe=GetProcAddress(module,(const char *)7);
        if (!module || !probe || probe(5)!=37 || !FreeLibrary(module)) ExitProcess(13);
    }
    module=LoadLibraryW((const WCHAR *)L"宇宙🚀.dll");
    data=GetProcAddress(module,"helper_data");
    if (!module || !data || *data!=8 || GetModuleHandleW((const WCHAR *)L"宇宙🚀.dll")!=module || !FreeLibrary(module)) ExitProcess(19);
    module=LoadLibraryA("bare.");
    data=GetProcAddress(module,"helper_data");
    if (!module || !data || *data!=8 || !FreeLibrary(module)) ExitProcess(20);
    HANDLE kernel=LoadLibraryA("KERNEL32");
    if (!kernel || GetProcAddress(kernel,"LoadLibraryA")!=(void *)LoadLibraryA || !FreeLibrary(kernel)) ExitProcess(14);
    const char text[]="windows dynamic DLL: references, forwarders, detach and reload ok\n";
    DWORD written;
    WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,sizeof(text)-1,&written,0);
    ExitProcess(written==sizeof(text)-1 ? 0 : 15);
}
