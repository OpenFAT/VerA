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
//! - `pub fn onRunError(_: *digital.Run) void`
//! - `pub fn pliError() void`
//! - `pub fn nextDue(after: u64, inclusive: bool) ?u64`
//! - `pub fn pendingTimes(out: *std.ArrayList(u64), a: std.mem.Allocator, now: u64) !void`
//! - `pub fn isDue(reason: c_int, now: u64) bool`
//! - `pub fn fireDue(reason: c_int, now: u64) void`
//! - `pub fn fireNext(now: u64) void`
//! - `pub fn fireSlot(slot: u32) void`
//! - `pub fn fireOverride(reason: c_int, o: *Obj) void`
//! - `pub fn onDone(r: *digital.Run, pc: u32) digital.Error!void`
//! - `pub fn fireStmt(_: *digital.Run, pc: u32) digital.Error!void`
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
/// heir must not see the change whose dispatch registered it).
pub fn fireAll(reason: c_int, from: ?*const Obj) void {
    const n = callback.cbs.items.len;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (!cb.dead and cb.reason == reason) _ = call(cb, cb.index, from);
    }
    callback.sweep();
}

/// §12.31.4 cbEndOfCompile — "End of simulation data structure compilation
/// or build": after the design is elaborated and the startup routines ran.
pub fn endOfCompile() void {
    // The build's last step before it is "end": the registered systfs'
    // compiletf/sizetf/derivtf at each call site (§12.32.1, §12.33.1).
    systf.buildCalls();
    fireAll(user.cbEndOfCompile, null);
}

/// §12.31.4 cbStartOfSimulation — "beginning of time 0 simulation cycle".
pub fn startOfSimulation() void {
    fireAll(user.cbStartOfSimulation, null);
}

/// §12.31.4 cbEndOfSimulation — "e.g., $finish system task executed".
pub fn endOfSimulation() void {
    fireAll(user.cbEndOfSimulation, null);
}

/// IEEE 1364-2005 §27.33.3 cbStartOfReset: a §12.36 vpiReset is about to
/// take the run back to time 0 (`run.simulate`).
pub fn startOfReset() void {
    fireAll(user.cbStartOfReset, null);
}

/// IEEE 1364-2005 §27.33.3 cbEndOfReset: the run is back at time 0, before
/// it goes on (or ends, for a stop_value of 0).
pub fn endOfReset() void {
    fireAll(user.cbEndOfReset, null);
}

/// IEEE 1364-2005 §27.33.3 cbInteractiveScopeChange: "obj shall be a handle
/// to the new scope".
pub fn interactiveScopeChange(scope: *const Obj) void {
    fireAll(user.cbInteractiveScopeChange, scope);
}

/// `digital.Run.tchk_hook`: timing check `check` of the run reported a
/// violation. IEEE 1364-2005 §27.33.3 / VAMS 12.31.4 cbTchkViolation,
/// "Timing check error occurred", and "For cbTchkViolation callbacks, the obj
/// field shall be a handle to the timing check": the §11.6.15 object built
/// from the same command (`src_tok`) in the same instance.
pub fn onTchk(r: *digital.Run, check: u32) void {
    if (!wanted(user.cbTchkViolation)) return;
    const site = r.tchkSite(check);
    const d = &session.design.?;
    const tchk = for (d.objects) |*o| {
        if (o.kind != .code or o.vtype != user.vpiTchk or o.src_tok != site.tok) continue;
        const owner = o.owner;
        if (owner == .none) continue;
        if (d.scope(owner).engine == site.scope) break o;
    } else return;
    fireAll(user.cbTchkViolation, tchk);
}

/// IEEE 1364-2005 §27.33.3 cbError: "Simulation run-time error occurred".
/// §12.31.4: "On a cbError callback, the routine vpi_chk_error() can be
/// called to retrieve error information" — recorded first, and not as a
/// cbPLIError, which is a different reason.
pub fn runError(e: anyerror) void {
    status.noteError("RUNTIME", "simulation run-time error: {t}", .{e});
    fireAll(user.cbError, null);
}

/// cbError for a run-time error the run survives (IEEE 1364-2005 §17.2.9's
/// terminated `$readmem` load): recorded for `vpi_chk_error`, then fired.
pub fn onRunError(_: *digital.Run) void {
    status.noteError("RUNTIME", "IEEE 1364-2005 §17.2.9: a $readmem load was terminated", .{});
    fireAll(user.cbError, null);
}

