#!/usr/bin/env python3
"""Independent integer/Fraction oracle for SSE results and MXCSR status bits."""
from fractions import Fraction as Q
from math import isqrt
import pathlib
import platform
import random
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'zig-out/bin/universe'


def power(n):
    return Q(1 << n) if n >= 0 else Q(1, 1 << -n)


class Format:
    def __init__(self, wide):
        self.p, self.bias = (52, 1023) if wide else (23, 127)
        self.sign = 1 << (self.p + (11 if wide else 8))
        self.exp = self.sign - (1 << self.p)
        self.quiet = 1 << (self.p - 1)
        self.mask = self.sign * 2 - 1
        self.minimum = 1 - self.bias

    def kind(self, bits):
        return ('nan' if bits & ((1 << self.p) - 1) else 'inf') if bits & self.exp == self.exp else 'finite'

    def value(self, bits):
        exponent = (bits & self.exp) >> self.p
        significand = bits & ((1 << self.p) - 1)
        if exponent:
            significand |= 1 << self.p
        return (-1 if bits & self.sign else 1) * significand * power((exponent - self.bias if exponent else self.minimum) - self.p)

    def denormal(self, bits):
        return bits & self.exp == 0 and bits & (self.sign - 1) != 0

    def input(self, bits, control):
        return bits & self.sign if self.denormal(bits) and control & 64 else bits


FORMATS = [Format(False), Format(True)]


def exponent(value):
    n = value.numerator.bit_length() - value.denominator.bit_length()
    return n - int(value < power(n))


