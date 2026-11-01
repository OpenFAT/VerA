//! A memory file's text in (§17.2.9 `$readmemb`/`$readmemh`), the words it loads into an unpacked array out, with the warnings a terminated or short load raises (W1150, W1156, W1157).
//! Cites: IEEE 1364-2005 §17.2.9.
//!
//! Contents:
//! - `pub const MemTokens = struct`
//! - `pub const MemLoad = struct`
//! - `MemLoad.Word = struct`
//! - `MemLoad.Failure = error`
//! - `MemLoad.init(in: *std.Io.Reader, radix: Radix, width: u32, low: i64, high: i64, given: u2, start: ?i64, finish: ?i64) MemLoad`
//! - `MemLoad.next(self: *MemLoad, a: std.mem.Allocator) Failure!?Word`
//! - `MemLoad.mismatch(self: *const MemLoad) ?struct { found: u128, expected: u128 }`
//! - `MemLoad.message(e: Failure) []const u8`
//! - `MemLoad.mismatch_text`
//! - `MemLoad.outside_text`
//! - `MemLoad.out_of_range_text`
//! - `pub const load_ended`
//! - `pub const unknown_bound`
//! - `pub const not_a_name`
//! - `pub const outside_memory`
//! - `pub const cannot_read`
//! - `pub fn memWord(a: std.mem.Allocator, token: []const u8, radix: Radix, width: u32) !Int.Literal`
//! - `pub fn readMemory(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, radix: Radix) Error!void`
//! - `pub fn sideFile(io: std.Io, a: std.mem.Allocator, file_name: []const u8, name: []const u8) !std.Io.File`
//! - `pub fn expectMemoryLoad(data: []const u8, bounds: []const u8, expected: []const u8, warnings: u32, terminated: bool) !void`
//! - `pub fn expectMemoryLoadDiagnostic(task: []const u8, data: []const u8, bounds: []const u8, expected: []const u8, warnings: u32, failure_phrase: ?[]const u8) !void`
//! §17 display, strobe, monitor, `%t` and memory-load formatting: a task's
//! arguments and the values they name (or a memory file's text) in; bytes on
//! `Run.out` (or words stored into an unpacked array) out. With a null
//! allocator the same walk validates the call without printing.
//! Clauses: §9.4.1 Table 9-1, §9.4.3 Table 9-22; IEEE 1364-2005 §17.1.1.3,
//! §17.1.1.4, §17.1.2, §17.1.3, §17.2.9, §17.3, §17.7.2.
const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const compile = @import("compile.zig");
const waiters = @import("waiters.zig");
const evaluate = @import("evaluate.zig");
const Error = @import("root.zig").Error;
const Run = @import("root.zig").Run;
const Standing = @import("root.zig").Standing;
const run = @import("root.zig").run;
const expectRun = @import("root.zig").expectRun;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const Signal = @import("net.zig").Signal;
const netPull = @import("net.zig").netPull;
/// §9.4.3 Table 9-23's C conversion, the one the analog devices run.
const str_real = @import("kernels").str_real;
const zCReal = str_real.zCReal;
const system = @import("system.zig");
const fmt = @import("kernels").fmt;
const Radix = fmt.Radix;
/// §17.3.2 `$timeformat`'s state; the type is `fmt`'s so `rt` shares it.
const TimeFormat = fmt.TimeFormat;
const display = @import("display.zig");

