# Roadmap

## Practical application milestone

The user defined the “50%” milestone as finding useful Linux or Windows apps
online and running them on their Mac. Current main downloads checksum-pinned,
unchanged official Linux jq 1.8.2, ripgrep 15.2.0, 7-Zip 26.03, fd 10.5.0 and
BusyBox 1.35.0 binaries. JSON/text processing, ZIP/7z archives, hashing, file
searches and selected shell scripts, external pipelines, signals, devices and
synthetic proc files pass 332 Linux checks across interpreter/JIT modes on
ARM64 macOS. The unchanged Windows x64 7-Zip
release now passes another 34 archive/hash/error workflows, including denied
read/write exits through our own C++ cleanup and catch execution.
fd's 19 cases per engine cover real file/directory/symlink inventories, Unicode
and NUL output, filters, ignore rules, physical paths and two-thread searches.
BusyBox adds 112 checks per engine: 30 utility/file cases, 11 virtual-identity
cases, 57 noninteractive shell cases and fourteen device/mount/system-info cases.
Linux dup/dup2/dup3 and fixed-ID setuid/setgid support startup; unavailable sendfile uses the app's
read/write fallback. Empty guest supplementary groups and initial parent PID 0 allow
identity queries and built-in scripts without exposing host credentials/process IDs.
Linux 7-Zip's threaded 7z round trips pass too, and its guest threads now
extract the pinned Windows release container through UNIVERSE itself.
See [public-apps.md](public-apps.md) for reproducible commands and limits.
This milestone does not measure half of every remaining roadmap task.

## v0.1.0 delivered

- Real foreign Linux x86-64 ELF execution on ARM64 macOS.
- Eight libc-free C fixtures for x86-64, RV64IM and AArch64, covering arithmetic,
  recursion, stack, BSS, heap/mmap, files, directory pagination, arguments,
  environment, time, randomness, standard input/error and nonzero exits.
- Static x86-64 musl Hello World; optional source-built BusyBox with selected
  coreutils and file applets.
- UIR, a checked guest virtual memory model, instruction/syscall tracing,
  ELF/PE/Mach-O inspection, IR disassembly and an interactive debugger.
- PE32+ x86-64 console execution and a tested small Windows API layer.
- Native ARM64-host JIT register blocks, W^X code pages and invalidation.
- Local regression checks, deterministic parser/decoder/executor mutations,
  exact-output native algorithm comparisons and honest interpreter/JIT timings.

## Current main development

All static imports of unchanged Windows 7-Zip bind. Both engines complete
format listing, hashing, ZIP/7z creation/listing/testing/extraction, Unicode
members, recursive folders, corrupt/missing input and denied-access exits:
17 workflows each. Broader application compatibility remains ongoing.
See [windows.md](windows.md) for the current API boundary.

- Linux shared-memory guest threads on x86-64, AArch64 and RISC-V64, with separate
  CPU/TLS contexts, real futex wait queues, per-thread signal metadata and clear-TID
  exits. The actual musl pthread fixture checks mutexes, condition waits, joins,
  TLS, CPU-bound preemption, timed waits and process-wide limits in both engines.
  AArch64 LDAR/STLR now covers all four widths with alignment/permission checks.
  Scheduler-backed relative/absolute sleeps allow actual two-thread ripgrep
  directory searches and file listings to finish; sleeping guests still respect
  process-wide runtime deadlines.
  Robust recovery, PI/requeue, cancellation and dynamic-library pthread TLS remain
  unsupported or unverified. See [linux-threads.md](linux-threads.md).
- Own RtlLookupFunctionEntry over checked live PE exception directories, with
  compiler-generated SDK records, independent Python metadata checks and
  malformed-table/output regressions in both engines.
- Own checked x64 call-frame unwinding and POD C++ throw/type/state/try maps,
  executing real guest cleanup and catch funclets. Both engines match the native
  C++ source oracle's `result=42 cleanup=23154`, preserve global instruction
  budgets, and pass unchanged Windows 7-Zip's four denied-access exit checks.
  Nested/rethrows, nontrivial exception-object lifetimes, SEH and RTTI remain
  explicit unsupported boundaries; public RtlVirtualUnwind is not implemented.
- Correct optional default-character flags for the virtual UTF-8 ANSI/OEM
  aliases, attribute setters that preserve file types, and canonical extended
  C-drive paths. These fixes enable real Windows archive workflows. The encoding
  oracle covers every Unicode scalar and 17,286 small cases per engine; failure
  injection checks both output buffers before mutation.
