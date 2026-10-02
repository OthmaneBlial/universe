#!/usr/bin/env python3
"""Real workflows using checksum-verified upstream executable bytes."""
import hashlib
import os
import pathlib
import platform
import runpy
import subprocess
import sys
import tempfile
import zipfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
WINDOWS = '--windows' in sys.argv[1:]
arguments = [arg for arg in sys.argv[1:] if arg != '--windows']
RUNTIME = pathlib.Path(arguments[0]).resolve() if arguments else ROOT / 'zig-out/bin/universe'
manifest = runpy.run_path(str(ROOT / 'scripts/public-apps.py'), run_name='manifest')
BASE, APPS, verify = [manifest[name] for name in ('BASE', 'APPS', 'verify')]
archive_app = '7za.exe' if WINDOWS else '7zzs'
if WINDOWS:
    verify((BASE / archive_app).read_bytes(), manifest['WINDOWS_7ZIP'][3], archive_app)
else:
    for name, (_, _, _, digest) in APPS.items():
        verify((BASE / name).read_bytes(), digest, name)

checks = 0
failures = []
for engine in [[]] + ([['--jit']] if platform.machine() in ('arm64', 'aarch64') else []):
    def run(name, args, data=b'', output=b'', code=0, error=None, files=False, contains=(), cwd=None):
        global checks
        # 7-Zip error cleanup can retire 28.9M instructions; allow bounded wall-time variation.
        deadline_ms = 60000 if name == archive_app else 30000
        command = [str(RUNTIME), *engine, '--max-instructions', '30000000', '--timeout-ms', str(deadline_ms)]
        if files:
            command.append('--allow-files')
        if name == '7zzs':
            command += ['--env', 'TZ=UTC']
        result = subprocess.run([*command, str(BASE / name), *args], input=data, capture_output=True, timeout=deadline_ms / 1000 + 10, cwd=cwd)
        assert result.returncode == code and (output is None or result.stdout == output), (engine, name, args, result.returncode, result.stdout, result.stderr)
        assert all(value in result.stdout for value in contains), (engine, name, args, result.stdout)
        assert error in result.stderr if error else not result.stderr, (engine, name, args, result.stderr)
        assert b'UNIVERSE FAULT' not in result.stderr, result.stderr
        checks += 1
        return result

    if not WINDOWS:
        run('jq', ['--version'], output=b'jq-1.8.2\n')
        run('jq', ['-c', '[.items[] | select(.price > 3) | .price] | add'],
            b'{"items":[{"price":2.5},{"price":4.75},{"price":6.25}]}\n', b'11\n')
        run('jq', ['-c', '-S', '{names: [.[] | .name] | sort, count: length}'],
            '[{"name":"Zoé"},{"name":"Amina"}]\n'.encode(), '{"count":2,"names":["Amina","Zoé"]}\n'.encode())
        run('jq', ['-e', '.ok'], b'{"ok":false}\n', b'false\n', 1)
        run('jq', ['-c', '.'], b'{broken json}\n', code=5, error=b'parse error:')
        run('rg', ['--version'], output=b'ripgrep 15.2.0 (rev e89fff89ac)\n\nfeatures:+pcre2\nsimd(compile):+SSE2,-SSSE3,-AVX2\nsimd(runtime):+SSE2,-SSSE3,-AVX2\n\nPCRE2 10.45 is available (JIT is available)\n')
        text = b'alpha\nbeta\ngamma\n'
        rg = ['--threads', '1', '--color', 'never']
        run('rg', [*rg, '-n', '^(alpha|gamma)'], text, b'1:alpha\n3:gamma\n', files=True)
        run('rg', [*rg, '--count', 'a$'], text, b'3\n', files=True)
        run('rg', [*rg, 'absent'], text, code=1, files=True)
        run('rg', [*rg, '['], text, code=2, error=b'regex parse error:', files=True)
        with tempfile.TemporaryDirectory(prefix='universe-public-apps-') as directory:
            root = pathlib.Path(directory)
            json_file = root / 'data.json'
            json_file.write_text('{"answer":42}\n')
            text_file = root / 'notes.txt'
            text_file.write_bytes(text)
            run('jq', ['-c', '.answer', str(json_file)], output=b'42\n', files=True)
            run('rg', [*rg, '-n', '^(alpha|gamma)', str(text_file)], output=b'1:alpha\n3:gamma\n', files=True)
            run('jq', ['.', str(json_file)], code=2, error=b'Permission denied')
            run('rg', [*rg, 'alpha', str(text_file)], code=2, error=b'Permission denied')
            parallel = ['--threads', '2', '--no-ignore', '--color', 'never']
            names, matches = [], []
            for index in range(8):
                name = f'threaded/group-{index}/notes.txt'
                target = root / name
                target.parent.mkdir(parents=True)
                target.write_bytes(text)
                names.append(name.encode())
                matches.extend([f'{name}:1:alpha'.encode(), f'{name}:3:gamma'.encode()])
            result = run('rg', [*parallel, '-n', '^(alpha|gamma)', 'threaded'],
                         output=None, files=True, cwd=root)
            assert sorted(result.stdout.splitlines()) == sorted(matches), result.stdout
            result = run('rg', [*parallel, '--files', 'threaded'], output=None, files=True, cwd=root)
            assert sorted(result.stdout.splitlines()) == sorted(names), result.stdout
        run('fd', ['--version'], output=b'fd 10.5.0\n')
        run('fd', ['--help'], output=None, contains=(b'Usage:', b'--threads', b'--type'))
        with tempfile.TemporaryDirectory(prefix='universe-fd-') as directory:
            root = pathlib.Path(directory)
            names = ['notes.txt', 'data.json', 'nested/alpha.txt', 'nested/café 🚀.txt',
                     'nested/deep/beta.rs', '.hidden.txt', 'ignored.txt', '.ignore']
            for name in names:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text('ignored.txt\n' if name == '.ignore' else name + '\n')
            (root / 'link.txt').symlink_to('notes.txt')
            visible = [name for name in names if not name.startswith('.')]
            default = [name for name in visible if name != 'ignored.txt']
            fd = ['--threads', '1', '--color', 'never', '--print0']
            cases = [
                (['--type', 'f', '.'], ['./' + name for name in default]),
                (['--type', 'd', '.'], ['./nested/', './nested/deep/']),
                (['--type', 'l', '.'], ['./link.txt']),
                (['--type', 'f', '--hidden', '--no-ignore', '.'], ['./' + name for name in names]),
                (['--type', 'f', '--extension', 'txt', '--no-ignore', '.'], ['./' + name for name in visible if name.endswith('.txt')]),
                (['--type', 'f', '--max-depth', '1', '--hidden', '--no-ignore', '.'], ['./' + name for name in names if '/' not in name]),
                (['--type', 'f', '--fixed-strings', '🚀', '.'], ['./nested/café 🚀.txt']),
                (['--type', 'f', '--threads', '2', '--no-ignore', '.'], ['./' + name for name in visible]),
                (['--type', 'f', '--no-ignore', '--exclude', 'nested', '.'], ['./' + name for name in visible if '/' not in name]),
                (['--type', 'f', '--no-ignore', '--min-depth', '2', '.'], ['./' + name for name in visible if '/' in name]),
                (['--type', 'f', '--absolute-path', '.'], [str(root.resolve() / name) for name in default]),
                (['--type', 'f', '--glob', '*.txt', '.'], ['./' + name for name in default if name.endswith('.txt')]),
            ]
            for args, expected in cases:
                result = run('fd', [*fd, *args], output=None, files=True, cwd=root)
                assert sorted(result.stdout.split(b'\0')) == sorted([b''] + [name.encode() for name in expected]), (engine, args, result.stdout, expected)
            run('fd', [*fd, '--has-results', 'absent', '.'], code=1, files=True, cwd=root)
            run('fd', [*fd, '--has-results', 'notes', '.'], files=True, cwd=root)
            run('fd', [*fd, '[', '.'], code=1, error=b'regex parse error:', files=True, cwd=root)
            run('fd', [*fd, '--definitely-invalid-option'], code=2, error=b'unexpected argument', files=True, cwd=root)
            run('fd', [*fd, '.', '.'], code=1, error=b'No valid search paths given', cwd=root)
    run(archive_app, ['i'], output=None, contains=(b'7-Zip (a) 26.03' if WINDOWS else b'7-Zip (z) 26.03', b'Formats:', b'Codecs:'), files=True)
    with tempfile.TemporaryDirectory(prefix='universe-7zip-') as directory:
        root = pathlib.Path(directory)
        original = {'hello.txt': b'Hello from UNIVERSE!\n' * 40,
                    'binary.dat': bytes(range(256)) * 32, 'nested/empty.txt': b''}
        if WINDOWS:
            original['nested/café 🚀.txt'] = 'Unicode filenames and bytes: é🚀\n'.encode()
        timestamp = 1_700_000_000
        for name, data in original.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            os.utime(target, (timestamp, timestamp))
        digest = hashlib.sha256(original['binary.dat']).hexdigest().encode()
        run(archive_app, ['h', '-scrcSHA256', 'binary.dat'], output=None,
            contains=(digest, b'Everything is Ok'), files=True, cwd=root)
        for kind in ['zip', '7z']:
            archive = f'bundle.{kind}'
            run(archive_app, ['a', f'-t{kind}', '-mmt=off', '-mx=1', archive, *original],
                output=None, contains=(b'Everything is Ok',), files=True, cwd=root)
            if kind == 'zip':
                # Independent stdlib decoding checks CRCs and every produced member byte.
                with zipfile.ZipFile(root / archive) as reference:
                    assert reference.testzip() is None
                    assert set(reference.namelist()) == set(original), reference.namelist()
                    for name, data in original.items():
                        assert reference.read(name) == data, name
            run(archive_app, ['l', '-slt', archive], output=None,
                contains=tuple(('Path = '+(name.replace('/',chr(92)) if WINDOWS else name)).encode() for name in original), files=True, cwd=root)
            run(archive_app, ['t', '-mmt=off', archive], output=None,
                contains=(b'Everything is Ok',), files=True, cwd=root)
            destination = f'out-{kind}'
            run(archive_app, ['x', '-mmt=off', f'-o{destination}', archive], output=None,
                contains=(b'Everything is Ok',), files=True, cwd=root)
            for name, data in original.items():
                extracted = root / destination / name
                assert extracted.read_bytes() == data, (kind, name)
                assert extracted.stat().st_mtime_ns == timestamp * 1_000_000_000, (kind, name, extracted.stat())
        if not WINDOWS:
            run(archive_app, ['a', '-t7z', '-mmt=2', '-mx=1', 'threaded.7z', *original],
                output=None, contains=(b'Everything is Ok',), files=True, cwd=root)
            run(archive_app, ['x', '-mmt=2', '-othreaded-out', 'threaded.7z'],
                output=None, contains=(b'Everything is Ok',), files=True, cwd=root)
            for name, data in original.items():
                extracted = root / 'threaded-out' / name
                assert extracted.read_bytes() == data, ('threaded', name)
                assert extracted.stat().st_mtime_ns == timestamp * 1_000_000_000, ('threaded', name)
        # The guest also decodes bytes produced by an independent ZIP implementation.
        with zipfile.ZipFile(root / 'host.zip', 'w', compression=zipfile.ZIP_DEFLATED) as reference:
            reference.writestr('from-python.txt', b'independent compressed archive\n' * 20)
        run(archive_app, ['x', '-mmt=off', '-ohost-out', 'host.zip'], output=None,
            contains=(b'Everything is Ok',), files=True, cwd=root)
        assert (root / 'host-out/from-python.txt').read_bytes() == b'independent compressed archive\n' * 20
        run(archive_app, ['a', '-tzip', '-mmt=off', '-mx=1', 'tree.zip', 'nested'], output=None,
            contains=(b'Everything is Ok',), files=True, cwd=root)
        with zipfile.ZipFile(root / 'tree.zip') as reference:
            assert reference.testzip() is None
            assert 'nested/' in reference.namelist()
            assert reference.read('nested/empty.txt') == b''
        run(archive_app, ['x', '-mmt=off', '-otree-out', 'tree.zip'], output=None,
            contains=(b'Everything is Ok',), files=True, cwd=root)
        assert (root / 'tree-out/nested/empty.txt').read_bytes() == b''
        (root / 'broken.zip').write_bytes(b'This is not a ZIP archive.\n')
        run(archive_app, ['t', '-mmt=off', 'broken.zip'], output=None, code=2,
            error=b'Cannot open the file as archive', files=True, cwd=root)
        run(archive_app, ['h', 'missing.txt'], output=None, code=1,
            error=b'The requested file was not found.' if WINDOWS else b'No such file or directory', files=True, cwd=root)
        for args, destination in [(['x', '-mmt=off', '-odenied-out', 'bundle.zip'], 'denied-out'),
                                  (['a', '-tzip', '-mmt=off', 'denied.zip', 'hello.txt'], 'denied.zip')]:
            try:
                run(archive_app, args, output=None, code=2,
                    error=b'Access was denied.' if WINDOWS else b'Permission denied', cwd=root)
            except AssertionError as fault:
                if not WINDOWS:raise
                failures.append(str(fault)) # Continue both engines, then fail the complete probe.
            assert not (root / destination).exists()
label = 'Windows 7-Zip 26.03' if WINDOWS else 'Linux jq 1.8.2, ripgrep 15.2.0, 7-Zip 26.03 and fd 10.5.0'
print(f'Public {label}: {checks} checked workflows passed, {len(failures)} failed on {platform.system()}/{platform.machine()} (interpreter/JIT on ARM64 hosts)',flush=True)
if failures:
    for failure in failures:print(failure,file=sys.stderr)
    raise SystemExit(1)
