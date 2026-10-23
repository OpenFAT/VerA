//! Void display, file-I/O and simulation-control `call`s -> labeled block
//! expressions around `std.debug.print`, `std.mem.print` or the file kernels, with
//! §9.4.3 conversions translated into Zig format text.
//! LRM §9.4 (display), §9.5 (file I/O), §9.7 (simulation control).
//! Runs only when `codegen.Display` is `.emit`; under `.drop` no call reaches it.

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const VTy = Analysis.VTy;
const strcap = @import("cg_strcap.zig");
const str_k = @import("kernels").str_kernels;

// -------------------------------------------------------- §9.4 display ----
//
// Codegen renders values, not statements, so a display call renders as a
// labeled block expression whose value is the `S.con(0.0)` the dropped form
// produces; the print is its side effect. It is emitted because
// `Lower.finishDisplays` chained it into a live root.

/// Parsed §9.4.3 conversion prefix: `%[flags][width][.precision]conv`. Table
/// 9-23 grants the real conversions "the full formatting capabilities
/// available in the C language", so C11 7.21.6.1 defines each flag; the
/// integer conversions share the grammar. Width and precision are numbers
/// because the composed C-style fields need them as arithmetic.
pub const Spec = struct {
    /// '-' left-justify; C makes it override '0'.
    left: bool = false,
    /// '+' always spell the sign.
    plus: bool = false,
    /// ' ' a space where the sign would be; '+' wins.
    space: bool = false,
    /// '0' pad with zeros AFTER the sign.
    zero: bool = false,
    /// '#' C's alternative form; lowering admits it on %e/%f/%g only (E0825).
    alt: bool = false,
    /// The field width; 0 = no width given.
    width: usize = 0,
    /// The precision; null = no precision given.
    prec: ?usize = null,

    // The scratch for a composed field is a stack array in the emitted block
    // up to what a field of this width and precision needs; a wider field's
    // scratch is a static row (`str_kernels.zSRow`), so no field makes a
    // huge frame (`PrintArg.onStack`).
    const max_stack = 4096;
    fn p(self: Spec, default: usize) usize {
        return self.prec orelse default;
    }
};

/// One rendered `std.debug.print` operand: the value, the Zig type the chosen
/// conversion needs it in, and HOW it is rendered. `%h` on a real is a
/// real→integer conversion (§4.2.1.1), not a reinterpretation, so `want` is
/// not always the value's own type.
const PrintArg = struct {
    v: Mir.Value,
    want: VTy,
    how: Mode = .plain,
    spec: Spec = .{},
    /// `.creal`: the source's conversion letter, case kept, because `%E`/`%G`
    /// print the exponent marker and INF/NAN in upper case.
    conv: u8 = 0,
    /// Original integer width, before SSA and the i64 storage carrier.
    bits: u7 = 64,
    /// Where this operand's `{…}` starts in the call's Zig format text: a
    /// call with more operands than one `std.fmt` call takes is split here.
    at: usize = 0,

    /// How `renderPrintArg` spells the operand: which helper, if any, sits
    /// between the value and the Zig format verb.
    pub const Mode = enum {
        /// Straight through the Zig verb the conversion mapped to.
        plain,
        /// §9.4.3 `%c`: the operand's low byte (Table 9-22 "display as an
        /// ASCII character"), narrowed to the `u8` Zig's `{c}` takes.
        chr,
        /// `%<width>d` with no sign/zero flag: render the decimal TEXT through
        /// `zPadInt` and pad it as a string. See `emitDisplayTask` for why.
        pad,
        /// `%+d` / `% d` / `%0<width>d`: C puts the sign inside the field
        /// (`+42`, ` 42`, `-0042`), which no Zig format spec can spell, so the
        /// field text is composed in per-op scratch and printed as `{s}`.
        cint,
        /// §9.4.3 Table 9-23's real conversions (`%e`, `%f`, `%g`, engineering
        /// `%r`) through `str_kernels.zCReal`, which follows C11 7.21.6.1
        /// (round half to even) where Zig's float verbs do not. The kernel
        /// composes the whole field, sign and padding included.
        creal,
        /// `%h`/`%o`/`%b`: the two's-complement bit pattern of the operand.
        /// Zig's radix verbs on an i64 print `-2a` instead, hence a u64
        /// bitcast around the rendered integer.
        bits,
        /// §9.4.5: most-significant byte first, with leading zero bytes removed.
        ascii,
    };

    /// Bytes of per-op scratch the emitted block declares, or null for the
    /// modes that render straight into the print's argument tuple.
    /// Lowering bounds every width and precision a source writes at 2^30
    /// (E0828, #45); the sums saturate besides, so no spec can overflow
    /// them, and a saturated row is E1011's (`fits`).
    fn scratch(self: PrintArg) ?usize {
        const n: ?usize = switch (self.how) {
            .ascii => @sizeOf(i64),
            .pad => 24, // i64's widest decimal (20 chars) plus slack
            .cint => @max(24, self.spec.width +| 2), // the full zero-filled field
            // The widest `%f` body is a sign, f64's 309 integer digits, the
            // point and the precision; the field can be wider still.
            .creal => @max(self.spec.width, self.spec.p(6) +| 320) +| 8,
            else => null,
        };
        if (n) |bytes| assert(bytes > 0);
        return n;
    }

    /// Whether the scratch is a stack array (`max_stack`) or a static row,
    /// which the emitted block holds as a pointer.
    fn onStack(self: PrintArg) bool {
        // The widest scratch a field of `max_stack` width and precision
        // takes: `.creal`'s.
        const most = @max(Spec.max_stack, Spec.max_stack + 320) + 8;
        return (self.scratch() orelse 0) <= most;
    }

    /// How the emitted block names the scratch as a slice: `&zb<i>` for the
    /// stack array, `zb<i>` for the static row's pointer.
    fn amp(self: PrintArg) []const u8 {
        return if (self.onStack()) "&" else "";
    }

    /// The most bytes this operand renders, field padding included: the
    /// composed modes' scratch, a radix's 64 digits, f64's widest decimal, a
    /// string operand's capacity (`cg_strcap`).
    fn textMax(self: PrintArg, g: *Gen) Error!u64 {
        const body: u64 = switch (self.how) {
            .creal, .pad, .cint, .ascii => self.scratch().?,
            .bits => 64,
            .chr => 1,
            .plain => switch (self.want) {
                .int => 20,
                .real => std.fmt.float.bufferSize(.decimal, f64),
                .str => try strcap.cap(g, self.v),
                .wide => unreachable, // lowering hands a task no wide value: a whole wide `reg` read is E0222
            },
        };
        return @max(body, self.spec.width);
    }
};

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
        const i_before = i;
        if (g.strArg(args, i)) |s| {
            i += 1;
            i += try translateFormat(g, s, args[i..], fmt, ops);
        } else {
            try appendConv(g, fmt, ops, args[i], 0, .{});
            i += 1;
        }
        assert(i > i_before);
    }
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

/// One call's print operands, in format order.
pub const Ops = std.ArrayList(PrintArg);

/// The most operands one `std.fmt` call takes (`std.fmt.ArgSetType`'s bits).
/// A call with more is emitted as consecutive calls of at most this many.
const fmt_chunk = @typeInfo(std.fmt.ArgSetType).int.bits;
comptime {
    // The chunk loops advance by it.
    assert(fmt_chunk > 0);
}

/// The bytes call `site`'s text can need: the Zig format text (an upper
/// bound on its literal part) plus each operand's `textMax`, never below
/// `strcap.row`, the row every site had.
pub fn siteCap(g: *Gen, fmt: []const u8, ops: []const PrintArg) Error!u64 {
    var n: u64 = fmt.len;
    for (ops) |p| n +|= try p.textMax(g);
    const c = @max(n, strcap.row);
    assert(c >= strcap.row);
    return c;
}

