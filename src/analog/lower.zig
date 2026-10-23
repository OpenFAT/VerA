//! AST → MIR lowering: elaborates the file (§6), then lowers the device
//! module's declarations and analog blocks into `Mir` plus the `Lowered` side
//! tables (params, nodes, branches, contributions, held state) every later
//! stage reads. Covers most of LRM ch3-5 and ch9 in analog context.
//!
//! The spine is `lower` → `lowerFile` → `lowerModule`, and `lowerModule` reads
//! as the order of the pass: disciplines, parameters, ports and nets, branches,
//! variables, the analog blocks, then the end-of-block reads and finishers.
//! Each step lives in the `analog/*.zig` file named for the table it owns (the
//! map at the bottom of this file); a sub-file's private state is a `State` on
//! `Lower` that only that file touches. This file holds what every sub-file
//! shares: the state, the diagnostics, the MIR helpers and the §4.2.1 type
//! coercions. The aliases at the bottom are what other modules call.
//!
//! `nodes` order is the solver-unknown order; keep it stable.
//!
//! LRM clauses this file's code cites: §1.3.1, §1.3.1.1, §2.7, §2.8, §2.9,
//! §2.9.2, §3.2, §3.2.2, §3.3, §3.4, §3.4.1, §3.4.4, §3.4.7, §3.4.8, §3.5,
//! §3.6, §3.6.1, §3.6.1.2, §3.6.2, §3.6.3, §3.6.4, §3.6.5, §3.11, §3.12,
//! §3.12.1, §3.13, §4.2, §4.2.1, §4.2.1.1, §4.2.1.2, §4.2.1.3, §4.2.8, §4.2.13,
//! §4.3, §4.4, §4.5, §4.5.2, §4.6.4, §4.6.4.3, §4.6.4.6, §4.7, §4.7.1, §4.7.2,
//! §4.7.3, §5, §5.2, §5.2.1, §5.3.2, §5.4.1, §5.4.2, §5.4.2.1, §5.4.3, §5.5.3,
//! §5.6, §5.6.1.2, §5.6.1.3, §5.6.6, §5.6.7, §5.6.8.1, §5.6.8.2, §5.7, §5.8,
//! §5.8.1, §5.9, §5.9.3, §5.10, §5.10.3.1, §5.10.4, §5.11, §6.2, §6.2.2,
//! §6.3.1, §6.3.4, §6.4, §6.4.2, §6.4.3, §6.5, §6.5.2.2, §6.5.7.1, §6.6.1,
//! §6.6.2, §6.6.3, §6.7, §6.7.1, §6.8, §6.9, §6.9.1, §7.2.2, §7.3.1, §7.3.6.5,
//! §7.4, §7.4.4, §8.5.3.5, §8.5.3.6, §9.4, §9.4.1, §9.5, §9.7, §9.7.2, §9.13,
//! §9.15, §9.16, §9.17, §9.17.3, §9.18, §9.20, §9.21, §9.21.1, §10.1, §10.2,
//! §10.3, §12.32.1.
//! IEEE 1364-2005 clauses cited: §4.2.1, §5.5.1, §19.1, §19.2, §19.8, §19.9.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Ssa = @import("ssa.zig");
const Elaborate = @import("elab").Elaborate;
const Lexer = @import("frontend").Lexer;
const Preprocessor = @import("frontend").Preprocessor;
const constfold = @import("frontend").constfold;
const diag = @import("diag");
const assert = std.debug.assert;

const Lower = @This();
/// What lowering produces (lowered.zig).
pub const Lowered = @import("ir").Lowered;

/// Only OOM unwinds during lowering; everything else goes in the shared
/// `diag.Bag` and lowering continues with a poison value, so one run reports
/// many errors.
pub const Oom = std.mem.Allocator.Error;
/// `lowerFile`'s errors: OOM, "diagnostics were reported", or no module to lower.
pub const Error = Oom || error{ DiagnosticsReported, NoModule };

// `Lowered`'s row types (lowered.zig), under the `Lower.X` names later
// stages and the sub-files use.
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

// ---------------------------------------------------------------------------
// Lowering's own types: never reach a later stage
// ---------------------------------------------------------------------------

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

/// §5.4.2.1 one access function read, kept for the end-of-module probe sweep.
const BranchRead = struct { access: Access, hi: u32, lo: u32, tok: u32 };

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
const LoopCtx = struct { brk: Mir.Block, cont: Mir.Block };
const RetCtx = struct { slot: VarSlot, exit: Mir.Block };
/// A contribution's accumulator places. `wrote` is §5.6.1.3's retention flag:
/// 0.0 in the entry block, 1.0 after every `<+` on this (access, branch), back
/// to 0.0 when the opposite access discards it. It has the accumulator's phi
/// structure, so "was a value retained this cycle?" survives a conditional as
/// an ordinary SSA boolean; on a straight line it folds to a constant.
pub const Accum = struct { resist: Ssa.Place, react: Ssa.Place, wrote: Ssa.Place };

