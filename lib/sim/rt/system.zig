//! `rt.State`'s IEEE 1364-2005 §17.2 file I/O (`$fopen` .. `$fclose`, the
//! `$fgets`/`$fread`/`$fscanf`/`$sscanf` readers, `$fdisplay`'s channels)
//! over `digital/system.zig`'s descriptor table, and §17.2.3's held
//! `$sformat` formats scanned at run time. Free functions over `*State`,
//! aliased on `State` because the emitted design calls each one as a
//! method (`s.fopen(...)`, `S.formatOf(...)`).
//!
//! Contents:
//! - `pub const Format = struct`
//! - `pub const Spec = struct`
//! - `pub fn fopen(self: *State, source: []const u8, name: anytype, comptime nw: u32, mode: anytype, comptime mw: u32) Error!i64`
//! - `pub fn fileOp(self: *const State, f: system.FileFn, x: ?i64, y: ?i64, z: ?i64) i64`
//! - `pub fn fileLine(self: *State, d: ?i64, comptime w: u32) Error![]const u8`
//! - `pub fn fileWord(self: *State, d: ?i64, comptime w: u32, prior: anytype) Error!struct { value: ?logic.T(w), n: i64 }`
//! - `pub fn fileError(self: *const State, d: ?i64) struct { code: i64, text: []const u8 }`
//! - `pub fn fclose(self: *const State, d: ?i64) void`
//! - `pub fn scan(_: *const State, a: std.mem.Allocator, input: anytype, comptime iw: u32, format: anytype, comptime fw: u32, outs: usize) Error!system.Scan`
//! - `pub fn scanFile(self: *const State, a: std.mem.Allocator, descriptor: ?i64, format: anytype, comptime fw: u32, outs: usize) Error!system.FileScan`
//! - `pub fn finishFileScan(self: *const State, file: system.FileScan, sc: system.Scan) void`
//! - `pub fn fshow(self: *State, d: i64) Error!void`
//! - `pub fn formatOf(buf: []u8, a: anytype, w: u32) Format`
//! - `pub fn nextSpec(self: *State, f: *Format, scope: []const u8, lib: []const u8) Error!?Spec`
//! - `pub fn endFormat(self: *State, f: *Format, scope: []const u8, lib: []const u8) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const design = @import("design.zig");
const State = @import("State.zig");
const Error = design.Error;
const logic = @import("logic/root.zig");
const fmt = @import("kernels").fmt;
const system = @import("../digital/system.zig");
const display = @import("../digital/display.zig");
const testing = std.testing;
const W = logic.W;

/// §17.2.3 a `$sformat` format held in a variable, read when the task
/// runs (`display.sformat`'s dynamic walk): its characters, how far they
/// are used, and whether they end inside a conversion.
pub const Format = struct { text: []const u8, i: usize = 0, bad: bool = false };

/// One argument-taking conversion of a `Format`; `flags` are `fmt.spec`'s,
/// which only a real conversion carries past `fmt.flagVerdict`.
pub const Spec = struct { conv: u8, flags: u8, width: ?u64, precision: i64 };

/// §17.2.1 `system.fopen` of the characters of `name` (`nw` bits) with
/// the type in `mode` (`mw` bits), or `mode` null for a multichannel
/// descriptor; `source` is the design's file, which a read looks beside.
/// Asserts that `name` has bits, and `mode` has bits unless it is null.
pub fn fopen(self: *State, source: []const u8, name: anytype, comptime nw: u32, mode: anytype, comptime mw: u32) Error!i64 {
    const mcd = @TypeOf(mode) == @TypeOf(null);
    comptime assert(nw >= 1);
    comptime assert(mcd == (mw == 0));
    if (self.quiet) return 0;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const m = if (mcd) null else try State.chars(a, mode, mw);
    return system.fopen(system.own, a, source, try State.chars(a, name, nw), m, mcd);
}