/// Call `site`'s formatted-text row: `zSBuf` for the 4096-byte row, else a
/// row of `cap` bytes (`str_kernels.zSRow`, slot 0). Asserts that `cap` is
/// at least `strcap.row` (`siteCap`, `strcap.rtFormatCap`).
pub fn emitRow(g: *Gen, site: usize, cap: u64) Error!void {
    assert(cap >= strcap.row);
    if (cap == strcap.row or !try fits(g, site, cap)) return g.b("zSBuf({d})", .{site});
    return g.b("zSRow({d}, 0, {d})", .{ site, cap });
}

/// Whether a row of `cap` bytes at call `site` can exist: past
/// `strcap.max_row` it is more than a device can address, which is E1011
/// at compile time (memory, the one bound a row has).
fn fits(g: *Gen, site: usize, cap: u64) Error!bool {
    if (cap <= strcap.max_row) return true;
    if (g.diags) |bag| try bag.add(.codegen, .E1011, g.lowered.tokenSpan(g.mir.instTok(@fromBackingInt(@intCast(site)))), "the text here can need {d} bytes, more than a device can address", .{cap});
    g.poison("a string row is larger than a device can address");
    assert(g.any_fatal);
    return false;
}

/// `std.mem.print(row, fmt, .{ops})` into call `site`'s row, as a slice
/// expression; an overrun is E1011 (`zSOver`). Past `fmt_chunk` operands the
/// text goes through one fixed writer, a print per chunk.
fn emitBufPrint(g: *Gen, fmt: []const u8, ops: []const PrintArg, site: usize) Error!void {
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
        try g.b("zw.print(\"{f}\", .{{", .{std.zig.fmtString(chunkText(fmt, ops, k, end))});
        try renderPrintArgs(g, ops[k..end], k);
        try g.b("}}) catch zSOver(); ", .{});
    }
    try g.b("break :zw{d} zw.buffered(); }}", .{site});
}

/// `std.debug.print(fmt, .{ops})`, one print per `fmt_chunk` operands.
fn emitDebugPrint(g: *Gen, fmt: []const u8, ops: []const PrintArg) Error!void {
    var k: usize = 0;
    while (true) : (k += fmt_chunk) {
        // One print per chunk, and one for no operands at all.
        assert(k <= ops.len);
        const end = @min(k + fmt_chunk, ops.len);
        try g.b("std.debug.print(\"{f}\", .{{", .{std.zig.fmtString(chunkText(fmt, ops, k, end))});
        try renderPrintArgs(g, ops[k..end], k);
        try g.b("}}); ", .{});
        if (end == ops.len) return;
    }
}

/// The format text of operands `k..end`: from operand k's `{` (the call's
/// start for the first chunk) to the next chunk's (the end for the last).
fn chunkText(fmt: []const u8, ops: []const PrintArg, k: usize, end: usize) []const u8 {
    assert(k <= end);
    assert(end <= ops.len);
    const from = if (k == 0) 0 else ops[k].at;
    const to = if (end == ops.len) fmt.len else ops[end].at;
    assert(from <= to);
    return fmt[from..to];
}

/// The per-op scratch declarations of one emitted display block: a stack
/// array, or call `site`'s static row for operand i (`zSRow` slot i + 1) when
/// the field is wider than `Spec.max_stack`.
fn emitScratch(g: *Gen, ops: []const PrintArg, site: usize) Error!void {
    for (ops, 0..) |p, i| {
        const n = p.scratch() orelse continue;
        if (p.onStack())
            try g.b("var zb{d}: [{d}]u8 = undefined; ", .{ i, n })
        else
            try g.b("const zb{d} = zSRow({d}, {d}, {d}); ", .{ i, site, i + 1, if (try fits(g, site, n)) n else strcap.row });
    }
}

/// Operands `ops`, the first of which is the call's operand `first`.
fn renderPrintArgs(g: *Gen, ops: []const PrintArg, first: usize) Error!void {
    for (ops, first..) |p, i| {
        if (i != first) try g.b(", ", .{});
        try renderPrintArg(g, p, i);
    }
}

/// Emits one §9.4.1 display or §9.7.3 severity task as a labeled block that
/// prints to stderr (the transcript; stdout belongs to a host that pipes
/// data). `inst` keys `$monitor`'s scratch row. `$fatal` also halts.
pub fn emitDisplayTask(g: *Gen, c: Mir.Callee, args: []const Mir.Value, inst: Mir.Inst) Error!void {
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
    // `Lower.armMonitor` puts the site key first.
    if (mon) assert(args.len > 0);
    const body = if (mon or (c == .@"$fatal" and args.len > 0 and g.strArg(args, 0) == null))
        args[1..]
    else
        args;
    try buildArgs(g, body, &fmt, &ops);
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
    if (severityWord(c)) |word| try emitWhen(g, word, inst, if (c == .@"$fatal") finishLevel(g, args) else 1);
    if (mon) {
        // §9.4.1's mechanism: format into this site's scratch row, then report
        // only when a watched argument VALUE differs from the step this site
        // last reported (`monitorValues`). An overrun is `emitStringFormat`'s
        // E1011.
        try g.b("if (zMonitor({d}, ", .{monitorKey(g, args)});
        try monitorValues(g, ops.items);
        try g.b(", ", .{});
        try emitBufPrint(g, fmt.items, ops.items, site);
        try g.b(")) |zt| std.debug.print(\"{{s}}\", .{{zt}}); ", .{});
    } else try emitDebugPrint(g, fmt.items, ops.items);
    // §9.7.3: `$fatal` "terminates the simulation with an errorcode". The
    // finish_number "may be used in an implementation-specific manner"; here
    // it is the exit status, floored at 1 so a `$fatal` never reads as success
    // to a shell. `zHalt` is f64-typed so the dead code after it still
    // compiles; `break :zd` is statically reachable, never taken.
    if (c == .@"$fatal") {
        const lvl = finishLevel(g, args);
        try g.b("_ = zHalt({d}); ", .{std.math.clamp(lvl, 1, 255)});
    }
    try g.b("break :zd S.con(0.0); }}", .{});
}

// ------------------------------------------- §9.4 a device's display records ----
//
// A `.record` device cannot print, so its `say` (`dispatch.emitDisplay`)
// runs the display chain at an accepted point and appends one record per
// task to the host's `contract.Say`: the site's index and its numeric
// values. The site's text is fixed here, once, as one C-style format
// (`contract.SaySite.fmt`) the host renders with `contract.formatSay`.

/// One display task a device's `say` records (`contract.SaySite`).
pub const SaySite = struct {
    /// The task's `call`, as `Analysis.rv` names it.
    call: Mir.Value,
    /// The C-style format its arguments make (`sayFormat`).
    fmt: []const u8,
    tok: u32,
    /// The arguments a record carries, in format order.
    vals: []const Mir.Value,
    /// §9.4.1 `$debug`, shown per iteration (`contract.Say.putDebug`).
    debug: bool = false,
};

