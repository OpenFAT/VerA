//! The design-element rows of the AST other than modules: natures and
//! disciplines (§3.6), attribute instances and their owners (§2.9),
//! paramsets (§6.4), connect rules (§7.7), and IEEE 1364-2005 library cells
//! and configurations (§13); and the walk `natureAttrExpr` (§3.6.1.1,
//! §3.6.2.6). In: what the parser recognises. Out: rows read by
//! elaboration and lowering.
//! Cites: LRM §2.9, §3.6, §3.6.1.1, §3.6.2.3, §3.6.2.6, §6.4, §7.7; IEEE
//! 1364-2005 §13.2, §13.3.
//!
//! Contents:
//! - `pub const NatureAttr = struct`
//! - `pub const AttributeOwner = struct`
//! - `pub const AttributeBinding = struct`
//! - `pub const LteAttr = struct`
//! - `pub const NatureDecl = struct`
//! - `pub const DisciplineDecl = struct`: `Domain`, `Override`
//! - `pub const ParamsetDecl = struct`
//! - `pub const ParamsetOverride = struct`: `Kind`
//! - `pub const ConnectRulesDecl = struct`
//! - `pub const ConnectInsertion = struct`: `Mode`, `PortOverrides`
//! - `pub const ConnectResolution = struct`
//! - `pub const LibCell = struct`
//! - `pub const ConfigRule = struct`
//! - `pub const ConfigDecl = struct`
//! - `pub fn natureAttrExpr(self: *const SourceFile, name: StrId, attr: []const u8) ?ExprId`

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const ExprId = ast.ExprId;
const StmtId = ast.StmtId;
const StrId = ast.StrId;
const Type = ast.Type;
const PotentialOrFlow = ast.PotentialOrFlow;
const SourceFile = ast.SourceFile;
const ParamDecl = ast.ParamDecl;
const AliasParam = ast.AliasParam;
const VarDecl = ast.VarDecl;
const ParamOverride = ast.ParamOverride;
const Direction = ast.Direction;
const testing = std.testing;

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
    assert(attr.len > 0);
    if (name == .none) return null;
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

// ---- private ----

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
