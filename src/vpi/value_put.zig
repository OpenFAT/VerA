//! §12.30 vpi_put_value: a value in any Table 12-4 format -> a write through
//! the engine (now, forced, released, or scheduled with a delay), a returned
//! value of the running call, a named event's toggle, or a sequential UDP's
//! state; and the scheduled-event handles it hands out.
//! Cites: VAMS-2023 §12.30, §11.6.12 NOTE 1, §11.6.13 NOTE 2; IEEE 1364-2005
//! §20.3, §26.6.20, §27.32, C.7.
//!
//! Contents:
//! - `pub const Event = struct`
//! - `pub fn asEvent(h: abi.vpiHandle) ?*Event`
//! - `pub fn freeEvent(e: *Event) void`
//! - `pub fn scheduled(e: *const Event) bool`
//! - `pub fn reset() void`
//! - `pub fn dropScheduled() void`
//! - `pub fn vpi_put_value(obj: abi.vpiHandle, value_p: ?*Value, time_p: ?*const Time, flags: c_int) abi.vpiHandle`
//! - `pub fn toPlanes(v: *const Value, width: u32, planes: []u64) !void`

const std = @import("std");
const Int = @import("frontend").Integer;
const digital = @import("sim").digital;
const sim = @import("sim");
const exec = digital.exec;
const gpa = std.heap.smp_allocator;
const abi = @import("abi.zig");
const analog_call = @import("analog_call.zig");
const callback_fire = @import("callback_fire.zig");
const run = @import("run.zig");
const schema = @import("schema.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const systf = @import("systf.zig");
const trust = @import("trust.zig");
const value = @import("value.zig");
const value_text = @import("value_text.zig");
const user = @import("vpi_user.zig");
const Obj = schema.Obj;
const Time = abi.Time;
const Value = abi.Value;
const VecVal = abi.VecVal;

/// One event a put scheduled. The handle is `live`'s key; the record stays in
/// `events` while the event can still fire, so a later inertial or transport
/// put can cancel it after the application freed the handle (§12.30: freeing
/// the handle "shall not effect the event").
pub const Event = struct {
    handle: sim.scheduler.Handle,
    slot: u32,
    time: u64,
};

var events: std.ArrayList(*Event) = .empty;
var live: std.AutoHashMapUnmanaged(usize, *Event) = .empty;
var put_buf: std.ArrayList(u64) = .empty;

/// Returns `h` as a live scheduled-event handle, or null; never dereferences
/// a foreign pointer.
pub fn asEvent(h: abi.vpiHandle) ?*Event {
    const p = h orelse return null;
    return live.get(@intFromPtr(p));
}

/// Invalidates `e`'s handle; a still-scheduled event fires regardless.
pub fn freeEvent(e: *Event) void {
    _ = live.remove(@intFromPtr(e));
}

/// Returns whether `e` is still waiting to fire; false with no run attached.
pub fn scheduled(e: *const Event) bool {
    const r = run.attached() orelse return false;
    return r.scheduler.payloadOf(e.handle) != null;
}

/// Drops every event record and handle.
pub fn reset() void {
    for (events.items) |e| gpa.destroy(e);
    events.clearAndFree(gpa);
    live.clearAndFree(gpa);
    value.get_store.clear();
    value.cb_store.clear();
    put_buf.clearAndFree(gpa);
}

/// IEEE 1364-2005 C.7's reset "Cancels all scheduled simulation events":
/// every event a put scheduled went with the run the reset replaced, so its
/// handle reads unscheduled and names none of the new run's
/// (`run.zig`'s vpiReset).
pub fn dropScheduled() void {
    for (events.items) |e| e.handle = .{ .slot = .none, .generation = 0 };
}

/// "shall set simulation logic values on an object ... The flags argument
/// shall be used to direct the routine to use one of the following delay
/// modes". Returns a vpiSchedEvent handle when vpiReturnEvent is set AND an
/// event was scheduled; otherwise NULL, which is not in itself an error.
pub export fn vpi_put_value(obj: abi.vpiHandle, value_p: ?*Value, time_p: ?*const Time, flags: c_int) abi.vpiHandle {
    if (status.refused("vpi_put_value")) return null;
    const mode = flags & ~user.vpiReturnEvent;
    if (mode == user.vpiCancelEvent) {
        // "It shall not be an error to cancel an event which has already
        // occurred." A handle that is not a scheduled event at all is one.
        const e = asEvent(obj) orelse {
            status.fail("BADHANDLE", "vpi_put_value(vpiCancelEvent): that handle is not a vpiSchedEvent", .{});
            return null;
        };
        if (run.attached()) |r| cancel(r, e.handle);
        return null;
    }
    if (run.read_only) {
        status.fail("READONLY", "vpi_put_value: cbReadOnlySynch forbids writing values or scheduling events", .{});
        return null;
    }
    // §12.32.2 a derivative object of the running analog call.
    if (analog_call.asDeriv(obj)) |dv| {
        const pv = value_p orelse {
            status.fail("BADVALUE", "vpi_put_value: value_p is NULL", .{});
            return null;
        };
        if (pv.format != user.vpiRealVal) {
            status.fail("BADFORMAT", "vpi_put_value: a derivative is a real, put with vpiRealVal", .{});
            return null;
        }
        _ = analog_call.putDerivative(dv, pv.value.real);
        return null;
    }
    const o = trust.asObj(obj) orelse {
        status.fail("BADHANDLE", "vpi_put_value: that handle is not an object", .{});
        return null;
    };
    // IEEE 1364-2005 §26.6.20 Details b.
    if (o.automatic and (mode == user.vpiInertialDelay or mode == user.vpiTransportDelay or mode == user.vpiPureTransportDelay)) {
        status.fail("AUTOMATIC", "vpi_put_value: `{s}` is an automatic variable, and a put with a delay onto one is illegal", .{o.full});
        return null;
    }
    // §12.30 "The routine can be applied to nets, regs, variables, memory
    // words, system function calls, sequential UDPs, and schedule events" —
    // a parameter is none of those. §11.6.12 NOTE 1 makes its value the
    // elaborated constant, which a put cannot be allowed to rewrite.
    // §11.6.13 NOTE 2: "For primitives, vpi_put_value() shall only be used
    // with sequential UDP primitives." A gate is not one.
    if (o.kind == .code and (o.vtype == user.vpiGate or o.vtype == user.vpiSwitch)) {
        status.fail("NOPUT", "vpi_put_value: a gate or switch is a primitive, and only a sequential UDP takes a put", .{});
        return null;
    }
    if (o.kind == .parameter) {
        status.fail("NOPUT", "vpi_put_value: `{s}` is a parameter, which vpi_put_value does not apply to", .{o.full});
        return null;
    }
    if (o.kind == .code and o.vtype == user.vpiAttribute) {
        status.fail("NOPUT", "vpi_put_value: an attribute is a constant, which vpi_put_value does not apply to", .{});
        return null;
    }
    // IEEE 1364-2005 §20.3: the value the digital call whose calltf is
    // running returns.
    if (o.kind == .code and o.vtype == user.vpiSysFuncCall) if (systf.result) |res| if (systf.active) |at| if (&session.design.?.objects[at] == o) {
        const v = value_p orelse {
            status.fail("BADVALUE", "vpi_put_value: value_p is NULL", .{});
            return null;
        };
        toPlanes(v, res.width, res.planes) catch |e| {
            if (e == error.OutOfMemory) return oom();
            return null;
        };
        if (systf.active_reg.?.digital.sysfunctype == user.vpiRealFunc) {
            const f: f64 = if (v.format == user.vpiRealVal) v.value.real else @floatFromInt(@as(i64, @bitCast(res.planes[0])));
            @memset(res.planes, 0);
            res.planes[0] = @bitCast(f);
        }
        return null;
    };
    // §12.30 "system function calls": the returned value of the analog call
    // calltf is running for (§12.32.3 "Set returned value to held value"),
    // as a real or an integer (§12.32.1: a vpiIntFunc returns an integer,
    // which the device was compiled to take as one).
    if (o.kind == .code and o.vtype == user.vpiSysFuncCall) if (value_p) |pv| if (pv.format == user.vpiRealVal or pv.format == user.vpiIntVal) {
        const r: f64 = if (pv.format == user.vpiRealVal) pv.value.real else @floatFromInt(pv.value.integer);
        if (analog_call.putResult(o, r)) return null;
    };
    // IEEE 1364-2005 §27.32: "Calling vpi_put_value() on an object of type
    // vpiNamedEvent shall cause the named event to toggle", and value_p may
    // be NULL.
    if (o.kind == .code and o.vtype == user.vpiNamedEvent) {
        // §26.6.20: automatic objects require an activation's frame, not
        // the lexical declaration's reusable engine storage. Until VPI
        // frame handles exist, refuse rather than choosing an activation.
        if (o.automatic) {
            status.fail("AUTOMATIC", "vpi_put_value: an automatic event reference requires an activation frame, which is not implemented", .{});
            return null;
        }
        if (mode != user.vpiNoDelay) {
            status.fail("NOPUT", "vpi_put_value: `{s}` is a named event, toggled now (vpiNoDelay) and not scheduled", .{o.full});
            return null;
        }
        const r = run.attached() orelse return engineFail();
        var selected = o.slot.get();
        if (schema.coldOf(o).event_ref) |ref| {
            var scratch = std.heap.ArenaAllocator.init(gpa);
            defer scratch.deinit();
            const scope = r.scope;
            defer r.scope = scope;
            r.scope = ref.scope;
            selected = exec.address(r, scratch.allocator(), ref.expr) catch return engineFail();
        }
        if (selected) |at| exec.trigger(r, at) catch return engineFail();
        return null;
    }
    // §12.22.2 an output argument of the analog call calltf is running for,
    // as a real or an integer.
    if (value_p) |pv| if (pv.format == user.vpiRealVal or pv.format == user.vpiIntVal) {
        const r: f64 = if (pv.format == user.vpiRealVal) pv.value.real else @floatFromInt(pv.value.integer);
        if (analog_call.putArg(o, r)) return null;
    };
    if (o.kind == .code and o.vtype == user.vpiUdp) return putUdp(o, value_p, mode);
    const at = o.slot.get() orelse {
        status.fail("NOVALUE", "vpi_put_value: `{s}` has no value this process holds", .{o.full});
        return null;
    };
    // vpiReleaseFlag: "The value_p shall contain the current value of the
    // object" — written back, after the release (IEEE 1364 §9.3.2 puts a
    // net back under its drivers at once).
    if (mode == user.vpiReleaseFlag) {
        exec.release(run.attached().?, at, true) catch return engineFail();
        if (value_p) |v| value.read(o, v, &value.get_store);
        callback_fire.fireOverride(user.cbRelease, o);
        return null;
    }
    // A net's value is the resolution of its drivers (§7.9). IEEE 1364-2005
    // §27.32: a put "overrides the resolved value of the net. This value
    // shall remain in effect until one of the drivers of the net changes
    // value", which a vpiNoDelay store is: the next resolution overwrites it.
    // A delayed put would need a driver of its own, which the engine does
    // not give an application.
    //
    // ponytail: a driver re-evaluated to the value it already had resolves
    // the net again too, ending the put early.
    const r = run.attached().?;
    if ((mode == user.vpiInertialDelay or mode == user.vpiTransportDelay or mode == user.vpiPureTransportDelay) and r.netlist.slot_nets.contains(at)) {
        status.fail("NETPUT", "vpi_put_value: `{s}` is a net, which takes a put with vpiNoDelay or vpiForceFlag only", .{o.full});
        return null;
    }
    const v = value_p orelse {
        status.fail("BADVALUE", "vpi_put_value: value_p is NULL", .{});
        return null;
    };
    // IEEE 1364-2005 §27.32: "It shall be illegal to specify the format of
    // the value as vpiStringVal when putting a value to a real variable".
    if (v.format == user.vpiStringVal and r.decls.reals.contains(at)) {
        status.fail("BADFORMAT", "vpi_put_value: vpiStringVal onto the real `{s}` is illegal", .{o.full});
        return null;
    }
    const dest = r.values[at];
    put_buf.resize(gpa, dest.planes.len) catch return oom();
    toPlanes(v, dest.width, put_buf.items) catch |e| {
        if (e == error.OutOfMemory) return oom();
        return null;
    };
    // A real holds IEEE 754 bits: a vpiRealVal as given, any other format as
    // the signed integer it wrote (IEEE 1364 §4.8.2 integer-to-real).
    if (r.decls.reals.contains(at)) {
        const f: f64 = if (v.format == user.vpiRealVal) v.value.real else @floatFromInt(@as(i64, @bitCast(put_buf.items[0])));
        @memset(put_buf.items, 0);
        put_buf.items[0] = @bitCast(f);
    }
    const lit: Int.Literal = .{ .width = dest.width, .sized = true, .signed = dest.signed, .planes = put_buf.items };

    switch (mode) {
        // "time_p shall be ignored": a force is immediate.
        user.vpiForceFlag => {
            exec.forceValue(r, at, lit.planes) catch return engineFail();
            callback_fire.fireOverride(user.cbForce, o);
            return null;
        },
        user.vpiNoDelay => {
            exec.store(r, at, lit.planes) catch return engineFail();
            return null;
        },
        user.vpiInertialDelay, user.vpiTransportDelay, user.vpiPureTransportDelay => {
            const t = time_p orelse {
                status.fail("BADTIME", "vpi_put_value: a delayed put needs time_p", .{});
                return null;
            };
            const delay = run.ticksOf(t.*, obj) orelse return null;
            const when = run.now() +| delay;
            prune();
            for (events.items) |e| {
                if (e.slot != at or !scheduled(e)) continue;
                // vpiInertialDelay: "All scheduled events on the object shall
                // be removed". vpiTransportDelay: "All events on the object
                // scheduled for times later than this event shall be removed".
                if (mode == user.vpiInertialDelay or (mode == user.vpiTransportDelay and e.time > when)) cancel(r, e.handle);
            }
            const h = exec.enqueue(r, .{ .write = .{ .target = at, .value = lit } }, delay, false) catch return engineFail();
            const e = gpa.create(Event) catch return oom();
            e.* = .{ .handle = h, .slot = at, .time = when };
            events.append(gpa, e) catch {
                gpa.destroy(e);
                return oom();
            };
            if (flags & user.vpiReturnEvent == 0) return null;
            live.put(gpa, @intFromPtr(e), e) catch return oom();
            return @ptrCast(e);
        },
        else => {
            status.fail("BADFLAGS", "vpi_put_value: {d} is not a §12.30 delay mode", .{mode});
            return null;
        },
    }
}

/// `v` as `width` bits in `planes` (value words, then unknown words).
pub fn toPlanes(v: *const Value, width: u32, planes: []u64) !void {
    @memset(planes, 0);
    const n = planes.len / 2;
    const val = planes[0..n];
    const unk = planes[n..];
    switch (v.format) {
        user.vpiIntVal, user.vpiRealVal, user.vpiTimeVal => {
            const x: u64 = switch (v.format) {
                user.vpiIntVal => @bitCast(@as(i64, v.value.integer)),
                user.vpiRealVal => @bitCast(value_text.roundAway(v.value.real)),
                else => blk: {
                    const t = v.value.time orelse return badPut("vpiTimeVal with a NULL time");
                    break :blk (@as(u64, t.high) << 32) | t.low;
                },
            };
            // Sign-extend across the whole object: a negative int or real
            // written to a wide reg is still negative.
            const fill: u64 = if (v.format != user.vpiTimeVal and @as(i64, @bitCast(x)) < 0) ~@as(u64, 0) else 0;
            for (val, 0..) |*w, k| w.* = if (k == 0) x else fill;
        },
        user.vpiScalarVal => {
            const bit: Int.Bit = switch (v.value.scalar) {
                user.vpi0, user.vpiL => .zero,
                user.vpi1, user.vpiH => .one,
                user.vpiZ => .z,
                user.vpiX => .x,
                else => return badPut("vpiScalarVal outside vpi0/vpi1/vpiX/vpiZ/vpiH/vpiL"),
            };
            value_text.orField(val, 0, @backingInt(bit) & 1, 1, width);
            value_text.orField(unk, 0, @backingInt(bit) >> 1, 1, width);
        },
        user.vpiVectorVal => {
            const vec = v.value.vector orelse return badPut("vpiVectorVal with a NULL vector");
            const words = (width + 31) / 32;
            for (0..words) |k| {
                const a: u64 = @as(u32, @bitCast(vec[k].aval));
                const b: u64 = @as(u32, @bitCast(vec[k].bval));
                const shift: u6 = if (k % 2 == 0) 0 else 32;
                val[k / 2] |= a << shift;
                unk[k / 2] |= b << shift;
            }
        },
        user.vpiBinStrVal, user.vpiOctStrVal, user.vpiHexStrVal => {
            const s = std.mem.span(v.value.str orelse return badPut("a string format with a NULL str"));
            const g: u32 = switch (v.format) {
                user.vpiBinStrVal => 1,
                user.vpiOctStrVal => 3,
                else => 4,
            };
            const m = value_text.lowMask(g);
            // Every character is checked, those past the width included.
            for (0..s.len) |k| {
                const c = s[s.len - 1 - k];
                const d: u64, const u: u64 = switch (c) {
                    'x', 'X' => .{ m, m },
                    'z', 'Z', '?' => .{ 0, m },
                    else => .{ std.fmt.charToDigit(c, @as(u8, 1) << @intCast(g)) catch return badPut("a digit outside the format's radix"), 0 },
                };
                value_text.orField(val, k * g, d, g, width);
                value_text.orField(unk, k * g, u, g, width);
            }
        },
        user.vpiDecStrVal => {
            const s = std.mem.span(v.value.str orelse return badPut("vpiDecStrVal with a NULL str"));
            const neg = s.len > 0 and s[0] == '-';
            for (s[@intFromBool(neg)..]) |c| {
                const d = std.fmt.charToDigit(c, 10) catch return badPut("a non-decimal digit in vpiDecStrVal");
                // val = val * 10 + d, across the words.
                var carry: u128 = d;
                for (val) |*w| {
                    const p = @as(u128, w.*) * 10 + carry;
                    w.* = @truncate(p);
                    carry = p >> 64;
                }
            }
            if (neg) value_text.negate(val);
        },
        user.vpiStringVal => {
            const s = std.mem.span(v.value.str orelse return badPut("vpiStringVal with a NULL str"));
            // The LAST character is the least significant byte.
            for (0..s.len) |k| value_text.orField(val, k * 8, s[s.len - 1 - k], 8, width);
        },
        else => return badPut("a value format vpi_put_value does not read"),
    }
    // Nothing past the object's width.
    if (width % 64 != 0) {
        const m = value_text.lowMask(width % 64);
        val[n - 1] &= m;
        unk[n - 1] &= m;
    }
}

// ---- private ----

/// Drop the records of events that fired or were cancelled and whose handle
/// the application no longer holds.
fn prune() void {
    var i: usize = 0;
    while (i < events.items.len) {
        const e = events.items[i];
        if (!scheduled(e) and !live.contains(@intFromPtr(e))) {
            gpa.destroy(events.swapRemove(i));
        } else i += 1;
    }
}

fn cancel(r: *digital.Run, h: sim.scheduler.Handle) void {
    const row = r.scheduler.payloadOf(h) orelse return;
    _ = r.scheduler.cancel(h) catch return;
    r.rows.free.append(r.arena, row) catch {};
}

/// §12.30 a put onto a UDP instance: "Sequential UDPs shall be set to the
/// indicated value with no delay regardless of any delay on the primitive
/// instance", so the instance's own delay is skipped. A combinational UDP
/// holds no state to set (§11.6.13 NOTE 2 limits puts to sequential ones),
/// an instance array has one state per element, and a put delayed by time_p
/// would need an event of its own: each is refused.
fn putUdp(o: *const Obj, value_p: ?*const Value, mode: c_int) abi.vpiHandle {
    const r = run.attached() orelse return engineFail();
    const scope = session.design.?.scopes[o.owner.get().?].engine;
    var found: ?u32 = null;
    for (r.netlist.drivers, 0..) |drv, k| if (drv.tok == o.src_tok and drv.scope == scope and drv.source == .udp) {
        if (found != null) {
            status.fail("NOPUT", "vpi_put_value: `{s}` is an instance array; put onto one element", .{o.full});
            return null;
        }
        found = @intCast(k);
    };
    const at = found orelse return engineFail();
    if (!r.netlist.drivers[at].source.udp.sequential) {
        status.fail("NOPUT", "vpi_put_value: `{s}` is a combinational UDP, and only a sequential UDP takes a put", .{o.full});
        return null;
    }
    if (mode != user.vpiNoDelay) {
        status.fail("NOPUT", "vpi_put_value: a sequential UDP is set with vpiNoDelay; a delayed put onto one is not implemented", .{});
        return null;
    }
    const v = value_p orelse {
        status.fail("BADVALUE", "vpi_put_value: value_p is NULL", .{});
        return null;
    };
    var planes: [2]u64 = undefined;
    toPlanes(v, 1, &planes) catch |e| {
        if (e == error.OutOfMemory) return oom();
        return null;
    };
    // §8.1.4: a UDP's output is 0, 1 or x; z is not one of them.
    const bit: Int.Bit = switch ((planes[0] & 1) | (planes[1] & 1) << 1) {
        0 => .zero,
        1 => .one,
        else => .x,
    };
    r.vpiPutUdp(at, bit) catch return engineFail();
    return null;
}

fn oom() abi.vpiHandle {
    status.fail("NOMEM", "vpi_put_value: out of memory", .{});
    return null;
}

fn engineFail() abi.vpiHandle {
    status.fail("ENGINE", "vpi_put_value: the digital engine refused the write", .{});
    return null;
}

fn badPut(why: []const u8) error{BadValue} {
    status.fail("BADVALUE", "vpi_put_value: {s}", .{why});
    return error.BadValue;
}

test "§12.30 toPlanes: an int sign-extends across the object, a time does not" {
    var v: Value = std.mem.zeroes(Value);
    var planes: [4]u64 = undefined;
    v.format = user.vpiIntVal;
    v.value.integer = -2;
    try toPlanes(&v, 72, &planes);
    try std.testing.expectEqualSlices(u64, &.{ std.math.maxInt(u64) - 1, 0xff, 0, 0 }, &planes);
    var t: Time = .{ .type = user.vpiSimTime, .high = 0xffff_ffff, .low = 0, .real = 0 };
    v.format = user.vpiTimeVal;
    v.value.time = &t;
    try toPlanes(&v, 72, &planes);
    try std.testing.expectEqualSlices(u64, &.{ 0xffff_ffff_0000_0000, 0, 0, 0 }, &planes);
    // A real rounds away from zero first: -2.5 is -3, 0xfd in 8 bits.
    v.format = user.vpiRealVal;
    v.value.real = -2.5;
    try toPlanes(&v, 8, planes[0..2]);
    try std.testing.expectEqualSlices(u64, &.{ 0xfd, 0 }, planes[0..2]);
}

test "§12.30 toPlanes: scalars, strings, and the values it refuses" {
    var v: Value = std.mem.zeroes(Value);
    var one_bit: [2]u64 = undefined;
    v.format = user.vpiScalarVal;
    // vpiH and vpiL are their strengthless 1 and 0.
    for ([_]struct { c_int, [2]u64 }{
        .{ user.vpi0, .{ 0, 0 } },
        .{ user.vpi1, .{ 1, 0 } },
        .{ user.vpiZ, .{ 0, 1 } },
        .{ user.vpiX, .{ 1, 1 } },
        .{ user.vpiH, .{ 1, 0 } },
        .{ user.vpiL, .{ 0, 0 } },
    }) |case| {
        v.value.scalar = case[0];
        try toPlanes(&v, 1, &one_bit);
        try std.testing.expectEqual(case[1], one_bit);
    }
    v.value.scalar = 9;
    try std.testing.expectError(error.BadValue, toPlanes(&v, 1, &one_bit));
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));

    // vpiStringVal: the last character is the least significant byte, and
    // what does not fit the width is dropped.
    var planes: [2]u64 = undefined;
    v.format = user.vpiStringVal;
    v.value.str = @constCast("AB");
    try toPlanes(&v, 16, &planes);
    try std.testing.expectEqual([2]u64{ 0x4142, 0 }, planes);
    try toPlanes(&v, 8, &planes);
    try std.testing.expectEqual([2]u64{ 0x42, 0 }, planes);

    for ([_]struct { c_int, [:0]const u8 }{
        .{ user.vpiBinStrVal, "102" },
        .{ user.vpiOctStrVal, "8" },
        .{ user.vpiHexStrVal, "g" },
        .{ user.vpiDecStrVal, "12a" },
    }) |case| {
        v.format = case[0];
        v.value.str = @constCast(case[1].ptr);
        try std.testing.expectError(error.BadValue, toPlanes(&v, 8, &planes));
    }
    v.format = user.vpiHexStrVal;
    v.value.str = null;
    try std.testing.expectError(error.BadValue, toPlanes(&v, 8, &planes));
    v.format = 99;
    try std.testing.expectError(error.BadValue, toPlanes(&v, 8, &planes));
}

