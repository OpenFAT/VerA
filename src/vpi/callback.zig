//! The simulation-callback registry: §12.31 vpi_register_cb, §12.34
//! vpi_remove_cb, §12.6 vpi_get_cb_info, and dispatch. Hosts fire the §12.31.4
//! action reasons (`endOfCompile` and siblings); `run.zig` fires the time and
//! value-change reasons and `analog.zig` the §12.31.3 analog ones. The live
//! registry also supplies IEEE 1364-2005 §26.6.39 callback traversal.
//!
//! A handle is a heap `Cb` pointer, valid while it is a key of `live`: C
//! pointers are never read until membership proves them ours. Removal deletes
//! the key first (§12.34: the handle "is no longer valid"); the `Cb` survives
//! until a sweep at dispatch depth zero, so a callback may remove itself.

const std = @import("std");
const digital = @import("sim").digital;
const root = @import("root.zig");
const coldOf = root.coldOf;
const value = @import("value.zig");
const analog = @import("analog.zig");
const code = @import("code.zig");

const vpiHandle = root.vpiHandle;

// ---------------------------------------------------------------------------
// The C ABI — Figure 12-5/12-9/12-10/12-17, as vpi_user.h lays them out.
// ---------------------------------------------------------------------------

/// Figure 12-5 `s_vpi_time`. `type` picks the live member: `vpiSimTime`,
/// the 64-bit tick count in `high`:`low`; `vpiScaledRealTime`, `real`.
pub const Time = extern struct {
    type: c_int,
    high: c_uint,
    low: c_uint,
    real: f64,
};

/// Figure 12-10 `s_vpi_vecval`: 32 bits of a four-state vector, `aval` and
/// `bval` per bit (0/0 = 0, 1/0 = 1, 0/1 = z, 1/1 = x).
pub const VecVal = extern struct { aval: c_int, bval: c_int };

/// Figure 12-11 `s_vpi_strengthval`.
pub const StrengthVal = extern struct { logic: c_int, s0: c_int, s1: c_int };

/// Figure 12-9 `s_vpi_value`: `format` (Table 12-4) picks the live member.
pub const Value = extern struct {
    format: c_int,
    value: extern union {
        str: [*c]u8,
        scalar: c_int,
        integer: c_int,
        real: f64,
        time: ?*Time,
        vector: [*c]VecVal,
        strength: ?*StrengthVal,
        misc: [*c]u8,
    },
};

/// An application's `cb_rtn`, called with the `CbData` of the firing.
const Routine = *const fn (*CbData) callconv(.c) c_int;

/// Figure 12-17 `s_cb_data`, with the `index` member Figure 12-2 omits
/// (§12.31.1 requires it).
pub const CbData = extern struct {
    reason: c_int,
    cb_rtn: ?Routine,
    obj: vpiHandle,
    time: ?*Time,
    value: ?*Value,
    index: c_int,
    user_data: [*c]u8,
};

// s_vpi_time.type — §12.15.
pub const vpiScaledRealTime: c_int = 1;
pub const vpiSimTime: c_int = 2;
pub const vpiSuppressTime: c_int = 3;
/// §12.15 "scaled real, analog, or simulation time": the analog time, in
/// seconds, in `real`. The LRM gives it no number; this is VerA's (vpi_user.h).
pub const vpiAnalogTime: c_int = 4;

// §12.31 reasons, Annex G numbering.
pub const cbValueChange: c_int = 1;
pub const cbStmt: c_int = 2;
pub const cbForce: c_int = 3;
pub const cbRelease: c_int = 4;
pub const cbAtStartOfSimTime: c_int = 5;
pub const cbReadWriteSynch: c_int = 6;
pub const cbReadOnlySynch: c_int = 7;
pub const cbNextSimTime: c_int = 8;
pub const cbAfterDelay: c_int = 9;
pub const cbEndOfCompile: c_int = 10;
pub const cbStartOfSimulation: c_int = 11;
pub const cbEndOfSimulation: c_int = 12;
pub const cbError: c_int = 13;
pub const cbTchkViolation: c_int = 14;
pub const cbStartOfReset: c_int = 19;
pub const cbEndOfReset: c_int = 20;
pub const cbInteractiveScopeChange: c_int = 23;
pub const cbAssign: c_int = 25;
pub const cbDeassign: c_int = 26;
pub const cbDisable: c_int = 27;
pub const cbPLIError: c_int = 28;

// §12.31.3 the analog reasons. Verilog-AMS names them and numbers none; the
// numbers are VerA's, shared by vpi_user.h and
// tests/conformance/tests/verilog-ams/ch12_vpi_routines/p03_vpi_analog.h.
pub const acbInitialStep: c_int = 701;
pub const acbFinalStep: c_int = 702;
pub const acbAbsTime: c_int = 703;
pub const acbElapsedTime: c_int = 704;
pub const acbConvergenceTest: c_int = 705;
pub const acbAcceptedPoint: c_int = 706;

/// Whether `r` is one of the §12.31.3 analog reasons.
fn isAnalogReason(r: c_int) bool {
    return r >= acbInitialStep and r <= acbAcceptedPoint;
}

/// §11.6.25's callback object, as `vpi_get(vpiType, cb)` reports it.
pub const vpiCallback: c_int = 107;

const vpiSuppressVal = value.vpiSuppressVal;

// ---------------------------------------------------------------------------
// The registry
// ---------------------------------------------------------------------------

/// One registration, owned by this file; see the header for its lifetime.
const Cb = struct {
    reason: c_int,
    rtn: Routine,
    obj: vpiHandle,
    user_data: [*c]u8,
    index: c_int,
    /// The registered `time->type`, or vpiSuppressTime when none was given.
    time_type: c_int,
    /// A copy of the registered time structure: the application's may be on
    /// its stack.
    time: Time,
    /// The registered `value->format`, or vpiSuppressVal.
    value_format: c_int,
    /// §26.6.39's object association. `obj` alone is not one: time reasons
    /// use it for timescale context, and action reasons ignore it entirely.
    /// Null means global, except for time reasons associated with a queue.
    reference: vpiHandle = null,
    /// Time reasons: the absolute tick this callback is due at.
    due: u64 = 0,
    /// cbNextSimTime: the tick it was registered at — it fires at the first
    /// time queue after this one.
    since: u64 = 0,
    /// acbAbsTime / acbElapsedTime: the analog time, in seconds, whose
    /// accepted solution it is delivered upon — and which it forces.
    due_real: f64 = 0,
    /// cbStmt: each (pc, statement object) it fires at, in the engine's
    /// order; cbDisable: the named block's one. Owned by `gpa`.
    sites: []const Site = &.{},
    dead: bool = false,
};

/// One cbStmt firing point: engine code index `pc`, statement row `obj`.
pub const Site = struct { pc: u32, obj: u32 };

const gpa = std.heap.smp_allocator;

/// Registration order, dead ones included until the next sweep.
var cbs: std.ArrayList(*Cb) = .empty;
/// The live handles.
var live: std.AutoHashMapUnmanaged(usize, *Cb) = .empty;
/// How many dispatches are on the stack; a sweep only runs at zero.
var depth: u32 = 0;
/// The reason of the innermost dispatch on the stack, 0 outside one.
var active: c_int = 0;

