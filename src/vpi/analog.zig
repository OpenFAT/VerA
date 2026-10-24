//! The analog analysis a VPI application watches: a compiled device library
//! (`tb.renderVpiLib`, loaded by the host) -> §12.31.3 callbacks, §12.7-§12.10
//! analog time and values, and §12.32 calltf per device system task or
//! function call, with the §12.22.2 output arguments it puts.
//!
//! The time walk lives here, not in the library, because §12.31.3 lets the
//! application force solution times (acbAbsTime, acbElapsedTime) and reject a
//! solution to "backup to an earlier time" (acbConvergenceTest).

const std = @import("std");
const root = @import("root.zig");
const callback = @import("callback.zig");
const code = @import("code.zig");
const systf = @import("systf.zig");
const value = @import("value.zig");

const vpiHandle = root.vpiHandle;

/// `tb.renderVpiLib`'s C interface.
pub const Lib = struct {
    open: *const fn (u8) callconv(.c) void,
    solve: *const fn (f64, f64, bool, bool) callconv(.c) bool,
    accept: *const fn () callconv(.c) void,
    x: *const fn () callconv(.c) [*]const f64,
    n_u: *const fn () callconv(.c) usize,
    n_rows: *const fn () callconv(.c) usize,
    row: *const fn (usize, *[4]i32) callconv(.c) void,
    rows: *const fn ([*]f64) callconv(.c) void,
    n_shares: *const fn () callconv(.c) usize,
    shares: *const fn ([*]f64) callconv(.c) void,
    /// Hands the library the hop its `contract.SystfHost` forwards through,
    /// and the `ctx` (the `Binding`) to pass back first.
    systf: *const fn (?*anyopaque, ?HostCall, ?HostOut) callconv(.c) void,
    n_systf: *const fn () callconv(.c) usize,
    systf_name: *const fn (usize, *usize) callconv(.c) [*]const u8,
    systf_tok: *const fn (usize) callconv(.c) u32,
    systf_outs: *const fn (usize) callconv(.c) u64,
    ac: *const fn (f64, [*]f64, [*]f64) callconv(.c) bool,
};

/// The C function the library forwards `contract.SystfHost.call` to:
/// `(ctx, inst, k, args, n, partials)`, `Binding.call` across a C ABI. `ctx`
/// is the one `Lib.systf` handed over; `inst` the host's instance of the
/// device (any value unique per instance, a key and nothing else).
pub const HostCall = *const fn (?*anyopaque, usize, usize, [*]const f64, usize, [*]f64) callconv(.c) f64;
/// The C function the library forwards `contract.SystfHost.out` to:
/// `(ctx, inst, k, j, args, n, partials)`, `Binding.output` across a C ABI.
pub const HostOut = *const fn (?*anyopaque, usize, usize, usize, [*]const f64, usize, [*]f64) callconv(.c) f64;

/// The analyses a host can run: a DC operating point, a transient, or a
/// small-signal AC sweep around an operating point.
pub const Kind = enum { op, tran, ac };

/// One `analysis` line: §12.18's vpiStartTime/vpiEndTime/vpiTransientMaxStep
/// and vpiStartFrequency/vpiEndFrequency are its fields. An AC sweep takes
/// `points` frequencies, evenly spaced from `fstart` to `fstop`.
pub const Analysis = struct {
    kind: Kind,
    start: f64 = 0,
    stop: f64 = 0,
    max_step: f64 = 0,
    fstart: f64 = 0,
    fstop: f64 = 0,
    points: u32 = 1,
};

/// The device's `AnalysisKind` ordinals (`static, ic, nodeset, dc, tran, ac,
/// noise`): an operating point is a DC analysis, a transient a transient.
/// The library evaluates a transient's first solution (dt = 0) as `.ic`,
/// Table 4-22's TRAN OP column (`atPoint` in `tb/runner_text.zig`), so this
/// host passes the analysis and `Lib.solve` passes dt. An AC sweep's operating point is "static" (Table 4-21: "the DC analysis
/// which precedes an AC or noise analysis"): the device's `ac_stim` is live
/// in every `.ac` evaluation, and is zero here (§4.6.1); the sweep itself
/// evaluates as `.ac` (`Lib.ac`).
fn kindOrdinal(k: Kind) u8 {
    return switch (k) {
        .op => 3,
        .tran => 4,
        .ac => 0,
    };
}

