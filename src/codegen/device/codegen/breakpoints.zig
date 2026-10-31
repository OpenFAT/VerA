//! The time-driven operators -> the host's step hooks: `delays` (each
//! §4.5.7 site's transport delay over `Model`), and `pendingBreakpoint` and
//! `nextBreakpoint` (the §5.10.5 `timer` schedule a host lands steps on).
//! Cites: §4.5.7, §4.5.14, §5.10.3.3, §5.10.5, §9.17.
//!
//! Contents:
//! - `pub fn emitDelays(self: *Gen) Error!void`
//! - `pub fn emitNextBreakpoint(self: *Gen) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_host = @import("host_expr.zig");
const gen_file = @import("file.zig");
const Error = codegen.Error;

/// Writes `delays`: each §4.5.7 site's transport delay over `Model` alone
/// (a §4.5.14 constant or parameter expression). The host lands an echo
/// breakpoint at t + td and clamps dt_max under the shortest delay. A site
/// whose delay is a solved quantity is skipped.
pub fn emitDelays(self: *Gen) Error!void {
    assert(self.out.items.len != 0);
    const saved = self.cur.uses.model;
    defer self.cur.uses.model = saved;
    self.cur.uses.model = false;
    var tds: std.ArrayList([]const u8) = .empty;
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .absdelay) continue;
        const inst = self.names.opInstOf(@intCast(i)) orelse continue;
        const args = self.mir.instData(inst).call.args;
        if (args.len < 2) continue;
        const td = try gen_host.f64Const(self, args[1], 0, false) orelse continue;
        // §4.5.7 "If td becomes greater than maxdelay, maxdelay will be used
        // as a substitute for td", as `call.absdelayTd` runs it in the
        // residual. A solve-time maxdelay is no `Model` expression: td stays.
        const maxd = if (args.len > 2) try gen_host.f64Const(self, args[2], 0, false) else null;
        try tds.append(self.arena, if (maxd) |m| try self.arena.print("@min({s}, {s})", .{ td, m }) else td);
    }
    if (tds.items.len == 0) return;
    try self.w(
        \\/// §4.5.7 transport delays, one per absdelay site. The host lands
        \\/// wavefront breakpoints at corner + td and bounds dt_max under the
        \\/// shortest delay (engine minDelay -> tran echo machinery).
        \\pub fn delays({s}: *const Model) [{d}]f64 {{
        \\    return .{{
    , .{ if (self.cur.uses.model) "model" else "_", tds.items.len });
    for (tds.items, 0..) |td, k| try self.w("{s} {s}", .{ if (k == 0) "" else ",", td });
    try self.w(" }};\n}}\n\n\n", .{});
}

/// Writes `pendingBreakpoint` (the live per-instance schedule) and
/// `nextBreakpoint` (the §5.10.5 `timer` fire times, recomputed from `Model`
/// alone): the host places a timepoint on each fire instead of across it.
///
/// All or nothing: if any timer's start or period does not render over
/// `Model`, `nextBreakpoint` is omitted. A missing hook costs accuracy; a
/// subset would tell the host this device wants no other timepoints.
pub fn emitNextBreakpoint(self: *Gen) Error!void {
    assert(self.out.items.len != 0);
    assert(self.names.units.len == self.names.unit_names.len);
    // ponytail: `enable` is honoured only when it folds to a constant zero (the
    // timer never fires) or renders over `Model` (a runtime guard). A solved
    // enable keeps its breakpoints: an extra timepoint costs a step, never an
    // answer.
    if (!gen_file.usesOp(self, .timer)) return;

    // §5.10.3.3 the live schedule: a start_time computed during the solve
    // exists only as `__next`. Every timer is listed; a disabled one costs
    // the host a timepoint, never an answer.
    try self.w(
        \\/// §5.10.3.3 the earliest timer event this instance has scheduled
        \\/// strictly after `t` — re-armed start times included.
        \\pub fn pendingBreakpoint(inst: *const Instance, t: f64) ?f64 {{
        \\    var best = std.math.inf(f64);
        \\
    , .{});
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .timer) continue;
        try self.w("    if (inst.{0s}__next > t) best = @min(best, inst.{0s}__next);\n", .{self.names.unit_names[i]});
    }
    try self.w(
        \\    return if (best == std.math.inf(f64)) null else best;
        \\}}
        \\
        \\
    , .{});

    // Render first: `f64Const` sets `uses.model`, and an unused `model`
    // parameter does not compile.
    const saved = self.cur.uses.model;
    defer self.cur.uses.model = saved;
    self.cur.uses.model = false;

    const Timer = struct { start: []const u8, period: []const u8, guard: ?[]const u8 };
    var timers: std.ArrayList(Timer) = .empty;
    for (self.names.units, 0..) |u, i| {
        if (u.role != .analog_op or u.op != .timer) continue;
        const inst = self.names.opInstOf(@intCast(i)) orelse return;
        const args = self.mir.instData(inst).call.args;
        // §5.10.3.3 "if enable is specified and it is zero, then timer() is
        // inactive": such a timer adds no breakpoint and vetoes no other.
        var guard: ?[]const u8 = null;
        if (@import("ir").op.enableArg(.timer)) |ei| {
            if (ei < args.len) {
                if (self.an.foldConst(args[ei], false)) |c| {
                    if (c == 0.0) continue;
                } else if (try gen_host.f64Const(self, args[ei], 0, false)) |e| {
                    guard = e;
                }
            }
        }
        // No diagnostic: an unrenderable period already has one, and a solved
        // start_time is legal Verilog-A this hook cannot describe.
        const start = try gen_host.f64Const(self, if (args.len > 0) args[0] else .zero, 0, false) orelse return;
        const period = try gen_host.f64Const(self, if (args.len > 1) args[1] else .zero, 0, false) orelse return;
        try timers.append(self.arena, .{ .start = start, .period = period, .guard = guard });
    }
    if (timers.items.len == 0) return;

    try self.w(
        \\/// §5.10.5 the earliest `timer` fire strictly after `t`, so the host
        \\/// puts a timepoint ON the discontinuity instead of across it.
        \\pub fn nextBreakpoint({s}: *const Model, t: f64) ?f64 {{
        \\    var best = std.math.inf(f64);
        \\
    , .{if (self.cur.uses.model) "model" else "_"});
    for (timers.items) |tm| {
        if (tm.guard) |g| try self.w("    if (({s}) != 0.0) {{\n    ", .{g});
        try self.w("    if (zNextTimer({s}, {s}, t)) |b| best = @min(best, b);\n", .{ tm.start, tm.period });
        if (tm.guard != null) try self.w("    }}\n", .{});
    }
    try self.w(
        \\    return if (best == std.math.inf(f64)) null else best;
        \\}}
        \\
        \\
    , .{});
}
