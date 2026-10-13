# Node.js, Go and Rust programs on UNIVERSE

Modern language runtimes reserve far more address space than they use. V8
reserves multi-gigabyte `PROT_NONE` ranges for its pointer cage and garbage
collector tables; Go's runtime reserves a 512 MiB heap arena at startup. Both
now run unchanged on an ARM64 Mac.

```sh
python3 scripts/alpine.py --node
./zig-out/bin/universe --unlimited --allow-files \
  --sysroot artifacts/alpine-x86_64/sysroot /usr/bin/node \
  -e 'console.log(6 * 7, process.arch, process.platform)'
# 42 x64 linux
```

V8 compiles JavaScript to x86-64 machine code at run time; UNIVERSE decodes and
executes that generated code like any other guest instruction stream.

## Verified

- `python3 tests/node.py` passes **6/6 checks** (three per engine) with
  Alpine's unchanged Node.js 22.23: an inline expression with WebAssembly
  present; a script using `fs` with Unicode, `crypto` SHA-256, `zlib`, JSON,
  BigInt, `os`, argv, a timer, `setImmediate` with async/await and an exit
  code; and an uncaught exception.
- `python3 tests/public-apps.py` includes official static Linux releases of
  fzf 0.74.5 and Hugo 0.167 (Go) and bat 0.26.1, eza 0.23.5 and glow 3.0
  (Rust and Go). fzf's `--filter` rankings, bat's syntax highlighting
  (256-color and 24-bit) and glow's Markdown rendering match the official
  macOS arm64 builds of the same releases byte for byte; Hugo builds a real
  site from Markdown and a Go template into the expected HTML.

## What changed in the runtime

**Lazily backed guest memory.** Owned mappings are anonymous host pages,
committed by the host only when touched. `PROT_NONE` reservations no longer
count toward the guest memory limit; the limit (256 MiB by default) applies
when pages become accessible, through `mmap` or `mprotect`. Splits created by
`mprotect`, `munmap` and fixed replacements share one host mapping through a
reference count instead of copying bytes. `fork` copies only regions that were
ever written; untouched ranges are known to be zero. `RLIMIT_AS` reports
unlimited, as on Linux by default, and `MAP_NORESERVE`/`MAP_POPULATE` are
accepted.

**`madvise`.** Hints succeed. `MADV_DONTNEED` keeps its Linux contract that
private anonymous pages read back as zero: whole host pages are replaced with
fresh zero pages and only unaligned edges are cleared, so freed memory is not
committed again.

**Threads and I/O.** `FUTEX_REQUEUE` and `FUTEX_CMP_REQUEUE` (musl's condition
variables hand waiters to the mutex with them; without them, `pthread_join`
deadlocked at Node's shutdown). `ioctl(FIONBIO)` and `FIOCLEX`/`FIONCLEX` share
the `fcntl` paths, and `fcntl(F_SETFL)` works on host descriptors. Inherited
stdio keeps its host flags, so a guest can never leave the user's terminal or
shell pipe non-blocking. `--syscalls` traces tag lines with the calling
thread's ID when a guest has several threads.

**Processes and terminals.** Go's `os/exec` uses `clone(CLONE_VM | CLONE_VFORK)`
without a new stack, `waitid` (with `WNOWAIT`) and `wait4` with a `rusage`
pointer; all are supported, with resource usage reported as the child's
lifetime and guest memory. `flock` never blocks the host: a waiting guest
thread retries instead. `pidfd_open` reports `ENOSYS`, so Go falls back.
`/dev/tty` opens the controlling terminal that the guest's stdio already
uses, and `TCFLSH`, `TCSBRK`, `TCXONC` and the foreground-group queries work on
real terminals.

**CPU.** x86-64 `RCL`/`RCR` (rotate through carry), used by Go's runtime, with
the 8/16-bit count reductions and CF/OF-only flag updates.

## Limits

- Speed: Node needs about 8 seconds to start (roughly 145 million guest
  instructions); V8's generated code is interpreted, not translated to ARM64.
- No networking, so `http`, `npm install` and `fetch` cannot reach a network.
- A memory model shortcut: when a region that was written is split, every piece
  is treated as written, so a later `fork` copies (and commits) all of it.
- `--allow-files` grants host-user file access. UNIVERSE is not a sandbox.
