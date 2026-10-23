//! A unit and its backward slice of the MIR -> one stably named Zig function
//! with its own @setFloatMode (proof.zig's verdict), including the shared core
//! every residual reads. Also decides where each slot is declared.
//! LRM: §1.3.1.1, §2.9, §3.2.2, §3.6.2.2, §4.5, §4.5.11, §4.5.12, §4.6.3, §4.6.4,
//! §5.6.1.3, §5.10, §9.4.

const std = @import("std");
const plan_core = @import("plan/core.zig");
const plan_jobs = @import("plan/jobs.zig");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_noise = @import("noise.zig");
const gen_file = @import("file.zig");
const gen_instance = @import("instance.zig");
const gen_cfg = @import("cfg.zig");
const gen_setup = @import("setup.zig");
const gen_state = @import("state.zig");
const gen_render = @import("render.zig");
const gen_wide = @import("wide.zig");
const family = @import("family.zig");
const gen_mask = @import("mask.zig");
const Mir = @import("ir").Mir;
const proof = @import("prove").proof;
const cg_filters = @import("../cg_filters.zig");
const cg_limit = @import("../cg_limit.zig");
const Error = codegen.Error;
const none_u32 = codegen.none_u32;
const VTy = codegen.VTy;
const OpKind = @import("ir").op.OpKind;

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

/// Returns which `SimState` fields the text `out[start..]` reads: `sim.t`
/// and `sim.dt` outside every `Gen.init_arms` range, `sim.iteration`
/// anywhere, and every field when `sim` is passed whole. A text scan, so
/// every renderer that spells a read is covered; a mention in a comment only
/// over-reports.
pub fn scanSimReads(self: *const Gen, start: usize) SimReads {
    const text = self.out.items;
    const ident = struct {
        fn f(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c == '_' or c == '@';
        }
    }.f;
    var r: SimReads = .{};
    var i = start;
    while (std.mem.findPos(u8, text, i, "sim")) |k| {
        i = k + "sim".len;
        if (ident(text[k - 1]) or (i < text.len and ident(text[i]))) continue;
        if (i == text.len or text[i] != '.') return .{ .t = true, .dt = true, .iteration = true };
        var e = i + 1;
        while (e < text.len and ident(text[e])) e += 1;
        const field = text[i + 1 .. e];
        const guarded = for (self.init_arms.items) |a| {
            if (a[0] <= k and k < a[1]) break true;
        } else false;
        if (std.mem.eql(u8, field, "iteration")) r.iteration = true;
        if (std.mem.eql(u8, field, "t") and !guarded) r.t = true;
        if (std.mem.eql(u8, field, "dt") and !guarded) r.dt = true;
    }
    return r;
}

/// The dry run `probeBody` makes of a body, and what it learned (`Gen.probe`).
/// Arena lists, cleared per run.
pub const Probe = struct {
    /// Set for the duration of the dry run; every recorder below is a no-op
    /// otherwise.
    active: bool = false,
    /// Where each slot's declaration goes, by slot. Meaningful only on the
    /// out-of-SSA path (`straight` declares everything at its definition).
    place: std.ArrayList(Place) = .empty,
    /// Emitted lexical scopes, as half-open output offsets: `sc_end` their
    /// closing offset once written, and `sc_open` the stack of indices into
    /// `sc_end` still being written.
    sc_end: std.ArrayList(u32) = .empty,
    sc_open: std.ArrayList(u32) = .empty,
};

/// The out-of-SSA slots that survived `probeBody` as hoisted function-scope
/// arrays (`Gen.hoist`): one array per real mask (`h<g>`) plus `hi`/`hs`,
/// rather than one `var tN` apiece. Arena lists, rebuilt per body by
/// `emitUnitBody`.
pub const Hoist = struct {
    /// Per slot: its index inside its type's hoist array, or `none_u32` for a
    /// slot that keeps its own name. All-`none_u32` while probing, so the dry
    /// run names every slot `tN`; `probeBody` only compares offsets within
    /// its own text.
    idx: std.ArrayList(u32) = .empty,
    // Per real hoist element (indexed by `idx`): its mask, and where it
    // lives, array `h<grp>` at `[pos]`.
    mask: std.ArrayList([]u64) = .empty,
    grp: std.ArrayList(u32) = .empty,
    pos: std.ArrayList(u32) = .empty,
    // Per array `h<g>`: it holds every element of mask `gmask[g]` (distinct,
    // in first-use order) and is `glen[g]` long.
    gmask: std.ArrayList([]const u64) = .empty,
    glen: std.ArrayList(u32) = .empty,
};

