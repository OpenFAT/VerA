//! Driver bits, their A.2.2.2 strengths and the net's type -> one resolved
//! four-state bit, a delay in scheduler ticks, or a gate output bit. Data and
//! pure functions only; no engine state. IEEE 1364-2005 §7.9 Tables 7-4/7-6/7-7
//! and §7.10 strength resolution, §7.8.5 gate tables (A.3.1, A.3.4), §7.6/§7.12
//! switches, §8 UDPs, §3.7 undriven values, §3.8 `trireg` charge, A.2.2.3
//! `delay3` chosen per §7.14, §6.1.3 vector and inertial delays.
//!
//! The strength fold lives in signal.zig and the gate and UDP tables in
//! gate_tables.zig; this file re-exports their names, which rt/ and the
//! emitter read as `net.<name>`.
//!
//! Contents:
//! - `pub const reduce`
//! - `pub const Signal`
//! - `pub const foldUniform`
//! - `pub const netPull`
//! - `pub const wiredLogic`
//! - `pub const undriven`
//! - `pub const Gate`
//! - `pub const gateBit`
//! - `pub const udpRows`
//! - `pub const udpEval`
//! - `pub const Inertial = struct`
//! - `pub const Delay = struct`
//! - `Delay.to(self: Delay, b: Int.Bit) u64`
//! - `Delay.continuous(self: Delay, from: Int.Bit, value: Int.Literal) u64`
//! - `pub const Bridge = struct`
//! - `pub const Net = struct`
//! - `pub const no_cold`
//! - `pub const NetCold = struct`
//! - `NetCold.none: NetCold`
//! - `pub const Path = struct`
//! - `pub const PathTable`
//! - `pub const PathEdge = struct`
//! - `pub const Mos = struct`
//! - `pub const Tran = struct`
//! - `Tran.State = enum`
//! - `pub const Node = struct`
//! - `pub const SwitchPath = struct`
//! - `pub const GateOut = struct`
//! - `pub const Slice = struct`
//! - `pub const Source = union(enum)`
//! - `pub const Driver = struct`
//! - `pub const no_transition`
//! - `pub const Wired = enum`
//! - `pub const UdpSym = union(enum)`
//! - `pub const UdpRow = struct`
//! - `pub const Udp = struct`
//! - `pub fn pathTable(d: []const u64) PathTable`
//! - `pub fn crossed(own: Signal, z: Node, y: Node, p: SwitchPath) Signal`
//! - `pub fn reach(g: anytype, a: std.mem.Allocator, from: Node) std.mem.Allocator.Error![]const Node`
//! - `pub fn switchPaths(g: anytype, a: std.mem.Allocator, y: Node, group: []const Node) std.mem.Allocator.Error![]const SwitchPath`
//! - `pub fn filled(a: std.mem.Allocator, width: u32, signed: bool, fill: Int.Bit) Error!Int.Literal`
//! - `pub fn setBit(value: Int.Literal, index: u32, b: Int.Bit) void`
//! - `pub fn planeBit(v: u64, x: u64) Int.Bit`
//! - `pub fn bitChar(b: Int.Bit) u8`
//! - `pub fn wordMask(width: u32, w: usize) u64`
//! Driver bits, their A.2.2.2 strengths and the net's type -> one resolved
//! four-state bit, a delay in scheduler ticks, or a gate output bit. Data and
//! pure functions only; no engine state. IEEE 1364-2005 §7.9 Tables 7-4/7-6/7-7
//! and §7.10 strength resolution, §7.8.5 gate tables (A.3.1, A.3.4), §7.6/§7.12
//! switches, §8 UDPs, §3.7 undriven values, §3.8 `trireg` charge, A.2.2.3
//! `delay3` chosen per §7.14, §6.1.3 vector and inertial delays.
const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const Error = @import("root.zig").Error;
const expectRun = @import("root.zig").expectRun;
const Handle = @import("../scheduler.zig").Handle;
const gate_tables = @import("gate_tables.zig");
const signal = @import("signal.zig");
const reduceSignal = signal.reduceSignal;

/// `signal.reduce`.
pub const reduce = signal.reduce;

/// `signal.Signal`.
pub const Signal = signal.Signal;

/// `signal.foldUniform`.
pub const foldUniform = signal.foldUniform;

/// `signal.netPull`.
pub const netPull = signal.netPull;

/// `signal.wiredLogic`.
pub const wiredLogic = signal.wiredLogic;

/// `signal.undriven`.
pub const undriven = signal.undriven;

/// `gate_tables.Gate`.
pub const Gate = gate_tables.Gate;

/// `gate_tables.gateBit`.
pub const gateBit = gate_tables.gateBit;

/// `gate_tables.udpRows`.
pub const udpRows = gate_tables.udpRows;

/// `gate_tables.udpEval`.
pub const udpEval = gate_tables.udpEval;

