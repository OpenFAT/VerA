//! §7.9 net resolution of a native design: the names the emitted code and the rest of rt reach as `rt.net.<name>`, from the files below.
//! Cites: none here; each file's header names its clauses.
//!
//! Contents:
//! - `pub const drive_base`
//! - `pub const net_base`
//! - `pub const Net`
//! - `pub const Path`
//! - `pub const PathCond`
//! - `pub const Driver`
//! - `pub const Source`
//! - `pub const Mos`
//! - `pub const Bridge`
//! - `pub const Udp`
//! - `pub const Tran`
//! - `pub const Nets`
//! - `pub const drive`
//! - `pub const gate`
//! - `pub const udp`
//! - `pub const mos`
//! - `pub const bridge`
//! - `pub const pull`
//! - `pub const contribution`
//! - `pub const resolve`
//! - `pub const shown`
//! - `pub const arrive`
//! - `pub const switchCtrl`
//! - `pub const seedPaths`
//! - `pub const pathSeen`

const layout = @import("layout.zig");
const driving = @import("driving.zig");
const resolution = @import("resolution.zig");
const switches = @import("switches.zig");
const module_paths = @import("module_paths.zig");

/// `State.next` payloads: driver k's, net k's delayed transition, and net
pub const drive_base = layout.drive_base;
/// `net_base + k`: net k's delayed transition lands (`drive_base`).
pub const net_base = layout.net_base;
/// One net `resolution.resolve` folds: `Run.netlist.nets[k]` with its word offset.
pub const Net = layout.Net;
/// `dnet.Path` resolved: its source's slot and first word, and its
pub const Path = layout.Path;
/// §14.2.4.1 a state-dependent path's condition, true when its least
pub const PathCond = layout.PathCond;
/// One driver of a `Net`, `Run.netlist.drivers[i]` without its expression.
pub const Driver = layout.Driver;
/// What computes a driver's value.
pub const Source = layout.Source;
/// `dnet.Mos` resolved: its data terminal's net, when it names one, is
pub const Mos = layout.Mos;
/// `dnet.Bridge` with its source slot's first word.
pub const Bridge = layout.Bridge;
/// `dnet.Udp`'s table: `ins` inputs, its state at time 0.
pub const Udp = layout.Udp;
/// `dnet.Tran` without its control (a `switch_ctrl` process reads that):
pub const Tran = layout.Tran;
/// What the resolution keeps between events, one row per net or driver.
pub const Nets = layout.Nets;
/// `exec` `.continuous`: driver `i` asserts `planes` (values then unknowns,
pub const drive = driving.drive;
/// §7.8.5 gate driver `i` of type `kind` over its input bits.
pub const gate = driving.gate;
/// §8 UDP driver `i` over its input bits (`resolution.udpValue`), any
pub const udp = driving.udp;
/// §7.6 MOS switch driver `i` (`resolution.mosValue`): its data at the data
pub const mos = driving.mos;
/// §6.5.7.1 port window driver `i`: its source's bits, z outside them.
pub const bridge = driving.bridge;
/// §19.9 `unconnected_drive` driver `i`: its level on every bit.
pub const pull = driving.pull;
/// What driver `di` asserts on bit `at` of its net (`resolution.contribution`).
pub const contribution = driving.contribution;
/// `resolution.resolve` of net `k`: every driver folded, a `trireg`'s charge
pub const resolve = resolution.resolve;
/// Bit `at` of the value whose first word is word `off` of the planes.
pub const shown = resolution.shown;
/// `State.next`'s dispatch of a `drive_base`/`net_base`/`decay_base`
pub const arrive = resolution.arrive;
/// `exec` `.switch_ctrl`: pass switch `i`'s control reads `c`, so it
pub const switchCtrl = switches.switchCtrl;
/// §14.3.3 the module path sources of `t.nets`, each with its value at time
pub const seedPaths = module_paths.seedPaths;
/// §14.3.3 slot `slot` changed: when a module path source transitions, its
pub const pathSeen = module_paths.pathSeen;

test {
    _ = layout;
    _ = driving;
    _ = resolution;
    _ = switches;
    _ = module_paths;
}
