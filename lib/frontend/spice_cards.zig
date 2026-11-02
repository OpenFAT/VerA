//! SPICE `.MODEL` and `.SUBCKT` cards in, Verilog-AMS module source text out
//! (LRM annex E.2, E.3). Reads the two interface cards and, inside a
//! `.SUBCKT`, the device cards that form its body. Cards outside a definition
//! (`.tran`, top-level devices) are not module definitions and are skipped
//! without a diagnostic, except a `.MODEL` of a type VerA has no primitive
//! for, which is recorded so an instance of it is refused by name (E0952,
//! E.1.2). The text is prepended to the source like
//! `@import("pp/annex_e.zig").spice_primitives`, so §6 instantiation, overrides and their
//! diagnostics apply unchanged. Input is lower-cased at ingest (E.2.1), file
//! names excepted.
//!
//! E.1.2: "with which particular variant of SPICE it is compatible, is solely
//! determined by the authors of the simulator". VerA claims SPICE3 card
//! syntax for `.MODEL` (the `model_types` rows), for `.SUBCKT` bodies of
//! R/C/L/V/I/E/F/G/H cards, of M/Q/J/D cards whose model is a Verilog-A
//! module or paramset (`model_cards`, binned models included) and of X cards
//! (`emitSubcktCard`), and for `.INCLUDE`, `.LIB` and HSPICE's `.HDL`
//! anywhere (`Reader`); and HSPICE's subcircuit parameters (`PARAMS:` on
//! the header) and `{expr}`/`'expr'` values over them (`expression`).
//! Inside a `.SUBCKT`, anything else (a nested `.SUBCKT`, `.PARAM`, an
//! expression `expression` does not read, a model-referenced R or unlisted
//! device card, a binned model no bin of which holds the card) is a
//! `Refusal` (E0928), and a card whose model is a Table E.1 semiconductor
//! with no behaviour is E0953: skipping either would change the circuit, a
//! dropped R being an open.
//!
//! Contents:
//! - `pub const Synthesized = struct`
//! - `pub const File = struct`
//! - `pub const Refusal = struct`
//! - `pub fn synthesize(arena: Allocator, netlist: []const u8, path: []const u8) Allocator.Error!Synthesized`

const std = @import("std");
const Allocator = std.mem.Allocator;
const token = @import("token.zig");
const deep_stack = @import("base").deep_stack;
const assert = std.debug.assert;
const spice_card = @import("spice/card.zig");
const spice_emit = @import("spice/emit.zig");
const spice_expr = @import("spice/expr.zig");
const spice_model = @import("spice/model.zig");
const spice_names = @import("spice/names.zig");
const spice_reader = @import("spice/reader.zig");
const Card = spice_card.Card;
const Refusals = spice_card.Refusals;
const model_types = spice_card.model_types;
const ModelCard = spice_card.ModelCard;
const hasEntry = spice_card.hasEntry;
const unquote = spice_card.unquote;
const tightEquals = spice_card.tightEquals;
const Tokens = spice_card.Tokens;
const strip = spice_card.strip;
const subcktBody = spice_card.subcktBody;
const Reader = spice_reader.Reader;
const emitCard = spice_emit.emitCard;
const device_cards = spice_emit.device_cards;
const controlled = spice_emit.controlled;
const emitBody = spice_emit.emitBody;
const emitSubcktCard = spice_emit.emitSubcktCard;
const declares = spice_emit.declares;
const model_cards = spice_model.model_cards;
const Value = spice_model.Value;
const expression = spice_expr.expression;
const spiceNumber = spice_names.spiceNumber;
const isIdent = spice_names.isIdent;
const isSpiceName = spice_names.isSpiceName;
const spell = spice_names.spell;

/// Synthesized prelude text plus the number of module declarations it holds,
/// which `Ast.SourceFile.netlist_modules` records.
pub const Synthesized = struct {
    text: []const u8 = "",
    modules: u32 = 0,
    /// Cards inside a definition this reader does not claim; the caller
    /// reports each (`Refusal.code`) and stops.
    refused: []const Refusal = &.{},
    /// `.MODEL` cards whose type is a primitive VerA does not support (E.1.2
    /// bullet 2), as `name type`, lower-cased: an instance naming one is
    /// refused with E0952 rather than as an unknown module.
    unsupported: []const []const u8 = &.{},
    /// The files a `Refusal` points into: the netlist itself first, then
    /// each file a `.INCLUDE` or `.LIB` card read.
    files: []const File = &.{},
    /// HSPICE `.HDL "file"`: Verilog-A sources the netlist names, as opened
    /// (relative to the naming file's directory), each once, in card order.
    /// They belong to the design like files given together on a command line.
    hdl: []const []const u8 = &.{},
};

/// One netlist file: the name it was opened by, and its text.
pub const File = struct { name: []const u8, text: []const u8 };

/// One card `synthesize` cannot read, located in `Synthesized.files[file]`
/// (the first physical line of the card).
pub const Refusal = struct {
    file: u32 = 0,
    at: u32,
    len: u32,
    why: []const u8,
    /// E0928 unless the card is readable and its model is not (E0953).
    code: enum { E0928, E0953 } = .E0928,
};

const test_lib =
    \\* corners
    \\.LIB FF
    \\.SUBCKT FAST A B
    \\R1 A B 1
    \\.ENDS
    \\.ENDL
    \\.LIB TT
    \\.SUBCKT TYP A B
    \\R1 A B 2
    \\.ENDS
    \\.ENDL
    \\.LIB EMPTY
    \\.ENDL
    \\
;

const test_top =
    \\.INCLUDE "inc.sp"
    \\.INC 'inc.sp'
    \\.LIB 'lib.sp' tt
    \\.LIB lib.sp empty
    \\.LIB lib.sp ss
    \\.INCLUDE
    \\.INCLUDE nothere.sp
    \\.LIB open.sp tt
    \\.HDL "a.va"
    \\.HDL a.va
    \\.HDL
    \\
;

/// The words `synthesizeOne` builds netlists from: cards, fields and the
/// punctuation the readers split on. No `.include`, `.lib` or `.hdl` call,
/// so a run reads no file.
const fuzz_words = [_][]const u8{ ".subckt", ".ends", ".model", ".param", ".endl", "+", "r1", "c1", "v1", "i1", "e1", "f1", "g1", "h1", "m1", "q1", "j1", "d1", "x1", "k1", "a", "b", "0", "1", "1k", "2n2222", "nch", "nch.1", "npn", "nmos", "bsim4", "params:", "w=1", "l={2*w}", "m=2", "lmin=0", "lmax=1", "{w*2}", "'w+1'", "{", "}", "'", "(", ")", ",", "=", "**", "-", "poly", "value={1}", "*", ";", "$", "\n", "1e999k", "wire" };

