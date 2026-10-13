#!/usr/bin/env python3
"""Optional unchanged Alpine GCC 14.2 checks; run `scripts/alpine.py --gcc` first."""
import hashlib
import pathlib
import platform
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'zig-out/bin/universe'
SYSROOT = ROOT / 'artifacts/alpine-x86_64/sysroot'
for name, expected in {
    'usr/bin/gcc': '3790afd5098d7b7c459b3ff94f2c55a789c495532e8e0bd82ec2e44ad34c5a43',
    'usr/libexec/gcc/x86_64-alpine-linux-musl/14.2.0/cc1': '71f397910c602ae1a6b27105702530b09f3e21f2b426f6204a049e19b1d00c95',
    'usr/bin/ld': '6c5bf7be2803e54ba22744cb30730f89b24e5e03771de630ae97d806951b19c5',
}.items():
    assert hashlib.sha256((SYSROOT / name).read_bytes()).hexdigest() == expected, name
SOURCE = rb'''#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned long fib(unsigned n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); }

int main(int argc, char **argv) {
    char line[64] = "";
    if (!fgets(line, sizeof line, stdin)) return 3;
    line[strcspn(line, "\n")] = 0;
    FILE *out = fopen("/tmp/gcc-check/out.txt", "w");
    if (!out) return 4;
    fprintf(out, "%s:%d\n", line, argc);
    fclose(out);
    printf("fib(25)=%lu sqrt(2)=%.6f argv=%s stdin=%s\n", fib(25), sqrt(2.0), argc > 1 ? argv[1] : "-", line);
    return argc > 2 ? atoi(argv[2]) : 0;
}
'''

checks = 0
binaries = []
modes = [[]] + ([['--jit']] if platform.machine() in ['arm64', 'aarch64'] else [])
for mode in modes:
    work = SYSROOT / 'tmp/gcc-check'
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    (work / 'program.c').write_bytes(SOURCE)

    def guest(*args, input=b'', output=None, code=0):
        global checks
        result = subprocess.run([str(RUNTIME), *mode, '--unlimited', '--allow-files', '--sysroot', str(SYSROOT), *args],
                                input=input, capture_output=True, timeout=900)
        assert result.returncode == code, (mode, args, result)
        if output is not None:
            assert result.stdout == output, (mode, args, result.stdout, output)
        assert not result.stderr, (mode, args, result.stderr)
        checks += 1
    # The driver spawns cc1, as and collect2/ld; every one is an unchanged x86-64 Linux binary.
    guest('/usr/bin/gcc', '-O2', '-Wall', '-o', '/tmp/gcc-check/program', '/tmp/gcc-check/program.c', '-lm')
    guest('/tmp/gcc-check/program', 'mac', input=b'hello\n',
          output=b'fib(25)=75025 sqrt(2)=1.414214 argv=mac stdin=hello\n')
    assert (work / 'out.txt').read_bytes() == b'hello:2\n'
    guest('/tmp/gcc-check/program', 'x', '7', input=b'bye\n', output=b'fib(25)=75025 sqrt(2)=1.414214 argv=x stdin=bye\n', code=7)
    binaries.append((work / 'program').read_bytes())
    shutil.rmtree(work)
assert all(binary == binaries[0] for binary in binaries), 'engines produced different executables'
assert binaries[0][:4] == b'\x7fELF' and binaries[0][18] == 62, 'expected an x86-64 ELF'
checks += 1
print(f'Alpine GCC 14.2 (musl, x86-64): {checks}/{checks} unchanged compiler checks passed; gcc/cc1/as/ld build a '
      'C program with libm, which reads stdin, writes a file and returns status, byte-identical across engines')
