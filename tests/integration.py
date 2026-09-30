#!/usr/bin/env python3
"""Real ELF execution, output/status/side-effect and malformed-input checks."""
import os, pathlib, platform, struct, subprocess, tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
RUNTIME=ROOT/'zig-out/bin/universe'
def run(args, code=0, stdout=None, stderr=None, input=None):
    p=subprocess.run([str(RUNTIME),*map(str,args)],input=input,capture_output=True,timeout=20)
    assert p.returncode==code,(args,p.returncode,p.stdout,p.stderr)
    if stdout is not None:assert p.stdout==stdout,(args,p.stdout)
    if stderr is not None:assert stderr in p.stderr,(args,p.stderr)
    return p
for arch in ['x86_64','riscv64','aarch64']:
    guests=ROOT/'artifacts/guests'/arch
    run([guests/'hello'],stdout=b'Hello from foreign Linux machine code!\n')
    run([guests/'compute'],stdout=b'compute: ok\n')
    run([guests/'echo'],code=37,stdout=b'input from host\n',stderr=b'guest stderr\n',input=b'input from host\n')
    run([guests/'system'],stdout=b'system: ok\n')
    run(['--env','KEY=value',guests/'arguments','foo','bar'],stdout=b'argc=3\nfoo\nbar\nKEY=value\n')
    run([guests/'arguments','foo'],stdout=b'argc=2\nfoo\n')
    with tempfile.TemporaryDirectory() as tmp:
        path=pathlib.Path(tmp)/'guest.txt'
        run([guests/'files',path],code=2,stdout=b'')
        assert not path.exists()
        run(['--allow-files',guests/'files',path],stdout=b'guest file\n')
        assert path.read_bytes()==b'guest file\n'
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
    native=platform.system()=='Linux' and {'AMD64':'x86_64','arm64':'aarch64'}.get(platform.machine(),platform.machine())==arch
    if native:
        for program in ['hello','compute','system']:
            n=subprocess.run([guests/program],capture_output=True,timeout=20)
            u=run([guests/program]);assert (n.returncode,n.stdout,n.stderr)==(u.returncode,u.stdout,u.stderr)
    print(arch,': execution, syscall and memory checks passed',flush=True)
run([ROOT/'artifacts/guests/x86_64/hello-asm'],stdout=b'Hello from x86-64 Linux!\n')
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
print('Malformed binaries and guest faults passed')

run(['debug',ROOT/'artifacts/guests/x86_64/hello-asm'],input=b'registers\nstep\nir\ncontinue\n',stderr=None)
run([ROOT/'artifacts/hello.exe'],stdout=b'Hello from Windows x86-64!\n')
run(['trace',ROOT/'artifacts/hello.exe'],stdout=b'Hello from Windows x86-64!\n',stderr=b'kernel32!WriteFile')
run([ROOT/'artifacts/windows-system.exe'],stdout=b'windows system: ok\n')
run([ROOT/'artifacts/windows-echo.exe'],stdout=b'Windows input\n',input=b'Windows input\n')
run([ROOT/'artifacts/windows-unsupported.exe'],code=125,stderr=b'Unsupported Windows API: KERNEL32.dll!GetTickCount')
if platform.machine() in ['arm64','aarch64']:
    for arch in ['x86_64','riscv64','aarch64']:
        guests=ROOT/'artifacts/guests'/arch
        for name in ['hello','compute','system']:
            interpreted=run([guests/name]);compiled=run(['--jit',guests/name]);assert (interpreted.stdout,interpreted.stderr)==(compiled.stdout,compiled.stderr)
        run(['--jit','--max-instructions','1',guests/'compute'],code=125,stderr=b'InstructionLimit')
    run(['--jit',ROOT/'artifacts/hello.exe'],stdout=b'Hello from Windows x86-64!\n')
else:
    run(['--jit',ROOT/'artifacts/guests/x86_64/hello'],code=125,stderr=b'UnsupportedJitHost')
print('Debugger, PE32+ Windows and JIT differential checks passed')

run([ROOT/'artifacts/musl-hello'],stdout=b'Hello from static musl!\n')
if platform.machine() in ['arm64','aarch64']:run(['--jit',ROOT/'artifacts/musl-hello'],stdout=b'Hello from static musl!\n')
print('Static x86-64 musl Hello World passed')

expected=b'ba690c62ba5fb61d\n'
for arch in ['x86_64','riscv64','aarch64']:
    run([ROOT/'artifacts/guests'/arch/'benchmark'],stdout=expected)
    if platform.machine() in ['arm64','aarch64']:run(['--jit',ROOT/'artifacts/guests'/arch/'benchmark'],stdout=expected)
with tempfile.TemporaryDirectory() as tmp:
    file=pathlib.Path(tmp)/'macho'
    header=struct.pack('<IiiIIIII',0xfeedfacf,0x100000c,0,2,2,96,0,0)
    segment=struct.pack('<II16sQQQQiiII',0x19,72,b'__TEXT',0x100000000,4096,0,132,5,5,0,0)
    main=struct.pack('<IIQQ',0x80000028,24,128,0)
    file.write_bytes(header+segment+main+b'\x1f\x20\x03\xd5')
    run(['inspect',file]);run([file],code=125,stderr=b'MachOExecutionUnsupported')
    data=bytearray(file.read_bytes());struct.pack_into('<I',data,16,4097);file.write_bytes(data);run(['inspect',file],code=125,stderr=b'InvalidMachOCommands')
print('Benchmarks and Mach-O inspection passed')

with tempfile.TemporaryDirectory() as tmp:
    file=pathlib.Path(tmp)/'pe'
    original=(ROOT/'artifacts/hello.exe').read_bytes();pe=struct.unpack_from('<I',original,60)[0]
    for off,fmt,value in [(60,'I',2**32-1),(pe+6,'H',65535),(pe+24+56,'I',2**32-1),(pe+24+108,'I',65535)]:
        data=bytearray(original);struct.pack_into('<'+fmt,data,off,value);file.write_bytes(data);run(['inspect',file],code=125)
    # Import table entries are guest RVAs, never unchecked host-sized offsets.
    optional=pe+24;section_count=struct.unpack_from('<H',original,pe+6)[0]
    sections=optional+struct.unpack_from('<H',original,pe+20)[0]
    def file_offset(rva):
        for n in range(section_count):
            section=sections+n*40
            address,size,offset=struct.unpack_from('<III',original,section+12)
            if address<=rva<address+size:return offset+rva-address
        raise AssertionError('RVA not backed by fixture file')
    imports=struct.unpack_from('<I',original,optional+112+8)[0]
    descriptor=file_offset(imports);lookup=struct.unpack_from('<I',original,descriptor)[0]
    if not lookup:lookup=struct.unpack_from('<I',original,descriptor+16)[0]
    data=bytearray(original);struct.pack_into('<Q',data,file_offset(lookup),2**63-1)
    file.write_bytes(data);run([file],code=125,stderr=b'InvalidWindowsImport')
print('Malformed PE and import checks passed')
