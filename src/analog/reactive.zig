//! §5.6.1.2 the reactive split: a `<+` right-hand side in, its resistive
//! value, its reactive value (the charge `ddt` differentiates) and one
//! charge site per reactive term out. Also the `vera_lte` verdict of each
//! site and the operator rows (`stampOpRow`) analog operators stamp.
//!
//! Cites: §2.9, §4.5.2, §4.5.3, §4.5.14, §5.6.1.2, §5.6.1.3, A.8.2.
//!
//! Contents:
//! - `pub const Split = struct`
//! - `pub fn splitContribution(self: *Lower, rhs: Ast.ExprId) Oom!Split`
//! - `pub fn addSite(self: *Lower, idx: u32, ps: PendingSite, neg: bool) Oom!void`
//! - `pub fn opSiteLte(self: *Lower, e: Ast.ExprId) Oom!bool`
//! - `pub fn stampOpRow(self: *Lower, tok: u32, s: u32, f: Mir.Value, q: Mir.Value, q_neg: bool, lte: bool) Oom!void`
//! - `pub fn lteValue(self: *Lower, a: Ast.LteAttr) Oom!bool`
//! - `pub fn coeffIsConst(self: *const Lower, v: Mir.Value) bool`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_node = @import("node.zig");
const lower_accum = @import("accum.zig");
const Oom = Lower.Oom;
const ground = Lower.ground;

/// A right-hand side split into its resistive and reactive halves (§5.6.1.2).
pub const Split = struct {
    resist: ?Mir.Value,
    react: ?Mir.Value,
    /// §5.6.1.2 the charge sites `react` sums, in term order (`ChargeSite`).
    sites: std.ArrayList(PendingSite) = .empty,
};

/// One reactive term of a right-hand side, before `lowerContribute` knows its
/// accumulator: the charge, its sign in the sum, and its `vera_lte` verdict.
const PendingSite = struct { charge: Mir.Value, negate: bool, lte: bool, tok: u32 };

/// One reactive term with its multiplicative spine split apart: `b` is the
/// `ddt` operand, `coeff` the accumulated product of everything that rode
/// outside the ddt (null = 1), `coeff_nonconst` whether any factor depends
/// on an unknown (literals/params have zero gradient and need no site).
const ReactiveTerm = struct { b: Mir.Value, coeff: ?Mir.Value = null, coeff_nonconst: bool = false };

/// Separates the ddt terms (§4.5.3) of a right-hand side into the reactive
/// part (LRM §5.6.1.2).
///
/// The split is on the additive terms: a term with no `ddt` is resistive; a term
/// with one is reactive, and its value is the term with the `ddt` stripped
/// (`C*ddt(V)` → `C*V`), the charge codegen differentiates. That is exact when
/// `ddt` appears once on a multiplicative spine (`linearDdt`). Any other term
/// (`ddt` inside a call, two `ddt`s multiplied) is resistive: each of its `ddt`s
/// is §4.5.2's new unknown with its own row and charge site (`opDdt`).
pub fn splitContribution(self: *Lower, rhs: Ast.ExprId) Oom!Split {
    assert(rhs == .none or self.exprValid(rhs));
    assert(self.contrib_target != null); // only a `<+` right-hand side is split
    var out: Split = .{ .resist = null, .react = null };
    try splitTerm(self, rhs, false, &out);
    return out;
}

/// Record reactive term `ps` of the statement accumulating into contribution
/// `idx` as a charge site of its own (`Lower.ChargeSite`). Its SSA place is
/// seeded zero in the entry block, so a path that does not execute the site
/// — or that §5.6.1.3 discards (`discardOpposite`) — reads a zero charge.
pub fn addSite(self: *Lower, idx: u32, ps: PendingSite, neg: bool) Oom!void {
    assert(idx < self.out.contributions.items.len);
    assert(self.site_places.items.len == self.out.charge_sites.items.len);
    const p = self.builder.newPlace();
    try self.builder.writeVariable(p, .entry, .f_zero);
    try self.builder.writeVariable(p, self.cur, ps.charge);
    try self.site_places.append(self.arena, p);
    try self.out.charge_sites.append(self.arena, .{
        .contrib = idx,
        .sign = if (ps.negate != neg) -1.0 else 1.0,
        .lte = ps.lte,
        .tok = ps.tok,
    });
    assert(self.site_places.items.len == self.out.charge_sites.items.len);
}

