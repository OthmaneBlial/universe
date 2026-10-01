#!/usr/bin/env python3
"""Real workflows using checksum-verified upstream Linux executable bytes."""
import pathlib
import platform
import runpy
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'zig-out/bin/universe'
manifest = runpy.run_path(str(ROOT / 'scripts/public-apps.py'), run_name='manifest')
BASE, APPS, verify = [manifest[name] for name in ('BASE', 'APPS', 'verify')]
for name, (_, _, _, digest) in APPS.items():
    verify((BASE / name).read_bytes(), digest, name)

checks = 0
for engine in [[]] + ([['--jit']] if platform.machine() in ('arm64', 'aarch64') else []):
    def run(name, args, data=b'', output=b'', code=0, error=None, files=False):
        global checks
        command = [str(RUNTIME), *engine, '--max-instructions', '30000000', '--timeout-ms', '30000']
        if files:
            command.append('--allow-files')
        result = subprocess.run([*command, str(BASE / name), *args], input=data, capture_output=True, timeout=40)
        assert result.returncode == code and result.stdout == output, (engine, name, args, result.returncode, result.stdout, result.stderr)
        assert error in result.stderr if error else not result.stderr, (engine, name, args, result.stderr)
        assert b'UNIVERSE FAULT' not in result.stderr, result.stderr
        checks += 1

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
print(f'Public Linux apps: {checks} checked workflows passed on {platform.system()}/{platform.machine()} with unchanged jq 1.8.2 and ripgrep 15.2.0 (interpreter/JIT on ARM64 hosts)')
