//! Annex F.2 over the unflattened hierarchy: one net segment (an instance
//! path and a local net name) → the discipline and domain resolution gives
//! it, before flattening joins a signal's segments into one node.
//! `insert.plan` reads both connections of a port from here.
//! Cites: LRM §3.6.2.4, §6.4, §6.6, §7.4.4, §7.4.4.1, §7.4.4.2, §7.4.4.3,
//! §7.7.2, §7.8.1, §7.8.4, Annex F.2.1 steps 3 and 4, F.2.2 steps 4 and 5;
//! IEEE 1364-2005 §12.1.2.
//!
//! Contents:
//! - `pub const Seg = struct`
//! - `pub const PortOn = struct`
//! - `pub const UnitIndex = struct`
//! - `pub fn up(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, net: Ast.StrId, depth: u32) design.Error!Seg`
//! - `pub fn down(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, net: Ast.StrId, parent: Seg) design.Error!Seg`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const walk = @import("walk.zig");
const flat_name = @import("flat_name.zig");
const lookup = @import("lookup.zig");
const ooc = @import("ooc.zig");
const resolve = @import("resolve.zig");
const insert = @import("insert.zig");
const connect_rule = @import("connect_rule.zig");
const discipline = @import("discipline_rules.zig");
const sep = design.sep;

/// `Flatten.seg`: `up`'s memos for the level `insert.plan` is planning
/// (cleared per level), and `down`'s answers, which outlive the level.
pub const State = struct {
    /// `up`'s answers, keyed by instance path and local net name.
    up: std.StringHashMapUnmanaged(Seg) = .empty,
    /// `indexOf`'s answers for the same level, keyed by instance path.
    index: std.StringHashMapUnmanaged(UnitIndex) = .empty,
    /// The modules `up` is below right now, outermost first: a source
    /// instance list that instantiates one of them again is a cycle the walk
    /// refuses (E0905), so the climb stops there.
    on: std.ArrayList(Ast.StrId) = .empty,
    /// The answer each port's lower connection resolved to when its parent
    /// was planned (`down`), the same keys: the upper connection of the ports
    /// one level further down.
    down: std.StringHashMapUnmanaged(Seg) = .empty,
};

/// One segment's answer. `domain == .unspecified` is F.2.2 step 4's
/// "unknown": nothing below the segment declares a domain.
pub const Seg = struct {
    disc: Ast.StrId = .none,
    domain: Ast.DisciplineDecl.Domain = .unspecified,
    /// Steps 2 and 3 decided it (an in-context or out-of-context
    /// declaration), so steps 4 and 5 leave it alone.
    declared: bool = false,
    /// Steps 4.a and 5.a: "Any net which is used in digital behavioral code
    /// shall be considered digital", whatever its children or parent are.
    behavioral: bool = false,
};

/// One child port a net of a level connects to: the child as the walk
/// elaborated it, and the port's local name.
pub const PortOn = struct { kid: walk.TreeKid, port: Ast.StrId };

/// `indexOf`'s answer for the unit at one path.
pub const UnitIndex = struct {
    /// Each net the module declares with a discipline → that discipline: a
    /// port's, else (no port of that name has one) a net declaration's.
    declared: std.AutoHashMapUnmanaged(Ast.StrId, Ast.StrId) = .empty,
    /// Each net → the child ports on it.
    ports: std.AutoHashMapUnmanaged(Ast.StrId, std.ArrayList(PortOn)) = .empty,
};

