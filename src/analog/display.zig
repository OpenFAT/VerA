const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_format = @import("format.zig");
const lower_sysfunc_args = @import("sysfunc_args.zig");
const Oom = Lower.Oom;
const Ty = Lower.Ty;
const TypedValue = Lower.TypedValue;
const Const = Lower.Const;
const Lowered = Lower.Lowered;

/// One §9.4/§9.7 task whose `call` is minted at the END of the analog block —
/// every unconditional display-family statement takes this route (see
/// `queueDisplay`). Holds what the statement position knew and the end of the
/// block will not: the at-statement operand values and the genvar bindings.
pub const DeferredDisplay = struct {
    name: []const u8,
    tok: u32,
    /// The original argument list, `.none` slots included (A.6.9).
    args: []const Ast.ExprId,
    /// Parallel to `args`. Non-null = the operand's value, captured AT THE
    /// STATEMENT (§5.6.1.2 sequential semantics for everything that is not
    /// converged simulation data — a variable printed then reassigned shows
    /// its at-statement value). Null = the operand reads a branch flow and is
    /// lowered at the end of the block instead, against the converged
    /// retention state (§9.4.1/§5.4.2.2).
    pre: []const ?TypedValue,
    /// §5.9.3 genvar bindings live at the statement, re-established around the
    /// end-of-block lowering so `I(pair[k])` in an unrolled body still folds.
    genvars: []const GenvarBind,
    /// `Ast.AnalogBlock.unit` of the block this statement was written in.
    /// Re-established around the end-of-block lowering for the same reason
    /// `genvars` is: `flowAccum` keys on it (§5.6.8.1's per-instance branch),
    /// and by `finishDisplays` time `cur_unit` is whatever block lowered last.
    unit: u32,
    /// Index of the placeholder row in `displays` whose `.val` this fills.
    display: u32,
    /// §9.4.1 a `$monitor`/`$fmonitor` report: the site key, prepended to the
    /// call's operands. Every operand of one is lowered at the end of the block.
    monitor: ?Mir.Value = null,
    // §5.3.2 the names a deferred operand was written under, when the
    // statement sits in a named block: its scope closes before
    // `finishDisplays`, and its locals would no longer resolve there. Null at
    // module scope, whose names are still bound at the end of the block.
    scope: ?Scope = null,
};

const GenvarBind = struct { name: []const u8, c: Const };

// The name bindings lowering resolves an operand against, captured at a
// statement and reinstalled around its end-of-block lowering (`swapScope`).
const Scope = struct {
    vars: std.StringHashMapUnmanaged(Lower.VarSlot),
    arrays: std.StringHashMapUnmanaged(Lower.ArrayInfo),
    consts: std.StringHashMapUnmanaged(Const),
    scope_path: []const u8,
    block_path: []const u8,
};

// Installs `s` as the scope lowering resolves names in, and returns the one it
// replaced, so a second call with that result restores it.
fn swapScope(self: *Lower, s: Scope) Scope {
    const old: Scope = .{
        .vars = self.vars,
        .arrays = self.arrays,
        .consts = self.consts,
        .scope_path = self.scope_path,
        .block_path = self.block_path,
    };
    self.vars = s.vars;
    self.arrays = s.arrays;
    self.consts = s.consts;
    self.scope_path = s.scope_path;
    self.block_path = s.block_path;
    return old;
}

