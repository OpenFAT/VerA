//! Evaluation: the simulator's `eval` call (its flags, time and previous
//! solution) in, the instance's residuals, Jacobian and limit RHS at the
//! limited point out, which the `load_*` calls stamp (`load.zig`), plus the
//! commits OSDI has no callback for and the step bound breakpoints set.
//!
//! One `evalQ` (or `eval`) over the sparse reference family at the limited
//! point: `seed` under ngspice's INIT_LIM, `limit` against the previous
//! limited point under ENABLE_LIM; the RHS is linearized at the limited point
//! (OpenVAF's lim_rhs). OSDI has no accept callback, so `updateState` and
//! `stateCtl(.commit)` run at every iterate of a static solve and, in a
//! transient, at the last point evaluated before the simulator moves time
//! forward (a rejected step retries at an earlier time, so it is never
//! committed). A static request ("iterate again", `contract.UpdateResult`)
//! is EVAL_RET_FLAG_LIM.
//!
//! Cites LRM §4.6.1 (a transient's operating point is the IC analysis),
//! §6.3.6 (`$mfactor` scales the KCL rows), §9.15 (`$simparam`), §9.17.3
//! (limiting and seeds), OpenVAF-Reloaded `osdi_0_4.h` and `load.rs`, and
//! ngspice-45 `osdiload.c` (the flags) and `dctran.c`.
//!
//! Contents:
//! - `pub fn Eval(comptime D: type) type`
//! - `pub fn Eval(D).eval(handle: ?*anyopaque, ip: *anyopaque, mp: *const anyopaque, info: *const abi.SimInfo) callconv(.c) u32`
//! - `pub fn Eval(D).simState(self: *Instance(D), info: *const abi.SimInfo) contract.SimState`

const std = @import("std");
const assert = std.debug.assert;
const contract = @import("contract");
const abi = @import("abi.zig");
const blobs = @import("blobs.zig");
const params = @import("params.zig");
const tables = @import("tables.zig");
const fixture = @import("fixture.zig"); // Tests only.
const testing = std.testing;

