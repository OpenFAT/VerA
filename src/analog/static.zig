const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_shape = @import("shape.zig");
const Oom = Lower.Oom;

/// This file's private state on `Lower` (`Lower.static_state`): the scratch
/// `isStaticValue` walks with, cleared at the start of each walk and reused, so
/// a condition costs no arena allocation once the sets have grown to the
/// largest walk (on psp103, ~5k conditions used to leave ~3 MB of dead sets).
pub const State = struct {
    /// Values already on the walk.
    seen: std.AutoHashMapUnmanaged(Mir.Value, void) = .empty,
    /// Blocks whose deciding branch was already judged.
    blocks: std.AutoHashMapUnmanaged(Mir.Block, void) = .empty,
    /// The walk's pending values and blocks. A worklist, not recursion: a
    /// value's dependences are as deep as the straight-line code before it
    /// (100,000 `y = y + 1.0;` is a 100,000-deep chain), which no parse
    /// nesting measures, so the old recursive walk overflowed the stack.
    work: std.ArrayList(WalkItem) = .empty,
    /// Blocks and values a walk that answered static already judged (a sealed
    /// block with every deciding branch static; a value with static operands).
    /// Kept across walks, since neither can change once judged, so a chain of
    /// n `if`s judges each block and value once rather than once per `if`.
    static_blocks: std.AutoHashMapUnmanaged(Mir.Block, void) = .empty,
    static_values: std.AutoHashMapUnmanaged(Mir.Value, void) = .empty,
};

/// One pending node of the static walk: a value whose definition is judged,
/// or a block whose deciding branches are.
const WalkItem = union(enum) { value: Mir.Value, block: Mir.Block };

/// Reports whether `e` is an A.8.3 `analysis_or_constant_expression` (the §5.8.1
/// carve-out): literals, parameters and `analysis()` calls combined with operators,
/// none of which can change between Newton iterations. Unlike `foldExpr(..., false)`,
/// a parameter qualifies: the card may override it, but not mid-solve.
pub fn isAnalysisOrConst(self: *const Lower, e: Ast.ExprId) bool {
    if (e == .none) return false;
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        // A.8.4 `number`, `string_literal`.
        .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf => true,
        .ident => blk: {
            const name = self.file.str(ex.strOf(e));
            if (self.vars.contains(name)) break :blk false;
            break :blk self.param_index.contains(name) or self.consts.contains(name);
        },
        // A.8.2 analysis_function_call. Its value is fixed for the analysis,
        // which is the whole reason §5.8.1 spells out "analysis_or_constant".
        // A.8.4 `system_parameter_identifier`: §9.18 Syntax 9-13's six hierarchical
        // parameters, fixed per instance for the whole simulation.
        .sys_call => blk: {
            const name = self.file.str(ex.strOf(e));
            if (std.mem.eql(u8, name, "analysis")) break :blk true;
            // §9.19 genvar_system_function: "fixed during elaboration. As such,
            // these functions can be used in genvar expressions controlling
            // conditional or looping behavior of the analog operators" (#33).
            // A top-level call reads the host-written mask, so it does not fold.
            if (std.mem.eql(u8, name, "$param_given") or std.mem.eql(u8, name, "$port_connected")) break :blk true;
            if (ex.args(e).len != 0) break :blk false;
            for ([_][]const u8{ "$mfactor", "$xposition", "$yposition", "$angle", "$hflip", "$vflip" }) |s| {
                if (std.mem.eql(u8, name, s)) break :blk true;
            }
            break :blk false;
        },
        // A.8.4 `parameter_identifier [ constant_range_expression ]`: the base
        // has to name a §3.4.4 array PARAMETER, whose elements `param.zig`
        // scalarizes into `param_index` under `elemKey`'s `name[i]` spelling.
        .index => blk: {
            var base = e;
            while (ex.tag(base) == .index) {
                if (!isAnalysisOrConst(self, ex.rhs(base))) break :blk false;
                base = ex.lhs(base);
            }
            if (ex.tag(base) != .ident) break :blk false;
            const name = self.file.str(ex.strOf(base));
            const info = self.arrays.get(name) orelse break :blk false;
            var buf: [lower_shape.elem_key_len]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            w.writeAll(name) catch break :blk false;
            for (info.dims) |d| w.print("[{d}]", .{d.lo}) catch break :blk false;
            break :blk self.param_index.contains(w.buffered());
        },
        // Operators, A.8.4 `constant_analog_built_in_function_call` and
        // `constant_concatenation`: constant when every operand is.
        .unary, .binary, .range, .indexed_range, .multi_concat, .ternary, .builtin_call, .concat => blk: {
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (!isAnalysisOrConst(self, c)) break :blk false;
            break :blk true;
        },
        // A.8.4 `nature_attribute_reference ::= net_identifier .
        // potential_or_flow . nature_attribute_identifier`: a nature's
        // attribute is fixed at declaration. Any other dotted name is a §6.8
        // hierarchical reference to something that can move.
        .hier_ident => blk: {
            const parts = ex.nameParts(e);
            if (parts.len != 3) break :blk false;
            break :blk self.file.strings.eql(parts[1], "potential") or self.file.strings.eql(parts[1], "flow");
        },
        // Probes, analog operators and small-signal sources are exactly what
        // moves between iterations; an assignment pattern and the event forms
        // are not A.8.4 primaries.
        //
        // A user function call stays out even with constant arguments: A.8.4's
        // `constant_analog_function_call` promises nothing about the body, which
        // may read `$abstime` (§9.10), and §4.5.15's test is "terms which can
        // not change their value during the course of a simulation".
        .call,
        .branch_access,
        .port_access,
        .filter_call,
        .noise_call,
        .assign_pattern,
        .pattern_repl,
        .event_or,
        .event_posedge,
        .event_negedge,
        .event_initial_step,
        .event_final_step,
        .event_function,
        .event_driver_update,
        => false,
    };
}