/// The display tasks a `.record` device records, in source order
/// (`Lowered.displays`): the §9.4.1 printing tasks and `$warning`/`$info`.
/// Not `$monitor` (its §9.4.1 change detection is state a device does not
/// keep) nor `$fatal`/`$error` (the status channel, `contract.StatusSite`);
/// root.zig reports those, and the §9.5/§9.7 tasks, as W0850. A task whose
/// value has no numeric record (a string that is not a constant, a number
/// under `%s`) is W0850 here.
pub fn planSay(g: *Gen) Error![]const SaySite {
    var out: std.ArrayList(SaySite) = .empty;
    for (g.lowered.displays.items) |d| {
        const c: Mir.Callee = .fromName(d.name);
        if (!sayRecords(c)) continue;
        const call = g.an.rv(d.val);
        const def = g.mir.valueDef(call);
        if (def != .inst_result) continue;
        var fmt: std.ArrayList(u8) = .empty;
        var vals: std.ArrayList(Mir.Value) = .empty;
        // §9.7.3: the severity is the message's reason for existing.
        if (severityWord(c)) |word| {
            try fmt.appendSlice(g.arena, word);
            try fmt.appendSlice(g.arena, ": ");
        }
        if (!try sayFormat(g, g.mir.instData(def.inst_result).call.args, &fmt, &vals)) {
            if (g.diags) |bag| try bag.add(.codegen, .W0850, g.lowered.tokenSpan(d.tok), "`{s}` — a device records numbers, and a string here is not a constant", .{d.name});
            continue;
        }
        // §9.4.1: `$write` is the family member that does NOT end the line.
        if (endsLine(c)) try fmt.append(g.arena, '\n');
        try out.append(g.arena, .{ .call = call, .fmt = fmt.items, .tok = d.tok, .vals = vals.items, .debug = c == .@"$debug" });
    }
    assert(out.items.len <= g.lowered.displays.items.len);
    return out.items;
}

/// §9.4.1/§9.5.9 sets `g.passes` when a printing artifact's display unit has
/// a task that shows output at every iteration of the solver, `$debug` or
/// `$fdebug`, and collects the calls an `analog initial` block makes into
/// `g.init_calls` (`callee.isFileCall`'s through `Lower.sequenceFileCall`'s
/// `$itor` carrier). Such a unit takes a `comptime pass: contract.SayPass`
/// and gates each call on it (`gen_call.gateOpen`).
pub fn planPasses(g: *Gen) Error!void {
    var init: std.ArrayList(Mir.Inst) = .empty;
    for (g.lowered.displays.items) |d| {
        const c: Mir.Callee = .fromName(d.name);
        // §5.10.2/§9.7: `$finish`/`$stop` also need the pass gate, so the
        // tasks after either of them in the same chain do not run (the halt
        // itself happens in the display wrapper's `zFinishPass`).
        if (c == .@"$debug" or c == .@"$fdebug" or c == .@"$finish" or c == .@"$stop") g.passes = true;
        if (!d.analog_initial or d.val == .undef) continue;
        var def = g.mir.valueDef(g.an.rv(d.val));
        if (def != .inst_result) continue;
        const data = g.mir.instData(def.inst_result);
        if (data == .call and data.call.callee == .@"$itor" and data.call.args.len == 1) {
            def = g.mir.valueDef(g.an.rv(data.call.args[0]));
            if (def != .inst_result) continue;
        }
        try init.append(g.arena, def.inst_result);
    }
    assert(init.items.len <= g.lowered.displays.items.len);
    g.init_calls = init.items;
}

/// Whether a `.record` device records task `c` (`planSay`).
pub fn sayRecords(c: Mir.Callee) bool {
    return Mir.callee.family(c) == .display and switch (c) {
        .@"$monitor", .@"$fatal", .@"$error" => false,
        else => true, // else: every other §9.4.1/§9.7.3 printing task is a plain text record
    };
}

/// §9.4.1's argument-list model (`buildArgs`) as one C-style format over
/// recorded numbers: each string argument is a format whose conversions take
/// the arguments after it, a constant string under `%s` spliced in as text
/// and `%l` as the module name (what the printing artifact writes); an
/// argument no format took is `%d` (integer) or `%g`, and a bare `%d` gets
/// the printing artifact's automatic field (`decimalField`). Appends the recorded
/// arguments to `vals`. False when one has no numeric record: a string that
/// is not a constant, or a number under `%s` (§9.4.5's bytes).
fn sayFormat(g: *Gen, args: []const Mir.Value, fmt: *std.ArrayList(u8), vals: *std.ArrayList(Mir.Value)) Error!bool {
    const vals_before = vals.items.len;
    var i: usize = 0;
    while (i < args.len) {
        const s = g.strArg(args, i) orelse {
            if (g.an.tyOf(args[i]) == .str) return false;
            if (g.an.tyOf(args[i]) == .int) try sayDecimal(g, fmt, args[i]) else try fmt.appendSlice(g.arena, "%g");
            try vals.append(g.arena, args[i]);
            i += 1;
            continue;
        };
        i += 1;
        var j: usize = 0;
        while (j < s.len) : (j += 1) {
            if (s[j] != '%' or j + 1 == s.len) {
                try fmt.append(g.arena, s[j]);
                continue;
            }
            const start = j;
            j += 1;
            while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == '.' or str_k.zcFlag(s[j]) != null)) j += 1;
            if (j == s.len) {
                try fmt.appendSlice(g.arena, s[start..]);
                break;
            }
            const conv = std.ascii.toLower(s[j]);
            if (conv == '%' or conv == 'm') {
                try fmt.appendSlice(g.arena, s[start .. j + 1]);
                continue;
            }
            if (conv == 'l') {
                // Table 9-22's library.cell, as `translateFormat` prints it.
                try appendLiteral(g, fmt, "work.");
                try appendLiteral(g, fmt, g.mir.name);
                continue;
            }
            // A conversion with no operand renders 0, the printing
            // artifact's answer (§9.4.3 pairing is E0810 at lowering).
            if (i == args.len) {
                try fmt.appendSlice(g.arena, s[start .. j + 1]);
                continue;
            }
            const a = args[i];
            i += 1;
            if (conv == 's') {
                const text = g.strArg(args, i - 1) orelse return false;
                try appendLiteral(g, fmt, text);
                continue;
            }
            // A number, or §2.7 a string literal's integer.
            if (g.an.tyOf(a) == .str and g.strArg(args, i - 1) == null) return false;
            if (conv == 'd' and j == start + 1) try sayDecimal(g, fmt, a) else try fmt.appendSlice(g.arena, s[start .. j + 1]);
            try vals.append(g.arena, a);
        }
    }
    assert(i == args.len);
    assert(vals.items.len - vals_before <= args.len);
    return true;
}

/// `%d` with `v`'s automatic field (`decimalField`), `%11d` for an `integer`.
fn sayDecimal(g: *Gen, fmt: *std.ArrayList(u8), v: Mir.Value) Error!void {
    const cols = decimalField(g, v) orelse return fmt.appendSlice(g.arena, "%d");
    var buf: [8]u8 = undefined;
    try fmt.appendSlice(g.arena, std.mem.print(&buf, "%{d}d", .{cols}) catch unreachable);
}

/// `text` into a format as itself: each `%` doubled.
fn appendLiteral(g: *Gen, fmt: *std.ArrayList(u8), text: []const u8) Error!void {
    const len_before = fmt.items.len;
    for (text) |ch| {
        if (ch == '%') try fmt.append(g.arena, '%');
        try fmt.append(g.arena, ch);
    }
    assert(fmt.items.len >= len_before + text.len);
}

/// Emits a `.record` display unit's task (`planSay`) as a labeled block that
/// appends its record to the host's `out`, each value as an f64. A task
/// `planSay` did not keep renders void.
pub fn emitSay(g: *Gen, inst: Mir.Inst) Error!void {
    const call = g.an.rv(g.mir.instResult(inst));
    const k = for (g.say, 0..) |site, j| {
        if (site.call == call) break j;
    } else return g.b("S.con(0.0)", .{});
    g.uses.out = true;
    try g.b("zd: {{ out.{s}({d}, &.{{", .{ if (g.say[k].debug) "putDebug" else "put", k });
    for (g.say[k].vals, 0..) |v, i| {
        try g.b("{s}", .{if (i == 0) " " else ", "});
        if (g.an.tyOf(v) == .real) {
            try g.b("(", .{});
            try g.renderVal(v, .real);
            try g.b(").val()", .{});
        } else {
            try g.b("@as(f64, @floatFromInt(", .{});
            try g.renderVal(v, .int);
            try g.b("))", .{});
        }
    }
    try g.b(" }}); break :zd S.con(0.0); }}", .{});
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
    const level = finishLevel(g, args);
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
}

