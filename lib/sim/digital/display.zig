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
const str_k = @import("kernels").str_kernels;
const zCReal = str_k.zCReal;
const system = @import("system.zig");
const fmt = @import("kernels").fmt;

// ---- memory files (IEEE 1364 §17.2.9) ---------------------------------------

/// IEEE 1364-2005 §17.2.9's memory-file lexer: white space and §2.4 comments
/// separate tokens, and a token is either an `@`-address or one data word.
/// It reads the file as a stream, so the file's size bounds nothing; one
/// token is held at a time. A byte that is not printable ASCII is a token of
/// its own, which no word or address accepts, so a binary file (or a stream
/// with no end, such as /dev/zero) is refused at its first such byte.
const MemTokens = struct {
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

const MemDigit = struct { digit: u32 = 0, fill: ?Int.Bit = null };

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

/// One data word, right-justified into the memory's declared width. §17.2.9
/// says the digits may be `x` or `z` for either task, and an unknown digit is
/// unknown in every bit it covers, so this shares `Radix.perDigit` with the
/// printer rather than parsing a number and losing the states.
fn memWord(a: std.mem.Allocator, token: []const u8, radix: Radix, width: u32) !Int.Literal {
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
            error.ReadFailed => cannot_read,
            error.OutOfMemory => "out of memory",
        };
    }

    /// The W1150 text; the arguments are `found` then `expected`.
    pub const mismatch_text = "memory file data word count does not match load range: found {d}, expected {d}";

    /// The W1156 text; the arguments are `outside`, then `low` and `high`.
    pub const outside_text = "memory file address @{x} is outside the memory's declared range [{d}:{d}]; its words are skipped";

    /// The E1157 text, after `next` failed with `AddressOutOfRange`; the
    /// arguments are the address (`at`), then `range_low` and `range_high`.
    /// §17.2.9: "an error message is issued, and the load operation is
    /// terminated": the load, not the run (#65).
    pub const out_of_range_text = "§17.2.9: memory file address @{x} is outside the load range [{d}:{d}] the task gives; the load is terminated, the words before it stay loaded";
};

/// The interpreter's `$readmemb` / `$readmemh` (`MemLoad`).
pub fn readMemory(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, radix: Radix) Error!void {
    const ex = &self.file.exprs;
    const base = try self.slot(args[1]);
    const arr = self.arrays.get(base).?;
    const name = self.file.str(ex.strOf(args[0]));
    const io = self.io orelse return self.exprFail(args[0], cannot_read);
    const file = sideFile(io, a, self.file_name, name) catch return self.exprFail(args[0], cannot_read);
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var in = file.reader(io, &buf);
    const start = if (args.len >= 3) (try evaluate.eval(self, a, args[2], 0)).asInt() orelse return self.exprFail(args[2], unknown_bound) else null;
    const finish = if (args.len == 4) (try evaluate.eval(self, a, args[3], 0)).asInt() orelse return self.exprFail(args[3], unknown_bound) else null;
    var load: MemLoad = .init(&in.interface, radix, self.values[base].width, arr.low, arr.high, @intCast(args.len - 2), start, finish);
    while (load.next(a) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // An error message, the load terminated, and the run goes on.
        error.AddressOutOfRange => {
            const tok = ex.mainTok(args[0]);
            const at = self.starts[@min(tok, self.starts.len - 1)];
            return self.bag.add(self.stage(), .E1157, .{ .start = at, .end = at }, MemLoad.out_of_range_text, .{ load.at, load.range_low, load.range_high });
        },
        else => |f| return self.fail(ex.mainTok(args[0]), "{s}", .{MemLoad.message(f)}),
    }) |w| try waiters.store(self, base + w.index, w.value.planes);
    if (load.mismatch()) |m| {
        const tok = ex.mainTok(args[0]);
        const at = self.starts[@min(tok, self.starts.len - 1)];
        try self.bag.add(self.stage(), .W1150, .{ .start = at, .end = at }, MemLoad.mismatch_text, .{ m.found, m.expected });
    }
    if (load.outside) |o| {
        const tok = ex.mainTok(args[0]);
        const at = self.starts[@min(tok, self.starts.len - 1)];
        try self.bag.add(self.stage(), .W1156, .{ .start = at, .end = at }, MemLoad.outside_text, .{ o, arr.low, arr.high });
    }
}

/// §17.2.9 gives an address no x or z digit, so a bound that evaluates to
/// one names no address and the load is refused rather than defaulted.
pub const unknown_bound = "a $readmem start or finish address evaluates to x or z";

/// The refusal of a memory file that cannot be opened or read to its end.
pub const cannot_read = "the memory file cannot be read";

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

// ---- the task table (§9.4.1 Table 9-1, §17.3) -------------------------------

const Radix = fmt.Radix;

/// §9.4.1 Table 9-1's display family, which is one task with two axes: the
/// radix an argument with no format specification is printed in, and whether
/// the call ends with a newline. "The $write task provides the same
/// capabilities as $display, but with no newline."
/// `file`: §17.2.2's `$fstrobe`/`$fmonitor`, whose first argument is the
/// descriptor the line goes to.
pub const Show = struct { radix: Radix, newline: bool, file: bool = false };

/// The display families of §9.4.1 Table 9-1 differ in when they run, not in
/// what they print: every one formats through `display`.
///
///   show    now, in the active region
///   strobe  at the end of the timestep (IEEE 1364-2005 §17.1.2: "display
///           simulation data at a selected time ... at the end of the current
///           timestep"), which is the `.monitor` scheduler region
///   monitor the same end-of-timestep print, but standing: it re-runs whenever
///           a value changes until another $monitor replaces it (§17.1.3)
pub const Task = union(enum) {
    show: Show,
    strobe: Show,
    monitor: Show,
    /// $monitoron / $monitoroff. "$monitoron ... produces a display
    /// immediately", so the flag's own transition is observable.
    monitor_enable: bool,
    /// §17.3, the `%t` format state.
    timeformat,
    /// §9.5 Table 9-2 / IEEE 1364 §17.2.9. The radix is the whole difference
    /// between `$readmemb` and `$readmemh`.
    readmem: Radix,
    /// §17.4.1 `$finish` (false) and §17.4.2 `$stop` (true). A batch run has
    /// nothing to suspend into, so `$stop` ends it too (VD-070), its report
    /// on stderr so stdout holds only what the design printed.
    finish: bool,
    /// §17.6 the four queue tasks.
    queue: system.QueueOp,
    /// §17.5 the sixteen PLA tasks.
    pla: system.Pla,
    /// §17.2.7 `$fclose`.
    fclose,
    /// §17.2.6 `$fflush`: every write is already in its file
    /// (`file_kernels.zFFlush`), so it only reads its argument.
    fflush,
    /// §17.2.2 `$fdisplay`/`$fwrite`: `show` to a descriptor.
    fshow: Show,
    /// §17.2.3 `$swrite`: `show` into the first argument, a variable.
    sshow: Show,
    /// §17.2.3 `$sformat`: `sformat`'s text into the first argument.
    sformat,
    /// §17.3.1 `$printtimescale`.
    printtimescale,
    /// §18.1 the value change dump tasks.
    dump: @import("vcd.zig").Op,
    /// §18.3 the extended value change dump tasks.
    ports: @import("evcd.zig").Op,
    /// IEEE 1364-2005 §20.3 a PLI application's task (`Run.systf`).
    user,
};

