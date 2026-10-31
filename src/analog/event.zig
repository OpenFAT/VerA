//! §5.10 analog events: an `@(...)` event control in, a guard out: each
//! event term becomes a `call` whose integer result codegen answers from the
//! simulator state (§5.10.2 global events, §5.10.3 monitored events), a
//! digital term the explicit D2A flag (§8.5.3.6), and a named event its flag
//! (§5.10.4). The body lowers under the guard as a runtime branch.
//!
//! Cites: §2.7, §3.3, §5.8, §5.9, §5.10, §5.10.1, §5.10.2, §5.10.3,
//! §5.10.3.1, §5.10.3.3, §5.10.3.4, §5.10.4, A.6.4, A.6.5, §7.3.4, §7.3.6.2,
//! §8.5.3.6.
//!
//! Contents:
//! - `pub fn lowerEventControl(self: *Lower, event: Ast.ExprId, body: Ast.StmtId) Oom!void`
//! - `pub const EventRef = struct`
//! - `pub fn eventRef(self: *Lower, e: Ast.ExprId) Oom!?EventRef`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_timer = @import("timer.zig");
const lower_constfold = @import("constfold.zig");
const lower_control = @import("control.zig");
const lower_expr = @import("expr.zig");
const lower_shape = @import("shape.zig");
const Ssa = @import("ssa.zig");
const lower_assign = @import("assign.zig");
const lower_lvalue = @import("lvalue.zig");
const lower_event_args = @import("event_args.zig");
const TimerCapture = lower_timer.TimerCapture;
const Oom = Lower.Oom;

/// The §5.10.4 event flags an event reference names, each with the condition
/// that it is the one named at this evaluation.
pub const EventRef = struct { places: []const Ssa.Place, conds: []const Mir.Value };

/// Lowers an analog event control to a guard: the event becomes a `call` whose
/// integer result codegen answers from the simulator state, and the body runs
/// only when it is set (LRM §5.10, §5.10.2, §5.10.3).
pub fn lowerEventControl(self: *Lower, event: Ast.ExprId, body: Ast.StmtId) Oom!void {
    assert(event == .none or self.exprValid(event));
    assert(body == .none or @backingInt(body) < self.stmtCount());
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(event), .E0702, "not allowed in {s}", .{ctx});
        return;
    }
    // §5.10 "Nested event control statements are not allowed" — and A.6.4
    // agrees: `analog_event_statement` has no
    // `analog_event_control_statement` alternative.
    if (self.in_event_stmt) {
        try self.err(self.file.exprs.mainTok(event), .E0703, "", .{});
        return;
    }
    // §5.8 "Event control statements (e.g.: timer, cross) cannot be used inside
    // conditional statements unless the conditional expression is a constant
    // expression"; §5.9 bans them in repeat/while/non-genvar for outright;
    // §5.10.3.1 repeats it for `cross`. Stricter than E0514 on purpose: the
    // carve-out here is a constant expression, so `analysis("dc")` does not
    // license it and `static_cond_depth` is not consulted.
    if (self.cond_depth != 0) {
        var b = self.errWith(self.file.exprs.mainTok(event), .E0707);
        b.help("put `@(...)` on the spine and make the statement it guards conditional", .{});
        try b.emit();
    }
    const cond = try lowerEventExpr(self, event) orelse return;
    const prev = self.in_event_stmt;
    self.in_event_stmt = true;
    defer self.in_event_stmt = prev;
    const prev_d2a = self.in_d2a_body;
    defer self.in_d2a_body = prev_d2a;
    if (hasD2aTerm(self, event)) self.in_d2a_body = true;
    // §5.10 an event's `hit` flag changes during the solve, so it is never static.
    try lower_control.lowerBranchStmt(self, cond, body, .none, false, .none);
}

