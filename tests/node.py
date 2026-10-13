#!/usr/bin/env python3
"""Optional unchanged Alpine Node.js 22 checks; run `scripts/alpine.py --node` first."""
import hashlib
import pathlib
import platform
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'zig-out/bin/universe'
SYSROOT = ROOT / 'artifacts/alpine-x86_64/sysroot'
assert hashlib.sha256((SYSROOT / 'usr/bin/node').read_bytes()).hexdigest() == \
    'a4b585b338f114850bc4f41cb0f33d2311722cdeded1b54f23e4a9df771d98af', 'unexpected node binary'
SCRIPT = r'''
const fs = require('fs'), crypto = require('crypto'), zlib = require('zlib'), os = require('os');
fs.writeFileSync('/tmp/node-check/out.txt', 'héllo from node\n');
console.log(fs.readFileSync('/tmp/node-check/out.txt', 'utf8').trim().toUpperCase());
console.log(crypto.createHash('sha256').update('universe').digest('hex').slice(0, 16));
console.log(zlib.gunzipSync(zlib.gzipSync(Buffer.from('x'.repeat(1000)))).length);
console.log(JSON.stringify({ a: [1, 2, { b: null }] }), [3, 1, 2].sort().join(','), String(2n ** 64n));
console.log(process.arch, process.platform, os.cpus().length, process.argv.slice(2).join(','));
const events = [];
setTimeout(() => events.push('timer'), 5);
(async () => { await new Promise(resolve => setImmediate(resolve)); events.push('async'); })();
process.on('exit', code => console.log(events.sort().join(','), code));
process.exitCode = 3;
'''

checks = 0
modes = [[]] + ([['--jit']] if platform.machine() in ['arm64', 'aarch64'] else [])
for mode in modes:
    work = SYSROOT / 'tmp/node-check'
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    (work / 'check.js').write_text(SCRIPT)

    def node(*args, output, code=0, error=None):
        global checks
        result = subprocess.run([str(RUNTIME), *mode, '--unlimited', '--allow-files', '--sysroot', str(SYSROOT),
                                 '/usr/bin/node', *args], capture_output=True, timeout=900)
        assert result.returncode == code and result.stdout == output, (mode, args, result)
        assert (error in result.stderr) if error else not result.stderr, (mode, args, result.stderr)
        checks += 1
    # V8 generates x86-64 code at runtime; UNIVERSE executes it like any other guest code.
    node('-e', 'console.log(6 * 7, typeof WebAssembly)', output=b'42 object\n')
    node('/tmp/node-check/check.js', 'mac', 'arm', output=(
        'HÉLLO FROM NODE\n327a7380d2cc7cf0\n1000\n{"a":[1,2,{"b":null}]} 1,2,3 18446744073709551616\n'
        'x64 linux 1 mac,arm\nasync,timer 3\n').encode(), code=3)
    assert (work / 'out.txt').read_text(encoding='utf-8') == 'héllo from node\n'
    node('-e', 'throw new Error("boom")', output=b'', code=1, error=b'Error: boom')
    shutil.rmtree(work)
print(f'Node.js 22.23 (Alpine musl, x86-64): {checks}/{checks} unchanged checks passed; V8 JIT code, fs, crypto, '
      'zlib, BigInt, timers, promises, exit codes and uncaught errors')
