//! A Clause 9 call whose operands are values the renderer reads -> its kernel
//! call: a §9.5.4.2 `zScan*` read, a §9.13 probabilistic draw, a §9.21
//! `$table_model` lookup, and a §3.2/§5.7 run-time array index.
//! Cites: §3.2, §5.7, §9.5.4.2, §9.13, §9.21.
//!
//! Contents:
//! - `pub fn emitScan(self: *Gen, fn_name: []const u8, args: []const Mir.Value, want: VTy) Error!void`
//! - `pub fn emitRng(self: *Gen, c: Mir.Callee, args: []const Mir.Value) Error!void`
//! - `pub fn emitTable(self: *Gen, inst: Mir.Inst, args: []const Mir.Value) Error!void`
//! - `pub fn emitIdx(self: *Gen, args: []const Mir.Value, want: VTy) Error!void`
//! - `pub fn intArg(self: *const Gen, args: []const Mir.Value, i: usize) ?usize`

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_mask = @import("mask.zig");
const gen_unit = @import("unit.zig");
const gen_unit_body = @import("unit_body.zig");
const family = @import("family.zig");
const Mir = @import("ir").Mir;
const Error = codegen.Error;
const VTy = codegen.VTy;
const render_op = @import("render_op.zig");
const gen_render = @import("render.zig");

/// Writes one §9.5.4.2 `zScan*` call: `(src, fmt)` for the count, plus the
/// item index for an item. `want` is the result's type; only `.real` gets
/// an `S.con` wrapper.
pub fn emitScan(self: *Gen, fn_name: []const u8, args: []const Mir.Value, want: VTy) Error!void {
    assert(fn_name.len != 0);
    assert(want != .wide);
    if (want == .real) try self.b("S.con(", .{});
    try self.b("{s}(", .{fn_name});
    try gen_render.renderVal(self, if (args.len > 0) args[0] else .undef, .str);
    try self.b(", ", .{});
    try gen_render.renderVal(self, if (args.len > 1) args[1] else .undef, .str);
    if (args.len > 2) {
        try self.b(", ", .{});
        try gen_render.renderVal(self, args[2], .int);
    }
    try self.b(")", .{});
    if (want == .real) try self.b(")", .{});
    assert(std.mem.endsWith(u8, self.out.items, ")"));
}

