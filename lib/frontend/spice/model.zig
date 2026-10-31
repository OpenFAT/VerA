//! A device card naming a `.MODEL` in, the instance of its Verilog-A module or
//! paramset out, the card's and the model's parameters as overrides; a binned
//! model resolves to the bin that holds the card's L and W, and a Table E.1
//! semiconductor with no behaviour is E0953.
//! Cites: LRM annex E.2, E.2.2.1, E.4.2, Table E.1; §6.3.
//!
//! Contents:
//! - `pub const model_cards = [_]struct`
//! - `pub const Value = union(enum)`: `format`
//! - `pub const Override = struct`
//! - `pub fn emitModelCard(`
//! - `pub const BinBound = enum`
//! - `pub fn pickBin(card: Card, inst: []const u8, model: []const u8, models: []const ModelCard, over: []const Override, refusals: *Refusals) Allocator.Error!??ModelCard`
//! - `pub fn isBinOf(name: []const u8, model: []const u8) bool`
//! - `pub fn namesModel(models: []const ModelCard, name: []const u8) bool`
//! - `pub fn setOverride(arena: Allocator, list: *std.ArrayList(Override), name: []const u8, value: Value) Allocator.Error!void`
//! - `pub fn paramValue(arena: Allocator, t: []const u8, eq: usize, inst: []const u8, card: Card, refusals: *Refusals, scope: []const []const u8) Allocator.Error!?Value`
//! - `pub fn exprValue(arena: Allocator, v: []const u8, inst: []const u8, card: Card, refusals: *Refusals, scope: []const []const u8) Allocator.Error!?Value`
//! - `pub fn cardValue(`
//! - `pub const ModelParams = struct`
//! - `pub fn modelParams(`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const spice_cards = @import("../spice_cards.zig");
const Refusal = spice_cards.Refusal;
const File = spice_cards.File;
const spice_card = @import("card.zig");
const spice_emit = @import("emit.zig");
const spice_expr = @import("expr.zig");
const spice_names = @import("names.zig");
const Card = spice_card.Card;
const Refusals = spice_card.Refusals;
const model_types = spice_card.model_types;
const ModelCard = spice_card.ModelCard;
const tightEquals = spice_card.tightEquals;
const Tokens = spice_card.Tokens;
const emitInstance = spice_emit.emitInstance;
const declares = spice_emit.declares;
const primitiveBody = spice_emit.primitiveBody;
const expression = spice_expr.expression;
const spiceNumber = spice_names.spiceNumber;
const spell = spice_names.spell;

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
pub const model_cards = [_]struct { letter: u8, nodes: u8, prim: []const u8 }{
    .{ .letter = 'm', .nodes = 4, .prim = "mosfet" },
    .{ .letter = 'q', .nodes = 3, .prim = "bjt" },
    .{ .letter = 'j', .nodes = 3, .prim = "jfet" },
    .{ .letter = 'd', .nodes = 2, .prim = "diode" },
};

/// A card value: a number, or a `{expr}` as Verilog-AMS text (`expression`),
/// which elaboration evaluates against the subcircuit's parameters.
pub const Value = union(enum) {
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
pub const Override = struct { name: []const u8, value: Value };

/// A bin card's four bounds, in the order `pickBin` keeps them.
pub const BinBound = enum { lmin, lmax, wmin, wmax };

/// The `parameter` declarations a model-derived module carries, and the argument
/// list that forwards them to the primitive it wraps.
pub const ModelParams = struct {
    /// One `   parameter ...;\n` line per parameter of the primitive.
    decls: []const u8,
    /// `.r(r), .tc1(tc1), ...`: §6.3.3 by name, so Table E.1's order does not
    /// matter here.
    args: []const u8,
};

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
pub fn emitModelCard(
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
    const out_before = out.items.len;
    defer assert(out.items.len >= out_before);
    assert(card.text.len > 0);
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

/// The bin of the binned model `model` that holds the card's L and W
/// (`emitModelCard`), wrapped in an optional: `.{null}` when `model` is not
/// binned at all, null after a refusal.
pub fn pickBin(card: Card, inst: []const u8, model: []const u8, models: []const ModelCard, over: []const Override, refusals: *Refusals) Allocator.Error!??ModelCard {
    assert(card.text.len > 0);
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
pub fn isBinOf(name: []const u8, model: []const u8) bool {
    return name.len > model.len + 1 and std.mem.startsWith(u8, name, model) and name[model.len] == '.';
}

// Whether a `.MODEL` card names `name`, itself or as a binned model.
pub fn namesModel(models: []const ModelCard, name: []const u8) bool {
    for (models) |m| if (std.mem.eql(u8, m.name, name) or isBinOf(m.name, name)) return true;
    return false;
}

/// Sets `name` in `list`, replacing an earlier value: a later assignment of
/// one parameter wins, as an instance's does over its model card's.
pub fn setOverride(arena: Allocator, list: *std.ArrayList(Override), name: []const u8, value: Value) Allocator.Error!void {
    for (list.items) |*o| if (std.mem.eql(u8, o.name, name)) {
        o.value = value;
        return;
    };
    try list.append(arena, .{ .name = name, .value = value });
}

/// The value `t[eq + 1 ..]` of the parameter assignment `t`: a number, or a
/// `{expr}` over `scope`; null after recording why it is neither. Asserts
/// that `eq` is the index of an `=` in `t`.
pub fn paramValue(arena: Allocator, t: []const u8, eq: usize, inst: []const u8, card: Card, refusals: *Refusals, scope: []const []const u8) Allocator.Error!?Value {
    assert(card.text.len > 0);
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
pub fn exprValue(arena: Allocator, v: []const u8, inst: []const u8, card: Card, refusals: *Refusals, scope: []const []const u8) Allocator.Error!?Value {
    assert(card.text.len > 0);
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
pub fn cardValue(
    arena: Allocator,
    t: ?[]const u8,
    it: *Tokens,
    inst: []const u8,
    card: Card,
    refusals: *Refusals,
    scope: []const []const u8,
) Allocator.Error!?Value {
    assert(card.text.len > 0);
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
pub fn modelParams(
    arena: Allocator,
    prim: []const u8,
    it: *Tokens,
    model: []const u8,
    card: Card,
    refusals: *Refusals,
) Allocator.Error!?ModelParams {
    assert(card.text.len > 0);
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