/// `siteLte` for an operator call `e` that is its own site: its own suffix,
/// then the nearest enclosing statement's, then yes.
pub fn opSiteLte(self: *Lower, e: Ast.ExprId) Oom!bool {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.tag(e) == .filter_call);
    if (self.file.exprLte(e, .vera_lte)) |a| return lteValue(self, a);
    return stackLte(self);
}

/// Writes the row of an operator unknown `s` (`lower_node.opStateNode`): a flow
/// contribution on (s, ground) with resistive half `f` and one charge site `q`,
/// stamped with sign -1 when `q_neg`. The resistive half starts as V(s) and
/// the site ASSIGNS it, so a card-conditional arm that is off leaves the row
/// `s = 0`, not an empty one that makes the system singular.
pub fn stampOpRow(self: *Lower, tok: u32, s: u32, f: Mir.Value, q: Mir.Value, q_neg: bool, lte: bool) Oom!void {
    assert(self.valueValid(f));
    assert(self.valueValid(q));
    assert(self.blockValid(self.cur));
    const idx = try lower_accum.contribIndex(self, .{ .access = .flow, .hi = s, .lo = ground }, tok);
    const acc = self.accum.items[idx];
    try self.builder.writeVariable(acc.resist, .entry, try lower_node.probe(self, s));
    try self.builder.writeVariable(acc.wrote, .entry, .f_one);
    try self.builder.writeVariable(acc.resist, self.cur, f);
    try self.builder.writeVariable(acc.react, self.cur, if (q_neg) try self.emit(.fneg, &.{q}) else q);
    try addSite(self, idx, .{ .charge = q, .negate = q_neg, .lte = lte, .tok = tok }, false);
}

/// A `vera_lte` value: §2.9's default 1 when absent, otherwise a constant
/// expression that must fold WITHOUT the model card — the mask is a
/// compile-time table (`contract.QSites`), so a parameter cannot decide it.
/// E0523 otherwise, and the site keeps the default.
pub fn lteValue(self: *Lower, a: Ast.LteAttr) Oom!bool {
    assert(a.value == .none or self.exprValid(a.value));
    assert(a.main_tok < self.tok_starts.len or self.tok_starts.len == 0);
    if (a.value == .none) return true;
    const c = lower_constfold.foldExpr(self, a.value, false) orelse {
        try self.err(a.main_tok, .E0523, "", .{});
        return true;
    };
    return c.isTrue();
}

/// Whether `v` has zero gradient: a literal, `undef` or a parameter.
pub fn coeffIsConst(self: *const Lower, v: Mir.Value) bool {
    assert(self.valueValid(v));
    return switch (self.mir.valueKind(v)) {
        .float_const, .int_const, .undef, .param_ref => true,
        .str_const, .block_param, .inst_result => false,
    };
}

// ---- private ----

