//! Target-independent facts about a lowered module: Mir + Lowered → CFG,
//! dominator and post-dominator trees, natural loops, flattened per-block
//! instruction pools, and per-Value tables (type, alias snapshot, derivative
//! dependencies, array owner, constant fold). Built once, then read-only. Nothing here knows the
//! target is Zig, so `prove` never imports `device`; per-unit scheduling tables
//! belong to the emitter.
//!
//! LRM clauses this file's code cites: §3.2, §3.4, §4.2, §4.2.1.1, §4.2.1.2,
//! §4.2.3, §4.2.4, §4.2.12, §4.4, §4.5, §5.9, §5.10, §6.3.4, §9.15.
//! IEEE 1364-2005 clauses cited: §5.4.

const std = @import("std");
const Mir = @import("ir").Mir;
const Lower = @import("ir").Lowered;
const Lowered = Lower.Lowered;
const Const = Lower.Const;
const op_kind = @import("ir").op;

/// File-as-struct: `@import("analysis.zig")` is both the namespace and the type.
pub const Analysis = @This();

/// Every builder here fails only on allocation.
pub const Error = std.mem.Allocator.Error;

const none_u32 = std.math.maxInt(u32);

/// How a Value is emitted: as the generic scalar `S` (real), a plain `i64`
/// (§3.2 integer) or a string. §4.2.1.1/§4.2.1.2 conversions are inserted at the use
/// site, so a typing miss degrades to a redundant cast, never to code that does
/// not compile.
pub const VTy = Mir.callee.Ty;

/// Owns every table below.
arena: std.mem.Allocator,
/// Borrowed; must outlive the Analysis and not change after `build`.
mir: *const Mir,
/// Borrowed, as `mir` is.
lowered: *const Lowered,

/// Block count.
nb: u32 = 0,
/// Reverse-postorder number per block, `none_u32` if unreachable.
rpo_num: []u32 = &.{},
/// Reachable blocks in reverse postorder.
rpo: []u32 = &.{},
/// Immediate dominator per block, `none_u32` if unreachable.
idom: []u32 = &.{},
/// Reachable predecessors per block.
preds: [][]u32 = &.{},
/// Successors per block, in branch order.
succs: [][]u32 = &.{},
/// Dominator-tree children of block `b`, in RPO order:
/// `kid_pool[kid_off[b]..kid_off[b + 1]]` (`domKids`). One pool, not a slice
/// per block: every block has a parent but the entry, so the pool is exactly
/// `nb - 1` words.
kid_pool: []u32 = &.{},
kid_off: []u32 = &.{},
/// Euler-tour numbering of the dominator tree, so `dominates` is O(1)
/// instead of an idom walk (`none_u32` = block not in the tree).
dom_in: []u32 = &.{},
dom_out: []u32 = &.{},
/// Block has two or more predecessors. `[]bool` because every probe is one
/// block at a time and block counts are small.
is_merge: []bool = &.{},
/// Block is a loop header (it dominates one of its predecessors).
is_loop: []bool = &.{},
/// The outermost loop header whose natural loop contains this block, or
/// `none_u32`. Outermost, so a whole nest is one decision for the emitter.
loop_of: []u32 = &.{},
/// Every instruction of block `b`, in emission order:
/// `inst_pool[inst_off[b]..inst_off[b + 1]]`. A flat window so later walks
/// avoid chasing the MIR's intrusive `next` chain.
inst_pool: []Mir.Inst = &.{},
inst_off: []u32 = &.{},
/// Non-aliased phis of block `b`, in emission order:
/// `phi_pool[phi_off[b]..phi_off[b + 1]]`. The emitter reads it once per CFG
/// edge, where re-walking the chain would be quadratic in in-degree.
phi_pool: []Mir.Inst = &.{},
phi_off: []u32 = &.{},
/// Same shape, for the instructions a unit body can emit: everything except
/// phis, terminators, and values aliased away. Read once per block per unit.
stmt_pool: []Mir.Inst = &.{},
stmt_off: []u32 = &.{},
/// Merge-block dominator children of `b`: `mk_pool[mk_off[b]..mk_off[b+1]]`.
mk_pool: []u32 = &.{},
mk_off: []u32 = &.{},
/// MIR `op` column, hoisted once (borrowed from `mir`).
i_op: []const Mir.Opcode = &.{},
/// MIR `result` column, hoisted once (borrowed from `mir`).
i_res: []const Mir.Value = &.{},
/// Terminator per block, `.none` if the block has none.
term: []Mir.Inst = &.{},
/// Block a Value is defined in (`none_u32` for constants/params/probes).
def_block: []u32 = &.{},
/// Immediate post-dominator per block, `nb + 1` long: index `nb` is a virtual
/// exit that every block with no successor, and every block that cannot
/// reach one, flows to (`ipdom[nb] == nb`). Filled by `build` only.
ipdom: []u32 = &.{},
/// The branch conditions that pick which edge reaches block `b`, so which
/// incoming value its phis take: `steer_pool[steer_off[b]..steer_off[b + 1]]`.
/// A branch steers its immediate post-dominator, where its arms rejoin, and
/// every branch inside a loop nest steers each header of that nest (how many
/// times round). Only the `xdeps`/`pdeps` phi rule reads it. Filled by `build`.
steer_pool: []Mir.Value = &.{},
steer_off: []u32 = &.{},

/// Value count, sentinels included.
nv: u32 = 0,
/// Emitted type per Value.
vty: []VTy = &.{},
/// Per Value, the bits of a `.wide` one (`wideWidth`); 0 for every other.
wide_w: []u32 = &.{},
/// `mir.resolveAlias` evaluated once for every Value, so `rv` is one load and
/// readers never write through `resolveAlias`'s path compression.
/// Invariant: nothing calls `Mir.setAlias` after `build`/`buildStructure`.
alias: []Mir.Value = &.{},

/// Words per Value in every dependency column: `max(1, ceil(n_u / 64))`,
/// `n_u` the unknown count (`Lowered.nodes`, or past the highest probe).
dep_words: u32 = 1,
/// Per Value, `dep_words` words (`deps[v * dep_words ..][0..dep_words]`):
/// which unknowns its derivative can be nonzero in. Bit `u` (word `u / 64`,
/// bit `u % 64`) set means `∂value/∂x[u]` may be nonzero; no bit at all is
/// `dFree`. This is the structural Jacobian: a clear column is a stamp the
/// host can drop at compile time. Exact at any unknown count, and sound in
/// one direction: a set bit is always safe, so every rule over-approximates.
/// `xdeps`, `pdeps` and `acdyn` have the same shape.
deps: []u64 = &.{},
/// Which unknowns the value can vary with (`xDep`): `deps`, plus what passes
/// a `dstop`, plus what steers a value without entering its derivative (a
/// select's condition, an array index, the branches that pick a phi's
/// incoming edge: `steer_pool`).
xdeps: []u64 = &.{},
/// `xdeps` plus the per-instance values a value can vary with: a §5.10 held
/// variable, `$mfactor`, a `$prev`/charge path latch (`pointDep`). The same
/// slice as `xdeps` when the module reads none.
pdeps: []u64 = &.{},
/// Per Value: the unknowns whose derivative reaches it through an operator
/// whose small-signal response depends on frequency (`op.acDynamic`). A
/// subset of `deps`, and empty when the module calls no such operator.
acdyn: []u64 = &.{},
/// `dep_words` zero words: `acDynDeps`' answer when `acdyn` is empty.
dep_zero: []const u64 = &.{},
/// §3.2.2 per Value: the `Lowered.mem_arrays` row an array version belongs to
/// (an `anew`, a `store`, or a phi over them), `none_u32` for every scalar.
/// Its `vty` is the element type. Every version of one array is one storage.
arr_of: []u32 = &.{},
/// `foldConst`'s answer per Value: `[0]` sees a parameter as the host sets
/// it, `[1]` looks through it to its declared default.
folds: [2]FoldColumn = .{ .{}, .{} },

/// One `folds` column as two parallel arrays. A `?Const` is 24 bytes, all for
/// the string arm's slice, and nearly every fold is a number: `kind` says
/// which arm a Value folded to, `bits` holds an integer's or a real's bits,
/// or a string's index in `strs`. 9 bytes a Value instead of 24, in the
/// table with one row per Value that codegen keeps for the whole emit.
const FoldColumn = struct {
    /// Which `Const` arm each Value folded to, `.none` for no fold.
    kind: []Kind = &.{},
    /// The arm's payload: an integer's or a real's bits, or an index into
    /// `strs`. Meaningless where `kind` is `.none`.
    bits: []u64 = &.{},
    /// The string folds, in the order they were found; borrowed slices.
    strs: std.ArrayList([]const u8) = .empty,

    const Kind = enum(u8) { none, int, real, str };

    fn get(c: *const FoldColumn, v: Mir.Value) ?Const {
        const i = @backingInt(v);
        const b = c.bits[i];
        return switch (c.kind[i]) {
            .none => null,
            .int => .{ .int = @bitCast(b) },
            .real => .{ .real = @bitCast(b) },
            .str => .{ .str = c.strs.items[@intCast(b)] },
        };
    }

    fn set(c: *FoldColumn, arena: std.mem.Allocator, i: usize, x: Const) Error!void {
        switch (x) {
            .int => |n| {
                c.kind[i] = .int;
                c.bits[i] = @bitCast(n);
            },
            .real => |r| {
                c.kind[i] = .real;
                c.bits[i] = @bitCast(r);
            },
            .str => |t| {
                c.kind[i] = .str;
                c.bits[i] = c.strs.items.len;
                try c.strs.append(arena, t);
            },
        }
    }
};

/// Builds every table above. Tables are allocated in `arena` and borrow
/// `mir`/`lowered`, which must outlive the result and not change after.
/// `mir` must have its entry block. Writes `mir`'s alias table (path
/// compression) and nothing else.
pub fn build(
    arena: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
) Error!Analysis {
    var self = try buildStructure(arena, mir, lowered);
    try self.buildPostDominators();
    try self.buildValueTypes();
    try self.buildDeps();
    try self.buildFolds();
    return self;
}

/// Builds the structural half alone: alias snapshot, CFG, dominator tree,
/// natural loops, per-block pools. `ipdom`, `vty`, `deps`, `arr_of` and
/// `folds` stay empty. For the prover, which runs before codegen's own `build` and needs
/// no value types; building them twice per compile measured slower. It adds
/// only `buildLiteralFolds` to identify provably untaken runtime-error paths.
/// `mir` must have its entry block.
pub fn buildStructure(
    arena: std.mem.Allocator,
    mir: *const Mir,
    lowered: *const Lowered,
) Error!Analysis {
    var self: Analysis = .{ .arena = arena, .mir = mir, .lowered = lowered };
    self.nv = @intCast(mir.defs.len + Mir.Value.first_dynamic);
    self.alias = try arena.alloc(Mir.Value, self.nv);
    for (self.alias, 0..) |*p, v| p.* = mir.resolveAlias(@fromBackingInt(@intCast(v)));
    try self.buildCfg();
    return self;
}

