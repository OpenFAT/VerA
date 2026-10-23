//! The VPI object model and its C routines (LRM §11.6, §12.2-§12.35,
//! §12.33.2): an elaborated flat design, read back as its instance tree
//! (`CompileResult.unit_paths`, `hier_names`) -> one fixed array of `Obj` rows that
//! every `vpiHandle` points into.
//!
//! The spine, in the order a host drives it:
//!
//!   open / openDigital   model_analog.zig, model_digital.zig build the rows;
//!                        model.zig freezes them into the one `Design`
//!   runStartupRoutines   §12.33.2: the application registers (systf.zig,
//!                        callback.zig)
//!   the routines         handle.zig (§12.19-§12.22), iterate.zig (§12.23,
//!                        §12.35), property.zig (§12.5, §12.12, §12.18),
//!                        value.zig (§12.16, §12.30), analog.zig (§12.7-
//!                        §12.10, the analog run), run.zig (the digital run),
//!                        delays.zig (§12.11, §12.29), print.zig
//!                        (§12.24-§12.28)
//!   close                frees the model and resets every sibling registry
//!
//! This file owns the tables every sibling reads: the vpi_user.h constants,
//! the object model (`Obj`, `Scope`, `Iter`, `Design`) and the installed
//! `design`; plus the §12.2 error status, the handle trust boundary, and the
//! routines over handles in general (§12.2, §12.3, §12.4, §12.17).
//! `code.zig` and `attributes.zig` build the behavioural and attribute rows.

const std = @import("std");
const Ast = @import("frontend").Ast;
const Lower = @import("ir").Lowered;
const sim = @import("sim");

// The routine families that live in their own files. Referenced here so their
// `export fn`s are emitted and their tests run with this module's.
const print = @import("print.zig");
/// The digital run a host drives (`run.simulate`) and its time queues.
pub const run = @import("run.zig");
/// The callback registry; a host fires the §12.31.4 action reasons here.
pub const callback = @import("callback.zig");
/// §12.16/§12.30 values.
pub const value = @import("value.zig");
/// The systf registry; `systf.hook` is the digital engine's view of it.
pub const systf = @import("systf.zig");
/// The behavioural rows and the Annex G type constants.
pub const code = @import("code.zig");
/// The analog analysis a host attaches a device library to and runs.
pub const analog_run = @import("analog.zig");
pub const handle = @import("handle.zig");
pub const iterate = @import("iterate.zig");
pub const property = @import("property.zig");
pub const delays = @import("delays.zig");
const analog_model = @import("model_analog.zig");
const digital_model = @import("model_digital.zig");
comptime {
    _ = print;
    _ = run;
    _ = callback;
    _ = value;
    _ = systf;
    _ = code;
    _ = analog_run;
    _ = handle;
    _ = iterate;
    _ = property;
    _ = delays;
}
test {
    _ = print;
    _ = run;
    _ = callback;
    _ = value;
    _ = systf;
    _ = code;
    _ = analog_run;
    _ = handle;
    _ = iterate;
    _ = property;
    _ = delays;
    _ = @import("model.zig");
    _ = @import("decompile.zig");
}

/// A folded constant (§11.6.12 NOTE 1's "the value of the parameter"), as
/// lowering represents it; what a `.parameter` or `.constant` row holds.
pub const Const = Lower.Const;

/// "No object": an edge a diagram draws that this object does not have.
pub const no_obj: u32 = std.math.maxInt(u32);

// ---------------------------------------------------------------------------
// vpi_user.h, from the other side.
//
// These must agree with src/vpi/vpi_user.h (IEEE 1364-2005 Annex G's
// numbering, which §12.2 and §12.31 defer to). Nothing shares a source of
// truth between the two; tests/conformance/tests/verilog-ams/ch11_vpi/vpi_app.c, compiled against the header,
// asserts every constant it names (e.g. `vpi_get(vpiType, m) == vpiModule`).
// ---------------------------------------------------------------------------

// §11.6 object types.
pub const vpiConstant: c_int = 7;
pub const vpiIntegerVar: c_int = 25;
pub const vpiIterator: c_int = 27;
pub const vpiMemory: c_int = 29;
pub const vpiMemoryWord: c_int = 30;
pub const vpiRealVar: c_int = 47;
pub const vpiVarSelect: c_int = 68;
pub const vpiModuleArray: c_int = 112;
pub const vpiRegArray: c_int = 116;
pub const vpiTimeVar: c_int = 63;
pub const vpiNetArray: c_int = 114;
/// IEEE 1364-2005 §26.6.1 module ->> variables.
pub const vpiVariables: c_int = 100;
/// IEEE 1364-2005 §26.6.20 (Annex G).
pub const vpiAutomatic: c_int = 50;

