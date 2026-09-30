#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
zig fmt --check build.zig src
zig build -Doptimize=ReleaseSafe
zig build test --summary all
python3 scripts/fixtures.py
python3 tests/integration.py