/// Returns the Value `v` aliases to (the snapshot of `Mir.resolveAlias`).
pub fn rv(self: *const Analysis, v: Mir.Value) Mir.Value {
    return self.alias[@backingInt(v)];
}

/// Returns block `b`'s dominator-tree children, in RPO order.
pub fn domKids(self: *const Analysis, b: u32) []const u32 {
    return self.kid_pool[self.kid_off[b]..self.kid_off[b + 1]];
}

/// Returns block `bi`'s instructions as a contiguous window (see `inst_pool`).
pub inline fn blockInstsFlat(self: *const Analysis, bi: u32) []const Mir.Inst {
    return self.inst_pool[self.inst_off[bi]..self.inst_off[bi + 1]];
}

// ---------------------------------------------------------------- CFG ----

fn buildCfg(self: *Analysis) Error!void {
    const a = self.arena;
    const nb = self.mir.blockCount();
    std.debug.assert(nb > 0); // the entry block roots the DFS and the dominator tree
    self.nb = nb;
    self.i_op = self.mir.insts.items(.op);
    self.i_res = self.mir.insts.items(.result);
    self.term = try a.alloc(Mir.Inst, nb);
    self.succs = try a.alloc([]u32, nb);
    self.preds = try a.alloc([]u32, nb);
    self.rpo_num = try a.alloc(u32, nb);
    self.idom = try a.alloc(u32, nb);
    self.is_merge = try a.alloc(bool, nb);
    self.is_loop = try a.alloc(bool, nb);
    self.loop_of = try a.alloc(u32, nb);
    @memset(self.rpo_num, none_u32);
    @memset(self.idom, none_u32);
    @memset(self.is_loop, false);
    @memset(self.loop_of, none_u32);

    // Flatten the intrusive `next` chain once (count, then fill, so the pool
    // never grows). Order is the chain order, which is emission order and
    // therefore load-bearing.
    self.inst_off = try a.alloc(u32, nb + 1);
    var n_insts: u32 = 0;
    for (0..nb) |bi| {
        self.inst_off[bi] = n_insts;
        var it = self.mir.blockInsts(@fromBackingInt(@intCast(bi)));
        while (it.next()) |_| n_insts += 1;
    }
    self.inst_off[nb] = n_insts;
    self.inst_pool = try a.alloc(Mir.Inst, n_insts);
    var ki: u32 = 0;
    for (0..nb) |bi| {
        var it = self.mir.blockInsts(@fromBackingInt(@intCast(bi)));
        while (it.next()) |inst| {
            self.inst_pool[ki] = inst;
            ki += 1;
        }
    }

    // Terminator + successors. A phi may sit anywhere in the chain (ssa.zig
    // mints them on demand), so the terminator is found by opcode, not by
    // position.
    var pred_count = try a.alloc(u32, nb);
    @memset(pred_count, 0);
    for (0..nb) |bi| {
        self.term[bi] = .none;
        var s: [2]u32 = undefined;
        var ns: usize = 0;
        for (self.blockInstsFlat(@intCast(bi))) |inst| switch (Mir.opClass(self.mir.instOp(inst))) {
            .branch => {
                const d = self.mir.instData(inst).branch;
                self.term[bi] = inst;
                s[0] = @backingInt(d.then_block);
                s[1] = @backingInt(d.else_block);
                ns = 2;
            },
            .jump => {
                self.term[bi] = inst;
                s[0] = @backingInt(self.mir.instData(inst).jump.target);
                ns = 1;
            },
            .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => {},
        };
        self.succs[bi] = try a.dupe(u32, s[0..ns]);
    }

    // Reachability + postorder (iterative DFS, successor order = branch
    // order ⇒ deterministic).
    var post = try a.alloc(u32, nb);
    var n_post: u32 = 0;
    {
        var seen = try a.alloc(bool, nb);
        @memset(seen, false);
        const Frame = struct { b: u32, i: u32 };
        // `seen` admits each block once: at most `nb` frames.
        var stack: std.ArrayList(Frame) = try .initCapacity(a, nb);
        defer stack.deinit(a);
        stack.appendAssumeCapacity(.{ .b = 0, .i = 0 });
        seen[0] = true;
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            if (top.i < self.succs[top.b].len) {
                const s = self.succs[top.b][top.i];
                top.i += 1;
                if (!seen[s]) {
                    seen[s] = true;
                    stack.appendAssumeCapacity(.{ .b = s, .i = 0 });
                }
            } else {
                post[n_post] = top.b;
                n_post += 1;
                _ = stack.pop();
            }
        }
    }
    for (post[0..n_post], 0..) |bi, i| self.rpo_num[bi] = n_post - 1 - @as(u32, @intCast(i));
    self.rpo = try a.alloc(u32, n_post);
    for (post[0..n_post], 0..) |bi, i| self.rpo[n_post - 1 - i] = bi;

    // Predecessors (reachable only).
    for (0..nb) |bi| {
        if (self.rpo_num[bi] == none_u32) continue;
        for (self.succs[bi]) |s| pred_count[s] += 1;
    }
    for (0..nb) |bi| self.preds[bi] = try a.alloc(u32, pred_count[bi]);
    @memset(pred_count, 0);
    for (self.rpo) |bi| {
        for (self.succs[bi]) |s| {
            self.preds[s][pred_count[s]] = bi;
            pred_count[s] += 1;
        }
    }
    for (0..nb) |bi| self.is_merge[bi] = self.preds[bi].len > 1;
    self.is_merge[0] = false; // entry is never re-entered

    // Cooper/Harvey/Kennedy iterative dominators over reverse postorder.
    self.idom[0] = 0;
    var changed = true;
    while (changed) {
        changed = false;
        for (self.rpo[1..]) |bi| {
            var new: u32 = none_u32;
            for (self.preds[bi]) |p| {
                if (self.idom[p] == none_u32 and p != 0) continue;
                new = if (new == none_u32) p else self.intersect(new, p);
            }
            if (new != none_u32 and self.idom[bi] != new) {
                self.idom[bi] = new;
                changed = true;
            }
        }
    }

    // Dominator children, in RPO order (deterministic emission order):
    // counted, prefix-summed into `kid_off`, then filled.
    self.kid_off = try a.alloc(u32, nb + 1);
    @memset(self.kid_off, 0);
    for (self.rpo[1..]) |bi| self.kid_off[self.idom[bi] + 1] += 1;
    for (1..nb + 1) |bi| self.kid_off[bi] += self.kid_off[bi - 1];
    self.kid_pool = try a.alloc(u32, self.kid_off[nb]);
    const kid_fill = try a.dupe(u32, self.kid_off[0..nb]);
    for (self.rpo[1..]) |bi| {
        const p = self.idom[bi];
        self.kid_pool[kid_fill[p]] = bi;
        kid_fill[p] += 1;
    }

    // Merge-block dominator children, flattened in `domKids` order.
    self.mk_off = try a.alloc(u32, nb + 1);
    var n_mk: u32 = 0;
    for (0..nb) |bi| {
        self.mk_off[bi] = n_mk;
        for (self.domKids(@intCast(bi))) |k| {
            if (self.is_merge[k]) n_mk += 1;
        }
    }
    self.mk_off[nb] = n_mk;
    self.mk_pool = try a.alloc(u32, n_mk);
    var mk: u32 = 0;
    for (0..nb) |bi| {
        for (self.domKids(@intCast(bi))) |k| {
            if (self.is_merge[k]) {
                self.mk_pool[mk] = k;
                mk += 1;
            }
        }
    }

    // Euler tour of the dominator tree (explicit stack: large models nest
    // deeply enough to blow a recursive walk).
    self.dom_in = try a.alloc(u32, nb);
    self.dom_out = try a.alloc(u32, nb);
    @memset(self.dom_in, none_u32);
    @memset(self.dom_out, none_u32);
    const Frame = struct { node: u32, kid: u32 };
    const stack = try a.alloc(Frame, nb);
    var sp: usize = 1;
    var clock: u32 = 0;
    stack[0] = .{ .node = 0, .kid = 0 };
    self.dom_in[0] = clock;
    clock += 1;
    while (sp > 0) {
        const f = &stack[sp - 1];
        const kids = self.domKids(f.node);
        if (f.kid < kids.len) {
            const k = kids[f.kid];
            f.kid += 1;
            self.dom_in[k] = clock;
            clock += 1;
            stack[sp] = .{ .node = k, .kid = 0 };
            sp += 1;
        } else {
            self.dom_out[f.node] = clock;
            clock += 1;
            sp -= 1;
        }
    }

    // Per-block phi and statement pools, counted then filled (same two-pass
    // shape as `kid_pool`, so neither pool needs to grow).
    self.phi_off = try a.alloc(u32, nb + 1);
    self.stmt_off = try a.alloc(u32, nb + 1);
    var n_phis: u32 = 0;
    var n_stmts: u32 = 0;
    for (0..nb) |bi| {
        self.phi_off[bi] = n_phis;
        self.stmt_off[bi] = n_stmts;
        for (self.blockInstsFlat(@intCast(bi))) |inst| {
            if (self.livePhi(inst)) n_phis += 1;
            if (self.liveStmt(inst)) n_stmts += 1;
        }
    }
    self.phi_off[nb] = n_phis;
    self.stmt_off[nb] = n_stmts;
    self.phi_pool = try a.alloc(Mir.Inst, n_phis);
    self.stmt_pool = try a.alloc(Mir.Inst, n_stmts);
    var kp: u32 = 0;
    var ks: u32 = 0;
    for (0..nb) |bi| {
        for (self.blockInstsFlat(@intCast(bi))) |inst| {
            if (self.livePhi(inst)) {
                self.phi_pool[kp] = inst;
                kp += 1;
            }
            if (self.liveStmt(inst)) {
                self.stmt_pool[ks] = inst;
                ks += 1;
            }
        }
    }

    // A loop header dominates at least one of its predecessors (back edge).
    for (self.rpo) |bi| {
        for (self.preds[bi]) |p| {
            if (self.dominates(bi, p)) self.is_loop[bi] = true;
        }
    }

    // The NATURAL LOOP BODY of every header, for the §5.9 `loop_recompute`
    // fixpoint and for `edgeAct`'s `inLoop` guard. Standard construction:
    // walk predecessors backwards from each back edge, stopping at the
    // header; every block reached is inside that loop.
    //
    // Not "everything the header dominates": that also covers the region past
    // the loop's exit, so a model whose analog block opens with a `for` would
    // lose hoisting for its entire body.
    //
    // `rpo` visits an outer header before an inner one, and the first write
    // wins, so `loop_of` ends up naming the outermost nest. That is what
    // makes a nest one decision: re-materializing an inner loop needs the
    // outer loop's structure too, so they stand or fall together.
    // A block is pushed only as its `loop_of` is first set: at most one row each.
    var body: std.ArrayList(u32) = try .initCapacity(self.arena, self.loop_of.len);
    defer body.deinit(self.arena);
    for (self.rpo) |h| {
        if (!self.is_loop[h]) continue;
        if (self.loop_of[h] == none_u32) self.loop_of[h] = h;
        for (self.preds[h]) |p| {
            if (!self.dominates(h, p)) continue; // not a back edge
            if (self.loop_of[p] != none_u32 and p != h) continue;
            if (p != h) {
                self.loop_of[p] = self.loop_of[h];
                body.appendAssumeCapacity(p);
            }
            while (body.pop()) |cur| {
                for (self.preds[cur]) |q| {
                    if (self.loop_of[q] != none_u32) continue;
                    self.loop_of[q] = self.loop_of[h];
                    body.appendAssumeCapacity(q);
                }
            }
        }
    }
}

