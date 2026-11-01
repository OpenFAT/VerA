//! The §7.9 tables `emit` writes for a native design (nets, their drivers, UDPs, switches, module paths) in; the resolution state a run keeps per net and per driver (`Nets`) out, allocated once at `State.initIn`.
//! Cites: IEEE 1364-2005 §7.9, §7.10, §7.11, §8, §14.3.3.
//!
//! Contents:
//! - `pub const drive_base: u32`
//! - `pub const net_base: u32`
//! - `pub const decay_base: u32`
//! - `pub const words`
//! - `pub const Net = struct`
//! - `pub const Path = struct`
//! - `pub const PathCond`
//! - `pub const Driver = struct`
//! - `pub const Source = union(enum)`
//! - `pub const Mos = struct`
//! - `pub const Bridge = struct`
//! - `pub const Udp = struct`
//! - `pub const Tran = struct`
//! - `pub const Nets = struct`
//! - `Nets.init(gpa: std.mem.Allocator, nets: []const Net, drivers: []const Driver, udps: []const Udp, trans: []const Tran) Error!Nets`
//! - `pub const tran_bit: u32`
//! - `pub const tran_base: u32`
//! - `pub const Switches = struct`
//! - `Switches.switches(g: Switches, k: u32) []const u32`
//! - `Switches.tran(g: Switches, ti: u32) Tran`
//! - `Switches.conduction(g: Switches, ti: u32) dnet.Tran.State`
//! - `Switches.fixed(g: Switches, k: u32) bool`

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
const Bit = logic.Bit;
const Signal = dnet.Signal;
const testing = std.testing;
const driving = @import("driving.zig");
const bridge = driving.bridge;
const fill = driving.fill;
const gate = driving.gate;
const int = driving.int;
const mos = driving.mos;
const pull = driving.pull;
const setBit = driving.setBit;
const udp = driving.udp;
/// `State.next` payloads: driver k's, net k's delayed transition, and net
/// k's §3.8 charge decay. All below `nba_payload`, above every pc and show.
pub const drive_base: u32 = @import("../records.zig").show_base | 1 << 28;
/// `net_base + k`: net k's delayed transition lands (`drive_base`).
pub const net_base: u32 = @import("../records.zig").show_base | 2 << 28;
/// `decay_base + k`: net k's §3.8 charge decays to x (`drive_base`).
pub const decay_base: u32 = @import("../records.zig").show_base | 3 << 28;

/// The words per plane of a `w`-bit value (`logic.words`).
pub const words = logic.words;

/// One net `resolution.resolve` folds: `Run.netlist.nets[k]` with its word offset.
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

/// One driver of a `Net`, `Run.netlist.drivers[i]` without its expression.
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
pub const Bridge = struct { src_off: u32, src_lo: u32, dst_lo: u32, width: u32, ext: u32 = 0, sign_at: ?u32 = null };

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
        // `resolution.initial`: an undriven net holds its type's pull (a
        // supply net's supply strength), which a MOS switch passes on.
        for (nets, t.sig0) |net, *sg| sg.* = if (net.kind == .trireg or net.kind == .wreal) .{} else dnet.netPull(net.kind);
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

/// `State.next` payload `tran_base + i`: pass switch i's delayed change of
/// conduction lands (`decay_base` with this bit set in its index).
pub const tran_bit: u32 = 1 << 27;

/// `tran_base + i`: pass switch i's delayed change of conduction lands.
pub const tran_base: u32 = decay_base + tran_bit;

/// `dnet.reach`'s and `dnet.switchPaths`'s view of the switches: the
/// `on_net` lists and the conduction held in `tstate`.
pub const Switches = struct {
    t: *const Nets,
    /// Returns the switches touching net `k`.
    pub fn switches(g: Switches, k: u32) []const u32 {
        return g.t.on_net[k];
    }
    /// Returns switch `ti`.
    pub fn tran(g: Switches, ti: u32) Tran {
        return g.t.trans[ti];
    }
    /// Returns switch `ti`'s conduction state now.
    pub fn conduction(g: Switches, ti: u32) dnet.Tran.State {
        return g.t.tstate[ti];
    }
    /// Returns whether net `k` is a supply the switch group cannot move.
    pub fn fixed(g: Switches, k: u32) bool {
        return switch (g.t.nets[k].kind) {
            .supply0, .supply1 => true,
            else => false, // else: every other net kind is a conductor
        };
    }
};
