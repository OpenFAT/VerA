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
const Lower = @import("lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_contrib = @import("contrib.zig");
const lower_control = @import("control.zig");
const lower_discipline = @import("discipline.zig");
const lower_expr = @import("expr.zig");
const lower_hier_name = @import("hier_name.zig");
const lower_node = @import("node.zig");
const lower_table_model = @import("table_model.zig");
const lower_shape = @import("shape.zig");
const Ast = @import("frontend").Ast;
const diag = @import("diag");
const Mir = @import("ir").Mir;
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
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(e), .E0422, "not allowed in {s}", .{ctx});
        return false;
    }
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
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const args = ex.args(e);
    if (!try checkOperatorPlace(self, e, name)) return poison;

    // §4.5.6 ddx(f, V(node)): the second argument is a probe, not a value;
    // it names the unknown to differentiate with respect to.
    if (std.mem.eql(u8, name, "ddx")) {
        if (args.len != 2) return lower_expr.arityError(self, e, name, 2);
        const f = try self.toReal(try lower_expr.lowerExpr(self, args[0]));
        if (ex.tag(args[1]) != .branch_access) {
            try self.err(self.file.exprs.mainTok(e), .E0504, "", .{});
            return poison;
        }
        const t = try lower_contrib.branchOf(self, args[1]) orelse return poison;
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
        return .{ .v = try opDdt(self, ex.mainTok(e), vals.items[0], opAbstol(self, args, 1), try lower_contrib.opSiteLte(self, e)), .ty = .real };
    if (std.mem.eql(u8, name, "idt"))
        return .{ .v = try opIdt(self, e, vals.items), .ty = .real };
    const callee = if (std.mem.eql(u8, name, "absdelay") and try absdelayQuad(self, e)) "absdelay$quad" else name;
    return .{ .v = try self.call(callee, vals.items), .ty = .real };
}

/// §4.5.3 `ddt(x)` as the unknown §4.5.2 introduces: s, with the row
/// s - d/dt(x) = 0 and x its charge. So DC reads the clause's zero, and the
/// host integrates and truncation-checks x like any charge. Returns V(s).
pub fn opDdt(self: *Lower, tok: u32, x: Mir.Value, abstol: f64, lte: bool) Oom!Mir.Value {
    const s = try lower_node.opStateNode(self, "ddt", abstol);
    const v = try lower_node.probe(self, s);
    try lower_contrib.stampOpRow(self, tok, s, v, x, true, lte);
    return v;
}

/// §4.5.4 `idt` as the unknown §4.5.2 introduces: s, whose charge is s
/// itself and whose resistive half is -x, so the host solves ds/dt = x. The
/// static solve swaps that half for s - ic, since idt() "returns the initial
/// condition (ic) if specified" there, and without an ic keeps -x: "the idt
/// operator must be contained within a negative feedback loop that forces its
/// argument to zero". Returns the operator's value.
fn opIdt(self: *Lower, e: Ast.ExprId, vals: []const Mir.Value) Oom!Mir.Value {
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
    try lower_contrib.stampOpRow(self, self.file.exprs.mainTok(e), s, f, v, false, try lower_contrib.opSiteLte(self, e));
    return if (hold != null) self.call("idt$hold", &.{ v, ic.?, vals[2] }) else v;
}

/// Whether `v` can read an unknown of the solve: a probe, or anything the walk
/// does not see through (a phi, an array, a committed latch).
fn readsUnknown(self: *Lower, v: Mir.Value) Oom!bool {
    const seen = &self.analog_op_state.unknown_seen;
    seen.clearRetainingCapacity();
    return unknownWalk(self, v, seen);
}

