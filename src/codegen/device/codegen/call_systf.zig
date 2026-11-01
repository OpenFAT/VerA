//! A §2.8.3/§12.32 user system function or task call -> its hand-off to the
//! host's VPI application (`zs<label>: { ... }` over f64 values and partials),
//! its §12.22.2 output arguments, and the `systf_calls` table that numbers every
//! such call for the host.
//! Cites: §2.8.3, §12.22.2, §12.32, §12.32.1.
//!
//! Contents:
//! - `pub fn emitSystfTable(self: *Gen) Error!void`
//! - `pub fn emitUnregistered(self: *Gen, inst: Mir.Inst, name: []const u8, args: []const Mir.Value) Error!void`
//! - `pub fn emitSystfOut(self: *Gen, args: []const Mir.Value) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_mask = @import("mask.zig");
const gen_render = @import("render.zig");
const family = @import("family.zig");
const Mir = @import("ir").Mir;
const Error = codegen.Error;
const gen_call = @import("call.zig");

/// Writes `systf_calls`, the `$name` calls this device leaves to a VPI
/// application, one per source call. Call after every unit is emitted:
/// `emitCall` fills the set.
/// Invalidates slices of `out.items` if additional memory is needed.
/// Asserts that every recorded call is named.
pub fn emitSystfTable(self: *Gen) Error!void {
    if (self.systf_names.items.len == 0) return;
    try self.w(
        \\/// §2.8.3 `$name`s this device leaves to a VPI application
        \\/// (§12.32 `vpi_register_analog_systf`), one per call site. Position k
        \\/// is the `k` the device passes to `Instance.systf.?.call`. A host
        \\/// linking this device shall bind them — see `contract.validateHost`.
        \\pub const systf_calls = [_]contract.Systf{{
        \\
    , .{});
    // §12.22.2 each call's output arguments: every `$systf$out` lowering
    // made, rendered or not, so the set is the source's and not the plan's.
    const outs = try self.arena.alloc(u64, self.systf_names.items.len);
    @memset(outs, 0);
    for (0..self.mir.instCount()) |ii| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(ii));
        if (self.mir.instOp(inst) != .call) continue;
        const d = self.mir.instData(inst).call;
        if (d.callee != .@"$systf$out") continue;
        const c = systfOutCall(self, d.args) orelse continue;
        if (c.j > 64) continue;
        assert(c.j >= 1); // `systfOutCall` refuses position 0
        for (self.systf_names.items, outs) |n, *o| {
            if (n.tok == c.tok and std.mem.eql(u8, n.name, c.name)) o.* |= @as(u64, 1) << @intCast(c.j - 1);
        }
    }
    for (self.systf_names.items, outs) |n, o| {
        assert(n.name.len != 0);
        try self.w("    .{{ .name = \"{s}\", .tok = {d}", .{ n.name, n.tok });
        if (o != 0) try self.w(", .outs = 0x{x}", .{o});
        if (n.task) try self.w(", .task = true", .{});
        try self.w(" }},\n", .{});
    }
    assert(outs.len == self.systf_names.items.len);
    try self.w("}};\n\n", .{});
}

/// Writes an unregistered system function call (W0852) as a VPI hand-off.
/// §2.8.3 makes `$name` grammatical and lets the VPI define it (§12.32), so
/// the source may not be rejected; `--deny=W0852` makes a host-less build
/// fail. Every Clause 9 name is implemented in `emitCall` or refused before
/// codegen, so only names the LRM defines nowhere arrive here. Add an
/// unimplemented LRM function to `Mir.Callee` and `emitCall`, not here.
/// Asserts that `name` is a `$name`. Appends to `systf_names` when the call
/// is new. Invalidates slices of `out.items` if additional memory is needed.
pub fn emitUnregistered(self: *Gen, inst: Mir.Inst, name: []const u8, args: []const Mir.Value) Error!void {
    assert(name.len > 1);
    assert(name[0] == '$');
    if (self.diags) |bag| try bag.add(
        .codegen,
        .W0852,
        self.lowered.tokenSpan(self.mir.instTok(inst)),
        "`{s}` is not a system function this compiler defines, so it is exported in " ++
            "`systf_calls` for a VPI application to supply; a host that binds none " ++
            "will not build",
        .{name},
    );
    // A systf crosses to the host through concrete f64s, so it pins.
    float_lanes.pinCrossing(self);
    return emitSystfCall(self, name, args, self.lowered.systf_tasks.contains(inst));
}

/// Writes §12.22.2 output argument j of the user system task call
/// `args[0]`, whose arguments are `args[2..]`: the value its calltf put
/// there and the partials, through `SystfHost.output`. The call is rendered
/// first, so its calltf has run when the output is read.
/// Refuses (E1020) a `$systf$out` that reads no user system task call.
/// Invalidates slices of `out.items` if additional memory is needed.
pub fn emitSystfOut(self: *Gen, args: []const Mir.Value) Error!void {
    const call = systfOutCall(self, args) orelse
        return gen_call.abort(self, .E1020, "VerA: `$systf$out` does not read a user system task call", .{});
    // Only a task has output arguments (`analog/systask.zig`).
    const k = try systfIndex(self, call.name, call.tok, true);
    assert(k < self.systf_names.items.len);
    assert(call.j >= 1);
    // Crosses to the host through concrete f64s, as the call does.
    float_lanes.pinCrossing(self);
    return emitHostCall(self, args[0], args[2..], try self.arena.print("zsh.output({d}, {d}, &zsv, &zsp)", .{ k, call.j }));
}

