//! Compiler directives: one '`'-led word and its logical line in, its effect
//! out (a conditional level pushed or popped, an included file scanned, a
//! `Directives` event recorded, or the word handed to `pp/macro.zig` as a
//! macro use). `directive` is the dispatch; the handlers follow it.
//! LRM §10.1-§10.3, §10.6; IEEE 1364 §19.1, §19.2, §19.4-§19.10, §28.

const std = @import("std");
const diag = @import("diag");
const Preprocessor = @import("../preprocessor.zig");
const Lexer = @import("../lexer.zig");
const pp_macro = @import("macro.zig");
const Directive = Preprocessor.Directive;
const directive_map = Preprocessor.directive_map;
const identEnd = Preprocessor.identEnd;
const escapedEnd = Preprocessor.escapedEnd;
const Error = Preprocessor.Error;
const Qualifier = Preprocessor.Qualifier;
const NetType = Preprocessor.NetType;
const Drive = Preprocessor.Drive;
const builtin_includes = Preprocessor.builtin_includes;
const Pp = Preprocessor.Pp;
const Rest = Preprocessor.Rest;
const isSpace = Preprocessor.isSpace;

// ---------------------------------------------------------------------------
// Dispatch and the IEEE 1364 §19.4 conditionals
// ---------------------------------------------------------------------------

