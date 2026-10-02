# Debian glibc compatibility probe

The checksum-pinned Debian GNU Hello **runs unchanged** with its glibc 2.41
loader and shared library. Both the interpreter and ARM64-host JIT print
`Hello, world!` and exit successfully on the tested Apple M2/macOS host.
The guest loader maps glibc, initializes single-thread TLS and performs its
own relocations and CPU feature selection on UNIVERSE's execution engine.

The optional probe passes **24 application/profile checks**, twelve per engine:
default output with loader/TLS/syscall tracing; traditional, custom ASCII,
empty, multiline and repeated greetings; help and version output; extra-operand
and unknown-option behavior; C-locale Unicode rejection; and default file denial.
The separate coreutils profile below adds 94 checks. Together with the 334
static Linux and 34 Windows workflows, these are **486 downloaded-app checks**.
Broader glibc and Linux compatibility remains open.

The test verifies SHA-256 pins for the extracted app, loader and libc before
running. This particular Debian executable has an empty version literal and
returns zero after its usage routine, including option errors; the regression
records those package-specific bytes and status. Its C locale rejects the
Unicode greeting with the app's own conversion error and status 1. Locale data
and broader Unicode/glibc application behavior require separate evidence.

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
# Hello, world! (exit status 0)
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

## Unchanged GNU coreutils

The optional `--coreutils` profile fetches checksum-pinned Debian coreutils
**9.7-3** and its original libraries into a separate private sysroot:

```sh
python3 scripts/debian.py --coreutils
python3 tests/coreutils.py
printf 'z\na\nb\n' | ./zig-out/bin/universe --allow-files \
  --sysroot artifacts/debian-coreutils-amd64/sysroot \
  artifacts/debian-coreutils-amd64/sysroot/usr/bin/sort
```

The 47 cases per engine cover `printf`, `cat`, `sort`, `wc`, `head`, `base64`,
`sleep`, `sha256sum`, `ls` and `stat`. Python independently checks binary bytes,
sorting, counts, Base64, hashes, directory names, inode/mode/size data, symlink
following and volume block/name sizes. The suite also checks application error
exits and default file denial. Guest binaries and libraries are unchanged.

Directory listings cover simple/hidden names and a long numeric listing. The
long listing uses Linux `llistxattr`; on macOS, only native `user.*` attributes
are exposed, so unrelated Apple metadata is not presented as Linux metadata.
Attribute reads/writes, ACL translation, explicit stat cache policies and
general coreutils compatibility remain open.
On macOS, volume type is reported as unknown instead of a fabricated Linux type.
All fifteen package pins are in the existing fetcher; downloaded inputs stay
under ignored `artifacts/` and never enter the release bundle.

## CPU and syscall behavior

`RDTSC` returns a virtual 1 GHz counter from the host monotonic clock in
zero-extended EDX:EAX. It preserves flags; it does not measure host CPU cycles.
`CPUID` returns the fixed virtual instruction vendor `GenuineIntel`, family 6,
basic maximum leaf 1 and extended maximum leaf `0x80000001`. Leaf 1 exposes
FPU, TSC, CX8, CMOV, MMX, FXSR, SSE, SSE2 and CX16; the extended leaf exposes
long mode and SYSCALL. See [the baseline inventory and ceilings](x86-baseline.md).
The identity is synthesized independently of the host. Newer ISA families
remain unadvertised.

The earlier `UNIVERSECPU!` vendor caused another discovery problem: glibc's
unknown-vendor path skips leaf 1. Its
[CPU feature initialization](https://github.com/bminor/glibc/blob/glibc-2.41/sysdeps/x86/cpu-features.c)
now recognizes the fixed virtual profile and checks the advertised features.

The real loader exposed missing legacy `MOVLPS/MOVHPS/MOVLPD/MOVHPD`,
`MOVHLPS/MOVLHPS` and short accumulator `XCHG` forms. These now execute with
exact-width memory access and destination-lane preservation. An untaken
32-bit `CMOV` also clears the destination's upper 32 bits, while still checking
its source memory, as specified by the
[Intel instruction manual](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html).

Linux `set_robust_list` and `rseq` return **ENOSYS** on all three guest CPUs.
Their robust owner-death recovery and restartable-sequence semantics are unsupported, so
libc must take its fallback paths. Other unknown syscalls still produce an
explicit engine fault. No success is fabricated for these thread facilities.

Paired compare/exchange and original MMX now pass exact scalar guest oracles.
Bounded `FXSAVE/FXRSTOR` preserve x87/MMX and all 16 XMM registers, with
`LDMXCSR/STMXCSR` supporting all four rounding modes, DAZ/FTZ and exception
masks/status. The implemented SSE arithmetic, comparisons and conversions now
use these controls and stop on unmasked conditions. Standard Linux guest signal
handlers execute, while CPU fault-to-signal delivery remains unsupported.
x87 arithmetic/comparisons have rational/bit oracles and documented numeric
limits. glibc's
[ISA-level check](https://github.com/bminor/glibc/blob/glibc-2.41/sysdeps/x86/get-isa-level.h)
requires CMOV, CX8, FPU, FXSR, MMX, SSE and SSE2 together. The probe uses no feature overrides, GNU-property patches or guest-code changes.

Separately, the unchanged official jq 1.8.2 Linux binary uses static glibc and
runs the bounded workflows in [public-apps.md](public-apps.md). This does not
establish general glibc compatibility. x87 transfers, controls, basic arithmetic, FXTRACT,
FPREM/FPREM1, FSCALE and legacy FLDENV/FNSTENV/FRSTOR/FNSAVE now execute.
Both protected environment layouts and FBLD/FBSTP packed BCD transfers are
covered. F2XM1 now covers exponential-minus-one over `[-1, 1]`, including
tiny extended inputs and deferred exceptions. FYL2X covers scaled base-two
logarithms across the extended range, retaining neighbors of one and tiny
products. FYL2XP1 covers scaled `log2(1 + x)` over its specified range near zero,
including products of two minimum subnormals. FPATAN covers full-range angles,
signed-zero/infinity quadrants and tiny ratios. FSIN and FCOS cover the strict
finite range below 2^63, with large-angle reduction, tiny corrections and C2
range signaling. FPTAN and FSINCOS now commit both stack outputs, retaining
pole neighbors, tiny corrections and gradual/biased underflow. These additions
retain the numeric and fault-delivery limits in the compatibility map.
The dynamic Hello result is a checked application workflow; broader
application compatibility remains open.
