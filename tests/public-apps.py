#!/usr/bin/env python3
"""Real workflows using checksum-verified upstream executable bytes."""
import base64
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
    def run(name, args, data=b'', output=b'', code=0, error=None, files=False, contains=(), cwd=None, sysroot=None):
        global checks
        # 7-Zip error cleanup can retire 28.9M instructions; allow bounded wall-time variation.
        deadline_ms = 60000 if name == archive_app else 30000
        command = [str(RUNTIME), *engine, '--max-instructions', '30000000', '--timeout-ms', str(deadline_ms)]
        if files:
            command.append('--allow-files')
        if sysroot is not None:
            command += ['--sysroot', str(sysroot)]
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
        run('busybox', ['--help'], output=None, contains=(b'BusyBox v1.35.0', b'Currently defined functions:'))
        listed = run('busybox', ['--list'], output=None, contains=(b'cat\n', b'printf\n', b'sort\n', b'cp\n'))
        assert listed.stdout.splitlines() == sorted(set(listed.stdout.splitlines()))
        run('busybox', ['printf', '%s:%04d\\n', 'hello', '42'], output=b'hello:0042\n')
        run('busybox', ['seq', '-s', ',', '1', '2', '7'], output=b'1,3,5,7\n')
        run('busybox', ['echo', 'café 🚀'], output='café 🚀\n'.encode())
        text = b'alpha\nbeta\ngamma\n'
        run('busybox', ['sha256sum'], text, hashlib.sha256(text).hexdigest().encode() + b'  -\n')
        binary = b'hello\0\xff'
        encoded = base64.b64encode(binary) + b'\n'
        run('busybox', ['base64'], binary, encoded)
        run('busybox', ['base64', '-d'], encoded, binary)
        run('busybox', ['cut', '-d', ':', '-f', '2'], b'a:one\nb:two\n', b'one\ntwo\n')
        run('busybox', ['sort', '-u'], b'z\na\nz\nb\n', b'a\nb\nz\n')
        run('busybox', ['grep', '-n', 'a$'], text, b'1:alpha\n2:beta\n3:gamma\n')
        run('busybox', ['grep', 'absent'], text, code=1)
        run('busybox', ['tr', 'a-z', 'A-Z'], text, text.upper())
        run('busybox', ['uniq', '-c'], b'a\na\nb\n', b'      2 a\n      1 b\n')
        run('busybox', ['wc', '-l'], text, b'3\n')
        run('busybox', ['head', '-n', '2'], text, b'alpha\nbeta\n')
        run('busybox', ['tail', '-n', '1'], text, b'gamma\n')
        run('busybox', ['true'])
        run('busybox', ['false'], code=1)
        run('busybox', ['cat'], text, text)
        with tempfile.TemporaryDirectory(prefix='universe-busybox-') as directory:
            root = pathlib.Path(directory)
            name = 'café 🚀.txt'
            contents = bytes(range(256)) * 8 + 'Unicode file contents: é🚀\n'.encode()
            (root / name).write_bytes(contents)
            run('busybox', ['cat', name], output=contents, files=True, cwd=root)
            run('busybox', ['cat', name], code=1, error=b'Permission denied', cwd=root)
            run('busybox', ['cat', 'missing.txt'], code=1, error=b'No such file or directory', files=True, cwd=root)
            run('busybox', ['sha256sum', name], output=hashlib.sha256(contents).hexdigest().encode() + b'  ' + name.encode() + b'\n', files=True, cwd=root)
            run('busybox', ['cp', name, 'copy.txt'], files=True, cwd=root)
            assert (root / 'copy.txt').read_bytes() == contents
            run('busybox', ['mv', 'copy.txt', 'moved.txt'], files=True, cwd=root)
            assert not (root / 'copy.txt').exists() and (root / 'moved.txt').read_bytes() == contents
            run('busybox', ['rm', 'moved.txt'], files=True, cwd=root)
            assert not (root / 'moved.txt').exists()
            run('busybox', ['mkdir', 'nested'], files=True, cwd=root)
            assert (root / 'nested').is_dir()
            run('busybox', ['rmdir', 'nested'], files=True, cwd=root)
            assert not (root / 'nested').exists()
            run('busybox', ['cp', name, 'denied.txt'], code=1, error=b'Permission denied', cwd=root)
            assert not (root / 'denied.txt').exists()
        with tempfile.TemporaryDirectory(prefix='universe-busybox-identity-') as directory:
            root = pathlib.Path(directory)
            for files in (False, True):
                for args, expected in [([], b'uid=1000 gid=1000\n'), (['-u'], b'1000\n'),
                                       (['-g'], b'1000\n'), (['-G'], b'1000\n')]:
                    run('busybox', ['id', *args], output=expected, files=files, sysroot=root)
            (root / 'etc').mkdir()
            (root / 'etc/passwd').write_text('guest:x:1000:1000:Guest user:/home/guest:/bin/sh\n')
            (root / 'etc/group').write_text('guest:x:1000:\n')
            run('busybox', ['id'], output=b'uid=1000(guest) gid=1000(guest)\n', files=True, sysroot=root)
            run('busybox', ['id', '-n', '-u'], output=b'guest\n', files=True, sysroot=root)
            run('busybox', ['id', '-n', '-g'], output=b'guest\n', files=True, sysroot=root)
        shell_cases = [
            ('echo hello', [], b'', b'hello\n', 0),
            ('printf "%s:%04d\\n" guest 7', [], b'', b'guest:0007\n', 0),
            ('a=20; b=22; echo $((a+b))', [], b'', b'42\n', 0),
            ('printf "%s|%s\\n" "$1" "$2"', ['café 🚀', 'a b'], b'', 'café 🚀|a b\n'.encode(), 0),
            ('n=0; for x in 2 3 5; do n=$((n+x)); done; printf "%d\\n" "$n"', [], b'', b'10\n', 0),
            ('sum() { echo $(($1+$2)); }; sum 20 22', [], b'', b'42\n', 0),
            ('if [ 42 -eq 42 ]; then echo yes; else echo no; fi', [], b'', b'yes\n', 0),
            ('x=blue; case "$x" in blue) echo sky;; *) echo other;; esac', [], b'', b'sky\n', 0),
            ('false; echo "$?"; exit 37', [], b'', b'1\n', 37),
            ('IFS= read -r line; printf "%s\\n" "$line"', [], b'from stdin\n', b'from stdin\n', 0),
            ('echo "$$:$PPID"', [], b'', b'1:0\n', 0),
            ('echo $(echo hi)', [], b'', b'hi\n', 0),
            ('value=$(printf \'%s\' \'é 🚀\'); printf \'<%s>\\n\' "$value"', [], b'', b'<\xc3\xa9 \xf0\x9f\x9a\x80>\n', 0),
            ('value=$(printf \'first\\nlast\\n\\n\'); printf \'%s:%s\\n\' "$value" "$?"', [], b'', b'first\nlast:0\n', 0),
            ('printf \'hello\\n\' | { read word; printf \'<%s>\\n\' "$word"; }', [], b'', b'<hello>\n', 0),
            ('false | true', [], b'', b'', 0),
            ('true | false', [], b'', b'', 1),
            ('(n=9; printf \'%s\\n\' "$n"); printf \'%s\\n\' "${n-unset}"', [], b'', b'9\nunset\n', 0),
            ('value=$(exit 37); printf \'%s:%s\\n\' "$?" "$value"', [], b'', b'37:\n', 0),
            ('for n in 1 2 3 4 5 6 7 8 9 10; do value=$(printf \'%s\' "$n"); printf \'%s:\' "$value"; done', [], b'', b'1:2:3:4:5:6:7:8:9:10:', 0),
            ('i=0; while [ "$i" -lt 420 ]; do printf \'0123456789\\n\'; i=$((i+1)); done | { n=0; while read line; do n=$((n+1)); done; printf \'%s\\n\' "$n"; }', [], b'', b'420\n', 0),
        ]
        for script, args, data, expected, code in shell_cases:
            run('busybox', ['sh', '-c', script, 'guest-script', *args], data, expected, code)
        with tempfile.TemporaryDirectory(prefix='universe-busybox-shell-') as directory:
            root = pathlib.Path(directory)
            script = 'printf "redirected\\n" > output.txt'
            run('busybox', ['sh', '-c', script], code=1, error=b'Permission denied', cwd=root, sysroot=root)
            assert not (root / 'output.txt').exists()
            run('busybox', ['sh', '-c', script], files=True, cwd=root, sysroot=root)
            assert (root / 'output.txt').read_bytes() == b'redirected\n'
        with tempfile.TemporaryDirectory(prefix='universe-busybox-exec-') as directory:
            root = pathlib.Path(directory)
            (root / 'bin').mkdir()
            for name in ('busybox', 'jq', 'rg'):
                target = root / 'bin' / name
                target.write_bytes((BASE / name).read_bytes())
                target.chmod(0o755)
            for name in ('cat', 'sort', 'wc', 'grep'):
                (root / 'bin' / name).symlink_to('busybox')
            (root / 'input.txt').write_bytes(b'alpha\nbeta\ngamma\n')
            (root / 'input.json').write_bytes(b'{"answer":42}\n')
            cases = [
                ('echo hi | /bin/cat', b'hi\n', 0),
                ('exec /bin/busybox printf "%s|%s\\n" "café 🚀" "a b"', 'café 🚀|a b\n'.encode(), 0),
                ('value=$(/bin/busybox printf "%s" "child value"); printf "<%s>\\n" "$value"', b'<child value>\n', 0),
                ('printf "beta\\nalpha\\nbeta\\n" | /bin/sort -u | /bin/wc -l', b'2\n', 0),
                ('export CHECK="é 🚀"; exec /bin/busybox sh -c \'printf "%s\\n" "$CHECK"\'', 'é 🚀\n'.encode(), 0),
                ('exec /bin/busybox false', b'', 1),
                ('PATH=/bin; export PATH; printf "from PATH\\n" | cat', b'from PATH\n', 0),
                ('printf "saved bytes\\n" | /bin/cat > /result.txt', b'', 0),
                ('i=0; while [ "$i" -lt 420 ]; do printf "0123456789\\n"; i=$((i+1)); done | /bin/cat', b'0123456789\n' * 420, 0),
                ('/bin/grep -n "a$" /input.txt', b'1:alpha\n2:beta\n3:gamma\n', 0),
                ('/bin/jq .answer /input.json', b'42\n', 0),
                ('printf "alpha\\nbeta\\ngamma\\n" | /bin/rg --threads 1 --color never -n alpha', b'1:alpha\n', 0),
            ]
            for script, expected, code in cases:
                run('busybox', ['sh', '-c', script], output=expected, code=code, files=True, cwd=root, sysroot=root)
            assert (root / 'result.txt').read_bytes() == b'saved bytes\n'
        with tempfile.TemporaryDirectory(prefix='universe-busybox-signals-') as directory:
            root = pathlib.Path(directory)
            (root / 'bin').mkdir()
            for name in ('busybox', 'jq'):
                target = root / 'bin' / name
                target.write_bytes((BASE / name).read_bytes())
                target.chmod(0o755)
            (root / 'bin' / 'cat').symlink_to('busybox')
            (root / 'empty').touch()
            (root / 'input.json').write_bytes(b'{"answer":42}\n')
            # Ash opens /dev/null before applying background redirections. These
            # cases use allowed host files; a sysroot must supply its own device.
            cases = [
                ('echo hi < empty & wait', b'hi\n', None),
                ('(exit 37) < empty & pid=$!; wait "$pid"; echo "$?"', b'37\n', None),
                ('(exit 3) < empty & a=$!; (exit 7) < empty & b=$!; wait "$a"; x=$?; wait "$b"; echo "$x:$?"', b'3:7\n', None),
                ("trap 'echo caught' USR1; kill -USR1 $$; echo alive", b'caught\nalive\n', None),
                ('trap \'flag=yes\' USR2; kill -USR2 $$; echo "$flag"', b'yes\n', None),
                ("trap '' USR1; kill -USR1 $$; echo ignored", b'ignored\n', None),
                ("trap 'echo terminated' TERM; kill -TERM $$; echo alive", b'terminated\nalive\n', None),
                ('(while :; do :; done) < empty & pid=$!; kill -KILL "$pid"; wait "$pid"; echo "$?"', b'137\n', b'Killed\n'),
                ('./bin/jq .answer input.json < empty > async.json & wait; ./bin/cat async.json', b'42\n', None),
                ('{ printf "background bytes\\n" | ./bin/cat > async.txt; } < empty & wait; ./bin/cat async.txt', b'background bytes\n', None),
                ('trap \'flag=yes\' CHLD; (exit 0) < empty & wait; echo "$flag"', b'yes\n', None),
                ('i=0; while [ "$i" -lt 10 ]; do (exit 0) < empty & wait; i=$((i+1)); done; echo "$i"', b'10\n', None),
            ]
            for script, expected, error in cases:
                run('busybox', ['sh', '-c', script], output=expected, error=error, files=True, cwd=root)
            assert (root / 'async.json').read_bytes() == b'42\n'
            assert (root / 'async.txt').read_bytes() == b'background bytes\n'
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
label = 'Windows 7-Zip 26.03' if WINDOWS else 'Linux BusyBox 1.35.0, jq 1.8.2, ripgrep 15.2.0, 7-Zip 26.03 and fd 10.5.0'
print(f'Public {label}: {checks} checked workflows passed, {len(failures)} failed on {platform.system()}/{platform.machine()} (interpreter/JIT on ARM64 hosts)',flush=True)
if failures:
    for failure in failures:print(failure,file=sys.stderr)
    raise SystemExit(1)