/// Returns Verilog-AMS module text for every `.MODEL` and `.SUBCKT` card in
/// `netlist`, the text of the file `path` names ("" when it names none:
/// relative `.INCLUDE`/`.LIB`/`.HDL` names then resolve against the working
/// directory). The text, the refusals and the files are allocated from
/// `arena`; the working copies (the lowered lines, the joined cards, per-card
/// strings) live on a scratch arena freed on return. Never fails on malformed
/// input: a line outside a definition this does not understand contributes
/// nothing, and one inside a definition is a `Refusal`.
pub fn synthesize(arena: Allocator, netlist: []const u8, path: []const u8) Allocator.Error!Synthesized {
    if (netlist.len == 0) return .{};
    var scratch_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    var refusals: Refusals = .{ .arena = arena };

    // Every line of every file, `.INCLUDE`/`.LIB` expanded in place.
    var r: Reader = .{ .arena = arena, .scratch = scratch, .refusals = &refusals };
    try r.files.append(arena, .{ .name = if (path.len == 0) "<spice netlist>" else path, .text = netlist });
    try r.read(0, null);
    assert(r.reading.items.len == 0); // every `read` pops what it pushed

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(scratch,
        \\// Annex E.2 — synthesized from the `//! spice` cards of this compilation;
        \\// see `spice_cards.synthesize` for what of a netlist is read and what is not.
        \\
        \\
    );
    var count: u32 = 0;
    // Emitted names, so a repeated card does not declare the same module twice.
    // The first card wins; E.1.2 leaves the choice to "the authors of the
    // simulator".
    // ponytail: `seen` and `models` are linear scans, O(cards * models); a
    // StringHashMap keyed by name if a netlist ever holds thousands of models.
    var seen: std.ArrayList([]const u8) = .empty;
    var unsupported: std.ArrayList([]const u8) = .empty;

    // `+` continuations make a card longer than a line, so the cards are
    // assembled first and read second.
    var cards: std.ArrayList(Card) = .empty;
    var logical: std.ArrayList(u8) = .empty;
    // The card's first line, whose place in its file the card keeps.
    var first: Card = undefined;
    for (r.lines.items) |line| {
        assert(line.text.len != 0); // `read` keeps no blank line
        if (line.text[0] == '+') {
            // Joins the card under construction. A `+` with nothing above it has
            // nothing to continue and is dropped.
            if (logical.items.len != 0) {
                try logical.append(scratch, ' ');
                try logical.appendSlice(scratch, std.mem.trim(u8, line.text[1..], " \t"));
            }
            continue;
        }
        if (logical.items.len != 0) {
            first.text = try tightEquals(scratch, logical.items);
            try cards.append(scratch, first);
        }
        logical.clearRetainingCapacity();
        try logical.appendSlice(scratch, line.text);
        first = line;
    }
    if (logical.items.len != 0) {
        first.text = try tightEquals(scratch, logical.items);
        try cards.append(scratch, first);
    }

    // A body card may name a model declared after it, or in another file.
    var models: std.ArrayList(ModelCard) = .empty;
    for (cards.items) |card| {
        var it: Tokens = .{ .text = card.text };
        if (!std.mem.eql(u8, it.next() orelse continue, ".model")) continue;
        const name = it.next() orelse continue;
        const type_ = it.next() orelse continue;
        for (models.items) |m| {
            if (std.mem.eql(u8, m.name, name)) break;
        } else try models.append(scratch, .{ .name = name, .type_ = type_, .card = card });
    }

    // Index-based, because a `.SUBCKT` header is not the whole card it reads:
    // E.2 makes it a module definition, which runs to its `.ENDS`.
    // The body is consumed with the header whether or not anything is emitted,
    // so a repeated `.SUBCKT`'s cards are not read a second time at top level.
    var i: usize = 0;
    while (i < cards.items.len) {
        const body = subcktBody(cards.items[i..]);
        if (try emitCard(scratch, &out, cards.items[i], body, models.items, &seen, &refusals, &unsupported)) count += 1;
        i += 1 + body.len;
    }
    // A body is a slice of the cards after its header, so no step overshoots.
    assert(i == cards.items.len);

    const kept = try arena.alloc([]const u8, unsupported.items.len);
    for (unsupported.items, kept) |u, *k| k.* = try arena.dupe(u8, u);
    var done: Synthesized = .{ .refused = refusals.list.items, .unsupported = kept, .files = r.files.items, .hdl = r.hdl.items };
    if (count == 0) return done;
    done.text = try arena.dupe(u8, out.items);
    done.modules = count;
    return done;
}

// ponytail: the first `.ENDS` ends it. A nested `.SUBCKT` is refused
// (`emitBody`), so closing the outer one early never produces a module.

// ponytail: two terminals and one positional value, which is every row of
// `device_cards`; a three-terminal or `k=v` card needs its own arity column.
// The `controlled` letters are the exception, and read their own shape.

// `emitBody` tries `controlled`, then `model_cards`, then `x`, then
// `device_cards` on a card's first letter: a letter in two of them would make
// the later row unreachable.
comptime {
    for (controlled) |c| {
        assert(c.letter != 'x');
        for (model_cards) |m| assert(c.letter != m.letter);
        for (device_cards) |d| assert(c.letter != d.letter);
    }
    for (model_cards) |m| {
        assert(m.letter != 'x');
        for (device_cards) |d| assert(m.letter != d.letter);
    }
    for (device_cards) |d| assert(d.letter != 'x');
}

// ---- private ----

/// Requires every `want` in `text`, printing the text when one is missing.
fn expectHas(text: []const u8, wants: []const []const u8) !void {
    for (wants) |want| if (std.mem.find(u8, text, want) == null) {
        std.debug.print("missing: {s}\n in:\n{s}\n", .{ want, text });
        return error.TestUnexpectedResult;
    };
}

/// Requires the refusals' reasons to hold `wants`, one each, in order.
fn expectRefusals(refused: []const Refusal, wants: []const []const u8) !void {
    errdefer for (refused, 0..) |r, i| std.debug.print("refusal {d}: {s}\n", .{ i, r.why });
    try std.testing.expectEqual(wants.len, refused.len);
    for (refused, wants) |r, want| try expectHas(r.why, &.{want});
}