fn showAs(radix: Radix, newline: bool) Show {
    return .{ .radix = radix, .newline = newline };
}

fn toFile(radix: Radix) Show {
    return .{ .radix = radix, .newline = true, .file = true };
}

const TaskRow = struct { []const u8, Task };

/// Every system task this module runs, by name.
pub const tasks = std.StaticStringMap(Task).initComptime(@as([]const TaskRow, &.{
    .{ "$display", Task{ .show = showAs(.decimal, true) } },
    .{ "$displayb", Task{ .show = showAs(.binary, true) } },
    .{ "$displayo", Task{ .show = showAs(.octal, true) } },
    .{ "$displayh", Task{ .show = showAs(.hex, true) } },
    .{ "$write", Task{ .show = showAs(.decimal, false) } },
    .{ "$writeb", Task{ .show = showAs(.binary, false) } },
    .{ "$writeo", Task{ .show = showAs(.octal, false) } },
    .{ "$writeh", Task{ .show = showAs(.hex, false) } },
    .{ "$strobe", Task{ .strobe = showAs(.decimal, true) } },
    .{ "$strobeb", Task{ .strobe = showAs(.binary, true) } },
    .{ "$strobeo", Task{ .strobe = showAs(.octal, true) } },
    .{ "$strobeh", Task{ .strobe = showAs(.hex, true) } },
    .{ "$monitor", Task{ .monitor = showAs(.decimal, true) } },
    .{ "$monitorb", Task{ .monitor = showAs(.binary, true) } },
    .{ "$monitoro", Task{ .monitor = showAs(.octal, true) } },
    .{ "$monitorh", Task{ .monitor = showAs(.hex, true) } },
    .{ "$fstrobe", Task{ .strobe = toFile(.decimal) } },
    .{ "$fstrobeb", Task{ .strobe = toFile(.binary) } },
    .{ "$fstrobeo", Task{ .strobe = toFile(.octal) } },
    .{ "$fstrobeh", Task{ .strobe = toFile(.hex) } },
    .{ "$fmonitor", Task{ .monitor = toFile(.decimal) } },
    .{ "$fmonitorb", Task{ .monitor = toFile(.binary) } },
    .{ "$fmonitoro", Task{ .monitor = toFile(.octal) } },
    .{ "$fmonitorh", Task{ .monitor = toFile(.hex) } },
    .{ "$monitoron", Task{ .monitor_enable = true } },
    .{ "$monitoroff", Task{ .monitor_enable = false } },
    .{ "$timeformat", .timeformat },
    .{ "$readmemb", Task{ .readmem = .binary } },
    .{ "$readmemh", Task{ .readmem = .hex } },
    .{ "$finish", Task{ .finish = false } },
    .{ "$stop", Task{ .finish = true } },
    .{ "$q_initialize", Task{ .queue = .initialize } },
    .{ "$q_add", Task{ .queue = .add } },
    .{ "$q_remove", Task{ .queue = .remove } },
    .{ "$q_exam", Task{ .queue = .exam } },
    .{ "$fclose", .fclose },
    .{ "$fflush", .fflush },
    .{ "$fdisplay", Task{ .fshow = showAs(.decimal, true) } },
    .{ "$fdisplayb", Task{ .fshow = showAs(.binary, true) } },
    .{ "$fdisplayo", Task{ .fshow = showAs(.octal, true) } },
    .{ "$fdisplayh", Task{ .fshow = showAs(.hex, true) } },
    .{ "$fwrite", Task{ .fshow = showAs(.decimal, false) } },
    .{ "$fwriteb", Task{ .fshow = showAs(.binary, false) } },
    .{ "$fwriteo", Task{ .fshow = showAs(.octal, false) } },
    .{ "$fwriteh", Task{ .fshow = showAs(.hex, false) } },
    .{ "$swrite", Task{ .sshow = showAs(.decimal, false) } },
    .{ "$swriteb", Task{ .sshow = showAs(.binary, false) } },
    .{ "$swriteo", Task{ .sshow = showAs(.octal, false) } },
    .{ "$swriteh", Task{ .sshow = showAs(.hex, false) } },
    .{ "$sformat", .sformat },
    .{ "$printtimescale", .printtimescale },
    .{ "$dumpfile", Task{ .dump = .file } },
    .{ "$dumpvars", Task{ .dump = .vars } },
    .{ "$dumpoff", Task{ .dump = .off } },
    .{ "$dumpon", Task{ .dump = .on } },
    .{ "$dumpall", Task{ .dump = .all } },
    .{ "$dumplimit", Task{ .dump = .limit } },
    .{ "$dumpflush", Task{ .dump = .flush } },
}) ++ pla_rows);

const pla_rows: []const TaskRow = blk: {
    var rows: [system.pla_tasks.len]TaskRow = undefined;
    for (system.pla_tasks, &rows) |t, *row| row.* = .{ t[0], Task{ .pla = t[1] } };
    const out = rows;
    break :blk &out;
};

/// §17.3.2 `$timeformat`'s state; the type is `fmt`'s so `rt` shares it.
pub const TimeFormat = fmt.TimeFormat;

// ---- formatting (§9.4.3, §17.1.1.3, §17.1.1.4, §17.3) -----------------------

/// Prints `args` as §9.4.1's display tasks do, onto `Run.out`; with a null
/// `allocator` it only validates the call. Every conversion is width-exact
/// (IEEE 1364-2005 §17.1.1.3), x and z apart (§17.1.1.4).
/// A `file` show is only validated here (its descriptor, then the rest);
/// `system.fdisplay` prints it.
pub fn display(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator, show: Show) Error!void {
    if (show.file) {
        std.debug.assert(allocator == null);
        if (args.len == 0 or args[0] == .none) return self.fail(0, "a §17.2.2 file output task's first argument is a descriptor", .{});
        try compile.checkExpr(self, args[0]);
        return walk(self, args[1..], null, show, false);
    }
    return walk(self, args, allocator, show, false);
}

