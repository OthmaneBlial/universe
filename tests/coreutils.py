#!/usr/bin/env python3
"""Unchanged Debian coreutils workflows; run scripts/debian.py --coreutils first."""
import base64
import datetime
import hashlib
import os
import pathlib
import platform
import stat
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'zig-out/bin/universe'
SYSROOT = ROOT / 'artifacts/debian-coreutils-amd64/sysroot'
for name, expected in {
    'usr/bin/printf': 'e7c954d7c89a494227b35c537a0a42fe315b4ea687b90a90b3eeee06c52927dd',
    'usr/bin/cat': '8a5c20c3400a4058a487cd806111cc5138ef4d0fbc6714ff67c9432e38c2705a',
    'usr/bin/sort': '4bf4f14424fa481b1f40d28534b0c5c7a7d07affcb82c805b07255cc4c2034be',
    'usr/bin/wc': 'e8fe45a85ebdb0dade6dabf96f21dfd686c6414ff2a4a8980727076a5981d2af',
    'usr/bin/head': 'd75b123e441ed3bd503eb3dc45b716c861fcbf5c2228ac302a50bc45f6346f6b',
    'usr/bin/base64': 'd366e0e50248ffe77018b327e0af70707dfdcb8616a6f1f088535f17d677dcc6',
    'usr/bin/sleep': '0637e6d47579929cb72efa46f361861b319d62c62fe8a9d10731fd7655eb5936',
    'usr/bin/sha256sum': '89f8c1d1ba3c76138f3771e1a91e2796ade6180b1c1e4258c04698ff32787c97',
    'usr/bin/ls': '833d6f9cf3ede2225d80eaa159ef78a141c92842a691179aec37d182cc808a5c',
    'usr/bin/stat': '128754b37ab743a539d889a91441c440f9b52df77f4e008b345ff221ce1daeaa',
    'usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2': 'c8438e4fde1934e61c88311633f00949ff645d5c04cdb8671fa3d78164d2f307',
    'usr/lib/x86_64-linux-gnu/libc.so.6': '9792e3cbb541c8f44c7acf5f14f4022ea62998ecc787d326bed4d8b6547dfd92',
    'usr/lib/x86_64-linux-gnu/libcrypto.so.3': '8bb5f3fdffe280d4453eb79a4663c2c47af70b7c247fe2e94e2da703cee1fd3d',
    'usr/lib/x86_64-linux-gnu/libzstd.so.1': '27f07c9a49c2c956bcfb64cd4712976586a66facbf15fc7f09bc37413b5f2b21',
    'usr/lib/x86_64-linux-gnu/libz.so.1': '85590dd58edf5445e18bc7193e5ebc01ac5841f1ae187e97705a662e90c6421e',
}.items():
    assert hashlib.sha256((SYSROOT / name).read_bytes()).hexdigest() == expected, name
