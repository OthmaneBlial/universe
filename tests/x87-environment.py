#!/usr/bin/env python3
"""Independent byte/layout oracle for x87 environments and full state images."""
import pathlib
import platform
import random
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'zig-out/bin/universe'
GUEST = ROOT / 'artifacts/guests/x86_64/x87-environment'
INTEGER, SIGN = 1 << 63, 1 << 79
VALUES = [0x3fff << 64 | INTEGER | 7, 0, SIGN, 1, INTEGER,
          0x7fff << 64 | INTEGER, 0xffff << 64 | INTEGER | 1 << 62 | 9,
          0x3fff << 64 | 3]


def summary(s):
    return (s['sw'] & ~0x8080) | (0x8080 if s['sw'] & ~s['cw'] & 63 else 0)


def full_tag(s):
    tags = []
    for slot, raw in enumerate(s['raw']):
        exp, sig = raw >> 64 & 0x7fff, raw & ((1 << 64) - 1)
        tags.append(3 if not s['tag'] >> slot & 1 else 1 if exp == sig == 0 else
                    2 if exp in (0, 0x7fff) or not sig & INTEGER else 0)
    return sum(tag << (2 * n) for n, tag in enumerate(tags))


def environment(s, short, full=False, tags=None):
    tags = full_tag(s) if tags is None else tags
    if short:
        header = struct.pack('<7H', s['cw'], s['sw'], tags, s['ip'] & 0xffff,
                             s['cs'], s['dp'] & 0xffff, s['ds'])
    else:
        header = struct.pack('<H2xH2xH2xIHHIH2x', s['cw'], s['sw'], tags,
                             s['ip'] & 0xffffffff, s['cs'], s['fop'] & 0x7ff,
                             s['dp'] & 0xffffffff, s['ds'])
    top = s['sw'] >> 11 & 7
    return header + (b''.join(s['raw'][(top + n) & 7].to_bytes(10, 'little')
                              for n in range(8)) if full else b'')


def restore(s, image, short, full):
    result = dict(s)
    result['raw'] = list(s['raw'])
    if short:
        cw, sw, tags, ip, cs, dp, ds = struct.unpack_from('<7H', image)
        header, fop = 14, s['fop']  # No FOP field in the protected 16-bit layout.
    else:
        cw, sw, tags, ip, cs, fop, dp, ds = struct.unpack_from('<H2xH2xH2xIHHIH2x', image)
        header, fop = 28, fop & 0x7ff
    result.update(cw=cw, sw=sw, tag=sum((tags >> (2 * n) & 3 != 3) << n for n in range(8)),
                  ip=ip, cs=cs, dp=dp, ds=ds, fop=fop)
    if full:
        top = sw >> 11 & 7
        for n in range(8):
            result['raw'][(top + n) & 7] = int.from_bytes(image[header + n * 10:header + (n + 1) * 10], 'little')
    result['sw'] = summary(result)
    return result


def fx_image(s):
    image = bytearray(416) + bytearray(b'\xa5' * 96)
    struct.pack_into('<HHBxHQQII', image, 0, s['cw'], s['sw'], s['tag'], s['fop'],
                     s['ip'], s['dp'], s['mxcsr'], 0xffff)
    top = s['sw'] >> 11 & 7
    for n in range(8):
        image[32 + n * 16:42 + n * 16] = s['raw'][(top + n) & 7].to_bytes(10, 'little')
    image[160:416] = s['xmm']
    return bytes(image)


def initial(top, tag, seed=0):
    return dict(cw=0x7f | (seed & 3) << 8 | (seed >> 2 & 3) << 10,
                sw=0x4700 | top << 11 | seed & 63, tag=tag, fop=seed & 0x7ff,
                ip=0xabcdef0123456789, dp=0xfedcba9876543210, cs=0, ds=0,
                mxcsr=0xff7f, raw=VALUES[seed & 7:] + VALUES[:seed & 7],
                xmm=bytes((n + seed) & 255 for n in range(256)))


queries, expected = [], []


