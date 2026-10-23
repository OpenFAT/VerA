//! Value and instruction rendering: one MIR value or instruction in, its Zig
//! expression text out, with the §4.2.1.1/§4.2.1.2 integer/real conversions
//! explicit. LRM clauses cited: §2.7, §2.9, §3.2, §3.2.1, §3.2.2, §4.2.1, §4.2.4, §4.2.11,
//! §4.3.1, §4.3.2, §4.5, §9.4, §9.13, §9.21.

const std = @import("std");
const assert = std.debug.assert;
const float_lanes = @import("float/lanes.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_host = @import("host_expr.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_mask = @import("mask.zig");
const gen_file = @import("file.zig");
const gen_instance = @import("instance.zig");
const gen_setup = @import("setup.zig");
const gen_cfg = @import("cfg.zig");
const gen_unit = @import("unit.zig");
const family = @import("family.zig");
const opcode_zig = codegen.opcode_zig;
const Mir = @import("ir").Mir;
const Analysis = @import("prove").Analysis;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;

/// `.ipow`'s device text: `kernels/fold.zig`'s `ipow32` as a callable expression. Locals
/// carry a `zp_` prefix because Zig refuses a name that shadows any enclosing
/// scope's.
pub const ipow_fn = "(struct { fn zp_f(zp_b: i64, zp_n: i64) i64 { " ++
    "if (zp_n < 0) return if (zp_b == 1) 1 else if (zp_b == -1) (if (@rem(zp_n, 2) == 0) 1 else -1) else 0; " ++
    "var zp_x: i32 = @truncate(zp_b); var zp_e = zp_n; var zp_r: i32 = 1; " ++
    "while (zp_e > 0) : (zp_e >>= 1) { if (zp_e & 1 != 0) zp_r *%= zp_x; zp_x *%= zp_x; } " ++
    "return zp_r; } }.zp_f)";

/// Integer `/` with a zero divisor defined as 0 (see `renderOp`'s `.idiv`).
const idiv_fn = "(struct { fn zd_f(zd_a: i64, zd_b: i64) i64 { " ++
    // In i65, so minInt(i64) / -1 wraps as `i64Const`'s host spelling does
    // instead of trapping; the caller truncates to §3.2's 32 bits.
    "return if (zd_b == 0) 0 else @truncate(@divTrunc(@as(i65, zd_a), zd_b)); } }.zd_f)";

/// §4.2.4 permits a varying divisor but requires an error when it is zero.
/// Executables report E0601; solver devices trap without importing host I/O
/// onto GPU targets. -1 divides every integer exactly, including minInt(i64),
/// whose hardware signed remainder would otherwise overflow its quotient.
/// Both ordinary expressions and model-card derivation use this spelling.
pub fn imodFn(self: *const Gen) []const u8 {
    const head = "(struct { fn zm_f(zm_a: i64, zm_b: i64) i64 { if (zm_b == 0) { ";
    const tail = " } return if (zm_b == -1) 0 else @rem(zm_a, zm_b); } }.zm_f)";
    return if (self.display == .emit)
        head ++ "std.debug.print(\"error[E0601]: LRM 4.2.4: integer modulus divisor is zero\\n\", .{}); std.process.exit(1);" ++ tail
    else
        head ++ "@trap();" ++ tail;
}

/// Returns `renderVal`'s text as an arena string instead of appending it to
/// `out`. Renders into `out` and rewinds, so `uses.x`/`uses.model`
/// accounting matches a direct render. For §4.5 operator inputs that must
/// appear inside a kernel call's `{s}`.
pub fn renderToArena(self: *Gen, v: Mir.Value, want: VTy) Error![]const u8 {
    const at = self.out.items.len;
    try renderVal(self, v, want);
    // A nested rewind (`renderLoad`) never reaches below where it started.
    assert(self.out.items.len >= at);
    const s = try self.arena.dupe(u8, self.out.items[at..]);
    self.out.shrinkRetainingCapacity(at);
    return s;
}

/// Writes a value reference, converting per §4.2.1.1/§4.2.1.2 when `want` is
/// the other LRM type.
pub fn renderVal(self: *Gen, v0: Mir.Value, want: VTy) Error!void {
    const v = self.an.rv(v0);
    if (self.subst) |s| if (s.v == v) return renderSubst(self, s, want);
    const def = self.mir.valueDef(v);
    if (def == .undef) {
        // Lowering starts every wide `reg` at its declaration, so no `.wide`
        // operand is undefined.
        if (want == .wide) return gen_call.abort(self, .E1020, "VerA: an undefined wide integer operand", .{});
        // ponytail: undefined operands share the slot initializer's spelling.
        try self.b("{s}", .{gen_unit.zeroOf(want)});
        return;
    }
    if (self.an.tyOf(v) == want) return renderValueRef(self, v);
    switch (want) {
        .real => {
            if (def == .int_const) {
                try self.b("S.con({s})", .{try gen_file.fmtF64(self, @floatFromInt(def.int_const))});
                return;
            }
            try self.b("S.con(@as(f64, @floatFromInt(", .{});
            try renderValueRef(self, v);
            try self.b(")))", .{});
        },
        .int => {
            if (def == .float_const) {
                // Saturate like the runtime cast below, so folding a
                // constant cannot change what the device computes.
                const x = def.float_const;
                try self.b("{d}", .{std.math.lossyCast(i64, @round(x))});
                return;
            }
            // §2.7: a string literal used as an operand is the unsigned
            // base-256 integer its bytes spell (`$strobe("%d", "\n")` is
            // 10). Lowering converts every numeric context it can see; a
            // format operand is paired with its specifier only here.
            if (self.an.tyOf(v) == .str) return switch (def) {
                .str_const => |s| self.b("@as(i64, {d})", .{@import("kernels").fold.strToInt(s, 64)}),
                // Not a literal, so §3.3 leaves it with no numeric value.
                .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => self.b("@as(i64, 0)", .{}),
            };
            float_lanes.leadLanes(self, v); // a real→int collapse is a decision
            // Saturating (§4.2.1.1 defines only the rounding): under
            // ReleaseFast `@intFromFloat` of an out-of-range or NaN value is UB.
            try self.b("zRoundI(S, ", .{});
            try renderValueRef(self, v);
            try self.b(")", .{});
        },
        .str => try self.b("\"\"", .{}),
        // Lowering hands a wide operand only a wide value (`analog/wide.zig`).
        .wide => return gen_call.abort(self, .E1020, "VerA: a {t} value where a wide integer is wanted", .{self.an.tyOf(v)}),
    }
}

/// Writes `v` in its own type: a setup root, a core cache field, a unit-local
/// slot, `S.con(literal)`, `model.<name>`, `x[@intFromEnum(U.<node>)]`, or the
/// instruction rendered inline. Never a `v{MIR index}` name.
pub fn renderValueRef(self: *Gen, v: Mir.Value) Error!void {
    const i = @backingInt(v);
    // `setup` wrote the field when the card, instance or temperature changed.
    if (i < self.an.nv and self.plan.isRoot(v)) {
        const f = try gen_setup.rootRef(self, v, false);
        return if (self.an.vty[i] == .int) self.b("{s}", .{f}) else self.b("S.con({s})", .{f});
    }
    // Hoisted: computed once by the shared core, read from its cache.
    if (i < self.an.nv and self.plan.cached(v)) return self.b("c.f{d}", .{self.core.lo_idx[i]});
    if (i < self.an.nv and self.plan.slot[i] != none_u32) {
        gen_unit.probeUse(self, self.plan.slot[i]);
        try gen_unit.writeSlotRef(self, i);
        return;
    }
    switch (self.mir.valueDef(v)) {
        .undef => try self.b("S.con(0.0)", .{}),
        .float_const => |x| try self.b("S.con({s})", .{try gen_file.fmtF64(self, x)}),
        .int_const => |x| try self.b("@as(i64, {d})", .{x}),
        .str_const => |s| try self.b("\"{f}\"", .{std.zig.fmtString(s)}),
        .param_ref => |p| {
            self.uses.model = true;
            switch (Analysis.tyOfParam(self.lowered.params.items[p].ty)) {
                .real => try self.b("S.con(model.{s})", .{self.names.p_names[p]}),
                // The field may be narrower than the i64 the bodies compute in.
                .int => try self.b("@as(i64, model.{s})", .{self.names.p_names[p]}),
                .str => try self.b("model.{s}", .{self.names.p_names[p]}),
                .wide => unreachable, // `tyOfParam` types no parameter wide
            }
        },
        .block_param => |u| {
            self.uses.x = true;
            // Every probe read needs its lane; `deriv_reads` is this sound
            // superset.
            gen_mask.set(self.jac.deriv_reads, u);
            try self.b("x[@intFromEnum(U.{s})]", .{self.names.u_names[u]});
        },
        .inst_result => |inst| try renderInst(self, inst),
    }
}

/// Returns whether `v` renders as a name (slot, cache field or setup field)
/// rather than an expression. The stop condition `eagerSafe`, `maskCmp` and
/// `foldHidesSlot` share.
pub fn materialized(self: *const Gen, v: Mir.Value) bool {
    const i = @backingInt(v);
    return i < self.an.nv and
        (self.plan.isRoot(v) or self.plan.cached(v) or self.plan.slot[i] != none_u32);
}

/// Returns the select condition's unslotted real comparison, so rendering it
/// in mask space leaves no unread `const`. Null for slotted predicates and
/// int comparisons, which take the `S.con(@floatFromInt(..))` fallback.
fn maskCmp(self: *Gen, cond: Mir.Value) ?Mir.Inst {
    const v = self.an.rv(cond);
    if (materialized(self, v)) return null;
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return null;
    return switch (self.mir.instOp(def.inst_result)) {
        .flt, .fgt, .fle, .fge, .feq, .fne => def.inst_result,
        else => null, // else: only the six §4.2.5 REAL comparisons have an `S` mask form
    };
}

/// Writes instruction `inst` as an expression.
pub fn renderInst(self: *Gen, inst: Mir.Inst) Error!void {
    const row = self.mir.instRow(inst);
    const op = row.op;
    if (op == .call) return gen_call.emitCall(self, inst);
    if (op == .phi) return self.b("S.con(0.0)", .{}); // materialised as a var
    if (op == .fload or op == .iload) return renderLoad(self, inst);

    // A derivative-free subtree is one `S.con` over plain f64 arithmetic:
    // each S op it replaces would carry zero lanes `.strict` cannot fold.
    // `f64Const` succeeds only on literals, parameters and arithmetic.
    const res = self.mir.instResult(inst);
    if (res != .undef and self.an.vty[@backingInt(res)] == .real and self.an.dFree(res)) {
        // A value the analysis folds from literals alone (never through a
        // parameter) is its literal: `pow(0.5178…, -2)` is no `zPowK` call.
        // The planner made it a slot-free leaf (`UnitPlan.literal`).
        if (self.plan.literal(res)) return self.b("S.con({s})", .{try gen_file.fmtF64(self, self.an.foldConst(res, false).?)});
        if (try gen_host.f64Const(self, res, 0, true)) |s| return self.b("S.con({s})", .{s});
    }

    const a: Mir.Value = @fromBackingInt(@intCast(row.a));
    const b2: Mir.Value = @fromBackingInt(@intCast(row.b));
    const c: Mir.Value = @fromBackingInt(@intCast(row.c));

    // §4.2.12 the conditional stays lazy by default: the prover treats the
    // condition as a guard, so `x > 0 ? ln(x) : 0` is accepted, and running
    // ln(x) with x <= 0 is UB under `.optimized`.
    //
    // In a `.strict` unit a real select whose inline arms are total
    // (`eagerSafe`) and cheap (`eagerCostly`) runs both arms and picks with
    // `sel`: a dead arm's NaN/inf is discarded, the branch is gone, and a
    // lane-parallel S gets a per-lane pick. Costly arms on a condition that
    // varies with the solve run both on a GPU target only (#81: `zSpec`),
    // where a branch costs the register allocator more than the arm.
    const res_ty = self.an.vty[@backingInt(res)];
    if (op == .select) {
        const want = res_ty;
        if (want == .real and self.float.strict and
            float_lanes.eagerSafe(self, b2, 0) and float_lanes.eagerSafe(self, c, 0))
        {
            if (!float_lanes.eagerCostly(self, b2, 0) and !float_lanes.eagerCostly(self, c, 0))
                return renderSelEager(self, a, b2, c, res);
            if (float_lanes.perPoint(self, a)) {
                try self.b("(if (comptime zSpec) ", .{});
                try renderSelEager(self, a, b2, c, res);
                try self.b(" else ", .{});
                try renderSelLazy(self, a, b2, c, want, res);
                return self.b(")", .{});
            }
        }
        return renderSelLazy(self, a, b2, c, want, res);
    }
    // §4.3.2 a domain-restricted row `ifconv`'s `.speculate` moved out of its
    // arm runs on its domain's safe argument while its guard is false, so it
    // neither reports nor leaves the domain where the source never ran it.
    const saved = self.subst;
    defer self.subst = saved;
    if (self.mir.guardOf(inst)) |lit| {
        const dom = Mir.opcode.get(op).domain;
        self.subst = .{ .v = self.an.rv(if (dom == .nonzero_divisor) b2 else a), .lit = lit, .safe = safeArg(dom) };
    }
    return renderOp(self, op, a, b2, res_ty);
}

/// A real select that runs both arms and picks. An integer-condition `S`
/// pick is `zPick`, whose arguments both run: a lazy `if` over two `S` values
/// joins them through a pointer phi (`zPick`'s doc).
fn renderSelEager(self: *Gen, a: Mir.Value, b2: Mir.Value, c: Mir.Value, res: Mir.Value) Error!void {
    // Best mask first: an inline real comparison renders as
    // `lt`/`le`/`eq`, true per lane. gt/ge swap operands; ne swaps
    // the arms. Otherwise the predicate is a 0/1 i64 (lane-uniform,
    // so it pins) or a real S tested against zero.
    var swap_arms = false;
    if (maskCmp(self, a)) |cmp| {
        const d = self.mir.instData(cmp).binary;
        const swap_ops = d.op == .fgt or d.op == .fge;
        swap_arms = d.op == .fne;
        const prim: []const u8 = switch (d.op) {
            .flt, .fgt => "lt",
            .fle, .fge => "le",
            .feq, .fne => "eq",
            else => unreachable, // else: `maskCmp` returns only the six real comparisons
        };
        // A family's `sel` is `S.sel` (`contract.family_fns`).
        try self.b("S.sel((", .{});
        try renderVal(self, if (swap_ops) d.rhs else d.lhs, .real);
        try self.b(").{s}(", .{prim});
        try renderVal(self, if (swap_ops) d.lhs else d.rhs, .real);
        try self.b("), ", .{});
    } else if (self.an.tyOf(self.an.rv(a)) == .int) {
        // A 0/1 i64 is already one scalar decision, so an `S` mask
        // buys nothing: pick in f64 when both arms have an f64 form,
        // else pick the `S` arm.
        float_lanes.pinLanes(self, a);
        const fb = try gen_host.f64Const(self, b2, 1, true);
        const fc = if (fb != null) try gen_host.f64Const(self, c, 1, true) else null;
        if (fc == null) {
            const m = family.mask(self, res);
            try self.b("zPick(S, (", .{});
            try renderVal(self, a, .int);
            try self.b(") != 0, ", .{});
            for ([_]Mir.Value{ b2, c }, 0..) |v, k| {
                if (k != 0) try self.b(", ", .{});
                try family.openTo(self, m);
                try renderVal(self, v, .real);
                try self.b(")", .{});
            }
            return self.b(")", .{});
        }
        try self.b("S.con(if ((", .{});
        try renderVal(self, a, .int);
        return self.b(") != 0) {s} else {s})", .{ fb.?, fc.? });
    } else {
        try self.b("S.sel(", .{});
        try renderVal(self, a, .real);
        try self.b(", ", .{});
    }
    try renderVal(self, if (swap_arms) c else b2, .real);
    try self.b(", ", .{});
    try renderVal(self, if (swap_arms) b2 else c, .real);
    try self.b(")", .{});
}

/// A select that runs only the arm its condition takes.
fn renderSelLazy(self: *Gen, a: Mir.Value, b2: Mir.Value, c: Mir.Value, want: VTy, res: Mir.Value) Error!void {
    try self.b("(if (", .{});
    try gen_cfg.renderCond(self, a);
    try self.b(") ", .{});
    if (want == .real) return renderArms(self, b2, c, family.mask(self, res));
    try renderVal(self, b2, want);
    try self.b(" else ", .{});
    try renderVal(self, c, want);
    try self.b(")", .{});
}

/// What `renderVal` writes in place of a guarded row's restricted operand
/// (`Gen.subst`): `v` while the guard chain from `lit` holds, else `safe`.
pub const Subst = struct { v: Mir.Value, lit: u32, safe: f64 };

/// A point inside each §4.3.1/§4.3.2 domain (Table 4-14/4-15) with a finite
/// derivative there, so the discarded result and its lanes stay finite:
/// ln(1), ln1p(0), sqrt(1), asin(0), atanh(0), acosh(2), x/1, tan(0),
/// pow(1, y).
fn safeArg(dom: Mir.opcode.Domain) f64 {
    return switch (dom) {
        .positive, .non_negative, .nonzero_divisor, .pow_sign => 1.0,
        .gt_neg_one, .unit_closed, .unit_open, .tan_poles => 0.0,
        .ge_one => 2.0,
        .all => unreachable, // `ifconv` guards only a domain-restricted row
    };
}

/// Writes the guard chain from `lit` as one `bool`: each literal's condition,
/// negated on an else arm, joined by `and`.
fn renderGuard(self: *Gen, lit0: u32) Error!void {
    var lit = lit0;
    var first = true;
    while (lit != Mir.GuardLit.end) {
        const l = self.mir.guard_lits.items[lit];
        if (!first) try self.b(" and ", .{});
        first = false;
        try self.b("{s}(", .{if (l.taken) "" else "!"});
        try gen_cfg.renderCond(self, l.cond);
        try self.b(")", .{});
        lit = l.next;
    }
}

/// Writes `s.v` behind its guard: the operand while the guard holds, else
/// the domain's safe value at the operand's type.
fn renderSubst(self: *Gen, s: Subst, want: VTy) Error!void {
    self.subst = null;
    defer self.subst = s;
    switch (want) {
        .real => {
            const m = family.mask(self, s.v);
            try self.b("zPick(S, ", .{});
            try renderGuard(self, s.lit);
            try self.b(", ", .{});
            try family.openTo(self, m);
            try renderVal(self, s.v, .real);
            try self.b("), ", .{});
            try family.openTo(self, m);
            try self.b("S.con({s})))", .{try gen_file.fmtF64(self, s.safe)});
        },
        .int => {
            try self.b("(if (", .{});
            try renderGuard(self, s.lit);
            try self.b(") ", .{});
            try renderVal(self, s.v, .int);
            try self.b(" else @as(i64, {d}))", .{@as(i64, @intFromFloat(s.safe))});
        },
        // A domain-restricted operand is a number (`Mir.opcode`).
        .str, .wide => try renderVal(self, s.v, want),
    }
}

/// Writes a lazy real `if`'s `then else otherwise)` after its condition. Both
/// arms widen to the result's mask `m`, the one type the `if` can have.
fn renderArms(self: *Gen, then: Mir.Value, otherwise: Mir.Value, m: []const u64) Error!void {
    for ([_]Mir.Value{ then, otherwise }, 0..) |v, k| {
        if (k != 0) try self.b(" else ", .{});
        try family.openTo(self, m);
        try renderVal(self, v, .real);
        try self.b(")", .{});
    }
    try self.b(")", .{});
}

// §3.2.2 memory-backed arrays. Every version of array `id` shares one local
// `a<id>: [len]T`; a load reads where it stands (`plan/unit.zig` never
// inlines a load past a later store). `T` is `S` only when a load reads a
// derivative a store put there (`Gen.arr_s`). A plain §5.10 held array is
// copy-on-write (`cow`): loads read through `p<id>`, which starts at the
// `Instance` field, and the first store copies it into `a<id>` (`zArrW`).

/// Is array `id`'s storage plain `f64`/`i64` rather than `S`?
fn arrPlain(self: *const Gen, id: u32) bool {
    assert(id < self.lowered.mem_arrays.items.len);
    assert(self.arr_s.len == self.lowered.mem_arrays.items.len);
    return self.lowered.mem_arrays.items[id].ty == .integer or !self.arr_s[id];
}

/// Returns whether array `id` is read in place from its `Instance` field
/// until first written.
pub fn cow(self: *const Gen, id: u32) bool {
    return self.lowered.mem_arrays.items[id].held != none_u32 and arrPlain(self, id);
}

/// Returns whether the slice being emitted stores held array `id` straight
/// into its `Instance` field (`plan.Core.in_place`, `state.zig`).
pub fn inPlace(self: *const Gen, id: u32) bool {
    // `inPlaceArrays` returns one flag per array, or none at all.
    if (self.core.in_place.len != 0) assert(self.core.in_place.len == self.lowered.mem_arrays.items.len);
    return self.core.in_place.len != 0 and self.core.in_place[id];
}

/// Returns the element type array `id` is stored as.
pub fn arrElemTy(self: *Gen, id: u32) Error![]const u8 {
    if (self.lowered.mem_arrays.items[id].ty == .integer) return "i64";
    if (!self.arr_s[id]) return "f64";
    return family.ofText(self, self.arrMask(id));
}

/// Write a pointer to the storage array version `v` is read from; true when
/// it holds plain values (a cached version always does).
fn arrRef(self: *Gen, v0: Mir.Value) Error!bool {
    const v = self.an.rv(v0);
    if (self.plan.cached(v)) {
        try self.b("&c.f{d}", .{self.core.lo_idx[@backingInt(v)]});
        return true;
    }
    const id = self.an.arrOf(v).?;
    try self.b("{s}{d}", .{ if (cow(self, id)) "p" else "&a", id });
    return arrPlain(self, id);
}

/// Writes a load `a[i]`, with §3.2.2's zero for an index outside the array.
fn renderLoad(self: *Gen, inst: Mir.Inst) Error!void {
    const d = self.mir.instData(inst).load;
    if (d.op == .iload) {
        try self.b("zArrLd(i64, ", .{});
        _ = try arrRef(self, d.arr);
        try self.b(", ", .{});
        try renderVal(self, d.index, .int);
        return self.b(", 0)", .{});
    }
    assert(d.op == .fload);
    const at = self.out.items.len;
    try self.b("zArrLd(S, ", .{});
    if (try arrRef(self, d.arr)) {
        assert(self.out.items.len > at + "zArrLd(S, ".len);
        // Plain storage: re-spell the head, the index follows either way.
        const name = try self.arena.dupe(u8, self.out.items[at + "zArrLd(S, ".len ..]);
        self.out.shrinkRetainingCapacity(at);
        try self.b("S.con(zArrLd(f64, {s}, ", .{name});
        try renderVal(self, d.index, .int);
        return self.b(", 0.0))", .{});
    }
    // The element type is the storage's `zOf`, and so is its zero. A version
    // whose elements depend on no unknown is read lane-free: the storage's
    // mask is the union over every version, and its lanes are zero here, so
    // `zStrip` drops them exactly instead of narrowing a lane `zTo` refuses.
    const id = self.an.arrOf(self.an.rv(d.arr)).?;
    const free = std.mem.allEqual(u64, family.mask(self, self.mir.instResult(inst)), 0) and !std.mem.allEqual(u64, self.arrMask(id), 0);
    const tail = try self.arena.dupe(u8, self.out.items[at + "zArrLd(S, ".len ..]);
    self.out.shrinkRetainingCapacity(at);
    if (free) try self.b("zStrip(S, ", .{});
    try self.b("zArrLd({s}, {s}, ", .{ try arrElemTy(self, id), tail });
    try renderVal(self, d.index, .int);
    try self.b(", zTo(S, 0x{f}, S.con(0.0)))", .{gen_mask.hex(self.arrMask(id), false)});
    if (free) try self.b(")", .{});
}

/// Writes the statement an `anew` or `store` is, at its place in the block.
pub fn emitArrayStmt(self: *Gen, inst: Mir.Inst, depth: u32) Error!void {
    try self.ind(depth);
    switch (self.mir.instData(inst)) {
        .anew => |d| {
            const m = self.lowered.mem_arrays.items[d.array];
            const plain = arrPlain(self, d.array);
            // VerA's `vera_timepoint` (§2.9): the version a cached statement
            // left, from its `Instance` slot; a copy-on-write array reads it
            // in place, as a held one reads its own field.
            if (d.tp) |tp| {
                self.uses.inst = true;
                float_lanes.instPin(self);
                if (cow(self, d.array)) return self.b("p{d} = &inst.tp{d}_s{d};\n", .{ d.array, tp.block, tp.slot });
                if (plain) return self.b("a{d} = inst.tp{d}_s{d};\n", .{ d.array, tp.block, tp.slot });
                return self.b("for (&a{d}, inst.tp{d}_s{d}) |*zd, zs| zd.* = zTo(S, 0x{f}, S.con(zs));\n", .{ d.array, tp.block, tp.slot, gen_mask.hex(self.arrMask(d.array), false) });
            }
            if (m.uninit) {
                // `(* vera_scratch = "uninit" *)` (§2.9): `a<id>` stays the
                // `undefined` it was declared, and the author writes every
                // element before reading it. Under runtime safety a broken
                // promise reads NaN (`S.con` carries zero lanes; `scale` by
                // NaN makes each one NaN) or minInt instead of stale bytes.
                // Otherwise an empty asm that may have written the array
                // ("memory" clobber, its address as input) freezes it: LLVM
                // must treat the contents as defined but unknown, so a broken
                // promise reads a stable garbage value, not undef/poison.
                if (m.ty == .integer) {
                    try self.b("if (std.debug.runtime_safety) @memset(&a{d}, std.math.minInt(i64))", .{d.array});
                } else if (plain) {
                    try self.b("if (std.debug.runtime_safety) @memset(&a{d}, std.math.nan(f64))", .{d.array});
                } else {
                    try self.b("if (std.debug.runtime_safety) @memset(&a{d}, zTo(S, 0x{f}, S.con(std.math.nan(f64))).scale(std.math.nan(f64)))", .{ d.array, gen_mask.hex(self.arrMask(d.array), false) });
                }
                return self.b(" else asm volatile (\"\" : : [p] \"r\" (&a{d}) : .{{ .memory = true }});\n", .{d.array});
            }
            // §3.2 every evaluation starts it at zero.
            if (m.held == none_u32) {
                if (!plain) return self.b("@memset(&a{d}, zTo(S, 0x{f}, S.con(0.0)));\n", .{ d.array, gen_mask.hex(self.arrMask(d.array), false) });
                return self.b("@memset(&a{d}, {s});\n", .{ d.array, if (m.ty == .integer) "0" else "0.0" });
            }
            // §5.10 a held array starts from what the last accepted
            // evaluation left in its `Instance` field.
            self.uses.inst = true;
            float_lanes.instPin(self); // a held array is one instance's
            const f = self.names.held_names[m.held];
            if (plain) return self.b("p{d} = &inst.{s};\n", .{ d.array, f });
            return self.b("for (&a{d}, inst.{s}) |*zd, zs| zd.* = zTo(S, 0x{f}, S.con(zs));\n", .{ d.array, f, gen_mask.hex(self.arrMask(d.array), false) });
        },
        .store => |d| {
            const id = self.an.arrOf(d.arr).?;
            const m = self.lowered.mem_arrays.items[id];
            // Only a §5.10 held array has an `Instance` field to store into.
            if (inPlace(self, id)) assert(m.held != none_u32);
            const r = self.an.rv(self.mir.instResult(inst));
            if (self.emitting_common and self.core.held_only.len != 0 and self.core.held_only[@backingInt(r)]) {
                self.uses.held = true;
                try self.b("if (held) ", .{});
            }
            const ty = try arrElemTy(self, id);
            // A store made from another store's version writes storage that
            // one has already copied in; the seed, or a join that may be it,
            // goes through `zArrW`.
            const after_store = switch (self.mir.valueDef(self.an.rv(d.arr))) {
                .inst_result => |di| self.mir.instOp(di) == .store,
                else => false, // else: an array version is an instruction result
            };
            // VerA's `vera_timepoint` (§2.9): inside a statement that caches
            // the array, the copy goes to its slot (`zArrWT`), always through
            // the pointer check: a store before the statement may have
            // copied it into `a<id>` already.
            const tp = gen_instance.tpSlotAt(self, @backingInt(self.mir.instBlock(inst)), id);
            if (tp != null) self.uses.inst = true;
            if (inPlace(self, id) and gen_instance.dirtyTracked(self, id))
                try self.b("zArrStD({s}, p{d}, &inst.{s}__dirty, ", .{ ty, id, self.names.held_names[m.held] })
            else if (inPlace(self, id))
                try self.b("zArrSt({s}, p{d}, ", .{ ty, id })
            else if (tp) |s|
                try self.b("zArrSt({s}, zArrWT({s}, {d}, &inst.tp{d}_s{d}, &a{d}, &p{d}), ", .{ ty, ty, m.len, s.b, s.k, id, id })
            else if (cow(self, id) and !after_store)
                try self.b("zArrSt({s}, zArrW({s}, {d}, &a{d}, &p{d}), ", .{ ty, ty, m.len, id, id })
            else
                try self.b("zArrSt({s}, &a{d}, ", .{ ty, id });
            try renderVal(self, d.index, .int);
            try self.b(", ", .{});
            if (m.ty == .integer) {
                try renderVal(self, d.value, .int);
            } else if (arrPlain(self, id)) {
                // No load reads this element's derivative, so only the value
                // is kept: a scalar collapse, which pins.
                float_lanes.pinLanes(self, d.value);
                try self.b("(", .{});
                try renderVal(self, d.value, .real);
                try self.b(").val()", .{});
            } else {
                try family.openTo(self, self.arrMask(id));
                try renderVal(self, d.value, .real);
                try self.b(")", .{});
            }
            return self.b(");\n", .{});
        },
        .unary, .binary, .ternary, .phi, .branch, .jump, .call, .load => unreachable, // `emitBlockInsts` sends only array versions
    }
}

/// Writes a held array's end-of-block version as the core's plain
/// `[len]f64`/`[len]i64`.
pub fn renderArrayOut(self: *Gen, v: Mir.Value) Error!void {
    const id = self.an.arrOf(v).?;
    if (cow(self, id)) return self.b("p{d}.*", .{id});
    if (arrPlain(self, id)) return self.b("a{d}", .{id});
    try self.b("zArrVal({s}, {d}, &a{d})", .{ try arrElemTy(self, id), self.lowered.mem_arrays.items[id].len, id });
}

/// Writes one opcode over its operands. Also serves the `$`-prefixed math
/// functions (IEEE 1364 §17.11).
///
/// Asserts that `op` is a unary or binary opcode.
pub fn renderOp(self: *Gen, op: Mir.Opcode, a: Mir.Value, b2: Mir.Value, res_ty: VTy) Error!void {
    assert(Mir.opClass(op) == .unary or Mir.opClass(op) == .binary);
    // §3.3.1 string relations: lowering types both operands `.string` and
    // picks the integer comparison opcodes for them.
    if (self.an.tyOf(self.an.rv(a)) == .str or self.an.tyOf(self.an.rv(b2)) == .str) {
        const rel: ?[]const u8 = switch (op) {
            .ieq, .feq => "== 0",
            .ine, .fne => "!= 0",
            .ilt, .flt => "< 0",
            .ile, .fle => "<= 0",
            .igt, .fgt => "> 0",
            .ige, .fge => ">= 0",
            else => null, // else: §3.3.1 relates strings with these six; any other op falls to its numeric form
        };
        if (rel) |r| {
            try self.b("@as(i64, @intFromBool(zStrCmp(", .{});
            try renderVal(self, a, .str);
            try self.b(", ", .{});
            try renderVal(self, b2, .str);
            try self.b(") {s}))", .{r});
            return;
        }
    }
    switch (op) {
        // §4.2.4 real arithmetic. With one operand derivative-free, `scale`
        // and `addC` skip the zero-lane multiply and add that `.strict` will
        // not fold. Each rewrite is value-preserving under IEEE 754 (`a - k`
        // is `a + (-k)`). `fdiv` keeps `div`: `a * (1/k)` is not `a / k`.
        .fadd, .fsub, .fmul => {
            // A derivative-free operand that still differs per point (a
            // `ddx`-stripped probe) goes through `zMulP`/`zAddP`/`zSubP`:
            // `scale`/`addC` of its value in a one-point family, the same
            // arithmetic kept per point in a batch.
            const pa = perPoint(self, a);
            const pb = perPoint(self, b2);
            if (pb or (pa and !self.an.dFree(b2))) {
                const k, const o = if (pb) .{ b2, a } else .{ a, b2 };
                try self.b("{s}(S, (", .{switch (op) {
                    .fmul => "zMulP",
                    .fsub => if (pb) "zSubP" else "zAddP",
                    else => "zAddP", // else: the prong is `.fadd, .fsub, .fmul`
                }});
                try renderVal(self, o, .real);
                try self.b("){s}, ", .{if (op == .fsub and !pb) ".neg()" else ""});
                try renderVal(self, k, .real);
                return self.b(")", .{});
            }
            if (self.an.dFree(b2)) {
                try self.b("(", .{});
                try renderVal(self, a, .real);
                try self.b(").{s}(", .{if (op == .fmul) "scale" else "addC"});
                if (op == .fsub) try writeNegConst(self, b2) else try writeConst(self, b2);
                return self.b(")", .{});
            }
            if (self.an.dFree(a)) {
                try self.b("(", .{});
                try renderVal(self, b2, .real);
                // k - b: negate first, so the constant still arrives through
                // `addC` and the derivative costs one negation.
                try self.b("){s}.{s}(", .{
                    if (op == .fsub) ".neg()" else "",
                    if (op == .fmul) "scale" else "addC",
                });
                try writeConst(self, a);
                return self.b(")", .{});
            }
            try method2(self, a, switch (op) {
                .fadd => "add",
                .fsub => "sub",
                else => "mul", // else: the prong is `.fadd, .fsub, .fmul`
            }, b2);
        },
        // §4.3.1/§4.3.2 math: one `S` method or kernel per opcode
        // (`opcode_zig`'s `s` column; `.custom` here is a compile error).
        // expm1/log1p are primitives, not compositions of exp/log, because
        // Table 4-14 names them for the cancellation those would suffer.
        inline .fdiv,
        .fneg,
        .fmod,
        .sqrt,
        .exp,
        .ln,
        .sin,
        .cos,
        .tanh,
        .sinh,
        .cosh,
        .atan,
        .fabs,
        .expm1,
        .ln1p,
        .log10,
        .tan,
        .asin,
        .acos,
        .asinh,
        .acosh,
        .atanh,
        .floor,
        .ceil,
        .hypot,
        .atan2,
        .fmin,
        .fmax,
        => |o| {
            const r = comptime opcode_zig.get(o);
            const binary = comptime Mir.opClass(o) == .binary;
            if (r.pins_lanes) {
                float_lanes.pinLanes(self, a);
                if (binary) float_lanes.pinLanes(self, b2);
            }
            // §4.3.2 a domain error is reported where the op runs, not where
            // `setup` speculates it outside its guard (`Setup.spec`).
            if (comptime r.checked) |c| {
                if (binary) @compileError("renderOp: a `checked` spelling is unary, `" ++ @tagName(o) ++ "` is binary");
                if (!self.su.spec) return switch (c) {
                    .helper => |h| helper1(self, h, a),
                    .helper_s => |h| helperS(self, h, a),
                    .method, .custom => @compileError("renderOp: `" ++ @tagName(o) ++ "`'s checked spelling is a kernel"),
                };
            }
            switch (r.s) {
                .method => |m| if (binary) try method2(self, a, m, b2) else try method1(self, a, m),
                .helper => |h| if (binary) try helper2(self, h, a, b2) else try helper1(self, h, a),
                .helper_s => |h| if (binary) @compileError("renderOp: `helper_s` is unary, `" ++ @tagName(o) ++ "` is binary") else try helperS(self, h, a),
                .custom => @compileError("renderOp: opcode_zig gives `" ++ @tagName(o) ++ "` no S spelling"),
            }
        },
        .pow => {
            // `S.pow` takes an f64 exponent. A literal exponent folds with
            // `resolve_params = false`, so a model-card override is never
            // baked in as the declared default. A solve-constant exponent
            // (`pow(1 - v/pj, 1 - mj)`) takes the same route spelled as an
            // expression, which keeps it off `zPow`'s lane-pinning path.
            // `UnitPlan.foldedExponent` mirrors this test; change both.
            const par_exp: ?[]const u8 = if (self.an.foldConst(b2, false) == null and self.an.dFree(b2))
                try gen_host.f64Const(self, b2, 1, true)
            else
                null;
            // §4.3.2 the domain check (`zPowK`) wherever the op runs, and
            // the bare method where `setup` speculates it (`Setup.spec`).
            const k_text: ?[]const u8 = if (self.an.foldConst(b2, false)) |k| try gen_file.fmtF64(self, k) else par_exp;
            if (k_text) |k| {
                if (self.su.spec) try self.b("(", .{}) else try self.b("zPowK(S, ", .{});
                try renderVal(self, a, .real);
                if (self.su.spec) try self.b(").pow({s})", .{k}) else try self.b(", {s})", .{k});
            } else {
                // zPow linearizes around `.val()` of both operands
                // (including §4.3.1's negative-base steering): a batch
                // family runs it point by point (`zPowL`, the lead protocol).
                float_lanes.leadLanes(self, a);
                float_lanes.leadLanes(self, b2);
                // The last argument drops the ∂/∂y term (and its `ln`) when
                // the exponent cannot move with the solve.
                const m = gen_mask.hex(try gen_mask.join(self.arena, family.mask(self, a), family.mask(self, b2)), false);
                try self.b("zPowL(S, 0x{f}, zTo(S, 0x{f}, ", .{ m, m });
                try renderVal(self, a, .real);
                try self.b("), zTo(S, 0x{f}, ", .{m});
                try renderVal(self, b2, .real);
                try self.b("), {})", .{!self.an.dFree(b2)});
            }
        },
        // §4.2.1 conversions
        .if_cast => {
            try self.b("S.con(@as(f64, @floatFromInt(", .{});
            try renderVal(self, a, .int);
            try self.b(")))", .{});
        },
        .fi_cast => {
            // §4.2.1.1 rounds and leaves overflow undefined; `lossyCast`
            // (saturate, NaN to 0) avoids UB under ReleaseFast and matches
            // `fold.Const.asInt`'s fold.
            float_lanes.leadLanes(self, a); // a real→int collapse is a decision
            try self.b("zRoundI(S, ", .{});
            try renderVal(self, a, .real);
            try self.b(")", .{});
        },
        .opt_barrier => try renderVal(self, a, res_ty),
        // VerA's `vera_nodiff` (§2.9): the operand's value with no lanes. The
        // `.val()` is a scalar decision on an x-varying value.
        .dstop => {
            float_lanes.leadLanes(self, a);
            try self.b("zStrip(S, ", .{});
            try renderVal(self, a, .real);
            try self.b(")", .{});
        },
        // §5.6.1.2 path-integrated reactive latches: value only, fixed
        // across one Newton attempt (advanced by stateCtl(.commit)). The
        // coefficient's dA enters only times (B - pb), which is zero at
        // every committed point, so the AD Jacobian is exact.
        .path_prev, .path_acc => {
            const v = self.an.rv(a);
            const fam = if (op == .path_prev) self.core.prev_vals else self.core.acc_vals;
            const k = std.mem.findScalar(Mir.Value, fam, v).?; // plan_core.plan queued every site
            self.uses.inst = true; // the latch read keeps `inst` in the signature
            float_lanes.instLanes(self, false);
            try self.b("zInst(S, inst, \"{s}__{d}\")", .{ @as([]const u8, if (op == .path_prev) "pb" else "pq"), k });
        },
        // §3.2 integer arithmetic at 32-bit two's complement width
        // (`kernels/fold.zig`'s `wrap32`). `%` never widens; `/` overflows only for
        // -2^31 / -1, whose wrapped answer is -2^31.
        .iadd => try intBin32(self, a, "+%", b2),
        .isub => try intBin32(self, a, "-%", b2),
        .imul => try intBin32(self, a, "*%", b2),
        .idiv => {
            // §4.2.4 has no zero rule for `/`, so a divisor the prover
            // cannot show non-zero is accepted (with W0653) and goes through
            // `idiv_fn`, where x / 0 is 0. A literal other than 0 and -1 keeps
            // the bare `@divTrunc`: -1 overflows at minInt(i64), which a
            // saturated real -> int conversion can hold.
            const lit = self.mir.valueDef(self.an.rv(b2));
            const bare = lit == .int_const and lit.int_const != 0 and lit.int_const != -1;
            try self.b("@as(i64, @as(i32, @truncate(", .{});
            try intCall2(self, if (bare) "@divTrunc" else idiv_fn, a, b2);
            try self.b(")))", .{});
        },
        .imod => try intCall2(self, imodFn(self), a, b2),
        .ineg => {
            try self.b("@as(i64, @as(i32, @truncate(-%(", .{});
            try renderVal(self, a, .int);
            try self.b("))))", .{});
        },
        .iabs => try intCall1(self, "zIabs", a),
        .imin => try intCall2(self, "@min", a, b2),
        .imax => try intCall2(self, "@max", a, b2),
        // Inline rather than a shared helper, which would grow every device.
        // An anonymous struct, so two nested `**` cannot collide on a label.
        .ipow => try intCall2(self, ipow_fn, a, b2),
        // §4.2.5/§4.2.7 relational and equality, integer 0/1
        .flt => try cmpReal(self, a, .lt, b2),
        .fgt => try cmpReal(self, a, .gt, b2),
        .fle => try cmpReal(self, a, .lte, b2),
        .fge => try cmpReal(self, a, .gte, b2),
        .feq => try cmpReal(self, a, .eq, b2),
        .fne => try cmpReal(self, a, .neq, b2),
        .ilt => try cmpInt(self, a, "<", b2),
        .igt => try cmpInt(self, a, ">", b2),
        .ile => try cmpInt(self, a, "<=", b2),
        .ige => try cmpInt(self, a, ">=", b2),
        .ieq => try cmpInt(self, a, "==", b2),
        .ine => try cmpInt(self, a, "!=", b2),
        // §4.2.8 logical
        .logand, .logor => {
            try self.b("@as(i64, @intFromBool((", .{});
            try renderVal(self, a, .int);
            try self.b(") != 0 {s} (", .{if (op == .logand) "and" else "or"});
            try renderVal(self, b2, .int);
            try self.b(") != 0))", .{});
        },
        .lognot => {
            try self.b("@as(i64, @intFromBool((", .{});
            try renderVal(self, a, .int);
            try self.b(") == 0))", .{});
        },
        // §4.2.9 bitwise
        .bitand => try intBin(self, a, "&", b2),
        .bitor => try intBin(self, a, "|", b2),
        .bitxor => try intBin(self, a, "^", b2),
        .bitxnor => {
            try self.b("~(", .{});
            try intBin(self, a, "^", b2);
            try self.b(")", .{});
        },
        .bitnot => {
            try self.b("~(", .{});
            try renderVal(self, a, .int);
            try self.b(")", .{});
        },
        // §4.2.11 shifts. The truncation is §3.2's width (`1 << 31` is
        // negative, `1 << 32` is zero). `zShl` defines an over-wide or
        // negative count instead of UB.
        .shl => {
            try self.b("@as(i64, @as(i32, @truncate(", .{});
            try intCall2(self, "zShl", a, b2);
            try self.b(")))", .{});
        },
        // §4.2.11 "fill the vacated bit positions with zeroes" at §3.2.1's
        // 32-bit width, so not `std.math.shr(i64, ...)`, which sign-fills.
        // `zShr` defines an over-wide or negative count as 0.
        .shr => try intCall2(self, "zShr", a, b2),
        // §3.2.2 array ops are rendered by `renderLoad`/`emitArrayStmt`.
        .phi, .select, .call, .branch, .jump, .anew, .fload, .iload, .store => unreachable,
    }
}

/// Returns whether folding `v` to one number would leave a materialized
/// temporary unread. `UnitPlan` already declared every slot, and an unread
/// `const` does not compile. Walks only the shapes `foldConst` walks and
/// answers true for the rest.
pub fn foldHidesSlot(self: *Gen, v0: Mir.Value, depth: u32) bool {
    if (depth > 32) return true;
    const v = self.an.rv(v0);
    if (depth > 0 and materialized(self, v)) return true;
    const def = self.mir.valueDef(v);
    if (def != .inst_result) return false;
    const row = self.mir.instRow(def.inst_result);
    return switch (Mir.opClass(row.op)) {
        .unary => foldHidesSlot(self, @fromBackingInt(@intCast(row.a)), depth + 1),
        .binary => foldHidesSlot(self, @fromBackingInt(@intCast(row.a)), depth + 1) or
            foldHidesSlot(self, @fromBackingInt(@intCast(row.b)), depth + 1),
        .ternary, .phi, .branch, .jump, .call, .anew, .load, .store => true,
    };
}

/// Whether real `v` is derivative-free yet x-dependent: a `.val()` of it
/// would be one point's value (see `renderOp`'s `.fadd, .fsub, .fmul`).
fn perPoint(self: *Gen, v: Mir.Value) bool {
    return self.an.dFree(v) and float_lanes.perPoint(self, v) and self.an.tyOf(self.an.rv(v)) == .real;
}

/// Writes the f64 value of a derivative-free operand (callers check `dFree`).
/// Prefers the arithmetic itself (`model.is`); falls back to `.val()` of the
/// rendered S for values with no GPU-safe f64 spelling (`$temperature`, a
/// transcendental of a parameter). Depth 1: naming the operand's own slot
/// is wanted here, unlike `renderInst`'s depth-0 self-reference.
fn writeConst(self: *Gen, v: Mir.Value) Error!void {
    if (try gen_host.f64Const(self, v, 1, true)) |s| return self.b("{s}", .{s});
    // A derivative-free value can still differ per point (a `ddx`-stripped
    // probe): `.val()` collapses it to one, so a batch is not exact.
    float_lanes.pinLanes(self, v);
    try self.b("(", .{});
    try renderVal(self, v, .real);
    try self.b(").val()", .{});
}

/// Writes `writeConst` negated, for `a - k` as `a.addC(-k)`. A literal
/// negates in the formatter (`addC(-1.0)`), not with a `-(...)` wrapper.
fn writeNegConst(self: *Gen, v: Mir.Value) Error!void {
    // Same guard as `f64Const`.
    if (!foldHidesSlot(self, v, 0)) {
        if (self.an.foldConst(v, false)) |k| return self.b("{s}", .{try gen_file.fmtF64(self, -k)});
    }
    try self.b("-(", .{});
    try writeConst(self, v);
    try self.b(")", .{});
}

fn method1(self: *Gen, a: Mir.Value, name: []const u8) Error!void {
    try self.b("(", .{});
    try renderVal(self, a, .real);
    try self.b(").{s}()", .{name});
}

fn method2(self: *Gen, a: Mir.Value, name: []const u8, b2: Mir.Value) Error!void {
    try self.b("(", .{});
    try renderVal(self, a, .real);
    try self.b(").{s}(", .{name});
    try renderVal(self, b2, .real);
    try self.b(")", .{});
}

/// `name(S, a)` with `S` as written: `zAbs` takes the family itself.
fn helperS(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
    try self.b("{s}(S, ", .{name});
    try renderVal(self, a, .real);
    try self.b(")", .{});
}

/// Writes a one-operand kernel call at the operand's mask.
fn helper1(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
    const m = family.mask(self, a);
    try kernelOpen(self, name, m);
    try kernelArg(self, a, m);
    try kernelClose(self);
}

/// Writes a two-operand kernel call at the union of the operands' masks.
pub fn helper2(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void {
    const m = try gen_mask.join(self.arena, family.mask(self, a), family.mask(self, b2));
    try kernelOpen(self, name, m);
    try kernelArg(self, a, m);
    try self.b(", ", .{});
    try kernelArg(self, b2, m);
    try kernelClose(self);
}

/// Writes `zLu(S, m, name(zL(S, m), `: kernels take one scalar, which a
/// family is at one mask. `m` is the result's. Close with `kernelClose`.
fn kernelOpen(self: *Gen, name: []const u8, m: []const u64) Error!void {
    const h = gen_mask.hex(m, false);
    try self.b("zLu(S, 0x{f}, {s}(zL(S, 0x{f}), ", .{ h, name, h });
}

/// Writes one real kernel operand, widened to the kernel's mask.
fn kernelArg(self: *Gen, v: Mir.Value, m: []const u64) Error!void {
    try self.b("zLw(S, 0x{f}, ", .{gen_mask.hex(m, false)});
    try renderVal(self, v, .real);
    try self.b(")", .{});
}

/// Writes the two parens `kernelOpen` left open.
fn kernelClose(self: *Gen) Error!void {
    try self.b("))", .{});
}

/// Writes `(a) opx (b2)` over integers, unwrapped: only for the bitwise ops
/// that cannot leave §3.2's range.
fn intBin(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
    try self.b("((", .{});
    try renderVal(self, a, .int);
    try self.b(") {s} (", .{opx});
    try renderVal(self, b2, .int);
    try self.b("))", .{});
}

/// Writes `intBin` truncated to §3.2's 32-bit width (`fold.wrap32`). `opx`
/// must be a wrapping op (`+%`): an overflowing i64 `+` would panic before
/// the truncation.
fn intBin32(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
    try self.b("@as(i64, @as(i32, @truncate(", .{});
    try intBin(self, a, opx, b2);
    try self.b(")))", .{});
}

/// Writes `name(a)` over an integer operand.
fn intCall1(self: *Gen, name: []const u8, a: Mir.Value) Error!void {
    try self.b("{s}(", .{name});
    try renderVal(self, a, .int);
    try self.b(")", .{});
}

/// Writes one §9.5.4.2 `zScan*` call: `(src, fmt)` for the count, plus the
/// item index for an item. `want` is the result's type; only `.real` gets
/// an `S.con` wrapper.
pub fn emitScan(self: *Gen, fn_name: []const u8, args: []const Mir.Value, want: VTy) Error!void {
    if (want == .real) try self.b("S.con(", .{});
    try self.b("{s}(", .{fn_name});
    try renderVal(self, if (args.len > 0) args[0] else .undef, .str);
    try self.b(", ", .{});
    try renderVal(self, if (args.len > 1) args[1] else .undef, .str);
    if (args.len > 2) {
        try self.b(", ", .{});
        try renderVal(self, args[2], .int);
    }
    try self.b(")", .{});
    if (want == .real) try self.b(")", .{});
}

/// Writes one §9.13 probabilistic draw. `$rng$auto` reads the seedless
/// form's `Instance` field; every other name is a `rng_kernels.zig` call on
/// the i64 seed and its real parameters. Always pins lanes.
pub fn emitRng(self: *Gen, c: Mir.Callee, args: []const Mir.Value) Error!void {
    // One draw per call, not per lane.
    float_lanes.pinCrossing(self);
    switch (c) {
        .@"$rng$auto" => {
            // §9.13.1's internal seed; `updateState` advances it on the
            // accepted step, never here.
            self.uses.inst = true;
            const site = intArg(self, args, 0) orelse 0;
            return self.b("S.con(@floatFromInt(inst.rng_auto[{d}]))", .{site});
        },
        .@"$rng$check" => {
            if (args.len != 4) return gen_call.abort(self, .E1020, "malformed RNG validation effect", .{});
            const val = "zV"; // a family has no `S.val`
            try self.b("S.con(zRngCheck({s}(", .{val});
            try renderVal(self, args[0], .real);
            try self.b("), {d}, {s}(", .{ intArg(self, args, 1) orelse return gen_call.abort(self, .E1020, "missing RNG validation rules", .{}), val });
            try renderVal(self, args[2], .real);
            try self.b("), {s}(", .{val});
            try renderVal(self, args[3], .real);
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
    try self.b("S.con({s}(", .{fn_name.items});
    try renderVal(self, if (args.len > 0) args[0] else .zero, .int);
    for (args[@min(1, args.len)..]) |a| {
        try self.b(", ", .{});
        try renderVal(self, a, .real);
        try self.b(".val()", .{});
    }
    try self.b("))", .{});
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
    // The lookup runs at the union of its points' masks.
    const m = try gen_mask.zero(self.arena, self.mw);
    for (args[7..head]) |v| gen_mask.orIn(m, family.mask(self, v));
    const val = "zV"; // a family has no `S.val`
    const pt = try self.arena.print("zL(S, 0x{f})", .{gen_mask.hex(m, false)});
    if (site != 0) {
        self.uses.inst = true;
        self.float.pinned = true;
        try self.b("tbl_{d}: {{ _ = {s}(", .{ @backingInt(inst), val });
        try renderVal(self, args[6], .real);
        try self.b("); if (!inst.table_ready[{d}]) {{ inst.table_{d} = [_]f64{{", .{ site - 1, site - 1 });
    } else {
        try self.b("zLu(S, 0x{f}, zTable({s}, {d}, {d}, {d}, {d}, \"{s}\", [_]f64{{", .{ gen_mask.hex(m, false), pt, np, ncol, nd, dep, ext });
    }
    for (args[head..], 0..) |v, k| {
        if (k != 0) try self.b(", ", .{});
        try self.b("{s}(", .{val});
        try renderVal(self, v, .real);
        try self.b(")", .{});
    }
    if (site != 0) {
        try self.b("}}; inst.table_ready[{d}] = true; }} break :tbl_{d} ", .{ site - 1, @backingInt(inst) });
        try self.b("zLu(S, 0x{f}, ", .{gen_mask.hex(m, false)});
        try self.b("zTable({s}, {d}, {d}, {d}, {d}, \"{s}\", inst.table_{d}, [_]{s}{{", .{ pt, np, ncol, nd, dep, ext, site - 1, pt });
    } else try self.b("}}, [_]{s}{{", .{pt});
    for (args[7..head], 0..) |v, k| {
        if (k != 0) try self.b(", ", .{});
        try kernelArg(self, v, m);
    }
    try self.b("}}))", .{});
    if (site != 0) try self.b("; }}", .{});
}

/// Writes a §3.2/§5.7 runtime array index in the shape
/// `analog/expr.zig`'s `lowerIndex` gives it, `(lo, i, e_lo … e_hi)`, as one `switch`: one dispatch and one
/// element evaluation per read (a `sel` chain would evaluate every element).
/// An out-of-range read yields the element type's zero; an integer array
/// cannot yield x. Pins lanes when the index depends on x.
pub fn emitIdx(self: *Gen, args: []const Mir.Value, want: VTy) Error!void {
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
    try renderVal(self, args[1], .int);
    try self.b(") {{", .{});
    for (args[2..], 0..) |v, k| {
        try self.b(" {d} => ", .{lo + @as(i64, @intCast(k))});
        if (widen) try family.openTo(self, m);
        try renderVal(self, v, want);
        if (widen) try self.b(")", .{});
        try self.b(",", .{});
    }
    // §5.7 defers out-of-range reads to IEEE 1800: the element type's
    // default, which §3.2 makes zero in an analog context. The read must
    // neither alias another element (clamp, wrap) nor abort (§4.3.2
    // reserves "shall report an error" for named cases).
    if (widen) return self.b(" else => zTo(S, 0x{f}, {s}) }}", .{ gen_mask.hex(m, false), gen_unit.zeroOf(want) });
    try self.b(" else => {s} }}", .{gen_unit.zeroOf(want)});
}

/// Returns the non-negative integer literal lowering put at `args[i]`, or
/// null when absent or not such a literal.
pub fn intArg(self: *const Gen, args: []const Mir.Value, i: usize) ?usize {
    if (i >= args.len) return null;
    return std.math.cast(usize, self.an.intConst(args[i]) orelse return null);
}

// ponytail: integer callees infer their type; add a typed variant only for a caller.
fn intCall2(self: *Gen, name: []const u8, a: Mir.Value, b2: Mir.Value) Error!void {
    try self.b("{s}(", .{name});
    try renderVal(self, a, .int);
    try self.b(", ", .{});
    try renderVal(self, b2, .int);
    try self.b(")", .{});
}

/// `op`'s tag names are the device kernel `zCmp`'s operator names.
fn cmpReal(self: *Gen, a: Mir.Value, op: std.math.CompareOperator, b2: Mir.Value) Error!void {
    float_lanes.leadLanes(self, a);
    float_lanes.leadLanes(self, b2);
    try self.b("@as(i64, @intFromBool(zCmp(S, .{s}, ", .{@tagName(op)});
    try renderVal(self, a, .real);
    try self.b(", ", .{});
    try renderVal(self, b2, .real);
    try self.b(")))", .{});
}

fn cmpInt(self: *Gen, a: Mir.Value, opx: []const u8, b2: Mir.Value) Error!void {
    try self.b("@as(i64, @intFromBool((", .{});
    try renderVal(self, a, .int);
    try self.b(") {s} (", .{opx});
    try renderVal(self, b2, .int);
    try self.b(")))", .{});
}