/// IEEE 1364-2005 §17.2.9's memory-file lexer: white space and §2.4 comments
/// separate tokens, and a token is either an `@`-address or one data word.
/// It reads the file as a stream, so the file's size bounds nothing; one
/// token is held at a time. A byte that is not printable ASCII is a token of
/// its own, which no word or address accepts, so a binary file (or a stream
/// with no end, such as /dev/zero) is refused at its first such byte.
pub const MemTokens = struct {
    in: *std.Io.Reader,
    token: std.ArrayList(u8) = .empty,

    fn isSpace(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == '\x0c';
    }

    /// Byte `k` ahead, or null past the end of the file.
    fn peek(self: *MemTokens, k: usize) error{ReadFailed}!?u8 {
        const ahead = self.in.peek(k + 1) catch |e| return switch (e) {
            error.EndOfStream => null,
            error.ReadFailed => error.ReadFailed,
        };
        return ahead[k];
    }

    /// Is the byte at the read position the start of a comment?
    fn comment(self: *MemTokens) error{ReadFailed}!?u8 {
        if (try self.peek(0) != '/') return null;
        const d = try self.peek(1) orelse return null;
        return if (d == '/' or d == '*') d else null;
    }

    fn next(self: *MemTokens, a: std.mem.Allocator) error{ ReadFailed, OutOfMemory }!?[]const u8 {
        self.token.clearRetainingCapacity();
        while (try self.peek(0)) |c| {
            if (isSpace(c)) {
                self.in.toss(1);
                continue;
            }
            const kind = try self.comment() orelse break;
            self.in.toss(2);
            if (kind == '/') {
                while (try self.peek(0)) |d| : (self.in.toss(1)) if (d == '\n') break;
                continue;
            }
            // `/*` closes at the first `*/` after it: `/*/` does not.
            var star = false;
            while (try self.peek(0)) |d| {
                self.in.toss(1);
                if (star and d == '/') break;
                star = d == '*';
            }
        } else return null;
        const first = (try self.peek(0)).?;
        if (!std.ascii.isPrint(first)) {
            self.in.toss(1);
            try self.token.append(a, first);
            return self.token.items;
        }
        while (try self.peek(0)) |d| {
            // A comment may abut a word: `/* ... */ d4` is one word, and so
            // is `d4// trailing`.
            if (isSpace(d) or !std.ascii.isPrint(d) or try self.comment() != null) break;
            try self.token.append(a, d);
            self.in.toss(1);
        }
        return self.token.items;
    }
};

