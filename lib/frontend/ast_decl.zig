//! The declaration rows of the AST: modules, their parameters, variables,
//! nets, ports, branches, instances and processes (LRM ch3, §4.7, ch6, §7.7),
//! natures and disciplines (§3.6), paramsets (§6.4), and the IEEE 1364-2005
//! user-defined primitives (A.5) and configurations (§13.3).
//! In: the declarations the parser recognises. Out: one struct per
//! declaration, its lists as arena slices, read by elaboration, lowering and
//! the digital engine; no later stage writes one. Also the one walk over
//! them, `natureAttrExpr` (§3.6.1.1).

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
pub const TfPort = struct { direction: Direction, v: VarDecl };

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

/// A.3.4's gate types that compute a logic value. §7.8.5's tables define all
/// twelve; `n_input`, `n_output` and `enable` gates differ only in what their
/// terminal list means, which `GateInst` records in its shape.
pub const GateKind = enum { g_and, g_nand, g_or, g_nor, g_xor, g_xnor, g_buf, g_not, g_bufif0, g_bufif1, g_notif0, g_notif1 };

/// A.3.1 one `gate_instance`. `out` is the output terminal (§7.8.5.1's `out`;
/// a `buf`/`not` with several outputs becomes one `GateInst` per output, since
/// each is a separate driver). `ins` is the rest in source order: the inputs of
/// an n-input gate, `(data, enable)` for an enable gate, the single input of
/// `buf`/`not`. A gate drives `out` (§7.1), so it carries a `ContAssign`'s
/// strength and delay.
pub const GateInst = struct {
    kind: GateKind,
    out: ExprId,
    ins: []const ExprId,
    /// A.3.1 `name_of_gate_instance`, `.none` when not written.
    name: StrId = .none,
    /// IEEE 1364-2005 §7.1.5 an array of instances, `name [ range ]`: one
    /// gate per index, vector terminals split among them (§7.1.6).
    range: ?Dim = null,
    strength0: Strength = .strong,
    strength1: Strength = .strong,
    delay: Delay3 = .{},
    main_tok: u32 = 0,
    /// Hoisted out of a generate block by an analog parse, which keeps no
    /// generate scope (`parser/generate.zig`); a digital parse leaves such a
    /// gate on its block, so it is not in the module's list there.
    generated: bool = false,
};

/// A.7.4 `edge_identifier` / A.7.5.3 `timing_check_event_control`.
pub const SpecEdge = enum(u8) { none, posedge, negedge, edge };
/// A.7.4 `polarity_operator`, absent when not written.
pub const SpecPolarity = enum(u8) { none, positive, negative };

/// A.7.2 one `path_declaration`: parallel (`=>`) or full (`*>`), simple or
/// edge-sensitive, optionally state-dependent.
pub const SpecPath = struct {
    full: bool,
    edge: SpecEdge = .none,
    /// The polarity before the arrow (a simple path's).
    polarity: SpecPolarity = .none,
    /// `if ( module_path_expression )`, or `.none`.
    cond: ExprId = .none,
    ifnone: bool = false,
    ins: []const ExprId,
    outs: []const ExprId,
    /// An edge-sensitive path's `data_source_expression` and the polarity
    /// written before its colon.
    data: ExprId = .none,
    data_polarity: SpecPolarity = .none,
    /// A.7.4 `list_of_path_delay_expressions`: 1, 2, 3, 6 or 12.
    delays: []const ExprId,
    main_tok: u32,
};

/// A.7.5.1 one `system_timing_check`: the command, and each argument slot in
/// order (`.none` for a slot A.7.5.1 lets be empty) with the event control
/// written on it.
pub const TimingCheck = struct {
    name: StrId,
    args: []const ExprId,
    edges: []const SpecEdge,
    /// Per argument slot, the IEEE 1364-2005 §15.4 transitions its
    /// `timing_check_event_control` names, one bit each (`transition`), a z
    /// read as x: `posedge` is `posedge_mask`, `negedge` `negedge_mask`, an
    /// `edge [...]` its descriptors; 0 for a slot with no event control.
    masks: []const u8 = &.{},
    /// Per argument slot, its A.7.5.3 `&&& timing_check_condition`, or
    /// `.none`.
    conds: []const ExprId = &.{},
    main_tok: u32,

    /// §15.4: "posedge clr is equivalent to ... edge[01, 0x, x1] clr".
    pub const posedge_mask: u8 = 0b100011;
    /// §15.4: "negedge clr is the same as ... edge[10, x0, 1x] clr".
    pub const negedge_mask: u8 = 0b011100;

    /// Returns the `masks` bit of the transition `from` -> `to` (§15.4:
    /// "Edge transitions involving z are treated the same way as edge
    /// transitions involving x"); 0 when they name none (the same level, or
    /// x to z). Bits 0..5 are 01, 0x, 10, 1x, x0, x1.
    /// Asserts each of `from` and `to` is `0`, `1`, `x` or `z`, lower case;
    /// the parser folds a descriptor's case before calling.
    pub fn transition(from: u8, to: u8) u8 {
        std.debug.assert(std.mem.findScalar(u8, "01xz", from) != null);
        std.debug.assert(std.mem.findScalar(u8, "01xz", to) != null);
        const f: u8 = if (from == 'z') 'x' else from;
        const t: u8 = if (to == 'z') 'x' else to;
        if (f == t) return 0;
        return switch (f) {
            '0' => if (t == '1') 1 << 0 else 1 << 1,
            '1' => if (t == '0') 1 << 2 else 1 << 3,
            else => if (t == '0') 1 << 4 else 1 << 5, // else: `x`, the only other level after the z fold
        };
    }

    /// Returns the transitions `mask` names, each turned around (01 <-> 10,
    /// 0x <-> x0, 1x <-> x1): §15.3.4's "reference event signal with
    /// opposite edge". An involution on bits 0..5; bits 6 and 7 are dropped.
    pub fn opposite(mask: u8) u8 {
        const swap = [6]u3{ 2, 4, 0, 5, 1, 3 };
        var out: u8 = 0;
        for (swap, 0..) |to, from| {
            if (mask & (@as(u8, 1) << @intCast(from)) != 0) out |= @as(u8, 1) << to;
        }
        return out;
    }
};