- Own read-only directory/symbolic-link handles and DeviceIoControl reparse
  queries, with 1,226 exact SDK replies per engine and checked COW/ownership.
- Correct Win64 entry home slots, verified by real guest stores before the prologue;
  unchanged Windows 7-Zip now reaches its banner and format-list code.
- Own FindFirstStreamW/FindNextStreamW over real default file data, checked
  64-bit stream records and typed search handles. Explicit `::$DATA` names
  round-trip through CreateFileA/W into real reads, writes and creation with
  shared identities. Both engines pass 2,145 exact SDK replies and the common
  1,024-search limit. Named alternate streams and native Windows parity remain
  unsupported or unverified.

- Own FindFirstFileW/FindNextFileW/FindClose with real directory cursors, bounded
  UTF-16 DOS wildcard matching, host metadata and checked handle ownership.
  Both engines pass 9,112 SDK replies against independent recursive/POSIX oracles;
  allocation and write failures preserve outputs and cursors. Guest cwd changes
  and directory renames retain open searches. Named alternate streams, UNC/device
  paths and native Windows filesystem/NLS parity remain unsupported or unverified.

- Own current/temp directory APIs with real relative file operations, checked
  UTF-16 buffers, stable sysroots and restored host working directories. SDK
  guests and Python verify path round trips, guest DLLs after directory changes
  and explicitly supplied temporary-path variables without host inheritance.
  The virtual C drive accepts absolute/current-drive-relative paths and both
  queries return reusable DOS paths. A/W drive enumeration and the drive bitmask
  refer to this same real mount, with 189 checked SDK replies per engine.
  File mutations, stream access and disk statistics round-trip through C paths.
  Other drives, UNC paths and native Windows
  parity remain unsupported or unverified.

- Own message diagnostics, UTF-16 templates, typed/reordered inserts, checked
  variadic/array arguments, line widths and locally allocated result buffers.
  Native snprintf and Python compare 1,428 exact byte cases per engine. English
  catalog wording is ours; module resources, localization and va_list stars remain
  unsupported. Allocation/COW failures preserve caller bytes and ownership.

- Own fixed/movable local allocations, checked resizing, lock counts and
  discarded handle lifetimes. SDK guests and Python compare 84 complete byte
  sequences per engine; allocation/COW failures preserve original memory.
  Native Windows differential behavior remains unverified.

- Own loaded-module filename queries for the executable and guest DLLs. The
  loader retains absolute host path spellings across renames, unload/rollback
  and slot reuse. SDK guests and Python check UTF-8/UTF-16 buffers at every
  capacity, Unicode/case/long/symlink paths, stale handles and checked faults.
  Built-in API modules have no physical Windows DLL path.

- Own UTF-8/UTF-16 conversion with the virtual UTF-8 ANSI/OEM profile. SDK
  guests and Python compare all 1,112,064 Unicode scalars in both directions,
  replacement/strict malformed handling, length queries, short buffers and
  checked outputs. Other code pages remain unsupported; native Windows NLS parity remains
  unverified.

- Own disk-space and allocation-geometry queries using the host directory's
  filesystem counters. SDK guests and Python compare native 64-bit capacity,
  geometry and bounded volatile free space across Unicode/symlink/sysroot paths
  in both engines. Optional outputs, permissions, failed paths and checked
  faults are tested. The virtual C drive uses these same counters; multi-drive
  mappings and quota virtualization remain absent. Legacy counts saturate at DWORD limits.

- Own virtual processor-feature and memory-capacity queries. SDK guests compare
  feature flags with CPUID and check exact allocation/free accounting in both
  engines. Memory availability follows the 256 MiB guest budget and checked
  address space. Incomplete CPU profiles remain unadvertised.

- Own Win32 shared file sections, named objects, checked views, guest-page COW,
  dirty-page writeback and independent handle/view lifetimes. SDK guests and
  Python compare actual sparse-file bytes above 4 GiB, partial flushes, hard
  links, deletion and fault cleanup in both engines. Executable paging views
  use our CPU engine. File execute rights, image/reserve/large-page flags,
  inherited handles, global IPC and native cache parity remain absent.

- Own Win32 terminal input/control callbacks, checked stream types and UTF-8
  console/file policy. SDK guests and independent real PTY/signal checks cover
  raw/cooked input, LIFO handlers, ignored Ctrl+C, interrupted reads and cleanup
  in both engines. Callbacks run serially on the initial guest thread; output
  modes, screen buffers and native handler-thread scheduling remain absent.

