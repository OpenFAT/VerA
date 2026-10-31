//! Unit list and plans -> the device.zig skeleton, in file order: imports and
//! kernel text, §1.3.1 `U`, §3.4 `Model` and `derive`, `Setup`, `Instance`
//! (`instance.zig`), the units, the dispatchers and host-facing tables, and
//! the contract validation block; plus the unit-file prologue and `h.zig`.
//! `emitFile` is the codegen spine: every other emitter is one line of it.
//! LRM: §1.3.1, §1.3.4.2, §3.4, §3.6.1.2, §4.5, §4.5.12, §4.5.15, §5.4.2, §5.10,
//! §6.3.4, §9.4.3, §9.5, §9.10, §9.13.1, §9.21.
//!
//! Contents:
//! - `pub const Features = struct`
//! - `pub const UnitFile = struct`
//! - `pub fn emitFile(self: *Gen) Error!void`
//! - `pub fn batchLead(self: *const Gen) bool`
//! - `pub fn recordUnitFile(self: *Gen, name: []const u8, lo: usize, fn_at: usize) Error!void`
//! - `pub fn hasStatefulOps(self: *const Gen) bool`
//! - `pub fn usesOp(self: *const Gen, k: OpKind) bool`
//! - `pub fn fmtF64(self: *Gen, x: f64) Error![]const u8`

const std = @import("std");
const codegen = @import("../codegen.zig");
const kt = @import("kernel_text.zig");
const Gen = codegen.Gen;
const call_systf = @import("call_systf.zig");
const gen_dispatch = @import("dispatch.zig");
const jac_tables = @import("jac_tables.zig");
const gen_noise = @import("noise.zig");
const gen_opvars = @import("opvars.zig");
const gen_state = @import("state.zig");
const gen_breakpoints = @import("breakpoints.zig");
const gen_collapse = @import("collapse.zig");
const gen_unit = @import("unit.zig");
const gen_instance = @import("instance.zig");
const gen_status = @import("status.zig");
const gen_family = @import("family.zig");
const gen_setup = @import("setup.zig");
const cg_limit = @import("../cg_limit.zig");
const assert = std.debug.assert;
const Error = codegen.Error;

/// `lib/contract.zig`'s `vera_version`, through `kernels` (which may import
/// `contract`), so the stamp cannot drift from the contract.
const OpKind = @import("ir").op.OpKind;

// =======================================================================
// File assembly
// =======================================================================
const gen_prelude = @import("prelude.zig");
const gen_unknowns = @import("unknowns.zig");
const gen_model = @import("model.zig");
const gen_card_checks = @import("card_checks.zig");

/// The optional helper blocks a device carries. Each flag gates the same
/// block in device.zig, the unit prologue and `h.zig`.
pub const Features = struct {
    stateful: bool,
    hist: bool,
    /// `hist_quad_txt`: an `absdelay` under `(* vera_interp = 2 *)`.
    hist_quad: bool,
    filt: bool,
    /// `ac_txt`: an operator whose small-signal response depends on ω.
    ac: bool,
    timer: bool,
    strs: bool,
    tbl: bool,
    rng: bool,
    files: bool,
    arrs: bool,
    /// `tp_txt`: a VerA `vera_timepoint` statement.
    tp: bool,
    /// `tp_arr_txt`: one caches an array in place (`instance.tpInPlace`).
    tp_arr: bool,
};

/// One emitted top-level unit declaration: a row of `Gen.files`, and of the
/// `Output` columns built from it. Offsets index `Gen.out`, so a device
/// over 4 GiB of text does not fit (`@intCast` traps in safe builds).
pub const UnitFile = struct {
    /// Declaration name and file stem (`Output.names`).
    name: []const u8,
    /// Where the declaration starts (`Output.unit_lo`).
    lo: u32,
    /// Where its keyword starts (`Output.unit_fn`).
    fn_at: u32,
    /// Just past its end (`Output.unit_hi`).
    hi: u32,
};

/// §9.12 / IEEE 1364 §17.10.1/§17.10.2: the plusargs "are searched in the
/// order provided", and a match is a plusarg whose prefix "matches all
/// characters in the provided string". `fmt` cuts `$value$plusargs`'s
/// user_string at its format. The match comes back without its `+`, and
/// `$sscanf` then reads it against the whole user_string (an empty remainder
/// scans as 0 or "", §17.10.2's own answer).
const plusarg_txt =
    \\fn zPlusarg(args: []const [:0]const u8, want: []const u8, fmt: bool) ?[]const u8 {
    \\    const key = if (fmt) want[0 .. std.mem.findScalar(u8, want, '%') orelse want.len] else want;
    \\    for (args) |a| if (a.len != 0 and a[0] == '+' and std.mem.startsWith(u8, a[1..], key)) return a[1..];
    \\    return null;
    \\}
    \\
