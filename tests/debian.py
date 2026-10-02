#!/usr/bin/env python3
"""Optional unchanged glibc application check; run scripts/debian.py first."""
import hashlib
import pathlib
import platform
import re
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'zig-out/bin/universe'
SYSROOT = ROOT / 'artifacts/debian-hello-amd64/sysroot'
GUEST = SYSROOT / 'usr/bin/hello'
for name, expected in {
    'usr/bin/hello': 'bfda3fef063414535d116a04689caf300568e0691318bcf255f932930508311b',
    'usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2': 'c8438e4fde1934e61c88311633f00949ff645d5c04cdb8671fa3d78164d2f307',
    'usr/lib/x86_64-linux-gnu/libc.so.6': '9792e3cbb541c8f44c7acf5f14f4022ea62998ecc787d326bed4d8b6547dfd92',
}.items():
    assert hashlib.sha256((SYSROOT / name).read_bytes()).hexdigest() == expected, name
checks = 0
modes = [[]] + ([['--jit']] if platform.machine() in ['arm64', 'aarch64'] else [])
for mode in modes:
    result = subprocess.run([
        str(RUNTIME), *mode, '--stats', '--syscalls', '--allow-files',
        '--sysroot', str(SYSROOT), str(GUEST),
    ], capture_output=True, timeout=20)
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    assert result.stdout == b'Hello, world!\n', result.stdout
    assert b'UNIVERSE FAULT' not in result.stderr, result.stderr
    for operation in [b'set_robust_list', b'rseq']:
        assert re.search(rb'syscall ' + operation + rb'\([^\n]+\) = -38\n', result.stderr), result.stderr
    assert re.search(rb'syscall exit_group\(0,', result.stderr), result.stderr
    assert re.search(rb'instructions=\d+ syscalls=\d+', result.stderr), result.stderr
    checks += 1

    def run(arguments, output=None, code=0, error=b''):
        global checks
        command = [str(RUNTIME), *mode, '--env', 'LC_ALL=C', '--allow-files',
                   '--sysroot', str(SYSROOT), str(GUEST), *arguments]
        value = subprocess.run(command, capture_output=True, timeout=20)
        assert value.returncode == code, (mode, arguments, value.returncode, value.stdout, value.stderr)
        if output is not None:
            assert value.stdout == output, (mode, arguments, value.stdout, output)
        assert error in value.stderr if error else not value.stderr, (mode, arguments, value.stderr)
        assert b'UNIVERSE FAULT' not in value.stderr and not value.stderr.startswith(b'UNIVERSE:'), value.stderr
        checks += 1
        return value

    run(['--traditional'], b'hello, world\n')
    run(['--greeting', 'Bonjour, univers!'], b'Bonjour, univers!\n')
    run(['-g', ''], b'\n')
    run(['--greeting=one\ntwo'], b'one\ntwo\n')
    run(['--greeting=first', '--greeting=last'], b'last\n')
    help_output = run(['--help']).stdout
    assert help_output.startswith(b'Usage: ' + str(GUEST).encode() + b' [OPTION]...\n'), help_output
    assert b'--greeting' in help_output and b'--traditional' in help_output, help_output
    version = run(['--version']).stdout
    # This pinned package contains an empty version literal and returns zero
    # after its usage routine, including option errors. Preserve its own bytes.
    assert version.startswith(b'hello (GNU Hello) \n'), version
    run(['unexpected'], help_output, error=b'extra operand: unexpected\n')
    run(['--invalid'], help_output, error=b"unrecognized option '--invalid'\n")
    run(['--greeting', 'Bonjour, univers 🚀'], b'', code=1,
        error=b'conversion to a multibyte string failed: Invalid or incomplete multibyte or wide character\n')
    denied = subprocess.run([str(RUNTIME), *mode, '--sysroot', str(SYSROOT), str(GUEST)],
                            capture_output=True, timeout=20)
    assert denied.returncode == 125 and not denied.stdout and denied.stderr == b'UNIVERSE: FileAccessDenied\n', denied
    checks += 1
print(f'Debian Hello/glibc: {checks}/{checks} unchanged application/profile checks passed; loader, TLS, greetings, help, package version/error behavior and default file denial')
