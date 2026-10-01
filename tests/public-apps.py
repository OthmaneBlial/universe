#!/usr/bin/env python3
"""Real workflows using checksum-verified upstream Linux executable bytes."""
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
RUNTIME = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'zig-out/bin/universe'
manifest = runpy.run_path(str(ROOT / 'scripts/public-apps.py'), run_name='manifest')
BASE, APPS, verify = [manifest[name] for name in ('BASE', 'APPS', 'verify')]
for name, (_, _, _, digest) in APPS.items():
    verify((BASE / name).read_bytes(), digest, name)

checks = 0
for engine in [[]] + ([['--jit']] if platform.machine() in ('arm64', 'aarch64') else []):
    def run(name, args, data=b'', output=b'', code=0, error=None, files=False, contains=(), cwd=None):
        global checks
        # 7-Zip error cleanup can retire 28.9M instructions; allow bounded wall-time variation.
        deadline_ms = 60000 if name == '7zzs' else 30000
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
    run('7zzs', ['i'], output=None, contains=(b'7-Zip (z) 26.03', b'Formats:', b'Codecs:'), files=True)
    with tempfile.TemporaryDirectory(prefix='universe-7zip-') as directory:
        root = pathlib.Path(directory)
        original = {'hello.txt': b'Hello from UNIVERSE!\n' * 40,
                    'binary.dat': bytes(range(256)) * 32, 'nested/empty.txt': b''}
        timestamp = 1_700_000_000
        for name, data in original.items():
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
            os.utime(target, (timestamp, timestamp))
        digest = hashlib.sha256(original['binary.dat']).hexdigest().encode()
        run('7zzs', ['h', '-scrcSHA256', 'binary.dat'], output=None,
            contains=(digest, b'Everything is Ok'), files=True, cwd=root)
        for kind in ['zip', '7z']:
            archive = f'bundle.{kind}'
            run('7zzs', ['a', f'-t{kind}', '-mmt=off', '-mx=1', archive, *original],
                output=None, contains=(b'Everything is Ok',), files=True, cwd=root)
            if kind == 'zip':
                # Independent stdlib decoding checks CRCs and every produced member byte.
                with zipfile.ZipFile(root / archive) as reference:
                    assert reference.testzip() is None
                    assert set(reference.namelist()) == set(original), reference.namelist()
                    for name, data in original.items():
                        assert reference.read(name) == data, name
            run('7zzs', ['l', '-slt', archive], output=None,
                contains=tuple(f'Path = {name}'.encode() for name in original), files=True, cwd=root)
            run('7zzs', ['t', '-mmt=off', archive], output=None,
                contains=(b'Everything is Ok',), files=True, cwd=root)
            destination = f'out-{kind}'
            run('7zzs', ['x', '-mmt=off', f'-o{destination}', archive], output=None,
                contains=(b'Everything is Ok',), files=True, cwd=root)
            for name, data in original.items():
                extracted = root / destination / name
                assert extracted.read_bytes() == data, (kind, name)
                assert extracted.stat().st_mtime_ns == timestamp * 1_000_000_000, (kind, name, extracted.stat())
        # The guest also decodes bytes produced by an independent ZIP implementation.
        with zipfile.ZipFile(root / 'host.zip', 'w', compression=zipfile.ZIP_DEFLATED) as reference:
            reference.writestr('from-python.txt', b'independent compressed archive\n' * 20)
        run('7zzs', ['x', '-mmt=off', '-ohost-out', 'host.zip'], output=None,
            contains=(b'Everything is Ok',), files=True, cwd=root)
        assert (root / 'host-out/from-python.txt').read_bytes() == b'independent compressed archive\n' * 20
        run('7zzs', ['a', '-tzip', '-mmt=off', '-mx=1', 'tree.zip', 'nested'], output=None,
            contains=(b'Everything is Ok',), files=True, cwd=root)
        with zipfile.ZipFile(root / 'tree.zip') as reference:
            assert reference.testzip() is None
            assert 'nested/' in reference.namelist()
            assert reference.read('nested/empty.txt') == b''
        run('7zzs', ['x', '-mmt=off', '-otree-out', 'tree.zip'], output=None,
            contains=(b'Everything is Ok',), files=True, cwd=root)
        assert (root / 'tree-out/nested/empty.txt').read_bytes() == b''
        (root / 'broken.zip').write_bytes(b'This is not a ZIP archive.\n')
        run('7zzs', ['t', '-mmt=off', 'broken.zip'], output=None, code=2,
            error=b'Cannot open the file as archive', files=True, cwd=root)
        run('7zzs', ['h', 'missing.txt'], output=None, code=1,
            error=b'No such file or directory', files=True, cwd=root)
        run('7zzs', ['x', '-mmt=off', '-odenied-out', 'bundle.zip'], output=None,
            code=2, error=b'Permission denied', cwd=root)
        assert not (root / 'denied-out').exists()
        run('7zzs', ['a', '-tzip', '-mmt=off', 'denied.zip', 'hello.txt'], output=None,
            code=2, error=b'Permission denied', cwd=root)
        assert not (root / 'denied.zip').exists()
print(f'Public Linux apps: {checks} checked workflows passed on {platform.system()}/{platform.machine()} with unchanged jq 1.8.2, ripgrep 15.2.0 and 7-Zip 26.03 (interpreter/JIT on ARM64 hosts)')
