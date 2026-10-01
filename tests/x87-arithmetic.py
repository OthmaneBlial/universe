#!/usr/bin/env python3
"""Fraction/decimal/bit oracles for decoded x87 calculations and raw moves."""
from fractions import Fraction as Q
from decimal import Decimal, localcontext
from functools import lru_cache
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
encodings += [(0xd9,byte) for byte in range(0xe8,0xef)]
encodings += [(op,0xc1+group*8) for op in (0xda,0xdb) for group in range(4)]
# Two views of FXTRACT check both output registers without changing the packet ABI.
encodings += [(0xd9,0xf4)]*2
encodings += [(0xd9,byte) for byte in (0xf8,0xf5,0xf8,0xf5)]
encodings += [(0xd9,0xfd)]*2  # FSCALE, then FXTRACT/FSCALE/FSTP reconstruction.
encodings += [(0xd9,0xf0)]
encodings += [(0xd9,0xf1)]
encodings += [(0xd9,0xf9)]
encodings += [(0xd9,0xf3)]
encodings += [(0xd9,0xfe),(0xd9,0xff)]
encodings += [(0xd9,0xfb)]*2  # Cosine and sine after the same stack push.
encodings += [(0xd9,0xf2)]*2  # Pushed value and tangent after the same instruction.

# Independent high-precision mathematical constants, not the runtime's bit table.
with localcontext() as context:
    context.prec=100
    D=Decimal
    total,m,k,l,x=D(13591409),1,6,13591409,1
    for n in range(1,8):
        m=m*(k*k*k-16*k)//(n*n*n);l+=545140134;x*=-262537412640768000
        total+=D(m*l)/D(x);k+=12
    pi=426880*D(10005).sqrt()/total
    constants=[Q(1),Q(D(10).ln()/D(2).ln()),Q(1/D(2).ln()),Q(pi),Q(D(2).ln()/D(10).ln()),Q(D(2).ln()),Q(0)]


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


@lru_cache(maxsize=None)
def exponential_value(raw):
    exact=value(raw)
    if exact in (0,1,-1): return {Q(0):Q(0),Q(1):Q(1),Q(-1):Q(-1,2)}[exact]
    with localcontext() as context:
        context.prec=160
        x=Decimal(exact.numerator)/Decimal(exact.denominator)
        y=x*Decimal(2).ln()
        # Decimal exp is independent of the runtime's normalized binary series.
        # Below 2^-128, keep tiny results with a relative expansion instead of
        # cancellation. The omitted cubic term is less than 2^-258 relative.
        result=y.exp()-1 if abs(exact)>=power(-128) else y*(1+y/2+y*y/6)
        return Q(result)


def exponential_oracle(raw,control,initial):
    if initial&64 or kind(raw) in ('unsupported','nan'):
        return compute(raw,0,'add',control,initial)
    flags=2 if not (raw>>64)&0x7fff and raw&((1<<64)-1) else 0
    if flags&~control&63: return raw,flags,False,False
    # Out-of-domain finite values/infinities are undefined in the ISA. The
    # numeric oracle covers only the specified [-1, 1] domain.
    assert kind(raw)=='finite' and abs(value(raw))<=1
    result=exponential_value(raw)
    out,post,up=rounded(result,control|0x300,bool(raw&SIGN))
    if value(raw) not in (0,1,-1): post |= 32
    return out,flags|post,up,True


@lru_cache(maxsize=None)
def logarithm_value(raw):
    exact=value(raw)
    # Rational binary arguments have rational logarithms only at powers of two.
    if exact.numerator&(exact.numerator-1)==0:
        return Q(exponent(exact))
    with localcontext() as context:
        context.prec=160
        x=Decimal(exact.numerator)/Decimal(exact.denominator)
        return Q(x.ln()/Decimal(2).ln())


def logarithm_oracle(a,b,control,initial):
    if initial&64 or kind(a) in ('unsupported','nan') or kind(b) in ('unsupported','nan'):
        return compute(a,b,'add',control,initial)
    ai,bi=kind(a)=='inf',kind(b)=='inf'
    az=not ai and not value(a)
    bz=not bi and not value(b)
    one=not ai and value(a)==1
    negative=bool(b&SIGN)!=(az or not ai and value(a)<1)
    if a&SIGN and not az or (az or ai) and bz or one and bi:
        return INDEFINITE,1,False,bool(control&1)
    if az:
        # Intel Table 3-50 marks #Z only when ST(1) is finite/nonzero.
        flags=0 if bi else 4
        return (SIGN if negative else 0)|(0x7fff<<64)|INTEGER,flags,False,not flags&~control&63
    flags=2 if any(not (raw>>64)&0x7fff and raw&((1<<64)-1) for raw in (a,b)) else 0
    if flags&~control&63: return a,flags,False,False
    if ai or bi: return (SIGN if negative else 0)|(0x7fff<<64)|INTEGER,flags,False,True
    if one or bz: return SIGN if negative else 0,flags,False,True
    exact=logarithm_value(a)*value(b)
    raw,post,up=rounded(exact,control|0x300)
    numerator=value(a).numerator
    if numerator&(numerator-1): post |= 32
    return raw,flags|post,up,True


@lru_cache(maxsize=None)
def log1p_value(raw):
    exact=value(raw)
    with localcontext() as context:
        context.prec=160
        x=Decimal(exact.numerator)/Decimal(exact.denominator)
        # Decimal ln is independent of the runtime's atanh series. For tiny
        # inputs avoid cancellation; the omitted relative term is < 2^-512.
        result=(1+x).ln() if abs(exact)>=power(-128) else x*(1-x/2+x*x/3-x*x*x/4)
        return Q(result/Decimal(2).ln())


LOG1P_LIMIT=0x3ffd95f619980c4336f7
with localcontext() as context:
    context.prec=160
    domain=Q(1-Decimal(2).sqrt()/2)
    assert value(LOG1P_LIMIT)<=domain<value(LOG1P_LIMIT+1)


def log1p_oracle(a,b,control,initial):
    if initial&64 or kind(a) in ('unsupported','nan') or kind(b) in ('unsupported','nan'):
        return compute(a,b,'add',control,initial)
    # Numeric results outside the Intel-specified domain are undefined.
    assert kind(a)=='finite' and a&~SIGN<=LOG1P_LIMIT
    bi=kind(b)=='inf'
    az=not value(a)
    negative=bool((a^b)&SIGN)
    if az and bi: return INDEFINITE,1,False,bool(control&1)
    flags=2 if any(not (raw>>64)&0x7fff and raw&((1<<64)-1) for raw in (a,b)) else 0
    if flags&~control&63: return a,flags,False,False
    if bi: return (SIGN if negative else 0)|(0x7fff<<64)|INTEGER,flags,False,True
    if az or not value(b): return SIGN if negative else 0,flags,False,True
    exact=log1p_value(a)*value(b)
    raw,post,up=rounded(exact,control|0x300)
    return raw,flags|post|32,up,True


