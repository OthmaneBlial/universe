const std = @import("std");
pub fn main() void {
    std.debug.print("UNIVERSE 0.1.0 — experimental binary runtime\n", .{});
}
test "version" {
    try std.testing.expect(true);
}
