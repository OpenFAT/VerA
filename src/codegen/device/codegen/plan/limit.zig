//! §4.5.15 `$limit`: lowered calls and the unknowns' names -> `Limits`, the
//! honoured sites in source order, one `Decline` per site not honoured
//! (reported as W0853 by `cg_limit.emit`) and the §9.17.3 seed tree. The
//! questions plan and emitter both ask (`ladderOf`, `limvdsClaimed`,
//! `writable`) are methods here so the two always agree.
//!
//! Contents:
//! - `pub const Error = std.mem.Allocator.Error`
//! - `pub const Limits = struct`
//! - `pub const Alg = enum`
//! - `pub const LimitCall = struct`
//! - `pub const Rung = struct`
//! - `pub const Ladder = struct`
//! - `pub fn plan(g: Input, u_names: []const []const u8) Error!Limits`
//! - `pub fn uName(u_names: []const []const u8, u: u32) []const u8`
//! - members: `Limits.ladderOf`, `Limits.rungOf`, `Limits.limvdsClaimed`, `Limits.writable`,
//!   `Alg.arity`

const std = @import("std");
const Mir = @import("ir").Mir;
const Input = @import("prove").Input;
const plan_topo = @import("topology.zig");
const strArg = @import("prove").strArg;
const assert = std.debug.assert;
const Fixture = @import("prove").Fixture;

/// Every fallible call here fails only on allocation.
pub const Error = std.mem.Allocator.Error;

/// §4.5.15 the `$limit` call sites this device honours, in source order, and
/// one `Decline` per site it does not. `plan/jobs.zig` queues the honoured
/// sites' algorithm arguments into the core.
pub const Limits = struct {
    /// The honoured sites, in source order (reverse postorder of their blocks).
    calls: []LimitCall = &.{},
    /// One per site not honoured, in the order found: first the sites refused
    /// on their own, then the `fetlimds`/`pnjlimds` legs no ladder or rung
    /// completes.
    declined: []Decline = &.{},
    /// `Lowered.num_ports`, what `writable` answers from.
    num_ports: usize = 0,
    /// Any site carries a seed argument, or any site is a `pnjlimds` leg. Then
    /// `seed` is the branch tree `seed_steps` spells; otherwise it is the
    /// per-junction vcrit bias.
    seed_tree: bool = false,
    /// The tree, root first per component, each node after the one it hangs off.
    seed_steps: []SeedStep = &.{},
    /// One per seed or tree edge that is not applied (W0854).
    seed_dropped: []Decline = &.{},

    /// The ladder `calls[i]` (a `fetlimds` site, either leg) belongs to:
    /// exactly two `fetlimds` sites share its first-named node (the gate), one
    /// `limvds` site spans their second-named nodes (the channel), and both
    /// channel nodes are the device's own to correct. Null otherwise. Derived
    /// on demand, so the plan and the emitter cannot disagree about it.
    /// Asserts `calls[i]` is a `fetlimds` site. O(calls).
    pub fn ladderOf(g: Limits, i: usize) ?Ladder {
        const me = g.calls[i];
        assert(me.alg == .fetlimds);
        var partner: usize = undefined;
        var gate_legs: usize = 0;
        for (g.calls, 0..) |lc, j| {
            if (lc.alg != .fetlimds or lc.hi != me.hi) continue;
            gate_legs += 1;
            if (j != i) partner = j;
        }
        if (gate_legs != 2) return null;
        const other = g.calls[partner];
        if (!g.writable(me.lo) or !g.writable(other.lo)) return null;
        for (g.calls, 0..) |lc, k| {
            if (lc.alg != .limvds) continue;
            if (lc.hi == me.lo and lc.lo == other.lo)
                return .{ .gs = @intCast(partner), .gd = @intCast(i), .ds = @intCast(k) };
            if (lc.hi == other.lo and lc.lo == me.lo)
                return .{ .gs = @intCast(i), .gd = @intCast(partner), .ds = @intCast(k) };
        }
        return null;
    }

    /// The bulk rung `calls[i]` (a `pnjlimds` site, either leg) belongs to:
    /// exactly two `pnjlimds` sites share its first-named node (the bulk), and
    /// one `limvds` site spans their second-named nodes (the channel). Null
    /// otherwise, or when any of the three nets is ground. Derived on demand,
    /// for `ladderOf`'s reason. Asserts `calls[i]` is a `pnjlimds` site.
    /// O(calls).
    pub fn rungOf(g: Limits, i: usize) ?Rung {
        const me = g.calls[i];
        assert(me.alg == .pnjlimds);
        var partner: usize = undefined;
        var legs: usize = 0;
        for (g.calls, 0..) |lc, j| {
            if (lc.alg != .pnjlimds or lc.hi != me.hi) continue;
            legs += 1;
            if (j != i) partner = j;
        }
        if (legs != 2 or me.hi == none_u32) return null;
        const other = g.calls[partner];
        if (me.lo == none_u32 or other.lo == none_u32) return null;
        for (g.calls, 0..) |lc, k| {
            if (lc.alg != .limvds) continue;
            if (lc.hi == me.lo and lc.lo == other.lo)
                return .{ .bs = @intCast(partner), .bd = @intCast(i), .ds = @intCast(k) };
            if (lc.hi == other.lo and lc.lo == me.lo)
                return .{ .bs = @intCast(i), .bd = @intCast(partner), .ds = @intCast(k) };
        }
        return null;
    }

    /// Is this `limvds` site the channel rung of some ladder? Then `emitLadder`
    /// owns it and the flat list must not clamp it a second time. O(calls²).
    pub fn limvdsClaimed(g: Limits, k: usize) bool {
        for (g.calls, 0..) |lc, i| {
            if (lc.alg != .fetlimds) continue;
            const lad = g.ladderOf(i) orelse continue;
            if (lad.ds == k) return true;
        }
        return false;
    }

    /// Can the device correct this unknown? Only its own internal nets: the host
    /// masks writes to §6.5 ports, because a limiter moving a driven or shared
    /// node fights the sources and the other devices on it (`contract.zig`'s
    /// note on `limit`).
    pub fn writable(g: Limits, u: u32) bool {
        return u != none_u32 and u >= g.num_ports;
    }
};

