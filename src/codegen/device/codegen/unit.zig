//! A unit and its backward slice of the MIR -> one stably named Zig function
//! with its own @setFloatMode (proof.zig's verdict), including the shared core
//! every residual reads. Also decides where each slot is declared.
//! LRM: §1.3.1.1, §2.9, §3.2.2, §3.6.2.2, §4.5, §4.5.11, §4.5.12, §4.6.3, §4.6.4,
//! §5.6.1.3, §5.10, §9.4.
//!
//! Contents:
//! - `pub const Uses = struct`
//! - `pub const SimReads = struct`
//! - `pub fn scanSimReads(self: *const Gen, start: usize) SimReads`
//! - `pub fn filterSec(self: *const Gen, i: usize) ?OpKind`
//! - `pub fn emitUnits(self: *Gen) Error!void`
//! - `pub fn emitSlice(self: *Gen, name: []const u8, vals: []Mir.Value, idx: []u32, doc: []const u8) Error!void`
//! - `pub fn sliceCore(self: *Gen, suffix: []const u8, keep: []const bool, doc: []const u8) Error!plan_core.Core`
//! - `pub fn unitOfInst(self: *const Gen, inst: Mir.Inst) u32`
//! - `pub fn opInputIdx(self: *const Gen, i: u32) u32`
//! - `pub fn patchParam(self: *Gen, at: usize, comptime width: usize) void`
//! - `pub fn patchUnless(self: *Gen, at: usize, from: usize, comptime ident: []const u8) void`

const std = @import("std");
const assert = std.debug.assert;
const plan_core = @import("plan/core.zig");
const plan_jobs = @import("plan/jobs.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_noise = @import("noise.zig");
const gen_opvars = @import("opvars.zig");
const gen_file = @import("file.zig");
const gen_instance = @import("instance.zig");
const gen_status = @import("status.zig");
const gen_state = @import("state.zig");
const render_array = @import("render_array.zig");
const family = @import("family.zig");
const Mir = @import("ir").Mir;
const proof = @import("prove").proof;
const cg_filters = @import("../cg_filters.zig");
const cg_limit = @import("../cg_limit.zig");
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const OpKind = @import("ir").op.OpKind;
const gen_unit_body = @import("unit_body.zig");

/// Which of a unit's uniform parameters its body read (`Gen.uses`). Zig
/// rejects an unused parameter, so the signature must say `_`; `closeSig`
/// back-patches each one left false. Every renderer that spells a parameter
/// sets its flag; a declaration resets them all before its body.
pub const Uses = struct {
    x: bool = false,
    model: bool = false,
    inst: bool = false,
    /// The body read the host's `contract.SimState` (§4.6.1, §5.10.2, §9.10).
    sim: bool = false,
    /// The core read its `held` flag (`plan_core.heldOnly`): a skippable
    /// store was emitted. Patched to `_` otherwise, like the flags above.
    /// Read only by `emitCoreDecl`.
    held: bool = false,
    /// A `.record` display unit wrote a record into its `out`
    /// (`contract.Say`, `cg_display.emitSay`).
    out: bool = false,
    /// A printing display unit gated a call on its `pass`
    /// (`contract.SayPass`, `Gen.passes`).
    pass: bool = false,
};

/// Which `SimState` fields a core reads (`contract.SimReads`, written out
/// by `file.emitFile`).
pub const SimReads = struct { t: bool = false, dt: bool = false, iteration: bool = false };

const core_doc =
    \\/// The whole model, evaluated ONCE per residual: the {d} source units
    \\/// share one CFG, so they share one declaration and `eval`/`q` read
    \\/// their targets out of the returned struct.
    \\
    \\/// Inlined at every host-scalar site (`@call(.always_inline, ...)` in
    \\/// `eval`/`q`/`evalQ`), which destructure the returned struct at
    \\/// once: behind a call boundary the unknowns argument and the
    \\/// {d}-field result both go to memory, the host's Dual derivative
    \\/// vectors spill instead of staying in registers, and no live-out the
    \\/// caller drops can be dead-coded. Measured on ARPice
    \\/// devices/mos6_inverter: 45.3 ms inline vs 64.9 ms out-of-line
    \\/// (+43%), tran/fourbitadder +40%, scaling/parallel_inverters_500
    \\/// +51%. NOT `inline fn`, so the value-only `core(S, zVals(...))`
    \\/// sites — collapse, seed — share ONE
    \\/// out-of-line instantiation per family instead of each inlining the
    \\/// model.
    \\
;

/// Offsets of a unit signature's four uniform parameter names, of a
/// `.record` display unit's `out` and of a printing display unit's `pass`
/// (0 for any other unit).
const Slots = struct { x: usize, model: usize, inst: usize, sim: usize, out: usize = 0, pass: usize = 0 };

/// Returns which `SimState` fields the text `out[start..]` reads: `sim.t`
/// and `sim.dt` outside every `Gen.init_arms` range, `sim.iteration`
/// anywhere, and every field when `sim` is passed whole. A text scan, so
/// every renderer that spells a read is covered; a mention in a comment only
/// over-reports.
pub fn scanSimReads(self: *const Gen, start: usize) SimReads {
    assert(start > 0); // A body follows its signature, so `text[k - 1]` exists.
    assert(start <= self.out.items.len);
    const text = self.out.items;
    const ident = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_' or c == '@';
        }
    }.f;
    var r: SimReads = .{};
    var i = start;
    // Each match moves `i` forward by at least "sim".len.
    var iterations: usize = 0;
    while (std.mem.findPos(u8, text, i, "sim")) |k| : (iterations += 1) {
        assert(iterations <= text.len / "sim".len);
        i = k + "sim".len;
        if (ident(text[k - 1]) or (i < text.len and ident(text[i]))) continue;
        if (i == text.len or text[i] != '.') return .{ .t = true, .dt = true, .iteration = true };
        var e = i + 1;
        while (e < text.len and ident(text[e])) e += 1;
        assert(e <= text.len);
        const field = text[i + 1 .. e];
        const guarded = for (self.cur.init_arms.items) |a| {
            if (a[0] <= k and k < a[1]) break true;
        } else false;
        if (std.mem.eql(u8, field, "iteration")) r.iteration = true;
        if (std.mem.eql(u8, field, "t") and !guarded) r.t = true;
        if (std.mem.eql(u8, field, "dt") and !guarded) r.dt = true;
    }
    return r;
}

