//! Control-flow reconstruction: one unit's MIR blocks, dominator tree and slot
//! plan in, structured Zig out (Ramsey, "Beyond Relooper"). A merge block Y
//! that is an immediate dominator child of X becomes a labelled block opened in
//! X and closed before Y's code, so every edge into Y is `break :B<Y>`; a back
//! edge is `continue :L<X>`. Exact for every reducible CFG. Phis are copied on
//! each incoming edge. LRM clauses cited: §5.6.1.3.

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_setup = @import("setup.zig");
const gen_instance = @import("instance.zig");
const gen_render = @import("render.zig");
const gen_unit = @import("unit.zig");
const family = @import("family.zig");
const gen_mask = @import("mask.zig");
const Mir = @import("ir").Mir;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;

/// Writes a body's exit: a unit returns its contribution value, the shared
/// core returns its whole cache, and `setup` stores its roots.
pub fn emitReturn(self: *Gen, depth: u32, target: Mir.Value) Error!void {
    if (self.su.mode) return gen_setup.emitStores(self, depth, "");
    try self.ind(depth);
    if (!self.emitting_common) {
        try self.b("return ", .{});
        try family.openTo(self, family.mask(self, target));
        try gen_render.renderVal(self, target, .real);
        return self.b(");\n", .{});
    }
    try self.b("return .{{\n", .{});
    for (self.core.lo_vals, 0..) |v, k| {
        const arr = self.an.arrOf(v);
        if (arr) |id| if (gen_render.inPlace(self, id)) continue;
        try self.ind(depth + 1);
        try self.b(".f{d} = ", .{k});
        const wrap = arr == null and self.an.vty[@backingInt(v)] == .real;
        if (wrap) try family.openTo(self, family.mask(self, v));
        if (arr != null)
            try gen_render.renderArrayOut(self, v)
        else
            try gen_render.renderVal(self, v, self.an.vty[@backingInt(v)]);
        if (wrap) try self.b(")", .{});
        try self.b(",\n", .{});
    }
    try self.ind(depth);
    try self.b("}};\n", .{});
}

/// Writes block `bi`'s statements. `decl` is the straight-line path, which
/// declares every slot at its definition. Asserts that `bi` is a block of
/// the unit.
pub fn emitBlockInsts(self: *Gen, bi: u32, depth: u32, comptime decl: bool) Error!void {
    assert(bi < self.an.term.len);
    assert(self.an.stmt_off[bi] <= self.an.stmt_off[bi + 1]);
    const stmts = self.an.stmt_pool[self.an.stmt_off[bi]..self.an.stmt_off[bi + 1]];
    // `setup` runs no `vera_timepoint` statement: it reads the time.
    if (!self.su.mode) try gen_instance.emitTpFills(self, bi, depth);
    for (stmts) |inst| {
        // `setup` computes a speculable value at its home instead.
        if (self.su.mode and self.sinv.home[@backingInt(self.an.i_res[@backingInt(inst)])] != none_u32) continue;
        try emitStmt(self, inst, depth, decl);
    }
    if (self.su.mode) for (self.sinv.movedTo(bi)) |v| {
        self.su.spec = true;
        defer self.su.spec = false;
        try emitStmt(self, self.mir.valueDef(v).inst_result, depth, decl);
    };
}