/// The evaluation of device `D`.
// Generic over `D` (axis: the device; every device VerA emits is a case).
pub fn Eval(comptime D: type) type {
    const T = tables.Tables(D);
    const I = blobs.Instance(D);
    const P = params.Params(D);
    const n = T.n;
    return struct {
        /// OSDI `eval`: evaluates the instance at the simulator's previous
        /// solution, limited, and keeps the results for the `load_*` calls.
        /// Returns `EVAL_RET_FLAG_LIM` when the iterate is not converged (a
        /// limited point, a static request, `checkConvergence`) and
        /// `EVAL_RET_FLAG_FATAL`, with a fatal log, on a refused `$simparam`
        /// list or a device status.
        pub fn eval(handle: ?*anyopaque, ip: *anyopaque, _: *const anyopaque, info: *const abi.SimInfo) callconv(.c) u32 {
            @setEvalBranchQuota(10_000_000);
            const self = I.of(ip);
            var ret: u32 = 0;
            // Gmin and source stepping move a `$simparam` mid-solve.
            const moved = P.hostParamsAt(self, info.paras) catch |err| switch (err) {
                error.SimParasUnterminated => {
                    abi.log(handle, abi.log_lvl_fatal, params.sim_paras_refusal);
                    return abi.eval_ret_flag_fatal;
                },
            };
            if (moved) {
                if (@hasDecl(D, "setup")) D.setup(T.Val, &self.row);
                if (@hasDecl(D, "setupInstance")) D.setupInstance(&self.row, &self.inst);
            }
            // The last point before the simulator moves time forward is the
            // one it accepted (a rejected step retries at an earlier time).
            if (T.State != void and self.have_x and self.sim.kind == .tran and info.abstime > self.sim.t and info.flags & abi.calc_react_residual != 0) _ = accept(self);
            const sim = simState(self, info);
            if (@hasDecl(D, "advanceIteration") and self.have_x) D.advanceIteration(T.Val, &self.row, &self.inst, self.x, sim);

            var cur: [n]f64 = undefined;
            for (&cur, self.node_mapping) |*c, k| c.* = info.prev_solve[k];
            var x = cur;
            if (info.flags & abi.init_lim != 0 and @hasDecl(D, "seed")) {
                // SPICE MODEINITJCT: the seeds are node values from a 0 V root.
                x = @splat(0);
                for (D.seed(T.Val, &self.row, &self.inst, sim), &x) |s, *xi| if (s) |v| {
                    xi.* = v;
                };
            } else if (info.flags & abi.enable_lim != 0 and @hasDecl(D, "limit") and self.have_x) {
                const r = D.limit(T.Val, &self.row, &self.inst, cur, self.x, sim);
                x = r.x;
                if (!r.converged) ret |= abi.eval_ret_flag_lim;
            }

            evaluate(self, &x, sim);
            scaleMfactor(self);
            limitRhs(self, &x, &cur);
            self.x = x;
            self.have_x = true;
            self.sim = sim;

            // A static solve has no steps to reject: every iterate is accepted.
            // A request there means "iterate again" (`contract.UpdateResult`):
            // the device's state moved, so this iterate is not converged.
            if (T.State != void and (sim.kind == .dc or sim.kind == .ic) and accept(self) != .ok) ret |= abi.eval_ret_flag_lim;
            if (T.has_bp) boundStep(self, sim);
            if (@hasDecl(D, "checkConvergence") and !D.checkConvergence(T.Val, &self.row, &self.inst, x, sim)) ret |= abi.eval_ret_flag_lim;
            if (@hasField(D.Instance, "vera_status__") and self.inst.vera_status__ != 0) {
                var buf: [512]u8 = undefined;
                var w: std.Io.Writer = .fixed(&buf);
                contract.formatStatus(D, &self.inst, &w) catch |err| switch (err) {
                    // A fixed writer fails only when full: the status is logged
                    // cut, as `log` cuts any long message.
                    error.WriteFailed => {},
                };
                abi.log(handle, abi.log_lvl_fatal, w.buffered());
                ret |= abi.eval_ret_flag_fatal;
            }
            assert(self.have_x);
            assert(ret & ~(abi.eval_ret_flag_lim | abi.eval_ret_flag_fatal) == 0);
            return ret;
        }

        /// The analysis OSDI's flags describe (ngspice osdiload.c sets them),
        /// and in a transient the step `dt` from the last earlier time
        /// evaluated, which this updates. `dt` is never negative.
        pub fn simState(self: *I, info: *const abi.SimInfo) contract.SimState {
            const f = info.flags;
            var s: contract.SimState = .{ .t = info.abstime, .analog_initial = false };
            if (f & abi.analysis_ac != 0) {
                s.kind = .ac;
            } else if (f & abi.analysis_noise != 0) {
                s.kind = .noise;
            } else if (f & abi.analysis_tran != 0 and f & abi.calc_react_residual != 0) {
                // ponytail: OSDI passes no step, so dt is the distance to the
                // last earlier time evaluated; a rejected-and-retried step
                // sees the right one, a later retry at a time past the
                // rejected one does not.
                //
                // OSDI 0.4 promises nothing about the order of `abstime`, and
                // a host can move behind the point taken as accepted: one that
                // starts a second transient without `setup_instance` (ngspice
                // re-runs it only on a reset, cktdojob.c), or ngspice's own
                // shared-sync bug (dctran.c, "CKTtime becomes less than
                // last_accepted_time"). That time is no step from `t_prev`,
                // and `sim.dt` feeds laplace, zi, idtmod and absdelay, so the
                // history restarts as `setup_instance` leaves it: the step is
                // from 0 (or from `abstime` itself if the host passes a
                // negative time), never negative.
                if (info.abstime < self.t_prev) self.t_prev = @min(0, info.abstime);
                if (info.abstime > self.t_last) {
                    self.t_prev = self.t_last;
                    self.t_last = info.abstime;
                } else if (info.abstime < self.t_last) self.t_last = info.abstime;
                s.kind = .tran;
                s.dt = info.abstime - self.t_prev;
                assert(!(s.dt < 0)); // A NaN `abstime` is the host's, and passes through.
                assert(!(self.t_prev > self.t_last));
            } else {
                // §4.6.1: a transient's own operating point is the IC analysis.
                s.kind = if (f & abi.analysis_tran != 0) .ic else .dc;
                s.initial_step = true;
                s.analog_initial = true;
            }
            return s;
        }

        // ---- private ----

        /// The residuals and the Jacobian of every entry at `x`, the
        /// `jac_const` entries that apply overriding the evaluated ones.
        fn evaluate(self: *I, x: *const [n]f64, sim: contract.SimState) void {
            @setEvalBranchQuota(10_000_000);
            if (T.has_q) {
                const out = D.evalQ(T.Dual, x, &self.row, &self.inst, sim);
                const qr = contract.qRows(D, T.Dual, out.q);
                inline for (0..n) |i| {
                    self.res[i] = out.res[i].val();
                    self.q[i] = qr[i].val();
                }
                inline for (T.entries, 0..) |e, k| {
                    self.jac[k] = out.res[e.r].ddxAt(e.c);
                    self.jac_q[k] = qr[e.r].ddxAt(e.c);
                }
            } else {
                const rows = D.eval(T.Dual, x, &self.row, &self.inst, sim);
                inline for (0..n) |i| {
                    self.res[i] = rows[i].val();
                    self.q[i] = 0;
                }
                inline for (T.entries, 0..) |e, k| {
                    self.jac[k] = rows[e.r].ddxAt(e.c);
                    self.jac_q[k] = 0;
                }
            }
            inline for (comptime contract.jacConst(D)) |e| {
                if (comptime T.shortFlow(@backingInt(e.row)) or T.shortFlow(@backingInt(e.col))) continue;
                if (contract.jacConstApplies(D, e, &self.row, T.collapses)) {
                    const k = comptime T.entryOf(@backingInt(e.row), @backingInt(e.col));
                    self.jac[k] = e.g;
                    self.jac_q[k] = e.c;
                }
            }
        }

        /// §6.3.6: every flow contribution is multiplied by `$mfactor` and
        /// every flow probe divided by it. The device applies neither, so the
        /// KCL rows (a voltage unknown's) scale by it here; a flow unknown's
        /// own row is its branch's potential equation and does not, which
        /// leaves the flow unknown the per-device current the probe reads.
        fn scaleMfactor(self: *I) void {
            @setEvalBranchQuota(10_000_000);
            if (!T.has_mf) return;
            // The card's value, which may be any double: no assert on it.
            const m = self.inst.mfactor;
            if (m == 1) return;
            inline for (0..n) |i| if (comptime T.kcl(i)) {
                self.res[i] *= m;
                self.q[i] *= m;
            };
            inline for (T.entries, 0..) |e, k| if (comptime T.kcl(e.r)) {
                self.jac[k] *= m;
                self.jac_q[k] *= m;
            };
        }

        /// OpenVAF's lim_rhs: J·(x − cur), which turns the RHS J·cur − f into
        /// the linearization at the limited point `x`. Zero unless limiting
        /// or a seed moved the point.
        fn limitRhs(self: *I, x: *const [n]f64, cur: *const [n]f64) void {
            @setEvalBranchQuota(10_000_000);
            self.lim_res = @splat(0);
            self.lim_q = @splat(0);
            if (!@reduce(.Or, @as(@Vector(n, f64), x.*) != @as(@Vector(n, f64), cur.*))) return;
            inline for (T.entries, 0..) |e, k| {
                const dx = x[e.c] - cur[e.c];
                self.lim_res[e.r] += self.jac[k] * dx;
                self.lim_q[e.r] += self.jac_q[k] * dx;
            }
        }

        /// `updateState` and `stateCtl(.commit)` at the last evaluated point;
        /// what `updateState` returned.
        fn accept(self: *I) contract.UpdateResult {
            comptime assert(T.State != void);
            assert(self.have_x); // `eval` evaluated a point to commit.
            const r = D.updateState(T.Val, &self.row, &self.inst, self.x, &self.state, self.sim);
            if (@hasDecl(D, "stateCtl")) _ = D.stateCtl(&self.row, &self.inst, &self.state, .commit); // A commit has no answer.
            self.t_acc = self.sim.t;
            return r;
        }

        /// OSDI has no breakpoint slot, so `pendingBreakpoint` becomes the step
        /// bound ngspice's OSDItrunc applies to the step after this point: the
        /// distance to the device's next breakpoint after the accepted time.
        /// One due at or before this point runs only when the point is
        /// accepted (`accept`), so what it schedules next is not known yet:
        /// the next step is held to this one's length. The device's own
        /// `$bound_step` bounds it too.
        fn boundStep(self: *I, sim: contract.SimState) void {
            comptime assert(T.has_bp);
            self.bound = if (@hasField(D.Instance, "bound_step")) self.inst.bound_step else std.math.inf(f64);
            if (sim.kind != .tran) return;
            const bp = D.pendingBreakpoint(&self.inst, self.t_acc) orelse return;
            const b = if (bp > sim.t) bp - sim.t else sim.t - self.t_acc;
            if (b > 0) self.bound = @min(self.bound, b);
        }
    };
}