/// Returns the operator kind of unit `i` when it emits a `<unit>__sec`
/// coefficient reader: a planned `laplace`/`zi` call with no refusal.
pub fn filterSec(self: *const Gen, i: usize) ?OpKind {
    assert(i < self.names.units.len);
    assert(self.filters.len == self.names.units.len);
    const u = self.names.units[i];
    if (u.role != .analog_op or (u.op != .laplace and u.op != .zi)) return null;
    if (self.names.opInstOf(@intCast(i)) == null) return null;
    if (self.filters[i].?.err != null) return null;
    return u.op;
}

/// Emits the filter coefficient readers ahead of every unit declaration,
/// then the units (the shared core and each job's unit), recording each
/// unit's range in `Output`.
pub fn emitUnits(self: *Gen) Error!void {
    assert(!self.cur.emitting_common);
    assert(!self.cur.emitting_display);
    try self.w("// ---- the model, in one declaration ----\n\n", .{});
    // §4.5.11/§4.5.12 the coefficient reader is named from the operator's
    // unit (`<unit>__sec`), not a Unit of its own, so the ordering in
    // `ir/names.zig`/proof.zig is untouched. It reads `Model` alone, so it is
    // not part of the residual slice. It stays in device.zig's prologue,
    // ahead of the first recorded unit, and a unit file reads it through the
    // prelude's `dev.<unit>__sec` alias (`file.buildPrelude`): as a unit file of its
    // own, the prelude alias every other unit needs would redeclare it there.
    for (self.names.units, 0..) |_, i| {
        const k = filterSec(self, i) orelse continue;
        _ = try cg_filters.emitFilterSections(self, self.names.unit_names[i], cg_filters.planOf(self, i), k == .zi);
    }
    // The §9.4 display unit calls the core as `core`, so one spelling works
    // in the single-file form (this alias) and the split form (the alias in
    // `Output.prelude`). It sits ahead of the first recorded unit range, so
    // the ranges still tile.
    if (self.core.name.len != 0) try self.w("const core = {s};\n\n", .{self.core.name});
    try emitCommon(self);
    try cg_limit.emitCore(self);
    try gen_state.emitCore(self);
    try gen_state.emitIterCore(self);
    try gen_noise.emitNoiseCore(self);
    try gen_opvars.emitOpVarCore(self);
    for (self.jobs.list) |job| {
        if (job.kind != .display) continue;
        // §9.5 the one unit where a descriptor operation may actually happen.
        self.cur.emitting_display = true;
        defer self.cur.emitting_display = false;
        const lo = self.out.items.len;
        const at = try emitUnit(self, self.jobs.display_name, job.target, job.mode, plan_jobs.display_comment);
        try gen_file.recordUnitFile(self, self.jobs.display_name, lo, at);
    }
    assert(!self.cur.emitting_display);
}