/// A.3.1 one `pull_gate_instance`, IEEE 1364-2005 §7.8's pullup/pulldown
/// source. It drives one constant, so it is not a `GateInst`: it has no
/// inputs and §7.8 gives it no delay. `strength` is the one side that counts
/// ("a strength0 specification on a pullup source ... shall be ignored").
pub const PullInst = struct {
    out: ExprId,
    /// `pullup` drives 1, `pulldown` drives 0.
    one: bool,
    strength: Strength = .pull,
    /// A.3.1 `name_of_gate_instance`, `.none` when not written.
    name: StrId = .none,
    /// `name_of_gate_instance ::= gate_instance_identifier [ range ]`: an
    /// instance array (IEEE 1364-2005 §7.1.5), as `GateInst.range`.
    range: ?Dim = null,
    main_tok: u32 = 0,
    /// As `GateInst.generated`.
    generated: bool = false,
};

/// A.3.4's switch types (IEEE 1364-2005 §7.6/§7.7): the MOS and CMOS switches
/// pass their input one way, the pass switches conduct both ways; an `r`
/// prefix is the resistive variant (§7.12's strength reduction).
pub const SwitchKind = enum(u8) { cmos, rcmos, nmos, pmos, rnmos, rpmos, tran, rtran, tranif0, tranif1, rtranif0, rtranif1 };

/// A.3.1 one switch instance: its terminals in source order (output, input,
/// control(s) for a MOS/CMOS switch; the two inout terminals, then the
/// enable, for a pass switch).
pub const SwitchInst = struct {
    kind: SwitchKind,
    terms: []const ExprId,
    delay: Delay3 = .{},
    /// A.3.1 `name_of_gate_instance`, `.none` when not written, and its
    /// §7.1.5 instance-array range.
    name: StrId = .none,
    range: ?Dim = null,
    main_tok: u32 = 0,
    /// As `GateInst.generated`.
    generated: bool = false,
};

/// One terminal of a built-in primitive as VAMS §7.8.5.1 names it "for the
/// purpose of naming the connect modules" §7.8.4 inserts on it (§7.8.5's
/// `SigName__InstName__PortName`).
pub const PrimTerm = struct {
    /// The module list that holds the primitive, and its row there.
    list: enum { gate, pull, switch_ },
    row: u32,
    /// 0 a gate's `out`, k its `ins[k - 1]`; a pull's terminal; a switch's
    /// `terms[k]`.
    term: u32,
    /// §7.8.5's InstName, before an instance array's `[k]` (`range`).
    inst: []const u8,
    range: ?Dim,
    port: []const u8,
    /// IEEE 1364-2005 A.3.3's direction of the terminal, which §7.8.4's
    /// matching reads as a port's.
    dir: Direction,
    expr: ExprId,
    generated: bool,
    main_tok: u32,
};

