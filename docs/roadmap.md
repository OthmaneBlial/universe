# Roadmap

## Practical application milestone

The user defined the “50%” milestone as finding useful Linux or Windows apps
online and running them on their Mac. Current main downloads checksum-pinned,
unchanged official Linux jq 1.8.2, ripgrep 15.2.0 and 7-Zip 26.03 binaries.
JSON/text processing, ZIP/7z archive workflows and hashing now pass 62 checks
across interpreter/JIT modes on ARM64 macOS.
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

- Own Win32 shared file sections, named objects, checked views, guest-page COW,
  dirty-page writeback and independent handle/view lifetimes. SDK guests and
  Python compare actual sparse-file bytes above 4 GiB, partial flushes, hard
  links, deletion and fault cleanup in both engines. Executable paging views
  use our CPU engine. File execute rights, image/reserve/large-page flags,
  inherited handles, global IPC and native cache parity remain absent.
  Windows 7-Zip now stops at KERNEL32!IsProcessorFeaturePresent before entry.

- Own Win32 terminal input/control callbacks, checked stream types and UTF-8
  console/file policy. SDK guests and independent real PTY/signal checks cover
  raw/cooked input, LIFO handlers, ignored Ctrl+C, interrupted reads and cleanup
  in both engines. Callbacks run serially on the initial guest thread; output
  modes, screen buffers and native handler-thread scheduling remain absent.
  Unchanged Windows 7-Zip now stops at KERNEL32!IsProcessorFeaturePresent during import
  binding, before entry. Virtual processor-feature queries are the next observed boundary.

- Own Win32 Gregorian/DOS/FILETIME conversions, current local/UTC clocks, virtual
  process CPU times and checked host file-time updates. SDK guests and independent
  calendar/host-stat oracles cover both engines; timezone probes include UTC,
  positive/negative offsets and current DST. Windows 7-Zip now stops at
  KERNEL32!IsProcessorFeaturePresent during import binding, before its entry runs. Native
  Windows time/filesystem parity and broader timezone APIs remain unverified.

- Own Win32 file mutations and metadata: atomic no-overwrite moves, replacement,
  directories, hard links, sharing-aware pending deletion, read-only mapping,
  checked file information and sparse seeks above 4 GiB. SDK guests and Python
  host-stat/byte checks cover both engines and relative/sysroot paths. No vendor
  DLL or external execution runtime is added. Cross-volume moves, progress
  callbacks and broader attributes still need implementation. Unchanged Windows
  7-Zip now stops at KERNEL32!IsProcessorFeaturePresent before its entry.

- Own single-thread Win32 events/semaphores, shared named-object references,
  access checks, wait-any/all consume rules, finite/infinite pending waits and
  recursive critical sections. Runtime timeouts interrupt pending waits even
  when no instructions retire. SDK guests and memory/exhaustion regressions
  check both engines. Virtual identity, one-CPU affinity and clocks do not
  create guest threads. Unchanged Windows 7-Zip now binds these APIs, MoveFileW and LocalFileTimeToFileTime, then stops
  at KERNEL32!IsProcessorFeaturePresent during import binding; its entry has not run.

- Own legacy MSVCRT allocation/copy/string functions, writable data exports,
  original argc/argv, unbuffered text/binary standard streams and guest
  initializer/exit callbacks. The SDK guest checks nested initialization, LIFO
  callbacks, allocation-failure preservation and stream bytes in both engines.
  All 39 CRT imports of unchanged Windows 7-Zip resolve; import binding
  stops at KERNEL32!IsProcessorFeaturePresent before guest entry. Exceptions/RTTI, threads,
  broad CRT and additional Win32 behavior remain missing.

