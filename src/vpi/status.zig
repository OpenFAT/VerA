//! The §12.2 error status and the routines' common entry: a failing
//! routine's message -> what `vpi_chk_error` reports; a routine call -> a
//! cleared status, a startup-phase refusal, or the installed design. Also the
//! Annex G names VerA refuses by name.
//! Cites: VAMS-2023 §12.2 Figure 12-1, Table 12-1; IEEE 1364-2005 §1.7,
//! §26.2.4, §27.1.
//!
//! Contents:
//! - `pub var product_name = "VerA".*`
//! - `pub const Unanswered = struct`
//! - `pub fn clearError() void`
//! - `pub fn fail(err: [:0]const u8, comptime fmt: []const u8, args: anytype) void`
//! - `pub fn noteError(err: [:0]const u8, comptime fmt: []const u8, args: anytype) void`
//! - `pub fn failUnanswered(comptime who: []const u8, u: Unanswered) void`
//! - `pub fn unansweredType(t: c_int) ?Unanswered`
//! - `pub fn unansweredProp(p: c_int) ?Unanswered`
//! - `pub fn refused(comptime who: []const u8) bool`
//! - `pub inline fn enter(comptime who: []const u8) ?*Design`
//! - `pub inline fn object(comptime who: []const u8, h: abi.vpiHandle) ?*Obj`
//! - `pub fn vpi_chk_error(error_info_p: ?*ErrorInfo) c_int`

const std = @import("std");
const abi = @import("abi.zig");
const callback_fire = @import("callback_fire.zig");
const session = @import("session.zig");
const trust = @import("trust.zig");
const user = @import("vpi_user.zig");
const Design = @import("Design.zig");
const schema = @import("schema.zig");
const ErrorInfo = abi.ErrorInfo;
const Obj = schema.Obj;

/// Figure 12-1's `product`. Static, NUL-terminated, never rewritten.
pub var product_name = "VerA".*;

/// An Annex G constant vpi_user.h defines (IEEE 1364-2005 §1.7 makes the
/// listing normative) that no routine here answers: its name and why, so
/// the refusal says which question it was (§12.2's error, read through
/// vpi_chk_error as IEEE 1364-2005 §27.1 has it).
pub const Unanswered = struct { name: []const u8, why: []const u8 };

var err_level: c_int = 0;
var err_code: [:0]const u8 = "";
var err_buf: [512]u8 = undefined;
var err_len: usize = 0;
const no_sdf = "VerA reads no SDF, so the model holds no delay device or terminal (IEEE 1364-2005 §26.6.21)";
const no_frame = "the model holds no task or function frame (IEEE 1364-2005 §26.6.20)";
const no_prim_array = "the model holds an arrayed primitive's instances, not the array";
const no_bits = "the model expands no port or continuous assignment into bits";
const no_directive = "the model does not record the compiler directives in force where a module was defined";
const no_save = "VerA has no save or restart (IEEE 1364-2005 C.8)";

/// Resets the §12.2 error status; every routine but `vpi_chk_error` calls it.
/// Asserts that the recorded message fits its buffer with its NUL.
pub fn clearError() void {
    std.debug.assert(err_len < err_buf.len);
    err_level = 0;
    err_len = 0;
    err_code = "";
    std.debug.assert(err_code.len == 0);
}

/// Records one error; the caller returns its own documented failure value.
/// `err` is a short stable token (`s_vpi_error_info.code`). Both it and the
/// message live in static storage until the next VPI call (Figure 12-1).
/// Asserts that `err` is a token, not empty.
///
/// ponytail: a fixed 512-byte message, truncating, so the error path never
/// allocates.
pub fn fail(err: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    std.debug.assert(err.len != 0);
    noteError(err, fmt, args);
    // A cbPLIError routine may call other routines, each clearing the status;
    // the failing routine's caller still reads this error afterwards.
    const saved = .{ err_level, err_code, err_buf, err_len };
    callback_fire.pliError();
    err_level, err_code, err_buf, err_len = saved;
    std.debug.assert(err_level == user.vpiError);
    std.debug.assert(err_code.ptr == err.ptr);
}

