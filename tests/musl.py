#!/usr/bin/env python3
"""Optional real guest ldso, DSO, constructor and single-thread TLS regression."""
import argparse, pathlib, platform, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'zig-out/bin/universe'
parser = argparse.ArgumentParser()
parser.add_argument('--arch', choices=['x86_64', 'aarch64', 'all'], default='x86_64')
args = parser.parse_args()
architectures = ['x86_64', 'aarch64'] if args.arch == 'all' else [args.arch]
output = b'dynamic musl: imports, constructors and TLS ok\n'
def run(args, code=0, stdout=b'', error=None):
    result = subprocess.run([str(RUNTIME), *map(str, args)], capture_output=True, timeout=20)
    assert (result.returncode, result.stdout) == (code, stdout), (args, result.returncode, result.stdout, result.stderr)
    if error is not None:
        assert error in result.stderr, result.stderr
    return result
for arch in architectures:
    suffix = '' if arch == 'x86_64' else '-' + arch
    sysroot = ROOT / 'artifacts' / ('musl' + suffix + '-sysroot')
    for name in ['musl-dynamic' + suffix, 'musl-dynamic' + suffix + '-pie']:
        guest = ROOT / 'artifacts' / name
        run([guest, 'check'], code=125, error=b'MissingSysroot')
        run(['--sysroot', sysroot, guest, 'check'], code=125, error=b'FileAccessDenied')
        args = ['--allow-files', '--sysroot', sysroot, '--env', 'UNIVERSE_TEST=dynamic', guest, 'check']
        run(args, stdout=output)
        if platform.machine() in ['arm64', 'aarch64']:
            run(['--jit', *args], stdout=output)
    print(f'Dynamic {arch} musl ET_EXEC and PIE, DSO constructors and TLS passed (including JIT on ARM64 hosts)', flush=True)
