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

## Current main: official downloaded Linux apps on a Mac

Validated locally on 2026-10-01 on Apple M2/macOS 26.6 ARM64:

- Checksum-pinned official jq 1.8.2 and ripgrep 15.2.0 Linux x86-64 release
  binaries run unchanged. `tests/public-apps.py` passes **28/28 workflows**,
  14 per engine: JSON filters/decimal addition, Unicode/sorting, predicates,
  malformed JSON, regex searches/counts, missing matches, invalid regexes,
  input files and denied file access. Output and exit statuses are checked.
  The tested ReleaseSafe runtime bytes match `zig-out/bin/universe`.
- `./scripts/check.sh` passes **94/94 Zig tests**, rebuilt core guests,
  interpreter/JIT comparisons, the 9,282-query SSE and 29,813-query x87 exact
  oracles per engine, 10,000 corpus mutations, 30,000 decoder cases and site
  checks. It remains network-free; only the explicit app download script
  accesses the network.
- New CPU checks cover wrapped 32-bit addresses, FS bases, EIP-relative forms,
  64-bit near calls, XADD aliases/flags/fault staging, single-thread fences,
  disabled-CET reads, cache hints, every SHUFPS/SHUFPD immediate, floating lane
  unpacks and MOVMSK sign patterns. Checked memory faults preserve state.
- Linux checks cover bounded poll/readiness, resource-limit queries,
  alternate-stack metadata and futex wake. F_DUPFD/F_DUPFD_CLOEXEC shares native
  file offsets while using the lowest available guest slot and independent
  flags; exhaustion, invalid arguments and borrowed handles are checked.
  This fixes ripgrep's normal stdin detection. Optional unavailable services
  return explicit Linux errors; no threads or signal delivery are implied.
- Separate SQLite, BusyBox and all three dynamic musl regressions pass. The
  dynamic Debian/glibc probe still rejects the CPU baseline without an engine
  fault; this differs from the working static glibc jq workflows.
- ReleaseSafe Linux x86-64/AArch64 GNU cross-builds pass; execution on Linux
  hosts remains unverified. Chrome review at 1280px desktop and 390px phone
  widths confirms readable app cards/docs, no horizontal document overflow
  and exact command copying through UI paste. Temporary preview resources
  are removed and the viewport is restored.

This reaches the requested practical “50%” application milestone: download
useful Linux or Windows apps and run them on the user's Mac. It is not a
measurement of half the complete roadmap. The verified scope is Linux CLI
workflows; GUI apps, general Windows apps, networking and guest threads remain
future work. See [public-apps.md](public-apps.md). GitHub Actions stays disabled;
all compatibility checks are local.

## Current main: exact x87 calculations and comparisons

Validated locally on 2026-10-01 on Apple M2/macOS ARM64:

- `./scripts/check.sh` passes **96/96 Zig tests**, rebuilt Linux/Windows/Mach-O
  guests, interpreter/JIT comparisons, site checks, 10,000 corpus mutations
  and 30,000 random decoder cases.
- `tests/x87-arithmetic.py` checks **102,630 queries per engine** over 63 decoded
  register and memory forms. Independent Python Fractions, bit encoders and
  integer square-root midpoint checks verify add/subtract/multiply/divide,
  square roots, integral rounding and ordered/unordered comparisons. Coverage
  includes three precisions, four rounding modes, full extended exponents,
  signed zeros, NaNs, denormals, empty operands and masked/unmasked conditions.
  This is exact-result oracle validation, not native x86 hardware comparison.
- Unit checks cover exact-width memory faults, LOCK rejection, ignored REX
  extensions, all eight wrapped stack destinations and deferred exceptions.
  Unmasked register overflow/underflow store exponent-biased results; precision
  results commit too, including pop forms. The following WAIT faults without
  changing state. Invalid, denormal and divide-by-zero pre-computation
  exceptions preserve the destination and TOP when unmasked.
- The existing 29,813-query x87 transfer and 9,282-query SSE suites still pass
  in both engines. All **28 downloaded jq/ripgrep workflows**, SQLite, BusyBox
  and dynamic musl on all three guest CPUs pass separately. The unchanged
  Debian/glibc probe still reports its CPU-baseline rejection without an engine
  fault; GNU Hello remains unsupported.
- ReleaseSafe Linux x86-64/AArch64 GNU cross-builds pass; execution on those
  hosts remains unverified. Chrome review at 1280px desktop and 390px phone
  widths confirms readable updated documentation and no horizontal overflow.
  Preview resources are closed and the viewport is restored.

Arithmetic uses integer significands and the standard library's integer square
root, with no external emulator or floating-point library dependency. Conditional
moves, remainders, scaling, transcendentals, remaining constants and legacy x87
environment save/restore still need work. CPUID FPU/FXSR/SSE/SSE2 stays clear;
guest signal delivery remains unsupported. The broader compatibility goal stays
open, and GitHub Actions stays disabled.

## Current main: x87 conditional moves and all constant loads

Validated locally on 2026-10-01 on Apple M2/macOS ARM64:

- `./scripts/check.sh` passes **97/97 Zig tests**, all rebuilt core guests,
  the existing SSE/x87 transfer oracles, **112,422 calculation/move/constant
  queries per engine**, site checks, 10,000 corpus mutations and 30,000 decoder
  cases. The calculation guest now covers **78 decoded forms**.
- A single decoded unit check covers all eight FCMOV conditions, every CF/ZF/PF
  combination, all eight logical stack slots, wrapped TOP and ignored REX
  extensions. Raw signaling NaNs move without quieting or invalid exceptions.
  Untaken moves still check empty operands; masked faults write indefinite,
  while unmasked faults preserve the destination and defer the following WAIT.
  Integer flags, tag/TOP and the remaining condition bits are checked too.
- Constant loads now include log2(10), log2(e), pi, log10(2) and ln(2), alongside
  1 and 0. Independent 100-digit decimal logarithms and a Chudnovsky pi
  calculation produce the expected raw values for all four rounding modes.
  Checks cover all precision-control encodings, ignored input values, full-stack
  faults and unmasked precision; loads never accrue precision loss.
- All **28 unchanged downloaded jq/ripgrep workflows**, SQLite, BusyBox and
  dynamic musl on all three guest CPUs pass. The Debian/glibc probe retains
  its CPU-baseline rejection without an engine fault. Linux x86-64/AArch64 GNU
  ReleaseSafe cross-builds pass; execution on those hosts is still unverified.
- Chrome previews at 390px and 1280px confirm readable updated documentation
  without horizontal overflow. Preview resources are closed and the viewport
  is restored.

This extends the previous calculation checkpoint without another runtime
dependency. Remainders, scaling, transcendentals and legacy x87 environment
save/restore remain unsupported. CPUID remains conservative, broader application
compatibility work remains open, and all CI checks remain local.

## Current main: unchanged Linux 7-Zip archive workflows

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- The official 7-Zip 26.03 static Linux x86-64 `7zzs` binary executes unchanged.
  `scripts/public-apps.py` pins the upstream archive SHA-256
  `dc99eff5008f1ab79bd7084c68513701547a808a89502bf4133683535ab3c695`
  and extracted executable SHA-256
  `eab4c8d7f193e3d6d3237370bbcaa879a160a3f1dc82202207e27baeab79b6ac`.
  Cached archives are verified again before extracting the single regular file.
- `tests/public-apps.py` passes **62 workflows**, 31 per engine: the previous
  jq/ripgrep cases plus 17 7-Zip cases per engine. ZIP and 7z creation, technical
  listing, testing and extraction preserve binary/text/empty input bytes,
  nested paths and modification times. SHA-256 matches Python; Python's ZIP
  implementation independently checks produced CRCs/member bytes and supplies
  another compressed archive for the guest to extract. Recursive ZIP folder
  scanning and corrupt/missing/denied input/output cases are checked too.
- The real app exposed a shared dirfd bug: valid zero-extended `0xffffff9c`
  was rejected as EBADF. All supported relative `*at` paths now decode the
  signed 32-bit argument, preserving sign-extended AT_FDCWD and real directory
  descriptors. Core guests exercise both encodings, both rename endpoints,
  readlink/stat/access, invalid descriptors and file permission gating.
- Linux `umask` supports low-nine-bit masks, previous-mask returns and native
  file/directory creation. Core fixtures check masks 027 and 0, existing-file
  reopen modes and directory/file permissions on all three CPUs and compressed
  RISC-V. Teardown restores the original host-process mask. The one-guest-per-CLI
  model remains; concurrent embedding needs mask isolation.
- `gettimeofday` writes 64-bit seconds/microseconds and optional obsolete UTC
  timezone metadata. Both buffers are checked before writing. Legacy x86-64
  `time` supports its optional seconds pointer. `sysinfo` exposes the current
  guest mapped-memory limit/free budget, elapsed runtime uptime, one process,
  no swap and zero modeled load/shared/high-memory fields. Tests check mapping
  changes, exact layout, null pointers and page-crossing output faults.
- `utimensat(fd, NULL, times, 0)` now uses native futimens after translating
  the checked guest times array. Core tests verify explicit/now timestamps,
  unchanged files after bad time buffers/values, invalid flags and descriptors.
  `O_NONBLOCK` translates to the native open flag, allowing 7-Zip's directory
  scan instead of an EINVAL warning.
- `REP RET` (`F3 C3`) decodes through the existing near-return path. Unit tests
  check stack/PC effects for RCX 0/1/3 and unchanged flags/count; the x86 baseline
  guest exercises a real call/return in both engines. Unrelated unsupported
  repeat-prefix encodings are still rejected.
- `./scripts/check.sh` passes: **101/101 Zig tests**, core guest/JIT comparisons,
  the existing 112,422-query x87 calculation, 29,813-query x87 transfer and
  9,282-query SSE oracles per engine, site validation, 10,000 corpus mutations
  and 30,000 random decoder cases.
