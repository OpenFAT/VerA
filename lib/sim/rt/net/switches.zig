//! A pass switch's control change in, the switch group re-resolved out (§7.6 bidirectional switches).
//! Cites: IEEE 1364-2005 §7.6, §7.11.
//!
//! Contents:
//! - `pub fn switchCtrl(s: *State, i: u32, c: Bit) Error!void`
//! - `pub fn wakeSwitchesOn(s: *State, k: u32) Error!void`

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const dnet = @import("../../digital/net.zig");
const Handle = @import("../../scheduler.zig").Handle;
const design = @import("../design.zig");
const State = @import("../State.zig");
const Error = design.Error;
const logic = @import("../logic/root.zig");
const Bit = logic.Bit;
const Signal = dnet.Signal;
const testing = std.testing;
const driving = @import("driving.zig");
const layout = @import("layout.zig");
const resolution = @import("resolution.zig");
const int = driving.int;
const mos = driving.mos;
const resolve = resolution.resolve;
const tran_base = layout.tran_base;

/// `exec` `.switch_ctrl`: pass switch `i`'s control reads `c`, so it
/// conducts, does not, or may (x or z); both sides re-resolve now, or after
/// the switch's delay (`switchAfter`).
pub fn switchCtrl(s: *State, i: u32, c: Bit) Error!void {
    const t = &s.nets;
    const tr = t.trans[i];
    const cb = int(c);
    const next: dnet.Tran.State = if (cb == int(tr.on)) .on else if (cb == .zero or cb == .one) .off else .unknown;
    if (tr.delay.present) return switchAfter(s, i, next);
    t.tstate[i] = next;
    try resolve(s, tr.a);
    try resolve(s, tr.b);
}

/// IEEE 1364-2005 §7.11: a MOS switch passes its data's strength, so when
/// net `k`'s bit 0 changes strength alone, which no event control sees, the
/// switches reading it re-evaluate on the bits they last read
/// (`waiters.wakeSwitches`). Only they: re-running a delayed driver would
/// restart its inertial delay.
pub fn wakeSwitchesOn(s: *State, k: u32) Error!void {
    const t = &s.nets;
    for (t.mos_ix) |i| if (t.drivers[i].source.mos.data_net == k) if (t.mos_in[i]) |in| try mos(s, i, in[0], in[1]);
}

// ---- private ----

/// `resolution.switchAfter`: a controlled switch with a delay turns on after the
/// first, off after the second, and to unknown conduction after the
/// smaller; a control that returns before its change lands cancels it.
fn switchAfter(s: *State, i: u32, next: dnet.Tran.State) Error!void {
    const t = &s.nets;
    const settled = if (t.tpending[i] != null) t.ttarget[i] else t.tstate[i];
    if (settled == next) return;
    if (t.tpending[i]) |h| _ = s.sched.cancel(h) catch |e| return s.schedFail(e);
    t.tpending[i] = null;
    if (next == t.tstate[i]) return;
    t.ttarget[i] = next;
    const to: Int.Bit = switch (next) {
        .on => .one,
        .off => .zero,
        .unknown => .x,
    };
    t.tpending[i] = s.sched.scheduleAfter(s.gpa, t.trans[i].delay.to(to), .inactive, tran_base + i) catch |e| return s.timeFail(e);
}
