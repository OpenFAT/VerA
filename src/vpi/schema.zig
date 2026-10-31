//! The object model's row types: `Obj` (one per VPI object, hot), `Cold`
//! (the fields few rows carry), `Scope` (one per module instance), `Iter`,
//! and the edge, list and property rows `code` objects carry; plus the
//! lookups every routine shares over them (`typeOf`, `typeName`, `edgeTo`,
//! `coldOf`, `locate`).
//! Cites: VAMS-2023 §11.6 (the object diagrams), IEEE 1364-2005 §26.3.2,
//! §26.3.3, §26.6.
//!
//! Contents:
//! - `pub const Edge = struct`
//! - `pub const List = struct`
//! - `pub const Prop = struct`
//! - `pub const no_obj: u32`
//! - `pub const Kind = enum`
//! - `pub const OptU32 = enum`
//! - `pub fn OptU32.of(v: ?u32) OptU32`
//! - `pub fn OptU32.get(o: OptU32) ?u32`
//! - `pub const Obj = struct`
//! - `pub const no_cold = std.math.maxInt(u32)`
//! - `pub const Cold = struct`
//! - `pub const Loc = struct`
//! - `pub const Scope = struct`
//! - `pub const Iter = struct`
//! - `pub const name_buf_len = 4096`
//! - `pub fn typeOf(o: *const Obj) c_int`
//! - `pub fn typeName(t: c_int) []const u8`
//! - `pub fn locate(bag: *const @import("vera").diag.Bag, start: u32) Loc`
//! - `pub fn edgeTo(x: *const Obj, tag: c_int) u32`
//! - `pub fn coldOf(o: *const Obj) *const Cold`

const std = @import("std");
const Ast = @import("frontend").Ast;
const Lower = @import("ir").Lowered;
const Lowered = @import("ir").Lowered;
const abi = @import("abi.zig");
const code_tables = @import("code_tables.zig");
const session = @import("session.zig");
const user = @import("vpi_user.zig");

/// A single arrow: `vpi_handle(tag, obj)` answers object `to` (or `none`).
pub const Edge = struct { tag: c_int, to: u32 };

/// A double arrow: `vpi_iterate(tag, obj)` walks `items`.
pub const List = struct { tag: c_int, items: []const u32 };

/// An int or bool property `vpi_get(prop, obj)` answers.
pub const Prop = struct { prop: c_int, value: c_int };

/// "No object": an edge a diagram draws that this object does not have.
pub const no_obj: u32 = std.math.maxInt(u32);

/// The object classes the model answers; `typeOf` maps each to its `vpiType`.
pub const Kind = enum(u8) {
    module,
    port,
    net,
    reg,
    parameter,
    /// §11.6.10 `integer` and `real` variables.
    integer,
    real_var,
    /// IEEE 1364-2005 §26.6.8 a `time` variable.
    time_var,
    /// §11.6.10/§11.6.11 arrays. A reg array is IEEE 1364 §26.6.9's memory
    /// (vpiRegArray, vpiIsMemory); an integer or real array is a variable of
    /// its element type with vpiArray set (§26.6.7). Each holds its elements
    /// in `members`.
    reg_array,
    var_array,
    /// IEEE 1364-2005 §26.6.6 an array of nets; its elements are `.net`s.
    net_array,
    /// One element: a memory word (a vpiReg) or a variable select.
    word,
    var_select,
    /// §6.2.2's `u[1:0]`: one array object over its member module instances.
    module_array,
    /// An index expression — the object `vpiIndex` leads to. Always a
    /// decimal integer constant, read by vpi_get_value.
    constant,
    /// §11.6.2 a discipline and a nature: design-wide, reached from a NULL
    /// reference (the diagram's circled arrows), not from a module.
    discipline,
    nature,
    /// §11.6.5 the node of a continuous-discipline net. A second object
    /// beside the §11.6.8 net rather than a replacement for it: the net
    /// diagram draws net -> node as its own edge, and the net keeps its
    /// §11.6.8 properties and its place in module ->> net.
    node,
    /// §11.6.6 a declared branch, and §11.6.7 the two quantities it carries.
    branch,
    quantity,
    /// §11.6.3, §11.6.16–§11.6.24 the behavioural objects — processes,
    /// statements, continuous assignments, tasks, named events, expressions —
    /// typed by `vtype` and answered from their `edges`/`lists`/`props` rows
    /// (code.zig).
    code,
};

