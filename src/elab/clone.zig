//! The clone: one child instance's declarations, statements and expressions →
//! new AST rows in the flat namespace, with ports bound and parameters
//! overridden. LRM §3.4.4, §4.4, §4.7.1, §5.3.2, §5.5.3, §6.2.1, §6.3, §6.3.6 ($mfactor
//! scaling), §6.4.1, §6.6.2, §6.7, §9.13.1/§9.13.2 (paramset distribution calls),
//! §9.18, §9.19.

const std = @import("std");
const hier_param = @import("hier_param.zig");
const elaborate = @import("elaborate.zig");
const Flatten = elaborate.Flatten;
const elab_names = @import("names.zig");
const elab_override = @import("override.zig");
const Ast = @import("frontend").Ast;
const dist = @import("dist.zig");
const rng = @import("kernels").rng_kernels;
const Error = elaborate.Error;
const sep = elaborate.sep;

// ---- the clone --------------------------------------------------------

/// Appends `params` and `aliases` to the flat design under their flat names,
/// taking each value from `over` when overridden (§6.3). Every cloned
/// parameter is local: the device's model card is the top's parameter list,
/// and a child's value is fixed at elaboration. Reports E0921 on a §3.4.4
/// array size mismatch.
pub fn cloneParams(
    self: *Flatten,
    params: []const Ast.ParamDecl,
    aliases: []const Ast.AliasParam,
    over: *const std.AutoHashMapUnmanaged(Ast.StrId, Ast.ExprId),
) Error!void {
    for (params) |p| {
        var out = p;
        out.name = elab_names.flat(self, p.name);
        out.ranges = try cloneRanges(self, p.ranges);
        out.dims = try cloneDims(self, p.dims);
        out.packed_range = try cloneDim(self, p.packed_range);
        if (over.get(p.name)) |v| {
            out.default = v; // already in the parent's flat namespace
            out.is_override = true;
        } else {
            out.default = try cloneExpr(self, p.default);
        }
        out.is_local = true;
        try self.params.append(self.ctx.arena, out);
        try elab_names.syncParamValues(self);
        if (out.dims.len != 0) try checkArraySize(self, out, over.contains(p.name));
    }
    for (aliases) |al| {
        if (@import("alias.zig").original(self.ctx.file, params, aliases, al)) |target|
            try self.expression_aliases.append(self.ctx.arena, .{
                .alias = elab_names.flat(self, al.alias),
                .target = elab_names.flat(self, target),
            });
        if (hier_param.Kind.fromName(self.ctx.file.str(al.target))) |kind| {
            // An inlined alias denotes THIS instance's resolved value. It
            // must not declare another top-level model-card system alias.
            const value = self.unit.hier.get(kind);
            try self.params.append(self.ctx.arena, .{
                .name = elab_names.flat(self, al.alias),
                .ty = .real,
                .default = if (value == .none) try self.ctx.file.exprs.addReal(self.ctx.arena, 0, kind.initial()) else value,
                .is_local = true,
                .main_tok = 0,
            });
            try elab_names.syncParamValues(self);
        } else try self.aliasparams.append(self.ctx.arena, .{
            .alias = elab_names.flat(self, al.alias),
            .target = elab_names.flat(self, al.target),
        });
    }
}

/// §3.4.4: "An array assigned to an instance of a module to override the
/// default value of an array parameter shall be of the exact size of the
/// parameter array", and "If the array size is changed, the parameter array
/// shall be assigned an array of the new size". Judged on the flat parameter
/// `p`, whose range and value already have overrides applied, so both rules
/// are one element-count comparison.
///
/// ponytail: "from the same module as the parameter assignment that changed
/// the parameter array size" is not checked; a replacement of the right size
/// from a defparam elsewhere is accepted. The upgrade is recording each
/// override's source module in `over`.
fn checkArraySize(self: *Flatten, p: Ast.ParamDecl, overridden: bool) Error!void {
    const got, const want = patternMismatch(self, p.default, p.dims) orelse return;
    const tok = if (overridden) self.ctx.file.exprs.mainTok(p.default) else p.main_tok;
    if (overridden)
        try self.err(tok, .E0921, "the array assigned to `{s}` has {d} elements, and its declared range has {d}", .{ self.ctx.file.str(p.name), got, want })
    else
        try self.err(tok, .E0921, "an override resized `{s}` to {d} elements, and no array of the new size was assigned to it (its default has {d})", .{ self.ctx.file.str(p.name), want, got });
}

/// The first `{ got, want }` element-count disagreement between assignment
/// pattern `e` and `dims`, outermost dimension first; null when they agree
/// or when either side does not fold (lowering owns those diagnostics).
fn patternMismatch(self: *Flatten, e: Ast.ExprId, dims: []const Ast.Dim) ?struct { i128, i128 } {
    if (dims.len == 0) return null;
    const ex = &self.ctx.file.exprs;
    if (e == .none or (ex.tag(e) != .assign_pattern and ex.tag(e) != .concat)) return null;
    const msb = elab_names.constIntFlat(self, dims[0].msb) orelse return null;
    const lsb = elab_names.constIntFlat(self, dims[0].lsb) orelse return null;
    var elems = ex.args(e);
    var reps: i64 = 1;
    // A.8.1's `'{N{...}}` with a non-literal count: see `Ast.Tag.pattern_repl`.
    if (elems.len == 1 and ex.tag(elems[0]) == .pattern_repl) {
        reps = elab_names.constIntFlat(self, ex.lhs(elems[0])) orelse return null;
        elems = ex.args(ex.rhs(elems[0]));
    }
    const got = @as(i128, reps) * elems.len;
    const want: i128 = @intCast(@abs(@as(i128, msb) - lsb) + 1);
    if (got != want) return .{ got, want };
    for (elems) |el| if (patternMismatch(self, el, dims[1..])) |m| return m;
    return null;
}

/// Clones a range's bounds into the flat namespace; null stays null.
pub fn cloneDim(self: *Flatten, d: ?Ast.Dim) Error!?Ast.Dim {
    const dim = d orelse return null;
    return .{ .msb = try cloneExpr(self, dim.msb), .lsb = try cloneExpr(self, dim.lsb) };
}

