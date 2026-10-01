#!/usr/bin/env python3
"""Compare real USER32 guest output against pinned original Unicode data, not generated ranges."""
import argparse, hashlib, pathlib, platform, struct, subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--unicode-data',type=pathlib.Path,default=ROOT/'artifacts/unicode-17.0.0/UnicodeData.txt');args=p.parse_args()
raw=args.unicode_data.read_bytes()
assert hashlib.sha256(raw).hexdigest()=='2e1efc1dcb59c575eedf5ccae60f95229f706ee6d031835247d843c11d96470c','Expected original Unicode 17.0.0 data'
expected=list(range(65536))
for line in raw.decode().splitlines():
    fields=line.split(';');point=int(fields[0],16)
    if point<=65535 and fields[12]:expected[point]=int(fields[12],16)
golden=struct.pack('<65536H',*expected)+struct.pack('<65536H',*expected[1:],0)
for mode in [[]]+([['--jit']] if platform.machine() in ['arm64','aarch64'] else []):
    result=subprocess.run([str(ROOT/'zig-out/bin/universe'),*mode,'--max-instructions','20000000','--timeout-ms','30000',str(ROOT/'artifacts/windows-text.exe'),'oracle'],capture_output=True,timeout=40)
    assert result.returncode==0,(mode,result.returncode,result.stderr)
    actual=struct.unpack('<131072H',result.stdout)
    wanted=struct.unpack('<131072H',golden)
    assert actual==wanted,(mode,next((i,a,b) for i,(a,b) in enumerate(zip(actual,wanted)) if a!=b))
    assert not result.stderr,(mode,result.stderr)
print('USER32: 131072 scalar/string unit comparisons per engine against original Unicode 17.0.0 data passed')
