//! §4.5 analog operators and filters, and the §4.6 small-signal sources.
//!
//! In: a ddt/idt/idtmod/absdelay/transition/slew/laplace_*/zi_*/last_crossing/
//! ddx/limexp call, or a §4.6 noise or `ac_stim` call. Out: one MIR `call` per
//! stateful operator site (§4.5.2); for `ddt` and `idt`, an operator unknown
//! with its own row and charge site (`opDdt`, `opIdt`); for a noise call, its
//! PSD operands in `Lower.noise_psd`/`noise_tab`/`noise_val`; and the
//! §4.6.4.6 noise coefficients `noiseCoeff` derives from a contribution.
//!
//! Spine: `lowerFilter` per operator call (`checkOperatorPlace` first, always),
//! `lowerNoise` per small-signal call; `noiseCoeff` runs when `contrib.zig`
//! accumulates a `<+` that carries a generator.
//!
//! LRM clauses this file's code cites: §1.3.1.2, §2, §2.8, §2.9, §3.2.2, §3.4,
//! §3.4.4, §3.6.1.2, §3.6.2.3, §3.13.1, §4.2, §4.2.12, §4.2.13, §4.5, §4.5.1,
//! §4.5.2, §4.5.3, §4.5.4, §4.5.5, §4.5.6, §4.5.7, §4.5.8, §4.5.9, §4.5.10,
//! §4.5.11, §4.5.12, §4.5.13, §4.5.14, §4.5.15, §4.6.3, §4.6.4, §4.6.4.1,
//! §4.6.4.2, §4.6.4.3, §4.6.4.6, §5.5.3, §5.8, §5.8.1, §5.9, §5.9.3, §6.8,
//! §9.21.

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const diag = @import("diag");
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_discipline = @import("discipline.zig");
const lower_expr = @import("expr.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_node = @import("node.zig");
const lower_shape = @import("shape.zig");
const lower_expr_select = @import("expr_select.zig");
const lower_math = @import("math.zig");
const lower_static = @import("static.zig");
const lower_branch = @import("branch.zig");
const lower_reactive = @import("reactive.zig");
const Oom = Lower.Oom;
const ground = Lower.ground;
const TypedValue = Lower.TypedValue;
const Const = Lower.Const;
const poison = Lower.poison;

/// This file's private state on `Lower` (`Lower.analog_op_state`).
pub const State = struct {
    /// `readsUnknown`'s visited set, cleared and reused per walk rather than
    /// allocated per `idt` site.
    unknown_seen: std.AutoHashMapUnmanaged(Mir.Value, void) = .empty,
    /// `readsUnknown`'s pending values. A worklist, not recursion: a value's
    /// dependences are as long as the straight-line code before it, which no
    /// parse nesting measures (`y = y + 1.0;` 5000 times overflowed the stack).
    unknown_work: std.ArrayList(Mir.Value) = .empty,
};

/// Reports whether `name` is one of the two A.8.2 `analog_filter_function_call`
/// names that keep no history (`ddx`, `limexp`). §5.8.1's ban on analog operators
/// under a runtime condition exists to protect history, which neither reads, so
/// E0514 exempts them.
pub fn isHistoryless(name: []const u8) bool {
    return std.mem.eql(u8, name, "ddx") or std.mem.eql(u8, name, "limexp");
}

/// Checks §4.5.15's placement rules for the analog operator `name` at `e`. Every
/// path that lowers one must call this, including `lowerReactive`'s `ddt` spine,
/// which bypasses `lowerFilter`. Returns false when the operator must not be lowered.
pub fn checkOperatorPlace(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!bool {
    assert(e == .none or self.exprValid(e));
    assert(name.len != 0);
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0422, "not allowed in {s}", .{ctx});
        return false;
    }
    // A.8.2 fixes each operator's last slot: an extra argument has no meaning
    // to ignore (`transition(x, td, rise, fall, tol, 1.0)`).
    const argc = self.file.exprs.args(e).len;
    if (maxArgs(name)) |max| if (argc > max) {
        try self.err(self.file.exprs.mainTok(e), .E0506, "`{s}()` takes at most {d} argument(s), got {d} (A.8.2)", .{ name, max, argc });
        return false;
    };
    // VerA's `vera_timepoint` (§2.9): an operator with history advances per
    // accepted step and reads its input every iterate.
    if (self.tp_cur != null and !isHistoryless(name)) {
        try self.err(self.file.exprs.mainTok(e), .E0530, "the analog operator `{s}` (§4.5)", .{name});
        return false;
    }
    // §5.8.1 / §5.9: an analog operator's state advances once per accepted step.
    // Under a branch the solve can flip, a step with its arm off feeds it zero
    // and corrupts its history.
    if (self.cond_depth != self.static_cond_depth and !isHistoryless(name)) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0514);
        b.msg("`{s}`", .{name});
        b.help("hoist `{s}(...)` onto the spine and make only its USE conditional", .{name});
        try b.emit();
    }
    return true;
}

