//! Net resolution of the interpreter: a net's drivers (their current
//! values and strengths) -> the value it shows, published through
//! `waiters.store`; plus each driver kind's own value and the delayed
//! transitions in flight. The tables it folds with are `net.zig`'s.
//! Clauses: IEEE 1364-2005 §3.7, §3.8, §6.1.3 inertial delay, §7.6 MOS and
//! pass switches, §7.8.5 gates, §7.9, §7.10, §7.11, §7.12, §8 UDPs,
//! §8.5.3.5; VAMS §3.7 wreal.
const std = @import("std");
const Int = @import("kernels").Integer;
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const net_mod = @import("net.zig");
const Inertial = net_mod.Inertial;
const no_cold = net_mod.no_cold;
const Bridge = net_mod.Bridge;
const Gate = net_mod.Gate;
const gateBit = net_mod.gateBit;
const Signal = net_mod.Signal;
const netPull = net_mod.netPull;
const wiredLogic = net_mod.wiredLogic;
const filled = net_mod.filled;
const setBit = net_mod.setBit;
const Tran = net_mod.Tran;
const reach = net_mod.reach;
const switchPaths = net_mod.switchPaths;
const crossed = net_mod.crossed;
const foldUniform = net_mod.foldUniform;
const evaluate = @import("evaluate.zig");
const exec = @import("exec.zig");
const waiters = @import("waiters.zig");

/// §7.9: a net's value is the wired-logic resolution of all its drivers, so
/// it is recomputed whole on every driver update and published through
/// `store`, the path a variable write takes, so `@(posedge w)` resumes on a
/// net.
pub fn resolve(self: *Run, net: u32) Error!void {
    const n = self.nets[net];
    const drivers = self.netDrivers(net);
    // A §18.4 port's state can change with its drivers' strengths alone.
    if (self.watch[n.slot].contains(.ports)) try waiters.requestVcd(self);
    if (self.netCold(n).trans.len != 0) return resolveJoined(self, net);
    // VAMS §3.7: a wreal has at most one driver and is that driver's value
    // (no four-state resolution, no strength), and 0.0 with none.
    if (n.kind == .wreal) {
        n.resolved.values()[0] = 0;
        n.resolved.unknowns()[0] = 0;
        for (drivers) |d| {
            const cur = self.drivers[d].current;
            if (!cur.hasUnknown()) n.resolved.values()[0] = cur.values()[0];
        }
        return waiters.store(self, n.slot, n.resolved.planes);
    }
    const current = self.values[n.slot];
    const tables = wiredLogic(n.kind);
    var floating: u32 = 0;
    // §7.10/§7.11: a MOS switch passes its data's strength, so a change of
    // strength alone on a net one reads re-evaluates that switch.
    var moved = false;
    if (uniform(self, net)) foldUniform(n.resolved, self.drivers, drivers) else for (0..n.resolved.width) |i| {
        const at: u32 = @intCast(i);
        var acc: Signal = .{};
        for (drivers) |d| {
            const c = contribution(self.drivers[d], at);
            acc = if (tables) |table| acc.combineWired(c, table) else acc.combine(c);
        }
        // §7.9/§7.10: a `trireg` with no driver asserting anything is in
        // the capacitive state, and what it asserts there is the charge
        // it last held, at its charge strength. Checked before the net
        // type's own pull so that a driven trireg never sees it.
        if (n.kind == .trireg and acc.none()) {
            acc = .of(current.bit(at), n.charge, n.charge);
            floating += 1;
        }
        acc = acc.combine(netPull(n.kind));
        moved = moved or (n.strength_read and !std.meta.eql(self.signals[n.signal + at], acc));
        self.signals[n.signal + at] = acc;
        setBit(n.resolved, at, acc.collapse());
    }
    if (n.kind == .trireg) try chargeState(self, net, floating == n.resolved.width);
    // A.2.1.3's `[ delay3 ]` and §14's module paths delay the net's own
    // transition, so they apply between the resolution and the publish,
    // after every driver is folded in.
    const cold = self.netCold(n);
    if (cold.delay.present or cold.paths.len != 0) {
        const c = try self.netColdMut(net);
        const st = &c.transition;
        const from = self.values[n.slot];
        if (try transitionDelay(self, c, from, n.resolved)) |ticks| {
            if (try schedule(self, from, false, n.resolved, false, st))
                st.in_flight = try exec.enqueue(self, .{ .net_update = net }, ticks, false);
            return;
        }
        // No path is active: the transition is not delayed, and one in
        // flight is superseded.
        if (st.in_flight) |h| try exec.cancel(self, h);
        st.in_flight = null;
    }
    try waiters.store(self, n.slot, n.resolved.planes);
    if (moved) try waiters.wakeSwitches(self, n.slot);
}

