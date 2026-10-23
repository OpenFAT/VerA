//! Annex F.2 discipline resolution across the hierarchy: the flattened nets
//! with their declared and inherited disciplines → one discipline per net, or
//! a diagnostic for an incompatible connection. Also checks `connectrules`
//! names and every net's declared discipline. LRM §3.6.2, §3.10, §3.11, §5.5.3, §7.2.4, §7.4,
//! §7.4.4.1, §7.4.4.3, §7.6, §7.7.1, §7.7.2, §7.7.2.1, §7.7.3, §7.8, Annex F.2.1.

const std = @import("std");
const elab_clone = @import("clone.zig");
const elaborate = @import("elaborate.zig");
const Flatten = elaborate.Flatten;
const elab_names = @import("names.zig");
const elab_insert = @import("insert.zig");
const elab_override = @import("override.zig");
const discipline = @import("discipline_rules.zig");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const Error = elaborate.Error;
const sep = elaborate.sep;
const PathKey = elab_names.PathKey;

// ---- Annex F.2 discipline resolution ----------------------------------

/// Returns whether a declared net name is an out-of-context one. A period can
/// only come from a hierarchical path (see `sep`).
pub fn isOoc(name: []const u8) bool {
    return std.mem.findScalar(u8, name, sep) != null;
}

/// Adds `nets` to the flattened module through `addNet`, skipping
/// out-of-context declarations: their content is the discipline they give a
/// segment below (`ooc`), and under a dotted name they would reach lowering
/// as a node nothing connects.
pub fn addNets(self: *Flatten, nets: []const Ast.NetDecl) Error!void {
    for (nets) |n| {
        if (isOoc(self.ctx.file.str(n.name))) continue;
        try addNet(self, n);
    }
}

/// Appends a net to the flattened module and records its discipline. The only
/// way to append to `self.nets`, which keeps `disc_of` complete.
pub fn addNet(self: *Flatten, n: Ast.NetDecl) Error!void {
    try self.nets.append(self.ctx.arena, n);
    try noteDiscipline(self, n.name, n.discipline);
}

/// Records a declared discipline for a flat net; the first one wins. See
/// `disc_of` and `resolveDiscipline`.
pub fn noteDiscipline(self: *Flatten, name: Ast.StrId, disc: Ast.StrId) Error!void {
    if (disc == .none) return;
    const gop = try self.disc_of.getOrPut(self.ctx.arena, name);
    if (!gop.found_existing) gop.value_ptr.* = disc;
}

/// §3.10 precedence order 1: the out-of-context discipline for one segment,
/// if a declaration named it.
///
/// Consulted at all three places a segment gets its discipline: a bound port
/// (`resolveDiscipline`), an unconnected one, and a child's internal net. The
/// clause's example covers the last: "electrical top.middle.bottom.sig;
/// overrides any discipline which may be declared for sig in the module where
/// sig was declared" (`annex_f_resolution/out_of_context_internal_net.va`).
///
/// ponytail: an out-of-context declaration that matched nothing is not
/// diagnosed as an unmatched `defparam` is (E0907): from here it cannot be
/// told apart from a legal form this pass does not reach. The upgrade is a
/// `used` flag on `ooc`, like `Defparam.used`.
pub fn oocDiscipline(self: *Flatten, path: []const u8, local: Ast.StrId) ?Ast.StrId {
    return oocIn(&self.ooc, self, path, local);
}

/// `oocDiscipline` over every declaration in the design, those in modules
/// below the level being planned included (`Flatten.tree_ooc`), for
/// `segment.up`.
pub fn oocDisciplineBelow(self: *Flatten, path: []const u8, local: Ast.StrId) ?Ast.StrId {
    return oocIn(&self.tree_ooc, self, path, local) orelse oocDiscipline(self, path, local);
}

fn oocIn(map: *const std.StringHashMapUnmanaged(elaborate.OocDecl), self: *Flatten, path: []const u8, local: Ast.StrId) ?Ast.StrId {
    const d = map.getAdapted(PathKey{ .path = path, .local = self.ctx.file.str(local) }, PathKey.Context{}) orelse return null;
    return if (d.disc == .none) null else d.disc;
}

