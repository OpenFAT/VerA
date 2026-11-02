//! The §4.2 constant_expression folder: an expression AST in, a `Const` out,
//! or null when the expression is not constant. Pure: no symbol table;
//! identifiers and `>>>`'s signedness come from the caller's `env`. This file
//! walks the tree, on a heap stack of the operators it has entered, so an
//! expression nests as deep as memory allows on any thread; IEEE §5.1.11's
//! reductions are here, and `constfold_size.zig` sizes the operands (§4.2.9;
//! IEEE §§5.4–5.5, the self-determined `$clog2` operand of §9.14). Each
//! operator's and §4.3 function's value is `kernels.fold`'s, re-exported
//! here.
//! §3.4/A.2.4 and §6.3 share the syntactic check for reads of simulation state.
//!
//! Contents:
//! - `pub const Const = fold_k.Const`
//! - `pub const wrap32 = fold_k.wrap32`
//! - `pub const unary = fold_k.unary`
//! - `pub const binary = fold_k.binary`
//! - `pub const MathFn = fold_k.MathFn`
//! - `pub const math = fold_k.math`
//! - `pub const clog2 = fold_k.clog2`
//! - `pub const UnsignedCompare = size.UnsignedCompare`
//! - `pub const IntContext = size.IntContext`
//! - `pub const IntPlan = size.IntPlan`
//! - `pub const unsignedCompare = size.unsignedCompare`
//! - `pub const operandWidth = size.operandWidth`
//! - `pub const clog2Width = size.clog2Width`
//! - `pub const clog2Signed = size.clog2Signed`
//! - `pub const intPlan = size.intPlan`
//! - `pub fn parameterValue(ty: Ast.Type, value: Const) Const`
//! - `pub fn parameterCardValue(ty: Ast.Type, declared: ?Const, value: f64) Const`
//! - `pub fn firstStateRead(gpa: std.mem.Allocator, file: *const Ast.SourceFile, e: Ast.ExprId, vars: []const Ast.VarDecl) std.mem.Allocator.Error!?[]const u8`
//! - `pub fn fold(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) ?Const`
//! - `pub fn foldSized(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) ?Const`
//! - `pub const literal_env: LiteralEnv = .`
//! - the `env` interface `fold` reads, which the private `LiteralEnv` and
//!   `TestEnv` implement: `leaf`, `signed`, `width`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("ast.zig");
const fold_k = @import("kernels").fold;
const size = @import("constfold_size.zig");
const Pending = size.Pending;
const literalWidth = size.literalWidth;
const testing = std.testing;

/// The value folds, in `kernels.fold`: re-exported for the callers that
/// reach them through `frontend.constfold`.
pub const Const = fold_k.Const;

pub const wrap32 = fold_k.wrap32;

pub const unary = fold_k.unary;

pub const binary = fold_k.binary;

pub const MathFn = fold_k.MathFn;

pub const math = fold_k.math;

pub const clog2 = fold_k.clog2;

pub const UnsignedCompare = size.UnsignedCompare;

pub const IntContext = size.IntContext;

pub const IntPlan = size.IntPlan;

pub const unsignedCompare = size.unsignedCompare;

pub const operandWidth = size.operandWidth;

pub const clog2Width = size.clog2Width;

pub const clog2Signed = size.clog2Signed;

pub const intPlan = size.intPlan;

/// The `env` that knows nothing: `fold(file, e, literal_env)` folds literals
/// and the operators over them, and declines an identifier and `>>>`.
pub const literal_env: LiteralEnv = .{};

/// The type of `literal_env`: every query answers null.
const LiteralEnv = struct {
    pub fn leaf(_: LiteralEnv, _: Ast.ExprId) ?Const {
        return null;
    }
    pub fn signed(_: LiteralEnv, _: Ast.ExprId) ?bool {
        return null;
    }
    pub fn width(_: LiteralEnv, _: Ast.ExprId) ?u32 {
        return null;
    }
};

/// `fold`'s environment in these tests: `a` is a signed 32-bit integer
/// holding -1 and `u` an unsigned 8-bit one holding 255; a literal reports its
/// own signedness, as lowering's environment does.
const TestEnv = struct {
    file: *const Ast.SourceFile,

    fn name(env: TestEnv, e: Ast.ExprId) ?[]const u8 {
        if (env.file.exprs.tag(e) != .ident) return null;
        return env.file.str(env.file.exprs.strOf(e));
    }
    pub fn leaf(env: TestEnv, e: Ast.ExprId) ?Const {
        const n = env.name(e) orelse return null;
        if (std.mem.eql(u8, n, "a")) return .{ .int = -1 };
        if (std.mem.eql(u8, n, "u")) return .{ .int = 255 };
        return null;
    }
    pub fn signed(env: TestEnv, e: Ast.ExprId) ?bool {
        const ex = &env.file.exprs;
        if (ex.tag(e) == .int_literal) return ex.intLiteral(e).signed;
        if (ex.tag(e) == .logic_literal) return ex.logicValue(e).signed;
        const n = env.name(e) orelse return null;
        if (std.mem.eql(u8, n, "a")) return true;
        if (std.mem.eql(u8, n, "u")) return false;
        return null;
    }
    pub fn width(env: TestEnv, e: Ast.ExprId) ?u32 {
        const n = env.name(e) orelse return null;
        if (std.mem.eql(u8, n, "a")) return 32;
        if (std.mem.eql(u8, n, "u")) return 8;
        return null;
    }
};

