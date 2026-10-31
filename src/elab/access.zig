//! Access functions across a port join: a child's access on a bound port →
//! judged against the child's own declaration (§4.4, §6.5.2.1) and
//! respelled for the parent's net, plus §6.3.6's automatic $mfactor scaling
//! of flow contributions, flow probes and noise.
//! Cites: LRM §3.6.1.2, §3.11.1, §4.4, §5.5.1, §6.3.6, §6.5.2.1, §7.4.
//!
//! Contents:
//! - `pub fn localAccess(self: *Flatten, access: Ast.StrId, net: Ast.ExprId, flat_net: Ast.ExprId, tok: u32) design.Error!LocalAccess`
//! - `pub fn checkTypedPort(self: *Flatten, access: Ast.StrId, net: Ast.ExprId, tok: u32) design.Error!void`
//! - `pub fn mfactorScale(...)`
//! - `pub fn mfactorNoise(self: *Flatten, call: Ast.ExprId) design.Error!Ast.ExprId`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const lookup = @import("lookup.zig");
const discipline = @import("discipline_rules.zig");
const fixture = @import("fixture.zig");

/// `localAccess`'s answer: the spelling, and whether only the child's
/// declaration can judge it.
const LocalAccess = struct { name: Ast.StrId, local_only: bool = false };

/// §4.4: "The access function name shall match the discipline declaration
/// for the nets, ports, or branch given in the argument expression list." In a
/// child, that declaration is the child's own: §7.4 resolves disciplines only
/// for nets "whose discipline is undeclared", and §6.5.8 lets one node carry
/// several continuous disciplines. So an access on a bound port is judged
/// against the port's local discipline (`Unit.port_disc`), E0501 here since
/// after the join lowering sees only the parent's net, and then respelled as
/// the same half of the net it was joined to, the rewrite `primitiveAccess`
/// makes for Table E.1's V and I. `net` is the terminal as the child wrote it,
/// `flat_net` the same terminal cloned.
///
/// When the joined net's discipline binds no nature for that half (§3.11.1's
/// natureless or domainless parent, compatible with the child's), there is no
/// spelling to respell to: the access keeps the child's name and is recorded
/// `local_only`, so lowering does not judge it again against the net
/// (`Design.local_accesses`).
///
/// ponytail: the respelling uses the net's discipline as known at the join;
/// a §7.7.2 `resolveto` re-decided after the walk (`resolveMultiCandidates`)
/// is not seen, the same ceiling `primitiveAccess` and `mfactorScale` have.
pub fn localAccess(self: *Flatten, access: Ast.StrId, net: Ast.ExprId, flat_net: Ast.ExprId, tok: u32) design.Error!LocalAccess {
    const file = self.ctx.file;
    const keep: LocalAccess = .{ .name = access };
    const local = self.unit.port_disc.get(lookup.netRefName(self, net) orelse return keep) orelse return keep;
    const disc = self.res.disc_of.get(lookup.netRefName(self, flat_net) orelse return keep) orelse return keep;
    if (disc == local) return keep;
    // §5.5.1 the generic spellings name a half on every discipline.
    const a = file.str(access);
    if (std.mem.eql(u8, a, "potential") or std.mem.eql(u8, a, "flow")) return keep;
    const half: Ast.PotentialOrFlow = if (discipline.accessOf(file, local, .potential) == access)
        .potential
    else if (discipline.accessOf(file, local, .flow) == access)
        .flow
    else {
        try self.err(tok, .E0501, "`{s}` is not an access function of `{s}`, which this module declares `{s}`", .{
            a, file.str(file.exprs.strOf(net)), file.str(local),
        });
        return keep;
    };
    const name = discipline.accessOf(file, disc, half) orelse return .{ .name = access, .local_only = true };
    return .{ .name = name };
}

/// §6.5.2.1 "If the type of a port is not declared, the port can only be
/// used in a structural description. (It can be passed to instances of
/// modules, but cannot be accessed in a behavioral description.)" Reports
/// E0337 when `net`, a terminal of the access `access` as the child wrote
/// it, is a BOUND port of this unit with no local discipline (#74). After
/// the join lowering sees only the parent's net, which discipline
/// resolution (§7.4) may have given a discipline, so the child's own
/// declaration is judged here. An unconnected port is an internal net with
/// its own (missing) discipline, which lowering's `checkAccessMatch`
/// reports; Table E.1 primitives are `primitiveAccess`'s, not this.
///
/// ponytail: a plain identifier only; a vector port element (`c[0]`) or a
/// named branch over the port is still judged by the joined net.
pub fn checkTypedPort(self: *Flatten, access: Ast.StrId, net: Ast.ExprId, tok: u32) design.Error!void {
    assert(!self.unit.primitive);
    const name = lookup.netRefName(self, net) orelse return;
    if (!(self.unit.connected.get(name) orelse return)) return;
    if (self.unit.port_disc.contains(name)) return;
    const file = self.ctx.file;
    try self.err(tok, .E0337, "`{s}` is a port of `{s}` with no discipline, so `{s}` names nothing on it (§6.5.2.1: an untyped port is structural only); declare one, e.g. `electrical {s};`", .{
        file.str(name), if (self.unit.module) |m| file.str(m.name) else self.unit.path, file.str(access), file.str(name),
    });
}

