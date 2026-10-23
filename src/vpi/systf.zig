//! The user system task/function registry: §12.33 vpi_register_systf, §12.32
//! vpi_register_analog_systf, §12.14/§12.13 their info routines, and §12.22
//! vpi_handle_multi. Registrations -> vpiUserSystf handles, build-time
//! compiletf/sizetf/derivtf calls (`buildCalls`), the lookup `analog.zig`
//! uses to run an analog calltf per device evaluation, and `hook`, through
//! which the digital engine runs a digital calltf (IEEE 1364-2005 §20.3,
//! §26.1.3).

const std = @import("std");
const digital = @import("sim").digital;
const Int = @import("frontend").Integer;
const root = @import("root.zig");
const property = @import("property.zig");
const handle = @import("handle.zig");
const callback = @import("callback.zig");
const code = @import("code.zig");

const vpiHandle = root.vpiHandle;

// §12.33.1 type / sysfunctype, Annex G numbering. VAMS spells the function
// type vpiSysFunction; Annex G spells it vpiSysFunc. Same number.
pub const vpiSysTask: c_int = 1;
pub const vpiSysFunc: c_int = 2;
pub const vpiIntFunc: c_int = 1;
pub const vpiRealFunc: c_int = 2;
pub const vpiTimeFunc: c_int = 3;
pub const vpiSizedFunc: c_int = 4;
pub const vpiSizedSignedFunc: c_int = 5;

// §12.32.1. Verilog-AMS names these and numbers none of them; the numbers are
// VerA's, shared with p03_vpi_analog.h.
pub const vpiAnalogSysTask: c_int = 740;
pub const vpiAnalogSysFunc: c_int = 741;
pub const vpiDerivative: c_int = 730;

pub const vpiUserSystf: c_int = 67;
pub const vpiSysTfCall: c_int = 85;
pub const vpiInterModPath: c_int = 26;

/// Figure 12-19, laid out for C.
pub const SystfData = extern struct {
    type: c_int,
    sysfunctype: c_int,
    tfname: [*c]u8,
    calltf: ?*const fn ([*c]u8) callconv(.c) c_int,
    compiletf: ?*const fn ([*c]u8) callconv(.c) c_int,
    sizetf: ?*const fn ([*c]u8) callconv(.c) c_int,
    user_data: [*c]u8,
};

/// §12.32.2 `t_vpi_stf_partials`, what derivtf returns: `count` pairs of
/// (derivative_of, derivative_wrt), 0 = returned value, 1 = first argument.
pub const Partials = extern struct {
    count: c_int,
    derivative_of: [*c]c_int,
    derivative_wrt: [*c]c_int,
};

/// Figure 12-18, laid out for C.
pub const AnalogSystfData = extern struct {
    type: c_int,
    sysfunctype: c_int,
    tfname: [*c]u8,
    calltf: ?*const fn (*callback.CbData) callconv(.c) c_int,
    compiletf: ?*const fn (*callback.CbData) callconv(.c) c_int,
    sizetf: ?*const fn (*callback.CbData) callconv(.c) c_int,
    derivtf: ?*const fn (*callback.CbData) callconv(.c) ?*Partials,
    user_data: [*c]u8,
};

/// A registration's domain; a name is unique within one (§12.32).
pub const Domain = enum { digital, analog };

/// §11.6.16's call properties. Annex G numbers vpiSysFuncType as vpiFuncType.
pub const vpiUserDefn: c_int = 45;
pub const vpiSysFuncType: c_int = 44;

/// The registration of `name` in `domain`, if one was made: §11.6.16 NOTE 3's
/// "corresponding systf object" of a call to a user-defined name.
pub fn find(name: []const u8, domain: Domain) ?*Systf {
    for (regs.items) |s| if (s.domain == domain and std.mem.eql(u8, s.name, name)) return s;
    return null;
}

