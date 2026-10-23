//! Unit list and plans -> the device.zig skeleton, in file order: imports and
//! kernel text, §1.3.1 `U`, §3.4 `Model` and `derive`, `Setup`, `Instance`
//! (`instance.zig`), the units, the dispatchers and host-facing tables, and
//! the contract validation block; plus the unit-file prologue and `h.zig`.
//! `emitFile` is the codegen spine: every other emitter is one line of it.
//! LRM: §1.3.1, §1.3.4.2, §3.4, §3.6.1.2, §4.5, §4.5.12, §4.5.15, §5.4.2, §5.10,
//! §6.3.4, §9.4.3, §9.5, §9.10, §9.13.1, §9.21.

const std = @import("std");
const plan_topo = @import("plan/topology.zig");
const codegen = @import("../codegen.zig");
const kt = @import("kernel_text.zig");
const gen_mask = @import("mask.zig");
const Gen = codegen.Gen;
const gen_call = @import("call.zig");
const gen_host = @import("host_expr.zig");
const gen_dispatch = @import("dispatch.zig");
const gen_noise = @import("noise.zig");
const gen_state = @import("state.zig");
const gen_unit = @import("unit.zig");
const gen_instance = @import("instance.zig");
const gen_family = @import("family.zig");
const gen_setup = @import("setup.zig");
const Analysis = @import("prove").Analysis;
const cg_limit = @import("../cg_limit.zig");
const Lower = @import("ir").Lowered;
const assert = std.debug.assert;
const Error = codegen.Error;

/// `lib/contract.zig`'s `vera_version`, through `kernels` (which may import
/// `contract`), so the stamp cannot drift from the contract.
const vera_version = @import("kernels").vera_version;
const VTy = codegen.VTy;
const OpKind = @import("ir").op.OpKind;

// =======================================================================
// File assembly
// =======================================================================

