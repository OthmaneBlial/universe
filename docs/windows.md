# PE32+ Windows milestone

Current main executes source-built Windows x86-64 fixtures on ARM64 macOS:
Hello World, stdin/stdout echo, virtual-memory allocation/free, process heap and
Unicode command lines, regular-file operations and an executable importing two
guest DLLs, runtime DLL loading/unloading, static TLS in executables and DLLs,
the 64 documented-minimum dynamic TLS slots for the initial guest thread, and
OLEAUT32 BSTR allocation/ownership and scalar/string/by-reference VARIANTs.
TLS fixtures verify callback ordering, dynamic unload, fresh template
initialization after reload, and dynamic slot reuse. Process/file/DLL fixtures
also pass with the partial ARM64 JIT.
They are newer than v0.1.0.
The unknown-import fixture fails explicitly rather than substituting a stub.

The official Windows x64 7-Zip 26.03 `7za.exe` was also inspected and attempted
unchanged. Its six OLEAUT32 ordinal imports now bind to UNIVERSE's own APIs;
`--syscalls` shows the next boundary at USER32 (`WindowsDLLNotFound`). USER32,
ADVAPI32, msvcrt and additional KERNEL32 imports still exceed this subset. The Linux `7zzs`
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
named/ordinal APIs from oleaut32.dll, maps
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
| Process / console | ExitProcess, GetStdHandle, GetLastError, SetLastError |
| Modules | GetModuleHandleA/W, GetProcAddress, LoadLibraryA/W, FreeLibrary |
| Dynamic TLS | TlsAlloc, TlsFree, TlsGetValue, TlsSetValue (64 slots, one guest thread) |
| Command line | GetCommandLineA/W, GetACP |
| Memory | VirtualAlloc, VirtualFree, GetProcessHeap, HeapAlloc, HeapReAlloc, HeapFree, HeapSize |
| Regular files | CreateFileA/W, ReadFile, WriteFile, CloseHandle, GetFileSizeEx, SetFilePointerEx, FlushFileBuffers |
| Automation (OLEAUT32) | SysAllocString (#2), SysAllocStringLen (#4), SysFreeString (#6), SysStringLen (#7), VariantInit (#8), VariantClear (#9), VariantCopy (#10) |

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
