# Unchanged CPython on UNIVERSE

UNIVERSE runs the official [python-build-standalone](https://github.com/astral-sh/python-build-standalone)
CPython 3.13.16 build for x86-64 Linux/musl on an ARM64 Mac. The interpreter,
`libpython3.13.so`, its extension modules and Alpine's musl dynamic loader are
the unchanged upstream bytes; UNIVERSE executes their x86-64 code with its own
CPU engine and Linux system-call layer.

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/python.py            # pinned Alpine 3.22.6 minirootfs + CPython 3.13.16
cd artifacts/python-x86_64/sysroot/tmp
../../../../zig-out/bin/universe --allow-files --sysroot .. --timeout-ms 0 \
  --max-instructions 20000000000 ../opt/python/bin/python3 \
  -c 'import sys, sqlite3; print(sys.platform, sqlite3.connect(":memory:").execute("select 6*7").fetchone())'
# linux (42,)
```

`scripts/python.py` verifies the SHA-256 of both upstream archives. The guest
sees `/opt/python/bin/python3` as its executable: when a binary lies inside
`--sysroot`, UNIVERSE passes its sysroot-relative path as `argv[0]`, as a chroot
would. The working directory must also be inside the sysroot; otherwise
`getcwd` reports `ENOENT`.

## Verified

`python3 tests/python.py` passes **6/6 checks** (three per engine, interpreter
and JIT): one exact-output workload covering `json`, `re`, `hashlib`, `zlib`,
`sqlite3`, four guest threads, `decimal`, dataclasses, big integers and Unicode
file round trips, plus exit-status and traceback cases.

CPython drove three Linux ABI additions:

- `mremap` shrinks, grows in place or moves an owned private mapping
  (`MREMAP_MAYMOVE`), as musl's `realloc` does for large blocks.
  `MREMAP_FIXED` and shared-mapping duplication return `EINVAL`.
- `membarrier` reports and accepts the global and private-expedited commands.
  Guest threads run serially on one host thread, so these barriers already hold.
- `argv[0]` translation for binaries inside a sysroot, so `sys.executable` and
  the standard-library search find `/opt/python/lib/python3.13`.

## Limits

- Speed: the simple workloads above take 30–60 seconds per run, because most
  x86-64 instructions are interpreted. Measured improvements are tracked in
  [benchmarks](../benchmarks/results.md).
- `asyncio` and `subprocess` need `epoll`, which is not yet implemented.
- No networking: sockets return `EAFNOSUPPORT`.
- `--allow-files` grants host-user file access. UNIVERSE is not a sandbox.
