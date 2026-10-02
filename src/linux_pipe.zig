const std = @import("std");

pub const Pipe = struct {
    // ponytail: 4 KiB pipe capacity enforces Linux's atomic-write size on Darwin; grow for a measured workload.
    pub const capacity = 4096;
    allocator: std.mem.Allocator,
    used: usize = 0,
    readers: usize = 0,
    writers: usize = 0,
    references: usize = 0,
    status: [2]u32 = .{ 0, 1 },

    pub fn retain(p: *Pipe) void {
        p.references += 1;
    }
    pub fn release(p: *Pipe) void {
        p.references -= 1;
        if (p.references == 0) p.allocator.destroy(p);
    }
    pub fn ready(p: Pipe, writing: bool, minimum: usize) bool {
        return if (writing) p.readers == 0 or capacity - p.used >= minimum else p.used != 0 or p.writers == 0;
    }
};
