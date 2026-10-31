//! §9.15 simulation parameters: a `$simparam` name in, where its value comes
//! from out (the run time, a host `Model` field, VerA's constant, or the
//! `timescale), as one name-keyed table. Lowering diagnoses and records with
//! it; `Lowered.simparamAnswer` and codegen answer from the same rows, so a
//! name is never both unknown and answered. Here, not in
//! `analog/sysfunc.zig`, so code after lowering reads it from `ir`.
//!
//! Cites: §9.15 (Table 9-27); IEEE 1364-2005 §19.8 (`timescale).
//!
//! Contents:
//! - `pub const HostParam = struct`
//! - `pub const host_params: [6]HostParam`
//! - `pub const Source = union(enum)`
//! - `pub fn source(name: []const u8) ?Source`
//! - `pub fn valueIn(timescale: ?Timescale, name: []const u8) ?f64`
//! - `pub fn isRuntime(name: []const u8) bool`
//! - `pub fn hostField(name: []const u8) ?[]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Timescale = @import("base").Timescale;
const Kernel = @import("Lowered.zig").Kernel;

/// One §9.15 simulation parameter whose value is the host's: its name, its
/// reserved `Model` field (written before `derive()`), the `uses` flag that
/// emits the field, and the field's declared default. Each is SPICE's
/// `.options` entry of that name, `sourceScaleFactor` the source-stepping
/// factor; `tnom` (degrees Celsius) is the temperature a model card without
/// its own `TNOM` was extracted at. The `__` suffix cannot collide:
/// `names.sanitize` escapes a trailing `_` and every `__` run in an identifier.
pub const HostParam = struct { name: []const u8, field: []const u8, use: Kernel, default: f64 };

/// The host's simulation parameters, in `Model` field order.
pub const host_params = [_]HostParam{
    // Table 9-27 gives `tnom` in degrees Celsius; 27 is the field's initializer.
    .{ .name = "tnom", .field = "nom_temp__", .use = .host_tnom, .default = 27.0 },
    // Not in Table 9-27, which §9.15 allows ("There is no fixed list"):
    // SPICE's `.options` Newton tolerances, defaulting to SPICE's values.
    .{ .name = "reltol", .field = "reltol__", .use = .host_reltol, .default = 1e-3 },
    .{ .name = "abstol", .field = "abstol__", .use = .host_abstol, .default = 1e-12 },
    .{ .name = "vntol", .field = "vntol__", .use = .host_vntol, .default = 1e-6 },
    // A host steps `gmin` and `sourceScaleFactor` (gmin stepping,
    // source-stepping homotopy, Table 9-27's own rows), so these are only
    // the defaults of `Model.gmin__`/`source_scale__`.
    .{ .name = "gmin", .field = "gmin__", .use = .host_gmin, .default = 1e-12 },
    .{ .name = "sourceScaleFactor", .field = "source_scale__", .use = .host_source_scale, .default = 1.0 },
};

/// Where one simulation parameter's value comes from.
pub const Source = union(enum) {
    /// `SimState`, which the host writes per evaluation: the Newton
    /// iteration counter (`advanceIteration`), and `dt`, not in Table 9-27,
    /// the host's step since the last accepted point (0 in a static solve),
    /// returned as the host's f64 so a model can reproduce the host's own
    /// `t - dt` bit for bit.
    runtime,
    /// A host-written `Model` field: an index into `host_params`.
    host: u8,
    /// VerA's own compile-time answer.
    constant: f64,
    /// The `timescale unit in force; unknown without one.
    time_unit,
    /// The `timescale precision in force; unknown without one.
    time_precision,
};

/// Every known name. Geometry scaling is applied when the card is built, so
/// 1.0 is the true answer for `scale` and `shrink`, not a stand-in.
const table = std.StaticStringMap(Source).initComptime(blk: {
    const fixed = .{
        .{ "iteration", Source.runtime },
        .{ "dt", Source.runtime },
        .{ "timeUnit", Source.time_unit },
        .{ "timePrecision", Source.time_precision },
        .{ "scale", Source{ .constant = 1.0 } },
        .{ "shrink", Source{ .constant = 1.0 } },
    };
    var kvs: [fixed.len + host_params.len]struct { []const u8, Source } = undefined;
    for (fixed, kvs[0..fixed.len]) |f, *kv| kv.* = .{ f[0], f[1] };
    for (host_params, kvs[fixed.len..], 0..) |h, *kv, i| kv.* = .{ h.name, .{ .host = i } };
    break :blk kvs;
});

comptime {
    assert(host_params.len <= std.math.maxInt(u8));
    for (host_params) |h| assert(std.mem.endsWith(u8, h.field, "__"));
}

