//! The main scan: one file's comment-stripped text in, its bytes appended to
//! `Pp.out` with every §10 directive and macro use handled in place
//! (pp/directive.zig) and a dead conditional arm reduced to its newlines.
//! Also the byte scans every preprocessor file shares: `findStop` (a vector
//! block compare, probed in tests/codegen_probe.zig), `stringStop` and the
//! directive-line cursor `Rest`.
//! Cites: LRM §2.7, §2.8, §2.8.1, §10; IEEE 1364-2005 §19.4.
//!
//! Contents:
//! - `pub const scan_stops: []const u8`
//! - `pub const Rest = struct`, `Rest.peek(r: *const Rest) ?u8`, `Rest.skipSpace(r: *Rest) void`, `Rest.escapedIdent(r: *Rest) ?[]const u8`, `Rest.ident(r: *Rest) ?[]const u8`
//! - `pub fn scan(pp: *Pp, text: []const u8) Error!void`
//! - `pub fn findStop(text: []const u8, from: usize, comptime stops: []const u8) usize`
//! - `pub fn stringStop(text: []const u8, start: usize) usize`
//! - `pub fn isIdentStart(c: u8) bool`

const std = @import("std");
const assert = std.debug.assert;
const lexer = @import("../lexer.zig");
const Pp = @import("Pp.zig");
const Error = Pp.Error;
const pp_directive = @import("directive.zig");
const isSpace = lexer.isSpace;
const identEnd = lexer.identEnd;
const escapedEnd = lexer.escapedEnd;

/// The three bytes `scan` branches on: a §2.7 string, a §2.8.1 escaped
/// identifier, and a §10 directive or macro use. Everything else is ordinary.
pub const scan_stops = "\"\\`";

/// Cursor over the tail of a directive line.
pub const Rest = struct {
    s: []const u8,
    i: usize = 0,

    /// Returns the byte under the cursor, or null at the end of the line.
    pub fn peek(r: *const Rest) ?u8 {
        assert(r.i <= r.s.len);
        return if (r.i < r.s.len) r.s[r.i] else null;
    }
    /// Advances past white space as the lexer classes it (`isSpace`).
    pub fn skipSpace(r: *Rest) void {
        assert(r.i <= r.s.len);
        while (r.i < r.s.len and isSpace(r.s[r.i])) r.i += 1;
        assert(r.i == r.s.len or !isSpace(r.s[r.i]));
    }
    /// Returns the next §2.8.1 escaped identifier, skipping leading white
    /// space, or null without consuming anything but that space. Neither
    /// the backslash nor the terminating white space is part of the name, so
    /// the macro is keyed on the same bytes a `` `\name `` use produces.
    pub fn escapedIdent(r: *Rest) ?[]const u8 {
        r.skipSpace();
        if (r.i >= r.s.len or r.s[r.i] != '\\') return null;
        const start = r.i + 1;
        const k = escapedEnd(r.s, start);
        if (k == start) return null;
        assert(k > start);
        r.i = k;
        return r.s[start..k];
    }
    /// Returns the next identifier (§2.8), skipping leading white space.
    pub fn ident(r: *Rest) ?[]const u8 {
        r.skipSpace();
        if (r.i >= r.s.len or !isIdentStart(r.s[r.i])) return null;
        const start = r.i;
        r.i = identEnd(r.s, start);
        assert(r.i > start);
        return r.s[start..r.i];
    }
};

