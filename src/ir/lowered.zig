//! `Lowered`: the tables lowering hands to every later stage, as one value,
//! and the row types of those tables.
//!
//! `Lower` builds these (with its symbol tables, SSA builder and scopes); this is the
//! part that outlives it. Every later stage takes a `*const Lowered`, so none can reach
//! lowering state. Every buffer is arena-owned, like the MIR it indexes, and lives as
//! long as the arena passed to `Lower.lower`.
//!
//! Cross-table references are indices: every row is a `u32` (`none_u32` is
//! "absent"; for a `nodes` row `ground` is the sentinel past the last row).
//! The row types are also reachable as `Lower.<Name>`, the spelling most callers use:
//! code after lowering binds this file as `Lower` (`const Lower = @import("ir").Lowered`),
//! so it reads the rows, `ParamOverride` and the §9.15 `simparam` rows from `ir` and
//! never imports lowering.
//!
//! LRM clauses this file's code cites: §1.3.1, §1.3.1.1, §1.3.1.2, §1.3.4,
//! §1.3.4.1, §2.7, §2.8.1, §2.8.3, §2.9, §2.9.2, §3.1, §3.2, §3.2.2, §3.4,
//! §3.4.2, §3.4.5, §3.4.7, §3.6, §3.6.1.2, §3.6.2, §3.6.2.1, §3.6.2.2, §3.6.3,
//! §3.6.3.2, §3.6.5, §3.9, §3.12, §4.2, §4.2.12, §4.4, §4.5.2, §4.5.3, §4.5.15,
//! §4.6.3, §4.6.4, §4.6.4.1, §4.6.4.2, §4.6.4.3, §4.6.4.6, §5.2.1, §5.4.1,
//! §5.4.2, §5.4.3, §5.5.2, §5.5.3, §5.6, §5.6.1.2, §5.6.1.3, §5.6.7, §5.6.8.2,
//! §5.10, §5.10.3.3, §5.10.4, §6, §6.3.4, §6.5, §6.5.2, §6.5.2.2, §6.6, §6.7,
//! §7.2.4, §7.3.1, §7.3.2, §7.3.3, §7.3.4, §7.3.6.1, §7.3.6.4, §7.3.6.5,
//! §7.4.4, §7.8.4, §8, §8.5, §8.5.3.6, §9.4, §9.4.1, §9.5.1, §9.5.3,
//! §9.5.4.2, §9.5.8, §9.7.3, §9.12, §9.13, §9.13.1, §9.15, §9.17.1, §9.17.3,
//! §9.18, §9.19, §9.21, §10.3, §11.6.6, §11.6.7, §12.32.
//! IEEE 1364-2005 clauses cited: §4.8.2, §5.1.5, §5.1.7, §5.1.8, §5.1.9,
//! §5.1.11, §5.1.12, §5.1.13, §5.4, §5.5, §5.5.1, §19.8.

const std = @import("std");
const base = @import("base");
const diag = @import("diag");
const Mir = @import("mir.zig");
const simparam = @import("simparam.zig");

/// Lowering's output; later stages read it through `*const Lowered`.
pub const Lowered = @This();

// ---- row types: the model card ----------------------------------------------

/// A folded constant (§4.2 constant_expression), the shared kernel's.
pub const Const = @import("kernels").fold.Const;
/// §3.1 a parameter's declared type (`base`'s, which `Ast.Type` aliases).
pub const Type = base.Type;

/// A resolved §3.4 parameter.
pub const ParamInfo = struct {
    name: []const u8,
    /// Token of the declaration, so a finiteness diagnostic can point a label at
    /// "`k` declared here" and hang a `from (0:inf)` suggestion off it.
    tok: u32 = Mir.no_tok,
    ty: Type,
    /// An explicit `integer` declaration converts to signed 32 bits; an
    /// inferred integral parameter retains its initializer's bit pattern.
    integer32: bool = true,
    /// Final HDL declaration width, retained for self-determined operands.
    /// A card value does not change it; `lowerClog2` reads a set card value
    /// at its own unsized width instead (VD-089).
    source_width: ?u32 = null,
    source_signed: ?bool = null,
    default: Mir.Value,
    /// §3.4.2 value ranges from `Ast.ParamDecl.ranges`, bounds folded
    /// (`Range`); proof.zig uses them as bound evidence.
    ranges: []const Range = &.{},
    /// §3.4.5 localparam: not part of the model card ABI.
    is_local: bool = false,
    /// §3.4 the value under the declared defaults, folded over the AST. The
    /// emitted `Model` field initializer needs it, and it cannot always be
    /// recovered from `default`: a §4.2.12 `?:` lowers to a diamond and a phi
    /// that no MIR fold sees through. Null when the default is not a constant
    /// expression.
    folded: ?Const = null,
    /// §3.2/§3.4/§6.6 a shape parameter: its value was folded into a shape (an
    /// array or vector bound, a replication count, a genvar loop bound, a
    /// generate scheme, the condition over a §5.6.7 indirect contribution),
    /// which the device fixes at compile time. Codegen's `checkShape` refuses a card that moves it.
    /// Set by `lower_constfold.shapeEval`.
    shape: bool = false,
};

/// §3.4.2 one value range of a parameter (`Ast.ValueRange`), as the prover
/// reads it: each bound folded over literals alone (`constfold.literal_env`,
/// `lower_param.paramRanges`), so a bound written over another parameter,
/// whose default the card can override, is no evidence.
pub const Range = struct {
    kind: enum(u8) { from, exclude },
    /// The folded lower bound, or null: it does not fold over literals, it
    /// folds to a string or a NaN, or the range is the string-set form.
    lo: ?f64,
    /// The folded upper bound under the same rule; a single-value `exclude`
    /// has `lo`'s.
    hi: ?f64,
    lo_inclusive: bool = true,
    hi_inclusive: bool = true,
    /// A.2.5 `value_range_type '{ string {, string} }`: no numeric bounds.
    strings: bool = false,
};

/// §3.4.7 one `aliasparam`: the alias's spelling and the `params` index it names.
pub const Alias = struct { name: []const u8, param: u32 };

// ---- row types: the unknown table -------------------------------------------

/// §1.3.1.1 the global reference node. Not a solver unknown, so it is a
/// sentinel rather than a `nodes` row: probing it yields a literal 0. One
/// below `maxInt(u32)` so it never equals `none_u32` ("absent"), and above
/// every row, so sorting by row puts it last.
pub const ground: u32 = std.math.maxInt(u32) - 1;

/// One row of `nodes`.
pub const Node = struct {
    /// The unknown's unique spelling (codegen's `U` member).
    name: []const u8,
    /// What the slot is, as opposed to how it is spelled (see `NodeKind`).
    kind: NodeKind,
    /// Discipline name (`""` when undeclared, §3.9). A name and not an index,
    /// because a node may name a discipline `disciplines` has no row for.
    disc: []const u8,
    /// §7.2.4 minimum potential tolerance over the signal's continuous net
    /// segments. This is node metadata, not a net's §5.5.3 nature attribute.
    potential_abstol: ?f64 = null,
    /// §6.5.2.2 port direction (`.unspecified` for an internal net or an undeclared
    /// direction). An `input` or `output` port is a §1.3.4 signal-flow port; which
    /// of the two decides §1.3.4.1's contribution-target rule (E0425).
    dir: base.Direction,
};

