//! Value and instruction rendering: one MIR value or instruction in, its Zig
//! expression text out, with the §4.2.1.1/§4.2.1.2 integer/real conversions
//! explicit. LRM clauses cited: §2.7, §2.9, §3.2, §3.2.1, §3.2.2, §4.2.1, §4.2.4, §4.2.11,
//! §4.3.1, §4.3.2, §4.5, §9.4, §9.13, §9.21.
//!
//! Contents:
//! - `pub const Subst = struct`
//! - `pub fn renderToArena(self: *Gen, v: Mir.Value, want: VTy) Error![]const u8`
//! - `pub fn renderVal(self: *Gen, v0: Mir.Value, want: VTy) Error!void`
//! - `pub fn renderValueRef(self: *Gen, v: Mir.Value) Error!void`
//! - `pub fn materialized(self: *const Gen, v: Mir.Value) bool`
//! - `pub fn renderInst(self: *Gen, inst: Mir.Inst) Error!void`
//! - `pub fn foldHidesSlot(self: *Gen, v0: Mir.Value, depth: u32) bool`

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_host = @import("host_expr.zig");
const gen_mask = @import("mask.zig");
const gen_file = @import("file.zig");
const gen_setup = @import("setup.zig");
const gen_cfg = @import("cfg.zig");
const gen_unit = @import("unit.zig");
const gen_unit_body = @import("unit_body.zig");
const family = @import("family.zig");
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;
const render_array = @import("render_array.zig");
const render_op = @import("render_op.zig");

/// What `renderVal` writes in place of a guarded row's restricted operand
/// (`Gen.subst`): `v` while the guard chain from `lit` holds, else `safe`.
pub const Subst = struct { v: Mir.Value, lit: u32, safe: f64 };

/// Returns `renderVal`'s text as an arena string instead of appending it to
/// `out`. Renders into `out` and rewinds, so `uses.x`/`uses.model`
/// accounting matches a direct render. For §4.5 operator inputs that must
/// appear inside a kernel call's `{s}`.
/// The result is arena-owned. Leaves `out` as it found it.
pub fn renderToArena(self: *Gen, v: Mir.Value, want: VTy) Error![]const u8 {
    const at = self.out.items.len;
    try renderVal(self, v, want);
    // A nested rewind (`renderLoad`) never reaches below where it started.
    assert(self.out.items.len >= at);
    const s = try self.arena.dupe(u8, self.out.items[at..]);
    self.out.shrinkRetainingCapacity(at);
    assert(self.out.items.len == at);
    return s;
}

/// Writes a value reference, converting per §4.2.1.1/§4.2.1.2 when `want` is
/// the other LRM type.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn renderVal(self: *Gen, v0: Mir.Value, want: VTy) Error!void {
    assert(self.an.vty.len == self.an.nv);
    const v = self.an.rv(v0);
    if (self.cur.subst) |s| if (s.v == v) return renderSubst(self, s, want);
    const def = self.mir.valueDef(v);
    if (def == .undef) {
        // Lowering starts every wide `reg` at its declaration, so no `.wide`
        // operand is undefined.
        if (want == .wide) return gen_call.abort(self, .E1020, "VerA: an undefined wide integer operand", .{});
        // ponytail: undefined operands share the slot initializer's spelling.
        try self.b("{s}", .{gen_unit_body.zeroOf(want)});
        return;
    }
    if (self.an.tyOf(v) == want) return renderValueRef(self, v);
    assert(self.an.tyOf(v) != want);
    switch (want) {
        .real => {
            if (def == .int_const) {
                try self.b("S.con({s})", .{try gen_file.fmtF64(self, @floatFromInt(def.int_const))});
                return;
            }
            try self.b("S.con(@as(f64, @floatFromInt(", .{});
            try renderValueRef(self, v);
            try self.b(")))", .{});
        },
        .int => {
            if (def == .float_const) {
                // Saturate like the runtime cast below, so folding a
                // constant cannot change what the device computes.
                const x = def.float_const;
                try self.b("{d}", .{std.math.lossyCast(i64, @round(x))});
                return;
            }
            // §2.7: a string literal used as an operand is the unsigned
            // base-256 integer its bytes spell (`$strobe("%d", "\n")` is
            // 10). Lowering converts every numeric context it can see; a
            // format operand is paired with its specifier only here.
            if (self.an.tyOf(v) == .str) return switch (def) {
                .str_const => |s| self.b("@as(i64, {d})", .{@import("kernels").fold.strToInt(s, 64)}),
                // Not a literal, so §3.3 leaves it with no numeric value.
                .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => self.b("@as(i64, 0)", .{}),
            };
            float_lanes.leadLanes(self, v); // a real→int collapse is a decision
            // Saturating (§4.2.1.1 defines only the rounding): under
            // ReleaseFast `@intFromFloat` of an out-of-range or NaN value is UB.
            try self.b("zRoundI(S, ", .{});
            try renderValueRef(self, v);
            try self.b(")", .{});
        },
        .str => try self.b("\"\"", .{}),
        // Lowering hands a wide operand only a wide value (`analog/wide.zig`).
        .wide => return gen_call.abort(self, .E1020, "VerA: a {t} value where a wide integer is wanted", .{self.an.tyOf(v)}),
    }
}

