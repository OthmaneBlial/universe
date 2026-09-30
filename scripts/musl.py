#!/usr/bin/env python3
"""Build an optional dynamic x86-64 musl guest from checksum-pinned source.
Requires Python 3.12+, make, awk and Zig. No upstream code is bundled.
"""
import hashlib, pathlib, shutil, subprocess, tarfile, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = '1.2.5'
SHA = 'a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4'
artifacts = ROOT / 'artifacts'
artifacts.mkdir(exist_ok=True)
archive = artifacts / f'musl-{VERSION}.tar.gz'
if not archive.exists():
    urllib.request.urlretrieve(f'https://musl.libc.org/releases/musl-{VERSION}.tar.gz', archive)
if hashlib.sha256(archive.read_bytes()).hexdigest() != SHA:
    raise RuntimeError('musl source checksum mismatch')
source = artifacts / f'musl-{VERSION}'
if not source.exists():
    with tarfile.open(archive) as tar:
        tar.extractall(artifacts, filter='data')
log = artifacts / 'musl-build.log'
def build(args, cwd):
    with log.open('ab') as output:
        result = subprocess.run(args, cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=output, stderr=subprocess.STDOUT)
    if result.returncode:
        raise RuntimeError(f'musl guest build failed: see {log}')
build(['./configure', '--target=x86_64-linux-musl', '--prefix=/usr',
       'CC=zig cc -target x86_64-linux-musl', 'AR=zig ar', 'RANLIB=zig ranlib',
       'CFLAGS=-O1 -fno-vectorize -fno-slp-vectorize'], source)
build(['make', '-j4', 'lib/libc.so'], source)
sysroot = artifacts / 'musl-sysroot'
(sysroot / 'lib').mkdir(parents=True, exist_ok=True)
(sysroot / 'usr/lib').mkdir(parents=True, exist_ok=True)
shutil.copyfile(source / 'lib/libc.so', sysroot / 'lib/ld-musl-x86_64.so.1')
shutil.copyfile(source / 'COPYRIGHT', sysroot / 'COPYRIGHT.musl')
cc = ['zig', 'cc', '-target', 'x86_64-linux-musl', '-O1',
      '-fno-vectorize', '-fno-slp-vectorize']
build([*cc, '-shared', '-fPIC', 'examples/musl-library.c',
       '-Wl,-soname,libuniverse-probe.so', '-o',
       str(sysroot / 'usr/lib/libuniverse-probe.so')], ROOT)
for name, flags in [('musl-dynamic', []), ('musl-dynamic-pie', ['-fPIE', '-pie'])]:
    build([*cc, '-dynamic', *flags, 'examples/musl-dynamic.c',
           '-L' + str(sysroot / 'usr/lib'), '-luniverse-probe',
           '-Wl,-rpath,/usr/lib', '-o', str(artifacts / name)], ROOT)
print(f'Built musl {VERSION} interpreter, guest DSO, executable and PIE; sysroot: {sysroot}')