fn emitStmt(self: *Gen, inst: Mir.Inst, depth: u32, comptime decl: bool) Error!void {
    const i = @backingInt(self.an.i_res[@backingInt(inst)]);
    if (!self.plan.needed.isSet(i)) return;
    // §3.2.2 an `anew`/`store` is a statement on its storage, not a slot.
    if (self.an.arr_of[i] != none_u32) {
        if (!self.plan.cached(@fromBackingInt(@intCast(i)))) try gen_render.emitArrayStmt(self, inst, depth);
        return;
    }
    if (self.plan.slot[i] == none_u32) return;
    // The straight-line path runs without a probe, so it never reads `place`.
    if (!decl) assert(self.plan.slot[i] < self.probe.place.items.len);
    gen_unit.probeDef(self, self.plan.slot[i], true);
    // `or` short-circuits, so the straight-line path (`decl`, which runs
    // without a probe) never touches `place`.
    const at_def = decl or self.probe.place.items[self.plan.slot[i]].at_def;
    try self.ind(depth);
    var m: ?[]const u64 = null;
    if (at_def) {
        if (self.an.vty[i] == .real) {
            // Zig types it from the expression; `lane_masks` counts it.
            try family.note(self, family.mask(self, @fromBackingInt(@intCast(i))));
            try self.b("const t{d} = ", .{self.plan.slot[i]});
        } else try self.b("const t{d}: {s} = ", .{ self.plan.slot[i], try gen_unit.slotTy(self, i) });
    } else {
        try gen_unit.writeSlotRef(self, i);
        try self.b(" = ", .{});
        m = gen_unit.slotMask(self, i);
        if (m) |k| try family.openTo(self, k);
    }
    try gen_render.renderInst(self, inst);
    if (m != null) try self.b(")", .{});
    try self.b(";\n", .{});
}

/// Writes block `bi` and the dominator subtree it heads, wrapping a loop
/// header in `L<bi>: while (true)`.
///
/// The walk is a loop over a heap stack of what is left to write after each
/// nested piece (`Resume`), not a recursion: an `if` nested, chained or
/// following another 100,000 deep is a dominator tree that deep, and each
/// level costs a stack row instead of a few native frames. The text is the
/// recursion's, byte for byte (`emitStep`'s pieces are its bodies in order).
pub fn emitTree(self: *Gen, bi: u32, depth: u32, target: Mir.Value) Error!void {
    var stack: std.ArrayList(Resume) = .empty;
    defer stack.deinit(self.gpa);
    var next: ?Step = .{ .tree = .{ .bi = bi, .depth = depth } };
    while (true) {
        if (next) |s| {
            next = try emitStep(self, s, &stack, target);
            continue;
        }
        const r = stack.pop() orelse return;
        next = try emitResume(self, r, &stack);
    }
}

/// A piece `emitTree` writes next: a block's subtree (`tree`, which may open
/// a loop), a block's own code (`code`), or an edge.
const Step = union(enum) {
    tree: struct { bi: u32, depth: u32 },
    code: struct { bi: u32, depth: u32 },
    edge: struct { from: u32, to: u32, depth: u32 },
};

/// What is left to write once the piece below it is done.
const Resume = union(enum) {
    /// Close `L<bi>: while (true) {`, putting `su.dead` back.
    loop_end: struct { depth: u32, was_dead: bool },
    /// After a block's terminator: drop a fall-through label (`emitCode`'s
    /// peephole, unless `peeped`), then close each merge label `mc[j..]`
    /// and write that child.
    merge_kids: struct { mc: []const u32, j: usize, depth: u32, at_inner: usize, body_start: usize, peeped: bool, dropped: bool },
    /// After an `if`'s `then` arm: `} else {` and the `else` arm.
    /// `init_at`: where the arm's text starts when the branch tests
    /// §5.10.2 `initial_step` (`Gen.init_arms`).
    else_arm: struct { from: u32, to: u32, depth: u32, else_dead: bool, init_at: ?usize = null },
    /// After the `else` arm: the closing brace, putting `su.dead` back.
    if_end: struct { depth: u32, was_dead: bool },
};