/// Sequences one unconditional display-family statement: captures its operands
/// and mints its `call` at the end of the analog block (LRM §9.4.1).
///
/// Why the end: $strobe displays data once "the simulator has converged", and
/// §5.4.2.2 makes a source branch's flow accessible "anywhere in the module".
/// A flow source's value is the §5.6.1.2 retained accumulator, settled only at
/// the end of the cycle (§5.6.1.3), so an operand that reads one is lowered in
/// `finishDisplays`, where the `flowAccum` read is the final retained value.
///
/// Only those operands move. Any other operand keeps its at-statement value, so
/// `x = 1; $strobe("%g", x); x = 2;` prints 1. The split is per operand because
/// SSA dominance puts a whole tree after the accumulator value it contains.
///
/// $display and $strobe collapse onto the same phase, since the printing
/// artifact runs the display chain once per accepted point; §9.7's tasks travel
/// the same chain. The §9.5.2 file writers do not take this route: §9.5.9
/// sequences them against `$fgets`/`$ftell` at statement order. The call is
/// minted at the end even when no operand defers, so prints keep source order.
///
/// A non-null `monitor` is a `$monitor`/`$fmonitor` report (`armMonitor`): every
/// operand defers, because the report runs at the end of each accepted step
/// whether or not the statement ran, and it may come from a guarded statement.
pub fn queueDisplay(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId, monitor: ?Mir.Value) Oom!void {
    const pre = try self.arena.alloc(?TypedValue, args.len);
    var any_deferred = false;
    for (args, pre) |a, *p| {
        p.* = null;
        if (a == .none) continue; // A.6.9 empty argument slot
        if (monitor != null or containsFlowRead(self, a)) {
            any_deferred = true;
            continue;
        }
        p.* = try lower_sysfunc_args.lowerTaskArg(self, a, name);
    }
    // §5.9.3 an unrolled body's genvar bindings are gone from `consts` by
    // `finishDisplays`, so a deferred operand snapshots them.
    var genvars: []const GenvarBind = &.{};
    if (any_deferred and self.active_genvars.items.len != 0) {
        const gs = try self.arena.alloc(GenvarBind, self.active_genvars.items.len);
        for (self.active_genvars.items, gs) |gname, *g|
            g.* = .{ .name = gname, .c = self.consts.get(gname).? };
        genvars = gs;
    }
    // §5.3.2 a named block's locals are unbound when it closes, which is
    // before `finishDisplays`; a deferred operand keeps the names it was
    // written under. Copies, so the block's later declarations stay its own.
    const scope: ?Scope = if (any_deferred and self.block_path.len != 0) .{
        .vars = try self.vars.clone(self.arena),
        .arrays = try self.arrays.clone(self.arena),
        .consts = try self.consts.clone(self.arena),
        .scope_path = self.scope_path,
        .block_path = self.block_path,
    } else null;
    try self.systask_state.deferred_displays.append(self.arena, .{
        .name = name,
        .tok = tok,
        .args = args,
        .pre = pre,
        .genvars = genvars,
        .unit = self.cur_unit,
        .display = @intCast(self.out.displays.items.len),
        .monitor = monitor,
        .scope = scope,
    });
    // The placeholder keeps `displays` in source order — W0850 reporting and
    // the chain both walk it — and `lowerDeferredDisplays` fills `.val`.
    try self.out.displays.append(self.arena, .{
        .val = .undef,
        .name = name,
        .tok = tok,
        .conditional = false,
    });
}

/// §9.4.1: "When a $monitor task is invoked with one or more arguments, the
/// simulator sets up a mechanism whereby for each accepted step, if the variable
/// or an expression in the argument list changes value compared with the last
/// accepted step ... the entire argument list is displayed at the end of the
/// time step as if reported by the $strobe task."
///
/// So one statement is two events. The invocation happens at the statement,
/// under its guards: this call, `$monitor$arm(k)`, latches site `k` on. The
/// report is `queueDisplay`'s end-of-block call with `k` prepended and runs at
/// the end of every accepted step from then on; codegen joins the two on `k`
/// (`str_kernels.zMonitor`). A monitor armed once under `@(initial_step)` keeps
/// reporting.
///
/// The arm rides `display_cond_place`, not `displays`: the report already has
/// the statement's `displays` row, and W0850 is one warning per statement.
pub fn armMonitor(self: *Lower, name: []const u8) Oom!Mir.Value {
    if (std.mem.eql(u8, name, "$fmonitor")) {
        self.out.uses.insert(.file_tasks);
        self.out.uses.insert(.str_tasks);
    }
    const k = try self.mir.addIntConst(self.arena, self.systask_state.monitor_sites);
    self.systask_state.monitor_sites += 1;
    try chainCondDisplay(self, try self.call("$monitor$arm", &.{k}));
    return k;
}

/// Does this operand tree read a branch FLOW (§4.4.1 `I(...)` under any
/// §3.6.1.2 spelling)? That is the one read whose value is position-dependent
/// inside the block (§5.6.1.2 retention); potentials and §5.4.3 port flows
/// resolve to solver unknowns and read the same value everywhere, so they do
/// not force an operand to the end. Every child edge is searched
/// (`ExprStore.children`), assignment-pattern elements included.
fn containsFlowRead(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .branch_access) {
        const name = self.file.str(ex.strOf(e));
        const kind = self.access_kind.get(name) orelse return false;
        // ponytail: a name both halves use counts as a flow read: the
        // retention is conservative, and the node is not resolved here.
        return kind == .flow or self.access_both.contains(name);
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (containsFlowRead(self, c)) return true;
    return false;
}

/// Carries one guarded §9.4/§9.5/§9.7 call into the display slice. The value is
/// discarded at the root; the `fadd` gives the call a use, without which
/// codegen's slice drops the print.
pub fn chainCondDisplay(self: *Lower, v: Mir.Value) Oom!void {
    const p = self.systask_state.display_cond_place orelse blk: {
        const np = self.builder.newPlace();
        try self.builder.writeVariable(np, .entry, .f_zero);
        self.systask_state.display_cond_place = np;
        break :blk np;
    };
    const prev = try self.builder.readVariable(p, self.cur);
    try self.builder.writeVariable(p, self.cur, try self.emit(.fadd, &.{ prev, v }));
}