@lru_cache(maxsize=None)
def arctangent_value(a,b):
    ratio=abs(value(b)/value(a))
    swap=ratio>1
    if swap: ratio=1/ratio
    if ratio<power(-128):
        # Keep the negative correction as a Fraction: Decimal would lose it
        # for extreme extended ratios and directed rounding at dyadic inputs.
        angle=ratio-ratio**3/3
    else:
        with localcontext() as context:
            context.prec=160
            z=Decimal(ratio.numerator)/Decimal(ratio.denominator)
            factor=1
            # Independent half-angle reduction, not the runtime's pi/4 shift.
            while z>Decimal('0.125'):
                z=z/(1+(1+z*z).sqrt())
                factor*=2
            term=total=z
            for n in range(3,401,2):
                term *= -z*z
                next_total=total+term/n
                if next_total==total: break
                total=next_total
            else: raise AssertionError('Decimal arctangent did not converge')
            angle=Q(factor*total)
    if swap: angle=constants[3]/2-angle
    if a&SIGN: angle=constants[3]-angle
    return -angle if b&SIGN else angle


def arctangent_oracle(a,b,control,initial):
    if initial&64 or kind(a) in ('unsupported','nan') or kind(b) in ('unsupported','nan'):
        return compute(a,b,'add',control,initial)
    flags=2 if any(not (raw>>64)&0x7fff and raw&((1<<64)-1) for raw in (a,b)) else 0
    if flags&~control&63: return a,flags,False,False
    ai,bi=kind(a)=='inf',kind(b)=='inf'
    az,bz=not ai and not value(a),not bi and not value(b)
    if ai and bi: angle=constants[3]*(Q(3,4) if a&SIGN else Q(1,4))
    elif bz or ai: angle=constants[3] if a&SIGN else Q(0)
    elif bi or az: angle=constants[3]/2
    else: angle=arctangent_value(a,b)
    if ai or bi or az or bz:
        if b&SIGN: angle=-angle
    raw,post,up=rounded(angle,control|0x300,bool(b&SIGN))
    return raw,flags|post|(32 if angle else 0),up,True


@lru_cache(maxsize=None)
def trigonometric_values(raw):
    exact=value(raw)
    if not exact: return Q(0),Q(1)
    if abs(exact)<power(-128):
        # Exact fractions retain the corrections below the input and below one
        # when even a 160-digit Decimal result would round them away.
        return exact-exact**3/6+exact**5/120,1-exact**2/2+exact**4/24-exact**6/720
    with localcontext() as context:
        context.prec=160
        x=Decimal(exact.numerator)/Decimal(exact.denominator)
        pi_half=Decimal(constants[3].numerator)/Decimal(constants[3].denominator)/2
        # Independent Decimal reduction uses the existing Chudnovsky pi value.
        turns=int((x/pi_half).to_integral_value())
        z=x-turns*pi_half
        sine_term=sine=z
        cosine_term=cosine=Decimal(1)
        for n in range(1,100):
            sine_term *= -z*z/((2*n)*(2*n+1))
            cosine_term *= -z*z/((2*n-1)*2*n)
            next_sine,next_cosine=sine+sine_term,cosine+cosine_term
            if next_sine==sine and next_cosine==cosine: break
            sine,cosine=next_sine,next_cosine
        else: raise AssertionError('Decimal sine/cosine did not converge')
        return [(Q(sine),Q(cosine)),(Q(cosine),Q(-sine)),(Q(-sine),Q(-cosine)),(Q(-cosine),Q(sine))][turns%4]


def trigonometric_oracle(raw,cosine,control,initial):
    if initial&64 or kind(raw) in ('unsupported','nan'):
        result=compute(raw,0,'add',control,initial)
        return (*result,False if result[3] else None)
    if kind(raw)=='inf': return INDEFINITE,1,False,bool(control&1),False if control&1 else None
    if abs(value(raw))>=power(63): return raw,0,False,False,True
    flags=2 if not (raw>>64)&0x7fff and raw&((1<<64)-1) else 0
    if flags&~control&63: return raw,flags,False,False,None
    exact=trigonometric_values(raw)[cosine]
    # FSIN/FCOS list no #U. #U masking cannot change their gradual numeric result.
    out,post,up=rounded(exact,control|0x310,bool(raw&SIGN) and not cosine)
    if value(raw): post |= 32
    return out,flags|(post&~16),up,True,False


@lru_cache(maxsize=None)
def tangent_value(raw):
    x=value(raw)
    if abs(x)<power(-128): return x+x**3/3+2*x**5/15+17*x**7/315
    sine,cosine=trigonometric_values(raw)
    return sine/cosine


# Both views inspect one instruction's two results, and these instructions
# ignore PC. Cache the canonical numerical tuple; check every original CW and
# complete state in each guest query.
@lru_cache(maxsize=None)
def paired_trigonometric_oracle(raw,control,tag,tangent=False):
    # An occupied pushed slot and an empty source are operand stack faults.
    if not tag&1 or tag&128:
        return (INDEFINITE,INDEFINITE),65,bool(tag&1),bool(control&1),False if control&1 else None
    if kind(raw) in ('unsupported','nan'):
        result,flags,up,commit=compute(raw,0,'add',control,0)
        return (result,result),flags,up,commit,False if commit else None
    if kind(raw)=='inf': return (INDEFINITE,INDEFINITE),1,False,bool(control&1),False if control&1 else None
    if abs(value(raw))>=power(63): return (raw,raw),0,False,False,True
    flags=2 if not (raw>>64)&0x7fff and raw&((1<<64)-1) else 0
    if flags&~control&63: return (raw,raw),flags,False,False,None
    if tangent:
        result,post,up=rounded(tangent_value(raw),control|0x300,bool(raw&SIGN))
        return (pack(Q(1)),result),flags|post|(32 if value(raw) else 0),up,True,False
    exact_sine,exact_cosine=trigonometric_values(raw)
    sine,sin_flags,up=rounded(exact_sine,control|0x300,bool(raw&SIGN))
    cosine,cos_flags,_=rounded(exact_cosine,control|0x300)
    return (cosine,sine),flags|sin_flags|cos_flags|(32 if value(raw) else 0),up,True,False


def scale_oracle(a,b,control,initial):
    if initial or 'unsupported' in (kind(a),kind(b)) or 'nan' in (kind(a),kind(b)):
        return compute(a,b,'add',control,initial)
    ai,bi=kind(a)=='inf',kind(b)=='inf'
    az=kind(a)=='finite' and not value(a)
    negative=bool(a&SIGN)
    if bi and (ai and b&SIGN or az and not b&SIGN):
        return INDEFINITE,1,False,bool(control&1)
    denorm=lambda raw: not (raw>>64)&0x7fff and raw&((1<<64)-1)!=0
    flags=2 if denorm(a) or denorm(b) else 0
    if flags&~control&63: return a,flags,False,False
    if ai or az: return a,flags,False,True
    if bi:
        return (SIGN if negative else 0)|(0 if b&SIGN else (0x7fff<<64)|INTEGER),flags,False,True
    exact=value(a)
    shift=int(value(b))
    e=exponent(abs(exact))+shift
    mode=(control>>10)&3
    # Compare mathematical exponents before building any enormous power of two.
    if e>16383:
        flags |= 8
        if control&8:
            infinity=mode==0 or mode==1 and negative or mode==2 and not negative
            raw=(0x7fff<<64)|INTEGER if infinity else (0x7ffe<<64)|((1<<64)-1)
            return raw|(SIGN if negative else 0),flags|32,bool(infinity),True
        shift -= 24576
        if e-24576>16383: return (SIGN if negative else 0)|(0x7fff<<64)|INTEGER,flags,False,True
    elif e < -16382 and not control&16:
        flags |= 16
        shift += 24576
        if e+24576 < -16382: return SIGN if negative else 0,flags,False,True
    elif e < -16446:
        up=mode==1 and negative or mode==2 and not negative
        return (SIGN if negative else 0)|int(up),flags|48,bool(up),True
    exact *= power(shift)
    # FSCALE always uses extended precision; RC still controls gradual underflow.
    raw,post,up=rounded(exact,control|0x300,negative)
    return raw,flags|post,up,True


