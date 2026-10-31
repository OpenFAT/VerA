//! Annex F.2 discipline resolution across the hierarchy: each port joining a
//! flat net → one discipline per net (first declaration wins, §7.4.4.1's
//! continuous upgrade), every arrival recorded so step 4.b re-decides the
//! multi-candidate nets after the walk (§7.7.2 `resolveto`, E0903, E0917).
//! The only writer of `Flatten.decls.nets`.
//! Cites: LRM §3.10, §3.11, §5.5.3, §7.2.4, §7.4, §7.4.1, §7.4.4.1,
//! §7.4.4.3, §7.7.2, §7.7.2.1, Annex F.2.1.
//!
//! Contents:
//! - `pub fn addNets(self: *Flatten, nets: []const Ast.NetDecl) design.Error!void`
//! - `pub fn addNet(self: *Flatten, n: Ast.NetDecl) design.Error!void`
//! - `pub fn noteDiscipline(self: *Flatten, name: Ast.StrId, disc: Ast.StrId) design.Error!void`
//! - `pub fn resolveDiscipline(self: *Flatten, path: []const u8, p: Ast.Port, bound: Ast.StrId, at: ?u32) design.Error!void`
//! - `pub fn noteSignalDiscipline(self: *Flatten, net: Ast.StrId, disc: Ast.StrId) design.Error!void`
//! - `pub fn resolveMultiCandidates(self: *Flatten) design.Error!void`
//! - `pub fn levelCandidates(self: *Flatten, cands: []const Ast.StrId) design.Error!Ast.StrId`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const ooc = @import("ooc.zig");
const discipline = @import("discipline_rules.zig");
const sep = design.sep;

/// `Flatten.res`: what Annex F.2 resolution knows about every flat net.
pub const State = struct {
    /// The discipline every flat net has been declared with, keyed by the
    /// flat name: §3.10's precedence orders 1 and 2 after they have been
    /// decided. Kept in agreement with `Flatten.decls.nets` by `addNet`. The
    /// top's ports are seeded first (`Flatten.run`), since a discipline
    /// resolved up the hierarchy lands on one of them. One discipline per net,
    /// the answer every consumer reads; F.2.1 step 4.b's full candidate set
    /// is `segs`.
    disc_of: std.AutoHashMapUnmanaged(Ast.StrId, Ast.StrId) = .empty,
    /// Annex F.2.1 step 4.b's input, per flat net: EVERY discipline a child
    /// segment declared onto it, in arrival order, with the token of the
    /// first segment for the diagnostic. Fed by `resolveDiscipline` and
    /// consumed once, after the walk, by `resolveMultiCandidates`. An array
    /// hash map so the post-pass visits nets in first-binding order and a
    /// design with two errors reports them deterministically.
    segs: std.array_hash_map.Auto(Ast.StrId, Segs) = .empty,
    /// The flat nets whose discipline came from a bound port rather than a
    /// declaration: §3.6.5's implicit nets, the set §7.4.4.1's
    /// continuous-wins rule may overrule without overruling a declaration.
    port_resolved: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty,
    /// The `port_resolved` nets whose discipline was overruled after their net
    /// row was added (§7.4.4.1's upgrade, F.2.1 4.b's `resolveto`):
    /// `resolveMultiCandidates` rewrites their rows once, at the end.
    redecided: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty,
    /// E.3.2's LAST source, deferred: every bound port of an analog
    /// primitive, whose own `electrical` is only "the default analog
    /// primitive" and so binds its net after the walk, and only if nothing
    /// else did (E.3.2.2).
    prim_ports: std.ArrayList(PrimPort) = .empty,
    /// Attribute reads of undeclared ports, waiting for bottom-up resolution.
    pending_attributes: std.ArrayList(PendingAttribute) = .empty,
};