// Budgets (64-bit host) of the rows lowering keeps one of per value or per
// variable: `TypedValue` is every expression's result, `VarSlot` a `vars`
// value (~1.5k on psp103), `BranchRead` one per access-function read.
comptime {
    assert(@sizeOf(TypedValue) == 8);
    assert(@sizeOf(VarSlot) == 16);
    assert(@sizeOf(BranchRead) == 16);
    assert(@sizeOf(Accum) == 12);
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
//
// Ownership: every `out` table has one writer, the sub-file named for it
// (`out.nodes` node.zig, `out.params` param.zig, `out.held_vars` and
// `out.mem_arrays` var.zig, `out.contributions` and `out.charge_sites`
// contrib.zig, `out.displays` and the status channel systask.zig, ...;
// `out.uses` is a flag set any of them may raise). The symbol tables below
// follow the same rule (`branches` and `node_voltages` node.zig, with §9.20's
// alias rebinding in hier_name.zig; `param_index` param.zig; `access_kind`
// discipline.zig). The context fields (`cur`, `vars`, `consts`, `arrays`,
// `scope_log`, `loops`, `cond_depth`, `restrict`, `cur_unit`, `block_path`,
// `scope_path`, `gen_iter`, `active_genvars`) belong to whichever construct is
// being lowered: it sets them on entry and restores them on exit. Every
// buffer lives in `arena`, for the whole pass.

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
/// §9.15/§9.16, indexed by `Ast.AnalogBlock.unit`: the module a block was
/// written in and the instance path it was inlined at. Flattening erases both,
/// so elaboration publishes them (`Design.units`); `$simparam$str` and the
/// VPI (`Output.unit_paths`) read them.
unit_paths: []const Elaborate.UnitPath = &.{},
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
event_state: lower_event.State = .{},
systask_state: lower_systask.State = .{},
random_state: lower_random.State = .{},
var_state: lower_var.State = .{},
stmt_state: lower_stmt.State = .{},
table_model_state: lower_table_model.State = .{},
hier_name_state: lower_hier_name.State = .{},
control_state: lower_control.State = .{},
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
/// with the pair's accumulator. Kept so `lower_contrib.checkHierParallel` can
/// see the second branch the merge hides.
hier_potentials: std.ArrayList(lower_contrib.HierPotential) = .empty,
/// Preprocessed source, kept only so a token index can become a `diag.Span`
/// (`tokenSpan`, which proof.zig uses too).
src: []const u8 = "",
/// The lexer's per-token start offsets into `src`.
tok_starts: []const u32 = &.{},
/// The positional directive events the preprocessor published
/// (`Preprocessor.Directives`), set through `Options`. A text stage cannot
/// apply them itself: §10.2's default discipline needs the module's
/// declarations, §10.3's default transition reaches only codegen
/// (`defaultTransition`), and §9.15 reads the timescale back. So they record
/// where each took effect, and lowering applies them. Empty when the text never
/// came through the preprocessor.
directives: Preprocessor.Directives = .{},
/// `Elaborate.Design.unconnected_inputs`, held between `lowerFile` (which has
/// the design) and `lowerModule` (which has the nodes `drives` applies to).
unconnected_inputs: []const Elaborate.NameSite = &.{},
/// `Elaborate.Design.port_concats`, held for `lowerModule` the same way.
port_concats: []const Elaborate.PortConcat = &.{},
/// `Elaborate.Design.port_widths`, held for `lowerModule` the same way.
port_widths: []const Elaborate.PortWidth = &.{},
/// §5.5.3 source-segment disciplines for attributes cloned across a port.
attribute_disciplines: std.AutoHashMapUnmanaged(Ast.ExprId, Ast.StrId) = .empty,
/// `Elaborate.Design.local_accesses`: accesses `checkAccessMatch` leaves alone.
local_accesses: std.AutoHashMapUnmanaged(Ast.ExprId, void) = .empty,
/// `Elaborate.Design.port_disciplines`, for `checkAccessMatch`.
port_disciplines: std.StringHashMapUnmanaged([]const u8) = .empty,
/// Where every diagnostic of this compilation goes. Shared with the other
/// stages, so the cap, the dedupe and the source order are global.
bag: *diag.Bag = undefined,
/// Set by `err`; `lowerFile` reads it. Not `bag.entries.len`, which the cap
/// and the dedupe both make an unreliable answer to "did lowering fail".
had_error: bool = false,
/// §3.6.1.2 access identifier → which half of the discipline it reads.
access_kind: std.StringHashMapUnmanaged(Access) = .empty,
/// Visible variables (§3.2) — locals, function args, scalarized array elements.
vars: std.StringHashMapUnmanaged(VarSlot) = .empty,
/// §5.4.1 each instance's share of an unnamed-branch contribution row
/// (`lower_contrib.unitAccum`), keyed by the row and the owning unit.
unit_accum: std.AutoHashMapUnmanaged(struct { row: u32, unit: u32 }, Accum) = .empty,
/// Every scalar `reg` with a constant packed range, by the name in `vars`,
/// and every such `reg` a mixed module's analog block reads as a discrete
/// input (`Lowered.discrete_inputs`).
reg_ranges: std.StringHashMapUnmanaged(RegRange) = .empty,
/// §7.3.1 a `reg` wider than 32 bits whose analog-context value is its
/// literal initializer (`.none`: none, so zero) for the whole analysis: the
/// analog context assigns it nowhere. Its bits above 31 fold from the
/// literal (`lower_expr.lowerRegSelect`); any other such `reg` holds only
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
finite_scan: std.AutoHashMapUnmanaged(Mir.Value, lower_contrib.FiniteScan) = .empty,
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
/// Where a §9.21.1 `$table_model` data file is looked for, in order: the
/// `include` search path, set through `Options`. Empty means the working
/// directory only.
include_dirs: []const []const u8 = &.{},
/// §3.4 compile-time overrides of the top module's parameters, set through `Options`.
param_overrides: []const ParamOverride = &.{},
/// True inside an `analog initial` block (§5.2.1) only; `restrict` also covers
/// analog functions, and §9.7.2's `$stop` rule keys on the narrower one. Not
/// cleared when a function is inlined: the call site is still "within an
/// analog initial block".
in_analog_initial: bool = false,
/// §9.4 the build drops the display family (`codegen.Options.display`), so a
/// variable those tasks read is not read at all in the device. Set through
/// `Options`; the default, false, counts those reads. Only `lower_var.Exposed`
/// asks: a §3.2 hold that only a print could observe is no hold.
displays_dropped: bool = false,
/// §7.4.4's resolution mode (`Options.discipline_resolution`).
discipline_resolution: Elaborate.DisciplineResolution = .basic,
/// §12.32.1 the user analog system functions a VPI application registered
/// with sysfunctype vpiIntFunc (`Options.int_systfs`): a call to one is an
/// integer. Every other unresolved `$name` is real.
int_systfs: []const []const u8 = &.{},
/// `Ast.AnalogBlock.unit` of the block being lowered: the module instance that
/// wrote it. Read by `discardOpposite` only; see `newContrib`.
cur_unit: u32 = 0,
/// §6.6.2 the flat prefixes of every unnamed generate block in the design
/// (`Elaborate.unnamedGenScopes`), built on the first hierarchical name
/// `lower_expr.refuseUnnamedGen` judges.
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
/// (`lower_stmt.lowerAssign`).
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
/// §6.4.3 `Elaborate.Design.ps_hidden`: module output variables a paramset
/// makes unavailable, by flat name. Read by `lowerSimprobe`.
ps_hidden: []const []const u8 = &.{},
/// §6.8 `Elaborate.Design.port_vars`: output-port variables renamed onto
/// the parent's net. Read by `lower_var.checkOneItemPerScope`.
port_vars: []const Ast.StrId = &.{},
/// §6.4.3 `Elaborate.Design.ps_outputs`: paramset output variables, reported
/// under the instance's name by §9.16's `$simprobe`.
ps_outputs: []const Elaborate.PsOutput = &.{},
/// §6.3.1/§6.4 forbidden defparams, awaiting final generate-scheme values.
paramset_defparams: []const Elaborate.ParamsetDefparam = &.{},
/// §6.4.2 parameters whose values selected an overloaded paramset.
selection_params: []const Ast.StrId = &.{},
/// §9.18 card-dependent system parameter values (`Elaborate.Design.system_checks`).
system_checks: []const Elaborate.SystemCheck = &.{},
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
contrib_target: ?lower_contrib.Target = null,

// ---------------------------------------------------------------------------
// The spine: lifecycle, then elaboration and the module (LRM ch6)
// ---------------------------------------------------------------------------

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
    self.builder.deinit();
}

/// What only the driver knows; each field documents the `Lower` field it sets.
pub const Options = struct {
    directives: Preprocessor.Directives = .{},
    include_dirs: []const []const u8 = &.{},
    param_overrides: []const ParamOverride = &.{},
    displays_dropped: bool = false,
    discipline_resolution: Elaborate.DisciplineResolution = .basic,
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
    self.directives = opts.directives;
    self.include_dirs = opts.include_dirs;
    self.param_overrides = opts.param_overrides;
    self.displays_dropped = opts.displays_dropped;
    self.discipline_resolution = opts.discipline_resolution;
    self.int_systfs = opts.int_systfs;
    defer {
        self.deinit();
        assert(self.builder.dir.items.len == 0);
    }
    const out = try self.lowerFile();
    return .{ .lowered = out, .module = self.module, .unit_paths = self.unit_paths };
}

