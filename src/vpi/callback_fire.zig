//! Callback dispatch: an occurrence (an action reason, a time, a value
//! change, a statement, an override, an analog step) -> each live registered
//! callback for it, called with a fresh `CbData`.
//! Cites: VAMS-2023 §12.31.1-§12.31.4; IEEE 1364-2005 §26.6.40, §27.33.
//!
//! Contents:
//! - `pub fn fireAll(reason: c_int, from: ?*const Obj) void`
//! - `pub fn endOfCompile() void`
//! - `pub fn startOfSimulation() void`
//! - `pub fn endOfSimulation() void`
//! - `pub fn startOfReset() void`
//! - `pub fn endOfReset() void`
//! - `pub fn interactiveScopeChange(scope: *const Obj) void`
//! - `pub fn onTchk(r: *digital.Run, check: u32) void`
//! - `pub fn runError(e: anyerror) void`
//! - `pub fn onRunError(r: *digital.Run) void`
//! - `pub fn pliError() void`
//! - `pub fn nextDue(after: u64, inclusive: bool) ?u64`
//! - `pub fn pendingTimes(out: *std.ArrayList(u64), a: std.mem.Allocator, now: u64) !void`
//! - `pub fn isDue(reason: c_int, now: u64) bool`
//! - `pub fn fireDue(reason: c_int, now: u64) void`
//! - `pub fn fireNext(now: u64) void`
//! - `pub fn fireSlot(slot: u32) void`
//! - `pub fn fireOverride(reason: c_int, o: *Obj) void`
//! - `pub fn onDone(r: *digital.Run, pc: u32) digital.Error!void`
//! - `pub fn fireStmt(r: *digital.Run, pc: u32) digital.Error!void`
//! - `pub fn fireAnalog(reason: c_int) void`
//! - `pub fn convergenceRejected() bool`
//! - `pub fn fireTimed(t: f64) void`
//! - `pub fn nextForced(after: f64, until: f64) ?f64`

const std = @import("std");
const digital = @import("sim").digital;
const sim = @import("sim");
const analog = @import("analog.zig");
const callback = @import("callback.zig");
const run = @import("run.zig");
const schema = @import("schema.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const systf = @import("systf.zig");
const trust = @import("trust.zig");
const value = @import("value.zig");
const user = @import("vpi_user.zig");
const abi = @import("abi.zig");
const Cb = callback.Cb;
const CbData = abi.CbData;
const Obj = schema.Obj;
const Time = abi.Time;
const Value = abi.Value;

/// Every live callback of `reason`, in registration order, with `from` as
/// `call` reads it. Only the ones registered BEFORE this dispatch began: a
/// callback registered from inside one is for a later occurrence (p02_07's
/// heir must not see the change whose dispatch registered it). Asserts that
/// `reason` is a §12.31 reason, that a reason whose obj is the occurrence's
/// has its `from`, and that the dispatch leaves the nesting depth and the
/// registrations it began with in place.
pub fn fireAll(reason: c_int, from: ?*const Obj) void {
    std.debug.assert(reason >= user.cbValueChange);
    std.debug.assert(reason <= user.cbPLIError or callback.isAnalogReason(reason));
    std.debug.assert(from != null or (reason != user.cbInteractiveScopeChange and reason != user.cbTchkViolation));
    const n = callback.cbs.items.len;
    const depth = callback.depth;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (!cb.dead and cb.reason == reason) _ = call(cb, cb.index, from);
    }
    std.debug.assert(callback.depth == depth);
    std.debug.assert(callback.cbs.items.len >= n);
    callback.sweep();
}

/// §12.31.4 cbEndOfCompile — "End of simulation data structure compilation
/// or build": after the design is elaborated and the startup routines ran.
/// Asserts that it is fired outside any dispatch, by the host.
pub fn endOfCompile() void {
    std.debug.assert(callback.depth == 0);
    // The build's last step before it is "end": the registered systfs'
    // compiletf/sizetf/derivtf at each call site (§12.32.1, §12.33.1).
    systf.buildCalls();
    fireAll(user.cbEndOfCompile, null);
    std.debug.assert(callback.depth == 0);
}

