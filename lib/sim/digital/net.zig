//! Driver bits, their A.2.2.2 strengths and the net's type -> one resolved
//! four-state bit, a delay in scheduler ticks, or a gate output bit. Data and
//! pure functions only; no engine state. IEEE 1364-2005 §7.9 Tables 7-4/7-6/7-7
//! and §7.10 strength resolution, §7.8.5 gate tables (A.3.1, A.3.4), §7.6/§7.12
//! switches, §8 UDPs, §3.7 undriven values, §3.8 `trireg` charge, A.2.2.3
//! `delay3` chosen per §7.14, §6.1.3 vector and inertial delays.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const Error = @import("root.zig").Error;
const expectRun = @import("root.zig").expectRun;
const Handle = @import("../scheduler.zig").Handle;

// ---- delays (A.2.2.3, §7.14, §6.1.3) ----------------------------------------

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
        return switch (b) {
            .one => self.rise,
            .zero => self.fall,
            .z => self.off,
            .x => @min(self.rise, @min(self.fall, self.off)),
        };
    }

    /// The delay of a continuous assignment, or of a net's own `delay3`,
    /// to `value` (§6.1.3): fall for nonzero to zero, turn-off for all z,
    /// rise otherwise. `from` is the §5.1.9 truth of the published value
    /// (the driver's, or the net's), never of a pending target. Unlike a
    /// scalar gate, a mix of x and z does not select the minimum. The one
    /// place this rule lives: both engines' drivers and nets call it.
    pub fn continuous(self: Delay, from: Int.Bit, value: Int.Literal) u64 {
        if (value.width == 1) return self.to(value.bit(0));
        // z is (value 0, unknown 1): one plane word tests 64 bits.
        const all_z = for (0..(value.width + 63) / 64) |w| {
            const m = wordMask(value.width, w);
            if (value.unknowns()[w] & ~value.values()[w] & m != m) break false;
        } else true;
        if (all_z) return self.off;
        if (from == .one and value.truth() == .zero) return self.fall;
        return self.rise;
    }
};

// ---- nets, drivers and gates (§7.9, §6.1, §7.8.5, A.3.1) --------------------

/// §6.5.7.1's "vector port ... connected to a ... concatenated net expression
/// of the matching width", the half of a port connection that cannot be a net
/// collapse: `width` bits starting at `src_lo` of one slot are carried onto
/// `dst_lo` of another net. Everything outside that window is z, which is the
/// identity of §7.9's resolution, so a window is an ordinary driver that
/// happens to assert only part of the net.
pub const Bridge = struct { src: u32, src_lo: u32, dst_lo: u32, width: u32 };

/// §7.9 one net: its resolution function, its storage, and the drivers whose
/// wired-logic combination is its value. `resolved` is the scratch the fold
/// writes before publishing through `store`, sized once at setup.
///
/// The hot row every resolution reads; what only a delayed net, a `trireg`
/// or a pass-switch terminal has is its `NetCold` row. Most nets have none,
/// and an unpacked net array is one `Net` per element (§4.9.1), so the split
/// is what keeps a large array's footprint at this row's 48 bytes an element
/// instead of 184. Its drivers are a run of `Run.net_drivers`
/// (`Run.netDrivers`) and its per-bit signals a run of `Run.signals`, so the
/// row holds no slice but `resolved`'s.
pub const Net = struct {
    kind: Ast.NetKind,
    slot: u32,
    resolved: Int.Literal,
    /// The declaring token, for a verdict reached after elaboration (§7.9's
    /// `uwire` driver count).
    tok: u32 = 0,
    /// This net's row in `Run.net_cold`, or `no_cold` when every field there
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
    /// The first of this net's entries in `Run.signals`, one per declared bit
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
    paths: []const Path = &.{},

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
};

/// A module path's delay for each destination transition, `[from][to]`
/// indexed by `Int.Bit`'s backing integer. The diagonal is never read.
pub const PathTable = [4][4]u64;

/// The last transition of a module path source (`Run.path_changed`): when,
/// and its low 64 bits before and after, values then unknowns.
pub const PathEdge = struct { time: u64, before: [2]u64, after: [2]u64 };

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
    }
    return t;
}

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

/// §7.11/§7.12 a signal that crossed `hops` pass switches, `resistive` of
/// them resistive: supply becomes strong at the first switch, and each
/// resistive one reduces by Table 7-8.
fn reduceSignal(sig: Signal, hops: u32, resistive: u32) Signal {
    if (hops == 0) return sig;
    const one = struct {
        fn side(v: i8, k: u32) i8 {
            var s = reduce(@fromBackingInt(@intCast(@abs(v))), false);
            for (0..k) |_| s = reduce(s, true);
            const m: i8 = @intCast(@backingInt(s));
            return if (v < 0) -m else m;
        }
    };
    return .{ .lo = one.side(sig.lo, resistive), .hi = one.side(sig.hi, resistive) };
}

// ---- switch paths (§7.6, §7.11, §7.12, §8.5.3.5) ----------------------------
//
// The joined-group search both resolutions run (`resolution.resolveJoined`,
// `rt/net.zig`'s `resolveJoined`). It lives here because this is the one
// file both already import: in `rt/net.zig` the interpreter's
// `resolution.zig` would reach it through `rt/root.zig` -> `digital/root.zig`,
// a file cycle. The two differ only in where a switch's conduction and a
// net's switch list are kept, so each search takes `g`, which has
// `switches(g, net: u32) []const u32` (the `trans` rows touching net `net`),
// `tran(g, ti: u32)` (a row with `a`, `b`, `a_bit`, `b_bit`, `resistive`) and
// `conduction(g, ti: u32) Tran.State`.

/// One bit of one net, as a pass switch terminal sees it.
pub const Node = struct { net: u32, bit: u32 };

/// From a group member to `y`: the fewest resistive switches on a path that
/// may conduct, and whether some path surely does.
pub const SwitchPath = struct { res: u32, sure: bool };

/// What `own`, asserted at group member `z`, asserts at `y` over path `p`:
/// reduced by the switches it crosses, and widened to include high impedance
/// when no path surely conducts (§7.10.2).
pub fn crossed(own: Signal, z: Node, y: Node, p: SwitchPath) Signal {
    const sig = reduceSignal(own, @intFromBool(!std.meta.eql(z, y)), p.res);
    return if (p.sure or sig.none()) sig else .{ .lo = @min(sig.lo, 0), .hi = @max(sig.hi, 0) };
}

/// The terminal of switch `tr` across from `u`, or null when `u` is neither.
fn across(tr: anytype, u: Node) ?Node {
    if (tr.a == u.net and tr.a_bit == u.bit) return .{ .net = tr.b, .bit = tr.b_bit };
    if (tr.b == u.net and tr.b_bit == u.bit) return .{ .net = tr.a, .bit = tr.a_bit };
    return null;
}

