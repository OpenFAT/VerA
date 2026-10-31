//! §6.4.2 paramset selection: an instance of an overloaded paramset name →
//! the one paramset whose ranges admit its overrides, after the clause's
//! three tie-breaking rules; E0911/E0914 otherwise. Also §3.4.2's range
//! order on every paramset parameter.
//! Cites: LRM §3.4.2, §3.4.5, §6.4, §6.4.2, §6.9.3, §9.18.
//!
//! Contents:
//! - `pub fn selectParamset(self: *Flatten, inst: *const Ast.Instance, path: []const u8) design.Error!?*const Ast.ParamsetDecl`
//! - `pub fn matchingParamsets(self: *Flatten, inst: *const Ast.Instance, path: []const u8, live: *std.ArrayList(*const Ast.ParamsetDecl)) design.Error!usize`
//! - `pub fn checkRanges(self: *Flatten) design.Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const ports = @import("ports.zig");
const lookup = @import("lookup.zig");
const fold = @import("fold.zig");
const override = @import("override.zig");
const hier_param = @import("hier_param.zig");
const sep = design.sep;

/// The three §6.4.2 tie-breaking rules, in the clause's order.
const TieRule = enum { un_overridden, ranged_locals, unconnected_ports };

/// §6.4.2 defaults and localparams see the candidate's effective parameters,
/// while an inline override and a defparam retain their respective scopes.
const ParamsetEnv = struct {
    self: *Flatten,
    ps: *const Ast.ParamsetDecl,
    bindings: []const ?override.ParamBinding,
    reads: ?[]bool,
    depth: usize = 0,

    fn value(env: ParamsetEnv, i: usize) ?constfold.Const {
        // Acyclic parameter defaults visit at most one declaration per level.
        // A cycle remains lowering's diagnostic, not infinite recursion here.
        if (env.depth >= env.ps.params.len) return null;
        const p = env.ps.params[i];
        const raw = if (env.bindings[i]) |b|
            fold.constValue(env.self, b.value, !b.flat, env.reads)
        else blk: {
            var next = env;
            next.depth += 1;
            break :blk constfold.fold(env.self.ctx.file, p.default, next);
        };
        return constfold.parameterValue(p.ty, raw orelse return null);
    }

    /// Resolves an identifier naming one of the candidate's parameters to
    /// its effective value; anything else declines.
    pub fn leaf(env: ParamsetEnv, e: Ast.ExprId) ?constfold.Const {
        const ex = &env.self.ctx.file.exprs;
        if (ex.tag(e) != .ident) return null;
        for (env.ps.params, 0..) |p, i| if (p.name == ex.strOf(e)) return env.value(i);
        return null;
    }
    /// Leaves operand signedness unknown.
    pub fn signed(_: ParamsetEnv, _: Ast.ExprId) ?bool {
        return null;
    }
    /// Leaves a parameter's width unknown.
    pub fn width(_: ParamsetEnv, _: Ast.ExprId) ?u32 {
        return null;
    }
};

/// Returns the paramset of an overload set this instance uses (§6.4.2), or
/// null after reporting E0904 (no paramset of that name), E0911 (none
/// admits the instance) or E0914 (still ambiguous after tie-breaking).
///
/// "Paramset identifiers need not be unique: multiple paramsets can be
/// declared using the same paramset_identifier ... During elaboration, the
/// simulator shall choose an appropriate paramset from the set that shares a
/// given name for every instance that references that name."
///
/// Two phases, from the clause. The selection rules ("the following rules
/// shall be enforced") cut the overload set down to the applicable paramsets
/// (`paramsetAdmits`). Then: "The rules above may not
/// be sufficient for the simulator to pick a unique paramset, in which case
/// the following rules shall be applied in order until a unique paramset
/// has been selected:"
///
///   1. "The paramset with the fewest number of un-overridden parameters
///      shall be selected." (§6.4.2's m3 example: the default paramset, l and
///      w both overridden, beats the long-channel one, ad and as defaulted.)
///   2. "The paramset with the greatest number of local parameters with
///      specified ranges shall be selected."
///   3. "The paramset with the fewest ports not connected in the instance
///      line shall be selected", over the target module's port list, since
///      same-named paramsets "may refer to different modules".
pub fn selectParamset(self: *Flatten, inst: *const Ast.Instance, path: []const u8) design.Error!?*const Ast.ParamsetDecl {
    var live: std.ArrayList(*const Ast.ParamsetDecl) = .empty;
    const candidates = try matchingParamsets(self, inst, path, &live);
    if (live.items.len == 0) {
        if (candidates == 0) {
            try lookup.unknownModule(self, inst);
        } else {
            try self.err(inst.main_tok, .E0911, "`{s}`: no paramset named `{s}` admits these parameter values", .{
                self.ctx.file.str(inst.name), self.ctx.file.str(inst.module),
            });
        }
        return null;
    }
    if (live.items.len > 1) {
        try self.err(inst.main_tok, .E0914, "`{s}`: {d} paramsets named `{s}` are still applicable after §6.4.2's tie-breaking rules", .{
            self.ctx.file.str(inst.name), live.items.len, self.ctx.file.str(inst.module),
        });
        return null;
    }
    return live.items[0];
}

