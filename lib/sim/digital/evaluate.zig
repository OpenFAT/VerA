//! Expressions of the interpreter: an `Ast.ExprId` in the executing scope
//! -> its value, evaluated in its §5.5.2 context (§4.8 reals as their 64
//! bits), or the place an lvalue names right now and the write that lands
//! there. Every read of a variable, net or array element goes through here.
//! Cites: IEEE 1364-2005 §3.5.1, §3.6, §3.9, §4.8.2, §4.9, §5.1.13,
//! §5.1.14, §5.2.1, §5.2.2, §5.5.2, §5.5.3, §9.2, §9.4, §10.4.1, §17.8,
//! §17.11.1 `$clog2`, §17.11.2; VAMS §3.7 wreal, §7.3.6.3 analog probes.
//!
//! The places an lvalue names and the writes that land there are in
//! places.zig, and the real-valued half in real_eval.zig; this file
//! re-exports their names, which the emitter reads as `for_emitter.evaluate`.
//!
//! Contents:
//! - `pub const address`
//! - `pub const indexInt`
//! - `pub const Offset`
//! - `pub const Sel`
//! - `pub const Place`
//! - `pub const selection`
//! - `pub const copyBits`
//! - `pub const assign`
//! - `pub const assignReal`
//! - `pub const assignInt`
//! - `pub const put`
//! - `pub const bitsOf`
//! - `pub const write`
//! - `pub const stringLiteral`
//! - `pub const realLiteral`
//! - `pub const intOfReal`
//! - `pub const evalReal`
//! - `pub fn leaf(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Literal`
//! - `pub fn normalize(a: std.mem.Allocator, value: Int.Literal, ty: Type) Error!Int.Literal`
//! - `pub fn convert(a: std.mem.Allocator, value: Int.Literal, ty: Type) Error!Int.Literal`
//! - `pub fn eval(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, width: u32) Error!Int.Literal`
//! - `pub fn truthOf(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Bit`
//! - `pub fn targetType(self: *Run, e: Ast.ExprId) Error!Type`
//! - `pub fn evalFor(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, target: Type) Error!Int.Literal`
//! - `pub fn convertSlot(self: *Run, a: std.mem.Allocator, slot: u32, target: Type) Error!Int.Literal`
//! - `pub fn convertValue(a: std.mem.Allocator, v: Int.Literal, from_real: bool, target: Type) Error!Int.Literal`
//! - `pub fn evalContext(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, ty: Type) Error!Int.Literal`
//! Expressions of the interpreter: an `Ast.ExprId` in the executing scope
//! -> its value, evaluated in its §5.5.2 context (§4.8 reals as their 64
//! bits), or the place an lvalue names right now and the write that lands
//! there. Every read of a variable, net or array element goes through here.
//! Clauses: IEEE 1364-2005 §3.5.1, §3.6, §3.9, §4.8.2, §4.9, §5.1.13,
//! §5.1.14, §5.2.1, §5.2.2, §5.5.2, §5.5.3, §9.2, §9.4, §10.4.1, §17.8,
//! §17.11.1 `$clog2`, §17.11.2; VAMS §3.7 wreal, §7.3.6.3 analog probes.
const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const compile = @import("compile.zig");
const driver = @import("driver.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const Type = compile.Type;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const exec = @import("exec.zig");
const waiters = @import("waiters.zig");
const places = @import("places.zig");
const real_eval = @import("real_eval.zig");
const readSelect = places.readSelect;
const realOfInt = real_eval.realOfInt;

/// `places.address`.
pub const address = places.address;

/// `places.indexInt`.
pub const indexInt = places.indexInt;

/// `places.Offset`.
pub const Offset = places.Offset;

/// `places.Sel`.
pub const Sel = places.Sel;

/// `places.Place`.
pub const Place = places.Place;

/// `places.selection`.
pub const selection = places.selection;

/// `places.copyBits`.
pub const copyBits = places.copyBits;

/// `places.assign`.
pub const assign = places.assign;

/// `places.assignReal`.
pub const assignReal = places.assignReal;

/// `places.assignInt`.
pub const assignInt = places.assignInt;

/// `places.put`.
pub const put = places.put;

/// `places.bitsOf`.
pub const bitsOf = places.bitsOf;

/// `places.write`.
pub const write = places.write;

/// `real_eval.stringLiteral`.
pub const stringLiteral = real_eval.stringLiteral;

/// `real_eval.realLiteral`.
pub const realLiteral = real_eval.realLiteral;

/// `real_eval.intOfReal`.
pub const intOfReal = real_eval.intOfReal;

/// `real_eval.evalReal`.
pub const evalReal = real_eval.evalReal;

pub fn leaf(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Literal {
    assert(e != .none);
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .ident, .hier_ident => self.values[try self.slot(e)],
        .index => blk: {
            const ty = compile.typeOf(self, e);
            if (try self.indexedArray(e) == null) break :blk try readSelect(self, a, e);
            const at = (try address(self, a, e)) orelse break :blk try filled(a, ty.width, ty.signed, .x);
            break :blk self.values[at];
        },
        .logic_literal => ex.logicValue(e),
        // §3.6 packed ASCII, the first character most significant.
        .str_literal => try stringLiteral(a, self.file.str(ex.strOf(e))),
        .int_literal => blk: {
            const n = ex.intLiteral(e);
            const planes = try a.alloc(u64, 2);
            planes[0] = @bitCast(n.value);
            planes[1] = 0;
            const width = compile.literalWidth(n);
            if (width < 64) planes[0] &= (@as(u64, 1) << @intCast(width)) - 1;
            break :blk .{ .width = width, .signed = n.signed, .sized = n.width != 0, .planes = planes };
        },
        else => unreachable, // else: evalContext sends only these leaves
    };
}

/// `value` in type `ty`. A value already of that type is returned as is,
/// planes and all, so the result may be a variable's storage: a caller that
/// keeps it past the next store copies it (as `claim` and the hold cells do).
pub fn normalize(a: std.mem.Allocator, value: Int.Literal, ty: Type) Error!Int.Literal {
    assert(ty.width != 0);
    assert(value.width != 0);
    if (value.width == ty.width and value.signed == ty.signed) return value;
    var result = value.resize(a, ty.width, if (ty.signed) .sign else .zero) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ZeroSize => unreachable,
    };
    result.signed = ty.signed;
    assert(result.width == ty.width);
    return result;
}

