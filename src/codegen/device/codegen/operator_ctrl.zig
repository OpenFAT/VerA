//! A §4.5 operator's control arguments (delay, tolerance, enable, period,
//! direction) -> their text in the frame that reads them: `ctrlEval` in the
//! residual's (an `S` expression, or a host `f64` when it folds), `ctrlStep` in
//! `updateState`'s (a core field `plan_jobs` queued). Also the per-site facts
//! those frames depend on: whether an `absdelay` td or maxdelay is frozen into
//! `Instance`, and whether a `cross` locates its own events.
//! Cites: §4.5, §4.5.7, §4.5.10, §4.5.14, §5.10.3, §5.10.3.1, §5.10.3.3.
//!
//! Contents:
//! - `pub fn ctrlEval(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8`
//! - `pub fn absdelayTd(self: *Gen, n: []const u8, args: []const Mir.Value, step: bool) Error![]const u8`
//! - `pub fn absdelayMaxdSampled(self: *Gen, args: []const Mir.Value) Error!bool`
//! - `pub fn absdelayFreezes(self: *Gen, args: []const Mir.Value) Error!bool`
//! - `pub fn ctrlStep(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8`
//! - `pub fn timerPeriod(self: *Gen, args: []const Mir.Value) Error![]const u8`
//! - `pub fn crossTest(self: *Gen, n: []const u8, args: []const Mir.Value, in: []const u8, step: bool) Error![]const u8`
//! - `pub fn lastCrossTime(self: *Gen, n: []const u8, in: []const u8) Error![]const u8`
//! - `pub fn crossLocated(self: *Gen, args: []const Mir.Value) Error!bool`
//! - `pub fn anyCrossLocated(self: *Gen) Error!bool`
//! - `pub fn enableTest(self: *Gen, k: OpKind, args: []const Mir.Value) Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_cfg = @import("cfg.zig");
const gen_render = @import("render.zig");
const gen_host = @import("host_expr.zig");
const Mir = @import("ir").Mir;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const ir_op = @import("ir").op;
const OpKind = ir_op.OpKind;

/// Returns a dynamic (§4.5 Table 4-20) control argument's value in the
/// residual's frame: `f64Const`'s text when it folds, else the rendered S
/// expression's `.val()`, which pins lanes. `ctrlStep` is the `updateState`
/// Asserts that `dflt` is not empty. The result is arena-owned.
/// frame's counterpart.
pub fn ctrlEval(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
    assert(dflt.len != 0);
    assert(i < 16); // An operator has at most a handful of arguments.
    if (i >= args.len) return dflt;
    if (try gen_host.f64Const(self, args[i], 0, false)) |s| return s;
    // The collapse is intended: a control argument (or §4.6.3's stimulus
    // magnitude) configures the operator and is not part of the Jacobian.
    float_lanes.pinLanes(self, self.an.rv(args[i]));
    return self.arena.print("({s}).val()", .{
        try gen_render.renderToArena(self, args[i], .real),
    });
}

/// Returns the §4.5.7 effective delay of one `absdelay` site in the caller's
/// frame (`step`: `updateState`'s, else the residual's). A frozen td reads
/// its `Instance` field; with `maxdelay`, td is clamped to it.
/// Asserts that `n` names the site and that `args` is `absdelay`'s list
/// (input, td and an optional maxdelay). The result is arena-owned.
pub fn absdelayTd(self: *Gen, n: []const u8, args: []const Mir.Value, step: bool) Error![]const u8 {
    assert(n.len != 0);
    assert(args.len <= 3);
    if (try absdelayFreezes(self, args))
        return self.arena.print("inst.{s}__td", .{n});
    const td = if (step)
        try ctrlStep(self, args, 1, "0.0")
    else
        try ctrlEval(self, args, 1, "0.0");
    if (args.len < 3) return td;
    // §4.5.7 "If td becomes greater than maxdelay, maxdelay will be used as
    // a substitute for td." Table 4-20 makes maxdelay the constant argument,
    // so it renders over Model where td renders over the core.
    return self.arena.print("@min({s}, {s})", .{
        td,
        if (try absdelayMaxdSampled(self, args))
            try self.arena.print("inst.{s}__maxd", .{n})
        else
            try gen_host.argF64(self, args, 2, "0.0"),
    });
}