/// §17.2.3 `$sformat`'s text of `args` (after its variable): "always
/// interprets its second argument, and only its second argument as a format
/// string", which "can be a static string ... or can be a reg variable whose
/// content is interpreted as the format string". Specifiers and arguments
/// that do not pair up at run time warn (W1153) and the task continues.
pub fn sformat(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator) Error!void {
    return walk(self, args, allocator, .{ .radix = .decimal, .newline = false }, true);
}

/// The W1153 text.
pub const sformat_mismatch = "$sformat: the format's specifiers and the arguments after it do not pair up";

fn sformatMismatch(self: *Run, e: Ast.ExprId) Error!void {
    const at = self.starts[@min(self.file.exprs.mainTok(e), self.starts.len - 1)];
    try self.bag.add(self.stage(), .W1153, .{ .start = at, .end = at }, sformat_mismatch, .{});
}

/// §17.1.1.2 one real conversion (`%e %f %g`, §9.4.7 `%r`): C's text under
/// C11 7.21.6.1p6's `flags` (`str_kernels.zc_*`; `fmt.flagVerdict` has
/// refused '#' on `%r`), in a field `width` wide, for both engines. No width
/// or precision is too large: the padding is written, not buffered, and the
/// text goes through a buffer sized for this precision (from `gpa` past a
/// small one on the stack). The longest %f of an f64 is a sign, 309 integer
/// digits and the point, then `precision` fractional digits, inside 512 +
/// precision.
pub fn real(out: *std.Io.Writer, gpa: std.mem.Allocator, r: f64, conv: u8, flags: u8, precision: i64, width: ?u64) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    var stack: [1024]u8 = undefined;
    const need = 512 + @as(usize, @intCast(@max(precision, 0)));
    const buf = if (need <= stack.len) &stack else try gpa.alloc(u8, need);
    defer if (buf.ptr != &stack) gpa.free(buf);
    // The kernel spells the sign and the body; the field is padded here,
    // as `zCReal` would pad it: '-' on the right, '0' after the sign of a
    // finite value (C: the '0' flag is ignored for inf and nan), else
    // spaces on the left.
    const text = zCReal(buf, r, conv, flags & ~(str_k.zc_left | str_k.zc_zero), 0, precision);
    const pad = (width orelse 0) -| text.len;
    if (flags & str_k.zc_left != 0) {
        try out.writeAll(text);
        return out.splatByteAll(' ', pad);
    }
    const zero = flags & str_k.zc_zero != 0 and std.math.isFinite(r);
    const sign: usize = if (zero and text.len != 0 and (text[0] == '-' or text[0] == '+' or text[0] == ' ')) 1 else 0;
    try out.writeAll(text[0..sign]);
    try out.splatByteAll(if (zero) '0' else ' ', pad);
    try out.writeAll(text[sign..]);
}