/// One `State.segs` row: the disciplines a net's child segments declared,
/// and the token of the first declaration (the diagnostic anchor).
pub const Segs = struct {
    /// `.none` for an undeclared port: see `resolveDiscipline`.
    discs: std.ArrayList(Ast.StrId) = .empty,
    /// Each arrival's instance path, parallel to `discs`.
    paths: std.ArrayList([]const u8) = .empty,
    /// Answers for undeclared segments, keyed by their arrival index.
    resolved: std.AutoHashMapUnmanaged(u32, ?Ast.StrId) = .empty,
    tok: u32,

    comptime {
        // One row per port-bound flat net; three containers and a token. A
        // budget, not an exact size: the hash map carries a safety lock in
        // Debug/ReleaseSafe only.
        assert(@sizeOf(Segs) <= 96);
    }
};

/// One `State.prim_ports` row: a primitive's bound port, at its instance
/// path, and the flat net it joined.
pub const PrimPort = struct { path: []const u8, port: Ast.Port, bound: Ast.StrId };

/// One `State.pending_attributes` row: a §5.5.3 attribute read on an
/// undeclared bound port, the flat net, and the reading unit's path.
pub const PendingAttribute = struct { expr: Ast.ExprId, net: Ast.StrId, path: []const u8 };

/// §7.4.1's levels of one flattened net: its arrivals grouped by the arrival
/// each reached the net through (`levelOf`), built once per net by `levelsOf`
/// so `resolveLevel` visits every arrival once. Level `g < paths.len` holds
/// the arrivals directly below arrival g; level `paths.len` the net's own.
const Levels = struct {
    /// `members[start[g]..start[g + 1]]` is level g, in arrival order.
    start: []const u32,
    /// Every arrival index exactly once.
    members: []const u32,
    /// The path-prefix lookups `levelsOf` made: one per `sep` of a path at
    /// most, plus the empty prefix. The linearity test reads it.
    probes: u32,

    fn of(lv: *const Levels, g: usize) []const u32 {
        return lv.members[lv.start[g]..lv.start[g + 1]];
    }
};

/// Adds `nets` to the flattened module through `addNet`, skipping
/// out-of-context declarations: their content is the discipline they give a
/// segment below (`ooc`), and under a dotted name they would reach lowering
/// as a node nothing connects.
pub fn addNets(self: *Flatten, nets: []const Ast.NetDecl) design.Error!void {
    for (nets) |n| {
        if (ooc.isOoc(self.ctx.file.str(n.name))) continue;
        try addNet(self, n);
    }
}

/// Appends a net to the flattened module and records its discipline. The only
/// way to append to `self.decls.nets`, which keeps `disc_of` complete.
pub fn addNet(self: *Flatten, n: Ast.NetDecl) design.Error!void {
    try self.decls.nets.append(self.ctx.arena, n);
    try noteDiscipline(self, n.name, n.discipline);
}

/// Records a declared discipline for a flat net; the first one wins. See
/// `disc_of` and `resolveDiscipline`.
pub fn noteDiscipline(self: *Flatten, name: Ast.StrId, disc: Ast.StrId) design.Error!void {
    if (disc == .none) return;
    const gop = try self.res.disc_of.getOrPut(self.ctx.arena, name);
    if (!gop.found_existing) gop.value_ptr.* = disc;
}

