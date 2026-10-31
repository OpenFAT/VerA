//! Guard evidence: branch and select conditions in, interval facts about
//! their operands out, applied to congruence classes through an undo log.
//! Writes `Prover.class_of`, the fact environment (`civ`, `ctop`, `saved`,
//! `seed`, `def_pos`, `def_seq`), `uses`, `facts` and `guard`. A condition is
//! mined for §4.2.5 relational and §4.2.7 equality facts; `&&`/`||` need no
//! case, since §4.2.8 short-circuit gives them real CFG.
//!
//! LRM clauses this file's code cites: §3.2.2, §4.2.4, §4.2.5, §4.2.7,
//! §4.2.8, §4.2.12, §5.10.3.3.
//!
//! Contents:
//! - `pub const Error = Allocator.Error`
//! - `pub fn buildClasses(p: *Prover) Error!void`
//! - `pub fn markSelectArms(p: *Prover) Error!void`
//! - `pub fn condFacts(p: *const Prover, cond: Mir.Value, taken: bool, buf: *[2]Prover.Fact) []const Prover.Fact`
//! - `pub fn pushFacts(p: *Prover, facts: []const Prover.Fact) Error!void`
//! - `pub fn popFacts(p: *Prover, mark: usize) void`
//! - `pub fn isPredicateValue(mir: *const Mir, v: Mir.Value) bool`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Interval = @import("Interval.zig");
const Prover = @import("Prover.zig");
const Fact = Prover.Fact;
const none = Prover.none;

/// Every pass here fails only on allocation, in the prover's arena.
pub const Error = Allocator.Error;

/// Most values one select arm's exclusive slice is walked over: a shared
/// value stops the walk, so this bounds a pathological arm, not a real one.
const arm_values_max: u32 = 4096;

/// Groups structurally identical pure instructions into congruence classes
/// (a key on already-resolved operands, no transitive numbering), then
/// builds the empty fact environment. Phi, call, terminators,
/// `opt_barrier`, `anew` and `store` are never merged. Asserts that it runs
/// once, after `seed.seedValues`.
pub fn buildClasses(p: *Prover) Error!void {
    const n = p.an.nv;
    assert(p.iv.len == n);
    assert(p.class_of.len == 0);
    p.class_of = try p.arena.alloc(u32, n);
    @memset(p.class_of, none);

    const Key = struct { op: Mir.Opcode, a: u32, b: u32, c: u32 };
    // At most one key per instruction: sized once, never rehashed.
    var map: std.AutoHashMapUnmanaged(Key, u32) = .empty;
    try map.ensureTotalCapacity(p.arena, @intCast(p.mir.insts.len));
    var n_classes: u32 = 0;
    for (0..p.mir.insts.len) |i| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(i));
        const op = p.mir.instOp(inst);
        // §3.2.2 two `anew`s of one array, or two equal stores, are two
        // versions of one storage at two times, not one value.
        if (op == .phi or op == .call or op == .opt_barrier or op == .anew or op == .store) continue;
        const result = p.mir.instResult(inst);
        if (result == .undef) continue;
        var buf: [3]Mir.Value = undefined;
        const ops = p.operands(inst, &buf);
        const key: Key = .{
            .op = op,
            .a = if (ops.len > 0) p.idxOf(ops[0]) else 0,
            .b = if (ops.len > 1) p.idxOf(ops[1]) else 0,
            .c = if (ops.len > 2) p.idxOf(ops[2]) else 0,
        };
        const gop = map.getOrPutAssumeCapacity(key);
        if (!gop.found_existing) {
            gop.value_ptr.* = n_classes;
            n_classes += 1;
        }
        p.class_of[p.idxOf(result)] = gop.value_ptr.*;
    }
    p.n_classes = n_classes;

    // The fact environment `ivAt` reads, empty: no fact is active yet.
    p.seed = try p.arena.dupe(Interval, p.iv);
    p.def_pos = try p.arena.alloc(u32, n);
    @memset(p.def_pos, none);
    p.def_seq = try p.arena.alloc(u64, n);
    p.civ = try p.arena.alloc(Interval, n_classes + n);
    @memset(p.civ, Interval.top);
    p.ctop = try p.arena.alloc(u32, n_classes + n);
    @memset(p.ctop, none);
    assert(n_classes <= p.mir.insts.len);
    assert(p.saved.items.len == 0);
}

/// Marks each `select` arm's exclusively-owned backward slice (use count 1)
/// as guarded by the select's condition, since a select's arms carry no CFG
/// dominance. `?:` lowers to a real diamond (§4.2.3), so this covers the
/// other selects: masked element writes at a runtime array index and the
/// §5.10.3.3 `enable` fold, and what if-conversion made. Codegen obligation:
/// a guarded `select` evaluates only the taken arm. Asserts that it runs
/// once, after `buildClasses`.
pub fn markSelectArms(p: *Prover) Error!void {
    assert(p.class_of.len == p.an.nv);
    assert(p.facts.items.len == 0);
    countUses(p);
    for (0..p.mir.insts.len) |i| {
        const inst: Mir.Inst = @fromBackingInt(@intCast(i));
        if (p.mir.instOp(inst) != .select) continue;
        const t = p.mir.instData(inst).ternary;
        try markArm(p, t.then_val, t.cond, true);
        try markArm(p, t.else_val, t.cond, false);
    }
}

