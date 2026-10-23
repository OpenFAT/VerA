//! `prove/setup.zig`'s solve-invariant values + the core's plan -> the setup
//! roots (the invariant values the per-eval core and §9.4 display unit read),
//! `pub const Setup`, and `pub fn setup` computing them into `Model.su` once
//! per model card and temperature (`Model.temperature__`), so the instances
//! of one Model row share them. `setup` is emitted through the same slicer
//! and relooper as the core. `pub fn setupInstance` drops what an instance
//! caches from the card (`vera_timepoint`, a §9.7.3 status).
//! LRM: §2.9, §4.4, §5.10.2, §9.4, §9.15.

const std = @import("std");
const codegen = @import("../codegen.zig");
const kt = @import("kernel_text.zig");
const Gen = codegen.Gen;
const gen_render = @import("render.zig");
const gen_unit = @import("unit.zig");
const gen_cfg = @import("cfg.zig");
const gen_instance = @import("instance.zig");
const plan_setup = @import("prove").setup;
const setup_chunk = @import("setup_chunk.zig");
const Mir = @import("ir").Mir;
const Error = codegen.Error;
const none_u32 = codegen.none_u32;

/// The roots and the emission state of `setup` (`Gen.su`).
pub const Setup = struct {
    /// Value → index in `Setup.r` (reals) or `Setup.i` (integers), or
    /// `none_u32`. Every body but `setup` reads a root as a leaf
    /// (`UnitPlan.isRoot`).
    idx: []u32 = &.{},
    /// The roots, reals first, then integers, then §4.2.5/§4.2.8 0/1 flags;
    /// `real` of them are reals and `int` integers. A root with the same op
    /// and operands as an earlier one is not listed: its `idx` is that one's.
    vals: []Mir.Value = &.{},
    /// How many of `vals` are reals.
    real: u32 = 0,
    /// How many of `vals` are integers.
    int: u32 = 0,
    /// Set while `setup` is being emitted: `emitReturn` stores the roots and
    /// `emitTerm` takes a per-eval branch `then`.
    mode: bool = false,
    /// Set while `setup` emits a value it computes at its `home`, outside
    /// the guard `eval` runs it under (`prove/setup.zig` `speculable`): a
    /// Table 4-14 op there takes its unchecked spelling (`opcode_zig.Row.checked`),
    /// since §4.3.2's error belongs to an evaluation that runs it.
    spec: bool = false,
    /// `setup` referenced its `zs_stop` flag (a per-eval branch or loop).
    stop: bool = false,
    /// Emitting text only a false `zs_stop` reaches: a per-eval branch's
    /// `else` arm, or the body of the loop a stop precedes. It never runs,
    /// so its exits store nothing.
    dead: bool = false,
    /// Live exits `emitStores` reached in the last probe.
    exits: u32 = 0,
    /// Bytes one copy of the root stores took in the last probe.
    store_bytes: usize = 0,
    /// Lines of the last probed body.
    lines: usize = 0,
    /// Set when the repeated stores outweigh re-indenting the body one level
    /// (`mergePays`): each exit leaves the `zs_done` block and the roots are
    /// stored once after it (`emitRoot`).
    merge: bool = false,
    /// How many chunks `setup` was emitted as (`setup_chunk.zig`); 0 when it is
    /// one function. `codegen.Output.setup_chunks`.
    chunks: u32 = 0,
};

/// Returns the instance expression an auxiliary core sweep passes: `inst`,
/// or a declared copy when the device has §9.21 tables, whose first-call
/// state must not be initialized at a trial bias.
pub fn probeInstance(self: *Gen) Error![]const u8 {
    if (self.lowered.table_samples.items.len == 0) return "inst";
    try self.w("    var table_probe = inst.*;\n", .{});
    return "&table_probe";
}