- Separate SQLite, BusyBox and dynamic musl checks on all three CPUs pass.
  The Debian/glibc probe still exits with its own CPU-baseline rejection and
  no engine fault. ReleaseSafe x86-64/AArch64 Linux GNU cross-builds pass;
  execution on Linux hosts remains unverified.
- README archive create/test/extract commands produce matching original bytes.
  The landing page and docs add the 7-Zip card, commands and explicit Windows
  boundary. Browser review checks desktop/mobile layouts and the landing
  command's actual copy-and-paste bytes. GitHub Actions remains disabled.

The official unchanged Windows x64 `7za.exe` from the same release was also
inspected and attempted with the existing fixture sysroot. It fails with
`WindowsDLLNotFound`: its OLEAUT32, USER32, ADVAPI32, msvcrt and additional
KERNEL32 imports exceed current support. No DLL substitutes or patched guest
were used. These Linux archive workflows do not establish Windows app or GUI
compatibility. 7-Zip runs one guest thread (`-mmt=off`); encrypted archives,
other codecs and large workloads remain outside this check. The broader
compatibility goal continues, with no new external execution dependency.

## Current main: own OLEAUT32 strings and variants

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **102/102 Zig tests**, rebuilt core guests,
  interpreter/JIT integration, the existing SSE/x87 independent oracles, site
  validation, 10,000 corpus mutations and 30,000 random decoder cases. Both new
  Automation PE executables are included in the mutation corpus.
- SDK-declared Windows x64 guests import seven OLEAUT32 APIs by name and through
  a NONAME ordinal import library. The PE checks independently verify both
  tables and that only KERNEL32/OLEAUT32 are imported: no CRT or vendor DLL.
  Both engines verify BSTR byte counts, embedded NUL/surrogate preservation,
  empty/null strings, multi-page data, string cloning/freeing, self-copy,
  25 scalar/by-reference types, invalid types and unsupported owning resources.
- Distinct built-in DLL handles/exports are used by startup imports,
  LoadLibrary, GetModuleHandle, GetProcAddress and named/ordinal guest DLL
  forwarders. Wrong DLL namespaces, case-sensitive API names and unknown
  ordinals fail explicitly. Ordinary missing LoadLibrary probes stay silent;
  import-DLL diagnostics are enabled by `--syscalls`.
- A checked-memory unit regression verifies invalid source/destination buffers
  before ordinary ownership changes, allocation failure cleanup, released
  mappings, double-free rejection and isolation from HeapFree/VirtualFree.
  Owning COM objects, arrays and records return E_NOTIMPL without mutation.
- The unchanged official Windows `7za.exe` hash is still
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Its six OLEAUT32 ordinal imports now bind. A fresh `--syscalls` probe reaches
  USER32 and exits 125 (`WindowsDLLNotFound`); the Windows app does not execute.
  USER32, ADVAPI32, msvcrt and more KERNEL32/exception behavior remain ahead.
- The unchanged Linux jq/ripgrep/7-Zip suite still passes **62/62 workflows**.
  ReleaseSafe x86-64/AArch64 Linux GNU cross-builds pass; Linux-host execution
  and native Windows differential testing remain unverified.
- README and site document the new API subset and the actual Windows boundary.
  Browser review checks the docs at 1280/390 pixels, the mobile compatibility
  row, no page overflow, command text and copy feedback. This check does not
  assert the operating-system clipboard contents.

No external execution runtime or vendor Windows DLL was added. GitHub Actions
CI stays disabled; the broader compatibility objective continues.

## Current main: own USER32 text APIs

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **103/103 Zig tests**, rebuilt core guests,
  interpreter/JIT integration, the existing SSE/x87 independent oracles, site
  checks, 10,000 corpus mutations and 30,000 random decoder cases. The new
  USER32 PE guest is included in the mutation corpus.
- The SDK-declared guest exercises CharUpperW's character/pointer forms,
  full-width guest addresses, mixed scripts, surrogate preservation, empty
  strings and DLL export isolation in both engines. CharPrevExA checks all
  255 nonzero bytes for each of five DBCS code pages against independently
  recorded metadata bitmaps, ambiguous lead/trail sequences and byte navigation
  for UTF-8/GB18030. Reserved flags and cursors beyond NUL fail explicitly.
- A checked-memory regression verifies cross-page read/write permissions,
  unmapped strings/cursors, address overflow and unchanged string bytes on
  failed destination validation.
- `tests/windows-text.py` compares **131,072 scalar/string results per engine**
  against pinned original Unicode 17.0.0 data. The generated 1,198 BMP mappings
  in 192 ranges reproduce that source exactly. Supplementary casing and native
  Windows NLS version parity remain unverified.
- The unchanged official Windows 7-Zip executable retains its recorded hash.
  OLEAUT32 and USER32 imports now bind; ADVAPI32 stops the loader with
  `WindowsDLLNotFound` (exit 125). The Windows application still does not execute.
- The unchanged Linux jq/ripgrep/7-Zip suite still passes **62/62 workflows**.
- ReleaseSafe x86-64/AArch64 Linux GNU cross-builds pass; Linux-host execution
  remains unverified. Browser review checks docs and the landing compatibility
  row at 1280/390 pixels, no page overflow, command text and copy feedback.
  This check does not assert operating-system clipboard contents.

The runtime uses bundled case data and its own API implementations; no external
execution runtime or vendor Windows DLL was added. GitHub Actions stays disabled.

## Current main: own ADVAPI32 process services

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **104/104 Zig tests**, rebuilt core guests,
  interpreter/JIT integration, the existing SSE/x87 independent oracles, site
  checks, 10,000 corpus mutations and 30,000 random decoder cases. The new
  security PE guest is included in the mutation corpus.
- The SDK-declared guest calls all nine named ADVAPI32 imports without a vendor
  DLL or CRT, in both engines and with/without the file grant. It verifies
  36 privilege-name LUIDs, generic token access rights, 64-handle exhaustion and
  reuse, stale handles, adjustment result/error codes and output-buffer sizes.
  The virtual token has no assigned Windows privileges; no host rights are granted.
- Named and runtime-resolved entropy calls check an 8,196-byte high-address
  buffer, unchanged guard bytes, zero-length calls and distinct samples. This
  verifies buffer behavior and the host entropy route, not statistical certification.
- Five empty read-only registry roots pass null/empty opens, missing subkeys/
  values, direct LSTATUS returns, unchanged LastError/output data and errors for
  write access, invalid options/views and unsupported special roots.
- Traces verify file-security failure codes exactly: ERROR_ACCESS_DENIED without
  `--allow-files`, ERROR_NOT_SUPPORTED with it. These calls do not translate
  Windows ACLs or change host permissions.
- A checked-memory regression verifies token output faults before handle
  allocation, privilege input/output faults before normal result writes, count
  limits and unmapped/read-only entropy buffers before mutation.
- The unchanged official Windows 7-Zip hash remains
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  OLEAUT32, USER32 and all nine ADVAPI32 imports bind. The loader now reaches
  msvcrt and exits 125 (`WindowsDLLNotFound`); the Windows app still does not execute.
- The unchanged Linux jq/ripgrep/7-Zip suite still passes **62/62 workflows**.
- ReleaseSafe x86-64/AArch64 Linux GNU cross-builds pass; Linux-host execution
  and native Windows differential testing remain unverified. Browser review
  checks docs/compatibility rows at 1280/390 pixels, no page overflow, three
  fixture commands and copy feedback, without asserting OS clipboard contents.

No external execution runtime or vendor Windows DLL was added. Local checks
remain the CI path; the broader compatibility objective continues.


## Current main: own legacy MSVCRT subset

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **106/106 Zig tests**, rebuilt core guests,
  interpreter/JIT integration, the existing independent SSE/x87 oracles,
  site checks, 10,000 corpus mutations and 30,000 random decoder cases.
  The CRT PE guest is included in the mutation corpus. A subsequent unit run
  also checks DLL callers cannot register process-scoped `_onexit` callbacks.
- The SDK-declared CRT guest links only an import library containing symbol
  declarations. Compile-time assertions verify the legacy 48-byte FILE ABI;
  PE metadata checks KERNEL32/MSVCRT-only imports including all four real data
  exports. No vendor CRT DLL or external execution runtime is used.
- Both engines, with/without the file grant, verify original empty/quoted/
  backslash/Unicode argv, NULL argv/env terminators, writable data exports,
  CRT errno versus Windows LastError, alignment and allocation-failure
  preservation, calloc overflow, realloc/free ownership, 9,000-byte overlapping
  copies across chunks, unsigned comparisons and UTF-16 string search.
- Exact byte checks cover text CRLF and Ctrl-Z, all 256 binary byte values
  repeated 40 times, and a 9,000-byte translated fputs spanning output chunks.
  EOF/error flags, descriptor/mode failures and `_beginthreadex`'s explicit
  no-thread result are checked without fabricating thread handles or IDs.
- Guest initializers execute in table order, skip NULLs and call nested
  initializer tables. Caller-owned `__dllonexit` tables remain separate.
  Process exit handlers run in LIFO order, including a newly registered handler.
  `_cexit` returns with guest streams closed, normal exit returns status 42
  after callbacks, and quick `_exit` returns 43 without callbacks.
- Wildcards, nonzero startup newmode, exception and RTTI invocation stop with
  their explicit errors. These recognized entries are not exception/RTTI support.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines bind all 39 MSVCRT imports, then stop at `KERNEL32!ResumeThread`
  during import binding (exit 125). The executable entry has not run.
- The unchanged Linux jq/ripgrep/7-Zip suite passes **62/62 workflows**.
  ReleaseSafe Linux x86-64/AArch64 GNU cross-builds pass; Linux-host execution
  and native Windows differential testing remain unverified.
