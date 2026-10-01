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
pub fn render(a: std.mem.Allocator, source: []const u16, flags: u32) ![:0]u16 {
    var tokens: std.ArrayList(u32) = .empty;
    defer tokens.deinit(a);
    var index: usize = 0;
    while (index < source.len) {
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
            if (flags & 0x200 == 0) return error.UnsupportedMessageFormat;
            try push(a, &tokens, '%');
            try push(a, &tokens, escape);
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
    for ([_][]const u8{ "one\r\ntwo%nthree %1!s! %0ignored", "one\r\ntwo%nthree %1!s! %0ignored" }, [_]u32{ 0x200, 0x2ff }, [_][]const u8{ "one\r\ntwo\r\nthree %1!s! ", "one two\r\nthree %1!s! " }) |text, flags, expected| {
        const source = try std.unicode.utf8ToUtf16LeAlloc(a, text);
        defer a.free(source);
        const output = try render(a, source, flags);
        defer a.free(output);
        const bytes = try std.unicode.utf16LeToUtf8Alloc(a, output);
        defer a.free(bytes);
        try std.testing.expectEqualStrings(expected, bytes);
    }
    const source = std.unicode.utf8ToUtf16LeStringLiteral("one two three%nlongerword end");
    const output = try render(a, source, 7);
    defer a.free(output);
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("one two\r\nthree\r\nlongerword\r\nend");
    try std.testing.expectEqualSlices(u16, expected, output);
    const raw = try render(a, &.{ 0xd800, '%', 't', 0xdc00 }, 0);
    defer a.free(raw);
    try std.testing.expectEqualSlices(u16, &.{ 0xd800, '\t', 0xdc00 }, raw);
    try std.testing.expectError(error.InvalidParameter, render(a, &.{'%'}, 0));
}
