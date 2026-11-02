//! Token text in, literal values out: a §2.6.2 real's `f64` (`parseReal`), a
//! §2.7 string's bytes (`stringContents`), the escapes Table 2-2 does not
//! define (`badEscape`) and why an unterminated string ran away
//! (`stringRunaway`). §2.6.1 integers are `kernels.Integer`'s.
//! Cites: LRM §2.6.2 Table 2-1, §2.7 Table 2-2; IEEE 1800 §5.9 (the line
//! continuation `stringRunaway` names).
//!
//! Contents:
//! - `pub const ValueError = error{ Overflow, OutOfMemory }`
//! - `pub const BadEscape = struct`
//! - `pub const StringRunaway = enum(u8)`
//! - `pub fn scaleExp(c: u8) ?[]const u8`
//! - `pub fn parseReal(gpa: Allocator, text: []const u8) ValueError!f64`
//! - `pub fn stringContents(gpa: Allocator, text: []const u8) Allocator.Error![]u8`
//! - `pub fn badEscape(text: []const u8, from: u32) ?BadEscape`
//! - `pub fn stringRunaway(src: []const u8, span: diag.Span) StringRunaway`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const testing = std.testing;

/// Every way `parseReal` fails. Nothing is allocated on return.
pub const ValueError = error{
    /// `std.fmt.parseFloat` refused the text. The lexer never produces such a
    /// literal; a value too large for f64 is not this error but inf (§2.6.2
    /// leaves it to IEEE 754).
    Overflow,
    /// A literal past 512 bytes needed a heap buffer that could not be had.
    OutOfMemory,
};

/// An escape in a `.string_literal` that `stringContents` decodes by VerA's
/// choice rather than by Table 2-2, as byte offsets into the token text.
pub const BadEscape = struct {
    start: u32,
    end: u32,
    /// `\ddd` above `\377` (E0148); otherwise an escape Table 2-2 does not
    /// list (W0149).
    above_377: bool,
};

/// Why a `.invalid` token that opened with `"` never closed, so the parser can
/// give that common mistake its own message (E0138).
pub const StringRunaway = enum(u8) {
    /// Not a string literal at all; the caller's own message stands.
    none,
    /// Ran off the end of the line (or the file) with no closing quote.
    unterminated,
    /// Ended the line with a backslash: the SystemVerilog line continuation.
    line_continuation,
};

/// Longest real literal `parseReal` decodes without the heap.
const real_stack_bytes = 512;

/// Returns the exponent text a §2.6.2 Table 2-1 scale factor stands for, or
/// null. `M` is 1e6 and `m` is 1e-3; `K` and `k` are both 1e3.
/// Callers append it to the mantissa and parse once: `200u` → `200e-6` rounds
/// once, while `200.0 * 1e-6` rounds twice and gives a different double. The
/// testbench's `//! time` parser uses it so both read the same value; do not
/// re-spell the table elsewhere.
pub fn scaleExp(c: u8) ?[]const u8 {
    const exp: ?[]const u8 = switch (c) {
        'T' => "e12",
        'G' => "e9",
        'M' => "e6",
        'K', 'k' => "e3",
        'm' => "e-3",
        'u' => "e-6",
        'n' => "e-9",
        'p' => "e-12",
        'f' => "e-15",
        'a' => "e-18",
        else => null,
    };
    if (exp) |e| assert(e.len <= 4 and e[0] == 'e');
    return exp;
}

/// Decodes a `.real_literal`'s text (LRM §2.6.2), of any length. Strips `_`
/// and rewrites a Table 2-1 scale factor into an exponent, so IEEE-754
/// rounding happens once. A literal past 512 bytes is decoded in a `gpa`
/// buffer freed before return.
pub fn parseReal(gpa: Allocator, text: []const u8) ValueError!f64 {
    // A scale factor is always the final character and never coexists with an
    // exponent, so one look at the last byte decides.
    var body = text;
    var suffix: []const u8 = "";
    if (text.len > 0) {
        if (scaleExp(text[text.len - 1])) |s| {
            suffix = s;
            body = text[0 .. text.len - 1];
        }
    }

    var small: [real_stack_bytes]u8 = undefined;
    const need = body.len + suffix.len;
    const buf = if (need <= small.len) small[0..need] else try gpa.alloc(u8, need);
    defer if (need > small.len) gpa.free(buf);
    var n: usize = 0;
    for (body) |c| {
        if (c == '_') continue; // §2.6.2: underscores are ignored
        buf[n] = c;
        n += 1;
    }
    @memcpy(buf[n..][0..suffix.len], suffix);
    n += suffix.len;
    assert(n <= need);
    assert(std.mem.findScalar(u8, buf[0..n], '_') == null);

    // The lexer only produces well-formed real literals; overflow yields inf,
    // which §2.6.2 leaves to IEEE 754; clamping would change the value.
    return std.fmt.parseFloat(f64, buf[0..n]) catch error.Overflow;
}