/// The three SPICE3 limiters the corpus names, plus VerA's own. Not an
/// LRM taxonomy: §4.5.15 leaves the identifier implementation-defined; the
/// first three are the spellings `devsup.c` established, which is what every
/// `.va` in the corpus writes. An identifier that is not one of these is
/// declined, which §4.5.15 permits ("the simulator may choose to ignore the
/// limiting request").
///
/// `fetlimds` is VerA's own, naming a construct devsup.c has no word for:
/// ngspice's MOS loads (mos1load.c:351-373, same in mos2/3/6/9, vdmos, b3ld)
/// do not fetlim both gate legs. They fetlim the junction that controls the
/// channel in the present mode (`vgs` when the old vds >= 0, `vgd` when it is
/// negative), run limvds, and derive the other leg. A static both-legs ladder
/// clamps the non-controlling frame at a vds = 0 crossing, and Newton
/// two-cycles against the mode-swapped Jacobian. Spell both gate legs
/// `fetlimds` next to a `limvds` on the channel and the three emit as one
/// mode ladder (`emitLadder`); jfet/hfet keep `fetlim`, because their ngspice
/// loads really do clamp both legs.
pub const Alg = enum {
    pnjlim,
    fetlim,
    limvds,
    fetlimds,
    /// OURS too, the bulk rung of the same loads (mos1load.c:376-384, same in
    /// mos2/3/6/9 and b1ld/b2ld/b3ld): pnjlim ONE junction, vbs when the
    /// LIMITED vds >= 0 and vbd otherwise, and derive the other through vds.
    /// Two static pnjlim sites limit both junctions and move the channel the
    /// ladder already set. Spell BOTH bulk legs `pnjlimds` next to a `limvds`
    /// on the channel and they emit as one rung that writes only the bulk
    /// (`emitRung`), port or not: a host that masks ports only loses the clamp,
    /// which §9.17.3 permits.
    pnjlimds,
    /// ngspice's per-model absolute step clamp (`B4SOIlimit`, hisim's
    /// `limit_dx`): |vnew - vold| <= arg. Unlike `pnjlim` it carries no
    /// cold-start seed: B4SOI's MODEINITJCT starts every junction at icVxS
    /// (0), and a vcrit seed parks a floating SOI body in the high-current
    /// basin.
    steplim,

    /// Numeric arguments that follow the algorithm name.
    pub fn arity(a: Alg) usize {
        return switch (a) {
            .pnjlim, .pnjlimds => 2,
            .fetlim, .fetlimds => 1,
            .limvds => 0,
            .steplim => 1,
        };
    }
};

/// One resolved `$limit` call site.
pub const LimitCall = struct {
    alg: Alg,
    /// Unknowns the probe spans, `V(hi, lo)`. `none_u32` is §1.3.1.1 global
    /// ground, which is not an unknown and reads as a hard 0.
    hi: u32,
    lo: u32,
    /// The call's token, for a decline that is only decided after resolution.
    tok: u32 = 0,
    /// The algorithm's numeric arguments as MIR values. `plan/jobs.zig`
    /// queues these as core jobs, so by emission time each has an `lo_idx`
    /// field.
    argv: [max_args]Mir.Value = .{ .f_zero, .f_zero },
    /// Optional argument after `sign`: the value this site's branch starts at
    /// in `seed` (SPICE MODEINITJCT), in the frame of `sign`; `.undef` when
    /// absent. §9.17.3 leaves the algorithm's arguments to the implementation.
    seed: Mir.Value = .undef,
    /// Optional trailing argument: the frame sign. All three devsup.c
    /// limiters assume forward = positive; a PNP/PMOS model whose junction is
    /// forward at negative probe voltage passes its `type` parameter here and
    /// the clamp runs on `sign*v`, as ngspice limits `type*vbe` in the load
    /// routine. `.f_zero` = unsigned (+1).
    ///
    /// The alternative spellings do not survive lowering: `$limit` under
    /// `if (type > 0)` is declined (no CFG in the clamp list), and
    /// `$limit(type*V(a,b), ...)` is refused in lowering (E0891).
    sign: Mir.Value = .f_zero,
};
// -------------------------------------------------------------------- plan

