const std = @import("std");
const host = @import("../host.zig");
const Memory = @import("../memory.zig").Memory;
const pe = @import("pe.zig");
const Builtin = @import("../syscall/windows.zig").Builtin;
pub const Symbol = union(enum) { name: []const u8, ordinal: u16 };
pub const Module = struct {
    name: []const u8,
    path: ?[]const u8 = null,
    base: u64,
    size: u32,
    entry: u64,
    imports: pe.Directory,
    exports: pe.Directory,
    exceptions: pe.Directory = .{ .rva = 0, .size = 0 },
    active: bool = true,
    references: u32 = 0,
    dependencies: u64 = 0,
    attached: bool = false,
    attach_called: bool = false,
    tls: ?pe.Tls = null,
    pub fn address(module: Module, value: u64, size: u64) !u64 {
        if (value >= module.size or size > module.size - value) return error.InvalidWindowsRva;
        return module.base + value;
    }
    pub fn functionEntry(module: Module, m: *Memory, pc: u64) !?u64 {
        if (pc < module.base or pc - module.base >= module.size or module.exceptions.size == 0) return null;
        const directory = module.exceptions;
        if (directory.rva & 3 != 0 or directory.size % 12 != 0) return error.InvalidWindowsFunctionTable;
        if (directory.size / 12 > 65536) return error.WindowsFunctionTableLimit;
        const table = try module.address(directory.rva, directory.size);
        try m.check(table, directory.size, .read);
        var found: ?u64 = null;
        var previous_end: u64 = 0;
        // ponytail: validate at most 65,536 live records per lookup; cache immutable tables if real unwind volume needs it.
        var offset: u64 = 0;
        while (offset < directory.size) : (offset += 12) {
            const start = try m.readInt(table + offset, 32, .read);
            const end = try m.readInt(table + offset + 4, 32, .read);
            const unwind = try m.readInt(table + offset + 8, 32, .read);
            if (start >= end or start < previous_end or end > module.size or unwind == 0 or unwind & 3 != 0) return error.InvalidWindowsFunctionTable;
            try m.check(try module.address(start, end - start), @intCast(end - start), .execute);
            try m.check(try module.address(unwind, 4), 4, .read);
            if (pc - module.base >= start and pc - module.base < end) found = table + offset;
            previous_end = end;
        }
        return found;
    }
    fn string(module: Module, a: std.mem.Allocator, m: *Memory, value: u64) ![:0]u8 {
        const guest_address = try module.address(value, 1);
        return m.cstring(a, guest_address, @intCast(@min(4096, module.size - value)));
    }
};

