//! An elaborated IEEE 1364-2005 design (the interpreter's `sim.digital.Run`,
//! until B4 gives this module IR of its own) -> Zig text that runs on
//! `sim.rt`: an `--emit-exe` executable's root (`program`), or a contract
//! device an analog host loads (`emitDevice`). Re-exports and `emitDevice`
//! only; emit.zig, emit_expr.zig and plan.zig import each other directly.
//! Clauses: those of emit.zig's header.

const std = @import("std");
const diag = @import("diag");
const sim_digital = @import("sim").digital;
/// The emitter itself, for the tests of what it writes (`tests/unit.zig`).
pub const emit = @import("emit.zig");

/// `--emit-rtlil`: the design as Yosys RTLIL.
pub const rtlil = @import("rtlil.zig");
/// `vera --schedule=`: same-time events in FIFO order, or levelized.
pub const Schedule = emit.Schedule;
/// `vera --state=`: which logic the executable computes.
pub const Logic = emit.Logic;
/// The root module of a design's `--emit-exe` executable, native or the
/// interpreter fallback.
pub const program = emit.program;

/// A `.v` design as a contract device an analog host loads (`rt.Device`).
const DeviceZig = struct {
    /// The top module's name.
    name: []const u8,
    /// The device's Zig root; it imports the modules `contract` and `sim`.
    zig: []const u8,
};

/// `source`'s top module as a contract device (`emit.device`), 4-state and
/// under `schedule`. A design that cannot be one is E1103 in `bag` and
/// `error.DigitalFailed`; a 1 s tick (no `timescale) is W1155.
pub fn emitDevice(arena: std.mem.Allocator, source: []const u8, opts: sim_digital.Options, schedule: Schedule, bag: *diag.Bag) sim_digital.Error!DeviceZig {
    return @import("base").deep_stack.runGuarded(0, emitDeviceDeep, .{ arena, source, opts, schedule, bag });
}

fn emitDeviceDeep(arena: std.mem.Allocator, source: []const u8, opts: sim_digital.Options, schedule: Schedule, bag: *diag.Bag) sim_digital.Error!DeviceZig {
    var discard: std.Io.Writer.Discarding = .init(&.{});
    var r = try sim_digital.elaborate(arena, source, opts, bag, &discard.writer);
    const top = r.file.modules[r.scope_info.items[0].def];
    const at: diag.Span = .{ .start = r.starts[top.main_tok], .end = r.starts[top.main_tok] };
    switch (try emit.device(arena, &r, opts.file_name, schedule)) {
        .zig => |text| {
            if (r.finest == 0) try bag.add(.lower, .W1155, at, "module `{s}`: no `timescale sets a finer precision", .{r.file.str(top.name)});
            return .{ .name = r.file.str(top.name), .zig = text };
        },
        .refused => |why| {
            try bag.add(.lower, .E1103, at, "module `{s}`: {s}", .{ r.file.str(top.name), why });
            return error.DigitalFailed;
        },
    }
}

test {
    _ = emit;
    _ = @import("emit_expr.zig");
    _ = @import("plan.zig");
    _ = rtlil;
}