// =======================================================================
// Units
// =======================================================================

/// Returns the operator kind of unit `i` when it emits a `<unit>__sec`
/// coefficient reader: a planned `laplace`/`zi` call with no refusal.
pub fn filterSec(self: *const Gen, i: usize) ?OpKind {
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
    for (self.jobs.list) |job| {
        if (job.kind != .display) continue;
        // §9.5 the one unit where a descriptor operation may actually happen.
        self.emitting_display = true;
        defer self.emitting_display = false;
        const lo = self.out.items.len;
        const at = try emitUnit(self, self.jobs.display_name, job.target, job.mode, plan_jobs.display_comment);
        try gen_file.recordUnitFile(self, self.jobs.display_name, lo, at);
    }
}

/// Emits the shared core: one declaration computing every live-out and
/// returning them as a struct (plan/core.zig says why). The return type is an
/// anonymous struct in the signature, because a named type would have to be
/// public for unit files to reach it, which `contract.validate` rejects.
fn emitCommon(self: *Gen) Error!void {
    if (self.core.lo_vals.len == 0) return;
    const n = self.jobs.list.len;
    try emitCoreDecl(self, self.core.name, try self.arena.print(core_doc, .{ n, n }));
}

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

/// Emits declaration `name`, the core's slice returning only `vals` (`idx`
/// maps each value to its field), under doc comment `doc`. Same MIR and
/// float mode as the core, so every field is bit-identical to the core's.
/// For a value-only caller: its reals are no `lane_masks` data.
pub fn emitSlice(self: *Gen, name: []const u8, vals: []Mir.Value, idx: []u32, doc: []const u8) Error!void {
    const saved = .{ self.core.lo_vals, self.plan.lo_idx, self.plan.lo_vals };
    defer {
        self.core.lo_vals = saved[0];
        self.plan.lo_idx = saved[1];
        self.plan.lo_vals = saved[2];
    }
    self.core.lo_vals = vals;
    self.plan.lo_idx = idx;
    self.plan.lo_vals = vals;
    const n_masks = self.fam_masks.items.len;
    defer self.fam_masks.shrinkRetainingCapacity(n_masks);
    try emitCoreDecl(self, name, doc);
}

/// Emits `<core>__<suffix>`, the slice returning the core fields `keep`
/// marks, in core order, and returns the core as that slice's caller reads
/// it: `name` the slice, and `lo_idx`, `lo_vals`, `prev_lo`, `acc_lo` and
/// `held_idx` renumbered onto its fields (`none_u32` where it has none).
/// Swapped into `Gen.core` while the caller's body is written, every
/// `m.f<k>` that body renders names the slice's field.
pub fn sliceCore(self: *Gen, suffix: []const u8, keep: []const bool, doc: []const u8) Error!plan_core.Core {
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
    try emitSlice(self, sc.name, vals.items, idx, doc);
    return sc;
}

fn remapAll(self: *Gen, fields: []const u32, remap: []const u32) Error![]u32 {
    const out = try self.arena.alloc(u32, fields.len);
    for (out, fields) |*o, k| o.* = if (k == none_u32) none_u32 else remap[k];
    return out;
}

