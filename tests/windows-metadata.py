#!/usr/bin/env python3
"""Real SDK directory handles, compared with native identity and sharing."""
import os,pathlib,platform,struct,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
COMMAND=[str(ROOT/'zig-out/bin/universe'),'run']
GUEST=str(ROOT/'artifacts/windows-find.exe')
INVALID=(1<<64)-1
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
for engine in MODES:
    cases=0
    for mounted in (False,True):
        with tempfile.TemporaryDirectory(prefix='universe-metadata-') as directory:
            root=pathlib.Path(directory).resolve();child=root/'directory é🚀';child.mkdir()
            regular=root/'regular.bin';regular.write_bytes(b'unchanged data')
            (root/'directory-link').symlink_to(child,target_is_directory=True)
            options=['--sysroot',str(root)] if mounted else []
            requests=[];expected=[]
            def request(op,text='',slot=0,arg=0,result=0,error=777,info=None):
                data=text.encode('utf-16le');requests.append(struct.pack('<4I',op,slot,arg,len(data)//2)+data)
                expected.append((result,error,info,600 if op<11 else 608))
            for op,text in ((26,'directory é🚀'),(27,'directory é🚀'),(26,'directory-link'),(27,'C:'+('/directory é🚀' if mounted else str(child)).replace('/',chr(92)))):
                request(op,text,result='handle',arg=1)
                request(28,result=1,info=child.stat())
                request(21,arg=1,result=INVALID,error=5);request(22,result=INVALID,error=5)
                request(20,arg=4097,error=5);request(29,error=5)
                request(2,error=6);request(3,result=1);request(28,error=6)
            # A metadata-only open still participates in native-identity sharing.
            request(26,'directory é🚀',arg=3,result='handle')
            request(27,'directory-link',slot=1,result=INVALID,error=32)
            request(7,'directory é🚀',error=32);request(3,result=1)
            request(7,'directory é🚀',result=1)
            # The hint is harmless for regular data files; metadata access=0 stays limited.
            request(27,'regular.bin',result='handle');request(21,arg=20,result=14,info=b'unchanged data');request(3,result=1)
            request(26,'regular.bin',result='handle');request(21,arg=1,result=INVALID,error=5);request(3,result=1)
            result=subprocess.run([*COMMAND,*engine,'--allow-files',*options,GUEST,'oracle'],cwd=root,input=b''.join(requests),capture_output=True,timeout=10)
            assert result.returncode==0 and not result.stderr,(engine,mounted,result.returncode,result.stderr)
            offset=0;last_handle=0
            for index,(value,error,info,length) in enumerate(expected):
                actual,last_error,size=struct.unpack_from('<QII',result.stdout,offset);offset+=16
                output=result.stdout[offset:offset+size];offset+=size
                assert (last_error,size)==(error,length),(engine,mounted,index,last_error,error,size,length)
                if value=='handle':assert last_handle<actual<INVALID and actual>=0x10000;last_handle=actual
                else:assert actual==value,(engine,mounted,index,actual,value)
                assert output[:4]==output[-4:]==b'\xa5'*4
                if isinstance(info,bytes):assert output[4:4+len(info)]==info and output[4+len(info):]==b'\xa5'*(604-len(info))
                elif info is not None:
                    assert struct.unpack_from('<I',output,4)[0]==0x10
                    dev,high,low,links,ino_high,ino_low=struct.unpack_from('<6I',output,32)
                    assert (dev,high<<32|low,links,ino_high<<32|ino_low)==((info.st_dev^(info.st_dev>>32))&0xffffffff,info.st_size,info.st_nlink,info.st_ino)
                    assert output[56:]==b'\xa5'*552
                else:assert output==b'\xa5'*length
            assert offset==len(result.stdout) and regular.read_bytes()==b'unchanged data'
            assert (root/'renamed-directory').is_dir();cases+=len(expected)
    print(f'Windows metadata {engine or ["interpreter"]}: {cases} SDK replies, real directory identities, A/W DOS paths, data denial and sharing passed',flush=True)
