//! Elaboration's spine: a parsed `Ast.SourceFile` (an overlay the stage may
//! append to) → one `Design` whose top module holds a renamed copy of every
//! reachable instance, so nothing after this stage sees hierarchy. Picks the
//! root (§6.2.2), runs the compilation-wide checks, then the walks
//! `Flatten.run` performs: an IEEE 1364-2005 §12.8.1 seed walk when a
//! defparam may bind early, a §7.8.4 dry walk when connect modules may be
//! inserted, and the real walk.
//! Cites: LRM §3.4.7, §6.2.1, §6.2.2, §6.3.1, §6.4, §6.6, §7.6, §7.7, §7.8.4,
//! Annex E; IEEE 1364-2005 §12.8.1, §13.2.1.1.
//!
//! Contents:
//! - `pub fn elaborate(ctx: design.Ctx) design.Error!design.Design`

const std = @import("std");
const Ast = @import("frontend").Ast;
const diag = @import("diag");
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const generate = @import("generate.zig");
const ports = @import("ports.zig");
const lookup = @import("lookup.zig");
const defparam = @import("defparam.zig");
const paramset_select = @import("paramset_select.zig");
const decl_check = @import("decl_check.zig");
const alias = @import("alias.zig");

/// Elaborates `ctx.file` into the design lowering walks. Every pointer in the
/// result points into `ctx.arena`. A top with no instances, defparams or
/// generate instances is returned by pointer, exactly as parsed. §6.5.7.1's
/// distribution of a vector net across an instance array is not supported.
pub fn elaborate(ctx: design.Ctx) design.Error!design.Design {
    if (ctx.file.userModules().len == 0) return error.NoModule;
    try alias.checkSource(ctx); // §3.4.7, before any folding or cloning

    // §6.6 each module's generate-block instances, walked once: `pickTop`,
    // the tree-of-one test and every inlined instance read them.
    const gen_instances = try ctx.arena.alloc([]const Ast.Instance, ctx.file.modules.len);
    for (ctx.file.modules, gen_instances) |*m, *out| {
        var list: std.ArrayList(Ast.Instance) = .empty;
        for (m.analog) |blk| try generate.genInstanceList(ctx.file, blk.body, ctx.arena, &list);
        out.* = list.items;
    }

    const top = try pickTop(ctx, gen_instances);

    var f: Flatten = .{ .ctx = ctx, .gen_instances = gen_instances };
    try lookup.warnSpiceShadows(&f);
    try lookup.warnRedefinedModules(&f); // IEEE 1364-2005 §13.2.1.1 W1152
    // §7.7's names are judged whether or not the design has a hierarchy to
    // resolve: a `connectrules` block is a description of the COMPILATION
    // (A.1.2), not of the top module, so the tree-of-one shortcut below must
    // not skip a misspelled connect module or discipline in one.
    try decl_check.checkConnectRules(&f);
    try decl_check.checkNetDisciplines(&f); // A.2.1.3, every module: see there
    try ports.checkPortDirections(&f); // §6.5.2.2, every module
    try paramset_select.checkRanges(&f); // §3.4.2, every paramset, selected or not
    // §7.4.2 "the real-value nets shall obey the rules imposed by 3.7": the
    // same structural check the digital runner makes (E0918/E0919).
    try @import("frontend").wreal.check(ctx.file, ctx.tok_starts, ctx.bag);
    if (ctx.bag.failed()) f.had_error = true;

    // A tree of one goes to lowering by pointer, untouched. A `defparam` with
    // no instance still takes the flatten: §6.3.1's path then names nothing,
    // and the flatten is where that E0907 is reported.
    // A primitive with connect rules takes it too: §7.8.4 may bridge its
    // terminals (§7.8.5.1).
    if (top.instances.len == 0 and top.defparams.len == 0 and f.genInstancesOf(top).len == 0 and
        (top.gates.len + top.pulls.len + top.switches.len == 0 or ctx.file.connectrules.len == 0))
    {
        if (f.had_error) return error.DiagnosticsReported;
        try alias.checkFlat(ctx, top, top.aliasparams);
        return .{ .top = top };
    }

    // IEEE 1364-2005 §12.8.1: every defparam is in force before the
    // parameters it names take their values. A design whose defparams may
    // name a parameter bound before the walk reaches them is walked twice,
    // the first walk (diagnostics discarded) only collecting them.
    const bind_early = defparam.mayBindEarly(ctx.file);
    var scratch: diag.Bag = .init(ctx.arena);
    scratch.levels = ctx.bag.levels;
    var first_ctx = ctx;
    first_ctx.bag = &scratch;
    var first: Flatten = .{ .ctx = first_ctx, .gen_instances = gen_instances };
    if (bind_early) {
        _ = first.run(top) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NoModule, error.DiagnosticsReported => {},
        };
        try defparam.seedDefparams(&f, &first);
    }
    // §7.8.4: insertion "depends on a complete hierarchical examination of
    // each signal", and a level is planned before its children are walked.
    // So a design that can insert connect modules is walked twice: once
    // inserting none, recording what it elaborated (`Flatten.tree`), then
    // for real. The first walk's diagnostics are the second's, so they go to
    // a scratch bag. It sees the same collected defparams as the real walk.
    if (ctx.file.connectrules.len != 0) {
        var dry_scratch: diag.Bag = .init(ctx.arena);
        var dry_ctx = ctx;
        dry_ctx.bag = &dry_scratch;
        var dry: Flatten = .{ .ctx = dry_ctx, .gen_instances = gen_instances, .dry = true };
        if (bind_early) try defparam.seedDefparams(&dry, &first);
        if (dry.run(top)) |_| {} else |e| if (e == error.OutOfMemory) return e;
        f.tree.kids = dry.tree.kids;
        f.tree.ooc = dry.oocs.decls;
    }
    return f.run(top);
}

