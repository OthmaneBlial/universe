#!/usr/bin/env python3
"""SDK guest module paths against actual host load spellings and independent codecs."""
import os, pathlib, platform, select, shutil, struct, subprocess, tempfile

ROOT=pathlib.Path(__file__).resolve().parents[1]
RUNTIME=str(ROOT/'zig-out/bin/universe')
GUEST=ROOT/'artifacts/windows-modules.exe'
DLL=ROOT/'artifacts/windows-sysroot/windows-helper.dll'
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
def command(mode,guest,*args,sysroot=None):
    return [RUNTIME,*mode,'--max-instructions','100000000','--timeout-ms','20000',*(['--allow-files','--sysroot',sysroot] if sysroot is not None else []),str(guest),*args]
def verify(data,paths):
    offset=0;checks=0
    for path in paths:
        length=struct.unpack_from('<I',data,offset)[0];offset+=4
        encoded=path.encode('utf-8')
        assert data[offset:offset+length]==encoded,(data[offset:offset+length],encoded)
        offset+=length
        for wide in (False,True):
            encoded=path.encode('utf-16-le' if wide else 'utf-8');unit=2 if wide else 1
            for capacity in range(len(encoded)//unit+3):
                kind,size,result,error,count=struct.unpack_from('<5I',data,offset);offset+=20
                assert (kind,size,count)==(int(wide),capacity,capacity*unit+8)
                expected=b'\xaa'*count
                if capacity:
                    copied=min(len(encoded)//unit,capacity-1)
                    prefix=encoded[:copied*unit]+b'\0'*unit
                    expected=prefix+expected[len(prefix):]
                expected_result=len(encoded)//unit if capacity>len(encoded)//unit else capacity
                expected_error=777 if capacity>len(encoded)//unit else 122
                assert (result,error)==(expected_result,expected_error),(wide,capacity,result,error)
                assert data[offset:offset+count]==expected,(wide,capacity,data[offset:offset+count].hex(),expected.hex())
                offset+=count;checks+=1
    assert offset==len(data),(offset,len(data))
    return checks
def run(mode,guest,args,paths,cwd=None,sysroot=None):
    result=subprocess.run(command(mode,guest,*args,sysroot=sysroot),cwd=cwd,capture_output=True,timeout=30)
    assert result.returncode==0 and not result.stderr,(mode,result.returncode,result.stderr[-1000:])
    return verify(result.stdout,paths)

for mode in MODES:
    checks=0
    default=subprocess.run(command(mode,GUEST),capture_output=True,timeout=5)
    assert default.returncode==0 and default.stdout==b'windows modules: loaded paths, Unicode, truncation and errors ok\n' and not default.stderr,default
    with tempfile.TemporaryDirectory() as tmp:
        root=pathlib.Path(tmp);cwd=str(root.resolve())
        guest=root/'main é🚀.exe';shutil.copyfile(GUEST,guest)
        checks+=run(mode,guest,['paths'],[str(guest)]*2,cwd=root)
        relative='./main é🚀.exe'
        checks+=run(mode,relative,['paths'],[cwd+'/'+relative]*2,cwd=root)
        target=root/'other'/'deep';target.mkdir(parents=True);(root/'link').symlink_to(target,target_is_directory=True)
        shutil.copyfile(GUEST,target.parent/'main é🚀.exe')
        alias='link/../main é🚀.exe'
        checks+=run(mode,alias,['paths'],[cwd+'/'+alias]*2,cwd=root)
        long=root/('long'+('a'*120))/('nested'+('b'*120));long.mkdir(parents=True)
        long_guest=long/'main é🚀.exe';shutil.copyfile(GUEST,long_guest)
        assert len(str(long_guest).encode('utf-16-le'))//2>260
        checks+=run(mode,long_guest,['paths'],[str(long_guest)]*2,cwd=root)
        dlls=root/'dlls é🚀';dlls.mkdir()
        first=dlls/'MoDuLe é🚀.dll';second=dlls/'Another é🚀.dll'
        shutil.copyfile(DLL,first);shutil.copyfile(DLL,second)
        relative_root='./dlls é🚀'
        checks+=run(mode,relative,['load'],[cwd+'/'+relative,cwd+'/'+relative_root+'/'+first.name,cwd+'/'+relative_root+'/'+second.name],cwd=root,sysroot=relative_root)
        checks+=run(mode,guest,['load'],[str(guest),str(first),str(second)],cwd=root,sysroot=str(dlls))
        child=subprocess.Popen(command(mode,guest,'mutate',sysroot=str(dlls)),cwd=root,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            assert select.select([child.stdout],[],[],3)[0] and child.stdout.readline()==b'READY\n'
            guest.rename(root/'renamed.exe');first.rename(dlls/'renamed.dll')
            data,error=child.communicate(b'X',timeout=30)
            assert child.returncode==0 and not error,(child.returncode,error)
            checks+=verify(data,[str(guest),str(first)])
        finally:
            if child.poll() is None:child.kill();child.wait()
            for stream in (child.stdin,child.stdout,child.stderr):
                if not stream.closed:stream.close()
    fault=subprocess.run(command(mode,GUEST,'fault'),capture_output=True,timeout=5)
    assert fault.returncode==125 and b'UnmappedMemory' in fault.stderr and not fault.stdout,(mode,fault)
    print(f'Windows modules {mode or ["interpreter"]}: {checks} exact byte/unit capacity cases, Unicode/case/long/symlink paths, unloaded handles, slot reuse, renamed files and checked faults passed',flush=True)
