//! Samples in, one logic function per state out: the bit each assignment
//! settles the state to, the variables that bit depends on, and the state's
//! rise and fall delays; then which states reach a digital output.
//!
//! A flow state settles where its residual crosses zero, read with its own
//! potential at 0 and at VDD: F = -S(0)·VDD/(S(VDD)-S(0)), with time constant
//! tau = ΔQ/ΔS (exact for an RC, a secant for anything else). A retained
//! potential row sets F directly. The bit is F > VDD/2, reached tau·ln2 later
//! (the 50 % crossing of a rail-to-rail RC step) plus the row's td. Cites
//! Verilog-AMS §5.6 (KCL), §5.6.1.2 (charge), §5.6.1.3 (retention), §4.5.7,
//! §4.5.8 (td).
//!
//! Contents:
//! - `pub const Bit = enum(u8)`
//! - `pub const Settled = struct`
//! - `pub fn Settled.table(s: *const Settled, state: usize) []const Bit`
//! - `pub const Error = error{ OutOfMemory, Refused }`
//! - `pub fn settle(scratch: Allocator, samples: *const Samples, drive: *const Drive, names: []const []const u8, delays: *const Delays, vdd: f64, refusal: *Refusal) Error!Settled`
//! - `pub fn liveStates(settled: *const Settled, drive: *const Drive, pins: []const Pin) u32`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ports = @import("ports.zig");
const Pin = ports.Pin;
const Delays = ports.Delays;
const drive_ = @import("drive.zig");
const Drive = drive_.Drive;
const vars_max = drive_.vars_max;
const Samples = @import("sample.zig").Samples;
const Refusal = @import("refusal.zig").Refusal;

/// A state's settled logic value; `x` when it settles at VDD/2 (within
/// 1e-9·VDD), which is no logic level.
pub const Bit = enum(u8) { @"0", @"1", x };

/// One row per state (`Drive.states`), every column in the caller's scratch.
pub const Settled = struct {
    /// The rising delay (s): the longest over the assignments that settle
    /// at 1, or the `vera_delay`. Finite in ns.
    rise_s: []f64,
    /// The falling delay (s), likewise over those that settle at 0.
    fall_s: []f64,
    /// The variables (bits of a mask over `Drive.vars`) the bit depends on.
    support: []u32,
    /// The state's truth table over its support alone: entry `sub` is the
    /// bit with the support's `j`-th variable at bit `j` of `sub`, every
    /// other variable at 0. State `si`'s at `bits[starts[si]..starts[si + 1]]`.
    starts: []u32,
    bits: []const Bit,

    /// Returns the truth table of `state`, `1 << popCount(support[state])` long.
    pub fn table(s: *const Settled, state: usize) []const Bit {
        const t = s.bits[s.starts[state]..s.starts[state + 1]];
        assert(t.len == @as(usize, 1) << @intCast(@popCount(s.support[state])));
        return t;
    }
};

/// Every way `settle` fails; `refusal` holds the reason of `Refused` (the
/// first state's first mask that is one, in row and mask order).
pub const Error = error{ OutOfMemory, Refused };

/// Derives every state's logic function from `samples`. `names` is the
/// `Lowered.nodes` name column; `delays` replaces a named state's delay.
/// Refuses a state whose potential row is retained at one end of its own
/// swing only, whose current does not move with its potential, whose
/// settled potential is not finite, or whose delay has no finite ns value
/// and no `vera_delay`. Costs O(vars · 2^vars) per state.
pub fn settle(scratch: Allocator, samples: *const Samples, drive: *const Drive, names: []const []const u8, delays: *const Delays, vdd: f64, refusal: *Refusal) Error!Settled {
    const states = drive.states();
    const nv = drive.vars.len;
    assert(nv <= vars_max);
    assert(samples.masks == @as(u32, 1) << @intCast(nv));
    var s: Settled = .{
        .rise_s = try scratch.alloc(f64, states.len),
        .fall_s = try scratch.alloc(f64, states.len),
        .support = try scratch.alloc(u32, states.len),
        .starts = try scratch.alloc(u32, states.len + 1),
        .bits = &.{},
    };
    var bits: std.ArrayList(Bit) = .empty;
    // One state's full table, every mask; reused.
    const target = try scratch.alloc(Bit, samples.masks);
    const ln2 = @log(2.0);
    for (states, 0..) |r, si| {
        const own = @as(u32, 1) << @intCast(drive.inputs_len + si);
        const fixed = delays.get(names[r]);
        var rise: f64 = 0;
        var fall: f64 = 0;
        for (target, 0..) |*t, mi| {
            const m: u32 = @intCast(mi);
            // This state's row under `m`, and with its own bit low and high.
            const at = samples.at(si, m);
            const lo = samples.at(si, m & ~own);
            const hi = samples.at(si, m | own);
            var f: f64 = undefined;
            var tau: f64 = 0;
            if (samples.retained.isSet(at)) {
                f = samples.current[at];
            } else if (samples.retained.isSet(lo) or samples.retained.isSet(hi)) {
                // The secant needs one constitutive law at both ends.
                return refusal.raise(.{ .retention_self = names[r] });
            } else {
                const a = (samples.current[hi] - samples.current[lo]) / vdd;
                if (!(a != 0) or !std.math.isFinite(a)) return refusal.raise(.{ .settles_nowhere = names[r] });
                f = -samples.current[lo] / a;
                tau = @abs((samples.charge[hi] - samples.charge[lo]) / vdd / a);
            }
            if (!std.math.isFinite(f)) return refusal.raise(.{ .potential_not_finite = names[r] });
            t.* = if (@abs(f - vdd / 2) <= 1e-9 * vdd) .x else if (f > vdd / 2) .@"1" else .@"0";
            const d = tau * ln2 + samples.delay_s[at];
            // A NaN or infinite charge or td (a `--param c=inf`) has no
            // delay to print; a `vera_delay` replaces it, so is not asked.
            if (t.* != .x and fixed == null and !std.math.isFinite(d * 1e9))
                return refusal.raise(.{ .delay_not_finite = .{ .node = names[r], .seconds = d } });
            switch (t.*) {
                .@"1" => rise = @max(rise, d),
                .@"0" => fall = @max(fall, d),
                .x => {},
            }
        }
        s.rise_s[si] = fixed orelse rise;
        s.fall_s[si] = fixed orelse fall;
        s.support[si] = supportOf(target, @intCast(nv));
        s.starts[si] = @intCast(bits.items.len);
        try appendTable(scratch, &bits, target, s.support[si]);
    }
    s.starts[states.len] = @intCast(bits.items.len);
    s.bits = bits.items;
    for (0..states.len) |si| assert(s.table(si).len > 0);
    return s;
}