/// §12.31.4 cbStartOfSimulation — "beginning of time 0 simulation cycle".
/// Asserts that it is fired outside any dispatch, by the host or the run.
pub fn startOfSimulation() void {
    std.debug.assert(callback.depth == 0);
    fireAll(user.cbStartOfSimulation, null);
    std.debug.assert(callback.depth == 0);
}

/// §12.31.4 cbEndOfSimulation — "e.g., $finish system task executed".
/// Asserts that it is fired outside any dispatch, by the host or the run.
pub fn endOfSimulation() void {
    std.debug.assert(callback.depth == 0);
    fireAll(user.cbEndOfSimulation, null);
    std.debug.assert(callback.depth == 0);
}

/// IEEE 1364-2005 §27.33.3 cbStartOfReset: a §12.36 vpiReset is about to
/// take the run back to time 0 (`run.simulate`). Asserts that it is fired
/// by the run, outside any dispatch.
pub fn startOfReset() void {
    std.debug.assert(callback.depth == 0);
    fireAll(user.cbStartOfReset, null);
    std.debug.assert(callback.depth == 0);
}

/// IEEE 1364-2005 §27.33.3 cbEndOfReset: the run is back at time 0, before
/// it goes on (or ends, for a stop_value of 0). Asserts that the clock is
/// back at 0 and that it is fired by the run, outside any dispatch.
pub fn endOfReset() void {
    std.debug.assert(run.now() == 0);
    std.debug.assert(callback.depth == 0);
    fireAll(user.cbEndOfReset, null);
}

/// IEEE 1364-2005 §27.33.3 cbInteractiveScopeChange: "obj shall be a handle
/// to the new scope". Asserts that `scope` is a module or a scope-like code
/// row with a name (`vpi_sim_control` checked the application's handle).
pub fn interactiveScopeChange(scope: *const Obj) void {
    std.debug.assert(scope.kind == .module or scope.kind == .code);
    std.debug.assert(scope.full.len != 0);
    fireAll(user.cbInteractiveScopeChange, scope);
}

/// `digital.Run.checks.hook`: timing check `check` of the run reported a
/// violation. IEEE 1364-2005 §27.33.3 / VAMS 12.31.4 cbTchkViolation,
/// "Timing check error occurred", and "For cbTchkViolation callbacks, the obj
/// field shall be a handle to the timing check": the §11.6.15 object built
/// from the same command (`src_tok`) in the same instance. Asserts that a
/// model is installed (the hook is attached with one) and that the row found
/// is that timing check.
pub fn onTchk(r: *digital.Run, check: u32) void {
    std.debug.assert(session.design != null);
    if (!wanted(user.cbTchkViolation)) return;
    const site = r.tchkSite(check);
    const d = &session.design.?;
    const tchk = for (d.objects) |*o| {
        if (o.kind != .code or o.vtype != user.vpiTchk or o.src_tok != site.tok) continue;
        const owner = o.owner;
        if (owner == .none) continue;
        if (d.scope(owner).engine == site.scope) break o;
    } else return;
    std.debug.assert(tchk.vtype == user.vpiTchk);
    std.debug.assert(tchk.src_tok == site.tok);
    fireAll(user.cbTchkViolation, tchk);
}

/// IEEE 1364-2005 §27.33.3 cbError: "Simulation run-time error occurred".
/// §12.31.4: "On a cbError callback, the routine vpi_chk_error() can be
/// called to retrieve error information" — recorded first, and not as a
/// cbPLIError, which is a different reason. Asserts that the run raises it
/// outside any dispatch, and that the status reads vpiError before cbError.
pub fn runError(e: anyerror) void {
    std.debug.assert(callback.depth == 0);
    status.noteError("RUNTIME", "simulation run-time error: {t}", .{e});
    std.debug.assert(status.vpi_chk_error(null) == user.vpiError);
    fireAll(user.cbError, null);
}

/// cbError for a run-time error the run survives (IEEE 1364-2005 §17.2.9's
/// terminated `$readmem` load): recorded for `vpi_chk_error`, then fired.
/// Asserts that `r` is the attached run and that the status reads vpiError
/// before cbError.
pub fn onRunError(r: *digital.Run) void {
    std.debug.assert(run.attached() == r);
    status.noteError("RUNTIME", "IEEE 1364-2005 §17.2.9: a $readmem load was terminated", .{});
    std.debug.assert(status.vpi_chk_error(null) == user.vpiError);
    fireAll(user.cbError, null);
}

