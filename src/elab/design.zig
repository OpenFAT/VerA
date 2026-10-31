//! The stage's narrow output and input: `Ctx` (what elaboration reads from
//! the compilation) and `Design` (what lowering reads back), with the row
//! types of `Design`'s side tables. Types only; `elaborate.zig` fills them.
//! Cites: LRM §3.6.5, §5.4.3, §6.2.2, §6.3.1, §6.4.2, §6.4.3, §6.5.7.1, §6.7,
//! §6.7.1, §7.2.4, §7.8.4, §9.15, §9.18 Table 9-29; IEEE 1364-2005 §12.3.3,
//! §19.9.
//!
//! Contents:
//! - `pub const Error = error{ OutOfMemory, NoModule, DiagnosticsReported };`
//! - `pub const sep = '.';`
//! - `pub const Ctx = struct`
//! - `pub const DisciplineResolution`
//! - `pub const ParamOverride`
//! - `pub const Design = struct`
//! - `pub const UnitPath = struct`
//! - `pub const NameSite = struct`
//! - `pub const PortAmmeter = struct`
//! - `pub const PsOutput = struct`
//! - `pub const ParamsetDefparam = struct`
//! - `pub const PortWidth = struct`
//! - `pub const SignalDiscipline = struct`
//! - `pub const PortConcat = struct`
//! - `pub const NetPart = struct`
//! - `pub const Inserted`
//! - `pub const SystemCheck = struct`

const std = @import("std");
const Ast = @import("frontend").Ast;
const diag = @import("diag");
const hier_param = @import("hier_param.zig");

/// `NoModule`: A.1.2 lets a source_text hold no module_declaration at all
/// (a file of `discipline`/`nature` declarations is legal), but a device needs
/// one. The caller reports E1001, since "no module" is only an error relative
/// to what was asked for.
///
/// `DiagnosticsReported`: something in the instance tree was diagnosed; the
/// bag holds the diagnostics and no design is returned.
pub const Error = error{ OutOfMemory, NoModule, DiagnosticsReported };

/// The separator between levels of a flattened hierarchical name (LRM §6.7).
///
/// A period, as §6.7's `hierarchical_identifier` writes it, so a flat name in
/// a diagnostic or an emitted identifier reads like the source reference. An
/// escaped identifier may contain a period (§2.8.1, `\x.y `), but
/// `parser.internTok` interns that period as a space, so a period in a flat
/// name is always a join and the mangling is injective.
pub const sep = '.';

/// Everything elaboration needs from the compilation. `file` is MUTABLE because
/// flattening appends: new interned names (§6.7 paths), cloned expression rows
/// and cloned statements. It is an overlay of the parse
/// (`Ast.SourceFile.overlay`), so they land in the overlay's own rows, numbered
/// after the parser's, and the parse is never written.
/// Nothing is ever rewritten in place, so every id the parser handed out
/// stays valid.
pub const Ctx = struct {
    arena: std.mem.Allocator,
    file: *Ast.SourceFile,
    src: []const u8,
    tok_starts: []const u32,
    bag: *diag.Bag,
    param_overrides: []const ParamOverride = &.{},
    discipline_resolution: DisciplineResolution = .basic,
    /// §10.2's directives: §3.9 names a digital primitive's side of a net
    /// with the one in force at the primitive (`insert.plan`).
    default_disciplines: []const @import("frontend").Preprocessor.DefaultDiscipline = &.{},
};

/// §7.4.4 basic or detail discipline resolution (`base`'s).
pub const DisciplineResolution = @import("base").DisciplineResolution;

/// §3.4 compile-time overrides, shared with Lower.Options (`base`'s).
pub const ParamOverride = @import("base").ParamOverride;