test "§12.30 toPlanes: a vector's words past the width are dropped; a decimal string of any width reads back" {
    var v: Value = std.mem.zeroes(Value);
    var planes: [2 * 18]u64 = undefined;
    // 40 bits: two vecvals, the second's bits past bit 7 cleared.
    var vec = [2]VecVal{ .{ .aval = -1, .bval = 0x0f }, .{ .aval = -1, .bval = -1 } };
    v.format = user.vpiVectorVal;
    v.value.vector = &vec;
    try toPlanes(&v, 40, planes[0..2]);
    try std.testing.expectEqualSlices(u64, &.{ 0xff_ffff_ffff, 0xff_0000_000f }, planes[0..2]);
    // Decimal through 1100 bits, past `decimal`'s stack words: the put's
    // planes print back as the same digits, a negative one with its sign.
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for ([_][:0]const u8{ "0", "123456789012345678901234567890123456789", "-98765432109876543210" }) |text| {
        v.format = user.vpiDecStrVal;
        v.value.str = @constCast(text.ptr);
        try toPlanes(&v, 1100, &planes);
        out.clearRetainingCapacity();
        try value_text.radixString(&out, .{ .width = 1100, .val = planes[0..18], .unk = planes[18..], .signed = text[0] == '-' }, user.vpiDecStrVal);
        try std.testing.expectEqualStrings(text, out.items);
    }
    // An empty decimal string is 0; a lone sign is too.
    for ([_][:0]const u8{ "", "-" }) |text| {
        v.value.str = @constCast(text.ptr);
        try toPlanes(&v, 8, planes[0..2]);
        try std.testing.expectEqualSlices(u64, &.{ 0, 0 }, planes[0..2]);
    }
}
