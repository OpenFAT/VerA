//! Lexer: preprocessed text in, one `{tag, start}` token row per token out
//! (`TokenList`), ending with `.eof`. `Lexer.next` depends only on `(src,
//! pos)`, so a token's end is recovered by re-lexing from its start
//! (`tokenEnd`, `tokenSpan`) and no length is stored. The lexer never fails
//! except on OOM: malformed text becomes one `.invalid` row for the parser to
//! report. Literal values are decoded later, from the token's text
//! (token_value.zig).
//! Cites: LRM §2.1-§2.9, Table 2-1; IEEE 1364-2005 §3.5.1, §19 (the
//! directives the preprocessor passes through), A.6.5.
//!
//! Only the identifier scan is a vector block compare (`identEnd`, probed in
//! tests/codegen_probe.zig); the white space and literal scans stay per-byte,
//! where a block lost.
//!
//! Contents:
//! - `pub const TokenList = std.MultiArrayList(token.Stored)`
//! - `pub const source_bytes_max: u32`
//! - `pub const Error = error{OutOfMemory}`
//! - `pub const Seed = struct`
//! - `pub const Lexer = struct`, `Lexer.next(self: *Lexer) token.Stored`
//! - `pub fn tokenize(gpa: Allocator, src: []const u8, seed: ?Seed) Error!TokenList`
//! - `pub fn tokenEnd(src: []const u8, start: u32) u32`
//! - `pub fn tokenText(src: []const u8, start: u32) []const u8`
//! - `pub fn tokenSpan(src: []const u8, starts: []const u32, tok: u32) diag.Span`
//! - `pub fn isSpace(c: u8) bool`
//! - `pub fn isIdentChar(c: u8) bool`
//! - `pub fn identEnd(s: []const u8, i: usize) usize`
//! - `pub fn escapedEnd(s: []const u8, i: usize) usize`
//! - `pub fn isBasedDigit(c: u8, radix: u8) bool`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const token = @import("token.zig");
const keyword = @import("keyword.zig");
const token_value = @import("token_value.zig");
const scaleExp = token_value.scaleExp;
const stringRunaway = token_value.stringRunaway;
const StringRunaway = token_value.StringRunaway;
const testing = std.testing;

/// Token rows in SoA form: the `.tag` and `.start` columns, 5 bytes a row.
pub const TokenList = std.MultiArrayList(token.Stored);

/// Longest text the lexer takes: a token start is a `u32` byte offset. The
/// preprocessor refuses a longer text first (E1013), so past it is a bug.
pub const source_bytes_max: u32 = std.math.maxInt(u32);

/// Every way `tokenize` fails. Malformed text is never an error: it lexes to
/// `.invalid` rows.
pub const Error = error{
    /// The token list could not grow. Nothing is returned; the partial list
    /// is freed.
    OutOfMemory,
};

/// Already-lexed tokens for a prefix of the text, replayed by `tokenize`
/// instead of re-scanned (`pp.preludeTokens` makes one for the annex D/E
/// prelude). `len` is the prefix's byte length; the columns are its tokens
/// without `.eof`, every `start` an absolute offset below `len`. The prefix
/// must end between tokens.
pub const Seed = struct {
    tags: []const token.Tag,
    starts: []const u32,
    len: u32,
};