/// `find` for call object `o`, in its own domain. The running call's
/// registration is `active_reg`, so a query on its own handle skips the scan.
pub fn regOf(o: *const root.Obj) ?*Systf {
    if (active) |at| if (&root.design.?.objects[at] == o) return active_reg.?;
    return find(o.name, if (o.in_analog) .analog else .digital);
}

/// The analog system functions registered with sysfunctype vpiIntFunc: the
/// names a device is compiled to call as integers (§12.32.1,
/// `vera.Options.int_systfs`). The slice is `a`'s; the names are this file's
/// until `reset`.
pub fn intAnalogNames(a: std.mem.Allocator) error{OutOfMemory}![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(a);
    for (regs.items) |s| if (s.domain == .analog and s.analog.type == vpiAnalogSysFunc and s.analog.sysfunctype == vpiIntFunc)
        try out.append(a, s.name);
    return out.toOwnedSlice(a);
}

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

/// The return width of a digital function registration, calling its sizetf
/// the first time: IEEE 1364-2005 §26.1.1 "Each sizetf routine shall be
/// called at most once", and "If no sizetf routine is specified, a
/// user-defined system function shall return 32 bits". Only vpiSizedFunc and
/// vpiSizedSignedFunc have one (§27.34.1).
fn width(s: *Systf) u32 {
    if (s.size) |w| return w;
    const w: u32 = if (s.digital.sizetf) |f| @intCast(@max(f(s.digital.user_data), 1)) else 32;
    s.size = w;
    return w;
}

/// The digital engine's view of the registrations (`digital.Options.systf`).
pub const hook: digital.UserSystf = .{ .kind = kindOf, .call = callDigital };

/// What the digital registration of `name` is, if one was made.
pub fn kindOf(name: []const u8) ?digital.UserKind {
    const s = find(name, .digital) orelse return null;
    if (s.digital.type == vpiSysTask) return .task;
    return .{
        .func = switch (s.digital.sysfunctype) {
            vpiIntFunc => .{ .width = 32, .signed = true },
            vpiRealFunc => .{ .width = 64, .signed = true, .real = true },
            vpiTimeFunc => .{ .width = 64, .signed = false },
            vpiSizedFunc, vpiSizedSignedFunc => .{ .width = width(s), .signed = s.digital.sysfunctype == vpiSizedSignedFunc },
            else => unreachable, // else: `vpi_register_systf` admitted only the five function types
        },
    };
}

/// The value the running digital function call returns, which a
/// `vpi_put_value` onto the call writes (§12.30 "system function calls").
pub var result: ?Int.Literal = null;

/// Each digital call site, by (engine instance scope, main token).
var sites: std.AutoHashMapUnmanaged([2]u32, u32) = .empty;

fn callDigital(_: *digital.Run, scope: u32, tok: u32, returned: ?Int.Literal) digital.Error!void {
    const d = &(root.design orelse return);
    if (sites.count() == 0) for (d.objects, 0..) |o, i| {
        if (o.kind != .code or o.in_analog or (o.vtype != code.vpiSysTaskCall and o.vtype != code.vpiSysFuncCall)) continue;
        sites.put(gpa, .{ d.scopes[o.owner.get().?].engine, o.src_tok }, @intCast(i)) catch return error.OutOfMemory;
    };
    const at = sites.get(.{ scope, tok }) orelse return;
    const s = find(d.objects[at].name, .digital) orelse return;
    const f = s.digital.calltf orelse return;
    const outer = .{ active, active_reg, result };
    defer {
        active, active_reg, result = outer;
    }
    active = at;
    active_reg = s;
    result = returned;
    _ = f(s.digital.user_data);
}

const gpa = std.heap.smp_allocator;
var regs: std.ArrayList(*Systf) = .empty;
var live: std.AutoHashMapUnmanaged(usize, *Systf) = .empty;

