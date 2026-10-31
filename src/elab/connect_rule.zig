//! §7.7.1 connect statements read as rules: a connect statement → §7.6
//! Table 7-2's continuous/discrete sides with §7.7.1's overrides applied, the
//! matching of a mixed port against them (§7.8.4), and E0927/E0929 for a
//! mixed port no rule bridged.
//! Cites: LRM §3.6.2.4, §3.11.1, §6.2.2, §6.5.7, §7.6, §7.7.1, §7.7.3,
//! §7.8.4, A.1.3.
//!
//! Contents:
//! - `pub const Unbridged = struct`
//! - `pub const Rule = struct`
//! - `pub fn ruleOf(self: *Flatten, ins: *const Ast.ConnectInsertion, report: bool) design.Error!?Rule`
//! - `pub fn checkDirections(self: *Flatten, r: Rule) design.Error!void`
//! - `pub fn paramsDeclared(self: *Flatten, ins: *const Ast.ConnectInsertion, m: *const Ast.ModuleDecl, report: bool) design.Error!bool`
//! - `pub fn connIndex(inst: *const Ast.Instance, p: Ast.Port, pi: usize) ?usize`
//! - `pub fn checkUnbridged(self: *Flatten) design.Error!void`
//! - `pub fn matchRules(file: *const Ast.SourceFile, rules: []const Rule, dir: Ast.Direction, upper: Ast.StrId, lower: Ast.StrId) struct { ?usize, usize }`
//! - `pub fn domain(file: *const Ast.SourceFile, d: Ast.StrId) ?Ast.DisciplineDecl.Domain`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const lookup = @import("lookup.zig");
const override = @import("override.zig");
const segment = @import("segment.zig");
const hier_param = @import("hier_param.zig");
const discipline = @import("discipline_rules.zig");
const fixture = @import("fixture.zig");

/// A child port `plan` bridged with nothing, as `checkUnbridged` reads it.
pub const Unbridged = struct {
    tok: u32,
    /// The flat net the port joins.
    net: Ast.StrId,
    /// The port's own discipline: its lower connection.
    lower: Ast.StrId,
    port: Ast.StrId,
    inst: Ast.StrId,
    dir: Ast.Direction,
    /// The upper connection as `plan` resolved it, when it could: then the
    /// port is known mixed and no statement matched it.
    upper: ?segment.Seg = null,
};

/// One connect statement, read as §7.6's Table 7-2 pair: which of the connect
/// module's two ports is continuous and which discrete, with the discipline and
/// direction each has after §7.7.1's overrides.
pub const Rule = struct {
    ins: *const Ast.ConnectInsertion,
    module: *const Ast.ModuleDecl,
    cont: Side,
    disc: Side,

    const Side = struct { port: Ast.StrId, discipline: Ast.StrId, dir: Ast.Direction };
};