/// The net bits joined to `from` through pass switches that may conduct.
pub fn reach(g: anytype, a: std.mem.Allocator, from: Node) std.mem.Allocator.Error![]const Node {
    var seen: std.ArrayList(Node) = .empty;
    try seen.append(a, from);
    var i: usize = 0;
    while (i < seen.items.len) : (i += 1) {
        const u = seen.items[i];
        for (g.switches(u.net)) |ti| {
            if (g.conduction(ti) == .off) continue;
            const v = across(g.tran(ti), u) orelse continue;
            for (seen.items) |w| {
                if (std.meta.eql(w, v)) break;
            } else try seen.append(a, v);
        }
    }
    return seen.items;
}

/// From each member of `group` to `y`, its `SwitchPath`.
pub fn switchPaths(g: anytype, a: std.mem.Allocator, y: Node, group: []const Node) std.mem.Allocator.Error![]const SwitchPath {
    const p = try a.alloc(SwitchPath, group.len);
    @memset(p, .{ .res = std.math.maxInt(u32), .sure = false });
    for (group, p) |u, *q| if (std.meta.eql(u, y)) {
        q.* = .{ .res = 0, .sure = true };
    };
    var changed = true;
    while (changed) {
        changed = false;
        for (group, 0..) |u, iu| {
            if (p[iu].res == std.math.maxInt(u32)) continue;
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
    return p;
}

/// IEEE 1364-2005 §7.12 Table 7-8: what a resistive switch makes of the
/// strength it passes; a non-resistive one only turns supply into strong.
pub fn reduce(s: Ast.Strength, resistive: bool) Ast.Strength {
    if (!resistive) return if (s == .supply) .strong else s;
    return switch (s) {
        .supply, .strong => .pull,
        .pull => .weak,
        .large, .weak => .medium,
        .medium, .small => .small,
        .highz => .highz,
    };
}

/// One gate evaluation: §7.8.5's output bit, and whether it is §7.10.2's H/L
/// (`bit` or high impedance) rather than `bit` itself.
const GateOut = struct { bit: Int.Bit, or_z: bool = false };

/// A window of a wider value: bits [lo, lo + the receiver's width) of it read
/// `total` bits wide.
pub const Slice = struct { lo: u32, total: u32 };

/// One A.3.1 gate instance, reduced to what §7.8.5 needs to compute its output:
/// the type and the input terminals in source order.
///
/// One member of a §7.1.5 instance array is lane `lane` of `lanes`: an input
/// as wide as the array gives it its bit `lane` (§7.1.6), a scalar one is
/// broadcast, and it drives bit `out_bit` of a vector output net.
pub const Gate = struct { kind: Ast.GateKind, ins: []const Ast.ExprId, lane: ?u32 = null, lanes: u32 = 1, out_bit: ?u32 = null };

comptime {
    // `Gate` is `Source`'s widest arm: its two `?u32` (8 bytes each) set
    // the 48-byte `Source` inside `Driver`.
    std.debug.assert(@sizeOf(Gate) <= 40);
    std.debug.assert(@sizeOf(Source) <= 48);
}

/// §7.8.5: "a gate transmits a logic value, not a connection": every primitive
/// but the MOS switches reads a z input as x, unlike the expression operators.
fn gateIn(b: Int.Bit) Int.Bit {
    return if (b == .z) .x else b;
}

/// §7.8.5's tables for A.3.4's twelve computing gate types, one output bit.
///
/// The n-input arms are controlling-value rules, which is what the tables
/// encode: `and(0, x)` is 0 because the 0 controls, while `xor(0, x)` is x
/// because xor has no controlling value. `ins` holds `(data, enable)` for
/// the four enable gates and at least one input for every other kind.
pub fn gateBit(kind: Ast.GateKind, ins: []const Int.Bit) GateOut {
    switch (kind) {
        // A.3.1 `( output_terminal , input_terminal , enable_terminal )`. Three
        // regimes: the off enable gives z whatever the data is; the on enable
        // gives the gate function of the data; an x/z enable means the gate may
        // or may not be conducting, which IEEE 1364 writes as L (0-or-z) or H
        // (1-or-z). Neither is a member of {0,1,x,z} (L is not 0, because it
        // might be z), so the value alone projects to x, and the flag is what
        // lets §7.10.3 resolve it against another driver (Figure 7-6).
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => {
            const on: Int.Bit = if (kind == .g_bufif1 or kind == .g_notif1) .one else .zero;
            const enable = ins[1];
            const data = if (kind == .g_bufif0 or kind == .g_bufif1) gateIn(ins[0]) else invert(ins[0]);
            if (enable == .x or enable == .z) return .{ .bit = data, .or_z = data != .x };
            if (enable != on) return .{ .bit = .z };
            return .{ .bit = data };
        },
        .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor, .g_buf, .g_not => return .{ .bit = logicBit(kind, ins) },
    }
}

/// ~x is x and ~z is x: the complement of "unknown" is unknown.
fn invert(b: Int.Bit) Int.Bit {
    return switch (b) {
        .zero => .one,
        .one => .zero,
        .x, .z => .x,
    };
}

fn logicBit(kind: Ast.GateKind, ins: []const Int.Bit) Int.Bit {
    switch (kind) {
        .g_and, .g_nand, .g_or, .g_nor => {
            // The value that decides the output on its own, and the output it
            // decides: `and` is controlled by 0 and produces 0.
            const control: Int.Bit = if (kind == .g_and or kind == .g_nand) .zero else .one;
            var unknown = false;
            for (ins) |raw| {
                const b = gateIn(raw);
                if (b == control) return if (kind == .g_and or kind == .g_or) control else invert(control);
                if (b == .x) unknown = true;
            }
            if (unknown) return .x;
            const quiet = invert(control);
            return if (kind == .g_and or kind == .g_or) quiet else control;
        },
        .g_xor, .g_xnor => {
            var ones: u32 = 0;
            for (ins) |raw| {
                const b = gateIn(raw);
                if (b == .x) return .x;
                if (b == .one) ones += 1;
            }
            const parity: Int.Bit = if (ones % 2 == 1) .one else .zero;
            return if (kind == .g_xor) parity else invert(parity);
        },
        .g_buf => return gateIn(ins[0]),
        .g_not => return invert(ins[0]),
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => unreachable, // gateBit's own arm
    }
}

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
    /// This driver's row in `Run.transitions`, made the first time a delay
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

// ---- strength and resolution (clause 7, §7.9 Tables 7-4/7-6/7-7, §3.7) ------

/// IEEE 1364-2005 §7.10's signal: a range of strength levels on Figure 7-2's
/// scale, which runs Su0 … Sm0 HiZ0 HiZ1 Sm1 … Su1. A position here is that
/// scale folded at HiZ: `-s` is strength0 level `s`, `+s` strength1 level
/// `s`, and 0 is HiZ. A per-side maximum would not do: §7.10.2's StH (a
/// bufif1 with an x enable passing a 1) is `[HiZ, St1]`, which a maximum
/// cannot tell from St1 and which §7.10.3 lets a Pu1 settle to 1. `collapse`
/// turns it into four states only after resolution.
pub const Signal = struct {
    lo: i8 = 0,
    hi: i8 = 0,

    // Budget: one per net bit (`Run.signals`).
    comptime {
        std.debug.assert(@sizeOf(Signal) == 2);
    }

    /// What a driver holding `b` at `(s0, s1)` asserts. An `x` spans both
    /// sides, an ambiguous range rather than a value, and a `z` asserts
    /// nothing, which is why an undriven net reads z. A
    /// `highz` strength on one side of an `x` is Figure 7-17's H/L: "HiZ0 is
    /// part of the result because the strength specification ... specified
    /// that strength for an output with a value 0".
    pub fn of(b: Int.Bit, s0: Ast.Strength, s1: Ast.Strength) Signal {
        const p0 = -@as(i8, @intCast(@backingInt(s0)));
        const p1: i8 = @intCast(@backingInt(s1));
        return switch (b) {
            .one => .{ .lo = p1, .hi = p1 },
            .zero => .{ .lo = p0, .hi = p0 },
            .x => .{ .lo = p0, .hi = p1 },
            .z => .{},
        };
    }

    /// §7.10.2 H or L: `b` or high impedance, at `b`'s side's strength, what
    /// a three-state driver with an unknown control asserts (Figure 7-6).
    pub fn orZ(b: Int.Bit, s0: Ast.Strength, s1: Ast.Strength) Signal {
        return of(.x, if (b == .one) .highz else s0, if (b == .zero) .highz else s1);
    }

    /// Does the signal reach neither side, the `.{}` of no driver at all?
    pub fn none(self: Signal) bool {
        return self.lo == 0 and self.hi == 0;
    }

    /// §7.10.1-§7.10.3, one more contributor folded in.
    ///   - two unambiguous signals: the stronger wins; equal strength and
    ///     opposite values give x "along with the strength levels of both
    ///     signals and all the smaller strength levels", the hull;
    ///   - two ambiguous ones: "a range that includes the extremes of the
    ///     signals and all the strengths between them", the hull again;
    ///   - one of each: §7.10.3's rules a-c. The ambiguous levels stronger
    ///     than the unambiguous one remain, the rest disappear, and the gap
    ///     between what remains and the unambiguous level is filled. An
    ///     opposite-value level equal to it remains too: Figure 7-21's text
    ///     drops only the opposite levels of "lesser strength", and §4.6.1
    ///     Table 4-2 makes St0 with StX an x, which dropping it would not.
    pub fn combine(a: Signal, b: Signal) Signal {
        if (a.none()) return b;
        if (b.none()) return a;
        const hull: Signal = .{ .lo = @min(a.lo, b.lo), .hi = @max(a.hi, b.hi) };
        const ua = a.lo == a.hi;
        const ub = b.lo == b.hi;
        if (ua and ub) {
            if (@abs(a.lo) != @abs(b.lo)) return if (@abs(a.lo) > @abs(b.lo)) a else b;
            return hull;
        }
        if (!ua and !ub) return hull;
        const u = if (ua) a.lo else b.lo;
        const amb = if (ua) b else a;
        const s: i8 = @intCast(@abs(u));
        return .{
            .lo = if (amb.lo < -s or (amb.lo == -s and u > 0)) @min(u, amb.lo) else u,
            .hi = if (amb.hi > s or (amb.hi == s and u < 0)) @max(u, amb.hi) else u,
        };
    }

    /// §7.10.4, one more contributor folded into a wired-logic net: the
    /// table decides only between levels of the same strength ("resolve
    /// conflicts when multiple drivers have the same strength"), and
    /// otherwise "the stronger signal shall dominate" (§7.10.1). An ambiguous
    /// signal takes "all combinations of each of the strength levels in the
    /// first signal with each of the strength levels in the second", and the
    /// result spans every level those produce. HiZ is a level of a range
    /// that crosses it, which is how §7.10.2's H with a Sm0 on a `wor` may
    /// still be 0.
    pub fn combineWired(a: Signal, b: Signal, table: Wired) Signal {
        if (a.none()) return b;
        if (b.none()) return a;
        var out: Signal = .{ .lo = std.math.maxInt(i8), .hi = std.math.minInt(i8) };
        var p = a.lo;
        while (p <= a.hi) : (p += 1) {
            var q = b.lo;
            while (q <= b.hi) : (q += 1) {
                // At equal strength `and` is decided by a 0 and `or` by a 1.
                const r = if (@abs(p) != @abs(q))
                    (if (@abs(p) > @abs(q)) p else q)
                else if (table == .@"and") @min(p, q) else @max(p, q);
                out.lo = @min(out.lo, r);
                out.hi = @max(out.hi, r);
            }
        }
        return out;
    }

    /// The four-state value of the range: wholly on one side is that side's
    /// value, HiZ alone is z, and anything that straddles HiZ (§7.10.2's H
    /// and L among them) is x.
    pub fn collapse(self: Signal) Int.Bit {
        if (self.lo > 0) return .one;
        if (self.hi < 0) return .zero;
        if (self.none()) return .z;
        return .x;
    }
};

/// §7.9/§7.10 the resolution of drivers that all assert one strength on
/// both sides and no H/L, on a net type with no wired logic and no pull of
/// its own, written to `out` 64 bits a word. At one strength the fold of
/// `Signal.combine` reduces to: any x, or a 0 beside a 1, is x; else a 0 or
/// a 1 is that value; else z. `ids` index `drivers`, and each one's
/// `current` has as many plane words as `out`.
pub fn foldUniform(out: Int.Literal, drivers: []const Driver, ids: []const u32) void {
    const words = out.values().len;
    for (0..words) |w| {
        var any0: u64 = 0;
        var any1: u64 = 0;
        var anyx: u64 = 0;
        for (ids) |d| {
            const cur = drivers[d].current;
            std.debug.assert(cur.planes.len == out.planes.len);
            const v = cur.values()[w];
            const u = cur.unknowns()[w];
            any0 |= ~v & ~u;
            any1 |= v & ~u;
            anyx |= v & u;
        }
        const x = anyx | (any0 & any1);
        const m = wordMask(out.width, w);
        out.values()[w] = (x | any1) & m;
        out.unknowns()[w] = (x | ~(any0 | any1)) & m;
    }
}

/// §3.7/§7.9: what the net type itself contributes, at the level clause 7
/// gives it: `undriven`'s value, at the strength that lets a driver argue
/// with it: a `weak1` driver cannot move a
/// `tri0` because pull(5) beats weak(3), and nothing an `assign` can write
/// beats a supply net's supply(7).
pub fn netPull(kind: Ast.NetKind) Signal {
    return switch (kind) {
        .supply0 => .of(.zero, .supply, .highz),
        .supply1 => .of(.one, .highz, .supply),
        .tri0 => .of(.zero, .pull, .highz),
        .tri1 => .of(.one, .highz, .pull),
        // No pull of its own; a wreal resolves as a real and never gets here.
        .wire, .tri, .triand, .trior, .trireg, .wand, .wor, .uwire, .wreal => .{},
    };
}

/// The two §7.9 value tables a wired-logic net folds its drivers through:
/// wired AND (`wand`, `triand`) and wired OR (`wor`, `trior`).
const Wired = enum { @"and", @"or" };

/// Which §7.9 table a net folds its drivers through, null for every net type
/// that resolves through `Signal.combine` alone.
pub fn wiredLogic(kind: Ast.NetKind) ?Wired {
    return switch (kind) {
        .wand, .triand => .@"and",
        .wor, .trior => .@"or",
        .wire, .tri, .tri0, .tri1, .trireg, .uwire, .supply0, .supply1, .wreal => null,
    };
}

/// §3.7 the value a net of this type shows with no driver at all: the pull of
/// `tri0`/`tri1`, the constant of a supply net, the X a `trireg` starts at
/// before it has any charge to hold, and Z for everything else.
pub fn undriven(kind: Ast.NetKind) Int.Bit {
    return switch (kind) {
        .supply0, .tri0 => .zero,
        .supply1, .tri1 => .one,
        .trireg => .x,
        // A wreal reads 0.0 undriven, which `mintNet` gives it directly.
        .wire, .tri, .triand, .trior, .wand, .wor, .uwire, .wreal => .z,
    };
}

// ---- user-defined primitives (IEEE 1364-2005 §8, A.5) -----------------------

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

/// Split A.5.3's input characters into one field per input, or null when an
/// entry has the wrong number of them (A.5.3 gives each input exactly one).
pub fn udpRows(a: std.mem.Allocator, decl: *const Ast.UdpDecl) Error!?[]const UdpRow {
    const inputs = decl.ports.len - 1;
    const rows = try a.alloc(UdpRow, decl.rows.len);
    for (decl.rows, rows) |src, *row| {
        // Exactly one symbol per input, else the row is malformed: a symbol
        // past `inputs` already makes it so.
        var syms: std.ArrayList(UdpSym) = try .initCapacity(a, inputs);
        var edge_at: ?u32 = null;
        var i: usize = 0;
        while (i < src.inputs.len) : (i += 1) {
            const c = src.inputs[i];
            const sym: UdpSym = switch (c) {
                '(' => blk: {
                    if (i + 3 >= src.inputs.len or src.inputs[i + 3] != ')') return null;
                    const pair: [2]u8 = .{ std.ascii.toLower(src.inputs[i + 1]), std.ascii.toLower(src.inputs[i + 2]) };
                    i += 3;
                    break :blk .{ .pair = pair };
                },
                'r', 'R', 'f', 'F', 'p', 'P', 'n', 'N', '*' => .{ .letter = std.ascii.toLower(c) },
                else => .{ .level = std.ascii.toLower(c) },
            };
            if (syms.items.len == inputs) return null;
            if (sym != .level) edge_at = @intCast(syms.items.len);
            syms.appendAssumeCapacity(sym);
        }
        if (syms.items.len != inputs) return null;
        row.* = .{ .ins = syms.items, .state = std.ascii.toLower(src.state), .out = std.ascii.toLower(src.output), .edge_at = edge_at };
    }
    return rows;
}

/// Table 8-1's level symbols against a value the table reads (§8.1.6: a z
/// input has already been read as x).
fn udpLevel(sym: u8, b: Int.Bit) bool {
    return switch (sym) {
        '0' => b == .zero,
        '1' => b == .one,
        'x' => b == .x,
        '?' => true,
        'b' => b == .zero or b == .one,
        else => false,
    };
}

/// Table 8-1's edges: `(vw)` is v then w; r is (01), f (10), p any of (01)
/// (0x) (x1), n any of (10) (1x) (x0), and * any change at all.
fn udpEdge(sym: UdpSym, from: Int.Bit, to: Int.Bit) bool {
    if (from == to) return false;
    return switch (sym) {
        .level => false,
        .pair => |p| udpLevel(p[0], from) and udpLevel(p[1], to),
        .letter => |l| switch (l) {
            'r' => from == .zero and to == .one,
            'f' => from == .one and to == .zero,
            'p' => (from == .zero and to != .zero) or (from == .x and to == .one),
            'n' => (from == .one and to != .one) or (from == .x and to == .zero),
            else => true, // `*`
        },
    };
}

fn udpOut(sym: u8, state: Int.Bit) Int.Bit {
    return switch (sym) {
        '0' => .zero,
        '1' => .one,
        '-' => state,
        else => .x,
    };
}

/// §8.6/§8.7 one evaluation. With `changed == null` only level entries can
/// match (a combinational table, or a sequential one re-read without an
/// event); otherwise `changed` went from `from` to `ins[changed]`, and an
/// edge entry on that input matches too, after every level entry, since
/// §8.8 makes level-sensitive entries dominate edge-sensitive ones. Nothing
/// matching is x (§8.1.6: "a combination of input values not specified ...
/// results in x"). `ins` has one value per input field of every row (as
/// `udpRows` made them), and `changed`, when given, indexes it.
pub fn udpEval(rows: []const UdpRow, sequential: bool, ins: []const Int.Bit, state: Int.Bit, changed: ?u32, from: Int.Bit) Int.Bit {
    for (rows) |row| {
        if (row.edge_at != null) continue;
        if (sequential and !udpLevel(row.state, state)) continue;
        for (row.ins, ins) |sym, b| {
            if (!udpLevel(sym.level, b)) break;
        } else return udpOut(row.out, state);
    }
    const k = changed orelse return .x;
    for (rows) |row| {
        if (row.edge_at != k or !udpLevel(row.state, state)) continue;
        for (row.ins, ins, 0..) |sym, b, i| {
            if (i == k) {
                if (!udpEdge(sym, from, b)) break;
            } else if (sym != .level or !udpLevel(sym.level, b)) break;
        } else return udpOut(row.out, state);
    }
    return .x;
}

// ---- four-state storage (§3.7) ----------------------------------------------

/// A four-state value of `width` bits, every bit `fill`: where declared state
/// gets its starting value, X for a variable and Z for an undriven net (§3.7).
/// The caller owns the result, allocated from `a`. `width` must be at least 1.
pub fn filled(a: std.mem.Allocator, width: u32, signed: bool, fill: Int.Bit) Error!Int.Literal {
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
    return .{ .width = width, .signed = signed, .sized = true, .planes = planes };
}

/// Write one packed bit. The read side is `Int.Literal.bit`; only the §7.9
/// resolution fold writes bit by bit. `index` must be below `value.width`.
pub fn setBit(value: Int.Literal, index: u32, b: Int.Bit) void {
    const at = @as(u64, 1) << @truncate(index);
    const word = index / 64;
    if (@backingInt(b) & 1 != 0) value.values()[word] |= at else value.values()[word] &= ~at;
    if (@backingInt(b) >> 1 != 0) value.unknowns()[word] |= at else value.unknowns()[word] &= ~at;
}

/// The bits of plane word `w` that lie inside a `width`-bit value; the ones
/// above it carry nothing and may hold anything. `w * 64` must not exceed
/// `width`.
pub fn wordMask(width: u32, w: usize) u64 {
    const rest = width - @as(u32, @intCast(w * 64));
    return if (rest >= 64) ~@as(u64, 0) else (@as(u64, 1) << @intCast(rest)) - 1;
}

// ---- tests ------------------------------------------------------------------

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

test "an undriven net reads Z where a variable reads X" {
    try expectRun(
        \\module example;
        \\reg [3:0] r;
        \\wire [3:0] w;
        \\wire s;
        \\initial $display("%b %b %b", r, w, s);
        \\endmodule
    , "xxxx zzzz z\n");
}

test "IEEE1364-2005 section 7.9 wired logic resolves all drivers of one net" {
    // Each net has the same two drivers; only the resolution function differs.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire w;
        \\wand wa;
        \\wor wo;
        \\assign w = a, wa = a, wo = a;
        \\assign w = b, wa = b, wo = b;
        \\initial begin
        \\  a = 0; b = 0; #1 $display("0 0 %b %b %b", w, wa, wo);
        \\  a = 1;        #1 $display("1 0 %b %b %b", w, wa, wo);
        \\  b = 1;        #1 $display("1 1 %b %b %b", w, wa, wo);
        \\  a = 1'bz;     #1 $display("z 1 %b %b %b", w, wa, wo);
        \\  b = 1'bx;     #1 $display("z x %b %b %b", w, wa, wo);
        \\  b = 1'bz;     #1 $display("z z %b %b %b", w, wa, wo);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        \\0 0 0 0 0
        \\1 0 x 0 1
        \\1 1 1 1 1
        \\z 1 1 1 1
        \\z x x x x
        \\z z z z z
        \\
    );
}

test "IEEE1364-2005 Figure 7-25 wired logic over an ambiguous strength" {
    // Signal 1 is St0..Pu0, signal 2 is Pu1. `and`: Pu0 & Pu1 = Pu0 and St0
    // dominates, so St0..Pu0. `or`: Pu0 | Pu1 = Pu1 but St0 still dominates,
    // so the result spans St0..Pu1.
    const s1: Signal = .{ .lo = -6, .hi = -5 };
    const s2: Signal = .of(.one, .pull, .pull);
    try std.testing.expectEqual(Signal{ .lo = -6, .hi = -5 }, s1.combineWired(s2, .@"and"));
    try std.testing.expectEqual(Signal{ .lo = -6, .hi = 5 }, s1.combineWired(s2, .@"or"));
}

// IEEE 1364-2005 clause 7, A.2.2.2, A.6.1: the three places strength decides
// what a four-state resolution alone would get wrong. The d03 fixtures cover
// the resolution as a whole.
test "a drive strength decides which of two disagreeing drivers the net shows" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire w;
        \\tri0 t;
        \\assign (strong1, strong0) w = a, t = a;
        \\assign (weak1, weak0) w = b;
        \\initial begin
        \\  a = 1; b = 0; #1 $display("6v3 %b %b", w, t);
        \\  a = 0; b = 1; #1 $display("3v6 %b %b", w, t);
        \\  a = 1'bx;     #1 $display("ambiguous %b %b", w, t);
        \\  a = 1'bz;     #1 $display("removed %b %b", w, t);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        // `t` is a tri0: its own pull(5) loses to strong(6) on both polarities and
        // to the strong x on neither side, so the ambiguous line is x there too,
        // and the weak driver of `w` never moves it.
        \\6v3 1 1
        \\3v6 0 0
        \\ambiguous x x
        \\removed 1 0
        \\
    );
}