/// Synthesizes `netlist` with every `arena` allocation on `gpa`, for
/// `checkAllAllocationFailures`.
fn synthesizeAll(gpa: Allocator, netlist: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    _ = try synthesize(arena_state.allocator(), netlist, "");
}

fn synthesizeOne(_: void, s: *std.testing.Smith) anyerror!void {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    while (!s.eos()) {
        w.writeAll(fuzz_words[s.index(fuzz_words.len)]) catch break;
        w.writeByte(' ') catch break;
    }
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try synthesize(arena_state.allocator(), w.buffered(), "");
    // Every refusal points inside the file it names, and a module count
    // comes with module text.
    for (out.refused) |r| {
        try std.testing.expect(r.file < out.files.len);
        try std.testing.expect(@as(usize, r.at) + r.len <= out.files[r.file].text.len);
    }
    try std.testing.expect((out.modules == 0) == (out.text.len == 0));
}

fn expressionOne(_: void, s: *std.testing.Smith) anyerror!void {
    const words = [_][]const u8{ "w", "1", "1k", "2e3", ".5", "(", ")", "+", "-", "*", "/", "**", "max", "sqrt", "log", ",", " ", "_x", "#", "'" };
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    while (!s.eos()) w.writeAll(words[s.index(words.len)]) catch break;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    switch (try expression(arena_state.allocator(), w.buffered(), &.{"w"})) {
        // Every operation is parenthesized: the text's parentheses balance.
        .text => |t| try std.testing.expectEqual(std.mem.count(u8, t, "("), std.mem.count(u8, t, ")")),
        .refused => |why| try std.testing.expect(why.len != 0),
    }
}

test "model_types names a real Table E.1 module with the ports it lists" {
    // A row whose primitive or port order does not match the prelude would be
    // wrong without any other test noticing.
    const prelude = @import("pp/annex_e.zig").spice_primitives;
    for (model_types) |r| {
        const header = try std.testing.allocator.print(
            "module {s}({s});",
            .{ r.prim, r.ports },
        );
        defer std.testing.allocator.free(header);
        try std.testing.expect(std.mem.find(u8, prelude, header) != null);
    }
}

test "a .MODEL card becomes a module with the primitive's ports, a .SUBCKT with its own" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\* a comment line
        \\.MODEL VERTNPN NPN BF=80 IS=1E-18 RB=100 VAF=50
        \\+ CJE=3PF CJC=2PF ; trailing comment
        \\.SUBCKT ECPOSC (OUT GND)
        \\VA VCC GND 5
        \\R1 B1 GND 10K
        \\.ENDS ECPOSC
        \\.TRAN 1N 100N $ skipped, not diagnosed
    , "");
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    try std.testing.expectEqual(@as(usize, 0), s.refused.len);
    // E.2.2.1: ports AND parameters from the bjt primitive, in Table E.1's
    // order, and the card's own names are not among them: Table E.1's bjt row
    // declares `area` and nothing else, so `BF`, `IS`, `CJE` have no parameter
    // to land on and are dropped in silence (E.4.2: "support of SPICE model
    // cards is implementation specific").
    try std.testing.expect(std.mem.find(u8, s.text, "module vertnpn(c, b, e, s);") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "parameter real area = 1.0;") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "bjt #(.area(area)) prim(c, b, e, s);") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "bf") == null);
    // E.2.2.2: ports from the card, lowered, parentheses dropped, and the two
    // device cards between it and `.ENDS` as E.2.2.3 translates them. `vcc` is
    // an internal node and appears only in the body.
    try std.testing.expect(std.mem.find(u8, s.text, "module ecposc(out, gnd);") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "vsine #(.dc(5)) va(vcc, gnd);") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "resistor #(.r(10000)) r1(b1, gnd);") != null);
    // The `.TRAN` after `.ENDS` is outside the body and is still not a module.
    try std.testing.expect(std.mem.find(u8, s.text, "100n") == null);
}

test "a .SUBCKT's device cards are its body, and an unreadable one is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT RDIV IN OUT GND
        \\R1 IN OUT 1K
        \\R2 OUT GND 3K
        \\S1 OUT IN GND 0 SWMOD
        \\R3 A B RMOD
        \\.ENDS RDIV
        \\R9 X Y 1K
    , "");
    try std.testing.expectEqual(@as(u32, 1), s.modules);
    try std.testing.expect(std.mem.find(u8, s.text, "resistor #(.r(1000)) r1(in, out);") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "resistor #(.r(3000)) r2(out, gnd);") != null);
    // A letter VerA has no row for (`S`, a switch) and no number on a
    // model-referenced R: neither becomes an instance, and each is a refusal
    // located at its line.
    try std.testing.expect(std.mem.find(u8, s.text, "s1") == null);
    try std.testing.expect(std.mem.find(u8, s.text, "r3") == null);
    try std.testing.expectEqual(@as(usize, 2), s.refused.len);
    try std.testing.expectEqual(@as(u32, 51), s.refused[0].at);
    try std.testing.expect(std.mem.find(u8, s.refused[1].why, "`rmod` is not a number") != null);
    // `R9` is after `.ENDS`: top-level netlist, not part of any definition.
    try std.testing.expect(std.mem.find(u8, s.text, "r9") == null);

    // A repeated `.SUBCKT` is dropped with its body: the cards inside must not
    // fall out into the next module, or into a module of their own.
    const dup = try synthesize(arena,
        \\.SUBCKT PAD A B
        \\R1 A B 1K
        \\.ENDS
        \\.SUBCKT PAD A B
        \\R1 A B 9K
        \\.ENDS
    , "");
    try std.testing.expectEqual(@as(u32, 1), dup.modules);
    try std.testing.expect(std.mem.find(u8, dup.text, "9000") == null);
}

test "a .MODEL card's value reaches the Table E.1 parameter of the same name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.MODEL RMOD R R=10K TC1=1E-3
        \\.MODEL CM C C=1P IC=2.5
    , "");
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    // §2.6.2 Table 2-1 by way of E.2.2.3's `resistor #(.r(10k))`: `10K` is 10000.
    // §3.4.2's `from` range survives the substitution: it belongs to the
    // declaration, not to the default it replaces.
    try std.testing.expect(std.mem.find(u8, s.text, "parameter real r = 10000 from (0:inf);") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "parameter real tc1 = 0.001;") != null);
    // A parameter the card does not name keeps the primitive's own default.
    try std.testing.expect(std.mem.find(u8, s.text, "parameter real tc2 = 0.0;") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "resistor #(.r(r), .tc1(tc1), .tc2(tc2)) prim(p, n);") != null);
    // Not a resistor special case, and `ic` is an initial condition rather than
    // a coefficient.
    try std.testing.expect(std.mem.find(u8, s.text, "parameter real c = 0.000000000001 from (0:inf);") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "parameter real ic = 2.5;") != null);
}