fn walk(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator, show: Show, only_first: bool) Error!void {
    const ex = &self.file.exprs;
    var arg: usize = 0;
    while (arg < args.len) : (arg += 1) {
        const e = args[arg];
        if (only_first and arg != 0) {
            // Arguments left over once the format is used up.
            for (args[arg..]) |rest| if (rest != .none) try compile.checkExpr(self, rest);
            if (allocator != null) try sformatMismatch(self, e);
            return;
        }
        // §9.4.1: "Any null argument produces a single space character in
        // the display. (A null argument is characterized by two adjacent
        // commas (,,) in the argument list.)"
        if (e == .none) {
            if (allocator != null) try self.out.writeByte(' ');
            continue;
        }
        // A format held in a variable is known only when the task runs.
        const dynamic = only_first and ex.tag(e) != .str_literal;
        // Only a string is a format. §9.4.3's last sentence before Table
        // 9-23: "Any expression argument with no corresponding format
        // specification is displayed using the default decimal format",
        // the default of this task, so $displayh's bare argument is hex.
        if (ex.tag(e) != .str_literal and !dynamic) {
            try compile.checkExpr(self, e);
            if (allocator) |a| try fmt.value(self.out, a, try evaluate.eval(self, a, e, 0), show.radix, null);
            continue;
        }
        if (dynamic and allocator == null) {
            for (args) |x| if (x != .none) try compile.checkExpr(self, x);
            return;
        }
        const format = if (dynamic) (try system.text(allocator.?, try evaluate.eval(self, allocator.?, e, 0))) orelse "" else self.file.str(ex.strOf(e));
        var i: usize = 0;
        while (i < format.len) : (i += 1) {
            if (format[i] != '%') {
                if (allocator != null) try self.out.writeByte(format[i]);
                continue;
            }
            i += 1;
            if (i == format.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "unterminated display format");
            if (format[i] == '%') {
                if (allocator != null) try self.out.writeByte('%');
                continue;
            }
            // §17.1.1.2's optional field width. `%0d` is the one every
            // source writes and means "minimum width"; a non-zero width is
            // an explicit column count. Absent means §17.1.1.3's automatic
            // sizing, which is `null` here and computed from the operand.
            // A real conversion takes C's flags and `.precision` too.
            const at = i - 1;
            const sp = fmt.spec(format, &i);
            const width = sp.width;
            const precision = sp.precision;
            if (i == format.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "unterminated display format");
            // #43: a flag is rendered where §17.1.1.2 grants C, refused
            // where it does not; never read and then ignored.
            if (format[i] != '%') switch (fmt.flagVerdict(sp.flags, format[i])) {
                .ok => {},
                .alt => return self.failWith(.E0825, ex.mainTok(e), "`{s}`: '#' is C's alternative form, which IEEE 1364-2005 §17.1.1.2 grants only to %e, %f and %g", .{format[at .. i + 1]}),
                .c_flag => return self.failWith(.E0827, ex.mainTok(e), "`{s}`: IEEE 1364-2005 §17.1.1.2 grants C's '-', '+' and ' ' flags to the real conversions only", .{format[at .. i + 1]}),
            };
            const radix: ?Radix = switch (format[i]) {
                // #42: §9.4.2's `%%` is two characters (`%%` above); one
                // with a flag, width or precision between them is no escape.
                '%' => return self.failWith(.E0826, ex.mainTok(e), "a flag, width or precision before the second `%` of `%%`", .{}),
                'b', 'B' => .binary,
                'o', 'O' => .octal,
                'h', 'H' => .hex,
                'd', 'D' => .decimal,
                // §9.4.3 Table 9-23's real conversions, which "have the full
                // formatting capabilities available in the C language".
                // §9.4.7 adds a fourth row here: "the %r (or %R) format
                // specifier may be used on real expressions in the digital
                // context", engineering notation, `zCReal`'s 'r'.
                'e', 'E', 'f', 'F', 'g', 'G', 'r', 'R' => null,
                // §17.3 `%t` is no radix: it reads the $timeformat state
                // and formats a time, whose operand is in the module's own
                // time unit.
                't', 'T' => {
                    arg += 1;
                    if (arg == args.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "missing display argument");
                    try compile.checkExpr(self, args[arg]);
                    // A real operand is formatted as it is, not rounded to
                    // a whole unit first (#64).
                    if (allocator) |a| try emitTime(self, if (compile.typeOf(self, args[arg]).real)
                        try evaluate.evalReal(self, a, args[arg])
                    else
                        fmt.timeOperand(try evaluate.eval(self, a, args[arg], 0)), width);
                    continue;
                },
                // §17.1.1.6 `%m` and §13.6 `%l` consume no argument: they
                // print where the display is, not a value.
                'm', 'M' => {
                    if (allocator != null) try emitScope(self);
                    continue;
                },
                'l', 'L' => {
                    const def = self.scope_info.items[self.scope].def;
                    if (allocator != null) try self.out.print("{s}.{s}", .{ self.file.str(self.def_lib[def]), self.file.str(self.file.modules[def].name) });
                    continue;
                },
                // §17.1.1.5 `%v`: "the strength of scalar nets".
                'v', 'V' => {
                    arg += 1;
                    if (arg == args.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "missing display argument");
                    try compile.checkExpr(self, args[arg]);
                    if (compile.typeOf(self, args[arg]).width != 1) return self.exprFail(args[arg], "§17.1.1.5: %v takes a scalar net reference");
                    const net = if (ex.tag(args[arg]) == .ident) self.net_of.get(try self.slot(args[arg])) else null;
                    // The resolution keeps a net's `signal` only when read.
                    if (net) |n| self.nets[n].strength_read = true;
                    if (allocator) |a| {
                        const n = if (net) |k| self.nets[k] else null;
                        // §7.6: a pass switch drives a net with no driver of its own.
                        const sig: Signal = if (n == null)
                            .of((try evaluate.eval(self, a, args[arg], 0)).bit(0), .strong, .strong)
                        else if (self.netDrivers(net.?).len == 0 and self.netCold(n.?).trans.len == 0) netPull(n.?.kind) else self.signals[n.?.signal];
                        try strength(self.out, sig);
                    }
                    continue;
                },
                // §17.1.1.7 `%s` (the operand as 8-bit ASCII codes) and
                // `%c` (its low eight bits as one character).
                's', 'S', 'c', 'C' => {
                    arg += 1;
                    if (arg == args.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "missing display argument");
                    try compile.checkExpr(self, args[arg]);
                    if (allocator) |a| try fmt.text(self.out, try evaluate.eval(self, a, args[arg], 0), format[i] == 'c' or format[i] == 'C', width);
                    continue;
                },
                // §17.1.1.2 `%u`/`%z`: the operand's two- or four-value bits
                // as binary data.
                'u', 'U', 'z', 'Z' => {
                    arg += 1;
                    if (arg == args.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "missing display argument");
                    try compile.checkExpr(self, args[arg]);
                    if (allocator) |a| try unformatted(self.out, try evaluate.eval(self, a, args[arg], 0), format[i] == 'z' or format[i] == 'Z');
                    continue;
                },
                else => return self.exprFail(
                    e,
                    "only the §9.4.3 Table 9-22 conversions (%b, %o, %h, %d, %e, %f, %g, §9.4.7 %r and %%) and %c %s %m %l %t %u %v %z are implemented",
                ),
            };
            arg += 1;
            if (arg == args.len) return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, "missing display argument");
            if (radix) |r| {
                try compile.checkExpr(self, args[arg]);
                if (allocator) |a| try fmt.value(self.out, a, try evaluate.eval(self, a, args[arg], 0), r, width);
            } else {
                try compile.checkExpr(self, args[arg]);
                if (allocator) |a| try real(self.out, a, try evaluate.evalReal(self, a, args[arg]), format[i], sp.flags, precision, width);
            }
        }
    }
    if (allocator != null and show.newline) try self.out.writeByte('\n');
}

/// §17.1.1.2 `%u` (`four` false: "unknown or high-impedance bits ... shall
/// be treated as zero") / `%z` (each word §27.14's s_vpi_vecval, aval then
/// bval): "in units of 32 bits with the word containing the LSB written
/// first", each little-endian, the native order of every target VerA builds
/// for. `system.Scan` reads them back.
fn unformatted(out: *std.Io.Writer, v: Int.Literal, four: bool) Error!void {
    for (0..@max(1, (v.width + 31) / 32)) |k| {
        const lo = k * 32;
        const val: u32 = @truncate(v.values()[lo / 64] >> @intCast(lo % 64));
        const unk: u32 = @truncate(v.unknowns()[lo / 64] >> @intCast(lo % 64));
        if (four) {
            try out.writeInt(u32, val, .little);
            try out.writeInt(u32, unk, .little);
        } else try out.writeInt(u32, val & ~unk, .little);
    }
}

/// §17.1.1.6 `%m`: the hierarchical name of the scope the display runs in,
/// the instance path from the root, then every §5.3.2 named block around the
/// running instruction, outermost first.
pub fn emitScope(self: *Run) Error!void {
    try emitPath(self, self.scope);
    // The named blocks enclosing `pc` in this scope nest, so each is one
    // statement level deeper than the last: printed shallowest first, with no
    // bound on how many.
    var last: i64 = -1;
    while (true) {
        var next: ?struct { depth: u32, name: Ast.StrId } = null;
        var it = self.blocks.iterator();
        while (it.next()) |b| {
            if (b.key_ptr.scope != self.scope or self.pc < b.value_ptr.start or self.pc >= b.value_ptr.end) continue;
            const d = b.value_ptr.depth;
            if (d > last and (next == null or d < next.?.depth)) next = .{ .depth = d, .name = b.key_ptr.str };
        }
        const b = next orelse break;
        try self.out.print(".{s}", .{self.file.str(b.name)});
        last = b.depth;
    }
}

/// Scope `s`'s hierarchical name, root first.
fn emitPath(self: *Run, s: u32) Error!void {
    const info = self.scope_info.items[s];
    if (info.parent != s and s != 0) {
        try emitPath(self, info.parent);
        try self.out.writeByte('.');
    }
    try self.out.writeAll(self.file.str(info.name));
    // §12.4.1 one iteration of a loop generate is `name[value]`.
    if (info.index) |i| try self.out.print("[{d}]", .{i});
}

