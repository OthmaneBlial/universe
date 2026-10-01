#!/usr/bin/env python3
"""Exact integer/Fraction oracle for x87 transfers, stack controls and stores."""
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
# Reuse the independent IEEE bit encoder without running the SSE guest suite.
ieee = runpy.run_path(str(ROOT / 'tests/x86-mxcsr.py'), run_name='oracle')
power, exponent, quantize, encode = [ieee[name] for name in ('power', 'exponent', 'quantize', 'encode')]
FORMATS = ieee['FORMATS']
SIGN, INTEGER, QUIET = 1 << 79, 1 << 63, 1 << 62
INDEFINITE = (0xffff << 64) | INTEGER | QUIET


def extended(value, negative_zero=False):
    if not value:
        return SIGN if negative_zero else 0
    e = exponent(abs(value))
    significand = abs(value) / power(e - 63)
    assert significand.denominator == 1 and INTEGER <= significand < 1 << 64
    return (SIGN if value < 0 else 0) | ((e + 16383) << 64) | int(significand)


def kind(raw):
    exp = (raw >> 64) & 0x7fff
    if exp and not raw & INTEGER:
        return 'unsupported'
    if exp == 0x7fff:
        return 'nan' if raw & (INTEGER - 1) else 'inf'
    return 'finite'


def value(raw):
    assert kind(raw) == 'finite'
    exp = (raw >> 64) & 0x7fff
    return (-1 if raw & SIGN else 1) * (raw & ((1 << 64) - 1)) * power(max(exp, 1) - 16383 - 63)


def load(bits, f):
    k = f.kind(bits)
    if k != 'finite':
        sig = INTEGER | ((bits & ((1 << f.p) - 1)) << (63 - f.p))
        invalid = k == 'nan' and not bits & f.quiet
        return (SIGN if bits & f.sign else 0) | (0x7fff << 64) | sig | (QUIET if invalid else 0), int(invalid)
    return extended(f.value(bits), bool(bits & f.sign)), 2 if f.denormal(bits) else 0


def store(raw, width, control, integer=False, truncate=False):
    k, negative = kind(raw), bool(raw & SIGN)
    if integer:
        if k != 'finite':
            return 1 << (width - 1), 1, False
        exact = value(raw)
        result, inexact = quantize(abs(exact), Q(1), 3 if truncate else (control >> 10) & 3, negative)
        signed = -result if negative else result
        if not -(1 << (width - 1)) <= signed < 1 << (width - 1):
            return 1 << (width - 1), 1, False
        return signed & ((1 << width) - 1), 32 if inexact else 0, inexact and result > abs(exact)
    f = FORMATS[width == 64]
    if k == 'unsupported':
        return f.sign | f.exp | f.quiet, 1, False
    if k != 'finite':
        bits = (f.sign if negative else 0) | f.exp | ((raw & (INTEGER - 1)) >> (63 - f.p))
        return bits | (f.quiet if k == 'nan' else 0), int(k == 'nan' and not raw & QUIET), False
    exact = value(raw)
    bits, flags = encode(exact, f, 0x1f80 | ((control & 0xc00) << 3), negative)
    if exact and not control & 16:
        e = exponent(abs(exact))
        unlimited, _ = quantize(abs(exact), power(e - f.p), (control >> 10) & 3, negative)
        if unlimited * power(e - f.p) < power(f.minimum):
            flags |= 16
    if flags & ~control & 24:
        return bits, flags & ~32, False
    rounded_up = bool(flags & 32) and (f.kind(bits) == 'inf' or abs(f.value(bits)) > abs(exact))
    return bits, flags, rounded_up


def packed_bcd(n, negative=False):
    assert 0 <= n < 10**18
    return (SIGN if negative else 0) | sum(int(digit) << (4 * place) for place, digit in enumerate(f'{n:018d}'[::-1]))


def load_bcd(bits):
    digits = [(bits >> (4 * place)) & 15 for place in range(18)]
    assert all(digit < 10 for digit in digits), 'Invalid BCD digits have undefined numeric results'
    n = int(''.join(str(digit) for digit in digits[::-1]))
    return extended(Q(-n if bits & SIGN else n), bool(bits & SIGN))


def store_bcd(raw, control):
    if kind(raw) != 'finite':
        return 0xffffc000000000000000, 1, False
    exact, negative = value(raw), bool(raw & SIGN)
    n, inexact = quantize(abs(exact), Q(1), (control >> 10) & 3, negative)
    if n >= 10**18:
        return 0xffffc000000000000000, 1, False
    return packed_bcd(n, negative), 32 if inexact else 0, inexact and n > abs(exact)