- Own ADVAPI32 entropy, process-token handles/access checks, privilege-name
  lookup and five empty read-only registry roots. The virtual token has no
  assigned Windows privileges; adjustment reports ERROR_NOT_ALL_ASSIGNED.
  Windows file ACLs fail explicitly without host permission changes.
  SDK-declared guests check both engines. Unchanged Windows 7-Zip binds all nine
  ADVAPI32 imports; subsequent CRT/synchronization/file/time/console work advances binding to KERNEL32!IsProcessorFeaturePresent.
- Own USER32 CharUpperW character/string conversion and CharPrevExA navigation,
  with bundled Unicode 17.0.0 BMP simple-uppercase mappings and five Windows
  DBCS lead-byte ranges. Original-data comparisons check every UTF-16 unit in
  both engines. Supplementary casing and Windows NLS version parity remain
  unverified. Unchanged Windows 7-Zip binds USER32;
  further Win32, CRT and exception behavior still blocks execution.
- Own OLEAUT32 BSTR allocation/length/free and Windows x64 scalar, string and
  by-reference VARIANT APIs, with named/ordinal imports and scoped DLL exports.
  Source-built guests check both engines and both forwarder forms. Unchanged
  Windows 7-Zip binds all six OLEAUT32 imports. Other Win32 APIs and
  CRT/exception support still block execution. Owning COM
  objects, arrays and records are explicit unimplemented cases.
- Unchanged Linux 7-Zip performs ZIP/7z creation, listing, testing and extraction,
  SHA-256 hashing and recursive ZIP folder scans, with exact file bytes and
  preserved timestamps. It drove general umask, wall-clock/resource queries,
  signed-32-bit dirfd handling, descriptor timestamp updates, O_NONBLOCK and
  REP RET support. The same release's Windows console app still needs missing
  Win32 APIs and broader CRT behavior; no Windows compatibility percentage is inferred from Linux success.
- The independent execution engine now adds basic x87 arithmetic, square roots,
  integral rounding, ordered/unordered comparisons, conditional moves and all
  seven constant loads. 112,422 rational/decimal/bit queries per engine cover
  78 decoded forms, three arithmetic precisions, four rounding
  modes and deferred exceptions. The broader compatibility goal remains open;
  no third-party emulator or floating-point library is added.
- Real downloaded apps drove support for wrapped 32-bit x86 addresses, XADD,
  SHUFPS/SHUFPD, floating lane unpacks, MOVMSKPS/MOVMSKPD, prefetch hints, single-thread fences and
  disabled CET reads. Linux startup adds bounded poll, resource-limit queries,
  alternate-stack metadata, descriptor duplication and single-thread futex wake. Unavailable optional
  capabilities return explicit Linux errors; guest threads/signals remain absent.
- x87 stack, raw 80-bit transfers, single/double and signed-integer conversions,
  rounding controls, condition classification and deferred exceptions. Exact
  rational/bit oracles check 29,813 transfer queries per engine. The calculation
  suite above extends this; transcendental instructions remain missing.
- MXCSR controls now apply to the implemented SSE floating operations: four
  rounding modes, DAZ/FTZ, NaN rules, sticky flags and staged unmasked traps.
  Results are checked with an exact rational oracle; traps preserve destinations
  and stop the engine, since guest signal frames/delivery remain unsupported.
- Paired CMPXCHG8B/16B, original MMX operations through shared SIMD execution,
  physical x87/MMX register aliasing and bounded FXSAVE/FXRSTOR images with
  all 16 XMM registers. Scalar guest oracles pass in interpreter/JIT modes.
  CPUID adds CX8/MMX/CX16; complete x87 and SSE/SSE2 instruction coverage
  remain missing. See [compatibility.md](compatibility.md).
- A checksum-pinned unmodified Debian Hello/glibc loader probe reaches mapped
  glibc and TLS, then exits with its own CPU-baseline rejection. It does not
  run the application yet. CPUID reports a conservative virtual profile; RDTSC,
  legacy SSE half-register moves and short XCHG forms have checked semantics.
  Robust-list and rseq probes return ENOSYS. See [debian.md](debian.md).

