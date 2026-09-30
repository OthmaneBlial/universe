# Local benchmark evidence

Measured 2026-09-30T19:24:44.899887+02:00 on Apple M2, macOS-26.6-arm64-arm-64bit-Mach-O; Zig 0.16.0, runtime ReleaseSafe, guest/native C `-O1`.

100,000 iterations of the same 64-bit xorshift-and-sum C workload. All outputs equal `ba690c62ba5fb61d`. Each measurement starts a new process. One warm-up run is discarded; the median uses seven runs. Runtime statistics also use seven-run medians. Wall time includes startup, guest loading, JIT compilation, execution and shutdown. Guest machine code differs between architectures.

| Execution | Median wall ms | Instructions | JIT compile ms | Cached block hits |
|---|---:|---:|---:|---:|
| native host | 3.370 | — | 0.000 | — |
| x86_64 interpreter | 234.240 | 1300238 | 0.000 | — |
| x86_64 jit | 311.595 | 1300238 | 0.059 | 300010 |
| riscv64 interpreter | 144.318 | 1000172 | 0.000 | — |
| riscv64 jit | 57.914 | 1000172 | 0.072 | 200041 |
| aarch64 interpreter | 114.669 | 800189 | 0.000 | — |
| aarch64 jit | 168.131 | 800189 | 0.048 | 100013 |

| Runtime | Execution ms | Guest instructions/s | Guest mapped KiB | JIT cache KiB |
|---|---:|---:|---:|---:|
| x86_64 interpreter | 226.836 | 5732062 | 17420 | 0 |
| x86_64 jit | 303.750 | 4280619 | 17420 | 192 |
| riscv64 interpreter | 137.396 | 7279484 | 17420 | 0 |
| riscv64 jit | 51.274 | 19506417 | 17420 | 272 |
| aarch64 interpreter | 108.090 | 7402988 | 17420 | 0 |
| aarch64 jit | 160.795 | 4976454 | 17420 | 176 |

Hello World cold process medians (startup + loading + trivial execution + shutdown): x86_64 6.328 ms, riscv64 6.551 ms, aarch64 6.212 ms. This is an end-to-end startup baseline, not an isolated loader timer.

Native runs the same C algorithm compiled for the actual host OS/CPU and uses host libc for output. It is an algorithm baseline, not native execution of the foreign ELF on this Mac. The JIT translates only register blocks and interprets unsupported operations. These numbers describe this microbenchmark only; they are not a claim about arbitrary application performance.

Runtime `elapsed_ns` starts after ELF/PE loading and stack setup. JIT `compile_ns` includes decoding/emission/cache setup, not just machine-code generation. `guest_memory_bytes` is mapped guest backing storage, not host RSS. JIT code cache size is allocated host pages. No peak-RSS or whole-ISA throughput claim is made.

Reproduce: `./scripts/check.sh && python3 scripts/benchmark.py`. Raw JSON is written to ignored `artifacts/benchmark.json`.