fn unknownWalk(self: *Lower, v0: Mir.Value, seen: *std.AutoHashMapUnmanaged(Mir.Value, void)) Oom!bool {
    const v = self.mir.resolveAlias(v0);
    if ((try seen.getOrPut(self.arena, v)).found_existing) return false;
    const inst = switch (self.mir.valueDef(v)) {
        .undef, .float_const, .int_const, .str_const, .param_ref => return false,
        .block_param => return true,
        .inst_result => |i| i,
    };
    return switch (self.mir.instData(inst)) {
        .unary => |u| u.op == .path_prev or u.op == .path_acc or try unknownWalk(self, u.operand, seen),
        .binary => |b| try unknownWalk(self, b.lhs, seen) or try unknownWalk(self, b.rhs, seen),
        .ternary => |t| try unknownWalk(self, t.cond, seen) or try unknownWalk(self, t.then_val, seen) or
            try unknownWalk(self, t.else_val, seen),
        .call => |c| for (c.args) |a| {
            if (try unknownWalk(self, a, seen)) break true;
        } else false,
        .phi, .branch, .jump, .anew, .load, .store => true,
    };
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
    if (natureAbstol(self, e)) |t| return try self.mir.addFloatConst(self.arena, t);
    // A `.banned` §5.5.3 reference has no value and gets its E0359 here.
    const tv = try lower_expr.lowerExpr(self, e);
    if (tv.ty != .string and !try lower_control.isStaticValue(self, tv.v)) {
        try self.err(self.file.exprs.mainTok(e), .E0515, "`{s}()` abstol is a constant expression argument (Table 4-20), and this one moves during the analysis", .{name});
        return null;
    }
    return if (tv.ty == .string) tv.v else try self.toReal(tv);
}

/// The abstol a bare `nature_identifier` or `net.potential.abstol` in a tolerance
/// slot stands for, or null. A variable or parameter with the same name wins (§2.8).
fn natureAbstol(self: *Lower, e: Ast.ExprId) ?f64 {
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
    const parts = self.file.exprs.nameParts(e);
    if (parts.len != 3) return null;
    const half = self.file.str(parts[1]);
    const is_potential = std.mem.eql(u8, half, "potential");
    if (!is_potential and !std.mem.eql(u8, half, "flow")) return null;

    const dname = if (self.attribute_disciplines.get(e)) |disc| self.file.str(disc) else blk: {
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
                const el = (try lower_expr.arrayElemValue(self, name, &index)) orelse return true;
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
                const el = (try lower_expr.arrayElemValue(self, name, &.{ends[0] + step * @as(i64, @intCast(k))})) orelse return true;
                try out.append(self.arena, try self.toReal(el));
            }
            return true;
        },
        else => return false, // else: not one of A.8.2's vector shapes; the ordinary path lowers or reports it
    }
}