/// Decodes a `.string_literal`'s text (quotes included) into its bytes
/// (LRM §2.7 Table 2-2: \n \t \\ \" and \ddd, 1 to 3 octal digits).
/// An escape Table 2-2 does not list decodes to the escaped character alone
/// (`\q` is `q`), and an octal escape above `\377` keeps its low 8 bits;
/// `badEscape` finds both so the caller can report them first.
/// Asserts that `text` is quoted. The caller owns the result and frees it
/// with `gpa`; on error nothing is allocated.
pub fn stringContents(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    assert(text.len >= 2);
    assert(text[0] == '"' and text[text.len - 1] == '"');
    const body = text[1 .. text.len - 1];

    var out = try gpa.alloc(u8, body.len); // escapes only ever shrink
    errdefer gpa.free(out);

    var n: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
        assert(n <= i);
        const c = body[i];
        if (c != '\\') {
            out[n] = c;
            n += 1;
            i += 1;
            continue;
        }
        i += 1;
        if (i >= body.len) break;
        switch (body[i]) {
            'n' => {
                out[n] = '\n';
                i += 1;
            },
            't' => {
                out[n] = '\t';
                i += 1;
            },
            '0'...'7' => { // \ddd, 1 to 3 octal digits
                var v: u16 = 0;
                var k: usize = 0;
                while (k < 3 and i < body.len and body[i] >= '0' and body[i] <= '7') : (k += 1) {
                    v = v * 8 + (body[i] - '0');
                    i += 1;
                }
                out[n] = @truncate(v); // above \377 is refused first (`badEscape`)
            },
            // ponytail: backslash, quote and undefined escapes pass through
            // (an undefined one warns W0149, `badEscape`); add an arm only
            // for an escape with a distinct byte mapping.
            else => {
                out[n] = body[i];
                i += 1;
            },
        }
        n += 1;
    }
    assert(n <= body.len);
    return gpa.realloc(out, n);
}

/// Returns the first escape at or after byte `from` of a `.string_literal`'s
/// text (quotes included) that LRM §2.7 Table 2-2 does not define, or null.
pub fn badEscape(text: []const u8, from: u32) ?BadEscape {
    assert(text.len <= std.math.maxInt(u32));
    var i: u32 = @max(from, 1);
    const end: u32 = @intCast(text.len -| 1);
    while (i < end) : (i += 1) {
        if (text[i] != '\\' or i + 1 >= end) continue;
        const start = i;
        i += 1;
        switch (text[i]) {
            'n', 't', '\\', '"' => {},
            '0'...'7' => {
                var v: u16 = 0;
                var k: usize = 0;
                while (k < 3 and i < end and text[i] >= '0' and text[i] <= '7') : (k += 1) {
                    v = v * 8 + (text[i] - '0');
                    i += 1;
                }
                if (v > 0o377) return .{ .start = start, .end = i, .above_377 = true };
                i -= 1;
            },
            else => return .{ .start = start, .end = i + 1, .above_377 = false },
        }
    }
    assert(i >= end);
    return null;
}

/// Classifies the `.invalid` token spanning `span`.
///
/// §2.7: a string literal is "contained on a single line", and Table 2-2 has no
/// `\<newline>` escape. Continuing a string across a line is IEEE 1800 §5.9,
/// which some foundry models use, so `.line_continuation` lets the message name
/// the rule. The body is walked with the lexer's escape pairing, because in
/// `"a\\` the final backslash is half of an escape, not a continuation.
/// Asserts that `span` lies within `src`.
pub fn stringRunaway(src: []const u8, span: diag.Span) StringRunaway {
    assert(span.start <= span.end);
    assert(span.end <= src.len);
    if (span.start >= src.len or src[span.start] != '"') return .none;
    const text = src[span.start..span.end];
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"') return .none; // closed on its own line after all
        if (text[i] != '\\') continue;
        // A `\` with nothing left in the token is the one the lexer refused
        // to pair, i.e. it sat immediately before the newline that stopped it.
        if (i + 1 == text.len) {
            return if (span.end < src.len) .line_continuation else .unterminated;
        }
        i += 1; // skip the escaped character
    }
    return .unterminated;
}

