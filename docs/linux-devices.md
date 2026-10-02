# Guest devices and Linux proc files

UNIVERSE provides two absolute guest paths, `/dev/null` and `/dev/zero`, on
x86-64, AArch64 and RISC-V64 Linux. They work inside an empty `--sysroot` and
without `--allow-files`. Opening them creates a guest descriptor with no native
device file or native FD. Other host paths still require the normal file grant.

The exact guest path `/proc/mounts` exposes one read-only synthetic root entry
(`universe / universe rw 0 0`). The exact path `/proc/meminfo` reports the
guest memory limit and mapped-page usage; swap and cache counters are zero.
These files do not expose host mount tables or host RAM. Disk statistics still
come from the granted sysroot path.

```sh
./zig-out/bin/universe artifacts/public-apps/busybox sh -c 'echo hi & wait'
# hi
./zig-out/bin/universe artifacts/public-apps/busybox sh -c \
  'printf hidden > /dev/null; echo visible'
# visible
./zig-out/bin/universe artifacts/public-apps/busybox head -c 64 /dev/zero
# exactly 64 zero bytes
```

The optional pinned-app suite also runs these workflows with a newly created
empty sysroot. It checks that no native device entries appear there. BusyBox
opens `/dev/null` for background stdin before applying redirections; its
selected background/wait scripts now use this internal device.

## Supported profile

| Operation | Behavior |
|---|---|
| open/openat | Absolute null/zero leaves and exact `/proc/mounts` and `/proc/meminfo` files, lexical normalization and supported flags; proc files are read-only |
| read/pread/readv | Null returns EOF; zero fills checked writable buffers; proc files support shared offsets and positioned reads |
| write/pwrite/writev | Null/zero discard payloads and return their byte count; proc-file writes fail with EBADF; discarded payloads need a valid guest address range, but need not be mapped |
| stat/lstat/fstat/newfstatat | Null/zero are character devices with mode 0666 and major 1/minor 3 or 5; proc files are regular 0444 files; all use fixed zero timestamps |
| access/faccessat | Null/zero allow read/write but deny execute; proc files allow reads only |
| dup/dup2/dup3/F_DUPFD | Share the owned open description across copies and forks; descriptor CLOEXEC remains independent |
| F_GETFL/F_SETFL | Shared access/status flags; SETFL changes APPEND and NONBLOCK; unsupported asynchronous/packet flags return ENOSYS |
| lseek | Null/zero return zero for whence 0 through 4; proc files support SET/CUR/END |
| poll | Immediately ready for requested normal read/write events |
| mmap | Readable zero descriptors create independent zero-filled MAP_PRIVATE pages through the existing checked memory path; null returns ENODEV |
| getdents/ioctl/fsync/ftruncate | ENOTDIR, ENOTTY, EINVAL and EINVAL respectively |
| path mutations/timestamps | Immutable virtual leaves; with file access enabled, mutations return EROFS before any host mutation |

Counts retain the existing bounded I/O profile: at most 1 MiB per operation,
1,024 iovecs and 64 guest descriptor slots. Iovec tables themselves must be
readable even when their payload is discarded. Actual zero output uses the
same whole-buffer preflight as other guest reads. A crossing into unmapped or
read-only memory returns EFAULT before output; Linux's partial-fault zero reads
are not modeled. Zero mappings retain ordinary protection, fixed-address,
allocation-budget and fork isolation checks. Shared mappings remain outside
the current mmap profile.

`/dev` directory enumeration, relative device aliases, `/proc/self/fd`, random
devices, terminal devices and a general device filesystem remain unsupported.
Path matching uses the existing lexical path profile, not a VFS or symlink
resolver. An absolute reserved leaf overrides a same-named entry in a sysroot.
Host filesystem symlink confinement is unchanged and remains a separate limit.
Device record locks return ENOSYS.

The behavior is checked against the public
[Linux memory-device driver](https://github.com/torvalds/linux/blob/master/drivers/char/mem.c)
and [device-number registry](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/devices.txt).
The implementation is UNIVERSE's own bounded service. Native Linux differential
execution has not been performed in this session.

## Reproduce locally

```sh
zig build -Doptimize=ReleaseSafe
zig build test
python3 scripts/fixtures.py
python3 tests/integration.py
python3 tests/public-apps.py
```

`examples/devices.c` uses raw syscalls and independent musl declarations for
stat/iovec layouts. Four CPU/encoding variants pass in both engines without
file grants. Checks cover exact scalar/vector bytes and guards, access errors,
metadata, dup/fork flags, EOF/discard buffers, private zero mappings and fork
isolation. Units additionally cover allocation failures, full descriptor
tables, close-on-exec cleanup, immutable paths and poll events on every ABI.
