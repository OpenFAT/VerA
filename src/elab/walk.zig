//! The instance walk: one module's instance list → every reachable instance
//! inlined into the flat module, depth first in source order. Per level it
//! records the level's §6.3.1 defparams and Annex F.2.1 out-of-context
//! declarations, plans §7.8.4 connect modules, then inlines each instance
//! (`instance.inlineInstance`). The levels sit on a heap stack, so any finite
//! hierarchy depth is walked; a cycle is E0905.
//! Cites: LRM §6.2.2, §6.4, §6.6, §7.1, §7.8.4, A.5.4, Annex E.3.2;
//! IEEE 1364-2005 §7.1.5.
//!
//! Contents:
//! - `pub const TreeKid = struct`
//! - `pub fn walkInstances(`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const generate = @import("generate.zig");
const ports = @import("ports.zig");
const instance = @import("instance.zig");
const lookup = @import("lookup.zig");
const primitive = @import("primitive.zig");
const fold = @import("fold.zig");
const defparam = @import("defparam.zig");
const paramset_select = @import("paramset_select.zig");
const ooc = @import("ooc.zig");
const resolve = @import("resolve.zig");
const insert = @import("insert.zig");
const sep = design.sep;
const Unit = Flatten.Unit;

/// `Flatten.tree`: §7.8.4 "a complete hierarchical examination of each
/// signal". The first walk, which inserts no connect module
/// (`Flatten.dry`), records every instance it elaborates under its parent's
/// instance path, and the walk that inserts reads it (`segment.up`), so a
/// level is planned from the subtree below it as elaborated: generate blocks
/// evaluated, instance arrays expanded, paramsets selected.
pub const Tree = struct {
    kids: std.StringHashMapUnmanaged(std.ArrayList(TreeKid)) = .empty,
    /// The first walk's `Flatten.oocs.decls`: every out-of-context
    /// declaration, those declared below the level being planned included.
    ooc: std.StringHashMapUnmanaged(ooc.OocDecl) = .empty,
};

/// One instance the first walk elaborated (`Flatten.tree`): the instance as
/// its parent wrote it (an array element or a generate copy as the walk
/// named it, a row of that level's arena list), the module it elaborated to,
/// and its own instance path.
pub const TreeKid = struct {
    inst: *const Ast.Instance,
    module: *const Ast.ModuleDecl,
    path: []const u8,

    comptime {
        // One row per instance of the dry walk: two pointers and a slice,
        // not a 72 B copy of the instance.
        assert(@sizeOf(TreeKid) <= 32);
    }
};

/// One unit `walkInstances` is walking: its instance list as planned, and
/// where the walk is in it.
const Level = struct {
    /// The unit's module with its instance arrays scalarized.
    module: *const Ast.ModuleDecl,
    /// The unit's hierarchical prefix ("" at the top).
    path: []const u8,
    /// The source instances, then the §6.6 generate instances (`gates`
    /// holds their schemes from index `module.instances.len` on), then the
    /// §7.8.4 connect modules `insert.plan` appended.
    all: []const Ast.Instance,
    /// The source and generate instances as written, before `plan`
    /// re-pointed any port: the implicit nets are read from these.
    src: []const Ast.Instance,
    gates: []const Ast.ExprId,
    /// §3.6.5's test: the nets `module` declares, as a port or a net
    /// declaration. A parameter, variable or genvar is not one, so an actual
    /// naming one is E0906, not an implicit net.
    declared: std.AutoHashMapUnmanaged(Ast.StrId, void),
    /// The instance being walked, and for it its generate scheme and the
    /// §6.2.2 array element next to inline, `k` in `lo..hi`.
    idx: usize = 0,
    started: bool = false,
    gate: Ast.ExprId = .none,
    is_array: bool = false,
    /// The end may be maxInt(i64), so the one-past-end value needs a
    /// wider carrier.
    k: i128 = 0,
    hi: i64 = 0,
    /// The unit in force above this one (`inlineInstance`'s return), put
    /// back when this level is done; null at the top.
    parent: ?*const Unit = null,

    comptime {
        // One row per level of the walk's heap stack, so as deep as the
        // tree; `k`'s i128 sets the 16 B alignment. A budget: the hash
        // map's safety lock exists in Debug and ReleaseSafe only.
        assert(@sizeOf(Level) <= 160);
    }
};