/// Every terminal of `m`'s primitives, named by VAMS §7.8.5.1, in source
/// order. The one naming rule for the analog compile's insertion
/// (`elab/insert.zig`) and the mixed runner's (`lib/sim/digital/elab.zig`
/// `bridged`), which meet only through these strings.
///
/// - "For N-input gates (and, nand, nor, or, xnor, xor) the output will be
///   named out, and the inputs reading from left to right will be in1, in2,
///   in3". "For N-output gates (buf, not) The input will be named in, and the
///   outputs reading from left to right will be named out1, out2, out3": such
///   a gate is one row per output, so an output's number is its row's place
///   among its instance's rows (one `main_tok`), and `in` is listed once, on
///   the first row.
/// - "3 port MOS switches (nmos, pmos, rnmos, rpmos) ... source, drain, gate";
///   "4 port MOS switches (cmos, rcmos) ... source, drain, ngate, pgate";
///   "bidirectional pass switches (tran, tranif1, tranif0, rtran, rtranif1,
///   rtranif) ... source, drain, gate"; "single port primitives (pullup,
///   pulldown) ... out". Left to right is the A.3.1 terminal order.
/// - The enable gates (bufif0, bufif1, notif0, notif1), which the clause does
///   not name: `out`, `in`, `enable`, left to right (VerA's choice, after the
///   N-input names; Vague_Decisions VD-115).
///
/// InstName is the instance's name. IEEE 1364-2005 A.3.1 makes it optional
/// and neither standard names an unnamed instance (VerA's VPI gives it none),
/// so one is `<gatetype>$<n>`, n counting from 1 the module's unnamed
/// instances of that type in source order (VD-115). A primitive an analog
/// parse hoisted out of a generate block is not counted, so the numbers match
/// a digital parse's, which keeps it on its block; it is listed with its
/// type name alone.
///
/// The result, every generated name and the scratch map all live in `a`,
/// and nothing is freed: pass an arena.
pub fn primTerms(a: std.mem.Allocator, file: *const SourceFile, m: *const ModuleDecl) std.mem.Allocator.Error![]PrimTerm {
    var out: std.ArrayList(PrimTerm) = .empty;
    // Unnamed instances seen per type name, for `<gatetype>$<n>`.
    var unnamed: std.StringHashMapUnmanaged(u32) = .empty;
    const Name = struct {
        fn of(al: std.mem.Allocator, f: *const SourceFile, seen: *std.StringHashMapUnmanaged(u32), name: StrId, ty: []const u8, generated: bool) ![]const u8 {
            if (name != .none) return f.str(name);
            if (generated) return ty;
            const n = try seen.getOrPutValue(al, ty, 0);
            n.value_ptr.* += 1;
            return al.print("{s}${d}", .{ ty, n.value_ptr.* });
        }
    };
    var inst: []const u8 = "";
    var k: u32 = 0; // the row's place among its instance's rows
    for (m.gates, 0..) |g, gi| {
        const first = gi == 0 or m.gates[gi - 1].main_tok != g.main_tok;
        k = if (first) 1 else k + 1;
        if (first) inst = try Name.of(a, file, &unnamed, g.name, @tagName(g.kind)[2..], g.generated);
        for (0..1 + g.ins.len) |t| {
            const port: []const u8, const dir: Direction = switch (g.kind) {
                .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor => if (t == 0) .{ "out", .output } else .{ try a.print("in{d}", .{t}), .input },
                .g_buf, .g_not => if (t == 0) .{ try a.print("out{d}", .{k}), .output } else if (first) .{ "in", .input } else continue,
                .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => .{ ([_][]const u8{ "out", "in", "enable" })[t], if (t == 0) .output else .input },
            };
            try out.append(a, .{ .list = .gate, .row = @intCast(gi), .term = @intCast(t), .inst = inst, .range = g.range, .port = port, .dir = dir, .expr = if (t == 0) g.out else g.ins[t - 1], .generated = g.generated, .main_tok = g.main_tok });
        }
    }
    for (m.pulls, 0..) |p, pi| try out.append(a, .{
        .list = .pull,
        .row = @intCast(pi),
        .term = 0,
        .inst = try Name.of(a, file, &unnamed, p.name, if (p.one) "pullup" else "pulldown", p.generated),
        .range = null,
        .port = "out",
        .dir = .output,
        .expr = p.out,
        .generated = p.generated,
        .main_tok = p.main_tok,
    });
    for (m.switches, 0..) |sw, si| {
        const name = try Name.of(a, file, &unnamed, sw.name, @tagName(sw.kind), sw.generated);
        const ports: []const []const u8, const dirs: []const Direction = switch (sw.kind) {
            .nmos, .pmos, .rnmos, .rpmos => .{ &.{ "source", "drain", "gate" }, &.{ .output, .input, .input } },
            .cmos, .rcmos => .{ &.{ "source", "drain", "ngate", "pgate" }, &.{ .output, .input, .input, .input } },
            .tran, .rtran, .tranif0, .tranif1, .rtranif0, .rtranif1 => .{ &.{ "source", "drain", "gate" }, &.{ .inout, .inout, .input } },
        };
        for (sw.terms, 0..) |x, t| try out.append(a, .{ .list = .switch_, .row = @intCast(si), .term = @intCast(t), .inst = name, .range = sw.range, .port = ports[t], .dir = dirs[t], .expr = x, .generated = sw.generated, .main_tok = sw.main_tok });
    }
    return out.items;
}

/// Points terminal `t.term` of the primitive `t` names at `x`, in rows laid
/// out like the module's lists `primTerms` read (`row` is `t.row`, or the
/// same row of a flattened list). A `buf`/`not` input re-points every output
/// row of its instance (one `main_tok`), since `primTerms` lists it once.
/// A changed `ins` or `terms` list is a fresh copy in `a` (the old one may
/// be shared and is never written or freed); `out` is written in place.
pub fn setPrimTerm(a: std.mem.Allocator, gates: []GateInst, pulls: []PullInst, switches: []SwitchInst, t: PrimTerm, row: usize, x: ExprId) std.mem.Allocator.Error!void {
    switch (t.list) {
        .gate => {
            var i = row;
            while (i < gates.len and gates[i].main_tok == gates[row].main_tok) : (i += 1) {
                const g = &gates[i];
                if (t.term == 0) {
                    g.out = x;
                    return;
                }
                const ins = try a.dupe(ExprId, g.ins);
                ins[t.term - 1] = x;
                g.ins = ins;
            }
        },
        .pull => pulls[row].out = x,
        .switch_ => {
            const terms = try a.dupe(ExprId, switches[row].terms);
            terms[t.term] = x;
            switches[row].terms = terms;
        },
    }
}

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
    /// Recorded for §11.6.15's VPI objects; no simulation applies them
    /// (W0251).
    paths: []const SpecPath = &.{},
    timing_checks: []const TimingCheck = &.{},
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

