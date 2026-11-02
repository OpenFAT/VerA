//! vpi_user.h's structs and handle type, laid out for C: what crosses the
//! ABI in each direction. No code.
//! Cites: IEEE 1364-2005 §27 Figures 27-1..27-11 (s_vpi_error_info,
//! s_vpi_vlog_info, s_vpi_time, s_vpi_value, s_vpi_vecval, s_vpi_strengthval,
//! s_cb_data, s_vpi_delay, s_vpi_systf_data); VAMS-2023 §12.10 (s_vpi_analog_value)
//! and §12.32 (s_vpi_analog_systf_data); §12.33.2 (vlog_startup_routines).
//!
//! Contents:
//! - `pub const AnalogValue = extern struct`
//! - `pub const Time = extern struct`
//! - `pub const VecVal = extern struct`
//! - `pub const StrengthVal = extern struct`
//! - `pub const Value = extern struct`
//! - `pub const Routine = *const fn (*CbData) callconv(.c) c_int`
//! - `pub const CbData = extern struct`
//! - `pub const Delay = extern struct`
//! - `pub const vpiHandle = ?*anyopaque`
//! - `pub const ErrorInfo = extern struct`
//! - `pub const StartupFn = *const fn () callconv(.c) void`
//! - `pub const VlogInfo = extern struct`
//! - `pub const SystfData = extern struct`
//! - `pub const Partials = extern struct`
//! - `pub const AnalogSystfData = extern struct`

const std = @import("std");
const callback = @import("callback.zig");
const delays = @import("delays.zig");
const session = @import("session.zig");
const status = @import("status.zig");
const user = @import("vpi_user.zig");

/// Figure 12-3, laid out for C.
pub const AnalogValue = extern struct {
    format: c_int,
    real: extern union { str: [*c]u8, real: f64, misc: [*c]u8 },
    imaginary: extern union { str: [*c]u8, real: f64, misc: [*c]u8 },
};

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
pub const Routine = *const fn (*CbData) callconv(.c) c_int;

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

/// Figure 12-4, laid out as Annex G does (its `bool`s are PLI_INT32).
pub const Delay = extern struct {
    da: [*c]Time,
    no_of_delays: c_int,
    time_type: c_int,
    mtm_flag: c_int,
    append_flag: c_int,
    pulsere_flag: c_int,
};

/// §11.3.1. Opaque to the application: a pointer into `Design.objects`, or to a
/// live `Iter`, and validated as one before it is followed.
pub const vpiHandle = ?*anyopaque;

/// Figure 12-1 `s_vpi_error_info`, laid out for C.
pub const ErrorInfo = extern struct {
    state: c_int,
    level: c_int,
    message: [*c]u8,
    product: [*c]u8,
    code: [*c]u8,
    file: [*c]u8,
    line: c_int,
};

/// One `vlog_startup_routines` entry.
pub const StartupFn = *const fn () callconv(.c) void;

/// Figure 12-12 `s_vpi_vlog_info`, laid out for C.
pub const VlogInfo = extern struct {
    argc: c_int,
    argv: [*c][*c]u8,
    product: [*c]u8,
    version: [*c]u8,
};

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
    calltf: ?*const fn (*CbData) callconv(.c) c_int,
    compiletf: ?*const fn (*CbData) callconv(.c) c_int,
    sizetf: ?*const fn (*CbData) callconv(.c) c_int,
    derivtf: ?*const fn (*CbData) callconv(.c) ?*Partials,
    user_data: [*c]u8,
};

test "§12.34/§12.6: removal invalidates the handle, and info round-trips" {
    callback.reset();
    defer callback.reset();
    var tag = "u".*;
    var t: Time = .{ .type = user.vpiSimTime, .high = 0, .low = 0, .real = 0 };
    const reg: CbData = .{ .reason = user.cbEndOfCompile, .cb_rtn = callback.onCompile, .obj = null, .time = &t, .value = null, .index = 3, .user_data = &tag };
    const h = callback.vpi_register_cb(&reg);
    try std.testing.expect(h != null);
    // §12.31.1: the registration is COPIED — changing the caller's struct
    // afterwards changes nothing.
    t.type = user.vpiScaledRealTime;

    var it: Time = .{ .type = user.vpiSuppressTime, .high = 9, .low = 9, .real = 9 };
    var iv: Value = std.mem.zeroes(Value);
    iv.format = 99;
    var info: CbData = .{ .reason = 0, .cb_rtn = null, .obj = null, .time = &it, .value = &iv, .index = 0, .user_data = null };
    callback.vpi_get_cb_info(h, &info);
    try std.testing.expectEqual(@as(c_int, 0), status.vpi_chk_error(null));
    try std.testing.expectEqual(user.cbEndOfCompile, info.reason);
    try std.testing.expect(info.cb_rtn == @as(?Routine, callback.onCompile));
    try std.testing.expectEqual(@as(c_int, 3), info.index);
    try std.testing.expect(info.user_data == @as([*c]u8, &tag));
    try std.testing.expectEqual(user.vpiSimTime, it.type);
    try std.testing.expectEqual(user.vpiSuppressVal, iv.format);

    try std.testing.expectEqual(@as(c_int, 1), callback.vpi_remove_cb(h));
    try std.testing.expectEqual(@as(c_int, 0), callback.vpi_remove_cb(h));
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    callback.vpi_get_cb_info(h, &info);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
}

test "§12.11/§12.29: delays of a handle that is no object, or into no structure" {
    session.close();
    var junk: u32 = 0;
    var d: Delay = .{ .da = null, .no_of_delays = 1, .time_type = user.vpiScaledRealTime, .mtm_flag = 0, .append_flag = 0, .pulsere_flag = 0 };
    delays.vpi_get_delays(@ptrCast(&junk), &d);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    delays.vpi_put_delays(@ptrCast(&junk), &d);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
    delays.vpi_get_delays(null, null);
    try std.testing.expectEqual(user.vpiError, status.vpi_chk_error(null));
}