test "a highz half suppresses that polarity outright, wired logic included" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire w;
        \\wand wa;
        \\assign (strong1, highz0) w = a, wa = a;
        \\assign (weak1, weak0) w = b, wa = b;
        \\initial begin
        \\  a = 0; b = 1; #1 $display("open_drain %b %b", w, wa);
        \\  a = 0; b = 0; #1 $display("weak_zero %b %b", w, wa);
        \\  a = 0; b = 1'bz; #1 $display("nothing_left %b %b", w, wa);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        // The `highz0` driver holding 0 asserts nothing at all, so it is invisible
        // to the plain wire and is the wand table's identity rather than a 0 vote.
        \\open_drain 1 1
        \\weak_zero 0 0
        \\nothing_left z z
        \\
    );
}

test "a supply net outranks every strength an assign can write but its own" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\supply1 vdd;
        \\supply1 v2;
        \\assign (strong1, strong0) vdd = a;
        \\assign (supply1, supply0) v2 = a;
        \\initial begin
        \\  a = 0; #1 $display("zero %b %b", vdd, v2);
        \\  a = 1; #1 $display("one %b %b", vdd, v2);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        // A supply-strength driver does not lose to the net, it ties with it, and a
        // tie on two nonzero sides is x. That is the line a resolver which simply
        // ignores a supply net's drivers gets wrong.
        \\zero 1 x
        \\one 1 1
        \\
    );
}

