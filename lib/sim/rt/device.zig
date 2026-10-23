//! A native design's tables and dispatch -> a contract device (ABI 5) an
//! analog host loads like a `.va` one: one pin per port bit of the top
//! module, an `input` bit sensed by an A2D bridge, an `output` bit driven by
//! a D2A bridge, and the digital engine behind `updateState`/`stateCtl`.
//! The bridges are the connect modules VAMS §7.8 inserts on a port that
//! meets an electrical net, with VerA's defaults (the LRM supplies none):
//!
//!     D2A: I(a) <+ transition(g, 0, trise, tfall) * (V(a) - transition(lvl, 0, trise, tfall))
//!          0 -> vss, 1 -> vdd, x -> (vdd + vss)/2 at g = 1/rout; z -> g = gz
//!     A2D: rising through vth + vhys/2 -> 1, falling through vth - vhys/2 -> 0;
//!          a static solve reads 1 above the band, 0 below, x inside it
//!
//! The engine is `root.State` rebuilt from a saved tick boundary
//! (`snapshot.save`) whenever it has work, run, and saved again: `State`
//! holds two boundaries, the accepted one and the one this step made.
//! Clauses: VAMS §7.3.6 (synchronization), §7.8, §8.4.3.3 (an A2D event at
//! the nearest tick), §4.5.8 (the ramps), §5.10.3.1 (`cross`); IEEE 1364-2005
//! §9.7.2 (which edges wake a process), §11.4 (a tick boundary).
const std = @import("std");
const contract = @import("contract");
const root = @import("root.zig");
const snapshot = @import("snapshot.zig");
const logic = @import("logic.zig");
const time = @import("../time.zig");

/// One pin: bit `bit` of the top module's port slot `slot`, whose first word
/// is word `off` of the planes.
pub const Pin = struct { out: bool, slot: u32, off: u32, bit: u32 };

/// What `src/codegen/digital/emit.zig`'s device root passes `Device`, all comptime.
pub const Spec = struct {
    /// The pins' enum, `U` of the device.
    U: type,
    design: *const root.Design,
    dispatch: root.Dispatch,
    /// In `U` order: the ports in declaration order, a vector's bits from
    /// its left index to its right.
    pins: []const Pin,
    /// The design's finest precision: a tick is 10^`units` s.
    units: i32,
};

