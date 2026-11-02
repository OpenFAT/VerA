//! §5.6 direct contributions: one `<+` statement in, its value accumulated
//! into the target's `Lowered.contributions` row out. The spine checks the
//! statement's context and target, resolves the branch (branch.zig), finds
//! or opens its row (accum.zig), splits the right-hand side into resistive
//! and reactive halves (reactive.zig), discards the opposite quantity
//! (§5.6.1.3), and collects the §4.6.4 noise generators (noise_src.zig).
//!
//! Cites: §1.3.1, §1.3.1.2, §1.3.4.1, §1.3.4.2, §3.4.7, §4.4, §4.5.12,
//! §4.6.4, §4.6.4.6, §5.4.1, §5.4.2.2, §5.4.3, §5.6, §5.6.1.2, §5.6.1.3,
//! §5.6.5, §5.6.6, §5.6.7.2, §5.6.8.2, §5.9, §5.9.3, §5.10, §6.3.6, A.6.4,
//! §7.3.2.1, A.8.2, §9.18.
//!
//! Contents:
//! - `pub const State = struct` (`Key`)
//! - `pub fn directRow(self: *const Lower, key: State.Key) ?u32`
//! - `pub fn oppositeKey(t: Target) State.Key`
//! - `pub fn lowerContribute(self: *Lower, lhs: Ast.ExprId, rhs: Ast.ExprId) Oom!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_analog_op = @import("analog_op.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_node = @import("node.zig");
const Ssa = @import("ssa.zig");
const lower_finite = @import("finite.zig");
const lower_indirect = @import("indirect.zig");
const lower_source_check = @import("source_check.zig");
const lower_branch = @import("branch.zig");
const lower_accum = @import("accum.zig");
const lower_reactive = @import("reactive.zig");
const lower_noise_src = @import("noise_src.zig");
const lower_node_discipline = @import("node_discipline.zig");
const lower_noise_op = @import("noise_op.zig");
const Target = lower_branch.Target;
const Oom = Lower.Oom;
const unnamed_branch = Lower.unnamed_branch;
const Access = Lower.Access;
const NoiseSrc = Lower.NoiseSrc;
const Accum = Lower.Accum;

/// This file's private state on `Lower` (`Lower.contrib_state`): the lookups
/// `contribIndex` makes per `<+`, hashed so a module of n contributions
/// lowers in O(n) (a generate loop or a flattened instance array of 10^5).
pub const State = struct {
    /// The first `.direct` entry of each (access, pair, branch).
    direct: std.AutoHashMapUnmanaged(Key, u32) = .empty,
    /// The `contrib_sharers` rows already recorded.
    sharers: std.AutoHashMapUnmanaged(struct { row: u32, unit: u32 }, void) = .empty,
    /// The `pairKey` of every `.indirect` row (§5.6.7.2's test per `<+`).
    indirect: std.AutoHashMapUnmanaged(u64, void) = .empty,

    /// `direct`'s key: the target's access, (hi, lo) net pair and branch row.
    pub const Key = struct { access: Access, hi: u32, lo: u32, br: u32 };
    comptime {
        assert(@sizeOf(Key) == 16); // hashed per `<+`
    }
};

/// The `.direct` contribution entry of a (access, pair, branch), if a `<+`
/// has made one: `contribIndex`'s lookup, without creating it.
pub fn directRow(self: *const Lower, key: State.Key) ?u32 {
    assert(self.nodeValid(key.hi));
    assert(self.nodeValid(key.lo));
    return self.contrib_state.direct.get(key);
}

/// `direct`'s key for the other quantity of `t`'s branch.
pub fn oppositeKey(t: Target) State.Key {
    assert(t.hi <= t.lo); // `canonical` ordered the pair
    assert(t.access == .potential or t.access == .flow);
    return .{ .access = if (t.access == .potential) .flow else .potential, .hi = t.hi, .lo = t.lo, .br = t.br };
}

