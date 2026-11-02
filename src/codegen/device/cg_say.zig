//! The §9.4 display tasks of a `.record` device (`Lowered.displays`) ->
//! `say_sites` and `say`: each task a device records, as a site index and its
//! numeric values in the host's `contract.Say`, with one C-style format over the
//! recorded numbers per site; and, for a printing artifact, whether its display
//! unit runs in passes (`Gen.passes`).
//! Cites: §9.4, §9.4.1, §9.4.3, §9.5.9, §9.7.3.
//!
//! Contents:
//! - `pub const SaySite = struct`
//! - `pub fn planSay(g: *Gen) Error![]const SaySite`
//! - `pub fn planPasses(g: *Gen) Error!void`
//! - `pub fn sayRecords(c: Mir.Callee) bool`
//! - `pub fn emitSay(g: *Gen, inst: Mir.Inst) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const str_real = @import("kernels").str_real;
const cg_display = @import("cg_display.zig");
const cg_format = @import("cg_format.zig");

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
    assert(g.display == .record);
    assert(g.say.len == 0);
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
        if (cg_display.severityWord(c)) |word| {
            try fmt.appendSlice(g.arena, word);
            try fmt.appendSlice(g.arena, ": ");
        }
        if (!try sayFormat(g, g.mir.instData(def.inst_result).call.args, &fmt, &vals)) {
            if (g.diags) |bag| try bag.add(.codegen, .W0850, g.lowered.tokenSpan(d.tok), "`{s}` — a device records numbers, and a string here is not a constant", .{d.name});
            continue;
        }
        // §9.4.1: `$write` is the family member that does NOT end the line.
        if (cg_display.endsLine(c)) try fmt.append(g.arena, '\n');
        // `sayFormat` writes at least two bytes per recorded value.
        assert(vals.items.len * 2 <= fmt.items.len);
        try out.append(g.arena, .{ .call = call, .fmt = fmt.items, .tok = d.tok, .vals = vals.items, .debug = c == .@"$debug" });
    }
    assert(out.items.len <= g.lowered.displays.items.len);
    return out.items;
}

/// §9.4.1/§9.5.9 sets `g.passes` when a printing artifact's display unit has
/// a task that runs at every iteration of the solver, `$debug`, `$fdebug` or
/// §9.7.3's `$fatal`, and collects the calls an `analog initial` block makes into
/// `g.init_calls` (`callee.isFileCall`'s through `Lower.sequenceFileCall`'s
/// `$itor` carrier). Such a unit takes a `comptime pass: contract.SayPass`
/// and gates each call on it (`gen_call.gateOpen`).
pub fn planPasses(g: *Gen) Error!void {
    assert(g.display == .emit);
    assert(!g.passes);
    var init: std.ArrayList(Mir.Inst) = .empty;
    for (g.lowered.displays.items) |d| {
        const c: Mir.Callee = .fromName(d.name);
        // §5.10.2/§9.7: `$finish`/`$stop` also need the pass gate, so the
        // tasks after either of them in the same chain do not run (the halt
        // itself happens in the display wrapper's `zFinishPass`).
        // §9.7.3 `$fatal` "terminates the simulation without checking whether
        // the iteration would be rejected": it runs at every iterate too.
        if (c == .@"$debug" or c == .@"$fdebug" or c == .@"$fatal" or c == .@"$finish" or c == .@"$stop") g.passes = true;
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
    g.init_calls = init.items;
    assert(g.init_calls.len <= g.lowered.displays.items.len);
}

/// Whether a `.record` device records task `c` (`planSay`).
pub fn sayRecords(c: Mir.Callee) bool {
    return Mir.callee.family(c) == .display and switch (c) {
        .@"$monitor", .@"$fatal", .@"$error" => false,
        else => true, // else: every other §9.4.1/§9.7.3 printing task is a plain text record
    };
}

/// Emits a `.record` display unit's task (`planSay`) as a labeled block that
/// appends its record to the host's `out`, each value as an f64. A task
/// `planSay` did not keep renders void.
pub fn emitSay(g: *Gen, inst: Mir.Inst) Error!void {
    assert(g.display == .record);
    assert(g.mir.instOp(inst) == .call);
    const call = g.an.rv(g.mir.instResult(inst));
    const k = for (g.say, 0..) |site, j| {
        if (site.call == call) break j;
    } else return g.b("S.con(0.0)", .{});
    assert(k < g.say.len);
    const len_before = g.out.items.len;
    g.cur.uses.out = true;
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
    assert(g.out.items.len > len_before);
}

// ---- private ----

/// §9.4.1's argument-list model (`buildArgs`) as one C-style format over
/// recorded numbers: each string argument is a format whose conversions take
/// the arguments after it, a constant string under `%s` spliced in as text
/// and `%l` as the module name (what the printing artifact writes); an
/// argument no format took is `%d` (integer) or `%g`, and a bare `%d` gets
/// the printing artifact's automatic field (`decimalField`). Appends the recorded
/// arguments to `vals`. False when one has no numeric record: a string that
/// is not a constant, or a number under `%s` (§9.4.5's bytes).
fn sayFormat(g: *Gen, args: []const Mir.Value, fmt: *std.ArrayList(u8), vals: *std.ArrayList(Mir.Value)) Error!bool {
    assert(vals.items.len == 0); // `fmt` may already hold a §9.7.3 severity prefix.
    const fmt_before = fmt.items.len;
    defer assert(fmt.items.len >= fmt_before);
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
            while (j < s.len and (std.ascii.isDigit(s[j]) or s[j] == '.' or str_real.zcFlag(s[j]) != null)) j += 1;
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
    // Every argument was consumed, each recorded one behind at least two
    // bytes of format (`%d`, `%g` or the source's conversion).
    assert(i == args.len);
    assert(vals.items.len * 2 <= fmt.items.len - fmt_before);
    return true;
}

/// `%d` with `v`'s automatic field (`decimalField`), `%11d` for an `integer`.
fn sayDecimal(g: *Gen, fmt: *std.ArrayList(u8), v: Mir.Value) Error!void {
    const len_before = fmt.items.len;
    defer assert(fmt.items.len >= len_before);
    const cols = cg_format.decimalField(g, v) orelse return fmt.appendSlice(g.arena, "%d");
    assert(cols <= 20); // `fieldCols`'s bound
    var buf: [8]u8 = undefined;
    comptime assert(buf.len >= "%20d".len);
    try fmt.appendSlice(g.arena, std.mem.print(&buf, "%{d}d", .{cols}) catch unreachable);
}

/// `text` into a format as itself: each `%` doubled.
fn appendLiteral(g: *Gen, fmt: *std.ArrayList(u8), text: []const u8) Error!void {
    const len_before = fmt.items.len;
    defer assert(fmt.items.len >= len_before);
    for (text) |ch| {
        if (ch == '%') try fmt.append(g.arena, '%');
        try fmt.append(g.arena, ch);
    }
    assert(fmt.items.len >= len_before + text.len);
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
