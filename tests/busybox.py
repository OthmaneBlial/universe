#!/usr/bin/env python3
"""Optional upstream-app regressions, separate from offline core checks."""
import os, pathlib, platform, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];RUNTIME=ROOT/'zig-out/bin/universe';GUEST=ROOT/'artifacts/busybox-1.37.0/busybox'
def run(args,stdout,code=0,input=None):
    p=subprocess.run([str(RUNTIME),*map(str,args)],input=input,capture_output=True,timeout=20)
    assert (p.returncode,p.stdout)==(code,stdout),(args,p.returncode,p.stdout,p.stderr)
modes=[[]]+([['--jit']] if platform.machine() in ['arm64','aarch64'] else [])
for mode in modes:
    run([*mode,GUEST,'echo','hello'],b'hello\n')
    run([*mode,GUEST,'true'],b'')
    run([*mode,GUEST,'false'],b'',code=1)
    run([*mode,GUEST,'test','7','-eq','7'],b'')
    run([*mode,GUEST,'test','7','-ne','7'],b'',code=1)
    run([*mode,GUEST,'printf','%s:%04d\\n','guest','7'],b'guest:0007\n')
    run([*mode,GUEST,'basename','/tmp/item.txt','.txt'],b'item\n')
    run([*mode,GUEST,'dirname','/tmp/item.txt'],b'/tmp\n')
    run([*mode,GUEST,'uname','-s'],b'Linux\n')
    run([*mode,GUEST,'uname','-m'],b'x86_64\n')
    run([*mode,GUEST,'wc','-l'],b'2\n',input=b'a\nb\n')
    run([*mode,GUEST,'head','-n','1'],b'b\n',input=b'b\na\n')
    run([*mode,GUEST,'tail','-n','1'],b'a\n',input=b'b\na\n')
    run([*mode,GUEST,'cut','-d:','-f2'],b'1\n2\n',input=b'a:1\nb:2\n')
    run([*mode,GUEST,'sort'],b'a\nb\n',input=b'b\na\n')
    run([*mode,GUEST,'grep','needle'],b'needle one\n',input=b'needle one\nother\n')
    run([*mode,GUEST,'grep','-i','NEEDLE'],b'needle one\n',input=b'needle one\nother\n')
    run([*mode,GUEST,'sed','s/blue/red/g'],b'red car red\n',input=b'blue car blue\n')
    run([*mode,GUEST,'tr','a-z','A-Z'],b'XYZ\n',input=b'xyz\n')
    run([*mode,GUEST,'uniq'],b'a\nb\n',input=b'a\na\nb\nb\n')
    with tempfile.TemporaryDirectory() as tmp:
        path=pathlib.Path(tmp)/'fixture.txt';path.write_bytes(b'BusyBox guest file\n')
        run([*mode,'--allow-files',GUEST,'cat',path],path.read_bytes())
        run([*mode,'--allow-files',GUEST,'ls',tmp],b'fixture.txt\n')
        copied=pathlib.Path(tmp)/'copied.txt'
        run([*mode,'--allow-files',GUEST,'cp',path,copied],b'')
        assert copied.read_bytes()==path.read_bytes()
        moved=pathlib.Path(tmp)/'moved.txt'
        run([*mode,'--allow-files',GUEST,'mv',copied,moved],b'')
        assert not copied.exists() and moved.read_bytes()==path.read_bytes()
        touched=pathlib.Path(tmp)/'touched.txt'
        run([*mode,'--allow-files',GUEST,'touch',touched],b'')
        assert touched.exists()
        os.utime(touched,(1,1))
        run([*mode,'--allow-files',GUEST,'touch',touched],b'')
        assert touched.stat().st_mtime_ns>1_000_000_000
        directory=pathlib.Path(tmp)/'created'
        run([*mode,'--allow-files',GUEST,'mkdir',directory],b'')
        assert directory.is_dir()
        removable=directory/'item';removable.write_bytes(b'guest file\n')
        run([*mode,'--allow-files',GUEST,'rm',removable],b'')
        assert not removable.exists()
        run([*mode,'--allow-files',GUEST,'rmdir',directory],b'')
        assert not directory.exists()

print('BusyBox selected applets passed (including JIT on ARM64 hosts)')