/// IEEE 1364-2005 §27.33.3 cbPLIError: "Simulation run-time error occurred
/// in a PLI function call", fired as the routine records it. A routine a
/// cbPLIError callback calls that fails fires none.
pub fn pliError() void {
    if (callback.active == user.cbPLIError) return;
    fireAll(user.cbPLIError, null);
}

/// The earliest tick a live time callback is due at that is strictly after
/// `after` — or AT it when `inclusive` — or null.
pub fn nextDue(after: u64, inclusive: bool) ?u64 {
    var best: ?u64 = null;
    for (callback.cbs.items) |cb| {
        if (cb.dead or !callback.isTimeReason(cb.reason) or cb.reason == user.cbNextSimTime) continue;
        if (cb.due < after or (!inclusive and cb.due == after)) continue;
        best = @min(best orelse cb.due, cb.due);
    }
    return best;
}

/// Every pending time a time callback holds, for §11.6.25's vpiTimeQueue.
/// A cbReadOnlySynch due at `now` holds none: IEEE 1364-2005 §26.6.40(c)
/// returns the current queue only "if there are events that precede read
/// only sync" (VD-046). One due later still makes its time a queue (VD-047).
pub fn pendingTimes(out: *std.ArrayList(u64), a: std.mem.Allocator, now: u64) !void {
    for (callback.cbs.items) |cb| {
        if (cb.dead or !callback.isTimeReason(cb.reason) or cb.reason == user.cbNextSimTime) continue;
        if (cb.reason == user.cbReadOnlySynch and cb.due == now) continue;
        try out.append(a, cb.due);
    }
}

/// Whether a live `reason` callback is due at `now` (what `fireDue` would run).
pub fn isDue(reason: c_int, now: u64) bool {
    for (callback.cbs.items) |cb| {
        if (!cb.dead and cb.reason == reason and cb.due == now) return true;
    }
    return false;
}

/// Fires the callbacks of `reason` due at `now`, each at most once: a time
/// callback is one-shot (§12.31.2 "shall occur ... a specified time"), so it
/// is removed as it fires and its handle stops being valid.
pub fn fireDue(reason: c_int, now: u64) void {
    const n = callback.cbs.items.len;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or cb.reason != reason or cb.due != now) continue;
        callback.retire(cb);
        _ = call(cb, cb.index, null);
    }
    callback.sweep();
}

/// §12.31.2 cbNextSimTime: "before execution of events in the next event
/// queue" — the first time queue after the one it was registered in.
pub fn fireNext(now: u64) void {
    const n = callback.cbs.items.len;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or cb.reason != user.cbNextSimTime or now <= cb.since) continue;
        callback.retire(cb);
        _ = call(cb, cb.index, null);
    }
    callback.sweep();
}

/// §12.31.1 cbValueChange for every callback watching the object stored in
/// `slot`, which the engine just changed.
pub fn fireSlot(slot: u32) void {
    const n = callback.cbs.items.len;
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
            _ = call(cb, @intCast(d.obj(word.index).value.?.int), word);
        }
    }
    callback.sweep();
}

/// §12.31.1 cbForce/cbRelease after `o` was forced or released: every
/// callback registered on `o`, and every one registered with a NULL obj.
/// "the object returned in the obj field shall be a handle to the force,
/// release ... statement"; a vpi_put_value force has no statement, so obj is
/// the object it forced. The value is `o`'s, after the force or release. A
/// design statement's force or release fires through `onDone` instead.
pub fn fireOverride(reason: c_int, o: *Obj) void {
    const n = callback.cbs.items.len;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or cb.reason != reason) continue;
        if (cb.obj != null and trust.asObj(cb.obj) != o) continue;
        _ = call(cb, cb.index, o);
    }
    callback.sweep();
}

/// `digital.DoneHook`: a design statement completed. A §9.3 `force`,
/// `release`, `assign` or `deassign` fires cbForce, cbRelease, cbAssign or
/// cbDeassign with obj the statement, on each callback registered with a NULL
/// obj or on one of the variables or nets it overrides. A `disable` fires
/// cbDisable on each callback whose named block it disabled.
pub fn onDone(r: *digital.Run, pc: u32) digital.Error!void {
    const site = r.host.done_sites.get(pc) orelse return;
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
    const n = callback.cbs.items.len;
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
    callback.sweep();
}

