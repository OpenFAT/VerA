//! §12.11 vpi_get_delays and §12.29 vpi_put_delays over gates, continuous
//! assignments, module paths, timing checks and delay controls, and IEEE
//! 1364-2005 §26.6.16's inter-module paths (§12.22).
//! Cites: VAMS-2023 §12.11, §12.22, §12.29, Table 12-5; IEEE 1364 §7.14,
//! §14.3.1 Tables 14-3/14-4, §26.6.16.
//!
//! Contents:
//! - `pub fn reset() void`
//! - `pub fn vpi_get_delays(obj: abi.vpiHandle, delay_p: ?*Delay) void`
//! - `pub fn vpi_put_delays(obj: abi.vpiHandle, delay_p: ?*Delay) void`
//! - `pub fn part(d: *const Delay, k: usize, p: usize) Time`
//! - `pub fn asPath(h: abi.vpiHandle) ?*InterModPath`
//! - `pub fn interModPath(ref1: abi.vpiHandle, ref2: abi.vpiHandle) abi.vpiHandle`

const std = @import("std");
const abi = @import("abi.zig");
const run = @import("run.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const trust = @import("trust.zig");
const user = @import("vpi_user.zig");
const schema = @import("schema.zig");
const Delay = abi.Delay;
const Obj = schema.Obj;
const Time = abi.Time;

/// The pulse limits a §12.29 put gave a module path, by object index: each
/// written delay's reject and error limit, kept apart from the delays so a
/// put of the delays alone leaves them ("If only the delay changes, and not
/// the pulse limits, the pulse limits shall retain the values they had"). A
/// path absent here has IEEE 1364 §14.6.1's default, both limits the delay
/// itself, which therefore follows a delay put. Slices live in the design's
/// arena; `reset` drops the table with the design.
const Limits = struct { reject: []const f64, err: []const f64 };

var limits: std.AutoHashMapUnmanaged(u32, Limits) = .empty;

/// IEEE 1364-2005 §26.6.16's inter-module path: the interconnect from port
/// row `ports[0]` (an output or inout) to port row `ports[1]` (an input or
/// inout), and the rise, fall and turn-off delays a put gave it, in
/// `ports[0]`'s module's time unit. An interconnect nothing was put on has no
/// delay, so they start at 0. Like a module path's, the delays are the
/// model's: no simulation applies one (VD-114).
const InterModPath = struct { ports: [2]u32, delays: [3]f64 = .{ 0, 0, 0 } };

/// Every inter-module path made since the design opened, each a handle.
/// ponytail: scanned per lookup; an application asks for a handful. Key a
/// map by the port pair when one asks for thousands.
var paths: std.ArrayList(*InterModPath) = .empty;

/// Forgets every path's pulse limits and every inter-module path
/// (`root.close`).
pub fn reset() void {
    limits.clearAndFree(std.heap.smp_allocator);
    for (paths.items) |m| std.heap.smp_allocator.destroy(m);
    paths.clearAndFree(std.heap.smp_allocator);
}

/// "shall retrieve the delays or pulse limits of an object and place them in
/// an s_vpi_delay structure which has been allocated by the user. The format
/// of the delay information shall be controlled by the time_type flag".
///
/// The objects with delays here are the ones §11.6 draws `vpi_get_delays()`
/// under and this model folds: a primitive (§11.6.13), a continuous
/// assignment (§11.6.17) and a delay control (§11.6.22). §12.11: "For
/// primitive objects, the no_of_delays value shall be 2 or 3." It names no
/// count for the other two; a continuous assignment carries a primitive's
/// delay3 (IEEE 1364 §6.1.3), so it takes 2 or 3 and the 1 its own `#d`
/// form writes, and a delay control holds 1. A delay asked for beyond those written is IEEE 1364
/// §7.14's derived one: fall = rise, turn-off = min(rise, fall).
///
/// Table 12-3's min/typ/max triple is one value three times (no mintypmax
/// expression reaches this model), and the reject and error limits are the
/// ones a put gave a path, else the delay itself (IEEE 1364 §14.6.1's
/// default, an inertial delay).
pub export fn vpi_get_delays(obj: abi.vpiHandle, delay_p: ?*Delay) void {
    if (status.refused("vpi_get_delays")) return;
    if (asPath(obj)) |m| return getPathDelays(m, delay_p);
    const o = trust.asObj(obj) orelse {
        status.fail("BADHANDLE", "vpi_get_delays: that handle is not an object", .{});
        return;
    };
    const d = delay_p orelse {
        status.fail("BADDELAY", "vpi_get_delays: delay_p is NULL", .{});
        return;
    };
    if (o.kind != .code or o.delays.len == 0) {
        status.fail("NODELAY", "vpi_get_delays: that object carries no delays", .{});
        return;
    }
    // §12.11: "For primitive objects, the no_of_delays value shall be 2 or
    // 3. For path delay objects, the no_of_delays value shall be 1, 2, 3, 6,
    // or 12. For timing check objects, the no_of_delays value shall match
    // the number of limits existing in the timing check."
    const primitive = o.vtype == user.vpiGate or o.vtype == user.vpiUdp;
    const legal = switch (o.vtype) {
        user.vpiModPath => switch (d.no_of_delays) {
            1, 2, 3, 6, 12 => true,
            else => false,
        },
        user.vpiTchk => d.no_of_delays == o.delays.len,
        else => d.no_of_delays >= @as(c_int, if (primitive) 2 else 1) and
            d.no_of_delays <= @as(c_int, if (o.vtype == user.vpiDelayControl) 1 else 3),
    };
    if (!legal) {
        status.fail("BADDELAY", "vpi_get_delays: no_of_delays {d} is not legal for this object", .{d.no_of_delays});
        return;
    }
    if (!timeTypeOk("vpi_get_delays", d)) return;
    if (d.da == null) {
        status.fail("BADDELAY", "vpi_get_delays: da is NULL", .{});
        return;
    }
    const rise = o.delays[0];
    const fall = if (o.delays.len > 1) o.delays[1] else rise;
    const off = if (o.delays.len > 2) o.delays[2] else @min(rise, fall);
    var values_buf: [12]f64 = undefined;
    const values: []const f64 = if (o.vtype == user.vpiModPath)
        pathDelays(o.delays, &values_buf)
    else if (o.vtype == user.vpiTchk)
        o.delays
    else blk: {
        values_buf[0..3].* = .{ rise, fall, off };
        break :blk values_buf[0..3];
    };
    // A path's put limits, spread over its transitions as its delays are.
    var reject_buf: [12]f64 = undefined;
    var err_buf: [12]f64 = undefined;
    const lim = if (o.vtype == user.vpiModPath) limits.get(session.design.?.indexOf(o)) else null;
    const rejects: []const f64 = if (lim) |l| pathDelays(l.reject, &reject_buf) else values;
    const errs: []const f64 = if (lim) |l| pathDelays(l.err, &err_buf) else values;
    fill(d, values, rejects, errs, obj);
}

/// "shall set the delays or timing limits of an object as indicated in the
/// delay_p structure. The same ordering of delays shall be used as described
/// in the vpi_get_delays() function. If only the delay changes, and not the
/// pulse limits, the pulse limits shall retain the values they had before the
/// delays where altered."
///
/// The objects are the ones whose delays the ENGINE applies — a primitive
/// (§11.6.13: "For primitive objects, the no_of_delays value shall be 2 or
/// 3") and a continuous assignment (§11.6.17, a delay3: 1..3), found as the
/// driver their statement became in their instance. The new delays hold from
/// the next transition the engine schedules; one already in flight keeps the
/// delay it was scheduled with (IEEE 1364 §6.1.3/§7.14 fix a delay when the
/// change is scheduled). A delay control (§11.6.22) is a statement's, read
/// by a process, not a driver's, and is refused.
///
/// Table 12-5's layouts: with `mtm_flag` each delay is a min/typ/max triple
/// and the TYPICAL is applied (no mintypmax selection reaches the engine,
/// which runs typical, as `vpi_get_delays` reports); with `pulsere_flag` each
/// is a (delay, reject, error) triple. A path keeps the limits (`limits`).
/// The engine's gates and continuous assignments run IEEE 1364 §14.6.1's
/// inertial default, both limits the delay itself, and no other: a put of
/// other limits onto one is refused rather than dropped.
pub export fn vpi_put_delays(obj: abi.vpiHandle, delay_p: ?*Delay) void {
    if (status.refused("vpi_put_delays")) return;
    if (asPath(obj)) |m| return putPathDelays(m, delay_p);
    const o = trust.asObj(obj) orelse {
        status.fail("BADHANDLE", "vpi_put_delays: that handle is not an object", .{});
        return;
    };
    const d = delay_p orelse {
        status.fail("BADDELAY", "vpi_put_delays: delay_p is NULL", .{});
        return;
    };
    const primitive = o.kind == .code and (o.vtype == user.vpiGate or o.vtype == user.vpiUdp);
    const assign = o.kind == .code and o.vtype == user.vpiContAssign;
    // §11.6.15's paths and timing checks: "For path delay objects, the
    // no_of_delays value shall be 1, 2, 3, 6, or 12. For timing check
    // objects, the no_of_delays value shall match the number of limits".
    // A path's delays are the model's to hold — no simulation here applies
    // a path delay (W0251) — so the put sets what vpi_get_delays reads
    // back. A timing check's limits are the engine's too: a digital run
    // judges every later event with them (IEEE 1364-2005 clause 15).
    if (o.kind == .code and o.vtype == user.vpiModPath) {
        _ = putModelDelays(o, d);
        return;
    }
    if (o.kind == .code and o.vtype == user.vpiTchk) {
        if (putModelDelays(o, d)) putEngineLimits(obj, o, d);
        return;
    }
    if (!primitive and !assign) {
        status.fail("NODELAY", "vpi_put_delays: that object has no delays a put can set", .{});
        return;
    }
    const least: c_int = if (primitive) 2 else 1;
    if (d.no_of_delays < least or d.no_of_delays > 3) {
        status.fail("BADDELAY", "vpi_put_delays: no_of_delays {d} is not legal here ({d}..3)", .{ d.no_of_delays, least });
        return;
    }
    if (!timeTypeOk("vpi_put_delays", d)) return;
    if (d.da == null) {
        status.fail("BADDELAY", "vpi_put_delays: da is NULL", .{});
        return;
    }
    const r = run.attached() orelse {
        status.fail("NOENGINE", "vpi_put_delays: no simulation is running this object's drivers", .{});
        return;
    };
    const n: usize = @intCast(d.no_of_delays);
    var ticks: [3]u64 = undefined;
    var units: [3]f64 = undefined;
    for (0..n) |k| {
        // The k-th delay's element: its typical (mtm), its delay (pulsere).
        const t = part(d, k, 0);
        if (t.type != d.time_type) {
            status.fail("BADDELAY", "vpi_put_delays: da[{d}] is not of the structure's time_type", .{k});
            return;
        }
        ticks[k] = run.ticksOf(t, obj) orelse return;
        units[k] = if (t.type == user.vpiScaledRealTime) t.real else run.unitsOf(ticks[k], obj);
        if (d.pulsere_flag != 0) for (1..3) |p| {
            const lt = part(d, k, p);
            const same = if (lt.type == user.vpiSimTime) lt.high == t.high and lt.low == t.low else lt.real == t.real;
            if (lt.type != t.type or !same) {
                status.fail("NOTSUPPORTED", "vpi_put_delays: this object's pulse limits are its delay (IEEE 1364 §14.6.1); other reject or error limits are not implemented for it", .{});
                return;
            }
        };
    }
    // IEEE 1364 §7.14's derivations for the delays not given.
    if (n < 2) ticks[1] = ticks[0];
    if (n < 3) ticks[2] = @min(ticks[0], ticks[1]);
    // Drivers are keyed by the ENGINE's instance scope, which a lexical engine
    // scope (a generate iteration, a task frame) can set apart from the
    // model's scope index.
    const scope = session.design.?.scopes[o.owner.get() orelse 0].engine;
    var hit = false;
    for (r.netlist.drivers) |*drv| {
        if (drv.tok != o.src_tok or drv.scope != scope) continue;
        drv.delay = .{ .rise = ticks[0], .fall = ticks[1], .off = ticks[2], .present = true };
        hit = true;
    }
    if (!hit) {
        status.fail("NODRIVER", "vpi_put_delays: the engine holds no driver for that statement", .{});
        return;
    }
    // What vpi_get_delays reads back: the written delays, in the module's
    // unit however they were given.
    const design = &session.design.?;
    design.objects[design.indexOf(o)].delays = design.arena.allocator().dupe(f64, units[0..n]) catch {
        status.fail("NOMEM", "vpi_put_delays: out of memory", .{});
        return;
    };
}

/// `d.da`'s delay `k`, part `p`, under `d`'s own mtm and pulsere flags.
pub fn part(d: *const Delay, k: usize, p: usize) Time {
    return d.da[element(k, p, if (d.mtm_flag != 0) 3 else 1, if (d.pulsere_flag != 0) 3 else 1)];
}

/// `h` as an inter-module path this design made, or null; never
/// dereferences a foreign pointer.
pub fn asPath(h: abi.vpiHandle) ?*InterModPath {
    const p = h orelse return null;
    for (paths.items) |m| if (@intFromPtr(m) == @intFromPtr(p)) return m;
    return null;
}

/// §12.22: "vpi_handle_multi() shall return a handle to objects of type
/// vpiInterModPath associated with a list of output port and input port
/// reference objects. The ports shall be of the same size and can be at
/// different levels of the hierarchy." The same pair is the same path, the
/// same handle (vpi_compare_objects reads identity). Two distinct ports,
/// `from` driving out (output or inout) and `to` reading in (input or
/// inout), of one size; whether a net joins them is not asked, as §12.22
/// does not ask it.
pub fn interModPath(ref1: abi.vpiHandle, ref2: abi.vpiHandle) abi.vpiHandle {
    const who = "vpi_handle_multi(vpiInterModPath)";
    const a = trust.asObj(ref1);
    const b = trust.asObj(ref2);
    if (a == null or b == null or a.?.kind != .port or b.?.kind != .port) {
        status.fail("BADHANDLE", who ++ ": an inter-module path joins two port handles", .{});
        return null;
    }
    const from = a.?;
    const to = b.?;
    if (from == to) {
        status.fail("BADPORT", who ++ ": `{s}` is both ends; a path joins two ports", .{from.full});
        return null;
    }
    if (from.direction != .output and from.direction != .inout) {
        status.fail("BADPORT", who ++ ": `{s}` is not an output or inout port, and the path leaves the first one", .{from.full});
        return null;
    }
    if (to.direction != .input and to.direction != .inout) {
        status.fail("BADPORT", who ++ ": `{s}` is not an input or inout port, and the path enters the second one", .{to.full});
        return null;
    }
    if (from.size != to.size or from.size == 0) {
        status.fail("BADPORT", who ++ ": `{s}` and `{s}` are not of the same size", .{ from.full, to.full });
        return null;
    }
    const key = [2]u32{ session.design.?.indexOf(from), session.design.?.indexOf(to) };
    for (paths.items) |m| if (std.mem.eql(u32, &m.ports, &key)) return @ptrCast(m);
    const gpa = std.heap.smp_allocator;
    const m = gpa.create(InterModPath) catch {
        status.fail("NOMEM", who ++ ": out of memory", .{});
        return null;
    };
    m.* = .{ .ports = key };
    paths.append(gpa, m) catch {
        gpa.destroy(m);
        status.fail("NOMEM", who ++ ": out of memory", .{});
        return null;
    };
    return @ptrCast(m);
}

// ---- private ----

/// Writes `values` (with their `rejects` and `errs`) into the user's `da` as
/// Table 12-5 lays them out, in `d.time_type`; a vpiSimTime counts ticks
/// of `unit_of`'s module's unit.
fn fill(d: *Delay, values: []const f64, rejects: []const f64, errs: []const f64, unit_of: abi.vpiHandle) void {
    const mtm: usize = if (d.mtm_flag != 0) 3 else 1;
    const pulse: usize = if (d.pulsere_flag != 0) 3 else 1;
    var at: usize = 0;
    // A path's first three transitions (0->1, 1->0, 0->z) ARE its rise,
    // fall and turn-off, so every count reads a prefix.
    for (values[0..@intCast(d.no_of_delays)], 0..) |delay_v, i| {
        for (0..pulse) |p| for (0..mtm) |_| {
            const v = switch (p) {
                0 => delay_v,
                1 => if (i < rejects.len) rejects[i] else delay_v,
                else => if (i < errs.len) errs[i] else delay_v,
            };
            var t: Time = .{ .type = d.time_type, .high = 0, .low = 0, .real = v };
            if (d.time_type == user.vpiSimTime) {
                const ticks = run.ticksOf(.{ .type = user.vpiScaledRealTime, .high = 0, .low = 0, .real = v }, unit_of) orelse return;
                t = .{ .type = user.vpiSimTime, .high = @truncate(ticks >> 32), .low = @truncate(ticks), .real = 0 };
            }
            d.da[at] = t;
            at += 1;
        };
    }
}

/// IEEE 1364 §14.3.1 Table 14-3: a path's written delays as the twelve
/// transitions 0->1, 1->0, 0->z, z->1, 1->z, z->0, 0->x, x->1, 1->x, x->0,
/// x->z, z->x. One value is every transition; two are rise and fall; three
/// add turn-off; six are the first six; the x transitions of a six-value
/// path are the pessimistic ones, min into x and max out of it.
fn pathDelays(w: []const f64, out: *[12]f64) []const f64 {
    const t: [6]f64 = switch (w.len) {
        1 => .{ w[0], w[0], w[0], w[0], w[0], w[0] },
        2 => .{ w[0], w[1], w[0], w[0], w[1], w[1] },
        3 => .{ w[0], w[1], w[2], w[0], w[2], w[1] },
        6, 12 => w[0..6].*,
        else => return w,
    };
    out[0..6].* = t;
    if (w.len == 12) {
        out[6..12].* = w[6..12].*;
    } else {
        out[6] = @min(t[0], t[2]); // 0->x
        out[7] = @max(t[0], t[3]); // x->1
        out[8] = @min(t[1], t[4]); // 1->x
        out[9] = @max(t[1], t[5]); // x->0
        out[10] = @max(t[4], t[2]); // x->z
        out[11] = @min(t[3], t[5]); // z->x
    }
    return out[0..12];
}

/// Table 12-5's index of delay `k`'s part `p` (0 delay, 1 reject, 2 error),
/// its typical when `mtm` is 3.
fn element(k: usize, p: usize, mtm: usize, pulse: usize) usize {
    return k * mtm * pulse + p * mtm + (if (mtm == 3) @as(usize, 1) else 0);
}

/// The two time types §12.11/§12.29 take for an object's delays; false,
/// with the error recorded, for any other.
fn timeTypeOk(comptime who: []const u8, d: *const Delay) bool {
    if (d.time_type == user.vpiScaledRealTime or d.time_type == user.vpiSimTime) return true;
    status.fail("BADDELAY", who ++ ": time_type {d} is neither vpiScaledRealTime nor vpiSimTime", .{d.time_type});
    return false;
}

/// A path's or a timing check's delays, as the model holds them; false,
/// with the error recorded, when the put is refused.
fn putModelDelays(o: *const Obj, d: *const Delay) bool {
    const legal = if (o.vtype == user.vpiModPath) switch (d.no_of_delays) {
        1, 2, 3, 6, 12 => true,
        else => false,
    } else d.no_of_delays == o.delays.len;
    if (!legal) {
        status.fail("BADDELAY", "vpi_put_delays: no_of_delays {d} is not legal for this object", .{d.no_of_delays});
        return false;
    }
    if (d.time_type != user.vpiScaledRealTime or d.da == null) {
        status.fail("BADDELAY", "vpi_put_delays: a specify object's delays are put as vpiScaledRealTime, in an array", .{});
        return false;
    }
    const n: usize = @intCast(d.no_of_delays);
    const design = &session.design.?;
    const out = design.arena.allocator().alloc(f64, n) catch return noMem();
    for (out, 0..) |*v, k| v.* = part(d, k, 0).real;
    for (out) |v| if (!isDelay(v)) return notDelay(v);
    const idx = design.indexOf(o);
    // §12.29: a put with pulsere_flag sets a path's limits; one without
    // leaves them.
    if (d.pulsere_flag != 0 and o.vtype == user.vpiModPath) {
        const a = design.arena.allocator();
        const reject = a.alloc(f64, n) catch return noMem();
        const err = a.alloc(f64, n) catch return noMem();
        for (0..n) |k| {
            reject[k] = part(d, k, 1).real;
            err[k] = part(d, k, 2).real;
            if (!isDelay(reject[k])) return notDelay(reject[k]);
            if (!isDelay(err[k])) return notDelay(err[k]);
        }
        limits.put(std.heap.smp_allocator, idx, .{ .reject = reject, .err = err }) catch return noMem();
    }
    design.objects[idx].delays = out;
    return true;
}

/// The limits a put gave timing check `o`, in its module's time unit, as
/// the digital engine's (`digital.Run.tchkLimits`). Without a digital run
/// (the analog model) the model's copy is all there is.
fn putEngineLimits(obj: abi.vpiHandle, o: *const Obj, d: *const Delay) void {
    const r = run.attached() orelse return;
    const n: usize = @intCast(d.no_of_delays);
    var ticks: [2]u64 = undefined;
    if (n > ticks.len) return;
    for (ticks[0..n], 0..) |*t, k| t.* = run.ticksOf(part(d, k, 0), obj) orelse return;
    const scope = session.design.?.scopes[o.owner.get() orelse 0].engine;
    if (!r.tchkLimits(scope, o.src_tok, ticks[0..n]))
        status.fail("NODRIVER", "vpi_put_delays: the engine holds no timing check for that object", .{});
}

/// Whether `v` is a delay a put may hold: finite and not negative. The
/// engine's puts get this from `run.ticksOf`; the model's puts never call it.
fn isDelay(v: f64) bool {
    return std.math.isFinite(v) and v >= 0;
}

fn notDelay(v: f64) bool {
    status.fail("BADDELAY", "vpi_put_delays: {d} is not a delay", .{v});
    return false;
}

fn noMem() bool {
    status.fail("NOMEM", "vpi_put_delays: out of memory", .{});
    return false;
}

/// The port row `i` as a handle, for a time unit or an iteration.
fn portHandle(i: u32) abi.vpiHandle {
    return @ptrCast(&session.design.?.objects[i]);
}

/// §12.11: "For inter-module path objects, the no_of_delays value shall be 2
/// or 3": rise and fall, then turn-off, IEEE 1364 §7.14's min(rise, fall)
/// until a put of three writes it. The reject and error limits are the delay
/// itself (§14.6.1's default): no put keeps others.
fn getPathDelays(m: *const InterModPath, delay_p: ?*Delay) void {
    const d = delay_p orelse {
        status.fail("BADDELAY", "vpi_get_delays: delay_p is NULL", .{});
        return;
    };
    if (!pathStruct("vpi_get_delays", d)) return;
    if (!timeTypeOk("vpi_get_delays", d)) return;
    fill(d, &m.delays, &m.delays, &m.delays, portHandle(m.ports[0]));
}

/// §12.29, with the count §12.11 gives: 2 or 3 delays, as vpiScaledRealTime
/// in the first port's time unit, as a module path's are put. Two leave
/// turn-off IEEE 1364 §7.14's min(rise, fall). Pulse limits other than the
/// delay are refused, not dropped. A put needs the digital run, whose
/// diagnostics get W0251: no simulation applies an interconnect delay.
fn putPathDelays(m: *InterModPath, delay_p: ?*Delay) void {
    const d = delay_p orelse {
        status.fail("BADDELAY", "vpi_put_delays: delay_p is NULL", .{});
        return;
    };
    if (!pathStruct("vpi_put_delays", d)) return;
    if (d.time_type != user.vpiScaledRealTime) {
        status.fail("BADDELAY", "vpi_put_delays: an inter-module path's delays are put as vpiScaledRealTime", .{});
        return;
    }
    const r = run.attached() orelse {
        status.fail("NOENGINE", "vpi_put_delays: an inter-module path's delays are put on a digital run, and none is running", .{});
        return;
    };
    const n: usize = @intCast(d.no_of_delays);
    var got: [3]f64 = undefined;
    for (got[0..n], 0..) |*v, k| {
        v.* = part(d, k, 0).real;
        if (!isDelay(v.*)) {
            _ = notDelay(v.*);
            return;
        }
        if (d.pulsere_flag == 0) continue;
        for (1..3) |p| {
            if (part(d, k, p).real == v.*) continue;
            status.fail("NOTSUPPORTED", "vpi_put_delays: an inter-module path's pulse limits are its delay (IEEE 1364 §14.6.1); others are not held", .{});
            return;
        }
    }
    if (n < 3) got[2] = @min(got[0], got[1]);
    m.delays = got;
    const objects = session.design.?.objects;
    const from = &objects[m.ports[0]];
    if (r.bag.enabled(.W0251)) {
        const start = r.starts[@min(from.src_tok, r.starts.len - 1)];
        r.bag.add(r.stage(), .W0251, .{ .start = start, .end = start }, "vpi_put_delays: the inter-module path from `{s}` to `{s}` holds its delays for vpi_get_delays; no simulation applies an interconnect delay", .{
            from.full,
            objects[m.ports[1]].full,
        }) catch {
            status.fail("NOMEM", "vpi_put_delays: out of memory", .{});
            return;
        };
    }
}

/// The checks a get and a put share: §12.11's count and a `da` to use.
fn pathStruct(comptime who: []const u8, d: *const Delay) bool {
    if (d.no_of_delays != 2 and d.no_of_delays != 3) {
        status.fail("BADDELAY", who ++ ": an inter-module path takes 2 or 3 delays, not {d} (§12.11)", .{d.no_of_delays});
        return false;
    }
    if (d.da == null) {
        status.fail("BADDELAY", who ++ ": da is NULL", .{});
        return false;
    }
    return true;
}

test "IEEE 1364 §14.3.1 Tables 14-3/14-4: a path's delays over the twelve transitions" {
    // Order: 0->1 1->0 0->z z->1 1->z z->0, then 0->x x->1 1->x x->0 x->z
    // z->x as min into x, max out of it.
    var out: [12]f64 = undefined;
    for ([_]struct { []const f64, [12]f64 }{
        .{ &.{5}, .{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 } },
        .{ &.{ 1, 2 }, .{ 1, 2, 1, 1, 2, 2, 1, 1, 2, 2, 2, 1 } },
        .{ &.{ 1, 2, 3 }, .{ 1, 2, 3, 1, 3, 2, 1, 1, 2, 2, 3, 1 } },
        .{ &.{ 1, 2, 3, 4, 5, 6 }, .{ 1, 2, 3, 4, 5, 6, 1, 4, 2, 6, 5, 4 } },
        .{ &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 }, .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } },
    }) |case| try std.testing.expectEqualSlices(f64, &case[1], pathDelays(case[0], &out));
    // Any other count is not a path's, and passes through untouched.
    const four = [_]f64{ 1, 2, 3, 4 };
    try std.testing.expectEqualSlices(f64, &four, pathDelays(&four, &out));
}

test "Table 12-5: the element holding a delay's typical value, reject or error limit" {
    for (0..4) |k| {
        try std.testing.expectEqual(k, element(k, 0, 1, 1));
        try std.testing.expectEqual(3 * k + 1, element(k, 0, 3, 1));
        for (0..3) |p| {
            try std.testing.expectEqual(3 * k + p, element(k, p, 1, 3));
            try std.testing.expectEqual(9 * k + 3 * p + 1, element(k, p, 3, 3));
        }
    }
}