test "SPICE's scaled notation, including the three suffixes §2.6.2 does not share" {
    // The annex prints `10K`, `3PF`, `1UH`, `0.3NS`, `1MA`, `1E-18` in its own
    // netlists; a reader that cannot turn those into numbers cannot read
    // E.2.2.2. `MEG`/`MIL` are the SPICE-only ones, and `M` is milli here where
    // §2.6.2 Table 2-1 makes it mega.
    try std.testing.expectEqual(@as(?f64, 10000), spiceNumber("10k"));
    try std.testing.expectEqual(@as(?f64, 3e-12), spiceNumber("3pf"));
    try std.testing.expectEqual(@as(?f64, 1e-6), spiceNumber("1uh"));
    try std.testing.expectEqual(@as(?f64, 0.3e-9), spiceNumber("0.3ns"));
    try std.testing.expectEqual(@as(?f64, 1e-3), spiceNumber("1ma"));
    try std.testing.expectEqual(@as(?f64, 1e6), spiceNumber("1meg"));
    try std.testing.expectEqual(@as(?f64, 25.4e-6), spiceNumber("1mil"));
    try std.testing.expectEqual(@as(?f64, 1e-18), spiceNumber("1e-18"));
    try std.testing.expectEqual(@as(?f64, -2.5), spiceNumber("-2.5"));
    // The scale rounds once, as the lexer's §2.6.2 factors do: 50 * 1e-9 is
    // 5.0000000000000004e-8, one ulp off the card's 50n.
    try std.testing.expectEqual(@as(?f64, 5e-8), spiceNumber("50n"));
    try std.testing.expectEqual(@as(?f64, 2.2e-9), spiceNumber("2.2n"));
    try std.testing.expectEqual(@as(?f64, 1.5e-6), spiceNumber("1.5e-3m"));
    // SPICE has no atto, so a bare `1A` is one ampere and the letter is noise.
    try std.testing.expectEqual(@as(?f64, 1.0), spiceNumber("1a"));
    // Not a number at all.
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("rmod"));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber(""));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("."));
}

test "a card naming a keyword is declared as a §2.8.1 escaped identifier" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT AMP (INPUT OUTPUT)
        \\.ENDS AMP
        \\.MODEL WIRE NPN BF=80
    , "");
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    // The terminator is the point: `\input,` would scan the comma into the
    // name (§2.8.1 ends at white space, and `,` is printable ASCII).
    try std.testing.expect(std.mem.find(u8, s.text, "module amp(\\input , \\output );") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "electrical \\input , \\output ;") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "module \\wire (c, b, e, s);") != null);
    // A name that is not a keyword is not escaped.
    const plain = try synthesize(arena, ".SUBCKT PAD IN OUT\n.ENDS\n", "");
    try std.testing.expect(std.mem.find(u8, plain.text, "module pad(in, out);") != null);
}

test "a digit-leading name and a numeric node are spelled §2.8.1, not dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.MODEL 2N2222 NPN BF=200
        \\.SUBCKT FLT A 1 B
        \\.ENDS FLT
    , "");
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    // E.2 treats the model as a module definition even though `2N2222` fails
    // §2.7's identifier shape.
    try std.testing.expect(std.mem.find(u8, s.text, "module \\2n2222 (c, b, e, s);") != null);
    // The numeric node is the SPICE default and is a port, not the end of the
    // list: three ports, in card order, or §6.5.4's ordered binding is wrong.
    try std.testing.expect(std.mem.find(u8, s.text, "module flt(a, \\1 , b);") != null);
    try std.testing.expect(std.mem.find(u8, s.text, "electrical a, \\1 , b;") != null);
    // A parameter assignment ends the port list: it is a module parameter
    // (HSPICE's PARAMS:, VD-012), not a port.
    const p = try synthesize(arena, ".SUBCKT X N1 N2 PARAMS: W=2\n.ENDS\n", "");
    try std.testing.expectEqual(@as(u32, 1), p.modules);
    try std.testing.expectEqual(@as(usize, 0), p.refused.len);
    try std.testing.expect(std.mem.find(u8, p.text, "module x(n1, n2);") != null);
    try std.testing.expect(std.mem.find(u8, p.text, "   parameter real w = 2;") != null);
}

test "an unrecognised model type, a repeat and an empty netlist all contribute nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqual(@as(u32, 0), (try synthesize(arena, "", "")).modules);
    const sw = try synthesize(arena, ".MODEL SW1 SW RON=1\n", "");
    try std.testing.expectEqual(@as(u32, 0), sw.modules);
    // E.1.2: kept by name and type, so its instance is refused as such.
    try std.testing.expectEqual(@as(usize, 1), sw.unsupported.len);
    try std.testing.expectEqualStrings("sw1 sw", sw.unsupported[0]);
    try std.testing.expectEqual(@as(u32, 0), (try synthesize(arena, "R1 a b 1k\n.TRAN 1n 1u\n", "")).modules);
    const dup = try synthesize(arena, ".MODEL M1 NPN\n.MODEL M1 PNP\n", "");
    try std.testing.expectEqual(@as(u32, 1), dup.modules);
    // A portless .SUBCKT is A.1.2's `module identifier ;`, not `electrical ;`.
    const bare = try synthesize(arena, ".SUBCKT PAD\n.ENDS\n", "");
    try std.testing.expectEqual(@as(u32, 1), bare.modules);
    try std.testing.expect(std.mem.find(u8, bare.text, "electrical") == null);
}