/// What quantity a `nodes` row carries, recorded where the slot is created
/// (`appendNode`). Never re-derive it from the name: §2.8.1 strips an escaped
/// identifier's backslash, so the net `\flow(p,n)` collides byte-for-byte with
/// what `flowUnknown` prints. The payload is the node whose discipline supplies
/// the unknown's §3.6.1.2 tolerance. §6.5.2 vector elements are ordinary nets
/// (`b[1]`, `b[0]`; §3.6.3), so `\b[0]` and `b[0]` still collide.
pub const NodeKind = union(enum) {
    /// §3.6 a net: a declared one, a §3.6.5 implicit one, or a §3.6.3 element.
    net,
    /// §5.4.2 the current of a branch, carrying the branch's high node.
    branch_flow: u32,
    /// §5.4.3 the current through a port, carrying the port.
    port_flow: u32,
    /// §4.5.2 the unknown an analog operator site introduces ("new equations
    /// and new unknowns"), carrying its tolerance: the operator's abstol or
    /// nature argument, else the 1e-6 an undisciplined net gets. A potential.
    op_state: f64,
};

/// §5.4.2 the identity of an unnamed branch: its ordered node pair, the key of
/// `flow_unknowns`.
pub const FlowKey = struct { hi: u32, lo: u32 };

/// §5.4.3 one probed module port: the port's `nodes` row and the
/// `nodes` row of the flow unknown that carries `I(<port>)`.
pub const PortProbe = struct { port: u32, u: u32 };

/// §3.6.3.2 one net_decl_assignment: the net's `nodes` row and the folded
/// initializer — "a nodeset value for the potential of the net by the analog
/// solver". An initial guess, never a constraint, so it is metadata for a host
/// and reaches nothing in the residual.
pub const Nodeset = struct { node: u32, value: f64, tok: u32 };

/// §2.9.2 one `decl_meta` row (`contract.DeclMeta`): a module-scope
/// declaration of the device's own module and its last `desc` and `units`
/// (§2.9), each null when absent. Metadata for a host; reaches no residual.
pub const DeclMeta = struct {
    kind: enum(u8) { parameter, variable, net },
    name: []const u8,
    desc: ?[]const u8 = null,
    units: ?[]const u8 = null,
};

/// §2.9 one attribute_spec on a declaration (`decl_attrs`): the declaration's
/// token, the attribute's name and its value folded over literals
/// (`constfold.literal_env`), null when it does not fold. A spec written with
/// no value is 1 (§2.9).
pub const DeclAttr = struct { tok: u32, name: []const u8, value: ?Const };

/// One `Lowered.system_checks` row: a §9.18 system parameter's name and kind,
/// and its value lowered over the parameters.
pub const SystemCheck = struct { kind: base.SystemParam, name: []const u8, v: Mir.Value };

/// A folded `[msb:lsb]` (§3.6.3 Syntax 3-6 `range`). Both bounds are signed and
/// either order is legal (§3.6.3 runs `[5:0]`, the vector-branch example
/// `[3:5]`), so nothing here assumes msb ≥ lsb. Every range lowering builds
/// has passed `lower_node.foldDim`'s E1015 check, so its size fits a `u32`.
pub const VecRange = struct {
    msb: i64,
    lsb: i64,

    /// Returns the element count, `|msb - lsb| + 1`.
    /// Asserts that the count fits a `u32`.
    pub fn size(v: VecRange) u32 {
        return @intCast(@abs(v.msb - v.lsb) + 1);
    }
    /// Returns whether index `i` lies within the range, in either direction.
    pub fn has(v: VecRange, i: i64) bool {
        return i >= @min(v.msb, v.lsb) and i <= @max(v.msb, v.lsb);
    }
    /// Returns the k-th element in declaration order, msb first. That order is the
    /// host's terminal order for a vector port, and it is what §3.12 pairs
    /// "in a parallel one-to-one fashion" for a vector branch.
    /// Asserts that `k` is below `size()`.
    pub fn at(v: VecRange, k: u32) i64 {
        std.debug.assert(k < v.size());
        const d: i64 = @intCast(k);
        return if (v.msb <= v.lsb) v.msb + d else v.msb - d;
    }
};

/// §3.6.1.2 tolerances of a discipline's two natures. Recorded for proof.zig
/// and for codegen's per-node abstol; nothing here consumes it.
pub const DisciplineInfo = struct {
    potential_abstol: f64 = 1e-6,
    flow_abstol: f64 = 1e-12,
    is_discrete: bool = false, // §3.6.2.2
    /// §3.6.2.1 a conservative discipline binds both a potential and a flow
    /// nature; §3.6.2.2 a signal-flow discipline binds only one. Codegen needs
    /// the distinction: a contribution to a signal-flow net has no KCL meaning.
    has_potential: bool = false,
    has_flow: bool = false,
    /// §3.6.1.2 the access identifier each bound nature declares, `""` when the
    /// discipline binds none. §4.4 requires the name in `V(n)` to be this one,
    /// so the check needs the discipline's spelling, not just the global set of
    /// access names.
    potential_access: []const u8 = "",
    flow_access: []const u8 = "",
};

// ---- row types: the equations -----------------------------------------------

/// §5.4.1 Example 2: "There can only be one unnamed branch between any two nets
/// or between a net and implicit ground (in addition to any number of named
/// branches)." So every `V(a,b)`/`I(a,b)` reference shares this one identity,
/// distinct from every named branch over the same pair.
pub const unnamed_branch: u32 = 0;

/// §4.4 access-function flavour. `V(a,b)` is a potential, `I(a,b)` a flow;
/// user natures rename them (§3.6.1.2) but the two roles are closed.
pub const Access = enum(u8) { potential, flow };

/// Whether a `Contribution` is a `<+` (`.direct`) or a §5.6.7 indirect
/// branch assignment.
pub const Kind = enum(u8) { direct, indirect };

