const std = @import("std");
const upper = @import("windows_upper.zig").upper;

// Win32 wildcard translation and DOS matching, over UTF-16 code units.
// https://github.com/dotnet/runtime/blob/main/src/libraries/System.Private.CoreLib/src/System/IO/Enumeration/FileSystemName.cs
pub fn matches(pattern: []const u16, name: []const u16) bool {
    std.debug.assert(name.len < 260); // WIN32_FIND_DATAW includes a terminator.
    if (pattern.len == 0 or name.len == 0) return false;
    if (std.mem.eql(u16, pattern, &.{ '*', '.', '*' })) return true;
    // ponytail: bounded O(pattern units * 260) DP; no backtracking or heap state.
    var previous: [260]bool = @splat(false);
    previous[0] = true;
    const last_dot = std.mem.lastIndexOfScalar(u16, name, '.');
    var index: usize = 0;
    while (index < pattern.len) : (index += 1) {
        var token = pattern[index];
        if (token == '*' and index + 2 == pattern.len and pattern[index + 1] == '.') {
            token = '<'; // DOS_STAR cannot consume the final period.
            index += 1;
        } else if (token == '?') {
            token = '>'; // DOS_QM can disappear at a period or end of name.
        } else if (token == '.' and index + 1 < pattern.len and (pattern[index + 1] == '?' or pattern[index + 1] == '*')) {
            token = '"'; // DOS_DOT can disappear only at end of name.
        }
        var next: [260]bool = @splat(false);
        for (0..name.len + 1) |cursor| {
            next[cursor] = switch (token) {
                '*', '<' => previous[cursor] or (cursor != 0 and next[cursor - 1] and (token == '*' or last_dot != cursor - 1)),
                '>' => (previous[cursor] and (cursor == name.len or name[cursor] == '.')) or (cursor != 0 and name[cursor - 1] != '.' and previous[cursor - 1]),
                '"' => (cursor == name.len and previous[cursor]) or (cursor != 0 and name[cursor - 1] == '.' and previous[cursor - 1]),
                else => cursor != 0 and previous[cursor - 1] and upper(token) == upper(name[cursor - 1]),
            };
        }
        previous = next;
    }
    return previous[name.len];
}

test "Win32 leaf patterns match DOS periods, optional question marks and BMP case" {
    const Case = struct { pattern: []const u8, name: []const u8, expected: bool };
    for ([_]Case{
        .{ .pattern = "*", .name = "extensionless", .expected = true },
        .{ .pattern = "*.*", .name = "extensionless", .expected = true },
        .{ .pattern = "file.*", .name = "file", .expected = true },
        .{ .pattern = "file.*", .name = "file.a.b", .expected = true },
        .{ .pattern = "file.", .name = "file", .expected = false },
        .{ .pattern = "*.", .name = "file", .expected = true },
        .{ .pattern = "*.", .name = "file.txt", .expected = false },
        .{ .pattern = "*.", .name = "file.", .expected = false },
        .{ .pattern = "a??.txt", .name = "a.txt", .expected = true },
        .{ .pattern = "a??.txt", .name = "abc.txt", .expected = true },
        .{ .pattern = "a??.txt", .name = "abcd.txt", .expected = false },
        .{ .pattern = "a?b", .name = "ab", .expected = false },
        .{ .pattern = "é?.TXT", .name = "Éa.txt", .expected = true },
        .{ .pattern = "??", .name = "🚀", .expected = true },
        .{ .pattern = "?", .name = "🚀", .expected = false },
        .{ .pattern = "*a*a*b", .name = "aaaac", .expected = false },
    }) |case| {
        const pattern = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, case.pattern);
        defer std.testing.allocator.free(pattern);
        const name = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, case.name);
        defer std.testing.allocator.free(name);
        try std.testing.expectEqual(case.expected, matches(pattern, name));
    }
    const pattern: [32767]u16 = @splat('*');
    const name: [259]u16 = @splat('x');
    try std.testing.expect(matches(&pattern, &name));
}