/// Lowers a §4.6.4 noise source call. It contributes only in a small-signal noise
/// analysis; codegen decides that from the call name (the value is 0 in DC).
pub fn lowerNoise(self: *Lower, e: Ast.ExprId) Oom!TypedValue {
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    // VerA's `vera_timepoint` (§2.9): a source is a stamp, not a value.
    if (self.tp_cur != null) {
        try self.err(ex.mainTok(e), .E0530, "the noise function `{s}` (§4.6.4)", .{name});
        return poison;
    }
    // A.8.2 analog_small_signal_function_call brackets only trailing optional
    // arguments; no form has an `_or_null` slot, so an empty one has no meaning.
    for (ex.args(e)) |a| if (a == .none) {
        try self.err(ex.mainTok(e), .E0505, "`{s}()` (A.8.2 gives the small-signal functions no empty slot)", .{name});
        return poison;
    };
    // A.8.2 `ac_stim ( [ " analysis_identifier " [ , analog_expression ...`:
    // the quotation marks are in the production, so the analysis name is a
    // string literal.
    if (std.mem.eql(u8, name, "ac_stim")) if (ex.args(e).len != 0) {
        const a0 = ex.args(e)[0];
        if (a0 != .none and ex.tag(a0) != .str_literal) {
            try self.err(ex.mainTok(a0), .E0521, "", .{});
            return poison;
        }
        // A name that is not a Table 4-21 small-signal kind matches the
        // analysis the host labels with it (`contract.acStimActive`, VD-109),
        // so the device reads the host's Table 9-28 `analysis_name`.
        if (a0 != .none) {
            const s = self.file.str(ex.strOf(a0));
            if (!std.mem.eql(u8, s, "ac") and !std.mem.eql(u8, s, "noise")) self.out.uses.insert(.host_strings);
        }
    };
    // Syntax 4-4 `flicker_noise ( analog_expression , analog_expression
    // [ , string ] )`: only the name is bracketed. §4.6.4.2's "1/f^exp" has no
    // default exponent, so a one-argument call has no spectrum to invent.
    if (std.mem.eql(u8, name, "flicker_noise")) {
        var n: usize = 0;
        for (ex.args(e)) |a| n += @intFromBool(a != .none);
        if (n < 2) {
            try self.err(ex.mainTok(e), .E0522, "got {d} argument(s)", .{n});
            return poison;
        }
    }
    // Syntax 4-4: each noise function's optional last argument is `string`,
    // §4.6.4.1's "name argument [that] acts as a label for the noise source".
    const label_at: ?usize = if (std.mem.eql(u8, name, "white_noise") or
        std.mem.eql(u8, name, "noise_table") or std.mem.eql(u8, name, "noise_table_log"))
        1
    else if (std.mem.eql(u8, name, "flicker_noise"))
        2
    else
        null;
    if (label_at) |li| if (ex.args(e).len > li and ex.args(e)[li] != .none) {
        const a = ex.args(e)[li];
        const c = lower_constfold.constEval(self, a);
        if (c == null or c.? != .str) {
            try self.err(ex.mainTok(a), .E0573, "`{s}()` argument {d} is its label", .{ name, li + 1 });
            return poison;
        }
    };
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    // §4.6.4 the PSD arguments, positionally: arg 0 is the power, arg 1 of
    // `flicker_noise` is the exponent. Recorded here, the only place the call's
    // arguments are lowered. The seeds are §4.6.3's `ac_stim` defaults: "The
    // default magnitude is one (1) and the default phase is zero (0)".
    var psd: [2]Mir.Value = if (std.mem.eql(u8, name, "ac_stim"))
        .{ .f_one, .f_zero }
    else
        .{ .f_zero, .f_one };
    var reals: usize = 0;
    // §4.6.4.3/.4 the table itself: `appendVectorArg` writes the count, then the
    // elements, so the pairs are the slice after the count.
    var tab: ?struct { usize, usize } = null;
    // A.8.2's `noise_table_input_arg` is argument 0 of `noise_table`/
    // `noise_table_log` only; every other form's trailing `string` is a label.
    const table_input = std.mem.eql(u8, name, "noise_table") or
        std.mem.eql(u8, name, "noise_table_log");
    for (ex.args(e), 0..) |a, ai| {
        if (a == .none) continue;
        const at = vals.items.len;
        // §4.6.4.3's FILE form of the input: "When the input is a file name,
        // the indicated file will contain the frequency / power pairs. The
        // file name argument shall be constant". So the pairs are compile-time
        // data and land in the same slot the vector form fills.
        if (table_input and ai == 0) if (lower_constfold.constEval(self, a)) |c| if (c == .str) {
            if (try lower_table_model.readNoiseTableFile(self, e, c.str)) |pairs| {
                try vals.append(self.arena, try self.mir.addIntConst(self.arena, @intCast(pairs.len)));
                for (pairs) |x| try vals.append(self.arena, try self.mir.addFloatConst(self.arena, x));
                if (tab == null) tab = .{ at + 1, vals.items.len };
            }
            continue;
        };
        // The same slot is the only one a vector belongs in: anywhere else a
        // pattern or an array is an ordinary operand, which `lowerExpr` judges.
        if (table_input and ai == 0 and try appendVectorArg(self, &vals, a)) {
            // Indices, not a slice: `vals` keeps growing and may reallocate.
            if (tab == null) tab = .{ at + 1, vals.items.len };
            continue;
        }
        const tv = try lower_expr.lowerExpr(self, a);
        if (tv.ty == .string) {
            try vals.append(self.arena, tv.v);
            continue;
        }
        const rv = try self.toReal(tv);
        if (reals < 2) psd[reals] = rv;
        reals += 1;
        try vals.append(self.arena, rv);
    }
    // §4.6.4.1 `white_noise(pwr[, name])` has one real argument, so its `.f_one`
    // exponent seed is never read as a spectrum; `flicker_noise` always
    // overwrites it (E0522 above refuses the call that would not).
    try self.noise_psd.put(self.arena, @backingInt(e), psd);
    if (tab) |r| try self.noise_tab.put(
        self.arena,
        @backingInt(e),
        try self.arena.dupe(Mir.Value, vals.items[r[0]..r[1]]),
    );
    const result = try self.call(name, vals.items);
    try self.noise_val.put(self.arena, @backingInt(e), result);
    return .{ .v = result, .ty = .real };
}

