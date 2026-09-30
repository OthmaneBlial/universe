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

Host environment is not inherited. Guest environment entries require `--env`.
Host files are denied by default. **`--allow-files` gives the guest host-user file
privileges**, including creation and truncation. It is not a confined virtual
filesystem. Network, process creation, exec and threads are not implemented.
Guest standard streams are attached to host standard streams.

Host I/O validates guest buffers before performing side effects. Native pointers
and host structure layouts are not exposed. Unsupported CPU instructions and
syscalls stop with an explicit diagnostic (runtime status 125). Implemented
syscall failures return Linux negative errno values.

Parser and decoder fuzz tests are built into `zig build test`; sustained fuzzing
uses `zig build test --fuzz`. Reproducible malformed-input and invalid-memory
integration cases are also run by the local check script. Passing these is not
a claim that all malicious inputs have been ruled out.
