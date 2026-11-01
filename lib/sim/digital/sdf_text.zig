//! An SDF file's bytes in, its OVI SDF 3.0 S-expression tree out (`parse`), and §16.6's rvalue read off a node (`rvalue`), for the annotator in sdf.zig.
//! Cites: IEEE 1364-2005 §16.6; OVI SDF 3.0 (S-expression syntax).
//!
//! Contents:
//! - `pub const Node = struct`
//! - `Node.head(n: Node) []const u8`
//! - `Node.is(n: Node, kw: []const u8) bool`
//! - `pub const ParseError = error`
//! - `pub const depth_max`
//! - `pub fn parse(a: std.mem.Allocator, text: []const u8, line: *u32) ParseError!Node`
//! - `pub fn rvalue(n: Node, mtm: u2) error{Syntax}!?f64`

const std = @import("std");
const assert = std.debug.assert;

/// One node: an atom (a word or a quoted string, its text as written) or a
/// parenthesized list; `line` is where it starts, 1-based.
pub const Node = struct {
    atom: ?[]const u8 = null,
    string: bool = false,
    kids: []const Node = &.{},
    line: u32,

    /// The keyword a list starts with, or "". Asserts that `n` is an atom
    /// or a list, not both, with a 1-based line.
    pub fn head(n: Node) []const u8 {
        // `Parser.node` makes an atom or a list, never both.
        if (n.atom != null) assert(n.kids.len == 0);
        assert(n.line >= 1);
        if (n.kids.len == 0) return "";
        return n.kids[0].atom orelse "";
    }

    /// Whether `n` is a list headed by keyword `kw`, in any case. Asserts
    /// that `kw` is not empty.
    pub fn is(n: Node, kw: []const u8) bool {
        assert(kw.len != 0); // A keyword the annotator names.
        const match = std.ascii.eqlIgnoreCase(n.head(), kw);
        if (match) assert(n.kids.len >= 1);
        return match;
    }
};

/// `TooDeep`: lists nested past `depth_max`.
pub const ParseError = error{ OutOfMemory, Syntax, TooDeep };

/// Lists `parse` nests before it refuses the file: `node` recurses once per
/// `(`, so the file's nesting is the native stack's depth. OVI SDF 3.0's
/// deepest construct (DELAYFILE CELL DELAY ABSOLUTE IOPATH COND rvalue) is
/// under ten.
pub const depth_max = 256;

const Parser = struct {
    a: std.mem.Allocator,
    text: []const u8,
    at: usize = 0,
    line: u32 = 1,
    /// Lists open at `at`.
    depth: u32 = 0,

    /// Skips white space and `//` and `/* */` comments.
    fn skip(p: *Parser) void {
        assert(p.at <= p.text.len);
        defer assert(p.at <= p.text.len);
        while (p.at < p.text.len) {
            const c = p.text[p.at];
            if (c == '\n') p.line += 1;
            if (std.ascii.isWhitespace(c)) {
                p.at += 1;
            } else if (std.mem.startsWith(u8, p.text[p.at..], "//")) {
                while (p.at < p.text.len and p.text[p.at] != '\n') p.at += 1;
            } else if (std.mem.startsWith(u8, p.text[p.at..], "/*")) {
                p.at += 2;
                while (p.at < p.text.len and !std.mem.startsWith(u8, p.text[p.at..], "*/")) : (p.at += 1) {
                    if (p.text[p.at] == '\n') p.line += 1;
                }
                p.at = @min(p.at + 2, p.text.len);
            } else return;
        }
    }

    fn node(p: *Parser) ParseError!Node {
        // `parse` and the list loop below call it only at a byte that `skip`
        // left: neither white space nor a comment.
        assert(p.at < p.text.len);
        assert(!std.ascii.isWhitespace(p.text[p.at]));
        const line = p.line;
        const c = p.text[p.at];
        if (c == '(') {
            if (p.depth == depth_max) return error.TooDeep;
            p.depth += 1;
            defer p.depth -= 1;
            p.at += 1;
            var kids: std.ArrayList(Node) = .empty;
            while (true) {
                p.skip();
                if (p.at >= p.text.len) return error.Syntax;
                if (p.text[p.at] == ')') break;
                try kids.append(p.a, try p.node());
            }
            p.at += 1;
            assert(p.at <= p.text.len);
            return .{ .kids = kids.items, .line = line };
        }
        if (c == ')') return error.Syntax;
        if (c == '"') {
            const start = p.at + 1;
            p.at = start;
            while (p.at < p.text.len and p.text[p.at] != '"') : (p.at += 1) {
                if (p.text[p.at] == '\n') p.line += 1;
            }
            if (p.at >= p.text.len) return error.Syntax;
            p.at += 1;
            assert(p.text[p.at - 1] == '"');
            return .{ .atom = p.text[start .. p.at - 1], .string = true, .line = line };
        }
        // A word: up to white space, a parenthesis or a quote; a backslash
        // escapes the next character (an SDF identifier's `\[`), kept as
        // written for `name` to undo.
        const start = p.at;
        while (p.at < p.text.len) : (p.at += 1) {
            const w = p.text[p.at];
            if (w == '\\') {
                p.at += 1;
                continue;
            }
            if (std.ascii.isWhitespace(w) or w == '(' or w == ')' or w == '"') break;
        }
        // The word holds `c` at least: `c` is none of the bytes that end one.
        assert(p.at > start);
        assert(@min(p.at, p.text.len) > start);
        return .{ .atom = p.text[start..@min(p.at, p.text.len)], .line = line };
    }
};