/// Resolves the discipline of flat net `bound` as port `p` of the instance at
/// `path` joins it (Annex F.2, §7.4). Flattening has already collapsed every
/// segment of a signal into one node, so what is left of F.2's traversal is:
/// a segment that declares a discipline gives it to the signal, and an
/// undeclared parent segment inherits it. The depth-first walk supplies the
/// order.
///
/// During the walk the first declaration wins, plus §7.4.4.1's
/// continuous-over-discrete upgrade. That decides F.2.1 step 4.b wherever at
/// most one matching-domain candidate arrives. Every arrival is also recorded
/// in `segs`, and `resolveMultiCandidates` re-decides the rest after the walk.
///
/// §3.11's Signal Connection Rule is judged here, the last place both
/// segments are visible: "It shall be an error to connect two ports or nets
/// of the same domain with incompatible disciplines" (E0355). A segment of
/// the other domain is §7.4.4's connect-module question.
///
/// ponytail: each arriving segment is compared with the discipline the
/// signal has so far, not with every earlier segment. Compatibility is not
/// transitive (a natureless discipline is compatible with two disciplines
/// that are not compatible with each other), so a third segment can slip
/// past a natureless second. Upgrade: compare against every entry of
/// `segs` for the net.
///
/// `at` is the connection's token, or null for an Annex E primitive: its
/// ports' `electrical` is the prelude's placeholder, and E.3.2 resolves the
/// discipline from the attribute or the connected net instead, so there is
/// no declaration to judge.
pub fn resolveDiscipline(self: *Flatten, path: []const u8, p: Ast.Port, bound: Ast.StrId, at: ?u32) design.Error!void {
    const disc = ooc.oocDiscipline(self, path, p.name) orelse p.discipline;
    try noteSignalDiscipline(self, bound, disc);
    // F.2 step 4.b's input: this port's lower connection is a child segment
    // of `bound` declaring `disc`. Recorded unconditionally; the post-pass
    // decides which nets still have a question (`port_resolved`). An
    // undeclared port is recorded as `.none` with its instance path: the
    // segments reaching `bound` from inside that instance are its level of
    // the hierarchy, resolved there first (§7.4.1 Figure 7-2's NetB).
    {
        const gop = try self.res.segs.getOrPut(self.ctx.arena, bound);
        if (!gop.found_existing) gop.value_ptr.* = .{ .tok = p.main_tok };
        try gop.value_ptr.discs.append(self.ctx.arena, disc);
        // `levelsOf` finds a level's prefix at a `sep` of the path.
        assert(path.len == 0 or path[path.len - 1] == sep);
        try gop.value_ptr.paths.append(self.ctx.arena, path);
        // Parallel columns: `resolveLevel` reads arrival i's path beside its discipline.
        assert(gop.value_ptr.discs.items.len == gop.value_ptr.paths.items.len);
    }
    if (disc == .none) return;
    const declared = self.res.disc_of.get(bound) orelse .none;
    if (declared != .none) {
        const file = self.ctx.file;
        if (at != null and discipline.isContinuous(file, declared) == discipline.isContinuous(file, disc)) {
            if (discipline.disciplineConflict(file, declared, disc)) |why| {
                try self.err(at.?, .E0355, "port `{s}{s}` is of discipline `{s}` and is connected to `{s}`, of discipline `{s}` ({s})", .{
                    path, file.str(p.name), file.str(disc), file.str(bound), file.str(declared), why,
                });
                return;
            }
        }
        // §7.4.4.1 basic mode: "At each level of the hierarchy where
        // continuous and discrete meet for an undeclared net that net segment
        // is declared continuous."
        //
        // Only for a net this function resolved (`port_resolved`). A net the
        // source declared was decided by §3.10's precedence, and upgrading it
        // would overrule a declaration.
        if (!self.res.port_resolved.contains(bound)) return;
        if (discipline.isContinuous(self.ctx.file, declared)) return;
        if (!discipline.isContinuous(self.ctx.file, disc)) return;
        try redecide(self, bound, disc);
        return;
    }
    try self.res.port_resolved.put(self.ctx.arena, bound, {});
    try addNet(self, .{
        .name = bound,
        .discipline = disc,
        // The declaration's token, not the connection's: a wrong discipline
        // is fixed where it was named.
        .main_tok = p.main_tok,
    });
}

/// §7.2.4 keeps a segment's tolerance separate from the single discipline
/// chosen for a flattened net by §7.4. Lowering owns nature-attribute folding.
pub fn noteSignalDiscipline(self: *Flatten, net: Ast.StrId, disc: Ast.StrId) design.Error!void {
    if (disc == .none) return;
    try self.out.signal_disciplines.append(self.ctx.arena, .{
        .net = net,
        .discipline = disc,
    });
}

