//! Every allocation of the prove passes fails once (`checkAllAllocationFailures`):
//! each pass returns `error.OutOfMemory` without swallowing it or leaking.
//! No LRM clause: this checks VerA's own passes.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const diag = @import("diag");
const Analysis = @import("prove").Analysis;
const ifconv = @import("prove").ifconv;
const proof = @import("prove").proof;
const setup = @import("prove").setup;
const timepoint = @import("prove").timepoint;
const held = @import("prove").held;
const Input = @import("prove").Input;

// ---- private ----

/// A diamond on a probe with a `sqrt` arm and a `$held_real` slot, through
/// every pass in `src/Compilation.zig`'s order.
fn passes(gpa: std.mem.Allocator) !void {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var mir: Mir = .{};
    var lw: Lowered = .{};
    try lw.nodes.append(a, .{ .name = "a", .kind = .net, .disc = "", .dir = .unspecified });
    const entry = try mir.addBlock(a);
    const t = try mir.addBlock(a);
    const e = try mir.addBlock(a);
    const j = try mir.addBlock(a);
    const p = try mir.addBlockParam(a, 0);
    const seed = try mir.emitCall(a, entry, try mir.internString(a, "$held_real"), &.{.zero});
    try lw.held_vars.append(a, .{ .name = "h", .ty = .real, .init = .f_zero, .seed = seed, .final = seed, .why = .unless_invariant });
    const c = try mir.emit(a, entry, .fgt, &.{ p, .f_zero });
    _ = try mir.emitBranch(a, entry, c, t, e);
    const tv = try mir.emit(a, t, .sqrt, &.{p});
    _ = try mir.emitJump(a, t, j);
    const ev = try mir.emit(a, e, .fmul, &.{ p, seed });
    _ = try mir.emitJump(a, e, j);
    const out = try mir.emitPhi(a, j, &.{ .{ .block = t, .value = tv }, .{ .block = e, .value = ev } });
    try lw.contributions.append(a, .{ .access = .flow, .hi = @fromBackingInt(0), .lo = @fromBackingInt(0), .resist_val = out });

    if (try held.prune(a, &mir, &lw)) |keep| std.debug.assert(keep.len == 1);
    _ = try ifconv.run(a, &mir, .pure, null);
    var bag = diag.Bag.init(a);
    const v = try proof.prove(gpa, &mir, &lw, .{}, &bag);
    defer v.deinit(gpa);
    var keep = try ifconv.keepSlice(a, &mir, &.{out});
    _ = try ifconv.run(a, &mir, .speculate, &keep);
    const an = try Analysis.build(a, &mir, &lw);
    const in: Input = .{ .arena = a, .mir = &mir, .an = &an, .lowered = &lw };
    _ = try setup.plan(in);
    _ = try timepoint.varying(in, .{ .tok = 0, .miss = t, .join = j });
}

test "prove passes: every allocation failure is reported, none leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, passes, .{});
}
