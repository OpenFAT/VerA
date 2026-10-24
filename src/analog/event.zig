//! §5.10 analog events: `@(...)`, cross/above/timer, initial_step/final_step.
//!
//! In: event-controlled statements. Out: event-guarded MIR (the event is a
//! `call` codegen answers from the simulator state), and for a `timer` whose
//! arguments still move after the event, the `Lowered.timer_controls` row the
//! host schedules the next firing from (§5.10.3.3).
//!
//! Spine: `lowerEventControl` → `lowerEventExpr` at each `@(...)`. While a
//! timer's arguments lower, `analog/expr.zig` and `analog/func.zig` feed the
//! capture (`captureExpr`, `captureTimerArray`, `suspendCapture`).
//! `finishTimers` runs once, after every analog block, and replays the
//! captured arguments against the block's final values.
//!
//! LRM clauses this file's code cites: §2.7, §3.3, §5.8, §5.9, §5.10, §5.10.1, §5.10.2,
//! §5.10.3, §5.10.3.1, §5.10.3.2, §5.10.3.3, §5.10.3.4, §5.10.4, §7.3.1, §7.3.4,
//! §7.3.6.2, §8.5.3.6.

const std = @import("std");
const Lower = @import("lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_control = @import("control.zig");
const lower_expr = @import("expr.zig");
const lower_stmt = @import("stmt.zig");
const lower_shape = @import("shape.zig");
const lower_var = @import("var.zig");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Mir = @import("ir").Mir;
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const VarSlot = Lower.VarSlot;
const Ssa = @import("ssa.zig");

/// This file's private state on `Lower` (`Lower.event_state`).
pub const State = struct {
    /// Timer arguments have an at-event value and an end-of-evaluation value.
    /// Capture expression dependencies while lowering once; recompute pure
    /// expressions, never event bodies, stateful operators or effectful calls.
    /// Non-null only while a `timer`'s first two arguments lower.
    timer_capture: ?*TimerCapture = null,
    /// Non-null only inside `finishTimers`' re-lowering: the values the replay
    /// already decided, which `replayedExpr` answers before any lowering.
    timer_replay: ?*const std.AutoHashMapUnmanaged(Ast.ExprId, TypedValue) = null,
    /// Every `timer` lowered so far, in source order, for `finishTimers`.
    timers: std.ArrayList(DeferredTimer) = .empty,
    /// Memo of `timerFunctionPure`, by function name.
    timer_functions: std.AutoHashMapUnmanaged(Ast.StrId, bool) = .empty,
};

/// What one expression read while a timer argument was captured.
const CapturedExpr = struct {
    value: TypedValue,
    variable: ?VarSlot = null,
    /// Input reads AFTER an effectful call's one evaluation. Its own inout
    /// writes have already happened, and must not request another execution.
    effects: ?[]const TimerRead = null,
};
/// One variable a capture read, and the value it held at the read.
const TimerRead = struct { slot: VarSlot, value: Mir.Value };
/// One scalarized element of a captured array: its `vars` name and its read.
const TimerCell = struct { name: []const u8, read: TimerRead };
/// One array a timer argument read: scalarized (`cells`, one per element that
/// exists) or memory-backed (`memory`, the storage version at the read).
const TimerArray = struct {
    name: []const u8,
    info: Lower.ArrayInfo,
    cells: []const TimerCell,
    memory: ?Mir.Value = null,
};
/// Everything one `timer` call's arguments read, keyed by expression and by
/// array name.
const TimerCapture = struct {
    exprs: std.AutoHashMapUnmanaged(Ast.ExprId, CapturedExpr) = .empty,
    arrays: std.StringHashMapUnmanaged(TimerArray) = .empty,
    const empty: TimerCapture = .{};
};
/// One `timer` call awaiting `finishTimers`: the call, the arguments it was
/// lowered from and their at-event values, and what they read.
const DeferredTimer = struct {
    inst: Mir.Inst,
    /// Context of the original call, including readonly module queries made
    /// by a pure function after other flattened analog blocks were lowered.
    unit: u32,
    scope_path: []const u8,
    block_path: []const u8,
    args: []const Ast.ExprId,
    values: [2]Mir.Value,
    captured: TimerCapture,
};

// ---- §5.10 events -----------------------------------------------------------

/// Lowers an analog event control to a guard: the event becomes a `call` whose
/// integer result codegen answers from the simulator state, and the body runs
/// only when it is set (LRM §5.10, §5.10.2, §5.10.3).
pub fn lowerEventControl(self: *Lower, event: Ast.ExprId, body: Ast.StmtId) Oom!void {
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

fn hasD2aTerm(self: *Lower, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    if (ex.tag(e) == .event_or) return hasD2aTerm(self, ex.lhs(e)) or hasD2aTerm(self, ex.rhs(e));
    return self.out.discrete_events.contains(e);
}

/// §5.10.1 or-lists, §5.10.2 initial_step/final_step, §5.10.3 cross/above/timer.
fn lowerEventExpr(self: *Lower, e: Ast.ExprId) Oom!?Mir.Value {
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
            if (!try checkEventArgBounds(self, e, name)) return null; // §5.10.3.1-§5.10.3.3
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
                if (is_timer and k < 2) self.event_state.timer_capture = &captured;
                defer self.event_state.timer_capture = null;
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
            if (is_timer) try self.event_state.timers.append(self.arena, .{
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

/// The §5.10.4 event flags an event reference names, each with the condition
/// that it is the one named at this evaluation.
pub const EventRef = struct { places: []const Ssa.Place, conds: []const Mir.Value };

/// Resolves `ev` or `ev[i]…` (A.6.5 `hierarchical_event_identifier
/// { [ expression ] }`) to its flags. A scalar event and a constant subscript
/// name one flag; a runtime subscript names every element, the element `k`
/// guarded by "the flat index is `k`" (`lower_stmt.runtimeArrayIndex`'s
/// order, -1 when out of range). So a trigger raises, and a detection reads,
/// only the element the subscript selects now: §5.10.4 "an event is not made
/// to occur by changing the index of an event array in an event control
/// expression", since a changed index reads a flag nothing raised. Null after
/// a diagnostic.
pub fn eventRef(self: *Lower, e: Ast.ExprId) Oom!?EventRef {
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
    const chain = (try lower_stmt.indexChain(self, e, &subs_buf)) orelse {
        try self.err(tok, .E0706, "", .{});
        return null;
    };
    const name = self.file.str(chain.name);
    const bounds = self.event_arrays.get(name) orelse {
        try self.err(tok, .E0705, "`{s}` is not an event array", .{name});
        return null;
    };
    if (!try lower_stmt.checkSubscriptCount(self, e, name, .{ .dims = bounds, .ty = .integer }, chain.subs.len)) return null;
    var buf: [lower_shape.max_stack_dims]i64 = undefined;
    const idx = try lower_shape.subscriptBuf(self, &buf, bounds.len);
    const constant = for (chain.subs, idx) |s, *o| {
        const c = lower_constfold.constEval(self, s) orelse break false;
        o.* = c.asIntExact() orelse break false;
    } else true;
    if (constant) {
        if (!try lower_stmt.checkSubscripts(self, e, name, .{ .dims = bounds, .ty = .integer }, idx)) return null;
        const p = self.events.get(try lower_shape.elemName(self, name, idx)).?;
        return .{ .places = try self.arena.dupe(Ssa.Place, &.{p}), .conds = try self.arena.dupe(Mir.Value, &.{.one}) };
    }
    const flat = try lower_stmt.runtimeArrayIndex(self, chain.subs, bounds);
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

/// Checks §5.10.3's monitored-event arguments (E0517), in both analog and
/// digital event controls. Numeric bounds apply only to folded operands;
/// cross()'s dependencies between omitted slots are structural.
pub fn checkEventArgBounds(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!bool {
    const args = self.file.exprs.args(e);
    // §5.10.3: a monitored event names what it monitors. A required slot
    // left empty (`cross()`, `timer(, 1n)`, `absdelta(V(a))`) is refused
    // here, before lowering reads the argument that is not there; A.6.5's
    // permission to omit covers only the optional slots.
    var complete = true;
    for (requiredSlots(name), 0..) |slot, i| if (i >= args.len or args[i] == .none) {
        try self.err(self.file.exprs.mainTok(e), .E0517, "`{s}()` requires its {s} argument", .{ name, slot });
        complete = false;
    };
    // A.6.5 writes the enable, every form's last slot, `analog_expression`
    // and not `_or_null`: a comma before it promises one (`timer(0, 1n,
    // 1p, )` derives from nothing).
    const last: ?usize = if (std.mem.eql(u8, name, "absdelta")) 4 else enableSlot(name);
    if (last) |k| if (k < args.len and args[k] == .none) {
        try self.err(self.file.exprs.mainTok(e), .E0517, "`{s}()` has a comma before its enable and no enable", .{name});
        complete = false;
    };
    if (!complete) return false;
    // "enable ... shall evaluate to an integer" (§5.10.3.1-§5.10.3.3); only a
    // folded non-integral value is refused. absdelta's is checked below.
    if (enableSlot(name)) |k| if (k < args.len and args[k] != .none) {
        if (lower_constfold.foldExpr(self, args[k], false)) |c| {
            if (c != .str and c.asReal() != @round(c.asReal()))
                try self.err(self.file.exprs.mainTok(args[k]), .E0517, "`{s}()` enable shall evaluate to an integer, got {d}", .{ name, c.asReal() });
        }
    };
    if (std.mem.eql(u8, name, "absdelta")) {
        // §5.10.3.4: delta and both tolerances "shall be non-negative";
        // enable "shall evaluate to an integer". These are analog_expression
        // slots: a model card or a runtime value can make them valid, so a
        // declared parameter default is not sufficient to reject the source.
        const bounds = [_][]const u8{ "delta", "time_tol", "expr_tol" };
        for (bounds, 1..) |arg_name, i| {
            if (i >= args.len or args[i] == .none) continue;
            const c = lower_constfold.foldExpr(self, args[i], false) orelse continue;
            if (c == .str or c.asReal() >= 0) continue;
            try self.err(self.file.exprs.mainTok(args[i]), .E0517, "`absdelta()` {s} shall be non-negative, got {d}", .{ arg_name, c.asReal() });
        }
        if (args.len > 4 and args[4] != .none) {
            if (lower_constfold.foldExpr(self, args[4], false)) |c| {
                if (c != .str and c.asReal() != @round(c.asReal()))
                    try self.err(self.file.exprs.mainTok(args[4]), .E0517, "`absdelta()` enable shall evaluate to an integer, got {d}", .{c.asReal()});
            }
        }
        return true;
    }
    const is_cross = std.mem.eql(u8, name, "cross");
    if (std.mem.eql(u8, name, "timer")) {
        if (args.len < 3 or args[2] == .none) return true;
        const c = lower_constfold.constEval(self, args[2]) orelse return true;
        if (c == .str or c.asReal() >= 0) return true;
        try self.err(self.file.exprs.mainTok(args[2]), .E0517, "`timer()` time_tol shall be non-negative, got {d}", .{c.asReal()});
        return true;
    }
    if (!is_cross and !std.mem.eql(u8, name, "above")) return true;
    // §5.10.3.2 above() has no direction: its tolerances start one slot earlier.
    const dir: ?usize = if (is_cross) 1 else null;
    const tol_first: usize = if (is_cross) 2 else 1;

    if (dir) |d| if (d < args.len and args[d] != .none) {
        if (lower_constfold.constEval(self, args[d])) |c| {
            const v = c.asReal();
            // "shall evaluate to integers". Only a folded non-integral value is
            // refused: 0.5 selects no direction, while a real 1.0 evaluates to one.
            if (c != .str and v != @round(v))
                try self.err(self.file.exprs.mainTok(args[d]), .E0517, "`cross()` direction shall evaluate to an integer, got {d}", .{v});
        }
    };

    var tol_given = false;
    for (tol_first..@max(tol_first, @min(tol_first + 2, args.len))) |i| {
        if (args[i] == .none) continue;
        tol_given = true;
        const c = lower_constfold.constEval(self, args[i]) orelse continue;
        if (c == .str) continue;
        const v = c.asReal();
        if (v >= 0) continue;
        try self.err(self.file.exprs.mainTok(args[i]), .E0517, "`{s}()` {s} shall be non-negative, got {d}", .{
            name,
            if (i == tol_first) "time_tol" else "expr_tol",
            v,
        });
    }

    // "If either or both tolerances are defined, then the direction shall also
    // be defined." Elision as such is legal — §5.10.3.1's own `sh` example
    // writes `cross(V(smpl) - thresh, dir, , , en === 1'b1)`, so the error is
    // the missing direction, not the comma.
    if (tol_given) if (dir) |d| {
        if (d >= args.len or args[d] == .none) {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0517);
            b.msg("a tolerance is given but the direction slot is empty", .{});
            b.help("write the direction explicitly; `0` is \"either edge\"", .{});
            try b.emit();
        }
    };
    // §5.10.3.1: "If expr_tol is specified, time_tol shall also be
    // specified". Omission of BOTH tolerances remains legal, including the
    // `sh` example above with a fifth-slot enable.
    if (is_cross and args.len > 3 and args[3] != .none and args[2] == .none) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0517);
        b.msg("`cross()` expr_tol is given but the time_tol slot is empty", .{});
        b.help("specify time_tol before expr_tol, or omit both tolerances", .{});
        try b.emit();
    }
    return true;
}

/// The argument slots a §5.10.3 monitored event requires, in order.
fn requiredSlots(name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, name, "cross") or std.mem.eql(u8, name, "above")) return &.{"expr"};
    if (std.mem.eql(u8, name, "timer")) return &.{"start_time"};
    if (std.mem.eql(u8, name, "absdelta")) return &.{ "expr", "delta" };
    return &.{};
}

/// The enable slot of cross (§5.10.3.1), above (§5.10.3.2) and timer
/// (§5.10.3.3); absdelta's is checked with its bounds.
fn enableSlot(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "cross")) return 4;
    if (std.mem.eql(u8, name, "above") or std.mem.eql(u8, name, "timer")) return 3;
    return null;
}