/// The delay of net `c`'s transition from `from` to `to`, in ticks from
/// now: its own `delay3` (§6.1.3), its module paths' (`pathDelay`), or of
/// the two "the larger" (IEEE 1364-2005 §14.4); null when neither applies.
fn transitionDelay(self: *Run, c: *const net_mod.NetCold, from: Int.Literal, to: Int.Literal) Error!?u64 {
    const own: ?u64 = if (c.delay.present) c.delay.continuous(from.truth(), to) else null;
    const path = try pathDelay(self, c.paths, from, to);
    if (own) |o| return if (path) |p| @max(o, p) else o;
    return path;
}

/// IEEE 1364-2005 §14.3.3: "Active specify paths are those whose input has
/// transitioned most recently in time, and either they have no condition or
/// their conditions are true", and of them the delay is chosen "by
/// comparing the correct delay for the specific transition being scheduled
/// from each specify path and choosing the smallest". An edge-sensitive
/// path is active only for its edge (§14.2.3), an `ifnone` one only while
/// no state-dependent path from its source is (§14.2.4.4). The delay runs
/// from the source's transition, so time the module's own logic already
/// took counts toward it: §14.4's "larger of the two delays" (Figure 14-3
/// lands at 22, Figure 14-4 at 30). Null when no path is active.
/// ponytail: a vector destination takes the smallest delay its changed bits
/// select, as one transition; per-bit scheduling would time each bit.
fn pathDelay(self: *Run, paths: []const net_mod.Path, from: Int.Literal, to: Int.Literal) Error!?u64 {
    var latest: ?u64 = null;
    for (paths) |p| if (self.path_changed.get(p.src)) |c| {
        latest = @max(latest orelse c.time, c.time);
    };
    const t = latest orelse return null;
    var best: ?u64 = null;
    for (paths) |p| {
        if (!try pathActive(self, paths, p, t)) continue;
        for (0..to.width) |i| {
            const a = from.bit(@intCast(i));
            const b = to.bit(@intCast(i));
            if (a == b) continue;
            const d = p.table[@backingInt(a)][@backingInt(b)];
            best = @min(best orelse d, d);
        }
    }
    const d = best orelse return null;
    return (t + d) -| self.scheduler.now;
}

/// Whether path `p` into a destination whose paths are `paths` is active
/// for a source transition at time `t` (`pathDelay`).
fn pathActive(self: *Run, paths: []const net_mod.Path, p: net_mod.Path, t: u64) Error!bool {
    if (!pathFired(self, p, t)) return false;
    if (p.ifnone) {
        // Its state-dependent paths may be edge-sensitive ones (§14.2.4.4,
        // `(posedge CLK => (Q +: D))` beside `ifnone (CLK => Q)`).
        for (paths) |q| if (q.src == p.src and !q.ifnone and (q.cond != .none or q.edge != .none) and pathFired(self, q, t) and (q.cond == .none or try pathCond(self, q))) return false;
        return true;
    }
    return p.cond == .none or try pathCond(self, p);
}

/// Whether `p`'s source transitioned at `t`, on its edge when it has one
/// (§14.2.3: "the edge transition shall be detected on the least
/// significant bit", or the bit a bit-select names).
/// ponytail: a source bit past 63 counts any transition as its edge.
fn pathFired(self: *const Run, p: net_mod.Path, t: u64) bool {
    const c = self.path_changed.get(p.src) orelse return false;
    if (c.time != t) return false;
    if (p.edge == .none or p.src_bit >= 64) return true;
    const sh: u6 = @intCast(p.src_bit);
    const before = net_mod.planeBit(c.before[0] >> sh, c.before[1] >> sh);
    const after = net_mod.planeBit(c.after[0] >> sh, c.after[1] >> sh);
    return (if (p.edge == .posedge) waiters.Edge.posedge else waiters.Edge.negedge).matches(before, after);
}

/// §14.2.4.1: a state-dependent path's condition, read now in its module.
/// "If the conditional expression evaluates to x or z, it shall be treated
/// as true. If the conditional expression evaluates to multiple bits, the
/// least significant bit shall represent the result."
fn pathCond(self: *Run, p: net_mod.Path) Error!bool {
    if (self.resolve_depth == 0) _ = self.resolve_scratch.reset(.retain_capacity);
    self.resolve_depth += 1;
    defer self.resolve_depth -= 1;
    const saved = self.scope;
    defer self.scope = saved;
    self.scope = p.scope;
    return (try evaluate.eval(self, self.resolve_scratch.allocator(), p.cond, 0)).bit(0) != .zero;
}

