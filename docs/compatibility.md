# Current compatibility

Every execution claim below is about reproducible fixtures or pinned public apps, not a complete ISA,
OS ABI or arbitrary applications. The primary verified host is **macOS 26.6
ARM64 (Apple M2)**. Linux GNU-libc x86-64/ARM64 builds are cross-compiled; execution there
has not been measured in this session.

| Guest | Level | Evidence |
|---|---|---|
| Linux x86-64 static ELF64 | Executed | Assembly, ten libc-free C fixtures, static musl Hello World |
| Official jq 1.8.2 / ripgrep 15.2.0 / 7-Zip 26.03 / fd 10.5.0 / BusyBox 1.35.0 Linux x86-64 binaries | Verified CLI workflows | 236 checks: unchanged upstream static binaries, JSON/text processing, file/directory/symlink searches, Unicode/filter/ignore/NUL paths, two-thread traversal, ZIP/7z creation and extraction, threaded 7z round trips, hashing, recursive ZIP folders, BusyBox utilities/file copies, virtual identity, selected built-in shell scripts and error exits in both engines; see [public-apps.md](public-apps.md) |
| Official Windows 7-Zip 26.03 x86-64 release | Verified CLI workflows | Unchanged PE32+ binary: 34 archive/hash/error checks across both engines, including real C++ cleanup/catch and application exit 2 on denied read/write access; see [public-apps.md](public-apps.md) |
| Linux RISC-V64 ELF64 | Executed subsets | Ten RV64IM/IMC libc-free C fixtures and word/doubleword atomics; separate hard-float fixture covers selected F/D transfers, five-mode arithmetic, integer conversions, comparisons, classification, sign injection, compressed transfers and Zicsr fflags/frm/fcsr |
| Linux AArch64 static ELF64 | Executed | Ten libc-free C fixtures, NEON arithmetic/logic/compare checks and a scalar/native ARM64 TBL/TBX/MLA/MLS byte oracle |
| Linux x86-64 / AArch64 / RISC-V64 pthreads | Executed fixture | Guest musl mutexes, condition waits, joins, TLS, preemption, timed waits, scheduler-backed sleeps and exact blocking pipe transfers in both engines; see [linux-threads.md](linux-threads.md) |
| Windows x86-64 PE32+ | Executed subsets | Terminal input/control callbacks, shared file views, directory/link reparse metadata, file/stream enumeration, loaded module paths, UTF-8/UTF-16 conversion, virtual CPU/memory and disk-space queries, file mutations/metadata/times, calendar/local clocks, command lines, memory, guest DLLs/TLS, OLEAUT32/USER32/ADVAPI32 subsets, legacy CRT and single-thread events/semaphores/waits/locks |
| macOS Mach-O64 x86-64/ARM64 | Executed | Five library-free C fixtures: console, argv/env, memory and files |
| BusyBox 1.37.0 static x86-64 | Experimental applets | Optional source build and separate app regression checks |
| SQLite 3.53.4 static x86-64 | Experimental batch CLI | Queries, persisted transactions, rollback, delete/truncate journals, VACUUM, native reopen and lock contention |
| Debian GNU Hello 2.10-5 / glibc 2.41 x86-64 | Rejected CPU baseline | Unchanged loader maps glibc, initializes TLS and exits 127 with its ISA-level diagnostic; see [debian.md](debian.md) |
| Linux x86-64 / AArch64 / RISC-V64 LP64 dynamic ELF64 / PIE | Experimental fixture | Upstream musl 1.2.5 guest linker, separate DSO, constructor and TLS |

## Instructions

x86: MOV/MOVZX/MOVSX/MOVSXD, LEA, PUSH/POP/LEAVE, PUSHFW/PUSHFQ,
ADD/SUB/ADC/SBB/INC/DEC/NEG, logical arithmetic, CMP/TEST, SHL/SHR/SAR, ROL/ROR,
IMUL/MUL/DIV/IDIV, JMP/Jcc/CALL/RET, SETcc/CMOVcc/XCHG/XADD/CMPXCHG/CMPXCHG8B/CMPXCHG16B,
BSF/BSR, TZCNT/LZCNT, POPCNT, BSWAP, BT/BTS/BTR/BTC, CBW/CWDE/CDQE and CWD/CDQ/CQO,
MOVS/STOS/LODS/CMPS/SCAS, REP/REPE/REPNE, CLD/STD,
NOP/PAUSE/ENDBR64, CPUID, RDTSC and SYSCALL. LFENCE/MFENCE/SFENCE are ordering
no-ops in the serialized guest CPU model. PREFETCHNTA/T0/T1/T2 are
cache hints without target-memory access. RDSSPD/Q preserves registers while
CET shadow stacks are disabled. REX, ModR/M, SIB, RIP/EIP-relative, FS/GS-based addresses
and 8/16/32/64-bit operands. Short accumulator XCHG forms honor 16/32/64-bit
widths and REX.B registers. Untaken 32-bit CMOV clears the destination upper
half and still checks source memory. CPUID reports a conservative virtual CPU
(TSC/CX8/CMOV/MMX, CX16 and extended SYSCALL/long-mode bits); unsupported leaves return
zero. RDTSC uses a virtual 1 GHz monotonic counter, not native CPU cycles.
PUSHFW/PUSHFQ save the modeled CF/PF/AF/ZF/SF/DF/OF flags and fixed bit 1
using checked two/eight-byte stack writes; faults preserve RSP, flags and
destination bytes. RF/VM and unmodeled system/control flags are zero in this
virtual profile. POPF, trap-flag delivery and privileged flag controls remain
unsupported. ADD/ADC/SUB/SBB/CMP/INC/DEC/NEG, XADD and CMPXCHG now track
auxiliary carry. Defined arithmetic and rotate flags commit only after a
successful destination write. Undefined AF after logical operations, shifts
and multiplication remains unchanged in our profile. POPCNT, PTEST and
completed SSE comparisons clear AF; x87 EFLAGS comparisons clear it alongside
their existing OF/SF behavior. Native full-RFLAGS parity is unverified.
Address-size overrides wrap ModR/M and SIB offsets to 32 bits before adding
FS/GS bases; near calls keep 64-bit targets and stack addresses.
`REP RET` (`F3 C3`) uses ordinary near-return behavior and preserves RCX/flags.
XADD stages flags/register writes until the destination access succeeds, including aliases.
Supported LOCK memory RMW instructions execute
atomically with respect to other serialized Linux guest threads.
Paired compare/exchange writes memory on success and failure, changes only ZF,
and checks the complete operand before changing state. CMPXCHG16B requires
16-byte alignment; failed CMPXCHG8B zero-extends EAX/EDX. Ordinary memory
CMPXCHG also performs writeback on a failed comparison.

