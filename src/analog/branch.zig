//! §4.4.1 branch resolution: an access-function call in, its `Target`
//! (access, canonical node pair, branch, owning instance) out, or a
//! diagnostic when the name, the nets or the discipline do not fit.
//!
//! Cites: §1.3.1.1, §1.3.1.2, §1.3.4, §3.6.1.2, §3.6.2, §3.6.2.3, §3.6.2.4,
//! §3.6.3, §3.6.5, §3.11, §3.12, §3.12.1, §4.4, §4.4.1, §4.5.6, §5.4.1,
//! §5.4.3, §5.5.1, §5.5.5, §5.6.7.2, §5.6.8.1, §5.6.8.2, §6.5.2.1, §6.6.2,
//! §6.7.1.
//!
//! Contents:
//! - `pub const Target = struct`
//! - `pub fn portBranchOf(self: *Lower, e: Ast.ExprId) Oom!?u32`
//! - `pub fn branchOf(self: *Lower, e: Ast.ExprId) Oom!?Target`
//! - `pub fn accessOn(self: *Lower, e: Ast.ExprId, name: []const u8, global: Access, hi: u32, lo: u32) Oom!Access`
//! - `pub const generic_potential = "potential"`
//! - `pub const generic_flow = "flow"`
//! - `pub fn checkAccessMatch(self: *Lower, e: Ast.ExprId, name: []const u8, access: Access, node: u32) Oom!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Elaborate = @import("elab").Elaborate;
const diag = @import("diag");
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_discipline = @import("discipline.zig");
const lower_node = @import("node.zig");
const lower_shape = @import("shape.zig");
const lower_expr_name = @import("expr_name.zig");
const Oom = Lower.Oom;
const unnamed_branch = Lower.unnamed_branch;
const ground = Lower.ground;
const Access = Lower.Access;

/// A resolved access. `hi`/`lo` are in CANONICAL order (`hi < lo` as `nodes`
/// indices, which puts `ground` — above every row — last, so `V(n)` is untouched);
/// `neg` says the source wrote the terminals the other way round.
///
/// §1.3.1.2 associated reference directions: "A positive flow enters a branch
/// through the port marked with the plus sign and exits the branch through the
/// port marked with the minus sign." So `a,b` and `b,a` are ONE branch named
/// twice, and its two spellings differ by a sign — for the flow and for the
/// potential alike.
///
/// Canonicalising here means `flowUnknown` mints one unknown per branch,
/// `contribIndex` accumulates both spellings into one source, and codegen
/// (which rebuilds the `flow(a,b)` name from `hi`/`lo`) sees one spelling.
pub const Target = struct {
    access: Access,
    hi: u32,
    lo: u32,
    neg: bool = false,
    /// §5.4.1 the branch this reference names — a `BranchInfo.id` for a declared
    /// name, `unnamed_branch` for the pair's one implicit branch. Carried beside
    /// the pair rather than instead of it: the pair is what codegen stamps and
    /// what §5.6.7.2's "or any of its parallel branches" is stated over.
    br: u32 = unnamed_branch,
    /// §5.4.1/§5.6.8.1: an unnamed branch belongs to the module instance it
    /// is written in ("a new unnamed branch is created in the module
    /// containing the direct contribution statements"), so two instances
    /// across one flattened node pair hold two branches. The instance
    /// (`Ast.AnalogBlock.unit`) whose branch this is; for a named branch,
    /// whose `br` is already per instance, the writer.
    unit: u32 = 0,

    comptime {
        assert(@sizeOf(Target) == 20); // by value through every `<+`
    }
};

/// §5.5.1 Syntax 5-3's generic potential access name. The generic pair is the
/// only access names not read from a §3.6.1.2 `access =` attribute.
pub const generic_potential = "potential";

/// §5.5.1 Syntax 5-3's generic flow access name.
pub const generic_flow = "flow";

/// The port a §3.12.1 port branch names, when the single argument of an access
/// function is one. `null` for everything else, including a two-argument
/// access — a port branch is a name, never a pair.
pub fn portBranchOf(self: *Lower, e: Ast.ExprId) Oom!?u32 {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.tag(e) == .branch_access);
    if (self.file.exprs.rhs(e) != .none) return null;
    var key_buf: [lower_shape.elem_key_len]u8 = undefined;
    const key = try branchKey(self, &key_buf, self.file.exprs.lhs(e)) orelse return null;
    return self.port_branches.get(key);
}