/// One attached device library (VerA #84): its call table mapped onto the
/// call objects of its design, the §12.22.2 outputs its calls put, the
/// solution it holds and the walk `run` takes over it. The host owns it, at
/// an address that does not move from `attach` to `detach`; two attached at
/// once keep all of it apart. The routines answer for the binding whose
/// call or walk is running, else for the one attached to the installed
/// design (`installed`).
pub const Binding = struct {
    lib: ?Lib = null,
    /// The design this library's calls are objects of, when the binding
    /// owns one (`owns`, `attach`'s `own`); while it is entered (`enter`),
    /// the installed design it stands in for.
    design: ?root.Design = null,
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

    /// Binds the loaded library and reads its row table and system-function
    /// call names. `own` is the library's own design (`root.buildDesign`),
    /// which the binding takes, frees at `detach`, and makes the installed
    /// one while its calls and walk run; null binds the calls to the
    /// installed design (`root.design`, which must be open) and makes this
    /// the binding the routines answer for outside any call. An owned
    /// design's compiletf/derivtf run here (`systf.buildCalls`); the
    /// installed one's run at cbEndOfCompile. Precondition: `b` is not
    /// attached (`.{}` or `detach`ed).
    pub fn attach(b: *Binding, l: Lib, own: ?root.Design) error{OutOfMemory}!void {
        std.debug.assert(b.lib == null);
        b.* = .{ .lib = l, .design = own, .owns = own != null };
        errdefer b.detach();
        const prev = enter(b);
        defer leave(b, prev);
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
        for (root.design.?.objects, 0..) |o, i| {
            if (o.kind != .code or !o.in_analog or (o.vtype != code.vpiSysFuncCall and o.vtype != code.vpiSysTaskCall)) continue;
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
        if (n_calls != 0) l.systf(b, deviceCall, deviceOut);
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
        if (!b.owns) installed = b;
    }

    /// Unbinds the library and frees everything `attach` and the analyses
    /// built, the design it owns included, and clears the point
    /// (`setPoint`). Safe on a binding never attached. Precondition: none of
    /// its calls or walks is running.
    pub fn detach(b: *Binding) void {
        std.debug.assert(active != b);
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
        if (installed == b) installed = null;
        b.* = .{};
        setPoint(null, 0, 0, 0);
    }

    /// Runs one analysis to its end, delivering every §12.31.3 callback.
    ///
    /// `tran` walks a grid of `max_step` (default (stop - start)/50) plus
    /// every forced time; each tentative solution passes acbConvergenceTest
    /// before it is accepted, and a rejection (or §12.36
    /// vpiRejectTransientStep) halves the step from the last accepted point.
    /// `op` is one DC solution, first and last at once. `ac` is that
    /// solution (acbInitialStep, at frequency 0), then one small-signal
    /// solution per frequency, each an acbAcceptedPoint and the last also
    /// acbFinalStep (`Vague_Decisions.md` VD-098). A rejected solution
    /// leaves no history. §12.36 vpiTransientFailConverge solves the same
    /// time again. `BackupExhausted`: 60 rejections or re-solves of one step.
    pub fn run(b: *Binding, a: Analysis) Error!void {
        const l = b.lib orelse return error.NoLibrary;
        const prev = enter(b);
        defer leave(b, prev);
        l.open(kindOrdinal(a.kind));
        @memset(b.prev_react, 0);
        var run_a = a;
        // §12.18 vpiTransientMaxStep is the step this walk takes.
        if (run_a.kind == .tran and run_a.max_step <= 0) run_a.max_step = (a.stop - a.start) / 50.0;
        setPoint(run_a, a.start, 0, 0);
        defer setPoint(null, t_now, delta, 0);
        b.t_accepted = a.start;
        const last0 = a.kind == .op or (a.kind == .tran and a.stop <= a.start);
        // The first solution has no earlier time to back up to; §12.31.3's
        // rejection is honoured from the next one on. §12.36's
        // vpiTransientFailConverge needs none, so it is honoured here too.
        var first_tries: u32 = 0;
        while (true) : (first_tries += 1) {
            if (first_tries == 60) return error.BackupExhausted;
            try b.attempt(l, a.start, 0, true, last0);
            _ = callback.convergenceRejected();
            if (!b.fail_converge) break;
        }
        b.accept(l, true, last0);
        if (last0) return;
        if (a.kind == .ac) return b.sweep(l, a);

        const h = run_a.max_step;
        while (!sameTime(b.t_accepted, a.stop) and b.t_accepted < a.stop) {
            // The next grid point strictly after t, by index rather than by
            // accumulation, so a thousand steps do not drift off `stop`.
            const k = @floor((b.t_accepted - a.start) / h + 1e-9) + 1;
            var target = @min(a.start + k * h, a.stop);
            if (callback.nextForced(b.t_accepted, target)) |f| target = f;
            if (a.stop - target < h * 1e-6) target = a.stop;
            var tries: u32 = 0;
            while (true) : (tries += 1) {
                if (tries == 60) return error.BackupExhausted;
                try b.attempt(l, target, target - b.t_accepted, false, sameTime(target, a.stop));
                const rejected = callback.convergenceRejected() or b.reject_step;
                if (!(rejected or b.fail_converge)) break;
                // "backup to an earlier time": half the step, from the same
                // accepted solution. A vpiTransientFailConverge alone keeps
                // the time and iterates again.
                if (rejected) target = b.t_accepted + (target - b.t_accepted) / 2;
            }
            b.accept(l, false, sameTime(target, a.stop));
        }
    }

    /// The AC half of `run`: `a.points` small-signal solutions around the
    /// accepted operating point. §12.31.3 names no per-frequency reason, so
    /// each is an acbAcceptedPoint, the last also acbFinalStep; §12.8's
    /// vpi_get_analog_freq() tells an application which kind of solution it
    /// is standing on.
    fn sweep(b: *Binding, l: Lib, a: Analysis) Error!void {
        defer setPoint(current, t_now, delta, 0);
        const n = @max(a.points, 1);
        for (0..n) |k| {
            const f = if (n == 1) a.fstart else a.fstart + (a.fstop - a.fstart) * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n - 1));
            const u = b.ac_x.len / 2;
            if (!l.ac(2 * std.math.pi * f, b.ac_x.ptr, b.ac_x[u..].ptr)) return error.Singular;
            setPoint(current, t_now, delta, f);
            callback.fireAnalog(callback.acbAcceptedPoint);
            if (k == n - 1) callback.fireAnalog(callback.acbFinalStep);
        }
    }

    fn attempt(b: *Binding, l: Lib, t: f64, dt: f64, first: bool, last: bool) Error!void {
        setPoint(current, t, dt, 0);
        b.have_solution = true;
        b.open_step = !first;
        b.awaiting = true;
        b.reject_step = false;
        b.fail_converge = false;
        b.vals_fresh = false;
        _ = l.solve(t, dt, first, last);
    }

    fn accept(b: *Binding, l: Lib, first: bool, last: bool) void {
        b.open_step = false;
        b.awaiting = false;
        // Row values are the accepted solution's, read before history moves.
        b.refreshRows(l);
        l.accept();
        b.t_accepted = t_now;
        // §12.31.3 does not say whether the first solution (acbInitialStep)
        // is also an acbAcceptedPoint. VerA says no, so accepted points
        // strictly advance (p03_02 pins this reading); the final one is an
        // accepted point, then acbFinalStep.
        if (first) callback.fireAnalog(callback.acbInitialStep);
        callback.fireTimed(b.t_accepted);
        if (!first) callback.fireAnalog(callback.acbAcceptedPoint);
        if (last) callback.fireAnalog(callback.acbFinalStep);
        // Only now does this solution's charge become the next step's history.
        for (b.prev_react, 0..) |*q, k| q.* = b.now_vals[2 * k + 1];
    }

    fn refreshRows(b: *Binding, l: Lib) void {
        if (b.vals_fresh or b.flow_u.len == 0) return;
        l.rows(b.now_vals.ptr);
        if (b.now_vals.len > 2 * b.flow_u.len) l.shares(b.now_vals[2 * b.flow_u.len ..].ptr);
        b.vals_fresh = true;
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
            root.fail("AMBIGUOUS", "this analog system function call is not one call object of the design (a module instantiated twice shares its calls' source)", .{});
            return 0;
        };
        const prev = enter(b);
        defer leave(b, prev);
        const n = args.len;
        const o = &root.design.?.objects[obj];
        const reg = systf.find(o.name, .analog) orelse return 0;
        for (o.lists) |li| if (li.tag == code.vpiArgument) {
            for (li.items[0..@min(n, li.items.len)], 0..) |a, j| b.arg_values.put(gpa, a, args[j]) catch {};
        };
        const f = reg.analog.calltf orelse return 0;
        // This call's outputs start over: an argument calltf does not put
        // keeps its value (`output`).
        if (b.call_outs[k] != 0) {
            const g = b.outs.getOrPut(gpa, .{ .k = k, .inst = inst }) catch return oom();
            if (!g.found_existing) {
                const buf = gpa.alloc(f64, n * (n + 1)) catch {
                    b.outs.removeByPtr(g.key_ptr);
                    return oom();
                };
                const put = gpa.alloc(bool, n) catch {
                    gpa.free(buf);
                    b.outs.removeByPtr(g.key_ptr);
                    return oom();
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
        const outer = .{ active_call, systf.active, systf.active_reg, systf.active_inst };
        active_call = &st;
        systf.active = obj;
        systf.active_reg = reg;
        systf.active_inst = inst;
        defer {
            active_call, systf.active, systf.active_reg, systf.active_inst = outer;
        }
        var cb: callback.CbData = .{ .reason = 0, .cb_rtn = null, .obj = @ptrCast(o), .time = null, .value = null, .index = 0, .user_data = reg.analog.user_data };
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
};

/// The binding whose call or walk is running (`enter`), else null.
var active: ?*Binding = null;
/// The binding attached to the installed design, which the routines answer
/// for outside any call or walk (a cbEndOfSimulation reading a value after
/// VerA's walk); null when none is.
var installed: ?*Binding = null;

/// The binding the routines answer for now.
fn bound() ?*Binding {
    return active orelse installed;
}

/// Makes `b` the binding the routines answer for and, when it owns a
/// design, that design the installed one, until `leave(b, <the result>)`.
/// Entering the binding already entered changes nothing; entries nest LIFO.
fn enter(b: *Binding) ?*Binding {
    const prev = active;
    if (prev == b) return prev;
    if (b.owns) std.mem.swap(?root.Design, &root.design, &b.design);
    active = b;
    return prev;
}

/// Undoes the `enter(b)` that returned `prev`.
fn leave(b: *Binding, prev: ?*Binding) void {
    if (prev == b) return;
    std.debug.assert(active == b);
    if (b.owns) std.mem.swap(?root.Design, &root.design, &b.design);
    active = prev;
}

/// The analysis running, or null between analyses.
var current: ?Analysis = null;
/// The time of the solution being attempted, or of the latest accepted one.
var t_now: f64 = 0;
/// The step being attempted, or the one the accepted solution was reached by.
var delta: f64 = 0;
/// §12.8 the frequency of the small-signal solution an AC sweep stands on,
/// 0 elsewhere (its operating point included).
var freq: f64 = 0;

/// §12.36 vpiRejectTransientStep: "cause the current analog simulation time
/// point to be rejected". The walk backs up as for an acbConvergenceTest
/// rejection. False when no rejectable solution is open: outside an analysis,
/// on the first solution (no earlier time to back up to), or once accepted.
pub fn rejectStep() bool {
    const b = bound() orelse return false;
    if (current == null or !b.open_step) return false;
    b.reject_step = true;
    return true;
}

/// §12.36 vpiTransientFailConverge: "cause the current analog simulation to
/// continue iterating for a (valid) solution". The walk solves the same time
/// again from the solution it has, with no backup and no acceptance between.
/// False when no solution is awaiting acceptance.
pub fn failConverge() bool {
    const b = bound() orelse return false;
    if (current == null or !b.awaiting) return false;
    b.fail_converge = true;
    return true;
}

const gpa = std.heap.smp_allocator;

/// Sets the point §12.7-§12.9 and §12.18 answer for: the analysis `a` (null
/// between analyses), the time `t` of the solution attempted, the step `dt`
/// that reaches it, and the small-signal frequency `f` (0 outside an AC
/// sweep's small-signal points). `run` calls it at every point it walks; a
/// host that walks its own analysis and binds VerA only for the calls (a
/// `Lib` with no solution, `vpi_get_analog_value` then refuses NOSOLUTION)
/// calls it before each `contract.SystfHost.call`, so a calltf reads the
/// host's point. One point per process, for every binding: §12.7-§12.9 take
/// no argument. `a.kind` decides which values the routines report (§12.9:
/// zero time outside a transient); its bounds are §12.18's.
pub fn setPoint(a: ?Analysis, t: f64, dt: f64, f: f64) void {
    current = a;
    t_now = t;
    delta = dt;
    freq = f;
}

/// The analysis `run` is walking, its default `max_step` filled in; null
/// outside `run`. §12.18's vpi_get_real reads its bounds.
pub fn analysis() ?Analysis {
    return current;
}

/// §12.9's value: the attempted solution's time, or the latest accepted.
pub fn time() f64 {
    return t_now;
}

/// Where acbElapsedTime counts from: "the current solution".
pub fn acceptedTime() f64 {
    const b = bound() orelse return 0;
    return if (current != null) b.t_accepted else 0;
}

/// Two analog instants are one when they differ by rounding only: a forced
/// point is solved at exactly the requested double, but a grid point is
/// `start + k·step` and need not be bit-equal to a time an application
/// computed another way.
pub fn sameTime(a: f64, b: f64) bool {
    return @abs(a - b) <= 1e-12 * @max(1.0, @max(@abs(a), @abs(b))) or @abs(a - b) <= 1e-21;
}

/// `Binding.run`'s failures: `NoLibrary`, not attached; `BackupExhausted`,
/// see `run`; `Singular`, an AC point whose small-signal system has no
/// solution. A solve that does not converge is no error: `attempt` discards
/// `Lib.solve`'s result.
pub const Error = error{ NoLibrary, BackupExhausted, Singular };

// ---------------------------------------------------------------------------
// §12.10 values
// ---------------------------------------------------------------------------

const ground = @import("ir").Lowered.ground;

fn unknownAt(x: [*]const f64, row: u32) f64 {
    return if (row == ground) 0 else x[row];
}

/// `NoAnalysis`: no library or no solution yet. `NoSolution`: the library
/// holds no value of this quantity (an unknown or row past what it
/// publishes: a calls-only `Lib`). `Unknowable`: a flow the device does not
/// publish. `SmallSignal`: a flow source's flow at an AC point, which this
/// host does not linearise per row.
pub const ValueError = error{ NoAnalysis, NoSolution, Unknowable, SmallSignal };

/// Whether `bi`'s `Lib.x` holds `row`: ground reads 0 and needs no slot.
fn holds(bi: *const Binding, row: u32) bool {
    return row == ground or row < bi.n_x;
}

/// §11.6.7 a quantity's "real value" and "imaginary value".
pub const Value = struct { re: f64, im: f64 = 0 };

/// Returns quantity `q`'s value (§11.6.7): at an AC point the small-signal
/// phasor, elsewhere the large-signal value with imaginary part 0. A
/// potential is the difference of two unknowns. A flow is an unknown for a
/// potential source, and for a flow source the §5.6 row the device publishes
/// (`codegen.Options.vpi_contribs`): resistive part plus the backward-Euler
/// derivative of the reactive part over the step being solved. When several
/// instances' unnamed branches share the row, it is this instance's own share
/// (`vpiShares`, §5.4.1), the same way.
fn quantityValue(q: *const root.Obj) ValueError!Value {
    const bi = bound() orelse return error.NoAnalysis;
    const l = bi.lib orelse return error.NoAnalysis;
    const d = &root.design.?;
    const flow_u = bi.flow_u;
    const b = root.coldOf(&d.objects[root.coldOf(q).branch orelse return error.NoAnalysis]);
    // The library is outside data: every slot read below is checked against
    // what it published, before the solution is.
    if (!holds(bi, b.hi_row) or !holds(bi, b.lo_row)) return error.NoSolution;
    if (b.contrib_pot) |k| if (k >= flow_u.len or (flow_u[k] >= 0 and @as(usize, @intCast(flow_u[k])) >= bi.n_x)) return error.NoSolution;
    if (b.contrib_flow != null and flow_u.len == 0) return error.NoSolution;
    if (!bi.have_solution) return error.NoAnalysis;
    const ac = freq != 0;
    const x = if (ac) bi.ac_x.ptr else l.x();
    const xi = bi.ac_x[bi.ac_x.len / 2 ..].ptr;
    const is_flow = b.flow != null and &d.objects[b.flow.?] == q;
    if (!is_flow) return .{
        .re = unknownAt(x, b.hi_row) - unknownAt(x, b.lo_row),
        .im = if (ac) unknownAt(xi, b.hi_row) - unknownAt(xi, b.lo_row) else 0,
    };
    if (b.flow_unknowable) return error.Unknowable;
    const sign: f64 = if (b.flow_neg) -1 else 1;
    if (b.contrib_pot) |k| {
        if (flow_u[k] < 0) return error.Unknowable;
        const u: usize = @intCast(flow_u[k]);
        return .{ .re = sign * x[u], .im = if (ac) sign * xi[u] else 0 };
    }
    if (b.contrib_flow) |row| {
        if (ac) return error.SmallSignal;
        bi.refreshRows(l);
        // A share's values follow the rows'.
        const k = if (b.contrib_share) |sh| flow_u.len + sh else row;
        if (2 * k + 1 >= bi.now_vals.len) return error.Unknowable;
        var v = bi.now_vals[2 * k];
        if (delta > 0) v += (bi.now_vals[2 * k + 1] - bi.prev_react[k]) / delta;
        return .{ .re = sign * v };
    }
    // §5.6.1.3: a branch with no source retains nothing, and is an open
    // circuit — its flow is zero.
    return .{ .re = 0 };
}

// ---------------------------------------------------------------------------
// §12.10 vpi_get_analog_value: the C face of `quantityValue`
// ---------------------------------------------------------------------------

/// Figure 12-3, laid out for C.
pub const AnalogValue = extern struct {
    format: c_int,
    real: extern union { str: [*c]u8, real: f64, misc: [*c]u8 },
    imaginary: extern union { str: [*c]u8, real: f64, misc: [*c]u8 },
};

/// "shall retrieve the simulation value of VPI analog vpiFlow or vpiPotential
/// (node or branch) quantity objects. The value shall be placed in an
/// s_vpi_analog_value structure, which has been allocated by the user."
///
/// A non-quantity object or a NULL structure is refused. The value is the
/// current solution of analog.zig's analysis; with none, the error is
/// NOANALYSIS, and a flow the model cannot tell from a parallel branch's is
/// SHARED. An instance's unnamed branch over a pair other instances also
/// drive reads its own share. The imaginary part is 0 except at an AC point
/// (`quantityValue`).
pub export fn vpi_get_analog_value(obj: vpiHandle, value_p: ?*AnalogValue) void {
    _ = root.enter("vpi_get_analog_value") orelse return;
    const o = root.object("vpi_get_analog_value", obj) orelse return;
    if (o.kind != .quantity) {
        root.fail("NOTQUANTITY", "vpi_get_analog_value: a {s} is not a vpiFlow or vpiPotential quantity", .{@tagName(o.kind)});
        return;
    }
    const v = value_p orelse {
        root.fail("BADVALUE", "vpi_get_analog_value: value_p is NULL", .{});
        return;
    };
    const val = quantityValue(o) catch |e| {
        switch (e) {
            error.NoAnalysis => root.fail("NOANALYSIS", "vpi_get_analog_value: no analysis has solved this quantity in this process", .{}),
            error.NoSolution => root.fail("NOSOLUTION", "vpi_get_analog_value: no solution is attached: the host's analog library publishes no value of this quantity", .{}),
            // Two named branches over one pair, or an instance that drives
            // the pair only through another's branch (§5.6.8.2): the model
            // has no row of this branch's own to read.
            error.Unknowable => root.fail("SHARED", "vpi_get_analog_value: this branch's flow cannot be told apart from a parallel branch's", .{}),
            error.SmallSignal => root.fail("NOTSUPPORTED", "vpi_get_analog_value: the small-signal flow of a flow contribution is not computed at an AC point; its potentials are", .{}),
        }
        return;
    };
    switch (v.format) {
        vpiRealVal => {
            v.real = .{ .real = val.re };
            v.imaginary = .{ .real = val.im };
        },
        vpiExpStrVal, vpiDecStrVal, vpiStringVal => {
            // Table 12-2. The strings live in THIS routine's buffer — "different
            // from the buffer which vpi_get_str() shall use" and "overwritten
            // with each call".
            // vpiStringVal: "The call shall reset the format field to
            // vpiExpStrVal or vpiDecStrVal to the selected format." The real
            // part's choice is the one reported.
            var chose: c_int = v.format;
            var im_chose: c_int = v.format;
            const a = analogString(&analog_buf[0], val.re, v.format, &chose) orelse return;
            const b = analogString(&analog_buf[1], val.im, v.format, &im_chose) orelse return;
            v.format = chose;
            v.real.str = a;
            v.imaginary.str = b;
        },
        else => root.fail("BADFORMAT", "vpi_get_analog_value: format {d} is not one of Table 12-2's", .{v.format}),
    }
}

const vpiRealVal = value.vpiRealVal;
const vpiDecStrVal = value.vpiDecStrVal;
const vpiStringVal = value.vpiStringVal;
/// §12.10's `vpExpStrVal` (Table 12-2's spelling): vpi_user.h's number.
const vpiExpStrVal: c_int = 710;

/// §12.10's own string buffers, real and imaginary.
var analog_buf: [2][analog_len]u8 = undefined;

/// The longest part Table 12-2 can spell, sentinel included. vpiDecStrVal is
/// Zig's shortest round-trip decimal: at most 17 significant digits, so a
/// value of at least 1 has at most 309 integer digits and no fraction, and one
/// below 1 is "0." then at most 323 zeros (5e-324) then its digits. With the
/// sign that is 1 + 2 + 323 + 17; %e and %g are shorter.
const analog_len = 1 + 2 + 323 + 17 + 1;

/// One part of an analog value as Table 12-2 spells it: vpiExpStrVal "like
/// printf %e", vpiDecStrVal "decimal char(s)", vpiStringVal "like printf
/// %g" — reporting which of the other two %g chose in `chose`.
fn analogString(buf: *[analog_len]u8, x: f64, format: c_int, chose: *c_int) ?[*:0]u8 {
    const text = switch (format) {
        vpiExpStrVal => printfE(buf, x, 6),
        vpiDecStrVal => std.mem.printSentinel(buf, "{d}", .{x}, 0) catch null,
        vpiStringVal => printfG(buf, x, chose),
        else => null,
    } orelse {
        root.fail("BADFORMAT", "vpi_get_analog_value: {e} does not fit the value buffer", .{x});
        return null;
    };
    return @constCast(text.ptr);
}

/// C's `%.<prec>e`: one digit, the fraction, `e`, a sign and at least two
/// exponent digits. Zig's `{e}` rounds correctly and spells the exponent
/// bare (`2.5e-3`), so only the exponent is re-spelled.
fn printfE(buf: *[analog_len]u8, x: f64, prec: usize) ?[:0]const u8 {
    if (!std.math.isFinite(x)) return nonFinite(buf, x);
    var tmp: [64]u8 = undefined;
    const e = splitE(&tmp, x, prec) orelse return null;
    return spellE(buf, e.mantissa, e.exp);
}

/// Zig's `{e:.<prec>}` of finite `x`, written into `tmp`, split at its `e`.
fn splitE(tmp: *[64]u8, x: f64, prec: usize) ?struct { mantissa: []const u8, exp: i32 } {
    const raw = std.mem.print(tmp, "{e:.[1]}", .{ x, prec }) catch return null;
    const at = std.mem.findScalar(u8, raw, 'e') orelse return null;
    const exp = std.fmt.parseInt(i32, raw[at + 1 ..], 10) catch return null;
    return .{ .mantissa = raw[0..at], .exp = exp };
}

/// C's exponent spelling after `mantissa`: `e`, a sign, at least two digits.
fn spellE(buf: *[analog_len]u8, mantissa: []const u8, exp: i32) ?[:0]const u8 {
    const sign: u8 = if (exp < 0) '-' else '+';
    return std.mem.printSentinel(buf, "{s}e{c}{d:0>2}", .{ mantissa, sign, @abs(exp) }, 0) catch null;
}

/// C's `%g` (precision 6): %e when the exponent is below -4 or at least 6,
/// %f otherwise, trailing zeros and a bare point dropped. `chose` becomes
/// vpiExpStrVal or vpiDecStrVal after the form taken.
fn printfG(buf: *[analog_len]u8, x: f64, chose: *c_int) ?[:0]const u8 {
    if (x == 0) {
        chose.* = vpiDecStrVal;
        return std.mem.printSentinel(buf, "0", .{}, 0) catch null;
    }
    // An infinity or NaN has no exponent to choose a style by.
    if (!std.math.isFinite(x)) {
        chose.* = vpiDecStrVal;
        return nonFinite(buf, x);
    }
    var tmp: [64]u8 = undefined;
    const e = splitE(&tmp, x, 5) orelse return null;
    if (e.exp < -4 or e.exp >= 6) {
        chose.* = vpiExpStrVal;
        return spellE(buf, dropZeros(e.mantissa), e.exp);
    }
    chose.* = vpiDecStrVal;
    const decimals: usize = @intCast(5 - e.exp);
    const fixed = std.mem.print(&tmp, "{d:.[1]}", .{ x, decimals }) catch return null;
    return std.mem.printSentinel(buf, "{s}", .{dropZeros(fixed)}, 0) catch null;
}

/// %g's trailing zeros of a fraction, and then a bare point, dropped.
fn dropZeros(digits: []const u8) []const u8 {
    if (std.mem.findScalar(u8, digits, '.') == null) return digits;
    return std.mem.trimEnd(u8, std.mem.trimEnd(u8, digits, "0"), ".");
}

// C11 7.21.6.1's spelling of an infinity or a NaN under %e and %g: `[-]inf`,
// `[-]nan`, the sign from the sign bit. Zig's `{e}` writes the same words but
// has no exponent for the callers above to re-spell.
fn nonFinite(buf: *[analog_len]u8, x: f64) ?[:0]const u8 {
    const word: []const u8 = if (std.math.isNan(x)) "nan" else "inf";
    const sign: []const u8 = if (std.math.signbit(x)) "-" else "";
    return std.mem.printSentinel(buf, "{s}{s}", .{ sign, word }, 0) catch null;
}

// ---------------------------------------------------------------------------
// The C routines
// ---------------------------------------------------------------------------

/// §12.9 "the time of the solution attempted or of the latest converged and
/// accepted solution otherwise. The function shall return zero (0) during DC
/// or the time zero transient solution."
pub export fn vpi_get_analog_time() f64 {
    if (root.refused("vpi_get_analog_time")) return 0;
    if (current) |a| if (a.kind != .tran) return 0;
    return t_now;
}

/// §12.7 "the elapsed time between the latest converged and accepted
/// solution and the solution being calculated. The function shall return
/// zero (0) during DC or the time zero transient solution." Inside an
/// acceptance callback the solution "being calculated" is the one just
/// accepted, so it is the step that reached it.
pub export fn vpi_get_analog_delta() f64 {
    if (root.refused("vpi_get_analog_delta")) return 0;
    if (current) |a| if (a.kind != .tran) return 0;
    return delta;
}

/// §12.8 "the current frequency used in the small-signal analysis. The
/// function shall return zero (0) during DC or transient analysis." Nonzero
/// only at an AC sweep's small-signal points, not at its operating point.
pub export fn vpi_get_analog_freq() f64 {
    if (root.refused("vpi_get_analog_freq")) return 0;
    return freq;
}

// ---------------------------------------------------------------------------
// §12.32 analog system function calls, during the analysis
// ---------------------------------------------------------------------------

/// §12.22.2 one call's output arguments, as its latest calltf left them:
/// `val[j - 1]` and row j - 1 of `part` (d(argument j)/d(argument i)) for each
/// argument j with `put[j - 1]`, which calltf put a value or a partial on.
/// `Binding.output` answers from it. `buf` holds `val` then `part`; `put` is
/// its own allocation. Both are `gpa`'s, freed at `Binding.detach`.
const Out = struct {
    buf: []f64,
    put: []bool,
    n: usize,
    fn val(o: Out) []f64 {
        return o.buf[0..o.n];
    }
    fn part(o: Out) []f64 {
        return o.buf[o.n..];
    }
};

/// Which output record: device call k, run for host instance `inst`.
const OutKey = struct { k: usize, inst: usize };

/// The call whose §12.32 calltf is running: its binding, object, device
/// call index and host instance.
const Active = struct { b: *Binding, obj: u32, k: usize, inst: usize, result: f64, partials: []f64 };
var active_call: ?*Active = null;

/// `HostCall`: `Binding.call` for a library behind a C ABI. `ctx` is the
/// binding `attach` handed the library (`Lib.systf`).
fn deviceCall(ctx: ?*anyopaque, inst: usize, k: usize, args: [*]const f64, n: usize, partials: [*]f64) callconv(.c) f64 {
    const b: *Binding = @ptrCast(@alignCast(ctx.?));
    return b.call(inst, k, args[0..n], partials[0..n]);
}

/// `HostOut`: `Binding.output` for a library behind a C ABI.
fn deviceOut(ctx: ?*anyopaque, inst: usize, k: usize, j: usize, args: [*]const f64, n: usize, partials: [*]f64) callconv(.c) f64 {
    const b: *const Binding = @ptrCast(@alignCast(ctx.?));
    return b.output(inst, k, j, args[0..n], partials[0..n]);
}

fn oom() f64 {
    root.fail("NOMEM", "out of memory for a call's output arguments", .{});
    return 0;
}

/// §12.30 onto argument j of the call calltf is running for: the value the
/// device reads back as that variable (§12.22.2). False when `o` is no
/// argument of that call, so the ordinary put rules apply; an argument the
/// device does not read back is refused (NOPUT).
pub fn putArg(o: *const root.Obj, v: f64) bool {
    const st = active_call orelse return false;
    const j = argPosition(st.obj, o) orelse return false;
    const out = outputOf(st, j, "vpi_put_value") orelse return true;
    out.val()[j - 1] = v;
    out.put[j - 1] = true;
    return true;
}

/// The running call's output record when argument j is one the device reads
/// back, else null with a NOPUT error.
fn outputOf(st: *const Active, j: usize, routine: []const u8) ?Out {
    if (j > 64 or (st.b.call_outs[st.k] >> @intCast(j - 1)) & 1 == 0) {
        root.fail("NOPUT", "{s}: argument {d} of `{s}` is not a variable the design reads back after the call (§12.22.2)", .{ routine, j, root.design.?.objects[st.obj].name });
        return null;
    }
    return st.b.outs.get(.{ .k = st.k, .inst = st.inst });
}

/// Which argument (1-based) of call `obj` the object `o` is, or null.
fn argPosition(obj: u32, o: *const root.Obj) ?usize {
    const d = &root.design.?;
    for (d.objects[obj].lists) |l| if (l.tag == code.vpiArgument) {
        for (l.items, 0..) |a, j| if (&d.objects[a] == o) return j + 1;
    };
    return null;
}

/// §12.16 for an analog call argument that has no value of its own: its
/// value at the latest evaluation.
pub fn argValue(o: *const root.Obj) ?f64 {
    const b = bound() orelse return null;
    const d = &(root.design orelse return null);
    return b.arg_values.get(d.indexOf(o));
}

/// §12.30 onto the call calltf is running for: its returned value. False
/// when `o` is not that call, so the ordinary put rules apply.
pub fn putResult(o: *const root.Obj, v: f64) bool {
    const st = active_call orelse return false;
    const d = &root.design.?;
    if (o != &d.objects[st.obj]) return false;
    st.result = v;
    return true;
}

// ---------------------------------------------------------------------------
// §12.22.1 / §12.32.2 derivative objects
// ---------------------------------------------------------------------------

/// One derivative handle: the call, and (of, wrt) in §12.32.2's numbering.
/// Each is its own allocation, so a handle stays put while more are handed
/// out; a handle is ours iff its binding's `derivs` lists it. There are at
/// most as many as derivtf declared (call, of, wrt) triples, since a
/// repeated request returns the first handle.
const Deriv = struct { call: u32, of: c_int, wrt: c_int, value: f64 = 0 };

/// Returns `h` as a derivative handle of the binding the routines answer
/// for, or null unless it is one handed out; never dereferences a foreign
/// pointer.
pub fn asDeriv(h: vpiHandle) ?*Deriv {
    return derivOf(bound() orelse return null, h);
}

// ponytail: a linear scan over the handed-out handles; a hash set if a
// design declares thousands of partials and `vpi_get_value` measures hot.
fn derivOf(b: *const Binding, h: vpiHandle) ?*Deriv {
    const p = h orelse return null;
    for (b.derivs.items) |dv| if (@as(*anyopaque, @ptrCast(dv)) == p) return dv;
    return null;
}

/// Which §12.32.2 position `h` is on call `obj`: 0 for the call itself (the
/// returned value), 1.. for its arguments, null for neither.
fn position(obj: u32, h: vpiHandle) ?c_int {
    const d = &root.design.?;
    const o = root.asObj(h) orelse return null;
    if (o == &d.objects[obj]) return 0;
    return @intCast(argPosition(obj, o) orelse return null);
}

/// §12.22.1 `vpi_handle_multi(vpiDerivative, ref1, ref2)`: the partial of
/// the running call's result or argument `ref1` with respect to argument
/// `ref2`, if derivtf declared it (§12.32.2). Null, with an error, outside a
/// calltf or for an undeclared pair, and NOMEM when no memory is left.
pub fn derivative(ref1: vpiHandle, ref2: vpiHandle) vpiHandle {
    const st = active_call orelse {
        root.fail("NOCALL", "vpi_handle_multi(vpiDerivative): no analog system task or function call is running", .{});
        return null;
    };
    const of = position(st.obj, ref1) orelse {
        root.fail("NOTARG", "vpi_handle_multi(vpiDerivative): the first handle is neither the call nor one of its arguments", .{});
        return null;
    };
    const wrt = position(st.obj, ref2) orelse 0;
    if (wrt == 0) {
        root.fail("NOTARG", "vpi_handle_multi(vpiDerivative): a derivative is taken with respect to an argument", .{});
        return null;
    }
    for (systf.partialsOf(st.obj)) |p| {
        if (p.of != of or p.wrt != wrt) continue;
        const derivs = &st.b.derivs;
        for (derivs.items) |dv| if (dv.call == st.obj and dv.of == of and dv.wrt == wrt) return @ptrCast(dv);
        derivs.ensureUnusedCapacity(gpa, 1) catch return noMem();
        const dv = gpa.create(Deriv) catch return noMem();
        dv.* = .{ .call = st.obj, .of = of, .wrt = wrt };
        derivs.appendAssumeCapacity(dv);
        return @ptrCast(dv);
    }
    root.fail("UNDECLARED", "vpi_handle_multi(vpiDerivative): d({d})/d({d}) was not declared by derivtf", .{ of, wrt });
    return null;
}

fn noMem() vpiHandle {
    root.fail("NOMEM", "vpi_handle_multi(vpiDerivative): out of memory", .{});
    return null;
}

/// §12.32.2 "values can then be contributed to the derivative using the
/// vpi_put_value function in the calltf call back": a partial of the returned
/// value, or of an argument the device reads back (§12.22.2); any other
/// argument's is refused (NOPUT).
pub fn putDerivative(dv: *Deriv, v: f64) bool {
    const st = active_call orelse {
        root.fail("NOCALL", "vpi_put_value: a derivative takes a value during its call's calltf", .{});
        return false;
    };
    if (dv.call != st.obj) {
        root.fail("NOCALL", "vpi_put_value: that derivative belongs to another call", .{});
        return false;
    }
    const j: usize = @intCast(dv.wrt - 1);
    if (dv.of != 0) {
        const of: usize = @intCast(dv.of);
        const out = outputOf(st, of, "vpi_put_value") orelse return false;
        if (j >= out.n) return false;
        out.part()[(of - 1) * out.n + j] = v;
        out.put[of - 1] = true;
        dv.value = v;
        return true;
    }
    if (j >= st.partials.len) return false;
    st.partials[j] = v;
    dv.value = v;
    return true;
}

// ---------------------------------------------------------------------------
// Tests: the pieces that need no device library
// ---------------------------------------------------------------------------

test "§12.10 Table 12-2: vpiExpStrVal is C's %e, two exponent digits and a sign" {
    var buf: [analog_len]u8 = undefined;
    // Hand-derived as C's printf("%e") spells each.
    for ([_]struct { f64, []const u8 }{
        .{ 1234.5, "1.234500e+03" },
        .{ -0.00025, "-2.500000e-04" },
        .{ 0, "0.000000e+00" },
        .{ 1e100, "1.000000e+100" },
    }) |case| try std.testing.expectEqualStrings(case[1], printfE(&buf, case[0], 6) orelse "(refused)");
}

test "§12.10 Table 12-2: vpiStringVal is C's %g, and reports the form it took" {
    var buf: [analog_len]u8 = undefined;
    // C11 7.21.6.1 %g at precision 6: style e when the exponent is below -4
    // or at least 6, else style f with 5 - exponent fraction digits; then
    // trailing zeros and a bare point go. 9999999 rounds up into 1e+07.
    for ([_]struct { f64, []const u8, c_int }{
        .{ 0, "0", vpiDecStrVal },
        .{ 2.5, "2.5", vpiDecStrVal },
        .{ -1.5, "-1.5", vpiDecStrVal },
        .{ 100, "100", vpiDecStrVal },
        .{ 123456, "123456", vpiDecStrVal },
        .{ 1234567, "1.23457e+06", vpiExpStrVal },
        .{ 9999999, "1e+07", vpiExpStrVal },
        .{ 0.0001, "0.0001", vpiDecStrVal },
        .{ 0.00001, "1e-05", vpiExpStrVal },
    }) |case| {
        var chose: c_int = 0;
        try std.testing.expectEqualStrings(case[1], printfG(&buf, case[0], &chose) orelse "(refused)");
        try std.testing.expectEqual(case[2], chose);
    }
}

test "§12.10 Table 12-2: a non-finite value is C's inf, -inf or nan in the e and g forms" {
    // C11 7.21.6.1: "A double argument representing an infinity is converted
    // in one of the styles [-]inf or [-]infinity ... A double argument
    // representing a NaN is converted in one of the styles [-]nan". %g of
    // one has no exponent, so it reports vpiDecStrVal.
    var buf: [analog_len]u8 = undefined;
    for ([_]struct { f64, []const u8 }{
        .{ std.math.inf(f64), "inf" },
        .{ -std.math.inf(f64), "-inf" },
        .{ std.math.nan(f64), "nan" },
    }) |case| {
        var chose: c_int = 0;
        try std.testing.expectEqualStrings(case[1], printfE(&buf, case[0], 6) orelse "(refused)");
        try std.testing.expectEqualStrings(case[1], printfG(&buf, case[0], &chose) orelse "(refused)");
        try std.testing.expectEqual(vpiDecStrVal, chose);
    }
}

test "§12.10 analogString: vpiDecStrVal is the shortest decimal; another format is refused" {
    var buf: [analog_len]u8 = undefined;
    var chose: c_int = 0;
    const text = analogString(&buf, 0.5, vpiDecStrVal, &chose) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("0.5", std.mem.span(text));
    try std.testing.expect(analogString(&buf, 0.5, 99, &chose) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}

test "sameTime: one instant up to rounding, symmetric, and no wider" {
    // Relative 1e-12 of the larger magnitude, at least 1e-12 absolute.
    try std.testing.expect(sameTime(1, 1 + 1e-13));
    try std.testing.expect(sameTime(1 + 1e-13, 1));
    try std.testing.expect(!sameTime(1, 1 + 1e-11));
    try std.testing.expect(sameTime(1e9, 1e9 + 1e-4));
    try std.testing.expect(!sameTime(1e9, 1e9 + 1e-2));
    try std.testing.expect(sameTime(0, 1e-13));
    try std.testing.expect(!sameTime(0, 1e-11));
}

test "§12.10 Table 12-2: every finite real spells whole in the value buffer" {
    var chose: c_int = 0;
    var buf: [analog_len]u8 = undefined;
    for ([_]f64{ std.math.floatMax(f64), -std.math.floatMax(f64), -std.math.floatTrueMin(f64), -std.math.floatMin(f64), -1.2345678901234567e-300, 1e308 }) |x| {
        for ([_]c_int{ vpiDecStrVal, vpiExpStrVal, vpiStringVal }) |f| {
            const t = analogString(&buf, x, f, &chose) orelse return error.TestUnexpectedResult;
            const text = std.mem.span(t);
            const back = try std.fmt.parseFloat(f64, text);
            // %e and %g keep 6 or 7 digits; the decimal keeps every one.
            if (f == vpiDecStrVal) try std.testing.expectEqual(x, back) else try std.testing.expectApproxEqRel(x, back, 1e-5);
        }
    }
}

test "asDeriv: a handle is a derivative only when its binding handed it out" {
    try std.testing.expect(asDeriv(null) == null);
    var b: Binding = .{};
    defer b.detach();
    // Past the 64 a fixed array once held: every handle stays distinct and
    // valid while more are added.
    var first: ?*Deriv = null;
    for (0..200) |k| {
        try b.derivs.ensureUnusedCapacity(gpa, 1);
        const dv = try gpa.create(Deriv);
        dv.* = .{ .call = @intCast(k), .of = 0, .wrt = 1 };
        b.derivs.appendAssumeCapacity(dv);
        if (first == null) first = dv;
    }
    try std.testing.expect(derivOf(&b, @ptrCast(first.?)) == first.?);
    try std.testing.expectEqual(@as(u32, 199), derivOf(&b, @ptrCast(b.derivs.items[199])).?.call);
    try std.testing.expect(derivOf(&b, @ptrFromInt(@intFromPtr(first.?) + 1)) == null);
    var other: Deriv = .{ .call = 0, .of = 0, .wrt = 1 };
    try std.testing.expect(derivOf(&b, @ptrCast(&other)) == null);
    // Another library's binding handed out none of them.
    const empty: Binding = .{};
    try std.testing.expect(derivOf(&empty, @ptrCast(first.?)) == null);
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

test "§12.7-§12.9, §12.36 with no library: nothing to run, reject or re-solve" {
    setPoint(null, 0, 0, 0);
    var b: Binding = .{};
    try std.testing.expectError(error.NoLibrary, b.run(.{ .kind = .op }));
    try std.testing.expect(!rejectStep());
    try std.testing.expect(!failConverge());
    try std.testing.expect(analysis() == null);
    try std.testing.expectEqual(@as(f64, 0), acceptedTime());
    try std.testing.expectEqual(@as(f64, 0), vpi_get_analog_freq());
    try std.testing.expectEqual(@as(f64, 0), vpi_get_analog_delta());
    try std.testing.expectEqual(@as(f64, 0), vpi_get_analog_time());
    const q: root.Obj = .{ .kind = .quantity, .owner = .none, .name = "", .full = "" };
    try std.testing.expectError(error.NoAnalysis, quantityValue(&q));
}

test "§12.7-§12.9, §12.18 setPoint: the routines answer the point a host set, by its kind" {
    setPoint(null, 0, 0, 0);
    defer setPoint(null, 0, 0, 0);
    // A transient point at 2 ms reached by a 1 us step: §12.9 the time, §12.7
    // the step, §12.8 zero outside a small-signal analysis.
    setPoint(.{ .kind = .tran, .stop = 5e-3 }, 2e-3, 1e-6, 0);
    try std.testing.expectEqual(@as(f64, 2e-3), vpi_get_analog_time());
    try std.testing.expectEqual(@as(f64, 1e-6), vpi_get_analog_delta());
    try std.testing.expectEqual(@as(f64, 0), vpi_get_analog_freq());
    try std.testing.expectEqual(@as(f64, 5e-3), analysis().?.stop);
    // An AC point at 1 kHz: time and step are zero there (§12.7, §12.9
    // "during DC"; the sweep stands on a DC operating point), freq is it.
    setPoint(.{ .kind = .ac }, 2e-3, 1e-6, 1e3);
    try std.testing.expectEqual(@as(f64, 0), vpi_get_analog_time());
    try std.testing.expectEqual(@as(f64, 0), vpi_get_analog_delta());
    try std.testing.expectEqual(@as(f64, 1e3), vpi_get_analog_freq());
    // Null: between analyses, no bounds to read.
    setPoint(null, 0, 0, 0);
    try std.testing.expect(analysis() == null);
}

test "holds: a calls-only library holds no unknown, ground needs none" {
    var b: Binding = .{};
    try std.testing.expect(holds(&b, ground));
    try std.testing.expect(!holds(&b, 0));
    b.n_x = 2;
    try std.testing.expect(holds(&b, 1));
    try std.testing.expect(!holds(&b, 2));
}

/// A calls-only library (#83's stub) of one call, `$c` at source token 5,
/// whose argument 1 the device reads back.
const OneCall = struct {
    const none = [0]f64{};
    fn open(_: u8) callconv(.c) void {}
    fn solve(_: f64, _: f64, _: bool, _: bool) callconv(.c) bool {
        return true;
    }
    fn accept() callconv(.c) void {}
    fn x() callconv(.c) [*]const f64 {
        return &none;
    }
    fn zero() callconv(.c) usize {
        return 0;
    }
    fn one() callconv(.c) usize {
        return 1;
    }
    fn row(_: usize, _: *[4]i32) callconv(.c) void {}
    fn rows(_: [*]f64) callconv(.c) void {}
    fn hooks(_: ?*anyopaque, _: ?HostCall, _: ?HostOut) callconv(.c) void {}
    fn name(_: usize, len: *usize) callconv(.c) [*]const u8 {
        len.* = 2;
        return "$c";
    }
    fn tok(_: usize) callconv(.c) u32 {
        return 5;
    }
    fn readBack(_: usize) callconv(.c) u64 {
        return 1;
    }
    fn ac(_: f64, _: [*]f64, _: [*]f64) callconv(.c) bool {
        return false;
    }
    const lib: Lib = .{
        .open = open,
        .solve = solve,
        .accept = accept,
        .x = x,
        .n_u = zero,
        .n_rows = zero,
        .row = row,
        .rows = rows,
        .n_shares = zero,
        .shares = rows,
        .systf = hooks,
        .n_systf = one,
        .systf_name = name,
        .systf_tok = tok,
        .systf_outs = readBack,
        .ac = ac,
    };
    const arg = [_]code.List{.{ .tag = code.vpiArgument, .items = &.{1} }};

    /// A design holding that call (object 0, full name `full`) and its
    /// argument (object 1): the same name, token and index in every design
    /// it builds, so only the binding tells two apart.
    fn design(full: []const u8) !root.Design {
        const a = std.testing.allocator;
        const objs = try a.alloc(root.Obj, 2);
        objs[0] = .{ .kind = .code, .owner = .none, .name = "$c", .full = full, .vtype = code.vpiSysFuncCall, .in_analog = true, .src_tok = 5, .lists = &arg };
        objs[1] = .{ .kind = .code, .owner = .none, .name = "x", .full = "x" };
        return .{ .gpa = a, .arena = .init(a), .objects = objs, .scopes = &.{}, .top_modules = &.{}, .by_name = .empty, .iters = .empty };
    }

    /// The registration's calltf: records the design it ran in, and puts
    /// 1 (library "A") or 2 (any other), plus 10 per host instance, on
    /// argument 1.
    var seen_full: []const u8 = "";
    var seen_objects: [*]root.Obj = undefined;
    fn calltf(cb: *callback.CbData) callconv(.c) c_int {
        const d = &root.design.?;
        const o = root.asObj(cb.obj).?;
        seen_full = o.full;
        seen_objects = d.objects.ptr;
        const tag: f64 = if (o.full[0] == 'A') 1 else 2;
        _ = putArg(&d.objects[1], tag + 10 * @as(f64, @floatFromInt(systf.active_inst)));
        return 0;
    }
};

test "Binding: two libraries at once, each call in its own design, each (library, instance) its own outputs (VerA #84)" {
    root.close();
    defer root.close();
    root.design = try OneCall.design("A.$c");
    var tf = "$c".*;
    const reg: systf.AnalogSystfData = .{ .type = systf.vpiAnalogSysFunc, .sysfunctype = systf.vpiRealFunc, .tfname = &tf, .calltf = OneCall.calltf, .compiletf = null, .sizetf = null, .derivtf = null, .user_data = null };
    try std.testing.expect(systf.vpi_register_analog_systf(&reg) != null);
    var a: Binding = .{};
    defer a.detach();
    var b: Binding = .{};
    defer b.detach();
    try a.attach(OneCall.lib, null);
    try b.attach(OneCall.lib, try OneCall.design("B.$c"));

    const args = [1]f64{0.5};
    var p: [1]f64 = undefined;
    // A's call runs in the installed design; B's in its own, swapped in for
    // the call and back out after it.
    _ = a.call(0, 0, &args, &p);
    try std.testing.expectEqualStrings("A.$c", OneCall.seen_full);
    try std.testing.expect(OneCall.seen_objects == root.design.?.objects.ptr);
    _ = b.call(0, 0, &args, &p);
    try std.testing.expectEqualStrings("B.$c", OneCall.seen_full);
    try std.testing.expect(OneCall.seen_objects != root.design.?.objects.ptr);
    try std.testing.expectEqualStrings("A.$c", root.design.?.objects[0].full);
    _ = a.call(1, 0, &args, &p);

    // Each (library, instance) reads back what its own calltf put: a value
    // with no partial.
    try std.testing.expectEqual(@as(f64, 1), a.output(0, 0, 1, &args, &p));
    try std.testing.expectEqual(@as(f64, 0), p[0]);
    try std.testing.expectEqual(@as(f64, 11), a.output(1, 0, 1, &args, &p));
    try std.testing.expectEqual(@as(f64, 2), b.output(0, 0, 1, &args, &p));
    // B's instance 1 never ran: its argument keeps its value, partial 1.
    try std.testing.expectEqual(@as(f64, 0.5), b.output(1, 0, 1, &args, &p));
    try std.testing.expectEqual(@as(f64, 1), p[0]);
    // Outside any call the routines answer for A, on the installed design.
    try std.testing.expect(bound().? == &a);
}

test "§12.10 vpiStringVal: the real part's %g choice is the format reported, whatever the imaginary part chose" {
    root.close();
    defer root.close();
    const a = std.testing.allocator;
    // A potential quantity (object 0) of a branch (object 1) from unknown 0
    // to ground.
    const objs = try a.alloc(root.Obj, 2);
    objs[0] = .{ .kind = .quantity, .owner = .none, .name = "", .full = "", .cold = 0 };
    objs[1] = .{ .kind = .branch, .owner = .none, .name = "b", .full = "b", .cold = 1 };
    const colds = try a.alloc(root.Cold, 2);
    colds[0] = .{ .branch = 1 };
    colds[1] = .{ .hi_row = 0 };
    root.design = .{ .gpa = a, .arena = .init(a), .objects = objs, .cold = colds, .scopes = &.{}, .top_modules = &.{}, .by_name = .empty, .iters = .empty };
    // An AC point whose phasor is 2.5 + 1e-7 j: %g spells the real part as a
    // decimal and the imaginary part with an exponent.
    var ac_x = [2]f64{ 2.5, 1e-7 };
    var b: Binding = .{ .lib = OneCall.lib, .n_x = 1, .ac_x = &ac_x, .have_solution = true };
    installed = &b;
    defer installed = null;
    setPoint(.{ .kind = .ac }, 0, 0, 1e3);
    defer setPoint(null, 0, 0, 0);
    var v: AnalogValue = .{ .format = vpiStringVal, .real = .{ .real = 0 }, .imaginary = .{ .real = 0 } };
    vpi_get_analog_value(root.handleOf(&root.design.?.objects[0]), &v);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expectEqualStrings("2.5", std.mem.span(v.real.str));
    try std.testing.expectEqualStrings("1e-07", std.mem.span(v.imaginary.str));
    try std.testing.expectEqual(vpiDecStrVal, v.format);
    // The real-only formats keep their format.
    v.format = vpiRealVal;
    vpi_get_analog_value(root.handleOf(&root.design.?.objects[0]), &v);
    try std.testing.expectEqual(@as(f64, 1e-7), v.imaginary.real);
    try std.testing.expectEqual(vpiRealVal, v.format);
}