// ---- private ----

fn decodeOnce(gpa: std.mem.Allocator) !void {
    const s = try stringContents(gpa, "\"a\\101\\q\"");
    defer gpa.free(s);
    try testing.expectEqualStrings("aAq", s);
}

test "scale factors: M is 1e6, m is 1e-3 (§2.6.2 Table 2-1)" {
    try testing.expectEqual(@as(f64, 1e6), try parseReal(testing.allocator, "1M"));
    try testing.expectEqual(@as(f64, 1e-3), try parseReal(testing.allocator, "1m"));
    try testing.expectEqual(@as(f64, 1e3), try parseReal(testing.allocator, "1K"));
    try testing.expectEqual(@as(f64, 1e3), try parseReal(testing.allocator, "1k"));
    try testing.expectEqual(@as(f64, 1e12), try parseReal(testing.allocator, "1T"));
    try testing.expectEqual(@as(f64, 1e9), try parseReal(testing.allocator, "1G"));
    try testing.expectEqual(@as(f64, 1e-6), try parseReal(testing.allocator, "1u"));
    try testing.expectEqual(@as(f64, 1e-9), try parseReal(testing.allocator, "1n"));
    try testing.expectEqual(@as(f64, 1e-12), try parseReal(testing.allocator, "1p"));
    try testing.expectEqual(@as(f64, 1e-15), try parseReal(testing.allocator, "1f"));
    try testing.expectEqual(@as(f64, 1e-18), try parseReal(testing.allocator, "1a"));
    try testing.expectEqual(@as(f64, 1300.0), try parseReal(testing.allocator, "1.3k"));
    try testing.expectEqual(@as(f64, 1.2e12), try parseReal(testing.allocator, "1.2E12"));
    try testing.expectEqual(@as(f64, 1234.567), try parseReal(testing.allocator, "1_234.5_67"));
    try testing.expectEqual(@as(f64, 236.123763e-12), try parseReal(testing.allocator, "236.123_763_e-12"));
}

test "§2.6.2 a scale factor rounds ONCE: 2.2n is parseFloat(\"2.2e-9\"), not 2.2 * 1e-9" {
    // §2.6.2 describes "24.7K" as "24.7 multiplied by 10 to the third power",
    // which read literally rounds twice (mantissa, then product). VerA parses
    // the joined text instead, so the value is the double nearest the literal;
    // §2.6.2 does not forbid that, and exact cases (1.3k) are unchanged. The
    // difference is 1 ulp for some literals and reaches emitted device text.
    try testing.expectEqual(@as(f64, 2.2e-9), try parseReal(testing.allocator, "2.2n"));
    // Both operands must be runtime `f64`s: Zig folds a comptime_float product
    // at arbitrary precision, which is exactly the double rounding under test.
    const mantissa: f64 = 2.2;
    const scale: f64 = 1e-9;
    try testing.expect((try parseReal(testing.allocator, "2.2n")) != mantissa * scale);
    try testing.expectEqual(@as(f64, 1.3e3), try parseReal(testing.allocator, "1.3k"));
}

test "stringContents decodes Table 2-2 escapes (§2.7)" {
    const s1 = try stringContents(testing.allocator, "\"line1\\nline2\\tend\"");
    defer testing.allocator.free(s1);
    try testing.expectEqualStrings("line1\nline2\tend", s1);

    const s2 = try stringContents(testing.allocator, "\"quote=\\\" slash=\\\\\"");
    defer testing.allocator.free(s2);
    try testing.expectEqualStrings("quote=\" slash=\\", s2);

    const s3 = try stringContents(testing.allocator, "\"A\\101\\0\"");
    defer testing.allocator.free(s3);
    try testing.expectEqualStrings("AA\x00", s3);
}