/// One `(* vera_lte [= constant_expression] *)`, or the same for
/// `vera_interp`, `vera_nodiff` or `vera_timepoint`; see `SourceFile.lte_attrs`.
/// Exactly one of `stmt`/`expr` is set. `value == .none` is §2.9's "If a value
/// is not specifically assigned to the attribute, then its value shall be 1".
pub const LteAttr = struct {
    /// The attribute's name, which is its tag.
    kind: enum { vera_lte, vera_interp, vera_nodiff, vera_timepoint } = .vera_lte,
    stmt: StmtId = .none,
    expr: ExprId = .none,
    value: ExprId,
    main_tok: u32,
};

/// Nature attribute: `name = expr;`. LRM §3.6.1 (A.1.6 nature_attribute).
/// The LRM-defined names are `abstol` (§3.6.1.2, required for a base nature),
/// `access`, `units`, `idt_nature` and `ddt_nature` (all §3.6.1.2), plus
/// user attributes (§3.6.1.3: `huge`, `blowup`, …).
/// `value` may be an `.ident` (A.8.3 nature_attribute_expression allows a
/// nature or access identifier, not just a constant).
pub const NatureAttr = struct {
    name: StrId,
    value: ExprId,
    main_tok: u32 = 0,
};

/// §2.9 / IEEE 1364-2005 §3.8: an attribute's parsed language element.
/// Source tokens identify declarations through elaboration; the category
/// distinguishes a statement from its leading operand and a declaration
/// from an initializer. A declaration list attaches the same specs to each
/// declared item. No later stage has to infer attachment from source text.
pub const AttributeOwner = struct {
    kind: enum { declaration, statement, expression },
    tok: u32,
};
/// One §2.9 attribute_instance and what it decorates: `SourceFile.attributes`
/// keeps one per instance, in source order.
pub const AttributeBinding = struct { owner: AttributeOwner, specs: []const NatureAttr };

/// Nature declaration. LRM §3.6.1 (A.1.6 nature_declaration).
pub const NatureDecl = struct {
    name: StrId,
    /// §3.6.1.1 derived nature: `nature x : parent`. `.none` = base nature
    /// (which then must declare `abstol` and `access`, §3.6.1).
    parent: StrId = .none,
    /// A.1.6 `parent_nature ::= ... | discipline_identifier . potential_or_flow`
    /// Set when the parent was written as `electrical.potential`.
    parent_access: ?PotentialOrFlow = null,
    attrs: []const NatureAttr = &.{},
    main_tok: u32 = 0,
};

/// Discipline declaration. LRM §3.6.2 (A.1.7 discipline_declaration).
pub const DisciplineDecl = struct {
    name: StrId,
    /// §3.6.2.1 `potential <nature>;`; `.none` for a flow-only discipline.
    potential: StrId = .none,
    /// §3.6.2.1 `flow <nature>;`; `.none` for a signal-flow discipline.
    flow: StrId = .none,
    /// §3.6.2.2 `domain continuous|discrete`.
    domain: Domain = .unspecified,
    /// §3.6.2.3 `potential.abstol = 1e-6;` style overrides.
    overrides: []const Override = &.{},
    // ponytail: no read syntax reaches these. §5.5.3's `net.potential_or_flow.attr`
    // lands on the bound nature, and the LRM gives a discipline attribute no
    // access spelling; a host reading the AST is the only consumer.
    /// §3.6.2.7 "Like natures, a discipline can specify user-defined
    /// attributes." A.1.7's discipline_item grammar omits the production; the
    /// prose governs (see `parseDiscipline`, parser/discipline.zig).
    attrs: []const NatureAttr = &.{},
    main_tok: u32 = 0,

    /// §3.6.2.2 the written domain; `.unspecified` when none was written.
    pub const Domain = enum(u8) { unspecified, continuous, discrete };
    /// One §3.6.2.3 `potential.attr = expr;` / `flow.attr = expr;`: the half
    /// whose nature it overrides, and the attribute.
    pub const Override = struct {
        which: PotentialOrFlow,
        attr: NatureAttr,
    };
};

/// Paramset. LRM §6.4 (A.1.9 paramset_declaration).
pub const ParamsetDecl = struct {
    name: StrId,
    /// The module (or paramset) this specializes.
    target: StrId,
    params: []const ParamDecl = &.{}, // §6.4 parameter/localparam decls
    aliasparams: []const AliasParam = &.{},
    vars: []const VarDecl = &.{},
    /// `.name = expr;` assignments (A.1.9 paramset_statement).
    overrides: []const ParamsetOverride = &.{},
    /// A.1.9 also allows `analog_function_statement`s in the body.
    body: []const StmtId = &.{},
    main_tok: u32 = 0,
};

