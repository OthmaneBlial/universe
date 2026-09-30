# Dynamic musl guest fixture

Current main executes x86-64, AArch64 and soft-float RISC-V64 dynamic ET_EXEC
and PIE guests linked against separate guest DSOs. All six pass on macOS ARM64,
interpreted and with the partial ARM64 JIT.
These features are newer than the v0.1.0 release bundle.

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/musl.py --arch all
python3 tests/musl.py --arch all
./zig-out/bin/universe --allow-files --sysroot artifacts/musl-sysroot \
  --env UNIVERSE_TEST=dynamic artifacts/musl-dynamic-pie check
# dynamic musl: imports, constructors and TLS ok
./zig-out/bin/universe --allow-files --sysroot artifacts/musl-aarch64-sysroot \
  --env UNIVERSE_TEST=dynamic artifacts/musl-dynamic-aarch64-pie check
# dynamic musl: imports, constructors and TLS ok
./zig-out/bin/universe --allow-files --sysroot artifacts/musl-riscv64-sysroot \
  --env UNIVERSE_TEST=dynamic artifacts/musl-dynamic-riscv64-pie check
# dynamic musl: imports, constructors and TLS ok
```

The optional build requires Python 3.12+, Zig 0.16.0, make, awk and network
access. It downloads official musl 1.2.5 source and verifies SHA-256:

`a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4`

It builds unmodified upstream `lib/libc.so` using `zig cc -target
x86_64-linux-musl`, `aarch64-linux-musl` or `riscv64-linux-musl`, C at `-O1`
with automatic vectorization disabled, and musl's existing assembly. RISC-V uses
`-mcpu=baseline_rv64-d-f -mabi=lp64`: compressed integers and atomics, without
hardware floating-point instructions. Its interpreter is
`/lib/ld-musl-riscv64-sf.so.1`, matching musl's configured soft-float ABI.
Each architecture has its own build directory and sysroot. Omit `--arch` for
x86-64 only, or select `--arch aarch64` / `--arch riscv64`. The source, logs,
interpreter, DSO and guest executables stay in ignored `artifacts/`.
Upstream musl has its own MIT license and notices; the build copies COPYRIGHT
into the generated sysroot. No upstream guest source or binary is bundled in
UNIVERSE's release archives.

UNIVERSE maps the program and PT_INTERP, sets up argc/argv/env and auxv with
AT_PHDR, AT_BASE and AT_ENTRY, then starts at the interpreter's guest entry.
musl's guest machine code performs symbol lookup, ELF relocations, GOT/PLT
binding, constructors and TLS initialization. All CPU, memory and Linux syscall
execution still uses UNIVERSE's own implementation; no host dynamic linker or
native guest execution is used.

`examples/musl-library.c` exports a function accessing initialized global data
and `__thread` storage. Its constructor changes a value before main; successive
calls must observe TLS values 7 and 8. `examples/musl-dynamic.c` checks those
results, explicit argv/env and libc allocation, memset, free and output. The
test repeats ET_EXEC and PIE for each selected CPU with interpreter/JIT output
and status checks. AArch64 uses a guest TPIDR_EL0 register, checked single-thread
exclusive loads/stores, vector transfers and integer SIMD immediate/lane moves.
RISC-V uses guest register x4 (tp), compressed integers and checked word/doubleword
atomics. Host TLS and native guest instructions are never used.

`--sysroot` prefixes absolute Linux file paths, including library search paths.
Relative paths still use the host CWD or guest directory descriptor. Host
symlinks can escape the prefix; this option is not filesystem confinement.
File access remains disabled unless `--allow-files` is supplied.

This verifies one controlled musl DSO fixture on three CPUs, not arbitrary dynamic
programs, glibc, dlopen, dynamic RISC-V hard-float applications or threads. A
separate assembly fixture checks a limited RISC-V F/D instruction subset. Signals, process
creation, sockets, complete SIMD/ISA coverage and overlapping ELF load pages
remain unsupported. Unsupported behavior stops with a named runtime fault.
