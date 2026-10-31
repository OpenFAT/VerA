//! A change the transcript or a dump watches in, its monitor-region event
//! out: `$strobe`, `$monitor`, and the §18 value change dump.
//! Cites: IEEE 1364-2005 §17.1.2, §17.1.3, §18.1, §18.2.2.
//!
//! Contents:
//! - `pub const Dumps = struct`
//! - `pub fn strobe(self: *State, site: u32) Error!void`
//! - `pub fn monitor(self: *State, site: u32, slots: []const u32) Error!void`
//! - `pub fn monitorEnable(self: *State, on: bool) ?u32`
//! - `pub fn requestMonitor(self: *State) Error!void`
//! - `pub fn dumpFile(self: *State, name: anytype, comptime w: u32, call: []const u8) Error!void`
//! - `pub fn dumpVars(self: *State, levels: ?i64, targets: []const vcd.Target) Error!void`
//! - `pub fn dumpControl(self: *State, op: vcd.Op) Error!void`
//! - `pub fn dumpTick(self: *State) Error!void`
//! - `pub fn requestDump(self: *State) Error!void`
//! - `pub fn dumpFail(self: *State, e: vcd.Failure) Error`
//! - `pub fn dumpPlanes(self: *const State, v: vcd.Var, out: []u64) void`
//! - `pub fn fire(self: *State, slot: u32) void`
//! - `pub fn dumpSlot(self: *State, slot: u32) void`

const std = @import("std");
const evcd = @import("evcd.zig");
const assert = std.debug.assert;
const vcd = @import("../digital/vcd.zig");
const State = @import("State.zig");
const design = @import("design.zig");
const logic = @import("logic/root.zig");
const records = @import("records.zig");
const Error = design.Error;
const Reach = design.Reach;
const one_slot = design.one_slot;
const monitor_payload = records.monitor_payload;
const vcd_payload = records.vcd_payload;
const nba_payload = records.nba_payload;
const show_base = records.show_base;
const W = logic.W;
const two = logic.two;
const quietState = State.quietState;
const testing = std.testing;

/// A native run's §18 dumps: the VCD and the design's catalog of what
/// `$dumpvars` can select, the extended dump's files and what each has
/// written, and per slot whether a change is dumped. Outside a snapshot.
pub const Dumps = struct {
    /// §18 the dump, the design's catalog, and per slot (empty without a
    /// catalog) whether a change is dumped.
    vcd: vcd.Vcd = .{},
    catalog: ?*const vcd.Catalog,
    /// §18.3 the extended dump: the files, what each has written, and the
    /// time its `$dumpports` calls ran at. Outside a snapshot, as `dump` is.
    port_files: []const evcd.File = &.{},
    port_live: []evcd.Live = &.{},
    ports_at: ?u64 = null,
    dumped: []bool,
};

const no_limit = std.math.maxInt(u64);

/// §17.1.2 `$strobe` site `site`: its line at the end of this timestep.
pub fn strobe(self: *State, site: u32) Error!void {
    assert(site < nba_payload - show_base); // The payload stays inside its band.
    _ = self.sched.schedule(self.gpa, .monitor, show_base + site) catch |e| return self.schedFail(e);
}

/// §17.1.3 `$monitor` site `site`, watching `slots`, replaces the
/// standing monitor; its first line is at the end of this timestep.
pub fn monitor(self: *State, site: u32, slots: []const u32) Error!void {
    assert(site < nba_payload - show_base);
    assert(slots.len <= self.monitored.len);
    @memset(self.monitored, false);
    for (slots) |at| self.monitored[at] = true;
    self.mon_site = site;
    try self.requestMonitor();
}

/// `$monitoron` / `$monitoroff`: the site whose line `$monitoron`
/// prints now, whether or not anything changed.
pub fn monitorEnable(self: *State, on: bool) ?u32 {
    self.mon_on = on;
    assert(self.mon_on == on);
    return if (on) self.mon_site else null;
}

/// Queues the step's one §17.1.3 monitor event, unless it is queued, off,
/// or there is no standing monitor.
pub fn requestMonitor(self: *State) Error!void {
    if (self.mon_site == null or !self.mon_on or self.mon_pending) return;
    assert(!self.quiet or self.mon_site != null);
    self.mon_pending = true;
    _ = self.sched.schedule(self.gpa, .monitor, monitor_payload) catch |e| return self.schedFail(e);
}

