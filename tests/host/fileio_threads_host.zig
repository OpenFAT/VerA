//! VAMS §9.5.1.2 a printing device keeps one descriptor table per instance:
//! two instances of `fileio_lines.va` each `$fopen` their own file and
//! `$fdisplay` `lines` numbered lines into it, interleaved phase by phase on
//! one thread (every display, then every accepted-point pass, as a circuit
//! runs them) and then on two threads at once. Oracle: the bytes one instance writes when
//! it runs alone, single-threaded (each file must be those bytes exactly),
//! and §9.5.1's numbering (each instance's table hands out fd 3 first, so
//! two instances share every descriptor number and only the table tells
//! their files apart). A device with one table and one latched result for
//! every instance holds b's descriptor in a, which then writes into b's
//! file; one with one formatting row per call site for every thread
//! interleaves the two threads' text.
//! device tests/host/fileio_lines.va
//! display emit

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});
const lines = 10_000;
const fd3: i64 = (1 << 31) | 3;
const x0: [n_u]f64 = @splat(0);

/// One instance writing `path`, and the point it is at.
const Inst = struct {
    model: D.Model = .{},
    inst: D.Instance = .{},
    state: D.State = .{},
    k: u32 = 0,

    fn init(id: i64, path: []const u8) Inst {
        var r: Inst = .{};
        r.model.id = id;
        r.model.path = path;
        if (@hasDecl(D, "setup")) D.setup(S, &r.model);
        if (@hasDecl(D, "setupInstance")) D.setupInstance(&r.model, &r.inst);
        r.state = D.initState(&r.model, &r.inst);
        return r;
    }

    /// The display phase of the accepted point at t = k.
    fn show(r: *Inst) void {
        D.display(S, &x0, &r.model, &r.inst, r.sim());
    }

    /// The accepted-point pass after it, which holds `fd` (§5.10), and the
    /// step to the next point.
    fn accept(r: *Inst) void {
        _ = D.updateState(S, &r.model, &r.inst, x0, &r.state, r.sim());
        _ = D.stateCtl(&r.model, &r.inst, &r.state, .commit);
        r.k += 1;
    }

    fn sim(r: *const Inst) contract.SimState {
        return .{ .kind = .tran, .t = @floatFromInt(r.k), .initial_step = r.k == 0 };
    }

    fn run(r: *Inst) void {
        while (r.k < lines) {
            r.show();
            r.accept();
        }
    }
};

/// The path of `name` in `tmp`, relative to the cwd the device opens it in.
fn tmpPath(buf: []u8, tmp: *const std.testing.TmpDir, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name }) catch unreachable;
}

fn read(tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .unlimited);
}

/// The bytes instance `id` writes alone, single-threaded.
fn solo(tmp: *const std.testing.TmpDir, id: i64, name: []const u8) ![]u8 {
    var pb: [256]u8 = undefined;
    var r: Inst = .init(id, tmpPath(&pb, tmp, name));
    defer D.deinitInstance(&r.inst);
    r.run();
    return read(tmp, name);
}

test "two instances phase by phase on one thread: each file is its solo bytes, each table its own numbers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const want_a = try solo(&tmp, 1, "solo_a.txt");
    defer std.testing.allocator.free(want_a);
    const want_b = try solo(&tmp, 2, "solo_b.txt");
    defer std.testing.allocator.free(want_b);
    try std.testing.expect(std.mem.startsWith(u8, want_a, "1 0\n1 1\n"));
    try std.testing.expectEqual(lines, std.mem.count(u8, want_b, "\n"));

    var pa: [256]u8 = undefined;
    var pb: [256]u8 = undefined;
    var a: Inst = .init(1, tmpPath(&pa, &tmp, "a.txt"));
    defer D.deinitInstance(&a.inst);
    var b: Inst = .init(2, tmpPath(&pb, &tmp, "b.txt"));
    defer D.deinitInstance(&b.inst);
    // A circuit's accepted point: every instance's display phase, then
    // every instance's accepted-point pass.
    for (0..lines) |_| {
        a.show();
        b.show();
        a.accept();
        b.accept();
    }
    const got_a = try read(&tmp, "a.txt");
    defer std.testing.allocator.free(got_a);
    const got_b = try read(&tmp, "b.txt");
    defer std.testing.allocator.free(got_b);
    try std.testing.expectEqualStrings(want_a, got_a);
    try std.testing.expectEqualStrings(want_b, got_b);

    // Each instance opened fd 3 in its own table, so the next is 4 in both.
    var pc: [256]u8 = undefined;
    inline for (.{ &a, &b }, .{ "c_a.txt", "c_b.txt" }) |r, name| {
        const t = contract.fileIo(D, &r.inst).?;
        try std.testing.expectEqual(fd3 + 1, t.open(t.ctx, tmpPath(&pc, &tmp, name), "w", false));
    }
}

test "two instances on two threads: each file is its solo bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const want_a = try solo(&tmp, 1, "solo_a.txt");
    defer std.testing.allocator.free(want_a);
    const want_b = try solo(&tmp, 2, "solo_b.txt");
    defer std.testing.allocator.free(want_b);

    var pa: [256]u8 = undefined;
    var pb: [256]u8 = undefined;
    var a: Inst = .init(1, tmpPath(&pa, &tmp, "a.txt"));
    defer D.deinitInstance(&a.inst);
    var b: Inst = .init(2, tmpPath(&pb, &tmp, "b.txt"));
    defer D.deinitInstance(&b.inst);
    const ta = try std.Thread.spawn(.{}, Inst.run, .{&a});
    const tb = try std.Thread.spawn(.{}, Inst.run, .{&b});
    ta.join();
    tb.join();
    const got_a = try read(&tmp, "a.txt");
    defer std.testing.allocator.free(got_a);
    const got_b = try read(&tmp, "b.txt");
    defer std.testing.allocator.free(got_b);
    try std.testing.expectEqualStrings(want_a, got_a);
    try std.testing.expectEqualStrings(want_b, got_b);
}
