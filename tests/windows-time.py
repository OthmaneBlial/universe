#!/usr/bin/env python3
"""Independent Gregorian/host-clock oracles for SDK-only Win32 time guests."""
import bisect, datetime, os, pathlib, platform, random, struct, subprocess, tempfile, time, zoneinfo

ROOT=pathlib.Path(__file__).resolve().parents[1]
RUNTIME=ROOT/'zig-out/bin/universe'
GUEST=ROOT/'artifacts/windows-time.exe'
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
SECOND=10_000_000
SENTINEL=0x0123456789abcdef
MONTHS=(0,31,59,90,120,151,181,212,243,273,304,334)
def leap(y): return y%4==0 and (y%100!=0 or y%400==0)
def ordinal(y,m,d):
    before=y-1
    return before*365+before//4-before//100+before//400+MONTHS[m-1]+(m>2 and leap(y))+d
BASE=ordinal(1601,1,1)
STARTS=[ordinal(y,1,1) for y in range(1,30830)]
def encode(fields):
    y,m,weekday,d,h,minute,second,ms=fields
    if not (1601<=y<=30827 and 1<=m<=12 and 0<=h<=23 and 0<=minute<=59 and 0<=second<=59 and 0<=ms<=999): return None
    length=(31,29 if leap(y) else 28,31,30,31,30,31,31,30,31,30,31)[m-1]
    if not 1<=d<=length:return None
    return ((ordinal(y,m,d)-BASE)*86400+h*3600+minute*60+second)*SECOND+ms*10000
def decode(ticks):
    seconds,remainder=divmod(ticks,SECOND);days,clock=divmod(seconds,86400);day=days+BASE
    if day<=datetime.date.max.toordinal():
        date=datetime.date.fromordinal(day);y,m,d=date.year,date.month,date.day
    else:
        y=bisect.bisect_right(STARTS,day);m=1
        while m<12 and ordinal(y,m+1,1)<=day:m+=1
        d=day-ordinal(y,m,1)+1
    h,clock=divmod(clock,3600);minute,second=divmod(clock,60)
    return y,m,day%7,d,h,minute,second,remainder//10000
def run(mode,args=(),data=None,cwd=None,grant=False,tz=None):
    env=dict(os.environ,TZ=tz) if tz is not None else None
    result=subprocess.run([str(RUNTIME),*mode,'--max-instructions','100000000','--timeout-ms','20000',*(['--allow-files'] if grant else []),str(GUEST),*args],input=data,capture_output=True,cwd=cwd,env=env,timeout=30)
    assert result.returncode==0,(mode,args,result.returncode,result.stdout[-100:],result.stderr[-500:])
    return result.stdout

rng=random.Random(1601)
systems=[]
for y in range(1601,30828):systems.append((y,1,65535,1,0,0,0,0))
for y in (1601,1700,1900,1970,1980,2000,2100,2400,9999,10000,30827):
    for m in range(1,13):
        for d in (1,28,29,30,31):systems.append((y,m,65535,d,23,59,59,999))
for _ in range(1000):systems.append((rng.randrange(1600,30830),rng.randrange(14),65535,rng.randrange(33),rng.randrange(26),rng.randrange(62),rng.randrange(62),rng.randrange(1002)))
systems.extend((2000,2,0,29,23,59,59,999+bit) for bit in (1,65535-999))
filetimes=[0,1,9999,10000,SECOND-1,116444736000000000,2**63-1,2**63,2**64-1]
filetimes.extend(encode(fields)+1234 for fields in systems if encode(fields) is not None)
filetimes.extend(rng.randrange(2**64) for _ in range(2000))
dos=[(date,(12<<11)|(34<<5)|28) for date in range(65536)]
dos.extend(((20<<9)|(2<<5)|29,clock) for clock in range(65536))
expected_system=b''.join(struct.pack('<IIQ',int((value:=encode(fields)) is not None),777 if value is not None else 87,value if value is not None else SENTINEL) for fields in systems)
expected_ticks=b''.join(struct.pack('<II8H',int(tick<2**63),777 if tick<2**63 else 87,*(decode(tick) if tick<2**63 else (0xcafe,)*8)) for tick in filetimes)
expected_dos=bytearray()
for date,clock in dos:
    fields=((date>>9)+1980,(date>>5)&15,0,date&31,clock>>11,(clock>>5)&63,(clock&31)*2,0)
    value=encode(fields)
    expected_dos+=struct.pack('<IIQHH',int(value is not None),777 if value is not None else 87,value if value is not None else SENTINEL,date if value is not None else 0xcafe,clock if value is not None else 0xcafe)
for mode in MODES:
    assert run(mode,['system'],b''.join(struct.pack('<8H',*fields) for fields in systems))==expected_system,'SYSTEMTIME range/leap validation or unchanged failure output'
    assert run(mode,['ticks'],b''.join(struct.pack('<Q',tick) for tick in filetimes))==expected_ticks,'FILETIME calendar/weekday/fraction conversion'
    assert run(mode,['dos'],b''.join(struct.pack('<HH',*words) for words in dos))==expected_dos,'Every DOS date/time word must validate or roundtrip exactly'
    for tz,offset in [(None,time.localtime().tm_gmtoff),('UTC0',0),('XST-14',14*3600),('XST12',-12*3600),('America/New_York',int(datetime.datetime.now(zoneinfo.ZoneInfo('America/New_York')).utcoffset().total_seconds()))]:
        before=time.time_ns()//100+116444736000000000
        output=run(mode,['clocks'],tz=tz)
        after=time.time_ns()//100+116444736000000000
        values=struct.unpack('<11Q',output[:88])
        assert output[88:]==b'windows time: checked calendars, local/UTC conversion and process clocks ok\n'
        assert all(before-10000<=values[index]<=after for index in (0,1,2,3,4)),values
        assert values[5]<=values[0] and values[6]==0 and values[7]+values[8]>0,values
        assert values[9]-values[4]==offset*SECOND and values[10]==116444736000000123+offset*SECOND,(tz,values)
    with tempfile.TemporaryDirectory() as tmp:
        root=pathlib.Path(tmp)
        assert run(mode,['files'],cwd=root)==b'windows file time: denied\n' and not list(root.iterdir())
        output=run(mode,['files'],cwd=root,grant=True);created,access,write=struct.unpack('<3Q',output)
        native=(root/'time é🚀.bin').stat()
        assert (root/'time é🚀.bin').read_bytes()==b'aZc\0\0!'
        assert access==encode((2000,2,0,29,23,59,59,123)) and write==encode((2002,4,0,5,23,59,59,123))
        assert native.st_atime_ns//100+116444736000000000==access and native.st_mtime_ns//100+116444736000000000==write
        if hasattr(native,'st_birthtime_ns'):assert created==native.st_birthtime_ns//100+116444736000000000==encode((1999,12,0,31,23,59,59,123))
    print(f'Windows time {mode or ["interpreter"]}: {len(systems)} SYSTEMTIME, {len(filetimes)} FILETIME, {len(dos)} DOS cases, real clocks and native file timestamps passed',flush=True)
