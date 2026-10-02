# Guest virtual memory

Regions own zero-initialized byte arrays, separate from host virtual addresses.
Each region carries a guest base and R/W/X permissions. Reads, writes and fetches
validate the entire range, including arithmetic overflow, before accessing data.
A multi-region write checks permissions before changing any bytes.

PE loading reserves the full image with inaccessible gaps and section-specific
permissions. A failed image load removes its range; runtime DLL unload removes
it after guest detach callbacks. Overlapping PE pages reject before mapping.

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
write conservatively invalidates the reservation, as does a guest thread switch.
Guest instructions execute serially; reservation granules are not tracked.
AArch64 LDAR/STLR use naturally aligned checked memory, with SP bases also
requiring 16-byte stack alignment. Serialized execution supplies acquire/release
ordering. Linux shared-memory guest threads use this same memory model; see
[linux-threads.md](linux-threads.md).
Isolated [Linux fork children](linux-processes.md) eagerly duplicate private
regions, retaining permissions and EOF boundaries. One shared budget accounts
for every process's mapped bytes; allocation failures do not publish a child.
Child exit releases its backing before wait reaps its status. Process switches
clear JIT blocks, because independent generation counters can have equal values
while referring to different code bytes. Linux exec also clears those blocks
and resets CPU/TLS state after a complete checked image is ready. Replacing the
image credits its old mapped bytes before charging the shared budget; a failed
allocation preserves the old mappings and accounting. Staging temporarily keeps
both bounded images in host memory; the mapped-memory cap is not a peak host-RSS
guarantee.
RISC-V SC additionally checks write permissions on a failed reservation. AMOs
validate alignment and checked reads/writes before publishing a register result.
