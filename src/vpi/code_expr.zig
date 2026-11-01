//! An expression -> the object it denotes (a declared object found by name)
//! or a new `.code`/`.constant` row: operations, selects, calls, literals and
//! access functions (§11.6.18, §11.6.19).
//! Cites: VAMS-2023 §11.6.18, §11.6.19; IEEE 1364-2005 §5.2.1, §26.6.11,
//! §26.6.19, §26.6.26.
//!
//! Contents:
//! - `pub fn expr(b: *Builder, id: Ast.ExprId) Error!ObjId`
//! - `pub fn exprObj(b: *Builder, id: Ast.ExprId) Error!ObjId`
//! - `pub fn select(b: *Builder, id: Ast.ExprId) Error!ObjId`
//! - `pub fn eventIndexValue(b: *Builder, e: Ast.ExprId) Error!?i64`

const std = @import("std");
const Ast = @import("frontend").Ast;
const code_tables = @import("code_tables.zig");
const schema = @import("schema.zig");
const ObjId = schema.ObjId;
const user = @import("vpi_user.zig");
const Builder = @import("Builder.zig");
const session = @import("session.zig");
const Error = session.Error;
const Prop = schema.Prop;

/// Builds or resolves the object for expression `id`; returns its index,
/// or `none` for `.none` or a form this model does not hold. An object
/// built here remembers `id`, which §26.6.26 b)'s vpiDecompile spells;
/// one resolved by name is the declared object, and keeps none. Asserts
/// that the answer is `none` or a row that exists, and that no row was lost.
pub fn expr(b: *Builder, id: Ast.ExprId) Error!ObjId {
    const before = b.objects.hot.items.len;
    const at = try b.exprObj(id);
    std.debug.assert(b.objects.hot.items.len >= before);
    if (at == ObjId.none) return at;
    std.debug.assert(at.index() < b.objects.hot.items.len);
    const o = b.objects.at(at);
    if ((o.kind == .code or o.kind == .constant) and o.full.len == 0 and o.src_expr == .none) {
        o.src_expr = id;
        o.expr_scope = .of(b.scope);
        o.in_analog = b.analog != null;
    }
    try b.attributes(at, .{ .kind = .expression, .tok = b.file.exprs.mainTok(id) }, false);
    return at;
}

