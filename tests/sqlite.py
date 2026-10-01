#!/usr/bin/env python3
"""Optional real SQLite CLI checks; run scripts/sqlite.py first."""
import pathlib
import platform
import sqlite3
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / 'zig-out/bin/universe'
GUEST = ROOT / 'artifacts/sqlite-x86_64'
modes = [[]] + ([['--jit']] if platform.machine() in ['arm64', 'aarch64'] else [])

def run(mode, args, output=None, code=0, cwd=None, allow=True):
    command = [str(RUNTIME), *mode, *(['--allow-files'] if allow else []), str(GUEST), '-batch', *map(str, args)]
    result = subprocess.run(command, cwd=cwd, capture_output=True, timeout=20)
    assert result.returncode == code, (command, result.returncode, result.stdout, result.stderr)
    if output is not None:
        assert result.stdout == output, (command, result.stdout, result.stderr)
    return result

for mode in modes:
    run(mode, [':memory:', "select sqlite_version(); with recursive n(x) as (values(1) union all select x+1 from n where x<1000) select sum(x) from n; select json_extract('{\"answer\":42}', '$.answer');"], b'3.53.4\n500500\n42\n', allow=False)
    with tempfile.TemporaryDirectory(prefix='universe-sqlite-') as tmp:
        root = pathlib.Path(tmp)
        init = root / 'init.sql'
        init.write_text('')
        path = root / 'database.db'
        denied = run(mode, [path, 'create table denied(id);'], code=1, allow=False)
        assert b'unable to open database file' in denied.stderr and not path.exists()
        run(mode, ['-init', init, path, """
            pragma journal_mode=delete; pragma synchronous=full; pragma foreign_keys=on;
            create table teams(id integer primary key, name text);
            create table members(id integer primary key, team integer references teams(id), name text, score real, note blob);
            create index members_team on members(team);
            begin;
            insert into teams values(1,'orbit'),(2,'launch');
            insert into members values(1,1,'Zoë',12.5,x'00ff'),(2,1,'Lin',7.5,x'1234'),(3,2,'Ada',20.0,x'cafe');
            commit;
            select t.name,count(*),printf('%.1f',sum(m.score)) from teams t join members m on t.id=m.team group by t.name order by t.name;
            begin; update members set score=99; rollback;
            select group_concat(name,',') from (select name from members order by id);
            select hex(note) from members where id=1;
            pragma integrity_check;
        """], 'delete\nlaunch|1|20.0\norbit|2|20.0\nZoë,Lin,Ada\n00FF\nok\n'.encode())
        assert path.read_bytes().startswith(b'SQLite format 3\x00')
        assert not path.with_name(path.name + '-journal').exists()
        # Reopen by a relative path, use truncate journals, and compact with VACUUM.
        run(mode, ['-init', init, path.name, "pragma journal_mode=truncate; begin; with recursive n(x) as (values(4) union all select x+1 from n where x<100) insert into members select x,1,'bulk',1.0,x'ab' from n; commit; select count(*),sum(score) from members; delete from members where id>3; vacuum; pragma integrity_check;"], b'truncate\n100|137.0\nok\n', cwd=tmp)
        run(mode, ['-init', init, '-readonly', path, 'select count(*),sum(score) from members; pragma integrity_check;'], b'3|40.0\nok\n')
        native = sqlite3.connect(path)
        try:
            assert native.execute('select id,name,score,hex(note) from members order by id').fetchall() == [(1,'Zoë',12.5,'00FF'), (2,'Lin',7.5,'1234'), (3,'Ada',20.0,'CAFE')]
            assert native.execute('pragma integrity_check').fetchone() == ('ok',)
            native.execute('begin exclusive')
            locked = run(mode, ['-init', init, path, 'select count(*) from members;'], code=1)
            assert b'database is locked' in locked.stderr, locked.stderr
            native.rollback()
        finally:
            native.close()
        run(mode, ['-init', init, path, 'select count(*) from members;'], b'3\n')

print('SQLite 3.53.4: queries, persistence, rollback, VACUUM, native reopen and lock contention passed (interpreter/JIT on ARM64 hosts)')
