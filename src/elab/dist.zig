//! §9.13 Table 9-10's probabilistic distributions: one row per source
//! spelling. Read by lowering (`Lower.lowerRandom`) and by elaboration
//! (`rewriteParamsetDist`), which judge the same argument rules.
//!
//! Contents:
//! - `pub const Dist = struct`
//! - `pub const dists`
//! - `pub fn of(name: []const u8) ?*const Dist`
//! - `pub fn paramName(d: *const Dist, i: usize) []const u8`

const std = @import("std");

/// One row of Table 9-10's probabilistic family: the source spelling, the
/// synthetic kernel `rng_kernels.zig` implements, and the argument rules
/// §9.13.1/§9.13.2 state for it.
pub const Dist = struct {
    /// Source spelling, `$` included.
    name: []const u8,
    /// `rng_kernels.zig` entry point.
    kernel: []const u8,
    /// Arguments AFTER the seed. §9.13.1's two take none and their seed is
    /// itself optional; every §9.13.2 distribution requires its seed.
    nparam: u8,
    /// §9.13.2: "$dist_ ... return integer values", "$rdist_ ... All functions
    /// return a real value."
    ty: enum { real, integer },
    /// Bit i set = parameter i "shall be greater than zero (0). Otherwise an
    /// error shall be reported." (§9.13.2 for the $rdist_ family; IEEE 1364
    /// §17.9.2 states the same domain for the integer twins.)
    positive: u8 = 0,
    /// First parameter is df/stages, whose reference algorithm uses a count.
    count: bool = false,
    /// §9.13.2 "The start value shall be smaller than the end value." Only the
    /// uniform pair, and it is a relation between two arguments rather than a
    /// domain on one, which is why it is a separate flag.
    ordered: bool = false,
};

/// Table 9-10, all 16 names. `$simprobe` is §9.16 and stays out.
pub const dists = [_]Dist{
    // §9.13.1. `kernel` is the same for both: "$arandom is upwardly compatible
    // with $random ... and has the same behavior."
    .{ .name = "$random", .kernel = "$rng$rand", .nparam = 0, .ty = .integer },
    .{ .name = "$arandom", .kernel = "$rng$rand", .nparam = 0, .ty = .integer },
    // §9.13.2, the integer family (IEEE 1364 §17.9.2).
    .{ .name = "$dist_uniform", .kernel = "$rng$i_uniform", .nparam = 2, .ty = .integer, .ordered = true },
    .{ .name = "$dist_normal", .kernel = "$rng$normal", .nparam = 2, .ty = .integer },
    .{ .name = "$dist_exponential", .kernel = "$rng$exponential", .nparam = 1, .ty = .integer, .positive = 0b01 },
    .{ .name = "$dist_poisson", .kernel = "$rng$poisson", .nparam = 1, .ty = .integer, .positive = 0b01 },
    .{ .name = "$dist_chi_square", .kernel = "$rng$chi_square", .nparam = 1, .ty = .integer, .positive = 0b01, .count = true },
    .{ .name = "$dist_t", .kernel = "$rng$t", .nparam = 1, .ty = .integer, .positive = 0b01, .count = true },
    .{ .name = "$dist_erlang", .kernel = "$rng$erlang", .nparam = 2, .ty = .integer, .positive = 0b11, .count = true },
    // §9.13.2, the real family.
    .{ .name = "$rdist_uniform", .kernel = "$rng$uniform", .nparam = 2, .ty = .real, .ordered = true },
    .{ .name = "$rdist_normal", .kernel = "$rng$normal", .nparam = 2, .ty = .real },
    .{ .name = "$rdist_exponential", .kernel = "$rng$exponential", .nparam = 1, .ty = .real, .positive = 0b01 },
    .{ .name = "$rdist_poisson", .kernel = "$rng$poisson", .nparam = 1, .ty = .real, .positive = 0b01 },
    .{ .name = "$rdist_chi_square", .kernel = "$rng$chi_square", .nparam = 1, .ty = .real, .positive = 0b01, .count = true },
    .{ .name = "$rdist_t", .kernel = "$rng$t", .nparam = 1, .ty = .real, .positive = 0b01, .count = true },
    .{ .name = "$rdist_erlang", .kernel = "$rng$erlang", .nparam = 2, .ty = .real, .positive = 0b11, .count = true },
};

// The flags agree with each row's arity: at most two parameters (both
// readers fold into a `[2]f64`), `positive` names only parameters the row
// has, `ordered` relates two of them, and a `count` is a positive first one.
comptime {
    for (dists) |d| {
        std.debug.assert(d.nparam <= 2);
        std.debug.assert(d.positive >> @intCast(d.nparam) == 0);
        if (d.ordered) std.debug.assert(d.nparam == 2);
        if (d.count) std.debug.assert(d.positive & 1 != 0);
    }
}

