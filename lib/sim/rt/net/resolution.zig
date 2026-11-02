//! A net's drivers in, its resolved value and strength published to its slot out, with the inertial delays a net or driver carries; a charge-storage net decays.
//! Cites: IEEE 1364-2005 §7.9 (resolution), §7.10, §7.14 (charge decay), §7.15 (net delays).
//!
//! Contents:
//! - `pub fn resolve(s: *State, k: u32) Error!void`
//! - `pub fn shown(s: *const State, off: u32, at: u32) Int.Bit`
//! - `pub fn arrive(s: *State, payload: u32) Error!void`
//! - `pub fn inertial(s: *State, flight: *?Handle, tgt: []u64, tgt_or_z: *bool, from_v: []const u64, from_x: []const u64, from_or_z: bool, to: []const u64, to_or_z: bool) Error!bool`

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const dnet = @import("../../digital/net.zig");
const Handle = @import("../../scheduler.zig").Handle;
const design = @import("../design.zig");
const State = @import("../State.zig");
const Error = design.Error;
const logic = @import("../logic/root.zig");
const words = logic.words;
const Bit = logic.Bit;
const Signal = dnet.Signal;
const testing = std.testing;
const driving = @import("driving.zig");
const layout = @import("layout.zig");
const module_paths = @import("module_paths.zig");
const switches = @import("switches.zig");
const Net = layout.Net;
const Nets = layout.Nets;
const Path = layout.Path;
const Switches = layout.Switches;
const Udp = layout.Udp;
const bitAt = driving.bitAt;
const bitOf = driving.bitOf;
const bridge = driving.bridge;
const contribution = driving.contribution;
const decay_base = layout.decay_base;
const drive_base = layout.drive_base;
const fill = driving.fill;
const literal = driving.literal;
const net_base = layout.net_base;
const pathDelay = module_paths.pathDelay;
const pathSeen = module_paths.pathSeen;
const setBit = driving.setBit;
const tran_bit = layout.tran_bit;
const udp = driving.udp;
const wakeSwitchesOn = switches.wakeSwitchesOn;

/// `resolution.resolve` of net `k`: every driver folded, a `trireg`'s charge
/// where none asserts anything, the net type's own pull; then published,
/// or after the net's `delay3`.
pub fn resolve(s: *State, k: u32) Error!void {
    const t = &s.nets;
    if (t.on_net.len != 0 and t.on_net[k].len != 0) return resolveJoined(s, k);
    const n = t.nets[k];
    const nw = words(n.width);
    const res = t.res[t.nat[k]..][0 .. 2 * nw];
    const cv = s.v[n.off..][0..nw];
    const cx = s.x[n.off..][0..nw];
    var moved = false;
    const floating = if (n.strong) foldStrong(t, n, res, cv, cx) else fold(t, k, res, cv, cx, &moved);
    if (n.kind == .trireg) try chargeState(s, k, floating);
    // §14.4: of a module path delay and the net's own, "the larger".
    const path = try pathDelay(s, n, cv, cx, res);
    if (n.delay.present or path != null) {
        const tgt = t.ntgt[t.nat[k]..][0 .. 2 * nw];
        var or_z = false;
        if (try inertial(s, &t.nflight[k], tgt, &or_z, cv, cx, false, res, false)) {
            // §5.1.9 truth of what the net shows: any known 1 is true.
            const from: Int.Bit = for (cv, cx) |v, x| {
                if (v & ~x != 0) break .one;
            } else .zero;
            const own: u64 = if (n.delay.present) n.delay.continuous(from, literal(tgt, n.width)) else 0;
            const ticks = @max(own, path orelse 0);
            t.nflight[k] = s.sched.scheduleAfter(s.gpa, ticks, .inactive, net_base + k) catch |e| return s.timeFail(e);
        }
        return;
    }
    // No path active: the change is not delayed, and one in flight is superseded.
    if (n.paths.len != 0) if (t.nflight[k]) |h| {
        _ = s.sched.cancel(h) catch |e| return s.schedFail(e);
        t.nflight[k] = null;
    };
    try s.store(n.slot, n.off, res[0..nw], res[nw..], t.ones[0..nw]);
    // §7.11: a MOS switch passes its data's strength, so a change of
    // strength alone re-runs what reads the net (`waiters.wakeSwitches`).
    if (moved) try wakeSwitchesOn(s, k);
}