fn splitTerm(self: *Lower, e: Ast.ExprId, negate: bool, out: *Split) Oom!void {
    assert(e == .none or self.exprValid(e));
    assert(out.sites.items.len == 0 or out.react != null); // a site is a term of `react`
    if (e == .none) return;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .binary => switch (ex.binOp(e)) {
            .add => {
                try splitTerm(self, ex.lhs(e), negate, out);
                try splitTerm(self, ex.rhs(e), negate, out);
                return;
            },
            .sub => {
                try splitTerm(self, ex.lhs(e), negate, out);
                try splitTerm(self, ex.rhs(e), !negate, out);
                return;
            },
            else => {}, // else: not a sum, so one term, lowered whole below
        },
        .unary => switch (ex.unOp(e)) {
            .plus => return splitTerm(self, ex.lhs(e), negate, out),
            .minus => return splitTerm(self, ex.lhs(e), !negate, out),
            else => {}, // else: not a sign, so one term, lowered whole below
        },
        else => {}, // else: not a sum or a sign, so one term, lowered whole below
    }

    if (linearDdt(self, e)) {
        const t = try lowerReactive(self, e) orelse return;
        const q = try finishReactive(self, t);
        try accumulate(self, &out.react, q, negate);
        const d = firstDdt(self, e);
        try out.sites.append(self.arena, .{
            .charge = q,
            .negate = negate,
            .lte = try siteLte(self, e),
            .tok = if (d != .none) self.file.exprs.mainTok(d) else Mir.no_tok,
        });
    } else {
        const v = try self.toReal(try lower_expr.lowerExpr(self, e));
        try accumulate(self, &out.resist, v, negate);
    }
}

fn accumulate(self: *Lower, slot: *?Mir.Value, v: Mir.Value, negate: bool) Oom!void {
    assert(self.valueValid(v));
    assert(self.blockValid(self.cur));
    if (slot.*) |old| {
        slot.* = try self.emit(if (negate) .fsub else .fadd, &.{ old, v });
    } else {
        slot.* = if (negate) try self.emit(.fneg, &.{v}) else v;
    }
}

/// The first `ddt` call in `e`, or `.none`.
fn firstDdt(self: *const Lower, e: Ast.ExprId) Ast.ExprId {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.len() != 0);
    if (e == .none) return .none;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .filter_call and self.file.strings.eql(ex.strOf(e), "ddt")) return e;
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| {
        const d = firstDdt(self, c);
        if (d != .none) return d;
    }
    return .none;
}

/// Does the charge site `e` join the host's truncation check? The innermost
/// `vera_lte` wins: one suffixed to a `ddt` in the term (`ddt (* vera_lte = 0
/// *) (q)`), then the nearest enclosing statement's (`lte_stack`), then the
/// default, yes. A term holding two `ddt`s under one factor is one site, and
/// the first suffixed one decides it.
fn siteLte(self: *Lower, e: Ast.ExprId) Oom!bool {
    assert(e == .none or self.exprValid(e));
    assert(self.lte_stack.items.len <= self.stmtCount());
    if (lteSuffix(self, e)) |a| return lteValue(self, a);
    return stackLte(self);
}

fn stackLte(self: *const Lower) bool {
    assert(self.lte_stack.items.len <= self.stmtCount()); // one entry per enclosing statement
    assert(self.interp_stack.items.len <= self.stmtCount());
    return self.lte_stack.last() orelse true;
}

fn lteSuffix(self: *const Lower, e: Ast.ExprId) ?Ast.LteAttr {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.len() != 0);
    if (e == .none) return null;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .filter_call and self.file.strings.eql(ex.strOf(e), "ddt")) {
        if (self.file.exprLte(e, .vera_lte)) |a| return a;
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (lteSuffix(self, c)) |a| return a;
    return null;
}

/// Does this subtree contain a `ddt` (§4.5.3)? Every child edge is searched
/// (`ExprStore.children`), assignment-pattern elements included.
fn containsDdt(self: *const Lower, e: Ast.ExprId) bool {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.len() != 0);
    return firstDdt(self, e) != .none;
}

