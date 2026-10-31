//! A `$sscanf`/`$fscanf` format and its input in, the values each conversion assigns out, stopping at the first mismatch (§17.2.4.3).
//! Cites: IEEE 1364-2005 §17.2.4.3.
//!
//! Contents:
//! - `pub const Scan = struct`
//! - `Scan.Time = struct`
//! - `Scan.Time.scale(t: Time, v: f64) f64`
//! - `Scan.Assign = struct`
//! - `Scan.init(input: ?[]const u8, format: ?[]const u8, outs: usize) Scan`
//! - `Scan.next(self: *Scan) ?Assign`
//! - `pub fn scanCall(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!i64`
//! - `pub fn scanContext(self: *Run, a: std.mem.Allocator, sc: *Scan, outs: []const Ast.ExprId) Error!void`
//! - `pub fn scanAssign(self: *Run, a: std.mem.Allocator, sc: *Scan, outs: []const Ast.ExprId) Error!void`
//! IEEE 1364-2005 §17 system tasks that keep state of their own: a task's
//! argument expressions and the `Run` in; values written to its output
//! arguments (and, for queues, `Run.queues`) out.
//! Clauses: §17.2 file input and output, §17.2.3 string output, §17.5
//! programmable logic arrays, §17.6 stochastic queues, §17.9 distributions.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const waiters = @import("waiters.zig");
const evaluate = @import("evaluate.zig");
const display = @import("display.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const expectRun = @import("root.zig").expectRun;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const wordMask = @import("net.zig").wordMask;
const rng = @import("kernels").rng_kernels;
const queues = @import("queues.zig");
const system = @import("system.zig");
const empty = queues.empty;
const text = system.text;

/// §17.2.4.3 `$sscanf(str, format, args...)`: C's scanf over the characters
/// of `str`. Each `next` is one assignment to an output argument, in order;
/// once it returns null, `result` is how many were assigned, or EOF (-1)
/// when the input ends before the first conversion, and (the clause's own
/// rule) when either `str` or `format` has an x or z bit (null here).
/// A conversion is `%`, an optional `*` (match, do not assign or count), an
/// optional maximum field width, and one of %b %o %d %h %x %c %s %f %e %g.
pub const Scan = struct {
    // ponytail: %v %m stop the scan; add them when a source reads them.
    input: []const u8,
    format: []const u8,
    /// Output arguments the call has.
    outs: usize,
    at: usize = 0,
    i: usize = 0,
    result: i64 = 0,
    done: bool = false,
    /// §17.2.4.3 `%u`/`%z` read "sufficient data from the input to fill the
    /// target reg": each output argument's width in bits. Without one, or
    /// past 64 bits, the conversion stops the scan.
    widths: []const u32 = &.{},
    /// §17.2.4.3 `%t`'s scale; null stops the scan at a `%t`.
    time: ?Time = null,
    /// §17.2.4.3 `%m`'s text, "the current hierarchical path"; null stops
    /// the scan at a `%m`.
    module: ?[]const u8 = null,

    /// `$timeformat`'s units and precision and the module's time unit, all
    /// as the exponents (precision: digits) §17.3.2 gives them.
    pub const Time = struct {
        units: i32,
        precision: u32,
        unit_exp: i32,

        /// "The value matched is then scaled and rounded according to the
        /// current time scale as set by $timeformat": `v` in $timeformat's
        /// units, rounded to its precision, in the module's time unit
        /// (the clause's example: 10.345 at -3, 2 is 10350000.0 in 1ns).
        pub fn scale(t: Time, v: f64) f64 {
            const p: i32 = @intCast(t.precision);
            const e = t.units - p - t.unit_exp;
            // A negative power divides, so -2256 at -3 is the double nearest
            // -2.256 (iverilog's scanf4 compares it with that literal).
            const r = @round(v * std.math.pow(f64, 10, @floatFromInt(p)));
            return if (e < 0) r / std.math.pow(f64, 10, @floatFromInt(-e)) else r * std.math.pow(f64, 10, @floatFromInt(e));
        }
    };

    /// Output argument `arg` (0 = the first after the format) takes a 64-bit
    /// 4-state value (`bits`: value and unknown planes, signed), characters
    /// (`%s`, `%c`) or a real (`%f %e %g`).
    pub const Assign = struct { arg: usize, value: union(enum) { bits: [2]u64, chars: []const u8, real: f64 } };

    /// The scan of `input` by `format`; a null one ends it at once with EOF.
    pub fn init(input: ?[]const u8, format: ?[]const u8, outs: usize) Scan {
        if (input == null or format == null) return .{ .input = "", .format = "", .outs = outs, .result = -1, .done = true };
        return .{ .input = input.?, .format = format.?, .outs = outs };
    }

    fn stop(self: *Scan, eof: bool) ?Assign {
        if (eof and self.result == 0) self.result = -1;
        self.done = true;
        return null;
    }

    /// The next assignment, or null once the scan is over and `result` is
    /// final. Null for good after the first null.
    pub fn next(self: *Scan) ?Assign {
        if (self.done) return null;
        const input = self.input;
        const format = self.format;
        while (self.i < format.len) : (self.i += 1) {
            const c = format[self.i];
            if (std.ascii.isWhitespace(c)) {
                while (self.at < input.len and std.ascii.isWhitespace(input[self.at])) self.at += 1;
                continue;
            }
            if (c != '%' or self.i + 1 == format.len) {
                if (self.at >= input.len) return self.stop(true);
                if (input[self.at] != c) return self.stop(false);
                self.at += 1;
                continue;
            }
            self.i += 1;
            if (format[self.i] == '%') {
                if (self.at >= input.len or input[self.at] != '%') return self.stop(false);
                self.at += 1;
                continue;
            }
            const suppress = format[self.i] == '*';
            if (suppress) self.i += 1;
            var width: usize = 0;
            while (self.i < format.len and std.ascii.isDigit(format[self.i])) : (self.i += 1) width = width *| 10 +| (format[self.i] - '0');
            if (self.i == format.len) return self.stop(false);
            const conv = std.ascii.toLower(format[self.i]);
            // §17.2.4.3 `%m` "Returns the current hierarchical path as a
            // string. Does not read data from the input".
            if (conv == 'm') {
                const m = self.module orelse return self.stop(false);
                self.i += 1;
                if (suppress) continue;
                const arg: usize = @intCast(self.result);
                if (arg >= self.outs) return self.stop(false);
                self.result += 1;
                return .{ .arg = arg, .value = .{ .chars = m } };
            }
            // §17.2.4.3 `%u`/`%z` match binary data, whose bytes may be white space.
            // A field width counts bits, read in whole 32-bit words and
            // the value cut to it (`%16u` reads a word and keeps 16 bits); a
            // suppressed one with none skips one word (iverilog's
            // fscanf_u/fscanf_z, VD-132). Too few bytes left is EOF.
            if (conv == 'u' or conv == 'z') {
                const per: usize = if (conv == 'z') 8 else 4;
                if (suppress) {
                    const words: usize = @max(1, (width + 31) / 32);
                    if (input.len - self.at < words * per) return self.stop(true);
                    self.at += words * per;
                    continue;
                }
                const arg: usize = @intCast(self.result);
                if (arg >= self.widths.len or arg >= self.outs) return self.stop(false);
                const bits = unformatted(input[self.at..], if (width != 0) @intCast(@min(width, 64)) else self.widths[arg], conv == 'z') orelse return self.stop(true);
                self.at += @intCast(bits[2]);
                self.i += 1;
                self.result += 1;
                return .{ .arg = arg, .value = .{ .bits = .{ bits[0], bits[1] } } };
            }
            if (conv != 'c') while (self.at < input.len and std.ascii.isWhitespace(input[self.at])) : (self.at += 1) {};
            if (self.at >= input.len) return self.stop(true);
            // "it extends to the next inappropriate character or until the
            // maximum field width, if one is specified, is exhausted".
            const field = input[self.at..if (width == 0) input.len else @min(input.len, self.at + width)];
            const n, const value: @FieldType(Assign, "value") = switch (conv) {
                'c' => .{ 1, .{ .bits = .{ field[0], 0 } } },
                's' => blk: {
                    const len = std.mem.findAny(u8, field, &std.ascii.whitespace) orelse field.len;
                    break :blk .{ len, .{ .chars = field[0..len] } };
                },
                'd', 'h', 'x', 'o', 'b' => number(field, conv) orelse return self.stop(false),
                'f', 'e', 'g' => float(field) orelse return self.stop(false),
                't' => blk: {
                    const t = self.time orelse return self.stop(false);
                    const n, const v = float(field) orelse return self.stop(false);
                    break :blk .{ n, .{ .real = t.scale(v.real) } };
                },
                else => return self.stop(false),
            };
            self.at += n;
            if (suppress) continue;
            const arg: usize = @intCast(self.result);
            if (arg >= self.outs) return self.stop(false);
            self.i += 1;
            self.result += 1;
            return .{ .arg = arg, .value = value };
        }
        return self.stop(false);
    }

    /// §17.2.4.3 `%u` (`four` false) / `%z` of a `width`-bit target: 32-bit
    /// words, the least significant first, each little-endian (the native
    /// order of every target VerA builds for); a `%z` word is §27.14's
    /// s_vpi_vecval, aval then bval. The value and unknown planes and the
    /// bytes used, or null when `input` ends first or `width` passes 64.
    fn unformatted(input: []const u8, width: u32, four: bool) ?[3]u64 {
        if (width > 64) return null;
        const words: usize = @max(1, (width + 31) / 32);
        const per: usize = if (four) 8 else 4;
        if (input.len < words * per) return null;
        var v: u64 = 0;
        var u: u64 = 0;
        for (0..words) |k| {
            const w = input[k * per ..][0..per];
            v |= @as(u64, std.mem.readInt(u32, w[0..4], .little)) << @intCast(32 * k);
            if (four) u |= @as(u64, std.mem.readInt(u32, w[4..8], .little)) << @intCast(32 * k);
        }
        // The bits past `width` of the last word are dropped (zero-filled).
        if (width != 0 and width < 64) {
            const keep = (@as(u64, 1) << @intCast(width)) - 1;
            v &= keep;
            u &= keep;
        }
        return .{ v, u, words * per };
    }

    /// The characters of `field` one integral conversion matches, and their
    /// value, or null on a matching failure. `%d` is an optional sign and
    /// decimal digits, or a single x, z or ?; the others take their radix's
    /// digits and x, z, ?, which give §3.5.1's bits (an x or z leftmost pads
    /// the value with itself). `_` separates digits in every radix but may
    /// not lead, and `?` reads as x (VD-132, iverilog's scanf4).
    fn number(field: []const u8, conv: u8) ?struct { usize, @FieldType(Assign, "value") } {
        if (field[0] == '_') return null;
        if (conv == 'd') {
            const neg = field[0] == '-';
            const sign: usize = @intFromBool(neg or field[0] == '+');
            if (sign == 0) switch (std.ascii.toLower(field[0])) {
                'x', '?' => return .{ 1, .{ .bits = .{ ~@as(u64, 0), ~@as(u64, 0) } } },
                'z' => return .{ 1, .{ .bits = .{ 0, ~@as(u64, 0) } } },
                else => {},
            };
            var n = sign;
            var acc: u64 = 0;
            while (n < field.len and (std.ascii.isDigit(field[n]) or field[n] == '_')) : (n += 1) {
                if (field[n] != '_') acc = acc *% 10 +% (field[n] - '0');
            }
            if (std.mem.findNone(u8, field[sign..n], "_") == null) return null;
            return .{ n, .{ .bits = .{ if (neg) 0 -% acc else acc, 0 } } };
        }
        const per: u6 = switch (conv) {
            'b' => 1,
            'o' => 3,
            else => 4, // else: 'h' and 'x'
        };
        var n: usize = 0;
        var v: u64 = 0;
        var u: u64 = 0;
        var top: ?[2]u64 = null;
        const ones = (@as(u64, 1) << per) - 1;
        while (n < field.len) : (n += 1) {
            const ch = std.ascii.toLower(field[n]);
            if (ch == '_') continue;
            const digit: [2]u64 = switch (ch) {
                'x', '?' => .{ ones, ones },
                'z' => .{ 0, ones },
                else => .{ (std.fmt.charToDigit(ch, @as(u8, 1) << @intCast(per)) catch break), 0 },
            };
            top = top orelse digit;
            v = v << per | digit[0];
            u = u << per | digit[1];
        }
        const first = top orelse return null;
        // §3.5.1: an unknown leftmost digit pads to the left with itself.
        if (first[1] != 0) {
            var bits: u32 = 0;
            for (field[0..n]) |ch| bits += if (ch == '_') 0 else per;
            if (bits < 64) {
                const pad = ~@as(u64, 0) << @intCast(bits);
                u |= pad;
                if (first[0] != 0) v |= pad;
            }
        }
        return .{ n, .{ .bits = .{ v, u } } };
    }

    /// "Matches a floating point number": C's sign, digits, fraction and
    /// exponent.
    fn float(field: []const u8) ?struct { usize, @FieldType(Assign, "value") } {
        var n: usize = @intFromBool(field[0] == '+' or field[0] == '-');
        var digits: usize = 0;
        while (n < field.len and std.ascii.isDigit(field[n])) : (n += 1) digits += 1;
        if (n < field.len and field[n] == '.') {
            n += 1;
            while (n < field.len and std.ascii.isDigit(field[n])) : (n += 1) digits += 1;
        }
        if (digits == 0) return null;
        // An `e` with no exponent digits after it is a matching failure, as
        // C's scanf, which has consumed it, reports (iverilog's scanf4:
        // "2.ea" matches nothing).
        if (n < field.len and (field[n] == 'e' or field[n] == 'E')) {
            var k = n + 1;
            if (k < field.len and (field[k] == '+' or field[k] == '-')) k += 1;
            if (k == field.len or !std.ascii.isDigit(field[k])) return null;
            while (k < field.len and std.ascii.isDigit(field[k])) k += 1;
            n = k;
        }
        return .{ n, .{ .real = std.fmt.parseFloat(f64, field[0..n]) catch return null } };
    }
};

/// §17.2.4.3 `$sscanf(str, format, args...)` in the interpreter (`Scan`).
pub fn scanCall(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!i64 {
    const input = try text(a, try evaluate.eval(self, a, args[0], 0));
    const format = try text(a, try evaluate.eval(self, a, args[1], 0));
    var sc: Scan = .init(input, format, args.len - 2);
    try scanContext(self, a, &sc, args[2..]);
    try scanAssign(self, a, &sc, args[2..]);
    return sc.result;
}

/// What `%u`/`%z` (the output widths) and `%t` (the time scale) read.
pub fn scanContext(self: *Run, a: std.mem.Allocator, sc: *Scan, outs: []const Ast.ExprId) Error!void {
    const widths = try a.alloc(u32, outs.len);
    for (outs, widths) |e, *w| w.* = (try evaluate.targetType(self, e)).width;
    sc.widths = widths;
    sc.time = .{ .units = self.time.format.units, .precision = self.time.format.precision, .unit_exp = self.timeOf(self.scope).unit_exp };
    var path: std.Io.Writer.Allocating = .init(a);
    const saved = self.out;
    self.out = &path.writer;
    defer self.out = saved;
    try display.emitScope(self);
    sc.module = path.written();
}

/// Writes each value `sc` converts to the next output argument of `outs`.
pub fn scanAssign(self: *Run, a: std.mem.Allocator, sc: *Scan, outs: []const Ast.ExprId) Error!void {
    while (sc.next()) |x| switch (x.value) {
        .bits => |b| {
            const v = try filled(a, 64, true, .zero);
            v.values()[0] = b[0];
            v.unknowns()[0] = b[1];
            try evaluate.assign(self, a, outs[x.arg], v);
        },
        .chars => |c| try evaluate.assign(self, a, outs[x.arg], try evaluate.stringLiteral(a, c)),
        .real => |r| try evaluate.assignReal(self, a, outs[x.arg], r),
    };
}

test "§17.2.4.3 $sscanf: conversions, a mismatch stops, unknown input is EOF" {
    try expectRun(
        \\module m;
        \\integer n, a, b; reg [15:0] w;
        \\initial begin
        \\  n = $sscanf("12 ff z", "%d %h %s", a, b, w); $write("%0d %0d %0d %s ", n, a, b, w);
        \\  n = $sscanf("7-8", "%d+%d", a, b); $write("%0d %0d ", n, a);
        \\  n = $sscanf(16'h31xx, "%d", a); $display("%0d", n);
        \\end
        \\endmodule
        // w is 16 bits: %s shows its leading zero byte as a space (VD-129).
    , "3 12 255  z 1 7 -1\n");
}

test "§17.2.4.3 Scan: %u, %z and %t" {
    // %u: a 32-bit word, little-endian; white space is data, not skipped.
    var u: Scan = .init("\x20\x56\x34\x12", "%u", 1);
    u.widths = &.{32};
    try std.testing.expectEqual([2]u64{ 0x12345620, 0 }, u.next().?.value.bits);
    // %z: aval then bval; z is (0, 1), x is (1, 1).
    var z: Scan = .init("\x01\x00\x00\x00\x03\x00\x00\x00", "%z", 1);
    z.widths = &.{8};
    try std.testing.expectEqual([2]u64{ 1, 3 }, z.next().?.value.bits);
    // Too few bytes for the target is EOF before the first conversion.
    var short: Scan = .init("\x01\x02", "%u", 1);
    short.widths = &.{32};
    try std.testing.expect(short.next() == null);
    try std.testing.expectEqual(@as(i64, -1), short.result);
    // 8.125 at $timeformat(-3, 2) rounds to 8.13ms, 8130000 in 1ns.
    var t: Scan = .init("8.125", "%t", 1);
    t.time = .{ .units = -3, .precision = 2, .unit_exp = -9 };
    try std.testing.expectEqual(@as(f64, 8130000), t.next().?.value.real);
    // With no width or scale the conversion stops the scan.
    var none: Scan = .init("1234", "%u", 1);
    try std.testing.expect(none.next() == null);
}

test "§17.2.4.3 Scan: %u widths and suppression, ? as x, a leading _, an empty exponent, %m (VD-132)" {
    // Oracle: iverilog 13's fscanf_u, fscanf_z and scanf4.
    // `%16u` reads a whole word and keeps 16 bits; `%*u` skips one word.
    var w: Scan = .init("\x78\x56\x34\x12\x01\x00\x00\x00", "%16u%*u", 1);
    w.widths = &.{32};
    try std.testing.expectEqual([2]u64{ 0x5678, 0 }, w.next().?.value.bits);
    try std.testing.expect(w.next() == null);
    try std.testing.expectEqual(@as(i64, 1), w.result);
    // `%*u%u` with one word: the skip leaves too few bytes, EOF.
    var e: Scan = .init("\x01\x00\x00\x00", "%*u%u", 1);
    e.widths = &.{32};
    try std.testing.expect(e.next() == null);
    try std.testing.expectEqual(@as(i64, -1), e.result);
    var q: Scan = .init("1?", "%b", 1);
    try std.testing.expectEqual([2]u64{ 0b11, 0b01 }, q.next().?.value.bits);
    var lead: Scan = .init("_01", "%b", 1);
    try std.testing.expect(lead.next() == null);
    try std.testing.expectEqual(@as(i64, 0), lead.result);
    var exp: Scan = .init("2.ea", "%f", 1);
    try std.testing.expect(exp.next() == null);
    try std.testing.expectEqual(@as(i64, 0), exp.result);
    var m: Scan = .init(" ", "%m", 1);
    m.module = "top.u";
    try std.testing.expectEqualStrings("top.u", m.next().?.value.chars);
    // -2.2566789 under %6t is -2.256 at $timeformat(-9, 3) in 1ns.
    var t: Scan = .init("-2.2566789", "%6t", 1);
    t.time = .{ .units = -9, .precision = 3, .unit_exp = -9 };
    try std.testing.expectEqual(@as(f64, -2.256), t.next().?.value.real);
}

test "§17.2.4.3 Scan: C's conversions over a string" {
    // One call: the assignments `next` gives, then its `result`.
    const S = struct {
        fn bits(input: []const u8, format: []const u8) ![2]u64 {
            var sc: Scan = .init(input, format, 1);
            const x = sc.next() orelse return error.NoAssignment;
            return x.value.bits;
        }
        fn result(input: ?[]const u8, format: ?[]const u8, outs: usize) i64 {
            var sc: Scan = .init(input, format, outs);
            while (sc.next()) |_| {}
            return sc.result;
        }
    };
    try std.testing.expectEqual([2]u64{ @bitCast(@as(i64, -12)), 0 }, try S.bits("  -12", "%d"));
    try std.testing.expectEqual([2]u64{ 255, 0 }, try S.bits("fF", "%x"));
    try std.testing.expectEqual([2]u64{ 5, 0 }, try S.bits("1_01", "%b"));
    try std.testing.expectEqual([2]u64{ 0o17, 0 }, try S.bits("17", "%o"));
    // A maximum field width stops the number.
    try std.testing.expectEqual([2]u64{ 123, 0 }, try S.bits("12345", "%3d"));
    // §3.5.1: an x leftmost pads the value with x; a known digit does not.
    try std.testing.expectEqual([2]u64{ ~@as(u64, 0), ~@as(u64, 0) << 1 }, try S.bits("x1", "%b"));
    try std.testing.expectEqual([2]u64{ 0b11, 0b01 }, try S.bits("1x", "%b"));
    // %d reads one x or z as the whole value.
    try std.testing.expectEqual([2]u64{ 0, ~@as(u64, 0) }, try S.bits("z", "%d"));
    // %c takes the next character, white space included.
    try std.testing.expectEqual([2]u64{ ' ', 0 }, try S.bits(" a", "%c"));
    // The count of assignments; `*` matches without assigning.
    try std.testing.expectEqual(@as(i64, 1), S.result("1 2", "%*d %d", 1));
    try std.testing.expectEqual(@as(i64, 2), S.result("7+8", "%d+%d", 2));
    // A literal that does not match stops the scan with what it assigned.
    try std.testing.expectEqual(@as(i64, 1), S.result("7-8", "%d+%d", 2));
    try std.testing.expectEqual(@as(i64, 0), S.result("b1", "a%d", 1));
    // Input that ends before the first conversion is EOF (-1), and so is
    // an x or z in the string or the format.
    try std.testing.expectEqual(@as(i64, -1), S.result("", "%d", 1));
    try std.testing.expectEqual(@as(i64, -1), S.result("   ", "%d", 1));
    try std.testing.expectEqual(@as(i64, -1), S.result(null, "%d", 1));
    try std.testing.expectEqual(@as(i64, -1), S.result("1", null, 1));
    // More conversions than outputs stop at the outputs.
    try std.testing.expectEqual(@as(i64, 1), S.result("1 2", "%d %d", 1));
    // A literal `%` and the strings.
    try std.testing.expectEqual(@as(i64, 1), S.result("%5", "%%%d", 1));
    {
        var sc: Scan = .init("  ab cd", "%s", 1);
        try std.testing.expectEqualStrings("ab", sc.next().?.value.chars);
        try std.testing.expectEqual(@as(usize, 4), sc.at);
    }
    {
        var sc: Scan = .init("1.5e3x -.25 e5", "%f %g %e", 3);
        try std.testing.expectEqual(@as(f64, 1500), sc.next().?.value.real);
        // The `x` after the number is no part of it, and no format character
        // matches it either.
        try std.testing.expect(sc.next() == null);
        try std.testing.expectEqual(@as(i64, 1), sc.result);
    }
    {
        var sc: Scan = .init("-0.25", "%g", 1);
        try std.testing.expectEqual(@as(f64, -0.25), sc.next().?.value.real);
    }
}
