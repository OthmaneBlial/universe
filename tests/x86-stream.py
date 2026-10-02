#!/usr/bin/env python3
"""Exact byte oracles for legacy ANDN and streaming/masked stores."""
import pathlib
import platform
import random
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'zig-out/bin/universe'
GUEST = ROOT / 'artifacts/guests/x86_64/stream'
CONTROLS = [0x1f80, 0, 0x1fbf, 0x3f80, 0x5fc0, 0x7fc0, 0x9f80, 0xffbf]
RNG = random.Random(0x53545245414d)
queries = []


def add(op, left, right, offset=0, control=0x1f80):
    queries.append((op, offset, control, left, right))


def oracle(query):
    op, offset, control, left, right = query
    memory = bytearray(b'\xa5' * 64)
    mmx = op in (13, 14, 15)
    value = left[:8] + bytes(8) if mmx else left
    if op < 4:
        value = bytes((~a & b) for a, b in zip(left, right))
    elif op < 6:
        value = bytes(16)
    elif op in (6, 7, 8, 9, 10, 13):
        size = 4 if op == 9 else 8 if op in (10, 13) else 16
        memory[16 + offset:16 + offset + size] = left[:size]
    elif op != 16:
        data = right if op == 12 else left
        mask = left if op == 15 else right
        for n in range(8 if op >= 13 else 16):
            if mask[n] & 128:
                memory[16 + offset + n] = data[n]
    return bytes(memory) + value + struct.pack('<IHBBQ', control, 0, 255 if mmx else 0, 0, 0)


# Raw floating bit patterns include signed zeros, denormals, signaling/quiet
# NaNs and infinities. No floating flags or payload changes are allowed.
edges = [bytes(16), b'\xff' * 16, bytes(range(16)), bytes(range(255, 239, -1)),
         struct.pack('<4I', 0x80000000, 1, 0x7f800001, 0x7fc12345),
         struct.pack('<2Q', 0xfff0000000000000, 0x7ff0000000000001)]
for control in CONTROLS:
    for left in edges:
        for right in edges:
            for op in range(6):
                add(op, left, right, control=control)
for n in range(256):
    left, right = RNG.randbytes(16), RNG.randbytes(16)
    control = CONTROLS[n % len(CONTROLS)]
    for op in range(17):
        offsets = range(16) if op in (9, 10, 13, 14, 15) else [n % 16] if op in (11, 12) else [0]
        for offset in offsets:
            add(op, left, right, offset, control)

# Every possible selected-byte pattern, with nonzero low mask bits and all
# unaligned offsets. Extended XMM registers and data/mask aliases are encoded.
left = bytes((n * 23 + 7) & 255 for n in range(16))
for bits in range(65536):
    mask = bytes(((bits >> n) & 1) * 128 | ((bits + n * 13) & 127) for n in range(16))
    add(11, left, mask, bits % 16, CONTROLS[bits % len(CONTROLS)])
for bits in range(256):
    mask = bytes(((bits >> n) & 1) * 128 | ((bits + n * 13) & 127) for n in range(16))
    add(14, left, mask, bits % 16, CONTROLS[bits % len(CONTROLS)])

modes = [[]] + ([['--jit']] if platform.machine() in ('arm64', 'aarch64') else [])
for mode in modes:
    for start in range(0, len(queries), 1000):
        batch = queries[start:start + 1000]
        payload = b''.join(struct.pack('<II16s16s', op | offset << 8, control, left, right)
                           for op, offset, control, left, right in batch)
        expected = b''.join(map(oracle, batch))
        result = subprocess.run([str(RUNTIME), *mode, str(GUEST)], input=payload, capture_output=True, timeout=30)
        assert result.returncode == 0 and not result.stderr, (mode, start, result.returncode, result.stderr)
        if result.stdout != expected:
            first = next((n for n, (a, b) in enumerate(zip(result.stdout, expected)) if a != b), min(len(result.stdout), len(expected)))
            index = start + first // 96
            raise AssertionError(f'stream mismatch mode={mode} query={index} value={queries[index]} byte={first % 96} actual={result.stdout[first:first + 16].hex()} expected={expected[first:first + 16].hex()} sizes={len(result.stdout)}/{len(expected)}')
    print(f'x86 streaming: {len(queries)} exact byte/state queries passed in {"JIT" if mode else "interpreter"}; all 65536 XMM and 256 MMX selection masks')
