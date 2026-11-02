//! VAMS §9.4.1 a `$monitor` latch and §9.5 a latched result are the
//! instance's own: two instances of `fmonitor_lines.va`, whose watched
//! values step at different periods, each `$fmonitor` into their own file,
//! run phase by phase on one thread (every display, then every
//! accepted-point pass, as a circuit runs them); then the two instances
//! are evaluated as the two points of one batch. Oracles: §9.4.1's rule
//! ("the entire argument list is displayed" only when a watched value
//! changes), which fixes each instance's file text by hand, and the bytes
//! it writes alone, single-threaded; for the batch, each point's scalar
//! `eval` over its own instance (contract.zig `batch_inst`). A device with
//! one monitor latch for every instance reports a's line again after b
//! reported, since a then compares against b's values; a batch that reads
//! the first point's latched `$ftell` for every point gives the second
//! point the first one's current.
//! device tests/host/fmonitor_lines.va
//! display emit
//!
//! Contents:
//! - `pub const Batch.V`
//! - `pub const Batch.Of`
//! - `pub const Batch.con`
//! - `pub const Batch.probe`
//! - `pub const Batch.sel`
//! - `pub const Batch.B`
//! - `pub const Batch.Inner`
//! - `pub fn Batch.leadBegin() void`
//! - `pub fn Batch.leadNext() bool`
//! - `pub fn Batch.leadMerge(out: anytype, new: @TypeOf(out.*)) void`
//! - `pub const Core.V`
//! - `pub const Core.Lane`
//! - `pub const Core.lane_count`
//! - `pub fn Core.laneOf(a: B, comptime w: usize) S.Of(0)`
//! - `pub fn Core.fromLanes(comptime _: contract.Mask(D), ls: [W]S.Of(0)) B`
//! - `pub fn Core.decide(comptime op: std.math.CompareOperator, a: B, b: B) bool`
//! - `pub fn Core.decideI(a: B) i64`
//! - `pub fn Core.strip(a: B) B`
//! - `pub fn Core.instLane(comptime T: type, comptime w: usize) *const T`
//! - `pub fn Core.Of(comptime _: contract.Mask(D)) type`
//! - `pub fn Core.con(c: f64) B`
//! - `pub fn Core.probe(comptime _: usize, v: VF) B`
//! - `pub fn Core.sel(c: B, a: B, b: B) B`
//! - `pub const Core.B = struct`
//! - `pub fn Core.B.to(a: B, comptime _: contract.Mask(D)) B`
//! - `pub fn Core.B.val(a: B) f64`
//! - `pub fn Core.B.leadKeep(a: *B, n: B, keep: @Vector(W, bool)) void`
//! - `pub fn Core.B.ddxAt(_: B, comptime _: usize) f64`
//! - `pub fn Core.B.add(a: B, b: B) B`
//! - `pub fn Core.B.sub(a: B, b: B) B`
//! - `pub fn Core.B.neg(a: B) B`
//! - `pub fn Core.B.mul(a: B, b: B) B`
//! - `pub fn Core.B.scale(a: B, c: f64) B`
//! - `pub fn Core.B.addC(a: B, c: f64) B`

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
const S = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});
const steps = 12;
const x0: [n_u]f64 = @splat(0);

/// One instance writing `path`, and the point it is at.
const Inst = struct {
    model: D.Model = .{},
    inst: D.Instance = .{},
    state: D.State = .{},
    k: u32 = 0,

    fn init(id: i64, period: i64, path: []const u8) Inst {
        var r: Inst = .{};
        r.model.id = id;
        r.model.period = period;
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
        while (r.k < steps) {
            r.show();
            r.accept();
        }
    }
};

