//! A driver's new output in (a continuous assignment, a gate, a UDP, a MOS switch, a port window, a pull), its row of `Nets` and the net it drives queued for resolution out.
//! Cites: IEEE 1364-2005 §6.1, §6.5.7.1, §7.1 to §7.8, §8, §19.9.
//!
//! Contents:
//! - `pub fn drive(s: *State, i: u32, planes: []const u64, or_z: bool) Error!void`
//! - `pub fn gate(s: *State, i: u32, comptime kind: Ast.GateKind, ins: []const Bit) Error!void`
//! - `pub fn udp(s: *State, i: u32, ins: []const Bit) Error!void`
//! - `pub fn mos(s: *State, i: u32, data: Bit, gate_: Bit) Error!void`
//! - `pub fn bridge(s: *State, i: u32) Error!void`
//! - `pub fn pull(s: *State, i: u32) Error!void`
//! - `pub fn contribution(t: *const Nets, di: u32, at: u32) Signal`
//! - `pub fn int(b: Bit) Int.Bit`
//! - `pub fn fill(planes: []u64, w: u32, b: Bit) void`
//! - `pub fn bitAt(planes: []const u64, i: u32) Int.Bit`
//! - `pub fn setBit(planes: []u64, i: u32, b: Int.Bit) void`
//! - `pub fn literal(planes: []const u64, w: u32) Int.Literal`
//! - `pub fn bitOf(v: []const u64, x: []const u64, i: u32) Int.Bit`

const std = @import("std");
const assert = std.debug.assert;
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
const layout = @import("layout.zig");
const resolution = @import("resolution.zig");
const Nets = layout.Nets;
const drive_base = layout.drive_base;
const inertial = resolution.inertial;
const resolve = resolution.resolve;
const shown = resolution.shown;

/// `exec` `.continuous`: driver `i` asserts `planes` (values then unknowns,
/// its net's width) and, when `or_z`, §7.10.2's H/L. With a `delay3` the
/// value arrives by §6.1.3's inertial rule; without, the net resolves now.
/// Asserts that `i` is a driver and `planes` is as wide as its net.
pub fn drive(s: *State, i: u32, planes: []const u64, or_z: bool) Error!void {
    const t = &s.nets;
    assert(i < t.drivers.len);
    const d = t.drivers[i];
    assert(planes.len == 2 * words(t.nets[d.net].width));
    const cur = t.cur[t.at[i]..][0..planes.len];
    // §8.5: a sequential UDP's initial output is published at time 0
    // whatever its delay.
    const first = d.source == .udp and t.udps[d.source.udp].sequential and !t.started[i];
    // A combinational one's output is x until its first delayed value.
    if (d.source == .udp and !t.started[i] and !first and d.delay.present) try resolve(s, d.net);
    t.started[i] = true;
    if (d.delay.present and !first) {
        const tgt = t.tgt[t.at[i]..][0..planes.len];
        const h = planes.len / 2;
        if (!try inertial(s, &t.flight[i], tgt, &t.tgt_or_z[i], cur[0..h], cur[h..], t.or_z[i], planes, or_z)) return;
        const w = t.nets[d.net].width;
        const ticks = if (d.delay_bit) |b| d.delay.to(bitAt(tgt, b)) else d.delay.continuous(literal(cur, w).truth(), literal(tgt, w));
        t.flight[i] = s.sched.scheduleAfter(s.gpa, ticks, .inactive, drive_base + i) catch |e| return s.timeFail(e);
        return;
    }
    @memcpy(cur, planes);
    t.or_z[i] = or_z;
    assert(t.started[i]);
    return resolve(s, d.net);
}

/// §7.8.5 gate driver `i` of type `kind` over its input bits. Asserts that
/// `i` is a gate driver and it has an input.
pub fn gate(s: *State, i: u32, comptime kind: Ast.GateKind, ins: []const Bit) Error!void {
    assert(i < s.nets.drivers.len);
    assert(s.nets.drivers[i].source == .gate);
    assert(ins.len != 0);
    const o = dnet.gateBit(kind, @ptrCast(ins));
    return driveBit(s, i, s.nets.drivers[i].source.gate, o.bit, o.or_z);
}

