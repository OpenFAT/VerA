//! The flatten: one walk's state, and the walk's spine `run`, which turns the
//! top module and the instance tree below it into one `Ast.ModuleDecl` plus
//! the `Design` side tables. The state is split by owner: each sub-table is
//! written by the file that defines its type (`decls` and `out` are the
//! synthesized module and the published rows, appended to by the walk and
//! the clone; `res` is `resolve.zig`'s, `oocs` `ooc.zig`'s, `seg`
//! `segment.zig`'s, `tree` `walk.zig`'s, `defparams` `defparam.zig`'s,
//! `folds` `fold.zig`'s). `unit` is not a table but the namespace in force:
//! `instance.inlineInstance` replaces it and the walk restores it, and a pass
//! that clones text written in another scope swaps it and restores it.
//!
//! The spine:
//!
//!     seed the top           its own declarations, unrenamed
//!     walk.walkInstances     per level: defparams, out-of-context
//!                            declarations, connect planning, then each
//!                            instance inlined
//!     post-passes            E.3.2.2 primitive ports, F.2.1 step 4,
//!                            §3.6.3.2 nodesets, §7.8.4 E0927, §6.3.1 E0907
//!     publish `fate`         one `Ast.ModuleDecl`, plus `Design`
//!     alias.checkFlat        §3.4.7 hierarchical alias reads
//!
//! Cites: LRM §3.4.7, §5.2, §5.4.2.2, §6.2.2, §6.3.1, §6.7, §9.15, §9.18,
//! Annex E.3.2.2, Annex F.2.1.
//!
//! Contents:
//! - `pub const Unit = struct`
//! - `pub const Decls = struct`
//! - `pub const Out = struct`
//! - `pub fn genInstancesOf(self: *const Flatten, m: *const Ast.ModuleDecl) []const Ast.Instance`
//! - `pub fn err(self: *Flatten, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Error!void`
//! - `pub fn run(self: *Flatten, top: *const Ast.ModuleDecl) Error!Design`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const diag = @import("diag");
const design = @import("design.zig");
const alias = @import("alias.zig");
const connect_rule = @import("connect_rule.zig");
const defparam = @import("defparam.zig");
const discipline = @import("discipline_rules.zig");
const fold = @import("fold.zig");
const hier_param = @import("hier_param.zig");
const ooc = @import("ooc.zig");
const resolve = @import("resolve.zig");
const segment = @import("segment.zig");
const walk = @import("walk.zig");
const Design = design.Design;
const Error = design.Error;
const Flatten = @This();

ctx: design.Ctx,
/// Set by `err` and by the pre-walk checks; `run` turns it into
/// `error.DiagnosticsReported` after the walk, so one design reports every
/// error it has rather than the first.
had_error: bool = false,
/// §6.6 every module's generate-block instances (`genInstanceList`),
/// indexed like `ctx.file.modules`; read through `genInstancesOf`. Built once
/// by `elaborate`, read-only after.
gen_instances: []const []const Ast.Instance,
/// This is §7.8.4's first walk, which inserts no connect module and records
/// what it elaborated in `tree`.
dry: bool = false,

/// The synthesized module's declaration lists, in append order.
decls: Decls = .{},
/// The `Design` side tables, as the walk builds them.
out: Out = .{},
/// `fold.zig`'s cache of folded flat parameter values.
folds: fold.Cache = .{},
/// `defparam.zig`'s §6.3.1 table.
defparams: defparam.Table = .{},
/// `resolve.zig`'s Annex F.2 state: one discipline per flat net, every
/// arrival on it, and the deferred post-pass inputs.
res: resolve.State = .{},
/// `ooc.zig`'s Annex F.2.1 step 3 table.
oocs: ooc.State = .{},
/// `segment.zig`'s per-level memos.
seg: segment.State = .{},
/// §7.8.4's dry walk, recorded by `walk.zig` and read by `segment.up`.
tree: walk.Tree = .{},
/// Ports `insert.plan` bridged with nothing, judged once every net's
/// discipline is resolved (`connect_rule.checkUnbridged`, E0927).
unbridged: std.ArrayList(connect_rule.Unbridged) = .empty,
/// Source aliases in each instantiated scope, including geometry aliases that
/// cloning represents as local parameters rather than declarations, for
/// §3.4.7's hierarchical check (`alias.checkFlat`).
expression_aliases: std.ArrayList(Ast.AliasParam) = .empty,