/// Is `e` a ddt on the linear spine `lowerReactive` strips: one `ddt` under
/// signs, factors and divisors free of `ddt`, or a sum of such terms?
fn linearDdt(self: *const Lower, e: Ast.ExprId) bool {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.len() != 0);
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .filter_call => self.file.strings.eql(ex.strOf(e), "ddt"),
        .unary => (ex.unOp(e) == .plus or ex.unOp(e) == .minus) and linearDdt(self, ex.lhs(e)),
        .binary => switch (ex.binOp(e)) {
            .mul => if (containsDdt(self, ex.lhs(e)))
                !containsDdt(self, ex.rhs(e)) and linearDdt(self, ex.lhs(e))
            else
                linearDdt(self, ex.rhs(e)),
            .div => !containsDdt(self, ex.rhs(e)) and linearDdt(self, ex.lhs(e)),
            .add, .sub => linearDdt(self, ex.lhs(e)) and linearDdt(self, ex.rhs(e)),
            .mod, .pow, .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or, .bit_and, .bit_or, .bit_xor, .bit_xnor, .shl, .shr, .ashl, .ashr => false,
        },
        else => false, // else: no other node keeps a ddt on a linear spine
    };
}

/// LRM semantics of `A*ddt(B)` is A·dB/dt, the capacitance form: the stamped
/// current carries no B·dA/dt (the plain product measured wrong on MESA Cgg).
/// A non-constant A becomes a path-integrated charge, ngspice's own
/// construction (NIintegrate on the increment, mesaload.c:341-344):
///
///     q = pq + A·(B − pb)      pb = B at last accept, pq = Σ committed A·ΔB
///
/// The base (pb, pq) is FIXED across one Newton attempt and advances only at
/// `stateCtl(.commit)` (operating-point exit, transient accepted step), so
///  - the committed charge increment is A·ΔB: capacitance-form physics;
///  - at any committed point ΔB = 0, so the C-plane is exactly A·∂B/∂x (AC);
///  - within a step the residual is one smooth function whose AD Jacobian
///    carries dA only as (dA/dx)·ΔB, the Newton term that vanishes as dt→0.
///    Deleting the dA term instead gives a quasi-Newton whose error gain grows
///    with 1/dt and wedges the timestep.
fn finishReactive(self: *Lower, t: ReactiveTerm) Oom!Mir.Value {
    assert(self.blockValid(self.cur));
    assert(self.valueValid(t.b));
    const c = t.coeff orelse return t.b; // plain ddt(B): q = B, exact
    // Constant/param coefficient: dA ≡ 0, the plain product IS the
    // capacitance form (and pq/pb with zero init would reproduce it).
    if (!t.coeff_nonconst) return try self.emit(.fmul, &.{ c, t.b });
    const pb = try self.emit(.path_prev, &.{t.b});
    const d = try self.emit(.fmul, &.{ c, try self.emit(.fsub, &.{ t.b, pb }) });
    return try self.emit(.fadd, &.{ try self.emit(.path_acc, &.{d}), d });
}

fn mulCoeff(self: *Lower, t: *ReactiveTerm, c: Mir.Value, op: Mir.Opcode) Oom!void {
    assert(self.valueValid(c));
    assert(self.blockValid(self.cur));
    t.coeff = if (t.coeff) |old|
        try self.emit(op, &.{ old, c })
    else if (op == .fdiv)
        try self.emit(.fdiv, &.{ try self.mir.addFloatConst(self.arena, 1.0), c })
    else
        c;
    t.coeff_nonconst = t.coeff_nonconst or !coeffIsConst(self, c);
}

