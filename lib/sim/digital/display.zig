//! §17 display, strobe, monitor, `%t` and memory-load formatting: a task's
//! arguments and the values they name (or a memory file's text) in; bytes on
//! `Run.out` (or words stored into an unpacked array) out. With a null
//! allocator the same walk validates the call without printing.
//! Memory loads live in readmem.zig and the standing monitor in monitor.zig;
//! this file re-exports their names, which rt/ and the emitter read here.
//! Cites: §9.4.1 Table 9-1, §9.4.3 Table 9-22; IEEE 1364-2005 §17.1.1.3,
//! §17.1.1.4, §17.1.2, §17.1.3, §17.2.9, §17.3, §17.7.2.
//!
//! Contents:
//! - `pub const TimeFormat`
//! - `pub const MemLoad`
//! - `pub const readMemory`
//! - `pub const load_ended`
//! - `pub const unknown_bound`
//! - `pub const not_a_name`
//! - `pub const outside_memory`
//! - `pub const cannot_read`
//! - `pub const sideFile`
//! - `pub const monitorPrint`
//! - `pub const monitorDue`
//! - `pub const install`
//! - `pub const cancelFile`
//! - `pub const comparedOperand`
//! - `pub const monitorChanged`
//! - `pub const fmonitorPrint`
//! - `pub const Show = struct`
//! - `pub const Task = union(enum)`
//! - `pub const tasks`
//! - `pub const sformat_mismatch`
//! - `pub const Fill = enum`
//! - `pub const TimescaleTarget = struct`
//! - `pub fn display(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator, show: Show) Error!void`
//! - `pub fn sformat(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator) Error!void`
//! - `pub fn real(out: *std.Io.Writer, gpa: std.mem.Allocator, r: f64, conv: u8, flags: u8, precision: i64, width: ?u64) (std.mem.Allocator.Error || std.Io.Writer.Error)!void`
//! - `pub fn fieldFill(sp: fmt.Spec, conv: u8) ?Fill`
//! - `pub fn fillField(out: *std.Io.Writer, text: []const u8, f: Fill) std.Io.Writer.Error!void`
//! - `pub fn zeroFilled(out: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void`
//! - `pub fn realRadix(out: *std.Io.Writer, a: std.mem.Allocator, r: f64, radix: Radix, width: ?u64) (std.mem.Allocator.Error || std.Io.Writer.Error)!void`
//! - `pub fn emitScope(self: *Run) Error!void`
//! - `pub fn strength(out: *std.Io.Writer, s: Signal) std.Io.Writer.Error!void`
//! - `pub fn printTimescale(self: *Run, args: []const Ast.ExprId) Error!void`
//! - `pub fn timescaleScope(self: *Run, e: Ast.ExprId) Error!TimescaleTarget`
//! - `V.expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) error{Found}!void {}`
//! - `V.stmt(v: @This(), c: Ast.StmtId) error{Found}!void`
//! §17 display, strobe, monitor, `%t` and memory-load formatting: a task's
//! arguments and the values they name (or a memory file's text) in; bytes on
//! `Run.out` (or words stored into an unpacked array) out. With a null
//! allocator the same walk validates the call without printing.
//! Clauses: §9.4.1 Table 9-1, §9.4.3 Table 9-22; IEEE 1364-2005 §17.1.1.3,
//! §17.1.1.4, §17.1.2, §17.1.3, §17.2.9, §17.3, §17.7.2.
const std = @import("std");
const assert = std.debug.assert;
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
const monitor = @import("monitor.zig");
const readmem = @import("readmem.zig");

/// §17.3.2 `$timeformat`'s state; the type is `fmt`'s so `rt` shares it.
pub const TimeFormat = fmt.TimeFormat;

/// `readmem.MemLoad`.
pub const MemLoad = readmem.MemLoad;

/// `readmem.readMemory`.
pub const readMemory = readmem.readMemory;

/// `readmem.load_ended`.
pub const load_ended = readmem.load_ended;

/// `readmem.unknown_bound`.
pub const unknown_bound = readmem.unknown_bound;

/// `readmem.not_a_name`.
pub const not_a_name = readmem.not_a_name;