Original MMX: MOVD/MOVQ, EMMS, PADD/PSUB B/W/D, signed/unsigned saturating
byte/word addition/subtraction, PCMPEQ/PCMPGT B/W/D, PAND/PANDN/POR/PXOR,
PACKSSWB/PACKSSDW/PACKUSWB, low/high PUNPCK BW/WD/DQ, PMULLW/PMULHW/PMADDWD,
and register/memory-count or immediate PSRL W/D/Q, PSRA W/D and PSLL W/D/Q.
Vector memory operands use exactly eight bytes; MOVD uses four. MMX shares
the physical x87 register data.
MMX resets TOP and marks all tags valid; destination writes set the upper
16 x87 bits to ones. EMMS clears tags and TOP, preserving register data.
Pending unmasked x87 exceptions stop MMX before state changes. MOVNTQ and
MASKMOVQ add checked eight-byte streaming stores. MOVDQ2Q copies the low XMM
quadword to MMX; MOVQ2DQ copies MMX to XMM and clears the upper quadword.
Both register-only bridge forms enter MMX state and honor pending x87 faults.
SSE/SSE2 MMX forms also include PADDQ/PSUBQ, PMULUDQ/PMULHUW, PAVGB/W,
PMINUB/PMAXUB, PMINSW/PMAXSW, PSADBW, PSHUFW, PINSRW, PEXTRW and PMOVMSKB.
Unsigned averages round up; PSADBW sums eight unsigned byte differences and
clears the other result bits. PMULUDQ multiplies only the low unsigned dwords.
Binary and shuffle memory sources read eight unaligned bytes; PINSRW reads
exactly two. PSHUFW uses four two-bit selectors, while PINSRW/PEXTRW use
the low two immediate bits and ignore the rest. General-purpose register
fields honor REX extensions; MMX fields ignore them. PEXTRW/PMOVMSKB clear
all upper destination bits, preserve physical x87 data and still enter MMX
state. All 15 forms preserve MXCSR and FLAGS, and pending x87 exceptions
precede source reads or destination writes.

SSSE3 MMX forms include PSHUFB, PALIGNR, PABS/PSIGN B/W/D, PHADD/PHSUB W/D/SW,
PMADDUBSW and PMULHRSW. PSHUFB masks each byte index to three bits and uses
the control byte's high bit to select zero. PALIGNR shifts the concatenated
old eight-byte destination/source by the immediate byte count, zeroing bytes
outside the pair; counts of 16 or more return zero but still read/fault on a
memory source. PABS retains the signed minimum as an unsigned result, and
PSIGN negation wraps at the lane width. Saturating horizontal operations and
PMADDUBSW clamp to signed words; PMULHRSW rounds its signed products and
retains `0x8000` for the minimum-times-minimum case. These 16 forms read eight
unaligned memory bytes, ignore MMX REX field extensions, preserve MXCSR/FLAGS
and honor pending x87 faults before any source read or state change. The
other extended-map SIMD forms still require their mandatory `66` prefix.