/// §17.1.1.5 `%v` of the §7.10 signal `s`: a Table 17-5 mnemonic and the
/// Table 17-4 value (0 1 X Z L H), or, where a 0 or 1 spans a range of
/// strengths, its maximum and minimum levels as digits, and for an X whose
/// sides differ, its 0 and 1 levels ("35X").
pub fn strength(out: *std.Io.Writer, s: Signal) std.Io.Writer.Error!void {
    const names = [_][]const u8{ "Hi", "Sm", "Me", "We", "La", "Pu", "St", "Su" };
    const lo: u8 = @abs(s.lo);
    const hi: u8 = @abs(s.hi);
    if (s.lo == 0 and s.hi == 0) return out.writeAll("HiZ");
    if (s.lo >= 0 and s.hi > 0 and s.lo != 0) return if (lo == hi) out.print("{s}1", .{names[hi]}) else out.print("{d}{d}1", .{ hi, lo });
    if (s.hi <= 0 and s.lo < 0 and s.hi != 0) return if (lo == hi) out.print("{s}0", .{names[lo]}) else out.print("{d}{d}0", .{ lo, hi });
    if (s.lo == 0) return out.print("{s}H", .{names[hi]});
    if (s.hi == 0) return out.print("{s}L", .{names[lo]});
    return if (lo == hi) out.print("{s}X", .{names[lo]}) else out.print("{d}{d}X", .{ lo, hi });
}

/// `%t`; a field width in the format (`%0t`: none) replaces §17.3.2's
/// minimum field width.
fn emitTime(self: *Run, v: f64, width: ?u64) Error!void {
    var f = self.time_format;
    if (width) |w| f.width = w;
    try fmt.time(self.out, v, f, self.timeOf(self.scope).unit_exp);
}

/// IEEE 1364-2005 §17.3.1 `$printtimescale`: "the time unit and precision of
/// the module that is the current scope", or with an argument "of the module
/// passed to it", in the clause's format `Time scale of (name) is unit /
/// precision`. The name is the current module's, or the argument as written.
pub fn printTimescale(self: *Run, args: []const Ast.ExprId) Error!void {
    const scope = if (args.len == 1) try timescaleScope(self, args[0]) else self.scope;
    const mt = self.timeOf(scope);
    const prec_exp = mt.unit_exp - @as(i32, std.math.log10_int(@as(u64, mt.scale.local_per_unit)));
    try self.out.writeAll("Time scale of (");
    if (args.len == 0) try self.out.writeAll(self.file.str(self.file.modules[self.scope_info.items[self.scope].def].name)) else {
        const ex = &self.file.exprs;
        const parts: []const Ast.StrId = if (ex.tag(args[0]) == .ident) &.{ex.strOf(args[0])} else ex.nameParts(args[0]);
        for (parts, 0..) |p, i| try self.out.print("{s}{s}", .{ if (i == 0) "" else ".", self.file.str(p) });
    }
    try self.out.writeAll(") is ");
    try fmt.decade(self.out, mt.unit_exp);
    try self.out.writeAll(" / ");
    try fmt.decade(self.out, prec_exp);
    try self.out.writeByte('\n');
}

/// §17.3.1 the module instance `$printtimescale`'s argument names.
pub fn timescaleScope(self: *Run, e: Ast.ExprId) Error!u32 {
    return switch (try @import("vcd.zig").target(self, e)) {
        .scope => |sc| sc,
        .slot => self.exprFail(e, "§17.3.1: $printtimescale names a module instance"),
    };
}

/// Prints the standing monitor's argument list, if there is one and it is
/// on. The caller decides whether to print (`monitorDue` at the time step's
/// `.monitor` event, or `$monitoron` ran), never by comparing text.
pub fn monitorPrint(self: *Run, a: std.mem.Allocator) Error!void {
    const m = self.monitor orelse return;
    if (!self.monitor_on) return;
    // §17.1.3 the monitor renders in the instance that installed it; the
    // `.monitor` region runs outside any process's dispatch.
    self.scope = m.scope;
    self.pc = m.pc;
    try display(self, m.args, a, m.show);
    // What each probe read at this report, the base the next time step
    // compares against (`monitorDue`).
    for (self.monitor_probes, self.monitor_last) |e, *last| last.* = try evaluate.evalReal(self, a, e);
    self.monitor_slot_hit = false;
}

/// Whether the `.monitor` event of this time step reports (§17.1.3: "each
/// time a variable or an expression in the argument list changes value"). A
/// watched slot's change says so already (`monitor_slot_hit`); a VAMS
/// §7.3.6.3 probe is an operand no slot holds, so each one is compared with
/// its value at the last report, a change being VD-032's `!=`. An argument
/// is not compared whole: `$time`, `$stime` and `$realtime` are the clause's
/// exceptions inside an expression too, so time passing alone reports
/// nothing (docs/specification/Vague_Decisions.md VD-111).
pub fn monitorDue(self: *Run, a: std.mem.Allocator) Error!bool {
    const m = self.monitor orelse return false;
    if (self.monitor_slot_hit) return true;
    if (self.monitor_probes.len == 0) return false;
    self.scope = m.scope;
    self.pc = m.pc;
    for (self.monitor_probes, self.monitor_last) |e, last| {
        if ((try evaluate.evalReal(self, a, e)) != last) return true;
    }
    return false;
}

/// §17.1.3 `$monitor` (`show.file` false) or §17.2.2 `$fmonitor` at `pc`,
/// in the current scope: a `$monitor` replaces the standing one, an
/// `$fmonitor` joins the others. Its first line is at the end of this time
/// step like every other, so it shows settled values.
pub fn install(self: *Run, a: std.mem.Allocator, args: []const Ast.ExprId, show: Show, pc: u32) Error!void {
    watchAll(self, false);
    defer watchAll(self, true);
    var m: Standing = .{ .args = args, .show = show, .scope = self.scope, .pc = pc, .hit = true };
    m.values = try self.arena.alloc(?[]u64, args.len);
    var loose: std.ArrayList(u32) = .empty;
    var probes_ignored: std.ArrayList(Ast.ExprId) = .empty;
    for (args, m.values, 0..) |e, *v, k| {
        v.* = null;
        if (k < @intFromBool(show.file) or e == .none or self.file.exprs.tag(e) == .str_literal) continue;
        // A clock query or a call can move with no slot changing (VD-111):
        // such an argument is not compared, and any change of a slot it
        // reads reports.
        if (!comparable(self, e)) {
            try compile.sensitivityProbes(self, e, &loose, &probes_ignored);
            continue;
        }
        v.* = try self.arena.dupe(u64, try current(self, a, e));
    }
    m.loose = loose.items;
    if (show.file) {
        m.fd = ((try evaluate.eval(self, a, args[0], 0)).asInt() orelse return) & 0xffff_ffff;
        var slots: std.ArrayList(u32) = .empty;
        for (args[1..]) |e| if (e != .none and self.file.exprs.tag(e) != .str_literal)
            try compile.sensitivity(self, e, &slots);
        m.slots = slots.items;
        try self.fmonitors.append(self.arena, m);
        return requestTick(self);
    }
    self.monitor_slots.clearRetainingCapacity();
    var probes: std.ArrayList(Ast.ExprId) = .empty;
    for (args) |e| if (e != .none and self.file.exprs.tag(e) != .str_literal)
        try compile.sensitivityProbes(self, e, &self.monitor_slots, &probes);
    self.monitor = m;
    // VAMS §8.5.1 row 4 after 3b: a probe of the analog solution is an
    // operand no slot holds, so it is compared at every time step and
    // analog solution (`monitorDue`). The first report is due.
    self.monitor_probes = probes.items;
    self.monitor_last = try self.arena.alloc(f64, probes.items.len);
    @memset(self.monitor_last, 0);
    self.monitor_slot_hit = true;
    try waiters.requestMonitor(self);
}

