# PE32+ Windows milestone

The runtime executes three source-built Windows x86-64 console fixtures on ARM64
macOS: Hello World, stdin/stdout echo, and virtual-memory allocation/free.
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

Implemented APIs: ExitProcess, GetStdHandle, WriteFile, ReadFile, VirtualAlloc,
VirtualFree, GetModuleHandleA (current module only), GetLastError. File APIs,
heaps, command-line APIs, SEH, CRT startup compatibility and GUI are unsupported.
Guest arguments/environment are rejected for PE execution. Write/ReadFile are
synchronous; overlapped I/O is unsupported. VirtualAlloc accepts a null address
and commit/reserve flags; VirtualFree supports complete MEM_RELEASE allocations.
This is an API subset, not arbitrary Windows application compatibility.