/// Resolves `ev` or `ev[i]…` (A.6.5 `hierarchical_event_identifier
/// { [ expression ] }`) to its flags. A scalar event and a constant subscript
/// name one flag; a runtime subscript names every element, the element `k`
/// guarded by "the flat index is `k`" (`lower_assign.runtimeArrayIndex`'s
/// order, -1 when out of range). So a trigger raises, and a detection reads,
/// only the element the subscript selects now: §5.10.4 "an event is not made
/// to occur by changing the index of an event array in an event control
/// expression", since a changed index reads a flag nothing raised. Null after
/// a diagnostic.
pub fn eventRef(self: *Lower, e: Ast.ExprId) Oom!?EventRef {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    const ex = &self.file.exprs;
    const tok = ex.mainTok(e);
    if (ex.tag(e) == .ident) {
        const name = self.file.str(ex.strOf(e));
        if (self.event_arrays.contains(name)) {
            try self.err(tok, .E0356, "`{s}` is an event array; an event control or trigger names one element", .{name});
            return null;
        }
        const p = self.events.get(name) orelse {
            try self.err(tok, .E0705, "`{s}`", .{name});
            return null;
        };
        return .{ .places = try self.arena.dupe(Ssa.Place, &.{p}), .conds = try self.arena.dupe(Mir.Value, &.{.one}) };
    }
    var subs_buf: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
    const chain = (try lower_lvalue.indexChain(self, e, &subs_buf)) orelse {
        try self.err(tok, .E0706, "", .{});
        return null;
    };
    const name = self.file.str(chain.name);
    const bounds = self.event_arrays.get(name) orelse {
        try self.err(tok, .E0705, "`{s}` is not an event array", .{name});
        return null;
    };
    if (!try lower_lvalue.checkSubscriptCount(self, e, name, .{ .dims = bounds, .ty = .integer }, chain.subs.len)) return null;
    var buf: [lower_shape.max_stack_dims]i64 = undefined;
    const idx = try lower_shape.subscriptBuf(self, &buf, bounds.len);
    const constant = for (chain.subs, idx) |s, *o| {
        const c = lower_constfold.constEval(self, s) orelse break false;
        o.* = c.asIntExact() orelse break false;
    } else true;
    if (constant) {
        if (!try lower_lvalue.checkSubscripts(self, e, name, .{ .dims = bounds, .ty = .integer }, idx)) return null;
        const p = self.events.get(try lower_shape.elemName(self, name, idx)).?;
        return .{ .places = try self.arena.dupe(Ssa.Place, &.{p}), .conds = try self.arena.dupe(Mir.Value, &.{.one}) };
    }
    const flat = try lower_assign.runtimeArrayIndex(self, chain.subs, bounds);
    const n = lower_shape.shapeCells(bounds);
    const places = try self.arena.alloc(Ssa.Place, n);
    const conds = try self.arena.alloc(Mir.Value, n);
    for (places, conds, 0..) |*p, *c, k| {
        lower_shape.shapeSubscripts(bounds, k, idx);
        p.* = self.events.get(try lower_shape.elemName(self, name, idx)).?;
        c.* = try self.emit(.ieq, &.{ flat, try self.mir.addIntConst(self.arena, @intCast(k)) });
    }
    return .{ .places = places, .conds = conds };
}

// ---- private ----

fn hasD2aTerm(self: *Lower, e: Ast.ExprId) bool {
    assert(e == .none or self.exprValid(e));
    assert(self.exprValid(e));
    const ex = &self.file.exprs;
    if (ex.tag(e) == .event_or) return hasD2aTerm(self, ex.lhs(e)) or hasD2aTerm(self, ex.rhs(e));
    return self.out.discrete_events.contains(e);
}

