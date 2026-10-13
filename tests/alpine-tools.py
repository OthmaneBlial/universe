#!/usr/bin/env python3
"""Optional unchanged Alpine bash, Perl, Ruby, SQLite, jq, make, tree and file checks; run scripts/alpine.py first."""
import pathlib
import platform
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'zig-out/bin/universe'
SYSROOT = ROOT / 'artifacts/alpine-x86_64/sysroot'
WORK = SYSROOT / 'tmp/tools-check'
BASH = '''echo bash ${BASH_VERSION}
for i in 1 2 3; do printf %s $i; done; echo
arr=(a b c); echo ${#arr[@]} $(( 6*7 ))
[[ abc == a* ]] && echo glob
'''
PERL = r'''my %h = (b => 2, a => 1);
print join(",", map { "$_=$h{$_}" } sort keys %h), "\n";
printf("%.3f\n", atan2(1, 1) * 4);
print scalar(reverse("universe")), "\n";
'''
RUBY = '''puts RUBY_VERSION
puts [3, 1, 2].sort.inspect
puts (1..5).map { |x| x * x }.sum
h = {a: 1, b: 2}; puts h.map { |k, v| "#{k}=#{v}" }.join(",")
t = Thread.new { 6 * 7 }; puts t.value
'''

checks = 0
modes = [[]] + ([['--jit']] if platform.machine() in ['arm64', 'aarch64'] else [])
for mode in modes:
    shutil.rmtree(WORK, ignore_errors=True)
    (WORK / 'tree/sub').mkdir(parents=True)
    (WORK / 'tree/a.txt').write_text('a')
    (WORK / 'tree/sub/b.txt').write_text('b')
    (WORK / 'check.bash').write_text(BASH)
    (WORK / 'check.pl').write_text(PERL)
    (WORK / 'check.rb').write_text(RUBY)
    (WORK / 'Makefile').write_text('out.txt: Makefile\n\tprintf "made by make\\n" > $@\n')

    def run(*args, input=b'', output, code=0):
        global checks
        result = subprocess.run([str(RUNTIME), *mode, '--unlimited', '--allow-files', '--env', 'HOME=/tmp',
                                 '--sysroot', str(SYSROOT), *args], input=input, capture_output=True, timeout=900)
        assert (result.returncode, result.stdout) == (code, output), (mode, args, result)
        assert not result.stderr, (mode, args, result.stderr)
        checks += 1
    run('/bin/bash', '/tmp/tools-check/check.bash', output=b'bash 5.2.37(1)-release\n123\n3 42\nglob\n')
    run('/usr/bin/perl', '/tmp/tools-check/check.pl', output=b'a=1,b=2\n3.142\nesrevinu\n')
    run('/usr/bin/ruby', '/tmp/tools-check/check.rb', output=b'3.4.4\n[1, 2, 3]\n55\na=1,b=2\n42\n')
    run('/usr/bin/sqlite3', '/tmp/tools-check/t.db', 'create table t(x); insert into t values (1),(2),(3); '
        'select sum(x), count(*) from t;', output=b'6|3\n')
    run('/usr/bin/sqlite3', '/tmp/tools-check/t.db', 'select group_concat(x) from t;', output=b'1,2,3\n')
    run('/usr/bin/jq', '-c', '.a | map(. * 2)', input=b'{"a": [1, 2, 3]}', output=b'[2,4,6]\n')
    run('/usr/bin/make', '-s', '-C', '/tmp/tools-check', output=b'')
    assert (WORK / 'out.txt').read_bytes() == b'made by make\n'
    run('/usr/bin/make', '-s', '-C', '/tmp/tools-check', output=b'')  # Up to date: make reads real mtimes.
    run('/usr/bin/tree', '--noreport', '--charset=ascii', '/tmp/tools-check/tree',
        output=b'/tmp/tools-check/tree\n|-- a.txt\n`-- sub\n    `-- b.txt\n')
    result = subprocess.run([str(RUNTIME), *mode, '--unlimited', '--allow-files', '--sysroot', str(SYSROOT),
                             '/usr/bin/file', '-b', '/bin/busybox'], capture_output=True, timeout=300)
    assert result.returncode == 0 and result.stdout.startswith(b'ELF 64-bit LSB pie executable, x86-64'), result
    checks += 1
    shutil.rmtree(WORK)
print(f'Alpine tools (musl, x86-64): {checks}/{checks} unchanged checks passed; bash 5.2, Perl 5.40, Ruby 3.4 '
      'with threads, SQLite 3.49 files, jq, make with real timestamps, tree and file')
