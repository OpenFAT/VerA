//! The runtime a `vera --emit-exe design.v` executable links: the emitted
//! design (src/codegen/digital/) in, its IEEE 1364 §17 transcript on
//! stdout out (exit 0), or a diagnostic on stderr (exit 1). This file only
//! names what the emitted code and the other modules reach as `sim.rt.<name>`;
//! each name lives in the file that owns its data. The names are the emitted
//! code's ABI: renaming one is a golden change of every executable.
//! Cites: IEEE 1364-2005 §11 scheduling (§11.4.2 for the `static` order), §9.7
//! event controls, §9.2.2 nonblocking updates, §6.1 and §7.9 nets, §17 system
//! tasks, §18 VCD.
//!
//! Contents:
//! - `pub const State`, `pub fn quietState`
//! - `pub const Design`, `Dispatch`, `Sense`, `Watcher`, `settle_pc`, `Edge`, `Error`, `Reach`,
//!   `overrides`, `activations`, `prebuilt`, `budget`, `one_slot`
//! - `pub const show_base`
//! - `pub fn interpret`, `pub fn auto`, `pub fn main`, `pub fn loop`
//! - `pub fn Phase`, `pub const View`, `pub fn repeatCount`
//! - `pub const Scale`, `logic`, `net`, `vcd`, `evcd`, `engine`, `Device`

const design = @import("design.zig");
const entry = @import("main.zig");
const planes = @import("planes.zig");
/// One run of a native design (`State.zig`).
pub const State = @import("State.zig");
/// `show_base + k`: the display of `$strobe` or `$monitor` site k (`records.zig`).
pub const show_base = @import("records.zig").show_base;
/// A module's §19.8 time scale, which the emitted code passes to `$time` and delays.
pub const Scale = @import("../time.zig").Scale;
/// The four-state operators the emitted expressions call (`L`).
pub const logic = @import("logic/root.zig");
/// §7.9 net resolution of the native design.
pub const net = @import("net/root.zig");
/// §18 the value change dump, shared with the interpreter.
pub const vcd = @import("../digital/vcd.zig");
/// §18.3 the extended (ports) dump.
pub const evcd = @import("evcd.zig");
/// The prebuilt-engine seam (`prebuilt`).
pub const engine = @import("engine.zig");
/// A native design as a contract device an analog host loads.
pub const Device = @import("device.zig").Device;

/// A `State` whose effects stay inside it, its transcript in memory (`State.quietState`).
pub const quietState = State.quietState;
/// A native design's tables, emitted as constants (`design.zig`).
pub const Design = design.Design;
/// The dispatch of one phase: `Code(k).dispatch` of the emitted root.
pub const Dispatch = design.Dispatch;
/// A combinational node's read of one plane word.
pub const Sense = design.Sense;
/// One term of a triggered process.
pub const Watcher = design.Watcher;
/// What `State.next` returns for a settle event.
pub const settle_pc = design.settle_pc;
/// §5.10.1 an edge is a change toward 1 or away from 1.
pub const Edge = design.Edge;
/// Every way a run of the emitted design fails.
pub const Error = design.Error;
/// What can observe a change of a slot, per slot.
pub const Reach = design.Reach;
/// The executable's root declares `vera_overrides`.
pub const overrides = design.overrides;
/// The executable's root declares `vera_activations`.
pub const activations = design.activations;
/// The executable's root declares `vera_prebuilt_engine`.
pub const prebuilt = design.prebuilt;
/// The zero-delay-loop guard: events per tick.
pub const budget = design.budget;
/// A one-slot design for tests of the runtime.
pub const one_slot = design.one_slot;
/// `vera --run` from inside an executable: the interpreter fallback.
pub const interpret = entry.interpret;
/// The `main` of a `--state=auto` executable.
pub const auto = entry.auto;
/// The `main` of a 4-state or `--two-state` executable.
pub const main = entry.main;
/// Dispatches every event of a `State` up to a tick.
pub const loop = entry.loop;
/// The plane accessors of one phase of a `--state=auto` executable.
pub const Phase = planes.Phase;
/// A settle event's hold on a `State`'s planes.
pub const View = planes.View;
/// §9.6/§9.7.7 a `repeat` count.
pub const repeatCount = planes.repeatCount;

test {
    _ = @import("State.zig");
    _ = @import("design.zig");
    _ = @import("device.zig");
    _ = @import("records.zig");
    _ = @import("planes.zig");
    _ = @import("main.zig");
    _ = @import("stores.zig");
    _ = @import("nonblocking.zig");
    _ = @import("holds.zig");
    _ = @import("processes.zig");
    _ = @import("waiters.zig");
    _ = @import("observe.zig");
    _ = @import("transcript.zig");
    _ = @import("tasks.zig");
    _ = @import("diagnostics.zig");
    _ = logic;
    _ = net;
    _ = @import("snapshot.zig");
    _ = engine;
    _ = evcd;
    _ = @import("system.zig");
    @import("std").testing.refAllDecls(State);
}