/// Applies Annex F.2.1 step 4 after the walk to undeclared segments, retaining
/// their local answers for tolerances and nature attributes. The flattened
/// root changes only if its discipline came from a bound port rather than
/// a declaration. `resolveLevel` asks §7.4.1's question bottom-up;
/// `levelAnswer` is 4.a/4.b for one level. Reports E0903 and E0917.
///
/// The other 4.a sentence (a net "used in digital behavioral code" is
/// digital) is `segment.up`'s: it decides the mixed ports, and `insert.plan`
/// bridges them, so the net arrives here with its digital segments only.
pub fn resolveMultiCandidates(self: *Flatten) design.Error!void {
    var it = self.res.segs.iterator();
    while (it.next()) |entry| {
        const net = entry.key_ptr.*;
        const s = entry.value_ptr;
        const undeclared = std.mem.findScalar(Ast.StrId, s.discs.items, .none) != null;
        if (!undeclared and !self.res.port_resolved.contains(net)) continue;
        const lv = try levelsOf(self.ctx.arena, s.paths.items);
        // A declared upper segment does not declare every segment below it
        // (§7.4.4.3 Figure 7-5, Case 2). Their local resolution answers still
        // supply §7.2.4 tolerances and §5.5.3 nature attributes.
        for (s.discs.items, 0..) |disc, i| {
            if (disc == .none) _ = try resolveLevel(self, net, s, &lv, i);
        }
        // A net the source declared was decided by §3.10 precedence
        // (steps 2/3); step 4 is only for undeclared interconnect.
        if (!self.res.port_resolved.contains(net)) continue;
        const r = try resolveLevel(self, net, s, &lv, null) orelse continue;
        if (self.res.disc_of.get(net) == r) continue;
        // Bullet 3: "the net is of the resolved discipline given by the
        // statement", which "need not be one of the disciplines specified
        // in the discipline list" (§7.7.2.1). As §7.4.4.1's upgrade in
        // `resolveDiscipline` is.
        try redecide(self, net, r);
    }
    // Every row of a redecided net takes its final answer, in one pass.
    if (self.res.redecided.count() != 0) for (self.decls.nets.items) |*n| {
        if (self.res.redecided.contains(n.name)) n.discipline = self.res.disc_of.get(n.name).?;
    };
    for (self.res.pending_attributes.items) |a| {
        var local: ?Ast.StrId = null;
        if (self.res.segs.getPtr(a.net)) |s| {
            for (s.paths.items, 0..) |path, i| {
                if (!std.mem.eql(u8, path, a.path)) continue;
                local = s.resolved.get(@intCast(i)) orelse null;
                break;
            }
        }
        if (local orelse self.res.disc_of.get(a.net)) |disc|
            try self.out.attribute_disciplines.put(self.ctx.arena, a.expr, disc);
    }
}

/// Step 4.b's choice among one segment's same-domain candidate
/// disciplines, without the diagnostics `levelAnswer` reports for the
/// flattened net: `.none` for no candidate or a `resolveto exclude`, the
/// one candidate, the `resolveto` result, or the first of an unresolved
/// set. For `segment.up`.
pub fn levelCandidates(self: *Flatten, cands: []const Ast.StrId) design.Error!Ast.StrId {
    if (cands.len <= 1) return if (cands.len == 1) cands[0] else .none;
    const r = try matchResolution(self, cands, false) orelse return cands[0];
    return if (r.exclude) .none else r.resolved;
}

// ---- private ----

/// Overrules port-resolved net `net`'s discipline with `disc`: `disc_of` now,
/// the net's declaration rows once, at the end of `resolveMultiCandidates`
/// (a scan of every row per redecision was quadratic in the net count).
/// Asserts that `net` already has a discipline.
fn redecide(self: *Flatten, net: Ast.StrId, disc: Ast.StrId) design.Error!void {
    assert(self.res.port_resolved.contains(net));
    self.res.disc_of.getPtr(net).?.* = disc;
    try self.res.redecided.put(self.ctx.arena, net, {});
}

