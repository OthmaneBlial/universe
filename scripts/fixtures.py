#!/usr/bin/env python3
"""Build guest ELF fixtures from checked-in source using Zig's cross C compiler."""
import pathlib, subprocess, argparse
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--arch', choices=['x86_64','riscv64','aarch64','all'],default='all');args=p.parse_args()
for arch in (['x86_64','riscv64','aarch64'] if args.arch=='all' else [args.arch]):
    out=ROOT/'artifacts'/'guests'/arch;out.mkdir(parents=True,exist_ok=True)
    flags=['zig','cc','-target',arch+'-linux-musl','-nostdlib','-ffreestanding','-static','-fno-pie','-no-pie','-fno-stack-protector','-fno-vectorize','-fno-slp-vectorize','-O1','-Wl,-e,_start','-Wl,--build-id=none']
    if arch=='x86_64':flags+=['-mno-sse','-mno-sse2','-mno-mmx']
    if arch=='riscv64':flags+=['-mcpu=baseline_rv64-a-c-d-f-zca-zaamo-zalrsc','-mabi=lp64','-mno-relax']
    if arch=='aarch64':flags+=['-mgeneral-regs-only']
    for source in sorted((ROOT/'examples').glob('*.c')):
        if source.name.startswith(('windows','musl-')):continue
        subprocess.run(flags+[str(source),'-o',str(out/source.stem)],check=True,cwd=ROOT)
    if arch=='x86_64':subprocess.run(flags+[str(ROOT/'examples/hello-x86_64.S'),'-o',str(out/'hello-asm')],check=True,cwd=ROOT)
    print('Built',arch,flush=True)

for source in sorted((ROOT/'examples').glob('windows*.c')):
    target='hello.exe' if source.stem=='windows' else source.stem+'.exe'
    subprocess.run(["zig","cc","-target","x86_64-windows-gnu","-nostdlib","-ffreestanding","-fno-stack-protector","-mno-sse","-mno-sse2","-mno-mmx","-O1",str(source),"-lkernel32","-Wl,-e,mainCRTStartup","-o",str(ROOT/"artifacts"/target)],check=True,cwd=ROOT)
print('Built Windows PE32+ fixtures',flush=True)

subprocess.run(["zig","cc","-target","x86_64-linux-musl","-static","-O1",str(ROOT/"examples/musl-hello.c"),"-o",str(ROOT/"artifacts/musl-hello")],check=True,cwd=ROOT)
