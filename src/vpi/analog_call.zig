//! An analog system task or function call while it runs: its arguments,
//! returned value, output arguments (§12.22.2) and derivative objects
//! (§12.22.1, §12.32.2), as the routines read and put them.
//! Cites: VAMS-2023 §12.22.1, §12.22.2, §12.30, §12.32.2, §12.32.3.
//!
//! Contents:
//! - `pub const Out = struct`
//! - `pub fn Out.val(o: Out) []f64`
//! - `pub fn Out.part(o: Out) []f64`
//! - `pub const OutKey = struct`
//! - `pub const Active = struct`
//! - `pub var active_call: ?*Active`
//! - `pub const Deriv = struct`
//! - `pub fn deviceCall(ctx: ?*anyopaque, inst: usize, k: usize, args: [*]const f64, n: usize, partials: [*]f64) callconv(.c) f64`
//! - `pub fn deviceOut(ctx: ?*anyopaque, inst: usize, k: usize, j: usize, args: [*]const f64, n: usize, partials: [*]f64) callconv(.c) f64`
//! - `pub fn oom() f64`
//! - `pub fn putArg(o: *const Obj, v: f64) bool`
//! - `pub fn argValue(o: *const Obj) ?f64`
//! - `pub fn putResult(o: *const Obj, v: f64) bool`
//! - `pub fn asDeriv(h: abi.vpiHandle) ?*Deriv`
//! - `pub fn derivative(ref1: abi.vpiHandle, ref2: abi.vpiHandle) abi.vpiHandle`
//! - `pub fn putDerivative(dv: *Deriv, v: f64) bool`

