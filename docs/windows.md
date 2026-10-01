# PE32+ Windows milestone

Current main executes source-built Windows x86-64 fixtures on ARM64 macOS:
Hello World, stdin/stdout echo, virtual-memory allocation/free, process heap and
Unicode command lines, regular-file operations and an executable importing two
guest DLLs, runtime DLL loading/unloading, static TLS in executables and DLLs,
the 64 documented-minimum dynamic TLS slots for the initial guest thread, and
OLEAUT32 BSTR allocation/ownership and scalar/string/by-reference VARIANTs,
plus USER32 uppercase conversion and code-page-aware backward navigation.
ADVAPI32 adds entropy, process-token handles/access checks and an empty read-only
registry. Windows file ACL calls are recognized but return explicit failures.
Our own legacy MSVCRT subset adds allocation, strings, original argv and data
imports, unbuffered standard streams and guest initializer/exit callbacks.
Single-thread events/semaphores, recursive critical sections, pending waits
and virtual process/thread identity and clocks now have their own Win32 APIs.
TLS fixtures verify callback ordering, dynamic unload, fresh template
initialization after reload, and dynamic slot reuse. Process/file/DLL fixtures
also pass with the partial ARM64 JIT.
They are newer than v0.1.0.
The unknown-import fixture fails explicitly rather than substituting a stub.

The official Windows x64 7-Zip 26.03 `7za.exe` was also inspected and attempted
unchanged. Its six OLEAUT32 ordinal imports now bind to UNIVERSE's own APIs;
Its two USER32, nine ADVAPI32 and all 39 MSVCRT imports now bind too.
`--syscalls` now binds synchronization/identity APIs and MoveFileW, then shows the next boundary
at `KERNEL32!LocalFileTimeToFileTime`
(`UnsupportedWindowsImport`, exit 125), before the executable entry runs.
Recognized exception/RTTI entries would still stop if called; other CRT and
KERNEL32 behavior exceeds this subset. The Linux `7zzs`
archive workflows now pass on the same Mac; this does not establish Windows
7-Zip compatibility. See [the downloaded-app evidence](public-apps.md).

The PE parser validates MZ, PE signature, x86-64 machine type, PE32+ optional
header, data directory bounds, sections and page overlap. The loader reserves
the complete image range, maps headers/sections with their permissions, leaves
image gaps inaccessible and zero fills virtual tails. Failed image loads remove
their mappings, including failures injected at every allocation point. DIR64 base relocation is
implemented and tested with a relocated synthetic image, including an RX target,
and source-built DLLs with absolute data pointers. Executables use their preferred
base; DLLs are rebased when that range is occupied. A DLL with no entry point can
be loaded, but invoking a DLL directly as the main executable is rejected.

The PE loader validates TLS directories, raw template bounds, writable TLS
indices, alignment and executable callback targets. It creates one TLS vector
for the guest's initial thread, copies each module's template and zero-fill area,
assigns its TLS index, and exposes the vector through GS:[0x58]. The runtime
invokes TLS callbacks in table order before that module's process-attach
DllMain; the executable's TLS callbacks run before its entry point. Explicit
FreeLibrary runs DllMain and TLS process-detach callbacks before unmapping the
module. Process-termination detach is not implemented. Native Windows callback
ordering has not been differentially tested.

The import binder handles named APIs from kernel32.dll/kernelbase.dll and
named/ordinal APIs from oleaut32.dll and named USER32/ADVAPI32/MSVCRT APIs, maps
guest API gateways, and writes guest addresses into the IAT. Static guest DLL
dependencies are loaded recursively from the explicitly supplied sysroot.
Their named/ordinal function and data exports, including forwarded exports,
are resolved in checked guest memory. Built-in DLLs have distinct handles and
export namespaces, including runtime GetProcAddress and guest DLL forwarders;
unknown APIs/ordinals and delay imports fail clearly. The API gateway follows
Windows x64 RCX/RDX/R8/R9 argument
registers, shadow space, stack arguments and return addresses.

