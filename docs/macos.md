# Library-free Mach-O guests

Current `main` executes thin little-endian x86-64 and AArch64 Mach-O64
command-line fixtures through UNIVERSE's loaders, CPU decoders, UIR and
interpreter/partial ARM64-host JIT. This capability is newer than v0.1.0.
The verified runtime host is Apple M2 / macOS 26.6 ARM64.

## Reproduce

Requires Zig 0.16.0, Python 3, macOS and Apple's installed command-line tools
(`clang`/`ld`). The builder links no guest libc, SDK framework or dynamic library.

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/macos.py
./zig-out/bin/universe artifacts/macos/x86_64/hello
# Hello from macOS guest machine code!
./zig-out/bin/universe --jit artifacts/macos/aarch64/system
# macOS system: ok
./zig-out/bin/universe --env KEY=value artifacts/macos/aarch64/arguments foo
# foo
# KEY=value
python3 scripts/fixtures.py
python3 tests/integration.py
```

`./scripts/check.sh` builds and tests these guests on macOS automatically.
The existing Linux/Windows fixture path remains available on Linux.

## Loading and startup

MH_EXECUTE segments map at their requested addresses with checked file/VM
ranges, BSS zero fill and initial/maximum R/W/X permissions. `__PAGEZERO` is
unmapped. Raw LC_UNIXTHREAD entries accept the x86_THREAD_STATE64 or ARM_THREAD_STATE64
layout with an initially zero stack pointer. UNIVERSE supplies a 1 MiB stack
containing argc, argv, explicit environment and `executable_path=` Apple entries.

Library-free LC_MAIN images receive argc/argv/env/apple argument registers and
a runtime-owned return hook. Returning sets the low-byte guest exit status and
consumes an instruction step. This path is covered by synthetic image tests;
the five compiled fixtures use LC_UNIXTHREAD and their own syscall-only startup.
It does not supply dyld's startup services.

Unknown load commands and unsupported runtime requirements fail explicitly.
Guest libraries, dyld commands, nonempty bind/rebase/chained-fixup streams,
section relocations, TLS and initializer/terminator sections are rejected.
Encrypted images, fat/universal files and 32-bit Mach-O are unsupported.
Code signatures are metadata; UNIVERSE does not validate them as a trust policy.

## Darwin BSD subset

The x86 syscall class is BSD (`0x2000000 | number`); AArch64 uses X16 and
`SVC #0x80`. Errors return positive Darwin errno with carry set. Other syscall
numbers/classes and Mach traps stop with explicit runtime faults.

| Calls | Implemented behavior |
|---|---|
| exit / getpid | Low-byte exit status; guest pid 1 |
| read / write / writev | Checked guest buffers, host standard streams, 1 MiB request cap |
| open / close / lseek | Explicit file grant, translated access/create/truncate/append/no-follow/directory/close-on-exec flags |
| mmap | Private anonymous or regular-file snapshots; optional fixed replacement |
| munmap / mprotect | Page-rounded lengths, checked alignment, retained segment maximum protections |

Guest page size is 4 KiB on x86-64 and 16 KiB on AArch64. mmap accepts aligned
file offsets, MAP_PRIVATE, MAP_ANON, MAP_FIXED and the UNIX03 marker. Shared
mappings, VM tags and legacy unaligned file mappings are unsupported. Legacy
zero-length mmap returns zero after argument/file validation; UNIX03 rejects
zero length. Zero-length mprotect succeeds; munmap rejects it.

File snapshots retain partial-page zero fill and whole-page EOF faults.
Guest writes do not change the host file. There is no signal delivery or
coherence with later file changes. Files require `--allow-files`; `--sysroot`
prefixes absolute paths lexically. Relative paths and host symlinks can escape
the prefix, so this is not filesystem confinement. Host environment is empty
unless `--env` entries are supplied.

## Evidence and limits

Five checked-in C fixtures per CPU cover console input/output/error, nonzero
exit, argv/env/Apple path, BSS/data pointers, permissions, private mappings and
UTF-8 file paths. Both interpreter and partial JIT paths verify exact outputs,
exit status and file contents. Invalid guest buffers return EFAULT; direct
invalid loads/stores stop with a checked fault. Malformed segments, sections,
thread states, entry points and unsupported syscall traps are regressions.

On a matching macOS CPU, the builder also compiles hello/system/echo/files from
the same source with ordinary native startup. Integration compares their
stdout/stderr/status and file contents with UNIVERSE. These are native syscall
**source comparisons**, not proof that the host accepts the standalone
LC_UNIXTHREAD images or that UNIVERSE runs ordinary dynamic macOS programs.
Native comparison on the other CPU is not performed through Rosetta.

Dyld, LibSystem imports, relocations, TLS, Mach IPC, signals, guest processes,
threads and GUI frameworks remain unsupported. Instruction coverage is the
same partial x86/AArch64 coverage listed in [compatibility.md](compatibility.md).
Primary format/ABI sources are linked in [references.md](references.md).
