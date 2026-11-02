//! The module-scope declaration rows of the AST: modules, their parameters,
//! variables, nets, ports, branches, functions, instances and processes.
//! In: the declarations the parser recognises. Out: one struct per
//! declaration, its lists as arena slices, read by elaboration, lowering and
//! the digital engine; no later stage writes one. The IEEE 1364 primitive
//! rows are ast_prim.zig's; the other design elements ast_design.zig's.
//! Cites: LRM ch3 (§3.2-§3.4, §3.5, §3.10), §4.7, ch6 (§6.2, §6.3.1, §6.5),
//! §7.7; IEEE 1364-2005 §6.1, §9.2, §10, §12.2.
//!
//! Contents:
//! - `pub const Dim = struct`
//! - `pub const ValueRange = struct`: `Kind`
//! - `pub const ParamDecl = struct`
//! - `pub const AliasParam = struct`
//! - `pub const VarDecl = struct`
//! - `pub const NetKind = enum(u8)`
//! - `pub const Strength = enum(u8)`
//! - `pub const NetStrength = struct`
//! - `pub const Delay3 = struct`: `any`
//! - `pub const NetDecl = struct`
//! - `pub const BranchDecl = struct`
//! - `pub const Port = struct`: `connName`
//! - `pub const FuncArg = struct`
//! - `pub const Subroutine = struct`
//! - `pub const EventDecl = struct`
//! - `pub const TfPort = struct`: `Redecl`
//! - `pub const FuncDecl = struct`
//! - `pub const AnalogBlock = struct`
//! - `pub const DiscreteBlock = struct`
//! - `pub const ContAssign = struct`
//! - `pub const PortConn = struct`
//! - `pub const ParamOverride = struct`
//! - `pub const Defparam = struct`
//! - `pub const Instance = struct`
//! - `pub const ModuleDecl = struct`

const std = @import("std");
const ast = @import("ast.zig");
const ExprId = ast.ExprId;
const StmtId = ast.StmtId;
const StrId = ast.StrId;
const Type = ast.Type;
const Direction = ast.Direction;
const PotentialOrFlow = ast.PotentialOrFlow;
const SourceFile = ast.SourceFile;
const ExprTag = ast.ExprTag;
const GateInst = ast.GateInst;
const SpecPath = ast.SpecPath;
const PulseControl = ast.PulseControl;
const TimingCheck = ast.TimingCheck;
const PullInst = ast.PullInst;
const SwitchInst = ast.SwitchInst;
const NatureAttr = ast.NatureAttr;

/// A declared dimension / range: `[msb:lsb]` (A.2.5 `range`, `dimension`).
/// Used by array parameters (§3.4.4), array variables (§3.2.2) and vector
/// ports / nets (§6.5.2).
pub const Dim = struct {
    msb: ExprId,
    lsb: ExprId,
};

/// LRM §3.4.2 value_range: `from [lo:hi]` / `exclude (lo:hi)` / `exclude val`.
/// A.2.5 `value_range`. `lo`/`hi` may be `.pos_inf` / `.neg_inf` nodes.
///
/// These are the only bound evidence the finiteness proof has; they travel
/// ParamDecl → Lower.ParamInfo → proof.zig.
pub const ValueRange = struct {
    kind: Kind,
    lo: ExprId,
    /// `.none` for a single-value `exclude` and for the string-set form.
    hi: ExprId = .none,
    lo_inclusive: bool = true,
    hi_inclusive: bool = true,
    /// A.2.5 `value_range_type '{ string {, string} }`: offset of a StrId list
    /// in `ExprStore.pool`, or `null` for the numeric forms. LRM §3.4.2 string
    /// parameter value ranges.
    strings: ?u32 = null,

    /// `from` admits the range; `exclude` removes it (or `lo`) from what
    /// the other ranges admit.
    pub const Kind = enum(u8) { from, exclude };
};