/// F.2.1 step 4 and F.2.2 step 4, the depth-first pass, which the two modes
/// share: a declared segment is its declaration; otherwise the segment is
/// continuous if any child segment is ("continuous (analog) has precedence
/// over discrete (digital)"), discrete if any is, and unknown when none says.
/// 4.b then picks among the children's disciplines of that domain: one is
/// the answer, several are a §7.7.2 `resolveto` (`resolve.levelCandidates`).
/// A child of unknown domain says nothing, so an undeclared port with
/// nothing below it does not make its parent analog. A segment the module's
/// digital behavioral code uses is digital whatever is below it (4.a), its
/// discipline the discrete children's, or none (§3.6.2.4).
///
/// Memoized per segment. A module already being climbed (`Flatten.seg_on`)
/// stops a recursive instantiation, which the walk itself reports (E0905);
/// `depth` is 0 at the level being planned.
///
/// The children are the ones the walk that inserts nothing elaborated below
/// `path` (`Flatten.tree`): every generate block's instances whose scheme
/// holds, every element of an instance array, a §6.4 paramset instance as
/// the module it selected, at any depth, with every out-of-context
/// declaration (`resolve.oocDisciplineBelow`). Without that walk (no
/// `connectrules`, so nothing to plan) the source instance list is read, a
/// paramset instance only where `insert.plan` is planning (`depth == 0`). A
/// port this pass could not decide is judged after the walk
/// (`insert.checkUnbridged`, E0929).
pub fn up(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, net: Ast.StrId, depth: u32) design.Error!Seg {
    const file = self.ctx.file;
    if (self.seg.up.getAdapted(flat_name.PathKey{ .path = path, .local = file.str(net) }, flat_name.PathKey.Context{})) |s| return s;
    const answer = try compute(self, module, path, net, depth);
    try self.seg.up.put(self.ctx.arena, try self.ctx.arena.print("{s}{s}", .{ path, file.str(net) }), answer);
    return answer;
}

/// The segment on the lower connection of a port whose upper connection
/// resolved to `parent`. Basic mode (F.2.1) has no second pass: it is `up`.
/// Detail mode adds F.2.2 step 5, "Traverse each signal hierarchically
/// (top-down) when a net is encountered which still has not been assigned a
/// discipline or which has been assigned a digital domain from step 4":
///
///  5.a "Any net whose parent nets are digital shall be considered digital.
///       Any others shall be considered analog."
///  5.b "If the net has not yet been assigned a discipline, examine all the
///       parent nets of that net": the parent's discipline. A segment step 4
///       made digital and 5.a keeps digital keeps step 4's discipline, which
///       is §7.4.4.3 Figure 7-5 Case 2's "Same as basic mode". One step 4
///       made digital and 5.a makes analog has no discipline of its domain,
///       so it takes the parent's (§7.4.4.2 Figure 7-4: "Continuous down:
///       NetA resolves to electrical").
///
/// A parent of unknown domain changes nothing: everything below it is
/// unknown too.
pub fn down(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, net: Ast.StrId, parent: Seg) design.Error!Seg {
    const s = try up(self, module, path, net, 0);
    if (self.ctx.discipline_resolution == .basic) return s;
    if (s.declared or s.behavioral or s.domain == .continuous) return s;
    return switch (parent.domain) {
        .continuous => .{ .disc = parent.disc, .domain = .continuous },
        .discrete => if (s.domain == .discrete) s else .{ .disc = parent.disc, .domain = .discrete },
        .unspecified => s,
    };
}

// ---- private ----