/// Lowers a §4.5 analog operator call. Each occurrence owns simulator state, so it
/// stays a distinct `call` (one Instance state slot per site, §4.5.2). Vector
/// coefficient arguments (§4.5.11, §4.5.12) are flattened as `<count>, e0, e1, ...`.
pub fn lowerFilter(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const args = ex.args(e);
    if (!try checkOperatorPlace(self, e, name)) return poison;

    // §4.5.6 ddx(f, V(node)): the second argument is a probe, not a value;
    // it names the unknown to differentiate with respect to.
    if (std.mem.eql(u8, name, "ddx")) {
        if (args.len != 2) return lower_math.arityError(self, e, name, 2);
        const f = try self.toReal(try lower_expr.lowerExpr(self, args[0]));
        if (ex.tag(args[1]) != .branch_access) {
            try self.err(self.file.exprs.mainTok(e), .E0504, "", .{});
            return poison;
        }
        const t = try lower_branch.branchOf(self, args[1]) orelse return poison;
        // §4.5.6: "The second argument shall be the potential of a scalar net
        // or port or the flow through a branch, because these are the unknown
        // variables in the system of equations for the analog solver."
        //
        // `V(p, n)` is neither: it is the difference of two unknowns, so the
        // partial derivative "holding all other unknowns fixed" is ambiguous.
        // A flow is exempt: a branch current is one unknown.
        if (t.access == .potential and t.lo != ground) {
            try self.err(self.file.exprs.mainTok(args[1]), .E0504, "a potential across two nets is not one unknown", .{});
            return poison;
        }
        try lower_hier_name.refuseRuntime(self, self.file.exprs.mainTok(args[1]), t.hi, t.lo);
        const u: u32 = switch (t.access) {
            .potential => t.hi,
            // Peek, never mint: "If the expression does not depend explicitly on
            // the unknown, then ddx() returns zero (0)." A branch current enters an
            // expression only through an `I()` read, which mints it, and the first
            // argument was lowered above. Minting here would add an unknown no
            // equation pins, a singular system.
            .flow => self.out.flow_unknowns.get(.{ .hi = t.hi, .lo = t.lo }) orelse
                return .{ .v = .f_zero, .ty = .real },
        };
        const d = try self.call("ddx", &.{ f, try self.mir.addIntConst(self.arena, u) });
        // §1.3.1.2 again: `ddx(f, I(n,p))` differentiates with respect to the
        // negation of the one canonical unknown, so the derivative negates too.
        // A potential probe reaches here only in the single-net form, which the
        // check above enforces and which is never reversed.
        return .{ .v = if (t.neg) try self.emit(.fneg, &.{d}) else d, .ty = .real };
    }

    // A.8.2 fixes each operator's mandatory arguments (everything left of the
    // grammar's first `[`). The per-slot loop below judges only written slots, so
    // a short list is measured here. The laplace forms mandate three slots and the
    // zi forms four; a slot may be null (see `nullZerosOk`) but must be present.
    const min_args: usize = if (std.mem.eql(u8, name, "absdelay"))
        2
    else if (std.mem.startsWith(u8, name, "laplace_"))
        3
    else if (std.mem.startsWith(u8, name, "zi_"))
        4
    else
        1; // ddt, idt, idtmod, transition, slew, last_crossing, limexp
    if (args.len < min_args) {
        try self.err(self.file.exprs.mainTok(e), .E0505, "`{s}()` needs {d} argument(s), got {d}", .{ name, min_args, args.len });
        return poison;
    }
    try checkFilterArgBounds(self, name, args); // §4.5.5-§4.5.10

    const abstol_slot = abstolSlot(name);

    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    for (args, 0..) |a, i| {
        // A.8.2 analog_filter_function_call has no `analog_expression_or_null`
        // form: every declared argument must be present (§4.5.14).
        //
        // §4.5.15: "It is illegal to specify a null argument in the argument list
        // of an analog operator, except as specified elsewhere in this document",
        // and §4.5.11/§4.5.12
        // are what the exception points at: "The zeros argument may be represented
        // as a null argument." Empty zeros are an empty product, numerator 1, which
        // only reads that way in the root forms (`*_zp`, `*_zd`).
        if (a == .none) {
            if (i == 1 and nullZerosOk(name)) {
                try vals.append(self.arena, try self.mir.addIntConst(self.arena, 0));
                continue;
            }
            try self.err(self.file.exprs.mainTok(e), .E0505, "`{s}()`", .{name});
            return poison;
        }
        // A.8.3 `abstol_expression ::= constant_expression | nature_identifier`.
        // The second arm is the only place a nature name is a value, so it is
        // resolved here, not in `lookupName`, where it would shadow every
        // variable named after a nature (§3.13.1's global scope).
        if (abstol_slot == i) {
            try vals.append(self.arena, try lowerAbstolArg(self, name, a) orelse return poison);
            continue;
        }
        // A.8.2's `analog_filter_function_arg` is a parameter, a part of
        // one or a `constant_assignment_pattern_or_null`; VAMS 2.x's `{a, b}`
        // is the §4.2.13 concatenation, which annex G retired from this slot
        // ("Add apostrophe before opening { in list of values").
        const coef_slot = (i == 1 or i == 2) and isCoefFilter(name);
        if (coef_slot and
            (self.file.exprs.tag(a) == .concat or self.file.exprs.tag(a) == .multi_concat))
        {
            try self.err(self.file.exprs.mainTok(a), .E0572, "`{s}()` argument {d} is a concatenation `{{...}}`: write the assignment pattern `'{{...}}`", .{ name, i + 1 });
            return poison;
        }
        // §4.5.1 "Certain analog operators require arrays or vectors to be
        // passed as arguments: Laplace filters, Z-transform filters ... An
        // array can either be passed as an array_identifier ... or an array
        // assignment pattern." Those two slots are the only ones: anywhere
        // else an array or a pattern is an ordinary operand, which `lowerExpr`
        // judges, never a vector flattened into the operator's arguments.
        if (coef_slot) {
            if (try appendVectorArg(self, &vals, a)) continue;
            // A scalar in a coefficient slot is neither spelling; a
            // part-select or multidimensional array is left to the ordinary path.
            if (!(self.file.exprs.tag(a) == .index or (self.file.exprs.tag(a) == .ident and self.arrays.contains(self.file.str(self.file.exprs.strOf(a)))))) {
                try self.err(self.file.exprs.mainTok(a), .E0572, "`{s}()` argument {d} is a scalar", .{ name, i + 1 });
                return poison;
            }
        }
        const tv = try lower_expr.lowerExpr(self, a);
        try vals.append(self.arena, if (tv.ty == .string) tv.v else try self.toReal(tv));
    }
    if (std.mem.eql(u8, name, "ddt"))
        return .{ .v = try opDdt(self, ex.mainTok(e), vals.items[0], opAbstol(self, args, 1), try lower_reactive.opSiteLte(self, e)), .ty = .real };
    if (std.mem.eql(u8, name, "idt"))
        return .{ .v = try opIdt(self, e, vals.items), .ty = .real };
    const callee = if (std.mem.eql(u8, name, "absdelay") and try absdelayQuad(self, e)) "absdelay$quad" else name;
    return .{ .v = try self.call(callee, vals.items), .ty = .real };
}