/// Writes `v` in its own type: a setup root, a core cache field, a unit-local
/// slot, `S.con(literal)`, `model.<name>`, `x[@intFromEnum(U.<node>)]`, or the
/// instruction rendered inline. Never a `v{MIR index}` name.
/// Asserts that a value's slot and cache entries are in range.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn renderValueRef(self: *Gen, v: Mir.Value) Error!void {
    assert(self.cur.plan.slot.len == self.an.nv);
    const i = @backingInt(v);
    // `setup` wrote the field when the card, instance or temperature changed.
    if (i < self.an.nv and self.cur.plan.isRoot(v)) {
        const f = try gen_setup.rootRef(self, v, false);
        return if (self.an.vty[i] == .int) self.b("{s}", .{f}) else self.b("S.con({s})", .{f});
    }
    // Hoisted: computed once by the shared core, read from its cache.
    if (i < self.an.nv and self.cur.plan.cached(v)) {
        assert(self.core.lo_idx[i] != none_u32);
        return self.b("c.f{d}", .{self.core.lo_idx[i]});
    }
    if (i < self.an.nv and self.cur.plan.slot[i] != none_u32) {
        gen_unit_body.probeUse(self, self.cur.plan.slot[i]);
        try gen_unit_body.writeSlotRef(self, i);
        return;
    }
    switch (self.mir.valueDef(v)) {
        .undef => try self.b("S.con(0.0)", .{}),
        .float_const => |x| try self.b("S.con({s})", .{try gen_file.fmtF64(self, x)}),
        .int_const => |x| try self.b("@as(i64, {d})", .{x}),
        .str_const => |s| try self.b("\"{f}\"", .{std.zig.fmtString(s)}),
        .param_ref => |p| {
            self.cur.uses.model = true;
            switch (Analysis.tyOfParam(self.lowered.params.items[p].ty)) {
                .real => try self.b("S.con(model.{s})", .{self.names.p_names[p]}),
                // The field may be narrower than the i64 the bodies compute in.
                .int => try self.b("@as(i64, model.{s})", .{self.names.p_names[p]}),
                .str => try self.b("model.{s}", .{self.names.p_names[p]}),
                .wide => unreachable, // `tyOfParam` types no parameter wide
            }
        },
        .block_param => |u| {
            assert(u < self.names.n_u);
            self.cur.uses.x = true;
            // Every probe read needs its lane; `deriv_reads` is this sound
            // superset.
            gen_mask.set(self.jac.deriv_reads, u);
            try self.b("x[@intFromEnum(U.{s})]", .{self.names.u_names[u]});
        },
        .inst_result => |inst| try renderInst(self, inst),
    }
}

/// Returns whether `v` renders as a name (slot, cache field or setup field)
/// rather than an expression. The stop condition `eagerSafe`, `maskCmp` and
/// `foldHidesSlot` share.
pub fn materialized(self: *const Gen, v: Mir.Value) bool {
    assert(self.cur.plan.slot.len == self.an.nv);
    const i = @backingInt(v);
    return i < self.an.nv and
        (self.cur.plan.isRoot(v) or self.cur.plan.cached(v) or self.cur.plan.slot[i] != none_u32);
}

