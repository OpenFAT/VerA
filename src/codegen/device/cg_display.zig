//! Void display, file-I/O and simulation-control `call`s -> labeled block
//! expressions around `std.debug.print`, `std.mem.print` or the file kernels, with
//! §9.4.3 conversions translated into Zig format text.
//! LRM §9.4 (display), §9.5 (file I/O), §9.7 (simulation control).
//! Runs only when `codegen.Display` is `.emit`; under `.drop` no call reaches it.
//!
//! Contents:
//! - `pub const Ops = std.ArrayList(cg_format.PrintArg)`
//! - `pub fn buildArgs(g: *Gen, args: []const Mir.Value, fmt: *std.ArrayList(u8), ops: *Ops) Error!void`
//! - `pub fn siteCap(g: *Gen, fmt: []const u8, ops: []const cg_format.PrintArg) Error!u64`
//! - `pub fn emitRow(g: *Gen, site: usize, cap: u64) Error!void`
//! - `pub fn emitDisplayTask(g: *Gen, c: Mir.Callee, args: []const Mir.Value, inst: Mir.Inst) Error!void`
//! - `pub fn emitSimCtl(g: *Gen, name: []const u8, args: []const Mir.Value, inst: Mir.Inst) Error!void`
//! - `pub fn emitStringFormat(g: *Gen, args: []const Mir.Value, site: usize) Error!void`
//! - `pub fn emitStringFormatRt(g: *Gen, args: []const Mir.Value, site: usize) Error!void`
//! - `pub fn severityWord(c: Mir.Callee) ?[]const u8`
//! - `pub fn endsLine(c: Mir.Callee) bool`
//! - `pub fn emitBufPrint(g: *Gen, fmt: []const u8, ops: []const cg_format.PrintArg, site: usize) Error!void`
//! - `pub fn emitScratch(g: *Gen, ops: []const cg_format.PrintArg, site: usize) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const strcap = @import("cg_strcap.zig");

// -------------------------------------------------------- §9.4 display ----
//
// Codegen renders values, not statements, so a display call renders as a
// labeled block expression whose value is the `S.con(0.0)` the dropped form
// produces; the print is its side effect. It is emitted because
// `Lower.finishDisplays` chained it into a live root.
const Harness = @import("codegen/harness.zig").Harness;
const cg_file_io = @import("cg_file_io.zig");
const cg_format = @import("cg_format.zig");

/// One call's print operands, in format order.
pub const Ops = std.ArrayList(cg_format.PrintArg);

/// The most operands one `std.fmt` call takes (`std.fmt.ArgSetType`'s bits).
/// A call with more is emitted as consecutive calls of at most this many.
const fmt_chunk = @typeInfo(std.fmt.ArgSetType).int.bits;

comptime {
    // The chunk loops advance by it.
    assert(fmt_chunk > 0);
}

/// §9.4.1's argument-list model, shared by every sink (display, §9.5.2 file
/// writers, §9.5.3 string writers). Every string argument is a format whose
/// conversions consume the expression arguments after it; an expression no
/// format consumed prints in the §9.4.3 default decimal format; nothing
/// inserts separators (a null argument is §9.4.1's space).
///
/// §9.1 makes Verilog-AMS "a superset of IEEE Std 1364 Verilog", and §9.4.1
/// "extends the display tasks so that they can be used in the analog
/// context" without a sizing rule of its own, so IEEE 1364 §17.1.1.3's
/// automatic sizing holds here as in the digital engine (#61): a bare or
/// `%d` number pads to its largest value's columns (`decimalField`: 11 for
/// an `integer`, 20 for a real), the radices show their leading zeros at
/// every width lowering records, and `%0d`/`%0h` print minimal-width.
/// One deviation: a bare real prints shortest-round-trip decimal, not `%g`.
pub fn buildArgs(
    g: *Gen,
    args: []const Mir.Value,
    fmt: *std.ArrayList(u8),
    ops: *Ops,
) Error!void {
    const ops_before = ops.items.len;
    var i: usize = 0;
    while (i < args.len) {
        if (g.strArg(args, i)) |s| {
            i += 1;
            i += try cg_format.translateFormat(g, s, args[i..], fmt, ops);
        } else {
            try cg_format.appendConv(g, fmt, ops, args[i], 0, .{});
            i += 1;
        }
    }
    // `translateFormat` consumes no more operands than it was handed.
    assert(i == args.len);
    // `chunkText` splits the text at the operands' starts, so they ascend
    // and lie inside it.
    var at_prev: usize = 0;
    for (ops.items[ops_before..]) |op| {
        assert(op.at >= at_prev);
        assert(op.at <= fmt.items.len);
        at_prev = op.at;
    }
}

/// The bytes call `site`'s text can need: the Zig format text (an upper
/// bound on its literal part) plus each operand's `textMax`, never below
/// `strcap.row`, the row every site had.
pub fn siteCap(g: *Gen, fmt: []const u8, ops: []const cg_format.PrintArg) Error!u64 {
    assert(ops.len <= std.math.maxInt(u32));
    var n: u64 = fmt.len;
    for (ops) |p| n +|= try p.textMax(g);
    assert(n >= fmt.len);
    const cap = @max(n, strcap.row);
    assert(cap >= strcap.row);
    return cap;
}

/// Call `site`'s formatted-text row: `zSBuf` for the 4096-byte row, else a
/// row of `cap` bytes (`str_store.zSRow`, slot 0). Asserts that `cap` is
/// at least `strcap.row` (`siteCap`, `strcap.rtFormatCap`).
pub fn emitRow(g: *Gen, site: usize, cap: u64) Error!void {
    assert(cap > 0);
    assert(cap >= strcap.row);
    const len_before = g.out.items.len;
    if (cap == strcap.row or !try fits(g, site, cap))
        try g.b("zSBuf({d})", .{site})
    else
        try g.b("zSRow({d}, 0, {d})", .{ site, cap });
    assert(g.out.items.len > len_before);
}