/// A cursor over preprocessed source. `pos` is the only state, so a scan
/// from any token start reproduces that token.
pub const Lexer = struct {
    src: []const u8,
    pos: u32 = 0,

    // The scan's whole state: three words in registers (4 B of padding after
    // `pos`). A u32 `pos` matches the u32 token starts.
    comptime {
        assert(@sizeOf(Lexer) <= 24);
    }

    /// Scans the token at `pos` and advances past it (LRM §2.2). Returns
    /// `.eof` at the end, repeatedly. Asserts that `pos` is within the
    /// source; every other token advances it by at least one byte, which is
    /// what bounds `tokenize`'s loop.
    pub fn next(self: *Lexer) token.Stored {
        assert(self.pos <= self.src.len);
        assert(self.src.len <= source_bytes_max);
        // §2.3 white space only separates. The preprocessor strips every §2.4
        // comment (pp/comments.zig), so `//` or `/*` here is two operators, as
        // IEEE 1364 §19.3.1 makes of macro text pasted into one.
        while (self.pos < self.src.len and isSpace(self.src[self.pos])) self.pos += 1;

        const start = self.pos;
        if (start >= self.src.len) return .{ .tag = .eof, .start = start };

        const tag: token.Tag = switch (self.src[start]) {
            '0'...'9' => self.lexNumber(), // §2.6
            'a'...'z', 'A'...'Z', '_' => self.lexIdentOrKeyword(), // §2.8, §2.8.2
            '\\' => self.lexEscapedIdentifier(), // §2.8.1
            '$' => self.lexSystemIdentifier(), // §2.8.3
            '"' => self.lexString(), // §2.7
            '\'' => self.lexApostrophe(), // §2.6.1 based constant / §4.2.14 '{
            '`' => self.lexDirective(), // the directives the preprocessor passes through
            else => self.lexOperator(), // §2.5, §2.9
        };
        assert(self.pos > start);
        assert(self.pos <= self.src.len);
        return .{ .tag = tag, .start = start };
    }

    // ---- private ----

    /// LRM §2.6.1 (integer constants) and §2.6.2 (real constants). The cursor
    /// is on a decimal digit. Underscores are legal anywhere but first.
    fn lexNumber(self: *Lexer) token.Tag {
        const start = self.pos;
        assert(std.ascii.isDigit(self.src[start]));
        self.skipUnsignedNumber(); // `size`, or the whole integer/mantissa

        // §2.6.1 sized based constant: size ' [s|S] base digits.
        //
        // White space may sit between the size and the apostrophe. §2.6.1 only
        // forbids it between the apostrophe and the base character, and says "it
        // shall be legal to macro substitute these three tokens": `8 `BASE `DIGITS`
        // arrives as `8 'h A5`, with white space at both joins. Footnote 1's
        // "embedded spaces are illegal" applies to each single-token production.
        //
        // Not after a `#`: A.6.5's delay_value there is an unsigned_number,
        // never a size, so `#1 'h123` is delay 1, then the constant 'h123.
        // Read from the bytes, so `tokenEnd` re-lexes the same span.
        {
            var i = self.pos;
            while (i < self.src.len and isSpace(self.src[i])) i += 1;
            if (i < self.src.len and self.src[i] == '\'' and (i == self.pos or !afterHash(self.src, start))) {
                const save = self.pos;
                self.pos = i;
                // Not a base_format (e.g. `2 '{`): the number ends before the
                // white space, which goes back to the stream untouched.
                if (self.lexBasedTail()) |tag| return tag;
                self.pos = save;
            }
        }

        // §2.6.2: a decimal point needs at least one digit on each side, so
        // `9.` and `4.E3` are two tokens and `.12` never starts a number.
        var is_real = false;
        if (self.peek(0) == '.' and std.ascii.isDigit(self.peek(1))) {
            self.pos += 1;
            self.skipUnsignedNumber();
            is_real = true;
        }

        // §2.6.2: an exponent or a scale factor, never both.
        const e = self.peek(0);
        if (e == 'e' or e == 'E') {
            if (std.ascii.isDigit(self.peek(1))) {
                self.pos += 2;
                self.skipUnsignedNumber();
                return .real_literal;
            }
            if ((self.peek(1) == '+' or self.peek(1) == '-') and std.ascii.isDigit(self.peek(2))) {
                self.pos += 3;
                self.skipUnsignedNumber();
                return .real_literal;
            }
        } else if (scaleExp(e) != null and !isIdentChar(self.peek(1))) {
            // Table 2-1 suffix, and only when it is not the head of an
            // identifier (`4af` is then `4` + `af`, illegal downstream as §2.6.1
            // requires; `7k` is a real).
            self.pos += 1;
            return .real_literal;
        }
        assert(self.pos > start);
        return if (is_real) .real_literal else .int_literal;
    }

    /// LRM §2.6.1 based-constant tail: `' [s|S] base_char digits`. The cursor
    /// is on the apostrophe. Returns null, the cursor untouched, when this is
    /// not a base_format.
    ///
    /// White space is legal between the base format and the digits ("optionally
    /// preceded by white space", §2.6.1, as in `'h 837FF`) but not inside the
    /// apostrophe group (`8 ' h`). It stays inside the token span, and
    /// `integer.parse` skips it at the same place.
    fn lexBasedTail(self: *Lexer) ?token.Tag {
        assert(self.src[self.pos] == '\'');
        var i = self.pos + 1;
        if (i < self.src.len and (self.src[i] == 's' or self.src[i] == 'S')) i += 1; // signed designator
        if (i >= self.src.len) return null;
        const radix: u8 = switch (std.ascii.toLower(self.src[i])) {
            'b' => 2,
            'o' => 8,
            'd' => 10,
            'h' => 16,
            else => return null,
        };
        i += 1;
        const after_base = i;
        while (i < self.src.len and isSpace(self.src[i])) i += 1;
        const digits = i;
        while (i < self.src.len and isBasedDigit(self.src[i], radix)) i += 1;
        // §2.6.1: the base format must be followed by an unsigned number. With
        // none there the token ends at the base format and the white space goes
        // back to the stream, so the next token is whatever really follows.
        if (i == digits) {
            self.pos = after_base;
            return .invalid;
        }
        assert(i > after_base);
        self.pos = i;
        return .int_literal;
    }

    /// LRM §2.6.1 unsigned_number: decimal digits with `_` separators. A
    /// trailing `_` is legal (`236.123_763_e-12` is an LRM example).
    fn skipUnsignedNumber(self: *Lexer) void {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (!std.ascii.isDigit(c) and c != '_') break;
            self.pos += 1;
        }
        assert(self.pos >= start);
        assert(self.pos <= self.src.len);
    }

    /// LRM §2.8 simple identifier or §2.8.2 keyword. Escaped identifiers never
    /// reach here, so they are never looked up as keywords.
    fn lexIdentOrKeyword(self: *Lexer) token.Tag {
        const start = self.pos;
        self.pos = @intCast(identEnd(self.src, self.pos));
        assert(self.pos > start);
        return keyword.lookupKeyword(self.src[start..self.pos]) orelse .identifier;
    }

    /// LRM §10.6 `begin_keywords / `end_keywords, §10.3 `default_transition,
    /// and IEEE 1364 §19.2, §19.6 and §19.9's directives: the ones the
    /// preprocessor passes through because only the parser can check where
    /// they sit (`passed_directives`). Any other backtick is one `.invalid` byte.
    fn lexDirective(self: *Lexer) token.Tag {
        assert(self.src[self.pos] == '`');
        const name = self.pos + 1; // past the '`'
        const end: u32 = @intCast(identEnd(self.src, name));
        const tag = passed_directives.get(self.src[name..end]) orelse {
            self.pos = name;
            return .invalid;
        };
        assert(end > name);
        self.pos = end;
        return tag;
    }

    /// LRM §2.8.1: `\` then printable ASCII 33 to 126, terminated by white
    /// space. Neither the backslash nor the terminator is part of the
    /// identifier, but the backslash is inside the token span (the parser
    /// strips it).
    fn lexEscapedIdentifier(self: *Lexer) token.Tag {
        assert(self.src[self.pos] == '\\');
        const body = self.pos + 1;
        self.pos = @intCast(escapedEnd(self.src, body));
        return if (self.pos == body) .invalid else .escaped_identifier;
    }

    /// LRM §2.8.3: `$` immediately followed by [a-zA-Z0-9_$]+ (no white space).
    fn lexSystemIdentifier(self: *Lexer) token.Tag {
        assert(self.src[self.pos] == '$');
        self.pos += 1;
        const body = self.pos;
        self.pos = @intCast(identEnd(self.src, self.pos));
        return if (self.pos == body) .invalid else .system_identifier;
    }

    /// LRM §2.7: double-quoted, single line, `\` escapes (decoded by
    /// `token_value.stringContents`). An unterminated string ends at the
    /// newline or the end of the text.
    fn lexString(self: *Lexer) token.Tag {
        assert(self.src[self.pos] == '"');
        self.pos += 1;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\n') break; // §2.7: contained on a single line
            self.pos += 1;
            if (c == '\\') {
                if (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            if (c == '"') return .string_literal;
        }
        assert(self.pos == self.src.len or self.src[self.pos] == '\n');
        return .invalid;
    }

    /// `'{` assignment pattern (§4.2.14) or an unsized based constant (§2.6.1).
    fn lexApostrophe(self: *Lexer) token.Tag {
        const start = self.pos;
        assert(self.src[start] == '\'');
        if (self.peek(1) == '{') {
            self.pos += 2;
            return .apostrophe_lbrace;
        }
        if (self.lexBasedTail()) |t| return t;
        assert(self.pos == start);
        self.pos += 1;
        return .invalid;
    }

    /// LRM §2.5 operators (longest match) and §2.9 attribute delimiters.
    /// Digital-only sequences with no tag (`=>`, `*>`, `&&&`) are consumed
    /// whole as `.invalid` so the parser reports one error, not three.
    fn lexOperator(self: *Lexer) token.Tag {
        const start = self.pos;
        const c = self.src[self.pos];
        self.pos += 1;
        const tag: token.Tag = switch (c) {
            '+' => .plus,
            // §5.10.4/A.6.5 `event_trigger ::= -> hierarchical_event_identifier`,
            // which §5.10 also allows in analog blocks.
            '-' => if (self.eat('>')) .arrow else .minus,
            '*' => if (self.eat('*')) .star_star // §4.2.4 power
            else if (self.eat(')')) .attr_close // §2.9
            else if (self.eat('>')) .invalid // '*>' specify path
            else .star,
            '/' => .slash, // comments were consumed before the token started
            '%' => .percent,
            '<' => if (self.eat('+')) .contribute // §5.6
            else if (self.eat('<')) (if (self.eat('<')) .lt_lt_lt else .lt_lt) // §4.2.11
            else if (self.eat('=')) .lt_eq else .lt,
            '>' => if (self.eat('>')) (if (self.eat('>')) .gt_gt_gt else .gt_gt) else if (self.eat('=')) .gt_eq else .gt,
            '=' => if (self.eat('=')) (if (self.eat('=')) .eq_eq_eq else .eq_eq) // §4.2.6/§4.2.7
            else if (self.eat('>')) .invalid // '=>' specify path
            else .assign_eq,
            '!' => if (self.eat('=')) (if (self.eat('=')) .bang_eq_eq else .bang_eq) else .bang,
            '&' => if (self.eat('&')) (if (self.eat('&')) .invalid else .amp_amp) else .amp, // '&&&' is specify-only
            '|' => if (self.eat('|')) .pipe_pipe else .pipe,
            '~' => if (self.eat('^')) .tilde_caret // §4.2.9/§4.2.10 xnor
            else if (self.eat('&')) .tilde_amp else if (self.eat('|')) .tilde_pipe else .tilde,
            '^' => if (self.eat('~')) .caret_tilde else .caret,
            '?' => .question,
            ':' => .colon,
            // §2.9 attribute instance. A.6.5's `@(*)` lexes as `attr_open`
            // `)`, and the parser's event control reads it back.
            '(' => if (self.eat('*')) .attr_open else .lparen,
            ')' => .rparen,
            '[' => .lbracket,
            ']' => .rbracket,
            '{' => .lbrace,
            '}' => .rbrace,
            ';' => .semicolon,
            ',' => .comma,
            '.' => .dot, // §2.6.2 forbids `.5`, so a dot is always punctuation
            '@' => .at,
            '#' => .hash,
            // §2.8.4: the preprocessor consumes every `directive; one reaching
            // the lexer is an unknown or unbalanced directive.
            else => .invalid,
        };
        // Longest operator: three bytes (`<<<`, `===`, `&&&`).
        assert(self.pos - start <= 3);
        return tag;
    }

    /// The byte `n` past the cursor, or 0 past the end (NUL never appears in
    /// a token, so 0 matches no scanner's test).
    fn peek(self: *const Lexer, n: u32) u8 {
        assert(n <= 2);
        // usize: `pos + n` may pass maxInt(u32) on a source of that length.
        const i = @as(usize, self.pos) + n;
        return if (i < self.src.len) self.src[i] else 0;
    }

    fn eat(self: *Lexer, c: u8) bool {
        assert(c != 0);
        if (self.pos < self.src.len and self.src[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }
};

/// The directives the preprocessor passes through as words (`lexDirective`),
/// without their backtick.
const passed_directives = std.StaticStringMap(token.Tag).initComptime(.{
    .{ "begin_keywords", .dir_begin_keywords },
    .{ "end_keywords", .dir_end_keywords },
    .{ "resetall", .dir_resetall },
    .{ "default_nettype", .dir_outside_module },
    .{ "unconnected_drive", .dir_outside_module },
    .{ "nounconnected_drive", .dir_outside_module },
    .{ "default_transition", .dir_outside_module },
});

/// Lexes all of `src` into a new list ending with `.eof`; with a `seed`, its
/// rows are copied and only the text after `seed.len` is scanned, which gives
/// the same rows because `next` carries no state across tokens.
/// The caller owns the list and frees it with `list.deinit(gpa)`.
/// Asserts that `src.len <= source_bytes_max` and that the seed lies within
/// `src` with equal-length columns.
pub fn tokenize(gpa: Allocator, src: []const u8, seed: ?Seed) Error!TokenList {
    assert(src.len <= source_bytes_max);
    var list: TokenList = .empty;
    errdefer list.deinit(gpa);
    var start: u32 = 0;
    if (seed) |s| {
        assert(s.tags.len == s.starts.len);
        assert(s.len <= src.len);
        // About 4 source bytes per token, over the part still to be scanned.
        try list.ensureTotalCapacity(gpa, s.tags.len + (src.len - s.len) / 4 + 8);
        list.len = s.tags.len;
        @memcpy(list.items(.tag), s.tags);
        @memcpy(list.items(.start), s.starts);
        start = s.len;
    } else {
        // About 4 source bytes per token including separators: one
        // allocation in practice.
        try list.ensureTotalCapacity(gpa, src.len / 4 + 8);
    }

    var lx: Lexer = .{ .src = src, .pos = start };
    // Every token but `.eof` advances by a byte, so `src.len - start + 1`
    // passes bound the loop.
    const passes_max = src.len - start + 1;
    for (0..passes_max) |_| {
        const t = lx.next();
        try list.append(gpa, t);
        if (t.tag == .eof) break;
    } else unreachable;
    assert(list.items(.tag)[list.len - 1] == .eof);
    return list;
}

/// Returns the end offset of the token starting at `start`, by re-lexing it
/// (one token scan). Asserts that `start <= src.len`.
pub fn tokenEnd(src: []const u8, start: u32) u32 {
    assert(start <= src.len);
    var relex: Lexer = .{ .src = src, .pos = start };
    _ = relex.next();
    assert(relex.pos >= start);
    return relex.pos;
}

/// Returns the source text of the token starting at `start` (one token scan).
/// Asserts that `start <= src.len`.
pub fn tokenText(src: []const u8, start: u32) []const u8 {
    const end = tokenEnd(src, start);
    assert(end <= src.len);
    return src[start..end];
}

/// Returns the byte range of token `tok`, for a diagnostic caret. `starts` is
/// the token list's `.start` column; the end costs one re-lex. An index past
/// the column is a zero-width span at the end of the text, for "expected X,
/// found end of file".
pub fn tokenSpan(src: []const u8, starts: []const u32, tok: u32) diag.Span {
    assert(src.len <= source_bytes_max);
    if (tok >= starts.len) {
        const end: u32 = @intCast(src.len);
        return .{ .start = end, .end = end };
    }
    const start = starts[tok];
    const span: diag.Span = .{ .start = start, .end = tokenEnd(src, start) };
    assert(span.end >= span.start);
    return span;
}

/// §2.3: "White space shall contain the characters for spaces, tabs,
/// newlines, and formfeeds." Carriage return is added so CRLF source reads as
/// LF source; vertical tab, which `std.ascii.isWhitespace` also admits, is not
/// white space and lexes as `.invalid`. The preprocessor uses this one too.
pub fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

/// §2.8: letters, digits, `$` and `_` (only the first character is restricted).
pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// Returns the first index at or after `i` whose byte is not `isIdentChar`,
/// else `s.len`. Asserts that `i <= s.len`.
pub fn identEnd(s: []const u8, i: usize) usize {
    assert(i <= s.len);
    var k = i;
    // One block compare and one predictable branch per 32 bytes, in place of
    // a loop exit mispredicted at the end of nearly every identifier: lexing
    // the five largest compact models fell from 6.16 to 5.17 ms. A plain
    // 64-byte block loop vectorizes too, but must rescan its block per byte
    // to find the end, and measured 8.25 ms. The loop below is the tail, the
    // no-vector fallback, and the oracle the test checks this against.
    if (std.simd.suggestVectorLength(u8)) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = @Int(.unsigned, lanes);
        while (k + lanes <= s.len) : (k += lanes) {
            const b: V = s[k..][0..lanes].*;
            const letter: Mask = @bitCast((b | @as(V, @splat(0x20))) -% @as(V, @splat('a')) < @as(V, @splat(26)));
            const digit: Mask = @bitCast(b -% @as(V, @splat('0')) < @as(V, @splat(10)));
            const under: Mask = @bitCast(b == @as(V, @splat('_')));
            const dollar: Mask = @bitCast(b == @as(V, @splat('$')));
            const out = ~(letter | digit | under | dollar);
            if (out != 0) return k + @ctz(out);
        }
    }
    while (k < s.len and isIdentChar(s[k])) k += 1;
    assert(k >= i);
    return k;
}

/// Returns where the §2.8.1 escaped identifier whose body starts at `i` (just
/// past the `\`) ends. The body is printable ASCII 33 to 126; any other byte
/// ends it. Asserts that `i <= s.len`.
pub fn escapedEnd(s: []const u8, i: usize) usize {
    assert(i <= s.len);
    var k = i;
    while (k < s.len and s[k] >= 33 and s[k] <= 126) k += 1;
    assert(k == s.len or s[k] < 33 or s[k] > 126);
    return k;
}

/// Returns whether `c` is a §2.6.1 digit of `radix`, `_`, or a four-state digit
/// (x/X/z/Z/?, decoded by `integer.parse`). The parser calls it with radix 16 to
/// tell §2.6.1 Example 1's `4af` (a based number missing its base format) from
/// `1g` (a number and an identifier). Asserts that `radix` is 2, 8, 10 or 16.
pub fn isBasedDigit(c: u8, radix: u8) bool {
    assert(radix == 2 or radix == 8 or radix == 10 or radix == 16);
    return switch (c) {
        '_', 'x', 'X', 'z', 'Z', '?' => true,
        '0'...'9' => c - '0' < radix,
        'a'...'f', 'A'...'F' => radix == 16,
        else => false,
    };
}

// ---- private ----

/// Whether the last non-space byte before `at` is a `#`.
fn afterHash(src: []const u8, at: usize) bool {
    assert(at <= src.len);
    var k = at;
    while (k > 0 and isSpace(src[k - 1])) k -= 1;
    return k > 0 and src[k - 1] == '#';
}

fn expectTags(src: []const u8, expected: []const token.Tag) !void {
    var list = try tokenize(testing.allocator, src, null);
    defer list.deinit(testing.allocator);
    try testing.expectEqualSlices(token.Tag, expected, list.items(.tag));
}

fn tokenizeMany(gpa: std.mem.Allocator) !void {
    // Past the up-front estimate of one token per 4 bytes, so the list grows.
    const semis: [100]u8 = @splat(';');
    var list = try tokenize(gpa, &semis, null);
    defer list.deinit(gpa);
    try testing.expectEqual(@as(usize, 101), list.len);
}

test "operators are longest-match (§2.5)" {
    try expectTags("< <= <+ << <<< > >= >> >>> = == === ! != !== ** * ~^ ^~ ~& ~| && || (* *) '{", &.{
        .lt,                .lt_eq,    .contribute,  .lt_lt,       .lt_lt_lt,
        .gt,                .gt_eq,    .gt_gt,       .gt_gt_gt,    .assign_eq,
        .eq_eq,             .eq_eq_eq, .bang,        .bang_eq,     .bang_eq_eq,
        .star_star,         .star,     .tilde_caret, .caret_tilde, .tilde_amp,
        .tilde_pipe,        .amp_amp,  .pipe_pipe,   .attr_open,   .attr_close,
        .apostrophe_lbrace, .eof,
    });
    // §5.10.4 `->` is a real token: it triggers a named analog event.
    try expectTags("-> -", &.{ .arrow, .minus, .eof });
    // No tag for these; each is consumed whole so the parser reports once.
    try expectTags("=> *> &&&", &.{ .invalid, .invalid, .invalid, .eof });
    // §2.9 attributes nest no deeper than one token pair.
    try expectTags("(* full_case = 1 *)", &.{
        .attr_open, .identifier, .assign_eq, .int_literal, .attr_close, .eof,
    });
}

test "white space separates; comment characters are operators here (§2.3, §2.4)" {
    try expectTags("a\t\n\x0cb\r\n", &.{ .identifier, .identifier, .eof });
    // The preprocessor removes every §2.4 comment (pp/test.zig "§2.4 comments
    // vanish"). What looks like one here was pasted by macros, and IEEE 1364
    // §19.3.1 forbids splitting macro text across a comment: `/` `/`, `/` `*`.
    try expectTags("x / / y", &.{ .identifier, .slash, .slash, .identifier, .eof });
    try expectTags("x //y", &.{ .identifier, .slash, .slash, .identifier, .eof });
    try expectTags("8 /* 2", &.{ .int_literal, .slash, .star, .int_literal, .eof });
}

test "identifiers, keywords, escaped and system names (§2.8)" {
    try expectTags("module _bus3 n$657 $temperature \\gain+trim  V", &.{
        .kw_module, .identifier, .identifier, .system_identifier, .escaped_identifier, .identifier, .eof,
    });
    // §2.8.2: an escaped keyword is an ordinary identifier.
    try expectTags("\\module ", &.{ .escaped_identifier, .eof });
    // §2.8.3: `$` must be followed immediately by a name character.
    try expectTags("$ temperature", &.{ .invalid, .identifier, .eof });
    // Annex B out-of-scope keywords still lex as reserved, never identifiers.
    try expectTags("primitive wreal", &.{ .kw_reserved, .kw_reserved, .eof });
    // §5.10.1 edges carry their own tags: an event expression tells them apart.
    try expectTags("posedge negedge", &.{ .kw_posedge, .kw_negedge, .eof });
}

test "numbers: bases, reals, scale factors (§2.6)" {
    try expectTags("27_195 16'b0011_0101 12'o7460 32'h12ab_f001 8'HAf 'h837ff 4'b01xz", &.{
        .int_literal, .int_literal, .int_literal, .int_literal, .int_literal, .int_literal, .int_literal, .eof,
    });
    try expectTags("2394.26331 1.2E12 1.30e-2 23E10 1.3u 7k 236.123_763_e-12", &.{
        .real_literal, .real_literal, .real_literal, .real_literal,
        .real_literal, .real_literal, .real_literal, .eof,
    });
    // §2.6.2: a digit is required on each side of the point.
    try expectTags(".12", &.{ .dot, .int_literal, .eof });
    try expectTags("9.", &.{ .int_literal, .dot, .eof });
    try expectTags("4.E3", &.{ .int_literal, .dot, .identifier, .eof });
    // §2.6.1 Example 1: `4af` is illegal hex; `a` is not eaten as a scale factor.
    try expectTags("4af", &.{ .int_literal, .identifier, .eof });
    // §2.6.1: the base format must be followed by digits (`8 'd -6` is illegal).
    try expectTags("8'd -6", &.{ .invalid, .minus, .int_literal, .eof });
    // A quote that is not a base_format leaves the number intact.
    try expectTags("2'{1}", &.{ .int_literal, .apostrophe_lbrace, .int_literal, .rbrace, .eof });
    // §2.6.1 "it shall be legal to macro substitute these three tokens": after
    // substitution the three arrive separated by white space, and the size
    // still joins to the base format. Both spacings are one literal.
    try expectTags("8 'h A5", &.{ .int_literal, .eof });
    try expectTags("32\n'h 12ab_f001", &.{ .int_literal, .eof });
    // A.6.5: after `#` the number is a delay_value, never a size, so the
    // white space ends it (IEEE 1364-2005 §3.5.1's three tokens do not form).
    try expectTags("#1 'h123", &.{ .hash, .int_literal, .int_literal, .eof });
    try expectTags("# 1 'h123", &.{ .hash, .int_literal, .int_literal, .eof });
    // White space before an assignment pattern is not joined: `'{` is
    // not a base_format, so the number ends at its digits (§4.2.14).
    try expectTags("2 '{1}", &.{ .int_literal, .apostrophe_lbrace, .int_literal, .rbrace, .eof });
}

test "strings (§2.7)" {
    try expectTags("\"line1\\nline2\" \"quote=\\\" slash=\\\\\"", &.{
        .string_literal, .string_literal, .eof,
    });
    // §2.7: a string is contained on a single line.
    try expectTags("\"first\nsecond\"", &.{ .invalid, .identifier, .invalid, .eof });
}

test "stringRunaway names the §2.7 mistake (E0138)" {
    const cases = [_]struct { src: []const u8, want: StringRunaway }{
        // IEEE 1800 §5.9 continuation, as in bsim4va's $strobe.
        .{ .src = "\"open\\\nrest\"", .want = .line_continuation },
        .{ .src = "\"open\nrest\"", .want = .unterminated },
        // `\\` is an escaped backslash (Table 2-2), not a continuation.
        .{ .src = "\"open\\\\\nrest\"", .want = .unterminated },
        // A trailing `\` with no newline after it is just end of file.
        .{ .src = "\"open\\", .want = .unterminated },
        .{ .src = "\"closed\"", .want = .none },
        .{ .src = "4'b01xz", .want = .none },
    };
    for (cases) |c| {
        var list = try tokenize(testing.allocator, c.src, null);
        defer list.deinit(testing.allocator);
        const span = tokenSpan(c.src, list.items(.start), 0);
        try testing.expectEqual(c.want, stringRunaway(c.src, span));
    }
}

test "tokenEnd recomputes exact spans (no len is stored)" {
    const src =
        \\analog I(p,n) <+ 1.5k * V(p,n); // c
    ;
    var list = try tokenize(testing.allocator, src, null);
    defer list.deinit(testing.allocator);

    const expected = [_][]const u8{
        "analog", "I", "(", "p", ",", "n", ")", "<+", "1.5k", "*",
        "V",      "(", "p", ",", "n", ")", ";",
    };
    for (list.items(.start)[0..expected.len], expected) |start, text| {
        try testing.expectEqualStrings(text, tokenText(src, start));
    }
    // Re-lexing is idempotent: asking twice gives the same end.
    try testing.expectEqual(tokenEnd(src, 0), tokenEnd(src, 0));
}

test "§2.6.1 white space splits the base format from the digits, and nothing else" {
    var list = try tokenize(testing.allocator, "8'h Af 8'h + 8 ' h 3", null);
    defer list.deinit(testing.allocator);
    const tags = list.items(.tag);
    // One token for the spaced literal...
    try testing.expectEqual(token.Tag.int_literal, tags[0]);
    // ...but a base format with no digits after it still ends AT the base
    // format, so the `+` that follows is its own token and not swallowed.
    try testing.expectEqual(token.Tag.invalid, tags[1]);
    try testing.expectEqual(token.Tag.plus, tags[2]);
    // §2.6.1 permits no space inside the apostrophe group: `8 ' h 3` is four
    // tokens, not one number.
    try testing.expectEqual(token.Tag.int_literal, tags[3]);
    try testing.expect(tags[4] != .int_literal);
}

test "§10.6 the two keyword directives survive the preprocessor as tokens" {
    var lx: Lexer = .{ .src = "`begin_keywords \"1364-2005\"\n`end_keywords\n`celldefine" };
    try testing.expectEqual(token.Tag.dir_begin_keywords, lx.next().tag);
    try testing.expectEqual(token.Tag.string_literal, lx.next().tag);
    try testing.expectEqual(token.Tag.dir_end_keywords, lx.next().tag);
    // Any other backtick means the preprocessor missed one: one invalid token.
    try testing.expectEqual(token.Tag.invalid, lx.next().tag);
}

test "tokenSpan covers exactly the token" {
    const src = "module foo;";
    var list = try tokenize(testing.allocator, src, null);
    defer list.deinit(testing.allocator);
    const starts = list.items(.start);

    // `module` is 6 bytes at offset 0; `foo` is 3 bytes at offset 7.
    try testing.expectEqual(diag.Span{ .start = 0, .end = 6 }, tokenSpan(src, starts, 0));
    try testing.expectEqual(diag.Span{ .start = 7, .end = 10 }, tokenSpan(src, starts, 1));
    try testing.expectEqualStrings("foo", src[tokenSpan(src, starts, 1).start..tokenSpan(src, starts, 1).end]);

    // Past the end is a zero-width span at EOF, not a panic: "expected X,
    // found end of file" has to point somewhere.
    const past = tokenSpan(src, starts, 9999);
    try testing.expectEqual(@as(u32, src.len), past.start);
    try testing.expectEqual(@as(u32, 0), past.len());
}

test "a real .va fixture lexes with no invalid tokens" {
    const src =
        \\`define GAIN 4.0
        \\module ch02(p, n); // one-line comment
        \\    inout p, n;
        \\    electrical p, n;
        \\    parameter real r = 1.5k from (0:inf);
        \\    real \gain+trim ;
        \\    analog begin
        \\        \gain+trim  = 4.0;
        \\        I(p, n) <+ V(p, n) / 1_000.0 + $temperature * 1u;
        \\    end
        \\endmodule
    ;
    var list = try tokenize(testing.allocator, src, null);
    defer list.deinit(testing.allocator);
    for (list.items(.tag), list.items(.start)) |tag, start| {
        // The backtick is the preprocessor's job; everything else must lex.
        if (src[start] == '`') continue;
        try testing.expect(tag != .invalid);
    }
}