/// A §4.6.4.6 noise coefficient, `∂contribution/∂generator`. A noise function is an
/// amplitude combined linearly, so for correlated noise ("the output of one noise
/// function for more than one noise source") the derivative is the constant factor
/// the branch applies to it:
///   absent     the generator does not occur here, so its coefficient is 0 and
///              this statement adds nothing to the branch's total;
///   nonlinear  it occurs in a shape no single factor describes (squared, in a
///              denominator, inside a call), so there is no coefficient;
///   value      the factor.
const Coeff = union(enum) { absent, nonlinear, value: Mir.Value };

/// Returns `-v`, folded when `v` is a literal so the coefficient renders inline in
/// `noisePsd` instead of taking a core live-out slot.
pub fn coeffNeg(self: *Lower, v: Mir.Value) Oom!Mir.Value {
    if (self.mir.valueDef(self.mir.resolveAlias(v)) == .float_const)
        return self.mir.addFloatConst(self.arena, -self.mir.valueDef(self.mir.resolveAlias(v)).float_const);
    return self.emit(.fneg, &.{v});
}

/// `a · b`, with the identity folded away. The derivative of `c * n` is
/// `c * 1`, and emitting that multiply would hide the constant from
/// `psdConst`.
fn coeffMul(self: *Lower, a: Mir.Value, b: Mir.Value) Oom!Mir.Value {
    if (a == .f_one) return b;
    if (b == .f_one) return a;
    return self.emit(.fmul, &.{ a, b });
}

/// Returns the coefficient of generator `n` in contribution value `v`, emitting the
/// few arithmetic nodes it needs over values the MIR already holds (no re-lowering,
/// so no side effect repeats).
pub fn noiseCoeff(self: *Lower, v: Mir.Value, n: Mir.Value) Oom!Coeff {
    const gen = self.mir.resolveAlias(n);
    var reach = try reachOf(self, gen, v);
    defer reach.deinit(self.arena);
    return coeffAt(self, v, gen, &reach, 0, null);
}