/// §17.2.7: "Active $fmonitor and/or $fstrobe operations on a file
/// descriptor or multichannel descriptor are implicitly cancelled by an
/// $fclose operation". The `$fmonitor`s writing to `d` stop.
pub fn cancelFile(self: *Run, d: i64) void {
    watchAll(self, false);
    defer watchAll(self, true);
    var k: usize = 0;
    while (k < self.fmonitors.items.len) {
        if (self.fmonitors.items[k].fd == d) _ = self.fmonitors.orderedRemove(k) else k += 1;
    }
}

/// Marks (`on`) or unmarks every slot a standing monitor reads as a
/// `.monitor` watch (`waiters.store` -> `monitorChanged`).
fn watchAll(self: *Run, on: bool) void {
    for (self.monitor_slots.items) |at| self.watch[at].setPresent(.monitor, on);
    for (self.fmonitors.items) |m| for (m.slots) |at| self.watch[at].setPresent(.monitor, on);
}

/// Whether `$monitor` argument `e` reports on a change of its own value
/// that a change of a slot it reads need not be (`bs[1]` under `bs`): an
/// expression `install` compares. A whole variable, a constant and an
/// argument that is not compared report on any change of their slots.
pub fn comparedOperand(self: *Run, e: Ast.ExprId) bool {
    if (e == .none) return false;
    return switch (self.file.exprs.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .real_literal, .ident, .hier_ident => false,
        else => comparable(self, e), // else: an expression of operands
    };
}

/// Whether argument `e`'s value can move only when a slot it reads does:
/// no clock query, call or analog probe anywhere in it.
fn comparable(self: *Run, e: Ast.ExprId) bool {
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .real_literal, .ident, .hier_ident => true,
        .index => comparable(self, ex.lhs(e)) and comparable(self, ex.rhs(e)),
        .unary, .binary, .multi_concat, .ternary, .concat, .range, .indexed_range => {
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (c != .none and !comparable(self, c)) return false;
            return true;
        },
        else => false, // else: a system or user call, an analog probe
    };
}

/// Argument `e`'s value now, as the planes compared between evaluations; a
/// real as its bits (VD-032's change is `!=`, which -0.0 over +0.0 is not,
/// so a real compares by value).
fn current(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error![]u64 {
    if (compile.typeOf(self, e).real) {
        const r = try evaluate.evalReal(self, a, e);
        const out = try a.alloc(u64, 1);
        out[0] = @bitCast(if (r == 0) 0 else r);
        return out;
    }
    return (try evaluate.eval(self, a, e, 0)).planes;
}

/// Re-evaluates `m`'s compared arguments after `slot` changed: true when any
/// of them moved since its last evaluation (each then keeps its new value),
/// or when an argument that is not compared reads `slot` (`install`).
fn moved(self: *Run, m: *Standing, a: std.mem.Allocator, slot: u32) Error!bool {
    if (std.mem.findScalar(u32, m.loose, slot) != null) return true;
    const saved_scope = self.scope;
    const saved_pc = self.pc;
    defer {
        self.scope = saved_scope;
        self.pc = saved_pc;
    }
    self.scope = m.scope;
    self.pc = m.pc;
    var any = false;
    for (m.args, m.values) |e, last| {
        const old = last orelse continue;
        const now = try current(self, a, e);
        if (std.mem.eql(u64, old, now)) continue;
        any = true;
        @memcpy(old, now);
    }
    return any;
}

/// `waiters.store`: a slot some standing monitor reads changed. §17.1.3 "each
/// time a variable or an expression in the argument list changes value": a
/// monitor whose arguments' values moved reports at the end of the time
/// step; one whose slot changed under an unchanged argument (`bs` under
/// `bs[1]`) does not. A transient change still reports.
pub fn monitorChanged(self: *Run, slot: u32) Error!void {
    if (self.monitor_evaluating) return;
    self.monitor_evaluating = true;
    defer self.monitor_evaluating = false;
    const a = self.scratch.allocator();
    if (self.monitor) |*m| if (std.mem.findScalar(u32, self.monitor_slots.items, slot) != null and try moved(self, m, a, slot)) {
        self.monitor_slot_hit = true;
        try waiters.requestMonitor(self);
    };
    for (self.fmonitors.items) |*m| if (std.mem.findScalar(u32, m.slots, slot) != null and try moved(self, m, a, slot)) {
        m.hit = true;
        try requestTick(self);
    };
}

/// The time step's one `.monitor_tick`, which `$fmonitor` needs whether or
/// not a `$monitor` stands.
fn requestTick(self: *Run) Error!void {
    if (self.monitor_pending) return;
    self.monitor_pending = true;
    try @import("exec.zig").enqueueMonitor(self, .monitor_tick);
}

/// The `.monitor_tick`'s `$fmonitor` lines: each one whose arguments moved.
pub fn fmonitorPrint(self: *Run, a: std.mem.Allocator) Error!void {
    for (self.fmonitors.items) |*m| if (m.hit) {
        m.hit = false;
        self.scope = m.scope;
        self.pc = m.pc;
        try system.fdisplayTo(self, a, m.fd, m.args, m.show);
    };
}

// ---- tests ------------------------------------------------------------------

test "§17.1.3 monitor: clock queries do not trigger, a change and change back does" {
    // t1: only `u` (unwatched) changes and $time advances: no line. t2: a
    // goes 1 then back to 0 via #0: it "changes value", so one line with
    // the settled 0. t3: a = 1 prints with the current time. $monitoron at
    // t4 prints although nothing changed and monitoring was already on.
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg a, u;
        \\initial begin
        \\  a = 0; u = 0;
        \\  $monitor("a=%b t=%0d", a, $time);
        \\  a <= 0;
        \\  #1 u = 1;
        \\  #1 a = 1;
        \\  #0 a = 0;
        \\  #1 a = 1;
        \\  #1 $monitoron;
        \\  #1 $finish(0);
        \\end
        \\endmodule
    , "a=0 t=0\na=0 t=2\na=1 t=3\na=1 t=4\n");
}