checks = 0
modes = [[]] + ([['--jit']] if platform.machine() in ['arm64', 'aarch64'] else [])
data = bytes(range(256)) * 129 + b'last line\n'
with tempfile.TemporaryDirectory(prefix='checks-', dir=SYSROOT) as temporary:
    work = pathlib.Path(temporary)
    guest_work = '/' + work.name
    (work / 'binary').write_bytes(data)
    (work / 'first').write_bytes(b'z\na\n')
    (work / 'second').write_bytes(b'b\na\n')
    (work / 'first-link').symlink_to('first')
    digest = hashlib.sha256(data).hexdigest().encode()
    manifest = digest + b'  ' + (guest_work + '/binary').encode() + b'\n'
    (work / 'sums').write_bytes(manifest)
    (work / 'bad-sums').write_bytes(b'0' * 64 + manifest[64:])
    for mode in modes:
        def run(name, args=(), input=b'', output=b'', code=0, error=b''):
            global checks
            command = [str(RUNTIME), *mode, '--env', 'LC_ALL=C', '--env', 'TZ=UTC', '--allow-files',
                       '--sysroot', str(SYSROOT), str(SYSROOT / 'usr/bin' / name), *args]
            value = subprocess.run(command, input=input, capture_output=True, timeout=30)
            assert (value.returncode, value.stdout) == (code, output), (mode, name, args, value)
            assert error in value.stderr if error else not value.stderr, (mode, name, args, value.stderr)
            assert b'UNIVERSE FAULT' not in value.stderr and not value.stderr.startswith(b'UNIVERSE:'), value.stderr
            checks += 1

        run('printf', ['%s:%04d\n', 'hello', '42'], output=b'hello:0042\n')
        run('printf', ['%x %o %.3f\n', '255', '8', '1.25'], output=b'ff 10 1.250\n')
        run('printf', ['\\x00\\377\\n'], output=b'\0\xff\n')
        run('cat', input=b'alpha\nbeta\n', output=b'alpha\nbeta\n')
        run('cat', input=data, output=data)
        run('cat', [guest_work + '/binary'], output=data)
        run('cat', [guest_work + '/first', guest_work + '/second'], output=b'z\na\nb\na\n')
        run('cat', ['-n'], input=b'one\n\ntwo\n', output=b'     1\tone\n     2\t\n     3\ttwo\n')
        run('cat', ['-s'], input=b'a\n\n\n\nb\n', output=b'a\n\nb\n')
        run('sort', input=b'z\na\nz\nb\n', output=b'a\nb\nz\nz\n')
        run('sort', ['-u'], input=b'z\na\nz\nb\n', output=b'a\nb\nz\n')
        run('sort', ['-n'], input=b'10\n-2\n3\n0\n', output=b'-2\n0\n3\n10\n')
        run('sort', ['-r'], input=b'a\nz\nb\n', output=b'z\nb\na\n')
        run('sort', ['-z'], input=b'z\0a\0b\0', output=b'a\0b\0z\0')
        run('sort', [guest_work + '/first', guest_work + '/second'], output=b'a\na\nb\nz\n')
        lines = [f'{n % 37:03d}\n'.encode() for n in range(2000, -1, -1)]
        run('sort', input=b''.join(lines), output=b''.join(sorted(lines)))
        run('wc', ['-l'], input=b'alpha\nbeta\nlast', output=b'2\n')
        run('wc', ['-c'], input=data, output=str(len(data)).encode() + b'\n')
        run('wc', ['-w'], input=b'one two\nthree\t four', output=b'4\n')
        run('wc', ['-L'], input=b'a\nabcdef\nxy', output=b'6\n')
        run('wc', ['-c', guest_work + '/binary'], output=str(len(data)).encode() + b' ' + (guest_work + '/binary').encode() + b'\n')
        run('head', ['-n', '2'], input=b'a\nb\nc\n', output=b'a\nb\n')
        run('head', ['-c', '257'], input=data, output=data[:257])
        run('head', ['-n', '-2'], input=b'a\nb\nc\nd\n', output=b'a\nb\n')
        run('head', ['-c', '257', guest_work + '/binary'], output=data[:257])
        run('head', ['-n', '2'])
        run('base64', input=data, output=base64.encodebytes(data))
        run('base64', ['-w', '0'], input=data, output=base64.b64encode(data))
        run('base64', ['-d'], input=base64.encodebytes(data), output=data)
        run('base64', ['-d'], input=b'!!!', code=1, error=b'invalid input')
        run('sleep', ['0'])
        run('sleep', ['0.001'])
        run('sleep', ['0.001s', '0.001s'])
        run('sleep', ['invalid'], code=1, error=b'invalid time interval')
        run('sha256sum', input=data, output=digest + b'  -\n')
        run('sha256sum', [guest_work + '/binary'], output=manifest)
        run('sha256sum', ['-c', '--status', guest_work + '/sums'])
        run('sha256sum', ['-c', '--status', guest_work + '/bad-sums'], code=1)
        names = sorted(entry.name for entry in work.iterdir())
        run('ls', ['-1', '--color=never', guest_work], output=('\n'.join(names) + '\n').encode())
        run('ls', ['-1a', '--color=never', guest_work], output=('\n'.join(['.', '..', *names]) + '\n').encode())
        run('ls', ['-1', '--color=never', guest_work + '/binary'], output=(guest_work + '/binary\n').encode())
        os.chmod(work / 'binary', 0o640)
        os.utime(work / 'binary', (1577934245, 1577934245))
        listed = (work / 'binary').stat()
        date = datetime.datetime.fromtimestamp(listed.st_mtime, datetime.timezone.utc).strftime('%Y-%m-%d %H:%M:%S')
        long_line = f'{stat.filemode(listed.st_mode)} {listed.st_nlink} {listed.st_uid} {listed.st_gid} {listed.st_size} {date} {guest_work}/binary\n'
        run('ls', ['-ldn', '--time-style=+%Y-%m-%d %H:%M:%S', guest_work + '/binary'], output=long_line.encode())
        native = (work / 'binary').stat()
        run('stat', ['-c', '%s %i %a %F', guest_work + '/binary'],
            output=f'{native.st_size} {native.st_ino} {stat.S_IMODE(native.st_mode):o} regular file\n'.encode())
        run('stat', ['-c', '%s %F', guest_work + '/first-link'], output=b'5 symbolic link\n')
        run('stat', ['-L', '-c', '%s %F', guest_work + '/first-link'], output=b'4 regular file\n')
        volume = os.statvfs(work)
        run('stat', ['-f', '-c', '%S %l', guest_work + '/binary'],
            output=f'{volume.f_frsize} {volume.f_namemax}\n'.encode())
        denied = subprocess.run([str(RUNTIME), *mode, '--sysroot', str(SYSROOT),
                                 str(SYSROOT / 'usr/bin/cat')], capture_output=True, timeout=20)
        assert denied.returncode == 125 and not denied.stdout and denied.stderr == b'UNIVERSE: FileAccessDenied\n', denied
        checks += 1
print(f'Debian coreutils: {checks}/{checks} unchanged application checks passed; bytes, files, sorting, counting, base64, sleeps, SHA-256, listings, metadata and denial')