/// `readmem.outside_memory`.
pub const outside_memory = readmem.outside_memory;

/// `readmem.cannot_read`.
pub const cannot_read = readmem.cannot_read;

/// `readmem.sideFile`.
pub const sideFile = readmem.sideFile;

/// `monitor.monitorPrint`.
pub const monitorPrint = monitor.monitorPrint;

/// `monitor.monitorDue`.
pub const monitorDue = monitor.monitorDue;

/// `monitor.install`.
pub const install = monitor.install;

/// `monitor.cancelFile`.
pub const cancelFile = monitor.cancelFile;

/// `monitor.comparedOperand`.
pub const comparedOperand = monitor.comparedOperand;

/// `monitor.monitorChanged`.
pub const monitorChanged = monitor.monitorChanged;

/// `monitor.fmonitorPrint`.
pub const fmonitorPrint = monitor.fmonitorPrint;

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
    /// §17.2.10 `$sdf_annotate` (`sdf.zig`).
    sdf_annotate,
    /// §18.1 the value change dump tasks.
    dump: @import("vcd.zig").Op,
    /// §18.3 the extended value change dump tasks.
    ports: @import("evcd.zig").Op,
    /// IEEE 1364-2005 §20.3 a PLI application's task (`Run.host.systf`).
    user,
};

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
    .{ "$sdf_annotate", .sdf_annotate },
    .{ "$dumpfile", Task{ .dump = .file } },
    .{ "$dumpvars", Task{ .dump = .vars } },
    .{ "$dumpoff", Task{ .dump = .off } },
    .{ "$dumpon", Task{ .dump = .on } },
    .{ "$dumpall", Task{ .dump = .all } },
    .{ "$dumplimit", Task{ .dump = .limit } },
    .{ "$dumpflush", Task{ .dump = .flush } },
}) ++ pla_rows);

/// The W1153 text.
pub const sformat_mismatch = "$sformat: the format's specifiers and the arguments after it do not pair up";

/// How a non-real field's C flag reshapes its padded text: '-' (`%t` only,
/// `fmt.flagVerdict`) moves the leading pad to the end, '0' (with a nonzero
/// width) turns it into zeros after the sign. 1364 grants C's flags to the
/// real conversions only and says nothing of them elsewhere; VerA renders
/// iverilog's text.
pub const Fill = enum { zero, left };

/// What `$printtimescale`'s argument names: a scope, or the object `leaf`
/// declared in one.
pub const TimescaleTarget = struct { scope: u32, leaf: ?Ast.StrId = null };

const TaskRow = struct { []const u8, Task };

const pla_rows: []const TaskRow = blk: {
    var rows: [system.pla_tasks.len]TaskRow = undefined;
    for (system.pla_tasks, &rows) |t, *row| row.* = .{ t[0], Task{ .pla = t[1] } };
    const out = rows;
    break :blk &out;
};

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

/// §17.1.1.2 one real conversion (`%e %f %g`, §9.4.7 `%r`): C's text under
/// C11 7.21.6.1p6's `flags` (`str_real.zc_*`; `fmt.flagVerdict` has
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
    const text = zCReal(buf, r, conv, flags & ~(str_real.zc_left | str_real.zc_zero), 0, precision);
    const pad = (width orelse 0) -| text.len;
    if (flags & str_real.zc_left != 0) {
        try out.writeAll(text);
        return out.splatByteAll(' ', @intCast(pad));
    }
    const zero = flags & str_real.zc_zero != 0 and std.math.isFinite(r);
    const sign: usize = if (zero and text.len != 0 and (text[0] == '-' or text[0] == '+' or text[0] == ' ')) 1 else 0;
    try out.writeAll(text[0..sign]);
    try out.splatByteAll(if (zero) '0' else ' ', @intCast(pad));
    try out.writeAll(text[sign..]);
}

/// `sp`'s `Fill` for conversion `conv`, if any; '-' wins over '0', as in C,
/// and a `%s` field's '0' pads with spaces still (iverilog: `%05s` of "ab"
/// is "   ab", `%05c` of 65 "0000A").
pub fn fieldFill(sp: fmt.Spec, conv: u8) ?Fill {
    if (sp.flags & str_real.zc_left != 0) return .left;
    if (sp.flags & str_real.zc_zero != 0 and (sp.width orelse 0) != 0 and conv | 0x20 != 's') return .zero;
    return null;
}

