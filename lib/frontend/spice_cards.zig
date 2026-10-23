//! SPICE `.MODEL` and `.SUBCKT` cards in, Verilog-AMS module source text out
//! (LRM annex E.2, E.3). Reads the two interface cards and, inside a
//! `.SUBCKT`, the device cards that form its body. Cards outside a definition
//! (`.tran`, top-level devices) are not module definitions and are skipped
//! without a diagnostic, except a `.MODEL` of a type VerA has no primitive
//! for, which is recorded so an instance of it is refused by name (E0952,
//! E.1.2). The text is prepended to the source like
//! `Preprocessor.spice_primitives`, so §6 instantiation, overrides and their
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

const std = @import("std");
const Allocator = std.mem.Allocator;
const token = @import("token.zig");
const Preprocessor = @import("preprocessor.zig");
const deep_stack = @import("base").deep_stack;
const assert = std.debug.assert;

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

/// A logical card (continuations joined) and where its first line starts;
/// also one physical line of it (`Reader.lines`), comments stripped and
/// lower-cased.
const Card = struct {
    text: []const u8,
    file: u32 = 0,
    at: u32,
    len: u32,
};

/// The refusals of one `synthesize` call.
const Refusals = struct {
    arena: Allocator,
    list: std.ArrayList(Refusal) = .empty,

    fn add(r: *Refusals, card: Card, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
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
/// `Preprocessor.spice_primitives`.
const model_types = [_]struct { type_: []const u8, prim: []const u8, ports: []const u8 }{
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
const ModelCard = struct {
    name: []const u8,
    type_: []const u8,
    card: Card,
};

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

/// Reads netlist files into `lines`, the way SPICE reads them: a `.INCLUDE
/// file` card is replaced by the file's lines, a `.LIB file entry` card by
/// the lines between `.LIB entry` and `.ENDL` in that file, and a `.LIB
/// entry` ... `.ENDL` block met any other way is a library entry, read only
/// when called. A relative file name is looked for beside the file whose
/// card names it, as VD-091 does for `` `include ``. `.HDL file` names a
/// Verilog-A source (`Synthesized.hdl`). A file that cannot be read, an entry
/// it does not have, or a cycle (a file, or a `.LIB` entry of it, read again
/// inside itself, which never ends) is a `Refusal` at the card. Any finite
/// nesting is read.
const Reader = struct {
    arena: Allocator,
    scratch: Allocator,
    refusals: *Refusals,
    /// Every physical line read, one `Card` each, in reading order.
    lines: std.ArrayList(Card) = .empty,
    files: std.ArrayList(File) = .empty,
    hdl: std.ArrayList([]const u8) = .empty,
    /// The files being read now, outermost first: each one's path with `.`
    /// and `..` resolved, and the `.LIB` entry read from it (null: all of
    /// it). Reading one of them again is a cycle.
    reading: std.ArrayList(struct { key: []const u8, entry: ?[]const u8 }) = .empty,

    /// Appends file `fi`'s lines, or with `entry` only those of its `.LIB
    /// entry` block.
    /// Asserts that `fi` names a file already in `files`.
    fn read(r: *Reader, fi: u32, entry: ?[]const u8) Allocator.Error!void {
        assert(fi < r.files.items.len);
        try r.reading.append(r.scratch, .{ .key = try std.fs.path.resolve(r.scratch, &.{r.files.items[fi].name}), .entry = entry });
        defer _ = r.reading.pop();
        const text = r.files.items[fi].text;
        // Inside a `.LIB name` block: true when it is the entry asked for.
        var in_lib: ?bool = null;
        // The open block's header, so one `.ENDL` never closes is not a
        // silent end of the file.
        var header: Card = undefined;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const line = strip(raw);
            if (line.len == 0) continue;
            const at: u32 = @intCast(line.ptr - text.ptr);
            const card: Card = .{ .text = line, .file = fi, .at = at, .len = @intCast(line.len) };
            var it = std.mem.tokenizeAny(u8, line, " \t");
            const kw = try std.ascii.allocLowerString(r.scratch, it.next().?);
            const arg = unquote(it.next() orelse "");
            const arg2 = unquote(it.next() orelse "");
            if (std.mem.eql(u8, kw, ".lib") and arg2.len == 0) {
                // A library entry's header, not a call.
                if (in_lib == null) {
                    in_lib = if (entry) |e| std.ascii.eqlIgnoreCase(e, arg) else false;
                    header = card;
                }
                continue;
            }
            if (std.mem.eql(u8, kw, ".endl")) {
                const done = in_lib orelse false;
                in_lib = null;
                if (done) return;
                continue;
            }
            if (entry != null and !(in_lib orelse false)) continue;
            if (in_lib == false) continue;
            const include = std.mem.eql(u8, kw, ".include") or std.mem.eql(u8, kw, ".inc");
            if (include or std.mem.eql(u8, kw, ".lib")) {
                if (arg.len == 0) {
                    try r.refusals.add(card, "`{s}` names no file", .{kw});
                    continue;
                }
                const sub = try r.open(card, kw, arg) orelse continue;
                const sub_entry: ?[]const u8 = if (include) null else arg2;
                if (try r.cycle(sub, sub_entry)) |chain| {
                    try r.refusals.add(card, "`{s}` cycle: {s}", .{ kw, chain });
                    continue;
                }
                const before = r.lines.items.len;
                // Every 512 nested files continue on a fresh stack segment,
                // so nesting is bounded by memory, not the caller's stack.
                if (r.reading.items.len % 512 != 0) try r.read(sub, sub_entry) else deep_stack.run(512, read, .{ r, sub, sub_entry }) catch |e| switch (e) {
                    error.DeepStackUnavailable => {
                        try r.refusals.add(card, "`{s}`: no stack left for {d} nested files", .{ kw, r.reading.items.len });
                        continue;
                    },
                    error.OutOfMemory => |oom| return oom,
                };
                if (!include and r.lines.items.len == before and !hasEntry(r.files.items[sub].text, arg2))
                    try r.refusals.add(card, "`{s}` has no `.lib {s}` entry", .{ r.files.items[sub].name, arg2 });
                continue;
            }
            if (std.mem.eql(u8, kw, ".hdl")) {
                if (arg.len == 0) {
                    try r.refusals.add(card, "`.hdl` names no file", .{});
                    continue;
                }
                const full = try r.resolve(fi, arg);
                for (r.hdl.items) |h| {
                    if (std.mem.eql(u8, h, full)) break;
                } else try r.hdl.append(r.arena, full);
                continue;
            }
            var lowered = card;
            lowered.text = try std.ascii.allocLowerString(r.scratch, line);
            try r.lines.append(r.scratch, lowered);
        }
        if (in_lib != null) try r.refusals.add(header, "`.lib` entry has no `.endl`; the cards after it are not read", .{});
    }

    /// The chain `a -> b -> a` when reading file `fi` (`entry` of it) now
    /// would repeat a read still open, else null.
    fn cycle(r: *Reader, fi: u32, entry: ?[]const u8) Allocator.Error!?[]const u8 {
        const key = try std.fs.path.resolve(r.scratch, &.{r.files.items[fi].name});
        for (r.reading.items, 0..) |o, k| {
            const same_entry = if (o.entry) |a| (if (entry) |b| std.ascii.eqlIgnoreCase(a, b) else false) else entry == null;
            if (!same_entry or !std.mem.eql(u8, o.key, key)) continue;
            var chain: std.ArrayList(u8) = .empty;
            for (r.reading.items[k..]) |c| try chain.print(r.scratch, "{s} -> ", .{c.key});
            try chain.appendSlice(r.scratch, key);
            return chain.items;
        }
        return null;
    }

    /// `name` beside the file `fi` was opened by, or as written when absolute.
    fn resolve(r: *Reader, fi: u32, name: []const u8) Allocator.Error![]const u8 {
        assert(fi < r.files.items.len);
        assert(r.files.items[0].name.len != 0); // `synthesize` names the netlist
        if (std.fs.path.isAbsolute(name)) return r.arena.dupe(u8, name);
        const dir = std.fs.path.dirname(r.files.items[fi].name) orelse ".";
        const base = if (fi == 0 and r.files.items[0].name[0] == '<') "." else dir;
        return std.fs.path.join(r.arena, &.{ base, name });
    }

    /// Reads the file `card` names (`.include` or `.lib`) into `files`, or
    /// records why not and returns null.
    fn open(r: *Reader, card: Card, kw: []const u8, name: []const u8) Allocator.Error!?u32 {
        const full = try r.resolve(card.file, name);
        const io = std.Io.Threaded.global_single_threaded.io();
        const text = Preprocessor.readText(io, .cwd(), full, r.arena) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                try r.refusals.add(card, "`{s}`: cannot read \"{s}\" ({t})", .{ kw, full, e });
                return null;
            },
        };
        try r.files.append(r.arena, .{ .name = full, .text = text });
        return @intCast(r.files.items.len - 1);
    }
};

