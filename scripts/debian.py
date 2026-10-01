#!/usr/bin/env python3
"""Fetch unchanged, checksum-pinned Debian guests into an optional private sysroot."""
import hashlib
import io
import pathlib
import subprocess
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
PACKAGES = {
    'libc6': ('pool/main/g/glibc/libc6_2.41-12+deb13u4_amd64.deb',
              '967aa62605721081c3eb2a17650611a792aa802d76a6511d1840242623d204c9'),
    'hello': ('pool/main/h/hello/hello_2.10-5_amd64.deb',
              '4536aabbb75ec21ffe161099ee4b97274945770bdb0682e25ec322421211ca5e'),
    'libgcc-s1': ('pool/main/g/gcc-14/libgcc-s1_14.2.0-19_amd64.deb',
                  '3c71917b490d1a17aed43196a2787a256ecf060526cdb20216a74bedc061b150'),
}
base = ROOT / 'artifacts/debian-hello-amd64'
sysroot = base / 'sysroot'
sysroot.mkdir(parents=True, exist_ok=True)
for name in PACKAGES:
    package, expected = PACKAGES[name]
    archive = base / pathlib.PurePosixPath(package).name
    if archive.exists():
        data = archive.read_bytes()
    else:
        with urllib.request.urlopen('https://deb.debian.org/debian/' + package, timeout=60) as response:
            data = response.read()
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError(f'Debian SHA-256 mismatch: {name}')
    if not archive.exists():
        archive.write_bytes(data)
    members = subprocess.check_output(['ar', 't', str(archive)], text=True).splitlines()
    payloads = [member for member in members if member.startswith('data.tar.')]
    if len(payloads) != 1:
        raise RuntimeError(f'Unexpected Debian archive: {name}')
    payload = subprocess.check_output(['ar', 'p', str(archive), payloads[0]])
    with tarfile.open(fileobj=io.BytesIO(payload)) as source:
        source.extractall(sysroot, filter='data')
    print(f'Verified and extracted {archive.name}', flush=True)
# Debian's merged-/usr filesystem aliases, contained within this private sysroot.
for name in ['lib', 'lib64']:
    alias = sysroot / name
    if not alias.exists() and not alias.is_symlink():
        alias.symlink_to('usr/' + name)
print(sysroot)
