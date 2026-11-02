//! The variables in, one analog run per assignment of them out: for every
//! state and every mask (each variable at 0 or VDD), the state's KCL residual,
//! charge and transition delay, or its potential target. Cites Verilog-AMS
//! §5.6 (KCL residual), §5.6.1.2 (charge), §5.6.1.3 (which row is retained).
//!
//! Contents:
//! - `pub const Samples = struct`
//! - `pub fn Samples.at(s: *const Samples, state: usize, mask: u32) usize`
//! - `pub const Error = error{ OutOfMemory, Refused }`
//! - `pub fn sample(scratch: Allocator, mir: *const Mir, lw: *const Lowered, pins: []const Pin, drive: *const Drive, vdd: f64, refusal: *Refusal) Error!Samples`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const Pin = @import("ports.zig").Pin;
const Drive = @import("drive.zig").Drive;
const vars_max = @import("drive.zig").vars_max;
const Interp = @import("Interp.zig");
const Refusal = @import("refusal.zig").Refusal;

/// One row per (state, mask), state-major (`at`), so `settle` walks one
/// state's masks contiguously. Every column lives in the caller's scratch.
pub const Samples = struct {
    /// `1 << vars.len`: the assignments run.
    masks: u32,
    /// Flow rows: the residual S (A) with the state at its mask's value.
    /// Potential rows: the target potential (V).
    current: []f64,
    /// The charge Q (C) of the flow rows; 0 for a potential row.
    charge: []f64,
    /// The longest `transition`/`absdelay` td (s) the row read through; NaN
    /// when a td was.
    delay_s: []f64,
    /// The state's potential row was retained (§5.6.1.3) in this run, so
    /// `current` is its target.
    retained: std.DynamicBitSetUnmanaged,

    /// Returns the row of `state` under `mask`.
    pub fn at(s: *const Samples, state: usize, mask: u32) usize {
        assert(mask < s.masks);
        const row = state * s.masks + mask;
        assert(row < s.current.len);
        return row;
    }
};

/// Every way `sample` fails; `refusal` holds the reason of `Refused` (the
/// first run's first refusal, in mask order).
pub const Error = error{ OutOfMemory, Refused };

/// Each state's flow contributions, in contribution order: CSR, state `si`'s
/// entries at `entries[starts[si]..starts[si + 1]]`.
const FlowRows = struct {
    starts: []u32,
    /// `Lowered.contributions` rows.
    entries: []const u32,
};

/// Runs the analog block once per mask over `drive.vars`, supplies at their
/// rails, and records every state's row. Costs 2^vars runs; `scratch` holds
/// 24 bytes and a bit per row.
pub fn sample(scratch: Allocator, mir: *const Mir, lw: *const Lowered, pins: []const Pin, drive: *const Drive, vdd: f64, refusal: *Refusal) Error!Samples {
    assert(drive.vars.len <= vars_max);
    assert(pins.len == lw.num_ports);
    const states = drive.states();
    const contribs = lw.contributions.items;
    const masks = @as(u32, 1) << @intCast(drive.vars.len);
    const rows = @as(usize, masks) * states.len;
    var s: Samples = .{
        .masks = masks,
        .current = try scratch.alloc(f64, rows),
        .charge = try scratch.alloc(f64, rows),
        .delay_s = try scratch.alloc(f64, rows),
        .retained = try .initEmpty(scratch, rows),
    };
    const flows = try flowRows(scratch, contribs, states);

    // Supplies sit at their rails and the variables are set per run; every
    // other row is NaN, which `Interp.get` refuses to read.
    const volts = try scratch.alloc(f64, lw.nodes.len);
    @memset(volts, std.math.nan(f64));
    for (pins, volts[0..pins.len]) |p, *v| v.* = switch (p) {
        .power => vdd,
        .ground => 0,
        .digital, .analog => std.math.nan(f64),
    };
    var in: Interp = try .init(scratch, mir, lw, volts, refusal);
    for (0..masks) |m| {
        for (drive.vars, 0..) |r, k| volts[r] = if (m >> @intCast(k) & 1 == 1) vdd else 0;
        try in.run();
        for (states, drive.potential, 0..) |r, source, si| {
            const row = s.at(si, @intCast(m));
            var current: f64 = 0;
            var charge: f64 = 0;
            var delay_s: f64 = 0;
            const retained = if (source == .none) false else (try in.get(contribs[@backingInt(source)].wrote_val)).c.isTrue();
            if (retained) {
                const c = contribs[@backingInt(source)];
                assert(c.hi == r);
                const f = try in.get(c.resist_val);
                current = f.c.asReal() + if (c.lo == Lowered.ground) 0 else volts[c.lo];
                delay_s = f.d;
            } else for (flows.entries[flows.starts[si]..flows.starts[si + 1]]) |ci| {
                const c = contribs[ci];
                const sign: f64 = if (c.hi == r) 1 else -1;
                const rv = try in.get(c.resist_val);
                const qv = try in.get(c.react_val);
                current += sign * rv.c.asReal();
                charge += sign * qv.c.asReal();
                delay_s = Interp.later(delay_s, Interp.later(rv.d, qv.d));
            }
            s.current[row] = current;
            s.charge[row] = charge;
            s.delay_s[row] = delay_s;
            s.retained.setValue(row, retained);
        }
    }
    assert(s.current.len == rows);
    assert(s.retained.bit_length == rows);
    return s;
}

// ---- private ----

fn flowRows(scratch: Allocator, contribs: []const Lowered.Contribution, states: []const u32) Allocator.Error!FlowRows {
    assert(states.len <= vars_max);
    const starts = try scratch.alloc(u32, states.len + 1);
    var entries: std.ArrayList(u32) = .empty;
    for (states, 0..) |r, si| {
        starts[si] = @intCast(entries.items.len);
        for (contribs, 0..) |c, ci| {
            if (c.access != .flow or (c.hi != r and c.lo != r)) continue;
            try entries.append(scratch, @intCast(ci));
        }
    }
    starts[states.len] = @intCast(entries.items.len);
    assert(starts[0] == 0);
    assert(entries.items.len <= contribs.len * states.len);
    return .{ .starts = starts, .entries = entries.items };
}