// §11.6.2/§11.6.5–§11.6.7, the analog classes. Verilog-AMS names these and
// numbers none; VerA's numbers, shared with tests/fixtures/ch12_vpi_routines/
// p03_vpi_analog.h so a plugin including both sees one value per name.
pub const vpiQuantity: c_int = 720;
pub const vpiBranch: c_int = 721;
pub const vpiPotential: c_int = 722;
pub const vpiFlow: c_int = 723;
pub const vpiPosNode: c_int = 724;
pub const vpiNegNode: c_int = 725;
pub const vpiNode: c_int = 726;
pub const vpiDiscipline: c_int = 727;
pub const vpiNature: c_int = 728;
pub const vpiFlowNature: c_int = 729;
pub const vpiPotentialNature: c_int = 731;
pub const vpiChild: c_int = 732;

// §11.6.10/§11.6.11 relationships and properties.
pub const vpiArray: c_int = 28;
pub const vpiIsMemory: c_int = 73;
pub const vpiIndex: c_int = 78;
pub const vpiParent: c_int = 81;
pub const vpiDecConst: c_int = 1;
pub const vpiModule: c_int = 32;
pub const vpiNet: c_int = 36;
pub const vpiParameter: c_int = 41;
pub const vpiPort: c_int = 44;
pub const vpiReg: c_int = 48;

// Relationships.
pub const vpiScope: c_int = 84;
pub const vpiInternalScope: c_int = 92;
/// IEEE 1364-2005 §26.6.5-§26.6.7 vector ->> bit.
pub const vpiBit: c_int = 90;
/// IEEE 1364-2005 §26.6.43 (Annex G).
pub const vpiUse: c_int = 101;
pub const vpiIteratorType: c_int = 57;
pub const vpiActiveTimeFormat: c_int = 119;

// Properties.
pub const vpiUndefined: c_int = -1;
pub const vpiType: c_int = 1;
pub const vpiName: c_int = 2;
pub const vpiFullName: c_int = 3;
pub const vpiSize: c_int = 4;
pub const vpiTopModule: c_int = 7;
pub const vpiFile: c_int = 5;
pub const vpiLineNo: c_int = 6;
pub const vpiNetType: c_int = 22;
pub const vpiProtected: c_int = 10;
pub const vpiTimeUnit: c_int = 11;
pub const vpiTimePrecision: c_int = 12;
pub const vpiDefName: c_int = 9;
pub const vpiCell: c_int = 51;
pub const vpiConfig: c_int = 52;
pub const vpiLibrary: c_int = 58;
pub const vpiScalar: c_int = 17;
pub const vpiVector: c_int = 18;
pub const vpiDirection: c_int = 20;
pub const vpiPortIndex: c_int = 29;
pub const vpiConstType: c_int = 40;
pub const vpiSigned: c_int = 65;
pub const vpiLocalParam: c_int = 70;
pub const vpiDecompile: c_int = 54;

// §6.5.2.2 directions.
pub const vpiInput: c_int = 1;
pub const vpiOutput: c_int = 2;
pub const vpiInout: c_int = 3;
pub const vpiMixedIO: c_int = 4;
pub const vpiNoDirection: c_int = 5;

// §11.6.12 constant subtypes, over §3.4.1's parameter types.
pub const vpiRealConst: c_int = 2;
pub const vpiStringConst: c_int = 6;
pub const vpiIntConst: c_int = 7;

// §12.2 error state, and Table 12-1's severity ladder.
pub const vpiCompile: c_int = 1;
pub const vpiPLI: c_int = 2;
pub const vpiRun: c_int = 3;
pub const vpiNotice: c_int = 1;
pub const vpiWarning: c_int = 2;
pub const vpiError: c_int = 3;
pub const vpiSystem: c_int = 4;
pub const vpiInternal: c_int = 5;

/// §11.3.1. Opaque to the application: a pointer into `Design.objects`, or to a
/// live `Iter`, and validated as one before it is followed.
pub const vpiHandle = ?*anyopaque;

/// Figure 12-1 `s_vpi_error_info`, laid out for C.
pub const ErrorInfo = extern struct {
    state: c_int,
    level: c_int,
    message: [*c]u8,
    product: [*c]u8,
    code: [*c]u8,
    file: [*c]u8,
    line: c_int,
};

// ---------------------------------------------------------------------------
// The object model
// ---------------------------------------------------------------------------

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

/// `vpi_get(vpiType, o)`.
pub fn typeOf(o: *const Obj) c_int {
    return switch (o.kind) {
        .module => vpiModule,
        .port => vpiPort,
        .net => vpiNet,
        .reg, .word => vpiReg,
        .parameter => vpiParameter,
        .integer => vpiIntegerVar,
        .real_var => vpiRealVar,
        .time_var => vpiTimeVar,
        .reg_array => vpiRegArray,
        .net_array => vpiNetArray,
        .var_array => if (o.ty == .real) vpiRealVar else vpiIntegerVar,
        .var_select => vpiVarSelect,
        .module_array => vpiModuleArray,
        .constant => vpiConstant,
        .discipline => vpiDiscipline,
        .nature => vpiNature,
        .node => vpiNode,
        .branch => vpiBranch,
        .quantity => vpiQuantity,
        .code => o.vtype,
    };
}

