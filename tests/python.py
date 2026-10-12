#!/usr/bin/env python3
"""Optional unchanged CPython 3.13 checks; run scripts/python.py first."""
import hashlib
import pathlib
import platform
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'zig-out/bin/universe'
SYSROOT = ROOT / 'artifacts/python-x86_64/sysroot'
for name, expected in {
    'opt/python/bin/python3.13': '4b48a2061e1f3c83201ac538fd8a87c94089f815c5e489a2e59a9f3d801f90cc',
    'opt/python/lib/libpython3.13.so.1.0': '65e9a0bb235617539b4905b062947d7568d82c14bc50e1a1511b14bb23a31564',
    'lib/ld-musl-x86_64.so.1': '1cc5c3f502179e2a4befae29658fb109102effefc75742893aa4a449fd3fbb03',
}.items():
    assert hashlib.sha256((SYSROOT / name).read_bytes()).hexdigest() == expected, name

WORKLOAD = r'''
import dataclasses, decimal, hashlib, json, os, re, sqlite3, sys, threading, zlib
print(sys.version_info[:3], sys.platform, sys.executable)
print(json.dumps({"a": [1, 2, {"b": None}]}, sort_keys=True))
print(re.findall(r"\d+", "a1b22c333"), hashlib.sha256(b"universe").hexdigest()[:16])
data = b"UNIVERSE " * 1000
print(len(zlib.compress(data)), zlib.decompress(zlib.compress(data)) == data)
db = sqlite3.connect(":memory:")
db.execute("create table t(x)")
db.executemany("insert into t values (?)", [(n,) for n in range(100)])
print(db.execute("select count(*), sum(x) from t").fetchone())
results = []
workers = [threading.Thread(target=lambda n=n: results.append(n * n)) for n in range(4)]
for worker in workers: worker.start()
for worker in workers: worker.join()
print(sorted(results), decimal.Decimal(1) / 7)
@dataclasses.dataclass
class Point:
    x: int
    y: int
print(Point(1, 2), f"{2**100:,}", sum(i * i for i in range(10000)))
with open("/tmp/universe-python.txt", "w", encoding="utf-8") as f: f.write("héllo, univers 🚀\n")
print(open("/tmp/universe-python.txt", encoding="utf-8").read().upper(), end="")
os.remove("/tmp/universe-python.txt")
print(os.getcwd(), "done")
'''
EXPECTED = '''(3, 13, 16) linux /opt/python/bin/python3
{"a": [1, 2, {"b": null}]}
['1', '22', '333'] 327a7380d2cc7cf0
53 True
(100, 4950)
[0, 1, 4, 9] 0.1428571428571428571428571429
Point(x=1, y=2) 1,267,650,600,228,229,401,496,703,205,376 333283335000
HÉLLO, UNIVERS 🚀
/tmp done
'''.encode()

checks = 0
modes = [[]] + ([['--jit']] if platform.machine() in ['arm64', 'aarch64'] else [])
for mode in modes:
    def run(code, output, status=0, error=None):
        global checks
        # The guest's working directory must be inside its sysroot, as under chroot.
        result = subprocess.run([str(RUNTIME), *mode, '--allow-files', '--sysroot', '..', '--timeout-ms', '0',
                                 '--max-instructions', '20000000000', '../opt/python/bin/python3', '-c', code],
                                cwd=SYSROOT / 'tmp', capture_output=True, timeout=900)
        assert result.returncode == status, (mode, code, result.returncode, result.stdout, result.stderr)
        assert result.stdout == output, (mode, code, result.stdout)
        assert result.stderr.endswith(error) if error else not result.stderr, (mode, code, result.stderr)
        checks += 1
    run(WORKLOAD, EXPECTED)
    run('import sys; print("exit"); sys.exit(3)', b'exit\n', status=3)
    run('raise ValueError("boom")', b'', status=1, error=b'ValueError: boom\n')
print(f'CPython 3.13.16 (musl, x86-64): {checks}/{checks} unchanged interpreter checks passed; '
      'json, re, hashlib, zlib, sqlite3, threads, decimal, dataclasses, Unicode files, exit status and tracebacks')