/// The object `expr` answers for `id`, without its decompile source or
/// attributes. Asserts that the answer is `none` or a row that exists, and
/// that building only ever appends rows.
pub fn exprObj(b: *Builder, id: Ast.ExprId) Error!ObjId {
    if (id == .none) return ObjId.none;
    const ex = &b.file.exprs;
    const before = b.objects.hot.items.len;
    const at = try switch (ex.tag(id)) {
        .ident => b.lookup(b.file.str(ex.strOf(id))),
        .hier_ident => blk: {
            const parts = ex.nameParts(id);
            var len: usize = parts.len -| 1;
            for (parts) |p| len += b.file.str(p).len;
            var name: std.ArrayList(u8) = try .initCapacity(b.arena, len);
            for (parts, 0..) |p, k| {
                if (k != 0) name.appendAssumeCapacity('.');
                name.appendSliceAssumeCapacity(b.file.str(p));
            }
            break :blk b.names.get(name.items) orelse b.lookup(name.items);
        },
        // IEEE 1364-2005 §26.6.26 vpiConstType: the base the literal was
        // written in (an unsized one without a base format is decimal,
        // A.8.7 unsigned_number).
        .int_literal => blk: {
            const lit = ex.intLiteral(id);
            break :blk b.constant(.{ .int = lit.value }, if (lit.width == 0) 32 else lit.width, switch (lit.radix) {
                2 => user.vpiBinaryConst,
                8 => user.vpiOctConst,
                16 => user.vpiHexConst,
                else => user.vpiDecConst,
            });
        },
        .real_literal => b.constant(.{ .real = ex.realValue(id) }, 64, user.vpiRealConst),
        .str_literal => b.constant(.{ .str = try b.arena.dupe(u8, b.file.str(ex.strOf(id))) }, 0, user.vpiStringConst),
        .logic_literal => blk: {
            const lit = ex.logicValue(id);
            // A value with no x or z that fits 64 bits is an integer
            // constant; anything else is a constant whose value this
            // model does not carry.
            const known = for (lit.unknowns()) |u| {
                if (u != 0) break false;
            } else true;
            const v = lit.values();
            const fits = v.len == 1 or (v.len > 1 and std.mem.allEqual(u64, v[1..], 0));
            break :blk b.constant(if (known and fits) .{ .int = @bitCast(v[0]) } else null, lit.width, 0);
        },
        .unary => b.operation(code_tables.unaryOp(ex.unOp(id)), &.{ex.lhs(id)}),
        .binary => b.operation(code_tables.binaryOp(ex.binOp(id)), &.{ ex.lhs(id), ex.rhs(id) }),
        .ternary => b.operation(user.vpiConditionOp, &.{ ex.lhs(id), ex.rhs(id), ex.ternaryElse(id) }),
        .concat => b.operation(user.vpiConcatOp, ex.args(id)),
        // §11.6.19 NOTE: "For an operator whose type is vpiMultiConcat,
        // the first operand shall be the multiplier expression." IEEE
        // 1364-2005 §26.6.26 a): "The remaining operands shall be the
        // expressions within the concatenation". A digital parse keeps
        // the braces of that concatenation as a `.concat` of its own,
        // the one element of `rhs`.
        .multi_concat => blk: {
            var inner = ex.rhs(id);
            if (ex.tag(inner) == .concat and ex.args(inner).len == 1 and ex.tag(ex.args(inner)[0]) == .concat) inner = ex.args(inner)[0];
            const one = [1]Ast.ExprId{inner};
            const rest: []const Ast.ExprId = if (ex.tag(inner) == .concat) ex.args(inner) else &one;
            const ops = try b.arena.alloc(Ast.ExprId, 1 + rest.len);
            ops[0] = ex.lhs(id);
            @memcpy(ops[1..], rest);
            break :blk b.operation(user.vpiMultiConcatOp, ops);
        },
        .event_posedge => b.operation(user.vpiPosedgeOp, &.{ex.lhs(id)}),
        .event_negedge => b.operation(user.vpiNegedgeOp, &.{ex.lhs(id)}),
        .event_or => b.operation(user.vpiEventOrOp, &.{ ex.lhs(id), ex.rhs(id) }),
        .index => b.select(id),
        .sys_call, .call => blk: {
            const args = try b.arena.alloc(ObjId, ex.args(id).len);
            for (ex.args(id), args) |a, *arg| arg.* = try b.expr(a);
            const name = b.file.str(ex.strOf(id));
            const sys = ex.tag(id) == .sys_call;
            const func = if (sys) ObjId.none else b.lookupAs(name, .function);
            // IEEE 1364-2005 §26.6.19 func call -> type int: vpiFuncType,
            // the function's (a system function's is computed in property.zig).
            var ftype: ?Prop = null;
            if (func != ObjId.none) for (b.objects.at(func).props) |p| {
                if (p.prop == user.vpiFuncType) ftype = p;
            };
            const at = try b.code(if (sys) user.vpiSysFuncCall else user.vpiFuncCall, if (sys) &.{} else &.{.{ .tag = user.vpiFunction, .to = func }}, &.{.{ .tag = user.vpiArgument, .items = try b.many(args) }}, if (ftype) |p| &.{p} else &.{});
            b.objects.at(at).name = try b.arena.dupe(u8, name);
            b.objects.at(at).in_analog = b.analog != null;
            b.objects.at(at).src_tok = ex.mainTok(id);
            break :blk at;
        },
        // §11.6.19 accessfunc -> branches, discipline.
        .branch_access => blk: {
            var branch = ObjId.none;
            if (b.analog) |an| {
                const first = ex.lhs(id);
                if (ex.tag(first) == .ident and ex.rhs(id) == .none) branch = an.branches.get(b.file.str(ex.strOf(first))) orelse ObjId.none;
            }
            const disc = if (branch != ObjId.none) b.objects.coldOf(branch).disc else ObjId.none;
            const at = try b.code(user.vpiAccessFunc, &.{
                .{ .tag = user.vpiBranch, .to = branch },
                .{ .tag = user.vpiDiscipline, .to = disc },
            }, &.{}, &.{});
            b.objects.at(at).name = try b.arena.dupe(u8, b.file.str(ex.strOf(id)));
            break :blk at;
        },
        // Not modelled: the analog operators and filters, event
        // functions, patterns, infinities. No object.
        .builtin_call, .filter_call, .noise_call, .port_access, .assign_pattern, .pattern_repl, .range, .indexed_range, .pos_inf, .neg_inf, .event_initial_step, .event_final_step, .event_driver_update, .event_function => ObjId.none,
    };
    std.debug.assert(b.objects.hot.items.len >= before);
    std.debug.assert(at == ObjId.none or at.index() < b.objects.hot.items.len);
    return at;
}