test "E.3.1 the four controlled sources inside a .SUBCKT, and the V card an F or H reads" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT CTL A B C D
        \\VS A X 0
        \\E1 B 0 A X 2
        \\G1 C 0 A X 3
        \\F1 D 0 VS 4
        \\H1 B C VS 5
        \\F2 D 0 VNONE 6
        \\.ENDS
    , "");
    for ([_][]const u8{
        "branch (a, x) vs;",
        "V(vs) <+ $simparam(\"sourceScaleFactor\") * 0;",
        "V(b, \\0 ) <+ 2 * V(a, x);",
        "I(c, \\0 ) <+ 3 * V(a, x);",
        "I(d, \\0 ) <+ 4 * I(vs);",
        "V(b, c) <+ 5 * I(vs);",
    }) |want| try std.testing.expect(std.mem.find(u8, s.text, want) != null);
    // A controlling V card the subcircuit does not declare is refused, and a
    // controlling V card is a branch of this module, not a `vsine` child.
    try std.testing.expect(std.mem.find(u8, s.text, "6 *") == null);
    try std.testing.expectEqual(@as(usize, 1), s.refused.len);
    try std.testing.expect(std.mem.find(u8, s.text, "vsine") == null);
}

test "E.1.2 nested .SUBCKT, {expr} values and trailing fields in a body are refused, top-level cards are not" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT OUTER A B
        \\.SUBCKT INNER C D
        \\R1 A B {RVAL}
        \\R2 A B 1K TC=0.01
        \\.ENDS
        \\R9 X Y RMOD
        \\.TRAN 1N 1U
    , "");
    try std.testing.expectEqual(@as(usize, 3), s.refused.len);
    try std.testing.expect(std.mem.find(u8, s.refused[0].why, "nested") != null);
    try std.testing.expect(std.mem.find(u8, s.refused[1].why, "{rval}") != null);
    try std.testing.expect(std.mem.find(u8, s.refused[2].why, "tc=0.01") != null);
}

test "E.2 an M/Q/J/D card instantiates its model's module, card parameters under the instance's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT AMP D G S B
        \\M1 D G S B NCH W=2U L = 50N M=3
        \\Q1 D G S QMOD 2
        \\Q2 D G S B QMOD
        \\D1 G S DIO 4 AREA=5
        \\J1 D G S MYJFET
        \\.ENDS
        \\.MODEL NCH BSIMCMG TYPE=1 L=20N NSD=2E+26
        \\.MODEL QMOD MYBJT BF=80
        \\.MODEL DIO DIODE_VA IS=1E-14
    , "");
    try std.testing.expectEqual(@as(usize, 0), s.refused.len);
    for ([_][]const u8{
        // The model card first (its `l` replaced by the instance's 50n, in
        // the card's place), then what only the instance sets; `M` is
        // E.4.1's multiplicity, `$mfactor`. 2e26 is real, not an integer.
        "   bsimcmg #(.type(1), .l(0.00000005), .nsd(2e26), .w(0.000002), .$mfactor(3)) m1(d, g, s, b);",
        // Q: a fifth name that is a number is the area, not a substrate.
        "   mybjt #(.bf(80), .area(2)) q1(d, g, s);",
        // ...and a fifth that is not is the model after a substrate.
        "   mybjt #(.bf(80)) q2(d, g, s, b);",
        // An explicit `area=` wins over the positional one.
        "   diode_va #(.is(0.00000000000001), .area(5)) d1(g, s);",
        // No `.MODEL`: the name is a module or paramset of the design.
        "   myjfet j1(d, g, s);",
    }) |want| {
        if (std.mem.find(u8, s.text, want) == null) {
            std.debug.print("missing: {s}\n in:\n{s}\n", .{ want, s.text });
            return error.TestUnexpectedResult;
        }
    }
}

test "E.2 a card whose model is a Table E.1 semiconductor is E0953; a binned model and a bad value are E0928" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.MODEL NMOS_LVT NMOS LEVEL = 72
        \\.MODEL PCH.1 BSIM4 LMIN=1U
        \\.SUBCKT INV A Y VDD VSS
        \\MN Y A VSS VSS NMOS_LVT L=21N
        \\MP Y A VDD VDD PCH L=21N
        \\MX Y A VDD VDD BSIM4 L={LEN}
        \\MY Y A VDD VDD BSIM4 OFF
        \\.ENDS
    , "");
    try std.testing.expectEqual(@as(usize, 4), s.refused.len);
    try std.testing.expect(s.refused[0].code == .E0953);
    try std.testing.expect(std.mem.find(u8, s.refused[0].why, "Table E.1's `mosfet`") != null);
    try std.testing.expect(s.refused[1].code == .E0928);
    try std.testing.expect(std.mem.find(u8, s.refused[1].why, "binned") != null);
    try std.testing.expect(std.mem.find(u8, s.refused[2].why, "{len}") != null);
    try std.testing.expect(std.mem.find(u8, s.refused[3].why, "`off`") != null);
}

test "PARAMS: on a .SUBCKT, {expr} values over them, and X cards instantiating a subcircuit" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.SUBCKT RDIV IN OUT GND PARAMS: RTOP=1K RBOT={3*RTOP}
        \\R1 IN OUT { RTOP }
        \\R2 OUT GND 'RBOT'
        \\R3 OUT GND {max(RTOP, 2k)}
        \\.ENDS
        \\.SUBCKT TWO A B
        \\X1 A MID 0 RDIV PARAMS: RTOP=2K
        \\X2 MID B 0 RDIV M=2
        \\.ENDS
    , "");
    try std.testing.expectEqual(@as(usize, 0), s.refused.len);
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    for ([_][]const u8{
        "   parameter real rtop = 1000;",
        // A default may read the parameters before it; numbers are real.
        "   parameter real rbot = (3e0 * rtop);",
        // A brace or quote holds its blanks, parentheses and commas.
        "   resistor #(.r(rtop)) r1(in, out);",
        "   resistor #(.r(rbot)) r2(out, gnd);",
        "   resistor #(.r(max(rtop, 2e3))) r3(out, gnd);",
        "   rdiv #(.rtop(2000)) x1(a, mid, \\0 );",
        "   rdiv #(.$mfactor(2)) x2(mid, b, \\0 );",
        // SPICE's node 0 is the global ground, not a local net.
        "   electrical \\0 ;\n   ground \\0 ;\n",
    }) |want| {
        if (std.mem.find(u8, s.text, want) == null) {
            std.debug.print("missing: {s}\n in:\n{s}\n", .{ want, s.text });
            return error.TestUnexpectedResult;
        }
    }
    // A name that is not a parameter before it is refused at the card.
    const bad = try synthesize(arena, ".SUBCKT R A B PARAMS: X={Y}\n.ENDS\n", "");
    try std.testing.expectEqual(@as(usize, 1), bad.refused.len);
    try std.testing.expect(std.mem.find(u8, bad.refused[0].why, "reads `y`") != null);
}

