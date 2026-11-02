//! §2.9 VerA's `vera_timepoint` over a §5.10 held history in a DEVICE:
//! tests/conformance/tests/verilog-a/ch05_analog_behavior/vera_timepoint_held_history.va, the
//! shape of ESPice's lossy lines (#82). Its statement commits the point
//! accepted last into two 2048-deep held arrays, and `eval` writes them
//! straight into the cache slot instead of a local copy. Checked here: the
//! values through a miss and a hit (the fixture's hand derivation), and,
//! from `tphist_gpu.zig`'s PTX (`@import("ptx")`, built by `zig build test`),
//! that no NVPTX function keeps a copy of the history on its stack.
//! device tests/verilog-a/ch05_analog_behavior/vera_timepoint_held_history.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");
const ptx = @import("ptx");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &.{ 0, 1 }, .{});
const S0 = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

/// `I(p, n)` at V = 0 is `1u * s`, the cached sum of the history.
fn sumAt(m: *const D.Model, inst: *D.Instance, sim: contract.SimState) f64 {
    const x: [n_u]f64 = @splat(0.0);
    const r = D.eval(S, &x, m, inst, sim);
    return @abs(r[@backingInt(D.U.p)].v) / 1e-6;
}

test "§2.9 a cached statement's held history reads back through a miss and a hit" {
    var m: D.Model = .{};
    if (@hasDecl(D, "derive")) D.derive(f64, &m);
    if (@hasDecl(D, "setup")) D.setup(S0, &m);
    const inst = try std.testing.allocator.create(D.Instance);
    defer std.testing.allocator.destroy(inst);
    inst.* = .{};
    const st = try std.testing.allocator.create(D.State);
    defer std.testing.allocator.destroy(st);
    st.* = D.initState(&m, inst);
    if (@hasDecl(D, "setupInstance")) D.setupInstance(&m, inst);
    const x: [n_u]f64 = @splat(0.0);
    // The fixture's grid t_k = k/2: s = t (2t - 1) = 0, 0, 1, 3, 6.
    const want = [_]f64{ 0, 0, 1, 3, 6 };
    for (want, 0..) |s, k| {
        const t = @as(f64, @floatFromInt(k)) / 2.0;
        const sim: contract.SimState = .{ .t = t, .dt = if (k == 0) 0 else 0.5, .kind = .tran, .initial_step = k == 0, .analog_initial = k == 0 };
        var it = sim;
        try std.testing.expectEqual(s, sumAt(&m, inst, it)); // the miss: the statement runs
        it.iteration = 2;
        try std.testing.expectEqual(s, sumAt(&m, inst, it)); // the hit: read back
        try std.testing.expect(D.updateState(S, &m, inst, x, st, sim) == .ok);
        _ = D.stateCtl(&m, inst, st, .commit);
    }
}

/// Largest `.local` depot of any function in `text` (PTX), in bytes.
fn maxDepot(text: []const u8) usize {
    var best: usize = 0;
    var at: usize = 0;
    const key = "__local_depot";
    while (std.mem.findPos(u8, text, at, key)) |i| : (at = i + key.len) {
        const open = std.mem.findScalarPos(u8, text, i, '[') orelse break;
        const close = std.mem.findScalarPos(u8, text, open, ']') orelse break;
        const n = std.fmt.parseInt(usize, text[open + 1 .. close], 10) catch continue;
        best = @max(best, n);
    }
    return best;
}

test "#82 eval keeps no copy of a cached history on the GPU stack" {
    const io = std.testing.io;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, ptx.path, std.testing.allocator, .limited(64 << 20));
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.find(u8, text, "tphist_ops_kernel") != null);
    // One copy of one history array is 16384 B; before #82 eval kept two
    // copies of both (65.5 KB). What is left is the dual-number frame.
    const one_copy = 2048 * @sizeOf(f64);
    const depot = maxDepot(text);
    if (depot >= one_copy / 4) {
        std.debug.print("largest NVPTX .local depot {d} B\n", .{depot});
        return error.TestUnexpectedResult;
    }
}