/// Handles the directive or macro use whose '`' is at `at`. Returns the offset
/// to resume scanning from. Inside an inactive arm only the conditionals act;
/// every other directive emits its newlines and nothing else. In an active
/// arm, a '`' followed by no name is E0103; each handler names its own
/// failures. Asserts that `text[at]` is the '`'. The offset returned is
/// past it, so the scan always moves.
pub fn directive(pp: *Pp, text: []const u8, at: usize) Error!usize {
    std.debug.assert(at < text.len);
    std.debug.assert(text[at] == '`');
    const name_start = at + 1;
    var j = name_start;

    // §2.8.1 escaped identifier: `\` then printable ASCII, ended by white
    // space, with neither the backslash nor the terminator part of the name.
    // Syntax 10-3 makes text_macro_identifier an `identifier` (A.9.3: simple
    // or escaped), so a use may be spelled `` `\MY-GAIN ``. No compiler
    // directive is spelled with a backslash, so this can only be a macro use
    // and goes straight to `expand`.
    if (j < text.len and text[j] == '\\') {
        const body = j + 1;
        j = escapedEnd(text, body);
        if (j == body) {
            if (!pp.emitting()) return at + 1;
            return pp.fail(pp.spanAt(at, at + 1), .E0103, "", .{});
        }
        return pp_macro.expand(pp, text, at, j, text[body..j]);
    }

    j = identEnd(text, j);
    if (j == name_start) {
        if (!pp.emitting()) return at + 1;
        return pp.fail(pp.spanAt(at, at + 1), .E0103, "", .{});
    }
    const name = text[name_start..j];

    const kind = directive_map.get(name) orelse return pp_macro.expand(pp, text, at, j, name);

    // Conditionals run even inside an inactive arm, because they nest.
    switch (kind) {
        .ifdef, .ifndef, .elsif, .@"else", .endif => return conditional(pp, text, at, j, kind),
        else => {}, // else: the line-oriented directives, below
    }

    // Everything else dies with the arm it sits in. A directive with no
    // operand (IEEE 1364 §19.1, §19.6, §19.9) is its word alone; the rest
    // take their operands to the end of the line.
    const end = switch (kind) {
        .celldefine, .endcelldefine, .nounconnected_drive, .resetall => j,
        .default_nettype, .unconnected_drive => operandLineEnd(text, j),
        else => logicalLineEnd(text, j), // else: every other directive reads its operand from the rest of the line
    };
    if (!pp.emitting()) {
        try pp.putNewlines(text[at..end]);
        return end;
    }
    switch (kind) {
        .define => try pp_macro.handleDefine(pp, text[j..end], at, j),
        .undef => try pp_macro.removeDefine(pp, text[j..end], at, j),
        .include => try handleInclude(pp, text[j..end], at, j),
        .resetall => {
            // IEEE 1364 §19.3: "The text macro facility is not affected by the
            // compiler directive `resetall." Macros are left alone.
            // §10.2 opens its reset sentence with "In addition to `resetall",
            // which makes the global reset the second way to withdraw the
            // default discipline. An empty `discipline` is that withdrawal.
            try pp.events.disciplines.append(pp.scratch, .{
                .at = @intCast(pp.out.items.len),
                .qualifier = null,
                .discipline = "",
            });
            // IEEE 1364 §19.6: `resetall returns every directive to its default.
            // `timescale's is "none specified", which §9.15 reads as not known.
            try pp.mark(&pp.events.timescales, null);
            // Events, not cleared lists: a mid-file `resetall must not unsay
            // what earlier directives did to the text above it.
            try pp.mark(&pp.events.nettypes, NetType.default);
            try pp.mark(&pp.events.cells, false);
            try pp.mark(&pp.events.drives, Drive.default);
            // §10.3's default is "controlled by the simulator": no directive.
            try pp.mark(&pp.events.transitions, null);
            // IEEE 1364 §19.6: "It shall be illegal for the `resetall directive
            // to be specified within a module or UDP declaration." Only the
            // parser knows where a module is, so the word is passed through,
            // like §10.6's pair below, for it to judge.
            try pp.out.appendSlice(pp.scratch, text[at..j]);
            return j;
        },
        .default_discipline => try handleDefaultDiscipline(pp, text[j..end], j),
        // Applied here, and the word passed through for the parser to refuse
        // inside a module: §10.3 "can be used only outside of module definitions".
        .default_transition => {
            try handleDefaultTransition(pp, text[j..end], j);
            try pp.out.appendSlice(pp.scratch, text[at..j]);
            try pp.putNewlines(text[j..end]);
            return end;
        },
        .line => try handleLine(pp, text[j..end], at, j),
        .timescale => try handleTimescale(pp, text[j..end], j),
        // Applied here, and the word passed through, as `resetall's is, for
        // the parser to refuse inside a module (IEEE 1364 §19.2, §19.9).
        .default_nettype, .unconnected_drive, .nounconnected_drive => {
            switch (kind) {
                .default_nettype => try handleDefaultNettype(pp, text[j..end], j),
                .unconnected_drive => try handleUnconnectedDrive(pp, text[j..end], j),
                else => try pp.mark(&pp.events.drives, .float), // else: `nounconnected_drive, the one other arm of this prong
            }
            try pp.out.appendSlice(pp.scratch, text[at..j]);
            try pp.putNewlines(text[j..end]);
            return end;
        },
        // IEEE 1364 §19.1's pair takes no operand.
        .celldefine => try pp.mark(&pp.events.cells, true),
        .endcelldefine => try pp.mark(&pp.events.cells, false),
        // `protect` is not unrecognized: IEEE 1364 §28 reserves it, and §28.2
        // obliges decryption that VerA does not do.
        .pragma => {
            var r: Rest = .{ .s = text[j..end] };
            const pragma_name = r.ident() orelse return pp.fail(pp.spanAt(at, j), .E0147, "", .{});
            if (std.mem.eql(u8, pragma_name, "protect"))
                return pp.fail(pp.spanAt(at, j), .E0146, "", .{});
        },
        // §10.6: passed through instead of being blanked out, so the lexer and
        // parser see it. The slice carries its own newlines, so the
        // line-number contract in the file header holds unchanged.
        .keywords => {
            try pp.out.appendSlice(pp.scratch, text[at..end]);
            return end;
        },
        .ifdef, .ifndef, .elsif, .@"else", .endif => unreachable, // returned above
    }
    try pp.putNewlines(text[at..end]);
    return end;
}