/// Clones a rise/fall/off delay into the flat namespace.
pub fn cloneDelay(self: *Flatten, d: Ast.Delay3) Error!Ast.Delay3 {
    return .{ .rise = try cloneExpr(self, d.rise), .fall = try cloneExpr(self, d.fall), .off = try cloneExpr(self, d.off) };
}

/// Returns named event `e` under its flat name, dimensions cloned.
pub fn cloneEvent(self: *Flatten, e: Ast.EventDecl) Error!Ast.EventDecl {
    return .{ .name = elab_names.flat(self, e.name), .dims = try cloneDims(self, e.dims), .main_tok = e.main_tok };
}

fn cloneDims(self: *Flatten, dims: []const Ast.Dim) Error![]const Ast.Dim {
    if (dims.len == 0) return &.{};
    const out = try self.ctx.arena.alloc(Ast.Dim, dims.len);
    for (dims, out) |d, *o| o.* = (try cloneDim(self, d)).?;
    return out;
}

fn cloneRanges(self: *Flatten, rs: []const Ast.ValueRange) Error![]const Ast.ValueRange {
    if (rs.len == 0) return &.{};
    const out = try self.ctx.arena.alloc(Ast.ValueRange, rs.len);
    for (rs, out) |r, *o| {
        o.* = r;
        o.lo = try cloneExpr(self, r.lo);
        o.hi = try cloneExpr(self, r.hi);
    }
    return out;
}

/// Returns `v` under its flat name, with dimensions and initializer cloned.
pub fn cloneVar(self: *Flatten, v: Ast.VarDecl) Error!Ast.VarDecl {
    var out = v;
    out.name = elab_names.flat(self, v.name);
    out.dims = try cloneDims(self, v.dims);
    out.packed_range = try cloneDim(self, v.packed_range);
    out.init = try cloneExpr(self, v.init);
    return out;
}

/// Clones a §4.7.1 user function under its flat name. Its formals and locals
/// are the function's own scope, so they are hidden from the unit's rename
/// map for the body; otherwise a formal sharing a module-level name would be
/// rewritten to the module's.
pub fn cloneFunc(self: *Flatten, fd: Ast.FuncDecl) Error!Ast.FuncDecl {
    var out = fd;
    out.name = elab_names.flat(self, fd.name);
    var hidden: std.ArrayList(HiddenName) = try .initCapacity(self.ctx.arena, fd.args.len + fd.params.len + fd.vars.len);
    for (fd.args) |arg| hide(self, &hidden, arg.name);
    for (fd.params) |p| hide(self, &hidden, p.name);
    for (fd.vars) |v| hide(self, &hidden, v.name);
    out.params = try cloneLocalParams(self, fd.params);
    out.vars = try cloneLocalVars(self, fd.vars);
    out.body = try cloneStmt(self, fd.body);
    unhide(self, hidden.items);
    return out;
}

/// A rename-map entry `hide` removed, restored by `unhide`.
const HiddenName = struct { name: Ast.StrId, was: ?Ast.StrId };

comptime {
    // One row per local of every cloned block and function; 12 B budget.
    std.debug.assert(@sizeOf(HiddenName) == 12);
}

/// Removes `name` from the unit's rename map for a local scope and records
/// the old binding in `list`, which the caller sized for every local it hides.
/// The caller restores the whole list with `unhide`, in reverse order.
fn hide(self: *Flatten, list: *std.ArrayList(HiddenName), name: Ast.StrId) void {
    list.appendAssumeCapacity(.{ .name = name, .was = self.unit.rename.get(name) });
    _ = self.unit.rename.remove(name);
}

fn unhide(self: *Flatten, list: []const HiddenName) void {
    // Reverse, so a name hidden twice (a formal and a body local) comes back
    // to the outermost saved binding.
    var i = list.len;
    while (i > 0) {
        i -= 1;
        if (list[i].was) |w| {
            self.unit.rename.putAssumeCapacity(list[i].name, w);
        } else {
            _ = self.unit.rename.remove(list[i].name);
        }
    }
}

/// A block's or function's own declarations: cloned for their initializers
/// and ranges, but not renamed: they are locals of a scope lowering already
/// pushes and pops.
fn cloneLocalParams(self: *Flatten, ps: []const Ast.ParamDecl) Error![]const Ast.ParamDecl {
    if (ps.len == 0) return &.{};
    const out = try self.ctx.arena.alloc(Ast.ParamDecl, ps.len);
    for (ps, out) |p, *o| {
        o.* = p;
        o.default = try cloneExpr(self, p.default);
        o.dims = try cloneDims(self, p.dims);
        o.packed_range = try cloneDim(self, p.packed_range);
        o.ranges = try cloneRanges(self, p.ranges);
    }
    return out;
}

fn cloneLocalVars(self: *Flatten, vs: []const Ast.VarDecl) Error![]const Ast.VarDecl {
    if (vs.len == 0) return &.{};
    const out = try self.ctx.arena.alloc(Ast.VarDecl, vs.len);
    for (vs, out) |v, *o| {
        o.* = v;
        o.dims = try cloneDims(self, v.dims);
        o.packed_range = try cloneDim(self, v.packed_range);
        o.init = try cloneExpr(self, v.init);
    }
    return out;
}

/// Clones the branch a `<+` or an indirect assignment drives, as opposed to
/// one it reads: §6.3.6's flow-probe division must not fire on it.
fn cloneTarget(self: *Flatten, e: Ast.ExprId) Error!Ast.ExprId {
    // A target holds no statement, so no target clone nests inside another,
    // and the reset below cannot end an outer one early.
    std.debug.assert(!self.contrib_target);
    self.contrib_target = true;
    defer self.contrib_target = false;
    return cloneExpr(self, e);
}