/// The contract device (`contract.validate`'s decls) of the native design in
/// `spec`. Every instance of the device shares `spec.design`'s tables; an
/// `Instance` holds only its bridges.
///
/// Its cost grows with the pins, never with their square: output row u reads
/// unknown u alone, so `jac_pattern` (in `contract.MaskOf(|U|)`, past 64 pins
/// too) gives a sparse family one lane per row; a step's A2D work is one
/// compare per input, and the engine runs only when an input crossed or an
/// event is due, so a bus that holds still costs no engine run.
pub fn Device(comptime spec: Spec) type {
    const n_u = spec.pins.len;
    @setEvalBranchQuota(100 * n_u + 1000);
    const M = contract.MaskOf(n_u);
    // The pins of each direction, in `U` order.
    const ins, const outs = comptime blk: {
        var i: [n_u]u32 = undefined;
        var o: [n_u]u32 = undefined;
        var ni: usize = 0;
        var no: usize = 0;
        for (spec.pins, 0..) |p, u| if (p.out) {
            o[no] = u;
            no += 1;
        } else {
            i[ni] = u;
            ni += 1;
        };
        const ii = i[0..ni].*;
        const oo = o[0..no].*;
        break :blk .{ ii, oo };
    };
    const n_out = outs.len;
    const n_in = ins.len;
    // Per pin, its index among the outputs or among the inputs.
    const index = comptime blk: {
        var ix: [n_u]usize = undefined;
        for (ins, 0..) |u, i| ix[u] = i;
        for (outs, 0..) |u, k| ix[u] = k;
        break :blk ix;
    };
    const out_mask: M = comptime blk: {
        var m: M = 0;
        for (outs) |u| m |= @as(M, 1) << u;
        break :blk m;
    };
    const tick: f64 = comptime std.fmt.parseFloat(f64, std.fmt.comptimePrint("1e{d}", .{spec.units})) catch unreachable;
    // 10^|units|, exact for every precision 1364 allows, so a tick count
    // converts with one rounding: k * 1e-9 is not k / 1e9.
    const decade: f64 = comptime std.fmt.parseFloat(f64, std.fmt.comptimePrint("1e{d}", .{@abs(spec.units)})) catch unreachable;
    const cap = snapshot.bound(spec.design);
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);

    return struct {
        const Self = @This();
        /// The contract's unknowns: one per pin, in `spec.pins` order.
        pub const U = spec.U;

        /// The bridge parameters, one card for every instance (§1.3 of the
        /// design). A NaN `vth` is (vdd + vss)/2. A ramp time <= 0 is 1 ps:
        /// an ideal step would need the solve at the event time repeated
        /// after the events.
        pub const Model = struct {
            vdd: f64 = 5,
            vss: f64 = 0,
            vth: f64 = nan,
            vhys: f64 = 0,
            trise: f64 = 1e-9,
            tfall: f64 = 1e-9,
            rout: f64 = 1,
            /// The conductance of a released (z) output: 0 would leave a net
            /// only it drives with no path, and the host's matrix singular.
            gz: f64 = 1e-12,
            /// How late after an A2D crossing the host may accept a point
            /// (the `time_tol` VAMS §5.10.3.1 leaves to the tool). NaN is
            /// min(trise, tfall)/50: the response starts at the accepted
            /// point, so an output ramp it arms runs at most 2% of its
            /// length late. The digital event's tick comes from the secant,
            /// not from this.
            ttol: f64 = nan,
        };

        /// What `eval` reads, and the A2D samples. `dc_lvl`/`dc_g` are the
        /// levels a static solve iterates on: `stateCtl(.revert)` leaves
        /// them, since each static `updateState` rebuilds from the accepted
        /// boundary and compares against them (the fixed point of VAMS
        /// §7.3.6's digital initialization).
        pub const Instance = struct {
            /// Per output, its level and conductance ramps: from `from` at
            /// `t0` to `to` at `t1` (§4.5.8 `transition`, zero delay).
            lvl_from: [n_out]f64 = @splat(0),
            lvl_to: [n_out]f64 = @splat(0),
            lvl_t0: [n_out]f64 = @splat(0),
            lvl_t1: [n_out]f64 = @splat(0),
            g_from: [n_out]f64 = @splat(0),
            g_to: [n_out]f64 = @splat(0),
            g_t0: [n_out]f64 = @splat(0),
            g_t1: [n_out]f64 = @splat(0),
            dc_lvl: [n_out]f64 = @splat(0),
            dc_g: [n_out]f64 = @splat(0),
            /// Each input's voltage at the last sample, NaN before the first,
            /// which is then the reference and never a crossing.
            a2d_v: [n_in]f64 = @splat(nan),
            a2d_t: f64 = 0,
            /// Per input, which of its crossings would wake a process at the
            /// accepted boundary: bit 0 a rising one, bit 1 a falling one.
            wakes: [n_in]u2 = @splat(3),
            /// The next digital event, in seconds.
            next_ev: f64 = inf,
            /// A crossing this step took more than `ttol` before its end, in
            /// a step where some process woke.
            late_cross: bool = false,
            /// `$finish` or `$stop` ran: the outputs hold from then on.
            stopped: bool = false,
        };

        /// Two tick boundaries (`snapshot.save`), the accepted one `bufs[cur]`
        /// and, while `work` is set, the one this step's `updateState` made,
        /// and the accepted `Instance`. `say[0..say_len]` is what this
        /// step's run printed: `commit` writes it to stderr, `revert` drops
        /// it, so a rejected step prints nothing and its retry prints once.
        pub const State = struct {
            bufs: [2][cap]u8 = undefined,
            lens: [2]u32 = .{ 0, 0 },
            cur: u1 = 0,
            work: bool = false,
            inst: Instance = .{},
            say: [say_cap]u8 = undefined,
            say_len: u32 = 0,
        };

        /// A step's transcript past this many bytes keeps its head and ends
        /// in `say_cut`.
        const say_cap = 4096;
        const say_cut = "...[device transcript cut at 4096 bytes]\n";

        /// The digital engine keeps history across accepted steps.
        pub const state_class: contract.StateClass = .history;
        /// Only an output pin's own voltage enters `eval` (`g · (V - level)`).
        pub const deriv_reads: M = out_mask;
        /// No `ddx` reads any unknown.
        pub const ddx_reads: M = 0;
        /// Output row u depends on unknown u alone; an input row on nothing.
        pub const jac_pattern: [n_u]M = blk: {
            @setEvalBranchQuota(100 * n_u + 1000);
            var p: [n_u]M = @splat(0);
            for (outs) |u| p[u] = @as(M, 1) << u;
            break :blk p;
        };

        /// Output pin k: g · (V - level), with the static levels in any
        /// analysis but a transient. An input pin draws nothing.
        pub fn eval(comptime S: type, x: *const [n_u]S.V, _: *const Model, inst: *const Instance, sim: contract.SimState) contract.Rows(Self, S) {
            var r: contract.Rows(Self, S) = undefined;
            inline for (spec.pins, 0..) |p, u| {
                if (!p.out) {
                    r[u] = S.con(0).to(contract.rowMask(Self, u));
                } else {
                    const k = index[u];
                    const g = if (sim.kind != .tran) inst.dc_g[k] else ramp(inst.g_from[k], inst.g_to[k], inst.g_t0[k], inst.g_t1[k], sim.t);
                    const v = if (sim.kind != .tran) inst.dc_lvl[k] else ramp(inst.lvl_from[k], inst.lvl_to[k], inst.lvl_t0[k], inst.lvl_t1[k], sim.t);
                    r[u] = S.probe(u, x[u]).addC(-v).scale(g).to(contract.rowMask(Self, u));
                }
            }
            return r;
        }

        /// Time 0: every input x, then the tick-0 events (initial blocks,
        /// continuous assignments); the outputs as they stand are both the
        /// static and the ramp levels.
        pub fn initState(m: *const Model, inst: *Instance) State {
            var st: State = .{};
            var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
            defer arena.deinit();
            birth(arena.allocator(), m, inst, &st) catch poison(inst);
            st.inst = inst.*;
            return st;
        }

        fn birth(a: std.mem.Allocator, m: *const Model, inst: *Instance, st: *State) !void {
            const s = try open(a, null);
            for (ins) |u| try drive(s, spec.pins[u], .x);
            try run(s, 0);
            outputs(m, inst, s, 0, true);
            try keep(inst, st, s);
            st.cur ^= 1;
            st.work = false;
            // Time 0 is never rejected.
            flush(st);
        }

        /// At a static solve (any analysis but a transient) the inputs are
        /// read by threshold at the engine's tick, whose events run again,
        /// and an output that moved asks the host to iterate once more. In
        /// a transient every crossing since the last sample is delivered at
        /// its nearest tick and every tick up to `sim.t` runs; an output
        /// that moved starts its ramp at `sim.t`, where its value has not
        /// changed, so the step never needs repeating (`.ok` always).
        pub fn updateState(comptime S: type, m: *const Model, inst: *Instance, x: [n_u]f64, st: *State, sim: contract.SimState) contract.UpdateResult {
            _ = S;
            st.say_len = 0;
            if (inst.stopped) return .ok;
            var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
            defer arena.deinit();
            if (sim.kind != .tran) {
                const moved = static(arena.allocator(), m, inst, x, st, sim.t) catch {
                    poison(inst);
                    return .ok;
                };
                return if (moved) .{ .request_reject_at = sim.t } else .ok;
            }
            transient(arena.allocator(), m, inst, x, st, sim.t) catch poison(inst);
            return .ok;
        }

        fn static(a: std.mem.Allocator, m: *const Model, inst: *Instance, x: [n_u]f64, st: *State, t: f64) !bool {
            const s = try open(a, st.bufs[st.cur][0..st.lens[st.cur]]);
            for (ins, 0..) |u, i| {
                try drive(s, spec.pins[u], threshold(m, x[u]));
                inst.a2d_v[i] = x[u];
            }
            inst.a2d_t = t;
            try run(s, s.sched.now);
            const before = inst.dc_lvl ++ inst.dc_g;
            outputs(m, inst, s, t, true);
            try keep(inst, st, s);
            return !std.mem.eql(f64, &before, &(inst.dc_lvl ++ inst.dc_g));
        }

        const Edge = struct { tick: u64, pin: u32, bit: logic.Bit };

        fn transient(a: std.mem.Allocator, m: *const Model, inst: *Instance, x: [n_u]f64, st: *State, t: f64) !void {
            const horizon = time.tickAtOrBefore(t, tick);
            const hi = vth(m) + m.vhys / 2;
            const lo = vth(m) - m.vhys / 2;
            var edges: [2 * n_in]Edge = undefined;
            var n: usize = 0;
            // A crossing's time matters only if the step wakes a process: one
            // that wakes nothing runs at its secant tick, unlocated.
            var late = false;
            var woke = false;
            for (ins, 0..) |u, i| {
                const v0 = inst.a2d_v[i];
                const v1 = x[u];
                if (std.math.isNan(v0)) {
                    // The first sample is the reference: no crossing, delivered
                    // at the engine's own tick.
                    edges[n] = .{ .tick = 0, .pin = u, .bit = threshold(m, v1) };
                    n += 1;
                } else for ([2]f64{ hi, lo }, [2]f64{ 1, -1 }, [2]logic.Bit{ .one, .zero }, [2]u2{ 1, 2 }) |th, dir, bit, wake| {
                    if (!time.crosses(dir, v0 - th, v1 - th)) continue;
                    // The secant between the two samples, as `cross` finds it.
                    const tc = inst.a2d_t + (t - inst.a2d_t) * (th - v0) / (v1 - v0);
                    late = late or t - tc > ttol(m);
                    woke = woke or inst.wakes[i] & wake != 0;
                    // ponytail: a crossing that rounds past `horizon` runs at it,
                    // a tick early, rather than holding an event past `t`.
                    edges[n] = .{ .tick = @min(@as(u64, @intFromFloat(@max(@round(ticks(tc)), 0))), horizon), .pin = u, .bit = bit };
                    n += 1;
                }
                inst.a2d_v[i] = v1;
            }
            inst.a2d_t = t;
            const due = inst.next_ev != inf and time.tickAtOrBefore(inst.next_ev, tick) <= horizon;
            if (late and (woke or due)) inst.late_cross = true;
            if (n == 0 and !due) return;
            // Stable, as `std.mem.sort`, without its 28 KB block sort: at
            // most two edges per input.
            std.sort.insertion(Edge, edges[0..n], {}, struct {
                fn lt(_: void, l: Edge, r: Edge) bool {
                    return l.tick < r.tick;
                }
            }.lt);
            const s = try open(a, st.bufs[st.cur][0..st.lens[st.cur]]);
            for (edges[0..n]) |e| {
                if (e.tick > s.sched.now) {
                    try run(s, e.tick - 1);
                    // Nothing is left before `e.tick`, so the clock may move there.
                    if (s.sched.phase != .stopped) s.sched.now = e.tick;
                }
                try drive(s, spec.pins[e.pin], e.bit);
            }
            try run(s, @max(horizon, s.sched.now));
            outputs(m, inst, s, t, false);
            try keep(inst, st, s);
        }

        /// The engine at the boundary `saved`, or at time 0 for null, with
        /// no file or dump (`root.State.quiet`) and its transcript in memory
        /// until `keep` holds it in `State.say`.
        fn open(a: std.mem.Allocator, saved: ?[]const u8) !*root.State {
            const s = try root.quietState(a, spec.design, spec.units);
            if (saved) |b| try s.restore(b);
            return s;
        }

        /// Every event at a tick up to `limit`.
        fn run(s: *root.State, limit: u64) !void {
            if (root.loop(s, spec.dispatch, null, limit)) |e| return e;
        }

        /// The A2D store of `bit` into pin `p`, with every wake it causes.
        fn drive(s: *root.State, p: Pin, bit: logic.Bit) !void {
            const one = @as(u64, 1) << @intCast(p.bit % 64);
            const b: u2 = @backingInt(bit);
            // (v, x) planes: 0 = 00, 1 = 10, z = 01, x = 11.
            const v: u64 = if (b == 1 or b == 3) one else 0;
            const xb: u64 = if (b >= 2) one else 0;
            try s.putWordAs(false, .all, p.slot, p.off, p.bit / 64, .{ .v = v, .x = xb }, one);
        }

        /// Each output's level and conductance from the engine: the static
        /// ones when `static`, else a ramp from its value at `t`.
        fn outputs(m: *const Model, inst: *Instance, s: *const root.State, t: f64, static_: bool) void {
            for (outs, 0..) |u, k| {
                const p = spec.pins[u];
                const w = s.get(p.off + p.bit / 64);
                const at: u6 = @intCast(p.bit % 64);
                const b: u2 = @intCast(((w.v >> at) & 1) | (((w.x >> at) & 1) << 1));
                const lvl = switch (b) {
                    0 => m.vss,
                    1 => m.vdd,
                    else => (m.vdd + m.vss) / 2,
                };
                const g = if (b == 2) m.gz else 1 / m.rout;
                if (static_) {
                    inst.dc_lvl[k] = lvl;
                    inst.dc_g[k] = g;
                    inst.lvl_from[k] = lvl;
                    inst.lvl_to[k] = lvl;
                    inst.g_from[k] = g;
                    inst.g_to[k] = g;
                } else {
                    arm(m, &inst.lvl_from[k], &inst.lvl_to[k], &inst.lvl_t0[k], &inst.lvl_t1[k], t, lvl);
                    arm(m, &inst.g_from[k], &inst.g_to[k], &inst.g_t0[k], &inst.g_t1[k], t, g);
                }
            }
        }

        /// The engine's next event, whether it stopped, which input edges
        /// wake it, and its boundary as this step's work; a boundary longer
        /// than `cap` fails.
        fn keep(inst: *Instance, st: *State, s: *root.State) !void {
            const said = s.sink.buffered();
            if (said.len <= say_cap) {
                @memcpy(st.say[0..said.len], said);
                st.say_len = @intCast(said.len);
            } else {
                @memcpy(st.say[0 .. say_cap - say_cut.len], said[0 .. say_cap - say_cut.len]);
                @memcpy(st.say[say_cap - say_cut.len ..], say_cut);
                st.say_len = say_cap;
            }
            inst.stopped = s.sched.phase == .stopped;
            inst.next_ev = if (s.sched.peekTime()) |k| seconds(k) else inf;
            for (ins, 0..) |u, i| {
                const p = spec.pins[u];
                const e = s.wakes(p.slot);
                // An edge term sees only the slot's least significant bit.
                const lsb = p.bit == 0;
                const up = e.contains(.any) or lsb and e.contains(.posedge);
                const down = e.contains(.any) or lsb and e.contains(.negedge);
                inst.wakes[i] = @as(u2, @intFromBool(up)) | @as(u2, @intFromBool(down)) << 1;
            }
            // A stopped engine is never run again, so its state is not kept.
            if (inst.stopped) return;
            const into = st.cur ^ 1;
            st.lens[into] = @intCast(try snapshot.saveTo(s, &st.bufs[into]));
            st.work = true;
        }

        /// `query`: a crossing ran late; `commit`: this step's boundary and
        /// `Instance` are the accepted ones; `revert`: the accepted ones are
        /// restored, the static levels excepted (see `Instance`).
        pub fn stateCtl(_: *const Model, inst: *Instance, st: *State, op: contract.StateCtlOp) bool {
            switch (op) {
                .query => return inst.late_cross,
                .commit => {
                    flush(st);
                    if (st.work) st.cur ^= 1;
                    st.work = false;
                    inst.late_cross = false;
                    st.inst = inst.*;
                },
                .revert => {
                    const lvl = inst.dc_lvl;
                    const g = inst.dc_g;
                    inst.* = st.inst;
                    inst.dc_lvl = lvl;
                    inst.dc_g = g;
                    st.work = false;
                    st.say_len = 0;
                },
            }
            return false;
        }

        /// The held transcript of an accepted step, to stderr: a host's
        /// stdout may carry its own results.
        fn flush(st: *State) void {
            if (st.say_len == 0) return;
            std.debug.print("{s}", .{st.say[0..st.say_len]});
            st.say_len = 0;
        }

        /// The next digital event or end of an output ramp after `t`.
        pub fn pendingBreakpoint(inst: *const Instance, t: f64) ?f64 {
            var best = if (inst.next_ev > t) inst.next_ev else inf;
            for (inst.lvl_t1 ++ inst.g_t1) |t1| {
                if (t1 > t) best = @min(best, t1);
            }
            return if (best == inf) null else best;
        }

        /// The ramp from `from` at `t0` to `to` at `t1`, at `t`.
        fn ramp(from: f64, to: f64, t0: f64, t1: f64, t: f64) f64 {
            if (from == to) return to;
            return from + (to - from) * std.math.clamp((t - t0) / (t1 - t0), 0, 1);
        }

        /// A ramp toward `target` from its value at `t`, unless it is headed
        /// there already; `trise` long upward, `tfall` downward.
        fn arm(m: *const Model, from: *f64, to: *f64, t0: *f64, t1: *f64, t: f64, target: f64) void {
            if (to.* == target) return;
            from.* = ramp(from.*, to.*, t0.*, t1.*, t);
            to.* = target;
            t0.* = t;
            t1.* = t + if (target > from.*) rise(m) else fall(m);
        }

        /// `k` ticks in seconds.
        fn seconds(k: u64) f64 {
            const f: f64 = @floatFromInt(k);
            return if (spec.units < 0) f / decade else f * decade;
        }

        /// `t` seconds in ticks.
        fn ticks(t: f64) f64 {
            return if (spec.units < 0) t * decade else t / decade;
        }

        fn rise(m: *const Model) f64 {
            return if (m.trise > 0) m.trise else 1e-12;
        }

        fn fall(m: *const Model) f64 {
            return if (m.tfall > 0) m.tfall else 1e-12;
        }

        fn vth(m: *const Model) f64 {
            return if (std.math.isNan(m.vth)) (m.vdd + m.vss) / 2 else m.vth;
        }

        fn ttol(m: *const Model) f64 {
            return if (std.math.isNan(m.ttol)) @min(rise(m), fall(m)) / 50 else m.ttol;
        }

        /// A static read of `v`: 1 above the band, 0 below, x inside it.
        fn threshold(m: *const Model, v: f64) logic.Bit {
            if (v > vth(m) + m.vhys / 2) return .one;
            if (v < vth(m) - m.vhys / 2) return .zero;
            return if (m.vhys > 0) .x else .zero;
        }

        /// A failed engine run: every output reads NaN, which the host
        /// reports as a failed step.
        fn poison(inst: *Instance) void {
            inst.dc_lvl = @splat(nan);
            inst.lvl_from = @splat(nan);
            inst.lvl_to = @splat(nan);
            inst.stopped = true;
        }
    };
}