/// IEEE 1364-2005 §27.33.3 cbPLIError: "Simulation run-time error occurred
/// in a PLI function call", fired as the routine records it. A routine a
/// cbPLIError callback calls that fails fires none. Asserts that the
/// failing routine recorded its error first, and that the dispatch unwinds.
pub fn pliError() void {
    std.debug.assert(status.vpi_chk_error(null) == user.vpiError);
    if (callback.active == user.cbPLIError) return;
    const depth = callback.depth;
    fireAll(user.cbPLIError, null);
    std.debug.assert(callback.depth == depth);
}

/// The earliest tick a live time callback is due at that is strictly after
/// `after` — or AT it when `inclusive` — or null. Asserts that the answer
/// is in that range.
pub fn nextDue(after: u64, inclusive: bool) ?u64 {
    var best: ?u64 = null;
    for (callback.cbs.items) |cb| {
        if (cb.dead or !callback.isTimeReason(cb.reason) or cb.reason == user.cbNextSimTime) continue;
        if (cb.due < after or (!inclusive and cb.due == after)) continue;
        best = @min(best orelse cb.due, cb.due);
    }
    std.debug.assert((best orelse after) >= after);
    std.debug.assert(inclusive or best == null or best.? > after);
    return best;
}

/// Every pending time a time callback holds, for §11.6.25's vpiTimeQueue.
/// A cbReadOnlySynch due at `now` holds none: IEEE 1364-2005 §26.6.40(c)
/// returns the current queue only "if there are events that precede read
/// only sync" (VD-046). One due later still makes its time a queue (VD-047).
/// Asserts that `now` is the run's clock, and that at most one time is
/// appended per registration.
pub fn pendingTimes(out: *std.ArrayList(u64), a: std.mem.Allocator, now: u64) !void {
    std.debug.assert(now == run.now());
    const before = out.items.len;
    for (callback.cbs.items) |cb| {
        if (cb.dead or !callback.isTimeReason(cb.reason) or cb.reason == user.cbNextSimTime) continue;
        if (cb.reason == user.cbReadOnlySynch and cb.due == now) continue;
        try out.append(a, cb.due);
    }
    std.debug.assert(out.items.len - before <= callback.cbs.items.len);
}

/// Whether a live `reason` callback is due at `now` (what `fireDue` would
/// run). Asserts that `reason` is a time reason with a due time of its own.
pub fn isDue(reason: c_int, now: u64) bool {
    std.debug.assert(callback.isTimeReason(reason));
    std.debug.assert(reason != user.cbNextSimTime);
    for (callback.cbs.items) |cb| {
        if (!cb.dead and cb.reason == reason and cb.due == now) return true;
    }
    return false;
}

/// Fires the callbacks of `reason` due at `now`, each at most once: a time
/// callback is one-shot (§12.31.2 "shall occur ... a specified time"), so it
/// is removed as it fires and its handle stops being valid. Asserts that
/// `reason` is a time reason with a due time of its own, and that the
/// dispatch leaves the nesting depth and the registrations in place.
pub fn fireDue(reason: c_int, now: u64) void {
    std.debug.assert(callback.isTimeReason(reason));
    std.debug.assert(reason != user.cbNextSimTime);
    const n = callback.cbs.items.len;
    const depth = callback.depth;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or cb.reason != reason or cb.due != now) continue;
        callback.retire(cb);
        _ = call(cb, cb.index, null);
    }
    std.debug.assert(callback.depth == depth);
    std.debug.assert(callback.cbs.items.len >= n);
    callback.sweep();
}

/// §12.31.2 cbNextSimTime: "before execution of events in the next event
/// queue" — the first time queue after the one it was registered in.
/// Asserts that `now` is the run's clock, and that the dispatch leaves the
/// nesting depth and the registrations in place.
pub fn fireNext(now: u64) void {
    std.debug.assert(now == run.now());
    const n = callback.cbs.items.len;
    const depth = callback.depth;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or cb.reason != user.cbNextSimTime or now <= cb.since) continue;
        callback.retire(cb);
        _ = call(cb, cb.index, null);
    }
    std.debug.assert(callback.depth == depth);
    std.debug.assert(callback.cbs.items.len >= n);
    callback.sweep();
}

