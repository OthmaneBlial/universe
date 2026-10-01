#!/usr/bin/env python3
"""Real ELF execution, output/status/side-effect and malformed-input checks."""
import os, pathlib, platform, struct, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
RUNTIME=ROOT/'zig-out/bin/universe'
def run(args, code=0, stdout=None, stderr=None, input=None, cwd=None):
    p=subprocess.run([str(RUNTIME),*map(str,args)],input=input,capture_output=True,timeout=20,cwd=cwd)
    assert p.returncode==code,(args,p.returncode,p.stdout,p.stderr)
    if stdout is not None:assert p.stdout==stdout,(args,p.stdout)
    if stderr is not None:assert stderr in p.stderr,(args,p.stderr)
    return p
def pe_offset(data, rva):
    pe=struct.unpack_from('<I',data,60)[0]
    sections=pe+24+struct.unpack_from('<H',data,pe+20)[0]
    for n in range(struct.unpack_from('<H',data,pe+6)[0]):
        address,size,offset=struct.unpack_from('<III',data,sections+n*40+12)
        if address<=rva<address+size:return offset+rva-address
    raise AssertionError('RVA not backed by fixture file')
def pe_directory(data, index):
    optional=struct.unpack_from('<I',data,60)[0]+24
    return struct.unpack_from('<II',data,optional+112+index*8)
for arch in ['x86_64','riscv64','aarch64','riscv64/compressed']:
    guests=ROOT/'artifacts/guests'/arch
    run([guests/'hello'],stdout=b'Hello from foreign Linux machine code!\n')
    pie=(guests/'hello-pie').read_bytes()
    assert struct.unpack_from('<H',pie,16)[0]==3,'PIE fixture must be ET_DYN'
    run([guests/'hello-pie'],stdout=b'Hello from foreign Linux machine code!\n')
    run([guests/'compute'],stdout=b'compute: ok\n')
    run([guests/'echo'],code=37,stdout=b'input from host\n',stderr=b'guest stderr\n',input=b'input from host\n')
    run([guests/'system'],stdout=b'system: ok\n')
    with tempfile.TemporaryDirectory() as tmp:
        fixture=guests/'filesystem-mutate'
        run([fixture],code=10,cwd=tmp)
        assert not (pathlib.Path(tmp)/'created').exists()
        modes=[[]]+([['--jit']] if platform.machine() in ['arm64','aarch64'] else [])
        for mode in modes:
            run([*mode,'--allow-files',fixture],stdout=b'filesystem mutation: ok\n',cwd=tmp)
            assert not (pathlib.Path(tmp)/'created').exists()
    run(['--env','KEY=value',guests/'arguments','foo','bar'],stdout=b'argc=3\nfoo\nbar\nKEY=value\n')
    run([guests/'arguments','foo'],stdout=b'argc=2\nfoo\n')
    with tempfile.TemporaryDirectory() as tmp:
        path=pathlib.Path(tmp)/'guest.txt'
        run([guests/'files',path],code=2,stdout=b'')
        assert not path.exists()
        run(['--allow-files',guests/'files',path],stdout=b'guest file\n')
        assert path.read_bytes()==b'guest file\n'
        link=path.parent/'link';link.symlink_to(path.name)
        run(['--allow-files',guests/'files',link,'flags'],stdout=b'open flags: ok\n')
        link.unlink()
        run(['--allow-files','--sysroot',tmp,guests/'files','/sysroot-file.txt'],stdout=b'guest file\n')
        rooted=path.parent/'sysroot-file.txt'
        assert rooted.read_bytes()==b'guest file\n'
        rooted.unlink()
        mapped=path.parent/'mapped.bin'
        contents=b'A'*4096+b'mapped!'
        mapped.write_bytes(contents)
        run([guests/'mappings',mapped],code=77,stdout=b'')
        run(['--allow-files',guests/'mappings',mapped],stdout=b'mappings: ok\n')
        run(['--allow-files',guests/'mappings',mapped,'eof'],code=125,stderr=b'BusError')
        if platform.machine() in ['arm64','aarch64']:
            run(['--allow-files','--jit',guests/'mappings',mapped],stdout=b'mappings: ok\n')
        assert mapped.read_bytes()==contents
        mapped.unlink()
        (path.parent/'a').touch()
        listing=run(['--allow-files',guests/'directory',path.parent])
        assert set(listing.stdout.splitlines())=={b'.',b'..',b'guest.txt',b'a'}
    run(['trace',guests/'hello'],stdout=b'Hello from foreign Linux machine code!\n',stderr=b'syscall write(')
    run(['--max-instructions','1',guests/'compute'],code=125,stderr=b'InstructionLimit')
    run(['inspect',guests/'hello'],stderr=None)
    run(['inspect','--ir','--count','3',guests/'hello'])
    # Native differential checks are only possible on a matching Linux host.
    native=platform.system()=='Linux' and {'AMD64':'x86_64','arm64':'aarch64'}.get(platform.machine(),platform.machine())==arch.split('/')[0]
    if native:
        for program in ['hello','compute','system']:
            n=subprocess.run([guests/program],capture_output=True,timeout=20)
            u=run([guests/program]);assert (n.returncode,n.stdout,n.stderr)==(u.returncode,u.stdout,u.stderr)
    print(arch,': execution, syscall and memory checks passed',flush=True)