test "badEscape finds an octal escape above \\377 (§2.7)" {
    try testing.expectEqual(null, badEscape("\"\\377\\\\477 \\n\\t\\\"\"", 0));
    const b = badEscape("\"x\\4777\"", 0).?;
    try testing.expectEqual(BadEscape{ .start = 2, .end = 6, .above_377 = true }, b);
    try testing.expectEqual(null, badEscape("\"x\\4777\"", b.end));
}

test "badEscape finds an escape Table 2-2 does not list (§2.7)" {
    const b = badEscape("\"\\n\\q\\\\\"", 0).?;
    try testing.expectEqual(BadEscape{ .start = 3, .end = 5, .above_377 = false }, b);
    try testing.expectEqual(null, badEscape("\"\\n\\q\\\\\"", b.end));
}

test "stringContents corners: empty, undefined escape, short and long octal, the byte wrap" {
    const cases = [_]struct { text: []const u8, want: []const u8 }{
        .{ .text = "\"\"", .want = "" },
        .{ .text = "\"\\q\"", .want = "q" },
        // Table 2-2: fewer than three digits when the next byte is no octal digit.
        .{ .text = "\"\\08\"", .want = "\x008" },
        // At most three digits: 0o123 is 'S', and the 4 is a character.
        .{ .text = "\"\\1234\"", .want = "S4" },
        // 0o777 = 511 keeps its low byte; `badEscape` reports it first.
        .{ .text = "\"\\777\"", .want = "\xff" },
        .{ .text = "\"tab\\tnl\\n\"", .want = "tab\tnl\n" },
    };
    for (cases) |c| {
        const got = try stringContents(testing.allocator, c.text);
        defer testing.allocator.free(got);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "stringContents frees its buffer when any allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, decodeOnce, .{});
}

test "badEscape corners: from past the end, an escaped backslash, a short octal escape" {
    try testing.expectEqual(BadEscape{ .start = 1, .end = 3, .above_377 = false }, badEscape("\"\\q\"", 0).?);
    try testing.expectEqual(@as(?BadEscape, null), badEscape("\"\\q\"", 4));
    // `\\` then `q`: an escaped backslash and a plain q.
    try testing.expectEqual(@as(?BadEscape, null), badEscape("\"\\\\q\"", 0));
    // `\1` then `8`: Table 2-2's short form; the 8 is a character.
    try testing.expectEqual(@as(?BadEscape, null), badEscape("\"\\18\"", 0));
    // \400 is the first value above \377.
    try testing.expectEqual(BadEscape{ .start = 1, .end = 5, .above_377 = true }, badEscape("\"\\400\"", 0).?);
}

test "parseReal: any length, underscores free, overflow is inf" {
    // 512 bytes decode on the stack; 513 and far past it in a heap buffer
    // (the old 512-byte cap, E0134).
    var buf: [600]u8 = @splat('1');
    buf[1] = '.';
    try testing.expect(std.math.isFinite(try parseReal(testing.allocator, buf[0..512])));
    try testing.expect(std.math.isFinite(try parseReal(testing.allocator, buf[0..513])));
    // The rewritten scale factor is part of the text: 511 + "e-3".
    buf[511] = 'm';
    try testing.expectApproxEqRel(try parseReal(testing.allocator, buf[0..511]) * 1e-3, try parseReal(testing.allocator, buf[0..512]), 1e-15);
    // "0.", 100,000 zeros, "1e100001": 10^-100001 * 10^100001 = 1.0
    // exactly, which only a decoder that reads every digit gets.
    const long = try testing.allocator.alloc(u8, 100_010);
    defer testing.allocator.free(long);
    @memcpy(long[0..2], "0.");
    @memset(long[2..100_002], '0');
    @memcpy(long[100_002..], "1e100001");
    try testing.expectEqual(@as(f64, 1.0), try parseReal(testing.allocator, long));
    // `_` is dropped before decoding.
    var spaced: [1022]u8 = undefined;
    spaced[0] = '1';
    spaced[1] = '.';
    for (0..510) |i| {
        spaced[2 + 2 * i] = '1';
        spaced[3 + 2 * i] = '_';
    }
    try testing.expect(std.math.isFinite(try parseReal(testing.allocator, &spaced)));
    // §2.6.2 leaves overflow to IEEE 754: inf, not an error.
    try testing.expect(std.math.isPositiveInf(try parseReal(testing.allocator, "1e400")));
    try testing.expectEqual(@as(f64, 0), try parseReal(testing.allocator, "1e-400"));
}
