# Downloaded Linux apps on an ARM64 Mac

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

The official Windows x64 `7za.exe` from the same 26.03 release was inspected and
probed unchanged. Its six OLEAUT32 ordinal imports now bind to UNIVERSE's own
BSTR/variant APIs; USER32 and all nine ADVAPI32 imports bind too. It does **not** run:
all 39 MSVCRT imports also bind, and the next import boundary is
`KERNEL32!GetModuleFileNameW` (exit 125), after synchronization, file/time,
console, mapping, virtual CPU/memory, disk-space and UTF-8/UTF-16 conversion APIs bind,
before the executable entry runs.
Recognized CRT exception/RTTI entries stop if called; further Win32 APIs
and broad CRT support are still missing. Linux 7-Zip success
does not establish Windows 7-Zip compatibility. The separate dynamic
Debian/glibc Hello probe still rejects the missing CPU baseline, while the
static jq build passes these workflows. GUI apps, broad Windows compatibility,
networking, process creation and guest signal delivery remain future work.

This is the practical application milestone requested as “50%”: find useful
Linux or Windows apps online and run them on the user's Mac. It describes an
observable product milestone, rather than a measured percentage of every
remaining roadmap task. The broader compatibility goal remains ongoing.
