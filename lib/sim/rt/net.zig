//! What the drivers of a resolved net assert -> the value the net shows,
//! published through `State.store` so its waiters wake as `resolution.resolve`'s
//! store wakes them, plus the delayed transitions in flight. The tables are
//! `digital/net.zig`'s; the one fold here, the all-strong one, is `Signal`'s.
//! Clauses: IEEE 1364-2005 §7.9 Tables 7-4 to 7-7, §7.10, §3.7, §3.8, §6.1.3,
//! §7.14 `delay3`, §7.8.5 gates, §7.6 MOS and pass switches, §8 UDPs, §19.9.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const dnet = @import("../digital/net.zig");
const Handle = @import("../scheduler.zig").Handle;
const root = @import("root.zig");
const State = root.State;
const Error = root.Error;
const logic = @import("logic.zig");
const Bit = logic.Bit;
const Signal = dnet.Signal;

/// `State.next` payloads: driver k's, net k's delayed transition, and net
/// k's §3.8 charge decay. All below `nba_payload`, above every pc and show.
pub const drive_base: u32 = root.show_base | 1 << 28;
/// `net_base + k`: net k's delayed transition lands (`drive_base`).
pub const net_base: u32 = root.show_base | 2 << 28;
/// `decay_base + k`: net k's §3.8 charge decays to x (`drive_base`).
const decay_base: u32 = root.show_base | 3 << 28;

/// One net `resolution.resolve` folds: `Run.nets[k]` with its word offset.
pub const Net = struct {
    kind: Ast.NetKind,
    slot: u32,
    off: u32,
    width: u32,
    drivers: []const u32,
    /// Every driver asserts strong0/strong1 and never §7.10.2's H/L, and
    /// no switch reads the net's strength: `foldStrong` applies.
    strong: bool,
    delay: dnet.Delay = .{},
    charge: Ast.Strength = .medium,
    decay: ?u64 = null,
    /// IEEE 1364-2005 §14.3 the module paths into the net (`dnet.Path`).
    paths: []const Path = &.{},
};

/// `dnet.Path` resolved: its source's slot and first word, and its
/// condition as a function of the emitted design (`emit.pathConds`).
pub const Path = struct {
    src: u32,
    src_off: u32,
    src_bit: u32 = 0,
    edge: Ast.SpecEdge = .none,
    cond: ?*const PathCond = null,
    ifnone: bool = false,
    table: dnet.PathTable,
};

/// §14.2.4.1 a state-dependent path's condition, true when its least
/// significant bit is not 0.
pub const PathCond = fn (*State) Error!bool;

/// One driver of a `Net`, `Run.drivers[i]` without its expression.
pub const Driver = struct {
    net: u32,
    s0: Ast.Strength = .strong,
    s1: Ast.Strength = .strong,
    delay: dnet.Delay = .{},
    /// The bit whose value picks the delay (§7.14), or null for §6.1.3's
    /// whole-vector rule of a continuous assignment.
    delay_bit: ?u32 = 0,
    /// Its value at time 0: a sequential UDP's state (§8.5), else z.
    init: Bit = .z,
    source: Source,
};

/// What computes a driver's value.
pub const Source = union(enum) {
    expr,
    /// The output bit of a gate (one of a §7.1.5 array).
    gate: u32,
    /// Index into `Design.udps`.
    udp: u32,
    mos: Mos,
    bridge: Bridge,
    pull: Bit,
};

/// `dnet.Mos` resolved: its data terminal's net, when it names one, is
/// where its strength comes from.
pub const Mos = struct { n_type: bool, resistive: bool, data_net: ?u32 = null };

/// `dnet.Bridge` with its source slot's first word.
pub const Bridge = struct { src_off: u32, src_lo: u32, dst_lo: u32, width: u32 };

/// `dnet.Udp`'s table: `ins` inputs, its state at time 0.
pub const Udp = struct { rows: []const dnet.UdpRow, sequential: bool, ins: u32, state: Bit };