/// §26.3.2's string form of a type: `vpi_get_str(vpiType, o)`.
pub fn typeName(t: c_int) []const u8 {
    if (code.typeName(t)) |n| return n;
    return switch (t) {
        vpiModule => "vpiModule",
        vpiPort => "vpiPort",
        vpiNet => "vpiNet",
        vpiReg => "vpiReg",
        vpiParameter => "vpiParameter",
        vpiIntegerVar => "vpiIntegerVar",
        vpiRealVar => "vpiRealVar",
        vpiRegArray => "vpiRegArray",
        vpiTimeVar => "vpiTimeVar",
        vpiNetArray => "vpiNetArray",
        vpiVarSelect => "vpiVarSelect",
        vpiModuleArray => "vpiModuleArray",
        vpiConstant => "vpiConstant",
        vpiDiscipline => "vpiDiscipline",
        vpiNature => "vpiNature",
        vpiNode => "vpiNode",
        vpiBranch => "vpiBranch",
        vpiQuantity => "vpiQuantity",
        vpiIterator => "vpiIterator",
        callback.vpiCallback => "vpiCallback",
        value.vpiSchedEvent => "vpiSchedEvent",
        systf.vpiUserSystf => "vpiUserSystf",
        run.vpiTimeQueue => "vpiTimeQueue",
        systf.vpiInterModPath => "vpiInterModPath",
        // else: `t` is always vpi_get(vpiType)'s answer, and every value it
        // can return has a prong above; this arm is unreachable, not a default.
        else => "vpiUndefined",
    };
}

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
    edges: []const code.Edge = &.{},
    lists: []const code.List = &.{},
    props: []const code.Prop = &.{},
    /// `.constant` only: §11.6.19's vpiConstType. 0 when the literal's base
    /// is not one this model records.
    const_type: c_int = vpiDecConst,
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
    /// `.code` only: §11.6.13/§11.6.14's vpiDefName of a primitive or UDP
    /// definition.
    def_name: []const u8 = "",
    /// A declaration inside a generated digital scope evaluates its source
    /// attribute expressions there, including the iteration's localparam.
    src_engine: OptU32 = .none,
    /// A continuous assignment's literal delays, in its module's time unit
    /// (IEEE 1364 §7.14: rise, fall, turn-off), for §12.11. Hot, not in
    /// `Cold`: §12.29's vpi_put_delays may give one to any gate or
    /// continuous assignment after `open`, when `Design.cold` is fixed.
    delays: []const f64 = &.{},
    /// This row's `Design.cold` entry, `no_cold` for none (every field of
    /// `Cold` at its default). Read it through `coldOf`.
    cold: u32 = no_cold,
};

// Budget: the row every handle points at and every scan walks. 472 bytes
// before the cold split; a new field that is not on most rows goes in `Cold`.
comptime {
    std.debug.assert(@sizeOf(Obj) == 224);
}

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
    /// IEEE 1364-2005 §26.3.3 vpiLineNo and vpiFile, resolved when the model
    /// was built: the analog model's instances (model/analog.zig), whose
    /// compilation is freed after `open`. The digital model resolves its
    /// `Obj.src_tok` through its run instead. Null: none recorded.
    loc: ?Loc = null,
};

/// IEEE 1364-2005 §26.3.3: a 1-based line of a named source file, as
/// written (no §19.7 `line renumbering).
pub const Loc = struct { line: c_int, file: []const u8 };

const empty_cold: Cold = .{};

/// The cold fields of `o`, a row of the installed design.
pub fn coldOf(o: *const Obj) *const Cold {
    return if (o.cold == no_cold) &empty_cold else &design.?.cold[o.cold];
}

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
    lists: []const code.List = &.{},
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
    handles: ?[]vpiHandle = null,
    /// IEEE 1364-2005 §26.6.43: the reference handle it was made from
    /// (vpiUse, NULL for a NULL reference) and the type it iterates
    /// (vpiIteratorType).
    use: vpiHandle = null,
    ty: c_int = 0,
};

