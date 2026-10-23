//! The elaborated nets and driver rows of a digital `Run` -> connect-module
//! driver access. At elaboration, every inserted segment a connect module
//! drives splits into its drivers' net and its receivers' net (`segregate`);
//! at run time, the values of `$driver_count` … `$receiver_count` and the
//! wake-ups of `driver_update`. VAMS §7.9, §9.22.1-§9.22.6, §9.23.1-§9.23.4,
//! Annex D.3; IEEE 1364-2005 §7.10 (the strength scale §9.22.4 encodes).

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const root = @import("root.zig");
const Run = root.Run;
const Error = root.Error;
const compile = @import("compile.zig");
const waiters = @import("waiters.zig");
const evaluate = @import("evaluate.zig");
const elab = @import("elab.zig");
const Driver = @import("net.zig").Driver;
const Signal = @import("net.zig").Signal;
const filled = @import("net.zig").filled;

/// The engine's §9.22 driver-access state (`Run.drv`), written by
/// `segregate` during elaboration and by `arm` once the slots are final.
pub const State = struct {
    /// §9.22.6 the receivers' net of a split segment, keyed by its drivers'
    /// net. A segment no connect module drives is not split and is absent.
    receivers: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    /// The nets some `@(driver_update …)` waits on, until `arm` reads them.
    watched: std.ArrayList(u32) = .empty,
    /// A slot whose write updates a driver of a watched net.
    sources: std.ArrayList(Source) = .empty,
};

/// `slot` feeds a driver of the net whose slot is `net`. A `reg` source (an
/// output port declared as a variable) IS the driver, so every assignment to
/// it is an update; an expression driver's operand updates it only by
/// changing, which is when a continuous assignment re-evaluates (§6.1).
const Source = struct { slot: u32, net: u32, reg: bool };

/// The waiter slot of `driver_update` on the net whose slot is `net`: one no
/// variable owns, like `registerMonitor`'s (which count down from the top).
/// Distinct from every slot, and per net, only while slots stay below 2^31.
pub fn key(net: u32) u32 {
    return (1 << 31) | net;
}

// ---- elaboration (§9.22.6, §7.9) --------------------------------------------

/// §7.9 "the drivers and receivers of connect modules shall be oppositely
/// segregated; i.e., the connect module drivers shall be grouped with the
/// ordinary module receivers and the ordinary module drivers shall be grouped
/// with the connect module receivers", and §9.22.6: with `assign d = out;` in
/// the connect module "the digital port of the connect module will drive the
/// receivers with a value determined in the connect module", while `d` itself
/// still reads the drivers. Without such an assignment "the default is
/// equivalent of assign d_receivers = d_drivers", which an unsplit net is.
///
/// So a segment an inserted connect module drives becomes two nets: the
/// segment keeps the ordinary drivers (and the connect module's reads), and a
/// fresh net takes the connect module's drivers and every ordinary INPUT port
/// bound to the segment. An ordinary `inout` port stays on the drivers' net.
pub fn segregate(r: *Run, e: *elab.Elab) Error!void {
    // ponytail: §7.9's Figure 7-11 bidirectional split is the upgrade for an
    // ordinary `inout` port.
    // VAMS §7.8.5.1 a primitive's terminal reads the segment by its name in the
    // parent, so a primitive's input is one more receiver. Re-pointed after the
    // loop, which finds each segment by that name.
    const GateRead = struct { scope: u32, str: Ast.StrId, net: u32 };
    var gate_reads: std.ArrayList(GateRead) = .empty;
    for (r.inserts, r.insert_segs) |row, seg| {
        const parent = scopeAt(r, row.path) orelse continue;
        // A continuous lower port minted no segment: nothing digital to split.
        const slot = r.names.get(.{ .scope = parent, .str = r.file.exprs.strOf(seg) }) orelse continue;
        const d = r.net_of.get(slot) orelse continue;
        const is_gate = if (r.file.strings.find(row.inst)) |n| r.instances.get(.{ .scope = parent, .str = n }) == null else true;
        if (is_gate) try gate_reads.append(r.arena, .{ .scope = parent, .str = r.file.exprs.strOf(seg), .net = d });
        if (r.drv.receivers.contains(d)) continue; // a merged group's later port
        var driven = false;
        for (e.wires.items) |w| driven = driven or (w.net == d and isConnect(r, w.scope));
        if (!driven) continue;
        const kind = e.nets.items[d].kind;
        const width = e.nets.items[d].resolved.width;
        const rx = try elab.mintNet(r, e, kind, width, e.values.items[slot].signed, .none, e.nets.items[d].tok);
        for (e.wires.items) |*w| if (w.net == d and isConnect(r, w.scope)) {
            w.net = rx;
        };
        const rx_slot = e.nets.items[rx].slot;
        var it = r.names.iterator();
        while (it.next()) |entry| if (entry.value_ptr.* == slot and ordinaryInput(r, entry.key_ptr.scope, entry.key_ptr.str)) {
            entry.value_ptr.* = rx_slot;
        };
        try r.drv.receivers.put(r.arena, d, rx);
    }
    for (gate_reads.items) |g| if (r.drv.receivers.get(g.net)) |rx| {
        r.names.getPtr(.{ .scope = g.scope, .str = g.str }).?.* = e.nets.items[rx].slot;
    };
}