/// §18.1 `$dumpfile` of the characters of a `w`-bit `name`; `call` is
/// the call as written.
pub fn dumpFile(self: *State, name: anytype, comptime w: u32, call: []const u8) Error!void {
    if (self.quiet) return;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    self.dumps.vcd.setFile(self.gpa, try State.chars(arena.allocator(), name, w), call) catch |e| return self.dumpFail(e);
}

/// §18.1.2 one `$dumpvars` (`vcd.Vcd.select`); its dump starts at the
/// end of the step.
pub fn dumpVars(self: *State, levels: ?i64, targets: []const vcd.Target) Error!void {
    if (self.quiet) return;
    self.dumps.vcd.select(self.gpa, self.sched.now, 0, std.math.lossyCast(u32, levels orelse 0), targets) catch |e| return self.dumpFail(e);
    try self.requestDump();
}

/// `$dumpoff`, `$dumpon`, `$dumpall`, `$dumpflush` (`vcd.Vcd.control`).
pub fn dumpControl(self: *State, op: vcd.Op) Error!void {
    if (self.quiet) return;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    self.dumps.vcd.control(arena.allocator(), self.io, self.dumps.catalog.?, self, self.sched.now, op) catch |e| return self.dumpFail(e);
}

/// The §18 dump's end-of-step event: every dumped change of the step written.
pub fn dumpTick(self: *State) Error!void {
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    self.dumps.vcd.tick(self.gpa, arena.allocator(), self.io, self.dumps.catalog.?, self, self.sched.now) catch |e| return self.dumpFail(e);
}

/// One dump event per step however many dumped values moved.
pub fn requestDump(self: *State) Error!void {
    if (self.dumps.vcd.pending or self.quiet) return;
    assert(self.dumps.catalog != null); // Only a dumped slot asks.
    self.dumps.vcd.pending = true;
    _ = self.sched.schedule(self.gpa, .monitor, vcd_payload) catch |e| return self.schedFail(e);
}

/// A dump failure as `error.OutOfMemory`, or the E1100 refusal its message names.
pub fn dumpFail(self: *State, e: vcd.Failure) Error {
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.DumpvarsTime => self.fail(vcd.message(error.DumpvarsTime), .{}),
        inline else => |f| self.fail(comptime vcd.message(f), .{self.dumps.vcd.name}),
    };
}

/// `vcd.Vcd`'s value source: catalog variable `v`'s planes.
pub fn dumpPlanes(self: *const State, v: vcd.Var, out: []u64) void {
    assert(out.len % 2 == 0);
    assert(v.off + out.len / 2 <= self.v.len);
    const n = out.len / 2;
    @memcpy(out[0..n], self.v[v.off..][0..n]);
    if (two) @memset(out[n..], 0) else @memcpy(out[n..], self.x[v.off..][0..n]);
}

/// §18.2.2 named event `slot` was triggered (`vcd.Vcd.fire`); the
/// `wake` that follows asks for the dump event.
pub fn fire(self: *State, slot: u32) void {
    if (self.quiet) return;
    if (self.dumps.dumped.len != 0 and self.dumps.dumped[slot]) self.dumps.vcd.fire(self.dumps.catalog.?, slot);
}

/// `vcd.Vcd`'s hook: a change of `slot` asks for a dump event.
pub fn dumpSlot(self: *State, slot: u32) void {
    assert(slot < self.dumps.dumped.len);
    self.dumps.dumped[slot] = true;
}

test "§17.1.3 one $monitor line per time step however many watched stores" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &one_slot, -9);
    try s.monitor(2, &.{0});
    try testing.expectEqual(@as(?u32, show_base + 2), try s.next(no_limit));
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
    for ([_]u64{ 1, 0, 1 }) |v| try s.put(Reach.all, 0, 0, W{ .v = v, .x = 0 }, @as(u64, 1));
    try testing.expectEqual(@as(?u32, show_base + 2), try s.next(no_limit));
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
    // `$monitoroff`: no line; `$monitoron` names the site to print now.
    try testing.expectEqual(@as(?u32, null), s.monitorEnable(false));
    try s.put(Reach.all, 0, 0, W{ .v = 0, .x = 0 }, @as(u64, 1));
    try testing.expectEqual(@as(?u32, null), try s.next(no_limit));
    try testing.expectEqual(@as(?u32, 2), s.monitorEnable(true));
}
