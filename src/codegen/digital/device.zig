//! A `.v` design's top module -> a contract device an analog host loads
//! (`rt.Device`): the native processes and tables, 4-state, then one pin
//! per port bit, each an input sensed through an analog-to-digital bridge
//! or an output driven through a digital-to-analog one.
//! Cites: VAMS §7.8 (connect modules where a digital port meets an
//! electrical net); IEEE 1364-2005 §7.9 (an inout would be a resolved
//! net's driver, refused), §9.3 (refused), §10.2.3.
//!
//! Contents:
//! - `pub const Device = union(enum) { zig: []const u8, refused: []const u8 }`
//! - `pub const DeviceRoot = struct`
//! - `pub fn device(arena: Allocator, r: *Run, file_name: []const u8, schedule: plan.Schedule) Allocator.Error!Device`
//! - `pub fn emitDevice(arena: Allocator, source: []const u8, opts: sim_digital.Options, schedule: plan.Schedule, bag: *diag.Bag) sim_digital.Error!DeviceRoot`
//! - `pub fn contractDecls(em: *Emitter) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const diag = @import("diag");
const sim_digital = @import("sim").digital;
const Run = sim_digital.Run;
const deep = @import("base").deep_stack;
const contract = @import("contract");
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const expr_select = @import("expr_select.zig");
const native = @import("native.zig");
const plan = @import("plan.zig");

/// A device root, or why `r` cannot be one (static text).
pub const Device = union(enum) { zig: []const u8, refused: []const u8 };

/// `emitDevice`'s result: a `.v` design as a contract device.
pub const DeviceRoot = struct {
    /// The top module's name.
    name: []const u8,
    /// The device's Zig root; it imports the modules `contract` and `sim`.
    zig: []const u8,
};

/// Returns the contract device of `r`'s top module (`rt.Device`), 4-state.
/// `r` is read and its time-0 queue drained, never run.
pub fn device(arena: Allocator, r: *Run, file_name: []const u8, schedule: plan.Schedule) Allocator.Error!Device {
    r.diag_stage = .lower; // compiled, never run: as in `program` (#72)
    var em: Emitter = .init(arena, r, .device, .four);
    // `rt` reads these from the root module, which in a host is the host's.
    for (r.program.code.items) |ins| if (ins == .override_on) return .{ .refused = "a §9.3 procedural continuous assignment (assign or force)" };
    // ponytail: rt resolves switches, but no host test drives a device's
    // pins through one; open this with a vdev_host case that does.
    if (r.netlist.switches.len != 0) return .{ .refused = "a §7.6 pass switch" };
    if (native.native(&em, file_name, schedule)) |text| {
        assert(text.len != 0);
        return .{ .zig = text };
    } else |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Unsupported => {
            assert(em.why.len != 0);
            return .{ .refused = em.why };
        },
    }
}

/// Elaborates `source` and returns its top module as a contract device
/// (`device`), under `schedule`. A design that cannot be one is E1103 in
/// `bag` and `error.DigitalFailed`; a 1 s tick (no `timescale) is W1155.
/// Runs on a reserved deep stack.
pub fn emitDevice(arena: Allocator, source: []const u8, opts: sim_digital.Options, schedule: plan.Schedule, bag: *diag.Bag) sim_digital.Error!DeviceRoot {
    return deep.runGuarded(0, emitDeviceDeep, .{ arena, source, opts, schedule, bag });
}

