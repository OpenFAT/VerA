//! Constant folding in the flat namespace: an expression (local or flat
//! names) → its constant value, read from the parameters flattened so far,
//! with each flat parameter's value cached in parameter order so a chain of
//! defaults folds on the stack one default's depth needs.
//! Cites: LRM §3.4, §6.2.2, §6.4.2, §6.6.2.
//!
//! Contents:
//! - `pub const Cache = struct`
//! - `pub const ParamValue = union(enum)`
//! - `pub const ParamEnv = struct`
//! -   `pub fn leaf(env: ParamEnv, e: Ast.ExprId) ?constfold.Const`
//! -   `pub fn signed(_: ParamEnv, _: Ast.ExprId) ?bool`
//! -   `pub fn width(_: ParamEnv, _: Ast.ExprId) ?u32`
//! - `pub fn constInt(self: *Flatten, e: Ast.ExprId) ?i64`
//! - `pub fn constIntFlat(self: *Flatten, e: Ast.ExprId) ?i64`
//! - `pub fn gateHolds(self: *Flatten, gate: Ast.ExprId) bool`
//! - `pub fn constValue(self: *Flatten, e: Ast.ExprId, local: bool, reads: ?[]bool) ?constfold.Const`
//! - `pub fn syncParamValues(self: *Flatten) design.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const flat_name = @import("flat_name.zig");
const fixture = @import("fixture.zig");

/// `Flatten.folds`: each flat parameter's folded value, one row per
/// `Flatten.decls.params` row (`syncParamValues`), how many leading rows are
/// folded, and each flat name → its first scalar row, so a fold's identifier
/// is one lookup, not a scan of every flat parameter.
pub const Cache = struct {
    values: std.ArrayList(ParamValue) = .empty,
    warm: usize = 0,
    index: std.AutoHashMapUnmanaged(Ast.StrId, u32) = .empty,
};

/// One `Flatten.param_values` row: a flat parameter's folded value, once
/// one is known. A default that does not fold is not remembered, since a
/// parameter appended later may make it fold.
pub const ParamValue = union(enum) { unknown, folding, done: constfold.Const };

/// `constfold.fold`'s identifiers, answered from the parameters flattened so
/// far. The bound is written in the instantiating module's local names, while
/// every value in `self.decls.params` is already flat, so only the first lookup
/// renames. A scalar parameter only; anything else declines.
pub const ParamEnv = struct {
    self: *Flatten,
    local: bool,
    depth: u8 = 0,
    reads: ?[]bool = null,

    /// Resolves an identifier to a flattened scalar parameter's folded value.
    /// Asserts that `reads`, when given, has one flag per flattened parameter.
    pub fn leaf(env: ParamEnv, e: Ast.ExprId) ?constfold.Const {
        const self = env.self;
        // `matchingParamsets` sizes it so, and zips it with `params` after.
        if (env.reads) |reads| assert(reads.len == self.decls.params.items.len);
        const ex = &self.ctx.file.exprs;
        // ponytail: a depth cap, not cycle detection; a cyclic default is
        // lowering's diagnostic, this only has to terminate.
        if (ex.tag(e) != .ident or env.depth > 32) return null;
        const name = if (env.local) flat_name.flat(self, ex.strOf(e)) else ex.strOf(e);
        const i = self.folds.index.get(name) orelse return null;
        // ponytail: a fold that records `reads` (§6.4.2 overload choice)
        // is not cached, so its chain of defaults still nests on the
        // stack; the upgrade is caching each parameter's read set.
        if (env.reads) |reads| {
            reads[i] = true;
            return env.param(i);
        }
        return paramValue(self, i, env.depth);
    }

    /// Flat parameter `i`'s value: a `--param` card value, else its default
    /// folded with the parameters before it.
    fn param(env: ParamEnv, i: usize) ?constfold.Const {
        const self = env.self;
        const p = self.decls.params.items[i];
        if (!p.is_local and p.ty != .string) for (self.ctx.param_overrides) |o| {
            if (!std.mem.eql(u8, o.name, self.ctx.file.str(p.name)) or std.math.isNan(o.value)) continue;
            // The replaced default supplies an inferred TYPE only. Its
            // former value dependencies cannot change this card binding
            // and must not freeze unrelated host fields as shape inputs.
            const declared = if (p.ty == .unspecified)
                constfold.fold(self.ctx.file, p.default, ParamEnv{ .self = self, .local = false, .depth = env.depth + 1 })
            else
                null;
            return constfold.parameterCardValue(p.ty, declared, o.value);
        };
        const declared = constfold.fold(self.ctx.file, p.default, ParamEnv{ .self = self, .local = false, .depth = env.depth + 1, .reads = env.reads }) orelse return null;
        return constfold.parameterValue(p.ty, declared);
    }

    /// Leaves operand signedness unknown.
    pub fn signed(_: ParamEnv, _: Ast.ExprId) ?bool {
        return null;
    }
    /// Leaves a parameter's width unknown.
    pub fn width(_: ParamEnv, _: Ast.ExprId) ?u32 {
        return null;
    }
};

/// Folds a §6.2.2 instance array bound, written in the current unit's local
/// names, to an integer; null when it does not fold or is real. A bound may
/// read a parameter (§3.4), with this instance's overrides applied.
pub fn constInt(self: *Flatten, e: Ast.ExprId) ?i64 {
    const c = constfold.fold(self.ctx.file, e, ParamEnv{ .self = self, .local = true }) orelse return null;
    return if (c == .int) c.int else null;
}

