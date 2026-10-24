//! Expressions of the interpreter: an `Ast.ExprId` in the executing scope
//! -> its value, evaluated in its §5.5.2 context (§4.8 reals as their 64
//! bits), or the place an lvalue names right now and the write that lands
//! there. Every read of a variable, net or array element goes through here.
//! Clauses: IEEE 1364-2005 §3.5.1, §3.6, §3.9, §4.8.2, §4.9, §5.1.13,
//! §5.1.14, §5.2.1, §5.2.2, §5.5.2, §5.5.3, §9.2, §9.4, §10.4.1, §17.8,
//! §17.11.1 `$clog2`, §17.11.2; VAMS §3.7 wreal, §7.3.6.3 analog probes.
const std = @import("std");
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

/// IEEE 1364-2005 §17.11.1 `$clog2`: every operand bit read as unsigned,
/// whatever the declared signedness. The ceiling is the bit length, minus one
/// exactly for powers of two.
fn integerCeilingLog2(value: Int.Literal) u64 {
    // An x or z operand gives 0, a choice: §17.11.1 does not say.
    if (value.hasUnknown()) return 0;
    var length: u64 = 0;
    var power_of_two = true;
    for (value.values(), 0..) |word, index| {
        if (word == 0) continue;
        if (length != 0 or word & (word - 1) != 0) power_of_two = false;
        length = @as(u64, @intCast(index)) * 64 + 64 - @clz(word);
    }
    return if (length != 0 and power_of_two) length - 1 else length;
}