test "every tag with a spelling lexes back to itself, whole (§2.5, §2.8.2)" {
    // `token.Tag.lexeme` and the scanners are written independently; each
    // is the other's oracle. A keyword read back as an identifier, or an
    // operator split in two, fails here.
    for (std.enums.values(token.Tag)) |t| {
        if (t == .dir_outside_module) continue; // four directives, described in prose
        const l = token.Tag.lexeme(t) orelse continue;
        var lx: Lexer = .{ .src = l };
        try testing.expectEqual(token.Stored{ .tag = t, .start = 0 }, lx.next());
        try testing.expectEqual(@as(u32, @intCast(l.len)), lx.pos);
        try testing.expectEqual(token.Tag.eof, lx.next().tag);
    }
}

test "next returns .eof at the end, repeatedly, past trailing white space" {
    var lx: Lexer = .{ .src = "a \n\t" };
    try testing.expectEqual(token.Tag.identifier, lx.next().tag);
    for (0..3) |_| try testing.expectEqual(token.Stored{ .tag = .eof, .start = 4 }, lx.next());
    var empty: Lexer = .{ .src = "" };
    try testing.expectEqual(token.Stored{ .tag = .eof, .start = 0 }, empty.next());
}

test "tokenizeSeeded equals tokenize for a seed ending at every token boundary" {
    const src = "module m(a); real x = 8 'h ff + 1.5k; $strobe(\"s\"); endmodule\n";
    var full = try tokenize(testing.allocator, src, null);
    defer full.deinit(testing.allocator);
    const tags = full.items(.tag);
    const starts = full.items(.start);
    // A prefix ends between tokens: at any token's start (the last one is
    // `.eof`'s, the end of the text).
    for (0..tags.len) |k| {
        const seed: Seed = .{ .tags = tags[0..k], .starts = starts[0..k], .len = starts[k] };
        var got = try tokenize(testing.allocator, src, seed);
        defer got.deinit(testing.allocator);
        try testing.expectEqualSlices(token.Tag, tags, got.items(.tag));
        try testing.expectEqualSlices(u32, starts, got.items(.start));
    }
}

