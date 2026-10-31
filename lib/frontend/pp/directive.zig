//! Compiler directives: one '`'-led word and its logical line in, its effect
//! out (a conditional level pushed or popped, an `include scanned
//! (pp/include.zig), a `Directives` event recorded (pp/directive_events.zig),
//! a §28 envelope decrypted and scanned, or the word handed to pp/macro.zig as
//! a macro use). `directive` is the dispatch; the conditionals follow it.
//! Cites: LRM §10.1 Table 10-1, §10.2, §10.3, §10.6; IEEE 1364-2005 §19.1,
//! §19.2, §19.4 Syntax 19-5, §19.6, §19.9, §19.10, §28.2, §28.4.
//!
//! Contents:
//! - `pub const Directive = enum(u8)`
//! - `pub const directive_map: std.StaticStringMap(Directive)`
//! - `pub fn directive(pp: *Pp, text: []const u8, at: usize) Error!usize`
//! - `pub fn logicalLineEnd(text: []const u8, i: usize) usize`

const std = @import("std");
const assert = std.debug.assert;
const diag = @import("diag");
const lexer = @import("../lexer.zig");
const Pp = @import("Pp.zig");
const Error = Pp.Error;
const events = @import("events.zig");
const NetType = events.NetType;
const Drive = events.Drive;
const pp_scan = @import("scan.zig");
const Rest = pp_scan.Rest;
const pp_macro = @import("macro.zig");
const pp_include = @import("include.zig");
const pp_events = @import("directive_events.zig");
const pp_protect = @import("protect.zig");
const identEnd = lexer.identEnd;
const escapedEnd = lexer.escapedEnd;
const isSpace = lexer.isSpace;

/// Directives handled here. LRM §10 Table 10-1.
pub const Directive = enum(u8) {
    define, // §10.4
    undef, // §10.4
    ifdef, // IEEE 1364 §19.4
    ifndef, // IEEE 1364 §19.4
    elsif, // IEEE 1364 §19.4
    @"else", // IEEE 1364 §19.4
    endif, // IEEE 1364 §19.4
    include, // IEEE 1364 §19.5
    resetall, // IEEE 1364 §19.6: directive state only; §19.3 keeps macros
    keywords, // §10.6: emitted verbatim, handled by the parser
    default_discipline, // §10.2: parsed here, applied by discipline resolution
    default_transition, // §10.3: parsed here, applied by §4.5.8 codegen
    line, // IEEE 1364 §19.7: remaps §10.7 `__LINE__` / `__FILE__`
    timescale, // IEEE 1364 §19.8: read back by §9.15 Table 9-27
    default_nettype, // IEEE 1364 §19.2: read by implicit-net creation
    celldefine, // IEEE 1364 §19.1: cell membership, `endcelldefine closes it
    endcelldefine,
    unconnected_drive, // IEEE 1364 §19.9: read by §6.2.2 port binding
    nounconnected_drive,
    pragma, // IEEE 1364 §19.10: no effect, except §28's `protect` (pp/protect.zig)
};

/// Directive name, without its backtick, to kind.
pub const directive_map = std.StaticStringMap(Directive).initComptime(.{
    .{ "define", .define },
    .{ "undef", .undef },
    .{ "ifdef", .ifdef },
    .{ "ifndef", .ifndef },
    .{ "elsif", .elsif },
    .{ "else", .@"else" },
    .{ "endif", .endif },
    .{ "include", .include },
    .{ "resetall", .resetall },

    // §10.6: which annex B words are reserved, and whether the directive sits
    // "outside of a design element", are parse-time questions. Emitted verbatim
    // so the lexer can tag them (`dir_begin_keywords`) and the parser can act.
    .{ "begin_keywords", .keywords },
    .{ "end_keywords", .keywords },

    // §10.2 and IEEE 1364 §19.7: both carry state past their own line, so both
    // are parsed here and published (`Directives`, `Pp.line_*`).
    .{ "default_discipline", .default_discipline },
    .{ "line", .line },
    .{ "default_transition", .default_transition }, // §10.3, read by §4.5.8

    .{ "timescale", .timescale }, // IEEE 1364 §19.8, read back by §9.15

    // The three IEEE 1364 directives that, like §10.2's, carry state past their
    // own line: §19.2 decides whether an undeclared name may become a net at
    // all, §19.1 tags the modules that follow, §19.9 drives their unconnected
    // inputs. All three are published as `Region` event lists.
    .{ "default_nettype", .default_nettype },
    .{ "celldefine", .celldefine },
    .{ "endcelldefine", .endcelldefine },
    .{ "unconnected_drive", .unconnected_drive },
    .{ "nounconnected_drive", .nounconnected_drive },

    // §10.1 lists `pragma and IEEE 1364 §19.10 leaves its content to the tool.
    // VerA defines no pragma, and §19.10 says an unrecognized one "shall have
    // no effect".
    .{ "pragma", .pragma },
});

