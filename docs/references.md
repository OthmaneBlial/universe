# Implementation references

Core parsers and execution engines are implemented in this repository. These
primary specifications describe the formats/ABIs; they are not dependencies.

- [System V ELF program headers](https://refspecs.linuxfoundation.org/elf/gabi4+/ch5.pheader.html)
- [Intel instruction reference](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)
- [RISC-V RV64I specification](https://docs.riscv.org/reference/isa/unpriv/rv64.html)
- [RISC-V unprivileged ISA specifications](https://docs.riscv.org/reference/isa/unpriv/unpriv-index.html)
- [Arm A64 ISA overview](https://developer.arm.com/community/arm-community-blogs/b/architectures-and-processors-blog/posts/the-a64-isa-and-compilers)
- [Arm A64 instruction reference](https://documentation-service.arm.com/static/67e40f3398aa3c3b6eea6a85)
- [Linux AArch64 open-flag encodings](https://github.com/torvalds/linux/blob/master/arch/arm64/include/uapi/asm/fcntl.h)
- [Linux syscall calling conventions](https://man7.org/linux/man-pages/man2/syscall.2.html)
- [Linux ELF interpreter and auxiliary-vector handoff](https://github.com/torvalds/linux/blob/master/fs/binfmt_elf.c)
- [Linux mmap semantics](https://man7.org/linux/man-pages/man2/mmap.2.html)
- [Microsoft PE/COFF format](https://learn.microsoft.com/en-us/windows/win32/debug/pe-format)
- [Windows x64 calling convention](https://learn.microsoft.com/en-us/cpp/build/x64-calling-convention)
- [Windows file creation and sharing](https://learn.microsoft.com/en-us/windows/win32/api/fileapi/nf-fileapi-createfilew)
- [Windows process heap reallocation](https://learn.microsoft.com/en-us/windows/win32/api/heapapi/nf-heapapi-heaprealloc)
- [Microsoft CRT command-line parsing](https://learn.microsoft.com/en-us/cpp/c-language/parsing-c-command-line-arguments)
