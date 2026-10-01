#!/usr/bin/env python3
"""SDK directory calls compared with physical host paths and exact UTF-16 bytes."""
import os,pathlib,platform,struct,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
COMMAND=[str(ROOT/'zig-out/bin/universe')]
GUEST=str(ROOT/'artifacts/windows-directory.exe')
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
for engine in MODES:
    cases=0
    for rooted in ('none','absolute','relative','symlink'):
        with tempfile.TemporaryDirectory(prefix='universe-directory-') as directory:
            root=pathlib.Path(directory).resolve();child=root/'child é🚀';child.mkdir();grand=child/'nested';grand.mkdir()
            deep=child
            for i in range(4):deep=deep/(str(i)+'x'*78);deep.mkdir()
            assert len(str(deep).encode('utf-16le'))//2>260
            (root/'shortcut').symlink_to(grand,target_is_directory=True)
            (root/'root-alias').symlink_to(root,target_is_directory=True)
            (root/'regular').write_bytes(b'not a directory')
            options=[] if rooted=='none' else ['--sysroot',{'absolute':str(root),'relative':'.','symlink':'root-alias'}[rooted]]
            denied=subprocess.run([*COMMAND,*engine,*options,GUEST],cwd=root,capture_output=True,timeout=5)
            assert denied.returncode==0 and denied.stdout==b'windows directories: denied\n' and not denied.stderr,denied
            requests=[];expected=[];current=root;created=[]
            def request(op,text='',capacity=0,value=1,error=777,output=b''):
                data=text.encode('utf-16le','surrogatepass')
                requests.append(struct.pack('<3I',op,len(data)//2,capacity)+data)
                expected.append((value,error,output))
            def guest_path(path):return str(path) if rooted=='none' else '/'+str(path.relative_to(root)) if path!=root else '/'
            def query():
                text=guest_path(current);data=text.encode('utf-16le');length=len(data)//2
                for capacity in range(length+3):
                    guard=b'\x5a\xa5'*(capacity+2)
                    output=(data+b'\0\0'+guard[(length+1)*2:]) if capacity>length else guard
                    request(0,capacity=capacity,value=length if capacity>length else length+1,output=output)
                request(6,capacity=0,value=length+1) # A size query must not dereference its output.
            def change(text):
                host_text=text.replace('\\','/')
                path=root/host_text.lstrip('/') if rooted!='none' and host_text.startswith('/') else pathlib.Path(host_text) if host_text.startswith('/') else current/host_text
                request(1,text);return pathlib.Path(os.path.realpath(path))
            query()
            for name in ('child é🚀','nested','..',guest_path(deep),guest_path(root),'shortcut/..',guest_path(root)):
                current=change(name);query()
                filename=f'created-{len(created)}.bin';created.append(current/filename);request(2,filename)
                # A queried absolute path must be reusable through the same sysroot.
                current=change(guest_path(current));query()
                request(3,'.',value=0,error=32);request(4,'.',value=0,error=32)
            for op,text,error in ((1,'missing',3),(1,'regular',267),(1,'',3),(1,'C:\\',50),(1,'\\\\server\\share',50),(1,'\ud800',1113),(5,'',87)):
                request(op,text,value=0,error=error);query()
            current=change('child é🚀\\nested');query()
            result=subprocess.run([*COMMAND,*engine,'--allow-files',*options,'--max-instructions','100000000','--timeout-ms','30000',GUEST,'oracle'],cwd=root,input=b''.join(requests),capture_output=True,timeout=40)
            assert result.returncode==0 and not result.stderr,(engine,rooted,result)
            offset=0
            for index,(value,error,output) in enumerate(expected):
                assert offset+16<=len(result.stdout),(engine,rooted,index,'missing reply')
                actual,actual_error,units,reserved=struct.unpack_from('<4I',result.stdout,offset);offset+=16
                actual_output=result.stdout[offset:offset+units*2];offset+=units*2
                assert (actual,actual_error,reserved,actual_output)==(value,error,0,output),(engine,rooted,index,(actual,actual_error,actual_output),(value,error,output))
            assert offset==len(result.stdout)
            assert all(path.read_bytes()==b'directory bytes' for path in created)
            assert not (root/'moved-current').exists() and child.is_dir() and grand.is_dir()
            for mode in ('fault','source-fault'):
                fault=subprocess.run([*COMMAND,*engine,'--allow-files',GUEST,mode],cwd=root,capture_output=True,timeout=5)
                assert fault.returncode==125 and b'UnmappedMemory' in fault.stderr and not fault.stdout,fault
            cases+=len(expected)
    print(f'Windows directories {engine or ["interpreter"]}: {cases} exact capacity/state cases, physical Unicode/symlink paths, sysroot round trips, real relative files, current-directory locks and checked faults passed',flush=True)
