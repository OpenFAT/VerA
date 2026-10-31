//! One §17.1 operand of the emitted `$display` in, its text on the
//! transcript out, in `vera --run`'s words (`kernels.fmt`, digital/display.zig).
//! Cites: IEEE 1364-2005 §17.1.1.2 to §17.1.1.7, §17.3, §9.4.7.
//!
//! Contents:
//! - `pub const Buffers = struct`
//! - `pub fn capture(self: *State) void`
//! - `pub fn captured(self: *State) []const u8`
//! - `pub fn chars(a: std.mem.Allocator, v: anytype, comptime w: u32) Error!?[]const u8`
//! - `pub fn setChars(self: *State, off: u32, comptime w: u32, bytes: []const u8) void`
//! - `pub fn literal(buf: []u64, w: u32, signed: bool) Int.Literal`
//! - `pub fn zeroBegin(self: *State) void`
//! - `pub fn zeroEnd(self: *State, f: display.Fill) Error!void`
//! - `pub fn value(self: *State, a: anytype, w: u32, signed: bool, radix: fmt.Radix, width: ?u64, zero: bool) Error!void`
//! - `pub fn realValue(self: *State, r: f64, radix: fmt.Radix, width: ?u64) Error!void`
//! - `pub fn time(self: *State, a: anytype, w: u32, signed: bool, unit_exp: i32, width: ?u64, precision: i64) Error!void`
//! - `pub fn timeReal(self: *State, v: f64, unit_exp: i32, width: ?u64, precision: i64) Error!void`
//! - `pub fn real(self: *State, r: f64, conv: u8, flags: u8, precision: i64, width: ?u64) Error!void`
//! - `pub fn netStrength(self: *State, k: u32) Error!void`
//! - `pub fn strongStrength(self: *State, a: anytype, w: u32) Error!void`
//! - `pub fn text(self: *State, a: anytype, w: u32, char: bool, width: ?u64) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const fmt = @import("kernels").fmt;
const Int = @import("kernels").Integer;
const display = @import("../digital/display.zig");
const system = @import("../digital/system.zig");
const State = @import("State.zig");
const design = @import("design.zig");
const logic = @import("logic/root.zig");
const Error = design.Error;
const one_slot = design.one_slot;
const W = logic.W;
const quietState = State.quietState;
const testing = std.testing;

/// A native run's transcript buffers, out of line from the hot `State`
/// fields: the stdout writer and its buffer, the sink the transcript goes to
/// (stdout unless redirected), a `capture`'s buffer, and a '0'-flag field in
/// progress (`zeroBegin`): where `out` pointed, and the field's text.
pub const Buffers = struct {
    stdout: std.Io.File.Writer,
    sink: *std.Io.Writer,
    /// `capture`'s buffer, and `scan`'s characters.
    cap: std.Io.Writer.Allocating,
    zero_out: ?*std.Io.Writer = null,
    zero_field: std.Io.Writer.Allocating = undefined,
    buf: [1 << 16]u8,
};

/// Everything printed until `captured` or `fshow` goes to a buffer.
pub fn capture(self: *State) void {
    assert(self.out == self.buffers.sink); // Captures do not nest.
    self.buffers.cap.clearRetainingCapacity();
    self.out = &self.buffers.cap.writer;
    assert(self.buffers.cap.written().len == 0);
}

/// Ends a `capture`: the bytes printed since, valid until the next one.
pub fn captured(self: *State) []const u8 {
    assert(self.out == &self.buffers.cap.writer); // Pair of `capture`.
    self.out = self.buffers.sink;
    return self.buffers.cap.written();
}

/// `system.text` of a `w`-bit value.
pub fn chars(a: std.mem.Allocator, v: anytype, comptime w: u32) Error!?[]const u8 {
    comptime assert(w >= 1);
    var buf = logic.planesOf(v);
    comptime assert(buf.len == 2 * logic.words(w));
    return system.text(a, literal(&buf, w, false)) catch error.OutOfMemory;
}

/// The characters `bytes` in the `w`-bit cell at word `off`, the last
/// one in the low byte, truncated or zero-filled on the left.
pub fn setChars(self: *State, off: u32, comptime w: u32, bytes: []const u8) void {
    comptime assert(w >= 1);
    const n = comptime logic.words(w);
    assert(off + n <= self.v.len);
    const v = self.v[off..][0..n];
    @memset(v, 0);
    @memset(self.x[off..][0..n], 0);
    for (0..@min(bytes.len, n * 8)) |k| v[k / 8] |= @as(u64, bytes[bytes.len - 1 - k]) << @intCast(8 * (k % 8));
    v[n - 1] &= logic.mask(w - 64 * (n - 1));
    assert(v[n - 1] & ~logic.mask(w - 64 * (n - 1)) == 0);
}

