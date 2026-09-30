# PE32+ Windows milestone

Current main executes six source-built Windows x86-64 fixtures on ARM64 macOS:
Hello World, stdin/stdout echo, virtual-memory allocation/free, process heap and
Unicode command lines, regular-file operations and an executable importing two
guest DLLs. Process/file/DLL fixtures also pass with the partial ARM64 JIT.
They are newer than v0.1.0.
The unknown-import fixture fails explicitly rather than substituting a stub.

The PE parser validates MZ, PE signature, x86-64 machine type, PE32+ optional
header, data directory bounds and sections. The loader maps headers/sections,
zero fills virtual tails and respects permissions. DIR64 base relocation is
implemented and tested with a relocated synthetic image, including an RX target,
and source-built DLLs with absolute data pointers. Executables use their preferred
base; DLLs are rebased when that range is occupied. A DLL with no entry point can
be loaded, but invoking a DLL directly as the main executable is rejected.

The import binder handles named APIs from kernel32.dll/kernelbase.dll, maps
guest API gateways, and writes guest addresses into the IAT. Static guest DLL
dependencies are loaded recursively from the explicitly supplied sysroot.
Their named/ordinal function and data exports, including forwarded exports,
are resolved in checked guest memory. Built-in APIs remain named-only; unknown
APIs, TLS callbacks and delay imports fail clearly. The API gateway follows
Windows x64 RCX/RDX/R8/R9 argument
registers, shadow space, stack arguments and return addresses.

| Area | Implemented APIs |
|---|---|
| Process / console | ExitProcess, GetStdHandle, GetLastError, SetLastError |
| Modules | GetModuleHandleA/W, GetProcAddress |
| Command line | GetCommandLineA/W, GetACP |
| Memory | VirtualAlloc, VirtualFree, GetProcessHeap, HeapAlloc, HeapReAlloc, HeapFree, HeapSize |
| Regular files | CreateFileA/W, ReadFile, WriteFile, CloseHandle, GetFileSizeEx, SetFilePointerEx, FlushFileBuffers |

## Guest DLL startup

DLL imports require both `--sysroot` and `--allow-files`. Only bare filenames are
accepted; lookup is ASCII case-insensitive within that directory. There is no
implicit search of the executable directory, host system directories or PATH.
The sysroot does not prevent host symlink escape. Each module is registered before
recursing into its dependencies, avoiding duplicate loads for cycles. The graph
is capped at 64 modules including the executable; import tables and strings,
export counts/RVAs and forwarding depth are bounded and validated.

Guest `DllMain` code executes through the same CPU engine before the executable
entry, in dependency traversal order, with DLL_PROCESS_ATTACH, the actual rebased
module handle and a non-null startup reserved argument. Instruction/time limits
include initializers. A false return stops with the failed module's name.
Circular dependency groups have traversal order rather than an independently
verified Windows loader ordering contract. Process-detach callbacks are not run.

GetModuleHandle accepts null for the executable, or an existing module's filename
including its extension (case-insensitive, paths reduced to a basename).
GetProcAddress accepts a case-sensitive name or public ordinal and can return
function or data addresses. Missing exports return null with error 127; invalid
module handles return null with error 6. Forwarders may load dependencies while
binding startup imports, but GetProcAddress only resolves already loaded modules.
LoadLibrary/FreeLibrary, TLS, DLL unload and late dependency loading remain
unsupported. No host dynamic linker or native execution of guest DLLs is used.

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
```

The file fixture expects a path that does not already exist. It verifies denied
access, creation, UTF-8/UTF-16 paths, sharing, read/write/EOF, size/seek/flush and
close behavior; `tests/integration.py` uses isolated temporary directories and
checks host file bytes in interpreter/JIT paths. The DLL fixture forces a preferred
base collision for both libraries, verifies dependency initialization order,
imports/exports by name and ordinal, data mutation, forwarding and module handles.
SEH, CRT startup compatibility, dynamic DLL loading, TLS, environment APIs and GUI
remain unsupported. This is an API subset, not arbitrary Windows compatibility.
