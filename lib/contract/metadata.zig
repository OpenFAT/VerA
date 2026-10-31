//! A device's module declarations in, the metadata a host shows beside them
//! out: §2.9.2 `desc` and `units` rows (`DeclMeta`), the kind of each unknown
//! (`UnknownKind`), and the contract of the optional `op_vars`/`opVars` and
//! `instance_params` tables. Also the rule `validate` applies to `decl_meta`.
//! Cites: VAMS-2023 §2.9 and §2.9.2 (attributes `desc`, `units`), §3.2.1
//! (output variables), §3.4.3 and §3.6.3.1 (help text), §3.6 (natures).
//!
//! Optional device table `op_vars: [_][]const u8` and its entry point
//!
//!     pub fn opVars(comptime S: type, x: [n_u]f64, model: *const Model,
//!                   inst: *const Instance, sim: SimState) [op_vars.len]f64
//!
//! The operating-point variables, §3.2.1's output variables: every
//! module-scope real or integer variable with a §2.9.2 `desc` or `units`
//! attribute, or both, in declaration order (OSDI's opvars take only a
//! `desc`; a units-only variable is an output variable all the same);
//! `decl_meta` holds each one's `desc` and `units`.
//! `opVars` runs the analog block at `x` and returns, at position k, the value
//! variable `op_vars[k]` holds at its end (an integer as an f64). Pure in `x`,
//! so a host may call it at any accepted point. `S` is the family `eval` gets,
//! so a `ddx` in a variable's expression (a model's own gm or cgg) reads its
//! partial; a value-only family reads every `ddx` as 0. The values are the
//! instance's own: a host-applied `$mfactor` is not in them.
//!
//! Optional device table `instance_params: [_][]const u8`: the `Model` fields
//! of the parameters the source marks `(* type = "instance" *)`, OpenVAF's
//! convention for the ones an instance line sets. An OSDI host lists only
//! these as instance parameters; absent, it may list every parameter.
//!
//! Contents:
//! - `pub const UnknownKind = enum { voltage, current, flow }`
//! - `pub const DeclMeta = struct`
//! - `pub fn declMetaError(comptime table: []const DeclMeta) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;

/// What an unknown is, per position of the optional `u_kinds` table.
pub const UnknownKind = enum {
    voltage,
    current,
    flow,
};

/// §2.9.2 one declaration of the device's own module that carries a `desc` or
/// `units` attribute: what a host shows in a help message (§3.4.3, §3.6.3.1)
/// or beside an output variable in an operating-point report (§3.2.1). Rows
/// of the optional `decl_meta` table, parameters, then variables, then nets,
/// each in declaration order. Comptime data, read by no entry point; a host
/// that does not read it needs nothing.
///
/// What is a row, by the clauses:
///   `.parameter`  a module-scope parameter, `name` as the card spells it;
///   `.variable`   a module-scope variable, a §3.2.1 output variable;
///   `.net`        a module-scope net or port; §2.9.2 gives `units` to
///                 parameters and variables only, so a net row's `units` is
///                 null, and §3.6.3.1's port-and-net pair is one row whose
///                 `desc` is the later declaration's.
/// "Units and descriptions specified for block-level [variables, parameters]
/// shall be ignored by the simulator" (§3.2.1, §3.4.3), so a named block's
/// declarations are never rows; nor is a flattened child instance's.
pub const DeclMeta = struct {
    kind: enum(u8) { parameter, variable, net },
    name: []const u8,
    /// §2.9.2 `desc`, the last one on the declaration (§2.9); null when absent.
    desc: ?[]const u8 = null,
    /// §2.9.2 `units`, likewise. "No dimensional analysis is performed"
    /// (§3.4.3): the text as written.
    units: ?[]const u8 = null,
};

/// The `DeclMeta` rule a row breaks, or null: every row carries a `desc` or
/// `units`, and a net row no `units` (§2.9.2 gives units to parameters and
/// variables). Returns the message so the refusal is testable.
pub fn declMetaError(comptime table: []const DeclMeta) ?[]const u8 {
    for (table) |m| {
        assert(m.name.len != 0);
        if (m.desc == null and m.units == null) return "a row carries a desc or units (`" ++ m.name ++ "` has neither)";
        if (m.kind == .net and m.units != null) return "§2.9.2 gives units to parameters and variables, not to net `" ++ m.name ++ "`";
    }
    return null;
}

test "§2.9.2 a decl_meta row says something, and a net row has no units" {
    const testing = std.testing;
    const rows = [_]DeclMeta{
        .{ .kind = .parameter, .name = "g", .desc = "conductance", .units = "S" },
        .{ .kind = .variable, .name = "ids", .units = "A" },
        .{ .kind = .net, .name = "p", .desc = "positive terminal" },
    };
    try testing.expect(comptime declMetaError(&rows) == null);
    try testing.expect(comptime declMetaError(&.{.{ .kind = .parameter, .name = "r" }}) != null);
    try testing.expect(comptime declMetaError(&.{.{ .kind = .net, .name = "d", .desc = "drain", .units = "V" }}) != null);
}