const TestExpr = struct { file: Ast.SourceFile, e: Ast.ExprId, vars: []const Ast.VarDecl };

/// One operator `foldContext` has entered, waiting on its operands.
const Frame = struct {
    e: Ast.ExprId,
    /// Its IEEE §5.5 plan when `sized` (`intPlan`).
    plan: ?IntPlan,
    /// Folded under `foldSized`'s rules; a §4.3 call's arguments are not.
    sized: bool,
    /// How many operands have come back, in `vals`.
    done: u8 = 0,
    /// The operands' values; a `?:` keeps its condition and the arm taken.
    vals: [MathFn.arity_max]Const = undefined,
};

/// A row `foldContext` folds next, and how.
const Operand = struct { e: Ast.ExprId, sized: bool, parent: ?IntContext };

/// Frames a fold keeps on the native stack before it takes pages: deeper
/// than nearly every constant expression.
const frames_in_place = 16;

/// §3.4.1 applies the declared parameter type before another expression reads
/// its value. Shared by elaboration's paramset selection and lowering, so the
/// selected member sees the same real/integer conversion as the emitted model.
/// Invalid real-to-integer inputs remain real for the caller's diagnostic.
pub fn parameterValue(ty: Ast.Type, value: Const) Const {
    const out: Const = switch (ty) {
        .real => if (value == .str) value else .{ .real = value.asReal() },
        .integer => switch (value) {
            .int => |n| .{ .int = wrap32(n) },
            .real => if (value.asIntExact()) |n| .{ .int = wrap32(n) } else value,
            .str => value,
        },
        .string, .unspecified => value,
    };
    // A real parameter holds a real unless the value is a string the caller reports.
    if (ty == .real and value != .str) assert(out == .real);
    if (ty == .integer and value == .int) assert(out == .int);
    return out;
}

/// Numeric host cards carry no new HDL type or width. Preserve an inferred
/// integral carrier without imposing the explicit `integer` declaration's
/// 32-bit wrap; operand width still comes from the elaborated declaration.
pub fn parameterCardValue(ty: Ast.Type, declared: ?Const, value: f64) Const {
    const c: Const = .{ .real = value };
    if (ty == .unspecified and declared != null and declared.? == .int)
        return if (c.asIntExact()) |n| .{ .int = n } else c;
    return parameterValue(ty, c);
}

/// §3.4/A.2.4: the spelling of the first simulation-state or module-variable
/// reference in a parameter default, or null when none exists. Access functions, analog
/// operators, small-signal sources and event functions are state reads by
/// TAG; a `sys_call` is one by NAME (`simStateName`), because most `$` names
/// that could appear here — `$param_given`, `$mfactor`, `$simprobe` — resolve
/// before the solve and are left to the ordinary paths. Every other tag is
/// searched through its `children`, first in source order. The rows still
/// to search sit on a stack from `gpa`, freed before return, so the depth of
/// `e` costs heap, not native stack.
pub fn firstStateRead(gpa: std.mem.Allocator, file: *const Ast.SourceFile, e: Ast.ExprId, vars: []const Ast.VarDecl) std.mem.Allocator.Error!?[]const u8 {
    assert(e == .none or @backingInt(e) < file.exprs.len());
    const ex = &file.exprs;
    var pending: std.ArrayList(Ast.ExprId) = .empty;
    defer pending.deinit(gpa);
    try pending.append(gpa, e);
    while (pending.pop()) |n| {
        if (n == .none) continue;
        switch (ex.tag(n)) {
            // §4.4 access functions, §4.5 analog operators, §4.6 small-signal
            // sources, §5.10 event functions: operating-point reads by construction.
            .branch_access, .port_access, .filter_call, .noise_call, .event_function => return file.str(ex.strOf(n)),
            .sys_call => {
                const name = file.str(ex.strOf(n));
                if (simStateName(name)) return name;
            },
            // §3.4 "constant numbers and previously defined parameters": a module
            // variable is neither, and holds nothing until the analog block runs.
            .ident => for (vars) |v| {
                if (v.name == ex.strOf(n)) return file.str(v.name);
            },
            else => {}, // else: a state read only through its children
        }
        // Pushed last first, so the first child is searched first.
        var buf: [3]Ast.ExprId = undefined;
        const kids = ex.children(n, &buf);
        try pending.ensureUnusedCapacity(gpa, kids.len);
        var k = kids.len;
        while (k > 0) {
            k -= 1;
            pending.appendAssumeCapacity(kids[k]);
        }
    }
    return null;
}

