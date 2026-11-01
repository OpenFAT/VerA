//! The system task and function registry: §12.33's digital and §12.32's
//! analog registrations -> `Systf` rows, the digital engine's view of them
//! (`hook`), the compiletf/sizetf/derivtf build pass at each call site, and
//! the per-call state a calltf reads (IEEE 1364-2005 §27.31 user data).
//! Cites: VAMS-2023 §11.6.16, §12.22, §12.32, §12.33; IEEE 1364-2005 §20.3,
//! §26.1.1, §27.13, §27.31.
//!
//! Contents:
//! - `pub const Domain = enum`
//! - `pub const Systf = struct`
//! - `pub const hook: digital.UserSystf`
//! - `pub var result: ?Int.Literal`
//! - `pub var misuse: ?[]const u8`
//! - `pub var active: ?ObjId`
//! - `pub var active_reg: ?*Systf`
//! - `pub var active_inst: usize`
//! - `pub const Pair = struct`
//! - `pub const UserKey = struct`
//! - `pub fn find(name: []const u8, domain: Domain) ?*Systf`
//! - `pub fn regOf(o: *const Obj) ?*Systf`
//! - `pub fn intAnalogNames(a: std.mem.Allocator) error`
//! - `pub fn kindOf(name: []const u8) ?digital.UserKind`
//! - `pub fn asSystf(h: abi.vpiHandle) ?*Systf`
//! - `pub fn buildCalls() void`
//! - `pub fn partialsOf(call: ObjId) []const Pair`
//! - `pub fn reset() void`
//! - `pub fn all(a: std.mem.Allocator) ![]abi.vpiHandle`
//! - `pub fn add(s: Systf) abi.vpiHandle`
//! - `pub fn vpi_register_systf(systf_data_p: ?*const SystfData) abi.vpiHandle`
//! - `pub fn vpi_register_analog_systf(systf_data_p: ?*const AnalogSystfData) abi.vpiHandle`
//! - `pub fn vpi_get_systf_info(obj: abi.vpiHandle, systf_data_p: ?*SystfData) void`
//! - `pub fn vpi_get_analog_systf_info(obj: abi.vpiHandle, systf_data_p: ?*AnalogSystfData) void`
//! - `pub fn vpi_put_userdata(obj: abi.vpiHandle, data: ?*anyopaque) c_int`
//! - `pub fn vpi_get_userdata(obj: abi.vpiHandle) ?*anyopaque`
//! - `pub fn vpi_handle_multi(obj_type: c_int, ref1: abi.vpiHandle, ref2: abi.vpiHandle, ...) callconv(.c) abi.vpiHandle`

