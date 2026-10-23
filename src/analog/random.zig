//! §9.13 probabilistic distributions: `$random`, `$dist_*` and `$rdist_*`.
//!
//! In: one distribution call, in function or statement position. Out: the
//! variate's `call` and, for an inout seed, the `_next` call written back to
//! the seed; a hidden held seed slot for a seed that is no variable; a row in
//! `Lowered.rng_auto_seeds` for an omitted one.
//!
//! LRM clauses this file's code cites: §4.2.3, §6.4, §9.13, §9.13.1, §9.13.2, §9.13.3.
//! IEEE 1364-2005 clauses cited: §17.9.3.

const std = @import("std");
const Lower = @import("lower.zig");
const lower_constfold = @import("constfold.zig");
const lower_expr = @import("expr.zig");
const lower_var = @import("var.zig");
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const dist = @import("elab").dist;
const Oom = Lower.Oom;
const TypedValue = Lower.TypedValue;
const VarSlot = Lower.VarSlot;
const poison = Lower.poison;

/// This file's private state on `Lower` (`Lower.random_state`).
pub const State = struct {
    /// The next site whose seed is no integer variable, in source order. An
    /// omitted seed starts at `1 + 7919·ordinal` (`rng_auto_seeds`); a
    /// constant or parameter seed takes an ordinal too, so adding one shifts
    /// the omitted seeds after it.
    rng_site_ordinal: u32 = 0,
    /// One hidden seed and first-call flag per source site and elaborated scope.
    rng_internal: std.StringHashMapUnmanaged(InternalSeed) = .empty,
};