// ---- private ----

/// Which module is the device (§6.2.2): the first user module, in source
/// order, that nothing instantiates. A child may be declared before its
/// parent. Several roots are not diagnosed: A.1.2 lets a source_text hold
/// unrelated descriptions and §6.2.1 gives no rule for choosing between them.
///
/// `gen_instances` is `Flatten.gen_instances`. Every instantiated name is
/// collected once, so the choice costs one pass over the instances rather
/// than one per candidate.
fn pickTop(ctx: design.Ctx, gen_instances: []const []const Ast.Instance) design.Error!*const Ast.ModuleDecl {
    const file = ctx.file;
    // Annex E: a candidate is a module the USER wrote. The shipped Table E.1
    // primitives instantiate nothing, so all nineteen are roots of the instance
    // graph and one of them would win every time. They still count as
    // instantiators, so every module's instances are collected.
    var instantiated: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty;
    for (file.modules, gen_instances) |*other, gen| for ([_][]const Ast.Instance{ gen, other.instances }) |list| for (list) |inst| {
        try instantiated.put(ctx.arena, inst.module, {});
        // §6.4 an instance that names a paramset is an incoming edge on
        // the module the paramset specializes.
        for (file.paramsets) |ps| {
            if (ps.name != inst.module) continue;
            // §6.4 "A chain of paramsets may be defined, but the last
            // paramset in the chain shall reference a module": follow
            // the second identifier while it keeps naming a paramset.
            // Bounded by the paramset count, so a cycle terminates.
            var target = ps.target;
            for (0..file.paramsets.len) |_| {
                target = for (file.paramsets) |p2| {
                    if (p2.name == target) break p2.target;
                } else break;
            }
            try instantiated.put(ctx.arena, target, {});
        }
    };
    for (file.userModules()) |*m| {
        // §7.6: a connect module is placed by the insertion phase, not a
        // design root. Insertion runs later, during the walk, so here every
        // connect module looks like a root. Skipped in both loops, so a file
        // of only connect modules is `NoModule`.
        if (m.is_connect) continue;
        // IEEE 1364-2005 §13.2.1.1 the last same-named module is the cell.
        if (!instantiated.contains(m.name)) return lastNamed(file, m);
    }
    // Every module is instantiated by some module, so the graph is all cycles.
    // Start at the first and let E0905 name the one that closes.
    for (ctx.file.userModules()) |*m| if (!m.is_connect) return lastNamed(file, m);
    return error.NoModule;
}

fn lastNamed(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl) *const Ast.ModuleDecl {
    var last = m;
    for (file.userModules()) |*o| if (o.name == m.name) {
        last = o;
    };
    return last;
}

const fixture = @import("fixture.zig");
const Fixture = fixture.Fixture;
const parse = fixture.parse;
const parseWithPrelude = fixture.parseWithPrelude;

test "a tree of one elaborates to that one, by pointer" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    var empty: Ast.SourceFile = .empty;
    var c = f.ctx();
    c.file = &empty;
    try std.testing.expectError(error.NoModule, elaborate(c));

    try parse(&f, "module a(p); inout p; electrical p; analog I(p) <+ 0.0; endmodule");
    const dsg = try elaborate(f.ctx());
    // The identity of the pointer IS the regression claim: nothing was rebuilt.
    try std.testing.expectEqual(&f.file.modules[0], dsg.top);
}

test "the top is the module nothing instantiates, whatever the source order" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    // The CHILD is declared first, which is the shape
    // tests/conformance/tests/verilog-a/ch03_data_types/implicit_nets.va has.
    try parse(&f,
        \\module kid(a, b); inout a, b; electrical a, b;
        \\  parameter real g = 3.0;
        \\  analog I(a, b) <+ g * V(a, b);
        \\endmodule
        \\module top(p, n); inout p, n; electrical p, n;
        \\  kid #(.g(4.0)) u(p, n);
        \\endmodule
    );
    const dsg = try elaborate(f.ctx());
    try std.testing.expectEqualStrings("top", f.file.str(dsg.top.name));

    // §6.3: the child's parameter is flattened in under its §6.7 path, as a
    // localparam, carrying the override.
    try std.testing.expectEqual(@as(usize, 1), dsg.top.params.len);
    try std.testing.expectEqualStrings("u.g", f.file.str(dsg.top.params[0].name));
    try std.testing.expect(dsg.top.params[0].is_local);
    try std.testing.expect(dsg.top.params[0].is_override);
    // §6.5 the terminals are still the top's, and the child added no node: both
    // its ports were connected to them.
    try std.testing.expectEqual(@as(usize, 2), dsg.top.ports.len);
    try std.testing.expectEqual(@as(usize, 0), dsg.top.nets.len);
    try std.testing.expectEqual(@as(usize, 1), dsg.top.analog.len);
}

