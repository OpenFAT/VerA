//! The decided helper blocks (`file.Features`) and the kernel text -> the
//! split build's shared text: `Output.prelude`, the file-scope prologue every
//! `u/<key>.zig` unit file opens with (aliases of device.zig's helpers), and
//! `Output.helpers`, `h.zig`, the kernels made public so unit files reach them.
//! Cites: none (build orchestration of the text `emitFile` writes).
//!
//! Contents:
//! - `pub fn wideText(self: *Gen, txt: []const u8) Error![]const u8`
//! - `pub fn buildPrelude(self: *Gen, f: gen_file.Features) Error!void`
//! - `pub fn depublish(gpa: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void`
//! - `pub fn publish(arena: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const codegen = @import("../codegen.zig");
const kt = @import("kernel_text.zig");
const gen_mask = @import("mask.zig");
const Gen = codegen.Gen;
const gen_unit = @import("unit.zig");
const Error = codegen.Error;
const gen_file = @import("file.zig");

/// `txt` with its masks typed `contract.MaskOf(n_u)`: `txt` itself up to 64
/// unknowns, whose masks are the `u64` it is written in; past them, every
/// `u64` mask parameter widened and the two "past 64, every lane" fallbacks
/// gone, since each unknown has its own bit. Arena-owned.
pub fn wideText(self: *Gen, txt: []const u8) Error![]const u8 {
    assert(self.mw >= 1);
    assert(txt.len != 0);
    if (self.mw == 1) return txt;
    var tb: [16]u8 = undefined;
    const ty = gen_mask.typeName(&tb, self.names.n_u);
    const pairs = [_][2][]const u8{
        .{ "comptime m: u64", try self.arena.print("comptime m: {s}", .{ty}) },
        .{ "comptime _: u64", try self.arena.print("comptime _: {s}", .{ty}) },
        .{ "if (u < 64) @as(u64, 1) << u else ~@as(u64, 0)", try self.arena.print("@as({s}, 1) << u", .{ty}) },
        .{ "comptime u >= 64 or (zdr >> u) & 1 != 0", "comptime (zdr >> u) & 1 != 0" },
    };
    var out = txt;
    for (pairs) |pr| out = try std.mem.replaceOwned(u8, self.arena, out, pr[0], pr[1]);
    return out;
}

