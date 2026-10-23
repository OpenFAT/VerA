//! The simulators behind `vera --run` and `--emit-exe`: the IEEE 1364 event
//! scheduler and interpreter (`digital`), the native executable's runtime
//! (`rt`), the VAMS §8 mixed-signal coordinator (`mixed`), and the shared
//! time scale (`time`). The §17.1 value text both engines print is
//! `kernels.fmt`.
//!
//! Every declaration here is reached from outside the module: `src/main.zig`,
//! `src/vpi/`, `src/codegen/exe/tb*`, `tests/`, and the Zig text that
//! `src/zigbuild/orchestrator.zig` and `src/codegen/digital/emit.zig` generate (`sim.rt`,
//! `sim.digital`, `sim.mixed`). The generated text is why a rename here is a
//! golden change, not only a compile error.
//! Clauses: none here; each file's header names the ones its code cites.

/// IEEE 1364-2005 elaboration and the event-driven interpreter (`Run`).
pub const digital = @import("digital/root.zig");
/// Timescale factors and the analog-time-to-tick mapping (§19.8, VAMS §7.3.6.5).
pub const time = @import("time.zig");
/// The region-ordered event queue (IEEE 1364-2005 §11, VAMS §8.5).
pub const scheduler = @import("scheduler.zig");
/// The VAMS §8 coordinator that steps a digital `Run` beside an analog solver.
pub const mixed = @import("mixed.zig");
/// The runtime an `--emit-exe` executable links: native designs and devices.
pub const rt = @import("rt/root.zig");

test {
    _ = scheduler;
    _ = time;
    _ = digital;
    _ = mixed;
    _ = rt;
}