/// §6.4.1: "The right-hand side can be composed of numbers, parameters, and
/// hierarchical out-of-module references to local parameters of a different
/// module. Hierarchical out-of-module references to non-local parameters are
/// disallowed."
///
/// The clause's example reads `semicoCMOS.tox` from a module nothing
/// instantiates, so the reference has no instance path and §6.7's flat-name
/// lookup (E0901) cannot resolve it. It names the declaration, so its
/// declared default is substituted here.
///
/// ponytail: the default is cloned under an empty rename map, so a library
/// localparam whose own default reads a sibling localparam leaves that name
/// unresolved (E0901 at lowering) rather than silently capturing a
/// same-named paramset parameter. §6.4.1's worked example does not nest.
/// The upgrade path is a recursive substitution keyed on the owning module.
fn paramsetOomr(self: *Flatten, e: Ast.ExprId) Error!?Ast.ExprId {
    if (!self.in_paramset) return null;
    const parts = self.ctx.file.exprs.nameParts(e);
    if (parts.len != 2) return null;
    const m = elab_names.findModule(self, parts[0]) orelse return null;
    const p = for (m.params) |*q| {
        if (q.name == parts[1]) break q;
    } else return null;
    if (!p.is_local) {
        try self.err(self.ctx.file.exprs.mainTok(e), .E0907, "`{s}.{s}` is a parameter, and §6.4.1 allows a paramset to reach out of module only to a LOCAL parameter", .{
            self.ctx.file.str(parts[0]), self.ctx.file.str(parts[1]),
        });
        return null;
    }
    const saved = self.unit;
    self.unit = .{ .hier = saved.hier };
    defer self.unit = saved;
    return try cloneExpr(self, p.default);
}

/// What `upward` made of a dotted name's first part.
const Upward = union(enum) {
    /// Not a scope of any enclosing unit: the name stays rooted at the top.
    keep,
    /// The flat name of the scope it found.
    head: Ast.StrId,
    /// The whole reference, a generate block's localparam, as its value.
    value: Ast.ExprId,
};

/// §6.7.1 adopts IEEE 1364-2005 12.6 for `scope_name.item_name`: look in the
/// current scope, then "in the parent module's outermost scope", and "repeat
/// step b), going up the hierarchy". §6.8 says the same of generate blocks
/// (12.7: "searched first at the current level and then in higher level
/// modules until found"). `parts[0]` is not a name the unit binds; this
/// walks the unit and the units above it (`Unit.up`) for a module instance
/// (12.6 restricts scope_name to a hierarchical_inst_identifier) or a named
/// generate block of that name, nearest first.
fn upward(self: *Flatten, e: Ast.ExprId, parts: []const Ast.StrId) Error!Upward {
    if (parts.len < 2) return .keep;
    var at: ?*const Flatten.Unit = &self.unit;
    while (at) |u| : (at = u.up) {
        const m = u.module orelse return .keep;
        // The top's names are its flat names; below it, the unit bound it.
        if (declaresInstance(self, m, parts[0])) return if (u.up == null) .keep else .{ .head = u.rename.get(parts[0]) orelse return .keep };
        var conds: std.ArrayList(GenCond) = .empty;
        for (m.analog) |blk| if (try genBlock(self, blk.body, parts[0], &conds)) |b|
            return genBlockRef(self, e, u, b, conds.items, parts);
    }
    return .keep;
}

/// Whether `m` declares a (non-array) module instance `name`, in its body or
/// in a generate block.
fn declaresInstance(self: *Flatten, m: *const Ast.ModuleDecl, name: Ast.StrId) bool {
    for (m.instances) |inst| if (inst.name == name and inst.range == null) return true;
    for (self.genInstancesOf(m)) |inst| if (inst.name == name and inst.range == null) return true;
    return false;
}

/// One if-generate scheme on the way down to a generate block: its
/// condition, negated in the else arm.
const GenCond = struct { cond: Ast.ExprId, negate: bool };

/// The named generate block `name` under statement `id`, with the
/// if-generate schemes that select it appended to `conds`. A block inside a
/// loop generate is `name[i]` (§6.6.1) and a case arm's needs its selector
/// matched, so neither is found here.
fn genBlock(self: *Flatten, id: Ast.StmtId, name: Ast.StrId, conds: *std.ArrayList(GenCond)) Error!?Ast.SeqBlock {
    if (id == .none) return null;
    // A miss pops every scheme it pushed; a hit leaves its path on.
    const depth = conds.items.len;
    switch (self.ctx.file.stmt(id)) {
        .block => |b| {
            if (b.gen_name != .none and b.name == name) return b;
            for (b.body) |s| if (try genBlock(self, s, name, conds)) |hit| return hit;
        },
        .if_stmt => |s| if (s.is_generate) for ([_]Ast.StmtId{ s.then_s, s.else_s }, [_]bool{ false, true }) |arm, negate| {
            try conds.append(self.ctx.arena, .{ .cond = s.cond, .negate = negate });
            if (try genBlock(self, arm, name, conds)) |hit| return hit;
            _ = conds.pop();
        },
        else => {}, // else: only blocks and if-generates lead to a scope this search may name
    }
    std.debug.assert(conds.items.len == depth);
    return null;
}

/// A reference through the generate block `b` of unit `u`. §6.6.2: a block
/// its scheme does not select does not exist, so the schemes must fold true
/// in `u`'s names (E0901 otherwise). `b.k` for one of the block's
/// localparams is that localparam's value, cloned in `u`'s names, which no
/// lowering order can make unready; any other item is the block's flat name.
///
/// ponytail: a localparam whose value reads another of the block's own
/// localparams, or an integer one whose value does not fold to an integer
/// (§3.4.1's conversion), keeps the flat name, which lowering resolves or
/// refuses (E0901). The upgrade is `bindGenLocals`-style substitution.
fn genBlockRef(self: *Flatten, e: Ast.ExprId, u: *const Flatten.Unit, b: Ast.SeqBlock, conds: []const GenCond, parts: []const Ast.StrId) Error!Upward {
    const saved = self.unit;
    self.unit = u.*;
    defer self.unit = saved;
    for (conds) |c| {
        const v = elab_names.constValue(self, c.cond, true, null);
        if (v != null and v.?.isTrue() != c.negate) continue;
        try self.err(self.ctx.file.exprs.mainTok(e), .E0901, "`{s}` is a generate block its scheme does not select (§6.6.2)", .{self.ctx.file.str(parts[0])});
        return .keep;
    }
    const flat_head: Upward = if (u.up == null) .keep else .{ .head = try elab_names.join(self, u.path, parts[0]) };
    if (parts.len != 2) return flat_head;
    const p = for (b.params) |*q| {
        if (q.name == parts[1] and q.dims.len == 0) break q;
    } else return flat_head;
    for (b.params) |q| if (readsName(self.ctx.file, p.default, q.name)) return flat_head;
    if (p.ty == .integer) {
        const v = elab_names.constValue(self, p.default, true, null) orelse return flat_head;
        if (v != .int) return flat_head;
    }
    return .{ .value = try cloneExpr(self, p.default) };
}

