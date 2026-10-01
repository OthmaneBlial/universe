#!/usr/bin/env python3
"""SDK message calls against native snprintf, Python UTF-16 units and independent wrapping."""
import ctypes, pathlib, platform, random, struct, subprocess, textwrap

ROOT=pathlib.Path(__file__).resolve().parents[1]
RUNTIME=ROOT/'zig-out/bin/universe';GUEST=ROOT/'artifacts/windows-message.exe'
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
libc=ctypes.CDLL(None);libc.snprintf.restype=ctypes.c_int
# Apple ARM64 needs the fixed parameter types to marshal variadic arguments correctly.
libc.snprintf.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_char_p]
def wide(text):return text.encode('utf-16-le',errors='surrogatepass')
cases=[]
def add(template,expected,values=(),flags=0x2400,capacity=128,error=None):
    cases.append((template,expected,list(values)+[0]*(4-len(values)),flags,capacity,error))
def c_integer(spec,value,modifier,kind):
    prefix='ll' if modifier in ('I64','ll','I') else modifier if modifier in ('h','hh') else ''
    fmt=('%'+spec+prefix+kind).encode()
    arg=(ctypes.c_longlong if kind in 'di' else ctypes.c_ulonglong)(value) if prefix=='ll' else (ctypes.c_int if kind in 'di' else ctypes.c_uint)(value)
    buffer=ctypes.create_string_buffer(256)
    length=libc.snprintf(buffer,len(buffer),fmt,arg)
    assert 0<=length<len(buffer),(fmt,value,length)
    return buffer.value.decode('ascii')

assert c_integer('',17,'','d')=='17'
assert c_integer('',0x8000000000000000,'I64','d')=='-9223372036854775808'
assert c_integer('#08',0xabcdef,'','X')=='0XABCDEF'
rng=random.Random(0x554e495645525345)
edges=(0,1,255,32768,0x7fffffff,0x80000000,0xffffffff,0x8000000000000000,0xffffffffffffffff)
for number in range(1200):
    kind=rng.choice('diuoxX');modifier=rng.choice(('', 'h','hh','l','I32','I64','ll','I'))
    value=edges[number%len(edges)] if number<400 else rng.getrandbits(64)
    flags=rng.choice(('', '-', '+', ' ', '0', '#', '#0', '+0', '-0', '-+ #0'))
    width=rng.choice((0,1,2,8,23,39));precision=rng.choice((None,0,1,8,24))
    spec=flags+(str(width) if width else '')+('' if precision is None else '.'+str(precision))
    expected=c_integer(spec,value,modifier,kind)
    definition='['+'%1!'+spec+modifier+kind+'!] %2!u! %% %1!'+spec+modifier+kind+'!%0hidden'
    use_array=modifier not in ('I64','ll','I') and number%2==0
    add(definition,'['+expected+'] 17 % '+expected,(value,17),flags=0x2400 if use_array else 0x400)

for narrow in (False,True):
    for text in ('', 'Bill', 'é🚀', 'a b\t', 'line\r\nend', 'a\0hidden'):
        actual=text.split('\0',1)[0];units=wide(actual)
        for precision in (None,0,1,2,3,8):
            for left in (False,True):
                count=len(units)//2 if precision is None else min(len(units)//2,precision)
                padded=units[:count*2]
                padding=wide(' ')*max(0,6-count)
                expected=wide('[')+(padded+padding if left else padding+padded)+wide(']')
                spec=('-' if left else '')+'6'+('' if precision is None else '.'+str(precision))+('hs' if narrow else 's')
                add('[%1!'+spec+'!]',expected,(text.encode() if narrow else text,))
for text in ('\ud800x','\udc00','é🚀'):
    for precision in (0,1,2,3,8):
        add('%1!.'+str(precision)+'s!',wide(text)[:precision*2],(text,))
add('%1 %1','(null) (null)',(0,))
add('%1!S!', 'é🚀',(b'\xc3\xa9\xf0\x9f\x9a\x80',))
for value in (0,65,0xe9,0xd800,0xffff):add('%1!3c!',wide('  ')+struct.pack('<H',value),(value,))
for value in (0,65,127):add('%1!C!',struct.pack('<H',value),(value,))
for value in (0,1,0x123456789abcdef0,0xffffffffffffffff):add('%1!p!',f'{value:016X}',(value,))
add('%1!*.*s! %4','  Bi Bob',(4,2,'Bill','Bob'))
add('%1!*s!', 'Bill  ',(0xfffffffa,'Bill'))
add('%1!.*s!', 'Bill',(0xffffffff,'Bill'))