/// Returns `h` as a live callback, or null; never dereferences a foreign
/// pointer.
pub fn asCb(h: vpiHandle) ?*Cb {
    const p = h orelse return null;
    return live.get(@intFromPtr(p));
}

/// Frees every callback and invalidates every handle. `root.close()` calls
/// it: callbacks belong to the session a design was opened for.
pub fn reset() void {
    for (cbs.items) |cb| destroy(cb);
    cbs.clearAndFree(gpa);
    live.clearAndFree(gpa);
    depth = 0;
    hooked.deinit(gpa);
    hooked = .{};
}

fn destroy(cb: *Cb) void {
    gpa.free(cb.sites);
    gpa.destroy(cb);
}

const no_save = "VerA has no save or restart (IEEE 1364-2005 C.8)";
const no_interactive = "a VerA run has no interactive mode (§12.36: vpiStop ends the run)";

/// The callback reasons of Annex G no registration here is ever delivered
/// for (vpi_user.h's "Annex G names VerA does not answer"), refused by name
/// at any time, the startup phase included.
fn unansweredReason(r: c_int) ?root.Unanswered {
    return switch (r) {
        15 => .{ .name = "cbStartOfSave", .why = no_save },
        16 => .{ .name = "cbEndOfSave", .why = no_save },
        17 => .{ .name = "cbStartOfRestart", .why = no_save },
        18 => .{ .name = "cbEndOfRestart", .why = no_save },
        21 => .{ .name = "cbEnterInteractive", .why = no_interactive },
        22 => .{ .name = "cbExitInteractive", .why = no_interactive },
        24 => .{ .name = "cbUnresolvedSystf", .why = "VerA delivers no callback for an unresolved system task or function name" },
        29 => .{ .name = "cbSignal", .why = "a VerA run traps no signal" },
        else => null, // else: every other number is delivered, or is no Annex G reason and gets NOREASON
    };
}

/// IEEE 1364-2005 §26.2.4: at startup "vpi_register_cb() routine can only be
/// called for the following reasons": these five, and cbUnresolvedSystf,
/// which VerA refuses at any time (no such callback is ever delivered).
fn startupReason(r: c_int) bool {
    return switch (r) {
        cbEndOfCompile, cbStartOfSimulation, cbEndOfSimulation, cbError, cbPLIError => true,
        else => false,
    };
}

fn isTimeReason(r: c_int) bool {
    return switch (r) {
        cbAtStartOfSimTime, cbReadWriteSynch, cbReadOnlySynch, cbNextSimTime, cbAfterDelay => true,
        else => false,
    };
}

/// IEEE 1364-2005 §26.6.39: callbacks on an object, a time queue, or NULL
/// for callbacks unrelated to either. Snapshot only live registrations;
/// the caller owns the returned slice, whose handles retain their ordinary
/// callback lifetime (§27.35). No iteration order is promised by the LRM.
pub fn all(a: std.mem.Allocator, ref: vpiHandle) ![]vpiHandle {
    const queue = root.run.asQueue(ref);
    const next = if (queue != null) try root.run.nextTime(root.run.now(), a) else null;
    // At most one handle per registration.
    var out: std.ArrayList(vpiHandle) = try .initCapacity(a, cbs.items.len);
    errdefer out.deinit(a);
    for (cbs.items) |cb| {
        if (cb.dead) continue;
        const matches = if (isTimeReason(cb.reason)) blk: {
            const q = queue orelse break :blk false;
            if (cb.reason == cbNextSimTime)
                break :blk next != null and q.time == next.? and q.time > cb.since;
            break :blk q.time == cb.due;
        } else if (cb.reason == cbStmt) blk: {
            // §27.33.1.3's module registration is one callback placed on
            // every covered statement. §26.6.39 reaches that same handle
            // from each statement, once even if it has several engine pcs.
            if (ref == null or queue != null) break :blk false;
            if (cb.reference == ref) break :blk true;
            for (cb.sites) |site| {
                if (@as(vpiHandle, @ptrCast(&root.design.?.objects[site.obj])) == ref)
                    break :blk true;
            }
            break :blk false;
        } else queue == null and cb.reference == ref;
        if (matches) out.appendAssumeCapacity(@ptrCast(cb));
    }
    return out.toOwnedSlice(a);
}

