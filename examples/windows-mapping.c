/* SDK-only sections: shared aliases, guest-page COW, names, file bytes and lifetimes. */
#include <windows.h>
static void require(int condition,DWORD code) { if(!condition)ExitProcess(code); }
static void output(const void *text,DWORD length) { DWORD written=0;require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,length,&written,0)&&written==length,200); }
static int mode(const char *name) {
    const char *line=GetCommandLineA();unsigned length=0,size=0;
    while(line[length])++length;while(name[size])++size;
    if(length<size+2||line[length-1]!='"'||line[length-size-2]!='"')return 0;
    for(unsigned i=0;i<size;++i)if(line[length-size-1+i]!=name[i])return 0;return 1;
}
void mainCRTStartup(void) {
    DWORD eax=1,ebx,ecx,edx;
    __asm__ volatile("cpuid":"+a"(eax),"=b"(ebx),"=c"(ecx),"=d"(edx));
    SetLastError(777);
    for(DWORD feature=0;feature<64;++feature) {
        BOOL expected=feature==PF_COMPARE_EXCHANGE_DOUBLE || feature==PF_MMX_INSTRUCTIONS_AVAILABLE || feature==PF_XMMI_INSTRUCTIONS_AVAILABLE || feature==PF_XMMI64_INSTRUCTIONS_AVAILABLE || feature==PF_RDTSC_INSTRUCTION_AVAILABLE || feature==PF_PAE_ENABLED || feature==PF_NX_ENABLED || feature==PF_COMPARE_EXCHANGE128;
        require(!!IsProcessorFeaturePresent(feature)==expected && GetLastError()==777,60);
    }
    require(!IsProcessorFeaturePresent(0xffffffff) && GetLastError()==777,61);
    require(!!IsProcessorFeaturePresent(PF_COMPARE_EXCHANGE_DOUBLE)==!!(edx&(1U<<8)) && !!IsProcessorFeaturePresent(PF_MMX_INSTRUCTIONS_AVAILABLE)==!!(edx&(1U<<23)) && !!IsProcessorFeaturePresent(PF_RDTSC_INSTRUCTION_AVAILABLE)==!!(edx&(1U<<4)) && !!IsProcessorFeaturePresent(PF_COMPARE_EXCHANGE128)==!!(ecx&(1U<<13)),62);
    require(IsProcessorFeaturePresent(PF_XMMI_INSTRUCTIONS_AVAILABLE) && (edx&(1U<<25)) && IsProcessorFeaturePresent(PF_XMMI64_INSTRUCTIONS_AVAILABLE) && (edx&(1U<<26)),63);
    MEMORYSTATUSEX before={0},during={0},after={0};
    before.dwLength=63;before.dwMemoryLoad=0xabcdef01;
    require(!GlobalMemoryStatusEx(&before) && GetLastError()==ERROR_INVALID_PARAMETER && before.dwMemoryLoad==0xabcdef01,64);
    before.dwLength=sizeof(before);during.dwLength=sizeof(during);after.dwLength=sizeof(after);SetLastError(777);
    require(sizeof(before)==64 && GlobalMemoryStatusEx(&before) && GetLastError()==777 && before.ullTotalPhys==256ULL*1024*1024 && before.ullTotalPageFile==before.ullTotalPhys && before.ullAvailPageFile==before.ullAvailPhys && before.ullTotalVirtual==0x800000000000ULL-65536 && before.ullAvailExtendedVirtual==0 && before.dwMemoryLoad==((before.ullTotalPhys-before.ullAvailPhys)*100/before.ullTotalPhys),65);
    void *allocation=VirtualAlloc(0,65537,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);require(allocation!=0,66);
    require(GlobalMemoryStatusEx(&during) && during.ullAvailPhys+69632==before.ullAvailPhys && during.ullAvailPageFile+69632==before.ullAvailPageFile && during.ullAvailVirtual+69632==before.ullAvailVirtual,67);
    require(VirtualFree(allocation,0,MEM_RELEASE) && GlobalMemoryStatusEx(&after) && after.ullAvailPhys==before.ullAvailPhys && after.ullAvailVirtual==before.ullAvailVirtual,68);
    SYSTEM_INFO info,native;
    GetSystemInfo(&info);GetNativeSystemInfo(&native);
    require(sizeof(info)==48 && info.wProcessorArchitecture==PROCESSOR_ARCHITECTURE_AMD64 && info.dwPageSize==4096 && info.dwAllocationGranularity==65536 && info.dwNumberOfProcessors==1 && info.dwActiveProcessorMask==1 && native.wProcessorArchitecture==info.wProcessorArchitecture,1);
    if(mode("file") || mode("file-fault")) {
        HANDLE file=CreateFileW(L"mapping.bin",GENERIC_READ|GENERIC_WRITE,7,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);
        if(file==INVALID_HANDLE_VALUE) { require(GetLastError()==ERROR_ACCESS_DENIED,2);output("windows mapping: denied\n",24);ExitProcess(0); }
        HANDLE section=CreateFileMappingW(file,0,PAGE_READWRITE,1,65537,L"Local\\universe.file.section");require(section!=0,3);
        LARGE_INTEGER size;require(GetFileSizeEx(file,&size) && size.QuadPart==((LONGLONG)1<<32)+65537,4);
        volatile unsigned char *low=MapViewOfFile(section,FILE_MAP_WRITE,0,0,17);
        volatile unsigned char *high=MapViewOfFile(section,FILE_MAP_WRITE,1,0,65537);
        require(low && high && low[0]==0xa1 && low[16]==0xa2 && high[0]==0 && high[65536]==0,5);
        low[0]=0xb1;high[0]=0xf1;high[65536]=0xf2;
        if(mode("file-fault")) { *(volatile DWORD*)0=1;ExitProcess(6); }
        require(CreateHardLinkW(L"mapping-link.bin",L"mapping.bin",0),7);
        HANDLE second=CreateFileW(L"mapping-link.bin",GENERIC_READ,7,0,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,0);require(second!=INVALID_HANDLE_VALUE,8);
        require(!CreateFileMappingW(second,0,PAGE_READWRITE,0,0,0) && GetLastError()==ERROR_ACCESS_DENIED,9);
        HANDLE other=CreateFileMappingW(second,0,PAGE_READONLY,0,0,0);require(other!=0,10);
        volatile unsigned char *reader=MapViewOfFile(other,FILE_MAP_READ,1,0,65537);
        volatile unsigned char *copy=MapViewOfFile(other,FILE_MAP_COPY,1,0,65537);
        require(reader && copy && reader[0]==0xf1 && reader[65536]==0xf2 && copy[0]==0xf1,11);
        copy[0]=0xa0;require(high[0]==0xf1 && reader[0]==0xf1,12);
        high[4097]=0xf3;require(copy[4097]==0xf3,13);
        high[0]=0xf4;require(copy[0]==0xa0 && reader[0]==0xf4,14);
        require(FlushViewOfFile((const void *)(high+1),1) && FlushViewOfFile((const void *)low,0),15);
        require(!SetEndOfFile(file) && GetLastError()==ERROR_USER_MAPPED_FILE,16);
        require(CreateFileW(L"mapping.bin",GENERIC_READ|GENERIC_WRITE,7,0,CREATE_ALWAYS,FILE_ATTRIBUTE_NORMAL,0)==INVALID_HANDLE_VALUE && GetLastError()==ERROR_USER_MAPPED_FILE,17);
        require(CloseHandle(file) && CloseHandle(second) && CloseHandle(section) && CloseHandle(other),18);
        HANDLE reopened=OpenFileMappingW(FILE_MAP_READ,FALSE,L"universe.file.section");require(reopened!=0 && CloseHandle(reopened),19);
        output("FLUSH\n",6);char byte;DWORD count=0;require(ReadFile(GetStdHandle(STD_INPUT_HANDLE),&byte,1,&count,0)&&count==1&&byte=='Z',20);
        require(DeleteFileW(L"mapping.bin"),21);
        require(UnmapViewOfFile((const void*)low) && UnmapViewOfFile((const void*)reader) && UnmapViewOfFile((const void*)high) && UnmapViewOfFile((const void*)copy),22);
        require(!OpenFileMappingW(FILE_MAP_READ,FALSE,L"universe.file.section") && GetLastError()==ERROR_FILE_NOT_FOUND,23);
        require(GetFileAttributesW(L"mapping.bin")==INVALID_FILE_ATTRIBUTES && GetLastError()==ERROR_FILE_NOT_FOUND,24);
        const char message[]="windows mapping: coherent file aliases, sparse offsets, flush and deletion lifetimes ok\n";output(message,sizeof(message)-1);ExitProcess(0);
    }
    require(!CreateFileMappingW(INVALID_HANDLE_VALUE,0,PAGE_READWRITE,0,0,0) && GetLastError()==ERROR_INVALID_PARAMETER,30);
    require(!CreateFileMappingW(INVALID_HANDLE_VALUE,0,PAGE_READWRITE|SEC_RESERVE,0,8193,0) && GetLastError()==ERROR_NOT_SUPPORTED,31);
    HANDLE section=CreateFileMappingW(INVALID_HANDLE_VALUE,0,PAGE_READWRITE,0,8193,L"Local\\universe.section");require(section!=0 && GetLastError()==0,32);
    HANDLE same=CreateFileMappingW(INVALID_HANDLE_VALUE,0,PAGE_READONLY,0,1,L"universe.section");require(same!=0 && GetLastError()==ERROR_ALREADY_EXISTS,33);
    HANDLE read=OpenFileMappingW(FILE_MAP_READ,FALSE,L"Local\\universe.section");require(read!=0,34);
    HANDLE copy_handle=OpenFileMappingW(FILE_MAP_COPY,FALSE,L"universe.section");require(copy_handle!=0,35);
    volatile unsigned char *shared=MapViewOfFile(section,FILE_MAP_WRITE,0,0,0);
    volatile unsigned char *reader=MapViewOfFileEx(read,FILE_MAP_READ,0,0,0,(void *)0x300000000ULL);
    volatile unsigned char *copy=MapViewOfFile(copy_handle,FILE_MAP_COPY,0,0,0);
    require(shared && reader==(void*)0x300000000ULL && copy && shared[8192]==0 && reader[8192]==0,36);
    SetLastError(777);shared[1]=11;require(reader[1]==11 && copy[1]==11 && GetLastError()==777,37);
    copy[2]=22;shared[1]=33;shared[4097]=44;require(copy[1]==11 && copy[4097]==44 && shared[2]==0,38);
    *(volatile ULONGLONG *)(copy+4094)=0x8877665544332211ULL;shared[4097]=55;require(copy[4097]==0x44 && shared[4094]==0,39);
    require(!MapViewOfFile(read,FILE_MAP_WRITE,0,0,1) && GetLastError()==ERROR_ACCESS_DENIED,40);
    require(!MapViewOfFile(section,FILE_MAP_READ,0,1,1) && GetLastError()==ERROR_MAPPED_ALIGNMENT,41);
    require(!MapViewOfFile(section,FILE_MAP_READ,0,0,8194) && GetLastError()==ERROR_INVALID_PARAMETER,42);
    require(!MapViewOfFileEx(section,FILE_MAP_READ,0,0,1,(void*)reader) && GetLastError()==ERROR_INVALID_ADDRESS,43);
    require(!UnmapViewOfFile((const void*)(shared+1)) && GetLastError()==ERROR_INVALID_ADDRESS,44);
    require(!VirtualFree((void*)shared,0,MEM_RELEASE) && GetLastError()==ERROR_INVALID_ADDRESS,45);
    require(!FlushViewOfFile((const void*)shared,12289) && GetLastError()==ERROR_INVALID_PARAMETER,46);
    require(!CreateEventW(0,TRUE,FALSE,L"universe.section") && GetLastError()==ERROR_INVALID_HANDLE,47);
    HANDLE event=CreateEventW(0,TRUE,FALSE,L"universe.event");require(event && !CreateFileMappingW(INVALID_HANDLE_VALUE,0,PAGE_READWRITE,0,4096,L"universe.event") && GetLastError()==ERROR_INVALID_HANDLE,48);
    require(CloseHandle(event) && CloseHandle(section) && CloseHandle(same) && CloseHandle(read) && CloseHandle(copy_handle),49);
    HANDLE reopened=OpenFileMappingW(FILE_MAP_READ,FALSE,L"universe.section");require(reopened && CloseHandle(reopened),50);
    if(mode("ro-fault")) { reader[0]=1;ExitProcess(51); }
    require(UnmapViewOfFile((const void*)shared) && reader[1]==33 && UnmapViewOfFile((const void*)reader) && copy[2]==22 && UnmapViewOfFile((const void*)copy),52);
    require(!OpenFileMappingW(FILE_MAP_READ,FALSE,L"universe.section") && GetLastError()==ERROR_FILE_NOT_FOUND,53);
    HANDLE machine=CreateFileMappingW(INVALID_HANDLE_VALUE,0,PAGE_EXECUTE_READWRITE,0,4096,0);require(machine!=0,54);
    volatile unsigned char *code=MapViewOfFile(machine,FILE_MAP_ALL_ACCESS|FILE_MAP_EXECUTE,0,0,4096);
    unsigned char *execute=MapViewOfFile(machine,FILE_MAP_READ|FILE_MAP_EXECUTE,0,0,4096);
    unsigned char *private_code=MapViewOfFile(machine,FILE_MAP_COPY|FILE_MAP_EXECUTE,0,0,4096);
    require(code && execute && private_code,55);
    code[0]=0xb8;code[1]=42;code[2]=0;code[3]=0;code[4]=0;code[5]=0xc3;
    require(((int(*)())execute)()==42,56);code[1]=43;require(((int(*)())execute)()==43,57);
    private_code[1]=44;code[1]=45;require(((int(*)())private_code)()==44 && ((int(*)())execute)()==45,58);
    require(CloseHandle(machine) && UnmapViewOfFile((const void*)code) && UnmapViewOfFile(execute) && UnmapViewOfFile(private_code),59);
    const char message[]="windows mapping: shared sections, guest-page COW, names and view lifetimes ok\n";output(message,sizeof(message)-1);ExitProcess(0);
}
