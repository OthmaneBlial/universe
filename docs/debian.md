# Debian glibc compatibility probe

GNU Hello **does not run yet**. The unchanged Debian x86-64 loader now maps
its glibc dependency, initializes single-thread TLS and exits through guest
Linux `exit_group` with glibc's own diagnostic:

```text
/lib/x86_64-linux-gnu/libc.so.6: CPU ISA level is lower than required
```

Exit status is **127**, stdout is empty, and no UNIVERSE engine fault occurs.
This is a checked compatibility boundary, not a successful application run.
Both the interpreter and ARM64-host JIT fallback path produce this result.

## Reproduce locally

Requires Python 3.12 or newer for filtered tar extraction, native `ar`, and a
built UNIVERSE binary. The optional fetcher verifies Debian SHA-256 checksums
before extracting package data into an ignored private sysroot. It does not
install packages, run package scripts or patch guest binaries. The download is
separate from the default local check suite.

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/debian.py
python3 tests/debian.py
./zig-out/bin/universe --allow-files --sysroot artifacts/debian-hello-amd64/sysroot \
  artifacts/debian-hello-amd64/sysroot/usr/bin/hello
# Expected: diagnostic above and exit status 127, not Hello World.
```

Pinned Debian trixie amd64 packages:

| Package | Version |
|---|---|
| hello | 2.10-5 |
| libc6 | 2.41-12+deb13u4 |
| libgcc-s1 | 14.2.0-19 |

The full archive paths and SHA-256 values are in [scripts/debian.py](../scripts/debian.py),
verified against Debian's official
[trixie amd64 package index](https://deb.debian.org/debian/dists/trixie/main/binary-amd64/Packages.xz).
[Debian's libc6 download page](https://packages.debian.org/trixie/amd64/libc6/download)
also publishes the glibc archive checksum. If a pinned archive leaves the
Debian mirror, fetch fails rather than silently switching versions. No Debian
binary or source archive is included in the repository or release package.

## CPU and syscall behavior

`RDTSC` returns a virtual 1 GHz counter from the host monotonic clock in
zero-extended EDX:EAX. It preserves flags; it does not measure host CPU cycles.
`CPUID` returns the fixed vendor `UNIVERSECPU!`, basic maximum leaf 1 and
extended maximum leaf `0x80000001`. Leaf 1 advertises TSC, CX8, CMOV, MMX and CX16; the
extended leaf advertises long mode and SYSCALL. Unsupported leaves return zero.
No host CPU features are copied, and partial SIMD support is not advertised as
a complete SSE family.

The real loader exposed missing legacy `MOVLPS/MOVHPS/MOVLPD/MOVHPD`,
`MOVHLPS/MOVLHPS` and short accumulator `XCHG` forms. These now execute with
exact-width memory access and destination-lane preservation. An untaken
32-bit `CMOV` also clears the destination's upper 32 bits, while still checking
its source memory, as specified by the
[Intel instruction manual](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html).

Linux `set_robust_list` and `rseq` return **ENOSYS** on all three guest CPUs.
Their thread cleanup and restartable-sequence semantics are unsupported, so
libc must take its fallback paths. Other unknown syscalls still produce an
explicit engine fault. No success is fabricated for these thread facilities.

Paired compare/exchange and original MMX now pass exact scalar guest oracles.
Bounded `FXSAVE/FXRSTOR` preserve x87/MMX and all 16 XMM registers, with
`LDMXCSR/STMXCSR` limited to reset controls and stored status. The remaining
baseline needs x87 arithmetic and complete SSE control/exception semantics
before advertising FPU, FXSR, SSE and SSE2. glibc's
[ISA-level check](https://github.com/bminor/glibc/blob/glibc-2.41/sysdeps/x86/get-isa-level.h)
requires CMOV, CX8, FPU, FXSR, MMX, SSE and SSE2 together. The probe uses no feature overrides, GNU-property patches or guest-code changes.