/// §8 UDP driver `i` over its input bits (`resolution.udpValue`), any
/// number of them. Asserts that `i` is a UDP driver given one bit per input.
pub fn udp(s: *State, i: u32, ins: []const Bit) Error!void {
    const t = &s.nets;
    assert(i < t.drivers.len);
    assert(t.drivers[i].source == .udp);
    const k = t.drivers[i].source.udp;
    const u = t.udps[k];
    assert(ins.len == u.ins);
    const bits = t.udp_bits[0..ins.len];
    // §8.1.6: a z input is read as x.
    for (ins, bits) |b, *o| o.* = if (b == .z) .x else int(b);
    const out = if (!u.sequential) dnet.udpEval(u.rows, false, bits, .x, null, .x) else blk: {
        const prev = t.prev[t.pat[k]..][0..ins.len];
        for (bits, 0..) |b, j| {
            if (b == prev[j]) continue;
            const from = prev[j];
            prev[j] = b;
            t.state[k] = dnet.udpEval(u.rows, true, prev, t.state[k], @intCast(j), from);
        }
        break :blk t.state[k];
    };
    return driveBit(s, i, t.drivers[i].delay_bit orelse 0, out, false);
}

/// §7.6 MOS switch driver `i` (`resolution.mosValue`): its data at the data
/// net's strength, reduced by §7.12, while `gate` conducts; z when it does
/// not; H/L when the gate is x or z. A z on the data passes as z. Asserts
/// that `i` is a MOS switch driver.
pub fn mos(s: *State, i: u32, data: Bit, gate_: Bit) Error!void {
    const t = &s.nets;
    assert(i < t.drivers.len);
    assert(t.drivers[i].source == .mos);
    const m = t.drivers[i].source.mos;
    t.mos_in[i] = .{ data, gate_ };
    const g = int(gate_);
    const sig: Signal = if (m.data_net) |k| t.sig0[k] else .of(int(data), .strong, .strong);
    t.s0[i] = dnet.reduce(if (sig.lo < 0) @fromBackingInt(@intCast(@as(u8, @intCast(-sig.lo)))) else .highz, m.resistive);
    t.s1[i] = dnet.reduce(if (sig.hi > 0) @fromBackingInt(@intCast(@as(u8, @intCast(sig.hi)))) else .highz, m.resistive);
    const value = sig.collapse();
    const on: Int.Bit = if (m.n_type) .one else .zero;
    const out: Int.Bit = if (value == .z or (g != on and (g == .zero or g == .one))) .z else value;
    if (value == .z) assert(out == .z); // A z on the data passes as z.
    return driveBit(s, i, 0, out, out != .z and g != on);
}

/// §6.5.7.1 port window driver `i`: its source's bits, z outside them.
/// Asserts that `i` is a port window driver.
pub fn bridge(s: *State, i: u32) Error!void {
    const t = &s.nets;
    assert(i < t.drivers.len);
    assert(t.drivers[i].source == .bridge);
    const b = t.drivers[i].source.bridge;
    const w = t.nets[t.drivers[i].net].width;
    const planes = t.scratch[0 .. 2 * words(w)];
    fill(planes, w, .z);
    for (0..b.width) |j| {
        setBit(planes, b.dst_lo + @as(u32, @intCast(j)), shown(s, b.src_off, b.src_lo + @as(u32, @intCast(j))));
    }
    // `digital.net.Bridge`'s §12.3.9.2 widening.
    const ext_bit = if (b.sign_at) |at| shown(s, b.src_off, at) else Int.Bit.zero;
    for (0..b.ext) |j| setBit(planes, b.dst_lo + b.width + @as(u32, @intCast(j)), ext_bit);
    return drive(s, i, planes, false);
}

/// §19.9 `unconnected_drive` driver `i`: its level on every bit. Asserts
/// that `i` is a pull driver.
pub fn pull(s: *State, i: u32) Error!void {
    const t = &s.nets;
    assert(i < t.drivers.len);
    assert(t.drivers[i].source == .pull);
    const w = t.nets[t.drivers[i].net].width;
    const planes = t.scratch[0 .. 2 * words(w)];
    fill(planes, w, t.drivers[i].source.pull);
    return drive(s, i, planes, false);
}

/// What driver `di` asserts on bit `at` of its net (`resolution.contribution`).
/// Asserts that `di` is a driver and `at` lies in its net's words.
pub fn contribution(t: *const Nets, di: u32, at: u32) Signal {
    assert(di < t.drivers.len);
    const nw = words(t.nets[t.drivers[di].net].width);
    assert(at / 64 < nw);
    const b = bitAt(t.cur[t.at[di]..][0 .. 2 * nw], at);
    return if (t.or_z[di] and b != .z) .orZ(b, t.s0[di], t.s1[di]) else .of(b, t.s0[di], t.s1[di]);
}

/// Returns `b` as the interpreter's `Integer.Bit`.
pub fn int(b: Bit) Int.Bit {
    // The cast keeps the encoding: both are (value, unknown) bit pairs.
    comptime assert(@backingInt(Bit.z) == @backingInt(Int.Bit.z));
    comptime assert(@backingInt(Bit.x) == @backingInt(Int.Bit.x));
    return @fromBackingInt(@intCast(@backingInt(b)));
}