/// The optional helper blocks a device carries. Each flag gates the same
/// block in device.zig, the unit prologue and `h.zig`.
const Features = struct {
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

/// Writes the whole device.zig into `self.out` and builds `self.prelude` and
/// `self.helpers`. Requires `Gen.prepare` to have run; asserts nothing has
/// been emitted yet.
pub fn emitFile(self: *Gen) Error!void {
    assert(self.out.items.len == 0 and self.files.len == 0);
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
    try buildPrelude(self, f);
    try self.out.appendSlice(self.gpa, kt.header_txt);
    try self.out.appendSlice(self.gpa, kt.math_txt);
    try self.out.appendSlice(self.gpa, if (self.display == .emit) kt.domain_report_txt else kt.domain_quiet_txt);
    try self.out.appendSlice(self.gpa, kt.ops_txt);
    try self.out.appendSlice(self.gpa, try wideText(self, kt.family_txt));
    try self.out.appendSlice(self.gpa, try wideText(self, kt.family_dev_txt));
    if (f.timer) try depublish(self.gpa, &self.out, kt.timer_txt);
    if (f.hist) try depublish(self.gpa, &self.out, kt.hist_txt);
    if (f.hist_quad) try self.out.appendSlice(self.gpa, kt.hist_quad_txt);
    if (f.arrs) try self.out.appendSlice(self.gpa, kt.arr_txt);
    if (f.tp) try self.out.appendSlice(self.gpa, kt.tp_txt);
    if (f.tp_arr) try self.out.appendSlice(self.gpa, kt.tp_arr_txt);
    // The embedded kernel files arrive already `pub`, which is right for
    // `h.zig` and wrong here: `contract.rejectStrayPubDecls` allows only
    // contract-recognized public names. So they are depublished; every other
    // helper block is written private and made public by `publish`.
    if (f.filt) try depublish(self.gpa, &self.out, kt.filt_txt);
    if (f.ac) try self.out.appendSlice(self.gpa, kt.ac_txt);
    if (f.ac) try self.out.appendSlice(self.gpa, try wideText(self, kt.ac_fam_txt));
    // §9.4.3's padding helper serves §9.5.3 too (`$sformat` is the same
    // formatter), so a device that never prints still needs it to format.
    if (f.strs) try self.out.appendSlice(self.gpa, kt.display_txt);
    if (f.strs) try depublish(self.gpa, &self.out, kt.str_txt);
    if (f.files) try depublish(self.gpa, &self.out, kt.file_txt);
    // §9.5.1.2 the same table, public for a host's second context to share
    // (`contract.FileIo`, optional: a host that runs one context ignores it).
    if (f.files) try self.out.appendSlice(self.gpa, "pub const file_io: contract.FileIo = .{ .open = zFOpen, .close = zFClose, .put = zFPut, .getc = zFGetc, .ungetc = zFUngetc, .tell = zFTell, .seek = zFSeek, .eof = zFEof, .err = zFError, .new_analysis = zFNewAnalysis };\n\n");
    if (f.tbl) try depublish(self.gpa, &self.out, kt.table_txt);
    if (f.rng) try depublish(self.gpa, &self.out, kt.rng_txt);
    if (self.lowered.wide_nodes.items.len != 0) try depublish(self.gpa, &self.out, kt.wide_txt);
    if (self.limits.calls.len != 0) try depublish(self.gpa, &self.out, kt.limit_txt);
    if (self.lowered.uses.contains(.plusargs)) try self.out.appendSlice(self.gpa, plusarg_txt);
    try self.out.appendSlice(self.gpa, "\n");
    // `emitSwitchRow` splits exactly these branches; `prepare` planned them
    // (`plan/topology.zig`) before any residual is emitted.
    const cpairs = self.topo.cpairs;

    try emitTopology(self);
    try emitModel(self);
    try emitDeclMeta(self);
    try emitInstanceParams(self);
    try emitDerive(self);
    try emitShapeCheck(self);
    try emitCardCheck(self);
    try emitRangeCheck(self);
    try gen_setup.emitSetupDecl(self);
    try gen_instance.emitInstance(self);
    try self.w("const InstancePtr = contract.InstancePtr(@This());\n", .{});
    // VerA's `vera_timepoint` (§2.9): `eval` fills the per-timepoint caches.
    if (self.lowered.table_samples.items.len != 0 or self.lowered.timepoints.items.len != 0 or gen_instance.hasStatus(self)) try self.w("pub const mutable_eval = true;\n", .{});
    try gen_setup.emitSetup(self);
    try gen_unit.emitUnits(self);
    try self.w("/// What `eval`, `q` and `evalQ` read of `SimState` (`contract.SimReads`).\n" ++
        "pub const sim_reads: contract.SimReads = .{{ .t = {}, .dt = {}, .iteration = {} }};\n\n", .{ self.sim_reads.t, self.sim_reads.dt, self.sim_reads.iteration });
    try gen_dispatch.emitDispatchers(self);
    try gen_noise.emitNoiseTable(self);
    try gen_noise.emitAcTable(self);
    try gen_call.emitSystfTable(self);
    // §4.5.2's accepted-step sweep also carries §9.13.1's internal-seed
    // advance, the only place a stream may move: a per-iteration draw makes
    // the residual non-deterministic and Newton never converges.
    if (f.stateful or self.lowered.rng_auto_seeds.items.len != 0 or gen_instance.pathLatches(self) or gen_instance.hasStatus(self)) try gen_state.emitStateMachine(self);
    try cg_limit.emit(self);
    try gen_state.emitCollapse(self, cpairs);
    try gen_state.emitNextBreakpoint(self);
    try gen_state.emitDelays(self);
    try gen_dispatch.emitDerivReads(self, if (self.limits.calls.len != 0) (try cg_limit.liveSets(self)).writes else self.zero_mask);
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

/// Whether the device declares `batch_ok`: no lane pinned, no per-timepoint
/// cache or status latch (each stores one point's values).
fn batchOk(self: *const Gen) bool {
    return !self.float.pinned and self.lowered.timepoints.items.len == 0 and !gen_instance.hasStatus(self);
}

/// Whether the device declares `batch_lead` (`batchOk` and a lead decision).
pub fn batchLead(self: *const Gen) bool {
    return batchOk(self) and self.float.lead;
}

/// `txt` with its masks typed `contract.MaskOf(n_u)`: `txt` itself up to 64
/// unknowns, whose masks are the `u64` it is written in; past them, every
/// `u64` mask parameter widened and the two "past 64, every lane" fallbacks
/// gone, since each unknown has its own bit. Arena-owned.
fn wideText(self: *Gen, txt: []const u8) Error![]const u8 {
    if (self.mw == 1) return txt;
    var tb: [16]u8 = undefined;
    const ty = gen_mask.typeName(&tb, self.names.n_u);
    const pairs = [_][2][]const u8{
        .{ "comptime m: u64", try self.arena.print("comptime m: {s}", .{ty}) },
        .{ "comptime _: u64", try self.arena.print("comptime _: {s}", .{ty}) },
        .{ "if (u < 64) @as(u64, 1) << u else ~@as(u64, 0)", try self.arena.print("@as({s}, 1) << u", .{ty}) },
        .{ "comptime u >= 64 or (zdr >> u) & 1 != 0", "comptime (zdr >> u) & 1 != 0" },
    };
    var out = txt;
    for (pairs) |pr| out = try std.mem.replaceOwned(u8, self.arena, out, pr[0], pr[1]);
    return out;
}

/// Builds `Output.prelude` (the file-scope prologue of a `u/<key>.zig`) and
/// `Output.helpers` (`h.zig`). Unit files alias the helpers rather than
/// re-emitting them, so `zig` analyses each once. The aliases are gated on the
/// same `Features` `emitFile` uses, so none names a missing decl.
fn buildPrelude(self: *Gen, f: Features) Error!void {
    var p: std.ArrayList(u8) = .empty;
    try p.appendSlice(self.arena, kt.prelude_head_txt);
    const alias = kt.appendAliases;
    try alias(&p, self.arena, kt.math_txt);
    try alias(&p, self.arena, kt.ops_txt);
    try alias(&p, self.arena, kt.family_txt);
    if (f.timer) try alias(&p, self.arena, kt.timer_txt);
    if (f.hist) try alias(&p, self.arena, kt.hist_txt);
    if (f.hist_quad) try alias(&p, self.arena, kt.hist_quad_txt);
    if (f.arrs) try alias(&p, self.arena, kt.arr_txt);
    if (f.tp) try alias(&p, self.arena, kt.tp_txt);
    if (f.tp_arr) try alias(&p, self.arena, kt.tp_arr_txt);
    if (f.filt) try alias(&p, self.arena, kt.filt_txt);
    if (f.ac) try alias(&p, self.arena, kt.ac_txt);
    if (f.strs) try alias(&p, self.arena, kt.display_txt);
    if (f.strs) try alias(&p, self.arena, kt.str_txt);
    if (f.files) try alias(&p, self.arena, kt.file_txt);
    if (f.tbl) try alias(&p, self.arena, kt.table_txt);
    if (f.rng) try alias(&p, self.arena, kt.rng_txt);
    // The shared core is a unit file beside the units that call it, and
    // device.zig's alias for it is private. Spelled `core`, not the structural
    // key, so the core's own file (same prologue) does not redeclare its name;
    // a file importing itself is legal and, unreferenced, never analysed.
    if (self.core.name.len != 0)
        try p.print(self.arena, "const core = @import(\"{0s}.zig\").{0s};\n", .{self.core.name});
    // §4.5.11/§4.5.12 the `pub fn <unit>__sec` readers live in device.zig
    // (`unit.emitUnits`), so a unit calling one reads it through `dev`.
    for (self.names.units, 0..) |_, i| {
        if (gen_unit.filterSec(self, i) == null) continue;
        try p.print(self.arena, "const {0s}__sec = dev.{0s}__sec;\n", .{self.names.unit_names[i]});
    }
    try p.appendSlice(self.arena, "\n");
    self.prelude = p.items;

    var hz: std.ArrayList(u8) = .empty;
    try hz.appendSlice(self.arena, kt.helpers_head_txt);
    try publish(self.arena, &hz, kt.math_txt);
    try publish(self.arena, &hz, if (self.display == .emit) kt.domain_report_txt else kt.domain_quiet_txt);
    try publish(self.arena, &hz, kt.ops_txt);
    try hz.appendSlice(self.arena, "const zdr = contract.derivReads(@import(\"device.zig\"));\n");
    try publish(self.arena, &hz, try wideText(self, kt.family_txt));
    if (f.timer) try publish(self.arena, &hz, kt.timer_txt);
    if (f.hist) try publish(self.arena, &hz, kt.hist_txt);
    if (f.hist_quad) try publish(self.arena, &hz, kt.hist_quad_txt);
    if (f.arrs) try publish(self.arena, &hz, kt.arr_txt);
    if (f.tp) try publish(self.arena, &hz, kt.tp_txt);
    if (f.tp_arr) try publish(self.arena, &hz, kt.tp_arr_txt);
    if (f.filt) try publish(self.arena, &hz, kt.filt_txt);
    if (f.ac) try publish(self.arena, &hz, kt.ac_txt);
    if (f.strs) try publish(self.arena, &hz, kt.display_txt);
    if (f.strs) try publish(self.arena, &hz, kt.str_txt);
    if (f.files) try publish(self.arena, &hz, kt.file_txt);
    if (f.tbl) try publish(self.arena, &hz, kt.table_txt);
    if (f.rng) try publish(self.arena, &hz, kt.rng_txt);
    self.helpers = hz.items;
}

/// Copies `src` into `out` with each leading `pub ` dropped, so an embedded
/// Zig file can be spliced into device.zig. The inverse of `publish`.
fn depublish(gpa: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(gpa, '\n');
        first = false;
        try out.appendSlice(gpa, if (std.mem.startsWith(u8, line, "pub ")) line[4..] else line);
    }
}

/// Copies `src` into `out`, making each top-level `fn`/`const` public. The
/// same text is private in device.zig, where the contract forbids stray
/// public names, and public in `h.zig`, where the unit files reach it.
fn publish(arena: std.mem.Allocator, out: *std.ArrayList(u8), src: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, src, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;
        if (kt.declKeyword(line) != null) try out.appendSlice(arena, "pub ");
        try out.appendSlice(arena, line);
    }
}