/// Writes `s` up to its first nested piece, pushing what follows that piece
/// onto `stack`, and returns the nested piece (null when `s` had none).
fn emitStep(self: *Gen, s: Step, stack: *std.ArrayList(Resume), target: Mir.Value) Error!?Step {
    switch (s) {
        .tree => |t| {
            if (!self.an.is_loop[t.bi]) return .{ .code = .{ .bi = t.bi, .depth = t.depth } };
            // `setup` ends at a loop with a per-eval branch: nothing it can reach
            // is placeable, and forcing its tests `then` could spin forever. The
            // stop is a runtime flag so the structure after it still compiles.
            const was_dead = self.su.dead;
            if (self.su.mode and self.sinv.loop_varying[t.bi] and !was_dead) {
                self.su.stop = true;
                try gen_setup.emitStores(self, t.depth, "if (zs_stop) ");
                self.su.dead = true; // the loop runs only on a false `zs_stop`
            }
            try self.ind(t.depth);
            try self.b("L{d}: while (true) {{\n", .{t.bi});
            try gen_unit.scopeOpen(self);
            try stack.append(self.gpa, .{ .loop_end = .{ .depth = t.depth, .was_dead = was_dead } });
            return .{ .code = .{ .bi = t.bi, .depth = t.depth + 1 } };
        },
        .code => |c| return emitCode(self, c.bi, c.depth, stack, target),
        .edge => |e| {
            try emitPhiCopies(self, e.from, e.to, e.depth);
            if (self.an.is_loop[e.to] and self.an.dominates(e.to, e.from)) {
                try self.ind(e.depth);
                try self.b("continue :L{d};\n", .{e.to});
            } else if (self.an.is_merge[e.to]) {
                try self.ind(e.depth);
                try self.b("break :B{d};\n", .{e.to});
            } else return .{ .tree = .{ .bi = e.to, .depth = e.depth } };
            return null;
        },
    }
}

/// Writes what `r` left, up to its next nested piece (see `emitStep`).
fn emitResume(self: *Gen, r: Resume, stack: *std.ArrayList(Resume)) Error!?Step {
    switch (r) {
        .loop_end => |l| {
            gen_unit.scopeClose(self, self.out.items.len);
            try self.ind(l.depth);
            try self.b("}}\n", .{});
            self.su.dead = l.was_dead;
            return null;
        },
        .else_arm => |e| {
            if (e.init_at) |at| try self.init_arms.append(self.arena, .{ at, self.out.items.len });
            gen_unit.scopeClose(self, self.out.items.len);
            try self.ind(e.depth);
            try self.b("}} else {{\n", .{});
            try gen_unit.scopeOpen(self);
            const was_dead = self.su.dead;
            self.su.dead = e.else_dead;
            try stack.append(self.gpa, .{ .if_end = .{ .depth = e.depth, .was_dead = was_dead } });
            return .{ .edge = .{ .from = e.from, .to = e.to, .depth = e.depth + 1 } };
        },
        .if_end => |e| {
            gen_unit.scopeClose(self, self.out.items.len);
            try self.ind(e.depth);
            try self.b("}}\n", .{});
            self.su.dead = e.was_dead;
            return null;
        },
        .merge_kids => |m0| {
            var m = m0;
            // Peephole: `B{k}: { break :B{k}; }` and `B{k}: {}` both fall
            // through to `k`'s code, emitted right after the brace anyway, so
            // the label is dropped by rewinding `out`. `planDeadBranches`
            // leaves many of these.
            // A `merge_kids` row is pushed only for a block with merge children.
            assert(m.mc.len > 0);
            assert(m.j <= m.mc.len);
            if (!m.peeped) {
                m.peeped = true;
                m.dropped = isFallThrough(self, m.body_start, m.depth, m.mc[0]);
                if (m.dropped) {
                    assert(m.at_inner <= m.body_start);
                    assert(m.depth > 0);
                    self.out.shrinkRetainingCapacity(m.at_inner);
                    gen_unit.scopeClose(self, m.at_inner);
                    m.depth -= 1;
                }
            }
            if (m.j == m.mc.len) return null;
            const k = m.mc[m.j];
            if (m.j != 0 or !m.dropped) {
                assert(m.depth > 0);
                m.depth -= 1;
                gen_unit.scopeClose(self, self.out.items.len);
                try self.ind(m.depth);
                try self.b("}}\n", .{});
            }
            m.j += 1;
            // The last child is written at this block's own depth after
            // everything else: no row is left for it.
            if (m.j != m.mc.len) try stack.append(self.gpa, .{ .merge_kids = m });
            return .{ .tree = .{ .bi = k, .depth = m.depth } };
        },
    }
}