/// Whether `text` has a `.LIB entry` header, so an empty entry is not
/// reported as a missing one.
fn hasEntry(text: []const u8, entry: []const u8) bool {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var it = std.mem.tokenizeAny(u8, strip(raw), " \t");
        if (!std.ascii.eqlIgnoreCase(it.next() orelse continue, ".lib")) continue;
        if (std.ascii.eqlIgnoreCase(unquote(it.next() orelse continue), entry) and it.next() == null) return true;
    }
    return false;
}

/// A file name or entry without the `"`/`'` SPICE dialects put around it.
fn unquote(t: []const u8) []const u8 {
    if (t.len >= 2 and (t[0] == '"' or t[0] == '\'') and t[t.len - 1] == t[0]) return t[1 .. t.len - 1];
    return t;
}

/// `card` with the white space around each `=` removed: HSPICE writes
/// `level = 72`, and every reader below splits a parameter on its `=` within
/// one token.
fn tightEquals(arena: Allocator, card: []const u8) Allocator.Error![]const u8 {
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

/// A card's fields: split at blanks and at `(`, `)` and `,`, which are noise
/// in a SPICE card, except inside a `{...}` or `'...'` expression, which is
/// one field whatever it holds (HSPICE writes `{w * 2}`, `'max(a, b)'`).
const Tokens = struct {
    text: []const u8,
    i: usize = 0,

    const seps = " \t(),";

    fn next(t: *Tokens) ?[]const u8 {
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

/// One physical line with its comments removed: `*` is a full-line comment, `;`
/// and `$` start a trailing one.
fn strip(raw: []const u8) []const u8 {
    var line = std.mem.trim(u8, raw, " \t\r");
    if (line.len != 0 and line[0] == '*') return "";
    if (std.mem.findAny(u8, line, ";$")) |at| line = std.mem.trim(u8, line[0..at], " \t");
    return line;
}

// ponytail: the first `.ENDS` ends it. A nested `.SUBCKT` is refused
// (`emitBody`), so closing the outer one early never produces a module.

/// Returns the cards `rest[0]` owns, excluding the terminating `.ENDS`; empty
/// unless `rest[0]` is a `.SUBCKT` header. E.2 makes a subcircuit a module
/// definition and E.2.2.2 shows its device cards as its body. Asserts that
/// `rest` is not empty.
fn subcktBody(rest: []const Card) []const Card {
    assert(rest.len != 0);
    if (!std.mem.startsWith(u8, rest[0].text, ".subckt")) return &.{};
    for (rest[1..], 1..) |card, i| {
        if (std.mem.startsWith(u8, card.text, ".ends")) return rest[1..i];
    }
    return rest[1..]; // an unterminated `.SUBCKT` still has a body
}

/// Emits one complete card, plus the body `subcktBody` gave it. Returns true
/// if it produced a module.
fn emitCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    card: Card,
    body: []const Card,
    models: []const ModelCard,
    seen: *std.ArrayList([]const u8),
    refusals: *Refusals,
    unsupported: *std.ArrayList([]const u8),
) Allocator.Error!bool {
    // `(` `)` and `,` are noise in a SPICE port list: E.2.2.2's own example
    // writes `.SUBCKT ECPOSC (OUT GND)` with parentheses that carry no meaning.
    var it: Tokens = .{ .text = card.text };
    const kw = it.next() orelse return false;
    const is_model = std.mem.eql(u8, kw, ".model");
    if (!is_model and !std.mem.eql(u8, kw, ".subckt")) return false; // a device card, .tran, .include, ...

    const name = it.next() orelse {
        if (!is_model) try refusals.add(card, "`{s}` names no definition", .{kw});
        return false;
    };
    if (!isSpiceName(name)) {
        if (!is_model) try refusals.add(card, "`{s}` is not a name for a definition", .{name});
        return false;
    }
    for (seen.items) |s| if (std.mem.eql(u8, s, name)) return false;
    // `seen` keeps the bare name: the escape is a spelling of it, so two cards
    // named `wire` are still a repeat.
    const decl = try spell(arena, name);

    if (is_model) {
        const type_ = it.next() orelse return false;
        const row = for (model_types) |r| {
            if (std.mem.eql(u8, r.type_, type_)) break r;
        } else {
            // E.1.2: "a particular SPICE netlist can reference a primitive
            // which is unsupported". Kept, so its use is named as that.
            try seen.append(arena, name);
            try unsupported.append(arena, try arena.print("{s} {s}", .{ name, type_ }));
            return false;
        };
        // E.2.2.1: the interface is the primitive's. The body instantiates the
        // primitive, so the model behaves as Table E.1's Behavior column gives
        // that row; an empty column (bjt, mosfet, diode) gives nothing, which
        // E.2 makes implementation dependent.
        const params = try modelParams(arena, row.prim, &it, name, card, refusals) orelse return false;
        try out.print(arena,
            \\module {s}({s});
            \\   inout {s};
            \\   electrical {s};
            \\{s}   {s} #({s}) prim({s});
            \\endmodule
            \\
            \\
        , .{ decl, row.ports, row.ports, row.ports, params.decls, row.prim, params.args, row.ports });
    } else {
        // `.SUBCKT name p1 p2 ... [PARAMS:] [k=v ...]`: ports up to the first
        // parameter. Numeric nodes are the SPICE default (`1`, `2`, `0`), so
        // only a parameter ends the list. Each `k=v` (HSPICE's PARAMS:, which
        // HSPICE also lets go unwritten) is a real parameter of the module
        // with `v` as its default, a number or a `{expr}` over the parameters
        // before it; the body's expressions read them all.
        var ports: std.ArrayList([]const u8) = .empty;
        var params: std.ArrayList([]const u8) = .empty;
        var decls: std.ArrayList(u8) = .empty;
        var in_params = false;
        while (it.next()) |t| {
            if (std.mem.eql(u8, t, "params:")) {
                in_params = true;
                continue;
            }
            const eq = std.mem.findScalar(u8, t, '=') orelse {
                if (in_params or !isSpiceName(t)) {
                    try refusals.add(card, "`{s}` on `.subckt {s}`: neither a node before the parameters nor a `k=v` parameter", .{ t, name });
                    return false;
                }
                try ports.append(arena, try spell(arena, t));
                continue;
            };
            in_params = true;
            if (!isIdent(t[0..eq])) {
                try refusals.add(card, "`{s}` on `.subckt {s}`: `{s}` is not a parameter name", .{ t, name, t[0..eq] });
                return false;
            }
            const v = try paramValue(arena, t, eq, name, card, refusals, params.items) orelse return false;
            try decls.print(arena, "   parameter real {s} = {f};\n", .{ try spell(arena, t[0..eq]), v });
            try params.append(arena, t[0..eq]);
        }
        // A.1.2 makes the port list optional, so a portless `.SUBCKT` is a legal
        // module, and an empty `electrical ;` would not be.
        if (ports.items.len == 0) {
            try out.print(arena, "module {s};\n", .{decl});
        } else {
            const list = try std.mem.join(arena, ", ", ports.items);
            try out.print(arena,
                \\module {s}({s});
                \\   inout {s};
                \\   electrical {s};
                \\
            , .{ decl, list, list, list });
        }
        try out.appendSlice(arena, decls.items);
        var inner: std.ArrayList(u8) = .empty;
        try emitBody(arena, &inner, body, models, params.items, refusals);
        // SPICE's node 0 is the global ground inside a subcircuit too. Spelled
        // `\0 ` (only a node can be: values are numbers) it would be a local
        // implicit net and every card on it an open; declared `ground`, it
        // is §3.6.4's "global reference node in the circuit".
        const zero_port = for (ports.items) |pt| {
            if (std.mem.eql(u8, pt, "\\0 ")) break true;
        } else false;
        if (!zero_port and std.mem.find(u8, inner.items, "\\0 ") != null)
            try out.appendSlice(arena, "   electrical \\0 ;\n   ground \\0 ;\n");
        try out.appendSlice(arena, inner.items);
        try out.appendSlice(arena, "endmodule\n\n");
    }
    try seen.append(arena, name);
    return true;
}

/// Device card letters and the Table E.1 primitive each becomes. E.2.2.3, the
/// only place the LRM says what a device card means, prints `R1 B1 GND 10K` as
/// `resistor #(.r(10k)) R1 (b1, gnd);`, `VA VCC GND 5` as
/// `vsine #(.dc(5)) Vcc (vcc, gnd);` and `IEE E GND 1MA` as
/// `isine #(.dc(1m)) Iee (e, gnd);`: the leading letter picks the primitive and
/// the one positional value lands on `param`. `c` and `l` are the other
/// two-terminal rows whose Behavior column Table E.1 fills in; letters with an
/// empty one (`Q`, `M`, `J`, `D`) have no equation here, and are read only
/// with a model (`model_cards`).
const device_cards = [_]struct { letter: u8, prim: []const u8, param: []const u8 }{
    .{ .letter = 'r', .prim = "resistor", .param = "r" },
    .{ .letter = 'c', .prim = "capacitor", .param = "c" },
    .{ .letter = 'l', .prim = "inductor", .param = "l" },
    .{ .letter = 'v', .prim = "vsine", .param = "dc" },
    .{ .letter = 'i', .prim = "isine", .param = "dc" },
};

/// E.3.1: "the following primitives are not supported: ccvs, cccs, and mutual
/// inductors; however, these primitives can be instantiated inside a SPICE
/// subcircuit". The four SPICE controlled-source letters, as the one
/// contribution each is, in SPICE's own sign convention: the controlled
/// quantity flows (or rises) from the card's first node to its second, which
/// is what `I(a, b)`/`V(a, b)` mean in §5.6:
///
///     E n+ n- nc+ nc- gain    V(n+, n-) <+ gain * V(nc+, nc-);   vcvs
///     G n+ n- nc+ nc- gm      I(n+, n-) <+ gm * V(nc+, nc-);     vccs
///     F n+ n- vctl gain       I(n+, n-) <+ gain * I(vctl);       cccs
///     H n+ n- vctl r          V(n+, n-) <+ r * I(vctl);          ccvs
///
/// `I(vctl)` is the current through the controlling V card, which SPICE takes
/// entering its first node. A V card that controls something is therefore
/// written as a named branch of this module (`branch (p, n) vctl;
/// V(vctl) <+ dc;`) rather than a `vsine` child, so the controlled source reads
/// the flow of a branch its own module declares (§5.4.2's flow probe of the
/// source branch) with no cross-instance access.
const controlled = [_]struct { letter: u8, lhs: []const u8, rhs: []const u8, by_current: bool }{
    .{ .letter = 'e', .lhs = "V", .rhs = "V", .by_current = false },
    .{ .letter = 'g', .lhs = "I", .rhs = "V", .by_current = false },
    .{ .letter = 'f', .lhs = "I", .rhs = "I", .by_current = true },
    .{ .letter = 'h', .lhs = "V", .rhs = "I", .by_current = true },
};

// The keywords (HSPICE and ngspice) that open a controlled source's
// polynomial, behavioural, table or frequency-domain form.
const source_forms = [_][]const u8{ "poly", "value", "table", "laplace", "freq" };

// ponytail: two terminals and one positional value, which is every row of
// `device_cards`; a three-terminal or `k=v` card needs its own arity column.
// The `controlled` letters are the exception, and read their own shape.

/// Emits the instance lines and analog contributions a `.SUBCKT`'s device
/// cards become. `scope` is the subcircuit's parameters, the names a
/// `{expr}` value may read.
///
/// A card this cannot read is a `Refusal`: a letter with no `device_cards`,
/// `controlled` or `model_cards` row and not `X` (`S`, `T`, `K`), a value
/// that is a model name (`R1 A B RMOD`) or an expression `expression` does
/// not read, a missing or extra field, a controlled source in its `POLY`,
/// `VALUE`, `TABLE` or `LAPLACE` form, a nested `.SUBCKT` or any other dot
/// card (`.PARAM` included).
///
/// A node the port list does not name needs no declaration: it is an implicit
/// net of the synthesized module, resolved by §7.5 from the primitive port it
/// touches.
fn emitBody(
    arena: Allocator,
    out: *std.ArrayList(u8),
    body: []const Card,
    models: []const ModelCard,
    scope: []const []const u8,
    refusals: *Refusals,
) Allocator.Error!void {
    // The V cards an F or H card reads the current of, by name.
    var controls: std.ArrayList([]const u8) = .empty;
    for (body) |card| {
        var it: Tokens = .{ .text = card.text };
        const inst = it.next() orelse continue;
        if (inst[0] != 'f' and inst[0] != 'h') continue;
        _ = it.next() orelse continue;
        _ = it.next() orelse continue;
        try controls.append(arena, it.next() orelse continue);
    }
    var analog: std.ArrayList(u8) = .empty;
    for (body) |card| {
        var it: Tokens = .{ .text = card.text };
        const inst = it.next() orelse continue;
        if (inst[0] == '.') {
            if (std.mem.eql(u8, inst, ".subckt"))
                try refusals.add(card, "a `.subckt` inside a `.subckt` body: nested subcircuits are not read", .{})
            else
                try refusals.add(card, "`{s}` inside a `.subckt` body is not read", .{inst});
            continue;
        }
        const short = "`{s}` has too few fields";
        if (for (controlled) |c| {
            if (inst[0] == c.letter) break c;
        } else null) |c| {
            const p = try spell(arena, it.next() orelse {
                try refusals.add(card, short, .{inst});
                continue;
            });
            const n = try spell(arena, it.next() orelse {
                try refusals.add(card, short, .{inst});
                continue;
            });
            // SPICE's other shapes of these letters put a keyword where the
            // control goes; read as nodes, `E1 A B POLY(1) 5` would be a gain
            // on V(poly, 1).
            var look = it;
            const field = look.next() orelse "";
            const key = field[0 .. std.mem.findScalar(u8, field, '=') orelse field.len];
            if (for (source_forms) |k| {
                if (std.mem.eql(u8, k, key)) break true;
            } else false) {
                try refusals.add(card, "`{s}`: the `{s}` form of a controlled source is not read", .{ inst, key });
                continue;
            }
            // The controlling quantity: a V card's branch, or a node pair.
            const ctl = if (c.by_current) blk: {
                const v = it.next() orelse {
                    try refusals.add(card, short, .{inst});
                    continue;
                };
                if (v[0] != 'v' or !declares(body, v)) {
                    try refusals.add(card, "`{s}` reads the current of `{s}`, which is not a V card of this subcircuit", .{ inst, v });
                    continue;
                }
                break :blk try spell(arena, v);
            } else try arena.print("{s}, {s}", .{
                try spell(arena, it.next() orelse {
                    try refusals.add(card, short, .{inst});
                    continue;
                }),
                try spell(arena, it.next() orelse {
                    try refusals.add(card, short, .{inst});
                    continue;
                }),
            });
            const gain = try cardValue(arena, it.next(), &it, inst, card, refusals, scope) orelse continue;
            try analog.print(arena, "      {s}({s}, {s}) <+ {f} * {s}({s});\n", .{ c.lhs, p, n, gain, c.rhs, ctl });
            continue;
        }
        if (for (model_cards) |m| {
            if (inst[0] == m.letter) break m;
        } else null) |m| {
            try emitModelCard(arena, out, card, inst, &it, m, models, scope, refusals);
            continue;
        }
        if (inst[0] == 'x') {
            try emitSubcktCard(arena, out, card, inst, &it, scope, refusals);
            continue;
        }
        const row = for (device_cards) |d| {
            if (inst[0] == d.letter) break d;
        } else {
            try refusals.add(card, "`{s}`: a `{c}` device card is not one VerA reads in a subcircuit (R, C, L, V, I, E, F, G, H, M, Q, J, D, X)", .{ inst, inst[0] });
            continue;
        };
        const p = it.next() orelse {
            try refusals.add(card, short, .{inst});
            continue;
        };
        const n = it.next() orelse {
            try refusals.add(card, short, .{inst});
            continue;
        };
        const value = try cardValue(arena, it.next(), &it, inst, card, refusals, scope) orelse continue;
        if (row.letter == 'v' and for (controls.items) |v| {
            if (std.mem.eql(u8, v, inst)) break true;
        } else false) {
            // An independent source, so §9.15's source-stepping factor scales
            // it, as it does the Annex E sources.
            const name = try spell(arena, inst);
            try out.print(arena, "   branch ({s}, {s}) {s};\n", .{ try spell(arena, p), try spell(arena, n), name });
            try analog.print(arena, "      V({s}) <+ $simparam(\"sourceScaleFactor\") * {f};\n", .{ name, value });
            continue;
        }
        try out.print(arena, "   {s} #(.{s}({f})) {s}({s}, {s});\n", .{
            row.prim,
            row.param,
            value,
            try spell(arena, inst),
            try spell(arena, p),
            try spell(arena, n),
        });
    }
    if (analog.items.len != 0) try out.print(arena, "   analog begin\n{s}   end\n", .{analog.items});
}

/// SPICE3's semiconductor device cards: the letter, its node count before
/// the model name, and the Table E.1 primitive a `.MODEL` of a Table E.1
/// type would make it (`emitModelCard`):
///
///     M d g s b model [k=v ...]
///     Q c b e [s] model [area] [k=v ...]
///     J d g s model [area] [k=v ...]
///     D a c model [area] [k=v ...]
///
/// Q's substrate is read as SPICE3 reads it: the fourth field is the model
/// when a `.MODEL` card names it; otherwise the fifth is, when a `.MODEL`
/// card names it or it is not a number (`2N2222` is both a model name and
/// SPICE's 2n with unit noise, so the card decides).
const model_cards = [_]struct { letter: u8, nodes: u8, prim: []const u8 }{
    .{ .letter = 'm', .nodes = 4, .prim = "mosfet" },
    .{ .letter = 'q', .nodes = 3, .prim = "bjt" },
    .{ .letter = 'j', .nodes = 3, .prim = "jfet" },
    .{ .letter = 'd', .nodes = 2, .prim = "diode" },
};

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

/// A card value: a number, or a `{expr}` as Verilog-AMS text (`expression`),
/// which elaboration evaluates against the subcircuit's parameters.
const Value = union(enum) {
    num: f64,
    expr: []const u8,

    pub fn format(v: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (v) {
            // `{d}`'s plain decimal, except an integral value of 2^31 or
            // more, which `{d}` would spell as an integer literal too wide
            // for §3.2's 32-bit integer; `{e}` keeps it real.
            .num => |n| if (@abs(n) >= 0x1p31 and @trunc(n) == n) try w.print("{e}", .{n}) else try w.print("{d}", .{n}),
            .expr => |e| try w.writeAll(e),
        }
    }
};

/// One `.name(value)` an instance carries.
const Override = struct { name: []const u8, value: Value };

/// Emits the instance an M/Q/J/D card is (`model_cards`). E.2: "models
/// contained within the SPICE netlist are treated as module definitions",
/// and E.1.1 lets "anything that can be instantiated in the particular flavor
/// of SPICE" be instantiated from Verilog-AMS. The card's model name
/// resolves, in order, to
///
///   - a `.MODEL name type ...` card whose type is no Table E.1 row: an
///     instance of `type`, a Verilog-A module or paramset of the design (the
///     HSPICE/Spectre `.model nch bsim4 ...` naming a compiled model), the
///     card's parameters as overrides;
///   - a `.MODEL` of a Table E.1 type (nmos, npn, d, ...): the rows Table E.1
///     leaves without a Behavior, which E.2 makes "implementation dependent",
///     and VerA has no equations for. Refused (E0953): an instance with no
///     behaviour would be an open where the netlist has a transistor;
///   - binned model cards `.MODEL name.N type ... LMIN= LMAX= WMIN= WMAX=`
///     (E.4.2's "model binning"): the first bin, in card order, that holds the
///     card's numeric L and W, lmin <= L < lmax and wmin <= W < wmax (a bound
///     the bin card does not give is open), read as the case above without
///     its four bounds, which only select. A card whose L or W is missing or
///     an expression, or that no bin holds, is refused: VerA chooses the bin
///     here, before elaboration;
///   - no `.MODEL` of that name: the name itself, as a module or paramset of
///     the design; one naming nothing is E0904 at elaboration.
///
/// The card's own parameters (`W=`, `L=`, `NFIN=`, a positional area)
/// override the model card's of the same name, and `M=` is E.4.1's
/// multiplicity factor, the §6.3.6 `$mfactor`. A card value may be a
/// `{expr}` over `scope`, a model card's only over numbers. Names keep the
/// netlist's lower case: elaboration matches them to the module's regardless
/// of case (E.2.1, `spiceCase`).
fn emitModelCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    card: Card,
    inst: []const u8,
    it: *Tokens,
    row: @TypeOf(model_cards[0]),
    models: []const ModelCard,
    scope: []const []const u8,
    refusals: *Refusals,
) Allocator.Error!void {
    var plain: std.ArrayList([]const u8) = .empty;
    var over: std.ArrayList(Override) = .empty;
    while (it.next()) |t| {
        const eq = std.mem.findScalar(u8, t, '=') orelse {
            if (over.items.len != 0)
                return refusals.add(card, "`{s}`: the field `{s}` after its parameters is not read", .{ inst, t });
            try plain.append(arena, t);
            continue;
        };
        try setOverride(arena, &over, t[0..eq], try paramValue(arena, t, eq, inst, card, refusals, scope) orelse return);
    }
    // Q's substrate is optional. SPICE3 takes the fourth field as the model
    // when a `.MODEL` names it; otherwise a fifth field a `.MODEL` names, or
    // one that is not a number, is the model after a substrate.
    const substrate = row.letter == 'q' and plain.items.len >= 5 and !namesModel(models, plain.items[3]) and
        (namesModel(models, plain.items[4]) or spiceNumber(plain.items[4]) == null);
    const nodes: usize = if (substrate) 4 else row.nodes;
    if (plain.items.len <= nodes) return refusals.add(card, "`{s}` has too few fields", .{inst});
    const model = plain.items[nodes];
    var extra = plain.items[nodes + 1 ..];
    // A positional area (Q, J, D) is Table E.1's `area`; `area=` wins.
    if (row.letter != 'm' and extra.len == 1) if (spiceNumber(extra[0])) |a| {
        for (over.items) |o| {
            if (std.mem.eql(u8, o.name, "area")) break;
        } else try over.append(arena, .{ .name = "area", .value = .{ .num = a } });
        extra = extra[1..];
    };
    if (extra.len != 0) return refusals.add(card, "`{s}`: the field `{s}` after the model is not read", .{ inst, extra[0] });

    var module = model;
    var params: std.ArrayList(Override) = .empty;
    const found = for (models) |m| {
        if (std.mem.eql(u8, m.name, model)) break m;
    } else try pickBin(card, inst, model, models, over.items, refusals) orelse return;
    if (found) |m| {
        if (for (model_types) |t| {
            if (std.mem.eql(u8, t.type_, m.type_)) break t;
        } else null) |t| {
            try refusals.list.append(refusals.arena, .{
                .file = card.file,
                .at = card.at,
                .len = card.len,
                .code = .E0953,
                .why = try refusals.arena.print("`{s}`: its model `{s}` is `.model {s} {s}`, Table E.1's `{s}`, which has no behaviour in VerA; name a Verilog-A module as the model's type (`.model {s} <module> ...`)", .{ inst, model, m.name, m.type_, t.prim, m.name }),
            });
            return;
        }
        module = m.type_;
        // A bin (`name.N`, picked or named) keeps its bounds to itself.
        const binned = std.mem.findScalar(u8, m.name, '.') != null;
        var mit: Tokens = .{ .text = m.card.text };
        for (0..3) |_| _ = mit.next(); // `.model name type`
        while (mit.next()) |t| {
            const eq = std.mem.findScalar(u8, t, '=') orelse
                return refusals.add(card, "`{s}`: the field `{s}` of `.model {s}` is not read", .{ inst, t, m.name });
            if (binned and std.meta.stringToEnum(BinBound, t[0..eq]) != null) continue;
            try setOverride(arena, &params, t[0..eq], try paramValue(arena, t, eq, inst, card, refusals, &.{}) orelse return);
        }
    }
    for (over.items) |o| try setOverride(arena, &params, o.name, o.value);
    try emitInstance(arena, out, module, params.items, inst, plain.items[0..nodes]);
}

/// A bin card's four bounds, in the order `pickBin` keeps them.
const BinBound = enum { lmin, lmax, wmin, wmax };

/// The bin of the binned model `model` that holds the card's L and W
/// (`emitModelCard`), wrapped in an optional: `.{null}` when `model` is not
/// binned at all, null after a refusal.
fn pickBin(card: Card, inst: []const u8, model: []const u8, models: []const ModelCard, over: []const Override, refusals: *Refusals) Allocator.Error!??ModelCard {
    const any = for (models) |m| {
        if (isBinOf(m.name, model)) break true;
    } else false;
    if (!any) return @as(?ModelCard, null);
    // The card's L and W, numbers: the bin is chosen here, before elaboration.
    var lw: [2]f64 = undefined;
    for ([_][]const u8{ "l", "w" }, &lw) |key, *dst| {
        const o = for (over) |o| {
            if (std.mem.eql(u8, o.name, key)) break o;
        } else {
            try refusals.add(card, "`{s}`: `{s}` is a binned model (`.model {s}.N`), chosen by the card's L and W, and the card gives no {s}", .{ inst, model, model, key });
            return null;
        };
        dst.* = switch (o.value) {
            .num => |v| v,
            .expr => {
                try refusals.add(card, "`{s}`: `{s}` is a binned model (`.model {s}.N`), chosen by the card's L and W, and its {s} is an expression", .{ inst, model, model, key });
                return null;
            },
        };
    }
    for (models) |m| {
        if (!isBinOf(m.name, model)) continue;
        // lmin, lmax, wmin, wmax; a bound the card does not give is open.
        var b = [4]f64{ 0, std.math.inf(f64), 0, std.math.inf(f64) };
        var mit: Tokens = .{ .text = m.card.text };
        for (0..3) |_| _ = mit.next(); // `.model name type`
        while (mit.next()) |t| {
            const eq = std.mem.findScalar(u8, t, '=') orelse continue;
            const k = std.meta.stringToEnum(BinBound, t[0..eq]) orelse continue;
            b[@backingInt(k)] = spiceNumber(t[eq + 1 ..]) orelse {
                try refusals.add(card, "`{s}`: the bound `{s}` of the bin `.model {s}` is not a number", .{ inst, t, m.name });
                return null;
            };
        }
        if (b[0] <= lw[0] and lw[0] < b[1] and b[2] <= lw[1] and lw[1] < b[3]) return @as(?ModelCard, m);
    }
    try refusals.add(card, "`{s}`: no bin of the binned model `{s}` (`.model {s}.N`) holds L={d}, W={d}", .{ inst, model, model, lw[0], lw[1] });
    return null;
}

// Whether `name` is a bin of the binned model `model`: `model.N`.
fn isBinOf(name: []const u8, model: []const u8) bool {
    return name.len > model.len + 1 and std.mem.startsWith(u8, name, model) and name[model.len] == '.';
}

// Whether a `.MODEL` card names `name`, itself or as a binned model.
fn namesModel(models: []const ModelCard, name: []const u8) bool {
    for (models) |m| if (std.mem.eql(u8, m.name, name) or isBinOf(m.name, name)) return true;
    return false;
}

/// Emits the instance an X card is: `Xname n1 ... nk subckt [PARAMS:] [k=v
/// ...]`, an instance of the subcircuit (or any module or paramset of the
/// design) `subckt`, connected by position (E.2: subcircuits "are treated as
/// module definitions"), each `k=v` an override of its parameter, a number
/// or a `{expr}` over `scope`, and `M=` E.4.1's `$mfactor`.
fn emitSubcktCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    card: Card,
    inst: []const u8,
    it: *Tokens,
    scope: []const []const u8,
    refusals: *Refusals,
) Allocator.Error!void {
    var plain: std.ArrayList([]const u8) = .empty;
    var over: std.ArrayList(Override) = .empty;
    while (it.next()) |t| {
        if (std.mem.eql(u8, t, "params:")) continue;
        const eq = std.mem.findScalar(u8, t, '=') orelse {
            if (over.items.len != 0)
                return refusals.add(card, "`{s}`: the field `{s}` after its parameters is not read", .{ inst, t });
            try plain.append(arena, t);
            continue;
        };
        try setOverride(arena, &over, t[0..eq], try paramValue(arena, t, eq, inst, card, refusals, scope) orelse return);
    }
    const sub = plain.pop() orelse return refusals.add(card, "`{s}` names no subcircuit", .{inst});
    try emitInstance(arena, out, sub, over.items, inst, plain.items);
}

