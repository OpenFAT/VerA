//! The §5.6.5 collapsible branches (`plan/topology.zig`'s pairs) -> `collapse`
//! and `collapse_full`: which unknowns a host may alias away at a bias where a
//! switch branch is a short, read off the core at x = 0, and the union-find
//! `out` both write.
//! Cites: §5.6.1.3, §5.6.5.
//!
//! Contents:
//! - `pub fn emitCollapse(self: *Gen, pairs: []const CollapsePair) Error!void`

const std = @import("std");
const CollapsePair = @import("plan/topology.zig").CollapsePair;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const assert = std.debug.assert;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;

/// Writes `collapse` and `collapse_full` (§5.6.5). `collapse` runs the core
/// at x = 0 and reads the §5.6.1.3 retention flags `eval` selects branch rows
/// on; a set flag is a dead short whose internal node and branch-flow unknown
/// the host aliases onto the far node. The host calls it once, at build, so
/// only `buildFree` flags are admitted.
pub fn emitCollapse(self: *Gen, pairs: []const CollapsePair) Error!void {
    for (pairs) |p| assert(p.flow_u < self.names.n_u);
    for (pairs) |p| assert(p.victim < self.names.n_u);
    for (pairs) |p| assert(p.target < p.victim); // `collapsePairs` orders them
    if (pairs.len == 0) return;
    try self.w(
        \\/// Zero-parasitic node collapse (ngspice setup: DIOsetup's
        \\/// `posPrimeNode = posNode` when RS == 0). Applied by the host before
        \\/// matrix build; the flags read here are the §5.6.1.3 retention flags
        \\/// `eval` selects the branch rows on, evaluated at x = 0 like `seed` —
        \\/// sound because codegen admits only build-time-constant flags.
        \\///
        \\/// Dead shorts form CHAINS (BSIM4's rgateMod=0 retains both V(g,gm)=0
        \\/// and V(gm,gi)=0, sharing gm), so aliases are resolved by union-find:
        \\/// every member of a merged set lands on ONE root and each stamp of
        \\/// the set cancels on a single slot. Last-write-wins aliasing left the
        \\/// chain's first link dangling — its KVL row landed on a KCL row as
        \\/// ±1 garbage stamps and the "solution" violated the model equations.
        \\pub fn collapse(comptime S: type, model: *const Model, inst: *const Instance) [n_u]?u8 {{
        \\    const xr: [n_u]zOf(S, 0) = @splat(S.con(0.0));
        \\    // SEEDS ITS OWN SETUP, on a local copy. `collapse` decides
        \\    // TOPOLOGY, so a host must call it while building the matrix —
        \\    // before the batch exists and therefore before the batch runs
        \\    // `setup`. But it answers by evaluating `core` at x = 0, and
        \\    // `core` reads `Model.su`: without this the retention flags
        \\    // are read off unset fields and a device collapses (or fails to)
        \\    // on garbage. `setup` is a pure function of the model, so
        \\    // computing it here is the answer the batch will compute later,
        \\    // and the copies keep the caller's Model and Instance untouched.
        \\{s}    const m = core(S, xr, {s}, {s}, .{{}}{s});
        \\    var parent: [n_u]u8 = undefined;
        \\    for (&parent, 0..) |*p, i| p.* = @intCast(i);
        \\
    , .{
        if (self.su.vals.len != 0 and self.lowered.table_samples.items.len != 0)
            "    var mpin = model.*;\n    setup(S, &mpin);\n    var pin = inst.*;\n"
        else if (self.su.vals.len != 0)
            "    var mpin = model.*;\n    setup(S, &mpin);\n"
        else if (self.lowered.table_samples.items.len != 0)
            "    var pin = inst.*;\n"
        else
            "",
        if (self.su.vals.len != 0) "&mpin" else "model",
        if (self.lowered.table_samples.items.len != 0) "&pin" else "inst",
        self.heldArg(true),
    });
    for (pairs, 0..) |p, pi| {
        const fi = @backingInt(self.an.rv(p.flag));
        const k = self.core.lo_idx[fi];
        assert(k != none_u32); // `buildJobs` queues every runtime retention flag
        if (self.an.vty[fi] == .int)
            try self.w("    const a{d} = (m.f{d} != 0);", .{ pi, k })
        else
            try self.w("    const a{d} = (m.f{d}.val() != 0.0);", .{ pi, k });
        try self.w(" // 0 V arm retained: dead short\n", .{});
        try self.w("    if (a{d}) zCollapseUnion(&parent, @intFromEnum(U.{s}), @intFromEnum(U.{s}));\n", .{
            pi, self.names.u_names[p.victim], self.names.u_names[p.target],
        });
    }
    try emitAliases(self, pairs);
    try self.w("    return out;\n}}\n\n", .{});
    try self.w(
        \\fn zCollapseRoot(parent: *const [n_u]u8, start: u8) u8 {{
        \\    var u = start;
        \\    while (parent[u] != u) u = parent[u];
        \\    return u;
        \\}}
        \\
        \\/// Min-index root wins, so a set's root is always its lowest unknown —
        \\/// the host resolves aliases in ascending order and needs the target
        \\/// resolved before every mover.
        \\fn zCollapseUnion(parent: *[n_u]u8, a: u8, b: u8) void {{
        \\    const ra = zCollapseRoot(parent, a);
        \\    const rb = zCollapseRoot(parent, b);
        \\    if (ra == rb) return;
        \\    if (ra < rb) parent[rb] = ra else parent[ra] = rb;
        \\}}
        \\
        \\
    , .{});
    try emitCollapseFull(self, pairs);
}

// ---- private ----

/// Writes `collapse_full`: `collapse` with every retention flag set, as a
/// comptime const. A host sizes a reduced derivative basis from it (a type,
/// so it cannot wait for an instance); an instance qualifies exactly when its
/// runtime `collapse` equals this.
fn emitCollapseFull(self: *Gen, pairs: []const CollapsePair) Error!void {
    assert(pairs.len != 0);
    assert(self.names.u_names.len == self.names.n_u);
    try self.w(
        \\/// The MAXIMAL collapse: `collapse` with every §5.6.1.3 retention
        \\/// flag set. Comptime, so a host can size a reduced derivative
        \\/// basis for the instances whose runtime `collapse` equals this;
        \\/// any other outcome merges strictly less and must use full width.
        \\pub const collapse_full: [n_u]?u8 = blk: {{
        \\    var parent: [n_u]u8 = undefined;
        \\    for (&parent, 0..) |*p, i| p.* = @intCast(i);
        \\
    , .{});
    for (pairs) |p| {
        try self.w("    zCollapseUnion(&parent, @intFromEnum(U.{s}), @intFromEnum(U.{s}));\n", .{
            self.names.u_names[p.victim], self.names.u_names[p.target],
        });
    }
    try emitAliases(self, pairs);
    try self.w("    break :blk out;\n}};\n\n", .{});
}

/// Writes `collapse`'s and `collapse_full`'s `out` from the union-find
/// `parent` both have built: each unknown's root, then every pair's
/// branch-flow unknown. Unconditional, unlike the union: the flag decides
/// whether the nodes merge, but the branch-flow unknown is aliased either
/// way. Not taken, the branch is a conductance stamped straight into KCL
/// (`emitSwitchRow`), so its current row is never written.
fn emitAliases(self: *Gen, pairs: []const CollapsePair) Error!void {
    assert(pairs.len != 0);
    assert(self.names.u_names.len == self.names.n_u);
    try self.w(
        \\    var out: [n_u]?u8 = @splat(null);
        \\    for (0..n_u) |u| {{
        \\        const r = zCollapseRoot(&parent, @intCast(u));
        \\        if (r != u) out[u] = r;
        \\    }}
        \\
    , .{});
    for (pairs) |p| {
        try self.w("    out[@intFromEnum(U.{s})] = zCollapseRoot(&parent, @intFromEnum(U.{s}));\n", .{
            self.names.u_names[p.flow_u], self.names.u_names[p.target],
        });
    }
}