// ---- §5.10.3.3 timer capture, while the arguments lower --------------------

/// Returns the value `finishTimers`' replay already chose for `e`, or null
/// outside a replay or for an expression the replay recomputes.
pub fn replayedExpr(self: *const Lower, e: Ast.ExprId) ?TypedValue {
    const replay = self.event_state.timer_replay orelse return null;
    return replay.get(e);
}

/// Records what `e` evaluated to while a timer argument is being captured: its
/// value, the variable it reads directly, and for an effectful call the inputs
/// it read. A no-op outside a capture.
pub fn captureExpr(self: *Lower, e: Ast.ExprId, value: TypedValue) Oom!void {
    if (e == .none) return;
    const capture = self.event_state.timer_capture orelse return;
    try capture.exprs.put(self.arena, e, .{
        .value = value,
        .variable = switch (self.file.exprs.tag(e)) {
            .ident => self.vars.get(self.file.str(self.file.exprs.strOf(e))),
            .hier_ident => self.vars.get(try lower_expr.flatName(self, e)),
            else => null, // else: only a resolved name directly reads one variable
        },
        .effects = try captureTimerEffects(self, e),
    });
}

/// Suspends timer capture for an inlined function body: the timer depends on
/// the caller's reads, never on the function's private locals. Returns what
/// `resumeCapture` must restore.
pub fn suspendCapture(self: *Lower) ?*TimerCapture {
    defer self.event_state.timer_capture = null;
    return self.event_state.timer_capture;
}