/// `   module #(.k(v), ...) inst(n1, ...);`, `m` written as `$mfactor`.
fn emitInstance(arena: Allocator, out: *std.ArrayList(u8), module: []const u8, params: []const Override, inst: []const u8, nodes: []const []const u8) Allocator.Error!void {
    try out.print(arena, "   {s} ", .{try spell(arena, module)});
    if (params.len != 0) {
        try out.appendSlice(arena, "#(");
        for (params, 0..) |p, i| {
            if (i != 0) try out.appendSlice(arena, ", ");
            const name = if (std.mem.eql(u8, p.name, "m")) "$mfactor" else try spell(arena, p.name);
            try out.print(arena, ".{s}({f})", .{ name, p.value });
        }
        try out.appendSlice(arena, ") ");
    }
    try out.print(arena, "{s}(", .{try spell(arena, inst)});
    for (nodes, 0..) |n, i| try out.print(arena, "{s}{s}", .{ if (i == 0) "" else ", ", try spell(arena, n) });
    try out.appendSlice(arena, ");\n");
}

/// Sets `name` in `list`, replacing an earlier value: a later assignment of
/// one parameter wins, as an instance's does over its model card's.
fn setOverride(arena: Allocator, list: *std.ArrayList(Override), name: []const u8, value: Value) Allocator.Error!void {
    for (list.items) |*o| if (std.mem.eql(u8, o.name, name)) {
        o.value = value;
        return;
    };
    try list.append(arena, .{ .name = name, .value = value });
}