/// Writes one §9.13 probabilistic draw. `$rng$auto` reads the seedless
/// form's `Instance` field; every other name is a `rng_kernels.zig` call on
/// the i64 seed and its real parameters. Always pins lanes.
pub fn emitRng(self: *Gen, c: Mir.Callee, args: []const Mir.Value) Error!void {
    assert(Mir.callee.family(c) == .none); // A draw is no task.
    // One draw per call, not per lane.
    float_lanes.pinCrossing(self);
    switch (c) {
        .@"$rng$auto" => {
            // §9.13.1's internal seed; `updateState` advances it on the
            // accepted step, never here.
            self.cur.uses.inst = true;
            const site = intArg(self, args, 0) orelse 0;
            return self.b("S.con(@floatFromInt(inst.rng_auto[{d}]))", .{site});
        },
        .@"$rng$check" => {
            if (args.len != 4) return gen_call.abort(self, .E1020, "malformed RNG validation effect", .{});
            const val = "zV"; // a family has no `S.val`
            try self.b("S.con(zRngCheck({s}(", .{val});
            try gen_render.renderVal(self, args[0], .real);
            try self.b("), {d}, {s}(", .{ intArg(self, args, 1) orelse return gen_call.abort(self, .E1020, "missing RNG validation rules", .{}), val });
            try gen_render.renderVal(self, args[2], .real);
            try self.b("), {s}(", .{val});
            try gen_render.renderVal(self, args[3], .real);
            return self.b(")))", .{});
        },
        else => {}, // else: a distribution draw — `emitCall` routes only the `$rng$` tags here, and every other one is a kernel
    }
    assert(std.mem.startsWith(u8, @tagName(c), "$rng$"));
    const tail = @tagName(c)["$rng$".len..];
    assert(tail.len > 0);
    // The kernel name is the callee's tail in camel case (`zRngChiSquare`),
    // so the two lists cannot drift apart by a typo.
    // Bounded by the longest callee tag, so it is a stack buffer.
    const cap = comptime blk: {
        @setEvalBranchQuota(100_000);
        var m: usize = 0;
        for (@typeInfo(Mir.Callee).@"enum".field_names) |n| m = @max(m, n.len);
        break :blk "zRng".len + m;
    };
    comptime assert(cap > "zRng".len + "$rng$".len);
    var buf: [cap]u8 = undefined;
    var fn_name: std.ArrayList(u8) = .initBuffer(&buf);
    fn_name.appendSliceAssumeCapacity("zRng");
    var up = true;
    for (tail) |ch| {
        if (ch == '_') {
            up = true;
            continue;
        }
        fn_name.appendAssumeCapacity(if (up) std.ascii.toUpper(ch) else ch);
        up = false;
    }
    assert(fn_name.items.len > "zRng".len);
    try self.b("S.con({s}(", .{fn_name.items});
    try gen_render.renderVal(self, if (args.len > 0) args[0] else .zero, .int);
    for (args[@min(1, args.len)..]) |a| {
        try self.b(", ", .{});
        try gen_render.renderVal(self, a, .real);
        try self.b(".val()", .{});
    }
    try self.b("))", .{});
    assert(std.mem.endsWith(u8, self.out.items, "))"));
}

/// Writes a §9.21 `$table_model` call in the shape
/// `analog/table_model.zig`'s `lowerTableModel` gives it:
///
///     (ND, NP, NCOL, dep, "<interp/extrap>", snapshot_site, previous_call, in₀…, row₀…)
///
/// Samples go in as f64 (§9.21.1 fixes the data at the first call, so they
/// carry no derivative); the lookup point goes in as `S`. Pins lanes on any
/// x-dependent argument.
pub fn emitTable(self: *Gen, inst: Mir.Inst, args: []const Mir.Value) Error!void {
    assert(self.mir.instOp(inst) == .call);
    // The cell choice is one scalar decision on `.val()`.
    for (args) |arg| float_lanes.pinLanes(self, arg);
    const nd = intArg(self, args, 0) orelse 0;
    const np = intArg(self, args, 1) orelse 0;
    const ncol = intArg(self, args, 2) orelse 0;
    const dep = intArg(self, args, 3) orelse 0;
    const ext = gen_call.strArg(self, args, 4) orelse "";
    const site = intArg(self, args, 5) orelse 0;
    const head = 7 + nd;
    // `np == 0` is §9.21.1's absent data source, reported by `zTable` at
    // the call.
    if (nd == 0 or ncol == 0 or args.len != head + np * ncol)
        return gen_call.abort(self, .E1020, "malformed `$table_model` call reached codegen", .{});
    assert(head <= args.len);
    // The lookup runs at the union of its points' masks.
    const m = try gen_mask.zero(self.arena, self.mw);
    for (args[7..head]) |v| gen_mask.orIn(m, family.mask(self, v));
    const val = "zV"; // a family has no `S.val`
    const pt = try self.arena.print("zL(S, 0x{f})", .{gen_mask.hex(m, false)});
    if (site != 0) {
        self.cur.uses.inst = true;
        self.float.pinned = true;
        try self.b("tbl_{d}: {{ _ = {s}(", .{ @backingInt(inst), val });
        try gen_render.renderVal(self, args[6], .real);
        try self.b("); if (!inst.table_ready[{d}]) {{ inst.table_{d} = [_]f64{{", .{ site - 1, site - 1 });
    } else {
        try self.b("zLu(S, 0x{f}, zTable({s}, {d}, {d}, {d}, {d}, \"{s}\", [_]f64{{", .{ gen_mask.hex(m, false), pt, np, ncol, nd, dep, ext });
    }
    for (args[head..], 0..) |v, k| {
        if (k != 0) try self.b(", ", .{});
        try self.b("{s}(", .{val});
        try gen_render.renderVal(self, v, .real);
        try self.b(")", .{});
    }
    if (site != 0) {
        try self.b("}}; inst.table_ready[{d}] = true; }} break :tbl_{d} ", .{ site - 1, @backingInt(inst) });
        try self.b("zLu(S, 0x{f}, ", .{gen_mask.hex(m, false)});
        try self.b("zTable({s}, {d}, {d}, {d}, {d}, \"{s}\", inst.table_{d}, [_]{s}{{", .{ pt, np, ncol, nd, dep, ext, site - 1, pt });
    } else try self.b("}}, [_]{s}{{", .{pt});
    for (args[7..head], 0..) |v, k| {
        if (k != 0) try self.b(", ", .{});
        try render_op.kernelArg(self, v, m);
    }
    try self.b("}}))", .{});
    if (site != 0) try self.b("; }}", .{});
    assert(std.mem.endsWith(u8, self.out.items, if (site != 0) "})); }" else "}))"));
}