/// Whether `net` resolves plane-wise (`net.foldUniform`): a net type with no
/// wired logic and no pull of its own (§7.9), whose per-bit `signal` nothing
/// reads (`Net.strength_read`), driven at one strength on both sides by
/// every driver, none of them H/L (§7.10.2).
fn uniform(self: *const Run, net: u32) bool {
    const n = self.nets[net];
    switch (n.kind) {
        .wire, .tri, .uwire => {},
        .tri0, .tri1, .trireg, .wand, .wor, .triand, .trior, .supply0, .supply1, .wreal => return false,
    }
    const ids = self.netDrivers(net);
    if (n.strength_read or ids.len == 0) return false;
    const s = self.drivers[ids[0]].s0;
    if (s == .highz) return false;
    for (ids) |d| {
        const dr = self.drivers[d];
        if (dr.or_z or dr.s0 != s or dr.s1 != s or dr.current.planes.len != n.resolved.planes.len) return false;
    }
    return true;
}

/// IEEE 1364-2005 §7.6/§8.5.3.5 "switch processing shall consider all the
/// devices in a bidirectional switch-connected net before it can determine
/// the appropriate value for any node": the net bits joined through
/// conducting pass switches resolve as one, from every driver of every one of
/// them. A signal crossing a switch loses supply strength (§7.11) and one
/// Table 7-8 step per resistive switch on the strongest path (§7.12). Across
/// a switch of unknown conduction a driver may or may not arrive, so what it
/// asserts there is widened to include high impedance (§7.10.2). With no
/// driver asserting anything, the group's triregs are §4.6.3.1's capacitive
/// network: each asserts the charge it holds at its charge strength, so the
/// larger charge wins and equal ones of different values make x.
/// ponytail: no charge decay, wired logic or net delay inside a joined
/// group; the group is found afresh on every resolution, which is fine for
/// the handful of switches a digital fixture wires up.
fn resolveJoined(self: *Run, start: u32) Error!void {
    // `Run.resolve_scratch`, kept between calls so a resolution per event
    // does not grow the run's arena; a nested call (a store below waking
    // another group) shares it, and only the outermost resets it.
    if (self.resolve_depth == 0) _ = self.resolve_scratch.reset(.retain_capacity);
    self.resolve_depth += 1;
    defer self.resolve_depth -= 1;
    const a = self.resolve_scratch.allocator();
    var touched: std.ArrayList(u32) = .empty;
    try touched.append(a, start);
    for (0..self.nets[start].resolved.width) |i| {
        const group = try reach(Switches{ .r = self }, a, .{ .net = start, .bit = @intCast(i) });
        for (group) |y| {
            const paths = try switchPaths(Switches{ .r = self }, a, y, group);
            var acc: Signal = .{};
            for (group, paths) |z, p| {
                const n = self.nets[z.net];
                var own = netPull(n.kind);
                for (self.netDrivers(z.net)) |d| own = own.combine(contribution(self.drivers[d], z.bit));
                acc = acc.combine(crossed(own, z, y, p));
            }
            if (acc.none()) for (group, paths) |z, p| {
                const n = self.nets[z.net];
                if (n.kind == .trireg) acc = acc.combine(crossed(.of(self.values[n.slot].bit(z.bit), n.charge, n.charge), z, y, p));
            };
            const n = self.nets[y.net];
            self.signals[n.signal + y.bit] = acc;
            setBit(n.resolved, y.bit, acc.collapse());
            if (std.mem.findScalar(u32, touched.items, y.net) == null) try touched.append(a, y.net);
        }
    }
    for (touched.items) |t| try waiters.store(self, self.nets[t].slot, self.nets[t].resolved.planes);
}

/// `net.reach`'s and `net.switchPaths`'s view of the run's switches: each
/// net's `NetCold.trans` list and the conduction held in its `Tran` row.
const Switches = struct {
    r: *const Run,
    pub fn switches(g: Switches, net: u32) []const u32 {
        return g.r.netCold(g.r.nets[net]).trans;
    }
    pub fn tran(g: Switches, ti: u32) Tran {
        return g.r.trans[ti];
    }
    pub fn conduction(g: Switches, ti: u32) Tran.State {
        return g.r.trans[ti].state;
    }
};

