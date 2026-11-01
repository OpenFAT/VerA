//! The tables `vera --emit-exe` emits for a design, and the configuration its
//! executable root declares, in; the types every rt file reads them through out.
//! Cites: IEEE 1364-2005 §5.10.1 and §9.7.2 Table 9-1 (edges), §6.1, §9.6, §9.8.2,
//! §10, §18.
//!
//! Contents:
//! - `pub const one_slot: Design`
//! - `pub const two_slots: Design`
//! - `pub const wide_slot: Design`
//! - `pub const Design = struct`
//! - `pub const Dispatch`
//! - `pub const Sense = struct`
//! - `pub const Watcher = struct`
//! - `pub const settle_pc: u32`
//! - `pub const Edge = enum(u2)`
//! - `Edge.matches(self: Edge, before: Bit, after: Bit) bool`
//! - `pub const Error = error`
//! - `pub const Reach = packed struct(u8)`
//! - `Reach.all: Reach`
//! - `pub const overrides`
//! - `pub const activations`
//! - `pub const prebuilt`
//! - `pub const budget: u64`

const std = @import("std");
const digital = @import("../digital/root.zig");
const vcd = @import("../digital/vcd.zig");
const State = @import("State.zig");
const evcd = @import("evcd.zig");
const logic = @import("logic/root.zig");
const net = @import("net/root.zig");
const records = @import("records.zig");
const Bit = logic.Bit;
const testing = std.testing;

/// One 64-bit slot (word 0 of each plane), no process, net or node, and
/// one subroutine for `enter`.
pub const one_slot: Design = .{
    .v = &.{0},
    .x = &.{0},
    .slots = 1,
    .fan_start = &.{},
    .fan = &.{},
    .code_len = 0,
    .repeats = 0,
    .order = &.{},
    .subs = 1,
};

/// Two 64-bit slots holding 7 and 9.
pub const two_slots: Design = .{
    .v = &.{ 7, 9 },
    .x = &.{ 0, 0 },
    .slots = 2,
    .fan_start = &.{},
    .fan = &.{},
    .code_len = 0,
    .repeats = 0,
    .order = &.{},
    .subs = 1,
};

/// One 128-bit slot: words 0 and 1 of each plane.
pub const wide_slot: Design = .{
    .v = &.{ 0, 0 },
    .x = &.{ 0, 0 },
    .slots = 1,
    .fan_start = &.{},
    .fan = &.{},
    .code_len = 0,
    .repeats = 0,
    .order = &.{},
};

/// A native design's tables, emitted as constants.
pub const Design = struct {
    /// Every slot's initial value (`Run.values`), `logic.words(width)`
    /// words per plane, slot after slot.
    v: []const u64,
    x: []const u64,
    /// `Run.values.len`.
    slots: u32,
    /// `Run.waits.fan_start`/`Run.waits.fan`: the continuous drivers reading each slot.
    fan_start: []const u32,
    fan: []const u32,
    /// `Run.program.code.len`: the pc space `armed` covers.
    code_len: u32,
    /// `Run.rows.repeats.len`: one counter per lexical `repeat` (§9.6).
    repeats: u32,
    /// `Run.rows.pending`'s time-0 queue, as the pcs each process starts at.
    order: []const u32,
    /// Static schedule: per slot, the bits each combinational node reads
    /// (`comb[comb_start[slot]..comb_start[slot + 1]]`, ascending by word),
    /// nodes numbered in topological order, and how many nodes there are.
    comb_start: []const u32 = &.{},
    comb: []const Sense = &.{},
    nodes: u32 = 0,
    /// Static schedule: per slot, the event-control terms of the processes
    /// that wait at one fixed place (`watchers[watch_start[slot]..]`), and
    /// how many such processes there are.
    watch_start: []const u32 = &.{},
    watchers: []const Watcher = &.{},
    triggered: u32 = 0,
    /// `Run.rows.joins.len`: one counter per §9.8.2 `fork`.
    joins: u32 = 0,
    /// `Run.routines.rows.len`: the tasks and functions (§10).
    subs: u32 = 0,
    /// What a `$dumpvars` (§18) can select; null when the design has none.
    vcd: ?*const vcd.Catalog = null,
    /// §18.3 the `$dumpports` calls, each one file (`evcd.File`).
    ports_dump: []const evcd.File = &.{},
    /// §7.9 the nets resolved from their drivers, those drivers, and the
    /// §8 UDPs among them.
    nets: []const net.Net = &.{},
    drivers: []const net.Driver = &.{},
    udps: []const net.Udp = &.{},
    /// §7.6 the pass switches between those nets.
    trans: []const net.Tran = &.{},
    /// `--state=auto`: the plane words (first word, count) of the slots
    /// whose value at a time-step boundary nothing reads before a whole
    /// write (`src/codegen/digital/plan.zig` `stepLocal`), an x in which does not keep
    /// the design 4-state.
    dead: []const [2]u32 = &.{},
    /// §10.2.1 per slot (empty without `vera_activations`): 1 + the task
    /// whose out-of-line automatic activations each own this named event,
    /// else 0 (`waiters.eventContext`).
    act_events: []const u32 = &.{},
    /// §9.3.2 per slot, where its forced selects start in `State.parts`
    /// (`parts[part_start[slot]..part_start[slot + 1]]`); empty when no
    /// `force` names a select.
    part_start: []const u32 = &.{},
};