/// Emits one §9.4.1 display or §9.7.3 severity task as a labeled block that
/// prints to stderr (the transcript; stdout belongs to a host that pipes
/// data). `inst` keys `$monitor`'s scratch row. `$fatal` also halts.
pub fn emitDisplayTask(g: *Gen, c: Mir.Callee, args: []const Mir.Value, inst: Mir.Inst) Error!void {
    assert(g.display == .emit);
    assert(g.mir.instOp(inst) == .call);
    const site: usize = @backingInt(inst);
    var fmt: std.ArrayList(u8) = .empty;
    var ops: Ops = .empty;
    // §9.7.3 the severity and the moment open the line (`emitWhen`, below);
    // the message follows a space.
    if (severityWord(c) != null) try fmt.append(g.arena, ' ');
    // §9.7.3 Syntax 9-7: `$fatal ( finish_number [, message_argument … ] )`.
    // The finish_number sets the $finish diagnostic level; it is not part of
    // the message, so it must not print. Dropped only when it is not a string,
    // so a (nonconforming but unambiguous) `$fatal("bye")` keeps its text.
    // §9.4.1 a monitor report carries its site key first (`Lower.armMonitor`).
    const mon = c == .@"$monitor";
    if (mon) assert(args.len > 0);
    const body = if (mon or (c == .@"$fatal" and args.len > 0 and g.strArg(args, 0) == null))
        args[1..]
    else
        args;
    assert(body.len <= args.len);
    try buildArgs(g, body, &fmt, &ops);
    // `appendConv` writes a `{…}` per operand.
    assert(ops.items.len <= fmt.items.len);
    // §9.4.1: `$write` is the family member that does NOT end the line.
    if (endsLine(c)) try fmt.append(g.arena, '\n');

    // A width-padded integer goes through `zPadInt` because Zig's `{d:>5}`
    // writes `+42` where §9.4.3 writes ` 42`; its scratch is a stack array
    // in this block.
    try g.b("zd: {{ ", .{});
    try emitScratch(g, ops.items, site);
    // §9.7.3: the severity is the message's whole reason for existing, and a
    // reader cannot recover it from the text; "these tasks shall also report
    // the simulation run time", at the Table 9-25 level `$fatal`'s
    // finish_number sets.
    const level = if (c == .@"$fatal") finishLevel(g, args) else 1;
    if (severityWord(c)) |word| try emitWhen(g, word, inst, level);
    if (mon) {
        // §9.4.1's mechanism: format into this site's scratch row, then report
        // only when a watched argument VALUE differs from the step this site
        // last reported (`monitorValues`). An overrun is `emitStringFormat`'s
        // E1011.
        try g.b("if (zMonitor({d}, ", .{cg_file_io.monitorKey(g, args)});
        try cg_file_io.monitorValues(g, ops.items);
        try g.b(", ", .{});
        try emitBufPrint(g, fmt.items, ops.items, site);
        try g.b(")) |zt| std.debug.print(\"{{s}}\", .{{zt}}); ", .{});
    } else try emitDebugPrint(g, fmt.items, ops.items);
    // §9.7.3: `$fatal` "terminates the simulation with an errorcode". The
    // finish_number "may be used in an implementation-specific manner"; here
    // it is the exit status, floored at 1 so a `$fatal` never reads as success
    // to a shell. `zHalt` is f64-typed so the dead code after it still
    // compiles; `break :zd` is statically reachable, never taken.
    if (c == .@"$fatal") try g.b("_ = zHalt({d}); ", .{std.math.clamp(level, 1, 255)});
    try g.b("break :zd S.con(0.0); }}", .{});
}
// ------------------------------------------- §9.4 a device's display records ----
//
// A `.record` device cannot print, so its `say` (`dispatch.emitDisplay`)
// runs the display chain at an accepted point and appends one record per
// task to the host's `contract.Say`: the site's index and its numeric
// values. The site's text is fixed here, once, as one C-style format
// (`contract.SaySite.fmt`) the host renders with `contract.formatSay`.

/// Emits §9.7.1 `$finish` / §9.7.2 `$stop` in the printing artifact: the run
/// ends at the call, after every print before it. Table 9-25 level 0 prints
/// nothing; level >= 1 prints the moment (`emitWhen`) and the location, the
/// module; level 2's memory and CPU statistics are the host's (`zWhen`).
/// Both exit 0: the display phase runs on the accepted solution, which is
/// where §9.7.1 exits.
///
/// ponytail: `$stop` exits because a batch artifact has nothing to suspend
/// into; add a debugger hook in the runner when something interactive can
/// resume.
pub fn emitSimCtl(g: *Gen, name: []const u8, args: []const Mir.Value, inst: Mir.Inst) Error!void {
    assert(name.len != 0);
    assert(g.mir.instOp(inst) == .call);
    const level = finishLevel(g, args);
    const len_before = g.out.items.len;
    try g.b("zd: {{ ", .{});
    // §5.10.2: "final_step will also generate a global event upon the
    // termination of the simulation due to a $finish() simulation control
    // task." The request is recorded here; the enclosing `display` wrapper
    // performs it after the pass, where the solution vector is in hand (this
    // unit holds only its probe). The nested pass sees `zFinish` set and
    // halts without printing or raising the event twice.
    const kind: u8 = if (Mir.Callee.fromName(name) == .@"$finish") 1 else 2;
    try g.b("if (zFinish == 0) {{ ", .{});
    if (level >= 1) {
        try emitWhen(g, name, inst, level);
        try g.b("std.debug.print(\" ({f})\\n\", .{{}}); ", .{std.zig.fmtString(g.mir.name)});
    }
    try g.b("zFinish = {d}; }} break :zd S.con(0.0); }}", .{kind});
    assert(g.out.items.len > len_before);
}

