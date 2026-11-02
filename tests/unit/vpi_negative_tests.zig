//! The call side of the VPI negative-input table (`tests/vpi_negative/`
//! holds the entry points a C application calls): what an application's
//! derivtf returns and what a device library hands back reach VerA as input,
//! and each refusal is a `vpi_chk_error` code and a 0 or empty answer, never
//! a crash. Driven in process because no C application can reach the library
//! side: VerA builds and loads the device itself. Cites IEEE 1364-2005 §27.4,
//! VAMS-2023 §12.32.2.

const std = @import("std");
const vpi = @import("vpi");
const abi = vpi.abi;
const user = vpi.user;
const OneCall = vpi.analog.OneCall;

var null_partials: abi.Partials = .{ .count = 2, .derivative_of = null, .derivative_wrt = null };

/// The hops the library is handed at `attach`, kept to call back with.
var hop_call: ?vpi.analog.HostCall = null;
var hop_out: ?vpi.analog.HostOut = null;

// ---- private ----

/// The code of the error `vpi_chk_error` reports, or null when none.
fn errorCode() ?[]const u8 {
    var info: abi.ErrorInfo = undefined;
    if (vpi.status.vpi_chk_error(&info) == 0) return null;
    return std.mem.span(info.code);
}

fn register(derivtf: ?*const fn (*abi.CbData) callconv(.c) ?*abi.Partials) !void {
    var tf = "$c".*;
    const reg: abi.AnalogSystfData = .{ .type = user.vpiAnalogSysFunc, .sysfunctype = user.vpiRealFunc, .tfname = &tf, .calltf = null, .compiletf = null, .sizetf = null, .derivtf = derivtf, .user_data = null };
    try std.testing.expect(vpi.systf.vpi_register_analog_systf(&reg) != null);
}

fn nullPartials(_: *abi.CbData) callconv(.c) ?*abi.Partials {
    return &null_partials;
}

fn keepHops(_: ?*anyopaque, call: ?vpi.analog.HostCall, out: ?vpi.analog.HostOut) callconv(.c) void {
    hop_call = call;
    hop_out = out;
}

fn plainName(_: usize, len: *usize) callconv(.c) [*]const u8 {
    len.* = 1;
    return "c";
}

test "§12.32.2 derivtf: a positive count with NULL arrays is BADPARTIALS and declares none" {
    vpi.session.close();
    defer vpi.session.close();
    vpi.session.design = try OneCall.design("A.$c");
    try register(nullPartials);
    vpi.systf.buildCalls();
    try std.testing.expectEqualStrings("BADPARTIALS", errorCode() orelse "");
    try std.testing.expectEqual(@as(usize, 0), vpi.systf.partialsOf(.at(0)).len);
}

test "a device library calling back without its ctx is NOCTX and gets 0" {
    vpi.session.close();
    defer vpi.session.close();
    vpi.session.design = try OneCall.design("A.$c");
    try register(null);
    var l = OneCall.lib;
    l.systf = keepHops;
    var b: vpi.Binding = .{};
    defer b.detach();
    try b.attach(l, null);
    const args = [1]f64{0.5};
    var partials: [1]f64 = undefined;
    try std.testing.expectEqual(@as(f64, 0), hop_call.?(null, 0, 0, &args, 1, &partials));
    try std.testing.expectEqualStrings("NOCTX", errorCode() orelse "");
    vpi.status.clearError();
    try std.testing.expectEqual(@as(f64, 0), hop_out.?(null, 0, 0, 1, &args, 1, &partials));
    try std.testing.expectEqualStrings("NOCTX", errorCode() orelse "");
}

test "a library call name that is not a `$` name binds to no call, refused when called" {
    vpi.session.close();
    defer vpi.session.close();
    vpi.session.design = try OneCall.design("A.$c");
    try register(null);
    var l = OneCall.lib;
    l.systf_name = plainName;
    var b: vpi.Binding = .{};
    defer b.detach();
    try b.attach(l, null);
    const args = [1]f64{0.5};
    var partials: [1]f64 = undefined;
    try std.testing.expectEqual(@as(f64, 0), b.call(0, 0, &args, &partials));
    try std.testing.expect(errorCode() != null);
}
