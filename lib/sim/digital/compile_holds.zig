//! A procedural continuous assignment (`assign`, `force`) in, the process that holds its target and the rows that switch it on and off out.
//! Cites: IEEE 1364-2005 §9.3, §9.3.2.
//!
//! Contents:
//! - `pub const Slice = struct`
//! - `pub const Bits = struct`
//! - `pub fn compileProcContinuous(self: *Run, target: Ast.ExprId, value: Ast.ExprId, kind: Ast.ProcContinuous, tok: u32) Error!void`
//! AST -> bytecode: one process body or driver expression, in its instance
//! scope, -> `Instruction` rows in `Run.code`, each expression's type in
//! `Run.types`, and the static slot lists drivers and `@*` wait on; or E1100
//! before any process has run.
//! Clauses: IEEE 1364-2005 §4.8.1, §5.1.1, §5.1.14, §5.2.1/§5.2.2, §5.5.1
//! Table 5-22, §5.10.4, §6.1, §8.5.3.3/§8.5.3.4, §9.3, §9.5, §9.6, §9.7.1 to
//! §9.7.7, §9.8.2, §10.2.2/§10.2.3, §10.4.4/§10.4.5, §12.7, §17.1 to §17.11,
//! §20.4, A.6.5; VAMS §7.3.6.3 analog probes, §9.14 Table 9-11 `$clog2`,
//! §9.22 driver access.
const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const exec = @import("exec.zig");
const evaluate = @import("evaluate.zig");
const deep = @import("base").deep_stack;
const display = @import("display.zig");
const driver = @import("driver.zig");
const system = @import("system.zig");
const elab = @import("elab.zig");
const evcd = @import("evcd.zig");
const vcd = @import("vcd.zig");
const root = @import("root.zig");
const Error = root.Error;
const Run = root.Run;
const SpecExpr = root.SpecExpr;
const expectRun = root.expectRun;
const expectRejected = root.expectRejected;
const filled = @import("net.zig").filled;
const compile_stmt = @import("compile_stmt.zig");
const constness = @import("constness.zig");
const expr_types = @import("expr_types.zig");
const wait_lists = @import("wait_lists.zig");
const append = compile_stmt.append;
const checkExpr = expr_types.checkExpr;
const constantExpression = constness.constantExpression;
const notAutomatic = wait_lists.notAutomatic;
const position = compile_stmt.position;
const readsNoAutomatic = wait_lists.readsNoAutomatic;
const sensitivity = wait_lists.sensitivity;
const watcher = compile_stmt.watcher;

/// The bits of an overriding value one concatenation operand takes: from
/// bit `lo` of a value `of` bits wide (§9.3 `assign {a, b} = v`).
pub const Slice = struct { lo: u32, of: u32 };

/// A constant bit range of a slot, `width` bits from bit position `lo`.
pub const Bits = struct { lo: u32, width: u32 };

const OverTarget = struct { at: u32, bits: ?Bits };

/// IEEE 1364-2005 §9.3: `assign`/`force` compile an out-of-line process that
/// re-writes the target whenever the expression's operands change, and an
/// `.override_on` that starts it; `deassign`/`release` stop it. `assign`
/// takes a variable (§9.3.1); `force` a variable or a net (§9.3.2).
pub fn compileProcContinuous(self: *Run, target: Ast.ExprId, value: Ast.ExprId, kind: Ast.ProcContinuous, tok: u32) Error!void {
    assert(target != .none);
    assert(tok < self.starts.len);
    if (self.in_function) return self.fail(tok, "§10.4.4: a function body cannot contain a procedural continuous assignment", .{});
    const ex = &self.file.exprs;
    // §9.3 "a concatenation of variables" (and for `force`, of nets): one
    // override per operand, each keeping its own bits of the value.
    if (ex.tag(target) == .concat) {
        const ops = ex.args(target);
        var of: u32 = 0;
        for (ops) |x| of += overWidth(self, try overTarget(self, x));
        var lo = of;
        for (ops) |x| {
            const t = try overTarget(self, x);
            lo -= overWidth(self, t);
            try override(self, x, t, value, kind, .{ .lo = lo, .of = of });
        }
        return;
    }
    return override(self, target, try overTarget(self, target), value, kind, null);
}