;

/// Writes the whole device.zig into `self.out` and builds `self.prelude` and
/// `self.helpers`. Requires `Gen.prepare` to have run; asserts nothing has
/// been emitted yet.
pub fn emitFile(self: *Gen) Error!void {
    assert(self.out.items.len == 0);
    assert(self.files.len == 0);
    const hist = usesOp(self, .absdelay);
    const filt = usesOp(self, .laplace) or usesOp(self, .zi);
    const f: Features = .{
        .stateful = hasStatefulOps(self),
        .hist = hist,
        .hist_quad = usesQuad(self),
        .filt = filt,
        .ac = hist or filt,
        .timer = usesOp(self, .timer),
        // §9.5.3/§9.5.4.2. Set at the call in lowering, because once the MIR
        // is sliced the formatter's call may sit in any unit. A printing
        // artifact needs the string kernels too: §9.4.3's real conversions
        // (Table 9-23, "the full formatting capabilities available in the C
        // language") are `zCReal`, which lives in the same file.
        // A §5.10 held string is a `ZStrHeld` (#19), which lives there too.
        .strs = self.lowered.uses.contains(.str_tasks) or self.display == .emit or gen_instance.heldString(self),
        // §9.21, set at the call for the same reason `strs` is: the lookup may
        // land in any unit once the MIR is sliced.
        .tbl = self.lowered.uses.contains(.table_model),
        // §9.13, set at the call for the same reason: `lowerRandom` runs long
        // before the MIR is sliced into units.
        .rng = self.lowered.uses.contains(.rng),
        // §9.5 the descriptor table. Only a `display == .emit` artifact has a
        // host that runs the per-point side-effect phase these kernels need.
        .files = self.display == .emit and self.lowered.uses.contains(.file_tasks),
        // §3.2.2 set in lowering: a runtime-indexed array is one storage.
        .arrs = self.lowered.mem_arrays.items.len != 0,
        .tp = self.lowered.timepoints.items.len != 0,
        .tp_arr = self.tp_of_block.len != 0,
    };
    try gen_prelude.buildPrelude(self, f);
    try self.out.appendSlice(self.gpa, kt.header_txt);
    try self.out.appendSlice(self.gpa, kt.math_txt);
    try self.out.appendSlice(self.gpa, if (self.display == .emit) kt.domain_report_txt else kt.domain_quiet_txt);
    try self.out.appendSlice(self.gpa, kt.ops_txt);
    try self.out.appendSlice(self.gpa, try gen_prelude.wideText(self, kt.family_txt));
    try self.out.appendSlice(self.gpa, try gen_prelude.wideText(self, kt.family_dev_txt));
    if (f.timer) try gen_prelude.depublish(self.gpa, &self.out, kt.timer_txt);
    if (f.hist) try gen_prelude.depublish(self.gpa, &self.out, kt.hist_txt);
    if (f.hist_quad) try self.out.appendSlice(self.gpa, kt.hist_quad_txt);
    if (f.arrs) try self.out.appendSlice(self.gpa, kt.arr_txt);
    if (f.tp) try self.out.appendSlice(self.gpa, kt.tp_txt);
    if (f.tp_arr) try self.out.appendSlice(self.gpa, kt.tp_arr_txt);
    // The embedded kernel files arrive already `pub`, which is right for
    // `h.zig` and wrong here: `contract.rejectStrayPubDecls` allows only
    // contract-recognized public names. So they are depublished; every other
    // helper block is written private and made public by `publish`.
    if (f.filt) try gen_prelude.depublish(self.gpa, &self.out, kt.filt_txt);
    if (f.ac) try self.out.appendSlice(self.gpa, kt.ac_txt);
    if (f.ac) try self.out.appendSlice(self.gpa, try gen_prelude.wideText(self, kt.ac_fam_txt));
    // §9.4.3's padding helper serves §9.5.3 too (`$sformat` is the same
    // formatter), so a device that never prints still needs it to format.
    if (f.strs) try self.out.appendSlice(self.gpa, kt.display_txt);
    if (f.strs) try gen_prelude.depublish(self.gpa, &self.out, kt.str_txt);
    if (f.files) try gen_prelude.depublish(self.gpa, &self.out, kt.file_txt);
    // §9.5.1.2 the same table, public for a host's second context to share
    // (`contract.FileIo`, optional: a host that runs one context ignores it).
    if (f.files) try self.out.appendSlice(self.gpa, "pub const file_io: contract.FileIo = .{ .open = zFOpen, .close = zFClose, .put = zFPut, .getc = zFGetc, .ungetc = zFUngetc, .tell = zFTell, .seek = zFSeek, .eof = zFEof, .err = zFError, .new_analysis = zFNewAnalysis };\n\n");
    if (f.tbl) try gen_prelude.depublish(self.gpa, &self.out, kt.table_txt);
    if (f.rng) try gen_prelude.depublish(self.gpa, &self.out, kt.rng_txt);
    if (self.lowered.wide_nodes.items.len != 0) try gen_prelude.depublish(self.gpa, &self.out, kt.wide_txt);
    if (self.limits.calls.len != 0) try gen_prelude.depublish(self.gpa, &self.out, kt.limit_txt);
    if (self.lowered.uses.contains(.plusargs)) try self.out.appendSlice(self.gpa, plusarg_txt);
    try self.out.appendSlice(self.gpa, "\n");
    // `emitSwitchRow` splits exactly these branches; `prepare` planned them
    // (`plan/topology.zig`) before any residual is emitted.
    const cpairs = self.topo.cpairs;

    try gen_unknowns.emitTopology(self);
    try gen_model.emitModel(self);
    try gen_unknowns.emitDeclMeta(self);
    try gen_unknowns.emitInstanceParams(self);
    try gen_model.emitDerive(self);
    try gen_card_checks.emitShapeCheck(self);
    try gen_card_checks.emitCardCheck(self);
    try gen_card_checks.emitRangeCheck(self);
    try gen_setup.emitSetupDecl(self);
    try gen_instance.emitInstance(self);
    try self.w("const InstancePtr = contract.InstancePtr(@This());\n", .{});
    // VerA's `vera_timepoint` (§2.9): `eval` fills the per-timepoint caches.
    if (self.lowered.table_samples.items.len != 0 or self.lowered.timepoints.items.len != 0 or gen_status.hasStatus(self)) try self.w("pub const mutable_eval = true;\n", .{});
    try gen_setup.emitSetup(self);
    try gen_unit.emitUnits(self);
    try self.w("/// What `eval`, `q` and `evalQ` read of `SimState` (`contract.SimReads`).\n" ++
        "pub const sim_reads: contract.SimReads = .{{ .t = {}, .dt = {}, .iteration = {} }};\n\n", .{ self.sim_reads.t, self.sim_reads.dt, self.sim_reads.iteration });
    try gen_dispatch.emitDispatchers(self);
    try gen_noise.emitNoiseTable(self);
    try gen_noise.emitAcTable(self);
    try gen_opvars.emitOpVarTable(self);
    try call_systf.emitSystfTable(self);
    // §4.5.2's accepted-step sweep also carries §9.13.1's internal-seed
    // advance, the only place a stream may move: a per-iteration draw makes
    // the residual non-deterministic and Newton never converges.
    if (f.stateful or self.lowered.rng_auto_seeds.items.len != 0 or gen_instance.pathLatches(self) or gen_status.hasStatus(self)) try gen_state.emitStateMachine(self);
    try cg_limit.emit(self);
    try gen_collapse.emitCollapse(self, cpairs);
    try gen_breakpoints.emitNextBreakpoint(self);
    try gen_breakpoints.emitDelays(self);
    try jac_tables.emitDerivReads(self, if (self.limits.calls.len != 0) (try cg_limit.liveSets(self)).writes else self.zero_mask);
    const k = try gen_family.constant(self);
    if (k.g or k.c) try self.w(
        \\/// ∂eval/∂x (`g`) and ∂q/∂x (`c`) do not depend on x: a host may build
        \\/// those stamps once per card and instance (`contract.Constant`).
        \\pub const constant: contract.Constant = .{{ .g = {}, .c = {} }};
        \\
        \\
    , .{ k.g, k.c });
    // Lane-parallel permission (see `float/lanes.zig`): eval/q of this device
    // instantiated with a vector S is exact per lane. The testbench's
    // batch differential check keys on it, and a batching host may.
    // ponytail: a `vera_timepoint` cache stores one point's values, so a
    // device with one is not batched; store lane 0 when a host batches it.
    if (batchOk(self)) try self.w(
        \\/// `eval`/`q`/`evalQ` with a family whose `V` holds several operating
        \\/// points compute each point exactly as a one-point call would.
        \\pub const batch_ok = true;
        \\
        \\
    , .{});
    // ...exact per point only for a family running the lead protocol: the
    // device decides on per-point values (`lanes.leadLanes`).
    if (batchLead(self)) try self.w(
        \\/// ...only through the lead protocol (`contract.LeadState`): the device
        \\/// branches on per-point values, so a point that diverges re-runs.
        \\pub const batch_lead = true;
        \\
        \\
    , .{});
    if (batchOk(self) and self.float.inst) try self.w(
        \\/// Each point of a batch reads its own `Instance` (the family's
        \\/// `instLane`); the points share one `Model` row and one `SimState`.
        \\pub const batch_inst = true;
        \\
        \\
    , .{});
    try self.w("comptime {{\n    contract.validate(Self);\n}}\n", .{});
}