/// §12.31. Returns the callback handle, or NULL plus vpiError for a request
/// that cannot be kept.
pub export fn vpi_register_cb(cb_data_p: ?*const CbData) vpiHandle {
    root.clearError();
    const d = cb_data_p orelse {
        root.fail("BADCB", "vpi_register_cb: cb_data_p is NULL", .{});
        return null;
    };
    const rtn = d.cb_rtn orelse {
        root.fail("BADCB", "vpi_register_cb: cb_rtn is NULL", .{});
        return null;
    };
    if (unansweredReason(d.reason)) |u| {
        root.failUnanswered("vpi_register_cb", u);
        return null;
    }
    if (root.starting and !startupReason(d.reason)) {
        root.fail("STARTUP", "vpi_register_cb: IEEE 1364-2005 §26.2.4 allows reason {d} only after vlog_startup_routines; register it from a cbEndOfCompile callback", .{d.reason});
        return null;
    }
    var cb: Cb = .{
        .reason = d.reason,
        .rtn = rtn,
        .obj = d.obj,
        .user_data = d.user_data,
        .index = d.index,
        .time_type = if (d.time) |t| t.type else vpiSuppressTime,
        .time = if (d.time) |t| t.* else std.mem.zeroes(Time),
        .value_format = if (d.value) |v| v.format else vpiSuppressVal,
    };
    switch (d.reason) {
        // §12.31.4: "The only fields in the s_cb_data structure which need to
        // be setup for simulation action/feature callbacks are the reason,
        // cb_rtn, and user_data". IEEE 1364-2005 §27.33.3 adds cbError and
        // cbPLIError to the actions "that shall occur in all VPI-compliant
        // products".
        // IEEE 1364-2005 §27.33.3's feature reason cbInteractiveScopeChange
        // "Simulation command to change interactive scope executed": §12.36's
        // vpiSetInteractiveScope is the only such command here.
        // IEEE 1364-2005 §27.33.3 and VAMS 12.31.4's action reason
        // cbTchkViolation, "Timing check error occurred": the digital
        // engine's timing checks (`digital.Run.tchk_hook`, `onTchk`).
        // IEEE 1364-2005 §27.33.3's feature reasons cbStartOfReset and
        // cbEndOfReset, "Simulation reset begin" and "end": §12.36's
        // vpiReset (`run.simulate`).
        cbEndOfCompile, cbStartOfSimulation, cbEndOfSimulation, cbError, cbPLIError, cbInteractiveScopeChange, cbTchkViolation, cbStartOfReset, cbEndOfReset => {},
        // §12.31.1: "For force and release callbacks, if this is set to NULL,
        // every force and release shall generate a callback." A non-NULL obj
        // must be one VerA issued. cbAssign/cbDeassign take the same: the
        // clause states the NULL rule for force and release only, and VerA
        // reads it for the procedural pair too (one statement per callback).
        cbForce, cbRelease, cbAssign, cbDeassign => {
            if (d.obj != null and root.asObj(d.obj) == null) {
                root.fail("BADHANDLE", "vpi_register_cb: obj is not a handle to an object", .{});
                return null;
            }
            cb.reference = d.obj;
        },
        // §12.31.1 cbDisable "After a named block or task containing a system
        // task/function has been disabled". ponytail: obj is a named begin or
        // fork; a task, function or system call as obj is refused, and the
        // block need not contain a system call (VerA does not check it).
        cbDisable => {
            const o = root.asObj(d.obj);
            if (o == null or o.?.kind != .code or (o.?.vtype != code.vpiNamedBegin and o.?.vtype != code.vpiNamedFork)) {
                root.fail("NOTSUPPORTED", "vpi_register_cb: cbDisable is delivered for a named begin or fork in obj", .{});
                return null;
            }
            cb.sites = stmtSites(d.obj) orelse return null;
            cb.reference = d.obj;
        },
        // §12.31.1 "After value change on an expression or terminal". The
        // object must be one whose value can change in this process: a
        // digital net, reg, variable or memory word.
        cbValueChange => {
            const o = root.asObj(d.obj) orelse {
                root.fail("BADHANDLE", "vpi_register_cb: cbValueChange needs an object handle in obj", .{});
                return null;
            };
            // IEEE 1364-2005 §26.6.20 Details a.
            if (o.automatic) {
                root.fail("AUTOMATIC", "vpi_register_cb: `{s}` is an automatic variable, and a value change callback on one is illegal", .{o.full});
                return null;
            }
            if (o.slot == .none and (coldOf(o).members.len == 0 or root.design.?.objects[coldOf(o).members[0]].slot == .none)) {
                root.fail("NOVALUE", "vpi_register_cb: `{s}` has no simulation value that can change", .{o.full});
                return null;
            }
            cb.reference = d.obj;
            value.watch(o);
        },
        // IEEE 1364-2005 §27.33.1.1 a statement Table 27-6 lists, or
        // §27.33.1.3 a module: "every statement that can have a callback
        // placed on it".
        cbStmt => {
            cb.sites = stmtSites(d.obj) orelse return null;
            cb.reference = d.obj;
        },
        cbAtStartOfSimTime, cbReadWriteSynch, cbReadOnlySynch, cbAfterDelay, cbNextSimTime => {
            // IEEE 1364-2005 27.33.2, which §12.31 defers to for the header:
            // a time callback needs a time it can deliver in. cbNextSimTime is
            // the exception — "For reason cbNextSimTime, the time structure is
            // ignored" (§12.31.2) — but it still says which FORMAT to deliver.
            if (d.reason != cbNextSimTime and (d.time == null or cb.time_type == vpiSuppressTime)) {
                root.fail("BADTIME", "vpi_register_cb: reason {d} needs a vpiSimTime or vpiScaledRealTime time", .{d.reason});
                return null;
            }
            if (cb.time_type != vpiSimTime and cb.time_type != vpiScaledRealTime and cb.time_type != vpiSuppressTime) {
                root.fail("BADTIME", "vpi_register_cb: time type {d} is not a §12.15 time type", .{cb.time_type});
                return null;
            }
            const now = root.run.now();
            cb.since = now;
            if (d.reason != cbNextSimTime) {
                const ticks = root.run.ticksOf(cb.time, d.obj) orelse return null;
                // §12.31.2: cbAtStartOfSimTime names a TIME; the others name a
                // DELAY from now ("after a specified amount of time").
                cb.due = if (d.reason == cbAtStartOfSimTime) ticks else now +| ticks;
                if (cb.due < now) {
                    root.fail("BADTIME", "vpi_register_cb: time {d} is already in the past (now {d})", .{ cb.due, now });
                    return null;
                }
                // IEEE 1364-2005 §27.33.2: "The following situations will
                // generate an error, and no callback will be created".
                if (cb.due == now and d.reason == cbAtStartOfSimTime and root.run.started and active != cbAtStartOfSimTime) {
                    root.fail("BADTIME", "vpi_register_cb: time {d} has progressed past its start, outside a cbAtStartOfSimTime callback", .{now});
                    return null;
                }
                if (cb.due == now and d.reason == cbReadWriteSynch and root.run.read_only) {
                    root.fail("BADTIME", "vpi_register_cb: a cbReadWriteSynch of delay zero at read-only synch time", .{});
                    return null;
                }
            }
        },
        // §12.31.3. The four step reasons carry no time; acbAbsTime names an
        // absolute analog time and acbElapsedTime an interval "advanced from
        // the current solution" — the latest accepted one, or the start of
        // the next analysis when none is running. Both are seconds, so only
        // vpiScaledRealTime can state them.
        acbInitialStep, acbFinalStep, acbConvergenceTest, acbAcceptedPoint => {},
        acbAbsTime, acbElapsedTime => {
            const t = d.time orelse {
                root.fail("BADTIME", "vpi_register_cb: reason {d} needs a vpiScaledRealTime time", .{d.reason});
                return null;
            };
            if (t.type != vpiScaledRealTime) {
                root.fail("BADTIME", "vpi_register_cb: an analog time is in seconds; time type {d} is not vpiScaledRealTime", .{t.type});
                return null;
            }
            if (!std.math.isFinite(t.real) or t.real < 0) {
                root.fail("BADTIME", "vpi_register_cb: {e} is not a time an analysis reaches", .{t.real});
                return null;
            }
            cb.due_real = if (d.reason == acbAbsTime) t.real else analog.acceptedTime() + t.real;
        },
        else => {
            root.fail("NOREASON", "vpi_register_cb: reason {d} is not a reason VerA can deliver", .{d.reason});
            return null;
        },
    }
    const p = gpa.create(Cb) catch {
        gpa.free(cb.sites);
        return oom();
    };
    p.* = cb;
    cbs.append(gpa, p) catch {
        destroy(p);
        return oom();
    };
    live.put(gpa, @intFromPtr(p), p) catch {
        _ = cbs.pop();
        destroy(p);
        return oom();
    };
    if (cb.reason == cbStmt) rehook();
    return @ptrCast(p);
}

fn oom() vpiHandle {
    root.fail("NOMEM", "vpi_register_cb: out of memory", .{});
    return null;
}

/// IEEE 1364-2005 §27.8 and §27.29: each "can only be called from an
/// application routine that has been called for reason cbStartOfRestart or
/// cbEndOfRestart" (cbStartOfSave or cbEndOfSave), and fails with 0
/// otherwise. VerA has no save or restart (Annex C.8), so those callbacks
/// never run and every call fails.
pub export fn vpi_get_data(id: c_int, data_loc: ?[*]u8, num_bytes: c_int) c_int {
    if (root.refused("vpi_get_data")) return 0;
    _ = .{ id, data_loc, num_bytes };
    root.fail("NOSAVE", "vpi_get_data: only a cbStartOfRestart or cbEndOfRestart callback reads saved data, and VerA has no restart", .{});
    return 0;
}