test "annex E: a shipped primitive is instantiable, is never the top, and yields to a user module of the same name" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parseWithPrelude(&f,
        \\module top(p, n); inout p, n; electrical p, n;
        \\  resistor #(.r(2.0)) r1(p, n);
        \\endmodule
    );
    try std.testing.expect(f.file.builtin_modules > 0);
    const dsg = try elaborate(f.ctx());
    // §6.2.2: nineteen uninstantiated primitives are nineteen roots, and none of
    // them is the device.
    try std.testing.expectEqualStrings("top", f.file.str(dsg.top.name));
    // Table E.1's `resistor` row: parameters r, tc1, tc2, flattened under §6.7.
    try std.testing.expectEqual(@as(usize, 3), dsg.top.params.len);
    try std.testing.expectEqualStrings("r1.r", f.file.str(dsg.top.params[0].name));
    try std.testing.expect(dsg.top.params[0].is_override);

    // E.3.3: "a module ... defined in the Verilog-AMS will always be selected in
    // favor of a SPICE primitive ... using exactly the same name". The user's
    // `resistor` has ONE parameter, so the count is the claim.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parseWithPrelude(&g,
        \\module resistor(p, n); inout p, n; electrical p, n;
        \\  parameter real mine = 1.0;
        \\  analog I(p, n) <+ mine * V(p, n);
        \\endmodule
        \\module top(p, n); inout p, n; electrical p, n;
        \\  resistor #(.mine(2.0)) r1(p, n);
        \\endmodule
    );
    const shadowed = try elaborate(g.ctx());
    try std.testing.expectEqualStrings("top", g.file.str(shadowed.top.name));
    try std.testing.expectEqual(@as(usize, 1), shadowed.top.params.len);
    try std.testing.expectEqualStrings("r1.mine", g.file.str(shadowed.top.params[0].name));
}

test "a module instantiating itself is E0905, not a stack overflow" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parse(&f,
        \\module loop(p); inout p; electrical p;
        \\  loop u(p);
        \\endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(f.ctx()));
    try std.testing.expectEqual(diag.Code.E0905, f.bag.at(0).code);
}

test "§6.6 an if-generate's instances are elaborated under their arm's scheme; a loop generate's once per iteration; a case generate's are E0235" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module top(p); inout p; electrical p; parameter integer sel = 0;
        \\  generate if (sel) begin leaf a(p); end else begin leaf b(p); end endgenerate
        \\endmodule
        \\module leaf(q); inout q; electrical q; analog I(q) <+ V(q); endmodule
    );
    const d = try elaborate(f.ctx());
    // Both leaves, then the top's own block; each leaf's body under its gate.
    try std.testing.expectEqual(@as(usize, 3), d.top.analog.len);
    for (d.top.analog[0..2]) |blk| try std.testing.expect(f.file.stmt(blk.body) == .if_stmt);

    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g,
        \\module top(p); inout p; electrical p; genvar i;
        \\  generate for (i = 0; i < 2; i = i + 1) begin : blk leaf a(p); end endgenerate
        \\endmodule
        \\module leaf(q); inout q; electrical q; analog I(q) <+ V(q); endmodule
    );
    // §6.6.1: one generate block instance per genvar value, `blk[i]`.
    const dg = try elaborate(g.ctx());
    try std.testing.expectEqual(@as(usize, 3), dg.units.len);
    try std.testing.expectEqualStrings("blk[0].a.", dg.units.items(.path)[1]);
    try std.testing.expectEqualStrings("blk[1].a.", dg.units.items(.path)[2]);

    var h: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer h.deinit();
    try parse(&h,
        \\module top(p); inout p; electrical p;
        \\  generate case (1) 1: begin leaf a(p); end endcase endgenerate
        \\endmodule
        \\module leaf(q); inout q; electrical q; analog I(q) <+ V(q); endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(h.ctx()));
    try std.testing.expectEqual(diag.Code.E0235, h.bag.at(0).code);
}