/// The Values of `v`'s cone whose operands, along the edges `coeffAt` follows,
/// lead to `gen`: off this set the walk answers `.absent` without descending, so
/// its cost is the generator-bearing paths and not every path of the DAG. An
/// unsealed phi (no operands yet) is kept in, since what it will carry is
/// unknown. Indexed by `@backingInt(value)`. O(cone) per fixpoint pass, not
/// O(values): a module of n noisy `<+` would otherwise lower in O(n²).
fn reachOf(self: *Lower, gen: Mir.Value, v: Mir.Value) Oom!std.bit_set.Dynamic {
    const mir = self.mir;
    const n = Mir.Value.first_dynamic + mir.defs.len;
    var reach = try std.bit_set.Dynamic.initEmpty(self.arena, n);
    errdefer reach.deinit(self.arena);
    reach.set(@backingInt(gen));
    // The cone: every instruction result `v`'s operand edges lead to, phis'
    // back edges included, which is all `coeffAt` can visit.
    var seen = try std.bit_set.Dynamic.initEmpty(self.arena, n);
    defer seen.deinit(self.arena);
    var cone: std.ArrayList(Mir.Value) = .empty;
    defer cone.deinit(self.arena);
    var stack: std.ArrayList(Mir.Value) = .empty;
    defer stack.deinit(self.arena);
    try stack.append(self.arena, mir.resolveAlias(v));
    while (stack.pop()) |x| {
        if (seen.isSet(@backingInt(x))) continue;
        seen.set(@backingInt(x));
        const inst = switch (mir.valueDef(x)) {
            .inst_result => |i| i,
            .undef, .float_const, .int_const, .str_const, .param_ref, .block_param => continue,
        };
        try cone.append(self.arena, x);
        switch (mir.instData(inst)) {
            .unary => |u| try stack.append(self.arena, mir.resolveAlias(u.operand)),
            .binary => |bn| try stack.appendSlice(self.arena, &.{ mir.resolveAlias(bn.lhs), mir.resolveAlias(bn.rhs) }),
            .ternary => |t| try stack.appendSlice(self.arena, &.{ mir.resolveAlias(t.then_val), mir.resolveAlias(t.else_val) }),
            .phi => |p| for (0..p.count) |k| try stack.append(self.arena, mir.resolveAlias(mir.phiPair(inst, @intCast(k)).value)),
            .call => |c| for (c.args) |arg| try stack.append(self.arena, mir.resolveAlias(arg)),
            .anew, .branch, .jump => {},
            .load => |l| try stack.appendSlice(self.arena, &.{ mir.resolveAlias(l.arr), mir.resolveAlias(l.index) }),
            .store => |st| try stack.appendSlice(self.arena, &.{ mir.resolveAlias(st.arr), mir.resolveAlias(st.index), mir.resolveAlias(st.value) }),
        }
    }
    // Operands precede their users except along a phi's back edge or an
    // alias onto a later value; those need another pass.
    std.mem.sortUnstable(Mir.Value, cone.items, {}, struct {
        fn lt(_: void, l: Mir.Value, r: Mir.Value) bool {
            return @backingInt(l) < @backingInt(r);
        }
    }.lt);
    var changed = true;
    var passes: usize = 0;
    while (changed) : (passes += 1) {
        // Each pass that continues sets a bit, and the cone has that many.
        std.debug.assert(passes <= cone.items.len);
        changed = false;
        for (cone.items) |x| {
            if (reach.isSet(@backingInt(x))) continue;
            if (operandReaches(mir, mir.valueDef(x).inst_result, &reach)) {
                reach.set(@backingInt(x));
                changed = true;
            }
        }
    }
    return reach;
}

fn reached(mir: *const Mir, reach: *const std.bit_set.Dynamic, v: Mir.Value) bool {
    return reach.isSet(@backingInt(mir.resolveAlias(v)));
}

fn operandReaches(mir: *const Mir, inst: Mir.Inst, reach: *const std.bit_set.Dynamic) bool {
    return switch (mir.instData(inst)) {
        .unary => |u| reached(mir, reach, u.operand),
        .binary => |b| reached(mir, reach, b.lhs) or reached(mir, reach, b.rhs),
        // `coeffAt` differentiates the arms; the condition selects, it is not scaled.
        .ternary => |t| reached(mir, reach, t.then_val) or reached(mir, reach, t.else_val),
        .phi => |p| {
            if (p.count == 0) return true;
            for (0..p.count) |k| if (reached(mir, reach, mir.phiPair(inst, @intCast(k)).value)) return true;
            return false;
        },
        .call => |c| {
            for (c.args) |arg| if (reached(mir, reach, arg)) return true;
            return false;
        },
        .anew, .branch, .jump => false,
        .load => |l| reached(mir, reach, l.arr) or reached(mir, reach, l.index),
        .store => |st| reached(mir, reach, st.arr) or reached(mir, reach, st.index) or reached(mir, reach, st.value),
    };
}

/// The phis the walk is inside, innermost first. A loop-header phi reaches
/// itself again through its back edge; meeting one already on the path is a
/// generator fed back into itself, which no single factor describes.
const PhiPath = struct { inst: Mir.Inst, up: ?*const PhiPath };