/// Parameter declaration. LRM §3.4 (A.2.1.1 parameter_declaration /
/// local_parameter_declaration, A.2.4 param_assignment). One `ParamDecl` per
/// declared name: the parser expands `parameter real a = 1, b = 2;`.
pub const ParamDecl = struct {
    name: StrId,
    ty: Type, // §3.4.1 (`.unspecified` ⇒ infer from `default`)
    default: ExprId, // §3.4 default expression (constant_mintypmax_expression)
    is_local: bool = false, // §3.4.5 localparam
    /// A.2.1.1 `parameter signed`: IEEE 1364-2005 §12.2 converts an override
    /// to a signed value.
    is_signed: bool = false,
    /// IEEE 1364-2005 §4.10.3 a module-body `specparam`, kept as a
    /// `localparam` (`is_local`) that no module parameter may read.
    is_spec: bool = false,
    /// A specparam declared inside a specify block, which §4.10.3's
    /// "declared outside a specify block shall be declared before it is
    /// referenced" does not bind: it may name a later one of the block.
    in_specify: bool = false,
    /// IEEE 1364-2005 §4.10.1 `parameter time`: `ty` folds it to `.integer`,
    /// but its value is unsigned 64-bit (§4.8), not a signed 32-bit integer.
    is_time: bool = false,
    /// §3.4.4 array parameter dimensions; empty for a scalar.
    dims: []const Dim = &.{},
    /// A.2.1.1's `[ range ]`, the first arm's width bracket (`parameter [3:0]
    /// nib = 4'h5;`). Not `dims`: A.2.5's `range` is a vector width and
    /// `dimension` is an array bound, and lowering scalarizes the latter.
    /// `null` when the declaration writes no bracket, which is every
    /// `parameter_type` form (the two A.2.1.1 arms are exclusive).
    packed_range: ?Dim = null,
    /// §6.3 this parameter's value came from an instance parameter value
    /// assignment (or a paramset), not from its own declaration. Set only by
    /// elaboration (`elab/clone.zig`) when it turns a flattened child's
    /// parameter into a `localparam` carrying the override as its default.
    ///
    /// It separates the two halves of §3.4.2: a declared default is judged only
    /// for well-formed bounds (E0347), while "the parameter value shall be
    /// within the range" applies to a supplied value.
    is_override: bool = false,
    /// LRM §3.4.2 value ranges (from/exclude). The finiteness proof needs them,
    /// so lowering carries them into `Lower.ParamInfo`.
    ranges: []const ValueRange = &.{},
    main_tok: u32 = 0,
};

// Budget: 64 bytes (948 rows on psp103); see docs/seams/s1-frontcore.md
// (removed from the tree; `git show 6e59b3d4^:docs/seams/s1-frontcore.md`)
// before adding a field.
comptime {
    std.debug.assert(@sizeOf(ParamDecl) <= 64);
}

/// LRM §3.4.6 `aliasparam alias = target;` (A.2.1.1 aliasparam_declaration).
pub const AliasParam = struct {
    alias: StrId,
    target: StrId,
};

/// Local variable declaration: `real`/`integer`/`string` (+ `realtime`/`time`
/// folded into those). LRM §3.2, §3.3; A.2.8 analog_block_item_declaration.
/// One per declared name.
pub const VarDecl = struct {
    name: StrId,
    ty: Type,
    /// §3.2.2 array dimensions; empty for a scalar.
    dims: []const Dim = &.{},
    /// A.2.2.1 `variable_identifier = constant_expression`; `.none` if absent.
    init: ExprId = .none,
    main_tok: u32 = 0,
    /// Digital declaration metadata retained for source execution. Analog lowering
    /// continues to use ty/dims; a packed reg range is not an unpacked array.
    storage: enum { variable, reg, time } = .variable,
    packed_range: ?Dim = null,
    is_signed: bool = true,
    /// A.2.1.3 `reg [ discipline_identifier ] ...`: the discrete discipline
    /// a `reg` names (E0371 when nothing declares it); `.none` otherwise.
    discipline: StrId = .none,
    /// §6.4.3 / §3.2.1 declared with a `(* desc = ... *)` attribute, which is
    /// what makes a variable an output variable. Recorded for paramset
    /// variables, where §6.4.3's hiding rule turns on it.
    desc: bool = false,
};

