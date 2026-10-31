//! §6.6 generate constructs → module instances: a generate block's instance
//! list with each instance renamed through its scopes (§6.6.3), the scheme
//! that brings it into existence, and a loop generate's copies one per genvar
//! value (§6.6.1). Also the expression rewrites the copies need (an
//! identifier replaced by a value).
//! Cites: LRM §6.6, §6.6.1, §6.6.2, §6.6.3, §6.9.2; IEEE 1364-2005 §12.4.3.
//!
//! Contents:
//! - `pub fn genInstanceList(file: *Ast.SourceFile, id: Ast.StmtId, arena: std.mem.Allocator, out: *std.ArrayList(Ast.Instance)) design.Error!void`
//! - `pub fn genvarLoop(comptime T: type, scheme: anytype, first: T) !LoopRun(T)`
//! - `pub fn substIdent(self: *Flatten, e: Ast.ExprId, name: Ast.StrId, with: Ast.ExprId) design.Error!Ast.ExprId`
//! -     `pub fn ident(sb: @This(), _: *Flatten, id: Ast.ExprId, n: Ast.StrId) design.Error!Ast.ExprId`
//! - `pub fn genInstances(self: *Flatten, id: Ast.StmtId, gate: Ast.ExprId, prefix: []const u8, locals: []const Ast.ParamDecl, out: *std.ArrayList(Ast.Instance), gates: *std.ArrayList(Ast.ExprId)) design.Error!void`
//! - `pub fn conj(self: *Flatten, a: Ast.ExprId, c: Ast.ExprId, negate: bool) design.Error!Ast.ExprId`
//! -     `pub fn ident(b: @This(), fl: *Flatten, id: Ast.ExprId, name: Ast.StrId) design.Error!Ast.ExprId`
//! -     `pub fn holds(sc: @This(), at: i64) design.Error!?bool`
//! -     `pub fn next(sc: @This(), at: i64) design.Error!?i64`
//! -     `pub fn same(a: i64, b: i64) bool`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const clone_expr = @import("clone_expr.zig");
const fold = @import("fold.zig");
const sep = design.sep;
const fixture = @import("fixture.zig");

/// Appends to `out` every module instance in a generate block under `id`
/// (§6.6), schemes aside, each renamed into its enclosing generate scopes
/// (`blockPrefix`); the names are interned and allocated in `arena`.
pub fn genInstanceList(file: *Ast.SourceFile, id: Ast.StmtId, arena: std.mem.Allocator, out: *std.ArrayList(Ast.Instance)) design.Error!void {
    try genInstanceListIn(file, id, arena, "", out);
}

/// §6.6.1 "It shall be an error if the loop does not terminate" and "if a
/// genvar value is repeated during evaluation of the loop". The genvar is
/// the scheme's whole state (§3.5: the step reads only it, parameters and
/// enclosing genvars, all fixed while it runs), so the scheme either ends
/// or repeats a value, and a §3.2 integer genvar has 2^32 values to repeat.
/// Brent's cycle detection finds the repeat with O(1) memory in at most
/// about three times the iterations before it, so no count stands in for
/// the answer: every loop that ends is reported as ending, however long.
/// `scheme` folds: `holds(v) !?bool` (the condition at genvar value `v`),
/// `next(v) !?T` (the step's value), and `same(a, b) bool`.
pub fn genvarLoop(comptime T: type, scheme: anytype, first: T) !LoopRun(T) {
    var tortoise = first;
    var hare = first;
    var power: u64 = 1;
    var lam: u64 = 0;
    var n: u64 = 0;
    while (true) {
        if (!((try scheme.holds(hare)) orelse return .unfolded)) return .{ .ends = n };
        hare = (try scheme.next(hare)) orelse return .unfolded;
        n += 1;
        lam += 1;
        if (@TypeOf(scheme).same(hare, tortoise)) return .{ .repeats = hare };
        assert(n != std.math.maxInt(u64)); // every scheme ends or repeats long before
        if (lam == power) {
            tortoise = hare;
            power *|= 2;
            lam = 0;
        }
        assert(lam < power); // Brent: the hare is less than one power ahead
    }
}

/// `e` with every identifier `name` replaced by `with`; rows unchanged where
/// nothing below them changed.
pub fn substIdent(self: *Flatten, e: Ast.ExprId, name: Ast.StrId, with: Ast.ExprId) design.Error!Ast.ExprId {
    const Subst = struct {
        name: Ast.StrId,
        with: Ast.ExprId,
        pub fn ident(sb: @This(), _: *Flatten, id: Ast.ExprId, n: Ast.StrId) design.Error!Ast.ExprId {
            return if (n == sb.name) sb.with else id;
        }
    };
    return mapIdents(self, e, Subst{ .name = name, .with = with });
}