/// Records the unit declaration `name` spanning `lo` to the current end of
/// `self.out`, with its keyword at `fn_at`. Asserts `lo` is the previous
/// range's end (the ranges tile, `Output`'s invariant) and `fn_at` lies in
/// the range.
pub fn recordUnitFile(self: *Gen, name: []const u8, lo: usize, fn_at: usize) Error!void {
    const his = self.files.items(.hi);
    if (his.len != 0) assert(his[his.len - 1] == lo);
    assert(lo <= fn_at and fn_at <= self.out.items.len);
    try self.files.append(self.arena, .{
        .name = name,
        .lo = @intCast(lo),
        .fn_at = @intCast(fn_at),
        .hi = @intCast(self.out.items.len),
    });
}

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

/// Returns whether the model needs the §4.5.2 accepted-step machinery: a
/// stateful operator, a §5.10 held variable or a `$limit` slot. Each keeps
/// state in `Instance` that only `updateState` may advance.
pub fn hasStatefulOps(self: *const Gen) bool {
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
    for (self.names.units) |u| {
        if (u.role == .analog_op and u.op == k) return true;
    }
    return false;
}

fn usesQuad(self: *const Gen) bool {
    for (self.names.units) |u| {
        if (u.role == .analog_op and self.mir.instData(u.inst).call.callee == .@"absdelay$quad") return true;
    }
    return false;
}