/// One A.1.9 paramset_statement `.name = expr;`.
pub const ParamsetOverride = struct {
    /// Which flavour of `.identifier` was on the left (A.1.9).
    kind: Kind,
    name: StrId,
    value: ExprId,
    main_tok: u32 = 0,

    /// A.1.9 `.module_parameter_identifier = ...` or its
    /// `.system_parameter_identifier` sibling (§9.18, `.$mfactor`).
    pub const Kind = enum(u8) { module_param, system_param };
};

/// Connect specification block. LRM §7.7 (A.1.8 connectrules_declaration),
/// an A.1.2 description, so it is a sibling of the module/discipline lists on
/// `SourceFile`, not of any module item. The two item forms share the
/// `connect` keyword and split on what follows the first identifier
/// (`parseConnectRules`, parser/connectrules.zig).
pub const ConnectRulesDecl = struct {
    name: StrId,
    /// §7.7.1 connect module auto-insertion statements, in source order.
    insertions: []const ConnectInsertion = &.{},
    /// §7.7.2 discipline resolution statements, in source order; §7.7.2.1
    /// breaks a multi-match tie by taking "the first match".
    resolutions: []const ConnectResolution = &.{},
    main_tok: u32 = 0,
};

/// `connect connectmodule_identifier [connect_mode] [#(...)] [overrides] ;`
/// LRM §7.7.1 (A.1.8 connect_insertion): names the connect module the
/// auto-insertion phase (§7.8) would place on a mixed net of the bridged
/// discipline pair.
///
/// Consumed by `elab/insert.zig` (§7.8 insertion, analog half):
/// `mode` picks merged vs split segments (§7.7.4), `params` is passed to the
/// inserted instance (§7.7.3), and `overrides` re-types a port's discipline
/// and direction before matching (§7.7.1).
pub const ConnectInsertion = struct {
    /// §7.7.1 connectmodule_identifier, resolved at elaboration like
    /// `Instance.module`, because A.1.2 puts no order on descriptions.
    module: StrId,
    /// §7.7.4 `merged` | `split`; `.unspecified` when the source wrote none
    /// (§7.8.3 makes `merged` the default, applied by the consumer, not here).
    mode: Mode = .unspecified,
    /// §7.7.3 `#(.tt(3.5n), ...)`: the same A.4.1 parameter_value_assignment
    /// an instance carries, parsed by the same code.
    params: []const ParamOverride = &.{},
    /// §7.7.1 discipline (and optionally direction) overrides, or null when
    /// the statement ends at the parameter list.
    overrides: ?PortOverrides = null,
    main_tok: u32 = 0,

    /// §7.7.4 `connect_mode`; see `mode`.
    pub const Mode = enum(u8) { unspecified, merged, split };
    /// A.1.8 connect_port_overrides: two disciplines, each optionally
    /// directed. The grammar fixes the legal direction pairings
    /// (input/output, output/input, inout/inout, or neither); the parser
    /// enforces that, so a stored pair is always one of the four productions.
    pub const PortOverrides = struct {
        a_dir: Direction = .unspecified,
        a: StrId,
        b_dir: Direction = .unspecified,
        b: StrId,
    };
};

/// `connect d1 { , dN } resolveto discipline_or_exclude ;` LRM §7.7.2 (A.1.8
/// connect_resolution): when resolution (annex F.2 step 4.b, third bullet)
/// finds more than one candidate discipline for an undeclared net and the
/// candidate set matches `disciplines`, the net is of discipline `resolved`,
/// which "need not be one of the disciplines specified in the discipline
/// list" (§7.7.2.1). With `exclude` instead, the listed disciplines "are
/// deemed to be incompatible and an error is indicated if they are found on
/// the same net" (§7.7.2).
pub const ConnectResolution = struct {
    /// The discipline list before `resolveto`, in source order.
    disciplines: []const StrId,
    /// The discipline after `resolveto`; `.none` iff `exclude`.
    resolved: StrId = .none,
    /// A.1.8 discipline_identifier_or_exclude took the `exclude` arm.
    exclude: bool = false,
    main_tok: u32 = 0,
};

// ---------------------------------------------------------------------------
// User-defined primitives: LRM §8.5.3, annex A.5
// ---------------------------------------------------------------------------

/// One A.5.3 `combinational_entry` or `sequential_entry`, as the characters of
/// its columns. A.5.3's alphabets are characters: an `edge_indicator ::= (
/// level_symbol level_symbol )` is one input field that lexes as three tokens,
/// so `parseUdpEntry` concatenates each column's token text.
pub const UdpRow = struct {
    /// `level_input_list` or `seq_input_list`, validated against A.5.3's
    /// alphabets, `( )` included so an edge entry keeps its grouping.
    inputs: []const u8,
    /// `current_state ::= level_symbol`; 0 for a combinational entry, which
    /// has no such column.
    state: u8 = 0,
    /// `output_symbol ::= 0 | 1 | x | X`, or `-` for a `next_state` that holds.
    output: u8,
};