/// The next instance `walkInstances` inlines from `lv`.
const Child = struct {
    inst: *const Ast.Instance,
    child: *const Ast.ModuleDecl,
    ps: ?*const Ast.ParamsetDecl,
    path: []const u8,
    gate: Ast.ExprId,
};

/// §6.2.2 the instance tree below `top`, in source order, depth first: each
/// instance is inlined (`inlineInstance`), then the instances of its module
/// are walked before its next sibling. One `Level` per unit being walked
/// sits on a heap stack, so the walk is as deep as the tree with no native
/// stack per level: §6.2.2 bounds nothing about the depth. Asserts that
/// `stack` holds `top` (is not empty), and leaves it as it found it.
pub fn walkInstances(
    self: *Flatten,
    top: *const Ast.ModuleDecl,
    /// The module names being elaborated, top first, `top` already on it.
    /// Each is on it once (E0905), so it is no deeper than the source has
    /// modules, and any finite tree is walked.
    stack: *std.ArrayList(Ast.StrId),
) design.Error!void {
    const a = self.ctx.arena;
    assert(stack.items.len != 0); // `top` is on it
    const base = stack.items.len;
    var levels: std.ArrayList(Level) = .empty;
    if (try enterLevel(self, top, "", stack.items)) |l| try levels.append(a, l);
    while (levels.items.len != 0) {
        // Every level below the top pushed its module; the top's was there.
        assert(stack.items.len + 1 == base + levels.items.len);
        if (try nextChild(self, &levels.items[levels.items.len - 1], stack.items)) |c| {
            const parent = try instance.inlineInstance(self, c.inst, c.child, c.ps, c.path, c.gate);
            try stack.append(a, c.child.name);
            if (try enterLevel(self, c.child, c.path, stack.items)) |l| {
                var below = l;
                below.parent = parent;
                try levels.append(a, below);
            } else {
                _ = stack.pop();
                self.unit = parent.*;
            }
            continue;
        }
        const done = levels.pop().?;
        if (done.parent) |p| {
            _ = stack.pop();
            self.unit = p.*;
        }
    }
    assert(stack.items.len == base);
}

// ---- private ----

