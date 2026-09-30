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
    run([guests/'system'],stdout=b'system: ok\n')
    run(['--env','KEY=value',guests/'arguments','foo','bar'],stdout=b'argc=3\nfoo\nbar\nKEY=value\n')
    run([guests/'arguments','foo'],stdout=b'argc=2\nfoo\n')
    with tempfile.TemporaryDirectory() as tmp:
        path=pathlib.Path(tmp)/'guest.txt'
        run([guests/'files',path],code=2,stdout=b'')
        assert not path.exists()
        run(['--allow-files',guests/'files',path],stdout=b'guest file\n')
        assert path.read_bytes()==b'guest file\n'
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
