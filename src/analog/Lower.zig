//! The lowering pass's state: an elaborated design (`elab`, §6.2.2) in, SSA
//! `Mir` plus the `Lowered` tables (`ir`) out. This file owns the pass's
//! fields, the entry point (`lower`), the diagnostics every sub-file reports
//! through, and the MIR helpers every sub-file emits through; the pass's order
//! is `module.zig`'s `lowerModule`, and each step lives in the file named for
//! the table it owns (the import list below is the map).
//!
//! `nodes` order is the solver-unknown order; keep it stable.
//!
//! Ownership: every `out` table has one writer, the sub-file named for it
//! (`out.nodes` node.zig, `out.params` param.zig, `out.held_vars` and
//! `out.mem_arrays` var.zig, `out.contributions` and `out.charge_sites`
//! contrib.zig, `out.displays` and the status channel systask.zig, ...;
//! `out.uses` is a flag set any of them may raise). The symbol tables follow
//! the same rule (`branches` and `node_voltages` node.zig, with §9.20's alias
//! rebinding in hier_name.zig; `param_index` param.zig; `access_kind`
//! discipline.zig). The context fields (`cur`, `vars`, `consts`, `arrays`,
//! `scope_log`, `loops`, `cond_depth`, `restrict`, `cur_unit`, `block_path`,
//! `scope_path`, `gen_iter`, `active_genvars`) belong to whichever construct
//! is being lowered: it sets them on entry and restores them on exit. Every
//! buffer lives in `arena`, for the whole pass; `opts` and `design` are read
//! only after they are set.
//!
//! Cites: §2.8.3 (`call`), §4.2.1 (the coercions re-exported from
//! coerce.zig), §5.9/§4.7.1 (`startUnreachable`), §6.2.2, §10.1-§10.3 and
//! §9.21.1 (`Options`), §3.4 (`ParamOverride`).
//!
//! Contents:
//! - `pub const Lowered`, `pub const Oom`, `pub const Error`
//! - `pub const ParamInfo`, `unnamed_branch`, `ground`, `none_u32`, `NodeKind`,
//!   `DeclMeta`, `VecRange`, `DisciplineInfo`, `Access`, `Kind`, `NoiseKind`,
//!   `NoiseSrc`, `ChargeSite`, `Ty`, `HeldVar`, `TpSlot`, `Const` (`Lowered`'s rows)
//! - `pub const ParamOverride`, `pub const BranchInfo = struct`
//! - `pub const TypedValue = struct`, `pub const poison: TypedValue`
//! - `pub const VarSlot = struct`, `pub const RegRange = struct`,
//!   `pub const ArrayInfo = struct` (with `pub const Mem = struct`), `pub const Accum = struct`
//! - `pub const Options = struct`, `pub const Output = struct`
//! - `pub const lowerFile`, `strToInt`, `strNum`, `toReal`, `toInt`,
//!   `coerceTo`, `toBool`, `unify`, `astTy` (methods from module.zig, coerce.zig)
//! - `pub const Harness`, `expectVerdict`, `expectBodyVerdict`, `Case`,
//!   `expectBodies` (test support, harness.zig)
//! - `pub const nodeName`, `dropHeld`, `simparamIsRuntime`, `host_simparams`
//! - `pub fn lower(arena, mir, file, src, tok_starts, bag, opts: Options) Error!Output`
//! - `pub fn init(arena, mir, file, src, tok_starts, bag) Lower`
//! - `pub fn deinit(self: *Lower) void`
//! - `pub fn tokenSpan(self: *const Lower, tok: u32) diag.Span`
//! - `pub fn tokStart(self: *const Lower, tok: u32) u32`
//! - `pub fn err(self: *Lower, tok: u32, code: diag.Code, comptime fmt, args) Oom!void`
//! - `pub fn errWith(self: *Lower, tok: u32, code: diag.Code) diag.Builder`
//! - `pub fn emit(self: *Lower, op: Mir.Opcode, ops: []const Mir.Value) Oom!Mir.Value`
//! - `pub fn call(self: *Lower, name: []const u8, args: []const Mir.Value) Oom!Mir.Value`
//! - `pub fn gotoBlock(self: *Lower, target: Mir.Block) Oom!void`
//! - `pub inline fn branchTo(self: *Lower, cond, then_b, else_b, comptime seal_else: bool) Oom!void`
//! - `pub fn startUnreachable(self: *Lower) Oom!void`
//! - `pub fn effectPlace(self: *Lower) Oom!Ssa.Place`
//! - `pub fn exprValid(self: *const Lower, e: Ast.ExprId) bool`
//! - `pub fn valueValid(self: *const Lower, v: Mir.Value) bool`
//! - `pub fn stmtCount(self: *const Lower) usize`
//! - `pub fn blockValid(self: *const Lower, b: Mir.Block) bool`
//! - `pub fn nodeValid(self: *const Lower, n: u32) bool`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const Preprocessor = @import("frontend").Preprocessor;
const Mir = @import("ir").Mir;
const Elaborate = @import("elab").Elaborate;
const diag = @import("diag");
const Ssa = @import("ssa.zig");
const lower_module = @import("module.zig");
const coerce = @import("coerce.zig");
const harness = @import("harness.zig");

