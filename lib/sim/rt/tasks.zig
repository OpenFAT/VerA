//! The §17 system tasks and functions that read the clock, the queues, the
//! random state or a file in; their values or effects out.
//! Cites: IEEE 1364-2005 §9.7.1 (delays), §17.2.9 ($readmem), §17.4, §17.5,
//! §17.6, §17.7, §17.9; VAMS §9.10 ($abstime).
//!
//! Contents:
//! - `pub fn units(self: *const State, scale: Scale) u64`
//! - `pub fn realtime(self: *const State, scale: Scale) f64`
//! - `pub fn abstime(self: *const State, finest: i32) f64`
//! - `pub fn queue(self: *State, op: system.QueueOp, id: ?i64, in1: ?i64, in2: ?i64, scale: Scale) Error!system.QueueResult`
//! - `pub fn queueFull(self: *const State, id: ?i64) @TypeOf(system.queueIsFull(undefined, null))`
//! - `pub fn pla(self: *State, p: system.Pla, off: u32, nrows: u32, comptime rw: u32, in: anytype, comptime iw: u32, cell: u32, comptime ow: u32) Error!void`
//! - `pub fn dist(self: *State, f: system.Dist, seed: i32, a: i32, b: i32) ?system.Draw`
//! - `pub fn readmem(self: *State, source: []const u8, name: []const u8, radix: fmt.Radix, width: u32, slot: u32, off: u32, low: i64, high: i64, given: u2, first: ?i64, last: ?i64) Error!void`
//! - `pub fn random(self: *State) i32`
//! - `pub fn realTicks(self: *State, r: f64, scale: Scale) Error!u64`
//! - `pub fn ticks(self: *State, a: W, signed: bool, scale: Scale) Error!u64`
//! - `pub fn stopRun(self: *State, verbose: bool, file: []const u8, byte: u32) Error!void`
//! - `pub fn finish(self: *State, verbose: bool, file: []const u8, byte: u32) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const fmt = @import("kernels").fmt;
const Int = @import("kernels").Integer;
const digital = @import("../digital/root.zig");
const display = @import("../digital/display.zig");
const system = @import("../digital/system.zig");
const Scale = @import("../time.zig").Scale;
const State = @import("State.zig");
const design = @import("design.zig");
const logic = @import("logic/root.zig");
const net = @import("net/root.zig");
const records = @import("records.zig");
const Error = design.Error;
const one_slot = design.one_slot;
const repeatCount = @import("planes.zig").repeatCount;
const W = logic.W;
const two = logic.two;
const quietState = State.quietState;
const testing = std.testing;

/// §17.7.1 `$time`: now, in the invoking module's unit.
pub fn units(self: *const State, scale: Scale) u64 {
    return scale.unitsAt(self.sched.now);
}

/// §17.7.2 `$realtime`: now, in the invoking module's unit, unrounded.
pub fn realtime(self: *const State, scale: Scale) f64 {
    return scale.realAt(self.sched.now);
}

/// VAMS §9.10 `$abstime`: now in seconds, the tick being 10^`finest` s.
pub fn abstime(self: *const State, finest: i32) f64 {
    return @import("../time.zig").secondsAt(self.sched.now, finest);
}

/// §17.6 queue task `op` (`system.queueStep`), at now in `scale`'s unit.
pub fn queue(self: *State, op: system.QueueOp, id: ?i64, in1: ?i64, in2: ?i64, scale: Scale) Error!system.QueueResult {
    return system.queueStep(&self.queues, self.gpa, op, id, in1, in2, self.units(scale));
}

/// §17.6.5 `$q_full` of queue `id`.
pub fn queueFull(self: *const State, id: ?i64) @TypeOf(system.queueIsFull(undefined, null)) {
    return system.queueIsFull(&self.queues, id);
}

