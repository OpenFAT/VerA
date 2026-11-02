//! The `lib/contract.zig` declarations Part 3 of the book quotes or names,
//! pinned: each test fails when the contract renames a declaration a page
//! names, or changes the fields, tags or defaults a page shows.
//! tools/doctest.py runs it through shapes.out on every push.
//!
//! Contents:
//! - `pub const Dev.U = enum`

const std = @import("std");
const contract = @import("contract");

/// A stand-in device: the table types are generic over `D.U`.
const Dev = struct {
    pub const U = enum(u8) { a, b };
};

// ---- private ----

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try std.testing.expectEqualStrings(w, g);
}

/// `T`'s fields (struct, union) or tags (enum), in declaration order.
fn expectNames(comptime T: type, want: []const []const u8) !void {
    const got = comptime std.meta.fieldNames(T);
    var names: [got.len][]const u8 = undefined;
    for (got, &names) |g, *n| n.* = g;
    try expectStrings(want, &names);
}

test "every contract declaration the pages name exists" {
    inline for (.{
        "vera_version", "validating",   "validate",     "validateHost",    "nU",
        "RefFamily",    "RefOptions",   "no_lane",      "family_fns",      "family_primitives",
        "checkFamily",  "expectFamily", "derivReads",   "ddxReads",        "Mask",
        "MaskOf",       "rowMask",      "jacConst",     "jacConstApplies", "JacConst",
        "LaneUse",      "Constant",     "Rows",         "Sites",           "InstancePtr",
        "SimState",     "AnalysisKind", "UpdateResult", "StateClass",      "stateClass",
        "StateCtlOp",   "LimitResult",  "QStamp",       "nQ",              "qStamps",
        "qLte",         "qRowMask",     "qRows",        "NoiseGen",        "PsdTerm",
        "NoiseTable",   "noiseTableAt", "AcGen",        "AcPhasor",        "UnknownKind",
        "SystfHost",    "FileIo",       "DeclMeta",     "Say",             "SayPass",
        "formatSay",    "StatusSite",   "formatStatus", "LeadState",       "leadMergeInto",
        "leads",        "instLanes",    "region",       "DevicePart",      "gm",
    }) |name| {
        if (!@hasDecl(contract, name)) {
            std.debug.print("contract.zig has no `{s}`\n", .{name});
            return error.Missing;
        }
    }
}

test "device.md: SimState, AnalysisKind" {
    try expectNames(contract.SimState, &.{ "t", "dt", "kind", "initial_step", "final_step", "analog_initial", "iteration" });
    try std.testing.expectEqual(contract.SimState{
        .t = 0,
        .dt = 0,
        .kind = .dc,
        .initial_step = false,
        .final_step = false,
        .analog_initial = true,
        .iteration = 1,
    }, contract.SimState{});
    try expectNames(contract.AnalysisKind, &.{ "static", "ic", "nodeset", "dc", "tran", "ac", "noise" });
}

test "families.md: family_fns, family_primitives, JacConst, LaneUse, Constant, RefOptions" {
    try expectStrings(&.{ "Of", "V", "con", "probe", "sel" }, &contract.family_fns);
    try expectStrings(&.{
        "addC",  "scale", "add",  "sub", "neg", "mul",   "div",  "exp",  "log",
        "expm1", "log1p", "sqrt", "pow", "sin", "cos",   "tanh", "sinh", "cosh",
        "atan",  "lt",    "le",   "eq",  "val", "ddxAt", "to",
    }, &contract.family_primitives);
    try expectNames(contract.JacConst(Dev.U), &.{ "row", "col", "g", "c", "when" });
    try expectNames(contract.LaneUse, &.{ "mask", "uses" });
    try expectNames(contract.Constant, &.{ "g", "c" });
    try expectNames(contract.RefOptions, &.{"collapse_applied"});
}

test "state.md: StateClass, UpdateResult, StateCtlOp, QStamp, LimitResult" {
    try expectNames(contract.StateClass, &.{ "none", "path_latch", "history" });
    try expectNames(contract.UpdateResult, &.{ "ok", "request_reject_at" });
    try std.testing.expect(@FieldType(contract.UpdateResult, "request_reject_at") == f64);
    try expectNames(contract.StateCtlOp, &.{ "query", "commit", "revert" });
    try expectNames(contract.QStamp(Dev.U), &.{ "site", "row", "sign" });
    try expectNames(contract.LimitResult(2), &.{ "x", "converged" });
}

test "tables.md: NoiseGen, PsdTerm, NoiseTable, AcGen, AcPhasor, UnknownKind" {
    try expectNames(contract.NoiseGen(Dev), &.{ "row", "col", "kind", "source", "table", "name" });
    try expectNames(@FieldType(contract.NoiseGen(Dev), "kind"), &.{ "thermal", "shot", "flicker", "table" });
    try expectNames(contract.PsdTerm, &.{ "white", "flicker", "ef", "corr_with", "corr", "coeff" });
    try std.testing.expectEqual(
        contract.PsdTerm{ .white = 0, .flicker = 0, .ef = 1, .corr_with = null, .corr = 0, .coeff = 1 },
        contract.PsdTerm{ .white = 0 },
    );
    try expectNames(contract.NoiseTable, &.{ "interp", "points" });
    try expectNames(contract.AcGen(Dev), &.{ "row", "col", "name" });
    try std.testing.expectEqual(contract.AcPhasor{ .mag = 1, .phase = 0 }, contract.AcPhasor{});
    try expectNames(contract.UnknownKind, &.{ "voltage", "current", "flow" });
    try expectNames(contract.DeclMeta, &.{ "kind", "name", "desc", "units" });
}

test "linking.md: DevicePart" {
    try expectNames(contract.DevicePart, &.{ "setup", "state", "eval" });
}