/// Whether `e` reads the identifier `name`.
fn readsName(file: *const Ast.SourceFile, e: Ast.ExprId, name: Ast.StrId) bool {
    if (e == .none) return false;
    if (file.exprs.tag(e) == .ident and file.exprs.strOf(e) == name) return true;
    var buf: [3]Ast.ExprId = undefined;
    for (file.exprs.children(e, &buf)) |c| if (readsName(file, c, name)) return true;
    return false;
}

/// §5.4.3 the flow into a port of this unit's own module, read from inside
/// an instance: `I(<a>)` (`I(<a[k]>)`) with `a` one of its ports, or `I(pb)`
/// with `pb` its §3.12.1 port branch, which names the same quantity. Returns
/// the port's local name, else null. At the top (`unit.up == null`) the
/// host binds the ports and `I(<a>)` is its own exact unknown.
fn ownPortFlow(self: *Flatten, e: Ast.ExprId) ?Ast.StrId {
    if (self.unit.up == null or self.unit.path.len == 0) return null;
    const m = self.unit.module orelse return null;
    const x = &self.ctx.file.exprs;
    var t = x.lhs(e);
    if (t != .none and x.tag(t) == .index) t = x.lhs(t);
    if (t == .none or x.tag(t) != .ident) return null;
    const name = x.strOf(t);
    if (x.tag(e) == .port_access) {
        for (m.ports) |p| if (p.name == name) return name;
    } else if (x.rhs(e) == .none) {
        for (m.branches) |b| if (b.is_port_branch and b.name == name) {
            var h = b.hi;
            if (h != .none and x.tag(h) == .index) h = x.lhs(h);
            return if (h != .none and x.tag(h) == .ident) x.strOf(h) else name;
        };
    }
    return null;
}

/// Copies one expression subtree into the store, renaming the names that
/// belong to the unit being inlined, and applies the per-instance rewrites
/// (§6.3.6 flow-probe division, §9.18/§9.19 answers, §6.4.1 references).
/// Rows are appended, never mutated, so the child's source ids stay valid
/// for its next instance.
pub fn cloneExpr(self: *Flatten, e: Ast.ExprId) Error!Ast.ExprId {
    if (e == .none) return .none;
    const x = &self.ctx.file.exprs;
    var n = x.get(e);
    var local_only = false;
    switch (n.tag) {
        // Literals and the two infinities carry no reference; the side-table
        // index in `extra` is shared, which is safe because `reals`/`ints`
        // are append-only too.
        .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf => {},
        .ident => n.str = elab_names.flat(self, n.str),
        .hier_ident => {
            if (try paramsetOomr(self, e)) |sub| return sub;
            // §6.7 a dotted name. Only the first part can be a local of this
            // unit, so renaming part 0 turns `u.gain` written inside a child
            // into the flat `mid.u.gain`; this is §6.2.1's "priority to the
            // local scope". A `$root` prefix names no unit, so it passes
            // through and `Lower.flatName` strips it.
            const parts = x.nameParts(e);
            var head = elab_names.flat(self, parts[0]);
            // §6.6.2 an unnamed generate block of this unit is no scope a name
            // may open; joined onto the unit's path, lowering refuses it by
            // name (E0998) instead of reading it from the top's namespace.
            if (!self.unit.rename.contains(parts[0])) {
                if (parts.len > 1 and self.unit.up != null and self.unit.module != null and
                    elab_names.namesUnnamedGen(self.ctx.file, self.unit.module.?, parts[0]))
                    head = try elab_names.join(self, self.unit.path, parts[0])
                else switch (try upward(self, e, parts)) {
                    .keep => {},
                    .head => |h| head = h,
                    .value => |v| return v,
                }
            }
            const out = try self.ctx.arena.alloc(Ast.StrId, parts.len);
            for (parts, out, 0..) |p, *o, i| o.* = if (i == 0) head else p;
            n.extra = try self.ctx.file.exprs.addStrList(self.ctx.arena, out);
        },
        .unary => n.lhs = try cloneExpr(self, x.lhs(e)),
        .binary, .index, .range, .indexed_range, .event_or, .multi_concat, .pattern_repl => {
            n.lhs = try cloneExpr(self, x.lhs(e));
            n.rhs = try cloneExpr(self, x.rhs(e));
        },
        .ternary => {
            const third = x.ternaryElse(e);
            n.lhs = try cloneExpr(self, x.lhs(e));
            n.rhs = try cloneExpr(self, x.rhs(e));
            n.extra = @backingInt(try cloneExpr(self, third));
        },
        // A.6.5 `driver_update expression` sits with the digital edges: one
        // signal operand. It occurs only in a connect module, which is
        // cloned when hand-placed (§7.1) or inserted (§7.8).
        .event_posedge, .event_negedge, .event_driver_update => n.lhs = try cloneExpr(self, x.lhs(e)),
        .event_initial_step, .event_final_step => {}, // §5.10.2 analysis names
        .branch_access, .port_access => {
            // §5.4.3 the flow into this INSTANCE's own port. Joined, the port
            // is the parent's net, whose port flow is another quantity (the
            // top's, or none: E0508), and VerA sums an instance's port flow
            // only for a reader above it (`lower_expr.instancePortFlow`).
            if (!self.contrib_target) if (ownPortFlow(self, e)) |port| {
                const access = self.ctx.file.str(n.str);
                try self.err(n.main_tok, .E0997, "`{s}` inside instance `{s}` reads the flow into its own port `{s}`; VerA sums that flow only for a module above it, as `{s}(<{s}{s}>)`", .{
                    access, self.unit.path[0 .. self.unit.path.len - 1], self.ctx.file.str(port), access, self.unit.path, self.ctx.file.str(port),
                });
                return x.addReal(self.ctx.arena, n.main_tok, 0.0);
            };
            // §4.4 `str` is the access function (`V`, `I`), not a name in
            // this unit; the terminals are `lhs`/`rhs`.
            n.lhs = try cloneExpr(self, x.lhs(e));
            n.rhs = try cloneExpr(self, x.rhs(e));
            if (self.unit.primitive) {
                n.str = elab_names.primitiveAccess(self, n.str, n.lhs);
            } else {
                try elab_names.checkTypedPort(self, n.str, x.lhs(e), n.main_tok);
                try elab_names.checkTypedPort(self, n.str, x.rhs(e), n.main_tok);
                const a = try elab_names.localAccess(self, n.str, x.lhs(e), n.lhs, n.main_tok);
                n.str = a.name;
                local_only = a.local_only;
            }
            // §6.3.6 rule 2: a flow probe inside a scaled instance reads
            // $mfactor copies' worth of flow, so the per-copy value is that
            // over $mfactor. Not the branch a `<+` drives (`contrib_target`).
            if (!self.contrib_target) {
                const probe = try self.ctx.file.exprs.add(self.ctx.arena, n);
                if (local_only) try self.local_accesses.put(self.ctx.arena, probe, {});
                return (try elab_names.mfactorScale(self, probe, n.str, n.lhs, .div, n.main_tok)) orelse probe;
            }
        },
        .call => {
            // §4.7 a user function was renamed with the declarations.
            n.str = elab_names.flat(self, n.str);
            n.extra = try cloneArgs(self, x.args(e));
        },
        .sys_call => {
            if (try rewriteSysCall(self, e)) |lit| return lit;
            if (self.in_paramset) if (try rewriteParamsetDist(self, e)) |out| return out;
            n.extra = try cloneArgs(self, x.args(e));
        },
        .builtin_call, .filter_call, .event_function, .concat, .assign_pattern => {
            n.extra = try cloneArgs(self, x.args(e));
        },
        // §6.3.6 rules 3 and 4 scale the noise power.
        .noise_call => {
            n.extra = try cloneArgs(self, x.args(e));
            return elab_names.mfactorNoise(self, try self.ctx.file.exprs.add(self.ctx.arena, n));
        },
    }
    const out = try self.ctx.file.exprs.add(self.ctx.arena, n);
    if (local_only) try self.local_accesses.put(self.ctx.arena, out, {});
    // §5.5.3 reads the nature of the local net segment. Renaming a bound
    // port to its parent must not replace that segment's nature attributes.
    if (n.tag == .hier_ident) {
        const parts = x.nameParts(e);
        if (parts.len == 3) {
            const half = self.ctx.file.str(parts[1]);
            if (std.mem.eql(u8, half, "potential") or std.mem.eql(u8, half, "flow")) {
                if (self.unit.port_disc.get(parts[0])) |disc| {
                    try self.attribute_disciplines.put(self.ctx.arena, out, disc);
                } else if (self.unit.connected.contains(parts[0])) {
                    try self.pending_attributes.append(self.ctx.arena, .{
                        .expr = out,
                        .net = elab_names.flat(self, parts[0]),
                        .path = self.unit.path,
                    });
                }
            }
        }
    }
    return out;
}

