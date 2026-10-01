#!/usr/bin/env python3
"""SDK disk queries compared with independent native filesystem statistics."""
import os,pathlib,platform,struct,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
COMMAND=[str(ROOT/'zig-out/bin/universe')]
GUEST=str(ROOT/'artifacts/windows-fileops.exe')
MODES=[[]]+([['--jit']] if platform.machine() in ('arm64','aarch64') else [])
for engine in MODES:
    for namespace in ('relative','absolute','drive-relative','drive-absolute'):
        rooted=namespace.endswith('absolute')
        with tempfile.TemporaryDirectory(prefix='universe-disk-') as directory:
            root=pathlib.Path(directory);target=root/'ops é🚀';target.mkdir()
            (target/'source.bin').write_bytes(b'not a directory')
            (root/'moved é🚀').symlink_to(target,target_is_directory=True)
            options=['--sysroot',directory] if rooted else []
            argument='disk-'+namespace if namespace!='relative' else 'disk'
            result=subprocess.run([*COMMAND,*engine,*options,GUEST,argument],cwd=directory,capture_output=True,timeout=5)
            assert result.returncode==0 and result.stdout==b'windows disk: denied\n' and not result.stderr,result
            paths=[root,target,root/'moved é🚀'];before=[os.statvfs(path) for path in paths]
            result=subprocess.run([*COMMAND,*engine,'--allow-files',*options,GUEST,argument],cwd=directory,capture_output=True,timeout=5)
            after=[os.statvfs(path) for path in paths]
            assert result.returncode==0 and len(result.stdout)==120 and not result.stderr,result
            for index,(prior,later) in enumerate(zip(before,after)):
                available,total,free,sectors,sector_bytes,free_clusters,clusters=struct.unpack_from('<3Q4I',result.stdout,index*40)
                assert prior.f_frsize==later.f_frsize and prior.f_blocks==later.f_blocks
                assert total==prior.f_frsize*prior.f_blocks and total>(1<<32),'Disk totals must retain their high DWORD'
                assert sector_bytes==512 and sectors*sector_bytes==prior.f_frsize,'Use allocation units rather than transfer sizes'
                assert clusters==min(prior.f_blocks,0xffffffff)
                # Availability is volatile; bracket native snapshots with 1 MiB for concurrent host I/O.
                for actual,field,unit in ((available,'f_bavail',prior.f_frsize),(free,'f_bfree',prior.f_frsize),(free_clusters,'f_bavail',1)):
                    low=min(getattr(prior,field),getattr(later,field));high=max(getattr(prior,field),getattr(later,field))
                    margin=(1024*1024+prior.f_frsize-1)//prior.f_frsize
                    if unit==1:low=min(low,0xffffffff);high=min(high,0xffffffff)
                    assert max(0,low-margin)*unit<=actual<=(high+margin)*unit,(engine,rooted,index,field,actual,prior,later)
                assert 0<=available<=free<=total and 0<=free_clusters<=clusters
            fault=subprocess.run([*COMMAND,*engine,'--allow-files',GUEST,'disk-fault'],cwd=directory,capture_output=True,timeout=5)
            assert fault.returncode==125 and b'UnmappedMemory' in fault.stderr and not fault.stdout,fault
    print(f'Windows disk {engine or ["interpreter"]}: native 64-bit totals, allocation geometry, bounded volatile free space, Unicode/symlinks/sysroot, optional outputs and denied/fault paths passed',flush=True)
