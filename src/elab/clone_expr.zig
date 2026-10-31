//! The expression clone: one expression subtree of a child → new rows in
//! the flat namespace, renamed through the unit's map, with the per-instance
//! rewrites applied: §6.3.6 flow-probe division, §9.18/§9.19 answers,
//! §6.4.1 out-of-module references, IEEE 1364-2005 §12.6 upward names, and
//! §5.5.3 attribute disciplines. Rows are appended, never mutated, so the
//! child's source ids stay valid for its next instance.
//! Cites: LRM §4.4, §5.4.3, §5.5.3, §6.2.1, §6.3.6, §6.4.1, §6.6.2, §6.7,
//! §6.7.1, §6.8, §9.18, §9.19; IEEE 1364-2005 §12.6, §12.7.
//!
//! Contents:
//! - `pub fn cloneExpr(self: *Flatten, e: Ast.ExprId) design.Error!Ast.ExprId`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const paramset_dist = @import("paramset_dist.zig");
const flat_name = @import("flat_name.zig");
const lookup = @import("lookup.zig");
const primitive = @import("primitive.zig");
const access = @import("access.zig");
const fold = @import("fold.zig");
const hier_param = @import("hier_param.zig");

/// What `upward` made of a dotted name's first part.
const Upward = union(enum) {
    /// Not a scope of any enclosing unit: the name stays rooted at the top.
    keep,
    /// The flat name of the scope it found.
    head: Ast.StrId,
    /// The whole reference, a generate block's localparam, as its value.
    value: Ast.ExprId,
};

/// One if-generate scheme on the way down to a generate block: its
/// condition, negated in the else arm.
const GenCond = struct { cond: Ast.ExprId, negate: bool };

