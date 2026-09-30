# Current compatibility

Every execution claim below is about reproducible fixtures, not a complete ISA,
OS ABI or arbitrary applications. The primary verified host is **macOS 26.6
ARM64 (Apple M2)**. Linux x86-64/ARM64 builds are cross-compiled; execution there
has not been measured in this session.

| Guest | Level | Evidence |
|---|---|---|
| Linux x86-64 static ELF64 | Executed | Assembly, nine libc-free C fixtures, static musl Hello World |
| Linux RV64IM static ELF64 | Executed | Nine libc-free C fixtures |
| Linux AArch64 static ELF64 | Executed | Nine libc-free C fixtures |
| Windows x86-64 PE32+ | Executed | Console output, input/output and VirtualAlloc/free fixtures |
| macOS Mach-O64 x86-64/ARM64 | Parsed | Segment/command/library/entry validation; execution rejected |
| BusyBox 1.37.0 static x86-64 | Experimental applets | Optional source build and separate app regression checks |
| Linux x86-64 / AArch64 dynamic ELF64 / PIE | Experimental fixture | Upstream musl 1.2.5 guest linker, separate DSO, constructor and TLS |

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
XORPS/XORPD/PXOR, ANDPS/ANDPD, ORPS/ORPD, MOVD/MOVQ, PUNPCKLBW/LWD/LDQ/LQDQ, PSHUFD/LW/HW, PCMPEQB/W/D, PMOVMSKB, PAND/PANDN/POR, PMINUB/PMAXUB, immediate packed
PSRLW/D/Q, PSRAW/D, PSLLW/D/Q and PSRLDQ/PSLLDQ. These move or operate on 128 raw bits;
there is no floating-point arithmetic, general SIMD, AVX or MMX support.
String operations accept 32/64-bit address sizes; other address-size overrides
are rejected. REP executes one element per step, including limits and faults.

RV64I: integer arithmetic, word operations, signed/unsigned loads, stores,
comparisons, branches, JAL/JALR, LUI/AUIPC, FENCE and ECALL. M high/low multiply,
division and remainder, including divide-by-zero/overflow semantics. CSR,
privileged instructions and A/F/D/C extensions are not implemented.

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

read/write/writev, open/openat, close, stat/lstat/fstat/newfstatat, lseek, selected
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
executes through the same CPU engine. Dynamic x86-64 and AArch64 musl ET_EXEC and PIE with a
separate DSO, imported functions, a constructor and single-thread TLS pass.
See [musl.md](musl.md): UNIVERSE supplies the kernel-style handoff, while musl's
guest code performs relocations and symbol lookup. This is not arbitrary dynamic
application or glibc compatibility. ELF32, big-endian, overlapping load pages,
signals, sockets, process creation and threads remain unsupported. Static musl
Hello World does not imply all musl functionality or arbitrary static programs.
BusyBox is a minimal echo/cat/ls build, not a complete build or a working shell.
Windows limitations and APIs are listed in [windows.md](windows.md).
Mach-O is inspection-only, including LC_SEGMENT_64 and LC_MAIN, not a macOS ABI.