test "§6.3.6 a scaled instance's flow contribution is multiplied, its flow probe divided" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parseWithPrelude(&f,
        \\module top(p, n, o); inout p, n, o; electrical p, n, o;
        \\  kid #(.$mfactor(4.0)) u(p, n, o);
        \\endmodule
        \\module kid(a, b, c); inout a, b, c; electrical a, b, c;
        \\  analog I(a, b) <+ V(a, b);
        \\  analog V(c) <+ I(a, b);
        \\endmodule
    );
    const dsg = try elaborate(f.ctx());
    const x = &f.file.exprs;
    try std.testing.expectEqual(@as(usize, 2), dsg.top.analog.len);

    // connect_rule.Rule 1: the FLOW contribution's value is `V(a,b) * 4.0`. The left-hand
    // side is untouched: it names the branch and is not a read of it.
    const flow = f.file.stmt(dsg.top.analog[0].body).contribute;
    try std.testing.expectEqual(Ast.ExprTag.branch_access, x.tag(flow.lhs));
    try std.testing.expectEqual(Ast.BinaryOp.mul, x.binOp(flow.rhs));
    try std.testing.expectEqual(@as(f64, 4.0), x.realValue(x.rhs(flow.rhs)));

    // connect_rule.Rule 2: the POTENTIAL contribution is not scaled, but the flow probe
    // inside it is divided: one instance of 4 copies carries a quarter each.
    const pot = f.file.stmt(dsg.top.analog[1].body).contribute;
    try std.testing.expectEqual(Ast.ExprTag.branch_access, x.tag(pot.lhs));
    try std.testing.expectEqual(Ast.BinaryOp.div, x.binOp(pot.rhs));
    try std.testing.expectEqual(Ast.ExprTag.branch_access, x.tag(x.lhs(pot.rhs)));
    try std.testing.expectEqual(@as(f64, 4.0), x.realValue(x.rhs(pot.rhs)));
}

test "§6.3.1 a defparam beats the instance's own override, and an unmatched one is E0907" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parse(&f,
        \\module top(p, n); inout p, n; electrical p, n;
        \\  kid #(.g(2.0)) u(p, n);
        \\  defparam u.g = 5.0;
        \\endmodule
        \\module kid(a, b); inout a, b; electrical a, b;
        \\  parameter real g = 1.0;
        \\  analog I(a, b) <+ g * V(a, b);
        \\endmodule
    );
    const dsg = try elaborate(f.ctx());
    try std.testing.expectEqualStrings("u.g", f.file.str(dsg.top.params[0].name));
    // §6.3: "the parameter in the module shall take the value specified by the
    // defparam": 5.0, not the instance's 2.0, whichever came first in the text.
    const v = dsg.top.params[0].default;
    try std.testing.expectEqual(@as(f64, 5.0), f.file.exprs.realValue(v));

    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g,
        \\module top(p); inout p; electrical p;
        \\  defparam nowhere.g = 1.0;
        \\  analog I(p) <+ V(p);
        \\endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(g.ctx()));
    try std.testing.expectEqual(diag.Code.E0907, g.bag.at(0).code);
}

test "§3.4.7 defparam aliases share binding and reject conflicting spellings across mechanisms" {
    const Case = struct { inline_name: []const u8, defparams: []const u8, conflict: bool };
    const cases = [_]Case{
        .{ .inline_name = "ag", .defparams = "u.ag=5.0", .conflict = false },
        .{ .inline_name = "g", .defparams = "u.ag=2.0", .conflict = true },
        .{ .inline_name = "ag", .defparams = "u.g=2.0", .conflict = true },
        .{ .inline_name = "ag", .defparams = "u.bg=2.0", .conflict = true },
        .{ .inline_name = "ag", .defparams = "u.ag=2.0, u.bg=2.0", .conflict = true },
    };
    for ([_]bool{ false, true }) |paramset| for (cases) |case| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        const declarations = if (paramset)
            \\paramset card kid;
            \\parameter real g=1.0; aliasparam ag=g; aliasparam bg=g; .k=g;
            \\endparamset
            \\module kid(p); inout p; electrical p;
            \\parameter real k=1.0; analog I(p)<+k*V(p); endmodule
        else
            \\module card(p); inout p; electrical p;
            \\parameter real g=1.0; aliasparam ag=g; aliasparam bg=g;
            \\analog I(p)<+g*V(p); endmodule
        ;
        try parse(&f, try f.arena.allocator().print(
            \\module top(p); inout p; electrical p;
            \\card #(.{s}(2.0)) u(p); defparam {s}; endmodule
            \\{s}
        , .{ case.inline_name, case.defparams, declarations }));
        if (case.conflict) {
            try std.testing.expectError(error.DiagnosticsReported, elaborate(f.ctx()));
            try std.testing.expectEqual(diag.Code.E0908, f.bag.at(0).code);
        } else {
            const dsg = try elaborate(f.ctx());
            const target = if (paramset) "u.card.g" else "u.g";
            const p = for (dsg.top.params) |p| {
                if (std.mem.eql(u8, f.file.str(p.name), target)) break p;
            } else unreachable;
            try std.testing.expect(p.is_override);
            try std.testing.expectEqual(@as(f64, 5.0), f.file.exprs.realValue(p.default));
        }
    };
}

test "empty named associations retain defaults and do not mark param_given" {
    for ([_][]const u8{ "g", "ag" }) |name| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try parse(&f, try f.arena.allocator().print(
            \\module top(p); inout p; electrical p; kid #( .{s}() ) u(p); endmodule
            \\module kid(p); inout p; electrical p;
            \\parameter real g=3.0; aliasparam ag=g;
            \\analog I(p)<+$param_given(g);
            \\endmodule
        , .{name}));
        const dsg = try elaborate(f.ctx());
        const p = dsg.top.params[0];
        try std.testing.expect(!p.is_override);
        try std.testing.expectEqual(@as(f64, 3.0), f.file.exprs.realValue(p.default));
        const contribution = f.file.stmt(dsg.top.analog[0].body).contribute;
        try std.testing.expectEqual(@as(i64, 0), f.file.exprs.intValue(contribution.rhs));
    }
}