/// A §5.6 contribution target and its accumulated value, split into resistive
/// and reactive (§5.6.1.2) parts. One entry per (access, branch), never one per
/// `<+`: §5.6.1.3 makes `<+` an accumulation, so the values are the final reads
/// of an SSA place and conditional contributions fall out. Keyed on the branch,
/// not the node pair, because §5.4.1 allows any number of named branches over
/// one pair (§5.4.3's diode uses two). KCL is unaffected: every entry stamps
/// the same two node rows.
pub const Contribution = struct {
    access: Access,
    /// §5.4.1 which branch retains this value: a `BranchInfo.id`, or
    /// `unnamed_branch` for the one implicit branch of the node pair.
    br: u32 = unnamed_branch,
    /// Token of the `<+` this unit came from; W0650 reports per unit, so it
    /// needs the statement, not the instruction that broke the proof.
    tok: u32 = Mir.no_tok,
    hi: u32, // `nodes` row (or `ground`)
    lo: u32, // `nodes` row (or `ground`)
    resist_val: Mir.Value = .f_zero, // → eval()
    react_val: Mir.Value = .f_zero, // → q()   (§4.5.3 ddt)
    /// §5.6.1.3 "If a value is retained for the potential ... otherwise, if a
    /// value is retained for the flow ... otherwise the branch is an open
    /// circuit." Retention depends on the cycle's execution path, so this is
    /// the end-of-block read of `Accum.wrote`: 1.0 for an unconditional `<+`,
    /// 0.0 for one discarded on the straight line, and a phi when an `if`
    /// decides, which makes codegen select the branch row at run time.
    /// `.direct` only.
    wrote_val: Mir.Value = .f_zero,
    noise_srcs: []const NoiseSrc = &.{}, // §4.6.4
    /// §5.6.7 `V(out) : V(in) == e` has the topology of a direct potential
    /// contribution (a source in the branch, its current an unknown) with a
    /// different constitutive row. `.direct` carries `V(hi,lo) - resist_val`;
    /// `.indirect` carries `resist_val` alone (probe - equation), because the
    /// branch voltage is what is being solved for (a nullor).
    ///
    /// A `.indirect` entry is never deduped by `contribIndex`: §5.6.1.3
    /// accumulation is a property of `<+`, and each indirect statement is its
    /// own equation with its own source.
    kind: Kind = .direct,
    /// `Ast.AnalogBlock.unit` of the block that opened this accumulator: the
    /// module instance whose §5.4.1 branch it is. Read by `discardOpposite`
    /// alone. An entry that later absorbs a same-kind `<+` from another
    /// instance keeps the first id, so a third instance wired across the pair
    /// cannot discard the aggregate.
    unit: u32 = 0,
    /// A `<+` from an instance other than `unit` accumulated into this entry
    /// (two devices in parallel over one pair). The row is still right, and
    /// it is the sum: a reader that wants the flow of one instance's own
    /// §5.4.1 branch (the VPI, §11.6.7) reads that instance's
    /// `contrib_shares` entry instead.
    shared: bool = false,
};

/// §5.4.1 one instance's own share of a `Contribution.shared` row: what its
/// unnamed branch carries (its `<+`, and §5.6.8.2's hierarchical ones aimed at
/// it), in the row's canonical direction. The end-of-block reads of lowering's
/// `unit_accum`.
pub const ContribShare = struct {
    /// A `contributions` index.
    row: u32,
    /// The instance (`Ast.AnalogBlock.unit`) whose branch this is.
    unit: u32,
    resist_val: Mir.Value = .f_zero,
    react_val: Mir.Value = .f_zero,
};

/// §4.6.4.1/.2 the parametric forms, then §4.6.4.3/.4 the tabulated ones, then
/// §4.6.3's stimulus. Append only, so no existing ordinal moves. `ac_stim` is
/// not noise and never reaches `noise_gens` (codegen routes it to `ac_gens`);
/// it is here because it shares the A.8.2 grammar node and therefore the same
/// collection walk (`noiseSrcsOf`, identity dedup, `var_noise`).
pub const NoiseKind = enum(u8) { thermal, flicker, table, table_log, ac_stim };

/// §4.6.4 one noise generator a contribution carries: its PSD kind and its
/// identity. `id` is the `Ast.ExprId` of the declaring call, because §4.6.4.6
/// makes one call one generator: two contributions reaching the same call
/// (through a variable) share it, perfectly correlated, while two separate
/// calls never do. Codegen renames ids densely into `contract.NoiseGen.source`.
/// A contribution holds a set of these, since a branch may combine several.
/// The PSD is the arguments (`pwr`, `exp`), not the kind: `white_noise(2·q·|I|)`
/// and `white_noise(4·k·T/R)` differ only in `pwr`; codegen exports both
/// through `noisePsd`.
pub const NoiseSrc = struct {
    kind: NoiseKind,
    id: u32,
    /// §4.6.4.1/.2 arg 0. `.f_zero` only for a generator whose call never
    /// lowered, which cannot happen through `lowerNoise`.
    ///
    /// On an `.ac_stim` row this is §4.6.3's `mag`, the first numeric argument
    /// (the analysis name is a string and does not take a slot), defaulting to
    /// the clause's 1.
    pwr: Mir.Value = .f_zero,
    /// §4.6.4.2 arg 1, the frequency exponent. Unread on a `.thermal` row, and
    /// 1 for a one-argument `flicker_noise`.
    ///
    /// On an `.ac_stim` row this is §4.6.3's `phase` in radians, defaulting to
    /// the clause's 0, which is why `lowerNoise` seeds the pair differently
    /// for a stimulus.
    exp: Mir.Value = .f_one,
    /// §4.6.4.3/.4 arg 0 of a `.table`/`.table_log` row: the vector, flattened
    /// to `f0, p0, f1, p1, …` and still unfolded. Empty on every other kind and
    /// on a table call whose argument was not a vector. Codegen folds, sorts and
    /// validates it with `Analysis.foldConst`.
    table: []const Mir.Value = &.{},
    /// The call's own token, for the diagnostics codegen raises over `table`.
    tok: u32 = Mir.no_tok,
    /// §4.6.4.6 the coefficient this contribution applies to the generator:
    /// the `c1` of `V(a,b) <+ c1*n`; the branch carries `coeff²·pwr`. Per
    /// (contribution, generator), because one shared `white_noise` reaching two
    /// branches is one source with two coefficients, whose product is the
    /// cross-spectrum. Signed: opposite signs are anti-correlation.
    /// `.f_zero` means no contribution has claimed the row yet; the first use
    /// replaces it and later ones add. A row still at zero in codegen is read
    /// as 1 (`plan/noise.zig` `plan`).
    coeff: Mir.Value = .f_zero,
    /// The generator appears in a shape no single factor describes. `coeff` is
    /// then 1 and stays there.
    nonlinear: bool = false,
    /// §4.6.4.1/.2/.3 the optional trailing `name` argument, verbatim; empty
    /// when the call did not supply one. A label only: same-name combination is
    /// a property of the host's noise summary, and §4.6.4.6 keeps separate
    /// calls uncorrelated whatever they are called. It never merges rows or
    /// touches `id`; it reaches `contract.NoiseGen.name`.
    name: []const u8 = "",
};

/// §5.6.1.2 one charge site: one reactive term a contribution's right-hand
/// side splits into (`lower_contrib.splitTerm`), a `ddt` with the factors of
/// its multiplicative spine, whose charge is the term with the `ddt` stripped.
/// Static by §4.5.15 (no analog operator in a user function, a runtime loop
/// or a runtime conditional), so a site is one source occurrence after genvar
/// unrolling and flattening. `Contribution.react_val` is exactly the sum of
/// its sites' `sign * final`, which is what lets the host tape charges per
/// site and still stamp the same rows (`contract.QStamp`).
pub const ChargeSite = struct {
    /// The `contributions` entry this site accumulates into.
    contrib: u32,
    /// ±1: the site's sign inside that entry's reactive accumulator: the
    /// term's own sign in the sum, times the §1.3.1.2 reversed-branch flip.
    sign: f64,
    /// VerA's `vera_lte` attribute (`Ast.LteAttr`): does this charge join the
    /// host's local-truncation-error check? Default true.
    lte: bool = true,
    /// The `ddt` token, for diagnostics and the emitted comment.
    tok: u32 = Mir.no_tok,
    /// The site's charge at the end of the analog block: zero on every path
    /// that did not execute it or that §5.6.1.3 discarded.
    final: Mir.Value = .f_zero,
};