/// Restores the capture `suspendCapture` returned. Asserts that no capture
/// opened meanwhile: an analog function body holds no event control (E0702).
pub fn resumeCapture(self: *Lower, capture: ?*TimerCapture) void {
    std.debug.assert(self.event_state.timer_capture == null);
    self.event_state.timer_capture = capture;
}
/// Record only arrays the timer expression actually reads. A function's local
/// arrays are excluded by suspending capture on entry to its private scope.
pub fn captureTimerArray(self: *Lower, name: []const u8) Oom!void {
    const capture = self.event_state.timer_capture orelse return;
    if (capture.arrays.contains(name)) return;
    const info = self.arrays.get(name) orelse return;
    var a: TimerArray = .{ .name = name, .info = info, .cells = &.{} };
    if (info.mem) |mem| {
        a.memory = try self.builder.readVariable(mem.place, self.cur);
    } else {
        var cells: std.ArrayList(TimerCell) = .empty;
        var buf: [lower_shape.max_stack_dims]i64 = undefined;
        const idx = try lower_shape.subscriptBuf(self, &buf, info.dims.len);
        for (0..lower_shape.shapeCells(info.dims)) |k| {
            lower_shape.shapeSubscripts(info.dims, k, idx);
            const key = try lower_shape.elemName(self, name, idx);
            if (self.vars.get(key)) |slot| try cells.append(self.arena, .{
                .name = key,
                .read = .{ .slot = slot, .value = try self.builder.readVariable(slot.place, self.cur) },
            });
        }
        a.cells = try cells.toOwnedSlice(self.arena);
    }
    try capture.arrays.put(self.arena, name, a);
}