test "empty named associations still validate parameter and localparam names" {
    // Unknown names are forbidden by §6.3.3. The localparam case preserves
    // current implementation behavior only: §3.4.5 forbids modification, but
    // an empty association modifies nothing. Its normative status is open;
    // this regression must not count as conformance rejection evidence.
    for ([_][]const u8{ "absent", "locked" }) |name| {
        var f: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try parse(&f, try f.arena.allocator().print(
            \\module top(p); inout p; electrical p; kid #( .{s}() ) u(p); endmodule
            \\module kid(p); inout p; electrical p;
            \\localparam real locked=3.0; analog I(p)<+V(p);
            \\endmodule
        , .{name}));
        try std.testing.expectError(error.DiagnosticsReported, elaborate(f.ctx()));
        try std.testing.expectEqual(diag.Code.E0907, f.bag.at(0).code);
    }
}

test "empty named associations do not suppress defparam override or given state" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module top(p); inout p; electrical p;
        \\kid #(.g()) u(p); defparam u.g=5.0; endmodule
        \\module kid(p); inout p; electrical p;
        \\parameter real g=3.0; analog I(p)<+$param_given(g); endmodule
    );
    const dsg = try elaborate(f.ctx());
    try std.testing.expect(dsg.top.params[0].is_override);
    try std.testing.expectEqual(@as(f64, 5.0), f.file.exprs.realValue(dsg.top.params[0].default));
    const contribution = f.file.stmt(dsg.top.analog[0].body).contribute;
    try std.testing.expectEqual(@as(i64, 1), f.file.exprs.intValue(contribution.rhs));
}

test "empty named associations leave the inherited mfactor product unchanged" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module top(p); inout p; electrical p; mid #(.$mfactor(4.0)) u(p); endmodule
        \\module mid(p); inout p; electrical p; kid #(.$mfactor()) v(p); endmodule
        \\module kid(p); inout p; electrical p; analog V(p)<+$mfactor; endmodule
    );
    const dsg = try elaborate(f.ctx());
    const contribution = f.file.stmt(dsg.top.analog[0].body).contribute;
    try std.testing.expectEqual(@as(f64, 4.0), f.file.exprs.realValue(contribution.rhs));
}

test "compile-time selection overrides replace default dependencies in host shape inputs" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module top(p); inout p; electrical p;
        \\parameter real unrelated=2.0, base=unrelated;
        \\bin #(.w(2.0)) u(p); defparam u.w=base; endmodule
        \\paramset bin kid;
        \\parameter real w=1.0 from [0:4); .g=2.0; endparamset
        \\paramset bin kid;
        \\parameter real w=0.0 from [4:10]; .g=3.0; endparamset
        \\module kid(p); inout p; electrical p;
        \\parameter real g=0.0; analog I(p)<+g*V(p); endmodule
    );
    var ctx = f.ctx();
    ctx.param_overrides = &.{.{ .name = "base", .value = 7.0 }};
    const dsg = try elaborate(ctx);
    try std.testing.expect(dsg.selection_params.len != 0);
    for (dsg.selection_params) |name|
        try std.testing.expectEqualStrings("base", f.file.str(name));
    const gain = for (dsg.top.params) |p| {
        if (std.mem.eql(u8, f.file.str(p.name), "u.g")) break p;
    } else unreachable;
    try std.testing.expectEqual(@as(f64, 3.0), f.file.exprs.realValue(gain.default));
}

test "empty named associations use paramset defaults in admission and tie scores" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module top(p); inout p; electrical p; bin #(.g()) u(p); endmodule
        \\paramset bin base;
        \\parameter real g=2.0 from [1.0:3.0]; .k=g;
        \\endparamset
        \\paramset bin base;
        \\parameter real g=0.0 from [1.0:3.0]; .k=99.0;
        \\endparamset
        \\module base(p); inout p; electrical p;
        \\parameter real k=1.0; analog I(p)<+k*V(p);
        \\endmodule
    );
    const dsg = try elaborate(f.ctx());
    const ps_value = for (dsg.top.params) |p| {
        if (std.mem.eql(u8, f.file.str(p.name), "u.bin.g")) break p;
    } else unreachable;
    try std.testing.expectEqual(@as(f64, 2.0), f.file.exprs.realValue(ps_value.default));
    try std.testing.expect(!ps_value.is_override);
}

test "§6.4.2 the paramset whose range admits the override is selected, and a gap is E0911" {
    const src =
        \\module top(p, n); inout p, n; electrical p, n;
        \\  bin #(.l({s})) u(p, n);
        \\endmodule
        \\paramset bin base;
        \\  parameter real l = 1.0 from [1.0:inf);
        \\  .k = 10.0;
        \\endparamset
        \\paramset bin base;
        \\  parameter real l = 0.25 from [0.25:1.0);
        \\  .k = 20.0;
        \\endparamset
        \\module base(a, b); inout a, b; electrical a, b;
        \\  parameter real k = 9.0;
        \\  analog I(a, b) <+ k * V(a, b);
        \\endmodule
    ;
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f, try f.arena.allocator().print(src, .{"0.5"}));
    const dsg = try elaborate(f.ctx());
    // The SECOND paramset is the admitting one, so a first-match with no range
    // test answers 10.0 here.
    const k = for (dsg.top.params) |p| {
        if (std.mem.eql(u8, f.file.str(p.name), "u.k")) break p.default;
    } else unreachable;
    try std.testing.expectEqual(@as(f64, 20.0), f.file.exprs.realValue(k));

    // A value in the gap between the bins belongs to neither.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g, try g.arena.allocator().print(src, .{"0.1"}));
    try std.testing.expectError(error.DiagnosticsReported, elaborate(g.ctx()));
    try std.testing.expectEqual(diag.Code.E0911, g.bag.at(0).code);
}