/// `system.fileOp`; -1 in a `quiet` run, which touches no file.
/// Asserts that `f` is one of the descriptor functions `system.fileOp` runs.
pub fn fileOp(self: *const State, f: system.FileFn, x: ?i64, y: ?i64, z: ?i64) i64 {
    assert(switch (f) {
        .fgetc, .ungetc, .ftell, .fseek, .rewind, .feof => true,
        .fopen, .fgets, .fscanf, .fread, .ferror, .sscanf => false,
    });
    if (self.quiet) return -1;
    return system.fileOp(system.own, f, x, y, z);
}

/// §17.2.4.2 `$fgets`: the bytes read into a `w`-bit destination, valid
/// until the next scratch-using call. No bytes means no assignment.
/// Asserts that the destination has bits.
pub fn fileLine(self: *State, d: ?i64, comptime w: u32) Error![]const u8 {
    comptime assert(w >= 1);
    if (self.quiet) return "";
    const fd = (d orelse return "") & 0xffff_ffff;
    _ = self.scratch.reset(.retain_capacity);
    const line = try system.readLine(self.scratch.allocator(), system.own, fd, w / 8);
    assert(line.len <= w / 8); // `readLine` stops at the room it is given.
    return line;
}

/// §17.2.4.4: one big-endian binary word over the target's `prior` value
/// (`system.overWord`: a file that ends inside the word keeps the bits no
/// character reached), copied out of the shared reader's scratch storage
/// so assigning it may safely call other tasks. Asserts that the target
/// has bits.
pub fn fileWord(self: *State, d: ?i64, comptime w: u32, prior: anytype) Error!struct { value: ?logic.T(w), n: i64 } {
    comptime assert(w >= 1);
    if (self.quiet) return .{ .value = null, .n = 0 };
    const fd = (d orelse return .{ .value = null, .n = 0 }) & 0xffff_ffff;
    _ = self.scratch.reset(.retain_capacity);
    const word = system.readWord(self.scratch.allocator(), system.own, fd, w) catch return error.OutOfMemory;
    // `readWord`: no value exactly when no character was read, and at most
    // one per byte of the target.
    assert((word.value == null) == (word.n == 0));
    assert(word.n <= (w + 7) / 8);
    var buf = logic.planesOf(prior);
    const v = system.overWord(word.value orelse return .{ .value = null, .n = word.n }, State.literal(&buf, w, false), word.n);
    if (w <= 64) return .{ .value = .{ .v = v.values()[0], .x = v.unknowns()[0] }, .n = word.n };
    var word_value: logic.T(w) = undefined;
    @memcpy(&word_value.v, v.values());
    @memcpy(&word_value.x, v.unknowns());
    return .{ .value = word_value, .n = word.n };
}

/// §17.2.7 `$ferror`: the descriptor's error and the corresponding text.
/// Descriptor zero also reports a failed open, as on the interpreter path.
pub fn fileError(self: *const State, d: ?i64) struct { code: i64, text: []const u8 } {
    const code = if (self.quiet) 0 else system.own.err.?((d orelse 0) & 0xffff_ffff);
    if (self.quiet) assert(code == 0);
    const text = @import("kernels").file_kernels.zFErrorStr(code, 0);
    // §9.5.7: an empty string exactly when there is no error.
    assert((code == 0) == (text.len == 0));
    return .{ .code = code, .text = text };
}

/// §17.2.1 `$fclose`.
pub fn fclose(self: *const State, d: ?i64) void {
    if (self.quiet) return;
    const fd = (d orelse return) & 0xffff_ffff;
    assert(fd >= 0); // A §17.2.1 descriptor is its low 32 bits.
    _ = system.own.close(fd);
}

/// §17.2.4.3 `$sscanf` over the characters of `input` and `format`.
/// The caller owns the scan's arena: an output index can call another
/// scanner without invalidating this conversion stream. Asserts that the
/// input and the format have bits.
pub fn scan(_: *const State, a: std.mem.Allocator, input: anytype, comptime iw: u32, format: anytype, comptime fw: u32, outs: usize) Error!system.Scan {
    comptime assert(iw >= 1);
    comptime assert(fw >= 1);
    const sc: system.Scan = .init(try State.chars(a, input, iw), try State.chars(a, format, fw), outs);
    assert(sc.outs == outs);
    return sc;
}