/// Emits §9.5.3 `$swrite`/`$sformat` ("the same as their counterparts ...
/// except that ... the resulting string shall be written"): `emitDisplayTask`'s
/// translation into call site `site`'s scratch row, with no newline. The
/// block's value is the formatted string. §3.3 removes NUL bytes only after
/// formatting, so field widths count the original bytes.
pub fn emitStringFormat(g: *Gen, args: []const Mir.Value, site: usize) Error!void {
    assert(site < g.mir.instCount());
    var fmt: std.ArrayList(u8) = .empty;
    var ops: Ops = .empty;
    try buildArgs(g, args, &fmt, &ops);
    assert(ops.items.len <= fmt.items.len);
    const len_before = g.out.items.len;
    try g.b("zs: {{ ", .{});
    try emitScratch(g, ops.items, site);
    // An overrun ends the run with E1011 (`zSOver`): §9.5.3 states no
    // truncation rule, and an empty or half string is a wrong answer. The
    // row is sized for every operand (`siteCap`), so only a run-time string
    // longer than the compiler could know can overrun it.
    try g.b("break :zs zStringStore(", .{});
    try emitBufPrint(g, fmt.items, ops.items, site);
    try g.b("); }}", .{});
    assert(g.out.items.len > len_before);
}

/// Emits §9.5.3 `$sformat` whose format_string is a string VARIABLE ("whose
/// content is interpreted as the format string"): `args[0]` is the format,
/// the rest its operands, each passed in its own type to
/// `str_format.zSFormatRt`, which walks the format at run time. `%m` prints
/// what `translateFormat` prints for it.
pub fn emitStringFormatRt(g: *Gen, args: []const Mir.Value, site: usize) Error!void {
    assert(site < g.mir.instCount());
    const len_before = g.out.items.len;
    try g.b("zStringStore(zSFormatRt(", .{});
    try emitRow(g, site, try strcap.rtFormatCap(g, args));
    try g.b(", ", .{});
    try g.renderVal(if (args.len > 0) args[0] else Mir.Value.f_zero, .str);
    try g.b(", \"{f}\", .{{", .{std.zig.fmtString(g.mir.name)});
    for (args[@min(1, args.len)..], 0..) |a, k| {
        if (k != 0) try g.b(", ", .{});
        switch (g.an.tyOf(g.an.rv(a))) {
            .real => {
                try g.b("@as(f64, (", .{});
                try g.renderVal(a, .real);
                try g.b(").val())", .{});
            },
            .int => {
                try g.b("@as(i64, ", .{});
                try g.renderVal(a, .int);
                try g.b(")", .{});
            },
            .str => {
                try g.b("@as([]const u8, ", .{});
                try g.renderVal(a, .str);
                try g.b(")", .{});
            },
            .wide => unreachable, // lowering hands a task no wide value: a whole wide `reg` read is E0222
        }
    }
    try g.b("}}))", .{});
    assert(g.out.items.len > len_before);
}
// ------------------------------------------------------- §9.5 file I/O ----
//
// §9.5.2 defines its five output tasks as the §9.4.1 ones "with one additional
// argument, which is either a multichannel descriptor or a file descriptor", so
// they share this formatter. The descriptor operations have no text but are
// sequenced in the same unit (`codegen.Gen.emitting_display`).

/// Returns the §9.7.3 severity prefix of `c`, or null for every other task.
pub fn severityWord(c: Mir.Callee) ?[]const u8 {
    const word: ?[]const u8 = switch (c) {
        .@"$fatal" => "FATAL",
        .@"$error" => "ERROR",
        .@"$warning" => "WARNING",
        .@"$info" => "INFO",
        else => null, // else: §9.7.3 has exactly these four; every other task prints no severity
    };
    if (word) |w| assert(w.len != 0);
    return word;
}

/// §9.4.1: does the task end its line? `$write` and its radix forms are the
/// members that do not, and §9.5.2's `$fwrite` is named after `$write`.
pub fn endsLine(c: Mir.Callee) bool {
    const ends = switch (c) {
        .@"$write", .@"$writeb", .@"$writeo", .@"$writeh", .@"$fwrite" => false,
        else => true, // else: every other §9.4.1/§9.5.2 printing task is a `$display`-like one
    };
    // Every §9.7.3 severity task ends its line.
    if (severityWord(c) != null) assert(ends);
    return ends;
}

/// `std.mem.print(row, fmt, .{ops})` into call `site`'s row, as a slice
/// expression; an overrun is E1011 (`zSOver`). Past `fmt_chunk` operands the
/// text goes through one fixed writer, a print per chunk.
pub fn emitBufPrint(g: *Gen, fmt: []const u8, ops: []const cg_format.PrintArg, site: usize) Error!void {
    assert(site < g.mir.instCount());
    const cap = try siteCap(g, fmt, ops);
    if (ops.len <= fmt_chunk) {
        try g.b("std.mem.print(", .{});
        try emitRow(g, site, cap);
        try g.b(", \"{f}\", .{{", .{std.zig.fmtString(fmt)});
        try renderPrintArgs(g, ops, 0);
        return g.b("}}) catch zSOver()", .{});
    }
    try g.b("zw{d}: {{ var zw: std.Io.Writer = .fixed(", .{site});
    try emitRow(g, site, cap);
    try g.b("); ", .{});
    var k: usize = 0;
    while (k < ops.len) : (k += fmt_chunk) {
        const end = @min(k + fmt_chunk, ops.len);
        assert(end > k);
        try g.b("zw.print(\"{f}\", .{{", .{std.zig.fmtString(chunkText(fmt, ops, k, end))});
        try renderPrintArgs(g, ops[k..end], k);
        try g.b("}}) catch zSOver(); ", .{});
    }
    assert(k >= ops.len);
    try g.b("break :zw{d} zw.buffered(); }}", .{site});
}