/// The charge/flux of a reactive term: strip exactly one `ddt` from a
/// multiplicative spine (§5.6.1.2), collecting the spine's coefficients
/// LIVE (no gradient suppression — `finishReactive` decides the form).
/// Asserts `linearDdt(e)`.
fn lowerReactive(self: *Lower, e: Ast.ExprId) Oom!?ReactiveTerm {
    assert(e == .none or self.exprValid(e));
    assert(self.blockValid(self.cur));
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .filter_call => {
            if (self.file.strings.eql(ex.strOf(e), "ddt")) {
                if (!try lower_analog_op.checkOperatorPlace(self, e, "ddt")) return null;
                const args = ex.args(e);
                // A.8.2 gives a filter no `analog_expression_or_null` form, so
                // an OMITTED slot (`ddt(,1.0)`) is as wrong as no argument at
                // all. `lowerFilter` already rejects it on the non-reactive
                // path; this reactive spine bypasses that call and has to
                // agree (§4.5.14).
                if (args.len == 0 or args[0] == .none) {
                    try self.err(self.file.exprs.mainTok(e), .E0502, "", .{});
                    return null;
                }
                // args[1] (abstol/nature, §4.5.3) only affects tolerance, but
                // it still has to be LEGAL, on the same grounds as the E0502
                // agreement above: this spine bypasses `lowerFilter`.
                if (args.len > 1) _ = try lower_analog_op.lowerAbstolArg(self, "ddt", args[1]) orelse return null;
                return .{ .b = try self.toReal(try lower_expr.lowerExpr(self, args[0])) };
            }
        },
        .unary => switch (ex.unOp(e)) {
            .plus => return lowerReactive(self, ex.lhs(e)),
            .minus => {
                var t = try lowerReactive(self, ex.lhs(e)) orelse return null;
                // Sign rides the coefficient (constness unchanged: negation
                // adds no unknown dependence).
                t.coeff = if (t.coeff) |old| try self.emit(.fneg, &.{old}) else try self.mir.addFloatConst(self.arena, -1.0);
                return t;
            },
            else => {}, // else: no other unary operator keeps a ddt on a linear spine
        },
        .binary => switch (ex.binOp(e)) {
            .mul => {
                if (containsDdt(self, ex.lhs(e))) {
                    var t = try lowerReactive(self, ex.lhs(e)) orelse return null;
                    try mulCoeff(self, &t, try self.toReal(try lower_expr.lowerExpr(self, ex.rhs(e))), .fmul);
                    return t;
                }
                const c = try self.toReal(try lower_expr.lowerExpr(self, ex.lhs(e)));
                var t = try lowerReactive(self, ex.rhs(e)) orelse return null;
                try mulCoeff(self, &t, c, .fmul);
                return t;
            },
            .div => {
                var t = try lowerReactive(self, ex.lhs(e)) orelse return null;
                try mulCoeff(self, &t, try self.toReal(try lower_expr.lowerExpr(self, ex.rhs(e))), .fdiv);
                return t;
            },
            // A sum of reactive terms under a factor, `c*(ddt(a) + ddt(b))`.
            // §4.5.3's ddt is a time derivative, so it is linear: the charge
            // of the sum is the sum of the charges, and the factor outside
            // scales that as it scales one. Each side is finished to its own
            // charge first, so a side with its own non-constant factor keeps
            // its capacitance form. A side WITHOUT a ddt is a resistive term
            // the factor would also have to scale, which this spine cannot
            // return, so `linearDdt` sends that term down the resistive path.
            .add, .sub => {
                const l = try lowerReactive(self, ex.lhs(e)) orelse return null;
                const lq = try finishReactive(self, l);
                const r = try lowerReactive(self, ex.rhs(e)) orelse return null;
                const rq = try finishReactive(self, r);
                return .{ .b = try self.emit(if (ex.binOp(e) == .add) .fadd else .fsub, &.{ lq, rq }) };
            },
            // No other operator keeps a ddt on a linear spine.
            .mod,
            .pow,
            .eq,
            .neq,
            .case_eq,
            .case_neq,
            .lt,
            .le,
            .gt,
            .ge,
            .logical_and,
            .logical_or,
            .bit_and,
            .bit_or,
            .bit_xor,
            .bit_xnor,
            .shl,
            .shr,
            .ashl,
            .ashr,
            => {},
        },
        else => {}, // else: no other node keeps a ddt on a linear spine
    }
    unreachable; // `linearDdt` admitted only the spine above
}
