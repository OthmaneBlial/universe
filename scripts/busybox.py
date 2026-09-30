#!/usr/bin/env python3
"""Build an optional GPL-2.0 BusyBox guest from checksum-pinned upstream source.
Requires Python 3.12+, make and a native C compiler for upstream build tools.
No upstream code or guest binary is included in UNIVERSE releases.
"""
import hashlib, pathlib, subprocess, tarfile, urllib.request
ROOT=pathlib.Path(__file__).resolve().parents[1]
VERSION='1.37.0';SHA='3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4'
archive=ROOT/'artifacts'/f'busybox-{VERSION}.tar.bz2';archive.parent.mkdir(exist_ok=True)
if not archive.exists():urllib.request.urlretrieve(f'https://busybox.net/downloads/busybox-{VERSION}.tar.bz2',archive)
assert hashlib.sha256(archive.read_bytes()).hexdigest()==SHA,'BusyBox source checksum mismatch'
source=archive.parent/f'busybox-{VERSION}'
if not source.exists():
    with tarfile.open(archive) as tar:tar.extractall(archive.parent,filter='data')
log=archive.parent/'busybox-build.log'
def make(*args):
    with log.open('ab') as output:
        result=subprocess.run(['make',*args,'CC=zig cc -target x86_64-linux-musl','HOSTCC=cc','AR=zig ar','SKIP_STRIP=y'],cwd=source,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT)
    if result.returncode:raise RuntimeError(f'BusyBox build failed: see {log}')
make('allnoconfig')
config=source/'.config';text=config.read_text()
for key in ['BUSYBOX','STATIC','ECHO','CAT','LS']:text=text.replace('# CONFIG_'+key+' is not set','CONFIG_'+key+'=y')
text=text.replace('CONFIG_EXTRA_CFLAGS=""','CONFIG_EXTRA_CFLAGS="-O1 -fno-vectorize -fno-slp-vectorize -fno-pie"').replace('CONFIG_EXTRA_LDFLAGS=""','CONFIG_EXTRA_LDFLAGS="-no-pie"')
config.write_text(text)
# Remove upstream diagnostic-only options that Zig 0.16's linker rejects.
link=source/'scripts/trylink';text=link.read_text()
for flag in ['-Wl,--warn-common','-Wl,--verbose','-Wl,-Map,$EXE.map']:text=text.replace(flag,'')
link.write_text(text)
make('oldconfig');make('-j4')
print(source/'busybox')
