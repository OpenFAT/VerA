//! §9.7.3 `$fatal`/`$error` in a DEVICE: the status channel
//! (`contract.StatusSite`). A device cannot print or stop its host, so the
//! first site an evaluation reaches latches `Instance.vera_status__` and its
//! numeric arguments; from then on `eval`, `q` and `evalQ` return all-zero rows
//! and charges, value and every derivative lane, and `updateState` leaves the
//! state alone, until `initState` clears it. The device is tests/conformance/tests/verilog-a/ch09_system_tasks/status_ops.va
//! (its header lists the sites); `zig build test` emits it and runs this file.
//! device tests/verilog-a/ch09_system_tasks/status_ops.va

const std = @import("std");
const contract = @import("contract");
const D = @import("device");

const n_u = @typeInfo(D.U).@"enum".field_names.len;
/// Every unknown in a lane, so a zeroed row is checked in its derivatives too.
const S = contract.RefFamily(f64, &.{ 0, 1 }, .{});
const S0 = contract.RefFamily(f64, &@as([n_u]u8, @splat(contract.no_lane)), .{});

fn x(v: f64) [n_u]f64 {
    var out: [n_u]f64 = @splat(0.0);
    out[@backingInt(D.U.p)] = v;
    return out;
}

fn sim(initial: bool) contract.SimState {
    return .{ .t = if (initial) 0 else 1e-9, .dt = if (initial) 0 else 1e-9, .kind = if (initial) .dc else .tran, .initial_step = initial, .analog_initial = initial };
}

/// Whether every row of `r` is zero in its value and every lane.
fn allZero(r: anytype) bool {
    inline for (r) |e| {
        if (e.v != 0.0) return false;
        inline for (0..n_u) |u| if (e.ddxAt(u) != 0.0) return false;
    }
    return true;
}

fn evalAt(m: *const D.Model, inst: *D.Instance, v: f64, initial: bool) contract.Rows(D, S) {
    const xv = x(v);
    return D.eval(S, &xv, m, inst, sim(initial));
}

/// `initState`, then `setup` and `setupInstance` (the card and instance are
/// fresh): `initState` and `setupInstance` both clear a latched status.
fn start(m: *D.Model, inst: *D.Instance) D.State {
    const st = D.initState(m, inst);
    if (@hasDecl(D, "setup")) D.setup(S0, m);
    D.setupInstance(m, inst);
    return st;
}

/// `got` is `want` after the file's directory, which depends on how the
/// build named the source.
fn expectMessage(want: []const u8, got: []const u8) !void {
    if (std.mem.endsWith(u8, got, want) and (got.len == want.len or std.fs.path.isSep(got[got.len - want.len - 1]))) return;
    std.debug.print("want …{s}\n got {s}\n", .{ want, got });
    return error.TestUnexpectedResult;
}

fn render(inst: *const D.Instance) ![]const u8 {
    const T = struct {
        var buf: [4096]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&T.buf);
    try contract.formatStatus(D, inst, &w);
    return w.buffered();
}

test "status: an $error latches its site and arguments, and zeroes every row until initState" {
    var m: D.Model = .{};
    m.mode = 1;
    var inst: D.Instance = .{};
    var st = start(&m, &inst);

    // Below the limit: no status, and the rows are the device's.
    try std.testing.expect(!allZero(evalAt(&m, &inst, 0.5, false)));
    try std.testing.expectEqual(@as(u32, 0), inst.vera_status__);

    // Above it: site 2 latches with V(p,n) = 2 and lim = 1, and this very
    // evaluation already returns the zero plane.
    try std.testing.expect(allZero(evalAt(&m, &inst, 2.0, false)));
    try std.testing.expectEqual(contract.statusCode(.@"error", 2), inst.vera_status__);
    try std.testing.expectEqual([4]f64{ 2.0, 1.0, 0.0, 0.0 }, inst.vera_status_args__);
    try expectMessage("status_ops.va:23: error: V(p,n) = 2 exceeds 1", try render(&inst));

    // Sticky: back below the limit, still zero, through every entry point.
    try std.testing.expect(allZero(evalAt(&m, &inst, 0.5, false)));
    const xv = x(0.5);
    try std.testing.expect(allZero(D.q(S, &xv, &m, &inst, sim(false))));
    const both = D.evalQ(S, &xv, &m, &inst, sim(false));
    try std.testing.expect(allZero(both.res) and allZero(both.q));

    // updateState leaves the device as it was. Field by field: `State` is
    // { f64, i32 }, and its padding bytes are undefined, so a byte compare
    // of a copy fails under LLVM (ReleaseSafe) with every field equal.
    const before = .{ inst, st };
    _ = D.updateState(S0, &m, &inst, xv, &st, sim(false));
    try std.testing.expectEqual(before[0], inst);
    try std.testing.expectEqual(before[1], st);

    // initState clears it.
    st = D.initState(&m, &inst);
    try std.testing.expectEqual(@as(u32, 0), inst.vera_status__);
    try std.testing.expect(!allZero(evalAt(&m, &inst, 0.5, false)));
}

