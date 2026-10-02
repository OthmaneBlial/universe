const std = @import("std");
const host = @import("host.zig");
const Memory = @import("memory.zig").Memory;
const State = @import("cpu/state.zig").State;
const Pipe = @import("linux_pipe.zig").Pipe;
fn negative(n: u16) u64 {
    return @bitCast(-@as(i64, n));
}
pub const Metadata = struct {
    clear_tid: u64 = 0,
    signal_mask: u64 = 0,
    saved_signal_mask: ?u64 = null,
    poll_deadline: ?u64 = null,
    alternate_stack: [24]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};
const Wait = struct { address: ?u64 = null, private: bool = false, mask: u32 = 0xffffffff, deadline: ?u64 = null, realtime: bool = false, expiry_result: u64 = negative(110), retry: bool = false, call: ?State = null, restartable: bool = false, remaining: u64 = 0, pipe: ?struct { value: *Pipe, writing: bool, minimum: usize } = null };
const Thread = struct {
    id: u32,
    context: State,
    data: Metadata,
    status: enum { ready, blocked, exited } = .ready,
    wait: ?Wait = null,
    fn clearWait(thread: *Thread) void {
        if (thread.wait) |wait| if (wait.pipe) |pipe| pipe.value.release();
        thread.wait = null;
    }
};
pub const Threads = struct {
    records: std.ArrayList(Thread) = .empty,
    initial: Metadata = .{},
    initial_id: u32 = 1,
    current: usize = 0,
    next_id: u32 = 2,
    quantum_start: u64 = 0,
    yield_pending: bool = false,
    pub fn deinit(t: *Threads, a: std.mem.Allocator) void {
        for (t.records.items) |*thread| thread.clearWait();
        t.records.deinit(a);
    }
    pub fn metadata(t: *Threads) *Metadata {
        return if (t.records.items.len == 0) &t.initial else &t.records.items[t.current].data;
    }
    pub fn id(t: Threads) u32 {
        return if (t.records.items.len == 0) t.initial_id else t.records.items[t.current].id;
    }
    pub fn contains(t: Threads, value: u64) bool {
        if (value == 0) return true;
        if (t.records.items.len == 0) return value == t.initial_id;
        for (t.records.items) |thread| if (thread.id == value and thread.status != .exited) return true;
        return false;
    }
    fn ensureMain(t: *Threads, a: std.mem.Allocator, s: State) !void {
        if (t.records.items.len == 0) try t.records.append(a, .{ .id = t.initial_id, .context = s, .data = t.initial });
    }
    pub fn waitPipe(t: *Threads, a: std.mem.Allocator, s: State, p: *Pipe, writing: bool, minimum: usize) !void {
        try t.ensureMain(a, s);
        p.retain();
        t.records.items[t.current].wait = .{ .retry = true, .call = s, .restartable = true, .pipe = .{ .value = p, .writing = writing, .minimum = minimum } };
        t.records.items[t.current].status = .blocked;
        t.yield_pending = true;
    }
    pub fn retryAfter(t: *Threads, a: std.mem.Allocator, s: State, deadline: u64, restartable: bool) !void {
        try t.ensureMain(a, s);
        t.records.items[t.current].wait = .{ .retry = true, .deadline = deadline, .call = s, .restartable = restartable };
        t.records.items[t.current].status = .blocked;
        t.yield_pending = true;
    }
    pub fn waitSignal(t: *Threads, a: std.mem.Allocator, s: State, mask: u64) !void {
        try t.ensureMain(a, s);
        t.metadata().saved_signal_mask = t.metadata().signal_mask;
        t.metadata().signal_mask = mask;
        t.records.items[t.current].wait = .{ .expiry_result = negative(4) };
        t.records.items[t.current].status = .blocked;
        t.yield_pending = true;
    }
    pub fn signalCandidate(t: *Threads, pending: u64) ?usize {
        if (t.records.items.len == 0) return if (pending & ~t.initial.signal_mask != 0) 0 else null;
        for (0..t.records.items.len) |offset| {
            const index = (t.current + offset) % t.records.items.len;
            const thread = &t.records.items[index];
            if (thread.status != .exited and pending & ~thread.data.signal_mask != 0) return index;
        }
        return null;
    }
    pub fn signalMetadata(t: *Threads, index: usize) *Metadata {
        return if (t.records.items.len == 0) &t.initial else &t.records.items[index].data;
    }
    pub fn signalContext(t: *Threads, s: State, index: usize, m: *Memory, restart: bool) !State {
        var next = if (index == t.current) s else t.records.items[index].context;
        if (t.records.items.len != 0) if (t.records.items[index].wait) |wait| {
            if (wait.call) |call| {
                next = call;
                if (restart and wait.restartable) {
                    next.pc -= if (next.architecture == .x86_64) @as(u64, 2) else 4;
                } else {
                    next.set(if (next.architecture == .riscv64) 10 else 0, negative(4));
                    if (wait.remaining != 0) {
                        const remaining = (wait.deadline orelse 0) -| try now(wait.realtime);
                        var bytes: [16]u8 = undefined;
                        std.mem.writeInt(u64, bytes[0..8], remaining / 1_000_000_000, .little);
                        std.mem.writeInt(u64, bytes[8..16], remaining % 1_000_000_000, .little);
                        try m.write(wait.remaining, &bytes);
                    }
                }
            }
        };
        next.instructions = s.instructions;
        return next;
    }
    pub fn activateSignal(t: *Threads, s: *State, index: usize, next: State) void {
        if (t.records.items.len != 0) {
            t.records.items[t.current].context = s.*;
            t.current = index;
            t.records.items[index].clearWait();
            t.records.items[index].status = .ready;
        }
        s.* = next;
        t.quantum_start = s.instructions;
        t.yield_pending = false;
        t.metadata().saved_signal_mask = null;
    }
    pub fn clone(t: *Threads, a: std.mem.Allocator, s: State, m: *Memory, args: [6]u64) !u64 {
        const flags = args[0];
        const required: u64 = 0x10f00; // VM, FS, FILES, SIGHAND, THREAD.
        const optional: u64 = 0x40000 | 0x80000 | 0x100000 | 0x200000 | 0x400000 | 0x1000000;
        if (flags & 0x800 != 0 and flags & 0x100 == 0 or flags & 0x10000 != 0 and flags & 0x800 == 0) return negative(22);
        if (flags & required != required or flags & ~(required | optional) != 0) return negative(38);
        const child_tid = if (s.architecture == .x86_64) args[3] else args[4];
        const tls = if (s.architecture == .x86_64) args[4] else args[3];
        if (args[1] == 0) return negative(22); // Shared-memory threads need a separate stack in this profile.
        if (s.architecture == .arm64 and args[1] & 15 != 0) return negative(22);
        if (flags & 0x80000 != 0 and s.architecture == .x86_64 and tls >= 0x800000000000) return negative(1);
        var slot = t.records.items.len;
        for (t.records.items, 0..) |thread, index| if (thread.status == .exited) {
            slot = index;
            break;
        };
        // ponytail: 64 live guest threads, sequential CPU execution; expand only for a real failing workload.
        if (slot >= 64 or t.next_id > std.math.maxInt(i32)) return negative(11);
        // No TID stores or runnable children until all outputs and allocations are ready.
        if (flags & 0x100000 != 0) try m.prepareWrite(args[2], 4);
        if (flags & 0x1000000 != 0) try m.prepareWrite(child_tid, 4);
        try t.records.ensureUnusedCapacity(a, if (t.records.items.len == 0) 2 else if (slot == t.records.items.len) 1 else 0);
        try t.ensureMain(a, s);
        if (slot == 0 and t.records.items.len == 1) slot = 1;
        var child = s;
        child.set(if (s.architecture == .riscv64) 10 else 0, 0);
        child.set(child.stackRegister(), args[1]);
        child.exclusive = null;
        if (flags & 0x80000 != 0) switch (s.architecture) {
            .x86_64 => child.fs_base = tls,
            .arm64 => child.set(33, tls),
            .riscv64 => child.set(4, tls),
        };
        const tid = t.next_id;
        if (flags & 0x100000 != 0) try m.writeInt(args[2], 32, tid);
        if (flags & 0x1000000 != 0) try m.writeInt(child_tid, 32, tid);
        const thread = Thread{ .id = tid, .context = child, .data = .{ .clear_tid = if (flags & 0x200000 != 0) child_tid else 0, .signal_mask = t.metadata().signal_mask } };
        if (slot == t.records.items.len) t.records.appendAssumeCapacity(thread) else t.records.items[slot] = thread;
        t.next_id += 1;
        t.yield_pending = true;
        return tid;
    }
    pub fn wake(t: *Threads, address: u64, private: bool, mask: u32, count: u32) u64 {
        var result: u64 = 0;
        for (t.records.items) |*thread| if (thread.wait) |wait| {
            if (result == count) break;
            if (thread.status == .blocked and wait.address == address and wait.private == private and wait.mask & mask != 0) {
                thread.status = .ready;
                thread.clearWait();
                thread.context.set(if (thread.context.architecture == .riscv64) 10 else 0, 0);
                result += 1;
            }
        };
        return result;
    }
    fn now(realtime: bool) !u64 {
        if (!realtime) return host.nowNs();
        const stamp = try host.clock(.realtime);
        if (stamp.sec < 0) return error.HostClockFailed;
        return std.math.add(u64, std.math.mul(u64, @intCast(stamp.sec), 1_000_000_000) catch return error.HostClockFailed, @intCast(stamp.nsec)) catch error.HostClockFailed;
    }
    fn timespecNs(m: *Memory, address: u64) !?u64 {
        try m.check(address, 16, .read);
        const seconds: i64 = @bitCast(try m.readInt(address, 64, .read));
        const nanos = try m.readInt(address + 8, 64, .read);
        if (seconds < 0 or nanos >= 1_000_000_000) return null;
        return @intCast(@min(@as(u128, @intCast(seconds)) * 1_000_000_000 + nanos, std.math.maxInt(i64)));
    }
    pub fn sleep(t: *Threads, a: std.mem.Allocator, s: State, m: *Memory, clock: u32, flags: u32, request: u64, remaining: u64) !u64 {
        if (clock == 3 or clock == 10 or clock > 11) return negative(22);
        if (clock > 1) return negative(95);
        const duration = (try timespecNs(m, request)) orelse return negative(22);
        const realtime = clock == 0 and flags & 1 != 0;
        const current = try now(realtime);
        const deadline = if (flags & 1 != 0) duration else @min(current +| duration, std.math.maxInt(i64));
        if (deadline <= current) {
            t.yield_pending = true;
            return 0;
        }
        try t.ensureMain(a, s);
        t.records.items[t.current].wait = .{ .deadline = deadline, .realtime = realtime, .expiry_result = 0, .call = s, .remaining = if (flags & 1 == 0) remaining else 0 };
        t.records.items[t.current].status = .blocked;
        t.yield_pending = true;
        return 0; // Visible after expiry; a caught signal supplies EINTR and remaining time.
    }
    pub fn futex(t: *Threads, a: std.mem.Allocator, s: State, m: *Memory, args: [6]u64) !u64 {
        const flags: u32 = @truncate(args[1]);
        const op = flags & ~@as(u32, 128 | 256);
        if (op != 0 and op != 1 and op != 9 and op != 10) return negative(38);
        if (flags & 256 != 0 and op != 9) return negative(38);
        const mask: u32 = if (op == 9 or op == 10) @truncate(args[5]) else 0xffffffff;
        if (args[0] & 3 != 0 or mask == 0) return negative(22);
        try m.check(args[0], 4, .read);
        if (op == 1 or op == 10) {
            const count: i32 = @bitCast(@as(u32, @truncate(args[2])));
            if (count < 0) return negative(22);
            return t.wake(args[0], flags & 128 != 0, mask, @intCast(count));
        }
        // Linux's timed wait uses a restart block: a caught handler returns EINTR even with SA_RESTART.
        var wait = Wait{ .address = args[0], .private = flags & 128 != 0, .mask = mask, .realtime = flags & 256 != 0, .call = s, .restartable = args[3] == 0 };
        if (args[3] != 0) {
            const duration = (try timespecNs(m, args[3])) orelse return negative(22);
            wait.deadline = if (op == 0) @min((try now(false)) +| duration, std.math.maxInt(i64)) else duration;
        }
        if (try m.readInt(args[0], 32, .read) != @as(u32, @truncate(args[2]))) return negative(11);
        if (wait.deadline) |deadline| if (try now(wait.realtime) >= deadline) return negative(110);
        try t.ensureMain(a, s);
        t.records.items[t.current].wait = wait;
        t.records.items[t.current].status = .blocked;
        t.yield_pending = true;
        return 0; // Result becomes visible only after a real wake or expiry.
    }
    pub fn blocked(t: Threads) bool {
        return t.records.items.len != 0 and t.records.items[t.current].status != .ready;
    }
    pub fn exit(t: *Threads, m: *Memory) bool {
        const address = t.metadata().clear_tid;
        if (address != 0) {
            m.writeInt(address, 32, 0) catch {};
            _ = t.wake(address, false, 0xffffffff, 1);
        }
        if (t.records.items.len == 0) return true;
        t.records.items[t.current].status = .exited;
        t.records.items[t.current].clearWait();
        t.yield_pending = true;
        for (t.records.items) |thread| if (thread.status != .exited) return false;
        return true;
    }
    pub fn exitGroup(t: *Threads, m: *Memory) void {
        if (t.records.items.len == 0) {
            _ = t.exit(m);
            return;
        }
        for (t.records.items) |*thread| {
            if (thread.status == .exited) continue;
            if (thread.data.clear_tid != 0) m.writeInt(thread.data.clear_tid, 32, 0) catch {};
            thread.clearWait();
            thread.status = .exited;
        }
    }
    pub fn schedule(t: *Threads, s: *State) !bool {
        if (t.records.items.len == 0) return true;
        if (!t.yield_pending and !t.blocked() and s.instructions - t.quantum_start < 4096) return true;
        t.records.items[t.current].context = s.*;
        for (t.records.items) |*thread| if (thread.wait) |wait| {
            const pipe_ready = if (wait.pipe) |p| p.value.ready(p.writing, p.minimum) else false;
            const expired = if (wait.deadline) |deadline| try now(wait.realtime) >= deadline else false;
            if (pipe_ready or expired) {
                thread.clearWait();
                thread.status = .ready;
                if (!wait.retry) thread.context.set(if (s.architecture == .riscv64) 10 else 0, wait.expiry_result);
                t.yield_pending = true;
            }
        };
        t.yield_pending = false;
        const instructions = s.instructions;
        for (1..t.records.items.len + 1) |offset_value| {
            const index = (t.current + offset_value) % t.records.items.len;
            if (t.records.items[index].status != .ready) continue;
            t.current = index;
            s.* = t.records.items[index].context;
            s.instructions = instructions;
            s.exclusive = null;
            t.quantum_start = instructions;
            return true;
        }
        return false;
    }
};