def remainder_step(a,b,nearest,control,tag,status):
    status &= ~0x200
    initial=65 if not tag&1 or not tag&2 else 0
    if initial or 'unsupported' in (kind(a),kind(b)) or 'nan' in (kind(a),kind(b)):
        raw,flags,_,commit=compute(a,b,'add',control,initial)
        status |= flags
        if commit: return raw,tag|1,status&~0x400
        return a,tag,status|0x8080
    if kind(a)=='inf' or kind(b)=='finite' and not value(b):
        if control&1: return INDEFINITE,tag|1,(status&~0x400)|1
        return a,tag,status|0x8081
    denorm=lambda raw: not (raw>>64)&0x7fff and raw&((1<<64)-1)!=0
    status |= 2 if denorm(a) or denorm(b) else 0
    if status&~control&63: return a,tag,status|0x8080
    if kind(b)=='inf' or not value(a): return a,tag,status&~0x4700
    x,y=value(a),value(b)
    gap=exponent(abs(x))-exponent(abs(y))
    partial=gap>=64
    # N=32 is our chosen ISA-permitted partial reduction, not a host CPU claim.
    factor=power(gap-32) if partial else Q(1)
    quotient=int(x/(y*factor)) if partial or not nearest else round(x/y)
    exact=x-y*quotient*factor
    if exact and exponent(abs(exact)) < -16382 and not control&16:
        exact *= power(24576)
        status |= 0x8090
    raw=pack(exact,bool(a&SIGN))
    if partial: status |= 0x400
    else:
        bits=quotient&7
        status=(status&~0x4700)|((bits&4)<<6)|((bits&2)<<13)|((bits&1)<<9)
    return raw,tag|1,status


def oracle(index,control,a,b,tag=3,status=0x4700):
    eflags=0x882
    op,byte=encodings[index]
    group=(byte>>3)&7
    memory=byte<0xc0
    flags=0
    if index in (92,93,94,95):
        results,flags,up,commit,c2=paired_trigonometric_oracle(a,control|0x300,tag,index>=94)
        status=(status&~0x200)|flags|(0x200 if up else 0)
        if c2 is not None: status=(status&~0x400)|(0x400 if c2 else 0)
        if flags&~control&63: status |= 0x8080
        if commit:
            tag |= 129
            status=(status&~0x3800)|0x3800
        raw=results[index&1] if commit else (a if not index&1 else b)
        return raw.to_bytes(10,'little'),status,control,0x1f80,tag,eflags
    if index in (90,91):
        raw,flags,up,commit,c2=trigonometric_oracle(a,index==91,control,65 if not tag&1 else 0)
        status=(status&~0x200)|flags|(0x200 if up else 0)
        if c2 is not None: status=(status&~0x400)|(0x400 if c2 else 0)
        if flags&~control&63: status |= 0x8080
        if commit: tag |= 1
        return (raw if commit else a).to_bytes(10,'little'),status,control,0x1f80,tag,eflags
    if index in (87,88,89):
        operation={87:logarithm_oracle,88:log1p_oracle,89:arctangent_oracle}[index]
        raw,flags,up,commit=operation(a,b,control,65 if not tag&1 or not tag&2 else 0)
        status=(status&~0x200)|flags|(0x200 if up else 0)
        if flags&~control&63: status |= 0x8080
        if commit:
            tag=(tag|2)&~1
            status=(status&~0x3800)|0x800
        return (raw if commit else a).to_bytes(10,'little'),status,control,0x1f80,tag,eflags
    if index==86:
        raw,flags,up,commit=exponential_oracle(a,control,65 if not tag&1 else 0)
        status=(status&~0x200)|flags|(0x200 if up else 0)
        if flags&~control&63: status |= 0x8080
        if commit: tag |= 1
        return (raw if commit else a).to_bytes(10,'little'),status,control,0x1f80,tag,eflags
    if index==85:
        assert tag==1 and control&63==63
        if kind(a)=='unsupported': raw,flags=INDEFINITE,1
        elif kind(a)=='nan': raw,flags=a|QUIET,int(not a&QUIET)
        elif kind(a)=='inf': raw=a
        else:
            raw=pack(value(a),bool(a&SIGN))
            flags=4 if not value(a) else 2 if not (a>>64)&0x7fff else 0
        return raw.to_bytes(10,'little'),status&~0x200|flags,control,0x1f80,1,eflags
    if index==84:
        raw,flags,up,commit=scale_oracle(a,b,control,65 if not tag&1 or not tag&2 else 0)
        status=(status&~0x200)|flags|(0x200 if up else 0)
        if flags&~control&63: status |= 0x8080
        if commit: tag |= 1
        return (raw if commit else a).to_bytes(10,'little'),status,control,0x1f80,tag,eflags
    if byte in (0xf5,0xf8) and op==0xd9:
        for _ in range(1100 if index>=82 else 1):
            a,tag,status=remainder_step(a,b,byte==0xf5,control,tag,status)
            if not status&0x400 or status&0x80: break
        else:
            assert index<82, 'partial reduction did not converge'
        return a.to_bytes(10,'little'),status,control,0x1f80,tag,eflags
    if byte==0xf4 and op==0xd9:
        status &= ~0x200
        if tag&128:
            flags=0x41
            status |= 0x200
            significand=scale=INDEFINITE
        elif not tag&1 or kind(a)=='unsupported':
            flags=0x41 if not tag&1 else 1
            significand=scale=INDEFINITE
        elif kind(a)=='nan':
            flags=int(not a&QUIET)
            significand=scale=a|QUIET
        elif kind(a)=='inf':
            significand,scale=a,(0x7fff<<64)|INTEGER
        elif not value(a):
            flags=4
            significand,scale=a,(0xffff<<64)|INTEGER
        else:
            exact=value(a)
            e=exponent(abs(exact))
            significand,scale=extended(exact/power(e)),extended(Q(e))
            flags=2 if not (a>>64)&0x7fff else 0
        status |= flags
        if flags&~control&63:
            raw=a if index==78 else b
            status |= 0x8080
        else:
            raw=significand if index==78 else scale
            status=(status&~0x3800)|0x3800
            tag |= 129
        return raw.to_bytes(10,'little'),status,control,0x1f80,tag,eflags
    if op==0xd9 and 0xe8<=byte<=0xee:
        if tag&128:
            status|=0x241
            if control&1: return INDEFINITE.to_bytes(10,'little'),(status&~0x3800)|0x3800,control,0x1f80,tag,eflags
            return a.to_bytes(10,'little'),status|0x8080,control,0x1f80,tag,eflags
        exact=constants[byte-0xe8]
        n,_=quantize(exact,power(exponent(exact)-63) if exact else Q(1),(control>>10)&3,False)
        raw=pack(n*power(exponent(exact)-63)) if exact else 0
        return raw.to_bytes(10,'little'),(status&~0x3a00)|0x3800,control,0x1f80,tag|128,eflags
    if not memory and op in (0xda,0xdb) and byte<0xe0:
        seed,tag=tag>>8,tag&255
        eflags=(2,0x46,0x87,0x83)[seed]
        missing=not tag&1 or not tag&2
        if missing:
            status=(status&~0x200)|0x41
            if not control&1: return a.to_bytes(10,'little'),status|0x8080,control,0x1f80,tag,eflags
            return INDEFINITE.to_bytes(10,'little'),status,control,0x1f80,tag|1,eflags
        condition=(bool(eflags&1),bool(eflags&64),bool(eflags&65),bool(eflags&4))[group]
        return (b if condition==(op==0xda) else a).to_bytes(10,'little'),status,control,0x1f80,tag,eflags
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
for index,(op,byte) in enumerate(encodings[:63]):
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
for index in range(63,70):
    for precision in range(4):
        for mode in range(4):
            for tag in (0,3,255):
                for unmask in (0,1,32,63): add(index,(0x7f|(precision<<8)|(mode<<10))&~unmask,INDEFINITE,SIGN,tag)