test "SPICE expressions: real arithmetic, power over a unary minus, and what is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        // `1/3` is a third: §4.2.1 would make `1 / 3` an integer 0.
        .{ "1/3", "(1e0 / 3e0)" },
        .{ "-2**2", "(-(2e0 ** 2e0))" },
        .{ "2**-1", "(2e0 ** (-1e0))" },
        .{ "max(1k, w)*2", "(max(1e3, w) * 2e0)" },
        .{ " w - 1u - 2 ", "((w - 1e-6) - 2e0)" },
    }) |c| try std.testing.expectEqualStrings(c[1], (try expression(arena, c[0], &.{"w"})).text);
    for ([_][]const u8{ "log(2)", "w^2", "v", "1 +", "(w", "w ? 1 : 2" }) |bad|
        try std.testing.expect((try expression(arena, bad, &.{"w"})) == .refused);
}

test "E.4.2 a card naming a binned model instantiates the bin that holds its L and W" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try synthesize(arena,
        \\.MODEL NCH.1 MYFET KP=1E-3 LMIN=0 LMAX=0.5
        \\.MODEL NCH.2 MYFET KP=3E-3 LMIN=0.5 LMAX=2 WMIN=1
        \\.SUBCKT CELL2 D G S B
        \\M1 D G S B NCH W=2 L=0.5
        \\M2 D G S B NCH W=2 L=0.25
        \\M3 D G S B NCH W=2 L=3
        \\M4 D G S B NCH L=1
        \\.ENDS
    , "");
    // lmin <= L < lmax: 0.5 is the second bin's, 0.25 the first's; the
    // bounds select and are not forwarded.
    for ([_][]const u8{
        "   myfet #(.kp(0.003), .w(2), .l(0.5)) m1(d, g, s, b);",
        "   myfet #(.kp(0.001), .w(2), .l(0.25)) m2(d, g, s, b);",
    }) |want| {
        if (std.mem.find(u8, s.text, want) == null) {
            std.debug.print("missing: {s}\n in:\n{s}\n", .{ want, s.text });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), s.refused.len);
    try std.testing.expect(std.mem.find(u8, s.refused[0].why, "no bin of the binned model `nch`") != null);
    try std.testing.expect(std.mem.find(u8, s.refused[1].why, "gives no w") != null);
}

test "a card value at or past 2^31 that is integral is spelled real" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("10000", try std.mem.print(&buf, "{f}", .{Value{ .num = 1e4 }}));
    try std.testing.expectEqualStrings("2147483647", try std.mem.print(&buf, "{f}", .{Value{ .num = 2147483647 }}));
    try std.testing.expectEqualStrings("2.147483648e9", try std.mem.print(&buf, "{f}", .{Value{ .num = 2147483648 }}));
    try std.testing.expectEqualStrings("0.5", try std.mem.print(&buf, "{f}", .{Value{ .num = 0.5 }}));
    try std.testing.expectEqualStrings("-2.147483648e9", try std.mem.print(&buf, "{f}", .{Value{ .num = -2147483648 }}));
    try std.testing.expectEqualStrings("-0.5", try std.mem.print(&buf, "{f}", .{Value{ .num = -0.5 }}));
}

test "the card text helpers: tightEquals, Tokens, strip, unquote, hasEntry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Pair = struct { []const u8, []const u8 };
    for ([_]Pair{
        .{ "level = 72", "level=72" },
        .{ "a  =  b c", "a=b c" },
        .{ "x= y", "x=y" },
        .{ "x =y", "x=y" },
        .{ "no equals here", "no equals here" },
    }) |p| try std.testing.expectEqualStrings(p[1], try tightEquals(arena, p[0]));
    const Split = struct { []const u8, []const []const u8 };
    for ([_]Split{
        .{ ".subckt ecposc (out gnd)", &.{ ".subckt", "ecposc", "out", "gnd" } },
        .{ "r1 a b {w * 2}", &.{ "r1", "a", "b", "{w * 2}" } },
        .{ "x1 a 'max(a, b)' c", &.{ "x1", "a", "'max(a, b)'", "c" } },
        .{ "{a {b} c} d", &.{ "{a {b} c}", "d" } },
        // A stray `}` does not open anything.
        .{ "a}b c", &.{ "a}b", "c" } },
        .{ " ,() ", &.{} },
    }) |c| {
        var it: Tokens = .{ .text = c[0] };
        for (c[1]) |want| try std.testing.expectEqualStrings(want, it.next().?);
        try std.testing.expect(it.next() == null);
    }
    try std.testing.expectEqualStrings("", strip("* a full-line comment"));
    try std.testing.expectEqualStrings("r1 a b 1k", strip("r1 a b 1k ; note"));
    try std.testing.expectEqualStrings("r1 a b 1k", strip("r1 a b 1k $ note"));
    try std.testing.expectEqualStrings("x", strip("  x \r"));
    try std.testing.expectEqualStrings("", strip("   ; only a comment"));
    try std.testing.expectEqualStrings("a", unquote("'a'"));
    try std.testing.expectEqualStrings("a", unquote("\"a\""));
    try std.testing.expectEqualStrings("'a\"", unquote("'a\""));
    try std.testing.expect(hasEntry(".lib tt\n.endl\n", "TT"));
    try std.testing.expect(hasEntry("* c\n.LIB 'tt'\n", "tt"));
    try std.testing.expect(!hasEntry(".lib file.sp tt\n", "tt"));
}

test "names: isIdent, isSpiceName and spell" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "_a1", "w" }) |t| try std.testing.expect(isIdent(t));
    for ([_][]const u8{ "", "a$", "1a", "a.b" }) |t| try std.testing.expect(!isIdent(t));
    for ([_][]const u8{ "2n2222", "a.b", "0", "{x}" }) |t| try std.testing.expect(isSpiceName(t));
    for ([_][]const u8{ "", "a=b", "x:", "a\x7f", "a b" }) |t| try std.testing.expect(!isSpiceName(t));
    try std.testing.expectEqualStrings("w", try spell(arena, "w"));
    try std.testing.expectEqualStrings("\\wire ", try spell(arena, "wire"));
    try std.testing.expectEqualStrings("\\2n ", try spell(arena, "2n"));
    try std.testing.expectEqualStrings("\\a.b ", try spell(arena, "a.b"));
}