fn intersect(self: *const Analysis, x0: u32, y0: u32) u32 {
    var x = x0;
    var y = y0;
    while (x != y) {
        while (self.rpo_num[x] > self.rpo_num[y]) x = self.idom[x];
        while (self.rpo_num[y] > self.rpo_num[x]) y = self.idom[y];
    }
    return x;
}

/// Fill `ipdom`. Cooper, Harvey and Kennedy's iteration over the reverse CFG,
/// in its reverse postorder.
fn buildPostDominators(self: *Analysis) Error!void {
    const a = self.arena;
    const nb = self.nb;
    const exit = nb;
    // Blocks with no successor end the body; a block that cannot reach one
    // (a loop with no exit) is given a virtual edge so every block has an
    // ipdom.
    const reaches = try a.alloc(bool, nb + 1);
    @memset(reaches, false);
    // Each block is pushed at most once (its flag is set first).
    var stack: std.ArrayList(u32) = try .initCapacity(a, nb);
    for (0..nb) |b| if (self.succs[b].len == 0) {
        reaches[b] = true;
        stack.appendAssumeCapacity(@intCast(b));
    };
    while (stack.pop()) |b| for (self.preds[b]) |p| {
        if (reaches[p]) continue;
        reaches[p] = true;
        stack.appendAssumeCapacity(p);
    };
    const to_exit = try a.alloc(bool, nb);
    for (0..nb) |b| to_exit[b] = self.succs[b].len == 0 or !reaches[b];

    // Postorder of the reverse CFG from `exit`: its successors there are the
    // CFG predecessors.
    const po = try a.alloc(u32, nb + 1);
    const num = try a.alloc(u32, nb + 1);
    @memset(num, none_u32);
    const seen = try a.alloc(bool, nb + 1);
    @memset(seen, false);
    var n_po: u32 = 0;
    const Frame = struct { b: u32, i: u32 };
    // Each block and `exit` is pushed at most once (`seen`).
    var dfs: std.ArrayList(Frame) = try .initCapacity(a, nb + 1);
    dfs.appendAssumeCapacity(.{ .b = exit, .i = 0 });
    seen[exit] = true;
    while (dfs.items.len != 0) {
        const top = &dfs.items[dfs.items.len - 1];
        const next: ?u32 = blk: {
            if (top.b == exit) {
                while (top.i < nb) : (top.i += 1) {
                    if (to_exit[top.i] and !seen[top.i]) break :blk top.i;
                }
                break :blk null;
            }
            const ps = self.preds[top.b];
            while (top.i < ps.len) : (top.i += 1) {
                if (!seen[ps[top.i]]) break :blk ps[top.i];
            }
            break :blk null;
        };
        if (next) |n| {
            top.i += 1;
            seen[n] = true;
            dfs.appendAssumeCapacity(.{ .b = n, .i = 0 });
        } else {
            num[top.b] = n_po;
            po[n_po] = top.b;
            n_po += 1;
            _ = dfs.pop();
        }
    }
    // `exit` roots the walk, so it is numbered last; each block at most once.
    std.debug.assert(n_po <= nb + 1);
    std.debug.assert(po[n_po - 1] == exit);

    const ipdom = try a.alloc(u32, nb + 1);
    @memset(ipdom, none_u32);
    ipdom[exit] = exit;
    // Bound: the iteration is the dominator dataflow, monotone per block: a
    // block's ipdom is set once from `none_u32`, then its dominator chain only
    // shrinks, at most `nb + 1` times. Every round but the last changes one,
    // so at most `(nb + 1) * (nb + 2) + 1` rounds.
    const rounds_max = (@as(usize, nb) + 1) * (@as(usize, nb) + 2) + 1;
    var rounds: usize = 0;
    var changed = true;
    while (changed) : (rounds += 1) {
        std.debug.assert(rounds < rounds_max);
        changed = false;
        var k = n_po;
        while (k > 0) {
            k -= 1;
            const b = po[k];
            if (b == exit) continue;
            var new: u32 = none_u32;
            // Reverse-graph predecessors of b are its CFG successors (and the
            // virtual exit).
            const extra: []const u32 = if (to_exit[b]) &.{exit} else &.{};
            for ([_][]const u32{ self.succs[b], extra }) |list| for (list) |s| {
                if (ipdom[s] == none_u32) continue;
                new = if (new == none_u32) s else pdomIntersect(ipdom, num, s, new);
            };
            if (new != none_u32 and ipdom[b] != new) {
                ipdom[b] = new;
                changed = true;
            }
        }
    }
    std.debug.assert(ipdom[exit] == exit);
    self.ipdom = ipdom;
}

fn pdomIntersect(ipdom: []const u32, num: []const u32, b1: u32, b2: u32) u32 {
    std.debug.assert(ipdom.len == num.len);
    std.debug.assert(b1 < num.len);
    std.debug.assert(b2 < num.len);
    var f1 = b1;
    var f2 = b2;
    // Bound: every pass moves at least one finger to a higher postorder
    // number, and each finger can rise at most `num.len` times.
    var passes: usize = 0;
    while (f1 != f2) : (passes += 1) {
        std.debug.assert(passes < 2 * num.len);
        while (num[f1] < num[f2]) f1 = ipdom[f1];
        while (num[f2] < num[f1]) f2 = ipdom[f2];
    }
    return f1;
}

/// Returns whether block `a` dominates block `x`. O(1) via the Euler-tour
/// interval. Unreachable blocks dominate only themselves. Asserts that both
/// are below `nb`.
pub fn dominates(self: *const Analysis, a: u32, x: u32) bool {
    std.debug.assert(a < self.nb);
    std.debug.assert(x < self.nb);
    const ia = self.dom_in[a];
    const ix = self.dom_in[x];
    if (ia == none_u32 or ix == none_u32) return a == x;
    return ia <= ix and self.dom_out[x] <= self.dom_out[a];
}

// -------------------------------------------------------------- values ----

fn buildValueTypes(self: *Analysis) Error!void {
    const a = self.arena;
    self.vty = try a.alloc(VTy, self.nv); // `nv` was set in `buildStructure`
    self.def_block = try a.alloc(u32, self.nv);
    @memset(self.def_block, none_u32);
    // No `vty` prefill: every arm of the base pass below assigns its index.

    for (0..self.nb) |bi| {
        for (self.blockInstsFlat(@intCast(bi))) |inst| {
            const r = self.mir.instResult(inst);
            if (r == .undef) continue;
            self.def_block[@backingInt(r)] = @intCast(bi);
        }
    }

    // Base pass: constants and opcodes decide themselves. Not a SIMD
    // candidate: most elements gather (`instOp`, `params`), and value counts
    // are small.
    try self.buildArrOf();
    var v: u32 = 0;
    while (v < self.nv) : (v += 1) {
        const val: Mir.Value = @fromBackingInt(@intCast(v));
        if (self.arr_of[v] != none_u32) {
            self.vty[v] = if (self.lowered.mem_arrays.items[self.arr_of[v]].ty == .integer) .int else .real;
            continue;
        }
        self.vty[v] = switch (self.mir.valueDef(val)) {
            .undef => .real,
            .float_const => .real,
            .int_const => .int,
            .str_const => .str,
            .param_ref => |p| tyOfParam(self.lowered.params.items[p].ty),
            .block_param => .real,
            .inst_result => |inst| blk: {
                const op = self.mir.instOp(inst);
                if (op == .call) break :blk Mir.callee.ty(self.mir.instData(inst).call.callee);
                if (op == .phi or op == .select) break :blk .real; // refined below
                break :blk if (Mir.opIsInteger(op)) .int else .real;
            },
        };
    }
    // Refine `select` and `phi` from their operands, to a fixpoint as
    // `buildDeps` does: SSA construction creates a chain of joins outer-first,
    // so the outer phi precedes its operand in value order and each sweep
    // settles one more link.
    //
    // Terminates: every refined value copies exactly one other value's type,
    // so the refined values form a functional graph. A chain settles one link
    // per sweep; a cycle (a loop-carried phi whose first operand leads back to
    // itself) is uniform after one sweep and then copies itself.
    var changed = true;
    while (changed) {
        changed = false;
        v = Mir.Value.first_dynamic;
        while (v < self.nv) : (v += 1) {
            const val: Mir.Value = @fromBackingInt(@intCast(v));
            const def = self.mir.valueDef(val);
            if (def != .inst_result) continue;
            const inst = def.inst_result;
            const src: Mir.Value = switch (Mir.opClass(self.mir.instOp(inst))) {
                .ternary => self.rv(self.mir.instData(inst).ternary.then_val), // `select`, the only ternary
                .phi => blk: {
                    const d = self.mir.instData(inst).phi;
                    if (d.count == 0) continue;
                    const first = self.rv(self.mir.phiPair(inst, 0).value);
                    if (first == .undef) continue;
                    break :blk first;
                },
                .unary, .binary, .branch, .jump, .call, .anew, .load, .store => continue,
            };
            const t = self.vty[@backingInt(src)];
            if (self.vty[v] == t) continue;
            self.vty[v] = t;
            changed = true;
        }
    }
    try self.buildWideWidths();
}

/// IEEE 1364-2005 §5.4: the bits of every `.wide` value, from its defining
/// call (`$wide`'s root node, a held variable's or a timepoint slot's
/// width) or, for a `select` or `phi`, from the operand `vty` copied.
fn buildWideWidths(self: *Analysis) Error!void {
    self.wide_w = try self.arena.alloc(u32, self.nv);
    @memset(self.wide_w, 0);
    if (self.lowered.wide_nodes.items.len == 0) return;
    // A width only goes from 0 to set, so each changing sweep sets one more.
    var sweeps: u32 = 0;
    var changed = true;
    while (changed) : (sweeps += 1) {
        std.debug.assert(sweeps <= self.nv);
        changed = false;
        for (Mir.Value.first_dynamic..self.nv) |v| {
            if (self.vty[v] != .wide or self.wide_w[v] != 0) continue;
            const def = self.mir.valueDef(@fromBackingInt(@intCast(v)));
            if (def != .inst_result) continue;
            const inst = def.inst_result;
            const w: u32 = switch (Mir.opClass(self.mir.instOp(inst))) {
                .ternary => self.wide_w[@backingInt(self.rv(self.mir.instData(inst).ternary.then_val))],
                .phi => self.wide_w[@backingInt(self.rv(self.mir.phiPair(inst, 0).value))],
                .call => blk: {
                    const d = self.mir.instData(inst).call;
                    const k: usize = @intCast(self.intArg(d.args, 0) orelse break :blk 0);
                    break :blk switch (d.callee) {
                        .@"$wide" => self.lowered.wide_nodes.items[k].width,
                        .@"$held_wide" => self.lowered.held_vars.items[k].width,
                        .@"$tp_wide" => self.lowered.timepoints.items[k].slots[@intCast(self.intArg(d.args, 1) orelse break :blk 0)].width,
                        else => 0, // else: `Callee.table` types only these three `.wide`
                    };
                },
                .unary, .binary, .branch, .jump, .anew, .load, .store => 0,
            };
            if (w == 0) continue;
            self.wide_w[v] = w;
            changed = true;
        }
    }
}