// Budget: 48 bytes (1,549 rows on psp103).
comptime {
    std.debug.assert(@sizeOf(VarDecl) <= 48);
}

/// The wired-logic function a net's drivers resolve through (IEEE 1364-2005
/// §7.9, Verilog-AMS §3.7): A.2.2.1 `net_type` plus the two spellings A.2.1.3
/// gives arms of their own, `trireg` (§3.8 charge storage) and `wreal` (§3.7).
/// A declaration that names no net type (`electrical a;`) is `.wire`, the §7.9
/// default resolution.
pub const NetKind = enum(u8) {
    wire,
    tri,
    tri0,
    tri1,
    triand,
    trior,
    trireg,
    wand,
    wor,
    uwire,
    supply0,
    supply1,
    /// §3.7: "The wreal, or real net data type, represents a real-valued
    /// physical connection between structural entities." Not four-state
    /// ("wreal nets shall have an initial value of zero"), so an `else` arm of
    /// a four-state resolution is wrong for one. `parseWrealDecl` (parser/net.zig)
    /// refuses it under `--run` for that reason.
    wreal,
};

/// A.2.2.2 `strength0`/`strength1`/`charge_strength` as one scale (IEEE 1364
/// clause 7): supply > strong > pull > large > weak > medium > small > highz.
/// The numeric values are that order, so `@backingInt` comparison is "stronger
/// than". The 0-side/1-side split belongs to the keyword, so the parser checks
/// it (rejecting `(strong0, pull0)`).
pub const Strength = enum(u8) { highz = 0, small = 1, medium = 2, weak = 3, large = 4, pull = 5, strong = 6, supply = 7 };

/// The three strength slots A.2.1.3 puts on one `net_declaration` (a
/// `charge_strength` on the `trireg` arms, a `drive_strength` pair on the
/// `list_of_net_decl_assignments` arms), carried together so the parser can
/// return whichever bracket the source wrote. Defaults: `medium` (IEEE
/// 1364-2005 §3.8) and `(strong1, strong0)` (§7.10).
pub const NetStrength = struct {
    charge: Strength = .medium,
    strength0: Strength = .strong,
    strength1: Strength = .strong,
    /// A `drive_strength` was written, which A.2.1.3 allows only before a
    /// `list_of_net_decl_assignments` (IEEE 1364-2005 §4.4).
    drive: bool = false,
};

/// A.2.2.3 `delay3 ::= # delay_value | # ( delay_value [ , delay_value [ , delay_value ] ] )`.
/// One value means all three; two mean rise and fall with the turn-off delay
/// taken as the minimum of them (IEEE 1364-2005 §7.14); three are given. On a
/// `trireg` the third value is not a turn-off delay at all but A.2.1.3's charge
/// decay time, which is why the third field is spelled for both readings.
/// `.none` throughout is "no delay".
pub const Delay3 = struct {
    rise: ExprId = .none,
    fall: ExprId = .none,
    /// Turn-off (to z) on a driver, charge decay on a `trireg`.
    off: ExprId = .none,

    /// Returns whether any delay was written. The two-value form leaves `off`
    /// `.none`: §7.14 derives it as the smaller of rise and fall. A `trireg`
    /// reads that `.none` as "no charge decay", so `trireg c;` holds forever.
    pub fn any(self: Delay3) bool {
        return self.rise != .none;
    }
};