/// Returns `h` as a registration, or null unless it is a live one; never
/// dereferences a foreign pointer.
pub fn asSystf(h: vpiHandle) ?*Systf {
    const p = h orelse return null;
    return live.get(@intFromPtr(p));
}

/// A registered system task that the design calls as a function (IEEE
/// 1364-2005 §20.3), found by `buildCalls`; `run.simulate` refuses to run
/// such a design.
pub var misuse: ?[]const u8 = null;

/// The call site whose compiletf, sizetf, derivtf or calltf is running, as an
/// object index into the open design: §11.6.16 NOTE 1's
/// `vpi_handle(vpiSysTfCall, NULL)`. Null outside one.
pub var active: ?u32 = null;
/// `active`'s registration, found once as the call starts (`regOf`). Set and
/// cleared with `active`.
pub var active_reg: ?*Systf = null;

/// The host instance whose analog calltf is running (`analog_run.Binding.call`,
/// VerA #84): the key, beside the call, of the state an application keeps
/// per call (`Design.userdata`). 0 outside one, and for every digital call:
/// the only instance VerA's own walk has.
pub var active_inst: usize = 0;

/// Runs the build-time callbacks: for each call site of a registered name, in
/// source order, compiletf, then derivtf (analog, §12.32.2), each with the
/// registration's user_data; and each sized function's sizetf, if the
/// engine did not already ask for its width (`width`). A host calls this
/// once, after the startup routines and before cbEndOfCompile. calltf is not
/// called here; `analog.zig` runs it per evaluation, the digital engine per
/// execution (`hook`).
pub fn buildCalls() void {
    const d = &(root.design orelse return);
    for (d.objects, 0..) |o, i| {
        if (o.kind != .code or (o.vtype != code.vpiSysTaskCall and o.vtype != code.vpiSysFuncCall)) continue;
        const reg = find(o.name, if (o.in_analog) .analog else .digital) orelse continue;
        // IEEE 1364-2005 §20.3: "A user task can be used in the same places a
        // Verilog HDL task can be used", which is never inside an expression.
        if (reg.domain == .digital and reg.digital.type == vpiSysTask and o.vtype == code.vpiSysFuncCall) {
            if (misuse == null) misuse = reg.name;
            continue;
        }
        active = @intCast(i);
        active_reg = reg;
        defer {
            active = null;
            active_reg = null;
        }
        switch (reg.domain) {
            .digital => {
                const ud = reg.digital.user_data;
                if (reg.digital.compiletf) |f| _ = f(ud);
                if (reg.digital.type == vpiSysFunc and (reg.digital.sysfunctype == vpiSizedFunc or reg.digital.sysfunctype == vpiSizedSignedFunc)) _ = width(reg);
            },
            .analog => {
                var cb: callback.CbData = .{ .reason = 0, .cb_rtn = null, .obj = @ptrCast(&d.objects[i]), .time = null, .value = null, .index = 0, .user_data = reg.analog.user_data };
                if (reg.analog.compiletf) |f| _ = f(&cb);
                // §12.32.2: derivtf "returns a pointer to a t_vpi_stf_partials
                // data structure" declaring the derivative objects this call
                // has. Copied: the application's structure is its own.
                if (reg.analog.derivtf) |f| if (f(&cb)) |p| declarePartials(@intCast(i), p);
            },
        }
    }
}

/// §12.32.2's declared partials, per call object: (derivative_of,
/// derivative_wrt), "0 = returned value, 1 = 1st arg, etc.". Kept in the
/// installed design (`Design.partials`), whose object index `call` is.
pub const Pair = struct { of: c_int, wrt: c_int };

fn declarePartials(call: u32, p: *const Partials) void {
    const d = &(root.design orelse return);
    const n: usize = @intCast(@max(p.count, 0));
    const pairs = d.gpa.alloc(Pair, n) catch return;
    for (pairs, 0..) |*q, k| q.* = .{ .of = p.derivative_of[k], .wrt = p.derivative_wrt[k] };
    const g = d.partials.getOrPut(d.gpa, call) catch return d.gpa.free(pairs);
    if (g.found_existing) d.gpa.free(g.value_ptr.*);
    g.value_ptr.* = pairs;
}