/// An assignment's conversion (§5.5.3): `value` extended by its own
/// signedness or truncated to `ty.width`, then typed `ty`.
pub fn convert(a: std.mem.Allocator, value: Int.Literal, ty: Type) Error!Int.Literal {
    assert(ty.width != 0);
    assert(!ty.real);
    var out = try normalize(a, value, .{ .width = ty.width, .signed = value.signed });
    out.signed = ty.signed;
    assert(out.width == ty.width);
    return out;
}

/// `e` evaluated at least `width` bits wide, in its own signedness: an
/// assignment supplies width only (§5.5.3). `evalContext` propagates both.
pub fn eval(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, width: u32) Error!Int.Literal {
    assert(e != .none);
    var ty = compile.typeOf(self, e);
    // An integral reading of a real is §4.8.2's rounded integer.
    if (ty.real) ty = .{ .width = 64, .signed = true };
    ty.width = @max(ty.width, width);
    assert(ty.width >= width);
    return evalContext(self, a, e, ty);
}

/// A condition's truth (§9.4): a real is true when it is not zero.
pub fn truthOf(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Bit {
    assert(e != .none);
    if (compile.typeOf(self, e).real) return if ((try evalReal(self, a, e)) != 0) .one else .zero;
    const b = (try eval(self, a, e, 0)).truth();
    assert(b != .z); // §5.1.13: a truth value is 0, 1 or x.
    return b;
}

/// The type an assignment to `e` converts its value to: a select's own width,
/// else the variable's type, real included.
pub fn targetType(self: *Run, e: Ast.ExprId) Error!Type {
    assert(e != .none);
    const ex = &self.file.exprs;
    // §9.2 a concatenation: as wide as its operands together, unsigned.
    if (ex.tag(e) == .concat) {
        var width: u32 = 0;
        for (ex.args(e)) |x| width += (try targetType(self, x)).width;
        return .{ .width = width, .signed = false };
    }
    if (ex.tag(e) == .index and try self.indexedArray(e) == null) return .{ .width = compile.typeOf(self, e).width, .signed = false };
    const at = try self.baseSlot(e);
    assert(at < self.values.len);
    return self.slotType(at);
}

/// `e` converted for an assignment to `target` (§5.5.3; §4.8.2 between real
/// and integral).
pub fn evalFor(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, target: Type) Error!Int.Literal {
    assert(e != .none);
    if (target.real) return realLiteral(a, try evalReal(self, a, e));
    const rhs = try eval(self, a, e, target.width);
    assert(rhs.width >= target.width);
    return normalize(a, rhs, .{ .width = target.width, .signed = rhs.signed });
}

/// A slot's value converted for an assignment to `target`.
pub fn convertSlot(self: *Run, a: std.mem.Allocator, slot: u32, target: Type) Error!Int.Literal {
    assert(slot < self.values.len);
    assert(target.real or target.width != 0);
    return convertValue(a, self.values[slot], self.decls.reals.contains(slot), target);
}

/// `v`, a real's 64 bits when `from_real`, converted for an assignment to
/// `target` (§4.8.2: a real rounds to the nearest integer; an integer
/// becomes a real). The result is in `a`, or `v` itself when no change is
/// needed.
pub fn convertValue(a: std.mem.Allocator, v: Int.Literal, from_real: bool, target: Type) Error!Int.Literal {
    assert(v.width != 0);
    assert(target.real or target.width != 0);
    if (target.real) return if (from_real) v else realLiteral(a, realOfInt(v));
    const i = if (from_real) try intOfReal(a, @bitCast(v.values()[0])) else v;
    return normalize(a, i, .{ .width = target.width, .signed = i.signed });
}

/// `e` evaluated in context `ty` (IEEE 1364-2005 §5.5.2): the context reaches
/// the operands before they are evaluated. A one-bit result stops it; its
/// operands get Table 5-22's self-determined or common comparison context.
pub fn evalContext(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, ty: Type) Error!Int.Literal {
    assert(e != .none);
    assert(ty.real or ty.width != 0);
    const ex = &self.file.exprs;
    // §4.8: a real context is a double; a real operand in an integral
    // context is its §4.8.2 rounded integer. A real context comes first: an
    // unsized x or z constant there is §4.8.2's conversion too (its unknown
    // bits are 0), not a fill of the real's 64 bits.
    if (ty.real) return realLiteral(a, try evalReal(self, a, e));
    if (ex.tag(e) == .logic_literal and !ex.logicValue(e).sized) return unsizedFill(a, ex.logicValue(e), ty);
    if (compile.typeOf(self, e).real) return normalize(a, try intOfReal(a, try evalReal(self, a, e)), ty);
    switch (ex.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .ident, .hier_ident, .index => return normalize(a, try leaf(self, a, e), ty),
        .unary => {
            const op = ex.unOp(e);
            switch (op) {
                .plus, .minus, .bit_not => {
                    const value = try evalContext(self, a, ex.lhs(e), ty);
                    return switch (op) {
                        .plus => value,
                        .minus => value.negate(a),
                        .bit_not => value.bitwiseNot(a),
                        else => unreachable, // else: the enclosing arm is these three
                    };
                },
                .logical_not => return scalarContext(a, switch (try truthOf(self, a, ex.lhs(e))) {
                    .one => .zero,
                    .zero => .one,
                    .x, .z => .x,
                }, ty),
                .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => {
                    const value = try eval(self, a, ex.lhs(e), 0);
                    const bit = value.reduce(switch (op) {
                        .reduce_and => .and_bits,
                        .reduce_nand => .nand_bits,
                        .reduce_or => .or_bits,
                        .reduce_nor => .nor_bits,
                        .reduce_xor => .xor_bits,
                        .reduce_xnor => .xnor_bits,
                        else => unreachable, // else: the enclosing arm is the six reductions
                    });
                    return scalarContext(a, bit, ty);
                },
            }
        },
        .binary => {
            const op = ex.binOp(e);
            switch (op) {
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => {
                    const operand_type = compile.common(compile.typeOf(self, ex.lhs(e)), compile.typeOf(self, ex.rhs(e)));
                    if (operand_type.real) {
                        const l = try evalReal(self, a, ex.lhs(e));
                        const r = try evalReal(self, a, ex.rhs(e));
                        const holds = switch (op) {
                            .eq => l == r,
                            .neq => l != r,
                            .lt => l < r,
                            .le => l <= r,
                            .gt => l > r,
                            .ge => l >= r,
                            else => unreachable, // else: infer refuses === on a real
                        };
                        return scalarContext(a, if (holds) .one else .zero, ty);
                    }
                    const lhs = try evalContext(self, a, ex.lhs(e), operand_type);
                    const rhs = try evalContext(self, a, ex.rhs(e), operand_type);
                    const bit = switch (op) {
                        .eq, .neq, .case_eq, .case_neq => lhs.equality(switch (op) {
                            .eq => .equal,
                            .neq => .not_equal,
                            .case_eq => .case_equal,
                            else => .case_not_equal, // else: `!==`, the fourth equality operator
                        }, rhs),
                        else => lhs.relational(switch (op) { // else: the four relational operators
                            .lt => .less,
                            .le => .less_equal,
                            .gt => .greater,
                            else => .greater_equal, // else: `>=`, the fourth relational operator
                        }, rhs),
                    };
                    return scalarContext(a, bit, ty);
                },
                .logical_and, .logical_or => {
                    const truth = try truthOf(self, a, ex.lhs(e));
                    if ((op == .logical_and and truth == .zero) or (op == .logical_or and truth == .one))
                        return scalarContext(a, truth, ty);
                    const rhs = try truthOf(self, a, ex.rhs(e));
                    const lhs_bit = try scalar(a, truth);
                    return scalarContext(a, lhs_bit.logical(if (op == .logical_and) .and_bits else .or_bits, try scalar(a, rhs)), ty);
                },
                .shl, .shr, .ashl, .ashr, .pow => {
                    const lhs = try evalContext(self, a, ex.lhs(e), ty);
                    const rhs = try eval(self, a, ex.rhs(e), 0);
                    if (op == .pow) return lhs.power(a, rhs);
                    return lhs.shift(a, switch (op) {
                        .shl => .left,
                        .shr => .right,
                        .ashl => .arithmetic_left,
                        else => .arithmetic_right, // else: `>>>`, the fourth shift
                    }, rhs);
                },
                .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => {},
            }
            const lhs = try evalContext(self, a, ex.lhs(e), ty);
            const rhs = try evalContext(self, a, ex.rhs(e), ty);
            return switch (op) {
                .add, .sub, .mul, .div, .mod => lhs.arithmetic(a, switch (op) {
                    .add => .add,
                    .sub => .subtract,
                    .mul => .multiply,
                    .div => .divide,
                    else => .remainder, // else: `%`, the fifth arithmetic operator
                }, rhs),
                .bit_and, .bit_or, .bit_xor, .bit_xnor => lhs.bitwise(a, switch (op) {
                    .bit_and => .and_bits,
                    .bit_or => .or_bits,
                    .bit_xor => .xor_bits,
                    else => .xnor_bits, // else: `~^`, the fourth bitwise operator
                }, rhs),
                else => unreachable, // else: every other operator returned above
            };
        },
        .ternary => {
            if (compile.typeOf(self, ex.lhs(e)).real) return switch (try truthOf(self, a, ex.lhs(e))) {
                .one => evalContext(self, a, ex.rhs(e), ty),
                else => evalContext(self, a, ex.ternaryElse(e), ty),
            };
            const condition = try eval(self, a, ex.lhs(e), 0);
            return switch (condition.truth()) {
                .one => evalContext(self, a, ex.rhs(e), ty),
                .zero => evalContext(self, a, ex.ternaryElse(e), ty),
                .x, .z => condition.conditional(a, try evalContext(self, a, ex.rhs(e), ty), try evalContext(self, a, ex.ternaryElse(e), ty)),
            };
        },
        // `infer` resolved every call it typed.
        .sys_call => switch (self.typing.sys_calls[@backingInt(e)].?) {
            .make_signed, .make_unsigned => |cast| {
                var value = try eval(self, a, ex.args(e)[0], 0);
                value.signed = cast == .make_signed;
                return normalize(a, value, ty);
            },
            // §17.8: `$rtoi` truncates toward zero; `$realtobits` is the bits.
            // A value past 32 bits keeps its low 32 (VD-130), and an
            // infinity or a NaN is x; an integral argument converts to real
            // first (`evalReal`).
            .rtoi => {
                const t = @trunc(try evalReal(self, a, ex.args(e)[0]));
                const v = try filled(a, 32, true, .x);
                if (std.math.isFinite(t)) {
                    v.values()[0] = (try intOfReal(a, t)).values()[0] & 0xffff_ffff;
                    v.unknowns()[0] = 0;
                }
                return normalize(a, v, ty);
            },
            .realtobits => {
                const v = try filled(a, 64, false, .zero);
                v.values()[0] = @bitCast(try evalReal(self, a, ex.args(e)[0]));
                return normalize(a, v, ty);
            },
            .time, .stime, .clog2, .test_plusargs, .value_plusargs, .q_full, .fopen, .fgetc, .ungetc, .fgets, .fscanf, .fread, .ftell, .fseek, .rewind, .feof, .ferror, .sscanf, .random, .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => |f| {
                const natural = compile.typeOf(self, e);
                const raw: u64 = switch (f) {
                    .random, .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => @as(u32, @bitCast(try @import("system.zig").random(self, a, f.dist().?, ex.args(e), ex.mainTok(e)))),
                    inline .fopen, .fgetc, .ungetc, .fgets, .fscanf, .fread, .ftell, .fseek, .rewind, .feof, .ferror, .sscanf => |g| @bitCast(try @import("system.zig").fileCall(self, a, @field(@import("system.zig").FileFn, @tagName(g)), ex.args(e))),
                    .q_full => @intCast(try @import("system.zig").queueFull(self, a, ex.args(e))),
                    .time, .stime => blk: {
                        const units = self.timeOf(self.scope).scale.unitsAt(self.scheduler.now);
                        break :blk if (f == .stime) units & 0xffff_ffff else units;
                    },
                    .clog2 => blk: {
                        const n = try eval(self, a, ex.args(e)[0], 0);
                        break :blk integerCeilingLog2(n);
                    },
                    .test_plusargs, .value_plusargs => 0,
                    else => unreachable, // else: the arms around this one
                };
                const planes = try a.alloc(u64, 2);
                planes[0] = if (natural.width >= 64) raw else raw & ((@as(u64, 1) << @intCast(natural.width)) - 1);
                planes[1] = 0;
                const value: Int.Literal = .{ .width = natural.width, .signed = natural.signed, .sized = true, .planes = planes };
                return normalize(a, value, ty);
            },
            .driver_count, .receiver_count, .driver_state, .driver_strength, .driver_next_state, .driver_next_strength, .driver_type => |f| return normalize(a, try driver.eval(self, a, e, driver.of(f).?), ty),
            .user => {
                const natural = compile.typeOf(self, e);
                const v = try filled(a, natural.width, natural.signed, .x);
                try self.host.systf.?.call(self, self.instanceOf(self.scope), ex.mainTok(e), v);
                return normalize(a, v, ty);
            },
            else => unreachable, // else: the real-valued functions left through the real path above
        },
        .concat => {
            // One part per operand at most (a zero replication adds none).
            var parts: std.ArrayList(Int.Literal) = try .initCapacity(a, ex.args(e).len);
            for (ex.args(e)) |arg| {
                if (compile.typeOf(self, arg).width == 0) {
                    // §5.1.14 evaluates the repeated operand once even for
                    // count zero. No zero-width Literal enters value helpers.
                    std.debug.assert(ex.tag(arg) == .multi_concat);
                    _ = try eval(self, a, ex.rhs(arg), 0);
                } else parts.appendAssumeCapacity(try eval(self, a, arg, 0));
            }
            const value = Int.Literal.concatenate(a, parts.items) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ZeroSize, error.Overflow => unreachable, // preflight checked exact widths
            };
            return normalize(a, value, ty);
        },
        .call => {
            const idx = self.routines.base.get(self.instanceOf(self.scope)).? + self.routines.calls.get(e).?;
            return normalize(a, try @import("activations.zig").callSync(self, a, idx, ex.args(e)), ty);
        },
        .multi_concat => {
            const value = try eval(self, a, ex.rhs(e), 0);
            const repeated = value.replicate(a, self.typing.replications.get(.{ .spec = self.specOf(self.scope), .e = e }).?) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ZeroSize, error.Overflow => unreachable, // zero only consumed by .concat above
            };
            return normalize(a, repeated, ty);
        },
        else => unreachable, // else: infer rejects every other form before execution
    }
}

