#!/usr/bin/env python3
"""Record a real UNIVERSE terminal session and render it as an animated SVG.

  python3 scripts/demo.py record python|alpine   # needs scripts/python.py or scripts/alpine.py
  python3 scripts/demo.py render python|alpine   # needs `pip install pyte`

The recording is an asciicast v2 file of the actual pseudo-terminal bytes with
real timestamps. Rendering only shortens idle waits (labelled in the caption).
"""
import html
import json
import os
import pathlib
import pty
import select
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
COLUMNS, ROWS = 78, 16
# Each scene runs from `cwd`; its first frame shows exactly `shown`, the command that runs.
SCENES = {
    'python': {
        'name': 'python-repl', 'cwd': 'artifacts/python-x86_64', 'prompt': b'>>> ',
        'title': 'x86-64 Linux CPython on ARM64 macOS',
        'command': ['--unlimited', '--allow-files', '--env', 'TERM=xterm-256color', '--env', 'PYTHON_BASIC_REPL=1',
                    '--sysroot', 'sysroot', '/opt/python/bin/python3'],
        'shown': ('$ universe --unlimited --allow-files --env TERM=xterm-256color \\\r\n'
                  '    --env PYTHON_BASIC_REPL=1 --sysroot sysroot /opt/python/bin/python3\r\n'),
        'inputs': ['import platform, sys', 'platform.machine(), sys.platform', 'sum(i * i for i in range(10**5))',
                   'import sqlite3', 'sqlite3.connect(":memory:").execute("select 6*7").fetchone()', 'exit()'],
    },
    'alpine': {
        'name': 'alpine-shell', 'cwd': 'artifacts/alpine-x86_64', 'prompt': b'$ ',
        'title': 'Alpine Linux x86-64 shell on ARM64 macOS',
        'command': ['--unlimited', '--allow-files', '--env', 'TERM=xterm-256color', '--env', 'PS1=alpine:\\w$ ',
                    '--sysroot', 'sysroot', '/bin/sh', '-i'],
        'shown': ("$ universe --unlimited --allow-files --env TERM=xterm-256color \\\r\n"
                  "    --env 'PS1=alpine:\\w$ ' --sysroot sysroot /bin/sh -i\r\n"),
        'inputs': ['uname -sm; cat /etc/alpine-release', 'git --version; vim --version | head -1',
                   'echo "6*7" | lua5.4 -e "print(load(\'return \' .. io.read())())"',
                   'ls /usr/bin | wc -l', 'exit'],
    },
}
SCENE = SCENES[sys.argv[2] if len(sys.argv) > 2 else 'python']
CAST = ROOT / f"docs/assets/{SCENE['name']}.cast"
SVG = ROOT / f"docs/assets/{SCENE['name']}.svg"
COMMAND, SHOWN, INPUTS = SCENE['command'], SCENE['shown'], SCENE['inputs']


def record():
    pid, terminal = pty.fork()
    if pid == 0:
        os.chdir(ROOT / SCENE['cwd'])
        os.execv(str(ROOT / 'zig-out/bin/universe'), ['universe', *COMMAND])
    os.set_blocking(terminal, False)
    start = time.time()
    events = [[0.0, 'o', SHOWN]]
    data = b''

    status = []

    def exited():
        if not status:
            done, code = os.waitpid(pid, os.WNOHANG)
            if done:
                status.append(code)
        return bool(status)

    def pump(until, seconds=900):
        nonlocal data
        deadline = time.time() + seconds
        while not until(data) and time.time() < deadline:
            if exited():
                return
            if select.select([terminal], [], [], 0.2)[0]:
                try:
                    chunk = os.read(terminal, 65536)
                except OSError:
                    return
                data += chunk
                events.append([round(time.time() - start, 3), 'o', chunk.decode('utf-8', 'replace')])
    for line in INPUTS:
        pump(lambda d: SCENE['prompt'] in d[-24:])  # line editors may append terminal escapes after the prompt.
        pump(lambda d: False, 0.8)
        for key in line:
            os.write(terminal, key.encode())
            pump(lambda d: False, 0.07)
        data = b''  # Clear before Enter so a fast reply's next prompt is not discarded.
        os.write(terminal, b'\r')
    pump(lambda d: None, 60)
    if not exited():
        os.waitpid(pid, 0)
    header = {'version': 2, 'width': COLUMNS, 'height': ROWS, 'timestamp': int(start),
              'title': f"UNIVERSE: {SCENE['title']}"}
    CAST.write_text('\n'.join([json.dumps(header)] + [json.dumps(e, ensure_ascii=False) for e in events]) + '\n')
    print(f'Recorded {len(events)} events over {events[-1][0]:.1f} s, exit status {status}: {CAST}')
    print(repr(''.join(e[2] for e in events)[-300:]))