const std = @import("std");
const Int = @import("frontend").Integer;
const digital = @import("sim").digital;
const sim = @import("sim");
const gpa = std.heap.smp_allocator;
const abi = @import("abi.zig");
const analog_call = @import("analog_call.zig");
const delays = @import("delays.zig");
const handle = @import("handle.zig");
const property = @import("property.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const trust = @import("trust.zig");
const user = @import("vpi_user.zig");
const Design = @import("Design.zig");
const schema = @import("schema.zig");
const AnalogSystfData = abi.AnalogSystfData;
const CbData = abi.CbData;
const ErrorInfo = abi.ErrorInfo;
const Obj = schema.Obj;
const ObjId = schema.ObjId;
const Partials = abi.Partials;
const SystfData = abi.SystfData;

/// A registration's domain; a name is unique within one (§12.32).
pub const Domain = enum { digital, analog };

/// One registration, owned by this file until `reset`.
pub const Systf = struct {
    domain: Domain,
    /// The registration as given, with `tfname` pointing at this record's own
    /// copy: the application's string may be a stack buffer (§12.33's own
    /// example builds the name with sprintf).
    digital: SystfData = std.mem.zeroes(SystfData),
    analog: AnalogSystfData = std.mem.zeroes(AnalogSystfData),
    name: [:0]u8,
    /// A sized function's width, once its sizetf answered (`width`).
    size: ?u32 = null,
};

/// The digital engine's view of the registrations (`digital.Options.systf`).
pub const hook: digital.UserSystf = .{ .kind = kindOf, .call = callDigital };

/// The value the running digital function call returns, which a
/// `vpi_put_value` onto the call writes (§12.30 "system function calls").
pub var result: ?Int.Literal = null;

/// A registered system task that the design calls as a function (IEEE
/// 1364-2005 §20.3), found by `buildCalls`; `run.simulate` refuses to run
/// such a design.
pub var misuse: ?[]const u8 = null;

/// The call site whose compiletf, sizetf, derivtf or calltf is running, as an
/// object index into the open design: §11.6.16 NOTE 1's
/// `vpi_handle(vpiSysTfCall, NULL)`. Null outside one.
pub var active: ?ObjId = null;

/// `active`'s registration, found once as the call starts (`regOf`). Set and
/// cleared with `active`.
pub var active_reg: ?*Systf = null;

/// The host instance whose analog calltf is running (`analog_run.Binding.call`,
/// VerA #84): the key, beside the call, of the state an application keeps
/// per call (`Design.userdata`). 0 outside one, and for every digital call:
/// the only instance VerA's own walk has.
pub var active_inst: usize = 0;

/// §12.32.2's declared partials, per call object: (derivative_of,
/// derivative_wrt), "0 = returned value, 1 = 1st arg, etc.". Kept in the
/// installed design (`Design.partials`), whose object index `call` is.
pub const Pair = struct { of: c_int, wrt: c_int };

/// IEEE 1364-2005 §27.31/§27.13 user data's key (`Design.userdata`): the
/// call's object index and the host instance whose calltf was running
/// (`active_inst`), so two instances of one device keep their own.
pub const UserKey = struct { call: ObjId, inst: usize };

/// Each digital call site, by (engine instance scope, main token).
var sites: std.AutoHashMapUnmanaged([2]u32, ObjId) = .empty;

var regs: std.ArrayList(*Systf) = .empty;
var live: std.AutoHashMapUnmanaged(usize, *Systf) = .empty;
var sizetf_calls: u32 = 0;

/// The registration of `name` in `domain`, if one was made: §11.6.16 NOTE 3's
/// "corresponding systf object" of a call to a user-defined name. Asserts
/// that the registry's two tables agree.
pub fn find(name: []const u8, domain: Domain) ?*Systf {
    std.debug.assert(regs.items.len == live.count());
    for (regs.items) |s| if (s.domain == domain and std.mem.eql(u8, s.name, name)) {
        // `checkName` admitted it: `$` and at least one more character.
        std.debug.assert(s.name.len >= 2);
        std.debug.assert(s.name[0] == '$');
        return s;
    };
    return null;
}

/// `find` for call object `o`, in its own domain. The running call's
/// registration is `active_reg`, so a query on its own handle skips the scan.
/// Asserts that `o` is a system task or function call, and that a running
/// call has its registration and an open design.
pub fn regOf(o: *const Obj) ?*Systf {
    std.debug.assert(o.vtype == user.vpiSysTaskCall or o.vtype == user.vpiSysFuncCall);
    std.debug.assert((active == null) == (active_reg == null));
    const domain: Domain = if (o.in_analog) .analog else .digital;
    if (active) |at| if (session.design.?.obj(at) == o) {
        std.debug.assert(active_reg.?.domain == domain);
        return active_reg.?;
    };
    return find(o.name, domain);
}

/// The analog system functions registered with sysfunctype vpiIntFunc: the
/// names a device is compiled to call as integers (§12.32.1,
/// `vera.Settings.int_systfs`). The slice is `a`'s; the names are this file's
/// until `reset`. Asserts that the registry's two tables agree.
pub fn intAnalogNames(a: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
    std.debug.assert(regs.items.len == live.count());
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    for (regs.items) |s| if (s.domain == .analog and s.analog.type == user.vpiAnalogSysFunc and s.analog.sysfunctype == user.vpiIntFunc)
        try out.append(a, s.name);
    std.debug.assert(out.items.len <= regs.items.len);
    return out.toOwnedSlice(a);
}

/// What the digital registration of `name` is, if one was made. Asserts
/// that a function's width is at least one bit.
pub fn kindOf(name: []const u8) ?digital.UserKind {
    const s = find(name, .digital) orelse return null;
    std.debug.assert(s.domain == .digital);
    if (s.digital.type == user.vpiSysTask) return .task;
    // `vpi_register_systf` admitted only a task or a function.
    std.debug.assert(s.digital.type == user.vpiSysFunc);
    return .{
        .func = switch (s.digital.sysfunctype) {
            user.vpiIntFunc => .{ .width = 32, .signed = true },
            user.vpiRealFunc => .{ .width = 64, .signed = true, .real = true },
            user.vpiTimeFunc => .{ .width = 64, .signed = false },
            user.vpiSizedFunc, user.vpiSizedSignedFunc => .{ .width = width(s), .signed = s.digital.sysfunctype == user.vpiSizedSignedFunc },
            else => unreachable, // else: `vpi_register_systf` admitted only the five function types
        },
    };
}

/// Returns `h` as a registration, or null unless it is a live one; never
/// dereferences a foreign pointer.
pub fn asSystf(h: abi.vpiHandle) ?*Systf {
    std.debug.assert(regs.items.len == live.count());
    const p = h orelse return null;
    const s = live.get(@intFromPtr(p)) orelse return null;
    std.debug.assert(@intFromPtr(s) == @intFromPtr(p));
    return s;
}

/// Runs the build-time callbacks: for each call site of a registered name, in
/// source order, compiletf, then derivtf (analog, §12.32.2), each with the
/// registration's user_data; and each sized function's sizetf, if the
/// engine did not already ask for its width (`width`). A host calls this
/// once, after the startup routines and before cbEndOfCompile. calltf is not
/// called here; `analog.zig` runs it per evaluation, the digital engine per
/// execution (`hook`). Asserts that no call is running when it starts, and
/// leaves none running.
pub fn buildCalls() void {
    std.debug.assert(active == null);
    std.debug.assert(active_reg == null);
    defer std.debug.assert(active == null and active_reg == null);
    const d = &(session.design orelse return);
    for (d.objects, 0..) |o, i| {
        if (o.kind != .code or (o.vtype != user.vpiSysTaskCall and o.vtype != user.vpiSysFuncCall)) continue;
        const reg = find(o.name, if (o.in_analog) .analog else .digital) orelse continue;
        // IEEE 1364-2005 §20.3: "A user task can be used in the same places a
        // Verilog HDL task can be used", which is never inside an expression.
        if (reg.domain == .digital and reg.digital.type == user.vpiSysTask and o.vtype == user.vpiSysFuncCall) {
            if (misuse == null) misuse = reg.name;
            continue;
        }
        active = .at(i);
        active_reg = reg;
        defer {
            active = null;
            active_reg = null;
        }
        switch (reg.domain) {
            .digital => {
                const ud = reg.digital.user_data;
                if (reg.digital.compiletf) |f| _ = f(ud);
                if (reg.digital.type == user.vpiSysFunc and (reg.digital.sysfunctype == user.vpiSizedFunc or reg.digital.sysfunctype == user.vpiSizedSignedFunc)) _ = width(reg);
            },
            .analog => {
                var cb: CbData = .{ .reason = 0, .cb_rtn = null, .obj = @ptrCast(d.obj(.at(i))), .time = null, .value = null, .index = 0, .user_data = reg.analog.user_data };
                if (reg.analog.compiletf) |f| _ = f(&cb);
                // §12.32.2: derivtf "returns a pointer to a t_vpi_stf_partials
                // data structure" declaring the derivative objects this call
                // has. Copied: the application's structure is its own.
                if (reg.analog.derivtf) |f| if (f(&cb)) |p| declarePartials(.at(i), p);
            },
        }
    }
}

/// The partials derivtf declared for `call` in the installed design.
/// Asserts that `call` is an object, not `none`.
pub fn partialsOf(call: ObjId) []const Pair {
    std.debug.assert(call != .none);
    const d = &(session.design orelse return &.{});
    const pairs = d.partials.get(call) orelse return &.{};
    // `declarePartials` copied a non-negative `c_int` count.
    std.debug.assert(pairs.len <= std.math.maxInt(c_int));
    return pairs;
}

/// Frees every registration; handles become invalid. The declared partials
/// and user data are the design's, freed with it (`Design.deinit`).
pub fn reset() void {
    active = null;
    active_reg = null;
    result = null;
    misuse = null;
    active_inst = 0;
    sites.clearAndFree(gpa);
    for (regs.items) |s| {
        gpa.free(s.name);
        gpa.destroy(s);
    }
    regs.clearAndFree(gpa);
    live.clearAndFree(gpa);
    std.debug.assert(regs.items.len == 0);
    std.debug.assert(live.count() == 0);
}

/// Every registration's handle, in registration order, for
/// `vpi_iterate(vpiUserSystf, NULL)`. Caller owns the slice and frees it with
/// `a`. Asserts that the registry's two tables agree.
pub fn all(a: std.mem.Allocator) ![]abi.vpiHandle {
    std.debug.assert(regs.items.len == live.count());
    const out = try a.alloc(abi.vpiHandle, regs.items.len);
    for (regs.items, out) |s, *h| h.* = @ptrCast(s);
    std.debug.assert(out.len == live.count());
    return out;
}

/// Registers `s`; null, with the error recorded, when out of memory, and
/// `s.name` is then still the caller's. Asserts that `s.name` passed
/// `checkName`: a `$` name not yet registered in `s.domain`.
pub fn add(s: Systf) abi.vpiHandle {
    std.debug.assert(s.name.len >= 2 and s.name[0] == '$');
    std.debug.assert(find(s.name, s.domain) == null);
    defer std.debug.assert(regs.items.len == live.count());
    const p = gpa.create(Systf) catch return oom();
    p.* = s;
    regs.append(gpa, p) catch {
        gpa.destroy(p);
        return oom();
    };
    live.put(gpa, @intFromPtr(p), p) catch {
        _ = regs.pop();
        gpa.destroy(p);
        return oom();
    };
    return @ptrCast(p);
}

/// §12.33 "shall register callbacks for user-defined system tasks or
/// functions". §12.33.1: type is vpiSysTask or vpiSysFunction, and for a
/// function sysfunctype is vpiIntFunc, vpiRealFunc, vpiTimeFunc or
/// vpiSizedFunc (Annex G adds vpiSizedSignedFunc).
pub export fn vpi_register_systf(systf_data_p: ?*const SystfData) abi.vpiHandle {
    status.clearError();
    const d = systf_data_p orelse {
        status.fail("BADSYSTF", "vpi_register_systf: systf_data_p is NULL", .{});
        return null;
    };
    if (d.type != user.vpiSysTask and d.type != user.vpiSysFunc) {
        status.fail("BADSYSTF", "vpi_register_systf: type {d} is neither vpiSysTask nor vpiSysFunction", .{d.type});
        return null;
    }
    if (d.type == user.vpiSysFunc and (d.sysfunctype < user.vpiIntFunc or d.sysfunctype > user.vpiSizedSignedFunc)) {
        status.fail("BADSYSTF", "vpi_register_systf: sysfunctype {d} is not a §12.33.1 function type", .{d.sysfunctype});
        return null;
    }
    const name = checkName("vpi_register_systf", d.tfname, .digital) orelse return null;
    const copy = gpa.dupeSentinel(u8, name, 0) catch return oom();
    var reg = d.*;
    reg.tfname = copy.ptr;
    const h = add(.{ .domain = .digital, .digital = reg, .name = copy });
    if (h == null) gpa.free(copy);
    std.debug.assert(h == null or asSystf(h).?.domain == .digital);
    std.debug.assert(h != null or status.vpi_chk_error(null) == user.vpiError);
    return h;
}

/// §12.32. §12.32.1: type is vpiAnalogSysTask or vpiAnalogSysFunction, and
/// for a function sysfunctype is vpiIntFunc or vpiRealFunc.
pub export fn vpi_register_analog_systf(systf_data_p: ?*const AnalogSystfData) abi.vpiHandle {
    status.clearError();
    const d = systf_data_p orelse {
        status.fail("BADSYSTF", "vpi_register_analog_systf: systf_data_p is NULL", .{});
        return null;
    };
    if (d.type != user.vpiAnalogSysTask and d.type != user.vpiAnalogSysFunc) {
        status.fail("BADSYSTF", "vpi_register_analog_systf: type {d} is neither vpiAnalogSysTask nor vpiAnalogSysFunction", .{d.type});
        return null;
    }
    if (d.type == user.vpiAnalogSysFunc and d.sysfunctype != user.vpiIntFunc and d.sysfunctype != user.vpiRealFunc) {
        status.fail("BADSYSTF", "vpi_register_analog_systf: sysfunctype {d} is neither vpiIntFunc nor vpiRealFunc", .{d.sysfunctype});
        return null;
    }
    const name = checkName("vpi_register_analog_systf", d.tfname, .analog) orelse return null;
    const copy = gpa.dupeSentinel(u8, name, 0) catch return oom();
    var reg = d.*;
    reg.tfname = copy.ptr;
    const h = add(.{ .domain = .analog, .analog = reg, .name = copy });
    if (h == null) gpa.free(copy);
    std.debug.assert(h == null or asSystf(h).?.domain == .analog);
    std.debug.assert(h != null or status.vpi_chk_error(null) == user.vpiError);
    return h;
}

/// §12.14 "shall return information about a user-defined system task or
/// function callback in an s_vpi_systf_data structure".
pub export fn vpi_get_systf_info(obj: abi.vpiHandle, systf_data_p: ?*SystfData) void {
    if (status.refused("vpi_get_systf_info")) return;
    const s = asSystf(obj) orelse {
        status.fail("BADHANDLE", "vpi_get_systf_info: that handle is not a vpiUserSystf", .{});
        return;
    };
    const out = systf_data_p orelse {
        status.fail("BADSYSTF", "vpi_get_systf_info: systf_data_p is NULL", .{});
        return;
    };
    if (s.domain != .digital) {
        status.fail("DOMAIN", "vpi_get_systf_info: `{s}` is an analog registration; vpi_get_analog_systf_info reads it", .{s.name});
        return;
    }
    std.debug.assert(!session.starting);
    out.* = s.digital;
    // The name handed out is the registration's own copy (`vpi_register_systf`).
    std.debug.assert(out.tfname == s.name.ptr);
}

/// §12.13, the analog twin of §12.14.
pub export fn vpi_get_analog_systf_info(obj: abi.vpiHandle, systf_data_p: ?*AnalogSystfData) void {
    if (status.refused("vpi_get_analog_systf_info")) return;
    const s = asSystf(obj) orelse {
        status.fail("BADHANDLE", "vpi_get_analog_systf_info: that handle is not a vpiUserSystf", .{});
        return;
    };
    const out = systf_data_p orelse {
        status.fail("BADSYSTF", "vpi_get_analog_systf_info: systf_data_p is NULL", .{});
        return;
    };
    if (s.domain != .analog) {
        status.fail("DOMAIN", "vpi_get_analog_systf_info: `{s}` is a digital registration; vpi_get_systf_info reads it", .{s.name});
        return;
    }
    std.debug.assert(!session.starting);
    out.* = s.analog;
    // The name handed out is the registration's own copy.
    std.debug.assert(out.tfname == s.name.ptr);
}

/// IEEE 1364-2005 §27.31: "The routine will return a value of 1 on success or
/// a 0 if it fails." Kept for the instance whose calltf is running
/// (`active_inst`; 0 outside one).
pub export fn vpi_put_userdata(obj: abi.vpiHandle, data: ?*anyopaque) c_int {
    if (status.refused("vpi_put_userdata")) return 0;
    const i = callIndex("vpi_put_userdata", obj) orelse return 0;
    const d = &session.design.?;
    std.debug.assert(d.obj(i).kind == .code);
    d.userdata.put(d.gpa, .{ .call = i, .inst = active_inst }, data) catch {
        status.fail("NOMEM", "vpi_put_userdata: out of memory", .{});
        return 0;
    };
    std.debug.assert(d.userdata.contains(.{ .call = i, .inst = active_inst }));
    return 1;
}

/// IEEE 1364-2005 §27.13: "If no user data had been previously associated
/// with the object or if the routine fails, the return value shall be NULL."
/// The data of the instance whose calltf is running (`active_inst`).
pub export fn vpi_get_userdata(obj: abi.vpiHandle) ?*anyopaque {
    if (status.refused("vpi_get_userdata")) return null;
    const i = callIndex("vpi_get_userdata", obj) orelse return null;
    const d = &session.design.?;
    std.debug.assert(!session.starting);
    std.debug.assert(d.obj(i).kind == .code);
    return d.userdata.get(.{ .call = i, .inst = active_inst }) orelse null;
}

/// §12.22 / §12.22.1. `vpiDerivative` names the partial of `ref1` — the
/// returned value (the call itself, §12.32.2's 0) or an argument — with
/// respect to `ref2`, an argument, of the analog call whose calltf is
/// running, and "can only be called for those derivatives allocated during
/// the derivtf phase of execution". `vpiInterModPath` names the
/// interconnect from an output port to an input port (delays.zig). Anything
/// else is refused.
pub export fn vpi_handle_multi(obj_type: c_int, ref1: abi.vpiHandle, ref2: abi.vpiHandle, ...) callconv(.c) abi.vpiHandle {
    if (status.refused("vpi_handle_multi")) return null;
    std.debug.assert(!session.starting);
    switch (obj_type) {
        user.vpiDerivative => {
            const h = analog_call.derivative(ref1, ref2);
            std.debug.assert(h == null or analog_call.asDeriv(h) != null);
            return h;
        },
        // §11.6.15's inter-module path joins two PORTS. Its handle exists
        // before any delay does: vpi_put_delays() on it is how an
        // interconnect delay is written (IEEE 1364-2005 §26.6.16).
        user.vpiInterModPath => {
            const h = delays.interModPath(ref1, ref2);
            std.debug.assert(h == null or delays.asPath(h) != null);
            return h;
        },
        else => status.fail("NOTRAVERSE", "vpi_handle_multi: {d} is not a many-to-one relationship", .{obj_type}),
    }
    return null;
}

// ---- private ----

/// The return width of a digital function registration, calling its sizetf
/// the first time: IEEE 1364-2005 §26.1.1 "Each sizetf routine shall be
/// called at most once", and "If no sizetf routine is specified, a
/// user-defined system function shall return 32 bits". Only vpiSizedFunc and
/// vpiSizedSignedFunc have one (§27.34.1).
fn width(s: *Systf) u32 {
    std.debug.assert(s.domain == .digital);
    std.debug.assert(s.digital.type == user.vpiSysFunc);
    if (s.size) |w| return w;
    const w: u32 = if (s.digital.sizetf) |f| @intCast(@max(f(s.digital.user_data), 1)) else 32;
    s.size = w;
    std.debug.assert(w >= 1);
    return w;
}

fn callDigital(_: *digital.Run, scope: u32, tok: u32, returned: ?Int.Literal) digital.Error!void {
    const d = &(session.design orelse return);
    if (sites.count() == 0) for (d.objects, 0..) |o, i| {
        if (o.kind != .code or o.in_analog or (o.vtype != user.vpiSysTaskCall and o.vtype != user.vpiSysFuncCall)) continue;
        sites.put(gpa, .{ d.scope(o.owner).engine, o.src_tok }, .at(i)) catch return error.OutOfMemory;
    };
    std.debug.assert(sites.count() <= d.objects.len);
    const at = sites.get(.{ scope, tok }) orelse return;
    std.debug.assert(!d.obj(at).in_analog);
    const s = find(d.obj(at).name, .digital) orelse return;
    const f = s.digital.calltf orelse return;
    const outer = .{ active, active_reg, result };
    defer {
        active, active_reg, result = outer;
    }
    active = at;
    active_reg = s;
    result = returned;
    _ = f(s.digital.user_data);
    // A nested call restores what it found, so this call is still the active one.
    std.debug.assert(active == at);
}

/// Copies the partials an application's derivtf returned for `call`. A
/// positive count with a NULL array is the application's error, refused
/// rather than read.
fn declarePartials(call: ObjId, p: *const Partials) void {
    std.debug.assert(call != .none);
    const d = &(session.design orelse return);
    const n: usize = @intCast(@max(p.count, 0));
    if (n != 0 and (p.derivative_of == null or p.derivative_wrt == null)) {
        status.fail("BADPARTIALS", "derivtf: {d} partials declared with a NULL derivative_of or derivative_wrt array", .{n});
        return;
    }
    const pairs = d.gpa.alloc(Pair, n) catch return;
    for (pairs, 0..) |*q, k| q.* = .{ .of = p.derivative_of[k], .wrt = p.derivative_wrt[k] };
    const g = d.partials.getOrPut(d.gpa, call) catch return d.gpa.free(pairs);
    if (g.found_existing) d.gpa.free(g.value_ptr.*);
    g.value_ptr.* = pairs;
    std.debug.assert(d.partials.get(call).?.len == n);
}

fn checkName(who: []const u8, tfname: [*c]const u8, domain: Domain) ?[]const u8 {
    std.debug.assert(who.len != 0);
    std.debug.assert(regs.items.len == live.count());
    if (tfname == null) {
        status.fail("BADNAME", "{s}: tfname is NULL", .{who});
        return null;
    }
    const name = std.mem.span(tfname);
    // §12.32/§12.33: "first character shall be `$`" — and a `$` alone names
    // nothing a source could call.
    if (name.len < 2 or name[0] != '$') {
        status.fail("BADNAME", "{s}: `{s}` does not begin with `$` and a name", .{ who, name });
        return null;
    }
    if (find(name, domain) != null) {
        status.fail("DUPSYSTF", "{s}: `{s}` is already registered in the {t} domain", .{ who, name, domain });
        return null;
    }
    return name;
}

fn oom() abi.vpiHandle {
    std.debug.assert(regs.items.len == live.count());
    status.fail("NOMEM", "systf registration: out of memory", .{});
    std.debug.assert(status.vpi_chk_error(null) == user.vpiError);
    return null;
}

/// `obj` as a system task or function call's object index, or null with the
/// error recorded.
fn callIndex(comptime who: []const u8, obj: abi.vpiHandle) ?ObjId {
    const d = &(session.design orelse {
        status.fail("NODESIGN", who ++ ": no design is open", .{});
        return null;
    });
    const o = trust.asObj(obj) orelse {
        status.fail("BADHANDLE", who ++ ": that handle is not an object", .{});
        return null;
    };
    if (o.kind != .code or (o.vtype != user.vpiSysTaskCall and o.vtype != user.vpiSysFuncCall)) {
        status.fail("NOTCALL", who ++ ": `{s}` is not a system task or function call", .{o.name});
        return null;
    }
    const i = d.idOf(o);
    std.debug.assert(i != .none);
    std.debug.assert(d.obj(i) == o);
    return i;
}

/// The tests' digital calltf: a registration needs one. Asserts that it runs
/// only as a registered call, never outside one.
fn dCall(_: [*c]u8) callconv(.c) c_int {
    std.debug.assert(active != null);
    std.debug.assert(active_reg.?.domain == .digital);
    return 0;
}

/// The tests' analog calltf; `dCall`'s analog twin.
fn aCall(cb: *CbData) callconv(.c) c_int {
    std.debug.assert(active != null);
    std.debug.assert(cb.obj != null);
    return 0;
}

/// Registers five analog vpiIntFunc names ($i1..$i5) between a real function
/// and a task: more than one growth of a list built from them.
fn registerIntAnalogs() !void {
    var names = [_][3:0]u8{ "$i1".*, "$i2".*, "$ra".*, "$i3".*, "$ta".*, "$i4".*, "$i5".* };
    const kinds = [_][2]c_int{
        .{ user.vpiAnalogSysFunc, user.vpiIntFunc },
        .{ user.vpiAnalogSysFunc, user.vpiIntFunc },
        .{ user.vpiAnalogSysFunc, user.vpiRealFunc },
        .{ user.vpiAnalogSysFunc, user.vpiIntFunc },
        .{ user.vpiAnalogSysTask, 0 },
        .{ user.vpiAnalogSysFunc, user.vpiIntFunc },
        .{ user.vpiAnalogSysFunc, user.vpiIntFunc },
    };
    const before = regs.items.len;
    comptime std.debug.assert(names.len == kinds.len);
    for (&names, kinds) |*n, k| {
        const d: AnalogSystfData = .{ .type = k[0], .sysfunctype = k[1], .tfname = n, .calltf = aCall, .compiletf = null, .sizetf = null, .derivtf = null, .user_data = null };
        if (vpi_register_analog_systf(&d) == null) return error.TestUnexpectedResult;
    }
    std.debug.assert(regs.items.len == before + names.len);
}

fn intNamesOnce(a: std.mem.Allocator) !void {
    std.debug.assert(regs.items.len != 0);
    const names = try intAnalogNames(a);
    defer a.free(names);
    std.debug.assert(names.len < regs.items.len);
}

/// The tests' sizetf, answering 0 bits. Asserts IEEE 1364-2005 §26.1.1's
/// "Each sizetf routine shall be called at most once".
fn sizetfZero(_: [*c]u8) callconv(.c) c_int {
    std.debug.assert(sizetf_calls == 0);
    sizetf_calls += 1;
    std.debug.assert(sizetf_calls == 1);
    return 0;
}

/// A design of `objects` alone, for the tests that need one installed;
/// `root.close` frees it (and `objects`, from `std.testing.allocator`).
fn testDesign(objects: []Obj) Design {
    std.debug.assert(session.design == null);
    std.debug.assert(objects.len < Design.objects_max);
    const a = std.testing.allocator;
    return .{ .gpa = a, .arena = .init(a), .objects = objects };
}

test "§12.32/§12.33: a name is unique per domain, shared across the two, and must start with $" {
    reset();
    defer reset();
    var name_buf = "$both".*;
    var ud = "digital".*;
    const dig: SystfData = .{ .type = user.vpiSysFunc, .sysfunctype = user.vpiRealFunc, .tfname = &name_buf, .calltf = dCall, .compiletf = null, .sizetf = null, .user_data = &ud };
    const d = vpi_register_systf(&dig);
    try std.testing.expect(d != null);
    // The registration copied the name: the caller's buffer may change.
    name_buf[1] = 'X';
    try std.testing.expect(vpi_register_systf(&dig) != null); // `$Xoth` is new
    name_buf[1] = 'b';
    try std.testing.expect(vpi_register_systf(&dig) == null);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));

    const ana: AnalogSystfData = .{ .type = user.vpiAnalogSysTask, .sysfunctype = 0, .tfname = &name_buf, .calltf = aCall, .compiletf = null, .sizetf = null, .derivtf = null, .user_data = null };
    const a = vpi_register_analog_systf(&ana);
    try std.testing.expect(a != null);
    try std.testing.expect(vpi_register_analog_systf(&ana) == null);
    try std.testing.expectEqual(@as(c_int, 0), trust.vpi_compare_objects(d, a));

    var info: SystfData = std.mem.zeroes(SystfData);
    vpi_get_systf_info(d, &info);
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(null));
    try std.testing.expectEqualStrings("$both", std.mem.span(info.tfname));
    try std.testing.expect(info.user_data == @as([*c]u8, &ud));
    try std.testing.expectEqual(user.vpiUserSystf, property.vpi_get(user.vpiType, d));
    // The other domain's reader refuses.
    var ainfo: AnalogSystfData = std.mem.zeroes(AnalogSystfData);
    vpi_get_analog_systf_info(d, &ainfo);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));

    var bad = "nodollar".*;
    const nd: SystfData = .{ .type = user.vpiSysTask, .sysfunctype = 0, .tfname = &bad, .calltf = dCall, .compiletf = null, .sizetf = null, .user_data = null };
    try std.testing.expect(vpi_register_systf(&nd) == null);
    // A function with no §12.33.1 return type.
    var f = "$f".*;
    const nf: SystfData = .{ .type = user.vpiSysFunc, .sysfunctype = 99, .tfname = &f, .calltf = dCall, .compiletf = null, .sizetf = null, .user_data = null };
    try std.testing.expect(vpi_register_systf(&nf) == null);
    try std.testing.expectEqual(@as(usize, 3), regs.items.len);
}

