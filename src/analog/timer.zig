//! §5.10.3.3 timer rescheduling: while a `timer`'s first two arguments lower,
//! what they read is captured; after every analog block `finishTimers`
//! replays them against the block's final values, and an argument that moved
//! becomes a `Lowered.timer_controls` row the host schedules the next firing
//! from. Effectful calls are never recomputed (E0528).
//!
//! Cites: §5.10.3.3, §7.3.1.
//!
//! Contents:
//! - `pub const State = struct`
//! - `pub const TimerCapture = struct` (`empty`)
//! - `pub fn replayedExpr(self: *const Lower, e: Ast.ExprId) ?TypedValue`
//! - `pub fn captureExpr(self: *Lower, e: Ast.ExprId, value: TypedValue) Oom!void`
//! - `pub fn suspendCapture(self: *Lower) ?*TimerCapture`
//! - `pub fn resumeCapture(self: *Lower, capture: ?*TimerCapture) void`
//! - `pub fn captureTimerArray(self: *Lower, name: []const u8) Oom!void`
//! - `pub fn finishTimers(self: *Lower) Oom!void`
//! - private `timerStmtPure` (`expr`, `stmt`)
//! - private `timerEarlyReturn` (`expr`, `stmt`)

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_shape = @import("shape.zig");
const lower_var = @import("var.zig");
const lower_expr_name = @import("expr_name.zig");
const lower_lvalue = @import("lvalue.zig");
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const VarSlot = Lower.VarSlot;

/// This file's private state on `Lower` (`Lower.timer_state`).
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

