#!/usr/bin/env python3
"""Own SDK guest against real host pipes, PTYs and SIGINT/SIGQUIT."""
import os, pathlib, platform, pty, select, signal, subprocess, termios, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
COMMAND=[str(ROOT/'zig-out/bin/universe')]
GUEST=str(ROOT/'artifacts/windows-console.exe')
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
def read_until(fd,marker,timeout=3):
    data=b'';deadline=time.monotonic()+timeout
    while marker not in data:
        remaining=deadline-time.monotonic()
        assert remaining>0 and select.select([fd],[],[],remaining)[0],('missing guest handshake',marker,data)
        chunk=os.read(fd,4096);assert chunk,('guest stream closed',marker,data);data+=chunk
    return data
def finish(child,code):
    child.wait(timeout=3);assert child.returncode==code,(child.returncode,child.stderr.read())
    if child.stdin:child.stdin.close()
    output=child.stdout.read() if child.stdout else b''
    error=child.stderr.read();assert not error,error
    return output
def native_raw_restore(attributes):
    # Compare cleanup with direct host calls: Darwin may set its PENDIN rescan bit on raw->canonical.
    master,slave=pty.openpty()
    try:
        termios.tcsetattr(slave,termios.TCSANOW,attributes)
        raw=termios.tcgetattr(slave);raw[3]&=~(termios.ISIG|termios.ICANON|termios.ECHO)
        raw[6][termios.VMIN]=1;raw[6][termios.VTIME]=0
        termios.tcsetattr(slave,termios.TCSANOW,raw)
        termios.tcsetattr(slave,termios.TCSANOW,attributes)
        return termios.tcgetattr(slave)
    finally:os.close(master);os.close(slave)
for mode in MODES:
    result=subprocess.run([*COMMAND,*mode,GUEST,'pipes'],input=b'',capture_output=True,timeout=5)
    assert result.returncode==0 and result.stdout==b'windows console: stream types, UTF-8 policy and handler registration ok\n' and not result.stderr,(mode,result)
    for name in ('signal','break','ignore','ignore-read','remove','read','threshold','default'):
        child=subprocess.Popen([*COMMAND,*mode,'--max-instructions','100000000',GUEST,name],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            assert read_until(child.stdout.fileno(),b'READY\n')==b'READY\n'
            if name=='ignore-read':time.sleep(.05)
            if name in ('ignore','ignore-read'):
                os.kill(child.pid,signal.SIGINT)
                assert not select.select([child.stdout],[],[],.04)[0] and child.poll() is None,'Ignored CTRL_C must not call a handler or terminate'
            if name=='ignore-read':
                child.stdin.write(b'a');child.stdin.flush()
                assert read_until(child.stdout.fileno(),b'WAIT\n')==b'WAIT\n'
            if name=='read':time.sleep(.05) # Let the child enter its blocking read before delivering the native interrupt.
            if name=='threshold':
                for number in (1,2,3):
                    os.kill(child.pid,signal.SIGINT)
                    assert read_until(child.stdout.fileno(),str(number).encode())==str(number).encode()
                assert finish(child,58)==b''
            else:
                os.kill(child.pid,signal.SIGQUIT if name in ('break','ignore','ignore-read') else signal.SIGINT)
                output=finish(child,58 if name=='default' else 0)
                assert output==(b'' if name=='default' else b'31 ok\n' if name=='remove' else b'321 ok\n'),(name,output)
        finally:
            if child.poll() is None:child.kill();child.wait()
            for stream in (child.stdin,child.stdout,child.stderr):
                if stream and not stream.closed:stream.close()
    for tty_mode in ('tty','tty-fault'):
        master,slave=pty.openpty()
        original=termios.tcgetattr(slave)
        canonical=termios.tcgetattr(slave);canonical[3]|=termios.ISIG|termios.ICANON|termios.ECHO
        termios.tcsetattr(slave,termios.TCSANOW,canonical)
        child=subprocess.Popen([*COMMAND,*mode,GUEST,tty_mode],stdin=slave,stdout=slave,stderr=subprocess.PIPE)
        try:
            assert read_until(master,b'RAW\r\n')==b'RAW\r\n'
            native=termios.tcgetattr(slave);assert not native[3]&(termios.ISIG|termios.ICANON|termios.ECHO)
            os.write(master,b'Z')
            if tty_mode=='tty-fault':
                child.wait(timeout=3);assert child.returncode==125 and b'UnmappedMemory' in child.stderr.read()
                assert termios.tcgetattr(slave)==native_raw_restore(canonical),'Fault cleanup must match a direct native terminal restore'
                continue
            assert read_until(master,b'LINE\r\n')==b'LINE\r\n'
            native=termios.tcgetattr(slave);assert native[3]&(termios.ISIG|termios.ICANON)==termios.ISIG|termios.ICANON and not native[3]&termios.ECHO
            os.write(master,b'a');assert not select.select([master],[],[],.03)[0],'Cooked read must wait for the line terminator without echo'
            os.write(master,b'\n')
            message=b'windows console: terminal raw/cooked input and restored modes ok\r\n'
            assert read_until(master,message)==message
            child.wait(timeout=3);assert child.returncode==0 and not child.stderr.read()
            assert termios.tcgetattr(slave)==canonical,'Every saved termios field must restore after guest exit'
        finally:
            if child.poll() is None:child.kill();child.wait()
            termios.tcsetattr(slave,termios.TCSANOW,original);os.close(master);os.close(slave);child.stderr.close()
    print(f'Windows console {mode or ["interpreter"]}: pipes, native terminal flags, LIFO controls, ignored C/break, third-interrupt/default exit and interrupted reads passed',flush=True)