test "the pull supply and capacitive net types supply what no driver did" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg d;
        \\tri0 t0;
        \\tri1 t1;
        \\supply0 s0;
        \\supply1 s1;
        \\trireg c;
        \\assign t0 = d, t1 = d, s0 = d, s1 = d, c = d;
        \\initial begin
        \\  $display("start %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  d = 0;    #1 $display("zero  %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  d = 1'bz; #1 $display("float %b %b %b %b %b", t0, t1, s0, s1, c);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        \\start x x 0 1 x
        \\zero  0 0 0 1 0
        \\float 0 1 0 1 0
        \\
    );
}

// §7.10.2/§7.10.3 against the clause's own figures, each as (lo, hi) on the
// folded scale: 35X is [-3, 5], 56X [-5, 6], 36X [-3, 6], 651 [5, 6].
test "§7.10 strength ranges combine the way Figures 7-9 through 7-19 draw them" {
    const S = Signal;
    // Figure 7-9: PuH + WeL is 35X, "the extremes of the signals and all the strengths between".
    try std.testing.expectEqual(S{ .lo = -3, .hi = 5 }, S.orZ(.one, .strong, .pull).combine(S.orZ(.zero, .weak, .strong)));
    // Figure 7-14: 651 + 530 is 56X.
    try std.testing.expectEqual(S{ .lo = -5, .hi = 6 }, (S{ .lo = 5, .hi = 6 }).combine(.{ .lo = -5, .hi = -3 }));
    // Figure 7-19: StH + We0 is 36X (rule c fills the gap).
    const sth = S.of(.x, .highz, .strong);
    try std.testing.expectEqual(S{ .lo = -3, .hi = 6 }, sth.combine(S.of(.zero, .weak, .strong)));
    // Rules a/b: StH + Pu1 keeps only St1 above Pu1: a 1, not an x.
    try std.testing.expectEqual(Int.Bit.one, sth.combine(S.of(.one, .strong, .pull)).collapse());
    try std.testing.expectEqual(Int.Bit.x, sth.collapse());
    // An opposite level equal to the unambiguous one ties: Table 4-2's 0-with-x.
    try std.testing.expectEqual(Int.Bit.x, S.of(.x, .strong, .strong).combine(S.of(.zero, .strong, .strong)).collapse());
    try std.testing.expectEqual(Int.Bit.x, S.of(.x, .pull, .pull).combine(S.of(.zero, .pull, .highz)).collapse());
    try std.testing.expectEqual(Int.Bit.x, sth.combine(S.of(.zero, .strong, .strong)).collapse());
    // §7.10.1: unambiguous, the stronger wins; equal and opposite is x.
    try std.testing.expectEqual(Int.Bit.zero, S.of(.one, .strong, .weak).combine(S.of(.zero, .pull, .strong)).collapse());
    try std.testing.expectEqual(Int.Bit.x, S.of(.one, .strong, .pull).combine(S.of(.zero, .pull, .strong)).collapse());
    try std.testing.expectEqual(Int.Bit.z, S.of(.one, .strong, .highz).collapse());
}