// ---- private ----

/// Writes one §2.8.3/§12.32 hand-off of `$name` to the host's VPI
/// application. A function pointer cannot be generic over S, so the host
/// takes f64 values and returns the value plus partials, and this rebuilds
/// S: `arg.addC(-arg.val()).scale(p)` adds p·d(arg) to the derivative and
/// zero to the value (§12.22.1's `derivtf`).
fn emitSystfCall(self: *Gen, name: []const u8, args: []const Mir.Value, task: bool) Error!void {
    const k = try systfIndex(self, name, self.cur.call_tok, task);
    assert(k < self.systf_names.items.len);
    return emitHostCall(self, null, args, try self.arena.print("zsh.call(zsh.ctx, {d}, &zsv, &zsp)", .{k}));
}

/// The user system task call a `$systf$out` reads (its name and token) and
/// the argument position j, or null for MIR lowering never makes.
fn systfOutCall(self: *const Gen, args: []const Mir.Value) ?struct { name: []const u8, tok: u32, j: usize } {
    if (args.len < 2) return null;
    const def = self.mir.valueDef(self.an.rv(args[0]));
    if (def != .inst_result) return null;
    const d = self.mir.instData(def.inst_result);
    if (d != .call or d.call.callee != .systf) return null;
    const j = self.mir.valueDef(self.an.rv(args[1]));
    if (j != .int_const or j.int_const < 1 or j.int_const > args.len - 2) return null;
    assert(j.int_const >= 1);
    return .{ .name = d.call.name, .tok = self.mir.instTok(def.inst_result), .j = @intCast(j.int_const) };
}

/// The `systf_calls` index of the call `name` at `tok`, added at the end
/// (a task when `task`) when it is new.
fn systfIndex(self: *Gen, name: []const u8, tok: u32, task: bool) Error!usize {
    assert(name.len != 0);
    const len_before = self.systf_names.items.len;
    for (self.systf_names.items, 0..) |n, i| {
        if (n.tok == tok and std.mem.eql(u8, n.name, name)) return i;
    }
    try self.systf_names.append(self.arena, .{ .name = name, .tok = tok, .task = task });
    assert(self.systf_names.items.len == len_before + 1);
    return self.systf_names.items.len - 1;
}

/// Writes `zs<label>: { ... }`, the S value of `host` (an expression over
/// `zsh`, the f64 values `zsv` and the partials `zsp` it fills) with every
/// argument's lanes put back. `first`, when set, is rendered and discarded
/// before the arguments.
fn emitHostCall(self: *Gen, first: ?Mir.Value, args: []const Mir.Value, host: []const u8) Error!void {
    // Reads `inst`, so `emitUnit` keeps the parameter named.
    self.cur.uses.inst = true;
    float_lanes.instPin(self);

    const label = self.systf_sites;
    assert(host.len != 0);
    self.systf_sites += 1;
    try self.b("zs{d}: {{\n", .{label});
    if (first) |f| {
        try self.b("        _ = ", .{});
        try gen_render.renderVal(self, f, .real);
        try self.b(";\n", .{});
    }
    for (args, 0..) |a, j| {
        try self.b("        const zs{d}a{d} = ", .{ label, j });
        try gen_render.renderVal(self, a, .real);
        try self.b(";\n", .{});
    }
    // `validateHost` refuses a host that binds no application, so this
    // unwrap is safe; the LRM fixes no default value to fall back to.
    try self.b("        const zsh = inst.systf.?;\n", .{});
    try self.b("        const zsv = [_]f64{{", .{});
    for (args, 0..) |_, j| try self.b("{s} zs{d}a{d}.val()", .{ if (j == 0) "" else ",", label, j });
    try self.b(" }};\n", .{});
    try self.b("        var zsp: [{d}]f64 = undefined;\n", .{args.len});
    // `zsr` holds every argument's lanes, the union of theirs.
    const m = try gen_mask.zero(self.arena, self.mw);
    assert(m.len == self.mw);
    for (args) |a| gen_mask.orIn(m, family.mask(self, a));
    const to = try self.arena.print("zTo(S, 0x{f}, ", .{gen_mask.hex(m, false)});
    try self.b("        var zsr = {s}S.con({s}));\n", .{ to, host });
    for (args, 0..) |_, j|
        try self.b("        zsr = {s}zsr.add(zs{d}a{d}.addC(-zsv[{d}]).scale(zsp[{d}])));\n", .{ to, label, j, j, j });
    assert(self.systf_sites > label);
    try self.b("        break :zs{d} zsr;\n    }}", .{label});
}