// Oracles: hand-derived step lengths (`simState`), the residual's central
// difference (the Jacobian), the diode's closed form at the clamp (the
// limited RHS), and OSDI's two RHS paths, which must agree.

test "a transient time behind the accepted point restarts dt from 0, never negative" {
    var inst = std.mem.zeroes(blobs.Instance(fixture.Rc));
    const x = [2]f64{ 0, 0 };
    const at = struct {
        fn dt(i: *blobs.Instance(fixture.Rc), xx: *const [2]f64, t: f64) f64 {
            const si: abi.SimInfo = .{ .paras = fixture.no_paras, .abstime = t, .prev_solve = xx, .prev_state = null, .next_state = null, .flags = abi.analysis_tran | abi.calc_react_residual };
            return Eval(fixture.Rc).simState(i, &si).dt;
        }
    };
    // 1 s then 2 s: steps of 1 s from 0 and from 1 s.
    try testing.expectEqual(@as(f64, 1), at.dt(&inst, &x, 1));
    try testing.expectEqual(@as(f64, 1), at.dt(&inst, &x, 2));
    // A retry at 1.5 s after 2 s is rejected: the step from 1 s.
    try testing.expectEqual(@as(f64, 0.5), at.dt(&inst, &x, 1.5));
    // 0.25 s is behind 1 s, the accepted point (0.25 - 1 = -0.75 before the
    // fix): the history restarts, the step is from 0.
    try testing.expectEqual(@as(f64, 0.25), at.dt(&inst, &x, 0.25));
    // And runs on from there: 0.75 s is a step of 0.5 s from 0.25 s.
    try testing.expectEqual(@as(f64, 0.5), at.dt(&inst, &x, 0.75));
    // A negative time (no transient's) steps 0, not below.
    try testing.expectEqual(@as(f64, 0), at.dt(&inst, &x, -1));
}