/// A two-point batch family running the lead protocol (contract.zig
/// `batch_lead`), each point with its own `Instance` (`batch_inst`): the
/// arithmetic `fmonitor_lines.va` needs, element by element.
const W = 2;
const VF = @Vector(W, f64);
var batch_lead: contract.LeadState(W, false) = .{};
var batch_insts: [W]*const D.Instance = undefined;
const Batch = struct {
    pub const V = VF;
    pub const Of = Core.Of;
    pub const con = Core.con;
    pub const probe = Core.probe;
    pub const sel = Core.sel;
    pub const B = Core.B;
    pub const Inner = Core;
    pub fn leadBegin() void {
        batch_lead.begin();
    }
    pub fn leadNext() bool {
        return batch_lead.next();
    }
    pub fn leadMerge(out: anytype, new: @TypeOf(out.*)) void {
        contract.leadMergeInto(out, new, batch_lead.keep());
    }
};
const Core = struct {
    pub const V = VF;
    pub const Lane = S;
    pub const lane_count = W;
    pub fn laneOf(a: B, comptime w: usize) S.Of(0) {
        return S.con(a.v[w]);
    }
    pub fn fromLanes(comptime _: contract.Mask(D), ls: [W]S.Of(0)) B {
        return .{ .v = .{ ls[0].v, ls[1].v } };
    }
    pub fn decide(comptime op: std.math.CompareOperator, a: B, b: B) bool {
        const c: @Vector(W, bool) = switch (op) {
            .lt => a.v < b.v,
            .lte => a.v <= b.v,
            .gt => a.v > b.v,
            .gte => a.v >= b.v,
            .eq => a.v == b.v,
            .neq => a.v != b.v,
        };
        return batch_lead.mark(c);
    }
    pub fn decideI(a: B) i64 {
        return batch_lead.markI(.{ std.math.lossyCast(i64, @round(a.v[0])), std.math.lossyCast(i64, @round(a.v[1])) });
    }
    pub fn strip(a: B) B {
        return a;
    }
    pub fn instLane(comptime T: type, comptime w: usize) *const T {
        comptime std.debug.assert(T == D.Instance);
        return batch_insts[w];
    }
    pub fn Of(comptime _: contract.Mask(D)) type {
        return B;
    }
    pub fn con(c: f64) B {
        return .{ .v = @splat(c) };
    }
    pub fn probe(comptime _: usize, v: VF) B {
        return .{ .v = v };
    }
    pub fn sel(c: B, a: B, b: B) B {
        return .{ .v = @select(f64, c.v != @as(VF, @splat(0)), a.v, b.v) };
    }
    pub const B = struct {
        v: VF,
        pub fn to(a: B, comptime _: contract.Mask(D)) B {
            return a;
        }
        pub fn val(a: B) f64 {
            return a.v[batch_lead.leader];
        }
        pub fn leadKeep(a: *B, n: B, keep: @Vector(W, bool)) void {
            a.v = @select(f64, keep, n.v, a.v);
        }
        pub fn ddxAt(_: B, comptime _: usize) f64 {
            return 0.0;
        }
        pub fn add(a: B, b: B) B {
            return .{ .v = a.v + b.v };
        }
        pub fn sub(a: B, b: B) B {
            return .{ .v = a.v - b.v };
        }
        pub fn neg(a: B) B {
            return .{ .v = -a.v };
        }
        pub fn mul(a: B, b: B) B {
            return .{ .v = a.v * b.v };
        }
        pub fn scale(a: B, c: f64) B {
            return .{ .v = a.v * @as(VF, @splat(c)) };
        }
        pub fn addC(a: B, c: f64) B {
            return .{ .v = a.v + @as(VF, @splat(c)) };
        }
    };
};

// ---- private ----

/// The path of `name` in `tmp`, relative to the cwd the device opens it in.
fn tmpPath(buf: []u8, tmp: *const std.testing.TmpDir, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path[0..], name }) catch unreachable;
}

fn read(tmp: *const std.testing.TmpDir, name: []const u8) ![]u8 {
    return tmp.dir.readFileAlloc(std.testing.io, name, std.testing.allocator, .unlimited);
}

/// The bytes instance (`id`, `period`) writes alone, single-threaded.
fn solo(tmp: *const std.testing.TmpDir, id: i64, period: i64, name: []const u8) ![]u8 {
    var pb: [256]u8 = undefined;
    var r: Inst = .init(id, period, tmpPath(&pb, tmp, name));
    defer D.deinitInstance(&r.inst);
    r.run();
    return read(tmp, name);
}

test "§9.4.1 two instances phase by phase on one thread: each monitor file is its solo bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const want_a = try solo(&tmp, 1, 2, "solo_a.txt");
    defer std.testing.allocator.free(want_a);
    const want_b = try solo(&tmp, 2, 3, "solo_b.txt");
    defer std.testing.allocator.free(want_b);
    // §9.4.1: a line per change of `t / period` over t = 0..11.
    try std.testing.expectEqualStrings("1 0\n1 1\n1 2\n1 3\n1 4\n1 5\n", want_a);
    try std.testing.expectEqualStrings("2 0\n2 1\n2 2\n2 3\n", want_b);

    var pa: [256]u8 = undefined;
    var pb: [256]u8 = undefined;
    var a: Inst = .init(1, 2, tmpPath(&pa, &tmp, "a.txt"));
    defer D.deinitInstance(&a.inst);
    var b: Inst = .init(2, 3, tmpPath(&pb, &tmp, "b.txt"));
    defer D.deinitInstance(&b.inst);
    for (0..steps) |_| {
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
}

test "§9.5.5 a batch of two instances: each point's eval reads its own latched $ftell" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var pa: [256]u8 = undefined;
    var pb: [256]u8 = undefined;
    var a: Inst = .init(1, 2, tmpPath(&pa, &tmp, "a.txt"));
    defer D.deinitInstance(&a.inst);
    var b: Inst = .init(2, 3, tmpPath(&pb, &tmp, "b.txt"));
    defer D.deinitInstance(&b.inst);
    a.run();
    b.run();

    const sim = a.sim();
    var xs: [2][n_u]f64 = .{ x0, x0 };
    xs[0][@backingInt(D.U.p)] = 0.5;
    xs[1][@backingInt(D.U.p)] = 0.25;
    var want: [2][n_u]f64 = undefined;
    for ([_]*const Inst{ &a, &b }, xs, &want) |r, x, *w| {
        const rs: [n_u]S.Of(0) = D.eval(S, &x, &r.model, &r.inst, sim);
        for (rs, w) |v, *o| o.* = v.val();
    }
    // The two files differ in length, so the two currents differ: a point
    // reading the other's position would show.
    try std.testing.expect(want[0][@backingInt(D.U.p)] / 0.5 != want[1][@backingInt(D.U.p)] / 0.25);

    batch_insts = .{ &a.inst, &b.inst };
    var xv: [n_u]Batch.V = undefined;
    for (&xv, 0..) |*v, i| v.* = .{ xs[0][i], xs[1][i] };
    const rv: [n_u]Batch.B = D.eval(Batch, &xv, &a.model, &a.inst, sim);
    for (0..2) |w| for (0..n_u) |i| {
        const got: [2]f64 = rv[i].v;
        try std.testing.expectEqual(want[w][i], got[w]);
    };
}