/// A driver's or net's one transition in flight. §6.1.3: a delayed continuous
/// assignment is inertial ("if the value changes before the delay has
/// elapsed, the scheduled event is cancelled"), and cancelling it is the
/// scheduler's own `cancel` on the handle kept here.
pub const Inertial = struct {
    /// The event in flight, or null when none is. Cleared when it dispatches.
    in_flight: ?Handle = null,
    /// What the event in flight will publish, meaningful only while
    /// `in_flight` is set. A re-evaluation landing on this value leaves the
    /// timer alone instead of restarting it. Sized once and reused, so a
    /// toggling input allocates nothing per transition.
    target: Int.Literal = .{ .width = 0, .sized = true, .signed = false, .planes = &.{} },
    /// When the event in flight lands, in absolute ticks; kept by a module
    /// path's destination only, whose §14.6 pulse handling reads it.
    due: u64 = 0,
    /// `target`'s §7.10.2 H/L flag, for a gate driver (see `Driver.or_z`).
    or_z: bool = false,
};

/// A.2.2.3's three values, in scheduler ticks. `present` is false for every
/// construct that names no delay: an immediate store.
pub const Delay = struct {
    rise: u64 = 0,
    fall: u64 = 0,
    off: u64 = 0,
    present: bool = false,

    /// The delay of a scalar transition to `to` (§7.14): the one for that
    /// value, and for x the smallest of the three, since x holds from the
    /// first moment any of the transitions could have begun. A vector
    /// continuous assignment uses `continuous` instead.
    pub fn to(self: Delay, b: Int.Bit) u64 {
        const ticks = switch (b) {
            .one => self.rise,
            .zero => self.fall,
            .z => self.off,
            .x => @min(self.rise, @min(self.fall, self.off)),
        };
        // x is never later than any transition it stands for.
        if (b == .x) assert(ticks <= self.rise);
        if (b == .x) assert(ticks <= self.fall);
        return ticks;
    }

    /// The delay of a continuous assignment, or of a net's own `delay3`,
    /// to `value` (§6.1.3): fall for nonzero to zero, turn-off for all z,
    /// rise otherwise. `from` is the §5.1.9 truth of the published value
    /// (the driver's, or the net's), never of a pending target. Unlike a
    /// scalar gate, a mix of x and z does not select the minimum. The one
    /// place this rule lives: both engines' drivers and nets call it.
    pub fn continuous(self: Delay, from: Int.Bit, value: Int.Literal) u64 {
        assert(value.width != 0);
        if (value.width == 1) return self.to(value.bit(0));
        // z is (value 0, unknown 1): one plane word tests 64 bits.
        const all_z = for (0..(value.width + 63) / 64) |w| {
            const m = wordMask(value.width, w);
            if (value.unknowns()[w] & ~value.values()[w] & m != m) break false;
        } else true;
        if (all_z) return self.off;
        if (from == .one and value.truth() == .zero) return self.fall;
        assert(value.width > 1);
        return self.rise;
    }
};

/// §6.5.7.1's "vector port ... connected to a ... concatenated net expression
/// of the matching width", the half of a port connection that cannot be a net
/// collapse: `width` bits starting at `src_lo` of one slot are carried onto
/// `dst_lo` of another net. Everything outside that window is z, which is the
/// identity of §7.9's resolution, so a window is an ordinary driver that
/// happens to assert only part of the net. `ext` bits above the window are
/// IEEE 1364-2005 §12.3.9.2's widening of a port narrower than what it
/// drives (the connection is a continuous assignment, §5.6): copies of
/// source bit `sign_at` (a signed port's top bit), or 0.
pub const Bridge = struct { src: u32, src_lo: u32, dst_lo: u32, width: u32, ext: u32 = 0, sign_at: ?u32 = null };

/// §7.9 one net: its resolution function, its storage, and the drivers whose
/// wired-logic combination is its value. `resolved` is the scratch the fold
/// writes before publishing through `store`, sized once at setup.
///
/// The hot row every resolution reads; what only a delayed net, a `trireg`
/// or a pass-switch terminal has is its `NetCold` row. Most nets have none,
/// and an unpacked net array is one `Net` per element (§4.9.1), so the split
/// is what keeps a large array's footprint at this row's 48 bytes an element
/// instead of 184. Its drivers are a run of `Run.netlist.driver_ids`
/// (`Run.netDrivers`) and its per-bit signals a run of `Run.netlist.signals`, so the
/// row holds no slice but `resolved`'s.
pub const Net = struct {
    kind: Ast.NetKind,
    slot: u32,
    resolved: Int.Literal,
    /// The declaring token, for a verdict reached after elaboration (§7.9's
    /// `uwire` driver count).
    tok: u32 = 0,
    /// This net's row in `Run.netlist.cold`, or `no_cold` when every field there
    /// would be its default.
    cold: u32 = no_cold,
    /// A.2.1.3 `charge_strength`, the level the stored charge of a `trireg` in
    /// the capacitive state asserts. `medium` is §3.8's default and is ignored
    /// outright by every other net type.
    charge: Ast.Strength = .medium,
    /// Whether the last resolution found no driver asserting anything, which is
    /// §3.8's capacitive state. The decay countdown restarts on each entry into
    /// it, so the transition is what is watched, not the state.
    capacitive: bool = false,
    /// A MOS switch's data terminal or a `%v` (§17.1.1.5) reads this net's `signal`.
    strength_read: bool = false,
    /// The first of this net's entries in `Run.netlist.signals`, one per declared bit
    /// (a wreal promoted to 64 bits keeps its declared count; it never
    /// folds). Per bit, the §7.10 signal the last resolution found, whose
    /// strength a MOS switch reading this net passes on (§7.12). Kept current
    /// only where `strength_read` or the net resolves through a fold.
    signal: u32 = 0,

    // Budget: one row per net array element (§4.9.1), so every 8 bytes here
    // is 8 MiB on a 2^20-element net array.
    comptime {
        std.debug.assert(@sizeOf(Net) <= 48);
    }
};

