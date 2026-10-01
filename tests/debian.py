#!/usr/bin/env python3
"""Optional real glibc boundary check; run scripts/debian.py first."""
import pathlib
import platform
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'zig-out/bin/universe'
SYSROOT = ROOT / 'artifacts/debian-hello-amd64/sysroot'
GUEST = SYSROOT / 'usr/bin/hello'
modes = [[]] + ([['--jit']] if platform.machine() in ['arm64', 'aarch64'] else [])
for mode in modes:
    result = subprocess.run([
        str(RUNTIME), *mode, '--stats', '--syscalls', '--allow-files',
        '--sysroot', str(SYSROOT), str(GUEST),
    ], capture_output=True, timeout=20)
    assert result.returncode == 127, (result.returncode, result.stdout, result.stderr)
    assert result.stdout == b'', result.stdout
    assert b'/lib/x86_64-linux-gnu/libc.so.6: CPU ISA level is lower than required\n' in result.stderr, result.stderr
    assert b'UNIVERSE FAULT' not in result.stderr, result.stderr
    for operation in [b'set_robust_list', b'rseq']:
        assert re.search(rb'syscall ' + operation + rb'\([^\n]+\) = -38\n', result.stderr), result.stderr
    assert re.search(rb'syscall exit_group\(7f,', result.stderr), result.stderr
    assert re.search(rb'instructions=\d+ syscalls=\d+', result.stderr), result.stderr
print('Debian Hello/glibc: loader, TLS and honest CPU-baseline rejection passed (interpreter/JIT on ARM64 hosts)')