/// Parses `text` into its one top-level list. `line` is set to where a
/// syntax error was found.
pub fn parse(a: std.mem.Allocator, text: []const u8, line: *u32) ParseError!Node {
    var p: Parser = .{ .a = a, .text = text };
    p.skip();
    if (p.at >= text.len or text[p.at] != '(') {
        line.* = p.line;
        return error.Syntax;
    }
    const n = p.node() catch |e| {
        line.* = p.line;
        return e;
    };
    // The text started with `(`: one list.
    assert(n.atom == null);
    p.skip();
    if (p.at != text.len) {
        line.* = p.line;
        return error.Syntax;
    }
    assert(p.at == text.len);
    return n;
}

/// §16.6 one rvalue: `()` is null, `(v)` is v, `(min:typ:max)` the member
/// `mtm` picks (0, 1, 2), any of which may be empty.
/// Asserts that `mtm` is 0, 1 or 2.
pub fn rvalue(n: Node, mtm: u2) error{Syntax}!?f64 {
    assert(mtm <= 2);
    if (n.atom != null) return error.Syntax;
    if (n.kids.len == 0) return null;
    if (n.kids.len != 1 or n.kids[0].atom == null or n.kids[0].string) return error.Syntax;
    const t = n.kids[0].atom.?;
    var parts = std.mem.splitScalar(u8, t, ':');
    var got: [3][]const u8 = undefined;
    var k: usize = 0;
    while (parts.next()) |s| : (k += 1) {
        if (k == 3) return error.Syntax;
        got[k] = s;
    }
    const pick = if (k == 1) got[0] else if (k == 3) got[mtm] else return error.Syntax;
    assert(k == 1 or k == 3);
    if (pick.len == 0) return null;
    return std.fmt.parseFloat(f64, pick) catch error.Syntax;
}

test "OVI SDF 3.0: a file nested past depth_max is refused, not a stack overflow" {
    // Oracle: the parse's own bound. One list per `(`: `depth_max` levels
    // parse, one more is TooDeep, and a million (a hostile or corrupt file)
    // is refused before the native stack is.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]usize{ 1_000_000, depth_max, depth_max + 1 }) |n| {
        const text = try a.alloc(u8, 2 * n);
        @memset(text[0..n], '(');
        @memset(text[n..], ')');
        var line: u32 = 0;
        if (n <= depth_max) {
            _ = try parse(a, text, &line);
        } else try std.testing.expectError(error.TooDeep, parse(a, text, &line));
    }
}