/// Writes block `bi` inside the labelled blocks of the merge children it
/// dominates; the children follow, after their labels close (`merge_kids`).
/// A chain of blocks each the only, inlined successor of the last (what
/// if-conversion leaves of a run of `if`s) is written in this loop.
fn emitCode(self: *Gen, bi0: u32, depth0: u32, stack: *std.ArrayList(Resume), target: Mir.Value) Error!?Step {
    var bi = bi0;
    var depth = depth0;
    // Each turn moves to an inlined successor that is never a loop header,
    // so the chain visits a block at most once.
    var turns: usize = 0;
    while (true) : (turns += 1) {
        assert(turns < self.an.term.len);
        assert(bi < self.an.term.len);
        const mc = self.an.mk_pool[self.an.mk_off[bi]..self.an.mk_off[bi + 1]];
        // Start of the innermost label (`mc[0]`, opened last); the peephole
        // rewinds to it.
        var at_inner: usize = 0;
        var i = mc.len;
        while (i > 0) {
            i -= 1;
            if (i == 0) at_inner = self.out.items.len;
            try self.ind(depth);
            try self.b("B{d}: {{\n", .{mc[i]});
            try gen_unit.scopeOpen(self);
            depth += 1;
        }
        const body_start = self.out.items.len;
        if (mc.len != 0) assert(at_inner < body_start);
        try emitBlockInsts(self, bi, depth, false);
        // With no label to close after it, an edge the terminator writes
        // inline is the last thing this block writes: take it as the next
        // turn.
        if (mc.len == 0) if (inlineSuccessor(self, bi)) |to| {
            try emitPhiCopies(self, bi, to, depth);
            bi = to;
            continue;
        };
        if (mc.len != 0) try stack.append(self.gpa, .{ .merge_kids = .{
            .mc = mc,
            .j = 0,
            .depth = depth,
            .at_inner = at_inner,
            .body_start = body_start,
            .peeped = false,
            .dropped = false,
        } });
        return emitTerm(self, bi, depth, stack, target);
    }
}

/// The block `emitTerm` would write inline as `bi`'s only successor, through
/// an edge and a subtree that opens no loop: the target of a jump, or
/// the `then` arm of a dead branch, when that is neither a back edge nor a
/// merge nor a loop header. Null otherwise. If-conversion leaves a chain of
/// such jumps, one per converted `if`.
fn inlineSuccessor(self: *const Gen, bi: u32) ?u32 {
    const t = self.an.term[bi];
    if (t == .none) return null;
    const to: u32 = switch (self.mir.instData(t)) {
        .jump => |d| @backingInt(d.target),
        .branch => |d| if (self.plan.dead_branch.isSet(bi)) @backingInt(d.then_block) else return null,
        .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => unreachable,
    };
    if (self.an.is_loop[to] or self.an.is_merge[to]) return null;
    return to;
}

/// Is everything emitted since `at` exactly "leave the block labelled `k`"?
/// A break to any other label is not: dropping the label would then let
/// control fall into `k`'s code instead of past it.
fn isFallThrough(self: *const Gen, at: usize, depth: u32, k: u32) bool {
    assert(at <= self.out.items.len);
    const body = self.out.items[at..];
    if (body.len == 0) return true;
    var buf: [64]u8 = undefined;
    const want = std.mem.print(&buf, "break :B{d};\n", .{k}) catch return false;
    const w = Gen.indWidth(depth);
    if (body.len != w + want.len) return false;
    return std.mem.allEqual(u8, body[0..w], ' ') and std.mem.eql(u8, body[w..], want);
}

