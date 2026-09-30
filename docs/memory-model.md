# Guest virtual memory

Regions own zero-initialized byte arrays, separate from host virtual addresses.
Each region carries a guest base and R/W/X permissions. Reads, writes and fetches
validate the entire range, including arithmetic overflow, before accessing data.
A multi-region write checks permissions before changing any bytes.

Mach-O regions also retain each segment's maximum permissions. A protection
request exceeding any covered region's maximum fails before changing permissions.
Region splits and fixed-replacement tails retain this maximum; a newly allocated
replacement has its own permissions. Darwin mapping calls use 4 KiB x86 pages
or 16 KiB ARM pages over the shared 4 KiB-granularity backing model.

Mappings are page aligned and bounded to the lower 47-bit address range.
The defaults cap mapped backing storage at 256 MiB and regions at 1024. A linear
region search is intentionally used at this scale. Stack is 1 MiB with unmapped
space below it. brk reserves 16 MiB; mmap allocates separately. Partial unmap and
protection split regions, retaining data and permissions on unaffected pages.
Splitting may temporarily allocate extra host memory; the guest limit is not a
host RSS limit. Guest W+X mappings are allowed, but they are byte arrays, never
host executable pages. JIT code has its separate host W^X policy.

Private file mappings eagerly copy regular-file bytes into guest backing
storage without moving the host descriptor offset. The final partial page is
zero-filled; whole pages beyond EOF retain a fault boundary across permission
changes and region splits. Access there stops with BusError rather than a
delivered guest signal. Shared mappings and later file-change coherence are
unsupported. Fixed replacement allocates new backing and both surviving tails
before changing existing regions; allocation or file-read failure leaves them
intact. Temporary backing allocations can exceed the mapped guest byte count.

Execution errors preserve access, address and size. Code-generation invalidation
uses a memory generation counter for executable writes and mapping/protection
changes, and caches recheck execute permission.

A separate write counter also tracks non-executable writes. AArch64 exclusive
loads and RISC-V LR save this counter and the mapping generation; exclusive
stores succeed only while both remain unchanged and the address/width match. Any intervening
write conservatively invalidates the reservation. This is a single-thread
model; reservation granules and guest thread synchronization are not implemented.
RISC-V SC additionally checks write permissions on a failed reservation. AMOs
validate alignment and checked reads/writes before publishing a register result.