// §7.2.2 the discrete context: which statements and nets are digital.
const lower_context = @import("context.zig");
// §3.6 disciplines and natures, §3.11 net compatibility.
const lower_discipline = @import("discipline.zig");
// §1.3.1 nodes: nets, ports, ground and the solver-unknown order.
const lower_node = @import("node.zig");
// §3.4 parameters and §2.9 attribute values.
const lower_param = @import("param.zig");
// §3.2 variables: scopes, storage and retention.
const lower_var = @import("var.zig");
// §3.2.2/§3.4.4 array shapes and §3.4.8 assignment patterns.
const lower_shape = @import("shape.zig");
// §5 analog statements: blocks, assignments, named blocks.
const lower_stmt = @import("stmt.zig");
// §5.6 contributions: `<+`, indirect contributions, switch branches.
const lower_contrib = @import("contrib.zig");
// §5.8 conditionals and §5.9 loops.
const lower_control = @import("control.zig");
// §5.10 analog events: `@(...)`, cross/above/timer, initial_step/final_step.
const lower_event = @import("event.zig");
// §4.2 expressions, §4.3 math functions, §4.4 signal access.
const lower_expr = @import("expr.zig");
// §4.5 analog operators and filters.
const lower_analog_op = @import("analog_op.zig");
// Clause 9 system functions in analog context, and their arguments.
const lower_sysfunc = @import("sysfunc.zig");
// Clause 9 system tasks: §9.4 display, §9.5 I/O, §9.7 status, §9.17 kernel control.
const lower_systask = @import("systask.zig");
// §9.13 probabilistic distributions.
const lower_random = @import("random.zig");
// §9.21 `$table_model`.
const lower_table_model = @import("table_model.zig");
// §9.17.3 `$limit`: the limiting-function call and its per-access state slot.
const lower_limit = @import("limit.zig");
// §9.16 `$simprobe` and §9.20 hierarchical reference strings.
const lower_hier_name = @import("hier_name.zig");
// §4.7 user-defined analog functions.
const lower_func = @import("func.zig");
// Constant evaluation: §4.2 constant_expression, §6.6.1 generate bounds.
const lower_constfold = @import("constfold.zig");
const lower_assign = @import("assign.zig");
const lower_static = @import("static.zig");
const lower_finite = @import("finite.zig");
const lower_source_check = @import("source_check.zig");
const lower_branch = @import("branch.zig");
const lower_accum = @import("accum.zig");
const lower_timer = @import("timer.zig");

/// What lowering produces (`ir`'s `Lowered`).
pub const Lowered = @import("ir").Lowered;
/// The one error that unwinds a lowering step: everything else goes in the
/// shared `diag.Bag` and lowering continues with a poison value, so one run
/// reports many errors.
pub const Oom = std.mem.Allocator.Error;
/// Every way `lower` fails. The arena keeps whatever was built; nothing is
/// returned to read.
pub const Error = Oom || error{
    /// At least one error diagnostic went to the bag.
    DiagnosticsReported,
    /// The file declares no module to lower (A.1.2).
    NoModule,
};

// `Lowered`'s row types, under the `Lower.X` names later stages and the
// sub-files use.
pub const ParamInfo = Lowered.ParamInfo;
pub const unnamed_branch = Lowered.unnamed_branch;
pub const ground = Lowered.ground;
pub const none_u32 = Lowered.none_u32;
pub const NodeKind = Lowered.NodeKind;
pub const DeclMeta = Lowered.DeclMeta;
pub const VecRange = Lowered.VecRange;
pub const DisciplineInfo = Lowered.DisciplineInfo;
pub const Access = Lowered.Access;
pub const Kind = Lowered.Kind;
pub const NoiseKind = Lowered.NoiseKind;
pub const NoiseSrc = Lowered.NoiseSrc;
pub const ChargeSite = Lowered.ChargeSite;
pub const Ty = Lowered.Ty;
pub const HeldVar = Lowered.HeldVar;
pub const TpSlot = Lowered.TpSlot;
pub const Const = Lowered.Const;

/// §3.4 "parameters can be modified at compilation time": the value a
/// `--param name=value` gives the top module's parameter `name`, in place of
/// its declaration value. A card is written in reals; `lowerParamDecl` converts.
pub const ParamOverride = Elaborate.ParamOverride;

/// A §3.12 named branch: a node pair carrying a flow and a potential.
pub const BranchInfo = struct {
    hi: u32, // `nodes` row
    lo: u32, // `nodes` row (`ground` if implicit, §1.3.1.1)
    /// §5.4.1 "There can be any number of named branches between any two
    /// signals", so the node pair does not identify the branch, and everything
    /// that retains a value per branch (§5.6.1.2/§5.6.1.3) has to key on this
    /// instead. One id per declared name, elements of a §3.12 branch array
    /// included: they are separate branches over one terminal pair.
    id: u32,
};

/// A lowered expression: its Value plus the LRM type that governs which opcode
/// family the *consumer* must use (§4.2.1.1–§4.2.1.3 implicit conversions).
pub const TypedValue = struct { v: Mir.Value, ty: Ty };

/// A poison real. Lowering continues so the run reports every error at once.
pub const poison: TypedValue = .{ .v = .undef, .ty = .real };

