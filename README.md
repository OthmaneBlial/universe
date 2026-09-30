# UNIVERSE

**Run software that was never built for your computer.**

An experimental universal binary runtime written primarily in Zig. Under active construction: compatibility claims will be backed by executable fixtures.

## Development

Requires Zig 0.16.0 and a POSIX host.

```sh
zig build
zig build test
zig fmt --check build.zig src
```

Apache-2.0 licensed. No external CPU emulator or compatibility layer.
