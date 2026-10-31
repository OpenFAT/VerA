//! Declaration lookup: a module or paramset name → the declaration
//! elaboration instantiates (user modules last-wins, then Annex E's prelude,
//! then E.2.1's case-folded netlist modules), §6.4 paramset chains, and the
//! warnings about redefined or shadowed names.
//! Cites: LRM §6.2.2, §6.4, E.1.2, E.2.1, E.3.3; IEEE 1364-2005 §13.2.1.1.
//!
//! Contents:
//! - `pub fn findModule(self: *Flatten, name: Ast.StrId) ?*const Ast.ModuleDecl`
//! - `pub fn unknownModule(self: *Flatten, inst: *const Ast.Instance) design.Error!void`
//! - `pub fn netRefName(self: *Flatten, e: Ast.ExprId) ?Ast.StrId`
//! - `pub fn paramsetChain(...)`
//! - `pub fn chainEnd(self: *Flatten, ps: *const Ast.ParamsetDecl) design.Error!?*const Ast.ModuleDecl`
//! - `pub fn isPrimitive(self: *Flatten, m: *const Ast.ModuleDecl) bool`
//! - `pub fn warnRedefinedModules(self: *Flatten) design.Error!void`
//! - `pub fn warnSpiceShadows(self: *Flatten) design.Error!void`

const std = @import("std");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const fixture = @import("fixture.zig");

/// Returns the module `name` denotes, or null. Lookup order: user modules,
/// the LAST of several same-named ones (IEEE 1364-2005 §13.2.1.1, see
/// `warnRedefinedModules`), then the shipped Annex E prelude, since E.3.3 selects "a module or
/// paramset defined in the Verilog-AMS ... in favor of a SPICE primitive,
/// model, or subcircuit using exactly the same name". Last, E.2.1: "if no
/// exact match is found, the mixed-case name shall match the same name
/// defined within SPICE regardless of the case", over the netlist-derived
/// modules only (already lower-cased).
///
/// An exact paramset match returns null so the caller selects that paramset
/// before considering any SPICE definition. Declaration collisions with a
/// netlist are diagnosed by `warnSpiceShadows`; the optional warning for a
/// Table E.1 primitive alone is not issued. Two SPICE objects of the same
/// name resolve primitive-first; Annex E does not order them.
pub fn findModule(self: *Flatten, name: Ast.StrId) ?*const Ast.ModuleDecl {
    const user = self.ctx.file.userModules();
    var i = user.len;
    while (i > 0) {
        i -= 1;
        if (user[i].name == name) return &user[i];
    }
    for (self.ctx.file.paramsets) |ps| if (ps.name == name) return null;
    for (self.ctx.file.modules[0..self.ctx.file.builtin_modules]) |*m| {
        if (m.name == name) return m;
    }
    const want = self.ctx.file.str(name);
    for (self.ctx.file.netlistModules()) |*m| {
        if (std.ascii.eqlIgnoreCase(self.ctx.file.str(m.name), want)) return m;
    }
    return null;
}

/// Reports an instance whose module name declares nothing: E0904, or E0952
/// when the SPICE netlist has a `.MODEL` of that name whose type is a
/// primitive VerA does not support (E.1.2: "a particular SPICE netlist can
/// reference a primitive which is unsupported"). The name matches the card
/// as E.2.1 matches netlist names, regardless of case.
pub fn unknownModule(self: *Flatten, inst: *const Ast.Instance) design.Error!void {
    const want = self.ctx.file.str(inst.module);
    for (self.ctx.file.netlist_unsupported) |card| {
        const space = std.mem.findScalar(u8, card, ' ').?; // `name type`
        if (!std.ascii.eqlIgnoreCase(card[0..space], want)) continue;
        return self.err(inst.main_tok, .E0952, "`{s}` is a SPICE `.MODEL` of type `{s}`, a primitive Table E.1 and VerA do not provide", .{ want, card[space + 1 ..] });
    }
    try self.err(inst.main_tok, .E0904, "`{s}`", .{want});
}