/// `constInt` for an expression already in the flat namespace (a cloned
/// declaration's range, say), so no name is renamed.
pub fn constIntFlat(self: *Flatten, e: Ast.ExprId) ?i64 {
    const c = constfold.fold(self.ctx.file, e, ParamEnv{ .self = self, .local = false }) orelse return null;
    return if (c == .int) c.int else null;
}

/// §6.6.2 whether the generate scheme `gate` (flat names, `.none` for an
/// instance outside any scheme) brings its instance into existence: it folds
/// true. One that does not fold is not known to.
pub fn gateHolds(self: *Flatten, gate: Ast.ExprId) bool {
    if (gate == .none) return true;
    const c = constValue(self, gate, false, null) orelse return false;
    return c.isTrue();
}

/// §6.4.2 folds an override in its source namespace. When `reads` is supplied,
/// it records which flattened parameter values an overload choice used, for
/// the same host shape check that protects §6.6 generate selection.
pub fn constValue(self: *Flatten, e: Ast.ExprId, local: bool, reads: ?[]bool) ?constfold.Const {
    return constfold.fold(self.ctx.file, e, ParamEnv{ .self = self, .local = local, .reads = reads });
}

/// Grows `Flatten.param_values` to one row per flat parameter and indexes
/// the new rows' names (`Flatten.param_index`); run after every append to
/// `Flatten.params`. Asserts that rows are only ever appended.
pub fn syncParamValues(self: *Flatten) design.Error!void {
    const have = self.folds.values.items.len;
    assert(have <= self.decls.params.items.len);
    try self.folds.values.appendNTimes(self.ctx.arena, .unknown, self.decls.params.items.len - have);
    for (self.decls.params.items[have..], have..) |p, i| {
        if (p.dims.len != 0) continue;
        const gop = try self.folds.index.getOrPut(self.ctx.arena, p.name);
        if (!gop.found_existing) gop.value_ptr.* = @intCast(i);
    }
}

// ---- private ----

/// Flat parameter `i`'s folded value, cached. The parameters before `i` are
/// folded first, in order, so a default's nested folds find their reads
/// cached: the stack holds one default's depth, not a chain of them (a
/// chain of `links` defaults each `d` deep needed `links * d` levels on a
/// stack the parse reserved for `d`, and overflowed it). A parameter met
/// again while its own default is folding is a cycle and declines.
fn paramValue(self: *Flatten, i: usize, depth: u8) ?constfold.Const {
    const rows = self.folds.values.items;
    assert(rows.len == self.decls.params.items.len); // `syncParamValues`
    switch (rows[i]) {
        .done => |v| return v,
        .folding => return null,
        .unknown => {},
    }
    while (self.folds.warm < i) {
        const j = self.folds.warm;
        self.folds.warm += 1;
        _ = paramValue(self, j, depth);
    }
    rows[i] = .folding;
    const v = (ParamEnv{ .self = self, .local = false, .depth = depth }).param(i);
    rows[i] = if (v) |c| .{ .done = c } else .unknown;
    return v;
}

/// Elaborates `text` on a `deep_stack` thread reserved for `depth` levels,
/// as `compileInArena` runs lowering (and so elaboration) for the parser's
/// `deepest`.
fn elaborateDeep(f: *fixture.Fixture, depth: usize) !design.Design {
    return @import("base").deep_stack.run(depth, elaborate.elaborate, .{f.ctx()});
}

test "a chain of parameter defaults folds within the stack reserved for one default's depth" {
    // `q<i> = q<i-1> + 1+1+…` (`d` terms): an instance range reading the
    // last folds every default of the chain. Folded one inside the next,
    // the chain needs `links` times the stack reserved for the parse's
    // deepest expression (one default) and overflowed it (SIGSEGV).
    const d = 4000;
    const links = 32;
    const gpa = std.testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    try text.appendSlice(gpa, "module kid(a); inout a; electrical a; endmodule\nmodule top(p); inout p; electrical p;\n");
    for (0..links) |i| {
        try text.print(gpa, "parameter integer q{d} = ", .{i});
        if (i != 0) try text.print(gpa, "q{d} + ", .{i - 1});
        for (0..d) |k| try text.appendSlice(gpa, if (k == 0) "1" else "+1");
        try text.appendSlice(gpa, ";\n");
    }
    try text.print(gpa, "kid u[q{d}:q{d}](p); endmodule\n", .{ links - 1, links - 1 });
    var f: fixture.Fixture = .{ .arena = .init(gpa) };
    defer f.deinit();
    try fixture.parse(&f, text.items);
    const dsg = try elaborateDeep(&f, d + 2);
    try std.testing.expectEqual(@as(usize, 2), dsg.units.len);
    try std.testing.expectEqualStrings(try f.arena.allocator().print("u[{d}].", .{links * d}), dsg.units.items(.path)[1]);
}

test "parameter folds: a forward reference still folds, a cycle declines (E0909)" {
    // `a` reads `b`, declared after it; `c` and `e` read each other.
    for ([_]struct { []const u8, bool }{
        .{ "parameter integer a = b + 1; parameter integer b = 2; kid u[a:a](p);", true },
        .{ "parameter integer c = e; parameter integer e = c; kid u[c:c](p);", false },
    }) |case| {
        var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
        defer f.deinit();
        try fixture.parse(&f, try f.arena.allocator().print(
            \\module kid(a); inout a; electrical a; endmodule
            \\module top(p); inout p; electrical p; {s} endmodule
        , .{case[0]}));
        if (case[1]) {
            const d = try elaborate.elaborate(f.ctx());
            try std.testing.expectEqualStrings("u[3].", d.units.items(.path)[1]);
        } else {
            try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(f.ctx()));
            try std.testing.expect(fixture.hasCode(&f.bag, .E0909));
        }
    }
}