/// Shared by actual instantiation and §6.9.3 connect insertion. Both must see
/// the same effective overrides at the external instance path, before storage
/// is renamed to the internal `instance.paramset.parameter` namespace.
/// Asserts that `live` starts empty.
pub fn matchingParamsets(self: *Flatten, inst: *const Ast.Instance, path: []const u8, live: *std.ArrayList(*const Ast.ParamsetDecl)) design.Error!usize {
    assert(live.items.len == 0);
    var count: usize = 0;
    for (self.ctx.file.paramsets) |ps| if (ps.name == inst.module) {
        count += 1;
    };
    const reads = if (count > 1) try self.ctx.arena.alloc(bool, self.decls.params.items.len) else null;
    if (reads) |r| @memset(r, false);
    try live.ensureUnusedCapacity(self.ctx.arena, count);
    for (self.ctx.file.paramsets) |*ps| {
        if (ps.name == inst.module and try paramsetAdmits(self, inst, ps, path, reads))
            live.appendAssumeCapacity(ps);
    }
    if (reads) |r| for (r, self.decls.params.items) |read, p| {
        if (read) try self.out.selection_params.append(self.ctx.arena, p.name);
    };
    // "applied in order until a unique paramset has been selected".
    for ([_]TieRule{ .un_overridden, .ranged_locals, .unconnected_ports }) |rule|
        if (live.items.len > 1) try tieBreak(self, inst, path, live, rule);
    assert(live.items.len <= count);
    return count;
}

/// §3.4.2 "The first expression in the range shall be numerically smaller
/// than the second expression in the range", for every paramset parameter,
/// once per declaration, whether or not an instance selects the paramset:
/// the check `Lower.lowerParamDecl` makes on a module's (E0347). Bounds fold
/// over the paramset's own defaults; one that does not fold is not judged.
pub fn checkRanges(self: *Flatten) design.Error!void {
    for (self.ctx.file.paramsets) |*ps| {
        const bindings = try self.ctx.arena.alloc(?override.ParamBinding, ps.params.len);
        @memset(bindings, null);
        const env: ParamsetEnv = .{ .self = self, .ps = ps, .bindings = bindings, .reads = null };
        for (ps.params) |p| for (p.ranges) |r| {
            if (r.strings != null or r.hi == .none) continue; // string set / single value
            const lo = constfold.fold(self.ctx.file, r.lo, env) orelse continue;
            const hi = constfold.fold(self.ctx.file, r.hi, env) orelse continue;
            if (lo == .str or hi == .str or lo.asReal() < hi.asReal()) continue;
            try self.err(p.main_tok, .E0347, "`{s}` of paramset `{s}`: {s} bounds {d} and {d} are not in increasing order", .{
                self.ctx.file.str(p.name), self.ctx.file.str(ps.name), @tagName(r.kind), lo.asReal(), hi.asReal(),
            });
        };
    }
}

// ---- private ----

/// Applies one tie-breaking rule: scores every surviving candidate and keeps
/// the minimum in `live` (a "greatest" rule negates its count).
fn tieBreak(
    self: *Flatten,
    inst: *const Ast.Instance,
    path: []const u8,
    live: *std.ArrayList(*const Ast.ParamsetDecl),
    rule: TieRule,
) design.Error!void {
    assert(live.items.len > 1); // a unique paramset needs no tie-break
    const scores = try self.ctx.arena.alloc(i64, live.items.len);
    for (live.items, scores) |ps, *s| s.* = switch (rule) {
        // "the fewest number of un-overridden parameters": the paramset's
        // overridable parameters the instance left at their defaults. A
        // localparam is not overridable (§3.4.5), and §6.4.2's neighbouring
        // rules count "parameters" and "local parameters" separately.
        .un_overridden => blk: {
            var n: i64 = 0;
            for (ps.params, 0..) |p, i| {
                if (p.is_local) continue;
                n += @intFromBool(try override.parameterBinding(self, inst, ps.params, ps.aliasparams, i, path, false) == null);
            }
            break :blk n;
        },
        // "the greatest number of local parameters with specified ranges",
        // negated.
        .ranged_locals => blk: {
            var n: i64 = 0;
            for (ps.params) |p| n += @intFromBool(p.is_local and p.ranges.len != 0);
            break :blk -n;
        },
        // "the fewest ports not connected in the instance line". A target
        // module the file never declares scores worst; if such a candidate
        // is selected anyway, E0904 names it at the use site.
        .unconnected_ports => blk: {
            const child = lookup.findModule(self, ps.target) orelse break :blk std.math.maxInt(i64);
            var n: i64 = 0;
            for (child.ports, 0..) |p, i| {
                const conn = ports.connectionFor(inst, p, i);
                n += @intFromBool(conn == null or conn.?.expr == .none);
            }
            break :blk n;
        },
    };
    const best = std.mem.min(i64, scores);
    var w: usize = 0;
    for (live.items, scores) |ps, s| if (s == best) {
        live.items[w] = ps;
        w += 1;
    };
    // The best score is some candidate's, so it survives.
    assert(w != 0);
    live.shrinkRetainingCapacity(w);
}