/// The rename map in force while cloning the current unit's body, plus the
/// per-instance rewrites §9.19 and §9.18 need.
unit: Unit = .{},
/// True while `paramsetOverrides` clones text written inside a §6.4
/// paramset body, the one scope §9.13.1/§9.13.2 admit a distribution call's
/// `type_string` in. Read by `clone_expr.cloneExpr`'s sys_call arm.
in_paramset: bool = false,
/// True while cloning the branch a `<+` or an indirect assignment DRIVES.
/// §6.3.6's second automatic rule divides "the value returned by any branch
/// flow probe" by $mfactor, and a contribution's left-hand side is the
/// branch, not a probe of it.
contrib_target: bool = false,

/// Per-instance clone state: the rename map and the §9.18/§9.19 answers that
/// differ from one instance of a module to the next.
pub const Unit = struct {
    /// This instance's namespace prefix, ending in `sep` below the top.
    path: []const u8 = "",
    /// Local name → flat name for this unit's declarations and ports.
    rename: Rename = .empty,
    /// §9.19 `$port_connected`: the child's local port name → was it given
    /// an expression in the connection list. Empty for the top, whose ports
    /// the host binds.
    connected: std.AutoHashMapUnmanaged(Ast.StrId, bool) = .empty,
    /// §9.19 `$param_given`: local parameter name → was it overridden.
    given: std.AutoHashMapUnmanaged(Ast.StrId, bool) = .empty,
    /// §4.4/§5.5.3 the discipline a BOUND port was declared with in this
    /// unit, local port name → discipline. The port is the parent's net after
    /// the join, whose discipline may be another one; `access.localAccess`
    /// checks this unit's access names against this, not against that.
    port_disc: std.AutoHashMapUnmanaged(Ast.StrId, Ast.StrId) = .empty,
    /// Annex E: the unit is a shipped Table E.1 primitive, whose `V`/`I` is a
    /// nature-neutral spelling of the port pair's potential and flow.
    primitive: bool = false,
    /// §9.18 the six resolved values in the flat namespace. `.none` denotes
    /// Table 9-29's top-level identity; descendants inherit the parent's
    /// expression unless they specify a new value to combine.
    hier: hier_param.Values = .initFill(.none),
    /// §6.6 the conjunction of if-generate schemes that brings this unit into
    /// existence, in the flat namespace; `.none` when nothing does. Every
    /// analog block of the unit is lowered under it.
    gate: Ast.ExprId = .none,
    /// §6.3.1 the nearest paramset instance above or at this unit. A
    /// descendant module inherits it even when instantiated by module name.
    paramset_instance: ?[]const u8 = null,
    /// The module this unit is an instance of, and the unit that instantiated
    /// it (null at the top). IEEE 1364-2005 12.6/12.7's upward search walks
    /// them (`clone_expr.upward`). Null `module` is a scope that is not a
    /// module instance (a paramset body).
    module: ?*const Ast.ModuleDecl = null,
    up: ?*const Unit = null,
};

/// The synthesized module's declarations, in append order: the top's, then
/// every inlined instance's, renamed. Published by `fate`'s `.merged` rows.
pub const Decls = struct {
    params: std.ArrayList(Ast.ParamDecl) = .empty,
    aliasparams: std.ArrayList(Ast.AliasParam) = .empty,
    vars: std.ArrayList(Ast.VarDecl) = .empty,
    /// Appended only through `resolve.addNet`, which keeps `res.disc_of` in
    /// agreement with it.
    nets: std.ArrayList(Ast.NetDecl) = .empty,
    branches: std.ArrayList(Ast.BranchDecl) = .empty,
    genvars: std.ArrayList(Ast.StrId) = .empty,
    events: std.ArrayList(Ast.EventDecl) = .empty,
    functions: std.ArrayList(Ast.FuncDecl) = .empty,
    analog: std.ArrayList(Ast.AnalogBlock) = .empty,
    discrete: std.ArrayList(Ast.DiscreteBlock) = .empty,
    assigns: std.ArrayList(Ast.ContAssign) = .empty,
    gates: std.ArrayList(Ast.GateInst) = .empty,
    pulls: std.ArrayList(Ast.PullInst) = .empty,
    switches: std.ArrayList(Ast.SwitchInst) = .empty,
    attrs: std.ArrayList(Ast.NatureAttr) = .empty,
};