/// The value `t[eq + 1 ..]` of the parameter assignment `t`: a number, or a
/// `{expr}` over `scope`; null after recording why it is neither. Asserts
/// that `eq` is the index of an `=` in `t`.
fn paramValue(arena: Allocator, t: []const u8, eq: usize, inst: []const u8, card: Card, refusals: *Refusals, scope: []const []const u8) Allocator.Error!?Value {
    assert(eq < t.len);
    assert(t[eq] == '=');
    const v = t[eq + 1 ..];
    if (eq == 0 or v.len == 0) {
        try refusals.add(card, "`{s}`: `{s}` is not a parameter assignment", .{ inst, t });
        return null;
    }
    if (spiceNumber(v)) |n| return .{ .num = n };
    if (v[0] == '{' or v[0] == '\'') return exprValue(arena, v, inst, card, refusals, scope);
    try refusals.add(card, "`{s}`: the value `{s}` of `{s}` is not a number", .{ inst, v, t[0..eq] });
    return null;
}

/// The `{expr}` or `'expr'` field `v` as a `Value`, or null after recording
/// why `expression` does not read it. Asserts that `v` opens with `{` or
/// `'`, which is how every caller tells an expression from a number.
fn exprValue(arena: Allocator, v: []const u8, inst: []const u8, card: Card, refusals: *Refusals, scope: []const []const u8) Allocator.Error!?Value {
    assert(v.len != 0);
    assert(v[0] == '{' or v[0] == '\'');
    const close: u8 = if (v[0] == '{') '}' else '\'';
    if (v.len < 2 or v[v.len - 1] != close) {
        try refusals.add(card, "`{s}`: the expression value `{s}` does not end in `{c}`", .{ inst, v, close });
        return null;
    }
    switch (try expression(arena, v[1 .. v.len - 1], scope)) {
        .text => |text| return .{ .expr = text },
        .refused => |why| {
            try refusals.add(card, "`{s}`: the expression value `{s}` {s}", .{ inst, v, why });
            return null;
        },
    }
}