/// Net declaration. LRM §3.6.3 (A.2.1.3 net_declaration). One per declared
/// name. In the Verilog-A subset (annex C) the only forms that matter are
/// `<discipline> a, b;` and `ground <discipline> g;`.
pub const NetDecl = struct {
    name: StrId,
    /// A.2.2.1 net type; `.wire` when the declaration names none.
    kind: NetKind = .wire,
    /// §3.6.2 discipline identifier; `.none` when the net is untyped (§3.9
    /// discipline resolution then assigns it).
    discipline: StrId = .none,
    /// §3.6.3 `ground` declaration: a global reference node.
    is_ground: bool = false,
    /// §6.5.2 vector net range; `null` for a scalar.
    range: ?Dim = null,
    /// A.2.3 `net_identifier { dimension }`: a net array (IEEE 1364-2005
    /// §4.9.1), one net per element. Only a digital parse keeps one.
    dims: []const Dim = &.{},
    /// A.2.1.3 `[ signed ]`. IEEE 1364-2005 §12.3.11: signedness belongs to the
    /// declaration, so each side of a port keeps its own.
    is_signed: bool = false,
    /// A.2.1.3 `charge_strength`, `trireg` only; `medium` is IEEE 1364-2005
    /// §3.8's default.
    charge: Strength = .medium,
    /// A.2.1.3 `[ drive_strength ]` on the `list_of_net_decl_assignments` arms.
    /// IEEE 1364-2005 §7.10's default is `(strong1, strong0)`.
    strength0: Strength = .strong,
    strength1: Strength = .strong,
    /// A.2.1.3 `[ delay3 ]`. On a `trireg` the third value is the charge decay
    /// time; on every other net type it is the turn-off delay of the net's own
    /// transition.
    delay: Delay3 = .{},
    /// A.2.4 net_decl_assignment; `.none` when the declaration has no `=`.
    /// §3.6.3.2 makes this a nodeset value for the net's potential: an initial
    /// guess for the solver, not an assignment or a clamp. Folded by
    /// `Lower.lowerModule`.
    init: ExprId = .none,
    main_tok: u32 = 0,
};

/// Branch declaration. LRM §3.12 (A.2.1.3 branch_declaration /
/// port_branch_declaration). One per declared branch name.
pub const BranchDecl = struct {
    name: StrId,
    /// First terminal: an `.ident` or `.index` expression (net or port ref).
    hi: ExprId,
    /// Second terminal; `.none` = implicit global ground (§3.12, §1.3.1.1).
    lo: ExprId = .none,
    /// §3.12 `branch (<p>)`: a port branch, not a node pair.
    is_port_branch: bool = false,
    /// A.2.3 `branch_identifier [ range ]`: array of branches; `null` = scalar.
    range: ?Dim = null,
    main_tok: u32 = 0,
};

/// Module port. LRM §6.5 (A.1.3 port / port_declaration).
pub const Port = struct {
    name: StrId,
    direction: Direction = .unspecified, // §6.5.2.2
    /// §6.5.2.1 discipline identifier; `.none` ⇒ resolved by §3.9.
    discipline: StrId = .none,
    /// §6.5.2 vector port range `[msb:lsb]` from the port direction
    /// declaration (`inout [0:3] p;`); `null` for a scalar port.
    range: ?Dim = null,
    /// §6.5.2.2 the range from the port type declaration (`electrical [0:3]
    /// p;`). Kept apart from `range` because §6.5.2.2 requires the two to
    /// "evaluate to the same value"; lowering folds and compares them (E0350).
    type_range: ?Dim = null,
    /// A.2.1.2 `net_type` from the port type declaration, `.wire` when none was
    /// written (A.2.1.3's default, and §3.5's for an undeclared port). A net
    /// declaration naming a header port is folded into the port
    /// (`parseNetNames`), and §7.9 resolution reads this type.
    kind: NetKind = .wire,
    /// A.1.3 `port ::= . port_identifier ( [ port_expression ] )`: the port's
    /// external name, the one an instantiation connects to; `.none` when the
    /// port is named by the net it carries. Several consecutive ports share one
    /// external name when the port expression is a concatenation (§6.5.1).
    external_name: StrId = .none,
    /// A.1.3 this port_reference continues the previous one's port_expression,
    /// a concatenation: `{c, d}` is two `Port`s, the second one `concat_rest`.
    concat_rest: bool = false,
    /// IEEE 1364-2005 A.1.3 `port_reference ::= port_identifier [ [
    /// constant_range_expression ] ]`: the bit-select (`msb == lsb`) or
    /// part-select of the net this reference names. A digital parse only.
    select: ?Dim = null,
    /// A.2.1.2 `[ signed ]` on the direction or the net declaration of this
    /// port. §12.3.3: "If either ... is declared as signed, then the other
    /// shall also be considered signed."
    is_signed: bool = false,
    /// A digital parse has folded this port's type declaration (`wire x;`)
    /// into it, so another one is a second declaration of the name.
    typed: bool = false,
    main_tok: u32 = 0,

    /// The name a §6.5.5 named connection `.name(expr)` binds by: the
    /// external name of a `.ext(...)` port (A.1.3), else the net's own.
    pub fn connName(p: Port) StrId {
        return if (p.external_name != .none) p.external_name else p.name;
    }
};

