# BusyBox applet milestone

## Official downloaded binary

Current main also runs selected applets from the unchanged official
[BusyBox 1.35.0 x86-64 musl binary](https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/).
Use the existing download and regression scripts:

```sh
python3 scripts/public-apps.py
python3 tests/public-apps.py
./zig-out/bin/universe artifacts/public-apps/busybox printf '%s:%04d\n' hello 42
# hello:0042
```

Its 30 workflows per engine cover formatting, sequences, SHA-256, Base64,
text filters, exits, Unicode/binary file reads and exact copies/renames/removals.
File access still needs `--allow-files`. Accelerated `sendfile` is unavailable;
the application's own read/write fallback copies the bytes. This older binary
is checksum-pinned from its official download, without a separately published
upstream checksum. No recompilation or source patch is involved. Shells and
all-applet compatibility remain unsupported or unverified. See the exact
[download and validation scope](public-apps.md#unchanged-busybox-utilities).

## Optional source-built subset

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
./zig-out/bin/universe artifacts/busybox-1.37.0/busybox grep needle <<EOF
needle one
other
EOF
./zig-out/bin/universe --allow-files artifacts/busybox-1.37.0/busybox cat README.md
./zig-out/bin/universe --allow-files artifacts/busybox-1.37.0/busybox ls examples
```

Requires Python 3.12+, make, native `cc` for upstream build tools, Zig and network
access to the [official source archive](https://busybox.net/downloads/). The script
checks the archive against upstream SHA-256
`3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4`.
It configures static x86-64 musl with echo, cat, ls, basename, dirname, false,
printf, test, true, uname, wc, head, tail, cut, sort, grep, sed, tr, uniq,
mkdir, rm, rmdir, cp, mv and touch, retaining the standard BusyBox dispatcher. Upstream
diagnostic-only linker flags (`--warn-common`,
`--verbose`, `-Map`) are removed because Zig's linker rejects them; no guest
application logic is modified. Compiler auto-vectorization is disabled, but
musl and applicable SSE integer operations execute in UNIVERSE.

The tests verify these applets' selected string, numeric-formatting, text
filtering, status, stdin, file, timestamp and temporary-directory mutation cases in the
interpreter, plus the ARM64 JIT where available. `cp` content and `mv` rename
results are checked on host files. Touch verifies that an old modification time
is updated. File mutation needs
`--allow-files`. No full BusyBox build, shell, process spawning or broad applet
compatibility is advertised.