/// Returns the integer literal `v` (through its aliases) is, or null for
/// any other definition.
pub fn intConst(self: *const Analysis, v: Mir.Value) ?i64 {
    return switch (self.mir.valueDef(self.rv(v))) {
        .int_const => |x| x,
        .undef, .float_const, .str_const, .param_ref, .block_param, .inst_result => null,
    };
}

fn intArg(self: *const Analysis, args: []const Mir.Value, i: usize) ?i64 {
    return if (i < args.len) self.intConst(args[i]) else null;
}

/// The bits of `.wide` value `v`. Requires `build`.
fn wideWidth(self: *const Analysis, v: Mir.Value) u32 {
    return self.wide_w[@backingInt(v)];
}

/// Fill `arr_of`. An `anew` names its array and a `store` inherits its
/// operand's; a phi takes any operand's (lowering joins only versions of one
/// place, so they agree). A fixpoint because a loop phi reads a store defined
/// after it; marking only ever adds, so it converges.
fn buildArrOf(self: *Analysis) Error!void {
    self.arr_of = try self.arena.alloc(u32, self.nv);
    @memset(self.arr_of, none_u32);
    if (self.lowered.mem_arrays.items.len == 0) return;
    // Each sweep that grows marks at least one more of the `nv` values.
    var sweeps: u32 = 0;
    var grew = true;
    while (grew) : (sweeps += 1) {
        std.debug.assert(sweeps <= self.nv);
        grew = false;
        for (Mir.Value.first_dynamic..self.nv) |i| {
            if (self.arr_of[i] != none_u32) continue;
            const def = self.mir.valueDef(@fromBackingInt(@intCast(i)));
            if (def != .inst_result) continue;
            const inst = def.inst_result;
            const id: u32 = switch (self.mir.instData(inst)) {
                .anew => |d| d.array,
                .store => |d| self.arr_of[@backingInt(self.rv(d.arr))],
                .phi => |d| blk: {
                    var k: u32 = 0;
                    while (k < d.count) : (k += 1) {
                        const a = self.arr_of[@backingInt(self.rv(self.mir.phiPair(inst, k).value))];
                        if (a != none_u32) break :blk a;
                    }
                    break :blk none_u32;
                },
                .unary, .binary, .ternary, .branch, .jump, .call, .load => none_u32,
            };
            if (id == none_u32) continue;
            self.arr_of[i] = id;
            grew = true;
        }
    }
}

/// §3.2.2 the array a Value is a version of, or null for a scalar.
/// Requires `build`, not `buildStructure`; asserts that it ran.
pub fn arrOf(self: *const Analysis, v: Mir.Value) ?u32 {
    std.debug.assert(self.arr_of.len == self.nv);
    const a = self.arr_of[@backingInt(self.rv(v))];
    return if (a == none_u32) null else a;
}

test "a chain of joins built outer-first types every phi from the integer at its root" {
    // Three nested `if`s, each join's first operand the join inside it,
    // created outer-first as SSA construction does: two sweeps are not enough.
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    var b: [4]Mir.Block = undefined;
    for (&b) |*x| x.* = try mir.addBlock(a);
    for (0..3) |i| _ = try mir.emitJump(a, b[i], b[i + 1]);
    const p3 = try mir.emitPhi(a, b[3], &.{});
    const p2 = try mir.emitPhi(a, b[2], &.{});
    const p1 = try mir.emitPhi(a, b[1], &.{.{ .block = b[0], .value = .one }});
    try mir.setPhiPairs(a, mir.valueDef(p2).inst_result, &.{.{ .block = b[1], .value = p1 }});
    try mir.setPhiPairs(a, mir.valueDef(p3).inst_result, &.{.{ .block = b[2], .value = p2 }});

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    for ([_]Mir.Value{ p1, p2, p3 }) |p| try std.testing.expectEqual(VTy.int, an.tyOf(p));
}

test "ipdom: a loop with no exit flows to the virtual exit" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    const entry = try mir.addBlock(a);
    const l = try mir.addBlock(a);
    _ = try mir.emitJump(a, entry, l);
    _ = try mir.emitJump(a, l, l);

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    // No block returns, so both are given an edge to the exit (2).
    try std.testing.expectEqualSlices(u32, &.{ 2, 2, 2 }, an.ipdom);
}

test "a dstop clears the derivative bits and keeps the value varying" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    _ = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    const vb = try mir.addBlockParam(a, 1);
    const stopped = try mir.emit(a, .entry, .dstop, &.{va});
    const prod = try mir.emit(a, .entry, .fmul, &.{ stopped, vb });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    try std.testing.expect(an.dFree(stopped) and an.xDep(stopped));
    // The product keeps its other operand's lane, and varies through both.
    try std.testing.expectEqualSlices(u64, &.{0b10}, an.unknownDeps(prod));
    try std.testing.expectEqual(@as(u64, 0b11), an.xdeps[@backingInt(prod)]);
}

test "a ?: steered by a probe varies with no derivative lane; one on a constant does not vary" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    _ = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    const two = try mir.addFloatConst(a, 2.0);
    const three = try mir.addFloatConst(a, 3.0);
    // `V * (V > 0.4 ? 2.0 : 3.0)`: ∂/∂V is 2 or 3, picked by x.
    const c = try mir.emit(a, .entry, .fgt, &.{ va, try mir.addFloatConst(a, 0.4) });
    const sel = try mir.emit(a, .entry, .select, &.{ c, two, three });
    const g = try mir.emit(a, .entry, .fmul, &.{ va, sel });
    const fixed = try mir.emit(a, .entry, .select, &.{ .one, two, three });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    // The taken arm's derivative is a constant's: no lane. Its value is 2 or
    // 3 as x moves: it varies.
    try std.testing.expectEqualSlices(u64, &.{0}, an.unknownDeps(sel));
    try std.testing.expect(an.xDep(sel) and an.pointDep(sel));
    try std.testing.expectEqualSlices(u64, &.{0b1}, an.unknownDeps(g));
    try std.testing.expect(an.dFree(fixed) and !an.xDep(fixed));
}

test "a join steered by a probe varies with no derivative lane; one steered by a constant does not vary" {
    // b0: br (V > 0) b1 b2; b1, b2: jump b3; b3: p1 = phi(2, 3); br 1 b4 b5;
    // b4, b5: jump b6; b6: p2 = phi(2, 3).
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    var b: [7]Mir.Block = undefined;
    for (&b) |*x| x.* = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    const two = try mir.addFloatConst(a, 2.0);
    const three = try mir.addFloatConst(a, 3.0);
    const c = try mir.emit(a, b[0], .fgt, &.{ va, .f_zero });
    _ = try mir.emitBranch(a, b[0], c, b[1], b[2]);
    _ = try mir.emitJump(a, b[1], b[3]);
    _ = try mir.emitJump(a, b[2], b[3]);
    const p1 = try mir.emitPhi(a, b[3], &.{ .{ .block = b[1], .value = two }, .{ .block = b[2], .value = three } });
    _ = try mir.emitBranch(a, b[3], .one, b[4], b[5]);
    _ = try mir.emitJump(a, b[4], b[6]);
    _ = try mir.emitJump(a, b[5], b[6]);
    const p2 = try mir.emitPhi(a, b[6], &.{ .{ .block = b[4], .value = two }, .{ .block = b[5], .value = three } });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    try std.testing.expect(an.dFree(p1) and an.xDep(p1));
    try std.testing.expect(an.dFree(p2) and !an.xDep(p2));
}

test "a loop counter whose exit test reads a probe varies with no derivative lane" {
    // b0: jump b1; b1: i = phi(0, i + 1); br (V > i) b2 b3; b2: jump b1.
    // How many times round, so the `i` that leaves, moves with x.
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    var b: [4]Mir.Block = undefined;
    for (&b) |*x| x.* = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    _ = try mir.emitJump(a, b[0], b[1]);
    const i = try mir.emitPhi(a, b[1], &.{});
    const c = try mir.emit(a, b[1], .fgt, &.{ va, i });
    _ = try mir.emitBranch(a, b[1], c, b[2], b[3]);
    const next = try mir.emit(a, b[2], .iadd, &.{ i, .one });
    _ = try mir.emitJump(a, b[2], b[1]);
    try mir.setPhiPairs(a, mir.valueDef(i).inst_result, &.{ .{ .block = b[0], .value = .zero }, .{ .block = b[2], .value = next } });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    try std.testing.expect(an.dFree(i) and an.xDep(i));
}

test "acdyn: an absdelay's input deps reach the value, a direct path does not" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    _ = try mir.addBlock(a);
    const va = try mir.addBlockParam(a, 0);
    const vb = try mir.addBlockParam(a, 1);
    const td = try mir.addFloatConst(a, 1e-9);
    const dly = try mir.emitCall(a, .entry, try mir.internString(a, "absdelay"), &.{ va, td });
    const sum = try mir.emit(a, .entry, .fadd, &.{ dly, vb });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    // x[0] reaches `sum` only through the delay, x[1] only directly.
    try std.testing.expectEqualSlices(u64, &.{0b11}, an.unknownDeps(sum));
    try std.testing.expectEqualSlices(u64, &.{0b01}, an.acDynDeps(sum));
    try std.testing.expectEqualSlices(u64, &.{0}, an.acDynDeps(va));
}

/// Returns the emitted type of `v`. Requires `build`, not `buildStructure`.
pub fn tyOf(self: *const Analysis, v: Mir.Value) VTy {
    return self.vty[@backingInt(v)];
}

// -------------------------------------------------- the derivative lattice --