/// §3.6.2: "It shall be an error to hierarchically override the discipline
/// of a net that was explicitly declared unless it is a compatible
/// discipline" (§3.11.1). Judged once per segment of `child`, the module
/// inlined at `path`: each port, and each net that is not a port's second
/// declaration. Reports E0375 at the out-of-context declaration.
///
/// An Annex E primitive's `electrical` is the placeholder E.3.2 resolves
/// past, not a declaration of the net, so its ports are not judged.
pub fn checkOocOverrides(self: *Flatten, child: *const Ast.ModuleDecl, path: []const u8) Error!void {
    if (elab_names.isPrimitive(self, child)) return;
    for (child.ports) |p| try checkOocOverride(self, path, p.name, p.discipline);
    for (child.nets) |n| {
        if (declaresPort(child, n.name)) continue;
        try checkOocOverride(self, path, n.name, n.discipline);
    }
}

fn declaresPort(m: *const Ast.ModuleDecl, name: Ast.StrId) bool {
    for (m.ports) |p| if (p.name == name) return true;
    return false;
}

fn checkOocOverride(self: *Flatten, path: []const u8, local: Ast.StrId, declared: Ast.StrId) Error!void {
    if (declared == .none) return;
    const file = self.ctx.file;
    const o = self.ooc.getAdapted(PathKey{ .path = path, .local = file.str(local) }, PathKey.Context{}) orelse return;
    if (o.disc == .none) return;
    const why = discipline.disciplineConflict(file, declared, o.disc) orelse return;
    try self.err(o.tok, .E0375, "`{s}{s}` is declared `{s}` and cannot be overridden with `{s}` ({s})", .{
        path, file.str(local), file.str(declared), file.str(o.disc), why,
    });
}

/// Annex F.2.1 step 3: records `module`'s out-of-context discipline
/// declarations under its instance prefix `path`, before any child is
/// inlined, since each names a segment below this module. Reports E0902 for
/// a second declaration of one segment: "More than one conflicting
/// out-of-context discipline declaration for the same hierarchical segment
/// of a signal is an error", and §3.10 makes two declarations at one
/// precedence level illegal even when compatible, so this is a duplicate-key
/// test, not a compatibility test.
pub fn collectOoc(self: *Flatten, module: *const Ast.ModuleDecl, path: []const u8) Error!void {
    for (module.nets) |n| {
        if (!isOoc(self.ctx.file.str(n.name))) continue;
        const key = elab_override.rootedPath(self, self.ctx.file.str(n.name)) orelse
            try self.ctx.arena.print("{s}{s}", .{ path, self.ctx.file.str(n.name) });
        if (self.ooc.get(key)) |first| {
            try self.err(n.main_tok, .E0902, "`{s}` already has the out-of-context discipline `{s}`", .{
                key, self.ctx.file.str(first.disc),
            });
            continue;
        }
        try self.ooc.put(self.ctx.arena, key, .{ .disc = n.discipline, .tok = n.main_tok });
        if (n.init != .none) try self.ooc_inits.append(self.ctx.arena, .{
            .key = key,
            .depth = path.len,
            .init = try elab_clone.cloneExpr(self, n.init),
        });
    }
}

/// An out-of-context declaration's initializer: the segment it names
/// (`collectOoc`'s key), how deep its declaring module sits (its path's
/// length), and the initializer in flat names.
pub const OocInit = struct { key: []const u8, depth: usize, init: Ast.ExprId };

