#!/usr/bin/env python3
"""SDK guest local-memory lifetimes and byte preservation against independent sequences."""
import pathlib, platform, struct, subprocess

ROOT=pathlib.Path(__file__).resolve().parents[1]
RUNTIME=ROOT/'zig-out/bin/universe';GUEST=ROOT/'artifacts/windows-local.exe'
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
INITIAL=(0,1,17,4095,4096,4097);SIZES=(7,4095,4097,8193,3,0,19)
def run(mode,*args):
    return subprocess.run([str(RUNTIME),*mode,'--max-instructions','30000000','--timeout-ms','20000',str(GUEST),*args],capture_output=True,timeout=30)
for mode in MODES:
    result=run(mode)
    assert result.returncode==0 and result.stdout==b'windows local: fixed/movable memory, resize, locks, discard and ownership ok\n' and not result.stderr,result
    result=run(mode,'records');assert result.returncode==0 and not result.stderr,result
    offset=0;checks=0
    for movable in range(2):
        for start,initial in enumerate(INITIAL):
            seed=movable*41+start;previous=bytes((n*37+seed)&255 for n in range(initial))
            for step,size in enumerate(SIZES):
                kind,index,number,actual,flags,error,stable=struct.unpack_from('<7I',result.stdout,offset);offset+=28
                assert (kind,index,number,actual,flags,error)==(movable,start,step,size,0x4000 if movable and not size else 0,777)
                if movable:assert stable==1
                expected=previous[:size]+bytes(max(0,size-len(previous)))
                assert result.stdout[offset:offset+actual]==expected,(mode,movable,start,step,size)
                offset+=actual;checks+=1;seed+=17
                previous=bytes((n*37+seed)&255 for n in range(size))
    assert offset==len(result.stdout),(offset,len(result.stdout))
    fault=run(mode,'fault')
    assert fault.returncode==125 and b'UnmappedMemory' in fault.stderr and not fault.stdout,fault
    print(f'Windows local {mode or ["interpreter"]}: {checks} exact resize/zero-fill byte sequences, fixed/movable ownership, locks, discarded handles, errors and use-after-free faults passed',flush=True)