/// §12.31.1 cbValueChange for every callback watching the object stored in
/// `slot`, which the engine just changed. Asserts that a model is installed
/// (the hook is attached with one), and that the dispatch leaves the nesting
/// depth and the registrations in place.
pub fn fireSlot(slot: u32) void {
    std.debug.assert(session.design != null);
    const n = callback.cbs.items.len;
    const depth = callback.depth;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or cb.reason != user.cbValueChange) continue;
        const target = trust.asObj(cb.obj) orelse continue;
        if (target.slot.get() == slot) {
            _ = call(cb, cb.index, null);
            continue;
        }
        // §12.31.1: a callback on an array hears each element's change, with
        // that element's value and "the index of the memory word or variable
        // select which changed value".
        const d = &session.design.?;
        for (schema.coldOf(target).members) |m| {
            const word = d.obj(m);
            if (word.slot.get() != slot) continue;
            // `s_cb_data.index` is a PLI_INT32; a design's word index is
            // any 64-bit integer (§4.9).
            const index = std.math.cast(c_int, d.obj(word.index).value.?.int) orelse {
                status.noteError("RANGE", "cbValueChange on `{s}`: the changed word's index {d} passes a PLI_INT32; the callback is not called", .{ target.full, d.obj(word.index).value.?.int });
                continue;
            };
            _ = call(cb, index, word);
        }
    }
    std.debug.assert(callback.depth == depth);
    std.debug.assert(callback.cbs.items.len >= n);
    callback.sweep();
}

/// §12.31.1 cbForce/cbRelease after `o` was forced or released: every
/// callback registered on `o`, and every one registered with a NULL obj.
/// "the object returned in the obj field shall be a handle to the force,
/// release ... statement"; a vpi_put_value force has no statement, so obj is
/// the object it forced. The value is `o`'s, after the force or release. A
/// design statement's force or release fires through `onDone` instead.
/// Asserts that `reason` is cbForce or cbRelease, and that the dispatch
/// leaves the nesting depth and the registrations in place.
pub fn fireOverride(reason: c_int, o: *Obj) void {
    std.debug.assert(reason == user.cbForce or reason == user.cbRelease);
    const n = callback.cbs.items.len;
    const depth = callback.depth;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or cb.reason != reason) continue;
        if (cb.obj != null and trust.asObj(cb.obj) != o) continue;
        _ = call(cb, cb.index, o);
    }
    std.debug.assert(callback.depth == depth);
    std.debug.assert(callback.cbs.items.len >= n);
    callback.sweep();
}

/// `digital.DoneHook`: a design statement completed. A §9.3 `force`,
/// `release`, `assign` or `deassign` fires cbForce, cbRelease, cbAssign or
/// cbDeassign with obj the statement, on each callback registered with a NULL
/// obj or on one of the variables or nets it overrides. A `disable` fires
/// cbDisable on each callback whose named block it disabled. Asserts that
/// `pc` is an instruction of `r` and that a recorded site starts at or
/// before it.
pub fn onDone(r: *digital.Run, pc: u32) digital.Error!void {
    std.debug.assert(pc < r.program.code.items.len);
    const site = r.host.done_sites.get(pc) orelse return;
    std.debug.assert(site.pc <= pc);
    const reason: c_int = switch (r.program.code.items[pc]) {
        .override_on => |o| if (o.force) user.cbForce else user.cbAssign,
        .override_off => |o| if (o.force) user.cbRelease else user.cbDeassign,
        .disable_block => |b| {
            const n = callback.cbs.items.len;
            for (0..n) |i| {
                const cb = callback.cbs.items[i];
                if (cb.dead or cb.reason != user.cbDisable) continue;
                for (cb.sites) |st| if (st.pc >= b.start and st.pc < b.end) {
                    _ = call(cb, cb.index, null);
                    break;
                };
            }
            callback.sweep();
            return;
        },
        else => return, // else: `done_sites` keys only these three instructions
    };
    const d = &session.design.?;
    const want: c_int = switch (reason) {
        user.cbForce => user.vpiForce,
        user.cbRelease => user.vpiRelease,
        user.cbAssign => user.vpiAssignStmt,
        else => user.vpiDeassign,
    };
    const stmt = for (d.objects) |*o| {
        if (o.kind == .code and o.vtype == want and o.stmt == site.stmt and o.owner != .none and d.scope(o.owner).engine == site.scope) break o;
    } else return;
    std.debug.assert(stmt.vtype == want);
    const n = callback.cbs.items.len;
    const depth = callback.depth;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or cb.reason != reason) continue;
        if (cb.obj != null) {
            const target = (trust.asObj(cb.obj) orelse continue).slot.get() orelse continue;
            // The slots the statement's instructions override (a
            // concatenation overrides several).
            const hit = for (r.program.code.items[site.pc .. pc + 1]) |ins| switch (ins) {
                .override_on => |o| if (o.slot == target) break true,
                .override_off => |o| if (o.slot == target) break true,
                else => {}, // else: only an override names a slot it overrides
            } else false;
            if (!hit) continue;
        }
        _ = call(cb, cb.index, stmt);
    }
    std.debug.assert(callback.depth == depth);
    callback.sweep();
}