/// `text`, one field as written with its leading pad, reshaped by `f`.
pub fn fillField(out: *std.Io.Writer, text: []const u8, f: Fill) std.Io.Writer.Error!void {
    if (f == .zero) return zeroFilled(out, text);
    const pad = std.mem.indexOfNone(u8, text, " ") orelse text.len;
    try out.writeAll(text[pad..]);
    try out.splatByteAll(' ', pad);
}

/// A field written with C's '0' flag and a width (`%05d`, `%04h`, `%06t`):
/// `text`, the field as the conversion padded it with spaces on the left,
/// with those spaces as zeros after any sign. §17.1.1.2 grants C's flags to
/// the real conversions only and leaves a width's leading zero open; this is
/// iverilog's text (ivtest delay.v's `%04d`).
pub fn zeroFilled(out: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    const pad = std.mem.indexOfNone(u8, text, " ") orelse text.len;
    const sign: usize = @intFromBool(pad < text.len and text[pad] == '-');
    try out.writeAll(text[pad..][0..sign]);
    try out.splatByteAll('0', pad);
    try out.writeAll(text[pad + sign ..]);
}

/// A radix conversion (`%d %h %o %b`) of a real, as iverilog prints it
/// (VD-120): the §4.8.2 integer, exact at any magnitude, at minimal width
/// unless the format gives one, since §17.1.1.3 sizes by a bit width a real
/// does not have; an infinity or a NaN, which has no integer, as C spells it.
pub fn realRadix(out: *std.Io.Writer, a: std.mem.Allocator, r: f64, radix: Radix, width: ?u64) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    // A negative real that rounds to zero keeps its sign under `%d`, as
    // C's `%.0f` (iverilog's br1029a: -0.4 is `-0`).
    const neg_zero = radix == .decimal and @round(r) == 0 and std.math.signbit(r);
    if (!std.math.isFinite(r) or neg_zero) {
        const text = if (neg_zero) "-0" else if (std.math.isNan(r)) "nan" else if (r < 0) "-inf" else "inf";
        try out.splatByteAll(' ', @intCast((width orelse 0) -| text.len));
        return out.writeAll(text);
    }
    // `intOfReal` fails only for memory.
    const v = evaluate.intOfReal(a, r) catch return error.OutOfMemory;
    try fmt.value(out, a, v, radix, width orelse 0);
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
        var it = self.program.blocks.iterator();
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

/// IEEE 1364-2005 §17.3.1 `$printtimescale`: "the time unit and precision of
/// the module that is the current scope", or with an argument "of the module
/// passed to it", in the clause's format `Time scale of (name) is unit /
/// precision`. The clause names a module and leaves the printed name open;
/// VerA prints what iverilog prints: the full hierarchical name of the
/// current module instance, or of the argument, which may name any object
/// (a named block, a variable, a parameter) and reports its module's scale.
pub fn printTimescale(self: *Run, args: []const Ast.ExprId) Error!void {
    const t: TimescaleTarget = if (args.len == 1) try timescaleScope(self, args[0]) else .{ .scope = self.instanceOf(self.scope) };
    const mt = self.timeOf(t.scope);
    const prec_exp = mt.unit_exp - @as(i32, std.math.log10_int(@as(u64, mt.scale.local_per_unit)));
    try self.out.writeAll("Time scale of (");
    try emitPath(self, t.scope);
    if (t.leaf) |name| try self.out.print(".{s}", .{self.file.str(name)});
    try self.out.writeAll(") is ");
    try fmt.decade(self.out, mt.unit_exp);
    try self.out.writeAll(" / ");
    try fmt.decade(self.out, prec_exp);
    try self.out.writeByte('\n');
}

