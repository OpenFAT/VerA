//! The card rows a netlist is read into (`Card`), the refusal list
//! (`Refusals`), the `.MODEL` type table (`model_types`) and the text helpers
//! every SPICE reader shares: a card's tokens (`Tokens`), comment stripping,
//! quote and `=` normalisation, and a `.SUBCKT`'s body.
//! Cites: LRM annex E.1.2, E.2, E.2.1, E.2.2.1, E.3, Table E.1.
//!
//! Contents:
//! - `pub const Card = struct`
//! - `pub const Refusals = struct`: `add`
//! - `pub const model_types = [_]struct`
//! - `pub const ModelCard = struct`
//! - `pub fn hasEntry(text: []const u8, entry: []const u8) bool`
//! - `pub fn unquote(t: []const u8) []const u8`
//! - `pub fn tightEquals(arena: Allocator, card: []const u8) Allocator.Error![]const u8`
//! - `pub const Tokens = struct`: `next`
//! - `pub fn strip(raw: []const u8) []const u8`
//! - `pub fn subcktBody(rest: []const Card) []const Card`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const spice_cards = @import("../spice_cards.zig");
const Refusal = spice_cards.Refusal;
const File = spice_cards.File;
const token = @import("../token.zig");
const spice_expr = @import("expr.zig");
const spice_model = @import("model.zig");
const spice_reader = @import("reader.zig");
const Reader = spice_reader.Reader;
const emitModelCard = spice_model.emitModelCard;
const expression = spice_expr.expression;

/// A logical card (continuations joined) and where its first line starts;
/// also one physical line of it (`Reader.lines`), comments stripped and
/// lower-cased.
pub const Card = struct {
    text: []const u8,
    file: u32 = 0,
    at: u32,
    len: u32,
};

/// The refusals of one `synthesize` call.
pub const Refusals = struct {
    arena: Allocator,
    list: std.ArrayList(Refusal) = .empty,

    pub fn add(r: *Refusals, card: Card, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        assert(card.text.len > 0);
        try r.list.append(r.arena, .{ .file = card.file, .at = card.at, .len = card.len, .why = try r.arena.print(fmt, args) });
    }
};

/// E.2.2.1: ".MODEL statements can be accessed in Verilog-AMS HDL ... The ports
/// and parameters of the bjt are determined by the bjt primitive itself and not
/// by the model statement." So a model card contributes a name and a primitive
/// type, and the interface comes from Table E.1's row for that type.
///
/// The rows are the SPICE model-type letters, mapped to the Table E.1 primitive
/// each names. Absent types (`sw`, `ltra`, `core`, ...) are skipped cards, not
/// errors: E.1.2's first bullet makes the recognised flavor "solely determined by
/// the authors of the simulator".
///
/// `ports` is pre-joined in Table E.1's order, which E.3 makes normative for
/// connection by order. A test pins each row against
/// `@import("../pp/annex_e.zig").spice_primitives`.
pub const model_types = [_]struct { type_: []const u8, prim: []const u8, ports: []const u8 }{
    .{ .type_ = "npn", .prim = "bjt", .ports = "c, b, e, s" },
    .{ .type_ = "pnp", .prim = "bjt", .ports = "c, b, e, s" },
    .{ .type_ = "d", .prim = "diode", .ports = "a, c" },
    .{ .type_ = "nmos", .prim = "mosfet", .ports = "d, g, s, b" },
    .{ .type_ = "pmos", .prim = "mosfet", .ports = "d, g, s, b" },
    .{ .type_ = "njf", .prim = "jfet", .ports = "d, g, s" },
    .{ .type_ = "pjf", .prim = "jfet", .ports = "d, g, s" },
    .{ .type_ = "nmf", .prim = "mesfet", .ports = "d, g, s" },
    .{ .type_ = "pmf", .prim = "mesfet", .ports = "d, g, s" },
    .{ .type_ = "r", .prim = "resistor", .ports = "p, n" },
    .{ .type_ = "c", .prim = "capacitor", .ports = "p, n" },
    .{ .type_ = "l", .prim = "inductor", .ports = "p, n" },
};