run([ROOT/'artifacts/guests/x86_64/hello-asm'],stdout=b'Hello from x86-64 Linux!\n')
sse2_right=b''.join(b'\x01'+bytes(width-1) for width in (1,2,4,8) for _ in range(16//width))
sse2_left=bytes([0x80,0x7f,0x00,0xff]*4)
sse2_compare_right=bytes([0x7f,0x80,0xff,0x00]*4)
sse2_sat_left=bytes([0x7f,0x80,0x01,0xff]*4)
sse2_sat_right=bytes([0x01,0xff,0x7f,0x80]*4)
sse2_sat_words=struct.pack('<HHHH',0x7fff,0x8000,1,0xffff)*2
sse2_sat_word_right=struct.pack('<HHHH',1,0xffff,0x7fff,0x8000)*2
sse2_unpack_left=bytes(range(16))
sse2_unpack_right=bytes(range(0x80,0x90))
sse2_average_left=bytes([0,1,255,254,128,127,170,85]*2)
sse2_average_right=bytes([1,0,254,255,127,128,85,170]*2)
run([ROOT/'artifacts/guests/x86_64/sse2-arithmetic'],stdout=b'SSE2 arithmetic, unpack, average and SAD: ok\n',input=b'\xff'*16+sse2_right+sse2_left+sse2_compare_right+sse2_sat_left+sse2_sat_right+sse2_sat_words+sse2_sat_word_right+sse2_unpack_left+sse2_unpack_right+sse2_average_left+sse2_average_right)
sse2_mul_left=struct.pack('<8H',0x7fff,0x8000,0xffff,2,0x8000,0x8000,0xffff,0x0100)
sse2_mul_right=struct.pack('<8H',2,0xffff,2,0x8000,0x8000,0x8000,0xffff,0x0100)
run([ROOT/'artifacts/guests/x86_64/sse2-multiply'],stdout=b'SSE2 packed multiply: ok\n',input=sse2_mul_left+sse2_mul_right)
sse2_shift_data=struct.pack('<8H',0x8001,0x7fff,0xffff,0x1234,0x8000,0x0001,0x55aa,0xaa55)
for shift in [0,1,15,16,17,31,32,63,64,65]:
    run([ROOT/'artifacts/guests/x86_64/sse2-shift'],stdout=b'SSE2 variable shifts: ok\n',input=sse2_shift_data+struct.pack('<QQ',shift,0xffffffffffffffff))
sse2_pack_left=struct.pack('<4I',0x80000000,0xffff7fff,0xffff8000,0xffffffff)
sse2_pack_right=struct.pack('<4I',0,0x7fff,0x8000,0x7fffffff)
sse2_insert_values=struct.pack('<8H',0x1111,0x2222,0x3333,0x4444,0x5555,0x6666,0x7777,0x8888)
run([ROOT/'artifacts/guests/x86_64/sse2-pack'],stdout=b'SSE2 saturating pack and insert: ok\n',input=sse2_pack_left+sse2_pack_right+sse2_insert_values)
pshufb_data=bytes(range(16))
pshufb_control=bytes([0x0f,0x00,0x08,0x07,0x80,0x8f,0x10,0x1f,0x01,0x81,0x70,0x40,0xff,0x00,0x0f,0x84])
psign_data=bytes([1,0,0,0x80,0xff,0xff,0xff,0x7f,0xff,0xff,0xff,0xff,0x34,0x12,0x00,0x00])
psign_byte_control=bytes([0x80,0,1,0x7f,0xff,0,0x80,1,0x7f,0x80,0,0xff,1,0,0x7f,0x80])
psign_word_control=struct.pack('<8H',0x4000,0x8000,0x4000,0x7fff,0xffff,0x0100,0xff00,0x8001)
psign_dword_control=struct.pack('<4I',0x80000000,0,1,0x7fffffff)
maddubsw_data=bytes([0xff]*16)
maddubsw_control=bytes([127,127,128,128,127,0,128,0,127,128,0,255,1,0,127,128])
ssse3_input=pshufb_data+pshufb_control+psign_data+psign_byte_control+psign_word_control+psign_dword_control+maddubsw_data+maddubsw_control+b'\0'
run([ROOT/'artifacts/guests/x86_64/ssse3-shuffle'],stdout=b'SSSE3 byte shuffle, arithmetic and alignment: ok\n',input=ssse3_input)
misaligned_ssse3_input=bytearray(ssse3_input);misaligned_ssse3_input[-1]=1
run([ROOT/'artifacts/guests/x86_64/ssse3-shuffle'],code=125,stdout=b'',stderr=b'MisalignedMemory',input=misaligned_ssse3_input)
sse41_input=struct.pack('<4I',0x80000000,0xffffffff,0x7fffffff,0x40000000)+struct.pack('<4I',1,0x80000000,0xffffffff,0x40000000)
run([ROOT/'artifacts/guests/x86_64/sse4.1-integer'],stdout=b'SSE4.1 integer lanes: ok\n',input=sse41_input)
for mode in [[]]+([['--jit']] if platform.machine() in ['arm64','aarch64'] else []):
    atomic=ROOT/'artifacts/guests/riscv64/atomics'
    run([*mode,atomic],stdout=b'riscv atomics: ok\n')
    run([*mode,atomic,'misaligned'],code=125,stdout=b'',stderr=b'MisalignedMemory')
    run([*mode,'--max-instructions','1',atomic],code=125,stdout=b'',stderr=b'InstructionLimit')
    run([*mode,ROOT/'artifacts/guests/riscv64/floating'],stdout=b'riscv F/D CSR: ok\n')
with tempfile.TemporaryDirectory() as tmp:
    file=pathlib.Path(tmp)/'malformed'
    original=(ROOT/'artifacts/guests/x86_64/hello-asm').read_bytes()
    for content in [b'',b'\x7fELF',original[:63],original[:100]]:
        file.write_bytes(content);run([file],code=125,stderr=b'UNIVERSE:')
    for off,fmt,value in [(32,'Q',2**64-1),(56,'H',65535),(24,'Q',0)]:
        data=bytearray(original);struct.pack_into('<'+fmt,data,off,value);file.write_bytes(data);run([file],code=125)
    # Patch entry's actual file offset, not a fixed compiler-dependent location.
    entry=struct.unpack_from('<Q',original,24)[0];phoff=struct.unpack_from('<Q',original,32)[0];phnum=struct.unpack_from('<H',original,56)[0]
    for i in range(phnum):
        kind,flags,offset,address,_,filesz,memsz,align=struct.unpack_from('<IIQQQQQQ',original,phoff+56*i)
        if kind==1 and address<=entry<address+filesz:entry_offset=offset+entry-address;break
    for machine,expected in [(b'\x0f\x0b',b'UnsupportedInstruction'),(b'\x48\x31\xc0\x48\x8b\x00',b'UnmappedMemory'),(b'\x48\x31\xc0\xff\xe0',b'UnmappedMemory'),(b'\xb8\x0f\x27\x00\x00\x0f\x05',b'UnsupportedSyscall')]:
        data=bytearray(original);data[entry_offset:entry_offset+len(machine)]=machine;file.write_bytes(data);run([file],code=125,stderr=expected)
    machine=b'\x48\x89\xe7\xb9\xff\xff\xff\xff\x31\xc0\xf3\xaa'
    data=bytearray(original);data[entry_offset:entry_offset+len(machine)]=machine;file.write_bytes(data)
    run(['--max-instructions','10',file],code=125,stderr=b'InstructionLimit')
with tempfile.TemporaryDirectory() as tmp:
    fifo=pathlib.Path(tmp)/'binary.dll';os.mkfifo(fifo)
    run(['inspect',fifo],code=125,stdout=b'',stderr=b'UnsupportedBinaryFile')
    run(['inspect',tmp],code=125,stdout=b'',stderr=b'UnsupportedBinaryFile')
    if os.geteuid()!=0:
        denied=pathlib.Path(tmp)/'denied';denied.write_bytes(b'MZ');denied.chmod(0)
        try:run(['inspect',denied],code=125,stdout=b'',stderr=b'BinaryAccessDenied')
        finally:denied.chmod(0o600)
print('Malformed binaries and guest faults passed')

with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp);(root/'lib').mkdir()
    program=root/'program';interpreter=root/'lib/ld-test.so'
    original=(ROOT/'artifacts/guests/x86_64/hello').read_bytes()
    def interpreted(name):
        data=bytearray(original);offset=len(data);data+=name
        phoff=struct.unpack_from('<Q',data,32)[0];phnum=struct.unpack_from('<H',data,56)[0]
        slot=next(i for i in range(phnum) if struct.unpack_from('<I',data,phoff+56*i)[0]==0x6474e551)
        struct.pack_into('<IIQQQQQQ',data,phoff+56*slot,3,4,offset,0,0,len(name),len(name),1)
        return data
    data=interpreted(b'/lib/ld-test.so\0');program.write_bytes(data)
    run([program],code=125,stderr=b'MissingSysroot')
    run(['--sysroot',root,program],code=125,stderr=b'FileAccessDenied')
    options=['--sysroot',root,'--allow-files']
    # A distinct interpreter entry executes before the main program's entry.
    loader=bytearray((ROOT/'artifacts/guests/x86_64/hello-asm').read_bytes())
    struct.pack_into('<H',loader,16,3);interpreter.write_bytes(loader)
    run([*options,program],stdout=b'Hello from x86-64 Linux!\n')
    interpreter.write_bytes((ROOT/'artifacts/guests/aarch64/hello').read_bytes())
    run([*options,program],code=125,stderr=b'ArchitectureMismatch')
    interpreter.write_bytes(data)
    run([*options,program],code=125,stderr=b'RecursiveInterpreterUnsupported')
    interpreter.write_bytes(b'\x7fELF')
    run([*options,program],code=125,stderr=b'TruncatedBinary')
    program.write_bytes(interpreted(b'/lib/ld\0ignored\0'))
    run([*options,program],code=125,stderr=b'InvalidInterpreter')
print('PIE, interpreter handoff, sysroot permissions and malformed interpreters passed')

run(['debug',ROOT/'artifacts/guests/x86_64/hello-asm'],input=b'registers\nstep\nir\ncontinue\n',stderr=None)
for program,trace in [('artifacts/guests/x86_64/hello-asm',b'syscall write('),('artifacts/hello.exe',b'kernel32!WriteFile')]:
    run(['debug',ROOT/program],input=b'syscalls\nrun\nquit\n',stderr=trace)
run([ROOT/'artifacts/hello.exe'],stdout=b'Hello from Windows x86-64!\n')
run(['trace',ROOT/'artifacts/hello.exe'],stdout=b'Hello from Windows x86-64!\n',stderr=b'kernel32!WriteFile')
run([ROOT/'artifacts/windows-system.exe'],stdout=b'windows system: ok\n')
run([ROOT/'artifacts/windows-echo.exe'],stdout=b'Windows input\n',input=b'Windows input\n')
windows_process=ROOT/'artifacts/windows-process.exe'
windows_arguments=['','a b','a"b','tail\\','é🚀']
windows_line=('"'+str(windows_process)+'" "" "a b" "a\\"b" "tail\\\\" "é🚀"').encode()
windows_output=b'command A: '+windows_line+b'\ncommand W: '+windows_line+b'\nwindows process: ok\n'
windows_modes=[[]]+([['--jit']] if platform.machine() in ['arm64','aarch64'] else [])
for mode in windows_modes:
    run([*mode,windows_process,*windows_arguments],stdout=windows_output)
    with tempfile.TemporaryDirectory() as tmp:
        path=pathlib.Path(tmp)/'Windows é🚀 file.txt'
        guest=ROOT/'artifacts/windows-files.exe'
        run([*mode,guest,path],stdout=b'windows files: denied\n')
        assert not path.exists()
        run([*mode,'--allow-files',guest,path],stdout=b'windows files: ok\n')
        assert path.read_bytes()==b'Windows file\n'
        path.unlink()
        run([*mode,'--allow-files','--sysroot',tmp,guest,'/Windows é🚀 file.txt'],stdout=b'windows files: ok\n')
        assert path.read_bytes()==b'Windows file\n'
run(['--env','KEY=value',windows_process],code=125,stderr=b'WindowsEnvironmentUnsupported')
windows_dll=ROOT/'artifacts/windows-dll.exe'
windows_root=ROOT/'artifacts/windows-sysroot'
dll_output=b'windows DLL: imports, exports, relocations and initialization ok\n'
run([windows_dll],code=125,stderr=b'MissingSysroot')
run(['--sysroot',windows_root,windows_dll],code=125,stderr=b'FileAccessDenied')
for mode in windows_modes:
    run([*mode,'--allow-files','--sysroot',windows_root,windows_dll],stdout=dll_output)
    run([*mode,'--allow-files','--sysroot',windows_root,'--max-instructions','1',windows_dll],code=125,stderr=b'InstructionLimit')
run(['inspect',windows_root/'windows-probe.dll'])
run([windows_root/'windows-probe.dll'],code=125,stderr=b'WindowsDLLExecutionUnsupported')
with tempfile.TemporaryDirectory() as tmp:
    program=pathlib.Path(tmp)/'upper.exe'
    program.write_bytes(windows_dll.read_bytes().replace(b'windows-probe.dll',b'WINDOWS-PROBE.DLL'))
    run(['--allow-files','--sysroot',windows_root,program],stdout=dll_output)
    run(['--allow-files','--sysroot',tmp,windows_dll],code=125,stderr=b'WindowsDLLNotFound')
with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp)
    originals={name:(windows_root/name).read_bytes() for name in ['windows-helper.dll','windows-probe.dll']}
    for name,data in originals.items():(root/name).write_bytes(data)
    options=['--allow-files','--sysroot',root]
    # Replace one real named import with the export's public ordinal.
    data=bytearray(windows_dll.read_bytes())
    replaced=0
    descriptor=pe_offset(data,pe_directory(data,1)[0])
    while struct.unpack_from('<I',data,descriptor+12)[0]:
        lookup=struct.unpack_from('<I',data,descriptor)[0] or struct.unpack_from('<I',data,descriptor+16)[0]
        thunk=pe_offset(data,lookup)
        while struct.unpack_from('<Q',data,thunk)[0]:
            item=struct.unpack_from('<Q',data,thunk)[0]
            name=pe_offset(data,item)+2
            if data[name:name+6]==b'probe\0':
                struct.pack_into('<Q',data,thunk,2**63|7);replaced+=1
            thunk+=8
        descriptor+=20
    assert replaced==1,'fixture must import probe by name before ordinal mutation'
    program=root/'ordinal.exe';program.write_bytes(data)
    for mode in windows_modes:run([*mode,*options,program],stdout=dll_output)
    # Mutate actual library tables/code, keeping the executable unchanged.
    helper=originals['windows-helper.dll'];optional=struct.unpack_from('<I',helper,60)[0]+24
    export=pe_offset(helper,pe_directory(helper,0)[0])
    entry=pe_offset(helper,struct.unpack_from('<I',helper,optional+16)[0])
    mutations=[(optional+116+5*8,'I',0,b'PERelocationsMissing'),
               (optional+112+9*8,'II',(0x1000,1),b'PETLSUnsupported'),
               (export+20,'I',65537,b'InvalidWindowsExport'),
               (export+28,'I',2**32-1,b'InvalidWindowsRva'),
               (pe_offset(helper,struct.unpack_from('<I',helper,export+36)[0]),'H',65535,b'InvalidWindowsExport')]
    for offset,fmt,value,error in mutations:
        data=bytearray(helper);struct.pack_into('<'+fmt,data,offset,*(value if isinstance(value,tuple) else (value,)))
        (root/'windows-helper.dll').write_bytes(data)
        for mode in windows_modes:run([*mode,*options,windows_dll],code=125,stdout=b'',stderr=error)
    data=bytearray(helper);data[entry:entry+3]=b'\x31\xc0\xc3'
    (root/'windows-helper.dll').write_bytes(data)
    for mode in windows_modes:
        failure=run([*mode,*options,windows_dll],code=125,stdout=b'',stderr=b'WindowsDLLInitializationFailed')
        assert b'Windows DLL initialization failed: windows-helper.dll' in failure.stderr
    (root/'windows-helper.dll').write_bytes(helper)
    data=bytearray(originals['windows-probe.dll'])
    forward=data.index(b'windows-helper.helper_add\0')
    data[forward:forward+26]=b'windows-probe.#10\0'.ljust(26,b'\0')
    (root/'windows-probe.dll').write_bytes(data)
    for mode in windows_modes:run([*mode,*options,windows_dll],code=125,stdout=b'',stderr=b'WindowsForwarderCycle')