/// Writes instruction `inst` as an expression.
/// Asserts that `inst` is a row of `mir`.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn renderInst(self: *Gen, inst: Mir.Inst) Error!void {
    assert(@backingInt(inst) < self.mir.insts.len);
    const row = self.mir.instRow(inst);
    const op = row.op;
    if (op == .call) return gen_call.emitCall(self, inst);
    if (op == .phi) return self.b("S.con(0.0)", .{}); // materialised as a var
    if (op == .fload or op == .iload) return render_array.renderLoad(self, inst);

    // A derivative-free subtree is one `S.con` over plain f64 arithmetic:
    // each S op it replaces would carry zero lanes `.strict` cannot fold.
    // `f64Const` succeeds only on literals, parameters and arithmetic.
    const res = self.mir.instResult(inst);
    if (res != .undef and self.an.vty[@backingInt(res)] == .real and self.an.dFree(res)) {
        // A value the analysis folds from literals alone (never through a
        // parameter) is its literal: `pow(0.5178…, -2)` is no `zPowK` call.
        // The planner made it a slot-free leaf (`UnitPlan.literal`).
        if (self.cur.plan.literal(res)) return self.b("S.con({s})", .{try gen_file.fmtF64(self, self.an.foldConst(res, false).?)});
        if (try gen_host.f64Const(self, res, 0, true)) |s| return self.b("S.con({s})", .{s});
    }

    // Only unary, binary and select rows get here; a select's arms sit in
    // `extra` (`Mir.InstRow`), and any other row has no third operand.
    const a: Mir.Value = @fromBackingInt(@intCast(row.a));
    const arms = if (op == .select) self.mir.instData(inst).ternary else null;
    const b2: Mir.Value = if (arms) |t| t.then_val else @fromBackingInt(@intCast(row.b));
    const c: Mir.Value = if (arms) |t| t.else_val else .undef;

    // §4.2.12 the conditional stays lazy by default: the prover treats the
    // condition as a guard, so `x > 0 ? ln(x) : 0` is accepted, and running
    // ln(x) with x <= 0 is UB under `.optimized`.
    //
    // In a `.strict` unit a real select whose inline arms are total
    // (`eagerSafe`) and cheap (`eagerCostly`) runs both arms and picks with
    // `sel`: a dead arm's NaN/inf is discarded, the branch is gone, and a
    // lane-parallel S gets a per-lane pick. Costly arms on a condition that
    // varies with the solve run both on a GPU target only (#81: `zSpec`),
    // where a branch costs the register allocator more than the arm.
    const res_ty = self.an.vty[@backingInt(res)];
    assert(op != .call);
    assert(op != .phi);
    if (op == .select) {
        const want = res_ty;
        if (want == .real and self.float.strict and
            float_lanes.eagerSafe(self, b2, 0) and float_lanes.eagerSafe(self, c, 0))
        {
            if (!float_lanes.eagerCostly(self, b2, 0) and !float_lanes.eagerCostly(self, c, 0))
                return renderSelEager(self, a, b2, c, res);
            if (float_lanes.perPoint(self, a)) {
                try self.b("(if (comptime zSpec) ", .{});
                try renderSelEager(self, a, b2, c, res);
                try self.b(" else ", .{});
                try renderSelLazy(self, a, b2, c, want, res);
                return self.b(")", .{});
            }
        }
        return renderSelLazy(self, a, b2, c, want, res);
    }
    // §4.3.2 a domain-restricted row `ifconv`'s `.speculate` moved out of its
    // arm runs on its domain's safe argument while its guard is false, so it
    // neither reports nor leaves the domain where the source never ran it.
    const saved = self.cur.subst;
    defer self.cur.subst = saved;
    if (self.mir.guardOf(inst)) |lit| {
        const dom = Mir.opcode.get(op).domain;
        self.cur.subst = .{ .v = self.an.rv(if (dom == .nonzero_divisor) b2 else a), .lit = lit, .safe = safeArg(dom) };
    }
    return render_op.renderOp(self, op, a, b2, res_ty);
}

