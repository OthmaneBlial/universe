//! Linux termios ioctls over a real host terminal. Flag bits and control-character slots are
//! translated through the host libc constants; unknown Linux bits are dropped, not passed through.
const std = @import("std");
const c = @import("host.zig").c;

pub const tcgets = 0x5401;
pub const tcsets = 0x5402; // TCSETSW and TCSETSF follow at 0x5403 and 0x5404.
pub const tiocgwinsz = 0x5413;
const Bit = struct { linux: u32, host: c.tcflag_t };
const input = [_]Bit{
    .{ .linux = 0x1, .host = c.IGNBRK },     .{ .linux = 0x2, .host = c.BRKINT },   .{ .linux = 0x4, .host = c.IGNPAR },
    .{ .linux = 0x8, .host = c.PARMRK },     .{ .linux = 0x10, .host = c.INPCK },   .{ .linux = 0x20, .host = c.ISTRIP },
    .{ .linux = 0x40, .host = c.INLCR },     .{ .linux = 0x80, .host = c.IGNCR },   .{ .linux = 0x100, .host = c.ICRNL },
    .{ .linux = 0x400, .host = c.IXON },     .{ .linux = 0x800, .host = c.IXANY },  .{ .linux = 0x1000, .host = c.IXOFF },
    .{ .linux = 0x2000, .host = c.IMAXBEL }, .{ .linux = 0x4000, .host = c.IUTF8 },
};
const output = [_]Bit{
    .{ .linux = 0x1, .host = c.OPOST },  .{ .linux = 0x4, .host = c.ONLCR },   .{ .linux = 0x8, .host = c.OCRNL },
    .{ .linux = 0x10, .host = c.ONOCR }, .{ .linux = 0x20, .host = c.ONLRET },
};
const control = [_]Bit{
    .{ .linux = 0x40, .host = c.CSTOPB },  .{ .linux = 0x80, .host = c.CREAD },  .{ .linux = 0x100, .host = c.PARENB },
    .{ .linux = 0x200, .host = c.PARODD }, .{ .linux = 0x400, .host = c.HUPCL }, .{ .linux = 0x800, .host = c.CLOCAL },
};
const local = [_]Bit{
    .{ .linux = 0x1, .host = c.ISIG },      .{ .linux = 0x2, .host = c.ICANON },    .{ .linux = 0x8, .host = c.ECHO },
    .{ .linux = 0x10, .host = c.ECHOE },    .{ .linux = 0x20, .host = c.ECHOK },    .{ .linux = 0x40, .host = c.ECHONL },
    .{ .linux = 0x80, .host = c.NOFLSH },   .{ .linux = 0x100, .host = c.TOSTOP },  .{ .linux = 0x200, .host = c.ECHOCTL },
    .{ .linux = 0x400, .host = c.ECHOPRT }, .{ .linux = 0x800, .host = c.ECHOKE },  .{ .linux = 0x1000, .host = c.FLUSHO },
    .{ .linux = 0x4000, .host = c.PENDIN }, .{ .linux = 0x8000, .host = c.IEXTEN },
};
const sizes = [_]Bit{ .{ .linux = 0x10, .host = c.CS6 }, .{ .linux = 0x20, .host = c.CS7 }, .{ .linux = 0x30, .host = c.CS8 } };
// Linux c_cc index for each host control character: VINTR VQUIT VERASE VKILL VEOF VTIME VMIN VSTART VSTOP VSUSP VEOL VREPRINT VDISCARD VWERASE VLNEXT VEOL2.
const characters = [_]struct { linux: usize, host: usize }{
    .{ .linux = 0, .host = c.VINTR },     .{ .linux = 1, .host = c.VQUIT },    .{ .linux = 2, .host = c.VERASE },
    .{ .linux = 3, .host = c.VKILL },     .{ .linux = 4, .host = c.VEOF },     .{ .linux = 5, .host = c.VTIME },
    .{ .linux = 6, .host = c.VMIN },      .{ .linux = 8, .host = c.VSTART },   .{ .linux = 9, .host = c.VSTOP },
    .{ .linux = 10, .host = c.VSUSP },    .{ .linux = 11, .host = c.VEOL },    .{ .linux = 12, .host = c.VREPRINT },
    .{ .linux = 13, .host = c.VDISCARD }, .{ .linux = 14, .host = c.VWERASE }, .{ .linux = 15, .host = c.VLNEXT },
    .{ .linux = 16, .host = c.VEOL2 },
};
fn toLinux(table: []const Bit, value: c.tcflag_t) u32 {
    var result: u32 = 0;
    for (table) |bit| if (value & bit.host == bit.host) {
        result |= bit.linux;
    };
    return result;
}
fn toHost(table: []const Bit, value: u32, keep: c.tcflag_t) c.tcflag_t {
    var result = keep;
    for (table) |bit| if (value & bit.linux != 0) {
        result |= bit.host;
    };
    return result;
}
/// The 36-byte kernel `struct termios` returned by TCGETS; speed reads as B38400.
pub fn encode(t: c.struct_termios) [36]u8 {
    var bytes: [36]u8 = @splat(0);
    const size = t.c_cflag & c.CSIZE;
    var cflag = toLinux(&control, t.c_cflag) | 0xf;
    for (sizes) |entry| if (size == entry.host) {
        cflag |= entry.linux;
    };
    std.mem.writeInt(u32, bytes[0..4], toLinux(&input, t.c_iflag), .little);
    std.mem.writeInt(u32, bytes[4..8], toLinux(&output, t.c_oflag), .little);
    std.mem.writeInt(u32, bytes[8..12], cflag, .little);
    std.mem.writeInt(u32, bytes[12..16], toLinux(&local, t.c_lflag), .little);
    for (characters) |entry| bytes[17 + entry.linux] = t.c_cc[entry.host];
    return bytes;
}
/// Applies guest settings over `current`, keeping host speed and host-only flags.
pub fn decode(bytes: [36]u8, current: c.struct_termios) c.struct_termios {
    var t = current;
    const keep_c = current.c_cflag & ~@as(c.tcflag_t, c.CSIZE | c.CSTOPB | c.CREAD | c.PARENB | c.PARODD | c.HUPCL | c.CLOCAL);
    t.c_iflag = toHost(&input, std.mem.readInt(u32, bytes[0..4], .little), current.c_iflag & ~mask(&input));
    t.c_oflag = toHost(&output, std.mem.readInt(u32, bytes[4..8], .little), current.c_oflag & ~mask(&output));
    const cflag = std.mem.readInt(u32, bytes[8..12], .little);
    t.c_cflag = toHost(&control, cflag, keep_c);
    for (sizes) |entry| if (cflag & 0x30 == entry.linux) {
        t.c_cflag |= entry.host;
    };
    t.c_lflag = toHost(&local, std.mem.readInt(u32, bytes[12..16], .little), current.c_lflag & ~mask(&local));
    for (characters) |entry| t.c_cc[entry.host] = bytes[17 + entry.linux];
    return t;
}
fn mask(table: []const Bit) c.tcflag_t {
    var result: c.tcflag_t = 0;
    for (table) |bit| result |= bit.host;
    return result;
}
test "Linux termios bytes round-trip through host flags" {
    var t = std.mem.zeroes(c.struct_termios);
    t.c_iflag = c.ICRNL | c.IXON | c.IUTF8;
    t.c_oflag = c.OPOST | c.ONLCR;
    t.c_cflag = c.CS8 | c.CREAD;
    t.c_lflag = c.ISIG | c.ICANON | c.ECHO | c.IEXTEN;
    t.c_cc[c.VINTR] = 3;
    t.c_cc[c.VMIN] = 1;
    const bytes = encode(t);
    try std.testing.expectEqual(@as(u32, 0x100 | 0x400 | 0x4000), std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0x5), std.mem.readInt(u32, bytes[4..8], .little));
    try std.testing.expectEqual(@as(u32, 0x30 | 0x80 | 0xf), std.mem.readInt(u32, bytes[8..12], .little));
    try std.testing.expectEqual(@as(u32, 0x1 | 0x2 | 0x8 | 0x8000), std.mem.readInt(u32, bytes[12..16], .little));
    try std.testing.expectEqual(@as(u8, 3), bytes[17]);
    try std.testing.expectEqual(@as(u8, 1), bytes[17 + 6]);
    var raw = bytes;
    std.mem.writeInt(u32, raw[12..16], 0x1, .little); // Clear ICANON and ECHO, as a raw-mode editor does.
    const back = decode(raw, t);
    try std.testing.expect(back.c_lflag & c.ICANON == 0 and back.c_lflag & c.ECHO == 0 and back.c_lflag & c.ISIG != 0);
    try std.testing.expectEqual(t.c_iflag, back.c_iflag);
    try std.testing.expectEqual(t.c_cflag, back.c_cflag);
    try std.testing.expectEqualSlices(u8, &bytes, &encode(decode(bytes, t)));
}