def quantize(value, step, mode, negative, root=False):
    scaled = value / (step * step if root else step)
    if root:
        lower = isqrt(scaled.numerator // scaled.denominator)
        exact = scaled == lower * lower
        midpoint = scaled - Q((2 * lower + 1) ** 2, 4)
    else:
        lower, remainder = divmod(scaled.numerator, scaled.denominator)
        exact = remainder == 0
        midpoint = Q(remainder, scaled.denominator) - Q(1, 2)
    increment = not exact and (midpoint > 0 or midpoint == 0 and lower & 1) if mode == 0 else (
        not exact and (negative if mode == 1 else not negative) if mode in (1, 2) else False)
    return lower + increment, not exact


def encode(value, f, control, negative_zero=False, root=False):
    if value == 0:
        return (f.sign if negative_zero else 0), 0
    negative = value < 0
    value = abs(value)
    mode = (control >> 13) & 3
    e = exponent(value) // 2 if root else exponent(value)
    unlimited, _ = quantize(value, power(e - f.p), mode, negative, root)
    tiny = unlimited * power(e - f.p) < power(f.minimum)
    if unlimited * power(e - f.p) >= power(f.bias + 1):
        infinity = mode == 0 or mode == 1 and negative or mode == 2 and not negative
        return (f.sign if negative else 0) | (f.exp if infinity else f.exp - 1), 40
    step = power(max(e, f.minimum) - f.p)
    significand, inexact = quantize(value, step, mode, negative, root)
    flags = (32 if inexact else 0) | (16 if tiny and (inexact or not control & 0x800) else 0)
    if tiny and control & 0x8800 == 0x8800:
        return f.sign if negative else 0, flags | 48
    if significand == 0:
        return f.sign if negative else 0, flags
    magnitude = significand * step
    final_e = exponent(magnitude)
    if final_e < f.minimum:
        bits = int(magnitude / power(f.minimum - f.p))
    else:
        bits = ((final_e + f.bias) << f.p) | (int(magnitude / power(final_e - f.p)) - (1 << f.p))
    return bits | (f.sign if negative else 0), flags


def arithmetic(op, a, b, f, control):
    a, b = f.input(a, control), f.input(b, control)
    if op == 4:
        a = b
    ka, kb = f.kind(a), f.kind(b)
    nan_a, nan_b = ka == 'nan', kb == 'nan' and op != 4
    invalid_nan = any(f.kind(n) == 'nan' and not n & f.quiet for n in ([a] if op == 4 else [a, b]))
    if nan_a or nan_b:
        return (b if op in (5, 6) else (a if nan_a else b) | f.quiet), int(invalid_nan or op in (5, 6))
    flags = 2 if f.denormal(a) or op != 4 and f.denormal(b) else 0
    va = f.value(a) if ka == 'finite' else None
    vb = f.value(b) if kb == 'finite' else None
    sa, sb = bool(a & f.sign), bool(b & f.sign)
    if op in (5, 6):
        av = va if va is not None else (float('-inf') if sa else float('inf'))
        bv = vb if vb is not None else (float('-inf') if sb else float('inf'))
        return (a if (av < bv if op == 5 else av > bv) else b), flags
    invalid = (op == 0 and ka == kb == 'inf' and sa != sb or
               op == 1 and ka == kb == 'inf' and sa == sb or
               op == 2 and (ka == 'inf' and vb == 0 or kb == 'inf' and va == 0) or
               op == 3 and (ka == kb == 'inf' or va == vb == 0) or
               op == 4 and sa and (ka == 'inf' or va != 0))
    if invalid:
        return f.sign | f.exp | f.quiet, 1
    if op == 3 and vb == 0:
        return f.exp | (f.sign if sa != sb else 0), 4 if ka != 'inf' else 0
    if ka == 'inf' or op != 4 and kb == 'inf':
        sign = (sa if ka == 'inf' else sb != (op == 1)) if op in (0, 1) else sa != sb
        if op == 4:
            sign = sa
        if op == 3 and kb == 'inf' and ka != 'inf':
            return f.sign if sa != sb else 0, flags
        return f.exp | (f.sign if sign else 0), flags
    if op == 4:
        result, post = encode(va, f, control, sa, root=True)
    else:
        exact = [lambda: va + vb, lambda: va - vb, lambda: va * vb, lambda: va / vb][op]()
        if op <= 1:
            effective_sb = sb != (op == 1)
            negative_zero = sa and effective_sb if va == vb == 0 and sa == effective_sb else (control >> 13) & 3 == 1
        else:
            negative_zero = sa != sb
        result, post = encode(exact, f, control, negative_zero)
    return result, flags | post


def oracle(operation, control, a, b):
    wide, op = bool(operation & 256), operation & 255
    f = FORMATS[wide]
    mode = (control >> 13) & 3
    if op in (23, 24):
        value, flags = arithmetic(0 if op == 23 else 1, a, a, f, control)
        _, other = arithmetic(0 if op == 23 else 1, b, b, f, control)
        return value, control | flags | other
    if op == 25:
        value, flags = arithmetic(1, a, b, f, control)
        _, other = arithmetic(0, a, b, f, control)
        return value, control | flags | other
    if op == 26:
        value, flags = arithmetic(2, a, b, f, control)
        value, more = arithmetic(0, value, value, f, control)
        flags |= more
        if not wide:
            value, more = arithmetic(0, value, value, f, control)
            flags |= more
        return value, control | flags
    if op >= 27:
        op = {27: 0, 28: 3, 29: 4}[op]
    if op <= 6:
        value, flags = arithmetic(op, a, b, f, control)
        return value, control | flags
    if op == 7:
        value, flags = encode(Q(a - (1 << 64) if a >> 63 else a), f, control)
        return value, control | flags
    a, b = f.input(a, control), f.input(b, control)
    if op in (8, 9, 11, 12):
        bits = a if op in (8, 9) else b
        kind = f.kind(bits)
        if kind != 'finite':
            if op in (8, 9):
                return 1 << 63, control | 1
            return bits | (f.quiet if kind == 'nan' else 0), control | int(kind == 'nan' and not bits & f.quiet)
        exact = f.value(bits)
        integer, inexact = quantize(abs(exact), Q(1), 3 if op == 9 else mode, exact < 0)
        integer *= -1 if exact < 0 else 1
        if op in (8, 9):
            return ((integer & ((1 << 64) - 1), control | (32 if inexact else 0)) if -(1 << 63) <= integer < 1 << 63 else (1 << 63, control | 1))
        value, _ = encode(Q(integer), f, control, bool(bits & f.sign))
        return value, control | (32 if inexact and op == 11 else 0)
    if op == 10:
        dst = FORMATS[not wide]
        kind = f.kind(a)
        if kind != 'finite':
            payload = a & ((1 << f.p) - 1)
            payload = payload << 29 if not wide else payload >> 29
            return dst.exp | payload | (dst.quiet if kind == 'nan' else 0) | (dst.sign if a & f.sign else 0), control | int(kind == 'nan' and not a & f.quiet)
        value, flags = encode(f.value(a), dst, control, bool(a & f.sign))
        return value, control | flags | (2 if f.denormal(a) else 0)
    unordered = f.kind(a) == 'nan' or f.kind(b) == 'nan'
    signaling = op == 13 or op in (16, 17, 20, 21)
    flags = int(unordered and (signaling or any(f.kind(n) == 'nan' and not n & f.quiet for n in [a, b])))
    if not unordered:
        flags |= 2 if f.denormal(a) or f.denormal(b) else 0
        av = f.value(a) if f.kind(a) == 'finite' else (float('-inf') if a & f.sign else float('inf'))
        bv = f.value(b) if f.kind(b) == 'finite' else (float('-inf') if b & f.sign else float('inf'))
        less, equal = av < bv, av == bv
    else:
        less = equal = False
    if op in (13, 14):
        value = 69 if unordered else 1 if less else 64 if equal else 0
    else:
        yes = [not unordered and equal, not unordered and less, not unordered and (less or equal), unordered,
               unordered or not equal, unordered or not less, unordered or not less and not equal, not unordered][op - 15]
        value = f.mask if yes else 0
    return value, control | flags


queries = []
for wide, f in enumerate(FORMATS):
    one, half = f.bias << f.p, (f.bias - 1) << f.p
    edges = [(one, one), (one, half), (one, (f.bias - f.p - 1) << f.p), (one | f.sign, ((f.bias - f.p - 1) << f.p) | f.sign),
             (1, one), (1, 1), (1, half), (1 | f.sign, half), (1 << f.p, half),
             (1 << f.p, one - 1), ((1 << f.p) | f.sign, one - 1), (f.exp - 1, one + (1 << f.p)),
             (0, 0), (0, f.sign), (f.exp, f.exp | f.sign), (one, 0),
             (f.exp | f.quiet | 123, one), (one, f.exp | 123), (f.exp | f.quiet | 123, f.exp | 321 | f.sign), (1, 0), (one, 1 | f.sign),
             (f.exp, 1), (f.exp | f.quiet | 123, 1), (1, f.exp)]
    for mode in range(4):
        control = 0x1f80 | mode << 13
        for op in [*range(23), *range(27, 30)]:
            for a, b in edges:
                queries.append((op | wide << 8, control, a, b))
        for op in (7,):
            for integer in [0, 1, (1 << 24) + 1, (1 << 53) + 1, (1 << 63) - 1, 1 << 63, (1 << 64) - 3]:
                queries.append((op | wide << 8, control, integer, 0))
        for options in (64, 0x8000, 0x8040):
            for op in (0, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 27, 28, 29):
                for a, b in edges[4:11]:
                    queries.append((op | wide << 8, control | options, a, b))
        for op in (23, 24, 25, 26):
            for a, b in edges[:12]:
                queries.append((op | wide << 8, control, a, b))
        rng = random.Random(0x535345 + wide)
        for op in (0, 1, 2, 3, 4, 10):
            for _ in range(24):
                a, b = [rng.randrange(f.exp) | (f.sign if rng.randrange(2) else 0) for _ in range(2)]
                queries.append((op | wide << 8, control, a, b))
    for mode in range(4):
        queries.append((wide << 8, (mode << 13) | 63, one, one))  # Old unmasked sticky bits do not trap.
    queries.append((wide << 8, 0x1fbf, one, one))  # Existing sticky bits survive exact arithmetic.

expected = [oracle(*query) for query in queries]
stdin = b''.join(struct.pack('<IIQQ', *query) for query in queries)
modes = [[]] + ([['--jit']] if platform.machine() in ('arm64', 'aarch64') else [])
for mode in modes:
    run = subprocess.run([str(RUNTIME), *mode, '--max-instructions', '30000000', '--timeout-ms', '30000',
                          str(ROOT / 'artifacts/guests/x86_64/mxcsr')], input=stdin, capture_output=True, timeout=40)
    assert run.returncode == 0 and not run.stderr, (mode, run.returncode, len(run.stdout), run.stderr)
    assert len(run.stdout) == len(queries) * 12, (len(run.stdout), len(queries) * 12)
    mismatches = [(n, actual) for n, actual in enumerate(struct.iter_unpack('<QI', run.stdout)) if actual != expected[n]]
    assert not mismatches, '\n'.join(f'{mode} query {n} op/control/a/b={tuple(hex(v) for v in queries[n])}: actual={tuple(hex(v) for v in actual)}, expected={tuple(hex(v) for v in expected[n])}' for n, actual in mismatches[:8]) + f'\n{len(mismatches)} mismatches'
print(f'SSE MXCSR: {len(queries)} exact rational/bit oracles per engine passed; four rounding modes, DAZ/FTZ, NaNs, conversions, compares, packed arithmetic and dot products')
