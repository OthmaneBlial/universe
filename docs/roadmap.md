# Roadmap

Completed: real foreign x86-64 ELF execution on ARM64 macOS, compiled libc-free
C, reusable UIR and guest memory, RV64IM and AArch64 execution, syscall tracing,
inspection/IR disassembly, local regression checks and debugger.

Next milestones:

1. Real basic PE32+ console execution with a small kernel32 compatibility layer.
2. A bounded ARM64-host JIT with interpreter fallback and differential checks.
3. Mach-O inspection with clear parsing-versus-execution status.
4. Static musl and then BusyBox: identify the first unsupported instruction or
   syscall, add general semantics and a regression, retry. Never special-case
   program names. SIMD, TLS, runtime startup and additional syscalls are likely
   prerequisites. The BusyBox shell additionally needs process and filesystem
   semantics well beyond the current runtime.
5. Broader instruction coverage, RISC-V C/A/F/D, Windows APIs and macOS ABI.
6. Linux dynamic linking: relocations, symbols, GOT/PLT and TLS, with separate
   loader and security review. Do not treat inspection as compatibility.
7. Optimizing JIT, block linking and measured guest-memory fast paths.
8. A separately reviewed sandbox with explicit policies and threat model.

The north star remains one CLI that detects executable format, guest CPU and OS
ABI and chooses the supported execution path. This release is experimental;
full OS, ISA or application compatibility is not an achieved milestone.