/// A `?u32` in four bytes rather than eight, for the `Obj` index fields most
/// rows leave empty: `none` is null, which `maxInt(u32)` can be because no
/// row, scope or engine slot index reaches it (`no_obj` is the same value).
pub const OptU32 = enum(u32) {
    none = std.math.maxInt(u32),
    _,

    /// Packs `v`. Asserts that `v` is not `maxInt(u32)`, the value `none`
    /// spends.
    pub fn of(v: ?u32) OptU32 {
        const x = v orelse return .none;
        std.debug.assert(x != std.math.maxInt(u32));
        return @fromBackingInt(@intCast(x));
    }

    /// Unpacks `o`: null for `none`.
    pub fn get(o: OptU32) ?u32 {
        return if (o == .none) null else @backingInt(o);
    }
};

/// One VPI object. Materialized once at `open`; a `vpiHandle` is a pointer to
/// one of these.
///
/// One struct for every class rather than a tagged union, so a `vpi_get` arm
/// switches on the property without first switching on a payload. Fields a
/// class does not use hold their defaults and are never read; each names its
/// owner. The fields only a few rows carry (analog topology, arrays,
/// attributes, event references) are out of line in `Cold`, reached through
/// `cold`.
pub const Obj = struct {
    kind: Kind,
    /// §11.6's "one-to-one relationship back to module": the containing
    /// module's SCOPE INDEX. For a `.module` this is its parent module.
    /// A lexical containing scope, such as a gen scope, is a separate
    /// vpiScope edge; runtime time-scale/storage lookup keeps this owner.
    owner: OptU32,
    /// `.module` only: which `Design.scopes` row is this module's own scope.
    scope: u32 = 0,
    /// §11.6 `vpiName` — the local name.
    name: []const u8,
    /// §11.6 `vpiFullName` — the hierarchical name, top module included.
    full: []const u8,
    /// §11.6.4/§11.6.8/§11.6.9 `vpiSize`; 1 for a scalar, 0 for a declared
    /// range that did not fold (see model_analog.zig `packedWidth`).
    /// Meaningless for a `.module` and a `.parameter`, which report
    /// `vpiUndefined` for it.
    size: u32 = 1,
    /// `.port` only — §6.5.2.2.
    direction: Ast.Direction = .unspecified,
    /// `.port` only — §11.6.4 `vpiPortIndex`, the position in the header.
    port_index: u32 = 0,
    /// `.parameter` only — §3.4.1, mapped onto §11.6.12's `vpiConstType`.
    ty: Ast.Type = .unspecified,
    /// `.parameter` only — §3.4.5.
    is_local: bool = false,
    /// `.reg` only.
    is_signed: bool = true,
    /// Declared in an automatic task or function (IEEE 1364-2005
    /// §26.6.20), or an event reference requiring such an activation.
    automatic: bool = false,
    /// `.net` only: IEEE 1364-2005 §26.6.6's vpiImplicitDecl, a net no
    /// declaration wrote (§4.5, §12.3.3).
    implicit: bool = false,
    /// The digital engine's storage slot for this object's value, when the
    /// design is a running digital one (`openDigital`). `.none` in the analog
    /// model, whose values come from analog.zig's solution.
    slot: OptU32 = .none,
    /// `.parameter` of the analog model: the constant lowering folded for it
    /// (`Lowered.consts`), copied; §11.6.12 NOTE 1's "the value of the
    /// parameter".
    value: ?Lower.Const = null,
    /// An element (word, var select, array member module): the array object
    /// it belongs to — §11.6.11's `vpiParent`, §6.2.2's `vpiModuleArray`.
    parent: OptU32 = .none,
    /// An element: the `.constant` object its `vpiIndex` edge leads to.
    index: OptU32 = .none,
    /// `.code`: the object type and the diagram's edges, as data. Any other
    /// class may carry `edges` and `props` too, answered after its own.
    vtype: c_int = 0,
    edges: []const Edge = &.{},
    lists: []const List = &.{},
    props: []const Prop = &.{},
    /// `.constant` only: §11.6.19's vpiConstType. 0 when the literal's base
    /// is not one this model records.
    const_type: c_int = user.vpiDecConst,
    /// `.code` only: written by the analog model (a call in an `analog`
    /// block names an analog systf, §12.32).
    in_analog: bool = false,
    /// The source an expression (`.code` or `.constant`) or a task call was
    /// built from, which `vpiDecompile` spells (IEEE 1364-2005 §26.6.26 b),
    /// §26.6.19 g)). Expressions also supply §26.6.19(e)'s lazy value reads;
    /// declared objects retain their storage-based path. `.none` means no source.
    src_expr: Ast.ExprId = .none,
    src_stmt: Ast.StmtId = .none,
    /// `.code` of the digital model: the main token of the statement it is —
    /// a gate, a UDP instance, a continuous assignment — which with `owner`
    /// names the engine driver §12.29's vpi_put_delays rewrites; of a system
    /// task or function call, the token the engine runs its calltf by
    /// (`systf.hook`); of a declaration, its IEEE §26.3.3 source location.
    /// Zero means no source token was recorded.
    src_tok: u32 = 0,
    /// `.code` statement: its AST statement, which with `owner` names the
    /// engine's `StmtSite`s for IEEE 1364-2005 §27.33.1.1's cbStmt.
    stmt: Ast.StmtId = .none,
    /// The instance supplying `src_expr`'s engine context. Expressions such
    /// as operations have no VPI scope relationship (`owner` is `.none`), but
    /// still need their original instance when an application reads them.
    expr_scope: OptU32 = .none,
    /// `.net` only: its A.2.2.1 net type, IEEE 1364-2005 §26.6.6 vpiNetType.
    net_type: Ast.NetKind = .wire,
    /// A continuous assignment's literal delays, in its module's time unit
    /// (IEEE 1364 §7.14: rise, fall, turn-off), for §12.11. Hot, not in
    /// `Cold`: §12.29's vpi_put_delays may give one to any gate or
    /// continuous assignment after `open`, when `Design.cold` is fixed.
    delays: []const f64 = &.{},
    /// This row's `Design.cold` entry, `no_cold` for none (every field of
    /// `Cold` at its default). Read it through `coldOf`.
    cold: u32 = no_cold,
};