/// `Net.cold` of a net with no cold row.
pub const no_cold = std.math.maxInt(u32);

/// A net's cold fields, for the nets that have any (`Net.cold`).
pub const NetCold = struct {
    /// A.2.1.3 `[ delay3 ]` on the declaration, applied to the resolved value.
    delay: Delay = .{},
    transition: Inertial = .{},
    /// A.2.1.3's third `delay3` value on a `trireg`: how long the capacitive
    /// state may last before the charge is worth nothing. `null` (a `trireg`
    /// with no `delay3`) is §3.8's indefinite hold.
    decay: ?u64 = null,
    /// The §3.8 decay countdown in flight, cancelled on leaving the state.
    decay_event: ?Handle = null,
    /// The §7.6 pass switches with this net as a terminal.
    trans: []const u32 = &.{},
    /// IEEE 1364-2005 §14.3 the module paths into this net, which time its
    /// transitions in place of `delay` (`resolution.pathDelay`).
    /// Mutable: `$sdf_annotate` rewrites a row's `table` (`sdf.zig`).
    paths: []Path = &.{},
    /// §14.6.4.1 `pulsestyle_ondetect` (else on-event) and §14.6.4.2
    /// `showcancelled` (else noshowcancelled) on this path destination.
    ondetect: bool = false,
    showcancelled: bool = false,

    /// Every field at its default: the row of a net with none.
    pub const none: NetCold = .{};
};

/// IEEE 1364-2005 §14.2 one module path into a net, from bit `src_bit` of
/// source slot `src` (an input or inout port; §14.2.3 reads an edge on the
/// least significant bit, or the bit a bit-select names). `edge` makes it an
/// edge-sensitive path (§14.2.3), `cond` a state-dependent one (§14.2.4),
/// evaluated in `scope`, and `ifnone` the default of the state-dependent
/// paths from the same source (§14.2.4.4). `table` is its delay for each
/// transition of the destination (`pathTable`).
pub const Path = struct {
    src: u32,
    src_bit: u32 = 0,
    edge: Ast.SpecEdge = .none,
    cond: Ast.ExprId = .none,
    ifnone: bool = false,
    scope: u32 = 0,
    table: PathTable,
    /// The A.7.4 delay expressions `table` was folded from, re-folded when an
    /// SDF LABEL changes a specparam they read (§16.2.3), and their token.
    delays: []const Ast.ExprId = &.{},
    tok: u32 = 0,
    /// §14.6.1 its reject and error limits in ticks, from a `PATHPULSE$`
    /// specparam or an SDF PATHPULSE; null is the default, the delay of the
    /// transition being scheduled.
    reject: ?u64 = null,
    err: ?u64 = null,
};

/// A module path's delay for each destination transition, `[from][to]`
/// indexed by `Int.Bit`'s backing integer. The diagonal is never read.
pub const PathTable = [4][4]u64;

/// The last transition of a module path source (`Run.netlist.path_changed`): when,
/// and its low 64 bits before and after, values then unknowns.
pub const PathEdge = struct { time: u64, before: [2]u64, after: [2]u64 };

/// §7.6 one MOS switch (half of a CMOS one, §7.7): it passes `data`, value
/// and strength, to its output while `gate` holds the conducting value (1
/// for an n-type, 0 for a p-type), and is off otherwise.
///
/// One member of a §7.1.5 instance array reads bit `lane` of a data or gate
/// terminal wider than one bit (§7.1.6) and drives bit `out_bit` of a vector
/// output net, as `Gate` does.
pub const Mos = struct { data: Ast.ExprId, gate: Ast.ExprId, n_type: bool, resistive: bool, lane: ?u32 = null, out_bit: ?u32 = null };

/// §7.6 one pass switch between bit `a_bit` of net `a` and bit `b_bit` of
/// net `b` ("scalar nets or bit-selects of vector nets"): always on (`tran`),
/// or on while `ctrl` equals `on` (`tranif1`: 1, `tranif0`: 0) and of
/// unknown conduction while it is x or z. A resistive one reduces what it
/// passes by §7.12. `delay` is the turn-on (`rise`) and turn-off (`fall`)
/// delay of a controlled one; `target` is the state in flight.
pub const Tran = struct {
    a: u32,
    b: u32,
    a_bit: u32 = 0,
    b_bit: u32 = 0,
    ctrl: Ast.ExprId = .none,
    on: Int.Bit = .one,
    state: State = .on,
    resistive: bool = false,
    delay: Delay = .{},
    target: State = .on,
    pending: ?Handle = null,

    /// Whether the switch conducts: `on` or `off` by its control's value,
    /// `unknown` while the control is x or z.
    pub const State = enum { on, off, unknown };
};

