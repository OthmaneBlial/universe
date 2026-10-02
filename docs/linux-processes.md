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
  the clear-TID registration is reset. Pending signals start empty in the child.
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
CPU/TLS/heap/mapping and JIT state. Pending signals, global instruction counts
and runtime deadlines survive replacement.

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
Selected background jobs and signal traps also run with allowed host files;
the exact profile follows below. Shebang scripts, execveat, vfork, clone3, broader
clone profiles, waitid and resource accounting remain unsupported.
This is not general Linux process compatibility.

Allocation-failure units check unchanged parent bytes, IDs and budget accounting.
Integration checks a waiting parent/spinning child at a 30 ms runtime deadline
and a shared 50,000-instruction limit on all four CPU variants in both engines.
See [security.md](security.md) for the existing host-access profile.

## Guest signals and interrupted waits

Standard process-directed signals use a coalescing pending set and the first
sender's 128-byte siginfo. `kill`, `rt_sigpending`, `rt_sigsuspend` and
`rt_sigreturn` join the existing handler, mask and alternate-stack calls on all
three CPUs. `kill` targets only this run's guest PID/TID namespace; signal zero
checks existence. PID zero targets the fixed virtual group; PID -1 targets its
other noninitial processes. Other negative groups return ESRCH. Real-time
signals 32–64 and stop/continue signals 18–22 return ENOSYS. Host signals and
Ctrl-C are not forwarded, and virtual PID 1 is an ordinary guest entry process.

Caught signals select an unmasked live context, build a checked Linux frame,
and enter guest machine code. Frames save integer registers, masks and modeled
FP/vector state; return honors guest edits to ucontext. SA_SIGINFO, SA_ONSTACK,
SA_NODEFER, SA_RESETHAND and SS_AUTODISARM affect delivery. x86-64 requires
SA_RESTORER; AArch64 accepts it or uses a checked RX return stub. RISC-V uses
that stub. Each fallback stub occupies one budgeted guest page per image;
it is not a vDSO. Legacy x86 FXSAVE, AArch64 FPSIMD and RISC-V F/D state are
supported; XSAVE, SVE, RVV and other frame extensions fail explicitly.
Bad frames/handlers stop the CLI with a named fault; native SIGSEGV fault
delivery is not synthesized.

SIG_IGN discards pending/future signals. Default SIGCHLD, SIGURG and SIGWINCH
are ignored; other supported default actions terminate the guest process and
produce a signal wait status. A broken guest pipe queues SIGPIPE and returns
EPIPE; default handling ends the writer, while an ignored/blocked/caught signal
leaves EPIPE available. Host signal disposition remains untouched.

Child exit queues SIGCHLD with CLD_EXITED or CLD_KILLED and its PID, UID and
status. Explicit SIGCHLD ignore or SA_NOCLDWAIT releases the child without a
zombie; otherwise wait4 reaps it normally. Standard coalescing does not promise
one handler call per child. `rt_sigsuspend` saves the original mask, installs the
temporary mask and blocks until a caught signal; returning restores the saved
mask and EINTR. All-blocked waits still honor the runtime deadline.

SA_RESTART retries blocked guest pipe I/O, wait4 and untimed futex waits with
their original syscall arguments. Poll, sleeps and timed futex waits return
EINTR after a caught handler. Interrupted relative sleeps write checked remaining
time; successful sleeps leave that buffer untouched. Native file/terminal I/O
can still block the host; this scheduler profile covers guest waits.

The libc-free `signals` source fixture uses Zig's installed musl signal/ucontext
declarations as independent ABI checks, without linking libc. Both engines on
all four CPU variants check coalescing, siginfo, alternate-stack addresses,
ucontext mask/register edits, pipe restart/EINTR, sleep remainder, timed-futex
interruption, child reaping, SIGKILL/SIGPIPE status and a blocked-suspend deadline.
Units also cover FP/vector state, malformed-frame rollback and reset/nodefer
flags. These are source ABI oracles; native Linux differential execution remains
unverified. Layouts and restart behavior follow the Linux sources for
[x86-64](https://github.com/torvalds/linux/blob/master/arch/x86/kernel/signal_64.c),
[AArch64](https://github.com/torvalds/linux/blob/master/arch/arm64/kernel/signal.c),
[RISC-V](https://github.com/torvalds/linux/blob/master/arch/riscv/kernel/signal.c)
and [timed futex waits](https://github.com/torvalds/linux/blob/v6.12/kernel/futex/waitwake.c).

```sh
./zig-out/bin/universe artifacts/guests/x86_64/signals s
# signals: mask, coalescing, siginfo, alternate stack and edited ucontext ok
./zig-out/bin/universe artifacts/public-apps/busybox sh -c \
  'trap '\''echo caught'\'' USR1; kill -USR1 $$; echo hi & wait'
# caught
# hi
```

BusyBox opens `/dev/null` before applying background redirections. That path
now uses an [internal guest device](linux-devices.md), so ten selected signal
and background cases per engine also pass inside a sysroot without file grants.
Twelve cases per engine run with grants too, including external jq/cat jobs;
no native `/dev/null` entry is required in the sysroot. A general device tree,
thread-directed tgkill/tkill, real-time queues, timer-generated signals, sockets,
terminal control and general interactive shell compatibility remain unverified
or unsupported as described above.