| Area | Implemented APIs |
|---|---|
| Process / console | ExitProcess, GetStdHandle, GetLastError, SetLastError, GetCurrentProcess |
| Modules | GetModuleHandleA/W, GetProcAddress, LoadLibraryA/W, FreeLibrary |
| Dynamic TLS | TlsAlloc, TlsFree, TlsGetValue, TlsSetValue (64 slots, one guest thread) |
| Command line | GetCommandLineA/W, GetACP |
| Memory | VirtualAlloc, VirtualFree, GetProcessHeap, HeapAlloc, HeapReAlloc, HeapFree, HeapSize |
| Regular files | CreateFileA/W, ReadFile, WriteFile, CloseHandle, GetFileSize/Ex, SetFilePointer/Ex, SetEndOfFile, FlushFileBuffers, GetFileInformationByHandle |
| File mutations / attributes | MoveFileW/ExW/WithProgressW (same volume; null callback), CreateDirectoryW, RemoveDirectoryW, CreateHardLinkW, DeleteFileW, GetFileAttributesW, SetFileAttributesW (normal/read-only regular files) |
| Automation (OLEAUT32) | SysAllocString (#2), SysAllocStringLen (#4), SysFreeString (#6), SysStringLen (#7), VariantInit (#8), VariantClear (#9), VariantCopy (#10) |
| String utilities (USER32) | CharUpperW, CharPrevExA |
| Entropy (ADVAPI32) | SystemFunction036 / RtlGenRandom |
| Process tokens (ADVAPI32) | OpenProcessToken, LookupPrivilegeValueW, AdjustTokenPrivileges (no assigned Windows privileges) |
| Registry (ADVAPI32) | RegOpenKeyExW, RegQueryValueExW, RegCloseKey (five empty read-only roots) |
| File security boundary (ADVAPI32) | GetFileSecurityW, SetFileSecurityW (failure only; Windows ACLs unsupported) |
| Synchronization | CreateEventW/OpenEventW, SetEvent/ResetEvent, CreateSemaphoreW/OpenSemaphoreW, ReleaseSemaphore, WaitForSingleObject/WaitForMultipleObjects |
| Critical sections | InitializeCriticalSection/AndSpinCount, SetCriticalSectionSpinCount, Enter/TryEnter/Leave/DeleteCriticalSection (one thread) |
| Virtual identity / clocks | GetCurrentThread, GetCurrentProcessId/GetCurrentThreadId, affinity queries/setters, ResumeThread (existing current thread only), GetTickCount/64, QueryPerformanceCounter/Frequency, GetVersion, GetOEMCP, GetLargePageMinimum |
| Legacy C runtime (MSVCRT) | Allocation/copy/string functions, argc/argv and data exports, standard-stream I/O, guest initialization and exit callbacks; see below |

## Single-thread synchronization, identity and clocks

Events and semaphores are objects owned by this runtime, with distinct handles,
shared references, access masks and a 1,024-live-handle limit. Closing the last
handle destroys the object/name; stale handles stay invalid when slots are reused.
Their handle IDs share the existing allocator with files and process tokens.
Named W objects compare exact case-sensitive UTF-8 decoded from checked UTF-16,
with a 260-unit input limit. Unprefixed names and `Local\` names share the virtual
local namespace. Global/private namespaces, security attributes and handle
inheritance return ERROR_NOT_SUPPORTED. There is no host named-object access,
IPC, Windows ACL emulation or guest process creation.

CreateEventW/OpenEventW and CreateSemaphoreW/OpenSemaphoreW return new handles
to the same named object, with ERROR_ALREADY_EXISTS for a repeated create.
Repeated create ignores the existing object's requested initial/reset/count
parameters. An event/semaphore name collision fails with ERROR_INVALID_HANDLE.
Open calls retain explicit specific/standard access masks; generic and
MAXIMUM_ALLOWED/security rights are not supported. Modify operations require
MODIFY_STATE and waits require SYNCHRONIZE. No host rights are granted.
See [events](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createeventw)
and [semaphores](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-createsemaphorew).

Auto-reset events are consumed by one successful wait; manual events remain
signaled until ResetEvent. SetEvent does not accumulate tokens. Semaphore
waits consume one count and ReleaseSemaphore validates positive LONG counts,
maximum limits and optional output memory before changing state. A failed
release preserves the count and previous-count output.

WaitForSingleObject/WaitForMultipleObjects validate the complete handle array
before consuming state. Wait-any selects the first ready array index. Wait-all
changes no event/count unless every object is ready. Zero-timeout polling
returns WAIT_TIMEOUT when unready; finite waits honor elapsed monotonic time.
Pending calls remain at the API gateway, poll in intervals up to 1 ms, and
continue checking the runtime execution deadline without inflating guest
instruction/API counts. INFINITE waits remain pending until readiness or the
runtime timeout; disabling that timeout can leave a call pending indefinitely.
The current process/thread pseudo handles are live and therefore nonsignaled.

The documented 64-handle count and exact duplicate-handle rejection apply.
Wait-all through distinct handles aliasing the same object is explicitly
unsupported until native differential behavior is verified. Mutexes, other
waitable object types, alertable waits, cross-thread scheduling and notifications
remain absent. These APIs do not create guest threads.
See [wait and consume rules](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitformultipleobjects).

Critical sections use the SDK's 40-byte x64 layout and an address/recursion
registry, capped at 1,024 live sections. Enter/TryEnter permit recursive ownership
by the initial thread; Leave releases one level. Invalid/uninitialized use,
reinitialization without delete, unowned leave and deleting a held section stop
explicitly. Output faults preserve the registered state. One virtual processor
means spin counts stay zero; no host mutex, debug-info allocation or contended
thread queue is involved. The logically opaque private fields are a local model,
not a native Windows version's internal LockCount-bit layout.
See [critical-section contract](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-initializecriticalsectionandspincount).

Process/thread IDs are 1, consistent with the guest TEB. GetCurrentThread returns
the current-thread pseudo handle (-2). ResumeThread accepts that existing,
never-suspended thread and returns its previous count, zero; unknown handles
fail. Affinity queries return process/system mask 1 and setters accept that
one-processor mask for the current pseudo handles only. No suspended or new
thread is fabricated; `_beginthreadex` still fails explicitly.

GetTickCount/64 measure virtual uptime since process initialization, with the
DWORD form wrapping at 32 bits. QueryPerformanceCounter exposes the host
monotonic nanosecond counter and frequency 1,000,000,000; it does not claim
nanosecond clock resolution or native CPU cycles. GetOEMCP uses the existing
UTF-8 guest policy (65001). GetLargePageMinimum returns zero because guest
large-page allocations are unavailable. GetVersion returns the declared virtual
NT 6.2/build 9200 compatibility metadata, not macOS or a claim of full Windows 8
behavior. Manifest-sensitive Windows version logic, system-sleep timing and
native Windows differential testing are unverified.

`examples/windows-sync.c` uses SDK declarations without a CRT or vendor DLL.
Both engines verify reference lifetimes, Unicode names, access masks, event and
semaphore consumption, wait-all failure preservation, recursive ownership,
1,100 slot-reuse cycles, clocks and finite/infinite wait deadlines. Unit checks
cover 1,024-handle exhaustion, token separation and memory faults before writes
or state changes. `tests/integration.py` independently checks elapsed wait time
and bounded runtime-timeout interruption.

## Legacy MSVCRT subset

This is our own Windows x64 implementation, with no vendor CRT DLL or host
execution of guest callbacks. Named function exports resolve to checked API
gateways; `_iob`, `_fmode`, `_commode` and `__initenv` resolve to writable guest
data. `_iob` has 20 legacy 48-byte FILE slots; only stdin/stdout/stderr are open.
This is not the UCRT opaque FILE ABI, UCRT DLL aliases or arbitrary CRT support.

`malloc`, `calloc`, `realloc` and `free` reuse page-rounded guest allocations,
16-byte aligned, with ownership distinct from Windows heap/VirtualAlloc/BSTRs.
Zero-size allocation returns a freeable block; realloc with a non-null block
and zero size frees it. Failed growth preserves the original block and sets
ENOMEM. One mapping per block shares the runtime's 1,024-region ceiling.
`memcpy`, `memmove`, `memset` and `memcmp` use full 64-bit size_t counts and
check complete ranges before writes. Overlap-safe copies cross page/chunk
boundaries. String functions provide byte `strlen`/`strcmp` and raw UTF-16
`wcscmp`/`wcsstr`, without locale conversion or expanding case mappings.

`__getmainargs` exposes the original UTF-8 arguments including argv[0], empty
arguments, quotes, trailing backslashes and Unicode. argv[argc] is NULL and the
initial environment is an empty NULL-terminated array, shared with `__initenv`.
All output pointers are checked before any output is written. Wildcard expansion
and nonzero startup newmode stop explicitly; PE `--env` remains unsupported.
See Microsoft's [argument contract](https://learn.microsoft.com/en-us/cpp/c-runtime-library/getmainargs-wgetmainargs).

The three unbuffered streams provide `fgetc`, `fputc`, `fputs` and `fflush`,
legacy EOF/error flags, `_fileno`, `_get_osfhandle` and `_isatty`. File descriptors
are guest 0/1/2 only; no host descriptor is exposed. Text mode translates output
LF to CRLF, input CRLF to LF and Ctrl-Z to sticky EOF; binary mode preserves all
256 byte values. `_setmode` accepts `_O_TEXT`/`_O_BINARY`, returning the previous
mode. Invalid descriptors/modes set EBADF/EINVAL. `_errno`, `__doserrno`,
`__p__fmode`, `__iob_func` and the compatibility `__acrt_iob_func` expose this
legacy state. There is no buffered CRT file I/O, fopen, printf, wide-stream
mode or locale support. `fflush` has no pending output to commit and discards
input lookahead for an input stream.

`_initterm` invokes non-null table entries in order through the guest CPU;
nested initializers are supported with a 64-frame limit. `_onexit` registers
process callbacks and `_cexit`/`exit` run them in reverse registration order,
including callbacks added while unwinding. `_cexit` closes the guest CRT streams
and returns; `exit` then terminates. `_c_exit` returns without those callbacks;
`_exit` terminates immediately. Host standard streams remain borrowed and open.
`__dllonexit` appends to a separate caller-owned CRT allocation; the DLL caller
must invoke its own table. `_onexit` from DLL attach/TLS callbacks or a DLL
return address stops explicitly until per-DLL lifetime ownership exists.
See [_initterm](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/initterm-initterm-e),
[_onexit](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/onexit-onexit-m),
[__dllonexit](https://learn.microsoft.com/en-us/cpp/c-runtime-library/dllonexit) and
[cleanup/exit contracts](https://learn.microsoft.com/en-us/cpp/c-runtime-library/reference/cexit-c-exit).

`__set_app_type` records valid startup metadata, without GUI support.
`__setusermatherr` accepts a null handler only; CRT math functions are absent.
`_beginthreadex` fails with EAGAIN/ERROR_NOT_SUPPORTED and creates no thread;
invalid null callbacks/flags fail with EINVAL/ERROR_INVALID_PARAMETER. Exception
entries (`_XcptFilter`, `__C_specific_handler`, `__CxxFrameHandler`,
`_CxxThrowException`) are recognized but stop on invocation, as does the RTTI
destructor. `_purecall` and default C++ terminate end the guest with status 3.
These explicit boundaries must not be counted as exception/RTTI support.

The SDK-declared `examples/windows-crt.c` uses an import library containing only
symbol declarations. Compile-time assertions verify the legacy FILE ABI; the
PE import inventory verifies function and real writable data imports. Exact
outputs, statuses, memory failure paths and callbacks pass in both engines.
Native Windows differential testing has not been performed.

## ADVAPI32 process services and limits

SystemFunction036, the DLL export for RtlGenRandom, fills checked guest buffers
using the existing host entropy source. The complete destination is validated
before entropy collection or writes. Requests are bounded by the guest memory
limit; zero bytes need no valid buffer. A failed entropy/allocation operation
returns FALSE without writing guest data; successful calls preserve LastError.
See Microsoft's [RtlGenRandom contract](https://learn.microsoft.com/en-us/windows/win32/api/ntsecapi/nf-ntsecapi-rtlgenrandom).

GetCurrentProcess returns the Windows current-process pseudo handle (-1).
OpenProcessToken accepts that process and returns a distinct closable handle,
retaining the requested token access rights, including generic/MAXIMUM_ALLOWED
mapping. Invalid handles, unsupported rights and null output pointers fail.
There are at most 64 live token handles; closing one frees its slot, and stale
handles remain invalid. Closing the current-process pseudo handle has no effect.
LookupPrivilegeValueW recognizes the 36 SDK privilege names case-insensitively
and returns stable local LUIDs. Null/empty system names identify this virtual
process; remote systems and unknown privileges fail without overwriting the LUID.
See [OpenProcessToken](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-openprocesstoken)
and [privilege-name lookup](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-lookupprivilegevaluew).

This virtual process has **no assigned Windows privileges**. AdjustTokenPrivileges
requires TOKEN_ADJUST_PRIVILEGES and, when returning PreviousState, TOKEN_QUERY.
Disabling all privileges or an empty request succeeds with ERROR_SUCCESS.
Nonempty requests return BOOL success with ERROR_NOT_ALL_ASSIGNED; no host rights
are granted. PreviousState contains a zero count, with a four-byte required size.
Too-small buffers return ERROR_INSUFFICIENT_BUFFER and the required size.
Inputs and writable outputs are checked before normal output mutation.
This is a restricted virtual-token profile, not the host user's Windows token
or a complete access-control implementation. See the
[adjustment contract](https://learn.microsoft.com/en-us/windows/win32/api/securitybaseapi/nf-securitybaseapi-adjusttokenprivileges).

The registry exposes five **empty read-only** predefined roots: classes,
current user, local machine, users and current configuration. Null/empty subkey
opens return the same root handle; named subkeys and all values return
ERROR_FILE_NOT_FOUND. Read/execute/maximum-allowed access and either WOW64 view
are accepted; write rights are denied, and contradictory view flags or reserved
parameters fail. Special performance/legacy roots return ERROR_NOT_SUPPORTED.
Registry functions return LSTATUS directly and preserve LastError.
No host registry, stored settings, registry writes or persistence is provided.
See [RegOpenKeyExW](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regopenkeyexw)
and [RegQueryValueExW](https://learn.microsoft.com/en-us/windows/win32/api/winreg/nf-winreg-regqueryvalueexw).

GetFileSecurityW and SetFileSecurityW return ERROR_ACCESS_DENIED without the file
grant, or ERROR_NOT_SUPPORTED with it. They neither query nor change host file
permissions, and do not fabricate Windows security descriptors. Existing regular
file APIs still use host-user permissions. Windows ACL translation remains future
work; recognizing these imports does not establish ACL compatibility.

The SDK-declared guest checks both named/runtime entropy routes, high guest
addresses, guard bytes, all privilege names, rights, stale handles, token-table
exhaustion/reuse, adjustment buffer sizes, registry status/LastError behavior and
both file-security failure policies in interpreter/JIT modes. A separate checked
memory regression verifies invalid output buffers before changes. Native Windows
differential testing remains unverified.

## USER32 string utilities

CharUpperW accepts a single UTF-16 code unit encoded in a pointer-sized value
at most 0xffff, or a full 64-bit pointer to a terminated string. It returns the
converted unit or the original string pointer and converts string data in place.
The complete readable string and writable destination are checked before
mutation, including page crossings. Empty strings, embedded terminators and
unpaired surrogates retain their code-unit behavior.

The case model uses Unicode 17.0.0 **BMP simple-uppercase mappings**: 1,198
mapped units in 192 generated ranges. No host locale, Unicode library or runtime
download is used. There are no multi-unit expansions: sharp s stays sharp s,
while Greek simple mappings and dotless i follow the one-unit table. Surrogate
units stay unchanged; supplementary-character casing and native Windows NLS
version parity are not established. See the
[CharUpperW contract](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-charupperw)
and [Unicode data fields](https://www.unicode.org/reports/tr44/).
The original data SHA-256 is
`2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c`;
its license notice is retained in [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES.md).

CharPrevExA scans from the supplied start to identify the preceding character,
including ambiguous DBCS lead/trail-byte runs. It uses the lead-byte ranges for
932, 936, 949, 950 and 1361; other code-page values use one-byte navigation.
The modeled ACP remains UTF-8 (GetACP = 65001). Windows' DBCS lead-byte metadata
does not describe UTF-8 or GB18030, so this function steps one byte for those
pages rather than decoding Unicode characters. It does not validate trail-byte
encodings. Reserved nonzero flags and a cursor beyond an embedded terminator
fail explicitly; guest memory reads remain checked.
See [CharPrevExA](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-charprevexa),
[lead-byte semantics](https://learn.microsoft.com/en-us/windows/win32/api/winnls/nf-winnls-isdbcsleadbyteex)
and [CPINFO's multibyte limits](https://learn.microsoft.com/en-us/windows/win32/api/winnls/ns-winnls-cpinfo).
Range endpoints were checked against original
[code-page metadata](https://github.com/reactos/reactos/tree/master/media/nls/src).

The core SDK-declared PE guest checks pointer/character forms, high 64-bit
addresses, Latin/Greek/Cyrillic/Armenian/Georgian mappings, surrogates, all 255
nonzero byte values for each DBCS page and DLL namespace isolation in both engines.
An offline optional oracle compares 131,072 scalar/string results per engine
directly against the original UnicodeData.txt, including a 65,535-unit string:

```sh
python3 scripts/windows-case.py artifacts/unicode-17.0.0/UnicodeData.txt --check
python3 tests/windows-text.py --unicode-data artifacts/unicode-17.0.0/UnicodeData.txt
```

The optional source data is available at the pinned
[Unicode 17.0.0 URL](https://www.unicode.org/Public/17.0.0/ucd/UnicodeData.txt);
it is only needed for regeneration or the independent oracle. Core checks and
runtime execution use the committed table and stay offline.

## Automation strings and variants

BSTRs carry a four-byte byte count immediately before the UTF-16 data and a
trailing zero code unit. Allocation preserves embedded NULs, surrogate pairs
and unpaired surrogates as raw code units. SysAllocString stops at the first
NUL; SysAllocStringLen copies the supplied count without requiring a terminator.
Empty BSTRs and null BSTRs retain their distinct pointer/ownership behavior.
SysFreeString releases the checked allocation; HeapFree/VirtualFree cannot
release it. The implementation currently uses one guest mapping per BSTR and
therefore shares the runtime's mapping-count and memory limits.

The Windows x64 VARIANT layout is 24 bytes. VariantInit sets VT_EMPTY without
interpreting previous storage. VariantClear frees owning BSTRs and sets
VT_EMPTY; scalar/DECIMAL and supported by-reference variants need no release.
VariantCopy preserves scalar/DECIMAL bytes, deep-copies owning strings and
copies borrowed pointers without dereferencing or releasing their referents.
Self-copy leaves the allocation unchanged. A failed string allocation returns
E_OUTOFMEMORY after the destination has been cleared. Invalid types return
DISP_E_BADVARTYPE. Owning COM pointers, SAFEARRAYs and records return E_NOTIMPL
without mutation; their reference-count/array/record operations are not implemented.
Invalid guest buffers fail through checked memory, before ordinary destination
ownership is changed.

The source fixture uses Zig's bundled Windows declarations, with compile-time
layout assertions and no linked CRT. Both named and NONAME ordinal import
libraries execute in interpreter/JIT modes without a Windows DLL file. The
checks include raw string bytes/length prefixes, independent clone ownership,
25 scalar/by-reference types, both forwarder forms and DLL namespace isolation.
See Microsoft's [BSTR layout](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/automat/bstr),
[VariantClear](https://learn.microsoft.com/en-us/windows/win32/api/oleauto/nf-oleauto-variantclear)
and [VariantCopy contracts](https://learn.microsoft.com/en-us/windows/win32/api/oleauto/nf-oleauto-variantcopy).
Export numbers were checked against the
[OLEAUT32 export metadata](https://github.com/reactos/reactos/blob/master/dll/win32/oleaut32/oleaut32.spec);
no external implementation is linked or used to execute guests. Native Windows
differential testing remains unverified.

## Guest DLL lifetime

Guest DLL imports require both `--sysroot` and `--allow-files`; built-in APIs do
not. Only bare filenames are
accepted; lookup is ASCII case-insensitive within that directory. There is no
implicit search of the executable directory, host system directories or PATH.
The sysroot does not prevent host symlink escape. Each module is registered before
recursing into its dependencies, avoiding duplicate loads for cycles. The graph
is capped at 64 active modules including the executable; unloaded slots are
reused. Import tables and strings, export counts/RVAs and forwarding depth are
bounded and validated.

Guest `DllMain` code executes through the same CPU engine before the executable
entry, in dependency traversal order, with DLL_PROCESS_ATTACH, the actual rebased
module handle and a non-null startup reserved argument. Instruction/time limits
include initializers. A false return stops with the failed module's name.
Circular dependency groups have traversal order rather than an independently
verified Windows loader ordering contract. Process-termination detach callbacks
are not run; explicit FreeLibrary unloads do run DLL_PROCESS_DETACH.

GetModuleHandle accepts null for the executable, or an existing module's filename
including its extension (case-insensitive, paths reduced to a basename).
GetProcAddress accepts a case-sensitive name or public ordinal and can return
function or data addresses. Missing exports return null with error 127; invalid
module handles return null with error 6. Forwarders may load dependencies during
startup binding or GetProcAddress.
New dependencies finish their guest attach callbacks before the API returns.
Win32 dynamic TLS APIs operate on 64 TEB slots for the initial guest thread;
TlsGetValue clears last error on success. Guest thread creation,
thread-attach/detach notifications, TLS expansion slots and FLS remain
unsupported. TLS support does not imply multithread support.
Delay imports, LoadLibraryEx flags and executable/resource-only loading remain
unsupported. No host dynamic linker or native execution of guest DLLs is used.

LoadLibraryA/W accepts bare filenames within the explicit sysroot, with ASCII
case-insensitive lookup. An omitted extension becomes `.dll`; a trailing period
suppresses extension addition. W names validate UTF-16, including surrogate
pairs; A names follow the existing UTF-8 policy. Null arguments, unsupported
paths, missing files and denied access return null and guest last-error values.
Binary inputs must be regular files; directories and FIFOs reject before reading.

Repeated loads acquire references without repeating DLL_PROCESS_ATTACH. Runtime
attach receives a null reserved argument. Bound imports and resolved forwarders
retain their dependencies. FreeLibrary spends a reference acquired by
LoadLibrary, and unloads DLLs no longer reachable from the executable or an
explicit reference, including cyclic groups. A GetModuleHandle lookup does not
acquire a releasable reference; startup dependencies remain owned by the main
image. This ownership model is not a claim of all native Windows reference-count
edge cases.

Detach runs dependents before dependencies, with reverse attachment order inside
a cycle. All affected images remain mapped until their callbacks complete, then
unmap invalidates cached JIT blocks. A false runtime attach detaches attempted
initializers, removes new images and restores previous dependency edges; the API
returns null with error 1114. Existing modules remain loaded. This rollback covers
loader state, not arbitrary guest initializer side effects. Trace output reports
the API's final result after callbacks. Callback stack alignment, shadow space,
caller registers and instruction accounting are preserved.

LoadLibrary/FreeLibrary calls from DllMain return null/false with error 1114;
GetProcAddress there resolves already loaded modules only. Thread notifications,
reentrant loader operations and native Windows differential testing are not
implemented or claimed.

PE arguments are quoted using Microsoft CRT rules, including empty arguments,
quotes and trailing backslashes. The program name is quoted separately; a quote
inside that name is rejected. Command lines are capped at 32,767 UTF-16 units
including NUL and stored in read-only guest memory. A APIs use UTF-8 and GetACP
returns 65001; W APIs use UTF-16 with surrogate-pair validation. This is an
explicit guest code-page policy, not inheritance of the host locale. Guest
environment entries remain unsupported and `--env` is rejected for PE execution.

The process heap returns 16-byte-aligned guest blocks. HeapAlloc accepts flags 0
or HEAP_ZERO_MEMORY; HeapReAlloc also accepts HEAP_REALLOC_IN_PLACE_ONLY.
Growth preserves existing bytes, zeroes added bytes when requested, and leaves
the original block intact on allocation failure. HeapSize reports the logical
requested size. HeapFree/HeapSize accept flags 0 only; invalid/freed pointers
fail. The implementation uses one page-rounded mapping per block, subject to
the guest memory and mapping-count limits. VirtualFree cannot free heap blocks.
VirtualAlloc accepts a null address and commit/reserve flags; VirtualFree
supports complete MEM_RELEASE allocations.

File access requires `--allow-files`. Paths use the host working directory or
absolute host-style paths, optionally prefixed by `--sysroot`; backslashes become
slashes. DOS drives, UNC/device namespaces and alternate streams are rejected.
This does not emulate a complete Windows filesystem or confine host symlinks.
CreateFile accepts GENERIC_READ/WRITE or metadata-only access, share bits 0..7,
all five creation dispositions, flags/attributes 0 or FILE_ATTRIBUTE_NORMAL,
and null security/template parameters. Only regular files are opened. Sharing
is checked by host device/inode across this runtime's handles, including aliases;
it does not lock out other host processes. A failed sharing check never truncates
the file. CREATE_ALWAYS/OPEN_ALWAYS set ERROR_ALREADY_EXISTS for an existing file.

ReadFile/WriteFile are synchronous, capped at 1 MiB per call, and require a
non-null byte-count pointer. Buffers and outputs are checked before host I/O.
The byte count is zeroed before API error checking. EOF succeeds with zero bytes
for these synchronous regular files. Overlapped I/O, devices and async flags are
unsupported. Seek supports FILE_BEGIN/CURRENT/END and signed 64-bit distances;
negative resulting positions fail. CloseHandle rejects closed/unknown handles
and closes guest standard handles without closing the host's borrowed streams.

MoveFileW preserves an existing destination using an atomic host no-replace
rename: macOS RENAME_EXCL or Linux RENAME_NOREPLACE. Files, directories and
symlinks move on the same volume. MoveFileExW and MoveFileWithProgressW also
support replacing an existing regular file, after destination read-only/sharing
checks. Non-null progress callbacks and unsupported flags fail explicitly.
COPY_ALLOWED/WRITE_THROUGH are accepted for same-volume rename; cross-volume
copy/delete remains unavailable and returns ERROR_NOT_SAME_DEVICE. Reboot-delayed
moves, link tracking and native Windows differential behavior are unverified.
See [MoveFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefilew)
and [move options](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefilewithprogressw).

CreateDirectoryW creates only the final component, with explicit existing/missing
parent errors and no security-attribute translation. RemoveDirectoryW requires
an empty real directory. CreateHardLinkW creates a real same-volume regular-file
link, with source sharing checks, a 1,023-link ceiling and no overwrite.
Symlink hard-link creation, junctions and directory handles remain unsupported.
See [directories](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createdirectoryw)
and [hard links](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-createhardlinkw).

DeleteFileW removes closed files immediately; a symlink is removed without
touching its target. Directories and read-only regular files fail. Open handles
must all permit FILE_SHARE_DELETE; otherwise deletion fails before mutation.
With shared open handles, deletion is pending until the final close, and new
opens of that device/inode fail. A retained parent descriptor follows directory
renames; a host replacement at that name is checked and preserved. Process
termination closes guest handles and finishes their pending deletions.
Hard-link alias behavior is a local per-inode model, not proven NTFS parity.
Checks do not lock out other host processes or eliminate every host pathname
race. See [deletion/lifetime rules](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-deletefilew).

GetFileAttributesW maps writable regular files to NORMAL, files with no host
write bits to READONLY, directories to DIRECTORY and symlinks to REPARSE_POINT.
SetFileAttributesW supports NORMAL/READONLY on regular files only: it clears
host write bits for READONLY or restores owner write for NORMAL, preserving
other mode bits. It does not retain Windows ACLs or emulate other DOS attributes.
Hidden/system/archive flags, directory attribute writes and broader reparse
metadata fail explicitly.
See [attribute flags](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfileattributesw).

GetFileInformationByHandle validates the complete 52-byte SDK output before
writing attributes, FILETIME timestamps, size, link count and device/inode
identity. Creation time comes from host birthtime when available, or zero;
ctime is not substituted for creation. FILETIME uses the 1601 UTC epoch and
100 ns units, with sub-unit truncation. The 32-bit virtual volume serial folds
the host device ID; it is not an NTFS serial or a collision-free global identity.
GetFileSize and SetFilePointer implement optional high DWORD outputs and clear
LastError for a successful 0xffffffff low result. Signed seeks and output faults
are checked before moving the descriptor; legacy seeks without a high output
reject positions beyond a DWORD without changing it. SetEndOfFile requires
write access and truncates/extends at the current position.
See [file metadata](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-getfileinformationbyhandle)
and [legacy seek rules](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-setfilepointer).

The SDK-only file-operation guest runs in isolated temporary directories, with
relative or sysroot-prefixed absolute paths. Both engines check collision
preservation, shared pending deletion across a parent rename, symlink-target
preservation, read-only failures, real hard links and sparse offsets above 4 GiB.
Python compares final file bytes, size, inode, volume identity and mtime/birthtime
against host stat results. Memory regressions check partial output faults before
seeking/writing and preservation of a host replacement during pending deletion.

```sh
python3 scripts/fixtures.py
./zig-out/bin/universe artifacts/windows-process.exe '' 'hello world' 'é🚀'
./zig-out/bin/universe --allow-files artifacts/windows-files.exe /tmp/universe-new-file.txt
./zig-out/bin/universe --allow-files --sysroot artifacts/windows-sysroot artifacts/windows-dll.exe
# windows DLL: imports, exports, relocations and initialization ok
./zig-out/bin/universe --allow-files --sysroot artifacts/windows-sysroot artifacts/windows-dynamic.exe
# windows dynamic DLL: references, forwarders, detach and reload ok
./zig-out/bin/universe --allow-files --sysroot artifacts/windows-sysroot artifacts/windows-tls.exe
# windows TLS: executable, DLL and callbacks ok
./zig-out/bin/universe --allow-files --sysroot artifacts/windows-sysroot artifacts/windows-tls-dynamic.exe
# windows dynamic TLS: callbacks, unload and fresh template ok
./zig-out/bin/universe artifacts/windows-dynamic-tls.exe
# windows dynamic TLS: allocation, values, reuse and errors ok
```

The file fixture expects a path that does not already exist. It verifies denied
access, creation, UTF-8/UTF-16 paths, sharing, read/write/EOF, size/seek/flush and
close behavior; `tests/integration.py` uses isolated temporary directories and
checks host file bytes in interpreter/JIT paths. The DLL fixture forces a preferred
base collision for both libraries, verifies dependency initialization order,
imports/exports by name and ordinal, data mutation, forwarding and module handles.
The runtime fixture additionally verifies shared references, late forwarders,
cyclic imports, dependency-aware detach, 80 reloads, UTF-16 filenames, extension
rules and invalid handles. Mutated DLLs verify failed-attach rollback while
retaining existing modules, and late missing/malformed/FIFO dependencies. TLS
fixtures cover executable and DLL templates, process callbacks, dynamic unload,
reload initialization and malformed TLS metadata. Dynamic TLS fixtures check
zero-initialized values, LastError behavior, all 64 slots, exhaustion, reuse and
invalid indices. Guest threads, SEH, broad CRT compatibility, environment APIs
and GUI remain unsupported.
This is an API subset, not arbitrary Windows compatibility.