/// A visible variable: its SSA place and declared type.
pub const VarSlot = struct {
    place: Ssa.Place,
    ty: Ty,
    /// §7.3.1: retained declaration width, checked and zero-extended when
    /// analog code reads it. A register used only by digital code may be wider.
    reg_width: ?u32 = null,
    /// IEEE 1364-2005 §5.5.1: the `reg` was declared `signed`.
    reg_signed: bool = false,
};
/// A `reg`'s packed range as a select reads it (§7.3.1): the right-hand
/// bound (its LSB in either direction, IEEE 1364-2005 §4.2.1), the direction,
/// and the width.
pub const RegRange = struct { right: i64, asc: bool, width: u32, signed: bool = false };
/// A declared array's shape (§3.2), one `Bounds` per dimension, outermost
/// first. `dims.len` is the number of subscripts a reference must supply.
pub const ArrayInfo = struct {
    dims: []const lower_shape.Bounds,
    ty: Ty,
    /// §3.2.2 set for an array some subscript indexes at run time: its one
    /// SSA place holds the current array version (`Mir.Opcode.anew`/`store`)
    /// and `id` is its `out.mem_arrays` row. Null: scalarized, one place per
    /// element under `elemName`. See `lower_var.declareVarDecl`.
    mem: ?Mem = null,
    /// §3.4.4 an array parameter: its elements are `param_index` rows, and
    /// §5.7 lets only its declaration assign it.
    param: bool = false,
    /// A memory-backed array's SSA place and `out.mem_arrays` row.
    pub const Mem = struct { place: Ssa.Place, id: u32, reg_width: ?u32 = null };
};
/// A contribution's accumulator places. `wrote` is §5.6.1.3's retention flag:
/// 0.0 in the entry block, 1.0 after every `<+` on this (access, branch), back
/// to 0.0 when the opposite access discards it. It has the accumulator's phi
/// structure, so "was a value retained this cycle?" survives a conditional as
/// an ordinary SSA boolean; on a straight line it folds to a constant.
pub const Accum = struct { resist: Ssa.Place, react: Ssa.Place, wrote: Ssa.Place };

/// What only the driver knows. Every field defaults to "the driver said
/// nothing": no directives, no include path, no overrides.
pub const Options = struct {
    /// The positional directive events the preprocessor published
    /// (`Preprocessor.Directives`). A text stage cannot apply them itself:
    /// §10.2's default discipline needs the module's declarations, §10.3's
    /// default transition reaches only codegen (`defaultTransition`), and §9.15
    /// reads the timescale back. So they record where each took effect, and
    /// lowering applies them. Empty when the text never came through the
    /// preprocessor.
    directives: Preprocessor.Directives = .{},
    /// Where a §9.21.1 `$table_model` data file is looked for, in order: the
    /// `include` search path. Empty means the working directory only.
    include_dirs: []const []const u8 = &.{},
    /// §3.4 compile-time overrides of the top module's parameters.
    param_overrides: []const ParamOverride = &.{},
    /// §9.4 the build drops the display family (`codegen.Options.display`), so
    /// a variable those tasks read is not read at all in the device. The
    /// default, false, counts those reads. Only `lower_var.Exposed` asks: a §3.2
    /// hold that only a print could observe is no hold.
    displays_dropped: bool = false,
    /// §7.4.4's resolution mode.
    discipline_resolution: Elaborate.DisciplineResolution = .basic,
    /// §12.32.1 the user analog system functions a VPI application registered
    /// with sysfunctype vpiIntFunc: a call to one is an integer. Every other
    /// unresolved `$name` is real.
    int_systfs: []const []const u8 = &.{},
};

/// What `lower` returns: the tables every later stage reads, and the
/// elaborated design (§6) only the VPI's object model walks
/// (`vera.CompileResult` carries it), so `Lowered` holds no Ast.
pub const Output = struct {
    lowered: Lowered,
    /// The module lowered (§6.2): elaboration's flattened top.
    module: ?*const Ast.ModuleDecl,
    /// §9.15/§9.16, indexed by `Ast.AnalogBlock.unit`: the module a block was
    /// written in and the instance path it was inlined at (`Design.units`).
    unit_paths: []const Elaborate.UnitPath,
};

/// The pass's spine over an `init`ed Lower (module.zig): elaborates the file,
/// then lowers its one flat module.
pub const lowerFile = lower_module.lowerFile;
/// §4.2.1 coercions (coerce.zig), as methods.
pub const strToInt = coerce.strToInt;
pub const strNum = coerce.strNum;
pub const toReal = coerce.toReal;
pub const toInt = coerce.toInt;
pub const coerceTo = coerce.coerceTo;
pub const toBool = coerce.toBool;
pub const unify = coerce.unify;
pub const astTy = coerce.astTy;
/// Test support (harness.zig): one source in, a verdict out.
pub const Harness = harness.Harness;
pub const expectVerdict = harness.expectVerdict;
pub const expectBodyVerdict = harness.expectBodyVerdict;
pub const Case = harness.Case;
pub const expectBodies = harness.expectBodies;
/// A node's §1.3.1 display name, for diagnostics and tests.
pub const nodeName = lower_node.nodeName;
/// Applies `prove.setup.pruneHeld`'s held-row mask to `Lowered`.
pub const dropHeld = lower_var.dropHeld;
/// Reports whether a §9.15 simulation parameter is answered at run time.
pub const simparamIsRuntime = Lowered.simparamIsRuntime;
/// The §9.15 simulation parameters a host supplies, in `Model` field order.
pub const host_simparams = Lowered.host_simparams;