/// Whether the device declares `batch_lead` (`batchOk` and a lead decision).
pub fn batchLead(self: *const Gen) bool {
    return batchOk(self) and self.float.lead;
}

/// Records the unit declaration `name` spanning `lo` to the current end of
/// `self.out`, with its keyword at `fn_at`. Asserts `lo` is the previous
/// range's end (the ranges tile, `Output`'s invariant) and `fn_at` lies in
/// the range.
pub fn recordUnitFile(self: *Gen, name: []const u8, lo: usize, fn_at: usize) Error!void {
    const his = self.files.items(.hi);
    if (his.len != 0) assert(his[his.len - 1] == lo);
    assert(name.len != 0);
    assert(lo <= fn_at);
    assert(fn_at <= self.out.items.len);
    try self.files.append(self.arena, .{
        .name = name,
        .lo = @intCast(lo),
        .fn_at = @intCast(fn_at),
        .hi = @intCast(self.out.items.len),
    });
    assert(self.files.items(.hi)[self.files.len - 1] == self.out.items.len);
}

/// Returns whether the model needs the §4.5.2 accepted-step machinery: a
/// stateful operator, a §5.10 held variable or a `$limit` slot. Each keeps
/// state in `Instance` that only `updateState` may advance.
pub fn hasStatefulOps(self: *const Gen) bool {
    assert(self.names.units.len == self.names.unit_names.len);
    if (self.lowered.held_vars.items.len != 0 or self.lowered.limit_slots.items.len != 0) return true;
    // VerA's `$vera_reject_step`: `updateState` is where the request is read.
    if (self.lowered.reject_step != .undef) return true;
    // §9.21.1 (VD-095): `updateState` keeps a `$table_model` capture.
    if (self.lowered.table_samples.items.len != 0) return true;
    for (self.names.units) |u| {
        if (u.role == .analog_op and u.op != .none) return true;
    }
    return false;
}