/// Each row's `name` -> its index in `dists`.
const by_name = std.StaticStringMap(u8).initComptime(blk: {
    var kvs: [dists.len]struct { []const u8, u8 } = undefined;
    for (dists, &kvs, 0..) |d, *kv, i| kv.* = .{ d.name, i };
    break :blk kvs;
});

/// The Table 9-10 row `name` spells, or null.
pub fn of(name: []const u8) ?*const Dist {
    return &dists[by_name.get(name) orelse return null];
}

/// The name §9.13.2 gives parameter `i` of `d`, for the diagnostics.
/// Asserts that `i` is a parameter of `d` (`i < d.nparam`): both callers
/// judge the arity first.
pub fn paramName(d: *const Dist, i: usize) []const u8 {
    std.debug.assert(i < d.nparam);
    if (d.ordered) return if (i == 0) "start" else "end";
    if (std.mem.endsWith(u8, d.name, "chi_square") or std.mem.endsWith(u8, d.name, "_t"))
        return "degree_of_freedom";
    if (std.mem.endsWith(u8, d.name, "erlang")) return if (i == 0) "k_stage" else "mean";
    if (std.mem.endsWith(u8, d.name, "normal")) return if (i == 0) "mean" else "standard_deviation";
    return "mean";
}

test of {
    // Table 9-10's sixteen names, each found under its own spelling.
    const names = [_][]const u8{
        "$dist_chi_square",
        "$dist_exponential",
        "$dist_poisson",
        "$dist_uniform",
        "$dist_erlang",
        "$dist_normal",
        "$dist_t",
        "$random",
        "$arandom",
        "$rdist_chi_square",
        "$rdist_exponential",
        "$rdist_poisson",
        "$rdist_uniform",
        "$rdist_erlang",
        "$rdist_normal",
        "$rdist_t",
    };
    try std.testing.expectEqual(names.len, dists.len);
    for (names) |name| try std.testing.expectEqualStrings(name, of(name).?.name);
    // §9.16's `$simprobe` is not a distribution; names are case-sensitive and
    // keep their `$`.
    for ([_][]const u8{ "$simprobe", "$dist", "random", "$RANDOM", "$rdist_t2", "" }) |name|
        try std.testing.expect(of(name) == null);
}

test "dist: §9.13 argument rules, and the integer twins match (IEEE 1364 §17.9.2)" {
    // §9.13.2 Syntax: parameters after the seed, and which "shall be greater
    // than zero": mean, degree_of_freedom and k_stage.
    const want = [_]struct { []const u8, u8, u8, bool, bool }{
        // name, nparam, positive, count, ordered
        .{ "uniform", 2, 0b00, false, true },
        .{ "normal", 2, 0b00, false, false },
        .{ "exponential", 1, 0b01, false, false },
        .{ "poisson", 1, 0b01, false, false },
        .{ "chi_square", 1, 0b01, true, false },
        .{ "t", 1, 0b01, true, false },
        .{ "erlang", 2, 0b11, true, false },
    };
    var buf: [32]u8 = undefined;
    for (want) |w| {
        for ([_][]const u8{ "$rdist_", "$dist_" }, [_]@FieldType(Dist, "ty"){ .real, .integer }) |prefix, ty| {
            const name = try std.mem.print(&buf, "{s}{s}", .{ prefix, w[0] });
            const d = of(name).?;
            errdefer std.debug.print("`{s}`\n", .{name});
            try std.testing.expectEqual(w[1], d.nparam);
            try std.testing.expectEqual(w[2], d.positive);
            try std.testing.expectEqual(w[3], d.count);
            try std.testing.expectEqual(w[4], d.ordered);
            try std.testing.expectEqual(ty, d.ty);
        }
    }
    // §9.13.1: `$arandom` "has the same behavior" as `$random`.
    try std.testing.expectEqualStrings(of("$random").?.kernel, of("$arandom").?.kernel);
    try std.testing.expectEqual(@as(u8, 0), of("$random").?.nparam);
}

test paramName {
    // The argument names §9.13.2's syntax prints.
    const cases = [_]struct { []const u8, usize, []const u8 }{
        .{ "$rdist_uniform", 0, "start" },
        .{ "$dist_uniform", 1, "end" },
        .{ "$rdist_normal", 0, "mean" },
        .{ "$dist_normal", 1, "standard_deviation" },
        .{ "$rdist_exponential", 0, "mean" },
        .{ "$dist_poisson", 0, "mean" },
        .{ "$rdist_chi_square", 0, "degree_of_freedom" },
        .{ "$dist_t", 0, "degree_of_freedom" },
        .{ "$rdist_erlang", 0, "k_stage" },
        .{ "$dist_erlang", 1, "mean" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[2], paramName(of(c[0]).?, c[1]));
}