/// Copies one expression subtree into the store, renaming the names that
/// belong to the unit being inlined, and applies the per-instance rewrites
/// (§6.3.6 flow-probe division, §9.18/§9.19 answers, §6.4.1 references).
/// Rows are appended, never mutated, so the child's source ids stay valid
/// for its next instance.
pub fn cloneExpr(self: *Flatten, e: Ast.ExprId) design.Error!Ast.ExprId {
    if (e == .none) return .none;
    const x = &self.ctx.file.exprs;
    var n = x.get(e);
    var local_only = false;
    switch (n.tag) {
        // Literals and the two infinities carry no reference; the side-table
        // index in `extra` is shared, which is safe because `reals`/`ints`
        // are append-only too.
        .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf => {},
        .ident => n.str = flat_name.flat(self, n.str),
        .hier_ident => {
            if (try paramsetOomr(self, e)) |sub| return sub;
            // §6.7 a dotted name. Only the first part can be a local of this
            // unit, so renaming part 0 turns `u.gain` written inside a child
            // into the flat `mid.u.gain`; this is §6.2.1's "priority to the
            // local scope". A `$root` prefix names no unit, so it passes
            // through and `Lower.flatName` strips it.
            const parts = x.nameParts(e);
            var head = flat_name.flat(self, parts[0]);
            // §6.6.2 an unnamed generate block of this unit is no scope a name
            // may open; joined onto the unit's path, lowering refuses it by
            // name (E0998) instead of reading it from the top's namespace.
            if (!self.unit.rename.contains(parts[0])) {
                if (parts.len > 1 and self.unit.up != null and self.unit.module != null and
                    flat_name.namesUnnamedGen(self.ctx.file, self.unit.module.?, parts[0]))
                    head = try flat_name.join(self, self.unit.path, parts[0])
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
            if (!self.contrib_target) if (ownPortFlow(self, e)) |port| if (!ammetered(self, port)) {
                const access_name = self.ctx.file.str(n.str);
                try self.err(n.main_tok, .E0997, "`{s}` inside instance `{s}` reads the flow into its own port `{s}`; VerA sums that flow only for a module above it, as `{s}(<{s}{s}>)`", .{
                    access_name, self.unit.path[0 .. self.unit.path.len - 1], self.ctx.file.str(port), access_name, self.unit.path, self.ctx.file.str(port),
                });
                return x.addReal(self.ctx.arena, n.main_tok, 0.0);
            };
            // §4.4 `str` is the access function (`V`, `I`), not a name in
            // this unit; the terminals are `lhs`/`rhs`.
            n.lhs = try cloneExpr(self, x.lhs(e));
            n.rhs = try cloneExpr(self, x.rhs(e));
            if (self.unit.primitive) {
                n.str = primitive.primitiveAccess(self, n.str, n.lhs);
            } else {
                try access.checkTypedPort(self, n.str, x.lhs(e), n.main_tok);
                try access.checkTypedPort(self, n.str, x.rhs(e), n.main_tok);
                const a = try access.localAccess(self, n.str, x.lhs(e), n.lhs, n.main_tok);
                n.str = a.name;
                local_only = a.local_only;
            }
            // §6.3.6 rule 2: a flow probe inside a scaled instance reads
            // $mfactor copies' worth of flow, so the per-copy value is that
            // over $mfactor. Not the branch a `<+` drives (`contrib_target`).
            if (!self.contrib_target) {
                const probe = try self.ctx.file.exprs.add(self.ctx.arena, n);
                if (local_only) try self.out.local_accesses.put(self.ctx.arena, probe, {});
                return (try access.mfactorScale(self, probe, n.str, n.lhs, .div, n.main_tok)) orelse probe;
            }
        },
        .call => {
            // §4.7 a user function was renamed with the declarations.
            n.str = flat_name.flat(self, n.str);
            n.extra = try cloneArgs(self, x.args(e));
        },
        .sys_call => {
            if (try rewriteSysCall(self, e)) |lit| return lit;
            if (self.in_paramset) if (try paramset_dist.rewriteParamsetDist(self, e)) |out| return out;
            n.extra = try cloneArgs(self, x.args(e));
        },
        .builtin_call, .filter_call, .event_function, .concat, .assign_pattern => {
            n.extra = try cloneArgs(self, x.args(e));
        },
        // §6.3.6 rules 3 and 4 scale the noise power.
        .noise_call => {
            n.extra = try cloneArgs(self, x.args(e));
            return access.mfactorNoise(self, try self.ctx.file.exprs.add(self.ctx.arena, n));
        },
    }
    const out = try self.ctx.file.exprs.add(self.ctx.arena, n);
    if (local_only) try self.out.local_accesses.put(self.ctx.arena, out, {});
    // §5.5.3 reads the nature of the local net segment. Renaming a bound
    // port to its parent must not replace that segment's nature attributes.
    if (n.tag == .hier_ident) {
        const parts = x.nameParts(e);
        if (parts.len == 3) {
            const half = self.ctx.file.str(parts[1]);
            if (std.mem.eql(u8, half, "potential") or std.mem.eql(u8, half, "flow")) {
                if (self.unit.port_disc.get(parts[0])) |disc| {
                    try self.out.attribute_disciplines.put(self.ctx.arena, out, disc);
                } else if (self.unit.connected.contains(parts[0])) {
                    try self.res.pending_attributes.append(self.ctx.arena, .{
                        .expr = out,
                        .net = flat_name.flat(self, parts[0]),
                        .path = self.unit.path,
                    });
                }
            }
        }
    }
    return out;
}

// ---- private ----

pub inline fn cloneArgs(self: *Flatten, src: []const Ast.ExprId) design.Error!u32 {
    const out = try self.ctx.arena.alloc(Ast.ExprId, src.len);
    for (src, out) |s, *o| o.* = try cloneExpr(self, s);
    return self.ctx.file.exprs.addExprList(self.ctx.arena, out);
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
fn paramsetOomr(self: *Flatten, e: Ast.ExprId) design.Error!?Ast.ExprId {
    if (!self.in_paramset) return null;
    const parts = self.ctx.file.exprs.nameParts(e);
    if (parts.len != 2) return null;
    const m = lookup.findModule(self, parts[0]) orelse return null;
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

/// §6.7.1 adopts IEEE 1364-2005 12.6 for `scope_name.item_name`: look in the
/// current scope, then "in the parent module's outermost scope", and "repeat
/// step b), going up the hierarchy". §6.8 says the same of generate blocks
/// (12.7: "searched first at the current level and then in higher level
/// modules until found"). `parts[0]` is not a name the unit binds; this
/// walks the unit and the units above it (`Unit.up`) for a module instance
/// (12.6 restricts scope_name to a hierarchical_inst_identifier) or a named
/// generate block of that name, nearest first.
fn upward(self: *Flatten, e: Ast.ExprId, parts: []const Ast.StrId) design.Error!Upward {
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

/// The named generate block `name` under statement `id`, with the
/// if-generate schemes that select it appended to `conds`. A block inside a
/// loop generate is `name[i]` (§6.6.1) and a case arm's needs its selector
/// matched, so neither is found here.
fn genBlock(self: *Flatten, id: Ast.StmtId, name: Ast.StrId, conds: *std.ArrayList(GenCond)) design.Error!?Ast.SeqBlock {
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
    assert(conds.items.len == depth);
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
fn genBlockRef(self: *Flatten, e: Ast.ExprId, u: *const Flatten.Unit, b: Ast.SeqBlock, conds: []const GenCond, parts: []const Ast.StrId) design.Error!Upward {
    const saved = self.unit;
    self.unit = u.*;
    defer self.unit = saved;
    for (conds) |c| {
        const v = fold.constValue(self, c.cond, true, null);
        if (v != null and v.?.isTrue() != c.negate) continue;
        try self.err(self.ctx.file.exprs.mainTok(e), .E0901, "`{s}` is a generate block its scheme does not select (§6.6.2)", .{self.ctx.file.str(parts[0])});
        return .keep;
    }
    const flat_head: Upward = if (u.up == null) .keep else .{ .head = try flat_name.join(self, u.path, parts[0]) };
    if (parts.len != 2) return flat_head;
    const p = for (b.params) |*q| {
        if (q.name == parts[1] and q.dims.len == 0) break q;
    } else return flat_head;
    for (b.params) |q| if (readsName(self.ctx.file, p.default, q.name)) return flat_head;
    if (p.ty == .integer) {
        const v = fold.constValue(self, p.default, true, null) orelse return flat_head;
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

/// §5.4.3 whether the walk split this unit's `port` onto an internal net of
/// its own (`design.Design.port_ammeters`), so its flow is a probe lowering reads.
fn ammetered(self: *Flatten, port: Ast.StrId) bool {
    const flat = self.unit.rename.get(port) orelse return false;
    const name = self.ctx.file.str(flat);
    for (self.out.port_ammeters.items) |am| if (std.mem.eql(u8, am.internal, name)) return true;
    return false;
}

/// Ch9 functions whose answer is a property of the instantiation. §9.19 `$port_connected` and
/// `$param_given` must be answered here: after the flatten a connected port
/// is the parent's net and nothing downstream can tell the two apart. §9.18
/// hierarchical values are the expressions `collectOverrides` composed.
fn rewriteSysCall(self: *Flatten, e: Ast.ExprId) design.Error!?Ast.ExprId {
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

const fixture = @import("fixture.zig");

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

test "§5.4.3 a child reading the flow into its own port gets a net of its own; the top reading its own does not" {
    // The read port is split off the parent's net (`design.Design.port_ammeters`),
    // so the flow into it is the branch between the two; the top's port is
    // the host's, its `I(<p>)` its own exact unknown.
    var own: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer own.deinit();
    try fixture.parse(&own,
        \\module top(p); inout p; electrical p; kid u(p); endmodule
        \\module kid(a); inout a; electrical a; analog V(a) <+ I(<a>); endmodule
    );
    const d = try elaborate.elaborate(own.ctx());
    try std.testing.expectEqual(@as(usize, 1), d.port_ammeters.len);
    try std.testing.expectEqualStrings("u.a", d.port_ammeters[0].internal);
    try std.testing.expectEqualStrings("p", d.port_ammeters[0].bound);

    var good: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer good.deinit();
    try fixture.parse(&good,
        \\module top(p); inout p; electrical p; kid u(p); analog V(p) <+ I(<p>); endmodule
        \\module kid(a); inout a; electrical a; analog V(a) <+ 0.0; endmodule
    );
    try std.testing.expectEqual(@as(usize, 0), (try elaborate.elaborate(good.ctx())).port_ammeters.len);
}
