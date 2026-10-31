//! Compilation-wide declaration checks, once per compilation over every
//! module: the names §7.7 `connectrules` statements use (E0915, E0916,
//! E0923, E0982, E0907) and the disciplines net declarations name (E0371).
//! Cites: LRM §3.6.2, §7.6, §7.7.1, §7.7.2, §7.7.3, §7.8, A.1.2, A.2.1.3,
//! Annex D.1.
//!
//! Contents:
//! - `pub fn checkConnectRules(self: *Flatten) design.Error!void`
//! - `pub fn checkNetDisciplines(self: *Flatten) design.Error!void`

const std = @import("std");
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const lookup = @import("lookup.zig");
const connect_rule = @import("connect_rule.zig");
const discipline = @import("discipline_rules.zig");
const fixture = @import("fixture.zig");

/// Checks the names every §7.7 `connectrules` statement uses (E0915, E0916,
/// E0923, E0982, E0907), once per compilation. Not the parser's job: A.1.2
/// puts no order on descriptions, so the connect module or discipline may be
/// declared after the block.
pub fn checkConnectRules(self: *Flatten) design.Error!void {
    for (self.ctx.file.connectrules) |cr| {
        for (cr.insertions) |*ins| {
            // §7.7.1 "connect connectmodule_identifier": the name must be
            // a §7.6 connect module; an ordinary module bridges nothing.
            const m = lookup.findModule(self, ins.module) orelse {
                try self.err(ins.main_tok, .E0915, "nothing declares `{s}`", .{self.ctx.file.str(ins.module)});
                continue;
            };
            if (!m.is_connect) try self.err(ins.main_tok, .E0915, "`{s}` is not declared with `connectmodule`", .{
                self.ctx.file.str(ins.module),
            });
            // §7.8 "When two disciplines are specified in a connect
            // statement, one shall be discrete and the other continuous."
            if (ins.overrides) |o| {
                // A name no discipline declares has no domain, so it is
                // neither of the two: refused here, not skipped.
                const da = if (discipline.declOf(self.ctx.file, o.a)) |d| discipline.domainOf(d) else null;
                const db = if (discipline.declOf(self.ctx.file, o.b)) |d| discipline.domainOf(d) else null;
                if (da == null or db == null or da == db) {
                    try self.err(ins.main_tok, .E0923, "`{s}` and `{s}`: one shall be discrete and the other continuous", .{
                        self.ctx.file.str(o.a), self.ctx.file.str(o.b),
                    });
                    continue;
                }
            }
            // §7.7.1 "the specified disciplines shall be compatible for both
            // the continuous and discrete disciplines of the given connect
            // module" (E0915), §7.6 Table 7-2's direction pairs (E0982) and
            // §7.7.3's parameter names (E0907), judged once for every
            // statement: insertion (`insert.plan`) reads the same rule
            // quietly and only in a module whose ports reach one.
            if (!m.is_connect) continue;
            if (try connect_rule.ruleOf(self, ins, true)) |r| try connect_rule.checkDirections(self, r);
            _ = try connect_rule.paramsDeclared(self, ins, m, true);
        }
        for (cr.resolutions) |r| {
            // §7.7.2 every identifier in a resolution statement is a
            // discipline_identifier; one that names no discipline can
            // never match a candidate list, and would silently turn a
            // resolving design into an E0903 one.
            for (r.disciplines) |d| if (discipline.declOf(self.ctx.file, d) == null)
                try self.err(r.main_tok, .E0916, "nothing declares a discipline `{s}`", .{self.ctx.file.str(d)});
            if (!r.exclude and discipline.declOf(self.ctx.file, r.resolved) == null)
                try self.err(r.main_tok, .E0916, "nothing declares a discipline `{s}`", .{self.ctx.file.str(r.resolved)});
        }
    }
}