/// Records the status `vpi_chk_error` reports, without firing cbPLIError.
/// For the cbError path: §12.31.4 "On a cbError callback, the routine
/// vpi_chk_error() can be called to retrieve error information", and that
/// callback is not a PLI-routine failure. Asserts that `err` is not empty.
pub fn noteError(err: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    std.debug.assert(err.len != 0);
    err_level = user.vpiError;
    err_code = err;
    const written = std.mem.print(err_buf[0 .. err_buf.len - 1], fmt, args) catch
        err_buf[0 .. err_buf.len - 1];
    err_len = written.len;
    err_buf[err_len] = 0;
    std.debug.assert(err_len < err_buf.len);
}

/// Records the refusal of `u`, asked of routine `who`. Asserts that `u`
/// names the constant and says why.
pub fn failUnanswered(comptime who: []const u8, u: Unanswered) void {
    std.debug.assert(u.name.len != 0);
    std.debug.assert(u.why.len != 0);
    fail("NOTSUPPORTED", who ++ ": {s} is not answered: {s}", .{ u.name, u.why });
}

/// The object types and relationships of Annex G no vpi_handle() or
/// vpi_iterate() answers.
/// Asserts that each refusal names its constant and says why.
pub fn unansweredType(t: c_int) ?Unanswered {
    const u: ?Unanswered = switch (t) {
        10 => .{ .name = "vpiDefParam", .why = "the model keeps no defparam: elaboration applied it" },
        45 => .{ .name = "vpiPortBit", .why = no_bits },
        54 => .{ .name = "vpiSpecParam", .why = "the model keeps no specparam object" },
        98 => .{ .name = "vpiPortInst", .why = "the model does not record the ports of lower instances a net connects to" },
        106 => .{ .name = "vpiBitSelect", .why = "the model types a bit-select as a vpiNetBit or vpiRegBit" },
        108 => .{ .name = "vpiDelayTerm", .why = no_sdf },
        109 => .{ .name = "vpiDelayDevice", .why = no_sdf },
        110 => .{ .name = "vpiFrame", .why = no_frame },
        111 => .{ .name = "vpiGateArray", .why = no_prim_array },
        113 => .{ .name = "vpiPrimitiveArray", .why = no_prim_array },
        117 => .{ .name = "vpiSwitchArray", .why = no_prim_array },
        118 => .{ .name = "vpiUdpArray", .why = no_prim_array },
        120 => .{ .name = "vpiInTerm", .why = no_sdf },
        121 => .{ .name = "vpiInstanceArray", .why = "the model reaches an instance array as vpiModuleArray" },
        124 => .{ .name = "vpiOutTerm", .why = no_sdf },
        125 => .{ .name = "vpiPorts", .why = no_bits },
        126 => .{ .name = "vpiSimNet", .why = "the model does not record the net a port connection collapsed into" },
        127 => .{ .name = "vpiTaskFunc", .why = "iterate vpiTask and vpiFunction instead" },
        128 => .{ .name = "vpiContAssignBit", .why = no_bits },
        135 => .{ .name = "vpiGenVar", .why = "a genvar is no object the model holds" },
        else => null, // else: every other number is answered, or is no Annex G type and gets the routine's own refusal
    };
    if (u) |x| {
        std.debug.assert(std.mem.startsWith(u8, x.name, "vpi"));
        std.debug.assert(x.why.len != 0);
    }
    return u;
}

/// The properties of Annex G no vpi_get() or vpi_get_str() answers.
/// Asserts that each refusal names its constant and says why.
pub fn unansweredProp(p: c_int) ?Unanswered {
    const u: ?Unanswered = switch (p) {
        8 => .{ .name = "vpiCellInstance", .why = no_directive },
        13 => .{ .name = "vpiDefNetType", .why = no_directive },
        14 => .{ .name = "vpiUnconnDrive", .why = no_directive },
        15 => .{ .name = "vpiDefFile", .why = "the model does not record where a module was defined" },
        16 => .{ .name = "vpiDefLineNo", .why = "the model does not record where a module was defined" },
        19 => .{ .name = "vpiExplicitName", .why = "the model does not record how a port was named" },
        23 => .{ .name = "vpiExplicitScalared", .why = "the model does not record a net's scalared or vectored keyword" },
        24 => .{ .name = "vpiExplicitVectored", .why = "the model does not record a net's scalared or vectored keyword" },
        25 => .{ .name = "vpiExpanded", .why = "the model does not record whether a vector is expanded" },
        27 => .{ .name = "vpiChargeStrength", .why = "the model does not record a trireg's charge strength" },
        47 => .{ .name = "vpiDefDelayMode", .why = no_directive },
        48 => .{ .name = "vpiDefDecayTime", .why = no_directive },
        49 => .{ .name = "vpiActive", .why = no_frame },
        53 => .{ .name = "vpiConstantSelect", .why = "the model does not record whether a select's index is constant" },
        56 => .{ .name = "vpiDelayType", .why = no_sdf },
        59 => .{ .name = "vpiMultiArray", .why = "the model does not record an array's dimension count" },
        60 => .{ .name = "vpiOffset", .why = "the model does not record this property" },
        61 => .{ .name = "vpiResolvedNetType", .why = "the model keeps each net's declared vpiNetType, not the type a port connection resolved" },
        62 => .{ .name = "vpiSaveRestartID", .why = no_save },
        63 => .{ .name = "vpiSaveRestartLocation", .why = no_save },
        64 => .{ .name = "vpiValid", .why = no_frame },
        else => null, // else: every other number is answered, or is no Annex G property and gets the routine's own refusal
    };
    if (u) |x| {
        std.debug.assert(std.mem.startsWith(u8, x.name, "vpi"));
        std.debug.assert(x.why.len != 0);
    }
    return u;
}