/// Fill `deps`: which unknowns, and so also whether any (`dFree`). See `deps`.
///
/// Everything starts at no bits and a bit spreads from the probes outwards,
/// so the fixpoint is monotone and cannot oscillate: the lattice only ever
/// gains bits, and it terminates in at most (longest chain) sweeps. Value
/// order is definition order except across a back edge, which is why this
/// iterates rather than sweeping once: a loop-carried phi needs the round
/// after its body.
fn buildDeps(self: *Analysis) Error!void {
    // One bit per unknown; a probe past `Lowered.nodes` (a hand-built test
    // MIR) still gets its own bit.
    var n_u: usize = self.lowered.nodes.len;
    for (0..self.nv) |v| {
        const d = self.mir.valueDef(@fromBackingInt(@intCast(v)));
        if (d == .block_param) n_u = @max(n_u, @as(usize, d.block_param) + 1);
    }
    self.dep_words = @intCast(@max(1, std.math.divCeil(usize, n_u, 64) catch unreachable));
    const zero = try self.arena.alloc(u64, self.dep_words);
    @memset(zero, 0);
    self.dep_zero = zero;
    // Its own column always: a `?:`, an array index or a branch can steer a
    // value without entering its derivative, and nearly every module has one.
    try self.buildSteer();
    const g = try self.buildDepGraph();
    self.deps = try self.fixDeps(g, .deriv);
    self.xdeps = try self.fixDeps(g, .value);
    self.pdeps = self.xdeps;
    for (0..self.mir.insts.len) |i| {
        if (!readsInstance(self, @fromBackingInt(@intCast(i)))) continue;
        self.pdeps = try self.fixDeps(g, .point);
        break;
    }
    // After `deps`, which an operator's `acdyn` reads.
    for (0..self.mir.insts.len) |i| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(i));
        if (self.mir.instOp(inst) != .call or !op_kind.acDynamic(Mir.callee.opKind(self.mir.instData(inst).call.callee))) continue;
        self.acdyn = try self.fixDeps(g, .ac_dyn);
        break;
    }
}

/// `fixDeps`' input, decoded from the MIR once so a sweep reads flat rows
/// instead of re-decoding every instruction (decoding per Value per sweep
/// measured 9.4 ms of `build`'s 11.4 on psp103). Per Value:
/// its rule (`kind`) and its operands, alias-resolved, in
/// `ops[off[v]..off[v + 1]]`; the first `n_d[v]` enter the derivative, the
/// rest only steer the value. An alias reads its target as one derivative
/// operand, so it settles to the target's bits in every column.
const DepGraph = struct {
    kind: []Kind,
    n_d: []u32,
    off: []u32,
    ops: []u32,

    /// How a Value combines its operands' bits (see `fixDeps`).
    const Kind = enum(u8) {
        /// The union of its operands: every value but the four below.
        plain,
        /// §4.4 a probe: its unknown's bit, none in `acdyn`.
        probe,
        /// A call that reads per-instance state (`readsInstance`): `pdeps`
        /// sets its bit 0 and ignores the arguments.
        instance_call,
        /// A `$prev`/charge path latch: `pdeps` sets bit 0 as well.
        latch,
        /// A frequency-dependent operator (`op.acDynamic`): `acdyn` takes its
        /// first argument's whole `deps`.
        ac_dynamic,
    };
};

/// Builds the `DepGraph` the four columns share: counted, then filled.
fn buildDepGraph(self: *const Analysis) Error!DepGraph {
    const a = self.arena;
    const nv = self.nv;
    var g: DepGraph = .{
        .kind = try a.alloc(DepGraph.Kind, nv),
        .n_d = try a.alloc(u32, nv),
        .off = try a.alloc(u32, nv + 1),
        .ops = &.{},
    };
    var n: u32 = 0;
    for (0..nv) |v| {
        g.off[v] = n;
        n += self.depRow(@intCast(v), &g, &.{});
    }
    g.off[nv] = n;
    g.ops = try a.alloc(u32, n);
    for (0..nv) |v| _ = self.depRow(@intCast(v), &g, g.ops[g.off[v]..g.off[v + 1]]);
    return g;
}

/// Value `v`'s row of `g`: sets `kind[v]` and `n_d[v]`, writes its operands
/// to `out` (empty: count only) and returns how many it wrote or counted.
fn depRow(self: *const Analysis, v: u32, g: *DepGraph, out: []u32) u32 {
    const Row = struct {
        out: []u32,
        alias: []const Mir.Value,
        n: u32 = 0,
        fn put(r: *@This(), x: Mir.Value) void {
            if (r.out.len != 0) r.out[r.n] = @backingInt(r.alias[@backingInt(x)]);
            r.n += 1;
        }
    };
    var r: Row = .{ .out = out, .alias = self.alias };
    g.kind[v] = .plain;
    const val: Mir.Value = @fromBackingInt(v);
    if (self.rv(val) != val) {
        r.put(val);
    } else switch (self.mir.valueDef(val)) {
        .block_param => g.kind[v] = .probe,
        .undef, .float_const, .int_const, .str_const, .param_ref => {},
        .inst_result => |inst| {
            // A `dstop` operand steers its value but enters no derivative.
            var steer_first: ?Mir.Value = null;
            switch (self.mir.instData(inst)) {
                .branch, .jump, .anew => {},
                // A call inherits from its arguments and nothing else. That
                // holds for all of §4.5 (each operator propagates the
                // derivative of its argument) and for ch9, where a systf's
                // partials arrive through `SystfHost.call`. A call cannot read
                // a probe its arguments do not name: codegen spells a probe in
                // one place only (`renderValueRef`'s `block_param` arm).
                // Without this rule every `$temperature`-dependent parameter
                // would carry a derivative.
                .call => |c| {
                    if (self.readsInstance(inst)) {
                        g.kind[v] = .instance_call;
                    } else if (op_kind.acDynamic(Mir.callee.opKind(c.callee))) g.kind[v] = .ac_dynamic;
                    for (c.args) |x| r.put(x);
                },
                .unary => |u| {
                    if (u.op == .path_prev or u.op == .path_acc) g.kind[v] = .latch;
                    if (u.op == .dstop) steer_first = u.operand else r.put(u.operand);
                },
                .binary => |b| {
                    r.put(b.lhs);
                    r.put(b.rhs);
                },
                // §4.2.12: the condition selects between arms rather than
                // entering the derivative, so `S.sel` lets the taken arm's
                // derivative ride through. Which arm is taken still moves
                // with the condition: it steers.
                .ternary => |t| {
                    r.put(t.then_val);
                    r.put(t.else_val);
                    steer_first = t.cond;
                },
                // §3.2.2 an array version carries the union of what was
                // stored into it; a fresh one (zero, or the held `Instance`
                // copy) is constant. The index steers, for `select`'s reason:
                // it picks an element, and the picked element's derivative is
                // what rides through.
                .load => |l| {
                    r.put(l.arr);
                    steer_first = l.index;
                },
                .store => |st| {
                    r.put(st.arr);
                    r.put(st.value);
                    steer_first = st.index;
                },
                .phi => |d| for (0..d.count) |k| r.put(self.mir.phiPair(inst, @intCast(k)).value),
            }
            g.n_d[v] = r.n;
            if (steer_first) |x| r.put(x);
            // A join is a select on the edge that reached it: the edge's
            // branches (`steer_pool`) steer it as a condition does.
            if (self.mir.instOp(inst) == .phi) {
                const b = self.def_block[v];
                if (b != none_u32) for (self.steer_pool[self.steer_off[b]..self.steer_off[b + 1]]) |c| r.put(c);
            }
            // A guarded row (`Mir.guard_of`) is steered by its guard's
            // conditions as a select is by its own.
            var it = self.mir.guardConds(inst);
            while (it.next()) |c| r.put(c);
            return r.n;
        },
    }
    g.n_d[v] = r.n;
    return r.n;
}

/// Which column `fixDeps` fills: `deps`, `xdeps`, `acdyn` or `pdeps`.
const DepCol = enum {
    deriv,
    value,
    ac_dyn,
    point,

    /// The columns that ask whether the value varies, so take what steers it
    /// (`steer_pool`, a select's condition, an index) and not only what
    /// enters its derivative.
    fn steered(c: DepCol) bool {
        return c == .value or c == .point;
    }
};

/// Fill `steer_pool` (see there), counted then filled. Requires `ipdom` and
/// the natural loops.
fn buildSteer(self: *Analysis) Error!void {
    const a = self.arena;
    const nb = self.nb;
    std.debug.assert(self.ipdom.len == nb + 1);
    var n_heads: u32 = 0;
    for (self.rpo) |h| n_heads += @intFromBool(self.is_loop[h]);
    const heads = try a.alloc(u32, n_heads);
    n_heads = 0;
    for (self.rpo) |h| if (self.is_loop[h]) {
        heads[n_heads] = h;
        n_heads += 1;
    };
    self.steer_off = try a.alloc(u32, nb + 1);
    @memset(self.steer_off, 0);
    var at: []u32 = &.{};
    for ([_]bool{ false, true }) |fill| {
        if (fill) {
            for (1..nb + 1) |b| self.steer_off[b] += self.steer_off[b - 1];
            self.steer_pool = try a.alloc(Mir.Value, self.steer_off[nb]);
            at = try a.dupe(u32, self.steer_off[0..nb]);
        }
        for (self.rpo) |bi| {
            const t = self.term[bi];
            if (t == .none or self.i_op[@backingInt(t)] != .branch) continue;
            const cond = self.mir.instData(t).branch.cond;
            const join = self.ipdom[bi];
            // The virtual exit has no phis.
            if (join < nb) {
                if (fill) {
                    self.steer_pool[at[join]] = cond;
                    at[join] += 1;
                } else self.steer_off[join + 1] += 1;
            }
            const nest = self.loop_of[bi];
            if (nest == none_u32) continue;
            for (heads) |h| {
                if (self.loop_of[h] != nest) continue;
                if (fill) {
                    self.steer_pool[at[h]] = cond;
                    at[h] += 1;
                } else self.steer_off[h + 1] += 1;
            }
        }
    }
    for (0..nb) |b| std.debug.assert(at[b] == self.steer_off[b + 1]);
}

/// Whether `inst` reads a per-instance value (`pdeps`' seeds).
fn readsInstance(self: *const Analysis, inst: Mir.Inst) bool {
    return switch (self.mir.instData(inst)) {
        .call => |c| c.callee == .@"$held_real" or c.callee == .@"$held_int" or c.callee == .@"$held_str" or c.callee == .@"$held_wide" or c.callee == .@"$mfactor",
        .unary => |u| u.op == .path_prev or u.op == .path_acc,
        else => false, // else: only a call or a latch reads the instance as a value
    };
}

/// The lattice's fixpoint for column `which` over `g`, swept in value order
/// until nothing changes. Per column, a Value's bits are:
///   deriv  `probe`: its unknown's bit; else its derivative operands'.
///   value  `probe`: its bit; else every operand's.
///   point  as `value`, plus bit 0 for an `instance_call` (over its steering
///          operands only) and a `latch`.
///   ac_dyn `probe`: none; `ac_dynamic`: its first argument's `deps`; else
///          its derivative operands'.
fn fixDeps(self: *const Analysis, g: DepGraph, which: DepCol) Error![]u64 {
    // One word, the common case, gets a body with the width known: the
    // generic one costs 1.8x there (psp103 `build`: 9.4 ms against 5.3).
    return if (self.dep_words == 1) self.fixDepsWide(g, which, 1) else self.fixDepsWide(g, which, 0);
}