/// Builds `Levels` from the arrivals' instance paths. An arrival's level is
/// the first arrival whose path is the longest proper prefix of its own
/// (`levelOf`, the test oracle). Every path ends in `sep` (asserted in
/// `resolveDiscipline`), so such a prefix ends just after a `sep` of the path,
/// or is empty: one hash lookup per `sep`, O(paths × depth), not O(paths²).
fn levelsOf(arena: std.mem.Allocator, paths: []const []const u8) design.Error!Levels {
    const n: u32 = @intCast(paths.len);
    var first: std.StringHashMapUnmanaged(u32) = .empty;
    try first.ensureTotalCapacity(arena, n);
    for (paths, 0..) |p, i| {
        const gop = first.getOrPutAssumeCapacity(p);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
    }
    const level = try arena.alloc(u32, n);
    var probes: u32 = 0;
    for (paths, level) |p, *lvl| {
        lvl.* = n;
        var len = p.len;
        while (len > 0) {
            len = if (std.mem.findScalarLast(u8, p[0 .. len - 1], sep)) |k| k + 1 else 0;
            probes += 1;
            if (first.get(p[0..len])) |j| {
                lvl.* = j;
                break;
            }
        }
    }
    // Counting sort by level, stable, so each level keeps arrival order.
    const start = try arena.alloc(u32, n + 2);
    @memset(start, 0);
    for (level) |g| start[g + 1] += 1;
    for (1..start.len) |g| start[g] += start[g - 1];
    const next = try arena.dupe(u32, start[0 .. n + 1]);
    const members = try arena.alloc(u32, n);
    for (level, 0..) |g, i| {
        members[next[g]] = @intCast(i);
        next[g] += 1;
    }
    assert(start[n + 1] == n);
    return .{ .start = start, .members = members, .probes = probes };
}

/// One level's answer for `net`, over the arrivals directly at that level
/// (`group`'s members, or the net's own level's at null). A declared lower
/// connection is itself (§7.4.4.3: "that discipline shall be used"); an
/// undeclared one is its own level's answer, resolved first, so Figure
/// 7-2's NetA sees "the resulting cmos3 from module twoblks", not twoblks'
/// children. `lv` is `s`'s levels; with the `resolved` memo, one net's
/// resolution visits each arrival once (#75: a scan of every arrival per
/// level, each through `levelOf`, was cubic in the instance count).
fn resolveLevel(self: *Flatten, net: Ast.StrId, s: *Segs, lv: *const Levels, group: ?usize) design.Error!?Ast.StrId {
    // `resolveDiscipline` appends the two columns together.
    assert(s.discs.items.len == s.paths.items.len);
    if (group) |g| assert(g < s.discs.items.len);
    if (group) |g| if (s.resolved.get(@intCast(g))) |cached| return cached;
    // The levels below `group`, on a heap stack, each closed before the one
    // above it: an arrival's level is a strictly shorter path, so the stack
    // holds at most one frame per arrival plus the net's own level.
    const Frame = struct { group: ?usize, members: []const u32, next: usize = 0, discs: std.ArrayList(Ast.StrId) };
    const a = self.ctx.arena;
    var stack: std.ArrayList(Frame) = .empty;
    const first = lv.of(group orelse s.discs.items.len);
    try stack.append(a, .{ .group = group, .members = first, .discs = try .initCapacity(a, first.len) });
    while (true) {
        assert(stack.items.len <= s.discs.items.len + 1);
        const top = &stack.items[stack.items.len - 1];
        if (top.next < top.members.len) {
            const i = top.members[top.next];
            top.next += 1;
            const d = s.discs.items[i];
            if (d != .none) {
                top.discs.appendAssumeCapacity(d);
            } else if (s.resolved.get(i)) |cached| {
                if (cached) |v| top.discs.appendAssumeCapacity(v);
            } else {
                const below = lv.of(i);
                try stack.append(a, .{ .group = i, .members = below, .discs = try .initCapacity(a, below.len) });
            }
            continue;
        }
        const done = stack.pop().?;
        const answer = try levelAnswer(self, net, s.tok, done.discs.items);
        if (done.group) |g| try s.resolved.put(a, @intCast(g), answer);
        if (answer) |disc| try noteSignalDiscipline(self, net, disc);
        if (stack.items.len == 0) {
            assert(done.group == group);
            return answer;
        }
        if (answer) |v| stack.items[stack.items.len - 1].discs.appendAssumeCapacity(v);
    }
}