/// Reads a §7.7.1 connect statement as a `Rule`: the module's two ports split
/// into the continuous and the discrete side (§7.6 "The port disciplines define the
/// default type of disciplines which shall be bridged by the connect module.
/// The directional qualifiers of the discrete port determine the default
/// scenarios"), then the statement's overrides applied by domain ("one shall
/// be discrete and the other continuous"). Null for a statement this pass
/// cannot read: an unknown module was E0915 already. `report` is true for the
/// one call per statement `checkConnectRules` makes, so a conflicting override
/// is diagnosed once per compilation and not once per module that has ports.
pub fn ruleOf(self: *Flatten, ins: *const Ast.ConnectInsertion, report: bool) design.Error!?Rule {
    const file = self.ctx.file;
    const m = lookup.findModule(self, ins.module) orelse return null;
    if (!m.is_connect or m.ports.len != 2) return null;
    var cont: ?Rule.Side = null;
    var disc: ?Rule.Side = null;
    for (m.ports) |p| {
        const side: Rule.Side = .{ .port = p.name, .discipline = p.discipline, .dir = p.direction };
        switch (domain(file, p.discipline) orelse return null) {
            .continuous => cont = side,
            .discrete => disc = side,
            .unspecified => return null,
        }
    }
    var r: Rule = .{ .ins = ins, .module = m, .cont = cont orelse return null, .disc = disc orelse return null };
    if (ins.overrides) |o| for ([_]struct { Ast.Direction, Ast.StrId }{ .{ o.a_dir, o.a }, .{ o.b_dir, o.b } }) |ov| {
        const side = switch (domain(file, ov[1]) orelse return null) {
            .continuous => &r.cont,
            .discrete => &r.disc,
            .unspecified => return null,
        };
        // "the specified disciplines shall be compatible for both the
        // continuous and discrete disciplines of the given connect module"
        if (discipline.disciplineConflict(file, side.discipline, ov[1])) |why| {
            if (report) try self.err(ins.main_tok, .E0915, "`{s}` cannot stand for `{s}`'s `{s}` ({s})", .{
                file.str(ov[1]), file.str(m.name), file.str(side.discipline), why,
            });
            return null;
        }
        side.discipline = ov[1];
        if (ov[0] != .unspecified) side.dir = ov[0];
    };
    assert(r.module.is_connect);
    assert(r.cont.port != r.disc.port); // one continuous and one discrete port
    return r;
}

/// §7.6 Table 7-2, "The following combinations of directional qualifiers are
/// supported for the continuous and discrete disciplines of a connect module":
/// input/output, output/input, inout/inout, read after §7.7.1's direction
/// overrides, which "are used to define the type of connect module". Any other
/// pair names no scenario the module could be inserted in, so the statement
/// is refused (E0982). A port with no direction is not judged here.
pub fn checkDirections(self: *Flatten, r: Rule) design.Error!void {
    assert(r.module.is_connect);
    const c = r.cont.dir;
    const d = r.disc.dir;
    if (c == .unspecified or d == .unspecified) return;
    if ((c == .input and d == .output) or (c == .output and d == .input) or (c == .inout and d == .inout)) return;
    const file = self.ctx.file;
    try self.err(r.ins.main_tok, .E0982, "`{s}`'s continuous port `{s}` is `{t}` and its discrete port `{s}` is `{t}`", .{
        file.str(r.module.name), file.str(r.cont.port), c, file.str(r.disc.port), d,
    });
}

/// §7.7.3 "Any parameters declared in the connect module can be specified":
/// the statement's `#(...)` is an A.4.1 parameter_value_assignment on the
/// module it names, so a name that module does not declare, a localparam
/// (§3.4.5) or an ordered list longer than its overridable parameters is the
/// same E0907 an instance gets, judged at the statement whether or not any
/// port selects it. `report` as in `ruleOf`. Returns whether every entry
/// named an overridable parameter.
pub fn paramsDeclared(self: *Flatten, ins: *const Ast.ConnectInsertion, m: *const Ast.ModuleDecl, report: bool) design.Error!bool {
    assert(m.is_connect);
    const file = self.ctx.file;
    if (ins.params.len == 0) return true;
    const named = ins.params[0].name != .none;
    if (!named) {
        const n = override.overridableCount(m.params);
        if (ins.params.len <= n) return true;
        if (report) try self.err(ins.params[n].main_tok, .E0907, "`{s}` declares {d} overridable parameter{s}, and this connect statement sets {d}", .{
            file.str(m.name), n, if (n == 1) "" else "s", ins.params.len,
        });
        return false;
    }
    var ok = true;
    for (ins.params) |o| {
        var target = o.name;
        for (m.aliasparams) |al| if (al.alias == o.name) {
            target = al.target;
            break;
        };
        if (hier_param.Kind.fromName(file.str(target)) != null) continue;
        const decl = for (m.params) |*p| {
            if (p.name == target) break p;
        } else null;
        if (decl != null and !decl.?.is_local) continue;
        ok = false;
        if (report) try self.err(o.main_tok, .E0907, "`{s}` is {s} of connect module `{s}`", .{
            file.str(o.name), if (decl == null) "not a parameter" else "a localparam", file.str(m.name),
        });
    }
    return ok;
}