/// See `vpi_get_data`.
pub export fn vpi_put_data(id: c_int, data_loc: ?[*]u8, num_bytes: c_int) c_int {
    if (root.refused("vpi_put_data")) return 0;
    _ = .{ id, data_loc, num_bytes };
    root.fail("NOSAVE", "vpi_put_data: only a cbStartOfSave or cbEndOfSave callback saves data, and VerA has no save", .{});
    return 0;
}

/// §12.34 "shall return a 1 (TRUE) if successful, and a 0 (FALSE) on a
/// failure. After vpi_remove_cb() is called with a handle to the callback, the
/// handle is no longer valid."
pub export fn vpi_remove_cb(cb_obj: vpiHandle) c_int {
    if (root.refused("vpi_remove_cb")) return 0;
    const cb = asCb(cb_obj) orelse {
        root.fail("BADHANDLE", "vpi_remove_cb: {s} is not a live callback handle", .{root.describe(cb_obj)});
        return 0;
    };
    _ = live.remove(@intFromPtr(cb));
    cb.dead = true;
    // Allocates nothing (`sizeHooks`), so a routine C calls cannot fail here.
    if (cb.reason == cbStmt) rehook();
    sweep();
    return 1;
}

/// §12.6 "shall return information about a simulation-related callback in an
/// s_cb_data structure. The memory for this structure shall be allocated by
/// the user." The `time` and `value` sub-structures are the user's too when
/// they point anywhere: they are written, never replaced.
pub export fn vpi_get_cb_info(obj: vpiHandle, cb_data_p: ?*CbData) void {
    if (root.refused("vpi_get_cb_info")) return;
    const cb = asCb(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_cb_info: {s} is not a live callback handle", .{root.describe(obj)});
        return;
    };
    const out = cb_data_p orelse {
        root.fail("BADCB", "vpi_get_cb_info: cb_data_p is NULL", .{});
        return;
    };
    out.reason = cb.reason;
    out.cb_rtn = cb.rtn;
    out.obj = cb.obj;
    out.index = cb.index;
    out.user_data = cb.user_data;
    if (out.time) |t| {
        t.* = cb.time;
        t.type = cb.time_type;
    }
    if (out.value) |v| v.format = cb.value_format;
}

/// Frees the dead registrations, keeping the live ones in order: one pass,
/// where removing each in place was quadratic in the registry.
fn sweep() void {
    if (depth != 0) return;
    var kept: usize = 0;
    for (cbs.items) |cb| {
        if (cb.dead) {
            destroy(cb);
            continue;
        }
        cbs.items[kept] = cb;
        kept += 1;
    }
    cbs.shrinkRetainingCapacity(kept);
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

/// Call `cb` with a FRESH s_cb_data — §12.31.1 "this is not a pointer to the
/// same structure which was passed to vpi_register_cb()" — whose time and
/// value are filled in the registered type and format. A value-change
/// callback reads its value from `from`: the array element that changed, or
/// the registered object itself.
fn call(cb: *Cb, index: c_int, from: ?*const root.Obj) c_int {
    var t: Time = std.mem.zeroes(Time);
    const override = cb.reason == cbForce or cb.reason == cbRelease or cb.reason == cbAssign or cb.reason == cbDeassign;
    var data: CbData = .{
        .reason = cb.reason,
        .cb_rtn = cb.rtn,
        .obj = if (override or cb.reason == cbStmt or cb.reason == cbInteractiveScopeChange or cb.reason == cbTchkViolation) @ptrCast(@constCast(from.?)) else cb.obj,
        .time = null,
        .value = null,
        .index = index,
        .user_data = cb.user_data,
    };
    if (isAnalogReason(cb.reason)) {
        // §12.31.3's time is the analog clock's, in seconds.
        if (cb.time_type != vpiSuppressTime) {
            t = cb.time;
            t.type = vpiScaledRealTime;
            t.real = analog.time();
            data.time = &t;
        }
    } else if (cb.time_type != vpiSuppressTime) {
        t.type = cb.time_type;
        root.run.timeNow(cb.obj, &t);
        data.time = &t;
    }
    var v: Value = std.mem.zeroes(Value);
    if ((cb.reason == cbValueChange or override) and cb.value_format != vpiSuppressVal) {
        v.format = cb.value_format;
        value.read(lhsOf(from) orelse root.asObj(cb.obj).?, &v, &value.cb_store);
        data.value = &v;
    }
    depth += 1;
    defer depth -= 1;
    const outer = active;
    active = cb.reason;
    defer active = outer;
    return cb.rtn(&data);
}

/// What an override callback reads its value from: a §9.3 statement's
/// left-hand side ("the resultant value of the left-hand expression"), or
/// `from` itself, the object a vpi_put_value force wrote.
fn lhsOf(from: ?*const root.Obj) ?*const root.Obj {
    const o = from orelse return null;
    if (o.stmt == .none) return o;
    const lhs = root.edgeTo(o, code.vpiLhs);
    return if (lhs == root.no_obj) null else &root.design.?.objects[lhs];
}

/// Every live callback of `reason`, in registration order, with `from` as
/// `call` reads it. Only the ones registered BEFORE this dispatch began: a
/// callback registered from inside one is for a later occurrence (p02_07's
/// heir must not see the change whose dispatch registered it).
fn fireAll(reason: c_int, from: ?*const root.Obj) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (!cb.dead and cb.reason == reason) _ = call(cb, cb.index, from);
    }
    sweep();
}

/// Whether any live callback has `reason`, so `onTchk` searches the design
/// for its timing check only when someone will hear it.
fn wanted(reason: c_int) bool {
    for (cbs.items) |cb| if (!cb.dead and cb.reason == reason) return true;
    return false;
}

/// §12.31.4 cbEndOfCompile — "End of simulation data structure compilation
/// or build": after the design is elaborated and the startup routines ran.
pub fn endOfCompile() void {
    // The build's last step before it is "end": the registered systfs'
    // compiletf/sizetf/derivtf at each call site (§12.32.1, §12.33.1).
    @import("systf.zig").buildCalls();
    fireAll(cbEndOfCompile, null);
}

/// §12.31.4 cbStartOfSimulation — "beginning of time 0 simulation cycle".
pub fn startOfSimulation() void {
    fireAll(cbStartOfSimulation, null);
}

/// §12.31.4 cbEndOfSimulation — "e.g., $finish system task executed".
pub fn endOfSimulation() void {
    fireAll(cbEndOfSimulation, null);
}

/// IEEE 1364-2005 §27.33.3 cbStartOfReset: a §12.36 vpiReset is about to
/// take the run back to time 0 (`run.simulate`).
pub fn startOfReset() void {
    fireAll(cbStartOfReset, null);
}

/// IEEE 1364-2005 §27.33.3 cbEndOfReset: the run is back at time 0, before
/// it goes on (or ends, for a stop_value of 0).
pub fn endOfReset() void {
    fireAll(cbEndOfReset, null);
}