/// Returns the facts implied by taking (or not taking) a branch on `cond`,
/// written into `buf`. Peels `!` and the §4.2.8 `c != 0` materialisation of
/// a comparison; keeps a bare `x != 0` as the §4.2.4 nonzero fact.
pub fn condFacts(p: *const Prover, cond: Mir.Value, taken: bool, buf: *[2]Fact) []const Fact {
    var c = cond;
    var t = taken;
    // Bound: each hop moves to an operand of a non-phi row, which SSA defines
    // before its use, so the chain visits each value once.
    var hops: u32 = 0;
    while (true) : (hops += 1) {
        assert(hops < p.an.nv);
        const def = p.mir.valueDef(p.an.rv(c));
        if (def != .inst_result) return buf[0..0];
        switch (p.mir.instData(def.inst_result)) {
            .unary => |u| {
                if (u.op != .lognot) return buf[0..0];
                c = u.operand;
                t = !t;
            },
            .binary => |b| {
                if (b.op == .ine or b.op == .fne or b.op == .ieq or b.op == .feq) {
                    const flip = b.op == .ieq or b.op == .feq;
                    const zl = isZeroConst(p, b.lhs);
                    const zr = isZeroConst(p, b.rhs);
                    const other: ?Mir.Value = if (zr) b.lhs else if (zl) b.rhs else null;
                    if (other) |o| {
                        if (isPredicateValue(p.mir, o)) {
                            c = o;
                            t = t != flip;
                            continue;
                        }
                        if (t == flip) return buf[0..0];
                        buf[0] = .{ .v = p.idxOf(o), .iv = .{ .nonzero = true } };
                        return buf[0..1];
                    }
                }
                return relationFacts(p, b, t, buf);
            },
            .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => return buf[0..0],
        }
    }
}

/// Applies facts to their classes (a fact about one member holds for every
/// member), logging what each overwrote. O(1) per fact (#29).
/// Invalidates `saved` element pointers if additional memory is needed.
pub fn pushFacts(p: *Prover, facts: []const Fact) Error!void {
    const len_before = p.saved.items.len;
    for (facts) |f| {
        const c = p.clsOf(f.v);
        p.push_seq += 1;
        try p.saved.append(p.arena, .{ .prev = p.civ[c], .cls = c, .prev_top = p.ctop[c], .seq = p.push_seq });
        p.ctop[c] = @intCast(p.saved.items.len - 1);
        p.civ[c] = p.civ[c].meet(f.iv);
    }
    assert(p.saved.items.len == len_before + facts.len);
}

/// Undoes every push after `mark`, newest first. Asserts that `mark` is a
/// length the log had.
pub fn popFacts(p: *Prover, mark: usize) void {
    assert(mark <= p.saved.items.len);
    while (p.saved.items.len > mark) {
        const f = p.saved.pop().?;
        p.civ[f.cls] = f.prev;
        p.ctop[f.cls] = f.prev_top;
    }
    assert(p.saved.items.len == mark);
}

/// Returns whether `v` is a 0/1 predicate (§4.2.5/§4.2.8). Shared with
/// ifconv.zig's `peelToBool`: what peels there must be exactly what
/// `condFacts` can mine, or a peel silently un-guards `b != 0 ? a/b : 0`.
pub fn isPredicateValue(mir: *const Mir, v: Mir.Value) bool {
    const def = mir.valueDef(mir.resolveAlias(v));
    if (def != .inst_result) return false;
    return Mir.opcode.get(mir.instOp(def.inst_result)).predicate;
}

// ---- private ----

/// How often each value is read, alias-resolved, saturating. It walks the
/// block chains, so a row in no chain (the branch and jumps if-conversion
/// orphans) is not a use. It skips a collapsed phi's operands (ssa.zig
/// contract 1): the phi aliases the value they resolve to, which its users
/// already count. Contribution roots count once each, so a root is never
/// taken for an exclusive arm.
fn countUses(p: *Prover) void {
    assert(p.uses.len == p.an.nv);
    const mir = p.mir;
    for (p.lowered.contributions.items) |c| {
        p.uses[p.idxOf(c.resist_val)] +|= 1;
        p.uses[p.idxOf(c.react_val)] +|= 1;
    }
    for (p.an.inst_pool) |inst| {
        if (mir.instOp(inst) == .phi) {
            if (mir.hasAlias(mir.instResult(inst))) continue;
            const ph = mir.instData(inst).phi;
            for (0..ph.count) |k| p.uses[p.idxOf(mir.phiPair(inst, @intCast(k)).value)] +|= 1;
            continue;
        }
        var buf: [3]Mir.Value = undefined;
        for (p.operands(inst, &buf)) |v| p.uses[p.idxOf(v)] +|= 1;
    }
}