/// Emits declaration `name`, the core's slice returning only `vals` (`idx`
/// maps each value to its field), under doc comment `doc`. Same MIR and
/// float mode as the core, so every field is bit-identical to the core's.
/// For a value-only caller: its reals are no `lane_masks` data.
pub fn emitSlice(self: *Gen, name: []const u8, vals: []Mir.Value, idx: []u32, doc: []const u8) Error!void {
    assert(vals.len <= self.core.lo_vals.len);
    assert(idx.len == self.an.nv);
    const saved = .{ self.core.lo_vals, self.cur.plan.lo_idx, self.cur.plan.lo_vals };
    defer {
        self.core.lo_vals = saved[0];
        self.cur.plan.lo_idx = saved[1];
        self.cur.plan.lo_vals = saved[2];
    }
    self.core.lo_vals = vals;
    self.cur.plan.lo_idx = idx;
    self.cur.plan.lo_vals = vals;
    const n_masks = self.fam_masks.items.len;
    defer self.fam_masks.shrinkRetainingCapacity(n_masks);
    try emitCoreDecl(self, name, doc);
    assert(self.fam_masks.items.len >= n_masks);
}

/// Emits `<core>__<suffix>`, the slice returning the core fields `keep`
/// marks, in core order, and returns the core as that slice's caller reads
/// it: `name` the slice, and `lo_idx`, `lo_vals`, `prev_lo`, `acc_lo` and
/// `held_idx` renumbered onto its fields (`none_u32` where it has none).
/// Swapped into `Gen.core` while the caller's body is written, every
/// `m.f<k>` that body renders names the slice's field.
pub fn sliceCore(self: *Gen, suffix: []const u8, keep: []const bool, doc: []const u8) Error!plan_core.Core {
    assert(keep.len == self.core.lo_vals.len);
    assert(suffix.len != 0);
    const full = self.core;
    const idx = try self.arena.alloc(u32, self.an.nv);
    @memset(idx, none_u32);
    const remap = try self.arena.alloc(u32, full.lo_vals.len);
    @memset(remap, none_u32);
    var vals: std.ArrayList(Mir.Value) = try .initCapacity(self.arena, std.mem.countScalar(bool, keep, true));
    for (full.lo_vals, keep, 0..) |v, kept, k| {
        if (!kept) continue;
        remap[k] = @intCast(vals.items.len);
        idx[@backingInt(v)] = remap[k];
        vals.appendAssumeCapacity(v);
    }
    var sc = full;
    sc.name = try self.arena.print("{s}__{s}", .{ full.name, suffix });
    sc.lo_idx = idx;
    sc.lo_vals = vals.items;
    sc.prev_lo = try remapAll(self, full.prev_lo, remap);
    sc.acc_lo = try remapAll(self, full.acc_lo, remap);
    sc.held_idx = try remapAll(self, full.held_idx, remap);
    // `sc.held_only` stays the core's: an unread `held` is renamed `_`, not
    // dropped, so every caller still passes `heldArg`.
    assert(sc.lo_vals.len == std.mem.countScalar(bool, keep, true));
    try emitSlice(self, sc.name, vals.items, idx, doc);
    return sc;
}

