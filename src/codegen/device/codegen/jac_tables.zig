//! The evidence the stamps left in `Gen.jac` -> the host's structural
//! Jacobian tables: `jac_pattern`/`q_pattern` (which columns of each row can be
//! nonzero), the rows each half ever writes, `deriv_reads`/`ddx_reads`/
//! `jac_const` (the lanes `eval`/`q` read and the exact constant partials of
//! the rest), and `ac_dyn_slots`/`acDyn` for frequency-dependent operators.
//! Cites: §4.5.14, §5.6, §5.6.5.
//!
//! Contents:
//! - `pub fn emitDerivReads(self: *Gen, limit_writes: []const u64) Error!void`
//! - `pub fn emitPattern(self: *Gen, any_q: bool) Error!void`
//! - `pub fn emitAcDyn(self: *Gen, any_q: bool) Error!void`

const std = @import("std");
const plan_jac = @import("plan/jac.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_file = @import("file.zig");
const family = @import("family.zig");
const gen_mask = @import("mask.zig");
const assert = std.debug.assert;
const Error = codegen.Error;
const gen_stamps = @import("stamps.zig");
const switch_row = @import("switch_row.zig");
const gen_dispatch = @import("dispatch.zig");
const dispatch_q = @import("dispatch_q.zig");

/// Emits `deriv_reads`, `ddx_reads` and `jac_const` (`contract.derivReads`).
/// Must run after every unit and residual is written, since all three are
/// read off them. Sound because an unknown's lane matters only if emitted
/// text reads `x[u]` or `.ddxAt(u)`: `renderValueRef` marks every read in a
/// core or unit, `ddx` marks `ddx_reads`, and the dispatcher marks every
/// unknown under a runtime-selected row. An unmarked unknown is read only in
/// the dispatcher's unconditional ±1 stamps, which `lin` replays exactly.
pub fn emitDerivReads(self: *Gen, limit_writes: []const u64) Error!void {
    assert(limit_writes.len == self.mw);
    assert(self.jac.lin[0].len == self.jac.lin[1].len);
    const jc = try plan_jac.plan(self.arena, self.names.n_u, self.jac.deriv_reads, self.jac.ddx_reads, limit_writes, .{ self.jac.lin[0], self.jac.lin[1] }, self.jac.guarded.items);
    assert(jc.mask.len == self.mw);
    var tb: [16]u8 = undefined;
    const ty = gen_mask.typeName(&tb, self.names.n_u);
    try self.w(
        \\/// Unknowns whose derivative lane `eval`/`q` read. Every other
        \\/// column's partials are constants, listed in `jac_const`; see
        \\/// `contract.derivReads`.
        \\pub const deriv_reads: {s} = 0x{f};
        \\
        \\/// The lanes §4.5.14 `ddx` reads by unknown index through `ddxAt`;
        \\/// see `contract.ddxReads`.
        \\pub const ddx_reads: {s} = 0x{f};
        \\
        \\/// The exact constant partials of the columns outside `deriv_reads`:
        \\/// `g` of `eval`, `c` of `q`. Sorted by (row, col); absent is 0.
        \\pub const jac_const = [_]contract.JacConst(U){{
        \\
    , .{ ty, gen_mask.hex(jc.mask, true), ty, gen_mask.hex(self.jac.ddx_reads, true) });
    for (jc.entries) |e| {
        try self.w("    .{{ .row = .{s}, .col = .{s}, .g = {s}, .c = {s}", .{
            self.names.u_names[e.row], self.names.u_names[e.col], try gen_file.fmtF64(self, e.g), try gen_file.fmtF64(self, e.c),
        });
        if (e.when) |k| try self.w(", .when = .{{ .flag = \"{s}\", .collapse_open = true }}", .{try switch_row.guardField(self, k)});
        try self.w(" }},\n", .{});
    }
    try self.w("}};\n\n", .{});
    assert(std.mem.endsWith(u8, self.out.items, "};\n\n"));
    try family.emitLaneMasks(self, jc.mask);
}

/// Emits the §5.6 structural Jacobian: which columns of each residual row can
/// be nonzero, as a comptime constant so the host can drop the structurally
/// zero stamps, and which rows each half writes. The column tables only up
/// to `max_table_words`.
pub fn emitPattern(self: *Gen, any_q: bool) Error!void {
    assert(self.jac.on); // Set by `emitDispatchers`, whose stamps are in.
    if (gen_dispatch.tables(self)) {
        try self.w(
            \\/// §5.6 structural Jacobian: bit `cu` of `jac_pattern[ru]` is set
            \\/// when `∂eval(x)[ru]/∂x[cu]` can be nonzero. A clear bit is a
            \\/// stamp with no physics behind it, and the host may drop it at
            \\/// compile time. Over-approximate: a set bit costs a stamp that
            \\/// happens to be zero, never a missing matrix entry.
            \\
        , .{});
        try emitPatternRows(self, "jac_pattern", self.jac.pat[0]);
    }
    try emitWrittenRows(self, "jac_rows", "eval", self.jac.rows[0]);
    if (!any_q) return;
    if (gen_dispatch.tables(self)) {
        try self.w("/// Same, for `q`'s reactive residual (`dQ/dx`).\n", .{});
        try emitPatternRows(self, "q_pattern", self.jac.pat[1]);
    }
    try emitWrittenRows(self, "q_rows", "q", self.jac.rows[1]);
    assert(std.mem.endsWith(u8, self.out.items, ";\n\n"));
}

/// Emits `ac_dyn_slots` and `acDyn` (`contract.acDynSlots`) when a
/// frequency-dependent operator reaches a residual row.
pub fn emitAcDyn(self: *Gen, any_q: bool) Error!void {
    assert(self.jac.on);
    const n = self.names.n_u;
    if (self.jac.dpat.len == 0) return;
    // A mask has no bit at or past `n`, so its count is its slot count.
    var slots: std.ArrayList(u32) = try .initCapacity(self.arena, gen_mask.count(self.jac.dpat));
    for (0..n) |r| for (0..n) |c| {
        if (gen_mask.has(gen_stamps.rowOf(self, self.jac.dpat, @intCast(r)), c)) slots.appendAssumeCapacity(@intCast(r * n + c));
    };
    assert(slots.items.len == slots.capacity);
    if (slots.items.len == 0) return;
    try self.w(
        \\/// §4.5.7/§4.5.11/§4.5.12 the slots `row * n_u + col` whose small-signal
        \\/// value depends on frequency; `acDyn` supplies them (`contract.acDynSlots`).
        \\pub const ac_dyn_slots = [_]u32{{
    , .{});
    for (slots.items, 0..) |k, i| try self.w("{s}{d}", .{ if (i == 0) " " else ", ", k });
    try self.w(
        \\ }};
        \\
        \\/// Each `ac_dyn_slots` entry's complex term at `omega`, one per lane of `F`
        \\/// (`contract.acDynSlots`).
        \\pub fn acDyn(comptime F: type, model: *const Model, inst: InstancePtr, x: *const [n_u]f64, sim: contract.SimState, omega: F, out: *[ac_dyn_slots.len]std.math.Complex(F)) void {{
        \\    const S = zAc(F);
        \\    var xs = zProbe(S, x);
        \\    inline for (0..n_u) |u| xs[u].w = &omega;
        \\    const m = @call(.always_inline, core, .{{ S, xs, model, inst, sim{s} }});
        \\    const g = zResidual(S, xs, m);
        \\
    , .{self.heldArg(false)});
    if (any_q) {
        try self.b("    const c = contract.qRows(Self, S, ", .{});
        try dispatch_q.writeSites(self);
        try self.b(");\n", .{});
    }
    try self.w(
        \\    inline for (ac_dyn_slots, 0..) |s, k| {{
        \\        const r = s / n_u;
        \\        const u = s % n_u;
        \\
    , .{});
    // A = G + jωC: the charge's complex lanes enter rotated by jω.
    if (any_q) try self.w(
        \\        const re = g[r].acRe(u) - omega * c[r].acIm(u);
        \\        const im = g[r].acIm(u) + omega * c[r].acRe(u);
        \\
    , .{}) else try self.w(
        \\        const re = g[r].acRe(u);
        \\        const im = g[r].acIm(u);
        \\
    , .{});
    try self.w(
        \\        out[k] = .{{ .re = re, .im = im }};
        \\    }}
        \\}}
        \\
        \\
    , .{});
    assert(std.mem.endsWith(u8, self.out.items, "}\n\n"));
}

// ---- private ----

/// Emits which §5.6 residual rows the half ever writes. A row outside the set
/// is zero at every bias, so a host may drop it whole. The host cannot infer
/// this from the pattern: a term with no unknown in it (an independent
/// current source) writes its row with a clear pattern.
fn emitWrittenRows(self: *Gen, name: []const u8, half: []const u8, mask: []const u64) Error!void {
    assert(name.len != 0);
    assert(mask.len == self.mw);
    var tb: [16]u8 = undefined;
    try self.w(
        \\/// §5.6 which residual rows `{s}` ever WRITES: bit `ru` set means
        \\/// `res[ru]` is assigned somewhere in it. A CLEAR bit is the only
        \\/// licence to skip a row's stamp entirely — a clear PATTERN row is
        \\/// not, because a term that depends on no unknown writes the row
        \\/// with an empty column mask. Over-approximate the same way: a set
        \\/// bit costs a stamp that happens to be zero.
        \\pub const {s}: {s} = 0x{f};
        \\
        \\
    , .{ half, name, gen_mask.typeName(&tb, self.names.n_u), gen_mask.hex(mask, true) });
    assert(std.mem.endsWith(u8, self.out.items, ";\n\n"));
}

fn emitPatternRows(self: *Gen, name: []const u8, rows: []const u64) Error!void {
    assert(name.len != 0);
    assert(rows.len == @as(usize, self.names.n_u) * self.mw);
    var tb: [16]u8 = undefined;
    try self.w("pub const {s} = [n_u]{s}{{\n", .{ name, gen_mask.typeName(&tb, self.names.n_u) });
    for (0..self.names.n_u) |i| try self.w("    0x{f}, // {s}\n", .{ gen_mask.hex(gen_stamps.rowOf(self, rows, @intCast(i)), true), self.names.u_names[i] });
    try self.w("}};\n\n", .{});
    assert(std.mem.endsWith(u8, self.out.items, "};\n\n"));
}