/// Emits declaration `name` computing `self.core.lo_vals` and returning them
/// as a struct: the shared core, or a caller's slice of it with `core.lo_vals`
/// and `plan.lo_idx`/`lo_vals` swapped (`emitSlice`), under doc comment `doc`.
fn emitCoreDecl(self: *Gen, name: []const u8, doc: []const u8) Error!void {
    self.emitting_common = true;
    defer self.emitting_common = false;

    self.uses = .{};
    self.fatal = null;
    self.plan.display_unit = self.emitting_display;
    try self.plan.analyze(.undef, self.emitting_common); // `emitting_common` ⇒ the live-outs are the targets

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
            if (gen_render.inPlace(self, id)) continue;
            const m = self.lowered.mem_arrays.items[id];
            try self.w("    f{d}: [{d}]{s},\n", .{ k, m.len, if (m.ty == .integer) "i64" else "f64" });
        } else if (self.an.vty[@backingInt(v)] == .real) {
            try family.note(self, family.mask(self, v));
            try self.w("    f{d}: {s},\n", .{ k, try family.ofText(self, family.mask(self, v)) });
        } else try self.w("    f{d}: {s},\n", .{ k, try slotTy(self, @backingInt(v)) });
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
        self.uses.model = true;
        try self.w("    if (std.debug.runtime_safety and contract.validating) std.debug.assert(model.su_ok);\n", .{});
    }
    self.fatal = null;
    self.init_arms.clearRetainingCapacity();
    try emitUnitBody(self, .undef);
    if (std.mem.eql(u8, name, self.core.name)) self.sim_reads = scanSimReads(self, body_start);
    try tableReset(self, body_start);
    try closeSig(self, slots, body_start);
    if (self.core.held_only.len != 0 and !self.uses.held) patchParam(self, at_held, "held".len);
    // A slice of integers and plain arrays alone never names `S`.
    if (!try namesIdent(self, slots.x, "S")) patchParam(self, slots.x - "S: type, ".len, "S".len);
    try self.w("}}\n\n", .{});
    try gen_file.recordUnitFile(self, name, lo, at_fn);
}

/// Returns the unit enumerated from operator call `inst`, or `none_u32`.
// ponytail: a linear scan over the unit list (tens of entries) per rendered
// operator; an nv-sized reverse map if unit counts grow.
pub fn unitOfInst(self: *const Gen, inst: Mir.Inst) u32 {
    for (self.names.units, 0..) |u, i| {
        if (u.inst == inst) return @intCast(i);
    }
    return none_u32;
}

/// Returns which core field holds analog-operator unit `i`'s §4.5 input, or
/// `none_u32` for an operator called with no argument (its input is the
/// literal zero and never reaches the core).
pub fn opInputIdx(self: *const Gen, i: u32) u32 {
    const args = self.names.opArgs(self.mir, i);
    if (args.len == 0) return none_u32;
    return self.core.lo_idx[@backingInt(self.an.rv(args[0]))];
}

/// Emits one source-unit function (LRM §5.6, §4.7, §5.3). The signature is
/// uniform, so `zig` re-analyses exactly the units whose bodies changed.
/// Parameters the body never reads are back-patched to `_`, padded to the
/// name's width, in fixed slots reserved before the body is rendered.
///
/// Returns the offset of the `fn` keyword, where `orchestrator.writeTree`
/// splices `pub ` for the split form. `text` itself stays private because
/// `contract.rejectStrayPubDecls` allows only contract-recognized public names.
fn emitUnit(self: *Gen, name: []const u8, target: Mir.Value, mode: proof.FloatMode, comment: []const u8) Error!usize {
    self.uses = .{};
    self.fatal = null;
    self.plan.display_unit = self.emitting_display;
    try self.plan.analyze(target, self.emitting_common);

    try self.w("/// {s}\n", .{comment});
    const at_fn = self.out.items.len;
    const slots = try openSig(self, name);
    try self.w(") {s} {{\n", .{try family.ofText(self, family.mask(self, target))});
    try self.w("    @setFloatMode(.{t});\n", .{mode});
    self.float.strict = mode == .strict;

    const body_start = self.out.items.len;
    try emitUnitBody(self, target);
    try tableReset(self, body_start);
    try closeSig(self, slots, body_start);
    try self.w("}}\n\n", .{});
    return at_fn;
}

/// §9.21.1 + §9.3 (VD-095): a body that calls `$table_model` on a captured
/// data source starts from the captures an accepted point kept
/// (`Instance.table_kept`). A first call it makes then fixes the data for
/// every later call of that site in this evaluation only: an evaluation the
/// host discards must leave no capture behind for the next one.
fn tableReset(self: *Gen, body_start: usize) Error!void {
    if (self.lowered.table_samples.items.len == 0) return;
    if (std.mem.findPos(u8, self.out.items, body_start, "inst.table_ready[") == null) return;
    try self.out.insertSlice(self.gpa, body_start, "    inst.table_ready = inst.table_kept;\n");
}

/// Offsets of a unit signature's four uniform parameter names, of a
/// `.record` display unit's `out` and of a printing display unit's `pass`
/// (0 for any other unit).
const Slots = struct { x: usize, model: usize, inst: usize, sim: usize, out: usize = 0, pass: usize = 0 };