/// Returns the unit enumerated from operator call `inst`, or `none_u32`.
// ponytail: a linear scan over the unit list (tens of entries) per rendered
// operator; an nv-sized reverse map if unit counts grow.
pub fn unitOfInst(self: *const Gen, inst: Mir.Inst) u32 {
    assert(self.mir.instOp(inst) == .call);
    for (self.names.units, 0..) |u, i| {
        if (u.inst == inst) return @intCast(i);
    }
    return none_u32;
}

/// Returns which core field holds analog-operator unit `i`'s §4.5 input, or
/// `none_u32` for an operator called with no argument (its input is the
/// literal zero and never reaches the core).
pub fn opInputIdx(self: *const Gen, i: u32) u32 {
    assert(i < self.names.units.len);
    assert(self.names.units[i].role == .analog_op);
    const args = self.names.opArgs(self.mir, i);
    if (args.len == 0) return none_u32;
    const k = self.core.lo_idx[@backingInt(self.an.rv(args[0]))];
    if (k != none_u32) assert(k < self.core.lo_vals.len);
    return k;
}

/// Overwrites a reserved parameter-name slot with `_`, space-padded to the
/// name's width so the bytes after it do not move.
pub fn patchParam(self: *Gen, at: usize, comptime width: usize) void {
    assert(at + width <= self.out.items.len);
    assert(width > 0);
    self.out.items[at..][0..width].* = ("_" ++ @as([width - 1]u8, @splat(' '))).*;
    assert(self.out.items[at] == '_');
}

/// Calls `patchParam` on the slot at `at` unless the body text from `from`
/// names `ident` as a whole identifier. Only valid for a body with no string
/// literal in it.
pub fn patchUnless(self: *Gen, at: usize, from: usize, comptime ident: []const u8) void {
    assert(at < from);
    assert(from <= self.out.items.len);
    var it = std.mem.findPos(u8, self.out.items, from, ident);
    while (it) |i| : (it = std.mem.findPos(u8, self.out.items, i + 1, ident)) {
        const t = self.out.items;
        // Not a field (`m.sim`), not part of a longer name.
        const before = i == 0 or !(isIdent(t[i - 1]) or t[i - 1] == '.');
        const after = i + ident.len >= t.len or !isIdent(t[i + ident.len]);
        if (before and after) return;
    }
    patchParam(self, at, ident.len);
}

// ---- private ----

/// Emits the shared core: one declaration computing every live-out and
/// returning them as a struct (plan/core.zig says why). The return type is an
/// anonymous struct in the signature, because a named type would have to be
/// public for unit files to reach it, which `contract.validate` rejects.
fn emitCommon(self: *Gen) Error!void {
    assert(!self.cur.emitting_common);
    if (self.core.lo_vals.len == 0) return;
    const n = self.jobs.list.len;
    try emitCoreDecl(self, self.core.name, try self.arena.print(core_doc, .{ n, n }));
}

fn remapAll(self: *Gen, fields: []const u32, remap: []const u32) Error![]u32 {
    assert(remap.len == self.core.lo_vals.len);
    const out = try self.arena.alloc(u32, fields.len);
    for (out, fields) |*o, k| o.* = if (k == none_u32) none_u32 else remap[k];
    assert(out.len == fields.len);
    return out;
}