/// The two held integers behind a seed that is not a variable.
const InternalSeed = struct { seed: VarSlot, ready: VarSlot };
/// §9.13 Table 9-10, whose "supported in analog context" column reads Yes for
/// every one of the 17 names. One source call becomes TWO pure calls over the
/// seed's incoming value — the variate, and the updated seed §9.13.1/§9.13.2
/// require to be written back through the inout argument — for the reason
/// `lowerScan` splits `$sscanf`: a unit body is an SSA expression tree and an
/// out-parameter has no spelling in one.
///
/// Both halves are functions of the same input, so re-evaluating the block at
/// one operating point re-derives the same pair: §9.13.2's "shall always return
/// the same value given the same seed", and the determinism Newton needs
/// (see `rng_kernels.zig`).
///
/// Returns null when `name` is not one of the 17.
pub fn lowerRandom(self: *Lower, tok: u32, name: []const u8, args: []const Ast.ExprId) Oom!?TypedValue {
    const d = dist.of(name) orelse return null;
    const ex = &self.file.exprs;
    self.out.uses.insert(.rng);

    // Drop A.6.9 empty slots first, so the arity below counts what was written.
    var given: std.ArrayList(Ast.ExprId) = .empty;
    defer given.deinit(self.arena);
    for (args) |a| if (a != .none) try given.append(self.arena, a);

    // §9.13.1 Syntax 9-8 / §9.13.2 Syntax 9-9: the optional trailing
    // `type_string` ("instance" or "global") "shall only be used in calls to a
    // distribution function from within a paramset". Elaboration
    // (`rewriteParamsetDist`) already handled the in-paramset calls, so any
    // string still in the last slot was written outside one.
    if (given.last()) |last| {
        if (ex.tag(last) == .str_literal) {
            try self.err(self.file.exprs.mainTok(last), .E0816, "`{s}`'s `type_string` argument is only meaningful within a paramset (§6.4)", .{name});
            return poison;
        }
    }

    const want: usize = @as(usize, d.nparam) + 1;
    // §9.13.1's two are the only ones whose seed "may be omitted, in which case
    // the simulator picks a seed"; Syntax 9-9 makes it mandatory everywhere else.
    const min: usize = if (d.nparam == 0) 0 else want;
    if (given.items.len < min or given.items.len > want) {
        try self.err(tok, .E0816, "`{s}` takes {s}{d} argument{s}, got {d}", .{
            name,
            if (min < want) "at most " else "",
            want,
            if (want == 1) "" else "s",
            given.items.len,
        });
        return poison;
    }

    // ---- the seed -----------------------------------------------------------
    var seed: Mir.Value = undefined;
    // Set only for §9.13.2's "If it is an integer VARIABLE, then it is an inout
    // argument"; a parameter, a constant and an omitted seed all leave it null,
    // which is §9.13.1's "the system function does not update the parameter
    // value".
    var write_back: ?VarSlot = null;
    if (given.items.len > 0) {
        const sa = given.items[0];
        const tv = try lower_expr.lowerExpr(self, sa);
        // §9.13.2: "For each system function, the seed argument shall be an
        // integer", and Syntax 9-9 says the same as grammar —
        // `seed ::= integer_variable_identifier | integer_parameter_identifier
        // | [ sign ] decimal_number`. A real is none of the three, and the
        // inout half of the rule needs somewhere to put an updated INTEGER.
        if (tv.ty != .integer) {
            try self.err(self.file.exprs.mainTok(sa), .E0816, "the seed argument shall be an integer, and this one is {s}", .{@tagName(tv.ty)});
            return poison;
        }
        seed = tv.v;
        if (ex.tag(sa) == .ident) if (self.vars.get(self.file.str(ex.strOf(sa)))) |s| {
            if (s.ty == .integer) write_back = s;
        };
    }
    if (write_back == null) {
        const ordinal = self.random_state.rng_site_ordinal;
        self.random_state.rng_site_ordinal += 1;
        if (given.items.len > 0) {
            // §9.13.1/§9.13.2 assign the supplied initial value, then update
            // the hidden seed only when THIS source call executes. The held
            // SSA places give it the same sequencing and rollback as an
            // explicit seed variable, including a skipped branch or loop.
            const state = try internalSeed(self, tok);
            const ready = try self.builder.readVariable(state.ready.place, self.cur);
            const previous = try self.builder.readVariable(state.seed.place, self.cur);
            seed = try self.emit(.select, &.{ try self.toBool(.{ .v = ready, .ty = .integer }), previous, seed });
            try self.builder.writeVariable(state.ready.place, self.cur, .one);
            write_back = state.seed;
        } else {
            // Omitted seeds retain their existing implementation-defined
            // starting values and accepted-point progression.
            const site = self.out.rng_auto_seeds.items.len;
            try self.out.rng_auto_seeds.append(self.arena, 1 + 7919 * @as(i64, ordinal));
            const latch = try self.call("$rng$auto", &.{try self.mir.addIntConst(self.arena, @intCast(site))});
            seed = try self.toInt(.{ .v = latch, .ty = .real });
        }
    }

    // ---- the parameters, and the rules §9.13.2 states about them ------------
    // §4.2.3 suppresses errors in skipped operands. Entry is a conservative
    // proof that the call executes unconditionally; later blocks keep runtime
    // checks even when they would also be safe to diagnose here. Function-local
    // constants can depend on host parameters, so they also stay runtime.
    const eager = self.cur == .entry and self.inlining.items.len == 0;
    var vals: std.ArrayList(Mir.Value) = .empty;
    defer vals.deinit(self.arena);
    try vals.append(self.arena, seed);
    for (given.items[@min(1, given.items.len)..], 0..) |a, i| {
        const tv = try lower_expr.lowerExpr(self, a);
        try vals.append(self.arena, try self.toReal(tv));
        // A declared parameter default is not the final host-supplied value.
        // Keep static signature/type checks above, and defer numeric checks
        // unless both execution and the argument value are known here.
        if (!eager) continue;
        const c = lower_constfold.foldExpr(self, a, false) orelse continue;
        if (c == .str) continue;
        if (d.positive & (@as(u8, 1) << @intCast(i)) != 0 and !(c.asReal() > 0))
            try self.err(self.file.exprs.mainTok(a), .E0816, "`{s}`'s `{s}` shall be greater than zero, got {d}", .{
                name, dist.paramName(d, i), c.asReal(),
            });
        if (d.count and i == 0 and c.asReal() > 0 and
            (!(c.asReal() <= 2147483647.0) or c.asReal() != @trunc(c.asReal())))
            try self.err(self.file.exprs.mainTok(a), .E0816, "`{s}`'s fractional or out-of-range `{s}` is unsupported; the reference count domain is 1..2147483647", .{ name, dist.paramName(d, i) });
    }
    if (eager and d.ordered and d.ty == .real and vals.items.len == 3) {
        const lo = lower_constfold.foldExpr(self, given.items[1], false);
        const hi = lower_constfold.foldExpr(self, given.items[2], false);
        if (lo != null and hi != null and lo.? != .str and hi.? != .str and
            !(lo.?.asReal() < hi.?.asReal()))
        {
            var b = self.errWith(self.file.exprs.mainTok(given.items[1]), .E0816);
            b.msg("the start value shall be smaller than the end value, got {d} and {d}", .{ lo.?.asReal(), hi.?.asReal() });
            b.note("§9.13.2: start and end \"bound the values returned\", and an interval with start above end is empty", .{});
            try b.emit();
        }
    }

    // A required runtime error remains observable even when neither the value
    // nor final seed is used. Share the guarded source-order effect chain with
    // table captures, but do not force an unused distribution's draw loop.
    const rules: u4 = @as(u4, @intCast(d.positive)) |
        (if (d.count) @as(u4, 4) else 0) |
        (if (d.ordered and d.ty == .real) @as(u4, 8) else 0);
    if (rules != 0) {
        const place = try self.effectPlace();
        const previous = try self.builder.readVariable(place, self.cur);
        const checked = try self.call("$rng$check", &.{
            previous,
            try self.mir.addIntConst(self.arena, rules),
            vals.items[1],
            if (d.nparam > 1) vals.items[2] else .f_zero,
        });
        try self.builder.writeVariable(place, self.cur, checked);
    }

    // ---- the two calls ------------------------------------------------------
    const v = try self.call(d.kernel, vals.items);
    // §9.13.1/§9.13.2: "a value is passed to the function and a different value
    // is returned. The variable is initialized by the user and only updated by
    // the system function." Written after the variate, so both read the same
    // incoming seed however the two calls are ordered in the MIR.
    //
    // The write-back is the kernel's own `_next` twin over the same arguments:
    // IEEE 1364 §17.9.3's routines consume a data-dependent number of LCG draws,
    // and §9.13.3 binds this family to that listing, so the updated seed must
    // land where the reference's `long *seed` did.
    if (write_back) |s| {
        const next_name = try self.arena.print("{s}_next", .{d.kernel});
        const next = try self.call(next_name, vals.items);
        try self.builder.writeVariable(s.place, self.cur, try self.toInt(.{ .v = next, .ty = .real }));
    }
    return .{ .v = if (d.ty == .integer) try self.toInt(.{ .v = v, .ty = .real }) else v, .ty = switch (d.ty) {
        .real => .real,
        .integer => .integer,
    } };
}