/// Emits a diagnostic's opening, `task: ` then the moment it reports, with no
/// newline. §9.7.1/§9.7.3: a task in an `analog initial` block reports "that
/// the call was made during initialization" in place of the time; every other
/// one reports the simulation time, or the host's dc sweep point, through
/// `zWhen` at `sim.t`, which also prints Table 9-25 `level` 2's statistics.
fn emitWhen(g: *Gen, task: []const u8, inst: Mir.Inst, level: i64) Error!void {
    if (std.mem.findScalar(Mir.Inst, g.init_calls, inst) != null)
        return g.b("std.debug.print(\"{s}: initialization\", .{{}}); ", .{task});
    g.uses.sim = true;
    try g.b("std.debug.print(\"{s}: \", .{{}}); zWhen(sim.t, {d}); ", .{ task, std.math.clamp(level, 0, 2) });
}

/// Emits §9.5.3 `$swrite`/`$sformat` ("the same as their counterparts ...
/// except that ... the resulting string shall be written"): `emitDisplayTask`'s
/// translation into call site `site`'s scratch row, with no newline. The
/// block's value is the formatted string. §3.3 removes NUL bytes only after
/// formatting, so field widths count the original bytes.
pub fn emitStringFormat(g: *Gen, args: []const Mir.Value, site: usize) Error!void {
    var fmt: std.ArrayList(u8) = .empty;
    var ops: Ops = .empty;
    try buildArgs(g, args, &fmt, &ops);
    try g.b("zs: {{ ", .{});
    try emitScratch(g, ops.items, site);
    // An overrun ends the run with E1011 (`zSOver`): §9.5.3 states no
    // truncation rule, and an empty or half string is a wrong answer. The
    // row is sized for every operand (`siteCap`), so only a run-time string
    // longer than the compiler could know can overrun it.
    try g.b("break :zs zStringStore(", .{});
    try emitBufPrint(g, fmt.items, ops.items, site);
    try g.b("); }}", .{});
}

/// Emits §9.5.3 `$sformat` whose format_string is a string VARIABLE ("whose
/// content is interpreted as the format string"): `args[0]` is the format,
/// the rest its operands, each passed in its own type to
/// `str_kernels.zSFormatRt`, which walks the format at run time. `%m` prints
/// what `translateFormat` prints for it.
pub fn emitStringFormatRt(g: *Gen, args: []const Mir.Value, site: usize) Error!void {
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
}

// ------------------------------------------------------- §9.5 file I/O ----
//
// §9.5.2 defines its five output tasks as the §9.4.1 ones "with one additional
// argument, which is either a multichannel descriptor or a file descriptor", so
// they share this formatter. The descriptor operations have no text but are
// sequenced in the same unit (`codegen.Gen.emitting_display`).

/// Emits one §9.5 call in the display unit. `site` is the call's MIR
/// instruction id, the per-call-site key for its formatted bytes (`zSBuf`).
/// Aborts codegen for a callee `codegen.isFileCall` does not route here.
pub fn emitFileCall(g: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    // §9.5.1/§9.5.2/§9.5.6: `$fclose`, `$fflush` and the five output tasks are
    // tasks, so `Mir.callee.ty` types them real like every void call, but the
    // kernels return integers. The cast lives here because the value only
    // gives the display chain something to carry (`Lower.sequenceFileCall`).
    const wrap = Mir.callee.ty(c) == .real;
    // `$fscanf$real` is the one real-typed §9.5 call whose kernel (`zScanR`)
    // already returns f64, so it takes no `@floatFromInt`.
    const from_int = c != .@"$fscanf$real";
    // An integer result is latched for the other units (`file_kernels.zFRes`).
    const keep = Mir.callee.ty(c) == .int;
    if (wrap) try g.b("S.con(", .{});
    if (wrap and from_int) try g.b("@as(f64, @floatFromInt(", .{});
    if (keep) try g.b("zFKeep({d}, ", .{site});
    // §9.5.4.1/§9.5.4.2 a read's line is copied when the read runs, so its
    // readers see it however late codegen places them (`zFLatch`).
    const latch = c == .@"$fgets" or c == .@"$fscanf";
    if (latch) try g.b("zFLatch({d}, ", .{site});
    try emitFileCallInner(g, c, args, site);
    if (latch) {
        try g.b(", ", .{});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        try g.b(")", .{});
    }
    if (keep) try g.b(")", .{});
    if (wrap and from_int) try g.b("))", .{});
    if (wrap) try g.b(")", .{});
}

fn emitFileCallInner(g: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    switch (c) {
        // §9.5.2's five output tasks, and the two descriptor tasks that take no
        // text (`callee.zig`'s `.file_out` family).
        .@"$fdisplay",
        .@"$fwrite",
        .@"$fstrobe",
        .@"$fmonitor",
        .@"$fdebug",
        .@"$fclose",
        .@"$fflush",
        => return emitFileWrite(g, c, args, site),
        // §9.5.1 Syntax 9-2: one argument is a multichannel descriptor, two are a
        // file descriptor. The presence of the type argument IS the discriminator,
        // and it is the only thing that decides which encoding comes back.
        .@"$fopen" => {
            try g.b("zFOpen(", .{});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.f_zero, .str);
            try g.b(", ", .{});
            if (args.len > 1) try g.renderVal(args[1], .str) else try g.b("\"\"", .{});
            return g.b(", {s})", .{if (args.len > 1) "false" else "true"});
        },
        // The one-argument descriptor operations, in clause order.
        .@"$fgets", .@"$ftell", .@"$feof", .@"$ferror" => {
            try g.b("{s}(", .{switch (c) {
                .@"$fgets" => "zFGets", // §9.5.4.1: the character count
                .@"$ftell" => "zFTell", // §9.5.5
                .@"$feof" => "zFEof", // §9.5.8
                else => "zFError", // else: `$ferror`, the one left (§9.5.7) — the errno
            }});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
            return g.b(")", .{});
        },
        // §9.5.5 `$rewind(fd)` "is equivalent to $fseek (fd,0,0)": the clause's own
        // words, so it is the same kernel with the constants written in.
        .@"$rewind" => {
            try g.b("zFSeek(", .{});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
            return g.b(", 0, 0)", .{});
        },
        .@"$fseek" => {
            try g.b("zFSeek(", .{});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 1) args[1] else Mir.Value.zero, .int);
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 2) args[2] else Mir.Value.zero, .int);
            return g.b(")", .{});
        },
        // §9.5.4.2 the count. Composed here because `file_kernels.zig` cannot
        // call `str_kernels.zScan` (each kernel file compiles alone). Scan the
        // unread window, widened until the scan stops inside it, then consume
        // exactly `zScan.used`: "the offending input character is left
        // unread". Operands are (fd, format); the item readers below re-scan
        // the window `zFTake` leaves latched.
        .@"$fscanf" => {
            const fd = if (args.len > 0) args[0] else Mir.Value.zero;
            try g.b("zk{d}: while (true) {{ const zw = zFWindow(", .{site});
            try g.renderVal(fd, .int);
            try g.b("); const zr = zScan(zw, ", .{});
            try g.renderVal(if (args.len > 1) args[1] else Mir.Value.f_zero, .str);
            // A scan that read to the end of a full window runs again over a
            // wider one (`file_kernels.zFMore`).
            try g.b(", -1); if (zFMore(", .{});
            try g.renderVal(fd, .int);
            try g.b(", zr.used)) continue; break :zk{d} zFTake(", .{site});
            try g.renderVal(fd, .int);
            return g.b(", zr.n, @intCast(zr.used)); }}", .{});
        },
        // The synthetic readers, all of which take the count first; see
        // `file_kernels.zFLine` for why that operand is there and why it is read.
        .@"$fgets$str" => return emitReadLine(g, args),
        .@"$ferror$str" => return emitLine(g, args, "zFErrorStr"),
        // §9.5.4.2's items: the same three flavours `$sscanf` has, over the line the
        // count's read latched. `(count, fd, format, item)`.
        .@"$fscanf$int", .@"$fscanf$real", .@"$fscanf$str" => {
            try g.b("{s}(", .{switch (c) {
                .@"$fscanf$int" => "zScanI",
                .@"$fscanf$real" => "zScanR",
                else => "zScanS", // else: `$fscanf$str`, the one left
            }});
            try emitReadLine(g, args);
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 2) args[2] else Mir.Value.f_zero, .str);
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 3) args[3] else Mir.Value.zero, .int);
            return g.b(")", .{});
        },
        else => return g.abort(.E1020, "VerA: unhandled §9.5 call `{s}`", .{@tagName(c)}), // else: `emitCall` routes only `callee.isFileCall` here, and every one of those has a prong above
    }
}
/// The line a `$fgets`/`$fscanf` reader reads: its count's site latch
/// (`zFLineAt`), so the value is the one the read statement left. A count that
/// is not a direct read call (no site to name) reads the channel (`zFLine`).
fn emitReadLine(g: *Gen, args: []const Mir.Value) Error!void {
    const n = if (args.len > 0) args[0] else Mir.Value.zero;
    const def = g.mir.valueDef(g.an.rv(n));
    if (def == .inst_result and g.mir.instOp(def.inst_result) == .call) {
        const callee = g.mir.instData(def.inst_result).call.callee;
        if (callee == .@"$fgets" or callee == .@"$fscanf") {
            try g.b("zFLineAt({d}, ", .{@backingInt(def.inst_result)});
            try g.renderVal(n, .int);
            return g.b(")", .{});
        }
    }
    return emitLine(g, args, "zFLine");
}