/// Every routine but `vpi_chk_error` and the three registrations starts
/// here or at `enter`: §12.2 "the error status shall be reset by any VPI
/// routine call", and IEEE 1364-2005 §26.2.4 allows none of them while the
/// startup routines run. True means the error is recorded; the caller
/// returns its own documented failure value.
/// Asserts that `who` names a routine and that a refusal is recorded.
pub fn refused(comptime who: []const u8) bool {
    comptime std.debug.assert(std.mem.startsWith(u8, who, "vpi_"));
    clearError();
    if (!session.starting) return false;
    fail("STARTUP", who ++ ": IEEE 1364-2005 §26.2.4 allows only vpi_register_systf() and vpi_register_cb() in vlog_startup_routines; call it from a cbEndOfCompile callback", .{});
    std.debug.assert(err_level == user.vpiError);
    return true;
}

/// `refused`, and then: no routine has an answer without an open design.
/// Null means the error is recorded; the caller returns its own documented
/// failure value.
/// Asserts that an answered entry left no error behind.
pub inline fn enter(comptime who: []const u8) ?*Design {
    if (refused(who)) return null;
    std.debug.assert(!session.starting);
    if (session.design) |*d| {
        std.debug.assert(err_level == 0);
        return d;
    }
    fail("NODESIGN", who ++ ": no design is open", .{});
    return null;
}

/// `h` as an object VerA issued, or null with the error recorded.
/// Asserts that a refusal is recorded.
pub inline fn object(comptime who: []const u8, h: abi.vpiHandle) ?*Obj {
    if (trust.asObj(h)) |o| {
        std.debug.assert(session.design != null);
        return o;
    }
    fail("BADHANDLE", who ++ ": {s} is not a handle to an object", .{trust.describe(h)});
    std.debug.assert(err_level == user.vpiError);
    return null;
}

/// "Shall return an integer constant representing an error severity level if
/// the previous call to a VPI routine resulted in an error ... The error status
/// shall be reset by any VPI routine call except vpi_chk_error(). Calling
/// vpi_chk_error() shall have no effect on the error status."
///
/// So this is the one routine that does not clear the status, and it is
/// idempotent. "If the error information is not needed, a NULL can be passed
/// to the routine."
///
/// Asserts that the status is one this file wrote.
pub export fn vpi_chk_error(error_info_p: ?*ErrorInfo) c_int {
    // `fail` and `noteError` set vpiError and `clearError` 0: no other level.
    std.debug.assert(err_level == 0 or err_level == user.vpiError);
    std.debug.assert(err_len < err_buf.len);
    if (error_info_p) |info| {
        info.* = .{
            // Table 12-1's companion field. Every error VerA raises is raised
            // from an application's own call into it, which is `vpiPLI`;
            // `vpiCompile` and `vpiRun` belong to errors a simulator raises
            // outside a VPI call, and there is no such path into this file.
            .state = user.vpiPLI,
            .level = err_level,
            .message = if (err_len == 0) null else @ptrCast(&err_buf),
            .product = @ptrCast(&product_name),
            .code = if (err_code.len == 0) null else @constCast(err_code.ptr),
            // The APPLICATION's call site. C gives a callee no caller location,
            // so these are reported absent rather than invented.
            .file = null,
            .line = 0,
        };
    }
    return err_level;
}
