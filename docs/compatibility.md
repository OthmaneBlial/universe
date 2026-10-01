# Current compatibility

Every execution claim below is about reproducible fixtures, not a complete ISA,
OS ABI or arbitrary applications. The primary verified host is **macOS 26.6
ARM64 (Apple M2)**. Linux GNU-libc x86-64/ARM64 builds are cross-compiled; execution there
has not been measured in this session.

| Guest | Level | Evidence |
|---|---|---|
| Linux x86-64 static ELF64 | Executed | Assembly, ten libc-free C fixtures, static musl Hello World |
| Linux RISC-V64 ELF64 | Executed subsets | Ten RV64IM/IMC libc-free C fixtures and word/doubleword atomics; separate hard-float fixture covers selected F/D transfers, five-mode arithmetic, integer conversions, comparisons, classification, sign injection, compressed transfers and Zicsr fflags/frm/fcsr |
| Linux AArch64 static ELF64 | Executed | Ten libc-free C fixtures plus a source-built NEON arithmetic/logic/compare oracle |
| Windows x86-64 PE32+ | Executed subsets | Console/files, command lines, memory, guest DLL imports/load/unload, and single-thread static TLS templates with process callbacks |
| macOS Mach-O64 x86-64/ARM64 | Executed | Five library-free C fixtures: console, argv/env, memory and files |
| BusyBox 1.37.0 static x86-64 | Experimental applets | Optional source build and separate app regression checks |
| SQLite 3.53.4 static x86-64 | Experimental batch CLI | Queries, persisted transactions, rollback, delete/truncate journals, VACUUM, native reopen and lock contention |
| Debian GNU Hello 2.10-5 / glibc 2.41 x86-64 | Rejected CPU baseline | Unchanged loader maps glibc, initializes TLS and exits 127 with its ISA-level diagnostic; see [debian.md](debian.md) |
| Linux x86-64 / AArch64 / RISC-V64 LP64 dynamic ELF64 / PIE | Experimental fixture | Upstream musl 1.2.5 guest linker, separate DSO, constructor and TLS |

## Instructions

x86: MOV/MOVZX/MOVSX/MOVSXD, LEA, PUSH/POP/LEAVE,
ADD/SUB/ADC/SBB/INC/DEC/NEG, logical arithmetic, CMP/TEST, SHL/SHR/SAR, ROL/ROR,
IMUL/MUL/DIV/IDIV, JMP/Jcc/CALL/RET, SETcc/CMOVcc/XCHG/CMPXCHG/CMPXCHG8B/CMPXCHG16B,
BSF/BSR, TZCNT/LZCNT, POPCNT, BSWAP, BT/BTS/BTR/BTC, CBW/CWDE/CDQE and CWD/CDQ/CQO,
MOVS/STOS/LODS/CMPS/SCAS, REP/REPE/REPNE, CLD/STD,
NOP/PAUSE/ENDBR64, CPUID, RDTSC and SYSCALL. REX, ModR/M, SIB, RIP-relative, FS/GS-based addresses
and 8/16/32/64-bit operands. Short accumulator XCHG forms honor 16/32/64-bit
widths and REX.B registers. Untaken 32-bit CMOV clears the destination upper
half and still checks source memory. CPUID reports a conservative virtual CPU
(TSC/CX8/CMOV/MMX, CX16 and extended SYSCALL/long-mode bits); unsupported leaves return
zero. RDTSC uses a virtual 1 GHz monotonic counter, not native CPU cycles.
Supported LOCK memory RMW instructions execute
atomically with respect to the single guest thread; guest threads are unsupported.
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
Pending unmasked x87 exceptions stop MMX before state changes. Later SSE/SSSE3
extensions operating on MMX registers remain unsupported.