/// Bit `at` of the value whose first word is word `off` of the planes.
pub fn shown(s: *const State, off: u32, at: u32) Int.Bit {
    const o = off + at / 64;
    const v: u2 = @intCast(s.v[o] >> @intCast(at % 64) & 1);
    const x: u2 = if (logic.two) 0 else @intCast(s.x[o] >> @intCast(at % 64) & 1);
    return @fromBackingInt(@intCast(v | x << 1));
}

/// `State.next`'s dispatch of a `drive_base`/`net_base`/`decay_base`
/// payload (`Run.runUntil`'s `.drive`, `.net_update`, `.decay`).
pub fn arrive(s: *State, payload: u32) Error!void {
    const t = &s.nets;
    const k = payload & ((1 << 28) - 1);
    switch (payload - k) {
        drive_base => {
            const d = t.drivers[k];
            const n = 2 * words(t.nets[d.net].width);
            t.flight[k] = null;
            @memcpy(t.cur[t.at[k]..][0..n], t.tgt[t.at[k]..][0..n]);
            t.or_z[k] = t.tgt_or_z[k];
            return resolve(s, d.net);
        },
        net_base => {
            const n = t.nets[k];
            const nw = words(n.width);
            t.nflight[k] = null;
            const tgt = t.ntgt[t.nat[k]..];
            return s.store(n.slot, n.off, tgt[0..nw], tgt[nw..][0..nw], t.ones[0..nw]);
        },
        // §3.8: a charge held for the decay time is worth nothing, x.
        decay_base => if (k >= tran_bit) {
            const i = k - tran_bit;
            t.tpending[i] = null;
            t.tstate[i] = t.ttarget[i];
            try resolve(s, t.trans[i].a);
            return resolve(s, t.trans[i].b);
        } else {
            const n = t.nets[k];
            const nw = words(n.width);
            t.decay_ev[k] = null;
            const res = t.res[t.nat[k]..][0 .. 2 * nw];
            fill(res, n.width, .x);
            return s.store(n.slot, n.off, res[0..nw], res[nw..], t.ones[0..nw]);
        },
        else => unreachable,
    }
}

/// `resolution.schedule`, §6.1.3's inertial rule: whether a transition to `to`
/// must be scheduled, having cancelled the one it displaces and recorded
/// `to` in `tgt`. Not when the value settles back to what is published, or
/// is what is already on its way: a pulse shorter than the delay vanishes.
pub fn inertial(s: *State, flight: *?Handle, tgt: []u64, tgt_or_z: *bool, from_v: []const u64, from_x: []const u64, from_or_z: bool, to: []const u64, to_or_z: bool) Error!bool {
    const h = to.len / 2;
    const same = if (flight.* != null)
        std.mem.eql(u64, tgt, to) and tgt_or_z.* == to_or_z
    else
        std.mem.eql(u64, from_v, to[0..h]) and (logic.two or std.mem.eql(u64, from_x, to[h..])) and from_or_z == to_or_z;
    if (same) return false;
    if (flight.*) |f| _ = s.sched.cancel(f) catch |e| return s.schedFail(e);
    flight.* = null;
    @memcpy(tgt, to);
    tgt_or_z.* = to_or_z;
    return true;
}

// ---- private ----