/// §7.6 what a MOS switch drives: its data's value, at the data's strength
/// reduced by §7.12 (the resolved strength of a net, strong for anything
/// else), when its gate conducts; z when it does not; §7.10.2's H or L when
/// the gate is x or z. A z on the data is z whatever the gate ("a switch
/// transmits the z through"), where a switch differs from a bufif.
pub fn mosValue(self: *Run, scratch: std.mem.Allocator, at: u32, m: net_mod.Mos, or_z: *bool) Error!Int.Literal {
    const ex = &self.file.exprs;
    const gv = try evaluate.eval(self, scratch, m.gate, 1);
    const g = gv.bit(if (gv.width > 1) m.lane.? else 0);
    const dv = try evaluate.eval(self, scratch, m.data, 1);
    const bit = if (dv.width > 1) m.lane.? else 0;
    var sig: Signal = .of(dv.bit(bit), .strong, .strong);
    if (ex.tag(m.data) == .ident) if (self.net_of.get(try self.slot(m.data))) |net| {
        sig = self.signals[self.nets[net].signal + bit];
    };
    const d = &self.drivers[at];
    d.s0 = net_mod.reduce(if (sig.lo < 0) @fromBackingInt(@intCast(@as(u8, @intCast(-sig.lo)))) else .highz, m.resistive);
    d.s1 = net_mod.reduce(if (sig.hi > 0) @fromBackingInt(@intCast(@as(u8, @intCast(sig.hi)))) else .highz, m.resistive);
    const value = sig.collapse();
    const on: Int.Bit = if (m.n_type) .one else .zero;
    const out: Int.Bit = if (value == .z or (g != on and (g == .zero or g == .one))) .z else value;
    or_z.* = out != .z and g != on;
    const result = try filled(scratch, d.current.width, false, .z);
    setBit(result, m.out_bit orelse 0, out);
    return result;
}

/// What one driver asserts on bit `at`: its value at its strengths, or §7.10.2's
/// H/L when a gate's control is unknown.
pub fn contribution(dr: net_mod.Driver, at: u32) Signal {
    const b = dr.current.bit(at);
    return if (dr.or_z and b != .z) .orZ(b, dr.s0, dr.s1) else .of(b, dr.s0, dr.s1);
}

/// §6.1.3's inertial rule, shared by a driver's delay and a net's: "if the
/// value changes before the delay has elapsed, the scheduled event is
/// cancelled". Returns whether a new transition to `to` is needed, having
/// already cancelled whatever it displaced and recorded `to` as the target;
/// the caller schedules it and keeps the handle in `st.in_flight`.
///
/// False covers the two cases that make a pulse shorter than the delay
/// vanish rather than arrive late: the value is back to what is published,
/// and the value is what is already on its way.
pub fn schedule(self: *Run, from: Int.Literal, from_or_z: bool, to: Int.Literal, to_or_z: bool, st: *Inertial) Error!bool {
    const settled = if (st.in_flight != null) st.target else from;
    const settled_or_z = if (st.in_flight != null) st.or_z else from_or_z;
    if (std.mem.eql(u64, settled.planes, to.planes) and settled_or_z == to_or_z) return false;
    if (st.in_flight) |h| try exec.cancel(self, h);
    st.in_flight = null;
    if (st.target.planes.len != to.planes.len) st.target.planes = try self.arena.alloc(u64, to.planes.len);
    @memcpy(st.target.planes, to.planes);
    st.target.width = to.width;
    st.target.signed = to.signed;
    st.or_z = to_or_z;
    return true;
}

/// §7.6 a controlled pass switch with a delay: it turns on after the first
/// delay, off after the second, and to unknown conduction after the smaller.
/// A control that returns before its change lands cancels it (§7.14's
/// inertial reading, as a gate's).
pub fn switchAfter(self: *Run, at: u32, next: Tran.State) Error!void {
    const t = &self.trans[at];
    const settled = if (t.pending != null) t.target else t.state;
    if (settled == next) return;
    if (t.pending) |h| try exec.cancel(self, h);
    t.pending = null;
    if (next == t.state) return;
    t.target = next;
    t.pending = try exec.enqueue(self, .{ .tran_switch = at }, t.delay.to(switch (next) {
        .on => .one,
        .off => .zero,
        .unknown => .x,
    }), false);
}

/// §3.8 charge decay. The countdown restarts on each entry into the
/// capacitive state, so this takes the state and acts on its edge.
// ponytail: whole-net, not per-bit: a vector `trireg` with some bits driven
// and some floating decays all of them together; a countdown per bit if a
// design needs it.
fn chargeState(self: *Run, net: u32, floating: bool) Error!void {
    const n = &self.nets[net];
    const was = n.capacitive;
    n.capacitive = floating;
    // Leaving the state, or entering one that never decays, only has to
    // cancel whatever countdown was running.
    if (was == floating) return;
    // A trireg without a cold row has no decay and no countdown to cancel.
    if (n.cold == no_cold) return;
    const c = &self.net_cold.items[n.cold];
    if (c.decay_event) |h| try exec.cancel(self, h);
    c.decay_event = null;
    if (!floating) return;
    const after = c.decay orelse return;
    c.decay_event = try exec.enqueue(self, .{ .decay = net }, after, false);
}