/// The index into `inst.ports` that binds `p`, the `pi`'th declared port.
pub fn connIndex(inst: *const Ast.Instance, p: Ast.Port, pi: usize) ?usize {
    const named = inst.ports.len != 0 and inst.ports[0].name != .none;
    if (!named) return if (pi < inst.ports.len) pi else null;
    for (inst.ports, 0..) |c, i| if (c.name == p.connName()) return i;
    return null;
}

/// §7.8.4 "the port shall match one (and only one) connect statement", the
/// zero-match half (E0922 is the other), and §6.5.7 "Ports of both analog
/// and digital discipline may be connected to a net provided the
/// appropriate connect statements exist". Run after §7.4 resolution, since
/// a port is mixed by the disciplines its net resolved to, not by what
/// crosses it.
pub fn checkUnbridged(self: *Flatten) design.Error!void {
    const file = self.ctx.file;
    for (self.unbridged.items) |u| {
        if (u.upper) |up| {
            try unmatched(self, u.tok, u.port, u.inst, u.lower, u.net, up.disc);
            continue;
        }
        const upper = self.res.disc_of.get(u.net) orelse continue;
        const up_d = domain(file, upper) orelse continue;
        const lo_d = domain(file, u.lower) orelse continue;
        if (up_d == lo_d or up_d == .unspecified or lo_d == .unspecified) continue;
        // A statement that matches, which `plan` could not apply: the net
        // resolved continuous above the level that elaborated this port.
        const rule = find: {
            for (file.connectrules) |cr| for (cr.insertions) |*ins| {
                const r = try ruleOf(self, ins, false) orelse continue;
                if (matches(file, r, u.dir, upper, u.lower)) break :find r;
            };
            break :find null;
        };
        if (rule) |r| {
            try self.err(u.tok, .E0929, "`{s}` matches port `{s}` of `{s}` (`{s}`), but its net `{s}` resolved `{s}` above the level that elaborated the port", .{
                file.str(r.module.name), file.str(u.port), file.str(u.inst), file.str(u.lower), file.str(u.net), file.str(upper),
            });
            continue;
        }
        try unmatched(self, u.tok, u.port, u.inst, u.lower, u.net, upper);
    }
}

/// The first of `rules` that `matches` the port, and how many do: §7.8.4's
/// "one (and only one)" is a count of one.
pub fn matchRules(file: *const Ast.SourceFile, rules: []const Rule, dir: Ast.Direction, upper: Ast.StrId, lower: Ast.StrId) struct { ?usize, usize } {
    var found: ?usize = null;
    var count: usize = 0;
    for (rules, 0..) |r, ri| if (matches(file, r, dir, upper, lower)) {
        count += 1;
        if (found == null) found = ri;
    };
    assert(count <= rules.len);
    if (found != null) assert(count != 0);
    return .{ found, count };
}

pub fn domain(file: *const Ast.SourceFile, d: Ast.StrId) ?Ast.DisciplineDecl.Domain {
    return discipline.domainOf(discipline.declOf(file, d) orelse return null);
}

// ---- private ----

