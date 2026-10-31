//! A §17.2 file task in (`$fopen`, `$fclose`, `$fgets`, `$fread`, `$fscanf`, `$fdisplay` and the descriptor queries), the descriptor table and the bytes read or written out, through the host's `contract.FileIo`.
//! Cites: IEEE 1364-2005 §17.2.1, §17.2.2, §17.2.4, §17.2.7, Table 17-7.
//!
//! Contents:
//! - `pub const own: contract.FileIo`
//! - `pub const FileFn = enum`
//! - `pub const FileScan = struct`
//! - `pub const unwritten`
//! - `pub const FakeFile = struct`
//! - `pub fn descriptor(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?i64`
//! - `pub fn fileCall(self: *Run, a: std.mem.Allocator, f: FileFn, args: []const Ast.ExprId) Error!i64`
//! - `pub fn fopen(t: contract.FileIo, a: std.mem.Allocator, file_name: []const u8, name: ?[]const u8, mode: ?[]const u8, mcd: bool) std.mem.Allocator.Error!i64`
//! - `pub fn fileType(ty: []const u8) bool`
//! - `pub fn fileOp(t: contract.FileIo, f: FileFn, x: ?i64, y: ?i64, z: ?i64) i64`
//! - `pub fn readLine(a: std.mem.Allocator, t: contract.FileIo, d: i64, room: u32) std.mem.Allocator.Error![]const u8`
//! - `pub fn fileScan(a: std.mem.Allocator, t: contract.FileIo, descriptor_: ?i64, format: ?[]const u8, outs: usize) std.mem.Allocator.Error!FileScan`
//! - `pub fn finishFileScan(t: contract.FileIo, file: FileScan, scan: Scan) i64`
//! - `pub fn readWord(a: std.mem.Allocator, t: contract.FileIo, d: i64, width: u32) Error!struct { value: ?Int.Literal, n: i64 }`
//! - `pub fn overWord(v: Int.Literal, prior: Int.Literal, n: i64) Int.Literal`
//! - `pub fn fclose(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!void`
//! - `pub fn fdisplay(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: display.Show) Error!void`
//! - `pub fn fdisplayTo(self: *Run, a: std.mem.Allocator, d: i64, args: []const Ast.ExprId, show: display.Show) Error!void`
//! - `pub fn channels(t: ?contract.FileIo, io: ?std.Io, out: *std.Io.Writer, d: i64, bytes: []const u8) std.Io.Writer.Error!bool`
//! IEEE 1364-2005 §17 system tasks that keep state of their own: a task's
//! argument expressions and the `Run` in; values written to its output
//! arguments (and, for queues, `Run.queues`) out.
//! Clauses: §17.2 file input and output, §17.2.3 string output, §17.5
//! programmable logic arrays, §17.6 stochastic queues, §17.9 distributions.
const std = @import("std");
const assert = std.debug.assert;
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
const contract = @import("contract");
const fk = @import("kernels").file_kernels;
const queues = @import("queues.zig");
const scanf = @import("scanf.zig");
const system = @import("system.zig");
const Scan = scanf.Scan;
const int = queues.int;
const scanAssign = scanf.scanAssign;
const scanCall = scanf.scanCall;
const scanContext = scanf.scanContext;
const text = system.text;

/// This engine's own descriptor table: `file_kernels`, the table the analog
/// devices run, so both engines answer §17.2 one way (IEEE 1364-2005 §17.2.1's
/// encodings: an mcd's bit 0 is standard output, an fd has bit 31 set and
/// 0..2 are the standard streams).
pub const own: contract.FileIo = .{ .open = fk.zFOpen, .close = fk.zFClose, .put = fk.zFPut, .getc = fk.zFGetc, .ungetc = fk.zFUngetc, .tell = fk.zFTell, .seek = fk.zFSeek, .eof = fk.zFEof, .err = fk.zFError };

/// The §17.2 functions an expression can call.
pub const FileFn = enum { fopen, fgetc, ungetc, fgets, fscanf, fread, ftell, fseek, rewind, feof, ferror, sscanf };

