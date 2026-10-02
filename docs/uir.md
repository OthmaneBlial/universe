# UIR

UIR is an in-memory, typed instruction representation, not a text language.
`src/ir.zig` is its schema. Each decoded instruction carries `pc`, `next`, an
operation, operands, width, an optional source width and condition.

Operands are immediates, registers (including x86 high bytes), memory addresses,
computed addresses, shifted/extended register values and 128-bit vectors
(16 x86 XMM or 32 AArch64 V registers). On x86, vector indices 16 through
23 denote the eight 64-bit MMX registers and alias the low bytes of physical
x87 registers; they do not use the separate XMM storage. Mixed MMX/XMM bridge
and conversion instructions keep each operand's register bank explicit.
Addresses hold optional base,
index, scale and displacement; relative operands use the **end of the complete
instruction**, including its immediate bytes. Loads and stores stay explicit in
operand kinds and go through guest memory.

Arithmetic normally reads the destination as its left operand. Three-register
architectures supply `lhs`. RISC-V word results request sign extension.
Architecture-independent comparisons can feed branches without changing flags.
x86 and ARM arithmetic request flag changes; carry uses the respective ISA's
borrow convention. ARM bitfield operations describe rotation, write/top masks
and optional sign filling. Pair transfers and address writeback are represented
within one instruction so stepping retains guest instruction boundaries. Long
multiply records source width and signedness separately from destination width.
AArch64 TPIDR_EL0 uses virtual register 33; SP and XZR remain distinct.
Repeated x86 string operations perform one element per step and retain the
same PC while more iterations remain. Each element counts toward `instructions`
and resource limits; a zero-count REP advances once without accessing memory.
Completed elements remain visible if a later element faults. Direction and
32/64-bit address width are preserved in the execution state and UIR.

`universe inspect --ir --count 8 program` and `universe disasm program` expose
this representation. Register names are numbered by hardware encoding (x86:
RAX=0, RCX=1, RDX=2, RBX=3, RSP=4, RBP=5, RSI=6, RDI=7).
Vector operations cover raw transfers, bitwise logic, packed integer comparison,
unpacking, shuffling, min/max and immediate shifts. Scalar/XMM transfers carry
32/64-bit widths. AArch64 scalar/vector moves also carry lane index and source
width for zero/sign extension. Immediate patterns and DUP carry 8/16-byte vector
width; pair transfers carry 4/8/16-byte widths. MMX operations carry an
eight-byte span, while full XMM operations use 16 bytes. Packed conversions
reuse the existing operations: their span and operation determine the source
and destination lane counts. CVTPI2PS preserves the high XMM quadword;
CVTPI2PD reads eight integer bytes and replaces all 16 XMM bytes. A memory
CVTPI2PS still enters MMX state, while a memory CVTPI2PD preserves x87 state.
These execute in
`src/vector.zig`; shared operand access lives in `src/operands.zig`.

Exclusive loads/stores use explicit UIR operations and checked guest memory.
The reservation stores address, width, memory write count and mapping generation;
an exclusive store clears it and writes a 32-bit success/failure status. Barriers
are no-ops in the ordered, serialized guest execution model. Guest thread
switches clear reservations. AArch64 acquire loads and release stores use
explicit UIR operations, aligned checked memory and this same ordering.
RISC-V LR.W requests sign extension;
SC and word/doubleword AMOs carry the memory width separately from their result
register. AMOs capture the old value and source before any aliased output and
return the old word sign-extended to 64 bits. They stay interpreted in JIT mode.

UIR is not serialized; there is no parser/serializer to fuzz or claim supported.