FXSAVE/FXRSTOR support 16-byte-aligned 512-byte operands, raw x87/MMX data,
logical stack slots, abridged tags, both 32/64-bit pointer layouts and all 16
XMM registers. Save preserves bytes 416–511, including the software-owned
tail; checked faults and rejected controls preserve state. LDMXCSR/STMXCSR use
exactly four bytes, including unaligned operands. MXCSR accepts reset controls
(nearest-even, masked exceptions, normal denormals) and stores status bits;
other control modes fail explicitly. x87 arithmetic and SSE exception accrual
or traps remain unsupported, so CPUID does not advertise FPU, FXSR, SSE or SSE2.
Layouts and MMX aliasing follow the
[Intel manuals](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html).

SSE/SSE2 plus tested SSSE3 `PSHUFB`, `PSIGNB/W/D`, `PABSB/W/D`, `PMADDUBSW`, `PMULHRSW`, `PHADDW/D/SW`, `PHSUBW/D/SW` and `PALIGNR`: MOVUPS/MOVUPD/MOVAPS/MOVAPD/MOVDQA/MOVDQU,
XORPS/XORPD/PXOR, ANDPS/ANDPD, ORPS/ORPD, MOVD/MOVQ, PEXTRW/PINSRW,
PUNPCKLBW/LWD/LDQ/LQDQ and PUNPCKHBW/HWD/HDQ/HQDQ,
PMULLW/PMULHW/PMULHUW/PMULUDQ/PMADDWD, PACKSSWB/PACKSSDW/PACKUSWB,
PAVGB/PAVGW/PSADBW,
PSHUFD/LW/HW, PSHUFB, PSIGNB/W/D, PABSB/W/D, PMADDUBSW, PMULHRSW,
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
signed 32/64-bit scalar conversions; CVT rounds to the reset nearest-even mode,
CVTT truncates and invalid inputs return the architecture's indefinite integer.
Packed `CVTDQ2PS`, `CVTPS2DQ` and `CVTTPS2DQ` convert four 32-bit lanes.
`CVTPS2PD`, `CVTPD2PS`, `CVTDQ2PD`, `CVTPD2DQ` and `CVTTPD2DQ` cover the packed
single/double and double/integer conversions. Integer conversions use
nearest-even or truncating rounding and return indefinite integers for invalid
inputs.
`MOVLPS/MOVHPS/MOVLPD/MOVHPD` load/store exactly eight bytes and preserve
the other XMM half on loads. Register `MOVHLPS/MOVLHPS` select the source high/low
half and preserve the other destination half, including register aliases.
Legacy `MOVSS/MOVSD` scalar loads, stores and register moves preserve or clear
upper XMM lanes according to the operand form. `CVTSS2SD/CVTSD2SS` convert
between scalar float formats while preserving the destination's upper lanes.
SSE3 `MOVSLDUP/MOVSHDUP/MOVDDUP` implement lane duplication, and `LDDQU` loads
an unaligned 128-bit memory source. `HADDPS/PD`, `HSUBPS/PD` and `ADDSUBPS/PD`
cover horizontal and alternating packed single/double arithmetic.
SSE arithmetic uses reset MXCSR controls; FP exception accrual/traps are not
modeled. Other conversions, general SIMD and AVX remain unsupported.
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
bits are accepted in the ordered single-thread engine; guest threads and
inter-thread synchronization are unsupported. The core atomic C fixture covers
builtin operations, compare/exchange and reservation invalidation in both modes.

AArch64: wide/immediate moves, ADR/ADRP, add/sub including extended registers,
logical register/immediate, shifts, bitfields, RBIT/CLZ, load/store/pairs with
writeback, conditional selection/compare, MUL/MADD/MSUB, signed/unsigned long
and high multiply, SDIV/UDIV, branches/calls/returns, SVC and NOP. TPIDR_EL0 is
guest state. DCZID_EL0 advertises checked 64-byte DC ZVA zeroing. Exclusive
loads/stores, CLREX and barriers use a single-thread reservation model; every
guest memory write or mapping change invalidates the reservation. There are no
guest threads. SIMD covers B/H/S/D/Q transfers, S/D/Q pairs, general-register
DUP, integer MOVI/MVNI/ORR/BIC immediates and UMOV/SMOV lane extraction, with
32 vector registers, plus modular integer vector ADD/SUB/MUL, AND/BIC/ORR/EOR,
MVN and signed CMGT/CMEQ comparisons across B/H/S/D lanes in D/Q arrangements, checked by an
exact-output guest oracle. The D forms clear the upper 64 bits; 64-bit lanes
require Q form, and MUL supports B/H/S lanes only. Floating-point arithmetic and the rest of NEON remain unsupported.
Opcode families are partially decoded; this is not complete AArch64 support.