// §7.6/§7.12: a MOS switch passes its data at the data's strength (reduced by
// an `r` switch), a tran joins two nets into one resolution, and a tranif
// whose control is x lets the far side's value arrive only as "or z".
test "§7.6 MOS strength pass-through and reduction, tran and tranif joins" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg d, g, c; wire n, rn, p, q, s, t;
        \\pullup (n); pullup (rn);
        \\nmos (n, d, g); rnmos (rn, d, g);
        \\assign p = d; tran (p, q);
        \\buf (s, 1'b1); tranif1 (s, t, c);
        \\initial begin
        \\  d = 0; g = 1; c = 1'bx; #1 $write("%b%b %b%b %b%b ", n, rn, p, q, s, t);
        \\  c = 1; #1 $write("%b ", t); c = 0; #1 $display("%b", t);
        \\end
        \\endmodule
    , "0x 00 1x 1 z\n");
}

// §7.1.6: a vector terminal as wide as the array is split one bit per gate,
// a scalar one is shared, and each gate drives only its own output bit.
test "§7.1.5 a gate instance array splits vector terminals and shares scalars" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [2:0] a, b; reg e; wire [2:0] y; wire [2:0] z;
        \\and g[2:0](y, a, b);
        \\bufif0 f[0:2](z, a, e);
        \\initial begin a = 3'b110; b = 3'b011; e = 1; #1 $write("%b %b ", y, z); e = 0; #1 $display("%b", z); end
        \\endmodule
    , "010 zzz 110\n");
}

