//! §3.6 disciplines on nodes: the declared nets in, each `nodes` row's
//! discipline out, with §10.2's `default_discipline` applied, the §3.6.2
//! primitive-terminal checks, IEEE 1364 §19.2's `default_nettype none` and
//! §19.9's unconnected-input drive.
//!
//! Cites: §1.3.4, §1.3.4.1, §1.3.4.2, §3.6.2.1, §3.6.2.2, §3.6.3, §3.6.3.2,
//! §3.6.5, §3.9, §5.6.1.3, §6.2.2, §6.5.2, §7.4, §7.4.4, §10.2, §19.2, §19.9;
//! IEEE 1364-2005 §19.2, §19.9.
//!
//! Contents:
//! - `pub fn resolveDisciplines(self: *Lower, module: *const Ast.ModuleDecl) Oom!void`
//! - `pub fn strOrEmpty(self: *const Lower, id: Ast.StrId) []const u8`
//! - `pub fn isSignalFlow(self: *const Lower, dname: []const u8) bool`
//! - `pub fn rejectImplicitNet(self: *Lower, name: []const u8, main_tok: u32) Oom!void`
//! - `pub fn applyUnconnectedDrive(self: *Lower) Oom!void`

const std = @import("std");
const assert = std.debug.assert;
const discipline_rules = @import("elab").discipline_rules;
const Ast = @import("frontend").Ast;
const directive_events = @import("frontend").directive_events;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_discipline = @import("discipline.zig");
const lower_shape = @import("shape.zig");
const lower_branch = @import("branch.zig");
const lower_accum = @import("accum.zig");
const lower_node_ref = @import("node_ref.zig");
const Oom = Lower.Oom;
const ground = Lower.ground;

/// §7.4 resolution, as far as VerA implements it: §10.2's default discipline
/// on every port and net, after every declaration is interned. Then the rules
/// that need a net's final discipline: §3.9 primitive terminals, §1.3.4's
/// `inout` ban on signal-flow ports (E0360) and §3.6.3.2's ban on a discrete
/// net's nodeset (E0366).
pub fn resolveDisciplines(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(module.name != .none);
    // §7.4 discipline resolution, the one rule of it VerA implements: §10.2's
    // default. It runs here, after every declaration has been interned: a port
    // and a body declaration of the same net are two entries
    // (`module (p); inout p; electrical p;`), and a default written at the
    // first would make the second a §7.4.4 second declaration (E0902).
    //
    // A vector is scalarised by now, so the default is applied to the
    // elements: `p` itself is not a node.
    //
    // §10.2 picks the default by the signal's net type, which the parser
    // folds into a port from its body declaration (`inout q; tri q;`).
    for (module.ports) |p| try applyDefaultToAll(self, self.file.str(p.name), p.main_tok, qualifierOf(p.kind));
    for (module.nets) |n| if (!self.out.discrete_inputs.contains(self.file.str(n.name)))
        try applyDefaultToAll(self, self.file.str(n.name), n.main_tok, qualifierOf(n.kind));
    // §3.9 a digital primitive on a continuous net needs the default the loops
    // above just applied — after them, so a net it made discrete is not mixed.
    try checkPrimitiveDisciplines(self, module);

    // §1.3.4.1 "Nets of potential signal flow disciplines in modules may only
    // be bound to `input` or `output` ports of the module, not to `inout`
    // ports"; §1.3.4.2 says the same of flow signal-flow disciplines. The
    // sibling of E0425, which rules on the contribution target rather than the
    // declaration.
    //
    // Here and not in the port loop, because only now is the discipline known:
    // `inout p; voltage p;` splits direction and discipline across two
    // declarations, and §10.2's default arrives in the `applyDefaultToAll`
    // loops above.
    //
    // `.unspecified` is deliberately not caught: §6.5.2 leaves a port with no
    // direction declaration to §3.9, and the clause names `inout` only.
    for (module.ports) |p| {
        if (p.direction != .inout) continue;
        const base = self.file.str(p.name);
        // A vector port is N nets sharing one declaration and therefore one
        // discipline (§6.5.2), so the first element answers for all of them and
        // the violation is reported once, at the declaration that commits it.
        var key_buf: [lower_shape.elem_key_len]u8 = undefined;
        const probe_name = if (self.out.vectors.get(base)) |r| try lower_shape.elemKey(self, &key_buf, base, &.{r.at(0)}) else base;
        const idx = self.node_voltages.get(probe_name) orelse continue;
        if (idx == ground) continue;
        const dname = self.out.nodes.items(.disc)[idx];
        if (!isSignalFlow(self, dname)) continue;
        var b = self.errWith(p.main_tok, .E0360);
        b.msg("`{s}` is an `inout` port of discipline `{s}`, which binds a {s} nature only", .{
            base, dname, if (self.out.disciplines.get(dname).?.has_potential) "potential" else "flow",
        });
        b.help("declare `{s}` as `input` or `output`", .{base});
        try b.emit();
    }

    // §3.6.3.2: "Nets with continuous disciplines are allowed to have
    // initializers on their net discipline declarations; however, nets of
    // non-continuous disciplines are not."
    //
    // Here for the same reason E0360 is here and not at the declaration: a net
    // and its discipline can arrive in two declarations, and §10.2's default
    // arrives in the `applyDefaultToAll` loops above. A net that still has no
    // discipline at this point is left alone — it is §3.6.5's implicit net,
    // whose domain is decided by resolution (§7.4) and not by this module, and
    // E0337 already rules on it if anything analog touches it.
    for (self.out.nodesets.items) |ns| {
        const dname = self.out.nodes.items(.disc)[ns.node];
        const info = self.out.disciplines.get(dname) orelse continue;
        if (!info.is_discrete) continue;
        var b = self.errWith(ns.tok, .E0366);
        b.msg("`{s}` is of discipline `{s}`, whose domain is discrete", .{ self.out.nodes.items(.name)[ns.node], dname });
        b.note("a nodeset is an initial guess for a POTENTIAL, and §3.6.2.2 leaves a discrete discipline with no nature to have one", .{});
        try b.emit();
    }
}