fn coeffAt(self: *Lower, v: Mir.Value, gen: Mir.Value, reach: *const std.bit_set.Dynamic, depth: u16, path: ?*const PhiPath) Oom!Coeff {
    if (depth == 64) return .nonlinear;
    const value = self.mir.resolveAlias(v);
    if (value == gen) return .{ .value = .f_one };
    if (!reach.isSet(@backingInt(value))) return .absent;
    const inst = switch (self.mir.valueDef(value)) {
        .inst_result => |i| i,
        // A constant, a parameter or a probe cannot contain the generator.
        .undef, .float_const, .int_const, .str_const, .param_ref, .block_param => return .absent,
    };
    switch (self.mir.instData(inst)) {
        .unary => |u| {
            const d = try coeffAt(self, u.operand, gen, reach, depth + 1, path);
            if (d == .absent) return .absent;
            if (u.op != .fneg or d == .nonlinear) return .nonlinear;
            return .{ .value = try coeffNeg(self, d.value) };
        },
        .binary => |b| {
            const da = try coeffAt(self, b.lhs, gen, reach, depth + 1, path);
            const db = try coeffAt(self, b.rhs, gen, reach, depth + 1, path);
            if (da == .absent and db == .absent) return .absent;
            if (da == .nonlinear or db == .nonlinear) return .nonlinear;
            switch (b.op) {
                .fadd, .fsub => {
                    // A side that does not mention the generator contributes
                    // the zero this skips rather than emits.
                    if (da == .absent) return .{
                        .value = if (b.op == .fadd) db.value else try coeffNeg(self, db.value),
                    };
                    if (db == .absent) return .{ .value = da.value };
                    return .{ .value = try self.emit(if (b.op == .fadd) .fadd else .fsub, &.{ da.value, db.value }) };
                },
                // The generator on both sides of a multiply is the generator
                // squared, which has no coefficient.
                .fmul => {
                    if (da != .absent and db != .absent) return .nonlinear;
                    if (da == .absent) return .{ .value = try coeffMul(self, b.lhs, db.value) };
                    return .{ .value = try coeffMul(self, da.value, b.rhs) };
                },
                // Dividing BY the generator is nonlinear for the same reason.
                .fdiv => {
                    if (db != .absent) return .nonlinear;
                    return .{ .value = try self.emit(.fdiv, &.{ da.value, b.rhs }) };
                },
                // The rest of the two-operand ops: a generator under any of them
                // is no longer an amplitude scaled by a factor (an integer op
                // would have to round it, a comparison or a min/max selects on
                // it, pow/hypot/atan2/fmod are not linear in it).
                .fmod,
                .iadd,
                .isub,
                .imul,
                .idiv,
                .imod,
                .flt,
                .fgt,
                .fle,
                .fge,
                .feq,
                .fne,
                .ilt,
                .igt,
                .ile,
                .ige,
                .ieq,
                .ine,
                .logand,
                .logor,
                .bitand,
                .bitor,
                .bitxor,
                .bitxnor,
                .shl,
                .shr,
                .pow,
                .hypot,
                .fmin,
                .fmax,
                .imin,
                .imax,
                .ipow,
                .atan2,
                => return .nonlinear,
                // `instData` decodes `.binary` only for `opClass(op) == .binary`.
                .fneg,
                .ineg,
                .lognot,
                .bitnot,
                .sqrt,
                .exp,
                .expm1,
                .ln,
                .ln1p,
                .log10,
                .floor,
                .ceil,
                .fabs,
                .iabs,
                .sin,
                .cos,
                .tan,
                .asin,
                .acos,
                .atan,
                .sinh,
                .cosh,
                .tanh,
                .asinh,
                .acosh,
                .atanh,
                .fi_cast,
                .if_cast,
                .opt_barrier,
                .dstop,
                .path_prev,
                .path_acc,
                .select,
                .phi,
                .branch,
                .jump,
                .call,
                .anew,
                .fload,
                .iload,
                .store,
                => unreachable,
            }
        },
        // §4.2.12 `?:`: either arm may carry the generator, and which arm runs
        // is a solve-time question, so the coefficient is the same conditional.
        .ternary => |t| {
            const dy = try coeffAt(self, t.then_val, gen, reach, depth + 1, path);
            const dn = try coeffAt(self, t.else_val, gen, reach, depth + 1, path);
            if (dy == .absent and dn == .absent) return .absent;
            if (dy == .nonlinear or dn == .nonlinear) return .nonlinear;
            return .{ .value = try self.emit(.select, &.{
                t.cond,
                if (dy == .absent) .f_zero else dy.value,
                if (dn == .absent) .f_zero else dn.value,
            }) };
        },
        // §5.8 `if` and §4.2.12 `?:` both arrive here as a CFG diamond (ifconv
        // makes the `.select` later): the coefficient of a phi is the phi of the
        // incoming coefficients.
        .phi => |p| {
            // An unsealed loop header's phi has no operands yet, so nothing is
            // known about what it carries.
            if (p.count == 0) return .nonlinear;
            var up = path;
            while (up) |f| : (up = f.up) if (f.inst == inst) return .nonlinear;
            const here: PhiPath = .{ .inst = inst, .up = path };
            const coeffs = try self.arena.alloc(Mir.PhiPair, p.count);
            var any = false;
            var same = true;
            for (coeffs, 0..) |*c, k| {
                const pair = self.mir.phiPair(inst, @intCast(k));
                const before = self.mir.blockLast(self.cur);
                const d = try coeffAt(self, pair.value, gen, reach, depth + 1, &here);
                // What that walk emitted (`x/r` has coefficient `1/r`) landed in
                // `self.cur`, after the join, where the edge from `pair.block`
                // cannot carry it. Its operands are sub-terms of `pair.value`,
                // so they exist at the end of that block: compute it there.
                if (!self.mir.moveTailBefore(self.cur, before, pair.block)) return .nonlinear;
                const cv: Mir.Value = switch (d) {
                    .absent => .f_zero,
                    .nonlinear => return .nonlinear,
                    .value => |x| blk: {
                        any = true;
                        break :blk x;
                    },
                };
                c.* = .{ .block = pair.block, .value = cv };
                if (cv != coeffs[0].value) same = false;
            }
            if (!any) return .absent;
            // One value on every edge is available at the join already.
            if (same) return .{ .value = coeffs[0].value };
            return .{ .value = try self.mir.emitPhi(self.arena, self.mir.instBlock(inst), coeffs) };
        },
        // A call's arguments are reachable, so whether the generator occurs is
        // answerable even though the derivative is not.
        .call => |c| {
            for (c.args) |arg| if (try coeffAt(self, arg, gen, reach, depth + 1, path) != .absent) return .nonlinear;
            return .absent;
        },
        // Terminators define no value, so no Value resolves to one.
        .branch, .jump => unreachable,
        // §3.2.2 a generator stored into an array is no longer an amplitude
        // scaled by a factor of this expression: like a call's argument, it
        // can only be detected, not differentiated through the storage.
        .anew => return .absent,
        .load => |l| return if (try coeffAt(self, l.arr, gen, reach, depth + 1, path) == .absent and
            try coeffAt(self, l.index, gen, reach, depth + 1, path) == .absent) .absent else .nonlinear,
        .store => |st| return if (try coeffAt(self, st.arr, gen, reach, depth + 1, path) == .absent and
            try coeffAt(self, st.index, gen, reach, depth + 1, path) == .absent and
            try coeffAt(self, st.value, gen, reach, depth + 1, path) == .absent) .absent else .nonlinear,
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
    });
}

test "§4.6 small-signal sources: arguments and labels" {
    try Lower.expectBodies(&.{
        // §4.6.4.1 `white_noise(pwr[, name])`: the power is a scalar. Only
        // `noise_table`'s input (§4.6.4.3) is a vector.
        .{ .src = "analog I(p) <+ white_noise('{1.0, 2.0});", .code = .E0509 },
        .{ .src = "analog I(p) <+ white_noise(1e-20);", .code = null },
        // Syntax 4-4: the optional last argument is a string label.
        .{ .src = "analog I(p) <+ white_noise(1e-20, 3);", .code = .E0573 },
        // §4.6.4.2: 1/f^exp has no default exponent.
        .{ .src = "analog I(p) <+ flicker_noise(1e-20);", .code = .E0522 },
        // A.8.2 puts the quotation marks inside `ac_stim`'s production.
        .{ .src = "analog I(p) <+ ac_stim(1);", .code = .E0521 },
    });
}