/// Resolves `V(a)`, `V(a,b)`, `I(br)` to (access, node pair), or null after
/// reporting why it cannot (LRM §4.4.1).
pub fn branchOf(self: *Lower, e: Ast.ExprId) Oom!?Target {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.tag(e) == .branch_access);
    const ex = &self.file.exprs;
    const name = self.file.str(ex.strOf(e));
    const global = self.access_kind.get(name) orelse {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}`", .{name});
        if (diag.didYouMeanMap(name, self.access_kind)) |s|
            b.suggestHere(s);
        try b.emit();
        return null;
    };
    // §5.5.1's measure1 note: "V cannot be used as an access function because
    // there is a parameter called V declared in the module." A module-scope
    // name hides the access-function name, and a value cannot be called.
    if (self.vars.contains(name) or self.param_index.contains(name) or self.consts.contains(name)) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}` is not an access function here: this module declares `{s}`, which hides it (§5.5.1)", .{ name, name });
        b.help("use the generic spelling, `{s}(...)`", .{if (global == .potential) generic_potential else generic_flow});
        try b.emit();
        return null;
    }
    // §5.4.3 "The port access function shall not be used on the left side of a
    // contribution operator <+", and §3.12.1 makes a named port branch the same
    // function under another name. `lowerBranchAccess` handles the read path, so
    // everything arriving here is an lvalue or an indirect-assignment probe.
    // ponytail: `ddx(f, I(pb))` also lands here and gets this message, which
    // names the wrong position; the fix is §4.5.6 deciding whether a port flow
    // is a valid derivative unknown at all.
    if (try portBranchOf(self, e)) |_| {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0407);
        b.msg("`{s}` is a port branch (3.12.1)", .{self.file.str(ex.strOf(ex.lhs(e)))});
        b.help("contribute to the branch instead: `I(p, gnd) <+ ...`", .{});
        try b.emit();
        return null;
    }
    const first = ex.lhs(e);
    // §3.12 a single argument naming a declared branch — `br`, or `br[k]` for
    // an element of a vector branch, which `declareVectorBranch` registered
    // under exactly that scalarised name. The miss falls through to `nodeOf`,
    // which owns every diagnostic about a bad index.
    if (ex.rhs(e) == .none) {
        var key_buf: [lower_shape.elem_key_len]u8 = undefined;
        if (try branchKey(self, &key_buf, first)) |key| {
            if (self.branches.get(key)) |b| {
                const access = try accessOn(self, e, name, global, b.hi, b.lo);
                try checkAccessMatch(self, e, name, access, b.hi);
                return canonical(access, b.hi, b.lo, b.id, self.cur_unit);
            }
        }
    }
    const hi = try lower_node.nodeOf(self, first);
    const lo = if (ex.rhs(e) == .none) ground else try lower_node.nodeOf(self, ex.rhs(e));
    const access = try accessOn(self, e, name, global, hi, lo);
    try checkAccessMatch(self, e, name, access, hi);
    // §3.11's own example of the rule: "if an access function has two nets as
    // arguments, they must be compatible".
    try lower_discipline.checkNetCompat(self, ex.mainTok(e), hi, lo);
    // §4.4 Table 4-16 gives both `V(n1,n1)` and `I(n1,n1)` as `Error`, and the
    // prose under it is normative for the flow half: "If two net expressions
    // are given as arguments to a flow access function, they shall not evaluate
    // to the same signal." (Annex G Table G.1: `I(a,a)` was the OVI v1.0 port
    // flow, replaced by `I(<a>)`.) Only the two-argument form: `V(gnd)` stays
    // legal.
    //
    // Ground is exempt as a pair: §1.3.1.1 collapses every `ground` net onto one
    // node, so `V(g1, g2)` over two declared grounds names two signals and reads 0.
    // ponytail: that also lets the literal `V(g1, g1)` through; catching it needs
    // a name comparison the interned index has already thrown away.
    if (ex.rhs(e) != .none and hi == lo and hi != ground) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0315);
        b.msg("`{s}({s}, {s})` names one signal twice", .{ name, lower_node.nodeName(self, hi), lower_node.nodeName(self, lo) });
        if (access == .flow)
            b.help("the flow into a port is `{s}(<{s}>)` (5.4.3)", .{ name, lower_node.nodeName(self, hi) });
        try b.emit();
        return null;
    }
    return canonical(access, hi, lo, unnamed_branch, try ownerUnit(self, e));
}