- Own Win32 Gregorian/DOS/FILETIME conversions, current local/UTC clocks, virtual
  process CPU times and checked host file-time updates. SDK guests and independent
  calendar/host-stat oracles cover both engines; timezone probes include UTC,
  positive/negative offsets and current DST. Native
  Windows time/filesystem parity and broader timezone APIs remain unverified.

- Own Win32 file mutations and metadata: atomic no-overwrite moves, replacement,
  directories, hard links, sharing-aware pending deletion, read-only mapping,
  checked file information and sparse seeks above 4 GiB. SDK guests and Python
  host-stat/byte checks cover both engines and relative/sysroot paths. No vendor
  DLL or external execution runtime is added. Cross-volume moves, progress
  callbacks and broader attributes still need implementation.

- Own single-thread Win32 events/semaphores, shared named-object references,
  access checks, wait-any/all consume rules, finite/infinite pending waits and
  recursive critical sections. Runtime timeouts interrupt pending waits even
  when no instructions retire. SDK guests and memory/exhaustion regressions
  check both engines. Virtual identity, one-CPU affinity and clocks do not
  create guest threads.

- Own legacy MSVCRT allocation/copy/string functions, writable data exports,
  original argc/argv, unbuffered text/binary standard streams and guest
  initializer/exit callbacks. The SDK guest checks nested initialization, LIFO
  callbacks, allocation-failure preservation and stream bytes in both engines.
  All 39 CRT imports of unchanged Windows 7-Zip resolve. Broader exceptions/RTTI, threads,
  broad CRT and additional Win32 behavior remain missing.

- Own ADVAPI32 entropy, process-token handles/access checks, privilege-name
  lookup and five empty read-only registry roots. The virtual token has no
  assigned Windows privileges; adjustment reports ERROR_NOT_ALL_ASSIGNED.
  Windows file ACLs fail explicitly without host permission changes.
  SDK-declared guests check both engines. Unchanged Windows 7-Zip binds all nine
  ADVAPI32 imports.
- Own USER32 CharUpperW character/string conversion and CharPrevExA navigation,
  with bundled Unicode 17.0.0 BMP simple-uppercase mappings and five Windows
  DBCS lead-byte ranges. Original-data comparisons check every UTF-16 unit in
  both engines. Supplementary casing and Windows NLS version parity remain
  unverified. Unchanged Windows 7-Zip binds USER32;
  further Win32, CRT and exception behavior remains outside the tested workflows.
- Own OLEAUT32 BSTR allocation/length/free and Windows x64 scalar, string and
  by-reference VARIANT APIs, with named/ordinal imports and scoped DLL exports.
  Source-built guests check both engines and both forwarder forms. Unchanged
  Windows 7-Zip binds all six OLEAUT32 imports. Other Win32 APIs and
  CRT/exception support remain outside the tested workflows. Owning COM
  objects, arrays and records are explicit unimplemented cases.
- Unchanged Linux 7-Zip performs ZIP/7z creation, listing, testing and extraction,
  SHA-256 hashing and recursive ZIP folder scans, with exact file bytes and
  preserved timestamps. It drove general umask, wall-clock/resource queries,
  signed-32-bit dirfd handling, descriptor timestamp updates, O_NONBLOCK and
  REP RET support. The same release's Windows console app now passes scoped
  archive/hash/error workflows through our own runtime. Broader exception
  behavior, Windows guest threads and broader glibc applications remain concrete next steps.