/// The first two operands every synthetic reader carries: count, then fd.
inline fn emitLine(g: *Gen, args: []const Mir.Value, comptime kernel: []const u8) Error!void {
    try g.b(kernel ++ "(", .{});
    try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
    try g.b(", ", .{});
    try g.renderVal(if (args.len > 1) args[1] else Mir.Value.zero, .int);
    try g.b(")", .{});
}

/// §9.5.2's five output tasks, plus `$fclose`/`$fflush`. The descriptor is
/// `args[0]`; the rest is formatted as the §9.4.1 task of the same base name
/// (`$fwrite`, like `$write`, does not end the line). Syntax 9-3 has no
/// radix-suffixed spelling, so the default conversion is the operand's own.
fn emitFileWrite(g: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    // §9.5.1 `$fclose` and §9.5.6 `$fflush` take a descriptor and no text.
    if (c == .@"$fclose" or c == .@"$fflush") {
        try g.b("{s}(", .{if (c == .@"$fclose") "zFClose" else "zFFlush"});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        return g.b(")", .{});
    }
    // §9.4.1 a monitor report carries its site key ahead of the descriptor.
    const mon = c == .@"$fmonitor";
    if (mon) assert(args.len > 0);
    const all = if (mon) args[1..] else args;
    const rest = if (all.len > 0) all[1..] else all;
    var fmt: std.ArrayList(u8) = .empty;
    var ops: Ops = .empty;
    try buildArgs(g, rest, &fmt, &ops);
    // The §9.4.1 task §9.5.2 names this one after decides the newline:
    // `$write` is the member that does not end the line, and so is `$fwrite`.
    if (endsLine(c)) try fmt.append(g.arena, '\n');

    // The text is formatted into this call site's own scratch row and then
    // written, which is `emitStringFormat`'s sink with a descriptor instead of a
    // string variable. An overrun is E1011, as for §9.5.3.
    try g.b("zf: {{ ", .{});
    try emitScratch(g, ops.items, site);
    // §9.5.2 makes `$fmonitor` "just like" `$monitor` with a descriptor in
    // front, so §9.4.1's change condition travels with it: the record is
    // composed either way, and `zMonitor` decides whether it is written.
    if (mon) try g.b("const zt = ", .{}) else try g.b("break :zf zFPut(", .{});
    if (!mon) {
        try g.renderVal(if (all.len > 0) all[0] else Mir.Value.zero, .int);
        try g.b(", ", .{});
    }
    try emitBufPrint(g, fmt.items, ops.items, site);
    if (mon) {
        try g.b("; break :zf if (zMonitor({d}, ", .{monitorKey(g, args)});
        try monitorValues(g, ops.items);
        try g.b(", zt)) |zm| zFPut(", .{});
        try g.renderVal(if (all.len > 0) all[0] else Mir.Value.zero, .int);
        try g.b(", zm) else 0; }}", .{});
    } else try g.b("); }}", .{});
}

/// §9.4.1 what a monitor watches: one u64 per argument (a real's or integer's
/// bit pattern, a string's hash) for `zMonitor` to compare with the last
/// reported step. `$abstime` and `$realtime` are left out, "with the exception
/// of the $abstime or $realtime system functions".
fn monitorValues(g: *Gen, ops: []const PrintArg) Error!void {
    try g.b("&[_]u64{{", .{});
    var first = true;
    for (ops) |p| {
        const v = g.an.rv(p.v);
        const def = g.mir.valueDef(v);
        if (def == .inst_result and g.mir.instOp(def.inst_result) == .call) {
            const callee = g.mir.instData(def.inst_result).call.callee;
            if (callee == .@"$abstime" or callee == .@"$realtime") continue;
        }
        if (first) try g.b(" ", .{}) else try g.b(", ", .{});
        first = false;
        switch (g.an.tyOf(v)) {
            .real => {
                try g.b("@as(u64, @bitCast((", .{});
                try g.renderVal(v, .real);
                try g.b(").val()))", .{});
            },
            .int => {
                try g.b("@as(u64, @bitCast(@as(i64, ", .{});
                try g.renderVal(v, .int);
                try g.b(")))", .{});
            },
            .str => {
                try g.b("std.hash.Wyhash.hash(0, ", .{});
                try g.renderVal(v, .str);
                try g.b(")", .{});
            },
            .wide => unreachable, // lowering hands a task no wide value: a whole wide `reg` read is E0222
        }
    }
    if (first) try g.b("}}", .{}) else try g.b(" }}", .{});
}

/// The site key `Lower.armMonitor` put first in a monitor's registration and
/// report: a literal, so it can key a comptime latch.
fn monitorKey(g: *const Gen, args: []const Mir.Value) i64 {
    assert(args.len > 0);
    const def = g.mir.valueDef(g.an.rv(args[0]));
    assert(def == .int_const);
    return def.int_const;
}

/// Emits §9.4.1's registration half: arms the monitor latch of the site keyed
/// by `args[0]` (`str_kernels.zMonitorArm`).
pub fn emitMonitorArm(g: *Gen, args: []const Mir.Value) Error!void {
    return g.b("S.con(zMonitorArm({d}))", .{monitorKey(g, args)});
}

/// Returns the §9.7.3 severity prefix of `c`, or null for every other task.
fn severityWord(c: Mir.Callee) ?[]const u8 {
    return switch (c) {
        .@"$fatal" => "FATAL",
        .@"$error" => "ERROR",
        .@"$warning" => "WARNING",
        .@"$info" => "INFO",
        else => null, // else: §9.7.3 has exactly these four; every other task prints no severity
    };
}