/// §17.5 `system.plaEval` of the `nrows` `rw`-bit rows from word `off`
/// over the `iw`-bit `in`, into the `ow`-bit cell at word `cell`.
pub fn pla(self: *State, p: system.Pla, off: u32, nrows: u32, comptime rw: u32, in: anytype, comptime iw: u32, cell: u32, comptime ow: u32) Error!void {
    comptime assert(rw >= 1);
    comptime assert(ow >= 1);
    assert(off + nrows * logic.words(rw) <= self.v.len);
    assert(cell + logic.words(ow) <= self.v.len);
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const n = comptime logic.words(rw);
    const rows = try a.alloc(Int.Literal, nrows);
    for (rows, 0..) |*row, k| {
        const row_planes = try a.alloc(u64, 2 * n);
        @memcpy(row_planes[0..n], self.v[off + k * n ..][0..n]);
        @memcpy(row_planes[n..], self.x[off + k * n ..][0..n]);
        if (two) @memset(row_planes[n..], 0);
        row.* = State.literal(row_planes, rw, false);
    }
    var ib = logic.planesOf(in);
    const out = @import("../digital/net.zig").filled(a, ow, false, .x) catch return error.OutOfMemory;
    system.plaEval(p, rows, State.literal(&ib, iw, false), out);
    const on = comptime logic.words(ow);
    for (self.v[cell..][0..on], self.x[cell..][0..on], out.values(), out.unknowns()) |*v, *x, ov, ox| {
        if (self.two and ox != 0) return error.Rerun;
        // `--two-state`: an output no row decides is 0.
        v.* = if (two) ov & ~ox else ov;
        x.* = if (two) 0 else ox;
    }
}

/// §17.9 `system.dist`, with the interpreter's W1151 warning where the
/// listing prints one.
pub fn dist(self: *State, f: system.Dist, seed: i32, a: i32, b: i32) ?system.Draw {
    return system.dist(f, seed, a, b) orelse {
        self.warn("W1151", system.dist_warning, .{});
        return null;
    };
}

/// §17.2.9 `$readmemb`/`$readmemh` of the file `name` beside `source`
/// (`display.MemLoad`) into the array whose lowest address is `slot`,
/// at word `off`, each element `width` bits. `given` is how many of the
/// start and finish addresses `first`/`last` the call has (null: x or z).
pub fn readmem(self: *State, source: []const u8, name: []const u8, radix: fmt.Radix, width: u32, slot: u32, off: u32, low: i64, high: i64, given: u2, first: ?i64, last: ?i64) Error!void {
    assert(width >= 1);
    assert(low <= high);
    if (self.quiet) return;
    if ((given >= 1 and first == null) or (given == 2 and last == null)) return self.warn("W1157", display.unknown_bound ++ display.load_ended, .{});
    // `display.readMemory`'s rules: a bound outside the memory loads nothing.
    if (given >= 1) if (first) |f| if (f < low or f > high) return self.warn("W1157", display.outside_memory ++ display.load_ended, .{ "start", f, low, high });
    if (given == 2) if (last) |l| if (l < low or l > high) return self.warn("W1157", display.outside_memory ++ display.load_ended, .{ "finish", l, low, high });
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const file = display.sideFile(self.io, a, source, name) catch return self.warn("W1157", display.cannot_read ++ display.load_ended, .{std.zig.fmtString(name)});
    defer file.close(self.io);
    var buf: [4096]u8 = undefined;
    var in = file.reader(self.io, &buf);
    var load: display.MemLoad = .init(&in.interface, radix, width, low, high, given, first, last);
    const n = (width + 63) / 64;
    const m = try a.alloc(u64, n);
    @memset(m, std.math.maxInt(u64));
    m[n - 1] = @as(u64, std.math.maxInt(u64)) >> @intCast(64 * n - width);
    while (load.next(a) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // An error message, the load terminated, and the run goes on.
        error.AddressOutOfRange => return self.warn("W1157", display.MemLoad.out_of_range_text ++ display.load_ended, .{ load.at, load.range_low, load.range_high }),
        else => return self.warn("W1157", "{s}" ++ display.load_ended, .{display.MemLoad.message(e)}),
    }) |w| {
        const v = w.value.values();
        const x = w.value.unknowns();
        // `--two-state`: an x or z digit loads 0.
        if (two) for (v, x) |*bv, *bx| {
            bv.* &= ~bx.*;
            bx.* = 0;
        };
        assert(w.index <= high - low);
        try self.store(slot + w.index, off + w.index * n, v, x, m);
    }
    if (load.mismatch()) |mm| self.warn("W1150", display.MemLoad.mismatch_text, .{ mm.found, mm.expected });
    if (load.outside) |o| self.warn("W1156", display.MemLoad.outside_text, .{ o, low, high });
}