// ---- row types: instance state and live roots -------------------------------

/// Value type of a lowered expression (§3.1). `Ast.Type.unspecified` is
/// resolved before it reaches here.
pub const Ty = enum(u8) {
    real,
    integer,
    string,
    /// IEEE 1364-2005 §5.4 a `reg` wider than §3.2's 32 bits that the analog
    /// context assigns: every bit of it (`analog/wide.zig`). Its width is the
    /// `VarSlot.reg_width`, `HeldVar.width` or `TpSlot.width` beside it.
    wide,
};

/// Absent-index sentinel for the `u32` index fields here.
pub const none_u32 = std.math.maxInt(u32);

/// One §5.10 event-assigned module variable and its persistent slot.
pub const HeldVar = struct {
    /// Source spelling, including the `[i]` of a scalarized array element
    /// (§3.2.2). Unique within the module scope, so codegen's `Instance` field
    /// name is injective after `names.sanitize`.
    name: []const u8,
    ty: Ty,
    /// A `.wide` variable's bits; 0 for every other type.
    width: u32 = 0,
    /// The declared initializer. Only reachable on the first evaluation, so
    /// codegen renders it as the `Instance` field's default and nowhere else.
    init: Mir.Value,
    /// The `$held_*` call seeded into the entry block. Reading the variable
    /// anywhere, even lexically before the `@(...)`, reads this: the value the
    /// last accepted evaluation left behind.
    seed: Mir.Value,
    /// The variable's value at the end of the analog block; `updateState`
    /// stores it back on the accepted solution. Filled at the end of
    /// `lowerModule`.
    final: Mir.Value = .undef,
    /// §3.2.2 a held memory-backed array: its `out.mem_arrays` index, and
    /// `seed`/`final` are array versions. `none_u32` for a scalar.
    array: u32 = none_u32,
    /// The array's declared initializer, one Value per element (`init` is
    /// the element type's zero). Empty: every element starts at zero.
    inits: []const Mir.Value = &.{},
    /// Why the variable is held; see `Why`.
    why: Why = .event,
    /// §8.5.3.6 every event body that assigns it waits on explicit D2A terms
    /// only, so a host evaluating one region-1b event before the next delta
    /// cycle's commits it alone (the mixed runner's `latch`).
    d2a: bool = false,

    /// The name of a variable's §7.3.6.1 assignment count is this followed
    /// by the variable's (`lower_var.countAssign`): no identifier starts
    /// with `$`.
    pub const assign_count_prefix = "$assigned.";

    /// Why a variable needs a persistent slot.
    pub const Why = enum {
        /// §5.10 assigned under an `@(...)`: latch state `stateCtl` may
        /// reject a step over.
        event,
        /// §3.2 retention (`lower_var.Exposed`) that some evaluation can
        /// observe: an `analog initial` write, or a read that reaches a later
        /// write of the same evaluation.
        retained,
        /// §3.2 retention that only a card-varying write could make
        /// observable. `prove`'s `pruneHeld` drops it when every merge
        /// of the held value is solve-invariant.
        unless_invariant,
        /// §7.3.3 a discrete context reads it (`Lowered.discrete_reads`): the
        /// mixed-signal coordinator copies its value off a solution, so it
        /// needs a slot even when every evaluation assigns it first.
        a2d,
    };
};

/// §3.2.2 one memory-backed array (`Lowered.mem_arrays`).
pub const MemArray = struct {
    /// Source spelling, for a comment and a diagnostic; never an identity.
    name: []const u8,
    /// Element count over every dimension.
    len: u32,
    /// `.real` or `.integer` (a string array stays scalarized).
    ty: Ty,
    /// The `out.held_vars` row it is, or `none_u32`: a §5.10 held array starts
    /// every evaluation from its `Instance` field instead of zero.
    held: u32 = none_u32,
    /// `(* vera_scratch = "uninit" *)` (§2.9): its `anew` stores nothing (NaN
    /// under runtime safety), since the author writes each element before
    /// reading it in the evaluation.
    uninit: bool = false,
};

/// §9.17.3 one `$limit(access, user_function, …)` state slot, keyed by the
/// access function, not the call site: §9.17.3 puts the state on the argument
/// ("internal state containing information about the argument on previous
/// iterations"). Per-site state breaks the SPICE-converted accessor idiom,
/// where `$limit(V(g,s), DEVlimitOldGet)` reads what a later
/// `$limit(V(g,s), DEVlimitNewSet, …)` writes: a per-site slot would store back
/// what it just read and never change. When every site names a distinct access
/// function the two readings coincide.
pub const LimitSlot = struct {
    /// `V(g,s)` as it reads in the source, for the `Instance` field comment.
    label: []const u8,
    access: Access,
    hi: u32,
    lo: u32,
    neg: bool,
    br: u32,
    /// The `$limit$old` call seeded into the entry block: the value this slot
    /// returned on the previous Newton iterate.
    seed: Mir.Value,
    /// The slot's value at the end of the analog block. `updateState` stages
    /// it; the next iterate's `updateState` promotes it into the read field.
    final: Mir.Value = .undef,
};

/// VerA's `vera_timepoint` statement (§2.9, `Lowered.timepoints`): it runs on
/// the first evaluation of a timepoint, and every later one reads back what it
/// assigned. Lowered as a diamond on `$tp_hit(b)`: the hit arm writes each
/// slot's `$tp_real`/`$tp_int` read (an array's cached `anew`), the miss arm
/// is the statement. `eval` stores the slots when the statement ran and the
/// cache was stale; the host's `stateCtl`, `updateState`, `initState` and
/// `setup` drop it.
pub const TpBlock = struct {
    /// The attribute's token, for E0531.
    tok: u32,
    /// The miss arm's first block and the join both arms reach: everything
    /// between them is the statement, whose values codegen checks (E0531).
    miss: Mir.Block,
    join: Mir.Block,
    /// Nonzero at the end of the block exactly when the statement was reached.
    mark: Mir.Value = .zero,
    slots: []const TpSlot = &.{},
};

/// One variable a `vera_timepoint` statement assigns: its `Instance` cache
/// slot. `final` is its value at the statement's join.
pub const TpSlot = struct {
    /// Source spelling, for the field comment.
    name: []const u8,
    ty: Ty,
    /// A `.wide` variable's bits; 0 for every other type.
    width: u32 = 0,
    final: Mir.Value = .undef,
    /// §3.2.2 a memory-backed array's `out.mem_arrays` row, or `none_u32`.
    array: u32 = none_u32,
};