/// Lowers one `<+`: resolves the branch, splits the rhs into its resistive and
/// reactive halves (§5.6.1.2) and accumulates both into the target (§5.6.1.3).
/// The reference direction (§1.3.1.2) is carried by the (hi, lo) order alone:
/// codegen stamps `+val` at hi and `-val` at lo. (LRM §5.6)
pub fn lowerContribute(self: *Lower, lhs: Ast.ExprId, rhs: Ast.ExprId) Oom!void {
    assert(lhs == .none or self.exprValid(lhs));
    assert(rhs == .none or self.exprValid(rhs));
    assert(self.blockValid(self.cur));
    if (self.restrict) |ctx| {
        try self.err(self.file.exprs.mainTok(lhs), .E0405, "not allowed in {s}", .{ctx});
        return;
    }
    // §5.10 "Contribution statements cannot be used inside an event control
    // block because it can generate discontinuity in analog signals"; A.6.4
    // `analog_event_statement` states it structurally.
    if (self.in_event_stmt) {
        try self.err(self.file.exprs.mainTok(lhs), .E0406, "", .{});
        return;
    }
    // §5.9, the third blanket restriction on `repeat`/`while`/non-genvar `for`:
    // "Contribution statements are not allowed". The set of branches a device
    // stamps is fixed before the solve, and a runtime trip count is not.
    //
    // Only the three CFG loops push onto `self.loops`. §5.9.3's genvar `for` is
    // unrolled by `tryUnrollFor` before `lowerFor` runs, so a genvar loop
    // contributes once per iteration and never reaches here.
    if (self.loops.items.len != 0) {
        try self.err(self.file.exprs.mainTok(lhs), .E0426, "", .{});
        return;
    }
    const ex = &self.file.exprs;
    // §5.4.3 "The port access function shall not be used on the left side of a
    // contribution operator <+." (§4.4 says the same of branch assignment.)
    if (ex.tag(lhs) == .port_access) {
        var b = self.errWith(self.file.exprs.mainTok(lhs), .E0407);
        b.help("contribute to the branch instead: `I(p, gnd) <+ ...`", .{});
        try b.emit();
        _ = try lower_expr.lowerExpr(self, rhs);
        return;
    }
    if (ex.tag(lhs) != .branch_access) {
        try self.err(self.file.exprs.mainTok(lhs), .E0408, "", .{});
        _ = try lower_expr.lowerExpr(self, rhs);
        return;
    }
    try checkZeroTransitionZFilter(self, rhs);
    const target = try lower_branch.branchOf(self, lhs) orelse return;
    // §5.6.7.2 "Once a value is indirectly assigned to a branch, it cannot be
    // contributed to using the branch contribution operator <+."
    if (lower_indirect.indirectOn(self, target.hi, target.lo)) {
        var b = self.errWith(self.file.exprs.mainTok(lhs), .E0409);
        b.msg("`{s}({s},{s})`", .{
            if (target.access == .potential) "V" else "I",
            lower_node.nodeName(self, target.hi),
            lower_node.nodeName(self, target.lo),
        });
        b.note("a branch is defined either by accumulated `<+` or by one indirect assignment, never both", .{});
        try b.emit();
        return;
    }
    // §1.3.4.1 "In that case, potential contributions may not be made to
    // `input` ports"; §1.3.4.2 says the same of flow contributions. The port's
    // direction is the direction of its one quantity, so an `input` is supplied
    // from outside and driving it has no meaning. Only `input`: an `output` is
    // meant to be driven, and E0360 already refuses an `inout` signal-flow port.
    for ([_]u32{ target.hi, target.lo }) |n| {
        if (n >= self.out.nodes.len or self.out.nodes.items(.dir)[n] != .input) continue;
        if (!lower_node_discipline.isSignalFlow(self, self.out.nodes.items(.disc)[n])) continue;
        try self.err(self.file.exprs.mainTok(lhs), .E0425, "`{s}` is an `input` port of discipline `{s}`", .{ self.out.nodes.items(.name)[n], self.out.nodes.items(.disc)[n] });
        return;
    }
    // §5.6.8.2: a hierarchical contribution is not allowed when it "changes
    // the branch into a switch branch". A named branch belongs to one instance
    // (§5.4.1), so the other access function on it from a DIFFERENT unit is
    // exactly that, whichever of the two blocks lowers first. Inside one unit
    // it is §5.6.1.3's value retention and stays legal (`discardOpposite`).
    if (target.br != unnamed_branch) if (directRow(self, oppositeKey(target))) |row| {
        const c = self.out.contributions.items[row];
        if (c.unit != self.cur_unit) {
            var b = self.errWith(self.file.exprs.mainTok(lhs), .E0439);
            b.label(self.tokenSpan(c.tok), "the other module instance contributes the {s} here", .{if (c.access == .potential) "potential" else "flow"});
            try b.emit();
            return;
        }
    };
    if (try lower_source_check.checkHierParallel(self, lhs, target)) return;
    if (target.access == .flow) try checkMfactorDoubleScaling(self, lhs, rhs);
    const idx = try lower_accum.contribIndex(self, target, self.file.exprs.mainTok(lhs));

    // §5.6.6: while THIS statement's right-hand side lowers, a read of its own
    // target is the implicit form — see `contrib_target`.
    self.contrib_target = target;
    defer self.contrib_target = null;
    const split = try lower_reactive.splitContribution(self, rhs);
    if (split.resist) |v| try lower_finite.checkFiniteContribution(self, lhs, v); // §7.3.2.1
    if (split.react) |v| try lower_finite.checkFiniteContribution(self, lhs, v);
    const acc = self.accum.items[idx];
    // The owning instance's share of an unnamed branch row (`unit_accum`).
    const part: ?Accum = if (target.br == unnamed_branch and self.out.contributions.items[idx].shared)
        try lower_accum.unitAccum(self, idx, target.unit)
    else
        null;
    // §5.6.1.3 value retention, the half that is a REPLACEMENT and not a sum.
    // Before this statement's own value is added, anything retained for the
    // OTHER quantity of the same branch is thrown away.
    try lower_accum.discardOpposite(self, target);
    // §1.3.1.2: `I(n,p) <+ e` drives the same branch as `I(p,n) <+ -e`, so the
    // reversed spelling accumulates into the same source with the sign flipped.
    // Checked AFTER §7.3.2.1, which is about the value the source names and
    // does not care which way the branch was written.
    inline for (.{ "resist", "react" }) |half| {
        if (@field(split, half)) |v0| {
            const v = if (target.neg) try self.emit(.fneg, &.{v0}) else v0;
            try addInto(self, @field(acc, half), v);
            if (part) |pa| try addInto(self, @field(pa, half), v);
        }
    }
    // §5.6.1.2 each reactive term is also a charge SITE of its own, so the
    // host can tape it apart from the others on the same row.
    for (split.sites.items) |ps| try lower_reactive.addSite(self, idx, ps, target.neg);
    // §5.6.1.3 this statement RETAINS a value for its quantity on every path
    // that executes it — even `<+ 0.0`, whose retained zero is §5.6.5's closed
    // switch and not an absent source. A constant write: no MIR instruction,
    // and on a straight line no phi either.
    try self.builder.writeVariable(acc.wrote, self.cur, .f_one);
    // §4.6.4 the noise generators belong to the target, not to one statement,
    // and they ACCUMULATE: two `<+` lines on one branch declare two sources —
    // unless they reach the SAME source through a variable (§4.6.4.6), which
    // the identity dedup in `addNoiseSrc` keeps as one generator.
    {
        var srcs: std.ArrayList(NoiseSrc) = .empty;
        try srcs.appendSlice(self.arena, self.out.contributions.items[idx].noise_srcs);
        try lower_noise_src.noiseSrcsOf(self, rhs, &srcs);
        // §4.6.4.6 the per-use coefficient. It ADDS across statements, because
        // two `<+` lines on one branch sum into one source: `V(a,b) <+ c1*n`
        // followed by `V(a,b) <+ c2*n` drives the branch with (c1+c2)·n, and
        // `addNoiseSrc` has already collapsed them onto one row.
        //
        // Read off `split.resist`: a noise function is an amplitude, not a
        // reactive quantity, so the generator only ever appears in the
        // resistive half. The §1.3.1.2 sign flip is applied for the same
        // reason it is applied above — `I(n,p) <+ c*n` drives the branch
        // with −c, and the sign is what separates correlation from
        // anti-correlation.
        if (split.resist) |v0| {
            for (srcs.items) |*s| {
                if (s.nonlinear) continue;
                const g = self.noise_val.get(s.id) orelse continue;
                switch (try lower_noise_op.noiseCoeff(self, v0, g)) {
                    .absent => {},
                    // No factor describes this use. Fall back to 1 and stop
                    // accumulating, so a later statement cannot make the row
                    // claim more than it knows.
                    .nonlinear => {
                        s.nonlinear = true;
                        s.coeff = .f_one;
                    },
                    .value => |d| {
                        const signed = if (target.neg) try lower_noise_op.coeffNeg(self, d) else d;
                        s.coeff = if (s.coeff == .f_zero) signed else try self.emit(.fadd, &.{ s.coeff, signed });
                    },
                }
            }
        }
        self.out.contributions.items[idx].noise_srcs = srcs.items;
    }
}