/// Emits declaration `name` computing `self.core.lo_vals` and returning them
/// as a struct: the shared core, or a caller's slice of it with `core.lo_vals`
/// and `plan.lo_idx`/`lo_vals` swapped (`emitSlice`), under doc comment `doc`.
fn emitCoreDecl(self: *Gen, name: []const u8, doc: []const u8) Error!void {
    assert(name.len != 0);
    assert(!self.cur.emitting_common);
    self.cur.emitting_common = true;
    defer self.cur.emitting_common = false;

    self.cur.uses = .{};
    self.cur.fatal = null;
    self.cur.plan.display_unit = self.cur.emitting_display;
    try self.cur.plan.analyze(.undef, self.cur.emitting_common); // `emitting_common` ⇒ the live-outs are the targets

    const lo = self.out.items.len;
    try self.w("{s}", .{doc});
    const at_fn = self.out.items.len;
    const slots = try openSig(self, name);
    // §5.10 whether the caller keeps the held arrays' end-of-block values
    // (`Gen.heldArg`); `uses.held` says whether the body read it.
    const at_held = self.out.items.len + ", comptime ".len;
    if (self.core.held_only.len != 0) try self.w(", comptime held: bool", .{});
    try self.w(") struct {{\n", .{});
    for (self.core.lo_vals, 0..) |v, k| {
        // §3.2.2 a held array's end-of-block version: its plain values,
        // unless the slice already stored them in place.
        if (self.an.arrOf(v)) |id| {
            if (render_array.inPlace(self, id)) continue;
            const m = self.lowered.mem_arrays.items[id];
            try self.w("    f{d}: [{d}]{s},\n", .{ k, m.len, if (m.ty == .integer) "i64" else "f64" });
        } else if (self.an.vty[@backingInt(v)] == .real) {
            try family.note(self, family.mask(self, v));
            try self.w("    f{d}: {s},\n", .{ k, try family.ofText(self, family.mask(self, v)) });
        } else try self.w("    f{d}: {s},\n", .{ k, try gen_unit_body.slotTy(self, @backingInt(v)) });
    }
    try self.w("}} {{\n", .{});
    // §4.3: the strictest mode of every consumer (`proof.FloatMode.strictest`
    // explains why the join absorbs `.strict`).
    try self.w("    @setFloatMode(.{t});\n", .{self.core.mode});
    self.float.strict = self.core.mode == .strict;

    const body_start = self.out.items.len;
    // `Setup` defaults its reals to NaN, which a missed `setup` call turns
    // into a NaN residual; the integers have no NaN, so Debug asserts it.
    if (self.su.vals.len != 0) {
        self.cur.uses.model = true;
        try self.w("    if (std.debug.runtime_safety and contract.validating) std.debug.assert(model.su_ok);\n", .{});
    }
    self.cur.fatal = null;
    self.cur.init_arms.clearRetainingCapacity();
    try gen_unit_body.emitUnitBody(self, .undef);
    if (std.mem.eql(u8, name, self.core.name)) self.sim_reads = scanSimReads(self, body_start);
    try tableReset(self, body_start);
    try closeSig(self, slots, body_start);
    if (self.core.held_only.len != 0 and !self.cur.uses.held) patchParam(self, at_held, "held".len);
    // A slice of integers and plain arrays alone never names `S`.
    if (!try namesIdent(self, slots.x, "S")) patchParam(self, slots.x - "S: type, ".len, "S".len);
    try self.w("}}\n\n", .{});
    assert(std.mem.endsWith(u8, self.out.items, "}\n\n"));
    try gen_file.recordUnitFile(self, name, lo, at_fn);
}