/// §9.4.1: does the task end its line? `$write` and its radix forms are the
/// members that do not, and §9.5.2's `$fwrite` is named after `$write`.
fn endsLine(c: Mir.Callee) bool {
    return switch (c) {
        .@"$write", .@"$writeb", .@"$writeo", .@"$writeh", .@"$fwrite" => false,
        else => true, // else: every other §9.4.1/§9.5.2 printing task is a `$display`-like one
    };
}

/// Translates one §9.4.2/§9.4.3 format string into `std.fmt` text appended to
/// `fmt` (literal `{`/`}` doubled), appending one `PrintArg` per conversion.
/// Returns how many of `operands` were consumed, so the §9.4.1 walk resumes
/// after them. A conversion with no operand renders 0.0; §9.4.3 makes that a
/// pairing violation, which `Lower.checkFormatPairing` diagnoses.
fn translateFormat(
    g: *Gen,
    src: []const u8,
    operands: []const Mir.Value,
    fmt: *std.ArrayList(u8),
    ops: *Ops,
) Error!usize {
    const a = g.arena;
    var next: usize = 0;
    var i: usize = 0;
    var steps: usize = 0;
    while (i < src.len) : (steps += 1) {
        // Every pass consumes at least one byte of `src`.
        assert(steps <= i);
        assert(steps < src.len);
        const c = src[i];
        if (c == '{' or c == '}') { // std.fmt's own escape
            try fmt.append(a, c);
            try fmt.append(a, c);
            i += 1;
            continue;
        }
        if (c != '%') {
            try fmt.append(a, c);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= src.len) break;
        if (src[i] == '%') { // §9.4.3 `%%` is a literal percent
            try fmt.append(a, '%');
            i += 1;
            continue;
        }
        // §9.4.3 `%[flags][width][.precision]conv`: the C prefix Table 9-23
        // grants. Parsed into numbers here; `appendConv` decides per
        // conversion whether Zig can spell it or a composed field is needed.
        var spec: Spec = .{};
        while (i < src.len) : (i += 1) switch (str_k.zcFlag(src[i]) orelse break) {
            str_k.zc_left => spec.left = true,
            str_k.zc_plus => spec.plus = true,
            str_k.zc_space => spec.space = true,
            str_k.zc_zero => spec.zero = true,
            str_k.zc_alt => spec.alt = true,
            else => unreachable, // `zcFlag` returns one of the five bits
        };
        const width_at = i;
        while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
        // An overflow saturates; lowering has refused any field past 2^30
        // (E0828), so only a format it never judged could reach that.
        if (i > width_at)
            spec.width = std.fmt.parseUnsigned(usize, src[width_at..i], 10) catch std.math.maxInt(usize);
        if (i < src.len and src[i] == '.') {
            i += 1;
            const prec_at = i;
            while (i < src.len and src[i] >= '0' and src[i] <= '9') : (i += 1) {}
            spec.prec = std.fmt.parseUnsigned(usize, src[prec_at..i], 10) catch std.math.maxInt(usize);
        }
        if (i >= src.len) break;
        const conv = src[i];
        i += 1;
        // §9.4.2's `%%` is two characters; lowering refuses a flag, width or
        // precision before the second `%` (E0826, #42), so none reaches here
        // to be taken for a consuming conversion.
        assert(conv != '%');
        // §9.4.3 `%m` names the enclosing module, and `%l` consumes no operand
        // either: "for each % character (except %m, %% and %l) … a
        // corresponding expression argument shall be supplied".
        if (conv == 'm' or conv == 'M') {
            try fmt.appendSlice(a, g.mir.name);
            continue;
        }
        // Table 9-22's `%l` is "library.cell". A Verilog-A source takes no
        // library map (`vera --libmap` configures a .v design), and IEEE
        // 1364-2005 §13.2.1 compiles a file no map matches "into a library
        // named work"; the cell is the module, as `%m` names it. The digital
        // runner prints the same shape (`work.top`).
        if (conv == 'l' or conv == 'L') {
            try fmt.appendSlice(a, "work.");
            try fmt.appendSlice(a, g.mir.name);
            continue;
        }
        const operand = if (next < operands.len) operands[next] else Mir.Value.f_zero;
        next += 1;
        try appendConv(g, fmt, ops, operand, conv, spec);
    }
    return @min(next, operands.len);
}

/// The Zig `:[fill][align][width][.precision]` tail, for the conversions whose
/// C and Zig renderings agree (radix on an unsigned, `%f`, `%g`, `%s`, `%c`).
/// Emits nothing when the source gave nothing. `extra_prec` is `%f`'s C
/// default of six decimals, applied only when the source did not say
/// otherwise.
fn appendZigSpec(g: *Gen, fmt: *std.ArrayList(u8), spec: Spec, extra_prec: ?[]const u8) Error!void {
    const a = g.arena;
    if (spec.width == 0 and spec.prec == null and extra_prec == null) return;
    var buf: [48]u8 = undefined;
    // `.{d}` of any usize fits, so the prints below cannot fail.
    comptime assert(buf.len >= std.math.log10_int(@as(usize, std.math.maxInt(usize))) + 2);
    try fmt.append(a, ':');
    if (spec.width > 0) {
        // Zig's fill/alignment are only meaningful WITH a width.
        if (spec.zero) try fmt.append(a, '0');
        try fmt.append(a, if (spec.left) '<' else '>');
        try fmt.appendSlice(a, std.mem.print(&buf, "{d}", .{spec.width}) catch unreachable);
    }
    if (spec.prec) |p| {
        try fmt.appendSlice(a, std.mem.print(&buf, ".{d}", .{p}) catch unreachable);
    } else if (extra_prec) |p| {
        try fmt.appendSlice(a, p);
    }
}

/// `{s}` with the outer alignment, for a field composed in per-op scratch
/// (`.cint`, `.pad`, `.ascii`). `full` marks a field already exactly its width
/// (a zero-filled integer), which no outer alignment may touch.
fn appendStrField(g: *Gen, fmt: *std.ArrayList(u8), spec: Spec, full: bool) Error!void {
    const a = g.arena;
    if (full or spec.width == 0) return fmt.appendSlice(a, "{s}");
    var buf: [48]u8 = undefined;
    // `{s:<W}` of any usize W fits.
    comptime assert(buf.len >= std.math.log10_int(@as(usize, std.math.maxInt(usize))) + 1 + 5);
    try fmt.appendSlice(a, std.mem.print(&buf, "{{s:{c}{d}}}", .{
        @as(u8, if (spec.left) '<' else '>'), spec.width,
    }) catch unreachable);
}

/// The width lowering recorded on a display operand (`$display$width`,
/// analog/systask.zig): `bits`, and whether the operand is signed, which
/// only a `%d` record states (a radix shows the bit pattern either way).
const WidthRecord = struct { bits: u7, signed: bool };

fn widthRecord(g: *Gen, v: Mir.Value) ?WidthRecord {
    const def = g.mir.valueDef(g.an.rv(v));
    if (def != .inst_result) return null;
    const data = g.mir.instData(def.inst_result);
    if (data != .call or data.call.callee != .@"$display$width") return null;
    // (value, width) for a radix or `%s`, (value, width, signed) for `%d`.
    const args = data.call.args;
    assert(args.len == 2 or args.len == 3);
    const bits = g.mir.valueDef(args[1]).int_const;
    assert(bits >= 1 and bits <= 64);
    return .{ .bits = @intCast(bits), .signed = args.len == 3 and g.mir.valueDef(args[2]).int_const != 0 };
}