test "PE named, ordinal, data and forwarded exports validate indices and RVAs" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 0x3000, .{ .read = true, .write = true, .execute = true });
    var l = Linker{ .allocator = a };
    defer l.deinit();
    try l.modules.append(a, .{ .name = try a.dupe(u8, "test.dll"), .base = 0x1000, .size = 0x3000, .entry = 0, .imports = .{ .rva = 0, .size = 0 }, .exports = .{ .rva = 0x100, .size = 0x200 } });
    for ([_]u64{ 16, 20, 24, 28, 32, 36 }, [_]u64{ 7, 4, 3, 0x180, 0x1b0, 0x1c0 }) |offset, value| try m.writeInt(0x1100 + offset, 32, value);
    for ([_]u64{ 0x1000, 0x2000, 0x280, 0 }, 0..) |value, n| try m.writeInt(0x1180 + n * 4, 32, value);
    for ([_]u64{ 0x200, 0x210, 0x220 }, 0..) |value, n| {
        try m.writeInt(0x11b0 + n * 4, 32, value);
        try m.writeInt(0x11c0 + n * 2, 16, n);
    }
    try m.write(0x1200, "function\x00");
    try m.write(0x1210, "data\x00");
    try m.write(0x1220, "forward\x00");
    try m.write(0x1280, "kernel32.WriteFile\x00");
    try std.testing.expectEqual(@as(u64, 0x2000), try l.resolve(&m, 0, .{ .name = "function" }, false, 0));
    try std.testing.expectEqual(@as(u64, 0x2000), try l.resolve(&m, 0, .{ .ordinal = 7 }, false, 0));
    try std.testing.expectEqual(@as(u64, 0x3000), try l.resolve(&m, 0, .{ .name = "data" }, false, 0));
    try std.testing.expectEqual(@import("../syscall/windows.zig").apiAddress("WriteFile").?, try l.resolve(&m, 0, .{ .name = "forward" }, false, 0));
    try m.write(0x1280, "KERNEL32.dll.WriteFile\x00");
    try std.testing.expectEqual(@import("../syscall/windows.zig").apiAddress("WriteFile").?, try l.resolve(&m, 0, .{ .name = "forward" }, false, 0));
    try std.testing.expectError(error.WindowsExportNotFound, l.resolve(&m, 0, .{ .ordinal = 6 }, false, 0));
    try std.testing.expectError(error.WindowsExportNotFound, l.resolve(&m, 0, .{ .ordinal = 10 }, false, 0));
    try std.testing.expectError(error.WindowsExportNotFound, l.resolve(&m, 0, .{ .name = "Function" }, false, 0));
    try m.write(0x1280, "test.forward\x00");
    try std.testing.expectError(error.WindowsForwarderCycle, l.resolve(&m, 0, .{ .name = "forward" }, false, 0));
    try m.writeInt(0x11c0, 16, 4);
    try std.testing.expectError(error.InvalidWindowsExport, l.resolve(&m, 0, .{ .name = "function" }, false, 0));
    try m.writeInt(0x11c0, 16, 0);
    try m.writeInt(0x1180, 32, 0x3000);
    try std.testing.expectError(error.InvalidWindowsRva, l.resolve(&m, 0, .{ .ordinal = 7 }, false, 0));
    try m.writeInt(0x1114, 32, 65537);
    try std.testing.expectError(error.InvalidWindowsExport, l.resolve(&m, 0, .{ .ordinal = 7 }, false, 0));
}
test "PE function lookup validates complete live tables, bounds, gaps and unloads" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 0x3000, .{ .read = true, .write = true, .execute = true });
    var l = Linker{ .allocator = a };
    defer l.deinit();
    try l.modules.append(a, .{ .name = try a.dupe(u8, "test.dll"), .base = 0x1000, .size = 0x3000, .entry = 0, .imports = .{ .rva = 0, .size = 0 }, .exports = .{ .rva = 0, .size = 0 }, .exceptions = .{ .rva = 0x300, .size = 24 } });
    const records = [_]u64{ 0x100, 0x180, 0x500, 0x200, 0x280, 0x600 };
    for (records, 0..) |value, index| try m.writeInt(0x1300 + index * 4, 32, value);
    for ([_]u64{ 0x1100, 0x117f, 0x1200, 0x127f }, [_]u64{ 0x1300, 0x1300, 0x130c, 0x130c }) |pc, expected| {
        const found = (try l.lookupFunction(&m, pc)).?;
        try std.testing.expectEqual(@as(u64, 0x1000), found.image_base);
        try std.testing.expectEqual(expected, found.entry);
    }
    for ([_]u64{ 0, 0x1000, 0x10ff, 0x1180, 0x11ff, 0x1280, 0x3fff, 0x4000, std.math.maxInt(u64) }) |pc| try std.testing.expect(try l.lookupFunction(&m, pc) == null);
    l.modules.items[0].active = false;
    try std.testing.expect(try l.lookupFunction(&m, 0x1100) == null);
    l.modules.items[0].active = true;
    for ([_]struct { slot: usize, value: u64 }{
        .{ .slot = 0, .value = 0x180 }, .{ .slot = 1, .value = 0x3100 },
        .{ .slot = 2, .value = 0 },     .{ .slot = 2, .value = 0x501 },
        .{ .slot = 3, .value = 0x170 }, .{ .slot = 4, .value = 0x200 },
    }) |bad| {
        try m.writeInt(0x1300 + bad.slot * 4, 32, bad.value);
        try std.testing.expectError(error.InvalidWindowsFunctionTable, l.lookupFunction(&m, 0x1100));
        try m.writeInt(0x1300 + bad.slot * 4, 32, records[bad.slot]);
    }
    try m.writeInt(0x1314, 32, 0x3000);
    try std.testing.expectError(error.InvalidWindowsRva, l.lookupFunction(&m, 0x1100));
    try m.writeInt(0x1314, 32, 0x600);
    l.modules.items[0].exceptions.size = 23;
    try std.testing.expectError(error.InvalidWindowsFunctionTable, l.lookupFunction(&m, 0x1100));
    l.modules.items[0].exceptions.size = 12 * 65537;
    try std.testing.expectError(error.WindowsFunctionTableLimit, l.lookupFunction(&m, 0x1100));
    l.modules.items[0].exceptions.size = 24;
    l.modules.items[0].exceptions.rva = 0x301;
    try std.testing.expectError(error.InvalidWindowsFunctionTable, l.lookupFunction(&m, 0x1100));
    l.modules.items[0].exceptions.rva = 0x2ffc;
    try std.testing.expectError(error.InvalidWindowsRva, l.lookupFunction(&m, 0x1100));
    l.modules.items[0].exceptions.rva = 0x300;
    try m.protect(0x1000, 4096, .{ .read = true });
    try std.testing.expectError(error.PermissionDenied, l.lookupFunction(&m, 0x1100));
}
pub const Linker = struct {
    pub const Checkpoint = struct { active: u64, dependencies: [64]u64 };
    allocator: std.mem.Allocator,
    sysroot: ?[:0]const u8 = null,
    allow_files: bool = false,
    trace: bool = false,
    modules: std.ArrayList(Module) = .empty,
    initializers: std.ArrayList(usize) = .empty,
    pub fn deinit(l: *Linker) void {
        for (l.modules.items) |module| if (module.active) {
            l.allocator.free(module.name);
            if (module.path) |path| l.allocator.free(path);
        };
        l.modules.deinit(l.allocator);
        l.initializers.deinit(l.allocator);
    }
    pub fn find(l: Linker, name: []const u8) ?usize {
        for (l.modules.items, 0..) |module, index| if (module.active and std.ascii.eqlIgnoreCase(name, module.name)) return index;
        return null;
    }
    pub fn handle(l: Linker, base: u64) ?usize {
        for (l.modules.items, 0..) |module, index| if (module.active and module.base == base) return index;
        return null;
    }
    pub fn containing(l: Linker, address_value: u64) ?usize {
        for (l.modules.items, 0..) |module, index| if (module.active and address_value >= module.base and address_value - module.base < module.size) return index;
        return null;
    }
    pub fn lookupFunction(l: Linker, m: *Memory, pc: u64) !?struct { image_base: u64, entry: u64 } {
        const module = l.modules.items[l.containing(pc) orelse return null];
        const entry = try module.functionEntry(m, pc) orelse return null;
        return .{ .image_base = module.base, .entry = entry };
    }
    pub fn addMain(l: *Linker, m: *Memory, image: pe.Image, name: []const u8) !void {
        const leaf = name[(if (std.mem.findLastAny(u8, name, "/\\")) |position| position + 1 else 0)..];
        const index = try l.add(m, image, image.base, leaf, name);
        if (l.modules.items[index].tls) |tls| if (tls.callback_count != 0) try l.initializers.append(l.allocator, index);
        try l.bindImports(m, 0);
    }
    fn add(l: *Linker, m: *Memory, image: pe.Image, base: u64, name: []const u8, path: []const u8) !usize {
        var index = l.modules.items.len;
        for (l.modules.items, 0..) |module, slot| if (!module.active) {
            index = slot;
            break;
        };
        if (index >= 64) return error.WindowsModuleLimit;
        const owned = try l.allocator.dupe(u8, name);
        errdefer l.allocator.free(owned);
        const full_path = try host.absolutePath(l.allocator, path);
        errdefer l.allocator.free(full_path);
        const tls = try image.tls(m, base);
        const module = Module{ .name = owned, .path = full_path, .base = base, .size = image.image_size, .entry = if (image.is_dll and image.entry_rva != 0) base + image.entry_rva else 0, .imports = try image.directory(1), .exports = try image.directory(0), .exceptions = try image.directory(3), .tls = tls };
        if (index == l.modules.items.len) try l.modules.append(l.allocator, module) else l.modules.items[index] = module;
        return index;
    }
    pub fn load(l: *Linker, m: *Memory, name: []const u8) !usize {
        if (name.len == 0 or name.len > 255 or std.mem.findAny(u8, name, "/\\:") != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.UnsupportedWindowsModulePath;
        if (l.find(name)) |index| return index;
        const root = l.sysroot orelse return error.MissingSysroot;
        if (!l.allow_files) return error.FileAccessDenied;
        if (@popCount(l.active()) >= 64) return error.WindowsModuleLimit;
        const directory = host.c.opendir(root.ptr) orelse return switch (host.errno()) {
            host.c.EACCES, host.c.EPERM => error.FileAccessDenied,
            host.c.EMFILE, host.c.ENFILE => error.BinaryFileLimit,
            else => error.WindowsDLLNotFound,
        };
        defer _ = host.c.closedir(directory);
        var path: ?[:0]u8 = null;
        defer if (path) |value| l.allocator.free(value);
        while (host.c.readdir(directory)) |entry| {
            const candidate = std.mem.sliceTo(entry.*.d_name[0..], 0);
            if (std.ascii.eqlIgnoreCase(candidate, name)) {
                path = try std.fmt.allocPrintSentinel(l.allocator, "{s}/{s}", .{ root, candidate }, 0);
                break;
            }
        }
        const bytes = try host.readFile(l.allocator, path orelse return error.WindowsDLLNotFound);
        defer l.allocator.free(bytes);
        const image = try pe.parse(bytes);
        if (!image.is_dll) return error.ExpectedWindowsDLL;
        var base = image.base;
        if (!l.available(m, base, image.image_size)) {
            base = 0x300000000;
            while (!l.available(m, base, image.image_size)) {
                base = std.math.add(u64, base, 65536) catch return error.AddressOverflow;
                if (base > 0x800000000000 - @as(u64, image.image_size)) return error.MemoryLimit;
            }
        }
        try image.load(m, base);
        errdefer if (l.handle(base) == null) m.unmap(base, image.image_size) catch unreachable;
        const index = try l.add(m, image, base, name, path.?);
        // Publish the module before recursion so cyclic imports bind to the same image.
        try l.bindImports(m, index);
        if (image.entry_rva != 0 or (l.modules.items[index].tls != null and l.modules.items[index].tls.?.callback_count != 0)) try l.initializers.append(l.allocator, index);
        return index;
    }
    fn available(l: Linker, m: *Memory, base: u64, size: u32) bool {
        if (!m.available(base, size)) return false;
        for (l.modules.items) |module| if (module.active and base < module.base + module.size and module.base < base + size) return false;
        return true;
    }
    fn bindImports(l: *Linker, m: *Memory, index: usize) anyerror!void {
        const module = l.modules.items[index];
        if (module.imports.size == 0) return;
        var offset: u64 = 0;
        while (offset + 20 <= module.imports.size and offset < 65536) : (offset += 20) {
            const descriptor = try module.address(@as(u64, module.imports.rva) + offset, 20);
            const lookup = try m.readInt(descriptor, 32, .read);
            const name_rva = try m.readInt(descriptor + 12, 32, .read);
            const iat = try m.readInt(descriptor + 16, 32, .read);
            if (lookup == 0 and name_rva == 0 and iat == 0) return;
            const dll = try module.string(l.allocator, m, name_rva);
            defer l.allocator.free(dll);
            if (l.trace) try host.print(2, "Windows import DLL: {s}\n", .{dll});
            const target = if (Builtin.find(dll) != null) null else try l.load(m, dll);
            if (target) |slot| l.modules.items[index].dependencies |= bit(slot);
            const table = if (lookup == 0) iat else lookup;
            var end = false;
            for (0..4096) |n| {
                const item = try m.readInt(try module.address(table + n * 8, 8), 64, .read);
                if (item == 0) {
                    end = true;
                    break;
                }
                var owned: ?[:0]u8 = null;
                defer if (owned) |value| l.allocator.free(value);
                const symbol: Symbol = if (item >> 63 != 0) blk: {
                    if (item & 0x7fffffffffff0000 != 0) return error.InvalidWindowsImport;
                    break :blk .{ .ordinal = @truncate(item) };
                } else blk: {
                    if (item >= module.size or module.size - item < 3) return error.InvalidWindowsImport;
                    owned = try module.string(l.allocator, m, item + 2);
                    break :blk .{ .name = owned.? };
                };
                const address = if (target) |slot| try l.resolve(m, slot, symbol, true, 0) else try builtinSymbol(dll, symbol);
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, address, .little);
                try m.initialize(try module.address(iat + n * 8, 8), &bytes);
            }
            if (!end) return error.UnterminatedWindowsImports;
        }
        return error.UnterminatedWindowsImports;
    }
    fn builtinSymbol(dll: []const u8, symbol: Symbol) !u64 {
        return Builtin.find(dll).?.symbol(symbol) orelse {
            switch (symbol) {
                .name => |name| try host.print(2, "Unsupported Windows API: {s}!{s}\n", .{ dll, name }),
                .ordinal => |ordinal| try host.print(2, "Unsupported Windows API: {s}!#{d}\n", .{ dll, ordinal }),
            }
            if (symbol == .ordinal) return error.OrdinalImportsUnsupported;
            return error.UnsupportedWindowsImport;
        };
    }
    pub fn resolve(l: *Linker, m: *Memory, index: usize, symbol: Symbol, load_missing: bool, depth: u8) anyerror!u64 {
        if (depth >= 16) return error.WindowsForwarderCycle;
        const module = l.modules.items[index];
        const dir = module.exports;
        if (dir.size == 0) return error.WindowsExportNotFound;
        if (dir.size < 40) return error.InvalidWindowsExport;
        const header = try module.address(dir.rva, 40);
        const first = try m.readInt(header + 16, 32, .read);
        const functions = try m.readInt(header + 20, 32, .read);
        const names = try m.readInt(header + 24, 32, .read);
        if (functions > 65536 or names > 65536) return error.InvalidWindowsExport;
        const eat = try module.address(try m.readInt(header + 28, 32, .read), functions * 4);
        const pointers = try module.address(try m.readInt(header + 32, 32, .read), names * 4);
        const ordinals = try module.address(try m.readInt(header + 36, 32, .read), names * 2);
        try m.check(eat, @intCast(functions * 4), .read);
        try m.check(pointers, @intCast(names * 4), .read);
        try m.check(ordinals, @intCast(names * 2), .read);
        var ordinal: ?u64 = null;
        if (symbol == .ordinal) {
            if (symbol.ordinal >= first) ordinal = symbol.ordinal - first;
        } else {
            for (0..@intCast(names)) |n| {
                const name = try module.string(l.allocator, m, try m.readInt(pointers + n * 4, 32, .read));
                defer l.allocator.free(name);
                const slot = try m.readInt(ordinals + n * 2, 16, .read);
                if (slot >= functions) return error.InvalidWindowsExport;
                if (std.mem.eql(u8, name, symbol.name)) {
                    ordinal = slot;
                    break;
                }
            }
        }
        const slot = ordinal orelse return error.WindowsExportNotFound;
        if (slot >= functions) return error.WindowsExportNotFound;
        const target = try m.readInt(eat + slot * 4, 32, .read);
        if (target == 0) return error.WindowsExportNotFound;
        const address = try module.address(target, 1);
        if (target >= dir.rva and target - dir.rva < dir.size) {
            const forwarder = try m.cstring(l.allocator, address, @intCast(@min(4096, dir.size - (target - dir.rva))));
            defer l.allocator.free(forwarder);
            const dot = std.mem.findScalarLast(u8, forwarder, '.') orelse return error.InvalidWindowsForwarder;
            if (dot == 0 or dot + 1 == forwarder.len) return error.InvalidWindowsForwarder;
            const part = forwarder[0..dot];
            const dll = if (part.len >= 4 and std.ascii.eqlIgnoreCase(part[part.len - 4 ..], ".dll")) try l.allocator.dupe(u8, part) else try std.fmt.allocPrint(l.allocator, "{s}.dll", .{part});
            defer l.allocator.free(dll);
            const name = forwarder[dot + 1 ..];
            const next: Symbol = if (name[0] == '#') .{ .ordinal = std.fmt.parseInt(u16, name[1..], 10) catch return error.InvalidWindowsForwarder } else .{ .name = name };
            if (Builtin.find(dll) != null) return builtinSymbol(dll, next);
            const dependency = l.find(dll) orelse if (load_missing) try l.load(m, dll) else return error.LateWindowsDependencyUnsupported;
            l.modules.items[index].dependencies |= bit(dependency);
            return l.resolve(m, dependency, next, load_missing, depth + 1);
        }
        return address;
    }
    pub fn bit(index: usize) u64 {
        return @as(u64, 1) << @as(u6, @intCast(index));
    }
    pub fn active(l: Linker) u64 {
        var mask: u64 = 0;
        for (l.modules.items, 0..) |module, index| if (module.active) {
            mask |= bit(index);
        };
        return mask;
    }
    pub fn checkpoint(l: Linker) Checkpoint {
        var saved = Checkpoint{ .active = l.active(), .dependencies = @splat(0) };
        for (l.modules.items, 0..) |module, index| saved.dependencies[index] = module.dependencies;
        return saved;
    }
    pub fn unreachableModules(l: Linker) u64 {
        var reachable: u64 = 1; // The main executable owns its bound imports.
        for (l.modules.items, 0..) |module, index| if (module.active and module.references != 0) {
            reachable |= bit(index);
        };
        while (true) {
            const before = reachable;
            for (l.modules.items, 0..) |module, index| if (module.active and reachable & bit(index) != 0) {
                reachable |= module.dependencies;
            };
            if (reachable == before) return l.active() & ~reachable;
        }
    }
    pub fn detachOrder(l: Linker, mask: u64, output: *[64]usize) usize {
        var remaining = mask & l.active();
        var reach: [64]u64 = @splat(0);
        for (l.modules.items, 0..) |module, index| reach[index] = (module.dependencies & remaining) | bit(index);
        for (0..l.modules.items.len) |via| {
            for (0..l.modules.items.len) |index| if (reach[index] & bit(via) != 0) {
                reach[index] |= reach[via];
            };
        }
        var count: usize = 0;
        while (remaining != 0) {
            var selected: ?usize = null;
            for (0..l.initializers.items.len + l.modules.items.len) |n| {
                const index = if (n < l.initializers.items.len) l.initializers.items[l.initializers.items.len - n - 1] else n - l.initializers.items.len;
                if (remaining & bit(index) == 0) continue;
                var dependent = false;
                for (0..l.modules.items.len) |other| if (remaining & bit(other) != 0 and reach[other] & bit(index) != 0 and reach[index] & bit(other) == 0) {
                    dependent = true;
                    break;
                };
                if (!dependent) {
                    selected = index;
                    break;
                }
            }
            // A cycle detaches in reverse attachment order before its external dependencies.
            const index = selected.?;
            output[count] = index;
            count += 1;
            remaining &= ~bit(index);
        }
        return count;
    }
    pub fn remove(l: *Linker, m: *Memory, mask: u64) !void {
        for (l.modules.items, 0..) |*module, index| if (module.active and mask & bit(index) != 0) {
            try m.unmap(module.base, module.size);
            l.allocator.free(module.name);
            if (module.path) |path| l.allocator.free(path);
            module.active = false;
        };
        var index = l.initializers.items.len;
        while (index != 0) {
            index -= 1;
            if (mask & bit(l.initializers.items[index]) != 0) _ = l.initializers.orderedRemove(index);
        }
        for (l.modules.items) |*module| module.dependencies &= ~mask;
    }
    pub fn rollback(l: *Linker, m: *Memory, saved: Checkpoint) !void {
        try l.remove(m, l.active() & ~saved.active);
        for (l.modules.items, 0..) |*module, index| if (module.active) {
            module.dependencies = saved.dependencies[index];
        };
    }
};

