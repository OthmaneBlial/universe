# UNIVERSE

**Run software that was never built for your computer.**

UNIVERSE is an experimental universal binary runtime written in Zig. It executes
real Linux x86-64, RISC-V and AArch64 machine code through its own ELF loader,
instruction decoders, universal IR, interpreter and syscall compatibility layer.
No QEMU, Wine, Rosetta or emulator library is involved.

## Try it

Requires **Zig 0.16.0**, Python 3 and macOS or Linux.

```sh
git clone https://github.com/OthmaneBlial/universe.git
cd universe
zig build -Doptimize=ReleaseSafe
python3 scripts/fixtures.py
file artifacts/guests/x86_64/hello-asm
uname -m
./zig-out/bin/universe artifacts/guests/x86_64/hello-asm
# Hello from x86-64 Linux!
./zig-out/bin/universe artifacts/guests/riscv64/compute
# compute: ok
./zig-out/bin/universe artifacts/guests/aarch64/system
# system: ok
```

The x86-64 demo and five C programs for each guest architecture were executed
locally on ARM64 macOS. Guests are rebuilt from source by Zig's cross compiler.
Zig/Clang is only a build tool; the runtime implements CPU execution itself.

| Guest | Format | Host verified | Status |
|---|---|---|---|
| Linux x86-64 | ELF64 | macOS ARM64 | Executes assembly + libc-free C fixtures |
| Linux RISC-V64 | ELF64 | macOS ARM64 | Executes RV64IM C fixtures |
| Linux AArch64 | ELF64 | macOS ARM64 | Executes integer C fixtures |
| Windows x86-64 | PE32+ | — | Planned |
| macOS | Mach-O | — | Planned |

This is **partial compatibility**, not general Linux application support.
Dynamic linking, libc, BusyBox, SIMD and threads are not currently advertised.
See [exact instruction/syscall coverage and limits](docs/compatibility.md).

## Observe execution

```sh
./zig-out/bin/universe inspect artifacts/guests/x86_64/hello-asm
./zig-out/bin/universe inspect --ir --count 8 artifacts/guests/x86_64/hello-asm
./zig-out/bin/universe trace artifacts/guests/riscv64/hello
./zig-out/bin/universe --stats --trace-instructions artifacts/guests/x86_64/compute
./zig-out/bin/universe --env KEY=value artifacts/guests/aarch64/arguments foo bar
./zig-out/bin/universe debug artifacts/guests/x86_64/hello-asm
```

Debugger commands: run, continue, step, break, registers, memory, stack, disasm,
ir, syscalls, quit. Unsupported behavior stops with guest PC, bytes and a named
error; guest exit codes pass through, runtime faults return 125.

## Design

```mermaid
flowchart LR
    ELF[ELF64 guest] --> Memory[Guest memory]
    Memory --> CPU[x86-64 / RV64IM / AArch64]
    CPU --> UIR
    UIR --> Interpreter[Zig interpreter]
    Interpreter --> Linux[Linux ABI translation]
    Linux --> Host[POSIX host]
```

- [Architecture and ownership](docs/architecture.md)
- [UIR](docs/uir.md)
- [Compatibility](docs/compatibility.md)
- [Security status](docs/security.md)
- [Roadmap](docs/roadmap.md)

## Validate locally

```sh
./scripts/check.sh
```

This formats/checks sources, builds in ReleaseSafe, runs Zig unit/fuzz-seed
checks, rebuilds all foreign guests and verifies output, exit codes, filesystem
effects, syscall behavior, malformed input and memory faults. Native differential
tests run when the script is on a matching Linux host. GitHub Actions is disabled
at the owner's request. No workflow is installed.

## Security

This is **not a security sandbox**. Guest memory permissions, resource limits
and syscall validation reduce accidental exposure; there has been no independent
security review. The guest environment is empty unless `--env` is provided.
Files are denied by default. `--allow-files` grants host-user file privileges,
including creation and truncation. Use it only with trusted binaries.

Apache-2.0. Contributions should include a failing guest fixture or a small
instruction regression and a reproducible local check.