/// IEEE 1364-2005 §5.4/§5.5 one node of an expression a `$wide`/`$wide$int`
/// call computes (`Lowered.wide_nodes`): `analog/wide.zig` sized it, and
/// `codegen/wide.zig` renders it over `wide_kernels.zig`. Every operand is
/// already of the type its operator computes in, so a node needs no context.
pub const WideNode = struct {
    op: WideOp,
    /// The node's bits; 0 for a real.
    width: u32,
    /// Its IEEE 1364 §5.5.1 type. The operators that read a sign (`div`,
    /// `rem`, `ashr`, `pow`, `resize`) read their own; `lt`, `le` and
    /// `to_real` read their operand's.
    signed: bool = false,
    a: u32 = none_u32,
    b: u32 = none_u32,
    c: u32 = none_u32,
    /// `leaf_*`: the call's argument it reads (after the root's), the first
    /// of `zwLimbs(width)` for `leaf_words`; `lit`: its first `wide_lits` word.
    arg: u32 = none_u32,
};

/// What one `WideNode` computes. Integer nodes are `width` bits; a node of
/// width 0 is a real, and its operator the real one (`add`, `sub`, `mul`,
/// `div`, `rem`, `pow`, `neg`, `cond`).
pub const WideOp = enum(u8) {
    /// An analog integer argument's low `width` bits.
    leaf_int,
    /// A discrete input's `Model` words (`Lowered.discrete_words`).
    leaf_words,
    /// A `.wide` argument of this width.
    leaf_wide,
    /// A real argument's value.
    leaf_real,
    /// A literal's `width` bits.
    lit,
    /// `a` converted to this width, sign-extended when `signed` (§5.5.2).
    resize,
    /// `a` (an integer) to a real, and a real to this width (§4.8.2).
    to_real,
    from_real,
    neg,
    not,
    add,
    sub,
    mul,
    div,
    rem,
    @"and",
    @"or",
    xor,
    xnor,
    /// `a` shifted by the unsigned count `b` (§5.1.12); `ashr` fills with
    /// the sign of a signed `a`.
    shl,
    shr,
    ashr,
    /// `a ** b` (§5.1.5 Table 5-6).
    pow,
    /// One-bit comparisons of `a` and `b`, which share a type (§5.1.7, §5.1.8).
    eq,
    lt,
    le,
    /// One-bit logical operators over the truth of `a` and `b` (§5.1.9).
    land,
    lor,
    lnot,
    /// One-bit reductions of `a` (§5.1.11).
    red_and,
    red_or,
    red_xor,
    /// `a ? b : c`; `a` is any type, `b` and `c` the node's (§5.1.13).
    cond,
};

/// One §9.4/§9.7.3 print site.
pub const Display = struct {
    /// The synthetic `call`. Its first argument is the §2.7 format string.
    val: Mir.Value,
    /// The task's exact spelling (`$strobe`, `$write`, `$error`, …). Codegen
    /// needs it for the newline rule (§9.4.1: `$write` does not append one) and
    /// for the §9.7.3 severity prefix.
    name: []const u8,
    /// The call token, for W0850.
    tok: u32,
    /// The call sits under an `if` or a loop, so it reaches the display root
    /// through `display_cond_place` rather than by direct `fadd` (the value
    /// does not dominate the root). `finishDisplays` is the one reader: it
    /// leaves these out of the unconditional chain.
    conditional: bool,
    /// The call is in an `analog initial` block, which §5.2.1 executes once
    /// per analysis "before a matrix solution is available": a printing
    /// artifact's iteration pass performs it at the first iterate
    /// (`codegen.Gen.init_calls`).
    analog_initial: bool = false,
};

/// One §9.7.3 `$fatal`/`$error` call in the analog context (`status_sites`).
pub const StatusSite = struct {
    fatal: bool,
    /// The format string, "" when the call has none.
    fmt: []const u8,
    /// The call token, for the site's source line.
    tok: u32,
};

/// How many numeric arguments a status site carries (`status_args`).
pub const status_arg_max = 4;

/// A device-side facility the model uses. Each gates a kernel file or an
/// `Instance`/`Model` field in codegen; `uses` is the set.
pub const Kernel = enum {
    /// §9.5.3/§9.5.4.2 `$sformat`/`$swrite`/`$sscanf` → `str_kernels.zig`.
    /// A flag, not a site list: codegen finds each site by its MIR instruction.
    str_tasks,
    /// §9.5.1-§9.5.8 the file-descriptor family → `file_kernels.zig`, only in the
    /// `display == .emit` artifact. A descriptor table is a host facility; without one
    /// the device answers as §9.5.1 does for a file that "cannot be opened": zero.
    file_tasks,
    /// §9.21 `$table_model` → `table_kernels.zig`.
    table_model,
    /// §9.13 one of Table 9-10's 17 probabilistic distributions → `rng_kernels.zig`.
    rng,
    /// §9.15 the model queries the runtime Newton iteration number.
    newton_iter,
    /// §9.15 the model reads a `$simparam` whose value is the HOST's
    /// (`host_simparams`), so codegen owes its Model that reserved field. Set
    /// at the call, because a §3.4 parameter default such as
    /// `parameter real tnom = $simparam("tnom")` is lowered outside the block stream.
    host_tnom,
    host_reltol,
    host_abstol,
    host_vntol,
    host_gmin,
    host_source_scale,
    /// §9.17.1 `$discontinuity(-1)`: `reject_iteration` is a live root and the
    /// device carries the rejection flag.
    reject_iteration,
    /// §9.19 a top-level `$port_connected`: the Model owes the host-written
    /// connection mask `port_connected__`.
    port_mask,
    /// §9.12 `$test$plusargs`/`$value$plusargs`: the `Instance.plusargs`
    /// field the host writes and the `zPlusarg` search over it.
    plusargs,
    /// §9.15 Table 9-28 `$simparam$str("cwd")` / `("analysis_name")`, or a
    /// name not known until the solve, or a §4.6.3 `ac_stim` name that is not
    /// a Table 4-21 small-signal kind (VD-109): the host-written
    /// `Instance.cwd`/`analysis_name` slices and their GPU-safe twins,
    /// `Model.cwd_idx__`/`analysis_name_idx__` (`contract.host_strings`).
    host_strings,
    /// §2.8.3/§12.32 a `$name` left to a VPI application (`Mir.Callee.systf`):
    /// the `Instance.systf` binding the host writes.
    systf,
};
// ---- row types: the discrete half -------------------------------------------

/// One explicit D2A event term (`discrete_events`): §7.3.4's `posedge`,
/// `negedge` or bare `expression` over a digital name, or §5.10.4's named event
/// triggered by the digital context.
pub const DiscreteEvent = struct {
    /// The digital variable, net or named event the term watches.
    name: []const u8,
    edge: enum { any, posedge, negedge },
    /// The `Model` field the host sets for the solve the event is delivered to.
    param: []const u8,
};

/// §7.8.4 one port an automatic connect module was inserted on (`inserts`).
pub const Inserted = base.Inserted;

// ---- what code after lowering reads beside the tables -------------------------