test "§11.6.16/§12.22.1: with no call active there is no call and no derivative" {
    reset();
    defer reset();
    try std.testing.expect(handle.vpi_handle(user.vpiSysTfCall, null) == null);
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(null));
    try std.testing.expect(vpi_handle_multi(user.vpiDerivative, null, null) == null);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
}

test "§12.32.1 intAnalogNames: the analog vpiIntFunc names, in a slice the caller owns" {
    reset();
    defer reset();
    try registerIntAnalogs();
    const names = try intAnalogNames(std.testing.allocator);
    defer std.testing.allocator.free(names);
    try std.testing.expectEqual(@as(usize, 5), names.len);
    for (names, [_][]const u8{ "$i1", "$i2", "$i3", "$i4", "$i5" }) |got, want| try std.testing.expectEqualStrings(want, got);
}

test "intAnalogNames frees what it built when an allocation fails" {
    reset();
    defer reset();
    try registerIntAnalogs();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, intNamesOnce, .{});
}

test "§12.33.1/IEEE 1364-2005 §26.1.1: each function type's width, sizetf called at most once" {
    reset();
    defer reset();
    var names = [_][3:0]u8{ "$fi".*, "$fr".*, "$ft".*, "$fs".*, "$fg".*, "$tk".* };
    const kinds = [_][2]c_int{
        .{ user.vpiSysFunc, user.vpiIntFunc },
        .{ user.vpiSysFunc, user.vpiRealFunc },
        .{ user.vpiSysFunc, user.vpiTimeFunc },
        .{ user.vpiSysFunc, user.vpiSizedFunc },
        .{ user.vpiSysFunc, user.vpiSizedSignedFunc },
        .{ user.vpiSysTask, 0 },
    };
    for (&names, kinds) |*n, k| {
        const d: SystfData = .{ .type = k[0], .sysfunctype = k[1], .tfname = n, .calltf = dCall, .compiletf = null, .sizetf = if (k[1] == user.vpiSizedFunc) &sizetfZero else null, .user_data = null };
        try std.testing.expect(vpi_register_systf(&d) != null);
    }
    sizetf_calls = 0;
    // A sized function whose sizetf answers 0 is 1 bit wide; one with no
    // sizetf is 32 (§26.1.1 "If no sizetf routine is specified, a
    // user-defined system function shall return 32 bits").
    for ([_]struct { []const u8, u32, bool, bool }{
        .{ "$fi", 32, true, false },
        .{ "$fr", 64, true, true },
        .{ "$ft", 64, false, false },
        .{ "$fs", 1, false, false },
        .{ "$fg", 32, true, false },
    }) |want| {
        const k = kindOf(want[0]) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(want[1], k.func.width);
        try std.testing.expectEqual(want[2], k.func.signed);
        try std.testing.expectEqual(want[3], k.func.real);
    }
    _ = kindOf("$fs");
    try std.testing.expectEqual(@as(u32, 1), sizetf_calls);
    try std.testing.expect(kindOf("$tk").? == .task);
    try std.testing.expect(kindOf("$none") == null);
}

