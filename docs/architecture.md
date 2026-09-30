# Architecture

UNIVERSE owns the execution path. It never launches a guest with an emulator,
virtual machine, container or host executable loader.

```mermaid
flowchart TD
    Binary --> ELF[Validated ELF64 parser]
    Binary --> PE[Validated PE32+ parser]
    Binary --> MachO[Validated Mach-O64 parser]
    MachO --> Memory
    PE --> Memory
    ELF --> Memory[Bounded guest virtual memory]
    Memory --> Decode[x86-64 / RV64IMAC + F/D/CSR subset / AArch64 decoders]
    Decode --> UIR[Typed instruction IR]
    UIR --> Interpreter[Zig interpreter]
    UIR --> JIT[ARM64 host register-block JIT]
    Interpreter --> Linux[Linux syscall ABI translation]
    Linux --> Host[POSIX host services]
    Interpreter --> Windows[Windows API subset]
    Windows --> Host
    Interpreter --> Darwin[Darwin BSD syscall subset]
    Darwin --> Host
```

The file bytes remain owned by the CLI until the runtime is destroyed. Loaders
copy loadable segment/section data into separately allocated guest regions. BSS starts at zero.
No guest address is cast to a host pointer. Decoders fetch from executable
regions; interpreted loads and stores enforce read/write permissions.

Registers, operand addressing, integer widths and control transfers are explicit
in UIR. Architecture decoders supply the guest instruction boundaries and CPU
specific operand semantics. The interpreter applies the register model (x86
partial writes, RISC-V x0, AArch64 SP/ZR), and executes the resulting operations.
The syscall translator reads the architecture's syscall argument registers and
serializes Linux structures instead of exposing host structs.

RISC-V compressed integer encodings expand to the existing 32-bit decoder while
retaining their original two-byte fallthrough address. UIR execution and JIT
instruction accounting therefore remain shared with the uncompressed path.
Word/doubleword RISC-V atomics reuse checked UIR memory operations and the
AArch64 single-thread reservation model; atomic operations stay interpreted.
The current F/D subset uses dedicated guest floating-point register state for
transfers, five-mode arithmetic and fused operations, compares, classification
and integer/cross-format conversions; Zicsr access is limited to `fflags`, `frm` and `fcsr`.
These operations fall back to the interpreter when a JIT block reaches them.

The Darwin layer translates its register, flag, errno and mapping conventions
to the existing checked POSIX services in `src/syscall/linux.zig`. Those services
receive canonical Linux encodings and a guest page size; they never invoke guest
code through the host Mach-O loader. Mach-O mappings retain segment maximum
protections, and the guest stack has argv, explicit environment and Apple path
entries. See [macos.md](macos.md).

Windows runtime DLL operations reuse the PE import/export linker. A bounded
dependency graph retains imported modules; explicit loads add references. Guest
attach/detach callbacks run through the same instruction pipeline before API
return, and image unmapping invalidates JIT code. See [windows.md](windows.md).

Host file metadata is normalized once in `src/host.zig`: Linux uses `statx`,
while macOS uses Zig's target-native `std.c.Stat`. Linux guest stat structures
are serialized from that normalized record rather than exposing host libc
layouts. Monotonic and realtime host clocks use Zig's target-native timespec.

The local validation command is `./scripts/check.sh`. GitHub Actions is disabled
at repository level and no workflow is installed, at the owner's request.
