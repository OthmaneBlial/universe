# BusyBox applet milestone

Optional guest, separate from UNIVERSE's Apache-2.0 core. BusyBox 1.37.0 is
GPL-2.0; UNIVERSE does not include its source or binary in its release artifacts.

```sh
python3 scripts/busybox.py
python3 tests/busybox.py
./zig-out/bin/universe artifacts/busybox-1.37.0/busybox echo hello
./zig-out/bin/universe artifacts/busybox-1.37.0/busybox printf '%s:%04d\n' guest 7
./zig-out/bin/universe artifacts/busybox-1.37.0/busybox sort <<EOF
zebra
apple
EOF
./zig-out/bin/universe --allow-files artifacts/busybox-1.37.0/busybox cat README.md
./zig-out/bin/universe --allow-files artifacts/busybox-1.37.0/busybox ls examples
```

Requires Python 3.12+, make, native `cc` for upstream build tools, Zig and network
access to the [official source archive](https://busybox.net/downloads/). The script
checks the archive against upstream SHA-256
`3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4`.
It configures static x86-64 musl with echo, cat, ls, basename, dirname, false,
printf, test, true, uname, wc, head, tail, cut and sort, retaining the standard
BusyBox dispatcher. Upstream diagnostic-only linker flags (`--warn-common`,
`--verbose`, `-Map`) are removed because Zig's linker rejects them; no guest
application logic is modified. Compiler auto-vectorization is disabled, but
musl and applicable SSE integer operations execute in UNIVERSE.

The tests verify these applets' selected string, numeric-formatting, status,
stdin and file cases in the interpreter, plus the ARM64 JIT where available.
Files need `--allow-files`. No full BusyBox build, shell, process spawning or
broad applet compatibility is advertised.