fn markArm(p: *Prover, arm: Mir.Value, cond: Mir.Value, taken: bool) Error!void {
    var raw: [2]Fact = undefined;
    const facts = condFacts(p, cond, taken, &raw);
    if (facts.len == 0) return;
    const start: u32 = @intCast(p.facts.items.len);
    try p.facts.appendSlice(p.arena, facts);
    const ref: Prover.GuardRef = .{ .start = start, .count = @intCast(facts.len) };

    // DFS the arm's exclusively-owned slice; a shared value stops the walk,
    // so it is linear in the arm.
    var stack: std.ArrayList(Mir.Value) = .empty;
    try stack.append(p.arena, arm);
    var budget: u32 = arm_values_max;
    while (stack.pop()) |v| {
        if (budget == 0) break;
        budget -= 1;
        const i = p.idxOf(v);
        if (p.uses[i] != 1 or p.guard[i].count != 0) continue;
        const def = p.mir.valueDef(@fromBackingInt(@intCast(i)));
        if (def != .inst_result) continue;
        p.guard[i] = ref;
        const inst = def.inst_result;
        if (p.mir.instOp(inst) == .phi) continue; // a phi is not arm-local
        var buf: [3]Mir.Value = undefined;
        for (p.operands(inst, &buf)) |o| try stack.append(p.arena, o);
    }
    assert(p.facts.items.len == start + ref.count);
}

fn isZeroConst(p: *const Prover, v: Mir.Value) bool {
    return (p.literalNumber(v) orelse return false) == 0.0;
}

/// Whether `v` is never NaN at run time: a number constant, a parameter or a
/// probe (finite or ±inf by the host contract), an integer, or a value the
/// walk already proved finite. Before `walk` every computed real answers
/// false.
// ponytail: a select arm's guard is mined before `walk`, so a false edge
// over a computed real gives it nothing. Mine arm guards lazily in the walk
// if a model needs them.
fn nanFree(p: *const Prover, v: Mir.Value) bool {
    const rv = p.an.rv(v);
    return switch (p.mir.valueDef(rv)) {
        .float_const => |c| !math.isNan(c),
        .int_const, .str_const, .param_ref, .block_param => true,
        .inst_result => |inst| Mir.opIsInteger(p.mir.instOp(inst)) or p.finite[@backingInt(rv)],
        .undef => false,
    };
}

/// The facts of a comparison `b` that went `taken`, normalised to `lo REL hi`.
fn relationFacts(p: *const Prover, b: @FieldType(Mir.InstData, "binary"), taken: bool, buf: *[2]Fact) []const Fact {
    const cmp = Mir.opcode.get(b.op).rel orelse return buf[0..0];
    // A false `<`, `<=`, `>` or `>=` gives the reverse relation only between
    // numbers: every ordering against NaN is false. `!=` is true against NaN,
    // so its false edge is a real `==`.
    const ordering = cmp != .eq and cmp != .ne;
    if (!taken and ordering and !(nanFree(p, b.lhs) and nanFree(p, b.rhs))) return buf[0..0];
    const Rel = enum { lt, le, eq };
    // The negated forms: !(a<b) ⇒ b<=a, !(a<=b) ⇒ b<a.
    const rel: Rel, const swap: bool = switch (cmp) {
        .lt => if (taken) .{ .lt, false } else .{ .le, true },
        .le => if (taken) .{ .le, false } else .{ .lt, true },
        .gt => if (taken) .{ .lt, true } else .{ .le, false },
        .ge => if (taken) .{ .le, true } else .{ .lt, false },
        .eq => if (taken) .{ .eq, false } else return buf[0..0],
        .ne => if (taken) return buf[0..0] else .{ .eq, false },
    };
    const li = p.idxOf(if (swap) b.rhs else b.lhs);
    const hi = p.idxOf(if (swap) b.lhs else b.rhs);
    const a_iv = p.ivAt(li);
    const b_iv = p.ivAt(hi);
    switch (rel) {
        .eq => {
            buf[0] = .{ .v = li, .iv = b_iv };
            buf[1] = .{ .v = hi, .iv = a_iv };
        },
        // a < b  ⇒  a < b.hi  and  b > a.lo
        .lt, .le => {
            const strict = rel == .lt;
            buf[0] = .{ .v = li, .iv = .{ .hi = b_iv.hi, .hi_open = strict or b_iv.hi_open } };
            buf[1] = .{ .v = hi, .iv = .{ .lo = a_iv.lo, .lo_open = strict or a_iv.lo_open } };
        },
    }
    return buf[0..2];
}
