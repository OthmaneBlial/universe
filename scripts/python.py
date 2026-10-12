#!/usr/bin/env python3
"""Fetch unchanged upstream CPython (musl, x86-64) into a pinned Alpine sysroot.
Requires Python 3.12+ for filtered tar extraction. No upstream code is bundled.
"""
import hashlib
import pathlib
import tarfile
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
BASE = ROOT / 'artifacts/python-x86_64'
ALPINE = ('https://dl-cdn.alpinelinux.org/alpine/v3.22/releases/x86_64/alpine-minirootfs-3.22.6-x86_64.tar.gz',
          '27694aaa55fd7a9e3ef596e0ad4eb66802308bb20172b17030cd5f4d8ae9bac2')
CPYTHON = ('https://github.com/astral-sh/python-build-standalone/releases/download/20261009/'
           'cpython-3.13.16%2B20261009-x86_64-unknown-linux-musl-install_only.tar.gz',
           '8f5665657484d4b7beeba48eb8a805f66212ec200c762614713072072f16d28d')


def fetch(url, expected):
    archive = BASE / pathlib.PurePosixPath(url).name.replace('%2B', '+')
    if not archive.exists():
        with urllib.request.urlopen(url, timeout=120) as response:
            data = response.read()
        if hashlib.sha256(data).hexdigest() != expected:
            raise RuntimeError(f'SHA-256 mismatch: {archive.name}')
        archive.write_bytes(data)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected:
        raise RuntimeError(f'SHA-256 mismatch: {archive.name}')
    return archive


def main():
    BASE.mkdir(parents=True, exist_ok=True)
    sysroot = BASE / 'sysroot'
    if not (sysroot / 'opt/python/bin/python3.13').is_file():
        with tarfile.open(fetch(*ALPINE)) as source:
            source.extractall(sysroot, filter='tar')  # busybox applets are absolute symlinks
        with tarfile.open(fetch(*CPYTHON)) as source:
            # Uppercase terminfo aliases collide with lowercase entries on case-insensitive macOS volumes;
            # keep every regular entry and only the aliases that do not shadow one.
            files = {m.name.casefold() for m in source.getmembers() if m.isfile()}
            seen = set()

            def portable(member, path):
                name = member.name.casefold()
                if '/share/terminfo/' in member.name and (name in seen or (member.issym() and name in files)):
                    return None
                seen.add(name)
                return tarfile.data_filter(member, path)
            source.extractall(sysroot / 'opt', filter=portable)
        # ncurses in the guest searches /usr/share/terminfo; Python's full REPL needs it.
        (sysroot / 'usr/share/terminfo').symlink_to('/opt/python/share/terminfo')
    print(f'Verified Alpine 3.22.6 + CPython 3.13.16 sysroot: {sysroot}', flush=True)


if __name__ == '__main__':
    main()
