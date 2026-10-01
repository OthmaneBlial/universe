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

Validated on 2026-10-01: **70/70 workflows pass**, 35 in each engine:

| App | Checks per engine | Evidence |
|---|---:|---|
| jq | 7 | Exact JSON output/status: filtering, decimal addition, Unicode/sorting, false predicates, malformed JSON, file input and denied access |
| ripgrep | 9 | Version, regex searches/counts, missing matches, invalid regexes, real file input, denied access and two-thread directory search/file listing |
| 7-Zip | 19 | Format listing, SHA-256, ZIP/7z create/list/test/extract, threaded 7z round trips, independent ZIP decoding in both directions, recursive ZIP folders, corrupt/missing inputs and denied read/write access |

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
7-Zip's checks use `-mmt=off` plus a Linux `-mmt=2` 7z creation/extraction round
trip with exact bytes and timestamps. [Linux guest threads](linux-threads.md)
run serially with separate CPU/TLS state and checked futex queues; this does
not establish arbitrary thread counts or archive compatibility.
Larger workloads remain subject to instruction/time/memory limits.
Encrypted archives and other codecs are not covered by these checks.
The regression runner bounds each guest to 30 million instructions, with a
60-second execution deadline for 7-Zip and 30 seconds for jq/ripgrep. Its data,
output and exit-status assertions apply in both engines; runtime CLI limits
are separately configurable.

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
