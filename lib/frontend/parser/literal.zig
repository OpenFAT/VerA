//! Literal values: §2.6.1 integer and §2.6.2 real numbers and §2.7 strings,
//! decoded once from their token text into `Ast` literal nodes and interned
//! strings. The token stream stores only {tag, start}, so this is the one
//! place a literal's value is computed.
//!
//! LRM clauses cited: §2.6.1, §2.6.2, §2.7, §3.3, §9.4.2.
//!
//! Contents:
//! - `pub fn parseNumber(self: *Parser) Error!Ast.ExprId`
//! - `pub fn internString(self: *Parser, tok: u32) Error!Ast.StrId`

const std = @import("std");
const assert = std.debug.assert;
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const lexer = @import("../lexer.zig");
const token_value = @import("../token_value.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

/// §2.6.1 integer (incl. sized/based) and §2.6.2 real (exponent + SI scale
/// factor) literals. Values are computed here because the token stream
/// stores only {tag,start}.
pub fn parseNumber(self: *Parser) Error!Ast.ExprId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const tok = self.pos;
    self.pos += 1;

    if (self.tags[tok] == .int_literal) {
        const text = gluedNumberText(self, tok);
        const integer = @import("kernels").Integer;
        const lit = integer.parse(self.arena, text) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.MissingBase => self.failAt(tok, .E0131, "`{s}`", .{text}),
            error.MissingDigits => self.failAt(tok, .E0132, "`{s}`", .{text}),
            error.Overflow => self.failAt(tok, .E1019, "`{s}`", .{text}),
            else => self.failAt(tok, .E0133, "`{s}`", .{text}),
        };
        const digit_bits = unsizedDigitBits(text, lit.sized);
        if (lit.asInt()) |value| {
            defer self.arena.free(lit.planes);
            // IEEE 1364-2005 §3.5.1: an unsized constant is 32 bits here, so a
            // signed based one whose digits fill bit 31 is negative:
            // 'shffffffff is -1. `integer.parse` holds unsized digits in 64.
            const wraps = !lit.sized and lit.signed and std.mem.findScalar(u8, text, '\'') != null and
                value > std.math.maxInt(i32) and value <= std.math.maxInt(u32);
            return self.file.exprs.addIntLiteral(self.arena, tok, .{
                .value = if (wraps) value - (1 << 32) else value,
                .width = if (lit.sized) lit.width else 0,
                .signed = lit.signed,
                .radix = integer.radixOf(text),
                .digit_bits = @intCast(@min(digit_bits, std.math.maxInt(u16))),
            });
        }
        // A known unsized based constant holds its leading zero digits too
        // (VD-131); its planes were allocated for every digit.
        var wide = lit;
        if (!lit.hasUnknown()) wide.width = @max(lit.width, digit_bits);
        return self.file.exprs.addLogic(self.arena, tok, wide);
    }

    const text = self.tokenText(tok);
    if (self.in_digital_delay and self.attr_depth == 0 and token_value.scaleExp(text[text.len - 1]) != null)
        try self.report(tok, .E0247, "`{s}` in a digital delay; use decimal or scientific notation in the module's time units", .{text});
    // §2.6.2 decoding (`_` removal, the Table 2-1 scale factor) has one home,
    // `lexer.parseReal`. It applies the scale to the text and rounds once;
    // `mantissa * scale` would round twice and can be off by 1 ulp.
    const v = token_value.parseReal(self.arena, text) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.Overflow => self.failAt(tok, .E0133, "`{s}`", .{text}),
    };
    return self.file.exprs.addReal(self.arena, tok, v);
}

/// Interns token `tok`'s §2.7 string contents, escapes decoded by
/// `lexer.stringContents`, then (outside digital mode) §3.3's literal to
/// string conversion applied. Allocates only when the literal contains a
/// backslash.
pub fn internString(self: *Parser, tok: u32) Error!Ast.StrId {
    assert(self.pos < self.tags.len);
    const pos_in = self.pos;
    defer assert(self.pos >= pos_in);
    const raw = self.tokenText(tok);
    const body = if (raw.len >= 2) raw[1 .. raw.len - 1] else "";
    if (std.mem.findScalar(u8, body, '\\') == null) {
        return self.file.intern(self.arena, body);
    }
    const decoded = try token_value.stringContents(self.arena, raw);
    // Direct display formats retain octal NUL bytes (§9.4.2). Digital
    // string-variable conversion is not part of this executor yet.
    if (self.digital) return self.file.intern(self.arena, decoded);
    // §3.3 spells the conversion out in three steps: "all the \0 characters
    // are ignored", an empty remainder becomes the empty string, otherwise
    // the rest is kept, so `"hello\0world"` is `helloworld`, not a C-style
    // truncation at the NUL.
    var n: usize = 0;
    for (decoded) |c| {
        if (c == 0) continue;
        decoded[n] = c;
        n += 1;
    }
    return self.file.intern(self.arena, decoded[0..n]);
}

// ---- private ----

/// An unsized based §2.6.1 constant's digits times the bits per digit
/// (VD-131); 0 for a sized or a decimal one.
fn unsizedDigitBits(text: []const u8, sized: bool) u32 {
    const q = std.mem.findScalar(u8, text, '\'') orelse return 0;
    if (sized) return 0;
    var i = q + 1;
    if (i < text.len and (text[i] | 0x20) == 's') i += 1;
    const per: u32 = switch (text[i] | 0x20) {
        'b' => 1,
        'o' => 3,
        'h' => 4,
        else => return 0,
    };
    var n: u32 = 0;
    for (text[i + 1 ..]) |c| {
        if (c != '_' and !std.ascii.isWhitespace(c)) n +|= per;
    }
    return n;
}

/// The text `integer.parse` must see to name a malformed §2.6.1 number:
/// normally the token, or the token plus the one glued to it.
///
/// The lexer stops a number where §2.6.1 does, so the forms the clause calls
/// illegal (`4' h5`, `8'y11`, Example 1's `4af`) arrive as a literal plus a
/// separate token. When that token begins exactly where this one ends, the
/// user wrote one number, and the decoder names the rule it broke instead of
/// the parser asking for a `;` mid-number. `4 af` is not adjacent and keeps
/// that message. `.apostrophe_lbrace` is excluded: `2'{1}` is §4.2.14's
/// assignment pattern.
fn gluedNumberText(self: *const Parser, tok: u32) []const u8 {
    const text = self.tokenText(tok);
    const start = self.starts[tok];
    const next = self.starts[tok + 1]; // the stream always ends in `.eof`
    if (next != start + text.len) return text;
    switch (self.tags[tok + 1]) {
        // Only when the glued text is all hex digits, which makes it a number
        // with the base format left out. `1g` is not: §2.6.2's scale factors
        // have no `g`, so it is an integer followed by an identifier (E0207).
        .identifier => for (self.tokenText(tok + 1)) |c| {
            if (!lexer.isBasedDigit(c, 16)) return text;
        },
        // Only an apostrophe: a stray backtick is the preprocessor's, and
        // gluing it would decode as a bad digit and say so (E0133).
        .invalid => if (self.src[next] != '\'') return text,
        else => return text, // else: nothing else can be the glued remainder of a based number
    }
    return self.src[start .. next + self.tokenText(tok + 1).len];
}