/// IEEE 1364-2005 §17.2.9 `$readmemb` / `$readmemh` over a memory file's
/// text: each `next` is one word to store, in file order. The one load walk
/// the interpreter and a native executable share.
///
/// The clause's rules:
///   - the file holds white space, comments and numbers in the task's radix;
///   - with no address arguments loading goes from lowest to highest index;
///   - `@<hex>` relocates the load point, and loading continues from there;
///   - an address the file never reaches is left alone: an unwritten word
///     keeps the x it started at.
///
/// With a start and a finish the load runs from one toward the other,
/// downward when start > finish: the direction is the argument order, not
/// the declaration's.
pub const MemLoad = struct {
    it: MemTokens,
    radix: Radix,
    /// Every element's width, and the array's declared index range.
    width: u32,
    low: i64,
    high: i64,
    at: i64,
    last: i64,
    down: bool,
    /// A start argument was given: a file address must lie in the range.
    bounded: bool,
    range_low: i64,
    range_high: i64,
    words: u128 = 0,
    addressed: bool = false,
    exhausted: bool = false,
    /// The first file address outside `low..high` in a load with no
    /// bounds arguments, which `outside_text` warns of (W1156).
    outside: ?i64 = null,

    /// One word: element `index` (from the lowest declared address) takes
    /// `value`, `width` bits wide.
    pub const Word = struct { index: u32, value: Int.Literal };

    /// §17.2.9: `BadAddress`, an `@` address that is not hex;
    /// `AddressOutOfRange`, an address outside the call's start..finish
    /// range; `BadWord`, a word that is not a number in the task's radix;
    /// `ReadFailed`, the file could not be read to its end.
    pub const Failure = error{ BadAddress, AddressOutOfRange, BadWord, ReadFailed } || std.mem.Allocator.Error;

    /// `in` is the file. `given` is how many of the start and finish
    /// arguments the call has; `start`/`finish` are their values, null where
    /// x or z.
    pub fn init(in: *std.Io.Reader, radix: Radix, width: u32, low: i64, high: i64, given: u2, start: ?i64, finish: ?i64) MemLoad {
        // §17.2.9: default traversal is lowest to highest, independent of
        // the declaration's direction.
        const at = if (given >= 1) start orelse low else low;
        const last = if (given == 2) finish orelse high else high;
        // With start alone, finish defaults to the highest address and the
        // walk stays upward, including after a file address specification.
        return .{
            .it = .{ .in = in },
            .radix = radix,
            .width = width,
            .low = low,
            .high = high,
            .at = at,
            .last = last,
            .down = given == 2 and last < at,
            .bounded = given >= 1,
            .range_low = @min(at, last),
            .range_high = @max(at, last),
        };
    }

    /// The next word to store, or null at the end of the file. A word
    /// outside the declared range is dropped.
    pub fn next(self: *MemLoad, a: std.mem.Allocator) Failure!?Word {
        while (try self.it.next(a)) |token| {
            if (token[0] == '@') {
                self.addressed = true;
                // §3.5.1: `_` is legal anywhere but first, so also last,
                // which `parseInt` refuses (VD-041). x, z and ? name no
                // word and stay malformed.
                self.at = std.fmt.parseInt(i64, std.mem.trimEnd(u8, token[1..], "_"), 16) catch return error.BadAddress;
                if (self.bounded and (self.at < self.range_low or self.at > self.range_high)) return error.AddressOutOfRange;
                // No bounds: the clause's error does not apply, so its
                // words are skipped with a warning (VD-040).
                if (!self.bounded and self.outside == null and (self.at < self.low or self.at > self.high)) self.outside = self.at;
                self.exhausted = false;
                continue;
            }
            self.words += 1;
            // Continue scanning after the final word: a later address both
            // suppresses count warnings and may restart loading in the range.
            if (self.exhausted) {
                // Stopping assignments does not legalize malformed file data.
                // Validate without allocating a destination-sized value.
                validateMemWord(token, self.radix) catch return error.BadWord;
                continue;
            }
            const at = self.at;
            if (self.down) {
                if (self.at <= self.last) self.exhausted = true else self.at -= 1;
            } else {
                if (self.at >= self.last) self.exhausted = true else self.at += 1;
            }
            // Outside the declared range the word has nowhere to go. Not an
            // error: a file longer than the memory is the clause's own
            // "more data than the range" case.
            if (at < self.low or at > self.high) continue;
            // `filled` fails only for want of memory.
            const value = memWord(a, token, self.radix, self.width) catch |e|
                return if (e == error.BadDigit) error.BadWord else error.OutOfMemory;
            return .{ .index = @intCast(at - self.low), .value = value };
        }
        return null;
    }

    /// Once `next` returned null: the words found and the range expected
    /// when they differ with no address in the file, which §17.2.9 says
    /// warrants a warning (W1150).
    pub fn mismatch(self: *const MemLoad) ?struct { found: u128, expected: u128 } {
        const expected: u128 = @intCast(@as(i128, self.range_high) - self.range_low + 1);
        if (self.addressed or self.words == expected) return null;
        return .{ .found = self.words, .expected = expected };
    }

    /// The diagnostic text of `e`, shared by both engines.
    pub fn message(e: Failure) []const u8 {
        return switch (e) {
            error.BadAddress => "the memory file has a malformed `@` address",
            error.AddressOutOfRange => "memory file address is outside the requested load range",
            error.BadWord => "the memory file has a malformed data word",
            error.ReadFailed => "the memory file cannot be read to its end",
            error.OutOfMemory => "out of memory",
        };
    }

    /// The W1150 text; the arguments are `found` then `expected`.
    pub const mismatch_text = "memory file data word count does not match load range: found {d}, expected {d}";

    /// The W1156 text; the arguments are `outside`, then `low` and `high`.
    pub const outside_text = "memory file address @{x} is outside the memory's declared range [{d}:{d}]; its words are skipped";

    /// The W1157 text, after `next` failed with `AddressOutOfRange`; the
    /// arguments are the address (`at`), then `range_low` and `range_high`.
    /// §17.2.9: "an error message is issued, and the load operation is
    /// terminated": the load, not the run (#65).
    pub const out_of_range_text = "§17.2.9: memory file address @{x} is outside the load range [{d}:{d}] the task gives (the words before it stay loaded)";
};

