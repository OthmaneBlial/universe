#!/usr/bin/env python3
"""Build library-free Mach-O guests with Apple's installed command-line toolchain."""
import pathlib,platform,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
if platform.system()!='Darwin':raise SystemExit('Mach-O fixture builds require macOS and Apple clang/ld')
for arch,target in [('x86_64','x86_64-apple-macos11'),('aarch64','arm64-apple-macos11')]:
    out=ROOT/'artifacts/macos'/arch;out.mkdir(parents=True,exist_ok=True)
    flags=['clang','-target',target,'-nostdlib','-static','-ffreestanding','-fno-stack-protector','-fno-vectorize','-fno-slp-vectorize','-O1','-Wl,-e,_start']
    flags+=['-mno-sse','-mno-sse2','-mno-mmx'] if arch=='x86_64' else ['-mgeneral-regs-only']
    for source in sorted((ROOT/'examples').glob('macos-*.c')):
        subprocess.run([*flags,str(source),'-o',str(out/source.stem.removeprefix('macos-'))],check=True,cwd=ROOT)
        matching={'arm64':'aarch64','x86_64':'x86_64'}.get(platform.machine())==arch
        if matching and source.stem!='macos-arguments':
            native=[flag for flag in flags if flag not in ['-nostdlib','-static','-Wl,-e,_start']]
            subprocess.run([*native,'-DMACOS_NATIVE_REFERENCE',str(source),'-o',str(out/(source.stem.removeprefix('macos-')+'-native'))],check=True,cwd=ROOT)
    print('Built library-free Mach-O',arch,flush=True)