// §8: a rising-edge toggle built from Table 8-1's letters, behind an
// instance delay: the initial state is out at time 0, a falling edge holds,
// each rising edge flips the state and lands 2 units later.
test "§8 a sequential UDP with edge letters, an initial state and an instance delay" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\primitive tog(q, c);
        \\  output q; reg q; input c;
        \\  initial q = 1;
        \\  table r : 0 : 1; r : 1 : 0; f : ? : -; (?x) : ? : -; (x?) : ? : -; endtable
        \\endprimitive
        \\module m;
        \\reg c; wire q;
        \\tog #2 t(q, c);
        \\initial begin
        \\  #1 $write("%b", q); c = 0; #1 c = 1; #1 $write("%b", q); #1 $write("%b", q);
        \\  c = 0; #3 c = 1; #3 $display("%b", q);
        \\end
        \\endmodule
    , "1101\n");
}

// ---- unit tests: the tables against the clause's own rows -------------------

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

test reduce {
    // IEEE 1364-2005 §7.12 Table 7-8, row by row: what a resistive switch
    // makes of each input strength.
    const S = Ast.Strength;
    const table = [_][2]S{
        .{ .supply, .pull },
        .{ .strong, .pull },
        .{ .pull, .weak },
        .{ .large, .medium },
        .{ .weak, .medium },
        .{ .medium, .small },
        .{ .small, .small },
        .{ .highz, .highz },
    };
    for (table) |row| {
        try std.testing.expectEqual(row[1], reduce(row[0], true));
        // §7.11: a non-resistive switch only turns supply into strong.
        try std.testing.expectEqual(if (row[0] == .supply) S.strong else row[0], reduce(row[0], false));
    }
}

test reduceSignal {
    const su1: Signal = .of(.one, .supply, .supply);
    // No switch crossed: the signal as driven.
    try std.testing.expectEqual(su1, reduceSignal(su1, 0, 0));
    // §7.11: supply arrives as strong across a tran.
    try std.testing.expectEqual(Signal{ .lo = 6, .hi = 6 }, reduceSignal(su1, 1, 0));
    // Table 7-8: strong (from supply) to pull across one rtran, to weak
    // across a second.
    try std.testing.expectEqual(Signal{ .lo = 5, .hi = 5 }, reduceSignal(su1, 1, 1));
    try std.testing.expectEqual(Signal{ .lo = 3, .hi = 3 }, reduceSignal(su1, 2, 2));
    // Both sides of an x reduce: StX across an rtran is PuX.
    try std.testing.expectEqual(Signal{ .lo = -5, .hi = 5 }, reduceSignal(.of(.x, .strong, .strong), 1, 1));
    // HiZ stays HiZ however many switches it crosses.
    try std.testing.expectEqual(Signal{}, reduceSignal(.{}, 3, 3));
}