/// Writes the contract decls of a device root (`rt.Device`), after the
/// design: its top module's ports in declaration order, each bit a pin, a
/// vector's from its left index to its right. `U` is an `enum(u8)` up to 256
/// pins and as wide as the pin count needs past them; the masks are
/// `contract.MaskOf`.
pub fn contractDecls(em: *Emitter) Error!void {
    const r = em.r;
    assert(em.target == .device);
    const m = &r.file.modules[r.hier.scopes.items[0].def];
    var names: std.Io.Writer.Allocating = .init(em.arena);
    var pins: std.Io.Writer.Allocating = .init(em.arena);
    var n: u32 = 0;
    for (m.ports) |p| {
        const out = switch (p.direction) {
            .input => false,
            .output => true,
            .inout, .unspecified => return em.refuse("an inout port: the analog side would drive a §7.9 resolved net"),
        };
        const at = r.hier.names.get(.{ .scope = 0, .str = p.name }) orelse return em.refuse("a port with no net or variable behind it");
        if (r.decls.reals.contains(at)) return em.refuse("a real port");
        for (m.vars) |v| if (v.name == p.name and v.storage != .reg) return em.refuse("an integer or time port");
        const w = em.slotWidth(at);
        const vr = expr_select.vecRange(r, at, w);
        const scalar = w == 1 and !r.typing.vec_ranges.contains(at);
        var i = vr.msb;
        while (true) : (i = if (vr.msb >= vr.lsb) i - 1 else i + 1) {
            // Not a VerA cap: a contract mask is one integer with a bit per
            // pin (`contract.MaskOf`), and Zig's widest integer is u65535.
            if (n == std.math.maxInt(u16)) return em.refuse("more than 65535 pins (a contract mask is one u65535)");
            const name = if (scalar) r.file.str(p.name) else try em.arena.print("{s}[{d}]", .{ r.file.str(p.name), i });
            names.writer.print(" {f},", .{std.zig.fmtId(name)}) catch return error.OutOfMemory;
            pins.writer.print("\n        .{{ .out = {}, .slot = {d}, .off = {d}, .bit = {d} }},", .{ out, at, em.planes.off[at], @abs(i - vr.lsb) }) catch return error.OutOfMemory;
            n += 1;
            if (i == vr.lsb) break;
        }
    }
    // No pins: Zig 0.17 refuses an empty exhaustive `enum(u8)`.
    const members = if (n == 0) " _," else names.written();
    const tag_bits = @max(8, std.math.log2_int_ceil(u32, @max(n, 1)));
    assert(tag_bits >= 8);
    try em.print(
        \\/// The VerA release that generated this device (`contract.vera_version`).
        \\pub const vera_version = "{s}";
        \\pub const U = enum(u{d}) {{{s} }};
        \\pub const num_ports: usize = {d};
        \\const Dev = rt.Device(.{{ .U = U, .design = &design, .dispatch = Code(false).dispatch, .units = {d}, .pins = &.{{{s}
        \\}} }});
        \\pub const Model = Dev.Model;
        \\pub const Instance = Dev.Instance;
        \\pub const State = Dev.State;
        \\pub const state_class = Dev.state_class;
        \\pub const deriv_reads = Dev.deriv_reads;
        \\pub const ddx_reads = Dev.ddx_reads;
        \\pub const jac_pattern = Dev.jac_pattern;
        \\pub const eval = Dev.eval;
        \\pub const initState = Dev.initState;
        \\pub const updateState = Dev.updateState;
        \\pub const stateCtl = Dev.stateCtl;
        \\pub const pendingBreakpoint = Dev.pendingBreakpoint;
        \\
        \\comptime {{
        \\    @import("contract").validate(@This());
        \\}}
        \\
    , .{ contract.vera_version, tag_bits, members, n, r.time.finest, pins.written() });
}

// ---- private ----

fn emitDeviceDeep(arena: Allocator, source: []const u8, opts: sim_digital.Options, schedule: plan.Schedule, bag: *diag.Bag) sim_digital.Error!DeviceRoot {
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var r = try sim_digital.elaborate(arena, source, opts, bag, &discard.writer);
    const top = r.file.modules[r.hier.scopes.items[0].def];
    const at: diag.Span = .{ .start = r.starts[top.main_tok], .end = r.starts[top.main_tok] };
    switch (try device(arena, &r, opts.file_name, schedule)) {
        .zig => |text| {
            if (r.time.finest == 0) try bag.add(.lower, .W1155, at, "module `{s}`: no `timescale sets a finer precision", .{r.file.str(top.name)});
            return .{ .name = r.file.str(top.name), .zig = text };
        },
        .refused => |why| {
            try bag.add(.lower, .E1103, at, "module `{s}`: {s}", .{ r.file.str(top.name), why });
            return error.DigitalFailed;
        },
    }
}
