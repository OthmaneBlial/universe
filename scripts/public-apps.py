#!/usr/bin/env python3
"""Download unchanged official releases for the optional application checks."""
import hashlib
import pathlib
import subprocess
import sys
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = ROOT / 'artifacts/public-apps'
APPS = {
    'jq': ('https://github.com/jqlang/jq/releases/download/jq-1.8.2/jq-linux-amd64',
           'b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f',
           None, 'b1c22172dd303f3be49e935aa56aa48a8b7a46e0bc838b4997d3bb451495870f'),
    'rg': ('https://github.com/BurntSushi/ripgrep/releases/download/15.2.0/ripgrep-15.2.0-x86_64-unknown-linux-musl.tar.gz',
           '33e15bcf1624b25cdd2a55813a47a2f95dbe126268203e76aa6a585d1e7b149c',
           'ripgrep-15.2.0-x86_64-unknown-linux-musl/rg',
           'e62198eb19b136b88c330af83647b5a962cb99b6b1f066758568f12de1974849'),
    '7zzs': ('https://github.com/ip7z/7zip/releases/download/26.03/7z2603-linux-x64.tar.xz',
             'dc99eff5008f1ab79bd7084c68513701547a808a89502bf4133683535ab3c695',
             '7zzs', 'eab4c8d7f193e3d6d3237370bbcaa879a160a3f1dc82202207e27baeab79b6ac'),
}
WINDOWS_7ZIP = ('https://github.com/ip7z/7zip/releases/download/26.03/7z2603-extra.7z',
                '191894e6acb3647ffb69ce630479ff318523b2e2b9890aa7f05c1127c2e59b8f',
                'x64/7za.exe', 'edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0')


def verify(data, expected, label):
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError(f'SHA-256 mismatch: {label}')


def download(url, digest):
    archive = BASE / pathlib.PurePosixPath(url).name
    if not archive.exists():
        with urllib.request.urlopen(url, timeout=30) as response:
            data = response.read()
        verify(data, digest, archive.name)
        archive.write_bytes(data)
    data = archive.read_bytes()
    verify(data, digest, archive.name)
    return archive, data


def main():
    BASE.mkdir(parents=True, exist_ok=True)
    for name, (url, digest, member, binary_digest) in APPS.items():
        archive, data = download(url, digest)
        if member:
            with tarfile.open(archive) as source:
                entry = source.getmember(member)
                if not entry.isfile():
                    raise RuntimeError(f'Expected regular executable: {member}')
                data = source.extractfile(entry).read()
        verify(data, binary_digest, name)
        target = BASE / name
        target.write_bytes(data)
        target.chmod(0o755)
        print(f'Verified official Linux release: {target}', flush=True)
    if '--windows' in sys.argv[1:]:
        url, digest, member, binary_digest = WINDOWS_7ZIP
        archive, _ = download(url, digest)
        target = BASE / '7za.exe'
        if target.exists():
            verify(target.read_bytes(), binary_digest, target.name)
        else:
            runtime = ROOT / 'zig-out/bin/universe'
            if not runtime.is_file():
                raise RuntimeError('Build UNIVERSE first: zig build -Doptimize=ReleaseSafe')
            print('Extracting the Windows release with Linux 7-Zip inside UNIVERSE (up to 5 minutes)…', flush=True)
            result = subprocess.run([str(runtime), '--allow-files', '--max-instructions', '1500000000',
                                     '--timeout-ms', '300000', str(BASE / '7zzs'),
                                     'x', '-mmt=off', '-so', str(archive), member],
                                    capture_output=True, timeout=310)
            if result.returncode:
                raise RuntimeError(f'Windows release extraction failed: {result.stderr.decode(errors="replace")}')
            verify(result.stdout, binary_digest, target.name)
            target.write_bytes(result.stdout)
        print(f'Verified official Windows release: {target}', flush=True)


if __name__ == '__main__':
    main()