/// One bit of one net, as a pass switch terminal sees it.
pub const Node = struct { net: u32, bit: u32 };

/// From a group member to `y`: the fewest resistive switches on a path that
/// may conduct, and whether some path surely does.
pub const SwitchPath = struct { res: u32, sure: bool };

/// One gate evaluation: §7.8.5's output bit, and whether it is §7.10.2's H/L
/// (`bit` or high impedance) rather than `bit` itself.
pub const GateOut = struct { bit: Int.Bit, or_z: bool = false };

/// A window of a wider value: bits [lo, lo + the receiver's width) of it read
/// `total` bits wide.
pub const Slice = struct { lo: u32, total: u32 };

/// What one driver asserts, decided at elaboration: exactly one source.
pub const Source = union(enum) {
    /// A.6.1 an expression. With `slice`, it is read `total` bits wide and the
    /// driver asserts the bits from `lo` up: one internal port of a §12.3.6
    /// concatenated port.
    expr: struct { e: Ast.ExprId, slice: ?Slice = null },
    /// A port connection that cannot collapse (`Bridge`).
    bridge: Bridge,
    /// An A.3.1 gate instance. A gate is a driver (§7.1) but not an
    /// expression: §7.8.5's tables read z on an input as x, which no operator
    /// does.
    gate: Gate,
    /// An IEEE 1364-2005 §8 UDP instance.
    udp: *Udp,
    /// A §7.6 MOS switch, whose `s0`/`s1` are the strengths it passes, set at
    /// each evaluation.
    mos: Mos,
    /// §19.9 `unconnected_drive`: a pull-strength driver of an unconnected
    /// input port, resolved against the net's own type through `Signal` like
    /// any other. A constant with an empty sensitivity list: it is evaluated
    /// once, at the initial `.continuous` dispatch.
    pull: Int.Bit,
};

/// §6.1 one driver. It keeps its own value (the net's is the resolution of
/// all of them) and re-evaluates whenever one of its operands changes.
/// `s0`/`s1` are A.2.2.2's `drive_strength`, a property of the driver, not
/// of the value it holds.
pub const Driver = struct {
    net: u32,
    source: Source,
    /// The §6.2.2 instance the source is written in. A port connection
    /// expression belongs to the parent, not to the scope of the net it feeds.
    scope: u32 = 0,
    sensitivity: []const u32,
    current: Int.Literal,
    /// A gate's `current` is §7.10.2's H/L: its one bit, or high impedance.
    or_z: bool = false,
    s0: Ast.Strength = .strong,
    s1: Ast.Strength = .strong,
    /// A.6.1 `[ delay3 ]`.
    delay: Delay = .{},
    /// This driver's row in `Run.netlist.transitions`, made the first time a delay
    /// holds its value back (`Run.driverTransition`), or `no_transition`:
    /// most drivers never have one, so the 40-byte `Inertial` is out of line.
    transition: u32 = no_transition,
    /// The statement's main token: with `scope`, the identity a VPI
    /// application's §12.29 vpi_put_delays reaches this driver by.
    tok: u32 = 0,

    // Budget: one row per continuous assignment, gate, switch and port
    // window. `src/vpi` reads `tok`, `scope`, `current` and `delay`.
    comptime {
        std.debug.assert(@sizeOf(Driver) <= 144);
    }
};

/// `Driver.transition` of a driver no delay has held back yet.
pub const no_transition = std.math.maxInt(u32);

/// The two §7.9 value tables a wired-logic net folds its drivers through:
/// wired AND (`wand`, `triand`) and wired OR (`wor`, `trior`).
pub const Wired = enum { @"and", @"or" };

/// One A.5.3 input field: a level symbol (`0 1 x ? b`), a parenthesized edge
/// `(vw)`, or one of Table 8-1's edge letters (`r f p n *`).
pub const UdpSym = union(enum) { level: u8, pair: [2]u8, letter: u8 };

/// One table entry, split into fields. `edge_at` is the input its edge is on,
/// null for a level entry; `state` is 0 in a combinational table.
pub const UdpRow = struct { ins: []const UdpSym, state: u8, out: u8, edge_at: ?u32 };

/// §8 one UDP instance as a driver: its table, its input terminals, and what
/// a sequential one carries between events: the input values the table last
/// saw (an event is a change from these) and its state, the output reg.
pub const Udp = struct {
    rows: []const UdpRow,
    sequential: bool,
    ins: []const Ast.ExprId,
    prev: []Int.Bit,
    state: Int.Bit,
    /// Whether the driver has published once; §8.5's initial value is
    /// published at time 0 whatever the instance delay.
    started: bool = false,
    /// IEEE 1364-2005 §8.6 one instance of an array: the bit of a vector
    /// input it reads (as `Gate.lane`), and the output bit it drives.
    lane: ?u32 = null,
    out_bit: ?u32 = null,
};