/// Returns whether `ps` passes §6.4.2's selection rules for `inst` ("When
/// choosing an appropriate paramset, the following rules shall be
/// enforced"), as far as each is decidable here. Reports nothing.
///
///   1. "All parameters overridden on the instance shall be parameters of
///      the paramset", and §3.4.5 keeps a localparam out of an override's
///      reach in either spelling.
///   2. "The parameters of the paramset, with overrides and defaults, shall
///      be all within the allowed ranges specified in the paramset
///      parameter declaration": this is what makes a binned set select on
///      geometry.
///   3. "The local parameters of the paramset, computed from parameters,
///      shall be within the allowed ranges specified in the paramset":
///      judged as far as `constReal` folds (see `inRanges`).
///   4. "The underlying module shall have a port declared for each port
///      connected in the instance line." An undeclared target module cannot
///      fail it; that is E0904 at the use site.
fn paramsetAdmits(self: *Flatten, inst: *const Ast.Instance, ps: *const Ast.ParamsetDecl, path: []const u8, reads: ?[]bool) design.Error!bool {
    const named = inst.params.len != 0 and inst.params[0].name != .none;
    if (!named and inst.params.len > override.overridableCount(ps.params)) return false;
    if (named) for (inst.params) |o| {
        if (!exposes(self, ps, self.ctx.file.str(o.name))) return false;
    };
    var it = self.defparams.rows.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!std.mem.startsWith(u8, key, path)) continue;
        const name = key[path.len..];
        // A path into a descendant names that descendant's own parameters,
        // not an additional parameter of the paramset instance.
        if (std.mem.findScalar(u8, name, sep) != null) continue;
        if (!exposes(self, ps, name)) return false;
    }
    const bindings = try self.ctx.arena.alloc(?override.ParamBinding, ps.params.len);
    for (bindings, 0..) |*b, i| b.* = try override.parameterBinding(self, inst, ps.params, ps.aliasparams, i, path, false);
    const env: ParamsetEnv = .{ .self = self, .ps = ps, .bindings = bindings, .reads = reads };
    for (ps.params, 0..) |p, i| {
        if (p.ranges.len != 0 and !inRanges(self, env.value(i), p.ranges, env)) return false;
    }
    // Criterion 4, both connection spellings. A mixed or malformed list is
    // E0906 after selection (`checkConnectionShape`).
    if (lookup.findModule(self, ps.target)) |child| {
        const conns_named = inst.ports.len != 0 and inst.ports[0].name != .none;
        if (conns_named) {
            for (inst.ports) |c| {
                if (c.name == .none) continue;
                const found = for (child.ports) |p| {
                    if (p.connName() == c.name) break true;
                } else false;
                if (!found) return false;
            }
        } else if (inst.ports.len > child.ports.len) return false;
    }
    return true;
}

/// Whether an external override names a public parameter of this candidate.
/// §6.4 hides unexposed parameters of the underlying module; §3.4.5 excludes
/// localparams. System parameters (and their aliases) keep §9.18's binding.
fn exposes(self: *Flatten, ps: *const Ast.ParamsetDecl, name: []const u8) bool {
    if (hier_param.Kind.fromName(name) != null) return true;
    for (ps.params) |p| if (!p.is_local and std.mem.eql(u8, self.ctx.file.str(p.name), name)) return true;
    for (ps.aliasparams) |al| {
        if (!std.mem.eql(u8, self.ctx.file.str(al.alias), name)) continue;
        if (hier_param.Kind.fromName(self.ctx.file.str(al.target)) != null) return true;
        for (ps.params) |p| if (!p.is_local and p.name == al.target) return true;
    }
    return false;
}

