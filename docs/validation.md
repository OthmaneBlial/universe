# v0.1.0 validation evidence

Validated locally on 2026-09-30: Apple M2, macOS 26.6 ARM64, Zig 0.16.0,
Python 3.14. The runtime was built in ReleaseSafe; Zig unit tests use Debug.
GitHub Actions is disabled at repository level and no workflow is installed.

| Check | Result |
|---|---|
| `./scripts/check.sh` | Formatting, build, 30/30 Zig tests, rebuilt guests and integration checks pass |
| Clean source snapshot | Core checks, fresh BusyBox download/build and README command checks pass with no preexisting local build or guest artifacts |
| ELF execution | Eight C guests each for x86-64, RV64IM and AArch64; x86 assembly and static musl Hello World pass |
| Windows execution | Three console/API guests pass; unknown imports and malformed import RVAs fail explicitly |
| Guest behavior | Output, stderr, exit statuses, argv/env, files, directory pagination/seek, allocation, permissions, clocks and random requests pass |
| ARM64 JIT | Native block/interpreter comparisons, invalidation, limits and cross-architecture output comparisons pass |
| Optional upstream application | Checksum-pinned minimal BusyBox 1.37.0 echo/cat/ls build and interpreter/JIT regressions pass |
| Extended mutation run | 50,000 ELF/PE/Mach-O corpus mutations and 150,000 random CPU decoder cases pass; successful decodes are interpreted |
| Linux builds | ReleaseSafe cross-compilation for x86-64-linux-gnu and aarch64-linux-gnu passes |
| Benchmark | Independent native host C and all six interpreter/JIT paths produce the same expected hash |

The extended mutation command used the three ELF hello guests, Windows hello,
the host Mach-O runtime and the BusyBox guest as corpus inputs:

```sh
zig build fuzz -- 50000 artifacts/guests/x86_64/hello-asm \
  artifacts/guests/riscv64/hello artifacts/guests/aarch64/hello \
  artifacts/hello.exe zig-out/bin/universe artifacts/busybox-1.37.0/busybox
```

The bounded mutation runner is deterministic, not a coverage-guided campaign.
Zig 0.16.0's installed coverage-guided test runner did not compile; see
[security.md](security.md). Linux runtime execution and native matching-Linux
ELF differential tests were not performed on this Mac. Mach-O is inspected,
not executed. There was no independent security or broad application review.

Performance results, exact workload, seven-run medians and measurement boundaries
are recorded in [benchmarks/results.md](../benchmarks/results.md). Guest backing
storage and JIT page allocation are reported; peak host RSS is not measured.

## Current main development: private mappings

The local check now passes 32 Zig tests and nine C fixtures per Linux guest
architecture. The new mapping guest verifies private file bytes, page-aligned
offsets, zero-filled partial EOF pages, unchanged descriptor offsets and file
contents, fixed replacement, preservation after invalid requests and
MAP_FIXED_NOREPLACE. Whole pages beyond EOF stop with BusError. x86-64, RV64IM
and AArch64 execution and interpreter/JIT comparisons pass on the same Mac.
Allocation-failure injection verifies that fixed replacement leaves the old
mapping intact. The 10,000-mutation / 30,000-decoder local fuzz smoke run passes.
These additions are newer than the archived v0.1.0 release evidence above.
Updated ReleaseSafe Linux x86-64 and AArch64 cross-builds also pass; execution
on those hosts remains unverified.

## Current main development: PIE and dynamic musl

`./scripts/check.sh` passes 36 Zig tests, the nine C fixtures per CPU, new
standalone PIE Hello World fixtures for x86-64/RV64IM/AArch64, interpreter
handoff and malformed-interpreter cases, and sysroot file access. REP limits,
restartable string faults, direction, segment/address width, rotate flags and
zero/width-sensitive bit counts are covered. The site check and the
10,000-mutation / 30,000-decoder fuzz smoke run also pass.

`python3 scripts/musl.py` builds the checksum-pinned upstream musl 1.2.5
interpreter and a separate guest DSO. `python3 tests/musl.py` passes dynamic
x86-64 ET_EXEC and PIE with explicit argv/env, imported functions, constructors,
single-thread TLS, libc allocation and output, in interpreter/JIT paths.
Missing sysroot and denied file access fail explicitly. The build and tests
also pass with fresh upstream source extraction in an isolated temporary
workspace, using the locally validated runtime and pinned source archive.
Optional BusyBox echo/cat/ls regressions still pass in both execution paths.

ReleaseSafe Linux x86-64 and AArch64 cross-builds pass. Linux-host execution,
other dynamic guest CPUs, glibc and arbitrary dynamic application compatibility
are not established. The v0.1.0 release archive remains the older milestone.

## Current main development: AArch64 dynamic musl

`./scripts/check.sh` passes 44 Zig tests, all rebuilt core guests and the
10,000-mutation / 30,000-decoder fuzz smoke run. New regressions cover AArch64
guest TLS, extended arithmetic, long/high multiply, RBIT/CLZ, vector immediate
patterns and lane moves, checked scalar/vector and pair transfers, cache-block
zeroing, and exclusive store success/failure after writes, CLREX and remapping.
Memory faults preserve checked transfer destinations and pair writeback.
The file guest now verifies each CPU's O_DIRECTORY/O_NOFOLLOW/O_LARGEFILE flags,
including final-symlink rejection and unchanged guest GETFL bits.

`python3 scripts/musl.py --arch all` builds both upstream architectures in
separate out-of-tree directories. `python3 tests/musl.py --arch all` verifies
x86-64 and AArch64 ET_EXEC and PIE, each interpreted and with the partial JIT:
exact stdout, exit status, argv/env, DSO imports, constructor changes,
single-thread TLS and libc allocation all pass. Missing sysroot and denied file
access fail explicitly. The optional BusyBox regression and updated ReleaseSafe
Linux x86-64/AArch64 cross-builds also pass.

These results are from the same macOS ARM64 host, using UNIVERSE's own guest CPU
engine. They do not establish Linux-host execution, guest thread synchronization,
full SIMD support or arbitrary dynamic application compatibility. The v0.1.0
release archive remains unchanged.

## Current main development: Windows process, heap and files

The local check passes 49 Zig tests and the full rebuilt guest, site and fuzz
smoke regressions. `windows-process.exe` checks aligned process-heap allocation,
reallocation data/zero fill, failure without losing the old block, heap/virtual
allocation separation, zero-sized allocation and double-free rejection. It
prints matching UTF-8/UTF-16 command lines containing empty arguments, spaces,
quotes, trailing backslashes and a surrogate-pair character.

`windows-files.exe` checks UTF-8/UTF-16 creation, sharing conflicts without
truncation, duplicate opens, create-new collisions, read/write/EOF, file size,
seek from beginning/current/end, flush, read-only access rejection, truncation
and closed-handle errors. Exact output and host file contents pass with the
interpreter and partial JIT, including a prefixed absolute path. Denied access
creates no host file. Unit tests verify failed heap growth preserves the old
block and invalid file output pointers cannot consume input or change host data.
Creation-disposition tests also cover missing/open-always creation and explicit
truncation. The full core check passes from a clean source snapshot without
preexisting runtime/guest artifacts. Optional BusyBox and both architectures'
dynamic musl regressions still pass; updated Linux cross-builds pass as well.

Linux-host execution and native Windows differential execution remain
unverified. Guest environment APIs, DLL loading/TLS, exceptions and arbitrary
Windows programs are not established. The v0.1.0 release archive is unchanged.