// ---- private ----

fn overWidth(self: *Run, t: OverTarget) u32 {
    return if (t.bits) |b| b.width else self.values[t.at].width;
}

/// A §9.3 target's slot and, for §9.3.2's "constant bit-select of a vector
/// net, a part-select of a vector net", the bits it names.
fn overTarget(self: *Run, x: Ast.ExprId) Error!OverTarget {
    assert(x != .none);
    const ex = &self.file.exprs;
    const refused = "§9.3: a procedural continuous assignment names one whole variable or net, a constant bit-select or part-select of a vector net, or a concatenation of them";
    switch (ex.tag(x)) {
        .ident, .hier_ident => return .{ .at = try self.scalarSlot(x), .bits = null },
        .index => {
            // §9.3.2 an element of a net array is a net (§4.9.1); a memory
            // word is not forced.
            if (try self.indexedArray(x) != null) {
                if (!self.net_of.contains(try self.baseSlot(x))) return self.exprFail(x, refused);
                return .{ .at = try elab.netSlot(self, x, ex.mainTok(x)), .bits = null };
            }
            const base = ex.lhs(x);
            if (ex.tag(base) != .ident and ex.tag(base) != .hier_ident) return self.exprFail(x, refused);
            const at = try self.scalarSlot(base);
            if (!self.net_of.contains(at)) return self.exprFail(x, refused);
            try checkExpr(self, x);
            const rg = ex.rhs(x);
            const index = switch (ex.tag(rg)) {
                .range => Ast.ExprId.none,
                .indexed_range => ex.lhs(rg),
                else => rg, // else: a bit-select's index
            };
            if (index != .none and !constantExpression(self, index)) return self.exprFail(x, refused);
            const sel = (try evaluate.selection(self, self.arena, x)) orelse return self.exprFail(x, "§9.3.2: the select's index is x or z");
            if (sel.first < 0 or sel.first + sel.count > self.values[at].width) return self.exprFail(x, "§9.3.2: the select is outside its net");
            return .{ .at = at, .bits = .{ .lo = @intCast(sel.first), .width = sel.count } };
        },
        else => return self.exprFail(x, refused), // else: no other expression names storage
    }
}

/// §9.3 one override of `target`: a whole variable or net, or bits of a net.
fn override(self: *Run, target: Ast.ExprId, t: OverTarget, value: Ast.ExprId, kind: Ast.ProcContinuous, slice: ?Slice) Error!void {
    assert(target != .none);
    const at = t.at;
    try notAutomatic(self, target, "a procedural continuous assignment");
    // Its value is re-evaluated after the activation may be gone.
    if (value != .none) try readsNoAutomatic(self, value, "a procedural continuous assignment");
    const force = kind == .force or kind == .release;
    if (!force and self.net_of.contains(at)) return self.exprFail(target, "§9.3.1: assign/deassign take a variable; a net is forced");
    if (kind == .deassign or kind == .release) {
        _ = try append(self, .{ .override_off = .{ .slot = at, .force = force, .bits = t.bits } });
        return;
    }
    try checkExpr(self, value);
    var watched: std.ArrayList(u32) = .empty;
    try sensitivity(self, value, &watched);
    const start = try watcher(self, .{ .override_eval = .{ .slot = at, .value = value, .force = force, .slice = slice, .bits = t.bits } }, watched.items);
    const end = position(self);
    // §9.3.1/§9.3.2: the override holds from the statement on, so the
    // value is written here, before the next statement reads it; the
    // process `.override_on` starts keeps it. `.override_on` stays the
    // statement's last instruction, the `done_sites` pc whose process
    // reports the §12.31.1 cbForce/cbAssign (`exec.doneFlush`).
    _ = try append(self, .{ .override_eval = .{ .slot = at, .value = value, .force = force, .slice = slice, .bits = t.bits } });
    _ = try append(self, .{ .override_on = .{ .slot = at, .force = force, .start = start, .end = end, .bits = t.bits } });
}
