#!/usr/bin/env python3
"""Build guest ELF fixtures from checked-in source using Zig's cross C compiler."""
import pathlib, subprocess, argparse, re
ROOT=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--arch', choices=['x86_64','riscv64','aarch64','all'],default='all');args=p.parse_args()
for arch in (['x86_64','riscv64','aarch64'] if args.arch=='all' else [args.arch]):
    out=ROOT/'artifacts'/'guests'/arch;out.mkdir(parents=True,exist_ok=True)
    flags=['zig','cc','-target',arch+'-linux-musl','-nostdlib','-ffreestanding','-static','-fno-pie','-no-pie','-fno-stack-protector','-fno-vectorize','-fno-slp-vectorize','-O1','-Wl,-e,_start','-Wl,--build-id=none']
    if arch=='x86_64':flags+=['-mno-sse','-mno-sse2','-mno-mmx']
    if arch=='riscv64':flags+=['-mcpu=baseline_rv64-a-c-d-f-zca-zaamo-zalrsc','-mabi=lp64','-mno-relax']
    if arch=='aarch64':flags+=['-mgeneral-regs-only']
    for source in sorted((ROOT/'examples').glob('*.c')):
        if source.name.startswith(('windows','musl-','macos-','riscv-')) or source.name in ('x86-sse2.c','x86-sse2-multiply.c','x86-sse2-shift.c','x86-sse2-pack.c','x86-ssse3.c','x86-sse41.c','x86-sse-fp.c','x86-popcnt.c','x86-bswap.c','x86-sse42-crc32.c','x86-baseline.c','x86-mxcsr.c','x87.c','x87-arithmetic.c'):continue
        subprocess.run(flags+[str(source),'-o',str(out/source.stem)],check=True,cwd=ROOT)
    pie_flags=[flag for flag in flags if flag not in ['-fno-pie','-no-pie']]
    subprocess.run(pie_flags+['-fPIE','-pie',str(ROOT/'examples/hello.c'),'-o',str(out/'hello-pie')],check=True,cwd=ROOT)
    if arch=='riscv64':
        fp_flags=[flag for flag in flags if flag!='-mabi=lp64' and not flag.startswith('-mcpu=')]+['-mcpu=baseline_rv64+f+d+c+zicsr','-mabi=lp64d']
        subprocess.run(fp_flags+[str(ROOT/'examples/riscv-fp.S'),'-o',str(out/'floating')],check=True,cwd=ROOT)
        compressed=out/'compressed';compressed.mkdir(exist_ok=True)
        c_flags=[flag for flag in flags if not flag.startswith('-mcpu=')]+['-mcpu=baseline_rv64-a-d-f-zaamo-zalrsc']
        for source in sorted((ROOT/'examples').glob('*.c')):
            if source.name.startswith(('windows','musl-','macos-','riscv-')) or source.name in ('x86-sse2.c','x86-sse2-multiply.c','x86-sse2-shift.c','x86-sse2-pack.c','x86-ssse3.c','x86-sse41.c','x86-sse-fp.c','x86-popcnt.c','x86-bswap.c','x86-sse42-crc32.c','x86-baseline.c','x86-mxcsr.c','x87.c','x87-arithmetic.c'):continue
            subprocess.run(c_flags+[str(source),'-o',str(compressed/source.stem)],check=True,cwd=ROOT)
        c_pie=[flag for flag in c_flags if flag not in ['-fno-pie','-no-pie']]
        subprocess.run(c_pie+['-fPIE','-pie',str(ROOT/'examples/hello.c'),'-o',str(compressed/'hello-pie')],check=True,cwd=ROOT)
        atomic_flags=[flag for flag in flags if not flag.startswith('-mcpu=')]+['-mcpu=baseline_rv64-d-f']
        subprocess.run(atomic_flags+[str(ROOT/'examples/riscv-atomics.c'),'-o',str(out/'atomics')],check=True,cwd=ROOT)
    if arch=='x86_64':
        subprocess.run(flags+[str(ROOT/'examples/hello-x86_64.S'),'-o',str(out/'hello-asm')],check=True,cwd=ROOT)
        simd_flags=[flag for flag in flags if flag not in ['-mno-sse','-mno-sse2','-mno-mmx']]
        subprocess.run(simd_flags+['-mcpu=baseline+sse+sse2',str(ROOT/'examples/x86-sse2.c'),'-o',str(out/'sse2-arithmetic')],check=True,cwd=ROOT)
        subprocess.run(simd_flags+['-mcpu=baseline+sse+sse2',str(ROOT/'examples/x86-sse2-multiply.c'),'-o',str(out/'sse2-multiply')],check=True,cwd=ROOT)
        subprocess.run(simd_flags+['-mcpu=baseline+sse+sse2',str(ROOT/'examples/x86-sse2-shift.c'),'-o',str(out/'sse2-shift')],check=True,cwd=ROOT)
        subprocess.run(simd_flags+['-mcpu=baseline+sse+sse2',str(ROOT/'examples/x86-sse2-pack.c'),'-o',str(out/'sse2-pack')],check=True,cwd=ROOT)
        subprocess.run(simd_flags+['-mcpu=baseline+sse+sse2+ssse3',str(ROOT/'examples/x86-ssse3.c'),'-o',str(out/'ssse3-shuffle')],check=True,cwd=ROOT)
        subprocess.run(simd_flags+['-mcpu=baseline+sse+sse2+ssse3+sse4_1',str(ROOT/'examples/x86-sse41.c'),'-o',str(out/'sse4.1-integer')],check=True,cwd=ROOT)
        subprocess.run(simd_flags+['-msse4.2',str(ROOT/'examples/x86-sse42-crc32.c'),'-o',str(out/'sse4.2-crc32c')],check=True,cwd=ROOT)
        subprocess.run(simd_flags+['-mcpu=baseline+sse+sse2',str(ROOT/'examples/x86-sse-fp.c'),'-o',str(out/'sse-fp')],check=True,cwd=ROOT)
        subprocess.run(simd_flags+['-msse4.1',str(ROOT/'examples/x86-mxcsr.c'),'-o',str(out/'mxcsr')],check=True,cwd=ROOT)
        subprocess.run(flags+[str(ROOT/'examples/x87.c'),'-o',str(out/'x87')],check=True,cwd=ROOT)
        subprocess.run(flags+['-mno-red-zone',str(ROOT/'examples/x87-arithmetic.c'),'-o',str(out/'x87-arithmetic')],check=True,cwd=ROOT)
        subprocess.run(simd_flags+['-mmmx',str(ROOT/'examples/x86-baseline.c'),'-o',str(out/'baseline')],check=True,cwd=ROOT)
        subprocess.run(simd_flags+['-mpopcnt',str(ROOT/'examples/x86-popcnt.c'),'-o',str(out/'popcnt')],check=True,cwd=ROOT)
        subprocess.run(simd_flags+[str(ROOT/'examples/x86-bswap.c'),'-o',str(out/'bswap')],check=True,cwd=ROOT)
    if arch=='aarch64':
        neon_flags=[flag for flag in flags if flag!='-mgeneral-regs-only']
        subprocess.run(neon_flags+[str(ROOT/'examples/aarch64-neon.S'),'-o',str(out/'neon-arithmetic')],check=True,cwd=ROOT)
    print('Built',arch,flush=True)