// ---- private ----

/// `place += v` in the current block.
fn addInto(self: *Lower, place: Ssa.Place, v: Mir.Value) Oom!void {
    assert(self.valueValid(v));
    assert(self.blockValid(self.cur));
    const old = try self.builder.readVariable(place, self.cur);
    try self.builder.writeVariable(place, self.cur, try self.emit(.fadd, &.{ old, v }));
}

/// §6.3.6 the double-scaling misuse: "The first example, badres, misuses the
/// $mfactor such that the contributed current would be multiplied by $mfactor
/// twice ... The simulator will generate an error for this module." Every flow
/// contribution is already scaled by $mfactor and "Verilog-AMS does not provide
/// a method to disable" it, so an explicit factor can only scale it again.
///
/// The predicate is scaling, not presence: §6.3.6's legal `parares` reads
/// $mfactor in an `if` condition. So the test is `$mfactor` as an operand of a
/// `*` or `/` in the contributed value; dividing by it is the same misuse.
/// Potential contributions are not scaled, so only flow is checked.
fn checkMfactorDoubleScaling(self: *Lower, lhs: Ast.ExprId, rhs: Ast.ExprId) Oom!void {
    assert(lhs == .none or self.exprValid(lhs));
    assert(rhs == .none or self.exprValid(rhs));
    // ponytail: misses a flattened child whose ancestor specified `.$mfactor(...)`,
    // where elaboration (`rewriteSysCall`) has already substituted the product and
    // no `sys_call` is left. The upgrade is to run this scan in the clone, which
    // needs the discipline table elaboration does not have.
    if (!scalesByMfactor(self, rhs)) return;
    var b = self.errWith(self.file.exprs.mainTok(lhs), .E0912);
    b.msg("this flow contribution multiplies by `$mfactor`", .{});
    b.note("§6.3.6: every flow contribution is scaled by $mfactor automatically, and \"Verilog-AMS does not provide a method to disable\" it — so an explicit factor scales it twice", .{});
    b.help("delete the `$mfactor` factor; read it in a guard if the equation needs to know the multiplicity", .{});
    try b.emit();
}

