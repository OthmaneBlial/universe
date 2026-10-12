#!/usr/bin/env python3
"""Optional unchanged Alpine vim 9.1, Lua 5.4 and htop 3.4 checks; run scripts/alpine.py first."""
import hashlib
import os
import pathlib
import platform
import pty
import select
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'zig-out/bin/universe'
SYSROOT = ROOT / 'artifacts/alpine-x86_64/sysroot'
for name, expected in {
    'usr/bin/vim': 'a640aef1cf0867f154c85ed8cf751ad29753b46aba820826015580954dfac211',
    'usr/bin/lua5.4': '5a4f62b98035ec33bc875b4ea3a8da5675b588597c212a0a9fdc4bf760f4f6ac',
    'usr/bin/htop': '163909e32d7e9ab56371eb40ea555ee6e7efa201305166f5818ab87b093b9e2b',
}.items():
    assert hashlib.sha256((SYSROOT / name).read_bytes()).hexdigest() == expected, name
LUA = r'''
local t = {}
for word in ("the quick brown fox"):gmatch("%a+") do t[#t + 1] = word:upper() end
table.sort(t)
local co = coroutine.wrap(function() for i = 1, 3 do coroutine.yield(i * i) end end)
print(table.concat(t, ","), co() + co() + co(), string.format("%.5f", math.sqrt(2)), 2^53 // 3, utf8.len("héllo"))
local f = assert(io.open("/tmp/lua-check.txt", "w")); f:write("lua\n"); f:close()
print(io.open("/tmp/lua-check.txt"):read("a"), os.remove("/tmp/lua-check.txt"))
'''

checks = 0
modes = [[]] + ([['--jit']] if platform.machine() in ['arm64', 'aarch64'] else [])


def command(mode, *args, env=()):
    flags = [item for pair in env for item in ('--env', pair)]
    return [str(RUNTIME), *mode, '--unlimited', '--allow-files', *flags, '--sysroot', str(SYSROOT), *args]


def run(mode, *args, output, code=0):
    global checks
    result = subprocess.run(command(mode, *args), capture_output=True, timeout=300)
    assert (result.returncode, result.stdout) == (code, output), (mode, args, result)
    assert b'UNIVERSE' not in result.stderr, result.stderr
    checks += 1


for mode in modes:
    run(mode, '/usr/bin/lua5.4', '-e', LUA, output=b'BROWN,FOX,QUICK,THE\t14\t1.41421\t3.0023997515803e+15\t5\nlua\n\ttrue\n')
    run(mode, '/usr/bin/lua5.4', '-e', 'error("boom")', output=b'', code=1)
    run(mode, '/usr/bin/htop', '--version', output=b'htop 3.4.1-3.4.1\n')
    # Batch ex mode: a real substitution and write through vim's own file code.
    target = SYSROOT / 'tmp/vim-check.txt'
    target.write_bytes(b'alpha\nbeta\ngamma\n')
    run(mode, '/usr/bin/vim', '-u', 'NONE', '-es', '-c', '%s/a$/A/', '-c', 'wq', '/tmp/vim-check.txt', output=b'')
    assert target.read_bytes() == b'alphA\nbetA\ngammA\n', target.read_bytes()
    # Full-screen vim on a real pseudo-terminal: draw, insert a line, write and quit.
    target.write_bytes(b'first line\n')
    pid, terminal = pty.fork()
    if pid == 0:
        os.chdir(ROOT)
        os.execv(str(RUNTIME), command(mode, '/usr/bin/vim', '-u', 'NONE', '/tmp/vim-check.txt',
                                       env=('TERM=xterm-256color', 'HOME=/tmp')))
    screen, deadline = b'', time.time() + 300
    while b'vim-check.txt' not in screen and time.time() < deadline:
        if select.select([terminal], [], [], 0.3)[0]:
            screen += os.read(terminal, 65536)
    assert b'vim-check.txt' in screen and b'\x1b[?1049h' in screen, screen[-400:]
    for keys in [b'G', b'o', b'hello from x86-64 vim', b'\x1b', b':wq\r']:
        time.sleep(0.3)
        os.write(terminal, keys)
    deadline = time.time() + 120
    while not (exited := os.waitpid(pid, os.WNOHANG))[0]:
        assert time.time() < deadline, ('vim did not exit', screen[-400:])
        if select.select([terminal], [], [], 0.2)[0]:
            try:
                screen += os.read(terminal, 65536)
            except OSError:
                pass
    os.close(terminal)
    assert os.waitstatus_to_exitcode(exited[1]) == 0, (mode, exited)
    assert target.read_bytes() == b'first line\nhello from x86-64 vim\n', target.read_bytes()
    target.unlink()
    checks += 1
print(f'Alpine terminal apps (musl, x86-64): {checks}/{checks} unchanged checks passed; Lua 5.4 scripts, '
      'files and errors, htop version, vim ex-mode substitution and full-screen vim editing on a pseudo-terminal')