/// `ifdef / `ifndef / `elsif / `else / `endif (IEEE 1364 §19.4).
fn conditional(pp: *Pp, text: []const u8, at: usize, after_name: usize, kind: Directive) Error!usize {
    std.debug.assert(after_name > at); // past the '`' and the word
    std.debug.assert(after_name <= text.len);
    // The operand, if any, is on the directive's line; the text after it is
    // ordinary source (IEEE 1364 §19.4 Syntax 19-5 has no line break).
    var r: Rest = .{ .s = text[after_name..logicalLineEnd(text, after_name)] };
    // The directive word itself: `ifdef, `else, ...
    const sp = pp.spanAt(at, after_name);

    switch (kind) {
        .ifdef, .ifndef => {
            // The operand is a text_macro_identifier (Syntax 10-3), simple or
            // escaped (A.9.3), so `` `ifdef \M-X `` tests what
            // `` `define \M-X `` created.
            const macro = r.escapedIdent() orelse r.ident() orelse
                return pp.fail(sp, .E0104, "`{s}", .{@tagName(kind)});
            const parent = pp.emitting();
            const defined = pp.macros.contains(macro);
            const want = if (kind == .ifdef) defined else !defined;
            const active = parent and want;
            try pp.conds.append(pp.scratch, .{
                .parent_active = parent,
                .active = active,
                .taken = active,
                .span = sp,
                .file = pp.cur_file_id,
            });
        },
        .elsif, .@"else" => {
            const n = pp.conds.items.len;
            if (n == 0) return pp.fail(sp, .E0105, "`{s}", .{@tagName(kind)});
            const top = &pp.conds.items[n - 1];
            if (top.seen_else) return pp.fail(sp, .E0106, "`{s}", .{@tagName(kind)});
            if (kind == .@"else") {
                top.seen_else = true;
                top.active = top.parent_active and !top.taken;
                top.taken = true;
            } else {
                // Same A.9.3 pair as `ifdef above: the name may be escaped.
                const macro = r.escapedIdent() orelse r.ident() orelse
                    return pp.fail(sp, .E0107, "", .{});
                top.active = top.parent_active and !top.taken and pp.macros.contains(macro);
                if (top.active) top.taken = true;
            }
        },
        .endif => {
            if (pp.conds.pop() == null) return pp.fail(sp, .E0108, "", .{});
        },
        else => unreachable,
    }
    const end = after_name + r.i;
    try pp.putNewlines(text[at..end]);
    return end;
}

/// Returns the end of the line holding the operand of a directive whose word
/// ends at `i`. IEEE 1364 Syntax 19-2 and 19-9 put no line break between the
/// word and its operand, so a word alone on its line takes the next nonblank
/// line (iverilog br_gh782f, br_gh782c).
fn operandLineEnd(text: []const u8, i: usize) usize {
    const end = logicalLineEnd(text, i);
    var k = i;
    while (k < text.len and isSpace(text[k])) k += 1;
    return if (k < end) end else logicalLineEnd(text, k);
}

/// Returns the end of the logical line at `i`: the next unescaped newline, or EOF.
/// A `\` before a newline continues the line (§10.4 multi-line macro text).
fn logicalLineEnd(text: []const u8, i: usize) usize {
    std.debug.assert(i <= text.len);
    var k = i;
    while (k < text.len) {
        if (text[k] == '\\') {
            var n = k + 1;
            while (n < text.len and (text[n] == ' ' or text[n] == '\t' or text[n] == '\r')) n += 1;
            if (n < text.len and text[n] == '\n') {
                k = n + 1;
                continue;
            }
        } else if (text[k] == '\n') return k;
        k += 1;
    }
    return text.len;
}

// ---------------------------------------------------------------------------
// `include
// ---------------------------------------------------------------------------

