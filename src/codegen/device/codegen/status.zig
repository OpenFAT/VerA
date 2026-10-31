//! The §9.7.3 `$fatal`/`$error` calls a device reports as a status
//! (`Lowered.status`) -> `status_sites`, the `Instance` latch, `zStatusStore`
//! (which `eval`, `q` and `evalQ` call on the core result) and the source line
//! each site names.
//! Cites: §9.7.3.
//!
//! Contents:
//! - `pub const status_drop`
//! - `pub fn hasStatus(self: *const Gen) bool`
//! - `pub fn emitStatusHelpers(self: *Gen) Error!void`
//! - `pub fn srcLine(self: *const Gen, tok: u32) struct { file: []const u8, line: u32 }`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_dispatch = @import("dispatch.zig");
const gen_file = @import("file.zig");
const Lowered = @import("ir").Lowered;
const Mir = @import("ir").Mir;
const Error = codegen.Error;

/// §9.7.3 `initState` and `setupInstance` clear a latched status (a `w` format).
pub const status_drop = "    inst.vera_status__ = 0;\n    inst.vera_status_args__ = @splat(0.0);\n";

/// Whether the device reports §9.7.3 `$fatal`/`$error` as a status
/// (`Lowered.status`): a printing artifact runs them in its display chain.
pub fn hasStatus(self: *const Gen) bool {
    assert(self.display == .emit or self.display == .record or self.display == .drop);
    return self.display != .emit and self.lowered.status != .undef;
}

/// §9.7.3 `status_sites`, `zStatusStore` (which `eval`, `q` and `evalQ` call
/// on the core result: the first status reported sticks) and `status_drop`
/// (`initState`, `setup`).
pub fn emitStatusHelpers(self: *Gen) Error!void {
    assert(self.out.items.len != 0);
    if (!hasStatus(self)) return;
    try self.w(
        \\/// §9.7.3 every `$fatal`/`$error` in the analog context: a device cannot
        \\/// print or stop its host, so the first one an evaluation reaches latches
        \\/// `Instance.vera_status__` (`contract.formatStatus` renders it), and
        \\/// from then on `eval`, `q` and `evalQ` return all-zero rows and
        \\/// `updateState` leaves the state alone.
        \\pub const status_sites = [_]contract.StatusSite{{
        \\
    , .{});
    for (self.lowered.status_sites.items) |s| {
        const at = srcLine(self, s.tok);
        try self.w("    .{{ .severity = .{s}, .fmt = \"{f}\", .file = \"{f}\", .line = {d} }},\n", .{
            if (s.fatal) "fatal" else "@\"error\"", std.zig.fmtString(s.fmt), std.zig.fmtString(at.file), at.line,
        });
    }
    try self.w("}};\n\n", .{});
    const code = try statusVal(self, self.lowered.status);
    // The `.{ }` below spells four arguments.
    comptime std.debug.assert(Lowered.status_arg_max == 4);
    var args: [Lowered.status_arg_max][]const u8 = undefined;
    var reads_m = std.mem.startsWith(u8, code, "m.");
    for (&args, self.lowered.status_args) |*s, a| {
        s.* = try statusVal(self, a);
        reads_m = reads_m or std.mem.startsWith(u8, s.*, "m.");
    }
    try self.w("/// §9.7.3 latch the first status reported; later ones change nothing.\n", .{});
    try self.w("inline fn zStatusStore(inst: *Instance, {s}: anytype) void {{\n", .{if (reads_m) "m" else "_"});
    try self.w("    if (inst.vera_status__ != 0) return;\n", .{});
    try self.w("    const code: f64 = {s};\n", .{code});
    try self.w("    if (code == 0.0) return;\n    inst.vera_status__ = @intFromFloat(code);\n", .{});
    try self.w("    inst.vera_status_args__ = .{{ {s}, {s}, {s}, {s} }};\n}}\n\n", .{ args[0], args[1], args[2], args[3] });
    // Every charge zero, value and derivative lanes, as `zRowsZero` does
    // for the rows. Unreferenced (so unanalysed) without a reactive half.
    try self.w(
        \\fn zSitesZero(comptime S: type) contract.Sites(Self, S) {{
        \\    var r: contract.Sites(Self, S) = undefined;
        \\    inline for (0..contract.nQ(Self)) |k| r[k] = zTo(S, contract.siteMask(Self, k), S.con(0.0));
        \\    return r;
        \\}}
        \\
        \\
    , .{});
}

/// The source file and 1-based line of token `tok`, through the diagnostic
/// bag's source map (an `include`d file names itself). Empty and 0 when
/// codegen runs without a bag.
pub fn srcLine(self: *const Gen, tok: u32) struct { file: []const u8, line: u32 } {
    assert(tok != Mir.no_tok);
    const bag = self.diags orelse return .{ .file = "", .line = 0 };
    if (tok >= self.lowered.tok_starts.len) return .{ .file = "", .line = 0 };
    const start = self.lowered.tok_starts[tok];
    const at = bag.locate(.{ .start = start, .end = start }, null);
    const off = bag.toSourceOffset(at.file, at.offset);
    const text = bag.sourceText(at.file);
    return .{
        .file = bag.fileName(at.file),
        .line = @intCast(1 + std.mem.count(u8, text[0..@min(off, text.len)], "\n")),
    };
}

// ---- private ----

/// The core result's spelling of status value `v`: its field, its folded
/// constant, or 0 for an argument the site never set.
fn statusVal(self: *Gen, v: Mir.Value) Error![]const u8 {
    assert(hasStatus(self)); // Only `emitStatusHelpers` asks, past its gate.
    if (v == .undef) return "0.0";
    if (self.an.foldConst(v, false)) |c| return gen_file.fmtF64(self, c);
    const k = gen_dispatch.coreIdx(self, self.an.rv(v)).?;
    return self.arena.print("m.f{d}.val()", .{k});
}
