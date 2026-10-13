# Unchanged git, vim, Lua and htop on UNIVERSE

Alpine Linux's own x86-64 packages run unchanged on an ARM64 Mac: `git` 2.49.1,
`vim` 9.1, `lua5.4` 5.4.7 and `htop` 3.4.1, with their library packages.
`scripts/alpine.py` downloads the Alpine 3.22.6 minirootfs plus the exact `.apk`
files, checks each SHA-256 and extracts them into
`artifacts/alpine-x86_64/sysroot`. Nothing is rebuilt.

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/alpine.py
mkdir -p artifacts/alpine-x86_64/sysroot/tmp/demo
./zig-out/bin/universe --unlimited --allow-files \
  --env GIT_AUTHOR_NAME=Ada --env GIT_AUTHOR_EMAIL=ada@example.com \
  --env GIT_COMMITTER_NAME=Ada --env GIT_COMMITTER_EMAIL=ada@example.com \
  --sysroot artifacts/alpine-x86_64/sysroot /usr/bin/git -C /tmp/demo init -b main
# Initialized empty Git repository in /tmp/demo/.git/
```

With `--sysroot`, an absolute binary path that exists inside the sysroot names
the guest file, and a host working directory outside the sysroot starts the guest
at its `/`, as `chroot(1)` does.

## Verified

`python3 tests/git.py` passes **32/32 checks** (16 per engine): `--version`,
`init`, `status`, `add`, `commit`, `rev-parse`, `cat-file`, `diff --stat`,
`commit -a`, `log`, `branch`, `switch` (checking the real working-tree bytes)
and an invalid-object exit status. Every blob, tree and commit ID equals an
independent SHA-1 computation of git's object encoding in the test itself; the
first commit also matches Apple's native git on the same inputs.

git drove these runtime additions:

- `chmod`, `fchmod`, `fchmodat` and `fchmodat2`; no-follow mode changes return
  `EOPNOTSUPP`, as on Linux.
- `symlink`/`symlinkat` store the target verbatim; `link`/`linkat` support
  `AT_SYMLINK_FOLLOW`.
- `chdir`/`fchdir` with a per-process working directory, restored on every
  guest process switch because guest processes share one host process.
- `/dev/random` and `/dev/urandom`, read from the host entropy source.
- `setsid` for git's background auto-maintenance; sessions and process groups
  are not modelled.
- File ownership: the guest's virtual user and group 1000 stand for the host
  user running UNIVERSE, so `stat` reports the host user's files as owned by
  1000 and git's ownership check accepts the repository.

## vim, Lua and htop

`python3 tests/terminal-apps.py` passes **12/12 checks** (six per engine):
Lua scripts with patterns, coroutines, integer/float arithmetic, UTF-8 and file
I/O; a Lua error exit; `htop --version`; full-screen htop, which draws its CPU,
memory, load and uptime meters plus its own process row and quits on `q`; a vim
ex-mode substitution written to disk; and full-screen vim on a real
pseudo-terminal, which draws, inserts a line, writes with `:wq` and exits 0.

```sh
./zig-out/bin/universe --unlimited --allow-files --env TERM=xterm-256color \
  --sysroot artifacts/alpine-x86_64/sysroot /usr/bin/vim -u NONE /tmp/notes.txt
```

vim needed `getrlimit` and `setfsuid`/`setfsgid` (which report the fixed guest
identity). POSIX timers are not implemented: `timer_create` returns `ENOSYS`,
and the vim workflows above still pass.

htop reads only UNIVERSE's guest-owned `/proc`, never the host's: `/proc/stat`
describes one virtual CPU that is always running guest code, `/proc/uptime`
and `/proc/loadavg` come from guest uptime and the guest process table (load
averages read 0.00), `/proc/<pid>/statm` reports guest memory pages, and
`/proc/<pid>/task` lists only the main thread. `capget` reports an empty
capability set and `capset` returns `EPERM`. Per-process CPU time is not yet
accounted, so htop shows 0.0% and 0:00.00 per process.

## Limits

- No networking: `clone`, `fetch` and `push` over HTTPS or SSH are unavailable.
- `git` hooks, editors and pagers run only if their programs exist in the
  sysroot; pass `--no-pager` or set variables explicitly, since the guest
  environment starts empty.
- `--allow-files` grants host-user file access. UNIVERSE is not a sandbox.