/// What a gate driver contributes: §7.8.5's one output bit, and whether it is
/// §7.10.2's H/L.
pub fn gateValue(self: *Run, scratch: std.mem.Allocator, g: Gate, width: u32, or_z: *bool) Error!Int.Literal {
    // Scratch, which `execute` resets each instruction, so `gateBit` stays a
    // pure function of the input bits, read straight off §7.8.5's tables.
    const bits = try scratch.alloc(Int.Bit, g.ins.len);
    for (g.ins, bits) |in, *b| {
        const v = try evaluate.eval(self, scratch, in, 1);
        b.* = v.bit(if (v.width > 1) g.lane.? else 0);
    }
    const out = try filled(scratch, width, false, .z);
    const o = gateBit(g.kind, bits);
    setBit(out, g.out_bit orelse 0, o.bit);
    or_z.* = o.or_z;
    return out;
}

/// What a UDP driver contributes (IEEE 1364-2005 §8). Its inputs are read with
/// z as x (§8.1.6). A combinational table is simply consulted; a sequential
/// one takes each input that changed since the last evaluation as one event,
/// in terminal order, and its state follows the entries matched (§8.6).
pub fn udpValue(self: *Run, scratch: std.mem.Allocator, u: *net_mod.Udp, width: u32) Error!Int.Literal {
    const bits = try scratch.alloc(Int.Bit, u.ins.len);
    for (u.ins, bits) |in, *b| {
        const w = try evaluate.eval(self, scratch, in, 1);
        const v = w.bit(if (w.width > 1) u.lane orelse 0 else 0);
        b.* = if (v == .z) .x else v;
    }
    const out = if (!u.sequential) net_mod.udpEval(u.rows, false, bits, .x, null, .x) else blk: {
        for (bits, 0..) |b, k| {
            if (b == u.prev[k]) continue;
            const from = u.prev[k];
            u.prev[k] = b;
            u.state = net_mod.udpEval(u.rows, true, u.prev, u.state, @intCast(k), from);
        }
        break :blk u.state;
    };
    const result = try filled(scratch, width, false, .z);
    setBit(result, u.out_bit orelse 0, out);
    return result;
}

/// What a `Bridge` driver contributes: its window, z everywhere else.
pub fn window(self: *Run, scratch: std.mem.Allocator, b: Bridge, width: u32) Error!Int.Literal {
    const out = try filled(scratch, width, false, .z);
    evaluate.copyBits(out, b.dst_lo, self.values[b.src], b.src_lo, b.width);
    return out;
}

// ---- tests ------------------------------------------------------------------