/// Elaborates the file (§6.2.2) into one flat module, then lowers it.
/// Returns `error.DiagnosticsReported` if any error was recorded,
/// `error.NoModule` if the file has no module to lower.
pub fn lowerFile(self: *Lower) Error!Lowered {
    // The current backend only executes two-state analog equations. Preserve
    // full source literals in the AST, but never silently coerce them here.
    // A mixed module's discrete half is exempt: it runs on the four-state
    // kernel (`markDiscreteExprs`). A two-state literal wider than an i64 is
    // judged where it is lowered: whole in a wide `reg`'s right-hand side
    // (`lower_wide`), E0130 as an analog integer (`lower_expr.lowerExpr`).
    const discrete = try self.arena.alloc(bool, self.file.exprs.len());
    @memset(discrete, false);
    lower_context.markDiscreteExprs(self.file, discrete);
    for (discrete, 0..) |in_discrete, i| {
        const e: Ast.ExprId = @fromBackingInt(@intCast(i));
        if (self.file.exprs.tag(e) != .logic_literal or in_discrete) continue;
        const literal = self.file.exprs.logicValue(e);
        if (!literal.hasUnknown()) continue; // two-state: `lower_expr` or `lower_wide` lowers it
        const span = self.tokenSpan(self.file.exprs.mainTok(e));
        try self.err(self.file.exprs.mainTok(e), .E0130, "`{s}`: the analog backend cannot execute this {d}-bit four-state literal", .{ self.src[span.start..span.end], literal.width });
    }
    if (self.had_error) return error.DiagnosticsReported;
    const design = try Elaborate.elaborate(.{
        .arena = self.arena,
        .file = self.file,
        .src = self.src,
        .tok_starts = self.tok_starts,
        .bag = self.bag,
        .param_overrides = self.param_overrides,
        .discipline_resolution = self.discipline_resolution,
        .default_disciplines = self.directives.disciplines,
    });
    self.out.hier_names = design.names;
    self.unit_paths = design.units; // §9.15 Table 9-28 / §9.16 sibling scope
    self.ps_hidden = design.ps_hidden; // §6.4.3
    self.port_vars = design.port_vars; // §6.8
    self.ps_outputs = design.ps_outputs;
    self.paramset_defparams = design.paramset_defparams;
    self.selection_params = design.selection_params;
    self.system_checks = design.system_checks;
    self.out.inserts = design.inserts;
    // IEEE 1364 §19.2 on §3.6.5's STRUCTURAL implicit nets, which is the half
    // elaboration made but could not judge. Before `lowerModule`, so a design
    // built on a mistyped instance terminal fails at the mistype, not at a
    // later E0337 on the invented floating node.
    for (design.implicit_nets) |n| try lower_node.rejectImplicitNet(self, n.name, n.main_tok);
    self.unconnected_inputs = design.unconnected_inputs;
    self.port_concats = design.port_concats;
    self.port_widths = design.port_widths;
    self.attribute_disciplines = design.attribute_disciplines;
    self.local_accesses = design.local_accesses;
    self.port_disciplines = design.port_disciplines;
    try self.lowerModule(design.top);
    if (self.had_error) return error.DiagnosticsReported;
    try lower_node.collectSignalAbstols(self, design.signal_disciplines);
    return self.lowered();
}

/// `out`, plus the inputs lowering read that a later stage still needs. Every
/// buffer is shared with `self`, not copied.
fn lowered(self: *Lower) Oom!Lowered {
    self.out.src = self.src;
    self.out.tok_starts = self.tok_starts;
    self.out.token_span = &Lexer.tokenSpan;
    self.out.default_transitions = self.directives.transitions; // §10.3
    self.out.timescale = self.directives.timescale(); // IEEE 1364 §19.8
    self.out.timescales = self.directives.timescales;
    self.out.decl_attrs = try declAttrs(self);
    self.out.consts = self.consts;
    return self.out;
}

/// §2.9 every attribute_spec on a declaration in the file, in source order
/// (`Lowered.decl_attrs`), each value folded over literals alone. Last, so
/// the AST is complete: nothing after lowering writes it.
fn declAttrs(self: *Lower) Oom![]const Lowered.DeclAttr {
    var out: std.ArrayList(Lowered.DeclAttr) = .empty;
    for (self.file.attributes.items) |b| {
        if (b.owner.kind != .declaration) continue;
        for (b.specs) |s| try out.append(self.arena, .{
            .tok = b.owner.tok,
            .name = self.file.str(s.name),
            .value = if (s.value == .none) .{ .int = 1 } else constfold.fold(self.file, s.value, constfold.literal_env),
        });
    }
    return out.items;
}

/// Sizes the MIR from the elaborated AST (`Mir.reserve`): rows per AST
/// expression, `exprs` counted after elaboration, prelude modules included.
//
// The ratios are the median over the 13 compiles with more than 5000
// expressions (the ARPice models, 2026-10-03): instructions 0.59, values
// 0.54, extra words 0.50 per expression. Straight-line compact models sit
// on it (psp103 0.55/0.47/0.23, bsim4va 0.59/0.51/0.52); loop-heavy ones
// run far past it (hisimhv_va 2.04/1.95/6.30, coupled_ltra 8.2/8.0/21.5,
// their Braun phis) and grow from the estimate as before. A large source
// with little analog code (a gate-level `.v`) over-reserves; the tables are
// large blocks of the compile arena's backing allocator, mapped but never
// touched past what lowering writes, so that costs address space, not RSS.
// `max_exprs` caps it at about 30 MB of address space all the same.
fn reserveMir(self: *Lower) Oom!void {
    const max_exprs = 1 << 20;
    const n: u64 = @min(self.file.exprs.len(), max_exprs);
    try self.mir.reserve(self.arena, @intCast(n * 59 / 100), @intCast(n * 54 / 100), @intCast(n / 2));
}