comptime {
    // `Gate` is `Source`'s widest arm: its two `?u32` (8 bytes each) set
    // the 48-byte `Source` inside `Driver`.
    std.debug.assert(@sizeOf(Gate) <= 40);
    std.debug.assert(@sizeOf(Source) <= 48);
}

/// IEEE 1364-2005 §14.3.1 Table 14-2: the delay for each transition from a
/// path's 1, 2, 3, 6 or 12 values, and for the x transitions §14.3.2's
/// Table 14-3 where fewer than 12 are given: "Transitions from a known state
/// to x shall occur as quickly as possible", "from x to a known state shall
/// take as long as possible".
pub fn pathTable(d: []const u64) PathTable {
    std.debug.assert(d.len == 1 or d.len == 2 or d.len == 3 or d.len == 6 or d.len == 12);
    const t01, const t10, const t0z, const tz1, const t1z, const tz0 = switch (d.len) {
        1 => .{ d[0], d[0], d[0], d[0], d[0], d[0] },
        2 => .{ d[0], d[1], d[0], d[0], d[1], d[1] },
        3 => .{ d[0], d[1], d[2], d[0], d[2], d[1] },
        else => .{ d[0], d[1], d[2], d[3], d[4], d[5] }, // else: the 6 and 12 forms name these six first
    };
    const zero = @backingInt(Int.Bit.zero);
    const one = @backingInt(Int.Bit.one);
    const z = @backingInt(Int.Bit.z);
    const x = @backingInt(Int.Bit.x);
    var t: PathTable = @splat(@splat(0));
    t[zero][one] = t01;
    t[one][zero] = t10;
    t[zero][z] = t0z;
    t[z][one] = tz1;
    t[one][z] = t1z;
    t[z][zero] = tz0;
    assert(t[zero][zero] == 0); // No transition takes no time.
    if (d.len == 12) {
        t[zero][x] = d[6];
        t[x][one] = d[7];
        t[one][x] = d[8];
        t[x][zero] = d[9];
        t[x][z] = d[10];
        t[z][x] = d[11];
    } else {
        t[zero][x] = @min(t0z, t01);
        t[one][x] = @min(t1z, t10);
        t[z][x] = @min(tz1, tz0);
        t[x][zero] = @max(tz0, t10);
        t[x][one] = @max(tz1, t01);
        t[x][z] = @max(t1z, t0z);
        // §14.3.2: to x as quickly as possible, from x as long as possible.
        assert(t[zero][x] <= t01);
        assert(t[x][one] >= t01);
    }
    return t;
}

/// What `own`, asserted at group member `z`, asserts at `y` over path `p`:
/// reduced by the switches it crosses, and widened to include high impedance
/// when no path surely conducts (§7.10.2).
pub fn crossed(own: Signal, z: Node, y: Node, p: SwitchPath) Signal {
    assert(p.res != std.math.maxInt(u32)); // `z` reaches `y`.
    const sig = reduceSignal(own, @intFromBool(!std.meta.eql(z, y)), p.res);
    if (p.sure) assert(p.res <= std.math.maxInt(u32) - 1);
    return if (p.sure or sig.none()) sig else .{ .lo = @min(sig.lo, 0), .hi = @max(sig.hi, 0) };
}

/// The net bits joined to `from` through pass switches that may conduct.
/// A supply net (`g.fixed`) is a member but no conductor: its value is its
/// own (§4.6.6, nothing outranks supply strength), so a signal does not cross
/// it from one switch to another, and two groups sharing `vdd` stay two
/// (iverilog agrees: ivtest br_gh1122's CMOS NOR then inverter). A supply
/// net's own group is itself: its neighbours resolve from their side.
pub fn reach(g: anytype, a: std.mem.Allocator, from: Node) std.mem.Allocator.Error![]const Node {
    var seen: std.ArrayList(Node) = .empty;
    try seen.append(a, from);
    var i: usize = 0;
    while (i < seen.items.len) : (i += 1) {
        assert(i < seen.items.len); // Each node is visited once: `seen` has no duplicates.
        const u = seen.items[i];
        if (g.fixed(u.net)) continue;
        for (g.switches(u.net)) |ti| {
            if (g.conduction(ti) == .off) continue;
            const v = across(g.tran(ti), u) orelse continue;
            for (seen.items) |w| {
                if (std.meta.eql(w, v)) break;
            } else try seen.append(a, v);
        }
    }
    assert(std.meta.eql(seen.items[0], from));
    return seen.items;
}