/// `dnet.Tran` without its control (a `switch_ctrl` process reads that):
/// `a` and `b` are `Nets.nets` rows, and `state` is the conduction at time 0.
pub const Tran = struct {
    a: u32,
    b: u32,
    a_bit: u32 = 0,
    b_bit: u32 = 0,
    on: Bit = .one,
    state: dnet.Tran.State = .on,
    resistive: bool = false,
    delay: dnet.Delay = .{},
};

/// `State.next` payload `tran_base + i`: pass switch i's delayed change of
/// conduction lands (`decay_base` with this bit set in its index).
const tran_bit: u32 = 1 << 27;
/// `tran_base + i`: pass switch i's delayed change of conduction lands.
const tran_base: u32 = decay_base + tran_bit;

/// What the resolution keeps between events, one row per net or driver.
pub const Nets = struct {
    nets: []const Net,
    drivers: []const Driver,
    udps: []const Udp,
    /// Per driver, its first word in `cur`/`tgt`: values then unknowns,
    /// as wide as its net.
    at: []u32,
    cur: []u64,
    tgt: []u64,
    or_z: []bool,
    tgt_or_z: []bool,
    /// A MOS switch's strengths follow its data (§7.12); the rest are fixed.
    s0: []Ast.Strength,
    s1: []Ast.Strength,
    flight: []?Handle,
    started: []bool,
    /// Per net, its first word in `res`/`ntgt`.
    nat: []u32,
    res: []u64,
    ntgt: []u64,
    nflight: []?Handle,
    capacitive: []bool,
    decay_ev: []?Handle,
    /// Bit 0's §7.10 signal, which a MOS switch passes on.
    sig0: []Signal,
    /// The MOS switch drivers, and per driver the data and gate bits its
    /// last evaluation read (null before its first), for `wakeSwitchesOn`.
    mos_ix: []const u32 = &.{},
    mos_in: []?[2]Bit = &.{},
    /// §14.3.3 each module path source's slot, its row in `src_seen` and the
    /// word it last held (values, unknowns), for `pathSeen`.
    src_ix: std.AutoHashMapUnmanaged(u32, u32) = .empty,
    src_off: []u32 = &.{},
    src_last: [][2]u64 = &.{},
    src_seen: []?dnet.PathEdge = &.{},
    /// Per UDP, its first input in `prev`, the inputs its table last saw.
    pat: []u32,
    prev: []Int.Bit,
    state: []Int.Bit,
    /// One UDP's inputs read as §8.1.6 levels, as long as the widest UDP's.
    udp_bits: []Int.Bit = &.{},
    /// All ones, as wide as the widest net: `store`'s mask.
    ones: []u64,
    /// A driver value under construction.
    scratch: []u64,
    /// §7.6 the pass switches, their conduction, the one in flight, and
    /// per net the switches with it as a terminal.
    trans: []const Tran = &.{},
    tstate: []dnet.Tran.State = &.{},
    ttarget: []dnet.Tran.State = &.{},
    tpending: []?Handle = &.{},
    on_net: []const []const u32 = &.{},

    /// The state at time 0, allocated from `gpa` for the whole run.
    pub fn init(gpa: std.mem.Allocator, nets: []const Net, drivers: []const Driver, udps: []const Udp, trans: []const Tran) Error!Nets {
        var t: Nets = undefined;
        t.nets = nets;
        t.drivers = drivers;
        t.udps = udps;
        t.trans = trans;
        t.tstate = try gpa.alloc(dnet.Tran.State, trans.len);
        t.ttarget = try gpa.alloc(dnet.Tran.State, trans.len);
        for (trans, t.tstate, t.ttarget) |tr, *st, *tg| {
            st.* = tr.state;
            tg.* = tr.state;
        }
        t.tpending = try gpa.alloc(?Handle, trans.len);
        @memset(t.tpending, null);
        // Per net, its switches ascending: a counting sort into one array.
        const on_net = try gpa.alloc([]const u32, nets.len);
        const fill_at = try gpa.alloc(u32, nets.len + 1);
        defer gpa.free(fill_at);
        @memset(fill_at, 0);
        for (trans) |tr| {
            fill_at[tr.a + 1] += 1;
            if (tr.b != tr.a) fill_at[tr.b + 1] += 1;
        }
        for (fill_at[1..], 0..) |*c, k| c.* += fill_at[k];
        const flat = try gpa.alloc(u32, fill_at[nets.len]);
        for (on_net, fill_at[0..nets.len], fill_at[1..]) |*l, lo, hi| l.* = flat[lo..hi];
        for (trans, 0..) |tr, i| {
            flat[fill_at[tr.a]] = @intCast(i);
            fill_at[tr.a] += 1;
            if (tr.b == tr.a) continue;
            flat[fill_at[tr.b]] = @intCast(i);
            fill_at[tr.b] += 1;
        }
        t.on_net = on_net;
        var widest: u32 = 1;
        t.at = try gpa.alloc(u32, drivers.len);
        var n: u32 = 0;
        for (drivers, t.at) |d, *at| {
            at.* = n;
            n += 2 * words(nets[d.net].width);
        }
        t.cur = try gpa.alloc(u64, n);
        t.tgt = try gpa.alloc(u64, n);
        @memset(t.tgt, 0);
        for (drivers, t.at) |d, at| {
            const w = nets[d.net].width;
            // A UDP's initial value is its output bit's (§8.5); the rest z.
            fill(t.cur[at..][0 .. 2 * words(w)], w, if (d.source == .udp) .z else d.init);
            if (d.source == .udp) setBit(t.cur[at..][0 .. 2 * words(w)], d.delay_bit orelse 0, int(d.init));
        }
        t.or_z = try gpa.alloc(bool, drivers.len);
        t.tgt_or_z = try gpa.alloc(bool, drivers.len);
        @memset(t.or_z, false);
        @memset(t.tgt_or_z, false);
        t.s0 = try gpa.alloc(Ast.Strength, drivers.len);
        t.s1 = try gpa.alloc(Ast.Strength, drivers.len);
        for (drivers, t.s0, t.s1) |d, *s0, *s1| {
            s0.* = d.s0;
            s1.* = d.s1;
        }
        t.flight = try gpa.alloc(?Handle, drivers.len);
        @memset(t.flight, null);
        t.started = try gpa.alloc(bool, drivers.len);
        @memset(t.started, false);
        t.nat = try gpa.alloc(u32, nets.len);
        n = 0;
        for (nets, t.nat) |net, *at| {
            at.* = n;
            n += 2 * words(net.width);
            widest = @max(widest, net.width);
        }
        t.res = try gpa.alloc(u64, n);
        t.ntgt = try gpa.alloc(u64, n);
        @memset(t.res, 0);
        @memset(t.ntgt, 0);
        t.nflight = try gpa.alloc(?Handle, nets.len);
        t.decay_ev = try gpa.alloc(?Handle, nets.len);
        t.capacitive = try gpa.alloc(bool, nets.len);
        t.sig0 = try gpa.alloc(Signal, nets.len);
        @memset(t.nflight, null);
        @memset(t.decay_ev, null);
        @memset(t.capacitive, false);
        @memset(t.sig0, .{});
        var mos_ix: std.ArrayList(u32) = .empty;
        for (drivers, 0..) |d, i| if (d.source == .mos) try mos_ix.append(gpa, @intCast(i));
        t.mos_ix = mos_ix.items;
        t.mos_in = try gpa.alloc(?[2]Bit, drivers.len);
        @memset(t.mos_in, null);
        t.src_ix = .empty;
        t.src_off = &.{};
        t.src_last = &.{};
        t.src_seen = &.{};
        t.pat = try gpa.alloc(u32, udps.len);
        t.state = try gpa.alloc(Int.Bit, udps.len);
        n = 0;
        var most: u32 = 0;
        for (udps, t.pat, t.state) |u, *at, *st| {
            at.* = n;
            n += u.ins;
            most = @max(most, u.ins);
            st.* = int(u.state);
        }
        t.udp_bits = try gpa.alloc(Int.Bit, most);
        t.prev = try gpa.alloc(Int.Bit, n);
        @memset(t.prev, .x);
        t.ones = try gpa.alloc(u64, words(widest));
        @memset(t.ones, std.math.maxInt(u64));
        t.scratch = try gpa.alloc(u64, 2 * words(widest));
        return t;
    }
};

