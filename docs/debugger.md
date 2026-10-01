# Debugger

`universe debug binary` starts at the guest entry and waits for commands:

```
break 0x100113c
run
registers
step
ir
disasm
memory 0x1000000 64
stack
syscalls
continue
quit
```

One breakpoint is supported. `run` executes from the current position and stops
before it; `continue` skips the current breakpoint once. `clear` removes it.
`step [count]` executes guest instructions through the interpreter even when
`--jit` is set. Guest instruction faults and resource limits still apply.
`memory` reads guest memory with normal permission checks. Commands are bounded;
there is no expression evaluator, source-level debug information or remote server.

Add `--stats` to report instruction/syscall counts, mapped guest bytes and elapsed
time. Current main reports these after runtime faults too, including instruction
limits and all-blocked thread timeouts; the exit status remains 125. `--jit`
also reports compiled blocks, cache hits, code bytes and compilation time.