- The independent execution engine now adds basic x87 arithmetic, square roots,
  integral rounding, ordered/unordered comparisons, conditional moves and all
  seven constant loads. FXTRACT adds exact significand/exponent separation,
  including denormal normalization and deferred stack/operand faults.
  FPREM/FPREM1 add exact remainders, quotient flags and repeated partial
  reductions across the full extended exponent range. FSCALE adds power-of-two
  scaling with truncated exponents, full significand precision and checked
  massive overflow/underflow results. FXTRACT followed by FSCALE reconstructs
  the original finite value.
  F2XM1 computes exponential-minus-one throughout its specified `[-1, 1]`
  domain, retaining tiny and exponent-biased results with a normalized
  113-bit approximation. It ignores precision control and handles deferred
  operand, precision and underflow exceptions. 18,013 new decimal/bit queries,
  sampled monotonicity and 257 bounded host-math comparisons cover this addition;
  universal correct rounding and native x87 parity remain unverified.
  FYL2X now computes scaled base-two logarithms across the complete extended
  argument/multiplier range. Centered reduction preserves neighbors of one;
  normalization retains tiny and exponent-biased results. It commits/pops
  post-computation results and preserves both operands on unmasked operand
  faults. 22,872 new decimal/bit queries, 32 sampled monotonicity sequences and
  384 bounded host-math comparisons cover the addition.
  FYL2XP1 computes scaled `log2(1 + x)` throughout its specified range near
  zero. The shared logarithmic series avoids cancellation; both factors are
  normalized to retain even products of two minimum subnormals before gradual
  or exponent-biased rounding. Unmasked operand faults preserve registers and TOP;
  computed results commit and pop before deferred precision/underflow faults.
  35,353 new decimal/bit queries, 32 sampled monotonicity sequences and 225
  bounded host-math comparisons cover this addition.
  FPATAN now computes the angle of both operands across their full extended
  ranges, including all quadrants, signed-zero and infinity combinations.
  Tiny angles use normalized integer division and 192 fractional bits to retain
  ratios below binary128's range and the correction below representable inputs.
  Regular angles reuse the logarithmic series with alternating terms and pi/4
  reduction. Operand/result faults retain their distinct preserve/pop behavior.
  29,289 new Decimal/Fraction/bit queries, 48 sampled monotonicity sequences
  and 1,089 bounded host-math comparisons cover the addition.
  FSIN and FCOS now cover the strict finite range below 2^63, using 256-bit
  fractional pi/2 reduction and integer tiny-angle corrections. Out-of-range
  finite values set C2 without changing ST(0); infinity raises invalid. Neither
  instruction invents underflow exceptions or biased results. Precision control
  is ignored and rounding control applies. 35,250 new decimal/bit queries,
  48 sampled monotonicity sequences and 1,536 bounded host-math comparisons
  cover the addition; native x87 numeric/flag parity remains unverified.
  FPTAN and FSINCOS now commit both stack outputs throughout their strict
  finite range below 2^63. Shared integer reduction, unrounded 113-bit series
  and 192-bit tiny corrections retain large angles, pole neighbors and values
  just above/below representable inputs. Operand/stack faults preserve the stack
  when unmasked; computed precision/underflow results commit before deferred
  faults. 37,584 new FSINCOS and 38,352 new FPTAN queries, 64 sampled
  monotonicity sequences and 768 bounded host tan comparisons cover
  both additions. Native x87 numeric/flag parity remains unverified.
  358,129 rational/decimal/bit queries per engine cover
  90 decoded forms, three arithmetic precisions, four rounding
  modes and deferred exceptions. The broader compatibility goal remains open;
  no third-party emulator or floating-point library is added.
- Legacy x87 FLDENV/FNSTENV and FRSTOR/FNSAVE now preserve environments and
  complete stack images in both 16-bit and 32-bit protected layouts. Their
  independent byte oracle covers 22,304 queries per engine, with tag
  reconstruction, every TOP/occupancy mask, pointer truncation, deferred
  exceptions and unchanged SSE state. Waiting stores and save/restore sequences
  execute through the existing engine; memory and COW failures preserve state.
  Trigonometric stack operations now execute, but broader CPU/SIMD coverage
  and native x87 numeric/flag verification remain open. CPUID claims stay
  conservative; a broader FPU/CPU baseline is not advertised from these checks.
- Real downloaded apps drove support for wrapped 32-bit x86 addresses, XADD,
  SHUFPS/SHUFPD, floating lane unpacks, MOVMSKPS/MOVMSKPD, prefetch hints, serialized fences and
  disabled CET reads. Linux startup adds bounded poll, resource-limit queries,
  alternate-stack metadata and descriptor duplication. Futex waits/wakes now
  integrate with Linux guest scheduling. Unavailable optional capabilities return
  explicit Linux errors; CPU fault-to-signal delivery remains unsupported.
- x87 stack, raw 80-bit transfers, single/double, signed-integer and packed BCD conversions,
  rounding controls, condition classification and deferred exceptions. Exact
  rational/bit oracles check 65,613 transfer queries per engine, including
  35,800 BCD load/store/round-trip cases. Decimal stores retain all four rounding
  modes, signed zero and the rounded 18-digit range boundary; invalid and
  precision exceptions preserve their distinct store/pop behavior. The calculation
  suite above now includes FPTAN, FPATAN, FSIN, FCOS and FSINCOS. Numerical
  checks are sampled, and native x87 numeric/flag parity remains unverified.