arena: std.mem.Allocator,
mir: *Mir,
/// Everything a later stage reads, built in place and returned by `lowerFile`
/// (lowered.zig). The fields below it are lowering's own.
out: Lowered,
/// Mutable only because `Elaborate.elaborate` appends to its stores (§6.7 flat
/// names, cloned rows) as the first step of `lowerFile`, before anything
/// caches an index into them. An overlay of the parse
/// (`Ast.SourceFile.overlay`), so those appends never reach the parse.
/// Lowering itself only reads.
file: *Ast.SourceFile,
/// The module being lowered (§6.2), elaboration's flattened top. Set by
/// `lowerModule`; `lower` hands it out beside `out` (`Output.module`).
module: ?*const Ast.ModuleDecl = null,
/// What only the driver knows, set once by `lower` and read-only after.
opts: Options = .{},
/// Elaboration's flat design (§6.2.2), set by `lowerFile` before the module
/// is lowered and read-only after. Its tables are the facts flattening knew
/// and erased from the AST: §9.15/§9.16's `units` (the module a block was
/// written in and the instance path it was inlined at), §6.4.3's paramset
/// outputs and hidden names, §6.8's renamed port variables, §5.4.3's split
/// port ammeters, §6.5.7.1's port concatenations and widths, §5.5.3's
/// attribute disciplines, §6.3.1/§6.4's forbidden defparams, §6.4.2's
/// selection parameters, §9.18's card-time checks and IEEE 1364 §19.9's
/// unconnected inputs. Before `lowerFile` every table is empty: the test
/// harness reaches constant folding without elaborating.
design: Elaborate.Design = .{ .top = undefined },
builder: Ssa.SsaBuilder,
/// The block statements are currently being appended to.
cur: Mir.Block = .entry,

/// Deduped `param_ref` Value per params[i] — parallel to `params`.
param_values: std.ArrayList(Mir.Value) = .empty,
branches: std.StringHashMapUnmanaged(BranchInfo) = .empty, // §3.12 named branches
/// §3.12.1 port branches: branch name → the port's `nodes` row. A table
/// of its own, not a flag on `BranchInfo`, because a port branch is not a node
/// pair: it is the §5.4.3 port flow under a second name.
port_branches: std.StringHashMapUnmanaged(u32) = .empty,
/// §1.3.1 net name → `nodes` row. Nets only: a §5.4.2/§5.4.3 flow unknown is
/// not reachable by name (`flow_unknowns` and `port_probes` are its identity).
node_voltages: std.StringHashMapUnmanaged(u32) = .empty,