/// Reads and scans the file an IEEE 1364 §19.5 `include names. `rest` is the
/// line after the word, starting at offset `off`; `at` is the '`'. Fails with
/// E0121-E0124 (the name), E0144 (text after it), E0125 (an include cycle),
/// E0126 (not found) or E1013 (larger than `Preprocessor.max_text_bytes`).
pub fn handleInclude(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    // The open-includes stack is the cycle check's: it leaves as it came.
    const depth = pp.includes.items.len;
    defer std.debug.assert(pp.includes.items.len == depth);
    // The directive word, for the errors that have nothing better to point at.
    const sp = pp.spanAt(at, off);
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const open = r.peek() orelse return pp.fail(sp, .E0121, "", .{});
    // IEEE 1364-2005 §19.5 Syntax 19-6 has one form, `include "filename". C's
    // `<file>` is not in it, so `<` is E0122 like any other opener.
    if (open != '"') return pp.fail(pp.spanAt(off + r.i, off + r.i + 1), .E0122, "found `{c}`", .{open});
    const close: u8 = '"';
    r.i += 1;
    const start = r.i;
    while (r.i < r.s.len and r.s[r.i] != close) r.i += 1;
    if (r.i >= r.s.len) return pp.fail(pp.spanAt(off + start - 1, off + r.i), .E0123, "", .{});
    const path = r.s[start..r.i];
    if (path.len == 0) return pp.fail(pp.spanAt(off + start - 1, off + r.i + 1), .E0124, "", .{});
    // The file name itself, quotes excluded.
    const name_span = pp.spanAt(off + start, off + r.i);
    // IEEE 1364 §19.5: "Only white space or a comment may appear on the same
    // line as the `include compiler directive." Comments are gone already.
    r.i += 1;
    r.skipSpace();
    if (r.i < r.s.len)
        return pp.fail(pp.spanAt(off + r.i, off + r.s.len), .E0144, "`{s}`", .{std.mem.trim(u8, r.s[r.i..], " \t\r\n")});

    const inc = (try readInclude(pp, path, name_span)) orelse {
        var b = pp.failWith(name_span, .E0126);
        b.msg("\"{s}\"", .{path});
        const dirs = if (includerDir(pp)) |d| try std.mem.concat(pp.scratch, []const u8, &.{ &.{d}, pp.opts.include_dirs }) else pp.opts.include_dirs;
        if (dirs.len != 0) b.note("searched, in order: {s}", .{try std.mem.join(pp.scratch, ", ", dirs)});
        b.note("then the built-in annex D headers ({s})", .{"constants.vams, disciplines.vams"});
        try b.emit();
        return error.PreprocessFailed;
    };

    // IEEE 1364-2005 §19.5: "The number of nesting levels for include files
    // shall be finite", and VerA sets no number. What makes nesting infinite
    // is a file opened again inside itself in the state it was first opened
    // in: the preprocessor's control flow reads only the macro table and the
    // open conditionals, so from there it repeats forever. Any other chain
    // ends (a file may include itself under a guard that changes), so only
    // that repetition is refused, naming the cycle. The state is compared by
    // a 64-bit hash of the macro table; two different tables share one with
    // probability 2^-64.
    const opened: Pp.Open = .{
        .key = try std.fs.path.resolve(pp.scratch, &.{inc.path}),
        .path = path,
        .macro_hash = pp.macro_hash,
        .conds = pp.conds.items.len,
    };
    for (pp.includes.items, 0..) |o, k| {
        if (o.macro_hash != opened.macro_hash or o.conds != opened.conds or !std.mem.eql(u8, o.key, opened.key)) continue;
        var chain: std.ArrayList([]const u8) = .empty;
        for (pp.includes.items[k..]) |c| try chain.append(pp.scratch, c.path);
        var b = pp.failWith(name_span, .E0125);
        b.msg("\"{s}\" includes itself with every macro as it was", .{path});
        b.note("include cycle: {s}", .{try pp.joinChain(chain.items, path)});
        try b.emit();
        return error.PreprocessFailed;
    }
    try pp.includes.append(pp.scratch, opened);
    defer _ = pp.includes.pop();
    // `Options.require_std_includes`: the source asked for annex D, from an
    // include directory or built in (a guarded copy is then a no-op).
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, base, "constants.vams") or std.mem.eql(u8, base, "constants.h")) pp.constants_included = true;
    if (std.mem.eql(u8, base, "disciplines.vams") or std.mem.eql(u8, base, "discipline.h")) pp.disciplines_included = true;
    // Registered under the opened path, so `__FILE__` and every diagnostic
    // inside the file name the file that was read (§10.7).
    try pp.nested(name_span, Pp.runFile, .{ pp, inc.text, inc.path, null });
    try pp.checkTextSize(name_span);
    // `scan` resyncs the map back to the parent file when `directive` returns.
}

/// The bytes of an `include and the path they were opened by, which §10.7
/// makes `__FILE__`: "the path by which a tool opened the file, not the short
/// name specified in `include". A built-in annex D file keeps the name written.
const Included = struct { text: []const u8, path: []const u8 };

/// Returns the `include file for `path`: an absolute path as written, else
/// the first hit in the including file's directory and then the include dirs
/// (specification/Vague_Decisions.md VD-091), else a built-in annex D file by
/// basename. Null if nothing matched; a file that exists but cannot be read
/// counts as no match. The bytes and the path are on `pp.arena`, since the
/// bag keeps both. Fails with E1013 for a file past
/// `Preprocessor.max_text_bytes`.
pub fn readInclude(pp: *Pp, path: []const u8, span: diag.Span) Error!?Included {
    // IEEE 1364 §19.5: a full path name is opened as written; `join` skips
    // the empty base.
    if (std.fs.path.isAbsolute(path)) return (try readAt(pp, "", path, span)) orelse builtin(pp, path);
    if (includerDir(pp)) |dir| if (try readAt(pp, dir, path, span)) |inc| return inc;
    for (pp.opts.include_dirs) |base| if (try readAt(pp, base, path, span)) |inc| return inc;
    return builtin(pp, path);
}