/// Returns the net a port connection names, or null when it is not a plain
/// identifier. §6.2.2 allows an expression; VerA takes a scalar net
/// reference, which a topology join can express without a new node.
pub fn netRefName(self: *Flatten, e: Ast.ExprId) ?Ast.StrId {
    if (e == .none) return null;
    if (self.ctx.file.exprs.tag(e) != .ident) return null;
    return self.ctx.file.exprs.strOf(e);
}

/// §6.4: "The second identifier is usually the name of a module with which
/// the paramset is associated. The second identifier may instead be the name
/// of a second paramset. A chain of paramsets may be defined, but the last
/// paramset in the chain shall reference a module."
///
/// Appends the chain's links to `out`, near (the one the instance named) to
/// far. Returns false after reporting E0904 when a link names neither a
/// module nor a paramset, or the chain is a cycle.
///
/// The chain is walked by name and the first declaration of that name wins.
/// §6.4.2's selection rules are written for "every instance that references
/// that name", and a chain link is not an instance, so an overloaded inner
/// link has no instance context to select against.
pub fn paramsetChain(
    self: *Flatten,
    near: *const Ast.ParamsetDecl,
    out: *std.ArrayList(*const Ast.ParamsetDecl),
) design.Error!bool {
    // Every link is a distinct paramset (a repeat is the cycle refused below).
    try out.ensureUnusedCapacity(self.ctx.arena, self.ctx.file.paramsets.len + 1);
    var link = near;
    while (true) {
        out.appendAssumeCapacity(link);
        if (findModule(self, link.target) != null) return true;
        const next = for (self.ctx.file.paramsets) |*p| {
            if (p.name == link.target) break p;
        } else {
            try self.err(link.main_tok, .E0904, "`{s}`, the module this paramset specializes", .{
                self.ctx.file.str(link.target),
            });
            return false;
        };
        // A chain that closes on itself never reaches a module, so §6.4's
        // "the last paramset in the chain shall reference a module" is
        // violated by the cycle itself.
        for (out.items) |seen| if (seen == next) {
            try self.err(next.main_tok, .E0904, "`{s}`: the paramset chain is a cycle and never reaches a module", .{
                self.ctx.file.str(next.name),
            });
            return false;
        };
        link = next;
    }
}

/// The module at the end of `ps`'s chain, or `null` after an E0904.
pub fn chainEnd(self: *Flatten, ps: *const Ast.ParamsetDecl) design.Error!?*const Ast.ModuleDecl {
    var chain: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    if (!try paramsetChain(self, ps, &chain)) return null;
    return findModule(self, chain.items[chain.items.len - 1].target).?;
}

/// Returns whether `m` is one of the shipped Table E.1 primitives (Annex E).
/// Identity, not name: a user module called `resistor` shadows the primitive
/// (E.3.3, see `findModule`) and must not get E.3.2's treatment: E.3.2.1's
/// port_discipline "shall only apply to analog primitives ... for other
/// modules as well as the ports of all other modules it shall be ignored".
///
/// Table E.1's own rows only: a module synthesized from a netlist `.MODEL`
/// card is a wrapper around a primitive, not a primitive, and its body is one
/// instantiation with no access function of its own to substitute.
pub fn isPrimitive(self: *Flatten, m: *const Ast.ModuleDecl) bool {
    // Table E.1's rows are one contiguous run of `modules`, so identity is an
    // address range test, not a scan.
    const rows = self.ctx.file.tablePrimitives();
    const at = @intFromPtr(m);
    return at >= @intFromPtr(rows.ptr) and at < @intFromPtr(rows.ptr + rows.len);
}