const words = logic.words;

fn int(b: Bit) Int.Bit {
    return @fromBackingInt(@intCast(@backingInt(b)));
}

/// `planes` (values then unknowns) of a `w`-bit value, every bit `b`.
fn fill(planes: []u64, w: u32, b: Bit) void {
    const n = planes.len / 2;
    for (planes[0..n], planes[n..], 0..) |*v, *x, j| {
        const m = dnet.wordMask(w, j);
        v.* = if (@backingInt(b) & 1 != 0) m else 0;
        x.* = if (@backingInt(b) >> 1 != 0) m else 0;
    }
}

/// Bit `i` of `planes`, values then unknowns.
fn bitAt(planes: []const u64, i: u32) Int.Bit {
    const n = planes.len / 2;
    return bitOf(planes[0..n], planes[n..], i);
}

/// `dnet.setBit` of bit `i` of `planes`, values then unknowns.
fn setBit(planes: []u64, i: u32, b: Int.Bit) void {
    dnet.setBit(literal(planes, 0), i, b);
}

fn literal(planes: []const u64, w: u32) Int.Literal {
    return .{ .width = w, .signed = false, .sized = true, .planes = @constCast(planes) };
}

/// `exec` `.continuous`: driver `i` asserts `planes` (values then unknowns,
/// its net's width) and, when `or_z`, §7.10.2's H/L. With a `delay3` the
/// value arrives by §6.1.3's inertial rule; without, the net resolves now.
pub fn drive(s: *State, i: u32, planes: []const u64, or_z: bool) Error!void {
    const t = &s.nets;
    const d = t.drivers[i];
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
        t.flight[i] = s.sched.scheduleAfter(ticks, .inactive, drive_base + i) catch |e| return s.timeFail(e);
        return;
    }
    @memcpy(cur, planes);
    t.or_z[i] = or_z;
    return resolve(s, d.net);
}