test "the Jacobian eval keeps is the residual's central difference, entry by entry" {
    var b: fixture.DioBench = undefined;
    try b.init();
    try testing.expectEqual(@as(u32, 4), fixture.DioBench.d.num_jacobian_entries);
    const x0 = [2]f64{ 0.65, 0.1 };
    _ = b.residual(x0);
    const jac = b.jacobian();
    // h = 1e-6 V: the truncation error is h²·f'''/6 ≈ 3e-10 of f' (f'''/f'
    // = 1/vt² = 1600 V⁻²), the rounding eps·f/h ≈ 1e-11 of it.
    const h = 1e-6;
    for (0..2) |c| {
        var hi = x0;
        var lo = x0;
        hi[c] += h;
        lo[c] -= h;
        const r_hi = b.residual(hi);
        const r_lo = b.residual(lo);
        for (0..2) |r| {
            const fd = (r_hi[r] - r_lo[r]) / (2 * h);
            try testing.expectApproxEqRel(fd, jac[2 * r + c], 1e-7);
        }
    }
}

test "under ENABLE_LIM the RHS is the linearization at the clamp, and OSDI's two RHS paths agree" {
    var b: fixture.DioBench = undefined;
    try b.init();
    const d = fixture.DioBench.d;
    // A previous point to limit against, inside the clamp: converged.
    try testing.expectEqual(@as(u32, 0), fixture.evalFlags(d, &b.inst, &b.model, &.{ 0.5, 0 }, 0, abi.enable_lim));
    // 1 V across the junction clamps to 0.7 V: not converged.
    const cur = [2]f64{ 1.0, 0 };
    try testing.expectEqual(abi.eval_ret_flag_lim, fixture.evalFlags(d, &b.inst, &b.model, &cur, 0, abi.enable_lim));

    // By hand at V = 0.7: f_a = is·(e − 1), f_b = −f_a, g = is·e/vt, and
    // J·x_lim − f with x_lim = (0.7, 0).
    const is = 1e-14;
    const vt = 0.025;
    const e = @exp(fixture.Dio.v_max / vt);
    const fa = is * (e - 1);
    const g = is * e / vt;
    const want = [2]f64{ g * 0.7 - fa, -g * 0.7 + fa };

    // Path 1: `load_spice_rhs_dc`, J·x − f at the limited point.
    var rhs: [2]f64 = @splat(0);
    d.load_spice_rhs_dc(&b.inst, &b.model, &rhs, &cur);
    // Path 2: what an OpenVAF host builds, J·cur − f(x_lim) + lim_rhs, from
    // `load_jacobian_resist`, `load_residual_resist` and
    // `load_limit_rhs_resist` (which subtracts lim_rhs).
    const jac = b.jacobian();
    var f: [2]f64 = @splat(0);
    d.load_residual_resist(&b.inst, &b.model, &f);
    var neg_lim: [2]f64 = @splat(0);
    d.load_limit_rhs_resist(&b.inst, &b.model, &neg_lim);
    for (0..2) |r| {
        try testing.expectApproxEqRel(want[r], rhs[r], 1e-12);
        const host = jac[2 * r] * cur[0] + jac[2 * r + 1] * cur[1] - f[r] - neg_lim[r];
        try testing.expectApproxEqRel(rhs[r], host, 1e-12);
    }
    try testing.expectApproxEqRel(fa, f[0], 1e-12);
    try testing.expectApproxEqRel(g, jac[0], 1e-12);
}

test "under INIT_LIM the seed replaces the simulator's point, and the limit RHS carries the move" {
    var b: fixture.DioBench = undefined;
    try b.init();
    const d = fixture.DioBench.d;
    // The simulator's point is ignored: `a` seeds to 0.6 V, `b` (no seed) to 0.
    const cur = [2]f64{ 5, 5 };
    _ = fixture.evalFlags(d, &b.inst, &b.model, &cur, 0, abi.init_lim);
    const is = 1e-14;
    const vt = 0.025;
    const e = @exp(fixture.Dio.v_seed / vt);
    var f: [2]f64 = @splat(0);
    d.load_residual_resist(&b.inst, &b.model, &f);
    try testing.expectApproxEqRel(is * (e - 1), f[0], 1e-12);
    // lim_rhs = J·(x − cur): row a is g·((0.6 − 5) − (0 − 5)) = 0.6·g.
    var neg_lim: [2]f64 = @splat(0);
    d.load_limit_rhs_resist(&b.inst, &b.model, &neg_lim);
    try testing.expectApproxEqRel(-0.6 * is * e / vt, neg_lim[0], 1e-12);
}