/// LRM §6.2/§6.9. Register ports (§6.5) into `nodes`, elaborate the
/// declarations, then lower each analog block (§5.2) in source order —
/// multiple analog blocks are executed as if concatenated (§6.9.1).
fn lowerModule(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    self.module = module;
    self.mir.name = self.file.str(module.name);
    // IEEE 1364 §19.1 (§10.1 carries it over): the tag of the module keyword's
    // own position, which is what "modules between `celldefine and
    // `endcelldefine" means once the directives are positional regions.
    self.mir.is_cell = Preprocessor.CellRegion.inForce(self.directives.cells, self.tokStart(module.main_tok), false);

    try reserveMir(self);
    const entry = try self.mir.addBlock(self.arena);
    assert(entry == .entry);
    try self.builder.sealBlock(entry);
    self.cur = entry;

    try lower_discipline.collectDisciplines(self); // §3.6.1/§3.6.2 (annex D.1 is inlined here)
    try lower_discipline.checkNatureTable(self); // §3.6.1/§3.13 — the declaration table itself
    try lower_node.checkPortBranchDecls(self); // §3.12.1 — per source module, before flattening's renames matter

    // §3.4 parameters before the ports, because a range is a constant
    // expression over them (§6.5.2.2's `input [1:width] dt`).
    try lower_param.lowerParams(self, module);
    try lower_control.checkParamsetDefparams(self);
    // §9.18 the card-time domain checks: expressions over parameters only.
    for (self.system_checks) |c| try self.out.system_checks.append(self.arena, .{
        .kind = c.kind,
        .name = c.name,
        .v = try self.toReal(try lower_expr.lowerExpr(self, c.value)),
    });
    // §7.3.6.5: a mixed module's digital-owned values are host-written inputs.
    // Before the ports and nets, so none of them becomes an analog node.
    try lower_context.declareDiscreteInputs(self, module);
    try lower_context.checkSwitchTerminals(self, module); // A.3.3, §8.5.3.5
    // §8.5.3.5 switch processing is the discrete cycle's; with no discrete
    // half to run it on, the device carries nothing for the switch.
    if (!self.out.mixed_signal) for (module.switches) |sw|
        try self.bag.add(.lower, .W0250, self.tokenSpan(sw.main_tok), "`{s}` switch primitive", .{@tagName(sw.kind)});

    // §6.5 ports first: this order is the host device's terminal order.
    try lower_node.declarePorts(self, module);
    try lower_node.declareNets(self, module); // §3.6.3, §3.6.4
    try lower_node.bindPortConnections(self); // §6.5.7.1
    try lower_node.resolveDisciplines(self, module); // §7.4, §10.2
    // After the parameters and their defaults are in (§6.3.4).
    try lower_param.declareAliasParams(self, module); // §3.4.7
    try lower_node.declareBranches(self, module); // §3.12

    // §3.5 genvars exist only for unrolling; they carry no runtime storage.
    // §3.2/§3.3 module-level variables. The §5.10 scan runs first: whether a
    // variable needs a persistent slot is decided at its declaration, not at
    // the assignment that reveals it (see `holdSlot`).
    try lower_var.markHeldVars(self, module);
    try lower_var.markMemArrays(self, module);
    try lower_var.checkOneItemPerScope(self, module.params, module.vars, module.nets);
    // A.6.2 the digital `initial` block, for the same reason and at the same
    // point as the §5.10 scan above: what a variable holds at the top of every
    // evaluation is decided at its declaration. `initial x = 3;` and
    // `integer x = 3;` therefore lower to one write, and the AST edit below is
    // the whole of the difference.
    try lower_context.collectInitialState(self, module);
    const analog_writes = try lower_var.analogWrites(self, module);
    self.analog_writes = analog_writes;
    for (module.vars) |*v| {
        if (self.out.discrete_inputs.contains(self.file.str(v.name))) continue;
        var d = v.*;
        if (self.initial_state.get(self.file.str(d.name))) |a| {
            // §3.2.2 an array takes an assignment pattern, not a scalar, and
            // which element is which is the question a discrete kernel would be
            // answering. E0433 rather than §5.7's E0429 because the refusal is
            // about the block, not about the shapes.
            if (d.dims.len != 0)
                try self.err(a.tok, .E0433, "`{s}` is an array", .{self.file.str(d.name)})
            else
                d.init = a.value;
        }
        try lower_var.declareVarDecl(self, &d, .module);
        // §7.3.1: a wide `reg` the analog context only reads holds its
        // literal for the whole analysis, so every bit of it is known.
        const name = self.file.str(d.name);
        if (self.reg_ranges.get(name)) |rr| if (rr.width > 32 and lower_var.literalReg(self, &d, .module))
            try self.reg_consts.put(self.arena, name, d.init);
    }
    // §6.8: an `initial` block that assigns a name this module never declared.
    // Reported here because it is only knowable once every declaration is in,
    // and nothing else lowers the block.
    for (self.initial_state.keys(), self.initial_state.values()) |name, a| {
        // A net is declared: writing one is A.6.2's E0482 (`checkDiscreteContext`).
        if (!self.vars.contains(name) and !self.arrays.contains(name) and !lower_context.isNetSpelling(self.file, module, name))
            try self.err(a.tok, .E0313, "`{s}`", .{name});
    }

    // §5.10.4 named events. An event carries no value — only "triggered at this
    // timepoint or not" — so one integer flag per event, zero on entry to every
    // evaluation, set by `-> ev` and tested by `@(ev)`.
    //
    // Not a `holdSlot` like an event-assigned variable: a trigger is
    // instantaneous, and a retained flag would leave `@(ev)` active forever
    // (§5.10.4 has no "untrigger").
    // ponytail: a detection that lexically precedes its trigger reads 0 and
    // never runs. Closing that needs a scheduler queue; §5.10.4's own example
    // triggers first.
    for (module.events) |ev| {
        const name = self.file.str(ev.name);
        if (ev.dims.len == 0) {
            const place = self.builder.newPlace();
            try self.builder.writeVariable(place, self.cur, .zero);
            try self.events.put(self.arena, name, place);
            continue;
        }
        // §5.10.4 an event array: one flag per element, scalarized as §3.2
        // arrays are (`ev[0]`, `ev[1][2]`), so `-> ev[i]` raises exactly one.
        const bounds = (try lower_shape.dimsBounds(self, ev.dims, ev.main_tok, name)) orelse continue;
        var buf: [lower_shape.max_stack_dims]i64 = undefined;
        const idx = try lower_shape.subscriptBuf(self, &buf, bounds.len);
        for (0..lower_shape.shapeCells(bounds)) |k| {
            lower_shape.shapeSubscripts(bounds, k, idx);
            const place = self.builder.newPlace();
            try self.builder.writeVariable(place, self.cur, .zero);
            try self.events.put(self.arena, try lower_shape.elemName(self, name, idx), place);
        }
        try self.event_arrays.put(self.arena, name, bounds);
    }

    // §4.7.3, checked on the declarations before any call site sees them.
    try lower_func.checkFuncRecursion(self, module.functions);

    // §2.9/§2.9.2, after the declarations because "constant expression" is a
    // question about the scopes, and before the analog block, so an attribute is
    // reported at its own token rather than after a body that may not compile.
    try lower_param.checkAttributes(self, module.attrs);
    try lower_param.collectDeclMeta(self, module);
    try lower_var.checkScratchOwners(self, module);

    // §7.2.2 the DISCRETE context. Before the analog blocks because the rules
    // below relate the two, and it is the discrete side that names the variables
    // the continuous side is then judged against.
    try lower_context.checkDiscreteContext(self, module);

    // §9.17.3 the user-function `$limit` state slots, before the body: each
    // slot's previous-iterate read is seeded in the entry block so it dominates
    // the end-of-block read even when the site is under an `if`.
    for (module.analog) |blk| try lower_func.scanCallSites(self, blk.body, true, {}, {});

    // IEEE 1364 §19.9, also before the body and for a related reason: the pull
    // on an unconnected `input` is the OUTSIDE driving the port, so it is there
    // when the child's equations read it, not added after them.
    try lower_node.applyUnconnectedDrive(self);

    // §5.2 analog blocks, concatenated (§6.9.1).
    self.runtime_error_phase = .core;
    for (module.analog, 0..) |blk, bi| {
        self.cur_unit = blk.unit;
        self.cur_block = bi;
        if (blk.is_initial) {
            // §5.2.1 executed once per analysis, before a matrix solution
            // exists. Guarded rather than split into a second CFG so codegen
            // keeps one walk; the guard is a call codegen answers from a flag on
            // the Instance.
            //
            // Not `initial_step`: §5.2.1 says the block "shall be re-executed"
            // for each sub-task of a parameter sweep whose inputs changed, while
            // Table 5-1 makes `initial_step` only the first point of the whole
            // analysis.
            const flag = try self.call("analog_initial", &.{});
            const prev = self.restrict;
            self.restrict = "an analog initial block";
            self.in_analog_initial = true;
            try lower_control.lowerBranchStmt(self, flag, blk.body, .none, false, .none);
            self.in_analog_initial = false;
            self.restrict = prev;
            try lower_systask.haltAfterInitError(self);
        } else {
            try lower_stmt.lowerStmt(self, blk.body);
        }
    }
    self.runtime_error_phase = .none;

    try lower_event.finishTimers(self);

    // §5.6.1.3 the contribution accumulators' final values, and beside each the
    // final value of its retention flag — the "is a value retained [this
    // cycle]?" question the clause's three-way rule turns on.
    try self.readContribFinals(0);
    // §5.6.8.1 needs the final retention flags just read.
    try lower_contrib.checkSourceLoops(self);
    // §5.10 the same, for every held variable. Reads only (no `call`), so the
    // unit enumeration below is untouched.
    for (self.out.held_vars.items, self.held_places.items) |*h, p| h.final = try self.builder.readVariable(p, self.cur);
    // §5.6.1.2 and the same for every charge site.
    try self.readSiteFinals(0);
    // §9.17.3 and the same again for every `$limit` state slot: the value the
    // last site on that access function returned this evaluation, or the
    // `$limit$old` seed if none ran.
    for (self.out.limit_slots.items, self.limit_places.items) |*s, p| s.final = try self.builder.readVariable(p, self.cur);
    // VerA's `vera_timepoint` (§2.9): whether each cached statement ran.
    for (self.out.timepoints.items, self.tp_marks.items) |*t, p| t.mark = try self.builder.readVariable(p, self.cur);

    // §9.17 analog kernel control. Emitted last and in this fixed order so the
    // unit enumeration stays a pure function of the source.
    try lower_systask.finishKernelCtl(self);
    // §9.4 display tasks, after the kernel-control calls: those become naming
    // units, and inserting anything ahead would renumber every Instance state
    // field. Deferred §9.4.1 operands are lowered inside, after the accumulator
    // finals above, which is what "converged" means here.
    const contribs_before = self.out.contributions.items.len;
    const sites_before = self.out.charge_sites.items.len;
    try lower_systask.finishDisplays(self);
    // §4.5.2 an operator in a deferred operand adds its unknown's row there.
    try self.readContribFinals(contribs_before);
    try self.readSiteFinals(sites_before);
    if (self.table_effect_place) |p| self.out.table_effect = try self.builder.readVariable(p, self.cur);

    // After `finishDisplays`: a deferred display operand appends its
    // `branch_reads` there, and §1.3.1's probe test has to see every read.
    try lower_contrib.checkProbeBranches(self);
    // Last, so no value numbered above moves.
    try self.readShareFinals();
}

