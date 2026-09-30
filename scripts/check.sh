#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
zig fmt --check build.zig src
zig build -Doptimize=ReleaseSafe
zig build test --summary all
python3 scripts/fixtures.py
python3 tests/integration.py
python3 scripts/check-site.py
zig build fuzz -- 10000 artifacts/guests/x86_64/hello-asm artifacts/guests/riscv64/hello artifacts/guests/aarch64/hello artifacts/hello.exe artifacts/windows-sysroot/windows-helper.dll artifacts/windows-sysroot/windows-probe.dll