/// `Signal`'s fold when every driver is strong and none is H/L: a driver
/// bit is St0, St1, StX or nothing, so a strength never decides and the
/// §7.9 tables reduce to plane algebra. `(cv, cx)` is the value the net
/// shows, a `trireg`'s charge. Whether no bit is driven (§3.8).
fn foldStrong(t: *const Nets, n: Net, res: []u64, cv: []const u64, cx: []const u64) bool {
    const nw = cv.len;
    var driven_any: u64 = 0;
    for (0..nw) |j| {
        const m = dnet.wordMask(n.width, j);
        var one: u64 = 0;
        var zero: u64 = 0;
        var unk: u64 = 0;
        for (n.drivers) |di| {
            const p = t.cur[t.at[di]..];
            const v = p[j];
            const x = p[nw + j];
            one |= v & ~x;
            zero |= ~v & ~x & m;
            unk |= v & x;
        }
        const driven = one | zero | unk;
        const z = m & ~driven;
        // Per bit, x where the table says so and 1 where only a 1 remains.
        // Table 7-4: disagreement is x. At equal strength a 0 decides
        // wired `and` (Table 7-6), a 1 wired `or` (Table 7-7).
        const X, const o = if (dnet.wiredLogic(n.kind)) |table| switch (table) {
            .@"and" => .{ unk & ~zero, one & ~zero & ~unk },
            .@"or" => .{ unk & ~one, one },
        } else .{ unk | (one & zero), one & ~zero & ~unk };
        var v = o | X;
        var x = X | z;
        switch (n.kind) {
            // §3.7 the net type's pull fills what no driver asserts, a
            // supply's beats every strong one.
            .tri0 => x &= ~z,
            .tri1 => {
                v |= z;
                x &= ~z;
            },
            .supply0 => {
                v = 0;
                x = 0;
            },
            .supply1 => {
                v = m;
                x = 0;
            },
            // §3.8 an undriven bit holds its charge.
            .trireg => {
                v = (v & driven) | (cv[j] & z);
                x = (x & driven) | (cx[j] & z);
            },
            .wire, .tri, .uwire, .wand, .wor, .triand, .trior, .wreal => {},
        }
        res[j] = v;
        res[nw + j] = x;
        driven_any |= driven;
    }
    return driven_any == 0;
}

/// `resolution.resolve`'s fold, bit by bit through `Signal`. `moved` is
/// set when bit 0's signal, the one a MOS switch reads, changed.
fn fold(t: *Nets, k: u32, res: []u64, cv: []const u64, cx: []const u64, moved: *bool) bool {
    const n = t.nets[k];
    const nw = cv.len;
    const tables = dnet.wiredLogic(n.kind);
    var floating: u32 = 0;
    for (0..n.width) |bi| {
        const at: u32 = @intCast(bi);
        var acc: Signal = .{};
        for (n.drivers) |di| {
            const b = bitAt(t.cur[t.at[di]..][0 .. 2 * nw], at);
            const c: Signal = if (t.or_z[di] and b != .z) .orZ(b, t.s0[di], t.s1[di]) else .of(b, t.s0[di], t.s1[di]);
            acc = if (tables) |table| acc.combineWired(c, table) else acc.combine(c);
        }
        if (n.kind == .trireg and acc.none()) {
            acc = .of(bitOf(cv, cx, at), n.charge, n.charge);
            floating += 1;
        }
        acc = acc.combine(dnet.netPull(n.kind));
        if (at == 0) {
            moved.* = !std.meta.eql(t.sig0[k], acc);
            t.sig0[k] = acc;
        }
        setBit(res, at, acc.collapse());
    }
    return floating == n.width;
}

/// `resolution.resolveJoined`: §7.6 "switch processing shall consider all the
/// devices in a bidirectional switch-connected net before it can determine
/// the appropriate value for any node". Each bit of net `start` and the net
/// bits joined to it through switches that may conduct resolve as one, from
/// every driver of every one of them, reduced by the switches crossed (§7.11,
/// §7.12) and widened to include high impedance across one of unknown
/// conduction (§7.10.2); with no driver asserting anything, the group's
/// triregs share their charge (§4.6.3.1). Every net touched is published.
/// ponytail: the interpreter's limits, kept: no charge decay, wired logic or
/// net delay inside a joined group, and the group is found afresh each time.
fn resolveJoined(s: *State, start: u32) Error!void {
    const t = &s.nets;
    var arena: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var touched: std.ArrayList(u32) = .empty;
    for (0..t.nets[start].width) |i| {
        const group = try dnet.reach(Switches{ .t = t }, a, .{ .net = start, .bit = @intCast(i) });
        for (group) |y| {
            const paths = try dnet.switchPaths(Switches{ .t = t }, a, y, group);
            var acc: Signal = .{};
            for (group, paths) |z, p| {
                var own = dnet.netPull(t.nets[z.net].kind);
                for (t.nets[z.net].drivers) |di| own = own.combine(contribution(t, di, z.bit));
                acc = acc.combine(dnet.crossed(own, z, y, p));
            }
            if (acc.none()) for (group, paths) |z, p| {
                const n = t.nets[z.net];
                if (n.kind == .trireg) acc = acc.combine(dnet.crossed(.of(shown(s, n.off, z.bit), n.charge, n.charge), z, y, p));
            };
            const n = t.nets[y.net];
            const res = t.res[t.nat[y.net]..][0 .. 2 * words(n.width)];
            // A net first reached here keeps what it shows on the bits no
            // switch joins (`exec`'s `resolved`, which it published).
            if (std.mem.findScalar(u32, touched.items, y.net) == null) {
                try touched.append(a, y.net);
                const nw = words(n.width);
                @memcpy(res[0..nw], s.v[n.off..][0..nw]);
                if (logic.two) @memset(res[nw..], 0) else @memcpy(res[nw..], s.x[n.off..][0..nw]);
            }
            if (y.bit == 0) t.sig0[y.net] = acc;
            setBit(res, y.bit, acc.collapse());
        }
    }
    for (touched.items) |k| {
        const n = t.nets[k];
        const nw = words(n.width);
        const res = t.res[t.nat[k]..][0 .. 2 * nw];
        try s.store(n.slot, n.off, res[0..nw], res[nw..], t.ones[0..nw]);
    }
}