/// A device card's one positional value, with nothing after it, or null after
/// recording why not: a model name (`R1 A B RMOD`), an expression
/// `expression` does not read, a missing value, or a trailing field (`TC=...`,
/// `AC 1`) whose meaning would be dropped.
fn cardValue(
    arena: Allocator,
    t: ?[]const u8,
    it: *Tokens,
    inst: []const u8,
    card: Card,
    refusals: *Refusals,
    scope: []const []const u8,
) Allocator.Error!?Value {
    const v = t orelse {
        try refusals.add(card, "`{s}` has too few fields", .{inst});
        return null;
    };
    const value: Value = if (spiceNumber(v)) |n| .{ .num = n } else if (v[0] == '{' or v[0] == '\'')
        try exprValue(arena, v, inst, card, refusals, scope) orelse return null
    else {
        try refusals.add(card, "`{s}`: the value `{s}` is not a number (a model-referenced card is not read)", .{ inst, v });
        return null;
    };
    if (it.next()) |extra| {
        try refusals.add(card, "`{s}`: the field `{s}` after the value is not read", .{ inst, extra });
        return null;
    }
    return value;
}

/// The functions a SPICE expression may call: each means the same in HSPICE
/// and ngspice as in §4.3.1-4.3.2 (`log`, natural in SPICE and base 10 here, is
/// not one).
const expr_fns = [_][]const u8{ "sqrt", "exp", "abs", "min", "max", "pow", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "floor", "ceil" };