/// The installed object model (`design`). Owns everything it reports: strings
/// are copied out of the compilation, so a `CompileResult` may be freed while
/// an application still holds handles.
pub const Design = struct {
    gpa: std.mem.Allocator,
    /// Owns every name string and every slice below.
    arena: std.heap.ArenaAllocator,
    /// Allocated once and never resized: every object handle points into it,
    /// and `object` accepts a pointer only if it lands here on an element
    /// boundary. One object always yields one pointer, but applications must
    /// still compare with `vpi_compare_objects` (§12.3).
    objects: []Obj,
    /// The `Cold` rows `Obj.cold` indexes, in no particular order.
    cold: []Cold = &.{},
    scopes: []Scope,
    /// §11.6.1 NOTE 1 — what `vpi_iterate(vpiModule, NULL)` walks. One entry:
    /// `Elaborate.pickTop` elaborates exactly one design root.
    top_modules: []const u32,
    /// §11.6.2's two top-level sets: `vpi_iterate(vpiDiscipline, NULL)` and
    /// `vpi_iterate(vpiNature, NULL)`, in declaration order. Empty for a
    /// digital design, which declares neither.
    disciplines: []const u32 = &.{},
    natures: []const u32 = &.{},
    /// §11.6.14's circled arrow: `vpi_iterate(vpiUdpDefn, NULL)`.
    udp_defns: []const u32 = &.{},
    /// How `vpi_handle_by_name` searches from a scope. Verilog-AMS §12.21
    /// uses "the scope search rules defined by the Verilog-AMS HDL", §6.7's
    /// upward walk; IEEE 1364-2005 §27.19 "search within that scope only".
    /// The model over a 1364 digital run takes the second.
    search_up: bool = true,
    /// IEEE 1364-2005 §26.6.1 Details b: what vpiTimeUnit and
    /// vpiTimePrecision of a NULL object answer, "the smallest time precision
    /// of all modules". Null in the analog model.
    finest: ?i8 = null,
    /// The parsed source `src_expr`/`src_stmt` index, for a digital design
    /// (the run it is read from outlives the model). Null for the analog
    /// model, whose compilation may be freed once `open` returns.
    file: ?*const Ast.SourceFile = null,
    /// §11.6 `vpiFullName` → object index. Every object has one and they are
    /// unique, which is what makes §12.21 a lookup rather than a tree walk.
    by_name: std.StringHashMapUnmanaged(u32),
    /// The live iterators, keyed by handle value.
    iters: std.AutoHashMapUnmanaged(usize, *Iter),
    /// iterate.zig's reverse indexes, built on first use; owned (`gpa`).
    relations: ?iterate.Relations = null,
    /// §12.32.2 the partials each analog call's derivtf declared, by call
    /// object index (`systf.buildCalls`); the slices are owned (`gpa`).
    partials: std.AutoHashMapUnmanaged(u32, []const systf.Pair) = .empty,
    /// IEEE 1364-2005 §27.31 user data, by call object index and the host
    /// instance whose calltf was running (`systf.active_inst`).
    userdata: std.AutoHashMapUnmanaged(systf.UserKey, ?*anyopaque) = .empty,

    /// Frees the model and every live iterator; all handles become invalid.
    pub fn deinit(self: *Design) void {
        var pit = self.partials.valueIterator();
        while (pit.next()) |p| self.gpa.free(p.*);
        self.partials.deinit(self.gpa);
        self.userdata.deinit(self.gpa);
        var it = self.iters.valueIterator();
        while (it.next()) |p| {
            if (p.*.handles) |hs| self.gpa.free(hs);
            self.gpa.destroy(p.*);
        }
        self.iters.deinit(self.gpa);
        if (self.relations) |*r| r.deinit(self.gpa);
        self.by_name.deinit(self.gpa);
        self.gpa.free(self.objects);
        self.gpa.free(self.cold);
        self.gpa.free(self.scopes);
        self.arena.deinit();
        self.* = undefined;
    }
};

// ---------------------------------------------------------------------------
// The global design
//
// ponytail: one installed design per process, in a global, and not
// thread-safe. No Clause 12 routine takes a context or thread argument, so a
// per-design context is a parameter no conforming application could pass. A
// second device library brings its own design (`buildDesign`), which its
// `analog_run.Binding` swaps in while its calls run (VerA #84).
// ---------------------------------------------------------------------------

/// The installed model; null until `open`/`openDigital`, and after `close`.
pub var design: ?Design = null;

/// Builds the object model over one elaborated design and installs it,
/// closing any previous one.
///
/// `res` is what `vera.compileSource` produced: `res.module` is the
/// elaborated top (`Elaborate.Design.top`), `res.file` its AST and
/// `res.lowered.hier_names` its §6.7 path table. Everything read out of it is
/// copied, so the caller may free the `CompileResult` the moment this returns.
pub fn open(gpa: std.mem.Allocator, res: *const @import("vera").CompileResult) !void {
    if (design != null) close();
    design = try buildDesign(gpa, res);
}

/// The object model `open` installs, built and returned instead: the design
/// of a second device library, which `analog_run.Binding.attach` takes and
/// makes the installed one while that library's calls run (VerA #84). The
/// caller owns it until it hands it to `attach`.
pub fn buildDesign(gpa: std.mem.Allocator, res: *const @import("vera").CompileResult) !Design {
    return analog_model.build(gpa, res);
}

