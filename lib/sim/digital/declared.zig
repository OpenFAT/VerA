//! A declaration's constant expressions in, their elaborated values out: widths, bounds, delays, timing-check limits and each module's timescale.
//! Cites: IEEE 1364-2005 §6.1.3, §7.14, §12.2, §15.1, §19.8.
//!
//! Contents:
//! - `pub const tchkLimits`
//! - `pub const tchkSite`
//! - `pub const Times = struct`
//! - `pub fn timeOf(self: *const Run, scope: u32) ModuleTime`
//! - `pub fn constant(self: *Run, e: Ast.ExprId, tok: u32) Error!Int.Literal`
//! - `pub fn declaredBound(self: *Run, e: Ast.ExprId, tok: u32) Error!i64`
//! - `pub fn declaredDelay(self: *Run, e: Ast.ExprId, tok: u32) Error!u64`
//! - `pub fn declaredDelay3(self: *Run, d: Ast.Delay3, tok: u32) Error!Delay`
//! - `pub fn declaredWidth(self: *Run, range: Ast.Dim, tok: u32) Error!u32`

const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const Scheduler = @import("../scheduler.zig").Scheduler;
/// Scheduler ticks. `Time` below is the timescale module, not this.
const Tick = @import("../scheduler.zig").Time;
const Time = @import("../time.zig");
const deep = @import("base").deep_stack;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const display = @import("display.zig");
/// Public for the VPI (src/vpi/value.zig), which writes a value the way a
/// process does (`waiters.store` now, `exec.enqueue` of a `.write` later), so a
/// §12.30 put wakes waiters and value-change watchers like any other write.
const exec = @import("exec.zig");
/// §17 system tasks.
const system = @import("system.zig");
const driver = @import("driver.zig");
const binding = @import("bind.zig");
const elab = @import("elab.zig");
const waiters = @import("waiters.zig");
const resolution = @import("resolution.zig");
const tchk = @import("tchk.zig");
const vpi = @import("vpi.zig");
const Type = compile.Type;
const Instruction = compile.Instruction;
const Row = exec.Row;
const Delay = @import("net.zig").Delay;
const Net = @import("net.zig").Net;
const NetCold = @import("net.zig").NetCold;
const no_cold = @import("net.zig").no_cold;
const Tran = @import("net.zig").Tran;
const Signal = @import("net.zig").Signal;
const Inertial = @import("net.zig").Inertial;
const no_transition = @import("net.zig").no_transition;
const Driver = @import("net.zig").Driver;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const Show = display.Show;
const TimeFormat = display.TimeFormat;
// ---- the public surface -----------------------------------------------------
const root = @import("root.zig");
const Run = root.Run;
const Error = root.Error;
const ModuleTime = root.ModuleTime;
/// The descriptor table a `Run` with no `file_io` opens files through.
const own_files = system.own;

/// IEEE 1364-2005 §27.31 / VAMS §12.29 vpi_put_delays on the timing check
/// whose command token is `tok` in instance `scope`: `ticks` are its
/// limits in A.7.5.1's written order, from the next event it judges.
/// False when the run holds no such check.
pub const tchkLimits = tchk.putLimits;

/// `vpi.tchkSite`: a timing check's VPI handle site.
pub const tchkSite = vpi.tchkSite;

/// A run's time scales: the design's finest precision (the tick), each
/// module's §19.8 timescale, and the §17.3.2 `$timeformat` in force.
pub const Times = struct {
    /// The ROOT module's time scale; every module's own is in `module_times`.
    scale: ?Time.Scale = null,
    /// The root module's time unit as a power of ten of a second. `Scale`
    /// stores only ratios, and `%t` needs the absolute magnitude to reach
    /// §17.3's `units_number`.
    unit_exp: i32 = 0,
    /// IEEE 1364 §19.8 each module definition's own time scale, per
    /// `file.modules` row. Read through `timeOf`.
    modules: []const ModuleTime = &.{},
    format: TimeFormat = .{},
    /// IEEE 1364-2005 §26.6.41: the call that selected `time_format`, absent
    /// before execution of any $timeformat. The instance disambiguates the
    /// same source token executed in two instantiations of one definition.
    active_format: ?struct { scope: u32, tok: u32 } = null,
    /// §17.3.2 Table 17-11's default `units_number`: "the smallest time
    /// precision argument of all the `timescale compiler directives".
    finest: i32 = 0,
};