/// The tail of every W1157 message.
pub const load_ended = "; the $readmem load is terminated, the simulation goes on";

/// §17.2.9 gives an address no x or z digit, so a bound that evaluates to
/// one names no address.
pub const unknown_bound = "a $readmem start or finish address evaluates to x or z";

/// A file name held in a variable with an x or z bit names no file.
pub const not_a_name = "the $readmem file name has an x or z bit, so it names no file";

/// A start or finish address outside the memory's declared range: no word
/// is loaded (§17.2.9 says nothing of it; iverilog loads none). The
/// arguments are which bound, its value, then the memory's low and high.
pub const outside_memory = "the $readmem {s} address {d} is outside the memory's range [{d}:{d}]";

/// A memory file that cannot be opened; the argument is its name, as
/// `std.zig.fmtString` escapes a non-printing character in it.
pub const cannot_read = "the memory file \"{f}\" cannot be read";

const MemDigit = struct { digit: u32 = 0, fill: ?Int.Bit = null };

/// One data word, right-justified into the memory's declared width. §17.2.9
/// says the digits may be `x` or `z` for either task, and an unknown digit is
/// unknown in every bit it covers, so this shares `Radix.perDigit` with the
/// printer rather than parsing a number and losing the states.
pub fn memWord(a: std.mem.Allocator, token: []const u8, radix: Radix, width: u32) !Int.Literal {
    // Validation covers discarded high digits independently of stored width.
    try validateMemWord(token, radix);
    const per = radix.perDigit();
    const value = try filled(a, width, false, .zero);
    var bit: u32 = 0;
    var i = token.len;
    while (i != 0 and bit < width) {
        i -= 1;
        const c = std.ascii.toLower(token[i]);
        // §2.6's readability separator is legal in a data word too.
        if (c == '_') continue;
        const decoded = try memDigit(c, radix);
        var k: u32 = 0;
        while (k < per and bit < width) : ({
            k += 1;
            bit += 1;
        }) setBit(value, bit, decoded.fill orelse @fromBackingInt(@intCast(@as(u2, @intCast((decoded.digit >> @intCast(k)) & 1)))));
    }
    return value;
}

/// The interpreter's `$readmemb` / `$readmemh` (`MemLoad`).
pub fn readMemory(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, radix: Radix) Error!void {
    const ex = &self.file.exprs;
    const base = try self.slot(args[1]);
    const arr = self.decls.arrays.get(base).?;
    const tok = ex.mainTok(args[0]);
    const at = self.starts[@min(tok, self.starts.len - 1)];
    const site: diag.Span = .{ .start = at, .end = at };
    const name = if (ex.tag(args[0]) == .str_literal)
        self.file.str(ex.strOf(args[0]))
    else
        (try system.text(a, try evaluate.eval(self, a, args[0], 0))) orelse return loadEnded(self, site, not_a_name, .{});
    const io = self.io orelse return loadEnded(self, site, cannot_read, .{std.zig.fmtString(name)});
    const file = sideFile(io, a, self.file_name, name) catch return loadEnded(self, site, cannot_read, .{std.zig.fmtString(name)});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var in = file.reader(io, &buf);
    const start = if (args.len >= 3) (try evaluate.eval(self, a, args[2], 0)).asInt() orelse return loadEnded(self, site, unknown_bound, .{}) else null;
    const finish = if (args.len == 4) (try evaluate.eval(self, a, args[3], 0)).asInt() orelse return loadEnded(self, site, unknown_bound, .{}) else null;
    for ([_]?i64{ start, finish }, [_][]const u8{ "start", "finish" }) |bound, which| if (bound) |b| if (b < arr.low or b > arr.high)
        return loadEnded(self, site, outside_memory, .{ which, b, arr.low, arr.high });
    var load: MemLoad = .init(&in.interface, radix, self.values[base].width, arr.low, arr.high, @intCast(args.len - 2), start, finish);
    while (load.next(a) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.AddressOutOfRange => return loadEnded(self, site, MemLoad.out_of_range_text, .{ load.at, load.range_low, load.range_high }),
        else => |f| return loadEnded(self, site, "{s}", .{MemLoad.message(f)}),
    }) |w| try waiters.store(self, base + w.index, w.value.planes);
    if (load.mismatch()) |m| try self.bag.add(self.stage(), .W1150, site, MemLoad.mismatch_text, .{ m.found, m.expected });
    if (load.outside) |o| try self.bag.add(self.stage(), .W1156, site, MemLoad.outside_text, .{ o, arr.low, arr.high });
}