/// IEEE 1364-2005 §27.33.3 cbInteractiveScopeChange: "obj shall be a handle
/// to the new scope".
pub fn interactiveScopeChange(scope: *const root.Obj) void {
    fireAll(cbInteractiveScopeChange, scope);
}

/// `digital.Run.tchk_hook`: timing check `check` of the run reported a
/// violation. IEEE 1364-2005 §27.33.3 / VAMS 12.31.4 cbTchkViolation,
/// "Timing check error occurred", and "For cbTchkViolation callbacks, the obj
/// field shall be a handle to the timing check": the §11.6.15 object built
/// from the same command (`src_tok`) in the same instance.
pub fn onTchk(r: *digital.Run, check: u32) void {
    if (!wanted(cbTchkViolation)) return;
    const site = r.tchkSite(check);
    const d = &root.design.?;
    const tchk = for (d.objects) |*o| {
        if (o.kind != .code or o.vtype != code.vpiTchk or o.src_tok != site.tok) continue;
        const owner = o.owner.get() orelse continue;
        if (d.scopes[owner].engine == site.scope) break o;
    } else return;
    fireAll(cbTchkViolation, tchk);
}

/// IEEE 1364-2005 §27.33.3 cbError: "Simulation run-time error occurred".
/// §12.31.4: "On a cbError callback, the routine vpi_chk_error() can be
/// called to retrieve error information" — recorded first, and not as a
/// cbPLIError, which is a different reason.
pub fn runError(e: anyerror) void {
    root.noteError("RUNTIME", "simulation run-time error: {t}", .{e});
    fireAll(cbError, null);
}

/// IEEE 1364-2005 §27.33.3 cbPLIError: "Simulation run-time error occurred
/// in a PLI function call", fired as the routine records it. A routine a
/// cbPLIError callback calls that fails fires none.
pub fn pliError() void {
    if (active == cbPLIError) return;
    fireAll(cbPLIError, null);
}

/// The earliest tick a live time callback is due at that is strictly after
/// `after` — or AT it when `inclusive` — or null.
pub fn nextDue(after: u64, inclusive: bool) ?u64 {
    var best: ?u64 = null;
    for (cbs.items) |cb| {
        if (cb.dead or !isTimeReason(cb.reason) or cb.reason == cbNextSimTime) continue;
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
    for (cbs.items) |cb| {
        if (cb.dead or !isTimeReason(cb.reason) or cb.reason == cbNextSimTime) continue;
        if (cb.reason == cbReadOnlySynch and cb.due == now) continue;
        try out.append(a, cb.due);
    }
}

/// Whether a live `reason` callback is due at `now` (what `fireDue` would run).
pub fn isDue(reason: c_int, now: u64) bool {
    for (cbs.items) |cb| {
        if (!cb.dead and cb.reason == reason and cb.due == now) return true;
    }
    return false;
}

/// Fires the callbacks of `reason` due at `now`, each at most once: a time
/// callback is one-shot (§12.31.2 "shall occur ... a specified time"), so it
/// is removed as it fires and its handle stops being valid.
pub fn fireDue(reason: c_int, now: u64) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or cb.reason != reason or cb.due != now) continue;
        retire(cb);
        _ = call(cb, cb.index, null);
    }
    sweep();
}

/// §12.31.2 cbNextSimTime: "before execution of events in the next event
/// queue" — the first time queue after the one it was registered in.
pub fn fireNext(now: u64) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or cb.reason != cbNextSimTime or now <= cb.since) continue;
        retire(cb);
        _ = call(cb, cb.index, null);
    }
    sweep();
}

/// §12.31.1 cbValueChange for every callback watching the object stored in
/// `slot`, which the engine just changed.
pub fn fireSlot(slot: u32) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or cb.reason != cbValueChange) continue;
        const target = root.asObj(cb.obj) orelse continue;
        if (target.slot.get() == slot) {
            _ = call(cb, cb.index, null);
            continue;
        }
        // §12.31.1: a callback on an array hears each element's change, with
        // that element's value and "the index of the memory word or variable
        // select which changed value".
        const d = &root.design.?;
        for (coldOf(target).members) |m| {
            const word = &d.objects[m];
            if (word.slot.get() != slot) continue;
            _ = call(cb, @intCast(d.objects[word.index.get().?].value.?.int), word);
        }
    }
    sweep();
}

/// §12.31.1 cbForce/cbRelease after `o` was forced or released: every
/// callback registered on `o`, and every one registered with a NULL obj.
/// "the object returned in the obj field shall be a handle to the force,
/// release ... statement"; a vpi_put_value force has no statement, so obj is
/// the object it forced. The value is `o`'s, after the force or release. A
/// design statement's force or release fires through `onDone` instead.
pub fn fireOverride(reason: c_int, o: *root.Obj) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or cb.reason != reason) continue;
        if (cb.obj != null and root.asObj(cb.obj) != o) continue;
        _ = call(cb, cb.index, o);
    }
    sweep();
}

/// `digital.DoneHook`: a design statement completed. A §9.3 `force`,
/// `release`, `assign` or `deassign` fires cbForce, cbRelease, cbAssign or
/// cbDeassign with obj the statement, on each callback registered with a NULL
/// obj or on one of the variables or nets it overrides. A `disable` fires
/// cbDisable on each callback whose named block it disabled.
pub fn onDone(r: *digital.Run, pc: u32) digital.Error!void {
    const site = r.done_sites.get(pc) orelse return;
    const reason: c_int = switch (r.code.items[pc]) {
        .override_on => |o| if (o.force) cbForce else cbAssign,
        .override_off => |o| if (o.force) cbRelease else cbDeassign,
        .disable_block => |b| {
            const n = cbs.items.len;
            for (0..n) |i| {
                const cb = cbs.items[i];
                if (cb.dead or cb.reason != cbDisable) continue;
                for (cb.sites) |st| if (st.pc >= b.start and st.pc < b.end) {
                    _ = call(cb, cb.index, null);
                    break;
                };
            }
            sweep();
            return;
        },
        else => return, // else: `done_sites` keys only these three instructions
    };
    const d = &root.design.?;
    const want: c_int = switch (reason) {
        cbForce => code.vpiForce,
        cbRelease => code.vpiRelease,
        cbAssign => code.vpiAssignStmt,
        else => code.vpiDeassign,
    };
    const stmt = for (d.objects) |*o| {
        if (o.kind == .code and o.vtype == want and o.stmt == site.stmt and o.owner != .none and d.scopes[o.owner.get().?].engine == site.scope) break o;
    } else return;
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or cb.reason != reason) continue;
        if (cb.obj != null) {
            const target = (root.asObj(cb.obj) orelse continue).slot.get() orelse continue;
            // The slots the statement's instructions override (a
            // concatenation overrides several).
            const hit = for (r.code.items[site.pc .. pc + 1]) |ins| switch (ins) {
                .override_on => |o| if (o.slot == target) break true,
                .override_off => |o| if (o.slot == target) break true,
                else => {}, // else: only an override names a slot it overrides
            } else false;
            if (!hit) continue;
        }
        _ = call(cb, cb.index, stmt);
    }
    sweep();
}

