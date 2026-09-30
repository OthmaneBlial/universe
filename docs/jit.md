# ARM64-host JIT

`universe --jit program` uses native ARM64 machine code for eligible UIR register
blocks. It works on the verified ARM64 macOS host; other host architectures fail
with `UnsupportedJitHost`. Linux ARM64 compilation is checked separately.

The emitter loads guest registers into two caller-saved ARM64 scratch registers,
performs moves or integer add/subtract/logical/multiply/shift operations, and
stores results back to the guest register array. It preserves architecture zero
registers, 32-bit writes and RISC-V word sign extension. x86 operations that
modify flags, memory accesses, branches, vectors and syscalls remain interpreted.
A block has at most 32 guest instructions; the cache has at most 128 pages. There
is no optimizing register allocator, block chaining or whole-ISA JIT claim.

The cache uses the native OS page size (16 KiB on the verified Mac) for allocation
and accounting. Host pages are created RW, filled and instruction caches synchronized, then
changed to RX before use. No host code page is RWX. Guest code writes, mapping
changes, protection changes and unmaps invalidate cached blocks. Data-only writes
do not invalidate code. Each cached execution still checks guest execute access.
Guest addresses are never dereferenced by emitted native instructions; only a
runtime-owned register-array pointer is passed to the generated code.

Single stepping and instruction tracing use the interpreter. JIT execution obeys
the same instruction/time limits. Unit tests compare native block results to the
UIR interpreter and check invalidation after code mutation and protection
changes. Integration tests compare outputs/status for all guest architectures,
Windows and musl. The microbenchmark also compares against an independent native
C result, which caught a zero-count shift bug in the interpreter.

See [measured results](../benchmarks/results.md). This JIT is faster on the measured
RV64IM workload, slower on the measured x86/AArch64 workloads. Keep it opt-in.