/// §4.5.3 `ddt(x)` as the unknown §4.5.2 introduces: s, with the row
/// s - d/dt(x) = 0 and x its charge. So DC reads the clause's zero, and the
/// host integrates and truncation-checks x like any charge. Returns V(s).
pub fn opDdt(self: *Lower, tok: u32, x: Mir.Value, abstol: f64, lte: bool) Oom!Mir.Value {
    assert(tok < self.tok_starts.len or self.tok_starts.len == 0 or tok == std.math.maxInt(u32));
    assert(self.valueValid(x));
    const s = try lower_node.opStateNode(self, "ddt", abstol);
    const v = try lower_node.probe(self, s);
    try lower_reactive.stampOpRow(self, tok, s, v, x, true, lte);
    return v;
}

/// §4.5.4 `idt` as the unknown §4.5.2 introduces: s, whose charge is s
/// itself and whose resistive half is -x, so the host solves ds/dt = x. The
/// static solve swaps that half for s - ic, since idt() "returns the initial
/// condition (ic) if specified" there, and without an ic keeps -x: "the idt
/// operator must be contained within a negative feedback loop that forces its
/// argument to zero". Returns the operator's value.
fn opIdt(self: *Lower, e: Ast.ExprId, vals: []const Mir.Value) Oom!Mir.Value {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    // ponytail: §4.5.5 idtmod stays in the device (`zIdtmod`), wrapped every
    // step. As a host unknown its state grows without bound, and a free-running
    // VCO's phase drifts with the rounding of |s|. Upgrade: a host that re-bases
    // the unknown on each wrap.
    const x = vals[0];
    const s = try lower_node.opStateNode(self, "idt", opAbstol(self, self.file.exprs.args(e), abstolSlot("idt").?));
    const v = try lower_node.probe(self, s);
    // An argument that reads no unknown has no loop to force it, and the
    // undefined DC output takes the 0 an ic of 0 gives, which keeps the
    // static solve regular.
    const ic: ?Mir.Value = if (vals.len > 1) vals[1] else if (!try readsUnknown(self, x)) .f_zero else null;
    // assert: s holds still while it is nonzero (`idt$hold`).
    const hold: ?Mir.Value = if (vals.len > 2) try self.emit(.fne, &.{ vals[2], .f_zero }) else null;
    var f = try self.emit(.fneg, &.{x});
    if (hold) |h| f = try self.emit(.select, &.{ h, .f_zero, f });
    if (ic) |c| f = try self.emit(.select, &.{ try self.call("op$static", &.{}), try self.emit(.fsub, &.{ v, c }), f });
    try lower_reactive.stampOpRow(self, self.file.exprs.mainTok(e), s, f, v, false, try lower_reactive.opSiteLte(self, e));
    return if (hold != null) self.call("idt$hold", &.{ v, ic.?, vals[2] }) else v;
}

/// Whether `v` can read an unknown of the solve: a probe, or anything the walk
/// does not see through (a phi, an array, a committed latch).
fn readsUnknown(self: *Lower, v: Mir.Value) Oom!bool {
    assert(self.valueValid(v));
    const st = &self.analog_op_state;
    st.unknown_seen.clearRetainingCapacity();
    st.unknown_work.clearRetainingCapacity();
    try st.unknown_work.append(self.arena, v);
    // The answer is the disjunction over the reachable set, so the visit
    // order is free; each value is judged once, so the walk ends within the
    // MIR's operand edges.
    const steps_max = 3 * self.mir.insts.len + self.mir.extra.items.len + 1;
    var steps: usize = 0;
    while (st.unknown_work.pop()) |v0| : (steps += 1) {
        assert(steps <= steps_max);
        const x = self.mir.resolveAlias(v0);
        if ((try st.unknown_seen.getOrPut(self.arena, x)).found_existing) continue;
        const inst = switch (self.mir.valueDef(x)) {
            .undef, .float_const, .int_const, .str_const, .param_ref => continue,
            .block_param => return true,
            .inst_result => |i| i,
        };
        switch (self.mir.instData(inst)) {
            .unary => |u| {
                if (u.op == .path_prev or u.op == .path_acc) return true;
                try st.unknown_work.append(self.arena, u.operand);
            },
            .binary => |bn| try st.unknown_work.appendSlice(self.arena, &.{ bn.lhs, bn.rhs }),
            .ternary => |t| try st.unknown_work.appendSlice(self.arena, &.{ t.cond, t.then_val, t.else_val }),
            .call => |c| try st.unknown_work.appendSlice(self.arena, c.args),
            .phi, .branch, .jump, .anew, .load, .store => return true,
        }
    }
    assert(st.unknown_work.items.len == 0);
    return false;
}