test "tokenize leaks nothing when any allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, tokenizeMany, .{});
}

test "byte classes: §2.3 white space, §2.8 identifier characters, Table 2-1 scale factors" {
    for (0..256) |i| {
        const c: u8 = @intCast(i);
        try testing.expectEqual(c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c, isSpace(c));
        const ident = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '$';
        try testing.expectEqual(ident, isIdentChar(c));
        try testing.expectEqual(std.mem.findScalar(u8, "TGMKkmunpfa", c) != null, scaleExp(c) != null);
    }
}

test "isBasedDigit is §2.6.1's digit set of each radix, plus _ x z ?" {
    for ([_]u8{ 2, 8, 10, 16 }) |radix| {
        for (0..256) |i| {
            const c: u8 = @intCast(i);
            const value: ?u8 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => null,
            };
            const four_state = std.mem.findScalar(u8, "_xXzZ?", c) != null;
            const in_radix = if (value) |v| v < radix else false;
            try testing.expectEqual(four_state or in_radix, isBasedDigit(c, radix));
        }
    }
}

test "tokens tile the text: only white space between them, each re-lexes to its own end" {
    // Property over random text from the bytes every scanner branches on: no
    // byte is lost or read twice, and `tokenSpan` (a re-lex) ends where the
    // scan did, so a diagnostic caret covers exactly the token.
    const alphabet = "aZ_$09 \t\n\r\x0c\\\"'`.+-*/<>=!&|~^(){}[];:,?@#ehxsk\x00\x0b\x80\xff";
    var prng: std.Random.DefaultPrng = .init(0x7e57);
    const rand = prng.random();
    var buf: [96]u8 = undefined;
    for (0..4000) |_| {
        const src = buf[0..rand.uintAtMost(usize, buf.len)];
        for (src) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        var list = try tokenize(testing.allocator, src, null);
        defer list.deinit(testing.allocator);
        const starts = list.items(.start);
        var prev_end: u32 = 0;
        for (starts, 0..) |start, k| {
            for (src[prev_end..start]) |c| try testing.expect(isSpace(c));
            const span = tokenSpan(src, starts, @intCast(k));
            try testing.expect(span.end > span.start or list.items(.tag)[k] == .eof);
            prev_end = span.end;
        }
        try testing.expectEqual(@as(u32, @intCast(src.len)), prev_end);
    }
}