/// A resolved bulk rung: indices into `calls` of the vbs leg, the vbd leg,
/// and the `limvds` site whose probe orients them, as `Ladder` does.
pub const Rung = struct { bs: u32, bd: u32, ds: u32 };

/// A resolved mode ladder: indices into `calls` of the vgs leg, the vgd leg,
/// and the `limvds` site whose probe orients them. `limvds` reads V(di,si),
/// so the leg landing on its `lo` is the source leg (vgs) and the one landing
/// on its `hi` is the drain leg (vgd).
pub const Ladder = struct { gs: u32, gd: u32, ds: u32 };

const none_u32 = std.math.maxInt(u32);

const max_args = 2;

/// The `Alg` spellings, comma-separated, for the unknown-name warning.
const alg_names = blk: {
    var s: []const u8 = "";
    for (@typeInfo(Alg).@"enum".field_names, 0..) |n, i| s = s ++ (if (i == 0) "" else ", ") ++ n;
    break :blk s;
};

/// A `$limit` site this device does not honour: its probe is returned
/// unchanged, which §9.17.3 permits. `tok` is the call's token.
const Decline = struct {
    tok: u32,
    /// The call as written and why it is declined.
    msg: []const u8,
    /// The model-side change that would get the site honoured, if one exists.
    help: ?[]const u8 = null,
};

/// One node of the seed tree: `s[node] = s[from] ± raw(site)`, the
/// sign picked by which end of `site`'s branch `node` is. `from` is ground
/// (0 V) when `none_u32`; `site == none_u32` is a component root, set to 0.
const SeedStep = struct { node: u32, from: u32, site: u32 };

const Site = struct {
    g: Input,
    u_names: []const []const u8,
    list: *std.ArrayList(Decline),
    tok: u32,
    args: []const Mir.Value,

    fn decline(s: Site, why: []const u8, help: ?[]const u8) Error!void {
        try s.list.append(s.g.arena, .{
            .tok = s.tok,
            .msg = try s.g.arena.print("{s}: {s}", .{ spell(s.g, s.u_names, s.args), why }),
            .help = help,
        });
    }
};