/// A call may be recomputed only when every operation in its body is free of
/// observable effects. Formal direction alone is insufficient: an input-only
/// function can still draw random numbers, perform file I/O or call a writer.
fn timerFunctionPure(self: *Lower, name: Ast.StrId) Oom!bool {
    if (self.event_state.timer_functions.get(name)) |pure| return pure;
    try self.event_state.timer_functions.put(self.arena, name, false); // recursion is already E0510
    const module = self.module orelse return false;
    for (module.functions) |*fd| if (fd.name == name) {
        if (!fd.is_analog) return false;
        for (fd.args) |arg| if (arg.direction != .input) return false;
        for (fd.vars) |decl| if (!try timerExprPure(self, decl.init)) return false;
        const pure = try timerStmtPure(self, fd.body);
        try self.event_state.timer_functions.put(self.arena, name, pure);
        return pure;
    };
    return false;
}

fn timerStmtPure(self: *Lower, id: Ast.StmtId) Oom!bool {
    if (id == .none) return true;
    switch (self.file.stmt(id)) {
        .sys_task, .event_control, .event_trigger, .contribute, .indirect, .disable => return false,
        .block => |block| for (block.vars) |decl| {
            if (!try timerExprPure(self, decl.init)) return false;
        },
        else => {}, // else: local assignments, control flow and return have only their child effects
    }
    var walk = struct {
        lower: *Lower,
        pure: bool = true,
        pub fn expr(w: *@This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
            w.pure = (try timerExprPure(w.lower, e)) and w.pure;
        }
        pub fn stmt(w: *@This(), s: Ast.StmtId) Oom!void {
            w.pure = (try timerStmtPure(w.lower, s)) and w.pure;
        }
    }{ .lower = self };
    try self.file.stmtEdges(id, &walk);
    return walk.pure;
}