/// The memory file `name`, opened. It sits beside the source `file_name`
/// that names it, which is what makes a fixture self-contained; the working
/// directory is tried second, so a path written relative to where the
/// simulator was launched still works. IEEE 1364-2005 §17.2.9 bounds no
/// memory file, and `MemLoad` reads it as a stream.
pub fn sideFile(io: std.Io, a: std.mem.Allocator, file_name: []const u8, name: []const u8) !std.Io.File {
    const cwd = std.Io.Dir.cwd();
    if (std.Io.Dir.path.dirname(file_name)) |dir| {
        const joined = try std.Io.Dir.path.join(a, &.{ dir, name });
        if (cwd.openFile(io, joined, .{})) |file| return file else |_| {}
    }
    return cwd.openFile(io, name, .{});
}

/// `terminated`: a file address falls outside the task's range, so §17.2.9's
/// "an error message is issued, and the load operation is terminated":
/// W1157, the words before it stay loaded and the run goes on to print them
/// (#65, VD-134).
pub fn expectMemoryLoad(data: []const u8, bounds: []const u8, expected: []const u8, warnings: u32, terminated: bool) !void {
    return expectMemoryLoadDiagnostic("$readmemh", data, bounds, expected, warnings, if (terminated) "is outside the load range" else null);
}

/// Test support: `task` loads `data` into a 4-word memory under `bounds`;
/// the transcript must be `expected`, with `warnings` warnings, one of them
/// naming `failure_phrase` when given.
pub fn expectMemoryLoadDiagnostic(task: []const u8, data: []const u8, bounds: []const u8, expected: []const u8, warnings: u32, failure_phrase: ?[]const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "words.hex", .data = data });
    const file_name = try a.print(".zig-cache/tmp/{s}/test.v", .{tmp.sub_path});
    const source = try a.print("module m; reg [7:0] mem[3:0]; initial begin " ++
        "mem[0]=8'haa; mem[1]=8'hbb; mem[2]=8'hcc; mem[3]=8'hdd; " ++
        "{s}(\"words.hex\",mem{s}); " ++
        "$display(\"%h %h %h %h\",mem[0],mem[1],mem[2],mem[3]); end endmodule", .{ task, bounds });
    var bag = diag.Bag.init(a);
    var output = std.Io.Writer.Allocating.init(a);
    const result = run(a, source, .{ .io = std.testing.io, .file_name = file_name }, &bag, &output.writer);
    // A terminated load (W1157) never ends the run nor fails it (VD-134).
    try result;
    try std.testing.expect(!bag.failed());
    if (failure_phrase) |phrase| {
        var messages = std.Io.Writer.Allocating.init(a);
        try diag.render(&bag, &messages.writer, .{});
        try std.testing.expect(std.mem.find(u8, messages.written(), "W1157") != null);
        try std.testing.expect(std.mem.find(u8, messages.written(), phrase) != null);
    }
    try std.testing.expectEqual(warnings, bag.warn_count);
    try std.testing.expectEqualStrings(expected, output.written());
}

