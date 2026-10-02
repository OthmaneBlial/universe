#!/usr/bin/env python3
"""Exact scalar oracles for the original MMX families, paired atomics and state images."""
import pathlib
import platform
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'zig-out/bin/universe'
GUEST = ROOT / 'artifacts/guests/x86_64/baseline'
OPS = '''paddb paddw paddd psubb psubw psubd
paddsb paddsw paddusb paddusw psubsb psubsw psubusb psubusw
pcmpeqb pcmpeqw pcmpeqd pcmpgtb pcmpgtw pcmpgtd
pand pandn por pxor packsswb packuswb packssdw
punpcklbw punpcklwd punpckldq punpckhbw punpckhwd punpckhdq
pmullw pmulhw pmaddwd'''.split()
SHIFTS = 'psrlw psrld psrlq psraw psrad psllw pslld psllq'.split()
VALUES = [
    (0x80007fff0001ffff, 0x7fff8000ffff0001),
    (0xff0100807f00ff80, 0x0101ff7f80ff007f),
    (0x800000007fffffff, 0x7fffffff80000000),
    (0x8000800080008000, 0x8000800080008000),
]

def lanes(value, bits, signed=False):
    result = [(value >> offset) & ((1 << bits) - 1) for offset in range(0, 64, bits)]
    return [n - (1 << bits) if n & (1 << (bits - 1)) else n for n in result] if signed else result

def pack(values, bits):
    return sum((value & ((1 << bits) - 1)) << (n * bits) for n, value in enumerate(values))

def clamp(value, bits, signed):
    low, high = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
    return min(high, max(low, value))

def binary(op, left, right):
    if op in ['pand', 'pandn', 'por', 'pxor']:
        return {'pand': left & right, 'pandn': (~left) & right,
                'por': left | right, 'pxor': left ^ right}[op]
    if op.startswith('pack'):
        source_bits = 32 if op == 'packssdw' else 16
        target_bits = source_bits // 2
        return pack([clamp(n, target_bits, op != 'packuswb') for n in lanes(left, source_bits, True) + lanes(right, source_bits, True)], target_bits)
    if op.startswith('punpck'):
        bits = {'bw': 8, 'wd': 16, 'dq': 32}[op[-2:]]
        a, b = lanes(left, bits), lanes(right, bits)
        half = len(a) // 2
        start = half if op.startswith('punpckh') else 0
        return pack([n for pair in zip(a[start:start + half], b[start:start + half]) for n in pair], bits)
    if op in ['pmullw', 'pmulhw', 'pmaddwd']:
        a, b = lanes(left, 16, True), lanes(right, 16, True)
        products = [x * y for x, y in zip(a, b)]
        if op == 'pmaddwd':
            return pack([products[0] + products[1], products[2] + products[3]], 32)
        return pack([n >> 16 if op == 'pmulhw' else n for n in products], 16)
    bits = {'b': 8, 'w': 16, 'd': 32}[op[-1]]
    compare = op.startswith('pcmp')
    signed = op.startswith('pcmpgt') or (not compare and 's' in op[4:-1] and 'us' not in op)
    a, b = lanes(left, bits, signed), lanes(right, bits, signed)
    if compare:
        return pack([-1 if (x > y if op.startswith('pcmpgt') else x == y) else 0 for x, y in zip(a, b)], bits)
    values = [x - y if op.startswith('psub') else x + y for x, y in zip(a, b)]
    if 's' in op[4:-1]:
        values = [clamp(n, bits, signed) for n in values]
    return pack(values, bits)

def shift(op, value, count):
    bits = {'w': 16, 'd': 32, 'q': 64}[op[-1]]
    signed = op.startswith('psra')
    count = min(count, bits)
    return pack([n << count if op.startswith('psll') else n >> count for n in lanes(value, bits, signed)], bits)

expected = bytearray(struct.pack('<II', 0x2000, 0x7808111))
for match in [False, True]:
    expected += struct.pack('<5Q',
        0x44332211 if match else 0x89abcdef, 0x55667788 if match else 0x76543210,
        0xaabbccdd89abcdef if match else 0x89abcdef,
        0x1122334476543210 if match else 0x76543210, int(match))
for match in [False, True]:
    expected += struct.pack('<5Q',
        0x8877665544332211 if match else 0x0123456789abcdef,
        0x1122334455667788 if match else 0xfedcba9876543210,
        0x0123456789abcdef, 0xfedcba9876543210, int(match))
for left, right in VALUES:
    for op in OPS:
        value = binary(op, left, right)
        expected += struct.pack('<2Q', value, value)  # Register and memory sources.
left = 0x80017fff89abcdef
for count in [0, 1, 15, 16, 31, 32, 63, 64, 65, 256]:
    for op in SHIFTS:
        value = shift(op, left, count)
        expected += struct.pack('<2Q', value, value)
for op in SHIFTS:
    expected += struct.pack('<Q', shift(op, left, 3))
expected += struct.pack('<QI', 0x89abcdef, 0x89abcdef)
expected += struct.pack('<5Q', 0x37f, 0, 0xff, 0x1f80, 0xffff)
expected += bytes(range(256))
expected += struct.pack('<QH', 0x0123456789abcdef, 0xffff)
expected += struct.pack('<QH', 0xfedcba9876543210, 0xffff)
expected += b'\xa5' * 96 + b'\0' + struct.pack('<I', 0x1f83)
expected += b'x86 baseline atomics, MMX and state images: ok\n'

modes = [[]] + ([['--jit']] if platform.machine() in ['arm64', 'aarch64'] else [])
for mode in modes:
    result = subprocess.run([str(RUNTIME), *mode, str(GUEST)], capture_output=True, timeout=20)
    assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
    assert not result.stderr, result.stderr
    if result.stdout != expected:
        first = next((n for n, pair in enumerate(zip(result.stdout, expected)) if pair[0] != pair[1]), min(len(result.stdout), len(expected)))
        raise AssertionError(f'Baseline oracle mismatch at byte {first}: actual={result.stdout[first:first + 16].hex()} expected={expected[first:first + 16].hex()} sizes={len(result.stdout)}/{len(expected)}')
print('x86 baseline: CMPXCHG8B/16B, original MMX scalar oracles, x87 aliasing and bounded state images passed (interpreter/JIT on ARM64 hosts)')