/// Whether the contributed value is a product with `$mfactor` as a factor.
///
/// The walk follows only the product spine (mul, div, sign), reading "the
/// contributed current would be multiplied by $mfactor twice" literally: a
/// `$mfactor` scaling one addend of a sum does not scale the current
/// (`mfactor.va` writes `I(p) <+ V(p) + 0.0 * $mfactor;` on purpose). The known
/// hole is `I <+ V/r * $mfactor + off`; the LRM gives no rule for the mixed case.
fn scalesByMfactor(self: *Lower, e: Ast.ExprId) bool {
    assert(e == .none or self.exprValid(e));
    assert(self.module != null);
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .binary => switch (ex.binOp(e)) {
            .mul, .div => isMfactorRead(self, ex.lhs(e)) or isMfactorRead(self, ex.rhs(e)) or
                scalesByMfactor(self, ex.lhs(e)) or scalesByMfactor(self, ex.rhs(e)),
            else => false, // else: only `*` and `/` scale; the doc above says why the spine stops there
        },
        .unary => switch (ex.unOp(e)) {
            .plus, .minus => scalesByMfactor(self, ex.lhs(e)),
            else => false, // else: only a sign keeps the spine
        },
        else => false, // else: not on the multiplicative spine
    };
}

/// A read of §9.18's `$mfactor`, under either of its two spellings: the system
/// function itself, or the §3.4.7 `aliasparam m = $mfactor;` name for it — the
/// alias is a second name for one location, so it is the same read.
fn isMfactorRead(self: *Lower, e: Ast.ExprId) bool {
    assert(e == .none or self.exprValid(e));
    assert(self.module != null);
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .sys_call => std.mem.eql(u8, self.file.str(ex.strOf(e)), "$mfactor"),
        .ident => if (self.hier_params.get(.mfactor)) |pi|
            self.param_index.get(self.file.str(ex.strOf(e))) == pi
        else
            false,
        else => false, // else: neither of `$mfactor`'s two spellings
    };
}