test "continuous vector delay audit_assignment_pending_same_value" {
    try expectRun(
        \\// IEEE1364-2005 §6.1.3(b): cancel pending propagation only if the newly
        \\// evaluated RHS differs from the pending value. At10 a rises, scheduling1
        \\// at15. At12 b rises too, but(a|b) is still1: delivery remains15, not17.
        \\//! inherited IEEE 1364-2005 6.1.3
        \\`timescale 1ns/1ns
        \\module audit_assignment_pending_same_value;
        \\  reg a, b;
        \\  wire y;
        \\  assign #5 y = a | b;
        \\  initial begin
        \\    a = 0; b = 0;
        \\    #10 a = 1;
        \\    #2 b = 1;
        \\    #2 $display("before=%b", y);
        \\    #2 $display("original_deadline_passed=%b", y);
        \\    $finish(0);
        \\  end
        \\endmodule
    ,
        \\before=0
        \\original_deadline_passed=1
        \\
    );
}

test "a continuous assignment drives its net and re-evaluates on every operand" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a, b;
        \\wire [1:0] w;
        \\assign w = {a, a & b};
        \\initial begin
        \\  a = 0; b = 0;
        \\  #1 $display("00 %b", w);
        \\  a = 1;
        \\  #1 $display("10 %b", w);
        \\  b = 1;
        \\  #1 $display("11 %b", w);
        \\  $finish(0);
        \\end
        \\endmodule
    , "00 00\n10 10\n11 11\n");
}

test "a net resolution resumes event waiters through the same write path" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\wire w;
        \\reg [1:0] hits;
        \\assign w = a;
        \\initial begin a = 0; hits = 0; end
        \\always @(posedge w) begin hits = hits + 1; $display("net posedge %b", hits); end
        \\initial begin #5 a = 1; #5 a = 0; #5 a = 1; #5 $finish(0); end
        \\endmodule
    , "net posedge 01\nnet posedge 10\n");
}

test "a delayed continuous assignment is inertial and swallows a short pulse" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg a;
        \\wire y;
        \\assign #(3, 7) y = a;
        \\initial begin
        \\  a = 0;
        \\  #10 #0 $display("t10 %b", y);
        \\  a = 1; #1 a = 0;
        \\  #5 #0 $display("pulse_gone %b", y);
        \\  a = 1;
        \\  #2 #0 $display("t18 %b", y);
        \\  #1 #0 $display("t19 %b", y);
        \\  a = 0;
        \\  #6 #0 $display("t25 %b", y);
        \\  #1 #0 $display("t26 %b", y);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        // The 1 at t=11 would have landed at 14; the 0 at t=12 cancels it and is
        // itself the value already published, so nothing happens at all. The rise
        // at t=16 lands at 19 and the fall at t=19 lands at 26: the two delays are
        // chosen by the value transitioned to, not by the direction of the source.
        \\t10 0
        \\pulse_gone 0
        \\t18 0
        \\t19 1
        \\t25 1
        \\t26 0
        \\
    );
}

test "a trireg holds its charge for the decay time and then gives up" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg d;
        \\trireg (large) #(0, 0, 20) c;
        \\trireg forever_c;
        \\assign c = d, forever_c = d;
        \\initial begin
        \\  d = 1;
        \\  #5 d = 1'bz;
        \\  #19 $display("t24 %b %b", c, forever_c);
        \\  #2 $display("t26 %b %b", c, forever_c);
        \\  d = 0; #1 d = 1'bz;
        \\  #19 $display("restarted %b %b", c, forever_c);
        \\  #1000 $display("late %b %b", c, forever_c);
        \\  $finish(0);
        \\end
        \\endmodule
    ,
        // Released at t=5, so the decay is at t=25, sampled at 24 and 26 and never
        // at it: a sample in the decay's own timestep would pin an intra-timestep
        // order. The countdown restarts from the second release at t=28; one
        // measured from the first release would have fired by t=46.
        \\t24 1 1
        \\t26 x 1
        \\restarted 0 0
        \\late x 0
        \\
    );
}

test "A.2.1.3 a net's own delay applies to its resolved value, rise and fall apart" {
    // `wire #(2,5) w;` plus `assign w = a`: the delay is the net's (with
    // `= a` on the declaration it would be the assignment's, §6.1.3). a rises
    // at 10, so w at 12; a falls at 20, so w at 25. Sampled at 11, 13, 24, 26.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg a; wire #(2,5) w; assign w = a;
        \\initial begin
        \\  a = 0; #10 a = 1;
        \\  #1 $write("%b", w); #2 $write("%b", w);
        \\  #7 a = 0; #4 $write("%b", w); #2 $display("%b", w);
        \\end
        \\endmodule
    , "0110\n");
}

test "§7.6 a controlled pass switch with a delay turns on and off after it" {
    // tranif1 #(2,3): on 2 units after its control rises (at 12), off 3
    // after it falls (at 23). Sampled at 11, 13, 22 and 24.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg c; wire a, b;
        \\assign a = 1'b1;
        \\tranif1 #(2,3) t(a, b, c);
        \\initial begin
        \\  c = 0; #10 c = 1;
        \\  #1 $write("%b", b); #2 $write("%b", b);
        \\  #7 c = 0; #2 $write("%b", b); #2 $display("%b", b);
        \\end
        \\endmodule
    , "z11z\n");
}