/// Writes a §3.2/§5.7 runtime array index in the shape
/// `analog/expr.zig`'s `lowerIndex` gives it, `(lo, i, e_lo … e_hi)`, as one `switch`: one dispatch and one
/// element evaluation per read (a `sel` chain would evaluate every element).
/// An out-of-range read yields the element type's zero; an integer array
/// cannot yield x. Pins lanes when the index depends on x.
pub fn emitIdx(self: *Gen, args: []const Mir.Value, want: VTy) Error!void {
    assert(want != .wide);
    // Checked before any operand is read: a short list has no `args[1]`.
    if (args.len < 3) return gen_call.abort(self, .E1020, "malformed `$idx` call reached codegen", .{});
    // The choice is one integer, so it is lane-uniform.
    float_lanes.pinLanes(self, args[1]);
    const lo: i64 = blk: {
        const def = self.mir.valueDef(self.an.rv(args[0]));
        break :blk if (def == .int_const) def.int_const else 0;
    };
    // Every real arm widens to the union of the elements'.
    const m = try gen_mask.zero(self.arena, self.mw);
    for (args[2..]) |v| gen_mask.orIn(m, family.mask(self, v));
    const widen = want == .real;
    try self.b("switch (", .{});
    try gen_render.renderVal(self, args[1], .int);
    try self.b(") {{", .{});
    for (args[2..], 0..) |v, k| {
        try self.b(" {d} => ", .{lo + @as(i64, @intCast(k))});
        if (widen) try family.openTo(self, m);
        try gen_render.renderVal(self, v, want);
        if (widen) try self.b(")", .{});
        try self.b(",", .{});
    }
    // §5.7 defers out-of-range reads to IEEE 1800: the element type's
    // default, which §3.2 makes zero in an analog context. The read must
    // neither alias another element (clamp, wrap) nor abort (§4.3.2
    // reserves "shall report an error" for named cases).
    if (widen) return self.b(" else => zTo(S, 0x{f}, {s}) }}", .{ gen_mask.hex(m, false), gen_unit_body.zeroOf(want) });
    try self.b(" else => {s} }}", .{gen_unit_body.zeroOf(want)});
    assert(std.mem.endsWith(u8, self.out.items, " }"));
}

/// Returns the non-negative integer literal lowering put at `args[i]`, or
/// null when absent or not such a literal.
pub fn intArg(self: *const Gen, args: []const Mir.Value, i: usize) ?usize {
    assert(args.len <= std.math.maxInt(u32));
    if (i >= args.len) return null;
    return std.math.cast(usize, self.an.intConst(args[i]) orelse return null);
}
