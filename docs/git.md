# Unchanged git on UNIVERSE

Alpine Linux's own x86-64 `git` 2.49.1 package and its 14 library packages run
unchanged on an ARM64 Mac. `scripts/alpine.py` downloads the Alpine 3.22.6
minirootfs plus the exact `.apk` files, checks each SHA-256 and extracts them into
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

## Limits

- No networking: `clone`, `fetch` and `push` over HTTPS or SSH are unavailable.
- `git` hooks, editors and pagers run only if their programs exist in the
  sysroot; pass `--no-pager` or set variables explicitly, since the guest
  environment starts empty.
- `--allow-files` grants host-user file access. UNIVERSE is not a sandbox.