/// The §7.8.5 truth tables read as "an x input is a 0 or a 1" (and a z
/// input as an x, §7.8.5: "a gate transmits a logic value"): the output
/// every resolution of the unknown inputs agrees on, else x. An enable gate
/// whose resolutions give one value or z is that value's L/H (Figure 7-6).
/// The oracle `gateBit`'s controlling-value rules are checked against: it
/// enumerates worlds instead of reading a controlling value.
fn gateWorlds(kind: Ast.GateKind, ins: []const Int.Bit) GateOut {
    std.debug.assert(ins.len <= 3);
    var seen = [3]bool{ false, false, false }; // the output was 0, 1, z
    for (0..@as(usize, 1) << @intCast(ins.len)) |world| {
        var v: [3]bool = undefined;
        const fits = for (ins, 0..) |b, i| {
            v[i] = (world >> @intCast(i)) & 1 != 0;
            if ((b == .zero and v[i]) or (b == .one and !v[i])) break false;
        } else true;
        if (!fits) continue;
        const in = v[0..ins.len];
        var all = true;
        var any = false;
        var odd = false;
        for (in) |p| {
            all = all and p;
            any = any or p;
            odd = odd != p;
        }
        const z: usize = 2;
        const out: usize = switch (kind) {
            .g_and => @intFromBool(all),
            .g_nand => @intFromBool(!all),
            .g_or => @intFromBool(any),
            .g_nor => @intFromBool(!any),
            .g_xor => @intFromBool(odd),
            .g_xnor => @intFromBool(!odd),
            .g_buf => @intFromBool(in[0]),
            .g_not => @intFromBool(!in[0]),
            // A.3.1 `(out, data, enable)`: an off enable gives z.
            .g_bufif0 => if (in[1]) z else @intFromBool(in[0]),
            .g_bufif1 => if (in[1]) @intFromBool(in[0]) else z,
            .g_notif0 => if (in[1]) z else @intFromBool(!in[0]),
            .g_notif1 => if (in[1]) @intFromBool(!in[0]) else z,
        };
        seen[out] = true;
    }
    if (seen[0] and seen[1]) return .{ .bit = .x };
    if (seen[0]) return .{ .bit = .zero, .or_z = seen[2] };
    if (seen[1]) return .{ .bit = .one, .or_z = seen[2] };
    return .{ .bit = .z };
}

test "§7.8.5 every gate table agrees with every resolution of its unknown inputs" {
    const bits = [_]Int.Bit{ .zero, .one, .x, .z };
    const Case = struct { Ast.GateKind, usize };
    const cases = [_]Case{
        .{ .g_and, 2 },
        .{ .g_and, 3 },
        .{ .g_nand, 2 },
        .{ .g_nand, 3 },
        .{ .g_or, 2 },
        .{ .g_or, 3 },
        .{ .g_nor, 2 },
        .{ .g_nor, 3 },
        .{ .g_xor, 2 },
        .{ .g_xor, 3 },
        .{ .g_xnor, 2 },
        .{ .g_xnor, 3 },
        .{ .g_buf, 1 },
        .{ .g_not, 1 },
        .{ .g_bufif0, 2 },
        .{ .g_bufif1, 2 },
        .{ .g_notif0, 2 },
        .{ .g_notif1, 2 },
    };
    for (cases) |c| {
        const kind, const n = c;
        var ins: [3]Int.Bit = undefined;
        // Every combination of 0, 1, x and z on `n` inputs: 4^n of them.
        for (0..std.math.pow(usize, 4, n)) |code| {
            var rest = code;
            for (ins[0..n]) |*b| {
                b.* = bits[rest % 4];
                rest /= 4;
            }
            try std.testing.expectEqual(gateWorlds(kind, ins[0..n]), gateBit(kind, ins[0..n]));
        }
    }
}

test "§7.10 Signal: what a driver asserts, and its four-state value" {
    try std.testing.expectEqual(Signal{ .lo = 6, .hi = 6 }, Signal.of(.one, .weak, .strong));
    try std.testing.expectEqual(Signal{ .lo = -3, .hi = -3 }, Signal.of(.zero, .weak, .strong));
    try std.testing.expectEqual(Signal{ .lo = -3, .hi = 6 }, Signal.of(.x, .weak, .strong));
    try std.testing.expectEqual(Signal{}, Signal.of(.z, .supply, .supply));
    // Figure 7-6's H and L: one side's level and HiZ.
    try std.testing.expectEqual(Signal{ .lo = 0, .hi = 6 }, Signal.orZ(.one, .strong, .strong));
    try std.testing.expectEqual(Signal{ .lo = -6, .hi = 0 }, Signal.orZ(.zero, .strong, .strong));
    try std.testing.expectEqual(Int.Bit.x, Signal.orZ(.one, .strong, .strong).collapse());
    try std.testing.expect((Signal{}).none());
    try std.testing.expect(!Signal.orZ(.one, .strong, .strong).none());
    try std.testing.expectEqual(Int.Bit.one, (Signal{ .lo = 1, .hi = 7 }).collapse());
    try std.testing.expectEqual(Int.Bit.zero, (Signal{ .lo = -7, .hi = -1 }).collapse());
}

test "§7.9 the two-signal folds are symmetric and HiZ is their identity" {
    // Every range on Figure 7-2's folded scale, lo <= hi in [-7, 7].
    // Symmetry only: a fold of three or more signals with two ambiguous
    // ones depends on their order (`(StL, StL, Pu0)` is 0 one way and x
    // another), which the clause's pairwise rules leave open.
    var la: i8 = -7;
    while (la <= 7) : (la += 1) {
        var ha = la;
        while (ha <= 7) : (ha += 1) {
            const a: Signal = .{ .lo = la, .hi = ha };
            try std.testing.expectEqual(a, a.combine(.{}));
            try std.testing.expectEqual(a, (Signal{}).combine(a));
            try std.testing.expectEqual(a, a.combineWired(.{}, .@"and"));
            try std.testing.expectEqual(a, (Signal{}).combineWired(a, .@"or"));
            var lb: i8 = -7;
            while (lb <= 7) : (lb += 1) {
                var hb = lb;
                while (hb <= 7) : (hb += 1) {
                    const b: Signal = .{ .lo = lb, .hi = hb };
                    try std.testing.expectEqual(a.combine(b), b.combine(a));
                    try std.testing.expectEqual(a.combineWired(b, .@"and"), b.combineWired(a, .@"and"));
                    try std.testing.expectEqual(a.combineWired(b, .@"or"), b.combineWired(a, .@"or"));
                }
            }
        }
    }
}

test "§3.7/§7.9 what each net type supplies undriven, and which table it folds through" {
    const Row = struct { Ast.NetKind, Int.Bit, ?Wired };
    const rows = [_]Row{
        .{ .wire, .z, null },
        .{ .tri, .z, null },
        .{ .tri0, .zero, null },
        .{ .tri1, .one, null },
        .{ .triand, .z, .@"and" },
        .{ .trior, .z, .@"or" },
        .{ .trireg, .x, null },
        .{ .wand, .z, .@"and" },
        .{ .wor, .z, .@"or" },
        .{ .uwire, .z, null },
        .{ .supply0, .zero, null },
        .{ .supply1, .one, null },
        .{ .wreal, .z, null },
    };
    for (rows) |row| {
        const kind, const bit, const table = row;
        try std.testing.expectEqual(bit, undriven(kind));
        try std.testing.expectEqual(table, wiredLogic(kind));
        // A net type's own pull collapses to its undriven value. A trireg's
        // x is charge it holds (§3.8), not a pull: it asserts nothing.
        try std.testing.expectEqual(if (kind == .trireg) Int.Bit.z else bit, netPull(kind).collapse());
    }
    // §7.9: tri0 pulls at pull(5), a supply net supplies at supply(7).
    try std.testing.expectEqual(Signal{ .lo = -5, .hi = -5 }, netPull(.tri0));
    try std.testing.expectEqual(Signal{ .lo = 7, .hi = 7 }, netPull(.supply1));
}

