# Downloaded Linux and Windows apps on an ARM64 Mac

UNIVERSE executes unchanged official Linux x86-64 binaries of
[jq 1.8.2](https://github.com/jqlang/jq/releases/tag/jq-1.8.2),
[ripgrep 15.2.0](https://github.com/BurntSushi/ripgrep/releases/tag/15.2.0),
[7-Zip 26.03](https://github.com/ip7z/7zip/releases/tag/26.03) (`7zzs`),
[fd 10.5.0](https://github.com/sharkdp/fd/releases/tag/v10.5.0) and the official
[BusyBox 1.35.0 x86-64 musl binary](https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/).
The download script verifies pinned SHA-256 values and extracted executable
bytes. jq/ripgrep/7-Zip/fd archive pins come from upstream release metadata.
BusyBox's pin records the bytes downloaded from its official TLS URL; it is
not a separately published upstream checksum. BusyBox 1.35.0 is an older
binary, rather than the latest BusyBox release. It does not compile,
patch or replace the guest programs with macOS versions.

Build current `main`; the older v0.1.0 bundle predates this compatibility work:

```sh
zig build -Doptimize=ReleaseSafe
python3 scripts/public-apps.py
python3 tests/public-apps.py

printf '{"items":[{"price":2.5},{"price":4.75},{"price":6.25}]}\n' |
  ./zig-out/bin/universe artifacts/public-apps/jq -c \
  '[.items[] | select(.price > 3) | .price] | add'
# 11

printf 'alpha\nbeta\ngamma\n' |
  ./zig-out/bin/universe --allow-files artifacts/public-apps/rg \
  --threads 1 --color never -n '^(alpha|gamma)'
# 1:alpha
# 3:gamma

./zig-out/bin/universe --allow-files artifacts/public-apps/7zzs \
  a -tzip -mmt=off -mx=1 artifacts/universe-docs.zip README.md
./zig-out/bin/universe --allow-files artifacts/public-apps/7zzs \
  t -mmt=off artifacts/universe-docs.zip
./zig-out/bin/universe --allow-files artifacts/public-apps/7zzs \
  x -mmt=off -oartifacts/universe-docs artifacts/universe-docs.zip
# Everything is Ok; the extracted README matches the original bytes.

./zig-out/bin/universe --allow-files --max-instructions 30000000 --timeout-ms 30000 \
  artifacts/public-apps/fd --threads 2 --color never --type f --extension c . examples
# Real C source paths from this checkout, checked against Python's file inventory.

./zig-out/bin/universe artifacts/public-apps/busybox printf '%s:%04d\n' hello 42
# hello:0042

./zig-out/bin/universe artifacts/public-apps/busybox sh -c \
  'n=0; for x in 2 3 5; do n=$((n+x)); done; printf "%d\n" "$n"'
# 10
```

Validated on 2026-10-02: **260/260 workflows pass**, 130 in each engine:

| App | Checks per engine | Evidence |
|---|---:|---|
| jq | 7 | Exact JSON output/status: filtering, decimal addition, Unicode/sorting, false predicates, malformed JSON, file input and denied access |
| ripgrep | 9 | Version, regex searches/counts, missing matches, invalid regexes, real file input, denied access and two-thread directory search/file listing |
| 7-Zip | 19 | Format listing, SHA-256, ZIP/7z create/list/test/extract, threaded 7z round trips, independent ZIP decoding in both directions, recursive ZIP folders, corrupt/missing inputs and denied read/write access |
| fd | 19 | Version/help, exact NUL-delimited file/directory/symlink inventories, hidden/ignore rules, extension/glob/depth/exclusion filters, Unicode fixed-string search, physical absolute paths, two-thread traversal, has-results exits, invalid patterns/options and denied directory searches |
| BusyBox | 76 | 30 utility/file cases, 11 virtual-identity cases and 35 noninteractive shell cases: exact output/status, controlled passwd/group names, Unicode arguments, loops/functions/conditions/arithmetic, stdin, allowed/denied redirection, subshells, command substitution, external pipelines and exec'd BusyBox/jq/ripgrep |

7-Zip checks binary/text/empty members, nested paths and preserved file
modification timestamps. Python's standard ZIP reader independently validates
produced CRCs and member bytes; the guest also extracts a ZIP made by Python.
7z extraction is compared directly with the original input bytes. Its console
output includes variable metadata, so checks assert exit statuses and expected
messages alongside exact hashes, files and timestamps. No claim is made that
all the formats/codecs printed by `7zzs i` work.

ARM64 hosts run each case in interpreter and JIT modes. The network is used
only by the explicit download script; `./scripts/check.sh` stays local and
network-free. Downloaded executables remain under ignored `artifacts/` and are
not included in UNIVERSE release archives. Runtime execution uses UNIVERSE's
own CPU and ABI implementation, without QEMU, Wine, Rosetta or hosted services.

These are command-line workflows on Apple M2/macOS 26.6 ARM64. ripgrep needs
`--allow-files` for its working-directory query, including stdin searches.
The stdin examples select `--threads 1`. Two-thread searches and file listings
also pass over eight nested directories, with every output line and path checked
independently of worker ordering. These invoke real guest clone/futex/sleep code.
The printed PCRE2/JIT availability comes from its upstream build;
this suite does not establish PCRE2 JIT or general ripgrep compatibility.
fd's paths and types are checked against independently constructed directory
fixtures, preserving Unicode bytes and NUL separators. Absolute paths match
the physical working directory, including macOS's `/var` to `/private/var`
alias. One/two-thread searches pass; subprocess execution (`--exec`), arbitrary
thread counts and general fd compatibility remain unverified.
7-Zip's checks use `-mmt=off` plus a Linux `-mmt=2` 7z creation/extraction round
trip with exact bytes and timestamps. [Linux guest threads](linux-threads.md)
run serially with separate CPU/TLS state and checked futex queues; this does
not establish arbitrary thread counts or archive compatibility.
Larger workloads remain subject to instruction/time/memory limits.
Encrypted archives and other codecs are not covered by these checks.
The regression runner bounds each guest to 30 million instructions, with a
60-second execution deadline for 7-Zip and 30 seconds for jq/ripgrep/fd/BusyBox. Its data,
output and exit-status assertions apply in both engines; runtime CLI limits
are separately configurable.

## Unchanged BusyBox utilities

The official multi-call executable is **1,131,168 bytes**, pinned to SHA-256
`6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348`.
No applets or compiler options were altered. The 30 utility cases per engine include
binary file contents, Unicode filenames and real temporary-directory changes;
Python compares every copied byte and checks removed/denied destinations.
Base64 output and SHA-256 values come from independent standard-library oracles.

Startup uses Linux `dup2`, `setgid` and `setuid`. Descriptor duplication shares
file offsets with independent close-on-exec flags; guest credentials remain the
fixed unprivileged ID 1000 without changing the host's identity. Accelerated
`sendfile` returns ENOSYS. BusyBox's own fallback then executes read/write
machine code; both engine traces and byte comparisons verify this path.
All file access and mutation still requires `--allow-files`.

The additional 11 identity cases verify numeric UID/GID 1000 with file access
allowed or denied, an empty supplementary-group list, and names from a controlled
sysroot's `etc/passwd` and `etc/group`. No host credentials are queried. Linux
`getgroups` returns zero without accessing the output buffer for nonnegative
sizes; a negative signed 32-bit size returns EINVAL. `getppid` returns zero for
the initial guest process, whose PID is 1; fork children have their own PIDs and
guest threads retain separate TIDs.

The 35 shell cases run unchanged `sh -c` guest code: echo/printf, arithmetic,
Unicode and spaced positional arguments, for loops, functions, if/test, case,
exit status 37, stdin reads, PID/parent expansion and file redirection. The
runner compares stdout and statuses exactly, checks redirected file bytes and
proves denied writes create no destination. These are selected noninteractive
built-in scripts. Ten cases cover command substitution, Unicode and trailing
newline handling, child exit status, isolated subshell variables, repeated fork/
wait cycles and built-in pipeline status. A 420-line producer sends 4,620 bytes
through the 4 KiB pipe queue; the built-in reader checks the exact line count.
Twelve further cases per engine run external guest binaries: direct exec with
Unicode/spaced argv, exported environment and exit 1; external command substitution;
cat pipelines and PATH lookup; sort/wc in a three-stage pipeline; redirected file
bytes; grep file input; jq JSON file input; and a piped ripgrep search. An exec'd
cat returns all 4,620 producer bytes exactly. The controlled sysroot uses copies
of the same checksum-verified executables, executable modes and relative BusyBox
applet symlinks; the runtime executes their machine code without native launching.

```sh
./zig-out/bin/universe --allow-files artifacts/public-apps/busybox sh -c \
  'printf '\''{"answer":42}\n'\'' | ./artifacts/public-apps/jq .answer'
# 42
```

Background jobs, signal delivery and terminal/job-control semantics remain
unsupported. See [linux-processes.md](linux-processes.md).

The help/list output describes the binary's compiled applets, not tested
compatibility for all of them. Broader process APIs, networking and general
BusyBox compatibility remain unsupported or unverified. The separate
[BusyBox 1.37.0 source-built subset](busybox.md) remains an optional fixture.

## Windows 7-Zip on the same Mac

The unchanged official Windows x64 `7za.exe` from 26.03 now completes
**34/34 application workflows**, 17 per engine: format listing, SHA-256, ZIP/7z
creation/listing/testing/extraction, Unicode/binary/empty members and exact
modification timestamps. Python independently reads the produced ZIP and the
guest extracts a ZIP made by Python. Recursive folders, corrupt input and a
missing-file warning and denied read/write exits are checked too. These are scoped console workflows;
GUI apps and broad Windows compatibility remain unverified.

```sh
# The optional Windows download also verifies the existing Linux release pins.
python3 scripts/public-apps.py --windows
./zig-out/bin/universe --allow-files artifacts/public-apps/7za.exe \
  a -tzip -mmt=off -mx=1 artifacts/windows-docs.zip README.md
./zig-out/bin/universe --allow-files artifacts/public-apps/7za.exe \
  t -mmt=off artifacts/windows-docs.zip
python3 tests/public-apps.py --windows
```

The Windows probe **exits 0: all 34 workflows pass**. Both engines deny the
requested filesystem operations and leave the destination absent. Our checked
C++ unwinder executes the application's cleanup and catch machine code, which
produces its own access-denied diagnostic and application exit 2. The original
exit-status expectations are preserved. See the
[C++ exception profile](windows.md#c-exception-execution) for its current bounds.
The local core CI and optional downloaded-app probe are separate checks.

The download verifies upstream archive SHA-256
`191894e6acb3647ffb69ce630479ff318523b2e2b9890aa7f05c1127c2e59b8f`
and executable SHA-256
`edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
The download script runs the verified Linux `7zzs` through UNIVERSE's interpreter
to read the Windows release container. It captures only `x64/7za.exe`, verifies
the executable hash and then saves the bytes. Fresh extraction matches all
**1,335,296 original executable bytes**. A separate JIT extraction produces
the same bytes. No system tar/7z extractor or external compatibility engine is
used. Build current main before the first Windows extraction. It has a separate
1.5-billion-instruction, 300-second execution limit and can take several minutes;
later downloads verify the cached executable. The smaller application regression
cases retain their 30-million-instruction limits.

To repeat the large-container check independently:

```sh
./zig-out/bin/universe --allow-files --max-instructions 1500000000 \
  --timeout-ms 300000 artifacts/public-apps/7zzs \
  x -mmt=off -so artifacts/public-apps/7z2603-extra.7z x64/7za.exe \
  > artifacts/7za-from-universe.exe
cmp artifacts/7za-from-universe.exe artifacts/public-apps/7za.exe
# Identical bytes; add --jit on an ARM64 host to check the other engine.
```

Large LZMA2 containers request Linux guest threads even with `-mmt=off`; the
release extraction now completes with guest clone/futex scheduling. Windows
guest threads, broader C++/SEH behavior, networking, process creation and GUI
remain future work. The separate dynamic
Debian/glibc Hello probe still rejects the missing CPU baseline. Build current
main for these results; the v0.1.0 bundle predates this work.

This is the practical application milestone requested as “50%”: find useful
Linux or Windows apps online and run them on the user's Mac. It describes an
observable product milestone, rather than a measured percentage of every
remaining roadmap task. The broader compatibility goal remains ongoing.