// ---------------------------------------------------------------------------
// IEEE 1364-2005 §27.33.1.1 statement callbacks
// ---------------------------------------------------------------------------

/// The pcs a live cbStmt fires at, which the engine checks (`StmtHook`).
var hooked: std.bit_set.Dynamic = .{};

/// `obj`'s sites: a statement's own, or every statement's of a module
/// instance. Null, with the error recorded, for anything else.
fn stmtSites(obj: vpiHandle) ?[]const Site {
    const o = root.asObj(obj) orelse {
        root.fail("BADHANDLE", "vpi_register_cb: cbStmt needs a statement or module handle in obj", .{});
        return null;
    };
    const one = o.stmt != .none and o.vtype != code.vpiNullStmt;
    if (!one and o.kind != .module) {
        root.fail("NOTSTMT", "vpi_register_cb: `{s}` is neither a statement Table 27-6 lists nor a module", .{o.full});
        return null;
    }
    const r = root.run.attached() orelse {
        root.fail("NOENGINE", "vpi_register_cb: no digital run executes statements", .{});
        return null;
    };
    const engine_sites = r.stmt_sites orelse {
        root.fail("NOSITES", "vpi_register_cb: this run records no statement sites", .{});
        return null;
    };
    const d = &root.design.?;
    const scope = if (one) o.owner.get().? else o.scope;
    // The statement objects this registration covers, by AST statement.
    var covered: std.AutoHashMapUnmanaged(@import("frontend").Ast.StmtId, u32) = .empty;
    defer covered.deinit(gpa);
    if (one) {
        covered.put(gpa, o.stmt, d.indexOf(o)) catch return oomSites();
    } else for (d.objects, 0..) |s, i| {
        if (s.kind != .code or s.owner.get() != scope or s.stmt == .none or s.vtype == code.vpiNullStmt) continue;
        covered.put(gpa, s.stmt, @intCast(i)) catch return oomSites();
    }
    var out: std.ArrayList(Site) = .empty;
    const eng = d.scopes[scope].engine;
    for (engine_sites.items) |st| {
        if (st.scope != eng) continue;
        const at = covered.get(st.stmt) orelse continue;
        out.append(gpa, .{ .pc = st.pc, .obj = at }) catch {
            out.deinit(gpa);
            return oomSites();
        };
    }
    return out.toOwnedSlice(gpa) catch {
        out.deinit(gpa);
        return oomSites();
    };
}

fn oomSites() ?[]const Site {
    root.fail("NOMEM", "vpi_register_cb: out of memory", .{});
    return null;
}

/// Sizes `hooked` to `r`'s program, before `r` is attached
/// (`root.openDigital`), so `rehook` never allocates: `vpi_remove_cb` has
/// no failure to report but a bad handle (§12.34).
pub fn sizeHooks(r: *const digital.Run) error{OutOfMemory}!void {
    try hooked.resize(gpa, r.code.items.len, false);
}

/// Rebuilds `hooked` from the live cbStmt callbacks, and installs the hook
/// on the engine while any is live. Asserts that `sizeHooks` sized it to the
/// attached program, whose length a reset keeps (it elaborates the same
/// source again).
fn rehook() void {
    const r = root.run.attached() orelse return;
    std.debug.assert(hooked.bit_length == r.code.items.len);
    hooked.unsetAll();
    for (cbs.items) |cb| {
        if (cb.dead or cb.reason != cbStmt) continue;
        for (cb.sites) |st| hooked.set(st.pc);
    }
    r.stmt_hook = if (hooked.findFirstSet() != null) .{ .at = &hooked, .fire = fireStmt } else null;
}

/// Every live cbStmt at `pc`, in registration order, each once per
/// statement starting there, outer first: "Just before the indicated
/// statement executes".
fn fireStmt(_: *digital.Run, pc: u32) digital.Error!void {
    const d = &root.design.?;
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.reason != cbStmt) continue;
        for (cb.sites) |st| {
            if (cb.dead) break;
            if (st.pc == pc) _ = call(cb, 0, &d.objects[st.obj]);
        }
    }
    sweep();
}

// ---------------------------------------------------------------------------
// §12.31.3 analog dispatch — driven by `analog.zig`'s time walk.
// ---------------------------------------------------------------------------

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
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or cb.reason != acbConvergenceTest) continue;
        if (call(cb, cb.index, null) != 0) rejected = true;
    }
    sweep();
    return rejected;
}

/// acbAbsTime / acbElapsedTime due upon the solution accepted at `t`: each
/// is delivered once and then retired — AFTER its routine returns, so a
/// routine that removes itself is removing a live callback (§12.34 returns 1
/// for it, p03_04).
pub fn fireTimed(t: f64) void {
    const n = cbs.items.len;
    for (0..n) |i| {
        const cb = cbs.items[i];
        if (cb.dead or (cb.reason != acbAbsTime and cb.reason != acbElapsedTime)) continue;
        if (!analog.sameTime(cb.due_real, t)) continue;
        _ = call(cb, cb.index, null);
        if (!cb.dead) retire(cb);
    }
    sweep();
}

/// The earliest acbAbsTime/acbElapsedTime instant strictly after `after`
/// and at most `until`: the next solution §12.31.3 says "shall" be forced.
pub fn nextForced(after: f64, until: f64) ?f64 {
    var best: ?f64 = null;
    for (cbs.items) |cb| {
        if (cb.dead or (cb.reason != acbAbsTime and cb.reason != acbElapsedTime)) continue;
        if (cb.due_real <= after or analog.sameTime(cb.due_real, after) or cb.due_real > until) continue;
        best = @min(best orelse cb.due_real, cb.due_real);
    }
    return best;
}