/// `resolution.chargeState`: the §3.8 decay countdown restarts on each entry
/// into the capacitive state and stops on leaving it.
fn chargeState(s: *State, k: u32, floating: bool) Error!void {
    const t = &s.nets;
    const was = t.capacitive[k];
    t.capacitive[k] = floating;
    if (was == floating) return;
    if (t.decay_ev[k]) |h| _ = s.sched.cancel(h) catch |e| return s.schedFail(e);
    t.decay_ev[k] = null;
    if (!floating) return;
    const after = t.nets[k].decay orelse return;
    t.decay_ev[k] = s.sched.scheduleAfter(s.gpa, after, .inactive, decay_base + k) catch |e| return s.timeFail(e);
}

test "the all-strong plane fold is Signal's fold" {
    // Every net kind the fold covers, three drivers, every 4^3 combination
    // on one bit each, against `resolution.resolve`'s per-bit fold.
    const kinds = [_]Ast.NetKind{ .wire, .tri, .wand, .wor, .triand, .trior, .tri0, .tri1, .supply0, .supply1, .trireg };
    const bits = [_]Int.Bit{ .zero, .one, .z, .x };
    for (kinds) |kind| for (bits) |charge| {
        var cur: [3 * 2]u64 = undefined;
        const at = [_]u32{ 0, 2, 4 };
        for (0..64) |combo| {
            // Driver j's value in bit 0 of its own planes.
            for (0..3) |j| {
                const b = bits[combo >> @intCast(2 * j) & 3];
                cur[at[j]] = @backingInt(b) & 1;
                cur[at[j] + 1] = @backingInt(b) >> 1;
            }
            const net: Net = .{ .kind = kind, .slot = 0, .off = 0, .width = 1, .drivers = &.{ 0, 1, 2 }, .strong = true };
            // Real variables, not `@constCast` of a literal: `fold` writes
            // `sig0`, and a constant literal may sit in read-only memory (a
            // bus error on aarch64-macos).
            var or_z = [_]bool{ false, false, false };
            var s0 = [_]Ast.Strength{ .strong, .strong, .strong };
            var s1 = [_]Ast.Strength{ .strong, .strong, .strong };
            var sig0 = [_]Signal{.{}};
            const t: Nets = .{
                .nets = &.{net},
                .drivers = &.{},
                .udps = &.{},
                .at = @constCast(&at),
                .cur = &cur,
                .tgt = &.{},
                .or_z = &or_z,
                .tgt_or_z = &.{},
                .s0 = &s0,
                .s1 = &s1,
                .flight = &.{},
                .started = &.{},
                .nat = &.{},
                .res = &.{},
                .ntgt = &.{},
                .nflight = &.{},
                .capacitive = &.{},
                .decay_ev = &.{},
                .sig0 = &sig0,
                .pat = &.{},
                .prev = &.{},
                .state = &.{},
                .ones = &.{},
                .scratch = &.{},
            };
            const cv = [_]u64{@backingInt(charge) & 1};
            const cx = [_]u64{@backingInt(charge) >> 1};
            var fast: [2]u64 = undefined;
            var slow: [2]u64 = .{ 0, 0 };
            var tt = t;
            const f1 = foldStrong(&tt, net, &fast, &cv, &cx);
            var moved = false;
            const f2 = fold(&tt, 0, &slow, &cv, &cx, &moved);
            try std.testing.expectEqual(slow, fast);
            // Only a `trireg` counts its undriven bits.
            if (kind == .trireg) try std.testing.expectEqual(f2, f1);
        }
    };
}

