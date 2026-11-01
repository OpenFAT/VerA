//! Proven MIR in, a behavioural IEEE 1364-2005 module out (`vera
//! --emit-verilog`): the digital stand-in a gate-level or RTL simulation
//! uses for an analog macro, derived from the same `.va` the analog side is
//! verified against. Same module name, same port order.
//!
//! The abstraction. Every net the model drives (one with a contribution) is
//! one bit: high when its potential is above VDD/2. For every assignment of
//! the input pins and node bits, each pin or node at 0 or VDD, the analog
//! block is run once (`Interp.zig`, an interpreter over the MIR whose
//! arithmetic is `opcode.fold`, the compiler's own constant kernel). A node's
//! §5.6 KCL residual and §5.6.1.2 charge, read with its own potential at 0
//! and at VDD, give the potential it settles to and its time constant
//! (`settle.zig`); a §5.6 `V(n) <+ F` contribution sets the potential
//! directly. Each node becomes a truth table over the bits it depends on and
//! an inertial `assign #(rise, fall)` (`write.zig`).
//!
//! Pins (§2.9 attributes on a port declaration, `--digital-pins` wins):
//!   `(* vera_pin = "digital" *)`  logic: `input` if the model never drives it,
//!                                 else `output`
//!   `(* vera_pin = "analog" *)`   undriven `inout wire`; read as its logic level
//!   `(* vera_pin = "power" *)`    supply, VDD;  `(* vera_pin = "ground" *)`, 0 V
//! Undecorated: `vdd*`/`vcc*`/`vpwr`/`vpb`/`avdd`/`dvdd` are power,
//! `vss*`/`gnd*`/`vgnd`/`vnb`/`vee*`/`avss`/`dvss` ground, the rest analog.
//! `(* vera_delay = <seconds> *)` on a net's declaration replaces its derived
//! delay (both edges). On a port, both go on the direction declaration
//! (`inout`): a port's discipline declaration carries no attribute to it.
//! `--power-pins` moves the supply pins under `` `ifdef USE_POWER_PINS ``.
//!
//! Refused with a `Refusal`, never emitted half-right: §5.10 events and held
//! variables, `I()` probes and `ddt`/`idt` outside a contribution (their
//! unknowns are not nets), arrays, vector ports, `$abstime` and any call with
//! no static value, more than `vars_max` pins plus nodes, and a node whose
//! derived delay is not finite (a NaN or infinite charge or `td`) and has no
//! `vera_delay`.
//!
//! The spine, one stage per file: `ports.readAttrs` and `ports.classify`
//! (pin kinds), `drive.scan` (the variables), `sample.sample` (2^n runs),
//! `settle.settle` and `settle.liveStates` (the logic functions), then
//! `write.write` (the text).
//!
//! Contents:
//! - `pub const Refusal = union(enum)` (`refusal.zig`)
//! - `pub const vars_max: u8` (`drive.zig`)
//! - `pub const Options = struct`
//! - `pub const Error = error{ OutOfMemory, Refused, WriteFailed }`
//! - `pub fn emit(gpa: Allocator, mir: *const Mir, lw: *const Lowered, options: Options, out: *std.Io.Writer, refusal: ?*Refusal) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const ports = @import("ports.zig");
const drive = @import("drive.zig");
const sample = @import("sample.zig");
const settle = @import("settle.zig");
const write = @import("write.zig");

/// Why `emit` refused; rendered by `{f}`.
pub const Refusal = @import("refusal.zig").Refusal;

/// The largest pins-plus-driven-nodes count the truth tables enumerate.
pub const vars_max = drive.vars_max;

/// What `emit` reads besides the model.
pub const Options = struct {
    /// `--digital-pins`: port names that are logic, whatever their attributes say.
    digital: []const []const u8 = &.{},
    /// `--power-pins`: declare the supply pins only under `ifdef USE_POWER_PINS`.
    power_pins: bool = false,
    /// The logic-high potential (V) a pin or node is evaluated at; > 0, finite.
    vdd: f64 = 1.8,
    /// The `.va` path, for the header comment.
    source: []const u8 = "",
};

/// Every way `emit` fails.
pub const Error = error{
    /// The scratch allocator failed; nothing was written to `out`.
    OutOfMemory,
    /// The model is outside the abstraction (the header lists what is);
    /// `refusal`, when given, holds why. Nothing was written to `out`.
    Refused,
    /// `out` failed; it holds a prefix of the module.
    WriteFailed,
};

/// Writes the behavioural module of `mir` and `lw` to `out`, or refuses it.
/// Every table lives in an arena over `gpa`, freed before return, so the
/// peak is about 24 bytes per (driven node, assignment): 2^vars_max · 20
/// rows at most. Runs the analog block 2^vars times. A `Refusal` borrows
/// from `mir`, `lw` and `options`. Asserts that `options.vdd` is positive
/// and finite.
pub fn emit(gpa: Allocator, mir: *const Mir, lw: *const Lowered, options: Options, out: *std.Io.Writer, refusal: ?*Refusal) Error!void {
    assert(options.vdd > 0);
    assert(std.math.isFinite(options.vdd));
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var slot: Refusal = undefined;
    const p = plan(arena.allocator(), mir, lw, options, &slot) catch |e| switch (e) {
        error.Refused => {
            if (refusal) |r| r.* = slot;
            return error.Refused;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    assert(p.pins.len == lw.num_ports);
    try write.write(out, &p);
}

// ---- private ----

/// Every stage but the text, in order: everything that can refuse runs
/// before a byte is written.
fn plan(scratch: Allocator, mir: *const Mir, lw: *const Lowered, options: Options, slot: *Refusal) (Allocator.Error || error{Refused})!write.Plan {
    if (lw.held_vars.items.len != 0) return slot.raise(.{ .held_state = lw.held_vars.items[0].name });
    if (lw.vectors.count() != 0) return slot.raise(.vector_net);
    if (lw.num_ports == 0) return slot.raise(.{ .no_ports = mir.name });
    assert(lw.num_ports <= lw.nodes.len);
    const names = lw.nodes.items(.name);

    const attrs = try ports.readAttrs(scratch, lw, slot);
    const pins = try ports.classify(scratch, names[0..lw.num_ports], &attrs, options.digital, mir.name, slot);
    const d = try drive.scan(scratch, mir, lw, pins, slot);
    const samples = try sample.sample(scratch, mir, lw, pins, &d, options.vdd, slot);
    const settled = try settle.settle(scratch, &samples, &d, names, &attrs.delay, options.vdd, slot);
    const live = settle.liveStates(&settled, &d, pins);
    assert(settled.support.len == d.states().len);
    assert(live >> @intCast(d.states().len) == 0);
    if (write.firstSignal(pins, options.power_pins) == null) return slot.raise(.only_supplies);
    return .{
        .module = mir.name,
        .source = options.source,
        .vdd = options.vdd,
        .power_pins = options.power_pins,
        .names = names,
        .pins = pins,
        .drive = d,
        .settled = settled,
        .live = live,
    };
}

test {
    _ = @import("refusal.zig");
    _ = ports;
    _ = drive;
    _ = @import("Interp.zig");
    _ = sample;
    _ = settle;
    _ = write;
}