print('Guest DLL rebasing, ordinal imports, initialization and malformed exports passed')
windows_dynamic=ROOT/'artifacts/windows-dynamic.exe'
dynamic_output=b'windows dynamic DLL: references, forwarders, detach and reload ok\n'
for mode in windows_modes:
    result=run([*mode,'--allow-files','--sysroot',windows_root,windows_dynamic],stdout=dynamic_output)
    assert not result.stderr
    run([*mode,windows_dynamic],code=126,stdout=b'')
    run([*mode,'--sysroot',windows_root,windows_dynamic],code=5,stdout=b'')
    run([*mode,'--allow-files','--sysroot',windows_root,'--max-instructions','1',windows_dynamic],code=125,stdout=b'',stderr=b'InstructionLimit')
if os.geteuid()!=0:
    with tempfile.TemporaryDirectory() as tmp:
        root=pathlib.Path(tmp);root.chmod(0)
        try:
            for mode in windows_modes:run([*mode,'--allow-files','--sysroot',root,windows_dynamic],code=5,stdout=b'')
        finally:root.chmod(0o700)
with tempfile.TemporaryDirectory() as tmp:
    root=pathlib.Path(tmp)
    originals={name:(windows_root/name).read_bytes() for name in ['windows-helper.dll','windows-probe.dll','windows-late.dll']}
    for name,data in originals.items():(root/name).write_bytes(data)
    options=['--allow-files','--sysroot',root]
    data=bytearray(originals['windows-probe.dll'])
    optional=struct.unpack_from('<I',data,60)[0]+24
    entry=pe_offset(data,struct.unpack_from('<I',data,optional+16)[0])
    data[entry:entry+3]=b'\x31\xc0\xc3'
    (root/'windows-probe.dll').write_bytes(data)
    for mode in windows_modes:
        result=run([*mode,*options,windows_dynamic,'rollback'],stdout=b'windows dynamic DLL: rollback ok\n')
        assert not result.stderr
    trace=run(['--syscalls',*options,windows_dynamic,'rollback'],stdout=b'windows dynamic DLL: rollback ok\n')
    assert trace.stderr.count(b'kernel32!LoadLibraryA = 0x0\n')==1
    assert trace.stderr.index(b'DLL_PROCESS_DETACH: windows-probe.dll') < trace.stderr.index(b'kernel32!LoadLibraryA = 0x0\n')
    (root/'windows-probe.dll').write_bytes(originals['windows-probe.dll'])
    (root/'windows-late.dll').unlink()
    for mode in windows_modes:run([*mode,*options,windows_dynamic,'forward-fail'],code=126,stdout=b'')
    late=originals['windows-late.dll'];optional=struct.unpack_from('<I',late,60)[0]+24
    entry=pe_offset(late,struct.unpack_from('<I',late,optional+16)[0])
    rejected=bytearray(late);rejected[entry:entry+3]=b'\x31\xc0\xc3'
    tls=bytearray(late);struct.pack_into('<II',tls,optional+112+9*8,0x1000,1)
    for data,code in [(b'MZ',193),(rejected,1114 & 255),(tls,50)]:
        (root/'windows-late.dll').write_bytes(data)
        for mode in windows_modes:run([*mode,*options,windows_dynamic,'forward-fail'],code=code,stdout=b'')
    (root/'windows-late.dll').unlink()
    os.mkfifo(root/'windows-late.dll')
    for mode in windows_modes:run([*mode,*options,windows_dynamic,'forward-fail'],code=193,stdout=b'')
    (root/'windows-late.dll').unlink()
    if os.geteuid()!=0:
        denied=root/'windows-late.dll';denied.write_bytes(late);denied.chmod(0)
        try:
            for mode in windows_modes:run([*mode,*options,windows_dynamic,'forward-fail'],code=5,stdout=b'')
        finally:denied.chmod(0o600)
