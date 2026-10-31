//! §7.3.2.1 non-finite contributions: a contributed `Mir.Value` in, E0424
//! out when a constant subtree of it folds to NaN or an infinity. A
//! post-order worklist over the value's operands, memoized per statement.
//!
//! Cites: §7.3.2.1.
//!
//! Contents:
//! - `pub fn checkFiniteContribution(self: *Lower, lhs: Ast.ExprId, v: Mir.Value) Oom!void`
//! - `pub const FiniteScan = struct`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const Const = Lower.Const;
const Oom = Lower.Oom;

/// One visited value: its fold, and the first non-finite fold met in its
/// subtree, in the scan's order.
pub const FiniteScan = struct { r: ?Const, bad: ?f64 };

/// At most two operands, in order: what `scanFinite` walks under one value.
const Operands = struct {
    items: [2]Mir.Value = undefined,
    len: u8 = 0,

    fn slice(o: *const Operands) []const Mir.Value {
        return o.items[0..o.len];
    }
    fn push(o: *Operands, v: Mir.Value) void {
        o.items[o.len] = v;
        o.len += 1;
    }
};

/// §7.3.2.1: "While use of these special numbers in digital expressions is not
/// an error, it is illegal to assign these values to a branch through
/// contribution in the analog context."
///
/// Compile time only: the clause is about a value the source names, and annex A
/// confines `inf` to a value_range_expression, so the only way to write one is
/// IEEE arithmetic (1.0/0.0, 0.0/0.0). A value non-finite only at some operating
/// point is W0650's "not provably finite", a different claim.
///
/// Scans subexpressions, not the whole contribution: `bad + 0.0*V(p)` does not
/// fold as a unit, so the scan folds every subtree it can and reports the first
/// non-finite one.
pub fn checkFiniteContribution(self: *Lower, lhs: Ast.ExprId, v: Mir.Value) Oom!void {
    assert(lhs == .none or self.exprValid(lhs));
    assert(self.valueValid(v));
    self.finite_scan.clearRetainingCapacity();
    var bad: ?f64 = null;
    _ = try scanFinite(self, v, &bad);
    const x = bad orelse return;
    try self.err(self.file.exprs.mainTok(lhs), .E0424, "{s}", .{
        if (std.math.isNan(x)) "contribution of a NaN" else "contribution of an infinite value",
    });
}

// ---- private ----

/// Fold `v0` where it is constant, recording the first non-finite result in
/// `bad`. Returns null for anything not constant — a probe, a parameter (the
/// host overrides it, so its declared default proves nothing), a call — but
/// keeps walking into it, because the offending constant is normally one
/// operand of a sum that is not constant. Visits each value once per
/// `self.finite_scan` clear.
///
/// Not `analysis.foldConst`: that wants a built `Analysis`, which does not
/// exist until lowering has finished, and this rule has to be reported on the
/// `<+` that broke it.
fn scanFinite(self: *Lower, v0: Mir.Value, bad: *?f64) Oom!?Const {
    assert(self.valueValid(v0));
    // ponytail: arithmetic and sign only (`accuses`). `exp(1000)` overflows to
    // +inf as well, but §7.3.2.1's examples are IEEE division and every operator
    // added here widens the surface for a false accusation. Add transcendentals
    // when a model needs them.
    const root = self.mir.resolveAlias(v0);
    if (!self.finite_scan.contains(root)) {
        // Post-order with an explicit stack: a model's dependency chain is
        // as long as its statement list, and recursion along it overflowed
        // the native stack at 2e4 chained statements.
        var stack: std.ArrayList(Mir.Value) = .empty;
        try stack.append(self.arena, root);
        while (stack.items.len != 0) {
            const v = stack.last().?;
            if (self.finite_scan.contains(v)) {
                _ = stack.pop();
                continue;
            }
            const ops = finiteOperands(self, v);
            var pending = false;
            for (ops.slice()) |o| if (!self.finite_scan.contains(o)) {
                try stack.append(self.arena, o);
                pending = true;
            };
            if (pending) continue;
            _ = stack.pop();
            try self.finite_scan.put(self.arena, v, scanOne(self, v, ops));
        }
    }
    const s = self.finite_scan.get(root).?;
    if (bad.* == null) bad.* = s.bad;
    return s.r;
}

/// The operands `scanFinite` walks under `v`, aliases resolved: those of a
/// unary or binary instruction, in order. Everything else is a leaf.
fn finiteOperands(self: *Lower, v: Mir.Value) Operands {
    assert(self.valueValid(v));
    var out: Operands = .{};
    switch (self.mir.valueDef(v)) {
        .inst_result => |inst| switch (self.mir.instData(inst)) {
            .unary => |u| out.push(self.mir.resolveAlias(u.operand)),
            .binary => |bn| {
                out.push(self.mir.resolveAlias(bn.lhs));
                out.push(self.mir.resolveAlias(bn.rhs));
            },
            .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => {},
        },
        .float_const, .int_const, .undef, .str_const, .param_ref, .block_param => {},
    }
    return out;
}

/// One value's scan, its operands' already in `finite_scan`: the fold of
/// IEEE arithmetic and sign (`accuses`), and the first non-finite value met,
/// operands before the value itself and lhs before rhs.
fn scanOne(self: *Lower, v: Mir.Value, ops: Operands) FiniteScan {
    assert(self.valueValid(v));
    assert(ops.len <= 2);
    var sub: ?f64 = null;
    for (ops.slice()) |o| if (sub == null) {
        sub = self.finite_scan.get(o).?.bad;
    };
    const r: ?Const = switch (self.mir.valueDef(v)) {
        .float_const => |x| .{ .real = x },
        .int_const => |x| .{ .int = x },
        .inst_result => |inst| switch (self.mir.instData(inst)) {
            .unary => |u| blk: {
                const a = self.finite_scan.get(ops.items[0]).?.r orelse break :blk null;
                break :blk if (accuses(u.op)) Mir.opcode.fold(u.op, &.{a}) else null;
            },
            .binary => |bn| blk: {
                if (!accuses(bn.op)) break :blk null;
                const a = self.finite_scan.get(ops.items[0]).?.r orelse break :blk null;
                const b = self.finite_scan.get(ops.items[1]).?.r orelse break :blk null;
                break :blk Mir.opcode.fold(bn.op, &.{ a, b });
            },
            .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => null,
        },
        .undef, .str_const, .param_ref, .block_param => null,
    };
    if (r) |c| {
        const x = c.asReal();
        if (!std.math.isFinite(x) and sub == null) sub = x;
    }
    return .{ .r = r, .bad = sub };
}

/// The opcodes `scanFinite` folds: IEEE arithmetic and sign, the ponytail in
/// its body. The operation itself is the shared kernel's (`opcode.fold`).
fn accuses(op: Mir.Opcode) bool {
    return switch (op) {
        .fneg, .ineg, .fabs, .iabs, .if_cast, .opt_barrier, .fadd, .fsub, .fmul, .fdiv => true,
        else => false, // else: §7.3.2.1's examples are IEEE division; every other operator widens the surface for a false accusation
    };
}