/// §3.6.3.2: "If different nets of a node have conflicting initializers, then
/// initializers on hierarchical net declarations win. If there are multiple
/// hierarchical declarations, then the declaration on the highest level
/// wins." A segment's flat net is the port binding's (`names`) or, for an
/// internal net, the key itself (`sep` is the path separator). The first
/// declaration at the shallowest level wins: §3.6.3.2 makes a tie a race,
/// and `collectOoc` order is the walk's.
pub fn applyOocInits(self: *Flatten) Error!void {
    for (self.ooc_inits.items, 0..) |o, i| {
        const flat = self.names.get(o.key) orelse o.key;
        const beaten = for (self.ooc_inits.items, 0..) |q, j| {
            if (j == i) continue;
            if (!std.mem.eql(u8, self.names.get(q.key) orelse q.key, flat)) continue;
            if (q.depth < o.depth or (q.depth == o.depth and j < i)) break true;
        } else false;
        if (beaten) continue;
        const name = try self.ctx.file.intern(self.ctx.arena, flat);
        var found = false;
        for (self.nets.items) |*n| if (n.name == name) {
            n.init = o.init;
            found = true;
        };
        // An undeclared (implicit) net has no declaration to carry it.
        if (!found) try addNet(self, .{ .name = name, .init = o.init, .main_tok = self.ctx.file.exprs.mainTok(o.init) });
    }
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
pub fn resolveDiscipline(self: *Flatten, path: []const u8, p: Ast.Port, bound: Ast.StrId, at: ?u32) Error!void {
    const disc = oocDiscipline(self, path, p.name) orelse p.discipline;
    try noteSignalDiscipline(self, bound, disc);
    // F.2 step 4.b's input: this port's lower connection is a child segment
    // of `bound` declaring `disc`. Recorded unconditionally; the post-pass
    // decides which nets still have a question (`port_resolved`). An
    // undeclared port is recorded as `.none` with its instance path: the
    // segments reaching `bound` from inside that instance are its level of
    // the hierarchy, resolved there first (§7.4.1 Figure 7-2's NetB).
    {
        const gop = try self.segs.getOrPut(self.ctx.arena, bound);
        if (!gop.found_existing) gop.value_ptr.* = .{ .tok = p.main_tok };
        try gop.value_ptr.discs.append(self.ctx.arena, disc);
        // `levelsOf` finds a level's prefix at a `sep` of the path.
        std.debug.assert(path.len == 0 or path[path.len - 1] == sep);
        try gop.value_ptr.paths.append(self.ctx.arena, path);
        // Parallel columns: `resolveLevel` reads arrival i's path beside its discipline.
        std.debug.assert(gop.value_ptr.discs.items.len == gop.value_ptr.paths.items.len);
    }
    if (disc == .none) return;
    const declared = self.disc_of.get(bound) orelse .none;
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
        if (!self.port_resolved.contains(bound)) return;
        if (discipline.isContinuous(self.ctx.file, declared)) return;
        if (!discipline.isContinuous(self.ctx.file, disc)) return;
        try redecide(self, bound, disc);
        return;
    }
    try self.port_resolved.put(self.ctx.arena, bound, {});
    try addNet(self, .{
        .name = bound,
        .discipline = disc,
        // The declaration's token, not the connection's: a wrong discipline
        // is fixed where it was named.
        .main_tok = p.main_tok,
    });
}

/// Overrules port-resolved net `net`'s discipline with `disc`: `disc_of` now,
/// the net's declaration rows once, at the end of `resolveMultiCandidates`
/// (a scan of every row per redecision was quadratic in the net count).
/// Asserts that `net` already has a discipline.
fn redecide(self: *Flatten, net: Ast.StrId, disc: Ast.StrId) Error!void {
    std.debug.assert(self.port_resolved.contains(net));
    self.disc_of.getPtr(net).?.* = disc;
    try self.redecided.put(self.ctx.arena, net, {});
}

