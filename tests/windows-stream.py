#!/usr/bin/env python3
"""Exact SDK stream records compared with independently created POSIX file data."""
import os,pathlib,platform,struct,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
COMMAND=[str(ROOT/'zig-out/bin/universe')];GUEST=str(ROOT/'artifacts/windows-find.exe')
INVALID=(1<<64)-1
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
def stream_bytes(size):return b'\xa5'*4+struct.pack('<Q',size)+'::$DATA\0'.encode('utf-16le')+b'\0'*576+b'\xa5'*4

for engine in MODES:
    cases=0
    for rooted in ('none','absolute','relative','symlink'):
        with tempfile.TemporaryDirectory(prefix='universe-stream-') as directory:
            root=pathlib.Path(directory).resolve();child=root/'child é🚀';child.mkdir()
            sizes=[*range(33),255,4096,65535,(1<<32)-1,1<<32,(1<<32)+17]
            contents={};paths=[]
            for size in sizes:
                path=root/f'data-{size}.bin'
                if size<65536:
                    data=bytes((index*17)&255 for index in range(size));path.write_bytes(data);contents[path]=data
                else:
                    with path.open('wb') as file:file.truncate(size)
                paths.append(path)
            regular=root/'regular.bin';regular.write_bytes(b'real default data stream\n');contents[regular]=regular.read_bytes();paths.append(regular)
            unicode_file=child/'é🚀.bin';unicode_file.write_bytes(b'Unicode path bytes');contents[unicode_file]=unicode_file.read_bytes();paths.append(unicode_file)
            readonly=root/'readonly';readonly.write_bytes(b'readonly');readonly.chmod(0o444);contents[readonly]=b'readonly';paths.append(readonly)
            (root/'file-link').symlink_to(regular);paths.append(root/'file-link')
            (root/'directory-link').symlink_to(child,target_is_directory=True)
            (root/'broken-link').symlink_to('absent');os.mkfifo(root/'fifo')
            os.link(regular,root/'hard-link');paths.append(root/'hard-link')
            (root/'root-alias').symlink_to(root,target_is_directory=True)
            options=[] if rooted=='none' else ['--sysroot',{'absolute':str(root),'relative':'.','symlink':'root-alias'}[rooted]]
            requests=[];expected=[]
            def request(op,text='',slot=0,arg=0,result=0,error=777,output=None):
                data=text.encode('utf-16le','surrogatepass');length=608 if op>=11 else 600
                requests.append(struct.pack('<4I',op,slot,arg,len(data)//2)+data)
                expected.append((result,error,length,b'\xa5'*length if output is None else output))
            def execute():
                result=subprocess.run([*COMMAND,*engine,'--allow-files',*options,'--max-instructions','100000000','--timeout-ms','30000',GUEST,'oracle'],cwd=root,input=b''.join(requests),capture_output=True,timeout=40)
                assert result.returncode==0 and not result.stderr,(engine,rooted,result.returncode,result.stderr)
                offset=0;last_handle=0
                for index,(value,error,length,output) in enumerate(expected):
                    actual,last_error,amount=struct.unpack_from('<QII',result.stdout,offset);offset+=16
                    actual_bytes=result.stdout[offset:offset+amount];offset+=amount
                    assert (last_error,amount)==(error,length),(engine,rooted,index,actual,last_error,error,amount,length)
                    if value=='handle':assert last_handle<actual<INVALID and actual>=0x10000;last_handle=actual
                    else:assert actual==value,(engine,rooted,index,actual,value)
                    if output=='file':
                        assert actual_bytes[:4]==actual_bytes[-4:]==b'\xa5'*4
                        assert actual_bytes[48:72]=='regular.bin\0'.encode('utf-16le')
                    else:assert actual_bytes==output,(engine,rooted,index,'record/guard mismatch')
                assert offset==len(result.stdout)
                return len(expected)
            for path in paths:
                text=str(path.relative_to(root)).replace('/','\\')
                request(11,text,result='handle',output=stream_bytes(path.stat().st_size))
                request(12,error=38);request(12,arg=1,error=38) # An exhausted search must not dereference address 1.
                request(1,error=6);request(3,error=6) # Wrong-kind NextFile and CloseHandle preserve the search.
                request(2,result=1);request(12,error=6);request(2,error=6)
            absolute=str(unicode_file) if rooted=='none' else '/child é🚀/é🚀.bin'
            request(11,absolute,result='handle',output=stream_bytes(unicode_file.stat().st_size));request(12,arg=2,error=87);request(12,error=38);request(2,result=1)
            for text,error in (('.',38),('child é🚀',38),('directory-link',38),('broken-link',2),('fifo',50),('missing',2),('missing/child',2),('',3),('D:\\regular.bin',15),('\\\\server\\share',50),('regular.bin:named',50),('regular.bin::$INDEX_ALLOCATION',50),('::$DATA',3),('*',123),('child?/*',123),('bad|name',123),('bad\x01name',123),('\ud800',1113),('x'*32767,206)):
                request(11,text,result=INVALID,error=error)
            for argument in (1,2,0xffff,1<<16,0xffff0000,0xffffffff):request(11,'regular.bin',arg=argument,result=INVALID,error=87)
            request(13,'regular.bin',result=INVALID,error=87);request(14,result=INVALID,error=87)
            for foreign in range(4):request(15,arg=foreign,error=6)
            # Genuine file and event handles must remain owned by CloseHandle.
            request(16,'regular.bin',slot=1,result='handle');request(12,slot=1,error=6);request(2,slot=1,error=6);request(3,slot=1,result=1)
            request(17,slot=1,result='handle',error=0);request(12,slot=1,error=6);request(2,slot=1,error=6);request(3,slot=1,result=1)
            request(0,'regular.bin',slot=1,result='handle',output='file');request(12,slot=1,error=6);request(1,slot=1,error=18);request(2,slot=1,result=1)
            # Names returned by enumeration must round-trip into A/W data-file access.
            for path in (regular,unicode_file):
                relative=str(path.relative_to(root));body=contents[path]
                absolute='C:'+('/'+relative if rooted!='none' else str(path)).replace('/',chr(92))
                for text in (relative,'c:'+relative.replace('/',chr(92)),absolute):
                    for suffix in ('::$DATA','::$dAtA'):
                        request(11,text+suffix,result='handle',output=stream_bytes(len(body)));request(2,result=1)
                        for op in (16,23):
                            request(op,text+suffix,slot=1,result='handle')
                            request(21,slot=1,arg=len(body)+3,result=len(body),output=b'\xa5'*4+body+b'\xa5'*(604-len(body)))
                            request(3,slot=1,result=1)
            request(25,'regular.bin',slot=1,result='handle');request(16,'c:regular.bin::$DATA',slot=2,result=INVALID,error=32);request(3,slot=1,result=1)
            request(16,'regular.bin:named',slot=1,result=INVALID,error=50)
            for text in ('C:regular.bin\\','regular.bin/'):
                request(11,text,result=INVALID,error=3)
                request(16,text,slot=1,result=INVALID,error=3)
            request(11,'\\/server/share/file',result=INVALID,error=50)
            cases+=execute()
            assert all(path.read_bytes()==data for path,data in contents.items())
            assert all(path.stat().st_size==size for path,size in zip(paths[:len(sizes)],sizes,strict=True))
            requests=[];expected=[]
            new_file=root/'new stream é🚀.bin'
            request(24,'C:new stream é🚀.bin::$DATA',slot=1,result='handle');request(22,slot=1,result=18);request(3,slot=1,result=1)
            request(11,'new stream é🚀.bin',result='handle',output=stream_bytes(18));request(2,result=1)
            request(16,'new stream é🚀.bin::$dAtA',slot=1,result='handle');request(22,slot=1,result=18);request(3,slot=1,result=1)
            # Query again after guest resizing; existing snapshots remain independent of file handles.
            mutable=root/'mutable.bin';mutable.write_bytes(b'original bytes')
            request(11,'mutable.bin',result='handle',output=stream_bytes(14));request(16,'mutable.bin',slot=1,result='handle')
            request(20,slot=1,arg=4097,result=1);request(11,'mutable.bin',slot=2,result='handle',output=stream_bytes(4097))
            request(12,error=38);request(2,result=1);request(2,slot=2,result=1);request(3,slot=1,result=1)
            # Pending-delete identities cannot acquire a fresh stream search.
            doomed=root/'doomed.bin';doomed.write_bytes(b'pending deletion')
            request(16,'doomed.bin',slot=1,result='handle');request(11,'doomed.bin',result='handle',output=stream_bytes(16))
            request(18,'doomed.bin',result=1);request(11,'doomed.bin',slot=2,result=INVALID,error=5)
            request(12,error=38);request(2,result=1);request(3,slot=1,result=1);request(11,'doomed.bin',result=INVALID,error=2)
            request(11,'regular.bin',result='handle',output=stream_bytes(regular.stat().st_size));request(6,'child é🚀',result=1)
            request(19,'../regular.bin' if rooted=='none' else '/regular.bin',result=1);request(12,error=38);request(2,result=1)
            request(11,'moved-stream.bin',result='handle',output=stream_bytes(regular.stat().st_size));request(12,error=38);request(2,result=1)
            cases+=execute();assert not doomed.exists() and not regular.exists()
            assert new_file.read_bytes()==b'guest stream write' and not list(root.glob('*::*'))
            assert (child/'moved-stream.bin').read_bytes()==contents[regular]
            assert mutable.stat().st_size==4097 and mutable.read_bytes()==b'original bytes'+b'\0'*(4097-14)
            # Fresh input keeps output faults independent of the preceding rename.
            regular.write_bytes(contents[regular])
            for mode in ('stream-fault','stream-source-fault'):
                fault=subprocess.run([*COMMAND,*engine,'--allow-files',*options,GUEST,mode],cwd=root,input=b'',capture_output=True,timeout=5)
                assert fault.returncode==125 and b'UnmappedMemory' in fault.stderr and not fault.stdout,fault
            limit=subprocess.run([*COMMAND,*engine,'--allow-files',*options,'--max-instructions','100000000',GUEST,'stream-limit'],cwd=root,capture_output=True,timeout=20)
            assert limit.returncode==0 and limit.stdout==b'windows stream limit: 1024 shared searches and checked kinds ok\n' and not limit.stderr,limit
    # Host-only prefix spelling must not be validated as part of the guest path.
    with tempfile.TemporaryDirectory(prefix='universe-stream-root-') as directory:
        root=pathlib.Path(directory)/'host ?*';root.mkdir();(root/'regular.bin').write_bytes(b'physical prefix')
        data='/regular.bin'.encode('utf-16le');request_bytes=struct.pack('<4I',11,0,0,len(data)//2)+data
        answer=subprocess.run([*COMMAND,*engine,'--allow-files','--sysroot',str(root),GUEST,'oracle'],input=request_bytes,capture_output=True,timeout=5)
        assert answer.returncode==0 and answer.stdout==struct.pack('<QII',0x10000,777,608)+stream_bytes(15) and not answer.stderr,(answer.returncode,answer.stdout[:16],answer.stderr)
        cases+=1
    print(f'Windows streams {engine or ["interpreter"]}: {cases} exact SDK replies, real zero/small/>4 GiB sizes, Unicode A/W default-stream reads/writes and sharing, sysroots/symlinks, resizing, pending deletion, cwd/rename, typed lifetimes, 1024-search limit and checked failures passed',flush=True)