/// What a unit's walk does before its first instance: recorded defparams and
/// out-of-context declarations, the planned connect modules, the
/// primitives' disciplines. Null when the unit's instance list is refused
/// (E0905, an unknown module), so nothing below it is walked.
fn enterLevel(self: *Flatten, source_module: *const Ast.ModuleDecl, path: []const u8, stack: []const Ast.StrId) design.Error!?Level {
    // §6.3/§6.4.2 an indexed defparam can select a different paramset for
    // each array element. Expand before §6.9.3 connect planning, so both
    // passes use the same external instance paths and selected modules.
    // Preserve early named errors before allocating an array's rows.
    for (source_module.instances) |inst| {
        if (inst.range == null) continue;
        if (isUdp(self.ctx.file, inst.module)) continue;
        if (lookup.findModule(self, inst.module)) |child| {
            if (try cycle(self, stack, child.name)) |names| {
                try self.err(inst.main_tok, .E0905, "{s} closes at `{s}{s}`", .{ names, path, self.ctx.file.str(inst.name) });
                return null;
            }
        } else {
            const known = for (self.ctx.file.paramsets) |ps| {
                if (ps.name == inst.module) break true;
            } else false;
            if (!known) {
                try lookup.unknownModule(self, &inst);
                return null;
            }
        }
    }
    const module = try self.ctx.arena.create(Ast.ModuleDecl);
    module.* = source_module.*;
    module.instances = try expandInstanceArrays(self, source_module.instances);
    // Both before the children: each names something below this module.
    try defparam.collectDefparams(self, module, path); // §6.3.1
    try ooc.collectOoc(self, module, path); // Annex F.2.1 step 3

    // The source instances, then the §6.6 generate instances, whose schemes
    // `gates` holds in parallel from index `module.instances.len` on.
    var src: std.ArrayList(Ast.Instance) = .empty;
    try src.appendSlice(self.ctx.arena, module.instances);
    var gates: std.ArrayList(Ast.ExprId) = .empty;
    for (module.analog) |blk| try generate.genInstances(self, blk.body, .none, "", &.{}, &src, &gates);
    assert(src.items.len == module.instances.len + gates.items.len);

    // §7.8.4 connect modules are inserted "in the context of the ports
    // upper connection", which is this module: `plan` re-points each mixed
    // port at a digital segment and appends the bridges, which then inline
    // like any child. Indices past `src.items.len` are those.
    // The first walk (`Flatten.dry`) inserts nothing: it records the tree.
    const all = if (self.dry) src.items else try insert.plan(self, module, path, src.items, gates.items);

    // E.3.2's first source, "A port_discipline attribute on the analog
    // primitive", bound for every primitive of this level before any is
    // inlined, so E.3.2.2's "the same discipline" scan for an unattributed
    // primitive finds the segment resolved in any source order.
    // ponytail: a primitive reached through a paramset keeps only the
    // default; `selectParamset` diagnoses, so it is not run twice.
    for (module.instances) |*inst| {
        const child = lookup.findModule(self, inst.module) orelse continue;
        if (!lookup.isPrimitive(self, child)) continue;
        for (child.ports, 0..) |p, i| {
            const conn = ports.connectionFor(inst, p, i) orelse continue;
            const n = lookup.netRefName(self, conn.expr) orelse continue;
            var q = p;
            q.discipline = primitive.portDisciplineAttr(self, module, inst, conn) orelse continue;
            const child_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, self.ctx.file.str(inst.name), sep });
            try resolve.resolveDiscipline(self, child_path, q, self.unit.rename.get(n) orelse n, conn.main_tok);
        }
    }
    // Read only by `startInstance`, so a unit with no children skips it.
    var declared: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty;
    if (src.items.len != 0) {
        try declared.ensureTotalCapacity(self.ctx.arena, @intCast(module.ports.len + module.nets.len));
        for (module.ports) |p| declared.putAssumeCapacity(p.name, {});
        for (module.nets) |n| declared.putAssumeCapacity(n.name, {});
    }
    return .{ .module = module, .path = path, .all = all, .src = src.items, .gates = gates.items, .declared = declared };
}

/// Advances `lv` to its next instance to inline, doing for each instance on
/// the way what needs no recursion: implicit nets, UDPs, array bounds,
/// paramset selection, the cycle check and the first walk's tree. Null when
/// the level is done, or ends at a cycle (E0905).
fn nextChild(self: *Flatten, lv: *Level, stack: []const Ast.StrId) design.Error!?Child {
    const module = lv.module;
    const path = lv.path;
    while (true) {
        if (!lv.started) {
            if (lv.idx == lv.all.len) return null;
            if (!try startInstance(self, lv)) {
                lv.idx += 1;
                continue;
            }
            lv.started = true;
        }
        if (lv.k > lv.hi) {
            lv.started = false;
            lv.idx += 1;
            continue;
        }
        const k = lv.k;
        lv.k += 1;
        const inst = &lv.all[lv.idx];
        const leaf = if (lv.is_array)
            try self.ctx.arena.print("{s}[{d}]", .{ self.ctx.file.str(inst.name), k })
        else
            self.ctx.file.str(inst.name);
        const child_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, leaf, sep });
        var ps: ?*const Ast.ParamsetDecl = null;
        const child = lookup.findModule(self, inst.module) orelse blk: {
            ps = try paramset_select.selectParamset(self, inst, child_path) orelse continue;
            break :blk try lookup.chainEnd(self, ps.?) orelse continue;
        };
        if (lookup.isPrimitive(self, child)) try primitive.checkPortDiscipline(self, module, inst);
        // §7.1 manually and automatically inserted connect modules
        // follow this same instance walk.
        if (try cycle(self, stack, child.name)) |names| {
            try self.err(inst.main_tok, .E0905, "{s} closes at `{s}`", .{ names, child_path[0 .. child_path.len - 1] });
            lv.idx = lv.all.len;
            lv.started = false;
            return null;
        }
        // Both arms of an if-generate are inlined under their gates; the
        // tree holds only an instance its scheme brings into existence
        // (one whose gate does not fold is left out, as unknown).
        if (self.dry and fold.gateHolds(self, lv.gate)) {
            const kids = try self.tree.kids.getOrPut(self.ctx.arena, path);
            if (!kids.found_existing) kids.value_ptr.* = .empty;
            try kids.value_ptr.append(self.ctx.arena, .{ .inst = inst, .module = child, .path = child_path });
        }
        return .{ .inst = inst, .child = child, .ps = ps, .path = child_path, .gate = lv.gate };
    }
}