/// The per-op scratch declarations of one emitted display block: a stack
/// array, or call `site`'s static row for operand i (`zSRow` slot i + 1) when
/// the field is wider than `Spec.max_stack`.
pub fn emitScratch(g: *Gen, ops: []const cg_format.PrintArg, site: usize) Error!void {
    assert(site < g.mir.instCount());
    for (ops, 0..) |p, i| {
        const n = p.scratch() orelse continue;
        if (p.onStack())
            try g.b("var zb{d}: [{d}]u8 = undefined; ", .{ i, n })
        else
            try g.b("const zb{d} = zSRow({d}, {d}, {d}); ", .{ i, site, i + 1, if (try fits(g, site, n)) n else strcap.row });
    }
}

// ---- private ----

/// Whether a row of `cap` bytes at call `site` can exist: past
/// `strcap.max_row` it is more than a device can address, which is E1011
/// at compile time (memory, the one bound a row has).
fn fits(g: *Gen, site: usize, cap: u64) Error!bool {
    assert(site < g.mir.instCount());
    if (cap <= strcap.max_row) return true;
    if (g.diags) |bag| try bag.add(.codegen, .E1011, g.lowered.tokenSpan(g.mir.instTok(@fromBackingInt(@intCast(site)))), "the text here can need {d} bytes, more than a device can address", .{cap});
    g.poison("a string row is larger than a device can address");
    assert(g.any_fatal);
    return false;
}

/// `std.debug.print(fmt, .{ops})`, one print per `fmt_chunk` operands.
fn emitDebugPrint(g: *Gen, fmt: []const u8, ops: []const cg_format.PrintArg) Error!void {
    assert(g.display == .emit);
    var k: usize = 0;
    while (true) : (k += fmt_chunk) {
        // One print per chunk, and one for no operands at all.
        assert(k <= ops.len);
        const end = @min(k + fmt_chunk, ops.len);
        assert(end >= k);
        try g.b("std.debug.print(\"{f}\", .{{", .{std.zig.fmtString(chunkText(fmt, ops, k, end))});
        try renderPrintArgs(g, ops[k..end], k);
        try g.b("}}); ", .{});
        if (end == ops.len) return;
    }
}

/// The format text of operands `k..end`: from operand k's `{` (the call's
/// start for the first chunk) to the next chunk's (the end for the last).
fn chunkText(fmt: []const u8, ops: []const cg_format.PrintArg, k: usize, end: usize) []const u8 {
    assert(k <= end);
    assert(end <= ops.len);
    // A later chunk starts at an operand the call has.
    if (k != 0) assert(k < ops.len);
    const from = if (k == 0) 0 else ops[k].at;
    const to = if (end == ops.len) fmt.len else ops[end].at;
    assert(from <= to);
    assert(to <= fmt.len);
    return fmt[from..to];
}

/// Operands `ops`, the first of which is the call's operand `first`.
fn renderPrintArgs(g: *Gen, ops: []const cg_format.PrintArg, first: usize) Error!void {
    assert(ops.len <= std.math.maxInt(u32));
    const len_before = g.out.items.len;
    for (ops, first..) |p, i| {
        if (i != first) try g.b(", ", .{});
        try cg_format.renderPrintArg(g, p, i);
    }
    if (ops.len != 0) assert(g.out.items.len > len_before);
    if (ops.len == 0) assert(g.out.items.len == len_before);
}

/// §9.7.1's diagnostic argument, folded. Syntax 9-5/9-7 make it the literal
/// 0 | 1 | 2; anything that does not fold takes the default 1.
fn finishLevel(g: *Gen, args: []const Mir.Value) i64 {
    if (args.len == 0) return 1;
    return switch (g.mir.valueDef(g.an.rv(args[0]))) {
        .int_const => |x| x,
        .float_const => |x| std.math.lossyCast(i64, x),
        .undef, .str_const, .param_ref, .block_param, .inst_result => 1,
    };
}

/// Emits a diagnostic's opening, `task: ` then the moment it reports, with no
/// newline. §9.7.1/§9.7.3: a task in an `analog initial` block reports "that
/// the call was made during initialization" in place of the time; every other
/// one reports the simulation time, or the host's dc sweep point, through
/// `zWhen` at `sim.t`, which also prints Table 9-25 `level` 2's statistics.
fn emitWhen(g: *Gen, task: []const u8, inst: Mir.Inst, level: i64) Error!void {
    assert(task.len != 0);
    if (std.mem.findScalar(Mir.Inst, g.init_calls, inst) != null)
        return g.b("std.debug.print(\"{s}: initialization\", .{{}}); ", .{task});
    g.cur.uses.sim = true;
    const len_before = g.out.items.len;
    try g.b("std.debug.print(\"{s}: \", .{{}}); zWhen(sim.t, {d}); ", .{ task, std.math.clamp(level, 0, 2) });
    assert(g.out.items.len > len_before + task.len);
}

/// One analog block body → the printing artifact's text, in `arena`.
fn emitBody(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const src = try arena.print(
        \\module t(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog begin
        \\    {s}
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
        \\
    , .{body});
    var h: Harness = undefined;
    try Harness.run(arena, src, &h);
    return h.genDisplay(arena);
}

fn has(text: []const u8, needle: []const u8) bool {
    return std.mem.find(u8, text, needle) != null;
}

test "§9.4.1 every string argument opens a format run; output concatenates" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Two runs, each consuming its own operand: `a=1b=2`, with no separator
    // anywhere: the second string is a FORMAT, not the first run's operand.
    // Each `%d` of an unsized literal, a 32-bit `integer` (IEEE 1364 §3.5.1),
    // pads to its 11 columns (§17.1.1.3, #61).
    const two = try emitBody(a, "$strobe(\"a=%d\", 1, \"b=%d\", 2);");
    try std.testing.expect(has(two, "\"a={s:>11}b={s:>11}\\n\""));

    // A string consumed BY a conversion stays an operand: `%s` takes "x",
    // then "y=%d" opens the next run over 2.
    const eaten = try emitBody(a, "$strobe(\"%s;\", \"x\", \"y=%d\", 2);");
    try std.testing.expect(has(eaten, "\"{s};y={s:>11}\\n\""));

    // An expression before the first string prints in the §9.4.3 default,
    // in order: `3.5lead          7`.
    const lead = try emitBody(a, "$strobe(3.5, \"lead %d\", 7);");
    try std.testing.expect(has(lead, "\"{d}lead {s:>11}\\n\""));
    try std.testing.expect(has(lead, "S.con(3.5)"));

    // No inserted space before a bare trailing operand: §9.4.1's way to
    // write a space is a null argument. Its default decimal format is
    // `%d`'s, so the 11 columns are the field's own (#61).
    const bare = try emitBody(a, "$strobe(\"v:\", 42);");
    try std.testing.expect(has(bare, "\"v:{s:>11}\\n\""));
}

