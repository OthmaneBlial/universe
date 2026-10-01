# Current compatibility

Every execution claim below is about reproducible fixtures, not a complete ISA,
OS ABI or arbitrary applications. The primary verified host is **macOS 26.6
ARM64 (Apple M2)**. Linux GNU-libc x86-64/ARM64 builds are cross-compiled; execution there
has not been measured in this session.

| Guest | Level | Evidence |
|---|---|---|
| Linux x86-64 static ELF64 | Executed | Assembly, nine libc-free C fixtures, static musl Hello World |
| Linux RISC-V64 ELF64 | Executed subsets | Nine RV64IM/IMC libc-free C fixtures and word/doubleword atomics; separate hard-float fixture covers selected F/D transfers, five-mode arithmetic, integer conversions, comparisons, classification, sign injection, compressed transfers and Zicsr fflags/frm/fcsr |
| Linux AArch64 static ELF64 | Executed | Nine libc-free C fixtures |
| Windows x86-64 PE32+ | Executed | Console/files, command lines, memory, guest DLL imports and runtime load/unload with DllMain |
| macOS Mach-O64 x86-64/ARM64 | Executed | Five library-free C fixtures: console, argv/env, memory and files |
| BusyBox 1.37.0 static x86-64 | Experimental applets | Optional source build and separate app regression checks |
| Linux x86-64 / AArch64 / RISC-V64 LP64 dynamic ELF64 / PIE | Experimental fixture | Upstream musl 1.2.5 guest linker, separate DSO, constructor and TLS |

## Instructions

x86: MOV/MOVZX/MOVSX/MOVSXD, LEA, PUSH/POP/LEAVE,
ADD/SUB/ADC/SBB/INC/DEC/NEG, logical arithmetic, CMP/TEST, SHL/SHR/SAR, ROL/ROR,
IMUL/MUL/DIV/IDIV, JMP/Jcc/CALL/RET, SETcc/CMOVcc/XCHG/CMPXCHG,
BSF/BSR, TZCNT/LZCNT, BT/BTS/BTR/BTC, CBW/CWDE/CDQE and CWD/CDQ/CQO,
MOVS/STOS/LODS/CMPS/SCAS, REP/REPE/REPNE, CLD/STD,
NOP/PAUSE/ENDBR64 and SYSCALL. REX, ModR/M, SIB, RIP-relative, FS/GS-based addresses
and 8/16/32/64-bit operands. Supported LOCK memory RMW instructions execute
atomically with respect to the single guest thread; guest threads are unsupported.

SSE/SSE2 subset: MOVUPS/MOVUPD/MOVAPS/MOVAPD/MOVDQA/MOVDQU,
XORPS/XORPD/PXOR, ANDPS/ANDPD, ORPS/ORPD, MOVD/MOVQ, PEXTRW,
PUNPCKLBW/LWD/LDQ/LQDQ and PUNPCKHBW/HWD/HDQ/HQDQ,
PMULLW/PMULHW/PMULHUW/PMULUDQ/PMADDWD, PACKSSWB/PACKSSDW/PACKUSWB,
PAVGB/PAVGW/PSADBW,
PSHUFD/LW/HW, PCMPEQB/W/D,
PCMPGTB/W/D, PMOVMSKB, PAND/PANDN/POR, PMINUB/PMAXUB/PMINSW/PMAXSW,
register-count and immediate packed PSRLW/D/Q, PSRAW/D, PSLLW/D/Q, PSRLDQ/PSLLDQ,
modular PADD/PSUB byte, word,
doubleword and quadword lanes, and signed/unsigned saturating byte/word
PADDS/PADDUS/PSUBS/PSUBUS operations. These move or operate on 128 raw bits;
there is no floating-point arithmetic, general SIMD, AVX or MMX support.
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
`artifacts/guests/riscv64/compressed/`. All nine and standalone PIE pass in
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
32 vector registers. Floating-point arithmetic and general NEON are unsupported.
Opcode families are partially decoded; this is not complete AArch64 support.

## Linux ABI

read/write/writev, open/openat, x86-64 access/mkdir/rmdir/unlink/rename,
faccessat with zero flags, mkdirat/unlinkat/renameat, utimensat with supported
null or explicit times, UTIME_NOW/UTIME_OMIT and AT_SYMLINK_NOFOLLOW forms,
close, stat/lstat/fstat/newfstatat, lseek, selected
fcntl, getdents64, exit/exit_group, brk, private mmap, munmap, mprotect,
clock_gettime, getrandom, uname, getpid/gettid, uid/gid/euid/egid,
sched_getaffinity, set_tid_address, x86 arch_prctl (FS/GS set/get).
Unsupported syscall numbers fault. ioctl presents guest descriptors as
nonterminal streams and returns ENOTTY, rather than exposing native device ioctls.

I/O and random requests are capped at 1 MiB. mmap accepts private anonymous and
regular-file snapshots, page-aligned file offsets, MAP_FIXED replacement and
MAP_FIXED_NOREPLACE. File snapshots require `--allow-files`; writes remain
private, reads do not change the descriptor offset, partial EOF pages are
zero-padded and whole pages beyond EOF fault with BusError. Signals, shared
mappings and coherence with later file changes remain unsupported. A hint may
be ignored. Fixed mapping failures preserve existing pages. brk has a 16 MiB
reservation. IDs are guest pid/tid 1 and uid/gid 1000; affinity exposes one guest
CPU. Clocks support realtime/monotonic only. fcntl supports GETFD/SETFD/GETFL.
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
signals, sockets, process creation and threads remain unsupported. Static musl
Hello World does not imply all musl functionality or arbitrary static programs.
BusyBox is a selected applet build with tested numeric `printf`, coreutils and
file cases, not a complete build or a working shell.
Windows LoadLibraryA/W, FreeLibrary and late forwarders pass the source-built
fixture with shared references, cyclic imports, detach order, rollback and reload.
Windows limitations and APIs are listed in [windows.md](windows.md).
Mach-O execution accepts thin little-endian x86-64/AArch64 MH_EXECUTE images
without guest libraries or fixups. Source-built LC_UNIXTHREAD fixtures pass;
library-free LC_MAIN startup/return is covered by synthetic image tests. The
Darwin BSD subset covers exit, read/write/writev, open/close/lseek, getpid and
private mmap/munmap/mprotect. Guest page sizes are 4 KiB (x86) and 16 KiB (ARM).
Dyld, LibSystem imports, relocations/fixups, TLS, initializers, Mach traps,
universal/fat files, guest processes and threads are unsupported. See
[macos.md](macos.md) for exact scope and native-comparison boundaries.