- Browser review checks docs and the landing compatibility row at 1280/390
  pixels, readable CRT commands, no page overflow and copy feedback. It does
  not assert operating-system clipboard contents.

GitHub Actions remains disabled. The v0.1.0 bundle predates these changes;
current source and the broader compatibility objective continue.


## Current main: own single-thread Win32 synchronization

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **109/109 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, independent SSE/x87 oracles, site checks,
  10,000 corpus mutations and 30,000 random decoder cases. The new sync PE
  guest is included in the mutation corpus.
- The SDK-only guest uses our own KERNEL32 APIs without a vendor DLL or CRT.
  Both engines, with/without the file grant, verify manual/auto-reset events,
  shared Unicode named objects and handle lifetimes, access masks, semaphore
  counts/overflow, wait-any index selection, wait-all consumption and failure
  preservation, recursive critical sections and 1,100 create/close reuse cycles.
- Finite waits honor a 40 ms interval, checked by both the guest clock and
  Python's independent monotonic clock. INFINITE and 1,000 ms waits stop at
  the runtime's 30 ms execution deadline without returning a fabricated result.
  Uninitialized critical-section use stops with its explicit runtime error.
- Unit regressions verify whole-output and handle-array validation before
  state changes, read-only/unmapped faults, 1,024-handle exhaustion without
  leaking references/IDs, token-handle separation and stale-handle rejection.
- Identity, one-CPU affinity and monotonic clock APIs pass SDK checks.
  ResumeThread only accepts the existing, never-suspended current thread;
  `_beginthreadex` still creates no thread. GetVersion is declared virtual
  compatibility metadata; native Windows differential behavior is unverified.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines now bind the synchronization/identity imports, then stop at
  `KERNEL32!MoveFileW` during import binding (exit 125). Its entry has not run.
- The unchanged Linux jq/ripgrep/7-Zip suite still passes **62/62 workflows**.
  ReleaseSafe Linux x86-64/AArch64 GNU cross-builds pass; Linux-host execution
  remains unverified.
- Browser review checks the docs fixture block and landing compatibility row
  at 1280/390 pixels: five readable Windows commands, copy feedback and no
  page overflow. Operating-system clipboard contents were not asserted.

Global IPC, handle inheritance, contended scheduling and guest thread creation
remain unsupported. GitHub Actions stays disabled; local checks are the CI path.
The v0.1.0 bundle predates this work and the broader compatibility goal continues.


## Current main: own Win32 file mutations and metadata

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **111/111 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, independent SSE/x87 oracles, site checks,
  10,000 corpus mutations and 30,000 random decoder cases. The new SDK-only
  file-operation PE guest is included in the mutation corpus.
- Both engines run file-operation checks with relative paths and sysroot-prefixed
  absolute paths, confined by the test's isolated temporary-directory setup.
  Denied-access runs leave that directory unchanged; this is test isolation,
  not a claim that the runtime's sysroot is a sandbox.
- SDK checks verify atomic no-overwrite collisions, regular-file replacement,
  directory moves, nonempty/wrong-type errors, actual hard links, sharing errors,
  read-only mapping, unsupported flags/callbacks and large-file DWORD sentinels.
  Sparse seeks/sizes pass at 0xffffffff and above 4 GiB, then truncate to eight
  bytes; failed negative/overflow seeks preserve the current position.
- Shared deletion stays pending until final close, denies new opens and survives
  a parent directory rename. Process termination closes and deletes a pending
  file. Symlink deletion preserves its independently seeded target.
- Python independently verifies final file bytes, directory contents, size,
  inode/device identity, link count and mtime/birthtime against host stat data.
  FILETIME conversions use the 1601 epoch and truncate sub-100 ns values.
- Unit regressions check full metadata/high-output buffers before writes/seeks,
  read-only access before truncation, and preservation of a different host inode
  placed at the retained pending-delete name. These checks do not remove every
  host pathname race or establish native Windows filesystem/ACL parity.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines bind MoveFileW, then stop at `KERNEL32!LocalFileTimeToFileTime`
  during import binding (exit 125). Its entry still has not run.
- The unchanged Linux jq/ripgrep/7-Zip suite passes **62/62 workflows**.
  ReleaseSafe Linux x86-64/AArch64 GNU cross-builds pass. Linux-host execution,
  native Windows differential testing and cross-volume moves remain unverified.
- Browser review at 1280/390 pixels verifies six readable Windows commands,
  copy feedback, updated compatibility rows and no page overflow. It does not
  assert operating-system clipboard contents.

No vendor Windows DLL or external execution runtime was added. Cross-volume
copy/delete, progress callbacks and broader attributes still require work.
GitHub Actions remains disabled; the compatibility goal continues on current
source and v0.1.0 predates this checkpoint.

## Current main: own Win32 calendar, clocks and file times

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **113/113 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, existing SSE/x87 oracles, site checks,
  10,000 corpus mutations and 30,000 random decoder cases. The SDK-only
  time PE guest is included in the mutation corpus.
- The independent Python oracle checks **194,482 conversion cases per engine**:
  30,889 SYSTEMTIMEs, 32,521 FILETIMEs and 131,072 DOS records. It covers every
  input year 1601..30827, leap-century/month boundaries, ignored weekdays,
  millisecond truncation, high-bit failures, unchanged invalid outputs,
  every 16-bit DOS date word with one fixed time and every DOS time word with
  one valid leap date. It does not test the full DOS date/time cross-product.
- Real-clock probes bracket outputs with host wall time and check virtual
  process creation/live exit and nondecreasing host CPU durations. Legacy
  local/UTC roundtrips preserve 100 ns fractions. Five zone environments cover
  the host default, UTC, +14 hours, -12 hours and current New York DST.
  An input from January 1970 still uses the current offset.
- SDK checks verify explicit attribute-only handles, denied read-handle updates,
  null/zero omission, creation/high-bit rejection and per-handle access/write
  suppression across actual reads, writes and truncation. A second handle's
  later timestamp update survives suppressed I/O. Python independently verifies
  final bytes and birth/access/write times against macOS stat results.
- Unit regressions validate all process/file/DOS outputs before partial writes,
  and every SetFileTime input before changing host timestamps or handle flags.
  macOS birth-time updates pass; Linux creation-time updates explicitly fail
  before applying other fields, but Linux-host execution remains unverified.
- The unchanged Linux jq/ripgrep/7-Zip suite passes **62/62 workflows**.
  ReleaseSafe Linux x86-64/AArch64 GNU cross-builds pass.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines now bind LocalFileTimeToFileTime and stop at
  `KERNEL32!SetConsoleMode` during import binding (exit 125, no stdout).
  Its entry still has not run.
- Browser review at 1280/390 pixels verifies seven readable Windows commands,
  copy feedback, updated compatibility rows and no page overflow. It does not
  assert operating-system clipboard contents.

No vendor Windows DLL or external execution runtime was added. Native Windows
timezone/filesystem parity, historical Windows zone rules, directory file-time
handles and broader console APIs remain unverified or unimplemented. Host
timestamp restoration is not atomic against concurrent external writes.
GitHub Actions remains disabled. The compatibility goal continues on current
source; v0.1.0 predates this checkpoint.

## Current main: own Win32 terminal input and control callbacks

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **115/115 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, existing calendar/SSE/x87 oracles, site checks,
  10,000 corpus mutations and 30,000 random decoder cases. The SDK-only console
  PE guest is included in the mutation corpus.
- Independent Python tests use real pipes and isolated PTYs. They verify
  actual termios processed/line/echo flags, a raw one-byte read without newline,
  cooked line blocking without echo, unsupported modes, unchanged outputs and
  every saved input attribute after normal exit. Handled guest-fault cleanup
  matches an independent direct native raw-to-canonical restoration, including
  Darwin's kernel PENDIN rescan flag.
- Real SIGINT/SIGQUIT exercise LIFO guest callbacks, removal, duplicate
  registrations, ignored Ctrl+C with delivered break, pending event-wait
  restoration, default exit and a third-interrupt handler returning FALSE.
  Blocking ReadFile interrupts with zero bytes/ERROR_OPERATION_ABORTED;
  ignored Ctrl+C leaves the read pending until real input arrives.
- Unit checks reject nonexecutable handlers before registration/hook changes,
  enforce the 64-registration and one-owner limits, validate callback return
  stacks, restore all CPU state, LastError/TEB and pending waits, preserve
  monotonic instruction accounting and restore native signal dispositions.
- The PTY tests exposed an existing Darwin stat panic on signed device IDs.
  The shared stat conversion now preserves their native widened bit patterns;
  a regression covers negative device and character-device identifiers.
- SDK checks cover host stream types, closed handles, UTF-8-only console code
  pages and queryable ANSI/OEM file-policy state. Output modes and screen-buffer
  queries return explicit unsupported/invalid-handle errors.
- The unchanged Linux jq/ripgrep/7-Zip suite passes **62/62 workflows**.
  ReleaseSafe Linux x86-64/AArch64 GNU cross-builds pass; runtime execution on
  Linux hosts remains unverified.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Console imports now bind in both engines. The next boundary is
  `KERNEL32!UnmapViewOfFile` during import binding (exit 125, no stdout).
  The application's entry still has not run.
- Browser review at 1280/390 pixels verifies eight readable Windows commands,
  copy feedback, the updated mobile compatibility row and no page overflow.
  It does not assert operating-system clipboard contents.

No vendor Windows DLL or external execution runtime was added. Control callbacks
run serially on the initial guest thread with its TLS; native Windows' separate
handler thread, full console output rendering and native differential behavior
remain unimplemented or unverified. Signals coalesce per type. Cooked input
uses native terminal editing/LF endings. Cleanup covers normal exits and handled
guest faults, not abrupt native process termination. GitHub Actions remains
disabled; local checks are the CI path. v0.1.0 predates this checkpoint.

