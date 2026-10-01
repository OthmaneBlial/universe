#!/usr/bin/env python3
"""Exact Fraction oracle for decoded x87 arithmetic and comparisons."""
from fractions import Fraction as Q
import pathlib
import math
import platform
import random
import runpy
import struct
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT / 'zig-out/bin/universe'
old = runpy.run_path(str(ROOT / 'tests/x87.py'), run_name='oracle')
power, exponent, quantize, extended, kind, value, load = [old[n] for n in ('power','exponent','quantize','extended','kind','value','load')]
SIGN, INTEGER, QUIET, INDEFINITE, FORMATS = [old[n] for n in ('SIGN','INTEGER','QUIET','INDEFINITE','FORMATS')]
encodings = [(op, 0xc1 + group*8) for op in (0xd8,0xdc,0xde) for group in (0,1,4,5,6,7)]
encodings += [(op, 7 + group*8) for op in (0xd8,0xdc,0xda,0xde) for group in range(8)]
encodings += [(0xd8,0xd1),(0xd8,0xd9),(0xde,0xd9),(0xdd,0xe1),(0xdd,0xe9),(0xda,0xe9),(0xdb,0xf1),(0xdf,0xf1),(0xdb,0xe9),(0xdf,0xe9),(0xd9,0xe4),(0xd9,0xfa),(0xd9,0xfc)]


def pack(exact, negative=False):
    if not exact:
        return SIGN if negative else 0
    e = exponent(abs(exact))
    if e >= -16382:
        return extended(exact)
    sig = abs(exact) / power(-16445)
    assert sig.denominator == 1
    return (SIGN if exact < 0 else 0) | int(sig)


def rounded(exact, control, negative_zero=False):
    if not exact:
        return pack(exact, negative_zero), 0, False
    p = {0:24,2:53,3:64}[(control>>8)&3]
    mode, negative = (control>>10)&3, exact<0
    quantum = power(exponent(abs(exact))-p+1)
    n, inexact = quantize(abs(exact),quantum,mode,negative)
    result = n*quantum
    up = result>abs(exact)
    flags = 32 if inexact else 0
    if result >= power(16384):
        if control&8:
            inf = mode==0 or mode==1 and negative or mode==2 and not negative
            raw = (0x7fff<<64)|INTEGER if inf else (0x7ffe<<64)|(((1<<p)-1)<<(64-p))
            return raw|(SIGN if negative else 0),40,inf
        result *= power(-24576)
        flags |= 8
    elif result < power(-16382):
        if not control&16:
            result *= power(24576)
            flags |= 16
        else:
            quantum=power(-16382-p+1)
            n,inexact=quantize(abs(exact),quantum,mode,negative)
            result=n*quantum
            flags=48 if inexact else 0
            up=result>abs(exact)
    return pack(-result if negative else result,negative),flags,up


def compute(a,b,operation,control,initial):
    ka,kb=kind(a),kind(b)
    if initial&64 or 'unsupported' in (ka,kb):
        flags=(initial&~2)|1
        return INDEFINITE,flags,False,not flags&~control&63
    if 'nan' in (ka,kb):
        sn=lambda raw: kind(raw)=='nan' and not raw&QUIET
        flags=(initial&~2)|(1 if sn(a) or sn(b) else 0)
        if ka!='nan': selected=b
        elif kb!='nan': selected=a
        elif sn(a)!=sn(b): selected=b if sn(a) else a
        else: selected=min((a,b),key=lambda raw:(-(raw&((1<<64)-1)),bool(raw&SIGN)))
        return selected|QUIET,flags,False,not flags&~control&63
    ai,bi=ka=='inf',kb=='inf'
    az,bz=ka=='finite' and not value(a),kb=='finite' and not value(b)
    an,bn=bool(a&SIGN),bool(b&SIGN)
    xor=an!=bn
    if operation=='sub': bn=not bn
    if operation in ('add','sub') and ai and bi and an!=bn or operation=='mul' and (ai and bz or bi and az) or operation=='div' and (ai and bi or az and bz):
        flags=(initial&~2)|1
        return INDEFINITE,flags,False,not flags&~control&63
    if operation=='div' and not ai and not az and bz:
        flags=(initial&~2)|4
        return (SIGN if xor else 0)|(0x7fff<<64)|INTEGER,flags,False,not flags&~control&63
    denorm=lambda raw: not (raw>>64)&0x7fff and raw&((1<<64)-1)!=0
    flags=initial|(2 if denorm(a) or denorm(b) else 0)
    if flags&~control&63: return a,flags,False,False
    if ai or bi:
        negative=(an if ai else bn) if operation in ('add','sub') else xor
        raw=(SIGN if negative else 0)|(((0x7fff<<64)|INTEGER) if operation!='div' or ai else 0)
        return raw,flags,False,True
    av,bv=value(a),value(b)
    result={'add':lambda:av+bv,'sub':lambda:av-bv,'mul':lambda:av*bv,'div':lambda:av/bv}[operation]()
    negative_zero=xor if operation in ('mul','div') else (an if az and bz and an==bn else (control>>10)&3==1)
    raw,post,up=rounded(result,control,negative_zero)
    return raw,flags|post,up,True