/// Reports whether lowered value `v` consists of §4.5.15 "terms which can not
/// change their value during the course of a simulation", by following its
/// dependences rather than its spelling, so `td = ptf * c * tf; if (td == 0.0)`
/// qualifies where `isAnalysisOrConst` refuses every variable.
///
/// Static leaves: literals, parameters (§3.4), and the calls `static_calls`
/// names. Dynamic: a §4.4 probe (`block_param`), the committed-state latches,
/// any other call (analog operators, `$abstime`, `$held_*` seeds, I/O, ...),
/// and a phi whose merge a dynamic branch decides.
///
/// ponytail: a phi is judged by every branch backward-reachable from its
/// incoming blocks, not only the ones between its dominator and itself, so a
/// solve-dependent `if` anywhere earlier in the block makes a later merge
/// dynamic even when it cannot decide it. Sound, and no worse than the
/// syntactic test it extends (which refuses every variable). Upgrade: control
/// dependence through the immediate dominator of the phi's block. A held
/// variable is dynamic even when every write to it is static, for the same
/// reason.
pub fn isStaticValue(self: *Lower, v: Mir.Value) Oom!bool {
    const st = &self.static_state;
    st.seen.clearRetainingCapacity();
    st.blocks.clearRetainingCapacity();
    st.work.clearRetainingCapacity();
    if (!try staticWalk(self, v)) return false;
    // Only a whole walk that answered static proves its blocks: a `false`
    // anywhere may have been met after a block was provisionally passed.
    var it = st.blocks.keyIterator();
    while (it.next()) |blk| try st.static_blocks.put(self.arena, blk.*, {});
    var vt = st.seen.keyIterator();
    while (vt.next()) |sv| try st.static_values.put(self.arena, sv.*, {});
    return true;
}

/// The calls whose value is fixed for the whole simulation: A.8.2's
/// `analysis()`, §9.15's `$temperature` and `$vt`, §9.18's six system
/// parameters, and the runtime array read (a pure selection over its operands).
const static_calls = std.StaticStringMap(void).initComptime(.{
    .{"analysis"},   .{"$temperature"}, .{"$vt"},    .{"$mfactor"}, .{"$xposition"},
    .{"$yposition"}, .{"$angle"},       .{"$hflip"}, .{"$vflip"},   .{"$idx"},
    .{"$idx$int"},   .{"$idx$str"},
});

/// Judges `root` and everything it depends on, through operands and the
/// branches deciding each phi's incoming edges: true when every one is static.
/// The answer is the conjunction over the reachable set, so the visit order is
/// free; `seen` and `blocks` keep each node judged once.
fn staticWalk(self: *Lower, root: Mir.Value) Oom!bool {
    const st = &self.static_state;
    assert(st.work.items.len == 0);
    // Every push is an operand, phi pair or predecessor edge of a node judged
    // once, so the walk ends within their total.
    const pushes_max = 3 * self.mir.insts.len + 2 * self.mir.extra.items.len + self.builder.pred_pool.items.len + 1;
    var steps: usize = 0;
    try st.work.append(self.arena, .{ .value = root });
    while (st.work.pop()) |item| : (steps += 1) {
        assert(steps <= pushes_max);
        const ok = switch (item) {
            .value => |v| try judgeValue(self, v),
            .block => |b| try judgeBlock(self, b),
        };
        if (!ok) {
            st.work.clearRetainingCapacity();
            return false;
        }
    }
    assert(st.work.items.len == 0);
    return true;
}