print('Runtime DLL references, forwarders, detach, reload, permission failures and rollback passed')

run([ROOT/'artifacts/windows-unsupported.exe'],code=125,stderr=b'Unsupported Windows API: KERNEL32.dll!GetTickCount')
if platform.machine() in ['arm64','aarch64']:
    for arch in ['x86_64','riscv64','aarch64','riscv64/compressed']:
        guests=ROOT/'artifacts/guests'/arch
        for name in ['hello','compute','system']:
            interpreted=run([guests/name]);compiled=run(['--jit',guests/name]);assert (interpreted.stdout,interpreted.stderr)==(compiled.stdout,compiled.stderr)
        run(['--jit','--max-instructions','1',guests/'compute'],code=125,stderr=b'InstructionLimit')
        if arch=='riscv64/compressed':
            run(['--jit',guests/'hello-pie'],stdout=b'Hello from foreign Linux machine code!\n')
            run(['--jit','--env','KEY=value',guests/'arguments','foo','bar'],stdout=b'argc=3\nfoo\nbar\nKEY=value\n')
            run(['--jit',guests/'echo'],code=37,stdout=b'input from host\n',stderr=b'guest stderr\n',input=b'input from host\n')
            with tempfile.TemporaryDirectory() as tmp:
                path=pathlib.Path(tmp)/'guest.txt'
                run(['--jit','--allow-files',guests/'files',path],stdout=b'guest file\n')
                assert path.read_bytes()==b'guest file\n'
                (path.parent/'a').touch()
                listing=run(['--jit','--allow-files',guests/'directory',path.parent])
                assert set(listing.stdout.splitlines())=={b'.',b'..',b'guest.txt',b'a'}
    run(['--jit',ROOT/'artifacts/hello.exe'],stdout=b'Hello from Windows x86-64!\n')
