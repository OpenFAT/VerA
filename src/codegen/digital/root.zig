//! The `digital` module: an elaborated IEEE 1364-2005 design (the
//! interpreter's `sim.digital.Run`) -> Zig text that runs on `sim.rt`: an
//! `--emit-exe` executable's root (`program`), or a contract device an
//! analog host loads (`emitDevice`); and a `.v` source -> Yosys RTLIL
//! (`rtlil`). Re-exports only.
//! Cites: those of each file's header.
//!
//! Contents:
//! - `pub const Schedule = plan.Schedule`
//! - `pub const Logic = Emitter.Logic`
//! - `pub const Reason = Emitter.Reason`
//! - `pub const Embed = program_root.Embed`
//! - `pub const Program = program_root.Program`
//! - `pub const program = program_root.program`
//! - `pub const Device = device_root.Device`
//! - `pub const DeviceRoot = device_root.DeviceRoot`
//! - `pub const device = device_root.device`
//! - `pub const emitDevice = device_root.emitDevice`
//! - `pub const rtlil`

/// `--emit-rtlil`: the design as Yosys RTLIL.
pub const rtlil = @import("rtlil.zig");
const Emitter = @import("Emitter.zig");
const device_root = @import("device.zig");
const plan = @import("plan.zig");
const program_root = @import("program.zig");

/// `vera --schedule=`: same-time events in FIFO order, or levelized.
pub const Schedule = plan.Schedule;
/// `vera --state=`: which logic the executable computes.
pub const Logic = Emitter.Logic;
/// Why an `.auto` executable stays 4-state throughout, and where.
pub const Reason = Emitter.Reason;
/// What `vera --emit-exe` was given, which a fallback root embeds.
pub const Embed = program_root.Embed;
/// `program`'s result: the executable's root text, native or not.
pub const Program = program_root.Program;
/// The root module of a design's `--emit-exe` executable, native or the
/// interpreter fallback.
pub const program = program_root.program;
/// A device root, or why a design cannot be one.
pub const Device = device_root.Device;
/// `emitDevice`'s result: the top module's name and the device's root.
pub const DeviceRoot = device_root.DeviceRoot;
/// The contract device of an elaborated design's top module.
pub const device = device_root.device;
/// A `.v` source's top module as a contract device, with its diagnostics.
pub const emitDevice = device_root.emitDevice;

test {
    _ = @import("assign.zig");
    _ = @import("calls.zig");
    _ = @import("design_table.zig");
    _ = device_root;
    _ = @import("drivers.zig");
    _ = Emitter;
    _ = @import("expr.zig");
    _ = @import("expr_real.zig");
    _ = @import("expr_select.zig");
    _ = @import("expr_system.zig");
    _ = @import("instruction.zig");
    _ = @import("layout.zig");
    _ = @import("native.zig");
    _ = @import("nets.zig");
    _ = plan;
    _ = @import("plan_nodes.zig");
    _ = @import("plane_words.zig");
    _ = @import("processes.zig");
    _ = program_root;
    _ = rtlil;
    _ = @import("rtlil_emitter.zig");
    _ = @import("rtlil_expr.zig");
    _ = @import("rtlil_fold.zig");
    _ = @import("rtlil_module.zig");
    _ = @import("rtlil_proc.zig");
    _ = @import("rtlil_table.zig");
    _ = @import("settle.zig");
    _ = @import("show.zig");
    _ = @import("step_local.zig");
    _ = @import("tasks.zig");
    _ = @import("timing.zig");
}
