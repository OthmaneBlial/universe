# Linux guest processes

Current main executes isolated fork children and checked exec replacements on
x86-64, AArch64 and RISC-V64.
The runtime schedules guest CPU contexts itself; it never starts a native host
process to execute a guest binary. This work is newer than v0.1.0.

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/fixtures.py
./zig-out/bin/universe artifacts/guests/x86_64/system fork
./zig-out/bin/universe artifacts/guests/aarch64/system fork
./zig-out/bin/universe artifacts/guests/riscv64/system fork
# process: private memory, identity, masks, pipe bytes, EOF and wait status ok
python3 scripts/public-apps.py
./zig-out/bin/universe --allow-files artifacts/public-apps/busybox sh -c \
  'printf '\''{"answer":42}\n'\'' | ./artifacts/public-apps/jq .answer'
# 42
python3 tests/integration.py
```

All three CPUs and RV64IMC pass in interpreter/JIT modes on ARM64 macOS. The
source fixture independently checks 4,097 patterned pipe bytes, child identity,
private global variables, inherited/independent umasks, WNOHANG, EOF, exit status
37 and one-time reaping. A bad status pointer returns EFAULT and still consumes
the exited child, following Linux's reap-before-status-copy behavior.

## Execution profile

- x86-64 `fork` and three-CPU `clone(SIGCHLD, stack=0)` copy the calling CPU/TLS
  context, with child return zero and parent return the new guest PID. Other
  parent threads remain in the parent; the child starts with only the calling
  context. Thread IDs and process IDs share one monotonically allocated namespace.
  Signal dispositions, the calling mask and alternate stack are inherited;
  the clear-TID registration is reset. Pending-signal delivery is not modeled.
- Memory uses eager independent copies, retaining permissions, maximum
  protections, file-EOF boundaries and mapping metadata. Writes and unmaps in
  one process do not affect the other. Borrowed/shared backing is unsupported
  for fork; Linux shared mmap was already unsupported. Refcounted COW is a
  future optimization if a measured workload needs it.
- Descriptor tables and FD_CLOEXEC flags are copied. Private native descriptor
  duplicates share regular-file offsets and pipe queue/status state. Closing a
  child's descriptor does not close the parent's copy or host standard stream.
  Fork currently rejects active cached directory streams with ENOSYS; broader
  inherited directory traversal remains unverified.
- Guest umasks are independent. Native creation temporarily applies the active
  guest's mask and restores the host mask immediately. Working-directory queries
  still use the host cwd; Linux chdir and filesystem namespaces are unsupported.
- Round-robin process scheduling uses quanta around 4,096 instructions and the
  existing per-process thread scheduler. Blocking pipe/futex/sleep/wait requests
  let other contexts run. Instruction and time budgets remain global. The
  **256 MiB default mapped-memory budget covers all processes together**,
  including eager fork copies. Mapping/fork failures preserve unpublished
  children; exited children release memory and descriptors before being reaped.
  There are at most 64 process records, including zombies, with reusable reaped
  slots and the existing per-process thread/descriptor limits.
- `wait4` supports a specific child, any child or the caller's fixed virtual
  process group, WNOHANG and exit status. Accepted stop/continue flags do not
  invent events; stopping and continuing are unsupported. Clone-child and
  calling-thread selection flags filter the eligible fork children. Unknown
  flags return EINVAL; no eligible child returns ECHILD. Resource-usage output
  returns ENOSYS. Blocking waits retry through the scheduler and respect limits.
- Child exit closes its pipe ends and retains only zombie metadata for wait.
  Orphaned children are adopted by guest PID 1. Exiting that initial process ends
  the CLI run. A child instruction/syscall fault currently stops the whole run;
  it does not synthesize a guest signal or wait status.
- A process switch clears JIT blocks, preventing equal independent memory
  generations from reusing another process's code. Unit checks execute differing
  code bytes with equal generation counters and compare the resulting registers.

## Replacing a guest image

`execve` uses x86-64 syscall 59 and AArch64/RISC-V syscall 221. It requires
`--allow-files`, a regular readable executable file, and an ELF matching the
calling guest CPU. Static ELF, PIE and the existing PT_INTERP profile reuse the
same loader as CLI startup. Exec also checks the interpreter's execute permission.
Absolute paths use the lexical sysroot prefix; relative paths use the host cwd.
No native host execution takes place.

The runtime copies argv and environment strings before discarding old mappings.
Each string is limited to 128 KiB including its NUL; the combined 256 KiB budget
includes strings, vector pointers and the executable filename. Null/empty argv
becomes one empty argv[0]; null environment becomes empty. AT_EXECFN contains
the actual input filename even when argv[0] differs. Host environment stays absent.

A complete new image is staged before publication. Invalid pointers return
EFAULT, oversized arguments E2BIG, missing files/interpreters ENOENT, denied or
non-executable inputs EACCES, unsupported/malformed ELF ENOEXEC, and mapped-memory
exhaustion ENOMEM. Failed loading leaves old memory, thread metadata and
close-on-exec descriptors intact. Unit allocation-failure checks exercise each
staging allocation and preserve shared budget accounting. Old mapped bytes are
credited before charging the replacement, while other processes remain charged.
The bounded full-image staging temporarily keeps both images in host memory;
this is not a peak host-memory guarantee.

Successful exec retains PID, parent, umask, signal mask, ignored signal dispositions
and non-CLOEXEC descriptors with their shared offsets/pipe state. It closes
FD_CLOEXEC descriptors, resets caught signal handlers and alternate-stack state,
removes sibling guest threads/waits, clears old clear-TID registration, and resets
CPU/TLS/heap/mapping and JIT state. Global instruction counts and runtime deadlines
survive replacement. These signal metadata rules do not implement signal delivery.

The source `system exec` fixture forks, changes child metadata, replaces its own
image with a Unicode filename and renamed argv[0], verifies fresh globals and
the above state, then exits 37 through an inherited pipe. The parent checks every
output byte, EOF, wait status and its own unchanged variables/umask. All four CPU
variants pass in both engines. Bad pointers, oversized strings/vectors, permissions,
missing/foreign/malformed images and interpreter failures check rollback; repeated
exec obeys a 30 ms deadline and an exact 5,000-instruction limit. The optional
[musl fixture](musl.md) also passes real ET_EXEC and PIE exec handoffs on all
three CPUs in both engines, with guest constructors, imports and TLS.

The unchanged BusyBox 1.35.0 binary now passes selected command substitution,
subshell and external pipeline cases, including 420 eleven-byte lines checked
byte-for-byte after an exec'd cat. The 12 newer cases per engine include PATH
lookup, exported Unicode environment, redirection, three-stage sort/wc, jq and
ripgrep. These are exact output/status regressions in [public-apps.md](public-apps.md).
Background jobs still reach missing `rt_sigsuspend`/signal delivery. Shebang scripts,
execveat, vfork, clone3, broader clone profiles, waitid, resource accounting and
guest signals remain unsupported. This is not general Linux process compatibility.

Allocation-failure units check unchanged parent bytes, IDs and budget accounting.
Integration checks a waiting parent/spinning child at a 30 ms runtime deadline
and a shared 50,000-instruction limit on all four CPU variants in both engines.
See [security.md](security.md) for the existing host-access profile.