/// The instance scope at a `Mixed.Insert` path (`a.b.`, empty at the root).
fn scopeAt(r: *const Run, path: []const u8) ?u32 {
    var scope: u32 = 0;
    var parts = std.mem.tokenizeScalar(u8, path, '.');
    while (parts.next()) |part| {
        const name = r.file.strings.find(part) orelse return null;
        scope = r.instances.get(.{ .scope = scope, .str = name }) orelse return null;
    }
    return scope;
}

/// §9.22 ¶3: is `scope` inside a connect module, whose drivers "the driver
/// access functions … only access drivers found in ordinary modules" skip?
fn isConnect(r: *const Run, scope: u32) bool {
    return r.file.modules[r.scope_info.items[r.instanceOf(scope)].def].is_connect;
}

/// §9.22.1 the `i`'th ordinary driver of `net`, "arbitrarily numbered from 0
/// to N-1" (here in declaration order), or its count N when `i` is null.
fn ordinary(r: *const Run, net: u32, i: ?u64) union(enum) { count: u32, driver: ?u32 } {
    var n: u32 = 0;
    for (r.netDrivers(net)) |d| {
        if (isConnect(r, r.drivers[d].scope)) continue;
        if (i) |want| if (n == want) return .{ .driver = d };
        n += 1;
    }
    return if (i == null) .{ .count = n } else .{ .driver = null };
}

// ---- driver_update (§9.22.5) --------------------------------------------------

/// `@(driver_update x)`: `x` names a net, and its drivers are watched once the
/// slot space is final (`arm`).
pub fn checkUpdate(r: *Run, e: Ast.ExprId) Error!void {
    const signal = r.file.exprs.lhs(e);
    const net = r.net_of.get(try r.scalarSlot(signal)) orelse return r.exprFail(signal, "§9.22.5: driver_update watches the drivers of a net");
    if (std.mem.findScalar(u32, r.drv.watched.items, net) != null) return;
    try r.drv.watched.append(r.arena, net);
}

