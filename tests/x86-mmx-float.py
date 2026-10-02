#!/usr/bin/env python3
"""Exact rational results and complete physical MMX/x87 data through real encodings."""
from fractions import Fraction as Q
import pathlib
import platform
import random
import runpy
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'zig-out/bin/universe'
NUMERIC = runpy.run_path(str(ROOT / 'tests/x86-mxcsr.py'))
FORMATS, encode, quantize = (NUMERIC[name] for name in ('FORMATS', 'encode', 'quantize'))
QUERY, ANSWER = struct.Struct('<IIHBB16s16s'), struct.Struct('<16sIHHQ80sB7x')
MODES = [[]] + ([['--jit']] if platform.machine() in ('arm64', 'aarch64') else [])


def query(op, control, left, right, n=0, status=None, pending=False):
    offset = n & 15 if op in (3, 5, 7, 9) else 0
    return (op | offset << 8 | int(pending) << 24, control,
            0x4520 | (n & 7) << 11 if status is None else status,
            (0x81 + n * 17) & 255, 0, left, right)


def pair(a, b, wide):
    return struct.pack('<QQ' if wide else '<II', a, b) + (b'' if wide else b'\xff' * 8)


def expected(q):
    operation, control, status, tag, _, left, right = q
    op = operation & 255
    raw = bytearray(((reg * 31 + n * 19) ^ 0x5a) & 255 for reg in range(8) for n in range(10))
    raw[70:78] = right[:8] if op in (1, 2, 4) else left[:8]
    value, flags = left, 0
    if op == 0:
        raw[70:80] = right[:8] + b'\xff\xff'
    elif op == 1:
        value = right[:8] + b'\0' * 8
    elif op in (2, 3, 4, 5):
        wide = op in (4, 5)
        converted = []
        for integer in struct.unpack('<ii', right[:8]):
            result, more = encode(Q(integer), FORMATS[wide], control)
            converted.append(result)
            flags |= more
        value = pair(*converted, wide)
        if not wide:
            value = value[:8] + left[8:]
    else:
        wide = op >= 10
        f = FORMATS[wide]
        truncate = op in (8, 9, 12, 13)
        converted = []
        for bits in struct.unpack('<QQ' if wide else '<II', right[:16 if wide else 8]):
            bits = f.input(bits, control)
            if f.kind(bits) != 'finite':
                integer, more = 0x80000000, 1
            else:
                exact = f.value(bits)
                integer, inexact = quantize(abs(exact), Q(1), 3 if truncate else (control >> 13) & 3, exact < 0)
                integer *= -1 if exact < 0 else 1
                integer, more = (integer & 0xffffffff, 32 if inexact else 0) if -(1 << 31) <= integer < 1 << 31 else (0x80000000, 1)
            converted.append(integer)
            flags |= more
        raw[70:80] = struct.pack('<II', *converted) + b'\xff\xff'
    if op != 5:
        status, tag = status & ~0x3800, 255
    return ANSWER.pack(value, control | flags, status, 0x37e if operation & (1 << 24) else 0x37f, 0, raw, tag)


def run(mode, queries):
    return subprocess.run([str(RUNTIME), *mode, '--max-instructions', '30000000', '--timeout-ms', '30000',
                           str(ROOT / 'artifacts/guests/x86_64/mmx-float')],
                          input=b''.join(QUERY.pack(*q) for q in queries), capture_output=True, timeout=40)


