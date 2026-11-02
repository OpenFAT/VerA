//! The lowered nodes, ports and branch currents (`plan/names.zig`) -> `U`, the
//! solver unknowns (§1.3.1 nodes, §6.5 ports first), each one's §3.6.1.2
//! `abstol`, the §3.6.3.2 `u_nodeset` initial values, §2.9.2's `decl_meta` and
//! the `instance_params` table.
//! Cites: §1.3.1, §1.3.4.2, §2.9.2, §3.6.1.2, §3.6.2.3, §3.6.3.2, §5.4.2, §6.5.
//!
//! Contents:
//! - `pub fn emitTopology(self: *Gen) Error!void`
//! - `pub fn emitDeclMeta(self: *Gen) Error!void`
//! - `pub fn emitInstanceParams(self: *Gen) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const plan_topo = @import("plan/topology.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const Lower = @import("ir").Lowered;
const Error = codegen.Error;
const vera_version = @import("kernels").vera_version;
const gen_file = @import("file.zig");

/// Emits `U`, the solver unknowns (§1.3.1 nodes, §6.5 ports first, so the
/// host's terminal order is the module header order), and the per-unknown
/// tables. `x[i]` in every emitted body indexes this enum. `U` is an
/// `enum(u8)` up to 256 unknowns and as wide as the count needs past them
/// (`contract.isDenseEnum` takes any unsigned tag of 8 bits or more), so the
/// count has no bound of its own (#29; §6.5.2.2 asks for at least 256 ports).
pub fn emitTopology(self: *Gen) Error!void {
    assert(self.names.u_names.len == self.names.n_u);
    assert(self.out.items.len != 0);
    const n_names: u32 = @intCast(self.names.u_names.len);
    try self.w("/// Solver unknowns: §6.5 ports first, then §3.6.3 internal nets,\n", .{});
    try self.w("/// then §5.4.2 branch-flow unknowns.\n", .{});
    try self.w("pub const U = enum(u{d}) {{\n", .{@max(8, std.math.log2_int_ceil(u32, @max(n_names, 1)))});
    for (self.names.u_names, 0..) |n, i| {
        const kindc: []const u8 = if (i < self.lowered.num_ports)
            "port"
        else if (plan_topo.isFlowUnknown(self.input(), @intCast(i)))
            "branch flow"
        else if (i < self.lowered.nodes.len and self.lowered.nodes.items(.kind)[i] == .op_state)
            "§4.5.2 operator unknown"
        else
            "internal";
        try self.w("    {s}, // {s}\n", .{ n, kindc });
    }
    // No unknowns: Zig 0.17 refuses an empty exhaustive `enum(u8)`, and
    // `enum(noreturn)` would break the contract's unsigned tag.
    if (self.names.u_names.len == 0) try self.w("    _,\n", .{});
    try self.w(
        \\}};
        \\
        \\/// The first `num_ports` members of `U` are the §6.5 ports, in
        \\/// port-list order: the unknowns a netlist connects.
        \\pub const num_ports: usize = {d};
        \\const n_u = contract.nU(Self);
        \\
        \\
    , .{self.lowered.num_ports});
    try self.w("/// The VerA release that generated this device (`contract.vera_version`).\npub const vera_version = \"{s}\";\n\n", .{vera_version});

    if (self.float.jac != .off) try self.w(
        \\/// This device permits a single-precision DERIVATIVE half in the
        \\/// host's scalar S. The residual stays f64 — see `--jac-f32`.
        \\/// Permission, not order: a host may take it on one instantiation
        \\/// (its GPU kernel) and decline it on another (its CPU path).
        \\pub const jac_f32 = true;
        \\
        \\
    , .{});
    if (self.float.jac == .host) try self.w(
        \\/// ...and the host should take that permission on its CPU path too,
        \\/// not only where f32 is free. See `--jac-f32-host`.
        \\pub const jac_f32_host = true;
        \\
        \\
    , .{});

    var any_current = false;
    for (0..self.names.n_u) |i| {
        if (plan_topo.isFlowUnknown(self.input(), @intCast(i))) any_current = true;
    }
    if (any_current) {
        try self.w(
            \\/// Per unknown, in `U` order: a node potential (`.voltage`) or a
            \\/// §5.4.2 branch flow (`.current`).
            \\pub const u_kinds = [n_u]contract.UnknownKind{{
            \\
        , .{});
        for (0..self.names.n_u) |i| {
            try self.w("    .{s},\n", .{if (plan_topo.isFlowUnknown(self.input(), @intCast(i))) "current" else "voltage"});
        }
        try self.w("}};\n\n", .{});
    }
    // §3.6.1.2 the tolerance the discipline settled on for each unknown. A
    // host needs the absolute half of its stopping test per unknown and
    // cannot derive it: "negligible" differs per nature, and §3.6.2.3 lets a
    // discipline override the nature's number.
    try self.w("/// §3.6.1.2 `abstol` per unknown: the largest value of this\n", .{});
    try self.w("/// quantity a host may treat as zero, after any §3.6.2.3 override.\n", .{});
    try self.w("pub const u_abstol = [n_u]f64{{\n", .{});
    for (0..self.names.n_u) |i| {
        try self.w("    {d},\n", .{abstolOf(self, @intCast(i))});
    }
    try self.w("}};\n\n", .{});
    try emitNodesets(self);
    assert(std.mem.endsWith(u8, self.out.items, "};\n\n"));
}

/// Emits `decl_meta`, §2.9.2's `desc` and `units` on the module's own
/// declarations (`contract.DeclMeta`), in `Lowered.decl_meta` order. Only
/// when the module writes one: its absence means no such attribute.
pub fn emitDeclMeta(self: *Gen) Error!void {
    assert(self.out.items.len != 0);
    if (self.lowered.decl_meta.items.len == 0) return;
    try self.w("/// §2.9.2 `desc`/`units` of this module's own declarations, for a\n", .{});
    try self.w("/// host's help messages and operating-point reports (§3.2.1, §3.4.3, §3.6.3.1).\n", .{});
    try self.w("pub const decl_meta = [_]contract.DeclMeta{{\n", .{});
    for (self.lowered.decl_meta.items) |m| {
        try self.w("    .{{ .kind = .{t}, .name = \"{f}\"", .{ m.kind, std.zig.fmtString(m.name) });
        if (m.desc) |v| try self.w(", .desc = \"{f}\"", .{std.zig.fmtString(v)});
        if (m.units) |v| try self.w(", .units = \"{f}\"", .{std.zig.fmtString(v)});
        try self.w(" }},\n", .{});
    }
    try self.w("}};\n\n", .{});
    assert(std.mem.endsWith(u8, self.out.items, "};\n\n"));
}

/// Emits `instance_params` (`contract`'s optional table): the `Model` fields
/// of the parameters marked `type = "instance"`. Only when one is.
pub fn emitInstanceParams(self: *Gen) Error!void {
    assert(self.names.p_names.len == self.lowered.params.items.len);
    if (self.lowered.instance_params.items.len == 0) return;
    try self.w("/// The parameters marked `(* type = \"instance\" *)`: an OSDI host lists\n", .{});
    try self.w("/// only these as instance parameters.\n", .{});
    try self.w("pub const instance_params = [_][]const u8{{\n", .{});
    for (self.lowered.instance_params.items) |nm| {
        for (self.lowered.params.items, 0..) |p, i| if (std.mem.eql(u8, p.name, nm)) {
            try self.w("    \"{s}\",\n", .{self.names.p_names[i]});
            break;
        };
    }
    try self.w("}};\n\n", .{});
    assert(std.mem.endsWith(u8, self.out.items, "};\n\n"));
}

// ---- private ----

/// Emits `u_nodeset`, the §3.6.3.2 net discipline initial values as one
/// optional table over `U`: a number per unknown only the declaration knows
/// and only the host's solver can use. Emitted only when the module declares
/// one, so its absence means "no opinion". `?f64` because "a null value ...
/// indicates that no nodeset value is being specified" and zero is an
/// ordinary nodeset; a §5.4.2 branch flow is always null.
fn emitNodesets(self: *Gen) Error!void {
    assert(self.names.n_u >= self.lowered.nodes.len);
    if (self.lowered.nodesets.items.len == 0) return;
    try self.w("/// §3.6.3.2 nodeset: the initial guess the source states for each\n", .{});
    try self.w("/// unknown's potential. A HINT to the solver — not an initial\n", .{});
    try self.w("/// condition and not a clamp; the solved answer is unchanged by it.\n", .{});
    try self.w("pub const u_nodeset = [n_u]?f64{{\n", .{});
    for (0..self.names.n_u) |i| {
        // §3.6.3.2: "If different nets of a node have conflicting
        // initializers ... it is a race condition for which the initializer
        // wins." Last wins here, which the clause permits.
        var v: ?f64 = null;
        for (self.lowered.nodesets.items) |ns| {
            if (ns.node == i) v = ns.value;
        }
        if (v) |x| try self.w("    {s},\n", .{try gen_file.fmtF64(self, x)}) else try self.w("    null,\n", .{});
    }
    try self.w("}};\n\n", .{});
    assert(std.mem.endsWith(u8, self.out.items, "};\n\n"));
}

/// Returns the §3.6.1.2 `abstol` of the nature this unknown's quantity
/// belongs to, after §3.6.2.3's per-discipline override (so it reads
/// `DisciplineInfo`, not the nature table). A §5.4.2 branch flow takes the
/// discipline at its high node (`Lower.NodeKind`'s payload). A net with no
/// discipline (a §3.5 implicit net without `default_discipline`) falls back to
/// annex D's `VOLTAGE_ABSTOL` 1e-6 / `CURRENT_ABSTOL` 1e-12.
/// A shared potential node uses §7.2.4's minimum across its signal segments.
fn abstolOf(self: *const Gen, i: u32) f64 {
    assert(i < self.names.n_u);
    const flow = plan_topo.isFlowUnknown(self.input(), i);
    var idx: u32 = i;
    if (i < self.lowered.nodes.len) switch (self.lowered.nodes.items(.kind)[i]) {
        .net => {},
        .branch_flow, .port_flow => |n| idx = n,
        .op_state => |t| return t,
    };
    if (idx == Lower.ground or idx >= self.lowered.nodes.len)
        return if (flow) 1e-12 else 1e-6;
    if (!flow) if (self.lowered.nodes.items(.potential_abstol)[idx]) |abstol| return abstol;
    const info = self.lowered.disciplines.get(self.lowered.nodes.items(.disc)[idx]) orelse
        return if (flow) 1e-12 else 1e-6;
    return if (flow) info.flow_abstol else info.potential_abstol;
}
