const std = @import("std");
const host = @import("host.zig");
const signals = [_]std.c.SIG{ .INT, .QUIT };
var owner = std.atomic.Value(bool).init(false);
var pending = std.atomic.Value(u32).init(0);
var ignore_int = std.atomic.Value(bool).init(false);
fn receive(signal: std.c.SIG) callconv(.c) void {
    if (signal == .INT and ignore_int.load(.acquire)) return;
    // Only lock-free atomic work in the native handler; guest code runs at runtime checkpoints.
    _ = pending.fetchOr(if (signal == .INT) 1 else 2, .monotonic);
}
pub const Console = struct {
    active: bool = false,
    saved_signals: [2]std.c.Sigaction = undefined,
    input_fd: c_int = -1,
    saved_input: host.c.struct_termios = undefined,
    pub fn start(console: *Console) !void {
        if (console.active) return;
        // ponytail: one signal-owning runtime per host process; a supervisor is needed for parallel guests.
        if (owner.cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) return error.WindowsConsoleBusy;
        errdefer owner.store(false, .release);
        pending.store(0, .release);
        ignore_int.store(false, .release);
        const action = std.c.Sigaction{ .handler = .{ .handler = receive }, .mask = std.posix.sigemptyset(), .flags = 0 };
        for (signals, 0..) |signal, index| {
            if (std.c.sigaction(signal, &action, &console.saved_signals[index]) != 0) {
                for (signals[0..index], console.saved_signals[0..index]) |old_signal, *old| _ = std.c.sigaction(old_signal, old, null);
                return error.HostConsoleSignalsFailed;
            }
        }
        console.active = true;
    }
    pub fn deinit(console: *Console) void {
        if (console.input_fd >= 0) {
            _ = host.c.tcsetattr(console.input_fd, host.c.TCSANOW, &console.saved_input);
            _ = host.c.close(console.input_fd);
        }
        if (console.active) {
            for (signals, &console.saved_signals) |signal, *old| _ = std.c.sigaction(signal, old, null);
            pending.store(0, .release);
            ignore_int.store(false, .release);
            owner.store(false, .release);
        }
    }
    pub fn hasEvent(console: Console) bool {
        return console.active and pending.load(.acquire) != 0;
    }
    pub fn ignoreC(console: Console, ignore: bool) void {
        if (!console.active) return;
        ignore_int.store(ignore, .release);
        if (ignore) _ = pending.fetchAnd(~@as(u32, 1), .acq_rel);
    }
    pub fn take(console: Console) ?u32 {
        if (!console.active) return null;
        const bits = pending.load(.acquire);
        if (bits == 0) return null;
        const bit: u32 = if (bits & 1 != 0) 1 else 2;
        _ = pending.fetchAnd(~bit, .acq_rel);
        return if (bit == 1) 0 else 1;
    }
    pub fn inputMode() !u32 {
        var attributes: host.c.struct_termios = undefined;
        if (host.c.tcgetattr(0, &attributes) != 0) return error.HostConsoleModeFailed;
        return @as(u32, @intFromBool(attributes.c_lflag & host.c.ISIG != 0)) |
            (@as(u32, @intFromBool(attributes.c_lflag & host.c.ICANON != 0)) << 1) |
            (@as(u32, @intFromBool(attributes.c_lflag & host.c.ECHO != 0)) << 2);
    }
    pub fn setInput(console: *Console, mode: u32) !void {
        var attributes: host.c.struct_termios = undefined;
        if (host.c.tcgetattr(0, &attributes) != 0) return error.HostConsoleModeFailed;
        if (console.input_fd < 0) {
            const backup = host.c.fcntl(0, host.c.F_DUPFD_CLOEXEC, @as(c_int, 3));
            if (backup < 0) return error.HostConsoleModeFailed;
            console.saved_input = attributes;
            console.input_fd = backup;
        }
        for ([_]host.c.tcflag_t{ host.c.ISIG, host.c.ICANON, host.c.ECHO }, 0..) |bit, index| {
            if (mode & (@as(u32, 1) << @intCast(index)) != 0) attributes.c_lflag |= bit else attributes.c_lflag &= ~bit;
        }
        if (mode & 2 == 0) {
            attributes.c_cc[host.c.VMIN] = 1;
            attributes.c_cc[host.c.VTIME] = 0;
        }
        if (host.c.tcsetattr(0, host.c.TCSANOW, &attributes) != 0) return error.HostConsoleModeFailed;
    }
};