/// Everything one `timer` call's arguments read, keyed by expression and by
/// array name.
pub const TimerCapture = struct {
    exprs: std.AutoHashMapUnmanaged(Ast.ExprId, CapturedExpr) = .empty,
    arrays: std.StringHashMapUnmanaged(TimerArray) = .empty,
    pub const empty: TimerCapture = .{};
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

/// Returns the value `finishTimers`' replay already chose for `e`, or null
/// outside a replay or for an expression the replay recomputes.
pub fn replayedExpr(self: *const Lower, e: Ast.ExprId) ?TypedValue {
    assert(e == .none or self.exprValid(e));
    assert(e == .none or self.exprValid(e));
    const replay = self.timer_state.timer_replay orelse return null;
    return replay.get(e);
}

/// Records what `e` evaluated to while a timer argument is being captured: its
/// value, the variable it reads directly, and for an effectful call the inputs
/// it read. A no-op outside a capture.
pub fn captureExpr(self: *Lower, e: Ast.ExprId, value: TypedValue) Oom!void {
    assert(e == .none or self.exprValid(e));
    assert(self.valueValid(value.v));
    if (e == .none) return;
    const capture = self.timer_state.timer_capture orelse return;
    try capture.exprs.put(self.arena, e, .{
        .value = value,
        .variable = switch (self.file.exprs.tag(e)) {
            .ident => self.vars.get(self.file.str(self.file.exprs.strOf(e))),
            .hier_ident => self.vars.get(try lower_expr_name.flatName(self, e)),
            else => null, // else: only a resolved name directly reads one variable
        },
        .effects = try captureTimerEffects(self, e),
    });
}

/// Suspends timer capture for an inlined function body: the timer depends on
/// the caller's reads, never on the function's private locals. Returns what
/// `resumeCapture` must restore.
pub fn suspendCapture(self: *Lower) ?*TimerCapture {
    assert(self.blockValid(self.cur));
    defer self.timer_state.timer_capture = null;
    return self.timer_state.timer_capture;
}

/// Restores the capture `suspendCapture` returned. Asserts that no capture
/// opened meanwhile: an analog function body holds no event control (E0702).
pub fn resumeCapture(self: *Lower, capture: ?*TimerCapture) void {
    assert(self.blockValid(self.cur));
    assert(self.timer_state.timer_capture == null);
    self.timer_state.timer_capture = capture;
}

/// Record only arrays the timer expression actually reads. A function's local
/// arrays are excluded by suspending capture on entry to its private scope.
pub fn captureTimerArray(self: *Lower, name: []const u8) Oom!void {
    assert(self.blockValid(self.cur));
    assert(name.len != 0);
    const capture = self.timer_state.timer_capture orelse return;
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

/// §5.10.3.3 schedule using controls after event bodies have run. The event
/// condition itself keeps its original operands, so an already delivered
/// event is neither canceled nor executed a second time. Asserts that no
/// capture or replay is open: it runs once, after every analog block.
pub fn finishTimers(self: *Lower) Oom!void {
    assert(self.timer_state.timer_capture == null);
    assert(self.timer_state.timer_replay == null);
    for (self.timer_state.timers.items) |tm| {
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
        self.timer_state.timer_replay = &replay;
        defer self.timer_state.timer_replay = null;
        var latest = tm.values;
        for (tm.args[0..@min(tm.args.len, 2)], 0..) |arg, k| {
            if (arg != .none) latest[k] = try self.toReal(try lower_expr.lowerExpr(self, arg));
        }
        if (self.mir.resolveAlias(latest[0]) != self.mir.resolveAlias(tm.values[0]) or
            self.mir.resolveAlias(latest[1]) != self.mir.resolveAlias(tm.values[1]))
            try self.out.timer_controls.put(self.arena, tm.inst, latest);
    }
}

// ---- private ----

/// A call may be recomputed only when every operation in its body is free of
/// observable effects. Formal direction alone is insufficient: an input-only
/// function can still draw random numbers, perform file I/O or call a writer.
fn timerFunctionPure(self: *Lower, name: Ast.StrId) Oom!bool {
    assert(name != .none);
    assert(self.module != null);
    if (self.timer_state.timer_functions.get(name)) |pure| return pure;
    try self.timer_state.timer_functions.put(self.arena, name, false); // recursion is already E0510
    const module = self.module orelse return false;
    for (module.functions) |*fd| if (fd.name == name) {
        if (!fd.is_analog) return false;
        for (fd.args) |arg| if (arg.direction != .input) return false;
        for (fd.vars) |decl| if (!try timerExprPure(self, decl.init)) return false;
        const pure = try timerStmtPure(self, fd.body);
        try self.timer_state.timer_functions.put(self.arena, name, pure);
        return pure;
    };
    return false;
}

fn timerStmtPure(self: *Lower, id: Ast.StmtId) Oom!bool {
    assert(id == .none or @backingInt(id) < self.stmtCount());
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
    assert(e == .none or self.exprValid(e));
    assert(self.module != null);
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
    const pure = switch (c) {
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
    // A pure call has no descriptor argument: a file call moves its file.
    if (pure) assert(Mir.callee.fdArg(c) == null);
    if (pure) assert(c != .systf);
    return pure;
}

/// Prove a literal return from source, not from the at-call MIR value: an
/// input currently equal to 1 can change later, whereas `return 1` cannot.
/// A final unconditional assignment/return establishes the value unless an
/// earlier return can bypass it. Side effects still occur only at the call.
fn timerFunctionConstant(self: *Lower, name: Ast.StrId) Oom!bool {
    assert(name != .none);
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
    assert(last != .none);
    assert(id == .none or @backingInt(id) < self.stmtCount());
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
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    if (self.timer_state.timer_capture == null) return null;
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
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    if (e == .none) return;
    const ex = &self.file.exprs;
    // A fixed scalarized element does not depend on its siblings. Whole
    // arrays and runtime indices below depend on their storage version.
    if (ex.tag(e) == .index) {
        var subs: [lower_shape.max_stack_dims]Ast.ExprId = undefined;
        if (try lower_lvalue.indexChain(self, e, &subs)) |chain| {
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
        .hier_ident => try lower_expr_name.flatName(self, e),
        else => null, // else: recurse into the expression's reads below
    };
    if (name) |n| {
        if (self.vars.get(n)) |slot| try reads.append(self.arena, .{
            .slot = slot,
            .value = try self.builder.readVariable(slot.place, self.cur),
        });
        try captureTimerArray(self, n);
        if (self.timer_state.timer_capture.?.arrays.get(n)) |a| {
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

fn replayTimerExpr(self: *Lower, e: Ast.ExprId, captured: *const TimerCapture, replay: *std.AutoHashMapUnmanaged(Ast.ExprId, TypedValue), changed: *bool) Oom!void {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
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
    assert(self.blockValid(self.cur));
    assert(self.valueValid(read.value));
    const after = try self.builder.readVariable(read.slot.place, self.cur);
    return self.mir.resolveAlias(after) != self.mir.resolveAlias(read.value);
}

test timerSystemPure {
    try std.testing.expect(timerSystemPure(.fromName("$sqrt")));
    try std.testing.expect(timerSystemPure(.fromName("$abstime")));
    // A descriptor call opens a file: replaying it would open a second one.
    try std.testing.expect(!timerSystemPure(.fromName("$fopen")));
    try std.testing.expect(!timerSystemPure(.fromName("$strobe")));
}