/// From each member of `group` to `y`, its `SwitchPath`.
pub fn switchPaths(g: anytype, a: std.mem.Allocator, y: Node, group: []const Node) std.mem.Allocator.Error![]const SwitchPath {
    assert(group.len != 0);
    const p = try a.alloc(SwitchPath, group.len);
    @memset(p, .{ .res = std.math.maxInt(u32), .sure = false });
    for (group, p) |u, *q| if (std.meta.eql(u, y)) {
        q.* = .{ .res = 0, .sure = true };
    };
    // Each pass lowers some `res` or sets some `sure`, so the passes are
    // bounded by the members times (the longest path plus one).
    const passes_max = group.len * (group.len + 2) + 1;
    var passes: usize = 0;
    var changed = true;
    while (changed) : (passes += 1) {
        assert(passes <= passes_max);
        changed = false;
        for (group, 0..) |u, iu| {
            if (p[iu].res == std.math.maxInt(u32)) continue;
            // `reach`: a path does not run through a supply net.
            if (!std.meta.eql(u, y) and g.fixed(u.net)) continue;
            for (g.switches(u.net)) |ti| {
                const st = g.conduction(ti);
                if (st == .off) continue;
                const tr = g.tran(ti);
                const v = across(tr, u) orelse continue;
                const iv = for (group, 0..) |w, k| {
                    if (std.meta.eql(w, v)) break k;
                } else continue;
                const res = p[iu].res + @intFromBool(tr.resistive);
                if (res < p[iv].res) {
                    p[iv].res = res;
                    changed = true;
                }
                if (p[iu].sure and st == .on and !p[iv].sure) {
                    p[iv].sure = true;
                    changed = true;
                }
            }
        }
    }
    assert(p.len == group.len);
    return p;
}

/// A four-state value of `width` bits, every bit `fill`: where declared state
/// gets its starting value, X for a variable and Z for an undriven net (§3.7).
/// The caller owns the result, allocated from `a`. `width` must be at least 1.
pub fn filled(a: std.mem.Allocator, width: u32, signed: bool, fill: Int.Bit) Error!Int.Literal {
    assert(width >= 1);
    const words = (@as(usize, width) - 1) / 64 + 1;
    const planes = try a.alloc(u64, words * 2);
    @memset(planes[0..words], if (@backingInt(fill) & 1 != 0) std.math.maxInt(u64) else 0);
    @memset(planes[words..], if (@backingInt(fill) >> 1 != 0) std.math.maxInt(u64) else 0);
    const tail: u6 = @truncate(width);
    if (tail != 0) {
        const keep = (@as(u64, 1) << tail) - 1;
        planes[words - 1] &= keep;
        planes[2 * words - 1] &= keep;
    }
    assert(planes.len == 2 * words);
    return .{ .width = width, .signed = signed, .sized = true, .planes = planes };
}

/// Write one packed bit. The read side is `Int.Literal.bit`; only the §7.9
/// resolution fold writes bit by bit. `index` must be below `value.width`.
pub fn setBit(value: Int.Literal, index: u32, b: Int.Bit) void {
    // Branchless: the per-bit resolution fold calls this with data-dependent
    // bits, so the plane bits are blended in rather than chosen by `if`.
    // rt's resolution writes into bare planes (`width` 0), so the bound is
    // the planes', not the width's.
    assert(index / 64 < value.planes.len / 2);
    const sh: u6 = @truncate(index);
    const word = index / 64;
    const bits: u64 = @backingInt(b);
    const v = &value.values()[word];
    const u = &value.unknowns()[word];
    v.* = (v.* & ~(@as(u64, 1) << sh)) | ((bits & 1) << sh);
    u.* = (u.* & ~(@as(u64, 1) << sh)) | ((bits >> 1) << sh);
    assert(planeBit(v.* >> sh, u.* >> sh) == b); // Pair of `planeBit`.
}

/// The bit whose value-plane bit is bit 0 of `v` and unknown-plane bit bit 0
/// of `x`: the read side of a (values, unknowns) word pair such as
/// `waiters.termBits` returns. Higher bits are ignored.
pub fn planeBit(v: u64, x: u64) Int.Bit {
    comptime assert(@backingInt(Int.Bit.z) == 2); // (v, x) = 01 is z, 11 is x.
    return @fromBackingInt(@as(u2, @truncate(v & 1)) | @as(u2, @truncate(x & 1)) << 1);
}

/// `b` as the character §18.2.1 and §15.4's edge descriptors write it: `0`, `1`, `z`
/// or `x`. A table load indexed by the encoding, so a vector's digits are
/// written without a branch per bit.
pub fn bitChar(b: Int.Bit) u8 {
    comptime assert(@backingInt(Int.Bit.x) == 3);
    return "01zx"[@backingInt(b)];
}

/// The bits of plane word `w` that lie inside a `width`-bit value; the ones
/// above it carry nothing and may hold anything. `w * 64` must not exceed
/// `width`.
pub fn wordMask(width: u32, w: usize) u64 {
    assert(w * 64 < width or (w == 0 and width == 0));
    const rest = width - @as(u32, @intCast(w * 64));
    return if (rest >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(rest)) - 1;
}

// ---- private ----

/// The terminal of switch `tr` across from `u`, or null when `u` is neither.
fn across(tr: anytype, u: Node) ?Node {
    assert(!(tr.a == tr.b and tr.a_bit == tr.b_bit)); // A switch joins two terminals.
    if (tr.a == u.net and tr.a_bit == u.bit) return .{ .net = tr.b, .bit = tr.b_bit };
    if (tr.b == u.net and tr.b_bit == u.bit) return .{ .net = tr.a, .bit = tr.a_bit };
    return null;
}