/// IEEE 1364 §17.1.1.3's automatic decimal field for `%d` (and §9.4.3's
/// bare default) of `v`: the columns of the largest value it can hold, its
/// sign included, so a 32-bit `integer` is 11 ("-2147483648"), as the
/// digital engine prints it (`kernels/fmt.zig` `autoWidth`). Lowering
/// records an integer operand's width and sign (`systask.decimalWidth`); a
/// real is the 64-bit signed integer it converts to, 20 columns
/// (docs/specification/Vague_Decisions.md VD-120). Null for an integer with no
/// record (a 1-bit result, or a sink lowering does not size), a string
/// operand (§2.7's integer has no fixed width) and a one-column field.
fn decimalField(g: *Gen, v: Mir.Value) ?usize {
    const r: WidthRecord = switch (g.an.tyOf(g.an.rv(v))) {
        .int => widthRecord(g, v) orelse return null,
        .real => .{ .bits = 64, .signed = true },
        .str, .wide => return null,
    };
    const cols = fieldCols(r);
    return if (cols > 1) cols else null;
}

/// The decimal columns of record `r`'s largest value: 2^bits - 1 unsigned,
/// -2^(bits-1) signed (its magnitude's digits plus the sign).
fn fieldCols(r: WidthRecord) usize {
    assert(r.bits >= 1 and r.bits <= 64);
    const most: u64 = if (r.signed) @as(u64, 1) << @intCast(r.bits - 1) else @as(u64, std.math.maxInt(u64)) >> @intCast(@as(u8, 64) - r.bits);
    const cols = std.math.log10_int(most) + 1 + @intFromBool(r.signed);
    assert(cols <= 20);
    return cols;
}

test fieldCols {
    // Against the largest values written out by hand.
    const cases = [_]struct { r: WidthRecord, cols: usize }{
        .{ .r = .{ .bits = 32, .signed = true }, .cols = 11 }, // -2147483648
        .{ .r = .{ .bits = 64, .signed = true }, .cols = 20 }, // -9223372036854775808
        .{ .r = .{ .bits = 12, .signed = false }, .cols = 4 }, // 4095
        .{ .r = .{ .bits = 64, .signed = false }, .cols = 20 }, // 18446744073709551615
        .{ .r = .{ .bits = 8, .signed = true }, .cols = 4 }, // -128
        .{ .r = .{ .bits = 1, .signed = false }, .cols = 1 }, // 1
    };
    for (cases) |c| try std.testing.expectEqual(c.cols, fieldCols(c.r));
}

/// Appends one conversion's `{…}` to `fmt` and its operand to `ops`.
/// `conv_raw == 0` means the §9.4.3 default: the operand's natural form.
fn appendConv(
    g: *Gen,
    fmt: *std.ArrayList(u8),
    ops: *Ops,
    operand: Mir.Value,
    conv_raw: u8,
    spec_arg: Spec,
) Error!void {
    const a = g.arena;
    const v = operand;
    const rec = widthRecord(g, v);
    const bits: u7 = if (rec) |r| r.bits else 64;
    const conv = std.ascii.toLower(conv_raw);
    const ty = g.an.tyOf(g.an.rv(v));
    // §9.4.3 a bare operand is "the default decimal format", `%d`'s field.
    if (conv == 0 and ty == .int) return appendConv(g, fmt, ops, operand, 'd', spec_arg);
    // IEEE 1364 §17.1.1.3 automatic sizing: the radices "always" show leading
    // zeros at a width lowering recorded, a decimal field pads with spaces to
    // the largest value's columns (`decimalField`), and `%0h`/`%0d` (the '0'
    // flag with no width) "overrides" both.
    var spec = spec_arg;
    if (spec.width == 0 and !spec.zero and !spec.left and !spec.plus and !spec.space) switch (conv) {
        'h', 'x' => if (rec != null) {
            spec = .{ .width = (@as(usize, bits) + 3) / 4, .zero = true };
        },
        'o' => if (rec != null) {
            spec = .{ .width = (@as(usize, bits) + 2) / 3, .zero = true };
        },
        'b' => if (rec != null) {
            spec = .{ .width = bits, .zero = true };
        },
        'd' => if (decimalField(g, v)) |cols| {
            spec = .{ .width = cols };
        },
        else => {},
    };
    const at = fmt.items.len;
    const ops_before = ops.items.len;
    switch (conv) {
        // §9.4.3 Table 9-23's four real conversions "have the full formatting
        // capabilities available in the C language"; `%r` adds §2.6.2's
        // engineering notation. One kernel composes the whole field. An
        // integer operand converts to real first (§4.2.1.1).
        'e', 'f', 'g', 'r' => {
            try fmt.appendSlice(a, "{s}");
            try ops.append(a, .{ .at = at, .v = v, .want = .real, .how = .creal, .spec = spec, .conv = conv_raw });
        },
        // §9.4.3 Table 9-22: a radix conversion shows the operand's
        // two's-complement bit pattern at its width (IEEE 1364 §17.1.1.2):
        // the width lowering recorded (`systask.intSize`, 32 for an `integer`
        // or an unsized literal, §3.2), so `%h` of integer -5 is fffffffb, and
        // an operand with no record its minimal digits. `.bits` bitcasts to u64
        // because Zig's `{x}` on an i64 writes `-2a`. A real rounds first
        // (§4.2.1.1). An unsigned field has no sign, so the spec passes through.
        'b', 'o', 'h', 'x' => {
            try fmt.append(a, '{');
            try fmt.append(a, if (conv == 'h') 'x' else conv);
            try appendZigSpec(g, fmt, spec, null);
            try fmt.append(a, '}');
            try ops.append(a, .{ .at = at, .v = v, .want = .int, .how = .bits, .spec = spec, .bits = bits });
        },
        // Table 9-22 gives %c the single character: the operand's low byte,
        // whatever its type (a string goes through its §2.7 integer value).
        'c' => {
            try fmt.appendSlice(a, "{c");
            try appendZigSpec(g, fmt, spec, null);
            try fmt.append(a, '}');
            try ops.append(a, .{ .at = at, .v = v, .want = .int, .how = .chr, .spec = spec });
        },
        's' => {
            if (ty == .int) {
                try appendStrField(g, fmt, spec, false);
            } else {
                try fmt.appendSlice(a, "{s");
                try appendZigSpec(g, fmt, spec, null);
                try fmt.append(a, '}');
            }
            try ops.append(a, .{ .at = at, .v = v, .want = ty, .how = if (ty == .int) .ascii else .plain, .spec = spec, .bits = bits });
        },
        'd' => {
            // §2.7 makes a string literal an unsigned base-256 integer when
            // used as an operand, so `$strobe("%d", "\n")` prints 10;
            // `renderVal(.int)` does the digits.
            const zero_fill = spec.zero and !spec.left and spec.width > 0;
            if (spec.plus or spec.space or zero_fill) {
                // C 7.21.6.1: '+'/' ' put a sign character in the field and
                // '0' packs zeros between sign and digits (`+42`, ` 42`,
                // `-0042`). Zig's `{d:0>5}` writes `00-42`, so the field is
                // composed in scratch (`renderPrintArg`'s .cint arm).
                try appendStrField(g, fmt, spec, zero_fill);
                try ops.append(a, .{ .at = at, .v = v, .want = .int, .how = .cint, .spec = spec });
            } else if (spec.width > 0) {
                // A width alone makes std.fmt spell the sign (`{d:>5}` writes
                // `+42`), so the decimal TEXT pads instead, via `zPadInt`.
                try appendStrField(g, fmt, spec, false);
                try ops.append(a, .{ .at = at, .v = v, .want = .int, .how = .pad, .spec = spec });
            } else {
                try fmt.appendSlice(a, "{d}");
                try ops.append(a, .{ .at = at, .v = v, .want = .int, .spec = spec });
            }
        },
        else => {
            // The Zig verb for the remaining conversions. `conv == 0` on a
            // real or string is §9.4.3's "default decimal format" in the
            // value's own type (an integer took `%d` above; a real's
            // shortest round trip is `buildArgs`'s deviation); a string prints its text,
            // which every `CHECK` macro's `%s` depends on. `%t`/`%u`/`%z`/`%v`
            // are rows an analog device has no data for; they print the value.
            const verb: []const u8 = switch (conv) {
                's' => "s",
                't', 'u', 'z', 'v' => "d",
                else => if (ty == .str) "s" else "d",
            };
            try fmt.append(a, '{');
            try fmt.appendSlice(a, verb);
            try appendZigSpec(g, fmt, spec, null);
            try fmt.append(a, '}');
            try ops.append(a, .{ .at = at, .v = v, .want = ty, .spec = spec });
        },
    }
    // One `{…}` and one operand per conversion.
    assert(ops.items.len == ops_before + 1);
    assert(fmt.items.len > at);
}