// ---- private ----

fn memDigit(character: u8, radix: Radix) !MemDigit {
    const c = std.ascii.toLower(character);
    switch (c) {
        'x' => return .{ .fill = .x },
        'z', '?' => return .{ .fill = .z },
        else => {},
    }
    const digit: u32 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => return error.BadDigit,
    };
    if (digit >= @backingInt(radix)) return error.BadDigit;
    return .{ .digit = digit };
}

fn validateMemWord(token: []const u8, radix: Radix) !void {
    // IEEE3.5/3.5.1: a number starts with a digit, not a separator.
    if (token.len == 0 or token[0] == '_') return error.BadDigit;
    for (token) |c| {
        if (c == '_') continue;
        _ = try memDigit(c, radix);
    }
}

/// §17.2.9 "an error message is issued, and the load operation is
/// terminated": W1157 names why, the words loaded before it stay, and the
/// simulation goes on with its exit status untouched, as iverilog's does
/// (specification/Vague_Decisions.md VD-134). Every reason a load cannot go
/// on takes this one path, in both engines.
fn loadEnded(self: *Run, site: diag.Span, comptime why: []const u8, args: anytype) Error!void {
    try self.bag.add(self.stage(), .W1157, site, why ++ load_ended, args);
    if (self.host.error_hook) |hook| hook(self);
}

test "readmem validates high token characters beyond destination width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // IEEE17.2.9 forbids length/base prefixes and non-radix digits, even
    // where all of those characters would be discarded by value truncation.
    for ([_][]const u8{ "8'h11", "'h11", "g11", ";11" }) |token|
        try std.testing.expectError(error.BadDigit, memWord(a, token, .hex, 8));
    for ([_][]const u8{ "8'b00010001", "'b00010001", "200010001", "g00010001" }) |token|
        try std.testing.expectError(error.BadDigit, memWord(a, token, .binary, 8));
    // Valid high digits remain legal and truncate; separators still do not
    // consume bit positions. Validation must not become a width rejection.
    const hex = try memWord(a, "aB_11", .hex, 8);
    const bin = try memWord(a, "10_00010001", .binary, 8);
    try std.testing.expectEqual(@as(?i64, 17), hex.asInt());
    try std.testing.expectEqual(@as(?i64, 17), bin.asInt());
}

test "readmem count mismatch warns without refusing or clearing memory" {
    try expectMemoryLoad("// @0 is only a comment\n", "", "aa bb cc dd\n", 1, false);
    try expectMemoryLoad("11 22 33 44 55", "", "11 22 33 44\n", 1, false);
    try expectMemoryLoad("11 // 99\n22 /* 88 */", ",0,3", "11 22 cc dd\n", 1, false);
    try expectMemoryLoad("11 22 33 44", ",0,3", "11 22 33 44\n", 0, false);
    try expectMemoryLoad("11 22 33 44 55", ",3,0", "44 33 22 11\n", 1, false);
    try expectMemoryLoad("11 22", ",3,0", "aa bb 22 11\n", 1, false);
    try expectMemoryLoad("11 22 33 44", ",3,0", "44 33 22 11\n", 0, false);
}

test "readmem question mark is high impedance in both radices" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hex = try memWord(a, "0?", .hex, 8);
    const bin = try memWord(a, "0000000?", .binary, 8);
    for (0..4) |i| try std.testing.expectEqual(Int.Bit.z, hex.bit(@intCast(i)));
    try std.testing.expectEqual(Int.Bit.z, bin.bit(0));
}

test "readmem underscore must follow an initial digit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_]Radix{ .hex, .binary }) |radix| {
        for ([_][]const u8{ "_", "__", "_11" }) |token|
            try std.testing.expectError(error.BadDigit, memWord(arena.allocator(), token, radix, 8));
    }
    const legal = try memWord(arena.allocator(), "1__1_", .hex, 8);
    try std.testing.expectEqual(@as(?i64, 17), legal.asInt());
}