/// Repeated execution of one source site shares its hidden seed. A first-call
/// flag defers a model-card parameter's initialization until the call runs;
/// neither an unevaluated branch nor a discarded Newton iterate consumes it.
fn internalSeed(self: *Lower, tok: u32) Oom!InternalSeed {
    const scope = self.inlining.last() orelse self.scope_path;
    const key = try self.arena.print("{d}:{s}:{d}", .{ self.cur_unit, scope, tok });
    const entry = try self.random_state.rng_internal.getOrPut(self.arena, key);
    if (!entry.found_existing) {
        const name = try self.arena.print("$rng.{d}", .{self.random_state.rng_internal.count() - 1});
        entry.value_ptr.* = .{
            .seed = try lower_var.hiddenHeldInt(self, try self.arena.print("{s}.seed", .{name})),
            .ready = try lower_var.hiddenHeldInt(self, try self.arena.print("{s}.ready", .{name})),
        };
    }
    return entry.value_ptr.*;
}

test "dist: every §9.13 kernel is one of lowering's own reserved callees" {
    for (&dist.dists) |*d| {
        const c = Mir.Callee.fromName(d.kernel);
        try std.testing.expect(c != .systf and c.synthetic());
    }
}

test "§9.13 distributions: the seed and the parameter rules" {
    try Lower.expectBodies(&.{
        // "For each system function, the seed argument shall be an integer."
        .{ .src = "analog begin iv = $random(r); I(p) <+ iv; end", .code = .E0816 },
        // Syntax 9-9: $dist_uniform takes a seed, a start and an end.
        .{ .src = "analog begin iv = $dist_uniform(seed, 0); I(p) <+ iv; end", .code = .E0816 },
        // "The start value shall be smaller than the end value."
        .{ .src = "analog begin x = $rdist_uniform(seed, 2.0, 1.0); I(p) <+ x; end", .code = .E0816 },
        .{ .src = "analog begin x = $rdist_uniform(seed, 0.0, 1.0); I(p) <+ x * V(p); end", .code = null },
        // "mean ... shall be greater than zero (0)."
        .{ .src = "analog begin x = $rdist_exponential(seed, -1.0); I(p) <+ x; end", .code = .E0816 },
        // A type_string "shall only be used ... from within a paramset".
        .{ .src = "analog begin x = $rdist_uniform(seed, 0.0, 1.0, \"global\"); I(p) <+ x; end", .code = .E0816 },
    });
}

test "§9.13.1 omitted seeds number their sites in source order" {
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  integer a, b;
        \\  analog begin
        \\    a = $random;
        \\    b = $random;
        \\    I(p) <+ (a + b) * V(p);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    _ = try h.low.lowerFile();
    // "the simulator picks a seed": VerA's pick is 1 + 7919·ordinal, so the
    // two sites start apart (`lowerRandom`).
    try std.testing.expectEqualSlices(i64, &.{ 1, 7920 }, h.low.out.rng_auto_seeds.items);
}