/// The tolerance of an operator's unknown: its §4.5.3/§4.5.4 abstol or nature
/// argument in `slot`, folded at the parameters' declared defaults, else the
/// 1e-6 an undisciplined net gets.
fn opAbstol(self: *Lower, args: []const Ast.ExprId, slot: usize) f64 {
    if (slot >= args.len or args[slot] == .none) return 1e-6;
    if (natureAbstol(self, args[slot])) |t| return t;
    const c = lower_constfold.constEval(self, args[slot]) orelse return 1e-6;
    return if (c == .str) 1e-6 else c.asReal();
}

/// Reports whether `absdelay` call `e` interpolates quadratically, from VerA's
/// `vera_interp` attribute, innermost wins: the call's own suffix, then the nearest
/// enclosing statement's (`interp_stack`), then §4.5.7's "linear interpolation".
fn absdelayQuad(self: *Lower, e: Ast.ExprId) Oom!bool {
    assert(e == .none or self.exprValid(e));
    if (self.file.exprLte(e, .vera_interp)) |a| return interpQuad(self, a);
    return self.interp_stack.last() orelse false;
}

/// Returns whether a `vera_interp` value selects quadratic (2) over linear (1, the
/// §2.9 default when absent). It must fold without the model card because it picks
/// the emitted kernel; otherwise reports E0524 and returns false.
pub fn interpQuad(self: *Lower, a: Ast.LteAttr) Oom!bool {
    if (a.value == .none) return false;
    const c = lower_constfold.foldExpr(self, a.value, false) orelse {
        try self.err(a.main_tok, .E0524, "the value depends on the model card", .{});
        return false;
    };
    const v = c.asReal(); // a string is 0
    if (v != 1 and v != 2) {
        try self.err(a.main_tok, .E0524, "", .{});
        return false;
    }
    return v == 2;
}

/// Which argument of an analog operator is its tolerance, or null for an
/// operator that has none. §5.5.3, last sentence: "The abstol attribute of a
/// nature may also be accessed simply by using the nature's identifier as the
/// A.8.2 Syntax 4-3's longest argument list per `analog_filter_function_call`
/// (`ddx` is checked exactly on its own path), or null for a name it does not
/// list.
fn maxArgs(name: []const u8) ?usize {
    const table = std.StaticStringMap(usize).initComptime(.{
        .{ "ddt", 2 },           .{ "idt", 4 },        .{ "idtmod", 5 },
        .{ "absdelay", 3 },      .{ "transition", 5 }, .{ "slew", 3 },
        .{ "last_crossing", 2 }, .{ "limexp", 1 },
    });
    if (table.get(name)) |n| return n;
    if (std.mem.startsWith(u8, name, "laplace_")) return 4;
    if (std.mem.startsWith(u8, name, "zi_")) return 6;
    return null;
}

/// appropriate argument to the ddt(), idt(), or idtmod() operators described in
/// 4.5." Those three, and the slot each of their signatures puts it in:
///
///     4.5.3  ddt(expr [, abstol|nature])
///     4.5.4  idt(expr [, ic [, assert [, abstol|nature]]])
///     4.5.5  idtmod(expr [, ic [, modulus [, offset [, abstol|nature]]]])
///
/// Written out rather than computed from `args.len`, so a call that dropped a
/// trailing argument does not read its `assert` or `offset` as a tolerance.
fn abstolSlot(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "ddt")) return 1;
    if (std.mem.eql(u8, name, "idt")) return 3;
    if (std.mem.eql(u8, name, "idtmod")) return 4;
    return null;
}

/// Returns the value in operator `name`'s tolerance slot, A.8.3's
/// `abstol_expression ::= constant_expression | nature_identifier`, or null
/// after reporting E0515 for an expression that moves during the analysis:
/// Table 4-20 lists abstol among each operator's "Constant expression
/// arguments", and "The constant expressions remain static throughout an
/// analysis" (§4.5.14). Judged on what the value depends on, so a tolerance
/// held in a variable that only literals and parameters reach still passes.
pub fn lowerAbstolArg(self: *Lower, name: []const u8, e: Ast.ExprId) Oom!?Mir.Value {
    assert(name.len != 0);
    assert(e == .none or self.exprValid(e));
    if (natureAbstol(self, e)) |t| return try self.mir.addFloatConst(self.arena, t);
    // A `.banned` §5.5.3 reference has no value and gets its E0359 here.
    const tv = try lower_expr.lowerExpr(self, e);
    if (tv.ty != .string and !try lower_static.isStaticValue(self, tv.v)) {
        try self.err(self.file.exprs.mainTok(e), .E0515, "`{s}()` abstol is a constant expression argument (Table 4-20), and this one moves during the analysis", .{name});
        return null;
    }
    return if (tv.ty == .string) tv.v else try self.toReal(tv);
}