test "the all-strong plane fold is Signal's fold across word boundaries" {
    // Widths that end inside a word, on a word's end, and past it: a word
    // index or mask slip in either fold shows as a differing bit past 63.
    const kinds = [_]Ast.NetKind{ .wire, .tri, .wand, .wor, .triand, .trior, .tri0, .tri1, .supply0, .supply1, .trireg };
    var prng = std.Random.DefaultPrng.init(0x79);
    const rand = prng.random();
    inline for (.{ 64, 70, 128, 130 }) |width| {
        const nw = comptime words(width);
        for (kinds) |kind| for (0..50) |_| {
            // Three drivers, each `2 * nw` words (values then unknowns), and
            // the trireg charge; every bit one of the four states at random.
            var cur: [3 * 2 * nw]u64 = @splat(0);
            var charge: [2 * nw]u64 = @splat(0);
            for (0..width) |bi| {
                const at: u32 = @intCast(bi);
                for (0..3) |j| setBit(cur[2 * nw * j ..][0 .. 2 * nw], at, @fromBackingInt(rand.int(u2)));
                setBit(&charge, at, @fromBackingInt(rand.int(u2)));
            }
            const starts = [_]u32{ 0, 2 * nw, 4 * nw };
            const n: Net = .{ .kind = kind, .slot = 0, .off = 0, .width = width, .drivers = &.{ 0, 1, 2 }, .strong = true };
            var or_z = [_]bool{ false, false, false };
            var s0 = [_]Ast.Strength{ .strong, .strong, .strong };
            var s1 = [_]Ast.Strength{ .strong, .strong, .strong };
            var sig0 = [_]Signal{.{}};
            var tt: Nets = .{
                .nets = &.{n},
                .drivers = &.{},
                .udps = &.{},
                .at = @constCast(&starts),
                .cur = &cur,
                .tgt = &.{},
                .or_z = &or_z,
                .tgt_or_z = &.{},
                .s0 = &s0,
                .s1 = &s1,
                .flight = &.{},
                .started = &.{},
                .nat = &.{},
                .res = &.{},
                .ntgt = &.{},
                .nflight = &.{},
                .capacitive = &.{},
                .decay_ev = &.{},
                .sig0 = &sig0,
                .pat = &.{},
                .prev = &.{},
                .state = &.{},
                .ones = &.{},
                .scratch = &.{},
            };
            var fast: [2 * nw]u64 = undefined;
            var slow: [2 * nw]u64 = @splat(0);
            const f1 = foldStrong(&tt, n, &fast, charge[0..nw], charge[nw..]);
            var moved = false;
            const f2 = fold(&tt, 0, &slow, charge[0..nw], charge[nw..], &moved);
            try std.testing.expectEqual(slow, fast);
            if (kind == .trireg) try std.testing.expectEqual(f2, f1);
        };
    }
}

test "§6.5.7.1 a port window passes its source bits, z and x included, and shown reads them back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d = design.one_slot;
    // Slot 0 is the 4-bit net at word 0; word 1 is the source: 1, z, 1, 0 from bit 3 down.
    d.v = &.{ 0, 0b1010 };
    d.x = &.{ 0, 0b0100 };
    d.nets = &.{.{ .kind = .wire, .slot = 0, .off = 0, .width = 4, .drivers = &.{0}, .strong = false }};
    d.drivers = &.{.{ .net = 0, .source = .{ .bridge = .{ .src_off = 1, .src_lo = 0, .dst_lo = 0, .width = 4 } } }};
    const s = try State.quietState(arena.allocator(), &d, -9);
    try bridge(s, 0);
    try std.testing.expectEqual(@as(u64, 0b1010), s.v[0]);
    try std.testing.expectEqual(@as(u64, 0b0100), s.x[0]);
    const want = [_]Int.Bit{ .zero, .one, .z, .one };
    for (want, 0..) |b, i| try std.testing.expectEqual(b, shown(s, 0, @intCast(i)));
}