/// Every live cbStmt at `pc`, in registration order, each once per
/// statement starting there, outer first: "Just before the indicated
/// statement executes". Asserts that `pc` is an instruction of `r` and that
/// a model is installed, and that the dispatch leaves the nesting depth and
/// the registrations in place.
pub fn fireStmt(r: *digital.Run, pc: u32) digital.Error!void {
    std.debug.assert(pc < r.program.code.items.len);
    std.debug.assert(session.design != null);
    const d = &session.design.?;
    const n = callback.cbs.items.len;
    const depth = callback.depth;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.reason != user.cbStmt) continue;
        for (cb.sites) |st| {
            if (cb.dead) break;
            if (st.pc == pc) _ = call(cb, 0, d.obj(st.obj));
        }
    }
    std.debug.assert(callback.depth == depth);
    std.debug.assert(callback.cbs.items.len >= n);
    callback.sweep();
}

/// acbInitialStep, acbFinalStep or acbAcceptedPoint: every live callback of
/// `reason` registered before this dispatch began. These persist: §12.31.3
/// ties them to a kind of solution, not to one. Asserts that `reason` is
/// one of those three, not a timed or a convergence reason, which have
/// their own dispatch.
pub fn fireAnalog(reason: c_int) void {
    std.debug.assert(callback.isAnalogReason(reason));
    std.debug.assert(reason == user.acbInitialStep or reason == user.acbFinalStep or reason == user.acbAcceptedPoint);
    fireAll(reason, null);
}

/// acbConvergenceTest, "prior acceptance of the analog solution for the
/// given time (this callback allows rejection of the analog solution at that
/// time and backup to an earlier time)". Every callback runs; the solution
/// is rejected if ANY returned non-zero.
///
/// Implementation-defined: the LRM does not say which `int` rejects. 0
/// accepts, as 0 is every other callback's uneventful return; anything else
/// rejects. Asserts that the dispatch leaves the nesting depth and the
/// registrations in place.
pub fn convergenceRejected() bool {
    var rejected = false;
    const n = callback.cbs.items.len;
    const depth = callback.depth;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or cb.reason != user.acbConvergenceTest) continue;
        if (call(cb, cb.index, null) != 0) rejected = true;
    }
    std.debug.assert(callback.depth == depth);
    std.debug.assert(callback.cbs.items.len >= n);
    callback.sweep();
    return rejected;
}

/// acbAbsTime / acbElapsedTime due upon the solution accepted at `t`: each
/// is delivered once and then retired — AFTER its routine returns, so a
/// routine that removes itself is removing a live callback (§12.34 returns 1
/// for it, p03_04). Asserts that `t` is an instant of the analysis (finite,
/// not negative) and that the dispatch leaves the nesting depth in place.
pub fn fireTimed(t: f64) void {
    std.debug.assert(std.math.isFinite(t));
    std.debug.assert(t >= 0);
    const n = callback.cbs.items.len;
    const depth = callback.depth;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or (cb.reason != user.acbAbsTime and cb.reason != user.acbElapsedTime)) continue;
        if (!analog.sameTime(cb.due_real, t)) continue;
        _ = call(cb, cb.index, null);
        if (!cb.dead) callback.retire(cb);
    }
    std.debug.assert(callback.depth == depth);
    callback.sweep();
}