/// The directory of the file the current `include sits in: the path it was
/// opened by (§10.7), "." for a bare file name, and null for a unit that
/// names no file (`<source>`, `<digital>`), which has no directory to search.
fn includerDir(pp: *const Pp) ?[]const u8 {
    const name = pp.opts.bag.fileName(pp.cur_file_id);
    if (name.len == 0 or name[0] == '<') return null;
    return std.fs.path.dirname(name) orelse ".";
}

fn readAt(pp: *Pp, base: []const u8, path: []const u8, span: diag.Span) Error!?Included {
    const io = std.Io.Threaded.global_single_threaded.io();
    const full = try std.fs.path.join(pp.arena, &.{ base, path });
    if (Preprocessor.readText(io, .cwd(), full, pp.arena)) |bytes| {
        return .{ .text = bytes, .path = full };
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.StreamTooLong => return pp.fail(span, .E1013, "\"{s}\" is larger than {d} bytes", .{ full, Preprocessor.max_text_bytes }),
        else => return null, // try the next dir
    }
}

fn builtin(pp: *Pp, path: []const u8) Error!?Included {
    const name = std.fs.path.basename(path);
    const text = builtin_includes.get(name) orelse return null;
    if (std.mem.eql(u8, name, "disciplines.vams") or std.mem.eql(u8, name, "discipline.h")) pp.annex_d_included = true;
    // `path` may slice a macro body on scratch, and the bag keeps the name.
    return .{ .text = text, .path = try pp.arena.dupe(u8, path) };
}

// ---------------------------------------------------------------------------
// Directives recorded as `Directives` events, and `line
// ---------------------------------------------------------------------------

/// Parses a §10.2 Syntax 10-1 `default_discipline and records its event;
/// §7.4 discipline resolution applies it. `rest` is everything after the word
/// on one logical line, starting at offset `off`.
fn handleDefaultDiscipline(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    // Both operands are optional; the bare form withdraws the default. The
    // discipline_identifier is simple or escaped (A.9.3); annex D.1 declares
    // `discipline \logic ;`, which only the escaped spelling can name. The
    // qualifier is one of fifteen keywords, and §2.8.2 makes an escaped
    // identifier never a keyword.
    const disc = r.escapedIdent() orelse r.ident() orelse "";
    const word = if (disc.len == 0) "" else r.ident() orelse "";
    const qual = std.meta.stringToEnum(Qualifier, word);
    if (word.len != 0 and qual == null) {
        var b = pp.failWith(pp.spanAt(off + r.i - word.len, off + r.i), .E0127);
        b.msg("`{s}` is not a qualifier", .{word});
        b.note("Syntax 10-1 allows one of: {s}", .{"integer, real, reg, wreal, wire, tri, wand, triand, wor, trior, trireg, tri0, tri1, supply0, supply1"});
        try b.emit();
        return error.PreprocessFailed;
    }
    // Anything after the qualifier is not in Syntax 10-1 either. Reported with
    // the same code so the rule reads as one rule.
    try expectEnd(pp, &r, off, .E0127, "qualifier", "Syntax 10-1 is `default_discipline [ discipline_identifier [ qualifier ] ], and nothing more");
    try pp.events.disciplines.append(pp.scratch, .{
        .at = @intCast(pp.out.items.len),
        .qualifier = qual,
        // Published in `Output`, and `disc` may slice a macro body on scratch.
        .discipline = try pp.arena.dupe(u8, disc),
    });
}