/// The partials derivtf declared for `call` in the installed design.
pub fn partialsOf(call: u32) []const Pair {
    const d = &(root.design orelse return &.{});
    return d.partials.get(call) orelse &.{};
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
}

/// Every registration's handle, in registration order, for
/// `vpi_iterate(vpiUserSystf, NULL)`. Caller owns the slice and frees it with
/// `a`.
pub fn all(a: std.mem.Allocator) ![]vpiHandle {
    const out = try a.alloc(vpiHandle, regs.items.len);
    for (regs.items, out) |s, *h| h.* = @ptrCast(s);
    return out;
}

fn checkName(who: []const u8, tfname: [*c]const u8, domain: Domain) ?[]const u8 {
    if (tfname == null) {
        root.fail("BADNAME", "{s}: tfname is NULL", .{who});
        return null;
    }
    const name = std.mem.span(tfname);
    // §12.32/§12.33: "first character shall be `$`" — and a `$` alone names
    // nothing a source could call.
    if (name.len < 2 or name[0] != '$') {
        root.fail("BADNAME", "{s}: `{s}` does not begin with `$` and a name", .{ who, name });
        return null;
    }
    if (find(name, domain) != null) {
        root.fail("DUPSYSTF", "{s}: `{s}` is already registered in the {t} domain", .{ who, name, domain });
        return null;
    }
    return name;
}

