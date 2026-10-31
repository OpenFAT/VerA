//! One attached device library (VerA #84): its call table mapped onto the
//! call objects of its design, the §12.22.2 outputs its calls put, and the
//! solution it holds. The time walk over it is analog_walk.zig's.
//! Cites: VAMS-2023 §12.22.2, §12.32.1, §12.32.3; IEEE 1364-2005 §27.31.
//!
//! Contents:
//! - `pub const run = analog_walk.run`
//! - `pub const runMixed = analog_walk.runMixed`
//! - `pub const sweep = analog_walk.sweep`
//! - `pub const attempt = analog_walk.attempt`
//! - `pub const accept = analog_walk.accept`
//! - `pub const refreshRows = analog_walk.refreshRows`
//! - `pub fn attach(b: *Binding, l: Lib, own: ?Design) error`
//! - `pub fn attach.hash(_: @This(), s: Site) u64`
//! - `pub fn attach.eql(_: @This(), x: Site, y: Site) bool`
//! - `pub fn detach(b: *Binding) void`
//! - `pub fn call(b: *Binding, inst: usize, k: usize, args: []const f64, partials: []f64) f64`
//! - `pub fn output(b: *const Binding, inst: usize, k: usize, j: usize, args: []const f64, partials: []f64) f64`

const std = @import("std");
const gpa = std.heap.smp_allocator;
const analog = @import("analog.zig");
const analog_call = @import("analog_call.zig");
const analog_walk = @import("analog_walk.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const systf = @import("systf.zig");
const user = @import("vpi_user.zig");
const Design = @import("Design.zig");
const abi = @import("abi.zig");
const Active = analog_call.Active;
const CbData = abi.CbData;
const Deriv = analog_call.Deriv;
const Lib = analog.Lib;
const OneCall = analog.OneCall;
const Out = analog_call.Out;
const OutKey = analog_call.OutKey;

lib: ?Lib = null,

/// The design this library's calls are objects of, when the binding
/// owns one (`owns`, `attach`'s `own`); while it is entered (`enter`),
/// the installed design it stands in for.
design: ?Design = null,

owns: bool = false,

/// Per `Lib.row`: the unknown that is a potential source's flow, -1
/// for none. The row's other fields (kind, terminals) are unread.
flow_u: []i32 = &.{},

/// How many unknowns `Lib.x` holds (`Lib.n_u`): 0 for a host that binds
/// VerA only for the calls and keeps its solution to itself.
n_x: usize = 0,

/// Each row's (resistive, reactive) value at the current x, then each
/// instance's share of a shared row (`Lib.shares`), the same way.
now_vals: []f64 = &.{},

/// The same rows' and shares' reactive value at the last ACCEPTED
/// solution: the other operand of the backward-Euler difference.
prev_react: []f64 = &.{},

vals_fresh: bool = false,

/// §12.8's small-signal solution, every unknown's real part then every
/// imaginary part (`Lib.ac`); meaningful while `freq != 0`.
ac_x: []f64 = &.{},

/// The latest converged and accepted solution's time.
t_accepted: f64 = 0,

/// A solution has been attempted, so x means something.
have_solution: bool = false,

/// A later-than-first solution is attempted and not yet accepted: the
/// one §12.36 vpiRejectTransientStep can reject.
open_step: bool = false,

/// §12.36 vpiRejectTransientStep was called on the open step.
reject_step: bool = false,

/// A solution is attempted and not yet accepted, first one included:
/// the one §12.36 vpiTransientFailConverge keeps iterating.
awaiting: bool = false,

/// §12.36 vpiTransientFailConverge was called on the awaiting solution.
fail_converge: bool = false,

/// Per device call index: the VPI call object, or null when there is
/// none or more than one.
call_obj: []?u32 = &.{},

/// Per device call index: the arguments the device reads back after the
/// call (`contract.Systf.outs`, bit j - 1 for argument j).
call_outs: []u64 = &.{},

/// Per (call, host instance): its latest calltf's output arguments.
outs: std.AutoHashMapUnmanaged(OutKey, Out) = .empty,

/// Each call argument's value at the latest evaluation, by object index
/// — what `vpi_get_value` answers for an argument with no value of its
/// own (an access function, an operation), inside calltf and after it:
/// the §12.32.3 sampler reads its expression from an acbAbsTime
/// callback. Per call, not per instance: "the latest evaluation" is one.
arg_values: std.AutoHashMapUnmanaged(u32, f64) = .empty,

/// The §12.22.1 derivative handles handed out for this library's calls.
derivs: std.ArrayList(*Deriv) = .empty,

pub const run = analog_walk.run;
pub const runMixed = analog_walk.runMixed;
pub const sweep = analog_walk.sweep;
pub const attempt = analog_walk.attempt;
pub const accept = analog_walk.accept;
pub const refreshRows = analog_walk.refreshRows;

const Binding = @This();

/// A library with no unknowns whose device has one timer instant, at 0.37 s:
/// off the 0.02 s grid a 1 s transient walks.
const Timer = struct {
    var times: [128]f64 = undefined;
    var n: usize = 0;
    fn solve(t: f64, _: f64, _: bool, _: bool) callconv(.c) bool {
        if (n < times.len) times[n] = t;
        n += 1;
        return true;
    }
    fn breakpoint(t: f64) callconv(.c) f64 {
        return if (t < 0.37) 0.37 else std.math.inf(f64);
    }
};

/// Binds the loaded library and reads its row table and system-function
/// call names. `own` is the library's own design (`root.buildDesign`),
/// which the binding takes, frees at `detach`, and makes the installed
/// one while its calls and walk run; null binds the calls to the
/// installed design (`root.design`, which must be open) and makes this
/// the binding the routines answer for outside any call. An owned
/// design's compiletf/derivtf run here (`systf.buildCalls`); the
/// installed one's run at cbEndOfCompile. Precondition: `b` is not
/// attached (`.{}` or `detach`ed).
pub fn attach(b: *Binding, l: Lib, own: ?Design) error{OutOfMemory}!void {
    std.debug.assert(b.lib == null);
    b.* = .{ .lib = l, .design = own, .owns = own != null };
    errdefer b.detach();
    const prev = analog.enter(b);
    defer analog.leave(b, prev);
    // The library names each call by its name and source token, and the
    // model's call objects carry the token they were built from (both
    // parsed the same source). A pair two objects share (one call in a
    // module instantiated twice) binds to none and is refused when
    // called rather than handed to the wrong one.
    const n_calls = l.n_systf();
    b.call_obj = try gpa.alloc(?u32, n_calls);
    b.call_outs = try gpa.alloc(u64, n_calls);
    const Site = struct { name: []const u8, tok: u32 };
    const SiteCtx = struct {
        pub fn hash(_: @This(), s: Site) u64 {
            return std.hash.Wyhash.hash(s.tok, s.name);
        }
        pub fn eql(_: @This(), x: Site, y: Site) bool {
            return x.tok == y.tok and std.mem.eql(u8, x.name, y.name);
        }
    };
    // Each analog call site's object, or null when two objects share
    // it: one pass over the rows, not one per call.
    var by_site: std.HashMapUnmanaged(Site, ?u32, SiteCtx, std.hash_map.default_max_load_percentage) = .empty;
    defer by_site.deinit(gpa);
    for (session.design.?.objects, 0..) |o, i| {
        if (o.kind != .code or !o.in_analog or (o.vtype != user.vpiSysFuncCall and o.vtype != user.vpiSysTaskCall)) continue;
        const g = try by_site.getOrPut(gpa, .{ .name = o.name, .tok = o.src_tok });
        g.value_ptr.* = if (g.found_existing) null else @intCast(i);
    }
    for (b.call_obj, b.call_outs, 0..) |*c, *m, k| {
        var len: usize = 0;
        const name = l.systf_name(k, &len)[0..len];
        c.* = by_site.get(.{ .name = name, .tok = l.systf_tok(k) }) orelse null;
        m.* = l.systf_outs(k);
    }
    if (b.owns) systf.buildCalls();
    if (n_calls != 0) l.systf(b, analog_call.deviceCall, analog_call.deviceOut);
    const n = l.n_rows();
    b.flow_u = try gpa.alloc(i32, n);
    const n_vals = n + l.n_shares();
    b.now_vals = try gpa.alloc(f64, 2 * n_vals);
    b.prev_react = try gpa.alloc(f64, n_vals);
    b.n_x = l.n_u();
    b.ac_x = try gpa.alloc(f64, 2 * b.n_x);
    for (b.flow_u, 0..) |*u, k| {
        var m: [4]i32 = undefined;
        l.row(k, &m);
        u.* = m[3];
    }
    if (!b.owns) analog.installed = b;
}

/// Unbinds the library and frees everything `attach` and the analyses
/// built, the design it owns included, and clears the point
/// (`setPoint`). Safe on a binding never attached. Precondition: none of
/// its calls or walks is running.
pub fn detach(b: *Binding) void {
    std.debug.assert(analog.active != b);
    gpa.free(b.call_obj);
    gpa.free(b.call_outs);
    var it = b.outs.valueIterator();
    while (it.next()) |o| {
        gpa.free(o.buf);
        gpa.free(o.put);
    }
    b.outs.deinit(gpa);
    b.arg_values.deinit(gpa);
    for (b.derivs.items) |dv| gpa.destroy(dv);
    b.derivs.deinit(gpa);
    gpa.free(b.flow_u);
    gpa.free(b.now_vals);
    gpa.free(b.prev_react);
    gpa.free(b.ac_x);
    if (b.owns) if (b.design) |*d| d.deinit();
    if (analog.installed == b) analog.installed = null;
    b.* = .{};
    analog.setPoint(null, 0, 0, 0);
}

/// `contract.SystfHost.call` for host instance `inst` of the device:
/// runs the registration's calltf "each time the system task or function
/// is invoked during simulation execution" (§12.32.1), with
/// `vpi_handle(vpiSysTfCall, NULL)` naming call `k` and the per-call
/// state (§12.22.2 outputs, IEEE 1364-2005 §27.31 user data) that
/// instance's. Returns what calltf put on the call (§12.30); `partials`
/// receives what it put on §12.22.1 derivative objects, 0 elsewhere.
/// A call that is no one call object of the design is refused
/// (AMBIGUOUS) and returns 0. Asserts `partials.len == args.len`.
pub fn call(b: *Binding, inst: usize, k: usize, args: []const f64, partials: []f64) f64 {
    std.debug.assert(partials.len == args.len);
    @memset(partials, 0);
    const at = if (k < b.call_obj.len) b.call_obj[k] else null;
    const obj = at orelse {
        status.fail("AMBIGUOUS", "this analog system function call is not one call object of the design (a module instantiated twice shares its calls' source)", .{});
        return 0;
    };
    const prev = analog.enter(b);
    defer analog.leave(b, prev);
    const n = args.len;
    const o = &session.design.?.objects[obj];
    const reg = systf.find(o.name, .analog) orelse return 0;
    for (o.lists) |li| if (li.tag == user.vpiArgument) {
        for (li.items[0..@min(n, li.items.len)], 0..) |a, j| b.arg_values.put(gpa, a, args[j]) catch {};
    };
    const f = reg.analog.calltf orelse return 0;
    // This call's outputs start over: an argument calltf does not put
    // keeps its value (`output`).
    if (b.call_outs[k] != 0) {
        const g = b.outs.getOrPut(gpa, .{ .k = k, .inst = inst }) catch return analog_call.oom();
        if (!g.found_existing) {
            const buf = gpa.alloc(f64, n * (n + 1)) catch {
                b.outs.removeByPtr(g.key_ptr);
                return analog_call.oom();
            };
            const put = gpa.alloc(bool, n) catch {
                gpa.free(buf);
                b.outs.removeByPtr(g.key_ptr);
                return analog_call.oom();
            };
            g.value_ptr.* = .{ .buf = buf, .put = put, .n = n };
        }
        const rec = g.value_ptr.*;
        // One call site always passes the same arguments.
        std.debug.assert(rec.n == n);
        @memcpy(rec.val(), args);
        @memset(rec.put, false);
        @memset(rec.part(), 0);
    }
    var st: Active = .{ .b = b, .obj = obj, .k = k, .inst = inst, .result = 0, .partials = partials };
    const outer = .{ analog_call.active_call, systf.active, systf.active_reg, systf.active_inst };
    analog_call.active_call = &st;
    systf.active = obj;
    systf.active_reg = reg;
    systf.active_inst = inst;
    defer {
        analog_call.active_call, systf.active, systf.active_reg, systf.active_inst = outer;
    }
    var cb: CbData = .{ .reason = 0, .cb_rtn = null, .obj = @ptrCast(o), .time = null, .value = null, .index = 0, .user_data = reg.analog.user_data };
    _ = f(&cb);
    return st.result;
}

/// `contract.SystfHost.out` for host instance `inst`: argument j
/// (1-based) of call k as that instance's latest calltf left it
/// (§12.22.2), with its partials; an argument calltf put nothing on is
/// unchanged (partial 1 on itself). Writes every slot of `partials`;
/// j outside 1..`args.len` returns 0. Asserts `partials.len == args.len`.
pub fn output(b: *const Binding, inst: usize, k: usize, j: usize, args: []const f64, partials: []f64) f64 {
    std.debug.assert(partials.len == args.len);
    const n = args.len;
    @memset(partials, 0);
    if (j == 0 or j > n) return 0;
    const o = b.outs.get(.{ .k = k, .inst = inst }) orelse {
        partials[j - 1] = 1;
        return args[j - 1];
    };
    if (o.n != n or !o.put[j - 1]) {
        partials[j - 1] = 1;
        return args[j - 1];
    }
    @memcpy(partials, o.part()[(j - 1) * n ..][0..n]);
    return o.val()[j - 1];
}

test "§12.22.2 Binding.output: an argument calltf put nothing on reads back unchanged" {
    const b: Binding = .{};
    const args = [3]f64{ 1.5, -2, 4 };
    var partials: [3]f64 = undefined;
    // No record for call 7: argument 2 is itself, its partial on itself 1.
    try std.testing.expectEqual(@as(f64, -2), b.output(0, 7, 2, &args, &partials));
    try std.testing.expectEqualSlices(f64, &.{ 0, 1, 0 }, &partials);
    // Position 0 (the returned value) and one past the end are no argument.
    try std.testing.expectEqual(@as(f64, 0), b.output(0, 7, 0, &args, &partials));
    try std.testing.expectEqualSlices(f64, &.{ 0, 0, 0 }, &partials);
    try std.testing.expectEqual(@as(f64, 0), b.output(0, 7, 4, &args, &partials));
}

test "§5.10.3.3 Binding.run: a transient places a time point at the device's timer instant" {
    session.close();
    defer session.close();
    session.design = try OneCall.design("A.$c");
    var l = OneCall.lib;
    l.n_systf = OneCall.zero;
    l.solve = Timer.solve;
    l.breakpoint = Timer.breakpoint;
    var b: Binding = .{};
    defer b.detach();
    try b.attach(l, null);
    Timer.n = 0;
    try b.run(.{ .kind = .tran, .start = 0, .stop = 1 });
    try std.testing.expect(Timer.n <= Timer.times.len);
    const solved = Timer.times[0..Timer.n];
    try std.testing.expect(std.mem.findScalar(f64, solved, 0.37) != null);
    // The grid resumes after it: 0.38 is still solved.
    try std.testing.expect(for (solved) |t| (if (analog.sameTime(t, 0.38)) break true) else false);
}