/// §17.3.1 what `$printtimescale`'s argument names, by §12.5's resolution:
/// an instance (or a named block that declares something, which `instances`
/// holds too), or a variable, net or parameter and the scope declaring it
/// (iverilog takes any such object). The first name is searched for upward
/// from the current scope to its module, then among the top-level modules.
/// A named block that declares nothing has no scope, so is found in its
/// module's source (`namedBlock`).
pub fn timescaleScope(self: *Run, e: Ast.ExprId) Error!TimescaleTarget {
    assert(e != .none);
    const ex = &self.file.exprs;
    const parts: []const Ast.StrId = switch (ex.tag(e)) {
        .ident => &.{ex.strOf(e)},
        .hier_ident => ex.nameParts(e),
        // Syntax 17-9's argument is a hierarchical_identifier (A.9.3), so
        // a bit- or word-select (`r[0]`, ivtest pr1701855b) is refused.
        else => return self.exprFail(e, "§17.3.1: $printtimescale names a module instance or an object in one"), // else: no hierarchical_identifier
    };
    var scope: u32 = blk: {
        var at = self.scope;
        while (true) {
            if (self.hier.instances.get(.{ .scope = at, .str = parts[0] })) |child| break :blk child;
            if (parts.len == 1 and (self.hier.names.contains(.{ .scope = at, .str = parts[0] }) or namedBlock(self, at, parts[0]))) return .{ .scope = at, .leaf = parts[0] };
            if (!self.hier.scopes.items[at].lexical) break;
            at = self.hier.scopes.items[at].parent;
        }
        for (self.hier.roots) |t| if (self.hier.scopes.items[t].name == parts[0]) break :blk t;
        if (parts.len == 1) return self.exprFail(e, "§17.3.1: $printtimescale names no object of this design");
        return self.exprFail(e, "undeclared instance in a hierarchical reference");
    };
    for (parts[1..], 1..) |p, i| {
        if (self.hier.instances.get(.{ .scope = scope, .str = p })) |child| {
            scope = child;
        } else if (i + 1 == parts.len and (self.hier.names.contains(.{ .scope = scope, .str = p }) or namedBlock(self, scope, p))) {
            return .{ .scope = scope, .leaf = p };
        } else if (i + 1 == parts.len) {
            return self.exprFail(e, "§17.3.1: $printtimescale names no object of this design");
        } else return self.exprFail(e, "undeclared instance in a hierarchical reference");
    }
    return .{ .scope = scope };
}

// ---- private ----

fn showAs(radix: Radix, newline: bool) Show {
    return .{ .radix = radix, .newline = newline };
}

fn toFile(radix: Radix) Show {
    return .{ .radix = radix, .newline = true, .file = true };
}

fn sformatMismatch(self: *Run, e: Ast.ExprId) Error!void {
    assert(e != .none);
    const at = self.starts[@min(self.file.exprs.mainTok(e), self.starts.len - 1)];
    try self.bag.add(self.stage(), .W1153, .{ .start = at, .end = at }, sformat_mismatch, .{});
}

/// A format `e` that ran out before its specifiers did: one held in a
/// variable (`dynamic`) warns and the task stops (`sformatMismatch`), a
/// literal one is refused with `msg`.
fn short(self: *Run, e: Ast.ExprId, dynamic: bool, comptime msg: []const u8) Error!void {
    assert(e != .none);
    return if (dynamic) sformatMismatch(self, e) else self.exprFail(e, msg);
}

/// The argument after `arg` that a specifier of format `e` consumes, or null
/// when the format ran out (`short` warned). A null argument (`, ,`) is
/// §9.4.1's single space only where no specifier consumes it.
fn operand(self: *Run, args: []const Ast.ExprId, arg: usize, e: Ast.ExprId, dynamic: bool) Error!?usize {
    assert(arg < args.len);
    assert(e != .none);
    const next = arg + 1;
    if (next == args.len) {
        try short(self, e, dynamic, "missing display argument");
        return null;
    }
    if (args[next] == .none) return self.exprFail(e, "§17.1.1.2: a format specification's argument is an expression, not a null argument");
    assert(args[next] != .none);
    return next;
}