/// Handles the directive or macro use whose '`' is at `at`. Returns the offset
/// to resume scanning from. Inside an inactive arm only the conditionals act;
/// every other directive emits its newlines and nothing else. In an active
/// arm, a '`' followed by no name is E0103; each handler names its own
/// failures. Asserts that `text[at]` is the '`'. The offset returned is
/// past it, so the scan always moves.
pub fn directive(pp: *Pp, text: []const u8, at: usize) Error!usize {
    assert(at < text.len);
    assert(text[at] == '`');
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
        .include => try pp_include.handleInclude(pp, text[j..end], at, j),
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
        .default_discipline => try pp_events.handleDefaultDiscipline(pp, text[j..end], j),
        // Applied here, and the word passed through for the parser to refuse
        // inside a module: §10.3 "can be used only outside of module definitions".
        .default_transition => {
            try pp_events.handleDefaultTransition(pp, text[j..end], j);
            try pp.out.appendSlice(pp.scratch, text[at..j]);
            try pp.putNewlines(text[j..end]);
            return end;
        },
        .line => try pp_events.handleLine(pp, text[j..end], at, j),
        .timescale => try pp_events.handleTimescale(pp, text[j..end], j),
        // Applied here, and the word passed through, as `resetall's is, for
        // the parser to refuse inside a module (IEEE 1364 §19.2, §19.9).
        .default_nettype, .unconnected_drive, .nounconnected_drive => {
            switch (kind) {
                .default_nettype => try pp_events.handleDefaultNettype(pp, text[j..end], j),
                .unconnected_drive => try pp_events.handleUnconnectedDrive(pp, text[j..end], j),
                else => try pp.mark(&pp.events.drives, .float), // else: `nounconnected_drive, the one other arm of this prong
            }
            try pp.out.appendSlice(pp.scratch, text[at..j]);
            try pp.putNewlines(text[j..end]);
            return end;
        },
        // IEEE 1364 §19.1's pair takes no operand.
        .celldefine => try pp.mark(&pp.events.cells, true),
        .endcelldefine => try pp.mark(&pp.events.cells, false),
        // `protect` is not unrecognized: IEEE 1364 §28 reserves it. §28.2
        // obliges decryption, which VerA does; it provides no encryption
        // service, so an encryption envelope (`begin`) and a block outside a
        // decryption envelope are refused.
        .pragma => {
            var r: Rest = .{ .s = text[j..end] };
            const pragma_name = r.ident() orelse return pp.fail(pp.spanAt(at, j), .E0147, "", .{});
            if (std.mem.eql(u8, pragma_name, "protect")) {
                const list = r.s[r.i..];
                if (envelopeKeyword(list)) |kw| {
                    if (!std.mem.eql(u8, kw, "begin_protected"))
                        return pp.fail(pp.spanAt(at, end), .E0146, "`{s}`", .{kw});
                    return decryptionEnvelope(pp, text, at, end, list);
                }
            }
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
    assert(end > at);
    return end;
}

/// Returns the end of the logical line at `i`: the next unescaped newline, or EOF.
/// A `\` before a newline continues the line (§10.4 multi-line macro text).
pub fn logicalLineEnd(text: []const u8, i: usize) usize {
    assert(i <= text.len);
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
    assert(k == text.len);
    return text.len;
}

// ---- private ----

/// IEEE 1364-2005 §28.2: decrypts the envelope whose `begin_protected` line
/// is `text[at..end]` (expression list `list`) and scans its cleartext in its
/// place, so a macro defined outside expands inside and an envelope inside
/// opens in turn. Returns the offset past the `end_protected` line.
///
/// ponytail: a diagnostic inside the cleartext quotes it; §28's rule that a
/// tool not reveal decrypted text is not applied to diagnostics.
fn decryptionEnvelope(pp: *Pp, text: []const u8, at: usize, end: usize, list: []const u8) Error!usize {
    assert(at < end);
    assert(end <= text.len);
    const span = pp.spanAt(at, end);
    const r = pp_protect.open(pp.arena, pp.opts.protect_keys, list, text, @min(end + 1, text.len)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    switch (r.opened) {
        .fail => |f| return pp.fail(span, f.code, "{s}", .{f.why}),
        .text => |clear| try pp.nested(span, Pp.runFile, .{ pp, clear, pp_protect.file_name, diag.FileId.none }),
    }
    try pp.checkTextSize(span);
    try pp.putNewlines(text[at..r.end]);
    return r.end;
}

/// The first §28.4 pragma keyword in a `pragma protect expression list that
/// opens or carries an envelope (`begin`, `begin_protected` and the three
/// blocks), or null. Every other keyword is metadata: §28.4 gives it an
/// action only inside an envelope, so outside one it has none (§19.10), as
/// for a lone `end`. Items split at top-level commas; strings and
/// parenthesized values are opaque.
fn envelopeKeyword(list: []const u8) ?[]const u8 {
    const opens = [_][]const u8{ "begin", "begin_protected", "data_block", "key_block", "digest_block" };
    assert(list.len <= std.math.maxInt(u32));
    var depth: usize = 0;
    var item = true;
    var i: usize = 0;
    while (i < list.len) : (i += 1) {
        const c = list[i];
        if (c == '"') {
            i = pp_scan.stringStop(list, i);
            continue;
        }
        if (c == '(') depth += 1;
        if (c == ')' and depth > 0) depth -= 1;
        if (c == ',' and depth == 0) item = true;
        if (!item or !pp_scan.isIdentStart(c)) continue;
        const e = identEnd(list, i);
        const word = list[i..e];
        for (opens) |o| if (std.mem.eql(u8, o, word)) return word;
        item = false;
        assert(e > i);
        i = e - 1;
    }
    return null;
}

/// `ifdef's view of a macro. Under `Options.require_std_includes` the
/// prelude's annex D macros (D.2's constants, D.1's guard `DISCIPLINES_VAMS`)
/// are hidden with the definitions they belong to until the source includes
/// that file, so `` `ifndef DISCIPLINES_VAMS `include ... `` includes it here
/// exactly as in a tool without a prelude. A source's own `define of a guard
/// is its own macro, and defined.
fn isDefined(pp: *const Pp, name: []const u8) bool {
    assert(name.len > 0);
    const m = pp.macros.get(name) orelse return false;
    if (!pp.opts.require_std_includes or pp.in_std_defs) return true;
    if (m.annex_d2) return pp.constants_included;
    if (m.annex_d1) return pp.disciplines_included;
    return true;
}

/// `ifdef / `ifndef / `elsif / `else / `endif (IEEE 1364 §19.4).
fn conditional(pp: *Pp, text: []const u8, at: usize, after_name: usize, kind: Directive) Error!usize {
    assert(after_name > at); // past the '`' and the word
    assert(after_name <= text.len);
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
            const defined = isDefined(pp, macro);
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
                top.active = top.parent_active and !top.taken and isDefined(pp, macro);
                if (top.active) top.taken = true;
            }
        },
        .endif => {
            if (pp.conds.pop() == null) return pp.fail(sp, .E0108, "", .{});
        },
        else => unreachable,
    }
    const end = after_name + r.i;
    assert(end <= text.len);
    try pp.putNewlines(text[at..end]);
    return end;
}

/// Returns the end of the line holding the operand of a directive whose word
/// ends at `i`. IEEE 1364 Syntax 19-2 and 19-9 put no line break between the
/// word and its operand, so a word alone on its line takes the next nonblank
/// line (iverilog br_gh782f, br_gh782c).
fn operandLineEnd(text: []const u8, i: usize) usize {
    assert(i <= text.len);
    const end = logicalLineEnd(text, i);
    var k = i;
    while (k < text.len and isSpace(text[k])) k += 1;
    return if (k < end) end else logicalLineEnd(text, k);
}
