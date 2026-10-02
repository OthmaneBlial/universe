#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
zig fmt --check build.zig src
zig build -Doptimize=ReleaseSafe
zig build test --summary all
python3 scripts/fixtures.py
if [ "$(uname -s)" = Darwin ]; then python3 scripts/macos.py; fi
python3 tests/integration.py
python3 tests/windows-time.py
python3 tests/windows-console.py
python3 tests/windows-mapping.py
python3 tests/windows-disk.py
python3 tests/windows-encoding.py
python3 tests/windows-modules.py
python3 tests/windows-local.py
python3 tests/windows-message.py
python3 tests/windows-directory.py
python3 tests/windows-drives.py
python3 tests/windows-find.py
python3 tests/windows-stream.py
python3 tests/windows-metadata.py
python3 tests/windows-device.py
python3 tests/windows-stack.py
python3 tests/x86-baseline.py
python3 tests/x86-stream.py
python3 tests/x86-mxcsr.py
python3 tests/x87.py
python3 tests/x87-arithmetic.py
python3 tests/x87-environment.py
python3 scripts/check-site.py
set -- artifacts/guests/x86_64/hello-asm artifacts/guests/riscv64/hello artifacts/guests/x86_64/pthread artifacts/guests/riscv64/pthread artifacts/guests/aarch64/pthread artifacts/guests/riscv64/compressed/hello artifacts/guests/riscv64/atomics artifacts/guests/riscv64/floating artifacts/guests/aarch64/hello artifacts/hello.exe artifacts/windows-automation.exe artifacts/windows-automation-ordinal.exe artifacts/windows-text.exe artifacts/windows-security.exe artifacts/windows-crt.exe artifacts/windows-sync.exe artifacts/windows-fileops.exe artifacts/windows-time.exe artifacts/windows-console.exe artifacts/windows-mapping.exe artifacts/windows-encoding.exe artifacts/windows-modules.exe artifacts/windows-local.exe artifacts/windows-message.exe artifacts/windows-directory.exe artifacts/windows-find.exe artifacts/windows-device.exe artifacts/windows-stack.exe artifacts/windows-unwind.exe artifacts/windows-exception.exe artifacts/windows-dynamic.exe artifacts/windows-tls.exe artifacts/windows-tls-dynamic.exe artifacts/windows-sysroot/windows-helper.dll artifacts/windows-sysroot/windows-probe.dll artifacts/windows-sysroot/windows-late.dll artifacts/windows-sysroot/windows-tls.dll artifacts/windows-sysroot/windows-cycle-a.dll artifacts/windows-sysroot/windows-cycle-b.dll
if [ "$(uname -s)" = Darwin ]; then set -- "$@" artifacts/macos/x86_64/hello artifacts/macos/aarch64/hello; fi
zig build fuzz -- 10000 "$@"