/// Annex F.2.1 step 4 over one level's candidate disciplines.
///
///  4.a  domain: "Any net whose child nets are all digital shall be
///       considered digital (discrete domain), any others shall be
///       considered analog (continuous domain)." §7.4.4.1's basic mode says
///       the same thing as a precedence ("continuous winning over discrete").
///  4.b  candidates: the distinct disciplines whose domain matches the
///       level's. One → that one. More than one → bullet 3: a §7.7.2
///       resolution statement whose list matches the set resolves it
///       (`resolveto exclude` refuses it instead, E0917); no statement →
///       bullet 4: unknown, "legal provided the net has no mixed-port
///       connections ... Otherwise this is an error" (E0903).
///
/// A legally unknown net keeps its first arrival in the level's domain.
fn levelAnswer(self: *Flatten, net: Ast.StrId, tok: u32, discs: []const Ast.StrId) design.Error!?Ast.StrId {
    var net_continuous = false;
    for (discs) |d| {
        if (discipline.isContinuous(self.ctx.file, d)) net_continuous = true;
    }
    var cands: std.ArrayList(Ast.StrId) = try .initCapacity(self.ctx.arena, discs.len);
    var mixed_port = false;
    for (discs) |d| {
        if (discipline.isContinuous(self.ctx.file, d) != net_continuous) {
            mixed_port = true;
            continue;
        }
        // ponytail: linear membership for short lists; use a set if this scan dominates.
        if (std.mem.findScalar(Ast.StrId, cands.items, d) == null)
            cands.appendAssumeCapacity(d);
    }
    // The level's domain is continuous as soon as one candidate is, so a
    // discrete level has no other-domain arrival.
    if (!net_continuous) assert(!mixed_port);
    if (cands.items.len <= 1) return if (cands.items.len == 1) cands.items[0] else null;

    if (try matchResolution(self, cands.items, true)) |r| {
        if (r.exclude) {
            // §7.7.2: "deemed to be incompatible and an error is indicated
            // if they are found on the same net."
            try self.err(tok, .E0917, "the disciplines of `{s}` match `connect ... resolveto exclude`", .{
                self.ctx.file.str(net),
            });
            return null;
        }
        return r.resolved;
    }
    if (mixed_port) try self.err(
        tok,
        .E0903,
        "`{s}` has candidate disciplines {{`{s}`, `{s}`{s}}} and no matching `resolveto`",
        .{
            self.ctx.file.str(net),
            self.ctx.file.str(cands.items[0]),
            self.ctx.file.str(cands.items[1]),
            if (cands.items.len > 2) ", ..." else "",
        },
    );
    return cands.items[0];
}