/// Does connect rule `r` bridge a port of direction `dir` whose upper and
/// lower connections have these disciplines? §7.6's three examples, which
/// state the matching in terms of data flow: a d2a (discrete input, continuous
/// output) "can bridge a mixed input port whose upper connection is compatible
/// with discipline ddiscrete and whose lower connection is compatible with
/// electrical, or a mixed output port whose upper connection is compatible
/// with discipline electrical and whose lower connection is compatible with
/// ddiscrete"; an inout/inout bidir "can bridge any mixed port". So the rule's
/// input side faces the port's source: the upper connection of an input port,
/// the lower of an output port. "Compatible" is §3.11.1's.
fn matches(file: *const Ast.SourceFile, r: Rule, dir: Ast.Direction, upper: Ast.StrId, lower: Ast.StrId) bool {
    const compat = struct {
        fn f(fl: *const Ast.SourceFile, a: Ast.StrId, b: Ast.StrId) bool {
            // §3.6.2.4 a net with no discipline that digital behavioral code
            // uses is discrete and binds no nature, which §3.11.1's
            // Natureless Discipline Rule makes compatible with every
            // discrete discipline.
            if (b == .none) return domain(fl, a) == .discrete;
            return discipline.disciplineConflict(fl, a, b) == null and domain(fl, a) == domain(fl, b);
        }
    }.f;
    if (r.cont.dir == .inout and r.disc.dir == .inout) {
        const c, const d = if (domain(file, upper) == .continuous) .{ upper, lower } else .{ lower, upper };
        return compat(file, r.cont.discipline, c) and compat(file, r.disc.discipline, d);
    }
    const in_side, const out_side = if (r.cont.dir == .input and r.disc.dir == .output)
        .{ r.cont, r.disc }
    else if (r.cont.dir == .output and r.disc.dir == .input)
        .{ r.disc, r.cont }
    else
        return false; // not a Table 7-2 combination
    const source, const sink = switch (dir) {
        .input => .{ upper, lower },
        .output => .{ lower, upper },
        // A unidirectional bridge does not cover an inout port, and a port
        // with no direction has no source side to face.
        .inout, .unspecified => return false,
    };
    return compat(file, in_side.discipline, source) and compat(file, out_side.discipline, sink);
}

/// E0927 for a mixed port no connect statement matches.
fn unmatched(self: *Flatten, tok: u32, port: Ast.StrId, inst: Ast.StrId, lower: Ast.StrId, net: Ast.StrId, upper: Ast.StrId) design.Error!void {
    assert(port != .none);
    assert(inst != .none);
    const file = self.ctx.file;
    try self.err(tok, .E0927, "port `{s}` of `{s}` is {s}{s}{s} and its net `{s}` is {s}{s}{s}, and no connect statement bridges them", .{
        file.str(port), file.str(inst), q(lower), discName(file, lower), q(lower), file.str(net), q(upper), discName(file, upper), q(upper),
    });
}

/// A segment's discipline for a message: §3.6.2.4's digital net with none
/// (`segment.Seg.behavioral`) is named by what it is.
fn discName(file: *const Ast.SourceFile, d: Ast.StrId) []const u8 {
    return if (d == .none) "discrete with no discipline (3.6.2.4)" else file.str(d);
}

fn q(d: Ast.StrId) []const u8 {
    return if (d == .none) "" else "`";
}

test connIndex {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file: Ast.SourceFile = .empty;
    const pa = try file.intern(a, "a");
    const pb = try file.intern(a, "b");
    const pc = try file.intern(a, "c");
    const ext = try file.intern(a, "ext");
    const port_a: Ast.Port = .{ .name = pa };
    const port_b: Ast.Port = .{ .name = pb };
    const port_c: Ast.Port = .{ .name = pc };
    // §6.2.2 an ordered list binds by position; a short one leaves the rest
    // unbound, and an empty one binds nothing.
    const ordered: Ast.Instance = .{ .module = pa, .name = pa, .ports = &.{ .{}, .{} } };
    try std.testing.expectEqual(@as(?usize, 0), connIndex(&ordered, port_a, 0));
    try std.testing.expectEqual(@as(?usize, 1), connIndex(&ordered, port_b, 1));
    try std.testing.expectEqual(@as(?usize, null), connIndex(&ordered, port_c, 2));
    const empty: Ast.Instance = .{ .module = pa, .name = pa };
    try std.testing.expectEqual(@as(?usize, null), connIndex(&empty, port_a, 0));
    // A named list binds by name, the first of a repeated one (the second
    // is `checkConnectionShape`'s E0906), whatever the declaration order.
    const named: Ast.Instance = .{ .module = pa, .name = pa, .ports = &.{ .{ .name = pb }, .{ .name = pa }, .{ .name = pa } } };
    try std.testing.expectEqual(@as(?usize, 1), connIndex(&named, port_a, 0));
    try std.testing.expectEqual(@as(?usize, 0), connIndex(&named, port_b, 1));
    try std.testing.expectEqual(@as(?usize, null), connIndex(&named, port_c, 2));
    // A.1.3 a `.ext(c)` port connects by its external name, not its net's.
    const port_ext: Ast.Port = .{ .name = pc, .external_name = ext };
    const by_ext: Ast.Instance = .{ .module = pa, .name = pa, .ports = &.{.{ .name = ext }} };
    try std.testing.expectEqual(@as(?usize, 0), connIndex(&by_ext, port_ext, 0));
    try std.testing.expectEqual(@as(?usize, null), connIndex(&by_ext, port_c, 0));
}