for index in range(70,78):
    for seed in range(4):
        for tag in range(4):
            for control in (0x37f,0x37e,0x7f,0x77d,0xb7f,0xf7f):
                for a,b in zip(special,special[::-1]): add(index,control,a,b,tag|(seed<<8))
extract_edges=special+[(0x7ffe<<64)|((1<<64)-1), (1<<64)|INTEGER, (0x3fff<<64)|((1<<64)-1)]
extract_edges += [1<<bit for bit in range(64)]
extract_edges += [pack(power(e)) for e in (-16382,-16000,-64,-1,0,1,63,16000,16383)]
extract_edges += [raw^SIGN for raw in extract_edges]
for index in (78,79):
    for precision in range(4):
        for mode in range(4):
            for raw in extract_edges:
                add(index,0x7f|(precision<<8)|(mode<<10),raw,extended(Q(7)),1)
    for raw in extract_edges:
        for mask in (1,2,4,32,63):
            add(index,0x37f&~mask,raw,extended(Q(7)),1)
    for tag in (0,128,129,255):
        for control in (0x37f,0x37e):
            add(index,control,extended(Q(3)),extended(Q(7)),tag)
extract_rng=random.Random(0xf4)
for _ in range(128):
    raw=(extract_rng.randrange(1,0x7fff)<<64)|INTEGER|extract_rng.getrandbits(64)|(SIGN if extract_rng.randrange(2) else 0)
    for index in (78,79): add(index,0x37f,raw,extended(Q(7)),1)
remainder_pairs=finite_pairs+[(Q(n,2),Q(d)) for n in (-15,-13,-11,-9,-7,-5,-3,-1,1,3,5,7,9,11,13,15) for d in (-4,-2,2,4)]
remainder_pairs += [(power(e)+power(e-63),Q(3)) for e in (63,64,65,95,96,97,100,127,128,129,16383)]
remainder_pairs += [(power(-16382)+power(-16445),power(-16382)),(power(-16445),power(-16444))]
for index in (80,81):
    pairs=[(pack(a),pack(b)) for a,b in remainder_pairs]+[(a,b) for a in special for b in special]
    for precision in range(4):
        for mode in range(4):
            for a,b in pairs: add(index,0x7f|(precision<<8)|(mode<<10),a,b)
    for unmask in (1,2,4,16,32,63):
        for a,b in pairs: add(index,0x37f&~unmask,a,b)
    for tag in (0,1,2):
        for control in (0x37f,0x37e): add(index,control,extended(Q(3)),extended(Q(7)),tag)
# Completed binary64-sized remainders also agree with the native host math library.
native_remainders=0
for x in (Q(n,8) for n in range(-40,41)):
    for y in (Q(-7,4),Q(-1,4),Q(1,4),Q(7,4)):
        for index,operation in ((80,math.fmod),(81,math.remainder)):
            raw,_,_=remainder_step(extended(x),extended(y),index==81,0x37f,3,0x4700)
            actual=float(value(raw)) if value(raw) else (-0.0 if raw&SIGN else 0.0)
            expected_native=operation(float(x),float(y))
            assert struct.pack('<d',actual)==struct.pack('<d',expected_native),(x,y,index,actual,expected_native)
            add(index,0x37f,extended(x),extended(y))
            native_remainders+=1
for index in (82,83):
    for x,y in remainder_pairs:
        if y:
            for control in (0x7f,0x27f,0x37f,0xf7f): add(index,control,pack(x),pack(y))
    for e in (64,96,128,1024,8192,16383):
        for sign_a in (-1,1):
            for sign_b in (-1,1): add(index,0x37f,pack(sign_a*(power(e)+power(e-63))),pack(sign_b*3*power(-16445)))
rng=random.Random(0x873)
for _ in range(750):
    index=rng.choice([*range(18),61,62])
    raw=lambda: (rng.randrange(1,0x7fff)<<64)|INTEGER|rng.getrandbits(64)|(SIGN if rng.randrange(2) else 0)
    add(index,0x7f|(rng.choice((0,2,3))<<8)|(rng.randrange(4)<<10),raw(),raw())
for _ in range(128):
    raw=lambda: (rng.randrange(1,0x7fff)<<64)|INTEGER|rng.getrandbits(64)|(SIGN if rng.randrange(2) else 0)
    a,b=raw(),raw()
    for index in (80,81,82,83): add(index,0x37f,a,b)