/// `fixDeps` at `words_ct` words a value, or `dep_words` when it is 0.
fn fixDepsWide(self: *const Analysis, g: DepGraph, which: DepCol, comptime words_ct: u32) Error![]u64 {
    const w: usize = if (words_ct != 0) words_ct else self.dep_words;
    std.debug.assert(w == self.dep_words);
    const col = try self.arena.alloc(u64, @as(usize, self.nv) * w);
    @memset(col, 0);
    // The row being built: derivative operands' union, then steering ones'.
    const d = (try self.arena.alloc(u64, w))[0..w];
    const s = (try self.arena.alloc(u64, w))[0..w];
    var changed = true;
    while (changed) {
        changed = false;
        for (0..self.nv) |v| {
            const row = g.ops[g.off[v]..g.off[v + 1]];
            @memset(d, 0);
            @memset(s, 0);
            for (row[0..g.n_d[v]]) |o| orInto(d, col[@as(usize, o) * w ..][0..w]);
            if (which.steered()) for (row[g.n_d[v]..]) |o| orInto(s, col[@as(usize, o) * w ..][0..w]);
            switch (g.kind[v]) {
                .probe => {
                    @memset(d, 0);
                    if (which != .ac_dyn) {
                        const u = self.mir.valueDef(@fromBackingInt(@intCast(v))).block_param;
                        d[u / 64] = @as(u64, 1) << @intCast(u % 64);
                    }
                },
                // Bit 0 marks "reads the instance": `pointDep` asks only
                // whether any bit is set.
                .instance_call => if (which == .point) {
                    @memset(d, 0);
                    d[0] = 1;
                },
                .latch => if (which == .point) {
                    d[0] |= 1;
                },
                .ac_dynamic => if (which == .ac_dyn) {
                    if (g.n_d[v] == 0) @memset(d, 0) else @memcpy(d, self.deps[@as(usize, row[0]) * w ..][0..w]);
                },
                .plain => {},
            }
            orInto(d, s);
            const at = col[v * w ..][0..w];
            if (std.mem.eql(u64, at, d)) continue;
            @memcpy(at, d);
            changed = true;
        }
    }
    return col;
}

fn orInto(acc: []u64, x: []const u64) void {
    for (acc, x) |*a, b| a.* |= b;
}

/// Returns whether `v` is independent of every §4.4 probe, so its derivative
/// vanishes structurally (no bit of its `deps` row). Resolves the alias first.
/// Conservative: `false` is always sound. Worth knowing because
/// `@setFloatMode(.strict)` forbids folding a multiply by a literal zero, so a
/// dual holding `splat(0)` would pay full-width arithmetic at every use.
/// Requires `build`; so do `xDep`, `pointDep`, `unknownDeps` and `acDynDeps`.
pub fn dFree(self: *const Analysis, v: Mir.Value) bool {
    return std.mem.allEqual(u64, self.depsIn(self.deps, v), 0);
}

/// Returns whether `v`'s value varies with some §4.4 probe. `!dFree` implies
/// it; it also holds past a `dstop`, whose value varies while its derivative
/// is zero, and for a select, join or array read steered by a varying
/// condition or index over arms that do not vary (`xdeps`).
pub fn xDep(self: *const Analysis, v: Mir.Value) bool {
    return !std.mem.allEqual(u64, self.depsIn(self.xdeps, v), 0);
}

/// Returns whether `v` can differ between two points of a batch that share
/// the `Model` row and the `SimState`: `xDep`, or it reads per-instance
/// state (a held variable, `$mfactor`, a path latch; contract.zig
/// `batch_inst`).
pub fn pointDep(self: *const Analysis, v: Mir.Value) bool {
    return !std.mem.allEqual(u64, self.depsIn(self.pdeps, v), 0);
}

fn depsIn(self: *const Analysis, col: []const u64, v: Mir.Value) []const u64 {
    const w = self.dep_words;
    return col[@as(usize, @backingInt(self.rv(v))) * w ..][0..w];
}

/// Returns which unknowns `v`'s derivative can be nonzero in: `dep_words`
/// words, borrowed from `deps` (see there for the bit layout).
fn unknownDeps(self: *const Analysis, v: Mir.Value) []const u64 {
    return self.depsIn(self.deps, v);
}

/// Returns the unknowns whose derivative reaches `v` through a
/// frequency-dependent operator (`acdyn`), shaped as `unknownDeps`; all
/// zero when the module calls no such operator.
fn acDynDeps(self: *const Analysis, v: Mir.Value) []const u64 {
    if (self.acdyn.len == 0) return self.dep_zero;
    return self.depsIn(self.acdyn, v);
}

/// Returns whether `block` is inside some loop's natural body.
pub fn inLoop(self: *const Analysis, block: u32) bool {
    return self.loop_of[block] != none_u32;
}

/// A phi whose result survives aliasing: the `phi_pool` filter, CFG-wide.
fn livePhi(self: *const Analysis, inst: Mir.Inst) bool {
    if (self.i_op[@backingInt(inst)] != .phi) return false;
    const r = self.i_res[@backingInt(inst)];
    return self.rv(r) == r;
}

/// The `stmt_pool` filter: everything a unit body may emit as a statement.
/// Phis are block headers, terminators are `emitTerm`'s, and an aliased
/// result was rewritten away by ssa.zig.
fn liveStmt(self: *const Analysis, inst: Mir.Inst) bool {
    switch (Mir.opClass(self.i_op[@backingInt(inst)])) {
        .phi, .branch, .jump => return false,
        .unary, .binary, .ternary, .call, .anew, .load, .store => {},
    }
    const r = self.i_res[@backingInt(inst)];
    return r != .undef and self.rv(r) == r;
}

// ---------------------------------------------------------------------------
// The VTy lattice: a Value's type is a property of the MIR, so both the
// analysis that fills `vty` and the emitter that reads it use these.
// ---------------------------------------------------------------------------

/// Returns the emitted type of a §3.4 parameter declared with type `t`.
pub fn tyOfParam(t: Lower.Type) VTy {
    return switch (t) {
        .real, .unspecified => .real,
        .integer => .int,
        .string => .str,
    };
}

// ---------------------------------------------------------------------------
// Constant folding: a property of the MIR, so it lives with the facts. Both
// the emitter (parameter defaults, §4.5 operator control arguments) and the
// per-unit planner fold through this.
// ---------------------------------------------------------------------------

/// A folded constant, as a real.
pub const Folded = struct { f: f64 };

/// Returns `v` as a §4.2 constant expression, or null. Used for parameter
/// defaults (`parameter real b = a*2;`, §6.3.4) and §4.5 operator control
/// arguments; anything touching an unknown or a call is not constant.
/// `resolve_params` looks through a parameter to its declared default, which
/// only a Model default may do. O(1): a load from `folds`. Requires `build`
/// (`buildLiteralFolds` for `resolve_params = false`); asserts that the
/// column it reads was built.
pub fn foldConst(self: *const Analysis, v: Mir.Value, resolve_params: bool) ?Folded {
    std.debug.assert(self.folds[@intFromBool(resolve_params)].kind.len == self.nv);
    const c = self.folds[@intFromBool(resolve_params)].get(v) orelse return null;
    return .{ .f = c.asReal() };
}

fn buildFolds(self: *Analysis) Error!void {
    for (&self.folds, [_]bool{ false, true }) |*col, resolve_params| {
        col.* = try self.buildFoldColumn(resolve_params);
    }
}

/// Literal-only folds after `buildStructure`: runtime branch truth may not
/// inspect a parameter's overridable default (§4.2.3/§6.3.4). The prover
/// needs this column but none of the derivative/type tables in `build`.
pub fn buildLiteralFolds(self: *Analysis) Error!void {
    self.folds[0] = try self.buildFoldColumn(false);
}

fn buildFoldColumn(self: *Analysis, resolve_params: bool) Error!FoldColumn {
    var col: FoldColumn = .{
        .kind = try self.arena.alloc(FoldColumn.Kind, self.nv),
        .bits = try self.arena.alloc(u64, self.nv),
    };
    @memset(col.kind, .none);
    @memset(col.bits, 0);
    // An answer only ever goes from null to a constant, so this terminates;
    // operands precede users except through aliases or forward defaults.
    // Each sweep that changes something folds at least one more value.
    var sweeps: u32 = 0;
    var changed = true;
    while (changed) : (sweeps += 1) {
        std.debug.assert(sweeps <= self.nv);
        changed = false;
        for (0..self.nv) |v| {
            if (col.kind[v] != .none) continue;
            const c = self.foldStep(@fromBackingInt(@intCast(v)), &col, resolve_params) orelse continue;
            try col.set(self.arena, v, c);
            changed = true;
        }
    }
    return col;
}

/// `v`'s fold given the current answers for its operands. The operators are
/// the one constant kernel's (`opcode.fold`); this only decides which values
/// are leaves.
fn foldStep(self: *const Analysis, v: Mir.Value, col: *const FoldColumn, resolve_params: bool) ?Const {
    switch (self.mir.valueDef(self.rv(v))) {
        .float_const => |x| return .{ .real = x },
        .int_const => |x| return .{ .int = x },
        // Only a Model default may look through a parameter: everywhere
        // else the value is whatever the host overrode it with.
        .param_ref => |p| return if (resolve_params) col.get(self.lowered.params.items[p].default) else null,
        .inst_result => |inst| switch (self.mir.instData(inst)) {
            .unary => |u| return Mir.opcode.fold(u.op, &.{col.get(u.operand) orelse return null}),
            .binary => |bn| return Mir.opcode.fold(bn.op, &.{
                col.get(bn.lhs) orelse return null,
                col.get(bn.rhs) orelse return null,
            }),
            // §4.2.12 `?:`. Lazy, as the kernel's `fold` is: only the taken
            // arm has to be foldable, so `w > 0 ? 1/w : 0` folds for w = 0
            // instead of declining on a division it never performs.
            .ternary => |d| {
                const c = col.get(d.cond) orelse return null;
                return col.get(if (c.isTrue()) d.then_val else d.else_val);
            },
            // §9.15 `$simparam` in `Lowered.simparamAnswer`'s order. A host
            // field follows `.param_ref`'s rule: only a Model default may
            // look through it, and sees Table 9-27's declared value (what
            // `Model{}` means to a host that writes nothing); every other
            // reader gets `model.<field>` (codegen's `f64Const`), so the §3.4
            // field initializer and the §6.3.4 `derive()` assignment split on
            // `resolve_params`. VerA's own answer is a constant everywhere,
            // and an unknown name is its fallback's fold. A run-time name
            // has no card-time value.
            .call => |d| {
                if (d.callee != .@"$simparam" or d.args.len == 0) return null;
                const arg = self.mir.valueDef(self.rv(d.args[0]));
                if (arg != .str_const) return null;
                switch (self.lowered.simparamAnswer(arg.str_const, d.args.len > 1)) {
                    .host => |h| return if (resolve_params) .{ .real = h.default } else null,
                    .value => |x| return .{ .real = x },
                    .fallback => return col.get(d.args[1]),
                    .runtime, .unknown => return null,
                }
            },
            // §3.2.2 an array element is not a constant expression.
            .phi, .branch, .jump, .anew, .load, .store => return null,
        },
        .undef, .str_const, .block_param => return null,
    }
}