/// §6.6 appends a generate block's module instances to `out` and, in
/// parallel, the scheme that brings each into existence to `gates`, cloned
/// into this unit's flat namespace.
/// "At most one generate block instantiated from a set of alternatives":
/// an if-generate's arms are gated `c` and `!c`, and `inlineInstance`
/// lowers each child's analog blocks under its gate. `checkGenScheme`
/// marks the parameters as shape parameters, so a host card cannot change
/// the arm selected by their final compile-time values.
/// A loop generate's instances are `loopInstances`'s.
/// ponytail: a case generate's instance is E0235 (`refuseGen`): it needs an
/// equality chain per arm.
/// `prefix` names the generate scopes enclosing `id` (`blockPrefix`);
/// `locals` are their localparams, outermost first (`bindGenLocals`).
pub fn genInstances(self: *Flatten, id: Ast.StmtId, gate: Ast.ExprId, prefix: []const u8, locals: []const Ast.ParamDecl, out: *std.ArrayList(Ast.Instance), gates: *std.ArrayList(Ast.ExprId)) design.Error!void {
    if (id == .none) return;
    // `out` and `gates` grow together: one scheme per generate instance.
    assert(out.items.len >= gates.items.len);
    const lead = out.items.len - gates.items.len;
    switch (self.ctx.file.stmt(id)) {
        .block => |b| {
            const inner = try blockPrefix(self.ctx.file, self.ctx.arena, prefix, b);
            const inner_locals = if (b.params.len == 0) locals else try std.mem.concat(self.ctx.arena, Ast.ParamDecl, &.{ locals, b.params });
            for (b.instances) |inst| {
                var bound = try scoped(self.ctx.file, self.ctx.arena, inner, inst);
                if (inner_locals.len != 0) {
                    const params = try self.ctx.arena.dupe(Ast.ParamOverride, inst.params);
                    for (params) |*o| o.value = try bindGenLocals(self, o.value, inner_locals);
                    bound.params = params;
                }
                try out.append(self.ctx.arena, bound);
            }
            try gates.appendNTimes(self.ctx.arena, gate, b.instances.len);
            for (b.body) |s| try genInstances(self, s, gate, inner, inner_locals, out, gates);
        },
        .if_stmt => |s| if (s.is_generate) {
            const c = try clone_expr.cloneExpr(self, s.cond);
            try genInstances(self, s.then_s, try conj(self, gate, c, false), prefix, locals, out, gates);
            try genInstances(self, s.else_s, try conj(self, gate, c, true), prefix, locals, out, gates);
        },
        .for_stmt => |s| try loopInstances(self, s.init, s.cond, s.step, s.body, gate, prefix, locals, out, gates),
        .case_stmt => |s| for (s.arms) |a| try refuseGen(self, a.body),
        else => {}, // else: no other statement holds a generate block
    }
    assert(out.items.len - gates.items.len == lead);
}

/// `a && c` (or `a && !c`), `a` = `.none` meaning true.
pub fn conj(self: *Flatten, a: Ast.ExprId, c: Ast.ExprId, negate: bool) design.Error!Ast.ExprId {
    const ex = &self.ctx.file.exprs;
    const tok = ex.mainTok(c);
    const t = if (!negate) c else try ex.add(self.ctx.arena, .{
        .tag = .unary,
        .main_tok = tok,
        .lhs = c,
        .extra = @backingInt(Ast.UnaryOp.logical_not),
    });
    if (a == .none) return t;
    return ex.add(self.ctx.arena, .{
        .tag = .binary,
        .main_tok = tok,
        .lhs = a,
        .rhs = t,
        .extra = @backingInt(Ast.BinaryOp.logical_and),
    });
}

// ---- private ----

/// How a §6.6.1 loop generate scheme runs, followed from its first genvar
/// value without its body: it `ends` after that many iterations, it
/// `repeats` a value with the condition true and so never ends, or it is
/// `unfolded`: the condition or step did not fold at some iteration, which
/// the unroll then reports.
fn LoopRun(comptime T: type) type {
    return union(enum) { ends: u64, repeats: T, unfolded };
}