/// Analog function argument. LRM §4.7.2 (A.2.6 analog_function_item_declaration
/// → input/output/inout declaration). §4.7.2.3 makes `output`/`inout` args
/// write-back parameters.
pub const FuncArg = struct {
    name: StrId,
    ty: Type,
    direction: Direction, // §4.7.2.3; `.input` unless declared otherwise
    /// §4.7.2.3/§4.7.2.4 an array formal, `output [0:1] out;`. A.2.6 puts the
    /// range on the direction declaration and §4.7.1's Example 3 on the block
    /// item declaration (`real a[0:1];`); `parseFuncDecl` merges either.
    dims: []const Dim = &.{},
    /// The identifier token, so §4.7.1's "all formal arguments shall have an
    /// associated block item declaration" (E0225) can point at the formal that
    /// never got one, after the parser has moved on to `endfunction`.
    main_tok: u32 = 0,
};

/// IEEE 1364-2005 §10.2 task or §10.4 function (A.2.6 `function_declaration`,
/// A.2.7 `task_declaration`) as a digital parse records it: the 1364
/// spellings VAMS §4.7 admits beside the analog function: packed port ranges,
/// `reg`/`integer`/`time` formals, `automatic`, and tasks at all. An analog
/// parse records its tasks here too (the mixed-signal kernel runs them) and
/// no function: its bare `function` is a `FuncDecl`.
///
/// Every formal, local and the function result is a `VarDecl`, because that
/// is what §10.2.3/§10.4.1 make them: variables of the subroutine's scope.
pub const Subroutine = struct {
    name: StrId,
    is_function: bool,
    /// A.2.6/A.2.7 `automatic`: storage per activation (§10.2.3, §10.4.2).
    automatic: bool = false,
    /// §10.4.1 "a variable with the same name as the function"; its type is
    /// A.2.6's `function_range_or_type`. Unused for a task.
    result: VarDecl = .{ .name = .none, .ty = .integer },
    /// A.2.7 `tf_*_declaration`s in declaration order, which is call order.
    ports: []const TfPort = &.{},
    /// A.2.7 `block_item_declaration`s.
    vars: []const VarDecl = &.{},
    /// A.2.8's `parameter_declaration`, `local_parameter_declaration` and
    /// `event_declaration` among them, declared in the subroutine's scope.
    params: []const ParamDecl = &.{},
    events: []const EventDecl = &.{},
    body: StmtId,
    main_tok: u32 = 0,
};

/// IEEE 1364-2005 §9.7.3 / AMS §5.10.4: one scalar event or unpacked
/// array of events. Each element has an identity, but holds no data.
pub const EventDecl = struct {
    name: StrId,
    dims: []const Dim = &.{},
    main_tok: u32 = 0,
};

/// One A.2.7 task/function formal: a direction and the variable it declares.
pub const TfPort = struct {
    direction: Direction,
    v: VarDecl,
    /// A body (non-ANSI) port's variable redeclarations folded into `v`,
    /// kept for IEEE 1364-2005 §12.3.3's rules, which the elaborator checks:
    /// a port declared with a type is complete, a name is declared again at
    /// most once, and a vector's two ranges are identical.
    redecl: Redecl = .{},

    pub const Redecl = struct {
        /// Variable declarations of the port's name; the first is in `v`.
        count: u32 = 0,
        /// The first one's name token.
        tok: u32 = 0,
        /// The port declaration wrote a type (`reg`, `integer`, `time`,
        /// `real`, `realtime`).
        typed: bool = false,
        /// The port declaration's own range, and the variable's.
        port_range: ?Dim = null,
        var_range: ?Dim = null,
    };
};