## Current main: own Win32 file sections and mapped views

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **118/118 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, calendar/console/SSE/x87 oracles, site checks,
  10,000 corpus mutations and 30,000 random decoder cases. The SDK-only mapping
  PE guest is included in the mutation corpus.
- SDK guests verify zero-filled paging sections, coherent overlapping views,
  case-sensitive shared object names, Local prefixes, rights and alignment,
  invalid ranges/bases, fixed views, cross-type name collisions and independent
  handle/view lifetimes. Views retain a named object after all handles close;
  the final unmap releases its name.
- Guest-page COW checks detach only written 4 KiB pages, including a write
  crossing two pages on a 16 KiB host. Unwritten pages still see shared updates;
  private bytes remain isolated. Executable paging aliases return new values
  after shared code changes in both engines; COW code stays private.
- Independent Python checks use a real **4 GiB + 65,537 byte sparse file**.
  They compare original/changed bytes, a partial flush observed before unmap,
  pending dirty pages, hardlink inode/link counts, no COW writeback and final
  bytes. Shared views from different section objects and hardlink handles see
  identical changes. The file remains sparse, with under 1 MiB allocated.
- The original file/section handles close before remaining views. Section
  objects block SetEndOfFile and truncating opens. Pending deletion retains
  the original pathname until the final object/view reference; the hardlink
  still contains the flushed bytes afterward. Handled guest-fault cleanup
  flushes shared file changes; read-only view writes produce checked faults.
- Unit checks inject every section/view/COW allocation failure, validate all
  SYSTEM_INFO outputs before writing and reject mapping bounds/memory-limit
  failures without adding views, references or advancing allocation state.
  Integration exposed a cleanup use-after-free in section metadata; cleanup
  now resets the collection before pending deletion checks. A regression
  verifies the emptied metadata remains safe to query and clean again.
- The unchanged Linux jq/ripgrep/7-Zip suite passes **62/62 workflows**.
  ReleaseSafe Linux x86-64/AArch64 GNU cross-builds pass with isolated output
  prefixes; native runtime execution on Linux hosts remains unverified.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines now bind mapping imports and stop at
  `KERNEL32!IsProcessorFeaturePresent` during import binding, before entry.
  The Windows application still does not execute.
- Browser review at 1280/390 pixels verifies nine Windows commands, copy
  feedback, the updated mobile compatibility row and no page overflow.
  Operating-system clipboard contents are not asserted.

The runtime owns cached section pages in private unlinked backing files and
executes guest code through its CPU engine. No vendor Windows DLL or external
execution runtime was added. External file/ReadFile/WriteFile changes are not
synchronized with cached views. Unmap/exit writeback is eager; hardware
durability, native Windows cache/security parity, file execute rights, image,
reserve/large-page flags, inherited handles and global IPC remain absent or
unverified. Native termination cannot guarantee writeback. GitHub Actions
remains disabled. The compatibility goal continues; v0.1.0 predates this work.

## Current main: virtual Windows processor and memory queries

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **120/120 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, calendar/console/mapping/SSE/x87 oracles,
  site checks, 10,000 corpus mutations and 30,000 random decoder cases.
- The SDK-only mapping guest queries processor features 0 through 63 and an
  unknown DWORD, preserving LastError. CX8, MMX, RDTSC and CX16 agree with guest
  CPUID; PAE/NX describe the virtual AMD64 address/execute model. Incomplete
  SSE/SSE2, AVX, ARM and unknown capabilities remain unadvertised.
- The same unchanged fixture checks the 64-byte MEMORYSTATUSEX layout, invalid
  length without buffer mutation, the 256 MiB guest budget, commit/address-space
  fields and exact 69,632-byte availability changes for a rounded 65,537-byte
  allocation. Freeing restores the previous totals in both engines.
- Unit checks validate all output bytes before writing, preserve cross-page
  read-only outputs, exercise exhausted-budget reporting and exclude mappings
  below 64 KiB from the reported user address-space occupation. DWORD processor
  input ignores high register bits; processor/memory success preserves LastError.
- The unchanged Linux jq/ripgrep/7-Zip suite passes **62/62 workflows**.
- Official Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines now bind IsProcessorFeaturePresent and GlobalMemoryStatusEx,
  then stop at `KERNEL32!GetDiskFreeSpaceExW` (exit 125) before guest entry.
  No successful Windows 7-Zip execution is claimed.
- Desktop/mobile browser review at 1280/390 pixels verifies the updated
  compatibility row, current import boundary, nine Windows commands and no
  horizontal page overflow. Static checks verify two pages, 36 local URLs,
  SVG assets and five real guest outputs; JavaScript syntax also passes.

Memory numbers describe the checked runtime budget and mapped bytes, including
shared aliases, rather than host physical RAM. There is no additional guest
swap pool; available totals do not guarantee a contiguous allocation or bypass
the region limit/native allocation failures. No external execution runtime or
vendor Windows DLL was added. GitHub Actions remains disabled and validation
runs locally. The compatibility goal continues; v0.1.0 predates these APIs.

## Current main: Win32 disk capacity and allocation geometry

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **121/121 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, calendar/console/mapping/disk/SSE/x87 oracles,
  site checks, 10,000 corpus mutations and 30,000 random decoder cases.
- The SDK-only file-operation guest queries current, Unicode-directory and
  directory-symlink volumes. Python compares 12 returned records across both
  engines and relative/sysroot paths: exact native total capacity above 4 GiB,
  allocation-unit geometry and saturated DWORD counts. Free bytes/clusters
  must lie between surrounding native snapshots with a 1 MiB allowance for
  concurrent host I/O; they are not asserted as immutable values.
- Every combination of optional extended outputs succeeds and preserves
  LastError. Failed regular-file paths preserve all output sentinels; missing
  and empty directories, unsupported DOS/UNC paths, denied file grants and
  null required output faults are checked. Directory symlinks are followed.
- Unit checks use more than 2^32 clusters to verify 64-bit byte totals and
  DWORD saturation. Unsupported geometry, zero units, invalid counts and
  multiplication overflow fail explicitly. Cross-page read-only outputs and
  unmapped fifth stack arguments leave earlier destinations untouched.
- The unchanged Linux jq/ripgrep/7-Zip suite passes **62/62 workflows** on rerun.
  Its first run reached a 30-second timeout in the final denied-access 7-Zip
  JIT case. Isolated checks complete with exit 2 and the expected permission
  error in about 5.95 seconds interpreted and 9.49 seconds with JIT, retiring
  28,924,452 instructions. The test runner now allows 60 seconds for 7-Zip
  (70-second outer deadline); other apps keep 30 seconds. The 30-million
  instruction limit, exact output/status checks and all data assertions remain.
- The host adapter uses Darwin statfs's 64-bit counters instead of its narrow
  statvfs block-count ABI. Linux uses statvfs's allocation unit. ReleaseSafe
  Linux x86-64/AArch64 GNU builds pass with isolated output directories;
  execution on Linux hosts remains unverified. The native macOS runtime stays
  ARM64 and is not replaced by a cross-build.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines bind the disk-space imports, then stop at
  `KERNEL32!MultiByteToWideChar` (exit 125) before guest entry. The Windows
  application still does not execute.
- Desktop/mobile browser review at 1280/390 pixels verifies the current
  import boundary, nine Windows commands and the new compatibility row without
  horizontal overflow. Static checks verify two pages, 36 local URLs, SVGs
  and five real guest outputs; JavaScript syntax passes.

Disk values describe the host volume and available-user block counts. They do
not implement Windows drive namespaces, quotas or physical sector geometry;
legacy counts saturate and available space is volatile. Native Windows
filesystem parity remains unverified. File access requires an explicit grant.
No vendor Windows DLL or external execution runtime was added. GitHub Actions
remains disabled and validation runs locally. The compatibility goal continues;
v0.1.0 predates these APIs.

## Current main: checked Win32 UTF-8 and UTF-16 conversion

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **124/124 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, calendar/console/mapping/disk/encoding/SSE/x87
  oracles, site checks, 10,000 corpus mutations and 30,000 random decoder cases.
- The SDK-only encoding guest matches Python's independent codecs for every
  **1,112,064 valid Unicode scalar** in both directions and both engines,
  including embedded NULs, noncharacters and supplementary planes. Bulk length
  queries report the same required output sizes without accessing destinations.
- **16,557 additional cases per engine** check malformed UTF-8 prefixes and
  UTF-16 surrogates, strict errors versus U+FFFD replacement, signed counts,
  explicit/terminated input, short buffers, code-page aliases, invalid flags,
  null/identical pointers, optional default pointers and unchanged guard bytes.
  Short-buffer output contains only complete Unicode scalars; this prefix
  policy has not been compared with native Windows.
- Unit checks exercise DWORD truncation, unreadable eighth stack arguments,
  cross-page read-only outputs, unreadable/unterminated sources, address overflow
  and memory-limit errors. Failure injection at every temporary allocation
  preserves output and releases owned buffers. Successful APIs preserve LastError.
- The unchanged Linux jq/ripgrep/7-Zip suite passes **62/62 workflows**.
  ReleaseSafe GNU Linux x86-64 and AArch64 cross-builds pass with isolated
  prefixes; execution on Linux hosts remains unverified. The native macOS
  runtime remains ARM64.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines bind MultiByteToWideChar and WideCharToMultiByte, then stop at
  `KERNEL32!GetModuleFileNameW` (exit 125) before guest entry. The Windows
  application still does not execute.
- Desktop/mobile browser review at 1280/390 pixels verifies the current
  import boundary, ten Windows commands, copy feedback and the updated home
  compatibility row without horizontal page overflow. Operating-system
  clipboard contents are not asserted. Static checks verify two pages,
  36 local URLs, SVG assets and five real guest outputs.