/// What `expression` makes of a SPICE expression.
const Expr = union(enum) {
    /// Verilog-AMS source with the same value.
    text: []const u8,
    /// Why it is not read, to follow "the expression value `{...}`".
    refused: []const u8,
};

/// A SPICE expression (the inside of `{...}` or `'...'`) as Verilog-AMS
/// text. Read: numbers in SPICE's scaled notation, written as real literals
/// (`1k` is `1e3`, and `1/3` is a third, not §4.2.1's integer 0); the names in
/// `scope`, a subcircuit's parameters; `+ - * /`; `**`, HSPICE's power; unary
/// `+` and `-`; parentheses; and the `expr_fns` calls. Power binds tighter
/// than a unary minus on its left (`-2**2` is -4), and every operation is
/// parenthesized, so the grammar's precedence is the text's. Anything else
/// (`.param` names, `^`, comparisons, `?:`, other functions) is refused.
/// Nesting (parentheses, calls, unary signs) has no bound but memory: the
/// recursion continues on a fresh stack segment every `ExprParser.segment`
/// levels.
fn expression(arena: Allocator, src: []const u8, scope: []const []const u8) Allocator.Error!Expr {
    var p: ExprParser = .{ .arena = arena, .src = src, .scope = scope };
    const text = try p.sum() orelse return .{ .refused = p.why.? };
    p.skip();
    if (p.i != src.len) return .{ .refused = try arena.print("has `{s}` after a complete expression", .{src[p.i..]}) };
    return .{ .text = text };
}

