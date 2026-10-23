//! Preprocessed text → token stream of `{tag, start}` rows, and literal value
//! decoding (LRM §2.1-§2.8, Tables 2-1 and 2-2). `Lexer.next` depends only on
//! (src, pos), so `tokenEnd` recovers a token's end by re-lexing. The lexer never
//! fails except on OOM: malformed input becomes one `.invalid` token for the parser
//! to report. Only the identifier scan is a vector block compare (`identEnd`);
//! the white space and literal scans stay per-byte, where a block lost.

const std = @import("std");
const token = @import("token.zig");
const diag = @import("diag");

/// Token rows in SoA form: the `.tag` and `.start` columns.
pub const TokenList = std.MultiArrayList(token.Stored);

/// A cursor over preprocessed source. `pos` is the only state.
pub const Lexer = struct {
    src: []const u8,
    pos: u32 = 0,

    // Budget: the scan's whole state, three words in registers (4 B of
    // padding after `pos`). A u32 `pos` matches the u32 token starts.
    comptime {
        std.debug.assert(@sizeOf(Lexer) <= 24);
    }

    /// Already-lexed tokens for a prefix of `src`, replayed by `tokenizeSeeded`
    /// instead of re-scanned. `len` is the prefix's byte length; the columns are
    /// its tokens without `.eof`, and every `start` is an absolute offset into
    /// `src`. The prefix must end between tokens.
    /// Produced by `Preprocessor.preludeTokens` for the annex D/E prelude.
    pub const Seed = struct {
        tags: []const token.Tag,
        starts: []const u32,
        len: u32,
    };

    /// Lexes all of `src`; the list ends with `.eof`. Fails only with
    /// `OutOfMemory`: malformed text becomes `.invalid` rows.
    /// The caller owns the list and frees it with `list.deinit(arena)`.
    pub fn tokenize(arena: std.mem.Allocator, src: []const u8) !TokenList {
        return tokenizeSeeded(arena, src, null);
    }

    /// Same as `tokenize`, but copies `seed`'s tokens and scans only the rest.
    /// Asserts `src.len` fits in u32 and the seed lies within `src`. Correct
    /// because `next` carries no state across tokens; the prelude equivalence
    /// test in preprocessor.zig checks it against a full scan.
    pub fn tokenizeSeeded(arena: std.mem.Allocator, src: []const u8, seed: ?Seed) !TokenList {
        std.debug.assert(src.len <= std.math.maxInt(u32));

        var list: TokenList = .empty;
        errdefer list.deinit(arena);
        var start: u32 = 0;
        if (seed) |s| {
            std.debug.assert(s.tags.len == s.starts.len);
            std.debug.assert(s.len <= src.len);
            // About 4 source bytes per token, over the part still to be scanned.
            try list.ensureTotalCapacity(arena, s.tags.len + (src.len - s.len) / 4 + 8);
            list.len = s.tags.len;
            @memcpy(list.items(.tag), s.tags);
            @memcpy(list.items(.start), s.starts);
            start = s.len;
        } else {
            // About 4 source bytes per token including separators: one allocation in practice.
            try list.ensureTotalCapacity(arena, src.len / 4 + 8);
        }

        var lx: Lexer = .{ .src = src, .pos = start };
        while (true) {
            const t = lx.next();
            try list.append(arena, t);
            if (t.tag == .eof) return list;
        }
    }

    /// Scans the token at `pos` and advances past it (LRM §2.2). Returns `.eof`
    /// at the end, repeatedly. Asserts that `pos` is within the source, and
    /// that every other token advanced it by at least one byte: the
    /// tokenizer's loop ends only because each pass moves.
    pub fn next(self: *Lexer) token.Stored {
        std.debug.assert(self.pos <= self.src.len);
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
            '`' => self.lexDirective(), // §10.6 (the only directives left here)
            else => self.lexOperator(), // §2.5, §2.9
        };
        std.debug.assert(self.pos > start);
        std.debug.assert(self.pos <= self.src.len);
        return .{ .tag = tag, .start = start };
    }

    /// Returns the end offset of the token starting at `start`, by re-lexing it.
    /// Cost is one token scan per call.
    fn tokenEnd(self: *const Lexer, start: u32) u32 {
        var relex: Lexer = .{ .src = self.src, .pos = start };
        _ = relex.next();
        return relex.pos;
    }

    /// Returns the source text of the token starting at `start` (one token scan).
    pub fn tokenText(self: *const Lexer, start: u32) []const u8 {
        return self.src[start..self.tokenEnd(start)];
    }

    // ---- scanners ---------------------------------------------------------

    /// Whether the last non-space byte before `at` is a `#`.
    fn afterHash(src: []const u8, at: usize) bool {
        var k = at;
        while (k > 0 and isSpace(src[k - 1])) k -= 1;
        return k > 0 and src[k - 1] == '#';
    }

    /// LRM §2.6.1 (integer constants) and §2.6.2 (real constants). Cursor is on
    /// a decimal digit. Underscores are legal anywhere but first (§2.6.1).
    fn lexNumber(self: *Lexer) token.Tag {
        const start = self.pos;
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

        return if (is_real) .real_literal else .int_literal;
    }

    /// LRM §2.6.1 based-constant tail: `' [s|S] base_char digits`. Cursor is on
    /// the apostrophe. Returns null (cursor untouched) if this is not a
    /// base_format.
    ///
    /// White space is legal between the base format and the digits ("optionally
    /// preceded by white space", §2.6.1, as in `'h 837FF`) but not inside the
    /// apostrophe group (`8 ' h`). It stays inside the token span, and
    /// `integer.parse` skips it at the same place.
    fn lexBasedTail(self: *Lexer) ?token.Tag {
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
        self.pos = i;
        return .int_literal;
    }

    /// LRM §2.6.1 unsigned_number: decimal digits with `_` separators. A trailing
    /// `_` is legal (`236.123_763_e-12` is an LRM example).
    fn skipUnsignedNumber(self: *Lexer) void {
        while (true) {
            const c = self.peek(0);
            if (std.ascii.isDigit(c) or c == '_') self.pos += 1 else return;
        }
    }

    /// LRM §2.8 simple identifier or §2.8.2 keyword. Escaped identifiers never
    /// reach here, so they are never looked up as keywords.
    fn lexIdentOrKeyword(self: *Lexer) token.Tag {
        const start = self.pos;
        self.pos = @intCast(identEnd(self.src, self.pos));
        return token.lookupKeyword(self.src[start..self.pos]) orelse .identifier;
    }

    /// LRM §10.6 `begin_keywords / `end_keywords, and IEEE 1364 §19.6 `resetall:
    /// the directives the preprocessor passes through because only the parser
    /// can check where they sit. Any other backtick is `.invalid`.
    fn lexDirective(self: *Lexer) token.Tag {
        const start = self.pos;
        self.pos += 1; // '`'
        const name = self.pos;
        self.pos = @intCast(identEnd(self.src, self.pos));
        const text = self.src[name..self.pos];
        if (std.mem.eql(u8, text, "begin_keywords")) return .dir_begin_keywords;
        if (std.mem.eql(u8, text, "end_keywords")) return .dir_end_keywords;
        if (std.mem.eql(u8, text, "resetall")) return .dir_resetall;
        if (std.mem.eql(u8, text, "default_nettype") or std.mem.eql(u8, text, "unconnected_drive") or
            std.mem.eql(u8, text, "nounconnected_drive") or std.mem.eql(u8, text, "default_transition")) return .dir_outside_module;
        self.pos = start + 1;
        return .invalid;
    }

    /// LRM §2.8.1: `\` then printable ASCII 33 to 126, terminated by white space.
    /// Neither the backslash nor the terminator is part of the identifier, but
    /// both are inside the token span (the parser strips them).
    fn lexEscapedIdentifier(self: *Lexer) token.Tag {
        const body = self.pos + 1;
        self.pos = @intCast(escapedEnd(self.src, body));
        return if (self.pos == body) .invalid else .escaped_identifier;
    }

    /// LRM §2.8.3: `$` immediately followed by [a-zA-Z0-9_$]+ (no white space).
    fn lexSystemIdentifier(self: *Lexer) token.Tag {
        self.pos += 1;
        const body = self.pos;
        self.pos = @intCast(identEnd(self.src, self.pos));
        return if (self.pos == body) .invalid else .system_identifier;
    }

    /// LRM §2.7: double-quoted, single line, `\` escapes (decoded by
    /// `stringContents`). An unterminated string ends at the newline/EOF.
    fn lexString(self: *Lexer) token.Tag {
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
        return .invalid;
    }

    /// `'{` assignment pattern (§4.2.14) or an unsized based constant (§2.6.1).
    fn lexApostrophe(self: *Lexer) token.Tag {
        if (self.peek(1) == '{') {
            self.pos += 2;
            return .apostrophe_lbrace;
        }
        if (self.lexBasedTail()) |t| return t;
        self.pos += 1;
        return .invalid;
    }

    /// LRM §2.5 operators (longest match) and §2.9 attribute delimiters.
    /// Digital-only sequences with no tag (`=>`, `*>`, `&&&`) are consumed
    /// whole as `.invalid` so the parser reports one error, not three.
    fn lexOperator(self: *Lexer) token.Tag {
        const c = self.src[self.pos];
        self.pos += 1;
        return switch (c) {
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
    }

    /// The byte `n` past the cursor, or 0 past the end.
    fn peek(self: *const Lexer, n: u32) u8 {
        // usize: `pos + n` may pass maxInt(u32) on a source of that length.
        const i = @as(usize, self.pos) + n;
        return if (i < self.src.len) self.src[i] else 0; // NUL never appears in source
    }

    fn eat(self: *Lexer, c: u8) bool {
        if (self.pos < self.src.len and self.src[self.pos] == c) {
            self.pos += 1;
            return true;
        }
        return false;
    }
};

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
/// else `s.len`. Asserts `i <= s.len`.
pub fn identEnd(s: []const u8, i: usize) usize {
    std.debug.assert(i <= s.len);
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
    return k;
}

