//! A model card's values after `derive` -> the checks a host runs on it:
//! `checkShape` (§3.2/§3.4 shape parameters), `checkCard` (§9.18 hierarchical
//! system parameters) and `checkRange` (§3.4 `from`/`exclude` ranges), each
//! naming the first parameter that fails.
//! Cites: §3.2, §3.4, §3.4.2, §9.18.
//!
//! Contents:
//! - `pub fn emitShapeCheck(self: *Gen) Error!void`
//! - `pub fn emitCardCheck(self: *Gen) Error!void`
//! - `pub fn emitRangeCheck(self: *Gen) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_host = @import("host_expr.zig");
const Analysis = @import("prove").Analysis;
const Error = codegen.Error;
const gen_model = @import("model.zig");
const gen_file = @import("file.zig");

/// Emits `checkShape`, which names the first shape parameter
/// (`ParamInfo.shape`, §3.2/§3.4) whose card value differs from the compiled
/// one, or returns null when the card fits. An array bound is laid out in the
/// generated text at compile time, so a card that moves it must be refused.
/// The host calls it after `derive`. No allocation or print, so it is safe in
/// a GPU build. Not emitted when no parameter shapes anything.
pub fn emitShapeCheck(self: *Gen) Error!void {
    assert(self.names.p_names.len == self.lowered.params.items.len);
    const at = self.out.items.len;
    try self.w(
        \\/// §3.4 the shape parameters this device was compiled for: the name of
        \\/// the first one the card (after `derive`) sets to another value, or null.
        \\pub fn checkShape(model: *const Model) ?[]const u8 {{
        \\
    , .{});
    const body = self.out.items.len;
    for (self.lowered.params.items, 0..) |p, i| {
        if (!p.shape) continue;
        const ty = Analysis.tyOfParam(p.ty);
        if (ty == .str) {
            try self.w("    if (!std.mem.eql(u8, model.{s}, {s})) return \"{f}\";\n", .{ self.names.p_names[i], try gen_model.paramDefault(self, p, ty), std.zig.fmtString(p.name) });
            continue;
        }
        // `derive` rewrites a localparam from its default; one that reads no
        // parameter is that constant every time and cannot disagree.
        if (p.is_local and self.an.foldConst(p.default, false) != null) continue;
        // §3.4.1 gives an explicit integer its low 32 bits even when the host
        // writes a wider carrier. Compare the value used by selection; a field
        // the range sized narrower (`intFieldType`) holds it already.
        if (ty == .int and p.integer32 and std.mem.eql(u8, gen_model.intFieldType(self, p), "i64"))
            try self.w("    if (@as(i32, @truncate(model.{s})) != {s}) return \"{f}\";\n", .{ self.names.p_names[i], try gen_model.paramDefault(self, p, ty), std.zig.fmtString(p.name) })
        else
            try self.w("    if (model.{s} != {s}) return \"{f}\";\n", .{ self.names.p_names[i], try gen_model.paramDefault(self, p, ty), std.zig.fmtString(p.name) });
    }
    if (self.out.items.len == body) return self.out.shrinkRetainingCapacity(at);
    try self.w("    return null;\n}}\n\n", .{});
}

/// Emits `checkCard`, which names the first §9.18 hierarchical system
/// parameter whose card-dependent value (`Lowered.system_checks`) lies
/// outside Table 9-29's "Allowed values" ($mfactor > 0, $hflip/$vflip = ±1,
/// 0 <= $angle < 360), or returns null. A literal outside them is E0890 at
/// compile time; this is the same rule for a value the host writes. The host
/// calls it after `derive`. Not emitted when nothing is card-dependent.
pub fn emitCardCheck(self: *Gen) Error!void {
    assert(self.out.items.len != 0);
    const checks = self.lowered.system_checks.items;
    if (checks.len == 0) return;
    var body: std.ArrayList(u8) = .empty;
    for (checks) |c| {
        const v = try gen_host.f64Const(self, c.v, 0, false) orelse {
            if (self.diags) |bag| try bag.add(.codegen, .E1004, .{ .start = 0, .end = 0 }, "the card-time check of `{s}` uses an unsupported expression", .{c.name});
            return error.UnsupportedParameterDefault;
        };
        const out = switch (c.kind) {
            .mfactor => "!(v > 0.0)",
            .hflip, .vflip => "!(v == 1.0 or v == -1.0)",
            .angle => "!(v >= 0.0 and v < 360.0)",
            .xposition, .yposition => unreachable, // `Kind.constrained` records neither
        };
        try body.print(self.arena, "    {{\n        const v: f64 = {s};\n        if ({s}) return \"{f}\";\n    }}\n", .{ v, out, std.zig.fmtString(c.name) });
    }
    try self.w(
        \\/// §9.18 Table 9-29: the first hierarchical system parameter the card
        \\/// (after `derive`) puts outside its allowed values, or null.
        \\pub fn checkCard({s}: *const Model) ?[]const u8 {{
        \\
    , .{if (std.mem.find(u8, body.items, "model.") != null) "model" else "_"});
    try self.w("{s}    return null;\n}}\n\n", .{body.items});
}

/// Emits `checkRange`, which names the first §3.4 parameter whose value (after
/// `derive`) lies in none of its §3.4.2 `from` ranges or in one of its
/// `exclude` ranges, or returns null (#80). "It shall be an error only if the
/// value of the parameter is out of range during simulation": a `#(...)`
/// override is judged at compile time (E0361), a value the host writes on the
/// card only here. A range whose bounds do not fold over literals
/// (`Lowered.Range`), a string-set range and a string parameter are not
/// checked (VD-125). Not emitted when no parameter has a checkable range.
pub fn emitRangeCheck(self: *Gen) Error!void {
    assert(self.names.p_names.len == self.lowered.params.items.len);
    var body: std.ArrayList(u8) = .empty;
    for (self.lowered.params.items, 0..) |p, i| {
        const ty = Analysis.tyOfParam(p.ty);
        if (ty == .str) continue;
        // `inside` ORs the `from` intervals (§3.4.2: several are a union);
        // `excluded` ORs the `exclude` ones. A `from` with an unfoldable bound
        // might admit any value, so it drops the whole `from` test.
        var inside: std.ArrayList(u8) = .empty;
        var excluded: std.ArrayList(u8) = .empty;
        var from_known = true;
        for (p.ranges) |r| {
            if (r.strings) continue;
            const lo = r.lo orelse {
                if (r.kind == .from) from_known = false;
                continue;
            };
            const hi = r.hi orelse {
                if (r.kind == .from) from_known = false;
                continue;
            };
            const list = switch (r.kind) {
                .from => &inside,
                .exclude => &excluded,
            };
            try list.print(self.arena, "{s}(v {s} {s} and v {s} {s})", .{
                if (list.items.len == 0) "" else " or ",
                if (r.lo_inclusive) ">=" else ">",
                try gen_file.fmtF64(self, lo),
                if (r.hi_inclusive) "<=" else "<",
                try gen_file.fmtF64(self, hi),
            });
        }
        if (!from_known) inside.clearRetainingCapacity();
        if (inside.items.len == 0 and excluded.items.len == 0) continue;
        try body.print(self.arena, "    {{\n        const v: f64 = {s}model.{s}{s};\n        if (", .{
            if (ty == .int) "@floatFromInt(" else "", self.names.p_names[i], if (ty == .int) ")" else "",
        });
        if (inside.items.len != 0) try body.print(self.arena, "!({s})", .{inside.items});
        if (inside.items.len != 0 and excluded.items.len != 0) try body.appendSlice(self.arena, " or ");
        try body.print(self.arena, "{s}) return \"{f}\";\n    }}\n", .{ excluded.items, std.zig.fmtString(p.name) });
    }
    if (body.items.len == 0) return;
    try self.w(
        \\/// §3.4.2 the declared `from`/`exclude` ranges: the first parameter the
        \\/// card (after `derive`) puts outside its range, or null.
        \\pub fn checkRange(model: *const Model) ?[]const u8 {{
        \\
    , .{});
    try self.w("{s}    return null;\n}}\n\n", .{body.items});
}
