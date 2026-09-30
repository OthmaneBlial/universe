# UIR

UIR is an in-memory, typed instruction representation, not a text language.
`src/ir.zig` is its schema. Each decoded instruction carries `pc`, `next`, an
operation, operands, width, an optional source width and condition.

Operands are immediates, registers (including x86 high bytes), memory addresses,
computed addresses and shifted register values. Addresses hold optional base,
index, scale and displacement; relative operands use the **end of the complete
instruction**, including its immediate bytes. Loads and stores stay explicit in
operand kinds and go through guest memory.

Arithmetic normally reads the destination as its left operand. Three-register
architectures supply `lhs`. RISC-V word results request sign extension.
Architecture-independent comparisons can feed branches without changing flags.
x86 and ARM arithmetic request flag changes; carry uses the respective ISA's
borrow convention. ARM bitfield operations describe rotation, write/top masks
and optional sign filling. Pair transfers and address writeback are represented
within one instruction so stepping retains guest instruction boundaries.

`universe inspect --ir --count 8 program` and `universe disasm program` expose
this representation. Register names are numbered by hardware encoding (x86:
RAX=0, RCX=1, RDX=2, RBX=3, RSP=4, RBP=5, RSI=6, RDI=7).
UIR is not serialized; there is no parser/serializer to fuzz or claim supported.