/// Resolves every `$limit` call into honoured sites, declines (W0853) and the
/// seed tree; slices are owned by `g.arena`. Runs in `prepare` before
/// `plan/jobs.zig`, which queues each honoured site's `argv` into the core.
pub fn plan(g: Input, u_names: []const []const u8) Error!Limits {
    var lim: Limits = .{ .num_ports = g.lowered.num_ports };
    var out: std.ArrayList(LimitCall) = .empty;
    var declined: std.ArrayList(Decline) = .empty;
    // A block that dominates the exit is on every path to it, so a call there
    // runs unconditionally. `limit` has no CFG of its own (it is a flat list
    // of clamps), so a call under an `if` cannot be honoured: its guard is
    // bias-dependent and would have to be re-evaluated at the unlimited x.
    //
    // The exit is the block with no successors, not `rpo[last]`: with a loop
    // upstream, DFS may visit the loop's after-block before its body, so
    // reverse postorder can end on the body.
    const exit = blk: {
        for (g.an.rpo) |bi| {
            if (g.an.succs[bi].len == 0) break :blk bi;
        }
        break :blk g.an.rpo[g.an.rpo.len - 1];
    };
    for (g.an.rpo) |bi| {
        for (g.an.blockInstsFlat(bi)) |inst| {
            if (g.mir.instOp(inst) != .call) continue;
            const d = g.mir.instData(inst).call;
            if (d.callee != .@"$limit") continue;

            const tok = g.mir.instTok(inst);
            const at: Site = .{ .g = g, .u_names = u_names, .list = &declined, .tok = tok, .args = d.args };
            // §9.17.3 an unknown string, or none, leaves the algorithm to the
            // simulator "just as if no string had been supplied"; VerA's choice
            // is no limiting.
            const alg = algOf(g, d.args) orelse {
                try at.decline(if (d.args.len < 2)
                    "names no algorithm, and VerA's own choice is no limiting"
                else
                    "names no algorithm VerA implements, so VerA applies none", "name one of " ++ alg_names);
                continue;
            };
            const pair = probePair(g, d.args) orelse {
                try at.decline("its first argument is not a §4.4 potential probe of one or two nets", "limit the potential `V(a,b)` the flow depends on: the host corrects node voltages");
                continue;
            };
            if (!g.an.dominates(bi, exit)) {
                try at.decline("it is under an `if`, and the clamp list carries no control flow", "move the call out of the `if`; a polarity guard such as `if (type > 0)` is the trailing sign argument: `$limit(V(a,b), \"pnjlim\", vte, vcrit, type)`");
                continue;
            }
            if (alg != .pnjlimds and !lim.writable(pair[0]) and !lim.writable(pair[1])) {
                try at.decline("both nets are §6.5 ports, which the host masks — there is nothing private to correct", "limit across an internal node, such as the one behind a series resistance");
                continue;
            }
            const n = alg.arity();
            if (d.args.len < 2 + n or d.args.len > 4 + n) {
                try at.decline(if (d.args.len < 2 + n) "too few arguments for the algorithm named" else "too many arguments for the algorithm named", try g.arena.print("`{t}` takes {d} argument(s) after its name, then an optional sign, then an optional seed", .{ alg, n }));
                continue;
            }
            var lc: LimitCall = .{ .alg = alg, .hi = pair[0], .lo = pair[1], .tok = tok };
            var bad = false;
            for (0..n) |k| {
                const v = g.an.rv(d.args[2 + k]);
                // The clamp is arithmetic on volts. An integer argument would
                // land in the core as an `i64` field, and reading `.v` off it
                // would not compile, so it is refused here where the reason
                // can be stated.
                if (v != .f_zero and g.an.vty[@backingInt(v)] != .real) bad = true;
                lc.argv[k] = v;
            }
            // One argument past the algorithm's arity is the frame sign.
            // Integer is fine here: the emitted uses are comparisons
            // (`< 0.0`), never arithmetic, and `parameter integer type` is
            // the standard polarity spelling (bjt.va).
            if (d.args.len > 2 + n) {
                const v = g.an.rv(d.args[2 + n]);
                if (v != .f_zero and g.an.vty[@backingInt(v)] == .str) bad = true;
                lc.sign = v;
            }
            // And one past the sign is the seed, arithmetic like `argv`.
            if (d.args.len > 3 + n) {
                const v = g.an.rv(d.args[3 + n]);
                if (v != .f_zero and g.an.vty[@backingInt(v)] != .real) bad = true;
                lc.seed = v;
            }
            if (bad) {
                try at.decline("an algorithm argument is not real-valued", null);
                continue;
            }
            try out.append(g.arena, lc);
        }
    }
    lim.calls = out.items;

    // A `fetlimds` site is honoured only as a member of a complete mode
    // ladder (dangling, it would clamp one leg with no frame authority, the
    // static-order bug the algorithm exists to fix), and a `pnjlimds` site
    // only as a member of a complete bulk rung. The mask is computed over the
    // unfiltered list first: validity is symmetric (both legs check both
    // `lo`s, a share of more than two fails every member), so dropping the
    // invalid sites never invalidates a surviving one.
    var any_dangling = false;
    for (lim.calls, 0..) |_, i| {
        if (dangling(lim, i) != null) any_dangling = true;
    }
    if (any_dangling) {
        const keep = try g.arena.alloc(bool, lim.calls.len);
        for (lim.calls, 0..) |lc, i| {
            const why = dangling(lim, i);
            keep[i] = why == null;
            if (why) |w| try declined.append(g.arena, .{
                .tok = lc.tok,
                .msg = try g.arena.print("$limit(V({s},{s}), \"{t}\"): {s}", .{ uName(u_names, lc.hi), uName(u_names, lc.lo), lc.alg, w[0] }),
                .help = w[1],
            });
        }
        var w_: usize = 0;
        for (out.items, 0..) |lc, i| {
            if (!keep[i]) continue;
            out.items[w_] = lc;
            w_ += 1;
        }
        lim.calls = out.items[0..w_];
    }
    lim.declined = declined.items;
    try planSeed(g, u_names, &lim);
    return lim;
}

/// Returns the name of unknown `u`, or "0" for §1.3.1.1 ground.
pub fn uName(u_names: []const []const u8, u: u32) []const u8 {
    return if (u == none_u32) "0" else u_names[u];
}

// ---- private ----