// ---- internal lowering state (not part of the codegen contract) ----
/// Sub-file-private state: each is read and written by that one file only.
contrib_state: lower_contrib.State = .{},
node_state: lower_node.State = .{},
timer_state: lower_timer.State = .{},
systask_state: lower_systask.State = .{},
random_state: lower_random.State = .{},
var_state: lower_var.State = .{},
stmt_state: lower_stmt.State = .{},
table_model_state: lower_table_model.State = .{},
hier_name_state: lower_hier_name.State = .{},
static_state: lower_static.State = .{},
analog_op_state: lower_analog_op.State = .{},
/// Accumulator places, parallel to `contributions`.
accum: std.ArrayList(Accum) = .empty,
/// §1.3.1/§5.4.2.1 every access function read, in source order. A branch is a
/// probe only once the whole module has been lowered — a contribution to it may
/// come after the read — so the rule is a sweep over this at the end, not a
/// test at the read. Reads only: the left of a `<+` is a contribution.
branch_reads: std.ArrayList(BranchRead) = .empty,
/// §5.6.8.1 every potential `<+` spelled with hierarchical net references
/// (`V(drv.x)`, not §5.6.8.2's `V(drv.branch(x))`): each creates a new unnamed
/// branch in the writing instance, which `contribIndex` nonetheless merges
/// with the pair's accumulator. Kept so `lower_source_check.checkHierParallel` can
/// see the second branch the merge hides.
hier_potentials: std.ArrayList(lower_source_check.HierPotential) = .empty,
/// Preprocessed source, kept only so a token index can become a `diag.Span`
/// (`tokenSpan`, which proof.zig uses too).
src: []const u8 = "",
/// The lexer's per-token start offsets into `src`.
tok_starts: []const u32 = &.{},
/// Where every diagnostic of this compilation goes. Shared with the other
/// stages, so the cap, the dedupe and the source order are global.
bag: *diag.Bag = undefined,
/// Set by `err`; `lowerFile` reads it. Not `bag.entries.len`, which the cap
/// and the dedupe both make an unreliable answer to "did lowering fail".
had_error: bool = false,
/// §3.6.1.2 access identifier → which half of the discipline it reads.
access_kind: std.StringHashMapUnmanaged(Access) = .empty,
/// Access names one discipline binds to its potential and another to its flow
/// (annex D's `I` is `current`'s potential in some libraries). For these the
/// net's discipline decides the half, never `access_kind` (`accessOn`).
access_both: std.StringHashMapUnmanaged(void) = .empty,
/// Visible variables (§3.2) — locals, function args, scalarized array elements.
vars: std.StringHashMapUnmanaged(VarSlot) = .empty,
/// §5.4.1 each instance's share of an unnamed-branch contribution row
/// (`lower_accum.unitAccum`), keyed by the row and the owning unit.
unit_accum: std.AutoHashMapUnmanaged(struct { row: u32, unit: u32 }, Accum) = .empty,
/// Every scalar `reg` with a constant packed range, by the name in `vars`,
/// and every such `reg` a mixed module's analog block reads as a discrete
/// input (`Lowered.discrete_inputs`).
reg_ranges: std.StringHashMapUnmanaged(RegRange) = .empty,
/// §7.3.1 a `reg` wider than 32 bits whose analog-context value is its
/// literal initializer (`.none`: none, so zero) for the whole analysis: the
/// analog context assigns it nowhere. Its bits above 31 fold from the
/// literal (`lower_expr_select.lowerRegSelect`); any other such `reg` holds only
/// what a §3.2 integer computes.
reg_consts: std.StringHashMapUnmanaged(Ast.ExprId) = .empty,
/// §7.2.2 the names the module's analog blocks write (`lower_var.analogWrites`),
/// known before any variable is declared: a `reg` wider than 32 bits in it is
/// `Ty.wide`.
analog_writes: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty,
/// Undo log so named blocks (§5.3.2) and inlined functions (§4.7) can shadow.
scope_log: std.ArrayList(lower_var.ScopeEntry) = .empty,
/// §3.4 parameters and §3.5 genvars visible to constant evaluation.
consts: std.StringHashMapUnmanaged(Const) = .empty,
/// name → index into `params` (aliasparam §3.4.7 maps two names to one index).
param_index: std.StringHashMapUnmanaged(u32) = .empty,
/// §3.4.7/§9.18 top-level aliases share one model-card slot per system
/// parameter. Child aliases have already become instance-local values.
hier_params: @import("elab").hier_param.Aliases = .initFill(null),
/// Scalarized array bounds (§3.2.2 variables, §3.4.4 parameters).
arrays: std.StringHashMapUnmanaged(ArrayInfo) = .empty,
/// §4.6.4 the noise sources a variable holds, by name, for §4.6.4.6's
/// `n = white_noise(pwr); V(a,b) <+ c1*n;` shape, where `noiseSrcsOf`'s walk
/// of the contributed expression reaches only an identifier. Each entry is
/// the set of generators the name carries, with the `NoiseSrc.id` that makes
/// two uses of one name share one generator.
// ponytail: keyed by name and unioned, never cleared, so this is reaching
// rather than dataflow: a variable reassigned after holding a source still
// counts. The over-report is one extra topology row; the under-report would
// be a missing generator.
var_noise: std.StringHashMapUnmanaged([]const NoiseSrc) = .empty,
/// §4.6.4 the `(pwr, exp)` MIR values of every lowered noise call, by
/// `Ast.ExprId`. `lowerNoise` fills it; `noiseSrcsOf` walks the AST and reads
/// it back onto the `NoiseSrc` it appends.
noise_psd: std.AutoHashMapUnmanaged(u32, [2]Mir.Value) = .empty,
/// §4.6.4.3/.4 the same for the table forms: the flattened `f0, p0, f1, p1, …`
/// of `noise_table`'s vector argument, by `Ast.ExprId`. Absent or empty for the
/// clause's file-name form, which codegen reports.
noise_tab: std.AutoHashMapUnmanaged(u32, []const Mir.Value) = .empty,
/// §4.6.4 the result value of every lowered noise call, by `Ast.ExprId`: the
/// variable `noiseCoeff` differentiates a contribution with respect to.
noise_val: std.AutoHashMapUnmanaged(u32, Mir.Value) = .empty,
/// `contrib.scanFinite`'s per-value answers for the `<+` being checked;
/// cleared per statement, since a later alias can change a fold.
finite_scan: std.AutoHashMapUnmanaged(Mir.Value, lower_finite.FiniteScan) = .empty,
/// §5.9 break/continue targets.
loops: std.ArrayList(LoopCtx) = .empty,
/// `loops.items.len` when the innermost §5.9.3 analog_for being unrolled
/// began, or null outside one. A jump with no runtime loop pushed since is
/// inside the analog_for, §5.11's E0440.
analog_for_base: ?usize = null,
/// §5.3.2 "All identifiers declared within a named sequential block can be
/// accessed outside the scope in which they are declared." The qualified
/// `<label>.<local>` spellings `publishBlockLocals` bound, which is what tells
/// them apart from §6.7.1's forbidden cross-instance variable read (E0910).
block_locals: std.StringHashMapUnmanaged(void) = .empty,
/// §4.7.1 the function currently being inlined (return slot + exit block).
ret: ?RetCtx = null,
/// §4.7.2/§6.8 the local `parameter` declarations of the function currently
/// being inlined, empty outside one. Their values fold into `consts`
/// (`inlineUserFuncPre`); this slice is the mask `lookupName`/`foldExpr` consult
/// before `param_index`, because §6.8 makes the function a scope whose local
/// declaration shadows the module's parameter of the same name.
func_params: []const Ast.ParamDecl = &.{},
/// Nonzero while `lowerClog2` lowers its operand as a host card sets it
/// (docs/specification/Vague_Decisions.md VD-089): each `hostSizedParam` then reads as a
/// signed integer of this many bits instead of its declaration's width.
clog2_host: u8 = 0,
/// §4.7.1 recursion guard — names on the inline stack.
inlining: std.ArrayList([]const u8) = .empty,
/// Non-null inside an `analog initial` block (§5.2.1) or an analog function
/// (§4.7.2); names the context in the "not allowed here" diagnostic.
restrict: ?[]const u8 = null,
/// Retain evaluated runtime errors even when their arithmetic result is
/// unused, in the phase which executes them. Defaults have their own derive.
runtime_error_phase: enum { none, core, display } = .none,
/// Guard-aware source-order chain for captures and required runtime checks;
/// its final value is a core live-out.
table_effect_place: ?Ssa.Place = null,
/// True inside an `analog initial` block (§5.2.1) only; `restrict` also covers
/// analog functions, and §9.7.2's `$stop` rule keys on the narrower one. Not
/// cleared when a function is inlined: the call site is still "within an
/// analog initial block".
in_analog_initial: bool = false,
/// `Ast.AnalogBlock.unit` of the block being lowered: the module instance that
/// wrote it. Read by `discardOpposite` only; see `newContrib`.
cur_unit: u32 = 0,
/// §6.6.2 the flat prefixes of every unnamed generate block in the design
/// (`Elaborate.unnamedGenScopes`), built on the first hierarchical name
/// `lower_expr_name.refuseUnnamedGen` judges.
unnamed_gen: ?[]const []const u8 = null,
/// Index into the flat module's `analog` of the block being lowered, so a
/// read can tell which blocks are already behind it (`instancePortFlow`).
cur_block: usize = 0,
/// True while lowering the body of an `@(...)`, where the statement position is
/// A.6.4 `analog_event_statement` rather than `analog_statement`. The two
/// productions differ in both directions: `disable_statement`/`event_trigger` are legal only when it
/// is set, and `contribution_statement`/`indirect_contribution_statement` and a
/// nested `analog_event_control_statement` are legal only when it is clear
/// (§5.10 states the last three as prose restrictions as well).
in_event_stmt: bool = false,
/// Lowering the body of an explicit-D2A event control (§8.5.3.6): a digital
/// read there takes the region-1b snapshot (`Lowered.discrete_snaps`).
in_d2a_body: bool = false,
/// §5.6.7 "Indirect branch contributions shall not be used in conditional or
/// looping statements, unless the conditional expression is a constant
/// expression". Incremented only on paths that emit a branch; a constant-folded
/// `if` and an unrolled genvar `for` never come through `lowerCondBody`.
cond_depth: u32 = 0,
/// §5.8.1's carve-out, counted in parallel with `cond_depth`: how many of the
/// enclosing runtime conditionals had an A.8.3 `analysis_or_constant_expression`
/// for their condition. `cond_depth == static_cond_depth` therefore means
/// "every enclosing conditional is decided before the solve starts", which is
/// exactly when an analog operator's history stays whole (E0514).
///
/// A loop body never raises it: §5.9 bans analog filter functions in `repeat`,
/// `while` and non-genvar `for` with no carve-out, so a loop always leaves
/// `cond_depth > static_cond_depth`. Separate from `cond_depth` because
/// §5.6.7 and §5.8/§5.10.3.1 ask for a constant condition, which
/// `analysis("dc")` is not.
static_cond_depth: u32 = 0,
/// The SSA place of each `out.held_vars` row, parallel to it: the variable's
/// value during this evaluation, read back once into `HeldVar.final`.
held_places: std.ArrayList(Ssa.Place) = .empty,
/// Parallel to `out.limit_slots`: this evaluation's returned value. Seeded in
/// the entry block with the `$limit$old` read, overwritten by each site, and
/// read back at the end of the block, so a site under an `if` that does not
/// run leaves the slot holding what it held.
limit_places: std.ArrayList(Ssa.Place) = .empty,
/// Parallel to `out.charge_sites`: the site's charge during this evaluation,
/// seeded `.f_zero` in the entry block and read back into `ChargeSite.final`.
site_places: std.ArrayList(Ssa.Place) = .empty,
/// The `vera_lte` values of the enclosing statements, innermost last
/// (`lower_stmt.lowerStmt` pushes and pops). A `ddt`'s own suffix wins.
lte_stack: std.ArrayList(bool) = .empty,
/// The same for `vera_interp`: true where the enclosing statement asks for
/// quadratic `absdelay` interpolation (`lower_analog_op.absdelayQuad`).
interp_stack: std.ArrayList(bool) = .empty,
/// The same for `vera_nodiff`: true where assignments store no derivative
/// (`lower_assign.lowerAssign`).
nodiff_stack: std.ArrayList(bool) = .empty,
/// VerA's `vera_timepoint` (§2.9): the `out.timepoints` row of the statement
/// being lowered, null outside one. Inside, the constructs whose value moves
/// between Newton iterations are refused (E0530), and a nested
/// `vera_timepoint` adds nothing: the outer statement is cached whole.
tp_cur: ?u32 = null,
/// Parallel to `out.timepoints`: the place that is 1 once the statement ran,
/// read back into `Lowered.TpBlock.mark` at the end of the block.
tp_marks: std.ArrayList(Ssa.Place) = .empty,
/// §6.6.1/§5.9.3 genvars currently bound in `consts`, a stack pushed and
/// popped by `tryUnrollFor`. Exists so `queueDisplay` can snapshot the
/// bindings a deferred operand in an unrolled body was written under;
/// `tryUnrollFor` removes them from `consts` when the loop ends, which is
/// before `finishDisplays` re-lowers the operand.
active_genvars: std.ArrayList([]const u8) = .empty,
/// §5.3.2 the dotted prefix of the named block being lowered ("" at module
/// scope, "lo." inside `begin : lo`). The lowering-side half of `held_names`'
/// key; see `declareVarDecl`.
block_path: []const u8 = "",
/// §9.15 Table 9-28 "path": the scopes between the instance and the call
/// (named blocks and §6.6.3 generate blocks under their external names),
/// joined by §6.7's period, "" at the top of the instance. Unlike `block_path`
/// it is never a storage key.
scope_path: []const u8 = "",
/// §6.6.1 the genvar value of the loop-generate iteration whose block is about
/// to be lowered: `tryUnrollFor` sets it, `lowerSeqBlock` takes it, so the
/// block's scope is `name[i]`.
gen_iter: ?i64 = null,
/// §7.3.1 the digital arrays the analog block reads, each one input per
/// element (`lower_context.declareDiscreteArray`): name → declared bounds.
discrete_arrays: std.StringHashMapUnmanaged(struct { lo: i64, hi: i64 }) = .empty,
/// A.6.2 the digital `initial` block's assignments, name -> the constant
/// expression it leaves in that variable. Collected before the module's
/// variables are declared, for the same reason `held_names` is: the value a
/// variable starts every evaluation with is decided at its declaration.
/// Empty for a module with no `initial` block. See `collectInitialState`.
initial_state: std.StringArrayHashMapUnmanaged(struct { value: Ast.ExprId, tok: u32 }) = .empty,
/// §5.10.4 named events, name -> the flag slot `-> ev` writes and `@(ev)` reads.
/// Its own map and not `vars`, because §2.8 gives an event a name but no value:
/// `x = tick;` has no derivation, and putting the flag in `vars` would give it
/// one.
events: std.StringHashMapUnmanaged(Ssa.Place) = .empty,
/// §5.10.4 `event_identifier { dimension }`: an event array's shape. Each
/// element is its own `events` row under its scalarized key (`ev[0]`).
event_arrays: std.StringHashMapUnmanaged([]const lower_shape.Bounds) = .empty,
/// §5.6.6 the branch a `<+` right-hand side is being lowered for, null outside
/// one. For the implicit form `I(b) <+ f(I(b))`, the rhs read is the branch-flow
/// unknown of the implicit equation, not the §5.6.1.2 accumulator, which
/// mid-statement still lacks this statement's term. See `lowerBranchAccess`.
contrib_target: ?lower_branch.Target = null,
/// The number of `lowerExpr` frames on the stack: the walk's recursion depth,
/// asserted below the expression table's size (expr.zig's header).
expr_depth: u32 = 0,
/// The number of `lowerStmt` frames on the stack, asserted below twice the
/// statement table's size (stmt.zig's `lowerStmt`).
stmt_depth: u32 = 0,