test "Annex F.2 a leaf's discipline reaches the top segment it is bound to" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parse(&f,
        \\discipline annex_f_y; enddiscipline
        \\module top(a); inout a;
        \\  mid m(a);
        \\  annex_f_y m.l.p;
        \\endmodule
        \\module mid(p); inout p;
        \\  leaf l(p);
        \\endmodule
        \\module leaf(p); inout p; electrical p;
        \\endmodule
    );
    const dsg = try elaborate(f.ctx());
    // The path is INSTANCE names, so it is `m.l.p` and not `m.leaf.p`: §6.7 walks
    // the instance tree. The leaf declares `electrical p`, the declaration above
    // declares it out of context, and
    // §3.10 order 1 wins. Both segments are the top's `a` after the flatten, so
    // the discipline lands on a net declaration for `a` and on nothing else.
    try std.testing.expectEqual(@as(usize, 1), dsg.top.nets.len);
    try std.testing.expectEqualStrings("a", f.file.str(dsg.top.nets[0].name));
    try std.testing.expectEqualStrings("annex_f_y", f.file.str(dsg.top.nets[0].discipline));
}

test "Annex F.2.1 step 4.b: resolveto resolves the multi-candidate net, no rule with a mixed port is E0903, exclude is E0917" {
    // The candidate topology of all three: an undeclared top net bound to two
    // leaves with distinct continuous disciplines. The `{s}` slots vary only
    // the connectrules block and whether the discrete leaf is bound.
    const src =
        \\discipline fa; domain continuous; enddiscipline
        \\discipline fb; domain continuous; enddiscipline
        \\discipline fc; domain continuous; enddiscipline
        \\discipline fd; domain discrete; enddiscipline
        \\{s}
        // `top` first: when the discrete leaf is not bound it is a second
        // root, and pickTop takes the first root in source order.
        \\module top(sig);
        \\  inout sig;
        \\  la ia(sig);
        \\  lb ib(sig);
        \\  {s}
        \\endmodule
        \\module la(p); inout p; fa p; endmodule
        \\module lb(p); inout p; fb p; endmodule
        \\module ld(d); inout d; fd d; endmodule
    ;
    const S = struct {
        fn build(f: *Fixture, rules: []const u8, extra: []const u8) !void {
            try parse(f, try f.arena.allocator().print(src, .{ rules, extra }));
        }
    };

    // Bullet 3: {fa, fb} matches the statement's list (order-free), so the net
    // is fc, which is neither candidate, per §7.7.2.1's "need not be one of
    // the disciplines specified".
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try S.build(&f, "connectrules r; connect fb, fa resolveto fc; endconnectrules", "");
    const dsg = try elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 1), dsg.top.nets.len);
    try std.testing.expectEqualStrings("fc", f.file.str(dsg.top.nets[0].discipline));

    // §7.7.2.1: the candidate set {fa,fb} is a subset of {fa,fb,fc}.
    var subset: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer subset.deinit();
    try S.build(&subset, "connectrules r; connect fa, fb, fc resolveto fc; endconnectrules", "");
    const sub = try elaborate(subset.ctx());
    try std.testing.expectEqualStrings("fc", subset.file.str(sub.top.nets[0].discipline));
    try std.testing.expectEqual(0, subset.bag.count());

    // A later exact match wins without warning about the discarded subset.
    var exact: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer exact.deinit();
    try S.build(&exact, "connectrules r; connect fa, fb, fc resolveto fc; connect fa, fb resolveto fb; endconnectrules", "");
    const ex = try elaborate(exact.ctx());
    try std.testing.expectEqualStrings("fb", exact.file.str(ex.top.nets[0].discipline));
    try std.testing.expectEqual(0, exact.bag.count());

    // Duplicate exact and subset rules both warn and retain source order.
    for ([_][]const u8{
        "connectrules r; connect fa, fb resolveto fb; connect fb, fa resolveto fc; endconnectrules",
        "connectrules r; connect fa, fb, fc resolveto fb; connect fc, fb, fa resolveto fc; endconnectrules",
    }) |rules| {
        var ambiguous: Fixture = .{ .arena = .init(std.testing.allocator) };
        defer ambiguous.deinit();
        try S.build(&ambiguous, rules, "");
        const amb = try elaborate(ambiguous.ctx());
        try std.testing.expectEqualStrings("fb", ambiguous.file.str(amb.top.nets[0].discipline));
        try std.testing.expectEqual(1, ambiguous.bag.count());
        try std.testing.expectEqual(diag.Code.W0950, ambiguous.bag.at(0).code);
    }

    // Bullet 4, error half: no statement matches, the discipline is unknown,
    // and the discrete segment is the mixed-port connection.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try S.build(&g, "", "ld id(sig);");
    try std.testing.expectError(error.DiagnosticsReported, elaborate(g.ctx()));
    try std.testing.expectEqual(diag.Code.E0903, g.bag.at(0).code);

    // Bullet 4, legal half: same unknown, no discrete segment: the net keeps
    // the first arrival and the dsg elaborates.
    var h: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer h.deinit();
    try S.build(&h, "", "");
    const legal = try elaborate(h.ctx());
    try std.testing.expectEqualStrings("fa", h.file.str(legal.top.nets[0].discipline));

    // §7.7.2 exclude: the match refuses the net instead of resolving it.
    var k: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer k.deinit();
    try S.build(&k, "connectrules r; connect fa, fb resolveto exclude; endconnectrules", "");
    try std.testing.expectError(error.DiagnosticsReported, elaborate(k.ctx()));
    try std.testing.expectEqual(diag.Code.E0917, k.bag.at(0).code);
}