// ponytail: `UdpRow.inputs` is not split into one field per input port; the
// evaluator is where that split has a consumer, and where the per-port field
// count can be checked with a diagnostic.
/// LRM §8.5.3 / A.5.1 `udp_declaration` as validated by `parseUdpDecl`.
/// Evaluating it belongs to whatever executes the discrete cycle.
pub const UdpDecl = struct {
    name: StrId,
    /// A.5.2 `udp_port_list ::= output_port_identifier , input_port_identifier
    /// { , input_port_identifier }`, so `ports[0]` is the output and
    /// `ports[1..]` are the inputs, in the order A.5.3's input list is written
    /// in. Both A.5.1 header arms produce the same order.
    ports: []const StrId = &.{},
    /// Which A.5.3 `udp_body` alternative the table is, taken from the table
    /// itself: a `sequential_entry` is the two-colon one, and `parseUdpTable`
    /// already requires every entry to agree.
    ///
    /// Not taken from the `reg` on the output declaration. A.5.2 admits one
    /// there and A.5.3 decides the body; a UDP that writes `reg` over a
    /// combinational table is malformed, and nothing checks that yet.
    is_sequential: bool = false,
    /// A.5.3 `udp_initial_statement ::= initial output_port_identifier =
    /// init_val ;`; `.none` when the declaration carries none.
    init: ExprId = .none,
    /// The identifier the initial statement assigns (§8.1.3: the output).
    init_target: StrId = .none,
    /// The ports declared `output`, the last one's name, and whether any
    /// `reg` is declared: IEEE 1364-2005 §8.1.1 wants exactly one output,
    /// first in the list; §8.1.2 a `reg` for a sequential UDP's output and
    /// none in a combinational one. The digital engine judges them.
    outputs: u8 = 0,
    output: StrId = .none,
    has_reg: bool = false,
    rows: []const UdpRow = &.{},
    main_tok: u32 = 0,
};

/// IEEE 1364-2005 Syntax 13-1 `[library_identifier.]cell_identifier[:config]`.
pub const LibCell = struct {
    /// `.none` when omitted; the clause using it says which library that is.
    lib: StrId = .none,
    cell: StrId,
    /// The `:config` suffix (§13.1.1), which only a use clause admits.
    config: bool = false,
};

/// IEEE 1364-2005 §13.3.1 one `config_rule_statement`.
pub const ConfigRule = struct {
    select: union(enum) {
        default,
        /// §13.3.1.3 `inst_name`, interned whole (`top.a1`).
        instance: StrId,
        cell: LibCell,
    },
    expand: union(enum) {
        liblist: []const StrId,
        use: LibCell,
    },
    main_tok: u32,
};

/// IEEE 1364-2005 §13.3.1 / A.1.5 `config_declaration`.
pub const ConfigDecl = struct {
    name: StrId,
    /// §13.3.1.1 the top-level cells, in the order the statement lists them.
    design: []const LibCell,
    rules: []const ConfigRule,
    main_tok: u32,
};

/// Returns the value expression a (possibly derived) nature gives `attr`, or
/// null (§3.6.1.1). A derived nature overrides its base, so the first hit
/// walking up the parent chain wins. A parent written as
/// `discipline.potential_or_flow` continues at the nature that discipline
/// binds there (§3.6.2.6). Null when a name in the chain is undeclared, a
/// bound half is empty, or the chain is longer than 16 hops (so a cyclic
/// chain ends). Where two natures share a name the first declared is used.
/// Cost: O(16 × (natures + disciplines + attributes)).
/// Lowering and elaboration both call it.
pub fn natureAttrExpr(self: *const SourceFile, name: StrId, attr: []const u8) ?ExprId {
    var want = name;
    var hops: u32 = 0;
    while (hops < 16) : (hops += 1) {
        const nat = for (self.natures) |*n| {
            if (n.name == want) break n;
        } else return null;
        for (nat.attrs) |a| {
            if (std.mem.eql(u8, self.str(a.name), attr)) return a.value;
        }
        if (nat.parent == .none) return null;
        // A.1.6 `parent_nature ::= nature_identifier | discipline_identifier
        // . potential_or_flow`. In the second form the parent names a
        // discipline, so the walk continues at whichever nature that
        // discipline binds to the named half (§3.6.2.6).
        if (nat.parent_access) |half| {
            const d = for (self.disciplines) |*x| {
                if (x.name == nat.parent) break x;
            } else return null;
            const bound = switch (half) {
                .potential => d.potential,
                .flow => d.flow,
            };
            if (bound == .none) return null;
            // §3.6.2.6 the parent is the nature as the discipline binds it,
            // so a §3.6.2.3 override there (`flow.abstol = 10u;`) is what
            // the derived nature inherits. The last override wins, as in
            // `collectDisciplines`.
            var over: ?ExprId = null;
            for (d.overrides) |o| {
                if (o.which == half and std.mem.eql(u8, self.str(o.attr.name), attr)) over = o.attr.value;
            }
            if (over) |v| return v;
            want = bound;
            continue;
        }
        want = nat.parent;
    }
    return null;
}

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