/// Folds `e` over `file`'s expression store, or returns null when it is not
/// constant. Covers literals, the A.2.5 infinities, the unary and binary
/// operators, a lazy `?:`, and §4.3's math functions. `&&` and `||` fold both
/// operands here (`foldSized` short-circuits), so `0 && 1/0` declines.
///
/// `env` answers what the structure cannot, as three methods:
///   leaf(e) ?Const     any tag this walk does not fold itself (an identifier)
///   signed(e) ?bool    an operand's signedness (`>>>`, §4.2.9 comparisons)
///   width(e) ?u32      a name's bit length (§4.2.9 comparisons)
/// `literal_env` answers none of them: a fold over literals only.
/// Out of memory for its pending operators, it answers null, as for an
/// expression that is not constant. Asserts that `e` is `.none` or a row of
/// `file`.
pub fn fold(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) ?Const {
    assert(e == .none or @backingInt(e) < file.exprs.len());
    return foldContext(file, e, env, false, null);
}

/// IEEE §§5.4–5.5: a system-function operand is self-determined, but its
/// type and size propagate into its context-dependent subexpressions.
pub fn foldSized(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) ?Const {
    assert(e == .none or @backingInt(e) < file.exprs.len());
    return foldContext(file, e, env, true, null);
}

// ---- private ----

/// The `$` (and `analysis`) names whose value belongs to a solve: time, the
/// ambient temperature pair, the RNG family, and the analysis type. §9.13's
/// distributions are matched by their two prefixes.
///
/// `$simparam` is deliberately NOT here: §9.15's table is the HOST's, constant
/// for a whole run, and a default reading it is the documented W1050 contract
/// — the field ships as 0 and the host writes it (codegen's "§3.4 a default
/// with no compile-time value is W1050" test pins exactly that shape).
fn simStateName(n: []const u8) bool {
    assert(n.len > 0);
    const names = [_][]const u8{
        "$abstime", "$realtime", "$temperature", "$vt",
        "$random",  "$arandom",  "analysis",
    };
    for (names) |s| if (std.mem.eql(u8, n, s)) return true;
    return std.mem.startsWith(u8, n, "$dist_") or std.mem.startsWith(u8, n, "$rdist_");
}

fn foldContext(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype, sized: bool, parent: ?IntContext) ?Const {
    if (!sized) assert(parent == null);
    const ex = &file.exprs;
    var in_place: [frames_in_place]Frame = undefined;
    var frames: Pending(Frame) = .init(&in_place);
    defer frames.deinit();
    // The row folded next: the root, then each operand an operator asks for.
    var at: Operand = .{ .e = e, .sized = sized, .parent = parent };
    descend: while (true) {
        // Every frame is a distinct ancestor of `at`, in an acyclic store.
        assert(frames.items().len < ex.len());
        if (at.e == .none) return null;
        const plan: ?IntPlan = if (at.sized) intPlan(file, at.e, env, at.parent) else null;
        if (plan) |p| if (!p.supported) return null;
        const first: ?Operand = switch (ex.tag(at.e)) {
            .unary, .binary, .ternary => .{ .e = ex.lhs(at.e), .sized = at.sized, .parent = if (plan) |p| p.operands[0] else null },
            // §4.3 Table 4-14/4-15 math in a constant expression: each
            // argument is folded on its own, unsized.
            .builtin_call => blk: {
                const f = MathFn.fromName(file.str(ex.strOf(at.e))) orelse return null;
                const args = ex.args(at.e);
                if (args.len != f.arity()) return null;
                break :blk .{ .e = args[0], .sized = false, .parent = null };
            },
            else => null, // else: a leaf, folded whole below
        };
        if (first) |o| {
            frames.push(.{ .e = at.e, .plan = plan, .sized = at.sized }) catch return null;
            at = o;
            continue :descend;
        }
        var value = resized(plan, leafValue(file, at.e, env) orelse return null);
        // Hand `value` up until an operator asks for another operand.
        while (frames.items().len > 0) {
            const f = &frames.items()[frames.items().len - 1];
            assert(f.done < f.vals.len);
            f.vals[f.done] = value;
            f.done += 1;
            if (nextOperand(file, f.*)) |o| {
                at = o;
                continue :descend;
            }
            value = resized(f.plan, apply(file, env, f.*) orelse return null);
            _ = frames.pop();
        }
        return value;
    }
}