test "§7.7 connectrules names are judged even for a tree of one (E0915, E0916)" {
    // `top` has no instances, so this exercises the check ahead of the
    // tree-of-one shortcut: an insertion naming an ordinary module and a
    // resolution naming an undeclared discipline are both dead statements.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\discipline fa; domain continuous; enddiscipline
        \\module top(p); inout p; fa p; endmodule
        \\connectrules r;
        \\  connect top;
        \\  connect fa, nowhere resolveto fa;
        \\endconnectrules
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(f.ctx()));
    try std.testing.expectEqual(diag.Code.E0915, f.bag.at(0).code);
    try std.testing.expectEqual(diag.Code.E0916, f.bag.at(1).code);
}

test "an instance naming no module is E0904" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    try parse(&f,
        \\module top(p); inout p; electrical p;
        \\  nowhere u(p);
        \\endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(f.ctx()));
    try std.testing.expectEqual(diag.Code.E0904, f.bag.at(0).code);
}

test "a connect module is never the top (§7.6), and a hand-placed one is inlined (§7.1)" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();

    // Declared FIRST and instantiated by nobody, so "the first module nothing
    // instantiates" would pick it. §7.6 makes it the insertion phase's to place.
    try parse(&f,
        \\connectmodule bridge(a, d); inout a, d; electrical a; endmodule
        \\module top(p); inout p; electrical p; analog I(p) <+ V(p); endmodule
    );
    const dsg = try elaborate(f.ctx());
    try std.testing.expectEqualStrings("top", f.file.str(dsg.top.name));

    // §7.1: connect modules "can be manually inserted (by the user)", so
    // naming one inlines it like any child, its analog block included.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g,
        \\connectmodule bridge(a, d); inout a, d; electrical a, d; analog I(a, d) <+ V(a, d); endmodule
        \\module top(p); inout p; electrical p; bridge u(p, p); analog I(p) <+ V(p); endmodule
    );
    const inlined = try elaborate(g.ctx());
    try std.testing.expectEqual(@as(usize, 2), inlined.top.analog.len);
}

test "§7.2.2 a flattened discrete half is carried, never dropped" {
    // The top's own `initial` survives having a child, and the child's is
    // renamed into the flat namespace next to it.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module c(p); inout p; electrical p; integer k; initial k = 3; analog I(p) <+ k * V(p); endmodule
        \\module top(p); inout p; electrical p; integer j; initial j = 2; c u(p); analog I(p) <+ j * V(p); endmodule
    );
    const dsg = try elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 2), dsg.top.discrete.len);
    const child_init = f.file.stmt(dsg.top.discrete[1].body).assign;
    try std.testing.expectEqualStrings("u.k", f.file.str(f.file.exprs.strOf(child_init.target)));

    // So is a child's process in a dsg that needs the event kernel: the
    // mixed runner resolves `u.q` as a §6.7 path (`sim.digital.Run.slotOf`).
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g,
        \\module c(p); inout p; electrical p; reg q; always #5 q = ~q; analog I(p) <+ V(p); endmodule
        \\module top(p); inout p; electrical p; c u(p); endmodule
    );
    const mixed = try elaborate(g.ctx());
    try std.testing.expectEqual(@as(usize, 1), mixed.top.discrete.len);
    const toggle = g.file.stmt(g.file.stmt(mixed.top.discrete[0].body).event_control.body).assign;
    try std.testing.expectEqualStrings("u.q", g.file.str(g.file.exprs.strOf(toggle.target)));
}

test "IEEE 1364 §12.3.3 two variable ports collapsed onto one net declare it once" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module d(o); output o; reg o; initial o = 1'b0; endmodule
        \\module top(p); inout p; electrical p; wire w; d a(w); d b(w); analog I(p) <+ V(p); endmodule
    );
    const dsg = try elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 1), dsg.top.vars.len);
    try std.testing.expectEqualStrings("w", f.file.str(dsg.top.vars[0].name));
}