/// §5.4.1 each instance's share of a shared row (`unit_accum`) at the end of
/// the block, sorted by row then unit, into `Lowered.contrib_shares`.
fn readShareFinals(self: *Lower) Oom!void {
    const out = &self.out.contrib_shares;
    assert(out.items.len == 0); // runs once, last: the capacity below is the whole table
    try out.ensureTotalCapacity(self.arena, self.unit_accum.count());
    var it = self.unit_accum.keyIterator();
    while (it.next()) |k| out.appendAssumeCapacity(.{ .row = k.row, .unit = k.unit });
    std.mem.sortUnstable(Lowered.ContribShare, out.items, {}, struct {
        fn lt(_: void, a: Lowered.ContribShare, b: Lowered.ContribShare) bool {
            return a.row < b.row or (a.row == b.row and a.unit < b.unit);
        }
    }.lt);
    for (out.items) |*sh| {
        const pa = self.unit_accum.get(.{ .row = sh.row, .unit = sh.unit }).?;
        sh.resist_val = try self.builder.readVariable(pa.resist, self.cur);
        sh.react_val = try self.builder.readVariable(pa.react, self.cur);
    }
    assert(out.items.len == self.unit_accum.count());
}

/// Reads each contribution's accumulators from `from` on at the end of the
/// block, beside its §5.6.1.3 retention flag.
fn readContribFinals(self: *Lower, from: usize) Oom!void {
    assert(self.accum.items.len == self.out.contributions.items.len); // `newContrib` keeps them parallel
    assert(from <= self.accum.items.len);
    for (self.out.contributions.items[from..], self.accum.items[from..]) |*c, acc| {
        c.resist_val = try self.builder.readVariable(acc.resist, self.cur);
        c.react_val = try self.builder.readVariable(acc.react, self.cur);
        c.wrote_val = try self.builder.readVariable(acc.wrote, self.cur);
    }
}

/// Reads each §5.6.1.2 charge site's charge from `from` on at the end of the block.
fn readSiteFinals(self: *Lower, from: usize) Oom!void {
    assert(self.site_places.items.len == self.out.charge_sites.items.len); // `addSite` keeps them parallel
    assert(from <= self.site_places.items.len);
    for (self.out.charge_sites.items[from..], self.site_places.items[from..]) |*s, p| s.final = try self.builder.readVariable(p, self.cur);
}

// ---------------------------------------------------------------------------
// Diagnostics
// ---------------------------------------------------------------------------

/// Returns the byte range of a token, the unit every diagnostic reports in.
pub fn tokenSpan(self: *const Lower, tok: u32) diag.Span {
    return Lexer.tokenSpan(self.src, self.tok_starts, tok);
}

/// Returns where `tok` starts in the preprocessed text, the offset §10.1's
/// positional directives are published in (what a `Region` lookup takes).
/// Zero for a token index never lexed, which answers with each directive's
/// default.
pub fn tokStart(self: *const Lower, tok: u32) u32 {
    return if (tok < self.tok_starts.len) self.tok_starts[tok] else 0;
}