const bus_source =
    \\`timescale 1ns/1ns
    \\module leaf(input [3:0] i, output [3:0] o); assign o = i; endmodule
    \\module m;
    \\reg [1:0] sel; reg [69:0] d0, d1;
    \\wire [69:0] bus; wire [3:0] w; wire p;
    \\assign bus = sel[0] ? d0 : 70'bz;
    \\assign bus = sel[1] ? d1 : 70'bz;
    \\assign (weak0, weak1) p = d0[0];
    \\assign p = sel[1] ? d1[0] : 1'bz;
    \\leaf u({d0[1:0], d1[1:0]}, w);
    \\initial begin
    \\  d0 = {1'b1, 65'b0, 4'b0101}; d1 = {1'b0, 65'b0, 4'b0011}; sel = 1;
    \\  #1 $display("%b %b %b %b", bus[69], bus[3:0], p, w);
    \\  sel = 3;
    \\  #1 $display("%b %b %b", bus[69], bus[3:0], p);
    \\  force bus[1] = 1'b0; sel = 2;
    \\  #1 $display("%b %b", bus[69], bus[3:0]);
    \\  release bus[1];
    \\  #1 $display("%b %b", bus[69], bus[3:0]);
    \\  sel = 0;
    \\  #1 $display("%b %b %b", bus[69], bus[3:0], p);
    \\end
    \\endmodule
;
const bus_expected = "1 0101 1 0111\nx 0xx1 1\n0 0001\n0 0011\nz zzzz 1\n";

test "§7.9 a bus of tri-state drivers resolves across a word boundary, under a forced select and beside a weaker driver" {
    try expectRun(bus_source, bus_expected);
}

fn runBus(gpa: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var bag = @import("diag").Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try @import("root.zig").run(arena.allocator(), bus_source, .{}, &bag, &output.writer);
    try std.testing.expectEqualStrings(bus_expected, output.written());
}

test "allocation failure anywhere in net resolution, a port window or a forced select cleans up" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, runBus, .{});
}

test "§14.3.3 Example 1: the source that transitioned last picks the delay, and a simultaneous tie the smallest" {
    // (A => Y) = (6, 9); (B => Y) = (5, 11), with Y = A | B: a rise after A
    // is 6, after B 5, and after both at once the smaller, 5; a fall after A
    // is 9, after B 11, after both 9. x -> 0 at time 0 is Table 14-3's
    // max(tz0, t10) per path, 9 and 11, so 9.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module dut(input A, input B, output Y);
        \\  assign Y = A | B;
        \\  specify (A => Y) = (6, 9); (B => Y) = (5, 11); endspecify
        \\endmodule
        \\module t;
        \\  reg a, b;
        \\  wire y;
        \\  dut d(a, b, y);
        \\  always @(y) $display("%0t Y=%b", $time, y);
        \\  initial begin
        \\    a = 0; b = 0;
        \\    #20 a = 1;
        \\    #20 a = 0;
        \\    #20 b = 1;
        \\    #20 b = 0;
        \\    #20 a = 1; b = 1;
        \\    #20 a = 0; b = 0;
        \\  end
        \\endmodule
    , "9 Y=0\n26 Y=1\n49 Y=0\n65 Y=1\n91 Y=0\n105 Y=1\n129 Y=0\n");
}

test "§14.3.3 Example 2: the true conditions' paths are active, and the smallest delay for the transition wins" {
    // The example's conditions are `MODE < 5` ... `MODE < 1`, but `<` is not
    // in Table 14-1 nor A.7.4's binary_module_path_operator, so each is
    // written as one bit `LT[k]` = (MODE < k+1): MODE 2 is 5'b11100, MODE 5
    // 5'b00000, MODE 0 5'b11111. MODE 2 makes the first three active: rise 4,
    // fall 5. MODE 5 makes none: no path delay. MODE 0 makes all five: rise
    // 3, fall 2.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module dut(input A, input [4:0] LT, output Y);
        \\  assign Y = A;
        \\  specify
        \\    if (LT[4]) (A => Y) = (5, 9);
        \\    if (LT[3]) (A => Y) = (4, 8);
        \\    if (LT[2]) (A => Y) = (6, 5);
        \\    if (LT[1]) (A => Y) = (3, 2);
        \\    if (LT[0]) (A => Y) = (7, 7);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg a;
        \\  reg [4:0] lt;
        \\  wire y;
        \\  dut d(a, lt, y);
        \\  always @(y) $display("%0t Y=%b", $time, y);
        \\  initial begin
        \\    lt = 5'b11100; a = 0;
        \\    #20 a = 1;
        \\    #20 a = 0;
        \\    #20 lt = 5'b00000;
        \\    #1 a = 1;
        \\    #19 lt = 5'b11111;
        \\    #1 a = 0;
        \\    #19 a = 1;
        \\  end
        \\endmodule
    , "5 Y=0\n24 Y=1\n45 Y=0\n61 Y=1\n83 Y=0\n103 Y=1\n");
}

test "§14.2.3 an edge-sensitive path times only the transitions its edge causes" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module dut(input clk, input d, output q);
        \\  assign q = clk & d;
        \\  specify (posedge clk => (q : d)) = 3; endspecify
        \\endmodule
        \\module t;
        \\  reg clk, d;
        \\  wire q;
        \\  dut u(clk, d, q);
        \\  always @(q) $display("%0t q=%b", $time, q);
        \\  initial begin
        \\    d = 1; clk = 0;
        \\    #10 clk = 1;
        \\    #10 clk = 0;
        \\  end
        \\endmodule
    , "0 q=0\n13 q=1\n20 q=0\n");
}

test "§14.3.1 six path delays time 0->1, 1->0, 0->z, z->1, 1->z and z->0 each" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module dut(input en, input d, output q);
        \\  assign q = en ? d : 1'bz;
        \\  specify (d, en *> q) = (1, 2, 3, 4, 5, 6); endspecify
        \\endmodule
        \\module t;
        \\  reg en, d;
        \\  wire q;
        \\  dut u(en, d, q);
        \\  always @(q) $display("%0t q=%b", $time, q);
        \\  initial begin
        \\    en = 1; d = 0;
        \\    #10 d = 1;
        \\    #10 d = 0;
        \\    #10 en = 0;
        \\    #10 d = 1;
        \\    #1 en = 1;
        \\    #9 en = 0;
        \\    #10 d = 0;
        \\    #1 en = 1;
        \\  end
        \\endmodule
    , "6 q=0\n11 q=1\n22 q=0\n33 q=z\n45 q=1\n55 q=z\n67 q=0\n");
}

test "§14.4 Figures 14-3 and 14-4: a path delay and the distributed delays along it, the larger" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module fig3(input D, output Q);
        \\  wire n;
        \\  buf #0 g1(n, D);
        \\  buf #1 g2(Q, n);
        \\  specify (D => Q) = 22; endspecify
        \\endmodule
        \\module fig4(input D, output Q);
        \\  wire n;
        \\  buf #10 g1(n, D);
        \\  buf #20 g2(Q, n);
        \\  specify (D => Q) = 22; endspecify
        \\endmodule
        \\module t;
        \\  reg d;
        \\  wire q3, q4;
        \\  fig3 u3(d, q3);
        \\  fig4 u4(d, q4);
        \\  always @(q3) $display("%0t q3=%b", $time, q3);
        \\  always @(q4) $display("%0t q4=%b", $time, q4);
        \\  initial begin
        \\    d = 0;
        \\    #100 d = 1;
        \\  end
        \\endmodule
    , "22 q3=0\n30 q4=0\n122 q3=1\n130 q4=1\n");
}

test "§14.3.3 a path delay times a destination driven through a procedural block" {
    // `q` starts at z (§4.2.1: "The default initialization value for a net
    // shall be the value z") and takes `r`'s x at time 0, when `clk` too
    // first transitions: that z -> x lands after Table 14-3's
    // min(tz1, tz0) = 3. (iverilog starts the net at x and prints no line.)
    try expectRun(
        \\`timescale 1ns/1ns
        \\module dut(input clk, input d, output q);
        \\  reg r;
        \\  always @(posedge clk) r <= d;
        \\  assign q = r;
        \\  specify (clk => q) = 3; endspecify
        \\endmodule
        \\module t;
        \\  reg clk, d;
        \\  wire q;
        \\  dut u(clk, d, q);
        \\  always @(q) $display("%0t q=%b", $time, q);
        \\  initial begin
        \\    clk = 0; d = 1;
        \\    #10 clk = 1;
        \\  end
        \\endmodule
    , "3 q=x\n13 q=1\n");
}