/// §17.2.4.3's input snapshot and original descriptor position. The native
/// executable and interpreter use the same scanner and restore only the
/// consumed prefix, so a failed conversion leaves the offending byte unread.
/// `pushed`: how many of the input's first bytes are §17.2.4.1 pushback
/// that differs from the file under it, which a reposition would lose.
pub const FileScan = struct { scan: Scan, descriptor: ?i64 = null, start: i64 = 0, input_len: usize = 0, pushed: usize = 0 };

/// The W1154 text.
pub const unwritten = "no file this descriptor names is open for writing: the output is not written";

/// A one-file `contract.FileIo` over `data`, for the descriptor-level
/// helpers. Its state is global: one test at a time uses it.
pub const FakeFile = struct {
    var data: []const u8 = "";
    var pos: usize = 0;
    var put_bytes: usize = 0;

    fn reset(bytes: []const u8) void {
        data = bytes;
        pos = 0;
        put_bytes = 0;
    }
    /// A read opens beside the source when it can (`dir/f.txt`, 7), and
    /// anything else as itself (3).
    fn open(path: []const u8, _: []const u8, _: bool) i64 {
        return if (path.len > "f.txt".len and std.mem.endsWith(u8, path, "f.txt")) 7 else 3;
    }
    fn close(_: i64) i64 {
        return 0;
    }
    /// Takes none of the bytes, as a file not open for writing.
    fn put(_: i64, bytes: []const u8) i64 {
        put_bytes += bytes.len;
        return 0;
    }
    fn getc(_: i64) i64 {
        if (pos == data.len) return -1;
        pos += 1;
        return data[pos - 1];
    }
    fn ungetc(c: i64, _: i64) i64 {
        pos -= 1;
        return c;
    }
    fn tell(_: i64) i64 {
        return @intCast(pos);
    }
    fn seek(_: i64, off: i64, _: i64) i64 {
        pos = @intCast(off);
        return 0;
    }
    fn eof(_: i64) i64 {
        return @intFromBool(pos == data.len);
    }
    const io: contract.FileIo = .{ .open = open, .close = close, .put = put, .getc = getc, .ungetc = ungetc, .tell = tell, .seek = seek, .eof = eof };
};