fn genInstanceListIn(file: *Ast.SourceFile, id: Ast.StmtId, arena: std.mem.Allocator, prefix: []const u8, out: *std.ArrayList(Ast.Instance)) design.Error!void {
    if (id == .none) return;
    switch (file.stmt(id)) {
        .block => |b| {
            const inner = try blockPrefix(file, arena, prefix, b);
            for (b.instances) |inst| try out.append(arena, try scoped(file, arena, inner, inst));
            for (b.body) |s| try genInstanceListIn(file, s, arena, inner, out);
        },
        .if_stmt => |s| {
            try genInstanceListIn(file, s.then_s, arena, prefix, out);
            try genInstanceListIn(file, s.else_s, arena, prefix, out);
        },
        .for_stmt => |s| try genInstanceListIn(file, s.body, arena, prefix, out),
        .case_stmt => |s| for (s.arms) |a| try genInstanceListIn(file, a.body, arena, prefix, out),
        else => {}, // else: no other statement holds a generate block
    }
}

/// §6.6.3 / IEEE 1364-2005 §12.4.3: a generate block is a scope, so an
/// instance in `g1` is `g1.u`, and one in an unnamed block is
/// `genblk<n>.u` for external interfaces (`Ast.SeqBlock.gen_name`). Two
/// blocks may each hold a `u`. The prefix of the blocks enclosing `b`, plus
/// `b`'s own name when it is a generate scope.
fn blockPrefix(file: *Ast.SourceFile, arena: std.mem.Allocator, prefix: []const u8, b: Ast.SeqBlock) design.Error![]const u8 {
    if (b.gen_name == .none) return prefix;
    return arena.print("{s}{s}{c}", .{ prefix, file.str(b.gen_name), sep });
}

/// `inst` named inside the generate scope `prefix` (see `blockPrefix`). The
/// flat path joins on `sep`, so `g1.u` is the instance's hierarchical name.
fn scoped(file: *Ast.SourceFile, arena: std.mem.Allocator, prefix: []const u8, inst: Ast.Instance) design.Error!Ast.Instance {
    if (prefix.len == 0) return inst;
    var out = inst;
    out.name = try file.intern(arena, try arena.print("{s}{s}", .{ prefix, file.str(inst.name) }));
    return out;
}

/// §6.6.2 a generate block's localparams are declared in the block's scope,
/// so an instance's `#(...)` written there may read them, and §6.9.2 selects
/// a paramset only once "the generate construct has been evaluated", with
/// the values the block supplies. The flatten keeps an override in the
/// instantiating module's names, where a block localparam does not exist, so
/// each identifier in `e` naming one of `locals` (the innermost, latest
/// declared, when several share a name) is replaced by that localparam's
/// value expression, itself read in the scope it was declared in. The
/// result is still in the module's names and depends on the module's
/// parameters as the localparam did.
/// ponytail: the localparam's declared type is not applied to the
/// substituted value; the receiving parameter's type converts it.
fn bindGenLocals(self: *Flatten, e: Ast.ExprId, locals: []const Ast.ParamDecl) design.Error!Ast.ExprId {
    const Bind = struct {
        locals: []const Ast.ParamDecl,
        pub fn ident(b: @This(), fl: *Flatten, id: Ast.ExprId, name: Ast.StrId) design.Error!Ast.ExprId {
            var k = b.locals.len;
            while (k > 0) {
                k -= 1;
                if (b.locals[k].name == name and b.locals[k].dims.len == 0) return bindGenLocals(fl, b.locals[k].default, b.locals[0..k]);
            }
            return id;
        }
    };
    return mapIdents(self, e, Bind{ .locals = locals });
}