// ---- private ----

/// IEEE 1364-2005 §17.11.1 `$clog2`: every operand bit read as unsigned,
/// whatever the declared signedness. The ceiling is the bit length, minus one
/// exactly for powers of two.
fn integerCeilingLog2(value: Int.Literal) u64 {
    assert(value.width != 0);
    // An x or z operand gives 0, a choice: §17.11.1 does not say.
    if (value.hasUnknown()) return 0;
    var length: u64 = 0;
    var power_of_two = true;
    for (value.values(), 0..) |word, index| {
        if (word == 0) continue;
        if (length != 0 or word & (word - 1) != 0) power_of_two = false;
        length = @as(u64, @intCast(index)) * 64 + 64 - @clz(word);
    }
    assert(length <= @as(u64, value.width));
    return if (length != 0 and power_of_two) length - 1 else length;
}

/// IEEE 1364-2005 §3.5.1 / Table 5-22's note: "if the size of the unsized
/// constant is smaller than the context, and its leftmost bit is x or z, the
/// x or z shall be extended", to the size of the expression, not to 32 bits.
/// The parsed literal already carries the fill up to its own width, so it is
/// its top bit that is replicated; a known top bit extends as usual.
fn unsizedFill(a: std.mem.Allocator, v: Int.Literal, ty: Type) Error!Int.Literal {
    assert(v.width != 0);
    assert(ty.width != 0);
    const top = v.bit(v.width - 1);
    var out = v.resize(a, ty.width, if (top == .x or top == .z or ty.signed) .sign else .zero) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ZeroSize => unreachable,
    };
    out.signed = ty.signed;
    return out;
}