/// Frees the installed model and resets every sibling registry (run,
/// callbacks, values, systfs) and the error status. Invalidates every handle.
pub fn close() void {
    if (design) |*d| d.deinit();
    design = null;
    run.detach();
    callback.reset();
    value.reset();
    systf.reset();
    delays.reset();
    clearError();
}

/// Calls each entry of the application's `vlog_startup_routines` once, in
/// order, stopping at the 0 terminator (§12.33.2).
///
/// A binary that calls this must link a `vlog_startup_routines` (a strong
/// reference; §12.33.2 makes the array and the application one link unit).
/// The `@extern` is inside this body, so a binary that never calls it needs
/// none. Tests use `runStartupTable`.
pub fn runStartupRoutines() void {
    runStartupTable(@extern(?[*]const ?StartupFn, .{ .name = "vlog_startup_routines" }));
}

/// The loop of `runStartupRoutines` over a given table. A null table is a
/// no-op: an application that registers nothing at startup is legal.
pub fn runStartupTable(table: ?[*]const ?StartupFn) void {
    const entries = table orelse return;
    starting = true;
    defer starting = false;
    var i: usize = 0;
    while (entries[i]) |f| : (i += 1) f();
}

/// True while the startup routines run. IEEE 1364-2005 §26.2.4: "Only two
/// routines can be called at this time: vpi_register_systf() [and]
/// vpi_register_cb()", the latter for six reasons (`callback.startupReason`).
/// VAMS's vpi_register_analog_systf is the first one's analog twin.
/// `refused` turns every other routine away (VD-044).
pub var starting = false;

/// One `vlog_startup_routines` entry.
pub const StartupFn = *const fn () callconv(.c) void;

/// Builds the object model over an elaborated digital run and installs it.
/// The run must outlive the model: object values are read from `run.values`.
pub fn openDigital(gpa: std.mem.Allocator, r: *sim.digital.Run) !void {
    if (design != null) close();
    design = try digital_model.buildDigital(gpa, r);
    try callback.sizeHooks(r);
    run.attach(r);
    print.share(r);
}

/// `NotElaborated`: `lowered` carries no elaborated top, a sequencing bug in
/// the caller rather than a diagnostic.
pub const Error = error{ OutOfMemory, NotElaborated };

// ---------------------------------------------------------------------------
// §12.2 error status
//
// "The error status shall be reset by any VPI routine call except
// vpi_chk_error()." So every entry point below opens with `clearError()`, and
// `vpi_chk_error` does not.
// ---------------------------------------------------------------------------

var err_level: c_int = 0;
var err_code: [:0]const u8 = "";
var err_buf: [512]u8 = undefined;
var err_len: usize = 0;

/// Figure 12-1's `product`. Static, NUL-terminated, never rewritten.
var product_name = "VerA".*;

/// Resets the §12.2 error status; every routine but `vpi_chk_error` calls it.
pub fn clearError() void {
    err_level = 0;
    err_len = 0;
    err_code = "";
}

/// Records one error; the caller returns its own documented failure value.
/// `err` is a short stable token (`s_vpi_error_info.code`). Both it and the
/// message live in static storage until the next VPI call (Figure 12-1).
///
/// ponytail: a fixed 512-byte message, truncating, so the error path never
/// allocates.
pub fn fail(err: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    noteError(err, fmt, args);
    // A cbPLIError routine may call other routines, each clearing the status;
    // the failing routine's caller still reads this error afterwards.
    const saved = .{ err_level, err_code, err_buf, err_len };
    callback.pliError();
    err_level, err_code, err_buf, err_len = saved;
}

/// Records the status `vpi_chk_error` reports, without firing cbPLIError.
/// For the cbError path: §12.31.4 "On a cbError callback, the routine
/// vpi_chk_error() can be called to retrieve error information", and that
/// callback is not a PLI-routine failure.
pub fn noteError(err: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    err_level = vpiError;
    err_code = err;
    const written = std.mem.print(err_buf[0 .. err_buf.len - 1], fmt, args) catch
        err_buf[0 .. err_buf.len - 1];
    err_len = written.len;
    err_buf[err_len] = 0;
}

// ---------------------------------------------------------------------------
// Annex G names VerA does not answer (vpi_user.h's block of that name)
// ---------------------------------------------------------------------------

/// An Annex G constant vpi_user.h defines (IEEE 1364-2005 §1.7 makes the
/// listing normative) that no routine here answers: its name and why, so
/// the refusal says which question it was (§12.2's error, read through
/// vpi_chk_error as IEEE 1364-2005 §27.1 has it).
pub const Unanswered = struct { name: []const u8, why: []const u8 };

/// Records the refusal of `u`, asked of routine `who`.
pub fn failUnanswered(comptime who: []const u8, u: Unanswered) void {
    fail("NOTSUPPORTED", who ++ ": {s} is not answered: {s}", .{ u.name, u.why });
}

