//! A net's cold rows and its drivers' transition state, read and grown on demand.
//! Cites: IEEE 1364-2005 §6.1.3, §7.9.
//!
//! Contents:
//! - `pub fn netCold(self: *const Run, n: Net) *const NetCold`
//! - `pub fn netDrivers(self: *const Run, net: u32) []const u32`
//! - `pub fn driverTransition(self: *Run, at: u32) Error!*Inertial`
//! - `pub fn netColdMut(self: *Run, net: u32) Error!*NetCold`

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const Scheduler = @import("../scheduler.zig").Scheduler;
/// Scheduler ticks. `Time` below is the timescale module, not this.
const Tick = @import("../scheduler.zig").Time;
const Time = @import("../time.zig");
const deep = @import("base").deep_stack;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const display = @import("display.zig");
/// Public for the VPI (src/vpi/value.zig), which writes a value the way a
/// process does (`waiters.store` now, `exec.enqueue` of a `.write` later), so a
/// §12.30 put wakes waiters and value-change watchers like any other write.
const exec = @import("exec.zig");
/// §17 system tasks.
const system = @import("system.zig");
const driver = @import("driver.zig");
const binding = @import("bind.zig");
const elab = @import("elab.zig");
const waiters = @import("waiters.zig");
const resolution = @import("resolution.zig");
const tchk = @import("tchk.zig");
const vpi = @import("vpi.zig");
const Type = compile.Type;
const Instruction = compile.Instruction;
const Row = exec.Row;
const Delay = @import("net.zig").Delay;
const Net = @import("net.zig").Net;
const NetCold = @import("net.zig").NetCold;
const no_cold = @import("net.zig").no_cold;
const Tran = @import("net.zig").Tran;
const Signal = @import("net.zig").Signal;
const Inertial = @import("net.zig").Inertial;
const no_transition = @import("net.zig").no_transition;
const Driver = @import("net.zig").Driver;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const Show = display.Show;
const TimeFormat = display.TimeFormat;

// ---- the public surface -----------------------------------------------------
const root = @import("root.zig");
const Run = root.Run;
const Error = root.Error;

/// The descriptor table a `Run` with no `file_io` opens files through.
const own_files = system.own;

/// Net `n`'s cold row, or `NetCold.none` when it has none.
pub fn netCold(self: *const Run, n: Net) *const NetCold {
    return if (n.cold == no_cold) &NetCold.none else &self.net_cold.items[n.cold];
}

/// Net `net`'s driver rows (`drivers` indices), in declaration order;
/// none until pass two has grouped them (`elaborate`).
pub fn netDrivers(self: *const Run, net: u32) []const u32 {
    if (net + 1 >= self.net_driver_start.len) return &.{};
    return self.net_drivers[self.net_driver_start[net]..self.net_driver_start[net + 1]];
}

/// Driver `at`'s §6.1.3 transition row, made on first use. Invalidates
/// pointers to other rows when it makes one.
pub fn driverTransition(self: *Run, at: u32) Error!*Inertial {
    const d = &self.drivers[at];
    if (d.transition == no_transition) {
        try self.transitions.append(self.arena, .{});
        d.transition = @intCast(self.transitions.items.len - 1);
    }
    return &self.transitions.items[d.transition];
}

/// Net `net`'s cold row, made on first use. Invalidates pointers to
/// other cold rows when it makes one.
pub fn netColdMut(self: *Run, net: u32) Error!*NetCold {
    const n = &self.nets[net];
    if (n.cold == no_cold) {
        n.cold = @intCast(self.net_cold.items.len);
        try self.net_cold.append(self.arena, .{});
    }
    return &self.net_cold.items[n.cold];
}
