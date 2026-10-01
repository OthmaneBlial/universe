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
python3 tests/integration.py
```

On an ARM64 host, add `--jit` to use register-block compilation with interpreted
atomic and memory operations. All three fixtures pass in both engines. The same
POSIX source built with native macOS clang produces the same two output lines;
its Linux-only checks additionally verify the UAPI bitset futex opcode values.
This is a source oracle, not native Linux differential validation.

## Execution profile

- `clone` accepts the shared VM/FS/files/signal-handler/thread profile, with
  optional TLS, parent/child TID stores and child clear-TID registration.
  New children resume after the syscall with return value zero and their own
  supplied stack. TLS uses x86 FS, AArch64 TPIDR_EL0 or RISC-V tp. IDs are unique
  within the process; exited slots are reusable. The limit is 64 live records,
  including the initial thread. Process-style clone and `clone3` return ENOSYS.
- Guest memory, heap, descriptors, working directory and umask are shared.
  Signal masks, alternate-stack metadata and clear-TID pointers are per thread.
  Masks are inherited; the child's alternate stack starts disabled. Signal
  delivery itself remains unsupported.
- Round-robin scheduling uses instruction quanta around 4,096 instructions and
  immediate scheduling requests on clone, blocking waits, exit and sched_yield.
  A JIT block can extend a quantum by up to 32 instructions. Instruction totals
  and the execution deadline remain process-wide across every context switch.
- Futex WAIT/WAKE and WAIT_BITSET/WAKE_BITSET check mapped, naturally aligned
  32-bit words. Keys include guest address and private/shared mode; bitsets
  select waiters. Value mismatch returns EAGAIN. WAIT uses a relative monotonic
  timeout; WAIT_BITSET uses an absolute monotonic or CLOCK_REALTIME timeout.
  Expired waits return ETIMEDOUT. All-blocked processes still check the runtime
  deadline. CLOCK_REALTIME with plain WAIT is outside this profile.
- Thread exit best-effort clears its registered TID and wakes one shared-key
  waiter. Other threads continue; exit_group ends the process. AArch64
  LDAR/STLR byte, halfword, word and doubleword forms use checked aligned memory.
  Sequential guest execution supplies acquire/release ordering. Any memory
  write, mapping change or thread switch conservatively invalidates exclusive
  reservations.

The fixture checks contended mutexes, a condition barrier, separate TLS, joins,
exact shared totals, CPU-bound spin-loop preemption, reused slots and timed
condition waits. Integration also checks an all-blocked execution deadline and
an instruction limit reached after thread creation. Unit checks cover invalid
TID outputs, allocation failure, futex keys/masks and thread/group exits.

Robust owner-death recovery, rseq, cancellation, PI/requeue futexes, process
creation and cross-process synchronization remain unsupported. Futex keys do
not recognize distinct virtual addresses aliasing the same backing storage.
Blocking host I/O serializes all guest threads and is not interrupted by the
execution timeout. Dynamic-library pthread TLS, general threaded applications
and native Linux behavior remain unverified. Windows and Mach-O guest thread
creation remain unsupported. See [security.md](security.md) for host access.