/// The per-instance work before its first element: implicit nets, a UDP
/// (judged here and never inlined) and the §6.2.2 array range. False when
/// the instance inlines nothing.
fn startInstance(self: *Flatten, lv: *Level) design.Error!bool {
    const module = lv.module;
    const idx = lv.idx;
    assert(idx < lv.all.len);
    // `enterLevel`'s: one scheme per generate instance, after the source ones.
    assert(lv.src.len == module.instances.len + lv.gates.len);
    const inst = &lv.all[idx];
    const auto = idx >= lv.src.len;
    lv.gate = if (idx < module.instances.len or auto) .none else lv.gates[idx - module.instances.len];
    // §3.6.5, the structural half: an actual that names nothing `module`
    // declared is an implicit net (see `design.Design.implicit_nets`).
    // Collected here, not in `inlineInstance`, because only this loop
    // still has `module` in hand; one level down the names are flat.
    // Reads the source's own connections, not `plan`'s segments.
    if (idx < module.instances.len) try ports.checkVariableActuals(self, module, &lv.declared, &module.instances[idx]);
    if (!auto) for (lv.src[idx].ports) |c| {
        const n = lookup.netRefName(self, c.expr) orelse continue;
        if (lv.declared.contains(n)) continue;
        try self.out.implicit_nets.append(self.ctx.arena, .{
            .name = self.ctx.file.str(n),
            .main_tok = c.main_tok,
        });
    };

    // A.4.1 `module_instantiation ::= module_or_paramset_identifier ...`:
    // §6.4 says a paramset "can be instantiated exactly like a module".
    // A module wins; §6.4.2 selection runs only when nothing else matches.
    //
    // A.5.4: a named udp_instance parses as a module instance
    // (`parseUdpInst`), so its `#( … )` arrives as a
    // parameter_value_assignment. It is A.2.2.3's `delay2` (at most two
    // positional values), and the instance reaches no analog device (W0252).
    if (isUdp(self.ctx.file, inst.module)) {
        for (inst.params) |p| if (p.scaled_literal_tok) |tok|
            try self.err(tok, .E0247, "a scaled literal in `{s}`'s UDP delay", .{self.ctx.file.str(inst.module)});
        if (inst.params.len > 2 or (inst.params.len != 0 and inst.params[0].name != .none))
            try self.err(inst.main_tok, .E0239, "`{s} #(…) {s}`: {d} value(s)", .{ self.ctx.file.str(inst.module), self.ctx.file.str(inst.name), inst.params.len })
        else
            try self.ctx.bag.add(.lower, .W0252, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, inst.main_tok), "`{s}` primitive", .{self.ctx.file.str(inst.module)});
        return false;
    }
    // §6.2.2 `name_of_module_instance ::= module_instance_identifier
    // [ range ]`: one instance per element, each addressable as §6.7's
    // `adder1[5].sum`.
    lv.k = 0;
    lv.hi = 0;
    lv.is_array = false;
    if (inst.range) |r| {
        const msb = fold.constInt(self, r.msb) orelse {
            try self.err(inst.main_tok, .E0909, "`{s}`", .{self.ctx.file.str(inst.name)});
            return false;
        };
        const lsb = fold.constInt(self, r.lsb) orelse {
            try self.err(inst.main_tok, .E0909, "`{s}`", .{self.ctx.file.str(inst.name)});
            return false;
        };
        lv.k = @min(msb, lsb);
        lv.hi = @max(msb, lsb);
        lv.is_array = true;
    }
    return true;
}