/// Parses a §10.3 Syntax 10-2 `default_transition and records its event.
///
///   default_transition_directive ::= `default_transition transition_time
///   transition_time ::= constant_expression
///
/// The operand is mandatory (E0129) and must be a finite, non-negative time.
///
/// ponytail: reads one §2.6 number with scale factor (`4n`, `4e-9`), not a
/// full constant_expression. Upgrade path: emit the directive verbatim and let
/// the parser fold it, once a model writes `default_transition tr*2.
fn handleDefaultTransition(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and !isSpace(r.s[r.i])) r.i += 1;
    const text = r.s[start..r.i];
    if (text.len == 0) {
        var b = pp.failWith(pp.spanAt(off, off + r.s.len), .E0129);
        b.msg("`default_transition needs a transition time and this one has none", .{});
        b.note("Syntax 10-2 is `default_transition transition_time, and the operand is not optional", .{});
        try b.emit();
        return error.PreprocessFailed;
    }
    // One §2.6 number, signed: `parseFloat` alone also reads C's `0x10`,
    // `1.` and `_1`, none of which the lexer makes one number token.
    const num = if (text[0] == '+' or text[0] == '-') text[1..] else text;
    var lx: Lexer.Lexer = .{ .src = num };
    const tag = lx.next().tag;
    if ((tag != .int_literal and tag != .real_literal) or lx.pos != num.len)
        return pp.fail(pp.spanAt(off + start, off + r.i), .E0129, "`{s}` is not a transition time", .{text});
    const t = Lexer.parseReal(pp.scratch, text) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return pp.fail(pp.spanAt(off + start, off + r.i), .E0129, "`{s}` is not a transition time", .{text});
    };
    // §4.5.8 gives the value straight to rise_time and fall_time, and both are
    // times: a negative one describes an edge that finishes before it starts.
    // (E0516 says the same of a rise_time written at the call.)
    if (!(t >= 0.0) or !std.math.isFinite(t)) {
        return pp.fail(pp.spanAt(off + start, off + r.i), .E0129, "a transition time cannot be `{s}`", .{text});
    }
    try expectEnd(pp, &r, off, .E0129, "transition time", "Syntax 10-2 is `default_transition transition_time, and nothing more");
    try pp.mark(&pp.events.transitions, t);
}

/// Parses an IEEE 1364 §19.8 `` `timescale <unit> / <precision> `` and records
/// its event. Each operand is on Table 19-1's grid (1, 10 or 100 and one of
/// six units). Every malformed form, and a precision coarser than the unit,
/// is E0142.
fn handleTimescale(pp: *Pp, rest: []const u8, off: usize) Error!void {
    // Marked null first and filled in on success; a `resetall also writes null.
    const event = pp.events.timescales.items.len;
    try pp.mark(&pp.events.timescales, null);
    var r: Rest = .{ .s = rest };
    const unit = timeLiteral(&r) orelse return badTimescale(pp, off, &r, "a Table 19-1 time unit");
    r.skipSpace();
    if (r.peek() != '/') return badTimescale(pp, off, &r, "`/` and then the time precision");
    r.i += 1;
    const precision = timeLiteral(&r) orelse return badTimescale(pp, off, &r, "a Table 19-1 time precision");
    // "The time precision shall be at least as precise as the time unit"
    // (§19.8). A card that has them backwards is not a timescale.
    if (precision > unit) {
        var b = pp.failWith(pp.spanAt(off, off + r.s.len), .E0142);
        b.msg("the time precision is coarser than the time unit", .{});
        b.note("§19.8: \"The time precision shall be at least as precise as the time unit\"", .{});
        try b.emit();
        return error.PreprocessFailed;
    }
    r.skipSpace();
    if (r.i < r.s.len) return badTimescale(pp, off, &r, "nothing more");
    pp.events.timescales.items[event].value = .{ .unit = unit, .precision = precision };
}

/// Emits E0142 naming what §19.8's grammar wanted. `r.i` is undefined after a
/// failed `timeLiteral`, so the span is the whole operand list.
fn badTimescale(pp: *Pp, off: usize, r: *const Rest, wanted: []const u8) Error {
    const wrote = std.mem.trim(u8, r.s, " \t\r");
    var b = pp.failWith(pp.spanAt(off, off + r.s.len), .E0142);
    if (wrote.len == 0) {
        b.msg("`timescale has no operands", .{});
    } else {
        b.msg("`{s}` is not a `timescale", .{wrote});
    }
    b.note("§19.8 is `timescale <time_unit>/<time_precision>; here it wanted {s}", .{wanted});
    b.note("each operand is 1, 10 or 100 glued to one of s ms us ns ps fs", .{});
    b.emit() catch |e| return e;
    return error.PreprocessFailed;
}