/// A leaf's value: a literal's, or `env.leaf`'s for every other tag.
fn leafValue(file: *const Ast.SourceFile, e: Ast.ExprId, env: anytype) ?Const {
    const ex = &file.exprs;
    return switch (ex.tag(e)) {
        .int_literal => .{ .int = ex.intValue(e) },
        .logic_literal => .{ .int = ex.logicValue(e).asExactInt() orelse return null },
        .real_literal => .{ .real = ex.realValue(e) },
        .str_literal => .{ .str = file.str(ex.strOf(e)) },
        .pos_inf => .{ .real = std.math.inf(f64) },
        .neg_inf => .{ .real = -std.math.inf(f64) },
        else => env.leaf(e), // else: every other tag names something only the caller can resolve
    };
}

/// `value` converted into its node's context when the node has a plan.
fn resized(plan: ?IntPlan, value: Const) Const {
    var v = value;
    if (v == .int) if (plan) |p| {
        v.int = p.resize(v.int);
    };
    return v;
}

/// The operand frame `f` folds next, or null once it has all it reads:
/// `&&`/`||` stop after a deciding left operand when sized, and `?:` folds
/// only the arm its condition takes (§4.2.12).
fn nextOperand(file: *const Ast.SourceFile, f: Frame) ?Operand {
    const ex = &file.exprs;
    assert(f.done >= 1);
    const ctx = if (f.plan) |p| p.operands else [_]?IntContext{ null, null, null };
    switch (ex.tag(f.e)) {
        .unary => return null,
        .binary => {
            if (f.done == 2) return null;
            const op = ex.binOp(f.e);
            const a = f.vals[0];
            if (f.sized and ((op == .logical_and and !a.isTrue()) or (op == .logical_or and a.isTrue()))) return null;
            return .{ .e = ex.rhs(f.e), .sized = f.sized, .parent = ctx[1] };
        },
        .ternary => {
            if (f.done == 2) return null;
            const taken = f.vals[0].isTrue();
            return .{ .e = if (taken) ex.rhs(f.e) else ex.ternaryElse(f.e), .sized = f.sized, .parent = ctx[if (taken) 1 else 2] };
        },
        .builtin_call => {
            const args = ex.args(f.e);
            return if (f.done < args.len) .{ .e = args[f.done], .sized = false, .parent = null } else null;
        },
        // Only the four tags above push a frame.
        .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf, .ident, .hier_ident, .call, .sys_call, .filter_call, .noise_call, .branch_access, .port_access, .concat, .multi_concat, .assign_pattern, .pattern_repl, .index, .range, .indexed_range, .event_or, .event_posedge, .event_negedge, .event_initial_step, .event_final_step, .event_function, .event_driver_update => unreachable,
    }
}

/// Frame `f`'s value from its folded operands, before its own `resize`.
fn apply(file: *const Ast.SourceFile, env: anytype, f: Frame) ?Const {
    const ex = &file.exprs;
    assert(f.done >= 1);
    const ctx = if (f.plan) |p| p.operands else [_]?IntContext{ null, null, null };
    switch (ex.tag(f.e)) {
        .unary => {
            const op = ex.unOp(f.e);
            return switch (op) {
                .plus, .minus, .logical_not, .bit_not => unary(op, f.vals[0]),
                .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => reduction(ex, op, ex.lhs(f.e), f.vals[0]),
            };
        },
        .binary => {
            var a = f.vals[0];
            // A sized `&&`/`||` its left operand decided.
            if (f.done == 1) return .{ .int = @intFromBool(a.isTrue()) };
            var b = f.vals[1];
            const op = ex.binOp(f.e);
            const compare = op == .eq or op == .neq or op == .case_eq or op == .case_neq or op == .lt or op == .le or op == .gt or op == .ge;
            if (f.sized and a == .int and b == .int) {
                if (op == .shr) if (ctx[0]) |c| {
                    a.int = (IntContext{ .width = c.width, .signed = false }).normalize(a.int);
                };
                if (compare) if (ctx[0]) |c| if (!c.signed and c.width == 64) {
                    a.int ^= std.math.minInt(i64);
                    b.int ^= std.math.minInt(i64);
                };
            } else if (compare and a == .int and b == .int) if (unsignedCompare(file, ex.lhs(f.e), ex.rhs(f.e), env)) |u| {
                a.int = u.extend(.lhs, a.int);
                b.int = u.extend(.rhs, b.int);
            };
            const shift_signed = if (op != .ashr) null else if (f.sized and ctx[0] != null) ctx[0].?.signed else env.signed(ex.lhs(f.e));
            return binary(op, a, b, shift_signed);
        },
        .ternary => {
            assert(f.done == 2);
            return f.vals[1];
        },
        .builtin_call => {
            const m = MathFn.fromName(file.str(ex.strOf(f.e))).?;
            assert(f.done == m.arity());
            return math(m, f.vals[0..f.done]);
        },
        // Only the four tags above push a frame.
        .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf, .ident, .hier_ident, .call, .sys_call, .filter_call, .noise_call, .branch_access, .port_access, .concat, .multi_concat, .assign_pattern, .pattern_repl, .index, .range, .indexed_range, .event_or, .event_posedge, .event_negedge, .event_initial_step, .event_final_step, .event_function, .event_driver_update => unreachable,
    }
}