test "continuous vector delay audit_assignment_vector_delay" {
    try expectRun(
        \\// IEEE1364-2005 §6.1.3: vector nonzero-to-nonzero uses rising delay,
        \\// even if one bit falls. Whole-vector transition to zero uses falling delay;
        \\// all-z uses turnoff. Samples deliberately avoid exact update-time races.
        \\//! inherited IEEE 1364-2005 6.1.3
        \\`timescale 1ns/1ns
        \\module audit_assignment_vector_delay;
        \\  reg [1:0] a;
        \\  wire [1:0] y;
        \\  assign #(2,7,4) y = a;
        \\  initial begin
        \\    a = 0;
        \\    #10 a = 1;
        \\    #3 $display("nonzero=%b", y);
        \\    a = 2;
        \\    #3 $display("nonzero_to_nonzero=%b", y);
        \\    a = 0;
        \\    #6 $display("before_fall=%b", y);
        \\    #2 $display("after_fall=%b", y);
        \\    a = 2'bzz;
        \\    #3 $display("before_turnoff=%b", y);
        \\    #2 $display("after_turnoff=%b", y);
        \\    $finish(0);
        \\  end
        \\endmodule
    ,
        \\nonzero=01
        \\nonzero_to_nonzero=10
        \\before_fall=10
        \\after_fall=00
        \\before_turnoff=00
        \\after_turnoff=zz
        \\
    );
}

test "continuous vector delay audit_assignment_vector_delay_unknown" {
    try expectRun(
        \\// IEEE1364-2005 §6.1.3: vector transitions other than nonzero->zero
        \\// and all-z use rising delay. Mixed x/z is not all-z; unlike scalar gates,
        \\// a vector transition to x does not select the minimum delay.
        \\// #(7,5,2): start00; at10 assign0x -> due17; at19 assign1z -> due26;
        \\// at28 assignzz -> due30. Samples avoid update instants.
        \\//! inherited IEEE 1364-2005 6.1.3
        \\`timescale 1ns/1ns
        \\module audit_assignment_vector_delay_unknown;
        \\  reg [1:0] a;
        \\  wire [1:0] y;
        \\  assign #(7,5,2) y = a;
        \\  initial begin
        \\    a = 0;
        \\    #10 a = 2'b0x;
        \\    #3 $display("before_x=%b", y);
        \\    #5 $display("after_x=%b", y);
        \\    #1 a = 2'b1z;
        \\    #3 $display("before_mixed_z=%b", y);
        \\    #5 $display("after_mixed_z=%b", y);
        \\    #1 a = 2'bzz;
        \\    #1 $display("before_all_z=%b", y);
        \\    #2 $display("after_all_z=%b", y);
        \\    $finish(0);
        \\  end
        \\endmodule
    ,
        \\before_x=00
        \\after_x=0x
        \\before_mixed_z=0x
        \\after_mixed_z=1z
        \\before_all_z=1z
        \\after_all_z=zz
        \\
    );
}

test "continuous vector delay examines upper limbs and keeps scalar selection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const zero = try filled(arena.allocator(), 129, false, .zero);
    const high = try filled(arena.allocator(), 129, false, .zero);
    setBit(high, 128, .one);
    const off = try filled(arena.allocator(), 129, false, .z);
    const mixed = try filled(arena.allocator(), 129, false, .z);
    setBit(mixed, 128, .x);
    const delay = Delay{ .rise = 7, .fall = 5, .off = 2, .present = true };
    try std.testing.expectEqual(@as(u64, 7), delay.continuous(zero.truth(), high));
    try std.testing.expectEqual(@as(u64, 5), delay.continuous(high.truth(), zero));
    try std.testing.expectEqual(@as(u64, 2), delay.continuous(high.truth(), off));
    try std.testing.expectEqual(@as(u64, 7), delay.continuous(high.truth(), mixed));
    for ([_]Int.Bit{ .zero, .one, .x, .z }) |bit| {
        const scalar = try filled(arena.allocator(), 1, false, bit);
        try std.testing.expectEqual(delay.to(bit), delay.continuous(scalar.truth(), scalar));
    }
}

test "setBit writes what Literal.bit and planeBit read back, and leaves the other bits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bits = [_]Int.Bit{ .zero, .one, .z, .x };
    for (bits) |fill| for (bits) |b| for ([_]u32{ 0, 63, 64, 69 }) |at| {
        const v = try filled(arena.allocator(), 70, false, fill);
        setBit(v, at, b);
        try std.testing.expectEqual(b, v.bit(at));
        try std.testing.expectEqual(b, planeBit(v.values()[at / 64] >> @intCast(at % 64), v.unknowns()[at / 64] >> @intCast(at % 64)));
        for (0..70) |i| if (i != at) try std.testing.expectEqual(fill, v.bit(@intCast(i)));
    };
    // §18.2.1 Table 18-1's characters, by name.
    for (bits, [_]u8{ '0', '1', 'z', 'x' }) |b, ch| try std.testing.expectEqual(ch, bitChar(b));
}