test "Linux clone keeps thread CPU/TLS/masks separate and clears TIDs on thread exit" {
    const a = std.testing.allocator;
    for ([_]@import("loader/elf.zig").Architecture{ .x86_64, .riscv64, .arm64 }) |arch| {
        var m = Memory.init(a);
        defer m.deinit();
        try m.map(0x1000, 4096, .{ .read = true, .write = true });
        var t = Threads{};
        defer t.deinit(a);
        t.metadata().signal_mask = 4;
        var s = State{ .architecture = arch, .pc = 0x4567, .instructions = 99 };
        s.set(s.stackRegister(), 0x2000);
        const args: [6]u64 = if (arch == .x86_64) .{ 0x13d0f00, 0x1800, 0x1100, 0x1104, 0x1200, 0 } else .{ 0x13d0f00, 0x1800, 0x1100, 0x1200, 0x1104, 0 };
        try std.testing.expectEqual(@as(u64, 2), try t.clone(a, s, &m, args));
        try std.testing.expectEqual(@as(u64, 2), try m.readInt(0x1100, 32, .read));
        try std.testing.expectEqual(@as(u64, 2), try m.readInt(0x1104, 32, .read));
        try std.testing.expect(try t.schedule(&s));
        try std.testing.expectEqual(@as(u32, 2), t.id());
        try std.testing.expectEqual(@as(u64, 0x1800), s.get(s.stackRegister()));
        try std.testing.expectEqual(@as(u64, 0x1200), if (arch == .x86_64) s.fs_base else s.get(if (arch == .riscv64) 4 else 33));
        try std.testing.expectEqual(@as(u64, 4), t.metadata().signal_mask);
        t.metadata().signal_mask = 8;
        s.instructions = 120;
        try std.testing.expect(!t.exit(&m));
        try std.testing.expect(try t.schedule(&s));
        try std.testing.expectEqual(@as(u32, 1), t.id());
        try std.testing.expectEqual(@as(u64, 120), s.instructions);
        try std.testing.expectEqual(@as(u64, 4), t.metadata().signal_mask);
        try std.testing.expectEqual(@as(u64, 0), try m.readInt(0x1104, 32, .read));
        try std.testing.expect(t.exit(&m));
    }
}