/// Decides the roots: runs the core's (and the display unit's) slice with
/// every `prove/setup.zig` candidate a leaf and keeps the candidates it
/// reaches. Must run after the core is planned and before anything is
/// emitted, since `emitInstance` sizes `Setup` from the roots.
pub fn planSetup(self: *Gen) Error!void {
    const a = self.arena;
    const nv = self.an.nv;
    self.su.idx = try a.alloc(u32, nv);
    @memset(self.su.idx, none_u32);
    self.su.vals = &.{};
    self.su.real = 0;
    // `self.sinv` was computed by `prepare`, before the jobs (`plan/qsite.zig`
    // reads it too).
    // Tables sample on the first ACTUAL evaluation, never at a trial point.
    if (self.lowered.table_samples.items.len != 0) return;
    if (self.core.lo_vals.len == 0 and self.jobs.display_name.len == 0) return;
    for (0..nv) |i| {
        if (plan_setup.candidate(self.input(), self.sinv.val, @fromBackingInt(@intCast(i)))) self.su.idx[i] = 0;
    }
    self.plan.su_idx = self.su.idx;
    self.plan.su_on = true;
    // `root` and `same` are scratch of this pass: on the gpa, freed on return.
    const root = try self.gpa.alloc(bool, nv);
    defer self.gpa.free(root);
    @memset(root, false);
    if (self.core.lo_vals.len != 0) {
        self.plan.display_unit = false;
        try self.plan.analyze(.undef, true);
        for (self.plan.live.items) |lv| {
            if (self.su.idx[@backingInt(lv)] != none_u32) root[@backingInt(lv)] = true;
        }
    }
    for (self.jobs.list) |job| {
        if (job.kind != .display) continue;
        self.plan.display_unit = true;
        try self.plan.analyze(job.target, false);
        self.plan.display_unit = false;
        for (self.plan.live.items) |lv| {
            if (self.su.idx[@backingInt(lv)] != none_u32 and !self.plan.cached(lv)) root[@backingInt(lv)] = true;
        }
    }
    // A card copied beside nothing is a slower read: without a derived root
    // there is no `Setup` to pack it into, and the bodies keep reading the card.
    const derived = for (0..nv) |i| {
        if (root[i] and self.mir.valueDef(@fromBackingInt(@intCast(i))) == .inst_result) break true;
    } else false;
    if (!derived) @memset(root, false);
    @memset(self.su.idx, none_u32);
    const same = try valueNumbers(self);
    defer self.gpa.free(same);
    var vals: std.ArrayList(Mir.Value) = .empty;
    var n: [3]u32 = @splat(0);
    for (0..3) |group| {
        for (0..nv) |i| {
            if (!root[i] or rootGroup(self, @fromBackingInt(@intCast(i))) != group) continue;
            const r = @backingInt(same[i]);
            if (self.su.idx[r] == none_u32) {
                self.su.idx[r] = n[group];
                n[group] += 1;
                try vals.append(a, same[i]);
            }
            self.su.idx[i] = self.su.idx[r];
        }
    }
    self.su.vals = vals.items;
    self.su.real = n[0];
    self.su.int = n[1];
    self.plan.su_idx = self.su.idx;
    self.plan.su_on = vals.items.len != 0;
}

/// Returns which of `Setup`'s arrays holds `v`: 0 real, 1 integer, 2 a 0/1 flag.
fn rootGroup(self: *const Gen, v: Mir.Value) u2 {
    const i = @backingInt(v);
    if (self.an.vty[i] == .real) return 0;
    const def = self.mir.valueDef(v);
    return if (def == .inst_result and Mir.opcode.get(self.mir.instOp(def.inst_result)).bool01) 2 else 1;
}

