//! An lvalue and the executing scope in, the place it names right now (slot, element, select) out, and a value written there; a select read against its declared range.
//! Cites: IEEE 1364-2005 §3.9, §4.9, §5.2.1, §5.2.2, §9.2.
//!
//! Contents:
//! - `pub const Offset = struct`
//! - `Offset.add(o: *Offset, arr: @import("root.zig").Array, d: usize, index: i64) bool`
//! - `pub const Sel = struct`
//! - `pub const Place = struct`
//! - `pub fn address(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?u32`
//! - `pub fn indexInt(value: Int.Literal) ?i64`
//! - `pub fn selection(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?Sel`
//! - `pub fn readSelect(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Literal`
//! - `pub fn copyBits(dst: Int.Literal, dst_lo: u32, src: Int.Literal, src_lo: u32, count: u32) void`
//! - `pub fn assign(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, value: Int.Literal) Error!void`
//! - `pub fn assignReal(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, r: f64) Error!void`
//! - `pub fn assignInt(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, v: i64) Error!void`
//! - `pub fn put(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, value: Int.Literal, nba: bool, delay: ?u64) Error!void`
//! - `pub fn bitsOf(a: std.mem.Allocator, v: Int.Literal, lo: u32, w: u32) Error!Int.Literal`
//! - `pub fn write(self: *Run, a: std.mem.Allocator, p: Place, value: Int.Literal) Error!void`
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
const evaluate = @import("evaluate.zig");
const real_eval = @import("real_eval.zig");
const convertValue = evaluate.convertValue;
const eval = evaluate.eval;
const normalize = evaluate.normalize;
const realLiteral = real_eval.realLiteral;
const realOfInt = real_eval.realOfInt;
const targetType = evaluate.targetType;

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