/// Returns where the §2.8.1 escaped identifier whose body starts at `i` (just
/// past the `\`) ends. The body is printable ASCII 33 to 126; any other byte ends it.
pub fn escapedEnd(s: []const u8, i: usize) usize {
    var k = i;
    while (k < s.len and s[k] >= 33 and s[k] <= 126) k += 1;
    return k;
}

/// Returns whether `c` is a §2.6.1 digit of `radix`, `_`, or a four-state digit
/// (x/X/z/Z/?, decoded by `integer.parse`). The parser calls it with radix 16 to
/// tell §2.6.1 Example 1's `4af` (a based number missing its base format) from
/// `1g` (a number and an identifier).
pub fn isBasedDigit(c: u8, radix: u8) bool {
    return switch (c) {
        '_', 'x', 'X', 'z', 'Z', '?' => true,
        '0'...'9' => c - '0' < radix,
        'a'...'f', 'A'...'F' => radix == 16,
        else => false,
    };
}

/// Returns the exponent text a §2.6.2 Table 2-1 scale factor stands for, or null.
/// `M` is 1e6 and `m` is 1e-3; `K` and `k` are both 1e3.
/// Callers append it to the mantissa and parse once: `200u` → `200e-6` rounds
/// once, while `200.0 * 1e-6` rounds twice and gives a different double. The
/// testbench's `//! time` parser uses it so both read the same value; do not
/// re-spell the table elsewhere.
pub fn scaleExp(c: u8) ?[]const u8 {
    return switch (c) {
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
}

// ---- source locations (diagnostics) ---------------------------------------

/// Returns the byte range of token `tok`, for a diagnostic caret. `starts` is
/// the token list's `.start` column; the end costs one re-lex.
/// An out-of-range index yields a zero-width span at end of file, for
/// "expected X, found end of file".
pub fn tokenSpan(src: []const u8, starts: []const u32, tok: u32) diag.Span {
    if (tok >= starts.len) {
        const end: u32 = @intCast(src.len);
        return .{ .start = end, .end = end };
    }
    const start = starts[tok];
    const lx: Lexer = .{ .src = src };
    return .{ .start = start, .end = lx.tokenEnd(start) };
}

/// Why a `.invalid` token that opened with `"` never closed, so the parser can
/// give that common mistake its own message.
const StringRunaway = enum {
    /// Not a string literal at all; the caller's own message stands.
    none,
    /// Ran off the end of the line (or the file) with no closing quote.
    unterminated,
    /// Ended the line with a backslash: the SystemVerilog line continuation.
    line_continuation,
};

/// Classifies the `.invalid` token spanning `span`.
///
/// §2.7: a string literal is "contained on a single line", and Table 2-2 has no
/// `\<newline>` escape. Continuing a string across a line is IEEE 1800 §5.9,
/// which some foundry models use, so `.line_continuation` lets the message name
/// the rule. The body is walked with `lexString`'s escape pairing, because in
/// `"a\\` the final backslash is half of an escape, not a continuation.
pub fn stringRunaway(src: []const u8, span: diag.Span) StringRunaway {
    if (span.start >= src.len or src[span.start] != '"') return .none;
    const text = src[span.start..span.end];
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (text[i] == '"') return .none; // closed on its own line after all
        if (text[i] != '\\') continue;
        // A `\` with nothing left in the token is the one `lexString` refused
        // to pair, i.e. it sat immediately before the newline that stopped it.
        if (i + 1 == text.len) {
            return if (span.end < src.len) .line_continuation else .unterminated;
        }
        i += 1; // skip the escaped character
    }
    return .unterminated;
}