/// Every live cbStmt at `pc`, in registration order, each once per
/// statement starting there, outer first: "Just before the indicated
/// statement executes".
pub fn fireStmt(_: *digital.Run, pc: u32) digital.Error!void {
    const d = &session.design.?;
    const n = callback.cbs.items.len;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.reason != user.cbStmt) continue;
        for (cb.sites) |st| {
            if (cb.dead) break;
            if (st.pc == pc) _ = call(cb, 0, d.obj(st.obj));
        }
    }
    callback.sweep();
}

/// acbInitialStep, acbFinalStep or acbAcceptedPoint: every live callback of
/// `reason` registered before this dispatch began. These persist: §12.31.3
/// ties them to a kind of solution, not to one.
pub fn fireAnalog(reason: c_int) void {
    fireAll(reason, null);
}

/// acbConvergenceTest, "prior acceptance of the analog solution for the
/// given time (this callback allows rejection of the analog solution at that
/// time and backup to an earlier time)". Every callback runs; the solution
/// is rejected if ANY returned non-zero.
///
/// Implementation-defined: the LRM does not say which `int` rejects. 0
/// accepts, as 0 is every other callback's uneventful return; anything else
/// rejects.
pub fn convergenceRejected() bool {
    var rejected = false;
    const n = callback.cbs.items.len;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or cb.reason != user.acbConvergenceTest) continue;
        if (call(cb, cb.index, null) != 0) rejected = true;
    }
    callback.sweep();
    return rejected;
}

/// acbAbsTime / acbElapsedTime due upon the solution accepted at `t`: each
/// is delivered once and then retired — AFTER its routine returns, so a
/// routine that removes itself is removing a live callback (§12.34 returns 1
/// for it, p03_04).
pub fn fireTimed(t: f64) void {
    const n = callback.cbs.items.len;
    for (0..n) |i| {
        const cb = callback.cbs.items[i];
        if (cb.dead or (cb.reason != user.acbAbsTime and cb.reason != user.acbElapsedTime)) continue;
        if (!analog.sameTime(cb.due_real, t)) continue;
        _ = call(cb, cb.index, null);
        if (!cb.dead) callback.retire(cb);
    }
    callback.sweep();
}

/// The earliest acbAbsTime/acbElapsedTime instant strictly after `after`
/// and at most `until`: the next solution §12.31.3 says "shall" be forced.
pub fn nextForced(after: f64, until: f64) ?f64 {
    var best: ?f64 = null;
    for (callback.cbs.items) |cb| {
        if (cb.dead or (cb.reason != user.acbAbsTime and cb.reason != user.acbElapsedTime)) continue;
        if (cb.due_real <= after or analog.sameTime(cb.due_real, after) or cb.due_real > until) continue;
        best = @min(best orelse cb.due_real, cb.due_real);
    }
    return best;
}

// ---- private ----

/// Call `cb` with a FRESH s_cb_data — §12.31.1 "this is not a pointer to the
/// same structure which was passed to vpi_register_cb()" — whose time and
/// value are filled in the registered type and format. A value-change
/// callback reads its value from `from`: the array element that changed, or
/// the registered object itself.
fn call(cb: *Cb, index: c_int, from: ?*const Obj) c_int {
    var t: Time = std.mem.zeroes(Time);
    const override = cb.reason == user.cbForce or cb.reason == user.cbRelease or cb.reason == user.cbAssign or cb.reason == user.cbDeassign;
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
        v.format = cb.value_format;
        value.read(lhsOf(from) orelse trust.asObj(cb.obj).?, &v, &value.cb_store);
        data.value = &v;
    }
    callback.depth += 1;
    defer callback.depth -= 1;
    const outer = callback.active;
    callback.active = cb.reason;
    defer callback.active = outer;
    return cb.rtn(&data);
}

/// What an override callback reads its value from: a §9.3 statement's
/// left-hand side ("the resultant value of the left-hand expression"), or
/// `from` itself, the object a vpi_put_value force wrote.
fn lhsOf(from: ?*const Obj) ?*const Obj {
    const o = from orelse return null;
    if (o.stmt == .none) return o;
    const lhs = schema.edgeTo(o, user.vpiLhs);
    return if (lhs == schema.ObjId.none) null else session.design.?.obj(lhs);
}

/// Whether any live callback has `reason`, so `onTchk` searches the design
/// for its timing check only when someone will hear it.
fn wanted(reason: c_int) bool {
    for (callback.cbs.items) |cb| if (!cb.dead and cb.reason == reason) return true;
    return false;
}