/// §17.2.4.3 `$fscanf`: the same conversion stream as `$sscanf`, together
/// with the file position which `finishFileScan` advances by consumed input.
/// Asserts that the format has bits.
pub fn scanFile(self: *const State, a: std.mem.Allocator, descriptor: ?i64, format: anytype, comptime fw: u32, outs: usize) Error!system.FileScan {
    comptime assert(fw >= 1);
    const file = try system.fileScan(a, system.own, if (self.quiet) null else descriptor, try State.chars(a, format, fw), outs);
    assert(file.scan.outs == outs);
    if (self.quiet) assert(file.descriptor == null); // A quiet run reads no file.
    return file;
}

/// `system.finishFileScan` of a `scanFile`: the file position follows
/// what the scan consumed. Asserts that `sc` is `file`'s stream.
pub fn finishFileScan(self: *const State, file: system.FileScan, sc: system.Scan) void {
    assert(sc.outs == file.scan.outs); // Pair of `scanFile`.
    assert(sc.input.len == file.scan.input.len);
    if (self.quiet) return;
    _ = system.finishFileScan(system.own, file, sc);
}

/// §17.2.2: ends a `capture`, sending its bytes to descriptor `d`'s
/// channels (`system.channels`). Asserts that a `capture` is open.
pub fn fshow(self: *State, d: i64) Error!void {
    assert(self.out == &self.buffers.cap.writer); // Pair of `capture`.
    const bytes = self.captured();
    assert(self.out == self.buffers.sink);
    if (self.quiet) return;
    if (try system.channels(system.own, self.io, self.out, d & 0xffff_ffff, bytes)) self.warn("W1154", system.unwritten, .{});
}

/// The characters of the `w`-bit format `a` (`system.text`) in `buf`,
/// `w / 8` bytes rounded up, most significant first and its leading zero
/// bytes dropped; none when it holds an x or z. The text is a slice of
/// `buf`. Asserts that the format has bits.
pub fn formatOf(buf: []u8, a: anytype, w: u32) Format {
    assert(w >= 1);
    var planes = logic.planesOf(a);
    const v = State.literal(&planes, w, false);
    if (v.hasUnknown()) return .{ .text = "" };
    var n: usize = 0;
    var k = buf.len;
    while (k != 0) {
        k -= 1;
        const c = fmt.byteAt(v, @intCast(k));
        if (c == 0 and n == 0) continue;
        buf[n] = c;
        n += 1;
    }
    assert(n <= buf.len);
    return .{ .text = buf[0..n] };
}

/// The next conversion of `f` that takes an argument, printing the text
/// before it (`%%`, `%m` as `scope`, `%l` as `lib`); null, having warned
/// (W1153), when the format has none left for the argument. Asserts that
/// `f` is used no further than its text.
pub fn nextSpec(self: *State, f: *Format, scope: []const u8, lib: []const u8) Error!?Spec {
    assert(f.i <= f.text.len);
    if (try scanSpec(self, f, scope, lib)) |sp| {
        assert(sp.conv != '%'); // `%%` is text, not a conversion.
        return sp;
    }
    assert(f.i == f.text.len); // Null only once the text is used up.
    self.warn("W1153", display.sformat_mismatch, .{});
    return null;
}

/// The text after the last argument's conversion; W1153 when another
/// conversion wants an argument or the format ends inside one. Asserts
/// that `f` is used no further than its text.
pub fn endFormat(self: *State, f: *Format, scope: []const u8, lib: []const u8) Error!void {
    assert(f.i <= f.text.len);
    const rest = try scanSpec(self, f, scope, lib);
    if (rest == null) assert(f.i == f.text.len);
    if (rest != null or f.bad) self.warn("W1153", display.sformat_mismatch, .{});
}

// ---- private ----

