#!/usr/bin/env python3
"""Exercise Win64 entry home slots before a prologue allocates local storage."""
import pathlib,platform,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
for engine in [[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else []):
    result=subprocess.run([str(ROOT/'zig-out/bin/universe'),'run',*engine,str(ROOT/'artifacts/windows-stack.exe')],capture_output=True,timeout=5)
    assert result.returncode==0 and result.stdout==b'windows entry: aligned stack and all four home slots ok\n' and not result.stderr,result
    print(f'Windows entry {engine or ["interpreter"]}: real guest home-slot stores and stack alignment passed',flush=True)