fn scalar(a: std.mem.Allocator, bit: Int.Bit) Error!Int.Literal {
    const out = try filled(a, 1, false, bit);
    assert(out.bit(0) == bit);
    assert(out.width == 1);
    return out;
}

fn scalarContext(a: std.mem.Allocator, bit: Int.Bit, ty: Type) Error!Int.Literal {
    assert(ty.width != 0);
    const out = try normalize(a, try scalar(a, bit), ty);
    assert(out.width == ty.width);
    return out;
}

test "§3.5.1 an unsized x/z constant fills its context, a known top digit does not" {
    try expectRun(
        \\module m;
        \\reg [39:0] w;
        \\initial begin
        \\  w = 'hx; $display("%h", w);
        \\  w = 'hz3; $display("%h", w);
        \\  w = 'h3x; $display("%h", w);
        \\  $display("%b", 'bz);
        \\end
        \\endmodule
    , "xxxxxxxxxx\nzzzzzzzzz3\n000000003x\nzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz\n");
}

test "clog2 scans arbitrary-width unsigned bit patterns" {
    try expectRun(
        \\module m;
        \\reg [64:0] wide;
        \\reg [128:0] wider;
        \\reg signed [128:0] signed_wide;
        \\reg [256:0] many;
        \\initial begin
        \\  wide = 65'd1 << 64;
        \\  wider = 129'd1 << 128;
        \\  signed_wide = wider;
        \\  many = 257'd1 << 256;
        \\  $display("%0d %0d %0d %0d", $clog2(wide), $clog2(wider), $clog2(signed_wide), $clog2(many));
        \\  $display("%0d %0d %0d", $clog2(wide + 65'd1), $clog2(wider + 129'd1), $clog2(many + 257'd1));
        \\  $display("%0d %0d %0d", $clog2(wide - 65'd1), $clog2(wider - 129'd1), $clog2(many - 257'd1));
        \\  $display("%0d %0d %0d %0d", $clog2(257'd0), $clog2(257'd1), $clog2(257'd2), $clog2(257'd3));
        \\  $display("%0d %0d %0d", $clog2(32'shffffffff), $clog2(64'h8000000000000001), $clog2(0) - 1);
        \\end
        \\endmodule
    , "64 128 128 256\n65 129 257\n64 128 256\n0 0 1 2\n32 64 -1\n");
}

test "clog2 limb scan includes every limb and preserves unknown policy" {
    var planes: [10]u64 = @splat(0);
    const value: Int.Literal = .{ .width = 257, .signed = false, .sized = true, .planes = &planes };
    try std.testing.expectEqual(@as(u64, 0), integerCeilingLog2(value));
    for (0..257) |bit| {
        @memset(&planes, 0);
        planes[bit / 64] = @as(u64, 1) << @intCast(bit % 64);
        try std.testing.expectEqual(@as(u64, @intCast(bit)), integerCeilingLog2(value));
        if (bit != 0) {
            planes[0] |= 1;
            try std.testing.expectEqual(@as(u64, @intCast(bit + 1)), integerCeilingLog2(value));
        }
    }
    planes[5] = 1;
    try std.testing.expectEqual(@as(u64, 0), integerCeilingLog2(value));
}

test "digital assignment context extends before operations and preserves X Z" {
    try expectRun(
        \\module example;
        \\reg [7:0] a;
        \\integer i;
        \\initial begin
        \\  a = ~4'b0000; $display("wide %b",a);
        \\  a = 4'sb1000; $display("signed %b",a);
        \\  a = 4'b1000; $display("unsigned %b",a);
        \\  a = 4'b10xz; $display("logic %b",a);
        \\  i = 32'shffffffff; $display("integer %b",i);
        \\end
        \\endmodule
    , "wide 11111111\nsigned 11111000\nunsigned 00001000\nlogic 000010xz\ninteger 11111111111111111111111111111111\n");
}

test "§5.1.9/§5.1.11/§5.1.8 logical, reduction and equality operators over x" {
    // && with a 0 side is 0, || with a 1 side is 1, otherwise x decides x.
    // &1x11 has no 0 (x); &0x11 has one (0); |0x00 has no 1 (x); |1x00 has
    // one (1); ^ over any x is x. == over an x bit in both is x, === compares
    // it (1), and a known differing bit makes == 0.
    try expectRun(
        \\module m;
        \\initial begin
        \\  $display("%b%b%b", 1'bx && 1'b0, 1'bx || 1'b1, 1'bx && 1'b1);
        \\  $display("%b%b%b%b%b", &4'b1x11, &4'b0x11, |4'b0x00, |4'b1x00, ^4'b1x00);
        \\  $display("%b%b%b", 4'b1x00 == 4'b1x00, 4'b1x00 === 4'b1x00, 4'b1x00 == 4'b0x00);
        \\end
        \\endmodule
    , "01x\nx0x1x\nx10\n");
}

test "§4.2.1.4 $signed/$unsigned retype their operand before it is extended; >>> is arithmetic on a signed operand only" {
    // $signed(4'b1111) is -1, extended to 8 bits by sign; $unsigned(4'sb1111)
    // is 15, extended by zero. 8'sb1000_0000 >>> 2 fills with its sign bit;
    // the unsigned operand fills with 0.
    try expectRun(
        \\module m; reg [7:0] r;
        \\initial begin
        \\  r = $signed(4'b1111) + 8'sd0; $display("%b", r);
        \\  r = $unsigned(4'sb1111) + 8'sd0; $display("%b", r);
        \\  r = 8'sb1000_0000 >>> 2; $display("%b", r);
        \\  r = 8'b1000_0000 >>> 2; $display("%b", r);
        \\end
        \\endmodule
    , "11111111\n00001111\n11100000\n00100000\n");
}

test "§5.1.14 a zero replication inside a concatenation contributes no bits" {
    try expectRun("module m; initial $display(\"%b\", {{0{1'b1}}, 2'b10}); endmodule", "10\n");
}

test "§17.2.4.3 a %f conversion into a concatenation rounds to an integer and splits it" {
    // One item matched. 2.5 rounds away from zero to 3 (§4.8.2): {hi, lo}
    // is the 8-bit 3, hi 0 and lo 3.
    try expectRun(
        \\module m; reg [3:0] hi, lo; integer n;
        \\initial begin n = $sscanf("2.5", "%f", {hi, lo}); $display("%0d %0d %0d", n, hi, lo); end
        \\endmodule
    , "1 0 3\n");
}