// ponytail: literal operands only. A parameter's width is 32 unless A.2.1.1's
// `[ range ]` sized it, and an expression's is §5.4's sizing rules; carry a
// width beside `Const` if a model ever reduces either.

/// IEEE 1364-2005 §5.1.11: "The unary reduction operators shall perform a
/// bitwise operation on a single operand to produce a single-bit result", so
/// the answer depends on the operand's width, which a `Const` does not carry.
/// A literal has one: its size, or unsized the width `operandWidth` gives it
/// (§3.2's 32 bits, or 64 when 32 do not hold its value); any other operand,
/// and a size past 64, declines. §4.2.10 bars these operators from the analog
/// block, not from a parameter declaration.
fn reduction(ex: *const Ast.ExprStore, op: Ast.UnaryOp, operand: Ast.ExprId, a: Const) ?Const {
    assert(operand != .none);
    if (a != .int) return null;
    if (ex.tag(operand) != .int_literal) return null;
    const w = literalWidth(ex, operand);
    if (w > 64) return null;
    const mask: u64 = if (w == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(w)) - 1;
    const bits: u64 = @as(u64, @bitCast(a.int)) & mask;
    const r: bool = switch (op) {
        .reduce_and => bits == mask,
        .reduce_nand => bits != mask,
        .reduce_or => bits != 0,
        .reduce_nor => bits == 0,
        .reduce_xor => @popCount(bits) % 2 == 1,
        .reduce_xnor => @popCount(bits) % 2 == 0,
        .plus, .minus, .logical_not, .bit_not => unreachable, // `fold` sends these to `unary`
    };
    return .{ .int = @intFromBool(r) };
}

fn expectInt(want: i64, got: ?Const) !void {
    const c = got orelse return error.TestExpectedEqual;
    try testing.expect(c == .int);
    try testing.expectEqual(want, c.int);
}

fn expectReal(want: f64, got: ?Const) !void {
    const c = got orelse return error.TestExpectedEqual;
    try testing.expect(c == .real);
    try testing.expectEqual(want, c.real);
}

/// Parses `module m; <decls> parameter p = <src>; endmodule` with the real
/// lexer and parser, and returns `p`'s default.
fn testParse(arena: std.mem.Allocator, decls: []const u8, src: []const u8) !TestExpr {
    const text = try arena.print("module m; {s} parameter p = {s}; endmodule\n", .{ decls, src });
    const r = try @import("parser.zig").parseForTest(arena, text);
    try testing.expectEqual(@as(u32, 0), r.bag.err_count);
    const m = r.file.modules[0];
    return .{ .file = r.file, .e = m.params[0].default, .vars = m.vars };
}

fn testFold(arena: std.mem.Allocator, src: []const u8, comptime sized: bool) !?Const {
    const t = try testParse(arena, "", src);
    const env: TestEnv = .{ .file = &t.file };
    return if (sized) foldSized(&t.file, t.e, env) else fold(&t.file, t.e, env);
}

/// `open` `n` times, `leaf`, then `close` `n` times.
fn nested(arena: std.mem.Allocator, open: []const u8, leaf: []const u8, close: []const u8, n: usize) ![]const u8 {
    var src: std.ArrayList(u8) = .empty;
    for (0..n) |_| try src.appendSlice(arena, open);
    try src.appendSlice(arena, leaf);
    for (0..n) |_| try src.appendSlice(arena, close);
    return src.items;
}

test "§3.4.1 parameterValue converts to the declared type; a host card does not impose `integer`'s wrap" {
    try expectReal(3, parameterValue(.real, .{ .int = 3 }));
    try testing.expect(parameterValue(.real, .{ .str = "s" }) == .str);
    try expectInt(3, parameterValue(.integer, .{ .real = 2.5 }));
    try expectInt(1, parameterValue(.integer, .{ .int = 4294967297 }));
    // A real with no integer value stays real, for the caller's diagnostic.
    try testing.expect(parameterValue(.integer, .{ .real = std.math.nan(f64) }) == .real);
    try expectInt(4, parameterValue(.string, .{ .int = 4 }));
    try expectReal(0.5, parameterValue(.unspecified, .{ .real = 0.5 }));
    // 5e9 mod 2^32 = 705032704: an `integer` declaration wraps the card...
    try expectInt(705032704, parameterCardValue(.integer, null, 5e9));
    // ...an inferred integral one keeps the whole value...
    try expectInt(5000000000, parameterCardValue(.unspecified, .{ .int = 1 }, 5e9));
    // ...rounding a fraction as §4.2.1.1 does, unless the default was real.
    try expectInt(3, parameterCardValue(.unspecified, .{ .int = 1 }, 2.5));
    try expectReal(3, parameterCardValue(.unspecified, .{ .real = 1 }, 3));
    try expectReal(3, parameterCardValue(.unspecified, null, 3));
}