/// Returns where `name`'s value comes from, or null for "param_name is not
/// known" (E0811 in `lowerSysCall` without a fallback). Table 9-27 applies to
/// simulators "if they support the parameter", so rows VerA cannot answer
/// (`gdev`, `simulatorVersion`) stay unknown. Names are case-sensitive.
pub fn source(name: []const u8) ?Source {
    const s = table.get(name) orelse return null;
    if (s == .host) assert(std.mem.eql(u8, host_params[s.host].name, name));
    return s;
}

/// Returns the compile-time value of a §9.15 Table 9-27 simulation parameter
/// under the `timescale in force, or null when it has none: unknown, or a
/// `timescale row without a `timescale, or a run-time row. A host row
/// answers its field's default. Takes the `timescale alone so `Lowered` can
/// answer after `Lower` is gone.
pub fn valueIn(timescale: ?Timescale, name: []const u8) ?f64 {
    const s = source(name) orelse return null;
    const v: ?f64 = switch (s) {
        .runtime => null,
        .host => |i| host_params[i].default,
        .constant => |x| x,
        .time_unit => if (timescale) |t| t.unit else null,
        .time_precision => if (timescale) |t| t.precision else null,
    };
    if (s == .host) assert(v != null);
    return v;
}

/// Reports whether `name` is a §9.15 simulation parameter the device answers at
/// run time from `SimState` (`Source.runtime`).
pub fn isRuntime(name: []const u8) bool {
    const s = source(name) orelse return false;
    return s == .runtime;
}

/// Returns the reserved `Model` field of a `host_params` name, or null for
/// any other name.
pub fn hostField(name: []const u8) ?[]const u8 {
    const s = source(name) orelse return null;
    return switch (s) {
        .host => |i| host_params[i].field,
        .runtime, .constant, .time_unit, .time_precision => null,
    };
}

test valueIn {
    // No `timescale: §9.15's two source rows are unknown.
    const d: ?Timescale = null;
    try std.testing.expectEqual(@as(?f64, null), valueIn(d, "timeUnit"));
    try std.testing.expectEqual(@as(?f64, null), valueIn(d, "timePrecision"));
    try std.testing.expectEqual(@as(?f64, 1e-12), valueIn(d, "gmin"));
    try std.testing.expectEqual(@as(?f64, 27.0), valueIn(d, "tnom"));
    try std.testing.expectEqual(@as(?f64, 1.0), valueIn(d, "shrink"));
    try std.testing.expectEqual(@as(?f64, 1.0), valueIn(d, "scale"));
    try std.testing.expectEqual(@as(?f64, 1e-3), valueIn(d, "reltol"));
    try std.testing.expectEqual(@as(?f64, 1e-12), valueIn(d, "abstol"));
    try std.testing.expectEqual(@as(?f64, 1e-6), valueIn(d, "vntol"));
    try std.testing.expectEqual(@as(?f64, 1.0), valueIn(d, "sourceScaleFactor"));
    // Table 9-27 applies "if they support the parameter"; VerA does not.
    try std.testing.expectEqual(@as(?f64, null), valueIn(d, "gdev"));
    // A run-time row has no compile-time value.
    try std.testing.expectEqual(@as(?f64, null), valueIn(d, "iteration"));
    // A `timescale answers both source rows; nothing else moves with it.
    const ts: ?Timescale = .{ .unit = 1e-9, .precision = 1e-12 };
    try std.testing.expectEqual(@as(?f64, 1e-9), valueIn(ts, "timeUnit"));
    try std.testing.expectEqual(@as(?f64, 1e-12), valueIn(ts, "timePrecision"));
    try std.testing.expectEqual(valueIn(d, "reltol"), valueIn(ts, "reltol"));
    // Names are case-sensitive: §9.15 spells `timeUnit`.
    try std.testing.expectEqual(@as(?f64, null), valueIn(ts, "timeunit"));
}

test host_params {
    // `Lowered.simparamAnswer` unwraps a host row's default, and a host row
    // is answered from the card, never from `SimState`.
    for (host_params) |h| {
        try std.testing.expect(valueIn(null, h.name) != null);
        try std.testing.expect(!isRuntime(h.name));
    }
}

test hostField {
    try std.testing.expectEqualStrings("nom_temp__", hostField("tnom").?);
    try std.testing.expectEqualStrings("source_scale__", hostField("sourceScaleFactor").?);
    try std.testing.expect(hostField("timeUnit") == null);
    try std.testing.expect(hostField("scale") == null);
    // Every row's field ends `__`, the suffix `names.sanitize` never emits.
    for (host_params) |h| try std.testing.expect(std.mem.endsWith(u8, h.field, "__"));
}

test isRuntime {
    try std.testing.expect(isRuntime("iteration"));
    try std.testing.expect(isRuntime("dt"));
    try std.testing.expect(!isRuntime("gmin"));
    try std.testing.expect(!isRuntime("nope"));
}
