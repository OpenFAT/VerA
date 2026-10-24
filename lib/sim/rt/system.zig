//! `rt.State`'s IEEE 1364-2005 §17.2 file I/O (`$fopen` .. `$fclose`, the
//! `$fgets`/`$fread`/`$fscanf`/`$sscanf` readers, `$fdisplay`'s channels)
//! over `digital/system.zig`'s descriptor table, and §17.2.3's held
//! `$sformat` formats scanned at run time. Free functions over `*State`,
//! aliased on `State` because the emitted design calls each one as a
//! method (`s.fopen(...)`, `S.formatOf(...)`).
const std = @import("std");
const root = @import("root.zig");
const State = root.State;
const Error = root.Error;
const logic = @import("logic.zig");
const fmt = @import("kernels").fmt;
const system = @import("../digital/system.zig");
const display = @import("../digital/display.zig");

/// §17.2.1 `system.fopen` of the characters of `name` (`nw` bits) with
/// the type in `mode` (`mw` bits), or `mode` null for a multichannel
/// descriptor; `source` is the design's file, which a read looks beside.
pub fn fopen(self: *State, source: []const u8, name: anytype, comptime nw: u32, mode: anytype, comptime mw: u32) Error!i64 {
    if (self.quiet) return 0;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const mcd = @TypeOf(mode) == @TypeOf(null);
    const m = if (mcd) null else try State.chars(a, mode, mw);
    return system.fopen(system.own, a, source, try State.chars(a, name, nw), m, mcd);
}

/// `system.fileOp`; -1 in a `quiet` run, which touches no file.
pub fn fileOp(self: *const State, f: system.FileFn, x: ?i64, y: ?i64, z: ?i64) i64 {
    if (self.quiet) return -1;
    return system.fileOp(system.own, f, x, y, z);
}

/// §17.2.4.2 `$fgets`: the bytes read into a `w`-bit destination, valid
/// until the next scratch-using call. No bytes means no assignment.
pub fn fileLine(self: *State, d: ?i64, comptime w: u32) Error![]const u8 {
    if (self.quiet) return "";
    const fd = (d orelse return "") & 0xffff_ffff;
    _ = self.scratch.reset(.retain_capacity);
    return system.readLine(self.scratch.allocator(), system.own, fd, w / 8);
}

/// §17.2.4.4: one big-endian binary word, copied out of the shared
/// reader's scratch storage so assigning it may safely call other tasks.
pub fn fileWord(self: *State, d: ?i64, comptime w: u32) Error!struct { value: ?logic.T(w), n: i64 } {
    if (self.quiet) return .{ .value = null, .n = 0 };
    const fd = (d orelse return .{ .value = null, .n = 0 }) & 0xffff_ffff;
    _ = self.scratch.reset(.retain_capacity);
    const word = system.readWord(self.scratch.allocator(), system.own, fd, w) catch return error.OutOfMemory;
    const v = word.value orelse return .{ .value = null, .n = word.n };
    if (w <= 64) return .{ .value = .{ .v = v.values()[0], .x = 0 }, .n = word.n };
    var word_value: logic.T(w) = .{ .v = undefined, .x = @splat(0) };
    @memcpy(&word_value.v, v.values());
    return .{ .value = word_value, .n = word.n };
}

/// §17.2.7 `$ferror`: the descriptor's error and the corresponding text.
/// Descriptor zero also reports a failed open, as on the interpreter path.
pub fn fileError(self: *const State, d: ?i64) struct { code: i64, text: []const u8 } {
    const code = if (self.quiet) 0 else system.own.err.?((d orelse 0) & 0xffff_ffff);
    return .{ .code = code, .text = @import("kernels").file_kernels.zFErrorStr(code, 0) };
}

/// §17.2.1 `$fclose`.
pub fn fclose(self: *const State, d: ?i64) void {
    if (self.quiet) return;
    _ = system.own.close((d orelse return) & 0xffff_ffff);
}

/// §17.2.4.3 `$sscanf` over the characters of `input` and `format`.
/// The caller owns the scan's arena: an output index can call another
/// scanner without invalidating this conversion stream.
pub fn scan(_: *const State, a: std.mem.Allocator, input: anytype, comptime iw: u32, format: anytype, comptime fw: u32, outs: usize) Error!system.Scan {
    return .init(try State.chars(a, input, iw), try State.chars(a, format, fw), outs);
}