The UTF-8-only ANSI/OEM profile remains explicit. Other code pages, broader
Windows NLS behavior and native Windows differential validation are absent.
Temporary input and converted output are bounded by the guest memory limit;
guest addresses are read and written through the checked memory model.
No vendor Windows DLL or external execution runtime was added. GitHub Actions
remains disabled and validation runs locally. The compatibility goal continues;
v0.1.0 predates these APIs.

## Current main: retained PE paths and checked module filename queries

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **126/126 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, calendar/console/mapping/disk/encoding/module
  and SSE/x87 oracles, site checks, 10,000 corpus mutations and 30,000 decoder
  cases. Existing cyclic DLL, failed-attach rollback, unload/reload and TLS
  checks pass with the new path ownership.
- The SDK-only module guest matches Python's independently encoded host load
  paths in **3,781 byte/unit capacity cases per engine** on this host. Cases
  cover every capacity from zero through the full path plus two units, UTF-8
  and UTF-16 output, exact lengths, NUL truncation, LastError and guard bytes.
  The count depends on the temporary directory and resulting path lengths.
- Relative/absolute names, Unicode and mixed-case DLL filenames, paths longer
  than 260 UTF-16 units and a host symlink followed by `..` retain their actual
  load spelling. Null/main handles agree. Invalid/unloaded handles and virtual
  built-in API modules fail explicitly, preserving output sentinels.
- A host handshake renames the executable and loaded DLL before both filename
  queries. Stored paths still match the original load names, proving the API
  does not reopen those files. Unload and a different DLL in a reused loader
  slot report the appropriate lifetime and new path.
- Unit failure injection covers owned path metadata, A/W output buffers and
  guest copy-on-write pages across a page boundary. Backing allocation failures
  return ERROR_NOT_ENOUGH_MEMORY without changing output bytes or shared backing.
  Rollback, inactive-slot reuse, DWORD size truncation and cross-page read-only
  outputs are checked. SDK output into unmapped memory stops with exit 125 in
  both engines; faults and allocation failures preserve destination bytes.
- ReleaseSafe GNU Linux x86-64 and AArch64 cross-builds pass with isolated
  prefixes. The native macOS runtime remains ARM64; execution on Linux hosts
  remains unverified.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines bind GetModuleFileNameW, then stop at `KERNEL32!LocalFree`
  (exit 125) before guest entry. Windows 7-Zip still does not execute.
- Desktop/mobile browser review at 1280/390 pixels verifies the current import
  boundary, eleven Windows commands, copy feedback and the updated mobile
  compatibility row without horizontal page overflow. Operating-system
  clipboard contents are not asserted. Static checks verify two pages,
  36 local URLs, SVG assets and five real guest outputs.

Module paths describe the host load spelling, not a fabricated Windows drive
or vendor DLL location. Built-in API modules have no loaded file. Byte/unit
truncation may split a Unicode encoding sequence. DOS/UNC paths, data-file
module loading and native Windows path/search parity remain absent or
unverified. No vendor Windows DLL or external execution runtime was added.
GitHub Actions remains disabled and validation runs locally. The compatibility
goal continues; v0.1.0 predates this work.

## Current main: checked local memory and movable handle lifetimes

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **128/128 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, calendar/console/mapping/disk/encoding/module/local
  and SSE/x87 oracles, site checks, 10,000 corpus mutations and 30,000 decoder
  cases. The local-memory executable is built from SDK declarations and included
  in the normal local check and mutation seeds.
- The SDK guest and Python compare **84 complete resize/zero-fill byte sequences
  per engine**: fixed/movable objects, zero and page-boundary sizes, growth,
  shrink, discard and subsequent allocation through the same movable handle.
  Movable sequences grow while unlocked without LMEM_MOVEABLE. Fixed/locked
  relocation, lock-count preservation, MODIFY ignoring size, foreign ownership,
  stale handles, LastError and checked use-after-free faults also pass.
- Unit failure injection covers allocation metadata, private backing, relocation
  and in-place zero filling, including guest copy-on-write backing failures.
  Failed growth preserves the original logical size, handle, locks and bytes;
  failed allocation publishes no handle or mapping. Budget exhaustion, invalid
  flags, UINT truncation, 255-lock overflow and 1,024 allocation entries are checked.
  The final extra unlocked-growth regression passes 128 tests and both SDK
  byte-sequence oracles after the full local check.
- ReleaseSafe GNU Linux x86-64 and AArch64 cross-builds pass with isolated
  prefixes; the native runtime remains Mach-O ARM64. Linux-host execution is
  still unverified. Optional downloaded Linux app workflows were not rerun for
  these Windows-only changes; their earlier 62-workflow evidence remains separate.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines bind LocalFree and stop at `KERNEL32!FormatMessageW` (exit 125)
  during import binding, before guest entry. Windows 7-Zip still does not execute.
- Desktop/mobile browser review at 1280/390 pixels verifies the new boundary,
  twelve Windows commands, copy feedback and the updated mobile compatibility
  row without horizontal page overflow. Clipboard contents are not asserted.
  Static checks verify two pages, 36 local URLs, SVG assets and five real outputs.

The local-memory profile uses checked page mappings, logical sizes, separate
movable handles, bounded locks and explicit errors. It does not compact the heap,
convert allocation forms or implement GlobalAlloc. Locked discard and zero-size
fixed behavior are documented profile choices; native Windows differential
validation remains absent. No vendor DLL or external execution runtime was
added. GitHub Actions remains disabled; validation runs locally. The compatibility
goal continues; v0.1.0 predates these APIs.

## Current main: checked message formatting and allocated diagnostics

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **130/130 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, calendar/console/mapping/disk/encoding/module/local/
  message and SSE/x87 oracles, site checks, 10,000 corpus mutations and 30,000
  decoder cases. The SDK-only message guest is included in local validation
  and PE mutation seeds.
- Native snprintf and independent Python text/UTF-16 oracles compare **1,428
  exact byte cases per engine**. Cases cover integer widths, signed extremes,
  alternate forms, padding/precision, reordered inserts, raw wide characters,
  strict UTF-8 strings, word wrapping, guarded capacities, allocation minimums,
  errors and the 65,535-unit output ceiling. Native numeric comparisons use fixed
  C specifications, not guest templates; they do not prove native Windows
  FormatMessage parity.
- Actual SDK variadic and argument-array calls pass, including the documented
  dynamic-array example, argument 99, repeated/reordered inserts and checked
  source, argument and output faults in both engines. Precision reads at page
  ends and zero precision pass after fixing the shared narrow-string reader to
  stop at the requested limit without reading a following terminator.
- Unit failure injection covers temporary string/output buffers and allocated
  backing, including cross-page copy-on-write pointer outputs. Failure preserves
  caller bytes and shared backing and reclaims unpublished local allocations.
  Successful allocated results are owned by LocalFree; LastError is preserved.
- ReleaseSafe GNU Linux x86-64 and AArch64 cross-builds pass with isolated
  prefixes; the native runtime remains Mach-O ARM64. Linux-host execution is
  unverified. Optional downloaded Linux workflows were not rerun for these
  Windows-only changes; the earlier 62-workflow evidence remains separate.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines bind FormatMessageW and stop at `KERNEL32!SetCurrentDirectoryW`
  (exit 125) during import binding, before entry. Windows 7-Zip still does not run.
- Desktop/mobile browser review at 1280/390 pixels verifies the new boundary,
  thirteen Windows commands, copy feedback and the updated compatibility row
  without horizontal page overflow. Clipboard contents are not asserted.
  Static checks verify two pages, 36 local URLs, SVG assets and five real outputs.

The independent English catalog uses our own wording. Module message resources,
broad localization, floating-point inserts, va_list dynamic-field caching and
FormatMessageA remain unsupported. Native Windows differential validation is
absent. No vendor DLL or external execution runtime was added. GitHub Actions
remains disabled and validation runs locally. The compatibility goal continues;
v0.1.0 predates this work.

## Current main: current directories and explicit temporary paths

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes **132/132 Zig tests**, rebuilt core/Mach-O guests,
  interpreter/JIT integration, calendar/console/mapping/disk/encoding/module/local/
  message/directory and SSE/x87 oracles, site checks, 10,000 corpus mutations and
  30,000 decoder cases. The SDK-only directory guest is included in the local
  check and PE mutation seeds.
- SDK guests and Python compare **5,613 exact directory capacity/state cases per
  engine** on this host. Every UTF-16 capacity is checked across physical Unicode
  paths, paths longer than 260 units, symlink/.. traversal and no/absolute/relative/
  symlink sysroots. Queried paths can be reused; subsequent relative writes match
  actual host file bytes. Missing/non-directory/invalid inputs preserve directory
  state. Removal and moves of the current directory itself fail explicitly.
- Guest DLLs load, attach, execute exported machine code and unload after directory
  changes, using the anchored original root. These DLLs are built from checked-in
  source, not vendor Windows DLLs. Existing module lifetime/path and file-operation
  integration checks also pass.
- Temporary-path checks compare **2,948 exact UTF-16 capacity/environment cases
  per engine**: explicit TMP/TEMP/USERPROFILE precedence, case/duplicates/empty
  values, relative qualification, normalized dot components, retained symlink
  names, absent directories and the 32,767-unit profile limit. Controlled host
  environment values are not inherited. Other PE environment variables still
  fail explicitly; the CRT environment array remains empty.
- Unit failure injection covers path ownership, relative-root anchoring, UTF-16
  staging and cross-page copy-on-write outputs. Failures preserve caller bytes
  and shared backing; the original host working directory is restored during
  cleanup, including injected failures. DWORD capacity truncation, size-query
  pointers, null outputs, read-only boundaries and SDK unmapped faults pass.
- ReleaseSafe GNU Linux x86-64 and AArch64 cross-builds pass with isolated prefixes;
  the native runtime remains Mach-O ARM64. Linux-host execution is unverified.
  Optional downloaded Linux workflows were not rerun for these Windows changes;
  their earlier 62-workflow evidence remains separate.