/// §7.2.4 keeps a segment's tolerance separate from the single discipline
/// chosen for a flattened net by §7.4. Lowering owns nature-attribute folding.
pub fn noteSignalDiscipline(self: *Flatten, net: Ast.StrId, disc: Ast.StrId) Error!void {
    if (disc == .none) return;
    try self.signal_disciplines.append(self.ctx.arena, .{
        .net = self.ctx.file.str(net),
        .discipline = self.ctx.file.str(disc),
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
pub fn resolveMultiCandidates(self: *Flatten) Error!void {
    var it = self.segs.iterator();
    while (it.next()) |entry| {
        const net = entry.key_ptr.*;
        const s = entry.value_ptr;
        const undeclared = std.mem.findScalar(Ast.StrId, s.discs.items, .none) != null;
        if (!undeclared and !self.port_resolved.contains(net)) continue;
        const lv = try levelsOf(self.ctx.arena, s.paths.items);
        // A declared upper segment does not declare every segment below it
        // (§7.4.4.3 Figure 7-5, Case 2). Their local resolution answers still
        // supply §7.2.4 tolerances and §5.5.3 nature attributes.
        for (s.discs.items, 0..) |disc, i| {
            if (disc == .none) _ = try resolveLevel(self, net, s, &lv, i);
        }
        // A net the source declared was decided by §3.10 precedence
        // (steps 2/3); step 4 is only for undeclared interconnect.
        if (!self.port_resolved.contains(net)) continue;
        const r = try resolveLevel(self, net, s, &lv, null) orelse continue;
        if (self.disc_of.get(net) == r) continue;
        // Bullet 3: "the net is of the resolved discipline given by the
        // statement", which "need not be one of the disciplines specified
        // in the discipline list" (§7.7.2.1). As §7.4.4.1's upgrade in
        // `resolveDiscipline` is.
        try redecide(self, net, r);
    }
    // Every row of a redecided net takes its final answer, in one pass.
    if (self.redecided.count() != 0) for (self.nets.items) |*n| {
        if (self.redecided.contains(n.name)) n.discipline = self.disc_of.get(n.name).?;
    };
    for (self.pending_attributes.items) |a| {
        var local: ?Ast.StrId = null;
        if (self.segs.getPtr(a.net)) |s| {
            for (s.paths.items, 0..) |path, i| {
                if (!std.mem.eql(u8, path, a.path)) continue;
                local = s.resolved.get(@intCast(i)) orelse null;
                break;
            }
        }
        if (local orelse self.disc_of.get(a.net)) |disc|
            try self.attribute_disciplines.put(self.ctx.arena, a.expr, disc);
    }
}

/// §7.4.1 "at each level of the hierarchy": the arrival that arrival `i`
/// reached the net through (the one whose instance path is the longest
/// proper prefix of `i`'s), or null for a segment at the net's own level.
/// This recovers the levels a flattened net's single list mixes together.
/// O(paths) per call: the test oracle for `levelsOf`, which production uses.
fn levelOf(paths: []const []const u8, i: usize) ?usize {
    std.debug.assert(i < paths.len);
    var best: ?usize = null;
    for (paths, 0..) |q, j| {
        if (q.len >= paths[i].len or !std.mem.startsWith(u8, paths[i], q)) continue;
        if (best == null or q.len > paths[best.?].len) best = j;
    }
    return best;
}

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

/// Builds `Levels` from the arrivals' instance paths. An arrival's level is
/// the first arrival whose path is the longest proper prefix of its own
/// (`levelOf`, the test oracle). Every path ends in `sep` (asserted in
/// `resolveDiscipline`), so such a prefix ends just after a `sep` of the path,
/// or is empty: one hash lookup per `sep`, O(paths × depth), not O(paths²).
fn levelsOf(arena: std.mem.Allocator, paths: []const []const u8) Error!Levels {
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
    std.debug.assert(start[n + 1] == n);
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
fn resolveLevel(self: *Flatten, net: Ast.StrId, s: anytype, lv: *const Levels, group: ?usize) Error!?Ast.StrId {
    // `resolveDiscipline` appends the two columns together.
    std.debug.assert(s.discs.items.len == s.paths.items.len);
    if (group) |g| std.debug.assert(g < s.discs.items.len);
    if (group) |g| if (s.resolved.get(@intCast(g))) |cached| return cached;
    const members = lv.of(group orelse s.discs.items.len);
    var discs: std.ArrayList(Ast.StrId) = try .initCapacity(self.ctx.arena, members.len);
    for (members) |i| {
        const d = s.discs.items[i];
        const v = if (d != .none) d else (try resolveLevel(self, net, s, lv, i)) orelse continue;
        discs.appendAssumeCapacity(v);
    }
    const answer = try levelAnswer(self, net, s.tok, discs.items);
    if (group) |g| try s.resolved.put(self.ctx.arena, @intCast(g), answer);
    if (answer) |disc| try noteSignalDiscipline(self, net, disc);
    return answer;
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
fn levelAnswer(self: *Flatten, net: Ast.StrId, tok: u32, discs: []const Ast.StrId) Error!?Ast.StrId {
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
    if (!net_continuous) std.debug.assert(!mixed_port);
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

/// Step 4.b's choice among one segment's same-domain candidate
/// disciplines, without the diagnostics `levelAnswer` reports for the
/// flattened net: `.none` for no candidate or a `resolveto exclude`, the
/// one candidate, the `resolveto` result, or the first of an unresolved
/// set. For `segment.up`.
pub fn levelCandidates(self: *Flatten, cands: []const Ast.StrId) Error!Ast.StrId {
    if (cands.len <= 1) return if (cands.len == 1) cands[0] else .none;
    const r = try matchResolution(self, cands, false) orelse return cands[0];
    return if (r.exclude) .none else r.resolved;
}

/// §7.7.2 the first resolution statement whose discipline list matches
/// `cands` as a set (order-free, duplicate-free on both sides: 4.b's
/// "the contents of the list match"). First match across every
/// `connectrules` block in source order, which is §7.7.2.1's tie-break.
fn matchResolution(self: *Flatten, cands: []const Ast.StrId, report: bool) Error!?*const Ast.ConnectResolution {
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

/// Checks the names every §7.7 `connectrules` statement uses (E0915, E0916,
/// E0923, E0982, E0907), once per compilation. Not the parser's job: A.1.2
/// puts no order on descriptions, so the connect module or discipline may be
/// declared after the block.
pub fn checkConnectRules(self: *Flatten) Error!void {
    for (self.ctx.file.connectrules) |cr| {
        for (cr.insertions) |*ins| {
            // §7.7.1 "connect connectmodule_identifier": the name must be
            // a §7.6 connect module; an ordinary module bridges nothing.
            const m = elab_names.findModule(self, ins.module) orelse {
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
            // statement: insertion (`elab_insert.plan`) reads the same rule
            // quietly and only in a module whose ports reach one.
            if (!m.is_connect) continue;
            if (try elab_insert.ruleOf(self, ins, true)) |r| try elab_insert.checkDirections(self, r);
            _ = try elab_insert.paramsDeclared(self, ins, m, true);
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

// ponytail: nets declared inside a generate block are not visited; add them
// when a fixture declares one with a bad discipline.
/// Checks that every net declaration in every user module names a declared
/// discipline (A.2.1.3, §3.6.2; E0371), once per compilation. Every module,
/// because the common form of this error, `child c1;` (an instance missing
/// its parentheses, parsed as a net of discipline `child`), leaves `child`
/// an uninstantiated module that is never lowered.
pub fn checkNetDisciplines(self: *Flatten) Error!void {
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
        if (elab_names.findModule(self, n.discipline) != null)
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

/// E0371 when `name` resolves only to a prelude annex D.1 discipline the
/// source did not include.
fn hiddenDiscipline(self: *Flatten, name: Ast.StrId, decl_name: Ast.StrId, tok: u32) Error!void {
    if (name == .none) return;
    const file = self.ctx.file;
    const d = discipline.declOf(file, name) orelse return;
    const index = (@intFromPtr(d) - @intFromPtr(file.disciplines.ptr)) / @sizeOf(Ast.DisciplineDecl);
    if (index >= file.hidden_disciplines) return;
    try self.err(tok, .E0371, "`{s}` in the declaration of `{s}` is annex D.1's: add `include \"disciplines.vams\"", .{ file.str(name), file.str(decl_name) });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture = @import("fixture.zig");

test isOoc {
    try std.testing.expect(isOoc("m.l.p"));
    try std.testing.expect(!isOoc("p"));
    try std.testing.expect(!isOoc(""));
}

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

test applyOocInits {
    // §3.6.3.2: "initializers on hierarchical net declarations win. If there
    // are multiple hierarchical declarations, then the declaration on the
    // highest level wins." `u.w` has a local nodeset 1.25 and the top's
    // hierarchical 2.75: 2.75. Node `n` has the top's own 1.25, the top's
    // `m.p = 2.75` (level 0) and mid's `v.q = 1.25` (level `m.`), all one
    // node after the joins: the top's hierarchical 2.75.
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\discipline electrical; domain continuous; enddiscipline
        \\module cub(g); inout g; electrical g; electrical w = 1.25; endmodule
        \\module leaf(q, g); inout q, g; electrical q, g; endmodule
        \\module mid(p, g); inout p, g; electrical p, g; leaf v(p, g); electrical v.q = 1.25; endmodule
        \\module top(g); inout g; electrical g; electrical n = 1.25;
        \\  cub u(g); mid m(n, g);
        \\  electrical u.w = 2.75; electrical m.p = 2.75;
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    const x = &f.file.exprs;
    try std.testing.expectEqual(@as(f64, 2.75), x.realValue(fixture.netNamed(&f.file, d.top, "u.w").?.init));
    try std.testing.expectEqual(@as(f64, 2.75), x.realValue(fixture.netNamed(&f.file, d.top, "n").?.init));
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
        try std.testing.expectEqual(ca, fl.disc_of.get(w).?);
        try std.testing.expectEqual(@as(usize, 2), fl.nets.items.len);
        for (fl.nets.items) |n| {
            if (continuous_first and n.discipline == .none) continue; // nothing overruled the declaration
            try std.testing.expectEqual(ca, n.discipline);
        }
        try std.testing.expect(!fl.had_error);
    }
}
