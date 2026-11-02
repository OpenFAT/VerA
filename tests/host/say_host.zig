//! §9.4 the display tasks of a DEVICE: `say` and its site table
//! (`contract.SaySite`). A device cannot print, so a host calls `say` at an
//! accepted point (§9.4.6) and renders what it recorded with
//! `contract.formatSay`. The device is
//! tests/conformance/tests/verilog-a/ch09_system_tasks/say_ops.va (its header lists the sites);
//! `zig build test` emits it and runs this file.
//! device tests/verilog-a/ch09_system_tasks/say_ops.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &.{ 0, 1 }, .{});
/// `setup`'s value-only family.
const V = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

fn sayAt(v: f64, out: *contract.Say) void {
    var x: [n_u]f64 = @splat(0.0);
    x[@backingInt(D.U.p)] = v;
    var m: D.Model = .{};
    // `say` reads `su` as `eval` does: `setup` copies the card value the
    // display unit reads (`lim`) beside the derived values.
    if (@hasDecl(D, "setup")) D.setup(V, &m);
    // `say` takes `contract.InstancePtr(D)`, as `eval` does: say_ops's
    // `$error` makes it `mutable_eval`.
    var inst: D.Instance = .{};
    D.say(S, &x, &m, &inst, .{ .t = 1e-9, .dt = 1e-9, .kind = .tran }, out);
}

fn render(out: *contract.Say) ![]const u8 {
    const T = struct {
        var buf: [4096]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&T.buf);
    try contract.formatSay(D, out, "x1", &w);
    return w.buffered();
}

test "say_sites: one C-style format per recorded task, in source order" {
    const want = [_]struct { fmt: []const u8, nargs: u32 }{
        .{ .fmt = "v = %g\n", .nargs = 1 },
        .{ .fmt = "%11d|%5.2f|", .nargs = 2 },
        .{ .fmt = "k=%h\n", .nargs = 1 },
        .{ .fmt = "WARNING: hot %g > %g\n", .nargs = 2 },
        .{ .fmt = "\n", .nargs = 0 },
    };
    try std.testing.expectEqual(want.len, D.say_sites.len);
    for (want, D.say_sites) |w, got| {
        try std.testing.expectEqualStrings(w.fmt, got.fmt);
        try std.testing.expectEqual(w.nargs, got.nargs);
        try std.testing.expect(std.mem.endsWith(u8, got.file, "say_ops.va"));
    }
    try std.testing.expectEqual(@as(u32, 19), D.say_sites[0].line);
}

test "say: the tasks that run are recorded, a guarded one only when its arm runs" {
    var store: [64]f64 = undefined;
    var out: contract.Say = .{ .buf = &store };
    sayAt(0.5, &out);
    // The printing artifact's order: a guarded task where its arm is, the
    // unconditional ones at the end of the block.
    try std.testing.expectEqualStrings("v = 0.5\n          3| 0.50|k=ff\n\n", try render(&out));
    sayAt(2.0, &out);
    try std.testing.expectEqualStrings("WARNING: hot 2 > 1\nv = 2\n          3| 0.50|k=ff\n\n", try render(&out));
}

test "say: a record that does not fit is counted, never cut" {
    var store: [4]f64 = undefined;
    var out: contract.Say = .{ .buf = &store };
    sayAt(0.5, &out);
    // `v = %g` (2 values) fits, `%11d|%5.2f|` (3) does not, `k=%h` (2) fits,
    // the bare newline (1) does not.
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expectEqual(@as(usize, 2), out.lost);
    try std.testing.expectEqualStrings("v = 0.5\nk=ff\n[2 display record(s) did not fit the host's buffer]\n", try render(&out));
}