/// Emits one source-unit function (LRM §5.6, §4.7, §5.3). The signature is
/// uniform, so `zig` re-analyses exactly the units whose bodies changed.
/// Parameters the body never reads are back-patched to `_`, padded to the
/// name's width, in fixed slots reserved before the body is rendered.
///
/// Returns the offset of the `fn` keyword, where `zigbuild.writeTree`
/// splices `pub ` for the split form. `text` itself stays private because
/// `contract.rejectStrayPubDecls` allows only contract-recognized public names.
fn emitUnit(self: *Gen, name: []const u8, target: Mir.Value, mode: proof.FloatMode, comment: []const u8) Error!usize {
    assert(name.len != 0);
    assert(!self.cur.emitting_common);
    self.cur.uses = .{};
    self.cur.fatal = null;
    self.cur.plan.display_unit = self.cur.emitting_display;
    try self.cur.plan.analyze(target, self.cur.emitting_common);

    try self.w("/// {s}\n", .{comment});
    const at_fn = self.out.items.len;
    const slots = try openSig(self, name);
    try self.w(") {s} {{\n", .{try family.ofText(self, family.mask(self, target))});
    try self.w("    @setFloatMode(.{t});\n", .{mode});
    self.float.strict = mode == .strict;

    const body_start = self.out.items.len;
    try gen_unit_body.emitUnitBody(self, target);
    try tableReset(self, body_start);
    try closeSig(self, slots, body_start);
    try self.w("}}\n\n", .{});
    assert(at_fn < self.out.items.len);
    assert(std.mem.endsWith(u8, self.out.items, "}\n\n"));
    return at_fn;
}

/// §9.21.1 + §9.3 (VD-095): a body that calls `$table_model` on a captured
/// data source starts from the captures an accepted point kept
/// (`Instance.table_kept`). A first call it makes then fixes the data for
/// every later call of that site in this evaluation only: an evaluation the
/// host discards must leave no capture behind for the next one.
fn tableReset(self: *Gen, body_start: usize) Error!void {
    assert(body_start <= self.out.items.len);
    if (self.lowered.table_samples.items.len == 0) return;
    if (std.mem.findPos(u8, self.out.items, body_start, "inst.table_ready[") == null) return;
    try self.out.insertSlice(self.gpa, body_start, "    inst.table_ready = inst.table_kept;\n");
}

/// Writes `fn <name>(comptime S: type, x, model, inst, sim` up to the closing
/// parenthesis, reserving each parameter's slot for `closeSig`.
fn openSig(self: *Gen, name: []const u8) Error!Slots {
    assert(name.len != 0);
    try self.w("fn {s}(comptime S: type, ", .{name});
    const x = self.out.items.len;
    // A body's unknowns: a tuple, each unknown typed by the lanes it carries.
    try self.w("x: anytype, ", .{});
    const model = self.out.items.len;
    try self.w("model: *const Model, ", .{});
    const inst = self.out.items.len;
    // Of the three things that make a device `mutable_eval`, only §9.21.1
    // table samples are written BY the core: a `vera_timepoint` cache and the
    // §9.7.3 status latch are written by `eval` around it. So without tables a
    // `*const` serves every caller, the `*const Instance` entries the contract
    // fixes (`noisePsd`, `acStim`, `limit`, `seed`, `collapse`,
    // `checkConvergence`) included. An in-place held array
    // (`plan.Core.in_place`) is stored through it.
    // Spelled `InstancePtr` where that already is `*const Instance` (a device
    // that is not `mutable_eval`), so those devices' text is unchanged.
    // A `vera_timepoint` array cached in place (`instance.tpInPlace`) is
    // the exception: `anytype`, so `eval`'s mutable `Instance` reaches the
    // statement's stores and every `*const` caller keeps the local copy.
    const eval_writes = self.lowered.timepoints.items.len != 0 or gen_status.hasStatus(self);
    const inst_ty = if (self.core.in_place.len != 0)
        "*Instance"
    else if (self.lowered.table_samples.items.len == 0 and eval_writes)
        (if (self.tp_of_block.len != 0) "anytype" else "*const Instance")
    else
        "InstancePtr";
    try self.w("inst: {s}, ", .{inst_ty});
    const sim = self.out.items.len;
    try self.w("sim: contract.SimState", .{});
    // §9.4.1/§9.5.9 a printing display unit with a per-iteration task runs
    // once per pass (`Gen.passes`).
    if (self.cur.emitting_display and self.display == .emit and self.passes) {
        try self.w(", comptime ", .{});
        const pass = self.out.items.len;
        try self.w("pass: contract.SayPass", .{});
        return .{ .x = x, .model = model, .inst = inst, .sim = sim, .pass = pass };
    }
    // §9.4 a device's display unit records into the host's buffer (`say`).
    if (!self.cur.emitting_display or self.display != .record) return .{ .x = x, .model = model, .inst = inst, .sim = sim };
    try self.w(", ", .{});
    const out = self.out.items.len;
    try self.w("out: *contract.Say", .{});
    return .{ .x = x, .model = model, .inst = inst, .sim = sim, .out = out };
}