/// `$limit`'s seed argument and SPICE `MODEINITJCT` (mos1load.c:397-408):
/// ngspice starts a device at BRANCH values, vgs = vto, vds = 0, vbs = -1,
/// and the limited image a host keeps is NODE values. So the branches are the
/// edges of a graph over their nets: the sites carrying a seed, and the
/// pnjlim/pnjlimds legs at their default vcrit. A fetlimds vgd leg and a
/// pnjlimds vbd leg are derived through vds and are never edges. Two sites on
/// one net pair are one edge, an explicit seed beating a default; a second
/// explicit seed, or an edge closing a cycle, is dropped (W0854). Each
/// component's root is ground if it holds it, else its lowest port, else its
/// lowest net, at 0 V; every other node follows its edge from the root.
fn planSeed(g: Input, u_names: []const []const u8, lim: *Limits) Error!void {
    for (lim.calls) |lc| lim.seed_tree = lim.seed_tree or lc.seed != .undef or lc.alg == .pnjlimds;
    if (!lim.seed_tree) return;
    var dropped: std.ArrayList(Decline) = .empty;
    var edges: std.ArrayList(u32) = .empty;
    for (lim.calls, 0..) |lc, i| {
        const derived = switch (lc.alg) {
            .fetlimds => lim.ladderOf(i).?.gd == i,
            .pnjlimds => lim.rungOf(i).?.bd == i,
            .pnjlim, .fetlim, .limvds, .steplim => false,
        };
        const explicit = lc.seed != .undef;
        if (derived) {
            if (explicit) try dropped.append(g.arena, .{
                .tok = lc.tok,
                .msg = try g.arena.print("V({s},{s}) is derived through vds, so it is not seeded on its own", .{ uName(u_names, lc.hi), uName(u_names, lc.lo) }),
                .help = "seed the leg on the channel's source side instead",
            });
            continue;
        }
        const default = (lc.alg == .pnjlim or lc.alg == .pnjlimds) and lc.argv[1] != .f_zero;
        if (!explicit and !default) continue;
        const k = for (edges.items, 0..) |e, k| {
            const o = lim.calls[e];
            if ((o.hi == lc.hi and o.lo == lc.lo) or (o.hi == lc.lo and o.lo == lc.hi)) break k;
        } else {
            try edges.append(g.arena, @intCast(i));
            continue;
        };
        if (!explicit) continue; // a default never displaces what is there
        if (lim.calls[edges.items[k]].seed == .undef) {
            edges.items[k] = @intCast(i);
            continue;
        }
        try dropped.append(g.arena, .{
            .tok = lc.tok,
            .msg = try g.arena.print("V({s},{s}) is already seeded by an earlier site", .{ uName(u_names, lc.hi), uName(u_names, lc.lo) }),
        });
    }

    // Union-find over the unknowns plus ground (`n`), keeping the edges
    // that join two components.
    const n = u_names.len;
    const up = try g.arena.alloc(u32, n + 1);
    for (up, 0..) |*p, i| p.* = @intCast(i);
    const find = struct {
        fn f(parent: []u32, x0: u32) u32 {
            var x = x0;
            while (parent[x] != x) x = parent[x];
            return x;
        }
    }.f;
    const node = struct {
        fn f(u: u32, gnd: usize) u32 {
            return if (u == none_u32) @intCast(gnd) else u;
        }
    }.f;
    var tree: std.ArrayList(u32) = .empty;
    for (edges.items) |e| {
        const lc = lim.calls[e];
        const a = find(up, node(lc.hi, n));
        const b = find(up, node(lc.lo, n));
        if (a == b) {
            try dropped.append(g.arena, .{
                .tok = lc.tok,
                .msg = try g.arena.print("V({s},{s}) closes a loop of seeded branches", .{ uName(u_names, lc.hi), uName(u_names, lc.lo) }),
                .help = "the other branches of the loop already fix it; drop this seed or one of theirs",
            });
            continue;
        }
        up[a] = b;
        try tree.append(g.arena, e);
    }

    // Roots, then every node in the order it becomes reachable.
    var steps: std.ArrayList(SeedStep) = .empty;
    const placed = try g.arena.alloc(bool, n + 1);
    @memset(placed, false);
    for (tree.items) |e0| {
        const lc0 = lim.calls[e0];
        if (placed[node(lc0.hi, n)]) continue;
        // This component's root: ground, else its lowest port, else its lowest net.
        const c = find(up, node(lc0.hi, n));
        var root: u32 = none_u32;
        var u: u32 = 0;
        while (u <= n) : (u += 1) {
            if (find(up, u) != c) continue;
            if (u == n) {
                root = u;
                break;
            }
            if (root == none_u32 or (u < lim.num_ports and root >= lim.num_ports)) root = u;
        }
        // `lc0.hi` itself is in the component, so the scan found a root.
        assert(root != none_u32);
        placed[root] = true;
        if (root != n) try steps.append(g.arena, .{ .node = root, .from = none_u32, .site = none_u32 });
        var grew = true;
        while (grew) {
            grew = false;
            for (tree.items) |e| {
                const lc = lim.calls[e];
                const hi = node(lc.hi, n);
                const lo = node(lc.lo, n);
                if (placed[hi] == placed[lo]) continue;
                const to = if (placed[hi]) lo else hi;
                const from = if (placed[hi]) hi else lo;
                placed[to] = true;
                grew = true;
                try steps.append(g.arena, .{ .node = to, .from = if (from == n) none_u32 else from, .site = e });
            }
        }
    }
    lim.seed_steps = steps.items;
    lim.seed_dropped = dropped.items;
}

/// Why `lim.calls[i]` cannot be honoured on its own, and the help line; null
/// when it can.
fn dangling(lim: Limits, i: usize) ?[2][]const u8 {
    return switch (lim.calls[i].alg) {
        .fetlimds => if (lim.ladderOf(i) == null) .{
            "no complete mode ladder",
            "write a second fetlimds site on the same gate node and a limvds site across the two channel nodes, both channel nodes internal",
        } else null,
        .pnjlimds => if (lim.rungOf(i) == null) .{
            "no complete bulk rung",
            "write a second pnjlimds site on the same bulk node and a limvds site across the two channel nodes",
        } else null,
        .pnjlim, .fetlim, .limvds, .steplim => null,
    };
}