def add(operation, short, state, incoming=None, tags=None):
    target = incoming or initial((state['sw'] >> 11 & 7) + 3 & 7, state['tag'] ^ 0xa5, 23)
    target = dict(target, ip=0x89abcdef, dp=0x76543210, cs=0x33, ds=0x2b,
                  fop=0xf357, raw=list(reversed(target['raw'])))
    image = environment(target, short, True, tags)
    image += b'\x5a' * (108 - len(image))
    queries.append(struct.pack('<4I', operation, short, 0, 0) + fx_image(state) + image)
    post, output = dict(state), bytearray(b'\xa5' + image + b'\xa5')
    op = {4: 0, 5: 2, 6: 2, 7: 0}.get(operation, operation)
    if op in (0, 2):
        saved = environment(state, short, op == 2)
        output[1:1 + len(saved)] = saved
        if op == 2:
            post.update(cw=0x37f, sw=0, tag=0, fop=0, ip=0, dp=0, cs=0, ds=0)
        else:
            post['cw'] |= 63
            post['sw'] = summary(post)
    else:
        assert not state['sw'] & ~state['cw'] & 63
        post = restore(state, image, short, op == 3)
    if operation in (6, 7):
        post = restore(post, output[1:], short, operation == 6)
    expected.append(fx_image(post) + output + environment(post, False))
    assert len(queries[-1]) == 636 and len(expected[-1]) == 650


for short in (False, True):
    for top in range(8):
        for tag in range(256):
            s = initial(top, tag, tag)
            for operation in range(4):
                add(operation, short, s)
        for tag in range(0, 256, 17):
            for operation in range(4, 8):
                add(operation, short, initial(top, tag, tag))

# Every tag class is deliberately loaded over mismatching raw register values.
# Only emptiness survives; a subsequent store classifies the actual contents.
rng = random.Random(0xd9dd)
tag_words = [0, 0x5555, 0xaaaa, 0xffff] + [rng.randrange(65536) for _ in range(128)]
for short in (False, True):
    for top in range(8):
        for tags in tag_words:
            for operation in (1, 3):
                add(operation, short, initial(top, 0xa5), tags=tags)
    for flag in (1, 2, 4, 8, 16, 32, 63):
        for top in range(8):
            s = initial(top, 0xa5)
            s.update(cw=0x37f & ~flag, sw=0x4700 | top << 11 | flag | 0x8080)
            for operation in (0, 2, 6, 7):
                add(operation, short, s)
            target = dict(s)
            for operation in (1, 3):
                add(operation, short, initial(top, 0xa5), incoming=target)

stdin = b''.join(queries)
modes = [[]] + ([['--jit']] if platform.machine() in ('arm64', 'aarch64') else [])
for mode in modes:
    command = [str(RUNTIME), *mode, '--max-instructions', '100000000', '--timeout-ms', '60000', str(GUEST)]
    run = subprocess.run(command, input=stdin, capture_output=True, timeout=75)
    assert run.returncode == 0 and not run.stderr, (mode, run.returncode, len(run.stdout), run.stderr)
    assert len(run.stdout) == len(expected) * 650, (len(run.stdout), len(expected) * 650)
    for n, wanted in enumerate(expected):
        actual = run.stdout[n * 650:(n + 1) * 650]
        if actual != wanted:
            first = next(i for i, pair in enumerate(zip(actual, wanted)) if pair[0] != pair[1])
            raise AssertionError(f'{mode} query {n} op/layout={struct.unpack_from("<2I", queries[n])} byte={first}: actual={actual[first:first + 12].hex()} expected={wanted[first:first + 12].hex()}')
    for operation in (1, 3, 4, 5):
        for short in (False, True):
            pending = initial(3, 0xa5)
            pending.update(cw=0x37e, sw=0x9881)
            data = struct.pack('<4I', operation, short, 0, 0) + fx_image(pending) + bytes(108)
            fault = subprocess.run(command, input=data, capture_output=True, timeout=10)
            assert fault.returncode == 125 and not fault.stdout and b'FloatingPointException' in fault.stderr, (mode, operation, short, fault)
    print(f'x87 environments: {len(queries)} exact image/state queries and 8 deferred faults passed ({"JIT" if mode else "interpreter"})', flush=True)

print('Native x87 hardware parity remains unverified on this host' if platform.machine() not in ('x86_64', 'AMD64') else 'Environment oracle uses specification-defined fields; native differential execution is separate')