inline fn cloneArgs(self: *Flatten, src: []const Ast.ExprId) Error!u32 {
    const out = try self.ctx.arena.alloc(Ast.ExprId, src.len);
    for (src, out) |s, *o| o.* = try cloneExpr(self, s);
    return self.ctx.file.exprs.addExprList(self.ctx.arena, out);
}

/// Ch9 functions whose answer is a property of the instantiation. §9.19 `$port_connected` and
/// `$param_given` must be answered here: after the flatten a connected port
/// is the parent's net and nothing downstream can tell the two apart. §9.18
/// hierarchical values are the expressions `collectOverrides` composed.
fn rewriteSysCall(self: *Flatten, e: Ast.ExprId) Error!?Ast.ExprId {
    const x = &self.ctx.file.exprs;
    const name = x.strOf(e);
    const tok = x.mainTok(e);
    if (hier_param.Kind.fromName(self.ctx.file.str(name))) |kind| {
        const value = self.unit.hier.get(kind);
        return if (value == .none) null else value;
    }
    const is_pc = self.ctx.file.strings.eql(name, "$port_connected");
    const is_pg = self.ctx.file.strings.eql(name, "$param_given");
    if (!is_pc and !is_pg) return null;
    const args = x.args(e);
    if (args.len != 1 or args[0] == .none or x.tag(args[0]) != .ident) return null;
    const local = x.strOf(args[0]);
    const table = if (is_pc) &self.unit.connected else &self.unit.given;
    const answer = table.get(local) orelse return null;
    return try self.ctx.file.exprs.addInt(self.ctx.arena, tok, @intFromBool(answer));
}

