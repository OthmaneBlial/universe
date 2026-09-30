# Dynamic musl guest fixture

Current main executes an x86-64 dynamic ET_EXEC and PIE linked against a separate
guest DSO. Both pass on macOS ARM64, interpreted and with the partial ARM64 JIT.
These features are newer than the v0.1.0 release bundle.

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/musl.py
python3 tests/musl.py
./zig-out/bin/universe --allow-files --sysroot artifacts/musl-sysroot \
  --env UNIVERSE_TEST=dynamic artifacts/musl-dynamic-pie check
# dynamic musl: imports, constructors and TLS ok
```

The optional build requires Python 3.12+, Zig 0.16.0, make, awk and network
access. It downloads official musl 1.2.5 source and verifies SHA-256:

`a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4`

It builds unmodified upstream `lib/libc.so` using `zig cc -target
x86_64-linux-musl`, scalar C at `-O1` and musl's existing assembly. The source,
logs, interpreter, DSO and guest executables stay in ignored `artifacts/`.
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
test repeats both executables with interpreter/JIT output and status checks.

`--sysroot` prefixes absolute Linux file paths, including library search paths.
Relative paths still use the host CWD or guest directory descriptor. Host
symlinks can escape the prefix; this option is not filesystem confinement.
File access remains disabled unless `--allow-files` is supplied.

This verifies one controlled musl DSO fixture, not arbitrary dynamic programs,
glibc, dlopen, additional guest architectures or threads. Signals, process
creation, sockets, complete SIMD/ISA coverage and overlapping ELF load pages
remain unsupported. Unsupported behavior stops with a named runtime fault.
