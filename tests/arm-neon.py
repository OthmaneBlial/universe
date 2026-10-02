#!/usr/bin/env python3
"""Check decoded NEON table/accumulate instructions against scalar and native ARM64 bytes."""
import ctypes
import pathlib
import platform
import random
import struct
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'artifacts/arm-neon'
OUT.mkdir(parents=True, exist_ok=True)
views = []
for width in (8, 16):
    for length in range(1, 5):
        for start in (0, 29, 30, 31):
            for dest in (5, start, (start + 3) % 32):
                for extend in (False, True):
                    registers = ', '.join(f'v{(start + n) % 32}.16b' for n in range(length))
                    text = f'{"tbx" if extend else "tbl"} v{dest}.{width}b, {{ {registers} }}, v5.{width}b'
                    views.append((text, dest, ('table', width, length, start, extend)))
for width in (8, 16):
    for element in (1, 2, 4):
        for dest in (2, 0, 1):
            for subtract in (False, True):
                shape = f'{width // element}{ {1:"b", 2:"h", 4:"s"}[element] }'
                text = f'{"mls" if subtract else "mla"} v{dest}.{shape}, v0.{shape}, v1.{shape}'
                views.append((text, dest, ('multiply', width, element, subtract)))

lines = ['.text', '#ifdef __APPLE__', '.global _neon_case', '_neon_case:', '#else', '.global neon_case', 'neon_case:', '#endif',
         'stp q8, q9, [sp, #-128]!', 'stp q10, q11, [sp, #32]', 'stp q12, q13, [sp, #64]', 'stp q14, q15, [sp, #96]']
lines += [f'ldp q{reg}, q{reg+1}, [x0, #{reg*16}]' for reg in range(0, 32, 2)]
lines += ['adr x3, cases', 'add x3, x3, x2, lsl #4', 'br x3', 'cases:']
for text, dest, _ in views:
    lines += [text, f'str q{dest}, [x1]', 'b restore', 'nop']
lines += ['restore:', 'ldp q8, q9, [sp]', 'ldp q10, q11, [sp, #32]', 'ldp q12, q13, [sp, #64]', 'ldp q14, q15, [sp, #96]', 'add sp, sp, #128', 'ret']
lines += ['#ifndef __APPLE__', '.global _start', '_start:', 'adr x19, request', 'adr x20, reply',
          'next:', 'mov x21, #0', 'read_more:', 'mov x0, #0', 'add x1, x19, x21', 'mov x2, #520', 'sub x2, x2, x21',
          'mov x8, #63', 'svc #0', 'cmp x0, #0', 'b.lt failed', 'b.eq eof', 'add x21, x21, x0', 'cmp x21, #520', 'b.ne read_more',
          'add x0, x19, #8', 'mov x1, x20', 'ldr x2, [x19]', 'bl neon_case',
          'mov x0, #1', 'mov x1, x20', 'mov x2, #16', 'mov x8, #64', 'svc #0', 'cmp x0, #16', 'b.ne failed', 'b next',
          'eof:', 'cbnz x21, failed', 'mov x0, #0', 'b exit', 'failed:', 'mov x0, #1', 'exit:', 'mov x8, #93', 'svc #0',
          '.bss', '.balign 16', 'request: .skip 520', 'reply: .skip 16', '#endif']
source = OUT / 'oracle.S'
source.write_text('\n'.join(lines) + '\n')
guest = OUT / 'guest'
subprocess.run(['zig', 'cc', '-target', 'aarch64-linux-musl', '-nostdlib', '-static', '-fno-pie', '-no-pie',
                '-Wl,-e,_start', '-Wl,--build-id=none', str(source), '-o', str(guest)], check=True)
native = None
if platform.system() == 'Darwin' and platform.machine() in ('arm64', 'aarch64'):
    library = OUT / 'native.dylib'
    subprocess.run(['cc', '-dynamiclib', str(source), '-o', str(library)], check=True)
    native = ctypes.CDLL(str(library)).neon_case
    native.argtypes = [ctypes.POINTER(ctypes.c_ubyte), ctypes.POINTER(ctypes.c_ubyte), ctypes.c_uint64]
    native.restype = None

rng = random.Random(0x4e1b6206)
requests, expected = bytearray(), bytearray()
checks = 0
for case, (_, dest, spec) in enumerate(views):
    for sample in range(32 if spec[0] == 'table' else 64):
        data = bytearray(rng.randbytes(512))
        if spec[0] == 'table':
            _, width, length, start, extend = spec
            data[5*16:6*16] = bytes((sample*8 + lane) % 256 for lane in range(16))
            table = b''.join(data[((start+n) % 32)*16:((start+n) % 32)*16+16] for n in range(length))
            result = bytes(table[index] if index < len(table) else data[dest*16+lane] if extend else 0
                           for lane, index in enumerate(data[5*16:5*16+width])) + bytes(16-width)
        else:
            _, width, element, subtract = spec
            result = bytearray(16)
            for offset in range(0, width, element):
                a = int.from_bytes(data[offset:offset+element], 'little')
                b = int.from_bytes(data[16+offset:16+offset+element], 'little')
                old = int.from_bytes(data[dest*16+offset:dest*16+offset+element], 'little')
                value = (old - a*b if subtract else old + a*b) % (1 << (element*8))
                result[offset:offset+element] = value.to_bytes(element, 'little')
            result = bytes(result)
        if native:
            actual = (ctypes.c_ubyte * 16)()
            native((ctypes.c_ubyte * 512).from_buffer_copy(data), actual, case)
            assert bytes(actual) == result, (views[case], sample, bytes(actual).hex(), result.hex())
        requests += struct.pack('<Q', case) + data
        expected += result
        checks += 1
for engine in [[]] + ([['--jit']] if platform.machine() in ('arm64', 'aarch64') else []):
    command = [str(ROOT/'zig-out/bin/universe'), *engine, '--max-instructions', '30000000', '--timeout-ms', '30000', str(guest)]
    process = subprocess.run(command, input=requests, capture_output=True, timeout=40)
    assert process.returncode == 0 and not process.stderr, (command, process.returncode, process.stderr)
    assert process.stdout == expected, (command, len(process.stdout), len(expected), next((i for i, (a,b) in enumerate(zip(process.stdout,expected)) if a != b), None))
print(f'ARM64 NEON: {checks} exact queries per engine across {len(views)} views; scalar oracle' + (' and native ARM64 hardware agree' if native else '; native hardware not checked'))