/// The declared discipline's spelling, `""` for none (§3.6.5, §3.9).
pub fn strOrEmpty(self: *const Lower, id: Ast.StrId) []const u8 {
    return if (id == .none) "" else self.file.str(id);
}

/// Reports whether `dname` is a §1.3.4 signal-flow discipline: exactly one of its
/// two natures is bound. A discipline binding both is conservative (§3.6.2.1); one
/// binding neither (natureless continuous, or discrete) is not signal-flow either.
pub fn isSignalFlow(self: *const Lower, dname: []const u8) bool {
    if (dname.len == 0) return false;
    const d = self.out.disciplines.get(dname) orelse return false;
    return d.has_potential != d.has_flow;
}

/// Reports an error when IEEE 1364 §19.2 `` `default_nettype none `` is in force at
/// `main_tok`, on a name about to become a §3.6.5 implicit net. Other net types are
/// a no-op: VerA's analog nets have a discipline, not a net type.
///
/// ponytail: the other ten values are accepted and dropped; they differ only in
/// how multiple drivers resolve, which VerA does not model. Upgrade: a discrete
/// net type on `Ast.NetDecl`.
pub fn rejectImplicitNet(self: *Lower, name: []const u8, main_tok: u32) Oom!void {
    assert(main_tok < self.tok_starts.len or self.tok_starts.len == 0 or main_tok == std.math.maxInt(u32));
    if (directive_events.NetTypeRegion.inForce(self.opts.directives.nettypes, self.tokStart(main_tok), .default) != .none) return;
    var b = self.errWith(main_tok, .E0367);
    b.msg("`{s}` was never declared, and `default_nettype none is in force", .{name});
    b.note("§3.6.5 would make it an implicit net; IEEE 1364 §19.2's `none` is what withdraws that", .{});
    b.help("declare it — `electrical {s};` — or go back to `default_nettype wire", .{name});
    try b.emit();
}

/// Applies IEEE 1364 §19.9 `unconnected_drive to the internal nets §6.2.2 gave
/// unconnected `input` ports: `pull0` holds the port at potential 0 and `pull1` at 1,
/// in its discipline's potential units, through a potential source. Must run after
/// the declarations are interned and before the analog blocks lower. Skips a net
/// whose discipline binds no potential.
///
/// ponytail: 1.0 stands in for §19.9's Pu1 strength; the upgrade is discrete net
/// resolution, where a pull is a driver rather than a potential.
pub fn applyUnconnectedDrive(self: *Lower) Oom!void {
    assert(self.blockValid(self.cur));
    if (self.opts.directives.drives.len == 0) return;
    for (self.design.unconnected_inputs) |site| {
        const drive = directive_events.DriveRegion.inForce(self.opts.directives.drives, self.tokStart(site.main_tok), .default);
        if (drive == .float) continue;
        const idx = self.node_voltages.get(site.name) orelse continue;
        if (idx == ground) continue;
        const info = self.out.disciplines.get(self.out.nodes.items(.disc)[idx]) orelse continue;
        if (!info.has_potential) continue;
        const target: lower_branch.Target = .{ .access = .potential, .hi = idx, .lo = ground };
        const acc = self.accum.items[try lower_accum.contribIndex(self, target, site.main_tok)];
        const old = try self.builder.readVariable(acc.resist, self.cur);
        const level: Mir.Value = if (drive == .pull1) .f_one else .f_zero;
        try self.builder.writeVariable(acc.resist, self.cur, try self.emit(.fadd, &.{ old, level }));
        // §5.6.1.3: retained on every path, like an unconditional `<+`.
        try self.builder.writeVariable(acc.wrote, self.cur, .f_one);
    }
}

// ---- private ----