/// Watch every slot whose write updates a driver of a watched net. The
/// connect module's own drivers were moved to the receivers' net by
/// `segregate`, so both halves are read.
pub fn arm(r: *Run) Error!void {
    for (r.drv.watched.items) |net| {
        const rx = r.drv.receivers.get(net);
        const halves = [2]u32{ net, rx orelse net };
        for (halves[0 .. @as(usize, 1) + @intFromBool(rx != null)]) |half| {
            for (r.netDrivers(half)) |di| {
                const dr = r.drivers[di];
                // `driver_update` does not fire for a connect module's own
                // driver (the `assign d = out;` of §9.22.6): §9.22.6 separates
                // that driver, which "will drive the receivers", from "the
                // drivers of the connect module digital port", the ordinary
                // drivers §9.22 ¶3's access functions see (the user's
                // 2026-09-24 reading of §9.22.6). Fixture m04_12 pins it.
                if (isConnect(r, dr.scope)) continue;
                if (dr.source == .bridge) {
                    try watch(r, dr.source.bridge.src, r.nets[net].slot, true);
                } else for (dr.sensitivity) |s| try watch(r, s, r.nets[net].slot, false);
            }
        }
    }
}

fn watch(r: *Run, slot: u32, net: u32, reg: bool) Error!void {
    r.watch[slot].insert(.driver_update);
    try r.drv.sources.append(r.arena, .{ .slot = slot, .net = net, .reg = reg });
}

/// `waiters.store` wrote `slot`. §9.22.5: "an update is defined as the addition
/// of a new pending value to the driver. This is true whether or not there is
/// a change in the resolved value of the signal", so a `reg` driver updates on
/// every assignment, changed or not. A nonblocking one already updated when it
/// was scheduled (`scheduled`), so its maturing in the NBA region is not a
/// second update.
pub fn stored(r: *Run, slot: u32, changed: bool) Error!void {
    if (!r.watch[slot].contains(.driver_update)) return;
    const maturing = switch (r.scheduler.phase) {
        .dispatch => |region| region == .nba,
        .idle, .stopped => false,
    };
    for (r.drv.sources.items) |s| if (s.slot == slot and (if (s.reg) !maturing else changed))
        try waiters.wake(r, key(s.net), .x, .x);
}

/// `exec.enqueue` scheduled a write of `slot`: a pending value added to a
/// `reg` driver (§9.22.5, and what §9.23 then reads back).
pub fn scheduled(r: *Run, slot: u32) Error!void {
    if (!r.watch[slot].contains(.driver_update)) return;
    for (r.drv.sources.items) |s| if (s.slot == slot and s.reg) try waiters.wake(r, key(s.net), .x, .x);
}

// ---- the access functions (§9.22.1 to §9.22.4, §9.23.1 to §9.23.4) ----------------

/// The driver access functions, one per VAMS §9.22.1-§9.22.4 / §9.23.1-
/// §9.23.4 `$driver_*` name (`of` maps the `compile.SysFn` row).
const Fn = enum { count, receiver_count, state, strength, delay, next_state, next_strength, type };

/// The system function a `compile.SysFn` driver row stands for.
pub fn of(f: compile.SysFn) ?Fn {
    return switch (f) {
        .driver_count => .count,
        .receiver_count => .receiver_count,
        .driver_state => .state,
        .driver_strength => .strength,
        .driver_delay => .delay,
        .driver_next_state => .next_state,
        .driver_next_strength => .next_strength,
        .driver_type => .type,
        else => null, // else: not a §9.22/§9.23 function
    };
}

