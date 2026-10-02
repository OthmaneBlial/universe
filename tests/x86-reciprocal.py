#!/usr/bin/env python3
"""Independent rational/ISQRT checks for legacy SSE reciprocal approximations."""
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
GUEST = ROOT / 'artifacts/guests/x86_64/reciprocal'
CONTROLS = [0x1f80, 0, 0x7f, 0x3fbf, 0x5fc0, 0x7fc0, 0x9f80, 0xffbf]
BOUND = Q(3, 8192)
RNG = random.Random(0x5243505253515254)


def power(n):
    return Q(1 << n) if n >= 0 else Q(1, 1 << -n)


def value(bits):
    exponent = (bits >> 23) & 255
    significand = bits & 0x7fffff
    if exponent:
        significand |= 1 << 23
    return (-1 if bits & 0x80000000 else 1) * significand * power((exponent - 127 if exponent else -126) - 23)


def nearest(magnitude, root=False):
    """Round a positive rational (or its root) using exact midpoint comparisons."""
    e = magnitude.numerator.bit_length() - magnitude.denominator.bit_length()
    e -= magnitude < power(e)
    if root:
        e //= 2
    scaled = magnitude / power((2 if root else 1) * (e - 23))
    if root:
        lower = isqrt(scaled.numerator // scaled.denominator)
        midpoint = scaled - Q((2 * lower + 1) ** 2, 4)
    else:
        lower, remainder = divmod(scaled.numerator, scaled.denominator)
        midpoint = Q(remainder, scaled.denominator) - Q(1, 2)
    significand = lower + int(midpoint > 0 or midpoint == 0 and lower & 1)
    if significand == 1 << 24:
        significand >>= 1
        e += 1
    assert -126 <= e <= 127, (magnitude, root, e)
    return ((e + 127) << 23) | (significand - (1 << 23))


def result(bits, root):
    sign, magnitude = bits & 0x80000000, bits & 0x7fffffff
    exponent = magnitude >> 23
    if exponent == 255 and magnitude & 0x7fffff:
        return bits | 0x400000
    if exponent == 0:
        return sign | 0x7f800000
    if root and sign:
        return 0xffc00000
    if magnitude == 0x7f800000:
        return sign
    reciprocal = 1 / abs(value(bits))
    if not root and reciprocal < power(-126):
        return sign
    return nearest(reciprocal, root) | sign


queries = []


def add(op, left, right, control=0x1f80, offset=0):
    queries.append((op, offset, control, tuple(left), tuple(right)))


edges = [0, 0x80000000, 1, 0x807fffff, 0x007fffff, 0x00800000, 0x00800001,
         0x3f800000, 0xbf800000, 0x3f000000, 0xbf000000, 0x40400000, 0xc0400000,
         0x7f800000, 0xff800000, 0x7f800001, 0xff800001, 0x7fc12345, 0xffc12345,
         0x7f7fffff, 0xff7fffff, 0x7e7ff400, 0x7e7fffff, 0x7e800000, 0x7e800001, 0x7e800c01]
for control in CONTROLS:
    for n in range(len(edges)):
        left = [edges[(n + lane) % len(edges)] for lane in range(4)]
        right = [edges[(n * 7 + lane) % len(edges)] for lane in range(4)]
        for op in range(12):
            add(op, left, right, control)
for exponent in range(1, 255):
    for fraction in (0, 1, 2, 0x12345, 0x1fffff, 0x3fffff, 0x555555, 0x7ffffe, 0x7fffff):
        bits = exponent << 23 | fraction
        left = [bits, bits ^ 0x80000000, bits, bits ^ 0x80000000]
        right = list(reversed(left))
        for op in range(12):
            add(op, left, right, CONTROLS[(exponent + fraction + op) % len(CONTROLS)])
for n in range(2000):
    left, right = [RNG.getrandbits(32) for _ in range(4)], [RNG.getrandbits(32) for _ in range(4)]
    for op in range(12):
        add(op, left, right, CONTROLS[n % len(CONTROLS)], n % 16 if op in (4, 10) else 0)
for delta in range(-128, 129):
    bits = 0x7e800000 + delta
    lanes = [bits, bits | 0x80000000, bits, bits | 0x80000000]
    for control in CONTROLS:
        for op in range(6):
            add(op, lanes, lanes, control)
for bits in edges:
    for offset in range(16):
        for op in (4, 10):
            add(op, [0x7f800001, 1, 0x80000000, 0xffc12345], [bits] * 4, CONTROLS[offset % len(CONTROLS)], offset)

# Inputs adjacent to inverse-square-root output midpoints challenge rounding
# without using host floating-point division or square root in the oracle.
for exponent in range(64, 190):
    for fraction in (0, 1, 0x12345, 0x3fffff, 0x7ffffe):
        bits = exponent << 23 | fraction
        midpoint = (value(bits) + value(bits + 1)) / 2
        candidate = nearest(1 / (midpoint * midpoint))
        for delta in range(-2, 3):
            source = candidate + delta
            if not 0x00800000 <= source < 0x7f800000:
                continue
            for op in range(6, 12):
                add(op, [source] * 4, [source] * 4)


def expected(query):
    op, _, control, left, right = query
    source = left if op % 3 == 2 else right
    root, scalar = op >= 6, op % 6 >= 3
    lanes = [result(bits, root) for bits in source[:1 if scalar else 4]]
    if scalar:
        lanes += list(left[1:])
    # A second rational check verifies Intel's relative error limit for every
    # normal finite result, separately from the sampled nearest-value profile.
    for a, b in zip(source, lanes[:1 if scalar else 4]):
        magnitude = a & 0x7fffffff
        if 0x00800000 <= magnitude < 0x7f800000 and not (root and a & 0x80000000) and b & 0x7fffffff:
            product = value(b) ** 2 * value(a) if root else value(b) * value(a)
            assert (1 - BOUND) ** 2 <= product <= (1 + BOUND) ** 2 if root else abs(product - 1) <= BOUND
    return struct.pack('<4IIHBBQ', *lanes, control, 0, 0, 0, 0)


answers = [expected(query) for query in queries]
modes = [[]] + ([['--jit']] if platform.machine() in ('arm64', 'aarch64') else [])
for mode in modes:
    for start in range(0, len(queries), 1000):
        batch = queries[start:start + 1000]
        payload = b''.join(struct.pack('<II8I', op | offset << 8, control, *left, *right)
                           for op, offset, control, left, right in batch)
        reference = b''.join(answers[start:start + len(batch)])
        run = subprocess.run([str(RUNTIME), *mode, str(GUEST)], input=payload, capture_output=True, timeout=30)
        assert run.returncode == 0 and not run.stderr, (mode, start, run.returncode, run.stderr)
        if run.stdout != reference:
            for n in range(len(batch)):
                actual, wanted = run.stdout[n * 32:(n + 1) * 32], reference[n * 32:(n + 1) * 32]
                assert actual == wanted, (mode, start + n, batch[n], actual.hex(), wanted.hex())
            raise AssertionError(('output length', mode, start, len(run.stdout), len(reference)))
    print(f'SSE reciprocals: {len(queries)} exact rational/ISQRT byte-state queries passed ({"JIT" if mode else "interpreter"}); 12 encoding views, all normal exponents, flush boundaries, midpoint neighbors and unchanged MXCSR/FLAGS', flush=True)
print('Native x86 lookup-table bit parity and universal correct rounding remain unverified', flush=True)