/// Registers `s`; null, with the error recorded, when out of memory, and
/// `s.name` is then still the caller's.
fn add(s: Systf) vpiHandle {
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

fn oom() vpiHandle {
    root.fail("NOMEM", "systf registration: out of memory", .{});
    return null;
}

/// §12.33 "shall register callbacks for user-defined system tasks or
/// functions". §12.33.1: type is vpiSysTask or vpiSysFunction, and for a
/// function sysfunctype is vpiIntFunc, vpiRealFunc, vpiTimeFunc or
/// vpiSizedFunc (Annex G adds vpiSizedSignedFunc).
pub export fn vpi_register_systf(systf_data_p: ?*const SystfData) vpiHandle {
    root.clearError();
    const d = systf_data_p orelse {
        root.fail("BADSYSTF", "vpi_register_systf: systf_data_p is NULL", .{});
        return null;
    };
    if (d.type != vpiSysTask and d.type != vpiSysFunc) {
        root.fail("BADSYSTF", "vpi_register_systf: type {d} is neither vpiSysTask nor vpiSysFunction", .{d.type});
        return null;
    }
    if (d.type == vpiSysFunc and (d.sysfunctype < vpiIntFunc or d.sysfunctype > vpiSizedSignedFunc)) {
        root.fail("BADSYSTF", "vpi_register_systf: sysfunctype {d} is not a §12.33.1 function type", .{d.sysfunctype});
        return null;
    }
    const name = checkName("vpi_register_systf", d.tfname, .digital) orelse return null;
    const copy = gpa.dupeSentinel(u8, name, 0) catch return oom();
    var reg = d.*;
    reg.tfname = copy.ptr;
    const h = add(.{ .domain = .digital, .digital = reg, .name = copy });
    if (h == null) gpa.free(copy);
    return h;
}

/// §12.32. §12.32.1: type is vpiAnalogSysTask or vpiAnalogSysFunction, and
/// for a function sysfunctype is vpiIntFunc or vpiRealFunc.
pub export fn vpi_register_analog_systf(systf_data_p: ?*const AnalogSystfData) vpiHandle {
    root.clearError();
    const d = systf_data_p orelse {
        root.fail("BADSYSTF", "vpi_register_analog_systf: systf_data_p is NULL", .{});
        return null;
    };
    if (d.type != vpiAnalogSysTask and d.type != vpiAnalogSysFunc) {
        root.fail("BADSYSTF", "vpi_register_analog_systf: type {d} is neither vpiAnalogSysTask nor vpiAnalogSysFunction", .{d.type});
        return null;
    }
    if (d.type == vpiAnalogSysFunc and d.sysfunctype != vpiIntFunc and d.sysfunctype != vpiRealFunc) {
        root.fail("BADSYSTF", "vpi_register_analog_systf: sysfunctype {d} is neither vpiIntFunc nor vpiRealFunc", .{d.sysfunctype});
        return null;
    }
    const name = checkName("vpi_register_analog_systf", d.tfname, .analog) orelse return null;
    const copy = gpa.dupeSentinel(u8, name, 0) catch return oom();
    var reg = d.*;
    reg.tfname = copy.ptr;
    const h = add(.{ .domain = .analog, .analog = reg, .name = copy });
    if (h == null) gpa.free(copy);
    return h;
}

/// §12.14 "shall return information about a user-defined system task or
/// function callback in an s_vpi_systf_data structure".
pub export fn vpi_get_systf_info(obj: vpiHandle, systf_data_p: ?*SystfData) void {
    if (root.refused("vpi_get_systf_info")) return;
    const s = asSystf(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_systf_info: that handle is not a vpiUserSystf", .{});
        return;
    };
    const out = systf_data_p orelse {
        root.fail("BADSYSTF", "vpi_get_systf_info: systf_data_p is NULL", .{});
        return;
    };
    if (s.domain != .digital) {
        root.fail("DOMAIN", "vpi_get_systf_info: `{s}` is an analog registration; vpi_get_analog_systf_info reads it", .{s.name});
        return;
    }
    out.* = s.digital;
}

/// §12.13, the analog twin of §12.14.
pub export fn vpi_get_analog_systf_info(obj: vpiHandle, systf_data_p: ?*AnalogSystfData) void {
    if (root.refused("vpi_get_analog_systf_info")) return;
    const s = asSystf(obj) orelse {
        root.fail("BADHANDLE", "vpi_get_analog_systf_info: that handle is not a vpiUserSystf", .{});
        return;
    };
    const out = systf_data_p orelse {
        root.fail("BADSYSTF", "vpi_get_analog_systf_info: systf_data_p is NULL", .{});
        return;
    };
    if (s.domain != .analog) {
        root.fail("DOMAIN", "vpi_get_analog_systf_info: `{s}` is a digital registration; vpi_get_systf_info reads it", .{s.name});
        return;
    }
    out.* = s.analog;
}

/// IEEE 1364-2005 §27.31/§27.13 user data's key (`Design.userdata`): the
/// call's object index and the host instance whose calltf was running
/// (`active_inst`), so two instances of one device keep their own.
pub const UserKey = struct { call: u32, inst: usize };

/// `obj` as a system task or function call's object index, or null with the
/// error recorded.
fn callIndex(comptime who: []const u8, obj: vpiHandle) ?u32 {
    const d = &(root.design orelse {
        root.fail("NODESIGN", who ++ ": no design is open", .{});
        return null;
    });
    const o = root.asObj(obj) orelse {
        root.fail("BADHANDLE", who ++ ": that handle is not an object", .{});
        return null;
    };
    if (o.kind != .code or (o.vtype != code.vpiSysTaskCall and o.vtype != code.vpiSysFuncCall)) {
        root.fail("NOTCALL", who ++ ": `{s}` is not a system task or function call", .{o.name});
        return null;
    }
    return d.indexOf(o);
}

/// IEEE 1364-2005 §27.31: "The routine will return a value of 1 on success or
/// a 0 if it fails." Kept for the instance whose calltf is running
/// (`active_inst`; 0 outside one).
pub export fn vpi_put_userdata(obj: vpiHandle, data: ?*anyopaque) c_int {
    if (root.refused("vpi_put_userdata")) return 0;
    const i = callIndex("vpi_put_userdata", obj) orelse return 0;
    const d = &root.design.?;
    d.userdata.put(d.gpa, .{ .call = i, .inst = active_inst }, data) catch {
        root.fail("NOMEM", "vpi_put_userdata: out of memory", .{});
        return 0;
    };
    return 1;
}

/// IEEE 1364-2005 §27.13: "If no user data had been previously associated
/// with the object or if the routine fails, the return value shall be NULL."
/// The data of the instance whose calltf is running (`active_inst`).
pub export fn vpi_get_userdata(obj: vpiHandle) ?*anyopaque {
    if (root.refused("vpi_get_userdata")) return null;
    const i = callIndex("vpi_get_userdata", obj) orelse return null;
    return root.design.?.userdata.get(.{ .call = i, .inst = active_inst }) orelse null;
}

/// §12.22 / §12.22.1. `vpiDerivative` names the partial of `ref1` — the
/// returned value (the call itself, §12.32.2's 0) or an argument — with
/// respect to `ref2`, an argument, of the analog call whose calltf is
/// running, and "can only be called for those derivatives allocated during
/// the derivtf phase of execution". `vpiInterModPath` names the
/// interconnect from an output port to an input port (delays.zig). Anything
/// else is refused.
pub export fn vpi_handle_multi(obj_type: c_int, ref1: vpiHandle, ref2: vpiHandle, ...) callconv(.c) vpiHandle {
    if (root.refused("vpi_handle_multi")) return null;
    switch (obj_type) {
        vpiDerivative => return @import("analog.zig").derivative(ref1, ref2),
        // §11.6.15's inter-module path joins two PORTS. Its handle exists
        // before any delay does: vpi_put_delays() on it is how an
        // interconnect delay is written (IEEE 1364-2005 §26.6.16).
        vpiInterModPath => return @import("delays.zig").interModPath(ref1, ref2),
        else => root.fail("NOTRAVERSE", "vpi_handle_multi: {d} is not a many-to-one relationship", .{obj_type}),
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn dCall(_: [*c]u8) callconv(.c) c_int {
    return 0;
}
fn aCall(_: *callback.CbData) callconv(.c) c_int {
    return 0;
}

test "§12.32/§12.33: a name is unique per domain, shared across the two, and must start with $" {
    reset();
    defer reset();
    var name_buf = "$both".*;
    var ud = "digital".*;
    const dig: SystfData = .{ .type = vpiSysFunc, .sysfunctype = vpiRealFunc, .tfname = &name_buf, .calltf = dCall, .compiletf = null, .sizetf = null, .user_data = &ud };
    const d = vpi_register_systf(&dig);
    try std.testing.expect(d != null);
    // The registration copied the name: the caller's buffer may change.
    name_buf[1] = 'X';
    try std.testing.expect(vpi_register_systf(&dig) != null); // `$Xoth` is new
    name_buf[1] = 'b';
    try std.testing.expect(vpi_register_systf(&dig) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));

    const ana: AnalogSystfData = .{ .type = vpiAnalogSysTask, .sysfunctype = 0, .tfname = &name_buf, .calltf = aCall, .compiletf = null, .sizetf = null, .derivtf = null, .user_data = null };
    const a = vpi_register_analog_systf(&ana);
    try std.testing.expect(a != null);
    try std.testing.expect(vpi_register_analog_systf(&ana) == null);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_compare_objects(d, a));

    var info: SystfData = std.mem.zeroes(SystfData);
    vpi_get_systf_info(d, &info);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expectEqualStrings("$both", std.mem.span(info.tfname));
    try std.testing.expect(info.user_data == @as([*c]u8, &ud));
    try std.testing.expectEqual(vpiUserSystf, property.vpi_get(root.vpiType, d));
    // The other domain's reader refuses.
    var ainfo: AnalogSystfData = std.mem.zeroes(AnalogSystfData);
    vpi_get_analog_systf_info(d, &ainfo);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));

    var bad = "nodollar".*;
    const nd: SystfData = .{ .type = vpiSysTask, .sysfunctype = 0, .tfname = &bad, .calltf = dCall, .compiletf = null, .sizetf = null, .user_data = null };
    try std.testing.expect(vpi_register_systf(&nd) == null);
    // A function with no §12.33.1 return type.
    var f = "$f".*;
    const nf: SystfData = .{ .type = vpiSysFunc, .sysfunctype = 99, .tfname = &f, .calltf = dCall, .compiletf = null, .sizetf = null, .user_data = null };
    try std.testing.expect(vpi_register_systf(&nf) == null);
    try std.testing.expectEqual(@as(usize, 3), regs.items.len);
}

