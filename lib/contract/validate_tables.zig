//! A device type in, why its optional tables and card hooks break the
//! contract (or null) out: one rule per group of `validate`'s checks on the
//! per-unknown, Jacobian and VPI tables and on the hooks a host calls on a
//! card, in the order `validate` runs them. The noise, AC, charge-site and
//! systf rules live beside their tables (`noise.zig`, `ac.zig`, `rows.zig`,
//! `host_callbacks.zig`).
//! Cites: VAMS-2023 §2.9.2 (`decl_meta`), §3.2.1 (output variables), §3.6.1.2
//! and §3.6.2.3 (`abstol`), §3.6.3.2 (nodesets), §5.6 (the structural
//! Jacobian), clause 12 and §11.6.7 (VPI contribution rows), §6.3.4/§3.4.5
//! (`derive`), §3.4 (shape parameters), §9.18 Table 9-29, §3.4.2 (ranges),
//! §4.5.7 (`absdelay` delays), §5.10.3.3 (timers).
//!
//! Contents:
//! - `pub fn unknownTablesError(comptime D: type) ?[]const u8`
//! - `pub fn patternError(comptime D: type) ?[]const u8`
//! - `pub fn rowsWrittenError(comptime D: type) ?[]const u8`
//! - `pub fn vpiError(comptime D: type) ?[]const u8`
//! - `pub fn systfTableError(comptime D: type) ?[]const u8`
//! - `pub fn cardHooksError(comptime D: type) ?[]const u8`
//! - `pub fn breakpointsError(comptime D: type) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const host_callbacks = @import("host_callbacks.zig");
const masks = @import("masks.zig");
const metadata = @import("metadata.zig");
const shape = @import("validate_shape.zig");
const sim_state = @import("sim_state.zig");
const Mask = masks.Mask;
const nU = masks.nU;

/// The per-unknown tables have one entry per unknown: `u_kinds`,
/// `u_abstol` (§3.6.1.2 `abstol` of each unknown's nature, §3.6.2.3
/// overrides included: the absolute half of a Newton stopping test) and
/// `u_nodeset` (§3.6.3.2 a net initializer is a nodeset: a starting guess,
/// null where none is given, not an initial condition the solve must hold).
/// Also `decl_meta` (§2.9.2) and the `op_vars`/`opVars` pair, both or
/// neither, and `sim_reads`.
pub fn unknownTablesError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    const n = nU(D);
    if (@hasDecl(D, "u_kinds") and @TypeOf(D.u_kinds) != [n]metadata.UnknownKind)
        return name ++ ".u_kinds must be [|U|]UnknownKind";
    if (shape.arrayError(D, "decl_meta", metadata.DeclMeta)) |m| return m;
    if (@hasDecl(D, "decl_meta")) if (metadata.declMetaError(&D.decl_meta)) |m| return name ++ ".decl_meta: " ++ m;
    if (shape.arrayError(D, "op_vars", []const u8)) |m| return m;
    if (shape.requireWithError(D, "op_vars", "opVars")) |m| return m;
    if (shape.requireWithError(D, "opVars", "op_vars")) |m| return m;
    if (@hasDecl(D, "opVars"))
        if (shape.genericError(D, "opVars", 5, "fn (comptime S: type, [n_u]f64, *const Model, *const Instance, SimState) [op_vars.len]f64")) |m| return m;
    if (@hasDecl(D, "u_abstol") and @TypeOf(D.u_abstol) != [n]f64)
        return name ++ ".u_abstol must be [|U|]f64";
    if (@hasDecl(D, "sim_reads") and @TypeOf(D.sim_reads) != sim_state.SimReads)
        return name ++ ".sim_reads must be contract.SimReads";
    if (@hasDecl(D, "u_nodeset") and @TypeOf(D.u_nodeset) != [n]?f64)
        return name ++ ".u_nodeset must be [|U|]?f64";
    return null;
}

/// §5.6 the structural Jacobian, over-approximate: bit `cu` of
/// `jac_pattern[ru]` is set when ∂eval[ru]/∂x[cu] can be nonzero, and
/// `q_pattern` says the same for `q`, which it needs. Absent means dense.
pub fn patternError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    const n = nU(D);
    if (@hasDecl(D, "jac_pattern") and @TypeOf(D.jac_pattern) != [n]Mask(D))
        return name ++ ".jac_pattern must be [|U|]" ++ @typeName(Mask(D)) ++ " (contract.Mask)";
    if (@hasDecl(D, "q_pattern")) {
        if (@TypeOf(D.q_pattern) != [n]Mask(D))
            return name ++ ".q_pattern must be [|U|]" ++ @typeName(Mask(D)) ++ " (contract.Mask)";
        if (!@hasDecl(D, "q"))
            return name ++ ".q_pattern without a `q` residual to describe";
    }
    return null;
}