/// Returns whether `name` is an IEEE 1364 UDP: a digital primitive the
/// analog flatten never inlines (A.5.4).
fn isUdp(file: *const Ast.SourceFile, name: Ast.StrId) bool {
    for (file.udps) |u| if (u.name == name) return true;
    return false;
}

/// §6.2.2/§6.6.2 the cycle instantiating `child` under `stack` would close,
/// named module by module (`` `a` → `b` → `a` ``), or null when `child` is
/// not being elaborated. A module that instantiates itself has no finite
/// instance tree here: the walk does not fold a generate scheme that could
/// end the recursion, so any cycle is refused (E0905), and any finite depth
/// is walked.
fn cycle(self: *Flatten, stack: []const Ast.StrId, child: Ast.StrId) design.Error!?[]const u8 {
    const at = std.mem.findScalar(Ast.StrId, stack, child) orelse return null;
    var names: std.ArrayList(u8) = .empty;
    for (stack[at..]) |m| try names.print(self.ctx.arena, "`{s}` → ", .{self.ctx.file.str(m)});
    try names.print(self.ctx.arena, "`{s}`", .{self.ctx.file.str(child)});
    return names.items;
}

/// Scalarize §6.2.2 module arrays before per-instance decisions. The source
/// AST remains unchanged for the mixed runner's independent digital walk.
fn expandInstanceArrays(self: *Flatten, insts: []const Ast.Instance) design.Error![]const Ast.Instance {
    for (insts) |inst| {
        if (inst.range != null) break;
    } else return insts;
    var out: std.ArrayList(Ast.Instance) = .empty;
    for (insts) |inst| {
        // UDP instances belong to the digital walk. The analog path
        // reports W0252 once at the source site, as for a scalar UDP.
        if (isUdp(self.ctx.file, inst.module)) {
            try out.append(self.ctx.arena, inst);
            continue;
        }
        const range = inst.range orelse {
            try out.append(self.ctx.arena, inst);
            continue;
        };
        const msb = fold.constInt(self, range.msb);
        const lsb = fold.constInt(self, range.lsb);
        if (msb == null or lsb == null) {
            try self.err(inst.main_tok, .E0909, "`{s}`", .{self.ctx.file.str(inst.name)});
            continue;
        }
        // A singleton at maxInt(i64) is legal and must not overflow
        // when advancing past its final element. No range subtraction.
        var k: i128 = @min(msb.?, lsb.?);
        while (k <= @max(msb.?, lsb.?)) : (k += 1) {
            var scalar = inst;
            scalar.name = try self.ctx.file.intern(self.ctx.arena, try self.ctx.arena.print("{s}[{d}]", .{ self.ctx.file.str(inst.name), k }));
            scalar.range = null;
            try out.append(self.ctx.arena, scalar);
        }
    }
    return out.items;
}

const fixture = @import("fixture.zig");