/// Records an error and keeps going. Callers substitute a poison value;
/// nothing downstream runs because `lowerFile` fails at the end.
pub fn err(self: *Lower, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Oom!void {
    self.had_error = true;
    return self.bag.add(.lower, code, self.tokenSpan(tok), fmt, args);
}

/// Starts an error that wants a label, a note or a suggestion. The caller
/// must `emit()` it.
pub fn errWith(self: *Lower, tok: u32, code: diag.Code) diag.Builder {
    self.had_error = true;
    return self.bag.build(.lower, code, self.tokenSpan(tok));
}

// ---------------------------------------------------------------------------
// Small MIR helpers
// ---------------------------------------------------------------------------

/// Appends `op` to the current block (`Mir.emit`).
pub fn emit(self: *Lower, op: Mir.Opcode, ops: []const Mir.Value) Oom!Mir.Value {
    return self.mir.emit(self.arena, self.cur, op, ops);
}

/// Appends a call to `name` in the current block (`Mir.emitCall`).
pub fn call(self: *Lower, name: []const u8, args: []const Mir.Value) Oom!Mir.Value {
    // §2.8.3 a `$name` no clause defines is the host's: the device owes it
    // an `Instance.systf` binding (`Uses.systf`).
    if (Mir.Callee.fromName(name) == .systf) self.out.uses.insert(.systf);
    const callee = try self.mir.internString(self.arena, name);
    return self.mir.emitCall(self.arena, self.cur, callee, args);
}

/// Closes `self.cur` with a jump and registers the CFG edge. `target` must not
/// be sealed yet.
pub fn gotoBlock(self: *Lower, target: Mir.Block) Oom!void {
    _ = try self.mir.emitJump(self.arena, self.cur, target);
    try self.builder.addPredecessor(target, self.cur);
}

/// Closes `self.cur` with a branch, registers both edges, and seals `then_b`
/// (and `else_b` when `seal_else`). A loop leaves its exit unsealed until its
/// body has registered any `break` predecessors.
pub inline fn branchTo(self: *Lower, cond: Mir.Value, then_b: Mir.Block, else_b: Mir.Block, comptime seal_else: bool) Oom!void {
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
    const b = try self.mir.addBlock(self.arena);
    try self.builder.sealBlock(b);
    self.cur = b;
}

/// Returns `table_effect_place`, creating it on first use seeded `.f_zero` in
/// the entry block. Its sum is never observed; what codegen keeps alive is the
/// dependencies and CFG edges it carries (`Lowered.table_effect`).
pub fn effectPlace(self: *Lower) Oom!Ssa.Place {
    if (self.table_effect_place) |p| return p;
    const p = self.builder.newPlace();
    try self.builder.writeVariable(p, .entry, .f_zero);
    self.table_effect_place = p;
    return p;
}

// ---------------------------------------------------------------------------
// Type coercion — LRM §4.2.1.1 (real→integer), §4.2.1.2 (integer→real)
// ---------------------------------------------------------------------------

/// §2.7 a string literal's integer value: `kernels.fold.strToInt`.
pub const strToInt = @import("kernels").fold.strToInt;

/// Returns `tv` converted to a number when it is a string with compile-time
/// bytes (§2.7 at an operand); everything else is returned untouched, and the
/// caller diagnoses a runtime string.
pub fn strNum(self: *Lower, tv: TypedValue) Oom!TypedValue {
    // ponytail: 64 bits, the width of the slot the value lands in. An operand
    // has no declared width (§3.3's assignment case passes its own), so a
    // literal longer than eight characters keeps its low eight.
    if (tv.ty != .string) return tv;
    return switch (self.mir.valueDef(tv.v)) {
        .str_const => |s| .{ .v = try self.mir.addIntConst(self.arena, strToInt(s, 64)), .ty = .integer },
        .undef, .float_const, .int_const, .param_ref, .block_param, .inst_result => tv,
    };
}

/// Returns `tv0` as a real (§4.2.1.2 integer→real; §2.7 string→number).
pub fn toReal(self: *Lower, tv0: TypedValue) Oom!Mir.Value {
    const tv = try self.strNum(tv0); // §2.7
    return switch (tv.ty) {
        .real => tv.v,
        .integer => self.emit(.if_cast, &.{tv.v}),
        .string => tv.v, // already diagnosed at the use site
        .wide => unreachable, // `lowerExpr` types no value `.wide`: a whole wide `reg` read is E0222
    };
}

/// Returns `tv0` as an integer (§4.2.1.1 real→integer rounds; §2.7 string→number).
pub fn toInt(self: *Lower, tv0: TypedValue) Oom!Mir.Value {
    const tv = try self.strNum(tv0); // §2.7
    return switch (tv.ty) {
        .integer => tv.v,
        .real => self.emit(.fi_cast, &.{tv.v}),
        .string => tv.v,
        .wide => unreachable, // `lowerExpr` types no value `.wide`: a whole wide `reg` read is E0222
    };
}

/// Returns `tv` converted for a §5.7 store into a slot of type `ty`.
/// §4.2.1.1/§4.2.1.2 convert between integer and real; §3.3 draws the one line
/// no conversion crosses, between a string literal and a string value:
///
///   "A string literal can be assigned to a string or an integral type. ...
///    A string cannot be assigned to an integral type."
///
/// So `integer code = "A";` is legal and `code = label;` (label a `string`) is
/// not: the test is the shape of expression `e`, not its lowered type. Every
/// write to a declared variable goes through this.
pub fn coerceTo(self: *Lower, e: Ast.ExprId, ty: Ty, tv: TypedValue) Oom!Mir.Value {
    // ponytail: the mirror direction, a numeric into a `string` slot (which
    // §3.4.1 forbids too), is unchecked; the arm to add it to is `.string`.
    if (tv.ty == .string and ty != .string) {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.arena);
        if (!try self.strLitBytes(e, &bytes)) {
            try self.err(self.file.exprs.mainTok(e), .E0354, "assigning a string to {s}", .{@tagName(ty)});
            return lower_var.zeroOf(ty);
        }
        // §3.3's "right justified and either truncated on the left or zero
        // filled on the left" is measured against the declared type, and §3.2
        // fixes `integer` at 32 bits: "hello" is 40 bits and loses its 'h'.
        if (ty == .integer) return self.mir.addIntConst(self.arena, strToInt(bytes.items, 32));
    }
    return switch (ty) {
        .real => self.toReal(tv),
        .integer => self.toInt(tv),
        .string => tv.v,
        .wide => unreachable, // `resolveLvalue` types a wide `reg` `.integer`, and nothing else coerces to one
    };
}

/// Is `e` a §3.3 string literal, and what are its bytes? The literal itself, or
/// a concatenation of literals — §4.2.13's replication with a literal count is
/// unrolled by the parser, so `{5{"Hi"}}` arrives as five operands.
///
/// A `.multi_concat` is deliberately not one, and that exclusion is the whole
/// rule: Table 3-3's multiplier "can be nonconstant", and a nonconstant one
/// leaves a string with no width at elaboration, which is why §3.3's own
/// example makes `r = {i{"Hi"}}` invalid where `b = {i{"Hi"}}` is fine.
///
/// The test is made on the AST because the SSA builder answers a read of a
/// once-written `string label = "hi"` with the literal's own `str_const`, so
/// by Value `code = label` and `code = "hi"` are indistinguishable.
///
/// Table 3-3's empty-string row is the one place these bytes differ from the
/// string the same expression evaluates to: `""` "is converted to 8'b0", so
/// `{"H", ""}` is "H" as a string and 'H' followed by one zero byte as an
/// integral.
fn strLitBytes(self: *Lower, e: Ast.ExprId, out: *std.ArrayList(u8)) Oom!bool {
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .str_literal => {
            const s = self.file.str(ex.strOf(e));
            try out.appendSlice(self.arena, if (s.len == 0) &[_]u8{0} else s);
            return true;
        },
        .concat => {
            for (ex.args(e)) |el| if (!try self.strLitBytes(el, out)) return false;
            return true;
        },
        else => return false, // else: not a literal or a concatenation of literals, so no compile-time bytes
    }
}

/// Returns `tv` as integer 0/1: §4.2.8, a condition is "true" when non-zero. Normalized to integer 0/1 so
/// `logand`/`logor`/`branch` all see the same shape.
pub fn toBool(self: *Lower, tv: TypedValue) Oom!Mir.Value {
    return switch (tv.ty) {
        .integer => self.emit(.ine, &.{ tv.v, .zero }),
        .real => self.emit(.fne, &.{ tv.v, .f_zero }),
        .string => .zero,
        .wide => unreachable, // `lowerExpr` types no value `.wide`: a whole wide `reg` read is E0222
    };
}

/// Returns the operation type of two operands: §4.2.1, one real operand makes
/// the operation real; a string operand makes it a string.
pub fn unify(a: Ty, b: Ty) Ty {
    if (a == .string or b == .string) return .string;
    return if (a == .real or b == .real) .real else .integer;
}

/// Returns the lowering type of a declared AST type (`.unspecified` is real).
pub fn astTy(t: Ast.Type) Ty {
    return switch (t) {
        .real, .unspecified => .real,
        .integer => .integer,
        .string => .string,
    };
}