/// The abstol a bare `nature_identifier` or `net.potential.abstol` in a tolerance
/// slot stands for, or null. A variable or parameter with the same name wins (§2.8).
fn natureAbstol(self: *Lower, e: Ast.ExprId) ?f64 {
    assert(e == .none or self.exprValid(e));
    const ex = &self.file.exprs;
    // §5.5.3's other spelling of the same value, `n1.potential.abstol`. Its last
    // sentence makes the two interchangeable in this slot.
    if (ex.tag(e) == .hier_ident) {
        // A `.banned` attribute is diagnosed by `lowerExpr`, which every caller
        // falls through to; returning null here is what routes it there.
        const r = natureAttrRef(self, e) orelse return null;
        return switch (r) {
            .value => |c| switch (c) {
                .real, .int => c.asReal(),
                .str => null,
            },
            .banned => null,
        };
    }
    if (ex.tag(e) != .ident) return null;
    const id = ex.strOf(e);
    const name = self.file.str(id);
    if (self.vars.contains(name) or self.param_index.contains(name) or self.consts.contains(name))
        return null;
    for (self.file.natures) |*n| {
        if (n.name != id) continue;
        // Reached only for a nature `checkNatureTable` already refused (§3.6.1.2
        // makes `abstol` mandatory); answering "a nature" avoids a second E0314.
        return lower_discipline.natureOf(self, id).abstol orelse 0;
    }
    return null;
}

/// A resolved §5.5.3 `nature_attribute_reference` (`a.potential.abstol`): its
/// constant value, or the attribute name when Syntax 5-4 bans it ("shall not be
/// used for the access, ddt_nature, or idt_nature attributes ... nor any other
/// attribute whose value is not a constant expression").
pub const NatureRef = union(enum) {
    value: Const,
    /// The attribute named, for the message.
    banned: []const u8,
};
/// Resolves `e` as `net.potential.attr` or `net.flow.attr` through the net's
/// discipline, or returns null when it is a §6.8 hierarchical name instead.
/// `abstol` comes from `DisciplineInfo`, where a §3.6.2.3 discipline override is applied.
pub fn natureAttrRef(self: *Lower, e: Ast.ExprId) ?NatureRef {
    assert(e == .none or self.exprValid(e));
    const parts = self.file.exprs.nameParts(e);
    if (parts.len != 3) return null;
    const half = self.file.str(parts[1]);
    const is_potential = std.mem.eql(u8, half, "potential");
    if (!is_potential and !std.mem.eql(u8, half, "flow")) return null;

    const dname = if (self.design.attribute_disciplines.get(e)) |disc| self.file.str(disc) else blk: {
        const net = self.file.str(parts[0]);
        // §5.5.3 "the attributes for a net or a branch": a §3.12 branch reads
        // the discipline of its terminals, which §3.11 makes compatible; the
        // lo terminal when hi is ground.
        const idx = self.node_voltages.get(net) orelse if (self.branches.get(net)) |b|
            (if (b.hi == ground) b.lo else b.hi)
        else
            self.port_branches.get(net) orelse return null;
        if (idx == ground) return null;
        break :blk self.out.nodes.items(.disc)[idx];
    };
    const attr = self.file.str(parts[2]);

    if (std.mem.eql(u8, attr, "abstol")) {
        const info = self.out.disciplines.get(dname) orelse return null;
        return .{ .value = .{ .real = if (is_potential) info.potential_abstol else info.flow_abstol } };
    }
    // ponytail: reuse compatibility's first-declaration lookup.
    const d = lower_discipline.disciplineDecl(self, dname) orelse return null;
    const nat = if (is_potential) d.potential else d.flow;
    if (nat == .none) return null;
    const v = self.file.natureAttrExpr(nat, attr) orelse return .{ .banned = attr };
    return .{ .value = lower_constfold.constEval(self, v) orelse return .{ .banned = attr } };
}