fn walk(self: *Run, args: []const Ast.ExprId, allocator: ?std.mem.Allocator, show: Show, only_first: bool) Error!void {
    const ex = &self.file.exprs;
    var arg: usize = 0;
    while (arg < args.len) : (arg += 1) {
        const e = args[arg];
        if (only_first and arg != 0) {
            // Arguments left over once the format is used up.
            for (args[arg..]) |rest| if (rest != .none) try compile.checkExpr(self, rest);
            // W1153 points at the first leftover, or the format past a null one.
            if (allocator != null) try sformatMismatch(self, if (e != .none) e else args[0]);
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
            if (allocator) |a| {
                if (compile.typeOf(self, e).real) try bareReal(self, a, e) else try fmt.value(self.out, a, try evaluate.eval(self, a, e, 0), show.radix, null);
            }
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
            if (i == format.len) return short(self, e, dynamic, "unterminated display format");
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
            if (i == format.len) return short(self, e, dynamic, "unterminated display format");
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
                'h', 'H', 'x', 'X' => .hex,
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
                    arg = (try operand(self, args, arg, e, dynamic)) orelse return;
                    try compile.checkExpr(self, args[arg]);
                    // A real operand is formatted as it is, not rounded to
                    // a whole unit first (#64).
                    if (allocator) |a| {
                        const out = self.out;
                        defer self.out = out;
                        var field: std.Io.Writer.Allocating = .init(a);
                        const fill = fieldFill(sp, format[i]);
                        if (fill != null) self.out = &field.writer;
                        const tf = self.time.format.field(width, precision);
                        const unit_exp = self.timeOf(self.scope).unit_exp;
                        if (compile.typeOf(self, args[arg]).real)
                            try fmt.time(self.out, try evaluate.evalReal(self, a, args[arg]), tf, unit_exp)
                        else {
                            const v = try evaluate.eval(self, a, args[arg], 0);
                            if (v.hasUnknown()) try fmt.timeUnknown(self.out, v, tf) else try fmt.timeInt(self.out, a, v, tf, unit_exp);
                        }
                        if (fill) |f| try fillField(out, field.written(), f);
                    }
                    continue;
                },
                // §17.1.1.6 `%m` and §13.6 `%l` consume no argument: they
                // print where the display is, not a value.
                'm', 'M' => {
                    if (allocator != null) try emitScope(self);
                    continue;
                },
                'l', 'L' => {
                    const def = self.hier.scopes.items[self.scope].def;
                    if (allocator != null) try self.out.print("{s}.{s}", .{ self.file.str(self.hier.def_lib[def]), self.file.str(self.file.modules[def].name) });
                    continue;
                },
                // §17.1.1.5 `%v`: "the strength of scalar nets".
                'v', 'V' => {
                    arg = (try operand(self, args, arg, e, dynamic)) orelse return;
                    try compile.checkExpr(self, args[arg]);
                    if (compile.typeOf(self, args[arg]).width != 1) return self.exprFail(args[arg], "§17.1.1.5: %v takes a scalar net reference");
                    const net = if (ex.tag(args[arg]) == .ident) self.netlist.slot_nets.get(try self.slot(args[arg])) else null;
                    // The resolution keeps a net's `signal` only when read.
                    if (net) |n| self.netlist.nets[n].strength_read = true;
                    if (allocator) |a| {
                        const n = if (net) |k| self.netlist.nets[k] else null;
                        // §7.6: a pass switch drives a net with no driver of its own.
                        const sig: Signal = if (n == null)
                            .of((try evaluate.eval(self, a, args[arg], 0)).bit(0), .strong, .strong)
                        else if (self.netDrivers(net.?).len == 0 and self.netCold(n.?).trans.len == 0) netPull(n.?.kind) else self.netlist.signals[n.?.signal];
                        try strength(self.out, sig);
                    }
                    continue;
                },
                // §17.1.1.7 `%s` (the operand as 8-bit ASCII codes) and
                // `%c` (its low eight bits as one character).
                's', 'S', 'c', 'C' => {
                    arg = (try operand(self, args, arg, e, dynamic)) orelse return;
                    try compile.checkExpr(self, args[arg]);
                    if (allocator) |a| {
                        const out = self.out;
                        defer self.out = out;
                        var field: std.Io.Writer.Allocating = .init(a);
                        const fill = fieldFill(sp, format[i]);
                        if (fill != null) self.out = &field.writer;
                        try fmt.text(self.out, try evaluate.eval(self, a, args[arg], 0), format[i] == 'c' or format[i] == 'C', width);
                        if (fill) |f| try fillField(out, field.written(), f);
                    }
                    continue;
                },
                // §17.1.1.2 `%u`/`%z`: the operand's two- or four-value bits
                // as binary data.
                'u', 'U', 'z', 'Z' => {
                    arg = (try operand(self, args, arg, e, dynamic)) orelse return;
                    try compile.checkExpr(self, args[arg]);
                    if (allocator) |a| try unformatted(self.out, try evaluate.eval(self, a, args[arg], 0), format[i] == 'z' or format[i] == 'Z');
                    continue;
                },
                else => return self.exprFail(
                    e,
                    "only the §9.4.3 Table 9-22 conversions (%b, %o, %h, %d, %e, %f, %g, §9.4.7 %r and %%) and %c %s %m %l %t %u %v %z are implemented",
                ),
            };
            arg = (try operand(self, args, arg, e, dynamic)) orelse return;
            if (radix) |r| {
                try compile.checkExpr(self, args[arg]);
                if (allocator) |a| {
                    // `%05d`: C's '0' flag, which iverilog renders
                    // (`fillField`).
                    const out = self.out;
                    defer self.out = out;
                    var field: std.Io.Writer.Allocating = .init(a);
                    const fill = fieldFill(sp, format[i]);
                    if (fill != null) self.out = &field.writer;
                    if (compile.typeOf(self, args[arg]).real)
                        try realRadix(self.out, a, try evaluate.evalReal(self, a, args[arg]), r, width)
                    else
                        try fmt.value(self.out, a, try evaluate.eval(self, a, args[arg], 0), r, width);
                    if (fill) |f| try fillField(out, field.written(), f);
                }
            } else {
                try compile.checkExpr(self, args[arg]);
                if (allocator) |a| try real(self.out, a, try evaluate.evalReal(self, a, args[arg]), format[i], sp.flags, precision, width);
            }
        }
    }
    if (allocator != null and show.newline) try self.out.writeByte('\n');
}