fn retire(cb: *Cb) void {
    _ = live.remove(@intFromPtr(cb));
    cb.dead = true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

var order: [8]u8 = undefined;
var order_len: usize = 0;

fn note(c: u8) void {
    order[order_len] = c;
    order_len += 1;
}

fn onCompile(d: *CbData) callconv(.c) c_int {
    std.debug.assert(d.reason == cbEndOfCompile);
    note('C');
    return 0;
}
fn onStart(_: *CbData) callconv(.c) c_int {
    note('S');
    return 0;
}
fn onEnd(d: *CbData) callconv(.c) c_int {
    note(if (d.user_data != null) d.user_data[0] else 'E');
    return 0;
}

var self_handle: vpiHandle = null;
fn removeSelf(_: *CbData) callconv(.c) c_int {
    note('R');
    std.debug.assert(vpi_remove_cb(self_handle) == 1);
    return 0;
}

test "§12.31.4: action callbacks fire once each, in registration order, with user_data" {
    reset();
    defer reset();
    order_len = 0;
    var tag = "X".*;
    const regs = [_]CbData{
        .{ .reason = cbEndOfSimulation, .cb_rtn = onEnd, .obj = null, .time = null, .value = null, .index = 0, .user_data = &tag },
        .{ .reason = cbEndOfCompile, .cb_rtn = onCompile, .obj = null, .time = null, .value = null, .index = 0, .user_data = null },
        .{ .reason = cbStartOfSimulation, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null },
    };
    for (&regs) |*r| try std.testing.expect(vpi_register_cb(r) != null);
    endOfCompile();
    startOfSimulation();
    endOfSimulation();
    try std.testing.expectEqualStrings("CSX", order[0..order_len]);
}

test "§12.34/§12.6: removal invalidates the handle, and info round-trips" {
    reset();
    defer reset();
    var tag = "u".*;
    var t: Time = .{ .type = vpiSimTime, .high = 0, .low = 0, .real = 0 };
    const reg: CbData = .{ .reason = cbEndOfCompile, .cb_rtn = onCompile, .obj = null, .time = &t, .value = null, .index = 3, .user_data = &tag };
    const h = vpi_register_cb(&reg);
    try std.testing.expect(h != null);
    // §12.31.1: the registration is COPIED — changing the caller's struct
    // afterwards changes nothing.
    t.type = vpiScaledRealTime;

    var it: Time = .{ .type = vpiSuppressTime, .high = 9, .low = 9, .real = 9 };
    var iv: Value = std.mem.zeroes(Value);
    iv.format = 99;
    var info: CbData = .{ .reason = 0, .cb_rtn = null, .obj = null, .time = &it, .value = &iv, .index = 0, .user_data = null };
    vpi_get_cb_info(h, &info);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expectEqual(cbEndOfCompile, info.reason);
    try std.testing.expect(info.cb_rtn == @as(?Routine, onCompile));
    try std.testing.expectEqual(@as(c_int, 3), info.index);
    try std.testing.expect(info.user_data == @as([*c]u8, &tag));
    try std.testing.expectEqual(vpiSimTime, it.type);
    try std.testing.expectEqual(vpiSuppressVal, iv.format);

    try std.testing.expectEqual(@as(c_int, 1), vpi_remove_cb(h));
    try std.testing.expectEqual(@as(c_int, 0), vpi_remove_cb(h));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    vpi_get_cb_info(h, &info);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}

test "a callback may remove itself during its own dispatch" {
    reset();
    defer reset();
    order_len = 0;
    const reg: CbData = .{ .reason = cbEndOfCompile, .cb_rtn = removeSelf, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    self_handle = vpi_register_cb(&reg);
    endOfCompile();
    endOfCompile();
    try std.testing.expectEqualStrings("R", order[0..order_len]);
    try std.testing.expectEqual(@as(usize, 0), cbs.items.len);
}

test "registrations VerA cannot keep are refused with vpiError" {
    reset();
    defer reset();
    // No routine.
    const none: CbData = .{ .reason = cbEndOfCompile, .cb_rtn = null, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&none) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    // A time reason with no time, and with vpiSuppressTime (IEEE 1364 27.33.2).
    var t: Time = .{ .type = vpiSuppressTime, .high = 0, .low = 5, .real = 0 };
    var bad: CbData = .{ .reason = cbAfterDelay, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&bad) == null);
    bad.time = &t;
    try std.testing.expect(vpi_register_cb(&bad) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    // A value change on something that is not an object.
    var junk: u32 = 0;
    const vc: CbData = .{ .reason = cbValueChange, .cb_rtn = onStart, .obj = @ptrCast(&junk), .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&vc) == null);
    // A reason VerA does not deliver, and a cbStmt on no statement.
    const unknown: CbData = .{ .reason = 9999, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&unknown) == null);
    const stmt: CbData = .{ .reason = cbStmt, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&stmt) == null);
    try std.testing.expectEqual(@as(usize, 0), cbs.items.len);
}

test "the reason classes: analog, startup and time" {
    try std.testing.expect(!isAnalogReason(acbInitialStep - 1));
    try std.testing.expect(isAnalogReason(acbInitialStep));
    try std.testing.expect(isAnalogReason(acbAcceptedPoint));
    try std.testing.expect(!isAnalogReason(acbAcceptedPoint + 1));
    for ([_]c_int{ cbEndOfCompile, cbStartOfSimulation, cbEndOfSimulation, cbError, cbPLIError }) |r| try std.testing.expect(startupReason(r));
    for ([_]c_int{ cbValueChange, cbAfterDelay, cbInteractiveScopeChange, cbTchkViolation, acbInitialStep }) |r| try std.testing.expect(!startupReason(r));
    for ([_]c_int{ cbAtStartOfSimTime, cbReadWriteSynch, cbReadOnlySynch, cbNextSimTime, cbAfterDelay }) |r| try std.testing.expect(isTimeReason(r));
    for ([_]c_int{ cbValueChange, cbStmt, cbEndOfCompile, acbAbsTime }) |r| try std.testing.expect(!isTimeReason(r));
}

test "§12.31.3: an analog time is a finite, non-negative vpiScaledRealTime, forced in order" {
    reset();
    defer reset();
    var t: Time = .{ .type = vpiScaledRealTime, .high = 0, .low = 0, .real = 0.5 };
    var d: CbData = .{ .reason = acbAbsTime, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&d) == null);
    d.time = &t;
    t.type = vpiSimTime;
    try std.testing.expect(vpi_register_cb(&d) == null);
    t.type = vpiScaledRealTime;
    for ([_]f64{ -1, std.math.nan(f64), std.math.inf(f64) }) |bad| {
        t.real = bad;
        try std.testing.expect(vpi_register_cb(&d) == null);
        try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    }
    t.real = 0.5;
    try std.testing.expect(vpi_register_cb(&d) != null);
    // Outside an analysis an elapsed time counts from 0.
    d.reason = acbElapsedTime;
    t.real = 0.25;
    try std.testing.expect(vpi_register_cb(&d) != null);
    // nextForced: strictly after `after`, at most `until`.
    try std.testing.expectEqual(@as(?f64, 0.25), nextForced(0, 1));
    try std.testing.expectEqual(@as(?f64, 0.5), nextForced(0.25, 1));
    try std.testing.expectEqual(@as(?f64, null), nextForced(0.5, 1));
    try std.testing.expectEqual(@as(?f64, 0.25), nextForced(0, 0.3));
    try std.testing.expectEqual(@as(?f64, null), nextForced(0.3, 0.4));
}

var timed_calls: u32 = 0;
fn onTimed(_: *CbData) callconv(.c) c_int {
    timed_calls += 1;
    return 0;
}