test "§11.6.16/§12.22.1: with no call active there is no call and no derivative" {
    reset();
    defer reset();
    try std.testing.expect(handle.vpi_handle(vpiSysTfCall, null) == null);
    try std.testing.expectEqual(@as(c_int, 0), root.vpi_chk_error(null));
    try std.testing.expect(vpi_handle_multi(vpiDerivative, null, null) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}

/// Registers five analog vpiIntFunc names ($i1..$i5) between a real function
/// and a task: more than one growth of a list built from them.
fn registerIntAnalogs() !void {
    var names = [_][3:0]u8{ "$i1".*, "$i2".*, "$ra".*, "$i3".*, "$ta".*, "$i4".*, "$i5".* };
    const kinds = [_][2]c_int{
        .{ vpiAnalogSysFunc, vpiIntFunc },
        .{ vpiAnalogSysFunc, vpiIntFunc },
        .{ vpiAnalogSysFunc, vpiRealFunc },
        .{ vpiAnalogSysFunc, vpiIntFunc },
        .{ vpiAnalogSysTask, 0 },
        .{ vpiAnalogSysFunc, vpiIntFunc },
        .{ vpiAnalogSysFunc, vpiIntFunc },
    };
    for (&names, kinds) |*n, k| {
        const d: AnalogSystfData = .{ .type = k[0], .sysfunctype = k[1], .tfname = n, .calltf = aCall, .compiletf = null, .sizetf = null, .derivtf = null, .user_data = null };
        if (vpi_register_analog_systf(&d) == null) return error.TestUnexpectedResult;
    }
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

fn intNamesOnce(a: std.mem.Allocator) !void {
    const names = try intAnalogNames(a);
    a.free(names);
}

test "intAnalogNames frees what it built when an allocation fails" {
    reset();
    defer reset();
    try registerIntAnalogs();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, intNamesOnce, .{});
}

var sizetf_calls: u32 = 0;
fn sizetfZero(_: [*c]u8) callconv(.c) c_int {
    sizetf_calls += 1;
    return 0;
}

test "§12.33.1/IEEE 1364-2005 §26.1.1: each function type's width, sizetf called at most once" {
    reset();
    defer reset();
    var names = [_][3:0]u8{ "$fi".*, "$fr".*, "$ft".*, "$fs".*, "$fg".*, "$tk".* };
    const kinds = [_][2]c_int{
        .{ vpiSysFunc, vpiIntFunc },
        .{ vpiSysFunc, vpiRealFunc },
        .{ vpiSysFunc, vpiTimeFunc },
        .{ vpiSysFunc, vpiSizedFunc },
        .{ vpiSysFunc, vpiSizedSignedFunc },
        .{ vpiSysTask, 0 },
    };
    for (&names, kinds) |*n, k| {
        const d: SystfData = .{ .type = k[0], .sysfunctype = k[1], .tfname = n, .calltf = dCall, .compiletf = null, .sizetf = if (k[1] == vpiSizedFunc) &sizetfZero else null, .user_data = null };
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
    var d: SystfData = .{ .type = vpiSysTask, .sysfunctype = 0, .tfname = &dollar, .calltf = dCall, .compiletf = null, .sizetf = null, .user_data = null };
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
    d.type = vpiSysFunc;
    for ([_]c_int{ 0, vpiSizedSignedFunc + 1 }) |t| {
        d.sysfunctype = t;
        try std.testing.expect(vpi_register_systf(&d) == null);
    }
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    // §12.32.1: a digital type, and a function that is neither int nor real.
    var an = "$an".*;
    var ad: AnalogSystfData = .{ .type = vpiSysTask, .sysfunctype = 0, .tfname = &an, .calltf = aCall, .compiletf = null, .sizetf = null, .derivtf = null, .user_data = null };
    try std.testing.expect(vpi_register_analog_systf(&ad) == null);
    ad.type = vpiAnalogSysFunc;
    ad.sysfunctype = vpiTimeFunc;
    try std.testing.expect(vpi_register_analog_systf(&ad) == null);
    ad.sysfunctype = vpiRealFunc;
    try std.testing.expect(vpi_register_analog_systf(&ad) != null);
    try std.testing.expectEqual(@as(usize, 1), regs.items.len);
    // §12.14 with no structure to fill.
    vpi_get_systf_info(@ptrCast(regs.items[0]), null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));

    var info: root.ErrorInfo = undefined;
    try std.testing.expect(vpi_handle_multi(vpiInterModPath, null, null) == null);
    _ = root.vpi_chk_error(&info);
    try std.testing.expectEqualStrings("BADHANDLE", std.mem.span(info.code));
    try std.testing.expect(vpi_handle_multi(999, null, null) == null);
    _ = root.vpi_chk_error(&info);
    try std.testing.expectEqualStrings("NOTRAVERSE", std.mem.span(info.code));
}

/// A design of `objects` alone, for the tests that need one installed;
/// `root.close` frees it (and `objects`, from `std.testing.allocator`).
fn testDesign(objects: []root.Obj) root.Design {
    const a = std.testing.allocator;
    return .{ .gpa = a, .arena = .init(a), .objects = objects };
}

test "§12.32.2: declared partials are copied, and a negative count declares none" {
    reset();
    defer reset();
    root.close();
    root.design = testDesign(&.{});
    // The design owns them: closing it frees them (the leak check).
    defer root.close();
    var of = [_]c_int{ 0, 1 };
    var wrt = [_]c_int{ 1, 2 };
    declarePartials(3, &.{ .count = 2, .derivative_of = &of, .derivative_wrt = &wrt });
    // The application's arrays stay its own.
    of[0] = 9;
    try std.testing.expectEqualSlices(Pair, &.{ .{ .of = 0, .wrt = 1 }, .{ .of = 1, .wrt = 2 } }, partialsOf(3));
    declarePartials(4, &.{ .count = -1, .derivative_of = null, .derivative_wrt = null });
    try std.testing.expectEqual(@as(usize, 0), partialsOf(4).len);
    try std.testing.expectEqual(@as(usize, 0), partialsOf(5).len);
}

test "IEEE 1364-2005 §27.31/§27.13: user data is per instance of the running call (VerA #84)" {
    root.close();
    const objs = try std.testing.allocator.alloc(root.Obj, 1);
    objs[0] = .{ .kind = .code, .owner = .none, .name = "$c", .full = "$c", .vtype = code.vpiSysFuncCall, .in_analog = true };
    root.design = testDesign(objs);
    defer root.close();
    const call: vpiHandle = @ptrCast(&objs[0]);
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
    root.close();
    var x: u8 = 0;
    try std.testing.expectEqual(@as(c_int, 0), vpi_put_userdata(null, &x));
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
    try std.testing.expect(vpi_get_userdata(null) == null);
    try std.testing.expectEqual(root.vpiError, root.vpi_chk_error(null));
}