test Delay {
    // §7.14: a transition to 1 takes the rise delay, to 0 the fall delay, to
    // z the turn-off delay, and to x the smallest of the three.
    const d: Delay = .{ .rise = 3, .fall = 5, .off = 4, .present = true };
    try std.testing.expectEqual(@as(u64, 3), d.to(.one));
    try std.testing.expectEqual(@as(u64, 5), d.to(.zero));
    try std.testing.expectEqual(@as(u64, 4), d.to(.z));
    try std.testing.expectEqual(@as(u64, 3), d.to(.x));
    const e: Delay = .{ .rise = 9, .fall = 2, .off = 7, .present = true };
    try std.testing.expectEqual(@as(u64, 2), e.to(.x));
}

test filled {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]u32{ 1, 63, 64, 65, 128, 129 }) |w| for ([_]Int.Bit{ .zero, .one, .z, .x }) |fill| {
        const v = try filled(a, w, true, fill);
        try std.testing.expectEqual(w, v.width);
        try std.testing.expect(v.signed and v.sized);
        try std.testing.expectEqual(@as(usize, ((w - 1) / 64 + 1) * 2), v.planes.len);
        for (0..w) |i| try std.testing.expectEqual(fill, v.bit(@intCast(i)));
        // The bits above the width are zero in both planes, so two values
        // compare with `std.mem.eql` (`waiters.store`).
        const last = v.values().len - 1;
        try std.testing.expectEqual(@as(u64, 0), v.values()[last] & ~wordMask(w, last));
        try std.testing.expectEqual(@as(u64, 0), v.unknowns()[last] & ~wordMask(w, last));
    };
}

test setBit {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try filled(arena.allocator(), 130, false, .zero);
    setBit(v, 129, .x);
    setBit(v, 64, .one);
    setBit(v, 63, .z);
    try std.testing.expectEqual(Int.Bit.x, v.bit(129));
    try std.testing.expectEqual(Int.Bit.one, v.bit(64));
    try std.testing.expectEqual(Int.Bit.z, v.bit(63));
    // A write leaves its neighbours alone, and a later one replaces it.
    try std.testing.expectEqual(Int.Bit.zero, v.bit(128));
    try std.testing.expectEqual(Int.Bit.zero, v.bit(65));
    try std.testing.expectEqual(Int.Bit.zero, v.bit(62));
    setBit(v, 129, .zero);
    try std.testing.expectEqual(Int.Bit.zero, v.bit(129));
}

test wordMask {
    try std.testing.expectEqual(~@as(u64, 0), wordMask(64, 0));
    try std.testing.expectEqual(~@as(u64, 0), wordMask(128, 1));
    try std.testing.expectEqual(@as(u64, 1), wordMask(1, 0));
    try std.testing.expectEqual(@as(u64, 1), wordMask(65, 1));
    try std.testing.expectEqual((@as(u64, 1) << 36) - 1, wordMask(100, 1));
}

test "§14.3.2 Table 14-3's usage row: (5, 12, 17, 10, 6, 22) gives the x transitions 5, 6, 10, 22, 10, 17" {
    const t = pathTable(&.{ 5, 12, 17, 10, 6, 22 });
    const zero = @backingInt(Int.Bit.zero);
    const one = @backingInt(Int.Bit.one);
    const z = @backingInt(Int.Bit.z);
    const x = @backingInt(Int.Bit.x);
    try std.testing.expectEqual(@as(u64, 5), t[zero][x]);
    try std.testing.expectEqual(@as(u64, 6), t[one][x]);
    try std.testing.expectEqual(@as(u64, 10), t[z][x]);
    try std.testing.expectEqual(@as(u64, 22), t[x][zero]);
    try std.testing.expectEqual(@as(u64, 10), t[x][one]);
    try std.testing.expectEqual(@as(u64, 17), t[x][z]);
}

test "§14.3.1 Table 14-2: two values are rise and fall, three add tz, twelve name every transition" {
    const zero = @backingInt(Int.Bit.zero);
    const one = @backingInt(Int.Bit.one);
    const z = @backingInt(Int.Bit.z);
    const x = @backingInt(Int.Bit.x);
    const two = pathTable(&.{ 6, 9 });
    try std.testing.expectEqual([4]u64{ 6, 9, 6, 9 }, [4]u64{ two[zero][one], two[one][zero], two[zero][z], two[one][z] });
    const three = pathTable(&.{ 1, 2, 3 });
    try std.testing.expectEqual([6]u64{ 1, 2, 3, 1, 3, 2 }, [6]u64{ three[zero][one], three[one][zero], three[zero][z], three[z][one], three[one][z], three[z][zero] });
    const twelve = pathTable(&.{ 10, 12, 14, 15, 29, 36, 14, 15, 15, 14, 20, 30 });
    try std.testing.expectEqual([6]u64{ 14, 15, 15, 14, 20, 30 }, [6]u64{ twelve[zero][x], twelve[x][one], twelve[one][x], twelve[x][zero], twelve[x][z], twelve[z][x] });
}