else:
    run(['--jit',ROOT/'artifacts/guests/x86_64/hello'],code=125,stderr=b'UnsupportedJitHost')
print('Debugger, PE32+ Windows and JIT differential checks passed')

run([ROOT/'artifacts/musl-hello'],stdout=b'Hello from static musl!\n')
if platform.machine() in ['arm64','aarch64']:run(['--jit',ROOT/'artifacts/musl-hello'],stdout=b'Hello from static musl!\n')
print('Static x86-64 musl Hello World passed')

expected=b'ba690c62ba5fb61d\n'
for arch in ['x86_64','riscv64','aarch64','riscv64/compressed']:
    run([ROOT/'artifacts/guests'/arch/'benchmark'],stdout=expected)
    if platform.machine() in ['arm64','aarch64']:run(['--jit',ROOT/'artifacts/guests'/arch/'benchmark'],stdout=expected)
with tempfile.TemporaryDirectory() as tmp:
    file=pathlib.Path(tmp)/'macho'
    header=struct.pack('<IiiIIIII',0xfeedfacf,0x100000c,0,2,2,96,0,0)
    segment=struct.pack('<II16sQQQQiiII',0x19,72,b'__TEXT',0x100000000,4096,0,132,5,5,0,0)
    main=struct.pack('<IIQQ',0x80000028,24,128,0)
    file.write_bytes(header+segment+main+b'\x1f\x20\x03\xd5')
    run(['inspect',file]);run([file],code=125,stderr=b'UnsupportedInstruction')
    data=bytearray(file.read_bytes());struct.pack_into('<I',data,16,4097);file.write_bytes(data);run(['inspect',file],code=125,stderr=b'InvalidMachOCommands')
