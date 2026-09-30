# ELF loader

ELF64, little-endian, version 1, ET_EXEC and Linux/System V OSABI are accepted.
The parser recognizes x86-64, AArch64 and RISC-V machine IDs. Inspection accepts
ET_DYN, while execution rejects it, PT_INTERP and PT_DYNAMIC. Header and program
header ranges, entry placement, segment sizes, file ranges, overflow, alignment
and permissions are validated before mapping.

PT_LOAD regions are mapped at 4 KiB guest page boundaries. File bytes are copied
by the loader and the remainder stays zero (BSS). Overlapping pages are rejected;
there is no accidental merging of permissions. Code is executable only when the
segment permits it. Sections are optional metadata, not required for execution.
ET_EXEC fixtures require no relocation; dynamic ELF relocations are not supported.

The initial Linux stack is 16-byte aligned and contains argc, argv, a separately
configured environment and auxv. Auxv includes PHDR/PHENT/PHNUM/PAGESZ/ENTRY,
UID/GID, AT_RANDOM bytes from the host entropy source, SECURE and EXECFN.
No host environment or host pointer is embedded in the guest stack.
