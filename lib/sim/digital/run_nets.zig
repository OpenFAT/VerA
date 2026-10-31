//! A net's cold rows and its drivers' transition state, read and grown on demand.
//! Cites: IEEE 1364-2005 §6.1.3, §7.9.
//!
//! Contents:
//! - `pub const Netlist = struct`
//! - `pub fn netCold(self: *const Run, n: Net) *const NetCold`
//! - `pub fn netDrivers(self: *const Run, net: u32) []const u32`
//! - `pub fn driverTransition(self: *Run, at: u32) Error!*Inertial`
//! - `pub fn netColdMut(self: *Run, net: u32) Error!*NetCold`

const std = @import("std");
const SlotNets = @import("root.zig").SlotNets;
const assert = std.debug.assert;
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

/// A design's §7.9 netlist: which slots are nets, each net's hot and cold
/// row and driver list, each driver's contribution and inertial state, the
/// §7.6 switches, the variable delays read when a driver schedules, and
/// §14.3.3's last transition of each module path source.
pub const Netlist = struct {
    /// Which of `nets` a slot is, for the slots that are nets at all. Per slot
    /// and not a `net_base` boundary because §6.2.2 elaboration interleaves one
    /// instance's variables with the next one's nets.
    slot_nets: SlotNets = .{},
    nets: []Net = &.{},
    /// The cold rows `Net.cold` indexes.
    cold: std.ArrayList(NetCold) = .empty,
    /// Every net's drivers as one CSR table: net `n`'s are
    /// `net_drivers[net_driver_start[n]..net_driver_start[n + 1]]`, in
    /// declaration order (`netDrivers`). Empty until pass two groups them.
    driver_start: []const u32 = &.{},
    driver_ids: []const u32 = &.{},
    /// Every net's per-bit §7.10 signals, `Net.signal` the first of each.
    signals: []Signal = &.{},
    drivers: []Driver = &.{},
    /// The §6.1.3 transitions of the delayed drivers, `Driver.transition`
    /// the row of each (`driverTransition`).
    transitions: std.ArrayList(Inertial) = .empty,
    /// §7.6 every pass switch.
    switches: []Tran = &.{},
    /// Per driver index, a `delay3` that reads a variable: A.2.2.3 lets a
    /// continuous assignment's or gate's delay be one, which §6.1.3 reads
    /// each time the driver schedules (`exec`'s `.continuous`).
    driver_delays: std.AutoHashMapUnmanaged(u32, Ast.Delay3) = .empty,
    /// The same for a §7.6 pass switch's delays, by `trans` index.
    switch_delays: std.AutoHashMapUnmanaged(u32, Ast.Delay3) = .empty,
    /// IEEE 1364-2005 §14.3.3: per module path source slot (a `.path`
    /// watch), its last transition, which picks the path whose delay a
    /// destination transition takes (`waiters.store` fills it).
    path_changed: std.AutoHashMapUnmanaged(u32, @import("net.zig").PathEdge) = .empty,
};

/// Net `n`'s cold row, or `NetCold.none` when it has none.
pub fn netCold(self: *const Run, n: Net) *const NetCold {
    return if (n.cold == no_cold) &NetCold.none else &self.netlist.cold.items[n.cold];
}

/// Net `net`'s driver rows (`drivers` indices), in declaration order;
/// none until pass two has grouped them (`elaborate`).
pub fn netDrivers(self: *const Run, net: u32) []const u32 {
    assert(net < self.netlist.nets.len);
    if (net + 1 >= self.netlist.driver_start.len) return &.{};
    return self.netlist.driver_ids[self.netlist.driver_start[net]..self.netlist.driver_start[net + 1]];
}

/// Driver `at`'s §6.1.3 transition row, made on first use. Invalidates
/// pointers to other rows when it makes one.
pub fn driverTransition(self: *Run, at: u32) Error!*Inertial {
    const d = &self.netlist.drivers[at];
    if (d.transition == no_transition) {
        try self.netlist.transitions.append(self.arena, .{});
        d.transition = @intCast(self.netlist.transitions.items.len - 1);
    }
    return &self.netlist.transitions.items[d.transition];
}

/// Net `net`'s cold row, made on first use. Invalidates pointers to
/// other cold rows when it makes one.
pub fn netColdMut(self: *Run, net: u32) Error!*NetCold {
    assert(net < self.netlist.nets.len);
    const n = &self.netlist.nets[net];
    if (n.cold == no_cold) {
        n.cold = @intCast(self.netlist.cold.items.len);
        try self.netlist.cold.append(self.arena, .{});
    }
    return &self.netlist.cold.items[n.cold];
}
