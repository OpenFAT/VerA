//! `Lowered.op_vars` -> the host's operating-point report: `op_vars` (the
//! names) and `opVars` (each one's value at a state vector), read off a
//! slice of the core as `noisePsd` reads its PSDs. An operating-point
//! variable is LRM §3.2.1's output variable: a module-scope variable with a
//! `desc` or `units` attribute, or both, whose value a simulator shall report.
//! LRM: §2.9.2, §3.2.1, §4.5.14.
//!
//! Contents:
//! - `pub fn emitOpVarCore(self: *Gen) Error!void`
//! - `pub fn emitOpVarTable(self: *Gen) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_mask = @import("mask.zig");
const gen_setup = @import("setup.zig");
const gen_unit = @import("unit.zig");
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const coreIdx = @import("dispatch.zig").coreIdx;

/// Emits `<core>__opvars`, the core's slice computing only the values
/// `opVars` reads. Called from `emitUnits`, so its range tiles with the
/// other unit declarations.
pub fn emitOpVarCore(self: *Gen) Error!void {
    if (self.lowered.op_vars.items.len == 0) return;
    const keep = try self.arena.alloc(bool, self.core.lo_vals.len);
    @memset(keep, false);
    var any = false;
    for (self.lowered.op_vars.items) |ov| {
        const k = coreIdx(self, self.an.rv(ov.final)) orelse continue;
        keep[k] = true;
        any = true;
    }
    if (!any) return;
    // As `emitNoiseCore`: a mask cleared around the slice says whether a
    // §4.5.14 `ddx` (a model's own gm or cgg) reads a lane.
    const ddx_before = self.jac.ddx_reads;
    self.jac.ddx_reads = try gen_mask.zero(self.arena, self.mw);
    self.opvar_core = try gen_unit.sliceCore(self, "opvars", keep,
        \\/// The operating-point variables the core computes, and only what
        \\/// they read: `opVars` evaluates them at the state vector `x`.
        \\
    );
    self.opvar_reads_ddx = !std.mem.allEqual(u64, self.jac.ddx_reads, 0);
    gen_mask.orIn(self.jac.ddx_reads, ddx_before);
}

/// Emits `op_vars`, the names in `decl_meta` order, and `opVars`, their
/// values after the analog block runs at `x`, position k for name k. A real
/// variable reports its value, an integer one its value as an f64, and one
/// whose end-of-block value folded to zero reports 0. Nothing when the
/// module has no operating-point variable.
pub fn emitOpVarTable(self: *Gen) Error!void {
    const ovs = self.lowered.op_vars.items;
    if (ovs.len == 0) return;
    try self.w(
        \\/// The operating-point variables: the module-scope variables with a
        \\/// §2.9.2 `desc` or `units` (§3.2.1), in declaration order; `decl_meta`
        \\/// holds each one's `desc` and `units`.
        \\pub const op_vars = [_][]const u8{{
    , .{});
    for (ovs, 0..) |ov, k| try self.w("{s}\"{f}\"", .{ if (k == 0) " " else ", ", std.zig.fmtString(ov.name) });
    try self.w(" }};\n\n", .{});
    try self.w(
        \\/// Each `op_vars[k]`'s value, position k, after the analog block runs
        \\/// at `x`: an integer variable as an f64. `S` seeds the lanes a
        \\/// `ddx` in a variable's expression reads, as `eval`'s family does.
        \\pub fn opVars(comptime
    , .{});
    const at_s = self.out.items.len + 1;
    try self.w(" S: type, ", .{});
    const at_x = self.out.items.len;
    try self.w("x: [n_u]f64, ", .{});
    const at_model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const at_inst = self.out.items.len;
    try self.w("inst: *const Instance, ", .{});
    const at_sim = self.out.items.len;
    try self.w("sim: contract.SimState) [op_vars.len]f64 {{\n", .{});
    const full = self.core;
    defer self.core = full;
    if (self.opvar_core.lo_vals.len != 0) {
        self.core = self.opvar_core;
        const xs = if (self.opvar_reads_ddx) "zProbe(S, &x)" else "zVals(S, &x)";
        try self.w("    const m = {s}(S, {s}, model, {s}, sim{s});\n", .{ self.core.name, xs, try gen_setup.probeInstance(self), self.heldArg(true) });
    } else {
        gen_unit.patchParam(self, at_s, "S".len);
        gen_unit.patchParam(self, at_x, "x".len);
        gen_unit.patchParam(self, at_model, "model".len);
        gen_unit.patchParam(self, at_inst, "inst".len);
        gen_unit.patchParam(self, at_sim, "sim".len);
    }
    try self.w("    return .{{", .{});
    for (ovs, 0..) |ov, k| try self.w("{s}{s}", .{ if (k == 0) " " else ", ", try opVarRef(self, ov.final) });
    try self.w(" }};\n}}\n\n", .{});
}

// ---- private ----

/// The text of one `opVars` entry: the slice's field, as an f64.
fn opVarRef(self: *Gen, final: Mir.Value) Error![]const u8 {
    const v = self.an.rv(final);
    if (v == .f_zero) return "0";
    const k = self.core.lo_idx[@backingInt(v)];
    // `plan_jobs` queued every value that is not `.f_zero`, so the slice has it.
    assert(k != none_u32);
    return switch (self.an.vty[@backingInt(v)]) {
        .real => try self.arena.print("m.f{d}.val()", .{k}),
        .int => try self.arena.print("@as(f64, @floatFromInt(m.f{d}))", .{k}),
        // `readOpVarFinals` keeps real and integer variables only.
        .str, .wide => unreachable,
    };
}