test "§9.7.3 $fatal's finish_number is a diagnostic level, not message text" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try emitBody(a, "$fatal(0, \"died %d\", 7);");
    // The 0 is consumed by the skip, not printed by the walk; it is the
    // Table 9-25 level the moment prints at (`emitWhen`).
    try std.testing.expect(has(out, "std.debug.print(\"FATAL: \", .{}); zWhen(sim.t, 0); "));
    try std.testing.expect(has(out, "\" died {s:>11}\\n\""));
    try std.testing.expect(!has(out, "}died"));
}

test "§9.4.3 Table 9-23: every real conversion routes through the C kernel" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // All four conversions become one `zCReal` call and one `{s}`: the kernel
    // composes the whole field, so no outer alignment is left to apply.
    const e = try emitBody(a, "$strobe(\"%e\", 1.5);");
    try std.testing.expect(has(e, "zCReal(&zb0, (S.con(1.5)).val(), 'e', 0, 0, -1)"));
    try std.testing.expect(has(e, "\"{s}\\n\""));

    // Width and precision reach the kernel as NUMBERS (C puts the pad inside
    // the field, behind the sign), never as a Zig format tail.
    const wp = try emitBody(a, "$strobe(\"%10.4e\", 1.5);");
    try std.testing.expect(has(wp, "'e', 0, 10, 4)"));
    try std.testing.expect(!has(wp, "{s:>10}"));

    // The conversion letter travels in the CASE the source wrote it: `%E`
    // spells the exponent marker (and INF/NAN) upper case.
    const up = try emitBody(a, "$strobe(\"%E\", 1.5);");
    try std.testing.expect(has(up, "'E', 0, 0, -1)"));

    // The flag bits, in `zCReal`'s order: 1 '-', 2 '+', 4 ' ', 8 '0'.
    const fl = try emitBody(a, "$strobe(\"%+08.1f\", 2.5);");
    try std.testing.expect(has(fl, "'f', 10, 8, 1)"));

    // #41: '#' is the flag 16, never the letter; the 'g' after it is.
    const alt = try emitBody(a, "$strobe(\"%#g|\", 2.5);");
    try std.testing.expect(has(alt, "'g', 16, 0, -1)"));
    try std.testing.expect(has(alt, "\"{s}|\\n\""));

    // Table 9-23's `%r` is engineering notation, not a second spelling of
    // `%g`; it reaches the same kernel with its own letter.
    const r = try emitBody(a, "$strobe(\"%r\", 1.5);");
    try std.testing.expect(has(r, "'r', 0, 0, -1)"));
}

test "§9.4.3/C11 7.21.6.1: zCReal is the conversion the device runs" {
    // `str_real.zig` is spliced into every printing artifact, so these are
    // the renderings a model gets. Each row is a rule of the clause: the %g
    // style choice on both sides of its window, sign/zero-fill placement, the
    // round-half-to-even tie, and §2.6.2's mantissa normalisation.
    // Imported through the `kernels` module: a file may live in one module.
    const k = @import("kernels").str_real;
    var b: [1024]u8 = undefined;
    const rows = .{
        .{ 1234.5678, 'g', @as(u8, 0), @as(usize, 0), @as(i64, -1), "1234.57" },
        .{ 1.0e-5, 'g', 0, 0, -1, "1e-05" }, // exponent below -4 -> %e
        .{ 1.0e8, 'g', 0, 0, -1, "1e+08" }, // exponent at/above P -> %e
        .{ 2.5, 'f', 10, 8, 1, "+00002.5" }, // '+' then the zero fill
        .{ -3.5, 'f', 8, 9, 2, "-00003.50" }, // the pad is BEHIND the sign
        .{ -3.5, 'f', 1, 9, 2, "-3.50    " }, // '-' overrides '0'
        .{ 2.5, 'f', 0, 0, 0, "2" }, // an exact tie goes to the EVEN digit
        .{ 3.5, 'f', 0, 0, 0, "4" }, // ...which round-half-away gets wrong
        .{ 1.5, 'e', 0, 0, -1, "1.500000e+00" },
        .{ 2.0, 'e', 16, 0, 0, "2.e+00" }, // '#': the point always prints
        .{ 2.0, 'f', 16, 0, 0, "2." },
        .{ 1.5, 'g', 16, 0, -1, "1.50000" }, // ...and %g keeps its zeros
        // %#g of 999999.5: rounding to P = 6 digits carries to 1e6, so X = 6
        // = P picks style e at P - 1 = 5 digits, zeros kept (#41; glibc
        // prints "1.e+06", tests/printf_reference.zig routes around it).
        .{ 999999.5, 'g', 16, 0, -1, "1.00000e+06" },
        .{ 999999.5, 'G', 16, 0, -1, "1.00000E+06" },
        .{ 999999.5, 'g', 16, 13, -1, "  1.00000e+06" },
        .{ 999999.5, 'g', 17, 13, -1, "1.00000e+06  " }, // '-'
        .{ 999999.5, 'g', 18, 0, -1, "+1.00000e+06" }, // '+'
        .{ 999999.5, 'g', 20, 13, -1, "  1.00000e+06" }, // ' '
        .{ 999999.5, 'g', 24, 13, -1, "001.00000e+06" }, // '0'
        .{ 999999.4999, 'g', 16, 0, -1, "999999." }, // no carry: X = 5, style f
        .{ 0.0015, 'r', 0, 0, -1, "1.5m" },
        .{ 2.0e-13, 'R', 0, 0, -1, "200f" }, // not "0.2p": the mantissa is >= 1
    };
    inline for (rows) |row| {
        try std.testing.expectEqualStrings(row[5], k.zCReal(&b, row[0], row[1], row[2], row[3], row[4]));
    }
    // C11 7.21.6.1p13 rounds the VALUE, not its shortest decimal: 0.1 is not
    // 0.1, and past 17 digits that is visible.
    try std.testing.expectEqualStrings("0.10000000000000000555", k.zCReal(&b, 0.1, 'f', 0, 0, 20));
}