test "§12.32/§12.33: registrations refused, and vpi_handle_multi's refusals" {
    reset();
    defer reset();
    var dollar = "$".*;
    var d: SystfData = .{ .type = user.vpiSysTask, .sysfunctype = 0, .tfname = &dollar, .calltf = dCall, .compiletf = null, .sizetf = null, .user_data = null };
    // `$` alone names nothing; a NULL name, a NULL structure, a type that is
    // neither a task nor a function, a function type past vpiSizedSignedFunc.
    try std.testing.expect(vpi_register_systf(&d) == null);
    d.tfname = null;
    try std.testing.expect(vpi_register_systf(&d) == null);
    try std.testing.expect(vpi_register_systf(null) == null);
    var good = "$ok".*;
    d.tfname = &good;
    d.type = 3;
    try std.testing.expect(vpi_register_systf(&d) == null);
    d.type = user.vpiSysFunc;
    for ([_]c_int{ 0, user.vpiSizedSignedFunc + 1 }) |t| {
        d.sysfunctype = t;
        try std.testing.expect(vpi_register_systf(&d) == null);
    }
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    // §12.32.1: a digital type, and a function that is neither int nor real.
    var an = "$an".*;
    var ad: AnalogSystfData = .{ .type = user.vpiSysTask, .sysfunctype = 0, .tfname = &an, .calltf = aCall, .compiletf = null, .sizetf = null, .derivtf = null, .user_data = null };
    try std.testing.expect(vpi_register_analog_systf(&ad) == null);
    ad.type = user.vpiAnalogSysFunc;
    ad.sysfunctype = user.vpiTimeFunc;
    try std.testing.expect(vpi_register_analog_systf(&ad) == null);
    ad.sysfunctype = user.vpiRealFunc;
    try std.testing.expect(vpi_register_analog_systf(&ad) != null);
    try std.testing.expectEqual(@as(usize, 1), regs.items.len);
    // §12.14 with no structure to fill.
    vpi_get_systf_info(@ptrCast(regs.items[0]), null);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));

    var info: ErrorInfo = undefined;
    try std.testing.expect(vpi_handle_multi(user.vpiInterModPath, null, null) == null);
    _ = status.vpi_chk_error(&info);
    try std.testing.expectEqualStrings("BADHANDLE", std.mem.span(info.code));
    try std.testing.expect(vpi_handle_multi(999, null, null) == null);
    _ = status.vpi_chk_error(&info);
    try std.testing.expectEqualStrings("NOTRAVERSE", std.mem.span(info.code));
}