/// The half `name` reads on the net (`hi`, or `lo` when `hi` is ground).
/// §3.6.1.2 makes an access name its nature's, and §3.6.2 lets two disciplines
/// bind one nature to different halves (`electrical`'s flow `Current`, a
/// signal-flow `discipline current; potential Current;`), so for a name in
/// `access_both` the net's discipline decides; the global map's answer would
/// depend on declaration order. `global` is that answer for every other name.
pub fn accessOn(self: *Lower, e: Ast.ExprId, name: []const u8, global: Access, hi: u32, lo: u32) Oom!Access {
    assert(e == .none or self.exprValid(e));
    assert(self.nodeValid(hi));
    assert(self.nodeValid(lo));
    if (!self.access_both.contains(name)) return global;
    const node = if (hi == ground) lo else hi;
    if (node == ground) return global;
    const dname = (try portDiscipline(self, e)) orelse self.out.nodes.items(.disc)[node];
    const info = self.out.disciplines.get(dname) orelse return global;
    if (std.mem.eql(u8, info.potential_access, name)) return .potential;
    if (std.mem.eql(u8, info.flow_access, name)) return .flow;
    return global;
}

/// §4.4: "The access function name shall match the discipline declaration for
/// the nets, ports, or branch given in the argument expression list."
///
/// `access_kind` is the global set of access names, so the node's discipline
/// decides. Reports one of:
///  - E0337: no discipline. §3.6.5 makes the implicit net legal as a
///    declaration; §3.6.3 and §6.5.2.1 forbid it in analog behaviour.
///  - E0501 with no suggestion: the discipline binds no nature for this half
///    (natureless, or `I` on a signal-flow `voltage`; §1.3.4).
///  - E0501 with a suggestion: the §3.6.1.2 name mismatch.
pub fn checkAccessMatch(self: *Lower, e: Ast.ExprId, name: []const u8, access: Access, node: u32) Oom!void {
    assert(e == .none or self.exprValid(e));
    assert(self.nodeValid(node));
    if (node == ground or self.design.local_accesses.contains(e)) return;
    const dname = (try portDiscipline(self, e)) orelse self.out.nodes.items(.disc)[node];
    if (dname.len == 0) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0337);
        b.msg("`{s}` has no discipline, so `{s}` names nothing on it", .{ lower_node.nodeName(self, node), name });
        b.note("§3.6.2.4 treats a net with no discipline that is referenced in behavioral code as discrete; declare one, e.g. `electrical {s};`", .{lower_node.nodeName(self, node)});
        try b.emit();
        return;
    }
    const info = self.out.disciplines.get(dname) orelse return;
    const want = switch (access) {
        .potential => info.potential_access,
        .flow => info.flow_access,
    };
    const half = if (access == .potential) "potential" else "flow";
    if (want.len == 0) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
        b.msg("`{s}` is not an access function of `{s}`", .{ name, lower_node.nodeName(self, node) });
        b.note("`{s}` is of discipline `{s}`, which binds no {s} nature, so `{s}` has no {s} to access", .{
            lower_node.nodeName(self, node), dname, half, lower_node.nodeName(self, node), half,
        });
        try b.emit();
        return;
    }
    if (std.mem.eql(u8, want, name)) return;
    // §4.4: "As an alternative to using the access attribute specified in the
    // discipline, the generic potential and flow access functions are also
    // supported." So `potential`/`flow` skip only the name match; the checks
    // above still apply, since the generic spelling also reaches a nature.
    if (std.mem.eql(u8, name, generic_potential) or std.mem.eql(u8, name, generic_flow)) return;
    var b = self.errWith(self.file.exprs.mainTok(e), .E0501);
    b.msg("`{s}` is not an access function of `{s}`", .{ name, lower_node.nodeName(self, node) });
    b.suggestHere(want);
    b.note("`{s}` is of discipline `{s}`, whose {s} nature declares `access = {s}`", .{
        lower_node.nodeName(self, node),
        dname,
        half,
        want,
    });
    try b.emit();
}

// ---- private ----

/// The key a branch reference has in `branches`: `br` for a scalar branch,
/// `br[k]` for one element of a §3.12 vector branch. `null` when the
/// expression cannot name a branch at all (a two-terminal access, a
/// non-constant index), which is not an error here — `nodeOf` reads the same
/// expression as a net reference and reports whatever is wrong with it.
fn branchKey(self: *Lower, buf: *[lower_shape.elem_key_len]u8, e: Ast.ExprId) Oom!?[]const u8 {
    assert(e == .none or self.exprValid(e));
    assert(buf.len == lower_shape.elem_key_len);
    const ex = &self.file.exprs;
    return switch (ex.tag(e)) {
        .ident => self.file.str(ex.strOf(e)),
        // §5.5.5 "A module is allowed to access the potential and flow of a
        // branch in another module instance" (§6.7.1). Elaboration cloned the
        // child's BranchDecl under `path.name`, so the flat name is the key
        // `branches`/`port_branches` already hold. A miss falls through to
        // `nodeOf`, whose `.hier_ident` arm owns E0901. Arena rather than `buf`:
        // cold, one path per source reference.
        // §6.6.2: into an unnamed generate block, `nodeOf` refuses it (E0998).
        .hier_ident => if (try lower_expr_name.unnamedGenScope(self, e) != null) null else try lower_expr_name.flatName(self, e),
        // Into the caller's buffer, not the arena: both consumers only call
        // `branches.get`/`port_branches.get`, which never retain a key, and this
        // runs once per §4.4.1 access.
        .index => blk: {
            const base = ex.lhs(e);
            if (ex.tag(base) != .ident) break :blk null;
            const i = lower_constfold.constEval(self, ex.rhs(e)) orelse break :blk null;
            break :blk try lower_shape.elemKey(self, buf, self.file.str(ex.strOf(base)), &.{i.asInt()});
        },
        else => null, // else: names no branch; `nodeOf` reads it as a net reference and reports it
    };
}