/// §4.5.5-§4.5.10 control-argument bounds (E0516). Only folded operands are judged:
/// A.8.2 types these slots `analog_expression`, so a bound over parameters is
/// legal and unknowable here. Checked in lowering, where the LRM's names for the
/// arguments are still known for the message.
fn checkFilterArgBounds(self: *Lower, name: []const u8, args: []const Ast.ExprId) Oom!void {
    assert(name.len != 0);
    const Bound = enum {
        positive,
        non_negative,
        negative,

        fn holds(b: @This(), v: f64) bool {
            return switch (b) {
                .positive => v > 0,
                .non_negative => v >= 0,
                .negative => v < 0,
            };
        }
        /// The LRM's own word for the bound; it goes in the message.
        fn word(b: @This()) []const u8 {
            return switch (b) {
                .positive => "positive",
                .non_negative => "non-negative",
                .negative => "negative",
            };
        }
    };
    const Rule = struct { i: usize, arg: []const u8, want: Bound };
    const rules: []const Rule = if (std.mem.eql(u8, name, "idtmod"))
        &.{.{ .i = 2, .arg = "modulus", .want = .positive }}
    else if (std.mem.eql(u8, name, "absdelay"))
        // "In all cases" covers the optional-maxdelay form too, so the index is
        // the same for both spellings.
        &.{.{ .i = 1, .arg = "td", .want = .positive }}
    else if (std.mem.eql(u8, name, "transition"))
        &.{
            .{ .i = 1, .arg = "td", .want = .non_negative },
            .{ .i = 2, .arg = "rise_time", .want = .non_negative },
            .{ .i = 3, .arg = "fall_time", .want = .non_negative },
            .{ .i = 4, .arg = "time_tol", .want = .non_negative },
        }
    else if (std.mem.eql(u8, name, "slew"))
        // Checked on the written arguments, before §4.5.9's "if the
        // max_neg_slew_rate is not specified, it defaults to the opposite of
        // the max_pos_slew_rate" can manufacture a well-signed second rate out
        // of a badly-signed first one.
        &.{
            .{ .i = 1, .arg = "max_pos_slew_rate", .want = .positive },
            .{ .i = 2, .arg = "max_neg_slew_rate", .want = .negative },
        }
    else
        &.{};

    for (rules) |r| {
        if (r.i >= args.len or args[r.i] == .none) continue;
        const c = lower_constfold.constEval(self, args[r.i]) orelse continue;
        if (c == .str) continue; // a type error, not a range one
        const v = c.asReal();
        if (r.want.holds(v)) continue;
        try self.err(self.file.exprs.mainTok(args[r.i]), .E0516, "`{s}()` argument `{s}` shall be {s}, got {d}", .{ name, r.arg, r.want.word(), v });
    }

    // §4.5.10: "The optional direction indicator shall evaluate to an integer
    // expression +1, -1, or 0." An enumeration, not a range.
    if (std.mem.eql(u8, name, "last_crossing") and args.len > 1 and args[1] != .none) {
        if (lower_constfold.constEval(self, args[1])) |c| {
            const v = c.asReal();
            if (c != .str and (v != @round(v) or @abs(v) > 1))
                try self.err(self.file.exprs.mainTok(args[1]), .E0516, "`last_crossing()` direction indicator shall be +1, -1 or 0, got {d}", .{v});
        }
    }
}

/// §4.5.11/§4.5.12: a laplace or Z-transform filter, whose second and third
/// slots are coefficient vectors.
fn isCoefFilter(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "laplace_") or std.mem.startsWith(u8, name, "zi_");
}

/// §4.5.11/§4.5.12: does this filter take its zeros as a root vector, so that
/// the null form `f(x, , poles, …)` reads as the empty product 1?
fn nullZerosOk(name: []const u8) bool {
    const forms = [_][]const u8{ "laplace_zp", "laplace_zd", "zi_zp", "zi_zd" };
    for (forms) |f| {
        if (std.mem.eql(u8, name, f)) return true;
    }
    return false;
}

/// Appends a vector argument to `out` as `<count>, e0, e1, ...`: a §4.5.11/§4.5.12
/// filter coefficient vector or §9.21/§4.6.4 data vector, spelled as an assignment
/// pattern `'{a,b}` or an array name (§3.4.4). Returns false when `a` is a scalar,
/// appending nothing. Invalidates element pointers of `out` if it grows.
pub fn appendVectorArg(self: *Lower, out: *std.ArrayList(Mir.Value), a: Ast.ExprId) Oom!bool {
    assert(a == .none or self.exprValid(a));
    const ex = &self.file.exprs;
    switch (ex.tag(a)) {
        .assign_pattern, .concat => {
            const elems = try lower_shape.patternElems(self, a);
            try out.append(self.arena, try self.mir.addIntConst(self.arena, @intCast(elems.len)));
            for (elems) |el|
                try out.append(self.arena, try self.toReal(try lower_expr.lowerExpr(self, el)));
            return true;
        },
        .ident => {
            const name = self.file.str(ex.strOf(a));
            const info = self.arrays.get(name) orelse return false;
            // §4.5.11's coefficient slot is a flat vector: a multidimensional
            // array has no reading as a list of poles and is left to the
            // ordinary path, which reports it (E0356).
            if (info.dims.len != 1) return false;
            const d = info.dims[0];
            try out.append(self.arena, try self.mir.addIntConst(self.arena, d.count()));
            var index: [1]i64 = undefined;
            for (0..@intCast(d.count())) |k| {
                lower_shape.shapeSubscripts(info.dims, k, &index);
                const el = (try lower_expr_select.arrayElemValue(self, name, &index)) orelse return true;
                try out.append(self.arena, try self.toReal(el));
            }
            return true;
        },
        // A.8.2's third shape, for both `analog_filter_function_arg` and
        // `noise_table_input_arg`: `parameter_identifier [ msb_constant_expression
        // : lsb_constant_expression ]`, the elements from msb to lsb.
        .index => {
            const sel = ex.rhs(a);
            if (ex.tag(ex.lhs(a)) != .ident or ex.tag(sel) != .range) return false;
            const name = self.file.str(ex.strOf(ex.lhs(a)));
            const info = self.arrays.get(name) orelse return false;
            if (info.dims.len != 1) return false;
            const d = info.dims[0];
            // A refused select is still a vector, of no elements, so the
            // caller's `<count>, elements` slice stays well formed.
            var ends: [2]i64 = undefined;
            for ([2]Ast.ExprId{ ex.lhs(sel), ex.rhs(sel) }, &ends) |b, *end| {
                const c = lower_constfold.shapeEval(self, b) orelse {
                    try self.err(ex.mainTok(b), .E0308, "in the part select of `{s}`", .{name});
                    try out.append(self.arena, try self.mir.addIntConst(self.arena, 0));
                    return true;
                };
                end.* = c.asInt();
                if (end.* < d.lo or end.* > d.hi) {
                    try self.err(ex.mainTok(b), .E0310, "index {d} is outside `{s}[{d}:{d}]`", .{ end.*, name, d.lo, d.hi });
                    try out.append(self.arena, try self.mir.addIntConst(self.arena, 0));
                    return true;
                }
            }
            const n = @abs(ends[1] - ends[0]) + 1;
            const step: i64 = if (ends[1] >= ends[0]) 1 else -1;
            try out.append(self.arena, try self.mir.addIntConst(self.arena, @intCast(n)));
            for (0..@as(usize, @intCast(n))) |k| {
                const el = (try lower_expr_select.arrayElemValue(self, name, &.{ends[0] + step * @as(i64, @intCast(k))})) orelse return true;
                try out.append(self.arena, try self.toReal(el));
            }
            return true;
        },
        else => return false, // else: not one of A.8.2's vector shapes; the ordinary path lowers or reports it
    }
}