/// §3.4 a `--param name=value` override of the top module's parameter
/// `name`; the testbench and `vera` pass it to lowering.
pub const ParamOverride = base.ParamOverride;
/// §7.4.4 basic or detail discipline resolution, which the testbench passes
/// to lowering (`Elaborate.DisciplineResolution`).
pub const DisciplineResolution = base.DisciplineResolution;
/// Reports whether a §9.15 simulation parameter is answered at run time.
pub const simparamIsRuntime = simparam.simparamIsRuntime;
/// The §9.15 simulation parameters a host supplies, in `Model` field order.
pub const host_simparams = simparam.host_simparams;
/// §10.3 one `default_transition event (`Preprocessor.DefaultTransition`).
pub const DefaultTransition = base.Region(?f64);
/// A `timescale's two operands, in seconds (`Preprocessor.Timescale`).
pub const Timescale = base.Timescale;
/// IEEE 1364 §19.8 one `timescale event (`Preprocessor.TimescaleEvent`).
pub const TimescaleEvent = base.Region(?Timescale);

// Row budgets on a 64-bit host. Every table here is per module and short
// (psp103: 847 params, 12 nodes, 18 contributions), so these pin today's
// sizes against a silent bloat rather than claim a tight layout;
// docs/seams/s1-lower.md has the narrower shapes the readers outside
// lowering would have to accept.
comptime {
    std.debug.assert(@sizeOf(ParamInfo) <= 88); // ~850 rows on a compact model
    std.debug.assert(@sizeOf(Node) <= 72); // SoA (`nodes` is a MultiArrayList)
    std.debug.assert(@sizeOf(Contribution) <= 56); // u32 node rows (#29)
    std.debug.assert(@sizeOf(ChargeSite) == 24);
    std.debug.assert(@sizeOf(HeldVar) <= 56);
    std.debug.assert(@sizeOf(NoiseSrc) <= 56);
    // The node sentinels: `ground` is never "absent" (`none_u32`).
    std.debug.assert(ground < none_u32);
}

// ---- the source, for diagnostics and host facts -----------------------------
// The AST itself is not here: the VPI, the one reader after lowering, takes it
// from `vera.CompileResult`.
/// Preprocessed source and the lexer's `.start` column, kept only so a token
/// index can become a `diag.Span` (`tokenSpan`).
src: []const u8 = "",
tok_starts: []const u32 = &.{},
/// Returns a token's byte range from `src` and `tok_starts`: the lexer's
/// `tokenSpan`, which lowering sets, so `tokenSpan` re-lexes a token
/// without `ir` importing the frontend. Diagnostics only (cold).
token_span: *const fn (src: []const u8, starts: []const u32, tok: u32) diag.Span = &noTokens,
/// §10.3 the `default_transition events (`Preprocessor.Directives.transitions`),
/// in text-stream order: codegen's `transition()` default at a call's offset.
default_transitions: []const DefaultTransition = &.{},
/// IEEE 1364 §19.8 the `timescale in force at the end of the stream
/// (`Preprocessor.Directives.timescale`), or null: §9.15's `timeUnit` and
/// `timePrecision`.
timescale: ?Timescale = null,
/// IEEE 1364 §19.8 every `timescale event (`Preprocessor.Directives.timescales`),
/// at offsets into `src`: each module runs in the one written before it, so
/// the mixed-signal testbench hands the digital half all of them.
timescales: []const TimescaleEvent = &.{},
/// §2.9 every attribute_spec on a declaration, in source order (instance,
/// then spec), over the whole file. `--emit-verilog` reads `vera_pin` and
/// `vera_delay` from them.
decl_attrs: []const DeclAttr = &.{},

// ---- the elaborated hierarchy (§6), for the VPI -----------------------------
/// §6.7 path → flat name, from elaboration. Lowering reads it in `flatName`,
/// the VPI to resolve a path.
hier_names: std.StringHashMapUnmanaged([]const u8) = .empty,
/// §3.4 the constant table as lowering left it: every module parameter's
/// folded value, by flat name. The VPI's `vpiParameter` values.
consts: std.StringHashMapUnmanaged(Const) = .empty,
/// §3.6.3 declared vector nets and §3.12 vector branches, by base name.
/// Vectors are scalarised (`electrical [3:0] p` interns nodes `p[3]`..`p[0]`), so
/// this map is the only place a range survives. It answers whether a name is a
/// vector and whether an index is one of its elements (E0351, E0352).
vectors: std.StringHashMapUnmanaged(VecRange) = .empty,

// ---- §1.3.1 the unknown table -----------------------------------------------
/// The U-enum index space, one row per solver unknown: ports (§6.5) first,
/// then internal nodes (§3.6.3), then branch-flow unknowns (§5.4.2).
/// Append-only, so row indices are stable. SoA because every consumer reads one column.
///
/// A row index is a `u32` everywhere (`ground` sits above every row); the
/// emitted `U`'s tag is as wide as the row count needs (`emitTopology`).
nodes: std.MultiArrayList(Node) = .{},
/// §6.5 the port rows are `nodes[0..num_ports]`. A `u32` because it is a row
/// index (see `nodes`).
num_ports: u32 = 0,
/// §5.4.2 branch-flow identity: the node pair → its unknown's `nodes` row.
/// Keyed on the pair, so `I(a)` and `I(a,gnd)` stay distinct when a plain net is
/// spelled `gnd` (see `flowUnknown`).
flow_unknowns: std.AutoHashMapUnmanaged(FlowKey, u32) = .empty,
/// §5.4.3 ports read with `I(<p>)`, in first-probe order, deduped. Each needs
/// its own solver unknown (`u`) and a row pinning it to the module's KCL sum
/// at `port`; codegen emits that row. Append-only, so the order is deterministic.
port_probes: std.ArrayList(PortProbe) = .empty,
/// §3.6.3.2 the net_decl_assignments of this module, in declaration order and
/// already folded. Sparse (most modules declare none), so codegen emits the
/// optional `u_nodeset` table only when this is non-empty.
nodesets: std.ArrayList(Nodeset) = .empty,
/// §2.9.2 the `desc`/`units` rows, parameters then variables then nets, each
/// in declaration order (`lower_param.collectDeclMeta`). Sparse, so codegen
/// emits the optional `decl_meta` table only when this is non-empty.
decl_meta: std.ArrayList(DeclMeta) = .empty,
/// The parameters whose last `type` attribute is "instance", in declaration
/// order (`lower_param.collectDeclMeta`): OpenVAF's convention for the ones
/// an instance line sets. Empty when the module marks none.
instance_params: std.ArrayList([]const u8) = .empty,
disciplines: std.StringHashMapUnmanaged(DisciplineInfo) = .empty, // §3.6.2