/// §5.10.1 or-lists, §5.10.2 initial_step/final_step, §5.10.3 cross/above/timer.
fn lowerEventExpr(self: *Lower, e: Ast.ExprId) Oom!?Mir.Value {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    const ex = &self.file.exprs;
    // §7.3.4 / §7.3.6.2 a digital event term: the explicit D2A flag the host
    // raises for the solve at the tick the event occurred in (§8.5.3.6).
    if (self.out.discrete_events.get(e)) |site|
        return self.param_values.items[self.param_index.get(site.param).?];
    switch (ex.tag(e)) {
        // §5.10.1 `@(a or b)` — active when either is.
        .event_or => {
            const a = try lowerEventExpr(self, ex.lhs(e)) orelse return null;
            const b = try lowerEventExpr(self, ex.rhs(e)) orelse return null;
            return try self.emit(.logor, &.{ a, b });
        },
        // §5.10.2 global events; the analysis-name arguments select which
        // analyses they fire in (`initial_step("dc","tran")`).
        .event_initial_step, .event_final_step => {
            const name = if (ex.tag(e) == .event_initial_step) "initial_step" else "final_step";
            var args: std.ArrayList(Mir.Value) = .empty;
            defer args.deinit(self.arena);
            if (ex.extraOf(e) < ex.poolLen()) {
                for (ex.nameParts(e)) |p|
                    try args.append(self.arena, try self.mir.addStrConst(self.arena, self.file.str(p)));
            }
            return try self.call(name, args.items);
        },
        // §5.10.3 monitored events.
        .event_function => {
            const name = self.file.str(ex.strOf(e));
            if (std.mem.eql(u8, name, "absdelta")) {
                // §5.10.3.4 "only allowed in an initial or always block": in a
                // digital process it is the mixed-signal kernel's monitor, and
                // here it is misplaced.
                try self.err(self.file.exprs.mainTok(e), .E0513, "", .{});
                return null;
            }
            if (!try lower_event_args.checkEventArgBounds(self, e, name)) return null; // §5.10.3.1-§5.10.3.3
            var args: std.ArrayList(Mir.Value) = .empty;
            defer args.deinit(self.arena);
            var captured: TimerCapture = .empty;
            const is_timer = std.mem.eql(u8, name, "timer");
            for (ex.args(e), 0..) |a, k| {
                // A.6.5 permits omitted arguments; keep the position.
                if (a == .none) {
                    try args.append(self.arena, .f_zero);
                    continue;
                }
                if (is_timer and k < 2) self.timer_state.timer_capture = &captured;
                defer self.timer_state.timer_capture = null;
                // §2.7 reads a string literal operand as an unsigned integer
                // constant (`cross("s")` monitors 115, which never crosses);
                // a §3.3 string-typed value has no number to monitor.
                const tv = try self.strNum(try lower_expr.lowerExpr(self, a));
                if (tv.ty == .string) {
                    try self.err(ex.mainTok(a), .E0517, "`{s}()` argument {d} is a string", .{ name, k + 1 });
                    return null;
                }
                try args.append(self.arena, try self.toReal(tv));
            }
            const result = try self.call(name, args.items);
            if (is_timer) try self.timer_state.timers.append(self.arena, .{
                .inst = self.mir.valueDef(result).inst_result,
                .unit = self.cur_unit,
                .scope_path = self.scope_path,
                .block_path = self.block_path,
                .args = ex.args(e),
                .values = .{ args.items[0], if (args.items.len > 1) args.items[1] else .f_zero },
                .captured = captured,
            });
            return result;
        },
        .event_posedge, .event_negedge => {
            try self.err(self.file.exprs.mainTok(e), .E0704, "", .{});
            return null;
        },
        // §5.10.4 `@ hierarchical_event_identifier`: the event's flag is the
        // guard. In scope for Verilog-A: §5.10 lists named events as an analog
        // event kind, and annex C.7 excludes only digital behaviour and events.
        // §5.10.4 an event array element: active when the element the
        // subscript names now was triggered.
        .ident, .index => {
            const r = try eventRef(self, e) orelse return null;
            var any: Mir.Value = .zero;
            for (r.places, r.conds) |p, c| {
                const hit = try self.emit(.logand, &.{ c, try self.builder.readVariable(p, self.cur) });
                any = if (any == .zero) hit else try self.emit(.logor, &.{ any, hit });
            }
            return any;
        },
        else => { // else: not an event expression: E0706
            try self.err(self.file.exprs.mainTok(e), .E0706, "", .{});
            return null;
        },
    }
}

test "lower: §5.8/§5.10.3.1 an event control statement is stricter than E0514" {
    // §5.8: event control "cannot be used inside conditional statements unless
    // the conditional expression is a constant expression" — CONSTANT, not
    // analysis_or_constant. So the very condition that licenses `ddt` above
    // still rejects `@(cross(...))`, and the two rules must not share a counter.
    const cases = [_]struct { cond: []const u8, warns: bool }{
        .{ .cond = "V(c) > 0.5", .warns = true },
        .{ .cond = "analysis(\"dc\")", .warns = true },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p, c);
            \\  inout p, c;
            \\  electrical p, c;
            \\  real held;
            \\  analog begin
            \\    held = 0.0;
            \\    if ({s}) @(cross(V(c) - 1.0, 1)) held = V(p);
            \\    I(p) <+ held;
            \\  end
            \\endmodule
        , .{c.cond});
        defer std.testing.allocator.free(src);

        var h: Lower.Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        if (h.low.lowerFile()) |_| {} else |e| switch (e) {
            error.DiagnosticsReported => {},
            else => return e,
        }

        var seen = false;
        for (0..h.bag.count()) |i| {
            if (h.bag.at(i).code == .E0707) seen = true;
        }
        std.testing.expectEqual(c.warns, seen) catch |e| {
            std.debug.print("condition: if ({s})\n", .{c.cond});
            return e;
        };
    }
}
