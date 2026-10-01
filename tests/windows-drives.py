#!/usr/bin/env python3
"""SDK drive enumeration: exact MULTI_SZ buffers and native filesystem round trips."""
import os,pathlib,platform,struct,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
COMMAND=[str(ROOT/'zig-out/bin/universe')];GUEST=str(ROOT/'artifacts/windows-directory.exe')
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
for engine in MODES:
    cases=0
    for rooted in ('none','absolute','relative','symlink'):
        with tempfile.TemporaryDirectory(prefix='universe-drives-') as directory:
            root=pathlib.Path(directory).resolve();(root/'root-alias').symlink_to(root,target_is_directory=True)
            options=[] if rooted=='none' else ['--sysroot',{'absolute':str(root),'relative':'.','symlink':'root-alias'}[rooted]]
            requests=[];expected=[]
            def request(op,capacity=0,value=0,error=777,output=b'',text=''):
                data=text.encode('utf-16le');requests.append(struct.pack('<3I',op,len(data)//2,capacity)+data);expected.append((value,error,output))
            for op,wide in ((10,True),(11,False)):
                data=('C:\\\0\0'.encode('utf-16le') if wide else b'C:\\\0\0')
                for capacity in (*range(10),32768):
                    guard=b'\x5a\xa5'*(capacity+2)
                    request(op,capacity,5 if capacity<5 else 4,output=guard if capacity<5 else data+guard[len(data):])
            request(12,value=4)
            for op in (13,14):
                for capacity in range(5):request(op,capacity,value=5)
            for op in (15,16):
                for capacity in (0,1,4,5,32768):request(op,capacity,value=5 if capacity<5 else 0,error=777 if capacity<5 else 87)
            request(19,value=0x10)
            guard=b'\x5a\xa5'*66
            request(18,64,value=1,output='disk')
            request(17,64,value=3,output='C:\\\0'.encode('utf-16le')+guard[8:])
            # CreateFileW accepts a C-drive name after changing to the enumerated root.
            filename=root/'drive-created é🚀.bin'
            path='C:'+('/drive-created é🚀.bin' if rooted!='none' else str(filename)).replace('/',chr(92))
            request(2,text=path,value=1)
            physical=root if rooted!='none' else pathlib.Path('/')
            before=os.statvfs(physical)
            result=subprocess.run([*COMMAND,*engine,'--allow-files',*options,'--max-instructions','100000000','--timeout-ms','30000',GUEST,'oracle'],cwd=root,input=b''.join(requests),capture_output=True,timeout=40)
            after=os.statvfs(physical)
            assert result.returncode==0 and not result.stderr,(engine,rooted,result)
            offset=0
            for index,(value,error,output) in enumerate(expected):
                actual,last_error,units,reserved=struct.unpack_from('<4I',result.stdout,offset);offset+=16
                data=result.stdout[offset:offset+units*2];offset+=units*2
                assert (actual,last_error,reserved)==(value,error,0),(engine,rooted,index,actual,last_error,value,error)
                if output=='disk':
                    assert data[:4]==guard[:4] and data[28:]==guard[28:]
                    available,total,free=struct.unpack_from('<3Q',data,4)
                    assert total==before.f_blocks*before.f_frsize==after.f_blocks*after.f_frsize
                    for amount,field in ((available,'f_bavail'),(free,'f_bfree')):
                        low=min(getattr(before,field),getattr(after,field))*before.f_frsize
                        high=max(getattr(before,field),getattr(after,field))*before.f_frsize
                        assert max(0,low-1024*1024)<=amount<=high+1024*1024,(engine,rooted,field,amount,low,high)
                    assert 0<=available<=free<=total
                else:assert data==output,(engine,rooted,index,data[:20],output[:20])
            assert offset==len(result.stdout) and filename.read_bytes()==b'directory bytes'
            assert not (root/'C:').exists();cases+=len(expected)
            denied=subprocess.run([*COMMAND,*engine,*options,GUEST],cwd=root,capture_output=True,timeout=5)
            assert denied.returncode==0 and denied.stdout==b'windows directories: denied\n' and not denied.stderr,denied
            for mode in ('drive-fault','drive-ansi-fault'):
                fault=subprocess.run([*COMMAND,*engine,'--allow-files',*options,GUEST,mode],cwd=root,capture_output=True,timeout=5)
                assert fault.returncode==125 and b'UnmappedMemory' in fault.stderr and not fault.stdout,fault
    # A missing guest mount cannot be enumerated as an available drive.
    with tempfile.TemporaryDirectory(prefix='universe-missing-drive-') as directory:
        missing=str(pathlib.Path(directory)/'missing')
        result=subprocess.run([*COMMAND,*engine,'--allow-files','--sysroot',missing,GUEST,'oracle'],input=struct.pack('<3I',12,0,0),capture_output=True,timeout=5)
        assert result.returncode==0 and result.stdout==struct.pack('<4I',0,3,0,0) and not result.stderr,result
        cases+=1
    print(f'Windows drives {engine or ["interpreter"]}: {cases} exact A/W MULTI_SZ/capacity replies, four mounts, native disk totals, queried-root cwd/attributes/file creation, denied grants and checked faults passed',flush=True)