// ---- token value decoding (§2.6, §2.7) ------------------------------------

/// `parseReal`'s errors. §2.6.1 integer decoding is `integer.parse`, with its
/// own error set.
pub const ValueError = error{
    /// `std.fmt.parseFloat` refused the text. The lexer never produces such a
    /// literal; a value too large for f64 is not this error but inf (§2.6.2
    /// leaves it to IEEE 754).
    Overflow,
    OutOfMemory,
};

/// A decoded §2.6.1 integer constant. `width` is the declared size in bits, or
/// 0 for an unsized constant, which §4.2.13 forbids in a concatenation.
pub const IntLiteral = struct {
    value: i64,
    width: u32,
    signed: bool,
    /// §2.6.1 the radix the base format names (2, 8, 10 or 16); 10 for a
    /// literal written without one. IEEE 1364-2005 §26.6.26's vpiConstType.
    radix: u8 = 10,
};

// Budget: 16 bytes, one per `.int_literal` row (4,750 on hisimhv_va).
comptime {
    std.debug.assert(@sizeOf(IntLiteral) == 16);
}

/// Decodes a `.real_literal`'s text (LRM §2.6.2), of any length. Strips `_`
/// and rewrites a Table 2-1 scale factor into an exponent, so IEEE-754
/// rounding happens once. A literal past 512 bytes is decoded in a `gpa`
/// buffer freed before return.
pub fn parseReal(gpa: std.mem.Allocator, text: []const u8) ValueError!f64 {
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

    var small: [512]u8 = undefined;
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

    // The lexer only produces well-formed real literals; overflow yields inf,
    // which §2.6.2 leaves to IEEE 754; clamping would change the value.
    return std.fmt.parseFloat(f64, buf[0..n]) catch error.Overflow;
}

