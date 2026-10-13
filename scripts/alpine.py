#!/usr/bin/env python3
"""Fetch unchanged Alpine 3.22 x86-64 packages (git, vim, lua, htop; --gcc adds GCC) into a pinned sysroot.
Requires Python 3.12+. Packages are extracted, never executed on the host; no upstream code is bundled.
"""
import argparse
import gzip
import hashlib
import io
import pathlib
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = ROOT / 'artifacts/alpine-x86_64'
MIRROR = 'https://dl-cdn.alpinelinux.org/alpine/v3.22'
MINIROOTFS = ('releases/x86_64/alpine-minirootfs-3.22.6-x86_64.tar.gz',
              '27694aaa55fd7a9e3ef596e0ad4eb66802308bb20172b17030cd5f4d8ae9bac2')
# git, vim, lua5.4 and htop with their complete runtime dependency closure from the v3.22 main APKINDEX.
PACKAGES = [
    ('brotli-libs-1.1.0-r2', 'a693524543421b3a90f163ccb48d5ad0f5fd773b5c3b640acc461eace2cb01b6'),
    ('c-ares-1.34.8-r0', '1397ec9682ff6153e5d037965c76408e570ae6535ce479cc2af37436fdea52ce'),
    ('ca-certificates-bundle-20260909-r0', '9cbf2fd3bcbad4a73d6e2c5a2d5cfea176ce01790d8ae8bb1796ba4e64d6c48b'),
    ('git-2.49.1-r0', '42f4573799ffce0c7dd4954d2247eb882eb87360dc18637930624484ecfd1c90'),
    ('libcrypto3-3.5.9-r0', '3f5825ced5fde1c66a5376a3f6076b3c08538ad52d9ef23f069857e212d9175a'),
    ('libcurl-8.14.1-r3', '249e5a3a50558cdb3ce1bab1619b15d88243a628d878700c8d05878c2e71ed71'),
    ('libexpat-2.8.5-r0', '771c18e6f7891a503a4664cfc09a3c4fb35a9b2fd2d4a643caf7206b792f5444'),
    ('libidn2-2.3.7-r0', '515cfe061176c7456ea3548651d0014084d77dd3774b78e2c944404ae75a41ff'),
    ('libpsl-0.21.5-r3', '1e79da4fa1364b7153b8950a363a6de0bef1d1b48d46fcb3b850cd4f233727b2'),
    ('libssl3-3.5.9-r0', '6801c740b9760b5b08da8db6367ebc18b2cc4dbaf371f7148429538b8bb04e23'),
    ('libunistring-1.3-r0', '989640e58f7646c0495c3950df36eb7b4df152d8150c2c888f8ab954fed8c908'),
    ('nghttp2-libs-1.69.0-r0', 'd6ee515d30d703e94b55ef9c0a02aea053313f654acbd2c655d18e3907ecb66a'),
    ('pcre2-10.46-r0', 'cfb8ad103a101fa6a31769e50e188dab9c60124705682d01b3de268795db58ad'),
    ('zlib-1.3.2-r1', 'af24e502645e2b392cae833856d776691ac21655362e5db69d7b89f147f76216'),
    ('zstd-libs-1.5.7-r0', '1bdd6e57cfbfbfd6e8481cad37ddd5d199950715bec1879b3afb600272dbb09e'),
    ('htop-3.4.1-r1', '158e8e3d7802f86e2d35c8333d722adeef2a92e4bd353aa36a4cb3f29265dfbd'),
    ('libncursesw-6.5_p20250503-r0', 'aeafdfca68147b014705b4e2564639ade6345198debb522f2c6c51d32e417651'),
    ('lua5.4-5.4.7-r0', '130a2726f461f90661176452b42ad28b6fada86af78da13aeef5ded591964d6a'),
    ('lua5.4-libs-5.4.7-r0', '2788121cf38d6b1869974e26cc337d9ffc207a6e74cb8866d96444ded05705c7'),
    ('ncurses-terminfo-base-6.5_p20250503-r0', '0815a5f0403974bb9c34d456e71dc9c0222cb5455d393bc63c44b573da3d7fe0'),
    ('readline-8.2.13-r1', '520fa586c689144928191bee13e2c85ff4e170ad87d1471ec48e3e97611673d8'),
    ('vim-9.1.1566-r0', '5f14f201bbdd14efca1d0dc15088464e7bc89356a73fdc18d476c35ab21d78ad'),
    ('vim-common-9.1.1566-r0', '3ad4854dc45d5eef0cf8eff8d49caa8f3198e7e611d422ad1279b1ed3bba747b'),
    ('xxd-9.1.1566-r0', '6e8e2cb25b4d858b09ce17f5ec6c43d347e3eeeb1cc35ffc1c7cd4df8a0ac92b'),
]
# Optional GCC 14.2 toolchain (about 60 MiB): gcc, binutils, musl-dev and their libraries.
GCC = [
    ('binutils-2.44-r3', 'd12005fc43aa4e818ce240dcdd5ae90a42a5a4b3ea6937800c7b0a5b877190aa'),
    ('gcc-14.2.0-r6', '4fd10bd05784f596e5ff0adc724a94b71380fac0ac276bd257dd861e8b5822e6'),
    ('gmp-6.3.0-r3', 'd3f987ae3836ac7774324bff443dd49d03b846209660729d0c30dfff5546e138'),
    ('isl26-0.26-r1', 'ecd11e4446097ff62b49e6ab8f552b438a304634a8f8e2db713fcbbe62f04c61'),
    ('jansson-2.14.1-r0', '7fde81421482507163410715a7ef7d7df6a091870edab855c24e8f6fc84e3e2d'),
    ('libatomic-14.2.0-r6', 'e9a884f8a63f614b722dd5191ede154a6b6b81d99457af610bc6f544a6d2d7bc'),
    ('libgcc-14.2.0-r6', '04f3467bc967e705221a843fe4d3de5850db826e571686e0c0ed453d38cb5c59'),
    ('libgomp-14.2.0-r6', '026e5c9d0bab7e82c42fa11b96ed95e66d2549bd5de5c869c18a3600c2e3aa02'),
    ('libstdc++-14.2.0-r6', '939f7c99898f3e8154207a17f4acbe8bc40437e1bb1b43f5525620ca9e452a2e'),
    ('mpc1-1.3.1-r1', 'bfc0d8bd7e3b8de2fdfcf4977437281e58147cc568194cb82ba887bd190376e6'),
    ('mpfr4-4.2.1_p1-r0', '33f2f274333164dfc25a0002ca58bb99f6d26843d5486c03e3fa207e5432ac59'),
    ('musl-dev-1.2.5-r12', '1c2068d910cfdbbcb4eb107a5a478f8b48edf3a6311953c8fa5180c5190efab3'),
]


