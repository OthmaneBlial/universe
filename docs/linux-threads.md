# Linux guest threads

Current main runs musl pthread machine code on x86-64, AArch64 and RISC-V64.
UNIVERSE schedules separate guest CPU contexts on one host execution thread;
it does not run guest instructions as native code or use a host pthread runtime.
This work is newer than v0.1.0.

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/fixtures.py
./zig-out/bin/universe artifacts/guests/x86_64/pthread
./zig-out/bin/universe artifacts/guests/aarch64/pthread
./zig-out/bin/universe artifacts/guests/riscv64/pthread
# pthread: TLS, mutex, condition wait, joins and shared total=12000 ok
# pthread: CPU preemption, reused slots, TLS and timed condition wait ok
# pthread: scheduler sleeps and timed wakeups ok
# pthread: pipe blocking, backpressure, exact 32769 bytes and EOF ok
python3 tests/integration.py
```

On an ARM64 host, add `--jit` to use register-block compilation with interpreted
atomic and memory operations. All three fixtures pass in both engines. The same
POSIX source built with native macOS clang produces the same four output lines;
its Linux-only checks additionally verify bitset futex opcodes, absolute sleeps
and unchanged successful-sleep remainder buffers.
This is a source oracle, not native Linux differential validation.

## Execution profile

- `clone` accepts the shared VM/FS/files/signal-handler/thread profile, with
  optional TLS, parent/child TID stores and child clear-TID registration.
  New children resume after the syscall with return value zero and their own
  supplied stack. TLS uses x86 FS, AArch64 TPIDR_EL0 or RISC-V tp. IDs are unique
  across guest processes; exited slots are reusable. The limit is 64 live records
  per process, including the initial thread. The isolated
  [clone(SIGCHLD, stack=0) fork profile](linux-processes.md) is supported;
  other process-style clone profiles and `clone3` return ENOSYS.
- Guest memory, heap, descriptors, working directory and umask are shared.
  Signal masks, alternate-stack metadata and clear-TID pointers are per thread.
  Masks are inherited; the child's alternate stack starts disabled. Signal
  delivery itself remains unsupported.
- Round-robin scheduling uses instruction quanta around 4,096 instructions and
  immediate scheduling requests on clone, blocking waits, exit and sched_yield.
  A JIT block can extend a quantum by up to 32 instructions. Instruction totals
  and the execution deadline remain global across every process/thread switch.
- Futex WAIT/WAKE and WAIT_BITSET/WAKE_BITSET check mapped, naturally aligned
  32-bit words. Keys include guest address and private/shared mode; bitsets
  select waiters. Value mismatch returns EAGAIN. WAIT uses a relative monotonic
  timeout; WAIT_BITSET uses an absolute monotonic or CLOCK_REALTIME timeout.
  Expired waits return ETIMEDOUT. All-blocked processes still check the runtime
  deadline. CLOCK_REALTIME with plain WAIT is outside this profile.
- `nanosleep` and `clock_nanosleep` suspend the calling guest, allowing other
  guest contexts to run. Relative sleeps use monotonic time; absolute sleeps
  support CLOCK_MONOTONIC and CLOCK_REALTIME. Expiry returns zero, and futex
  wakes cannot wake a sleep timer. Valid large intervals saturate safely.
  Only TIMER_ABSTIME affects flags, matching Linux's syscall handling. Other
  clocks return explicit errors. Signal interruption remains unsupported, so
  successful calls leave remaining-time buffers untouched.
- Thread exit best-effort clears its registered TID and wakes one shared-key
  waiter. Other threads continue; exit_group ends the process. AArch64
  LDAR/STLR byte, halfword, word and doubleword forms use checked aligned memory.
  Sequential guest execution supplies acquire/release ordering. Any memory
  write, mapping change or thread switch conservatively invalidates exclusive
  reservations.
- Blocking guest pipe reads/writes suspend only the calling context. Empty
  reads and full queues wake when another guest supplies bytes, drains space or
  closes the peer. The scheduler retries the original syscall with its number
  and arguments preserved. The 4 KiB queue enforces atomic writes up to 4 KiB;
  readv/writev use the same path. Nonblocking requests return EAGAIN instead.
  Legacy x86-64 poll also retries without blocking native poll, preserving one
  absolute timeout across retries. All-blocked waits still check runtime limits.

The fixture checks contended mutexes, a condition barrier, separate TLS, joins,
exact shared totals, CPU-bound spin-loop preemption, reused slots and timed
condition waits, scheduler sleeps and absolute clock deadlines. A guest writer
transfers 32,769 patterned bytes through a pipe, while the reader independently
checks every byte in 513-byte chunks, then verifies exact length, join status
and EOF. The initial empty read and repeated 4 KiB writes exercise blocking and
backpressure. Compiler vectorization remains enabled; AArch64's generated
TBL and MLA instructions have independent scalar/native byte checks. Integration
also checks a 30 ms runtime fault during a two-second sleep without
blocking the host for two seconds, an all-blocked execution deadline and
an instruction limit reached after thread creation. Empty pipe reads on all
three CPUs and indefinite x86-64 poll also stop at a 30 ms runtime deadline,
within a one-second wall-time bound. Unit checks cover invalid TID/pipe outputs,
allocation failure, queue/EOF/EPIPE rules, duplicate flags, unchanged retry
registers, poll deadlines, futex keys/masks and thread/group exits.

Robust owner-death recovery, rseq, cancellation, PI/requeue futexes, process
clone profiles beyond the isolated fork subset and cross-process futex synchronization
remain unsupported. [Guest fork/wait](linux-processes.md) copies only the calling
context into a child with private memory/descriptors and inherited TLS. Futex keys do
not recognize distinct virtual addresses aliasing the same backing storage.
Blocking host I/O outside owned guest pipes still serializes all guest threads
and is not interrupted by the execution timeout. Pipe writes return EPIPE
without guest SIGPIPE delivery. Dynamic-library pthread TLS, general threaded applications
and native Linux behavior remain unverified. Windows and Mach-O guest thread
creation remain unsupported. See [security.md](security.md) for host access.