/// Maps each value to an earlier candidate with the same pure op over the
/// same operands, placed so `setup` has it wherever it has this one (itself
/// if none). Lowering does not number values, so a card expression written
/// twice would otherwise be two roots. `x != 0` over a 0/1 flag `x` is `x`.
/// Caller owns the returned slice and frees it with `self.gpa`.
fn valueNumbers(self: *Gen) Error![]Mir.Value {
    const Opnd = struct { tag: enum(u8) { none, val, f, i, param }, x: u64 };
    const Key = struct { op: Mir.Opcode, a: Opnd, b: Opnd, c: Opnd };
    const nv = self.an.nv;
    const same = try self.gpa.alloc(Mir.Value, nv);
    errdefer self.gpa.free(same);
    for (same, 0..) |*r, i| r.* = @fromBackingInt(@intCast(i));
    // Scratch for this pass alone: on the gpa and freed on return, so its
    // doublings do not stay in the compilation arena.
    var seen: std.AutoHashMapUnmanaged(Key, Mir.Value) = .empty;
    defer seen.deinit(self.gpa);
    const opnd = struct {
        fn f(g: *Gen, sm: []const Mir.Value, raw: u32) ?Opnd {
            const v = g.an.rv(@fromBackingInt(@intCast(raw)));
            return switch (g.mir.valueDef(v)) {
                .inst_result => .{ .tag = .val, .x = @backingInt(sm[@backingInt(v)]) },
                .float_const => |k| .{ .tag = .f, .x = @bitCast(k) },
                .int_const => |k| .{ .tag = .i, .x = @bitCast(k) },
                .param_ref => |k| .{ .tag = .param, .x = k },
                .undef, .str_const, .block_param => null,
            };
        }
    }.f;
    for (Mir.Value.first_dynamic..nv) |i| {
        const v: Mir.Value = @fromBackingInt(@intCast(i));
        if (!plan_setup.candidate(self.input(), self.sinv.val, v) or self.an.rv(v) != v) continue;
        // A parameter leaf is one value per parameter (`param_values`), so
        // it is its own number.
        if (self.mir.valueDef(v) != .inst_result) continue;
        const inst = self.mir.valueDef(v).inst_result;
        if (self.mir.guardOf(inst) != null) continue; // the guard is not in the key
        const row = self.mir.instRow(inst);
        const none: Opnd = .{ .tag = .none, .x = 0 };
        var key: Key = .{ .op = row.op, .a = none, .b = none, .c = none };
        switch (Mir.opClass(row.op)) {
            .unary => key.a = opnd(self, same, row.a) orelse continue,
            .binary => {
                key.a = opnd(self, same, row.a) orelse continue;
                key.b = opnd(self, same, row.b) orelse continue;
            },
            .ternary => {
                const d = self.mir.instData(inst).ternary;
                key.a = opnd(self, same, @backingInt(d.cond)) orelse continue;
                key.b = opnd(self, same, @backingInt(d.then_val)) orelse continue;
                key.c = opnd(self, same, @backingInt(d.else_val)) orelse continue;
            },
            .phi, .branch, .jump, .call, .anew, .load, .store => continue,
        }
        if (row.op == .ine and key.b.tag == .i and key.b.x == 0 and key.a.tag == .val) {
            const x: Mir.Value = @fromBackingInt(@intCast(key.a.x));
            if (rootGroup(self, x) == 2 and plan_setup.candidate(self.input(), self.sinv.val, x) and placedOver(self, x, v)) {
                same[i] = x;
                continue;
            }
        }
        const gop = try seen.getOrPut(self.gpa, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = v;
        } else if (placedOver(self, gop.value_ptr.*, v)) same[i] = gop.value_ptr.*;
    }
    return same;
}

/// Returns whether `setup` computes `a` wherever it computes `b`.
fn placedOver(self: *const Gen, a: Mir.Value, b: Mir.Value) bool {
    return self.an.dominates(placeOf(self, a), placeOf(self, b));
}

fn placeOf(self: *const Gen, v: Mir.Value) u32 {
    const h = self.sinv.home[@backingInt(v)];
    if (h != none_u32) return h;
    const b = self.an.def_block[@backingInt(v)];
    // A leaf (a parameter) has no block: `setup` has it from the entry.
    return if (b == none_u32) 0 else b;
}

/// Returns the text reading root `v`'s `Setup` field, as an f64 (`as_f64`)
/// or in its own type. Arena-owned.
pub fn rootRef(self: *Gen, v: Mir.Value, as_f64: bool) Error![]const u8 {
    const i = @backingInt(v);
    const k = self.su.idx[i];
    self.uses.model = true;
    if (rootGroup(self, v) == 2) {
        if (as_f64) return self.arena.print("@as(f64, @floatFromInt(@intFromBool(model.su.b.isSet({d}))))", .{k});
        return self.arena.print("@as(i64, @intFromBool(model.su.b.isSet({d})))", .{k});
    }
    if (self.an.vty[i] == .int) {
        if (as_f64) return self.arena.print("@as(f64, @floatFromInt(model.su.i[{d}]))", .{k});
        return self.arena.print("model.su.i[{d}]", .{k});
    }
    return self.arena.print("model.su.r[{d}]", .{k});
}