/// Judges one value's definition and queues what it depends on. False when
/// the definition itself moves between iterations.
fn judgeValue(self: *Lower, v0: Mir.Value) Oom!bool {
    const st = &self.static_state;
    assert(self.valueValid(v0));
    const v = self.mir.resolveAlias(v0);
    if (st.static_values.contains(v)) return true;
    // A value already on the walk is being decided by the rest of it: a loop
    // phi reaching itself adds no dependence of its own.
    if ((try st.seen.getOrPut(self.arena, v)).found_existing) return true;
    const inst = switch (self.mir.valueDef(v)) {
        .undef, .float_const, .int_const, .str_const, .param_ref => return true,
        .block_param => return false, // §4.4: an unknown of the solve
        .inst_result => |i| i,
    };
    const work = &st.work;
    switch (self.mir.instData(inst)) {
        .unary => |u| {
            // Committed-solution latches: they move with every accepted step.
            if (u.op == .path_prev or u.op == .path_acc) return false;
            try work.append(self.arena, .{ .value = u.operand });
        },
        .binary => |b| try work.appendSlice(self.arena, &.{ .{ .value = b.lhs }, .{ .value = b.rhs } }),
        .ternary => |t| try work.appendSlice(self.arena, &.{ .{ .value = t.cond }, .{ .value = t.then_val }, .{ .value = t.else_val } }),
        .call => |c| {
            if (!static_calls.has(c.name)) return false;
            // `args` borrows the payload pool; the walk appends nothing to it.
            for (c.args) |a| try work.append(self.arena, .{ .value = a });
        },
        .phi => |p| {
            // An incomplete phi (unsealed loop header) has no operands yet.
            if (p.count == 0) return false;
            for (0..p.count) |k| {
                const pair = self.mir.phiPair(inst, @intCast(k));
                try work.appendSlice(self.arena, &.{ .{ .value = pair.value }, .{ .block = pair.block } });
            }
        },
        .branch, .jump => return false,
        // §3.2.2 a fresh local array is static; a held one is dynamic, as a
        // held variable is. An element is static when its version and its
        // index are, and a version when everything stored into it is.
        .anew => |a| return self.out.mem_arrays.items[a.array].held == Lower.none_u32,
        .load => |l| try work.appendSlice(self.arena, &.{ .{ .value = l.arr }, .{ .value = l.index } }),
        .store => |s| try work.appendSlice(self.arena, &.{ .{ .value = s.arr }, .{ .value = s.index }, .{ .value = s.value } }),
    }
    assert(st.seen.contains(v));
    return true;
}

/// Judges one block reaching a phi: every branch that can decide whether
/// control reaches it must have a static condition, so its deciding branch
/// and its predecessors are queued; see `isStaticValue` for the
/// over-approximation. False when a predecessor may still arrive.
fn judgeBlock(self: *Lower, blk: Mir.Block) Oom!bool {
    const st = &self.static_state;
    assert(self.blockValid(blk));
    if (st.static_blocks.contains(blk)) return true;
    if ((try st.blocks.getOrPut(self.arena, blk)).found_existing) return true;
    const b = &self.builder;
    const i = @backingInt(blk);
    // Unsealed: more predecessors may still arrive (a loop's back edge).
    if (i >= b.block_state.len or !b.block_state.items(.sealed)[i]) return false;
    const last = self.mir.blockLast(blk);
    if (last != .none and self.mir.instOp(last) == .branch)
        try st.work.append(self.arena, .{ .value = self.mir.instData(last).branch.cond });
    var node = b.block_state.items(.preds_head)[i];
    for (0..b.block_state.items(.preds_len)[i]) |_| {
        try st.work.append(self.arena, .{ .block = b.pred_pool.items[node].block });
        node = b.pred_pool.items[node].next;
    }
    assert(st.blocks.contains(blk));
    return true;
}

test isAnalysisOrConst {
    // A.8.3 `analysis_or_constant_expression`, judged on the parsed default
    // in an empty scope, so no identifier is a parameter: literals,
    // `analysis()`, §9.18's six system parameters and §5.5.3's nature
    // attributes, under any operator; nothing that moves between iterations.
    const cases = [_]struct { expr: []const u8, want: bool }{
        .{ .expr = "1", .want = true },
        .{ .expr = "2.5", .want = true },
        .{ .expr = "\"s\"", .want = true },
        .{ .expr = "4'b1010", .want = true },
        .{ .expr = "analysis(\"dc\")", .want = true },
        .{ .expr = "(1 > 0) && analysis(\"tran\")", .want = true },
        .{ .expr = "1 ? 2 : 3", .want = true },
        .{ .expr = "abs(-2.0)", .want = true },
        .{ .expr = "$mfactor", .want = true },
        .{ .expr = "p.potential.abstol", .want = true },
        .{ .expr = "$abstime", .want = false },
        .{ .expr = "$temperature", .want = false },
        .{ .expr = "ddt(1.0)", .want = false },
        .{ .expr = "V(p)", .want = false },
        .{ .expr = "f(1)", .want = false },
        .{ .expr = "undeclared", .want = false },
        .{ .expr = "u.x", .want = false },
        .{ .expr = "undeclared ? 2 : 3", .want = false },
    };
    for (cases) |c| {
        const src = try std.testing.allocator.print("module m; parameter real a = {s}; endmodule", .{c.expr});
        defer std.testing.allocator.free(src);
        var h: Lower.Harness = undefined;
        try h.init(std.testing.allocator, src);
        defer h.deinit();
        const m = &h.file.modules[h.file.builtin_modules];
        std.testing.expectEqual(c.want, isAnalysisOrConst(&h.low, m.params[0].default)) catch |e| {
            std.debug.print("{s}\n", .{c.expr});
            return e;
        };
    }
}
