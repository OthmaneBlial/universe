#!/usr/bin/env python3
"""SDK-only guest against Python's independent UTF-8/UTF-16 codecs."""
import pathlib, platform, random, struct, subprocess

ROOT=pathlib.Path(__file__).resolve().parents[1]
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
cases=[]
def add(wide,data,count=None,capacity=None,page=65001,flags=0,options=0):
    count=len(data)//(2 if wide else 1) if count is None else count
    codec='utf-16-le' if wide else 'utf-8'
    output_codec='utf-8' if wide else 'utf-16-le'
    used=data
    if count==-1:
        end=next(n for n in range(0,len(data),2 if wide else 1) if data[n:n+(2 if wide else 1)]==b'\0'*(2 if wide else 1))
        used=data[:end+(2 if wide else 1)]
    elif count>0:used=data[:count*(2 if wide else 1)]
    error=777;encoded=b''
    if page not in (0,1,3,65001) or options&1 or options&4 or count==0 or count<-1 or (capacity is not None and capacity<0) or (wide and page==65001 and options&24):error=87
    elif flags not in (0,128 if wide else 8):error=1004
    else:
        try:encoded=used.decode(codec,'strict' if flags else 'replace').encode(output_codec)
        except UnicodeError:error=1113
    unit=1 if wide else 2
    required=len(encoded)//unit
    capacity=required if capacity is None else capacity
    if options&2 and capacity>0 and error==777:error=122
    size=max(capacity,0)*unit
    assert size<8388600
    initial=(b'\xaa'*size if size<=512 else b'\0'*size)+b'\xaa'*8
    result=0;written=b''
    if error==777:
        result=required
        if capacity:
            written=encoded[:size]
            while written:
                try:written.decode(output_codec);break
                except UnicodeDecodeError as fault:
                    assert fault.end==len(written)
                    written=written[:fault.start]
            if capacity<required:result=0;error=122
    default_used=0 if wide and options&16 and error==777 else 0xaaaaaaaa
    expected=struct.pack('<iIII',result,error,size+8,default_used)+written+initial[len(written):]
    cases.append((struct.pack('<IIIiiII',wide,page,flags,count,capacity,len(data),options)+data,expected))

# Every valid Unicode scalar, including NUL, supplementary planes and noncharacters.
text=''.join(chr(value) for value in range(0x110000) if not 0xd800<=value<=0xdfff)
for wide in (False,True):
    data=text.encode('utf-16-le' if wide else 'utf-8')
    add(wide,data,flags=128 if wide else 8)
    add(wide,data,capacity=0,flags=128 if wide else 8)

rng=random.Random(65001)
utf8=[bytes([value]) for value in range(256)]
utf8 += [bytes([lead,trail]) for lead in (0xc0,0xc1,0xc2,0xdf,0xe0,0xed,0xf0,0xf4,0xf5,0xff) for trail in range(256)]
utf8 += [b'\xe1\x80',b'\xe0\xa0',b'\xf1\x80\x80',b'\xf4\x8f\xbf',b'\xed\xa0\x80',b'\xf4\x90\x80\x80',b'\xe2(\xa1',b'\xe2\x82A']
utf8 += [rng.randbytes(rng.randrange(1,17)) for _ in range(256)]
utf16=[struct.pack('<H',value) for value in range(0xd800,0xe000)]
utf16 += [struct.pack('<2H',a,b) for a in (0xd7ff,0xd800,0xdbff,0xdc00,0xdfff,0xe000) for b in (0,0xd7ff,0xd800,0xdbff,0xdc00,0xdfff,0xe000)]
utf16 += [rng.randbytes(2*rng.randrange(1,9)) for _ in range(256)]
for wide,inputs in ((False,utf8),(True,utf16)):
    for data in inputs:
        add(wide,data,capacity=32)
        add(wide,data,capacity=32,flags=128 if wide else 8)
        add(wide,data,capacity=0)
    data='Aé🚀\0tail'.encode('utf-16-le' if wide else 'utf-8')
    for page in (0,1,3,65001):
        for count in (-1,len(data)//(2 if wide else 1)):
            for capacity in range(16):add(wide,data,count,capacity,page,128 if wide else 8)
    for count in (0,-2,-2147483648):add(wide,data,count,16)
    add(wide,data,capacity=-1)
    add(wide,data,capacity=16,page=1252)
    add(wide,data,capacity=16,flags=1)
    for options in (1,2,4):add(wide,data,capacity=16,options=options)
    add(wide,data,capacity=0,options=2)
    if wide:
        for options in (8,16,24):add(wide,data,capacity=16,options=options)
        for page in (0,1,3):
            for options in (8,16,24):
                for value in ('Aé🚀\0tail','e\u0301\U0010ffff','\ud800Z\udfff'):
                    raw=value.encode('utf-16-le','surrogatepass')
                    for flags in (0,128):
                        for capacity in range(13):add(True,raw,capacity=capacity,page=page,flags=flags,options=options)
                for count in (0,-1,-2):add(True,data,count,16,page,0,options)

for mode in MODES:
    # Keep bulk cases separate: initial virtual buffers are zero for independent guard checks.
    for batch in (cases[:1],cases[1:2],cases[2:3],cases[3:4],cases[4:]):
        result=subprocess.run([str(ROOT/'zig-out/bin/universe'),*mode,'--max-instructions','100000000','--timeout-ms','30000',str(ROOT/'artifacts/windows-encoding.exe')],input=b''.join(item[0] for item in batch),capture_output=True,timeout=40)
        assert result.returncode==0 and not result.stderr,(mode,result.returncode,result.stderr[-1000:])
        offset=0
        for index,(_,expected) in enumerate(batch):
            actual=result.stdout[offset:offset+len(expected)]
            assert actual==expected,(mode,index,actual[:32].hex(),expected[:32].hex())
            offset+=len(expected)
        assert offset==len(result.stdout)
    print(f'Windows encoding {mode or ["interpreter"]}: 1,112,064 Unicode scalars in both directions and {len(cases)-4} malformed, sizing, flags, code-page and guard cases passed',flush=True)