/// User-defined analog function. LRM §4.7.1 (A.2.6 analog_function_declaration).
/// The implicit return variable is the function's own name (§4.7.1).
pub const FuncDecl = struct {
    name: StrId,
    ret_ty: Type, // §4.7.1 analog_function_type (default `.real`)
    args: []const FuncArg, // §4.7.2, in declaration order (call order)
    /// §4.7.2 local declarations of the function body.
    params: []const ParamDecl = &.{},
    vars: []const VarDecl = &.{},
    /// §4.7.1 the single `analog_function_statement` (usually a `.block`).
    body: StmtId,
    main_tok: u32 = 0,
    /// §4.7's opening paragraph: "Each function can be an analog user-defined
    /// function or a digital function (as defined in IEEE Std 1364 Verilog)."
    /// False for the bare `function` spelling. The declaration is legal either
    /// way; §7.3.7 forbids only the call across contexts.
    is_analog: bool = true,
};

/// One `analog` construct. LRM §5.2 (A.6.2 analog_construct).
pub const AnalogBlock = struct {
    /// §5.2.1 `analog initial`: evaluated once, at initialization only.
    is_initial: bool = false,
    body: StmtId,
    main_tok: u32 = 0,
    /// Which module instance wrote this block, after elaboration concatenated
    /// every instance's blocks into the top's. 0 is the top itself; each inlined
    /// instance gets its own.
    ///
    /// §5.4.1 gives branch identity per instance, which flattening loses: two
    /// instances across the same nets share one unnamed branch. Same-kind
    /// contributions still aggregate, but §5.6.1.3's flow-discards-potential rule
    /// is about one branch, so `Lower.discardOpposite` scopes it by this unit.
    unit: u32 = 0,
};

/// One `initial` or `always` construct (A.6.2 initial_construct /
/// always_construct), §7.2.2's discrete context.
/// The analog device pipeline accepts only constant initial assignments; the
/// digital executor runs the rest through its event scheduler.
pub const DiscreteBlock = struct {
    /// `always` rather than `initial`. §7.2.2 puts both in the same context, so
    /// the context checks read this only for diagnostic wording;
    /// `Lower.collectInitialState` collects from `initial` only.
    is_always: bool = false,
    /// Hoisted out of a generate block by an analog parse: it exists only as
    /// the scheme selects (§6.6), which the digital engine decides, so it runs
    /// there and has no constant reading.
    generated: bool = false,
    body: StmtId,
    main_tok: u32 = 0,
};

/// A.6.1 `net_assignment ::= net_lvalue = expression`: one driver of one net
/// (IEEE 1364-2005 §6.1). `assign a = b, c = d;` is two of these.
pub const ContAssign = struct {
    target: ExprId,
    value: ExprId,
    /// A.6.1 `[ drive_strength ]`; IEEE 1364-2005 §7.9's default is
    /// `(strong1, strong0)`.
    strength0: Strength = .strong,
    strength1: Strength = .strong,
    /// A.6.1 `[ delay3 ]`: the driver's own delay, §6.1.3 inertial.
    delay: Delay3 = .{},
    main_tok: u32 = 0,
};

/// One port connection of a module instance. LRM §6.2.2 (A.4.1
/// ordered_port_connection / named_port_connection).
///
/// `name == .none` is the ordered form, where the row's position picks the
/// port; otherwise the `.p(expr)` form. `expr == .none` is §6.2.2's unconnected
/// port, from either a blank in an ordered list (`u(a, , b)`) or an empty
/// `.p()`; §9.19 `$port_connected` reads it.
pub const PortConn = struct {
    name: StrId = .none,
    expr: ExprId = .none,
    main_tok: u32 = 0,
};

