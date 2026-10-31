//! The stage's narrow input and output: `Ctx` (what elaboration reads from
//! the compilation) and `Design` (what lowering reads back), with the row
//! types of `Design`'s side tables and the handles they hold. Types only;
//! `elaborate.zig` fills them. Every name a row holds is an interned
//! `Ast.StrId` of `Ctx.file` when the walk had one interned; the rows whose
//! name the walk builds as text (an instance path, a report name) keep the
//! bytes, since interning them would renumber every id interned after them.
//! Cites: LRM §3.6.5, §5.4.3, §5.5.3, §6.2.2, §6.3.1, §6.4.2, §6.4.3,
//! §6.5.5, §6.5.7.1, §6.7, §6.7.1, §7.2.4, §7.8.4, §9.15, §9.18 Table 9-29;
//! IEEE 1364-2005 §5.2.1, §12.3.3, §19.9.
//!
//! Contents:
//! - `pub const DisciplineResolution`
//! - `pub const ParamOverride`
//! - `pub const Inserted`
//! - `pub const Error`
//! - `pub const sep: u8`
//! - `pub const Ctx = struct`
//! - `pub const UnitId = enum(u32)`
//! - `pub const ModuleId = enum(u32)`
//! -   `pub fn of(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl) ModuleId`
//! -   `pub fn get(id: ModuleId, file: *const Ast.SourceFile) *const Ast.ModuleDecl`
//! - `pub const Design = struct`
//! - `pub const Unit = struct`
//! - `pub const NameSite = struct`
//! - `pub const PortAmmeter = struct`
//! - `pub const PsOutput = struct`
//! - `pub const ParamsetDefparam = struct`
//! - `pub const PortWidth = struct`
//! - `pub const SignalDiscipline = struct`
//! - `pub const PortConcat = struct`
//! - `pub const PartRange = struct`
//! -   `pub fn of(r: PartRange, parts: []const NetPart) []const NetPart`
//! - `pub const NetPart = struct`
//! -   `pub const Select = enum(u8)`
//! - `pub const SystemCheck = struct`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const directive_events = @import("frontend").directive_events;
const diag = @import("diag");
const hier_param = @import("hier_param.zig");

/// §7.4.4 basic or detail discipline resolution (`base`'s).
pub const DisciplineResolution = @import("base").DisciplineResolution;

/// §3.4 compile-time overrides, shared with Lower.Options (`base`'s).
pub const ParamOverride = @import("base").ParamOverride;

/// One port §7.8.4 re-pointed at a connect module (`base`'s, which
/// documents the fields).
pub const Inserted = @import("base").Inserted;

/// Every way `elaborate` fails. The bag holds whatever was diagnosed; no
/// `Design` is returned and the rows appended to `Ctx.file` stay (they are
/// numbered after the parse's and nothing reads them).
pub const Error = error{
    /// An arena allocation failed.
    OutOfMemory,
    /// A.1.2 lets a source_text hold no module_declaration at all (a file of
    /// `discipline`/`nature` declarations is legal), but a device needs one.
    /// The caller reports E1001, since "no module" is only an error relative
    /// to what was asked for.
    NoModule,
    /// Something in the instance tree was diagnosed; the bag holds the
    /// diagnostics.
    DiagnosticsReported,
};

/// The separator between levels of a flattened hierarchical name (LRM §6.7).
///
/// A period, as §6.7's `hierarchical_identifier` writes it, so a flat name in
/// a diagnostic or an emitted identifier reads like the source reference. An
/// escaped identifier may contain a period (§2.8.1, `\x.y `), but
/// `parser.internTok` interns that period as a space, so a period in a flat
/// name is always a join and the mangling is injective.
pub const sep: u8 = '.';