/// The elaborated design lowering walks: one module with the hierarchy already
/// applied. Runtime dynamic hierarchical access (`$simprobe` with a computed
/// path) cannot be answered from it; every §6.7 reference must resolve here.
pub const Design = struct {
    /// The root of §6.2.2's instance tree, with every reachable child inlined:
    /// the module whose ports are the device's terminals.
    top: *const Ast.ModuleDecl,
    /// §6.7 hierarchical path → the flat name that path denotes.
    ///
    /// Holds only the rows that are not the identity: the flat name is the
    /// path joined with `sep`, so every reader does `get(p) orelse p`. The rows
    /// are connected child ports: `u.a` bound to parent net `p` has no node of
    /// its own, and §6.7.1 still lets `V(u.a)` name it.
    ///
    /// Empty for a tree of one: with nothing renamed there is no path but the
    /// module's own names, and those resolve without it.
    names: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// §4.4 the `names` rows' own declarations: a connected child port's path
    /// → the discipline the child declares for it, when it declares one. The
    /// joined net's discipline may be another (§3.6.2.3's domainless net), and
    /// `V(u.a)` names the port.
    port_disciplines: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// §3.6.5's STRUCTURAL implicit nets: "Nets can be used in structural
    /// descriptions without being declared." One entry per instance port actual
    /// naming a net the instantiating module never declared.
    ///
    /// Reported, not judged: the child's declaration already supplies the
    /// discipline (§7.4), and legality is IEEE 1364 §19.2 `default_nettype`, a
    /// positional directive this pass cannot see (`Lower.rejectImplicitNet`).
    implicit_nets: []const NameSite = &.{},
    /// §6.2.2 "a blank port connection shall represent the situation where the
    /// port is not to be connected", for an `input` port. One entry per such
    /// port, naming the internal net the flatten gave it.
    ///
    /// Judged later for the same reason: IEEE 1364 §19.9 `unconnected_drive`
    /// is positional text (`Lower.applyUnconnectedDrive`).
    unconnected_inputs: []const NameSite = &.{},
    /// §9.15 Table 9-28's two hierarchy rows, indexed by `Ast.AnalogBlock.unit`:
    /// "module" is "the name of the module from which $simparam$str is called"
    /// and "instance" is "the hierarchical name of the instance". Flattening
    /// erases both, so the walk publishes them here. §9.16's sibling scope
    /// ("in the parent of the current instance") reads `path` too.
    units: []const UnitPath = &.{},
    /// §7.8.4 every port an automatic connect module was inserted on, for the
    /// mixed-signal runner: its digital engine elaborates the SOURCE hierarchy,
    /// in which the bridges do not exist.
    inserts: []const Inserted = &.{},
    /// §6.5.7.1 "a vector port can be connected to a vector net or
    /// concatenated net expression of the matching width". One entry per port
    /// connected to a concatenation or to §6.5.5's scalar member or sub-range
    /// of a net (`.v(bus[1])`, `.w(bus[3:2])`): the child's port, renamed to a flat
    /// name of its own, whose element k (declaration order, msb first per IEEE
    /// 1364 §12.3.9.2) is bit k of `parts`, read left to right. Lowering
    /// interns no node for it: each element aliases its net's node
    /// (`lower_node.bindPortConnections`).
    port_concats: []const PortConcat = &.{},
    /// §6.5.7.1 "The sizes of the ports and net must match." One entry per
    /// port bound to a net: the bound flat net and the child's declared range
    /// (null for a scalar port), for lowering to fold and compare.
    port_widths: []const PortWidth = &.{},
    /// §7.2.4's continuous segments of one signal retain their local
    /// disciplines even when flattening gives the signal one net declaration.
    /// Lowering folds their potential tolerances into the shared node's minimum.
    signal_disciplines: []const SignalDiscipline = &.{},
    /// §5.5.3 attribute reads on bound ports keep the source segment's
    /// discipline even after the expression names the shared flattened net.
    attribute_disciplines: std.AutoHashMapUnmanaged(Ast.ExprId, Ast.StrId) = .empty,
    /// §4.4 accesses in a child that `names.localAccess` already judged
    /// against the child's own declaration, on a node whose discipline binds
    /// no nature for that half (§3.11.1's natureless or domainless parent).
    local_accesses: std.AutoHashMapUnmanaged(Ast.ExprId, void) = .empty,
    /// §6.4.3 "If a paramset variable without a description has the same name
    /// as a module output variable, the module output variable shall not be
    /// available for instances using the paramset." The flat names of those
    /// variables, for §9.16's `$simprobe` to treat as unresolvable.
    ps_hidden: []const []const u8 = &.{},
    /// §6.8 IEEE 1364-2005 §12.3.3: the flat names of the output ports
    /// "declared as a variable" that the walk renamed onto the net their
    /// parent connects (`instance.zig`). Such a variable is in the child's
    /// scope and the net in the parent's, so sharing one flat name is not
    /// two declarations in one scope (`lower_var.checkOneItemPerScope`).
    port_vars: []const Ast.StrId = &.{},
    /// §5.4.3/§6.7.1 the instance ports whose flow is read, each split off the
    /// parent's net onto an internal net of its own (`instance.zig`): one
    /// row per such port, the internal net's flat name and the parent's net
    /// it hangs from. Lowering reads the port's flow as that branch's current,
    /// a §5.4.2.1 flow probe (Figure 5-1's ammeter).
    port_ammeters: []const PortAmmeter = &.{},
    /// §6.4.3 "Integer or real variables in the paramset declared with
    /// descriptions are considered output variables", and "the paramset's
    /// value is reported for instances using the paramset": one row per such
    /// variable of a paramset instance, for §9.16's `$simprobe`.
    ps_outputs: []const PsOutput = &.{},
    /// §6.3.1/§6.4 defparams encountered below a paramset instance, with the
    /// generate condition that decides whether that hierarchy exists. Lowering
    /// judges them after the final parameter values (including --param) exist.
    paramset_defparams: []const ParamsetDefparam = &.{},
    /// §6.4.2 values read while choosing an overloaded paramset. The host must
    /// re-elaborate when these shape parameters change, as for generate schemes.
    selection_params: []const Ast.StrId = &.{},
    /// §9.18 Table 9-29 domains to check at card time (`SystemCheck`).
    system_checks: []const SystemCheck = &.{},
};