/// `Obj.cold` of a row with no `Cold` entry.
pub const no_cold = std.math.maxInt(u32);

/// The fields of an `Obj` only a few classes carry, one row per object that
/// sets any of them (`Design.cold`, indexed by `Obj.cold`). A row without one
/// reads `Cold{}`, every default.
pub const Cold = struct {
    /// §26.6.11: a source reference to an event with nonconstant indices.
    /// Its identity is selected when used, in the declaring lexical scope.
    /// Automatic references require frame handles and are refused by put.
    event_ref: ?struct { expr: Ast.ExprId, scope: u32 } = null,
    /// IEEE §26.6.42: a folded attribute preserves its declared bit width
    /// and all x/z bits, which a signed i64 constant cannot represent.
    constant_bits: ?@import("frontend").Integer.Literal = null,
    attributes: []const u32 = &.{},
    /// An array: its elements, in increasing index.
    members: []const u32 = &.{},
    /// A digital array: its IEEE 1364-2005 §26.6.10 range, one `.code` object
    /// of vtype vpiRange (a slice, so vpi_iterate can walk it).
    range: []const u32 = &.{},
    /// The one-to-one edges of the analog classes (§11.6.2, §11.6.5–§11.6.7),
    /// as object indices. Null is "no such object", which vpi_handle answers
    /// with NULL and no error (a base nature has no parent, a one-terminal
    /// branch no named negative node).
    ///   disc       net, node, branch -> vpiDiscipline
    ///   node       net -> vpiNode
    ///   pos, neg   branch -> vpiPosNode, vpiNegNode
    ///   flow, pot  branch -> vpiFlow/vpiPotential quantity;
    ///              discipline -> vpiFlowNature/vpiPotentialNature
    ///   nature     quantity -> its nature; nature -> vpiParent
    ///   branch     quantity -> vpiBranch
    disc: ?u32 = null,
    node: ?u32 = null,
    pos: ?u32 = null,
    neg: ?u32 = null,
    flow: ?u32 = null,
    pot: ?u32 = null,
    nature: ?u32 = null,
    branch: ?u32 = null,
    /// The one-to-many edges of the analog classes:
    ///   nets       node ->> net
    ///   children   nature ->> nature (vpiChild), the natures derived from it
    ///   users      nature ->> discipline, the disciplines binding it
    nets: []const u32 = &.{},
    children: []const u32 = &.{},
    users: []const u32 = &.{},
    /// `.node` of the analog model: its `Lowered.nodes` row — the solver
    /// unknown whose value §12.10 reads for a potential. Null for a node the
    /// lowering never gave a row (declared, never reached by analog code).
    row: ?u32 = null,
    /// `.branch` of the analog model: the §5.6 contribution rows carrying its
    /// two values, by `Lowered.contributions` index — the potential source
    /// (whose branch-flow unknown IS the flow) and the flow source (whose
    /// row's value is). Both null is an open branch, which carries no flow.
    contrib_pot: ?u32 = null,
    contrib_flow: ?u32 = null,
    /// `.branch`: when `contrib_flow` is a row several instances share, this
    /// instance's own share of it, by `Lowered.contrib_shares` index: the
    /// flow §12.10 reads (§5.4.1).
    contrib_share: ?u32 = null,
    /// `.branch`: the terminal rows, `Lower.ground` for the reference node.
    hi_row: u32 = Lower.ground,
    lo_row: u32 = Lower.ground,
    /// `.branch`: its flow row absorbed another instance's `<+`
    /// (`Contribution.shared`) and holds no share of this instance's (it
    /// drives the pair only through another's branch, §5.6.8.2), or a named
    /// branch whose rows could not be told from a sibling's over the same
    /// pair: either way its own flow is not a number this model holds.
    flow_unknowable: bool = false,
    /// `.branch`: a declared branch whose (pos, neg) is the reverse of its
    /// source row's canonical pair — its flow is the row's, negated
    /// (§1.3.1.2: the reference direction is the declaration's).
    flow_neg: bool = false,
    /// A force/assign statement's RHS source expression. The engine's live
    /// override ranges retain this identity, so traversal can distinguish
    /// two source statements that write the same target (§26.6.6 i, j).
    override_expr: Ast.ExprId = .none,
    /// A vpiUdpDefn: its §11.6.14 vpiDefName. A primitive's is derived
    /// (`code.defName`).
    def_name: []const u8 = "",
    /// A net of a generated digital scope: that scope's engine index, where
    /// its source attribute expressions evaluate (the iteration's localparam
    /// included).
    src_engine: ?u32 = null,
    /// IEEE 1364-2005 §26.3.3 vpiLineNo and vpiFile, resolved when the model
    /// was built: the analog model's instances (model/analog.zig), whose
    /// compilation is freed after `open`. The digital model resolves its
    /// `Obj.src_tok` through its run instead. Null: none recorded.
    loc: ?Loc = null,
};

