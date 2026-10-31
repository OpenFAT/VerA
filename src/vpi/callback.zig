//! The simulation-callback registry: a `CbData` -> a live `Cb` handle
//! (§12.31 vpi_register_cb), removed by §12.34 vpi_remove_cb and read back by
//! §12.6 vpi_get_cb_info; plus the cbStmt sites. Dispatch is callback_fire.zig's.
//!
//! A handle is a heap `Cb` pointer, valid while it is a key of `live`: C
//! pointers are never read until membership proves them ours. Removal deletes
//! the key first (§12.34: the handle "is no longer valid"); the `Cb` survives
//! until a sweep at dispatch depth zero, so a callback may remove itself.
//! Cites: VAMS-2023 §12.6, §12.31, §12.34; IEEE 1364-2005 §26.2.4, §26.6.39,
//! §27.8, §27.29, §27.33.
//!
//! Contents:
//! - `pub const Cb = struct`
//! - `pub const Site = struct`
//! - `pub var cbs: std.ArrayList(*Cb)`
//! - `pub var depth: u32`
//! - `pub var active: c_int`
//! - `pub fn isAnalogReason(r: c_int) bool`
//! - `pub fn asCb(h: abi.vpiHandle) ?*Cb`
//! - `pub fn reset() void`
//! - `pub fn isTimeReason(r: c_int) bool`
//! - `pub fn all(a: std.mem.Allocator, ref: abi.vpiHandle) ![]abi.vpiHandle`
//! - `pub fn vpi_register_cb(cb_data_p: ?*const CbData) abi.vpiHandle`
//! - `pub fn vpi_get_data(id: c_int, data_loc: ?[*]u8, num_bytes: c_int) c_int`
//! - `pub fn vpi_put_data(id: c_int, data_loc: ?[*]u8, num_bytes: c_int) c_int`
//! - `pub fn vpi_remove_cb(cb_obj: abi.vpiHandle) c_int`
//! - `pub fn vpi_get_cb_info(obj: abi.vpiHandle, cb_data_p: ?*CbData) void`
//! - `pub fn sweep() void`
//! - `pub fn sizeHooks(r: *const digital.Run) error`
//! - `pub fn retire(cb: *Cb) void`
//! - `pub fn onCompile(d: *CbData) callconv(.c) c_int`
//! - `pub fn onStart(_: *CbData) callconv(.c) c_int`

