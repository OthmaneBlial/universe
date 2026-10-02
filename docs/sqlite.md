# SQLite CLI milestone 🗃️

UNIVERSE executes the unmodified upstream SQLite 3.53.4 CLI as a static Linux
x86-64 guest on the verified ARM64 macOS host. This optional application build
is separate from offline core checks and release artifacts.

```sh
python3 scripts/sqlite.py
python3 tests/sqlite.py
./zig-out/bin/universe artifacts/sqlite-x86_64 -batch :memory: 'select 6 * 7;'
# 42
./zig-out/bin/universe --allow-files artifacts/sqlite-x86_64 -batch demo.db \
  "create table if not exists stars(name text); insert into stars values('Sirius'); select * from stars;"
```

The source is [SQLite's official amalgamation](https://www.sqlite.org/download.html),
verified against its published SHA3-256 digest:
`628a44cfe82c66aed1ccbbe85a562d2e33ebe64b3288981ed76285612227934e`.
Requires Python 3, Zig 0.16.0 and network access for the first download.
[SQLite is public domain](https://www.sqlite.org/copyright.html); its source and
guest binary remain under ignored `artifacts/` and are not bundled in releases.

The build uses musl, `-static -O1`, disables compiler auto-vectorization, and
sets `SQLITE_THREADSAFE=0` and `SQLITE_OMIT_LOAD_EXTENSION`. Upstream SQL and
storage code is unchanged. These flags match the runtime's single-thread
execution and lack of guest extension loading.

The separate application regression checks interpreter and ARM64 JIT paths:

- In-memory version, recursive CTE aggregation and JSON queries.
- Persistent tables, index creation, joins, foreign keys, Unicode text, real
  numbers and blobs, with explicit transactions and rollback.
- Delete and truncate journal modes with full synchronization, reopen by
  absolute/relative paths, bulk insert/delete, VACUUM and integrity checks.
- Read-only CLI reopen and independent reads of the database through Python's
  native SQLite, including exact rows and an integrity check.
- A native exclusive transaction rejects a guest read with `database is locked`;
  the guest can read after the native lock is released.
- File access remains denied without `--allow-files` and creates no database.

General Linux services now translate checked `readv`, `pread64`/`pwrite64`,
`fsync`/`fdatasync`, `ftruncate`, `getcwd`, symlink reads and nonblocking advisory
record locks. Native sync/locking calls report their real failures. Additional
libc-free storage fixtures verify all three Linux guest CPUs, EOF/offset
behavior, invalid buffers, descriptor-relative paths and external lock conflicts.

This is a tested batch CLI subset. Standard guest signals have a
[checked delivery profile](linux-processes.md#guest-signals-and-interrupted-waits),
but SQLite interruption and host Ctrl-C forwarding remain unverified. Guest
threads, loaded extensions, WAL/shared-memory coordination, interrupted-commit
recovery and power-loss durability have not been validated. This milestone does
not establish complete SQLite, musl or Linux application compatibility.
