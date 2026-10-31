//! Compile facts: a compile's `Lowered` and `Mir` in, what a runner needs
//! from them out (`Facts`, the shape cards to compile again with, the
//! fixed-grid runner's W0750 warning).
//! Cites: §3.2.2, §3.4, §4.5.2, §5.10.3, §7.2.2, §8; IEEE 1364 §5.4.
//!
//! Contents:
//! - `pub fn compileFacts(arena: Allocator, lowered: *const Lowered, mir: *const Mir) Allocator.Error!Facts`
//! - `pub fn shapeCards(arena: Allocator, params: []const Binding, lowered: *const Lowered) Allocator.Error![]const Lowered.ParamOverride`
//! - `pub fn memBytes(lowered: *const Lowered) u64`
//! - `pub fn opStates(arena: Allocator, lowered: *const Lowered) Allocator.Error![]const u32`
//! - `pub fn mixedPlan(lowered: *const Lowered, mir: *const Mir) ?Mixed`
//! - `pub fn warnGridEvents(bag: *diag.Bag, lowered: *const Lowered, mir: *const Mir) Allocator.Error!void`

const std = @import("std");
const diag = @import("diag");
const ir = @import("ir");
const spec = @import("spec.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Lowered = ir.Lowered;
const Mir = ir.Mir;
const Binding = spec.Binding;
const Facts = spec.Facts;
const Mixed = spec.Mixed;

/// Returns the three facts every runner caller takes from one compile
/// (`mixed`, `op_states`, `mem_bytes`); the caller sets the switches.
/// `op_states` is allocated in `arena`; `mixed` borrows from `lowered` and `mir`.
pub fn compileFacts(arena: Allocator, lowered: *const Lowered, mir: *const Mir) Allocator.Error!Facts {
    const facts: Facts = .{
        .mixed = mixedPlan(lowered, mir),
        .op_states = try opStates(arena, lowered),
        .mem_bytes = memBytes(lowered),
    };
    assert(facts.op_states.len <= lowered.nodes.len);
    assert((facts.mixed != null) == lowered.mixed_signal);
    return facts;
}

/// Returns the `params` cards that name a shape parameter of `lowered`
/// (`ParamInfo.shape`, §3.4), allocated in `arena`. A shape parameter is fixed
/// at compile time, so a non-empty result means the caller compiles again
/// with it as `Options.param_overrides`, as `--param` would.
pub fn shapeCards(arena: Allocator, params: []const Binding, lowered: *const Lowered) Allocator.Error![]const Lowered.ParamOverride {
    var out: std.ArrayList(Lowered.ParamOverride) = .empty;
    for (params) |card| for (lowered.params.items) |p| {
        if (p.shape and std.mem.eql(u8, p.name, card.name)) try out.append(arena, .{ .name = card.name, .value = card.value });
    };
    assert(out.items.len <= params.len * lowered.params.items.len);
    if (lowered.params.items.len == 0) assert(out.items.len == 0);
    return out.items;
}

/// Returns the bytes of `lowered`'s §3.2.2 memory-backed arrays
/// (`Facts.mem_bytes`): eight per element, real or integer. Plus the
/// IEEE 1364 §5.4 wide temporaries (`wide_kernels.zig`): one value per node
/// of every sized tree and the division's scratch, three values' bytes per
/// node (docs/specification/Vague_Decisions.md §7, "wide `reg` temporaries").
pub fn memBytes(lowered: *const Lowered) u64 {
    var n: u64 = 0;
    for (lowered.mem_arrays.items) |m| n += 8 * @as(u64, m.len);
    const arrays = n;
    for (lowered.wide_nodes.items) |w| n += 3 * 4 * ((@as(u64, w.width) + 31) / 32);
    assert(n >= arrays);
    assert(n % 4 == 0);
    return n;
}

/// Returns the `U` indices of the §4.5.2 operator unknowns
/// (`Facts.op_states`), ascending, allocated in `arena`.
pub fn opStates(arena: Allocator, lowered: *const Lowered) Allocator.Error![]const u32 {
    const kinds = lowered.nodes.items(.kind);
    var n: usize = 0;
    for (kinds) |k| n += @intFromBool(k == .op_state);
    const out = try arena.alloc(u32, n);
    n = 0;
    for (kinds, 0..) |k, i| switch (k) {
        .op_state => {
            out[n] = @intCast(i);
            n += 1;
        },
        .net, .branch_flow, .port_flow => {},
    };
    assert(n == out.len);
    // Ascending, as `Facts.op_states` promises.
    for (out[0..n -| 1], out[@min(n, 1)..]) |a, b| assert(a < b);
    return out;
}

/// Returns the mixed-signal plan of a compile, or null for a module with no
/// discrete half that needs the event queue (`Lowered.mixed_signal`). The
/// slices borrow from `lowered` and `mir`.
pub fn mixedPlan(lowered: *const Lowered, mir: *const Mir) ?Mixed {
    if (!lowered.mixed_signal) return null;
    const plan: Mixed = .{
        .source = lowered.src,
        .top = mir.name,
        .timescales = lowered.timescales,
        .inputs = lowered.discrete_inputs.keys(),
        .snaps = lowered.discrete_snaps.keys(),
        .xz = lowered.discrete_xz.keys(),
        .wide = lowered.discrete_words.keys(),
        .words = lowered.discrete_words.values(),
        .events = lowered.discrete_events.values(),
        .inserts = lowered.inserts,
        .reads = lowered.discrete_reads.keys(),
        .probe_names = lowered.discrete_probes.keys(),
        .probe_nodes = lowered.discrete_probes.values(),
        .held = lowered.held_vars.items,
        .params = lowered.params.items,
        .param_reads = lowered.discrete_params.keys(),
    };
    assert(plan.wide.len == plan.words.len);
    assert(plan.probe_names.len == plan.probe_nodes.len);
    return plan;
}

/// Adds W0750 to `bag` at the first §5.10.3 `cross`, `above` or `timer` call
/// when the module gets the fixed-grid runner (`mixedPlan` is null), which
/// inserts no timepoint: such an event fires at the first `//! time` point
/// past its own time. Adds nothing for a mixed-signal module.
pub fn warnGridEvents(bag: *diag.Bag, lowered: *const Lowered, mir: *const Mir) Allocator.Error!void {
    if (lowered.mixed_signal) return;
    const blocks = mir.blockCount();
    for (0..blocks) |bi| {
        var insts = mir.blockInsts(@fromBackingInt(@intCast(bi)));
        while (insts.next()) |inst| {
            if (mir.instOp(inst) != .call or mir.instTok(inst) == Mir.no_tok) continue;
            const k = Mir.callee.opKind(mir.instData(inst).call.callee);
            if (k == .cross or k == .above or k == .timer)
                return bag.add(.codegen, .W0750, lowered.tokenSpan(mir.instTok(inst)), "the testbench inserts no timepoint at it", .{});
        }
    }
    assert(blocks == mir.blockCount());
}
