# Virtual x86-64 baseline

UNIVERSE implements guest instructions in its own interpreter and ARM64-host
JIT. Its fixed CPUID profile exposes FPU, TSC, CX8, CMOV, MMX, FXSR, SSE, SSE2
and CX16. Leaf 1 returns EAX `0x600`, EBX `0x10000`, ECX `0x2000` and EDX
`0x07808111`; the signature describes a virtual family 6 CPU. The instruction
vendor is `GenuineIntel`, with basic maximum leaf 1. Extended leaf
`0x80000001` exposes long mode and SYSCALL. Other leaves return zero.

This identity is fixed on every host. glibc 2.41 only queries leaf 1 for a
recognized vendor: its unknown-vendor path passes a null family pointer to
`get_common_indices`, which skips that query. See glibc's
[CPU feature initialization](https://github.com/bminor/glibc/blob/glibc-2.41/sysdeps/x86/cpu-features.c)
and [baseline requirements](https://github.com/bminor/glibc/blob/glibc-2.41/sysdeps/x86/get-isa-level.h).

## Instruction inventory and checks

The inventory follows the user-mode x87, MMX, SSE and SSE2 groups in
[Intel Volume 1, sections 5.3–5.6](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html).
Decoder coverage and an executed app are different evidence; numeric and ABI
ceilings remain documented in [compatibility.md](compatibility.md).

| Group | Shared implementation | Runnable checks |
|---|---|---|
| x87 transfers, integer/BCD conversions, constants, stack/control operations | `src/x87.zig` | `tests/x87.py`, `tests/x87-environment.py` |
| x87 arithmetic, comparisons/conditional moves, remainders, scaling and transcendental operations | `src/x87.zig` | `tests/x87-arithmetic.py` |
| Original MMX, CX8/CX16 and x87 aliasing | `src/interpreter.zig`, `src/vector.zig` | `tests/x86-baseline.py` |
| FXSAVE/FXRSTOR and MXCSR | `src/x86_state.zig`, `src/x86_float.zig` | baseline, MXCSR and environment oracles; unit fault/state checks |
| SSE/SSE2 transfers, masks, integer arithmetic, packing, shuffle, unpack and shifts | `src/vector.zig` | `tests/integration.py`, `tests/x86-mmx-float.py` |
| Packed/scalar floating arithmetic, comparisons and conversions | `src/vector.zig`, `src/x86_float.zig` | `tests/x86-mxcsr.py`, mixed MMX oracle, integration fixtures |
| Reciprocal and reciprocal square root | `src/x86_float.zig` | `tests/x86-reciprocal.py` |
| Streaming/masked stores, logical ANDN, prefetch and ordering hints | `src/vector.zig`, x86 decoder | `tests/x86-stream.py`, unit checks |

The SSE2 shift fixture executes all 256 immediates of both PSLLDQ and PSRLDQ
using XMM9, with a Python byte-slice oracle in both engines. Packed legacy
memory alignment is checked across 83 instruction forms and all 16 offsets;
faults preserve CPU/FP state and destination bytes. Narrow scalar, eight-byte
conversion and MMX operands retain their instruction-specific rules.

Run the complete local gate with `sh scripts/check.sh`. The optional unchanged
Debian application check is documented in [debian.md](debian.md).

## Profile ceilings

SSE3, SSSE3, SSE4.1, SSE4.2, POPCNT and LAHF/SAHF are not advertised as complete
families. XSAVE, OSXSAVE, AVX and higher ISA levels are absent. Selected
instructions from some later families execute through the documented subsets.
CLFLUSH is unsupported and its separate CLFSH bit is clear; Intel defines that
[availability bit independently](https://www.intel.com/content/dam/www/public/us/en/documents/manuals/64-ia-32-architectures-software-developer-vol-2a-manual.pdf).

Guest memory operations are serialized. Cache hints and fences use that model;
cache hierarchy and hardware timing are not simulated. Unmasked CPU FP faults
stop execution; conversion of CPU faults into Linux signals remains open.
x87 transcendental approximations and condition flags retain the limits in
the compatibility map. Native x86 hardware parity and universal correct
rounding are unverified. This profile establishes instruction availability,
not general Linux, Windows or application compatibility.