/// `drive` of a value that is z but for bit `at`, which is `b`.
fn driveBit(s: *State, i: u32, at: u32, b: Int.Bit, or_z: bool) Error!void {
    const t = &s.nets;
    const planes = t.scratch[0 .. 2 * words(t.nets[t.drivers[i].net].width)];
    fill(planes, t.nets[t.drivers[i].net].width, .z);
    setBit(planes, at, b);
    return drive(s, i, planes, or_z);
}

/// §7.8.5 gate driver `i` of type `kind` over its input bits.
pub fn gate(s: *State, i: u32, comptime kind: Ast.GateKind, ins: []const Bit) Error!void {
    const o = dnet.gateBit(kind, @ptrCast(ins));
    return driveBit(s, i, s.nets.drivers[i].source.gate, o.bit, o.or_z);
}

/// §8 UDP driver `i` over its input bits (`resolution.udpValue`), any
/// number of them.
pub fn udp(s: *State, i: u32, ins: []const Bit) Error!void {
    const t = &s.nets;
    const k = t.drivers[i].source.udp;
    const u = t.udps[k];
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
/// not; H/L when the gate is x or z. A z on the data passes as z.
pub fn mos(s: *State, i: u32, data: Bit, gate_: Bit) Error!void {
    const t = &s.nets;
    const m = t.drivers[i].source.mos;
    t.mos_in[i] = .{ data, gate_ };
    const g = int(gate_);
    const sig: Signal = if (m.data_net) |k| t.sig0[k] else .of(int(data), .strong, .strong);
    t.s0[i] = dnet.reduce(if (sig.lo < 0) @fromBackingInt(@intCast(@as(u8, @intCast(-sig.lo)))) else .highz, m.resistive);
    t.s1[i] = dnet.reduce(if (sig.hi > 0) @fromBackingInt(@intCast(@as(u8, @intCast(sig.hi)))) else .highz, m.resistive);
    const value = sig.collapse();
    const on: Int.Bit = if (m.n_type) .one else .zero;
    const out: Int.Bit = if (value == .z or (g != on and (g == .zero or g == .one))) .z else value;
    return driveBit(s, i, 0, out, out != .z and g != on);
}

/// §14.3.3 the module path sources of `t.nets`, each with its value at time
/// 0 (`v`/`x`, the design's initial plane words), the "before" of its first
/// transition (`pathSeen`). Allocated from `gpa` for the whole run.
pub fn seedPaths(t: *Nets, gpa: std.mem.Allocator, v: []const u64, x: []const u64) Error!void {
    std.debug.assert(t.src_ix.count() == 0); // once, from `State.initIn`
    var last: std.ArrayList([2]u64) = .empty;
    var offs: std.ArrayList(u32) = .empty;
    for (t.nets) |net| for (net.paths) |p| {
        const g = try t.src_ix.getOrPut(gpa, p.src);
        if (g.found_existing) continue;
        g.value_ptr.* = @intCast(last.items.len);
        try last.append(gpa, .{ v[p.src_off], x[p.src_off] });
        try offs.append(gpa, p.src_off);
    };
    t.src_last = last.items;
    t.src_off = offs.items;
    t.src_seen = try gpa.alloc(?dnet.PathEdge, last.items.len);
    @memset(t.src_seen, null);
}

/// IEEE 1364-2005 §14.3.3 `resolution.pathDelay`: of the paths into net `n`
/// whose source "has transitioned most recently in time" and whose
/// condition is true, on its edge (§14.2.3) and an `ifnone` one only while
/// no state-dependent path from its source is (§14.2.4.4), the smallest
/// delay for each bit's transition from `cv`/`cx` to `res`, counted from the
/// source's transition (§14.4). Null when no path is active.
fn pathDelay(s: *State, n: Net, cv: []const u64, cx: []const u64, res: []const u64) Error!?u64 {
    if (n.paths.len == 0) return null;
    const t = &s.nets;
    var latest: ?u64 = null;
    for (n.paths) |p| if (t.src_seen[t.src_ix.get(p.src).?]) |c| {
        latest = @max(latest orelse c.time, c.time);
    };
    const at = latest orelse return null;
    const nw = cv.len;
    var best: ?u64 = null;
    for (n.paths) |p| {
        if (!try pathActive(s, n.paths, p, at)) continue;
        for (0..n.width) |i| {
            const a = bitOf(cv, cx, @intCast(i));
            const b = bitAt(res[0 .. 2 * nw], @intCast(i));
            if (a == b) continue;
            const d = p.table[@backingInt(a)][@backingInt(b)];
            best = @min(best orelse d, d);
        }
    }
    const d = best orelse return null;
    return (at + d) -| s.sched.now;
}

fn pathActive(s: *State, paths: []const Path, p: Path, at: u64) Error!bool {
    if (!pathFired(s, p, at)) return false;
    if (p.ifnone) {
        for (paths) |q| if (q.src == p.src and !q.ifnone and (q.cond != null or q.edge != .none) and pathFired(s, q, at) and (q.cond == null or try q.cond.?(s))) return false;
        return true;
    }
    return if (p.cond) |c| try c(s) else true;
}

/// `resolution.pathFired`.
fn pathFired(s: *const State, p: Path, at: u64) bool {
    const t = &s.nets;
    const c = t.src_seen[t.src_ix.get(p.src).?] orelse return false;
    if (c.time != at) return false;
    if (p.edge == .none or p.src_bit >= 64) return true;
    const before = bitOf(c.before[0..1], c.before[1..2], p.src_bit);
    const after = bitOf(c.after[0..1], c.after[1..2], p.src_bit);
    if (before == after) return false;
    return if (p.edge == .posedge) before == .zero or after == .one else before == .one or after == .zero;
}

/// Bit `i` of the value whose planes are `v` and `x`.
fn bitOf(v: []const u64, x: []const u64, i: u32) Int.Bit {
    const sh: u6 = @intCast(i % 64);
    return dnet.planeBit(v[i / 64] >> sh, x[i / 64] >> sh);
}

/// §14.3.3 slot `slot` changed: when a module path source transitions, its
/// time and its low word before and after (`waiters.store`'s `.path`).
pub fn pathSeen(s: *State, slot: u32) void {
    const t = &s.nets;
    const i = t.src_ix.get(slot) orelse return;
    const now: [2]u64 = .{ s.v[t.src_off[i]], s.x[t.src_off[i]] };
    t.src_seen[i] = .{ .time = s.sched.now, .before = t.src_last[i], .after = now };
    t.src_last[i] = now;
}

/// IEEE 1364-2005 §7.11: a MOS switch passes its data's strength, so when
/// net `k`'s bit 0 changes strength alone, which no event control sees, the
/// switches reading it re-evaluate on the bits they last read
/// (`waiters.wakeSwitches`). Only they: re-running a delayed driver would
/// restart its inertial delay.
fn wakeSwitchesOn(s: *State, k: u32) Error!void {
    const t = &s.nets;
    for (t.mos_ix) |i| if (t.drivers[i].source.mos.data_net == k) if (t.mos_in[i]) |in| try mos(s, i, in[0], in[1]);
}

/// §6.5.7.1 port window driver `i`: its source's bits, z outside them.
pub fn bridge(s: *State, i: u32) Error!void {
    const t = &s.nets;
    const b = t.drivers[i].source.bridge;
    const w = t.nets[t.drivers[i].net].width;
    const planes = t.scratch[0 .. 2 * words(w)];
    fill(planes, w, .z);
    for (0..b.width) |j| {
        setBit(planes, b.dst_lo + @as(u32, @intCast(j)), shown(s, b.src_off, b.src_lo + @as(u32, @intCast(j))));
    }
    return drive(s, i, planes, false);
}

/// §19.9 `unconnected_drive` driver `i`: its level on every bit.
pub fn pull(s: *State, i: u32) Error!void {
    const t = &s.nets;
    const w = t.nets[t.drivers[i].net].width;
    const planes = t.scratch[0 .. 2 * words(w)];
    fill(planes, w, t.drivers[i].source.pull);
    return drive(s, i, planes, false);
}

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
            t.nflight[k] = s.sched.scheduleAfter(ticks, .inactive, net_base + k) catch |e| return s.timeFail(e);
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

/// Bit `at` of the value whose first word is word `off` of the planes.
pub fn shown(s: *const State, off: u32, at: u32) Int.Bit {
    const o = off + at / 64;
    const v: u2 = @intCast(s.v[o] >> @intCast(at % 64) & 1);
    const x: u2 = if (logic.two) 0 else @intCast(s.x[o] >> @intCast(at % 64) & 1);
    return @fromBackingInt(@intCast(v | x << 1));
}

/// What driver `di` asserts on bit `at` of its net (`resolution.contribution`).
pub fn contribution(t: *const Nets, di: u32, at: u32) Signal {
    const nw = words(t.nets[t.drivers[di].net].width);
    const b = bitAt(t.cur[t.at[di]..][0 .. 2 * nw], at);
    return if (t.or_z[di] and b != .z) .orZ(b, t.s0[di], t.s1[di]) else .of(b, t.s0[di], t.s1[di]);
}

/// `dnet.reach`'s and `dnet.switchPaths`'s view of the switches: the
/// `on_net` lists and the conduction held in `tstate`.
const Switches = struct {
    t: *const Nets,
    pub fn switches(g: Switches, k: u32) []const u32 {
        return g.t.on_net[k];
    }
    pub fn tran(g: Switches, ti: u32) Tran {
        return g.t.trans[ti];
    }
    pub fn conduction(g: Switches, ti: u32) dnet.Tran.State {
        return g.t.tstate[ti];
    }
};

/// `exec` `.switch_ctrl`: pass switch `i`'s control reads `c`, so it
/// conducts, does not, or may (x or z); both sides re-resolve now, or after
/// the switch's delay (`switchAfter`).
pub fn switchCtrl(s: *State, i: u32, c: Bit) Error!void {
    const t = &s.nets;
    const tr = t.trans[i];
    const cb = int(c);
    const next: dnet.Tran.State = if (cb == int(tr.on)) .on else if (cb == .zero or cb == .one) .off else .unknown;
    if (tr.delay.present) return switchAfter(s, i, next);
    t.tstate[i] = next;
    try resolve(s, tr.a);
    try resolve(s, tr.b);
}

/// `resolution.switchAfter`: a controlled switch with a delay turns on after the
/// first, off after the second, and to unknown conduction after the
/// smaller; a control that returns before its change lands cancels it.
fn switchAfter(s: *State, i: u32, next: dnet.Tran.State) Error!void {
    const t = &s.nets;
    const settled = if (t.tpending[i] != null) t.ttarget[i] else t.tstate[i];
    if (settled == next) return;
    if (t.tpending[i]) |h| _ = s.sched.cancel(h) catch |e| return s.schedFail(e);
    t.tpending[i] = null;
    if (next == t.tstate[i]) return;
    t.ttarget[i] = next;
    const to: Int.Bit = switch (next) {
        .on => .one,
        .off => .zero,
        .unknown => .x,
    };
    t.tpending[i] = s.sched.scheduleAfter(t.trans[i].delay.to(to), .inactive, tran_base + i) catch |e| return s.timeFail(e);
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
    t.decay_ev[k] = s.sched.scheduleAfter(after, .inactive, decay_base + k) catch |e| return s.timeFail(e);
}

/// `resolution.schedule`, §6.1.3's inertial rule: whether a transition to `to`
/// must be scheduled, having cancelled the one it displaces and recorded
/// `to` in `tgt`. Not when the value settles back to what is published, or
/// is what is already on its way: a pulse shorter than the delay vanishes.
fn inertial(s: *State, flight: *?Handle, tgt: []u64, tgt_or_z: *bool, from_v: []const u64, from_x: []const u64, from_or_z: bool, to: []const u64, to_or_z: bool) Error!bool {
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
    var d = root.one_slot;
    // Slot 0 is the 4-bit net at word 0; word 1 is the source: 1, z, 1, 0 from bit 3 down.
    d.v = &.{ 0, 0b1010 };
    d.x = &.{ 0, 0b0100 };
    d.nets = &.{.{ .kind = .wire, .slot = 0, .off = 0, .width = 4, .drivers = &.{0}, .strong = false }};
    d.drivers = &.{.{ .net = 0, .source = .{ .bridge = .{ .src_off = 1, .src_lo = 0, .dst_lo = 0, .width = 4 } } }};
    const s = try root.quietState(arena.allocator(), &d, -9);
    try bridge(s, 0);
    try std.testing.expectEqual(@as(u64, 0b1010), s.v[0]);
    try std.testing.expectEqual(@as(u64, 0b0100), s.x[0]);
    const want = [_]Int.Bit{ .zero, .one, .z, .one };
    for (want, 0..) |b, i| try std.testing.expectEqual(b, shown(s, 0, @intCast(i)));
}

test "§7.11 a strength-only change re-runs the MOS switch reading it, and only it: a delayed driver's transition keeps its time" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var d = root.one_slot;
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
    const s = try root.quietState(arena.allocator(), &d, -9);
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
    var d = root.one_slot;
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
    const s = try root.quietState(a, &d, -9);
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
    var d = root.one_slot;
    d.v = &.{ 0, 0 };
    d.x = &.{ 0, 0 };
    d.slots = 2;
    const paths = [_]Path{.{ .src = 1, .src_off = 1, .table = dnet.pathTable(&.{ 5, 12, 17, 10, 6, 22 }) }};
    d.nets = &.{.{ .kind = .wire, .slot = 0, .off = 0, .width = 1, .drivers = &.{}, .strong = false, .paths = &paths }};
    const s = try root.quietState(a, &d, -9);
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
