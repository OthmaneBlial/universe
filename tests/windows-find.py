#!/usr/bin/env python3
"""SDK enumeration checked against lstat and an independent recursive DOS oracle."""
import decimal,errno,functools,itertools,os,pathlib,platform,stat,struct,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
COMMAND=[str(ROOT/'zig-out/bin/universe')];GUEST=str(ROOT/'artifacts/windows-find.exe')
INVALID=(1<<64)-1;EPOCH=116444736000000000;GUARD=b'\xa5'*600
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])

def units(text):return struct.unpack('<'+'H'*(len(text.encode('utf-16le'))//2),text.encode('utf-16le'))
def matches(pattern,name):
    if pattern=='*.*':return bool(name)
    tokens=[]
    for index,c in enumerate(pattern):
        if c=='.' and index==len(pattern)-1 and index and pattern[index-1]=='*':tokens[-1]='<'
        elif c=='.' and index+1<len(pattern) and pattern[index+1] in '?*':tokens.append('"')
        else:tokens.append('>' if c=='?' else c)
    expression=units(''.join(tokens));filename=units(name)
    def upper(unit):
        value=chr(unit).upper();return ord(value) if len(value)==1 else unit
    @functools.lru_cache(None)
    def visit(i,j):
        if i==len(expression):return j==len(filename)
        token=chr(expression[i])
        if token in '*<':
            end=len(filename)
            if token=='<' and 46 in filename[j:]:end=max(k for k in range(j,end) if filename[k]==46)
            return any(visit(i+1,k) for k in range(j,end+1))
        if token=='>' and (j==len(filename) or filename[j]==46):
            while i<len(expression) and expression[i]==62:i+=1
            return visit(i,j)
        if token=='"':return visit(i+1,j) if j==len(filename) else filename[j]==46 and visit(i+1,j+1)
        return j<len(filename) and (token=='>' or upper(expression[i])==upper(filename[j])) and visit(i+1,j+1)
    return bool(filename) and visit(0,0)

def record(output,infos):
    assert len(output)==600 and output[:4]==output[-4:]==b'\xa5'*4
    data=output[4:-4];raw=data[44:564];end=next(i for i in range(0,len(raw),2) if raw[i:i+2]==b'\0\0')
    name=raw[:end].decode('utf-16le');before,after=infos[name]
    attributes,created,access,written,high,low,tag,reserved=struct.unpack_from('<IQQQIIII',data)
    expected=0x10 if stat.S_ISDIR(after.st_mode) else 0x400 if stat.S_ISLNK(after.st_mode) else 1 if after.st_mode&0o222==0 else 0x80
    size=0 if stat.S_ISDIR(after.st_mode) else after.st_size
    assert (attributes,(high<<32)|low,tag,reserved)==(expected,size,0xa000000c if stat.S_ISLNK(after.st_mode) else 0,0),(name,attributes,size,tag)
    for actual,field in ((access,'st_atime_ns'),(written,'st_mtime_ns')):
        bounds=[getattr(item,field)//100+EPOCH for item in (before,after)]
        assert min(bounds)<=actual<=max(bounds),(name,field,actual,bounds)
    if hasattr(after,'st_birthtime_ns'):assert created==after.st_birthtime_ns//100+EPOCH
    elif hasattr(after,'st_birthtime'):
        # Python macOS exposes birth time as a float: allow only its 300 ns conversion bound.
        ticks=int(decimal.Decimal.from_float(after.st_birthtime)*10000000)+EPOCH
        assert abs(created-ticks)<=3,(name,created,ticks)
    assert not any(raw[end:]) and not any(data[564:]),(name,'filename padding or short alias')
    return name

for engine in MODES:
    cases=0
    for rooted in ('none','absolute','relative','symlink'):
        with tempfile.TemporaryDirectory(prefix='universe-find-') as directory:
            parent=pathlib.Path(directory).resolve();root=parent/'scan';root.mkdir()
            names={''.join(value) for size in range(1,4) for value in itertools.product('ab.',repeat=size)}-{'.','..'}
            names.update(('extensionless','a.txt','ab.txt','abc.txt','file','file.txt','file.a.b','file.','éa.TXT','ÉB.txt','σ.txt','ς.txt','🚀.txt','.hidden','x'*255))
            for name in names:(root/name).write_bytes(name.encode())
            (root/'readonly').write_bytes(b'readonly bytes');(root/'readonly').chmod(0o444)
            with (root/'large.bin').open('wb') as file:file.truncate((1<<32)+17)
            sub=root/'sub';sub.mkdir();(sub/'one.bin').write_bytes(b'one');(sub/'two.bin').write_bytes(b'two')
            child=root/'child é🚀';child.mkdir();(child/'nested').mkdir()
            (root/'shortcut').symlink_to(child/'nested',target_is_directory=True)
            (root/'directory-link').symlink_to(sub,target_is_directory=True)
            (root/'file-link').symlink_to(root/'a.txt');(root/'broken-link').symlink_to('absent')
            (root/'root-alias').symlink_to(root,target_is_directory=True)
            options=[] if rooted=='none' else ['--sysroot',{'absolute':str(root),'relative':'.','symlink':'root-alias'}[rooted]]
            def execute(requests):
                result=subprocess.run([*COMMAND,*engine,'--allow-files',*options,'--max-instructions','500000000','--timeout-ms','30000',GUEST,'oracle'],cwd=root,input=b''.join(requests),capture_output=True,timeout=40)
                assert result.returncode==0 and not result.stderr,(engine,rooted,result.returncode,result.stderr)
                return result.stdout
            def check(output,expected,infos,groups):
                assert len(output)==len(expected)*616,(len(output),len(expected))
                found=[set() for _ in groups];handles=set()
                for index,(value,error,group) in enumerate(expected):
                    actual,last_error,length=struct.unpack_from('<QII',output,index*616);data=output[index*616+16:(index+1)*616]
                    assert (last_error,length)==(error,600),(engine,rooted,index,actual,last_error,error)
                    if value=='handle':assert actual>=0x10000 and actual!=INVALID and actual not in handles;handles.add(actual)
                    else:assert actual==value,(engine,rooted,index,actual,value)
                    if group is None:assert data==GUARD,(engine,rooted,index,'failure modified output')
                    else:
                        name=record(data,infos[group]);assert name not in found[group],(group,name,'duplicate');found[group].add(name)
                assert found==groups,(engine,rooted,[(got,want) for got,want in zip(found,groups) if got!=want])
                return len(expected)
            denied=subprocess.run([*COMMAND,*engine,*options,GUEST],cwd=root,capture_output=True,timeout=5)
            assert denied.returncode==0 and denied.stdout==b'windows enumeration: denied\n' and not denied.stderr,denied
            requests=[];expected=[];groups=[];snapshots={}
            def request(op,text='',slot=0,arg=0,result=0,error=777,group=None):
                data=text.encode('utf-16le','surrogatepass');requests.append(struct.pack('<4I',op,slot,arg,len(data)//2)+data);expected.append((result,error,group))
            def search(text,leaf,base=root):
                entries={name:base/name for name in ('.','..',*os.listdir(base))};wanted={name for name in entries if matches(leaf,name)}
                group=len(groups);groups.append(wanted);snapshots[group]={name:(path.lstat(),path) for name,path in entries.items()}
                request(0,text,result='handle' if wanted else INVALID,error=777 if wanted else 2,group=group if wanted else None)
                if wanted:
                    request(3,error=6);request(10,error=87) # Both failures must leave the cursor alone.
                    for _ in range(len(wanted)-1):request(1,result=1,group=group)
                    request(1,error=18);request(1,error=18);request(2,result=1);request(1,error=6);request(2,error=6)
            patterns=[''.join(value) for size in range(1,4) for value in itertools.product('a.?*',repeat=size)]
            patterns+=['*.*','a??.txt','file.*','file.','é?.txt','σ.txt','??.txt','?.txt','*.bin','x'*255,'does-not-exist','READONLY','BROKEN-LINK']
            for pattern in patterns:search(pattern,pattern)
            search('sub\\*.bin','*.bin',sub);search('directory-link/*','*',sub);search('shortcut/../*','*',child)
            search(str(root/'a.txt') if rooted=='none' else '/a.txt','a.txt')
            for text,error in (('',3),('sub/',123),('sub\\',123),('a*/../*',123),('sub?/a',123),('bad|name',123),('bad<name',123),('bad"name',123),('bad\x01name',123),('missing/*',3),('a.txt/*',3),('D:\\*',15),('\\\\server\\*',50),('\ud800',1113)):
                request(0,text,result=INVALID,error=error)
            request(8,result=INVALID,error=87);request(9,'*',result=INVALID,error=87)
            for foreign in range(3):request(4,arg=foreign,error=6);request(5,arg=foreign,error=6)
            output=execute(requests)
            infos={group:{name:(before,path.lstat()) for name,(before,path) in entries.items()} for group,entries in snapshots.items()}
            cases+=check(output,expected,infos,groups)
            # Two live cursors survive cwd changes and renaming their parent directory.
            requests=[];expected=[]
            request(0,'sub/*.bin',result='handle',group=0);request(0,'éa.TXT',slot=1,result='handle',group=1)
            request(6,'child é🚀',result=1);request(7,'../sub' if rooted=='none' else '/sub',result=1)
            request(1,result=1,group=0);request(1,error=18);request(1,slot=1,error=18);request(2,result=1);request(2,slot=1,result=1)
            before={name:(sub/name).lstat() for name in ('one.bin','two.bin')};unicode_info=(root/'éa.TXT').lstat();output=execute(requests)
            moved=child/'renamed-directory';assert moved.is_dir() and not sub.exists()
            infos={0:{name:(info,(moved/name).lstat()) for name,info in before.items()},1:{'éa.TXT':(unicode_info,(root/'éa.TXT').lstat())}}
            cases+=check(output,expected,infos,[{'one.bin','two.bin'},{'éa.TXT'}])
            for mode in ('first-fault','next-fault','source-fault'):
                fault=subprocess.run([*COMMAND,*engine,'--allow-files',*options,GUEST,mode],cwd=root,capture_output=True,timeout=5)
                assert fault.returncode==125 and b'UnmappedMemory' in fault.stderr and not fault.stdout,fault
            # Host entries outside the supported Unicode / regular-file profile fail explicitly.
            for bad,error in (('invalid-utf8',1113),('fifo',50)):
                special=root/bad;special.mkdir()
                if bad=='fifo':os.mkfifo(special/'entry')
                else:
                    try:fd=os.open(os.fsencode(special)+b'/entry-\xff',os.O_CREAT|os.O_WRONLY,0o600)
                    except OSError as exc:
                        if exc.errno==errno.EILSEQ:continue # APFS rejects invalid UTF-8 names before enumeration.
                        raise
                    os.close(fd)
                requests=[];expected=[];request(0,bad+'/entry*',result=INVALID,error=error)
                cases+=check(execute(requests),expected,{},[])
    print(f'Windows enumeration {engine or ["interpreter"]}: {cases} SDK replies, recursive DOS wildcard and lstat metadata checks, four sysroots, Unicode/large files, symlinks, retained cursors, handle ownership and checked failures passed',flush=True)