test matches {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\discipline ca; domain continuous; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\module top; endmodule
    );
    const file = &f.file;
    const ca = fixture.id(file, "ca").?;
    const dd = fixture.id(file, "dd").?;
    const m = &file.modules[0];
    const ins: Ast.ConnectInsertion = .{ .module = m.name };
    // §7.6 Example 2's a2d: continuous input, discrete output. Port names
    // are not what `matches` reads.
    const a2d: Rule = .{
        .ins = &ins,
        .module = m,
        .cont = .{ .port = m.name, .discipline = ca, .dir = .input },
        .disc = .{ .port = m.name, .discipline = dd, .dir = .output },
    };
    // It "can bridge a mixed input port whose upper connection is compatible
    // with electrical and whose lower connection is compatible with
    // ddiscrete": the input faces the port's source, its upper connection.
    try std.testing.expect(matches(file, a2d, .input, ca, dd));
    // An output port's source is its lower connection, so the same
    // disciplines the other way round match, and these do not.
    try std.testing.expect(matches(file, a2d, .output, dd, ca));
    try std.testing.expect(!matches(file, a2d, .output, ca, dd));
    // A unidirectional bridge covers no inout and no undirected port.
    try std.testing.expect(!matches(file, a2d, .inout, ca, dd));
    try std.testing.expect(!matches(file, a2d, .unspecified, ca, dd));
    // §3.6.2.4 a behavioral net with no discipline is discrete and natureless,
    // compatible with every discrete discipline (§3.11.1).
    try std.testing.expect(matches(file, a2d, .input, ca, .none));
    // An inout/inout bridge "can bridge any mixed port", either way round.
    var bidir = a2d;
    bidir.cont.dir = .inout;
    bidir.disc.dir = .inout;
    try std.testing.expect(matches(file, bidir, .input, ca, dd));
    try std.testing.expect(matches(file, bidir, .output, dd, ca));
    try std.testing.expect(matches(file, bidir, .inout, dd, ca));
    // A direction pair outside Table 7-2 bridges nothing.
    var bad = a2d;
    bad.disc.dir = .input;
    try std.testing.expect(!matches(file, bad, .input, ca, dd));
}

test "§7.6 Table 7-2: a connect module whose port directions name no scenario is E0982" {
    const src =
        \\discipline ca; domain continuous; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\connectmodule bridge(a, d); input a; {s} d; ca a; dd d; endmodule
        \\module top(p); inout p; ca p; endmodule
        \\connectrules r; connect bridge; endconnectrules
    ;
    var bad: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer bad.deinit();
    try fixture.parse(&bad, try bad.arena.allocator().print(src, .{"input"}));
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(bad.ctx()));
    try std.testing.expect(fixture.hasCode(&bad.bag, .E0982));

    // input/output is the first of the table's three pairs.
    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good, try good.arena.allocator().print(src, .{"output"}));
    _ = try elaborate.elaborate(good.ctx());
}