/// Which rows `eval` (`jac_rows`) and `q` (`q_rows`) ever write, one bit
/// per row. Separate from the pattern because a row can be written with no
/// unknown in it (an independent current source has `jac_pattern = {0, 0}`
/// and two written rows). Only the sound direction is checked: a row with a
/// live column is a written row.
pub fn rowsWrittenError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (masks.rowMaskError(D, name, "jac_rows", "eval")) |m| return m;
    return masks.rowMaskError(D, name, "q_rows", "q");
}

/// Clause 12: the contribution rows' values are meaningless without the
/// rows' shape, and one instance's share of a row several instances share
/// (§5.4.1, §11.6.7) comes with its row and the rows.
pub fn vpiError(comptime D: type) ?[]const u8 {
    const needs = [_][2][]const u8{
        .{ "vpiContribs", "vpi_contrib_access" },
        .{ "vpiContribs", "vpi_contrib_hi" },
        .{ "vpiContribs", "vpi_contrib_lo" },
        .{ "vpiContribs", "vpi_contrib_flow_u" },
        .{ "vpiShares", "vpi_share_row" },
        .{ "vpiShares", "vpiContribs" },
    };
    inline for (needs) |pair| {
        if (shape.requireWithError(D, pair[0], pair[1])) |m| return m;
    }
    return null;
}

/// §2.8.3/§12.32 unresolved `$name`s: `systf_calls` is `[k]Systf` and meets
/// `systfError`'s rules.
pub fn systfTableError(comptime D: type) ?[]const u8 {
    if (shape.arrayError(D, "systf_calls", host_callbacks.Systf)) |m| return m;
    return host_callbacks.systfError(D);
}

/// The hooks a host calls on a card: `mc_param` names the float field of
/// `Model` or `Instance` that Monte Carlo varies; `derive` (§6.3.4/§3.4.5
/// parameters defined over others, and every localparam: `Model` is flat, so
/// a write to a base parameter reaches them only through `derive`);
/// `checkShape` (§3.4 shape parameters, folded into an array bound, a
/// replication count or the generate structure, so the device holds one
/// value of each), `checkCard` (§9.18 Table 9-29) and `checkRange` (§3.4.2
/// `from`/`exclude`, #80); `precompute` (a hand-written device's
/// per-instance preparation); and `constant`.
pub fn cardHooksError(comptime D: type) ?[]const u8 {
    const name = @typeName(D);
    if (@hasDecl(D, "mc_param") and !shape.hasFloatField(D.Instance, D.mc_param) and !shape.hasFloatField(D.Model, D.mc_param))
        return name ++ ".mc_param '" ++ D.mc_param ++ "' is not a float field of Model or Instance";
    if (@hasDecl(D, "derive"))
        if (shape.genericError(D, "derive", 2, "fn (comptime S: type, *Model) void")) |m| return m;
    inline for (.{ "checkShape", "checkCard", "checkRange" }) |hook| {
        if (@hasDecl(D, hook))
            if (shape.fnError(D, hook, fn (*const D.Model) ?[]const u8)) |m| return m;
    }
    if (@hasDecl(D, "precompute"))
        if (shape.fnError(D, "precompute", fn (*D.Instance, *const D.Model) void)) |m| return m;
    if (@hasDecl(D, "constant") and @TypeOf(D.constant) != sim_state.Constant)
        return name ++ ".constant must be contract.Constant";
    return null;
}

/// Breakpoint scheduling: `nextBreakpoint` (piecewise sources),
/// `pendingBreakpoint` (the live per-instance schedule: §5.10.3.3 timers,
/// re-armed start times included, digital events, and the corners of D2A
/// ramps) and `delays` (§4.5.7 `absdelay` delays, from which the host echoes
/// breakpoints).
pub fn breakpointsError(comptime D: type) ?[]const u8 {
    if (@hasDecl(D, "nextBreakpoint"))
        if (shape.fnError(D, "nextBreakpoint", fn (*const D.Model, f64) ?f64)) |m| return m;
    if (@hasDecl(D, "pendingBreakpoint"))
        if (shape.fnError(D, "pendingBreakpoint", fn (*const D.Instance, f64) ?f64)) |m| return m;
    if (@hasDecl(D, "delays")) {
        const R = @typeInfo(@TypeOf(D.delays)).@"fn".return_type.?;
        if (@typeInfo(R) != .array or @typeInfo(R).array.child != f64)
            return @typeName(D) ++ ".delays: must return [n]f64";
        if (shape.fnError(D, "delays", fn (*const D.Model) R)) |m| return m;
    }
    return null;
}

test "vpiError and cardHooksError refuse their own mistakes" {
    const testing = std.testing;
    try testing.expect(comptime vpiError(struct {
        pub const vpiShares = 0;
        pub const vpi_share_row = 0;
    }) != null);
    try testing.expect(comptime cardHooksError(struct {
        pub const Model = struct { g: u32 = 0 };
        pub const Instance = struct {};
        pub const mc_param = "g";
    }) != null);
    try testing.expect(comptime breakpointsError(struct {
        pub const Model = struct {};
        pub fn delays(_: *const Model) [1]f32 {
            return .{0};
        }
    }) != null);
}