fn timerExprPure(self: *Lower, e: Ast.ExprId) Oom!bool {
    if (e == .none) return true;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .call => if (!try timerFunctionPure(self, ex.strOf(e))) return false,
        .sys_call => if (!timerSystemPure(Mir.Callee.fromName(self.file.str(ex.strOf(e))))) return false,
        .filter_call,
        .noise_call,
        .event_function,
        .event_initial_step,
        .event_final_step,
        .event_posedge,
        .event_negedge,
        .event_driver_update,
        .event_or,
        => return false,
        else => {}, // else: ordinary values and arithmetic have only their child effects
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |child| if (!try timerExprPure(self, child)) return false;
    return true;
}

fn timerSystemPure(c: Mir.Callee) bool {
    return switch (c) {
        .@"$rtoi",
        .@"$itor",
        .@"$realtobits",
        .@"$bitstoreal",
        .@"$clog2",
        .@"$sqrt",
        .@"$exp",
        .@"$expm1",
        .@"$ln",
        .@"$ln1p",
        .@"$log",
        .@"$log10",
        .@"$floor",
        .@"$ceil",
        .@"$sin",
        .@"$cos",
        .@"$tan",
        .@"$asin",
        .@"$acos",
        .@"$atan",
        .@"$sinh",
        .@"$cosh",
        .@"$tanh",
        .@"$asinh",
        .@"$acosh",
        .@"$atanh",
        .@"$pow",
        .@"$hypot",
        .@"$atan2",
        .@"$temperature",
        .@"$vt",
        .@"$mfactor",
        .@"$abstime",
        .@"$realtime",
        .@"$simparam",
        .@"$simparam$str",
        .@"$param_given",
        .@"$port_connected",
        => true,
        else => false, // else: unproved system calls may write arguments or simulator state
    };
}

/// Prove a literal return from source, not from the at-call MIR value: an
/// input currently equal to 1 can change later, whereas `return 1` cannot.
/// A final unconditional assignment/return establishes the value unless an
/// earlier return can bypass it. Side effects still occur only at the call.
fn timerFunctionConstant(self: *Lower, name: Ast.StrId) Oom!bool {
    const module = self.module orelse return false;
    for (module.functions) |*fd| if (fd.name == name) {
        var last = fd.body;
        while (last != .none and self.file.stmt(last) == .block) {
            const body = self.file.stmt(last).block.body;
            if (body.len == 0) return false; // an earlier statement may already have assigned the result
            last = body[body.len - 1];
        }
        if (last == .none) return false;
        const value = switch (self.file.stmt(last)) {
            .assign => |a| if (self.file.exprs.tag(a.target) == .ident and
                self.file.exprs.strOf(a.target) == name) a.value else return false,
            .jump => |j| if (j.kind == .ret) j.value else return false,
            else => return false, // else: no unconditional final result is established
        };
        if (constfold.fold(self.file, value, constfold.literal_env) == null) return false;
        return !try timerEarlyReturn(self, fd.body, last);
    };
    return false;
}

