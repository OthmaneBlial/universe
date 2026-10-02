#!/usr/bin/env python3
"""Fetch unchanged, checksum-pinned Debian guests into an optional private sysroot."""
import argparse
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
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--coreutils', action='store_true', help='Include GNU coreutils and its Debian support libraries')
args = parser.parse_args()
if args.coreutils:
    PACKAGES.update({
        'coreutils': ('pool/main/c/coreutils/coreutils_9.7-3_amd64.deb',
                      '1299ab6f9389a288eb2f5f3dd222c26cc777b9a2d5ecb6ee4cbd340cebcdada2'),
        'libacl1': ('pool/main/a/acl/libacl1_2.3.2-2+b1_amd64.deb',
                    '08074f01e384bc07c0c2d79a58cf4a6523f71cf75d1808101c79617656c9a39d'),
        'libattr1': ('pool/main/a/attr/libattr1_2.5.2-3_amd64.deb',
                     '606b5ee12ea2786be607a17f40c1fb5e65c76ceaff66665bdf8f8c6c1b71d1fb'),
        'libcap2': ('pool/main/libc/libcap2/libcap2_2.75-10+deb13u1+b3_amd64.deb',
                    '89fc4d34fc7a28ad6f0fcd0c561ab253b9dedf6f77f5a000b47c276c8295bf67'),
        'libgmp10': ('pool/main/g/gmp/libgmp10_6.3.0+dfsg-3_amd64.deb',
                     'd0d0265eb01770f17afd0f7c8c0622f80479dcfbbe13653a0debeec61464e622'),
        'libselinux1': ('pool/main/libs/libselinux/libselinux1_3.8.1-1_amd64.deb',
                        '68bb8d32bd8d6d7d2f5952a169db03d1484b46ae1e52abccdec42a19dccea5d5'),
        'libpcre2-8-0': ('pool/main/p/pcre2/libpcre2-8-0_10.46-1~deb13u2_amd64.deb',
                         '1252b96a5bc44bb5db982bef8eb18e54f5047cede2aff641bce4f8e1edb91c3e'),
        'libssl3t64': ('pool/main/o/openssl/libssl3t64_3.5.7-1~deb13u2_amd64.deb',
                       '916f7f40b34a06e6ebfaefcdab331bff458328411da672598f126a760472467d'),
        'libsystemd0': ('pool/main/s/systemd/libsystemd0_257.13-1~deb13u1_amd64.deb',
                        'ab0d4127b5e46e6f8c015a1db15a62ba9ae274cdefa150083adf90ada0600ea1'),
        'libzstd1': ('pool/main/libz/libzstd/libzstd1_1.5.7+dfsg-1_amd64.deb',
                     '2f6a2aeacfc925eba8b00ac9139bc4bfccf8cacb09eb93de067074b26948eef9'),
        'zlib1g': ('pool/main/z/zlib/zlib1g_1.3.dfsg+really1.3.1-1+b1_amd64.deb',
                   '015be740d6236ad114582dea500c1d907f29e16d6db00566ca32fb68d71ac90d'),
        'openssl-provider-legacy': ('pool/main/o/openssl/openssl-provider-legacy_3.5.7-1~deb13u2_amd64.deb',
                                    'f155c8191ae6d41da73d792f4182680aeafeb85c3dd223934ee9fdd115c4f1fa'),
    })
base = ROOT / ('artifacts/debian-coreutils-amd64' if args.coreutils else 'artifacts/debian-hello-amd64')
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