fn compute(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, net: Ast.StrId, depth: u32) design.Error!Seg {
    const file = self.ctx.file;
    // ponytail: a narrow unit (under 16 ports, nets and children) is scanned
    // per net: building its table cost more than the scans on a 2^10-leaf
    // binary tree (callgrind). The table is for the wide ones, where the
    // per-net scan was quadratic.
    const kid_count = if (self.tree.kids.get(path)) |k| k.items.len else module.instances.len;
    const index = if (module.ports.len + module.nets.len + kid_count < 16) null else try indexOf(self, module, path, depth);
    const declared = if (index) |ix| ix.declared.get(net) else declaredIn(module, net);
    if (ooc.oocDisciplineBelow(self, path, net) orelse declared) |d|
        return ofDiscipline(file, d, true);
    // §3.6.2.4: "If the net is referenced in behavioral code, then it shall
    // be treated as having no discipline with a domain binding of discrete."
    const behavioral = digitalUse(file, module, net);
    if (std.mem.findScalar(Ast.StrId, self.seg.on.items, module.name) != null)
        return .{ .domain = if (behavioral) .discrete else .unspecified, .behavioral = behavioral };
    const on = self.seg.on.items.len;
    try self.seg.on.append(self.ctx.arena, module.name);
    // Every nested climb pops what it pushed, so this frame's own push is
    // on top when it returns.
    defer {
        assert(self.seg.on.items.len == on + 1);
        _ = self.seg.on.pop();
    }
    var below: std.ArrayList(Seg) = .empty;
    if (index) |ix| {
        if (ix.ports.get(net)) |list| for (list.items) |c| {
            const s = try up(self, c.kid.module, c.kid.path, c.port, depth + 1);
            if (s.domain != .unspecified) try below.append(self.ctx.arena, s);
        };
    } else for (try kidsOf(self, module, path, depth)) |kid| {
        if (kid.module.is_connect) continue;
        for (kid.module.ports, 0..) |p, pi| {
            const ci = connect_rule.connIndex(kid.inst, p, pi) orelse continue;
            if (lookup.netRefName(self, kid.inst.ports[ci].expr) != net) continue;
            const s = try up(self, kid.module, kid.path, p.name, depth + 1);
            if (s.domain != .unspecified) try below.append(self.ctx.arena, s);
        }
    }
    var domain: Ast.DisciplineDecl.Domain = if (behavioral) .discrete else .unspecified;
    if (!behavioral) for (below.items) |s| {
        assert(s.domain != .unspecified); // only known domains are kept above
        if (s.domain == .continuous) domain = .continuous;
        if (s.domain == .discrete and domain == .unspecified) domain = .discrete;
    };
    if (domain == .unspecified) return .{};
    var cands: std.ArrayList(Ast.StrId) = .empty;
    for (below.items) |s| {
        if (s.domain != domain or s.disc == .none) continue;
        if (std.mem.findScalar(Ast.StrId, cands.items, s.disc) == null)
            try cands.append(self.ctx.arena, s.disc);
    }
    return .{ .disc = try resolve.levelCandidates(self, cands.items), .domain = domain, .behavioral = behavioral };
}

fn ofDiscipline(file: *const Ast.SourceFile, d: Ast.StrId, declared: bool) Seg {
    const decl = discipline.declOf(file, d) orelse return .{ .disc = d, .declared = declared };
    return .{ .disc = d, .domain = discipline.domainOf(decl) orelse .unspecified, .declared = declared };
}

/// The declared disciplines and child ports of the unit at `path` (an
/// instance of `module`): children in instance order, ports in declaration
/// order, connect modules skipped (they bridge, so are no segment). Built
/// once per path and level (`Flatten.seg_index`), so `compute` looks its net
/// up instead of scanning the module's declarations and every child per net,
/// which was quadratic in a level's net and instance counts.
fn indexOf(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, depth: u32) design.Error!*const UnitIndex {
    const gop = try self.seg.index.getOrPut(self.ctx.arena, path);
    if (gop.found_existing) return gop.value_ptr;
    gop.value_ptr.* = .{};
    const index = gop.value_ptr;
    const a = self.ctx.arena;
    for (module.ports) |p| if (p.discipline != .none) {
        const d = try index.declared.getOrPut(a, p.name);
        if (!d.found_existing) d.value_ptr.* = p.discipline;
    };
    for (module.nets) |n| if (n.discipline != .none) {
        const d = try index.declared.getOrPut(a, n.name);
        if (!d.found_existing) d.value_ptr.* = n.discipline;
    };
    for (try kidsOf(self, module, path, depth)) |kid| {
        if (kid.module.is_connect) continue;
        for (kid.module.ports, 0..) |p, pi| {
            const ci = connect_rule.connIndex(kid.inst, p, pi) orelse continue;
            const n = lookup.netRefName(self, kid.inst.ports[ci].expr) orelse continue;
            const list = try index.ports.getOrPut(a, n);
            if (!list.found_existing) list.value_ptr.* = .empty;
            try list.value_ptr.append(a, .{ .kid = kid, .port = p.name });
        }
    }
    return index;
}

