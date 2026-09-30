# Security status

Experimental, not independently reviewed and **not a security sandbox**. Do not
run hostile binaries outside a separately isolated operating system environment.

Guest addresses index bounded allocations; they never become arbitrary host
pointers. Mappings enforce permissions for reads, writes and instruction fetch.
The loader checks file ranges, integer overflows, segment sizes, alignment and
entry permissions. The default guest memory cap is 256 MiB, file input cap 64 MiB,
stack 1 MiB, heap reservation 16 MiB, mapping count 1024. Execution defaults to
10 million instructions and 10 seconds, checked every 4096 instructions.
A blocking host stdin read or file operation is not interrupted by this timeout.

Host environment is not inherited. Linux guest environment entries require
`--env`; Windows guest environment entries are currently rejected.
Host files are denied by default. **`--allow-files` gives the guest host-user file
privileges**, including creation and truncation. It is not a confined virtual
filesystem. Network, process creation, exec and threads are not implemented.
`--sysroot` lexically prefixes absolute Linux paths, including PT_INTERP, and
absolute host-style Windows file paths;
relative paths still use the host working directory or an open directory FD.
Static Windows DLL dependencies use bare filenames within the explicit sysroot.
Host symlink targets can escape that prefix. It is not chroot or a security policy.
Guest standard streams are attached to host standard streams.

Host I/O validates guest buffers before performing side effects. Native pointers
and host structure layouts are not exposed. Unsupported CPU instructions and
syscalls stop with an explicit diagnostic (runtime status 125). Implemented
syscall failures return Linux negative errno values; Windows API failures use
Win32 return values and guest last-error state. File sharing checks cover open
handles within one runtime, not other host processes.

Parser and decoder fuzz seed tests are built into `zig build test`. The local
check additionally runs `zig build fuzz -- 10000 <corpus paths>`: deterministic
mutations of valid ELF/PE files, checked export lookup on loadable DLL mutations,
and random decoding/interpreting for every CPU. Guest DLL initializers are subject
to the normal execution limits; module graphs and forwarding depth are bounded.
The Zig 0.16.0 coverage-guided `--fuzz` runner failed to compile in the installed
toolchain (StackTrace type mismatch in its test_runner); it is not reported as
a successful fuzz campaign. Reproducible malformed-input and invalid-memory
integration cases are also run by the local check script. Passing these is not
a claim that all malicious inputs have been ruled out.

The ARM64 JIT creates RW host pages and switches them to RX before execution;
code invalidation and execute permission checks are tested. Native code only
accesses the bounded register array, not guest-selected host pointers. Windows
API gateways validate guest buffers and serialize arguments explicitly.