/// `Design`'s side tables as the walk appends to them; `run` hands each
/// list's `items` to `Design` without copying. Each field documents itself on
/// `Design`.
pub const Out = struct {
    /// §9.15/§9.16 one row per unit id, in issue order (so index == unit id):
    /// the top's, appended by `run`, then each inlined instance's.
    units: std.MultiArrayList(design.Unit) = .empty,
    names: std.StringHashMapUnmanaged(Ast.StrId) = .empty,
    port_disciplines: std.StringHashMapUnmanaged(Ast.StrId) = .empty,
    implicit_nets: std.ArrayList(design.NameSite) = .empty,
    unconnected_inputs: std.ArrayList(design.NameSite) = .empty,
    inserts: std.ArrayList(design.Inserted) = .empty,
    port_concats: std.ArrayList(design.PortConcat) = .empty,
    net_parts: std.ArrayList(design.NetPart) = .empty,
    port_widths: std.ArrayList(design.PortWidth) = .empty,
    signal_disciplines: std.ArrayList(design.SignalDiscipline) = .empty,
    attribute_disciplines: std.AutoHashMapUnmanaged(Ast.ExprId, Ast.StrId) = .empty,
    local_accesses: std.AutoHashMapUnmanaged(Ast.ExprId, void) = .empty,
    ps_hidden: std.ArrayList([]const u8) = .empty,
    port_vars: std.ArrayList(Ast.StrId) = .empty,
    port_ammeters: std.ArrayList(design.PortAmmeter) = .empty,
    ps_outputs: std.ArrayList(design.PsOutput) = .empty,
    paramset_defparams: std.ArrayList(design.ParamsetDefparam) = .empty,
    /// May repeat a name; readers treat it as a set.
    selection_params: std.ArrayList(Ast.StrId) = .empty,
    system_checks: std.ArrayList(design.SystemCheck) = .empty,
};

/// One name binding in the flattened namespace: what a child's local name is
/// called after the join. §6.7's path table, in the direction the clone needs.
const Rename = std.AutoHashMapUnmanaged(Ast.StrId, Ast.StrId);

/// What the flatten does with one field of `Ast.ModuleDecl`.
const Fate = enum {
    /// The device's own: the top's value, as parsed.
    top,
    /// The top's entries followed by every inlined instance's, renamed into the
    /// flat namespace. `Decls` holds a list of the same name, and `run`
    /// publishes it.
    merged,
    /// Applied by the walk and gone after it; nothing downstream reads it.
    consumed,
};

/// Every field of `Ast.ModuleDecl`, classified. `EnumFieldStruct` with no
/// default makes each entry required, so a field added to `ModuleDecl` does
/// not compile until someone decides what a child's copy of it becomes. `run`
/// builds its output from this table, so the two cannot drift.
const fate: std.enums.EnumFieldStruct(std.meta.FieldEnum(Ast.ModuleDecl), Fate, null) = .{
    .name = .top,
    .ports = .top, // §6.5 the device's terminals are the top's
    .params = .merged,
    .aliasparams = .merged,
    .vars = .merged,
    .nets = .merged,
    .branches = .merged,
    .instances = .consumed, // §6.2.2 inlined; lowering must not elaborate them again
    .defparams = .consumed, // §6.3.1 applied to the parameter each names
    .genvars = .merged,
    .events = .merged,
    .functions = .merged,
    .analog = .merged,
    // §7.2.2 the discrete context. Merged: lowering reads what the analog
    // half needs of it, and the mixed runner runs it under the flat names.
    .discrete = .merged,
    .assigns = .merged,
    // Lowering reads no gate in any module; the parser's W0252 reports each.
    // Merged anyway, so a child's gate is where a top's gate is.
    .gates = .merged,
    // §7.8 pull sources, read by the digital engine only; merged like gates.
    .pulls = .merged,
    // The digital engine elaborates its own hierarchy from the source and runs
    // every task; lowering reads the top's only (what its bodies write).
    // ponytail: a child's task writes are not digital-owned to the analog side;
    // merge them (renamed like `discrete`) when a child's task needs it.
    .tasks = .top,
    // §8.5.3.5 switches, run by the digital engine; merged like gates.
    .switches = .merged,
    // A.7 specify paths and timing checks: read only by the VPI's §11.6.15
    // model, which walks each module's own declaration, never the flattened
    // one, so the flat design keeps the top's.
    .paths = .top,
    .timing_checks = .top,
    .pulses = .top,
    .attrs = .merged,
    // `pickTop` never picks a connect module, so this is always the top's
    // `false`; a hand-placed one (§7.1) is a child like any other.
    .is_connect = .top,
    .main_tok = .top,
};