test "§14.3.3 the source that transitioned last picks the delay, the smallest of a tie, per transition, and only true conditions (the interpreter's Examples 1 and 2)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const C = struct {
        fn yes(_: *State) Error!bool {
            return true;
        }
        fn no(_: *State) Error!bool {
            return false;
        }
    };
    var d = design.one_slot;
    // Slot 0 is Y; slots 1 and 2 are A and B. Example 1: (A => Y) = (6, 9),
    // (B => Y) = (5, 11). Example 2's MODE 2 rows: three true conditions
    // (5, 9), (4, 8), (6, 5) and a false one (3, 2).
    d.v = &.{ 0, 0, 0 };
    d.x = &.{ 0, 0, 0 };
    d.slots = 3;
    const ex1 = [_]Path{
        .{ .src = 1, .src_off = 1, .table = dnet.pathTable(&.{ 6, 9 }) },
        .{ .src = 2, .src_off = 2, .table = dnet.pathTable(&.{ 5, 11 }) },
    };
    const ex2 = [_]Path{
        .{ .src = 1, .src_off = 1, .cond = &C.yes, .table = dnet.pathTable(&.{ 5, 9 }) },
        .{ .src = 1, .src_off = 1, .cond = &C.yes, .table = dnet.pathTable(&.{ 4, 8 }) },
        .{ .src = 1, .src_off = 1, .cond = &C.yes, .table = dnet.pathTable(&.{ 6, 5 }) },
        .{ .src = 1, .src_off = 1, .cond = &C.no, .table = dnet.pathTable(&.{ 3, 2 }) },
    };
    d.nets = &.{
        .{ .kind = .wire, .slot = 0, .off = 0, .width = 1, .drivers = &.{}, .strong = false, .paths = &ex1 },
        .{ .kind = .wire, .slot = 0, .off = 0, .width = 1, .drivers = &.{}, .strong = false, .paths = &ex2 },
    };
    const s = try State.quietState(a, &d, -9);
    const zero = [_]u64{0};
    const rise = [_]u64{ 1, 0 };
    const fall = [_]u64{ 0, 0 };
    const one = [_]u64{1};
    // No source has transitioned: no path delay.
    try std.testing.expectEqual(@as(?u64, null), try pathDelay(s, d.nets[0], &zero, &zero, &rise));
    s.sched.now = 20;
    s.v[1] = 1;
    pathSeen(s, 1);
    try std.testing.expectEqual(@as(?u64, 6), try pathDelay(s, d.nets[0], &zero, &zero, &rise));
    try std.testing.expectEqual(@as(?u64, 9), try pathDelay(s, d.nets[0], &one, &zero, &fall));
    s.sched.now = 60;
    s.v[2] = 1;
    pathSeen(s, 2);
    try std.testing.expectEqual(@as(?u64, 5), try pathDelay(s, d.nets[0], &zero, &zero, &rise));
    try std.testing.expectEqual(@as(?u64, 11), try pathDelay(s, d.nets[0], &one, &zero, &fall));
    s.sched.now = 100;
    s.v[1] = 0;
    s.v[2] = 0;
    pathSeen(s, 1);
    pathSeen(s, 2);
    try std.testing.expectEqual(@as(?u64, 5), try pathDelay(s, d.nets[0], &zero, &zero, &rise));
    try std.testing.expectEqual(@as(?u64, 9), try pathDelay(s, d.nets[0], &one, &zero, &fall));
    // §14.4: 30 after the sources moved, a delay of at most 11 has passed.
    s.sched.now = 130;
    try std.testing.expectEqual(@as(?u64, 0), try pathDelay(s, d.nets[0], &one, &zero, &fall));
    // Example 2 at MODE 2: rise 4, fall 5 (the false row's 3 and 2 unused).
    s.sched.now = 100;
    try std.testing.expectEqual(@as(?u64, 4), try pathDelay(s, d.nets[1], &zero, &zero, &rise));
    try std.testing.expectEqual(@as(?u64, 5), try pathDelay(s, d.nets[1], &one, &zero, &fall));
}