add('é🚀 %% %1!bad%0field!%nnext%r%t%.%!%?%0hidden','é🚀 % %1!bad%0field!\r\nnext\r\t.!?',flags=0x600)
add('%1!unterminated', '%1!unterminated',flags=0x600)
for width in (0,1,2,4,7,11,20,255):
    text='one two three';tail='longerword end'
    expected=text+'\r\n'+tail if width in (0,255) else '\r\n'.join(textwrap.wrap(text,width,break_long_words=False,break_on_hyphens=False)+textwrap.wrap(tail,width,break_long_words=False,break_on_hyphens=False))
    add('one two three%nlongerword end',expected,flags=0x400|width)
add('one\r\ntwo%nthree','one two\r\nthree',flags=0x4ff)
add('raw \ud800\udc00 \udfff','raw \ud800\udc00 \udfff')

for allocated in (False,True):
    for capacity in range(10):
        add('[%1]', '[é🚀]',('é🚀',),flags=0x2400|(0x100 if allocated else 0),capacity=capacity)
    add('', '',flags=0x2400|(0x100 if allocated else 0),capacity=1)
    add('%1!65535s!',wide(' ')*65534+wide('z'),('z',),flags=0x2400|(0x100 if allocated else 0),capacity=65536)
    add('a%1!65535s!',None,('z',),flags=0x2400|(0x100 if allocated else 0),capacity=64,error=234)
    add('%1!65536s!',None,('z',),flags=0x2400|(0x100 if allocated else 0),error=234)
add('abc',None,flags=0x2500,capacity=0xffffffff,error=8)
for template,values,flags,error in [('%',(),0x2400,87),('%1!s',('a',),0x2400,87),('%1!f!',(1,),0x2400,50),('%1!I64u!',(1,),0x2400,87),('%1!*s!',(3,'a'),0x400,50),('%1!hs!',(b'\xff',),0x2400,1113),('%1!C!',(255,),0x2400,1113),('abc',(),0,87),('abc',(),0x8000,87),('abc',(),0xc00,87),('abc',(),0x800,50)]:
    add(template,None,values,flags=flags,error=error)

payload=bytearray()
for template,expected,values,flags,capacity,error in cases:
    source=wide(template);numbers=[];lengths=[];strings=[]
    for value in values:
        if isinstance(value,str):data=wide(value);lengths.append(len(data)//2);strings.append(data);numbers.append(0)
        elif isinstance(value,bytes):lengths.append(0x80000000|len(value));strings.append(value);numbers.append(0)
        else:numbers.append(value&0xffffffffffffffff);lengths.append(0xffffffff)
    payload+=struct.pack('<4I4Q4I',flags,capacity,len(source)//2,0,*numbers,*lengths)+source+b''.join(strings)
for mode in MODES:
    command=[str(RUNTIME),*mode,'--max-instructions','100000000','--timeout-ms','30000',str(GUEST)]
    basic=subprocess.run(command,capture_output=True,timeout=40)
    assert basic.returncode==0 and basic.stdout==b'windows messages: diagnostics, typed inserts, escapes, line widths and local buffers ok\n' and not basic.stderr,basic
    result=subprocess.run([*command,'oracle'],input=payload,capture_output=True,timeout=40)
    assert result.returncode==0 and not result.stderr,(mode,result.returncode,result.stdout[-200:],result.stderr[-1000:])
    offset=0
    for index,(template,expected,values,flags,capacity,error) in enumerate(cases):
        count,last,units,allocation=struct.unpack_from('<4I',result.stdout,offset);offset+=16
        data=result.stdout[offset:offset+units*2];offset+=units*2
        expected=wide(expected) if isinstance(expected,str) else expected
        length=0 if expected is None else len(expected)//2
        if error is None and not flags&0x100 and capacity<=length:error=122
        assert (count,last)==(0 if error is not None else length,error if error is not None else 777),(mode,index,template,values,flags,capacity,count,last,error)
        if flags&0x100:
            if error is not None:assert units==allocation==0 and not data
            else:assert units==length+1 and allocation>=max(capacity,length+1)*2 and data==expected+b'\0\0',(index,template)
        else:
            guard=b'\xfe\xca'*(min(capacity,65536)+4)
            if error is None:guard=guard[:4]+expected+b'\0\0'+guard[4+len(expected)+2:]
            assert units==min(capacity,65536)+4 and not allocation and data==guard,(index,template,values,data.decode("utf-16-le",errors="surrogatepass"),guard.decode("utf-16-le",errors="surrogatepass"))
    assert offset==len(result.stdout),(offset,len(result.stdout))
    precision=subprocess.run([*command,'precision'],capture_output=True,timeout=40)
    assert precision.returncode==0 and not precision.stdout and not precision.stderr,precision
    for argument in ('fault','bad-arguments','bad-valist','bad-source'):
        fault=subprocess.run([*command,argument],capture_output=True,timeout=40)
        assert fault.returncode==125 and b'UnmappedMemory' in fault.stderr and not fault.stdout,fault
    print(f'Windows messages {mode or ["interpreter"]}: {len(cases)} native snprintf/Python byte cases, SDK variadic/array calls, widths, UTF-16, buffers, allocation ownership and checked faults passed',flush=True)