test "readmem validates discarded excess tokens and still restarts after addresses" {
    const invalid = "the memory file has a malformed data word";
    // The load ends at the bad word; the words before it stay (iverilog
    // prints the same memory for the first two, and takes `_` as a word).
    try expectMemoryLoadDiagnostic("$readmemh", "11 ;", ",0,0", "11 bb cc dd\n", 1, invalid);
    try expectMemoryLoadDiagnostic("$readmemb", "1 2", ",0,0", "01 bb cc dd\n", 1, invalid);
    try expectMemoryLoadDiagnostic("$readmemh", "11 _", ",0,0", "11 bb cc dd\n", 1, invalid);
    try expectMemoryLoadDiagnostic("$readmemh", "11 22", ",0,0", "11 bb cc dd\n", 1, null);
    try expectMemoryLoadDiagnostic("$readmemh", "11 22 @0 33", ",0,0", "33 bb cc dd\n", 0, null);
}

test "readmem addresses suppress count warning and relocate after range end" {
    try expectMemoryLoad("@1 11", ",0,3", "aa 11 cc dd\n", 0, false);
    try expectMemoryLoad("11 22 33 44 55 @2 66", ",0,3", "11 22 66 44\n", 0, false);
    try expectMemoryLoad("11 22 33 44 @2 66 77", ",3,0", "44 77 66 11\n", 0, false);
    // §17.2.9 (#65): an address outside the task's range ends the load, not
    // the run. 11 -> mem[1], 22 -> mem[2], then @0 is outside 1..2.
    try expectMemoryLoad("11 22 @0", ",1,2", "aa 11 22 dd\n", 1, true);
    // @3 is outside 2..1 before any word: nothing loads.
    try expectMemoryLoad("@3 11", ",2,1", "aa bb cc dd\n", 1, true);
}

test "readmem start-only defaults to highest address and stays upward" {
    try expectMemoryLoad("11 22", ",2", "aa bb 11 22\n", 0, false);
    try expectMemoryLoad("11", ",2", "aa bb 11 dd\n", 1, false);
    try expectMemoryLoad("11 22 33", ",2", "aa bb 11 22\n", 1, false);
    try expectMemoryLoad("11", ",3", "aa bb cc 11\n", 0, false);
    try expectMemoryLoad("@3 11 @2 22 33", ",2", "aa bb 22 33\n", 0, false);
    // §17.2.9 (#65): start alone makes the range 2..3, the memory's highest
    // address; an address outside it ends the load, not the run. @1 comes
    // before any word: nothing loads.
    try expectMemoryLoad("@1 11", ",2", "aa bb cc dd\n", 1, true);
    // 11 -> mem[2], 22 -> mem[3], then @4 is outside 2..3.
    try expectMemoryLoad("11 22 @4", ",2", "aa bb 11 22\n", 1, true);
}

test "readmem formfeeds delimit words and addresses without adding words" {
    try expectMemoryLoad("\x0c11\x0c22\x0c33\x0c44\x0c", "", "11 22 33 44\n", 0, false);
    try expectMemoryLoad("\x0c@2\x0c11\x0c22\x0c", ",2", "aa bb 11 22\n", 0, false);
    try expectMemoryLoad("/* not words: @0 55 */\x0c11\x0c22", ",2", "aa bb 11 22\n", 0, false);
    try expectMemoryLoadDiagnostic("$readmemb", "\x0c00010001\x0c00100010\x0c", ",2", "aa bb 11 22\n", 0, null);
    try expectMemoryLoadDiagnostic("$readmemb", "@3\x0c1\x0c@2\x0c10\x0c11", ",2", "aa bb 02 03\n", 0, null);
}