/// §3.4.2 does this value satisfy the declared `from`/`exclude` ranges?
///
/// ponytail: a value or a bound this cannot fold counts as admissible, so a
/// missing folder never becomes a selection error; `Lower` still judges the
/// value it ends up with (E0361).
fn inRanges(self: *Flatten, value: ?constfold.Const, ranges: []const Ast.ValueRange, env: ParamsetEnv) bool {
    if (ranges.len == 0) return true;
    // §3.4.2: "Valid values of string parameters are indicated differently.
    // The `from` keyword may be used with a list of valid string values, or
    // the `exclude` keyword may be used with a list of invalid string
    // values." A.2.5's `value_range_type '{ string {, string} }`, parsed
    // into `ValueRange.strings`. Without this arm a binned set keyed on a
    // string (§3.4.6's `ebersmoll` mapping) admits every bin.
    const c = value orelse return true;
    if (c == .str) return strInRanges(self, c.str, ranges);
    const v = c.asReal();
    var has_from = false;
    var in_from = false;
    for (ranges) |r| {
        if (r.strings != null) continue;
        const lo = (constfold.fold(self.ctx.file, r.lo, env) orelse return true).asReal();
        const hi = if (r.hi == .none) lo else (constfold.fold(self.ctx.file, r.hi, env) orelse return true).asReal();
        const above = if (r.lo_inclusive) v >= lo else v > lo;
        const below = if (r.hi_inclusive) v <= hi else v < hi;
        switch (r.kind) {
            .from => {
                has_from = true;
                if (above and below) in_from = true;
            },
            .exclude => if (above and below) return false,
        }
    }
    return !has_from or in_from;
}

/// The string half of `inRanges`: membership in a `'{ ... }` set, union over
/// the `from` clauses, any `exclude` hit fatal, as lowering's
/// `checkParamRange` judges it. Returns a verdict instead of a diagnostic,
/// because here a non-member only means "this bin is not the one".
fn strInRanges(self: *Flatten, s: []const u8, ranges: []const Ast.ValueRange) bool {
    var has_from = false;
    var in_from = false;
    for (ranges) |r| {
        const off = r.strings orelse continue;
        const contains = for (self.ctx.file.exprs.list(off)) |id| {
            if (std.mem.eql(u8, s, self.ctx.file.str(@fromBackingInt(@intCast(id))))) break true;
        } else false;
        switch (r.kind) {
            .from => {
                has_from = true;
                in_from = in_from or contains;
            },
            .exclude => if (contains) return false,
        }
    }
    return !has_from or in_from;
}

const fixture = @import("fixture.zig");

test "§6.4.2 ties: the greatest number of ranged localparams, then the fewest unconnected ports; still tied is E0914" {
    // Rule 1 ties both pairs below (each leaves its one parameter `l` at its
    // default). Rule 2 then picks the paramset whose localparam has a range.
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; bin u(p); endmodule
        \\paramset bin base; parameter real l = 1.0; .k = 10.0; endparamset
        \\paramset bin base; parameter real l = 1.0; localparam real lp = 1.0 from [0:2]; .k = 20.0; endparamset
        \\module base(a); inout a; electrical a; parameter real k = 0.0; endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(f64, 20.0), f.file.exprs.realValue(fixture.paramNamed(&f.file, d.top, "u.k").?.default));

    // Rules 1 and 2 tie; rule 3 counts the target module's ports the
    // instance leaves unconnected: `two`'s `b` is, `one` has no other.
    var g: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer g.deinit();
    try fixture.parse(&g,
        \\module top(p); inout p; electrical p; bin u(p); endmodule
        \\paramset bin two; parameter real l = 1.0; .k = 10.0; endparamset
        \\paramset bin one; parameter real l = 1.0; .k = 20.0; endparamset
        \\module two(a, b); inout a, b; electrical a, b; parameter real k = 0.0; endmodule
        \\module one(a); inout a; electrical a; parameter real k = 0.0; endmodule
    );
    const dg = try elaborate.elaborate(g.ctx());
    try std.testing.expectEqualStrings("one", g.file.str(dg.units.items(.module)[1]));
    try std.testing.expectEqual(@as(f64, 20.0), g.file.exprs.realValue(fixture.paramNamed(&g.file, dg.top, "u.k").?.default));

    // Two indistinguishable paramsets survive every rule.
    var h: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer h.deinit();
    try fixture.parse(&h,
        \\module top(p); inout p; electrical p; bin u(p); endmodule
        \\paramset bin base; parameter real l = 1.0; .k = 10.0; endparamset
        \\paramset bin base; parameter real l = 1.0; .k = 20.0; endparamset
        \\module base(a); inout a; electrical a; parameter real k = 0.0; endmodule
    );
    try std.testing.expectError(error.DiagnosticsReported, elaborate.elaborate(h.ctx()));
    try std.testing.expect(fixture.hasCode(&h.bag, .E0914));
}