const no_sdf = "VerA reads no SDF, so the model holds no delay device or terminal (IEEE 1364-2005 §26.6.21)";
const no_frame = "the model holds no task or function frame (IEEE 1364-2005 §26.6.20)";
const no_prim_array = "the model holds an arrayed primitive's instances, not the array";
const no_bits = "the model expands no port or continuous assignment into bits";
const no_directive = "the model does not record the compiler directives in force where a module was defined";
const no_save = "VerA has no save or restart (IEEE 1364-2005 C.8)";

/// The object types and relationships of Annex G no vpi_handle() or
/// vpi_iterate() answers.
pub fn unansweredType(t: c_int) ?Unanswered {
    return switch (t) {
        10 => .{ .name = "vpiDefParam", .why = "the model keeps no defparam: elaboration applied it" },
        45 => .{ .name = "vpiPortBit", .why = no_bits },
        54 => .{ .name = "vpiSpecParam", .why = "the model keeps no specparam object" },
        80 => .{ .name = "vpiLowConn", .why = "the model holds a port's upper connection (vpiHighConn), not its lower one" },
        98 => .{ .name = "vpiPortInst", .why = "the model does not record the ports of lower instances a net connects to" },
        106 => .{ .name = "vpiBitSelect", .why = "the model types a bit-select as a vpiNetBit or vpiRegBit" },
        108 => .{ .name = "vpiDelayTerm", .why = no_sdf },
        109 => .{ .name = "vpiDelayDevice", .why = no_sdf },
        110 => .{ .name = "vpiFrame", .why = no_frame },
        111 => .{ .name = "vpiGateArray", .why = no_prim_array },
        113 => .{ .name = "vpiPrimitiveArray", .why = no_prim_array },
        117 => .{ .name = "vpiSwitchArray", .why = no_prim_array },
        118 => .{ .name = "vpiUdpArray", .why = no_prim_array },
        120 => .{ .name = "vpiInTerm", .why = no_sdf },
        121 => .{ .name = "vpiInstanceArray", .why = "the model reaches an instance array as vpiModuleArray" },
        124 => .{ .name = "vpiOutTerm", .why = no_sdf },
        125 => .{ .name = "vpiPorts", .why = no_bits },
        126 => .{ .name = "vpiSimNet", .why = "the model does not record the net a port connection collapsed into" },
        127 => .{ .name = "vpiTaskFunc", .why = "iterate vpiTask and vpiFunction instead" },
        128 => .{ .name = "vpiContAssignBit", .why = no_bits },
        135 => .{ .name = "vpiGenVar", .why = "a genvar is no object the model holds" },
        else => null, // else: every other number is answered, or is no Annex G type and gets the routine's own refusal
    };
}

/// The properties of Annex G no vpi_get() or vpi_get_str() answers.
pub fn unansweredProp(p: c_int) ?Unanswered {
    return switch (p) {
        8 => .{ .name = "vpiCellInstance", .why = no_directive },
        13 => .{ .name = "vpiDefNetType", .why = no_directive },
        14 => .{ .name = "vpiUnconnDrive", .why = no_directive },
        15 => .{ .name = "vpiDefFile", .why = "the model does not record where a module was defined" },
        16 => .{ .name = "vpiDefLineNo", .why = "the model does not record where a module was defined" },
        19 => .{ .name = "vpiExplicitName", .why = "the model does not record how a port was named" },
        23 => .{ .name = "vpiExplicitScalared", .why = "the model does not record a net's scalared or vectored keyword" },
        24 => .{ .name = "vpiExplicitVectored", .why = "the model does not record a net's scalared or vectored keyword" },
        25 => .{ .name = "vpiExpanded", .why = "the model does not record whether a vector is expanded" },
        27 => .{ .name = "vpiChargeStrength", .why = "the model does not record a trireg's charge strength" },
        47 => .{ .name = "vpiDefDelayMode", .why = no_directive },
        48 => .{ .name = "vpiDefDecayTime", .why = no_directive },
        49 => .{ .name = "vpiActive", .why = no_frame },
        53 => .{ .name = "vpiConstantSelect", .why = "the model does not record whether a select's index is constant" },
        56 => .{ .name = "vpiDelayType", .why = no_sdf },
        59 => .{ .name = "vpiMultiArray", .why = "the model does not record an array's dimension count" },
        60 => .{ .name = "vpiOffset", .why = "the model does not record this property" },
        61 => .{ .name = "vpiResolvedNetType", .why = "the model keeps each net's declared vpiNetType, not the type a port connection resolved" },
        62 => .{ .name = "vpiSaveRestartID", .why = no_save },
        63 => .{ .name = "vpiSaveRestartLocation", .why = no_save },
        64 => .{ .name = "vpiValid", .why = no_frame },
        else => null, // else: every other number is answered, or is no Annex G property and gets the routine's own refusal
    };
}