/// Returns whether a signal-valued `maxdelay` is latched into `Instance` at
/// the start of the analysis instead of refused (§4.5.14: "the value of the
/// dynamic expression at the start of the analysis defaults to the constant
/// value of the argument").
pub fn absdelayMaxdSampled(self: *Gen, args: []const Mir.Value) Error!bool {
    assert(args.len <= 3);
    // ponytail: `absdelay`'s maxdelay and the filter coefficients
    // (`sampledCoefs`) only. Every other constant slot still answers a solve
    // result with E0515; the same latch is the upgrade path.
    if (args.len != 3) return false;
    return gen_host.ctrlIsDynamic(self, args[2]);
}

/// Returns whether a two-argument `absdelay`'s td is signal-valued and so
/// frozen into `Instance` (§4.5.7: "any future changes to td shall be
/// ignored").
pub fn absdelayFreezes(self: *Gen, args: []const Mir.Value) Error!bool {
    assert(args.len <= 3);
    if (args.len != 2) return false;
    return gen_host.ctrlIsDynamic(self, args[1]);
}

/// Returns a control argument's value in `updateState`'s frame: `f64Const`'s
/// text, else the core field `buildJobs` queued (`m.f<k>.v`). With no field
/// it reports E0515 through `f64Expr` rather than guess.
/// Asserts that `dflt` is not empty and that the core's field map covers
/// every value. The result is arena-owned.
pub fn ctrlStep(self: *Gen, args: []const Mir.Value, i: usize, dflt: []const u8) Error![]const u8 {
    assert(dflt.len != 0);
    assert(self.core.lo_idx.len == 0 or self.core.lo_idx.len == self.an.nv);
    if (i >= args.len) return dflt;
    if (try gen_host.f64Const(self, args[i], 0, false)) |s| return s;
    const k = self.core.lo_idx[@backingInt(self.an.rv(args[i]))];
    if (k != none_u32) assert(k < self.core.lo_vals.len);
    if (k == none_u32) return gen_host.f64Expr(self, args[i]);
    return self.arena.print("m.f{d}.v", .{k});
}

/// Returns §5.10.3.3's period as `updateState` reads it: inline when it
/// folds, else the core field `buildJobs` queued, so "the next event will be
/// scheduled based on the latest value".
/// The result is arena-owned. Asserts that a queued field indexes the core.
pub fn timerPeriod(self: *Gen, args: []const Mir.Value) Error![]const u8 {
    // §5.10.3.3 `timer(start, period, ...)`: the period is argument 1.
    assert(args.len <= 4);
    if (args.len < 2) return "0.0";
    if (self.an.foldConst(args[1], false) == null) {
        const lo = self.core.lo_idx[@backingInt(self.an.rv(args[1]))];
        if (lo != none_u32) return self.arena.print("m.f{d}.v", .{lo});
        assert(lo == none_u32);
    }
    return gen_host.argF64(self, args, 1, "0.0");
}