- Optional unmodified upstream SQLite 3.53.4 static x86-64 batch CLI, with
  persistent transactions, indexes/joins, Unicode/blobs, rollback, delete/truncate
  journals, VACUUM, native database reopen and lock contention in interpreter/JIT
  paths. This is a tested subset; WAL, guest threads and loaded extensions are
  not validated. See [sqlite.md](sqlite.md).
- Checked positioned/scatter I/O, native file sync/truncation, symlink reads,
  working-directory queries and nonblocking advisory locks, covered by storage
  fixtures for all three Linux guest CPUs. Signal dispositions and masks are
  guest state; signal delivery and guest frames remain unsupported.
- Private regular-file snapshots and anonymous mappings with fixed replacement
  and MAP_FIXED_NOREPLACE, verified across all three Linux guest CPUs.
- Zero-padding of partial EOF pages, faults beyond EOF, unchanged file offsets
  and file contents, and allocation-failure checks preserving existing mappings.
- Standalone PIE fixtures for all three Linux CPUs and validated PT_INTERP
  handoff with rebased Linux auxv and an explicit guest sysroot.
- Optional upstream musl 1.2.5 dynamic x86-64, AArch64 and RISC-V LP64 ET_EXEC/PIE
  fixtures, a separate shared library, constructors and single-thread TLS, in interpreter/JIT paths.
- AArch64 guest TLS, extended arithmetic, long/high multiply, RBIT/CLZ, checked
  cache-block zeroing, single-thread exclusive atomics and a SIMD transfer/move
  subset. Integer NEON modular ADD/SUB/MUL, AND/BIC/ORR/EOR, MVN and signed CMGT/CMEQ now
  cover B/H/S/D lanes in D/Q arrangements, with D-register upper-lane clearing.
  MUL is restricted to B/H/S lanes.
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
  All ten Linux C fixtures and PIE also pass as RV64IMC guests.
- Checked RISC-V word/doubleword LR/SC and nine AMOs, sign-extended word
  returns, conservative single-thread reservations, aliases and permission faults.
  A source-built atomic fixture passes both interpreter and JIT modes.
- A bounded RISC-V F/D transfer, arithmetic, fused multiply-add, compare,
  classify, integer and S/D cross-format conversion subset, NaN-boxed single
  values, compressed D transfers, and Zicsr access to `fflags`, `frm` and
  `fcsr`. A hard-float guest verifies these in interpreter/JIT.
- A refreshed README and published [project site](https://othmaneblial.github.io/universe/)
  with recorded real guest examples and a flight-manual documentation page.

## Next compatibility milestones

1. Broader x86 integer/SIMD decoding, remaining RISC-V F/D/CSR coverage, plus broader
   AArch64 coverage.
2. Larger static musl programs and full BusyBox applets. The current build enables
   a small tested subset. BusyBox shell needs process creation, exec/wait, signal,
   terminal and additional filesystem semantics; none is currently claimed.
3. Broader Windows APIs, loader search/flags and reentrancy, thread notifications
   and exception handling. Add real source-built API fixtures
   before advertising support.
4. Broader dynamic Linux applications, hard-float RISC-V guests and glibc. The current
   three-CPU musl fixture delegates linking to guest ldso code running on our engine;
   expand source-built library and application regressions before wider claims.
5. macOS dyld, shared libraries, fixups/TLS and broader ABI coverage. The current
   Mach-O guests link no libraries; ordinary LibSystem applications remain unsupported.
6. JIT flag operations, memory fast paths and block linking. Measure each change;
   the current JIT does not speed up every architecture or workload.
7. A separately reviewed sandbox with explicit policies and threat model.

Continue by finding the first unsupported behavior in a real binary, implementing
its general platform semantics, adding a regression and retrying. Never special
case program names. Full OS or ISA compatibility remains a long-term goal.