test "identEnd agrees with the per-byte isIdentChar loop for every byte, position and start" {
    // Oracle: the scalar loop the block scan replaced. Every byte value ends
    // a run at every position of a 130-byte text (past four 32-byte blocks,
    // so every block and tail boundary), from four starts.
    var buf: [130]u8 = undefined;
    for (&buf, 0..) |*b, k| b.* = "aZ09_$"[k % 6];
    for (0..buf.len) |at| {
        for (0..256) |c| {
            buf[at] = @intCast(c);
            for (0..4) |from| {
                const s = buf[0..@max(at + 1, from)];
                var want = from;
                while (want < s.len and isIdentChar(s[want])) want += 1;
                try testing.expectEqual(want, identEnd(s, from));
            }
        }
        buf[at] = "aZ09_$"[at % 6];
    }
    try testing.expectEqual(@as(usize, 0), identEnd("", 0));
    try testing.expectEqual(@as(usize, buf.len), identEnd(&buf, 0));
}

test "escapedEnd stops at the first byte outside printable ASCII 33-126 (§2.8.1)" {
    try testing.expectEqual(@as(usize, 6), escapedEnd("\\a+b-c d", 1));
    try testing.expectEqual(@as(usize, 4), escapedEnd("\\a~!\x7f", 1));
    try testing.expectEqual(@as(usize, 2), escapedEnd("\\a\x80", 1));
    try testing.expectEqual(@as(usize, 1), escapedEnd("\\ x", 1));
    try testing.expectEqual(@as(usize, 3), escapedEnd("\\ab", 1)); // end of text
    // A lone backslash names nothing.
    try expectTags("\\ x", &.{ .invalid, .identifier, .eof });
}