/// Everything elaboration needs from the compilation. `file` is MUTABLE because
/// flattening appends: new interned names (§6.7 paths), cloned expression rows
/// and cloned statements. It is an overlay of the parse
/// (`Ast.SourceFile.overlay`), so they land in the overlay's own rows, numbered
/// after the parser's, and the parse is never written. Nothing is rewritten in
/// place, so every id the parser handed out stays valid.
pub const Ctx = struct {
    /// Every row elaboration allocates, and the `Design` it returns, live
    /// here; the caller frees it with the compilation.
    arena: std.mem.Allocator,
    file: *Ast.SourceFile,
    /// The preprocessed source and its token starts, for diagnostic spans and
    /// E.3.2.1's attribute targets.
    src: []const u8,
    tok_starts: []const u32,
    /// Where every diagnostic goes; elaboration only appends.
    bag: *diag.Bag,
    param_overrides: []const ParamOverride = &.{},
    discipline_resolution: DisciplineResolution = .basic,
    /// §10.2's directives: §3.9 names a digital primitive's side of a net
    /// with the one in force at the primitive (`insert.plan`).
    default_disciplines: []const directive_events.DefaultDiscipline = &.{},
};

/// A row of `Design.units`, and the value `Ast.AnalogBlock.unit` holds: 0 is
/// the top, each inlined instance the next id in walk order. `none` is no
/// unit.
pub const UnitId = enum(u32) { top = 0, none = std.math.maxInt(u32), _ };

/// A row of `Ast.SourceFile.modules`: the declaration a unit was inlined
/// from. `none` is no module.
pub const ModuleId = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    /// Returns the handle of `m`. Asserts that `m` is a row of `file.modules`,
    /// not a copy.
    pub fn of(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl) ModuleId {
        const mods = file.modules;
        assert(@intFromPtr(m) >= @intFromPtr(mods.ptr));
        assert(@intFromPtr(m) < @intFromPtr(mods.ptr + mods.len));
        const i = (@intFromPtr(m) - @intFromPtr(mods.ptr)) / @sizeOf(Ast.ModuleDecl);
        return @fromBackingInt(@intCast(@as(u32, @intCast(i))));
    }

    /// Returns the declaration `id` names. Asserts that `id` is a row of
    /// `file.modules`.
    pub fn get(id: ModuleId, file: *const Ast.SourceFile) *const Ast.ModuleDecl {
        assert(id != .none);
        assert(@backingInt(id) < file.modules.len);
        return &file.modules[@backingInt(id)];
    }
};