/// Copies comment-stripped `text` to `pp.out`, handling directives (§10) and
/// macro uses (§10.4). An inactive conditional arm emits only its newlines.
pub fn scan(pp: *Pp, text: []const u8) Error!void {
    const out_before = pp.out.items.len;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];

        // §2.7 strings are opaque to macro expansion and to directives.
        if (c == '"') {
            const start = i;
            i = stringStop(text, i);
            const closed = i < text.len and text[i] == '"';
            if (closed) i += 1;
            if (pp.emitting()) {
                try pp.out.appendSlice(pp.scratch, text[start..i]);
            } else {
                // IEEE 1364 §19.4: an ignored group "shall still follow the
                // Verilog HDL lexical conventions"; an emitted one is the
                // lexer's to check.
                // ponytail: of those conventions, only §3.6's one-line string
                // is checked here.
                if (!closed) return pp.fail(pp.spanAt(start, i), .E0138, "", .{});
                try pp.putNewlines(text[start..i]);
            }
            continue;
        }

        // §2.8.1 escaped identifiers are opaque too (they may contain '`').
        if (c == '\\') {
            const start = i;
            i = escapedEnd(text, i + 1);
            if (pp.emitting()) try pp.out.appendSlice(pp.scratch, text[start..i]);
            continue;
        }

        if (c == '`') {
            const at = i;
            i = try pp_directive.directive(pp, text, i);
            assert(i > at); // every directive and macro use consumes its '`'
            try pp.resync(i);
            continue;
        }

        // Ordinary text up to the next byte the branches above care about.
        // '\n' is not a stop: `putNewlines` counts it in a dead arm. '/' is
        // not either, since no comment survives `stripComments`.
        const end = findStop(text, i, scan_stops);
        if (pp.emitting()) try pp.out.appendSlice(pp.scratch, text[i..end]) else try pp.putNewlines(text[i..end]);
        // `text[i]` is none of the three, so `end > i`: the loop always moves.
        i = end;
    }
    assert(i == text.len);
    // Emitting or not, the scan only appends.
    assert(pp.out.items.len >= out_before);
}

/// Returns the first index at or after `from` whose byte is in `stops`, else
/// `text.len`. O(result - from). Asserts that `from` is at most `text.len`.
pub fn findStop(text: []const u8, from: usize, comptime stops: []const u8) usize {
    assert(from <= text.len);
    // `std.mem.findAnyPos` is a scalar loop per (byte, needle); only
    // single-needle searches are vectorized in std. So: splat each stop and OR
    // the compare masks. Most scanned bytes sit in runs of 32 or more, so this
    // pays even though the median run is shorter. The scalar loop below is the
    // tail, the no-vector fallback, and the reference tests/unit.zig's preprocessor_tests check.
    var i = from;
    if (std.simd.suggestVectorLength(u8)) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = @Int(.unsigned, lanes);
        while (i + lanes <= text.len) : (i += lanes) {
            const block: V = text[i..][0..lanes].*;
            var hit: Mask = 0;
            inline for (stops) |stop| {
                const splat: V = @splat(stop);
                hit |= @as(Mask, @bitCast(block == splat));
            }
            if (hit != 0) return i + @ctz(hit);
        }
    }
    while (i < text.len) : (i += 1) {
        inline for (stops) |stop| {
            if (text[i] == stop) return i;
        }
    }
    assert(i == text.len);
    return i;
}

/// Returns the index of the closing quote, an unescaped newline, or EOF.
/// A `\` escapes the byte after it, a newline included. Asserts that
/// `text[start]` is the opening quote.
pub fn stringStop(text: []const u8, start: usize) usize {
    assert(text[start] == '"');
    // ponytail: the lexer and `substitute` have their own string scans. The
    // lexer rejects escaped newlines and `substitute` crosses bare ones; share
    // one scan only if those rules converge.
    var i = start + 1;
    // Each pass advances past one escape pair, so `text.len` passes bound it.
    for (0..text.len) |_| {
        i = findStop(text, i, "\"\n\\");
        if (i == text.len or text[i] != '\\') return i;
        i = @min(i + 2, text.len);
    }
    unreachable;
}

/// Reports whether `c` may start a §2.8 simple identifier. Admits `$`, which
/// §2.8 forbids first, because `Rest.ident` also reads system names; a caller
/// that must refuse it (`handleDefine`) checks before calling.
pub fn isIdentStart(c: u8) bool {
    // ponytail: stdlib ASCII classes; `_` and `$` are Verilog's extensions.
    return std.ascii.isAlphabetic(c) or c == '_' or c == '$';
}