/// One entry of `Design.units`. `path` is the instance prefix, separator
/// included and empty at the top, so `path ++ local` is the flat name.
pub const UnitPath = struct {
    module: []const u8,
    path: []const u8,
    /// The definition this unit was inlined FROM: the module `findModule`
    /// named, or the end of the §6.4.2-selected paramset's chain. Published so
    /// the VPI's `vpiDefName` and ports (Clause 11) read the answer instead of
    /// re-resolving the name by a second rule.
    decl: *const Ast.ModuleDecl,
};

/// A name the flatten wants a later stage to judge, and the token it was
/// written at. The token is what a positional compiler directive is looked up
/// by, and what a diagnostic points at.
pub const NameSite = struct { name: []const u8, main_tok: u32 };

/// One `Design.port_ammeters` row: the flat names of the port's own internal
/// net and of the parent's net it was connected to.
pub const PortAmmeter = struct { internal: []const u8, bound: []const u8 };

/// One `Design.ps_outputs` row: the name an instance reports the variable
/// under (`path ++ name`) and the flat variable holding it (`path ++
/// paramset ++ sep ++ name`, beside the paramset's parameters).
pub const PsOutput = struct { report: []const u8, flat: []const u8 };

/// A defparam is forbidden only in an instantiated paramset hierarchy:
/// §6.6.2 leaves an unselected generate arm out of the model. Flattening keeps
/// both arms, so the flattened gate travels with the source diagnostic site.
pub const ParamsetDefparam = struct {
    /// The defparam statement's token, where the diagnostic points.
    main_tok: u32,
    /// The nearest paramset instance's path, without its trailing `sep`.
    instance: []const u8,
    /// The unit's §6.6 gate in flat names; `.none` when no scheme gates it.
    gate: Ast.ExprId,
};

/// One `Design.port_widths` row: a port bound to a flat net, for the §6.5.7.1
/// size check.
pub const PortWidth = struct {
    net: []const u8,
    /// Cloned into the flat namespace, as `PortConcat.range` is.
    range: ?Ast.Dim,
    main_tok: u32,
};

/// One hierarchical net segment attached to the flattened signal `net`.
pub const SignalDiscipline = struct { net: []const u8, discipline: []const u8 };

/// One `Design.port_concats` row: a port bound bit by bit to parent nets, a
/// concatenation (LRM §6.5.7.1) or a bit- or part-select (§6.5.5).
pub const PortConcat = struct {
    /// The port's flat name.
    name: []const u8,
    /// The child's declared range, cloned into the flat namespace so a
    /// parameter in it folds against the instance's own overrides. Null for
    /// a scalar port bound to one bit (§6.5.5 `.v(bus[1])`).
    range: ?Ast.Dim,
    /// The connection's members, left to right: one for a select, one per
    /// operand of a concatenation.
    parts: []const NetPart,
    main_tok: u32,
};

/// One member of a `PortConcat` connection: a parent net (its flat name),
/// whole or under the constant select the connection wrote, its bounds folded
/// in the parent's names. Lowering, which knows each net's declared range,
/// checks the select against it and expands the part to bits.
pub const NetPart = struct {
    net: []const u8,
    /// `[a]`, `[a:b]`, or IEEE 1364-2005 §5.2.1's `[a +: b]` and `[a -: b]`.
    sel: enum { whole, bit, range, up, down } = .whole,
    /// The select's first and second folded values; `b == a` for a bit,
    /// both 0 for a whole net.
    a: i64 = 0,
    b: i64 = 0,
};

/// One port §7.8.4 re-pointed at a connect module (`base`'s, which
/// documents the fields).
pub const Inserted = @import("base").Inserted;

/// §9.18 a hierarchical system parameter's specified value that reads the
/// model card, so Table 9-29's "Allowed values" can only be checked when
/// the host writes the card (codegen's `checkCard`). `value` is in the flat
/// namespace; `name` is what the check reports: `path$kind`, or a top-level
/// alias's own spelling.
pub const SystemCheck = struct { kind: hier_param.Kind, value: Ast.ExprId, name: []const u8 };