/// Builds `Output.prelude` (the file-scope prologue of a `u/<key>.zig`) and
/// `Output.helpers` (`h.zig`). Unit files alias the helpers rather than
/// re-emitting them, so `zig` analyses each once. The aliases are gated on the
/// same `Features` `emitFile` uses, so none names a missing decl.
pub fn buildPrelude(self: *Gen, f: gen_file.Features) Error!void {
    assert(self.prelude.len == 0);
    assert(self.helpers.len == 0);
    var p: std.ArrayList(u8) = .empty;
    try p.appendSlice(self.arena, kt.prelude_head_txt);
    const alias = kt.appendAliases;
    try alias(&p, self.arena, kt.math_txt);
    try alias(&p, self.arena, kt.ops_txt);
    try alias(&p, self.arena, kt.family_txt);
    if (f.timer) try alias(&p, self.arena, kt.timer_txt);
    if (f.hist) try alias(&p, self.arena, kt.hist_txt);
    if (f.hist_quad) try alias(&p, self.arena, kt.hist_quad_txt);
    if (f.arrs) try alias(&p, self.arena, kt.arr_txt);
    if (f.tp) try alias(&p, self.arena, kt.tp_txt);
    if (f.tp_arr) try alias(&p, self.arena, kt.tp_arr_txt);
    if (f.filt) try alias(&p, self.arena, kt.filt_txt);
    if (f.ac) try alias(&p, self.arena, kt.ac_txt);
    if (f.strs) try alias(&p, self.arena, kt.display_txt);
    if (f.strs) try alias(&p, self.arena, kt.str_txt);
    if (f.files) try alias(&p, self.arena, kt.file_txt);
    if (f.tbl) try alias(&p, self.arena, kt.table_txt);
    if (f.rng) try alias(&p, self.arena, kt.rng_txt);
    // The shared core is a unit file beside the units that call it, and
    // device.zig's alias for it is private. Spelled `core`, not the structural
    // key, so the core's own file (same prologue) does not redeclare its name;
    // a file importing itself is legal and, unreferenced, never analysed.
    if (self.core.name.len != 0)
        try p.print(self.arena, "const core = @import(\"{0s}.zig\").{0s};\n", .{self.core.name});
    // §4.5.11/§4.5.12 the `pub fn <unit>__sec` readers live in device.zig
    // (`unit.emitUnits`), so a unit calling one reads it through `dev`.
    for (self.names.units, 0..) |_, i| {
        if (gen_unit.filterSec(self, i) == null) continue;
        try p.print(self.arena, "const {0s}__sec = dev.{0s}__sec;\n", .{self.names.unit_names[i]});
    }
    try p.appendSlice(self.arena, "\n");
    self.prelude = p.items;

    var hz: std.ArrayList(u8) = .empty;
    try hz.appendSlice(self.arena, kt.helpers_head_txt);
    try publish(self.arena, &hz, kt.math_txt);
    try publish(self.arena, &hz, if (self.display == .emit) kt.domain_report_txt else kt.domain_quiet_txt);
    try publish(self.arena, &hz, kt.ops_txt);
    try hz.appendSlice(self.arena, "const zdr = contract.derivReads(@import(\"device.zig\"));\n");
    try publish(self.arena, &hz, try wideText(self, kt.family_txt));
    if (f.timer) try publish(self.arena, &hz, kt.timer_txt);
    if (f.hist) try publish(self.arena, &hz, kt.hist_txt);
    if (f.hist_quad) try publish(self.arena, &hz, kt.hist_quad_txt);
    if (f.arrs) try publish(self.arena, &hz, kt.arr_txt);
    if (f.tp) try publish(self.arena, &hz, kt.tp_txt);
    if (f.tp_arr) try publish(self.arena, &hz, kt.tp_arr_txt);
    if (f.filt) try publish(self.arena, &hz, kt.filt_txt);
    if (f.ac) try publish(self.arena, &hz, kt.ac_txt);
    if (f.strs) try publish(self.arena, &hz, kt.display_txt);
    if (f.strs) try publish(self.arena, &hz, kt.str_txt);
    if (f.files) try publish(self.arena, &hz, kt.file_txt);
    if (f.tbl) try publish(self.arena, &hz, kt.table_txt);
    if (f.rng) try publish(self.arena, &hz, kt.rng_txt);
    self.helpers = hz.items;
}

/// Copies `src` into `out` with each leading `pub ` dropped, so an embedded
/// Zig file can be spliced into device.zig. The inverse of `publish`.
pub fn depublish(gpa: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void {
    const len_before = out.items.len;
    defer assert(out.items.len >= len_before);
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.appendSlice(gpa, if (std.mem.startsWith(u8, line, "pub ")) line[4..] else line);
    }
}

/// Copies `src` into `out`, making each top-level `fn`/`const` public. The
/// same text is private in device.zig, where the contract forbids stray
/// public names, and public in `h.zig`, where the unit files reach it.
pub fn publish(arena: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void {
    const len_before = out.items.len;
    defer assert(out.items.len >= len_before);
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        if (kt.declKeyword(line) != null) try out.appendSlice(arena, "pub ");
        try out.appendSlice(arena, line);
    }
}

// ---- private ----

test depublish {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // Only a leading `pub ` goes: a nested one is the kernel's own business.
    try depublish(gpa, &out, "pub fn a() void {}\npub const b = 1;\n    pub const c = 2;\nconst d = 3;");
    try std.testing.expectEqualStrings("fn a() void {}\nconst b = 1;\n    pub const c = 2;\nconst d = 3;", out.items);
}

test publish {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // Every top-level `fn`/`const` gains `pub`; a `var`, an indented line and
    // an already public one are left as they are.
    try publish(gpa, &out, "fn a() void {}\nconst b = 1;\nvar c = 2;\n    const d = 3;\npub fn e() void {}");
    try std.testing.expectEqualStrings("pub fn a() void {}\npub const b = 1;\nvar c = 2;\n    const d = 3;\npub fn e() void {}", out.items);
}
