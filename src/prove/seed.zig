//! Seeding: the MIR's leaves in, every Value's first interval and finite bit
//! out (`Prover.iv`, `Prover.finite`, sized here with `uses` and `guard`).
//! Constants are exact (§4.2), parameters take their §3.4.2 ranges, a §4.4
//! probe is finite with the host's bound; only computed values stay `top`,
//! for `walk.zig` to fill. Emits W0651 for a range closed on infinity.
//!
//! LRM clauses this file's code cites: §2.7, §3.2.1, §3.4.2, §4.2, §4.4.
//!
//! Contents:
//! - `pub fn seedValues(p: *Prover) Error!void`
//! - `pub const Error = Allocator.Error`

const std = @import("std");
const assert = std.debug.assert;
const math = std.math;
const Allocator = std.mem.Allocator;
const Mir = @import("ir").Mir;
const Lowered = @import("ir").Lowered;
const diag = @import("diag");
const Interval = @import("Interval.zig");
const Prover = @import("Prover.zig");

/// Fails on allocation, in the prover's arena or in the diagnostics bag.
pub const Error = Allocator.Error;

/// Sizes the per-Value tables and seeds every Value but a computed one.
/// Asserts that it runs once, first.
pub fn seedValues(p: *Prover) Error!void {
    const n = p.an.nv;
    assert(p.iv.len == 0); // runs once
    assert(p.unknown_bound == null or !math.isNan(p.unknown_bound.?));
    p.iv = try p.arena.alloc(Interval, n);
    p.finite = try p.arena.alloc(bool, n);
    p.uses = try p.arena.alloc(u8, n);
    p.guard = try p.arena.alloc(Prover.GuardRef, n);
    @memset(p.iv, Interval.top);
    @memset(p.finite, false);
    @memset(p.uses, 0);
    @memset(p.guard, .{});

    for (0..n) |i| {
        const v: Mir.Value = @fromBackingInt(@intCast(i));
        switch (p.mir.valueDef(v)) {
            // §4.2 constant expressions: exact.
            .float_const => |c| {
                p.iv[i] = Interval.point(c);
                p.finite[i] = math.isFinite(c);
            },
            .int_const => |c| {
                p.iv[i] = Interval.point(@floatFromInt(c));
                p.finite[i] = true;
            },
            // §2.7 strings never reach a float operation.
            .str_const => p.finite[i] = true,
            // §3.4.2: the primary bound evidence.
            .param_ref => |pi| {
                const iv = paramInterval(p.lowered, pi);
                p.iv[i] = iv;
                p.finite[i] = iv.excludesInf();
                // A written range that admits infinity is almost always a
                // typo for the open bound (W0651).
                if (!p.finite[i]) try warnInfiniteRange(p, pi);
            },
            // §4.4 a solver unknown: finite by the host contract, magnitude
            // unknown unless the host declares one.
            .block_param => {
                if (p.unknown_bound) |b| p.iv[i] = .{ .lo = -@abs(b), .hi = @abs(b) };
                p.finite[i] = true;
            },
            // if-conversion collects select-arm guards before the transfer
            // walk: a widened literal in `real_value > 0` already has the
            // same bound as the source integer zero.
            .inst_result => if (p.literalNumber(v)) |c| {
                p.iv[i] = Interval.point(c);
                p.finite[i] = math.isFinite(c);
            },
            .undef => {},
        }
    }
    assert(p.iv.len == n);
    assert(p.finite.len == n);
    assert(p.guard.len == n);
    assert(!p.finite[@backingInt(Mir.Value.undef)]);
}

// ---- private ----