- Unchanged Windows 7-Zip retains SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  Both engines bind SetCurrentDirectoryW, GetCurrentDirectoryW and GetTempPathW,
  then stop at `KERNEL32!FindClose` (exit 125) during import binding before entry.
  Windows 7-Zip still does not execute.
- Desktop/mobile browser review at 1280/390 pixels verifies the new boundary,
  fourteen Windows commands and the updated mobile compatibility row without
  horizontal page overflow. Copy feedback and exact browser clipboard contents
  match the complete fourteen-command block. Static checks verify two pages,
  36 local URLs, SVG assets and five real guest outputs.

These APIs use the process-wide POSIX working directory and restore it when the
runtime closes; embedded runtimes must run serially. Paths use the host-style
namespace and `/` separators, with a documented long-path profile. DOS/UNC
namespaces, host-wide Windows locks, ancestor locking and native Windows
differential behavior remain unsupported or unverified. Temporary paths do not
validate existence/access or inherit host values. No vendor DLL or external
execution runtime was added. GitHub Actions remains disabled and validation runs
locally. The compatibility goal continues; v0.1.0 predates these APIs.

## Current main: Linux guest pthread execution

Validated locally on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- `./scripts/check.sh` passes the Zig tests, rebuilt Linux/Windows/Mach-O
  integrations, CPU and SDK oracles, site checks, 10,000 corpus mutations and
  30,000 decoder cases. All three pthread executables are now mutation seeds.
- Actual musl pthread code passes on x86-64, AArch64 and RISC-V64 in interpreter
  and JIT modes: contended mutexes, a condition barrier, joins, distinct TLS,
  exact shared total 12,000, CPU-bound preemption, reused slots and timed waits.
  Native macOS compilation of the same POSIX source produces the same output;
  the guest-only UAPI checks catch swapped bitset wait/wake syscall opcodes.
- Integration checks an all-blocked process timeout and a global instruction
  limit reached after thread creation. Unit checks validate separate CPU/TLS
  state, clear-TID exits, masks/keys/deadlines and unchanged TID outputs on bad
  pointers or allocation failure. AArch64 acquire/release checks cover every
  width, zero registers, alignment, permissions and reservation behavior.

Guest contexts execute serially on one host thread. Robust owner-death recovery,
PI/requeue, cancellation, cross-process futexes, dynamic-library pthread TLS and
native Linux differential behavior remain unsupported or unverified. Blocking
host I/O stalls all guest threads. Windows and Mach-O thread creation remain
unsupported. See [linux-threads.md](linux-threads.md). GitHub Actions stays
disabled; these checks run locally.

## Current main: threaded public 7-Zip and Windows release extraction

- The optional Linux app suite passes **66/66 workflows**, 33 per engine,
  including 7z creation/extraction with `-mmt=2`. Text, binary, empty and nested
  members retain exact bytes and modification timestamps. Existing JSON/text,
  ZIP, archive hash and denied-access expectations still pass.
- The optional Windows 7-Zip suite also passes **34/34 workflows** on rerun,
  including application exit 2 and absent output files for denied read/write
  requests in both engines.