- MXCSR controls now apply to the implemented SSE floating operations: four
  rounding modes, DAZ/FTZ, NaN rules, sticky flags and staged unmasked traps.
  Results are checked with an exact rational oracle; traps preserve destinations
  and stop the engine, since CPU fault-to-signal delivery remains unsupported.
- Paired CMPXCHG8B/16B, original MMX operations through shared SIMD execution,
  physical x87/MMX register aliasing and bounded FXSAVE/FXRSTOR images with
  all 16 XMM registers. Scalar guest oracles pass in interpreter/JIT modes.
  CPUID adds CX8/MMX/CX16; remaining SSE/SSE2 forms, native flag verification
  and guest fault delivery keep the baseline incomplete. See [compatibility.md](compatibility.md).
- ANDNPS/ANDNPD, aligned MOVNTPS/MOVNTPD/MOVNTDQ, MOVNTQ and four/eight-byte
  MOVNTI now reuse checked raw vector/scalar operations. MASKMOVDQU/MASKMOVQ
  reserve selected output bytes before writes, honor mask MSBs, RDI/EDI and
  FS/GS overrides, and preserve untouched bytes. A 91,072-query byte/state
  oracle includes all XMM/MMX selection patterns in both engines.
  PUSHFW/PUSHFQ save the modeled flags through checked stack writes; auxiliary
  carry is tracked by arithmetic, XADD and CMPXCHG, with flag updates staged
  until destination writes succeed. Other MMX
  extensions remain open; CPUID claims stay conservative.
- RCPPS/RCPSS and RSQRTPS/RSQRTSS now execute through checked vector sources,
  preserving scalar upper lanes, MXCSR and flags. Signed zero/denormal, NaN,
  infinity, negative-indefinite and RCP underflow rules are explicit. A
  binary64 approximation is rounded to binary32 within the ISA error limit;
  its bits need not match a native x86 lookup table. An independent rational/
  integer-root oracle passes 85,996 queries per engine, covering all normal
  exponents, flush boundaries, midpoint neighbors and 12 encoding views.
  Universal correct rounding remains unverified; CPUID stays conservative.
- MOVDQ2Q/MOVQ2DQ and CVTPI2PS/PD, CVTPS/PD2PI and CVTTPS/PD2PI now
  reuse checked vector transfers and the existing rounding/exception context.
  Register-only bridges, exact eight-byte PS/integer sources, aligned 16-byte
  PD sources and the memory-only CVTPI2PD exception distinction are checked.
  A real-guest rational/byte oracle passes 24,653 queries and 33 fault exits
  per engine, including physical x87 data and pending/unmasked exceptions.
  Native fault parity and CPU fault-to-signal delivery remain open;
  the [virtual baseline profile](x86-baseline.md) records the current CPUID scope.
- Fifteen additional SSE/SSE2 MMX integer forms now reuse the existing vector
  operations: qword add/subtract, unsigned products, averages, byte differences,
  byte/word min/max, word shuffle/insert/extract and byte-mask moves. Every
  immediate and byte-mask result, MMX/GP field extensions, aliases, exact
  two/eight-byte sources and pending/memory faults are checked. The mixed
  oracle retains 24,653 rational/bridge cases and adds 22,048 integer cases,
  with 73 fault exits per engine across 54 real encoding views. Native fault
  parity and broader CPU instruction coverage remain open.
- Sixteen SSSE3 MMX forms now reuse the shared decoder/register mapping and
  vector executor: PSHUFB, PALIGNR, PABS/PSIGN B/W/D, PHADD/PHSUB W/D/SW,
  PMADDUBSW and PMULHRSW. Eight-byte reads, three-bit shuffle indices,
  horizontal result halves, signed saturation, rounding ties and the extreme
  rounded-product wrap are checked. The real guest adds 27,255 integer/state
  cases, all PALIGNR immediates, every PSHUFB control byte and zero mask, aliases
  and pending-fault exits. The combined oracle passes 73,956 queries and
  121 fault exits per engine across 102 views. The earlier 46,701 queries are
  retained. Native fault parity, CPU fault-to-signal delivery, broader ISA auditing
  and broader dynamic application coverage remain open.
- A checksum-pinned unmodified Debian Hello/glibc app now runs with its guest
  loader and library, prints Hello World and passes 24 application/profile
  checks across both engines. CPUID exposes the implemented virtual baseline; RDTSC,
  legacy SSE half-register moves and short XCHG forms have checked semantics.
  Robust-list and rseq probes return ENOSYS. See [debian.md](debian.md).