/// `base[i]`, `base[msb:lsb]` and `base[i +: w]`: an array element is the
/// memory word or variable select the model already holds (§11.6.18); a
/// bit of a vector is a net bit or reg bit with vpiParent and vpiIndex; a
/// range is §11.6.19's part select, and an IEEE 1364-2005 §5.2.1
/// indexed part-select is §26.6.26's, with its base and width. Asserts
/// that `id` is an `.index` expression and that the chain of selects under
/// it ends within the expression table (the tree has no cycle).
pub fn select(b: *Builder, id: Ast.ExprId) Error!ObjId {
    const ex = &b.file.exprs;
    std.debug.assert(ex.tag(id) == .index);
    var event_base = id;
    var rank: usize = 0;
    while (ex.tag(event_base) == .index) : (event_base = ex.lhs(event_base)) {
        std.debug.assert(rank < ex.len());
        rank += 1;
    }
    if (ex.tag(event_base) == .ident or ex.tag(event_base) == .hier_ident) {
        const array = try b.expr(event_base);
        if (array != ObjId.none and b.objects.at(array).vtype == user.vpiNamedEventArray) {
            const indices = try b.arena.alloc(ObjId, rank);
            const values = try b.arena.alloc(?i64, rank);
            var x = id;
            for (indices, values) |*index, *v| {
                index.* = try b.expr(ex.rhs(x));
                v.* = try b.eventIndexValue(ex.rhs(x));
                x = ex.lhs(x);
            }
            for (b.objects.coldOf(array).members) |member| {
                for (b.objects.at(member).lists) |l| {
                    if (l.tag != user.vpiIndex or l.items.len != rank) continue;
                    const matches = for (l.items, values) |want, have| {
                        if (have == null or have.? != b.objects.at(want).value.?.int) break false;
                    } else true;
                    if (matches) return member;
                }
            }
            const automatic = b.automatic or b.objects.at(array).automatic;
            const at = try b.code(user.vpiNamedEvent, &.{ .{ .tag = user.vpiParent, .to = array }, .{ .tag = user.vpiIndex, .to = indices[0] } }, &.{.{ .tag = user.vpiIndex, .items = indices }}, &.{ .{ .prop = user.vpiArray, .value = 1 }, .{ .prop = user.vpiAutomatic, .value = @intFromBool(automatic) } });
            b.objects.at(at).automatic = automatic;
            (try b.objects.coldFor(at)).event_ref = .{ .expr = id, .scope = b.engine };
            return at;
        }
    }
    const ix = ex.rhs(id);
    const base = try b.expr(ex.lhs(id));
    if (ex.tag(ix) == .indexed_range) {
        const at = try b.code(user.vpiIndexedPartSelect, &.{
            .{ .tag = user.vpiParent, .to = base },
            .{ .tag = user.vpiBaseExpr, .to = try b.expr(ex.lhs(ix)) },
            .{ .tag = user.vpiWidthExpr, .to = try b.expr(ex.rhs(ix)) },
        }, &.{}, &.{.{ .prop = user.vpiIndexedPartSelectType, .value = if (ex.extraOf(ix) == 0) user.vpiPosIndexed else user.vpiNegIndexed }});
        b.objects.at(at).owner = .none;
        return at;
    }
    if (base != ObjId.none) {
        const members = b.objects.coldOf(base).members;
        if (members.len != 0 and ex.tag(ix) == .int_literal) {
            const want = ex.intValue(ix);
            for (members) |m| {
                const c = b.objects.at(m).index;
                if (c == .none) continue;
                if (b.objects.at(c).value.?.int == want) return m;
            }
        }
    }
    if (ex.tag(ix) == .range) {
        const at = try b.code(user.vpiPartSelect, &.{
            .{ .tag = user.vpiParent, .to = base },
            .{ .tag = user.vpiLeftRange, .to = try b.expr(ex.lhs(ix)) },
            .{ .tag = user.vpiRightRange, .to = try b.expr(ex.rhs(ix)) },
        }, &.{}, &.{});
        b.objects.at(at).owner = .none;
        return at;
    }
    const is_net = base != ObjId.none and b.objects.at(base).kind == .net;
    const at = try b.code(if (is_net) user.vpiNetBit else user.vpiRegBit, &.{
        .{ .tag = user.vpiParent, .to = base },
        .{ .tag = user.vpiIndex, .to = try b.expr(ix) },
    }, &.{}, &.{});
    b.objects.at(at).owner = .none;
    return at;
}

/// Constant source selects denote the declared element, including
/// negative bounds and parameter expressions. Use the engine's integer
/// rules; a variable or application function is never evaluated here.
/// Asserts that `e` is an expression and this builder's engine scope is
/// one of the run's.
pub fn eventIndexValue(b: *Builder, e: Ast.ExprId) Error!?i64 {
    std.debug.assert(e != .none);
    const r = b.run orelse return null;
    std.debug.assert(b.engine < r.hier.scopes.items.len);
    return r.vpiConstantIndex(b.arena, b.engine, e) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.NotElaborated;
}