test "Linux futex waits really block, separate keys and masks, wake selected threads and expire" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    var t = Threads{};
    defer t.deinit(a);
    var s = State{ .architecture = .x86_64, .pc = 0x5000, .instructions = 10 };
    try std.testing.expectEqual(@as(u64, 2), try t.clone(a, s, &m, .{ 0x10f00, 0x1800, 0, 0, 0, 0 }));
    try std.testing.expect(try t.schedule(&s));
    try std.testing.expectEqual(@as(u64, 0), try t.futex(a, s, &m, .{ 0x1100, 137, 0, 0, 0, 2 }));
    try std.testing.expect(t.blocked());
    try std.testing.expect(try t.schedule(&s));
    try std.testing.expectEqual(@as(u32, 1), t.id());
    try std.testing.expectEqual(@as(u64, 0), t.wake(0x1100, false, 2, 1));
    try std.testing.expectEqual(@as(u64, 0), t.wake(0x1100, true, 1, 1));
    try std.testing.expectEqual(@as(u64, 1), t.wake(0x1100, true, 2, 1));
    t.yield_pending = true;
    try std.testing.expect(try t.schedule(&s));
    try std.testing.expectEqual(@as(u32, 2), t.id());
    try std.testing.expectEqual(@as(u64, 0), s.get(0));
    try std.testing.expectEqual(negative(11), try t.futex(a, s, &m, .{ 0x1100, 0, 1, 0, 0, 0 }));
    // A queued timeout changes the saved syscall result, including for the current thread.
    t.records.items[t.current].wait = .{ .address = 0x1100, .private = false, .mask = 1, .deadline = 0 };
    t.records.items[t.current].status = .blocked;
    s.set(0, 0);
    try std.testing.expect(try t.schedule(&s));
    t.yield_pending = true;
    try std.testing.expect(try t.schedule(&s));
    try std.testing.expectEqual(negative(110), s.get(0));
    t.exitGroup(&m);
    for (t.records.items) |thread| try std.testing.expect(thread.status == .exited);
}