/// Writes block `bi`'s terminator up to its first edge: the unit's return,
/// or the edge of a jump, or `if (cond) {` with the `else` arm pushed.
fn emitTerm(self: *Gen, bi: u32, depth: u32, stack: *std.ArrayList(Resume), target: Mir.Value) Error!?Step {
    const t = self.an.term[bi];
    if (t == .none) {
        // The block lowering ended in: the contribution accumulators are
        // read here (§5.6.1.3).
        try emitReturn(self, depth, target);
        return null;
    }
    switch (self.mir.instData(t)) {
        .jump => |d| return .{ .edge = .{ .from = bi, .to = @backingInt(d.target), .depth = depth } },
        .branch => |d| {
            // `planDeadBranches`: both arms reconverge with nothing this
            // unit can observe in between, so emit the common action once.
            if (self.plan.dead_branch.isSet(bi))
                return .{ .edge = .{ .from = bi, .to = @backingInt(d.then_block), .depth = depth } };
            try self.ind(depth);
            try self.b("if (", .{});
            var else_dead = self.su.dead;
            if (self.su.mode and !self.sinv.val[@backingInt(self.an.rv(d.cond))]) {
                // `setup` takes a per-eval branch `then` without testing it:
                // neither arm holds setup work, and a §5.10.2 initial-step
                // arm is exactly what it must compute (prove/setup.zig's
                // header). Both arms are still emitted, behind the always-true
                // runtime flag, so every label and break stays where the
                // relooper put it.
                self.su.stop = true;
                else_dead = true;
                try self.b("zs_stop", .{});
            } else try renderCond(self, d.cond);
            try self.b(") {{\n", .{});
            try gen_unit.scopeOpen(self);
            const init_at: ?usize = if (!self.su.mode and initialStep(self, d.cond)) self.out.items.len else null;
            try stack.append(self.gpa, .{ .else_arm = .{ .from = bi, .to = @backingInt(d.else_block), .depth = depth, .else_dead = else_dead, .init_at = init_at } });
            return .{ .edge = .{ .from = bi, .to = @backingInt(d.then_block), .depth = depth + 1 } };
        },
        // `an.term` is the block's branch or jump, found by opcode.
        .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => unreachable,
    }
}

/// Whether `cond` is a §5.10.2 `initial_step` event's flag, with or without
/// an analysis list.
fn initialStep(self: *const Gen, cond: Mir.Value) bool {
    const def = self.mir.valueDef(self.an.rv(cond));
    if (def != .inst_result or self.mir.instOp(def.inst_result) != .call) return false;
    return self.mir.instData(def.inst_result).call.callee == .initial_step;
}

/// Writes `cond` as a Zig bool (`!= 0` on its scalar value) and pins lanes
/// if it depends on x.
pub fn renderCond(self: *Gen, cond: Mir.Value) Error!void {
    const v = self.an.rv(cond);
    if (self.an.tyOf(v) == .int) {
        float_lanes.pinLanes(self, cond);
        try gen_render.renderVal(self, v, .int);
        try self.b(" != 0", .{});
    } else {
        float_lanes.leadLanes(self, cond);
        try self.b("zCmp(S, .neq, ", .{});
        try gen_render.renderVal(self, v, .real);
        try self.b(", S.con(0.0))", .{});
    }
}