test "§6.2.2 an instance tree of any finite depth elaborates; a cycle is E0905, named" {
    const gpa = std.testing.allocator;
    // e0 -> e1 -> ... -> e<depth>: the old 64-level bound, one past it, and
    // far past it, every level on the walk's heap stack.
    for ([_]usize{ 64, 65, 5_000 }) |depth| {
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(gpa);
        for (0..depth) |i| try text.print(gpa, "module e{d}(p); inout p; electrical p; e{d} u(p); endmodule\n", .{ i, i + 1 });
        try text.print(gpa, "module e{d}(p); inout p; electrical p; analog I(p) <+ V(p); endmodule\n", .{depth});
        var f: fixture.Fixture = .{ .arena = .init(gpa) };
        defer f.deinit();
        try fixture.parse(&f, text.items);
        const d = try elaborate.elaborate(f.ctx());
        try std.testing.expectEqual(@as(usize, 0), f.bag.count());
        try std.testing.expectEqual(@as(usize, 1), d.top.analog.len); // the deepest module's block
        try std.testing.expectEqual(depth + 1, d.units.len);
    }
    // A cycle through an instance array: refused, named module by module.
    var f: fixture.Fixture = .{ .arena = .init(gpa) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; ca u(p); endmodule
        \\module ca(p); inout p; electrical p; cb v(p); endmodule
        \\module cb(p); inout p; electrical p; cc w[1:0](p); endmodule
        \\module cc(p); inout p; electrical p; ca x(p); endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
    try std.testing.expectEqual(@import("diag").Code.E0905, f.bag.at(0).code);
    try std.testing.expectEqualStrings("`ca` → `cb` → `cc` → `ca` closes at `u.v.w[0].x`", f.bag.at(0).message);
}

test "§6.2.2 an instance array is one instance per element, lowest index first; a range that does not fold is E0909" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u[1:0](p); endmodule
        \\module kid(a); inout a; electrical a; analog I(a) <+ V(a); endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 3), d.units.len);
    try std.testing.expectEqualStrings("u[0].", d.units[1].path);
    try std.testing.expectEqualStrings("u[1].", d.units[2].path);

    var g: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try fixture.parse(&g,
        \\module top(p); inout p; electrical p; real r; kid u[r:0](p); endmodule
        \\module kid(a); inout a; electrical a; analog I(a) <+ V(a); endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(g.ctx()));
    try std.testing.expect(fixture.hasCode(&g.bag, .E0909));
}

test "§6.2.2 an instance array at the top of i64 is one element; a reversed range walks lowest first" {
    const src =
        \\module top(p); inout p; electrical p; kid u{s}(p); endmodule
        \\module kid(a); inout a; electrical a; analog I(a) <+ V(a); endmodule
    ;
    const Case = struct { range: []const u8, paths: []const []const u8 };
    for ([_]Case{
        // Advancing past the last element must not overflow (`k: i128`).
        .{ .range = "[9223372036854775807:9223372036854775807]", .paths = &.{"u[9223372036854775807]."} },
        .{ .range = "[0:1]", .paths = &.{ "u[0].", "u[1]." } },
        .{ .range = "[-1:-1]", .paths = &.{"u[-1]."} },
    }) |c| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(src, .{c.range}));
        const d = try elaborate.elaborate(f.ctx());
        try std.testing.expectEqual(c.paths.len + 1, d.units.len);
        for (c.paths, d.units[1..]) |want, u| try std.testing.expectEqualStrings(want, u.path);
    }
}

test "A.5.4 a UDP instance is never inlined: W0252, and E0239 past A.2.2.3's two delays" {
    const src =
        \\primitive inv(o, i); output o; input i; table 0 : 1; 1 : 0; endtable endprimitive
        \\module top(p); inout p; electrical p; wire a, b; inv {s} g(a, b); analog I(p) <+ V(p); endmodule
    ;
    const Case = struct { delay: []const u8, code: @import("diag").Code };
    for ([_]Case{
        .{ .delay = "", .code = .W0252 },
        .{ .delay = "#(1, 2)", .code = .W0252 },
        .{ .delay = "#(1, 2, 3)", .code = .E0239 },
    }) |c| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(src, .{c.delay}));
        if (c.code == .E0239)
            try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()))
        else
            try std.testing.expectEqual(@as(usize, 1), (try elaborate.elaborate(f.ctx())).units.len);
        try std.testing.expect(fixture.hasCode(&f.bag, c.code));
    }
}