/// The dispatch of one phase: `Code(k).dispatch` of the emitted root.
pub const Dispatch = fn (*State, u32) Error!void;

/// Node `node` reads the bits `mask` of plane word `word`.
pub const Sense = struct {
    node: u32,
    word: u32,
    mask: u64,

    // Budget: one row per (slot, node) read, walked by `markReaders`.
    comptime {
        std.debug.assert(@sizeOf(Sense) == 16);
    }
};

/// One term of a triggered process: it resumes at `pc` on `edge`.
pub const Watcher = struct { proc: u32, pc: u32, edge: Edge };

/// What `State.next` returns for a settle event.
pub const settle_pc: u32 = std.math.maxInt(u32);

/// `waiters.Edge`: §5.10.1 an edge is a change toward 1 or away from 1.
pub const Edge = enum(u2) {
    any,
    posedge,
    negedge,

    // One load and a shift, no branch on the data: the wake loops test one
    // edge per waiter.
    /// Returns whether `before -> after` is an edge of this kind (§9.7.2 Table 9-1).
    pub fn matches(self: Edge, before: Bit, after: Bit) bool {
        const at = @as(u4, @backingInt(before)) << 2 | @backingInt(after);
        return edge_hits[@backingInt(self)] >> at & 1 != 0;
    }
};

/// `Rerun`: a `--state=auto` executable's 2-state phase met an x or z it
/// cannot hold (`Phase`); `auto` runs the design again, 4-state.
pub const Error = error{ Failed, Rerun } || std.mem.Allocator.Error || std.Io.Writer.Error;

/// What can observe a change of a slot, decided per slot by the
/// native emitter's planner (`src/codegen/digital/plan.zig`, `Plan.reach`):
/// a store's `wake` in `rt.State` does only these.
pub const Reach = packed struct(u8) {
    /// Continuous drivers the fan-out queues (§6.1).
    fan: bool = false,
    /// Combinational nodes (`Design.comb`).
    comb: bool = false,
    /// Triggered processes (`Design.watchers`).
    watch: bool = false,
    /// A process suspended at an event control (`State.watch`).
    terms: bool = false,
    /// The §17.1.3 monitor.
    mon: bool = false,
    /// A §18 dump.
    dump: bool = false,
    /// A §14.3.3 module path source (`net.pathSeen`).
    path: bool = false,
    _: u1 = 0,

    /// Everything: the reach of a store `plan` could not narrow.
    pub const all: Reach = .{ .fan = true, .comb = true, .watch = true, .terms = true, .mon = true, .dump = true, .path = true };
};

/// Some `assign` or `force` (§9.3) can hold a slot: the executable's root
/// declares `vera_overrides`.
pub const overrides = @hasDecl(@import("root"), "vera_overrides");

/// A §10.2.3 timed task reaches itself (`emit`'s `.call_timed`): the
/// executable's root declares `vera_activations`, and its processes carry
/// an activation (`State.ctx`).
pub const activations = @hasDecl(@import("root"), "vera_activations");

/// A contract device's root declares `vera_prebuilt_engine`: the engine's
/// design-independent half is linked prebuilt (`engine.zig`).
pub const prebuilt = @hasDecl(@import("root"), "vera_prebuilt_engine");

/// `root.max_events_per_tick`, or the executable's `vera --event-budget=`.
pub const budget: u64 = if (@hasDecl(@import("root"), "vera_event_budget")) @import("root").vera_event_budget else digital.max_events_per_tick;

/// Per `Edge`, bit `4 * before + after` (`Bit` encodings) is set when that
/// transition wakes it: every change and no change for `any`; for `posedge`
/// 0 -> x, z, 1 and x, z -> 1; for `negedge` 1 -> x, z, 0 and x, z -> 0.
const edge_hits = [3]u16{ 0xffff, 0x220e, 0x11d0 };

// ---- private ----

fn listed(rows: []const [2]Bit, before: Bit, after: Bit) bool {
    for (rows) |r| if (r[0] == before and r[1] == after) return true;
    return false;
}

test "Edge.matches is §9.7.2 Table 9-1" {
    const bits = [_]Bit{ .zero, .one, .z, .x };
    // Table 9-1's posedge transitions; negedge's are their mirror.
    const pos = [_][2]Bit{ .{ .zero, .x }, .{ .zero, .z }, .{ .zero, .one }, .{ .x, .one }, .{ .z, .one } };
    const neg = [_][2]Bit{ .{ .one, .x }, .{ .one, .z }, .{ .one, .zero }, .{ .x, .zero }, .{ .z, .zero } };
    for (bits) |before| for (bits) |after| {
        try testing.expect(Edge.any.matches(before, after));
        try testing.expectEqual(listed(&pos, before, after), Edge.posedge.matches(before, after));
        try testing.expectEqual(listed(&neg, before, after), Edge.negedge.matches(before, after));
    };
}