/// `e` with each identifier row replaced by `ctx.ident(self, row, name)`'s
/// answer; rows unchanged where nothing below them changed, so a rewrite
/// that touches nothing appends nothing.
fn mapIdents(self: *Flatten, e: Ast.ExprId, ctx: anytype) design.Error!Ast.ExprId {
    if (e == .none) return e;
    const x = &self.ctx.file.exprs;
    var n = x.get(e);
    switch (n.tag) {
        .ident => return ctx.ident(self, e, n.str),
        .unary => {
            n.lhs = try mapIdents(self, x.lhs(e), ctx);
            if (n.lhs == x.lhs(e)) return e;
        },
        .binary, .index, .range, .indexed_range, .multi_concat, .pattern_repl => {
            n.lhs = try mapIdents(self, x.lhs(e), ctx);
            n.rhs = try mapIdents(self, x.rhs(e), ctx);
            if (n.lhs == x.lhs(e) and n.rhs == x.rhs(e)) return e;
        },
        .ternary => {
            const third = x.ternaryElse(e);
            n.lhs = try mapIdents(self, x.lhs(e), ctx);
            n.rhs = try mapIdents(self, x.rhs(e), ctx);
            const t = try mapIdents(self, third, ctx);
            if (n.lhs == x.lhs(e) and n.rhs == x.rhs(e) and t == third) return e;
            n.extra = @backingInt(t);
        },
        .call, .sys_call, .builtin_call, .concat, .assign_pattern => {
            const src = x.args(e);
            const args = try self.ctx.arena.alloc(Ast.ExprId, src.len);
            var changed = false;
            for (src, args) |a, *o| {
                o.* = try mapIdents(self, a, ctx);
                changed = changed or o.* != a;
            }
            if (!changed) return e;
            n.extra = try x.addExprList(self.ctx.arena, args);
        },
        else => return e, // else: literals, dotted names and the analog-only forms hold no identifier a generate override or connection reads
    }
    return x.add(self.ctx.arena, n);
}

/// §6.6.1 a loop generate's module instances, one set per iteration. The
/// genvar is "an integer parameter" in each generate block instance, "the
/// value of the index variable at the time the instance was elaborated", so
/// each copy's overrides and connections read it as a literal, and the copy
/// is named `blk[i].inst` (§6.6.1, §6.6.3) inside the enclosing scopes
/// `prefix`. An override reads the localparams of those scopes and of the
/// loop's block (`bindGenLocals`, before the genvar is bound, so a
/// localparam computed from the genvar takes this iteration's value).
/// §6.9.2's paramset selection then sees those values. The scheme folds in the module's names; one that does
/// not fold, or never ends (`genvarLoop`), yields no instances here, and
/// lowering's unroll of the same loop reports why (E0417-E0420, E0486).
///
/// ponytail: instances written directly in the loop's block only. One under
/// a nested generate scheme or block is E0235; the upgrade is recursing
/// through `genInstances` with the genvar bound.
fn loopInstances(self: *Flatten, init: Ast.StmtId, cond: Ast.ExprId, step: Ast.StmtId, body: Ast.StmtId, gate: Ast.ExprId, prefix: []const u8, locals: []const Ast.ParamDecl, out: *std.ArrayList(Ast.Instance), gates: *std.ArrayList(Ast.ExprId)) design.Error!void {
    const file = self.ctx.file;
    var all: std.ArrayList(Ast.Instance) = .empty;
    try genInstanceList(file, body, self.ctx.arena, &all);
    if (all.items.len == 0) return;
    const blk = if (body != .none and file.stmt(body) == .block) file.stmt(body).block else return refuseGen(self, body);
    if (blk.gen_name == .none) return refuseGen(self, body);
    if (blk.instances.len != all.items.len) {
        for (all.items[blk.instances.len..]) |inst| try self.err(inst.main_tok, .E0235, "a module instance under a generate scheme nested in a loop generate", .{});
        return;
    }
    if (init == .none or step == .none or file.stmt(init) != .assign or file.stmt(step) != .assign) return;
    const gv_e = file.stmt(init).assign.target;
    if (file.exprs.tag(gv_e) != .ident) return;
    const gv = file.exprs.strOf(gv_e);
    const inner_locals = if (blk.params.len == 0) locals else try std.mem.concat(self.ctx.arena, Ast.ParamDecl, &.{ locals, blk.params });
    var v = (try constGenvar(self, file.stmt(init).assign.value, gv, null)) orelse return;
    const Scheme = struct {
        self: *Flatten,
        gv: Ast.StrId,
        cond: Ast.ExprId,
        step: Ast.ExprId,
        fn lit(sc: @This(), at: i64) design.Error!Ast.ExprId {
            const x = &sc.self.ctx.file.exprs;
            return x.addInt(sc.self.ctx.arena, x.mainTok(sc.cond), at);
        }
        pub fn holds(sc: @This(), at: i64) design.Error!?bool {
            const c = fold.constValue(sc.self, try substIdent(sc.self, sc.cond, sc.gv, try sc.lit(at)), true, null) orelse return null;
            return c.isTrue();
        }
        pub fn next(sc: @This(), at: i64) design.Error!?i64 {
            return constGenvar(sc.self, sc.step, sc.gv, try sc.lit(at));
        }
        pub fn same(a: i64, b: i64) bool {
            return a == b;
        }
    };
    const scheme: Scheme = .{ .self = self, .gv = gv, .cond = cond, .step = file.stmt(step).assign.value };
    const run = try genvarLoop(i64, scheme, v);
    if (run != .ends) return;
    // `genvarLoop` ran this scheme to its end: as many copies as it counted.
    var copies: u64 = 0;
    while (true) : (copies += 1) {
        assert(copies <= run.ends);
        const lit = try scheme.lit(v);
        if (!(try scheme.holds(v)).?) {
            assert(copies == run.ends);
            return;
        }
        for (blk.instances) |inst| {
            var copy = inst;
            copy.name = try file.intern(self.ctx.arena, try self.ctx.arena.print("{s}{s}[{d}]{c}{s}", .{ prefix, file.str(blk.gen_name), v, sep, file.str(inst.name) }));
            const params = try self.ctx.arena.dupe(Ast.ParamOverride, inst.params);
            for (params) |*o| o.value = try substIdent(self, try bindGenLocals(self, o.value, inner_locals), gv, lit);
            copy.params = params;
            const ports = try self.ctx.arena.dupe(Ast.PortConn, inst.ports);
            for (ports) |*pc| pc.expr = try substIdent(self, pc.expr, gv, lit);
            copy.ports = ports;
            try out.append(self.ctx.arena, copy);
            try gates.append(self.ctx.arena, gate);
        }
        v = (try scheme.next(v)).?;
    }
}