/// `$limit(V(a,b), "alg")` as it reads in the source, for the declined list.
fn spell(g: Input, u_names: []const []const u8, args: []const Mir.Value) []const u8 {
    const alg = strArg(g, args, 1) orelse "?";
    const pair = probePair(g, args) orelse
        return g.arena.print("$limit(…, \"{s}\")", .{alg}) catch "$limit(…)";
    return g.arena.print("$limit(V({s},{s}), \"{s}\")", .{ uName(u_names, pair[0]), uName(u_names, pair[1]), alg }) catch "$limit(…)";
}

/// §4.4 `V(a,b)` lowers to `fsub` of two probes and `V(a)` to a bare probe.
/// Anything else (a flow probe, an expression) has no node pair to correct.
fn probePair(g: Input, args: []const Mir.Value) ?[2]u32 {
    if (args.len == 0) return null;
    const v = g.an.rv(args[0]);
    const pair: [2]u32 = switch (g.mir.valueDef(v)) {
        .block_param => |u| .{ u, none_u32 },
        .inst_result => |inst| blk: {
            if (g.mir.instOp(inst) != .fsub) return null;
            const d = g.mir.instData(inst).binary;
            const a = g.mir.valueDef(g.an.rv(d.lhs));
            const b = g.mir.valueDef(g.an.rv(d.rhs));
            if (a != .block_param or b != .block_param) return null;
            break :blk .{ a.block_param, b.block_param };
        },
        .undef, .float_const, .int_const, .str_const, .param_ref => return null,
    };
    // §5.4.2 a branch-flow unknown is an ampere. These limiters are voltage
    // clamps; writing one back as if it were a potential is nonsense.
    for (pair) |u| {
        if (u != none_u32 and plan_topo.isFlowUnknown(g, u)) return null;
    }
    return pair;
}

fn algOf(g: Input, args: []const Mir.Value) ?Alg {
    // §4.5.15 bare `$limit(V(a,b))` asks for the simulator's own choice of
    // algorithm. Ours is none: inventing a clamp the model did not name would
    // change its answers with no way to say so in the source.
    // §9.17.3 also allows a user analog function here. That is a call, not a
    // string, and it needs the whole body, so lowering handles it
    // (`Lower.lowerLimitUser`) and it never reaches the clamp list.
    return std.meta.stringToEnum(Alg, strArg(g, args, 1) orelse return null);
}

test "an honoured pnjlim, and the declines that say why" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "p", "a", "b" }); // one port, two internal nets
    defer f.deinit();
    f.lowered.num_ports = 1;
    const a = f.alloc();
    const va = try f.probe(1);
    const vb = try f.probe(2);
    const vab = try f.mir.emit(a, .entry, .fsub, &.{ va, vb });
    const pnj = try f.mir.addStrConst(a, "pnjlim");
    const vt = try f.mir.addFloatConst(a, 0.025);
    const vcrit = try f.mir.addFloatConst(a, 0.6);
    // $limit(V(a,b), "pnjlim", vt, vcrit): honoured, both nets internal.
    _ = try f.call("$limit", &.{ vab, pnj, vt, vcrit });
    // $limit(V(p), "pnjlim", vt, vcrit): the only net is a port.
    _ = try f.call("$limit", &.{ try f.probe(0), pnj, vt, vcrit });
    // $limit(V(a,b), "pnjlim", vt): too few arguments.
    _ = try f.call("$limit", &.{ vab, pnj, vt });
    const an = try f.analysis();

    const lim = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{ "p", "a", "b" });
    try std.testing.expectEqual(@as(usize, 1), lim.calls.len);
    try std.testing.expectEqual(Alg.pnjlim, lim.calls[0].alg);
    try std.testing.expectEqual(@as(u32, 1), lim.calls[0].hi);
    try std.testing.expectEqual(@as(u32, 2), lim.calls[0].lo);
    try std.testing.expect(lim.writable(2) and !lim.writable(0));
    try std.testing.expectEqual(@as(usize, 2), lim.declined.len);
    try std.testing.expect(std.mem.find(u8, lim.declined[0].msg, "§6.5 ports") != null);
    try std.testing.expect(std.mem.find(u8, lim.declined[1].msg, "too few arguments") != null);
}