test "§12.32.2: declared partials are copied, and a negative count declares none" {
    reset();
    defer reset();
    session.close();
    session.design = testDesign(&.{});
    // The design owns them: closing it frees them (the leak check).
    defer session.close();
    var of = [_]c_int{ 0, 1 };
    var wrt = [_]c_int{ 1, 2 };
    declarePartials(.at(3), &.{ .count = 2, .derivative_of = &of, .derivative_wrt = &wrt });
    // The application's arrays stay its own.
    of[0] = 9;
    try std.testing.expectEqualSlices(Pair, &.{ .{ .of = 0, .wrt = 1 }, .{ .of = 1, .wrt = 2 } }, partialsOf(.at(3)));
    declarePartials(.at(4), &.{ .count = -1, .derivative_of = null, .derivative_wrt = null });
    try std.testing.expectEqual(@as(usize, 0), partialsOf(.at(4)).len);
    try std.testing.expectEqual(@as(usize, 0), partialsOf(.at(5)).len);
}

test "IEEE 1364-2005 §27.31/§27.13: user data is per instance of the running call (VerA #84)" {
    session.close();
    const objs = try std.testing.allocator.alloc(Obj, 1);
    objs[0] = .{ .kind = .code, .owner = .none, .name = "$c", .full = "$c", .vtype = user.vpiSysFuncCall, .in_analog = true };
    session.design = testDesign(objs);
    defer session.close();
    const call: abi.vpiHandle = @ptrCast(&objs[0]);
    var zero: u8 = 0;
    var one: u8 = 1;
    // Instance 0 (outside any calltf), then instance 1's calltf running.
    try std.testing.expectEqual(@as(c_int, 1), vpi_put_userdata(call, &zero));
    active_inst = 1;
    defer active_inst = 0;
    try std.testing.expect(vpi_get_userdata(call) == null);
    try std.testing.expectEqual(@as(c_int, 1), vpi_put_userdata(call, &one));
    try std.testing.expect(vpi_get_userdata(call) == @as(?*anyopaque, &one));
    active_inst = 0;
    try std.testing.expect(vpi_get_userdata(call) == @as(?*anyopaque, &zero));
}

test "IEEE 1364-2005 §27.13/§27.31: user data needs an open design" {
    session.close();
    var x: u8 = 0;
    try std.testing.expectEqual(@as(c_int, 0), vpi_put_userdata(null, &x));
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    try std.testing.expect(vpi_get_userdata(null) == null);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
}