def oracle(op, control, sig, exp):
    raw = sig | ((exp & 0xffff) << 64)
    flags, c1, top, tag = 0, False, 7, 0x80
    if op in (0, 1):
        raw, flags = load(sig & ((1 << (32 if op == 0 else 64)) - 1), FORMATS[op])
        if flags & ~control & 1:
            raw, top, tag = 0, 0, 0
    elif op in (3, 4, 5):
        width = [16, 32, 64][op - 3]
        bits = sig & ((1 << width) - 1)
        raw = extended(Q(bits - (1 << width) if bits & (1 << (width - 1)) else bits))
    elif 6 <= op <= 17:
        width = {6: 32, 7: 64, 8: 32, 9: 64, 10: 16, 11: 32, 12: 16, 13: 32, 14: 64, 15: 16, 16: 32, 17: 64}[op]
        bits, flags, c1 = store(raw, width, control, op >= 10, op >= 15)
        suppressed = bool(flags & ~control & 25)
        raw = 0 if suppressed else bits
        if not suppressed and op not in (6, 7, 10, 11):
            top, tag = 0, 0
    elif op in (18, 19):
        raw = raw ^ SIGN if op == 18 else raw & ~SIGN
    elif op in (20, 30):
        k = kind(raw)
        exp = (raw >> 64) & 0x7fff
        flags = 0x4100 if op == 30 else (0 if k == 'unsupported' else 0x100 if k == 'nan' else 0x500 if k == 'inf' else
                                      0x4000 if exp == 0 and sig == 0 else 0x4400 if exp == 0 else 0x400)
        c1 = bool(raw & SIGN)
        if op == 30:
            tag = 0
    elif op == 21:
        top, tag = 6, 0xc0
    elif op == 22:
        tag = 0x84
    elif op == 23:
        top, tag = 0, 1
    elif op == 24:
        tag = 0
    elif op == 25:
        top = 0
    elif op == 26:
        top = 6
    elif op in (27, 28):
        raw = extended(Q(1)) if op == 27 else 0
    elif op in (31, 33):
        flags = 0x41
        if control & 1:
            raw, tag = INDEFINITE, 0x80 if op == 31 else 0x84
        elif op == 31:
            tag = 0
    elif op == 32:
        top, tag = 0, 0
    elif op == 35:
        raw = load_bcd(raw)
    elif op in (36, 37):
        bits, flags, c1 = store_bcd(load_bcd(raw) if op == 37 else raw, control)
        suppressed = bool(flags & ~control & 1)
        raw = 0 if suppressed else bits
        if not suppressed:
            top, tag = 0, 0
    elif op == 38:
        flags, tag = 0x41, 0
        raw = 0 if not control & 1 else 0xffffc000000000000000
        if control & 1:
            top = 0
    # FLD80, FNOP and FXCH ST(0) preserve the raw value.
    status = (top << 11) | flags | (0x200 if c1 else 0)
    if flags & ~control & 0x3f:
        status |= 0x8080
    return raw.to_bytes(10, 'little'), status, control, 0x1f80, tag