test "§14.3.3 a destination change no path source caused takes no path delay" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module dut(input a, output y);
        \\  reg r;
        \\  assign y = r;
        \\  initial begin r = 0; #5 r = 1; end
        \\  specify (a => y) = 3; endspecify
        \\endmodule
        \\module t;
        \\  wire y;
        \\  dut d(, y);
        \\  always @(y) $display("%0t y=%b", $time, y);
        \\endmodule
    , "0 y=0\n5 y=1\n");
}

test "§14.2.4.4 an ifnone path applies while every state-dependent path from its source is false" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module dut(input C1, input IN, output OUT);
        \\  assign OUT = IN;
        \\  specify
        \\    if (C1) (IN => OUT) = (1, 1);
        \\    ifnone (IN => OUT) = (2, 2);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg c1, in;
        \\  wire out;
        \\  dut d(c1, in, out);
        \\  always @(out) $display("%0t OUT=%b", $time, out);
        \\  initial begin
        \\    c1 = 1; in = 0;
        \\    #10 in = 1;
        \\    #10 c1 = 0;
        \\    #1 in = 0;
        \\  end
        \\endmodule
    , "1 OUT=0\n11 OUT=1\n23 OUT=0\n");
}

test "§14.2.4.4 an ifnone path yields to an edge-sensitive path from its source that fired" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module dut(input CLK, input D, output Q);
        \\  assign Q = CLK & D;
        \\  specify
        \\    (posedge CLK => (Q : D)) = 5;
        \\    ifnone (CLK => Q) = 1;
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg clk, d;
        \\  wire q;
        \\  dut u(clk, d, q);
        \\  always @(q) $display("%0t Q=%b", $time, q);
        \\  initial begin
        \\    d = 1; clk = 0;
        \\    #10 clk = 1;
        \\    #10 clk = 0;
        \\  end
        \\endmodule
    , "1 Q=0\n15 Q=1\n21 Q=0\n");
}
