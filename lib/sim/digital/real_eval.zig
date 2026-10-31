//! A real-typed expression in, its binary64 value out, and the §4.8.2 conversions between reals and integers.
//! Cites: IEEE 1364-2005 §4.8, §4.8.2, §5.1.13, §17.8; VAMS §3.7 wreal, §7.3.6.3 analog probes.
//!
//! Contents:
//! - `pub fn stringLiteral(a: std.mem.Allocator, text: []const u8) Error!Int.Literal`
//! - `pub fn realLiteral(a: std.mem.Allocator, r: f64) Error!Int.Literal`
//! - `pub fn realOfInt(v: Int.Literal) f64`
//! - `pub fn intOfReal(a: std.mem.Allocator, r: f64) Error!Int.Literal`
//! - `pub fn evalReal(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!f64`
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
const places = @import("places.zig");
const assign = places.assign;
const eval = evaluate.eval;
const leaf = evaluate.leaf;
const normalize = evaluate.normalize;
const truthOf = evaluate.truthOf;
const write = places.write;

/// §3.6 `text` as packed ASCII, the first character most significant, in
/// `a`. An empty string is one zero byte wide (`compile.stringWidth`).
pub fn stringLiteral(a: std.mem.Allocator, text: []const u8) Error!Int.Literal {
    assert(text.len <= std.math.maxInt(u32) / 8);
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
    assert(out.width == 64);
    return out;
}

/// §4.8.2 integer-to-real: the value, read by its own signedness, "Individual
/// bits that are x or z in the net or the variable shall be treated as zero".
/// A wider operand converts whole (`logic.wordsToReal`).
pub fn realOfInt(v: Int.Literal) f64 {
    assert(v.width != 0);
    assert(v.planes.len >= 2);
    const lo = v.values()[0] & ~v.unknowns()[0];
    if (v.width > 64) return @import("../rt/logic/root.zig").wordsToReal(v.values(), v.unknowns(), v.width, v.signed);
    if (!v.signed) return @floatFromInt(lo);
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
        assert(out.width == 64);
        return out;
    }
    // |n| >= 2^63: an f64 integer is its 53-bit mantissa shifted left.
    const fr = std.math.frexp(@abs(n)); // |n| = fr.significand * 2^fr.exponent
    const mant: u64 = @intFromFloat(std.math.ldexp(fr.significand, 53));
    assert(fr.exponent >= 64); // |n| >= 2^63.
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
    assert(e != .none);
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
        .call => @bitCast((try @import("activations.zig").callSync(self, a, self.sub_base.get(self.instanceOf(self.scope)).? + self.call_subs.get(e).?, ex.args(e))).values()[0]),
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
                .itor => if (compile.typeOf(self, args[0]).real)
                    @import("../rt/logic/root.zig").itorReal(try evalReal(self, a, args[0]))
                else
                    realOfInt(try eval(self, a, args[0], 0)),
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
                    try self.host.systf.?.call(self, self.instanceOf(self.scope), ex.mainTok(e), v);
                    break :blk2 @bitCast(v.values()[0]);
                },
                else => unreachable, // else: the integral system functions are not real-typed
            };
        },
        // VAMS §7.3.6.3 the analog solution at the promoted digital time.
        .branch_access => blk: {
            const probe = self.analog.probe orelse return self.exprFail(e, "an analog probe needs the mixed-signal kernel");
            const b = ex.rhs(e);
            break :blk try probe(self.analog.probe_ctx, try compile.probeName(self, a, ex.lhs(e)), if (b == .none) null else try compile.probeName(self, a, b));
        },
        else => unreachable, // else: infer types no other form real
    };
}

test "§4.8.2 rt's ofRealTo is intOfReal truncated to the target, at every width" {
    const logic = @import("../rt/logic/root.zig");
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

test "§4.8.2/§5.5.1 a case label meets a real scrutinee as a real" {
    // The label 'bx is integral; against the real r it converts to a real,
    // and §4.8.2 reads each x bit as 0, so it is 0.0 and matches r = 0.0.
    try expectRun(
        \\module m; real r;
        \\initial begin r = 0.0; case (r) 'bx: $display("x"); default: $display("other"); endcase end
        \\endmodule
    , "x\n");
}