test "§9.4.1 $monitor reports a step only when the record changed" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `$strobe` prints unconditionally; `$monitor` goes through §9.4.1's
    // mechanism, which is the whole difference between the two tasks. The
    // needles are CALL-shaped: the kernel's own text is in both artifacts.
    const s = try emitBody(a, "$strobe(\"v=%0d\", 1);");
    try std.testing.expect(has(s, "zd: { std.debug.print("));
    const m = try emitBody(a, "$monitor(\"v=%0d\", 1);");
    try std.testing.expect(has(m, "S.con(zMonitorArm(0))")); // the invocation
    try std.testing.expect(has(m, "zd: { if (zMonitor(0, "));
    try std.testing.expect(has(m, ") |zt| std.debug.print(\"{s}\", .{zt});"));
    // §9.5.2 "$fmonitor ... works just like its counterpart": the record is
    // composed, then written only if it changed.
    const f = try emitBody(a, "$fmonitor(1, \"v=%0d\", 1);");
    try std.testing.expect(has(f, "break :zf if (zMonitor(0, "));
    try std.testing.expect(has(f, ") |zm| zFPut("));

    // The latch itself, at the boundary the emitted code uses it at.
    const k = @import("kernels").str_store;
    // "When a $monitor task is invoked ... the simulator sets up a mechanism":
    // before the statement has run there is no mechanism and nothing reports.
    try std.testing.expect(k.zMonitor(9001, &[_]u64{1}, "a\n") == null);
    _ = k.zMonitorArm(9001);
    _ = k.zMonitorArm(9002);
    try std.testing.expectEqualStrings("a\n", k.zMonitor(9001, &[_]u64{1}, "a\n").?); // first step: no predecessor
    try std.testing.expect(k.zMonitor(9001, &[_]u64{1}, "a\n") == null); // unchanged
    // The watched VALUES decide, not the text: a line that differs only in an
    // exempt `$abstime` (never in `vals`) is not a change.
    try std.testing.expect(k.zMonitor(9001, &[_]u64{1}, "t=2 a\n") == null);
    try std.testing.expectEqualStrings("b\n", k.zMonitor(9001, &[_]u64{2}, "b\n").?);
    try std.testing.expect(k.zMonitor(9001, &[_]u64{2}, "b\n") == null);
    // A DISTINCT site is a distinct latch: two monitors must not mask each
    // other, exactly as two `$sformat` sites must not share a row.
    try std.testing.expectEqualStrings("b\n", k.zMonitor(9002, &[_]u64{2}, "b\n").?);
}

test "§9.5.4.2 a scan consumes per DIRECTIVE, and says how much" {
    // `ZScan.used` is what `$fscanf` advances the descriptor by, so these
    // numbers are §9.5.5's `$ftell` answers (see `file_kernels.zFTake`).
    const k = @import("kernels").str_scan;
    // "The offending input character is left unread": nothing moved, and the
    // return is 0 and not EOF, because the input has not ended.
    const fail = k.zScan("abc\n", "%d", -1);
    try std.testing.expectEqual(@as(i64, 0), fail.n);
    try std.testing.expectEqual(@as(usize, 0), fail.used);
    // "Trailing white space (including newline characters) is left unread
    // unless matched by a directive": the field is two bytes, not the line.
    const first = k.zScan("12 34\n56\n", "%d", 0);
    try std.testing.expectEqual(@as(i64, 12), first.i);
    try std.testing.expectEqual(@as(usize, 2), first.used);
    // White space in the CONTROL string matches a newline, so one scan can
    // take a field from each of two lines.
    const two = k.zScan("12\n34\n", "%d %d", 1);
    try std.testing.expectEqual(@as(i64, 2), two.n);
    try std.testing.expectEqual(@as(i64, 34), two.i);
    try std.testing.expectEqual(@as(usize, 5), two.used);
    // "If the input ends before the first matching failure or conversion, EOF
    // is returned", and the white space looked through still counts consumed.
    const eof = k.zScan("\n", "%d", -1);
    try std.testing.expectEqual(@as(i64, -1), eof.n);
    try std.testing.expectEqual(@as(usize, 1), eof.used);
    // §9.5.4.2's `%r`, over §2.6.2 Table 2-1: both spellings of the 1e3 row,
    // and an optional symbol.
    try std.testing.expectEqual(@as(f64, 2500.0), k.zScan("2.5K", "%r", 0).r);
    try std.testing.expectEqual(@as(f64, 2500.0), k.zScan("2.5k", "%r", 0).r);
    try std.testing.expectEqual(@as(f64, 4.0), k.zScan("4", "%r", 0).r);
    // `%m` "does not read data from the input file or str argument", so the
    // directive after it still sees the whole field.
    const path = k.zScan("42", "%m%d", 1);
    try std.testing.expectEqual(@as(i64, 2), path.n);
    try std.testing.expectEqual(@as(i64, 42), path.i);
}