test udpRows {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const decl: Ast.UdpDecl = .{
        .name = .none,
        .ports = &.{ .none, .none, .none },
        .is_sequential = true,
        .rows = &.{
            .{ .inputs = "(01)0", .state = '?', .output = '1' },
            .{ .inputs = "R?", .state = 'X', .output = '-' },
            .{ .inputs = "1b", .state = 'b', .output = 'x' },
        },
    };
    const rows = (try udpRows(a, &decl)).?;
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqual(@as(?u32, 0), rows[0].edge_at);
    try std.testing.expectEqualSlices(u8, "01", &rows[0].ins[0].pair);
    try std.testing.expectEqual(@as(u8, '0'), rows[0].ins[1].level);
    // Table 8-1's letters and the state column are read case-blind.
    try std.testing.expectEqual(@as(u8, 'r'), rows[1].ins[0].letter);
    try std.testing.expectEqual(@as(?u32, 0), rows[1].edge_at);
    try std.testing.expectEqual(@as(u8, 'x'), rows[1].state);
    try std.testing.expectEqual(@as(?u32, null), rows[2].edge_at);
    try std.testing.expectEqual(@as(u8, 'x'), rows[2].out);
    // A.5.3 gives each input exactly one field: one too few, one too many,
    // and an edge whose parenthesis does not close are malformed.
    for ([_][]const u8{ "0", "000", "(01", "(0)1" }) |bad| {
        const one: Ast.UdpDecl = .{ .name = .none, .ports = &.{ .none, .none, .none }, .rows = &.{.{ .inputs = bad, .output = '0' }} };
        try std.testing.expect((try udpRows(a, &one)) == null);
    }
}

test udpEval {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A combinational AND table.
    const comb: Ast.UdpDecl = .{
        .name = .none,
        .ports = &.{ .none, .none, .none },
        .rows = &.{
            .{ .inputs = "11", .output = '1' },
            .{ .inputs = "0?", .output = '0' },
            .{ .inputs = "?0", .output = '0' },
        },
    };
    const and_rows = (try udpRows(a, &comb)).?;
    try std.testing.expectEqual(Int.Bit.one, udpEval(and_rows, false, &.{ .one, .one }, .x, null, .x));
    try std.testing.expectEqual(Int.Bit.zero, udpEval(and_rows, false, &.{ .zero, .x }, .x, null, .x));
    try std.testing.expectEqual(Int.Bit.zero, udpEval(and_rows, false, &.{ .x, .zero }, .x, null, .x));
    // §8.1.6: a combination no entry names is x.
    try std.testing.expectEqual(Int.Bit.x, udpEval(and_rows, false, &.{ .one, .x }, .x, null, .x));
    // A sequential table over (clk, d): d = 1 sets, a rising clk clears, a
    // falling clk with d = 0 holds, and clk at x with d = 0 sets only from
    // state 1.
    const seq: Ast.UdpDecl = .{
        .name = .none,
        .ports = &.{ .none, .none, .none },
        .is_sequential = true,
        .rows = &.{
            .{ .inputs = "?1", .state = '?', .output = '1' },
            .{ .inputs = "r?", .state = '?', .output = '0' },
            .{ .inputs = "f0", .state = '?', .output = '-' },
            .{ .inputs = "x0", .state = '1', .output = '1' },
        },
    };
    const ff = (try udpRows(a, &seq)).?;
    // clk 0 -> 1 with d = 0: the edge entry.
    try std.testing.expectEqual(Int.Bit.zero, udpEval(ff, true, &.{ .one, .zero }, .x, 0, .zero));
    // clk 0 -> 1 with d = 1: the edge entry says 0, but §8.8 makes the
    // level entry dominate.
    try std.testing.expectEqual(Int.Bit.one, udpEval(ff, true, &.{ .one, .one }, .zero, 0, .zero));
    // clk 1 -> 0 with d = 0: `-` keeps the state.
    try std.testing.expectEqual(Int.Bit.one, udpEval(ff, true, &.{ .zero, .zero }, .one, 0, .one));
    // clk 0 -> x: no entry names that edge, so x.
    try std.testing.expectEqual(Int.Bit.x, udpEval(ff, true, &.{ .x, .zero }, .zero, 0, .zero));
    // With no event only level entries match, and the state column counts.
    try std.testing.expectEqual(Int.Bit.one, udpEval(ff, true, &.{ .x, .zero }, .one, null, .x));
    try std.testing.expectEqual(Int.Bit.x, udpEval(ff, true, &.{ .x, .zero }, .zero, null, .x));
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

test foldUniform {
    // Differential against the per-bit `Signal.combine` fold `resolve` runs
    // otherwise: every driver count to 4, every strength but highz, widths
    // across the word boundaries, and random 0/1/x/z bits.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x7e9);
    const rand = prng.random();
    for ([_]u32{ 1, 63, 64, 65, 130 }) |width| for (1..5) |count| for (1..8) |level| {
        const s: Ast.Strength = @fromBackingInt(@intCast(level));
        var drivers: [4]Driver = undefined;
        for (drivers[0..count]) |*d| {
            d.* = .{ .net = 0, .source = .{ .pull = .z }, .sensitivity = &.{}, .current = try filled(a, width, false, .z), .s0 = s, .s1 = s };
            for (0..width) |i| setBit(d.current, @intCast(i), rand.enumValue(Int.Bit));
        }
        const ids = [_]u32{ 0, 1, 2, 3 };
        // Garbage above the width must not reach the result.
        const out = try filled(a, width, false, .x);
        foldUniform(out, drivers[0..count], ids[0..count]);
        for (0..width) |i| {
            var acc: Signal = .{};
            for (drivers[0..count]) |d| acc = acc.combine(.of(d.current.bit(@intCast(i)), d.s0, d.s1));
            try std.testing.expectEqual(acc.combine(netPull(.wire)).collapse(), out.bit(@intCast(i)));
        }
        const last = out.values().len - 1;
        try std.testing.expectEqual(@as(u64, 0), out.values()[last] & ~wordMask(width, last));
        try std.testing.expectEqual(@as(u64, 0), out.unknowns()[last] & ~wordMask(width, last));
    };
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