// ---------------------------------------------------------------------------
// Handle validation — the trust boundary
//
// Every `vpiHandle` arrived from C and is not dereferenced until shown to be
// one VerA issued:
//
//   an object   lands inside `objects`, on an element boundary
//   an iterator is a key of `iters` (allocated and not yet freed)
//
// `vpi_scan` and `vpi_free_object` remove an iterator's key before destroying
// it. A stale object handle from a closed design is rejected only when the new
// `objects` is a different allocation. No magic-number header: checking one
// would read through an arbitrary pointer.
// ---------------------------------------------------------------------------

/// Returns `h` as an object of the installed design, or null. Never reads
/// through `h`.
pub fn asObj(h: vpiHandle) ?*Obj {
    const d = &(design orelse return null);
    const p = h orelse return null;
    if (d.objects.len == 0) return null;
    const base = @intFromPtr(d.objects.ptr);
    const addr = @intFromPtr(p);
    if (addr < base) return null;
    const off = addr - base;
    if (off >= d.objects.len * @sizeOf(Obj)) return null;
    if (off % @sizeOf(Obj) != 0) return null;
    return &d.objects[off / @sizeOf(Obj)];
}

/// Returns `h` as a live iterator of the installed design, or null. Never
/// reads through `h`: membership in `Design.iters` is the proof.
pub fn asIter(h: vpiHandle) ?*Iter {
    const d = &(design orelse return null);
    const p = h orelse return null;
    return d.iters.get(@intFromPtr(p));
}

/// The handle an application receives for `o`, which must be a row of
/// `design.objects`; `asObj` is its inverse. Valid until `close`.
pub fn handleOf(o: *Obj) vpiHandle {
    return @ptrCast(o);
}

/// How an invalid handle is named in a message. Never dereferences it.
pub fn describe(h: vpiHandle) []const u8 {
    return if (h == null) "NULL" else "that handle";
}

/// Every routine but `vpi_chk_error` and the three registrations starts
/// here or at `enter`: §12.2 "the error status shall be reset by any VPI
/// routine call", and IEEE 1364-2005 §26.2.4 allows none of them while the
/// startup routines run. True means the error is recorded; the caller
/// returns its own documented failure value.
pub fn refused(comptime who: []const u8) bool {
    clearError();
    if (!starting) return false;
    fail("STARTUP", who ++ ": IEEE 1364-2005 §26.2.4 allows only vpi_register_systf() and vpi_register_cb() in vlog_startup_routines; call it from a cbEndOfCompile callback", .{});
    return true;
}

/// `refused`, and then: no routine has an answer without an open design.
/// Null means the error is recorded; the caller returns its own documented
/// failure value.
pub inline fn enter(comptime who: []const u8) ?*Design {
    if (refused(who)) return null;
    if (design) |*d| return d;
    fail("NODESIGN", who ++ ": no design is open", .{});
    return null;
}

/// `h` as an object VerA issued, or null with the error recorded.
pub inline fn object(comptime who: []const u8, h: vpiHandle) ?*Obj {
    if (asObj(h)) |o| return o;
    fail("BADHANDLE", who ++ ": {s} is not a handle to an object", .{describe(h)});
    return null;
}

// ---------------------------------------------------------------------------
// §12.2 vpi_chk_error
// ---------------------------------------------------------------------------

/// "Shall return an integer constant representing an error severity level if
/// the previous call to a VPI routine resulted in an error ... The error status
/// shall be reset by any VPI routine call except vpi_chk_error(). Calling
/// vpi_chk_error() shall have no effect on the error status."
///
/// So this is the one routine that does not clear the status, and it is
/// idempotent. "If the error information is not needed, a NULL can be passed
/// to the routine."
pub export fn vpi_chk_error(error_info_p: ?*ErrorInfo) c_int {
    if (error_info_p) |info| {
        info.* = .{
            // Table 12-1's companion field. Every error VerA raises is raised
            // from an application's own call into it, which is `vpiPLI`;
            // `vpiCompile` and `vpiRun` belong to errors a simulator raises
            // outside a VPI call, and there is no such path into this file.
            .state = vpiPLI,
            .level = err_level,
            .message = if (err_len == 0) null else @ptrCast(&err_buf),
            .product = @ptrCast(&product_name),
            .code = if (err_code.len == 0) null else @constCast(err_code.ptr),
            // The APPLICATION's call site. C gives a callee no caller location,
            // so these are reported absent rather than invented.
            .file = null,
            .line = 0,
        };
    }
    return err_level;
}

// ---------------------------------------------------------------------------
// §12.3 vpi_compare_objects / §12.4 vpi_free_object
// ---------------------------------------------------------------------------