const Lower = @This();

/// §5.4.2.1 one access function read, kept for the end-of-module probe sweep.
const BranchRead = struct { access: Access, hi: u32, lo: u32, tok: u32 };
/// §5.9 one enclosing loop's `break` and `continue` targets.
const LoopCtx = struct { brk: Mir.Block, cont: Mir.Block };
/// §4.7.1 the function being inlined: its return slot and exit block.
const RetCtx = struct { slot: VarSlot, exit: Mir.Block };

// Budgets (64-bit host) of the rows lowering keeps one of per value or per
// variable: `TypedValue` is every expression's result, `VarSlot` a `vars`
// value (~1.5k on psp103), `BranchRead` one per access-function read.
comptime {
    assert(@sizeOf(TypedValue) == 8);
    assert(@sizeOf(VarSlot) == 16);
    assert(@sizeOf(BranchRead) == 16);
    assert(@sizeOf(Accum) == 12);
    assert(@sizeOf(LoopCtx) == 8);
}

/// Lowers `file` into the empty `mir`. Retains nothing: the SSA builder's map
/// is gone on return, so everything returned lives in `arena`.
/// Returns `error.DiagnosticsReported` when any error went to `bag`.
pub fn lower(
    arena: std.mem.Allocator,
    mir: *Mir,
    file: *Ast.SourceFile,
    src: []const u8,
    tok_starts: []const u32,
    bag: *diag.Bag,
    opts: Options,
) Error!Output {
    var self = init(arena, mir, file, src, tok_starts, bag);
    self.opts = opts;
    defer {
        self.deinit();
        assert(self.builder.dir.items.len == 0);
    }
    const out = try lower_module.lowerFile(&self);
    assert(out.num_ports <= out.nodes.len);
    return .{ .lowered = out, .module = self.module, .unit_paths = self.design.units };
}