/// The elaborated design lowering walks: one module with the hierarchy already
/// applied. Runtime dynamic hierarchical access (`$simprobe` with a computed
/// path) cannot be answered from it; every §6.7 reference must resolve here.
/// Every slice and map points into `Ctx.arena`.
pub const Design = struct {
    /// The root of §6.2.2's instance tree, with every reachable child inlined:
    /// the module whose ports are the device's terminals. A tree of one is the
    /// parsed module itself, by pointer.
    top: *const Ast.ModuleDecl,
    /// §6.7 hierarchical path → the flat net that path denotes.
    ///
    /// Holds only the rows that are not the identity: the flat name is the
    /// path joined with `sep`, so every reader does `get(p) orelse p`. The
    /// rows are connected child ports: `u.a` bound to parent net `p` has no
    /// node of its own, and §6.7.1 still lets `V(u.a)` name it. Empty for a
    /// tree of one.
    names: std.StringHashMapUnmanaged(Ast.StrId) = .empty,
    /// §4.4 the `names` rows' own declarations: a connected child port's path
    /// → the discipline the child declares for it, when it declares one. The
    /// joined net's discipline may be another (§3.6.2.3's domainless net), and
    /// `V(u.a)` names the port.
    port_disciplines: std.StringHashMapUnmanaged(Ast.StrId) = .empty,
    /// §3.6.5's STRUCTURAL implicit nets: "Nets can be used in structural
    /// descriptions without being declared." One row per instance port actual
    /// naming a net the instantiating module never declared. Reported, not
    /// judged: legality is IEEE 1364 §19.2 `default_nettype`, a positional
    /// directive this pass cannot see (`Lower.rejectImplicitNet`).
    implicit_nets: []const NameSite = &.{},
    /// §6.2.2 "a blank port connection shall represent the situation where the
    /// port is not to be connected", for an `input` port: one row per such
    /// port, naming the internal net the flatten gave it. Judged later: IEEE
    /// 1364 §19.9 `unconnected_drive` is positional text.
    unconnected_inputs: []const NameSite = &.{},
    /// §9.15 Table 9-28's two hierarchy rows, indexed by `UnitId`
    /// (`Ast.AnalogBlock.unit`): "module" and "the hierarchical name of the
    /// instance". Flattening erases both, so the walk publishes them. Row 0 is
    /// the top. Read by column (`items(.path)`).
    units: std.MultiArrayList(Unit).Slice = .empty,
    /// §7.8.4 every port an automatic connect module was inserted on, for the
    /// mixed-signal runner: its digital engine elaborates the SOURCE hierarchy,
    /// in which the bridges do not exist.
    inserts: []const Inserted = &.{},
    /// §6.5.7.1 "a vector port can be connected to a vector net or
    /// concatenated net expression of the matching width": one row per port
    /// connected to a concatenation or to §6.5.5's member or sub-range of a
    /// net, its parts a range of `net_parts`.
    port_concats: []const PortConcat = &.{},
    /// Every `PortConcat`'s members, each concat's run contiguous and in its
    /// row's order.
    net_parts: []const NetPart = &.{},
    /// §6.5.7.1 "The sizes of the ports and net must match": one row per port
    /// bound to a net, for lowering to fold and compare.
    port_widths: []const PortWidth = &.{},
    /// §7.2.4's continuous segments of one signal retain their local
    /// disciplines even when flattening gives the signal one net declaration.
    /// Lowering folds their potential tolerances into the shared node's
    /// minimum.
    signal_disciplines: []const SignalDiscipline = &.{},
    /// §5.5.3 attribute reads on bound ports keep the source segment's
    /// discipline even after the expression names the shared flattened net.
    attribute_disciplines: std.AutoHashMapUnmanaged(Ast.ExprId, Ast.StrId) = .empty,
    /// §4.4 accesses in a child that `access.localAccess` already judged
    /// against the child's own declaration, on a node whose discipline binds
    /// no nature for that half (§3.11.1's natureless or domainless parent).
    local_accesses: std.AutoHashMapUnmanaged(Ast.ExprId, void) = .empty,
    /// §6.4.3 "If a paramset variable without a description has the same name
    /// as a module output variable, the module output variable shall not be
    /// available for instances using the paramset." The flat names of those
    /// variables (`path ++ name`, not interned), for §9.16's `$simprobe`.
    ps_hidden: []const []const u8 = &.{},
    /// §6.8 IEEE 1364-2005 §12.3.3: the flat names of the output ports
    /// "declared as a variable" that the walk renamed onto the net their
    /// parent connects. Such a variable is in the child's scope and the net
    /// in the parent's, so sharing one flat name is not two declarations in
    /// one scope (`lower_var.checkOneItemPerScope`).
    port_vars: []const Ast.StrId = &.{},
    /// §5.4.3/§6.7.1 the instance ports whose flow is read, each split off the
    /// parent's net onto an internal net of its own: lowering reads the port's
    /// flow as that branch's current, a §5.4.2.1 flow probe.
    port_ammeters: []const PortAmmeter = &.{},
    /// §6.4.3 "Integer or real variables in the paramset declared with
    /// descriptions are considered output variables": one row per such
    /// variable of a paramset instance, for §9.16's `$simprobe`.
    ps_outputs: []const PsOutput = &.{},
    /// §6.3.1/§6.4 defparams encountered below a paramset instance, with the
    /// generate condition that decides whether that hierarchy exists. Lowering
    /// judges them after the final parameter values (including --param) exist.
    paramset_defparams: []const ParamsetDefparam = &.{},
    /// §6.4.2 values read while choosing an overloaded paramset. The host must
    /// re-elaborate when these shape parameters change, as for generate
    /// schemes. May repeat a name; readers treat it as a set.
    selection_params: []const Ast.StrId = &.{},
    /// §9.18 Table 9-29 domains to check at card time (`SystemCheck`).
    system_checks: []const SystemCheck = &.{},
};

/// One `Design.units` row. Read by column; the three are read together only
/// by the VPI's scope tree.
pub const Unit = struct {
    /// The module name §9.15's "module" row reports.
    module: Ast.StrId,
    /// The instance prefix, separator included and empty at the top, so
    /// `path ++ local` is the flat name.
    path: []const u8,
    /// The definition this unit was inlined FROM: the module `lookup`
    /// named, or the end of the §6.4.2-selected paramset's chain. Published so
    /// the VPI's `vpiDefName` and ports (Clause 11) read the answer instead of
    /// re-resolving the name by a second rule.
    decl: ModuleId,
};