/// §9.13.1/§9.13.2 a distribution call written inside a §6.4 paramset body,
/// the one scope whose calls may carry the optional trailing `type_string`.
///
///   1. The `type_string`: `type_string ::= "global" | "instance"`, anything
///      else is E0816. Monte-Carlo trials are the host's loop, and in the one
///      trial VerA compiles both spellings select the same draw, so a valid
///      string is validated and dropped.
///   2. The value: §9.13.2 makes the draw a pure function of its seed, so a
///      call whose seed and parameters are literals is folded now with the
///      same kernels every device embeds (`rng_kernels.zig`). The literal
///      then reaches the model card through the ordinary §6.3 overrides.
///
/// Returns null when the callee is not one of Table 9-10's names (or is
/// `$random`, whose Syntax 9-8 production has no `type_string`). A call
/// whose arguments do not fold is returned with the string stripped and
/// left to lowering, which owns the remaining argument rules (in a parameter
/// position that still ends in E0363).
///
/// ponytail: the fold takes a literal seed only. Syntax 9-9 also admits an
/// integer parameter identifier, and a paramset's own parameters are fixed
/// by the time this runs; folding through them needs the parameter values
/// threaded in here. Add when a model writes one.
fn rewriteParamsetDist(self: *Flatten, e: Ast.ExprId) Error!?Ast.ExprId {
    const x = &self.ctx.file.exprs;
    const name = self.ctx.file.str(x.strOf(e));
    const d = dist.of(name) orelse return null;
    if (std.mem.eql(u8, name, "$random")) return null;
    const tok = x.mainTok(e);
    const args = x.args(e);

    var eff = args;
    var stripped = false;
    var bad = false;
    if (eff.len > 0 and eff[eff.len - 1] != .none and x.tag(eff[eff.len - 1]) == .str_literal) {
        const last = eff[eff.len - 1];
        const ts = self.ctx.file.str(x.strOf(last));
        if (!std.mem.eql(u8, ts, "global") and !std.mem.eql(u8, ts, "instance")) {
            try self.err(x.mainTok(last), .E0816, "`{s}`'s `type_string` shall be \"global\" or \"instance\", got \"{s}\"", .{ name, ts });
            bad = true;
        }
        eff = eff[0 .. eff.len - 1];
        stripped = true;
    }

    // The fold: the seed plus §9.13.2's parameters, all literal, judged by
    // the same domain rules `lowerRandom` applies on the runtime path.
    fold: {
        if (bad or eff.len != @as(usize, d.nparam) + 1) break :fold;
        const seed = constIntLit(x, eff[0]) orelse break :fold;
        var p = [2]f64{ 0, 0 };
        for (eff[1..], 0..) |arg, i| {
            p[i] = elab_override.constReal(self, arg) orelse break :fold;
            if (d.positive & (@as(u8, 1) << @intCast(i)) != 0 and !(p[i] > 0)) {
                try self.err(x.mainTok(arg), .E0816, "`{s}`'s `{s}` shall be greater than zero, got {d}", .{ name, dist.paramName(d, i), p[i] });
                bad = true;
            }
            if (d.count and i == 0 and p[i] > 0 and
                (!(p[i] <= 2147483647.0) or p[i] != @trunc(p[i])))
            {
                try self.err(x.mainTok(arg), .E0816, "`{s}`'s fractional or out-of-range `{s}` is unsupported; the reference count domain is 1..2147483647", .{ name, dist.paramName(d, i) });
                bad = true;
            }
        }
        if (d.ordered and d.ty == .real and !(p[0] < p[1])) {
            try self.err(x.mainTok(eff[1]), .E0816, "the start value shall be smaller than the end value, got {d} and {d}", .{ p[0], p[1] });
            bad = true;
        }
        if (bad) break :fold; // report; nothing sound to draw
        const v: f64 = if (std.mem.eql(u8, d.kernel, "$rng$rand"))
            rng.zRngRand(seed)
        else if (std.mem.eql(u8, d.kernel, "$rng$i_uniform"))
            rng.zRngIUniform(seed, p[0], p[1])
        else if (std.mem.eql(u8, d.kernel, "$rng$uniform"))
            rng.zRngUniform(seed, p[0], p[1])
        else if (std.mem.eql(u8, d.kernel, "$rng$normal"))
            rng.zRngNormal(seed, p[0], p[1])
        else if (std.mem.eql(u8, d.kernel, "$rng$exponential"))
            rng.zRngExponential(seed, p[0])
        else if (std.mem.eql(u8, d.kernel, "$rng$poisson"))
            rng.zRngPoisson(seed, p[0])
        else if (std.mem.eql(u8, d.kernel, "$rng$chi_square"))
            rng.zRngChiSquare(seed, p[0])
        else if (std.mem.eql(u8, d.kernel, "$rng$t"))
            rng.zRngT(seed, p[0])
        else if (std.mem.eql(u8, d.kernel, "$rng$erlang"))
            rng.zRngErlang(seed, p[0], p[1])
        else
            break :fold;
        if (d.ty == .integer and (!std.math.isFinite(v) or
            @round(v) < -2147483648.0 or @round(v) > 2147483647.0))
        {
            try self.err(tok, .E0816, "`{s}`'s reference result cannot be represented as a signed 32-bit integer", .{name});
            break :fold;
        }
        // §9.13.2 "$dist_ ... return integer values": §4.2.1.1's rounding,
        // the same conversion the runtime path's `toInt` performs.
        return if (d.ty == .integer)
            try x.addInt(self.ctx.arena, tok, @intFromFloat(@round(v)))
        else
            try x.addReal(self.ctx.arena, tok, v);
    }

    if (!stripped) return null; // the ordinary clone will do
    // Unfoldable, but a `type_string` shall not survive to lowering, where
    // it would read as the out-of-paramset scope error: rebuild the call
    // over the remaining arguments, cloned as `cloneArgs` would have.
    var n = x.get(e);
    n.extra = try cloneArgs(self, eff);
    return try self.ctx.file.exprs.add(self.ctx.arena, n);
}

/// §9.13.1 Syntax 9-8's literal seed form, `[ sign ] decimal_number`. A real
/// is not one: "the seed argument shall be an integer" is lowering's E0816 to
/// report, so a real seed declines the fold.
fn constIntLit(x: *const Ast.ExprStore, e: Ast.ExprId) ?i64 {
    if (e == .none) return null;
    return switch (x.tag(e)) {
        .int_literal => x.intValue(e),
        .unary => switch (x.unOp(e)) {
            .plus => constIntLit(x, x.lhs(e)),
            .minus => if (constIntLit(x, x.lhs(e))) |v| -v else null,
            else => null, // else: the production's `[ sign ]` is `+` or `-` and nothing else
        },
        else => null, // else: not `[ sign ] decimal_number`, so not the literal seed form
    };
}