/// A real argument with no format. §17.1.1.2's "default decimal format" is
/// an integer's, and 1364 names none for a real; VerA prints what iverilog
/// prints: C's `%#g`, and a bare `$realtime` call in `%.Nf`, N the decimal
/// digits of its module's precision below its unit.
fn bareReal(self: *Run, a: std.mem.Allocator, e: Ast.ExprId) Error!void {
    assert(e != .none);
    const r = try evaluate.evalReal(self, a, e);
    if (self.file.exprs.tag(e) == .sys_call and self.typing.sys_calls[@backingInt(e)].? == .realtime) {
        const digits = std.math.log10_int(@as(u64, self.timeOf(self.scope).scale.local_per_unit));
        return real(self.out, a, r, 'f', 0, digits, null);
    }
    try real(self.out, a, r, 'g', str_real.zc_alt, -1, null);
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

/// Scope `s`'s hierarchical name, root first.
fn emitPath(self: *Run, s: u32) Error!void {
    const info = self.hier.scopes.items[s];
    if (info.parent != s and s != 0) {
        try emitPath(self, info.parent);
        try self.out.writeByte('.');
    }
    try self.out.writeAll(self.file.str(info.name));
    // §12.4.1 one iteration of a loop generate is `name[value]`.
    if (info.index) |i| try self.out.print("[{d}]", .{i});
}

/// Whether a block named `name` that declares nothing, so has no scope of
/// its own (`elab.blockScopes`), is in module instance `scope`'s
/// initial and always constructs.
fn namedBlock(self: *const Run, scope: u32, name: Ast.StrId) bool {
    assert(scope < self.hier.scopes.items.len);
    if (self.hier.scopes.items[scope].lexical) return false;
    const V = struct {
        f: *const Ast.SourceFile,
        name: Ast.StrId,
        /// An expression holds no named block: nothing to find.
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) error{Found}!void {}
        /// `error.Found` at the named block the walk is looking for.
        pub fn stmt(v: @This(), c: Ast.StmtId) error{Found}!void {
            if (c == .none) return;
            switch (v.f.stmt(c)) {
                .block => |b| if (b.name == v.name) return error.Found,
                else => {}, // else: only a block is named
            }
            try v.f.stmtEdges(c, v);
        }
    };
    for (self.file.modules[self.hier.scopes.items[scope].def].discrete) |d|
        (V{ .f = self.file, .name = name }).stmt(d.body) catch return true;
    return false;
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
        // %s shows s's leading zero bytes as spaces (VD-129; iverilog the same).
    , "[   t=3]\n[   ab!]\n[o-long]\nTime scale of (m) is 10us / 100ns\n");
}