// ---- §3.4 the model card and §5.6 the equations -----------------------------
params: std.ArrayList(ParamInfo) = .empty, // §3.4
/// §3.4.7 parameter aliases, in declaration order, for the model card. An alias
/// carries an override (`#(.trise(5))` and `#(.dtemp(5))` mean the same thing), so it
/// needs its own card field; `params` has one entry per real parameter, and
/// `param_index` does not say which name is the alias.
aliases: std.ArrayList(Alias) = .empty,
contributions: std.ArrayList(Contribution) = .empty, // §5.6
/// §5.4.1 the OTHER instances whose `<+` a row accumulated
/// (`Contribution.shared`): `row` is a `contributions` index, `unit` the
/// instance. The row's own `unit` is not repeated here. Each still declares its
/// own unnamed branch (§5.4.2), which the VPI's §11.6.6 model lists.
contrib_sharers: std.ArrayList(struct { row: u32, unit: u32 }) = .empty,
/// Every instance's share of a shared row (`ContribShare`), sorted by row,
/// then unit. Nothing in the device reads them; a VPI device publishes them
/// (`codegen.Options.vpi_contribs`, `vpiShares`) by this index.
contrib_shares: std.ArrayList(ContribShare) = .empty,
/// §5.6.1.2 every charge site, in source order (`ChargeSite`).
charge_sites: std.ArrayList(ChargeSite) = .empty,

// ---- instance state ---------------------------------------------------------
/// §5.10 module variables assigned inside an `@(<event>)` body, in declaration
/// order. Such a variable retains its value between analog evaluations
/// (`@(cross(...)) x = V(p);`), which an SSA place re-initialised every evaluation
/// cannot express, so each gets a persistent `Instance` slot.
held_vars: std.ArrayList(HeldVar) = .empty,
/// §5.10.3.3 final start/period expressions, distinct from the call operands
/// which decided whether to execute the event body. Only changed controls
/// have a row; codegen reads these for the following breakpoint.
timer_controls: std.AutoHashMapUnmanaged(Mir.Inst, [2]Mir.Value) = .empty,
/// §2.8.3/§12.32 the user system TASK calls: each `$name(...)` statement's
/// `.systf` call. A `.systf` call not in it is a function call in an
/// expression. Codegen publishes the difference (`contract.Systf.task`).
systf_tasks: std.AutoHashMapUnmanaged(Mir.Inst, void) = .empty,
/// §3.2.2 the arrays some subscript indexes at run time. Each is ONE storage
/// of `len` elements (dimensions flattened in declaration order), reached
/// through `Mir.Opcode.anew`/`fload`/`iload`/`store` instead of one SSA place
/// per element; `anew` names its array by index into this list.
mem_arrays: std.ArrayList(MemArray) = .empty,
/// §9.17.3 the user-function `$limit` state, one entry per ACCESS FUNCTION.
/// Collected by `scanCallSites` before the analog block is lowered.
limit_slots: std.ArrayList(LimitSlot) = .empty,
/// VerA's `vera_timepoint` statements (§2.9), in source order: each one's
/// per-timepoint cache in `Instance` (`TpBlock`).
timepoints: std.ArrayList(TpBlock) = .empty,
/// First-call sample counts, one entry per array-source call site.
table_samples: std.ArrayList(u32) = .empty,
/// §9.13.1 implementation-chosen starting seeds for omitted-seed call sites.
/// Each `Instance` latch advances on the accepted step. Explicit constant and
/// parameter seeds instead use held SSA storage, updated by the executed call.
rng_auto_seeds: std.ArrayList(i64) = .empty,

// ---- live roots: values no contribution reads, kept alive by codegen --------
/// §9.4 display tasks, in source order. Nothing reads a display call's result, so
/// `display_root` keeps them live (see `finishDisplays`).
displays: std.ArrayList(Display) = .empty,
/// The chain root over every unconditional entry of `displays`, or `.f_zero`
/// when the model prints nothing. codegen turns it into ONE unit function whose
/// body is the prints, in source order.
display_root: Mir.Value = .f_zero,
/// Source-order chain over table captures and required runtime checks; a core
/// live-out.
table_effect: Mir.Value = .f_zero,
/// §9.17.1 rejection belongs to the Newton iteration, not timestep history:
/// the final value of the rejection flag, meaningful when
/// `uses.contains(.reject_iteration)`.
reject_iteration: Mir.Value = .zero,
/// VerA's `$vera_reject_step`: the earliest retry time any call asked for
/// (+inf when none ran), or `.undef` when the module never calls it.
/// `updateState` turns it into `contract.UpdateResult.request_reject_at`.
reject_step: Mir.Value = .undef,
/// §9.7.3 `$fatal`/`$error` in the analog context, in source order: a
/// device (`--display=drop`) reports the first one an evaluation reaches
/// through `Instance.vera_status__` (`contract.StatusSite`).
status_sites: std.ArrayList(StatusSite) = .empty,
/// The status code the evaluation ends with: 0 when no site ran, else the
/// FIRST site's `(severity << 24) | (site + 1)`. `.undef` without sites.
status: Mir.Value = .undef,
/// The first site's numeric arguments, after its format string (0 past
/// its count, and for a string argument).
status_args: [status_arg_max]Mir.Value = @splat(.undef),

// ---- which kernels the device needs -----------------------------------------
/// The device-side facilities the model needs (see `Kernel`).
uses: std.EnumSet(Kernel) = .empty,

// ---- §7.3.6.5/§8 the discrete half ------------------------------------------
/// §7.3.6.5/§8.5 a mixed module's digital-owned values the analog block may
/// read, name → declaring token, in first-write order.
discrete_inputs: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// §8.5 / §8.5.3.6 explicit D2A: every digital event term of an analog event
/// control, keyed by the term's expression. Each is a host-written `Model`
/// flag (`DiscreteEvent.param`), nonzero for the solve at the digital tick the
/// event occurred in.
discrete_events: std.AutoArrayHashMapUnmanaged(base.ExprId, DiscreteEvent) = .empty,
/// §8.5.3.6 the digital values read INSIDE a statement guarded by an explicit
/// D2A event: each is read from a `<name>__1b` `Model` field holding the value
/// after region 1 of the event's tick, not the live one region 3b sees.
discrete_snaps: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// §7.3.2 the `discrete_inputs` the analog block reads through `===`, `!==`
/// or a `case` subject: their unknown plane arrives in a `<name>__xz` `Model`
/// field beside the value plane, and an x or z there is not an error.
discrete_xz: std.StringArrayHashMapUnmanaged(void) = .empty,
/// IEEE 1364-2005 §5.4 every `WideNode` the `$wide`/`$wide$int` call
/// roots reach, and the 32-bit words of their literals (`WideNode.arg`).
wide_nodes: std.ArrayList(WideNode) = .empty,
wide_lits: std.ArrayList(u32) = .empty,
/// §7.3.1 the `discrete_inputs` that are a `reg` wider than 32 bits, name →
/// its number of 32-bit words: word 0 (bits 0 to 31) arrives in the `<name>`
/// `Model` field, word k in `<name>__w<k>`, so a part-select anywhere in the
/// `reg` reads exact bits.
discrete_words: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// §7.3.6.4 / §7.3.1 the other direction: module variables a digital
/// expression reads and the discrete context does not assign (the analog
/// block's), name → first reading token. The mixed runner copies each one's
/// §5.10 held value into the digital engine after every accepted solution.
discrete_reads: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// §7.3.3 / §6.7.1 each terminal a digital `V(...)` probe names, spelled as
/// the digital half spells it (a hierarchical name's parts joined by `.`),
/// → the node pair whose potential difference it reads, `""` for ground: a
/// named branch's terminals, or the net and ground. The mixed runner reads a
/// probe through it (`probe_terminals`).
discrete_probes: std.StringArrayHashMapUnmanaged([2][]const u8) = .empty,
/// §6.3.4 scalar parameters read by the discrete source, including defaults
/// they depend on. The mixed host transports selected real values from the
/// derived model card; unrelated analog parameters need no digital storage.
discrete_params: std.StringArrayHashMapUnmanaged(u32) = .empty,
/// The module's discrete half needs the event queue (`lower_context.isMixed`).
mixed_signal: bool = false,
/// §7.8.4 the connect modules elaboration inserted (see `Elaborate.Design.inserts`).
inserts: []const Inserted = &.{},
/// §9.18 Table 9-29 domains of card-dependent system parameters
/// (`Elaborate.SystemCheck`), each value lowered over the parameters.
/// Codegen's `checkCard` names the first one the card puts outside.
system_checks: std.ArrayList(SystemCheck) = .empty,