/// IEEE 1364-2005 §26.3.3: a 1-based line of a named source file, as
/// written (no §19.7 `line renumbering).
pub const Loc = struct { line: c_int, file: []const u8 };

/// One module instance, with the §11.6.1 one-to-many sets it is the reference
/// object of, as object indices; read-only after `open`.
///
/// Invariant, relied on by every traversal: scope `i`'s own `vpiModule` object
/// is `objects[i]` (modules are appended first, in scope order), so an
/// object's `owner` scope index is also its owner's object index.
pub const Scope = struct {
    parent: ?u32,
    /// §11.6.1 `vpiDefName`: the module definition this is an instance of,
    /// which the flattened design does not carry.
    def_name: []const u8,
    /// IEEE 1364-2005 §13.6 `vpiLibrary`, and `vpiConfig` (empty: none).
    library: []const u8 = "work",
    config: []const u8 = "",
    /// The §6.7 path relative to the top, `""` at the root. The key the flat
    /// declarations are bucketed by.
    path: []const u8,
    /// IEEE 1364-2005 §26.6.1 vpiTimeUnit and vpiTimePrecision, powers of ten
    /// of a second (§17.3.2 Table 17-10's exponents): the §19.8 time scale of
    /// this instance's definition. Null in the analog model, which has none.
    time_unit: ?i8 = null,
    time_precision: ?i8 = null,
    children: []const u32 = &.{},
    /// IEEE 1364-2005 §26.6.3 module ->> vpiInternalScope: the instances,
    /// then the gen scopes, tasks, functions and named blocks written here.
    internal: []const u32 = &.{},
    ports: []const u32 = &.{},
    nets: []const u32 = &.{},
    regs: []const u32 = &.{},
    params: []const u32 = &.{},
    integers: []const u32 = &.{},
    reals: []const u32 = &.{},
    reg_arrays: []const u32 = &.{},
    /// IEEE 1364-2005 §26.6.1 module ->> net array and ->> variables (every
    /// integer, time and real variable and variable array, in declaration
    /// order).
    net_arrays: []const u32 = &.{},
    variables: []const u32 = &.{},
    module_arrays: []const u32 = &.{},
    nodes: []const u32 = &.{},
    branches: []const u32 = &.{},
    /// §11.6.1's behavioural double arrows (code.zig), as tagged rows.
    lists: []const List = &.{},
    /// A digital model's `digital.Run` scope id for this instance.
    engine: u32 = 0,
};