test "spiceNumber never panics: an exponent past i32 is not a number, a huge one is infinite" {
    // `1e2147483647k` scales an exponent already at maxInt(i32) by 10^3.
    try std.testing.expect(std.math.isInf(spiceNumber("1e2147483647k").?));
    const tiny = spiceNumber("-1e-2147483648f").?;
    try std.testing.expect(tiny == 0 and std.math.signbit(tiny));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("1e99999999999k"));
    // Past the 128-byte join a scaled number is refused; unscaled it is read.
    var long: [132]u8 = @splat('0');
    long[0] = '1';
    long[131] = 'k';
    try std.testing.expectEqual(@as(?f64, null), spiceNumber(&long));
    try std.testing.expectEqual(@as(?f64, 1e130), spiceNumber(long[0..131]));
    try std.testing.expectEqual(@as(?f64, 0.5), spiceNumber("+.5"));
    try std.testing.expectEqual(@as(?f64, 5e-7), spiceNumber(".5u"));
    // An incomplete exponent is unit noise, as are other letters.
    try std.testing.expectEqual(@as(?f64, 1), spiceNumber("1e"));
    try std.testing.expectEqual(@as(?f64, 1), spiceNumber("1x"));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("-"));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("+"));
    try std.testing.expectEqual(@as(?f64, null), spiceNumber("e5"));
}

test "SPICE expressions name what they refuse, and nesting has no depth bound" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Case = struct { []const u8, []const u8 };
    for ([_]Case{
        .{ "1 2", "has `2` after a complete expression" },
        .{ "foo(1)", "calls `foo`" },
        .{ "max(1, 2", "has a `max(` with no `)`" },
        .{ "(1", "has a `(` with no `)`" },
        .{ "", "ends before an operand" },
        .{ "1 +", "ends before an operand" },
        .{ "#", "has `#`, which is not read" },
        .{ "q", "reads `q`, which names no parameter in scope" },
    }) |c| {
        const got = try expression(arena, c[0], &.{"w"});
        try std.testing.expect(got == .refused);
        try expectHas(got.refused, &.{c[1]});
    }
    try std.testing.expectEqualStrings("1e0", (try expression(arena, "+1", &.{})).text);
    try std.testing.expectEqualStrings("(2e0 ** (3e0 ** 2e0))", (try expression(arena, "2**3**2", &.{})).text);
    // Every recursive rule passes through `unary`. 257 parentheses was one
    // past the old 256-level cap; 100,000 crosses many stack segments. An
    // even count of signs is the value itself.
    for ([_]usize{ 257, 100_000 }) |n| {
        const buf = try arena.alloc(u8, 2 * n + 1);
        @memset(buf[0..n], '(');
        buf[n] = '1';
        @memset(buf[n + 1 ..], ')');
        try std.testing.expectEqualStrings("1e0", (try expression(arena, buf, &.{})).text);
    }
    // Signs build one `(-...)` per level, so 2,000 (past the old cap) stays
    // a small test: the text is 2,000 levels of `(-` around 1e0.
    const signs = try arena.alloc(u8, 2001);
    @memset(signs[0..2000], '-');
    signs[2000] = '1';
    const got = (try expression(arena, signs, &.{})).text;
    try std.testing.expect(std.mem.startsWith(u8, got, "(-(-") and std.mem.count(u8, got, "(-") == 2000);
}

test "cards: `+` continues the card above, a leading `+` is dropped, and an unterminated .SUBCKT keeps its body" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try synthesize(arena,
        \\+ R0 A B 1
        \\.SUBCKT CONT A
        \\+ B PARAMS: W = 2 ; comment
        \\R1 A B
        \\+ {W}
        \\.ENDS
        \\.MODEL
        \\.MODEL NOTYPE
        \\.SUBCKT OPEN A B
        \\R1 A B 1K
    , "");
    try expectRefusals(s.refused, &.{});
    try std.testing.expectEqual(@as(u32, 2), s.modules);
    try expectHas(s.text, &.{
        "module cont(a, b);",
        "   parameter real w = 2;",
        "   resistor #(.r(w)) r1(a, b);",
        "module open(a, b);",
        "   resistor #(.r(1000)) r1(a, b);",
    });
    try std.testing.expect(std.mem.find(u8, s.text, "r0") == null);
}

test "E.2 a .SUBCKT header and body refuse what they cannot read, and name it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try synthesize(arena,
        \\.SUBCKT
        \\.ENDS
        \\.SUBCKT A=1
        \\.ENDS
        \\.SUBCKT S1 A PARAMS: W=1 B
        \\.ENDS
        \\.SUBCKT S2 A 1X=2
        \\.ENDS
        \\.SUBCKT S3 A B
        \\.PARAM W=1
        \\K1 L1 L2 0.9
        \\X1
        \\X2 A B SUB W=1 C
        \\R1 A
        \\M1 A B NCH
        \\D1 A B DIO 2 3
        \\R2 A B W=
        \\R3 A B {W
        \\.ENDS
    , "");
    try expectRefusals(s.refused, &.{
        "`.subckt` names no definition",
        "`a=1` is not a name for a definition",
        "`b` on `.subckt s1`: neither a node before the parameters nor a `k=v` parameter",
        "`1x` is not a parameter name",
        "`.param` inside a `.subckt` body is not read",
        "a `k` device card is not one VerA reads",
        "`x1` names no subcircuit",
        "the field `c` after its parameters is not read",
        "`r1` has too few fields",
        "`m1` has too few fields",
        "the field `2` after the model is not read",
        "the value `w=` is not a number",
        "the expression value `{w` does not end in `}`",
    });
    try std.testing.expectEqual(@as(u32, 1), s.modules);
    try expectHas(s.text, &.{"module s3(a, b);"});
}

test "E.2 Q's substrate is read as SPICE3 reads it, by which field a .MODEL card names" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // `2N2222` is also SPICE's 2n with unit noise; the `.MODEL` card says it
    // is the model, so `S` before it is the substrate.
    const s = try synthesize(arena,
        \\.MODEL 2N2222 MYBJT BF=100
        \\.MODEL QM MYBJT
        \\.SUBCKT AMP C B E S
        \\Q1 C B E S 2N2222
        \\Q2 C B E 2N2222 3
        \\Q3 C B E QM SUB
        \\.ENDS
    , "");
    try expectHas(s.text, &.{
        "   mybjt #(.bf(100)) q1(c, b, e, s);",
        "   mybjt #(.bf(100), .area(3)) q2(c, b, e);",
    });
    // The fourth field names a model, so the fifth is no substrate.
    try expectRefusals(s.refused, &.{"`q3`: the field `sub` after the model is not read"});
}