/// A genvar assignment's value, folded in the module's names with the genvar
/// at `at` (null for the initialization), or null when it is no integer.
fn constGenvar(self: *Flatten, e: Ast.ExprId, gv: Ast.StrId, at: ?Ast.ExprId) design.Error!?i64 {
    const bound = if (at) |lit| try substIdent(self, e, gv, lit) else e;
    const c = fold.constValue(self, bound, true, null) orelse return null;
    return if (c == .int) c.int else null;
}

fn refuseGen(self: *Flatten, id: Ast.StmtId) design.Error!void {
    var all: std.ArrayList(Ast.Instance) = .empty;
    try genInstanceList(self.ctx.file, id, self.ctx.arena, &all);
    for (all.items) |inst| try self.err(inst.main_tok, .E0235, "a module instance in a loop or case generate", .{});
}

test genvarLoop {
    // f(v) = (v + 1) % m from 0 under `v < lim`: the scheme of
    // `for (i = 0; i < lim; i = (i + 1) % m)`.
    const Mod = struct {
        m: i64,
        lim: i64,
        pub fn holds(sc: @This(), v: i64) error{}!?bool {
            return v < sc.lim;
        }
        pub fn next(sc: @This(), v: i64) error{}!?i64 {
            return @mod(v + 1, sc.m);
        }
        pub fn same(a: i64, b: i64) bool {
            return a == b;
        }
    };
    // Ends at exactly the old 4096 cap, one past it, and far past it.
    for ([_]i64{ 4096, 4097, 1 << 20 }) |lim| {
        const r = try genvarLoop(i64, Mod{ .m = std.math.maxInt(i64), .lim = lim }, 0);
        try std.testing.expectEqual(LoopRun(i64){ .ends = @intCast(lim) }, r);
    }
    // Never ends: every cycle length, short and long, is a repeat.
    for ([_]i64{ 1, 2, 3, 4096, 4097, 100_000 }) |m| {
        const r = try genvarLoop(i64, Mod{ .m = m, .lim = m }, 0);
        try std.testing.expect(r == .repeats);
        try std.testing.expect(r.repeats >= 0 and r.repeats < m);
    }
}

test substIdent {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, "module top; endmodule");
    var fl = try fixture.flatten(&f);
    const a = f.arena.allocator();
    const x = &f.file.exprs;
    const na = try f.file.intern(a, "a");
    const nb = try f.file.intern(a, "b");
    const nc = try f.file.intern(a, "c");
    const ea = try x.add(a, .{ .tag = .ident, .str = na });
    const eb = try x.add(a, .{ .tag = .ident, .str = nb });
    const sum = try x.add(a, .{ .tag = .binary, .lhs = ea, .rhs = eb, .extra = @backingInt(Ast.BinaryOp.add) });
    const seven = try x.addInt(a, 0, 7);
    // Nothing named `c` below: the same row, and no row appended.
    const rows = x.nodes.len;
    try std.testing.expectEqual(sum, try substIdent(&fl, sum, nc, seven));
    try std.testing.expectEqual(rows, x.nodes.len);
    // A replaced operand gets a new row over the operand left alone.
    const out = try substIdent(&fl, sum, na, seven);
    try std.testing.expect(out != sum);
    try std.testing.expectEqual(Ast.BinaryOp.add, x.binOp(out));
    try std.testing.expectEqual(seven, x.lhs(out));
    try std.testing.expectEqual(eb, x.rhs(out));
}