- Fresh interpreter extraction of the pinned `7z2603-extra.7z` release container
  produces exactly **1,335,296 bytes**, matching Windows executable SHA-256
  `edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
  The downloader now uses this path instead of system tar. A separate JIT
  extraction matches the same bytes at 332,659,005 guest instructions.
- The large-container command has its own 1.5-billion-instruction/300-second
  profile; smaller app regressions retain their original limits. Earlier
  100-million-instruction and 60-second probes reached those limits, rather
  than the previous unsupported clone fault. No runtime budget is reset when
  threads switch. Downloads are optional; core local CI stays network-free.

These are scoped CLI checks on macOS ARM64. Windows guest threads, arbitrary
archive codecs, broader applications and native Linux parity remain unverified
or unsupported. See [public-apps.md](public-apps.md) for pinned hashes and commands.

## Current main: scheduler-backed sleeps and threaded ripgrep

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- Full local CI passes **154/154 Zig tests**, rebuilt guest integrations, CPU/SDK
  oracles, site checks, 10,000 corpus mutations and 30,000 decoder cases.
- The pthread fixture adds sleeps that allow another guest to run, absolute
  CLOCK_MONOTONIC/CLOCK_REALTIME deadlines and unchanged successful-sleep
  remainder buffers. All three CPU architectures pass in interpreter/JIT modes.
  A two-second guest sleep faults at the configured 30 ms runtime deadline;
  elapsed host time stays below one second, detecting a blocking host-sleep
  implementation. Native macOS POSIX compilation matches all three output lines;
  the absolute clock and raw Linux ABI checks are guest-only.
- Unchanged ripgrep 15.2.0 now completes two-thread directory searches and file
  listings. The initial search stopped at syscall 230 after returning only some
  results. It now returns all 16 expected matches across eight directories.
  Trace evidence includes real clone, futex and clock_nanosleep calls.
  The complete optional Linux suite passes **70/70 workflows**, 35 per engine;
  the Windows 7-Zip suite also passes **34/34** on rerun.
- The unchanged Debian glibc probe still returns its own ISA-level rejection
  and exit 127. Its regression now checks the actual exit_group trace rather
  than the older combined exit name. No CPU feature override is introduced.

Only realtime/monotonic sleeps are implemented. Other clock IDs return explicit
errors; guest signal interruption, CPU-time clocks and restart semantics remain
unsupported. Timer waits cannot be woken as futexes. GitHub Actions stays
disabled, and all default CI checks remain local and network-free.

## Current main: exact x87 exponent/significand extraction

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- Full local CI passes **155/155 Zig tests**, rebuilt ELF/PE/Mach-O integrations,
  CPU/SDK oracles, site checks, 10,000 corpus mutations and 30,000 decoder cases.
- `FXTRACT` now executes through the common interpreter/JIT x87 path. Both
  outputs retain exact extended precision, including normalized denormals,
  signed zeros, infinities and quieted NaN payloads. Precision and rounding
  controls cannot alter its results; unmasked operand/stack faults preserve
  register data, tags and TOP before the next waiting instruction faults.
- The arithmetic guest adds two output views of the same instruction, keeping
  the binary query/answer format stable. Its independent Fraction/bit oracle
  adds **7,580 queries per engine**, for **120,002 total** over 79 decoded forms.
  It covers every denormal leading-bit position, exponent extremes, random
  significands, four precision-field settings, four rounding modes and
  masked/unmasked operand and stack exceptions. Unit checks exercise every TOP.
- The existing 29,813-query transfer and 9,282-query SSE suites still pass in
  both engines. The unchanged Debian loader probe still rejects its CPU
  baseline with guest exit 127; CPUID features remain conservative.

This is specification/mathematical validation on ARM64 macOS, without a native
x86 hardware differential run. Remainders, scaling, transcendental instructions
and legacy x87 environments remain unsupported. No external execution engine or
floating-point library is introduced. GitHub Actions stays disabled.

## Current main: exact x87 partial and complete remainders

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- Full local CI passes **156/156 Zig tests**, rebuilt ELF/PE/Mach-O integrations,
  CPU/SDK oracles, site checks, 10,000 corpus mutations and 30,000 decoder cases.
- `FPREM` truncates its quotient; `FPREM1` rounds it to nearest-even. Both
  produce exact 64-bit remainders regardless of precision/rounding control.
  Exponent gaps of 64 or more use our fixed, ISA-permitted 32-bit partial
  reduction and set C2. Complete reductions clear C2 and expose quotient bits.
- The independent Fraction oracle adds **12,256 queries per engine**, including
  single-step results, complete guest C2 loops, ties, signed operands/zeros,
  NaN/unsupported/empty operands, denormals and unmasked underflow. The total
  is **132,258 queries per engine** over 81 decoded forms. Guest loops cover
  the full extended exponent range and retain a 1,100-step convergence bound
  alongside the existing process-wide instruction/time limits.
- **648 bounded binary64 numeric cases** also agree with the native host
  `fmod`/`remainder` math library. This checks numeric results on ARM64;
  native x87 hardware, quotient flags and partial-reduction parity remain
  unverified. Unit checks exercise all eight TOP positions and deferred faults.
- A further unit regression pairs the maximum normal exponent with a five-unit
  subnormal modulus. Both instructions require more than 900 partial reductions
  before returning the exact nonzero signed residue and quotient bits. It also
  preserves the divisor and tags under 24-bit precision control. All 156 unit
  tests pass again after adding this case.
- Fresh checksum-verified public-app reruns pass **70/70 Linux workflows**
  and **34/34 Windows workflows** in interpreter/JIT modes. The unchanged
  Debian loader still rejects its CPU baseline and exits 127.

Scaling, transcendental instructions and legacy x87 environments remain
unsupported. CPU feature claims stay conservative. No external emulator or
floating-point library is introduced; GitHub Actions remains disabled.

## Current main: x87 power-of-two scaling and extraction reconstruction

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- Full local CI passes **157/157 Zig tests**, rebuilt ELF/PE/Mach-O integrations,
  CPU/SDK oracles, site checks, 10,000 corpus mutations and 30,000 decoder cases.
- `FSCALE` truncates ST(1) toward zero and scales ST(0) at full 64-bit
  significand precision, independent of precision control. Rounding control
  still governs gradual underflow and masked overflow. Unmasked results use
  the specified 24,576 exponent bias; massive overflow/underflow produces
  signed infinity/zero when the bias cannot bring the result into range.
- The independent Fraction/bit oracle adds **9,158 queries per engine**, for
  **141,416 total** over 82 decoded forms. It derives the full mathematical
  exponent rather than copying the runtime's bounded integer conversion.
  Cases include fractional and huge exponents, denormals, all precision-field
  settings and rounding modes, masked/unmasked faults and exact reconstruction
  with `FXTRACT; FSCALE; FSTP ST(1)`. Unit checks exercise every TOP position
  and preservation of ST(1), tags, control word, MXCSR and EFLAGS.
- **252 bounded binary64 scaling cases** agree with native host `ldexp`,
  alongside the existing **648 remainder comparisons**. Exponent extremes
  and reconstruction use exact mathematical/bit checks. Native x87 hardware
  results and condition-flag parity remain unverified on this ARM64 host.
- The unchanged 29,813-query x87 transfer and 9,282-query SSE suites pass in
  both engines. The fresh Windows public-app rerun passes **34/34 workflows**;
  the unchanged Debian loader still rejects its CPU baseline with guest exit 127.
- The fresh checksum-verified Linux jq, ripgrep and 7-Zip rerun passes
  **70/70 workflows**, 35 per engine. Public-app checks remain separate from
  the network-free core CI and retain their existing execution limits.
- The matching website is published at
  [UNIVERSE](https://othmaneblial.github.io/universe/). All four live HTML/JS/CSS
  files return HTTP 200 and match the checked source bytes exactly. This update
  changes documentation text; it adds no fresh browser/clipboard evidence.

Transcendental instructions and legacy x87 environments remain unsupported;
CPU feature claims stay conservative. No external execution engine or
floating-point library is introduced. GitHub Actions remains disabled.

## Current main: legacy x87 environments and full-state images

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- Full local CI passes **159/159 Zig tests**, rebuilt ELF/PE/Mach-O integrations,
  CPU/SDK oracles, site checks, 10,000 corpus mutations and 30,000 decoder cases.
  The added cases cover every
  TOP in both operand layouts, classified physical tags, logical register
  ordering and restoration of pending exceptions. Exact page-end operands
  succeed; crossing into unreadable/unwritable or unmapped memory faults
  without changing state or bytes. COW allocation failure preserves both.
- The syscall-only ELF guest and independent byte/layout oracle pass
  **22,304 image/state queries and eight deferred-fault checks per engine**.
  They cover every occupancy mask and TOP, arbitrary full tag classes,
  signaling/quiet NaNs, unsupported raw values, pointer truncation, selectors,
  saved opcode bits and untouched XMM/MXCSR state. FSTENV/FSAVE waiting aliases
  and environment/full-state save/restore sequences are included.
- Environment stores mask exceptions; full saves reset x87 controls, tags
  and pointers while retaining raw register bytes and SSE state. Environment
  loads keep physical register data; full restores replace it. Both restore
  paths derive only emptiness from the saved tag word and defer new unmasked
  exceptions to a later waiting instruction.
- The fresh Windows public-app regression passes **34/34 workflows**.
  The unchanged Debian loader still emits its own CPU-baseline rejection
  and exits 127 in both engines; no CPU feature override is added.
- The fresh checksum-verified Linux jq, ripgrep and 7-Zip regression passes
  **70/70 workflows**, 35 per engine. The existing 141,416-query arithmetic,
  29,813-query transfer and 9,282-query SSE oracles also pass in both engines.
  Public-app checks retain their execution limits and remain separate from
  the network-free core CI.
- The matching [website](https://othmaneblial.github.io/universe/) is live.
  Its four HTML/JS/CSS responses return HTTP 200 and exactly match checked
  source bytes. This text update has static/local-HTTP verification;
  no fresh browser/clipboard result is claimed.

This is specification/byte validation for 16-bit and 32-bit protected-format
images in x86-64 guests. Native x87 hardware parity and real-mode environments
remain outside the verified scope. The 16-bit protected image has no opcode
field; our restore retains the current opcode. Packed BCD transfers and
transcendental calculations remain missing from the full FPU baseline.
No external execution engine is introduced. GitHub Actions remains disabled.

## Current main: packed BCD loads and rounded decimal stores

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- Full local CI passes **161/161 Zig tests**, rebuilt ELF/PE/Mach-O integrations,
  CPU/SDK oracles, site checks, 10,000 corpus mutations and 30,000 decoder cases.
  New cases exercise every TOP
  and precision-field setting, signed zero, all rounding directions, the
  18-digit limit, stack overflow/underflow and deferred invalid/precision faults.
  Exact ten-byte page-end operands succeed; permission/unmapped faults and
  COW allocation failure preserve state and output bytes.
- The existing transfer guest adds FBLD, FBSTP, an exact decimal round trip
  and an empty-stack store without changing its query/answer ABI. Independent
  Fraction and decimal-string encoders add **35,800 queries per engine**,
  for **65,613 total**. Every decimal position/digit and unused sign-byte
  pattern is covered alongside random signed 18-digit values and fractional
  rounding boundaries. The existing 30-million-instruction/30-second limits
  are retained.
- Loads retain exact extended precision and negative zero. Decimal stores
  ignore precision control and range-check the rounded value. Masked invalid
  conversions store the specified packed BCD indefinite value; unmasked invalid
  leaves memory and TOP intact. Unmasked precision still stores and pops,
  then the next waiting instruction faults. Denormal input does not fabricate
  a denormal-operand exception for FBSTP.
- Intel defines malformed BCD numeric results as undefined and FBLD does not
  check malformed digits. The numeric oracle uses valid digits; a unit check
  verifies that loading malformed input does not invent an invalid exception.
- Fresh Windows public-app regressions pass **34/34 workflows**. The unchanged
  Debian loader still reports its own CPU-baseline rejection and exits 127
  in both engines; CPUID feature claims remain conservative.
- Fresh checksum-verified Linux jq, ripgrep and 7-Zip regressions pass
  **70/70 workflows**, 35 per engine, with unchanged execution limits.
  The existing 141,416-query arithmetic, 22,304-query environment and
  9,282-query SSE suites also pass in both engines.
- The matching [website](https://othmaneblial.github.io/universe/) is published.
  All four live HTML/JS/CSS responses return HTTP 200 and match checked source
  bytes exactly. The documentation text update has static/local-HTTP checks;
  no fresh browser/clipboard result is claimed.

This is mathematical/specification validation on ARM64 macOS. Native x87
hardware numeric and condition-flag parity remain unverified. Transcendental
calculations still need implementation; the complete FPU baseline is not
advertised. No external execution engine or floating-point library is added.
GitHub Actions remains disabled.

## Current main: F2XM1 exponential-minus-one

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-01:

- Focused native checks pass **162/162 Zig tests** and the ReleaseSafe build.
  New instruction checks cover every TOP, all four precision fields and
  rounding modes, signed zero, exact endpoints, NaN payloads, unsupported
  values, empty operands and masked/unmasked invalid, denormal, precision
  and underflow exceptions. The next waiting instruction reports deferred
  faults without changing state. ST(1), control word, MXCSR, EFLAGS and data
  pointers remain intact; LOCK is rejected.
- The existing arithmetic guest adds raw `D9 F0` without changing its
  48-byte query or 32-byte answer ABI. Both engines pass **159,429 total
  Fraction/decimal/bit queries**, including **18,013 new F2XM1 cases**.
  A 160-digit Decimal oracle checks the specified signed input range,
  neighbors of dyadic powers/endpoints, all 64 subnormal leading-bit positions,
  normal/subnormal transitions and random extended inputs. Execution limits
  remain 100 million instructions and 60 seconds per engine.
- Both engines also pass **16 sampled monotonicity sequences**. Another
  **257 bounded numeric comparisons** agree with the host `expm1` within
  three binary64 ulps; these do not test native x87 instructions or flags.
- The normalized 113-bit approximation avoids cancellation and keeps full
  significands for exponent-biased underflow, including the smallest extended
  input. Precision control is ignored; rounding control applies. Non-integral
  binary inputs accrue precision loss even if the approximation happens to
  land on a representable number.
- Static site checks verify two pages, 36 local URLs, SVGs and five real guest
  outputs. All four local HTML/JS/CSS responses return HTTP 200 and match
  source bytes. No fresh browser or clipboard result is claimed.
- Full local CI completes successfully on 2026-10-01, including **162/162
  Zig tests**, rebuilt ELF/PE/Mach-O integrations, CPU/SDK oracles, all
  **159,429 arithmetic**, **65,613 transfer**, **22,304 environment plus
  eight deferred-fault** and **9,282 SSE** queries per engine. The final
  fuzz checks pass **10,000 corpus mutations and 30,000 decoder cases**.
- Fresh checksum-verified public-app checks pass **70/70 Linux workflows**
  with jq 1.8.2, ripgrep 15.2.0 and 7-Zip 26.03, plus **34/34 Windows 7-Zip
  workflows**, through both engines and with unchanged execution limits.
  The unchanged Debian loader still reports its own CPU-baseline rejection
  and exits 127; no broader CPU capability is advertised to bypass it.

The matching [website](https://othmaneblial.github.io/universe/) is published;
all four live HTML/JS/CSS files return HTTP 200 and match checked source bytes.

This is sampled mathematical/specification validation. Universal correct
rounding and native x87 numeric/condition-flag parity remain unverified.
The ISA leaves numeric results outside `[-1, 1]` undefined; our profile retains
those operands and excludes them from the numeric oracle. Other transcendental
instructions remain unsupported, so a complete FPU baseline is not advertised.
No external execution engine or floating-point library is added.
GitHub Actions remains disabled.

## Current main: FYL2X scaled logarithms and true underflow

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-02:

- Focused native checks pass **164/164 Zig tests** and the ReleaseSafe build.
  FYL2X checks every TOP, all precision fields and rounding modes, adjacent
  inputs around one, exact powers of two, tiny multipliers, signed zeros,
  infinities, NaN priority and masked/unmasked operand and result exceptions.
  Unmasked operand faults preserve both registers and TOP. Computed results
  commit and pop before deferred precision, overflow or underflow faults.
  The next WAIT preserves state while reporting the pending exception.
- The existing arithmetic guest adds raw `D9 F1` with the same 48-byte query
  and 32-byte answer ABI. **22,872 new Decimal/Fraction/bit queries per engine**
  cover the full extended argument/multiplier ranges, normal/subnormal
  transitions, all subnormal leading-bit positions, all PC/RC fields, class
  combinations, centered-reduction neighbors and random extended inputs.
  **32 sampled monotonicity sequences** check both positive and negative
  multipliers; **384 bounded host log2 comparisons** agree within three
  binary64 ulps. All guest invocations retain the 100-million-instruction and
  60-second caps.
- After the shared rounding fix, both engines pass all **40,885 focused
  F2XM1/FYL2X queries** plus **16 constructed underflow cases**. A
  continued-fraction convergent just below log2(3) produces a tiny irrational
  result whose binary128 approximation appears exact. The fix preserves
  both precision and underflow status. Nearest results match Decimal; all
  rounding modes stay within one subnormal destination step. C1 follows the
  approximation's rounding. Dedicated state checks cover the deferred
  denormal, precision and exponent-biased underflow paths for this case.
- Normalized multiplication retains guard bits for tiny products, including
  biased underflow; centered reduction avoids cancellation around one. Powers
  of two have exact integer logarithms. Zig 0.16's compiler-rt log2q narrows to
  binary64, confirmed by a local probe that loses `1 + 2^-63`; this implementation
  uses its own 113-bit series and the shared integer rounding machinery.
- Static site checks verify two pages, 36 local URLs, SVGs and five real guest
  outputs. All four local and published HTML/JS/CSS responses return HTTP 200
  and match source bytes. This documentation update has static/HTTP evidence;
  no fresh browser or clipboard result is claimed.
- Full local CI finishes successfully on 2026-10-02 with **164/164 Zig tests**,
  rebuilt ELF/PE/Mach-O integrations, CPU/SDK oracles, **182,301 arithmetic
  queries plus 16 hard underflow cases per engine**, **65,613 transfer**,
  **22,304 environment plus eight deferred-fault** and **9,282 SSE** queries
  per engine. Final fuzz checks pass **10,000 corpus mutations and 30,000
  decoder cases**.
- Fresh checksum-verified public-app checks pass **70/70 Linux workflows**
  with jq 1.8.2, ripgrep 15.2.0 and 7-Zip 26.03, and **34/34 Windows 7-Zip
  workflows**, through both engines with unchanged execution limits. The
  unchanged Debian loader still reports its own CPU-baseline rejection and
  exits 127; CPUID claims remain conservative.

This is sampled mathematical/specification validation. Universal correct
rounding and native x87 numeric/condition-flag parity remain unverified.
FYL2X special classes follow the Intel result table; our CPU profile retains
C0/C2/C3, which the ISA leaves undefined. FYL2XP1 and trigonometric instructions
remain unsupported, so a complete FPU baseline is not advertised.
No external execution engine or floating-point library is added.
GitHub Actions remains disabled.

## Current main: FYL2XP1 logarithms near zero

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-02:

- Host unit checks pass **165/165 Zig tests** and the ReleaseSafe build.
  The shared logarithm matrix checks every TOP, all PC/RC fields, domain
  endpoints, signed zeros, NaN/unsupported priority, empty operands and
  masked/unmasked invalid, denormal, precision and underflow exceptions.
  Unmasked operand faults preserve both registers and TOP; computed results
  commit and pop before deferred faults. The next WAIT reports the pending
  exception without changing state. Control, MXCSR, EFLAGS and unrelated
  registers/pointers remain intact, and LOCK is rejected.
- The existing arithmetic guest adds raw `D9 F9` without changing its
  48-byte query or 32-byte answer ABI. Both engines pass **217,654 total
  Fraction/decimal/bit queries**, including **35,353 new FYL2XP1 cases**.
  The independent 160-digit Decimal/Fraction oracle checks both input-domain
  boundaries, normal/subnormal transitions, all 64 subnormal leading-bit
  positions, the complete multiplier range, special classes, all PC/RC fields,
  deferred faults and random extended inputs. Execution limits remain
  100 million instructions and 60 seconds per engine.
- Both engines pass **32 sampled increasing/decreasing sequences**.
  Another **225 bounded host log1p comparisons** agree within three binary64
  ulps; these are host-library numeric comparisons, not native x87 checks.
  Existing F2XM1 and FYL2X cases and the **16 hard FYL2X underflow cases**
  also pass unchanged, including their underflow/precision flag requirements.
- The shared 113-bit logarithmic series avoids forming `1 + x` and
  normalizes both factors before multiplying. Products of two minimum
  extended subnormals retain guard bits before gradual or exponent-biased
  rounding. Precision control is ignored; rounding control applies to the
  approximation. Signed zero and infinite multipliers follow Intel's result
  table; zero arguments with infinite multipliers report invalid.
- The exact encoded domain cutoff is independently checked against Decimal
  `1 - sqrt(2)/2`. Numeric results outside the specified domain are undefined;
  our explicit profile retains ST(1) and still pops. These numeric results
  are excluded from the mathematical oracle. C0/C2/C3 are also undefined
  in the ISA and retained by our profile.
- Local static checks verify two pages, 36 local URLs, SVGs and five real
  guest outputs. All four local HTML/JS/CSS responses return HTTP 200 and
  match source bytes. This is static/local-HTTP verification; no fresh
  browser or clipboard result is claimed.
- Full local CI completes successfully on 2026-10-02 with **165/165 Zig
  tests**, rebuilt ELF/PE/Mach-O integrations, CPU/SDK oracles, **217,654
  arithmetic queries plus 16 hard underflow cases per engine**, **65,613
  transfer**, **22,304 environment plus eight deferred-fault** and **9,282
  SSE** queries per engine. Final fuzz checks pass **10,000 corpus mutations
  and 30,000 decoder cases**.
- Fresh checksum-verified public-app checks pass **70/70 Linux workflows**
  with jq 1.8.2, ripgrep 15.2.0 and 7-Zip 26.03, and **34/34 Windows 7-Zip
  workflows**, through both engines with unchanged execution limits. The
  unchanged Debian loader still reports its own CPU-baseline rejection and
  exits 127; CPUID claims remain conservative.

The matching [website](https://othmaneblial.github.io/universe/) is published;
all four live HTML/JS/CSS responses return HTTP 200 and match checked source
bytes exactly, including the clarified unmasked-operand exception notes.

This is sampled mathematical/specification validation. Universal correct
rounding and native x87 numeric/condition-flag parity remain unverified.
Trigonometric instructions remain unsupported, so a complete FPU baseline
is not advertised. No external execution engine or floating-point library
is added. GitHub Actions remains disabled.

## Current main: FPATAN quadrants and full-range tiny angles

Validated on Apple M2/macOS 26.6 ARM64, 2026-10-02:

- Host unit checks pass **166/166 Zig tests** and the ReleaseSafe build.
  The shared popping-transcendental matrix checks every TOP, all PC/RC fields,
  all quadrants, signed zeros, infinities, NaN priority, unsupported formats,
  empty operands and masked/unmasked invalid, denormal, precision and underflow
  exceptions. Unmasked operand faults preserve registers and TOP; computed
  results commit and pop before deferred faults. The next WAIT reports a
  pending exception without changing state. Control, MXCSR, EFLAGS, data
  pointers and unrelated registers remain intact, and LOCK is rejected.
- A dedicated check covers **all 64 subnormal leading-bit positions**, both
  signs and all PC/RC fields. It retains the negative correction below an
  exactly representable ratio: nearest and outward rounding keep the input
  magnitude, while inward rounding selects its predecessor. The normal/
  subnormal boundary, signed zero, gradual and exponent-biased underflow
  retain their distinct results and flags.
- The existing arithmetic guest adds raw `D9 F3` with the same 48-byte query
  and 32-byte answer ABI. Both engines pass **246,943 total Fraction/decimal/bit
  queries**, including **29,289 new FPATAN cases**. An independent 160-digit
  Decimal half-angle series and tiny-input Fraction expansion cover full
  operand ranges, normal/subnormal transitions, reduction/tiny-angle neighbors,
  special classes, all PC/RC fields, masked/unmasked faults and random extended
  pairs. Execution limits remain 100 million instructions and 60 seconds
  per engine.
- Both engines pass **48 sampled monotonicity sequences** within continuous
  angle branches; the negative-X branch cut is explicitly excluded from these
  sequences and its signed-zero results use exact bit checks. Another
  **1,089 bounded host atan2 comparisons** agree within three binary64 ulps.
  These host-library comparisons do not test native x87 instructions or flags.
  Existing F2XM1/FYL2X/FYL2XP1 cases and all **16 hard FYL2X underflow cases**
  also pass unchanged after sharing the series/rounding helpers.
- Regular angles use the shared 113-bit alternating series with pi/4
  reduction. Tiny positive-X angles use normalized division and a Taylor
  approximation with 192 fractional bits. Even the minimum-to-maximum extended
  ratio remains available for gradual and exponent-biased rounding. Zero/zero
  and infinity/infinity follow Intel's defined angle table without fabricating
  division exceptions. Precision control is ignored; rounding control applies.
- Local static checks verify two pages, 36 local URLs, SVGs and five real
  guest outputs. All four local HTML/JS/CSS responses return HTTP 200 and match
  source bytes. This is static/local-HTTP verification; no fresh browser or
  clipboard result is claimed.

This is sampled mathematical/specification validation. Universal correct
rounding and native x87 numeric/condition-flag parity remain unverified.
C0/C2/C3 are undefined in the ISA and retained by our profile. FPTAN, FSIN,
FCOS and FSINCOS remain unsupported, so a complete FPU baseline is not
advertised. No external execution engine or floating-point library is added.
GitHub Actions remains disabled.