scale_values=extract_edges
scale_amounts=[pack(Q(n,4)) for n in (-15,-5,-3,-1,0,1,3,5,15)]
scale_amounts += [pack(Q(n)) for n in (-1000000000,-65536,-40960,-24576,-16446,-16383,16383,16446,24576,40960,65536,1000000000)]
scale_amounts += special
for precision in range(4):
    for mode in range(4):
        control=0x7f|(precision<<8)|(mode<<10)
        for a,b in zip(scale_values,scale_amounts*(len(scale_values)//len(scale_amounts)+1)):
            add(84,control,a,b)
        for a in scale_values:
            add(85,control,a,0,1)
for a in special+[pack(power(-16382)+power(-16445)),pack(power(16383)),(0x7ffe<<64)|((1<<64)-1)]:
    for b in scale_amounts+[(0x7ffe<<64)|((1<<64)-1),(0xfffe<<64)|((1<<64)-1)]:
        for unmask in (0,1,2,8,16,32,63): add(84,0x37f&~unmask,a,b)
for tag in (0,1,2):
    for control in (0x37f,0x37e): add(84,control,extended(Q(3)),extended(Q(7)),tag)
native_scalings=0
for x in (Q(n,8) for n in range(-31,32)):
    for y in (Q(-31,4),Q(-3,4),Q(3,4),Q(31,4)):
        raw,_,_,_=scale_oracle(extended(x),extended(y),0x37f,0)
        actual=float(value(raw)) if value(raw) else (-0.0 if raw&SIGN else 0.0)
        expected_native=math.ldexp(float(x),int(y))
        assert struct.pack('<d',actual)==struct.pack('<d',expected_native),(x,y,actual,expected_native)
        add(84,0x37f,extended(x),extended(y))
        native_scalings+=1
exponential_start=len(queries)
exponential_edges=[0,SIGN,pack(Q(1)),pack(Q(-1)),(0x3ffe<<64)|((1<<64)-1),(0xbffe<<64)|((1<<64)-1)]
exponential_edges += [pack(Q(n,128)) for n in range(-127,128)]
exponential_edges += [raw|signed for raw in (1<<bit for bit in range(64)) for signed in (0,SIGN)]
exponential_edges += [raw|signed for raw in (INTEGER-1,INTEGER,INTEGER+1,(1<<64)|INTEGER,(1<<64)|INTEGER|1,(1<<64)|((1<<64)-1)) for signed in (0,SIGN)]
exponential_edges += [pack(signed*power(e)) for e in (-16000,-8192,-129,-128,-127,-114,-113,-112,-65,-64,-63,-2,-1) for signed in (-1,1)]
exponential_edges += [raw for raw in special if kind(raw) not in ('finite','inf')]
monotonic_blocks=[]
for precision in range(4):
    for mode in range(4):
        control=0x7f|(precision<<8)|(mode<<10)
        start=len(queries)
        for raw in exponential_edges: add(86,control,raw,INDEFINITE,1)
        monotonic_blocks.append(sorted((start+n for n,raw in enumerate(exponential_edges) if kind(raw)=='finite'),key=lambda n:value(queries[n][2])))
for raw in exponential_edges:
    for mode in range(4):
        for unmask in (1,2,16,32,63): add(86,(0x37f|(mode<<10))&~unmask,raw,INDEFINITE,1)
for tag in (0,2,128,255):
    for control in (0x37f,0x37e,0x35e): add(86,control,pack(Q(1,2)),INDEFINITE,tag)
exp_rng=random.Random(0xf0)
for _ in range(512):
    exp=exp_rng.choice((exp_rng.randrange(1,0x3fff),exp_rng.randrange(0x3fc0,0x3fff)))
    raw=(exp<<64)|INTEGER|exp_rng.getrandbits(63)|(SIGN if exp_rng.randrange(2) else 0)
    for mode in range(4): add(86,0x37f|(mode<<10),raw,INDEFINITE,1)
# Adjacent representable inputs around dyadic powers exercise monotonicity and
# the boundaries where exp-minus-one would cancel or change output exponent.
for e in (-128,-113,-64,-63,-2,-1):
    center=pack(power(e))
    for offset in (-1,0,1):
        raw=center+offset if offset>=0 else ((center>>64)-1)<<64|((1<<64)-1)
        for signed in (0,SIGN):
            for mode in range(4): add(86,0x37f|(mode<<10),raw|signed,INDEFINITE,1)
native_exponentials=0
for n in range(-128,129):
    a=pack(Q(n,128))
    raw,_,_,_=exponential_oracle(a,0x37f,0)
    actual=float(value(raw))
    expected_native=math.expm1((n/128)*math.log(2))
    assert abs(actual-expected_native)<=3*math.ulp(expected_native),(n,actual,expected_native)
    add(86,0x37f,a,INDEFINITE,1)
    native_exponentials+=1
exponential_queries=len(queries)-exponential_start
logarithm_start=len(queries)
log_x=[1<<bit for bit in range(64)]
log_x += [INTEGER-1,INTEGER,INTEGER+1,(1<<64)|INTEGER,(1<<64)|INTEGER|1,(0x7ffe<<64)|((1<<64)-1)]
log_x += [pack(power(e)) for e in (-16382,-16000,-8192,-65,-64,-1,0,1,14,63,8192,16000,16383)]
log_x += [0x3ffeffffffffffffffff,0x3fff8000000000000001,pack(Q(3))]
# Centered reduction changes at 1.5; its neighbors must preserve continuity.
log_x += [pack(Q(3,2))+offset for offset in (-1,0,1)]
log_y=[raw|signed for raw in log_x for signed in (0,SIGN)]+special
log_pairs=[(x,pack(y)) for x in log_x for y in (Q(1),Q(-3))]
log_pairs += [(x,y) for x in (pack(Q(2)),0x3ffeffffffffffffffff,0x3fff8000000000000001) for y in log_y]
log_pairs += [(a,b) for a in special+[pack(Q(1)),pack(Q(2)),pack(Q(1,2)),pack(Q(-2))] for b in special+[pack(Q(1)),pack(Q(-3))]]
log_monotonic_blocks=[]
for precision in range(4):
    for mode in range(4):
        control=0x7f|(precision<<8)|(mode<<10)
        start=len(queries)
        for a,b in log_pairs: add(87,control,a,b)
        for multiplier in (Q(1),Q(-3)):
            block=[start+n for n,(a,b) in enumerate(log_pairs) if b==pack(multiplier) and kind(a)=='finite' and value(a)>0]
            log_monotonic_blocks.append((sorted(block,key=lambda n:value(queries[n][2])),multiplier<0))
for a,b in log_pairs[:32]+log_pairs[-195:]+[(0x3fff8000000000000001,1),(0x7ffe8000000000000000,(0x7ffe<<64)|((1<<64)-1))]:
    for mode in range(4):
        for unmask in (1,2,4,8,16,32,63): add(87,(0x37f|(mode<<10))&~unmask,a,b)
for tag in (0,1,2,255):
    for control in (0x37f,0x37e,0x35e): add(87,control,pack(Q(2)),pack(Q(3)),tag)
log_rng=random.Random(0xf1)
for _ in range(256):
    a=(log_rng.randrange(1,0x7fff)<<64)|INTEGER|log_rng.getrandbits(63)
    b=(log_rng.randrange(1,0x7fff)<<64)|INTEGER|log_rng.getrandbits(63)|(SIGN if log_rng.randrange(2) else 0)
    for mode in range(4): add(87,0x37f|(mode<<10),a,b)
native_logarithms=0
for n in range(1,129):
    for multiplier in (Q(-7,8),Q(0),Q(7,8)):
        a,b=pack(Q(n,16)),pack(multiplier)
        raw,_,_,_=logarithm_oracle(a,b,0x37f,0)
        actual=float(value(raw))
        expected_native=float(multiplier)*math.log2(n/16)
        assert abs(actual-expected_native)<=3*math.ulp(expected_native),(n,multiplier,actual,expected_native)
        add(87,0x37f,a,b)
        native_logarithms+=1
logarithm_queries=len(queries)-logarithm_start
log1p_start=len(queries)
log1p_x=[0,SIGN]+[raw|signed for raw in (1<<bit for bit in range(64)) for signed in (0,SIGN)]
log1p_x += [raw|signed for raw in (INTEGER-1,INTEGER,INTEGER+1,(1<<64)|INTEGER,(1<<64)|INTEGER|1,LOG1P_LIMIT-1,LOG1P_LIMIT) for signed in (0,SIGN)]
log1p_x += [pack(signed*power(e)) for e in (-16382,-16000,-8192,-129,-128,-127,-114,-113,-112,-65,-64,-63,-3,-2) for signed in (-1,1)]
log1p_x += [pack(Q(n,128)) for n in range(-37,38)]
log1p_pairs=[(a,pack(b)) for a in log1p_x for b in (Q(1),Q(-3))]
log1p_pairs += [(a,b) for a in (pack(Q(1,4)),pack(Q(-1,4)),1,SIGN|1) for b in log_y]
log1p_special=[a for a in special if kind(a) in ('unsupported','nan') or kind(a)=='finite' and a&~SIGN<=LOG1P_LIMIT]
log1p_pairs += [(a,b) for a in log1p_special for b in special+[pack(Q(1)),pack(Q(-3))]]
log1p_monotonic_blocks=[]
for precision in range(4):
    for mode in range(4):
        control=0x7f|(precision<<8)|(mode<<10)
        start=len(queries)
        for a,b in log1p_pairs: add(88,control,a,b)
        for multiplier in (Q(1),Q(-3)):
            block=[start+n for n,(a,b) in enumerate(log1p_pairs) if b==pack(multiplier) and kind(a)=='finite']
            log1p_monotonic_blocks.append((sorted(block,key=lambda n:value(queries[n][2])),multiplier<0))
# Operand faults and biased result exceptions, including two minimum inputs.
log1p_fault_pairs=[(a,b) for a in log1p_x for b in (1,(1<<64)|INTEGER)]
log1p_fault_pairs += log1p_pairs[-len(log1p_special)*(len(special)+2):]
for a,b in log1p_fault_pairs:
    for mode in range(4):
        for unmask in (1,2,16,32,63): add(88,(0x37f|(mode<<10))&~unmask,a,b)
for tag in (0,1,2,255):
    for control in (0x37f,0x37e,0x35e): add(88,control,pack(Q(1,4)),pack(Q(3)),tag)
log1p_rng=random.Random(0xf9)
for _ in range(256):
    a=(log1p_rng.randrange(1,0x3ffe)<<64)|INTEGER|log1p_rng.getrandbits(63)
    if a>LOG1P_LIMIT: a=LOG1P_LIMIT-log1p_rng.randrange((LOG1P_LIMIT&((1<<64)-1))-INTEGER+1)
    a |= SIGN if log1p_rng.randrange(2) else 0
    b=(log1p_rng.randrange(1,0x7fff)<<64)|INTEGER|log1p_rng.getrandbits(63)|(SIGN if log1p_rng.randrange(2) else 0)
    for mode in range(4): add(88,0x37f|(mode<<10),a,b)
native_log1ps=0
for n in range(-37,38):
    for multiplier in (Q(-7,8),Q(0),Q(7,8)):
        a,b=pack(Q(n,128)),pack(multiplier)
        raw,_,_,_=log1p_oracle(a,b,0x37f,0)
        actual=float(value(raw))
        expected_native=float(multiplier)*math.log1p(n/128)/math.log(2)
        assert abs(actual-expected_native)<=3*math.ulp(expected_native),(n,multiplier,actual,expected_native)
        add(88,0x37f,a,b)
        native_log1ps+=1
log1p_queries=len(queries)-log1p_start
arctangent_start=len(queries)
atan_pairs=[(a,pack(b)) for a in extract_edges for b in (Q(1),Q(-3))]
atan_pairs += [(pack(a),b) for a in (Q(1),Q(-1)) for b in extract_edges]
atan_pairs += [(a,b) for a in special for b in special]
atan_pairs += [(a,b) for a in (1,(1<<64)|INTEGER,(0x7ffe<<64)|((1<<64)-1)) for b in (1,(1<<64)|INTEGER,(0x7ffe<<64)|((1<<64)-1))]
for e in (-128,-65,-64,-33,-32,-31,-2,-1,0):
    center=pack(power(e))
    neighbors=[((center>>64)-1)<<64|((1<<64)-1),center,center+1]
    for a in (pack(Q(1)),pack(Q(-1))):
        for b in neighbors:
            for signed in (0,SIGN): atan_pairs.append((a,b|signed))
atan_monotonic_blocks=[]
for precision in range(4):
    for mode in range(4):
        control=0x7f|(precision<<8)|(mode<<10)
        start=len(queries)
        for a,b in atan_pairs: add(89,control,a,b)
        for x,y_sign in ((Q(1),None),(Q(-1),False),(Q(-1),True)):
            block=[start+n for n,(a,b) in enumerate(atan_pairs) if a==pack(x) and kind(b)=='finite' and (y_sign is None or value(b) and bool(b&SIGN)==y_sign)]
            atan_monotonic_blocks.append((sorted(block,key=lambda n:value(queries[n][3])),x<0))
for a,b in atan_pairs:
    if kind(a)=='finite' and kind(b)=='finite' and a not in (pack(Q(1)),pack(Q(-1)),1) and b not in (1,(1<<64)|INTEGER): continue
    for mode in range(4):
        for unmask in (1,2,16,32,63): add(89,(0x37f|(mode<<10))&~unmask,a,b)
for tag in (0,1,2,255):
    for control in (0x37f,0x37e,0x35e): add(89,control,pack(Q(1)),pack(Q(3)),tag)
atan_rng=random.Random(0xf3)
for _ in range(256):
    raw=lambda: (atan_rng.randrange(1,0x7fff)<<64)|INTEGER|atan_rng.getrandbits(63)|(SIGN if atan_rng.randrange(2) else 0)
    a,b=raw(),raw()
    for mode in range(4): add(89,0x37f|(mode<<10),a,b)
native_arctangents=0
for x in (Q(n,8) for n in range(-16,17)):
    for y in (Q(n,8) for n in range(-16,17)):
        a,b=pack(x),pack(y)
        raw,_,_,_=arctangent_oracle(a,b,0x37f,0)
        actual=float(value(raw)) if value(raw) else (-0.0 if raw&SIGN else 0.0)
        expected_native=math.atan2(float(y),float(x))
        assert abs(actual-expected_native)<=3*math.ulp(expected_native),(x,y,actual,expected_native)
        if expected_native==0: assert struct.pack('<d',actual)==struct.pack('<d',expected_native)
        add(89,0x37f,a,b)
        native_arctangents+=1
arctangent_queries=len(queries)-arctangent_start
trigonometry_start=len(queries)
trig_edges=set(extract_edges)
for e in (-129,-128,-65,-64,-33,-32,-31,-17,-16,-15,-1,0,1,31,62,63):
    center=pack(power(e))
    for raw in (((center>>64)-1)<<64|((1<<64)-1),center,center+1):
        trig_edges.update((raw,raw|SIGN))
for multiplier in (Q(1,2),Q(1),Q(3,2),Q(2),Q(7),power(31),power(62)):
    center=rounded(constants[3]*multiplier,0x37f)[0]
    for offset in range(-4,5): trig_edges.update((center+offset,(center+offset)|SIGN))
trig_edges.update(pack(Q(n,32)) for n in range(-256,257))
trig_edges=sorted(trig_edges)
trig_monotonic_blocks=[]
for index in (90,91):
    for precision in range(4):
        for mode in range(4):
            control=0x7f|(precision<<8)|(mode<<10)
            start=len(queries)
            for raw in trig_edges: add(index,control,raw,pack(Q(3)))
            # Continuous monotone intervals avoid periodic wraparound.
            intervals=((-Q(1),Q(1),False),) if index==90 else ((-Q(2),Q(0),False),(Q(0),Q(2),True))
            for lo,hi,descending in intervals:
                block=[start+n for n,raw in enumerate(trig_edges) if kind(raw)=='finite' and lo<=value(raw)<=hi]
                trig_monotonic_blocks.append((sorted(block,key=lambda n:value(queries[n][2])),descending))
    for raw in trig_edges:
        if kind(raw)=='finite' and abs(value(raw))<power(63) and raw not in (1,SIGN|1,(1<<64)|INTEGER,pack(Q(1)),pack(power(-31)),pack(power(-16))): continue
        for mode in range(4):
            for unmask in (1,2,16,32,63):
                for status in (0x4300,0x4700): add(index,(0x37f|(mode<<10))&~unmask,raw,0,status=status)
    for raw in (1,(1<<64)|INTEGER,pack(Q(1)),pack(power(63))):
        for mode in range(4): add(index,0x37f|(mode<<10),raw,0,status=0x4710)
    for tag in (0,2,255):
        for control in (0x37f,0x37e,0x35e): add(index,control,pack(Q(1)),pack(Q(3)),tag)
trig_rng=random.Random(0xfeff)
trig_random_values=[]
for _ in range(256):
    e=trig_rng.choice((0,1,0x3fff+trig_rng.randrange(-128,64),trig_rng.randrange(1,0x7fff)))
    raw=(e<<64)|INTEGER|trig_rng.getrandbits(63)|(SIGN if trig_rng.randrange(2) else 0)
    trig_random_values.append(raw)
    for index in (90,91):
        for mode in range(4): add(index,0x37f|(mode<<10),raw,0)
native_trigonometry=0
native_angles=[Q(n,32) for n in range(-256,257)]
native_angles += [signed*power(e) for e in range(63) for signed in (-1,1)]
native_angles += [Q.from_float(math.nextafter(2.0**63,0))]
native_angles += [Q.from_float(math.ldexp(trig_rng.uniform(-1,1),trig_rng.randrange(-64,64))) for _ in range(128)]
for exact in native_angles:
    for index,fn in ((90,math.sin),(91,math.cos)):
        raw=pack(exact)
        result,_,_,_,_=trigonometric_oracle(raw,index==91,0x37f,0)
        actual=float(value(result))
        expected_native=fn(float(exact))
        assert abs(actual-expected_native)<=3*math.ulp(expected_native),(index,exact,actual,expected_native)
        add(index,0x37f,raw,0)
        native_trigonometry+=1
trigonometry_queries=len(queries)-trigonometry_start
sincos_start=len(queries)
sincos_monotonic_blocks=[]
for index in (92,93):
    for precision in range(4):
        for mode in range(4):
            start=len(queries)
            for raw in trig_edges: add(index,0x7f|(precision<<8)|(mode<<10),raw,pack(Q(3)))
            intervals=((-Q(1),Q(1),False),) if index==93 else ((-Q(2),Q(0),False),(Q(0),Q(2),True))
            for lo,hi,descending in intervals:
                block=[start+n for n,raw in enumerate(trig_edges) if kind(raw)=='finite' and lo<=value(raw)<=hi]
                sincos_monotonic_blocks.append((sorted(block,key=lambda n:value(queries[n][2])),descending))
    for raw in extract_edges+[pack(Q(1)),pack(constants[0]),0x3fffc90fdaa22168c235]:
        for mode in range(4):
            for unmask in (1,2,16,32,63): add(index,(0x37f|(mode<<10))&~unmask,raw,pack(Q(3)))
    for tag in (0,1,2,3,128,129,255):
        for raw in (1,pack(Q(1)),pack(power(63)),(0x7fff<<64)|INTEGER|QUIET):
            for control in (0x37f,0x37e,0x35e):
                for status in (0x4300,0x4700): add(index,control,raw,pack(Q(3)),tag,status)
    for raw in (1,(1<<64)|INTEGER,pack(Q(1))):
        for mode in range(4): add(index,0x37f|(mode<<10),raw,0,status=0x4710)
for raw in trig_random_values:
    for index in (92,93):
        for mode in range(4): add(index,0x37f|(mode<<10),raw,pack(Q(3)))
sincos_queries=len(queries)-sincos_start
tangent_start=len(queries)
tangent_monotonic_blocks=[]
for index in (94,95):
    for precision in range(4):
        for mode in range(4):
            start=len(queries)
            for raw in trig_edges: add(index,0x7f|(precision<<8)|(mode<<10),raw,pack(Q(3)))
            if index==95:
                block=[start+n for n,raw in enumerate(trig_edges) if kind(raw)=='finite' and -Q(1)<=value(raw)<=Q(1)]
                tangent_monotonic_blocks.append(sorted(block,key=lambda n:value(queries[n][2])))
    for raw in extract_edges+[pack(Q(1)),0x3fffc90fdaa22168c235,0x4000c90fdaa22168c235]:
        for mode in range(4):
            for unmask in (1,2,16,32,63): add(index,(0x37f|(mode<<10))&~unmask,raw,pack(Q(3)))
    for tag in (0,1,2,3,128,129,255):
        for raw in (1,pack(Q(1)),pack(power(63)),(0x7fff<<64)|INTEGER|QUIET):
            for control in (0x37f,0x37e,0x35e):
                for status in (0x4300,0x4700): add(index,control,raw,pack(Q(3)),tag,status)
    for raw in (1,(1<<64)|INTEGER,pack(Q(1))):
        for mode in range(4): add(index,0x37f|(mode<<10),raw,0,status=0x4710)
for raw in trig_random_values:
    for index in (94,95):
        for mode in range(4): add(index,0x37f|(mode<<10),raw,pack(Q(3)))
native_tangents=0
for exact in native_angles:
    raw=pack(exact)
    result=paired_trigonometric_oracle(raw,0x37f,3,True)[0][1]
    actual=float(value(result))
    expected_native=math.tan(float(exact))
    assert abs(actual-expected_native)<=3*math.ulp(expected_native),(exact,actual,expected_native)
    add(95,0x37f,raw,0)
    native_tangents+=1
tangent_queries=len(queries)-tangent_start
expected=[oracle(*q) for q in queries]
stdin=b''.join(struct.pack('<IIQQQQII',idx,cw,a&((1<<64)-1),a>>64,b&((1<<64)-1),b>>64,tag,status) for idx,cw,a,b,tag,status in queries)
for engine in [[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else []):
    run=subprocess.run([str(RUNTIME),*engine,'--max-instructions','100000000','--timeout-ms','60000',str(ROOT/'artifacts/guests/x86_64/x87-arithmetic')],input=stdin,capture_output=True,timeout=75)
    assert run.returncode==0 and not run.stderr,(engine,run.returncode,len(run.stdout),run.stderr)
    assert len(run.stdout)==len(queries)*32,(len(run.stdout),len(queries)*32)
    bad=[(n,actual) for n,actual in enumerate(struct.iter_unpack('<10sHIIB3xQ',run.stdout)) if actual!=expected[n]]
    assert not bad,'\n'.join(f'{engine} query {n} encoding={encodings[queries[n][0]]} input={tuple(hex(v) for v in queries[n])}: actual={actual}, expected={expected[n]}' for n,actual in bad[:8])+f'\n{len(bad)} mismatches'
    for block in monotonic_blocks:
        results=[value(int.from_bytes(run.stdout[n*32:n*32+10],'little')) for n in block]
        assert all(a<=b for a,b in zip(results,results[1:])), ('F2XM1 monotonicity',engine)
    for block,descending in log_monotonic_blocks:
        results=[value(int.from_bytes(run.stdout[n*32:n*32+10],'little')) for n in block]
        assert all(a>=b if descending else a<=b for a,b in zip(results,results[1:])), ('FYL2X monotonicity',engine)
    for block,descending in log1p_monotonic_blocks:
        results=[value(int.from_bytes(run.stdout[n*32:n*32+10],'little')) for n in block]
        assert all(a>=b if descending else a<=b for a,b in zip(results,results[1:])), ('FYL2XP1 monotonicity',engine)
    for block,descending in atan_monotonic_blocks:
        results=[value(int.from_bytes(run.stdout[n*32:n*32+10],'little')) for n in block]
        assert all(a>=b if descending else a<=b for a,b in zip(results,results[1:])), ('FPATAN monotonicity',engine)
    for block,descending in trig_monotonic_blocks:
        results=[value(int.from_bytes(run.stdout[n*32:n*32+10],'little')) for n in block]
        assert all(a>=b if descending else a<=b for a,b in zip(results,results[1:])), ('FSIN/FCOS monotonicity',engine)
    for block,descending in sincos_monotonic_blocks:
        results=[value(int.from_bytes(run.stdout[n*32:n*32+10],'little')) for n in block]
        assert all(a>=b if descending else a<=b for a,b in zip(results,results[1:])), ('FSINCOS monotonicity',engine)
    for block in tangent_monotonic_blocks:
        results=[value(int.from_bytes(run.stdout[n*32:n*32+10],'little')) for n in block]
        assert all(a<=b for a,b in zip(results,results[1:])), ('FPTAN monotonicity',engine)
    # Continued-fraction p/q lies just below log2(3). Binary128 sees the
    # normalized product as the integer p, but the true tiny result is inexact.
    # Keep the exact oracle above intact. These hard cases check nearest exactly,
    # all RC modes within one subnormal destination step, and mandatory #U/#P.
    q=0x3ae12d1921f03199
    controls=[0x7f|(precision<<8)|(mode<<10) for precision in range(4) for mode in range(4)]
    hard_input=b''.join(struct.pack('<IIQQQQII',87,cw,0xc000000000000000,0x4000,q,0,3,0x4700) for cw in controls)
    hard=subprocess.run([str(RUNTIME),*engine,'--max-instructions','100000000','--timeout-ms','60000',str(ROOT/'artifacts/guests/x86_64/x87-arithmetic')],input=hard_input,capture_output=True,timeout=75)
    assert hard.returncode==0 and not hard.stderr and len(hard.stdout)==16*32,(engine,hard.returncode,hard.stderr)
    true_result=logarithm_value(pack(Q(3)))*value(q)
    for cw,(raw,status,control,mxcsr,tag,eflags) in zip(controls,struct.iter_unpack('<10sHIIB3xQ',hard.stdout)):
        actual=int.from_bytes(raw,'little')
        assert (status,control,mxcsr,tag,eflags)==(0x4d32,cw,0x1f80,2,0x882),(engine,cw,status)
        assert abs(value(actual)-true_result)<power(-16445),(engine,cw,hex(actual))
        if (cw>>10)&3==0: assert actual==rounded(true_result,cw|0x300)[0]
    print(f'x87 calculations: {len(queries)} Fraction/decimal/bit queries passed ({"JIT" if engine else "interpreter"})',flush=True)
print(f'x87 remainders: {native_remainders} native host binary64 numeric comparisons passed; native x87 hardware/flags remain unverified')
print(f'x87 scaling: {native_scalings} native host binary64 numeric comparisons passed; exponent extremes and reconstruction use Fraction/bit checks')
print(f'x87 F2XM1: {exponential_queries} new decimal/bit queries per engine, 16 sampled monotonicity sequences and {native_exponentials} bounded native expm1 comparisons (3 binary64 ulps); universal correct rounding and native x87 hardware/flags remain unverified')
print(f'x87 FYL2X: {logarithm_queries} new decimal/bit queries per engine, 32 sampled monotonicity sequences and {native_logarithms} bounded native log2 comparisons (3 binary64 ulps); universal correct rounding and native x87 hardware/flags remain unverified')
print('x87 FYL2X hard underflow: 16 additional queries per engine; nearest matches Decimal, all RC modes stay within one subnormal step and retain denormal/underflow/precision flags; C1 follows our approximation profile')
print(f'x87 FYL2XP1: {log1p_queries} new decimal/bit queries per engine, 32 sampled monotonicity sequences and {native_log1ps} bounded native log1p comparisons (3 binary64 ulps); universal correct rounding and native x87 hardware/flags remain unverified')
print(f'x87 FPATAN: {arctangent_queries} new decimal/bit queries per engine, 48 sampled monotonicity sequences and {native_arctangents} bounded native atan2 comparisons (3 binary64 ulps); universal correct rounding and native x87 hardware/flags remain unverified')
print(f'x87 FSIN/FCOS: {trigonometry_queries} new decimal/bit queries per engine, {len(trig_monotonic_blocks)} sampled monotonicity sequences and {native_trigonometry} bounded native sin/cos comparisons (3 binary64 ulps); universal correct rounding and native x87 hardware/flags remain unverified')
print(f'x87 FSINCOS: {sincos_queries} new decimal/bit queries per engine, {len(sincos_monotonic_blocks)} sampled monotonicity sequences; both stack results, operand/stack faults, range boundaries and gradual/biased underflow; C1 follows the sine result in our profile; native x87 hardware/flags remain unverified')
print(f'x87 FPTAN: {tangent_queries} new decimal/bit queries per engine, {len(tangent_monotonic_blocks)} sampled monotonicity sequences and {native_tangents} bounded native tan comparisons (3 binary64 ulps); both stack outputs and gradual/biased underflow; native x87 hardware/flags and universal correct rounding remain unverified')