/// Returns whether folding `v` to one number would leave a materialized
/// temporary unread. `UnitPlan` already declared every slot, and an unread
/// `const` does not compile. Walks only the shapes `foldConst` walks and
/// answers true for the rest.
pub fn foldHidesSlot(self: *Gen, v0: Mir.Value, depth: u32) bool {
    // A recursion bounded by the depth cap, not by the input.
    assert(depth <= 33);
    if (depth > 32) return true;
    const v = self.an.rv(v0);
    if (depth > 0 and materialized(self, v)) return true;
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return false;
    const row = self.mir.instRow(def.inst_result);
    return switch (Mir.opClass(row.op)) {
        .unary => foldHidesSlot(self, @fromBackingInt(@intCast(row.a)), depth + 1),
        .binary => foldHidesSlot(self, @fromBackingInt(@intCast(row.a)), depth + 1) or
            foldHidesSlot(self, @fromBackingInt(@intCast(row.b)), depth + 1),
        .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => true,
    };
}

// ---- private ----

/// Returns the select condition's unslotted real comparison, so rendering it
/// in mask space leaves no unread `const`. Null for slotted predicates and
/// int comparisons, which take the `S.con(@floatFromInt(..))` fallback.
fn maskCmp(self: *Gen, cond: Mir.Value) ?Mir.Inst {
    assert(self.an.vty.len == self.an.nv);
    const v = self.an.rv(cond);
    if (materialized(self, v)) return null;
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return null;
    return switch (self.mir.instOp(def.inst_result)) {
        .flt, .fgt, .fle, .fge, .feq, .fne => def.inst_result,
        else => null, // else: only the six §4.2.5 REAL comparisons have an `S` mask form
    };
}

/// A real select that runs both arms and picks. An integer-condition `S`
/// pick is `zPick`, whose arguments both run: a lazy `if` over two `S` values
/// joins them through a pointer phi (`zPick`'s doc).
fn renderSelEager(self: *Gen, a: Mir.Value, b2: Mir.Value, c: Mir.Value, res: Mir.Value) Error!void {
    assert(self.float.strict);
    // Best mask first: an inline real comparison renders as
    // `lt`/`le`/`eq`, true per lane. gt/ge swap operands; ne swaps
    // the arms. Otherwise the predicate is a 0/1 i64 (lane-uniform,
    // so it pins) or a real S tested against zero.
    var swap_arms = false;
    if (maskCmp(self, a)) |cmp| {
        const d = self.mir.instData(cmp).binary;
        const swap_ops = d.op == .fgt or d.op == .fge;
        swap_arms = d.op == .fne;
        const prim: []const u8 = switch (d.op) {
            .flt, .fgt => "lt",
            .fle, .fge => "le",
            .feq, .fne => "eq",
            else => unreachable, // else: `maskCmp` returns only the six real comparisons
        };
        // A family's `sel` is `S.sel` (`contract.family_fns`).
        try self.b("S.sel((", .{});
        try renderVal(self, if (swap_ops) d.rhs else d.lhs, .real);
        try self.b(").{s}(", .{prim});
        try renderVal(self, if (swap_ops) d.lhs else d.rhs, .real);
        try self.b("), ", .{});
    } else if (self.an.tyOf(self.an.rv(a)) == .int) {
        // A 0/1 i64 is already one scalar decision, so an `S` mask
        // buys nothing: pick in f64 when both arms have an f64 form,
        // else pick the `S` arm.
        float_lanes.pinLanes(self, a);
        const fb = try gen_host.f64Const(self, b2, 1, true);
        const fc = if (fb != null) try gen_host.f64Const(self, c, 1, true) else null;
        if (fc == null) {
            const m = family.mask(self, res);
            try self.b("zPick(S, (", .{});
            try renderVal(self, a, .int);
            try self.b(") != 0, ", .{});
            for ([_]Mir.Value{ b2, c }, 0..) |v, k| {
                if (k != 0) try self.b(", ", .{});
                try family.openTo(self, m);
                try renderVal(self, v, .real);
                try self.b(")", .{});
            }
            return self.b(")", .{});
        }
        try self.b("S.con(if ((", .{});
        try renderVal(self, a, .int);
        return self.b(") != 0) {s} else {s})", .{ fb.?, fc.? });
    } else {
        try self.b("S.sel(", .{});
        try renderVal(self, a, .real);
        try self.b(", ", .{});
    }
    try renderVal(self, if (swap_arms) c else b2, .real);
    try self.b(", ", .{});
    try renderVal(self, if (swap_arms) b2 else c, .real);
    try self.b(")", .{});
}