test "IEEE 1364 §19 directives the parser places survive; any other is one invalid byte" {
    try expectTags("`resetall `default_nettype `unconnected_drive `nounconnected_drive", &.{
        .dir_resetall, .dir_outside_module, .dir_outside_module, .dir_outside_module, .eof,
    });
    var lx: Lexer = .{ .src = "`timescale" };
    try testing.expectEqual(token.Stored{ .tag = .invalid, .start = 0 }, lx.next());
    try testing.expectEqual(token.Stored{ .tag = .identifier, .start = 1 }, lx.next());
    try expectTags("`", &.{ .invalid, .eof });
}

test "§2.6.1 based literal corners: signed designator, case, unknown digits, missing digits" {
    try expectTags("4'sb1001 4'SB1 'sd5 16'sd? 12'hx 3'b01x 8'hzZ?", &.{
        .int_literal, .int_literal, .int_literal, .int_literal, .int_literal, .int_literal, .int_literal, .eof,
    });
    // A base format with no digits: the token ends at the base letter.
    try expectTags("2'b", &.{ .invalid, .eof });
    try expectTags("'h;", &.{ .invalid, .semicolon, .eof });
    // An apostrophe with no base letter after it is not a base format.
    try expectTags("8'", &.{ .int_literal, .invalid, .eof });
    try expectTags("8's", &.{ .int_literal, .invalid, .identifier, .eof });
    try expectTags("3 'x", &.{ .int_literal, .invalid, .identifier, .eof });
    // A digit outside the radix ends the digits: `2'b12` is `2'b1` then `2`.
    try expectTags("2'b12", &.{ .int_literal, .int_literal, .eof });
}