test "TimingCheck.transition: every level pair, z read as x (§15.4)" {
    const levels = "01xz";
    // Rows `from`, columns `to`, both in the order 0 1 x z. Bit values:
    // 01 = 1, 0x = 2, 10 = 4, 1x = 8, x0 = 16, x1 = 32.
    const want = [4][4]u8{
        .{ 0, 1, 2, 2 },
        .{ 4, 0, 8, 8 },
        .{ 16, 32, 0, 0 },
        .{ 16, 32, 0, 0 },
    };
    for (levels, 0..) |from, i| {
        for (levels, 0..) |to, j| try std.testing.expectEqual(want[i][j], TimingCheck.transition(from, to));
    }
    // §15.4's two equivalences, built from the single transitions.
    const t = TimingCheck.transition;
    try std.testing.expectEqual(TimingCheck.posedge_mask, t('0', '1') | t('0', 'x') | t('x', '1'));
    try std.testing.expectEqual(TimingCheck.negedge_mask, t('1', '0') | t('x', '0') | t('1', 'x'));
}

test "TimingCheck.opposite turns each transition around and is an involution" {
    for (0..64) |m| {
        const mask: u8 = @intCast(m);
        try std.testing.expectEqual(mask, TimingCheck.opposite(TimingCheck.opposite(mask)));
        try std.testing.expectEqual(@popCount(mask), @popCount(TimingCheck.opposite(mask)));
    }
    try std.testing.expectEqual(TimingCheck.negedge_mask, TimingCheck.opposite(TimingCheck.posedge_mask));
    const levels = "01x";
    for (levels) |from| {
        for (levels) |to| {
            if (from == to) continue;
            try std.testing.expectEqual(TimingCheck.transition(to, from), TimingCheck.opposite(TimingCheck.transition(from, to)));
        }
    }
    try std.testing.expectEqual(@as(u8, 0), TimingCheck.opposite(0b1100_0000));
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

test "natureAttrExpr: own, inherited, overridden, through a discipline, and a cycle" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);
    const abstol = try f.intern(gpa, "abstol");
    const units = try f.intern(gpa, "units");
    const base = try f.intern(gpa, "Base");
    const derived = try f.intern(gpa, "Derived");
    const via = try f.intern(gpa, "Via");
    const half = try f.intern(gpa, "Half");
    const loop_a = try f.intern(gpa, "LoopA");
    const loop_b = try f.intern(gpa, "LoopB");
    const elec = try f.intern(gpa, "elec");
    const v1 = try f.exprs.addInt(gpa, 0, 1);
    const v2 = try f.exprs.addInt(gpa, 0, 2);
    const v3 = try f.exprs.addInt(gpa, 0, 3);
    const base_attrs = [_]NatureAttr{ .{ .name = abstol, .value = v1 }, .{ .name = units, .value = v2 } };
    const derived_attrs = [_]NatureAttr{.{ .name = abstol, .value = v3 }};
    const natures = [_]NatureDecl{
        .{ .name = base, .attrs = &base_attrs },
        .{ .name = derived, .parent = base, .attrs = &derived_attrs },
        // A.1.6 `nature Via : elec.potential;` and `nature Half : elec.flow;`.
        .{ .name = via, .parent = elec, .parent_access = .potential },
        .{ .name = half, .parent = elec, .parent_access = .flow },
        .{ .name = loop_a, .parent = loop_b },
        .{ .name = loop_b, .parent = loop_a },
    };
    // A potential-only discipline: `flow` is unbound.
    const disciplines = [_]DisciplineDecl{.{ .name = elec, .potential = derived }};
    f.natures = &natures;
    f.disciplines = &disciplines;
    try std.testing.expectEqual(v1, natureAttrExpr(&f, base, "abstol"));
    try std.testing.expectEqual(v3, natureAttrExpr(&f, derived, "abstol")); // the derived value wins
    try std.testing.expectEqual(v2, natureAttrExpr(&f, derived, "units")); // inherited
    try std.testing.expectEqual(v3, natureAttrExpr(&f, via, "abstol")); // elec.potential is Derived
    try std.testing.expectEqual(v2, f.natureAttrExpr(via, "units")); // and Derived's parent
    try std.testing.expectEqual(null, natureAttrExpr(&f, half, "abstol")); // elec binds no flow
    try std.testing.expectEqual(null, natureAttrExpr(&f, base, "access"));
    try std.testing.expectEqual(null, natureAttrExpr(&f, elec, "abstol")); // a discipline is no nature
    try std.testing.expectEqual(null, natureAttrExpr(&f, loop_a, "abstol")); // the hop limit ends a cycle
}