/// Copies one statement and everything under it into the pool, renamed into
/// the unit's flat namespace, scaling flow contributions by $mfactor (§6.3.6).
pub fn cloneStmt(self: *Flatten, id: Ast.StmtId) Error!Ast.StmtId {
    if (id == .none) return .none;
    const file = self.ctx.file;
    const tok = file.stmtTok(id);
    const s = file.stmt(id);
    const out: Ast.Stmt = switch (s) {
        .empty => .empty,
        .block => |b| blk: {
            // §5.3.2 a named block's declarations are locals, hidden for the
            // body like a function's formals.
            var hidden: std.ArrayList(HiddenName) = try .initCapacity(self.ctx.arena, b.params.len + b.vars.len + b.events.len);
            for (b.params) |p| hide(self, &hidden, p.name);
            for (b.vars) |v| hide(self, &hidden, v.name);
            for (b.events) |e| hide(self, &hidden, e.name);
            const params = try cloneLocalParams(self, b.params);
            const vars = try cloneLocalVars(self, b.vars);
            // IEEE 1364-2005 A.2.8 a named block's events are locals too:
            // hidden above, so `cloneEvent` keeps each name and clones dims.
            const events = try self.ctx.arena.alloc(Ast.EventDecl, b.events.len);
            for (b.events, events) |e, *o| o.* = try cloneEvent(self, e);
            const body = try self.ctx.arena.alloc(Ast.StmtId, b.body.len);
            for (b.body, body) |src, *o| o.* = try cloneStmt(self, src);
            unhide(self, hidden.items);
            break :blk .{
                .block = .{
                    // §6.7 a block label is a scope name. Renamed with the rest,
                    // so `disable` inside the child still finds it and two
                    // instances do not declare one name twice.
                    .name = if (b.name == .none) .none else try joinLocal(self, b.name),
                    // IEEE 1364-2005 §9.8.2 `fork ... join` stays parallel.
                    .parallel = b.parallel,
                    .params = params,
                    .vars = vars,
                    .events = events,
                    .body = body,
                    // §6.6.3 an external name, relative to the unit: not renamed.
                    .gen_name = b.gen_name,
                },
            };
        },
        // Copied over the source row, so the discrete-only fields (A.6.2's
        // `<=` and intra-assignment timing) survive the clone.
        .assign => |v| blk: {
            var o = v;
            o.target = try cloneExpr(self, v.target);
            o.value = try cloneExpr(self, v.value);
            o.timing = try cloneExpr(self, v.timing);
            // IEEE 1364-2005 §9.7.7 `repeat (count)` reads the unit's names.
            o.timing_repeat = try cloneExpr(self, v.timing_repeat);
            break :blk .{ .assign = o };
        },
        .contribute => |v| blk: {
            const lhs = try cloneTarget(self, v.lhs);
            const rhs = try cloneExpr(self, v.rhs);
            // §6.3.6 rule 1: "all contributions to a branch flow quantity in
            // the analog block shall be multiplied by $mfactor", and the
            // clause adds that "Verilog-AMS does not provide a method to
            // disable" it. A potential contribution is left alone: $mfactor
            // copies in parallel share a potential.
            const x = &self.ctx.file.exprs;
            const scaled = if (x.tag(lhs) == .branch_access or x.tag(lhs) == .port_access)
                try elab_names.mfactorScale(self, rhs, x.strOf(lhs), x.lhs(lhs), .mul, x.mainTok(lhs))
            else
                null;
            break :blk .{ .contribute = .{ .lhs = lhs, .rhs = scaled orelse rhs } };
        },
        .indirect => |v| .{ .indirect = .{
            .lhs = try cloneTarget(self, v.lhs),
            .probe = try cloneExpr(self, v.probe),
            .eqn = try cloneExpr(self, v.eqn),
        } },
        .if_stmt => |v| .{ .if_stmt = .{
            .cond = try cloneExpr(self, v.cond),
            .then_s = try cloneStmt(self, v.then_s),
            .else_s = try cloneStmt(self, v.else_s),
            .is_generate = v.is_generate,
        } },
        .case_stmt => |v| blk: {
            const arms = try self.ctx.arena.alloc(Ast.CaseArm, v.arms.len);
            for (v.arms, arms) |src, *o| {
                const labels = try self.ctx.arena.alloc(Ast.ExprId, src.labels.len);
                for (src.labels, labels) |l, *ol| ol.* = try cloneExpr(self, l);
                o.* = .{ .labels = labels, .body = try cloneStmt(self, src.body) };
            }
            break :blk .{ .case_stmt = .{
                .kind = v.kind,
                .scrutinee = try cloneExpr(self, v.scrutinee),
                .arms = arms,
                .is_generate = v.is_generate,
            } };
        },
        .for_stmt => |v| .{ .for_stmt = .{
            .init = try cloneStmt(self, v.init),
            .cond = try cloneExpr(self, v.cond),
            .step = try cloneStmt(self, v.step),
            .body = try cloneStmt(self, v.body),
        } },
        .while_stmt => |v| .{ .while_stmt = .{
            .cond = try cloneExpr(self, v.cond),
            .body = try cloneStmt(self, v.body),
        } },
        .repeat_stmt => |v| .{ .repeat_stmt = .{
            .count = try cloneExpr(self, v.count),
            .body = try cloneStmt(self, v.body),
        } },
        .event_control => |v| .{
            .event_control = .{
                .event = try cloneExpr(self, v.event),
                .body = try cloneStmt(self, v.body),
                .kind = v.kind, // `#`/`wait` are not `@`
            },
        },
        .event_trigger => |v| .{ .event_trigger = .{ .target = try cloneExpr(self, v.target) } },
        // A.6.5 a block label, spelled as the label itself was joined.
        .disable => |v| .{ .disable = .{ .name = try joinLocal(self, v.name) } },
        .sys_task => |v| blk: {
            // `name` is a system task (`$strobe`, ...), never a name of this unit.
            const args = try self.ctx.arena.alloc(Ast.ExprId, v.args.len);
            for (v.args, args) |src, *o| o.* = try cloneExpr(self, src);
            break :blk .{ .sys_task = .{ .name = v.name, .args = args } };
        },
        .jump => |v| .{ .jump = .{ .kind = v.kind, .value = try cloneExpr(self, v.value) } },
    };
    return file.addStmt(self.ctx.arena, out, tok);
}

/// A name the unit declares but that `bind` never saw, because it is not a
/// module-level declaration: a §5.3.2 block label. Joined against the unit's
/// path on demand, which the rename map already carries for every other
/// name of the unit.
fn joinLocal(self: *Flatten, name: Ast.StrId) Error!Ast.StrId {
    if (self.unit.rename.get(name)) |flat_id| return flat_id;
    // A dotted `disable` target (A.9.3) is a path already, not a label.
    if (std.mem.findScalar(u8, self.ctx.file.str(name), sep) != null) return name;
    // The unit's own path, never one read off a rename entry: a port's entry
    // is the PARENT's net, so it named the parent's scope (or none at the
    // top), and two instances' labels collided.
    return elab_names.join(self, self.unit.path, name);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fixture = @import("fixture.zig");

test "§9.13.1 constIntLit reads only Syntax 9-8's `[ sign ] decimal_number` seed" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file: Ast.SourceFile = .empty;
    const x = &file.exprs;
    const five = try x.addInt(a, 0, 5);
    const neg = try x.add(a, .{ .tag = .unary, .lhs = five, .extra = @backingInt(Ast.UnaryOp.minus) });
    const pos_neg = try x.add(a, .{ .tag = .unary, .lhs = neg, .extra = @backingInt(Ast.UnaryOp.plus) });
    const not_five = try x.add(a, .{ .tag = .unary, .lhs = five, .extra = @backingInt(Ast.UnaryOp.logical_not) });
    const real = try x.addReal(a, 0, 5.0);
    try std.testing.expectEqual(@as(?i64, 5), constIntLit(x, five));
    try std.testing.expectEqual(@as(?i64, -5), constIntLit(x, neg));
    try std.testing.expectEqual(@as(?i64, -5), constIntLit(x, pos_neg));
    // Any other operator, a real ("the seed argument shall be an integer",
    // lowering's E0816) and an omitted argument decline the fold.
    try std.testing.expectEqual(@as(?i64, null), constIntLit(x, not_five));
    try std.testing.expectEqual(@as(?i64, null), constIntLit(x, real));
    try std.testing.expectEqual(@as(?i64, null), constIntLit(x, .none));
}