test "§12.31.3: a timed analog callback fires once, at its time up to rounding, then is retired" {
    reset();
    defer reset();
    timed_calls = 0;
    var t: Time = .{ .type = vpiScaledRealTime, .high = 0, .low = 0, .real = 1.0 };
    const d: CbData = .{ .reason = acbAbsTime, .cb_rtn = onTimed, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    const h = vpi_register_cb(&d);
    try std.testing.expect(h != null);
    fireTimed(0.5);
    try std.testing.expectEqual(@as(u32, 0), timed_calls);
    fireTimed(1.0 + 1e-15);
    try std.testing.expectEqual(@as(u32, 1), timed_calls);
    try std.testing.expect(asCb(h) == null);
    fireTimed(1.0);
    try std.testing.expectEqual(@as(u32, 1), timed_calls);
    try std.testing.expectEqual(@as(usize, 0), cbs.items.len);
}

var verdicts: [2]c_int = .{ 0, 0 };
var verdict_calls: u32 = 0;
fn verdict(d: *CbData) callconv(.c) c_int {
    verdict_calls += 1;
    return verdicts[@intCast(d.index)];
}

test "§12.31.3 acbConvergenceTest: every callback runs, and any nonzero rejects" {
    reset();
    defer reset();
    for (0..2) |i| {
        const d: CbData = .{ .reason = acbConvergenceTest, .cb_rtn = verdict, .obj = null, .time = null, .value = null, .index = @intCast(i), .user_data = null };
        try std.testing.expect(vpi_register_cb(&d) != null);
    }
    verdict_calls = 0;
    verdicts = .{ 0, 0 };
    try std.testing.expect(!convergenceRejected());
    // The first rejects; the second still runs.
    verdicts = .{ 7, 0 };
    try std.testing.expect(convergenceRejected());
    try std.testing.expectEqual(@as(u32, 4), verdict_calls);
}

fn registerAt(reason: c_int, low: c_uint) !void {
    var t: Time = .{ .type = vpiSimTime, .high = 0, .low = low, .real = 0 };
    const d: CbData = .{ .reason = reason, .cb_rtn = onStart, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    if (vpi_register_cb(&d) == null) return error.TestUnexpectedResult;
}

test "§12.31.2 nextDue: the earliest pending time callback; cbNextSimTime holds no time" {
    root.close();
    defer root.close();
    try registerAt(cbAfterDelay, 5);
    try registerAt(cbReadOnlySynch, 9);
    const next: CbData = .{ .reason = cbNextSimTime, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&next) != null);
    try std.testing.expectEqual(@as(?u64, 5), nextDue(0, true));
    try std.testing.expectEqual(@as(?u64, 5), nextDue(5, true));
    try std.testing.expectEqual(@as(?u64, 9), nextDue(5, false));
    try std.testing.expectEqual(@as(?u64, null), nextDue(9, false));
}

var chain_calls: u32 = 0;
fn chain(_: *CbData) callconv(.c) c_int {
    chain_calls += 1;
    if (chain_calls == 1) {
        const again: CbData = .{ .reason = cbEndOfCompile, .cb_rtn = chain, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
        std.debug.assert(vpi_register_cb(&again) != null);
    }
    return 0;
}

test "a callback registered during a dispatch waits for the next occurrence" {
    reset();
    defer reset();
    chain_calls = 0;
    const first: CbData = .{ .reason = cbEndOfCompile, .cb_rtn = chain, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&first) != null);
    endOfCompile();
    try std.testing.expectEqual(@as(u32, 1), chain_calls);
    try std.testing.expectEqual(@as(usize, 2), cbs.items.len);
    endOfCompile();
    try std.testing.expectEqual(@as(u32, 3), chain_calls);
}

var victim: vpiHandle = null;
var victim_calls: u32 = 0;
fn killer(_: *CbData) callconv(.c) c_int {
    std.debug.assert(vpi_remove_cb(victim) == 1);
    return 0;
}
fn victimRoutine(_: *CbData) callconv(.c) c_int {
    victim_calls += 1;
    return 0;
}

test "§12.34: a callback removed by an earlier one in the same dispatch does not fire" {
    reset();
    defer reset();
    victim_calls = 0;
    const k: CbData = .{ .reason = cbStartOfSimulation, .cb_rtn = killer, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    const v: CbData = .{ .reason = cbStartOfSimulation, .cb_rtn = victimRoutine, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&k) != null);
    victim = vpi_register_cb(&v);
    try std.testing.expect(victim != null);
    startOfSimulation();
    try std.testing.expectEqual(@as(u32, 0), victim_calls);
    // The sweep after the dispatch dropped the removed record.
    try std.testing.expectEqual(@as(usize, 1), cbs.items.len);
}

var pli_calls: u32 = 0;
fn onPli(_: *CbData) callconv(.c) c_int {
    pli_calls += 1;
    // A routine failing inside cbPLIError fires no second cbPLIError.
    _ = vpi_remove_cb(null);
    return 0;
}

test "IEEE 1364-2005 §27.33.3 cbPLIError: once per failing call, and the caller keeps its error" {
    reset();
    defer reset();
    pli_calls = 0;
    const d: CbData = .{ .reason = cbPLIError, .cb_rtn = onPli, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&d) != null);
    var junk: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 0), vpi_remove_cb(@ptrCast(&junk)));
    try std.testing.expectEqual(@as(u32, 1), pli_calls);
    // The status is the outer call's, not the one the callback's own failing
    // call left.
    var info: root.ErrorInfo = undefined;
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(&info));
    try std.testing.expectEqualStrings("BADHANDLE", std.mem.span(info.code));
    try std.testing.expect(std.mem.find(u8, std.mem.span(info.message), "that handle") != null);
}

test "IEEE 1364-2005 §27.8/§27.29 and §12.6: no save or restart; info into nothing" {
    reset();
    defer reset();
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), vpi_get_data(1, &buf, 4));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 0), vpi_put_data(1, &buf, 4));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    const d: CbData = .{ .reason = cbEndOfCompile, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    const h = vpi_register_cb(&d);
    vpi_get_cb_info(h, null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    // A registration with no time or value leaves those of the structure
    // read into alone.
    var info: CbData = .{ .reason = 0, .cb_rtn = null, .obj = null, .time = null, .value = null, .index = 9, .user_data = null };
    vpi_get_cb_info(h, &info);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expectEqual(cbEndOfCompile, info.reason);
    try std.testing.expectEqual(@as(c_int, 0), info.index);
    try std.testing.expect(info.time == null and info.value == null);
}

var swept: [4]u8 = undefined;
var swept_n: usize = 0;
fn noteTag(d: *CbData) callconv(.c) c_int {
    swept[swept_n] = d.user_data[0];
    swept_n += 1;
    return 0;
}

test "§12.34: removals outside a dispatch free at once, and the survivors keep their order" {
    reset();
    defer reset();
    var tags = "ABCD".*;
    var hs: [4]vpiHandle = undefined;
    for (&hs, 0..) |*h, i| {
        const d: CbData = .{ .reason = cbEndOfCompile, .cb_rtn = noteTag, .obj = null, .time = null, .value = null, .index = 0, .user_data = tags[i..].ptr };
        h.* = vpi_register_cb(&d);
    }
    try std.testing.expectEqual(@as(c_int, 1), vpi_remove_cb(hs[1]));
    try std.testing.expectEqual(@as(c_int, 1), vpi_remove_cb(hs[3]));
    try std.testing.expectEqual(@as(usize, 2), cbs.items.len);
    swept_n = 0;
    fireAll(cbEndOfCompile, null);
    try std.testing.expectEqualStrings("AC", swept[0..swept_n]);
}
