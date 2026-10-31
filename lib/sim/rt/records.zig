//! The `State`'s own row types (suspensions, terms, nonblocking rows,
//! activations, holds) and the scheduler payload map: which `u32` payload
//! names which kind of event. No logic.
//! Cites: IEEE 1364-2005 §9.2.2, §9.3, §9.7.2, §9.7.3, §10.2.3, §17.1.3, §18.
//!
//! Contents:
//! - `pub const Susp = struct`
//! - `pub const Act = struct`
//! - `pub const Resume = struct`
//! - `pub const EventSelect`
//! - `pub const Term = struct`
//! - `pub const Rec = struct`
//! - `pub const no_rec`
//! - `pub const Nba = struct`
//! - `pub const Late = struct`
//! - `pub const nba_payload: u32`
//! - `pub const settle_payload: u32`
//! - `pub const monitor_payload: u32`
//! - `pub const vcd_payload: u32`
//! - `pub const show_base: u32`
//! - `pub const late_base: u32`
//! - `pub const resume_base: u32`
//! - `pub const Layers = struct`
//! - `pub const Range = struct`
//! - `pub const Part = struct`

const std = @import("std");
const assert = std.debug.assert;
const State = @import("State.zig");
const design = @import("design.zig");
const Edge = design.Edge;
const Error = design.Error;

/// `waiters.Susp`: where the process resumes, in which §10.2.3 activation
/// (`State.ctx`, 0 for none). `seq` is its `State.stamp`.
pub const Susp = struct { pc: u32, gen: u32, ctx: u32 = 0, alive: bool, seq: u64 = 0 };

/// `exec.Act`: one activation of a timed task that reaches itself, entered
/// by `State.callTimed`. Its caller resumes at `ret_pc` in `ret_ctx`; an
/// automatic task's frame is the `n` plane words from `lo`, kept in
/// `storage` (both planes) while another activation of it is resident.
pub const Act = struct { sub: u32, ret_pc: u32, ret_ctx: u32, lo: u32, n: u32, storage: []u64 = &.{} };

/// A process continuation queued inside an activation (`exec.Pending`'s
/// `resume`); its scheduler payload is `resume_base` + its row.
pub const Resume = struct { pc: u32, ctx: u32, live: bool };

/// §9.7.3: the event element selected now, or null for an invalid index.
/// The emitted function reads the declaring scope's slots in the active
/// logic phase. Its address is immutable across a saved tick boundary.
pub const EventSelect = fn (*State) Error!?u32;

/// One event-control term of suspension `susp`, filed under a slot: live
/// while `gen` equals the suspension's; `rec` names its select bits.
pub const Term = struct { susp: u32, gen: u32, edge: Edge, select: ?*const EventSelect = null, rec: u32 = no_rec };

/// §9.7.2 a constant select term's bits: `width` of them from bit `shift`
/// of plane word `word` on, and their value when last tested.
pub const Rec = struct { word: u32, shift: u6, width: u7, v: u64, x: u64 };

/// `Term.rec` of a term that watches its whole slot.
pub const no_rec = std.math.maxInt(u32);

/// One §9.2.2 nonblocking update: the bits `m` of `slot` (words from
/// `off`) become `v`/`x` when it matures, merged into the value the slot
/// holds then. `v`, `x` and `m` are `n` words each: the row's own `one`
/// for a single word, else at `words[at..]`. A `quiet` slot has nothing to
/// wake. A real row compares numeric values when it arrives (§4.8).
pub const Nba = struct { slot: u32, off: u32, n: u32, at: u32, quiet: bool, real: bool, one: [3]u64 = undefined };

/// An `Nba` in flight past this timestep, owning its `v`, `x`, `m` words.
pub const Late = struct { slot: u32, off: u32, n: u32, real: bool, words: []u64 };

/// The scheduler payload of the one NBA-region event that applies every
/// row in `rows`, in order: the interpreter's one event per row, which the
/// scheduler promotes together, with nothing between them.
pub const nba_payload: u32 = 1 << 31;

/// The payload of a settle event.
pub const settle_payload: u32 = nba_payload | 1;

/// The payload of the one §17.1.3 monitor event of a timestep.
pub const monitor_payload: u32 = nba_payload | 2;

/// The payload of the one §18 dump event of a timestep.
pub const vcd_payload: u32 = nba_payload | 3;

/// `show_base + k`: the display of `$strobe` or `$monitor` site k, which
/// `next` returns for the design to print. Every payload below is a pc.
pub const show_base: u32 = 1 << 30;

/// `late_base + k`: delayed nonblocking update `late[k]` (§9.2.2 `<= #d`).
pub const late_base: u32 = 3 << 30;

/// `resume_base + k`: process continuation `resumes[k]`, in an activation.
pub const resume_base: u32 = 5 << 29;

/// `root.Overrides`: the process ranges of a slot's `assign` and `force`.
pub const Layers = struct { assign: ?Range = null, force: ?Range = null };

/// The pcs `[start, end)` of one procedural continuous assignment's process.
pub const Range = struct { start: u32, end: u32 };

/// The force of one constant select of a net (§9.3.2), holding bits
/// [lo, lo + width) while `range` is set; `emit` numbers the distinct
/// selects (`Design.part_start`).
pub const Part = struct { lo: u32 = 0, width: u32 = 0, range: ?Range = null };

// The payload map, in the order `State.next` tests it: a pc below
// `show_base`, a display site, a net event (`net/layout.zig`'s bases, all
// `show_base | k << 28` for k in 1..3), the one-per-step events at
// `nba_payload`, then the activation and delayed-update bands.
comptime {
    assert(show_base < nba_payload);
    assert(vcd_payload < resume_base);
    assert(resume_base < late_base);
    assert(show_base | 3 << 28 < nba_payload);
}