/// A select that runs only the arm its condition takes.
fn renderSelLazy(self: *Gen, a: Mir.Value, b2: Mir.Value, c: Mir.Value, want: VTy, res: Mir.Value) Error!void {
    assert(self.an.tyOf(res) == want);
    try self.b("(if (", .{});
    try gen_cfg.renderCond(self, a);
    try self.b(") ", .{});
    if (want == .real) return renderArms(self, b2, c, family.mask(self, res));
    try renderVal(self, b2, want);
    try self.b(" else ", .{});
    try renderVal(self, c, want);
    try self.b(")", .{});
}

/// A point inside each §4.3.1/§4.3.2 domain (Table 4-14/4-15) with a finite
/// derivative there, so the discarded result and its lanes stay finite:
/// ln(1), ln1p(0), sqrt(1), asin(0), atanh(0), acosh(2), x/1, tan(0),
/// pow(1, y).
fn safeArg(dom: Mir.opcode.Domain) f64 {
    return switch (dom) {
        .positive, .non_negative, .nonzero_divisor, .pow_sign => 1.0,
        .gt_neg_one, .unit_closed, .unit_open, .tan_poles => 0.0,
        .ge_one => 2.0,
        .all => unreachable, // `ifconv` guards only a domain-restricted row
    };
}

/// Writes the guard chain from `lit` as one `bool`: each literal's condition,
/// negated on an else arm, joined by `and`.
fn renderGuard(self: *Gen, lit0: u32) Error!void {
    var lit = lit0;
    var first = true;
    assert(lit0 != Mir.GuardLit.end); // A guarded row has at least one literal.
    // The chain is a list through `guard_lits`, so it visits each row once.
    var iterations: usize = 0;
    while (lit != Mir.GuardLit.end) : (iterations += 1) {
        assert(iterations < self.mir.guard_lits.items.len);
        const l = self.mir.guard_lits.items[lit];
        if (!first) try self.b(" and ", .{});
        first = false;
        try self.b("{s}(", .{if (l.taken) "" else "!"});
        try gen_cfg.renderCond(self, l.cond);
        try self.b(")", .{});
        lit = l.next;
    }
}

/// Writes `s.v` behind its guard: the operand while the guard holds, else
/// the domain's safe value at the operand's type.
fn renderSubst(self: *Gen, s: Subst, want: VTy) Error!void {
    assert(self.cur.subst != null);
    self.cur.subst = null;
    defer self.cur.subst = s;
    assert(self.cur.subst == null);
    switch (want) {
        .real => {
            const m = family.mask(self, s.v);
            try self.b("zPick(S, ", .{});
            try renderGuard(self, s.lit);
            try self.b(", ", .{});
            try family.openTo(self, m);
            try renderVal(self, s.v, .real);
            try self.b("), ", .{});
            try family.openTo(self, m);
            try self.b("S.con({s})))", .{try gen_file.fmtF64(self, s.safe)});
        },
        .int => {
            try self.b("(if (", .{});
            try renderGuard(self, s.lit);
            try self.b(") ", .{});
            try renderVal(self, s.v, .int);
            try self.b(" else @as(i64, {d}))", .{@as(i64, @intFromFloat(s.safe))});
        },
        // A domain-restricted operand is a number (`Mir.opcode`).
        .str, .wide => try renderVal(self, s.v, want),
    }
}

/// Writes a lazy real `if`'s `then else otherwise)` after its condition. Both
/// arms widen to the result's mask `m`, the one type the `if` can have.
fn renderArms(self: *Gen, then: Mir.Value, otherwise: Mir.Value, m: []const u64) Error!void {
    assert(m.len == self.mw);
    for ([_]Mir.Value{ then, otherwise }, 0..) |v, k| {
        if (k != 0) try self.b(" else ", .{});
        try family.openTo(self, m);
        try renderVal(self, v, .real);
        try self.b(")", .{});
    }
    try self.b(")", .{});
}