test "analysis: CFG facts agree with their naive definitions on random structured CFGs" {
    // Oracles, each computed from the terminators alone:
    //   dominance   `a` dominates reachable `x` iff `x` is unreachable once
    //               `a` is removed (unreachable blocks dominate only themselves);
    //   RPO         every edge that is not a back edge goes forward;
    //   loops       a header dominates a predecessor, and its natural loop is
    //               every reachable block that reaches a back-edge source
    //               without passing the header; `loop_of` names the
    //               outermost (lowest-RPO) header whose loop holds the block.
    // The CFGs are lowering's shapes (if/else, one-armed if, loops, straight
    // jumps), so reducible, plus unreachable blocks jumping into them.
    const gpa = std.testing.allocator;
    const lowered: Lowered = .{};
    var prng = std.Random.DefaultPrng.init(0xd0_d0);
    const r = prng.random();

    const Gen = struct {
        mir: *Mir,
        r: std.Random,
        cur: Mir.Block = .entry,

        fn seq(g: *@This(), depth: u32) anyerror!void {
            const al = std.testing.allocator;
            for (0..g.r.uintLessThan(u32, 3)) |_| {
                const kind = if (depth >= 2) 3 else g.r.uintLessThan(u32, 4);
                switch (kind) {
                    0 => {
                        const t = try g.mir.addBlock(al);
                        const e = try g.mir.addBlock(al);
                        const j = try g.mir.addBlock(al);
                        _ = try g.mir.emitBranch(al, g.cur, .one, t, e);
                        g.cur = t;
                        try g.seq(depth + 1);
                        _ = try g.mir.emitJump(al, g.cur, j);
                        g.cur = e;
                        try g.seq(depth + 1);
                        _ = try g.mir.emitJump(al, g.cur, j);
                        g.cur = j;
                    },
                    1 => {
                        const t = try g.mir.addBlock(al);
                        const j = try g.mir.addBlock(al);
                        _ = try g.mir.emitBranch(al, g.cur, .one, t, j);
                        g.cur = t;
                        try g.seq(depth + 1);
                        _ = try g.mir.emitJump(al, g.cur, j);
                        g.cur = j;
                    },
                    2 => {
                        const h = try g.mir.addBlock(al);
                        const body = try g.mir.addBlock(al);
                        const exit = try g.mir.addBlock(al);
                        _ = try g.mir.emitJump(al, g.cur, h);
                        _ = try g.mir.emitBranch(al, h, .one, body, exit);
                        g.cur = body;
                        try g.seq(depth + 1);
                        _ = try g.mir.emitJump(al, g.cur, h);
                        g.cur = exit;
                    },
                    else => {
                        const n = try g.mir.addBlock(al);
                        _ = try g.mir.emitJump(al, g.cur, n);
                        g.cur = n;
                    },
                }
            }
        }
    };
    const Naive = struct {
        fn succs(m: *const Mir, b: u32, buf: *[2]u32) []const u32 {
            var it = m.blockInsts(@fromBackingInt(b));
            while (it.next()) |inst| switch (m.instData(inst)) {
                .branch => |d| {
                    buf.* = .{ @backingInt(d.then_block), @backingInt(d.else_block) };
                    return buf[0..2];
                },
                .jump => |d| {
                    buf[0] = @backingInt(d.target);
                    return buf[0..1];
                },
                .unary, .binary, .ternary, .phi, .call, .anew, .load, .store => {},
            };
            return buf[0..0];
        }

        /// Whether `b` reaches a block with no successor (the exit) without
        /// passing through `avoid`: false makes `avoid` post-dominate `b`.
        fn reachesExit(m: *const Mir, seen: []bool, stack: []u32, b: u32, avoid: u32) bool {
            if (b == avoid) return false;
            @memset(seen, false);
            seen[b] = true;
            stack[0] = b;
            var sp: usize = 1;
            while (sp > 0) {
                sp -= 1;
                var buf: [2]u32 = undefined;
                const ss = succs(m, stack[sp], &buf);
                if (ss.len == 0) return true;
                for (ss) |s| {
                    if (s == avoid or seen[s]) continue;
                    seen[s] = true;
                    stack[sp] = s;
                    sp += 1;
                }
            }
            return false;
        }

        /// Blocks reachable from the entry without passing through `skip`
        /// (`skip` past the last block skips nothing).
        fn reach(m: *const Mir, out: []bool, stack: []u32, skip: u32) void {
            @memset(out, false);
            if (skip == 0) return;
            out[0] = true;
            stack[0] = 0;
            var sp: usize = 1;
            while (sp > 0) {
                sp -= 1;
                const b = stack[sp];
                var buf: [2]u32 = undefined;
                for (succs(m, b, &buf)) |s| {
                    if (s == skip or out[s]) continue;
                    out[s] = true;
                    stack[sp] = s;
                    sp += 1;
                }
            }
        }
    };

    for (0..200) |round| {
        errdefer std.debug.print("analysis model: round {d}\n", .{round});
        var mir: Mir = .{};
        defer mir.deinit(gpa);
        _ = try mir.addBlock(gpa);
        var g: Gen = .{ .mir = &mir, .r = r };
        try g.seq(0);
        for (0..r.uintLessThan(u32, 3)) |_| {
            const dead = try mir.addBlock(gpa);
            const into: Mir.Block = @fromBackingInt(1 + r.uintLessThan(u32, mir.blockCount() - 1));
            _ = try mir.emitJump(gpa, dead, into);
        }

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const aa = arena.allocator();
        const an = try build(aa, &mir, &lowered);
        const nb = mir.blockCount();
        try std.testing.expectEqual(nb, an.nb);

        const stack = try aa.alloc(u32, nb);
        const live = try aa.alloc(bool, nb);
        Naive.reach(&mir, live, stack, nb);
        // dom[a * nb + x]
        const dom = try aa.alloc(bool, @as(usize, nb) * nb);
        const tmp = try aa.alloc(bool, nb);
        for (0..nb) |ai| {
            Naive.reach(&mir, tmp, stack, @intCast(ai));
            for (0..nb) |xi| dom[ai * nb + xi] = if (!live[ai] or !live[xi]) ai == xi else (ai == xi or !tmp[xi]);
        }
        for (0..nb) |ai| for (0..nb) |xi| {
            try std.testing.expectEqual(dom[ai * nb + xi], an.dominates(@intCast(ai), @intCast(xi)));
        };

        // Reachability, successors, predecessors, RPO direction, merges.
        const pred_n = try aa.alloc(u32, nb);
        @memset(pred_n, 0);
        for (0..nb) |ui| {
            try std.testing.expectEqual(live[ui], an.rpo_num[ui] != none_u32);
            var buf: [2]u32 = undefined;
            const ss = Naive.succs(&mir, @intCast(ui), &buf);
            try std.testing.expectEqualSlices(u32, ss, an.succs[ui]);
            if (!live[ui]) continue;
            for (ss) |v| {
                pred_n[v] += 1;
                try std.testing.expect(std.mem.findScalar(u32, an.preds[v], @intCast(ui)) != null);
                if (!dom[v * nb + ui]) try std.testing.expect(an.rpo_num[ui] < an.rpo_num[v]);
            }
        }
        for (0..nb) |v| {
            try std.testing.expectEqual(@as(usize, pred_n[v]), an.preds[v].len);
            try std.testing.expectEqual(v != 0 and pred_n[v] >= 2, an.is_merge[v]);
        }

        // Immediate dominators, and the dominator tree's child lists.
        var kids: usize = 0;
        for (0..nb) |x| {
            kids += an.domKids(@intCast(x)).len;
            for (an.domKids(@intCast(x))) |k| try std.testing.expectEqual(@as(u32, @intCast(x)), an.idom[k]);
            if (!live[x]) {
                try std.testing.expectEqual(none_u32, an.idom[x]);
                continue;
            }
            if (x == 0) continue;
            const id = an.idom[x];
            try std.testing.expect(id != x and dom[id * nb + x]);
            for (0..nb) |d| if (d != x and dom[d * nb + x]) try std.testing.expect(dom[d * nb + id]);
        }
        var n_live: usize = 0;
        for (live) |l| n_live += @intFromBool(l);
        try std.testing.expectEqual(n_live - 1, kids);
        try std.testing.expectEqual(n_live, an.rpo.len);

        // Loop headers, natural loops and the outermost owner.
        const owner = try aa.alloc(u32, nb);
        @memset(owner, none_u32);
        const member = try aa.alloc(bool, nb);
        for (an.rpo) |h| {
            var header = false;
            for (0..nb) |p| {
                if (!live[p]) continue;
                var buf: [2]u32 = undefined;
                const ss = Naive.succs(&mir, @intCast(p), &buf);
                if (std.mem.findScalar(u32, ss, h) != null and dom[h * nb + p]) header = true;
            }
            try std.testing.expectEqual(header, an.is_loop[h]);
            if (!header) continue;
            // Every live block that reaches a back-edge source without
            // passing `h`, to a fixpoint.
            @memset(member, false);
            member[h] = true;
            var grew = true;
            while (grew) {
                grew = false;
                for (0..nb) |b| {
                    if (!live[b] or member[b]) continue;
                    var buf: [2]u32 = undefined;
                    for (Naive.succs(&mir, @intCast(b), &buf)) |s| {
                        const back_edge = s == h and dom[h * nb + b];
                        if (back_edge or (s != h and member[s])) {
                            member[b] = true;
                            grew = true;
                            break;
                        }
                    }
                }
            }
            for (0..nb) |b| if (member[b] and owner[b] == none_u32) {
                owner[b] = h;
            };
        }
        for (0..nb) |b| {
            try std.testing.expectEqual(owner[b], an.loop_of[b]);
            try std.testing.expectEqual(owner[b] != none_u32, an.inLoop(@intCast(b)));
        }

        // Immediate post-dominators: every block here reaches the exit, so
        // `x` post-dominates `b` iff `b` cannot reach it avoiding `x`, and
        // `ipdom[b]` (`nb`: the virtual exit) is the nearest strict one. An
        // unreachable block is cut off from the reverse walk and flows to the
        // virtual exit.
        const pd = try aa.alloc(bool, @as(usize, nb) * nb);
        for (0..nb) |x| for (0..nb) |b| {
            pd[x * nb + b] = x == b or !Naive.reachesExit(&mir, tmp, stack, @intCast(b), @intCast(x));
        };
        try std.testing.expectEqual(nb, an.ipdom[nb]);
        for (0..nb) |b| {
            const ip = an.ipdom[b];
            if (!live[b]) {
                try std.testing.expectEqual(nb, ip);
                continue;
            }
            try std.testing.expect(ip != b);
            if (ip != nb) try std.testing.expect(pd[ip * nb + b]);
            for (0..nb) |d| if (d != b and pd[d * nb + b]) {
                try std.testing.expect(ip != nb);
                try std.testing.expect(pd[d * nb + ip]);
            };
        }
    }
}

