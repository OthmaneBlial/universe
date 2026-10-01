/* SDK ABI declarations only; no CRT, vendor DLL or host privilege changes. */
#define UNICODE
#include <windows.h>
#include <ntsecapi.h>
#include <stddef.h>
_Static_assert(sizeof(LUID)==8 && sizeof(LUID_AND_ATTRIBUTES)==12, "Windows privilege ABI");
_Static_assert(offsetof(TOKEN_PRIVILEGES,Privileges)==4, "Windows variable-array header");
static void require(int condition, DWORD code) { if (!condition) ExitProcess(code); }
void mainCRTStartup(void) {
    HANDLE library=LoadLibraryW(L"ADVAPI32"), kernel=GetModuleHandleW(L"KERNEL32.dll");
    require(library && library!=kernel && library==GetModuleHandleA("AdVaPi32.DlL"),1);
    BOOLEAN (WINAPI *random_api)(PVOID,ULONG)=(void *)GetProcAddress(library,"SystemFunction036");
    require(random_api!=0,2); /* The SDK declaration uses an import thunk, not a direct IAT pointer. */
    require(GetProcAddress(library,"OpenProcessToken")== (void *)OpenProcessToken,3);
    require(!GetProcAddress(kernel,"OpenProcessToken") && GetLastError()==ERROR_PROC_NOT_FOUND,4);
    require(!GetProcAddress(library,"WriteFile") && GetLastError()==ERROR_PROC_NOT_FOUND,5);
    require(!GetProcAddress(library,(const char *)1) && GetLastError()==ERROR_PROC_NOT_FOUND && FreeLibrary(library),6);
    HANDLE process=GetCurrentProcess(), token=(HANDLE)0x777;
    require(process==(HANDLE)-1 && CloseHandle(process),7);
    require(!OpenProcessToken((HANDLE)123,TOKEN_QUERY,&token) && GetLastError()==ERROR_INVALID_HANDLE && token==(HANDLE)0x777,8);
    require(!OpenProcessToken(process,SYNCHRONIZE,&token) && GetLastError()==ERROR_ACCESS_DENIED && token==(HANDLE)0x777,9);
    require(!OpenProcessToken(process,TOKEN_QUERY,0) && GetLastError()==ERROR_INVALID_PARAMETER,10);
    require(OpenProcessToken(process,TOKEN_QUERY|TOKEN_ADJUST_PRIVILEGES,&token),11);
    const WCHAR *names[]={
        SE_CREATE_TOKEN_NAME,SE_ASSIGNPRIMARYTOKEN_NAME,SE_LOCK_MEMORY_NAME,SE_INCREASE_QUOTA_NAME,
        SE_UNSOLICITED_INPUT_NAME,SE_MACHINE_ACCOUNT_NAME,SE_TCB_NAME,SE_SECURITY_NAME,
        SE_TAKE_OWNERSHIP_NAME,SE_LOAD_DRIVER_NAME,SE_SYSTEM_PROFILE_NAME,SE_SYSTEMTIME_NAME,
        SE_PROF_SINGLE_PROCESS_NAME,SE_INC_BASE_PRIORITY_NAME,SE_CREATE_PAGEFILE_NAME,SE_CREATE_PERMANENT_NAME,
        SE_BACKUP_NAME,SE_RESTORE_NAME,SE_SHUTDOWN_NAME,SE_DEBUG_NAME,SE_AUDIT_NAME,SE_SYSTEM_ENVIRONMENT_NAME,
        SE_CHANGE_NOTIFY_NAME,SE_REMOTE_SHUTDOWN_NAME,SE_UNDOCK_NAME,SE_SYNC_AGENT_NAME,SE_ENABLE_DELEGATION_NAME,
        SE_MANAGE_VOLUME_NAME,SE_IMPERSONATE_NAME,SE_CREATE_GLOBAL_NAME,SE_TRUSTED_CREDMAN_ACCESS_NAME,
        SE_RELABEL_NAME,SE_INC_WORKING_SET_NAME,SE_TIME_ZONE_NAME,SE_CREATE_SYMBOLIC_LINK_NAME,
        SE_DELEGATE_SESSION_USER_IMPERSONATE_NAME
    };
    LUID ids[sizeof(names)/sizeof(names[0])];
    for (unsigned n=0; n<sizeof(ids)/sizeof(ids[0]); ++n) {
        SetLastError(1234);
        require(LookupPrivilegeValueW(0,names[n],&ids[n]) && ids[n].LowPart && !ids[n].HighPart && GetLastError()==1234,12);
        for (unsigned p=0; p<n; ++p) require(ids[n].LowPart!=ids[p].LowPart,13);
    }
    LUID lock;
    require(LookupPrivilegeValueW(L"",L"sElOcKmEmOrYpRiViLeGe",&lock) && lock.LowPart==ids[2].LowPart,14);
    LUID unchanged={0x12345678,0x12345678};
    require(!LookupPrivilegeValueW(0,L"unknown",&unchanged) && GetLastError()==ERROR_NO_SUCH_PRIVILEGE && unchanged.LowPart==0x12345678,15);
    require(!LookupPrivilegeValueW(L"remote",SE_LOCK_MEMORY_NAME,&unchanged) && GetLastError()==ERROR_BAD_NETPATH,16);
    TOKEN_PRIVILEGES desired={1,{{lock,SE_PRIVILEGE_ENABLED}}}, previous={99,{{{55,66},77}}};
    DWORD needed=999;
    require(!AdjustTokenPrivileges(token,FALSE,&desired,0,&previous,&needed) && GetLastError()==ERROR_INSUFFICIENT_BUFFER && needed==4 && previous.PrivilegeCount==99,17);
    require(AdjustTokenPrivileges(token,FALSE,&desired,4,&previous,&needed) && GetLastError()==ERROR_NOT_ALL_ASSIGNED && !previous.PrivilegeCount && needed==4,18);
    require(AdjustTokenPrivileges(token,TRUE,(TOKEN_PRIVILEGES *)1,0,0,0) && GetLastError()==ERROR_SUCCESS,19);
    desired.PrivilegeCount=0;
    require(AdjustTokenPrivileges(token,FALSE,&desired,0,0,0) && GetLastError()==ERROR_SUCCESS,20);
    desired.PrivilegeCount=1;
    HANDLE query,adjust;
    require(OpenProcessToken(process,GENERIC_READ,&query) && OpenProcessToken(process,GENERIC_WRITE,&adjust),21);
    require(!AdjustTokenPrivileges(query,TRUE,0,0,0,0) && GetLastError()==ERROR_ACCESS_DENIED,22);
    require(!AdjustTokenPrivileges(adjust,FALSE,&desired,4,&previous,&needed) && GetLastError()==ERROR_ACCESS_DENIED,23);
    require(AdjustTokenPrivileges(adjust,FALSE,&desired,0,0,0) && GetLastError()==ERROR_NOT_ALL_ASSIGNED,24);
    require(CloseHandle(query) && CloseHandle(adjust) && CloseHandle(token),25);
    require(!CloseHandle(token) && GetLastError()==ERROR_INVALID_HANDLE,26);
    require(!AdjustTokenPrivileges(token,TRUE,0,0,0,0) && GetLastError()==ERROR_INVALID_HANDLE,27);
    HANDLE tokens[64];
    for (unsigned n=0; n<64; ++n) require(OpenProcessToken(process,MAXIMUM_ALLOWED,&tokens[n]),28);
    HANDLE overflow=(HANDLE)0x777;
    require(!OpenProcessToken(process,TOKEN_QUERY,&overflow) && GetLastError()==ERROR_NOT_ENOUGH_MEMORY && overflow==(HANDLE)0x777,29);
    for (unsigned n=0; n<64; ++n) require(CloseHandle(tokens[n]),30);
    require(OpenProcessToken(process,0,&token) && !AdjustTokenPrivileges(token,TRUE,0,0,0,0) && GetLastError()==ERROR_ACCESS_DENIED && CloseHandle(token),31);

    const HKEY roots[]={HKEY_CLASSES_ROOT,HKEY_CURRENT_USER,HKEY_LOCAL_MACHINE,HKEY_USERS,HKEY_CURRENT_CONFIG};
    SetLastError(4321);
    for (unsigned n=0; n<sizeof(roots)/sizeof(roots[0]); ++n) {
        HKEY opened=(HKEY)0x777;
        require(RegOpenKeyExW(roots[n],0,0,KEY_READ,&opened)==ERROR_SUCCESS && opened==roots[n] && RegCloseKey(opened)==ERROR_SUCCESS,32);
        require(RegOpenKeyExW(roots[n],L"",0,KEY_QUERY_VALUE|KEY_WOW64_32KEY,&opened)==ERROR_SUCCESS && opened==roots[n],33);
        require(RegOpenKeyExW(roots[n],L"Software\\7-Zip",0,KEY_READ,&opened)==ERROR_FILE_NOT_FOUND && opened==roots[n],34);
        require(RegQueryValueExW(roots[n],L"",0,0,0,0)==ERROR_FILE_NOT_FOUND,35);
    }
    HKEY key=(HKEY)0x777;
    DWORD kind=77,size=4; BYTE data[4]={1,2,3,4};
    require(RegQueryValueExW(HKEY_CURRENT_USER,L"missing",0,&kind,data,&size)==ERROR_FILE_NOT_FOUND && kind==77 && size==4 && data[0]==1 && data[3]==4,36);
    require(RegQueryValueExW(HKEY_CURRENT_USER,0,(DWORD *)1,0,0,0)==ERROR_INVALID_PARAMETER,37);
    require(RegQueryValueExW(HKEY_CURRENT_USER,0,0,0,data,0)==ERROR_INVALID_PARAMETER,38);
    require(RegOpenKeyExW(HKEY_CURRENT_USER,0,1,KEY_READ,&key)==ERROR_INVALID_PARAMETER,39);
    require(RegOpenKeyExW(HKEY_CURRENT_USER,0,0,KEY_READ|KEY_WOW64_32KEY|KEY_WOW64_64KEY,&key)==ERROR_INVALID_PARAMETER,40);
    require(RegOpenKeyExW(HKEY_CURRENT_USER,0,0,KEY_WRITE,&key)==ERROR_ACCESS_DENIED,41);
    require(RegOpenKeyExW(HKEY_CURRENT_USER,0,0,KEY_READ,0)==ERROR_INVALID_PARAMETER,42);
    require(RegCloseKey((HKEY)7)==ERROR_INVALID_HANDLE && RegQueryValueExW((HKEY)7,0,0,0,0,0)==ERROR_INVALID_HANDLE,43);
    require(RegOpenKeyExW(HKEY_PERFORMANCE_DATA,0,0,KEY_READ,&key)==ERROR_NOT_SUPPORTED && RegQueryValueExW(HKEY_PERFORMANCE_TEXT,0,0,0,0,0)==ERROR_NOT_SUPPORTED,44);
    require(GetLastError()==4321 && key==(HKEY)0x777,45);

    BYTE *random=VirtualAlloc(0,12288,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    require(random && (ULONG_PTR)random>0xffffffffULL,46);
    for (unsigned n=0; n<8198; ++n) random[n]=0xa5;
    SetLastError(6789);
    require(RtlGenRandom(random+1,8196) && random[0]==0xa5 && random[8197]==0xa5 && GetLastError()==6789,47);
    BYTE second[64];require(random_api(second,sizeof(second)) && RtlGenRandom(0,0),48);
    int difference=0;for (unsigned n=0; n<64; ++n) difference|=random[n+1]^second[n];
    require(difference && VirtualFree(random,0,MEM_RELEASE),49);
    BYTE descriptor[32]={0};needed=1234;
    require(!GetFileSecurityW(L"unused",DACL_SECURITY_INFORMATION,descriptor,sizeof(descriptor),&needed),50);
    DWORD security_error=GetLastError();require(security_error==ERROR_ACCESS_DENIED || security_error==ERROR_NOT_SUPPORTED,51);
    require(needed==1234 && !descriptor[0] && !SetFileSecurityW(L"unused",DACL_SECURITY_INFORMATION,descriptor) && GetLastError()==security_error,52);
    const char output[]="windows security: entropy, token rights, empty registry and explicit ACL limits ok\n";
    DWORD written;require(WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),output,sizeof(output)-1,&written,0) && written==sizeof(output)-1,53);
    ExitProcess(0);
}
