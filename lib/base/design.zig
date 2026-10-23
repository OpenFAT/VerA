//! The rows elaboration publishes that stages after lowering read: a §7.8.4
//! inserted connect module, a §3.4 `--param` override, the §7.4.4
//! discipline-resolution mode and a §9.18 Table 9-29 system parameter.
//! Elaboration (`Elaborate`, `hier_param`) aliases them, and `Lowered`
//! carries them without importing elaboration.
//! Imports only std.
//!
//! LRM clauses this file's code cites: §3.4, §6.3.6, §7.4.4, §7.8.4, §9.18, F.2.2.

const std = @import("std");

/// One port §7.8.4 re-pointed at a connect module (`elab/insert.zig`), by
/// name. In the module instance at `path` (instance prefix, separator
/// included, empty at the top), port `port` of child `inst` is connected to
/// the bridge `name`'s `lower_port` instead of its upper connection, and the
/// bridge (an instance of `module`) takes that upper connection on
/// `upper_port`. Merged ports share a bridge, so `name` repeats. The segment
/// between the child and the bridge is `name ++ sep ++ lower_port`.
pub const Inserted = struct {
    path: []const u8,
    inst: []const u8,
    port: []const u8,
    module: []const u8,
    name: []const u8,
    upper_port: []const u8,
    lower_port: []const u8,
};

/// §7.4.4 "There are two modes for this method of resolution, basic (the
/// default) and detail"; F.2.2: "The selection of this algorithm instead of
/// the default shall be controlled by a simulator option" (VerA's is
/// `--discipline-resolution=`). The mode decides where connect modules go
/// (`segment.down`, read by `insert.plan`).
pub const DisciplineResolution = enum { basic, detail };

/// §3.4 compile-time overrides, shared with Lower.Options. Elaboration needs
/// their final values when a §6.4.2 overload choice depends on a top parameter.
/// `text` is the value as typed: a string parameter takes it verbatim. `value`
/// is that text read as a number, NaN when it is not one.
pub const ParamOverride = struct { name: []const u8, value: f64, text: []const u8 = "" };

/// One §9.18 Table 9-29 hierarchical system parameter. The tag is the
/// spelling without its `$`.
pub const SystemParam = enum {
    angle,
    hflip,
    mfactor,
    vflip,
    xposition,
    yposition,

    /// Every kind, in declaration order (the order elaboration reports them).
    pub const all = std.enums.values(SystemParam);

    /// Returns the kind `spelling` names, `$` included, or null.
    pub fn fromName(spelling: []const u8) ?SystemParam {
        if (spelling.len == 0 or spelling[0] != '$') return null;
        return std.meta.stringToEnum(SystemParam, spelling[1..]);
    }

    /// Returns the source spelling, `$` included.
    pub fn name(self: SystemParam) []const u8 {
        return switch (self) {
            inline else => |k| "$" ++ @tagName(k),
        };
    }

    /// Returns Table 9-29's value for an instance nothing sets: the
    /// composition's identity (0 for the sums, 1 for the products).
    pub fn initial(self: SystemParam) f64 {
        return switch (self) {
            .angle, .xposition, .yposition => 0,
            .hflip, .mfactor, .vflip => 1,
        };
    }

    /// Returns whether `value` is in Table 9-29's domain for the kind.
    pub fn allows(self: SystemParam, value: f64) bool {
        return switch (self) {
            .angle => value >= 0 and value < 360,
            .hflip, .vflip => value == 1 or value == -1,
            .mfactor => value > 0,
            .xposition, .yposition => true,
        };
    }

    /// Returns whether Table 9-29 restricts the kind's values at all.
    pub fn constrained(self: SystemParam) bool {
        return switch (self) {
            .angle, .hflip, .vflip, .mfactor => true,
            .xposition, .yposition => false,
        };
    }

    /// Returns the domain `allows` checks, worded for a diagnostic.
    pub fn domain(self: SystemParam) []const u8 {
        return switch (self) {
            .angle => "0 <= $angle < 360",
            .hflip => "$hflip = +1 or -1",
            .mfactor => "$mfactor > 0",
            .vflip => "$vflip = +1 or -1",
            .xposition, .yposition => "any value",
        };
    }
};

test "SystemParam: spellings round-trip, and nothing else names a kind" {
    for (SystemParam.all) |k| try std.testing.expectEqual(@as(?SystemParam, k), SystemParam.fromName(k.name()));
    try std.testing.expectEqual(@as(usize, 6), SystemParam.all.len); // §6.3.6: "six system parameters"
    for ([_][]const u8{ "", "$", "angle", "$Angle", "$mfactor2", "$$angle", "mfactor" }) |s|
        try std.testing.expectEqual(@as(?SystemParam, null), SystemParam.fromName(s));
}

test "SystemParam: Table 9-29's top-level values and allowed values" {
    const t = std.testing;
    try t.expectEqual(@as(f64, 0), SystemParam.angle.initial());
    try t.expectEqual(@as(f64, 1), SystemParam.hflip.initial());
    try t.expectEqual(@as(f64, 1), SystemParam.vflip.initial());
    try t.expectEqual(@as(f64, 1), SystemParam.mfactor.initial());
    try t.expectEqual(@as(f64, 0), SystemParam.xposition.initial());
    try t.expectEqual(@as(f64, 0), SystemParam.yposition.initial());
    // Every top-level value is itself allowed.
    for (SystemParam.all) |k| try t.expect(k.allows(k.initial()));
    // "0 <= $angle < 360": both edges.
    try t.expect(SystemParam.angle.allows(0) and SystemParam.angle.allows(359.5));
    try t.expect(!SystemParam.angle.allows(360) and !SystemParam.angle.allows(-0.5));
    // "$hflip = +1 or -1".
    try t.expect(SystemParam.hflip.allows(-1) and !SystemParam.hflip.allows(0) and !SystemParam.vflip.allows(0.5));
    // "$mfactor > 0".
    try t.expect(SystemParam.mfactor.allows(1e-300) and !SystemParam.mfactor.allows(0) and !SystemParam.mfactor.allows(-2));
    // A NaN is in no stated range.
    try t.expect(!SystemParam.angle.allows(std.math.nan(f64)) and !SystemParam.mfactor.allows(std.math.nan(f64)));
    // "Any" for the coordinates.
    try t.expect(SystemParam.xposition.allows(-1e30) and !SystemParam.xposition.constrained());
    for ([_]SystemParam{ .angle, .hflip, .vflip, .mfactor }) |k| try t.expect(k.constrained());
    try t.expect(SystemParam.vflip.allows(1) and SystemParam.vflip.allows(-1));
    // A diagnostic's domain names the parameter it constrains.
    for (SystemParam.all) |k| try t.expect(!k.constrained() or std.mem.find(u8, k.domain(), k.name()) != null);
}