test pickTop {
    // §6.2.2: of several roots, the first in source order is the device.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\module a(p); inout p; electrical p; endmodule
        \\module b(p); inout p; electrical p; endmodule
    );
    try std.testing.expectEqual(&f.file.modules[0], (try elaborate(f.ctx())).top);

    // §6.4: a module a paramset chain ends at is instantiated through it, so
    // `base`, declared first and named by no instance, is not the root.
    // The chain's near link wins the module parameter both links assign.
    var g: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try parse(&g,
        \\module base(a); inout a; electrical a; parameter real j = 0.0; analog I(a) <+ j * V(a); endmodule
        \\paramset near far; parameter real gn = 1.0; .j = gn; endparamset
        \\paramset far base; parameter real hf = 2.0; .j = hf; endparamset
        \\module top(p); inout p; electrical p; near u(p); endmodule
    );
    const chained = try elaborate(g.ctx());
    try std.testing.expectEqualStrings("top", g.file.str(chained.top.name));
    const j = fixture.paramNamed(&g.file, chained.top, "u.j").?;
    try std.testing.expectEqualStrings("u.near.gn", g.file.str(g.file.exprs.strOf(j.default)));

    // Every module instantiated by another: the first is the top, and the
    // cycle is E0905.
    var h: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer h.deinit();
    try parse(&h,
        \\module a(p); inout p; electrical p; b u(p); endmodule
        \\module b(p); inout p; electrical p; a v(p); endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate(h.ctx()));
    try std.testing.expect(fixture.hasCode(&h.bag, .E0905));

    // §7.6: a file of connect modules only has no device.
    var k: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer k.deinit();
    try parse(&k, "connectmodule c(a, d); inout a, d; endmodule");
    try std.testing.expectError(error.NoModule, elaborate(k.ctx()));
}

test "every allocation elaborate makes can fail, and the failure is OutOfMemory, not a swallowed or leaked one" {
    // One dsg through every walk: the §12.8.1 seed walk (an upward
    // defparam), the §7.8.4 dry walk (connectrules), a paramset, an instance
    // array, a loop and an if-generate, $mfactor and an out-of-context net.
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try parse(&f,
        \\discipline ca; domain continuous; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\connectmodule a2d(el, cm); input el; output cm; ca el; dd cm; endmodule
        \\connectrules r; connect a2d; endconnectrules
        \\module din(d); input d; dd d; endmodule
        \\module leaf(a); inout a; ca a; parameter real g = 1.0; analog I(a) <+ g * V(a); endmodule
        \\paramset ps leaf; parameter real x = 2.0 from [0:9]; .g = x; endparamset
        \\module mid(a); inout a; ca a; parameter integer n = 2; genvar i; ca w;
        \\  leaf #(.$mfactor(2.0)) arr[n-1:0](a);
        \\  generate for (i = 0; i < n; i = i + 1) begin : blk leaf #(.g(i)) u(a); end endgenerate
        \\  generate if (n > 1) begin ps #(.x(3.0)) p(a); end endgenerate
        \\  defparam top.k.g = 4.0;
        \\endmodule
        \\module top(p); inout p; ca p; mid m(p); leaf k(p); din d(p); ca m.w; endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), f.bag.count());
    // `checkAllAllocationFailures` over an arena would fail only the arena's
    // chunk requests, so the failing allocator sits ABOVE a fresh arena:
    // allocation i of `elaborate` itself fails, for every i, and the arena
    // takes back whatever the failed run built.
    const base = f.file.base.?;
    var i: usize = 0;
    while (true) : (i += 1) {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        var failing: std.testing.FailingAllocator = .init(arena.allocator(), .{ .fail_index = i });
        var file = base.overlay(.{});
        var bag: diag.Bag = .init(arena.allocator());
        var c = f.ctx();
        c.arena = failing.allocator();
        c.file = &file;
        c.bag = &bag;
        if (elaborate(c)) |_| {
            // No failure was induced and swallowed on the way to a dsg.
            try std.testing.expect(!failing.has_induced_failure);
            break;
        } else |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            try std.testing.expect(failing.has_induced_failure);
        }
    }
    // The dsg allocates; the loop above failed each of those.
    try std.testing.expect(i > 100);
}

test {
    // Every file of the module, so each one's own tests run with `test-elab`.
    _ = @import("Flatten.zig");
    _ = @import("access.zig");
    _ = @import("alias.zig");
    _ = @import("clone_decl.zig");
    _ = @import("clone_expr.zig");
    _ = @import("clone_stmt.zig");
    _ = @import("connect_rule.zig");
    _ = @import("decl_check.zig");
    _ = @import("defparam.zig");
    _ = @import("design.zig");
    _ = @import("flat_name.zig");
    _ = @import("fold.zig");
    _ = @import("generate.zig");
    _ = @import("insert.zig");
    _ = @import("instance.zig");
    _ = @import("lookup.zig");
    _ = @import("ooc.zig");
    _ = @import("override.zig");
    _ = @import("paramset.zig");
    _ = @import("paramset_dist.zig");
    _ = @import("paramset_select.zig");
    _ = @import("ports.zig");
    _ = @import("primitive.zig");
    _ = @import("resolve.zig");
    _ = @import("segment.zig");
    _ = @import("spice_case.zig");
    _ = @import("walk.zig");
}