def unary(raw, root, control, initial):
    if initial&64 or kind(raw)=='unsupported':
        flags=initial|1
        return INDEFINITE,flags,False,not flags&~control&63
    if kind(raw)=='nan':
        flags=initial|(1 if not raw&QUIET else 0)
        return raw|QUIET,flags,False,not flags&~control&63
    if root and raw&SIGN and raw&((1<<64)-1): return INDEFINITE,1,False,bool(control&1)
    flags=initial|(2 if not (raw>>64)&0x7fff and raw&((1<<64)-1) else 0)
    if flags&~control&63: return raw,flags,False,False
    if kind(raw)=='inf' or not value(raw): return raw,flags,False,True
    exact=value(raw)
    mode=(control>>10)&3
    if not root:
        n,inexact=quantize(abs(exact),Q(1),mode,exact<0)
        return pack(Q(-n if exact<0 else n),bool(raw&SIGN)),flags|(32 if inexact else 0),n>abs(exact),True
    p={0:24,2:53,3:64}[(control>>8)&3]
    quantum=power(exponent(exact)//2-p+1)
    scaled=exact/(quantum*quantum)
    n=math.isqrt(scaled.numerator//scaled.denominator)
    inexact=Q(n*n)!=scaled
    up=(mode==2 and inexact) or mode==0 and (scaled>(Q(n)+Q(1,2))**2 or scaled==(Q(n)+Q(1,2))**2 and n%2)
    result=(n+int(up))*quantum
    return pack(result),flags|(32 if inexact else 0),bool(up),True


def oracle(index,control,a,b,tag=3,status=0x4700):
    eflags=0x882
    op,byte=encodings[index]
    group=(byte>>3)&7
    memory=byte<0xc0
    flags=0
    initial_b=b
    if memory:
        width=16 if op==0xde else 64 if op==0xdc else 32
        bits=b&((1<<width)-1)
        if op in (0xda,0xde): b=extended(Q(bits-(1<<width) if bits>>(width-1) else bits))
        else:
            f=FORMATS[width==64]
            b,flags=load(bits,f)
            if flags&1: b &= ~QUIET; flags &= ~1
    if not tag&1 or not memory and op!=0xd9 and not tag&2: flags|=65
    if op==0xd9: b=0
    if op==0xd9 and byte in (0xfa,0xfc):
        result,flags,up,commit=unary(a,byte==0xfa,control,flags)
        status=(status&~0x200)|flags|(0x200 if up else 0)
        if flags&~control&63: status |= 0x8080
        if commit: tag |= 1
        return (result if commit else a).to_bytes(10,'little'),status,control,0x1f80,tag,eflags
    compare=((memory or op==0xd8) and group in (2,3)) or not memory and (op in (0xd9,0xda,0xdd,0xdb,0xdf) or (op,byte)==(0xde,0xd9))
    initial_a=a
    top=0
    if compare:
        quiet=op==0xdd or (op,byte)==(0xda,0xe9) or op in (0xdb,0xdf) and group==5
        bad=flags&64 or 'unsupported' in (kind(a),kind(b))
        unordered=bad or 'nan' in (kind(a),kind(b))
        if unordered:
            flags &= ~2
            if bad or any(kind(x)=='nan' and not x&QUIET for x in (a,b)) or not quiet: flags|=1
        elif any(not (x>>64)&0x7fff and x&((1<<64)-1)!=0 for x in (a,b)): flags|=2
        integer_flags=op in (0xdb,0xdf)
        if integer_flags: eflags &= ~0x880
        commit=not flags&~control&63
        if commit:
            less=not unordered and value(a)<value(b) if 'inf' not in (kind(a),kind(b)) else not unordered and ((kind(a)=='inf' and bool(a&SIGN)) or (kind(b)=='inf' and not b&SIGN)) and a!=b
            equal=not unordered and (a==b or kind(a)==kind(b)=='finite' and value(a)==value(b))
            if integer_flags: eflags=(eflags&~0x45)|(1 if unordered or less else 0)|(4 if unordered else 0)|(64 if unordered or equal else 0)
            else: status=(status&~0x4500)|(0x4500 if unordered else 0x100 if less else 0x4000 if equal else 0)
            pops=2 if (op,byte) in ((0xda,0xe9),(0xde,0xd9)) else 0 if op==0xd9 else int(group==3) if memory or op==0xd8 else int(group==5) if op==0xdd else int(op==0xdf)
            for _ in range(pops): tag &= ~(1<<top); top+=1
        raw=initial_a if top==0 else initial_b if top==1 else 0
        up=False
    else:
        destination=not memory and op!=0xd8
        if destination: a,b=b,a
        reverse=group in (5,7) if memory or op==0xd8 else group in (4,6)
        if reverse: a,b=b,a
        operation={0:'add',1:'mul',4:'sub',5:'sub',6:'div',7:'div'}[group]
        result,flags,up,commit=compute(a,b,operation,control,flags)
        if commit:
            tag |= 1<<int(destination)
            if not memory and op==0xde: tag &= ~1;top=1
            raw=result
        else: raw=initial_a if op!=0xdc else (b if reverse else a)
    status=(status&~0x3a00)|(top<<11)|flags|(0x200 if up else 0)
    if flags&~control&63: status |= 0x8080
    return raw.to_bytes(10,'little'),status,control,0x1f80,tag,eflags


queries=[]
def add(index,control,a,b,tag=3,status=0x4700):
    queries.append((index,control,a,b,tag,status))

finite_pairs=[(Q(0),Q(1)),(Q(1),Q(0)),(Q(1),Q(1)),(Q(-1),Q(1)),(Q(3),Q(7)),(Q(-7),Q(3)),(Q(1)+power(-63),Q(1)-power(-63)),(power(63)-1,power(63)+1),(power(16383),power(1)),(power(-16382),Q(3)),(power(-16445),power(16383)),(power(16383),power(-16445)),(Q(1),power(-200)),(Q(1),-power(-200)),(power(-16382),power(-63)),(power(-16382),-power(-16445))]
for p in (24,53,64):
    finite_pairs += [(Q(1),power(-p)),(Q(1)+power(1-p),power(-p)),(Q(-1),-power(-p)),(Q(1),power(-p)+power(-p-63)),(power(-16382),-power(-16382-min(p,63)))]
finite_pairs += [((2-power(-63))*power(16383),power(16319)),((2-power(-63))*power(16383),-power(16319))]
special=[0,SIGN,1,INTEGER,(0x7fff<<64)|INTEGER,(0xffff<<64)|INTEGER,(0x7fff<<64)|INTEGER|QUIET|1,(0xffff<<64)|INTEGER|QUIET|1,(0x7fff<<64)|INTEGER|QUIET|9,(0x7fff<<64)|INTEGER|1,(0x3fff<<64)|3]
for index,(op,byte) in enumerate(encodings):
    memory=byte<0xc0
    width=16 if op==0xde else 64 if op==0xdc else 32
    pairs=[(pack(a),pack(b)) for a,b in finite_pairs]+[(a,b) for a in special for b in special]
    if memory:
        bits=[0,1,(1<<width)-1,1<<(width-1),42] if op in (0xda,0xde) else [0,1,FORMATS[width==64].bias<<FORMATS[width==64].p,FORMATS[width==64].exp,FORMATS[width==64].exp|1,FORMATS[width==64].exp|FORMATS[width==64].quiet|9]
        pairs=[(a,b) for a in special+[extended(Q(1)),extended(Q(-3))] for b in bits]
    for precision in (0,2,3):
        for mode in range(4):
            control=0x7f|(precision<<8)|(mode<<10)
            for a,b in pairs: add(index,control,a,b)
    for unmask in (1,2,4,8,16,32,63):
        for a,b in pairs[:16]+[(a,b) for a in special for b in special[:2]]: add(index,0x37f&~unmask,a,b)
    for tag in (0,1,2): add(index,0x37f,extended(Q(3)),extended(Q(7)),tag);add(index,0x37e,extended(Q(3)),extended(Q(7)),tag)
rng=random.Random(0x873)
for _ in range(750):
    index=rng.choice([*range(18),61,62])
    raw=lambda: (rng.randrange(1,0x7fff)<<64)|INTEGER|rng.getrandbits(64)|(SIGN if rng.randrange(2) else 0)
    add(index,0x7f|(rng.choice((0,2,3))<<8)|(rng.randrange(4)<<10),raw(),raw())
expected=[oracle(*q) for q in queries]
stdin=b''.join(struct.pack('<IIQQQQII',idx,cw,a&((1<<64)-1),a>>64,b&((1<<64)-1),b>>64,tag,status) for idx,cw,a,b,tag,status in queries)
for engine in [[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else []):
    run=subprocess.run([str(RUNTIME),*engine,'--max-instructions','100000000','--timeout-ms','60000',str(ROOT/'artifacts/guests/x86_64/x87-arithmetic')],input=stdin,capture_output=True,timeout=75)
    assert run.returncode==0 and not run.stderr,(engine,run.returncode,len(run.stdout),run.stderr)
    assert len(run.stdout)==len(queries)*32,(len(run.stdout),len(queries)*32)
    bad=[(n,actual) for n,actual in enumerate(struct.iter_unpack('<10sHIIB3xQ',run.stdout)) if actual!=expected[n]]
    assert not bad,'\n'.join(f'{engine} query {n} encoding={encodings[queries[n][0]]} input={tuple(hex(v) for v in queries[n])}: actual={actual}, expected={expected[n]}' for n,actual in bad[:8])+f'\n{len(bad)} mismatches'
    print(f'x87 arithmetic: {len(queries)} exact Fraction/bit queries passed ({"JIT" if engine else "interpreter"})',flush=True)