/// The children of the unit at `path` (an instance of `module`): the ones
/// the walk that inserts nothing elaborated below `path` (`Flatten.tree`),
/// else (no `connectrules`) the source instance list, a paramset instance
/// resolved only at `depth == 0`, where `insert.plan` is planning.
fn kidsOf(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8, depth: u32) design.Error![]const walk.TreeKid {
    if (self.tree.kids.get(path)) |kids| return kids.items;
    var kids: std.ArrayList(walk.TreeKid) = .empty;
    for (module.instances) |*inst| {
        if (inst.range != null) continue;
        const child_path = try self.ctx.arena.print("{s}{s}{c}", .{ path, self.ctx.file.str(inst.name), sep });
        const m = (if (depth == 0)
            try insert.moduleOf(self, inst, child_path)
        else
            lookup.findModule(self, inst.module)) orelse continue;
        try kids.append(self.ctx.arena, .{ .inst = inst, .module = m, .path = child_path });
    }
    return kids.items;
}

/// Is `net` read or written by `module`'s digital behavioral code: a
/// continuous assignment (A.6.1) or an `initial`/`always` block (A.6.2)?
/// Undeclared names reach here only as nets (§3.6.5's implicit nets of a
/// port connection or an assignment target).
fn digitalUse(file: *const Ast.SourceFile, module: *const Ast.ModuleDecl, net: Ast.StrId) bool {
    const Walk = struct {
        file: *const Ast.SourceFile,
        net: Ast.StrId,
        hit: *bool,
        /// Sets `hit` when `e` or an operand below it is the identifier `net`.
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) error{}!void {
            if (e == .none) return;
            const ex = &w.file.exprs;
            if (ex.tag(e) == .ident and ex.strOf(e) == w.net) w.hit.* = true;
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| try w.expr(c, .read);
        }
        /// Visits every expression and child statement of `s`.
        pub fn stmt(w: @This(), s: Ast.StmtId) error{}!void {
            if (s != .none) try w.file.stmtEdges(s, w);
        }
    };
    var hit = false;
    const w: Walk = .{ .file = file, .net = net, .hit = &hit };
    for (module.assigns) |a| {
        w.expr(a.target, .read) catch unreachable;
        w.expr(a.value, .read) catch unreachable;
    }
    for (module.discrete) |d| w.stmt(d.body) catch unreachable;
    return hit;
}

/// The discipline `module` itself declares for `net`, on a port or a net
/// declaration, if any: `UnitIndex.declared`'s answer, by a scan.
fn declaredIn(module: *const Ast.ModuleDecl, net: Ast.StrId) ?Ast.StrId {
    for (module.ports) |p| if (p.name == net and p.discipline != .none) return p.discipline;
    for (module.nets) |n| if (n.name == net and n.discipline != .none) return n.discipline;
    return null;
}

const fixture = @import("fixture.zig");

/// One module per F.2 case, each with the segment `s` under test at path "".
const cases_src =
    \\discipline ca; domain continuous; enddiscipline
    \\discipline dd; domain discrete; enddiscipline
    \\module m_mixed(s); inout s; la x(s); ld y(s); endmodule
    \\module m_dig(s); inout s; ld y(s); endmodule
    \\module m_beh(s); inout s; reg r; initial r = s; la x(s); endmodule
    \\module m_unk(s); inout s; nd z(s); endmodule
    \\module m_decl(s); inout s; ca s; ld y(s); endmodule
    \\module la(p); inout p; ca p; endmodule
    \\module ld(p); inout p; dd p; endmodule
    \\module nd(p); inout p; endmodule
;