/// The earliest acbAbsTime/acbElapsedTime instant strictly after `after`
/// and at most `until`: the next solution §12.31.3 says "shall" be forced.
/// Asserts that `after <= until`, and that the answer is in that range.
pub fn nextForced(after: f64, until: f64) ?f64 {
    std.debug.assert(after <= until);
    var best: ?f64 = null;
    for (callback.cbs.items) |cb| {
        if (cb.dead or (cb.reason != user.acbAbsTime and cb.reason != user.acbElapsedTime)) continue;
        if (cb.due_real <= after or analog.sameTime(cb.due_real, after) or cb.due_real > until) continue;
        best = @min(best orelse cb.due_real, cb.due_real);
    }
    std.debug.assert((best orelse until) <= until);
    std.debug.assert((best orelse until) > after);
    return best;
}

// ---- private ----

/// Call `cb` with a FRESH s_cb_data — §12.31.1 "this is not a pointer to the
/// same structure which was passed to vpi_register_cb()" — whose time and
/// value are filled in the registered type and format. A value-change
/// callback reads its value from `from`: the array element that changed, or
/// the registered object itself.
fn call(cb: *Cb, index: c_int, from: ?*const Obj) c_int {
    const override = cb.reason == user.cbForce or cb.reason == user.cbRelease or cb.reason == user.cbAssign or cb.reason == user.cbDeassign;
    std.debug.assert(from != null or !(override or cb.reason == user.cbStmt or cb.reason == user.cbInteractiveScopeChange or cb.reason == user.cbTchkViolation));
    std.debug.assert(callback.isAnalogReason(cb.reason) or cb.reason <= user.cbPLIError);
    var t: Time = std.mem.zeroes(Time);
    var data: CbData = .{
        .reason = cb.reason,
        .cb_rtn = cb.rtn,
        .obj = if (override or cb.reason == user.cbStmt or cb.reason == user.cbInteractiveScopeChange or cb.reason == user.cbTchkViolation) @ptrCast(@constCast(from.?)) else cb.obj,
        .time = null,
        .value = null,
        .index = index,
        .user_data = cb.user_data,
    };
    if (callback.isAnalogReason(cb.reason)) {
        // §12.31.3's time is the analog clock's, in seconds.
        if (cb.time_type != user.vpiSuppressTime) {
            t = cb.time;
            t.type = user.vpiScaledRealTime;
            t.real = analog.time();
            data.time = &t;
        }
    } else if (cb.time_type != user.vpiSuppressTime) {
        t.type = cb.time_type;
        run.timeNow(cb.obj, &t);
        data.time = &t;
    }
    var v: Value = std.mem.zeroes(Value);
    if ((cb.reason == user.cbValueChange or override) and cb.value_format != user.vpiSuppressVal) {
        // A callback on every override (obj NULL) of a target the model
        // holds no object for has no value to give.
        if (lhsOf(from) orelse trust.asObj(cb.obj)) |target| {
            v.format = cb.value_format;
            value.read(target, &v, &value.cb_store);
            data.value = &v;
        }
    }
    const depth = callback.depth;
    callback.depth += 1;
    defer callback.depth -= 1;
    const outer = callback.active;
    callback.active = cb.reason;
    defer callback.active = outer;
    const verdict = cb.rtn(&data);
    // Every dispatch the routine started has unwound.
    std.debug.assert(callback.depth == depth + 1);
    std.debug.assert(callback.active == cb.reason);
    return verdict;
}

/// What an override callback reads its value from: a §9.3 statement's
/// left-hand side ("the resultant value of the left-hand expression"), or
/// `from` itself, the object a vpi_put_value force wrote.
fn lhsOf(from: ?*const Obj) ?*const Obj {
    const o = from orelse return null;
    if (o.stmt == .none) return o;
    std.debug.assert(o.kind == .code);
    const lhs = schema.edgeTo(o, user.vpiLhs);
    if (lhs == schema.ObjId.none) return null;
    const target = session.design.?.obj(lhs);
    std.debug.assert(target != o);
    return target;
}

/// Whether any live callback has `reason`, so `onTchk` searches the design
/// for its timing check only when someone will hear it.
fn wanted(reason: c_int) bool {
    std.debug.assert(reason >= user.cbValueChange);
    std.debug.assert(reason <= user.cbPLIError);
    for (callback.cbs.items) |cb| if (!cb.dead and cb.reason == reason) return true;
    return false;
}