const std = @import("std");
const gpa = std.heap.smp_allocator;
const abi = @import("abi.zig");
const analog = @import("analog.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const systf = @import("systf.zig");
const trust = @import("trust.zig");
const value = @import("value.zig");
const user = @import("vpi_user.zig");
const Binding = @import("Binding.zig");
const schema = @import("schema.zig");
const Obj = schema.Obj;
const ObjId = schema.ObjId;

/// §12.22.2 one call's output arguments, as its latest calltf left them:
/// `val[j - 1]` and row j - 1 of `part` (d(argument j)/d(argument i)) for each
/// argument j with `put[j - 1]`, which calltf put a value or a partial on.
/// `Binding.output` answers from it. `buf` holds `val` then `part`; `put` is
/// its own allocation. Both are `gpa`'s, freed at `Binding.detach`.
pub const Out = struct {
    buf: []f64,
    put: []bool,
    n: usize,
    pub fn val(o: Out) []f64 {
        return o.buf[0..o.n];
    }
    pub fn part(o: Out) []f64 {
        return o.buf[o.n..];
    }
};

/// Which output record: device call k, run for host instance `inst`.
pub const OutKey = struct { k: usize, inst: usize };

/// The call whose §12.32 calltf is running: its binding, object, device
/// call index and host instance.
pub const Active = struct { b: *Binding, obj: ObjId, k: usize, inst: usize, result: f64, partials: []f64 };

pub var active_call: ?*Active = null;

/// One derivative handle: the call, and (of, wrt) in §12.32.2's numbering.
/// Each is its own allocation, so a handle stays put while more are handed
/// out; a handle is ours iff its binding's `derivs` lists it. There are at
/// most as many as derivtf declared (call, of, wrt) triples, since a
/// repeated request returns the first handle.
pub const Deriv = struct { call: ObjId, of: c_int, wrt: c_int, value: f64 = 0 };

/// `HostCall`: `Binding.call` for a library behind a C ABI. `ctx` is the
/// binding `attach` handed the library (`Lib.systf`).
pub fn deviceCall(ctx: ?*anyopaque, inst: usize, k: usize, args: [*]const f64, n: usize, partials: [*]f64) callconv(.c) f64 {
    const b: *Binding = @ptrCast(@alignCast(ctx.?));
    return b.call(inst, k, args[0..n], partials[0..n]);
}

/// `HostOut`: `Binding.output` for a library behind a C ABI.
pub fn deviceOut(ctx: ?*anyopaque, inst: usize, k: usize, j: usize, args: [*]const f64, n: usize, partials: [*]f64) callconv(.c) f64 {
    const b: *const Binding = @ptrCast(@alignCast(ctx.?));
    return b.output(inst, k, j, args[0..n], partials[0..n]);
}

pub fn oom() f64 {
    status.fail("NOMEM", "out of memory for a call's output arguments", .{});
    return 0;
}

/// §12.30 onto argument j of the call calltf is running for: the value the
/// device reads back as that variable (§12.22.2). False when `o` is no
/// argument of that call, so the ordinary put rules apply; an argument the
/// device does not read back is refused (NOPUT).
pub fn putArg(o: *const Obj, v: f64) bool {
    const st = active_call orelse return false;
    const j = argPosition(st.obj, o) orelse return false;
    const out = outputOf(st, j, "vpi_put_value") orelse return true;
    out.val()[j - 1] = v;
    out.put[j - 1] = true;
    return true;
}

/// §12.16 for an analog call argument that has no value of its own: its
/// value at the latest evaluation.
pub fn argValue(o: *const Obj) ?f64 {
    const b = analog.bound() orelse return null;
    const d = &(session.design orelse return null);
    return b.arg_values.get(d.idOf(o));
}

/// §12.30 onto the call calltf is running for: its returned value. False
/// when `o` is not that call, so the ordinary put rules apply.
pub fn putResult(o: *const Obj, v: f64) bool {
    const st = active_call orelse return false;
    const d = &session.design.?;
    if (o != d.obj(st.obj)) return false;
    st.result = v;
    return true;
}

/// Returns `h` as a derivative handle of the binding the routines answer
/// for, or null unless it is one handed out; never dereferences a foreign
/// pointer.
pub fn asDeriv(h: abi.vpiHandle) ?*Deriv {
    return derivOf(analog.bound() orelse return null, h);
}

/// §12.22.1 `vpi_handle_multi(vpiDerivative, ref1, ref2)`: the partial of
/// the running call's result or argument `ref1` with respect to argument
/// `ref2`, if derivtf declared it (§12.32.2). Null, with an error, outside a
/// calltf or for an undeclared pair, and NOMEM when no memory is left.
pub fn derivative(ref1: abi.vpiHandle, ref2: abi.vpiHandle) abi.vpiHandle {
    const st = active_call orelse {
        status.fail("NOCALL", "vpi_handle_multi(vpiDerivative): no analog system task or function call is running", .{});
        return null;
    };
    const of = position(st.obj, ref1) orelse {
        status.fail("NOTARG", "vpi_handle_multi(vpiDerivative): the first handle is neither the call nor one of its arguments", .{});
        return null;
    };
    const wrt = position(st.obj, ref2) orelse 0;
    if (wrt == 0) {
        status.fail("NOTARG", "vpi_handle_multi(vpiDerivative): a derivative is taken with respect to an argument", .{});
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
    status.fail("UNDECLARED", "vpi_handle_multi(vpiDerivative): d({d})/d({d}) was not declared by derivtf", .{ of, wrt });
    return null;
}

/// §12.32.2 "values can then be contributed to the derivative using the
/// vpi_put_value function in the calltf call back": a partial of the returned
/// value, or of an argument the device reads back (§12.22.2); any other
/// argument's is refused (NOPUT).
pub fn putDerivative(dv: *Deriv, v: f64) bool {
    const st = active_call orelse {
        status.fail("NOCALL", "vpi_put_value: a derivative takes a value during its call's calltf", .{});
        return false;
    };
    if (dv.call != st.obj) {
        status.fail("NOCALL", "vpi_put_value: that derivative belongs to another call", .{});
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

// ---- private ----

/// The running call's output record when argument j is one the device reads
/// back, else null with a NOPUT error.
fn outputOf(st: *const Active, j: usize, routine: []const u8) ?Out {
    if (j > 64 or (st.b.call_outs[st.k] >> @intCast(j - 1)) & 1 == 0) {
        status.fail("NOPUT", "{s}: argument {d} of `{s}` is not a variable the design reads back after the call (§12.22.2)", .{ routine, j, session.design.?.obj(st.obj).name });
        return null;
    }
    return st.b.outs.get(.{ .k = st.k, .inst = st.inst });
}

/// Which argument (1-based) of call `obj` the object `o` is, or null.
fn argPosition(obj: ObjId, o: *const Obj) ?usize {
    const d = &session.design.?;
    for (d.obj(obj).lists) |l| if (l.tag == user.vpiArgument) {
        for (l.items, 0..) |a, j| if (d.obj(a) == o) return j + 1;
    };
    return null;
}

// ponytail: a linear scan over the handed-out handles; a hash set if a
// design declares thousands of partials and `vpi_get_value` measures hot.
fn derivOf(b: *const Binding, h: abi.vpiHandle) ?*Deriv {
    const p = h orelse return null;
    for (b.derivs.items) |dv| if (@as(*anyopaque, @ptrCast(dv)) == p) return dv;
    return null;
}

/// Which §12.32.2 position `h` is on call `obj`: 0 for the call itself (the
/// returned value), 1.. for its arguments, null for neither.
fn position(obj: ObjId, h: abi.vpiHandle) ?c_int {
    const d = &session.design.?;
    const o = trust.asObj(h) orelse return null;
    if (o == d.obj(obj)) return 0;
    return @intCast(argPosition(obj, o) orelse return null);
}

fn noMem() abi.vpiHandle {
    status.fail("NOMEM", "vpi_handle_multi(vpiDerivative): out of memory", .{});
    return null;
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
        dv.* = .{ .call = .at(k), .of = 0, .wrt = 1 };
        b.derivs.appendAssumeCapacity(dv);
        if (first == null) first = dv;
    }
    try std.testing.expect(derivOf(&b, @ptrCast(first.?)) == first.?);
    try std.testing.expectEqual(ObjId.at(199), derivOf(&b, @ptrCast(b.derivs.items[199])).?.call);
    try std.testing.expect(derivOf(&b, @ptrFromInt(@intFromPtr(first.?) + 1)) == null);
    var other: Deriv = .{ .call = .at(0), .of = 0, .wrt = 1 };
    try std.testing.expect(derivOf(&b, @ptrCast(&other)) == null);
    // Another library's binding handed out none of them.
    const empty: Binding = .{};
    try std.testing.expect(derivOf(&empty, @ptrCast(first.?)) == null);
}