test "IntContext.normalize agrees with modular arithmetic at every width" {
    // Oracle: the value modulo 2^width in i128, less 2^width when signed and
    // at or above 2^(width-1).
    var prng = std.Random.DefaultPrng.init(0x0555_0002);
    const random = prng.random();
    for (0..5000) |_| {
        const width = random.intRangeAtMost(u32, 1, 70);
        const signed = random.boolean();
        const value = random.int(i64) >> random.int(u6);
        var want: i128 = value;
        if (width < 64) {
            const m: i128 = @as(i128, 1) << @intCast(width);
            want = @mod(want, m);
            if (signed and want >= @divExact(m, 2)) want -= m;
        }
        try testing.expectEqual(@as(i64, @intCast(want)), (IntContext{ .width = width, .signed = signed }).normalize(value));
    }
    // 4 bits signed holds 15 as -1, then widens unchanged; unsigned, 31 is 15.
    const plan: IntPlan = .{ .result = .{ .width = 8, .signed = true }, .from_width = 4 };
    try testing.expectEqual(@as(i64, -1), plan.resize(15));
    const unsigned: IntPlan = .{ .result = .{ .width = 8, .signed = false }, .from_width = 4 };
    try testing.expectEqual(@as(i64, 15), unsigned.resize(31));
}

test "UnsignedCompare.extend masks each side at its own width and orders 64-bit pairs as u64" {
    const u: UnsignedCompare = .{ .mask = .{ 0xff, null }, .flip = false };
    try testing.expectEqual(@as(i64, 255), u.extend(.lhs, -1));
    try testing.expectEqual(@as(i64, -1), u.extend(.rhs, -1));
    const f: UnsignedCompare = .{ .mask = .{ null, null }, .flip = true };
    try testing.expect(f.extend(.lhs, -1) > f.extend(.rhs, 1));
}

test "fold over parsed constant expressions: literals, operators, a lazy ?:, §4.3 calls and names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try expectInt(3, try testFold(a, "1 + 2", false));
    try expectInt(-2147483648, try testFold(a, "2147483647 + 1", false));
    try expectReal(3, try testFold(a, "1.5 * 2", false));
    try expectInt(1, try testFold(a, "\"ab\" == \"ab\"", false));
    // §4.2.12: only the taken arm has to have a value.
    try expectInt(4, try testFold(a, "1 ? 4 : 1/0", false));
    try expectInt(5, try testFold(a, "0 ? 1/0 : 5", false));
    // `fold` evaluates both operands of `&&`; `foldSized` short-circuits.
    try testing.expect((try testFold(a, "0 && 1/0", false)) == null);
    try expectInt(0, try testFold(a, "0 && 1/0", true));
    try expectInt(1, try testFold(a, "1 || 1/0", true));
    try expectInt(-1, try testFold(a, "a", false));
    try testing.expect((try testFold(a, "zz", false)) == null);
    try expectReal(2, try testFold(a, "sqrt(4.0)", false));
    try testing.expect(std.math.approxEqRel(f64, 8, (try testFold(a, "pow(2, 3)", false)).?.real, 1e-15));
    try expectInt(3, try testFold(a, "abs(-3)", false));
    try expectReal(1, try testFold(a, "min(1, 2.0)", false));
    try expectInt(7, try testFold(a, "max(a, 7)", false));
    try expectInt(255, try testFold(a, "8'hff", false));
    // A four-state literal has no analog value; a wide one with an i64 value does.
    try testing.expect((try testFold(a, "4'b1x01", false)) == null);
    try expectInt(5, try testFold(a, "128'h5", false));
    try expectInt(8, try testFold(a, "-4'sb1000", false));
    // `literal_env` folds literals and declines a name.
    const t = try testParse(a, "", "a + 1");
    try testing.expect(fold(&t.file, t.e, literal_env) == null);
    const lit = try testParse(a, "", "2 * 3");
    try expectInt(6, fold(&lit.file, lit.e, literal_env));
}