// ---------------------------------------------------------------------------
// Test support: source in, verdict out
// ---------------------------------------------------------------------------

/// Test support for the `analog/*.zig` tests: one source file preprocessed
/// (the annex E prelude included), parsed and ready to lower, with the arena
/// and the diagnostic bag a test reads afterwards. Analysed only by a test.
///
/// Pinned in place by `init`: `low` points at `file`, `mir` and `bag`, so the
/// value must not move until `deinit`.
pub const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    file: Ast.SourceFile,
    mir: Mir,
    bag: diag.Bag,
    low: Lower,

    /// Prepares `h` to lower `src`. Every buffer lives in an arena over
    /// `gpa`, which `deinit` frees whatever lowering returned.
    pub fn init(h: *Harness, gpa: std.mem.Allocator, src: []const u8) !void {
        h.* = .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .file = .empty,
            .mir = .{},
            .bag = undefined,
            .low = undefined,
        };
        errdefer h.arena_state.deinit();
        const arena = h.arena_state.allocator();
        h.bag = diag.Bag.init(arena);
        const text = (try Preprocessor.process(arena, src, .{ .bag = &h.bag })).text;
        const toks = try Lexer.Lexer.tokenize(arena, text);
        var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &h.bag);
        const parse = try arena.create(Ast.SourceFile);
        parse.* = try p.parseSourceFile();
        // The annex E prelude's modules lead `file.modules`. Elaboration
        // writes the overlay, never the parse.
        h.file = parse.overlay(.{ .builtin_modules = Preprocessor.spice_module_count });
        h.low = Lower.init(arena, &h.mir, &h.file, text, toks.items(.start), &h.bag);
    }

    /// Lowers the file: the tables, or null when an error was reported.
    /// Any other error (`NoModule`, OOM) is returned.
    pub fn lower(h: *Harness) Error!?Lowered {
        const out = h.low.lowerFile() catch |e| switch (e) {
            error.DiagnosticsReported => return null,
            else => |other| return other, // else: anything but a verdict fails the test
        };
        return out;
    }

    /// Returns how many diagnostics of `code` were recorded.
    pub fn count(h: *const Harness, code: diag.Code) usize {
        var n: usize = 0;
        for (0..h.bag.count()) |i| n += @intFromBool(h.bag.at(i).code == code);
        return n;
    }

    /// Prints every recorded diagnostic, for a failing test's report.
    pub fn dump(h: *const Harness) void {
        for (0..h.bag.count()) |i| {
            const d = h.bag.at(i);
            std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
        }
    }

    /// Frees everything `init` made.
    pub fn deinit(h: *Harness) void {
        h.low.deinit();
        h.arena_state.deinit();
    }
};

/// Test support, the one check every `analog/*.zig` table of cases goes
/// through: lowers `src` and compares the verdict with `want`. Null means it
/// lowers with no error at all; a code means at least one diagnostic of that
/// code was reported. On a mismatch, prints the source and every diagnostic.
pub fn expectVerdict(src: []const u8, want: ?diag.Code) !void {
    var h: Harness = undefined;
    try h.init(std.testing.allocator, src);
    defer h.deinit();
    const out = try h.lower();
    const ok = if (want) |code| h.count(code) != 0 else out != null and h.bag.err_count == 0;
    if (ok) return;
    std.debug.print("want {s}, got:\n", .{if (want) |code| @tagName(code) else "no error"});
    h.dump();
    std.debug.print("source:\n{s}\n", .{src});
    return error.TestUnexpectedResult;
}

/// Test support: `expectVerdict` over a two-terminal module `m(p, n)` whose
/// module-scope declarations are `decls` and whose analog block is `body`,
/// followed by one `I(p, n) <+ V(p, n)` so the module has an equation.
pub fn expectBodyVerdict(decls: []const u8, body: []const u8, want: ?diag.Code) !void {
    const src = try std.testing.allocator.print(
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\{s}
        \\  analog begin
        \\{s}
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , .{ decls, body });
    defer std.testing.allocator.free(src);
    return expectVerdict(src, want);
}

/// Test support: one rule case for `expectBodies`, a module body and the code
/// it must report, or null for a body that must lower with no error at all.
/// The oracle is the LRM sentence each case cites: every refusal has a legal
/// neighbour beside it, so a blanket refusal fails the table.
pub const Case = struct { src: []const u8, code: ?diag.Code };

/// Test support: `expectVerdict` over every case, stopping at the first that
/// fails. Each `src` is a module body with electrical ports `p` and `q`, a real
/// parameter `g`, and the variables `x`, `r` (real), `iv`, `seed` (integer)
/// and `sv` (string).
pub fn expectBodies(cases: []const Case) !void {
    const gpa = std.testing.allocator;
    for (cases) |c| {
        const src = try gpa.print(
            \\module m(p, q);
            \\  inout p, q;
            \\  electrical p, q;
            \\  parameter real g = 1.0;
            \\  real x, r;
            \\  integer iv, seed;
            \\  string sv;
            \\{s}
            \\endmodule
        , .{c.src});
        defer gpa.free(src);
        try expectVerdict(src, c.code);
    }
}

/// The frontend parser, which only `Harness` drives.
const Parser = @import("frontend").Parser;

test unify {
    // §4.2.1: one real operand makes the operation real, and §3.3 Table 3-3
    // makes an operation with a string operand a string one.
    const cases = [_]struct { a: Ty, b: Ty, want: Ty }{
        .{ .a = .integer, .b = .integer, .want = .integer },
        .{ .a = .integer, .b = .real, .want = .real },
        .{ .a = .real, .b = .integer, .want = .real },
        .{ .a = .real, .b = .real, .want = .real },
        .{ .a = .string, .b = .integer, .want = .string },
        .{ .a = .integer, .b = .string, .want = .string },
        .{ .a = .string, .b = .real, .want = .string },
        .{ .a = .real, .b = .string, .want = .string },
        .{ .a = .string, .b = .string, .want = .string },
    };
    for (cases) |c| try std.testing.expectEqual(c.want, unify(c.a, c.b));
}

test astTy {
    // §3.4.1: a declaration with no type is real until a value says otherwise.
    try std.testing.expectEqual(Ty.real, astTy(.real));
    try std.testing.expectEqual(Ty.real, astTy(.unspecified));
    try std.testing.expectEqual(Ty.integer, astTy(.integer));
    try std.testing.expectEqual(Ty.string, astTy(.string));
}

test strToInt {
    // §3.3's right justification at widths other than the ordinary 32 and
    // 64: whole bytes only, the leftmost characters dropped first.
    try std.testing.expectEqual(0, strToInt("", 64));
    try std.testing.expectEqual(0, strToInt("AB", 0));
    try std.testing.expectEqual('B', strToInt("AB", 8));
    try std.testing.expectEqual('B', strToInt("AB", 12));
    // Nine characters at 64 bits keep the last eight, 'B' (0x42) to 'I' (0x49).
    try std.testing.expectEqual(0x4243444546474849, strToInt("ABCDEFGHI", 64));
    // §2.7's "unsigned integer constants": unsigned at 32 bits, and the whole
    // 64-bit pattern reinterpreted at the slot's own width.
    try std.testing.expectEqual(4294967295, strToInt("\xff\xff\xff\xff", 32));
    try std.testing.expectEqual(-1, strToInt("\xff\xff\xff\xff\xff\xff\xff\xff", 64));
}