fn pathAllocationProbe(allocator: std.mem.Allocator) !void {
    var m = Memory.init(std.testing.allocator);
    defer m.deinit();
    var l = Linker{ .allocator = allocator };
    defer l.deinit();
    const image = pe.Image{ .bytes = "", .optional = 0, .section_offset = 0, .section_count = 0, .base = 0x400000, .entry_rva = 0, .image_size = 4096, .header_size = 0, .directory_count = 0, .is_dll = true };
    try m.map(0x400000, 4096, .{ .read = true });
    const first = try l.add(&m, image, 0x400000, "é🚀.dll", "dir/../é🚀.dll");
    try std.testing.expect(std.fs.path.isAbsolutePosix(l.modules.items[first].path.?));
    try std.testing.expect(std.mem.endsWith(u8, l.modules.items[first].path.?, "/dir/../é🚀.dll"));
    const saved = l.checkpoint();
    try m.map(0x500000, 4096, .{ .read = true });
    _ = try l.add(&m, image, 0x500000, "late.dll", "/unit/late.dll");
    try l.rollback(&m, saved);
    try std.testing.expect(l.handle(0x500000) == null);
    try l.remove(&m, Linker.bit(first));
    try m.map(0x600000, 4096, .{ .read = true });
    const reused = try l.add(&m, image, 0x600000, "fresh.dll", "/unit/fresh.dll");
    try std.testing.expectEqual(first, reused);
    try std.testing.expectEqualStrings("/unit/fresh.dll", l.modules.items[reused].path.?);
}
test "DLL path ownership survives rollback, slot reuse and every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, pathAllocationProbe, .{});
}
test "DLL graph release collects cycles, retains shared roots and rolls back new edges" {
    const a = std.testing.allocator;
    var memory = Memory.init(a);
    defer memory.deinit();
    var linker = Linker{ .allocator = a };
    defer linker.deinit();
    for ([_][]const u8{ "main.exe", "startup.dll", "cycle-a.dll", "cycle-b.dll", "retained.dll" }, 0..) |name, index| {
        const base = 0x10000 + index * 0x10000;
        try memory.map(base, 4096, .{ .read = true });
        try linker.modules.append(a, .{ .name = try a.dupe(u8, name), .base = base, .size = 4096, .entry = 0, .imports = .{ .rva = 0, .size = 0 }, .exports = .{ .rva = 0, .size = 0 } });
    }
    linker.modules.items[0].dependencies = Linker.bit(1);
    linker.modules.items[2].dependencies = Linker.bit(1) | Linker.bit(3);
    linker.modules.items[3].dependencies = Linker.bit(2) | Linker.bit(4);
    linker.modules.items[2].references = 1;
    linker.modules.items[4].references = 1;
    try linker.initializers.appendSlice(a, &.{ 1, 3, 2, 4 });
    try std.testing.expectEqual(@as(u64, 0), linker.unreachableModules());
    linker.modules.items[2].references = 0;
    const mask = Linker.bit(2) | Linker.bit(3);
    try std.testing.expectEqual(mask, linker.unreachableModules());
    var order: [64]usize = undefined;
    try std.testing.expectEqual(@as(usize, 2), linker.detachOrder(mask, &order));
    try std.testing.expectEqualSlices(usize, &.{ 2, 3 }, order[0..2]);
    linker.modules.items[4].references = 0;
    try std.testing.expectEqual(@as(usize, 3), linker.detachOrder(mask | Linker.bit(4), &order));
    try std.testing.expectEqualSlices(usize, &.{ 2, 3, 4 }, order[0..3]);
    linker.modules.items[4].references = 1;
    try linker.remove(&memory, mask);
    try std.testing.expect(linker.find("cycle-a.dll") == null and linker.handle(0x40000) == null);
    try std.testing.expect(linker.find("startup.dll") != null and linker.find("retained.dll") != null);
    try std.testing.expect(memory.available(0x30000, 4096) and memory.available(0x40000, 4096));
    const saved = linker.checkpoint();
    const used = memory.used;
    try memory.map(0x60000, 4096, .{ .read = true });
    try linker.modules.append(a, .{ .name = try a.dupe(u8, "late.dll"), .base = 0x60000, .size = 4096, .entry = 0, .imports = .{ .rva = 0, .size = 0 }, .exports = .{ .rva = 0, .size = 0 } });
    linker.modules.items[4].dependencies = Linker.bit(5);
    try linker.initializers.append(a, 5);
    try std.testing.expectEqual(@as(usize, 2), linker.detachOrder(Linker.bit(4) | Linker.bit(5), &order));
    try std.testing.expectEqualSlices(usize, &.{ 4, 5 }, order[0..2]);
    try linker.rollback(&memory, saved);
    try std.testing.expectEqual(saved.active, linker.active());
    try std.testing.expectEqual(@as(u64, 0), linker.modules.items[4].dependencies);
    try std.testing.expectEqual(used, memory.used);
    try std.testing.expectEqual(@as(u64, 0), linker.unreachableModules());
}