/// Replaces a refused body (from `body_start`) with its `@compileError`, then
/// back-patches every parameter the body never read to `_`.
fn closeSig(self: *Gen, s: Slots, body_start: usize) Error!void {
    assert(s.x < s.model);
    assert(s.model < s.inst);
    assert(s.inst < s.sim);
    assert(body_start > s.sim);
    if (self.cur.fatal) |msg| {
        self.any_fatal = true;
        self.out.shrinkRetainingCapacity(body_start);
        self.cur.uses = .{};
        try self.b("    @compileError(\"{s}\");\n", .{msg});
    }
    if (!self.cur.uses.x) patchParam(self, s.x, "x".len);
    if (!self.cur.uses.model) patchParam(self, s.model, "model".len);
    if (!self.cur.uses.inst) patchParam(self, s.inst, "inst".len);
    if (!self.cur.uses.sim) patchParam(self, s.sim, "sim".len);
    if (s.out != 0 and !self.cur.uses.out) patchParam(self, s.out, "out".len);
    if (s.pass != 0 and !self.cur.uses.pass) patchParam(self, s.pass, "pass".len);
}

/// Returns whether the Zig source written from output offset `from` names
/// `ident` as an identifier token, outside any string literal or comment.
/// Tokenizes `out` in place behind a sentinel it appends and pops again, so a
/// body (hundreds of KiB for a large core) is never copied.
fn namesIdent(self: *Gen, from: usize, ident: []const u8) Error!bool {
    assert(ident.len != 0);
    assert(from <= self.out.items.len);
    try self.out.append(self.gpa, 0);
    defer _ = self.out.pop();
    const src = self.out.items[from .. self.out.items.len - 1 :0];
    var t: std.zig.Tokenizer = .init(src);
    while (true) {
        const tok = t.next();
        if (tok.tag == .eof) return false;
        if (tok.tag == .identifier and std.mem.eql(u8, src[tok.loc.start..tok.loc.end], ident)) return true;
    }
}

fn isIdent(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

test scanSimReads {
    const Harness = @import("harness.zig").Harness;
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const Case = struct { body: []const u8, want: []const u8 };
    for ([_]Case{
        // The MOS levels' first-iterate test: `$abstime` inside the event.
        .{ .body = "g = 1.0; @(initial_step(\"tran\")) begin if ($abstime > 0.0 && $simparam(\"iteration\") == 1) g = 2.0; end", .want = ".{ .t = false, .dt = false, .iteration = true }" },
        .{ .body = "g = $abstime;", .want = ".{ .t = true, .dt = false, .iteration = false }" },
        .{ .body = "g = $simparam(\"dt\");", .want = ".{ .t = false, .dt = true, .iteration = false }" },
        .{ .body = "g = 1.0;", .want = ".{ .t = false, .dt = false, .iteration = false }" },
    }) |c| {
        const src = try a.print(
            \\module t(p, n);
            \\  inout p, n;
            \\  electrical p, n;
            \\  real g;
            \\  analog begin
            \\    {s}
            \\    I(p, n) <+ g * V(p, n);
            \\  end
            \\endmodule
            \\
        , .{c.body});
        var h: Harness = undefined;
        try Harness.run(a, src, &h);
        const out = try h.gen(a);
        const want = try a.print("pub const sim_reads: contract.SimReads = {s};", .{c.want});
        if (std.mem.find(u8, out, want) == null) {
            std.debug.print("{s}\nwant: {s}\n", .{ c.body, want });
            return error.TestUnexpectedResult;
        }
    }
}
