#!/usr/bin/env python3
"""SDK reparse queries against native readlink bytes, with checked wire buffers."""
import os,pathlib,platform,struct,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
COMMAND=[str(ROOT/'zig-out/bin/universe'),'run']
GUEST=str(ROOT/'artifacts/windows-device.exe')
GET=0x900a8;INVALID=(1<<64)-1;SENTINEL=0xa5a5a5a5;OUTPUT=16392
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
def record(link,root,mounted):
    target=os.readlink(link)
    if any(char in target for char in ('\\',':')):return None,50
    try:target.encode('utf-8')
    except UnicodeEncodeError:return None,1113
    absolute=target.startswith('/')
    if absolute:
        if target!='/' and os.path.normpath(target)!=target.rstrip('/'):return None,50
        if mounted:
            if target==str(root):target='/'
            elif target.startswith(str(root)+'/'):target=target[len(str(root)):]
            else:return None,50
        target='C:'+target
    name=target.replace('/','\\').encode('utf-16le');sub=('\\??\\'.encode('utf-16le') if absolute else b'')+name
    payload=struct.pack('<IHH4HI',0xa000000c,16+len(sub)+len(name),0,0,len(sub),len(sub)+2,len(name),int(not absolute))+sub+b'\0\0'+name+b'\0\0'
    return payload,777
for engine in MODES:
    cases=0
    denied=subprocess.run([*COMMAND,*engine,GUEST,'denied'],capture_output=True,timeout=5)
    assert denied.returncode==0 and denied.stdout==b'windows device: denied\n' and not denied.stderr,denied
    for mounted in ('none','absolute','relative','symlink'):
        with tempfile.TemporaryDirectory(prefix='universe-device-') as directory:
            root=pathlib.Path(directory).resolve();regular=root/'regular.bin';regular.write_bytes(b'unchanged file data')
            (root/'child').mkdir();(root/'root-alias').symlink_to(root,target_is_directory=True)
            targets=['regular.bin','missing é🚀','../parent é🚀','child/../regular.bin',str(regular),str(root),str(root/'absent é🚀'),'/',str(root.parent/'outside'),'host:stream','literal\\name','/directory/../target','a'*1000]
            links=[]
            for index,target in enumerate(targets):
                path=root/f'link-{index} é🚀';path.symlink_to(target);links.append(path)
            invalid=root/'invalid-utf8';os.symlink(b'bad\xff',os.fsencode(invalid));links.append(invalid)
            (root/'file-link').symlink_to('regular.bin')
            options=[] if mounted=='none' else ['--sysroot',{'absolute':str(root),'relative':'.','symlink':'root-alias'}[mounted]]
            requests=[];expected=[]
            def request(op,text='',slot=0,code=GET,capacity=16384,arg=0,value=0,error=777,count=SENTINEL,payload=None,search=False):
                data=text.encode('utf-16le');requests.append(struct.pack('<6I',op,slot,code,capacity,arg,len(data)//2)+data+b'\xa5'*OUTPUT)
                output=b'\xa5'*OUTPUT if payload is None else b'\xa5'*4+payload+b'\xa5'*(OUTPUT-4-len(payload))
                expected.append((value,error,count,output,search))
            for path in links:
                payload,error=record(path,root,mounted!='none')
                request(0,'C:'+path.name,arg=28,value='handle')
                required=len(payload) if payload else 0
                for capacity in sorted({0,1,7,20,max(0,required-1),required,required+1,16384,0xffffffff}):
                    failure=error if error!=777 else 122 if capacity<required else 777
                    request(1,capacity=capacity,value=int(failure==777),error=failure,count=required if failure==777 else 0,payload=payload if failure==777 else None)
                request(1,arg=16|64,value=int(error==777),error=error,count=required if error==777 else 0,payload=payload)
                request(1,arg=32,error=87,count=0)
                request(1,arg=2,error=87)
                if error==777:
                    request(1,arg=1,error=87,count=0)
                    request(1,arg=4,capacity=0,error=122,count=0)
                for code in (0,0x900a4,0x900ac,0x70000,0xffffffff):request(1,code=code,arg=1|64,error=50,count=0)
                request(2,value=1);request(1,arg=8,error=6)
            # Following a link yields an ordinary file; it must never claim a reparse tag.
            for op,text in ((0,'regular.bin'),(0,'child'),(7,'file-link')):
                request(op,text,arg=29,value='handle');request(1,arg=4,error=4390,count=0);request(2,value=1)
            request(3,value='handle',error=0);request(1,arg=8,error=6);request(2,value=1)
            request(4,'regular.bin',value='handle',search=True);request(1,arg=8,error=6);request(9,value=1)
            for foreign in range(4):request(8,arg=foreign,error=6)
            # Saved link records remain valid across guest rename and pending deletion.
            payload,_=record(root/'file-link',root,mounted!='none')
            request(0,'file-link',arg=28,value='handle');request(5,'file-link',value=1)
            request(1,value=1,count=len(payload),payload=payload);request(6,'moved-link',value=1)
            request(1,value=1,count=len(payload),payload=payload);request(2,value=1)
            request(0,'moved-link',arg=28,value=INVALID,error=2)
            result=subprocess.run([*COMMAND,*engine,'--allow-files',*options,'--max-instructions','100000000','--timeout-ms','30000',GUEST,'oracle'],cwd=root,input=b''.join(requests),capture_output=True,timeout=40)
            assert result.returncode==0 and not result.stderr,(engine,mounted,result.returncode,result.stderr)
            offset=0;last_handle=0
            for index,(value,error,count,output,search) in enumerate(expected):
                actual,last_error,returned=struct.unpack_from('<QII',result.stdout,offset);offset+=16
                actual_output=result.stdout[offset:offset+OUTPUT];offset+=OUTPUT
                assert (last_error,returned)==(error,count),(engine,mounted,index,actual,last_error,error,returned,count)
                if value=='handle':assert last_handle<actual<INVALID and actual>=0x10000;last_handle=actual
                else:assert actual==value,(engine,mounted,index,actual,value)
                if search:
                    assert actual_output[:4]==b'\xa5'*4 and actual_output[596:]==b'\xa5'*(OUTPUT-596)
                else:assert actual_output==output,(engine,mounted,index,'record/guard mismatch')
            assert offset==len(result.stdout) and regular.read_bytes()==b'unchanged file data'
            assert all(os.readlink(path)==target for path,target in zip(links[:-1],targets,strict=True))
            assert not (root/'moved-link').is_symlink();cases+=len(expected)
            (root/'file-link').symlink_to('regular.bin')
            for mode in ('output-fault','count-fault'):
                fault=subprocess.run([*COMMAND,*engine,'--allow-files',*options,GUEST,mode],cwd=root,capture_output=True,timeout=5)
                assert fault.returncode==125 and b'UnmappedMemory' in fault.stderr and not fault.stdout,fault
    print(f'Windows device {engine or ["interpreter"]}: {cases} exact SDK replies, native Unicode readlink records, DOS/sysroot targets, checked capacities, typed handles, rename/deletion and faults passed',flush=True)