test "E.3.1 a controlled source in its POLY, VALUE, TABLE or LAPLACE form is refused, not misread" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try synthesize(arena,
        \\.SUBCKT P A B C D
        \\VS C D 0
        \\E1 A B POLY(1) 5
        \\G1 A B VALUE={V(C)*2}
        \\E2 A B TABLE {V(C)} = (0,0) (1,1)
        \\G2 A B LAPLACE {V(C)} {1/(1+S)}
        \\F1 A B POLY(1) VS 0 2
        \\E3 A B C D 2
        \\.ENDS
    , "");
    try expectRefusals(s.refused, &.{ "`poly`", "`value`", "`table`", "`laplace`", "`poly`" });
    try expectHas(s.text, &.{"V(a, b) <+ 2 * V(c, d);"});
    try std.testing.expect(std.mem.find(u8, s.text, "poly") == null);
}

test "a top-level .LIB block is a library entry, read only when called" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try synthesize(arena,
        \\.LIB TT
        \\.SUBCKT HIDDEN A B
        \\.ENDS
        \\.ENDL
        \\.SUBCKT SEEN A B
        \\.ENDS
        \\.LIB OPEN
        \\.SUBCKT LOST A B
        \\.ENDS
    , "");
    try std.testing.expectEqual(@as(u32, 1), s.modules);
    try expectHas(s.text, &.{"module seen(a, b);"});
    try std.testing.expect(std.mem.find(u8, s.text, "hidden") == null);
    try std.testing.expect(std.mem.find(u8, s.text, "lost") == null);
    try expectRefusals(s.refused, &.{"`.lib` entry has no `.endl`"});
}

test "synthesize reports every allocation failure as OutOfMemory, the unclosed .LIB refusal's too" {
    // A model, a subcircuit with a body, an unsupported type, a refused card
    // and an entry with no `.endl`: every path that allocates on `arena`.
    try std.testing.checkAllAllocationFailures(std.testing.allocator, synthesizeAll, .{
        \\.MODEL RM R R=1K
        \\.MODEL SW1 SW
        \\.SUBCKT S A B
        \\R1 A B 1K
        \\S1 A B
        \\.ENDS
        \\.LIB OPEN
    });
    // The arena above coalesces small allocations, so the unclosed `.lib`
    // refusal is reached directly: its allocation fails, and `read` must say
    // so rather than return with the refusal lost.
    var scratch_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer scratch_state.deinit();
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var refusals: Refusals = .{ .arena = failing.allocator() };
    var r: Reader = .{ .arena = failing.allocator(), .scratch = scratch_state.allocator(), .refusals = &refusals };
    try r.files.append(scratch_state.allocator(), .{ .name = "<spice netlist>", .text = ".lib open\n" });
    try std.testing.expectError(error.OutOfMemory, r.read(0, null));
    try std.testing.expectEqual(@as(usize, 0), refusals.list.items.len);
}

test "Reader: .INCLUDE, .LIB entries and .HDL beside the netlist, and the refusal for each failure" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "inc.sp", .data = ".SUBCKT FROMINC A B\nR1 A B 1K\n.ENDS\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "lib.sp", .data = test_lib });
    try tmp.dir.writeFile(io, .{ .sub_path = "open.sp", .data = ".LIB TT\n.SUBCKT T2 A B\n.ENDS\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "top.sp", .data = test_top });
    const top: []const u8 = try tmp.dir.realPathFileAlloc(io, "top.sp", arena);
    const s = try synthesize(arena, test_top, top);
    // inc.sp twice (the second module is a repeat), lib.sp's `tt` entry and
    // open.sp's unterminated one.
    try std.testing.expectEqual(@as(u32, 3), s.modules);
    try expectHas(s.text, &.{ "module frominc(a, b);", "module typ(a, b);", "module t2(a, b);" });
    try std.testing.expect(std.mem.find(u8, s.text, "fast") == null);
    try expectRefusals(s.refused, &.{
        "has no `.lib ss` entry",
        "`.include` names no file",
        "cannot read",
        "`.lib` entry has no `.endl`",
        "`.hdl` names no file",
    });
    // The unterminated entry is reported in open.sp, the file it is in.
    try std.testing.expect(std.mem.endsWith(u8, s.files[s.refused[3].file].name, "open.sp"));
    // top, inc.sp twice, lib.sp three times, open.sp; nothere.sp is not a file.
    try std.testing.expectEqual(@as(usize, 7), s.files.len);
    try std.testing.expectEqual(@as(usize, 1), s.hdl.len);
    try std.testing.expect(std.mem.endsWith(u8, s.hdl[0], "a.va"));
}

test "Reader: an .INCLUDE cycle is one refusal naming it; finite nesting has no bound" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "self.sp", .data = ".include self.sp\n" });
    const path: []const u8 = try tmp.dir.realPathFileAlloc(io, "self.sp", arena);
    const s = try synthesize(arena, ".include self.sp\n", path);
    try expectRefusals(s.refused, &.{"`.include` cycle:"});
    // The netlist, and self.sp opened once more before the cycle is seen.
    try std.testing.expectEqual(@as(usize, 2), s.files.len);

    // 20 files deep, past the old bound of 16; and one file whose `.LIB`
    // entry calls another entry of the same file, which is no cycle.
    const n = 20;
    for (0..n) |k| {
        const data = if (k + 1 == n) ".SUBCKT DEEP A B\nR1 A B 1K\n.ENDS\n" else try arena.print(".include c{d}.sp\n", .{k + 1});
        try tmp.dir.writeFile(io, .{ .sub_path = try arena.print("c{d}.sp", .{k}), .data = data });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "two.sp", .data = ".LIB a\n.LIB two.sp b\n.ENDL\n.LIB b\n.SUBCKT FROMB A B\nR1 A B 1K\n.ENDS\n.ENDL\n" });
    const top = ".include c0.sp\n.lib two.sp a\n";
    const deep = try synthesize(arena, top, try tmp.dir.realPathFileAlloc(io, "self.sp", arena));
    try std.testing.expectEqual(@as(usize, 0), deep.refused.len);
    try expectHas(deep.text, &.{ "module deep(a, b);", "module fromb(a, b);" });
}

test "fuzz: synthesize never panics on card-shaped text, and every refusal points into its file" {
    try std.testing.fuzz({}, synthesizeOne, .{});
}

test "fuzz: a SPICE expression is read or refused with a reason, never a panic" {
    try std.testing.fuzz({}, expressionOne, .{});
}
