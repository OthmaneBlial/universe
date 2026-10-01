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
TLS fixtures verify callback ordering, dynamic unload, fresh template
initialization after reload, and dynamic slot reuse. Process/file/DLL fixtures
also pass with the partial ARM64 JIT.
They are newer than v0.1.0.
The unknown-import fixture fails explicitly rather than substituting a stub.

The official Windows x64 7-Zip 26.03 `7za.exe` was also inspected and attempted
unchanged. Its six OLEAUT32 ordinal imports now bind to UNIVERSE's own APIs;
Its two USER32 and nine ADVAPI32 imports now bind too. `--syscalls` shows the next
boundary at msvcrt (`WindowsDLLNotFound`). The CRT and additional
KERNEL32 imports still exceed this subset. The Linux `7zzs`
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
named/ordinal APIs from oleaut32.dll and named USER32/ADVAPI32 APIs, maps
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
| Regular files | CreateFileA/W, ReadFile, WriteFile, CloseHandle, GetFileSizeEx, SetFilePointerEx, FlushFileBuffers |
| Automation (OLEAUT32) | SysAllocString (#2), SysAllocStringLen (#4), SysFreeString (#6), SysStringLen (#7), VariantInit (#8), VariantClear (#9), VariantCopy (#10) |
| String utilities (USER32) | CharUpperW, CharPrevExA |
| Entropy (ADVAPI32) | SystemFunction036 / RtlGenRandom |
| Process tokens (ADVAPI32) | OpenProcessToken, LookupPrivilegeValueW, AdjustTokenPrivileges (no assigned Windows privileges) |
| Registry (ADVAPI32) | RegOpenKeyExW, RegQueryValueExW, RegCloseKey (five empty read-only roots) |
| File security boundary (ADVAPI32) | GetFileSecurityW, SetFileSecurityW (failure only; Windows ACLs unsupported) |

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
invalid indices. Guest threads, SEH, CRT startup compatibility, environment APIs
and GUI remain unsupported.
This is an API subset, not arbitrary Windows compatibility.