/// "Handle equivalence can not be determined with a C `==` comparison."
///
/// Two invalid handles are not "the same object": that is FALSE plus an
/// error, not TRUE.
pub export fn vpi_compare_objects(obj1: vpiHandle, obj2: vpiHandle) c_int {
    if (refused("vpi_compare_objects")) return 0;
    const a = issued(obj1) orelse {
        fail("BADHANDLE", "vpi_compare_objects: {s} is not a handle VerA issued", .{describe(obj1)});
        return 0;
    };
    const b = issued(obj2) orelse {
        fail("BADHANDLE", "vpi_compare_objects: {s} is not a handle VerA issued", .{describe(obj2)});
        return 0;
    };
    return @intFromBool(a == b);
}

/// The identity of a handle VerA issued, object or iterator (§12.23 gives an
/// iterator the type `vpiIterator`, so it is an object too). Erased to
/// `*anyopaque` because identity is all `vpi_compare_objects` reads.
pub fn issued(h: vpiHandle) ?*anyopaque {
    if (asObj(h)) |o| return @ptrCast(o);
    if (asIter(h)) |it| return @ptrCast(it);
    if (callback.asCb(h)) |cb| return @ptrCast(cb);
    if (run.asQueue(h)) |q| return @ptrCast(q);
    if (value.asEvent(h)) |e| return @ptrCast(e);
    if (systf.asSystf(h)) |s| return @ptrCast(s);
    if (delays.asPath(h)) |m| return @ptrCast(m);
    return null;
}

/// "It shall generally be used to free memory created for iterator objects. ...
/// This routine can also optionally be used for implementations which have to
/// allocate memory for objects."
///
/// Freeing an iterator frees it and invalidates the handle. Freeing an object
/// is a no-op returning TRUE: objects live as long as the design, and an
/// application is entitled to call this on one.
pub export fn vpi_free_object(obj: vpiHandle) c_int {
    if (refused("vpi_free_object")) return 0;
    if (asIter(obj)) |it| {
        iterate.destroyIter(&design.?, it);
        return 1;
    }
    // A callback handle is freed by vpi_remove_cb (§12.34), not here; freeing
    // the handle leaves the callback registered, as an object's does.
    if (asObj(obj) != null or callback.asCb(obj) != null or run.asQueue(obj) != null or systf.asSystf(obj) != null or delays.asPath(obj) != null) return 1;
    // §12.30 "Calling vpi_free_object() on the handle shall free the handle
    // but shall not effect the event."
    if (value.asEvent(obj)) |e| {
        value.freeEvent(e);
        return 1;
    }
    fail("BADHANDLE", "vpi_free_object: {s} is not a handle VerA issued", .{describe(obj)});
    return 0;
}

/// IEEE 1364-2005's later spelling of `vpi_free_object`; same contract, same
/// body.
pub export fn vpi_release_handle(obj: vpiHandle) c_int {
    return vpi_free_object(obj);
}

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

// ---------------------------------------------------------------------------
// §12.17 vpi_get_vlog_info
// ---------------------------------------------------------------------------

/// Figure 12-12 `s_vpi_vlog_info`, laid out for C.
pub const VlogInfo = extern struct {
    argc: c_int,
    argv: [*c][*c]u8,
    product: [*c]u8,
    version: [*c]u8,
};

/// The product's invocation, as its `main` received it. Kept by pointer: the
/// C runtime owns `argv` for the life of the process, which outlives any
/// application's use of it.
var inv_argc: c_int = 0;
var inv_argv: [*c][*c]u8 = null;

/// §12.26 the product log file channel 3 writes (`print.setLogFile`).
pub const setLogFile = print.setLogFile;

/// A host calls this once, from its `main`, before the startup routines run.
/// A host that never does reports an invocation of no options.
pub fn setInvocation(argc: c_int, argv: [*c][*c]u8) void {
    inv_argc = argc;
    inv_argv = argv;
}

/// Figure 12-12's `version`: the VerA release (`contract.vera_version`), a
/// mutable copy because `VlogInfo.version` is a `[*c]u8`.
var version_str = @import("vera").version.*;

/// "shall obtain the following information about Verilog-AMS product
/// execution: The number of invocation options (argc), Invocation option
/// values (argv), Product and version strings ... The routine shall return
/// TRUE on success and FALSE on failure." The one failure an application can
/// cause is having no structure to fill.
pub export fn vpi_get_vlog_info(vlog_info_p: ?*VlogInfo) c_int {
    if (refused("vpi_get_vlog_info")) return 0;
    const out = vlog_info_p orelse {
        fail("BADINFO", "vpi_get_vlog_info: vlog_info_p is NULL", .{});
        return 0;
    };
    out.* = .{
        .argc = inv_argc,
        .argv = inv_argv,
        .product = @ptrCast(&product_name),
        .version = @ptrCast(&version_str),
    };
    return 1;
}
