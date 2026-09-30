# Roadmap

## v0.1.0 delivered

- Real foreign Linux x86-64 ELF execution on ARM64 macOS.
- Eight libc-free C fixtures for x86-64, RV64IM and AArch64, covering arithmetic,
  recursion, stack, BSS, heap/mmap, files, directory pagination, arguments,
  environment, time, randomness, standard input/error and nonzero exits.
- Static x86-64 musl Hello World; optional source-built BusyBox echo/cat/ls.
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
- A refreshed README and published [project site](https://othmaneblial.github.io/universe/)
  with recorded real guest examples and a flight-manual documentation page.

## Next compatibility milestones

1. Broader x86 integer/SIMD decoding, RISC-V C/A/F/D and AArch64 coverage.
2. Larger static musl programs and full BusyBox applets. The current build only
   enables echo/cat/ls. BusyBox shell needs process creation, exec/wait, signal,
   terminal and additional filesystem semantics; none is currently claimed.
3. Windows file/heap/command-line APIs, DLL exports/loading, TLS and exception
   handling. Add real source-built API fixtures before advertising support.
4. Linux dynamic linking: ELF relocations, symbols, GOT/PLT and TLS initialization
   beyond x86 arch_prctl. Keep the first implementation independently testable.
5. Mach-O loading and a macOS ABI, with dyld/relocations evaluated separately.
6. JIT flag operations, memory fast paths and block linking. Measure each change;
   the current JIT does not speed up every architecture or workload.
7. A separately reviewed sandbox with explicit policies and threat model.

Continue by finding the first unsupported behavior in a real binary, implementing
its general platform semantics, adding a regression and retrying. Never special
case program names. Full OS or ISA compatibility remains a long-term goal.