test "status: the first site an evaluation reaches wins" {
    var m: D.Model = .{};
    m.mode = 5; // both the $error (site 2) and the $fatal (site 3) run
    var inst: D.Instance = .{};
    _ = start(&m, &inst);
    _ = evalAt(&m, &inst, 2.0, false);
    try std.testing.expectEqual(contract.statusCode(.@"error", 2), inst.vera_status__);
    // A later evaluation reaching the $fatal changes nothing.
    _ = evalAt(&m, &inst, 3.0, false);
    try std.testing.expectEqual(contract.statusCode(.@"error", 2), inst.vera_status__);
    try std.testing.expectEqual([4]f64{ 2.0, 1.0, 0.0, 0.0 }, inst.vera_status_args__);

    // The $fatal alone: its finish_number is not an argument of the format.
    m.mode = 4;
    _ = start(&m, &inst);
    _ = evalAt(&m, &inst, 2.0, false);
    try std.testing.expectEqual(contract.statusCode(.fatal, 3), inst.vera_status__);
    try expectMessage("status_ops.va:25: fatal: fatal 7", try render(&inst));
}

test "status: analog initial and vera_timepoint sites report too" {
    var m: D.Model = .{};
    m.mode = 2;
    var inst: D.Instance = .{};
    _ = start(&m, &inst);
    // §5.2.1 the analog initial block runs on the initial evaluation only.
    try std.testing.expect(allZero(evalAt(&m, &inst, 0.0, true)));
    try std.testing.expectEqual(contract.statusCode(.fatal, 0), inst.vera_status__);
    try expectMessage("status_ops.va:18: fatal: initial: mode 2 lim 1", try render(&inst));

    m.mode = 3;
    _ = start(&m, &inst);
    try std.testing.expect(allZero(evalAt(&m, &inst, 0.0, false)));
    try std.testing.expectEqual(contract.statusCode(.@"error", 1), inst.vera_status__);
    try std.testing.expectEqual([4]f64{ 1.0, 0.0, 0.0, 0.0 }, inst.vera_status_args__);

    // No site: never a status.
    m.mode = 0;
    _ = start(&m, &inst);
    try std.testing.expect(!allZero(evalAt(&m, &inst, 2.0, true)));
    try std.testing.expectEqual(@as(u32, 0), inst.vera_status__);
    try std.testing.expectEqual(@as(?contract.StatusSite, null), contract.statusSite(D, &inst));
}

test "the *const Instance entries compile and run beside a status site" {
    // `mutable_eval` makes `InstancePtr` `*Instance`; `noisePsd` and `acStim`
    // stay `*const Instance` by contract, so the core they call must take a
    // const instance (hisim2_va/hisimhv_va at 1c554bc2 did not compile).
    var m: D.Model = .{};
    var inst: D.Instance = .{};
    _ = start(&m, &inst);
    const ci: *const D.Instance = &inst;
    const psd = D.noisePsd(S0, x(0.5), &m, ci, sim(false));
    try std.testing.expectEqual(@as(f64, 4e-21), psd[0].white);
    const ac = D.acStim(S0, x(0.5), &m, ci, sim(false));
    try std.testing.expectEqual(@as(usize, 1), ac.len);
}
