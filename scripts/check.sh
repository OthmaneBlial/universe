#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
zig fmt --check build.zig src
zig build -Doptimize=ReleaseSafe
zig build test --summary all
python3 scripts/fixtures.py
if [ "$(uname -s)" = Darwin ]; then python3 scripts/macos.py; fi
python3 tests/integration.py
python3 scripts/check-site.py
set -- artifacts/guests/x86_64/hello-asm artifacts/guests/riscv64/hello artifacts/guests/riscv64/compressed/hello artifacts/guests/riscv64/atomics artifacts/guests/aarch64/hello artifacts/hello.exe artifacts/windows-sysroot/windows-helper.dll artifacts/windows-sysroot/windows-probe.dll
if [ "$(uname -s)" = Darwin ]; then set -- "$@" artifacts/macos/x86_64/hello artifacts/macos/aarch64/hello; fi
zig build fuzz -- 10000 "$@"