/// Returns a §3.4.2 parameter's value ranges as one interval. `from` ranges
/// are unioned (their convex hull: the representation has no holes), and an
/// `exclude` range is subtracted only where it clips an end, which is the
/// `exclude 0` / `from (0:inf)` evidence a divisor or `ln` needs. `top` for a
/// string parameter or an index past `lowered.params`.
///
/// Bounds are folded literally by lowering (`Lower.Range`), never through
/// `Lower.constEval`: a bound written in terms of another parameter would
/// fold to that parameter's default, which the card can override.
fn paramInterval(lowered: *const Lowered, param: u32) Interval {
    if (param >= lowered.params.items.len) return .top;
    const info = lowered.params.items[param];
    if (info.ty == .string) return .top;

    // A `from` bound that does not fold literally proves nothing, so the
    // union is then `top`; the exclusions and the type below still hold.
    var iv: Interval = from: {
        var acc: ?Interval = null;
        for (info.ranges) |r| {
            if (r.kind != .from or r.strings) continue;
            const lo = r.lo orelse break :from .top;
            const hi = r.hi orelse break :from .top;
            const one: Interval = .{
                .lo = lo,
                .hi = hi,
                .lo_open = !r.lo_inclusive,
                .hi_open = !r.hi_inclusive,
            };
            acc = if (acc) |a| a.join(one) else one;
        }
        break :from acc orelse .top;
    };

    for (info.ranges) |r| {
        if (r.kind != .exclude or r.strings) continue;
        const lo = r.lo orelse continue;
        const hi = r.hi orelse continue;
        // §3.4.2: "Parentheses, ( and ), indicate exclusion of the end points
        // from the value range." So an `exclude` end point is excluded only
        // when its bracket is square: `exclude (0:5)` still admits 0, and
        // reading `nonzero` from it would hand the unit `.optimized` over a
        // division by a value the range permits. `exclude 0` works because a
        // single value's `hi` is `lo`'s and both inclusive flags default true.
        const zero_excluded = (lo < 0 and hi > 0) or
            (lo == 0 and r.lo_inclusive) or
            (hi == 0 and r.hi_inclusive);
        if (zero_excluded) iv.nonzero = true;
        // The same rule at the range's own ends: an exclusion clips an end
        // only if it removes that end itself, by a square bracket or because
        // the range already left it open. [0:10] minus (0:5) is {0} ∪ [5:10],
        // whose hull is still [0:10].
        const covers_lo = lo < iv.lo or (lo == iv.lo and (r.lo_inclusive or iv.lo_open));
        const covers_hi = hi > iv.hi or (hi == iv.hi and (r.hi_inclusive or iv.hi_open));
        if (covers_lo and hi >= iv.lo and hi <= iv.hi) {
            // Ending exactly on an open end keeps that end open.
            iv.lo_open = r.hi_inclusive or (hi == iv.lo and iv.lo_open);
            iv.lo = hi;
        } else if (covers_hi and lo <= iv.hi and lo >= iv.lo) {
            iv.hi_open = r.lo_inclusive or (lo == iv.hi and iv.hi_open);
            iv.hi = lo;
        }
    }
    // §3.2.1 fixes `integer` at 32 bits, so a model-card integer never holds
    // an infinity whatever ranges were written.
    if (info.ty == .integer) iv = iv.meet(.{ .lo = -2147483648.0, .hi = 2147483647.0 });
    if (info.ty == .integer) assert(iv.excludesInf() or iv.isEmpty() or math.isNan(iv.lo) or math.isNan(iv.hi));
    return iv;
}

/// W0651: a `from [0:inf]` range admits infinity as a value, which costs
/// every unit downstream its proof. The open bound admits the same finite
/// values and keeps it.
fn warnInfiniteRange(p: *Prover, pi: u32) Error!void {
    if (!p.bag.enabled(.W0651)) return;
    if (pi >= p.lowered.params.items.len) return;
    const pinfo = p.lowered.params.items[pi];
    // A §3.4.2 string value set has no bounds to close (`paramInterval`
    // answers `top` for every string parameter).
    if (pinfo.ty == .string) return;
    // Only a `from` bound WRITTEN as a closed `inf` admits infinity. `exclude
    // 0` alone, or a bound naming another parameter, leaves the interval
    // unbounded without admitting it; W0650 covers those.
    const inf = math.inf(f64);
    const side: []const u8 = for (pinfo.ranges) |r| {
        if (r.kind != .from or r.strings) continue;
        if (r.lo_inclusive and (r.lo orelse 0) == -inf) break "lower";
        if (r.hi_inclusive and (r.hi orelse 0) == inf) break "upper";
    } else return;

    var b = p.bag.build(.proof, .W0651, p.lowered.tokenSpan(pinfo.tok));
    b.msg("`{s}`", .{pinfo.name});
    b.point("{s} bound is closed on infinity", .{side});
    b.help("close the bound instead: `[0:inf)` admits the same finite values", .{});
    try b.emit();
}