/// Returns the test "the signal crossed zero since the last accepted step, in
/// the direction argument 1 asks for" (+1 rising, -1 falling, 0 or absent
/// either), shared by §4.5.10 `last_crossing` and §5.10.3 `cross`. `in` is
/// the current input as a plain f64 expression, compared against `__prev`.
///
/// A direction that folds without parameters picks its comparison here;
/// any other becomes `zCrossDir` on its value. §5.10.3.1 and Table 4-20 make
/// `dir` an `analog_expression`, so a solve-time one is read where the caller
/// is (`step`: `updateState`'s core field, `buildJobs` queues it; else the
/// residual's own value), never refused.
/// Asserts that `n` and `in` are not empty. The result is arena-owned.
pub fn crossTest(self: *Gen, n: []const u8, args: []const Mir.Value, in: []const u8, step: bool) Error![]const u8 {
    assert(n.len != 0);
    assert(in.len != 0);
    const arg: Mir.Value = if (args.len > 1) args[1] else .zero;
    if (self.an.foldConst(arg, false)) |c| {
        // §5.10.3.1 "For any other values of dir, the cross() function does
        // not generate an event". §4.5.10's direction is the same closed
        // set, so `last_crossing` reads it the same way.
        if (c == 1.0) return self.arena.print("inst.{0s}__prev <= 0.0 and {1s} > 0.0", .{ n, in });
        if (c == -1.0) return self.arena.print("inst.{0s}__prev >= 0.0 and {1s} < 0.0", .{ n, in });
        if (c != 0.0) return "false";
        return self.arena.print(
            "(inst.{0s}__prev <= 0.0 and {1s} > 0.0) or (inst.{0s}__prev >= 0.0 and {1s} < 0.0)",
            .{ n, in },
        );
    }
    const dir = if (args.len < 2) "0.0" else if (step) try ctrlStep(self, args, 1, "0.0") else try ctrlEval(self, args, 1, "0.0");
    return self.arena.print("zCrossDir({s}, inst.{s}__prev, {s})", .{ dir, n, in });
}

/// Returns the §4.5.10 crossing time inside the step ending at `sim.t`: the
/// zero of the line through (`sim.t - sim.dt`, `__prev`) and (`sim.t`, `in`),
/// the "linear interpolation" §4.5.10 names. `updateState` latches it where
/// `crossTest` holds; `eval` answers there with `zLastCross`, the same
/// operations in the same order, so the accepted point and every later one
/// read the same bits.
/// Asserts that `n` and `in` are not empty. The result is arena-owned.
pub fn lastCrossTime(self: *Gen, n: []const u8, in: []const u8) Error![]const u8 {
    assert(n.len != 0);
    assert(in.len != 0);
    return self.arena.print("(sim.t - sim.dt) + inst.{0s}__prev / (inst.{0s}__prev - {1s}) * sim.dt", .{ n, in });
}

/// Returns whether a §5.10.3.1 `cross` gives its own tolerance box, so
/// `updateState` publishes where a late event should have fired
/// (`Instance.vera_cross_retry__`, `zCrossRetry`): time_tol is written and
/// both tolerances fold to card values. A dynamic tolerance, or an enable
/// that is not a nonzero literal, keeps the grid's answer (VD-066).
// ponytail: a solve-time tolerance would need its own core slot; add one
// when a model writes it.
pub fn crossLocated(self: *Gen, args: []const Mir.Value) Error!bool {
    // §5.10.3.1 `cross(expr, dir, time_tol, expr_tol, enable)`.
    assert(args.len <= 5);
    if (args.len < 3) return false;
    for (args[2..@min(args.len, 4)]) |a| if (try gen_host.ctrlIsDynamic(self, a)) return false;
    if (args.len < 5) return true;
    const en = self.an.foldConst(args[4], false) orelse return false;
    return en != 0.0;
}

/// Returns whether any `cross` in the module is `crossLocated`.
pub fn anyCrossLocated(self: *Gen) Error!bool {
    assert(self.names.units.len == self.names.unit_names.len);
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .cross) continue;
        const inst = self.names.opInstOf(@intCast(i)) orelse continue;
        if (try crossLocated(self, self.mir.instData(inst).call.args)) return true;
    }
    return false;
}

/// Returns the §5.10.3 enable test for `cross`, `above` or `timer` ("If
/// enable argument is specified and it is zero, then <op>() is inactive"), or
/// `true` when absent. The enable is a live expression; `UnitPlan` gives it
/// a slot (`callArgIsValue`).
/// Writes nothing to `out` on return (the text is rendered into the arena).
pub fn enableTest(self: *Gen, k: OpKind, args: []const Mir.Value) Error![]const u8 {
    assert(k == .cross or k == .above or k == .timer);
    const i = ir_op.enableArg(k) orelse return "true";
    if (i >= args.len) return "true";
    const at = self.out.items.len;
    try gen_cfg.renderCond(self, args[i]);
    const s = try self.arena.dupe(u8, self.out.items[at..]);
    self.out.shrinkRetainingCapacity(at);
    assert(self.out.items.len == at);
    return s;
}