/// Returns a lowering pass over `file` into `mir`. Asserts that `mir` is empty
/// (this pass owns block 0). `file` and its strings are borrowed and must
/// outlive the Lower. Prefer `lower`, which also frees the SSA builder.
pub fn init(
    arena: std.mem.Allocator,
    mir: *Mir,
    file: *Ast.SourceFile,
    src: []const u8,
    tok_starts: []const u32,
    bag: *diag.Bag,
) Lower {
    assert(mir.blockCount() == 0);
    // Every token starts inside the text it was lexed from.
    if (tok_starts.len != 0) assert(tok_starts[tok_starts.len - 1] <= src.len);
    return .{
        .arena = arena,
        .mir = mir,
        .file = file,
        .out = .{},
        .src = src,
        .tok_starts = tok_starts,
        .bag = bag,
        .builder = Ssa.SsaBuilder.init(arena, mir),
    };
}

/// Frees the SSA builder's `(place, block)` map, the one table an arena
/// cannot reclaim. Every other table lives in `arena`.
pub fn deinit(self: *Lower) void {
    assert(self.expr_depth == 0); // no expression walk is mid-flight
    assert(self.stmt_depth == 0);
    assert(self.static_cond_depth <= self.cond_depth);
    self.builder.deinit();
}

/// Returns the byte range of a token, the unit every diagnostic reports in.
pub fn tokenSpan(self: *const Lower, tok: u32) diag.Span {
    const span = Lexer.tokenSpan(self.src, self.tok_starts, tok);
    assert(span.start <= span.end);
    assert(span.end <= self.src.len);
    return span;
}

/// Returns where `tok` starts in the preprocessed text, the offset §10.1's
/// positional directives are published in (what a `Region` lookup takes).
/// Zero for a token index never lexed, which answers with each directive's
/// default.
pub fn tokStart(self: *const Lower, tok: u32) u32 {
    const start = if (tok < self.tok_starts.len) self.tok_starts[tok] else 0;
    assert(start <= self.src.len);
    if (tok >= self.tok_starts.len) assert(start == 0);
    return start;
}