def main():
    queries = []
    # All store directions and control-word precision settings, which cannot change transfers.
    edges = [0, SIGN, INTEGER, 1, INTEGER | 1, 0x7fff << 64, (0x7fff << 64) | INTEGER,
             (0x7fff << 64) | INTEGER | 123, (0x7fff << 64) | INTEGER | QUIET | 321,
             0x3fff << 64, (0x3fff << 64) | 123, (0x7ffe << 64) | ((1 << 64) - 1)]
    for exact in [Q(1), Q(5, 2), Q(7, 2), power(-24) + 1, power(-53) + 1,
                  power(-150), power(-149), power(-127), power(-126) - power(-151),
                  power(-1075), power(-1074), power(-1023), power(128), power(1024),
                  Q(32767), Q(32767) + Q(1, 2), Q(32768), Q(-32768),
                  power(31) - Q(1, 2), -power(31) - Q(1, 2), power(63) - 1, -power(63), power(63)]:
        edges.append(extended(exact))
    edges += [raw ^ SIGN for raw in edges]
    for mode in range(4):
        for precision in (0, 2, 3):
            control = 0x7f | (precision << 8) | (mode << 10)
            for op in range(6, 18):
                for raw in edges:
                    queries.append((op, control, raw & ((1 << 64) - 1), raw >> 64))
        control = 0x37f | (mode << 10)
        for unmask in (1, 8, 16, 32, 63):
            for op in range(6, 18):
                for raw in edges:
                    queries.append((op, control & ~unmask, raw & ((1 << 64) - 1), raw >> 64))
    for op, f in enumerate(FORMATS):
        bits = [0, f.sign, 1, (1 << f.p) - 1, 1 << f.p, f.bias << f.p, f.exp - 1, f.exp, f.exp | 1, f.exp | f.quiet | 123]
        bits += [b ^ f.sign for b in bits]
        for control in (0x37f, 0x7f, 0x27f, 0x37e, 0x37d, 0x340):
            queries.extend((op, control, b, 0) for b in bits)
    for op, width in zip((3, 4, 5), (16, 32, 64)):
        for control in (0x37f, 0x7f, 0x27f):
            queries.extend((op, control, n & ((1 << 64) - 1), 0) for n in (0, 1, -1, (1 << (width - 1)) - 1, -(1 << (width - 1))))
    for op in (2, *range(18, 35)):
        for control in (0x37f, 0x37e):
            queries.extend((op, control, raw & ((1 << 64) - 1), raw >> 64) for raw in edges)
    rng = random.Random(0x783837)
    for _ in range(128):
        raw = (rng.randrange(1, 0x7fff) << 64) | rng.getrandbits(64) | INTEGER | (SIGN if rng.randrange(2) else 0)
        queries.append((rng.randrange(6, 18), 0x37f | (rng.randrange(4) << 10), raw & ((1 << 64) - 1), raw >> 64))

    original_count = len(queries)
    decimal_values = {0, 1, 9, 10, 99, 100, 10**18 - 1, 123456789012345678, 987654321012345678}
    for place in range(18):
        decimal_values.update(digit * 10**place for digit in range(10))
        decimal_values.update(n for n in (10**place - 1, 10**place, 10**place + 1) if 0 <= n < 10**18)
    decimal_rng = random.Random(0xbcd)
    decimal_values.update(decimal_rng.randrange(10**18) for _ in range(128))
    for precision in range(4):
        for mode in range(4):
            control = 0x7f | precision << 8 | mode << 10
            for n in sorted(decimal_values):
                for negative in (False, True):
                    bits = packed_bcd(n, negative)
                    for op in (35, 37):
                        queries.append((op, control, bits & ((1 << 64) - 1), bits >> 64))
    # The seven unused bits in the sign byte cannot alter a valid BCD value.
    for ignored in range(128):
        for n in (0, 1, 123456789012345678, 10**18 - 1):
            for negative in (False, True):
                bits = packed_bcd(n, negative) | ignored << 72
                for op in (35, 37):
                    queries.append((op, 0x37f, bits & ((1 << 64) - 1), bits >> 64))
    bcd_edges = set(edges)
    for exact in [Q(n, 8) for n in range(-24, 25)] + [
        Q(base) + offset for base in [10**place for place in range(19)] + [10**18 - 1, 10**18 - 2]
        for offset in (Q(-9, 16), Q(-1, 2), Q(-1, 16), Q(0), Q(1, 16), Q(1, 2), Q(9, 16))
    ]:
        bcd_edges.update((extended(exact), extended(-exact)))
    for precision in range(4):
        for mode in range(4):
            control = 0x7f | precision << 8 | mode << 10
            for raw in sorted(bcd_edges):
                queries.append((36, control, raw & ((1 << 64) - 1), raw >> 64))
    for mode in range(4):
        for unmask in (1, 2, 32, 63):
            for raw in sorted(bcd_edges):
                queries.append((36, (0x37f | mode << 10) & ~unmask, raw & ((1 << 64) - 1), raw >> 64))
    for control in (0x37f, 0x37e, 0x35f, 0x340):
        for raw in edges:
            queries.append((38, control, raw & ((1 << 64) - 1), raw >> 64))

    expected = [oracle(*query) for query in queries]
    stdin = b''.join(struct.pack('<IIQQ', *query) for query in queries)
    for mode in [[]] + ([['--jit']] if platform.machine() in ('arm64', 'aarch64') else []):
        run = subprocess.run([str(RUNTIME), *mode, '--max-instructions', '30000000', '--timeout-ms', '30000',
                              str(ROOT / 'artifacts/guests/x86_64/x87')], input=stdin, capture_output=True, timeout=40)
        assert run.returncode == 0 and not run.stderr, (mode, run.returncode, len(run.stdout), run.stderr)
        assert len(run.stdout) == len(queries) * 24, (len(run.stdout), len(queries) * 24)
        mismatches = [(n, actual) for n, actual in enumerate(struct.iter_unpack('<10sHIIB3x', run.stdout)) if actual != expected[n]]
        assert not mismatches, '\n'.join(f'{mode} query {n} op/control/sig/exp={tuple(hex(v) for v in queries[n])}: actual={actual}, expected={expected[n]}' for n, actual in mismatches[:8]) + f'\n{len(mismatches)} mismatches'
    print(f'x87: {len(queries)} exact rational/bit oracles per engine passed; float/integer/packed BCD transfers, four rounding modes, stack controls, raw 80-bit values and masked/unmasked exceptions')
    print(f'x87 BCD: {len(queries) - original_count} added queries; valid decimal loads/round trips, ignored sign-byte bits and 18-digit rounded boundaries; undefined malformed digits and native x87 hardware numeric/flag parity are not claimed')


if __name__ == "__main__":
    main()