/// Emits operand `i` of a print's argument tuple. A real crosses into the
/// format layer through `.val()`. The `.ascii`/`.cint` arms emit labeled block
/// expressions whose scratch is the `zb{i}` array `emitScratch` declared.
fn renderPrintArg(g: *Gen, p: PrintArg, i: usize) Error!void {
    // `appendConv` pairs every helper mode with the type it reads.
    switch (p.how) {
        .pad, .cint, .chr, .bits, .ascii => assert(p.want == .int),
        .creal => assert(p.want == .real),
        .plain => {},
    }
    switch (p.how) {
        .ascii => {
            // Mask the i64 carrier to the source width so sign extension adds
            // no characters. Only leading zero bytes vanish; interior and
            // trailing NULs are data.
            try g.b("zs{d}: {{ std.mem.writeInt(u64, &zb{d}, @as(u{d}, @truncate(@as(u64, @bitCast(@as(i64, ", .{ i, i, p.bits });
            try g.renderVal(p.v, .int);
            try g.b("))))), .big); break :zs{d} std.mem.trimStart(u8, &zb{d}, &.{{0}}); }}", .{ i, i });
        },
        .pad => {
            try g.b("zPadInt(&zb{d}, ", .{i});
            try g.renderVal(p.v, .int);
            try g.b(")", .{});
        },
        .bits => {
            // The pattern at the operand's own width (`PrintArg.bits`): §3.2
            // makes an `integer` 32 bits, so -5 is fffffffb, not sixteen digits.
            if (p.bits < 64) try g.b("@as(u{d}, @truncate(", .{p.bits});
            try g.b("@as(u64, @bitCast(@as(i64, ", .{});
            try g.renderVal(p.v, .int);
            try g.b(")))", .{});
            if (p.bits < 64) try g.b("))", .{});
        },
        .chr => {
            try g.b("@as(u8, @truncate(@as(u64, @bitCast(@as(i64, ", .{});
            try g.renderVal(p.v, .int);
            try g.b(")))))", .{});
        },
        .cint => {
            // C 7.21.6.1 sign placement. Zero-fill: zeros go after the sign,
            // so each branch prints its sign and pads |v| to what is left.
            // @abs on an i64 returns u64, so minInt needs no special case.
            // Without zero-fill the outer `{s:>W}` does any padding.
            const sign: []const u8 = if (p.spec.plus) "+" else if (p.spec.space) " " else "";
            const w = p.spec.width;
            const zero_fill = p.spec.zero and !p.spec.left and p.spec.width > 0;
            // The zero-filled field leaves room for its sign.
            if (zero_fill) assert(w >= 1);
            if (zero_fill) assert(w >= sign.len);
            try g.b("zi{d}: {{ const zv: i64 = ", .{i});
            try g.renderVal(p.v, .int);
            if (zero_fill) {
                // @abs in both branches: Zig spells `+42` for a signed int
                // once a width fixes the field; a u64 has no sign to spell.
                try g.b("; if (zv < 0) break :zi{d} std.mem.print({s}zb{d}, \"-{{d:0>{d}}}\", .{{@abs(zv)}}) catch unreachable", .{ i, p.amp(), i, w - 1 });
                try g.b("; break :zi{d} std.mem.print({s}zb{d}, \"{s}{{d:0>{d}}}\", .{{@abs(zv)}}) catch unreachable; }}", .{ i, p.amp(), i, sign, w - sign.len });
            } else {
                try g.b("; break :zi{d} std.mem.print({s}zb{d}, \"{{s}}{{d}}\", .{{ if (zv < 0) \"\" else \"{s}\", zv }}) catch unreachable; }}", .{ i, p.amp(), i, sign });
            }
        },
        .creal => {
            // C11 7.21.6.1's flag bits, `str_kernels.zc_*`: 1 '-', 2 '+',
            // 4 ' ', 8 '0', 16 '#'. The kernel composes the whole field.
            assert(p.conv != 0); // the source's letter: 'e', 'f', 'g' or 'r', either case
            const flags: u8 = (if (p.spec.left) str_k.zc_left else 0) |
                (if (p.spec.plus) str_k.zc_plus else 0) |
                (if (p.spec.space) str_k.zc_space else 0) |
                (if (p.spec.zero) str_k.zc_zero else 0) |
                (if (p.spec.alt) str_k.zc_alt else 0);
            try g.b("zCReal({s}zb{d}, (", .{ p.amp(), i });
            try g.renderVal(p.v, .real);
            try g.b(").val(), '{c}', {d}, {d}, {d})", .{
                p.conv,
                flags,
                p.spec.width,
                if (p.spec.prec) |pr| @as(i64, @intCast(pr)) else -1,
            });
        },
        .plain => switch (p.want) {
            .real => {
                try g.b("(", .{});
                try g.renderVal(p.v, .real);
                try g.b(").val()", .{});
            },
            .int => try g.renderVal(p.v, .int),
            .str => try g.renderVal(p.v, .str),
            .wide => unreachable, // lowering hands a task no wide value: a whole wide `reg` read is E0222
        },
    }
}

// ---------------------------------------------------------------------------
// Tests: the emitted translation, pinned as text. The printed transcripts are
// pinned by tests/conformance/tests/verilog-a/ch09_system_tasks/display_argument_runs.va and
// display_c_format_flags.va.
// ---------------------------------------------------------------------------

const Harness = @import("codegen/harness.zig").Harness;

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
    // `str_kernels.zig` is spliced into every printing artifact, so these are
    // the renderings a model gets. Each row is a rule of the clause: the %g
    // style choice on both sides of its window, sign/zero-fill placement, the
    // round-half-to-even tie, and §2.6.2's mantissa normalisation.
    // Imported through the `kernels` module: a file may live in one module.
    const k = @import("kernels").str_kernels;
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
    const k = @import("kernels").str_kernels;
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
    const k = @import("kernels").str_kernels;
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

test sayRecords {
    // A printing task is a record; `$monitor` (its change detection is state
    // a device does not keep) and `$fatal`/`$error` (the status channel) are not.
    try std.testing.expect(sayRecords(.@"$strobe"));
    try std.testing.expect(sayRecords(.@"$display"));
    try std.testing.expect(!sayRecords(.@"$monitor"));
    try std.testing.expect(!sayRecords(.@"$fatal"));
    try std.testing.expect(!sayRecords(.@"$error"));
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
        fn f(how: PrintArg.Mode, spec: Spec) ?usize {
            return (PrintArg{ .v = .f_zero, .want = .int, .how = how, .spec = spec }).scratch();
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