/// Returns the states (bit `si` of the result) that reach a digital output:
/// the digital ports themselves, and every state some live state's support
/// reads. A driven analog port or an internal net nothing logic reads is
/// dead.
pub fn liveStates(settled: *const Settled, drive: *const Drive, pins: []const Pin) u32 {
    const states = drive.states();
    assert(settled.support.len == states.len);
    assert(states.len <= vars_max);
    var live: u32 = 0;
    for (states, 0..) |r, si| {
        if (r < pins.len and pins[r] == .digital) live |= @as(u32, 1) << @intCast(si);
    }
    // Each round that continues marks at least one more state live.
    var rounds: usize = 0;
    while (true) : (rounds += 1) {
        assert(rounds <= states.len);
        var reached = live;
        for (settled.support, 0..) |support, si| {
            if (live >> @intCast(si) & 1 == 1) reached |= support >> @intCast(drive.inputs_len);
        }
        if (reached == live) break;
        live = reached;
    }
    assert(live >> @intCast(states.len) == 0);
    return live;
}

// ---- private ----

/// The variables a full table depends on: bit `k` when flipping variable `k`
/// changes some entry.
fn supportOf(target: []const Bit, nv: u8) u32 {
    assert(target.len == @as(usize, 1) << @intCast(nv));
    var support: u32 = 0;
    for (0..nv) |k| {
        const b = @as(usize, 1) << @intCast(k);
        for (target, 0..) |t, m| if (t != target[m ^ b]) {
            support |= @as(u32, 1) << @intCast(k);
            break;
        };
    }
    assert(@popCount(support) <= nv);
    return support;
}

/// Appends `target` restricted to `support`: one entry per assignment of the
/// support's variables, the rest at 0.
fn appendTable(scratch: Allocator, bits: *std.ArrayList(Bit), target: []const Bit, support: u32) Allocator.Error!void {
    const width: u5 = @intCast(@popCount(support));
    const len_before = bits.items.len;
    for (0..@as(usize, 1) << width) |sub| {
        var m: usize = 0;
        var rest = support;
        var j: u5 = 0;
        while (rest != 0) : (j += 1) {
            const v = @ctz(rest);
            rest &= rest - 1;
            if (sub >> j & 1 == 1) m |= @as(usize, 1) << @intCast(v);
        }
        try bits.append(scratch, target[m]);
    }
    assert(bits.items.len - len_before == @as(usize, 1) << width);
}

test supportOf {
    // Spec examples: a buffer of variable 0 over two variables, a constant,
    // and an XOR, which depends on both.
    try std.testing.expectEqual(@as(u32, 0b01), supportOf(&.{ .@"0", .@"1", .@"0", .@"1" }, 2));
    try std.testing.expectEqual(@as(u32, 0b00), supportOf(&.{ .x, .x, .x, .x }, 2));
    try std.testing.expectEqual(@as(u32, 0b11), supportOf(&.{ .@"0", .@"1", .@"1", .@"0" }, 2));
}

test appendTable {
    // Round trip: a table over variables {0, 2} of three, read back at
    // masks 0b000, 0b001, 0b100, 0b101.
    const full = [_]Bit{ .@"0", .@"1", .x, .x, .@"1", .@"0", .x, .x };
    var bits: std.ArrayList(Bit) = .empty;
    defer bits.deinit(std.testing.allocator);
    try appendTable(std.testing.allocator, &bits, &full, 0b101);
    try std.testing.expectEqualSlices(Bit, &.{ .@"0", .@"1", .@"1", .@"0" }, bits.items);
}