PALETTE = {'magenta': '#f472d0', 'blue': '#7aa2ff', 'green': '#7ee2a8', 'red': '#ff7a7a', 'cyan': '#6fe3ef',
           'yellow': '#ffd166', 'brightmagenta': '#f472d0', 'default': '#e6e9f2'}


def render():
    import pyte
    lines = CAST.read_text().splitlines()
    screen = pyte.Screen(COLUMNS, ROWS)
    stream = pyte.ByteStream(screen)
    frames, clock, last = [], 0.0, None
    for line in lines[1:]:
        at, _, text = json.loads(line)
        gap = at - last if last is not None else 0.0
        clock += min(gap, 1.2)  # Idle waits (mostly interpreter startup) are shortened.
        last = at
        stream.feed(text.encode())
        rows = []
        for y in range(ROWS):
            spans, current, color = [], '', None
            for x in range(COLUMNS):
                char = screen.buffer[y][x]
                fg = char.fg if char.fg in PALETTE else 'default'
                if fg != color and current:
                    spans.append((color, current))
                    current = ''
                color = fg
                current += char.data
            spans.append((color, current))
            rows.append(spans)
        cursor = (screen.cursor.x, screen.cursor.y)
        if frames and frames[-1][1] == rows:
            continue
        frames.append((clock, rows, cursor))
    total = frames[-1][0] + 4.0
    actual = json.loads(lines[-1])[0]
    out = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {COLUMNS * 9 + 32} {ROWS * 19 + 74}" '
           f'role="img" aria-label="Recorded terminal: {SCENE["title"]} under UNIVERSE">',
           '<style>text{font:15px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre}'
           '.f{opacity:0;animation:show %.2fs steps(1) infinite}</style>' % total,
           f'<rect width="100%" height="100%" rx="12" fill="#0d1020"/>',
           '<circle cx="22" cy="20" r="6" fill="#ff5f57"/><circle cx="42" cy="20" r="6" fill="#febc2e"/><circle cx="62" cy="20" r="6" fill="#28c840"/>',
           '<text x="84" y="25" fill="#8b93b0" style="font-size:12px">'
           f"{SCENE['title']} · real {actual:.0f} s session, waits shortened</text>"]
    keyframes = []
    for index, (start, rows, (cx, cy)) in enumerate(frames):
        end = frames[index + 1][0] if index + 1 < len(frames) else total
        a, b = 100 * start / total, 100 * end / total
        keyframes.append(f'@keyframes k{index}{{0%,{a:.3f}%{{opacity:0}}{a:.3f}%,{b:.3f}%{{opacity:1}}{b:.3f}%,100%{{opacity:0}}}}')
        out.append(f'<g class="f" style="animation-name:k{index}">')
        for y, spans in enumerate(rows):
            if not ''.join(t for _, t in spans).strip():
                continue
            tspans = ''.join(f'<tspan fill="{PALETTE[c]}">{html.escape(t)}</tspan>' for c, t in spans)
            out.append(f'<text x="16" y="{58 + y * 19}" xml:space="preserve">{tspans}</text>')
        out.append(f'<rect x="{16 + cx * 9}" y="{45 + cy * 19}" width="9" height="17" fill="#e6e9f2" opacity=".55"/></g>')
    out.insert(2, '<style>' + ''.join(keyframes) + '</style>')
    out.append('</svg>')
    SVG.write_text('\n'.join(out) + '\n')
    print(f'Rendered {len(frames)} frames, {total:.1f} s loop: {SVG} ({SVG.stat().st_size} bytes)')


if __name__ == '__main__':
    {'record': record, 'render': render}[sys.argv[1] if len(sys.argv) > 1 else 'render']()