/// Writes the phi copies on the edge `from -> to`. They go through
/// temporaries only when an incoming value reads a phi of `to` itself (a swap,
/// or a loop counter's `i + 1`), where sequential assignment would let a
/// later copy see an earlier one's new value. Otherwise they are written
/// straight into the slots.
///
/// Asserts that `from` and `to` are blocks of the unit.
fn emitPhiCopies(self: *Gen, from: u32, to: u32, depth: u32) Error!void {
    assert(from < self.an.term.len);
    assert(to < self.an.term.len);
    const phis = self.an.phi_pool[self.an.phi_off[to]..self.an.phi_off[to + 1]];
    var n: u32 = 0;
    var reads_own = false;
    for (phis) |inst| {
        if (!slotted(self, inst)) continue;
        n += 1;
        if (!reads_own) reads_own = readsPhiOf(self, self.mir.phiIn(inst, @fromBackingInt(from)) orelse .undef, to, 0);
    }
    if (n == 0) return;
    const par = n > 1 and reads_own;
    if (par) {
        try self.ind(depth);
        try self.b("{{\n", .{});
    }
    const d2 = if (par) depth + 1 else depth;
    var k: u32 = 0;
    for (phis) |inst| {
        if (!slotted(self, inst)) continue;
        const i = @backingInt(self.an.i_res[@backingInt(inst)]);
        try self.ind(d2);
        var m: ?[]const u64 = null;
        if (par) {
            if (self.an.vty[i] == .real)
                try self.b("const c{d} = ", .{k})
            else
                try self.b("const c{d}: {s} = ", .{ k, try gen_unit.slotTy(self, i) });
        } else {
            gen_unit.probeDef(self, self.plan.slot[i], false);
            try gen_unit.writeSlotRef(self, i);
            try self.b(" = ", .{});
            m = gen_unit.slotMask(self, i);
            if (m) |mk| try family.openTo(self, mk);
        }
        try gen_render.renderVal(self, self.mir.phiIn(inst, @fromBackingInt(from)) orelse .undef, self.an.vty[i]);
        if (m != null) try self.b(")", .{});
        try self.b(";\n", .{});
        k += 1;
    }
    assert(k == n);
    if (!par) return;
    k = 0;
    for (phis) |inst| {
        if (!slotted(self, inst)) continue;
        try self.ind(d2);
        const i = @backingInt(self.an.i_res[@backingInt(inst)]);
        gen_unit.probeDef(self, self.plan.slot[i], false);
        try gen_unit.writeSlotRef(self, i);
        if (gen_unit.slotMask(self, i)) |mk|
            try self.b(" = zTo(S, 0x{f}, c{d});\n", .{ gen_mask.hex(mk, false), k })
        else
            try self.b(" = c{d};\n", .{k});
        k += 1;
    }
    assert(k == n);
    try self.ind(depth);
    try self.b("}}\n", .{});
}

/// Does rendering `v` read the slot of a phi defined in block `to`? Walks the
/// inline tree `renderVal` would print and stops at materialized values.
/// Answers yes past the depth cap, which keeps the temporaries.
fn readsPhiOf(self: *Gen, v0: Mir.Value, to: u32, depth: u32) bool {
    if (depth > 64) return true;
    const v = self.an.rv(v0);
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return false;
    const inst = def.inst_result;
    if (self.mir.instOp(inst) == .phi) return self.an.def_block[@backingInt(v)] == to;
    if (gen_render.materialized(self, v)) return false;
    return switch (self.mir.instData(inst)) {
        .unary => |d| readsPhiOf(self, d.operand, to, depth + 1),
        .binary => |d| readsPhiOf(self, d.lhs, to, depth + 1) or readsPhiOf(self, d.rhs, to, depth + 1),
        .ternary => |d| readsPhiOf(self, d.cond, to, depth + 1) or
            readsPhiOf(self, d.then_val, to, depth + 1) or readsPhiOf(self, d.else_val, to, depth + 1),
        .call => |d| for (d.args) |a| {
            if (readsPhiOf(self, a, to, depth + 1)) break true;
        } else false,
        .load => |d| readsPhiOf(self, d.index, to, depth + 1),
        .phi, .branch, .jump, .anew, .store => true,
    };
}

/// Returns whether this unit materializes the pooled phi `inst` into a
/// local slot.
fn slotted(self: *const Gen, inst: Mir.Inst) bool {
    const i = @backingInt(self.an.i_res[@backingInt(inst)]);
    return self.plan.needed.isSet(i) and self.plan.slot[i] != none_u32;
}