/// Records an error and keeps going. Callers substitute a poison value;
/// nothing downstream runs because `lowerFile` fails at the end.
pub fn err(self: *Lower, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Oom!void {
    assert(@tagName(code)[0] == 'E'); // a warning goes to `bag` directly: it fails nothing
    self.had_error = true;
    try self.bag.add(.lower, code, self.tokenSpan(tok), fmt, args);
    assert(self.had_error);
}

/// Starts an error that wants a label, a note or a suggestion. The caller
/// must `emit()` it.
pub fn errWith(self: *Lower, tok: u32, code: diag.Code) diag.Builder {
    assert(@tagName(code)[0] == 'E'); // as `err`
    self.had_error = true;
    const b = self.bag.build(.lower, code, self.tokenSpan(tok));
    assert(self.had_error);
    return b;
}

/// Appends `op` to the current block (`Mir.emit`).
pub fn emit(self: *Lower, op: Mir.Opcode, ops: []const Mir.Value) Oom!Mir.Value {
    assert(self.blockValid(self.cur));
    for (ops) |o| assert(self.valueValid(o));
    const v = try self.mir.emit(self.arena, self.cur, op, ops);
    assert(self.valueValid(v));
    return v;
}

/// Appends a call to `name` in the current block (`Mir.emitCall`).
pub fn call(self: *Lower, name: []const u8, args: []const Mir.Value) Oom!Mir.Value {
    // §2.8.3 a `$name` no clause defines is the host's: the device owes it
    // an `Instance.systf` binding (`Uses.systf`).
    assert(name.len != 0);
    assert(self.blockValid(self.cur));
    if (Mir.Callee.fromName(name) == .systf) self.out.uses.insert(.systf);
    const callee = try self.mir.internString(self.arena, name);
    const v = try self.mir.emitCall(self.arena, self.cur, callee, args);
    assert(self.valueValid(v));
    return v;
}

/// Closes `self.cur` with a jump and registers the CFG edge. `target` must not
/// be sealed yet.
pub fn gotoBlock(self: *Lower, target: Mir.Block) Oom!void {
    assert(self.blockValid(target));
    assert(self.blockValid(self.cur));
    _ = try self.mir.emitJump(self.arena, self.cur, target);
    try self.builder.addPredecessor(target, self.cur);
}

/// Closes `self.cur` with a branch, registers both edges, and seals `then_b`
/// (and `else_b` when `seal_else`). A loop leaves its exit unsealed until its
/// body has registered any `break` predecessors.
pub inline fn branchTo(self: *Lower, cond: Mir.Value, then_b: Mir.Block, else_b: Mir.Block, comptime seal_else: bool) Oom!void {
    assert(self.valueValid(cond));
    assert(self.blockValid(then_b));
    assert(self.blockValid(else_b));
    _ = try self.mir.emitBranch(self.arena, self.cur, cond, then_b, else_b);
    try self.builder.addPredecessor(then_b, self.cur);
    try self.builder.addPredecessor(else_b, self.cur);
    try self.builder.sealBlock(then_b);
    if (seal_else) try self.builder.sealBlock(else_b);
}

/// Starts a fresh predecessor-less block. Everything appended to it is dead
/// (post-`break`/`return` code, §5.9/§4.7.1); sealing it immediately keeps the
/// SSA builder from ever waiting on an edge that will not arrive.
pub fn startUnreachable(self: *Lower) Oom!void {
    const blocks = self.mir.blockCount();
    const b = try self.mir.addBlock(self.arena);
    try self.builder.sealBlock(b);
    self.cur = b;
    assert(self.mir.blockCount() == blocks + 1);
    assert(@backingInt(self.cur) == blocks);
}

/// Returns `table_effect_place`, creating it on first use seeded `.f_zero` in
/// the entry block. Its sum is never observed; what codegen keeps alive is the
/// dependencies and CFG edges it carries (`Lowered.table_effect`).
pub fn effectPlace(self: *Lower) Oom!Ssa.Place {
    if (self.table_effect_place) |p| return p;
    assert(self.mir.blockCount() != 0); // the entry block the seed goes in
    const p = self.builder.newPlace();
    try self.builder.writeVariable(p, .entry, .f_zero);
    self.table_effect_place = p;
    assert(self.table_effect_place != null);
    return p;
}

/// Reports whether `e` names a row of this file's expression table; `.none`
/// does not. For the sub-files' entry asserts.
pub fn exprValid(self: *const Lower, e: Ast.ExprId) bool {
    return @backingInt(e) < self.file.exprs.len();
}

/// Reports whether `v` is a sentinel constant or a row this pass's `mir`
/// numbered. For the sub-files' exit asserts.
pub fn valueValid(self: *const Lower, v: Mir.Value) bool {
    return @backingInt(v) < Mir.Value.first_dynamic + self.mir.defs.len;
}

/// Returns how many statement rows `file` holds, its parse's included (an
/// overlay's `StmtId`s number the base's rows first).
pub fn stmtCount(self: *const Lower) usize {
    const base = if (self.file.base) |b| b.stmts.items.len else 0;
    return base + self.file.stmts.items.len;
}

/// Reports whether `b` is a block this pass's `mir` holds.
pub fn blockValid(self: *const Lower, b: Mir.Block) bool {
    return @backingInt(b) < self.mir.blockCount();
}

/// Reports whether `n` is ground or a row of `out.nodes`.
pub fn nodeValid(self: *const Lower, n: u32) bool {
    return n == ground or n < self.out.nodes.len;
}

// ---- private ----

test {
    _ = lower_context;
    _ = lower_discipline;
    _ = lower_node;
    _ = lower_param;
    _ = lower_var;
    _ = lower_shape;
    _ = lower_stmt;
    _ = lower_contrib;
    _ = lower_control;
    _ = lower_event;
    _ = lower_expr;
    _ = lower_analog_op;
    _ = lower_sysfunc;
    _ = lower_systask;
    _ = lower_random;
    _ = lower_table_model;
    _ = lower_limit;
    _ = lower_hier_name;
    _ = lower_func;
    _ = lower_constfold;
    _ = lower_module;
    _ = coerce;
    _ = harness;
    _ = Lowered;
}