test "§17.2.9 memory-file tokens: white space and both comment forms separate them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var in: std.Io.Reader = .fixed("a//x\nb/*y*/c \x0c d/*/ e */f/g/* never closed");
    var it: MemTokens = .{ .in = &in };
    for ([_][]const u8{ "a", "b", "c", "d", "f/g" }) |want| try std.testing.expectEqualStrings(want, (try it.next(a)).?);
    try std.testing.expect(try it.next(a) == null);
    // A byte that is not printable ASCII ends a word and is a token itself.
    var bin: std.Io.Reader = .fixed("1f\x00\x002");
    it = .{ .in = &bin };
    for ([_][]const u8{ "1f", "\x00", "\x00", "2" }) |want| try std.testing.expectEqualStrings(want, (try it.next(a)).?);
}

test MemLoad {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // §17.2.9 with no address arguments: lowest address up, one word each.
    {
        var in1: std.Io.Reader = .fixed("11 22 // c\n33");
        var load: MemLoad = .init(&in1, .hex, 8, 0, 3, 0, null, null);
        for ([_]u32{ 0, 1, 2 }, [_]i64{ 0x11, 0x22, 0x33 }) |index, value| {
            const w = (try load.next(a)).?;
            try std.testing.expectEqual(index, w.index);
            try std.testing.expectEqual(@as(?i64, value), w.value.asInt());
        }
        try std.testing.expect((try load.next(a)) == null);
        // Three words for a four-word range warns (W1150).
        const m = load.mismatch().?;
        try std.testing.expectEqual(@as(u128, 3), m.found);
        try std.testing.expectEqual(@as(u128, 4), m.expected);
    }
    // `@` relocates, a word past the last address has nowhere to go, and an
    // addressed file is not counted.
    {
        var in2: std.Io.Reader = .fixed("@2 aa bb cc");
        var load: MemLoad = .init(&in2, .hex, 8, 0, 3, 0, null, null);
        try std.testing.expectEqual(@as(u32, 2), (try load.next(a)).?.index);
        try std.testing.expectEqual(@as(u32, 3), (try load.next(a)).?.index);
        try std.testing.expect((try load.next(a)) == null);
        try std.testing.expect(load.mismatch() == null);
    }
    // No bounds: an address outside the declaration skips its words (W1156).
    {
        var in3: std.Io.Reader = .fixed("@5 11");
        var load: MemLoad = .init(&in3, .hex, 8, 0, 3, 0, null, null);
        try std.testing.expect((try load.next(a)) == null);
        try std.testing.expectEqual(@as(?i64, 5), load.outside);
    }
    // A start after the finish walks downward.
    {
        var in4: std.Io.Reader = .fixed("11 22");
        var load: MemLoad = .init(&in4, .hex, 8, 0, 3, 2, 3, 0);
        try std.testing.expectEqual(@as(u32, 3), (try load.next(a)).?.index);
        try std.testing.expectEqual(@as(u32, 2), (try load.next(a)).?.index);
    }
    // The clause's errors: an address outside the call's range, an address
    // that is not hex, and a word that is not a number in the radix.
    {
        var in5: std.Io.Reader = .fixed("@0 11");
        var load: MemLoad = .init(&in5, .hex, 8, 0, 3, 2, 1, 2);
        try std.testing.expectError(error.AddressOutOfRange, load.next(a));
    }
    {
        var in6: std.Io.Reader = .fixed("@g 11");
        var load: MemLoad = .init(&in6, .hex, 8, 0, 3, 0, null, null);
        try std.testing.expectError(error.BadAddress, load.next(a));
    }
    {
        var in7: std.Io.Reader = .fixed("12");
        var load: MemLoad = .init(&in7, .binary, 8, 0, 3, 0, null, null);
        try std.testing.expectError(error.BadWord, load.next(a));
    }
    // VD-041: a trailing `_` in an address is legal.
    {
        var in8: std.Io.Reader = .fixed("@1_ 7");
        var load: MemLoad = .init(&in8, .hex, 8, 0, 3, 0, null, null);
        try std.testing.expectEqual(@as(u32, 1), (try load.next(a)).?.index);
    }
}