/// Checks that every net declaration in every user module names a declared
/// discipline (A.2.1.3, §3.6.2; E0371), once per compilation. Every module,
/// because the common form of this error, `child c1;` (an instance missing
/// its parentheses, parsed as a net of discipline `child`), leaves `child`
/// an uninstantiated module that is never lowered.
pub fn checkNetDisciplines(self: *Flatten) design.Error!void {
    // ponytail: nets declared inside a generate block are not visited; add
    // them when a fixture declares one with a bad discipline.
    const file = self.ctx.file;
    // `require_std_includes`: annex D.1's disciplines reach
    // only a source that includes disciplines.vams. A user discipline of the
    // same name comes later in `disciplines`, so `declOf` finds it first.
    if (file.hidden_disciplines != 0) for (file.userModules()) |*m| {
        for (m.ports) |x| try hiddenDiscipline(self, x.discipline, x.name, x.main_tok);
        for (m.nets) |x| try hiddenDiscipline(self, x.discipline, x.name, x.main_tok);
        for (m.vars) |x| try hiddenDiscipline(self, x.discipline, x.name, x.main_tok);
    };
    for (file.userModules()) |*m| for (m.nets) |n| {
        if (n.discipline == .none or discipline.declOf(file, n.discipline) != null) continue;
        if (lookup.findModule(self, n.discipline) != null)
            try self.err(n.main_tok, .E0371, "`{s}` in the declaration of `{s}` is a module; an A.4.1 module_instance takes a parenthesised port list even when it is empty: `{s} {s}();`", .{
                file.str(n.discipline), file.str(n.name), file.str(n.discipline), file.str(n.name),
            })
        else
            try self.err(n.main_tok, .E0371, "`{s}` in the declaration of `{s}`", .{ file.str(n.discipline), file.str(n.name) });
    };
    // A.2.1.3 `reg [ discipline_identifier ] ...` names a discipline too.
    for (file.userModules()) |*m| for (m.vars) |v| {
        if (v.discipline == .none or discipline.declOf(file, v.discipline) != null) continue;
        try self.err(v.main_tok, .E0371, "`{s}` in the declaration of the reg `{s}`", .{ file.str(v.discipline), file.str(v.name) });
    };
}

// ---- private ----

/// E0371 when `name` resolves only to a prelude annex D.1 discipline the
/// source did not include.
fn hiddenDiscipline(self: *Flatten, name: Ast.StrId, decl_name: Ast.StrId, tok: u32) design.Error!void {
    if (name == .none) return;
    const file = self.ctx.file;
    const d = discipline.declOf(file, name) orelse return;
    const index = (@intFromPtr(d) - @intFromPtr(file.disciplines.ptr)) / @sizeOf(Ast.DisciplineDecl);
    if (index >= file.hidden_disciplines) return;
    try self.err(tok, .E0371, "`{s}` in the declaration of `{s}` is annex D.1's: add `include \"disciplines.vams\"", .{ file.str(name), file.str(decl_name) });
}

test checkNetDisciplines {
    // A.2.1.3: `kid c1;` is a net of discipline `kid`, a module instance
    // missing its `()`: E0371, even though nothing instantiates `kid`.
    var bad: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer bad.deinit();
    try fixture.parse(&bad,
        \\discipline ca; domain continuous; enddiscipline
        \\module top(p); inout p; ca p; kid c1; endmodule
        \\module kid(a); inout a; ca a; endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(bad.ctx()));
    try std.testing.expect(fixture.hasCode(&bad.bag, .E0371));

    // The legal neighbour declares the net with a discipline.
    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good,
        \\discipline ca; domain continuous; enddiscipline
        \\module top(p); inout p; ca p; ca w; endmodule
    );
    _ = try elaborate.elaborate(good.ctx());
}

test "§7.8 a connect statement's override naming no discipline is E0923" {
    // "When two disciplines are specified in a connect statement, one shall
    // be discrete and the other continuous." A name no declaration
    // introduces is neither, so the statement bridges nothing; it is
    // refused, not skipped. The neighbour overrides with declared ones.
    const src =
        \\discipline ca; domain continuous; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\connectmodule bridge(a, d); input a; output d; ca a; dd d; endmodule
        \\module top(p); inout p; ca p; endmodule
        \\connectrules r; connect bridge {s}, dd; endconnectrules
    ;
    var bad: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer bad.deinit();
    try fixture.parse(&bad, try bad.arena.allocator().print(src, .{"nowhere"}));
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(bad.ctx()));
    try std.testing.expect(fixture.hasCode(&bad.bag, .E0923));

    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good, try good.arena.allocator().print(src, .{"ca"}));
    _ = try elaborate.elaborate(good.ctx());
}