/// §17.9.1 a seedless `$random`.
pub fn random(self: *State) i32 {
    // `$random` has no bounds to refuse: the draw always exists.
    const d = system.dist(.random, self.random_seed, 0, 0).?;
    self.random_seed = d.seed;
    return d.value;
}

/// `exec.delayOf` of a real delay (§9.7.1), rounded to the precision.
pub fn realTicks(self: *State, r: f64, scale: Scale) Error!u64 {
    return scale.realDelay(r) catch |e| self.fail("digital delay cannot be represented: {t}", .{e});
}

/// `exec.delayOf` of an integral delay (§9.7.1): x/z reads as 0.
pub fn ticks(self: *State, a: W, signed: bool, scale: Scale) Error!u64 {
    if (a.x != 0) return 0;
    return (if (signed) scale.signedDelay(@bitCast(a.v)) else scale.unsignedDelay(a.v)) catch |e|
        self.fail("digital delay cannot be represented: {t}", .{e});
}

/// §17.4.2 `$stop`: a batch run has nothing to suspend into, so it ends
/// as `$finish` does (VD-070), reporting on stderr, not the design's stdout.
pub fn stopRun(self: *State, verbose: bool, file: []const u8, byte: u32) Error!void {
    if (verbose) std.debug.print("$stop at tick {d}, {s} byte {d}\n", .{ self.sched.now, file, byte });
    return self.finish(false, file, byte);
}

/// §17.4.1 `$finish`: end the run after this process step.
pub fn finish(self: *State, verbose: bool, file: []const u8, byte: u32) Error!void {
    if (verbose) try self.out.print("$finish at tick {d}, {s} byte {d}\n", .{ self.sched.now, file, byte });
    // `exec`'s `.finish`: the rest of this time step runs, the dump's
    // tick included.
    self.sched.finishStep();
    assert(self.sched.finishing);
}

test "§9.7.1 delays: an x is no delay, a negative integer an unsigned time; §9.6 repeat counts" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &one_slot, -9);
    // 1 ns units at 1 ps precision: 1000 ticks per unit.
    const scale = try Scale.init(.ns, .ps, .ps);
    try testing.expectEqual(@as(u64, 0), try s.ticks(.{ .v = 5, .x = 1 }, false, scale));
    try testing.expectEqual(@as(u64, 5000), try s.ticks(.{ .v = 5, .x = 0 }, false, scale));
    // -1 is 2^64 - 1 units, which no tick count holds.
    try testing.expectError(error.Failed, s.ticks(.{ .v = std.math.maxInt(u64), .x = 0 }, true, scale));
    try testing.expectEqual(@as(u64, 1500), try s.realTicks(1.5, scale));
    // A negative real wraps as its integer would (`Scale.realDelay`).
    try testing.expectEqual(@as(u64, 0) -% 1000, try s.realTicks(-1.0, scale));
    try testing.expectEqual(@as(u64, 0), repeatCount(W{ .v = 3, .x = 2 }, 8, false));
    try testing.expectEqual(@as(u64, 255), repeatCount(W{ .v = 255, .x = 0 }, 8, false));
    try testing.expectEqual(@as(u64, 0), repeatCount(W{ .v = 255, .x = 0 }, 8, true));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), repeatCount(W{ .v = std.math.maxInt(u64), .x = 0 }, 64, false));
    const Wide2 = logic.Wide(2);
    try testing.expectEqual(@as(u64, 2), repeatCount(Wide2{ .v = .{ 2, 0 }, .x = .{ 0, 0 } }, 70, false));
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), repeatCount(Wide2{ .v = .{ 0, 1 }, .x = .{ 0, 0 } }, 70, false));
    try testing.expectEqual(@as(u64, 0), repeatCount(Wide2{ .v = .{ 1, 1 << 5 }, .x = .{ 0, 0 } }, 70, true));
    try testing.expectEqual(@as(u64, 0), repeatCount(Wide2{ .v = .{ 2, 0 }, .x = .{ 0, 1 } }, 70, false));
}