/// Returns `m`'s §6.6 generate-block instances. Asserts that `m` is a row of
/// `ctx.file.modules` (what `findModule` returns), not a copy.
pub fn genInstancesOf(self: *const Flatten, m: *const Ast.ModuleDecl) []const Ast.Instance {
    const mods = self.ctx.file.modules;
    assert(@intFromPtr(m) >= @intFromPtr(mods.ptr));
    assert(@intFromPtr(m) < @intFromPtr(mods.ptr + mods.len));
    assert(self.gen_instances.len == mods.len);
    return self.gen_instances[(@intFromPtr(m) - @intFromPtr(mods.ptr)) / @sizeOf(Ast.ModuleDecl)];
}

/// Reports `code` at `tok` and marks the flatten failed, so `run` returns
/// `error.DiagnosticsReported` once the walk ends. Asserts that `tok` is a
/// token of the source (or the 0 a synthesized row carries).
pub fn err(self: *Flatten, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Error!void {
    assert(tok == 0 or tok < self.ctx.tok_starts.len);
    self.had_error = true;
    try self.ctx.bag.add(.lower, code, Lexer.tokenSpan(self.ctx.src, self.ctx.tok_starts, tok), fmt, args);
    assert(self.had_error);
}

/// The flatten's spine (see the file header): seeds the flat namespace with
/// the top's own declarations, walks the instance tree, runs the post-walk
/// passes and publishes `Design`. Asserts that this state has not run yet.
/// Every pointer in the result points into `ctx.arena`.
pub fn run(self: *Flatten, top: *const Ast.ModuleDecl) Error!Design {
    assert(self.out.units.len == 0);
    assert(self.decls.params.items.len == 0);
    try seedTop(self, top);

    self.unit.module = top;
    var stack: std.ArrayList(Ast.StrId) = .empty;
    try stack.append(self.ctx.arena, top.name);
    try walk.walkInstances(self, top, &stack);
    // The walk puts back every unit it inlined, ending on the top's.
    assert(self.unit.module.? == top);
    assert(self.unit.up == null);

    // E.3.2.2 "If there are no continuous disciplines defined on the net
    // segment, then the discipline shall default to electrical": the
    // primitive's own declaration, on a net nothing else resolved.
    for (self.res.prim_ports.items) |pp| {
        const d = self.res.disc_of.get(pp.bound) orelse .none;
        if (d == .none or !discipline.isContinuous(self.ctx.file, d))
            try resolve.resolveDiscipline(self, pp.path, pp.port, pp.bound, null);
    }

    // Annex F.2.1 step 4's multi-candidate arm, over the segment sets the
    // walk collected. After the walk because 4.b matches the complete
    // candidate set of a signal against §7.7.2's resolution statements.
    try resolve.resolveMultiCandidates(self);
    try ooc.applyOocInits(self); // §3.6.3.2 hierarchical nodesets
    try connect_rule.checkUnbridged(self); // §7.8.4 E0927, on resolved nets

    // §5.2 analog blocks are concurrent, but §5.4.2.2's flow read is
    // ordered: `I(b)` after a flow contribution to `b` reads the retained
    // value, before one it mints an unknown. A parent reading a child's
    // branch flow through §6.7.1 must see the child's contribution, so the
    // top's own blocks go last, after every inlined child's.
    try self.decls.analog.appendSlice(self.ctx.arena, top.analog);

    try defparam.reportUnusedDefparams(self); // §6.3.1 E0907

    const out = try self.ctx.arena.create(Ast.ModuleDecl);
    const md = @typeInfo(Ast.ModuleDecl).@"struct";
    inline for (md.field_names, md.field_types, md.field_attrs) |name, F, attrs| @field(out, name) = switch (@field(fate, name)) {
        .top => @field(top, name),
        .merged => @field(self.decls, name).items,
        .consumed => comptime attrs.defaultValue(F).?,
    };

    if (self.had_error) return error.DiagnosticsReported;
    try alias.checkFlat(self.ctx, out, self.expression_aliases.items);
    return publish(self, out);
}

// ---- private ----

/// The top's own declarations go in unrenamed and uncloned: it IS the flat
/// namespace, so an identity rename would rewrite every expression in the
/// device for no change. Unit 0 is the top itself, and §9.15's example makes
/// a top-level module's instance name its module name ("testbench").
fn seedTop(self: *Flatten, top: *const Ast.ModuleDecl) Error!void {
    const a = self.ctx.arena;
    try self.decls.params.appendSlice(a, top.params);
    try fold.syncParamValues(self);
    try defparam.applyTopDefparams(self);
    try self.decls.aliasparams.appendSlice(a, top.aliasparams);
    for (top.aliasparams) |al| if (alias.original(self.ctx.file, top.params, top.aliasparams, al)) |target|
        try self.expression_aliases.append(a, .{ .alias = al.alias, .target = target });

    // A host can set a top-level geometry alias through the model card.
    // Retain that parameter read in every descendant's composition. The
    // mfactor host field has its own automatic scaling convention.
    for (top.aliasparams) |al| {
        const kind = hier_param.Kind.fromName(self.ctx.file.str(al.target)) orelse continue;
        const card = try self.ctx.file.exprs.add(a, .{ .tag = .ident, .main_tok = top.main_tok, .str = al.alias });
        // The card value is the top's own system parameter: Table 9-29
        // constrains it as much as an instance override.
        if (kind.constrained()) try self.out.system_checks.append(a, .{
            .kind = kind,
            .value = card,
            .name = self.ctx.file.str(al.alias),
        });
        if (kind == .mfactor or self.unit.hier.get(kind) != .none) continue;
        self.unit.hier.set(kind, card);
    }
    try self.decls.vars.appendSlice(a, top.vars);
    for (top.ports) |p| try resolve.noteDiscipline(self, p.name, p.discipline);
    try resolve.addNets(self, top.nets);
    try self.decls.branches.appendSlice(a, top.branches);
    try self.decls.genvars.appendSlice(a, top.genvars);
    try self.decls.events.appendSlice(a, top.events);
    try self.decls.functions.appendSlice(a, top.functions);
    try self.decls.attrs.appendSlice(a, top.attrs);
    try self.decls.discrete.appendSlice(a, top.discrete);
    try self.decls.assigns.appendSlice(a, top.assigns);
    try self.decls.gates.appendSlice(a, top.gates);
    try self.decls.pulls.appendSlice(a, top.pulls);
    try self.decls.switches.appendSlice(a, top.switches);
    try self.out.units.append(a, .{ .module = top.name, .path = "", .decl = .of(self.ctx.file, top) });
    assert(self.out.units.len == 1);
    assert(self.decls.params.items.len >= top.params.len);
}

/// `Design` over the walk's tables, without copying a list.
fn publish(self: *Flatten, out: *const Ast.ModuleDecl) Design {
    // `Design.units[i]` is unit i: the top, then one row per instance.
    assert(self.out.units.len != 0);
    assert(self.out.units.items(.path)[0].len == 0);
    const o = &self.out;
    return .{
        .top = out,
        .names = o.names,
        .port_disciplines = o.port_disciplines,
        .implicit_nets = o.implicit_nets.items,
        .unconnected_inputs = o.unconnected_inputs.items,
        .units = o.units.slice(),
        .inserts = o.inserts.items,
        .port_concats = o.port_concats.items,
        .net_parts = o.net_parts.items,
        .port_widths = o.port_widths.items,
        .signal_disciplines = o.signal_disciplines.items,
        .attribute_disciplines = o.attribute_disciplines,
        .local_accesses = o.local_accesses,
        .ps_hidden = o.ps_hidden.items,
        .port_vars = o.port_vars.items,
        .ps_outputs = o.ps_outputs.items,
        .port_ammeters = o.port_ammeters.items,
        .paramset_defparams = o.paramset_defparams.items,
        .selection_params = o.selection_params.items,
        .system_checks = o.system_checks.items,
    };
}