/// §7.7.2 the first resolution statement whose discipline list matches
/// `cands` as a set (order-free, duplicate-free on both sides: 4.b's
/// "the contents of the list match"). First match across every
/// `connectrules` block in source order, which is §7.7.2.1's tie-break.
fn matchResolution(self: *Flatten, cands: []const Ast.StrId, report: bool) design.Error!?*const Ast.ConnectResolution {
    // §7.7.2.1: an exact set wins even over an earlier subset match.
    // In the fallback, the candidate set is a subset of the rule's list.
    for ([_]bool{ true, false }) |want_exact| {
        var first: ?*const Ast.ConnectResolution = null;
        for (self.ctx.file.connectrules) |*cr| {
            rule: for (cr.resolutions) |*r| {
                for (cands) |c| {
                    if (std.mem.findScalar(Ast.StrId, r.disciplines, c) == null) continue :rule;
                }
                var exact = true;
                for (r.disciplines) |d| {
                    if (std.mem.findScalar(Ast.StrId, cands, d) == null) exact = false;
                }
                if (exact != want_exact) continue;
                if (first != null) {
                    if (report) try self.ctx.bag.add(.lower, .W0950, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, r.main_tok), "multiple {s} resolution rules apply; using the first", .{
                        if (want_exact) "exact" else "subset",
                    });
                    return first;
                }
                first = r;
            }
        }
        if (first != null) return first;
    }
    return null;
}

/// §7.4.1 "at each level of the hierarchy": the arrival that arrival `i`
/// reached the net through (the one whose instance path is the longest
/// proper prefix of `i`'s), or null for a segment at the net's own level.
/// This recovers the levels a flattened net's single list mixes together.
/// O(paths) per call: the test oracle for `levelsOf`, which production uses.
fn levelOf(paths: []const []const u8, i: usize) ?usize {
    assert(i < paths.len);
    var best: ?usize = null;
    for (paths, 0..) |q, j| {
        if (q.len >= paths[i].len or !std.mem.startsWith(u8, paths[i], q)) continue;
        if (best == null or q.len > paths[best.?].len) best = j;
    }
    return best;
}

const fixture = @import("fixture.zig");

test levelOf {
    // An arrival's level is the arrival whose instance path is its longest
    // PROPER prefix. Every path ends in `sep`, so `u1.` is not below `u.`.
    const paths = [_][]const u8{ "u.", "u.v.", "w.", "u.v.x.", "u1.", "u." };
    try std.testing.expectEqual(@as(?usize, null), levelOf(&paths, 0));
    try std.testing.expectEqual(@as(?usize, 0), levelOf(&paths, 1));
    try std.testing.expectEqual(@as(?usize, null), levelOf(&paths, 2));
    try std.testing.expectEqual(@as(?usize, 1), levelOf(&paths, 3));
    try std.testing.expectEqual(@as(?usize, null), levelOf(&paths, 4));
    // A repeated path is the same level, never its own parent.
    try std.testing.expectEqual(@as(?usize, null), levelOf(&paths, 5));
}

/// Checks every level of `lv` against the `levelOf` oracle: each arrival sits
/// in exactly the level `levelOf` names, and each level is in arrival order.
fn expectLevelsMatchOracle(paths: []const []const u8, lv: *const Levels) !void {
    try std.testing.expectEqual(paths.len, lv.members.len);
    for (0..paths.len + 1) |g| {
        var prev: ?u32 = null;
        for (lv.of(g)) |i| {
            try std.testing.expectEqual(if (g == paths.len) null else @as(?usize, g), levelOf(paths, i));
            if (prev) |p| try std.testing.expect(p < i);
            prev = i;
        }
    }
}

test levelsOf {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = [_][]const u8{ "u.", "u.v.", "w.", "u.v.x.", "u1.", "u.", "u.v.x.y.z.", "" };
    const small = try levelsOf(a, &paths);
    try expectLevelsMatchOracle(&paths, &small);

    // #75: issue 75's shape, N instances `g[i].u.` of a module with an
    // undeclared port, each holding a leaf `g[i].u.l.`, is 2N arrivals on one
    // net. The levels take 3 prefix lookups per instance whatever N is (the
    // old `levelOf` per arrival per level was N^3), so doubling N doubles
    // the work, and each arrival is in one level, so `resolveLevel` visits
    // it once. A count, not a clock.
    var probes: [3]u32 = undefined;
    for ([_]usize{ 256, 512, 1024 }, &probes) |n, *count| {
        const ps = try a.alloc([]const u8, 2 * n);
        for (0..n) |i| {
            ps[2 * i] = try a.print("g[{d}].u.", .{i});
            ps[2 * i + 1] = try a.print("g[{d}].u.l.", .{i});
        }
        const lv = try levelsOf(a, ps);
        try expectLevelsMatchOracle(ps, &lv);
        try std.testing.expectEqual(@as(usize, n), lv.of(ps.len).len);
        count.* = lv.probes;
    }
    try std.testing.expectEqual(@as(u32, 3 * 256), probes[0]);
    try std.testing.expectEqual(2 * probes[0], probes[1]);
    try std.testing.expectEqual(2 * probes[1], probes[2]);
}