// §17.1.1.2 grants C's flags to the real conversions only; a radix or `%t`
// width written with a leading zero pads with zeros after the sign, as
// iverilog prints it (ivtest delay.v's `%04d`; this transcript is iverilog's).
test "§17.1.1.2 a zero-led width pads a radix or time field with zeros" {
    try expectRun(
        \\module t; reg [7:0] r; integer i; reg [3:0] x;
        \\initial begin r = 8'h5; i = -5; x = 4'bx01x;
        \\$display("[%04d][%04h][%06b][%04o][%05d][%06d][%04d][%03d][%04t][%4d]", r, r, r, r, i, x, 12345, 3'd2, 5, r);
        \\end endmodule
        \\
    , "[0005][0005][00000101][0005][-0005][00000X][12345][002][0005][   5]\n");
}

// §17.3.1 leaves the printed name and a non-module argument open; iverilog
// (ivtest pr1701855, pr1701855b) prints this transcript: the current module
// instance's full name with no argument, and for an argument its full name,
// a select as `[i]`/`[i:i]`, and its own module's scale.
test "§17.3.1 $printtimescale names any object by its full hierarchical name" {
    try expectRun(
        \\`timescale 1us/1ns
        \\module top;
        \\  reg [1:0] r; reg a [0:2]; wire w;
        \\  initial begin : blk
        \\    $printtimescale(dut); $printtimescale(dut.q); $printtimescale(r); $printtimescale(a);
        \\    $printtimescale(top.w); $printtimescale(blk); $printtimescale(dut.t);
        \\  end
        \\  lower dut();
        \\endmodule
        \\`timescale 10ns/10ps
        \\module lower; reg q; task t; ; endtask initial #1 $printtimescale; endmodule
        \\
    ,
        \\Time scale of (top.dut) is 10ns / 10ps
        \\Time scale of (top.dut.q) is 10ns / 10ps
        \\Time scale of (top.r) is 1us / 1ns
        \\Time scale of (top.a) is 1us / 1ns
        \\Time scale of (top.w) is 1us / 1ns
        \\Time scale of (top.blk) is 1us / 1ns
        \\Time scale of (top.dut.t) is 10ns / 10ps
        \\Time scale of (top.dut) is 10ns / 10ps
        \\
    );
    try @import("root.zig").expectRejected("module m; reg [1:0] r; initial $printtimescale(r[0]); endmodule", "names a module instance or an object in one");
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
    // of 1500 is "1.5K", left in 6. `%05d` is C's zero fill, as iverilog
    // prints it (VD-129).
    try expectRun(
        \\module m; initial $display("[%-8.2f|%+e|% .1f|%08.3f|%#.0f|%-6r|%05d]", 2.5, 1.5, 3.0, -2.5, 2.0, 1500.0, 42);
        \\endmodule
        \\
    , "[2.50    |+1.500000e+00| 3.0|-002.500|2.|1.5K  |00042]\n");
    // '-' left-justifies a `%t` field, as iverilog prints it (ivtest
    // br_gh1591a's `%-700t`); on any other it, '+' and ' ' stay refused.
    try expectRun("`timescale 1ns/1ps\nmodule m; initial $display(\"[%-6t][%05c][%05s]\", 3, 65, \"ab\"); endmodule", "[3000  ][0000A][   ab]\n");
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
        if (f & str_real.zc_alt != 0 and !str_real.zcAltOk(conv)) continue; // E0825
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