/// `planes` (values then unknowns) of a `w`-bit value, every bit `b`.
/// Asserts that `planes` holds exactly `w` bits per plane, rounded up.
pub fn fill(planes: []u64, w: u32, b: Bit) void {
    assert(planes.len % 2 == 0);
    const n = planes.len / 2;
    assert(n == words(w));
    for (planes[0..n], planes[n..], 0..) |*v, *x, j| {
        const m = dnet.wordMask(w, j);
        v.* = if (@backingInt(b) & 1 != 0) m else 0;
        x.* = if (@backingInt(b) >> 1 != 0) m else 0;
    }
}

/// Bit `i` of `planes`, values then unknowns. Asserts that `i` lies in them.
pub fn bitAt(planes: []const u64, i: u32) Int.Bit {
    assert(planes.len % 2 == 0);
    const n = planes.len / 2;
    assert(i / 64 < n);
    return bitOf(planes[0..n], planes[n..], i);
}

/// `dnet.setBit` of bit `i` of `planes`, values then unknowns. Asserts
/// that `i` lies in them.
pub fn setBit(planes: []u64, i: u32, b: Int.Bit) void {
    assert(planes.len % 2 == 0);
    assert(i / 64 < planes.len / 2);
    dnet.setBit(literal(planes, 0), i, b);
}

/// Returns `planes` (both, `words(w)` each) as the `Literal` the shared tables read.
/// Asserts that they hold `w` bits.
pub fn literal(planes: []const u64, w: u32) Int.Literal {
    assert(planes.len % 2 == 0);
    assert(words(w) <= planes.len / 2);
    return .{ .width = w, .signed = false, .sized = true, .planes = @constCast(planes) };
}

/// Bit `i` of the value whose planes are `v` and `x`. Asserts that the
/// planes pair up and hold bit `i`.
pub fn bitOf(v: []const u64, x: []const u64, i: u32) Int.Bit {
    assert(v.len == x.len);
    assert(i / 64 < v.len);
    const sh: u6 = @intCast(i % 64);
    return dnet.planeBit(v[i / 64] >> sh, x[i / 64] >> sh);
}

// ---- private ----

/// `drive` of a value that is z but for bit `at`, which is `b`.
fn driveBit(s: *State, i: u32, at: u32, b: Int.Bit, or_z: bool) Error!void {
    const t = &s.nets;
    assert(i < t.drivers.len);
    assert(at / 64 < words(t.nets[t.drivers[i].net].width));
    const planes = t.scratch[0 .. 2 * words(t.nets[t.drivers[i].net].width)];
    fill(planes, t.nets[t.drivers[i].net].width, .z);
    setBit(planes, at, b);
    return drive(s, i, planes, or_z);
}

test "§7.11 a strength-only change re-runs the MOS switch reading it, and only it: a delayed driver's transition keeps its time" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d = design.one_slot;
    // Net 0 `w` (pullup and a strong driver) is the data of pmos driver 2
    // on net 1 `q`, which a `#5` continuous assignment also drives.
    d.v = &.{ 0, 0 };
    d.x = &.{ 0, 0 };
    d.slots = 2;
    d.nets = &.{
        .{ .kind = .wire, .slot = 0, .off = 0, .width = 1, .drivers = &.{ 0, 1 }, .strong = false },
        .{ .kind = .wire, .slot = 1, .off = 1, .width = 1, .drivers = &.{ 2, 3 }, .strong = false },
    };
    d.drivers = &.{
        .{ .net = 0, .s0 = .pull, .s1 = .pull, .source = .{ .pull = .one } },
        .{ .net = 0, .source = .expr },
        .{ .net = 1, .source = .{ .mos = .{ .n_type = false, .resistive = false, .data_net = 0 } } },
        .{ .net = 1, .delay = .{ .rise = 5, .fall = 5, .off = 5, .present = true }, .source = .expr },
    };
    const s = try State.quietState(arena.allocator(), &d, -9);
    try pull(s, 0);
    try drive(s, 1, &.{ 1, 0 }, false);
    try mos(s, 2, .one, .zero);
    try std.testing.expectEqual(Ast.Strength.strong, s.nets.s1[2]);
    try drive(s, 3, &.{ 1, 0 }, false);
    const landing = s.nets.flight[3];
    try std.testing.expect(landing != null);
    // The strong driver lets go: `w` stays 1, at pull strength.
    var off: [2]u64 = undefined;
    fill(&off, 1, .z);
    try drive(s, 1, &off, false);
    try std.testing.expectEqual(@as(u64, 1), s.v[0] & 1);
    try std.testing.expectEqual(Ast.Strength.pull, s.nets.s1[2]);
    try std.testing.expect(std.meta.eql(landing, s.nets.flight[3]));
}
