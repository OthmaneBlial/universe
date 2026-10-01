const std = @import("std");
const Memory = @import("memory.zig").Memory;
pub const limit = 65535; // Modern 128 KiB formatted-message ceiling, including the UTF-16 terminator.

// Own English diagnostics for the virtual runtime; no vendor message DLL is consulted.
pub fn system(code: u32) ?[]const u8 {
    return switch (code) {
        0 => "The operation completed successfully.\r\n",
        2 => "The requested file was not found.\r\n",
        3 => "The requested path was not found.\r\n",
        4 => "Too many files are open.\r\n",
        5 => "Access was denied.\r\n",
        6 => "The handle is invalid.\r\n",
        8, 14 => "There is not enough memory for this operation.\r\n",
        13 => "The data is invalid.\r\n",
        17 => "The operation crosses filesystem volumes.\r\n",
        18 => "There are no more files.\r\n",
        32 => "A sharing conflict prevents file access.\r\n",
        33 => "A file lock prevents this operation.\r\n",
        38 => "The end of the file was reached.\r\n",
        50 => "This operation is not supported.\r\n",
        53 => "The network path was not found.\r\n",
        80, 183 => "A file with this name already exists.\r\n",
        87 => "A parameter is invalid.\r\n",
        109 => "The pipe has been closed.\r\n",
        112 => "The filesystem has no free space.\r\n",
        120 => "This operation is not implemented.\r\n",
        122 => "The supplied buffer is too small.\r\n",
        123 => "The name or path syntax is invalid.\r\n",
        126 => "The requested module was not found.\r\n",
        127 => "The requested procedure was not found.\r\n",
        145 => "The directory is not empty.\r\n",
        157 => "The memory object has been discarded.\r\n",
        158 => "The memory object is not locked.\r\n",
        193 => "The executable format is invalid.\r\n",
        206 => "The file name is too long.\r\n",
        212 => "The memory object is locked.\r\n",
        234 => "The result exceeds the available data limit.\r\n",
        267 => "The directory name is invalid.\r\n",
        298 => "The semaphore release count is too large.\r\n",
        317 => "No message is available for this error code.\r\n",
        487 => "The address is invalid.\r\n",
        995 => "The operation was aborted.\r\n",
        1004 => "The flags are invalid.\r\n",
        1113 => "The text cannot be converted to the requested encoding.\r\n",
        1114 => "A library initialization routine failed.\r\n",
        1117 => "A device input or output operation failed.\r\n",
        1142 => "The filesystem link limit was reached.\r\n",
        1224 => "A mapped section prevents this file operation.\r\n",
        1313 => "The requested privilege does not exist.\r\n",
        1813 => "The module has no message-table resource.\r\n",
        1815 => "The requested message language is unavailable.\r\n",
        else => null,
    };
}
pub fn read(a: std.mem.Allocator, m: *Memory, address: u64, precision: ?usize) ![]u16 {
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(a);
    for (0..@min(precision orelse limit + 1, limit + 1)) |index| {
        const next = std.math.add(u64, address, index * 2) catch return error.AddressOverflow;
        const unit: u16 = @intCast(try m.readInt(next, 16, .read));
        if (unit == 0) return units.toOwnedSlice(a);
        if (units.items.len == limit) return error.MessageTooLong;
        try units.append(a, unit);
    }
    if (precision != null) return units.toOwnedSlice(a);
    return error.MessageTooLong;
}
fn readNarrow(a: std.mem.Allocator, m: *Memory, address: u64, precision: ?usize) ![]u16 {
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(a);
    var offset: usize = 0;
    while (precision == null or units.items.len < precision.?) {
        const cursor = std.math.add(u64, address, offset) catch return error.AddressOverflow;
        const first: u8 = @intCast(try m.readInt(cursor, 8, .read));
        if (first == 0) return units.toOwnedSlice(a);
        const length = std.unicode.utf8ByteSequenceLength(first) catch return error.InvalidMessageEncoding;
        var bytes: [4]u8 = undefined;
        try m.read(cursor, bytes[0..length], .read);
        const scalar = std.unicode.utf8Decode(bytes[0..length]) catch return error.InvalidMessageEncoding;
        offset += length;
        const count = @min(@as(usize, if (scalar < 0x10000) 1 else 2), (precision orelse limit + 1) - units.items.len);
        if (units.items.len + count > limit) return error.MessageTooLong;
        if (scalar < 0x10000) try units.append(a, @intCast(scalar)) else {
            try units.append(a, @intCast(0xd800 + ((scalar - 0x10000) >> 10)));
            if (count == 2) try units.append(a, @intCast(0xdc00 + ((scalar - 0x10000) & 0x3ff)));
        }
    }
    return units.toOwnedSlice(a);
}
const hard = 0x10000;
fn push(a: std.mem.Allocator, list: *std.ArrayList(u32), unit: u32) !void {
    if (list.items.len == limit) return error.MessageTooLong;
    try list.append(a, unit);
}
fn layout(a: std.mem.Allocator, tokens: []const u32, width: u8) ![:0]u16 {
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(a);
    var column: usize = 0;
    var index: usize = 0;
    while (index < tokens.len) {
        const token = tokens[index];
        const unit: u16 = @truncate(token);
        if (width == 0 or token & hard != 0) {
            try out.append(a, unit);
            if (unit == '\r' or unit == '\n') column = 0 else column += 1;
            index += 1;
        } else if (unit == '\r' or unit == '\n' or unit == ' ' or unit == '\t') {
            try out.append(a, if (unit == '\r' or unit == '\n') ' ' else unit);
            if (unit == '\r' and index + 1 < tokens.len and tokens[index + 1] == '\n') index += 1;
            column += 1;
            index += 1;
        } else {
            var end = index;
            while (end < tokens.len and tokens[end] & hard == 0 and tokens[end] != ' ' and tokens[end] != '\t' and tokens[end] != '\r' and tokens[end] != '\n') : (end += 1) {}
            if (width != 255 and column != 0 and column + end - index > width) {
                while (out.items.len != 0 and (out.items[out.items.len - 1] == ' ' or out.items[out.items.len - 1] == '\t')) _ = out.pop();
                try out.appendSlice(a, &.{ '\r', '\n' });
                column = 0;
            }
            for (tokens[index..end]) |value| try out.append(a, @truncate(value));
            column += end - index;
            index = end;
        }
        if (out.items.len > limit) return error.MessageTooLong;
    }
    return a.dupeZ(u16, out.items);
}
pub const Arguments = struct {
    memory: *Memory,
    pointer: u64 = 0,
    array: bool = false,
    fn get(args: Arguments, index: usize) !u64 {
        if (args.pointer == 0) return error.InvalidParameter;
        const base = if (args.array) args.pointer else try args.memory.readInt(args.pointer, 64, .read);
        if (base == 0) return error.InvalidParameter;
        return args.memory.readInt(std.math.add(u64, base, index * 8) catch return error.AddressOverflow, 64, .read);
    }
};
fn digits(spec: []const u16, cursor: *usize) !usize {
    var value: usize = 0;
    while (cursor.* < spec.len and spec[cursor.*] >= '0' and spec[cursor.*] <= '9') : (cursor.* += 1) {
        value = value * 10 + spec[cursor.*] - '0';
        if (value > limit) return error.MessageTooLong;
    }
    return value;
}
fn starts(spec: []const u16, text: []const u8) bool {
    if (spec.len < text.len) return false;
    for (text, 0..) |byte, index| if (spec[index] != byte) return false;
    return true;
}
fn insert(a: std.mem.Allocator, tokens: *std.ArrayList(u32), args: Arguments, number: usize, spec: []const u16) !void {
    var cursor: usize = 0;
    var left = false;
    var plus = false;
    var blank = false;
    var alternate = false;
    var zero = false;
    while (cursor < spec.len) : (cursor += 1) switch (spec[cursor]) {
        '-' => left = true,
        '+' => plus = true,
        ' ' => blank = true,
        '#' => alternate = true,
        '0' => zero = true,
        else => break,
    };
    var argument = number - 1;
    var width: usize = 0;
    if (cursor < spec.len and spec[cursor] == '*') {
        // ponytail: dynamic fields use the documented argument-array layout; va_list star caching needs native evidence.
        if (!args.array) return error.UnsupportedMessageFormat;
        const raw: i32 = @bitCast(@as(u32, @truncate(try args.get(argument))));
        argument += 1;
        cursor += 1;
        if (raw < 0) left = true;
        width = @intCast(if (raw < 0) -@as(i64, raw) else raw);
        if (width > limit) return error.MessageTooLong;
    } else width = try digits(spec, &cursor);
    var precision: ?usize = null;
    if (cursor < spec.len and spec[cursor] == '.') {
        cursor += 1;
        if (cursor < spec.len and spec[cursor] == '*') {
            if (!args.array) return error.UnsupportedMessageFormat;
            const raw: i32 = @bitCast(@as(u32, @truncate(try args.get(argument))));
            argument += 1;
            cursor += 1;
            if (raw >= 0) precision = @intCast(raw);
            if (precision != null and precision.? > limit) return error.MessageTooLong;
        } else precision = try digits(spec, &cursor);
    }
    var bits: u7 = 32;
    var narrow = false;
    var force_wide = false;
    if (starts(spec[cursor..], "I64") or starts(spec[cursor..], "ll")) {
        bits = 64;
        cursor += if (spec[cursor] == 'I') @as(usize, 3) else 2;
    } else if (starts(spec[cursor..], "I32")) {
        cursor += 3;
    } else if (starts(spec[cursor..], "hh")) {
        bits = 8;
        narrow = true;
        cursor += 2;
    } else if (cursor < spec.len) switch (spec[cursor]) {
        'h' => {
            bits = 16;
            narrow = true;
            cursor += 1;
        },
        'l', 'w' => {
            force_wide = true;
            cursor += 1;
        },
        'I', 'z' => {
            bits = 64;
            cursor += 1;
        },
        else => {},
    };
    if (cursor + 1 != spec.len) return error.InvalidParameter;
    const kind = spec[cursor];
    if (kind == 's' or kind == 'S' or kind == 'c' or kind == 'C') {
        if (bits == 64) return error.InvalidParameter;
        if (!force_wide and (kind == 'S' or kind == 'C')) narrow = true;
        const value = try args.get(argument);
        var character: [1]u16 = .{@truncate(value)};
        var owned: ?[]u16 = null;
        defer if (owned) |data| a.free(data);
        const data: []const u16 = if (kind == 'c' or kind == 'C') blk: {
            if (narrow) {
                character[0] = @as(u8, @truncate(value));
                if (character[0] >= 128) return error.InvalidMessageEncoding;
            }
            break :blk &character;
        } else if (value == 0) std.unicode.utf8ToUtf16LeStringLiteral("(null)") else blk: {
            owned = if (narrow) try readNarrow(a, args.memory, value, precision) else try read(a, args.memory, value, precision);
            break :blk owned.?;
        };
        const count = if (kind == 's' or kind == 'S') @min(data.len, precision orelse data.len) else data.len;
        const padding = width -| count;
        if (!left) for (0..padding) |_| try push(a, tokens, ' ');
        for (data[0..count]) |unit| try push(a, tokens, unit);
        if (left) for (0..padding) |_| try push(a, tokens, ' ');
        return;
    }
    if (std.mem.indexOfScalar(u16, &.{ 'd', 'i', 'u', 'o', 'x', 'X', 'p' }, kind) == null) return error.UnsupportedMessageFormat;
    if (force_wide and cursor != 0 and spec[cursor - 1] == 'w') return error.InvalidParameter;
    if (bits == 64 and args.array) return error.InvalidParameter; // Win32 forbids 64-bit integers in argument arrays.
    const raw = try args.get(argument);
    const mask: u64 = if (bits == 64 or kind == 'p') std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
    const value = raw & mask;
    const signed = kind == 'd' or kind == 'i';
    const negative = signed and value & (@as(u64, 1) << @intCast(bits - 1)) != 0;
    const magnitude = if (negative) (~value +% 1) & mask else value;
    var buffer: [64]u8 = undefined;
    var text = switch (kind) {
        'x' => std.fmt.bufPrint(&buffer, "{x}", .{magnitude}) catch unreachable,
        'X' => std.fmt.bufPrint(&buffer, "{X}", .{magnitude}) catch unreachable,
        'p' => std.fmt.bufPrint(&buffer, "{X:0>16}", .{magnitude}) catch unreachable,
        'o' => std.fmt.bufPrint(&buffer, "{o}", .{magnitude}) catch unreachable,
        else => std.fmt.bufPrint(&buffer, "{d}", .{magnitude}) catch unreachable,
    };
    if (precision == 0 and magnitude == 0 and kind != 'p') text = text[0..0];
    var prefix: [2]u8 = undefined;
    var prefix_size: usize = 0;
    if (negative or (signed and (plus or blank))) {
        prefix[0] = if (negative) '-' else if (plus) '+' else ' ';
        prefix_size = 1;
    } else if (alternate and magnitude != 0 and (kind == 'x' or kind == 'X')) {
        prefix = .{ '0', @intCast(kind) };
        prefix_size = 2;
    }
    var zeros = (precision orelse 0) -| text.len;
    if (alternate and kind == 'o' and (text.len == 0 or text[0] != '0')) zeros = @max(zeros, 1);
    var padding = width -| (prefix_size + zeros + text.len);
    if (zero and !left and precision == null) {
        zeros += padding;
        padding = 0;
    }
    if (!left) for (0..padding) |_| try push(a, tokens, ' ');
    for (prefix[0..prefix_size]) |byte| try push(a, tokens, byte);
    for (0..zeros) |_| try push(a, tokens, '0');
    for (text) |byte| try push(a, tokens, byte);
    if (left) for (0..padding) |_| try push(a, tokens, ' ');
}
pub fn render(a: std.mem.Allocator, source: []const u16, flags: u32, args: Arguments) ![:0]u16 {
    var tokens: std.ArrayList(u32) = .empty;
    defer tokens.deinit(a);
    var index: usize = 0;
    while (index < source.len) {
        const start = index;
        const unit = source[index];
        index += 1;
        if (unit != '%') {
            try push(a, &tokens, unit);
            continue;
        }
        if (index == source.len) return error.InvalidParameter;
        const escape = source[index];
        index += 1;
        if (escape == '0') break;
        if (escape >= '1' and escape <= '9') {
            var number: usize = escape - '0';
            if (index < source.len and source[index] >= '0' and source[index] <= '9') {
                number = number * 10 + source[index] - '0';
                index += 1;
            }
            var spec: []const u16 = &.{'s'};
            if (index < source.len and source[index] == '!') {
                const end = std.mem.indexOfScalarPos(u16, source, index + 1, '!') orelse {
                    if (flags & 0x200 == 0) return error.InvalidParameter;
                    for (source[start..]) |raw| try push(a, &tokens, raw);
                    break;
                };
                spec = source[index + 1 .. end];
                index = end + 1;
            }
            if (flags & 0x200 != 0) {
                for (source[start..index]) |raw| try push(a, &tokens, raw);
            } else try insert(a, &tokens, args, number, spec);
            continue;
        }
        switch (escape) {
            'n' => {
                try push(a, &tokens, hard | '\r');
                try push(a, &tokens, hard | '\n');
            },
            'r' => try push(a, &tokens, hard | '\r'),
            't' => try push(a, &tokens, '\t'),
            else => try push(a, &tokens, escape),
        }
    }
    return layout(a, tokens.items, @truncate(flags));
}
test "message escapes and line widths preserve explicit breaks and raw UTF-16" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    const args = Arguments{ .memory = &m };
    for ([_][]const u8{ "one\r\ntwo%nthree %1!s! %0ignored", "one\r\ntwo%nthree %1!s! %0ignored" }, [_]u32{ 0x200, 0x2ff }, [_][]const u8{ "one\r\ntwo\r\nthree %1!s! ", "one two\r\nthree %1!s! " }) |text, flags, expected| {
        const source = try std.unicode.utf8ToUtf16LeAlloc(a, text);
        defer a.free(source);
        const output = try render(a, source, flags, args);
        defer a.free(output);
        const bytes = try std.unicode.utf16LeToUtf8Alloc(a, output);
        defer a.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }
    const source = std.unicode.utf8ToUtf16LeStringLiteral("one two three%nlongerword end");
    const output = try render(a, source, 7, args);
    defer a.free(output);
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("one two\r\nthree\r\nlongerword\r\nend");
    try std.testing.expectEqualSlices(u16, expected, output);
    const raw = try render(a, &.{ 0xd800, '%', 't', 0xdc00 }, 0, args);
    defer a.free(raw);
    try std.testing.expectEqualSlices(u16, &.{ 0xd800, '\t', 0xdc00 }, raw);
    try std.testing.expectError(error.InvalidParameter, render(a, &.{'%'}, 0, args));
}