fn scanSpec(self: *State, f: *Format, scope: []const u8, lib: []const u8) Error!?Spec {
    const t = f.text;
    assert(f.i <= t.len);
    while (f.i < t.len) {
        const c = t[f.i];
        f.i += 1;
        if (c != '%') {
            try self.out.writeByte(c);
            continue;
        }
        if (f.i < t.len and t[f.i] == '%') {
            f.i += 1;
            try self.out.writeByte('%');
            continue;
        }
        const sp = fmt.spec(t, &f.i);
        assert(f.i <= t.len); // `fmt.spec` stops at the text's end.
        if (f.i == t.len) {
            f.bad = true;
            return null;
        }
        const conv = t[f.i];
        f.i += 1;
        // #43: `display.walk`'s rule, met here only when the task runs.
        if (conv != '%') switch (fmt.flagVerdict(sp.flags, conv)) {
            .ok => {},
            .alt => return self.fail("IEEE 1364-2005 §17.1.1.2 (E0825): '#' is C's alternative form, granted only to %e, %f and %g", .{}),
            .c_flag => return self.fail("IEEE 1364-2005 §17.1.1.2 (E0827): C's '-', '+' and ' ' flags are granted to the real conversions only", .{}),
        };
        switch (conv) {
            '%' => return self.fail("§9.4.2 (E0826): a flag, width or precision before the second `%` of `%%`", .{}),
            'm', 'M' => try self.out.writeAll(scope),
            'l', 'L' => try self.out.writeAll(lib),
            'b', 'B', 'o', 'O', 'h', 'H', 'x', 'X', 'd', 'D', 'e', 'E', 'f', 'F', 'g', 'G', 'r', 'R', 't', 'T', 's', 'S', 'c', 'C', 'v', 'V' => return .{ .conv = conv, .flags = sp.flags, .width = sp.width, .precision = sp.precision },
            else => return self.fail("only the §9.4.3 Table 9-22 conversions (%b, %o, %h, %d, %e, %f, %g, §9.4.7 %r and %%) and %c %s %m %l %t %v are implemented", .{}),
        }
    }
    return null;
}

test "formatOf: a held format's characters, leading zero bytes dropped, none with an x" {
    var buf: [4]u8 = undefined;
    try testing.expectEqualStrings("Hi", State.formatOf(&buf, W{ .v = 0x4869, .x = 0 }, 32).text);
    // An inner or trailing zero byte is a character.
    try testing.expectEqualStrings("H\x00i\x00", State.formatOf(&buf, W{ .v = 0x4800_6900, .x = 0 }, 32).text);
    try testing.expectEqualStrings("", State.formatOf(&buf, W{ .v = 0x4869, .x = 0x100 }, 32).text);
}

test "§17.2.3 a held format: text, %% and %m print, a conversion is returned, a broken one refused" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const s = try State.quietState(arena.allocator(), &design.one_slot, -9);
    var f: State.Format = .{ .text = "a%%b%5.2fc%m%" };
    const sp = (try s.nextSpec(&f, "top.u", "work")).?;
    try testing.expectEqual(@as(u8, 'f'), sp.conv);
    try testing.expectEqual(@as(?u64, 5), sp.width);
    try testing.expectEqual(@as(i64, 2), sp.precision);
    try testing.expectEqualStrings("a%b", s.buffers.sink.buffered());
    // The rest prints; the format ends inside a conversion (W1153).
    try s.endFormat(&f, "top.u", "work");
    try testing.expectEqualStrings("a%bctop.u", s.buffers.sink.buffered());
    try testing.expect(f.bad);
    // No conversion left for an argument: null (W1153).
    var plain: State.Format = .{ .text = "" };
    try testing.expect(try s.nextSpec(&plain, "", "") == null);
    var unknown: State.Format = .{ .text = "%q" };
    try testing.expectError(error.Failed, s.nextSpec(&unknown, "", ""));
    // No width is too large: past the old 4096 and past a u32.
    var huge: State.Format = .{ .text = "%99999999999d" };
    try testing.expectEqual(@as(?u64, 99999999999), (try s.nextSpec(&huge, "", "")).?.width);
}