test "Linux clone output faults and allocation failures do not publish a TID or child" {
    const a = std.testing.allocator;
    var m = Memory.init(a);
    defer m.deinit();
    try m.map(0x1000, 4096, .{ .read = true, .write = true });
    try m.writeInt(0x1100, 32, 0xaaaaaaaa);
    try m.writeInt(0x1104, 32, 0xbbbbbbbb);
    var t = Threads{};
    defer t.deinit(a);
    const s = State{ .architecture = .x86_64, .pc = 0x5000 };
    const args: [6]u64 = .{ 0x1110f00, 0x1800, 0x1100, 0x1104, 0, 0 };
    var bad = args;
    bad[3] = 0x2000;
    try std.testing.expectError(error.UnmappedMemory, t.clone(a, s, &m, bad));
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, t.clone(failing.allocator(), s, &m, args));
    try std.testing.expectEqual(@as(usize, 0), t.records.items.len);
    try std.testing.expectEqual(@as(u32, 2), t.next_id);
    try std.testing.expectEqual(@as(u64, 0xaaaaaaaa), try m.readInt(0x1100, 32, .read));
    try std.testing.expectEqual(@as(u64, 0xbbbbbbbb), try m.readInt(0x1104, 32, .read));
    try std.testing.expectEqual(@as(u64, 2), try t.clone(a, s, &m, args));
}