/// Writes `fn <name>(comptime S: type, x, model, inst, sim` up to the closing
/// parenthesis, reserving each parameter's slot for `closeSig`.
fn openSig(self: *Gen, name: []const u8) Error!Slots {
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
    const eval_writes = self.lowered.timepoints.items.len != 0 or gen_instance.hasStatus(self);
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
    if (self.emitting_display and self.display == .emit and self.passes) {
        try self.w(", comptime ", .{});
        const pass = self.out.items.len;
        try self.w("pass: contract.SayPass", .{});
        return .{ .x = x, .model = model, .inst = inst, .sim = sim, .pass = pass };
    }
    // §9.4 a device's display unit records into the host's buffer (`say`).
    if (!self.emitting_display or self.display != .record) return .{ .x = x, .model = model, .inst = inst, .sim = sim };
    try self.w(", ", .{});
    const out = self.out.items.len;
    try self.w("out: *contract.Say", .{});
    return .{ .x = x, .model = model, .inst = inst, .sim = sim, .out = out };
}

/// Replaces a refused body (from `body_start`) with its `@compileError`, then
/// back-patches every parameter the body never read to `_`.
fn closeSig(self: *Gen, s: Slots, body_start: usize) Error!void {
    if (self.fatal) |msg| {
        self.any_fatal = true;
        self.out.shrinkRetainingCapacity(body_start);
        self.uses = .{};
        try self.b("    @compileError(\"{s}\");\n", .{msg});
    }
    if (!self.uses.x) patchParam(self, s.x, "x".len);
    if (!self.uses.model) patchParam(self, s.model, "model".len);
    if (!self.uses.inst) patchParam(self, s.inst, "inst".len);
    if (!self.uses.sim) patchParam(self, s.sim, "sim".len);
    if (s.out != 0 and !self.uses.out) patchParam(self, s.out, "out".len);
    if (s.pass != 0 and !self.uses.pass) patchParam(self, s.pass, "pass".len);
}

/// Overwrites a reserved parameter-name slot with `_`, space-padded to the
/// name's width so the bytes after it do not move.
pub fn patchParam(self: *Gen, at: usize, comptime width: usize) void {
    self.out.items[at..][0..width].* = ("_" ++ @as([width - 1]u8, @splat(' '))).*;
}