test "§2.6.2 real corners: exponent forms, a dangling e, scale factor against identifier" {
    try expectTags("1.5e+3 1.5E-3 2e0 1_e3", &.{ .real_literal, .real_literal, .real_literal, .real_literal, .eof });
    // An `e` with no digits after it starts an identifier.
    try expectTags("1e", &.{ .int_literal, .identifier, .eof });
    try expectTags("1e+", &.{ .int_literal, .identifier, .plus, .eof });
    try expectTags("1.5e_3", &.{ .real_literal, .identifier, .eof });
    // A scale factor followed by an identifier character is not one.
    try expectTags("1m$x 2k_", &.{ .int_literal, .identifier, .int_literal, .identifier, .eof });
    // An exponent and a scale factor never combine.
    try expectTags("1e3k", &.{ .real_literal, .identifier, .eof });
}

test "bytes outside the grammar are one .invalid token each" {
    try expectTags("\xc3\xa9", &.{ .invalid, .invalid, .eof });
    try expectTags("a\x00b", &.{ .identifier, .invalid, .identifier, .eof });
    // Vertical tab is not §2.3 white space.
    try expectTags("a\x0bb", &.{ .identifier, .invalid, .identifier, .eof });
}

test "string corners (§2.7): empty, escaped quote last, runaway at end of file" {
    try expectTags("\"\"", &.{ .string_literal, .eof });
    try expectTags("\"a\\\"\"", &.{ .string_literal, .eof });
    try expectTags("\"abc", &.{ .invalid, .eof });
    try expectTags("\"abc\\", &.{ .invalid, .eof });
}

test "tokenSpan of an empty token column is the end of the text; stringRunaway past it is .none" {
    try testing.expectEqual(diag.Span{ .start = 3, .end = 3 }, tokenSpan("abc", &.{}, 0));
    try testing.expectEqual(StringRunaway.none, stringRunaway("ab", .{ .start = 2, .end = 2 }));
}