fn timerEarlyReturn(self: *Lower, id: Ast.StmtId, last: Ast.StmtId) Oom!bool {
    if (id == .none or id == last) return false;
    if (self.file.stmt(id) == .jump and self.file.stmt(id).jump.kind == .ret) return true;
    var walk = struct {
        lower: *Lower,
        last: Ast.StmtId,
        found: bool = false,
        /// An expression holds no `return`.
        pub fn expr(_: *@This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {}
        pub fn stmt(w: *@This(), s: Ast.StmtId) Oom!void {
            w.found = (try timerEarlyReturn(w.lower, s, w.last)) or w.found;
        }
    }{ .lower = self, .last = last };
    try self.file.stmtEdges(id, &walk);
    return walk.found;
}

/// Snapshot inputs of an opaque call after it has run. Output-only formals
/// are not inputs; an inout's post-call value prevents its own copy-out from
/// looking like a later edit. The snapshot is narrow to this call's actuals.
/// Null outside a capture or for a call the replay may recompute; the slice
/// is `self.arena`'s.
fn captureTimerEffects(self: *Lower, e: Ast.ExprId) Oom!?[]const TimerRead {
    if (self.event_state.timer_capture == null) return null;
    const ex = &self.file.exprs;
    if (ex.tag(e) != .call and ex.tag(e) != .sys_call) return null;
    if (ex.tag(e) == .call and try timerFunctionPure(self, ex.strOf(e))) return null;
    if (ex.tag(e) == .sys_call and timerSystemPure(Mir.Callee.fromName(self.file.str(ex.strOf(e))))) return null;
    var reads: std.ArrayList(TimerRead) = .empty;
    var formals: []const Ast.FuncArg = &.{};
    if (ex.tag(e) == .call) if (self.module) |module| for (module.functions) |*fd| {
        if (fd.name == ex.strOf(e)) {
            formals = fd.args;
            break;
        }
    };
    for (ex.args(e), 0..) |arg, k| {
        if (k < formals.len and formals[k].direction == .output) continue;
        try timerInputReads(self, arg, &reads);
    }
    return try reads.toOwnedSlice(self.arena);
}

fn timerInputReads(self: *Lower, e: Ast.ExprId, reads: *std.ArrayList(TimerRead)) Oom!void {
    if (e == .none) return;
    const ex = &self.file.exprs;
    // A fixed scalarized element does not depend on its siblings. Whole
    // arrays and runtime indices below depend on their storage version.
    if (ex.tag(e) == .index) {
        var subs: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
        if (try lower_stmt.indexChain(self, e, &subs)) |chain| {
            const name = self.file.str(chain.name);
            if (self.arrays.get(name)) |info| if (info.mem == null and chain.subs.len == info.dims.len) {
                var buf: [lower_shape.max_stack_dims]i64 = undefined;
                const idx = try lower_shape.subscriptBuf(self, &buf, chain.subs.len);
                const fixed = for (chain.subs, idx) |sub, *value| {
                    const c = lower_constfold.foldExpr(self, sub, false) orelse break false;
                    value.* = c.asIntExact() orelse break false;
                } else true;
                if (fixed) {
                    const key = try lower_shape.elemName(self, name, idx);
                    if (self.vars.get(key)) |slot| try reads.append(self.arena, .{
                        .slot = slot,
                        .value = try self.builder.readVariable(slot.place, self.cur),
                    });
                    return;
                }
            };
        }
    }
    const name = switch (ex.tag(e)) {
        .ident => self.file.str(ex.strOf(e)),
        .hier_ident => try lower_expr.flatName(self, e),
        else => null, // else: recurse into the expression's reads below
    };
    if (name) |n| {
        if (self.vars.get(n)) |slot| try reads.append(self.arena, .{
            .slot = slot,
            .value = try self.builder.readVariable(slot.place, self.cur),
        });
        try captureTimerArray(self, n);
        if (self.event_state.timer_capture.?.arrays.get(n)) |a| {
            if (a.info.mem) |mem| try reads.append(self.arena, .{
                .slot = .{ .place = mem.place, .ty = a.info.ty },
                .value = try self.builder.readVariable(mem.place, self.cur),
            });
            for (a.cells) |cell| try reads.append(self.arena, .{
                .slot = cell.read.slot,
                .value = try self.builder.readVariable(cell.read.slot.place, self.cur),
            });
        }
        return;
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |child| try timerInputReads(self, child, reads);
}

// ---- §5.10.3.3 timer replay, after every analog block ----------------------

/// §5.10.3.3 schedule using controls after event bodies have run. The event
/// condition itself keeps its original operands, so an already delivered
/// event is neither canceled nor executed a second time. Asserts that no
/// capture or replay is open: it runs once, after every analog block.
pub fn finishTimers(self: *Lower) Oom!void {
    std.debug.assert(self.event_state.timer_capture == null);
    std.debug.assert(self.event_state.timer_replay == null);
    for (self.event_state.timers.items) |tm| {
        const saved_unit = self.cur_unit;
        const saved_scope = self.scope_path;
        const saved_block = self.block_path;
        self.cur_unit = tm.unit;
        self.scope_path = tm.scope_path;
        self.block_path = tm.block_path;
        defer {
            self.cur_unit = saved_unit;
            self.scope_path = saved_scope;
            self.block_path = saved_block;
        }
        var replay: std.AutoHashMapUnmanaged(Ast.ExprId, TypedValue) = .empty;
        var changed = false;
        // Array reads bypass lowerExpr for whole-array function actuals. Keep
        // their original bindings, including named-block locals whose scope
        // has ended, then read the final SSA storage version.
        const saved_vars = self.vars;
        const saved_arrays = self.arrays;
        self.vars = try self.vars.clone(self.arena);
        self.arrays = try self.arrays.clone(self.arena);
        defer {
            self.vars.deinit(self.arena);
            self.arrays.deinit(self.arena);
            self.vars = saved_vars;
            self.arrays = saved_arrays;
        }
        var arrays = tm.captured.arrays.valueIterator();
        while (arrays.next()) |a| {
            try self.arrays.put(self.arena, a.name, a.info);
            if (a.info.mem) |mem| {
                const after = try self.builder.readVariable(mem.place, self.cur);
                changed = changed or self.mir.resolveAlias(after) != self.mir.resolveAlias(a.memory.?);
            }
            for (a.cells) |cell| {
                try self.vars.put(self.arena, cell.name, cell.read.slot);
                changed = changed or try timerReadChanged(self, cell.read);
            }
        }
        for (tm.args[0..@min(tm.args.len, 2)]) |arg| if (arg != .none)
            try replayTimerExpr(self, arg, &tm.captured, &replay, &changed);
        if (!changed) continue;
        self.event_state.timer_replay = &replay;
        defer self.event_state.timer_replay = null;
        var latest = tm.values;
        for (tm.args[0..@min(tm.args.len, 2)], 0..) |arg, k| {
            if (arg != .none) latest[k] = try self.toReal(try lower_expr.lowerExpr(self, arg));
        }
        if (self.mir.resolveAlias(latest[0]) != self.mir.resolveAlias(tm.values[0]) or
            self.mir.resolveAlias(latest[1]) != self.mir.resolveAlias(tm.values[1]))
            try self.out.timer_controls.put(self.arena, tm.inst, latest);
    }
}

fn replayTimerExpr(self: *Lower, e: Ast.ExprId, captured: *const TimerCapture, replay: *std.AutoHashMapUnmanaged(Ast.ExprId, TypedValue), changed: *bool) Oom!void {
    const before = captured.exprs.get(e) orelse return;
    if (before.variable) |slot| {
        const stored = try self.builder.readVariable(slot.place, self.cur);
        // §7.3.1 applies to this later read too: a packed reg's analog value
        // is zero-extended from its declaration width, not its raw SSA slot.
        const after = try lower_var.analogRead(self, stored, slot.reg_width);
        changed.* = changed.* or self.mir.resolveAlias(after) != self.mir.resolveAlias(before.value.v);
        return replay.put(self.arena, e, .{ .v = after, .ty = slot.ty });
    }
    if (before.effects) |reads| {
        // A constant return needs no recomputation, even if an argument used
        // only by its effects changes later. Keep the original effects.
        const constant = self.file.exprs.tag(e) == .call and
            try timerFunctionConstant(self, self.file.exprs.strOf(e));
        for (reads) |read| if (!constant and try timerReadChanged(self, read)) {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0528);
            b.note("the call's input changes after it was evaluated; replay would repeat its effects", .{});
            try b.emit();
            break;
        };
        return replay.put(self.arena, e, before.value);
    }
    switch (self.file.exprs.tag(e)) {
        .unary, .binary, .ternary, .builtin_call, .concat, .multi_concat, .index, .call, .sys_call => {
            var buf: [3]Ast.ExprId = undefined;
            for (self.file.exprs.children(e, &buf)) |child|
                try replayTimerExpr(self, child, captured, replay, changed);
        },
        else => try replay.put(self.arena, e, before.value), // else: all other leaves keep their one evaluated value
    }
}

fn timerReadChanged(self: *Lower, read: TimerRead) Oom!bool {
    const after = try self.builder.readVariable(read.slot.place, self.cur);
    return self.mir.resolveAlias(after) != self.mir.resolveAlias(read.value);
}

test requiredSlots {
    // §5.10.3: the monitored quantity, and absdelta's delta besides.
    try std.testing.expectEqual(@as(usize, 1), requiredSlots("cross").len);
    try std.testing.expectEqualStrings("expr", requiredSlots("above")[0]);
    try std.testing.expectEqualStrings("start_time", requiredSlots("timer")[0]);
    try std.testing.expectEqual(@as(usize, 2), requiredSlots("absdelta").len);
    try std.testing.expectEqualStrings("delta", requiredSlots("absdelta")[1]);
    try std.testing.expectEqual(@as(usize, 0), requiredSlots("initial_step").len);
}

test enableSlot {
    // cross(expr, dir, time_tol, expr_tol, enable); above and timer one earlier.
    try std.testing.expectEqual(@as(?usize, 4), enableSlot("cross"));
    try std.testing.expectEqual(@as(?usize, 3), enableSlot("above"));
    try std.testing.expectEqual(@as(?usize, 3), enableSlot("timer"));
    try std.testing.expectEqual(@as(?usize, null), enableSlot("absdelta"));
}

test timerSystemPure {
    try std.testing.expect(timerSystemPure(.fromName("$sqrt")));
    try std.testing.expect(timerSystemPure(.fromName("$abstime")));
    // A descriptor call opens a file: replaying it would open a second one.
    try std.testing.expect(!timerSystemPure(.fromName("$fopen")));
    try std.testing.expect(!timerSystemPure(.fromName("$strobe")));
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

test "§5.10.3 monitored events: argument rules, each beside a legal call" {
    try Lower.expectBodies(&.{
        .{ .src = "analog begin @(cross(V(p) - 0.5, 1, 1n, 1u)) x = 1.0; I(p) <+ x; end", .code = null },
        // §5.10.3.1 the direction "shall evaluate to integers".
        .{ .src = "analog begin @(cross(V(p) - 0.5, 0.5)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // "If either or both tolerances are defined, then the direction shall
        // also be defined."
        .{ .src = "analog begin @(cross(V(p) - 0.5, , 1n)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // "If expr_tol is specified, time_tol shall also be specified."
        .{ .src = "analog begin @(cross(V(p) - 0.5, 1, , 1u)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // A.6.5: the enable is analog_expression, not `_or_null`.
        .{ .src = "analog begin @(cross(V(p) - 0.5, 1, 1n, 1u, )) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // §5.10.3.3 time_tol is non-negative.
        .{ .src = "analog begin @(timer(0, 1n, -1p)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        .{ .src = "analog begin @(timer(0, 1n)) x = 1.0; I(p) <+ x; end", .code = null },
        // §5.10.3.2 the enable "shall evaluate to an integer".
        .{ .src = "analog begin @(above(V(p) - 0.5, 1n, 1u, 0.5)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        .{ .src = "analog begin @(above(V(p) - 0.5)) x = 1.0; I(p) <+ x; end", .code = null },
        // §5.10.3.4 absdelta is "only allowed in an initial or always block".
        .{ .src = "analog begin @(absdelta(V(p), 0.1)) x = 1.0; I(p) <+ x; end", .code = .E0513 },
        // §5.10 "Nested event control statements are not allowed."
        .{ .src = "analog begin @(initial_step) @(final_step) x = 1.0; I(p) <+ x; end", .code = .E0703 },
    });
}