/// §17.2.4.3 `$fscanf`: the same conversion stream as `$sscanf`, together
/// with the file position which `finishFileScan` advances by consumed input.
pub fn scanFile(self: *const State, a: std.mem.Allocator, descriptor: ?i64, format: anytype, comptime fw: u32, outs: usize) Error!system.FileScan {
    return system.fileScan(a, system.own, if (self.quiet) null else descriptor, try State.chars(a, format, fw), outs);
}

/// `system.finishFileScan` of a `scanFile`: the file position follows
/// what the scan consumed.
pub fn finishFileScan(self: *const State, file: system.FileScan, sc: system.Scan) void {
    if (self.quiet) return;
    _ = system.finishFileScan(system.own, file, sc);
}

/// §17.2.2: ends a `capture`, sending its bytes to descriptor `d`'s
/// channels (`system.channels`).
pub fn fshow(self: *State, d: i64) Error!void {
    const bytes = self.captured();
    if (self.quiet) return;
    if (try system.channels(system.own, self.io, self.out, d & 0xffff_ffff, bytes)) self.warn("W1154", system.unwritten, .{});
}

/// §17.2.3 a `$sformat` format held in a variable, read when the task
/// runs (`display.sformat`'s dynamic walk): its characters, how far they
/// are used, and whether they end inside a conversion.
pub const Format = struct { text: []const u8, i: usize = 0, bad: bool = false };

/// One argument-taking conversion of a `Format`; `flags` are `fmt.spec`'s,
/// which only a real conversion carries past `fmt.flagVerdict`.
pub const Spec = struct { conv: u8, flags: u8, width: ?u64, precision: i64 };

/// The characters of the `w`-bit format `a` (`system.text`) in `buf`,
/// `w / 8` bytes rounded up, most significant first and its leading zero
/// bytes dropped; none when it holds an x or z. The text is a slice of
/// `buf`.
pub fn formatOf(buf: []u8, a: anytype, w: u32) Format {
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
    return .{ .text = buf[0..n] };
}

/// The next conversion of `f` that takes an argument, printing the text
/// before it (`%%`, `%m` as `scope`, `%l` as `lib`); null, having warned
/// (W1153), when the format has none left for the argument.
pub fn nextSpec(self: *State, f: *Format, scope: []const u8, lib: []const u8) Error!?Spec {
    if (try scanSpec(self, f, scope, lib)) |sp| return sp;
    self.warn("W1153", display.sformat_mismatch, .{});
    return null;
}

/// The text after the last argument's conversion; W1153 when another
/// conversion wants an argument or the format ends inside one.
pub fn endFormat(self: *State, f: *Format, scope: []const u8, lib: []const u8) Error!void {
    if (try scanSpec(self, f, scope, lib) != null or f.bad) self.warn("W1153", display.sformat_mismatch, .{});
}

fn scanSpec(self: *State, f: *Format, scope: []const u8, lib: []const u8) Error!?Spec {
    const t = f.text;
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
            'b', 'B', 'o', 'O', 'h', 'H', 'd', 'D', 'e', 'E', 'f', 'F', 'g', 'G', 'r', 'R', 't', 'T', 's', 'S', 'c', 'C', 'v', 'V' => return .{ .conv = conv, .flags = sp.flags, .width = sp.width, .precision = sp.precision },
            else => return self.fail("only the §9.4.3 Table 9-22 conversions (%b, %o, %h, %d, %e, %f, %g, §9.4.7 %r and %%) and %c %s %m %l %t %v are implemented", .{}),
        }
    }
    return null;
}

const testing = std.testing;
const W = logic.W;

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
    const s = try root.quietState(arena.allocator(), &root.one_slot, -9);
    var f: State.Format = .{ .text = "a%%b%5.2fc%m%" };
    const sp = (try s.nextSpec(&f, "top.u", "work")).?;
    try testing.expectEqual(@as(u8, 'f'), sp.conv);
    try testing.expectEqual(@as(?u64, 5), sp.width);
    try testing.expectEqual(@as(i64, 2), sp.precision);
    try testing.expectEqualStrings("a%b", s.sink.buffered());
    // The rest prints; the format ends inside a conversion (W1153).
    try s.endFormat(&f, "top.u", "work");
    try testing.expectEqualStrings("a%bctop.u", s.sink.buffered());
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