const std = @import("std");
const digital = @import("sim").digital;
const sim = @import("sim");
const gpa = std.heap.smp_allocator;
const abi = @import("abi.zig");
const analog = @import("analog.zig");
const callback_fire = @import("callback_fire.zig");
const run = @import("run.zig");
const schema = @import("schema.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const trust = @import("trust.zig");
const value = @import("value.zig");
const user = @import("vpi_user.zig");
const CbData = abi.CbData;
const ErrorInfo = abi.ErrorInfo;
const Routine = abi.Routine;
const Time = abi.Time;
const Unanswered = status.Unanswered;

/// One registration, owned by this file; see the header for its lifetime.
pub const Cb = struct {
    reason: c_int,
    rtn: Routine,
    obj: abi.vpiHandle,
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
    reference: abi.vpiHandle = null,
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

/// Registration order, dead ones included until the next sweep.
pub var cbs: std.ArrayList(*Cb) = .empty;

/// How many dispatches are on the stack; a sweep only runs at zero.
pub var depth: u32 = 0;

/// The reason of the innermost dispatch on the stack, 0 outside one.
pub var active: c_int = 0;

/// The live handles.
var live: std.AutoHashMapUnmanaged(usize, *Cb) = .empty;

const no_save = "VerA has no save or restart (IEEE 1364-2005 C.8)";
const no_interactive = "a VerA run has no interactive mode (§12.36: vpiStop ends the run)";

/// The pcs a live cbStmt fires at, which the engine checks (`StmtHook`).
var hooked: std.bit_set.Dynamic = .{};

var order: [8]u8 = undefined;
var order_len: usize = 0;
var self_handle: abi.vpiHandle = null;
var timed_calls: u32 = 0;
var verdicts: [2]c_int = .{ 0, 0 };
var verdict_calls: u32 = 0;
var chain_calls: u32 = 0;
var victim: abi.vpiHandle = null;
var victim_calls: u32 = 0;
var pli_calls: u32 = 0;
var swept: [4]u8 = undefined;
var swept_n: usize = 0;

/// Whether `r` is one of the §12.31.3 analog reasons.
pub fn isAnalogReason(r: c_int) bool {
    return r >= user.acbInitialStep and r <= user.acbAcceptedPoint;
}

/// Returns `h` as a live callback, or null; never dereferences a foreign
/// pointer.
pub fn asCb(h: abi.vpiHandle) ?*Cb {
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

pub fn isTimeReason(r: c_int) bool {
    return switch (r) {
        user.cbAtStartOfSimTime, user.cbReadWriteSynch, user.cbReadOnlySynch, user.cbNextSimTime, user.cbAfterDelay => true,
        else => false,
    };
}

/// IEEE 1364-2005 §26.6.39: callbacks on an object, a time queue, or NULL
/// for callbacks unrelated to either. Snapshot only live registrations;
/// the caller owns the returned slice, whose handles retain their ordinary
/// callback lifetime (§27.35). No iteration order is promised by the LRM.
pub fn all(a: std.mem.Allocator, ref: abi.vpiHandle) ![]abi.vpiHandle {
    const queue = run.asQueue(ref);
    const next = if (queue != null) try run.nextTime(run.now(), a) else null;
    // At most one handle per registration.
    var out: std.ArrayList(abi.vpiHandle) = try .initCapacity(a, cbs.items.len);
    errdefer out.deinit(a);
    for (cbs.items) |cb| {
        if (cb.dead) continue;
        const matches = if (isTimeReason(cb.reason)) blk: {
            const q = queue orelse break :blk false;
            if (cb.reason == user.cbNextSimTime)
                break :blk next != null and q.time == next.? and q.time > cb.since;
            break :blk q.time == cb.due;
        } else if (cb.reason == user.cbStmt) blk: {
            // §27.33.1.3's module registration is one callback placed on
            // every covered statement. §26.6.39 reaches that same handle
            // from each statement, once even if it has several engine pcs.
            if (ref == null or queue != null) break :blk false;
            if (cb.reference == ref) break :blk true;
            for (cb.sites) |site| {
                if (@as(abi.vpiHandle, @ptrCast(&session.design.?.objects[site.obj])) == ref)
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
pub export fn vpi_register_cb(cb_data_p: ?*const CbData) abi.vpiHandle {
    status.clearError();
    const d = cb_data_p orelse {
        status.fail("BADCB", "vpi_register_cb: cb_data_p is NULL", .{});
        return null;
    };
    const rtn = d.cb_rtn orelse {
        status.fail("BADCB", "vpi_register_cb: cb_rtn is NULL", .{});
        return null;
    };
    if (unansweredReason(d.reason)) |u| {
        status.failUnanswered("vpi_register_cb", u);
        return null;
    }
    if (session.starting and !startupReason(d.reason)) {
        status.fail("STARTUP", "vpi_register_cb: IEEE 1364-2005 §26.2.4 allows reason {d} only after vlog_startup_routines; register it from a cbEndOfCompile callback", .{d.reason});
        return null;
    }
    var cb: Cb = .{
        .reason = d.reason,
        .rtn = rtn,
        .obj = d.obj,
        .user_data = d.user_data,
        .index = d.index,
        .time_type = if (d.time) |t| t.type else user.vpiSuppressTime,
        .time = if (d.time) |t| t.* else std.mem.zeroes(Time),
        .value_format = if (d.value) |v| v.format else user.vpiSuppressVal,
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
        user.cbEndOfCompile, user.cbStartOfSimulation, user.cbEndOfSimulation, user.cbError, user.cbPLIError, user.cbInteractiveScopeChange, user.cbTchkViolation, user.cbStartOfReset, user.cbEndOfReset => {},
        // §12.31.1: "For force and release callbacks, if this is set to NULL,
        // every force and release shall generate a callback." A non-NULL obj
        // must be one VerA issued. cbAssign/cbDeassign take the same: the
        // clause states the NULL rule for force and release only, and VerA
        // reads it for the procedural pair too (one statement per callback).
        user.cbForce, user.cbRelease, user.cbAssign, user.cbDeassign => {
            if (d.obj != null and trust.asObj(d.obj) == null) {
                status.fail("BADHANDLE", "vpi_register_cb: obj is not a handle to an object", .{});
                return null;
            }
            cb.reference = d.obj;
        },
        // §12.31.1 cbDisable "After a named block or task containing a system
        // task/function has been disabled". ponytail: obj is a named begin or
        // fork; a task, function or system call as obj is refused, and the
        // block need not contain a system call (VerA does not check it).
        user.cbDisable => {
            const o = trust.asObj(d.obj);
            if (o == null or o.?.kind != .code or (o.?.vtype != user.vpiNamedBegin and o.?.vtype != user.vpiNamedFork)) {
                status.fail("NOTSUPPORTED", "vpi_register_cb: cbDisable is delivered for a named begin or fork in obj", .{});
                return null;
            }
            cb.sites = stmtSites(d.obj) orelse return null;
            cb.reference = d.obj;
        },
        // §12.31.1 "After value change on an expression or terminal". The
        // object must be one whose value can change in this process: a
        // digital net, reg, variable or memory word.
        user.cbValueChange => {
            const o = trust.asObj(d.obj) orelse {
                status.fail("BADHANDLE", "vpi_register_cb: cbValueChange needs an object handle in obj", .{});
                return null;
            };
            // IEEE 1364-2005 §26.6.20 Details a.
            if (o.automatic) {
                status.fail("AUTOMATIC", "vpi_register_cb: `{s}` is an automatic variable, and a value change callback on one is illegal", .{o.full});
                return null;
            }
            if (o.slot == .none and (schema.coldOf(o).members.len == 0 or session.design.?.objects[schema.coldOf(o).members[0]].slot == .none)) {
                status.fail("NOVALUE", "vpi_register_cb: `{s}` has no simulation value that can change", .{o.full});
                return null;
            }
            cb.reference = d.obj;
            value.watch(o);
        },
        // IEEE 1364-2005 §27.33.1.1 a statement Table 27-6 lists, or
        // §27.33.1.3 a module: "every statement that can have a callback
        // placed on it".
        user.cbStmt => {
            cb.sites = stmtSites(d.obj) orelse return null;
            cb.reference = d.obj;
        },
        user.cbAtStartOfSimTime, user.cbReadWriteSynch, user.cbReadOnlySynch, user.cbAfterDelay, user.cbNextSimTime => {
            // IEEE 1364-2005 27.33.2, which §12.31 defers to for the header:
            // a time callback needs a time it can deliver in. cbNextSimTime is
            // the exception — "For reason cbNextSimTime, the time structure is
            // ignored" (§12.31.2) — but it still says which FORMAT to deliver.
            if (d.reason != user.cbNextSimTime and (d.time == null or cb.time_type == user.vpiSuppressTime)) {
                status.fail("BADTIME", "vpi_register_cb: reason {d} needs a vpiSimTime or vpiScaledRealTime time", .{d.reason});
                return null;
            }
            if (cb.time_type != user.vpiSimTime and cb.time_type != user.vpiScaledRealTime and cb.time_type != user.vpiSuppressTime) {
                status.fail("BADTIME", "vpi_register_cb: time type {d} is not a §12.15 time type", .{cb.time_type});
                return null;
            }
            const now = run.now();
            cb.since = now;
            if (d.reason != user.cbNextSimTime) {
                const ticks = run.ticksOf(cb.time, d.obj) orelse return null;
                // §12.31.2: cbAtStartOfSimTime names a TIME; the others name a
                // DELAY from now ("after a specified amount of time").
                cb.due = if (d.reason == user.cbAtStartOfSimTime) ticks else now +| ticks;
                if (cb.due < now) {
                    status.fail("BADTIME", "vpi_register_cb: time {d} is already in the past (now {d})", .{ cb.due, now });
                    return null;
                }
                // IEEE 1364-2005 §27.33.2: "The following situations will
                // generate an error, and no callback will be created".
                if (cb.due == now and d.reason == user.cbAtStartOfSimTime and run.started and active != user.cbAtStartOfSimTime) {
                    status.fail("BADTIME", "vpi_register_cb: time {d} has progressed past its start, outside a cbAtStartOfSimTime callback", .{now});
                    return null;
                }
                if (cb.due == now and d.reason == user.cbReadWriteSynch and run.read_only) {
                    status.fail("BADTIME", "vpi_register_cb: a cbReadWriteSynch of delay zero at read-only synch time", .{});
                    return null;
                }
            }
        },
        // §12.31.3. The four step reasons carry no time; acbAbsTime names an
        // absolute analog time and acbElapsedTime an interval "advanced from
        // the current solution" — the latest accepted one, or the start of
        // the next analysis when none is running. Both are seconds, so only
        // vpiScaledRealTime can state them.
        user.acbInitialStep, user.acbFinalStep, user.acbConvergenceTest, user.acbAcceptedPoint => {},
        user.acbAbsTime, user.acbElapsedTime => {
            const t = d.time orelse {
                status.fail("BADTIME", "vpi_register_cb: reason {d} needs a vpiScaledRealTime time", .{d.reason});
                return null;
            };
            if (t.type != user.vpiScaledRealTime) {
                status.fail("BADTIME", "vpi_register_cb: an analog time is in seconds; time type {d} is not vpiScaledRealTime", .{t.type});
                return null;
            }
            if (!std.math.isFinite(t.real) or t.real < 0) {
                status.fail("BADTIME", "vpi_register_cb: {e} is not a time an analysis reaches", .{t.real});
                return null;
            }
            cb.due_real = if (d.reason == user.acbAbsTime) t.real else analog.acceptedTime() + t.real;
        },
        else => {
            status.fail("NOREASON", "vpi_register_cb: reason {d} is not a reason VerA can deliver", .{d.reason});
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
    if (cb.reason == user.cbStmt) rehook();
    return @ptrCast(p);
}

/// IEEE 1364-2005 §27.8 and §27.29: each "can only be called from an
/// application routine that has been called for reason cbStartOfRestart or
/// cbEndOfRestart" (cbStartOfSave or cbEndOfSave), and fails with 0
/// otherwise. VerA has no save or restart (Annex C.8), so those callbacks
/// never run and every call fails.
pub export fn vpi_get_data(id: c_int, data_loc: ?[*]u8, num_bytes: c_int) c_int {
    if (status.refused("vpi_get_data")) return 0;
    _ = .{ id, data_loc, num_bytes };
    status.fail("NOSAVE", "vpi_get_data: only a cbStartOfRestart or cbEndOfRestart callback reads saved data, and VerA has no restart", .{});
    return 0;
}

/// See `vpi_get_data`.
pub export fn vpi_put_data(id: c_int, data_loc: ?[*]u8, num_bytes: c_int) c_int {
    if (status.refused("vpi_put_data")) return 0;
    _ = .{ id, data_loc, num_bytes };
    status.fail("NOSAVE", "vpi_put_data: only a cbStartOfSave or cbEndOfSave callback saves data, and VerA has no save", .{});
    return 0;
}

/// §12.34 "shall return a 1 (TRUE) if successful, and a 0 (FALSE) on a
/// failure. After vpi_remove_cb() is called with a handle to the callback, the
/// handle is no longer valid."
pub export fn vpi_remove_cb(cb_obj: abi.vpiHandle) c_int {
    if (status.refused("vpi_remove_cb")) return 0;
    const cb = asCb(cb_obj) orelse {
        status.fail("BADHANDLE", "vpi_remove_cb: {s} is not a live callback handle", .{trust.describe(cb_obj)});
        return 0;
    };
    _ = live.remove(@intFromPtr(cb));
    cb.dead = true;
    // Allocates nothing (`sizeHooks`), so a routine C calls cannot fail here.
    if (cb.reason == user.cbStmt) rehook();
    sweep();
    return 1;
}

/// §12.6 "shall return information about a simulation-related callback in an
/// s_cb_data structure. The memory for this structure shall be allocated by
/// the user." The `time` and `value` sub-structures are the user's too when
/// they point anywhere: they are written, never replaced.
pub export fn vpi_get_cb_info(obj: abi.vpiHandle, cb_data_p: ?*CbData) void {
    if (status.refused("vpi_get_cb_info")) return;
    const cb = asCb(obj) orelse {
        status.fail("BADHANDLE", "vpi_get_cb_info: {s} is not a live callback handle", .{trust.describe(obj)});
        return;
    };
    const out = cb_data_p orelse {
        status.fail("BADCB", "vpi_get_cb_info: cb_data_p is NULL", .{});
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
pub fn sweep() void {
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

/// Sizes `hooked` to `r`'s program, before `r` is attached
/// (`root.openDigital`), so `rehook` never allocates: `vpi_remove_cb` has
/// no failure to report but a bad handle (§12.34).
pub fn sizeHooks(r: *const digital.Run) error{OutOfMemory}!void {
    try hooked.resize(gpa, r.program.code.items.len, false);
}

pub fn retire(cb: *Cb) void {
    _ = live.remove(@intFromPtr(cb));
    cb.dead = true;
}

pub fn onCompile(d: *CbData) callconv(.c) c_int {
    std.debug.assert(d.reason == user.cbEndOfCompile);
    note('C');
    return 0;
}

pub fn onStart(_: *CbData) callconv(.c) c_int {
    note('S');
    return 0;
}

// ---- private ----

fn destroy(cb: *Cb) void {
    gpa.free(cb.sites);
    gpa.destroy(cb);
}

/// The callback reasons of Annex G no registration here is ever delivered
/// for (vpi_user.h's "Annex G names VerA does not answer"), refused by name
/// at any time, the startup phase included.
fn unansweredReason(r: c_int) ?Unanswered {
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
        user.cbEndOfCompile, user.cbStartOfSimulation, user.cbEndOfSimulation, user.cbError, user.cbPLIError => true,
        else => false,
    };
}

fn oom() abi.vpiHandle {
    status.fail("NOMEM", "vpi_register_cb: out of memory", .{});
    return null;
}

/// `obj`'s sites: a statement's own, or every statement's of a module
/// instance. Null, with the error recorded, for anything else.
fn stmtSites(obj: abi.vpiHandle) ?[]const Site {
    const o = trust.asObj(obj) orelse {
        status.fail("BADHANDLE", "vpi_register_cb: cbStmt needs a statement or module handle in obj", .{});
        return null;
    };
    const one = o.stmt != .none and o.vtype != user.vpiNullStmt;
    if (!one and o.kind != .module) {
        status.fail("NOTSTMT", "vpi_register_cb: `{s}` is neither a statement Table 27-6 lists nor a module", .{o.full});
        return null;
    }
    const r = run.attached() orelse {
        status.fail("NOENGINE", "vpi_register_cb: no digital run executes statements", .{});
        return null;
    };
    const engine_sites = r.host.stmt_sites orelse {
        status.fail("NOSITES", "vpi_register_cb: this run records no statement sites", .{});
        return null;
    };
    const d = &session.design.?;
    const scope = if (one) o.owner.get().? else o.scope;
    // The statement objects this registration covers, by AST statement.
    var covered: std.AutoHashMapUnmanaged(@import("frontend").Ast.StmtId, u32) = .empty;
    defer covered.deinit(gpa);
    if (one) {
        covered.put(gpa, o.stmt, d.indexOf(o)) catch return oomSites();
    } else for (d.objects, 0..) |s, i| {
        if (s.kind != .code or s.owner.get() != scope or s.stmt == .none or s.vtype == user.vpiNullStmt) continue;
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
    status.fail("NOMEM", "vpi_register_cb: out of memory", .{});
    return null;
}

/// Rebuilds `hooked` from the live cbStmt callbacks, and installs the hook
/// on the engine while any is live. Asserts that `sizeHooks` sized it to the
/// attached program, whose length a reset keeps (it elaborates the same
/// source again).
fn rehook() void {
    const r = run.attached() orelse return;
    std.debug.assert(hooked.bit_length == r.program.code.items.len);
    hooked.unsetAll();
    for (cbs.items) |cb| {
        if (cb.dead or cb.reason != user.cbStmt) continue;
        for (cb.sites) |st| hooked.set(st.pc);
    }
    r.host.stmt_hook = if (hooked.findFirstSet() != null) .{ .at = &hooked, .fire = callback_fire.fireStmt } else null;
}

fn note(c: u8) void {
    order[order_len] = c;
    order_len += 1;
}

fn onEnd(d: *CbData) callconv(.c) c_int {
    note(if (d.user_data != null) d.user_data[0] else 'E');
    return 0;
}

fn removeSelf(_: *CbData) callconv(.c) c_int {
    note('R');
    std.debug.assert(vpi_remove_cb(self_handle) == 1);
    return 0;
}

fn onTimed(_: *CbData) callconv(.c) c_int {
    timed_calls += 1;
    return 0;
}

fn verdict(d: *CbData) callconv(.c) c_int {
    verdict_calls += 1;
    return verdicts[@intCast(d.index)];
}

fn chain(_: *CbData) callconv(.c) c_int {
    chain_calls += 1;
    if (chain_calls == 1) {
        const again: CbData = .{ .reason = user.cbEndOfCompile, .cb_rtn = chain, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
        std.debug.assert(vpi_register_cb(&again) != null);
    }
    return 0;
}

fn killer(_: *CbData) callconv(.c) c_int {
    std.debug.assert(vpi_remove_cb(victim) == 1);
    return 0;
}

fn victimRoutine(_: *CbData) callconv(.c) c_int {
    victim_calls += 1;
    return 0;
}

fn onPli(_: *CbData) callconv(.c) c_int {
    pli_calls += 1;
    // A routine failing inside cbPLIError fires no second cbPLIError.
    _ = vpi_remove_cb(null);
    return 0;
}

fn noteTag(d: *CbData) callconv(.c) c_int {
    swept[swept_n] = d.user_data[0];
    swept_n += 1;
    return 0;
}

test "§12.31.4: action callbacks fire once each, in registration order, with user_data" {
    reset();
    defer reset();
    order_len = 0;
    var tag = "X".*;
    const regs = [_]CbData{
        .{ .reason = user.cbEndOfSimulation, .cb_rtn = onEnd, .obj = null, .time = null, .value = null, .index = 0, .user_data = &tag },
        .{ .reason = user.cbEndOfCompile, .cb_rtn = onCompile, .obj = null, .time = null, .value = null, .index = 0, .user_data = null },
        .{ .reason = user.cbStartOfSimulation, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null },
    };
    for (&regs) |*r| try std.testing.expect(vpi_register_cb(r) != null);
    callback_fire.endOfCompile();
    callback_fire.startOfSimulation();
    callback_fire.endOfSimulation();
    try std.testing.expectEqualStrings("CSX", order[0..order_len]);
}

test "a callback may remove itself during its own dispatch" {
    reset();
    defer reset();
    order_len = 0;
    const reg: CbData = .{ .reason = user.cbEndOfCompile, .cb_rtn = removeSelf, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    self_handle = vpi_register_cb(&reg);
    callback_fire.endOfCompile();
    callback_fire.endOfCompile();
    try std.testing.expectEqualStrings("R", order[0..order_len]);
    try std.testing.expectEqual(@as(usize, 0), cbs.items.len);
}

test "registrations VerA cannot keep are refused with vpiError" {
    reset();
    defer reset();
    // No routine.
    const none: CbData = .{ .reason = user.cbEndOfCompile, .cb_rtn = null, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&none) == null);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    // A time reason with no time, and with vpiSuppressTime (IEEE 1364 27.33.2).
    var t: Time = .{ .type = user.vpiSuppressTime, .high = 0, .low = 5, .real = 0 };
    var bad: CbData = .{ .reason = user.cbAfterDelay, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&bad) == null);
    bad.time = &t;
    try std.testing.expect(vpi_register_cb(&bad) == null);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    // A value change on something that is not an object.
    var junk: u32 = 0;
    const vc: CbData = .{ .reason = user.cbValueChange, .cb_rtn = onStart, .obj = @ptrCast(&junk), .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&vc) == null);
    // A reason VerA does not deliver, and a cbStmt on no statement.
    const unknown: CbData = .{ .reason = 9999, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&unknown) == null);
    const stmt: CbData = .{ .reason = user.cbStmt, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&stmt) == null);
    try std.testing.expectEqual(@as(usize, 0), cbs.items.len);
}

test "the reason classes: analog, startup and time" {
    try std.testing.expect(!isAnalogReason(user.acbInitialStep - 1));
    try std.testing.expect(isAnalogReason(user.acbInitialStep));
    try std.testing.expect(isAnalogReason(user.acbAcceptedPoint));
    try std.testing.expect(!isAnalogReason(user.acbAcceptedPoint + 1));
    for ([_]c_int{ user.cbEndOfCompile, user.cbStartOfSimulation, user.cbEndOfSimulation, user.cbError, user.cbPLIError }) |r| try std.testing.expect(startupReason(r));
    for ([_]c_int{ user.cbValueChange, user.cbAfterDelay, user.cbInteractiveScopeChange, user.cbTchkViolation, user.acbInitialStep }) |r| try std.testing.expect(!startupReason(r));
    for ([_]c_int{ user.cbAtStartOfSimTime, user.cbReadWriteSynch, user.cbReadOnlySynch, user.cbNextSimTime, user.cbAfterDelay }) |r| try std.testing.expect(isTimeReason(r));
    for ([_]c_int{ user.cbValueChange, user.cbStmt, user.cbEndOfCompile, user.acbAbsTime }) |r| try std.testing.expect(!isTimeReason(r));
}

test "§12.31.3: an analog time is a finite, non-negative vpiScaledRealTime, forced in order" {
    reset();
    defer reset();
    var t: Time = .{ .type = user.vpiScaledRealTime, .high = 0, .low = 0, .real = 0.5 };
    var d: CbData = .{ .reason = user.acbAbsTime, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&d) == null);
    d.time = &t;
    t.type = user.vpiSimTime;
    try std.testing.expect(vpi_register_cb(&d) == null);
    t.type = user.vpiScaledRealTime;
    for ([_]f64{ -1, std.math.nan(f64), std.math.inf(f64) }) |bad| {
        t.real = bad;
        try std.testing.expect(vpi_register_cb(&d) == null);
        try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    }
    t.real = 0.5;
    try std.testing.expect(vpi_register_cb(&d) != null);
    // Outside an analysis an elapsed time counts from 0.
    d.reason = user.acbElapsedTime;
    t.real = 0.25;
    try std.testing.expect(vpi_register_cb(&d) != null);
    // nextForced: strictly after `after`, at most `until`.
    try std.testing.expectEqual(@as(?f64, 0.25), callback_fire.nextForced(0, 1));
    try std.testing.expectEqual(@as(?f64, 0.5), callback_fire.nextForced(0.25, 1));
    try std.testing.expectEqual(@as(?f64, null), callback_fire.nextForced(0.5, 1));
    try std.testing.expectEqual(@as(?f64, 0.25), callback_fire.nextForced(0, 0.3));
    try std.testing.expectEqual(@as(?f64, null), callback_fire.nextForced(0.3, 0.4));
}

test "§12.31.3: a timed analog callback fires once, at its time up to rounding, then is retired" {
    reset();
    defer reset();
    timed_calls = 0;
    var t: Time = .{ .type = user.vpiScaledRealTime, .high = 0, .low = 0, .real = 1.0 };
    const d: CbData = .{ .reason = user.acbAbsTime, .cb_rtn = onTimed, .obj = null, .time = &t, .value = null, .index = 0, .user_data = null };
    const h = vpi_register_cb(&d);
    try std.testing.expect(h != null);
    callback_fire.fireTimed(0.5);
    try std.testing.expectEqual(@as(u32, 0), timed_calls);
    callback_fire.fireTimed(1.0 + 1e-15);
    try std.testing.expectEqual(@as(u32, 1), timed_calls);
    try std.testing.expect(asCb(h) == null);
    callback_fire.fireTimed(1.0);
    try std.testing.expectEqual(@as(u32, 1), timed_calls);
    try std.testing.expectEqual(@as(usize, 0), cbs.items.len);
}

test "§12.31.3 acbConvergenceTest: every callback runs, and any nonzero rejects" {
    reset();
    defer reset();
    for (0..2) |i| {
        const d: CbData = .{ .reason = user.acbConvergenceTest, .cb_rtn = verdict, .obj = null, .time = null, .value = null, .index = @intCast(i), .user_data = null };
        try std.testing.expect(vpi_register_cb(&d) != null);
    }
    verdict_calls = 0;
    verdicts = .{ 0, 0 };
    try std.testing.expect(!callback_fire.convergenceRejected());
    // The first rejects; the second still runs.
    verdicts = .{ 7, 0 };
    try std.testing.expect(callback_fire.convergenceRejected());
    try std.testing.expectEqual(@as(u32, 4), verdict_calls);
}

test "a callback registered during a dispatch waits for the next occurrence" {
    reset();
    defer reset();
    chain_calls = 0;
    const first: CbData = .{ .reason = user.cbEndOfCompile, .cb_rtn = chain, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&first) != null);
    callback_fire.endOfCompile();
    try std.testing.expectEqual(@as(u32, 1), chain_calls);
    try std.testing.expectEqual(@as(usize, 2), cbs.items.len);
    callback_fire.endOfCompile();
    try std.testing.expectEqual(@as(u32, 3), chain_calls);
}

test "§12.34: a callback removed by an earlier one in the same dispatch does not fire" {
    reset();
    defer reset();
    victim_calls = 0;
    const k: CbData = .{ .reason = user.cbStartOfSimulation, .cb_rtn = killer, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    const v: CbData = .{ .reason = user.cbStartOfSimulation, .cb_rtn = victimRoutine, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&k) != null);
    victim = vpi_register_cb(&v);
    try std.testing.expect(victim != null);
    callback_fire.startOfSimulation();
    try std.testing.expectEqual(@as(u32, 0), victim_calls);
    // The sweep after the dispatch dropped the removed record.
    try std.testing.expectEqual(@as(usize, 1), cbs.items.len);
}

test "IEEE 1364-2005 §27.33.3 cbPLIError: once per failing call, and the caller keeps its error" {
    reset();
    defer reset();
    pli_calls = 0;
    const d: CbData = .{ .reason = user.cbPLIError, .cb_rtn = onPli, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    try std.testing.expect(vpi_register_cb(&d) != null);
    var junk: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 0), vpi_remove_cb(@ptrCast(&junk)));
    try std.testing.expectEqual(@as(u32, 1), pli_calls);
    // The status is the outer call's, not the one the callback's own failing
    // call left.
    var info: ErrorInfo = undefined;
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(&info));
    try std.testing.expectEqualStrings("BADHANDLE", std.mem.span(info.code));
    try std.testing.expect(std.mem.find(u8, std.mem.span(info.message), "that handle") != null);
}

test "IEEE 1364-2005 §27.8/§27.29 and §12.6: no save or restart; info into nothing" {
    reset();
    defer reset();
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), vpi_get_data(1, &buf, 4));
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    try std.testing.expectEqual(@as(c_int, 0), vpi_put_data(1, &buf, 4));
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    const d: CbData = .{ .reason = user.cbEndOfCompile, .cb_rtn = onStart, .obj = null, .time = null, .value = null, .index = 0, .user_data = null };
    const h = vpi_register_cb(&d);
    vpi_get_cb_info(h, null);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    // A registration with no time or value leaves those of the structure
    // read into alone.
    var info: CbData = .{ .reason = 0, .cb_rtn = null, .obj = null, .time = null, .value = null, .index = 9, .user_data = null };
    vpi_get_cb_info(h, &info);
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(null));
    try std.testing.expectEqual(user.cbEndOfCompile, info.reason);
    try std.testing.expectEqual(@as(c_int, 0), info.index);
    try std.testing.expect(info.time == null and info.value == null);
}

test "§12.34: removals outside a dispatch free at once, and the survivors keep their order" {
    reset();
    defer reset();
    var tags = "ABCD".*;
    var hs: [4]abi.vpiHandle = undefined;
    for (&hs, 0..) |*h, i| {
        const d: CbData = .{ .reason = user.cbEndOfCompile, .cb_rtn = noteTag, .obj = null, .time = null, .value = null, .index = 0, .user_data = tags[i..].ptr };
        h.* = vpi_register_cb(&d);
    }
    try std.testing.expectEqual(@as(c_int, 1), vpi_remove_cb(hs[1]));
    try std.testing.expectEqual(@as(c_int, 1), vpi_remove_cb(hs[3]));
    try std.testing.expectEqual(@as(usize, 2), cbs.items.len);
    swept_n = 0;
    callback_fire.fireAll(user.cbEndOfCompile, null);
    try std.testing.expectEqualStrings("AC", swept[0..swept_n]);
}
