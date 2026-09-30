# ELF loader

ELF64, little-endian, version 1, ET_EXEC/ET_DYN and Linux/System V OSABI are accepted.
The parser recognizes x86-64, AArch64 and RISC-V machine IDs. Inspection accepts
ET_DYN and PT_INTERP, including execution. Header and program
header ranges, entry placement, segment sizes, file ranges, overflow, alignment
and permissions are validated before mapping.

PT_LOAD regions are mapped at 4 KiB guest page boundaries. File bytes are copied
by the loader and the remainder stays zero (BSS). Overlapping pages are rejected;
there is no accidental merging of permissions. Code is executable only when the
segment permits it. Sections are optional metadata, not required for execution.
ET_EXEC is mapped at its linked addresses. ET_DYN uses a fixed load bias of
0x40000000 for the program and 0x700000000000 for its interpreter; there is no
ASLR. Bias addition and segment alignment are checked.

PT_INTERP names must have exactly one terminating NUL. With `--sysroot` and
`--allow-files`, the loader reads and validates the named ELF interpreter,
requires matching architecture, rejects recursive interpreters, maps it and
starts at its entry. The program's headers must be mapped for this handoff.
The interpreter executes as guest instructions; UNIVERSE does not invoke a
host linker or native guest code. Guest musl performs symbol resolution, GOT/PLT
relocations, constructors and TLS initialization. Standalone ET_DYN guests must
need no relocations or perform their own startup relocation. See [musl.md](musl.md).

The initial Linux stack is 16-byte aligned and contains argc, argv, a separately
configured environment and auxv. Auxv includes PHDR/PHENT/PHNUM/PAGESZ/BASE/ENTRY,
UID/GID, AT_RANDOM bytes from the host entropy source, SECURE and EXECFN.
No host environment or host pointer is embedded in the guest stack.
PHDR and ENTRY refer to the rebased main program; BASE is the interpreter's
load bias (zero without an interpreter). This follows the
[Linux ELF handoff](https://github.com/torvalds/linux/blob/master/fs/binfmt_elf.c).