/// Emits `pub const Setup`, the type of `Model.su`.
pub fn emitSetupDecl(self: *Gen) Error!void {
    if (self.su.vals.len == 0) return;
    const n_flag = self.su.vals.len - self.su.real - self.su.int;
    try self.w(
        \\/// Solve-invariant values: functions of `Model` (its card and
        \\/// `temperature__`) only, which `eval` would otherwise recompute at
        \\/// every Newton iterate. `setup` fills them; until it runs the reals
        \\/// are NaN, so a forgotten call is a NaN residual and not a plausible
        \\/// wrong one. `@sizeOf(Setup)` is a per-Model-row cost.
        \\pub const Setup = struct {{
        \\
    , .{});
    if (self.su.real != 0) try self.w("    /// One per invariant real; `eval` reads `model.su.r[k]`.\n    r: [{d}]f64 = @splat(" ++ kt.nan_lit ++ "),\n", .{self.su.real});
    if (self.su.int != 0) try self.w("    /// One per invariant integer; `eval` reads `model.su.i[k]`.\n    i: [{d}]i64 = @splat(0),\n", .{self.su.int});
    if (n_flag != 0) try self.w("    /// One bit per invariant §4.2.5/§4.2.8 condition `eval` branches on.\n    b: std.StaticBitSet({d}) = .empty,\n", .{n_flag});
    try self.w("}};\n\n", .{});
}

/// Emits `pub fn setupInstance` when an instance caches what a card, a
/// temperature or a `$simparam` write invalidates: VerA's `vera_timepoint`
/// (§2.9) caches and a latched §9.7.3 status. The host calls it per instance
/// after `setup` (`contract.validateHost`'s `calls_setup`).
fn emitSetupInstance(self: *Gen) Error!void {
    const tp = self.lowered.timepoints.items.len != 0;
    if (!tp and !gen_instance.hasStatus(self)) return;
    try self.w(
        \\/// Call for every instance after `setup`, or after any write to
        \\/// `Model` or this instance: it drops what the instance cached from
        \\/// them (`vera_timepoint` caches, a latched status).
        \\pub fn setupInstance(_: *const Model, inst: *Instance) void {{
        \\{s}{s}}}
        \\
        \\
    , .{ if (tp) "    zTpDrop(inst);\n" else "", if (gen_instance.hasStatus(self)) gen_instance.status_drop else "" });
}

/// Emits the §9.15 `$simparam`s `setup` reads, so a host knows which writes
/// need a new `setup` call. Collected while `emitSetup` plans its slice.
fn emitSimparams(self: *Gen) Error!void {
    var names: std.ArrayList([]const u8) = .empty;
    for (self.plan.live.items) |lv| {
        const def = self.mir.valueDef(lv);
        if (def != .inst_result or self.mir.instOp(def.inst_result) != .call) continue;
        const d = self.mir.instData(def.inst_result).call;
        if (d.callee != .@"$simparam") continue;
        const nm = @import("prove").strArg(self.input(), d.args, 0) orelse continue;
        for (names.items) |n| {
            if (std.mem.eql(u8, n, nm)) break;
        } else try names.append(self.arena, nm);
    }
    try self.w(
        \\/// §9.15 the `$simparam` names `setup` reads: after writing one of them
        \\/// (a homotopy rung's gmin, say) the host calls `setup` again.
        \\pub const setup_simparams = [_][]const u8{{
    , .{});
    for (names.items, 0..) |n, k| try self.w("{s}\"{f}\"", .{ if (k == 0) " " else ", ", std.zig.fmtString(n) });
    try self.w("{s}}};\n\n", .{if (names.items.len == 0) "" else " "});
}

/// Emits `pub fn setup`: the invariant slice, through the same plan and
/// relooper as the core, with the roots as its targets. Per-eval branches
/// are taken `then` untested (neither arm is setup work, and the §5.10.2
/// initial-step arm is what setup must compute), and the walk stops at the
/// first loop that is not invariant, since nothing after it is placeable.
/// Asserts the body read no unknown and refused nothing: `prove/setup.zig`
/// admits only solve-invariant, constant-renderable roots.
pub fn emitSetup(self: *Gen) Error!void {
    try emitSetupInstance(self);
    if (self.su.vals.len == 0) return;
    const save_idx = self.plan.lo_idx;
    const save_vals = self.plan.lo_vals;
    self.plan.lo_idx = self.su.idx;
    self.plan.lo_vals = self.su.vals;
    self.plan.su_on = false; // computing the roots, not reading them
    self.plan.setup_mode = true;
    self.plan.sinv = self.sinv.val;
    self.plan.su_home = self.sinv.home;
    self.plan.display_unit = false;
    self.su.mode = true;
    self.emitting_common = true;
    defer {
        self.plan.lo_idx = save_idx;
        self.plan.lo_vals = save_vals;
        self.plan.su_on = true;
        self.plan.setup_mode = false;
        self.su.mode = false;
        self.emitting_common = false;
    }
    try self.plan.analyze(.undef, true);
    try emitSimparams(self);

    self.uses.x = false;
    self.uses.model = true;
    self.uses.inst = false;
    self.fatal = null;
    self.su.chunks = 0;
    const at_doc = self.out.items.len;
    try self.w(
        \\/// Fill `model.su`: once after `derive`, and again after every write to
        \\/// `Model` (its card or `temperature__`) or to a `$simparam` in
        \\/// `setup_simparams` — before `eval` or any other entry point runs.
        \\/// Once per Model row: the instances that share the row share it.
        \\/// `V` is the host's VALUE scalar, with exactly the value semantics of
        \\/// the `S` it evaluates with (its Dual's value half), so every latched
        \\/// value is the bits `eval` would have computed. A §5.10.2
        \\/// `@(initial_step)` body the card alone determines is computed here
        \\/// as if the step were initial: the host evaluates an initial step
        \\/// before any other.
        \\
    , .{});
    try self.w("pub fn setup(comptime V: type, model: *Model) void {{\n", .{});
    try self.w("    @setFloatMode(.strict);\n    const S = V;\n", .{});
    self.float.strict = true;
    self.su.stop = false;
    self.su.dead = false;
    self.su.merge = false;
    defer self.su.merge = false;
    const at_body = self.out.items.len;
    try gen_unit.emitUnitBody(self, .undef);
    try self.w("}}\n\n", .{});
    // A body of integer roots alone never names `S`, and an unused local is
    // a Zig error: then the scalar is discarded instead.
    var at_stop = at_body;
    if (!namesS(self.out.items[at_body..])) {
        const decl = "    const S = V;\n";
        const discard = "    _ = V;\n";
        std.debug.assert(std.mem.eql(u8, self.out.items[at_body - decl.len .. at_body], decl));
        try self.out.replaceRange(self.gpa, at_body - decl.len, decl.len, discard);
        at_stop = at_body - decl.len + discard.len;
    }
    // Declared only when a per-eval branch or loop used it: it is always
    // true, and a runtime value so the arm it guards still compiles.
    if (self.su.stop) try self.out.insertSlice(self.gpa, at_stop, "    var zs_stop = true;\n    _ = &zs_stop;\n");
    // The stores write `model.su`, so `model` is always named. No root reads
    // an instance (`prove/setup.zig` `callInvariant`: a `$held_*` read is
    // per-eval), but a per-eval value the relooper places before a `zs_stop`
    // branch may, for the arm that flag never runs: it reads a default
    // Instance, so the text compiles and nothing stored depends on it.
    if (self.uses.inst) {
        std.debug.assert(self.su.stop);
        try self.out.insertSlice(self.gpa, at_stop, "    const inst: *const Instance = &.{};\n");
    }
    std.debug.assert(!self.uses.x);
    std.debug.assert(self.fatal == null);
    if (self.out.items.len - at_doc < setup_chunk.chunk_bytes) return;
    // A large `setup` becomes chunks a split build compiles in parallel.
    // The split is a text transform whose working copies (several times the
    // body: psp103's 1 MiB `setup` churns ~7 MiB) die once `c.text` is
    // copied into `out`, so they live in an arena of this call, not the
    // compilation's.
    var scratch: std.heap.ArenaAllocator = .init(self.gpa);
    defer scratch.deinit();
    const c = try setup_chunk.chunk(scratch.allocator(), self.out.items[at_doc..], setup_chunk.chunk_bytes) orelse return;
    self.out.shrinkRetainingCapacity(at_doc);
    try self.out.appendSlice(self.gpa, c.text);
    self.su.chunks = c.n;
}

/// Returns whether emitted text uses the identifier `S`.
fn namesS(text: []const u8) bool {
    // Outside string literals and comments: a §3.4.6 string comparison puts
    // the literal "S" in a body that may never name the scalar.
    return setup_chunk.hasWord(text, "S");
}

/// Emits `emitReturn` inside `setup`: stores every root from wherever the
/// body holds it, then leaves, unconditionally at an exit block or on the
/// runtime `zs_stop` flag at a per-eval loop (`emitTree`). In dead text
/// (`dead`) only the leaving remains.
pub fn emitStores(self: *Gen, depth: u32, stop: []const u8) Error!void {
    if (self.su.dead) {
        try self.ind(depth);
        return self.b("{s}return;\n", .{stop});
    }
    self.su.exits += 1;
    if (self.su.merge) {
        try self.ind(depth);
        return self.b("{s}break :zs_done;\n", .{stop});
    }
    const at = self.out.items.len;
    defer self.su.store_bytes += self.out.items.len - at;
    for (self.su.vals) |v| {
        const k = self.su.idx[@backingInt(v)];
        try self.ind(depth);
        if (rootGroup(self, v) == 2) {
            try self.b("model.su.b.setValue({d}, (", .{k});
            try gen_render.renderVal(self, v, .int);
            try self.b(") != 0);\n", .{});
        } else if (self.an.vty[@backingInt(v)] == .int) {
            try self.b("model.su.i[{d}] = ", .{k});
            try gen_render.renderVal(self, v, .int);
            try self.b(";\n", .{});
        } else {
            try self.b("model.su.r[{d}] = (", .{k});
            try gen_render.renderVal(self, v, .real);
            try self.b(").val();\n", .{});
        }
    }
    try self.ind(depth);
    try self.b("if (std.debug.runtime_safety and contract.validating) model.su_ok = true;\n", .{});
    try self.ind(depth);
    try self.b("{s}return;\n", .{stop});
}

/// Returns whether merging the exits would shrink `setup`, judged after a
/// probe without `merge`: one copy of the stores stays, and every body line
/// gains four spaces.
pub fn mergePays(self: *const Gen) bool {
    const su = self.su;
    return su.mode and su.exits > 1 and su.store_bytes - su.store_bytes / su.exits > 4 * su.lines;
}

/// Emits the unit body's root tree. Under `merge`, `setup`'s exits leave one
/// labelled block and the roots are stored once after it; a root read there
/// that was defined in an inner scope is hoisted like any other slot read
/// outside its block (`probeBody`), so every exit stores the same bits.
pub fn emitRoot(self: *Gen, target: Mir.Value) Error!void {
    if (!self.su.merge) return gen_cfg.emitTree(self, 0, 1, target);
    try self.ind(1);
    try self.b("zs_done: {{\n", .{});
    try gen_unit.scopeOpen(self);
    try gen_cfg.emitTree(self, 0, 2, target);
    gen_unit.scopeClose(self, self.out.items.len);
    try self.ind(1);
    try self.b("}}\n", .{});
    self.su.merge = false;
    defer self.su.merge = true;
    try emitStores(self, 1, "");
}

test namesS {
    try std.testing.expect(namesS("    const S = V;\n"));
    try std.testing.expect(namesS("zOf(S, 0x0)"));
    try std.testing.expect(!namesS("model.su.b[0] = (x) != 0;"));
    try std.testing.expect(!namesS("SS_S S2"));
    // A literal or a comment is text, not a use: `const S = V;` beside a
    // body that only spells "S" would be an unused local.
    try std.testing.expect(!namesS("zStrCmp(model.mode, \"S\")"));
    try std.testing.expect(!namesS("// S\n"));
}