/// `a`'s planes as the `Literal` the interpreter formats.
pub fn literal(buf: []u64, w: u32, signed: bool) Int.Literal {
    assert(w >= 1);
    assert(buf.len >= 2 * logic.words(w));
    return .{ .width = w, .signed = signed, .sized = true, .planes = buf };
}

/// The next field is a `%05d`/`%04t`: written aside until `zeroEnd`
/// (`display.zeroFilled`, the interpreter's rule).
pub fn zeroBegin(self: *State) void {
    assert(self.buffers.zero_out == null); // Zero-filled fields do not nest.
    self.buffers.zero_field = .init(self.gpa);
    self.buffers.zero_out = self.out;
    self.out = &self.buffers.zero_field.writer;
    assert(self.buffers.zero_out != null);
}

/// Ends a `zeroBegin`: the field written aside goes to the transcript,
/// padded with zeros to `f`'s width (`display.fillField`).
pub fn zeroEnd(self: *State, f: display.Fill) Error!void {
    assert(self.out == &self.buffers.zero_field.writer); // Pair of `zeroBegin`.
    self.out = self.buffers.zero_out.?;
    self.buffers.zero_out = null;
    defer self.buffers.zero_field.deinit();
    try display.fillField(self.out, self.buffers.zero_field.written(), f);
}

/// One `%b`/`%o`/`%h`/`%d` operand (§17.1.1.3).
pub fn value(self: *State, a: anytype, w: u32, signed: bool, radix: fmt.Radix, width: ?u64, zero: bool) Error!void {
    var buf = logic.planesOf(a);
    return fmt.valueFill(self.out, self.gpa, literal(&buf, w, signed), radix, width, zero);
}

/// One `%d %h %o %b` operand of real type (`display.realRadix`).
pub fn realValue(self: *State, r: f64, radix: fmt.Radix, width: ?u64) Error!void {
    return display.realRadix(self.out, self.gpa, r, radix, width);
}

/// One integral `%t` operand, in a module whose unit is 10^`unit_exp` s
/// (§17.3).
pub fn time(self: *State, a: anytype, w: u32, signed: bool, unit_exp: i32, width: ?u64, precision: i64) Error!void {
    var buf = logic.planesOf(a);
    const v = literal(&buf, w, signed);
    const f = self.time_format.field(width, precision);
    if (v.hasUnknown()) return fmt.timeUnknown(self.out, v, f);
    return fmt.timeInt(self.out, self.gpa, v, f, unit_exp);
}

/// One `%t` operand of real type, formatted as it is (#64).
pub fn timeReal(self: *State, v: f64, unit_exp: i32, width: ?u64, precision: i64) Error!void {
    try fmt.time(self.out, v, self.time_format.field(width, precision), unit_exp);
}

/// One real conversion (§17.1.1.2 `%e %f %g`, §9.4.7 `%r`): C's text
/// under `flags` (`str_kernels.zc_*`) in a field `width` wide
/// (`display.real`).
pub fn real(self: *State, r: f64, conv: u8, flags: u8, precision: i64, width: ?u64) Error!void {
    return display.real(self.out, self.gpa, r, conv, flags, precision, width);
}

/// §17.1.1.5 `%v` of the native net `k` (`Nets.sig0`, kept by the fold
/// a net whose strength is read resolves through).
pub fn netStrength(self: *State, k: u32) Error!void {
    assert(k < self.nets.sig0.len);
    try display.strength(self.out, self.nets.sig0[k]);
}

/// §17.1.1.5 `%v` of an operand that is not a net: its bit 0, strong.
pub fn strongStrength(self: *State, a: anytype, w: u32) Error!void {
    var buf = logic.planesOf(a);
    try display.strength(self.out, .of(literal(&buf, w, false).bit(0), .strong, .strong));
}

/// One `%s` or `%c` operand (§17.1.1.7).
pub fn text(self: *State, a: anytype, w: u32, char: bool, width: ?u64) Error!void {
    var buf = logic.planesOf(a);
    try fmt.text(self.out, literal(&buf, w, false), char, width);
}

test "setChars puts the last characters in the low bytes, cut to the width" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try quietState(arena.allocator(), &one_slot, -9);
    s.x[0] = 5;
    s.setChars(0, 16, "abc");
    try testing.expectEqual(W{ .v = 0x6263, .x = 0 }, s.get(0));
    // "ab" is 0x6162; 12 bits keep 0x162.
    s.setChars(0, 12, "ab");
    try testing.expectEqual(W{ .v = 0x162, .x = 0 }, s.get(0));
    s.setChars(0, 24, "");
    try testing.expectEqual(W{ .v = 0, .x = 0 }, s.get(0));
}
