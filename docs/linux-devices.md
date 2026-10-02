# Guest null and zero devices

UNIVERSE provides two absolute guest paths, `/dev/null` and `/dev/zero`, on
x86-64, AArch64 and RISC-V64 Linux. They work inside an empty `--sysroot` and
without `--allow-files`. Opening them creates a guest descriptor with no native
device file or native FD. Other paths still require the normal file grant.

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
| open/openat | Absolute null/zero leaves, lexical normalization, read/write access modes and the existing supported flags; O_DIRECTORY and trailing slashes return ENOTDIR; O_CREAT with O_EXCL returns EEXIST |
| read/pread/readv | Null returns EOF; zero fills checked writable buffers; positioned offsets must be nonnegative |
| write/pwrite/writev | Both discard the payload and return its byte count; discarded payloads need a valid guest address range, but need not be mapped |
| stat/lstat/fstat/newfstatat | Serialized guest character-device records: mode 0666, root ownership, major 1/minor 3 or 5, zero size/blocks and fixed zero timestamps |
| access/faccessat | Existence, read and write allowed; execute denied |
| dup/dup2/dup3/F_DUPFD | Share the owned open description across copies and forks; descriptor CLOEXEC remains independent |
| F_GETFL/F_SETFL | Shared access/status flags; SETFL changes APPEND and NONBLOCK; unsupported asynchronous/packet flags return ENOSYS |
| lseek | Valid whence values 0 through 4 return zero |
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
