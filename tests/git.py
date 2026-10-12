#!/usr/bin/env python3
"""Optional unchanged Alpine git 2.49.1 checks; run scripts/alpine.py first."""
import hashlib
import pathlib
import platform
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'zig-out/bin/universe'
SYSROOT = ROOT / 'artifacts/alpine-x86_64/sysroot'
assert hashlib.sha256((SYSROOT / 'usr/bin/git').read_bytes()).hexdigest() == \
    '5b5cbd6facf5d86226063d69fe57064bc5ad79bdccee2af0ac787646c564a880', 'unexpected git binary'
IDENTITY = {'HOME': '/tmp/git-check', 'GIT_AUTHOR_NAME': 'Ada', 'GIT_AUTHOR_EMAIL': 'ada@example.com',
            'GIT_COMMITTER_NAME': 'Ada', 'GIT_COMMITTER_EMAIL': 'ada@example.com',
            'GIT_AUTHOR_DATE': '2026-10-13T00:00:00Z', 'GIT_COMMITTER_DATE': '2026-10-13T00:00:00Z'}


def obj(kind, body):
    """Git object ID from its canonical encoding: an independent oracle for the guest's hashes."""
    return hashlib.sha1(f'{kind} {len(body)}\0'.encode() + body).hexdigest()


def commit(tree, message, parent=None):
    signature = b'Ada <ada@example.com> 1791849600 +0000'
    body = b'tree ' + tree.encode() + b'\n' + (b'parent ' + parent.encode() + b'\n' if parent else b'')
    return obj('commit', body + b'author ' + signature + b'\ncommitter ' + signature + b'\n\n' + message + b'\n')


def tree(name, blob):
    return obj('tree', b'100644 ' + name + b'\0' + bytes.fromhex(blob))


first_blob = obj('blob', b'hello\n')
first = commit(tree(b'a.txt', first_blob), b'first')
second_blob = obj('blob', b'hello\nworld\n')
second = commit(tree(b'a.txt', second_blob), b'second', first)

checks = 0
modes = [[]] + ([['--jit']] if platform.machine() in ['arm64', 'aarch64'] else [])
for mode in modes:
    work = SYSROOT / 'tmp/git-check'
    shutil.rmtree(work, ignore_errors=True)
    (work / 'repo').mkdir(parents=True)
    (work / 'repo/a.txt').write_bytes(b'hello\n')

    def git(*args, output=None, code=0):
        global checks
        env = [item for key, value in IDENTITY.items() for item in ('--env', f'{key}={value}')]
        # From the repository root: the absolute guest path names the sysroot's git, and -C needs chdir.
        result = subprocess.run([str(RUNTIME), *mode, '--unlimited', '--allow-files', *env, '--sysroot', str(SYSROOT),
                                 '/usr/bin/git', '-C', '/tmp/git-check/repo', *args], capture_output=True, timeout=600)
        assert result.returncode == code, (mode, args, result)
        if output is not None:
            assert result.stdout == output, (mode, args, result.stdout, output)
        assert b'UNIVERSE' not in result.stderr, (mode, args, result.stderr)
        checks += 1
        return result.stdout
    git('--version', output=b'git version 2.49.1\n')
    git('init', '-q', '-b', 'main')
    git('status', '--short', output=b'?? a.txt\n')
    git('add', 'a.txt')
    git('commit', '-q', '-m', 'first')
    git('rev-parse', 'HEAD', output=first.encode() + b'\n')
    git('cat-file', '-p', 'HEAD:a.txt', output=b'hello\n')
    (work / 'repo/a.txt').write_bytes(b'hello\nworld\n')
    git('diff', '--stat', output=b' a.txt | 1 +\n 1 file changed, 1 insertion(+)\n')
    git('commit', '-q', '-a', '-m', 'second')
    git('log', '--format=%H %s', output=f'{second} second\n{first} first\n'.encode())
    git('branch', 'feature', first)
    git('branch', '--list', output=b'  feature\n* main\n')
    git('switch', '-q', 'feature')
    assert (work / 'repo/a.txt').read_bytes() == b'hello\n'
    git('switch', '-q', 'main')
    assert (work / 'repo/a.txt').read_bytes() == b'hello\nworld\n'
    git('rev-parse', 'feature', output=first.encode() + b'\n')
    git('cat-file', '-t', 'nope', code=128)
    shutil.rmtree(work)
print(f'Alpine git 2.49.1 (musl, x86-64): {checks}/{checks} unchanged git checks passed; init, status, add, commit, '
      'object IDs matching an independent SHA-1 oracle, diff, log, branch, switch and errors')
