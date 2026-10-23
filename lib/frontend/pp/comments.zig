//! Comment stripping: source bytes in, the bytes with each comment replaced by
//! its newlines (or one space) out, plus marks mapping stripped offsets back
//! to source offsets for diagnostics.
//! LRM §2.2, §2.4, §2.7, §2.8.1.

const std = @import("std");
const Preprocessor = @import("../preprocessor.zig");
const diag = @import("diag");
const Error = Preprocessor.Error;
const Pp = Preprocessor.Pp;
const findStop = Preprocessor.findStop;
const stringStop = Preprocessor.stringStop;

// ---------------------------------------------------------------------------
// §2.4 comments
// ---------------------------------------------------------------------------

/// `stripComments`' result. Both slices are on `Pp.arena`, exactly sized,
/// because the bag keeps them for rendering after the compilation's
/// preprocessing ends.
pub const Stripped = struct { text: []const u8, marks: []const diag.StripMark };

/// Removes `//` and `/* */` comments, keeping the newlines they contained so
/// line numbers survive; a single-line block comment leaves one space, since
/// §2.2 makes a comment a token separator. String literals (§2.7) and escaped
/// identifiers (§2.8.1) are opaque. Block comments do not nest (§2.4).
///
/// Also returns one `diag.StripMark` per comment: lines agree between the two
/// texts, but a comment shifts every column after it, and the renderer maps
/// back through the marks. Both slices are owned by `pp.arena`. An
/// unterminated block comment is E0102, reported in `pp.cur_file_id`, which
/// must already name `src`. O(src.len).
pub fn stripComments(pp: *Pp, src: []const u8) Error!Stripped {
    // The output never grows, so every append below fits. It is the last
    // allocation on `pp.arena` until the return, so the shrink there hands
    // the bytes the comments freed back to the arena. The marks grow on
    // scratch and are copied out once, exactly sized.
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(pp.arena, src.len);
    var marks: std.ArrayList(diag.StripMark) = .empty;

    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '"') {
            const start = i;
            // §2.7: an unterminated literal is the lexer's error to report; stop
            // at the newline so the rest of the file still preprocesses.
            i = stringStop(src, i);
            if (i < src.len and src[i] == '"') i += 1;
            out.appendSliceAssumeCapacity(src[start..i]);
            continue;
        }
        if (c == '\\') {
            // §2.8.1 escaped identifier (or a `define line continuation):
            // opaque up to the next whitespace, so `//` inside cannot start a
            // comment.
            const start = i;
            i = Preprocessor.escapedEnd(src, i + 1);
            out.appendSliceAssumeCapacity(src[start..i]);
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '/') {
            // §2.4: to the end of the line. A single-needle search is vectorized.
            const start = i;
            i = std.mem.findScalarPos(u8, src, i, '\n') orelse src.len;
            // IEEE 1364 §19.3.1: inside `define text the comment is dropped but
            // a `\` ending it still continues the macro (iverilog br_gh435), so
            // the `\` and what follows it survive.
            var keep = i;
            while (keep > start + 2 and (src[keep - 1] == ' ' or src[keep - 1] == '\t' or src[keep - 1] == '\r')) keep -= 1;
            if (keep > start + 2 and src[keep - 1] == '\\' and inDefine(out.items)) keep -= 1 else keep = i;
            // The output stood still while the input advanced; from here the
            // two run in lockstep again, which is one mark.
            try marks.append(pp.scratch, .{ .out = @intCast(out.items.len), .src = @intCast(keep) });
            out.appendSliceAssumeCapacity(src[keep..i]);
            continue;
        }
        if (c == '/' and i + 1 < src.len and src[i + 1] == '*') {
            const start = i;
            // The `*` of the first `*/` past the opener: each `/` from the
            // vectorized single-needle search, kept when a `*` precedes it.
            var k = start + 2;
            i = while (std.mem.findScalarPos(u8, src, k + 1, '/')) |slash| {
                if (src[slash - 1] == '*') break slash - 1;
                k = slash;
            } else {
                // Offsets here index `src`, which runFile registered before
                // this call precisely so this span resolves.
                return pp.fail(pp.spanAt(start, start + 2), .E0102, "", .{});
            };
            // §2.2 makes a comment a token separator. A multi-line comment
            // separates through its newlines; a single-line one leaves a space,
            // or `1/*c*/2` would lex as 12. It fits: `/**/` is four bytes.
            const lines = std.mem.countScalar(u8, src[start..i], '\n');
            if (lines == 0) {
                out.appendAssumeCapacity(' ');
            } else {
                out.appendNTimesAssumeCapacity('\n', lines);
            }
            i += 2;
            // After the replacement bytes, so the lockstep run the mark opens
            // starts at the first byte after the comment on both sides.
            try marks.append(pp.scratch, .{ .out = @intCast(out.items.len), .src = @intCast(i) });
            continue;
        }
        // Ordinary text up to the next byte the branches above care about.
        // `end == i` is a '/' that starts no comment; step over it.
        const end = findStop(src, i, "\"\\/");
        if (end == i) {
            out.appendAssumeCapacity(c);
            i += 1;
        } else {
            out.appendSliceAssumeCapacity(src[i..end]);
            i = end;
        }
    }
    const text = try out.toOwnedSlice(pp.arena);
    return .{ .text = text, .marks = try pp.arena.dupe(diag.StripMark, marks.items) };
}

/// Whether the end of `out` sits on a `define's logical line: walk back over
/// `\`-continued physical lines to the first, and look for the word there.
fn inDefine(out: []const u8) bool {
    var line_end = out.len;
    while (true) {
        const line_start = if (std.mem.findScalarLast(u8, out[0..line_end], '\n')) |n| n + 1 else 0;
        const line = std.mem.trimStart(u8, out[line_start..line_end], " \t");
        if (std.mem.startsWith(u8, line, "`define")) return true;
        if (line_start == 0) return false;
        const prev = std.mem.trimEnd(u8, out[0 .. line_start - 1], " \t\r");
        if (prev.len == 0 or prev[prev.len - 1] != '\\') return false;
        line_end = line_start - 1;
    }
}