/// `expression`'s recursive descent. Each rule returns its Verilog-AMS
/// text, or null with `why` set.
const ExprParser = struct {
    arena: Allocator,
    src: []const u8,
    scope: []const []const u8,
    i: usize = 0,
    why: ?[]const u8 = null,
    /// `unary` frames open; every recursive rule passes through `unary`.
    depth: u32 = 0,

    /// `unary` levels one stack segment holds (`deep_stack`).
    const segment = 1024;

    fn refuse(p: *ExprParser, comptime fmt: []const u8, args: anytype) Allocator.Error!?[]const u8 {
        if (p.why == null) p.why = try p.arena.print(fmt, args);
        return null;
    }

    fn skip(p: *ExprParser) void {
        while (p.i < p.src.len and (p.src[p.i] == ' ' or p.src[p.i] == '\t')) p.i += 1;
    }

    /// Consumes `tok` after blanks when it is next. `*` is not taken from
    /// the front of a `**`.
    fn eat(p: *ExprParser, tok: []const u8) bool {
        p.skip();
        if (!std.mem.startsWith(u8, p.src[p.i..], tok)) return false;
        if (std.mem.eql(u8, tok, "*") and std.mem.startsWith(u8, p.src[p.i..], "**")) return false;
        p.i += tok.len;
        return true;
    }

    /// sum := product (('+' | '-') product)*
    fn sum(p: *ExprParser) Allocator.Error!?[]const u8 {
        var acc = try p.product() orelse return null;
        while (true) {
            const op: []const u8 = if (p.eat("+")) "+" else if (p.eat("-")) "-" else return acc;
            const rhs = try p.product() orelse return null;
            acc = try p.arena.print("({s} {s} {s})", .{ acc, op, rhs });
        }
    }

    /// product := unary (('*' | '/') unary)*
    fn product(p: *ExprParser) Allocator.Error!?[]const u8 {
        var acc = try p.unary() orelse return null;
        while (true) {
            const op: []const u8 = if (p.eat("*")) "*" else if (p.eat("/")) "/" else return acc;
            const rhs = try p.unary() orelse return null;
            acc = try p.arena.print("({s} {s} {s})", .{ acc, op, rhs });
        }
    }

    /// unary := ('+' | '-') unary | power
    fn unary(p: *ExprParser) Allocator.Error!?[]const u8 {
        if (p.depth == 0 or p.depth % segment != 0) return p.unaryHere();
        return deep_stack.run(segment, unaryHere, .{p}) catch |e| switch (e) {
            error.DeepStackUnavailable => p.refuse("nests {d} levels deep, past the stack memory allows", .{p.depth}),
            error.OutOfMemory => |oom| oom,
        };
    }

    fn unaryHere(p: *ExprParser) Allocator.Error!?[]const u8 {
        p.depth += 1;
        defer p.depth -= 1;
        if (p.eat("-")) return try p.arena.print("(-{s})", .{try p.unary() orelse return null});
        if (p.eat("+")) return p.unary();
        return p.power();
    }

    /// power := atom ('**' unary)?
    fn power(p: *ExprParser) Allocator.Error!?[]const u8 {
        const base = try p.atom() orelse return null;
        if (!p.eat("**")) return base;
        return try p.arena.print("({s} ** {s})", .{ base, try p.unary() orelse return null });
    }

    /// atom := number | name | function '(' sum (',' sum)* ')' | '(' sum ')'
    fn atom(p: *ExprParser) Allocator.Error!?[]const u8 {
        p.skip();
        if (p.i == p.src.len) return p.refuse("ends before an operand", .{});
        const c = p.src[p.i];
        if (c == '(') {
            p.i += 1;
            const e = try p.sum() orelse return null;
            if (!p.eat(")")) return p.refuse("has a `(` with no `)`", .{});
            return e;
        }
        if (std.ascii.isDigit(c) or c == '.') {
            const start = p.i;
            while (p.i < p.src.len and (std.ascii.isDigit(p.src[p.i]) or p.src[p.i] == '.')) p.i += 1;
            // A complete exponent only, as `spiceNumber` reads one.
            if (p.i + 1 < p.src.len and p.src[p.i] == 'e') {
                var j = p.i + 1;
                if (p.src[j] == '+' or p.src[j] == '-') j += 1;
                if (j < p.src.len and std.ascii.isDigit(p.src[j])) {
                    while (j < p.src.len and std.ascii.isDigit(p.src[j])) j += 1;
                    p.i = j;
                }
            }
            // The scale letter and any unit letters after it.
            while (p.i < p.src.len and std.ascii.isAlphabetic(p.src[p.i])) p.i += 1;
            const v = spiceNumber(p.src[start..p.i]) orelse return p.refuse("has `{s}`, which is not a number", .{p.src[start..p.i]});
            return try p.arena.print("{e}", .{v});
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = p.i;
            while (p.i < p.src.len and (std.ascii.isAlphanumeric(p.src[p.i]) or p.src[p.i] == '_')) p.i += 1;
            const name = p.src[start..p.i];
            if (p.eat("(")) {
                for (expr_fns) |f| {
                    if (std.mem.eql(u8, f, name)) break;
                } else return p.refuse("calls `{s}`, which is not one of sqrt, exp, abs, min, max, pow, sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, floor, ceil", .{name});
                var args: std.ArrayList(u8) = .empty;
                while (true) {
                    const a = try p.sum() orelse return null;
                    if (args.items.len != 0) try args.appendSlice(p.arena, ", ");
                    try args.appendSlice(p.arena, a);
                    if (p.eat(",")) continue;
                    if (p.eat(")")) break;
                    return p.refuse("has a `{s}(` with no `)`", .{name});
                }
                return try p.arena.print("{s}({s})", .{ name, args.items });
            }
            for (p.scope) |s| if (std.mem.eql(u8, s, name)) return try spell(p.arena, name);
            return p.refuse("reads `{s}`, which names no parameter in scope (the subcircuit's PARAMS: before it; a `.param` is not read)", .{name});
        }
        return p.refuse("has `{c}`, which is not read", .{c});
    }
};

/// Reports whether `body` holds a card named `name`. An F/H card naming a V
/// card the subcircuit does not declare is skipped like any unreadable card.
fn declares(body: []const Card, name: []const u8) bool {
    for (body) |card| {
        var it: Tokens = .{ .text = card.text };
        if (std.mem.eql(u8, it.next() orelse continue, name)) return true;
    }
    return false;
}

/// The `parameter` declarations a model-derived module carries, and the argument
/// list that forwards them to the primitive it wraps.
const ModelParams = struct {
    /// One `   parameter ...;\n` line per parameter of the primitive.
    decls: []const u8,
    /// `.r(r), .tc1(tc1), ...`: §6.3.3 by name, so Table E.1's order does not
    /// matter here.
    args: []const u8,
};

/// E.2.2.1: "The ports and parameters of the bjt are determined by the bjt
/// primitive itself and not by the model statement for the bjt." That fixes
/// which parameters exist (all of the primitive's) but does not discard the
/// values the card assigns to them.
///
/// So the model-derived module re-declares the primitive's parameter list,
/// copied from the prelude so the `from` ranges and defaults cannot drift,
/// with the default replaced by the card's value wherever the card names one,
/// and forwards all of them by name. Re-declaring is what makes §6.7.1's
/// `r1.r` resolve and §6.3.3's `rmod #(.r(2500))` override.
///
/// A card parameter Table E.1 does not declare (`BF=80`, `RSH=50`) is dropped in
/// silence: E.2 makes "all aspects of SPICE primitives implementation
/// dependent", E.4.2 makes model-card support "implementation specific", and
/// E.1.2's remedy for a name mismatch is a user-written wrapper module, not a
/// diagnostic. A value for a parameter the primitive does declare is a number
/// or an expression over numbers (`expression` with no names: no `.param` is
/// read), and anything else is refused, since dropping it keeps the default.
fn modelParams(
    arena: Allocator,
    prim: []const u8,
    it: *Tokens,
    model: []const u8,
    card: Card,
    refusals: *Refusals,
) Allocator.Error!?ModelParams {
    // The card's `k=v` tail; `tightEquals` has joined HSPICE's `k = v`.
    var keys: std.ArrayList([]const u8) = .empty;
    var vals: std.ArrayList([]const u8) = .empty;
    while (it.next()) |t| {
        const at = std.mem.findScalar(u8, t, '=') orelse continue;
        if (at == 0 or at + 1 == t.len) continue;
        try keys.append(arena, t[0..at]);
        try vals.append(arena, t[at + 1 ..]);
    }

    var decls: std.ArrayList(u8) = .empty;
    var args: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, primitiveBody(prim), '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (!std.mem.startsWith(u8, line, "parameter ")) continue;
        const eq = std.mem.findScalar(u8, line, '=') orelse continue;
        const head = std.mem.trimEnd(u8, line[0..eq], " \t");
        // The declared name is the last token before the `=`, minus any §3.4.4
        // array range: `parameter real wave[0:nwave-1] = ...` declares `wave`.
        var name = head[(std.mem.findLastAny(u8, head, " \t") orelse 0) + 1 ..];
        if (std.mem.findScalar(u8, name, '[')) |b| name = name[0..b];
        if (name.len == 0) continue;

        if (args.items.len != 0) try args.appendSlice(arena, ", ");
        try args.print(arena, ".{s}({s})", .{ name, name });

        const bound = for (keys.items, vals.items) |k, v| {
            if (std.mem.eql(u8, k, name)) break v;
        } else null;
        if (bound) |given| {
            // A value for a parameter the primitive declares is read or
            // refused, never dropped: dropping it would keep the default.
            // An expression may read no name: no `.param` is in scope.
            const v: Value = if (spiceNumber(given)) |n| .{ .num = n } else if (given[0] == '{' or given[0] == '\'')
                try exprValue(arena, given, model, card, refusals, &.{}) orelse return null
            else {
                try refusals.add(card, "`.model {s}`: the value `{s}` of `{s}` is not a number", .{ model, given, name });
                return null;
            };
            // Everything from the `from` range on is kept: §3.4.2's range is part
            // of the declaration, not of the default it replaces.
            const rest = line[eq + 1 ..];
            const tail = if (std.mem.find(u8, rest, " from ")) |f| rest[f..] else ";";
            try decls.print(arena, "   {s} = {f}{s}\n", .{ head, v, tail });
        } else {
            try decls.print(arena, "   {s}\n", .{line});
        }
    }
    return .{ .decls = decls.items, .args = args.items };
}