def main():
    rng = random.Random(0x4d4d584650)
    queries = []
    left = bytes((n * 29 + 13) & 255 for n in range(16))
    for n in range(512):
        right = rng.randbytes(16)
        for op in (0, 1):
            queries.append(query(op, (n * 127) & 0xffff, left, right, n))
    integers = [0, 1, 0xffffffff, 0x80000000, 0x7fffffff]
    for e in (23, 24, 25, 30):
        for delta in (-1, 0, 1):
            integers.extend(((1 << e) + delta, (-(1 << e) - delta) & 0xffffffff))
    int_pairs = [(a, integers[(n * 7 + 1) % len(integers)]) for n, a in enumerate(integers)]
    int_pairs += [(rng.getrandbits(32), rng.getrandbits(32)) for _ in range(64)]
    for mode in range(4):
        for options in (0, 64, 0x8000, 0x8040):
            for n, (a, b) in enumerate(int_pairs):
                control = 0x1f80 | mode << 13 | options | (63 if n & 1 else 0)
                for op in range(2, 6):
                    queries.append(query(op, control, left, pair(a, b, False), n))
    for wide, f in enumerate(FORMATS):
        one = f.bias << f.p
        edges = [0, f.sign, 1, 1 | f.sign, (1 << f.p) - 1, 1 << f.p,
                 f.exp - 1, f.exp, f.exp | f.sign, f.exp | 1, f.exp | f.quiet | 123,
                 f.exp | f.sign | f.quiet | 321, one, one | f.sign]
        for number in (Q(1, 2), Q(3, 2), Q(5, 2), Q((1 << 31) - 1), Q(1 << 31), Q(1 << 32)):
            for sign in (-1, 1):
                bits, _ = encode(sign * number, f, 0x1f80)
                edges.extend((bits + delta) & f.mask for delta in (-2, -1, 0, 1, 2))
        cases = [(a, edges[(n * 19 + 7) % len(edges)]) for n, a in enumerate(edges)]
        cases += [(rng.getrandbits(64 if wide else 32), rng.getrandbits(64 if wide else 32)) for _ in range(64)]
        for mode in range(4):
            for options in (0, 64, 0x8000, 0x8040):
                for n, (a, b) in enumerate(cases):
                    control = 0x1f80 | mode << 13 | options | (63 if n & 1 else 0)
                    for op in range(10 if wide else 6, 14 if wide else 10):
                        queries.append(query(op, control, left, pair(a, b, wide), n))
    # Exact inputs may run with every SIMD mask clear and old sticky bits set.
    for op in range(2, 14):
        right = pair(1, 2, False) if op < 6 else pair(*[encode(Q(n), FORMATS[op >= 10], 0x1f80)[0] for n in (1, -2)], op >= 10)
        queries.append(query(op, 63, left, right))
    queries.append(query(5, 0x1f80, left, pair(0x80000000, 0x7fffffff, False), status=0x6d21, pending=True))
    answers = [expected(q) for q in queries]
    fault_cases = []
    for op in range(14):
        if op != 5:
            fault_cases.append((query(op, 0x1f80, left, bytes(16), status=0x6d21, pending=True), b'FloatingPointException'))
    for op in (2, 3):
        fault_cases.append((query(op, 0x0f80, left, pair(16777217, 1, False)), b'SimdFloatingPointException'))
    for op in range(6, 14):
        wide, f = op >= 10, FORMATS[op >= 10]
        fault_cases.append((query(op, 0x1f00, left, pair(f.exp, f.exp | 1, wide)), b'SimdFloatingPointException'))
        half = encode(Q(1, 2), f, 0x1f80)[0]
        fault_cases.append((query(op, 0x0f80, left, pair(half, half, wide)), b'SimdFloatingPointException'))
    for op in (11, 13):
        q = query(op, 0x1f80, left, bytes(16))
        fault_cases.append(((q[0] | 0x100, *q[1:]), b'MisalignedMemory'))
    for mode in MODES:
        for start in range(0, len(queries), 512):
            batch = queries[start:start + 512]
            result = run(mode, batch)
            assert result.returncode == 0 and not result.stderr, (mode, start, result.returncode, result.stderr)
            assert len(result.stdout) == len(batch) * ANSWER.size, (mode, start, len(result.stdout))
            for n, actual in enumerate(ANSWER.iter_unpack(result.stdout)):
                wanted = ANSWER.unpack(answers[start + n])
                assert actual == wanted, (mode, start + n, batch[n], actual, wanted)
        for q, error in fault_cases:
            result = run(mode, [q])
            assert result.returncode != 0 and not result.stdout and error in result.stderr, (mode, q, result.returncode, result.stderr)
        print(f'MMX floating {mode or ["interpreter"]}: {len(queries)} exact rational/state queries and {len(fault_cases)} fault exits passed', flush=True)


if __name__ == '__main__':
    main()