- Optional unmodified upstream SQLite 3.53.4 static x86-64 batch CLI, with
  persistent transactions, indexes/joins, Unicode/blobs, rollback, delete/truncate
  journals, VACUUM, native database reopen and lock contention in interpreter/JIT
  paths. This is a tested subset; WAL, guest threads and loaded extensions are
  not validated. See [sqlite.md](sqlite.md).
- Checked positioned/scatter I/O, native file sync/truncation, symlink reads,
  working-directory queries and nonblocking advisory locks, covered by storage
  fixtures for all three Linux guest CPUs.
- Standard guest signal delivery, checked frames/return, pending masks, siginfo,
  alternate stacks and interrupted/restarted waits on all three Linux CPUs.
  Selected unchanged BusyBox background jobs and traps pass in both engines;
  CPU fault signals, real-time queues and terminal job control remain open.
- Internal absolute `/dev/null` and `/dev/zero`, including checked I/O, guest
  character-device metadata, shared dup/fork flags and private zero mappings.
  BusyBox background stdin now works inside an empty sysroot without file grants.
  No native device nodes are supplied. See [linux-devices.md](linux-devices.md).
- Private regular-file snapshots and anonymous mappings with fixed replacement
  and MAP_FIXED_NOREPLACE, verified across all three Linux guest CPUs.
- Zero-padding of partial EOF pages, faults beyond EOF, unchanged file offsets
  and file contents, and allocation-failure checks preserving existing mappings.
- Standalone PIE fixtures for all three Linux CPUs and validated PT_INTERP
  handoff with rebased Linux auxv and an explicit guest sysroot.
- Optional upstream musl 1.2.5 dynamic x86-64, AArch64 and RISC-V LP64 ET_EXEC/PIE
  fixtures, a separate shared library, constructors and single-thread TLS, in interpreter/JIT paths.
- AArch64 guest TLS, extended arithmetic, long/high multiply, RBIT/CLZ, checked
  cache-block zeroing, conservative exclusive atomics and a SIMD transfer/move
  subset. Integer NEON modular ADD/SUB/MUL, AND/BIC/ORR/EOR, MVN and signed CMGT/CMEQ now
  cover B/H/S/D lanes in D/Q arrangements, with D-register upper-lane clearing.
  MUL is restricted to B/H/S lanes. TBL/TBX now checks one-to-four-register
  tables, wrapping and aliases; integer MLA/MLS supports B/H/S lanes. Both
  engines match 8,448 scalar/native ARM64 byte queries across 228 views.
  Architecture-specific Linux open flags and symlink rejection.
- Restartable bounded x86 string operations, direction control, ROL/ROR and
  TZCNT/LZCNT, with width, flag and memory-fault regressions. POPCNT supports
  16/32/64-bit register and memory sources with verified status-flag results;
  BSWAP handles 32/64-bit and extended registers without changing flags.
- SSE2 signed-word min/max, verified by edge-lane tests and BusyBox numeric
  `printf` execution.
- SSE2 modular packed add/subtract for byte, word, doubleword and quadword
  lanes, plus signed byte/word/doubleword greater-than comparisons, exercised
  by a dedicated x86-64 guest. Signed/unsigned saturating byte/word add/sub
  operations are checked against scalar boundary results. High-half unpack
  byte/word/doubleword/quadword instructions now have guest coverage too.
- SSE2 low/high signed and unsigned word products, even unsigned doubleword
  products and pairwise signed multiply-add have scalar-checked guest coverage.
  `PEXTRW` zero-extending word extraction is covered through the guest oracle.
- SSE2 register-count logical word/doubleword/quadword shifts and arithmetic
  word/doubleword right shifts, checked at and beyond lane widths.
- SSE2 rounded unsigned byte/word averages and byte sum-of-absolute-differences
  are checked against scalar expected values.
- SSE2 signed word-to-byte, signed dword-to-word, and signed word-to-unsigned
  byte saturating packs are tested at signed boundaries.
- SSE2 `PINSRW` inserts all eight word lanes from a general register and one
  word from memory, preserving untouched vector lanes.
