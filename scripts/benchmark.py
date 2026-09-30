#!/usr/bin/env python3
"""Measure cold process runs of identical integer work; no speed claims without data."""
import datetime, json, pathlib, platform, re, statistics, subprocess, time
ROOT=pathlib.Path(__file__).resolve().parents[1]
subprocess.run(['zig','cc','-O1',str(ROOT/'benchmarks/native.c'),'-o',str(ROOT/'artifacts/native-benchmark')],check=True)
native=ROOT/'artifacts/native-benchmark';expected=subprocess.check_output([native])
def measure(command,expected_output=expected,repeats=7):
    timings=[];stats={};samples=[]
    for _ in range(repeats+1):
        begin=time.perf_counter_ns();p=subprocess.run(command,capture_output=True,timeout=30);elapsed=time.perf_counter_ns()-begin
        assert p.returncode==0 and p.stdout==expected_output,(command,p.returncode,p.stdout,p.stderr)
        stats={k:int(v) for k,v in re.findall(rb'(\w+)=(\d+)',p.stderr)}
        timings.append(elapsed/1e6);samples.append(stats)
    return {'median_wall_ms':statistics.median(timings[1:]),'min_wall_ms':min(timings[1:]),'stats':{k.decode():statistics.median([s[k] for s in samples[1:]]) for k in stats}}
results={'date':datetime.datetime.now().astimezone().isoformat(),'platform':platform.platform(),'machine':platform.machine(),'zig':subprocess.check_output(['zig','version'],text=True).strip(),'iterations':100000,'expected_stdout':expected.decode().strip(),'repetitions':7,'results':{}}
if platform.system()=='Darwin':results['cpu']=subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip()
results['results']['native host']=measure([str(native)])
results['hello_process_wall_ms']={}
for arch in ['x86_64','riscv64','aarch64']:
    hello=ROOT/'artifacts/guests'/arch/'hello'
    results['hello_process_wall_ms'][arch]=measure([str(ROOT/'zig-out/bin/universe'),str(hello)],b'Hello from foreign Linux machine code!\n')['median_wall_ms']
    path=ROOT/'artifacts/guests'/arch/'benchmark'
    for mode in (['interpreter','jit'] if platform.machine() in ['aarch64','arm64'] else ['interpreter']):
        command=[str(ROOT/'zig-out/bin/universe'),'--stats']
        if mode=='jit':command+=['--jit']
        command.append(str(path));results['results'][arch+' '+mode]=measure(command)
(ROOT/'artifacts/benchmark.json').write_text(json.dumps(results,indent=2)+'\n')
lines=['# Local benchmark evidence','',f"Measured {results['date']} on {results.get('cpu',results['machine'])}, {results['platform']}; Zig {results['zig']}, runtime ReleaseSafe, guest/native C `-O1`.",'','100,000 iterations of the same 64-bit xorshift-and-sum C workload. All outputs equal `'+results['expected_stdout']+'`. Each measurement starts a new process. One warm-up run is discarded; the median uses seven runs. Runtime statistics also use seven-run medians. Wall time includes startup, guest loading, JIT compilation, execution and shutdown. Guest machine code differs between architectures.','', '| Execution | Median wall ms | Instructions | JIT compile ms | Cached block hits |','|---|---:|---:|---:|---:|']
for name,data in results['results'].items():
    s=data['stats'];lines.append(f"| {name} | {data['median_wall_ms']:.3f} | {s.get('instructions','—')} | {s.get('jit_compile_ns',0)/1e6:.3f} | {s.get('jit_cache_hits','—')} |")
lines+=['', '| Runtime | Execution ms | Guest instructions/s | Guest mapped KiB | JIT cache KiB |', '|---|---:|---:|---:|---:|']
for name,data in results['results'].items():
    s=data['stats']
    if not s:continue
    elapsed=s['elapsed_ns']/1e9
    lines.append(f"| {name} | {elapsed*1000:.3f} | {s['instructions']/elapsed:.0f} | {s['guest_memory_bytes']/1024:.0f} | {s.get('jit_code_bytes',0)/1024:.0f} |")
lines+=['', 'Hello World cold process medians (startup + loading + trivial execution + shutdown): '+', '.join(f"{arch} {ms:.3f} ms" for arch,ms in results['hello_process_wall_ms'].items())+'. This is an end-to-end startup baseline, not an isolated loader timer.']
lines+=['','Native runs the same C algorithm compiled for the actual host OS/CPU and uses host libc for output. It is an algorithm baseline, not native execution of the foreign ELF on this Mac. The JIT translates only register blocks and interprets unsupported operations. These numbers describe this microbenchmark only; they are not a claim about arbitrary application performance.','', 'Runtime `elapsed_ns` starts after ELF/PE loading and stack setup. JIT `compile_ns` includes decoding/emission/cache setup, not just machine-code generation. `guest_memory_bytes` is mapped guest backing storage, not host RSS. JIT code cache size is allocated host pages. No peak-RSS or whole-ISA throughput claim is made.','', 'Reproduce: `./scripts/check.sh && python3 scripts/benchmark.py`. Raw JSON is written to ignored `artifacts/benchmark.json`.']
(ROOT/'benchmarks/results.md').write_text('\n'.join(lines)+'\n');print('\n'.join(lines))