/// Chains every unconditional §9.4 display call into one value, so codegen has
/// a single live root to slice a unit from. `fadd` is the cheapest carrier: the
/// sum is discarded, and rendering it walks the operands in MIR order, which is
/// source order.
///
/// Only `cond_depth == 0` calls join directly. They lie on the straight-line
/// spine of the analog block, so each one dominates `self.cur` here; a call
/// inside an `if` arm does not, and chaining it would be invalid SSA. Those
/// reach the root through `display_cond_place` instead — one read of a place
/// the arms wrote, an ordinary phi. §9.4.6 is satisfied by where the call
/// sits: it stays in the arm's block and codegen emits the arm as an `if`.
/// Runs once, after `finishKernelCtl`; writes `Lowered.display_root`.
pub fn finishDisplays(self: *Lower) Oom!void {
    // ponytail: print order is MIR order, so a module that prints both kinds shows
    // the guarded lines first, whatever the source order. Upgrade path: give
    // `Display` a source-order index and have codegen emit by it.
    try lowerDeferredDisplays(self);
    var root: Mir.Value = .f_zero;
    var first = true;
    for (self.out.displays.items) |d| {
        if (d.conditional) continue;
        // Every unconditional entry either carried its call from the
        // statement or was a `queueDisplay` placeholder just filled above.
        assert(d.val != .undef);
        root = if (first) d.val else try self.emit(.fadd, &.{ root, d.val });
        first = false;
    }
    if (self.systask_state.display_cond_place) |p| {
        const v = try self.builder.readVariable(p, self.cur);
        root = if (first) v else try self.emit(.fadd, &.{ root, v });
    }
    self.out.display_root = root;
}

/// The end-of-block half of `queueDisplay`: lower what was deferred, mint each
/// call, fill its `displays` placeholder. Runs at the top of `finishDisplays`,
/// with `self.cur` past the last statement and past `lowerModule`'s final
/// accumulator reads — so a `flowAccum` read here is the §5.6.1.3 end-of-cycle
/// retention state, phis and all.
fn lowerDeferredDisplays(self: *Lower) Oom!void {
    for (self.systask_state.deferred_displays.items) |dd| {
        // Provenance: instructions minted here belong to the display
        // statement, not to whatever token the block ended on.
        self.mir.cur_tok = dd.tok;
        self.cur_unit = dd.unit;
        const outer: ?Scope = if (dd.scope) |s| swapScope(self, s) else null;
        for (dd.genvars) |g| try self.consts.put(self.arena, g.name, g.c);
        var vals: std.ArrayList(Mir.Value) = .empty;
        defer vals.deinit(self.arena);
        var live: std.ArrayList(Ast.ExprId) = .empty;
        defer live.deinit(self.arena);
        var tys: std.ArrayList(Ty) = .empty;
        defer tys.deinit(self.arena);
        for (dd.args, dd.pre) |a, p| {
            if (a == .none and !Mir.callee.takesFormat(.fromName(dd.name))) continue;
            const tv = if (a == .none) try nullArg(self) else p orelse try lower_sysfunc_args.lowerTaskArg(self, a, dd.name);
            try vals.append(self.arena, tv.v);
            try live.append(self.arena, a);
            try tys.append(self.arena, tv.ty);
        }
        for (dd.genvars) |g| _ = self.consts.remove(g.name);
        // §9.4.3 conversion-vs-type pairing, postponed with the operands.
        try lower_format.prepareFormatArgs(self, dd.tok, live.items, tys.items, vals.items, lower_format.messageStart(.fromName(dd.name), tys.items));
        if (outer) |s| _ = swapScope(self, s);
        if (dd.monitor) |k| try vals.insert(self.arena, 0, k);
        self.out.displays.items[dd.display].val = try self.call(dd.name, vals.items);
    }
}

/// §9.4.1: "Any null argument produces a single space character in the
/// display." A formatting task's null slot is the one-space string, which
/// `cg_display.buildArgs` writes as a format with no conversion, at its place.
pub fn nullArg(self: *Lower) Oom!TypedValue {
    return .{ .v = try self.mir.addStrConst(self.arena, " "), .ty = .string };
}

test "§9.4.1/§5.3.2 a deferred display operand keeps its named block's names" {
    // `$strobe` reads a branch flow, so its operand is lowered at the end of
    // the block, where §5.4.2.2's flow is converged. `x` is the named block's
    // own variable, and the operand was written in its scope.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p, q);
        \\  inout p, q; electrical p, q;
        \\  analog begin : blk
        \\    real x;
        \\    x = 2.0;
        \\    $strobe("%g", x * I(p, q));
        \\    I(p, q) <+ V(p, q);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = h.low.lowerFile() catch |err| switch (err) {
        error.DiagnosticsReported => {},
        else => |e| return e,
    };
    if (h.bag.err_count != 0) for (0..h.bag.count()) |i| std.debug.print("  {s}: {s}\n", .{ @tagName(h.bag.at(i).code), h.bag.at(i).message });
    try std.testing.expectEqual(@as(u32, 0), h.bag.err_count);
    try std.testing.expectEqual(@as(usize, 1), h.low.out.displays.items.len);
}