- SSE/SSE2 `ADD/SUB/MUL/DIV/SQRT/MIN/MAX` cover all 28 packed/scalar
  single/double precision forms. `CMPPS/PD/SS/SD` cover all eight legacy
  predicates, unordered values, full-lane masks and scalar upper-lane retention;
  `COMISS/UCOMISS/COMISD/UCOMISD` cover their EFLAGS result classes. Scalar
  signed-integer conversions support 32/64-bit inputs/outputs, nearest-even CVT,
  truncating CVTT and invalid indefinite results. Legacy `MOVSS/MOVSD` cover
  scalar memory/register transfers and register upper-lane preservation.
  `CVTSS2SD/CVTSD2SS` add scalar single/double precision conversion. Packed
  SSE2 conversions cover four-lane single/integer and two-lane
  single/double/integer forms. SSE3 `MOVSLDUP/MOVSHDUP/MOVDDUP` duplicate lanes;
  `LDDQU` covers unaligned 128-bit loads. `HADDPS/PD`, `HSUBPS/PD` and
  `ADDSUBPS/PD` add horizontal and alternating packed arithmetic.
- SSSE3 `PSHUFB` register and aligned-memory operands, with zeroing-mask and
  low-nibble selection checks against a scalar oracle; `PSIGNB/W/D` zero,
  preserve and wrapping-negate semantics plus `PABSB/W/D` absolute values use
  byte/word/dword scalar oracles. `PMADDUBSW` checks paired unsigned-by-signed
  byte products, addition and signed saturation in register and memory forms;
  `PMULHRSW` checks rounding ties, negative products and 16-bit result wrap.
  Horizontal add/subtract word, dword and saturating-word operations compare both
  source halves against the scalar lane oracle. `PALIGNR` tests register and
  aligned-memory sources across zero, boundary and out-of-range byte counts.
- Tested SSE4.1 operations: byte SAD, aligned non-temporal-hint load, packed
  multiply, signed/unsigned min/max, equality, min-position, saturating pack,
  immediate and variable blending, PTEST flags, scalar/vector lane transfers,
  float-bit dword routing, all 12 sign/zero-extension forms, ROUND*, DPPS and DPPD.
- SSE4.2 `CRC32` byte/word/dword/qword forms, checked against a scalar
  CRC32C oracle, including high-byte operands, 32-bit zero-extension and
  unchanged CF/ZF/PF/OF/SF.
- SSE4.2 `PCMPGTQ` register and aligned-memory forms compare both signed qword
  lanes against exact scalar results.
- Linux `mkdirat`/`unlinkat`/`renameat`/`faccessat` across x86-64, RISC-V64 and AArch64,
  plus legacy x86-64 access/mkdir/rmdir/unlink/rename and `utimensat`; mutation
  stays behind `--allow-files` and guest times/flags are translated.
- Windows command lines, UTF-16 paths, process heap allocation/reallocation,
  synchronous regular files, size/seek/flush/close and guest sharing checks.
- Static Windows guest DLL dependencies, DIR64 rebasing, named/ordinal function
  and data exports, forwarding, guest DllMain startup and GetProcAddress lookup.
- Windows runtime LoadLibraryA/W, FreeLibrary and late forwarders, explicit
  references, cyclic dependency retention, guest attach/detach callbacks, failed
  attach rollback and repeated unload/reload in interpreter/JIT modes.
- PE static TLS template loading for the initial guest thread, per-module TLS
  indices through the x64 TEB vector, process callbacks and dynamic DLL reload
  initialization, checked with source-built executable and DLL guests.
- Win32 `TlsAlloc`, `TlsFree`, `TlsGetValue` and `TlsSetValue` for the documented
  64-slot minimum on the initial guest thread, including zero initialization,
  LastError behavior, exhaustion and index reuse.
- Linux GNU and musl host-target builds, using `statx` metadata and shared
  target-native time/file-stat types instead of opaque libc structures.
- Library-free x86-64/AArch64 Mach-O execution, checked segments/BSS/maximum
  protections, initial stack and a Darwin BSD console/file/private-mapping subset.
  Five source-built guests per CPU and matching-host syscall source comparisons.
- RISC-V compressed integer decoding with mixed two/four-byte boundaries,
  hints/reserved encodings, PC+2 links and JIT accounting/invalidation checks.
  All twelve Linux C fixtures and PIE also pass as RV64IMC guests.
- Checked RISC-V word/doubleword LR/SC and nine AMOs, sign-extended word
  returns, conservative reservations cleared on thread switches, aliases and permission faults.
  A source-built atomic fixture passes both interpreter and JIT modes.
- A bounded RISC-V F/D transfer, arithmetic, fused multiply-add, compare,
  classify, integer and S/D cross-format conversion subset, NaN-boxed single
  values, compressed D transfers, and Zicsr access to `fflags`, `frm` and
  `fcsr`. A hard-float guest verifies these in interpreter/JIT.