/// Returns the byte range of token `tok`, for a diagnostic.
pub fn tokenSpan(self: *const Lowered, tok: u32) diag.Span {
    return self.token_span(self.src, self.tok_starts, tok);
}

/// `token_span` until lowering sets it: a `Lowered` with no token list
/// (a test's) points every token at the end of `src`, as the lexer's
/// `tokenSpan` does past its last token. Asserts that there is no list.
fn noTokens(src: []const u8, starts: []const u32, tok: u32) diag.Span {
    std.debug.assert(tok >= starts.len);
    const end: u32 = @intCast(src.len);
    return .{ .start = end, .end = end };
}

/// Returns the name codegen prints for a `nodes` row, or "gnd" for `ground`.
pub fn nodeName(self: *const Lowered, idx: u32) []const u8 {
    return if (idx == ground) "gnd" else self.nodes.items(.name)[idx];
}

/// Returns the compile-time value of `$simparam(name)`, or null (LRM §9.15 Table 9-27).
pub fn simparamValue(self: *const Lowered, name: []const u8) ?f64 {
    return simparam.simparamValueIn(self.timescale, name);
}

/// Where a §9.15 `$simparam(name [, expression])` gets its value. One owner,
/// so the analog block (`call.zig`), the parameter-default fold
/// (`Analysis.foldStep`) and the `derive()` renderer (`host_expr.f64Const`)
/// answer in the same order.
pub const SimparamAnswer = union(enum) {
    /// `iteration`, `dt`: `SimState`, which changes during a run, so no
    /// card-time value exists (a parameter default over one stays W1050).
    runtime,
    /// A host-written `Model` field; `default` is its declared value.
    host: struct { field: []const u8, default: f64 },
    /// VerA's own answer (`scale`, `shrink`, `timeUnit`, ...).
    value: f64,
    /// "If param_name is not known": the second argument.
    fallback,
    /// Not known and no second argument: E0811 refused a literal name.
    unknown,
};

/// Classifies `$simparam(name)` per §9.15: known names first (run-time,
/// host field, VerA's constant), then the fallback when the call has one.
pub fn simparamAnswer(self: *const Lowered, name: []const u8, has_fallback: bool) SimparamAnswer {
    if (simparam.simparamIsRuntime(name)) return .runtime;
    const v = self.simparamValue(name);
    if (simparam.simparamHostField(name)) |f| return .{ .host = .{ .field = f, .default = v.? } };
    if (v) |x| return .{ .value = x };
    return if (has_fallback) .fallback else .unknown;
}

test VecRange {
    // §3.6.3: `[msb:lsb]` in either order, over every pair in [-3, 3]. The
    // oracle is the definition: |msb - lsb| + 1 elements, the first one msb,
    // the last one lsb, each one step from the last, and `has` true on
    // exactly the elements `at` visits.
    var msb: i64 = -3;
    while (msb <= 3) : (msb += 1) {
        var lsb: i64 = -3;
        while (lsb <= 3) : (lsb += 1) {
            const r: VecRange = .{ .msb = msb, .lsb = lsb };
            const n = r.size();
            try std.testing.expectEqual(@abs(msb - lsb) + 1, n);
            try std.testing.expectEqual(msb, r.at(0));
            try std.testing.expectEqual(lsb, r.at(n - 1));
            for (1..n) |k| try std.testing.expectEqual(1, @abs(r.at(@intCast(k)) - r.at(@intCast(k - 1))));
            var i: i64 = -5;
            while (i <= 5) : (i += 1) {
                var visited = false;
                for (0..n) |k| visited = visited or r.at(@intCast(k)) == i;
                try std.testing.expectEqual(visited, r.has(i));
            }
        }
    }
}

test nodeName {
    // §1.3.1.1 the reference node is no row, and prints as `gnd`; a row
    // prints its own name.
    var l: Lowered = .{};
    defer l.nodes.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("gnd", l.nodeName(ground));
    try l.nodes.append(std.testing.allocator, .{ .name = "d", .kind = .net, .disc = "", .dir = .unspecified });
    try std.testing.expectEqualStrings("d", l.nodeName(0));
}

test tokenSpan {
    // Before lowering sets `token_span`, every token points at the end of `src`.
    const l: Lowered = .{ .src = "module m;" };
    try std.testing.expectEqual(diag.Span{ .start = 9, .end = 9 }, l.tokenSpan(3));
}

test simparamAnswer {
    // §9.15: a known name answers whether or not a fallback is written; an
    // unknown one returns the fallback, else is not known. Values are
    // VD-072's (`specification/Vague_Decisions.md`), not this table's.
    const l: Lowered = .{};
    const t = std.testing;
    for ([_]bool{ false, true }) |fb| {
        try t.expectEqual(SimparamAnswer.runtime, l.simparamAnswer("iteration", fb));
        try t.expectEqual(SimparamAnswer.runtime, l.simparamAnswer("dt", fb));
        try t.expectEqual(@as(f64, 1.0), l.simparamAnswer("scale", fb).value);
        try t.expectEqual(@as(f64, 1.0), l.simparamAnswer("shrink", fb).value);
        const h = l.simparamAnswer("tnom", fb).host;
        try t.expectEqualStrings("nom_temp__", h.field);
        try t.expectEqual(@as(f64, 27.0), h.default);
        try t.expectEqual(@as(f64, 1e-12), l.simparamAnswer("gmin", fb).host.default);
    }
    try t.expectEqual(SimparamAnswer.fallback, l.simparamAnswer("minr", true));
    try t.expectEqual(SimparamAnswer.unknown, l.simparamAnswer("minr", false));
    // IEEE 1364 §19.8: `timeUnit` is known only under a `timescale.
    try t.expectEqual(SimparamAnswer.fallback, l.simparamAnswer("timeUnit", true));
    const ts: Lowered = .{ .timescale = .{ .unit = 1e-6, .precision = 1e-9 } };
    try t.expectEqual(@as(f64, 1e-6), ts.simparamAnswer("timeUnit", true).value);
}