/// §12.23's iterator. Individually allocated; a handle is a live iterator iff
/// it is a key of `Design.iters`.
pub const Iter = struct {
    /// Object indices, in §11.6's order, which is source order.
    items: []const u32,
    at: usize = 0,
    /// Handles to objects that are not in `Design.objects` (§11.6.25 time
    /// queues), OWNED by the iterator; scanned instead of `items` when set.
    handles: ?[]abi.vpiHandle = null,
    /// IEEE 1364-2005 §26.6.43: the reference handle it was made from
    /// (vpiUse, NULL for a NULL reference) and the type it iterates
    /// (vpiIteratorType).
    use: abi.vpiHandle = null,
    ty: c_int = 0,
};

/// Bound on a §6.7 name, both for the upward search above and for
/// `vpi_get_str`'s §12.12 buffer.
///
/// ponytail: 4 KiB, truncating. That is far past the hierarchical names real
/// designs make out of §2.8 identifiers (the instance tree itself has no depth
/// bound). In the search a name
/// that overflows simply fails that one scope's attempt and the walk continues,
/// so the ceiling costs a lookup rather than correctness. Upgrade path: `open`
/// already sees every `vpiFullName`, so it could size this from the longest.
pub const name_buf_len = 4096;

// Budget: the row every handle points at and every scan walks. 472 bytes
// before the cold split, 224 before `def_name` and `src_engine` left it; a
// new field that is not on most rows goes in `Cold`.
comptime {
    std.debug.assert(@sizeOf(Obj) == 200);
}

