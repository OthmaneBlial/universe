# Local benchmark evidence

Measured 2026-10-12T22:33:59.812755+02:00 on Apple M2, macOS-26.6-arm64-arm-64bit; Zig 0.16.0, runtime ReleaseSafe, guest/native C `-O1`.

100,000 iterations of the same 64-bit xorshift-and-sum C workload. All outputs equal `ba690c62ba5fb61d`. Each measurement starts a new process. One warm-up run is discarded; the median uses seven runs. Runtime statistics also use seven-run medians. Wall time includes startup, guest loading, JIT compilation, execution and shutdown. Guest machine code differs between architectures.

| Execution | Median wall ms | Instructions | JIT compile ms | Cached block hits |
|---|---:|---:|---:|---:|
| native host | 3.887 | — | 0.000 | — |
| x86_64 interpreter | 104.985 | 1300238 | 0.000 | — |
| x86_64 jit | 240.747 | 1300238 | 0.072 | 300010 |
| riscv64 interpreter | 89.606 | 1000172 | 0.000 | — |
| riscv64 jit | 60.631 | 1000172 | 0.085 | 200041 |
| aarch64 interpreter | 77.126 | 800189 | 0.000 | — |
| aarch64 jit | 139.868 | 800189 | 0.069 | 100013 |

| Runtime | Execution ms | Guest instructions/s | Guest mapped KiB | JIT cache KiB |
|---|---:|---:|---:|---:|
| x86_64 interpreter | 88.137 | 14752465 | 17420 | 0 |
| x86_64 jit | 222.801 | 5835871 | 17420 | 192 |
| riscv64 interpreter | 72.987 | 13703427 | 17420 | 0 |
| riscv64 jit | 44.226 | 22615023 | 17420 | 272 |
| aarch64 interpreter | 60.804 | 13160137 | 17420 | 0 |
| aarch64 jit | 123.125 | 6498997 | 17420 | 176 |

Hello World cold process medians (startup + loading + trivial execution + shutdown): x86_64 18.781 ms, riscv64 17.708 ms, aarch64 17.294 ms. This is an end-to-end startup baseline, not an isolated loader timer.

Native runs the same C algorithm compiled for the actual host OS/CPU and uses host libc for output. It is an algorithm baseline, not native execution of the foreign ELF on this Mac. The JIT translates only register blocks and interprets unsupported operations. These numbers describe this microbenchmark only; they are not a claim about arbitrary application performance.

Runtime `elapsed_ns` starts after ELF/PE loading and stack setup. JIT `compile_ns` includes decoding/emission/cache setup, not just machine-code generation. `guest_memory_bytes` is mapped guest backing storage, not host RSS. JIT code cache size is allocated host pages. No peak-RSS or whole-ISA throughput claim is made.

Reproduce: `./scripts/check.sh && python3 scripts/benchmark.py`. Raw JSON is written to ignored `artifacts/benchmark.json`.