/// Parses an IEEE 1364 §19.2 `default_nettype and records its region.
///
///   default_nettype_compiler_directive ::= `default_nettype default_nettype_value
///   default_nettype_value ::= wire | tri | tri0 | tri1 | wand | triand
///                           | wor | trior | trireg | uwire | none
///
/// The operand is mandatory and anything off the list is E0140. This is not
/// §10.2's qualifier list: that admits `integer`, `real`, `reg`, `wreal`,
/// `supply0` and `supply1` and lacks `uwire` and `none`. Name resolution
/// applies the region to undeclared names used as nets.
fn handleDefaultNettype(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    const word = r.ident() orelse "";
    const value = std.meta.stringToEnum(NetType, word) orelse {
        var b = pp.failWith(pp.spanAt(off, off + r.s.len), .E0140);
        if (word.len == 0) {
            b.msg("`default_nettype needs a net type and this one has none", .{});
        } else {
            b.msg("`{s}` is not a net type", .{word});
        }
        b.note("§19.2 allows one of: wire, tri, tri0, tri1, wand, triand, wor, trior, trireg, uwire, none", .{});
        try b.emit();
        return error.PreprocessFailed;
    };
    try expectEnd(pp, &r, off, .E0140, "net type", "§19.2 is `default_nettype default_nettype_value, and nothing more");
    try pp.mark(&pp.events.nettypes, value);
}

/// Parses an IEEE 1364 §19.9 `` `unconnected_drive pull1 | pull0 `` and
/// records its region. The operand is mandatory (E0141); the operand-less
/// form is `` `nounconnected_drive ``.
fn handleUnconnectedDrive(pp: *Pp, rest: []const u8, off: usize) Error!void {
    var r: Rest = .{ .s = rest };
    const word = r.ident() orelse "";
    // Not a `stringToEnum`: `.float` is `nounconnected_drive's value, and
    // `unconnected_drive float` is not a directive.
    const value: Drive = if (std.mem.eql(u8, word, "pull0"))
        .pull0
    else if (std.mem.eql(u8, word, "pull1"))
        .pull1
    else {
        var b = pp.failWith(pp.spanAt(off, off + r.s.len), .E0141);
        if (word.len == 0) {
            b.msg("`unconnected_drive needs a pull value and this one has none", .{});
        } else {
            b.msg("`{s}` is not a pull value", .{word});
        }
        b.note("§19.9 is `unconnected_drive pull1 | pull0; the form with no operand is `nounconnected_drive", .{});
        try b.emit();
        return error.PreprocessFailed;
    };
    try expectEnd(pp, &r, off, .E0141, "pull value", "§19.9 takes one operand and nothing more");
    try pp.mark(&pp.events.drives, value);
}

/// Fails with `code` if anything but white space is left on the directive
/// line: the operand, named by `what`, is the last thing `syntax` allows.
fn expectEnd(pp: *Pp, r: *Rest, off: usize, code: diag.Code, what: []const u8, syntax: []const u8) Error!void {
    r.skipSpace();
    if (r.i == r.s.len) return;
    var b = pp.failWith(pp.spanAt(off + r.i, off + r.s.len), code);
    b.msg("`{s}` follows the {s}", .{ std.mem.trim(u8, r.s[r.i..], " \t\r"), what });
    b.note("{s}", .{syntax});
    try b.emit();
    return error.PreprocessFailed;
}

/// Reads one IEEE 1364 Table 19-1 time literal (`1`, `10` or `100` glued to
/// one of `s ms us ns ps fs`) as seconds, the unit §9.15 Table 9-27 asks for.
/// Null, with the cursor undefined, on anything else.
fn timeLiteral(r: *Rest) ?f64 {
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') r.i += 1;
    const mag: i8 = if (std.mem.eql(u8, r.s[start..r.i], "1"))
        0
    else if (std.mem.eql(u8, r.s[start..r.i], "10"))
        1
    else if (std.mem.eql(u8, r.s[start..r.i], "100")) 2 else return null;
    const unit = r.ident() orelse return null;
    const units = std.StaticStringMap(i8).initComptime(.{
        .{ "s", 0 },   .{ "ms", -3 },  .{ "us", -6 },
        .{ "ns", -9 }, .{ "ps", -12 }, .{ "fs", -15 },
    });
    // A table of exact decimal literals, not magnitude * unit: 100 * 1e-6 is
    // 9.999999999999999e-5, one ulp off the 1e-4 a §9.15 reader expects.
    const decades = [_]f64{
        1e-15, 1e-14, 1e-13, 1e-12, 1e-11, 1e-10, 1e-9, 1e-8, 1e-7,
        1e-6,  1e-5,  1e-4,  1e-3,  1e-2,  1e-1,  1e0,  1e1,  1e2,
    };
    return decades[@intCast(mag + (units.get(unit) orelse return null) + 15)];
}