test "analysis: the per-block pools are the chain, filtered" {
    // b0: p = V(a); live = -p; dead = -p (aliased to live); br p b1 b1'.
    // b1: phi live, phi dead (aliased); jump b2.
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    const lowered: Lowered = .{};
    const b0 = try mir.addBlock(a);
    const b1 = try mir.addBlock(a);
    const b2 = try mir.addBlock(a);
    const b3 = try mir.addBlock(a);
    const p = try mir.addBlockParam(a, 0);
    const live = try mir.emit(a, b0, .fneg, &.{p});
    const dead = try mir.emit(a, b0, .fneg, &.{p});
    mir.setAlias(dead, live);
    _ = try mir.emitBranch(a, b0, p, b1, b2);
    _ = try mir.emitJump(a, b1, b3);
    _ = try mir.emitJump(a, b2, b3);
    const ph = try mir.emitPhi(a, b3, &.{ .{ .block = b1, .value = live }, .{ .block = b2, .value = p } });
    const ph_dead = try mir.emitPhi(a, b3, &.{ .{ .block = b1, .value = p }, .{ .block = b2, .value = p } });
    mir.setAlias(ph_dead, p);

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    const inst = struct {
        fn of(m: *const Mir, v: Mir.Value) Mir.Inst {
            return m.valueDef(v).inst_result;
        }
    }.of;
    // b0's window is its whole chain; its statements skip the aliased row
    // and the terminator.
    try std.testing.expectEqual(@as(usize, 3), an.blockInstsFlat(0).len);
    try std.testing.expectEqualSlices(Mir.Inst, &.{inst(&mir, live)}, an.stmt_pool[an.stmt_off[0]..an.stmt_off[1]]);
    try std.testing.expectEqualSlices(Mir.Inst, &.{inst(&mir, ph)}, an.phi_pool[an.phi_off[3]..an.phi_off[4]]);
    try std.testing.expectEqual(an.stmt_off[3], an.stmt_off[4]);
    // b3 is b0's only merge-block dominator child; b1 and b2 are not merges.
    try std.testing.expectEqualSlices(u32, &.{3}, an.mk_pool[an.mk_off[0]..an.mk_off[1]]);
    try std.testing.expectEqual(an.mk_off[1], an.mk_off[an.nb]);
    try std.testing.expectEqual(@as(u32, 0), an.def_block[@backingInt(live)]);
    try std.testing.expectEqual(@as(u32, 3), an.def_block[@backingInt(ph)]);
}

test "wideWidth: a `$wide` root's width reaches a select over it" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    var lowered: Lowered = .{};
    defer lowered.wide_nodes.deinit(a);
    try lowered.wide_nodes.append(a, .{ .op = .leaf_int, .width = 40 });
    _ = try mir.addBlock(a);
    const w = try mir.emitCall(a, .entry, try mir.internString(a, "$wide"), &.{.zero});
    const p = try mir.addBlockParam(a, 0);
    const sel = try mir.emit(a, .entry, .select, &.{ p, w, w });
    const r = try mir.emit(a, .entry, .fneg, &.{p});

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    try std.testing.expectEqual(VTy.wide, an.tyOf(w));
    try std.testing.expectEqual(@as(u32, 40), an.wideWidth(w));
    try std.testing.expectEqual(@as(u32, 40), an.wideWidth(sel));
    try std.testing.expectEqual(@as(u32, 0), an.wideWidth(r));
}

test "analysis: dependency masks are exact past 64 unknowns" {
    // 70 unknowns, so two words a value. `far` reads unknown 67 only: word 1
    // bit 3. A delay over it puts the same bit in `acdyn`.
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    var lowered: Lowered = .{};
    defer lowered.nodes.deinit(a);
    for (0..70) |_| try lowered.nodes.append(a, .{ .name = "n", .kind = .net, .disc = "", .dir = .unspecified });
    _ = try mir.addBlock(a);
    const far = try mir.addBlockParam(a, 67);
    const near = try mir.addBlockParam(a, 1);
    const prod = try mir.emit(a, .entry, .fmul, &.{ far, .f_two });
    const sum = try mir.emit(a, .entry, .fadd, &.{ near, prod });
    const k = try mir.emit(a, .entry, .fadd, &.{ .f_one, .f_two });
    const dly = try mir.emitCall(a, .entry, try mir.internString(a, "absdelay"), &.{ far, try mir.addFloatConst(a, 1e-9) });
    const stopped = try mir.emit(a, .entry, .dstop, &.{sum});

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    try std.testing.expectEqual(@as(u32, 2), an.dep_words);
    try std.testing.expectEqualSlices(u64, &.{ 0, 1 << 3 }, an.unknownDeps(prod));
    try std.testing.expectEqualSlices(u64, &.{ 1 << 1, 1 << 3 }, an.unknownDeps(sum));
    try std.testing.expectEqualSlices(u64, &.{ 0, 0 }, an.unknownDeps(k));
    try std.testing.expectEqualSlices(u64, &.{ 0, 1 << 3 }, an.acDynDeps(dly));
    try std.testing.expectEqualSlices(u64, &.{ 0, 0 }, an.acDynDeps(prod));
    try std.testing.expect(!an.dFree(prod) and !an.dFree(sum) and an.dFree(k));
    // A `dstop` keeps the value varying in both words, with no derivative.
    try std.testing.expect(an.dFree(stopped) and an.xDep(stopped) and an.pointDep(stopped));
    try std.testing.expectEqualSlices(u64, &.{ 1 << 1, 1 << 3 }, an.xdeps[@backingInt(stopped) * 2 ..][0..2]);
}

test foldConst {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    var lowered: Lowered = .{};
    defer lowered.params.deinit(a);
    _ = try mir.addBlock(a);
    const k_default = try mir.addFloatConst(a, 2.5);
    try lowered.params.append(a, .{ .name = "k", .ty = .real, .default = k_default });
    const k = try mir.addParamRef(a, 0);
    const twice = try mir.emit(a, .entry, .fmul, &.{ k, .f_two });
    // §4.2.12 is lazy: `0 > 0 ? 1 % 0 : 10` folds to 10 although `1 % 0`
    // has no value (§4.2.4).
    const c = try mir.emit(a, .entry, .fgt, &.{ .f_zero, .f_zero });
    const bad = try mir.emit(a, .entry, .fmod, &.{ .f_one, .f_zero });
    const sel = try mir.emit(a, .entry, .select, &.{ c, bad, .f_ten });
    const isum = try mir.emit(a, .entry, .iadd, &.{ .one, .one });
    const probe = try mir.addBlockParam(a, 0);
    const varies = try mir.emit(a, .entry, .fadd, &.{ probe, .f_one });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    // Only a Model default looks through a parameter to its declaration.
    try std.testing.expectEqual(@as(?Folded, null), an.foldConst(twice, false));
    try std.testing.expectEqual(@as(f64, 5), an.foldConst(twice, true).?.f);
    try std.testing.expectEqual(@as(?Folded, null), an.foldConst(bad, true));
    try std.testing.expectEqual(@as(f64, 10), an.foldConst(sel, false).?.f);
    try std.testing.expectEqual(@as(f64, 2), an.foldConst(isum, false).?.f);
    try std.testing.expectEqual(@as(?Folded, null), an.foldConst(varies, true));
    try std.testing.expectEqual(@as(?Folded, null), an.foldConst(.undef, true));
}

test "analysis: §3.2.2 array versions, value types and per-instance reads" {
    const a = std.testing.allocator;
    var mir: Mir = .{};
    defer mir.deinit(a);
    var lowered: Lowered = .{};
    defer lowered.mem_arrays.deinit(a);
    defer lowered.params.deinit(a);
    try lowered.mem_arrays.append(a, .{ .name = "m", .len = 4, .ty = .integer });
    try lowered.params.append(a, .{ .name = "n", .ty = .integer, .default = .one });

    const entry = try mir.addBlock(a);
    const next = try mir.addBlock(a);
    const a0 = try mir.emitAnew(a, entry, 0);
    const st = try mir.emit(a, entry, .store, &.{ a0, .zero, .one });
    const ld = try mir.emit(a, entry, .iload, &.{ st, .zero });
    const held = try mir.emitCall(a, entry, try mir.internString(a, "$held_real"), &.{.zero});
    const from_held = try mir.emit(a, entry, .fadd, &.{ held, .f_one });
    const given = try mir.emitCall(a, entry, try mir.internString(a, "$param_given"), &.{});
    const text = try mir.addStrConst(a, "s");
    const n = try mir.addParamRef(a, 0);
    const probe = try mir.addBlockParam(a, 0);
    const isel = try mir.emit(a, entry, .select, &.{ probe, .one, .zero });
    const fsel = try mir.emit(a, entry, .select, &.{ probe, .f_one, .zero });
    _ = try mir.emitJump(a, entry, next);
    const ph = try mir.emitPhi(a, next, &.{.{ .block = entry, .value = st }});
    const phi_inst = mir.valueDef(ph).inst_result;

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const an = try build(arena.allocator(), &mir, &lowered);
    // An `anew`, a `store` from it and a phi over that are one array; a load
    // is a scalar. A version's type is its element type.
    for ([_]Mir.Value{ a0, st, ph }) |v| {
        try std.testing.expectEqual(@as(?u32, 0), an.arrOf(v));
        try std.testing.expectEqual(VTy.int, an.tyOf(v));
    }
    try std.testing.expectEqual(@as(?u32, null), an.arrOf(ld));
    try std.testing.expectEqual(VTy.int, an.tyOf(ld));
    // A call's type is its callee's; a select's is its then arm's.
    try std.testing.expectEqual(VTy.int, an.tyOf(given));
    try std.testing.expectEqual(VTy.real, an.tyOf(held));
    try std.testing.expectEqual(VTy.str, an.tyOf(text));
    try std.testing.expectEqual(VTy.int, an.tyOf(n));
    try std.testing.expectEqual(VTy.int, an.tyOf(isel));
    try std.testing.expectEqual(VTy.real, an.tyOf(fsel));
    // A held read varies per instance but not with x.
    try std.testing.expect(an.pointDep(from_held) and !an.xDep(from_held) and an.dFree(from_held));
    try std.testing.expect(!an.pointDep(given));
    // §4.2.12: the select's condition does not enter its derivative.
    try std.testing.expect(an.dFree(isel));
    // `phiIn` is the pair for the edge, null for an edge with none.
    try std.testing.expectEqual(@as(?Mir.Value, st), an.mir.phiIn(phi_inst, entry));
    try std.testing.expectEqual(@as(?Mir.Value, null), an.mir.phiIn(phi_inst, next));
    try std.testing.expectEqual(@as(u32, @backingInt(entry)), an.def_block[@backingInt(st)]);
    try std.testing.expectEqual(none_u32, an.def_block[@backingInt(probe)]);
}