/// §3.9 the element an `.index` names right now, or the whole value a
/// scalar reference names. `null` is an out-of-bounds or X/Z index: it
/// names no storage, so a read of one is X and a write to one is discarded.
pub fn address(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?u32 {
    assert(e != .none);
    assert(self.values.len != 0);
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
    assert(value.width != 0);
    return std.math.cast(i64, value.asIndex() orelse return null);
}

/// The selection an `.index` of a vector makes right now. A bit-select's
/// index and an indexed part-select's base are evaluated; a part-select's
/// bounds and an indexed one's width were folded by `infer`. Null is an x/z
/// index, which names no bit.
pub fn selection(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?Sel {
    assert(e != .none);
    assert(self.file.exprs.tag(e) == .index); // A select is an index expression.
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
    assert(count >= 1);
    return .{ .first = first, .count = count };
}

/// §5.2.1: the selected bits, x wherever the index is x/z or outside the
/// declared range. A select is unsigned whatever its vector is.
pub fn readSelect(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!Int.Literal {
    assert(e != .none);
    assert(self.file.exprs.tag(e) == .index);
    const width = compile.typeOf(self, e).width;
    const out = try filled(a, width, false, .x);
    const at = (try selectSlot(self, a, e)) orelse return out;
    const sel = (try selection(self, a, e)) orelse return out;
    const v = self.values[at];
    // The selected positions the vector has; the rest stay x.
    const lo = @max(sel.first, 0);
    const hi = @min(sel.first + @as(i64, sel.count), @as(i64, v.width));
    if (lo < hi) copyBits(out, @intCast(lo - sel.first), v, @intCast(lo), @intCast(hi - lo));
    assert(out.width == width);
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
    assert(done == count);
}

/// Assigns an integral `value` to the lvalue `target` under the assignment
/// rules, as a system task does with an output argument.
pub fn assign(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, value: Int.Literal) Error!void {
    assert(target != .none);
    assert(value.width != 0);
    const tt = try targetType(self, target);
    const converted = if (tt.real) try realLiteral(a, realOfInt(value)) else try normalize(a, value, .{ .width = tt.width, .signed = value.signed });
    try put(self, a, target, converted, false, null);
}

/// `assign` of a real, which an integral target takes rounded (§4.8.2).
pub fn assignReal(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, r: f64) Error!void {
    assert(target != .none);
    // `put`, as `assign` does: a concatenation target splits the rounded
    // value among its operands (§9.2); `place` alone names one slot.
    const tt = try targetType(self, target);
    try put(self, a, target, try convertValue(a, try realLiteral(a, r), true, tt), false, null);
}

/// `assign` of an integer.
pub fn assignInt(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, v: i64) Error!void {
    assert(target != .none);
    const lit = try filled(a, 64, true, .zero);
    lit.values()[0] = @bitCast(v);
    assert(lit.asInt().? == v);
    try assign(self, a, target, lit);
}

/// §9.2 writes `value`, converted for `target` (`targetType`), where the
/// lvalue lands now, or queues it as a nonblocking update after `delay`. A
/// concatenation partitions the value among its operands, the last one
/// taking the low bits.
pub fn put(self: *Run, a: std.mem.Allocator, target: Ast.ExprId, value: Int.Literal, nba: bool, delay: ?u64) Error!void {
    assert(target != .none);
    assert(value.width != 0);
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
        assert(lo <= value.width);
        return;
    }
    const p = (try place(self, a, target)) orelse return;
    if (nba) {
        _ = try exec.enqueue(self, .{ .write = .{ .target = p.slot, .value = value, .sel = p.sel } }, delay, true);
    } else try write(self, a, p, value);
}

/// Bits [lo, lo + w) of `v`, unsigned.
pub fn bitsOf(a: std.mem.Allocator, v: Int.Literal, lo: u32, w: u32) Error!Int.Literal {
    assert(w != 0);
    assert(@as(u64, lo) + w <= v.width);
    const out = try filled(a, w, false, .zero);
    copyBits(out, 0, v, lo, w);
    assert(out.width == w);
    return out;
}

/// Writes `value` (already converted by `evalFor`) where `p` lands. A selection
/// merges into the value the slot holds now, which for a nonblocking update is
/// when it lands, so two NBAs to different bits both survive. Bits outside the
/// declared range are dropped.
pub fn write(self: *Run, a: std.mem.Allocator, p: Place, value: Int.Literal) Error!void {
    assert(p.slot < self.values.len);
    assert(value.width != 0);
    const sel = p.sel orelse return waiters.store(self, p.slot, value.planes);
    const cur = self.values[p.slot];
    const merged = try filled(a, cur.width, cur.signed, .zero);
    assert(merged.planes.len == cur.planes.len);
    @memcpy(merged.planes, cur.planes);
    // The selected positions the slot has; the value's bits for the others
    // are dropped.
    const lo = @max(sel.first, 0);
    const hi = @min(sel.first + @as(i64, sel.count), @as(i64, cur.width));
    if (lo < hi) copyBits(merged, @intCast(lo), value, @intCast(lo - sel.first), @intCast(hi - lo));
    return waiters.store(self, p.slot, merged.planes);
}

// ---- private ----

/// The slot the vector a select `e` selects from lives in right now: a named
/// vector, or the §5.2.2 array element its operand addresses. Null is an
/// element address that names no storage.
fn selectSlot(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?u32 {
    assert(e != .none);
    assert(self.file.exprs.tag(e) == .index);
    const v = self.file.exprs.lhs(e);
    return if (self.file.exprs.tag(v) == .index) try address(self, a, v) else try self.slot(v);
}

/// Where `e` lands if written now, or null when it names no storage (an
/// out-of-range or x/z array index, §3.9; an x/z bit index, §5.2.1).
fn place(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?Place {
    assert(e != .none);
    const ex = &self.file.exprs;
    if (ex.tag(e) != .index) return .{ .slot = try self.slot(e) };
    if (try self.indexedArray(e) != null) return .{ .slot = (try address(self, a, e)) orelse return null };
    return .{ .slot = (try selectSlot(self, a, e)) orelse return null, .sel = (try selection(self, a, e)) orelse return null };
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

test "§3.9 an index past i64 names no element, signed or not" {
    try expectRun(
        \\module m; reg [3:0] mem [0:1];
        \\initial begin mem[0] = 4'h5; $display("%b %b %h", mem[65'h1_0000_0000_0000_0000], mem[64'hffff_ffff_ffff_ffff], mem[0]); end
        \\endmodule
    , "xxxx xxxx 5\n");
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