/// The body of `Preprocessor.spice_primitives`'s module for `prim`, between its
/// header and its `endmodule`. Empty if there is no such row; a test pins that
/// every `model_types` row exists.
fn primitiveBody(prim: []const u8) []const u8 {
    const prelude = Preprocessor.spice_primitives;
    var buf: [64]u8 = undefined;
    const header = std.mem.print(&buf, "\nmodule {s}(", .{prim}) catch return "";
    const at = std.mem.find(u8, prelude, header) orelse return "";
    const rest = prelude[at + header.len ..];
    const end = std.mem.find(u8, rest, "\nendmodule") orelse return "";
    return rest[0..end];
}

/// Parses SPICE's scaled notation, which annex E prints throughout its
/// netlists (`10K`, `1P`, `0.3NS`, `1MA`). E.2.2.3 translates `10K` as
/// `10k`, which §2.6.2 Table 2-1 makes ten thousand.
///
/// The scale letter is followed by unit letters that carry no value (`PF`, `UH`,
/// `NS`, `MA`), so anything after the matched suffix is ignored rather than
/// rejected. Returns null when the token does not start with a number at all,
/// when its exponent does not fit an i32, or when a scaled number's joined
/// text passes 128 bytes; a value past f64's range is an infinity. Never
/// panics.
fn spiceNumber(t: []const u8) ?f64 {
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    const digits = i;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    }
    if (i == digits or (i == digits + 1 and t[digits] == '.')) return null;
    const mant_end = i;
    // An exponent only if it is complete: `1E-18` is a number, the `E` of a bare
    // `1EXP` is the start of unit noise.
    var own: i32 = 0;
    if (i < t.len and t[i] == 'e') {
        var j = i + 1;
        if (j < t.len and (t[j] == '+' or t[j] == '-')) j += 1;
        if (j < t.len and std.ascii.isDigit(t[j])) {
            while (j < t.len and std.ascii.isDigit(t[j])) j += 1;
            own = std.fmt.parseInt(i32, t[i + 1 .. j], 10) catch return null;
            i = j;
        }
    }
    const scale = spiceScale(t[i..]);
    if (scale.exp == 0) return (std.fmt.parseFloat(f64, t[0..i]) catch return null) * scale.mul;
    // Rounds once, as `Lexer.scaleExp`'s callers do: `50n` is
    // parseFloat("50e-9"), while 50 * 1e-9 is a different double.
    var buf: [128]u8 = undefined;
    // i64: an exponent at the end of i32 plus the scale's would overflow.
    const joined = std.mem.print(&buf, "{s}e{d}", .{ t[0..mant_end], @as(i64, own) + scale.exp }) catch return null;
    return std.fmt.parseFloat(f64, joined) catch null;
}

/// Berkeley SPICE's ten scale factors, as a power of ten (`exp`) or, for
/// `mil`, a factor. `meg` and `mil` are tested before `m` because they share
/// its first letter and mean 1e6 and 25.4e-6, not 1e-3 with unit noise. SPICE
/// and §2.6.2 Table 2-1 disagree on `M` (milli in SPICE, mega in Verilog),
/// which is why a card's number is converted to plain decimal here rather
/// than handed on with its suffix. SPICE has no atto, so `1A` is one ampere.
fn spiceScale(rest: []const u8) struct { exp: i32 = 0, mul: f64 = 1.0 } {
    if (std.mem.startsWith(u8, rest, "meg")) return .{ .exp = 6 };
    if (std.mem.startsWith(u8, rest, "mil")) return .{ .mul = 25.4e-6 };
    const scales = [_]struct { suffix: u8, exp: i32 }{
        .{ .suffix = 't', .exp = 12 },
        .{ .suffix = 'g', .exp = 9 },
        .{ .suffix = 'k', .exp = 3 },
        .{ .suffix = 'm', .exp = -3 },
        .{ .suffix = 'u', .exp = -6 },
        .{ .suffix = 'n', .exp = -9 },
        .{ .suffix = 'p', .exp = -12 },
        .{ .suffix = 'f', .exp = -15 },
    };
    if (rest.len != 0) for (scales) |s| if (rest[0] == s.suffix) return .{ .exp = s.exp };
    return .{};
}

/// Reports whether `t` has the §2.7 shape of a simple identifier. `$` is not
/// admitted even though §2.7 allows it in an identifier: `strip` has
/// already treated it as a comment opener, so it cannot reach here.
fn isIdent(t: []const u8) bool {
    if (t.len == 0) return false;
    if (!std.ascii.isAlphabetic(t[0]) and t[0] != '_') return false;
    for (t) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// Reports whether `t` is a SPICE model, subcircuit or node name. SPICE names
/// may lead with digits (`2N2222`) and bare numbers are the default node
/// spelling, so anything printable that is not a parameter (`k=v`, `params:`)
/// qualifies; `spell` decides how it is written.
fn isSpiceName(t: []const u8) bool {
    if (t.len == 0) return false;
    for (t) |c| if (c < 33 or c > 126 or c == '=' or c == ':') return false;
    return true;
}

/// Returns `t` as it must be written to declare it: bare when it is a simple
/// identifier and not a keyword, otherwise as a §2.8.1 escaped identifier
/// (`\wire `, `\2n2222 `), since SPICE has no reserved words and no §2.7
/// shape rule. An escaped identifier is never a keyword (§2.8.2), and neither
/// the `\` nor the terminating white space is part of the name, so lookups
/// still see `wire`. The trailing space is required: `,` and `)` are printable
/// and would otherwise be scanned into the identifier.
fn spell(arena: Allocator, t: []const u8) Allocator.Error![]const u8 {
    // ponytail: share the lexer's keyword lookup; extend the common table for new keywords.
    if (isIdent(t) and token.lookupKeyword(t) == null) return t;
    return arena.print("\\{s} ", .{t});
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "model_types names a real Table E.1 module with the ports it lists" {
    // A row whose primitive or port order does not match the prelude would be
    // wrong without any other test noticing.
    const prelude = Preprocessor.spice_primitives;
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

/// Synthesizes `netlist` with every `arena` allocation on `gpa`, for
/// `checkAllAllocationFailures`.
fn synthesizeAll(gpa: Allocator, netlist: []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    _ = try synthesize(arena_state.allocator(), netlist, "");
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

/// The words `synthesizeOne` builds netlists from: cards, fields and the
/// punctuation the readers split on. No `.include`, `.lib` or `.hdl` call,
/// so a run reads no file.
const fuzz_words = [_][]const u8{ ".subckt", ".ends", ".model", ".param", ".endl", "+", "r1", "c1", "v1", "i1", "e1", "f1", "g1", "h1", "m1", "q1", "j1", "d1", "x1", "k1", "a", "b", "0", "1", "1k", "2n2222", "nch", "nch.1", "npn", "nmos", "bsim4", "params:", "w=1", "l={2*w}", "m=2", "lmin=0", "lmax=1", "{w*2}", "'w+1'", "{", "}", "'", "(", ")", ",", "=", "**", "-", "poly", "value={1}", "*", ";", "$", "\n", "1e999k", "wire" };

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

test "fuzz: synthesize never panics on card-shaped text, and every refusal points into its file" {
    try std.testing.fuzz({}, synthesizeOne, .{});
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

test "fuzz: a SPICE expression is read or refused with a reason, never a panic" {
    try std.testing.fuzz({}, expressionOne, .{});
}