/// §4.5.12, the two sentences that are one rule: "If the transition time is
/// specified as zero (0), then the output is abruptly discontinuous. A Z-filter
/// with zero (0) transition time shall not be directly assigned to a branch."
///
/// A zero τ is legal (reading the output into a variable is fine); the rule
/// targets the statement, so the check lives here rather than with the
/// operator's argument checks. "Directly" means the filter call is the whole
/// right-hand side: `V(x) <+ 2*zi_zp(…)` is not reached. An absent τ is the
/// simulator's default, not "specified as zero".
fn checkZeroTransitionZFilter(self: *Lower, rhs: Ast.ExprId) Oom!void {
    assert(rhs == .none or self.exprValid(rhs));
    assert(self.blockValid(self.cur));
    const ex = &self.file.exprs;
    if (ex.tag(rhs) != .filter_call) return;
    if (!std.mem.startsWith(u8, self.file.str(ex.strOf(rhs)), "zi_")) return;
    // zi_*(expr, numerator, denominator, T [, τ [, t0]]) — A.8.2.
    const args = ex.args(rhs);
    if (args.len < 5 or args[4] == .none) return;
    const tau = lower_constfold.constEval(self, args[4]) orelse return;
    if (tau.asReal() != 0.0) return;
    var b = self.errWith(self.file.exprs.mainTok(rhs), .E0518);
    b.msg("a Z-filter with zero (0) transition time shall not be directly assigned to a branch", .{});
    b.help("read it into a variable first, then contribute the variable", .{});
    try b.emit();
}

test "§5.6 contributions: the rules a `<+` is judged by" {
    try Lower.expectBodies(&.{
        // §6.3.6: every flow contribution is already scaled by $mfactor.
        .{ .src = "analog I(p) <+ V(p) * $mfactor;", .code = .E0912 },
        .{ .src = "analog I(p) <+ V(p) + 0.0 * $mfactor;", .code = null },
        // §4.5.12: a zero-transition Z-filter "shall not be directly assigned".
        .{ .src = "analog V(p) <+ zi_nd(V(q), '{1.0}, '{1.0}, 1n, 0);", .code = .E0518 },
        // §7.3.2.1: an infinite value contributed to a branch.
        .{ .src = "analog begin x = 1.0 / 0.0; I(p) <+ x + 0.0 * V(p); end", .code = .E0424 },
        .{ .src = "analog begin x = 1.0 / 2.0; I(p) <+ x + 0.0 * V(p); end", .code = null },
        // §1.3.1: both quantities of a probe branch; a contribution makes it a
        // source, whose two quantities §5.4.2.2 makes accessible.
        .{ .src = "analog begin x = V(p, q) + I(p, q); I(p) <+ x; end", .code = .E0423 },
        .{ .src = "analog begin x = V(p, q) + I(p, q); I(p, q) <+ x * 1m; end", .code = null },
        // §4.4 Table 4-16: `I(n1,n1)` is an error.
        .{ .src = "analog I(p) <+ I(p, p);", .code = .E0315 },
        // §5.9: no contribution inside a procedural `for`.
        .{ .src = "analog for (iv = 0; iv < 2; iv = iv + 1) I(p) <+ 1.0;", .code = .E0426 },
    });
}

test "§1.3.1.2 a reversed spelling accumulates into one source" {
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p, q);
        \\  inout p, q; electrical p, q;
        \\  analog begin
        \\    I(p, q) <+ 1.0;
        \\    I(q, p) <+ 2.0;
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    // `I(q,p) <+ 2` is `I(p,q) <+ -2`: one row, in lower_branch.canonical (p, q) order.
    try std.testing.expectEqual(@as(usize, 1), h.low.out.contributions.items.len);
    try std.testing.expectEqual(@as(u32, 0), h.low.out.contributions.items[0].hi);
    try std.testing.expectEqual(@as(u32, 1), h.low.out.contributions.items[0].lo);
}