test isHistoryless {
    // A.8.2's two analog_filter_function_call names with no state.
    try std.testing.expect(isHistoryless("ddx"));
    try std.testing.expect(isHistoryless("limexp"));
    try std.testing.expect(!isHistoryless("ddt"));
    try std.testing.expect(!isHistoryless("absdelay"));
}

test abstolSlot {
    // §4.5.3/§4.5.4/§4.5.5's signatures, counted from 0.
    try std.testing.expectEqual(@as(?usize, 1), abstolSlot("ddt"));
    try std.testing.expectEqual(@as(?usize, 3), abstolSlot("idt"));
    try std.testing.expectEqual(@as(?usize, 4), abstolSlot("idtmod"));
    try std.testing.expectEqual(@as(?usize, null), abstolSlot("transition"));
}

test nullZerosOk {
    // §4.5.11/§4.5.12: only the root forms read an empty zeros slot as 1.
    for ([_][]const u8{ "laplace_zp", "laplace_zd", "zi_zp", "zi_zd" }) |n| try std.testing.expect(nullZerosOk(n));
    for ([_][]const u8{ "laplace_nd", "laplace_np", "zi_nd", "zi_np", "ddt" }) |n| try std.testing.expect(!nullZerosOk(n));
}

test isCoefFilter {
    try std.testing.expect(isCoefFilter("laplace_nd"));
    try std.testing.expect(isCoefFilter("zi_zp"));
    try std.testing.expect(!isCoefFilter("transition"));
    try std.testing.expect(!isCoefFilter("laplace"));
}

test "lower: §5.8.1 an analog operator under a runtime condition (E0514)" {
    // What makes this rule worth a diagnostic: an analog operator is a state
    // machine the kernel steps once per accepted timestep. Under a branch the
    // solve can flip, the step its arm was off feeds it the type's zero, and its
    // history is wrong from then on — with a residual that still looks ordinary.
    //
    // Each case is the SAME operator under a different condition; only the
    // condition decides the verdict, which is exactly what §5.8.1 says.
    const cases = [_]struct { cond: []const u8, warns: bool }{
        // Not an analysis_or_constant_expression: a probe moves every iteration.
        .{ .cond = "V(c) > 0.5", .warns = true },
        .{ .cond = "V(c) > 0.5 && gain > 0.0", .warns = true },
        // A.8.2 analysis_function_call — §5.8.1 names it explicitly.
        .{ .cond = "analysis(\"dc\")", .warns = false },
        .{ .cond = "!analysis(\"tran\")", .warns = false },
        // constant_primary: a §3.4 parameter cannot move mid-analysis.
        .{ .cond = "gain > 0.0", .warns = false },
        .{ .cond = "analysis(\"dc\") || gain > 0.0", .warns = false },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print(
            \\module m(p, n, c);
            \\  inout p, n, c;
            \\  electrical p, n, c;
            \\  parameter real gain = 1.0;
            \\  real q;
            \\  analog begin
            \\    q = 0.0;
            \\    if ({s}) q = ddt(V(p, n));
            \\    I(p, n) <+ q;
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
            if (h.bag.at(i).code == .E0514) seen = true;
        }
        std.testing.expectEqual(c.warns, seen) catch |e| {
            std.debug.print("condition: if ({s})\n", .{c.cond});
            return e;
        };
    }
}

test "lower: §5.9 a loop body has no carve-out, and §4.5.6/§4.5.13 have no history" {
    // §5.9's ban on analog filter functions in repeat/while/non-genvar `for` is
    // unconditional — there is no analysis_or_constant escape hatch — so a
    // constant loop bound does NOT license the operator.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  integer i; real q;
        \\  analog begin
        \\    q = 0.0;
        \\    for (i = 0; i < 3; i = i + 1) q = q + ddt(V(p, n));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    );
    defer h.deinit();
    try std.testing.expectError(error.DiagnosticsReported, h.low.lowerFile());
    try std.testing.expectEqual(diag.Code.E0514, h.bag.at(0).code);

    // ...but a genvar `for` (§5.9.3 analog_for) is unrolled onto the spine, so
    // every operator instance is stepped every time: no warning.
    var h2: Lower.Harness = undefined;
    try h2.init(std.testing.allocator,
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  genvar i; real q;
        \\  analog begin
        \\    q = 0.0;
        \\    for (i = 0; i < 3; i = i + 1) q = q + ddt(V(p, n));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    );
    defer h2.deinit();
    _ = try h2.low.lowerFile();
    try std.testing.expect(h2.bag.isEmpty());

    // `ddx` (§4.5.6) and `limexp` (§4.5.13) read no previous timestep, so a
    // branch that was off cannot corrupt them. `vdmos.va` calls conditional
    // `limexp` three times; warning there would be noise, and noise is what
    // teaches a modeller to silence the code.
    var h3: Lower.Harness = undefined;
    try h3.init(std.testing.allocator,
        \\module m(p, n, c);
        \\  inout p, n, c;
        \\  electrical p, n, c;
        \\  real q;
        \\  analog begin
        \\    q = 0.0;
        \\    if (V(c) > 0.5) q = limexp(V(p, n)) + ddx(V(p, n), V(p));
        \\    I(p, n) <+ q;
        \\  end
        \\endmodule
    );
    defer h3.deinit();
    _ = try h3.low.lowerFile();
    try std.testing.expect(h3.bag.isEmpty());
}