/// `up` for `module`'s `s`. Every module of `cases_src` sits at path "",
/// the key `up` memoizes under, so the memo is cleared first, as
/// `insert.plan` clears it per level.
fn upOf(fl: *Flatten, f: *fixture.Fixture, module: []const u8) design.Error!Seg {
    fl.seg.up.clearRetainingCapacity();
    fl.seg.index.clearRetainingCapacity();
    return up(fl, fixture.moduleNamed(&f.file, module).?, "", fixture.id(&f.file, "s").?, 0);
}

/// `down` for `module`'s `s` under an upper connection `parent`.
fn downOf(fl: *Flatten, f: *fixture.Fixture, module: []const u8, parent: Seg) design.Error!Seg {
    fl.seg.up.clearRetainingCapacity();
    fl.seg.index.clearRetainingCapacity();
    return down(fl, fixture.moduleNamed(&f.file, module).?, "", fixture.id(&f.file, "s").?, parent);
}

test up {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, cases_src);
    var fl = try fixture.flatten(&f);
    const ca = fixture.id(&f.file, "ca").?;
    const dd = fixture.id(&f.file, "dd").?;
    // F.2.1 step 4.a, "continuous (analog) has precedence over discrete";
    // 4.b's one continuous candidate is the answer.
    try std.testing.expectEqual(Seg{ .disc = ca, .domain = .continuous }, try upOf(&fl, &f, "m_mixed"));
    // Every child digital: digital, with the child's discipline.
    try std.testing.expectEqual(Seg{ .disc = dd, .domain = .discrete }, try upOf(&fl, &f, "m_dig"));
    // 4.a and §3.6.2.4: behavioral use makes the segment digital whatever is
    // below it, and with no digital child there is no discipline to take.
    try std.testing.expectEqual(Seg{ .domain = .discrete, .behavioral = true }, try upOf(&fl, &f, "m_beh"));
    // F.2.2 step 4's "unknown": nothing below declares a domain.
    try std.testing.expectEqual(Seg{}, try upOf(&fl, &f, "m_unk"));
    // Steps 2 and 3: a declaration decides, and says so.
    try std.testing.expectEqual(Seg{ .disc = ca, .domain = .continuous, .declared = true }, try upOf(&fl, &f, "m_decl"));
}

test "detail_resolution_bottom_up_all_digital" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, cases_src);
    try std.testing.expectEqual(@as(u32, 0), f.bag.err_count);
    var fl = try fixture.flatten(&f);
    fl.ctx.discipline_resolution = .detail;

    // F.2.2:7 is a step-4 result. A later analog parent could overwrite it,
    // so a final-voltage assertion cannot establish this intermediate state.
    // m_dig.s has no declaration or behavioral use and its only child is
    // explicitly digital. Compare the all-unknown child control too.
    const digital = Seg{ .disc = fixture.id(&f.file, "dd").?, .domain = .discrete };
    try std.testing.expectEqual(digital, try upOf(&fl, &f, "m_dig"));
    try std.testing.expectEqual(digital, fl.seg.up.get("s").?);
    try std.testing.expectEqual(@as(usize, 0), fl.seg.down.count());
    try std.testing.expectEqual(Seg{}, try upOf(&fl, &f, "m_unk"));
    try std.testing.expectEqual(@as(u32, 0), f.bag.err_count);
}

