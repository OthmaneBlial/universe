# Downloaded Linux apps on an ARM64 Mac

UNIVERSE now executes unchanged official Linux x86-64 release binaries of
[jq 1.8.2](https://github.com/jqlang/jq/releases/tag/jq-1.8.2) and
[ripgrep 15.2.0](https://github.com/BurntSushi/ripgrep/releases/tag/15.2.0).
The download script verifies pinned SHA-256 values from upstream release
metadata and also checks the extracted executable bytes. It does not compile,
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
```

The optional tests check exact output and exit statuses for JSON filtering,
decimal addition, Unicode/sorting, false predicates, malformed JSON, text
search, match counts, missing matches, invalid regexes and real input files.
They also check denied file access. ARM64 hosts run each case in interpreter
and JIT modes. The network is used only by the explicit download script;
`./scripts/check.sh` remains local and network-free.

Validated on 2026-10-01: **28/28 workflows pass**, 14 in each engine. ripgrep's
normal stdin detection works after Linux F_DUPFD/F_DUPFD_CLOEXEC support was
added; the upstream executable is unchanged.

These are command-line app workflows on Apple M2/macOS 26.6 ARM64.
ripgrep needs `--allow-files` for its working-directory query, including a
stdin search, and `--threads 1` because guest threads are unsupported.
Its printed PCRE2/JIT availability comes from the upstream build; this suite
does not establish PCRE2 JIT or general ripgrep compatibility. jq's static
glibc build runs these cases; the separate dynamic Debian/glibc Hello probe
still rejects the missing CPU baseline. GUI apps, broad Windows app
compatibility, networking, process creation and guest signal delivery remain
future work. Downloaded binaries stay under ignored `artifacts/` and are not
included in UNIVERSE release archives.

This is the practical application milestone requested as “50%”: find useful
Linux or Windows apps online and run them on the user's Mac. It describes an
observable product milestone, rather than a measured percentage of every
remaining roadmap task.
