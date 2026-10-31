//! One `.MODEL` or `.SUBCKT` card (and a `.SUBCKT`'s body cards) in, the
//! Verilog-AMS module text it stands for appended out: R/C/L/V/I and the four
//! controlled sources by their Table E.1 primitive, X cards as instances of a
//! subcircuit, model cards through model.zig; anything else in a body is a
//! `Refusal` (E0928).
//! Cites: LRM annex E.1.2, E.2, E.3, E.3.1, E.3.2, E.3.3, Table E.1; §2.8.1.
//!
//! Contents:
//! - `pub fn emitCard(`
//! - `pub const device_cards = [_]struct`
//! - `pub const controlled = [_]struct`
//! - `pub const source_forms = [_][]const u8`
//! - `pub fn emitBody(`
//! - `pub fn emitSubcktCard(`
//! - `pub fn emitInstance(arena: Allocator, out: *std.ArrayList(u8), module: []const u8, params: []const Override, inst: []const u8, nodes: []const []const u8) Allocator.Error!void`
//! - `pub fn declares(body: []const Card, name: []const u8) bool`
//! - `pub fn primitiveBody(prim: []const u8) []const u8`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const spice_cards = @import("../spice_cards.zig");
const Refusal = spice_cards.Refusal;
const File = spice_cards.File;
const spice_card = @import("card.zig");
const spice_expr = @import("expr.zig");
const spice_model = @import("model.zig");
const spice_names = @import("names.zig");
const Card = spice_card.Card;
const Refusals = spice_card.Refusals;
const model_types = spice_card.model_types;
const ModelCard = spice_card.ModelCard;
const Tokens = spice_card.Tokens;
const subcktBody = spice_card.subcktBody;
const model_cards = spice_model.model_cards;
const Override = spice_model.Override;
const emitModelCard = spice_model.emitModelCard;
const setOverride = spice_model.setOverride;
const paramValue = spice_model.paramValue;
const cardValue = spice_model.cardValue;
const modelParams = spice_model.modelParams;
const expression = spice_expr.expression;
const isIdent = spice_names.isIdent;
const isSpiceName = spice_names.isSpiceName;
const spell = spice_names.spell;

/// Device card letters and the Table E.1 primitive each becomes. E.2.2.3, the
/// only place the LRM says what a device card means, prints `R1 B1 GND 10K` as
/// `resistor #(.r(10k)) R1 (b1, gnd);`, `VA VCC GND 5` as
/// `vsine #(.dc(5)) Vcc (vcc, gnd);` and `IEE E GND 1MA` as
/// `isine #(.dc(1m)) Iee (e, gnd);`: the leading letter picks the primitive and
/// the one positional value lands on `param`. `c` and `l` are the other
/// two-terminal rows whose Behavior column Table E.1 fills in; letters with an
/// empty one (`Q`, `M`, `J`, `D`) have no equation here, and are read only
/// with a model (`model_cards`).
pub const device_cards = [_]struct { letter: u8, prim: []const u8, param: []const u8 }{
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
pub const controlled = [_]struct { letter: u8, lhs: []const u8, rhs: []const u8, by_current: bool }{
    .{ .letter = 'e', .lhs = "V", .rhs = "V", .by_current = false },
    .{ .letter = 'g', .lhs = "I", .rhs = "V", .by_current = false },
    .{ .letter = 'f', .lhs = "I", .rhs = "I", .by_current = true },
    .{ .letter = 'h', .lhs = "V", .rhs = "I", .by_current = true },
};

// The keywords (HSPICE and ngspice) that open a controlled source's
// polynomial, behavioural, table or frequency-domain form.
pub const source_forms = [_][]const u8{ "poly", "value", "table", "laplace", "freq" };

/// Emits one complete card, plus the body `subcktBody` gave it. Returns true
/// if it produced a module.
pub fn emitCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    card: Card,
    body: []const Card,
    models: []const ModelCard,
    seen: *std.ArrayList([]const u8),
    refusals: *Refusals,
    unsupported: *std.ArrayList([]const u8),
) Allocator.Error!bool {
    const out_before = out.items.len;
    defer assert(out.items.len >= out_before);
    assert(card.text.len > 0);
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
pub fn emitBody(
    arena: Allocator,
    out: *std.ArrayList(u8),
    body: []const Card,
    models: []const ModelCard,
    scope: []const []const u8,
    refusals: *Refusals,
) Allocator.Error!void {
    const out_before = out.items.len;
    defer assert(out.items.len >= out_before);
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

/// Emits the instance an X card is: `Xname n1 ... nk subckt [PARAMS:] [k=v
/// ...]`, an instance of the subcircuit (or any module or paramset of the
/// design) `subckt`, connected by position (E.2: subcircuits "are treated as
/// module definitions"), each `k=v` an override of its parameter, a number
/// or a `{expr}` over `scope`, and `M=` E.4.1's `$mfactor`.
pub fn emitSubcktCard(
    arena: Allocator,
    out: *std.ArrayList(u8),
    card: Card,
    inst: []const u8,
    it: *Tokens,
    scope: []const []const u8,
    refusals: *Refusals,
) Allocator.Error!void {
    const out_before = out.items.len;
    defer assert(out.items.len >= out_before);
    assert(card.text.len > 0);
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
pub fn emitInstance(arena: Allocator, out: *std.ArrayList(u8), module: []const u8, params: []const Override, inst: []const u8, nodes: []const []const u8) Allocator.Error!void {
    const out_before = out.items.len;
    defer assert(out.items.len >= out_before);
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

/// Reports whether `body` holds a card named `name`. An F/H card naming a V
/// card the subcircuit does not declare is skipped like any unreadable card.
pub fn declares(body: []const Card, name: []const u8) bool {
    for (body) |card| {
        var it: Tokens = .{ .text = card.text };
        if (std.mem.eql(u8, it.next() orelse continue, name)) return true;
    }
    return false;
}

/// The body of `@import("../pp/annex_e.zig").spice_primitives`'s module for `prim`, between its
/// header and its `endmodule`. Empty if there is no such row; a test pins that
/// every `model_types` row exists.
pub fn primitiveBody(prim: []const u8) []const u8 {
    const prelude = @import("../pp/annex_e.zig").spice_primitives;
    var buf: [64]u8 = undefined;
    const header = std.mem.print(&buf, "\nmodule {s}(", .{prim}) catch return "";
    const at = std.mem.find(u8, prelude, header) orelse return "";
    const rest = prelude[at + header.len ..];
    const end = std.mem.find(u8, rest, "\nendmodule") orelse return "";
    return rest[0..end];
}
