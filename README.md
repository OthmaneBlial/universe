<p align="center">
  <img src="docs/assets/universe-banner.svg" alt="UNIVERSE — one runtime for foreign machine code" width="100%">
</p>

<p align="center">
  <strong>Run software built for another world.</strong><br>
  An experimental binary runtime with its own CPU engine, loaders and OS compatibility layers.
</p>

<p align="center">
  <a href="https://othmaneblial.github.io/universe/">Website</a> &nbsp;·&nbsp;
  <a href="https://github.com/OthmaneBlial/universe/releases/latest">Download</a> &nbsp;·&nbsp;
  <a href="#quick-start">Quick start</a> &nbsp;·&nbsp;
  <a href="docs/compatibility.md">Compatibility</a> &nbsp;·&nbsp;
  <a href="docs/roadmap.md">Roadmap</a>
</p>

<p align="center"><sub>Zig 0.16.0 &nbsp; / &nbsp; macOS + Linux hosts &nbsp; / &nbsp; Apache-2.0</sub></p>

## What works today

UNIVERSE executes foreign machine code on an ARM64 Mac using its own Zig
interpreter and optional ARM64 JIT. Its loaders read Linux ELF64, Windows PE32+
and library-free macOS Mach-O64 binaries. The runtime implements CPU and OS
compatibility itself.

The useful milestone is already here: **unchanged downloaded applications run**.
The tests check their output, exit status and real file bytes in both engines.

| Applications | Verified workflows |
| :--- | :--- |
| **jq · ripgrep · fd** — Linux x86-64 | JSON processing, text searches, file discovery and selected threaded traversal |
| **7-Zip** — Linux and Windows x86-64 | ZIP/7z creation, extraction, hashing, Unicode paths and application error exits |
| **BusyBox** — Linux x86-64 | Utilities, file operations, selected shell scripts, external pipelines, background jobs and signal traps |
| **GNU Hello · coreutils** — dynamic Linux x86-64 | Unchanged glibc loader and libraries; greetings, text/binary processing, sorting, counting, Base64, sleeps, SHA-256, listings and file metadata |
| **Source-built guests** — x86-64, AArch64, RISC-V64 | CPU instructions, memory, threads, processes and selected Linux/Windows/Darwin APIs |

Execution is verified on **Apple M2 / macOS ARM64**. Linux-host builds are
cross-compiled; Linux-host execution remains unverified. Compatibility is
experimental and varies by application. See the [exact supported profile](docs/compatibility.md).

## Quick start

Install **Zig 0.16.0** and **Python 3**, then build and run a tiny foreign guest:

```sh
git clone https://github.com/OthmaneBlial/universe.git
cd universe
zig build -Doptimize=ReleaseSafe
python3 scripts/fixtures.py --arch x86_64
./zig-out/bin/universe artifacts/guests/x86_64/hello-asm
# Hello from x86-64 Linux!
```

On an ARM64 host, add `--jit` to enable the optional JIT. Unsupported operations
still stop with a named error, guest address and instruction bytes. Guest exit
codes pass through; runtime faults return `125`.

## Try a real application

Download scripts verify pinned upstream checksums. Guest applications stay in
`artifacts/` and are not bundled with UNIVERSE.

**Read JSON with Linux jq:**

```sh
python3 scripts/public-apps.py
printf '{"answer":42}\n' | ./zig-out/bin/universe artifacts/public-apps/jq '.answer'
# 42
```

**Run dynamic GNU coreutils with Debian's original libraries:**

```sh
python3 scripts/debian.py --coreutils
printf 'z\na\nb\n' | ./zig-out/bin/universe --allow-files \
  --sysroot artifacts/debian-coreutils-amd64/sysroot \
  artifacts/debian-coreutils-amd64/sysroot/usr/bin/sort
# a
# b
# z
```

**Create an archive with Windows 7-Zip:**

```sh
python3 scripts/public-apps.py --windows
./zig-out/bin/universe --allow-files artifacts/public-apps/7za.exe \
  a -tzip -mmt=off -mx=1 artifacts/readme.zip README.md
# Everything is Ok
```

[Downloaded application checks](docs/public-apps.md) ·
[Debian/glibc](docs/debian.md) · [Windows compatibility](docs/windows.md)

## How it works

```text
ELF / PE / Mach-O
        ↓
Checked guest memory → CPU decoder → Universal IR
                                         ↓
                              Interpreter / ARM64 JIT
                                         ↓
                              OS compatibility layer
                                         ↓
                                  Host services
```

Guest Linux threads have separate CPU/TLS state and futex wait queues. Forked
processes have private memory and descriptors, with shared execution limits.
Windows guests use UNIVERSE's API implementations and execute their own DLL,
TLS and supported C++ cleanup/catch code. macOS guests currently use a small
Darwin syscall subset; dyld and LibSystem remain unsupported.

[Architecture](docs/architecture.md) · [CPU baseline](docs/x86-baseline.md) ·
[Guest memory](docs/memory-model.md) · [Threads](docs/linux-threads.md) ·
[Processes](docs/linux-processes.md) · [JIT](docs/jit.md) · [macOS](docs/macos.md)

## Inspect and debug

```sh
./zig-out/bin/universe inspect artifacts/guests/x86_64/hello-asm
./zig-out/bin/universe inspect --ir --count 8 artifacts/guests/x86_64/hello-asm
./zig-out/bin/universe --stats --jit artifacts/guests/x86_64/hello-asm
./zig-out/bin/universe debug artifacts/guests/x86_64/hello-asm
```

The debugger supports stepping, breakpoints, registers, memory, stack,
disassembly, IR and syscall inspection. [Debugger commands](docs/debugger.md).

## Verify locally

```sh
./scripts/check.sh
```

The full local check rebuilds source guests, checks CPU/API behavior and output
against independent oracles, compares both engines and runs bounded fuzzing.
Optional downloaded-app suites run separately after fetching their inputs:

```sh
python3 tests/public-apps.py
python3 tests/public-apps.py --windows
python3 tests/debian.py
python3 tests/coreutils.py
```

Run `python3 scripts/debian.py` before the Hello suite. GitHub Actions remains
disabled; validation runs locally. [Validation evidence](docs/validation.md) ·
[Measured benchmarks](benchmarks/results.md).

## Boundaries

**Experimental compatibility.** Supported workflows do not establish broad
Windows, Linux or macOS application support, a complete ISA or native performance.
The JIT remains opt-in. [Compatibility and limits](docs/compatibility.md).

**Files are opt-in.** The guest environment is empty unless `--env` is supplied.
`--allow-files` grants access with the host user's permissions, including writes.
The runtime is not a security sandbox. [Security profile](docs/security.md).

## Contribute

Bring a small failing guest, a reproducible command and an expected result.
[Open an issue](https://github.com/OthmaneBlial/universe/issues) or follow the
[roadmap](docs/roadmap.md).

[Apache-2.0](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)