/// One `.MODEL` card of the netlist, wherever it sits: what a body card's
/// model name resolves to (`emitModelCard`).
pub const ModelCard = struct {
    name: []const u8,
    type_: []const u8,
    card: Card,
};

/// A card's fields: split at blanks and at `(`, `)` and `,`, which are noise
/// in a SPICE card, except inside a `{...}` or `'...'` expression, which is
/// one field whatever it holds (HSPICE writes `{w * 2}`, `'max(a, b)'`).
pub const Tokens = struct {
    text: []const u8,
    i: usize = 0,

    const seps = " \t(),";

    pub fn next(t: *Tokens) ?[]const u8 {
        while (t.i < t.text.len and std.mem.findScalar(u8, seps, t.text[t.i]) != null) t.i += 1;
        if (t.i == t.text.len) return null;
        const start = t.i;
        var depth: usize = 0;
        var quoted = false;
        while (t.i < t.text.len) : (t.i += 1) {
            const c = t.text[t.i];
            if (c == '\'') {
                quoted = !quoted;
            } else if (quoted) {
                continue;
            } else if (c == '{') {
                depth += 1;
            } else if (c == '}') {
                depth -|= 1;
            } else if (depth == 0 and std.mem.findScalar(u8, seps, c) != null) break;
        }
        // The first byte is no separator, so the field holds one at least.
        assert(t.i > start);
        assert(t.i <= t.text.len);
        return t.text[start..t.i];
    }
};

/// Whether `text` has a `.LIB entry` header, so an empty entry is not
/// reported as a missing one.
pub fn hasEntry(text: []const u8, entry: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeAny(u8, strip(raw), " \t");
        if (!std.ascii.eqlIgnoreCase(it.next() orelse continue, ".lib")) continue;
        if (std.ascii.eqlIgnoreCase(unquote(it.next() orelse continue), entry) and it.next() == null) return true;
    }
    return false;
}

/// A file name or entry without the `"`/`'` SPICE dialects put around it.
pub fn unquote(t: []const u8) []const u8 {
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

/// `card` with the white space around each `=` removed: HSPICE writes
/// `level = 72`, and every reader below splits a parameter on its `=` within
/// one token.
pub fn tightEquals(arena: Allocator, card: []const u8) Allocator.Error![]const u8 {
    if (std.mem.findScalar(u8, card, '=') == null) return arena.dupe(u8, card);
    var out: std.ArrayList(u8) = try .initCapacity(arena, card.len);
    for (card, 0..) |c, i| {
        const blank = c == ' ' or c == '\t';
        if (blank) {
            const next = std.mem.trimStart(u8, card[i..], " \t");
            if (next.len != 0 and next[0] == '=') continue;
            if (out.items.len != 0 and out.items[out.items.len - 1] == '=') continue;
        }
        out.appendAssumeCapacity(c);
    }
    return out.items;
}

/// One physical line with its comments removed: `*` is a full-line comment, `;`
/// and `$` start a trailing one.
pub fn strip(raw: []const u8) []const u8 {
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len != 0 and line[0] == '*') return "";
    if (std.mem.findAny(u8, line, ";$")) |at| line = std.mem.trim(u8, line[0..at], " \t");
    return line;
}

/// Returns the cards `rest[0]` owns, excluding the terminating `.ENDS`; empty
/// unless `rest[0]` is a `.SUBCKT` header. E.2 makes a subcircuit a module
/// definition and E.2.2.2 shows its device cards as its body. Asserts that
/// `rest` is not empty.
pub fn subcktBody(rest: []const Card) []const Card {
    assert(rest.len != 0);
    if (!std.mem.startsWith(u8, rest[0].text, ".subckt")) return &.{};
    for (rest[1..], 1..) |card, i| {
        if (std.mem.startsWith(u8, card.text, ".ends")) return rest[1..i];
    }
    return rest[1..]; // an unterminated `.SUBCKT` still has a body
}