test "lowerFile: a source with no module_declaration (A.1.2) is NoModule" {
    var h: Harness = undefined;
    try h.init(std.testing.allocator, "");
    defer h.deinit();
    try std.testing.expectError(error.NoModule, h.lower());
}

test "lowerFile: §2.6.1 a four-state literal is E0130 as a value, and a value under §7.3.2's ===" {
    try expectBodyVerdict("  integer k;", "    k = 4'b1x01;", .E0130);
    // A two-state literal is the integer it spells, however it is written.
    try expectBodyVerdict("  integer k;", "    k = 4'b0101;", null);
    try expectBodyVerdict("  integer k;", "    k = (2 === 4'b1x01);", null);
}

test "coerceTo: §3.3 a string reaches an integral slot only as a literal (E0354)" {
    const decls = "  integer k;\n  string s;\n  parameter integer c = 2;";
    // "A string cannot be assigned to an integral type."
    try expectBodyVerdict(decls, "    s = \"AB\";\n    k = s;", .E0354);
    // "A string literal can be assigned to a string or an integral type."
    try expectBodyVerdict(decls, "    k = \"AB\";", null);
    try expectBodyVerdict(decls, "    k = {\"A\", \"B\"};", null);
    // §3.3's own `r = {i{"Hi"}}`: a multiplier the parser could not unroll
    // leaves the literal no width at elaboration.
    try expectBodyVerdict(decls, "    k = {c{\"A\"}};", .E0354);
}

/// One generated module for the fuzz test below: up to eight statements
/// drawn from `pool`, legal ones and refused ones, in any order.
fn smithModule(_: void, s: *std.testing.Smith) anyerror!void {
    const pool = [_][]const u8{
        "x = x + 1.0;",
        "if (V(p) > 0.5) x = 2.0; else x = -1.0;",
        "k = (k * 3) % 7;",
        "for (j = 0; j < 3; j = j + 1) x = x + j;",
        "case (k) 0: x = 1.0; 1, 2: x = 2.0; default: x = 0.0; endcase",
        "begin : blk real t; t = x; x = t * 0.5; end",
        "a[k % 3] = x;",
        "x = a[1] + a[k % 3];",
        "while (k > 10) k = k - 1;",
        "repeat (2) x = x * 2.0;",
        "x = ((k != 0) && (1.0 / k > 0.5)) ? 1.0 : 0.0;",
        "I(p) <+ 0.1 * x;",
        "s = {\"a\", \"b\"};",
        "x = sqrt(abs(x)) + min(k, 2) + max(x, 1.0);",
        "@(initial_step) k = 0;",
        "x = ddt(x);",
        // Refused, each by its own rule: E0313, E0318, E0310, E0514.
        "zz = 1.0;",
        "x = ~x;",
        "a[7] = 1.0;",
        "if (k > 2) x = ddt(V(p));",
    };
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    const n = s.valueRangeAtMost(u8, 0, 8);
    for (0..n) |_| {
        try body.appendSlice(gpa, "    ");
        try body.appendSlice(gpa, pool[s.index(pool.len)]);
        try body.append(gpa, '\n');
    }
    const src = try gpa.print(
        \\module m(p);
        \\  inout p; electrical p;
        \\  real x;
        \\  real a[0:2];
        \\  integer k, j;
        \\  string s;
        \\  analog begin
        \\{s}
        \\    I(p) <+ x * V(p);
        \\  end
        \\endmodule
    , .{body.items});
    defer gpa.free(src);
    var h: Harness = undefined;
    try h.init(gpa, src);
    defer h.deinit();
    // Every refusal names its reason: `DiagnosticsReported` with an empty bag
    // would be a silent failure.
    const out = try h.lower() orelse return std.testing.expect(h.bag.err_count != 0);
    // What a later stage indexes with is in range.
    try std.testing.expect(out.num_ports <= out.nodes.len);
    for (out.contributions.items) |c| {
        try std.testing.expect(c.hi == ground or c.hi < out.nodes.len);
        try std.testing.expect(c.lo == ground or c.lo < out.nodes.len);
    }
    try std.testing.expectEqual(out.held_vars.items.len, h.low.held_places.items.len);
}

test "lowering a generated module never crashes, and every refusal reports" {
    try std.testing.fuzz({}, smithModule, .{});
}

// §7.2.2 the discrete context: which statements and nets are digital, analog/context.zig
const lower_context = @import("context.zig");

// §3.6 disciplines and natures, §3.11 net compatibility, analog/discipline.zig
const lower_discipline = @import("discipline.zig");

// §1.3.1 nodes: nets, ports, ground and the solver-unknown order, analog/node.zig
const lower_node = @import("node.zig");
/// A node's §1.3.1 display name, for diagnostics and tests.
pub const nodeName = lower_node.nodeName;

// §3.4 parameters and §2.9 attribute values, analog/param.zig
const lower_param = @import("param.zig");

// §3.2 variables: scopes, storage and retention, analog/var.zig
const lower_var = @import("var.zig");
/// Applies `prove.setup.pruneHeld`'s held-row mask to `Lowered`.
pub const dropHeld = lower_var.dropHeld;

// §3.2.2/§3.4.4 array shapes and §3.4.8 assignment patterns, analog/shape.zig
const lower_shape = @import("shape.zig");

// §5 analog statements: blocks, assignments, named blocks, analog/stmt.zig
const lower_stmt = @import("stmt.zig");

// §5.6 contributions: `<+`, indirect contributions, switch branches, analog/contrib.zig
const lower_contrib = @import("contrib.zig");

// §5.8 conditionals and §5.9 loops, analog/control.zig
const lower_control = @import("control.zig");

// §5.10 analog events: `@(...)`, cross/above/timer, initial_step/final_step, analog/event.zig
const lower_event = @import("event.zig");

// §4.2 expressions, §4.3 math functions, §4.4 signal access, analog/expr.zig
const lower_expr = @import("expr.zig");

// §4.5 analog operators and filters, analog/analog_op.zig
const lower_analog_op = @import("analog_op.zig");

// Clause 9 system functions in analog context, and their arguments, analog/sysfunc.zig
const lower_sysfunc = @import("sysfunc.zig");
/// Reports whether a §9.15 simulation parameter is answered at run time.
pub const simparamIsRuntime = Lowered.simparamIsRuntime;
/// The §9.15 simulation parameters a host supplies, in `Model` field order.
pub const host_simparams = Lowered.host_simparams;

// Clause 9 system tasks: §9.4 display, §9.5 I/O, §9.7 status, §9.17 kernel control, analog/systask.zig
const lower_systask = @import("systask.zig");

// §9.13 probabilistic distributions, analog/random.zig
const lower_random = @import("random.zig");

// §9.21 `$table_model`, analog/table_model.zig
const lower_table_model = @import("table_model.zig");

// §9.17.3 `$limit`: the limiting-function call and its per-access state slot, analog/limit.zig
const lower_limit = @import("limit.zig");

// §9.16 `$simprobe` and §9.20 hierarchical reference strings, analog/hier_name.zig
const lower_hier_name = @import("hier_name.zig");

// §4.7 user-defined analog functions, analog/func.zig
const lower_func = @import("func.zig");

// Constant evaluation: §4.2 constant_expression, §6.6.1 generate bounds, analog/constfold.zig
const lower_constfold = @import("constfold.zig");

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
    _ = Lowered;
}