/// §3.9 the element an `.index` names right now, or the whole value a
/// scalar reference names. `null` is an out-of-bounds or X/Z index: it
/// names no storage, so a read of one is X and a write to one is discarded.
pub fn address(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?u32 {
    const ex = &self.file.exprs;
    if (ex.tag(e) != .index) return try self.slot(e);
    const c = self.chainBase(e);
    const base = try self.slot(c.base);
    const arr = self.arrays.get(base).?; // infer proved this is an array
    // §4.9 row-major: the innermost select is the last dimension. Every
    // index is evaluated before an out-of-range one names no element.
    var offset: Offset = .{};
    var inside = true;
    var x = e;
    var k = c.depth;
    while (k != 0) : (x = ex.lhs(x)) {
        k -= 1;
        const at = indexInt(try eval(self, a, ex.rhs(x), 0)) orelse return null;
        inside = offset.add(arr, k, at) and inside;
    }
    return if (inside) base + offset.at else null;
}

/// `value` as an index, read by its own signedness; null when it has an x or
/// z bit or lies outside i64. An unsigned value above maxInt(i64) is null,
/// not wrapped negative, so it can never name an element.
pub fn indexInt(value: Int.Literal) ?i64 {
    return std.math.cast(i64, value.asIndex() orelse return null);
}

/// §4.9 row-major: an element's offset from the array's first, built from
/// its indices innermost dimension first, so an index chain of any depth
/// needs no buffer. `at` stays below the array's element count, a u32.
pub const Offset = struct {
    at: u32 = 0,
    /// The element count of the dimensions already added.
    stride: u64 = 1,

    /// Adds dimension `d`'s index (0 is the outermost). Returns false, and
    /// leaves `at` alone, when it is outside the declared range.
    pub fn add(o: *Offset, arr: @import("root.zig").Array, d: usize, index: i64) bool {
        const span: @import("root.zig").Span = if (d == 0) .{ .low = arr.low, .high = arr.high } else arr.rest[d - 1];
        if (index < span.low or index > span.high) return false;
        o.at += @intCast(o.stride * @as(u64, @intCast(index - span.low)));
        o.stride *= @as(u64, @intCast(span.high - span.low + 1));
        return true;
    }
};

/// IEEE 1364-2005 §5.2.1 a bit- or part-select of a vector, as the bit
/// positions it names: the selected value's bit i is bit `first + i` of the
/// slot, and names no bit where the slot has none.
pub const Sel = struct { first: i64, count: u32 };

/// Where an assignment lands: a whole slot, or a selection of one (§5.2.1).
pub const Place = struct { slot: u32, sel: ?Sel = null };

/// The slot the vector a select `e` selects from lives in right now: a named
/// vector, or the §5.2.2 array element its operand addresses. Null is an
/// element address that names no storage.
fn selectSlot(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?u32 {
    const v = self.file.exprs.lhs(e);
    return if (self.file.exprs.tag(v) == .index) try address(self, a, v) else try self.slot(v);
}

/// The selection an `.index` of a vector makes right now. A bit-select's
/// index and an indexed part-select's base are evaluated; a part-select's
/// bounds and an indexed one's width were folded by `infer`. Null is an x/z
/// index, which names no bit.
pub fn selection(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?Sel {
    const ex = &self.file.exprs;
    const rg = ex.rhs(e);
    const base_slot = try self.baseSlot(ex.lhs(e));
    const range = self.vecRange(base_slot);
    // Storage position of the selected value's least significant bit.
    var first: i64 = undefined;
    var count: u32 = 1;
    switch (ex.tag(rg)) {
        .range => {
            const b = self.part_selects.get(.{ .spec = self.specOf(self.scope), .e = e }).?; // infer folded it
            first = range.position(b.lsb);
            count = @intCast(@abs(b.msb - b.lsb) + 1);
        },
        // §5.2.1: `+:` selects `count` bits "starting at the base and
        // ascending the bit range", `-:` descending; which selected end
        // is least significant follows the vector declaration's direction.
        .indexed_range => {
            count = @intCast(self.part_selects.get(.{ .spec = self.specOf(self.scope), .e = e }).?.msb + 1); // infer folded it
            const base = (try eval(self, a, ex.lhs(rg), 0)).asIndex() orelse return null;
            const p = if (range.msb >= range.lsb) base -| range.lsb else range.lsb -| base;
            first = std.math.lossyCast(i64, if ((range.msb >= range.lsb) == (ex.extraOf(rg) == 0)) p else p -| (count - 1));
        },
        else => first = range.position(indexInt(try eval(self, a, rg, 0)) orelse return null), // else: a bit-select's index
    }
    const width = self.values[base_slot].width;
    if (first >= width or first <= -@as(i64, count)) return null;
    return .{ .first = first, .count = count };
}

/// §5.2.1: the selected bits, x wherever the index is x/z or outside the
/// declared range. A select is unsigned whatever its vector is.
fn readSelect(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Literal {
    const width = compile.typeOf(self, e).width;
    const out = try filled(a, width, false, .x);
    const at = (try selectSlot(self, a, e)) orelse return out;
    const sel = (try selection(self, a, e)) orelse return out;
    const v = self.values[at];
    // The selected positions the vector has; the rest stay x.
    const lo = @max(sel.first, 0);
    const hi = @min(sel.first + @as(i64, sel.count), @as(i64, v.width));
    if (lo < hi) copyBits(out, @intCast(lo - sel.first), v, @intCast(lo), @intCast(hi - lo));
    return out;
}

/// Copies bits [src_lo, src_lo + count) of `src` into bits [dst_lo, dst_lo +
/// count) of `dst`, value and unknown planes alike, leaving `dst`'s other
/// bits alone. Asserts both ranges lie inside their widths. A word at a
/// time: a chunk ends where either side's word does.
pub fn copyBits(dst: Int.Literal, dst_lo: u32, src: Int.Literal, src_lo: u32, count: u32) void {
    std.debug.assert(@as(u64, src_lo) + count <= src.width);
    std.debug.assert(@as(u64, dst_lo) + count <= dst.width);
    const planes = [2][2][]u64{ .{ dst.values(), src.values() }, .{ dst.unknowns(), src.unknowns() } };
    var done: u32 = 0;
    while (done < count) {
        const s = src_lo + done;
        const d = dst_lo + done;
        const n = @min(count - done, 64 - d % 64, 64 - s % 64);
        const mask: u64 = if (n == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(n)) - 1;
        const ds: u6 = @intCast(d % 64);
        for (planes) |p| {
            const bits = (p[1][s / 64] >> @intCast(s % 64)) & mask;
            p[0][d / 64] = (p[0][d / 64] & ~(mask << ds)) | (bits << ds);
        }
        done += n;
    }
}

/// Where `e` lands if written now, or null when it names no storage (an
/// out-of-range or x/z array index, §3.9; an x/z bit index, §5.2.1).
fn place(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?Place {
    const ex = &self.file.exprs;
    if (ex.tag(e) != .index) return .{ .slot = try self.slot(e) };
    if (try self.indexedArray(e) != null) return .{ .slot = (try address(self, a, e)) orelse return null };
    return .{ .slot = (try selectSlot(self, a, e)) orelse return null, .sel = (try selection(self, a, e)) orelse return null };
}

/// Assigns an integral `value` to the lvalue `target` under the assignment
/// rules, as a system task does with an output argument.
pub fn assign(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, value: Int.Literal) Error!void {
    const tt = try targetType(self, target);
    const converted = if (tt.real) try realLiteral(a, realOfInt(value)) else try normalize(a, value, .{ .width = tt.width, .signed = value.signed });
    try put(self, a, target, converted, false, null);
}

/// `assign` of a real, which an integral target takes rounded (§4.8.2).
pub fn assignReal(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, r: f64) Error!void {
    // `put`, as `assign` does: a concatenation target splits the rounded
    // value among its operands (§9.2); `place` alone names one slot.
    const tt = try targetType(self, target);
    try put(self, a, target, try convertValue(a, try realLiteral(a, r), true, tt), false, null);
}

/// `assign` of an integer.
pub fn assignInt(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, v: i64) Error!void {
    const lit = try filled(a, 64, true, .zero);
    lit.values()[0] = @bitCast(v);
    try assign(self, a, target, lit);
}

/// §9.2 writes `value`, converted for `target` (`targetType`), where the
/// lvalue lands now, or queues it as a nonblocking update after `delay`. A
/// concatenation partitions the value among its operands, the last one
/// taking the low bits.
pub fn put(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, value: Int.Literal, nba: bool, delay: ?u64) Error!void {
    const ex = &self.file.exprs;
    if (ex.tag(target) == .concat) {
        var lo: u32 = 0;
        const ops = ex.args(target);
        var k = ops.len;
        while (k != 0) {
            k -= 1;
            const w = (try targetType(self, ops[k])).width;
            try put(self, a, ops[k], try bitsOf(a, value, lo, w), nba, delay);
            lo += w;
        }
        return;
    }
    const p = (try place(self, a, target)) orelse return;
    if (nba) {
        _ = try exec.enqueue(self, .{ .write = .{ .target = p.slot, .value = value, .sel = p.sel } }, delay, true);
    } else try write(self, a, p, value);
}

/// Bits [lo, lo + w) of `v`, unsigned.
pub fn bitsOf(a: std.mem.Allocator, v: Int.Literal, lo: u32, w: u32) Error!Int.Literal {
    const out = try filled(a, w, false, .zero);
    copyBits(out, 0, v, lo, w);
    return out;
}

/// Writes `value` (already converted by `evalFor`) where `p` lands. A selection
/// merges into the value the slot holds now, which for a nonblocking update is
/// when it lands, so two NBAs to different bits both survive. Bits outside the
/// declared range are dropped.
pub fn write(self: *Run, a: std.mem.Allocator, p: Place, value: Int.Literal) Error!void {
    const sel = p.sel orelse return waiters.store(self, p.slot, value.planes);
    const cur = self.values[p.slot];
    const merged = try filled(a, cur.width, cur.signed, .zero);
    @memcpy(merged.planes, cur.planes);
    // The selected positions the slot has; the value's bits for the others
    // are dropped.
    const lo = @max(sel.first, 0);
    const hi = @min(sel.first + @as(i64, sel.count), @as(i64, cur.width));
    if (lo < hi) copyBits(merged, @intCast(lo), value, @intCast(lo - sel.first), @intCast(hi - lo));
    return waiters.store(self, p.slot, merged.planes);
}

fn leaf(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Literal {
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
    if (value.width == ty.width and value.signed == ty.signed) return value;
    var result = value.resize(a, ty.width, if (ty.signed) .sign else .zero) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ZeroSize => unreachable,
    };
    result.signed = ty.signed;
    return result;
}

/// IEEE 1364-2005 §3.5.1 / Table 5-22's note: "if the size of the unsized
/// constant is smaller than the context, and its leftmost bit is x or z, the
/// x or z shall be extended", to the size of the expression, not to 32 bits.
/// The parsed literal already carries the fill up to its own width, so it is
/// its top bit that is replicated; a known top bit extends as usual.
fn unsizedFill(a: std.mem.Allocator, v: Int.Literal, ty: Type) Error!Int.Literal {
    const top = v.bit(v.width - 1);
    var out = v.resize(a, ty.width, if (top == .x or top == .z or ty.signed) .sign else .zero) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ZeroSize => unreachable,
    };
    out.signed = ty.signed;
    return out;
}

/// An assignment's conversion (§5.5.3): `value` extended by its own
/// signedness or truncated to `ty.width`, then typed `ty`.
pub fn convert(a: std.mem.Allocator, value: Int.Literal, ty: Type) Error!Int.Literal {
    var out = try normalize(a, value, .{ .width = ty.width, .signed = value.signed });
    out.signed = ty.signed;
    return out;
}

fn scalar(a: std.mem.Allocator, bit: Int.Bit) Error!Int.Literal {
    return filled(a, 1, false, bit);
}

/// `e` evaluated at least `width` bits wide, in its own signedness: an
/// assignment supplies width only (§5.5.3). `evalContext` propagates both.
pub fn eval(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, width: u32) Error!Int.Literal {
    var ty = compile.typeOf(self, e);
    // An integral reading of a real is §4.8.2's rounded integer.
    if (ty.real) ty = .{ .width = 64, .signed = true };
    ty.width = @max(ty.width, width);
    return evalContext(self, a, e, ty);
}

// ---- reals (IEEE 1364-2005 §4.8, §17.8, §17.11.2) ---------------------------

/// §3.6 `text` as packed ASCII, the first character most significant, in
/// `a`. An empty string is one zero byte wide (`compile.stringWidth`).
pub fn stringLiteral(a: std.mem.Allocator, text: []const u8) Error!Int.Literal {
    const value = try filled(a, compile.stringWidth(text), false, .zero);
    for (text, 0..) |c, i| {
        const shift: u32 = @intCast((text.len - 1 - i) * 8);
        value.values()[shift / 64] |= @as(u64, c) << @intCast(shift % 64);
    }
    return value;
}

/// A real as the 64-bit slot value that holds it.
pub fn realLiteral(a: std.mem.Allocator, r: f64) Error!Int.Literal {
    const out = try filled(a, 64, true, .zero);
    out.values()[0] = @bitCast(r);
    return out;
}

/// §4.8.2 integer-to-real: the value, read by its own signedness, "Individual
/// bits that are x or z in the net or the variable shall be treated as zero".
/// A wider operand converts its low 64 bits, unsigned.
fn realOfInt(v: Int.Literal) f64 {
    // ponytail: the low 64 bits of a wider operand.
    const lo = v.values()[0] & ~v.unknowns()[0];
    if (!v.signed or v.width > 64) return @floatFromInt(lo);
    const shift: u6 = @intCast(64 - v.width);
    return @floatFromInt(@as(i64, @bitCast(lo << shift)) >> shift);
}

/// §4.8.2 real-to-integer: "rounded off to the nearest integer" (35.5 is 36,
/// -1.5 is -2), as a signed value at least 64 bits wide and as wide as the
/// integer needs (2.0**64 is 66 bits), so a wide target takes it whole; a
/// non-finite real has no integer and is x.
pub fn intOfReal(a: std.mem.Allocator, r: f64) Error!Int.Literal {
    const n = @round(r);
    if (!std.math.isFinite(n)) return filled(a, 64, true, .x);
    // -2^63 itself is an i64.
    if (n >= -0x1p63 and n < 0x1p63) {
        const out = try filled(a, 64, true, .zero);
        out.values()[0] = @bitCast(@as(i64, @intFromFloat(n)));
        return out;
    }
    // |n| >= 2^63: an f64 integer is its 53-bit mantissa shifted left.
    const fr = std.math.frexp(@abs(n)); // |n| = fr.significand * 2^fr.exponent
    const mant: u64 = @intFromFloat(std.math.ldexp(fr.significand, 53));
    const shift: u32 = @intCast(fr.exponent - 53);
    const out = try filled(a, @intCast(fr.exponent + 1), true, .zero);
    const v = out.values();
    v[shift / 64] |= mant << @intCast(shift % 64);
    if (shift % 64 != 0 and shift / 64 + 1 < v.len) v[shift / 64 + 1] |= mant >> @intCast(64 - shift % 64);
    if (n < 0) {
        // Two's complement over the whole width; bits above it stay 0.
        var carry: u1 = 1;
        for (v) |*w| {
            const sum = @addWithOverflow(~w.*, @as(u64, carry));
            w.* = sum[0];
            carry = sum[1];
        }
        const top = out.width % 64;
        if (top != 0) v[v.len - 1] &= (@as(u64, 1) << @intCast(top)) - 1;
    }
    return out;
}

/// `e`'s value as a real, converting an integral one (§4.8.2).
pub fn evalReal(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!f64 {
    const ex = &self.file.exprs;
    if (!compile.typeOf(self, e).real) return realOfInt(try eval(self, a, e, 0));
    return switch (ex.tag(e)) {
        .real_literal => ex.realValue(e),
        .ident, .hier_ident => @bitCast((try leaf(self, a, e)).values()[0]),
        .index => blk: {
            const v = try leaf(self, a, e);
            // §5.2.2 supplies x for an invalid array reference. At this
            // real boundary §4.8.2 clears its unknown bits; an actual NaN
            // in a valid real element has no unknown plane and survives.
            break :blk @bitCast(v.values()[0] & ~v.unknowns()[0]);
        },
        // §10.4.1 a real or realtime function: its result variable's bits.
        .call => @bitCast((try exec.callSync(self, a, self.sub_base.get(self.instanceOf(self.scope)).? + self.call_subs.get(e).?, ex.args(e))).values()[0]),
        .unary => switch (ex.unOp(e)) {
            .minus => -(try evalReal(self, a, ex.lhs(e))),
            else => try evalReal(self, a, ex.lhs(e)), // else: `+`, the only other real-valued unary
        },
        .binary => blk: {
            const l = try evalReal(self, a, ex.lhs(e));
            const r = try evalReal(self, a, ex.rhs(e));
            break :blk switch (ex.binOp(e)) {
                .add => l + r,
                .sub => l - r,
                .mul => l * r,
                .div => l / r,
                .pow => std.math.pow(f64, l, r),
                else => unreachable, // else: infer admitted only these real-valued operators
            };
        },
        .ternary => switch (try truthOf(self, a, ex.lhs(e))) {
            .one => try evalReal(self, a, ex.rhs(e)),
            .zero => try evalReal(self, a, ex.ternaryElse(e)),
            // §5.1.13: both arms are evaluated, but a real result under
            // an ambiguous condition is zero, even when the arms agree.
            .x, .z => blk: {
                _ = try evalReal(self, a, ex.rhs(e));
                _ = try evalReal(self, a, ex.ternaryElse(e));
                break :blk 0;
            },
        },
        .sys_call => blk: {
            const f = self.sys_calls[@backingInt(e)].?;
            const args = ex.args(e);
            break :blk switch (f) {
                .realtime => self.timeOf(self.scope).scale.realAt(self.scheduler.now),
                .abstime => @import("../time.zig").secondsAt(self.scheduler.now, self.finest),
                .itor => realOfInt(try eval(self, a, args[0], 0)),
                .bitstoreal => @bitCast((try eval(self, a, args[0], 64)).values()[0]),
                .ln => @log(try evalReal(self, a, args[0])),
                .ln1p => std.math.log1p(try evalReal(self, a, args[0])),
                .expm1 => std.math.expm1(try evalReal(self, a, args[0])),
                .log10 => @log10(try evalReal(self, a, args[0])),
                .exp => @exp(try evalReal(self, a, args[0])),
                .sqrt => @sqrt(try evalReal(self, a, args[0])),
                .floor => @floor(try evalReal(self, a, args[0])),
                .ceil => @ceil(try evalReal(self, a, args[0])),
                .sin => @sin(try evalReal(self, a, args[0])),
                .cos => @cos(try evalReal(self, a, args[0])),
                .tan => @tan(try evalReal(self, a, args[0])),
                .asin => std.math.asin(try evalReal(self, a, args[0])),
                .acos => std.math.acos(try evalReal(self, a, args[0])),
                .atan => std.math.atan(try evalReal(self, a, args[0])),
                .sinh => std.math.sinh(try evalReal(self, a, args[0])),
                .cosh => std.math.cosh(try evalReal(self, a, args[0])),
                .tanh => std.math.tanh(try evalReal(self, a, args[0])),
                .asinh => std.math.asinh(try evalReal(self, a, args[0])),
                .acosh => std.math.acosh(try evalReal(self, a, args[0])),
                .atanh => std.math.atanh(try evalReal(self, a, args[0])),
                .pow => std.math.pow(f64, try evalReal(self, a, args[0]), try evalReal(self, a, args[1])),
                .atan2 => std.math.atan2(try evalReal(self, a, args[0]), try evalReal(self, a, args[1])),
                .hypot => std.math.hypot(try evalReal(self, a, args[0]), try evalReal(self, a, args[1])),
                .driver_delay => try driver.evalReal(self, a, e),
                .user => blk2: {
                    const v = try filled(a, 64, true, .zero);
                    try self.systf.?.call(self, self.instanceOf(self.scope), ex.mainTok(e), v);
                    break :blk2 @bitCast(v.values()[0]);
                },
                else => unreachable, // else: the integral system functions are not real-typed
            };
        },
        // VAMS §7.3.6.3 the analog solution at the promoted digital time.
        .branch_access => blk: {
            const probe = self.probe orelse return self.exprFail(e, "an analog probe needs the mixed-signal kernel");
            const b = ex.rhs(e);
            break :blk try probe(self.probe_ctx, try compile.probeName(self, a, ex.lhs(e)), if (b == .none) null else try compile.probeName(self, a, b));
        },
        else => unreachable, // else: infer types no other form real
    };
}

/// A condition's truth (§9.4): a real is true when it is not zero.
pub fn truthOf(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Bit {
    if (compile.typeOf(self, e).real) return if ((try evalReal(self, a, e)) != 0) .one else .zero;
    return (try eval(self, a, e, 0)).truth();
}

/// The type an assignment to `e` converts its value to: a select's own width,
/// else the variable's type, real included.
pub fn targetType(self: *Run, e: Ast.ExprId) Error!Type {
    const ex = &self.file.exprs;
    // §9.2 a concatenation: as wide as its operands together, unsigned.
    if (ex.tag(e) == .concat) {
        var width: u32 = 0;
        for (ex.args(e)) |x| width += (try targetType(self, x)).width;
        return .{ .width = width, .signed = false };
    }
    if (ex.tag(e) == .index and try self.indexedArray(e) == null) return .{ .width = compile.typeOf(self, e).width, .signed = false };
    const at = try self.baseSlot(e);
    return self.slotType(at);
}

/// `e` converted for an assignment to `target` (§5.5.3; §4.8.2 between real
/// and integral).
pub fn evalFor(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, target: Type) Error!Int.Literal {
    if (target.real) return realLiteral(a, try evalReal(self, a, e));
    const rhs = try eval(self, a, e, target.width);
    return normalize(a, rhs, .{ .width = target.width, .signed = rhs.signed });
}

/// A slot's value converted for an assignment to `target`.
pub fn convertSlot(self: *Run, a: std.mem.Allocator, slot: u32, target: Type) Error!Int.Literal {
    return convertValue(a, self.values[slot], self.reals.contains(slot), target);
}

/// `v`, a real's 64 bits when `from_real`, converted for an assignment to
/// `target` (§4.8.2: a real rounds to the nearest integer; an integer
/// becomes a real). The result is in `a`, or `v` itself when no change is
/// needed.
pub fn convertValue(a: std.mem.Allocator, v: Int.Literal, from_real: bool, target: Type) Error!Int.Literal {
    if (target.real) return if (from_real) v else realLiteral(a, realOfInt(v));
    const i = if (from_real) try intOfReal(a, @bitCast(v.values()[0])) else v;
    return normalize(a, i, .{ .width = target.width, .signed = i.signed });
}

fn scalarContext(a: std.mem.Allocator, bit: Int.Bit, ty: Type) Error!Int.Literal {
    return normalize(a, try scalar(a, bit), ty);
}

/// `e` evaluated in context `ty` (IEEE 1364-2005 §5.5.2): the context reaches
/// the operands before they are evaluated. A one-bit result stops it; its
/// operands get Table 5-22's self-determined or common comparison context.
pub fn evalContext(self: *Run, a: std.mem.Allocator, e: Ast.ExprId, ty: Type) Error!Int.Literal {
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
        .sys_call => switch (self.sys_calls[@backingInt(e)].?) {
            .make_signed, .make_unsigned => |cast| {
                var value = try eval(self, a, ex.args(e)[0], 0);
                value.signed = cast == .make_signed;
                return normalize(a, value, ty);
            },
            // §17.8: `$rtoi` truncates toward zero; `$realtobits` is the bits.
            .rtoi => {
                const t = @trunc(try evalReal(self, a, ex.args(e)[0]));
                const v = try filled(a, 32, true, .x);
                // NaN fails both comparisons; -2^31 itself is an i32.
                if (t >= -0x1p31 and t < 0x1p31) {
                    v.values()[0] = @as(u32, @bitCast(@as(i32, @intFromFloat(t))));
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
                try self.systf.?.call(self, self.instanceOf(self.scope), ex.mainTok(e), v);
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
            const idx = self.sub_base.get(self.instanceOf(self.scope)).? + self.call_subs.get(e).?;
            return normalize(a, try exec.callSync(self, a, idx, ex.args(e)), ty);
        },
        .multi_concat => {
            const value = try eval(self, a, ex.rhs(e), 0);
            const repeated = value.replicate(a, self.replications.get(.{ .spec = self.specOf(self.scope), .e = e }).?) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ZeroSize, error.Overflow => unreachable, // zero only consumed by .concat above
            };
            return normalize(a, repeated, ty);
        },
        else => unreachable, // else: infer rejects every other form before execution
    }
}

// ---- tests ------------------------------------------------------------------

test "§4.8.2 rt's ofRealTo is intOfReal truncated to the target, at every width" {
    const logic = @import("../rt/logic.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const values = [_]f64{
        0,              0.5,               -0.5,              1.5,                -1.5,    2.5,           -2.5,
        0x1p31,         -0x1p31,           0x1p31 - 0.5,      -0x1p31 - 0.5,      0x1p63,  -0x1p63,       0x1p63 - 1024,
        -0x1p63 + 1024, 0x1p63 + 2048,     -0x1p63 - 2048,    0x1p64,             -0x1p64, 0x1p64 + 4096, 0x1p100,
        -0x1p100,       std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64),
    };
    inline for (.{ 1, 32, 63, 64, 65, 128 }) |w| for (values) |r| {
        // As `convertValue` assigns it: the signed integer extended or cut.
        const i = try intOfReal(a, r);
        const want = try normalize(a, i, .{ .width = w, .signed = i.signed });
        const got = logic.wide(logic.ofRealTo(r, w));
        try std.testing.expectEqualSlices(u64, want.values(), &got.v);
        try std.testing.expectEqualSlices(u64, want.unknowns(), &got.x);
    };
}

test copyBits {
    // Oracle: the bit-at-a-time copy it replaced, over random 4-state data at
    // every alignment of both sides up to a few words.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var prng = std.Random.DefaultPrng.init(0xc0b1e5);
    const rand = prng.random();
    for (0..3000) |_| {
        const sw = rand.intRangeAtMost(u32, 1, 200);
        const dw = rand.intRangeAtMost(u32, 1, 200);
        const count = rand.intRangeAtMost(u32, 1, @min(sw, dw));
        const src_lo = rand.intRangeAtMost(u32, 0, sw - count);
        const dst_lo = rand.intRangeAtMost(u32, 0, dw - count);
        const src = try filled(a, sw, false, .zero);
        const got = try filled(a, dw, false, .zero);
        const want = try filled(a, dw, false, .zero);
        for (0..sw) |i| setBit(src, @intCast(i), rand.enumValue(Int.Bit));
        for (0..dw) |i| {
            const b = rand.enumValue(Int.Bit);
            setBit(got, @intCast(i), b);
            setBit(want, @intCast(i), b);
        }
        copyBits(got, dst_lo, src, src_lo, count);
        for (0..count) |i| setBit(want, dst_lo + @as(u32, @intCast(i)), src.bit(src_lo + @as(u32, @intCast(i))));
        try std.testing.expectEqualSlices(u64, want.planes, got.planes);
    }
}

test "§4.8 real variables, conversions, and a VAMS §3.7 wreal" {
    try expectRun(
        \\module m;
        \\real r, s; integer i, j, k; wreal w; integer hits;
        \\assign w = s;
        \\always @(w) hits = hits + 1;
        \\initial begin
        \\  hits = 0; $write("%g ", r);
        \\  r = 35.5; i = r; r = -1.5; j = r; k = $rtoi(-1.5);
        \\  r = 7 / 2 + 0.25; s = 1.0; #1 s = -0.0; #1 s = 0.0; #1 s = -0.0;
        \\  #1 $display("%0d %0d %0d %g %b %0d %.3f", i, j, k, r, r > 3, hits, $sqrt(2.0));
        \\end
        \\endmodule
    , "0 36 -2 -1 3.25 1 2 1.414\n");
}

test "§4.9 a multidimensional array is addressed row-major, one index per dimension" {
    try expectRun(
        \\module m;
        \\reg [3:0] mem [-1:0][2:1][1:0];
        \\integer i, j;
        \\initial begin
        \\  for (i = -1; i <= 0; i = i + 1) for (j = 1; j <= 2; j = j + 1) begin mem[i][j][0] = i + j; mem[i][j][1] = 4'hf; end
        \\  mem[0][3][0] = 4'h9;
        \\  $display("%0d %0d %0d %h %b", mem[-1][1][0], mem[0][2][0], mem[-1][2][0], mem[0][1][1], mem[1][1][0]);
        \\end
        \\endmodule
    , "0 2 1 f xxxx\n");
}

test "§4.9 no dimension count: 17 dimensions (one past the old table) and 100" {
    // `@`/`~`: sixteen `[0:0]`/`[0]` on `w`; `^`/`|`: ninety-eight on `r`.
    const template =
        \\module m; wire w @[0:1]; assign w~[1] = 1'b1; assign w~[0] = 1'b0;
        \\reg [3:0] r [1:0]^[0:2]; integer i;
        \\initial begin i = 2; r[1]|[i] = 4'd7; r[0]|[0] = 4'd1;
        \\#1 $display("%b%b %0d %0d %b", w~[1], w~[0], r[1]|[2], r[0]|[0], r[1]|[3]); end endmodule
    ;
    var src: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer src.deinit();
    for (template) |c| switch (c) {
        '@' => for (0..16) |_| try src.writer.writeAll("[0:0]"),
        '~' => for (0..16) |_| try src.writer.writeAll("[0]"),
        '^' => for (0..98) |_| try src.writer.writeAll("[0:0]"),
        '|' => for (0..98) |_| try src.writer.writeAll("[0]"),
        else => try src.writer.writeByte(c),
    };
    try expectRun(src.written(), "10 7 1 xxxx\n");
}

test "§5.2.1 bit and part selects read and write against the declared range" {
    // Two nonblocking writes to different bits both land (each merges into
    // the value at its own landing), an x index writes nothing, and a
    // part-select of a signed vector is unsigned.
    try expectRun(
        \\module m;
        \\reg [7:0] a; reg [0:3] b; reg signed [3:0] s; reg [15:0] w;
        \\integer i;
        \\initial begin
        \\  a = 0; b = 0; s = -1; i = 1'bx;
        \\  a[1] <= 1; a[6] <= 1; a[i] = 1;
        \\  b[0:1] = 2'b11; a[5:3] = 3'b101;
        \\  w = s[3:0];
        \\  #1 $display("%b %b %b %b %b", a, b, a[7:4], w, a[3]);
        \\end
        \\endmodule
    , "01101010 1100 0110 0000000000001111 1\n");
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

test "§5.2.1 a select partly outside its vector reads x there and writes only the bits inside" {
    // a[9:6] of a [7:0] vector: bits 9 and 8 do not exist (x), 7 and 6 are 1.
    // v is [7:4] = 1010, so v[7]=1 v[6]=0 v[5]=1 v[4]=0. v[2 +: 4] ascends
    // from 2 to 5: {v[5], v[4], v[3], v[2]} = 1 0 x x. Writing 0110 there
    // lands bit 2 (1) in v[4] and bit 3 (0) in v[5]: v = 1001.
    try expectRun(
        \\module m; reg [7:0] a; reg [7:4] v;
        \\initial begin
        \\  a = 8'hff; v = 4'b1010;
        \\  $display("%b %b", a[9:6], v[2 +: 4]);
        \\  v[2 +: 4] = 4'b0110;
        \\  $display("%b", v);
        \\end
        \\endmodule
    , "xx11 10xx\n1001\n");
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

test "§4.8.2 an integer becomes a real with x and z bits as 0; a non-finite real becomes x" {
    // 4'b1x01 reads as 1001 = 9; 4'sb1111 as -1. 1.0/0.0 is infinite, which
    // no integer holds: every bit of i is x (VerA's choice, §4.8.2 is silent).
    try expectRun(
        \\module m; real r; integer i;
        \\initial begin
        \\  r = 4'b1x01; $display("%g", r);
        \\  r = 4'sb1111; $display("%g", r);
        \\  r = 1.0 / 0.0; i = r; $display("%b", i);
        \\end
        \\endmodule
    , "9\n-1\nxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n");
}

test "§5.1.13 a real result under an x condition is 0, even when the arms agree" {
    try expectRun("module m; real r; reg c; initial begin c = 1'bx; r = c ? 1.5 : 1.5; $display(\"%g\", r); end endmodule", "0\n");
}

test "§5.1.14 a zero replication inside a concatenation contributes no bits" {
    try expectRun("module m; initial $display(\"%b\", {{0{1'b1}}, 2'b10}); endmodule", "10\n");
}

test "§3.9 an index past i64 names no element, signed or not" {
    try expectRun(
        \\module m; reg [3:0] mem [0:1];
        \\initial begin mem[0] = 4'h5; $display("%b %b %h", mem[65'h1_0000_0000_0000_0000], mem[64'hffff_ffff_ffff_ffff], mem[0]); end
        \\endmodule
    , "xxxx xxxx 5\n");
}

test "§4.8.2/§5.5.1 a case label meets a real scrutinee as a real" {
    // The label 'bx is integral; against the real r it converts to a real,
    // and §4.8.2 reads each x bit as 0, so it is 0.0 and matches r = 0.0.
    try expectRun(
        \\module m; real r;
        \\initial begin r = 0.0; case (r) 'bx: $display("x"); default: $display("other"); endcase end
        \\endmodule
    , "x\n");
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

test "unpacked array elements are addressed, and an out-of-range index reads X" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg [7:0] mem [5:2];
        \\integer i;
        \\initial begin
        \\  for (i = 2; i < 6; i = i + 1) mem[i] = i * 3;
        \\  mem[1] = 8'hff;
        \\  mem[4] <= 8'h0f;
        \\  $display("%b %b %b", mem[2], mem[5], mem[1]);
        \\  #1 $display("%b %b", mem[4], mem[1'bx]);
        \\  $finish(0);
        \\end
        \\endmodule
    , "00000110 00001111 xxxxxxxx\n00001111 xxxxxxxx\n");
}
