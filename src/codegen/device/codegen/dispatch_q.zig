//! The §5.6.1.2 charge sites (`plan/qsite.zig`) -> `q`, the reactive residual
//! as one charge per site, its site tables (`n_q`, `q_stamps`, `q_lte`,
//! `q_site_pattern`) and the `q_pattern` rows the sites stamp.
//! Cites: §5.6.1.2.
//!
//! Contents:
//! - `pub fn writeSites(self: *Gen) Error!void`
//! - `pub fn qPattern(self: *Gen) void`
//! - `pub fn emitQ(self: *Gen) Error!void`
//! - `pub fn emitQSites(self: *Gen) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const none_u32 = codegen.none_u32;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_file = @import("file.zig");
const gen_instance = @import("instance.zig");
const gen_status = @import("status.zig");
const family = @import("family.zig");
const gen_mask = @import("mask.zig");
const Error = codegen.Error;
const gen_stamps = @import("stamps.zig");
const gen_dispatch = @import("dispatch.zig");

/// Writes a `contract.Sites(Self, S)` literal: every site's charge, in slot order.
/// Asserts that `q` has a site to return and that each site's charge is a
/// core field. Invalidates slices of `out.items` if additional memory is needed.
pub fn writeSites(self: *Gen) Error!void {
    assert(self.qs.sites.len != 0);
    const len_before = self.out.items.len;
    try self.b("@as(contract.Sites(Self, S), .{{", .{});
    for (0..self.qs.sites.len) |j| try self.b("{s}m.f{d}", .{ if (j == 0) " " else ", ", siteField(self, j) });
    try self.b(" }})", .{});
    assert(self.out.items.len > len_before);
}

/// Fills `q_pattern`/`q_rows` from the sites: row `ru` is written when a site
/// stamps it, and its columns are the union of those sites' dependences.
pub fn qPattern(self: *Gen) void {
    assert(self.qs.sites.len != 0);
    for (self.qs.stamps) |st| {
        const k = self.qs.sites[st.slot];
        const site = self.lowered.charge_sites.items[k].final;
        assert(st.row < self.names.n_u);
        if (self.jac.pat[1].len != 0) gen_mask.orIn(gen_stamps.rowOf(self, self.jac.pat[1], st.row), family.mask(self, site));
        if (self.jac.dpat.len != 0) gen_mask.orIn(gen_stamps.rowOf(self, self.jac.dpat, st.row), family.acDyn(self, site));
        gen_mask.set(self.jac.rows[1], st.row);
    }
}

/// Emits `q`, the §5.6.1.2 reactive residual as one charge per site
/// (`plan/qsite.zig`). `q_stamps` says which rows each enters, so a host
/// integrates and truncation-checks each charge on its own.
pub fn emitQ(self: *Gen) Error!void {
    assert(self.qs.sites.len != 0);
    assert(self.core.name.len != 0);
    try self.w(
        \\/// §5.6.1.2 the charges, one per `ddt` site (`n_q`, `q_stamps`, `q_lte`);
        \\/// the host differentiates each and stamps it into its rows.
        \\pub fn q(comptime S: type, x: *const [n_u]S.V, model: *const Model, inst: InstancePtr, sim: contract.SimState) contract.Sites(Self, S) {{
        \\
    , .{});
    try gen_dispatch.writeLead(self, "q", "out");
    if (gen_status.hasStatus(self)) {
        try self.w(
            \\    var out: contract.Sites(Self, S) = zSitesZero(S);
            \\    if (inst.vera_status__ == 0) {{
            \\        const m = @call(.always_inline, core, .{{ S, zProbe(S, x), model, inst, sim{s} }});
            \\        zStatusStore(inst, m);
            \\        if (inst.vera_status__ == 0) out = 
        , .{self.heldArg(false)});
        try writeSites(self);
        try self.w(";\n    }}\n" ++ gen_dispatch.status_tail, .{});
        return;
    }
    try self.w(
        \\    const m = @call(.always_inline, core, .{{ S, zProbe(S, x), model, inst, sim{s} }});
        \\
    , .{self.heldArg(false)});
    try self.w("    return ", .{});
    try writeSites(self);
    try self.w(";\n}}\n\n", .{});
}

/// Emits `n_q`, `q_stamps`, `q_lte` and `q_site_pattern` (`contract.QSites`).
pub fn emitQSites(self: *Gen) Error!void {
    assert(self.qs.sites.len != 0);
    try self.w(
        \\/// §5.6.1.2 how many charge sites `q` returns.
        \\pub const n_q: usize = {d};
        \\
        \\/// Row `row` of the reactive residual is `Σ sign · q[site]` over its
        \\/// entries. Sorted by (row, site).
        \\pub const q_stamps = [_]contract.QStamp(U){{
        \\
    , .{self.qs.sites.len});
    for (self.qs.stamps) |st| try self.w("    .{{ .site = {d}, .row = .{s}, .sign = {s} }},\n", .{
        st.slot, self.names.u_names[st.row], try gen_file.fmtF64(self, st.sign),
    });
    try self.w(
        \\}};
        \\
        \\/// Which charge sites join the host's local-truncation-error check
        \\/// (VerA's `vera_lte` attribute; all of them unless a model says so).
        \\pub const q_lte = [n_q]bool{{
    , .{});
    for (self.qs.sites, 0..) |k, j| try self.w("{s}{}", .{ if (j == 0) " " else ", ", self.lowered.charge_sites.items[k].lte });
    try self.w(" }};\n\n", .{});
    if (!gen_dispatch.tables(self)) return;
    var tb: [16]u8 = undefined;
    try self.w("/// Bit `cu` of `q_site_pattern[k]` is set when `∂q[k]/∂x[cu]` can be nonzero.\npub const q_site_pattern = [n_q]{s}{{\n", .{gen_mask.typeName(&tb, self.names.n_u)});
    for (self.qs.sites) |k| try self.w("    0x{f},\n", .{gen_mask.hex(family.mask(self, self.lowered.charge_sites.items[k].final), true)});
    try self.w("}};\n\n", .{});
}

// ---- private ----

/// The core field holding slot `j`'s charge.
fn siteField(self: *const Gen, j: usize) u32 {
    assert(j < self.qs.sites.len);
    const k = self.qs.sites[j];
    const field = self.core.lo_idx[@backingInt(self.an.rv(self.lowered.charge_sites.items[k].final))];
    assert(field != none_u32); // A site with a slot moves in time, so the core returns it.
    return field;
}