- A refreshed README and published [project site](https://othmaneblial.github.io/universe/)
  with recorded real guest examples and a flight-manual documentation page.

## Next unchanged BusyBox blockers

A separate 2026-10-02 probe of the same pinned binary found these boundaries
in both engines. Identity and built-in script successes now have exact regressions
in the 366 downloaded Linux/Windows workflows; the remaining exploratory faults
below are excluded from that passing count.

| Probe | Current result | Next requirement |
|---|---|---|
| `busybox id` | Passes numeric identity and controlled sysroot names | Preserve guest UID/GID 1000 and empty supplementary groups; mutable credentials remain separate work |
| `busybox sh -c 'echo hello'` | Passes, alongside loops/functions/conditions/arithmetic/stdin/redirection | Preserve exact built-in script regressions; preserve standard signals; broader shell execution still needs terminal job control |
| `busybox sh -c 'echo $(echo hi)'` | Passes with exact `hi` output in both engines | Preserve substitution/subshell/status regressions and global limits |
| Built-in `printf \| { read; printf; }` and a 420-line pipeline | Passes exact output/status; transfers 4,620 bytes through a 4 KiB queue | Preserve isolated process memory, descriptor lifetimes and backpressure |
| `busybox sh -c 'echo hi \| cat'` | Passes exact `hi` bytes with file permission granted and the unchanged BusyBox bytes at sysroot `/bin/cat`; additional cases exec jq and ripgrep | Preserve checked image replacement, argv/environment, close-on-exec and failed-loader rollback |
| `busybox sh -c 'echo hi & wait'` | Passes exact `hi` output with internal null stdin, including an empty sysroot without file grants | Preserve signal frames/return, suspend/wakeup and owned device lifetimes; terminal job control remains open |
| `busybox mount`; `df .`, `df -h .`, `df -i .` | Pass in interpreter/JIT; disk-stat modes use the granted target path | Keep the mount table deliberately synthetic; broader topology and Linux-native `statfs` remain separate work |
| `busybox free` | Passes in interpreter/JIT from guest-backed `/proc/meminfo` without file grants | Memory totals match the configured guest limit; caches and swap are zero, not host values |
| `busybox ps` | Exit 1 in interpreter/JIT: cannot open `/proc` | A process-aware read-only proc tree needs guest PID, identity, argv and scheduler accounting |

The same bounded probe produces exact expected outputs for `uname`, `ls -1 .`,
`find . -type f` and an `awk` sum of 42. This does not establish general applet
compatibility. Extend the shared Linux ABI in `src/syscall/linux.zig`, verify its
argument/error/state rules across all three guest CPUs, and promote new app
cases into `tests/public-apps.py` only after exact output/status checks pass in
both engines. Preserve the existing binary pins, budgets and 366 regressions.

## Next compatibility milestones

1. Broader x86 integer/SIMD decoding, remaining RISC-V F/D/CSR coverage, plus broader
   AArch64 coverage.
2. Larger static musl programs and broader BusyBox applets. The unchanged
   official 1.35.0 binary passes 112 workflows per engine, including selected
   noninteractive scripts and external commands; the optional source-built 1.37.0 fixture
   enables a small subset. Guest pipes now pass blocking/backpressure/EOF and
   exact-byte checks across all three CPUs; broader BusyBox shell execution
   now has isolated fork, wait4 and checked execve. Standard signal traps and background waits now pass with internal null stdin.
   Broader shell execution needs terminal and additional filesystem semantics. See [linux-processes.md](linux-processes.md).
3. Broader Windows APIs, loader search/flags and reentrancy, thread notifications
   and exception handling. Add real source-built API fixtures
   before advertising support.
4. Broader dynamic Linux applications, hard-float RISC-V guests and glibc. The current
   three-CPU musl fixture and unchanged x86-64 GNU Hello execute guest ldso code on our engine;
   expand source-built library and application regressions, including dynamic-library
   pthread TLS, before wider claims.
5. macOS dyld, shared libraries, fixups/TLS and broader ABI coverage. The current
   Mach-O guests link no libraries; ordinary LibSystem applications remain unsupported.
6. JIT flag operations, memory fast paths and block linking. Measure each change;
   the current JIT does not speed up every architecture or workload.
7. A separately reviewed sandbox with explicit policies and threat model.

Continue by finding the first unsupported behavior in a real binary, implementing
its general platform semantics, adding a regression and retrying. Never special
case program names. Full OS or ISA compatibility remains a long-term goal.
