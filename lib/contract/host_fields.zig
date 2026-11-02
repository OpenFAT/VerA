//! A device's `Model` and `Instance` in, whether the fields a host writes by
//! name have the contract's names and types out: the tables of host-written
//! fields, and the rule `validate` applies to them.
//! Cites: VAMS-2023 §9.10 (`$temperature`), §9.12 and IEEE 1364-2005 §17.10
//! (plusargs), §9.15 Table 9-28 (`$simparam`, `$simparam$str`), §9.17.2
//! (`$bound_step`), E.4.1 (`$mfactor`).
//!
//! Contents:
//! - `pub const Field = struct { name: []const u8, T: type }`
//! - `pub const instance_fields: [5]Field`
//! - `pub const model_index_fields: [2][]const u8`
//! - `pub const model_fields: [7][]const u8`
//! - `pub fn hostFieldsError(comptime D: type) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;

/// One host-written field: its name and its exact type.
pub const Field = struct { name: []const u8, T: type };

/// Host-written `Instance` fields. Presence is optional; the name and type are
/// contract, because the host reaches them by `@hasField` and a typo would be
/// a silently ignored field rather than an error.
pub const instance_fields = [_]Field{
    .{ .name = "mfactor", .T = f64 }, // §9.15/E.4.1 $mfactor
    .{ .name = "bound_step", .T = f64 }, // §9.17.2 $bound_step
    // §9.12 / IEEE 1364 §17.10 the command line's arguments (`argv[1..]`),
    // host-owned; only `+` entries are plusargs. Left at `&.{}`, every
    // $test$plusargs/$value$plusargs search answers 0.
    .{ .name = "plusargs", .T = []const [:0]const u8 },
    // §9.15 Table 9-28 `$simparam$str("cwd")`: the directory the simulator
    // was started in. Left at "", the device answers "". A host pointer in
    // the Instance, so a host that copies Instances to a GPU, or binds only
    // numbers, writes `Model.cwd_idx__` instead (`host_strings`).
    .{ .name = "cwd", .T = []const u8 },
    // §9.15 Table 9-28 `$simparam$str("analysis_name")`: the host's name for
    // the current analysis ("tran1", "mydc"), written before each analysis.
    // The GPU-safe twin is `Model.analysis_name_idx__`.
    .{ .name = "analysis_name", .T = []const u8 },
};

/// Host-written `Model` fields of type `u32`, each an index into
/// `host_strings`: the GPU-safe channel of §9.15 Table 9-28's strings. A
/// device declares both exactly when it declares the `Instance` fields `cwd`
/// and `analysis_name` above, and reads `host_strings[i]` for a nonzero index,
/// else the `Instance` field (`hostString`). Each is 0 ("not written") by
/// default, so a host that writes neither gets what it got before. `setup`
/// does not read them, so a host may rewrite one between evaluations (a new
/// analysis) without calling `setup` again.
pub const model_index_fields = [_][]const u8{
    "cwd_idx__", // $simparam$str("cwd")
    "analysis_name_idx__", // $simparam$str("analysis_name"); also §4.6.3 (`acStimActive`)
};

/// Host-written `Model` fields, all `f64`: §9.15 `$simparam` names whose value
/// is one number per run (SPICE `.options`). Presence is optional, and each is
/// initialized to its SPICE default, so a host that writes none gets that. The
/// host writes them before `derive`, and calls `setup` again after writing a
/// name `setup_simparams` lists.
pub const model_fields = [_][]const u8{
    "temperature__", // §9.10 $temperature, kelvin; 300.15. Per Model row, so
    // an instance at its own temperature gets its own row. `setup` reads it.
    "nom_temp__", // $simparam("tnom"), degC; 27
    "reltol__", // $simparam("reltol"); 1e-3
    "abstol__", // $simparam("abstol"), amperes; 1e-12
    "vntol__", // $simparam("vntol"), volts; 1e-6
    "gmin__", // $simparam("gmin"), siemens; 1e-12. Gmin stepping writes it.
    "source_scale__", // $simparam("sourceScaleFactor"); 1. Source stepping writes it.
};

/// `Instance` fields an earlier contract had and `SimState` now carries: a
/// device that still declares one was built for that contract.
const moved_to_sim_state = [_][]const u8{ "abstime", "dt", "analysis_kind", "is_initial_step", "is_final_step", "is_analog_initial", "newton_iteration" };

comptime {
    // The `cwd`/`analysis_name` pair and its two index twins.
    assert(model_index_fields.len == 2);
    assert(std.mem.eql(u8, instance_fields[3].name, "cwd"));
}

/// Why `D`'s host-written fields break the contract, or null: each one it
/// declares has the table's type, and it declares none of the `Instance`
/// fields `SimState` replaced. Asserts that `D.Model` and `D.Instance` are
/// structs.
pub fn hostFieldsError(comptime D: type) ?[]const u8 {
    assert(@typeInfo(D.Model) == .@"struct");
    assert(@typeInfo(D.Instance) == .@"struct");
    const name = @typeName(D);
    for (instance_fields) |f| {
        if (!@hasField(D.Instance, f.name)) continue;
        if (@FieldType(D.Instance, f.name) != f.T)
            return name ++ ".Instance." ++ f.name ++ ": host-written field must be " ++ @typeName(f.T);
    }
    for (model_fields) |f| {
        if (@hasField(D.Model, f) and @FieldType(D.Model, f) != f64)
            return name ++ ".Model." ++ f ++ ": host-written field must be f64";
    }
    for (model_index_fields) |f| {
        if (@hasField(D.Model, f) and @FieldType(D.Model, f) != u32)
            return name ++ ".Model." ++ f ++ ": host-written index into `contract.host_strings` must be u32";
    }
    // `SimState` carries these, so an Instance field of the same name is one
    // no host writes: a device built for an earlier contract.
    for (moved_to_sim_state) |f| {
        if (@hasField(D.Instance, f))
            return name ++ ".Instance." ++ f ++ ": the host passes it in `contract.SimState`, not in Instance";
    }
    return null;
}

test "hostFieldsError: a host-written field of the wrong type, and a field SimState replaced" {
    const Good = struct {
        pub const Model = struct { temperature__: f64 = 300.15, cwd_idx__: u32 = 0 };
        pub const Instance = struct { mfactor: f64 = 1, cwd: []const u8 = "" };
    };
    try std.testing.expect(comptime hostFieldsError(Good) == null);
    const WideIndex = struct {
        pub const Model = struct { cwd_idx__: u64 = 0 };
        pub const Instance = struct {};
    };
    try std.testing.expect(comptime hostFieldsError(WideIndex) != null);
    const NarrowTemp = struct {
        pub const Model = struct { temperature__: f32 = 300.15 };
        pub const Instance = struct {};
    };
    try std.testing.expect(comptime hostFieldsError(NarrowTemp) != null);
    const Old = struct {
        pub const Model = struct {};
        pub const Instance = struct { abstime: f64 = 0 };
    };
    try std.testing.expect(comptime hostFieldsError(Old) != null);
}
