#!/usr/bin/env python3
"""Build an optional static guest from unmodified, checksum-pinned SQLite source."""
import hashlib
import pathlib
import subprocess
import urllib.request
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION = '3.53.4'
PACKAGE = 'sqlite-amalgamation-3530400'
SHA3 = '628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e'
archive = ROOT / 'artifacts' / f'{PACKAGE}.zip'
archive.parent.mkdir(exist_ok=True)
if not archive.exists():
    urllib.request.urlretrieve(f'https://www.sqlite.org/2026/{PACKAGE}.zip', archive)
if hashlib.sha3_256(archive.read_bytes()).hexdigest() != SHA3:
    raise RuntimeError('SQLite source SHA3-256 mismatch')
with zipfile.ZipFile(archive) as source:
    for entry in source.infolist():
        path = pathlib.PurePosixPath(entry.filename)
        if path.is_absolute() or '..' in path.parts or path.parts[0] != PACKAGE:
            raise RuntimeError('Unexpected SQLite archive path')
    source.extractall(archive.parent)
source = archive.parent / PACKAGE
guest = archive.parent / 'sqlite-x86_64'
subprocess.run([
    'zig', 'cc', '-target', 'x86_64-linux-musl', '-static', '-O1',
    '-fno-vectorize', '-fno-slp-vectorize', '-fno-pie', '-no-pie',
    '-DSQLITE_THREADSAFE=0', '-DSQLITE_OMIT_LOAD_EXTENSION',
    str(source / 'shell.c'), str(source / 'sqlite3.c'), '-lm', '-o', str(guest),
], check=True, cwd=ROOT)
print(guest)