test "primTerms names every primitive terminal as VAMS §7.8.5.1 does, numbering unnamed instances per type (VD-115)" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var f: SourceFile = .empty;
    const e = struct {
        fn id(n: u32) ExprId {
            return @fromBackingInt(n);
        }
    }.id;
    // and (o, a, b); and g2 (o2, c, d); buf (x, y, i); bufif0 (q, d, en);
    // a hoisted `and` (generated, unnamed); and (p, r, s);
    const gates = [_]GateInst{
        .{ .kind = .g_and, .out = e(0), .ins = &.{ e(1), e(2) }, .main_tok = 1 },
        .{ .kind = .g_and, .out = e(3), .ins = &.{ e(4), e(5) }, .name = try f.intern(a, "g2"), .main_tok = 2 },
        .{ .kind = .g_buf, .out = e(6), .ins = &.{e(8)}, .main_tok = 3 },
        .{ .kind = .g_buf, .out = e(7), .ins = &.{e(8)}, .main_tok = 3 },
        .{ .kind = .g_bufif0, .out = e(9), .ins = &.{ e(10), e(11) }, .main_tok = 4 },
        .{ .kind = .g_and, .out = e(12), .ins = &.{e(13)}, .main_tok = 5, .generated = true },
        .{ .kind = .g_and, .out = e(14), .ins = &.{e(15)}, .main_tok = 6 },
    };
    const pulls = [_]PullInst{.{ .out = e(16), .one = true, .main_tok = 7 }};
    const switches = [_]SwitchInst{
        .{ .kind = .nmos, .terms = &.{ e(17), e(18), e(19) }, .main_tok = 8 },
        .{ .kind = .tran, .terms = &.{ e(20), e(21) }, .main_tok = 9 },
    };
    const m: ModuleDecl = .{ .name = try f.intern(a, "m"), .ports = &.{}, .gates = &gates, .pulls = &pulls, .switches = &switches };
    const Want = struct { []const u8, []const u8, Direction, u32 };
    const want = [_]Want{
        .{ "and$1", "out", .output, 0 },    .{ "and$1", "in1", .input, 1 },      .{ "and$1", "in2", .input, 2 },
        .{ "g2", "out", .output, 3 },       .{ "g2", "in1", .input, 4 },         .{ "g2", "in2", .input, 5 },
        // One buf, two output rows: `in` is listed once, on the first.
        .{ "buf$1", "out1", .output, 6 },   .{ "buf$1", "in", .input, 8 },       .{ "buf$1", "out2", .output, 7 },
        .{ "bufif0$1", "out", .output, 9 }, .{ "bufif0$1", "in", .input, 10 },   .{ "bufif0$1", "enable", .input, 11 },
        // Hoisted: its type name, not counted, so the next one is `and$2`.
        .{ "and", "out", .output, 12 },     .{ "and", "in1", .input, 13 },       .{ "and$2", "out", .output, 14 },
        .{ "and$2", "in1", .input, 15 },    .{ "pullup$1", "out", .output, 16 }, .{ "nmos$1", "source", .output, 17 },
        .{ "nmos$1", "drain", .input, 18 }, .{ "nmos$1", "gate", .input, 19 },   .{ "tran$1", "source", .inout, 20 },
        .{ "tran$1", "drain", .inout, 21 },
    };
    const got = try primTerms(a, &f, &m);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try std.testing.expectEqualStrings(w[0], g.inst);
        try std.testing.expectEqualStrings(w[1], g.port);
        try std.testing.expectEqual(w[2], g.dir);
        try std.testing.expectEqual(e(w[3]), g.expr);
    }
}

test "setPrimTerm re-points one terminal; a buf's shared input on every output row" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const e = struct {
        fn id(n: u32) ExprId {
            return @fromBackingInt(n);
        }
    }.id;
    const in = [_]ExprId{e(8)};
    var gates = [_]GateInst{
        .{ .kind = .g_buf, .out = e(6), .ins = &in, .main_tok = 3 },
        .{ .kind = .g_buf, .out = e(7), .ins = &in, .main_tok = 3 },
        .{ .kind = .g_and, .out = e(0), .ins = &.{ e(1), e(2) }, .main_tok = 4 },
    };
    var pulls = [_]PullInst{.{ .out = e(16), .one = false }};
    const terms = [_]ExprId{ e(17), e(18), e(19) };
    var switches = [_]SwitchInst{.{ .kind = .nmos, .terms = &terms }};
    const t: PrimTerm = .{ .list = .gate, .row = 0, .term = 1, .inst = "buf$1", .range = null, .port = "in", .dir = .input, .expr = e(8), .generated = false, .main_tok = 3 };
    try setPrimTerm(a, &gates, &pulls, &switches, t, 0, e(99));
    try std.testing.expectEqual(e(99), gates[0].ins[0]);
    try std.testing.expectEqual(e(99), gates[1].ins[0]);
    try std.testing.expectEqual(e(1), gates[2].ins[0]); // another instance
    try std.testing.expectEqual(e(8), in[0]); // copied, never written through
    var out = t;
    out.term = 0;
    try setPrimTerm(a, &gates, &pulls, &switches, out, 1, e(98));
    try std.testing.expectEqual(e(6), gates[0].out);
    try std.testing.expectEqual(e(98), gates[1].out);
    try setPrimTerm(a, &gates, &pulls, &switches, .{ .list = .pull, .row = 0, .term = 0, .inst = "", .range = null, .port = "out", .dir = .output, .expr = e(16), .generated = false, .main_tok = 0 }, 0, e(97));
    try std.testing.expectEqual(e(97), pulls[0].out);
    try setPrimTerm(a, &gates, &pulls, &switches, .{ .list = .switch_, .row = 0, .term = 2, .inst = "", .range = null, .port = "gate", .dir = .input, .expr = e(19), .generated = false, .main_tok = 0 }, 0, e(96));
    try std.testing.expectEqualSlices(ExprId, &.{ e(17), e(18), e(96) }, switches[0].terms);
    try std.testing.expectEqual(e(19), terms[2]);
}