/// Applies the `default_discipline in force at `main_tok` for a `q` signal to
/// net `name`, or to each scalarised element when it is a §3.6.3 vector (LRM §10.2).
fn applyDefaultToAll(self: *Lower, name: []const u8, main_tok: u32, q: ?directive_events.Qualifier) Oom!void {
    assert(main_tok < self.tok_starts.len or self.tok_starts.len == 0 or main_tok == std.math.maxInt(u32));
    const r = self.out.vectors.get(name) orelse
        return applyDefaultDiscipline(self, try lower_node_ref.netKey(self, name, main_tok), main_tok, q);
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    for (0..r.size()) |k|
        try applyDefaultDiscipline(self, try lower_shape.elemKey(self, &key_buf, name, &.{r.at(@intCast(k))}), main_tok, q);
}

/// §10.2 the Syntax 10-1 `qualifier` a net of type `kind` answers to. Null for
/// `uwire`, which the list lacks, so only an unqualified default applies.
fn qualifierOf(kind: Ast.NetKind) ?directive_events.Qualifier {
    return std.meta.stringToEnum(directive_events.Qualifier, @tagName(kind));
}

/// §10.2: "The default discipline is applied ... to all discrete signals without a
/// discipline declaration that appear in the text stream following the use of the
/// `default_discipline directive." So only a net that still has none, and only a
/// directive preceding its declaration, qualified for its type `q` or unqualified.
fn applyDefaultDiscipline(self: *Lower, name: []const u8, main_tok: u32, q: ?directive_events.Qualifier) Oom!void {
    assert(main_tok < self.tok_starts.len or self.tok_starts.len == 0 or main_tok == std.math.maxInt(u32));
    if (self.opts.directives.disciplines.len == 0) return;
    const idx = self.node_voltages.get(name) orelse return;
    if (idx == ground) return;
    if (self.out.nodes.items(.disc)[idx].len != 0) return;
    const dname = defaultDisciplineAt(self, main_tok, q) orelse return;
    // A default naming a discipline that was never declared supplies no
    // nature, so the net stays bare and E0337 reports it.
    if (!self.out.disciplines.contains(dname)) return;
    self.out.nodes.items(.disc)[idx] = dname;
}

/// §10.2 the `default_discipline in force for a `q` signal at token `main_tok`, or null.
fn defaultDisciplineAt(self: *const Lower, main_tok: u32, q: ?directive_events.Qualifier) ?[]const u8 {
    assert(main_tok < self.tok_starts.len or self.tok_starts.len == 0 or main_tok == std.math.maxInt(u32));
    if (main_tok >= self.tok_starts.len) return null;
    return directive_events.DefaultDiscipline.inForce(self.opts.directives.disciplines, self.tok_starts[main_tok], q);
}

/// §3.9 "For digital primitives the domain is discrete and thus the discipline
/// is set via the default_discipline directive as it is for digital modules.
/// If the discipline of digital connections (vpiLoConn) to a mixed net are
/// unknown then the default_discipline must be specified (via the directive or
/// other vendor specific method). If not specified, an error will result
/// during discipline resolution." Reports E0960.
///
/// Every gate, pull source or switch terminal is such a digital connection, and
/// its net is mixed when the net's own discipline is continuous. VerA has no
/// vendor-specific method, so only the directive in force at the primitive can
/// supply the connection's discipline. Must run after `applyDefaultToAll`.
fn checkPrimitiveDisciplines(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(module.name != .none);
    for (module.gates) |g| {
        try checkPrimitiveTerminal(self, g.out, g.main_tok, "gate");
        for (g.ins) |t| try checkPrimitiveTerminal(self, t, g.main_tok, "gate");
    }
    for (module.pulls) |p| try checkPrimitiveTerminal(self, p.out, p.main_tok, "pull source");
    for (module.switches) |sw| for (sw.terms) |t| try checkPrimitiveTerminal(self, t, sw.main_tok, "switch");
}

fn checkPrimitiveTerminal(self: *Lower, term: Ast.ExprId, prim_tok: u32, what: []const u8) Oom!void {
    assert(term == .none or self.exprValid(term));
    const ex = &self.file.exprs;
    const base = self.file.lvalueBase(term);
    if (base == .none or ex.tag(base) != .ident) return;
    if (defaultDisciplineAt(self, prim_tok, .wire) != null) return;
    const name = self.file.str(ex.strOf(base));
    // A vector is scalarised by now and its elements share one discipline
    // (§3.6.3), so the first element answers for the whole net.
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    const key = if (self.out.vectors.get(name)) |r| try lower_shape.elemKey(self, &key_buf, name, &.{r.at(0)}) else name;
    const idx = self.node_voltages.get(key) orelse return;
    if (idx == ground) return;
    const dname = self.out.nodes.items(.disc)[idx];
    const decl = lower_discipline.disciplineDecl(self, dname) orelse return;
    if (discipline_rules.domainOf(decl) != .continuous) return;
    var b = self.errWith(ex.mainTok(base), .E0960);
    b.msg("`{s}` is of continuous discipline `{s}` and a terminal of a digital {s}", .{ name, dname, what });
    b.note("the primitive's side of the net is discrete, so the net is mixed, and no `default_discipline is in force to name that side's discipline", .{});
    b.help("put `default_discipline logic (or another discrete discipline) before the primitive", .{});
    try b.emit();
}