test "§14.3.1/§14.3.2 a path's delay per transition follows Tables 14-2 and 14-3 (the interpreter's usage row)" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = design.one_slot;
    d.v = &.{ 0, 0 };
    d.x = &.{ 0, 0 };
    d.slots = 2;
    const paths = [_]Path{.{ .src = 1, .src_off = 1, .table = dnet.pathTable(&.{ 5, 12, 17, 10, 6, 22 }) }};
    d.nets = &.{.{ .kind = .wire, .slot = 0, .off = 0, .width = 1, .drivers = &.{}, .strong = false, .paths = &paths }};
    const s = try State.quietState(a, &d, -9);
    s.v[1] = 1;
    pathSeen(s, 1);
    // Planes per `Int.Bit`: 0 = (0, 0), 1 = (1, 0), z = (0, 1), x = (1, 1).
    const P = struct {
        fn of(b: Int.Bit) [2]u64 {
            return .{ @backingInt(b) & 1, @backingInt(b) >> 1 };
        }
    };
    const Case = struct { from: Int.Bit, to: Int.Bit, ticks: u64 };
    for ([_]Case{
        .{ .from = .zero, .to = .one, .ticks = 5 }, .{ .from = .one, .to = .zero, .ticks = 12 },
        .{ .from = .zero, .to = .z, .ticks = 17 },  .{ .from = .z, .to = .one, .ticks = 10 },
        .{ .from = .one, .to = .z, .ticks = 6 },    .{ .from = .z, .to = .zero, .ticks = 22 },
        .{ .from = .zero, .to = .x, .ticks = 5 },   .{ .from = .one, .to = .x, .ticks = 6 },
        .{ .from = .z, .to = .x, .ticks = 10 },     .{ .from = .x, .to = .zero, .ticks = 22 },
        .{ .from = .x, .to = .one, .ticks = 10 },   .{ .from = .x, .to = .z, .ticks = 17 },
    }) |c| {
        const f = P.of(c.from);
        const res = P.of(c.to);
        try std.testing.expectEqual(@as(?u64, c.ticks), try pathDelay(s, d.nets[0], f[0..1], f[1..2], &res));
    }
}

test "§8 a UDP of any number of inputs: 65, one past the old 64, and 300" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const D = @import("../../digital/net.zig");
    for ([_]u32{ 65, 300 }) |n| {
        // A wide AND: every input 1 is 1; a 0 anywhere, whatever the rest
        // (`?`), is 0; anything else matches no row and is x (§8.1.6).
        const ones = try a.alloc(D.UdpSym, n);
        @memset(ones, .{ .level = '1' });
        const rows = try a.alloc(D.UdpRow, n + 1);
        rows[0] = .{ .ins = ones, .state = 0, .out = '1', .edge_at = null };
        for (rows[1..], 0..) |*r, k| {
            const syms = try a.alloc(D.UdpSym, n);
            @memset(syms, .{ .level = '?' });
            syms[k] = .{ .level = '0' };
            r.* = .{ .ins = syms, .state = 0, .out = '0', .edge_at = null };
        }
        var d = design.one_slot;
        d.nets = &.{.{ .kind = .wire, .slot = 0, .off = 0, .width = 1, .drivers = &.{0}, .strong = true }};
        d.drivers = &.{.{ .net = 0, .source = .{ .udp = 0 } }};
        const udps = [_]Udp{.{ .rows = rows, .sequential = false, .ins = n, .state = .x }};
        d.udps = &udps;
        const s = try State.quietState(a, &d, -9);
        const ins = try a.alloc(Bit, n);
        @memset(ins, .one);
        try udp(s, 0, ins);
        try testing.expectEqual(@as(u64, 1), s.v[0] & 1);
        ins[n - 1] = .zero;
        try udp(s, 0, ins);
        try testing.expectEqual(@as(u64, 0), s.v[0] & 1);
        ins[n - 1] = .z;
        try udp(s, 0, ins);
        try testing.expectEqual(@as(u64, 1), s.x[0] & 1);
    }
}