test down {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, cases_src);
    var fl = try fixture.flatten(&f);
    const ca = fixture.id(&f.file, "ca").?;
    const dd = fixture.id(&f.file, "dd").?;
    const cont: Seg = .{ .disc = ca, .domain = .continuous };
    const dig: Seg = .{ .disc = dd, .domain = .discrete };
    // Basic mode (F.2.1) has no top-down pass: `down` is `up`.
    try std.testing.expectEqual(dig, try downOf(&fl, &f, "m_dig", cont));

    fl.ctx.discipline_resolution = .detail;
    // F.2.2 5.a/5.b: a segment step 4 made digital under an analog parent is
    // analog, with the parent's discipline (§7.4.4.2 Figure 7-4).
    try std.testing.expectEqual(cont, try downOf(&fl, &f, "m_dig", cont));
    // Under a digital parent it keeps step 4's answer (Figure 7-5 Case 2).
    try std.testing.expectEqual(dig, try downOf(&fl, &f, "m_dig", dig));
    // An unknown segment takes a known parent's domain and discipline.
    try std.testing.expectEqual(dig, try downOf(&fl, &f, "m_unk", dig));
    try std.testing.expectEqual(cont, try downOf(&fl, &f, "m_unk", cont));
    // Declared, behavioral and continuous segments are left alone, and so is
    // everything under an unknown parent.
    try std.testing.expectEqual(Seg{ .disc = ca, .domain = .continuous, .declared = true }, try downOf(&fl, &f, "m_decl", dig));
    try std.testing.expectEqual(Seg{ .domain = .discrete, .behavioral = true }, try downOf(&fl, &f, "m_beh", cont));
    try std.testing.expectEqual(cont, try downOf(&fl, &f, "m_mixed", dig));
    try std.testing.expectEqual(dig, try downOf(&fl, &f, "m_dig", .{}));
}

test indexOf {
    // N mixed nets at one level, each joining an analog and a digital child:
    // every net resolves continuous and gets one bridge, and the level's
    // level is indexed once (one `seg_index` row; its childless children
    // are scanned), not scanned per net.
    const n = 64;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(std.testing.allocator);
    try text.appendSlice(std.testing.allocator,
        \\discipline ca; domain continuous; enddiscipline
        \\discipline dd; domain discrete; enddiscipline
        \\connectmodule a2d(el, cm); input el; output cm; ca el; dd cm; endmodule
        \\connectrules r; connect a2d; endconnectrules
        \\module din(d); input d; dd d; endmodule
        \\module la(a); inout a; ca a; endmodule
        \\module top(p); inout p; ca p;
        \\
    );
    for (0..n) |i| try text.print(std.testing.allocator, "wire w{d}; din d{d}(w{d}); la a{d}(w{d});\n", .{ i, i, i, i, i });
    try text.appendSlice(std.testing.allocator, "endmodule\n");
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, text.items);
    var fl = try fixture.flatten(&f);
    const top = fixture.moduleNamed(&f.file, "top").?;
    const all = try insert.plan(&fl, top, "", top.instances, &.{});
    try std.testing.expectEqual(@as(usize, 2 * n + n), all.len);
    try std.testing.expectEqual(@as(usize, n), fl.out.inserts.items.len);
    try std.testing.expectEqual(@as(u32, 1), fl.seg.index.count());
    try std.testing.expectEqual(@as(usize, 0), f.bag.count());
}

// Exact Annex F.2.2 pass-boundary observations: the bottom-up and top-down
// passes on parsed segments, before flattening can erase their separate
// domains. No final voltage or invented parent state stands in for them.
test "detail_resolution_unknown_after_bottom_up" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parseWithPrelude(&f, @embedFile("resolution_unknown_fixture"));
    try std.testing.expectEqual(@as(u32, 0), f.bag.err_count);
    var fl = try fixture.flatten(&f);
    fl.ctx.discipline_resolution = .detail;

    const parent = fixture.moduleNamed(&f.file, "detail_unknown_parent").?;
    const child = fixture.moduleNamed(&f.file, "detail_unknown_child").?;
    const leaf = fixture.moduleNamed(&f.file, "detail_unknown_leaf").?;
    const p = fixture.id(&f.file, "p").?;
    const signal = fixture.id(&f.file, "signal").?;

    // The real parent's declaration is already continuous. It must not leak
    // into the child before step 5; the whole child subtree says unknown.
    const parent_up = try up(&fl, parent, "", signal, 0);
    try std.testing.expectEqual(Seg{
        .disc = fixture.id(&f.file, "observer_continuous").?,
        .domain = .continuous,
        .declared = true,
    }, parent_up);
    const child_up = try up(&fl, child, "child.", p, 1);
    const leaf_up = try up(&fl, leaf, "child.leaf.", p, 2);
    try std.testing.expectEqual(Seg{}, child_up);
    try std.testing.expectEqual(Seg{}, leaf_up);
    // This is the memoized step-4 result, observed before any down() call.
    try std.testing.expectEqual(Seg{}, fl.seg.up.get("child.p").?);
    try std.testing.expectEqual(Seg{}, fl.seg.up.get("child.leaf.p").?);
    try std.testing.expectEqual(@as(usize, 0), fl.seg.down.count());

    // The later answer deliberately differs, so observing the final domain
    // cannot accidentally satisfy the unknown-after-bottom-up assertion.
    const child_down = try down(&fl, child, "child.", p, parent_up);
    try std.testing.expectEqual(Seg{
        .disc = parent_up.disc,
        .domain = .continuous,
    }, child_down);
    try std.testing.expectEqual(Seg{}, fl.seg.up.get("child.p").?);
    try std.testing.expectEqual(@as(u32, 0), f.bag.err_count);
}