test "IEEE 1364-2005 §5.1.11 reductions fold over a literal at its size, or an unsized one's width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, ?i64 };
    for ([_]Case{
        .{ "&4'b1111", 1 },
        .{ "~&4'b1111", 0 },
        .{ "|4'b0000", 0 },
        .{ "~|4'b0000", 1 },
        .{ "^3'b111", 1 },
        .{ "~^3'b111", 0 },
        .{ "&64'hFFFF_FFFF_FFFF_FFFF", 1 },
        .{ "^64'h8000_0000_0000_0001", 0 },
        // Unsized: §3.2's 32 bits, so 15 is not all ones and 2^32-1 is.
        .{ "&15", 0 },
        .{ "~&15", 1 },
        .{ "&4294967295", 1 },
        // 2^32 needs 64 bits (`operandWidth`), and its one bit is set.
        .{ "|4294967296", 1 },
        .{ "&4294967296", 0 },
        // No width to read: a wide literal, or anything but a literal.
        .{ "&65'h1", null },
        .{ "&(1 + 1)", null },
    }) |c| {
        const got = try testFold(a, c[0], false);
        if (c[1]) |want| try expectInt(want, got) else try testing.expect(got == null);
    }
}

test "§4.2.9 a comparison with an unsigned operand compares unsigned values at each operand's own width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // `a` is a signed 32-bit -1: against an unsigned operand it is 2^32-1.
    try expectInt(1, try testFold(a, "a > 40'h0", false));
    try expectInt(1, try testFold(a, "a == 32'hFFFF_FFFF", false));
    try expectInt(1, try testFold(a, "a < 0", false));
    // 8-bit 255 against 2^32-1.
    try expectInt(0, try testFold(a, "u > a", false));
    // A 64-bit unsigned literal orders as a u64.
    try expectInt(1, try testFold(a, "64'hFFFF_FFFF_FFFF_FFFF > 1", false));
    // §5.1.12 `>>>` reads the left operand's signedness from the environment.
    try expectInt(-1, try testFold(a, "a >>> 1", false));
    try expectInt(127, try testFold(a, "u >>> 1", false));
    try expectInt(-1, try testFold(a, "8'shff >>> 1", false));
}

test "foldSized: IEEE §§5.4-5.5 propagate a context's width and signedness into the operands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // 4-bit addition wraps at 4 bits; `fold`'s carrier does not.
    try expectInt(0, try testFold(a, "4'b1111 + 4'b0001", true));
    try expectInt(16, try testFold(a, "4'b1111 + 4'b0001", false));
    try expectInt(0, try testFold(a, "4'sb1111 + 8'sb1", true));
    // -(-8) at 4 signed bits is -8 again.
    try expectInt(-8, try testFold(a, "-4'sb1000", true));
    try expectInt(4, try testFold(a, "4'b1000 >> 1", true));
    try expectInt(-4, try testFold(a, "4'sb1000 >>> 1", true));
    // Both sides become 32-bit unsigned: 255 against 2^32-1.
    try expectInt(0, try testFold(a, "8'hFF == -1", true));
    try expectInt(15, try testFold(a, "1 ? 4'b1111 : 8'h00", true));
    // Arithmetic wider than 32 bits is past the carrier's plan.
    try testing.expect((try testFold(a, "40'h1 + 40'h1", true)) == null);
}

test "operandWidth, clog2Width and clog2Signed size an expression as §2.6.1 and IEEE §5.4-5.5 do" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const W = struct { []const u8, ?u32, ?u32 };
    // Source, operandWidth, clog2Width.
    for ([_]W{
        .{ "4'b1010", 4, 4 },
        .{ "5000000000", 64, 64 },
        .{ "7", 32, 32 },
        .{ "-4'sb1", 32, 4 },
        .{ "~40'h1", 40, 40 },
        .{ "a < 1", 32, 1 },
        .{ "!u", 32, 1 },
        .{ "$realtobits(1.0)", 64, 64 },
        .{ "1 ? 8'h1 : 40'h1", 40, 40 },
        .{ "u", 8, 8 },
        .{ "u + u", 32, 8 },
        .{ "4'b1 + 8'b1", 32, 8 },
        .{ "4'b1 << 3", 32, 4 },
        .{ "u ** 2", 32, 8 },
        .{ "128'h1", 128, 128 },
        .{ "zz", null, null },
    }) |c| {
        const t = try testParse(a, "", c[0]);
        const env: TestEnv = .{ .file = &t.file };
        try testing.expectEqual(c[1], operandWidth(&t.file, t.e, env));
        try testing.expectEqual(c[2], clog2Width(&t.file, t.e, env));
    }
    const S = struct { []const u8, ?bool };
    for ([_]S{
        .{ "4'sb1", true },
        .{ "4'b1", false },
        .{ "4'sb1 + 4'b1", false },
        .{ "4'sb1 << 4'b1", true },
        .{ "1 == 1", false },
        .{ "~4'sb1", true },
        .{ "$realtobits(1.0)", false },
        .{ "$random", true },
        .{ "a", true },
        .{ "1.5", null },
    }) |c| {
        const t = try testParse(a, "", c[0]);
        try testing.expectEqual(c[1], clog2Signed(&t.file, t.e, TestEnv{ .file = &t.file }));
    }
}

