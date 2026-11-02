//! Contributions in, the model's logic variables out: which `nodes` rows a
//! contribution drives, the undriven signal ports (inputs) and driven rows
//! (states) whose 0/VDD assignments the truth tables enumerate, and each
//! state's potential source. Cites Verilog-AMS §5.6 (contributions),
//! §5.6.1.3 (retention), §5.6.7 (indirect assignments).
//!
//! Contents:
//! - `pub const vars_max: u8`
//! - `pub const Contrib = enum(u32)`
//! - `pub const Drive = struct`
//! - `pub const Error = error{ OutOfMemory, Refused }`
//! - `pub fn scan(scratch: Allocator, mir: *const Mir, lw: *const Lowered, pins: []const Pin, refusal: *Refusal) Error!Drive`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const ports = @import("ports.zig");
const Pin = ports.Pin;
const Refusal = @import("refusal.zig").Refusal;

/// The largest pins-plus-driven-nodes count the truth tables enumerate: the
/// analog block runs 2^n times and every table is indexed by an n-bit mask.
pub const vars_max: u8 = 20;

comptime {
    // A mask over the variables is a `u32`, and `1 << vars_max` counts them.
    assert(vars_max > 0);
    assert(vars_max < 32);
}

/// Handle to a `Lowered.contributions` row; `.none` is "no such row".
pub const Contrib = enum(u32) { none = std.math.maxInt(u32), _ };

/// The variables of the abstraction, allocated in the caller's scratch.
/// `vars.len <= vars_max` and `inputs_len <= vars.len`.
pub const Drive = struct {
    /// One bit per `nodes` row: a contribution drives it.
    driven: std.DynamicBitSetUnmanaged,
    /// `nodes` rows: the inputs (undriven signal ports, in port order), then
    /// the states (driven rows, in row order). Bit `k` of a run's mask is
    /// `vars[k]` at VDD.
    vars: []const u32,
    inputs_len: u8,
    /// Per state (`vars[inputs_len..]`): the `V(n) <+` row that may set it,
    /// the last one written, or `.none`.
    potential: []const Contrib,

    /// Returns the driven rows, `vars[inputs_len..]`.
    pub fn states(d: *const Drive) []const u32 {
        assert(d.inputs_len <= d.vars.len);
        assert(d.potential.len == d.vars.len - d.inputs_len);
        return d.vars[d.inputs_len..];
    }
};

/// Every way `scan` fails; `refusal` holds the reason of `Refused`.
pub const Error = error{ OutOfMemory, Refused };

/// Classifies every contribution in row order and lists the variables.
/// Refuses, at the first contribution that is one: an indirect assignment, a
/// row between unknowns that are not nets, a potential source from a rail
/// to a signal or between two signals; then more variables than `vars_max`.
/// `pins` has one entry per port.
pub fn scan(scratch: Allocator, mir: *const Mir, lw: *const Lowered, pins: []const Pin, refusal: *Refusal) Error!Drive {
    assert(pins.len == lw.num_ports);
    assert(lw.num_ports <= lw.nodes.len);
    const n_nodes = lw.nodes.len;
    const names = lw.nodes.items(.name);
    const kinds = lw.nodes.items(.kind);

    var driven: std.DynamicBitSetUnmanaged = try .initEmpty(scratch, n_nodes);
    // The `V(n) <+` row per `nodes` row, until the states are known.
    const source = try scratch.alloc(Contrib, n_nodes);
    @memset(source, .none);
    for (lw.contributions.items, 0..) |c, ci| {
        if (c.kind != .direct) return refusal.raise(.indirect_branch);
        for ([_]u32{ c.hi, c.lo }) |r| {
            if (r == Lowered.ground) continue;
            if (kinds[r] != .net) return refusal.raise(.{ .not_a_net = names[r] });
        }
        if (c.access == .flow) {
            for ([_]u32{ c.hi, c.lo }) |r| {
                if (r != Lowered.ground and !ports.isSupply(pins, r)) driven.set(r);
            }
            continue;
        }
        // §5.6.1.3: a row discarded on every path is no source; the flow
        // rows over its pair govern.
        if (!(staticRetention(mir, c.wrote_val) orelse true)) continue;
        const hi_rail = c.hi == Lowered.ground or ports.isSupply(pins, c.hi);
        const lo_rail = c.lo == Lowered.ground or ports.isSupply(pins, c.lo);
        // A rail against a rail is the supply itself.
        if (hi_rail and lo_rail) continue;
        if (hi_rail) return refusal.raise(.{ .potential_from_first = .{ .hi = lw.nodeName(c.hi), .lo = names[c.lo] } });
        if (!lo_rail) return refusal.raise(.{ .potential_not_rail = .{ .hi = names[c.hi], .lo = names[c.lo] } });
        source[c.hi] = @fromBackingInt(@intCast(ci));
        driven.set(c.hi);
    }

    var vars: std.ArrayList(u32) = .empty;
    for (0..lw.num_ports) |r| {
        if (!driven.isSet(r) and !ports.isSupply(pins, @intCast(r))) try vars.append(scratch, @intCast(r));
    }
    const inputs_len = vars.items.len;
    for (0..n_nodes) |r| {
        if (driven.isSet(r)) try vars.append(scratch, @intCast(r));
    }
    if (vars.items.len > vars_max) return refusal.raise(.{ .too_many_vars = .{ .count = @intCast(vars.items.len), .max = vars_max } });
    const potential = try scratch.alloc(Contrib, vars.items.len - inputs_len);
    for (potential, vars.items[inputs_len..]) |*p, r| p.* = source[r];

    const d: Drive = .{ .driven = driven, .vars = vars.items, .inputs_len = @intCast(inputs_len), .potential = potential };
    assert(d.states().len == d.vars.len - d.inputs_len);
    return d;
}

// ---- private ----

// §5.6.1.3 a direct row's retention when it is the same on every path, or
// null when it is decided per evaluation (`codegen/plan/topology.zig`'s
// `retention`, read off the MIR alone).
fn staticRetention(mir: *const Mir, v: Mir.Value) ?bool {
    return switch (mir.valueDef(mir.resolveAlias(v))) {
        .float_const => |x| x != 0,
        .int_const => |x| x != 0,
        .undef, .str_const, .param_ref, .block_param, .inst_result => null,
    };
}