/// Returns whether any unit is a call to analog operator `k`.
pub fn usesOp(self: *const Gen, k: OpKind) bool {
    assert(k != .none);
    for (self.names.units) |u| {
        if (u.role == .analog_op and u.op == k) return true;
    }
    return false;
}

/// Returns the Zig text of a float constant, memoized on its bit pattern.
/// Large models emit hundreds of thousands of constants with few distinct
/// texts. Keyed on `@bitCast`, not the `f64`: `-0.0` and `0.0` compare equal
/// but render differently, and NaN is not equal to itself. The text is
/// arena-owned and shared between calls.
pub fn fmtF64(self: *Gen, x: f64) Error![]const u8 {
    const cached_before = self.f64_cache.count();
    defer assert(self.f64_cache.count() >= cached_before);
    if (std.math.isNan(x)) return kt.nan_lit;
    if (std.math.isInf(x)) return if (x > 0) kt.inf_lit else "-" ++ kt.inf_lit;
    const gop = try self.f64_cache.getOrPut(self.arena, @bitCast(x));
    if (gop.found_existing) return gop.value_ptr.*;
    // Render on the stack, then copy the survivor. `{d}` on an f64 is at
    // most ~24 bytes.
    var buf: [512]u8 = undefined;
    const s = std.mem.print(&buf, "{d}", .{x}) catch unreachable;
    const has_point = std.mem.findAny(u8, s, ".eE") != null;
    gop.value_ptr.* = if (has_point)
        try self.arena.dupe(u8, s)
    else
        try self.arena.print("{s}.0", .{s});
    return gop.value_ptr.*;
}

// ---- private ----

/// Whether the device declares `batch_ok`: no lane pinned, no per-timepoint
/// cache or status latch (each stores one point's values).
fn batchOk(self: *const Gen) bool {
    assert(self.out.items.len != 0);
    return !self.float.pinned and self.lowered.timepoints.items.len == 0 and !gen_status.hasStatus(self);
}

fn usesQuad(self: *const Gen) bool {
    assert(self.names.units.len == self.names.unit_names.len);
    for (self.names.units) |u| {
        if (u.role == .analog_op and self.mir.instData(u.inst).call.callee == .@"absdelay$quad") return true;
    }
    return false;
}