fn canonical(access: Access, hi: u32, lo: u32, br: u32, unit: u32) Target {
    assert(access == .potential or access == .flow);
    const t: Target = if (hi <= lo)
        .{ .access = access, .hi = hi, .lo = lo, .br = br, .unit = unit }
    else
        .{ .access = access, .hi = lo, .lo = hi, .neg = true, .br = br, .unit = unit };
    assert(t.hi <= t.lo);
    return t;
}

/// The instance whose unnamed branch an access names. §5.6.8.2's
/// `drv.branch(x, y)` names `drv`'s own branch: the unit whose path is the
/// reference's instance prefix. Anything else is the writer's (`cur_unit`),
/// including §5.6.8.1's hierarchical NET spelling `I(drv.x, drv.y)`, which
/// names a branch of the writer between those nets and so reads the pair's
/// whole row (`annex_e_spice/primitive_segment_discipline.va`).
fn ownerUnit(self: *Lower, e: Ast.ExprId) Oom!u32 {
    assert(e == .none or self.exprValid(e));
    assert(self.file.exprs.tag(e) == .branch_access);
    const ex = &self.file.exprs;
    if (ex.extraOf(e) != Ast.branch_ref_hier_unnamed) return self.cur_unit;
    for ([_]Ast.ExprId{ ex.lhs(e), ex.rhs(e) }) |t| {
        if (t == .none or ex.tag(t) != .hier_ident) continue;
        assert(self.design.units.len != 0); // `inst.branch(...)` reaches a child, so a tree of more than one
        const path = try Elaborate.flatReference(self.file, self.arena, self.module, t);
        const cut = std.mem.findScalarLast(u8, path, Elaborate.sep) orelse continue;
        for (self.design.units, 0..) |u, i| {
            if (std.mem.eql(u8, u.path, path[0 .. cut + 1])) return @intCast(i);
        }
    }
    return self.cur_unit;
}

/// §4.4 "the discipline declaration for the nets, ports, or branch given in
/// the argument expression list": a hierarchical terminal naming a connected
/// child port (`V(u.b)`) names that port, so the child's declaration judges
/// the access, not the joined node's discipline (§3.6.2.3's domainless net
/// takes its domain from the ports connected to it). Null for any other access.
///
/// ponytail: the path is read without `flatName`'s generate-scope search, so
/// a `u.b` written inside a generate block keeps the node's discipline.
fn portDiscipline(self: *Lower, e: Ast.ExprId) Oom!?[]const u8 {
    assert(e == .none or self.exprValid(e));
    assert(self.module != null);
    const ex = &self.file.exprs;
    if (ex.tag(e) != .branch_access or ex.tag(ex.lhs(e)) != .hier_ident) return null;
    return self.design.port_disciplines.get(try Elaborate.flatReference(self.file, self.arena, self.module, ex.lhs(e)));
}

test canonical {
    // §1.3.1.2: `I(5,2)` is `I(2,5)` with the sign flipped.
    const t = canonical(.flow, 5, 2, unnamed_branch, 7);
    try std.testing.expectEqual(@as(u32, 2), t.hi);
    try std.testing.expectEqual(@as(u32, 5), t.lo);
    try std.testing.expect(t.neg);
    try std.testing.expectEqual(@as(u32, 7), t.unit);
    // `ground` is above every row, so a single-net access is already canonical.
    const v = canonical(.potential, 3, ground, unnamed_branch, 0);
    try std.testing.expectEqual(@as(u32, 3), v.hi);
    try std.testing.expectEqual(ground, v.lo);
    try std.testing.expect(!v.neg);
    // Equal terminals (two `ground` nets, §1.3.1.1) are not reversed.
    try std.testing.expect(!canonical(.potential, ground, ground, unnamed_branch, 0).neg);
}
