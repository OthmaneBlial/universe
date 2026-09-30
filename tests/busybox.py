#!/usr/bin/env python3
"""Optional upstream-app regressions, separate from offline core checks."""
import pathlib, platform, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];RUNTIME=ROOT/'zig-out/bin/universe';GUEST=ROOT/'artifacts/busybox-1.37.0/busybox'
def run(args,stdout,code=0):
    p=subprocess.run([str(RUNTIME),*map(str,args)],capture_output=True,timeout=20)
    assert (p.returncode,p.stdout)==(code,stdout),(args,p.returncode,p.stdout,p.stderr)
run([GUEST,'echo','hello'],b'hello\n')
with tempfile.TemporaryDirectory() as tmp:
    path=pathlib.Path(tmp)/'fixture.txt';path.write_bytes(b'BusyBox guest file\n')
    run(['--allow-files',GUEST,'cat',path],path.read_bytes())
    run(["--allow-files",GUEST,"ls",tmp],b"fixture.txt\n")

if platform.machine() in ['arm64','aarch64']:
    run(['--jit',GUEST,'echo','hello'],b'hello\n')
    with tempfile.TemporaryDirectory() as tmp:
        path=pathlib.Path(tmp)/'fixture.txt';path.write_bytes(b'BusyBox guest file\n')
        run(['--jit','--allow-files',GUEST,'cat',path],path.read_bytes())
        run(['--jit','--allow-files',GUEST,'ls',tmp],b'fixture.txt\n')

print('BusyBox echo, cat and ls regressions passed (including JIT on ARM64 hosts)')