The [mixed MMX oracle](../tests/x86-mmx-float.py) passes **73,956 result/state
queries and 121 fault exits per engine**: the existing 24,653 rational/bridge
cases plus 49,303 integer cases. Its 102 views cover all 39 implemented bridge,
floating and new integer forms, all 256 immediates, shuffle controls and
zero/selection masks, aliases,
raw physical x87 data and extended scalar results. Immediate tests execute
read-only guest instruction tables; no writable code or external engine is used.
Layouts follow [Intel Volume 2B](https://cdrdv2-public.intel.com/929354/253667-093-sdm-vol-2b.pdf)
and [Volume 3B tables 25-7 and 25-9](https://cdrdv2-public.intel.com/929360/253669-093-sdm-vol-3b.pdf).

x87 stack/data/control subset: FLD/FST/FSTP single/double/raw extended values,
FILD/FIST/FISTP/FISTTP signed 16/32/64-bit conversions, FLD/FST/FSTP ST(i),
FXCH, FFREE, FINCSTP/FDECSTP, FCHS/FABS/FXAM, FLD1/FLDZ, FNOP, FLDCW,
FNSTCW/FNSTSW, FNCLEX/FNINIT and WAIT. Float/integer stores honor all four
control-word rounding modes; loads and stores ignore arithmetic precision control.
FBLD adds exact signed 18-digit packed BCD loads, including negative zero and
the seven unused sign-byte bits. FBSTP rounds to the decimal range using the
control-word rounding mode, ignores precision control and stores ten bytes
before popping. Masked invalid/empty/overflowing conversions store packed BCD
indefinite; unmasked invalid conversions preserve the destination and TOP.
Unmasked precision loss still stores and pops before deferring its fault.
65,613 rational/bit transfer queries per engine include 35,800 BCD cases.
Malformed BCD digits have undefined numeric results in the
[Intel instruction specification](https://cdrdv2-public.intel.com/868140/253666-089-sdm-vol-2a.pdf)
and are excluded from the numeric oracle; native x87 hardware parity remains
unverified.
Masked stack faults produce the negative indefinite value. Unmasked numeric
conditions accrue deferred status; no-wait controls remain usable, and the next
waiting instruction stops with FloatingPointException. Unmasked invalid,
overflow and underflow stores preserve destinations and TOP; unmasked precision
stores still commit and pop.

Basic x87 calculations: FADD/FMUL/FSUB/FSUBR/FDIV/FDIVR, their register pop
forms and signed 16/32-bit FI memory forms; FSQRT and FRNDINT. Addition,
multiplication and division use integer significands with guard/sticky bits,
including the full extended exponent range. Arithmetic honors 24/53/64-bit
precision and all four rounding modes; FRNDINT ignores precision control.
Unmasked pre-computation exceptions preserve results/TOP. Register overflow
and underflow store exponent-biased results before deferring the exception;
precision results also commit, including pop forms. FCOM/FCOMP/FCOMPP,
FICOM/FICOMP, FUCOM/FUCOMP/FUCOMPP, FTST and FCOMI/FUCOMI with their pop
forms implement ordered/unordered comparisons and the modeled EFLAGS.
NaNs, unsupported values and empty stack operands follow checked exception
priority. All eight FCMOV conditions preserve raw values, including signaling
NaNs; empty operands still raise stack faults when the move is untaken. All
seven FLD constants support the rounding control, ignore precision control and
never raise precision loss. FXTRACT separates an extended value into its signed
significand and integer exponent without precision loss, including denormal
normalization, signed zeros, infinities and NaN payloads. It ignores precision
and rounding control; unmasked operand or stack faults preserve both results
and TOP. FPREM and FPREM1 calculate exact remainders with truncated and
nearest-even quotients, ignoring precision/rounding control. Our virtual CPU
uses 32-bit partial reductions when the exponent gap is at least 64; C2 tells
guests to repeat the instruction. Complete reductions expose the quotient's
low three bits. Unmasked underflow stores an exponent-biased result before
deferring its exception. FSCALE multiplies by a power of two after truncating
ST(1) toward zero. It retains full 64-bit significand precision regardless of
precision control; rounding control applies to overflow and gradual underflow.
Unmasked overflow/underflow stores exponent-biased results, or signed infinity/
zero when the result still exceeds the extended range after the bias.
358,129 Fraction/decimal/bit queries cover 90 decoded forms per engine, including
both FXTRACT outputs, full remainder loops and FXTRACT/FSCALE reconstruction.
648 remainder and 252 scaling numeric cases also match the native host
binary64 math library;
native x87 hardware and condition-flag parity remain unverified.
F2XM1 computes `2^ST(0) - 1` over its specified `[-1, 1]` input range.
A normalized 113-bit series retains tiny values without cancellation or loss
of the significand on exponent-biased underflow. It ignores precision control,
honors rounding control and preserves signed zero. Unmasked invalid, empty-stack
and denormal operand faults preserve the destination; precision and underflow results
commit before deferring the exception. Our profile retains C0/C2/C3, which
the ISA leaves undefined. Finite inputs outside the range and infinities have
undefined results in the ISA; our profile retains the operand and these are
excluded from the mathematical oracle. 18,013 new decimal/bit queries per engine,
16 sampled monotonicity sequences and 257 bounded host `expm1` comparisons
(within three binary64 ulps) pass. Universal correct rounding and native x87
numeric/flag parity remain unverified. Domain and exception behavior follow the
[Intel F2XM1 specification](https://cdrdv2-public.intel.com/868140/253666-089-sdm-vol-2a.pdf).

FYL2X computes `ST(1) * log2(ST(0))` and pops the stack after committing its
result. Positive finite ST(0) values span the complete extended range,
including all subnormal leading-bit positions. Centered reduction retains
inputs adjacent to one; normalized ST(1) multiplication preserves tiny results
and exponent-biased underflow. Powers of two have exact integer logarithms.
The 113-bit approximation ignores precision control; rounding control applies
to the approximation. Unmasked invalid, zero-divide and denormal faults preserve both
registers and TOP; precision/overflow/underflow results commit and pop before
deferring their exceptions. NaN priority, signed zeros, infinities and invalid
domains follow the
[Intel FYL2X result table](https://cdrdv2-public.intel.com/868140/253666-089-sdm-vol-2a.pdf).
22,872 new decimal/bit queries per engine, 32 sampled increasing/decreasing
sequences and 384 bounded host `log2` comparisons (within three binary64 ulps)
pass. Another 16 constructed underflow cases retain denormal, underflow and
precision flags even when the approximation appears exact. Nearest results
match Decimal; all rounding modes stay within one subnormal destination step.
C1 follows the approximation's rounding. C0/C2/C3 are retained by our CPU
profile; the ISA leaves them undefined.
Universal correct rounding and native x87 numeric/flag parity remain
unverified.

FYL2XP1 computes `ST(1) * log2(1 + ST(0))` and pops after committing its result.
ST(0) uses the specified range `[-(1 - sqrt(2)/2), +(1 - sqrt(2)/2)]`;
ST(1) spans the complete extended range. The shared 113-bit logarithmic series
avoids forming `1 + ST(0)` and normalizes both operands before multiplying,
retaining tiny arguments and products of two minimum subnormals for gradual
and exponent-biased underflow. Precision control is ignored; rounding control
applies to the approximation. Signed zeros, infinities, NaNs and masked/unmasked
exceptions follow the
[Intel FYL2XP1 result table](https://cdrdv2-public.intel.com/868140/253666-089-sdm-vol-2a.pdf).
Unmasked operand exceptions preserve both registers and TOP; computed precision
and underflow results commit and pop before deferring their exceptions. Numeric
results outside the input domain are undefined in the ISA; our profile retains
ST(1) and still pops, and excludes these inputs from the numeric oracle.
35,353 new decimal/bit queries per engine cover domain boundaries, all subnormal
leading-bit positions, normal/subnormal transitions, every PC/RC field, special
classes, operand/result faults and random extended inputs/multipliers. Both
engines pass 32 sampled increasing/decreasing sequences; 225 bounded host
`log1p` comparisons agree within three binary64 ulps.
C0/C2/C3 are retained by our profile; the ISA leaves them undefined. Universal
correct rounding and native x87 numeric/flag parity remain unverified.

FPATAN computes `atan2(ST(1), ST(0))` across the complete extended operand
range and pops after committing the result. The signs of both operands select
the quadrant, including signed-zero and infinity combinations; zero/zero and
infinity/infinity have defined angles and do not invent division exceptions.
NaN priority and exceptions follow the
[Intel FPATAN result table](https://cdrdv2-public.intel.com/868140/253666-089-sdm-vol-2a.pdf).
Regular angles use the shared 113-bit series with pi/4 reduction. Tiny angles
use normalized integer division and a Taylor approximation with 192 fractional
bits, preserving ratios below binary128's exponent range and the negative
correction below exactly representable ratios. Gradual and exponent-biased
underflow use the shared integer rounding machinery. Precision control is
ignored; rounding control applies. Unmasked operand faults preserve both
registers and TOP; computed precision/underflow results commit and pop before
deferring their exceptions. 29,289 new Decimal/Fraction/bit queries per engine
cover the full operand ranges, all subnormal leading-bit positions, signed-zero
and infinity combinations, reduction and tiny-angle transition neighbors,
every PC/RC field, masked/unmasked faults and random extended inputs.
Both engines pass 48 sampled monotonicity sequences within continuous angle
branches and 1,089 bounded host `atan2` comparisons within three binary64 ulps.
C0/C2/C3 are retained by our profile; the ISA leaves
them undefined. Universal correct rounding and native x87 numeric/flag parity
remain unverified.

FSIN and FCOS compute sine and cosine throughout the specified strict
`-2^63 < ST(0) < 2^63` finite range. Integer reduction uses pi/2 with 256
fractional bits before evaluating a 113-bit series. Small residuals and tiny
inputs use integer Taylor terms with 192 fractional bits, retaining corrections
below representable sine inputs and below cosine's unit magnitude, including
neighbors of pi/2 and pi. Precision control is ignored; rounding control applies.
Finite out-of-range inputs set C2 and preserve ST(0); accepted computations clear
C2. Infinity is invalid, separately from the finite range check. Unmasked
invalid/denormal operand faults preserve ST(0), TOP and the prior C2; computed
precision results commit before deferred exceptions. The
[Intel FSIN/FCOS exception tables](https://cdrdv2-public.intel.com/868140/253666-089-sdm-vol-2a.pdf)
list no underflow exception: tiny sine results use gradual rounding without
raising a new underflow flag or producing an exponent-biased result when
underflow is unmasked. Existing sticky underflow remains intact.
35,250 new independent Decimal/Fraction/bit queries per engine cover every
PC/RC field, all subnormal leading-bit positions, special classes, finite range
boundaries, large angles, pi/2 neighbors, masked/unmasked faults and random
extended inputs. Both engines pass 48 sampled monotonicity sequences and
1,536 bounded host sin/cos comparisons within three binary64 ulps.
C0/C3 are retained by our profile; the ISA leaves them undefined. The mathematical
pi reduction can differ from hardware x87's internal approximation, especially
at large angles. Universal correct rounding and native x87 numeric/flag parity
remain unverified.

FPTAN and FSINCOS now compute both stack results throughout the same strict
finite range below 2^63, given a valid source and a free pushed slot. FPTAN
leaves tangent in ST(1) and pushes one into ST(0); FSINCOS leaves sine in
ST(1) and pushes cosine into ST(0). Both ignore precision control and honor
rounding control. FPTAN divides unrounded 113-bit sine/cosine series, using the
reciprocal form around odd multiples of pi/2. Tiny tangent inputs/residuals
use the shared 192-bit fractional Taylor machinery with a positive correction,
retaining values just above representable inputs.
Unlike FSIN/FCOS, these instructions list underflow: tiny sine/tangent results
use gradual rounding when masked and exponent-biased results when unmasked.
Computed precision/underflow results commit both outputs and decrement TOP
before deferred exceptions; unmasked operand faults preserve both slots and
TOP. Stack faults are checked before numeric range reduction. In our profile,
empty-source faults take priority over occupied-push faults, and masked stack
faults write indefinite to both results. Quieted NaNs are copied to both slots;
FPTAN's pushed one applies to finite accepted inputs. Finite out-of-range values
with a valid stack set C2 and preserve registers/TOP. Completed results clear
C2; unmasked operand faults retain prior C2. C1 follows tangent for FPTAN and
sine for FSINCOS in our profile; C0/C3 remain unchanged. Native condition-flag
parity remains unverified.
37,584 new Decimal/Fraction/bit queries check both FSINCOS outputs, with
48 sampled monotonicity sequences. 38,352 new queries check both FPTAN
outputs, with 16 sampled monotonicity sequences and 768 bounded host
tan comparisons within three binary64 ulps. Full-range and pole-neighbor
numbers, all subnormal leading bits, every PC/RC field, all operand/stack
fault classes and gradual/biased underflow are covered. These are sampled
mathematical/specification checks; universal correct rounding and native x87
numeric/flag parity remain unverified. Broader CPU/SIMD and application
compatibility work remains open; CPUID feature claims stay conservative.

Legacy x87 environments: FLDENV/FNSTENV use 14/28-byte protected-format images;
FRSTOR/FNSAVE use 94/108 bytes including eight logical 80-bit stack slots.
The operand-size override selects the 16-bit layout. Saves classify every
nonempty physical register into the full tag word; restores use tag emptiness
and subsequent saves classify the actual register contents. Environment-only
stores mask exceptions; full saves reset the x87 controls, tags and pointers.
Loads defer newly restored unmasked exceptions to the next waiting instruction.
FSTENV/FSAVE are the corresponding WAIT plus no-wait store sequences.
Unaligned and page-end operands work; checked memory/COW allocation faults
preserve state and destination bytes. XMM registers, MXCSR and EFLAGS are
unchanged. Pointers truncate to the selected layout; 16-bit protected images
have no opcode field, so restores retain the current opcode. Reserved image
padding is zero in our CPU profile. 22,304 exact image/state queries and eight
deferred faults pass per engine. Real-mode images and native x87 hardware parity
remain outside this x86-64 guest profile. Layouts follow
[Intel Volume 1, section 8.1.10](https://cdrdv2-public.intel.com/789574/253665-sdm-vol-1.pdf).

FXSAVE/FXRSTOR support 16-byte-aligned 512-byte operands, raw x87/MMX data,
logical stack slots, abridged tags, both 32/64-bit pointer layouts and all 16
XMM registers. Save preserves bytes 416–511, including the software-owned
tail; checked faults and rejected controls preserve state. LDMXCSR/STMXCSR use
exactly four bytes, including unaligned operands. MXCSR accepts all four rounding
modes, exception masks/status, DAZ and FTZ; reserved high bits fail before state
changes. SSE arithmetic and conversion operations accrue flags and stop on new
unmasked conditions with `SimdFloatingPointException`, preserving destinations.
Guest signal delivery/frames remain unsupported. Full x87/native flag
verification and complete SSE/SSE2 coverage remain open, so CPUID does not advertise FPU,
FXSR, SSE or SSE2.
Layouts and MMX aliasing follow the
[Intel manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html).

SSE/SSE2 plus tested SSSE3 `PSHUFB`, `PSIGNB/W/D`, `PABSB/W/D`, `PMADDUBSW`, `PMULHRSW`, `PHADDW/D/SW`, `PHSUBW/D/SW` and `PALIGNR`: MOVUPS/MOVUPD/MOVAPS/MOVAPD/MOVDQA/MOVDQU,
XORPS/XORPD/PXOR, ANDPS/ANDPD/ANDNPS/ANDNPD, ORPS/ORPD, MOVD/MOVQ, PEXTRW/PINSRW,
PUNPCKLBW/LWD/LDQ/LQDQ and PUNPCKHBW/HWD/HDQ/HQDQ,
PMULLW/PMULHW/PMULHUW/PMULUDQ/PMADDWD, PACKSSWB/PACKSSDW/PACKUSWB,
PAVGB/PAVGW/PSADBW,
PSHUFD/LW/HW, SHUFPS/SHUFPD, UNPCKLPS/LPD/HPS/HPD, MOVMSKPS/MOVMSKPD, PSHUFB, PSIGNB/W/D, PABSB/W/D, PMADDUBSW, PMULHRSW,
PHADDW/D/SW, PHSUBW/D/SW, PALIGNR, PCMPEQB/W/D,
PCMPGTB/W/D, PMOVMSKB, PAND/PANDN/POR, PMINUB/PMAXUB/PMINSW/PMAXSW,
register-count and immediate packed PSRLW/D/Q, PSRAW/D, PSLLW/D/Q, PSRLDQ/PSLLDQ,
modular PADD/PSUB byte, word,
doubleword and quadword lanes, and signed/unsigned saturating byte/word
PADDS/PADDUS/PSUBS/PSUBUS operations. `ADD/SUB/MUL/DIV/SQRT/MIN/MAX` also
support packed/scalar single and double precision, with byte-checked results
and scalar upper-lane preservation. `MIN/MAX` select the second source for NaNs
and equal values, including signed zero. `CMPPS/PD/SS/SD` implement the eight
legacy predicates and produce full-lane masks; nonzero reserved immediate bits
are rejected. `COMISS/UCOMISS/COMISD/UCOMISD` set the compare flags for ordered
and unordered results. `CVTSI2SS/SD`, `CVTSS/SD2SI` and `CVTTSS/SD2SI` cover
signed 32/64-bit scalar conversions; CVT follows the current MXCSR rounding mode,
CVTT truncates and invalid inputs return the architecture's indefinite integer.
Packed `CVTDQ2PS`, `CVTPS2DQ` and `CVTTPS2DQ` convert four 32-bit lanes.
`CVTPS2PD`, `CVTPD2PS`, `CVTDQ2PD`, `CVTPD2DQ` and `CVTTPD2DQ` cover the packed
single/double and double/integer conversions. Integer conversions use
MXCSR or truncating rounding and return indefinite integers for invalid
inputs.

`CVTPI2PS/PD` convert two signed 32-bit lanes from MMX or exact eight-byte
unaligned memory sources. CVTPI2PS uses MXCSR rounding, preserves the upper
XMM quadword and enters MMX state for both sources. CVTPI2PD is exact and
only its MMX register source enters MMX state or takes pending x87 exceptions;
its memory form preserves x87 state even with a pending exception.
`CVTPS/PD2PI` round two floating lanes to signed 32-bit MMX results;
`CVTTPS/PD2PI` truncate regardless of MXCSR rounding. Their memory sources
read exactly eight unaligned bytes for PS or 16 aligned bytes for PD.
Invalid masked results are `0x80000000`; inexact valid results set precision.
DAZ applies to floating inputs; FTZ does not change these integer outputs.
All six conversions preserve FLAGS. Pending x87 faults precede source memory
checks on forms that enter MMX. New unmasked SIMD exceptions update MXCSR
status, stop execution and preserve the destination, physical x87 data,
tags and TOP. Guest signal delivery and native fault-state parity are unverified.
The floating portion of the [mixed MMX oracle](../tests/x86-mmx-float.py)
checks **24,653 exact rational/byte/state queries and 33 fault exits per engine**, including all
eight TOP positions, raw physical x87 data, upper lanes, extended XMM
registers, four rounding modes, DAZ/FTZ, old sticky flags, NaNs, range
boundaries and all eight instruction forms through 14 encoding views.
Semantics follow [Intel Volume 2A](https://cdrdv2-public.intel.com/929353/253666-093-sdm-vol-2a.pdf),
[Volume 2B](https://cdrdv2-public.intel.com/929354/253667-093-sdm-vol-2b.pdf)
and [Volume 3B exception tables 25-4 through 25-6](https://cdrdv2-public.intel.com/929360/253669-093-sdm-vol-3b.pdf).

RCPPS/RCPSS and RSQRTPS/RSQRTSS implement the four legacy single-precision
reciprocal forms. Packed memory sources require 16-byte alignment; scalar
sources read exactly four bytes without alignment requirements and preserve
the destination's upper 96 bits. Source/destination aliases use original
values. All forms ignore MXCSR rounding, DAZ/FTZ and exception masks, preserve
existing status flags and generate no floating-point exceptions. Signed zeros
and denormals produce signed infinities; NaNs retain sign/payload while becoming
quiet. Negative normal or infinite RSQRT inputs produce the negative indefinite
NaN. RCP infinities produce signed zeros; positive RSQRT infinity produces zero.
Our numeric profile computes a binary64 reciprocal or reciprocal square root,
then rounds to binary32. RCP results with magnitude below `2^-126` are flushed
to signed zero, including when FTZ is disabled. This chooses a transition inside
Intel's implementation-dependent underflow region around inputs of `2^126`.
The independent [reciprocal oracle](../tests/x86-reciprocal.py) passes **85,996
byte/state queries per engine**, with exact rational/integer-root midpoint
comparisons and separate checks of Intel's `1.5 * 2^-12` relative error bound.
All normal exponents, special classes, flush boundaries, midpoint neighbors,
12 encoding views, scalar offsets, aliases and unchanged MXCSR/FLAGS are
covered. Native x86 lookup-table bits and universal correct rounding remain
unverified. Semantics follow [Intel Volume 2B](https://cdrdv2-public.intel.com/929354/253667-093-sdm-vol-2b.pdf).

ANDNPS/ANDNPD compute raw `(~destination) & source` bits, including NaN,
denormal and signed-zero payloads, without changing MXCSR or flags. Their
legacy memory sources require 16-byte alignment. MOVNTPS/MOVNTPD/MOVNTDQ
write exactly 16 aligned bytes; MOVNTQ writes eight bytes and MOVNTI writes
four/eight bytes without requiring natural alignment in our profile.
MASKMOVDQU/MASKMOVQ select bytes by each mask byte's MSB and address RDI/EDI
through address-size and FS/GS overrides. Data/mask aliases use original values.
Only selected bytes require writable mappings; no destination read is needed.
All selected writes reserve COW pages and bookkeeping before publishing bytes,
so mapping/permission/allocation faults preserve data and CPU state. All-zero
MSBs suppress memory faults in this profile, while successful MASKMOVQ still
enters MMX state. Intel permits implementation-dependent zero-mask faults.
Streaming/cache hints use ordinary synchronous guest writes, consistent with
the serialized CPU model; cache performance and hardware write combining are
not modeled. The independent [streaming oracle](../tests/x86-stream.py) checks
91,072 byte/state queries per engine, every 65,536 XMM and 256 MMX selection
patterns, unaligned offsets, register aliases, guards, MXCSR and flags. Layouts
and semantics follow [Intel Volume 2B](https://cdrdv2-public.intel.com/929354/253667-093-sdm-vol-2b.pdf).

Remaining CPU work includes guest signal delivery, native fault-state
verification and a broader ISA audit. VEX/AVX forms remain unsupported.
Passing these MMX/SIMD checks does not satisfy the unchanged glibc
CPU-baseline gate; CPUID claims remain conservative.

`MOVLPS/MOVHPS/MOVLPD/MOVHPD` load/store exactly eight bytes and preserve
the other XMM half on loads. Register `MOVHLPS/MOVLHPS` select the source high/low
half and preserve the other destination half, including register aliases.
Legacy `MOVSS/MOVSD` scalar loads, stores and register moves preserve or clear
upper XMM lanes according to the operand form. `CVTSS2SD/CVTSD2SS` convert
between scalar float formats while preserving the destination's upper lanes.
SSE3 `MOVSLDUP/MOVSHDUP/MOVDDUP` implement lane duplication, and `LDDQU` loads
an unaligned 128-bit memory source. `HADDPS/PD`, `HSUBPS/PD` and `ADDSUBPS/PD`
cover horizontal and alternating packed single/double arithmetic.
The implemented arithmetic, comparisons, conversions, horizontal operations,
ROUND and dot products use MXCSR rounding and exception staging. Quiet/signaling
NaNs follow x86 rules; MIN/MAX forward source 2 and signal invalid on any NaN.
DAZ converts subnormal inputs to signed zero; FTZ flushes tiny arithmetic results
when underflow is masked. Pre-computation traps suppress post-computation flags;
masked results commit only after all source reads and exception checks. ROUND
honors its immediate rounding selection and precision suppression. Other
conversions, general SIMD and AVX remain unsupported.
The tested SSE4.1 subset includes `MPSADBW`, `MOVNTDQA`,
`PMULDQ`, `PACKUSDW`, `PHMINPOSUW`, `PTEST`, `PBLENDW`, `PBLENDVB`,
`BLENDPS/PD` and `BLENDVPS/PD`, alongside `PMULLD`, packed signed/unsigned
min/max, `PCMPEQQ` and all 12 `PMOVSX`/`PMOVZX` byte/word/dword widening forms.
`DPPS`/`DPPD` implement their immediate product and destination masks;
`ROUNDPS/PD/SS/SD` implement explicit immediate rounding modes.
`MOVNTDQA` requires a 16-byte aligned memory source; its cache hint has no
effect in this memory model. `PINSRB/RD/RQ` insert scalar register or
unaligned-memory values into byte/dword/qword lanes; `INSERTPS` selects,
inserts and zeroes dword lanes. `PEXTRB/W/D/Q` and `EXTRACTPS` extract register
and memory lanes, with register results zero-extended. The scalar transfer
results are checked by the host integration test. Other SSE4.1 instructions
are unsupported.
SSE4.2 `CRC32` supports byte, word, dword and qword sources using the reflected
Castagnoli polynomial; 32-bit destinations zero-extend and status flags remain
unchanged. A scalar-oracle fixture checks the legacy high-byte source form.
`PCMPGTQ` compares two signed qword lanes with register or aligned-memory
sources. Other SSE4.2 instructions remain unsupported.
Current-mode ROUND selectors use the reset round-to-nearest mode, and dot
products use round-to-nearest arithmetic.
String operations accept 32/64-bit address sizes; other address-size overrides
are rejected. REP executes one element per step, including limits and faults.

RV64I: integer arithmetic, word operations, signed/unsigned loads, stores,
comparisons, branches, JAL/JALR, LUI/AUIPC, FENCE and ECALL. M high/low multiply,
division and remainder, including divide-by-zero/overflow semantics. The tested
F/D subset covers FLW/FLD/FSW/FSD, FSGNJ[N/X], FCLASS, FEQ/FLT/FLE, FMV.X.W/D
and FMV.W.X/D.X; FADD/FSUB/FMUL/FDIV/FSQRT, FMIN/FMAX and all four fused
multiply-add forms; FCVT.S.D/FCVT.D.S; and integer/floating FCVT between
W/WU/L/LU and S/D. Arithmetic and fused operations implement RNE/RTZ/RDN/RUP/RMM.
Float-to-integer, integer-to-float and double-to-single conversions implement
the same five modes; single-to-double is exact. `fflags` accrues
NV/DZ/OF/UF/NX for the implemented operations. Single-precision values use
D-extension NaN boxing. Zicsr CSRRW/CSRRS/CSRRC and immediate forms support only
fflags, frm and fcsr. Other conversions, CSRs and privileged instructions
remain unsupported; this is not general RVF/RVD compatibility.

RV64C integer encodings: ADDI4SPN, LW/LD/SW/SD, ADDI/ADDIW/LI/LUI/ADDI16SP,
SRLI/SRAI/ANDI, SUB/XOR/OR/AND/SUBW/ADDW, J/BEQZ/BNEZ, SLLI,
LWSP/LDSP/SWSP/SDSP, JR/JALR/MV/ADD and NOP/hints. Mixed 16/32-bit instructions
can start on a two-byte boundary; compressed calls link to PC+2. Reserved
encodings fail explicitly. C.FLD/C.FSD/C.FLDSP/C.FSDSP execute through the
tested D subset. Other compressed floating-point encodings and EBREAK trap
handling remain unsupported. The core builder preserves the uncompressed
fixtures and additionally writes compressed variants to
`artifacts/guests/riscv64/compressed/`. All ten and standalone PIE pass in
interpreter/JIT paths on the verified ARM64 Mac.

RV64A word/doubleword LR/SC and AMOSWAP/ADD/XOR/AND/OR/MIN/MAX/MINU/MAXU
use checked, naturally aligned memory. Word loads return sign-extended values;
word stores ignore the source's upper 32 bits. SC checks write permission even
when its reservation fails, clears the reservation, and returns 0 or 1. Any
guest write or mapping change conservatively invalidates reservations. AQ/RL
bits are accepted in the ordered, serialized engine; thread switches also
invalidate reservations. The core atomic C fixture covers
builtin operations, compare/exchange and reservation invalidation in both modes.

AArch64: wide/immediate moves, ADR/ADRP, add/sub including extended registers,
logical register/immediate, shifts, bitfields, RBIT/CLZ, load/store/pairs with
writeback, conditional selection/compare, MUL/MADD/MSUB, signed/unsigned long
and high multiply, SDIV/UDIV, branches/calls/returns, SVC and NOP. TPIDR_EL0 is
guest state. DCZID_EL0 advertises checked 64-byte DC ZVA zeroing. Exclusive
loads/stores, CLREX and barriers use a conservative reservation model; every
guest memory write, mapping change or thread switch invalidates the reservation.
LDAR/STLR byte/halfword/word/doubleword forms use aligned checked memory and
serialized acquire/release ordering. SP bases require 16-byte alignment for
these atomic/exclusive accesses. SIMD covers B/H/S/D/Q transfers, S/D/Q pairs, general-register
DUP, integer MOVI/MVNI/ORR/BIC immediates and UMOV/SMOV lane extraction, with
32 vector registers, plus modular integer vector ADD/SUB/MUL, AND/BIC/ORR/EOR,
MVN and signed CMGT/CMEQ comparisons across B/H/S/D lanes in D/Q arrangements, checked by an
exact-output guest oracle. The D forms clear the upper 64 bits; 64-bit lanes
require Q form, and MUL supports B/H/S lanes only. TBL/TBX accepts one to four
full 16-byte table registers, including V31-to-V0 wrap and aliased operands;
8/16-byte destinations use zero/preserved bytes for out-of-range indices.
Integer MLA/MLS wraps B/H/S lane products into the old accumulator, with
8/16-byte arrangements and aliased operands. Both engines match a scalar
oracle and native ARM64 destination bytes on 8,448 queries across 228 instruction
views. Floating-point arithmetic and the rest of NEON remain unsupported.
Opcode families are partially decoded; this is not complete AArch64 support.

## Linux ABI

read/write/readv/writev, pread64/pwrite64, fsync/fdatasync, ftruncate,
getcwd, readlink/readlinkat, open/openat, x86-64 access/mkdir/rmdir/unlink/rename,
faccessat with zero flags, mkdirat/unlinkat/renameat, utimensat with supported
null or explicit times, UTIME_NOW/UTIME_OMIT, AT_SYMLINK_NOFOLLOW and
null-path descriptor timestamps (Linux futimens), umask,
close, stat/lstat/fstat/newfstatat, lseek, selected
fcntl, dup/dup3 (plus legacy x86-64 dup2), pipe2 (plus legacy x86-64 pipe),
getdents64, exit/exit_group, brk, private mmap, munmap, mprotect,
clock_gettime, gettimeofday, x86-64 time, sysinfo, getrandom, uname,
getpid/getppid/gettid, uid/gid/euid/egid, getgroups, unprivileged setuid/setgid,
sched_getaffinity, set_tid_address, shared-memory clone, sched_yield,
nanosleep, CLOCK_REALTIME/CLOCK_MONOTONIC clock_nanosleep and
x86 arch_prctl (FS/GS set/get). [Linux guest threads](linux-threads.md) run with
separate CPU/TLS state and shared memory/descriptors. x86-64 fork and three-CPU
clone(SIGCHLD, stack=0) create isolated guest processes; wait4 reaps exits and
schedules blocking waits. Other process-style clone profiles and clone3 remain
unsupported. Instruction/time limits and the mapped-memory budget are shared
across the process tree. See [linux-processes.md](linux-processes.md).
rt_sigaction and rt_sigprocmask store guest handler/mask metadata using each
CPU's kernel layout and an 8-byte sigset; SIGKILL/SIGSTOP cannot be caught or
blocked. Guest signal delivery and signal frames are unsupported.
sigaltstack stores 24-byte alternate-stack metadata with size/flag validation,
active-stack checks and atomic output faults; it does not deliver signals.
prlimit64 queries the fixed stack, 64-descriptor and memory limits; mutation
and other resources return ENOSYS. Legacy x86 poll translates guest descriptors,
normal/band event bits and regular-file readiness, up to 64 entries. Pipe
readiness uses the guest queue, with EOF/HUP and broken-writer/ERR reporting.
Blocking poll suspends the calling guest and retries with a preserved absolute
deadline; it does not block native poll for the guest timeout. Generic ppoll
remains unsupported. Futex
WAIT/WAKE and WAIT_BITSET/WAKE_BITSET use checked mapped/aligned words, real
wait queues, private/shared keys, masks and relative/absolute deadlines.
PI/requeue and cross-process synchronization remain unsupported. madvise,
set_robust_list, rseq and accelerated sendfile return ENOSYS. Guests may use
their read/write fallback for file transfers. No socket family is implemented: socket
returns EAFNOSUPPORT, allowing optional libc lookup fallbacks.
Unsupported syscall numbers fault. Pipe ioctl FIONREAD writes a checked 32-bit
queued-byte count. Other ioctls present descriptors as nonterminal streams and
return ENOTTY, rather than exposing native device ioctls.

Pipes use private nonblocking, close-on-exec native handles and a shared guest
queue limited to 4 KiB. They do not require `--allow-files`. Guest pipe2 accepts
zero, O_NONBLOCK and O_CLOEXEC; packet/notification modes are unsupported.
Writes up to 4 KiB are atomic: insufficient space blocks the guest or returns
EAGAIN in nonblocking mode. Larger writes may be short. Empty reads suspend
the guest while other contexts run, or return EAGAIN with O_NONBLOCK. The last
writer's close yields EOF after queued bytes drain. A write with no reader
returns EPIPE; guest SIGPIPE delivery is still missing. Waiting syscalls retain
their arguments and retry at the original trap, and all-blocked pipe/poll waits
still honor the runtime deadline. Read destinations are prepared before stream
bytes are consumed. Duplicates share pipe state and F_SETFL O_NONBLOCK/O_APPEND;
FD_CLOEXEC remains per descriptor. Pipe capacity resizing and asynchronous I/O
are unsupported. The existing system and musl pthread fixtures check these
boundaries. Isolated fork/wait now supports selected built-in shell pipelines;
exec and guest signal delivery remain unsupported.

I/O and random requests are capped at 1 MiB. mmap accepts private anonymous and
regular-file snapshots, page-aligned file offsets, MAP_FIXED replacement and
MAP_FIXED_NOREPLACE. File snapshots require `--allow-files`; writes remain
private, reads do not change the descriptor offset, partial EOF pages are
zero-padded and whole pages beyond EOF fault with BusError. Signal delivery, shared
mappings and coherence with later file changes remain unsupported. A hint may
be ignored. Fixed mapping failures preserve existing pages. brk has a 16 MiB
reservation. The initial guest has PID/TID 1 and parent PID 0; fork children
have their own PIDs, while thread IDs use the same unique namespace. UID/GID
remain 1000. Affinity exposes one guest CPU. Clocks support
realtime/monotonic only; gettimeofday returns microseconds
and optional obsolete UTC/no-DST timezone metadata. sysinfo reports the guest's
256 MiB mapped-memory budget, remaining unmapped bytes and elapsed runtime
uptime, live guest process count and zero modeled load/swap/shared/high-memory
fields. It does not expose host memory capacity. With fork, sysinfo's free-memory
value tracks the shared mapped-memory budget. umask retains the low nine bits
as independent guest state; native
creation temporarily applies that mask and restores the host mask immediately.
Concurrent embedding would require host mask isolation around those calls.
Directory descriptors decode signed 32-bit values, including either encoding
of AT_FDCWD. open/openat translates O_NONBLOCK to the host flag.
dup and fcntl DUPFD/DUPFD_CLOEXEC use the lowest available guest slot with
shared host file offsets and independent guest descriptor flags. dup2/dup3
replace exact slots within the 64-descriptor limit, reclaim private handles and
cached directory streams, and preserve borrowed host standard streams.
dup2 with identical valid descriptors preserves its flags; dup3 rejects identical
descriptors and accepts only zero or O_CLOEXEC flags. All private host copies stay
close-on-exec independently of guest metadata. setuid/setgid accept only ID 1000;
other valid IDs return EPERM and UINT32_MAX returns EINVAL. Host credentials are
never changed. Supplementary groups are an empty fixed list: getgroups returns
zero for nonnegative signed 32-bit sizes without touching the buffer, including
null/unmapped pointers; negative sizes return EINVAL. The duplication and identity arguments use Linux's low 32-bit
FD/ID encodings. Directory stream buffers are still per guest descriptor.
The three-CPU [file-duplicate guest](../examples/file-duplicate.c) tests offsets,
flags, stdout redirection, errors, table exhaustion, virtual credentials and
PID/parent/thread identity.
fcntl supports GETFD/SETFD/GETFL, pipe-only SETFL as described above,
and translates Linux flock records for native F_GETLK/F_SETLK advisory locks.
External lock conflicts and their owner PIDs come from the host; blocking
F_SETLKW and Linux-specific OFD locks are unsupported. Positioned I/O preserves
descriptor offsets. Both sync calls use native fsync; ftruncate requires
`--allow-files`. readv/writev gather/scatter through checked buffers for streams
and regular files. Symlink reads truncate without appending a NUL.
getcwd returns a NUL-terminated path and its byte count, including the NUL.
It inherits the host cwd; with a sysroot it strips that root's physical prefix
and returns ENOENT if the cwd is outside it. Guest chdir is unsupported.
Open flags translate the guest CPU's O_DIRECTORY, O_NOFOLLOW and O_LARGEFILE
encodings; O_NOFOLLOW rejects a final symlink, and O_LARGEFILE is a 64-bit no-op.
Directory records are serialized to Linux dirent64, with paginated reads and
absolute cookie seek. Files require `--allow-files`. No native struct/pointer
is directly exposed to a guest.

## Limits

Linux ELF execution accepts little-endian ET_EXEC/ET_DYN, Linux/System V OSABI,
and non-overlapping PT_LOAD pages. Standalone PIE Hello World passes for all
three CPUs. PT_INTERP requires `--sysroot` and `--allow-files`; the guest linker
executes through the same CPU engine. Dynamic x86-64, AArch64 and soft-float
LP64 RISC-V musl ET_EXEC and PIE with a separate DSO, imported functions, a
constructor and single-thread TLS pass.
See [musl.md](musl.md): UNIVERSE supplies the kernel-style handoff, while musl's
guest code performs relocations and symbol lookup. This is not arbitrary dynamic
application or glibc compatibility. ELF32, big-endian, overlapping load pages,
signal delivery, sockets and exec remain unsupported. Static musl
Hello World does not imply all musl functionality or arbitrary static programs.
The unchanged official BusyBox 1.35.0 binary passes selected utility/file,
identity and noninteractive built-in shell cases, including selected subshells,
command substitution and built-in pipelines. External commands, background jobs
and general shell compatibility remain
unsupported. The separate BusyBox 1.37.0 source-built fixture contains selected
coreutils/file applets only; see [busybox.md](busybox.md).
The optional SQLite batch CLI checks persisted transactions, rollback,
delete/truncate journals, VACUUM, native database reopen and lock contention.
Its build disables threads and loaded extensions; WAL and crash recovery are
unverified. See [sqlite.md](sqlite.md) for reproducible commands and limits.
Windows LoadLibraryA/W, FreeLibrary and late forwarders pass source-built fixtures
with shared references, cyclic imports, detach order, rollback and reload.
Static PE TLS templates, per-module indices and process callbacks also pass
source-built executable and DLL fixtures on the initial guest thread. The
64-slot dynamic TLS APIs pass too. Named/ordinal OLEAUT32 string/variant imports,
scoped runtime exports and guest forwarders pass without vendor DLLs; owning COM
objects, SAFEARRAYs and records return E_NOTIMPL. Guest threads remain unsupported.
USER32 CharUpperW uses Unicode 17.0.0 BMP simple-uppercase data; CharPrevExA
uses five Windows DBCS lead-byte ranges. Supplementary casing and Windows NLS
version parity are unverified. ADVAPI32 adds checked entropy writes, closable
process-token handles with no assigned Windows privileges, and five empty
read-only registry roots. Windows file ACL queries/updates return explicit
errors; no host permissions are changed. Windows limitations and APIs
are listed in [windows.md](windows.md). The legacy MSVCRT subset adds memory,
strings, original argv/data imports, standard-stream text/binary I/O and guest
initializer/exit callbacks. Exceptions, RTTI, guest threads and broad CRT
compatibility remain missing. Single-thread Win32 events/semaphores, recursive
critical sections, shared named-object lifetimes and timed waits now pass SDK
guests; pending waits remain subject to execution deadlines. Virtual identity,
one-CPU affinity and monotonic-clock APIs do not imply guest thread creation.
Win32 file mutations/metadata add same-volume no-overwrite/replacement moves,
directories, hard links, shared pending deletion, read-only mapping and large
file positions. SDK guests and independent host stat/byte checks pass in both
engines; cross-volume moves, progress callbacks and broad attributes remain
unsupported.

Win32 file enumeration uses real directory cursors, bounded UTF-16 DOS wildcard
matching and checked search handles. Default stream enumeration exposes actual
regular-file sizes and supports A/W reads, writes and creation through `::$DATA`.
Both engines pass 8,976 file-enumeration and 2,145 stream replies; file and stream
searches share 1,024 slots. One virtual C drive maps absolute and drive-relative
paths into the same guest filesystem, with reusable DOS current/temp paths.
Named alternate streams, other drives, UNC paths and native
Windows filesystem parity remain unsupported or unverified.
See [the file/stream scopes](windows.md#default-data-streams).

Win32 time APIs validate Gregorian/DOS/FILETIME dates, use current host timezone
for the legacy local/UTC pair, and update checked regular-file timestamps.
Virtual process CPU times include host emulation cost; native Windows timezone
and filesystem parity remain unverified. See [the time scope](windows.md#calendar-clocks-and-file-times).

Win32 stdin terminal modes map processed/line/echo input to real host termios.
SIGINT/SIGQUIT invoke registered guest control callbacks in reverse order,
including ignored Ctrl+C and pending-wait restoration. Callbacks run serially
on the initial guest thread; native Windows handler-thread scheduling, output
modes and screen buffers remain unsupported. Console code pages are UTF-8
only. See [the console scope](windows.md#terminal-input-and-control-callbacks).

Win32 file sections provide coherent shared views, private guest-page COW,
64-bit sparse offsets, dirty-page flushes and independent handle/view lifetimes.
Executable paging views use the CPU engine; file GENERIC_EXECUTE, section
image/reserve/large-page flags, inherited handles and global IPC remain absent.
Backing pages are cached; external changes and ReadFile/WriteFile are not
synchronized with them. See [the mapping scope](windows.md#file-sections-and-mapped-views).

Mach-O execution accepts thin little-endian x86-64/AArch64 MH_EXECUTE images
without guest libraries or fixups. Source-built LC_UNIXTHREAD fixtures pass;
library-free LC_MAIN startup/return is covered by synthetic image tests. The
Darwin BSD subset covers exit, read/write/writev, open/close/lseek, getpid and
private mmap/munmap/mprotect. Guest page sizes are 4 KiB (x86) and 16 KiB (ARM).
Dyld, LibSystem imports, relocations/fixups, TLS, initializers, Mach traps,
universal/fat files, guest processes and threads are unsupported. See
[macos.md](macos.md) for exact scope and native-comparison boundaries.

Linux thread capability probes `set_robust_list` and `rseq` return ENOSYS on
all three CPUs. Robust owner-death cleanup and restartable sequences are
unsupported; libc can use its unavailable-kernel fallback. The static pthread
fixture passes on all three CPUs in interpreter/JIT modes; dynamic-library
pthread TLS remains unverified.