/// Decodes a `.string_literal`'s text (quotes included) into its bytes
/// (LRM §2.7 Table 2-2: \n \t \\ \" and \ddd, 1 to 3 octal digits).
/// An escape Table 2-2 does not list decodes to the escaped character alone
/// (`\q` is `q`), and an octal escape above `\377` keeps its low 8 bits;
/// `badEscape` finds both so the caller can report them first.
/// Asserts `text` is quoted. Caller owns returned memory and must free it
/// with `gpa`.
pub fn stringContents(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
    std.debug.assert(text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"');
    const body = text[1 .. text.len - 1];

    var out = try gpa.alloc(u8, body.len); // escapes only ever shrink
    errdefer gpa.free(out);

    var n: usize = 0;
    var i: usize = 0;
    while (i < body.len) {
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
    return gpa.realloc(out, n);
}

/// An escape in a `.string_literal` that `stringContents` would decode by
/// VerA's choice rather than by Table 2-2, as byte offsets into the text.
const BadEscape = struct {
    start: u32,
    end: u32,
    /// `\ddd` above `\377` (E0148); otherwise an escape Table 2-2 does not
    /// list (W0149).
    above_377: bool,
};

/// Returns the first escape at or after byte `from` of a `.string_literal`'s
/// text (quotes included) that LRM §2.7 Table 2-2 does not define, or null.
pub fn badEscape(text: []const u8, from: u32) ?BadEscape {
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
    return null;
}

// ---- checks ---------------------------------------------------------------

const testing = std.testing;

fn expectTags(src: []const u8, expected: []const token.Tag) !void {
    var list = try Lexer.tokenize(testing.allocator, src);
    defer list.deinit(testing.allocator);
    try testing.expectEqualSlices(token.Tag, expected, list.items(.tag));
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
        var list = try Lexer.tokenize(testing.allocator, c.src);
        defer list.deinit(testing.allocator);
        const span = tokenSpan(c.src, list.items(.start), 0);
        try testing.expectEqual(c.want, stringRunaway(c.src, span));
    }
}

test "tokenEnd recomputes exact spans (no len is stored)" {
    const src =
        \\analog I(p,n) <+ 1.5k * V(p,n); // c
    ;
    var list = try Lexer.tokenize(testing.allocator, src);
    defer list.deinit(testing.allocator);

    const lx: Lexer = .{ .src = src };
    const expected = [_][]const u8{
        "analog", "I", "(", "p", ",", "n", ")", "<+", "1.5k", "*",
        "V",      "(", "p", ",", "n", ")", ";",
    };
    for (list.items(.start)[0..expected.len], expected) |start, text| {
        try testing.expectEqualStrings(text, lx.tokenText(start));
    }
    // Re-lexing is idempotent: asking twice gives the same end.
    try testing.expectEqual(lx.tokenEnd(0), lx.tokenEnd(0));
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

test "§2.6.1 white space splits the base format from the digits, and nothing else" {
    var list = try Lexer.tokenize(testing.allocator, "8'h Af 8'h + 8 ' h 3");
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

test "tokenSpan covers exactly the token" {
    const src = "module foo;";
    var list = try Lexer.tokenize(testing.allocator, src);
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
    var list = try Lexer.tokenize(testing.allocator, src);
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
        if (t == .dir_outside_module) continue; // three directives, described in prose
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
    var full = try Lexer.tokenize(testing.allocator, src);
    defer full.deinit(testing.allocator);
    const tags = full.items(.tag);
    const starts = full.items(.start);
    // A prefix ends between tokens: at any token's start (the last one is
    // `.eof`'s, the end of the text).
    for (0..tags.len) |k| {
        const seed: Lexer.Seed = .{ .tags = tags[0..k], .starts = starts[0..k], .len = starts[k] };
        var got = try Lexer.tokenizeSeeded(testing.allocator, src, seed);
        defer got.deinit(testing.allocator);
        try testing.expectEqualSlices(token.Tag, tags, got.items(.tag));
        try testing.expectEqualSlices(u32, starts, got.items(.start));
    }
}

fn tokenizeMany(gpa: std.mem.Allocator) !void {
    // Past the up-front estimate of one token per 4 bytes, so the list grows.
    const semis: [100]u8 = @splat(';');
    var list = try Lexer.tokenize(gpa, &semis);
    defer list.deinit(gpa);
    try testing.expectEqual(@as(usize, 101), list.len);
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
        var list = try Lexer.tokenize(testing.allocator, src);
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

fn decodeOnce(gpa: std.mem.Allocator) !void {
    const s = try stringContents(gpa, "\"a\\101\\q\"");
    defer gpa.free(s);
    try testing.expectEqualStrings("aAq", s);
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

test "tokenSpan of an empty token column is the end of the text; stringRunaway past it is .none" {
    try testing.expectEqual(diag.Span{ .start = 3, .end = 3 }, tokenSpan("abc", &.{}, 0));
    try testing.expectEqual(StringRunaway.none, stringRunaway("ab", .{ .start = 2, .end = 2 }));
}
