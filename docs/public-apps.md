# Downloaded Linux and Windows apps on an ARM64 Mac

UNIVERSE executes unchanged official Linux x86-64 release binaries of
[jq 1.8.2](https://github.com/jqlang/jq/releases/tag/jq-1.8.2),
[ripgrep 15.2.0](https://github.com/BurntSushi/ripgrep/releases/tag/15.2.0) and
[7-Zip 26.03](https://github.com/ip7z/7zip/releases/tag/26.03) (`7zzs`).
The download script verifies pinned SHA-256 values from upstream release
metadata and checks the extracted executable bytes. It does not compile,
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
```

Validated on 2026-10-01: **62/62 workflows pass**, 31 in each engine:

| App | Checks per engine | Evidence |
|---|---:|---|
| jq | 7 | Exact JSON output/status: filtering, decimal addition, Unicode/sorting, false predicates, malformed JSON, file input and denied access |
| ripgrep | 7 | Version, regex searches/counts, missing matches, invalid regexes, real file input and denied access |
| 7-Zip | 17 | Format listing, SHA-256, ZIP/7z create/list/test/extract, independent ZIP decoding in both directions, recursive ZIP folders, corrupt/missing inputs and denied read/write access |

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
`--allow-files` for its working-directory query, including stdin searches, and
`--threads 1`. The printed PCRE2/JIT availability comes from its upstream build;
this suite does not establish PCRE2 JIT or general ripgrep compatibility.
7-Zip's tested compression/extraction uses `-mmt=off`; guest threads remain
unsupported. Larger workloads remain subject to instruction/time/memory limits.
Encrypted archives and other codecs are not covered by these checks.
The regression runner bounds each guest to 30 million instructions, with a
60-second execution deadline for 7-Zip and 30 seconds for jq/ripgrep. Its data,
output and exit-status assertions apply in both engines; runtime CLI limits
are separately configurable.

## Windows 7-Zip on the same Mac

The unchanged official Windows x64 `7za.exe` from 26.03 now completes
**30 application workflows**, 15 per engine: format listing, SHA-256, ZIP/7z
creation/listing/testing/extraction, Unicode/binary/empty members and exact
modification timestamps. Python independently reads the produced ZIP and the
guest extracts a ZIP made by Python. Recursive folders, corrupt input and a
missing-file warning are checked too. These are scoped console workflows;
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

The Windows probe currently **exits 1: 30 workflows pass, four denied-access
exit checks fail**. Both engines deny the requested filesystem operations and
leave the destination absent, but the application's C++ throw then reaches
`WindowsExceptionHandlingUnsupported` (runtime exit 125 rather than the expected
application exit 2). These failures remain in the probe for the next exception
handling milestone; they are not counted as passing application workflows.
The local core CI and optional downloaded-app probe are separate checks.

The download verifies upstream archive SHA-256
`191894e6acb3647ffb69ce630479ff318523b2e2b9890aa7f05c1127c2e59b8f`
and executable SHA-256
`edbee35370e14030e4c785cf88200f42dc651c1eb4217c1e3963c38a12f099b0`.
macOS's built-in tar reads the release container; another host needs a system
tar with 7z support. This extracts bytes and does not execute the Windows app.
Its execution uses UNIVERSE's own CPU, loader and API implementation.

Large LZMA2 containers can still request guest threads in Linux 7-Zip even
with `-mmt=off`; our own-runtime extraction probe of this release container
stops at unsupported Linux `clone`. Guest threads, C++ exception handling,
networking, process creation and GUI remain future work. The separate dynamic
Debian/glibc Hello probe still rejects the missing CPU baseline. Build current
main for these results; the v0.1.0 bundle predates this work.

This is the practical application milestone requested as “50%”: find useful
Linux or Windows apps online and run them on the user's Mac. It describes an
observable product milestone, rather than a measured percentage of every
remaining roadmap task. The broader compatibility goal remains ongoing.
