# Roadmap

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
  subset. Architecture-specific Linux open flags and symlink rejection.
- Restartable bounded x86 string operations, direction control, ROL/ROR and
  TZCNT/LZCNT, with width, flag and memory-fault regressions.
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
- SSE/SSE2 `ADD/SUB/MUL/DIV/SQRT` cover all 20 packed/scalar single/double
  precision forms, checked against exact finite guest results and preserved
  scalar upper lanes.
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
- Linux GNU and musl host-target builds, using `statx` metadata and shared
  target-native time/file-stat types instead of opaque libc structures.
- Library-free x86-64/AArch64 Mach-O execution, checked segments/BSS/maximum
  protections, initial stack and a Darwin BSD console/file/private-mapping subset.
  Five source-built guests per CPU and matching-host syscall source comparisons.
- RISC-V compressed integer decoding with mixed two/four-byte boundaries,
  hints/reserved encodings, PC+2 links and JIT accounting/invalidation checks.
  All nine Linux C fixtures and PIE also pass as RV64IMC guests.
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
3. Broader Windows APIs, loader search/flags and reentrancy, TLS and exception
   handling. Add real source-built API fixtures before advertising support.
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