const empty_cold: Cold = .{};

/// `vpi_get(vpiType, o)`.
pub fn typeOf(o: *const Obj) c_int {
    return switch (o.kind) {
        .module => user.vpiModule,
        .port => user.vpiPort,
        .net => user.vpiNet,
        .reg, .word => user.vpiReg,
        .parameter => user.vpiParameter,
        .integer => user.vpiIntegerVar,
        .real_var => user.vpiRealVar,
        .time_var => user.vpiTimeVar,
        .reg_array => user.vpiRegArray,
        .net_array => user.vpiNetArray,
        .var_array => if (o.ty == .real) user.vpiRealVar else user.vpiIntegerVar,
        .var_select => user.vpiVarSelect,
        .module_array => user.vpiModuleArray,
        .constant => user.vpiConstant,
        .discipline => user.vpiDiscipline,
        .nature => user.vpiNature,
        .node => user.vpiNode,
        .branch => user.vpiBranch,
        .quantity => user.vpiQuantity,
        .code => o.vtype,
    };
}

/// §26.3.2's string form of a type: `vpi_get_str(vpiType, o)`.
pub fn typeName(t: c_int) []const u8 {
    if (code_tables.typeName(t)) |n| return n;
    return switch (t) {
        user.vpiModule => "vpiModule",
        user.vpiPort => "vpiPort",
        user.vpiNet => "vpiNet",
        user.vpiReg => "vpiReg",
        user.vpiParameter => "vpiParameter",
        user.vpiIntegerVar => "vpiIntegerVar",
        user.vpiRealVar => "vpiRealVar",
        user.vpiRegArray => "vpiRegArray",
        user.vpiTimeVar => "vpiTimeVar",
        user.vpiNetArray => "vpiNetArray",
        user.vpiVarSelect => "vpiVarSelect",
        user.vpiModuleArray => "vpiModuleArray",
        user.vpiConstant => "vpiConstant",
        user.vpiDiscipline => "vpiDiscipline",
        user.vpiNature => "vpiNature",
        user.vpiNode => "vpiNode",
        user.vpiBranch => "vpiBranch",
        user.vpiQuantity => "vpiQuantity",
        user.vpiIterator => "vpiIterator",
        user.vpiCallback => "vpiCallback",
        user.vpiSchedEvent => "vpiSchedEvent",
        user.vpiUserSystf => "vpiUserSystf",
        user.vpiTimeQueue => "vpiTimeQueue",
        user.vpiInterModPath => "vpiInterModPath",
        // else: `t` is always vpi_get(vpiType)'s answer, and every value it
        // can return has a prong above; this arm is unreachable, not a default.
        else => "vpiUndefined",
    };
}

/// Where span-currency offset `start` lands through `bag`'s source map (an
/// `include`d file names itself, a macro expansion its invocation): the
/// physical line, and the file name, borrowed from `bag`.
pub fn locate(bag: *const @import("vera").diag.Bag, start: u32) Loc {
    const at = bag.locate(.{ .start = start, .end = start }, null);
    const off = bag.toSourceOffset(at.file, at.offset);
    const text = bag.sourceText(at.file);
    return .{
        .line = @intCast(1 + std.mem.count(u8, text[0..@min(off, text.len)], "\n")),
        .file = bag.fileName(at.file),
    };
}

/// `x`'s first single arrow `tag`, or `no_obj`.
pub fn edgeTo(x: *const Obj, tag: c_int) u32 {
    for (x.edges) |e| if (e.tag == tag) return e.to;
    return no_obj;
}

/// The cold fields of `o`, a row of the installed design.
pub fn coldOf(o: *const Obj) *const Cold {
    return if (o.cold == no_cold) &empty_cold else &session.design.?.cold[o.cold];
}