/// Calls `patchParam` on the slot at `at` unless the body text from `from`
/// names `ident` as a whole identifier. Only valid for a body with no string
/// literal in it.
pub fn patchUnless(self: *Gen, at: usize, from: usize, comptime ident: []const u8) void {
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

/// Returns whether the Zig source written from output offset `from` names
/// `ident` as an identifier token, outside any string literal or comment.
/// Tokenizes `out` in place behind a sentinel it appends and pops again, so a
/// body (hundreds of KiB for a large core) is never copied.
fn namesIdent(self: *Gen, from: usize, ident: []const u8) Error!bool {
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

// ---- body emission ------------------------------------------------------

/// Returns the Zig type a value of type `t` is emitted as. A `.wide` value's
/// type is its width's (`slotTy`).
pub fn zigTy(t: VTy) []const u8 {
    return switch (t) {
        .real => "S",
        .int => "i64",
        .str => "[]const u8",
        .wide => unreachable, // `slotTy` spells it from the value's width
    };
}

/// Returns the Zig type value `i` is emitted as.
pub fn slotTy(self: *Gen, i: usize) Error![]const u8 {
    if (self.an.vty[i] == .wide) return gen_wide.zigTy(self, self.an.wide_w[i]);
    return zigTy(self.an.vty[i]);
}

/// Returns the zero value `i`'s slot starts at (`zeroOf`).
fn slotZero(self: *Gen, i: usize) Error![]const u8 {
    if (self.an.vty[i] == .wide) return self.arena.print("zwZero({d})", .{self.an.wide_w[i]});
    return zeroOf(self.an.vty[i]);
}

/// Returns the name of the hoist array a slot of type `t` lives in (`Hoist.idx`).
/// A `.wide` slot keeps its own `var tN`: its type is its width's.
fn hoistArray(t: VTy) []const u8 {
    return switch (t) {
        .real => "h",
        .int => "hi",
        .str => "hs",
        .wide => unreachable, // never hoisted (`emitUnitBody`)
    };
}

// `slotArr`/`slotNum` are the one place that knows whether a slot is its own
// `tN` or a hoist-array element, so declaration and use cannot drift apart.
fn slotArr(self: *Gen, i: usize) ?[]const u8 {
    const s = self.plan.slot[i];
    if (s < self.hoist.idx.items.len and self.hoist.idx.items[s] != none_u32) return hoistArray(self.an.vty[i]);
    return null;
}
fn slotNum(self: *Gen, i: usize) u32 {
    const s = self.plan.slot[i];
    if (s < self.hoist.idx.items.len and self.hoist.idx.items[s] != none_u32) return self.hoist.idx.items[s];
    return s;
}
/// Writes the name value `i`'s slot is read and written under: its own `tN`
/// or an element of a hoist array. Every slotted use goes through it.
pub fn writeSlotRef(self: *Gen, i: usize) Error!void {
    if (slotArr(self, i)) |arr| {
        const k = slotNum(self, i);
        if (self.an.vty[i] == .real) return self.b("h{d}[{d}]", .{ self.hoist.grp.items[k], self.hoist.pos.items[k] });
        return self.b("{s}[{d}]", .{ arr, k });
    }
    return self.b("t{d}", .{slotNum(self, i)});
}

/// Returns the mask of value `i`'s slot when it is an element of the real
/// hoist array (what a write into it widens to), or null for a `const`.
pub fn slotMask(self: *Gen, i: usize) ?[]const u64 {
    if (self.an.vty[i] != .real) return null;
    if (slotArr(self, i) == null) return null;
    return self.hoist.mask.items[slotNum(self, i)];
}

/// Every real hoist element's mask: the union over the values that share it.
fn hoistMasks(self: *Gen, n: u32) Error!void {
    self.hoist.mask.clearRetainingCapacity();
    try self.hoist.mask.ensureTotalCapacityPrecise(self.arena, n);
    for (0..n) |_| self.hoist.mask.appendAssumeCapacity(try gen_mask.zero(self.arena, self.mw));
    for (self.plan.live.items) |lv| {
        const v = @backingInt(lv);
        if (self.an.vty[v] != .real or self.plan.slot[v] == none_u32) continue;
        const k = self.hoist.idx.items[self.plan.slot[v]];
        if (k == none_u32) continue;
        gen_mask.orIn(self.hoist.mask.items[k], family.mask(self, lv));
    }
    for (self.hoist.mask.items) |m| try family.note(self, m);
    // One array per distinct mask: a `@Tuple` with one field per slot is
    // most of a large body's sema time (psp103 `setup`: 1,576 fields, 9
    // masks; `git show 6e59b3d4^:docs/measurements/codegen-levers-2026-09-30.md` lever 5), and
    // every element keeps exactly the type its tuple field had.
    // One `grp`/`pos` entry per hoist element.
    self.hoist.grp.clearRetainingCapacity();
    try self.hoist.grp.ensureTotalCapacityPrecise(self.arena, n);
    self.hoist.pos.clearRetainingCapacity();
    try self.hoist.pos.ensureTotalCapacityPrecise(self.arena, n);
    self.hoist.gmask.clearRetainingCapacity();
    self.hoist.glen.clearRetainingCapacity();
    for (self.hoist.mask.items) |m| {
        // ponytail: linear scan; a body has 1-30 distinct masks.
        const g = for (self.hoist.gmask.items, 0..) |gm, j| {
            if (std.mem.eql(u64, gm, m)) break j;
        } else blk: {
            try self.hoist.gmask.append(self.arena, m);
            try self.hoist.glen.append(self.arena, 0);
            break :blk self.hoist.gmask.items.len - 1;
        };
        self.hoist.grp.appendAssumeCapacity(@intCast(g));
        self.hoist.pos.appendAssumeCapacity(self.hoist.glen.items[g]);
        self.hoist.glen.items[g] += 1;
    }
}

/// Returns `writeSlotRef`'s text as an arena-owned string, for a caller that
/// needs the name as a value (`f64Const`).
pub fn slotRefStr(self: *Gen, i: usize) Error![]const u8 {
    if (slotArr(self, i)) |arr| {
        const k = slotNum(self, i);
        if (self.an.vty[i] == .real) return self.arena.print("h{d}[{d}]", .{ self.hoist.grp.items[k], self.hoist.pos.items[k] });
        return self.arena.print("{s}[{d}]", .{ arr, k });
    }
    return self.arena.print("t{d}", .{slotNum(self, i)});
}

/// Returns the zero a slot of type `t` starts at when it must be defined on
/// every path. Matches `renderVal`'s rendering of an `.undef` operand.
pub fn zeroOf(t: VTy) []const u8 {
    return switch (t) {
        .real => "S.con(0.0)",
        .int => "0",
        .str => "\"\"",
        .wide => unreachable, // its zero has its width (`slotZero`)
    };
}

/// Where one slot's declaration ends up, and the evidence for it.
///
/// `max_use` is an output offset and `scope` an index into `Probe.sc_end`.
/// The emitted scopes nest, so once `pinned` rules out a read before the
/// definition, "every use is lexically inside the block that defines this
/// slot" is exactly `max_use < sc_end[scope]`, with no dominator query needed.
/// `defs`/`uses` saturate at 255: every reader asks only 0, 1 or more.
pub const Place = struct {
    defs: u8 = 0,
    uses: u8 = 0,
    max_use: u32 = 0,
    scope: u32 = 0,
    /// Something disqualifies this slot from `const`-at-definition: a
    /// second assignment (a real phi), a phi copy on a CFG edge, or a use
    /// emitted before the assignment (a loop-carried read).
    pinned: bool = false,
    /// Set once, after the probe: declare at the definition instead of at
    /// function scope.
    at_def: bool = false,

    // One per slot of the body being probed (psp103's `setup`: 6854;
    // hisimhv_va: 10097), walked whole by `probeBody`: 12 bytes, two
    // offsets and four one-byte facts.
    comptime {
        std.debug.assert(@sizeOf(Place) == 12);
    }
};

/// Records that a lexical scope opens at the current output offset. No-op
/// unless `probe.active`.
pub fn scopeOpen(self: *Gen) Error!void {
    if (!self.probe.active) return;
    try self.probe.sc_end.append(self.arena, 0);
    try self.probe.sc_open.append(self.arena, @intCast(self.probe.sc_end.items.len - 1));
}

/// Records that the innermost open scope ends at `at`, which is not always
/// `out.len`: the `cfg.zig` peephole rewinds over a label it drops.
/// No-op unless `probe.active`.
pub fn scopeClose(self: *Gen, at: usize) void {
    if (!self.probe.active) return;
    self.probe.sc_end.items[self.probe.sc_open.pop().?] = @intCast(at);
}

/// Records the definition of `slot` at the current offset while `probe.active`.
/// `movable` is false for a phi copy: `emitPhiCopies` writes the slot from
/// several edges, and even a single-edge copy lands in an arm its merge
/// block's readers are lexically outside of.
pub fn probeDef(self: *Gen, slot: u32, movable: bool) void {
    if (!self.probe.active) return;
    const p = &self.probe.place.items[slot];
    if (p.defs == 0) p.scope = self.probe.sc_open.last().?;
    p.defs +|= 1;
    if (p.defs > 1 or !movable) p.pinned = true;
}

/// Records a read of `slot` at the current offset while `probe.active`.
pub fn probeUse(self: *Gen, slot: u32) void {
    if (!self.probe.active) return;
    const p = &self.probe.place.items[slot];
    p.uses +|= 1;
    // Read before written in the text: a loop-carried value, or a slot the
    // emitter never assigns at all (which is the `undefined`/zero seed the
    // hoist exists to provide).
    if (p.defs == 0) p.pinned = true;
    p.max_use = @max(p.max_use, @as(u32, @intCast(self.out.items.len)));
}

/// Emits the body once as a dry run to learn, per slot, where its assignment
/// lands relative to its reads, then rewinds `out`. A dry run rather than a
/// dominator query because the emitted nesting is not the CFG (dead branches,
/// dropped labels and inlined arms). Safe to run twice: emission only appends
/// to `out` and sets monotone flags, and `fatal` is set-once.
fn probeBody(self: *Gen, target: Mir.Value) Error!void {
    self.probe.place.clearRetainingCapacity();
    try self.probe.place.appendNTimes(self.arena, .{}, self.plan.n_slots);
    self.probe.sc_end.clearRetainingCapacity();
    self.probe.sc_open.clearRetainingCapacity();

    const at = self.out.items.len;
    self.su.exits = 0;
    self.su.store_bytes = 0;
    self.probe.active = true;
    try scopeOpen(self); // the function body itself
    try gen_setup.emitRoot(self, target);
    scopeClose(self, self.out.items.len);
    self.probe.active = false;
    self.su.lines = std.mem.count(u8, self.out.items[at..], "\n");
    self.out.shrinkRetainingCapacity(at);

    for (self.probe.place.items) |*p| {
        // `uses == 0` keeps its `var`: a slot that is written and never read
        // is legal Zig, but the same code as an unused `const` is not.
        p.at_def = !p.pinned and p.defs == 1 and p.uses != 0 and
            p.max_use < self.probe.sc_end.items[p.scope];
    }
}

/// Declares §3.2.2 `var a<id>: [len]T` for each memory-backed array this body
/// writes or reads locally, in array order. Its first `anew` fills it.
fn declareArrays(self: *Gen) Error!void {
    const n = self.lowered.mem_arrays.items.len;
    if (n == 0) return;
    const seen = try self.arena.alloc(bool, n);
    @memset(seen, false);
    // §5.10 a copy-on-write array needs its local storage only if a store
    // writes it; until one does, `p<id>` is the whole of it.
    const stored = try self.arena.alloc(bool, n);
    @memset(stored, false);
    for (self.plan.live.items) |lv| {
        const id = self.an.arrOf(lv) orelse continue;
        if (self.plan.cached(lv)) continue;
        seen[id] = true;
        const def = self.mir.valueDef(lv);
        if (def == .inst_result and self.mir.instOp(def.inst_result) == .store) stored[id] = true;
    }
    for (seen, stored, 0..) |s, st, id| {
        if (!s) continue;
        const len = self.lowered.mem_arrays.items[id].len;
        const ty = try gen_render.arrElemTy(self, @intCast(id));
        if (gen_render.inPlace(self, @intCast(id))) {
            try self.ind(1);
            try self.b("var p{d}: *[{d}]{s} = undefined;\n", .{ id, len, ty });
            continue;
        }
        if (gen_render.cow(self, @intCast(id))) {
            try self.ind(1);
            try self.b("var p{d}: *const [{d}]{s} = undefined;\n", .{ id, len, ty });
            if (!st) continue;
        }
        try self.ind(1);
        try self.b("var a{d}: [{d}]{s} = undefined;\n", .{ id, len, ty });
    }
}

/// Emits the body computing `target` (or every live-out, while
/// `emitting_common`): slot declarations, then the structured control flow.
/// Requires `self.plan` to be analyzed for this unit.
pub fn emitUnitBody(self: *Gen, target: Mir.Value) Error!void {
    // First, before anything can emit a slot name: slot numbering is
    // unit-local, so the previous unit's hoist indices would rename this
    // unit's slots. Both paths below can emit before the real assignment.
    self.hoist.idx.clearRetainingCapacity();
    try self.hoist.idx.appendNTimes(self.arena, none_u32, self.plan.n_slots);

    // One call at the top of the body, so the shared core is evaluated
    // exactly once per unit.
    if (self.plan.uses_cache) {
        self.uses.x = true;
        self.uses.model = true;
        self.uses.inst = true;
        self.uses.sim = true;
        try self.ind(1);
        try self.b("const c = @call(.always_inline, core, .{{ S, x, model, inst, sim{s} }});\n", .{self.heldArg(true)});
    }
    try declareArrays(self);
    if (self.plan.straight) {
        try gen_cfg.emitBlockInsts(self, 0, 1, true);
        try gen_cfg.emitReturn(self, 1, target);
        return;
    }
    // Out-of-SSA: a function-scope `var` per surviving value that needs one.
    // A labelled-block reconstruction can put a definition inside a scope its
    // uses are lexically outside of; `probeBody` finds those, and
    // `emitBlockInsts` declares the rest as `const` at the definition.
    // Left hoisted: values assigned more than once (a real phi), assigned by
    // `emitPhiCopies`, read outside the assigning block, or never assigned.
    //
    // `undefined` is safe for every slot except one the function returns: the
    // return is reached from exit blocks the definition need not dominate
    // (`if (c) I <+ transition(x)`), and `updateState` would push that value
    // into operator history. Zero is the right value, not just a safe one:
    // the arm did not execute, so it contributed nothing, the same reason
    // lowering seeds a §5.6 accumulator with `.f_zero`.
    try probeBody(self, target);
    if (gen_setup.mergePays(self)) {
        self.su.merge = true;
        try probeBody(self, target);
    }
    const ret = self.an.rv(target);

    // One array per type instead of one `var` per slot. Two passes: assign
    // every survivor its index, so the lengths are known, then emit the
    // declarations.
    var n_hoist: [std.enums.values(VTy).len]u32 = @splat(0);
    // IEEE 1364 §5.4 a `.wide` slot: its own `var tN`, of its width's type.
    var own: std.ArrayList(Mir.Value) = .empty;
    defer own.deinit(self.arena);
    // A returned slot cannot be seeded `undefined` (see above), and an array
    // is declared once for all its elements, so those get an explicit store
    // after the declaration.
    var seeded: std.ArrayList(Mir.Value) = .empty;
    defer seeded.deinit(self.arena);
    for (self.plan.live.items) |lv| {
        const v = @backingInt(lv);
        if (self.plan.slot[v] == none_u32) continue;
        const p = self.probe.place.items[self.plan.slot[v]];
        if (p.at_def) continue;
        // Never assigned and never read: `mark` kept the value alive but the
        // emitted tree reaches neither end. Declaring it would be an unused local.
        if (p.defs == 0 and p.uses == 0) continue;
        const returned = if (self.emitting_common) self.plan.lo_idx[v] != none_u32 else lv == ret;
        if (returned) try seeded.append(self.arena, lv);
        if (self.an.vty[v] == .wide) {
            try own.append(self.arena, lv);
            continue;
        }
        const ty = @backingInt(self.an.vty[v]);
        self.hoist.idx.items[self.plan.slot[v]] = n_hoist[ty];
        n_hoist[ty] += 1;
    }
    try hoistMasks(self, n_hoist[@backingInt(VTy.real)]);
    for ([_]VTy{ .real, .int, .str }) |ty| {
        const n = n_hoist[@backingInt(ty)];
        if (n == 0) continue;
        try self.ind(1);
        if (ty == .real) {
            for (self.hoist.gmask.items, self.hoist.glen.items, 0..) |m, len, g| {
                if (g != 0) try self.ind(1);
                try self.b("var h{d}: [{d}]zOf(S, 0x{f}) = undefined;\n", .{ g, len, gen_mask.hex(m, false) });
            }
            continue;
        }
        try self.b("var {s}: [{d}]{s} = undefined;\n", .{ hoistArray(ty), n, zigTy(ty) });
    }
    for (own.items) |lv| {
        try self.ind(1);
        try self.b("var t{d}: {s} = undefined;\n", .{ self.plan.slot[@backingInt(lv)], try slotTy(self, @backingInt(lv)) });
    }
    for (seeded.items) |lv| {
        const v = @backingInt(lv);
        try self.ind(1);
        try writeSlotRef(self, v);
        try self.b(" = ", .{});
        const m = slotMask(self, v);
        if (m) |k| try family.openTo(self, k);
        try self.b("{s}", .{try slotZero(self, v)});
        if (m != null) try self.b(")", .{});
        try self.b(";\n", .{});
    }
    // The probes' arms were rewound with their text.
    self.init_arms.clearRetainingCapacity();
    try gen_setup.emitRoot(self, target);
}

test zigTy {
    try std.testing.expectEqualStrings("S", zigTy(.real));
    try std.testing.expectEqualStrings("i64", zigTy(.int));
    try std.testing.expectEqualStrings("[]const u8", zigTy(.str));
}

test zeroOf {
    // The hoisted seed and `renderVal`'s `.undef` operand: one spelling per type.
    try std.testing.expectEqualStrings("S.con(0.0)", zeroOf(.real));
    try std.testing.expectEqualStrings("0", zeroOf(.int));
    try std.testing.expectEqualStrings("\"\"", zeroOf(.str));
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
        const src = try std.fmt.allocPrint(a,
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
        const want = try std.fmt.allocPrint(a, "pub const sim_reads: contract.SimReads = {s};", .{c.want});
        if (std.mem.find(u8, out, want) == null) {
            std.debug.print("{s}\nwant: {s}\n", .{ c.body, want });
            return error.TestUnexpectedResult;
        }
    }
}
