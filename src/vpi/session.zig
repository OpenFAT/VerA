//! The process's one VPI session: the installed `Design`, the startup phase
//! and the product's invocation. `open`/`openDigital` -> an installed model;
//! `close` -> every registry reset; `runStartupRoutines` -> the application's
//! registrations; `vpi_get_vlog_info` -> the invocation.
//! Cites: VAMS-2023 §12.17, §12.33.2; IEEE 1364-2005 §26.2.4.
//!
//! ponytail: one installed design per process, in a global, and not
//! thread-safe. No Clause 12 routine takes a context or thread argument, so a
//! per-design context is a parameter no conforming application could pass. A
//! second device library brings its own design (`buildDesign`), which its
//! `Binding` swaps in while its calls run (VerA #84).
//!
//! Contents:
//! - `pub var design: ?Design`
//! - `pub var starting = false`
//! - `pub const Error = error`
//! - `pub fn open(gpa: std.mem.Allocator, res: *const @import("vera").CompileResult) !void`
//! - `pub fn buildDesign(gpa: std.mem.Allocator, res: *const @import("vera").CompileResult) !Design`
//! - `pub fn close() void`
//! - `pub fn runStartupRoutines() void`
//! - `pub fn runStartupTable(table: ?[*]const ?StartupFn) void`
//! - `pub fn openDigital(gpa: std.mem.Allocator, r: *sim.digital.Run) !void`
//! - `pub fn setInvocation(argc: c_int, argv: [*c][*c]u8) void`
//! - `pub fn vpi_get_vlog_info(vlog_info_p: ?*VlogInfo) c_int`

const std = @import("std");
const sim = @import("sim");
const callback = @import("callback.zig");
const delays = @import("delays.zig");
const model_analog = @import("model_analog.zig");
const model_digital = @import("model_digital.zig");
const print = @import("print.zig");
const run = @import("run.zig");
const status = @import("status.zig");
const systf = @import("systf.zig");
const value_put = @import("value_put.zig");
const Design = @import("Design.zig");
const abi = @import("abi.zig");
const StartupFn = abi.StartupFn;
const VlogInfo = abi.VlogInfo;

/// Figure 12-12's `version`: the VerA release (`contract.vera_version`), a
/// mutable copy because `VlogInfo.version` is a `[*c]u8`.
var version_str = @import("vera").version.*;

/// The installed model; null until `open`/`openDigital`, and after `close`.
pub var design: ?Design = null;

/// True while the startup routines run. IEEE 1364-2005 §26.2.4: "Only two
/// routines can be called at this time: vpi_register_systf() [and]
/// vpi_register_cb()", the latter for six reasons (`callback.startupReason`).
/// VAMS's vpi_register_analog_systf is the first one's analog twin.
/// `refused` turns every other routine away (VD-044).
pub var starting = false;

/// `NotElaborated`: `lowered` carries no elaborated top, a sequencing bug in
/// the caller rather than a diagnostic.
pub const Error = error{ OutOfMemory, NotElaborated };

/// The product's invocation, as its `main` received it. Kept by pointer: the
/// C runtime owns `argv` for the life of the process, which outlives any
/// application's use of it.
var inv_argc: c_int = 0;

var inv_argv: [*c][*c]u8 = null;

/// Builds the object model over one elaborated design and installs it,
/// closing any previous one.
///
/// `res` is what `vera.compileSource` produced: `res.module` is the
/// elaborated top (`Elaborate.Design.top`), `res.file` its AST and
/// `res.lowered.hier_names` its §6.7 path table. Everything read out of it is
/// copied, so the caller may free the `CompileResult` the moment this returns.
pub fn open(gpa: std.mem.Allocator, res: *const @import("vera").CompileResult) !void {
    if (design != null) close();
    design = try buildDesign(gpa, res);
}

/// The object model `open` installs, built and returned instead: the design
/// of a second device library, which `analog_run.Binding.attach` takes and
/// makes the installed one while that library's calls run (VerA #84). The
/// caller owns it until it hands it to `attach`.
pub fn buildDesign(gpa: std.mem.Allocator, res: *const @import("vera").CompileResult) !Design {
    return model_analog.build(gpa, res);
}

/// Frees the installed model and resets every sibling registry (run,
/// callbacks, values, systfs) and the error status. Invalidates every handle.
pub fn close() void {
    if (design) |*d| d.deinit();
    design = null;
    run.detach();
    callback.reset();
    value_put.reset();
    systf.reset();
    delays.reset();
    status.clearError();
}

/// Calls each entry of the application's `vlog_startup_routines` once, in
/// order, stopping at the 0 terminator (§12.33.2).
///
/// A binary that calls this must link a `vlog_startup_routines` (a strong
/// reference; §12.33.2 makes the array and the application one link unit).
/// The `@extern` is inside this body, so a binary that never calls it needs
/// none. Tests use `runStartupTable`.
pub fn runStartupRoutines() void {
    runStartupTable(@extern(?[*]const ?StartupFn, .{ .name = "vlog_startup_routines" }));
}

/// The loop of `runStartupRoutines` over a given table. A null table is a
/// no-op: an application that registers nothing at startup is legal.
pub fn runStartupTable(table: ?[*]const ?StartupFn) void {
    const entries = table orelse return;
    starting = true;
    defer starting = false;
    var i: usize = 0;
    while (entries[i]) |f| : (i += 1) f();
}

/// Builds the object model over an elaborated digital run and installs it.
/// The run must outlive the model: object values are read from `run.values`.
pub fn openDigital(gpa: std.mem.Allocator, r: *sim.digital.Run) !void {
    if (design != null) close();
    design = try model_digital.buildDigital(gpa, r);
    try callback.sizeHooks(r);
    run.attach(r);
    print.share(r);
}

/// A host calls this once, from its `main`, before the startup routines run.
/// A host that never does reports an invocation of no options.
pub fn setInvocation(argc: c_int, argv: [*c][*c]u8) void {
    inv_argc = argc;
    inv_argv = argv;
}

/// "shall obtain the following information about Verilog-AMS product
/// execution: The number of invocation options (argc), Invocation option
/// values (argv), Product and version strings ... The routine shall return
/// TRUE on success and FALSE on failure." The one failure an application can
/// cause is having no structure to fill.
pub export fn vpi_get_vlog_info(vlog_info_p: ?*VlogInfo) c_int {
    if (status.refused("vpi_get_vlog_info")) return 0;
    const out = vlog_info_p orelse {
        status.fail("BADINFO", "vpi_get_vlog_info: vlog_info_p is NULL", .{});
        return 0;
    };
    out.* = .{
        .argc = inv_argc,
        .argv = inv_argv,
        .product = @ptrCast(&status.product_name),
        .version = @ptrCast(&version_str),
    };
    return 1;
}