test "§9.4.3/C: integer sign flags — %05d packs zeros after the sign, %+d prints it" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // `%05d` of -42 must print `-0042`, not Zig's `00-42`: the negative branch
    // writes the sign first and zero-pads the magnitude to width-1.
    const z = try emitBody(a, "$strobe(\"%05d\", -42);");
    try std.testing.expect(has(z, "\"-{d:0>4}\""));
    try std.testing.expect(has(z, "\"{d:0>5}\""));

    // `%+d` of 7 prints `+7`.
    const plus = try emitBody(a, "$strobe(\"%+d\", 7);");
    try std.testing.expect(has(plus, "if (zv < 0) \"\" else \"+\""));

    // A width alone routes through zPadInt (`  -42`, ` 42`).
    const pad = try emitBody(a, "$strobe(\"%5d\", -42);");
    try std.testing.expect(has(pad, "zPadInt(&zb0, "));
    try std.testing.expect(has(pad, "\"{s:>5}\\n\""));
}

test "§9.7 simulation control: the run ends at the call, with the pinned status" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // §9.7.3: $fatal prints its message, then exits with the finish_number as
    // the errorcode (fatal_terminates.va checks the run's exit status).
    const fat = try emitBody(a, "$fatal(2, \"died %0d\", 7);");
    try std.testing.expect(has(fat, "std.debug.print(\"FATAL: \", .{}); zWhen(sim.t, 2); "));
    try std.testing.expect(has(fat, "\" died {d}\\n\""));
    try std.testing.expect(has(fat, "_ = zHalt(2); "));
    // ...floored at 1, so a $fatal never reads as success to a shell.
    const fat0 = try emitBody(a, "$fatal(0, \"boom\");");
    try std.testing.expect(has(fat0, "_ = zHalt(1); "));
    // $error stays non-fatal: same severity family, no exit at its call site
    // (the kernel text is present in every printing artifact; the CALL is not).
    const err = try emitBody(a, "$error(\"soft\");");
    try std.testing.expect(!has(err, "_ = zHalt(1)"));
    try std.testing.expect(!has(err, "_ = zHalt(2)"));

    // §9.7.1: the default diagnostic level is 1 ("prints simulation time and
    // location"), and the exit status is 0: ending the run is the task's
    // defined behaviour, not a failure. §5.10.2's `final_step` re-run is the
    // display wrapper's job, so the site records the request (`zFinish`: 1
    // for `$finish`, 2 for `$stop`) and the wrapper halts.
    const fin = try emitBody(a, "$finish;");
    try std.testing.expect(has(fin, "std.debug.print(\"$finish: \", .{}); zWhen(sim.t, 1); std.debug.print(\" (t)\\n\", .{}); zFinish = 1; "));
    // Table 9-25 level 0 prints nothing (and still exits); level 2 asks the
    // host's hook for its statistics.
    const fin0 = try emitBody(a, "$finish(0);");
    try std.testing.expect(!has(fin0, "$finish: "));
    try std.testing.expect(has(fin0, "zFinish = 1; "));
    const fin2 = try emitBody(a, "$finish(2);");
    try std.testing.expect(has(fin2, "std.debug.print(\"$finish: \", .{}); zWhen(sim.t, 2); "));
    // §9.7.2 $stop, non-interactive artifact: diagnostic then exit 0. Not
    // `$finish`, so §5.10.2's final_step event is not raised.
    const stp = try emitBody(a, "$stop(1);");
    try std.testing.expect(has(stp, "std.debug.print(\"$stop: \", .{}); zWhen(sim.t, 1); std.debug.print(\" (t)\\n\", .{}); zFinish = 2; "));

    // The kernel is `std.process.exit`, f64-typed so the legal dead code
    // after a terminating call still compiles.
    try std.testing.expect(has(fin, "fn zHalt(code: u8) f64 {\n    std.process.exit(code);\n}"));
}

test "§9.7.1/§9.7.3 a diagnostic's moment: the time, or initialization in analog initial" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var h: Harness = undefined;
    try Harness.run(a,
        \\module t(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  analog initial $info("i");
        \\  analog begin
        \\    $warning("w");
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
        \\
    , &h);
    const out = try h.genDisplay(a);
    // "The call was made during initialization" in place of the time: a
    // property of the block, decided here, not of `sim`.
    try std.testing.expect(has(out, "std.debug.print(\"INFO: initialization\", .{}); std.debug.print(\" i\\n\", .{}); "));
    // Everywhere else the host's hook picks the time or the dc sweep's variable.
    try std.testing.expect(has(out, "std.debug.print(\"WARNING: \", .{}); zWhen(sim.t, 1); std.debug.print(\" w\\n\", .{}); "));
}

test "§9.4.3 Table 9-22: %h shows the operand's two's-complement bit pattern" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // -42 is an `integer` (an unsized literal, IEEE 1364 Table 5-22), so `%h`
    // is its 32-bit pattern with §17.1.1.3's leading zeros, ffffffd6 (#77):
    // 8 hex, 11 octal, 32 binary digits; the u64 bitcast stops Zig's `{x}`
    // writing `-2a`, the u32 truncate keeps the low 32 bits.
    const out = try emitBody(a, "$strobe(\"%h %o %b\", -42, -42, -42);");
    try std.testing.expect(has(out, "\"{x:0>8} {o:0>11} {b:0>32}\\n\""));
    try std.testing.expect(has(out, "@as(u32, @truncate(@as(u64, @bitCast(@as(i64, "));
    // A 64-bit operand keeps its leading zeros too: 16 hex digits.
    const wide = try emitBody(a, "$strobe(\"%h\", 64'h1);");
    try std.testing.expect(has(wide, "\"{x:0>16}\\n\""));
    // `%0h` overrides the automatic size: the minimal digits.
    const min = try emitBody(a, "$strobe(\"%0h\", -42);");
    try std.testing.expect(has(min, "\"{x}\\n\""));
}

test "§9.4.5 numeric strings preserve source width through every output sink" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const out = try emitBody(a, "$display(\"%s\", 8'shff); $write(\"%S\", 64'h4142434445464748);");
    try std.testing.expect(has(out, "std.mem.writeInt(u64"));
    try std.testing.expect(has(out, "@as(u8, @truncate(@as(u64"));
    try std.testing.expect(has(out, "@as(u64, @truncate(@as(u64"));
    try std.testing.expect(has(out, "std.mem.trimStart(u8"));
}