/// IEEE 1364 §19.8 the time scale of the module `scope` is an instance
/// (or a block) of: the one its delays, `$time` and `%t` are in. The
/// root's when the scope is not a module instance (a UDP's).
pub fn timeOf(self: *const Run, scope: u32) ModuleTime {
    const root_time: ModuleTime = .{ .scale = self.time.scale.?, .unit_exp = self.time.unit_exp };
    if (scope >= self.scope_info.items.len) return root_time;
    return self.time.modules[self.scope_info.items[self.instanceOf(scope)].def];
}

/// A constant expression's value at elaboration (IEEE 1364-2005 §5.2 /
/// §12.2): literals, parameters, operators and the constant system
/// functions, folded by the engine's own evaluator, so a bound and a
/// run-time expression cannot disagree about an operator. The result's
/// planes are fresh arena memory, never a literal's own.
pub fn constant(self: *Run, e: Ast.ExprId, tok: u32) Error!Int.Literal {
    assert(e != .none);
    assert(tok < self.starts.len);
    if (self.growing) |g| self.values = g.items;
    try compile.checkExpr(self, e);
    if (!compile.constantExpression(self, e)) return self.fail(tok, "a constant expression is required here", .{});
    const v = try evaluate.eval(self, self.arena, e, 0);
    const out = try filled(self.arena, v.width, v.signed, .zero);
    @memcpy(out.planes, v.planes);
    return out;
}

/// One declared bound (§3.3, §4.3.1): any constant expression, of any
/// sign (the §4.3.1 example `[-2:1]`).
pub fn declaredBound(self: *Run, e: Ast.ExprId, tok: u32) Error!i64 {
    assert(e != .none);
    assert(tok < self.starts.len);
    if (self.file.exprs.tag(e) == .int_literal) return self.file.exprs.intValue(e);
    const v = try self.constant(e, tok);
    // §4.3.1: "Both the msb constant expression and the lsb constant
    // expression shall be constant integer expressions."
    if (compile.typeOf(self, e).real) return self.fail(tok, "§4.3.1: a bound is a constant integer expression, not a real", .{});
    return v.asInt() orelse self.fail(tok, "a declaration bound cannot contain x or z", .{});
}

/// A.2.2.3 `delay_value ::= unsigned_number | real_number | identifier`, in
/// scheduler ticks. Folded at elaboration: a net's or a driver's delay is
/// fixed for the run, and only a procedural `#` re-evaluates.
///
/// The `identifier` alternative names a parameter, so anything but a
/// literal goes through `constant`.
pub fn declaredDelay(self: *Run, e: Ast.ExprId, tok: u32) Error!u64 {
    assert(e != .none);
    assert(tok < self.starts.len);
    const scale = self.timeOf(self.scope).scale;
    return switch (self.file.exprs.tag(e)) {
        .real_literal => scale.realDelay(self.file.exprs.realValue(e)),
        .int_literal => scale.signedDelay(self.file.exprs.intValue(e)),
        else => blk: { // else: any other form is a constant expression, which `constant` folds or refuses
            const v = try self.constant(e, tok);
            // §9.7.1: a real parameter is rounded to the precision like a
            // real literal, not truncated to the unit.
            if (compile.typeOf(self, e).real) break :blk scale.realDelay(try evaluate.evalReal(self, self.arena, e));
            break :blk scale.signedDelay(v.asInt() orelse return self.fail(tok, "a declared delay cannot contain x or z", .{}));
        },
    } catch self.fail(tok, "digital delay cannot be represented", .{});
}

/// One A.2.2.3 `delay3` as the three tick counts §7.14 chooses between. A
/// two-value form's `off` is "the smallest of the delays".
pub fn declaredDelay3(self: *Run, d: Ast.Delay3, tok: u32) Error!Delay {
    assert(tok < self.starts.len);
    if (!d.any()) return .{};
    var out: Delay = .{ .present = true };
    out.rise = try self.declaredDelay(d.rise, tok);
    out.fall = try self.declaredDelay(d.fall, tok);
    out.off = if (d.off != .none) try self.declaredDelay(d.off, tok) else @min(out.rise, out.fall);
    return out;
}

/// §3.3/§6.5.2 a packed `[msb:lsb]` range as a bit width.
pub fn declaredWidth(self: *Run, range: Ast.Dim, tok: u32) Error!u32 {
    assert(tok < self.starts.len);
    const hi = try self.declaredBound(range.msb, tok);
    const lo = try self.declaredBound(range.lsb, tok);
    const span = @abs(@as(i128, hi) - lo);
    if (span >= std.math.maxInt(u32)) return self.fail(tok, "packed range is outside the supported u32 width", .{});
    return @intCast(span + 1);
}
