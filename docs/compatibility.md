# Current compatibility

Supported means tested **fixtures**, not arbitrary binaries or a complete ISA.
All guests currently require static little-endian ELF64 ET_EXEC, Linux/System V
OSABI, supported instructions and the implemented Linux syscall subset.
ET_DYN, PT_INTERP and PT_DYNAMIC execution fail explicitly. ELF32, big-endian,
TLS, shared libraries, threads, SIMD and compressed RISC-V instructions are not
implemented. PT_LOAD pages that overlap are rejected rather than merged.

| Guest | Demonstrated on macOS ARM64 | Evidence |
|---|---|---|
| Linux x86-64 | Assembly + five compiled C programs | `tests/integration.py` |
| Linux RV64IM | Five compiled C programs, no compressed instructions | same |
| Linux AArch64 integer subset | Five compiled C programs | same |

x86 instructions: MOV/MOVZX/MOVSX/MOVSXD, LEA, stack PUSH/POP/LEAVE,
ADD/SUB/ADC/SBB/INC/DEC/NEG, logical arithmetic, CMP/TEST, SHL/SHR/SAR,
integer IMUL/MUL/DIV/IDIV, JMP/Jcc/CALL/RET, SETcc/CMOVcc/XCHG,
CBW/CWDE/CDQE and CWD/CDQ/CQO, NOP and ENDBR64, SYSCALL. Addressing:
REX, ModR/M, SIB, RIP-relative, immediate/relative operands; 8/16/32/64-bit
widths. Address-size overrides, FS/GS, REP string instructions and LOCK are
rejected. Some opcode families are intentionally only partially decoded.

RISC-V: RV64I integer arithmetic, word operations, signed/unsigned loads,
stores, comparisons, branches, JAL/JALR, LUI/AUIPC, FENCE and ECALL; M
multiply high/low, divide/remainder, including defined divide-by-zero behavior.
CSR, privileged operations, A/F/D/C and other extensions are rejected.

AArch64: immediate/wide moves, ADR/ADRP, integer add/sub, logical register and
immediate operations, shifts, bitfields, integer load/store and pairs with
writeback, conditional selection, MUL/MADD/MSUB, SDIV/UDIV, branches,
calls/returns, SVC, NOP. No claim of complete AArch64 support.

Linux syscalls: read, write, open/openat, close, lseek, fstat/newfstatat, exit/
exit_group, brk, anonymous private mmap, munmap, mprotect, clock_gettime,
getrandom, uname, getpid/gettid. Syscall numbers and register conventions vary
by architecture. I/O and random calls cap a request at 1 MiB. mmap only accepts
MAP_PRIVATE|MAP_ANONYMOUS (0x22), no fixed mappings or file-backed mappings.
getpid/gettid return guest ID 1. uname describes the emulated ABI. fstat uses
the x86 144-byte or asm-generic 128-byte layout. Only realtime/monotonic clocks
are supported. brk has a fixed 16 MiB reservation and no reclamation yet.

Musl, BusyBox, Windows execution and macOS execution have not been verified at
this milestone. The roadmap tracks them separately.