/// Syntax 9-17 … 9-24: `(signal_name)` for the two counts, `(signal_name,
/// driver_index)` for the rest. The counts, strengths and type are integers;
/// the states are "0, 1, x, or z"; the delay is "a real number".
pub fn infer(r: *Run, e: Ast.ExprId, f: Fn) Error!compile.Type {
    const args = r.file.exprs.args(e);
    const want: usize = if (f == .count or f == .receiver_count) 1 else 2;
    if (args.len != want or args[0] == .none or (want == 2 and args[1] == .none))
        return r.exprFail(e, "§9.22: a driver access function takes (signal_name) or (signal_name, driver_index)");
    if (!isConnect(r, r.scope))
        return r.failWith(.E0818, r.file.exprs.mainTok(e), "§9.22: \"Driver access functions can only be called from connect modules.\" This is a `module`", .{});
    const slot = try r.scalarSlot(args[0]);
    if (r.net_of.get(slot) == null) return r.exprFail(args[0], "§9.22: signal_name names a net");
    // §9.22.3 a driver's state is one of "0, 1, x, or z": one bit.
    if (r.values[slot].width != 1) return r.exprFail(args[0], "§9.22.3: signal_name is a scalar net; a driver's state is one bit");
    if (want == 2) {
        try compile.checkExpr(r, args[1]);
        if (compile.typeOf(r, args[1]).real) return r.exprFail(args[1], "§9.22.3: driver_index is an integer");
    }
    return switch (f) {
        .state, .next_state => .{ .width = 1, .signed = false },
        .delay => compile.real_type,
        .count, .receiver_count, .strength, .next_strength, .type => .{ .width = 32, .signed = true },
    };
}

/// The integral functions' values.
pub fn eval(r: *Run, a: std.mem.Allocator, e: Ast.ExprId, f: Fn) Error!Int.Literal {
    const args = r.file.exprs.args(e);
    const slot = try r.scalarSlot(args[0]);
    const net = r.net_of.get(slot).?;
    const n: u32 = switch (f) {
        .count => ordinary(r, net, null).count,
        // §9.22.2 "the total number of ordinary receivers": the ordinary
        // input ports on the receivers' net (the segment itself, unsplit).
        .receiver_count => receivers(r, r.nets[r.drv.receivers.get(net) orelse net].slot),
        .state, .strength, .next_state, .next_strength, .type => blk: {
            const i = (try evaluate.eval(r, a, args[1], 0)).asInt();
            const d = if (i != null and i.? >= 0) ordinary(r, net, @intCast(i.?)).driver else null;
            // §9.22.3 bounds the index to 0..N-1 and says no more; an index
            // outside it names no driver, and reads x.
            const dr = r.drivers[d orelse return filled(a, if (f == .state or f == .next_state) 1 else 32, f != .state and f != .next_state, .x)];
            const now = dr.current.bit(0);
            const next = (try pending(r, a, d.?)) orelse Pend{ .bit = now, .time = 0 };
            break :blk switch (f) {
                .state => return filled(a, 1, false, now),
                .next_state => return filled(a, 1, false, next.bit),
                .strength => strengthBits(Signal.of(now, dr.s0, dr.s1)),
                .next_strength => level(Signal.of(next.bit, dr.s0, dr.s1)),
                .type => typeBits(r, dr),
                .count, .receiver_count, .delay => unreachable, // the outer arms
            };
        },
        .delay => unreachable, // real-valued: `evalReal`
    };
    const v = try filled(a, 32, true, .zero);
    v.values()[0] = n;
    return v;
}