test "§3.4 firstStateRead names the first simulation-state or variable read of a default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { []const u8, ?[]const u8 };
    for ([_]Case{
        .{ "x + 1", "x" },
        .{ "$abstime * 2", "$abstime" },
        .{ "1 + $temperature", "$temperature" },
        .{ "$random", "$random" },
        .{ "$dist_normal(1, 2, 3)", "$dist_normal" },
        .{ "$rdist_uniform(1, 2, 3)", "$rdist_uniform" },
        // §9.15's table is the host's, constant for the run.
        .{ "$simparam(\"gmin\")", null },
        .{ "2 * y", null },
        .{ "2 * 3", null },
    }) |c| {
        const t = try testParse(a, "real x;", c[0]);
        const got = try firstStateRead(testing.allocator, &t.file, t.e, t.vars);
        if (c[1]) |want| try testing.expectEqualStrings(want, got.?) else try testing.expect(got == null);
    }
}

test "every walk holds 100,000 levels on a 1 MiB thread: depth costs heap, not native stack" {
    // Oracle: the guard page, and each chain's value worked out by hand. An
    // embedder's thread may have 1 MiB; a walk that recursed once per level
    // overflowed it long before 100,000.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const n = 100_000;
    // `40'd1 | 1 | ... | 1` nests on the left, the others on the right.
    const ors = try testParse(a, "", try nested(a, "", "40'd1", " | 1", n));
    const negs = try testParse(a, "", try nested(a, "-(", "1", ")", n));
    const elses = try testParse(a, "", try nested(a, "0 ? 0 : ", "7", "", n));
    const thens = try testParse(a, "", try nested(a, "1 ? ", "5", " : 0", n));
    const calls = try testParse(a, "", try nested(a, "abs(", "-3", ")", n));
    const sums = try testParse(a, "", try nested(a, "1 + (", "1", ")", n));
    const state = try testParse(a, "", try nested(a, "", "$abstime", " + 1", n));
    // `foldSized` plans each operator over its whole operand (`intPlan`), so
    // its chain is shorter: still far past 1 MiB of recursion.
    const sized = try testParse(a, "", try nested(a, "", "4'b1", " + 4'b1", 5000));
    const Run = struct {
        fn on(t: []const TestExpr, out: *anyerror!void) void {
            out.* = walks(t);
        }
        fn walks(t: []const TestExpr) !void {
            const ors_env: TestEnv = .{ .file = &t[0].file };
            try expectInt(1, fold(&t[0].file, t[0].e, ors_env));
            try testing.expectEqual(@as(?u32, 40), operandWidth(&t[0].file, t[0].e, ors_env));
            try testing.expectEqual(@as(?u32, 40), clog2Width(&t[0].file, t[0].e, ors_env));
            try testing.expectEqual(@as(?bool, false), clog2Signed(&t[0].file, t[0].e, ors_env));
            try testing.expectEqual(@as(?[]const u8, null), try firstStateRead(testing.allocator, &t[0].file, t[0].e, &.{}));
            // An even count of negations.
            try expectInt(1, fold(&t[1].file, t[1].e, literal_env));
            try testing.expectEqual(@as(?bool, true), clog2Signed(&t[1].file, t[1].e, TestEnv{ .file = &t[1].file }));
            try expectInt(7, fold(&t[2].file, t[2].e, literal_env));
            try testing.expectEqual(@as(?u32, 32), clog2Width(&t[2].file, t[2].e, TestEnv{ .file = &t[2].file }));
            try expectInt(5, fold(&t[3].file, t[3].e, literal_env));
            try expectInt(3, fold(&t[4].file, t[4].e, literal_env));
            try expectInt(n + 1, fold(&t[5].file, t[5].e, literal_env));
            try testing.expectEqualStrings("$abstime", (try firstStateRead(testing.allocator, &t[6].file, t[6].e, &.{})).?);
            // 5001 four-bit ones: 5001 mod 16 at four bits, 5001 on the carrier.
            try expectInt(9, foldSized(&t[7].file, t[7].e, TestEnv{ .file = &t[7].file }));
            try expectInt(5001, fold(&t[7].file, t[7].e, literal_env));
        }
    };
    var result: anyerror!void = {};
    const thread = try std.Thread.spawn(.{ .stack_size = 1 << 20 }, Run.on, .{ &[_]TestExpr{ ors, negs, elses, thens, calls, sums, state, sized }, &result });
    thread.join();
    try result;
}