def fetch(path, expected):
    archive = BASE / pathlib.PurePosixPath(path).name
    if not archive.exists():
        with urllib.request.urlopen(f'{MIRROR}/{path}', timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != expected:
            raise RuntimeError(f'SHA-256 mismatch: {archive.name}')
        archive.write_bytes(data)
    data = archive.read_bytes()
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError(f'SHA-256 mismatch: {archive.name}')
    return data


def inside(sysroot, name):
    """Resolve a member's parent directories as under chroot, so absolute links never reach the host."""
    parts, resolved, hops = list(pathlib.PurePosixPath(name).parts), [], 0
    while len(parts) > 1:
        part = parts.pop(0)
        if part == '..':
            resolved = resolved[:-1]
            continue
        candidate = sysroot.joinpath(*resolved, part)
        if candidate.is_symlink():
            hops += 1
            if hops > 40:
                raise RuntimeError(f'Symlink loop: {name}')
            target = pathlib.PurePosixPath(candidate.readlink())
            if target.is_absolute():
                resolved = []
            parts = [p for p in target.parts if p != '/'] + parts
            continue
        if part not in ('', '.'):
            resolved.append(part)
    return '/'.join(resolved + parts)


def place(sysroot, member, path):
    member = member.replace(name=inside(sysroot, member.name))
    target = sysroot / member.name
    if target.is_symlink() and not member.isdir():
        target.unlink()  # Replaced by this package; never follow an old absolute link to the host.
    return tarfile.tar_filter(member, path)


def extract(sysroot, name, digest):
    # An .apk is concatenated gzip tar segments: signature, metadata, then files.
    data = gzip.decompress(fetch(f'main/x86_64/{name}.apk', digest))
    with tarfile.open(fileobj=io.BytesIO(data), ignore_zeros=True) as source:
        members = [m for m in source.getmembers() if not m.name.startswith('.')]
        source.extractall(sysroot, members=members, filter=lambda m, path: place(sysroot, m, path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gcc', action='store_true', help='also install the GCC 14.2 toolchain (about 60 MiB)')
    args = parser.parse_args()
    BASE.mkdir(parents=True, exist_ok=True)
    sysroot = BASE / 'sysroot'
    if not all((sysroot / tool).is_file() for tool in ('usr/bin/git', 'usr/bin/vim', 'usr/bin/lua5.4', 'usr/bin/htop')):
        # Alpine's BusyBox applets and library links are absolute symlinks, resolved inside the sysroot.
        with tarfile.open(fileobj=io.BytesIO(fetch(*MINIROOTFS))) as source:
            source.extractall(sysroot, filter='tar')
        for name, digest in PACKAGES:
            extract(sysroot, name, digest)
    if args.gcc and not (sysroot / 'usr/bin/gcc').is_file():
        for name, digest in GCC:
            extract(sysroot, name, digest)
    tools = 'git, vim, lua5.4, htop' + (' and GCC 14.2' if (sysroot / 'usr/bin/gcc').is_file() else '')
    print(f'Verified Alpine 3.22.6 sysroot with {tools}: {sysroot}', flush=True)


if __name__ == '__main__':
    main()