test "§17.1.3 monitor: a bit-select argument reports only when that bit changes" {
    // bs changes at t1..t4; bs[1] only at t2, so two lines in all.
    try expectRun(
        \\module m;
        \\reg [3:0] bs;
        \\integer i;
        \\initial begin
        \\  bs = 0;
        \\  $monitor("%0d %b", $time, bs[1]);
        \\  for (i = 0; i < 4; i = i + 1) #1 bs[i] = 1;
        \\  #1 $finish(0);
        \\end
        \\endmodule
    , "0 0\n2 1\n");
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

/// `terminated`: a file address falls outside the task's range, so §17.2.9's
/// "an error message is issued, and the load operation is terminated": E1157,
/// the words before it stay loaded and the run goes on to print them (#65).
fn expectMemoryLoad(data: []const u8, bounds: []const u8, expected: []const u8, warnings: u32, terminated: bool) !void {
    return expectMemoryLoadDiagnostic("$readmemh", data, bounds, expected, warnings, if (terminated) "is outside the load range" else null);
}

fn expectMemoryLoadDiagnostic(task: []const u8, data: []const u8, bounds: []const u8, expected: []const u8, warnings: u32, failure_phrase: ?[]const u8) !void {
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
    if (failure_phrase) |phrase| {
        // A refusal ends the run (DigitalFailed); §17.2.9's terminated load
        // issues its error and the run goes on. `expected` tells them apart:
        // only a run that went on prints the memory.
        result catch |e| if (e != error.DigitalFailed) return e;
        try std.testing.expect(bag.failed());
        var messages = std.Io.Writer.Allocating.init(a);
        try diag.render(&bag, &messages.writer, .{});
        try std.testing.expect(std.mem.find(u8, messages.written(), phrase) != null);
    } else try result;
    try std.testing.expectEqual(warnings, bag.warn_count);
    try std.testing.expectEqualStrings(expected, output.written());
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
    try expectMemoryLoadDiagnostic("$readmemh", "11 ;", ",0,0", "", 0, invalid);
    try expectMemoryLoadDiagnostic("$readmemb", "1 2", ",0,0", "", 0, invalid);
    try expectMemoryLoadDiagnostic("$readmemh", "11 _", ",0,0", "", 0, invalid);
    try expectMemoryLoadDiagnostic("$readmemh", "11 22", ",0,0", "11 bb cc dd\n", 1, null);
    try expectMemoryLoadDiagnostic("$readmemh", "11 22 @0 33", ",0,0", "33 bb cc dd\n", 0, null);
}

test "readmem addresses suppress count warning and relocate after range end" {
    try expectMemoryLoad("@1 11", ",0,3", "aa 11 cc dd\n", 0, false);
    try expectMemoryLoad("11 22 33 44 55 @2 66", ",0,3", "11 22 66 44\n", 0, false);
    try expectMemoryLoad("11 22 33 44 @2 66 77", ",3,0", "44 77 66 11\n", 0, false);
    // §17.2.9 (#65): an address outside the task's range ends the load, not
    // the run. 11 -> mem[1], 22 -> mem[2], then @0 is outside 1..2.
    try expectMemoryLoad("11 22 @0", ",1,2", "aa 11 22 dd\n", 0, true);
    // @3 is outside 2..1 before any word: nothing loads.
    try expectMemoryLoad("@3 11", ",2,1", "aa bb cc dd\n", 0, true);
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
    try expectMemoryLoad("@1 11", ",2", "aa bb cc dd\n", 0, true);
    // 11 -> mem[2], 22 -> mem[3], then @4 is outside 2..3.
    try expectMemoryLoad("11 22 @4", ",2", "aa bb 11 22\n", 0, true);
}

test "readmem formfeeds delimit words and addresses without adding words" {
    try expectMemoryLoad("\x0c11\x0c22\x0c33\x0c44\x0c", "", "11 22 33 44\n", 0, false);
    try expectMemoryLoad("\x0c@2\x0c11\x0c22\x0c", ",2", "aa bb 11 22\n", 0, false);
    try expectMemoryLoad("/* not words: @0 55 */\x0c11\x0c22", ",2", "aa bb 11 22\n", 0, false);
    try expectMemoryLoadDiagnostic("$readmemb", "\x0c00010001\x0c00100010\x0c", ",2", "aa bb 11 22\n", 0, null);
    try expectMemoryLoadDiagnostic("$readmemb", "@3\x0c1\x0c@2\x0c10\x0c11", ",2", "aa bb 02 03\n", 0, null);
}

test "§9.4.3 the radix conversions size themselves from the operand" {
    // IEEE 1364-2005 §17.1.1.3: a radix field is the operand's declared width
    // in that radix, and the default decimal field holds the largest value the
    // operand can take: 255 for `reg [7:0]`, so three columns of leading
    // space, not zero. `%0d` is the escape from it.
    try expectRun(
        \\module m; reg [7:0] v; initial begin
        \\  v = 8'd7;
        \\  $display("[%d][%0d][%h][%o][%b]", v, v, v, v, v);
        \\end endmodule
        \\
    , "[  7][7][07][007][00000111]\n");
    // §17.1.1.4: a group that is entirely unknown prints lowercase, a group
    // that is partly unknown prints uppercase. The `X` is the whole signal
    // that known bits were discarded.
    try expectRun(
        \\module m; reg [7:0] v; initial begin
        \\  v = 8'b1010_xxxx; $display("[%b][%h][%o]", v, v, v);
        \\  v = 8'bzzzz_0011; $display("[%h][%o]", v, v);
        \\end endmodule
        \\
    , "[1010xxxx][ax][2Xx]\n[z3][zZ3]\n");
    // §9.4.1: a null argument is one space, $write has no newline, and an
    // argument with no format specification takes the task's default radix.
    try expectRun(
        \\module m; reg [7:0] v; initial begin
        \\  v = 8'hA5;
        \\  $write("w"); $displayh(v); $display("[", , "]"); $display("bare=", v);
        \\end endmodule
        \\
    , "wa5\n[ ]\nbare=165\n");
}

test "§17.2.3 $sformat/$swrite fill a reg with the text, §17.3.1 $printtimescale" {
    try expectRun(
        \\`timescale 10us/100ns
        \\module m; reg [8*6:1] s; initial begin
        \\  #3 $sformat(s, "t=%0d", $time); $display("[%s]", s);
        \\  $swriteh(s, 8'hab, "!"); $display("[%s]", s);
        \\  $sformat(s, "%s-long", "too"); $display("[%s]", s);
        \\  $printtimescale;
        \\end endmodule
        \\
    , "[t=3]\n[ab!]\n[o-long]\nTime scale of (m) is 10us / 100ns\n");
}

test "display retains escaped NUL bytes and unsized integer width" {
    try expectRun("module m; initial $display(\"A\\000B %b\",1); endmodule", "A\x00B 00000000000000000000000000000001\n");
    try expectRun("module m; initial $display(\"%b\",65'd1); endmodule", "00000000000000000000000000000000000000000000000000000000000000001\n");
}

test strength {
    // §17.1.1.5: a Table 17-5 mnemonic and a Table 17-4 value, or for a 0
    // or 1 spanning a range its maximum then minimum level as digits, and
    // for an X whose sides differ its 0 level then its 1 level.
    const cases = [_]struct { Signal, []const u8 }{
        .{ .{}, "HiZ" },
        .{ .of(.one, .strong, .strong), "St1" },
        .{ .of(.zero, .pull, .pull), "Pu0" },
        .{ .of(.one, .supply, .supply), "Su1" },
        .{ .{ .lo = 1, .hi = 1 }, "Sm1" },
        .{ .{ .lo = 5, .hi = 6 }, "651" },
        .{ .{ .lo = -6, .hi = -5 }, "650" },
        .{ .orZ(.one, .strong, .strong), "StH" },
        .{ .orZ(.zero, .weak, .weak), "WeL" },
        .{ .of(.x, .strong, .strong), "StX" },
        .{ .{ .lo = -3, .hi = 5 }, "35X" },
    };
    var buf: [8]u8 = undefined;
    for (cases) |c| {
        var w: std.Io.Writer = .fixed(&buf);
        try strength(&w, c[0]);
        try std.testing.expectEqualStrings(c[1], w.buffered());
    }
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

test "§17.1.1 %c, %s, %%, %m in a named block, %l, a real's width and precision" {
    // `%m` names the named block around the call (§17.1.1.6), `%l` the
    // library and cell (§13.6, the default library `work`), and `%7.3f` is
    // C's: three decimals, padded to seven columns.
    try expectRun(
        \\module m; reg [15:0] s; real r; initial begin : blk
        \\  s = "hi"; r = 2.5;
        \\  $display("%c|%s|%%|%m|%l|%7.3f|%0d", 8'h41, s, r, 7);
        \\end endmodule
        \\
    , "A|hi|%|m.blk|work.m|  2.500|7\n");
}

test "§17.1.1.2 a real conversion renders C's flags; any other refuses them (#43)" {
    // By hand: "2.50" left in 8; '+' on 1.5; ' ' where 3.0's sign would be;
    // "-2.500" zero-filled to 8 after its sign; '#' keeps 2's point; `%r`
    // of 1500 is "1.5K", left in 6. `%05d` stays §17.1.1.3's width 5.
    try expectRun(
        \\module m; initial $display("[%-8.2f|%+e|% .1f|%08.3f|%#.0f|%-6r|%05d]", 2.5, 1.5, 3.0, -2.5, 2.0, 1500.0, 42);
        \\endmodule
        \\
    , "[2.50    |+1.500000e+00| 3.0|-002.500|2.|1.5K  |   42]\n");
    try @import("root.zig").expectRejected("module m; initial $display(\"%-5d\", 1); endmodule", "to the real conversions only");
    try @import("root.zig").expectRejected("module m; initial $display(\"%+h\", 1); endmodule", "to the real conversions only");
    try @import("root.zig").expectRejected("module m; initial $display(\"%#h\", 1); endmodule", "alternative form");
    try @import("root.zig").expectRejected("module m; initial $display(\"%#r\", 1.5); endmodule", "alternative form");
}

test "§17.1.1.2 real pads its field as zCReal does, under every flag set (#43)" {
    // `real` streams its padding so no width is buffered; `zCReal` pads in
    // its buffer and is held to the C library's snprintf by
    // tests/printf_reference.zig. The two must print one text.
    const inf = std.math.inf(f64);
    const values = [_]f64{ 2.5, -2.5, 0.0, -0.0, inf, -inf, std.math.nan(f64), 1e-300, 1234.5678 };
    var buf: [600]u8 = undefined;
    for (values) |v| for ("eEfFgGrR") |conv| for (0..32) |flags| for ([_]usize{ 0, 1, 7, 20 }) |width| for ([_]i64{ -1, 0, 3 }) |prec| {
        const f: u8 = @intCast(flags);
        if (f & str_k.zc_alt != 0 and !str_k.zcAltOk(conv)) continue; // E0825
        var got: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer got.deinit();
        try real(&got.writer, std.testing.allocator, v, conv, f, prec, width);
        try std.testing.expectEqualStrings(zCReal(&buf, v, conv, f, width, prec), got.written());
    };
}

test "§17.1.1 a malformed format is refused before anything prints" {
    try @import("root.zig").expectRejected("module m; initial $display(\"%\"); endmodule", "unterminated display format");
    try @import("root.zig").expectRejected("module m; initial $display(\"%q\", 1); endmodule", "only the §9.4.3 Table 9-22 conversions");
    try @import("root.zig").expectRejected("module m; initial $display(\"%d\"); endmodule", "missing display argument");
    // #42: `%5%` is no §9.4.2 escape, and is refused rather than printed.
    try @import("root.zig").expectRejected("module m; initial $display(\"%5%\"); endmodule", "second `%` of `%%`");
}

test "§17.1.1.2 no field width or precision is too large" {
    // One past the old 4096 bound and well past it; `%.5000f` of 0.5 is
    // "0." and 5000 digits, a 5 then 4999 zeros.
    var want: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer want.deinit();
    try want.writer.splatByteAll(' ', 4096);
    try want.writer.writeAll("1|");
    try want.writer.splatByteAll(' ', 19999);
    try want.writer.writeAll("x|0.5");
    try want.writer.splatByteAll('0', 4999);
    try want.writer.writeAll("\n");
    try @import("root.zig").expectRun("module m; initial $display(\"%4097d|%20000s|%.5000f\", 1, \"x\", 0.5); endmodule", want.written());
}