test severityWord {
    try std.testing.expectEqualStrings("FATAL", severityWord(.@"$fatal").?);
    try std.testing.expectEqualStrings("ERROR", severityWord(.@"$error").?);
    try std.testing.expectEqualStrings("WARNING", severityWord(.@"$warning").?);
    try std.testing.expectEqualStrings("INFO", severityWord(.@"$info").?);
    try std.testing.expect(severityWord(.@"$display") == null);
    try std.testing.expect(severityWord(.@"$strobe") == null);
}

test endsLine {
    // §9.4.1: `$write` and its radix forms, and §9.5.2's `$fwrite`, do not.
    for ([_]Mir.Callee{ .@"$write", .@"$writeb", .@"$writeo", .@"$writeh", .@"$fwrite" }) |c|
        try std.testing.expect(!endsLine(c));
    for ([_]Mir.Callee{ .@"$display", .@"$strobe", .@"$monitor", .@"$fdisplay", .@"$error" }) |c|
        try std.testing.expect(endsLine(c));
}

test "§9.4.1 a call past 32 operands prints in runs of 32, in order (#29)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const rep = struct {
        fn f(al: std.mem.Allocator, s: []const u8, k: usize) ![]const u8 {
            var o: std.ArrayList(u8) = .empty;
            for (0..k) |_| try o.appendSlice(al, s);
            return o.items;
        }
    }.f;
    // 32 operands: one print, as before. `%0d`, so each operand is `{d}`.
    const d32 = try emitBody(a, try std.mem.concat(a, u8, &.{ "$strobe(", try rep(a, "\"%0d\", 1, ", 31), "\"%0d\", 1);" }));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, d32, "std.debug.print(\"{d}"));
    // 33: the first print takes 32 and the text up to the 33rd, the second
    // the 33rd and the newline.
    const d33 = try emitBody(a, try std.mem.concat(a, u8, &.{ "$strobe(", try rep(a, "\"%0d\", 1, ", 32), "\"x%0d\", 2);" }));
    try std.testing.expect(has(d33, try std.mem.concat(a, u8, &.{ "std.debug.print(\"", try rep(a, "{d}", 32), "x\", .{" })));
    try std.testing.expect(has(d33, "std.debug.print(\"{d}\\n\", .{"));
}

test "§9.5.3 a site's row is sized from the widths written (#29)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const src =
        \\module t(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  string s, w;
        \\  analog begin
        \\    $sformat(s, "%4000d", 1);
        \\    $sformat(w, "%5000d|%06000d", 1, 2);
        \\    I(p, n) <+ V(p, n) * ((s == w) + 1);
        \\  end
        \\endmodule
        \\
    ;
    var h: Harness = undefined;
    try Harness.run(a, src, &h);
    const out = try h.genDisplay(a);
    // Within 4096 bytes: the row every site had.
    try std.testing.expect(has(out, "zSBuf("));
    // Past it: the text (5000 + 1 + 6000) plus the Zig format text, and the
    // zero-filled field's 6002-byte scratch as a static row, not a frame.
    try std.testing.expect(has(out, ", 0, 110"));
    try std.testing.expect(has(out, "const zb1 = zSRow("));
    try std.testing.expect(has(out, ", 2, 6002); "));
}

test "PrintArg.scratch sizes the stack field each composed mode needs" {
    const at = struct {
        fn f(how: cg_format.PrintArg.Mode, spec: cg_format.Spec) ?usize {
            return (cg_format.PrintArg{ .v = .f_zero, .want = .int, .how = how, .spec = spec }).scratch();
        }
    }.f;
    try std.testing.expectEqual(@as(?usize, 8), at(.ascii, .{}));
    try std.testing.expectEqual(@as(?usize, 24), at(.pad, .{}));
    // The widest decimal, or the whole zero-filled field plus sign room.
    try std.testing.expectEqual(@as(?usize, 24), at(.cint, .{}));
    try std.testing.expectEqual(@as(?usize, 32), at(.cint, .{ .width = 30 }));
    // A sign, 309 integer digits, the point and the precision, or the width.
    try std.testing.expectEqual(@as(?usize, 6 + 320 + 8), at(.creal, .{}));
    try std.testing.expectEqual(@as(?usize, 400 + 8), at(.creal, .{ .width = 400, .prec = 10 }));
    // The rest render into the argument tuple.
    try std.testing.expectEqual(@as(?usize, null), at(.plain, .{}));
    try std.testing.expectEqual(@as(?usize, null), at(.bits, .{}));
    try std.testing.expectEqual(@as(?usize, null), at(.chr, .{}));
}

test "§9.4.3 a %d operand that is a phi prints its value, not a zero of the wrong type" {
    // bsim4va.va's `default: $strobe("... %d ...", BSIM4dioMod)` under a
    // card-decided `if`: the operand reaches the print only through
    // `$display$width`, whose operand the display unit did not plan, so it
    // rendered as `const t: i64 = S.con(0.0)` and the testbench failed to
    // compile.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\module t(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\  parameter integer diomod = 1;
        \\  parameter real is = 1e-14;
        \\  integer m;
        \\  real x, s;
        \\  analog begin
        \\    m = diomod;
        \\    if ((m != 0) && (m != 1) && (m != 2)) begin
        \\      m = 1;
        \\      $strobe("reset");
        \\    end
        \\    s = is * 2;
        \\    x = 0.0;
        \\    if (s > 0.0) begin
        \\      case (m)
        \\        0: x = 1.0;
        \\        1: x = 2.0;
        \\        default: $strobe("m = %d not matched", m);
        \\      endcase
        \\    end
        \\    I(p, n) <+ x * V(p, n);
        \\  end
        \\endmodule
        \\
    ;
    var h: Harness = undefined;
    try Harness.run(a, src, &h);
    const out = try h.genDisplay(a);
    try std.testing.expect(has(out, "not matched"));
    try std.testing.expect(!has(out, ": i64 = S.con("));
}
