# Launch notes

Drafts for sharing UNIVERSE. Every claim below links to a reproducible command or
test in this repository; update the numbers from the latest local validation
before posting. Post once per community, answer questions, and do not ask for
stars or votes.

## Show HN

**Title:** Show HN: UNIVERSE – run unchanged x86-64 Linux Python and git on an ARM Mac, in Zig

**Text:**

UNIVERSE is an experimental binary runtime written in Zig. It loads ELF, PE and
small Mach-O binaries and executes their machine code with its own x86-64,
AArch64 and RISC-V64 decoder, interpreter and a small ARM64 JIT, then translates
their Linux, Windows or Darwin system calls itself. No QEMU, Wine, Rosetta or VM.

What runs today on an Apple M2, all unchanged downloads with pinned SHA-256s:

- The official x86-64 Linux CPython 3.13 build, including the interactive REPL,
  sqlite3, threads and subprocess pipelines into BusyBox
- Alpine's git 2.49: init, commit, diff, log, branch and switch; commit IDs match
  an independent SHA-1 computation
- jq, ripgrep, fd, BusyBox, 7-Zip (Linux and the Windows .exe), Debian GNU
  coreutils with their original glibc

How it got there: run a real binary, find the first missing syscall or
instruction, implement the general Linux semantics (not an app special case),
add a regression test, repeat. Python needed mremap, termios ioctls, select and
chroot-style symlink resolution; git needed chdir, link/symlink, chmod and
/dev/urandom.

Honest limits: it is slow (about 16 million guest instructions per second in
the interpreter; CPython needs several seconds to start), there is no networking or GUI,
and it is not a sandbox. Everything is validated locally with exact-output tests
in both the interpreter and the JIT.

Repo: https://github.com/OthmaneBlial/universe

## r/programming / r/Zig

**Title:** I'm building a binary runtime in Zig that runs unchanged Linux Python and git on an ARM Mac

Use the Show HN text; for r/Zig add a paragraph on the design: checked guest
memory, a shared Universal IR for three ISAs, W^X JIT pages, and how Zig's
by-value parameter semantics turned a 1.2 KiB CPU-state copy into the hottest
path (fixed by passing pointers); with caching and batching, CPython runs 4.6×
faster than at the start of that work.

## X / Bluesky thread

1. Unchanged x86-64 Linux CPython 3.13, REPL and all, running on an ARM Mac
   through a runtime written from scratch in Zig. No QEMU, no Rosetta, no VM.
   [attach docs/assets/python-repl.svg as a GIF/video capture]
2. It decodes x86-64 itself, executes it on its own interpreter/JIT and
   translates Linux syscalls to macOS. git works too: commit IDs match real git.
3. Honest part: it's slow (~10 MIPS interpreted), no networking, not a sandbox.
   Every supported workflow is an exact-output test. Repo: https://github.com/OthmaneBlial/universe

## Likely questions

- **Why not QEMU user mode?** QEMU doesn't run on macOS in user mode; UNIVERSE is
  an independent implementation meant to be readable and testable.
- **How fast?** Measured numbers live in [benchmarks/results.md](../benchmarks/results.md)
  and [python.md](python.md). Native is far faster.
- **Is it safe to run untrusted binaries?** No. `--allow-files` grants host-user
  file access; see [security.md](security.md).