test levelCandidates {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\discipline fa; domain continuous; enddiscipline
        \\discipline fb; domain continuous; enddiscipline
        \\discipline fc; domain continuous; enddiscipline
        \\discipline fd; domain continuous; enddiscipline
        \\module top; endmodule
        \\connectrules r; connect fa, fb resolveto fc; connect fa, fd resolveto exclude; endconnectrules
    );
    var fl = try fixture.flatten(&f);
    const fa = fixture.id(&f.file, "fa").?;
    const fb = fixture.id(&f.file, "fb").?;
    const fc = fixture.id(&f.file, "fc").?;
    const fd = fixture.id(&f.file, "fd").?;
    try std.testing.expectEqual(Ast.StrId.none, try levelCandidates(&fl, &.{}));
    try std.testing.expectEqual(fa, try levelCandidates(&fl, &.{fa}));
    // §7.7.2 a statement whose list matches the set, in any order, names the
    // answer, which "need not be one of the disciplines specified" (§7.7.2.1).
    try std.testing.expectEqual(fc, try levelCandidates(&fl, &.{ fb, fa }));
    // `resolveto exclude` resolves nothing.
    try std.testing.expectEqual(Ast.StrId.none, try levelCandidates(&fl, &.{ fd, fa }));
    // No statement matches: the first candidate, quietly (the diagnostics are
    // `levelAnswer`'s, on the flattened net).
    try std.testing.expectEqual(fb, try levelCandidates(&fl, &.{ fb, fd }));
    try std.testing.expectEqual(@as(usize, 0), f.bag.count());
}

test "§7.4.4.1 continuous wins over discrete on a port-resolved net, on every row of it" {
    // `w` is declared with no discipline, so its ports decide it: the
    // discrete `d.x` arrives first and adds a row, the continuous `a.x`
    // overrules it, and both rows (the declaration and the port-resolved
    // one) end continuous once the post-pass has run, either arrival order.
    for ([_]bool{ false, true }) |continuous_first| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f,
            \\discipline ca; domain continuous; enddiscipline
            \\discipline dd; domain discrete; enddiscipline
            \\module top; endmodule
        );
        var fl = try fixture.flatten(&f);
        const a = f.arena.allocator();
        const w = try f.file.intern(a, "w");
        const ca = fixture.id(&f.file, "ca").?;
        const dd = fixture.id(&f.file, "dd").?;
        try addNet(&fl, .{ .name = w });
        const x = try f.file.intern(a, "x");
        const ports = [2]struct { []const u8, Ast.Port }{
            .{ "d.", .{ .name = x, .discipline = dd } },
            .{ "a.", .{ .name = x, .discipline = ca } },
        };
        for (0..2) |k| {
            const pp = ports[if (continuous_first) 1 - k else k];
            try resolveDiscipline(&fl, pp[0], pp[1], w, 0);
        }
        try resolveMultiCandidates(&fl);
        try std.testing.expectEqual(ca, fl.res.disc_of.get(w).?);
        try std.testing.expectEqual(@as(usize, 2), fl.decls.nets.items.len);
        for (fl.decls.nets.items) |n| {
            if (continuous_first and n.discipline == .none) continue; // nothing overruled the declaration
            try std.testing.expectEqual(ca, n.discipline);
        }
        try std.testing.expect(!fl.had_error);
    }
}