/// IEEE 1364-2005 §13.2.1.1: "If multiple cells with the same name map to
/// the same library, then the LAST cell encountered shall be written to the
/// library" and "a warning message shall be issued" (W1152). §4.11's ban on
/// reusing a module name predates libraries; the digital binder reads it the
/// same way (`lib/sim/digital/bind.zig` `libraries`), so one design
/// elaborates alike in both engines. `findModule` and `pickTop` take the
/// last definition.
pub fn warnRedefinedModules(self: *Flatten) design.Error!void {
    const user = self.ctx.file.userModules();
    for (user, 0..) |m, i| for (user[i + 1 ..]) |later| {
        if (later.name != m.name) continue;
        try self.ctx.bag.add(.lower, .W1152, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, later.main_tok), "`{s}` is defined again; this later definition is the module", .{self.ctx.file.str(m.name)});
        break;
    };
}

/// E.3.3 requires a warning for a same-named HDL declaration and a SPICE
/// model/subcircuit. Check definitions once, independently of the repeated
/// lookups used for ports, connect planning and parameter selection. Netlist
/// names have E.2.1's canonical lowercase spelling; a differently cased HDL
/// declaration leaves case-insensitive fallback available and does not warn.
pub fn warnSpiceShadows(self: *Flatten) design.Error!void {
    const file = self.ctx.file;
    for (file.netlistModules()) |spice| {
        for (file.userModules()) |m| if (m.name == spice.name)
            try spiceShadowWarning(self, m.name, m.main_tok, "module");
        for (file.paramsets) |ps| if (ps.name == spice.name)
            try spiceShadowWarning(self, ps.name, ps.main_tok, "paramset");
    }
}

// ---- private ----

fn spiceShadowWarning(self: *Flatten, name: Ast.StrId, tok: u32, kind: []const u8) design.Error!void {
    try self.ctx.bag.add(.lower, .W0951, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, tok), "{s} `{s}` is used instead of the SPICE model or subcircuit when this name is instantiated", .{ kind, self.ctx.file.str(name) });
}

test findModule {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parseWithPrelude(&f,
        \\module dup(p); inout p; electrical p; parameter real first = 1.0; endmodule
        \\module dup(p); inout p; electrical p; parameter real second = 1.0; endmodule
        \\paramset dps dup; parameter real x = 1.0; .second = x; endparamset
    );
    var fl = try fixture.flatten(&f);
    const user = f.file.userModules();
    // IEEE 1364-2005 §13.2.1.1: the last definition of a name is the module.
    try std.testing.expectEqual(&user[1], findModule(&fl, fixture.id(&f.file, "dup").?).?);
    // §6.4: a paramset name is selected by its instance, never by this lookup.
    try std.testing.expectEqual(@as(?*const Ast.ModuleDecl, null), findModule(&fl, fixture.id(&f.file, "dps").?));
    // Annex E: a Table E.1 row is found when no user module has the name,
    // and is a primitive; a user module never is.
    const resistor = findModule(&fl, fixture.id(&f.file, "resistor").?).?;
    try std.testing.expect(isPrimitive(&fl, resistor));
    try std.testing.expect(!isPrimitive(&fl, &user[1]));
    try std.testing.expectEqual(@as(?*const Ast.ModuleDecl, null), findModule(&fl, try f.file.intern(f.arena.allocator(), "nowhere")));
}

test "§6.4 a paramset chain that names nothing or closes on itself is E0904, and terminates" {
    for ([_][]const u8{
        "paramset a b; parameter real x = 1.0; endparamset paramset b a; parameter real y = 1.0; endparamset",
        "paramset a nowhere; parameter real x = 1.0; endparamset",
    }) |chain| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(
            \\module top(p); inout p; electrical p; a u(p); endmodule
            \\{s}
        , .{chain}));
        try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
        try std.testing.expect(fixture.hasCode(&f.bag, .E0904));
    }
}

test "IEEE 1364-2005 §13.2.1.1 of two same-named roots the last is the device, with W1152" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; parameter real first = 1.0; endmodule
        \\module top(p); inout p; electrical p; parameter real second = 1.0; endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(&f.file.modules[1], d.top);
    try std.testing.expect(fixture.hasCode(&f.bag, .W1152));
}
