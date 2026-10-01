#!/usr/bin/env python3
"""Download unchanged official Linux releases for the optional application check."""
import hashlib
import pathlib
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
}


def verify(data, expected, label):
    if hashlib.sha256(data).hexdigest() != expected:
        raise RuntimeError(f'SHA-256 mismatch: {label}')


def main():
    BASE.mkdir(parents=True, exist_ok=True)
    for name, (url, digest, member, binary_digest) in APPS.items():
        archive = BASE / pathlib.PurePosixPath(url).name
        if not archive.exists():
            with urllib.request.urlopen(url, timeout=30) as response:
                data = response.read()
            verify(data, digest, archive.name)
            archive.write_bytes(data)
        data = archive.read_bytes()
        verify(data, digest, archive.name)
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


if __name__ == '__main__':
    main()