print('Benchmarks and Mach-O inspection passed')

if platform.system()=='Darwin':
    for arch in ['x86_64','aarch64']:
        guests=ROOT/'artifacts/macos'/arch
        modes=[[]]+([['--jit']] if platform.machine() in ['arm64','aarch64'] else [])
        for mode in modes:
            run([*mode,guests/'hello'],stdout=b'Hello from macOS guest machine code!\n')
            run([*mode,guests/'system'],stdout=b'macOS system: ok\n')
            run([*mode,guests/'echo'],code=37,stdout=b'Darwin input\n',stderr=b'Darwin guest stderr\n',input=b'Darwin input\n')
            run([*mode,'--env','KEY=value',guests/'arguments','foo','é🚀'],stdout='foo\né🚀\nKEY=value\n'.encode())
            run([*mode,guests/'arguments'],stdout=b'')
            run([*mode,'--max-instructions','1',guests/'hello'],code=125,stdout=b'',stderr=b'InstructionLimit')
            run([*mode,guests/'system','protect'],code=125,stdout=b'',stderr=b'PermissionDenied')
            with tempfile.TemporaryDirectory() as tmp:
                path=pathlib.Path(tmp)/'Darwin é🚀 file.txt'
                run([*mode,guests/'files',path],stdout=b'macOS files: denied\n')
                assert not path.exists()
                run([*mode,'--allow-files',guests/'files',path],stdout=b'macOS files: ok\n')
                assert path.read_bytes()==b'Darwin file\n'
                path.unlink()
                run([*mode,'--allow-files','--sysroot',tmp,guests/'files','/Darwin é🚀 file.txt'],stdout=b'macOS files: ok\n')
                assert path.read_bytes()==b'Darwin file\n'
                path.unlink()
                run([*mode,'--allow-files',guests/'files',path,'eof'],code=125,stdout=b'',stderr=b'BusError')
                assert path.read_bytes()==b'Darwin file\n'
        run(['trace',guests/'hello'],stdout=b'Hello from macOS guest machine code!\n',stderr=b'Darwin syscall write')
        run(['debug',guests/'hello'],input=b'syscalls\nrun\nquit\n',stderr=b'Darwin syscall write')
        run(['inspect','--ir','--count','3',guests/'hello'])
        run(['inspect',guests/'hello'],stdout=None,stderr=None)
        if {'arm64':'aarch64','x86_64':'x86_64'}.get(platform.machine())==arch:
            # Same syscall source, compiled with ordinary native startup. This does
            # not claim the host accepts the standalone LC_UNIXTHREAD executable.
            for name,stdin in [('hello',None),('system',None),('echo',b'Darwin input\n')]:
                native=subprocess.run([guests/(name+'-native')],input=stdin,capture_output=True,env={},timeout=20)
                interpreted=run([guests/name],code=37 if name=='echo' else 0,input=stdin)
                assert (native.returncode,native.stdout,native.stderr)==(interpreted.returncode,interpreted.stdout,interpreted.stderr)
            with tempfile.TemporaryDirectory() as tmp:
                native_path=pathlib.Path(tmp)/'native.txt';guest_path=pathlib.Path(tmp)/'guest.txt'
                native=subprocess.run([guests/'files-native',native_path],capture_output=True,env={},timeout=20)
                interpreted=run(['--allow-files',guests/'files',guest_path])
                assert (native.returncode,native.stdout,native.stderr)==(interpreted.returncode,interpreted.stdout,interpreted.stderr)
                assert native_path.read_bytes()==guest_path.read_bytes()==b'Darwin file\n'
            run([guests/'hello-native'],code=125,stdout=b'',stderr=b'MachOLibrariesUnsupported')
            print(arch,': native-source Darwin syscall comparisons passed')
        with tempfile.TemporaryDirectory() as tmp:
            program=pathlib.Path(tmp)/'malformed-macho'
            original=(guests/'hello').read_bytes()
            commands=[];off=32
            for n in range(struct.unpack_from('<I',original,16)[0]):
                kind,size=struct.unpack_from('<II',original,off);commands.append((kind,off,size));off+=size
            text=next(off for kind,off,size in commands if kind==0x19 and original[off+8:off+14]==b'__TEXT')
            thread=next(off for kind,off,size in commands if kind==5)
            pc=struct.unpack_from('<Q',original,thread+16+(16 if arch=='x86_64' else 32)*8)[0]
            address,fileoff=struct.unpack_from('<Q',original,text+24)[0],struct.unpack_from('<Q',original,text+40)[0]
            entry=fileoff+pc-address
            mutations=[(text+24,'Q',0xffffffffffffffff,b'AddressOverflow'),
                       (text+32,'Q',512*1024*1024,b'InvalidMachOMapping'),
                       (text+60,'I',7,b'InvalidMachOProtection'),
                       (text+64,'I',65535,b'InvalidMachOSegment'),
                       (text+72+40,'Q',0xffffffffffffffff,b'InvalidMachOSection'),
                       (text+72+60,'I',1,b'MachORelocationsUnsupported'),
                       (thread+12,'I',1,b'UnsupportedMachOThreadState'),
                       (thread+16+(16 if arch=='x86_64' else 32)*8,'Q',0,b'InvalidMachOEntry'),
                       (12,'I',6,b'MachOExecutableRequired')]
            for offset,fmt,value,error in mutations:
                data=bytearray(original);struct.pack_into('<'+fmt,data,offset,value);program.write_bytes(data)
                run([program],code=125,stdout=b'',stderr=error)
            # Replace actual entry instructions to exercise unsupported traps/classes.
            code=b'\xb8\xff\xff\x00\x02\x0f\x05' if arch=='x86_64' else struct.pack('<II',0xd29ffff0,0xd4001001)
            data=bytearray(original);data[entry:entry+len(code)]=code;program.write_bytes(data)
            for mode in modes:run([*mode,program],code=125,stdout=b'',stderr=b'UnsupportedMacOSSyscall')
            code=b'\xb8\x04\x00\x00\x01\x0f\x05' if arch=='x86_64' else struct.pack('<II',0x92800010,0xd4001001)
            data=bytearray(original);data[entry:entry+len(code)]=code;program.write_bytes(data)
            run([program],code=125,stdout=b'',stderr=b'UnsupportedMacOSSyscallClass')
            if arch=='aarch64':
                data=bytearray(original);struct.pack_into('<I',data,entry,0xd4000001);program.write_bytes(data)
                run([program],code=125,stdout=b'',stderr=b'UnsupportedSyscallTrap')
    print('Mach-O x86-64/AArch64 guest code, Darwin ABI, files and JIT comparisons passed')

with tempfile.TemporaryDirectory() as tmp:
    file=pathlib.Path(tmp)/'pe'
    original=(ROOT/'artifacts/hello.exe').read_bytes();pe=struct.unpack_from('<I',original,60)[0]
    for off,fmt,value in [(60,'I',2**32-1),(pe+6,'H',65535),(pe+24+56,'I',2**32-1),(pe+24+108,'I',65535)]:
        data=bytearray(original);struct.pack_into('<'+fmt,data,off,value);file.write_bytes(data);run(['inspect',file],code=125)
    # Import table entries are guest RVAs, never unchecked host-sized offsets.
    optional=pe+24
    imports=struct.unpack_from('<I',original,optional+112+8)[0]
    descriptor=pe_offset(original,imports);lookup=struct.unpack_from('<I',original,descriptor)[0]
    if not lookup:lookup=struct.unpack_from('<I',original,descriptor+16)[0]
    data=bytearray(original);struct.pack_into('<Q',data,pe_offset(original,lookup),2**63-1)
    file.write_bytes(data);run([file],code=125,stderr=b'InvalidWindowsImport')
print('Malformed PE and import checks passed')