/// Returns `value` multiplied or divided (`op`) by the unit's running
/// `$mfactor` product when `access` is the flow access of `net`'s discipline,
/// else null (§6.3.6's two automatic scaling rules).
///
///     "All contributions to a branch flow quantity in the analog block
///      shall be multiplied by $mfactor. The value returned by any branch
///      flow probe in the analog block ... shall be divided by $mfactor."
///
/// A flattened child's $mfactor copies exist only in its own equations, so
/// the scaling is source arithmetic. The top's $mfactor stays with the host
/// (Table 9-29's 1.0; `unit.hier.get(.mfactor)` is `.none` there and nothing fires).
///
/// A §3.12 named branch (`I(br)`, `I(br[k])`) answers through its first
/// terminal's discipline (`accessNet`). Rules 3 and 4 (noise power) are
/// `mfactorNoise`'s.
pub fn mfactorScale(
    self: *Flatten,
    value: Ast.ExprId,
    access: Ast.StrId,
    net: Ast.ExprId,
    op: Ast.BinaryOp,
    tok: u32,
) design.Error!?Ast.ExprId {
    if (self.unit.hier.get(.mfactor) == .none) return null;
    const name = lookup.netRefName(self, accessNet(self, net)) orelse return null;
    const disc = self.res.disc_of.get(name) orelse return null;
    const flow = discipline.accessOf(self.ctx.file, disc, .flow) orelse return null;
    if (flow != access) return null; // a potential
    return try self.ctx.file.exprs.add(self.ctx.arena, .{
        .tag = .binary,
        .main_tok = tok,
        .lhs = value,
        .rhs = self.unit.hier.get(.mfactor),
        .extra = @backingInt(op),
    });
}

/// Returns noise call `call` scaled for §6.3.6's rules 3 and 4: "Contributions
/// to a branch flow quantity using the noise functions (white_noise,
/// flicker_noise, noise_table) shall have the noise power multiplied by
/// $mfactor", and a potential's "divided by $mfactor". A noise function's
/// value is an amplitude, so the call becomes `call / $mfactor ** 0.5`: on a
/// flow, rule 1's factor (`mfactorScale`) makes the amplitude sqrt(m) and the
/// power m; a potential, which rule 1 leaves alone, gets power 1/m. §4.6.3's
/// `ac_stim` is a stimulus, not noise, and keeps rule 1 alone. The top's
/// $mfactor stays with the host, as in `mfactorScale`.
pub fn mfactorNoise(self: *Flatten, call: Ast.ExprId) design.Error!Ast.ExprId {
    const m = self.unit.hier.get(.mfactor);
    if (m == .none) return call;
    const x = &self.ctx.file.exprs;
    if (std.mem.eql(u8, self.ctx.file.str(x.strOf(call)), "ac_stim")) return call;
    const tok = x.mainTok(call);
    const arena = self.ctx.arena;
    const root = try x.add(arena, .{ .tag = .binary, .main_tok = tok, .lhs = m, .rhs = try x.addReal(arena, tok, 0.5), .extra = @backingInt(Ast.BinaryOp.pow) });
    return x.add(arena, .{ .tag = .binary, .main_tok = tok, .lhs = call, .rhs = root, .extra = @backingInt(Ast.BinaryOp.div) });
}

// ---- private ----

/// The net whose discipline answers for an access to `net` (flat names): `net`
/// itself, or the first terminal of the §3.12 named branch `net` names (an
/// element of a branch array included). A unit's branches are appended to
/// `branches` before its analog blocks are cloned (`instance.zig`).
///
/// ponytail: a linear scan per flow access of a scaled instance; a flat name
/// → branch map if a design with many branches makes it show.
fn accessNet(self: *Flatten, net: Ast.ExprId) Ast.ExprId {
    const x = &self.ctx.file.exprs;
    var base = net;
    if (base != .none and x.tag(base) == .index) base = x.lhs(base);
    if (base == .none or x.tag(base) != .ident) return net;
    for (self.decls.branches.items) |b| if (b.name == x.strOf(base)) return b.hi;
    return net;
}

test checkTypedPort {
    // §6.5.2.1: an untyped port "can be passed to instances of modules, but
    // cannot be accessed in a behavioral description" (#74). The top's net is
    // `ca`, so the joined node has a discipline; the child's port does not.
    const src =
        \\nature nv; units = "V"; access = V; abstol = 1u; endnature
        \\nature ni; units = "A"; access = I; abstol = 1p; endnature
        \\discipline ca; potential nv; flow ni; enddiscipline
        \\module top(p); inout p; ca p; mid u(p); endmodule
        \\module mid(c); inout c; {s} endmodule
        \\module leaf(c); inout c; ca c; analog I(c) <+ V(c); endmodule
    ;
    const cases = [_]struct { mid: []const u8, bad: bool }{
        // Probed and contributed with no local discipline: E0337, as at the top.
        .{ .mid = "analog I(c) <+ V(c);", .bad = true },
        // The second terminal of an access is the same port.
        .{ .mid = "ca q; analog I(q, c) <+ V(q);", .bad = true },
        // Legal neighbours: the child declares the discipline, or passes the
        // port only to an instance (structural, §3.6.2.4; §7.4 resolves it).
        .{ .mid = "ca c; analog I(c) <+ V(c);", .bad = false },
        .{ .mid = "leaf l(c);", .bad = false },
    };
    for (cases) |c| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(src, .{c.mid}));
        if (c.bad) {
            try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
            try std.testing.expect(fixture.hasCode(&f.bag, .E0337));
        } else {
            _ = try elaborate.elaborate(f.ctx());
            try std.testing.expect(!fixture.hasCode(&f.bag, .E0337));
        }
    }
}
