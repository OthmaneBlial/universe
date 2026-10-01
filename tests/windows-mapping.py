#!/usr/bin/env python3
"""SDK guests against native sparse-file bytes, hardlinks and fault cleanup."""
import os,pathlib,platform,select,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
COMMAND=[str(ROOT/'zig-out/bin/universe')]
GUEST=str(ROOT/'artifacts/windows-mapping.exe')
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
SIZE=(1<<32)+65537
def byte(path,offset):
    with path.open('rb') as stream:stream.seek(offset);return stream.read(1)
def seed(path):
    with path.open('wb') as stream:stream.write(bytes([0xa1])+bytes(15)+bytes([0xa2]))
for mode in MODES:
    result=subprocess.run([*COMMAND,*mode,GUEST],capture_output=True,timeout=10)
    assert result.returncode==0 and result.stdout==b'windows mapping: shared sections, guest-page COW, names and view lifetimes ok\n' and not result.stderr,(mode,result)
    denied=subprocess.run([*COMMAND,*mode,GUEST,'file'],capture_output=True,timeout=5)
    assert denied.returncode==0 and denied.stdout==b'windows mapping: denied\n' and not denied.stderr,denied
    fault=subprocess.run([*COMMAND,*mode,GUEST,'ro-fault'],capture_output=True,timeout=5)
    assert fault.returncode==125 and b'PermissionDenied' in fault.stderr and not fault.stdout,fault
    with tempfile.TemporaryDirectory(prefix='universe-mapping-') as directory:
        path=pathlib.Path(directory)/'mapping.bin';seed(path)
        child=subprocess.Popen([*COMMAND,*mode,'--allow-files',GUEST,'file'],cwd=directory,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            assert select.select([child.stdout],[],[],5)[0],'Missing flushed-byte handshake'
            assert child.stdout.readline()==b'FLUSH\n',(child.poll(),child.stderr.read())
            assert path.stat().st_size==SIZE and path.stat().st_blocks*512<1024*1024,'The >4 GiB file must remain sparse'
            assert byte(path,0)==b'\xb1' and byte(path,16)==b'\xa2' and byte(path,1<<32)==b'\xf4'
            # Only the requested first dirty high page is flushed; other pages remain pending.
            assert byte(path,(1<<32)+4097)==b'\0' and byte(path,(1<<32)+65536)==b'\0'
            link=pathlib.Path(directory)/'mapping-link.bin'
            assert path.stat().st_ino==link.stat().st_ino and path.stat().st_nlink==2
            child.stdin.write(b'Z');child.stdin.flush()
            output,error=child.communicate(timeout=5)
            assert child.returncode==0 and output==b'windows mapping: coherent file aliases, sparse offsets, flush and deletion lifetimes ok\n' and not error,(child.returncode,output,error)
            assert not path.exists() and link.stat().st_size==SIZE
            assert byte(link,0)==b'\xb1' and byte(link,(1<<32)+4097)==b'\xf3' and byte(link,(1<<32)+65536)==b'\xf2'
            assert byte(link,1<<32)==b'\xf4','Private COW bytes must never reach the file'
        finally:
            if child.poll() is None:child.kill();child.wait()
            for stream in (child.stdin,child.stdout,child.stderr):
                if stream and not stream.closed:stream.close()
    with tempfile.TemporaryDirectory(prefix='universe-mapping-fault-') as directory:
        path=pathlib.Path(directory)/'mapping.bin';seed(path)
        fault=subprocess.run([*COMMAND,*mode,'--allow-files',GUEST,'file-fault'],cwd=directory,capture_output=True,timeout=5)
        assert fault.returncode==125 and b'UnmappedMemory' in fault.stderr and b'writeback failed' not in fault.stderr and not fault.stdout,fault
        assert path.stat().st_size==SIZE and byte(path,0)==b'\xb1' and byte(path,1<<32)==b'\xf1' and byte(path,(1<<32)+65536)==b'\xf2','Handled guest faults must flush shared changes'
    print(f'Windows mappings {mode or ["interpreter"]}: shared aliases, 4 KiB COW, >4 GiB sparse offsets, exact flushed bytes, names and independent handle/view lifetimes passed',flush=True)