test "caught signals select unmasked threads, preserve restart arguments and interrupt sleeps with remaining time" {
    const a = std.testing.allocator;
    for ([_]@import("loader/elf.zig").Architecture{ .x86_64, .arm64, .riscv64 }) |arch| {
        var m = Memory.init(a);
        defer m.deinit();
        try m.map(0x1000, 4096, .{ .read = true, .write = true });
        var t = Threads{};
        defer t.deinit(a);
        t.initial.signal_mask = 4;
        var s = State{ .architecture = arch, .pc = 0x5004, .instructions = 9 };
        s.set(archResult(arch), 0x1234);
        try std.testing.expectEqual(@as(u64, 0), try t.futex(a, s, &m, .{ 0x1100, 0, 0, 0, 0, 0 }));
        try std.testing.expect(t.signalCandidate(4) == null);
        const index = t.signalCandidate(16).?;
        const restarted = try t.signalContext(s, index, &m, true);
        try std.testing.expectEqual(@as(u64, if (arch == .x86_64) 0x5002 else 0x5000), restarted.pc);
        try std.testing.expectEqual(@as(u64, 0x1234), restarted.get(archResult(arch)));
        const interrupted = try t.signalContext(s, index, &m, false);
        try std.testing.expectEqual(@as(u64, 0x5004), interrupted.pc);
        try std.testing.expectEqual(negative(4), interrupted.get(archResult(arch)));
        try std.testing.expect(t.blocked()); // Preparing delivery does not consume the wait.
        t.activateSignal(&s, index, interrupted);
        try std.testing.expect(!t.blocked());
        try t.waitSignal(a, s, 16);
        try std.testing.expectEqual(@as(?u64, 4), t.metadata().saved_signal_mask);
        try std.testing.expectEqual(@as(u64, 16), t.metadata().signal_mask);
        t.activateSignal(&s, t.signalCandidate(4).?, s);
        try std.testing.expect(t.metadata().saved_signal_mask == null);
        try m.writeInt(0x1100, 64, 1);
        try m.writeInt(0x1108, 64, 0);
        try std.testing.expectEqual(@as(u64, 0), try t.sleep(a, s, &m, 1, 0, 0x1100, 0x1200));
        const slept = try t.signalContext(s, t.current, &m, true);
        try std.testing.expectEqual(s.pc, slept.pc); // Sleep never restarts with SA_RESTART.
        try std.testing.expectEqual(negative(4), slept.get(archResult(arch)));
        try std.testing.expect(try m.readInt(0x1200, 64, .read) <= 1);
        try std.testing.expect(try m.readInt(0x1208, 64, .read) < 1_000_000_000);
        t.activateSignal(&s, t.current, slept);
        try std.testing.expectEqual(@as(u64, 0), try t.sleep(a, s, &m, 1, 0, 0x1100, 0x3000));
        try std.testing.expectError(error.UnmappedMemory, t.signalContext(s, t.current, &m, true));
        try std.testing.expect(t.blocked());
        t.activateSignal(&s, t.current, slept);
        try m.writeInt(0x1110, 32, 0);
        try std.testing.expectEqual(@as(u64, 0), try t.futex(a, s, &m, .{ 0x1110, 128, 0, 0x1100, 0, 0 }));
        const timed = try t.signalContext(s, t.current, &m, true);
        try std.testing.expectEqual(s.pc, timed.pc);
        try std.testing.expectEqual(negative(4), timed.get(archResult(arch))); // A handler must not reset a relative timeout.
    }
}
fn archResult(arch: @import("loader/elf.zig").Architecture) u6 {
    return if (arch == .riscv64) 10 else 0;
}