test "detail_resolution_digital_parent" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parseWithPrelude(&f, @embedFile("resolution_digital_parent_fixture"));
    try std.testing.expectEqual(@as(u32, 0), f.bag.err_count);
    var fl = try fixture.flatten(&f);
    fl.ctx.discipline_resolution = .detail;

    const child = fixture.moduleNamed(&f.file, "detail_inherited_child").?;
    const leaf = fixture.moduleNamed(&f.file, "detail_inherited_leaf").?;
    const p = fixture.id(&f.file, "p").?;
    const signal = fixture.id(&f.file, "signal").?;
    const digital = fixture.id(&f.file, "observer_discrete").?;
    const analog = fixture.id(&f.file, "observer_continuous").?;
    const cases = [_]struct { parent: []const u8, want: Seg }{
        .{ .parent = "detail_digital_parent", .want = .{ .disc = digital, .domain = .discrete } },
        .{ .parent = "detail_analog_parent_control", .want = .{ .disc = analog, .domain = .continuous } },
        .{ .parent = "detail_unknown_parent_control", .want = .{} },
    };
    for (cases) |case| {
        // Each root instantiates the same modules at the same local paths.
        // Separate memos prevent the preceding root's answer being reused.
        fl.seg.up.clearRetainingCapacity();
        fl.seg.index.clearRetainingCapacity();
        const parent = fixture.moduleNamed(&f.file, case.parent).?;
        const parent_up = try up(&fl, parent, "", signal, 0);
        try std.testing.expectEqual(case.want.domain, parent_up.domain);
        try std.testing.expectEqual(case.want.disc, parent_up.disc);

        // Exact preconditions: neither a declaration, behavioral use nor
        // bottom-up inference has made either descendant digital.
        try std.testing.expectEqual(Seg{}, try up(&fl, child, "child.", p, 1));
        try std.testing.expectEqual(Seg{}, try up(&fl, leaf, "child.leaf.", p, 2));

        // The same input in BASIC mode keeps its bottom-up answer.
        fl.ctx.discipline_resolution = .basic;
        try std.testing.expectEqual(Seg{}, try down(&fl, child, "child.", p, parent_up));
        fl.ctx.discipline_resolution = .detail;

        // Parent-before-child traversal: leaf inherits the child result,
        // not a separately synthesized digital parent.
        const child_down = try down(&fl, child, "child.", p, parent_up);
        try std.testing.expectEqual(case.want, child_down);
        const leaf_down = try down(&fl, leaf, "child.leaf.", p, child_down);
        try std.testing.expectEqual(case.want, leaf_down);
        try std.testing.expectEqual(Seg{}, fl.seg.up.get("child.p").?);
        try std.testing.expectEqual(Seg{}, fl.seg.up.get("child.leaf.p").?);
    }
    try std.testing.expectEqual(@as(u32, 0), f.bag.err_count);
}