test "§6.6.2 bindGenLocals reads the innermost localparam, in the scope it was declared in" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, "module top; endmodule");
    var fl = try fixture.flatten(&f);
    const a = f.arena.allocator();
    const x = &f.file.exprs;
    const k = try f.file.intern(a, "k");
    const one = try x.addInt(a, 0, 1);
    const two = try x.addInt(a, 0, 2);
    const ek = try x.add(a, .{ .tag = .ident, .str = k });
    const ek_inner = try x.add(a, .{ .tag = .ident, .str = k });
    // Two blocks each declare `k`: the inner (later) one wins.
    const shadow = [_]Ast.ParamDecl{
        .{ .name = k, .ty = .integer, .default = one },
        .{ .name = k, .ty = .integer, .default = two },
    };
    try std.testing.expectEqual(two, try bindGenLocals(&fl, ek, &shadow));
    // The inner `k = k` reads the outer `k`, where it was declared.
    const nested = [_]Ast.ParamDecl{
        .{ .name = k, .ty = .integer, .default = one },
        .{ .name = k, .ty = .integer, .default = ek_inner },
    };
    try std.testing.expectEqual(one, try bindGenLocals(&fl, ek, &nested));
    // An array localparam is no scalar value to substitute.
    const array = [_]Ast.ParamDecl{.{ .name = k, .ty = .integer, .default = one, .dims = &.{.{ .msb = one, .lsb = one }} }};
    try std.testing.expectEqual(ek, try bindGenLocals(&fl, ek, &array));
}

test "§6.6 conj builds a generate block's gate: the scheme alone, negated, or under an enclosing one" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f, "module top; endmodule");
    var fl = try fixture.flatten(&f);
    const a = f.arena.allocator();
    const x = &f.file.exprs;
    const c = try x.add(a, .{ .tag = .ident, .str = try f.file.intern(a, "c") });
    const g = try x.add(a, .{ .tag = .ident, .str = try f.file.intern(a, "g") });
    try std.testing.expectEqual(c, try conj(&fl, .none, c, false));
    const not_c = try conj(&fl, .none, c, true);
    try std.testing.expectEqual(Ast.UnaryOp.logical_not, x.unOp(not_c));
    try std.testing.expectEqual(c, x.lhs(not_c));
    const both = try conj(&fl, g, c, true);
    try std.testing.expectEqual(Ast.BinaryOp.logical_and, x.binOp(both));
    try std.testing.expectEqual(g, x.lhs(both));
    try std.testing.expectEqual(Ast.UnaryOp.logical_not, x.unOp(x.rhs(both)));
}

test "§6.6.1 a loop generate that never ends or does not fold inlines nothing and leaves the diagnostic to the unroll" {
    for ([_][]const u8{
        "for (i = 0; i < 2; i = i)", // repeats 0 forever
        "for (i = 0; i < 2; i = i + r)", // the step reads a real variable
    }) |scheme| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(
            \\module top(p); inout p; electrical p; genvar i; real r;
            \\  generate {s} begin : blk kid u(p); end endgenerate
            \\endmodule
            \\module kid(a); inout a; electrical a; analog I(a) <+ V(a); endmodule
        , .{scheme}));
        const d = try elaborate.elaborate(f.ctx());
        try std.testing.expectEqual(@as(usize, 1), d.units.len);
    }
}

test "§6.6.3 an instance in a named generate block is named through the block; an unnamed one through genblk<n>" {
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p;
        \\  generate if (1) begin : g1 kid u(p); end endgenerate
        \\  generate if (1) begin kid v(p); end endgenerate
        \\endmodule
        \\module kid(a); inout a; electrical a; analog I(a) <+ V(a); endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 3), d.units.len);
    try std.testing.expectEqualStrings("g1.u.", d.units.items(.path)[1]);
    try std.testing.expect(std.mem.startsWith(u8, d.units.items(.path)[2], "genblk"));
    try std.testing.expect(std.mem.endsWith(u8, d.units.items(.path)[2], ".v."));
}