/// One `#(...)` entry of a module instance. LRM §6.3 (A.4.1
/// list_of_parameter_assignments), both arms: `name == .none` is the ordered
/// form ("in the order of their declaration"), a name is `.p(expr)`.
pub const ParamOverride = struct {
    name: StrId = .none,
    value: ExprId = .none,
    main_tok: u32 = 0,
    /// A positional `#(...)` becomes a digital delay if elaboration resolves
    /// the instance to a UDP. Preserve the first §2.6.2 scaled literal before
    /// expression folding hides it; module parameter overrides allow it.
    scaled_literal_tok: ?u32 = null,
};

/// One `defparam` assignment. LRM §6.3.1 (A.1.4 parameter_override, A.2.4
/// defparam_assignment `hierarchical_parameter_identifier = constant_expression`).
///
/// `path` is the whole dotted left-hand side interned as one string, joined by
/// `Elaborate.sep` ('.'), so it equals the flat name elaboration gives the
/// target parameter. `value` is over parameters "declared in the same module as
/// the defparam statement" (§6.3.1), so it is cloned in the declaring module's
/// namespace.
pub const Defparam = struct {
    path: StrId,
    value: ExprId,
    /// IEEE 1364-2005 §12.2.1 a digital path's instance selects that do not
    /// fold at parse time (a genvar's, inside a loop generate block), in
    /// order: each is spelled `[]` in `path` and folded in the scope the
    /// defparam is elaborated in.
    indices: []const ExprId = &.{},
    main_tok: u32 = 0,
};

/// A module instance. LRM §6.2.2 (A.4.1 module_instantiation).
///
/// One `Instance` per `module_instance`, so `child #(2.0) a(x), b(y);` is two
/// rows sharing one `params` slice.
pub const Instance = struct {
    /// §6.2.2 module_or_paramset_identifier, resolved at elaboration because
    /// the definition may be declared after the use (A.1.2 puts no order on the
    /// descriptions of a source_text).
    module: StrId,
    name: StrId,
    /// §6.2.2 `name_of_module_instance ::= module_instance_identifier [ range ]`:
    /// an array of instances; `null` for a single one. Folded at elaboration.
    range: ?Dim = null,
    params: []const ParamOverride = &.{}, // §6.3
    ports: []const PortConn = &.{}, // §6.2.2
    /// A.5.4 `udp_instantiation ::= udp_identifier [ drive_strength ]
    /// [ delay2 ] udp_instance …`: a UDP instance's own brackets, which only
    /// a digital parse records (an analog one warns W0252 and keeps nothing).
    delay: Delay3 = .{},
    strength0: Strength = .strong,
    strength1: Strength = .strong,
    main_tok: u32 = 0,
};

