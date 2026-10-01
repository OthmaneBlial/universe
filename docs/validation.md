# v0.1.0 validation evidence

Validated locally on 2026-10-01: Apple M2, macOS 26.6 ARM64, Zig 0.16.0,
Python 3.14. The runtime was built in ReleaseSafe; Zig unit tests use Debug.
GitHub Actions is disabled at repository level and no workflow is installed.

| Check | Result |
|---|---|
| `./scripts/check.sh` | Formatting, build, 62/62 Zig tests, rebuilt guests and integration checks pass |
| Clean source snapshot | Core checks, fresh BusyBox download/build and README command checks pass with no preexisting local build or guest artifacts |
| ELF execution | Eight C guests each for x86-64, RV64IM and AArch64; x86 assembly and static musl Hello World pass |
| Windows execution | Three console/API guests pass; unknown imports and malformed import RVAs fail explicitly |
| Guest behavior | Output, stderr, exit statuses, argv/env, files, directory pagination/seek, allocation, permissions, clocks and random requests pass |
| ARM64 JIT | Native block/interpreter comparisons, invalidation, limits and cross-architecture output comparisons pass |
| Optional upstream application | Checksum-pinned BusyBox 1.37.0 selected applet build and interpreter/JIT regressions pass |
| Extended mutation run | 50,000 ELF/PE/Mach-O corpus mutations and 150,000 random CPU decoder cases pass; successful decodes are interpreted |
| Linux builds | ReleaseSafe cross-compilation for x86-64-linux-gnu and aarch64-linux-gnu passes |
| Benchmark | Independent native host C and all six interpreter/JIT paths produce the same expected hash |

The extended mutation command used the three ELF hello guests, Windows hello,
the host Mach-O runtime and the BusyBox guest as corpus inputs:

```sh
zig build fuzz -- 50000 artifacts/guests/x86_64/hello-asm \
  artifacts/guests/riscv64/hello artifacts/guests/aarch64/hello \
  artifacts/guests/riscv64/floating \
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
unverified. At this milestone, guest environment APIs, DLL loading/TLS,
exceptions and arbitrary Windows programs were not established. The v0.1.0
release archive is unchanged.

## Current main development: static guest Windows DLLs

The full local check passes 51 Zig tests, rebuilt core guests, site validation,
10,000 corpus mutations and 30,000 random decoder cases. DLL corpus mutations
also exercise loading and checked export lookup without executing host syscalls.
The core check passes from an isolated clean source snapshot with no preexisting
runtime or guest artifacts. Both Linux ReleaseSafe cross-builds pass; optional
BusyBox and x86-64/AArch64 dynamic musl regressions still pass.

`windows-dll.exe` imports a probe DLL that imports a helper DLL. All three
images request the same preferred base, forcing both DLLs to relocate. Their
absolute data pointers, dependency-order DllMain updates, imported function/data
exports, forwarding to a guest DLL and to the built-in WriteFile gateway,
case-insensitive module handles and GetProcAddress name/ordinal lookups are
checked by actual guest code. The executable prints the expected output and
exits zero in interpreter/JIT paths. A modified import thunk also exercises
static ordinal binding, rather than only API lookup by ordinal.

Missing sysroot, denied file access and missing DLLs fail explicitly. Mutated
library fixtures reject missing relocations, TLS directories, invalid export
counts/table RVAs/name ordinal indices, forwarding cycles and a false DllMain
return before the executable prints anything. An instruction limit of one also
stops initializer execution. Unit tests check export holes/case sensitivity,
forwarding with explicit DLL extensions, startup stack alignment/state restoration
and preserved instruction accounting.

This verified the source-built static dependency graph, not arbitrary Windows
programs or native Windows differential behavior. At that milestone,
LoadLibrary/FreeLibrary, late dependency loading, DLL detach/unload, TLS, SEH
and broad CRT compatibility remained unsupported. The archived v0.1.0 release
remains unchanged.

## Current main development: library-free Mach-O execution

The full local check passes 54 Zig tests, rebuilt Linux/Windows/Mach-O guests,
site checks, 10,000 corpus mutations and 30,000 random decoder cases. Valid
Mach-O mutations additionally attempt checked guest-memory loading without
executing guest syscalls. The check also passes from a clean source snapshot
without preexisting runtime or guest artifacts. Both Linux ReleaseSafe
cross-builds pass; optional BusyBox and both architectures' dynamic musl
regressions still pass.

Five source-built Mach-O C guests per CPU execute in interpreter/JIT modes.
They verify console I/O, stderr and nonzero exit, UTF-8 argv and explicit
environment, Apple executable-path entries, BSS/data pointers, private anonymous
and regular-file mappings, page sizes, maximum protections and file contents.
Denied file access creates no file; partial EOF pages are zero-filled and whole
pages beyond EOF fault. Malformed segments, sections, raw thread states and
entry points fail explicitly, as do unknown BSD syscalls/classes and incorrect
AArch64 SVC traps. Synthetic library-free LC_MAIN images verify argument
registers, stack alignment, return status and instruction limits in both modes.

Matching-host AArch64 native builds of the same hello/system/echo/files source
pass exact stdout/stderr/status and file-content comparisons. They use ordinary
native startup, so these results compare syscall test source, not acceptance of
the standalone LC_UNIXTHREAD images by macOS. No native x86 execution through
Rosetta is used. A normal dynamically linked native reference is explicitly
rejected by UNIVERSE with MachOLibrariesUnsupported.

This establishes the tested library-free Mach-O class. Dyld, LibSystem imports,
relocations, TLS, Mach IPC and arbitrary macOS applications remain unsupported.
Linux-host execution and native Windows comparisons remain unverified; the
v0.1.0 release archive is unchanged. See [macos.md](macos.md).

## Current main development: RISC-V compressed integers

The local check passes 57 Zig tests and the rebuilt Linux/Windows/Mach-O guest,
site and mutation checks. The core builder preserves RV64IM guests and builds
all nine C fixtures plus PIE again with RV64IMC instructions. Both variants
produce expected output, status and filesystem effects. Compressed guests also
pass interpreter/JIT checks for each fixture and PIE; the benchmark produces
the same expected hash. The fuzz corpus now includes a compressed RISC-V ELF.
The full check also passes from a clean source snapshot without preexisting
runtime or guest artifacts; both Linux ReleaseSafe cross-builds pass.

The compressed decoder is checked against 101 independent LLVM-assembler
reference encodings, including single-bit offsets for scrambled immediate
fields. Reserved encodings and unsupported floating-point/trap forms reject
explicitly; hints preserve registers and flags. Tests cover PC+2 links, mixed
two/four-byte fetches, a compressed instruction at an executable page's end,
missing/non-executable second halves of longer instructions, JIT instruction
limits and invalidation after replacing two short instructions with one long
instruction.

These are execution and encoding checks on the ARM64 Mac, not native RISC-V
differential execution or full ISA conformance. At this milestone, atomics,
floating-point, CSR instructions and compressed EBREAK trap handling remained
unsupported. The
v0.1.0 release archive remains unchanged.


## Current main development: RISC-V atomics and dynamic musl

The local check passes 59 Zig tests, rebuilt Linux/Windows/Mach-O guests,
site checks, 10,000 corpus mutations and 30,000 random decoder cases. The
corpus now includes the source-built RISC-V atomic fixture. Its builtin
operations, compare/exchange, invalidated LR/SC reservation, misaligned access
and instruction limit pass in interpreter and JIT modes. Unit tests cover all
nine word/doubleword AMOs with all AQ/RL combinations, signed word returns,
upper-word preservation, aliases, flags, reservation invalidation, permissions
and reserved encodings. Atomic memory operations stay interpreted.

The checksum-pinned, unmodified musl 1.2.5 source now builds a RISC-V soft-float
LP64 interpreter named `ld-musl-riscv64-sf.so.1`, a separate DSO and ET_EXEC/PIE
guests. Both pass imports, initialized data, constructors, single-thread TLS,
argv/env, allocation and output checks. All six dynamic executable/PIE images
across x86-64, AArch64 and RISC-V pass interpreter/JIT comparisons and reject
missing sysroots or denied file access. BusyBox echo/cat/ls regressions pass.

These checks do not establish native RISC-V differential execution, hard-float
support or concurrent guest synchronization. RISC-V F/D, CSR instructions and
compressed EBREAK remain unsupported. The v0.1.0 release archive is unchanged.

The full core check also passes from a clean source snapshot with no existing
runtime or guest artifacts. A fresh RISC-V musl build, using only the verified
source archive, passes both executable types and modes with only the correctly
named soft-float interpreter in its sysroot. ReleaseSafe cross-builds for
`x86_64-linux-gnu` and `aarch64-linux-gnu` pass; Linux host execution remains
unverified. See the later host-libc portability milestone for current GNU and
musl host-target build results.

## Current main development: Windows runtime DLL lifecycle

The full local check passes 62 Zig tests, rebuilt Linux/Windows/Mach-O guests,
site validation, 10,000 corpus mutations and 30,000 random decoder cases. It
also passes from a clean source snapshot with no preexisting runtime or guest
artifacts. ReleaseSafe cross-builds for Linux x86-64 and AArch64 pass. All three
architectures' dynamic musl ET_EXEC/PIE checks pass. The optional BusyBox build
now includes a tested subset of coreutils and file applets; interpreter checks
pass, as do JIT checks on this ARM64 host.

The Windows fixture builder now supplies seven executable fixtures and five
DLL images, plus UTF-16-name and extensionless aliases. The runtime-loading
guest verifies LoadLibraryA/W, GetProcAddress and FreeLibrary through actual
guest code: shared references, imports and ordinal/data exports, runtime
DllMain reserved arguments, late forwarder initialization, cyclic imports,
dependency retention, detach callbacks and 80 unload/reload cycles. A cyclic
group that gains a later dependency detaches before that dependency; callbacks
can still call its code while the group unloads.

Mutated DLLs verify false-attach rollback without removing an existing module,
cleanup order and LastError preservation. Missing, truncated, TLS-bearing,
unreadable and FIFO late dependencies return guest API errors while the parent
remains usable. Unreadable sysroot-directory and DLL checks run as the non-root
host user. Traces report the final failed load result after callback cleanup.
Instruction limits include callback execution; loader calls from DllMain fail
explicitly rather than starting a nested operation.

PE image loading reserves the complete image, leaves unmapped section gaps
inaccessible, rejects overlapping section pages and rolls back failed loads.
Allocation-failure injection verifies rollback for every allocation in the
synthetic PE load. Shared binary reads now require regular files and reject
directories and FIFOs without blocking.

These are source-built fixture checks on macOS ARM64, not native Windows
differential execution or arbitrary Windows compatibility. Startup imports
retain their dependency graph; only explicit LoadLibrary references can be
released by FreeLibrary. TLS, loader search paths/extended flags, reentrant
loading, process-termination detach, SEH and full CRT compatibility remain
unsupported. Linux-host execution remains unverified, and the v0.1.0 release
archive is unchanged. See [windows.md](windows.md).

## Linux GNU/musl host portability milestone

The ReleaseSafe runtime cross-builds for `x86_64-linux-gnu`,
`aarch64-linux-gnu`, `x86_64-linux-musl` and `aarch64-linux-musl` pass. This
removes the Zig 0.16 opaque `struct stat`/`timespec` build failure by using
Linux `statx` metadata and standard Zig timespec layouts; macOS uses Zig's
target-native `std.c.Stat`. Shared host metadata now feeds binary-file checks,
Linux guest `stat`/`fstat`/`newfstatat`, private file `mmap`, Windows file
sharing/size calls and Darwin private-file mapping checks.

The full local check passes 61 Zig tests, all rebuilt guest integrations, site
validation and the 10,000-mutation/30,000-decoder fuzz smoke. This includes
regular-file enforcement, FIFO rejection without blocking, file sizes,
timestamps, guest `fstat`, symlink open policy and interpreter/JIT runs. Linux
targets are cross-compiled only here; Linux-host execution and runtime behavior
on older kernels without `statx` remain unverified.

## RISC-V F/D arithmetic, conversion and CSR milestone

`./scripts/check.sh` passes 61 Zig tests, all rebuilt fixtures and integration
checks, the site check (including five recorded guest outputs), and the
10,000-corpus-mutation/30,000-decoder smoke run. A new source-built hard-float
RV64 guest checks F/D loads and stores, NaN-boxed single values, FMV transfers,
sign injection, FCLASS, FEQ/FLT, FADD/FSUB/FMUL/FDIV/FSQRT, FMIN/FMAX, all four
fused multiply-add forms, all five rounding modes for arithmetic and fused
operations, FCVT.S.D under all five rounding modes, exact
FCVT.D.S, FCVT in both integer/floating directions, all five float-to-integer
and integer-to-float rounding modes, NV/DZ/OF/UF/NX flags, NaN conversion and
saturation, compressed C.FLD/C.FSD/C.FLDSP/C.FSDSP, and register/immediate
CSRRW/CSRRS/CSRRC forms for `fflags`, `frm` and `fcsr`. It passes in interpreter
and ARM64-host JIT modes; unsupported operations fall back to interpretation.

This is a selected F/D arithmetic and transfer/conversion slice, not general
RVF/RVD support. Other CSRs and compressed EBREAK handling remain unsupported.
Validation is on macOS ARM64. ReleaseSafe host builds pass for x86-64/AArch64
Linux GNU/musl and RISC-V64 Linux musl; guest execution on Linux and native
RISC-V differential execution remain unverified.

## Current main development: SSE2 signed-word min/max

The x86-64 interpreter implements `PMINSW` and `PMAXSW` (`66 0F EA` / `66 0F
EE`) for register operands and aligned memory sources. Eight-lane tests cover
signed extrema, and the memory form checks its alignment fault. BusyBox 1.37.0's
numeric `printf '%s:%04d\n' guest 7` now runs successfully through the real ELF
guest, exercising the previously missing `PMINSW` path.

`./scripts/check.sh` passes 62 Zig tests, rebuilt guests, integrations, site
validation and the 10,000-mutation/30,000-decoder fuzz smoke. The separate
BusyBox regression passes in interpreter and ARM64-host JIT modes. ReleaseSafe
cross-builds for AArch64 Linux GNU and RISC-V64 Linux musl pass. This adds two
SSE2 operations and does not establish general SIMD support.

## Current main development: Linux filesystem mutations

Guest `mkdirat`, `unlinkat`, `renameat`, `faccessat` and `utimensat` now map across x86-64,
RISC-V64 and AArch64; legacy x86-64 `access`, `mkdir`, `rmdir`, `unlink` and
`rename` are covered too. `filesystem-mutate.c` verifies default-denied
behavior, directory/file create, rename and removal, relative directory
descriptors, access checks, explicit nanosecond timestamps, UTIME_NOW/UTIME_OMIT,
invalid nanosecond rejection, ENOENT and cleanup in a temporary working directory.
It passes for every guest architecture in the interpreter and
ARM64-host JIT paths. Host `AT_REMOVEDIR` is translated explicitly because its
value differs from Linux's guest flag. The checksum-pinned BusyBox 1.37.0 guest
passes selected `mkdir`, `rm`, `rmdir`, `cp`, `mv` and `touch` cases, along with `grep`,
`sed`, `tr` and `uniq`; full applet and shell compatibility remain open.
ReleaseSafe host cross-builds for x86-64/AArch64 Linux GNU and musl plus
RISC-V64 Linux musl pass.

## Current main development: SSE2 packed arithmetic and compare

The local check passes 62 Zig tests, all rebuilt guest integrations, site
validation and the 10,000-mutation/30,000-decoder fuzz smoke. A dedicated
x86-64 guest checks modular packed addition and subtraction for byte, word,
doubleword and quadword lanes, plus signed greater-than comparisons for byte,
word and doubleword lanes and signed/unsigned saturating byte/word add/subtract
against scalar expected boundary results from runtime input. This does not
establish general SIMD or floating-point support.

## Current main development: SSE2 high-half unpack

The x86-64 guest also executes `PUNPCKHBW`, `PUNPCKHWD`, `PUNPCKHDQ` and
`PUNPCKHQDQ`. Runtime-filled source vectors are checked lane-by-lane against
the expected interleaving of their upper 64-bit halves.

## Current main development: SSE2 packed multiply

A dedicated x86-64 guest checks `PMULLW`, `PMULHW`, `PMULHUW`, `PMULUDQ` and
`PMADDWD` against scalar results using runtime input, including signed extrema
and the wrapped 32-bit pair-sum result. Its compiled scalar oracle also executes
`PEXTRW`, which zero-extends one selected word into a general-purpose register.

## Current main development: SSE2 register-count shifts

The x86-64 guest checks register-count `PSRLW/D/Q`, `PSRAW/D`, and `PSLLW/D/Q`
for counts 0, 1, at and beyond lane width, and 63/64/65. A nonzero upper 64 bits
in the count vector verifies that only the low 64-bit count controls the shift;
results are compared lane-by-lane with scalar expectations.

## Current main development: SSE2 averages and SAD

The arithmetic guest checks rounded unsigned byte/word averages at odd and
extreme values, plus both 8-byte-group sums produced by `PSADBW`; unused output
bits are verified as zero.

## Current main development: SSE2 saturating pack

A dedicated guest checks `PACKSSWB`, `PACKSSDW`, and `PACKUSWB` against scalar
clamping for negative, positive, and exact-boundary word/dword inputs. It also
checks `PINSRW` insertion from a register into all eight lanes, plus its m16
source form, verifying preservation of every untouched lane.

## Current main development: SSSE3 byte shuffle

The `PSHUFB` guest checks register and aligned-memory mask operands against a
scalar oracle, including low-nibble indexing, ignored upper bits and bit-7
zeroing. `PSIGNB/W/D` test byte, word and dword zero, preserve and wrapping
negation; `PABSB/W/D` check absolute values including the signed minimum's
wraparound. `PMADDUBSW` checks paired signed/unsigned products with both signed
16-bit saturation limits; `PMULHRSW` checks positive and negative rounding ties
and the signed minimum product. `PHADDW/D/SW` and `PHSUBW/D/SW` verify source and
destination pair order, modular dword/word results and signed-word saturation.
`PALIGNR` covers byte counts around both 16- and 32-byte boundaries; a misaligned
memory operand faults as required.

## Current main development: SSE4.1 subset

The x86-64 guest checks `PMULLD`, packed signed/unsigned min/max, `PCMPEQQ` and
all 12 `PMOVSX`/`PMOVZX` widening conversions against scalar results from
runtime input. It covers signed extrema, low-dword product wrap, equal lanes,
full-width equality masks and sign/zero extension. Register and unaligned-memory
source encodings are exercised. `PMULDQ`, `PACKUSDW` and `PHMINPOSUW` also
cover unaligned memory operands, signed overflow boundaries, unsigned
saturation and first-minimum position. `PTEST` checks both CF and ZF against a
scalar byte mask; `PBLENDW` checks all immediate-controlled word lanes from an
unaligned memory source, while `BLENDPS/PD` test dword/qword selection.
`MPSADBW` checks all eight sliding four-byte absolute-difference sums using
register and unaligned-memory sources, both selector fields and ignored high
immediate bits.
`ROUNDPS/PD/SS/SD` check ties-to-even, upward, downward and truncation modes,
scalar preservation, current-mode selection at reset state, signed zero,
infinity and signaling-NaN quieting. `DPPS/DPPD` check product masks,
reduction and output selection. MXCSR flags/traps were not modeled at that
checkpoint; the current MXCSR regression below adds control/exception coverage.
`PBLENDVB` and `BLENDVPS/PD` test byte/dword/qword mask lanes with `XMM0`,
including both register and unaligned-memory sources.
`PINSRB/RD/RQ` cover register and unaligned-memory sources and preserve untouched
lanes; `INSERTPS` checks register/memory sources, source/destination selection
and zero masks. `MOVNTDQA` checks an aligned 16-byte memory load and the
misaligned-address fault; the cache hint is not modeled. `PEXTRB/W/D/Q` and
`EXTRACTPS` cover register and memory destinations, including zero-extension.
The fixture reports transfer vectors/scalars for exact byte comparison in the
host integration test.
`./scripts/check.sh` validates the fixture with the full local suite; this
remains a tested SSE4.1 subset.

## SSE4.2 CRC32C

`examples/x86-sse42-crc32.c` checks `CRC32` byte, word, dword and qword forms
against a scalar reflected Castagnoli-polynomial oracle. It covers the legacy
high-byte register encoding, the `123456789` known vector, zero-extension from
a 32-bit destination and unchanged CF/ZF/PF/OF/SF. `PCMPGTQ` covers register
and aligned-memory operands against signed scalar comparisons. The fixture runs
in the interpreter and ARM64-host JIT;
unsupported JIT instructions fall back to the checked interpreter.

## SSE/SSE2/SSE3 scalar, packed and move instructions

`examples/x86-sse-fp.c` exercises `ADD/SUB/MUL/DIV/SQRT/MIN/MAX` in packed and
scalar single and double precision, using both register and memory sources. It
also checks all eight legacy predicates for `CMPPS/PD/SS/SD`, unordered values,
full-lane masks and scalar upper-lane preservation.
`UCOMISS/COMISS/UCOMISD/COMISD` cover equal, less-than, greater-than and
unordered EFLAGS outputs. Exact
output bytes are compared by the host integration test. Scalar 32/64-bit
`CVTSI2SS/SD`, `CVTSS/SD2SI` and `CVTTSS/SD2SI` check precision ties, truncation,
upper-lane preservation, NaN/infinity and out-of-range indefinite values. Legacy
`MOVSS/MOVSD` check memory-load zeroing, exact-width stores with guard bytes,
and register moves that preserve upper XMM lanes. `CVTSS2SD/CVTSD2SS` check
cross-format precision and destination-lane preservation. Packed `CVTDQ2PS`,
`CVTPS2DQ`, `CVTTPS2DQ`, `CVTPS2PD`, `CVTPD2PS`, `CVTDQ2PD`, `CVTPD2DQ` and
`CVTTPD2DQ` check lane mappings, signed extrema, precision ties, invalid
indefinite values and truncation. The current MXCSR regression below adds
rounding controls and FP exception flags/traps. `MOVSLDUP/MOVSHDUP` check even/odd lane replication,
`MOVDDUP` duplicates one 64-bit memory value, and `LDDQU` reads the expected
16 bytes from an intentionally unaligned address. `HADDPS/PD`, `HSUBPS/PD` and
`ADDSUBPS/PD` compare register and memory forms against exact lane results.

## x86 POPCNT

`examples/x86-popcnt.c` checks 16-, 32- and 64-bit counts from register and
memory sources, plus zero input. A pre-seeded flag pattern verifies that the
instruction clears carry, parity, sign and overflow, and sets zero only for a
zero source. Exact output bytes are checked by `tests/integration.py`.

## x86 BSWAP

`examples/x86-bswap.c` checks 32-bit and 64-bit byte reversal, REX.B access to
R8, zero-extension from `BSWAP R8D`, and preservation of the modeled status
flags. Exact result bytes are compared in `tests/integration.py`.

## Current main: persistent SQLite batch CLI

Validated locally on 2026-10-01 on the same Apple M2/macOS ARM64 host:

- `./scripts/check.sh`: 65/65 Zig tests, ten libc-free C fixtures per Linux CPU
  (including RV64IMC), interpreter/JIT integration, site links/SVGs/recorded
  outputs, 10,000 corpus mutations and 30,000 random decoder cases pass.
- `python3 scripts/sqlite.py`: checksum-pinned upstream SQLite 3.53.4 builds
  unchanged as a static x86-64 musl guest with threads/extensions disabled.
- `python3 tests/sqlite.py`: interpreter/JIT SQL, persisted transactions,
  indexes/joins, Unicode/blobs, rollback, delete/truncate journals, relative-path
  reopen, bulk mutations, VACUUM and integrity checks pass. Python's native
  SQLite verifies exact database rows; a native exclusive transaction blocks
  the guest until released. Denied file access creates no database.
- The libc-free storage fixture verifies positioned/scatter I/O, unchanged
  offsets, EOF, invalid buffers before host I/O, sync/truncate, relative stat,
  symlink truncation, sysroot cwd and external advisory-lock conflicts on every
  Linux guest CPU. Signal metadata tests cover all three kernel action layouts.
- ReleaseSafe x86-64-linux-gnu and aarch64-linux-gnu cross-builds pass; execution
  on those Linux hosts remains unverified.
- Desktop/mobile browser review verifies the SQLite copy control's exact text;
  long inline code now wraps with no page overflow at 390px.

Guest signal delivery, WAL/shared-memory coordination, loaded extensions,
guest threads and interrupted-commit/power-loss recovery are outside this
validation. See [sqlite.md](sqlite.md) for the build and application boundaries.

## Current main: x86 CPU discovery and Debian glibc boundary

Validated locally on 2026-10-01 on the Apple M2/macOS ARM64 host:

- `./scripts/check.sh`: 71/71 Zig tests, all core Linux/Windows/Mach-O guests,
  interpreter/JIT comparisons, site links/SVGs/recorded outputs, 10,000 corpus
  mutations and 30,000 decoder cases pass.
- Six new unit checks cover the virtual RDTSC counter, conservative CPUID
  profile, exact-width SSE half-register transfers, short accumulator XCHG,
  unavailable thread capability probes on all three CPUs and untaken CMOV
  zero-extension/source faults. Existing scalar lane-insertion regressions
  continue to pass through the shared vector executor.
- `python3 scripts/debian.py` freshly downloads and verifies three pinned
  Debian packages, extracts their unchanged data and constructs a private
  merged-/usr sysroot. No package scripts or system installation are used.
- `python3 tests/debian.py` passes in interpreter and ARM64-host JIT modes.
  This is a **negative compatibility check**: GNU Hello/glibc initializes TLS,
  sees ENOSYS for robust-list/rseq facilities, and exits 127 with its own
  CPU-baseline rejection, without an engine fault. GNU Hello does not run yet.
- Separate `tests/sqlite.py`, `tests/busybox.py` and `tests/musl.py --arch all`
  pass on the same runtime. SQLite persistence/locks and all three dynamic
  musl architectures remain covered.
- Chrome checks the updated flight manual at desktop and 390px mobile width;
  document width stays 390px. Quick-start commands copied through the UI paste
  exactly into an isolated local text field. The temporary field is removed.
- GitHub Actions remains disabled; validation is local. No new Linux host
  execution, glibc application success, full x86 baseline or 50% completion is
  inferred from this milestone.

See [debian.md](debian.md) for the pinned versions, reproducible command and
remaining baseline requirements.

## Current main: paired x86 atomics, original MMX and state images

Validated locally on 2026-10-01 on the Apple M2/macOS ARM64 host:

- `./scripts/check.sh`: 76/76 Zig tests, all core Linux/Windows/Mach-O guests,
  interpreter/JIT comparisons, site checks, 10,000 corpus mutations and 30,000
  decoder cases pass. The new baseline guest runs in the default local suite.
- `tests/x86-baseline.py` checks paired compare/exchange success/failure,
  36 original MMX binary operations with register/memory sources, all eight
  shift families at lane boundaries and beyond, MOVD zero-extension, x87/MMX
  alias data, all 16 XMM registers and preserved state-image tails against
  independent scalar results in interpreter/JIT modes.
- Five added unit checks cover instruction encodings, flags, alignment,
  failed-comparison writeback, exact-width accesses, pending x87 exceptions,
  EMMS tags/TOP, both state-image pointer layouts, stack-slot mapping and
  fault/control rejection before state changes. Unaligned MXCSR transfers
  and four-byte page-end accesses pass.
- Separate SQLite, BusyBox and all three dynamic musl regressions pass.
  The unchanged Debian glibc probe still exits 127 with its CPU-baseline
  diagnostic, without an engine fault; GNU Hello does not run yet.
- ReleaseSafe Linux x86-64/AArch64 GNU cross-builds pass; execution on those
  Linux hosts remains unverified. Chrome desktop and 390px mobile review
  checks the updated docs with no horizontal overflow and exact command
  copying through the UI. The temporary paste field is removed.

CPUID now advertises CX8, MMX and CX16. FPU, FXSR, SSE and SSE2 remain clear:
x87 arithmetic remains unsupported. This checkpoint preceded the MXCSR
control/exception work described below. State-image support is bounded, not complete floating-point
compatibility. GitHub Actions stays disabled; these checks are local. This
milestone does not establish 50% completion of the full project.

## Current main: SSE rounding controls and exception staging

Validated locally on 2026-10-01 on the Apple M2/macOS ARM64 host:

- `./scripts/check.sh`: 80/80 Zig tests, every core guest and interpreter/JIT
  comparison, 10,000 corpus mutations, 30,000 decoder cases and the site checks
  pass. The core check now builds `examples/x86-mxcsr.c` and runs its host oracle.
- `tests/x86-mxcsr.py` checks 9,282 binary queries per engine against independent
  Python integer/Fraction arithmetic. Square roots use integer square-root and
  exact midpoint comparisons. Both float formats cover all four rounding modes,
  denormals, DAZ/FTZ, signed zero, infinities, quiet/signaling NaNs, conversions,
  comparison predicates/EFLAGS, horizontal operations and dot products.
  Seeded finite inputs supplement the explicit precision/overflow/underflow
  boundaries. Existing sticky flags survive exact operations, including when
  those flags are already unmasked.
- Four added unit checks cover MXCSR rounding, NaN priority, precision
  suppression, tininess with an unbounded exponent and fault staging. Decoded
  unmasked pre/post exceptions preserve destinations, EFLAGS, PC and counters;
  pre-computation traps suppress post flags. Exact unmasked overflow/underflow
  does not invent precision loss. Source memory faults leave all state unchanged.
  State-image tests now round-trip DAZ/FTZ, rounding and pre-existing unmasked
  status through both pointer layouts; reserved MXCSR bits still fail atomically.
- The existing floating guest verifies packed conversion lane mappings, memory
  sources and scalar upper-lane preservation. The shared RISC-V rounding engine
  is reused; an infinity-result precision bug found by the new oracle is fixed
  there, and the RISC-V F/D guest still passes.
- Separate SQLite, BusyBox and all three dynamic musl regressions pass. The
  unchanged Debian/glibc probe still exits 127 with its CPU-baseline diagnostic
  and no engine fault. GNU Hello does not run yet.
- ReleaseSafe Linux x86-64/AArch64 GNU cross-builds pass. Execution on those
  Linux hosts is unverified. Chrome review at 1280px desktop and 390px mobile
  confirms readable documentation, no horizontal overflow, visible copy controls
  and copied commands matching the snippet. The preview server/tab are closed
  and the temporary viewport is reset.

The implemented SSE operations accrue MXCSR exceptions; a new unmasked
condition stops with `SimdFloatingPointException`. Guest signal delivery/frames,
x87 arithmetic and complete SSE/SSE2 instruction coverage remain unsupported;
CPUID stays conservative. This verified milestone does not establish 50%
completion of the full project. GitHub Actions remains disabled; checks are local.

## Current main: x87 stack, transfers and control word

Validated locally on 2026-10-01 on Apple M2/macOS ARM64:

- `./scripts/check.sh` passes 84/84 Zig tests, rebuilt Linux/Windows/Mach-O
  guests, interpreter/JIT comparisons, site checks, 10,000 corpus mutations
  and 30,000 random decoder cases.
- `tests/x87.py` checks 29,813 binary queries per engine using exact Python
  integers/Fractions and the independent IEEE encoder shared with the SSE
  oracle. Coverage includes signed 16/32/64-bit integer loads/stores, float
  loads/stores, four rounding modes, arithmetic precision-control independence,
  signed zero, infinities, quiet/signaling NaNs, raw 80-bit values, stack
  operations, sign/classification instructions and masked/unmasked status.
- Four unit tests verify exact-width page-boundary faults, rejected encodings
  and LOCK prefixes, ignored REX register extensions, raw-data-preserving init,
  deferred stack exceptions, no-wait controls, destination/pop behavior and
  x87/MMX physical aliasing across EMMS. Waiting faults preserve PC/state.
- The existing 9,282-query SSE oracle still passes in both engines after its
  entry point became importable by the x87 oracle.

x87 arithmetic, comparisons, transcendentals, most constants and legacy
environment save/restore remain unsupported. CPUID FPU/FXSR/SSE/SSE2 bits stay
clear. Numeric conditions are deferred to the next waiting instruction; guest
signal delivery remains unsupported. This checkpoint advances compatibility;
it does not claim completion of the full project.