test readsName {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var file: Ast.SourceFile = .empty;
    const x = &file.exprs;
    const na = try file.intern(a, "a");
    const nb = try file.intern(a, "b");
    const nc = try file.intern(a, "c");
    const ea = try x.add(a, .{ .tag = .ident, .str = na });
    const eb = try x.add(a, .{ .tag = .ident, .str = nb });
    const prod = try x.add(a, .{ .tag = .binary, .lhs = ea, .rhs = eb, .extra = @backingInt(Ast.BinaryOp.mul) });
    try std.testing.expect(readsName(&file, prod, na));
    try std.testing.expect(readsName(&file, prod, nb));
    try std.testing.expect(!readsName(&file, prod, nc));
    try std.testing.expect(!readsName(&file, .none, na));
}

test "§6.7 a child's block label joins its own instance path, whatever else the child declares" {
    // `kid` declares nothing but a port, bound to the top's `p`. Two
    // instances are two scopes, so the two labels must differ: otherwise
    // §5.3.2's static block locals of both would share one location.
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u1(p); kid u2(p); endmodule
        \\module kid(a); inout a; electrical a; analog begin : blk I(a) <+ V(a); end endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 2), d.top.analog.len);
    try std.testing.expectEqualStrings("u1.blk", f.file.str(f.file.stmt(d.top.analog[0].body).block.name));
    try std.testing.expectEqualStrings("u2.blk", f.file.str(f.file.stmt(d.top.analog[1].body).block.name));
}

test "§5.11 a disable inside a child names that child's flattened block" {
    // A.6.5 `disable` names an enclosing block, so it must be spelled as the
    // block's label is after the join, or lowering finds no such block.
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u(p); endmodule
        \\module kid(a); inout a; electrical a; parameter real g = 1.0;
        \\  analog begin : blk @(initial_step) disable blk; I(a) <+ g * V(a); end
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    const blk = f.file.stmt(d.top.analog[0].body).block;
    try std.testing.expectEqualStrings("u.blk", f.file.str(blk.name));
    const ev = f.file.stmt(blk.body[0]).event_control;
    try std.testing.expectEqual(blk.name, f.file.stmt(ev.body).disable.name);
}

test "§7.2.2 a child's discrete statements are copied whole: fork/join stays parallel, a repeat count is renamed" {
    // IEEE 1364-2005 §9.8.2 `fork ... join` starts every statement at once,
    // and §9.7.7's `repeat (n) @(...)` counts with the CHILD's `n`.
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u(p); endmodule
        \\module kid(a); inout a; electrical a; parameter integer n = 2; reg q, c;
        \\  initial fork q = 0; join
        \\  initial q = repeat (n) @(posedge c) 1;
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 2), d.top.discrete.len);
    try std.testing.expect(f.file.stmt(d.top.discrete[0].body).block.parallel);
    const count = f.file.stmt(d.top.discrete[1].body).assign.timing_repeat;
    try std.testing.expectEqualStrings("u.n", f.file.str(f.file.exprs.strOf(count)));
}

test "§4.7.1 a function's formal hides a module name for the function body only" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u(p); endmodule
        \\module kid(a); inout a; electrical a; parameter real x = 2.0;
        \\  analog function real fn; input x; real x; fn = x; endfunction
        \\  analog I(a) <+ fn(x) * V(a);
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    const ex = &f.file.exprs;
    const func = d.top.functions[0];
    try std.testing.expectEqualStrings("u.fn", f.file.str(func.name));
    // Inside, `x` is the formal; the return variable is the renamed function.
    const body = f.file.stmt(func.body).assign;
    try std.testing.expectEqualStrings("x", f.file.str(ex.strOf(body.value)));
    try std.testing.expectEqualStrings("u.fn", f.file.str(ex.strOf(body.target)));
    // Outside, `x` is the instance's parameter again.
    const call = ex.lhs(f.file.stmt(d.top.analog[0].body).contribute.rhs);
    try std.testing.expectEqualStrings("u.fn", f.file.str(ex.strOf(call)));
    try std.testing.expectEqualStrings("u.x", f.file.str(ex.strOf(ex.args(call)[0])));
}

test "§5.4.3 a child reading the flow into its own port is E0997; the top reading its own is not" {
    var bad: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer bad.deinit();
    try fixture.parse(&bad,
        \\module top(p); inout p; electrical p; kid u(p); endmodule
        \\module kid(a); inout a; electrical a; analog V(a) <+ I(<a>); endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(bad.ctx()));
    try std.testing.expect(fixture.hasCode(&bad.bag, .E0997));

    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good,
        \\module top(p); inout p; electrical p; kid u(p); analog V(p) <+ I(<p>); endmodule
        \\module kid(a); inout a; electrical a; analog V(a) <+ 0.0; endmodule
    );
    _ = try elaborate.elaborate(good.ctx());
}

test "§3.4.4 an array override must have the parameter's size (E0921)" {
    const src =
        \\module top(p); inout p; electrical p; kid #(.c('{{{s}}})) u(p); endmodule
        \\module kid(a); inout a; electrical a; parameter real c[0:1] = '{{0.0, 0.0}}; endmodule
    ;
    var bad: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer bad.deinit();
    try fixture.parse(&bad, try bad.arena.allocator().print(src, .{"1.0, 2.0, 3.0"}));
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(bad.ctx()));
    try std.testing.expect(fixture.hasCode(&bad.bag, .E0921));

    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good, try good.arena.allocator().print(src, .{"1.0, 2.0"}));
    _ = try elaborate.elaborate(good.ctx());
}