/// A module. LRM §6.2 (A.1.2 module_declaration). Declarations are kept in
/// typed, source-ordered slices rather than a mixed item list: lowering wants
/// them by kind, and a declaration is not a statement.
pub const ModuleDecl = struct {
    name: StrId,
    /// §6.5, in header order. This is the terminal order the host device ABI sees.
    ports: []const Port,
    /// §6.2.1 module_parameter_port_list `#(...)` followed by body parameter
    /// declarations, in source order (later defaults may reference earlier
    /// parameters, §3.4).
    params: []const ParamDecl = &.{},
    aliasparams: []const AliasParam = &.{}, // §3.4.6
    vars: []const VarDecl = &.{}, // §3.2/§3.3
    nets: []const NetDecl = &.{}, // §3.6.3
    branches: []const BranchDecl = &.{}, // §3.12
    /// §6.2.2 child instances, in source order. Elaboration flattens them away.
    instances: []const Instance = &.{},
    /// §6.3.1 `defparam`s written in this module, in source order. Elaboration
    /// applies them to the flattened parameters.
    defparams: []const Defparam = &.{},
    genvars: []const StrId = &.{}, // §3.5 (unrolling evidence, §6.6.1)
    /// §5.10.4 named events (A.2.1.3 event_declaration). Scalar events and
    /// array elements each have an identity, but carry no value.
    events: []const EventDecl = &.{},
    functions: []const FuncDecl = &.{}, // §4.7.1
    /// §5.2 analog blocks in source order.
    analog: []const AnalogBlock = &.{},
    /// A.6.2 `initial`/`always` constructs in source order, §7.2.2's discrete
    /// context.
    discrete: []const DiscreteBlock = &.{},
    /// A.6.1 continuous assignments in source order. One entry per
    /// net_assignment, because each is a separate driver of its net
    /// (IEEE 1364-2005 §6.1).
    assigns: []const ContAssign = &.{},
    /// A.3.1 gate instantiations in source order. Separate from `assigns`
    /// because §7.8.5's value tables are not the expression operators: a gate
    /// input is a logic value, so z on one reads as x.
    gates: []const GateInst = &.{},
    /// A.3.1 pullup/pulldown sources (§7.8), in source order.
    pulls: []const PullInst = &.{},
    /// IEEE 1364-2005 §10 tasks and digital functions (see `Subroutine`);
    /// an analog parse fills the tasks only.
    tasks: []const Subroutine = &.{},
    /// A.3.1 switch instances (§7.6), filled by a digital parse only.
    switches: []const SwitchInst = &.{},
    /// A.7.2 module paths and A.7.5 system timing checks of the module's
    /// `specify` blocks (IEEE 1364 Clause 14/15, inherited through §1.1).
    /// Recorded for §11.6.15's VPI objects and simulated by the digital
    /// engine; an analog compile applies none of them (W0251).
    paths: []const SpecPath = &.{},
    timing_checks: []const TimingCheck = &.{},
    /// §14.6 the pulse controls of its specify blocks and specparams.
    pulses: []const PulseControl = &.{},
    /// §2.9 every `attr_spec` in this module, for value validation. Owner
    /// associations are retained separately in `SourceFile.attributes`.
    attrs: []const NatureAttr = &.{},
    /// A.1.2 the `module_keyword` was `connectmodule` (§7.6). Unlike `module`
    /// and `macromodule`, which §6.2 makes interchangeable, it matters twice:
    /// §7.6 makes a connect module something insertion places on a mixed net,
    /// never a design root, so `elaborate.pickTop` skips it; and §7.2.2 allows
    /// the discrete context in its body, so `always` there is not E0205.
    is_connect: bool = false,
    main_tok: u32 = 0,
};

// ---- private ----

test "ParamDecl carries §3.4.2 ranges through to lowering" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);

    // parameter real r = 1k from (0:inf);
    const zero = try f.exprs.addInt(gpa, 0, 0);
    const inf = try f.exprs.add(gpa, .{ .tag = .pos_inf, .main_tok = 1 });
    const dflt = try f.exprs.addReal(gpa, 2, 1000.0);
    const ranges = [_]ValueRange{.{
        .kind = .from,
        .lo = zero,
        .hi = inf,
        .lo_inclusive = false,
        .hi_inclusive = false,
    }};
    const p: ParamDecl = .{
        .name = try f.intern(gpa, "r"),
        .ty = .real,
        .default = dflt,
        .ranges = &ranges,
    };
    try std.testing.expectEqual(@as(usize, 1), p.ranges.len);
    try std.testing.expectEqual(ExprTag.pos_inf, f.exprs.tag(p.ranges[0].hi));
    try std.testing.expect(!p.ranges[0].lo_inclusive);
}

test "Strength's backing integers order supply > strong > pull > large > weak > medium > small > highz" {
    const order = [_]Strength{ .highz, .small, .medium, .weak, .large, .pull, .strong, .supply };
    try std.testing.expectEqual(std.enums.values(Strength).len, order.len);
    for (order[0 .. order.len - 1], order[1..]) |lo, hi| try std.testing.expect(@backingInt(lo) < @backingInt(hi));
}

test "Port.connName prefers the external name; Delay3.any reads the rise slot" {
    const p: Port = .{ .name = @fromBackingInt(1) };
    try std.testing.expectEqual(p.name, p.connName());
    const q: Port = .{ .name = @fromBackingInt(1), .external_name = @fromBackingInt(2) };
    try std.testing.expectEqual(q.external_name, q.connName());
    try std.testing.expect(!(Delay3{}).any());
    try std.testing.expect((Delay3{ .rise = @fromBackingInt(0) }).any());
}