## Linux ABI

read/write/readv/writev, pread64/pwrite64, fsync/fdatasync, ftruncate,
getcwd, readlink/readlinkat, open/openat, x86-64 access/mkdir/rmdir/unlink/rename,
faccessat with zero flags, mkdirat/unlinkat/renameat, utimensat with supported
null or explicit times, UTIME_NOW/UTIME_OMIT and AT_SYMLINK_NOFOLLOW forms,
close, stat/lstat/fstat/newfstatat, lseek, selected
fcntl, getdents64, exit/exit_group, brk, private mmap, munmap, mprotect,
clock_gettime, getrandom, uname, getpid/gettid, uid/gid/euid/egid,
sched_getaffinity, set_tid_address, x86 arch_prctl (FS/GS set/get).
rt_sigaction and rt_sigprocmask store guest handler/mask metadata using each
CPU's kernel layout and an 8-byte sigset; SIGKILL/SIGSTOP cannot be caught or
blocked. Guest signal delivery and signal frames are unsupported.
Unsupported syscall numbers fault. ioctl presents guest descriptors as
nonterminal streams and returns ENOTTY, rather than exposing native device ioctls.

I/O and random requests are capped at 1 MiB. mmap accepts private anonymous and
regular-file snapshots, page-aligned file offsets, MAP_FIXED replacement and
MAP_FIXED_NOREPLACE. File snapshots require `--allow-files`; writes remain
private, reads do not change the descriptor offset, partial EOF pages are
zero-padded and whole pages beyond EOF fault with BusError. Signal delivery, shared
mappings and coherence with later file changes remain unsupported. A hint may
be ignored. Fixed mapping failures preserve existing pages. brk has a 16 MiB
reservation. IDs are guest pid/tid 1 and uid/gid 1000; affinity exposes one guest
CPU. Clocks support realtime/monotonic only. fcntl supports GETFD/SETFD/GETFL
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
signal delivery, sockets, process creation and threads remain unsupported. Static musl
Hello World does not imply all musl functionality or arbitrary static programs.
BusyBox is a selected applet build with tested numeric `printf`, coreutils and
file cases, not a complete build or a working shell.
The optional SQLite batch CLI checks persisted transactions, rollback,
delete/truncate journals, VACUUM, native database reopen and lock contention.
Its build disables threads and loaded extensions; WAL and crash recovery are
unverified. See [sqlite.md](sqlite.md) for reproducible commands and limits.
Windows LoadLibraryA/W, FreeLibrary and late forwarders pass source-built fixtures
with shared references, cyclic imports, detach order, rollback and reload.
Static PE TLS templates, per-module indices and process callbacks also pass
source-built executable and DLL fixtures on the initial guest thread. The
64-slot dynamic TLS APIs pass too; guest threads remain unsupported. Windows limitations and APIs
are listed in [windows.md](windows.md).
Mach-O execution accepts thin little-endian x86-64/AArch64 MH_EXECUTE images
without guest libraries or fixups. Source-built LC_UNIXTHREAD fixtures pass;
library-free LC_MAIN startup/return is covered by synthetic image tests. The
Darwin BSD subset covers exit, read/write/writev, open/close/lseek, getpid and
private mmap/munmap/mprotect. Guest page sizes are 4 KiB (x86) and 16 KiB (ARM).
Dyld, LibSystem imports, relocations/fixups, TLS, initializers, Mach traps,
universal/fat files, guest processes and threads are unsupported. See
[macos.md](macos.md) for exact scope and native-comparison boundaries.

Linux thread capability probes `set_robust_list` and `rseq` return ENOSYS on
all three CPUs. Robust owner-death cleanup, restartable sequences and guest
threads are unsupported; libc can use its unavailable-kernel fallback.