test "the seed tree: an explicit seed opts in, a loop edge is dropped, ground roots its component" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "p", "a", "b", "c" });
    defer f.deinit();
    f.lowered.num_ports = 1;
    const a = f.alloc();
    const pnj = try f.mir.addStrConst(a, "pnjlim");
    const vt = try f.mir.addFloatConst(a, 0.025);
    const vc = try f.mir.addFloatConst(a, 0.6);
    const pa = try f.probe(1);
    const pb = try f.probe(2);
    const pc = try f.probe(3);
    const one = try f.mir.addFloatConst(a, 1.0);
    const seed = try f.mir.addFloatConst(a, 0.1);
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ pa, pb }), pnj, vt, vc, one, seed });
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ pb, pc }), pnj, vt, vc });
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ pa, pc }), pnj, vt, vc }); // closes a-b-c
    _ = try f.call("$limit", &.{ pc, pnj, vt, vc }); // V(c): c against ground
    const an = try f.analysis();

    const lim = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{ "p", "a", "b", "c" });
    try std.testing.expect(lim.seed_tree);
    try std.testing.expectEqual(@as(usize, 1), lim.seed_dropped.len);
    try std.testing.expect(std.mem.find(u8, lim.seed_dropped[0].msg, "closes a loop") != null);
    // Ground is the root and writes nothing; c hangs off it, b off c, a off b.
    const want = [_]SeedStep{
        .{ .node = 3, .from = none_u32, .site = 3 },
        .{ .node = 2, .from = 3, .site = 1 },
        .{ .node = 1, .from = 2, .site = 0 },
    };
    try std.testing.expectEqualSlices(SeedStep, &want, lim.seed_steps);
}

test "each refusal names its reason: no algorithm, an unknown one, a flow probe, a guard, an arity, a non-real argument" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "a", "b", "flow(a,b)" });
    defer f.deinit();
    const a = f.alloc();
    f.lowered.nodes.items(.kind)[2] = .{ .branch_flow = 0 };
    const vab = try f.mir.emit(a, .entry, .fsub, &.{ try f.probe(0), try f.probe(1) });
    const pnj = try f.mir.addStrConst(a, "pnjlim");
    const vt = try f.mir.addFloatConst(a, 0.025);
    const vc = try f.mir.addFloatConst(a, 0.6);
    // 0: $limit(V(a,b)) — §4.5.15 leaves the choice to VerA, which picks none.
    _ = try f.call("$limit", &.{vab});
    // 1: an identifier VerA does not implement.
    _ = try f.call("$limit", &.{ vab, try f.mir.addStrConst(a, "foolim") });
    // 2: §5.4.2 I(a,b) is a current, not a potential to clamp.
    _ = try f.call("$limit", &.{ try f.probe(2), pnj, vt, vc });
    // 3: pnjlim takes vte, vcrit, sign, seed: seven arguments is too many.
    _ = try f.call("$limit", &.{ vab, pnj, vt, vc, .f_one, .f_zero, .f_one });
    // 4: an integer vte would land in the core as an i64.
    _ = try f.call("$limit", &.{ vab, pnj, try f.mir.addIntConst(a, 3), vc });
    // 5: a string sign.
    _ = try f.call("$limit", &.{ vab, pnj, vt, vc, try f.mir.addStrConst(a, "n") });
    // 6: under an `if`: entry branches on V(a,b) > 0 into `then`.
    const then_b = try f.mir.addBlock(a);
    const join = try f.mir.addBlock(a);
    _ = try f.mir.emitBranch(a, .entry, try f.mir.emit(a, .entry, .fgt, &.{ vab, .f_zero }), then_b, join);
    _ = try f.mir.emitCall(a, then_b, try f.mir.internString(a, "$limit"), &.{ vab, pnj, vt, vc });
    _ = try f.mir.emitJump(a, then_b, join);
    const an = try f.analysis();

    const lim = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{ "a", "b", "flow_a_b_" });
    try std.testing.expectEqual(@as(usize, 0), lim.calls.len);
    const want = [_][]const u8{
        "names no algorithm, and VerA's own choice is no limiting",
        "names no algorithm VerA implements",
        "not a §4.4 potential probe",
        "too many arguments",
        "not real-valued",
        "not real-valued",
        "under an `if`",
    };
    try std.testing.expectEqual(want.len, lim.declined.len);
    for (want, lim.declined) |w, d| try std.testing.expect(std.mem.find(u8, d.msg, w) != null);
    // The unknown-name help lists every spelling, in declaration order.
    try std.testing.expectEqualStrings("name one of pnjlim, fetlim, limvds, fetlimds, pnjlimds, steplim", lim.declined[1].help.?);
    // A refused site's call spells its probe pair back.
    try std.testing.expect(std.mem.startsWith(u8, lim.declined[3].msg, "$limit(V(a,b), \"pnjlim\")"));
}

test "a fetlimds mode ladder: both gate legs and the channel, oriented by the limvds probe" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "g", "d", "s" });
    defer f.deinit();
    const a = f.alloc();
    const g = try f.probe(0);
    const d = try f.probe(1);
    const s = try f.probe(2);
    const fet = try f.mir.addStrConst(a, "fetlimds");
    const vto = try f.mir.addFloatConst(a, 0.7);
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ g, s }), fet, vto }); // vgs
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ g, d }), fet, vto }); // vgd
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ d, s }), try f.mir.addStrConst(a, "limvds") });
    const an = try f.analysis();

    const lim = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{ "g", "d", "s" });
    try std.testing.expectEqual(@as(usize, 3), lim.calls.len);
    try std.testing.expectEqual(@as(usize, 0), lim.declined.len);
    // limvds reads V(d,s): the leg landing on its `lo` (s) is the source leg.
    const want: Ladder = .{ .gs = 0, .gd = 1, .ds = 2 };
    try std.testing.expectEqual(want, lim.ladderOf(0).?);
    try std.testing.expectEqual(want, lim.ladderOf(1).?);
    try std.testing.expect(lim.limvdsClaimed(2));
    // No seed and no pnjlimds: the per-junction bias, no tree.
    try std.testing.expect(!lim.seed_tree);
}