windows_flags=["zig","cc","-target","x86_64-windows-gnu","-nostdlib","-ffreestanding","-fno-stack-protector","-mno-sse","-mno-sse2","-mno-mmx","-O1"]
# -nostdlib omits Zig's Windows headers as well as the CRT. Use declarations only.
zig_lib=pathlib.Path(re.search(r'\.lib_dir = "([^"]+)"',subprocess.check_output(['zig','env'],text=True)).group(1))
automation_flags=['-isystem',str(zig_lib/'libc/include/any-windows-any')]
windows_root=ROOT/'artifacts/windows-sysroot';windows_root.mkdir(parents=True,exist_ok=True)
for name in ['windows-helper','windows-probe','windows-late','windows-tls']:
    definition=[str(ROOT/'examples/windows-probe.def')] if name=='windows-probe' else []
    subprocess.run([*windows_flags,'-shared',str(ROOT/'examples'/f'{name}.dll.c'),*definition,'-L'+str(windows_root),*(['-lwindows-helper'] if definition else []),'-lkernel32','-Wl,-e,DllMain','-Wl,--image-base,0x180000000','-Wl,--out-implib,'+str(windows_root/f'lib{name}.a'),'-o',str(windows_root/f'{name}.dll')],check=True,cwd=ROOT)
for alias in ['宇宙🚀.dll','bare']:(windows_root/alias).write_bytes((windows_root/'windows-helper.dll').read_bytes())
for name,defines,dependency in [('windows-cycle-a',['-DCYCLE_A','-DCYCLE_BOOTSTRAP'],None),('windows-cycle-b',[],'windows-cycle-a'),('windows-cycle-a',['-DCYCLE_A'],'windows-cycle-b')]:
    definition=[str(ROOT/'examples/windows-cycle-a.def')] if name=='windows-cycle-a' else []
    subprocess.run([*windows_flags,'-shared',*defines,str(ROOT/'examples/windows-cycle.dll.c'),*definition,'-L'+str(windows_root),*(['-l'+dependency] if dependency else []),'-Wl,-e,DllMain','-Wl,--image-base,0x180000000','-Wl,--out-implib,'+str(windows_root/f'lib{name}.a'),'-o',str(windows_root/f'{name}.dll')],check=True,cwd=ROOT)
for source in sorted((ROOT/'examples').glob('windows*.c')):
    if source.name.endswith('.dll.c'):continue
    target='hello.exe' if source.stem=='windows' else source.stem+'.exe'
    dll_flags=[]
    if source.stem=='windows-dll':dll_flags=['-L'+str(windows_root),'-lwindows-probe','-Wl,--image-base,0x180000000']
    if source.stem in ('windows-tls','windows-tls-dynamic'):dll_flags=['-L'+str(windows_root),'-lwindows-tls']
    if source.stem=='windows-automation':dll_flags=[*automation_flags,'-loleaut32']
    if source.stem=='windows-text':dll_flags=[*automation_flags,'-luser32']
    subprocess.run([*windows_flags,str(source),*dll_flags,"-lkernel32","-Wl,-e,mainCRTStartup","-o",str(ROOT/"artifacts"/target)],check=True,cwd=ROOT)
ordinal_lib=windows_root/'liboleaut32-ordinal.a'
subprocess.run(['zig','dlltool','-m','i386:x86-64','-d',str(ROOT/'examples/windows-oleaut32.def'),'-l',str(ordinal_lib)],check=True,cwd=ROOT)
subprocess.run([*windows_flags,*automation_flags,str(ROOT/'examples/windows-automation.c'),str(ordinal_lib),'-lkernel32','-Wl,-e,mainCRTStartup','-o',str(ROOT/'artifacts/windows-automation-ordinal.exe')],check=True,cwd=ROOT)
print('Built Windows PE32+ fixtures',flush=True)

subprocess.run(["zig","cc","-target","x86_64-linux-musl","-static","-O1",str(ROOT/"examples/musl-hello.c"),"-o",str(ROOT/"artifacts/musl-hello")],check=True,cwd=ROOT)