/// §9.23.1 `$driver_delay`: "the delay, from current simulation time, after
/// which the pending state or strength becomes active. If there is no pending
/// value on a signal, it returns the value minus one (-1.0)", in the calling
/// module's `timescale units.
pub fn evalReal(r: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!f64 {
    const args = r.file.exprs.args(e);
    const net = r.net_of.get(try r.scalarSlot(args[0])).?;
    const i = (try evaluate.eval(r, a, args[1], 0)).asInt() orelse return -1.0;
    if (i < 0) return -1.0;
    const d = ordinary(r, net, @intCast(i)).driver orelse return -1.0;
    const p = (try pending(r, a, d)) orelse return -1.0;
    const scale = r.timeOf(r.scope).scale;
    return scale.realAt(p.time) - scale.realAt(r.scheduler.now);
}

const Pend = struct { bit: Int.Bit, time: u64 };

/// The earliest value scheduled onto driver `dr` and not yet active: its own
/// A.6.1 delayed transition, or, for a `reg` driver, a scheduled write of the
/// variable it carries (§9.23's "a non-blocking assign with delays").
fn pending(r: *Run, a: std.mem.Allocator, di: u32) Error!?Pend {
    const dr = r.drivers[di];
    var live: std.ArrayList(@import("../scheduler.zig").Live) = .empty;
    try r.scheduler.pendingPayloads(a, &live);
    var best: ?Pend = null;
    for (live.items) |ev| {
        // `root.analog_payload` indexes no row.
        if (ev.payload >= r.pending.items.len) continue;
        const bit: Int.Bit = switch (r.pending.items[ev.payload].item) {
            .drive => |at| if (at == di) r.transitions.items[dr.transition].target.bit(0) else continue,
            .write => |w| switch (dr.source) {
                .bridge => |b| if (w.target == b.src and w.sel == null) w.value.bit(b.src_lo) else continue,
                .expr, .gate, .udp, .mos, .pull => continue,
            },
            else => continue, // else: only a drive or a write carries a driver's next value
        };
        if (best == null or ev.time < best.?.time) best = .{ .bit = bit, .time = ev.time };
    }
    return best;
}

/// §9.22.2: ordinary input ports bound to the net at `slot`.
fn receivers(r: *const Run, slot: u32) u32 {
    var n: u32 = 0;
    var it = r.names.iterator();
    while (it.next()) |entry| n += @intFromBool(entry.value_ptr.* == slot and ordinaryInput(r, entry.key_ptr.scope, entry.key_ptr.str));
    return n;
}

/// Whether name `str` in `scope` is an input port of an ordinary module
/// instance (not a connect module's, not a block's local).
fn ordinaryInput(r: *const Run, scope: u32, str: Ast.StrId) bool {
    if (isConnect(r, scope)) return false;
    const info = r.scope_info.items[scope];
    if (info.lexical) return false;
    for (r.file.modules[info.def].ports) |p| if (p.name == str) return p.direction == .input;
    return false;
}

/// §9.22.4 "bits 5-3 for strength0 and bits 2-0 for strength1", each a level of
/// Figure 9-3 (Su 7 … Sm 1, HiZ 0). "If the value returned is 0 or 1, strength0
/// returns the high-end of the strength range and strength1 returns the
/// low-end": a 0 or a 1 spans one side of the scale, and the two fields are its
/// strongest and weakest level. An x spans both sides, and Figure 9-3 gives
/// each field its own side.
fn strengthBits(s: Signal) u32 {
    if (s.lo < 0 and s.hi > 0) return @as(u32, @abs(s.lo)) << 3 | @abs(s.hi);
    return @as(u32, @max(@abs(s.lo), @abs(s.hi))) << 3 | @min(@abs(s.lo), @abs(s.hi));
}

/// §9.23.3 "an integer between 0 and 7": the strength of the one state.
fn level(s: Signal) u32 {
    return @max(@abs(s.lo), @abs(s.hi));
}

/// §9.23.4 and Annex D.3's masks. `DRIVER_KERNEL` marks the §19.9 pull a
/// kernel adds for `unconnected_drive`.
fn typeBits(r: *const Run, dr: Driver) u32 {
    var t: u32 = 0;
    if (dr.delay.present) t |= 1; // DRIVER_DELAYED
    t |= switch (dr.source) {
        .gate, .mos => 2, // DRIVER_GATE
        .udp => 4, // DRIVER_UDP
        .expr => 8,
        .bridge => 16,
        .pull => 256,
    };
    t |= switch (r.nets[dr.net].kind) {
        .wor, .trior => 512,
        .wand, .triand => 1024,
        // No other net type has a Table 7-4 wired-logic bit.
        .wire, .tri, .tri0, .tri1, .trireg, .uwire, .supply0, .supply1, .wreal => 0,
    };
    return t;
}

test "§9.22.3 a driver's state is one bit: a vector signal_name is refused, not read at bit 0" {
    const diag = @import("diag");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var out = std.Io.Writer.Allocating.init(arena.allocator());
    try std.testing.expectError(error.DigitalFailed, root.elaborate(arena.allocator(),
        \\connectmodule c(d); input [3:0] d; initial $display("%b", $driver_state(d, 0)); endmodule
        \\module top; wire [3:0] w; assign w = 4'b1010; c cm(.d(w)); endmodule
        \\
    , .{ .mixed = .{ .top = "top", .timescales = &.{} } }, &bag, &out.writer));
    var messages = std.Io.Writer.Allocating.init(arena.allocator());
    try diag.render(&bag, &messages.writer, .{});
    try std.testing.expect(std.mem.find(u8, messages.written(), "signal_name is a scalar net") != null);
}

test strengthBits {
    // VAMS §9.22.4: bits 5-3 strength0, bits 2-0 strength1. A 0 or 1 puts
    // the high end of its range in strength0's field and the low end in
    // strength1's; a 0 or 1 at one strength has that level in both.
    try std.testing.expectEqual(@as(u32, 6 << 3 | 6), strengthBits(.of(.one, .strong, .strong)));
    try std.testing.expectEqual(@as(u32, 6 << 3 | 5), strengthBits(.{ .lo = 5, .hi = 6 }));
    try std.testing.expectEqual(@as(u32, 7 << 3 | 3), strengthBits(.{ .lo = -7, .hi = -3 }));
    // An x spans both sides: each field its own side's level (Figure 9-3).
    try std.testing.expectEqual(@as(u32, 3 << 3 | 5), strengthBits(.{ .lo = -3, .hi = 5 }));
    // A z drives nothing: HiZ in both.
    try std.testing.expectEqual(@as(u32, 0), strengthBits(.{}));
}

test level {
    // §9.23.3 "an integer between 0 and 7": the strength of the one state.
    try std.testing.expectEqual(@as(u32, 7), level(.of(.one, .supply, .supply)));
    try std.testing.expectEqual(@as(u32, 5), level(.of(.zero, .pull, .pull)));
    try std.testing.expectEqual(@as(u32, 0), level(.{}));
}

test of {
    // One `compile.SysFn` row per §9.22/§9.23 function, and none for the rest.
    try std.testing.expectEqual(@as(?Fn, .count), of(.driver_count));
    try std.testing.expectEqual(@as(?Fn, .receiver_count), of(.receiver_count));
    try std.testing.expectEqual(@as(?Fn, .state), of(.driver_state));
    try std.testing.expectEqual(@as(?Fn, .strength), of(.driver_strength));
    try std.testing.expectEqual(@as(?Fn, .delay), of(.driver_delay));
    try std.testing.expectEqual(@as(?Fn, .next_state), of(.driver_next_state));
    try std.testing.expectEqual(@as(?Fn, .next_strength), of(.driver_next_strength));
    try std.testing.expectEqual(@as(?Fn, .type), of(.driver_type));
    try std.testing.expectEqual(@as(?Fn, null), of(.time));
}

test key {
    // A waiter slot no variable owns: bit 31 set, the net's slot below it.
    try std.testing.expectEqual(@as(u32, 0x8000_0000), key(0));
    try std.testing.expectEqual(@as(u32, 0x8000_0005), key(5));
    try std.testing.expect(key(5) != key(6));
}

test "§9.22 a driver access function outside a connect module is E0818" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const diag = @import("diag");
    var bag = diag.Bag.init(arena.allocator());
    var out = std.Io.Writer.Allocating.init(arena.allocator());
    try std.testing.expectError(error.DigitalFailed, root.elaborate(arena.allocator(),
        \\module top; wire w; assign w = 1'b1; initial $display("%0d", $driver_count(w)); endmodule
        \\
    , .{ .mixed = .{ .top = "top", .timescales = &.{} } }, &bag, &out.writer));
    try std.testing.expectEqual(diag.Code.E0818, bag.records.items[0].code);
}