/// Emits `U`, the solver unknowns (§1.3.1 nodes, §6.5 ports first, so the
/// host's terminal order is the module header order), and the per-unknown
/// tables. `x[i]` in every emitted body indexes this enum. `U` is an
/// `enum(u8)` up to 256 unknowns and as wide as the count needs past them
/// (`contract.isDenseEnum` takes any unsigned tag of 8 bits or more), so the
/// count has no bound of its own (#29; §6.5.2.2 asks for at least 256 ports).
fn emitTopology(self: *Gen) Error!void {
    const n_names: u32 = @intCast(self.names.u_names.len);
    try self.w("/// Solver unknowns: §6.5 ports first, then §3.6.3 internal nets,\n", .{});
    try self.w("/// then §5.4.2 branch-flow unknowns.\n", .{});
    try self.w("pub const U = enum(u{d}) {{\n", .{@max(8, std.math.log2_int_ceil(u32, @max(n_names, 1)))});
    for (self.names.u_names, 0..) |n, i| {
        const kindc: []const u8 = if (i < self.lowered.num_ports)
            "port"
        else if (plan_topo.isFlowUnknown(self.input(), @intCast(i)))
            "branch flow"
        else if (i < self.lowered.nodes.len and self.lowered.nodes.items(.kind)[i] == .op_state)
            "§4.5.2 operator unknown"
        else
            "internal";
        try self.w("    {s}, // {s}\n", .{ n, kindc });
    }
    // No unknowns: Zig 0.17 refuses an empty exhaustive `enum(u8)`, and
    // `enum(noreturn)` would break the contract's unsigned tag.
    if (self.names.u_names.len == 0) try self.w("    _,\n", .{});
    try self.w(
        \\}};
        \\
        \\/// The first `num_ports` members of `U` are the §6.5 ports, in
        \\/// port-list order: the unknowns a netlist connects.
        \\pub const num_ports: usize = {d};
        \\const n_u = contract.nU(Self);
        \\
        \\
    , .{self.lowered.num_ports});
    try self.w("/// The VerA release that generated this device (`contract.vera_version`).\npub const vera_version = \"{s}\";\n\n", .{vera_version});

    if (self.float.jac != .off) try self.w(
        \\/// This device permits a single-precision DERIVATIVE half in the
        \\/// host's scalar S. The residual stays f64 — see `--jac-f32`.
        \\/// Permission, not order: a host may take it on one instantiation
        \\/// (its GPU kernel) and decline it on another (its CPU path).
        \\pub const jac_f32 = true;
        \\
        \\
    , .{});
    if (self.float.jac == .host) try self.w(
        \\/// ...and the host should take that permission on its CPU path too,
        \\/// not only where f32 is free. See `--jac-f32-host`.
        \\pub const jac_f32_host = true;
        \\
        \\
    , .{});

    var any_current = false;
    for (0..self.names.n_u) |i| {
        if (plan_topo.isFlowUnknown(self.input(), @intCast(i))) any_current = true;
    }
    if (any_current) {
        try self.w(
            \\/// Per unknown, in `U` order: a node potential (`.voltage`) or a
            \\/// §5.4.2 branch flow (`.current`).
            \\pub const u_kinds = [n_u]contract.UnknownKind{{
            \\
        , .{});
        for (0..self.names.n_u) |i| {
            try self.w("    .{s},\n", .{if (plan_topo.isFlowUnknown(self.input(), @intCast(i))) "current" else "voltage"});
        }
        try self.w("}};\n\n", .{});
    }
    // §3.6.1.2 the tolerance the discipline settled on for each unknown. A
    // host needs the absolute half of its stopping test per unknown and
    // cannot derive it: "negligible" differs per nature, and §3.6.2.3 lets a
    // discipline override the nature's number.
    try self.w("/// §3.6.1.2 `abstol` per unknown: the largest value of this\n", .{});
    try self.w("/// quantity a host may treat as zero, after any §3.6.2.3 override.\n", .{});
    try self.w("pub const u_abstol = [n_u]f64{{\n", .{});
    for (0..self.names.n_u) |i| {
        try self.w("    {d},\n", .{abstolOf(self, @intCast(i))});
    }
    try self.w("}};\n\n", .{});
    try emitNodesets(self);
}

/// Emits `u_nodeset`, the §3.6.3.2 net discipline initial values as one
/// optional table over `U`: a number per unknown only the declaration knows
/// and only the host's solver can use. Emitted only when the module declares
/// one, so its absence means "no opinion". `?f64` because "a null value ...
/// indicates that no nodeset value is being specified" and zero is an
/// ordinary nodeset; a §5.4.2 branch flow is always null.
fn emitNodesets(self: *Gen) Error!void {
    if (self.lowered.nodesets.items.len == 0) return;
    try self.w("/// §3.6.3.2 nodeset: the initial guess the source states for each\n", .{});
    try self.w("/// unknown's potential. A HINT to the solver — not an initial\n", .{});
    try self.w("/// condition and not a clamp; the solved answer is unchanged by it.\n", .{});
    try self.w("pub const u_nodeset = [n_u]?f64{{\n", .{});
    for (0..self.names.n_u) |i| {
        // §3.6.3.2: "If different nets of a node have conflicting
        // initializers ... it is a race condition for which the initializer
        // wins." Last wins here, which the clause permits.
        var v: ?f64 = null;
        for (self.lowered.nodesets.items) |ns| {
            if (ns.node == i) v = ns.value;
        }
        if (v) |x| try self.w("    {s},\n", .{try fmtF64(self, x)}) else try self.w("    null,\n", .{});
    }
    try self.w("}};\n\n", .{});
}

/// Emits `decl_meta`, §2.9.2's `desc` and `units` on the module's own
/// declarations (`contract.DeclMeta`), in `Lowered.decl_meta` order. Only
/// when the module writes one: its absence means no such attribute.
fn emitDeclMeta(self: *Gen) Error!void {
    if (self.lowered.decl_meta.items.len == 0) return;
    try self.w("/// §2.9.2 `desc`/`units` of this module's own declarations, for a\n", .{});
    try self.w("/// host's help messages and operating-point reports (§3.2.1, §3.4.3, §3.6.3.1).\n", .{});
    try self.w("pub const decl_meta = [_]contract.DeclMeta{{\n", .{});
    for (self.lowered.decl_meta.items) |m| {
        try self.w("    .{{ .kind = .{t}, .name = \"{f}\"", .{ m.kind, std.zig.fmtString(m.name) });
        if (m.desc) |v| try self.w(", .desc = \"{f}\"", .{std.zig.fmtString(v)});
        if (m.units) |v| try self.w(", .units = \"{f}\"", .{std.zig.fmtString(v)});
        try self.w(" }},\n", .{});
    }
    try self.w("}};\n\n", .{});
}

/// Emits `instance_params` (`contract`'s optional table): the `Model` fields
/// of the parameters marked `type = "instance"`. Only when one is.
fn emitInstanceParams(self: *Gen) Error!void {
    if (self.lowered.instance_params.items.len == 0) return;
    try self.w("/// The parameters marked `(* type = \"instance\" *)`: an OSDI host lists\n", .{});
    try self.w("/// only these as instance parameters.\n", .{});
    try self.w("pub const instance_params = [_][]const u8{{\n", .{});
    for (self.lowered.instance_params.items) |nm| {
        for (self.lowered.params.items, 0..) |p, i| if (std.mem.eql(u8, p.name, nm)) {
            try self.w("    \"{s}\",\n", .{self.names.p_names[i]});
            break;
        };
    }
    try self.w("}};\n\n", .{});
}

/// Returns the §3.6.1.2 `abstol` of the nature this unknown's quantity
/// belongs to, after §3.6.2.3's per-discipline override (so it reads
/// `DisciplineInfo`, not the nature table). A §5.4.2 branch flow takes the
/// discipline at its high node (`Lower.NodeKind`'s payload). A net with no
/// discipline (a §3.5 implicit net without `default_discipline`) falls back to
/// annex D's `VOLTAGE_ABSTOL` 1e-6 / `CURRENT_ABSTOL` 1e-12.
/// A shared potential node uses §7.2.4's minimum across its signal segments.
fn abstolOf(self: *const Gen, i: u32) f64 {
    const flow = plan_topo.isFlowUnknown(self.input(), i);
    var idx: u32 = i;
    if (i < self.lowered.nodes.len) switch (self.lowered.nodes.items(.kind)[i]) {
        .net => {},
        .branch_flow, .port_flow => |n| idx = n,
        .op_state => |t| return t,
    };
    if (idx == Lower.ground or idx >= self.lowered.nodes.len)
        return if (flow) 1e-12 else 1e-6;
    if (!flow) if (self.lowered.nodes.items(.potential_abstol)[idx]) |abstol| return abstol;
    const info = self.lowered.disciplines.get(self.lowered.nodes.items(.disc)[idx]) orelse
        return if (flow) 1e-12 else 1e-6;
    return if (flow) info.flow_abstol else info.potential_abstol;
}

/// Returns the `Model` field type of parameter `p` (an alias's is its
/// original's).
fn paramFieldType(self: *Gen, p: Lower.ParamInfo) []const u8 {
    return switch (Analysis.tyOfParam(p.ty)) {
        .real => "f64",
        .int => intFieldType(self, p),
        .str => "[]const u8",
        .wide => unreachable, // `tyOfParam` types no parameter wide
    };
}

/// Returns the `Model` field type of a §3.4 integer parameter: the `i64`
/// carrier (an inferred integral one keeps its initializer's bit pattern;
/// an explicit `integer` holds §3.4.1's 32-bit value, and `derive` keeps the
/// low 32 bits of whatever a host writes), or the narrowest of i8/u8/i16/u16
/// that holds its folded §3.4.2 `from` ranges and its default when the card
/// alone writes it. A `derive` target keeps the carrier: a dependent default
/// outside the range must still be stored for `checkRange` to name. A host
/// writes a narrow field with a checked cast (docs/host/device.md).
fn intFieldType(self: *Gen, p: Lower.ParamInfo) []const u8 {
    if (!p.integer32 or p.is_local or self.an.foldConst(p.default, false) == null) return "i64";
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (p.ranges) |r| {
        if (r.kind != .from) continue;
        const l = r.lo orelse return "i64";
        const h = r.hi orelse return "i64";
        if (r.strings or !std.math.isFinite(l) or !std.math.isFinite(h)) return "i64";
        // Integer ends: an open bound excludes the integer it names.
        lo = @min(lo, if (r.lo_inclusive) @ceil(l) else @floor(l) + 1);
        hi = @max(hi, if (r.hi_inclusive) @floor(h) else @ceil(h) - 1);
    }
    if (lo > hi) return "i64"; // no `from` range, or an empty one
    // §3.4.2 checks the card, not the default: the default must fit too.
    const d: f64 = @floatFromInt(defaultInt(self, p) orelse return "i64");
    lo = @min(lo, d);
    hi = @max(hi, d);
    if (lo >= 0) return if (hi <= std.math.maxInt(u8)) "u8" else if (hi <= std.math.maxInt(u16)) "u16" else "i64";
    if (lo >= std.math.minInt(i8) and hi <= std.math.maxInt(i8)) return "i8";
    if (lo >= std.math.minInt(i16) and hi <= std.math.maxInt(i16)) return "i16";
    return "i64";
}

/// The folded default of an integer parameter, as `paramDefault` prints
/// it, or null when it is not a constant.
fn defaultInt(self: *Gen, p: Lower.ParamInfo) ?i64 {
    if (p.folded) |k| return switch (k) {
        .int => |v| if (p.integer32) @import("kernels").fold.wrap32(v) else v,
        .real => |v| if (p.integer32) std.math.lossyCast(i32, @round(v)) else std.math.lossyCast(i64, @round(v)),
        .str => 0,
    };
    const c = self.an.foldConst(p.default, true) orelse return null;
    return std.math.lossyCast(i64, @round(c.f));
}

/// How many §9.19 given bits `Model.given__` holds: one per flagged
/// parameter, then one per §3.4.7 alias.
fn givenCount(self: *const Gen) usize {
    return self.names.n_given + self.lowered.aliases.items.len;
}

/// Emits `Model.given_params` and `Model.setGiven`, the host's side of
/// `given__`, inside the struct so a host holding the `Model` type alone
/// (a generic card writer) reaches them.
fn emitGiven(self: *Gen) Error!void {
    if (givenCount(self) == 0) return;
    try self.w(
        \\    /// The names with a §9.19 `$param_given` bit in `given__`, bit k for
        \\    /// name k: every parameter the model asks about or whose default
        \\    /// `derive` fills, then every §3.4.7 alias. `setGiven` sets one.
        \\    pub const given_params = [_][]const u8{{
        \\
    , .{});
    for (self.lowered.params.items, 0..) |_, i| if (self.names.p_given[i]) try self.w("        \"{s}\",\n", .{self.names.p_names[i]});
    for (self.names.a_names) |a| try self.w("        \"{s}\",\n", .{a});
    try self.w(
        \\    }};
        \\
        \\    /// §9.19 marks `name` (a field's spelling) given: sets its bit. A name
        \\    /// without one is a no-op, since nothing reads it.
        \\    pub fn setGiven(model: *Model, name: []const u8) void {{
        \\        for (given_params, 0..) |n, k| {{
        \\            if (std.mem.eql(u8, n, name)) {{
        \\                model.given__.set(k);
        \\                return;
        \\            }}
        \\        }}
        \\    }}
        \\
    , .{});
}

/// Emits `Model`: one typed field per §3.4 parameter, initialized to its
/// folded spec default, plus alias, `tnom` and retention-flag fields.
fn emitModel(self: *Gen) Error!void {
    try self.w("/// §3.4 module parameters (spec defaults folded at compile time).\npub const Model = struct {{\n", .{});
    for (self.lowered.params.items, 0..) |p, i| {
        try checkParamDefault(self, p);
        try self.w("    {s}: {s} = {s},\n", .{ self.names.p_names[i], paramFieldType(self, p), try paramDefault(self, p, Analysis.tyOfParam(p.ty)) });
    }
    // §3.4.7 aliasparam: "The aliasparam declaration creates an alternate
    // name ... which can be used to override the value of the parameter", so
    // the alias is part of the model card. It is a second field because Zig
    // has no field aliases; `derive` folds it back onto the original.
    // Its given bit is unconditional: it is the only way to tell "the host
    // overrode the alias" from "the host left it at the default".
    for (self.lowered.aliases.items, 0..) |al, i| {
        const p = self.lowered.params.items[al.param];
        const ty = Analysis.tyOfParam(p.ty);
        try self.w("    {s}: {s} = {s}, // §3.4.7 alias of `{s}`\n", .{
            self.names.a_names[i],
            paramFieldType(self, p),
            try paramDefault(self, p, ty),
            p.name,
        });
    }
    // §9.19 the given flags, one bit each (`given_params` names them): a
    // byte per flag was 514 bytes of bsimcmg's Model row, 65 as bits.
    if (givenCount(self) != 0) try self.w(
        \\    /// §9.19 `$param_given`: bit k is set when the host's card named
        \\    /// `given_params[k]` (`setGiven`). `Model{{}}` has none set; `derive`
        \\    /// reads them and raises an alias's original.
        \\    given__: std.StaticBitSet({d}) = .empty,
        \\
    , .{givenCount(self)});
    // §9.15 the host-published simulation parameters. Model, not Instance:
    // each `.options` entry is one number per run. The initializer is the
    // default, for a host that never writes it.
    for (Lower.host_simparams) |h| if (self.lowered.uses.contains(h.use)) {
        try self.w("    {s}: f64 = {s}, // §9.15 $simparam(\"{s}\"){s} — host-written\n", .{
            h.field, try fmtF64(self, self.lowered.simparamValue(h.name).?), h.name, if (h.use == .host_tnom) ", degC" else "",
        });
    };
    // §5.6.5 the card-only retention flag of each collapsible switch branch,
    // which a guarded `jac_const` entry names (`contract.JacWhen`). Not a
    // parameter: `derive` overwrites it. The initializer is the flag at the
    // declared defaults when that folds, else NaN, so a host that skips
    // `derive` does not get a plausible 0.
    for (self.topo.cpairs, 0..) |p, k| {
        if (!p.card) continue;
        const d = if (self.an.foldConst(p.flag, true)) |f| try fmtF64(self, f.f) else kt.nan_lit;
        try self.w("    {s}: f64 = {s}, // §5.6.5 retention flag — `derive` writes it\n", .{ try gen_dispatch.guardField(self, @intCast(k)), d });
    }
    // §9.10 `$temperature`, kelvin: one number per Model row, so every value
    // `setup` derives from it is shared by the instances of that row. A host
    // simulating an instance at its own temperature gives it its own row.
    try self.w("    temperature__: f64 = 300.15, // §9.10 $temperature, kelvin — host-written\n", .{});
    // §9.19 which of the device's ports the host's card connects, bit p for
    // port p in declaration order; all ones (every port connected) unless the
    // host writes it. Read by `$port_connected` in setup, derive and eval, so
    // the host writes it with the card, before `derive`.
    if (self.lowered.uses.contains(.port_mask)) try self.w("    port_connected__: u64 = std.math.maxInt(u64), // §9.19 host-written connection mask\n", .{});
    // §9.15 Table 9-28 through the GPU-safe channel: indices into the host's
    // `contract.host_strings`, 0 ("not written") unless the host writes them,
    // beside the `Instance.cwd`/`analysis_name` slices a CPU host may write.
    if (self.lowered.uses.contains(.host_strings)) try self.w(
        "    cwd_idx__: u32 = 0, // §9.15 $simparam$str(\"cwd\"): index into contract.host_strings — host-written\n" ++
            "    analysis_name_idx__: u32 = 0, // §9.15 $simparam$str(\"analysis_name\"), §4.6.3: likewise\n",
        .{},
    );
    // §4.6.4.3 the row's own sorted copy of the card's noise-table knots
    // (`contract.noiseTable`), so it survives row sharing and copying. Not a
    // parameter: `derive` overwrites it. The initializer is the declared
    // defaults, `noise_tables` flattened, which is what `derive` computes
    // for a card that sets nothing.
    if (gen_noise.hasCardKnots(self)) {
        try self.w("    noise_table_points__: [{d}][2]f64 = .{{", .{gen_noise.cardKnotCount(self)});
        var first = true;
        for (self.noise.tabs) |pts| for (pts) |p| {
            try self.w("{s}.{{ {s}, {s} }}", .{ if (first) " " else ", ", try fmtF64(self, p[0]), try fmtF64(self, p[1]) });
            first = false;
        };
        try self.w(" }}, // §4.6.4.3 the card's knots, sorted — `derive` writes it\n", .{});
    }
    // The setup roots (`Setup`), LAST so a new parameter does not move them.
    // `su_ok` exists only where it is asserted: Debug, in a program that
    // asked for the contract's checks (`contract.validating`).
    if (self.su.vals.len != 0) try self.w(
        \\    /// The solve-invariant values `setup` fills and `eval` reads.
        \\    su: Setup = .{{}},
        \\    /// Set by `setup`; `eval` asserts it, so a forgotten `setup` panics
        \\    /// (safe builds of a program with `contract.validating`; else `void`).
        \\    su_ok: if (std.debug.runtime_safety and contract.validating) bool else void = if (std.debug.runtime_safety and contract.validating) false else {{}},
        \\
    , .{});
    // Declarations go after the fields (Zig allows none between them).
    try emitGiven(self);
    try self.w("}};\n\n", .{});
}

/// Emits `derive`, which recomputes every parameter whose value is not its
/// own (§6.3.4: "an update of gate_width ... automatically updates
/// gate_cap"). The host writes the model card, calls `derive`, then builds
/// instances. It rewrites a parameter whose default names another parameter
/// unless the host wrote it, and every §3.4.5 localparam unconditionally
/// ("shall not be directly modified"). Declaration order is dependency order
/// (a forward reference is E0314), so one pass suffices. `Model{}` is already
/// the spec default, so a host that overrides nothing need not call it.
fn emitDerive(self: *Gen) Error!void {
    const at = self.out.items.len;
    try self.w(
        \\/// §6.3.4 parameter dependence + §3.4.5 localparam. Call ONCE after
        \\/// writing the model card and before the first solve: the fields below
        \\/// are defined by expressions over other parameters, so they are not
        \\/// valid until the parameters they read have their final values.
        \\pub fn derive(comptime S: type, model: *Model) void {{
        \\
    , .{});
    const at_s = self.out.items.len - "S: type, model: *Model) void {\n".len;
    const body = self.out.items.len;
    // §3.4.7 first: an override written through the alias must be the
    // original's value before a §6.3.4 dependent parameter reads it. The
    // write sets the original too (#76): "the value of the parameter dtemp
    // ... is 5" after `.trise(5)`, so its own given bit (§9.19 `$param_given`,
    // and the §6.3.4 guard below that keeps a default from erasing it) is raised.
    for (self.lowered.aliases.items, 0..) |al, i| {
        const a = self.names.a_names[i];
        const p = self.names.p_names[al.param];
        const ab = self.names.n_given + i;
        if (self.names.p_given[al.param])
            try self.w("    if (model.given__.isSet({d})) {{\n        model.{s} = model.{s};\n        model.given__.set({d});\n    }}\n", .{ ab, p, a, self.names.given_bit[al.param] })
        else
            try self.w("    if (model.given__.isSet({d})) model.{s} = model.{s};\n", .{ ab, p, a });
    }
    // §3.4.1 an explicit `integer` parameter is a 32-bit value, but the host
    // writes the ABI's i64 carrier (4294967297 for 1). Reduce it here, once
    // per card, so every later read (a dependent default below, `setup`,
    // `checkShape`, `eval`) sees the low 32 bits and the hot loop pays nothing.
    // A field the range sized narrower (`intFieldType`) holds 32 bits or fewer.
    for (self.lowered.params.items, 0..) |p, i| {
        if (p.is_local or !p.integer32 or Analysis.tyOfParam(p.ty) != .int) continue;
        if (!std.mem.eql(u8, intFieldType(self, p), "i64")) continue;
        try self.w("    model.{0s} = @as(i32, @truncate(model.{0s}));\n", .{self.names.p_names[i]});
    }
    for (self.lowered.params.items, 0..) |p, i| {
        const ty = Analysis.tyOfParam(p.ty);
        // A string parameter has no arithmetic to redo; a string localparam
        // is left overridable rather than growing a second renderer for it.
        if (ty == .str) continue;
        // `resolve_params = false`: this folds only if the default is
        // self-contained, which is exactly "not derived from a parameter".
        if (self.an.foldConst(p.default, false) != null and !p.is_local) continue;
        // Render in the parameter's numeric domain. A known initializer
        // cannot stand in for a dependency that changes after a host write.
        const e = (if (ty == .int) try gen_host.i64Const(self, p.default, 0) else try gen_host.f64Const(self, p.default, 0, false)) orelse {
            // Defaults with no compile-time value retain W1050's explicit
            // host-supplied-value contract (for example $simparam("gmin")).
            if (!p.is_local and p.folded == null and self.an.foldConst(p.default, true) == null) continue;
            if (self.diags) |bag| try bag.add(.codegen, .E1004, self.lowered.tokenSpan(p.tok), "host derivation of `{s}` uses an unsupported expression; its declared value cannot be frozen after parameter overrides", .{p.name});
            return error.UnsupportedParameterDefault;
        };
        // §6.3.4 gives the default; an explicit host write wins (else a card's
        // `VTH0` over `VTH0 = VTHO` would be erased). Only a localparam is
        // overwritten unconditionally. `plan/names.zig` gave a given bit
        // to every non-local derived parameter.
        if (!p.is_local)
            try self.w("    if (!model.given__.isSet({d})) ", .{self.names.given_bit[i]})
        else
            try self.w("    ", .{});
        switch (ty) {
            .real => try self.w("model.{s} = {s};\n", .{ self.names.p_names[i], e }),
            .int => if (p.integer32)
                try self.w("model.{s} = @as(i32, @truncate({s}));\n", .{ self.names.p_names[i], e })
            else
                try self.w("model.{s} = {s};\n", .{ self.names.p_names[i], e }),
            .str => unreachable,
            .wide => unreachable, // `tyOfParam` types no parameter wide
        }
    }
    if (!try deriveFlags(self)) gen_unit.patchParam(self, at_s, "S".len);
    // §4.6.4.3 the card's noise-table knots, sorted, into the row: LAST, so
    // a knot that is a derived parameter reads its value from above.
    if (gen_noise.hasCardKnots(self)) try self.w("    model.noise_table_points__ = noiseTablePoints(model);\n", .{});
    if (self.out.items.len == body) return self.out.shrinkRetainingCapacity(at);
    try self.w("}}\n\n", .{});
}

/// Emits `checkShape`, which names the first shape parameter
/// (`ParamInfo.shape`, §3.2/§3.4) whose card value differs from the compiled
/// one, or returns null when the card fits. An array bound is laid out in the
/// generated text at compile time, so a card that moves it must be refused.
/// The host calls it after `derive`. No allocation or print, so it is safe in
/// a GPU build. Not emitted when no parameter shapes anything.
fn emitShapeCheck(self: *Gen) Error!void {
    const at = self.out.items.len;
    try self.w(
        \\/// §3.4 the shape parameters this device was compiled for: the name of
        \\/// the first one the card (after `derive`) sets to another value, or null.
        \\pub fn checkShape(model: *const Model) ?[]const u8 {{
        \\
    , .{});
    const body = self.out.items.len;
    for (self.lowered.params.items, 0..) |p, i| {
        if (!p.shape) continue;
        const ty = Analysis.tyOfParam(p.ty);
        if (ty == .str) {
            try self.w("    if (!std.mem.eql(u8, model.{s}, {s})) return \"{f}\";\n", .{ self.names.p_names[i], try paramDefault(self, p, ty), std.zig.fmtString(p.name) });
            continue;
        }
        // `derive` rewrites a localparam from its default; one that reads no
        // parameter is that constant every time and cannot disagree.
        if (p.is_local and self.an.foldConst(p.default, false) != null) continue;
        // §3.4.1 gives an explicit integer its low 32 bits even when the host
        // writes a wider carrier. Compare the value used by selection; a field
        // the range sized narrower (`intFieldType`) holds it already.
        if (ty == .int and p.integer32 and std.mem.eql(u8, intFieldType(self, p), "i64"))
            try self.w("    if (@as(i32, @truncate(model.{s})) != {s}) return \"{f}\";\n", .{ self.names.p_names[i], try paramDefault(self, p, ty), std.zig.fmtString(p.name) })
        else
            try self.w("    if (model.{s} != {s}) return \"{f}\";\n", .{ self.names.p_names[i], try paramDefault(self, p, ty), std.zig.fmtString(p.name) });
    }
    if (self.out.items.len == body) return self.out.shrinkRetainingCapacity(at);
    try self.w("    return null;\n}}\n\n", .{});
}

/// Emits `checkCard`, which names the first §9.18 hierarchical system
/// parameter whose card-dependent value (`Lowered.system_checks`) lies
/// outside Table 9-29's "Allowed values" ($mfactor > 0, $hflip/$vflip = ±1,
/// 0 <= $angle < 360), or returns null. A literal outside them is E0890 at
/// compile time; this is the same rule for a value the host writes. The host
/// calls it after `derive`. Not emitted when nothing is card-dependent.
fn emitCardCheck(self: *Gen) Error!void {
    const checks = self.lowered.system_checks.items;
    if (checks.len == 0) return;
    var body: std.ArrayList(u8) = .empty;
    for (checks) |c| {
        const v = try gen_host.f64Const(self, c.v, 0, false) orelse {
            if (self.diags) |bag| try bag.add(.codegen, .E1004, .{ .start = 0, .end = 0 }, "the card-time check of `{s}` uses an unsupported expression", .{c.name});
            return error.UnsupportedParameterDefault;
        };
        const out = switch (c.kind) {
            .mfactor => "!(v > 0.0)",
            .hflip, .vflip => "!(v == 1.0 or v == -1.0)",
            .angle => "!(v >= 0.0 and v < 360.0)",
            .xposition, .yposition => unreachable, // `Kind.constrained` records neither
        };
        try body.print(self.arena, "    {{\n        const v: f64 = {s};\n        if ({s}) return \"{f}\";\n    }}\n", .{ v, out, std.zig.fmtString(c.name) });
    }
    try self.w(
        \\/// §9.18 Table 9-29: the first hierarchical system parameter the card
        \\/// (after `derive`) puts outside its allowed values, or null.
        \\pub fn checkCard({s}: *const Model) ?[]const u8 {{
        \\
    , .{if (std.mem.find(u8, body.items, "model.") != null) "model" else "_"});
    try self.w("{s}    return null;\n}}\n\n", .{body.items});
}

/// Emits `checkRange`, which names the first §3.4 parameter whose value (after
/// `derive`) lies in none of its §3.4.2 `from` ranges or in one of its
/// `exclude` ranges, or returns null (#80). "It shall be an error only if the
/// value of the parameter is out of range during simulation": a `#(...)`
/// override is judged at compile time (E0361), a value the host writes on the
/// card only here. A range whose bounds do not fold over literals
/// (`Lowered.Range`), a string-set range and a string parameter are not
/// checked (VD-125). Not emitted when no parameter has a checkable range.
fn emitRangeCheck(self: *Gen) Error!void {
    var body: std.ArrayList(u8) = .empty;
    for (self.lowered.params.items, 0..) |p, i| {
        const ty = Analysis.tyOfParam(p.ty);
        if (ty == .str) continue;
        // `inside` ORs the `from` intervals (§3.4.2: several are a union);
        // `excluded` ORs the `exclude` ones. A `from` with an unfoldable bound
        // might admit any value, so it drops the whole `from` test.
        var inside: std.ArrayList(u8) = .empty;
        var excluded: std.ArrayList(u8) = .empty;
        var from_known = true;
        for (p.ranges) |r| {
            if (r.strings) continue;
            const lo = r.lo orelse {
                if (r.kind == .from) from_known = false;
                continue;
            };
            const hi = r.hi orelse {
                if (r.kind == .from) from_known = false;
                continue;
            };
            const list = switch (r.kind) {
                .from => &inside,
                .exclude => &excluded,
            };
            try list.print(self.arena, "{s}(v {s} {s} and v {s} {s})", .{
                if (list.items.len == 0) "" else " or ",
                if (r.lo_inclusive) ">=" else ">",
                try fmtF64(self, lo),
                if (r.hi_inclusive) "<=" else "<",
                try fmtF64(self, hi),
            });
        }
        if (!from_known) inside.clearRetainingCapacity();
        if (inside.items.len == 0 and excluded.items.len == 0) continue;
        try body.print(self.arena, "    {{\n        const v: f64 = {s}model.{s}{s};\n        if (", .{
            if (ty == .int) "@floatFromInt(" else "", self.names.p_names[i], if (ty == .int) ")" else "",
        });
        if (inside.items.len != 0) try body.print(self.arena, "!({s})", .{inside.items});
        if (inside.items.len != 0 and excluded.items.len != 0) try body.appendSlice(self.arena, " or ");
        try body.print(self.arena, "{s}) return \"{f}\";\n    }}\n", .{ excluded.items, std.zig.fmtString(p.name) });
    }
    if (body.items.len == 0) return;
    try self.w(
        \\/// §3.4.2 the declared `from`/`exclude` ranges: the first parameter the
        \\/// card (after `derive`) puts outside its range, or null.
        \\pub fn checkRange(model: *const Model) ?[]const u8 {{
        \\
    , .{});
    try self.w("{s}    return null;\n}}\n\n", .{body.items});
}

/// Emits `derive`'s §5.6.5 tail: every card-only retention flag into the
/// `Model` field `emitModel` declared for it, read from the core at x = 0 on a
/// scratch Instance (exact, since a card-only flag reads neither). Must follow
/// the parameter writes it reads. Returns whether it read the core, i.e. named `S`.
fn deriveFlags(self: *Gen) Error!bool {
    var any = false;
    for (self.topo.cpairs) |p| any = any or p.card;
    if (!any) return false;
    try self.w(
        \\    // §5.6.5 the published retention flags (`contract.JacWhen`).
        \\    const xr: [n_u]zOf(S, 0) = @splat(S.con(0.0));
        \\    var pin: Instance = .{{}};
        \\
    , .{});
    if (self.su.vals.len != 0) try self.w("    setup(S, model);\n", .{});
    try self.w("    _ = &pin;\n", .{});
    try self.w("    const m = core(S, xr, model, &pin, .{{}}{s});\n", .{self.heldArg(true)});
    for (self.topo.cpairs, 0..) |p, k| {
        if (!p.card) continue;
        const f = self.core.lo_idx[@backingInt(self.an.rv(p.flag))];
        if (self.an.vty[@backingInt(self.an.rv(p.flag))] == .int)
            try self.w("    model.{s} = @floatFromInt(m.f{d});\n", .{ try gen_dispatch.guardField(self, @intCast(k)), f })
        else
            try self.w("    model.{s} = m.f{d}.val();\n", .{ try gen_dispatch.guardField(self, @intCast(k)), f });
    }
    return true;
}

/// Warns W1050 for a parameter whose default nothing in the pipeline
/// evaluates: neither fold in `paramDefault` answers and `derive` cannot
/// render it (a ch9 call such as §9.10 `$temperature` or §9.18 `$simparam`,
/// which is not a §3.4.1 constant_expression). The field's `0` is then the
/// host's to overwrite. A warning, not a refusal, so a model whose default
/// reads a simulator quantity still compiles; `--deny=W1050` makes it strict.
fn checkParamDefault(self: *Gen, p: Lower.ParamInfo) Error!void {
    const bag = self.diags orelse return;
    if (!bag.enabled(.W1050)) return;
    if (p.folded != null or self.an.foldConst(p.default, true) != null) return;
    if (try gen_host.f64Const(self, p.default, 0, false) != null) return;
    var d = bag.build(.codegen, .W1050, self.lowered.tokenSpan(p.tok));
    d.msg("`{s}`", .{p.name});
    d.point("this default has no compile-time value, so the field is 0", .{});
    d.help("write the model card field before the first solve, or give `{s}` a constant default", .{p.name});
    try d.emit();
}

/// Returns the §3.4 field initializer: the parameter's value under the
/// declared defaults, which is what `Model{}` promises. Two folds answer it:
/// `ParamInfo.folded` (`Lower.constEval` over the AST, which sees through a
/// §4.2.12 `?:` that MIR has already turned into a CFG diamond) and
/// `foldConst` over the MIR. Integral defaults prefer the exact AST result.
fn paramDefault(self: *Gen, p: Lower.ParamInfo, want: VTy) Error![]const u8 {
    if (want == .int) if (p.folded) |k| {
        // An explicit `integer` (§3.4.1) is 32 bits: an integral default
        // keeps its low 32 bits, a real one saturates at the 32-bit bounds
        // (as the 64-bit carrier saturates for an inferred one).
        const value = switch (k) {
            .int => |v| if (p.integer32) @import("kernels").fold.wrap32(v) else v,
            .real => |v| if (p.integer32) std.math.lossyCast(i32, @round(v)) else std.math.lossyCast(i64, @round(v)),
            .str => 0,
        };
        return self.arena.print("{d}", .{value});
    };
    const c = self.an.foldConst(p.default, true);
    if (c == null) if (p.folded) |k| return switch (want) {
        .real => try fmtF64(self, k.asReal()),
        // From the i64 side: `folded` kept the integer, so nothing is rounded.
        // A real default on an integer parameter takes the same saturating
        // cast as the fold path below, because `Lower.Const.asInt` casts
        // unguarded.
        .int => try self.arena.print("{d}", .{switch (k) {
            .real => |r| std.math.lossyCast(i64, @round(r)),
            .int, .str => k.asInt(),
        }}),
        .str => switch (k) {
            .str => |s| try self.arena.print("\"{f}\"", .{std.zig.fmtString(s)}),
            else => "\"\"",
        },
        .wide => unreachable, // `tyOfParam` types no parameter wide
    };
    return switch (want) {
        .real => try fmtF64(self, if (c) |k| k.f else 0.0),
        // ponytail: a default with no AST fold (`p.folded`, which saturates an
        // explicit integer at 32 bits above) clamps to the i64 carrier
        // (`lossyCast`: NaN -> 0) instead of panicking the compiler, as the
        // fold (`fold.Const.asInt`) and the runtime `fi_cast` do; `derive` then
        // keeps an explicit integer's low 32 bits. §4.2.1.1 fixes no overflow
        // rule. Upgrade path: a lowering-time diagnostic on the default's span.
        .int => try self.arena.print("{d}", .{if (c) |k| std.math.lossyCast(i64, @round(k.f)) else 0}),
        .str => blk: {
            const def = self.mir.valueDef(self.an.rv(p.default));
            break :blk if (def == .str_const)
                try self.arena.print("\"{f}\"", .{std.zig.fmtString(def.str_const)})
            else
                "\"\"";
        },
        .wide => unreachable, // `tyOfParam` types no parameter wide
    };
}

/// Returns the Zig text of a float constant, memoized on its bit pattern.
/// Large models emit hundreds of thousands of constants with few distinct
/// texts. Keyed on `@bitCast`, not the `f64`: `-0.0` and `0.0` compare equal
/// but render differently, and NaN is not equal to itself. The text is
/// arena-owned and shared between calls.
pub fn fmtF64(self: *Gen, x: f64) Error![]const u8 {
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

test depublish {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // Only a leading `pub ` goes: a nested one is the kernel's own business.
    try depublish(gpa, &out, "pub fn a() void {}\npub const b = 1;\n    pub const c = 2;\nconst d = 3;");
    try std.testing.expectEqualStrings("fn a() void {}\nconst b = 1;\n    pub const c = 2;\nconst d = 3;", out.items);
}

test publish {
    const gpa = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    // Every top-level `fn`/`const` gains `pub`; a `var`, an indented line and
    // an already public one are left as they are.
    try publish(gpa, &out, "fn a() void {}\nconst b = 1;\nvar c = 2;\n    const d = 3;\npub fn e() void {}");
    try std.testing.expectEqualStrings("pub fn a() void {}\npub const b = 1;\nvar c = 2;\n    const d = 3;\npub fn e() void {}", out.items);
}