/// Parses an IEEE 1364 §19.7 `line <number> "<file>" <level> and remaps §10.7
/// `__LINE__` and `__FILE__` from the following line on. "All parameters in
/// the `line directive are required": the number "shall be a positive
/// integer", the level "shall be 0, 1, or 2", and nothing else may follow
/// (E0128). The level is checked and dropped, since VerA keeps the real
/// include stack. "Comments are not allowed on the same line": comments are
/// stripped before directives are read, so a strip mark on the line is one.
fn handleLine(pp: *Pp, rest: []const u8, at: usize, off: usize) Error!void {
    if (pp.expand_site == null) {
        const bag = pp.opts.bag;
        const id = pp.cur_file_id;
        const text = bag.fileText(id);
        const end = off + rest.len;
        const line_start = if (std.mem.findScalarLast(u8, text[0..at], '\n')) |nl| nl + 1 else 0;
        // "only white space may appear on the same line as the `line
        // directive", before it as much as after it.
        for (text[line_start..at]) |c| if (!isSpace(c))
            return pp.fail(pp.spanAt(line_start, at), .E0128, "text before the directive on its line", .{});
        // A comment that ends on the line leaves a strip mark on it; one whose
        // `*/` ends in column 0 marks `line_start` itself.
        // ponytail: linear in the file's comments; a `line is rare.
        for (bag.fileMarks(id)) |m| if (m.out >= line_start and m.out <= end)
            return pp.fail(pp.spanAt(at, end), .E0128, "a comment on the directive's line", .{});
        // One that opens on the line and ends on a later one leaves its first
        // newline where the line ends, and the original text has the comment's
        // `/` there instead of the line's newline.
        if (end < text.len and bag.sourceText(id)[bag.toSourceOffset(id, @intCast(end))] != '\n')
            return pp.fail(pp.spanAt(at, end), .E0128, "a comment on the directive's line", .{});
    }
    var r: Rest = .{ .s = rest };
    r.skipSpace();
    const start = r.i;
    while (r.i < r.s.len and r.s[r.i] >= '0' and r.s[r.i] <= '9') r.i += 1;
    if (r.i == start)
        return pp.fail(pp.spanAt(off, off + r.s.len), .E0128, "", .{});
    const n = std.fmt.parseInt(u32, r.s[start..r.i], 10) catch
        return pp.fail(pp.spanAt(off + start, off + r.i), .E0128, "`{s}` does not fit a line number", .{r.s[start..r.i]});
    if (n == 0) return pp.fail(pp.spanAt(off + start, off + r.i), .E0128, "the line number must be a positive integer", .{});

    r.skipSpace();
    if (r.peek() != '"') return pp.fail(pp.spanAt(off + r.i, off + r.s.len), .E0128, "the file name is missing", .{});
    const q = r.i + 1;
    r.i = q;
    while (r.i < r.s.len and r.s[r.i] != '"') r.i += 1;
    if (r.i >= r.s.len)
        return pp.fail(pp.spanAt(off + q - 1, off + r.i), .E0128, "unterminated file name", .{});
    const file = r.s[q..r.i];
    r.i += 1;
    r.skipSpace();
    const level = r.i;
    if (r.i >= r.s.len or r.s[r.i] < '0' or r.s[r.i] > '2')
        return pp.fail(pp.spanAt(off + level, off + r.s.len), .E0128, "the level must be 0, 1 or 2", .{});
    r.i += 1;
    if (std.mem.trim(u8, r.s[r.i..], " \t\r\n").len != 0)
        return pp.fail(pp.spanAt(off + level, off + r.s.len), .E0128, "`{s}` is not a level", .{std.mem.trim(u8, r.s[level..], " \t\r\n")});
    pp.file_override = file;

    pp.line_from = pp.physicalLine(at) + 1;
    pp.line_to = n;
}