test "a dangling fetlimds leg is declined and dropped; a port channel completes no ladder" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "d", "g", "s" }); // d is a port
    defer f.deinit();
    f.lowered.num_ports = 1;
    const a = f.alloc();
    const g = try f.probe(1);
    const d = try f.probe(0);
    const s = try f.probe(2);
    const fet = try f.mir.addStrConst(a, "fetlimds");
    const vto = try f.mir.addFloatConst(a, 0.7);
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ g, s }), fet, vto });
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ g, d }), fet, vto });
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ d, s }), try f.mir.addStrConst(a, "limvds") });
    const an = try f.analysis();

    const lim = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{ "d", "g", "s" });
    // Both legs declined (the drain is a port the host masks); limvds stays,
    // and nothing claims it.
    try std.testing.expectEqual(@as(usize, 1), lim.calls.len);
    try std.testing.expectEqual(Alg.limvds, lim.calls[0].alg);
    try std.testing.expect(!lim.limvdsClaimed(0));
    try std.testing.expectEqual(@as(usize, 2), lim.declined.len);
    for (lim.declined) |dc| try std.testing.expect(std.mem.find(u8, dc.msg, "no complete mode ladder") != null);
}

test "a pnjlimds bulk rung seeds the source-side leg; a seed on the derived leg is dropped" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "d", "g", "s", "b" });
    defer f.deinit();
    const a = f.alloc();
    const d = try f.probe(0);
    const s = try f.probe(2);
    const b = try f.probe(3);
    const pds = try f.mir.addStrConst(a, "pnjlimds");
    const vt = try f.mir.addFloatConst(a, 0.025);
    const vc = try f.mir.addFloatConst(a, 0.6);
    const seed = try f.mir.addFloatConst(a, -1.0);
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ b, s }), pds, vt, vc }); // vbs
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ b, d }), pds, vt, vc, .f_one, seed }); // vbd
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ d, s }), try f.mir.addStrConst(a, "limvds") });
    const an = try f.analysis();

    const lim = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{ "d", "g", "s", "b" });
    try std.testing.expectEqual(@as(usize, 3), lim.calls.len);
    try std.testing.expectEqual(Rung{ .bs = 0, .bd = 1, .ds = 2 }, lim.rungOf(0).?);
    try std.testing.expect(lim.seed_tree);
    try std.testing.expectEqual(@as(usize, 1), lim.seed_dropped.len);
    try std.testing.expect(std.mem.find(u8, lim.seed_dropped[0].msg, "derived through vds") != null);
    // The vbs leg's default vcrit is the one edge: s (the lower net, no port,
    // no ground) is the root, b hangs off it.
    const want = [_]SeedStep{
        .{ .node = 2, .from = none_u32, .site = none_u32 },
        .{ .node = 3, .from = 2, .site = 0 },
    };
    try std.testing.expectEqualSlices(SeedStep, &want, lim.seed_steps);
}

test "on one net pair an explicit seed displaces a default one, and a second explicit seed is dropped" {
    var f: Fixture = .{ .arena = .init(std.testing.allocator) };
    try f.init(&.{ "p", "a", "b" });
    defer f.deinit();
    f.lowered.num_ports = 1;
    const a = f.alloc();
    const pa = try f.probe(1);
    const pb = try f.probe(2);
    const pnj = try f.mir.addStrConst(a, "pnjlim");
    const vt = try f.mir.addFloatConst(a, 0.025);
    const vc = try f.mir.addFloatConst(a, 0.6);
    const s1 = try f.mir.addFloatConst(a, 0.1);
    const s2 = try f.mir.addFloatConst(a, 0.2);
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ pa, pb }), pnj, vt, vc }); // default
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ pa, pb }), pnj, vt, vc, .f_one, s1 }); // explicit
    _ = try f.call("$limit", &.{ try f.mir.emit(a, .entry, .fsub, &.{ pb, pa }), pnj, vt, vc, .f_one, s2 }); // reversed pair, explicit
    const an = try f.analysis();

    const lim = try plan(.{ .arena = a, .mir = &f.mir, .an = &an, .lowered = &f.lowered }, &.{ "p", "a", "b" });
    try std.testing.expectEqual(@as(usize, 3), lim.calls.len);
    try std.testing.expectEqual(@as(usize, 1), lim.seed_dropped.len);
    try std.testing.expect(std.mem.find(u8, lim.seed_dropped[0].msg, "already seeded") != null);
    // Site 1 is the edge; a is the lowest net of {a, b}.
    const want = [_]SeedStep{
        .{ .node = 1, .from = none_u32, .site = none_u32 },
        .{ .node = 2, .from = 1, .site = 1 },
    };
    try std.testing.expectEqualSlices(SeedStep, &want, lim.seed_steps);
}