test "§4.5 analog operators: argument shapes and bounds" {
    try Lower.expectBodies(&.{
        // §4.5.1: only the laplace and Z-transform coefficient slots take an
        // array. Anywhere else a pattern is §4.2's scalar context (E0509),
        // never a vector flattened into the operator's other arguments.
        .{ .src = "analog I(p) <+ transition('{1.0, 2.0});", .code = .E0509 },
        .{ .src = "analog I(p) <+ laplace_nd(V(p), '{1.0}, '{1.0, 1.0});", .code = null },
        // §4.5.11: a scalar in a coefficient slot is neither array spelling.
        .{ .src = "analog I(p) <+ laplace_nd(V(p), 1.0, '{1.0, 1.0});", .code = .E0572 },
        // §4.5.6: the second argument is one unknown; V(p, q) is two.
        .{ .src = "analog I(p) <+ ddx(V(p), V(p, q));", .code = .E0504 },
        .{ .src = "analog I(p) <+ ddx(V(p), V(p));", .code = null },
        // §4.5.8 td, §4.5.9 the two rates, §4.5.5 modulus, §4.5.10 direction.
        .{ .src = "analog I(p) <+ transition(V(p), -1.0);", .code = .E0516 },
        .{ .src = "analog I(p) <+ transition(V(p), 0.0);", .code = null },
        .{ .src = "analog I(p) <+ slew(V(p), 1.0, 1.0);", .code = .E0516 },
        .{ .src = "analog I(p) <+ idtmod(V(p), 0.0, 0.0);", .code = .E0516 },
        .{ .src = "analog I(p) <+ last_crossing(V(p), 2);", .code = .E0516 },
        // Table 4-20: abstol is a constant expression argument; a probe moves.
        .{ .src = "analog I(p) <+ ddt(V(p), V(q));", .code = .E0515 },
        .{ .src = "analog I(p) <+ ddt(V(p), 1e-6);", .code = null },
        // A.8.2's longest list for each operator, and one past it.
        .{ .src = "analog I(p) <+ transition(V(p), 0.0, 1n, 1n, 1p);", .code = null },
        .{ .src = "analog I(p) <+ transition(V(p), 0.0, 1n, 1n, 1p, 1.0);", .code = .E0506 },
        .{ .src = "analog I(p) <+ ddt(V(p), 1e-6, 1.0);", .code = .E0506 },
        .{ .src = "analog I(p) <+ idt(V(p), 0.0, 0, 1e-6, 1.0);", .code = .E0506 },
        .{ .src = "analog I(p) <+ idtmod(V(p), 0.0, 1.0, 0.0, 1e-6, 1.0);", .code = .E0506 },
        .{ .src = "analog I(p) <+ absdelay(V(p), 1n, 1n, 1.0);", .code = .E0506 },
        .{ .src = "analog I(p) <+ slew(V(p), 1.0, -1.0, 1.0);", .code = .E0506 },
        .{ .src = "analog I(p) <+ last_crossing(V(p), 1, 1.0);", .code = .E0506 },
        .{ .src = "analog I(p) <+ limexp(V(p), 1.0);", .code = .E0506 },
        .{ .src = "analog I(p) <+ laplace_nd(V(p), '{1.0}, '{1.0, 1.0}, 1e-6, 1.0);", .code = .E0506 },
        .{ .src = "analog I(p) <+ zi_nd(V(p), '{1.0}, '{1.0, 1.0}, 1n, 0.0, 0.0, 1.0);", .code = .E0506 },
    });
}

test "readsUnknown: a 5000-statement dependence chain under idt is judged on a 1 MiB stack" {
    // Width, not nesting: `y = y + 1.0;` 5000 times is a 5000-deep chain of
    // `fadd` values, so the recursive walk from `idt(y)` overflowed the stack.
    // Oracle: the module lowers with no diagnostic (the chain starts at a
    // constant, so `idt` takes its zero initial condition).
    const gpa = std.testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(gpa);
    try src.appendSlice(gpa, "module m(p, n);\n  inout p, n;\n  electrical p, n;\n  real y;\n  analog begin\n    y = 0.0;\n");
    for (0..5000) |_| try src.appendSlice(gpa, "    y = y + V(p, n);\n");
    try src.appendSlice(gpa, "    I(p, n) <+ idt(y);\n  end\nendmodule\n");
    var h: Lower.Harness = undefined;
    try h.init(gpa, src.items);
    defer h.deinit();
    _ = try h.lowerOnStack(1 << 20) orelse {
        h.dump();
        return error.TestUnexpectedResult;
    };
}