/// A descriptor is "a 32-bit value" (§17.2.1): its low 32 bits, however the
/// variable holding it is signed (`integer fd` is the clause's own example).
pub fn descriptor(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!?i64 {
    assert(e != .none);
    return low32(try int(self, a, e));
}

/// One §17.2 function call; every one of them returns an integer.
pub fn fileCall(self: *Run, a: std.mem.Allocator, f: FileFn, args: []const Ast.ExprId) Error!i64 {
    if (f == .sscanf) return scanCall(self, a, args);
    const t = table(self) orelse return switch (f) {
        .fopen, .fgets, .fread, .ferror => 0,
        else => -1, // else: EOF, the error answer of the rest
    };
    switch (f) {
        .fopen => {
            const name = try text(a, try evaluate.eval(self, a, args[0], 0));
            const mode = if (args.len == 1) null else try text(a, try evaluate.eval(self, a, args[1], 0));
            return fopen(t, a, self.file_name, name, mode, args.len == 1);
        },
        .fgets => return fgets(self, a, t, args),
        .fscanf => return fscanf(self, a, t, args),
        .fread => return fread(self, a, t, args),
        // §17.2.7: the code, and its description in `str`, cleared when 0.
        .ferror => {
            const code = if (t.err) |err| err((try descriptor(self, a, args[0])) orelse 0) else 0;
            try evaluate.assign(self, a, args[1], try evaluate.stringLiteral(a, fk.zFErrorStr(code, 0)));
            return code;
        },
        else => {}, // else: `fileOp`'s
    }
    var v: [3]?i64 = .{ null, null, null };
    for (args, 0..) |arg, i| v[i] = try int(self, a, arg);
    return fileOp(t, f, v[0], v[1], v[2]);
}

/// §17.2.1 `$fopen(name)` (`mcd`) or `$fopen(name, type)` on the table `t`
/// of a source `file_name`: no type opens for writing and returns a
/// multichannel descriptor, one bit above bit 0; a Table 17-7 type returns
/// a file descriptor. 0 when the file cannot be opened, or `name` or `mode`
/// is null (an x or z bit).
pub fn fopen(t: contract.FileIo, a: std.mem.Allocator, file_name: []const u8, name: ?[]const u8, mode: ?[]const u8, mcd: bool) std.mem.Allocator.Error!i64 {
    const path = name orelse return 0;
    const ty = if (mcd) "w" else mode orelse return 0;
    if (!fileType(ty)) return 0;
    // A file read is looked for beside the source first, as `$readmemh`
    // looks (`display.sideFile`).
    if (ty[0] == 'r') if (std.Io.Dir.path.dirname(file_name)) |dir| {
        const d = t.open(try std.Io.Dir.path.join(a, &.{ dir, path }), ty, mcd);
        if (d != 0) return d;
    };
    return t.open(path, ty, mcd);
}

/// Is `ty` one of §17.2.1 Table 17-7's file types? The list is lowering's
/// too (`kernels.fopen_types`).
pub fn fileType(ty: []const u8) bool {
    return @import("kernels").fopen_types.has(ty);
}

/// §17.2.4.1 / §17.2.4.2 / §17.2.5 / §17.2.8 on the table `t`, C's
/// semantics: `x`, `y`, `z` are the call's arguments in order, null where an
/// argument has an x or z bit (or is absent). EOF (-1) for an unknown one.
pub fn fileOp(t: contract.FileIo, f: FileFn, x: ?i64, y: ?i64, z: ?i64) i64 {
    const eof: i64 = -1;
    switch (f) {
        .fgetc => return t.getc(low32(x) orelse return eof),
        .ungetc => return t.ungetc(x orelse return eof, low32(y) orelse return eof),
        .ftell => return t.tell(low32(x) orelse return eof),
        // §17.2.5: whence 0 from the start, 1 from here, 2 from the end.
        .fseek, .rewind => {
            const d = low32(x) orelse return eof;
            if (f == .rewind) return t.seek(d, 0, 0);
            const offset = y orelse return eof;
            const whence = z orelse return eof;
            if (whence < 0 or whence > 2) return eof;
            return t.seek(d, offset, whence);
        },
        .feof => return t.eof(low32(x) orelse return eof),
        .fopen, .sscanf, .fgets, .fscanf, .fread, .ferror => unreachable, // `fileCall`'s own
    }
}

/// §17.2.4.2's byte read, shared by the interpreter and emitted executable.
/// Include the newline, respect the destination's complete-byte capacity,
/// and return no bytes on EOF/error so the caller leaves its target alone.
pub fn readLine(a: std.mem.Allocator, t: contract.FileIo, d: i64, room: u32) std.mem.Allocator.Error![]const u8 {
    var line: std.ArrayList(u8) = .empty;
    while (line.items.len < room) {
        const c = t.getc(d);
        if (c < 0) break;
        try line.append(a, @intCast(c));
        if (c == '\n') break;
    }
    return line.items;
}

/// Starts a `$fscanf` on descriptor `descriptor_`: the rest of the file is
/// read into `a` and the descriptor left at its end until `finishFileScan`
/// puts it back. A null, x or unreadable descriptor scans no input (EOF).
pub fn fileScan(a: std.mem.Allocator, t: contract.FileIo, descriptor_: ?i64, format: ?[]const u8, outs: usize) std.mem.Allocator.Error!FileScan {
    const no_input: FileScan = .{ .scan = .init(null, format, outs) };
    const d = low32(descriptor_) orelse return no_input;
    const start = t.tell(d);
    if (start < 0) return no_input;
    // ponytail: reads the rest of the file per call; a streaming scan when a
    // model reads large files this way.
    var rest: std.ArrayList(u8) = .empty;
    while (true) {
        const c = t.getc(d);
        if (c < 0) break;
        try rest.append(a, @intCast(c));
    }
    // `$ungetc`'s characters came first (VD-084). The file's own bytes under
    // them (at most 16, `file_kernels.ZFSlot.back`) tell which ones
    // `finishFileScan` must push back after it repositions.
    _ = t.seek(d, start, 0);
    var pushed: usize = 0;
    for (rest.items[0..@min(rest.items.len, 16)], 0..) |c, i| {
        if (t.getc(d) != c) pushed = i + 1;
    }
    return .{ .scan = .init(rest.items, format, outs), .descriptor = d, .start = start, .input_len = rest.items.len, .pushed = pushed };
}

/// Ends a `fileScan`: the descriptor is repositioned just past what `scan`
/// consumed, and `$fscanf`'s value (`Scan.result`) returned. Must follow
/// every `fileScan` whose descriptor was readable.
pub fn finishFileScan(t: contract.FileIo, file: FileScan, scan: Scan) i64 {
    const d = file.descriptor orelse return scan.result;
    if (scan.at < file.pushed) {
        // The pushback the scan left unread stays the next input.
        _ = t.seek(d, file.start + @as(i64, @intCast(file.pushed)), 0);
        var k = file.pushed;
        while (k > scan.at) {
            k -= 1;
            _ = t.ungetc(scan.input[k], d);
        }
        return scan.result;
    }
    _ = t.seek(d, file.start + @as(i64, @intCast(scan.at)), 0);
    // A scan that ran to the end of the input met EOF (§17.2.8), which the
    // repositioning cleared.
    if (scan.at == file.input_len) _ = t.getc(d);
    return scan.result;
}

/// One `$fread` word: ceil(width/8) characters, big-endian, into `width`
/// bits; the value is null when the file ends before its first character.
/// `n` is the characters read: fewer than a word's means the file ended
/// inside it, and `overWord` keeps the bits no character reached.
pub fn readWord(a: std.mem.Allocator, t: contract.FileIo, d: i64, width: u32) Error!struct { value: ?Int.Literal, n: i64 } {
    const bytes = (width + 7) / 8;
    const v = try filled(a, width, false, .zero);
    for (0..bytes) |k| {
        const c = t.getc(d);
        if (c < 0) {
            if (k == 0) return .{ .value = null, .n = 0 };
            v.values()[v.values().len - 1] &= wordMask(width, v.values().len - 1);
            return .{ .value = v, .n = @intCast(k) };
        }
        const lo = (bytes - 1 - k) * 8;
        v.values()[lo / 64] |= @as(u64, @intCast(c)) << @intCast(lo % 64);
    }
    // The top byte's bits above `width` are dropped.
    const top = v.values().len - 1;
    v.values()[top] &= wordMask(width, top);
    return .{ .value = v, .n = bytes };
}

/// A word `readWord` read `n` characters of, over the target's `prior`
/// value: the characters fill it from the most significant byte down, and
/// the bits below the last one keep `prior` (§17.2.4.4 says nothing of a
/// file that ends inside a word; iverilog keeps them, ivtest fread.v).
/// `v` is updated in place and returned.
pub fn overWord(v: Int.Literal, prior: Int.Literal, n: i64) Int.Literal {
    const bytes: i64 = (v.width + 7) / 8;
    if (n >= bytes) return v;
    const cut: u32 = @intCast(@min((bytes - n) * 8, v.width));
    for (0..cut) |i| setBit(v, @intCast(i), if (i < prior.width) prior.bit(@intCast(i)) else .zero);
    return v;
}

/// §17.2.7 `$fclose` of a file descriptor, or of every file a multichannel
/// descriptor's bits name.
pub fn fclose(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId) Error!void {
    const d = (try descriptor(self, a, args[0])) orelse return;
    display.cancelFile(self, d);
    if (table(self)) |t| _ = t.close(d);
}

/// §17.2.2 `$fdisplay`/`$fwrite` and their radix forms: the `$display` text
/// of the arguments after the descriptor, to every channel it names.
pub fn fdisplay(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: display.Show) Error!void {
    const d = (try descriptor(self, a, args[0])) orelse return;
    return fdisplayTo(self, a, d, args, show);
}

/// `fdisplay` to descriptor `d`, already read from `args[0]`.
pub fn fdisplayTo(self: *Run, a: std.mem.Allocator, d: i64, args: []const Ast.ExprId, show: display.Show) Error!void {
    var sh = show;
    sh.file = false;
    var buf: std.Io.Writer.Allocating = .init(a);
    const saved = self.out;
    self.out = &buf.writer;
    defer self.out = saved;
    try display.display(self, args[1..], a, sh);
    self.out = saved;
    if (try channels(table(self), self.io, self.out, d, buf.written())) {
        const start = self.starts[@min(self.file.exprs.mainTok(args[0]), self.starts.len - 1)];
        try self.bag.add(self.stage(), .W1154, .{ .start = start, .end = start }, unwritten, .{});
    }
}

/// `bytes` to every channel descriptor `d` names: bit 0 of an mcd and fd 1
/// (STDOUT) are the transcript `out`; fd 2 is STDERR; every other channel
/// is the table's. True when the table's channels took none of `bytes`:
/// each is closed (§17.2.1: `$fclose` "does not allow any further output to
/// the closed channels") or not open for writing.
pub fn channels(t: ?contract.FileIo, io: ?std.Io, out: *std.Io.Writer, d: i64, bytes: []const u8) std.Io.Writer.Error!bool {
    const fd = d & (@as(i64, 1) << 31) != 0;
    const ch = d & 0x7fff_ffff;
    if ((fd and ch == 1) or (!fd and d & 1 != 0)) try out.writeAll(bytes);
    if (fd and ch == 2) if (io) |i| std.Io.File.stderr().writeStreamingAll(i, bytes) catch {};
    const files = if (fd) (if (ch > 2) d else 0) else d & ~@as(i64, 1);
    if (files == 0 or bytes.len == 0) return false;
    const tt = t orelse return false;
    return tt.put(files, bytes) == 0;
}

// ---- private ----

/// VAMS §9.5.1.2: one descriptor table per simulation, the host's
/// (`Run.file_io`: a mixed simulation's device table), else this engine's
/// own, which only an engine given filesystem access (`Options.io`) opens
/// files through.
fn table(self: *Run) ?contract.FileIo {
    return self.tasks.file_io orelse if (self.io != null) own else null;
}

fn low32(d: ?i64) ?i64 {
    return (d orelse return null) & 0xffff_ffff;
}

/// §17.2.4.2 `$fgets(str, fd)`: characters into `str` "until str is filled,
/// or a newline character is read and transferred to str, or an EOF
/// condition is encountered"; a partial top byte of `str` holds none. The
/// count, 0 when nothing was read (and `str` is left alone).
fn fgets(self: *Run, a: std.mem.Allocator, t: contract.FileIo, args: []const Ast.ExprId) Error!i64 {
    const d = (try descriptor(self, a, args[1])) orelse return 0;
    const room = (try evaluate.targetType(self, args[0])).width / 8;
    const line = try readLine(a, t, d, room);
    if (line.len != 0) try evaluate.assign(self, a, args[0], try evaluate.stringLiteral(a, line));
    return @intCast(line.len);
}

/// §17.2.4.3 `$fscanf(fd, format, args...)`: `$sscanf` over the file from its
/// position, which then stands after the characters the scan used: "the
/// offending input character is left unread in the input stream".
fn fscanf(self: *Run, a: std.mem.Allocator, t: contract.FileIo, args: []const Ast.ExprId) Error!i64 {
    const d = (try descriptor(self, a, args[0])) orelse return -1;
    const format = try text(a, try evaluate.eval(self, a, args[1], 0));
    var file = try fileScan(a, t, d, format, args.len - 2);
    try scanContext(self, a, &file.scan, args[2..]);
    try scanAssign(self, a, &file.scan, args[2..]);
    return finishFileScan(t, file, file.scan);
}

/// §17.2.4.4 `$fread(myreg, fd)` / `$fread(mem, fd, start, count)`: whole
/// words of ceil(width/8) bytes each, the first byte the most significant;
/// a memory from `start` (default its lowest address) for at most `count`
/// words (default to its end). The count of characters read, 0 on none.
fn fread(self: *Run, a: std.mem.Allocator, t: contract.FileIo, args: []const Ast.ExprId) Error!i64 {
    const d = (try descriptor(self, a, args[1])) orelse return 0;
    const ex = &self.file.exprs;
    const base = if (ex.tag(args[0]) == .ident) try self.slot(args[0]) else 0;
    const arr = (if (ex.tag(args[0]) == .ident) self.arrays.get(base) else null) orelse {
        const width = (try evaluate.targetType(self, args[0])).width;
        const w = try readWord(a, t, d, width);
        if (w.value) |v| try evaluate.assign(self, a, args[0], overWord(v, try evaluate.eval(self, a, args[0], width), w.n));
        return w.n;
    };
    var at = if (args.len > 2 and args[2] != .none) (try int(self, a, args[2])) orelse return 0 else arr.low;
    var left = if (args.len > 3) (try int(self, a, args[3])) orelse return 0 else std.math.maxInt(i64);
    var read: i64 = 0;
    while (at >= arr.low and at <= arr.high and left > 0) {
        const w = try readWord(a, t, d, self.values[base].width);
        read += w.n;
        const slot = base + @as(u32, @intCast(at - arr.low));
        try waiters.store(self, slot, overWord(w.value orelse break, self.values[slot], w.n).planes);
        if (at == arr.high) break;
        at += 1;
        left -= 1;
    }
    return read;
}

test fileType {
    // §17.2.1 Table 17-7, every row.
    for ([_][]const u8{ "r", "rb", "w", "wb", "a", "ab", "r+", "r+b", "rb+", "w+", "w+b", "wb+", "a+", "a+b", "ab+" }) |ty|
        try std.testing.expect(fileType(ty));
    for ([_][]const u8{ "", "R", "rw", "rb+b", "x", "r +" }) |ty| try std.testing.expect(!fileType(ty));
}

test readLine {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    FakeFile.reset("ab\ncd");
    // §17.2.4.2: through the newline, then to EOF, then nothing.
    try std.testing.expectEqualStrings("ab\n", try readLine(a, FakeFile.io, 1, 8));
    try std.testing.expectEqualStrings("cd", try readLine(a, FakeFile.io, 1, 8));
    try std.testing.expectEqualStrings("", try readLine(a, FakeFile.io, 1, 8));
    // "until str is filled".
    FakeFile.reset("abc");
    try std.testing.expectEqualStrings("a", try readLine(a, FakeFile.io, 1, 1));
}

test readWord {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // §17.2.4.4: ceil(12 / 8) = 2 bytes, the first the most significant,
    // and only the low 12 bits of them kept: 0x1234 -> 0x234.
    FakeFile.reset("\x12\x34\x56");
    const w = try readWord(a, FakeFile.io, 1, 12);
    try std.testing.expectEqual(@as(i64, 2), w.n);
    try std.testing.expectEqual(@as(?i64, 0x234), w.value.?.asInt());
    // The file ends inside the next word: one byte read, its bits on top,
    // and `overWord` keeps the prior value's low byte (iverilog's fread.v).
    const short = try readWord(a, FakeFile.io, 1, 12);
    try std.testing.expectEqual(@as(i64, 1), short.n);
    const prior = try filled(a, 12, false, .x);
    const got = overWord(short.value.?, prior, short.n);
    for (0..8) |i| try std.testing.expectEqual(Int.Bit.x, got.bit(@intCast(i)));
    // 0x56's low nibble, bits 11..8.
    for (8..12, [_]Int.Bit{ .zero, .one, .one, .zero }) |i, want| try std.testing.expectEqual(want, got.bit(@intCast(i)));
    try std.testing.expect((try readWord(a, FakeFile.io, 1, 12)).value == null);
}

test fileOp {
    FakeFile.reset("xy");
    // An x or z descriptor or argument is EOF, as is a whence outside 0..2.
    try std.testing.expectEqual(@as(i64, -1), fileOp(FakeFile.io, .fgetc, null, null, null));
    try std.testing.expectEqual(@as(i64, -1), fileOp(FakeFile.io, .fseek, 1, 0, 3));
    try std.testing.expectEqual(@as(i64, -1), fileOp(FakeFile.io, .fseek, 1, null, 0));
    try std.testing.expectEqual(@as(i64, -1), fileOp(FakeFile.io, .ungetc, null, 1, null));
    try std.testing.expectEqual(@as(i64, 'x'), fileOp(FakeFile.io, .fgetc, 1, null, null));
    try std.testing.expectEqual(@as(i64, 1), fileOp(FakeFile.io, .ftell, 1, null, null));
    try std.testing.expectEqual(@as(i64, 0), fileOp(FakeFile.io, .rewind, 1, null, null));
    try std.testing.expectEqual(@as(i64, 0), fileOp(FakeFile.io, .feof, 1, null, null));
    try std.testing.expectEqual(@as(i64, 0), fileOp(FakeFile.io, .fseek, 1, 2, 0));
    try std.testing.expectEqual(@as(i64, 1), fileOp(FakeFile.io, .feof, 1, null, null));
    // §17.2.1: a descriptor is its low 32 bits, however it is signed, so
    // -1 is a descriptor like any other and not EOF.
    try std.testing.expectEqual(@as(i64, 2), fileOp(FakeFile.io, .ftell, -1, null, null));
}

test fopen {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A file read is looked for beside the source first; a write is not.
    try std.testing.expectEqual(@as(i64, 7), try fopen(FakeFile.io, a, "dir/src.v", "f.txt", "r", false));
    try std.testing.expectEqual(@as(i64, 3), try fopen(FakeFile.io, a, "dir/src.v", "f.txt", "w", false));
    // An mcd open is a write.
    try std.testing.expectEqual(@as(i64, 3), try fopen(FakeFile.io, a, "dir/src.v", "f.txt", null, true));
    // No name, no type, or a type outside Table 17-7: 0.
    try std.testing.expectEqual(@as(i64, 0), try fopen(FakeFile.io, a, "src.v", null, "r", false));
    try std.testing.expectEqual(@as(i64, 0), try fopen(FakeFile.io, a, "src.v", "f.txt", null, false));
    try std.testing.expectEqual(@as(i64, 0), try fopen(FakeFile.io, a, "src.v", "f.txt", "rw", false));
}

test "§17.2.4.3 a file scan leaves the descriptor just past what it used" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    FakeFile.reset("12 ab");
    var file = try fileScan(arena.allocator(), FakeFile.io, 1, "%d", 1);
    const x = file.scan.next().?;
    try std.testing.expectEqual(@as(u64, 12), x.value.bits[0]);
    try std.testing.expect(file.scan.next() == null);
    try std.testing.expectEqual(@as(i64, 1), finishFileScan(FakeFile.io, file, file.scan));
    // "12" consumed: the next read is the space after it.
    try std.testing.expectEqual(@as(usize, 2), FakeFile.pos);
    // A descriptor with an x bit scans no input: EOF.
    const none = try fileScan(arena.allocator(), FakeFile.io, null, "%d", 1);
    try std.testing.expectEqual(@as(i64, -1), finishFileScan(FakeFile.io, none, none.scan));
}

test channels {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    const fd: i64 = @as(i64, 1) << 31;
    // §17.2.1: an mcd's bit 0 and fd 1 are standard output, the transcript.
    try std.testing.expect(!try channels(null, null, &out.writer, 1, "a"));
    try std.testing.expect(!try channels(null, null, &out.writer, fd | 1, "b"));
    // Without a table the other channels have no one to refuse them.
    try std.testing.expect(!try channels(null, null, &out.writer, 3, "c"));
    try std.testing.expect(!try channels(null, null, &out.writer, fd | 3, "-"));
    try std.testing.expectEqualStrings("abc", out.written());
    // A table that takes none of the bytes: W1154's case. Empty text
    // reports nothing.
    FakeFile.reset("");
    try std.testing.expect(try channels(FakeFile.io, null, &out.writer, fd | 3, "d"));
    try std.testing.expect(try channels(FakeFile.io, null, &out.writer, 2, "e"));
    try std.testing.expect(!try channels(FakeFile.io, null, &out.writer, 2, ""));
    try std.testing.expectEqual(@as(usize, 2), FakeFile.put_bytes);
    try std.testing.expectEqualStrings("abc", out.written());
}