/// A name the flatten wants a later stage to judge, and the token it was
/// written at: what a positional compiler directive is looked up by, and what
/// a diagnostic points at.
pub const NameSite = struct { name: Ast.StrId, main_tok: u32 };

/// One `Design.port_ammeters` row: the port's own internal net and the
/// parent's net it was connected to.
pub const PortAmmeter = struct { internal: Ast.StrId, bound: Ast.StrId };

/// One `Design.ps_outputs` row: the name an instance reports the variable
/// under (`path ++ name`, not interned) and the flat variable holding it
/// (`path ++ paramset ++ sep ++ name`, beside the paramset's parameters).
pub const PsOutput = struct { report: []const u8, flat: Ast.StrId };

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
    net: Ast.StrId,
    /// The child's declared range, cloned into the flat namespace so a
    /// parameter in it folds against the instance's own overrides; null for
    /// a scalar port.
    range: ?Ast.Dim,
    main_tok: u32,
};

/// One flattened net's §7.2.4 segment: the net and the discipline one of its
/// hierarchical segments declares.
pub const SignalDiscipline = struct { net: Ast.StrId, discipline: Ast.StrId };

/// One `Design.port_concats` row: a port bound bit by bit to parent nets, a
/// concatenation (LRM §6.5.7.1) or a bit- or part-select (§6.5.5). The port's
/// element k (declaration order, msb first per IEEE 1364 §12.3.9.2) is bit k
/// of its parts read left to right. Lowering interns no node for it: each
/// element aliases its net's node.
pub const PortConcat = struct {
    /// The port's flat name.
    name: Ast.StrId,
    /// The child's declared range, cloned into the flat namespace. Null for
    /// a scalar port bound to one bit (§6.5.5 `.v(bus[1])`).
    range: ?Ast.Dim,
    /// The connection's members in `Design.net_parts`: one for a select, one
    /// per operand of a concatenation.
    parts: PartRange,
    main_tok: u32,
};

/// A run of `Design.net_parts`.
pub const PartRange = struct {
    start: u32,
    len: u32,

    /// Returns the run of `parts` this range names. Asserts that it lies in
    /// `parts`.
    pub fn of(r: PartRange, parts: []const NetPart) []const NetPart {
        assert(r.start <= parts.len);
        assert(r.len <= parts.len - r.start);
        return parts[r.start..][0..r.len];
    }
};

/// One member of a `PortConcat` connection: a parent net, whole or under the
/// constant select the connection wrote, its bounds folded in the parent's
/// names. Lowering, which knows each net's declared range, checks the select
/// against it and expands the part to bits.
pub const NetPart = struct {
    net: Ast.StrId,
    /// `[a]`, `[a:b]`, or IEEE 1364-2005 §5.2.1's `[a +: b]` and `[a -: b]`.
    sel: Select = .whole,
    /// The select's first and second folded values; `b == a` for a bit,
    /// both 0 for a whole net.
    a: i64 = 0,
    b: i64 = 0,

    /// The select a `NetPart` was written with.
    pub const Select = enum(u8) { whole, bit, range, up, down };

    comptime {
        // One row per connection member: two i64 bounds dominate.
        assert(@sizeOf(NetPart) == 24);
    }
};

/// §9.18 a hierarchical system parameter's specified value that reads the
/// model card, so Table 9-29's "Allowed values" can only be checked when the
/// host writes the card (codegen's `checkCard`). `value` is in the flat
/// namespace; `name` is what the check reports: `path$kind`, or a top-level
/// alias's own spelling.
pub const SystemCheck = struct { kind: hier_param.Kind, value: Ast.ExprId, name: []const u8 };

comptime {
    // The narrowed rows: two handles each, or a handle and a token.
    assert(@sizeOf(NameSite) == 8);
    assert(@sizeOf(PortAmmeter) == 8);
    assert(@sizeOf(SignalDiscipline) == 8);
    assert(@sizeOf(UnitId) == 4);
    assert(@sizeOf(ModuleId) == 4);
}
