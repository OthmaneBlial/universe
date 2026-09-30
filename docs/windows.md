# PE32+ Windows milestone

Current main executes five source-built Windows x86-64 fixtures on ARM64 macOS:
Hello World, stdin/stdout echo, virtual-memory allocation/free, process heap and
Unicode command lines, and regular-file operations. The new process/file
fixtures also pass with the partial ARM64 JIT. They are newer than v0.1.0.
The unknown-import fixture fails explicitly rather than substituting a stub.

The PE parser validates MZ, PE signature, x86-64 machine type, PE32+ optional
header, data directory bounds and sections. The loader maps headers/sections,
zero fills virtual tails and respects permissions. DIR64 base relocation is
implemented and tested with a relocated synthetic image, including an RX target.
Execution uses the preferred base; no shared DLL loader is available.

The import binder handles named imports from kernel32.dll/kernelbase.dll, maps
guest API gateways, and writes guest addresses into the IAT. Ordinal imports,
TLS callbacks, delay imports, other DLLs and unknown APIs fail clearly. Exports
are not resolved. The API gateway follows Windows x64 RCX/RDX/R8/R9 argument
registers, shadow space, stack arguments and return addresses.

| Area | Implemented APIs |
|---|---|
| Process / console | ExitProcess, GetStdHandle, GetLastError, SetLastError, GetModuleHandleA/W (null/current module only) |
| Command line | GetCommandLineA/W, GetACP |
| Memory | VirtualAlloc, VirtualFree, GetProcessHeap, HeapAlloc, HeapReAlloc, HeapFree, HeapSize |
| Regular files | CreateFileA/W, ReadFile, WriteFile, CloseHandle, GetFileSizeEx, SetFilePointerEx, FlushFileBuffers |

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
```

The file fixture expects a path that does not already exist. It verifies denied
access, creation, UTF-8/UTF-16 paths, sharing, read/write/EOF, size/seek/flush and
close behavior; `tests/integration.py` uses isolated temporary directories and
checks host file bytes in interpreter/JIT paths. SEH, CRT startup compatibility,
DLL loading/TLS and GUI remain unsupported. This is an API subset, not arbitrary
Windows application compatibility.
