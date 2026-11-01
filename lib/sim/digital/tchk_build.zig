//! An instance's A.7.5 `system_timing_check`s in (`Ast.TimingCheck`), the `Tchk` rows bound to the slots their events name out, with the limits in ticks and the §15.5 delayed signals of negative limits.
//! Cites: IEEE 1364-2005 §15.1, §15.5, §15.5.1 to §15.5.3, §15.6, A.7.5.
//!
//! Contents:
//! - `pub fn compileChecks(r: *Run, checks: []const Ast.TimingCheck) Error!void`
//! - `pub fn delayedDrivers(r: *Run, e: *elab.Elab) Error!void`
//! - `pub fn event(r: *Run, t: *const Ast.TimingCheck, k: usize) Error!Event`
//! - `pub fn solveNegative(r: *Run) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const root = @import("root.zig");
const Run = root.Run;
const Error = root.Error;
const compile = @import("compile.zig");
const elab = @import("elab.zig");
const evaluate = @import("evaluate.zig");
const exec = @import("exec.zig");
const waiters = @import("waiters.zig");
const wordMask = @import("net.zig").wordMask;
const planeBit = @import("net.zig").planeBit;
const bitChar = @import("net.zig").bitChar;
const tchk = @import("tchk.zig");
const Event = tchk.Event;
const Tchk = tchk.Tchk;
const flag = tchk.flag;
const kinds = tchk.kinds;
const notifier = tchk.notifier;
const reference = tchk.reference;

/// Binds the A.7.5 checks of the instance being elaborated (`r.scope`) into
/// `r.checks.rows`. Refuses (E1149) an argument `judge` does not evaluate.
pub fn compileChecks(r: *Run, checks: []const Ast.TimingCheck) Error!void {
    assert(r.scope < r.hier.scopes.items.len);
    const rows_before = r.checks.rows.items.len;
    for (checks) |*t| try compileOne(r, t);
    assert(r.checks.rows.items.len == rows_before + checks.len); // One row per check.
}

/// §15.5.1 the explicit delayed signals of every `$setuphold` and `$recrem`
/// (arguments 8 and 9, Syntax 15-3/15-6) of the instances `e` elaborated:
/// each is a net the check drives with its reference or data signal. "The
/// delayed timing check signals are only actually delayed when negative
/// limit values are present", which VerA has no option to enable
/// (§15.5.4: without it "the delayed reference and data signals become
/// copies of the original reference and data signals"), so each is a
/// zero-delay copy, one more driver of its net (a port window, `Bridge`).
pub fn delayedDrivers(r: *Run, e: *elab.Elab) Error!void {
    const drivers_before = r.netlist.drivers.len;
    defer assert(r.netlist.drivers.len >= drivers_before);
    for (e.insts.items) |inst| for (inst.module.timing_checks) |*t| {
        const name = r.file.str(t.name);
        if (!std.mem.eql(u8, name, "$setuphold") and !std.mem.eql(u8, name, "$recrem")) continue;
        r.scope = inst.scope;
        for ([_][2]usize{ .{ 7, 0 }, .{ 8, 1 } }) |pair| {
            const dst_e = arg(t, pair[0]);
            if (dst_e == .none) continue;
            const src = try terminal(r, t.args[pair[1]]);
            const dst = try terminal(r, dst_e);
            const net = r.netlist.slot_nets.get(dst.slot) orelse
                return r.failWith(.E1147, r.file.exprs.mainTok(dst_e), "a delayed signal of `{s}` is a net (IEEE 1364-2005 §15.5.1)", .{name});
            if (src.width != dst.width)
                return r.failWith(.E1147, r.file.exprs.mainTok(dst_e), "a delayed signal of `{s}` is as wide as the signal it delays (IEEE 1364-2005 §15.5.1)", .{name});
            try e.wires.append(r.arena, .{
                .net = net,
                .scope = inst.scope,
                .source = .{ .bridge = .{ .src = src.slot, .src_lo = src.lo, .dst_lo = dst.lo, .width = src.width } },
                .tok = t.main_tok,
            });
        }
    };
}

/// Event argument `k`: A.7.3's `specify_terminal_descriptor`, a name or a
/// constant bit- or part-select of one, with its control and condition.
pub fn event(r: *Run, t: *const Ast.TimingCheck, k: usize) Error!Event {
    assert(k < 2);
    const e = t.args[k]; // the parser refuses an empty mandatory argument
    assert(e != .none);
    const ex = &r.file.exprs;
    var ev: Event = .{
        .mask = if (k < t.masks.len) t.masks[k] else 0,
        .cond = if (k < t.conds.len) t.conds[k] else .none,
    };
    switch (ex.tag(e)) {
        .ident, .hier_ident => ev.slot = try r.slot(e),
        .index => {
            const sel = (try compile.selectTerm(r, e)) orelse return r.failWith(.E1147, ex.mainTok(e), "a timing check event names a port or a constant select of at most 64 bits of one (A.7.3)", .{});
            ev.slot = sel.slot;
            ev.lo = sel.first;
            ev.width = sel.count;
            const bits = waiters.termBits(r.values[ev.slot], ev.lo, ev.width);
            ev.v = bits[0];
            ev.x = bits[1];
        },
        else => return r.failWith(.E1147, ex.mainTok(e), "a timing check event names a port or a constant select of one (A.7.3), not an expression", .{}), // else: A.7.3 admits a name and a select only
    }
    if (r.decls.reals.contains(ev.slot) or r.decls.arrays.contains(ev.slot) or r.decls.events.contains(ev.slot) or r.decls.params.contains(ev.slot))
        return r.failWith(.E1147, ex.mainTok(e), "a timing check event names a net or a variable with a logic value (A.7.3)", .{});
    if (ev.cond != .none) try compile.checkExpr(r, ev.cond);
    assert(ev.slot < r.values.len);
    return ev;
}

/// IEEE 1364-2005 §15.5.1 with the negative timing option on: in each
/// instance whose `$setuphold`/`$recrem` checks have a negative limit, every
/// signal those checks name gets one delay ("a single delayed signal",
/// Example 2), the least non-negative ones that leave every adjusted limit
/// at least one tick. A check with a window `S` before its reference and
/// `H` after it, its reference delayed `dR` and data `dD`, keeps the same
/// window over the delayed signals with `S + dR - dD` and `H - dR + dD`; the
/// tick keeps §15.5.1 a)'s end points "exclusive": an event on the original
/// window's edge lands on the adjusted one, never on the reference itself,
/// where the check would judge it simultaneous. The LRM's feasibility rule
/// is the same margin, "removal_limit + recovery_limit > (simulation unit of
/// precision)". When no
/// delays exist (`S + H < 0` around a cycle), "changing the smallest negative
/// limit value to 0" and solving again (W1162). The delays reach the checks
/// in `changed`; the limits land in `Tchk.lim`.
/// ponytail: the explicit delayed nets (arguments 8 and 9) stay zero-delay
/// copies, and SDF or vpi_put_delays limits set later are not solved again.
pub fn solveNegative(r: *Run) Error!void {
    if (!r.opts.negative_timing) return;
    const checks = r.checks.rows.items;
    assert(r.checks.delay.items.len == 0 or r.checks.delay.items.len == checks.len);
    const window = struct {
        fn of(c: Tchk) bool {
            return c.kind == .setuphold or c.kind == .recrem;
        }
        fn signed(v: u64) i64 {
            return @bitCast(v);
        }
    };
    var any = false;
    for (checks) |c| if (window.of(c) and (window.signed(c.lim[0]) < 0 or window.signed(c.lim[1]) < 0)) {
        any = true;
    };
    if (!any) return;
    try r.checks.delay.appendNTimes(r.arena, .{ 0, 0 }, checks.len);
    var done: std.AutoHashMapUnmanaged(u32, void) = .empty;
    for (checks) |c0| {
        if (!window.of(c0) or done.contains(c0.scope)) continue;
        try done.put(r.arena, c0.scope, {});
        const scope = c0.scope;
        if (!for (checks) |c| {
            if (c.scope == scope and window.of(c) and (window.signed(c.lim[0]) < 0 or window.signed(c.lim[1]) < 0)) break true;
        } else false) continue;
        // The scope's signals, one per (slot, select).
        const Key = struct { slot: u32, lo: u32, width: u32 };
        var sigs: std.ArrayList(Key) = .empty;
        var at: std.ArrayList([2]u32) = .empty; // per check of the scope: its two signal indices
        var rows: std.ArrayList(u32) = .empty; // the scope's checks
        for (checks, 0..) |c, i| {
            if (c.scope != scope or !window.of(c)) continue;
            var pair: [2]u32 = undefined;
            for (c.ev, 0..) |ev, k| {
                const key: Key = .{ .slot = ev.slot, .lo = ev.lo, .width = ev.width };
                pair[k] = for (sigs.items, 0..) |s, j| {
                    if (std.meta.eql(s, key)) break @intCast(j);
                } else blk: {
                    try sigs.append(r.arena, key);
                    break :blk @intCast(sigs.items.len - 1);
                };
            }
            try at.append(r.arena, pair);
            try rows.append(r.arena, @intCast(i));
        }
        // In i128: a limit is any i64, and a delay sums one per signal, so
        // `d - s + eps` leaves i64 on legal limits near its ends.
        const d = try r.arena.alloc(i128, sigs.items.len);
        // One retry per negative limit at most, each zeroing one, then one
        // without the margin, which a set with no negative limit always meets.
        var eps: i128 = 1;
        var tries: usize = 2 * rows.items.len + 2;
        while (tries > 0) : (tries -= 1) {
            @memset(d, 0);
            // Bellman-Ford over `dR - dD >= -S` and `dD - dR >= -H`: a
            // feasible system settles within one round per signal.
            var settled = false;
            var round: usize = 0;
            while (round <= sigs.items.len) : (round += 1) {
                var moved = false;
                for (rows.items, at.items) |i, pair| {
                    const s = window.signed(checks[i].lim[0]);
                    const h = window.signed(checks[i].lim[1]);
                    if (d[pair[1]] - s + eps > d[pair[0]]) {
                        d[pair[0]] = d[pair[1]] - s + eps;
                        moved = true;
                    }
                    if (d[pair[0]] - h + eps > d[pair[1]]) {
                        d[pair[1]] = d[pair[0]] - h + eps;
                        moved = true;
                    }
                }
                if (!moved) {
                    settled = true;
                    break;
                }
            }
            if (settled) break;
            // §15.5.1: "changing the smallest negative limit value to 0".
            var low: ?struct { i: u32, k: usize, v: i64 } = null;
            for (rows.items) |i| for (0..2) |k| {
                const v = window.signed(checks[i].lim[k]);
                if (v < 0 and (low == null or v < low.?.v)) low = .{ .i = i, .k = k, .v = v };
            };
            const l = low orelse {
                std.debug.assert(eps != 0); // with no margin and no negative limit, d = 0 settles
                eps = 0;
                continue;
            };
            checks[l.i].lim[l.k] = 0;
            const start = r.starts[@min(checks[l.i].tok, r.starts.len - 1)];
            try r.bag.add(r.stage(), .W1162, .{ .start = start, .end = start }, "the limits of the timing checks on this instance's signals cannot all be met by delayed signals; the most negative one is set to 0 (IEEE 1364-2005 §15.5.1)", .{});
        }
        for (rows.items, at.items) |i, pair| {
            const s: i128 = window.signed(checks[i].lim[0]);
            const h: i128 = window.signed(checks[i].lim[1]);
            const dr = d[pair[0]];
            const dd = d[pair[1]];
            assert(s + dr - dd >= 0); // The system settled: dR - dD >= -S.
            assert(h - dr + dd >= 0); // And dD - dR >= -H.
            const tok = checks[i].tok;
            const too_far = "the limits of this timing check need delayed signals or limits past 2^64 ticks (IEEE 1364-2005 §15.5.1)";
            checks[i].lim = .{
                std.math.cast(u64, s + dr - dd) orelse return r.failWith(.E1148, tok, too_far, .{}),
                std.math.cast(u64, h - dr + dd) orelse return r.failWith(.E1148, tok, too_far, .{}),
            };
            r.checks.delay.items[i] = .{
                std.math.cast(u64, dr) orelse return r.failWith(.E1148, tok, too_far, .{}),
                std.math.cast(u64, dd) orelse return r.failWith(.E1148, tok, too_far, .{}),
            };
        }
    }
    // Every other check is non-negative already; its bits are its value.
    for (checks) |c| std.debug.assert(!window.of(c) or (window.signed(c.lim[0]) >= 0 and window.signed(c.lim[1]) >= 0));
}

// ---- private ----

fn arg(t: *const Ast.TimingCheck, k: usize) Ast.ExprId {
    assert(k < 9); // $setuphold and $recrem, the longest, have nine (A.7.5.1).
    assert(t.args.len <= 9);
    return if (k < t.args.len) t.args[k] else .none;
}

fn compileOne(r: *Run, t: *const Ast.TimingCheck) Error!void {
    const name = r.file.str(t.name);
    const kind = kinds.get(name).?; // the parser admits A.7.5.1's twelve commands only
    assert(t.args.len >= 1);
    var c: Tchk = .{ .kind = kind, .scope = r.scope, .tok = t.main_tok };
    switch (kind) {
        .width, .period => {
            c.ev[0] = try event(r, t, 0);
            c.ev[1] = c.ev[0];
            // §15.3.4: "data event = reference event signal with opposite
            // edge"; §15.3.5: "... with the same edge".
            if (kind == .width) c.ev[1].mask = Ast.TimingCheck.opposite(c.ev[0].mask);
            c.lim[0] = try nonNegative(r, t, arg(t, 1), "limit");
            if (kind == .width) {
                // Syntax 15-12: "the default value for the threshold zero".
                if (arg(t, 2) != .none) c.lim[1] = try nonNegative(r, t, arg(t, 2), "threshold");
                c.notifier = try notifier(r, arg(t, 3));
            } else c.notifier = try notifier(r, arg(t, 2));
        },
        // A.7.5.1: `$setup ( data_event , reference_event , ...)` is the one
        // command that writes its data event first.
        .setup => {
            c.ev[0] = try event(r, t, 1);
            c.ev[1] = try event(r, t, 0);
            c.lim[0] = try nonNegative(r, t, arg(t, 2), "limit");
            c.notifier = try notifier(r, arg(t, 3));
        },
        // Table 15-4: the reference event is the timecheck, the data event
        // the timestamp: the window is before the reference.
        .removal => {
            c.ev[0] = try event(r, t, 0);
            c.ev[1] = try event(r, t, 1);
            c.lim[0] = try nonNegative(r, t, arg(t, 2), "limit");
            c.notifier = try notifier(r, arg(t, 3));
        },
        // Tables 15-2 and 15-5: the reference event is the timestamp, the
        // data event the timecheck: the window is after the reference.
        .hold, .recovery => {
            c.ev[0] = try event(r, t, 0);
            c.ev[1] = try event(r, t, 1);
            c.lim[1] = try nonNegative(r, t, arg(t, 2), "limit");
            c.notifier = try notifier(r, arg(t, 3));
        },
        .setuphold, .recrem => {
            c.ev[0] = try event(r, t, 0);
            c.ev[1] = try event(r, t, 1);
            // Table 15-3's timestamp and timecheck conditions (§15.8's
            // negative checks); the delayed signals are driven
            // (`delayedDrivers`).
            c.stamp_cond = arg(t, 5);
            c.check_cond = arg(t, 6);
            for ([_]Ast.ExprId{ c.stamp_cond, c.check_cond }) |x| if (x != .none) try compile.checkExpr(r, x);
            const a = try signedLimit(r, t, arg(t, 2));
            const b = try signedLimit(r, t, arg(t, 3));
            // §15.2.3/§15.2.6: the first limit is $setuphold's setup (the
            // window before the reference) and $recrem's recovery (after).
            c.lim = if (kind == .setuphold) .{ a, b } else .{ b, a };
            c.notifier = try notifier(r, arg(t, 4));
        },
        // Tables 15-7 to 15-9: the reference event, the data event, one
        // limit (`$fullskew`: one per order), the notifier and the two
        // flags. $skew is $timeskew with both flags set (§15.3.2: "It
        // behaves like the $skew check when both the event_based_flag and
        // the remain_active_flag are set").
        .skew, .timeskew, .fullskew => {
            c.ev[0] = try event(r, t, 0);
            c.ev[1] = try event(r, t, 1);
            c.lim[0] = try nonNegative(r, t, arg(t, 2), "limit");
            var k: usize = 3;
            if (kind == .fullskew) {
                c.lim[1] = try nonNegative(r, t, arg(t, 3), "limit");
                k = 4;
            }
            c.notifier = try notifier(r, arg(t, k));
            c.flags = .{
                .event_based = kind == .skew or try flag(r, t, arg(t, k + 1)),
                .remain_active = kind == .skew or try flag(r, t, arg(t, k + 2)),
            };
        },
        // Table 15-12. §15.3.6: "The reference event can be specified with
        // the posedge or the negedge keyword": its level is the window.
        .nochange => {
            c.ev[0] = try event(r, t, 0);
            c.ev[1] = try event(r, t, 1);
            if (c.ev[0].mask == 0) return r.failWith(.E1147, r.file.exprs.mainTok(t.args[0]), "the reference event of `$nochange` is an edge, posedge or negedge, whose level is the window (IEEE 1364-2005 §15.3.6)", .{});
            c.lim[0] = @bitCast(try limitTicks(r, t, arg(t, 2)));
            // The window's end is judged at the data event, before the
            // trailing edge is known, so it cannot move earlier than it.
            const end = try limitTicks(r, t, arg(t, 3));
            if (end < 0) return r.failWith(.E1149, r.file.exprs.mainTok(arg(t, 3)), "a negative end edge offset of `$nochange` (IEEE 1364-2005 §15.3.6, a window ending before its trailing reference edge) is not evaluated by VerA's digital engine", .{});
            c.lim[1] = @intCast(end);
            c.notifier = try notifier(r, arg(t, 4));
        },
    }
    assert(c.kind == kind);
    try r.checks.rows.append(r.arena, c);
}

/// A.7.3 a `specify_terminal_descriptor`: a name, or a constant select of one.
fn terminal(r: *Run, e: Ast.ExprId) Error!struct { slot: u32, lo: u32, width: u32 } {
    assert(e != .none);
    const ex = &r.file.exprs;
    switch (ex.tag(e)) {
        .ident, .hier_ident => {
            const at = try r.slot(e);
            assert(at < r.values.len);
            return .{ .slot = at, .lo = 0, .width = r.values[at].width };
        },
        else => { // else: a select, which `selectTerm` admits; every other form is refused there
            const sel = (try compile.selectTerm(r, e)) orelse
                return r.failWith(.E1147, ex.mainTok(e), "a timing check terminal names a port or a constant select of one (A.7.3)", .{});
            return .{ .slot = sel.slot, .lo = @intCast(sel.first), .width = sel.count };
        },
    }
}

/// A limit's value in the instance's time unit, converted to ticks, with
/// its sign. Tables 15-1..15-12: "constant expression".
fn limitTicks(r: *Run, t: *const Ast.TimingCheck, e: Ast.ExprId) Error!i64 {
    assert(e != .none);
    assert(t.name != .none);
    const tok = r.file.exprs.mainTok(e);
    const name = r.file.str(t.name);
    try compile.checkExpr(r, e);
    if (!compile.constantExpression(r, e))
        return r.failWith(.E1148, tok, "a limit of `{s}` is a constant expression (IEEE 1364-2005 §15.1); this one reads a signal", .{name});
    const scale = r.timeOf(r.scope).scale;
    var negative = false;
    const mag = (if (compile.typeOf(r, e).real) blk: {
        const v = try evaluate.evalReal(r, r.arena, e);
        negative = v < 0;
        break :blk scale.realDelay(@abs(v));
    } else blk: {
        const v = (try r.constant(e, tok)).asInt() orelse return r.failWith(.E1148, tok, "a limit of `{s}` has an x or z bit", .{name});
        negative = v < 0;
        break :blk scale.unsignedDelay(@abs(v));
    }) catch return r.failWith(.E1148, tok, "a limit of `{s}` is no tick count", .{name});
    const ticks = std.math.cast(i64, mag) orelse return r.failWith(.E1148, tok, "a limit of `{s}` is no tick count", .{name});
    return if (negative) -ticks else ticks;
}

/// Tables 15-1, 15-2, 15-4, 15-5, 15-7 to 15-11: a "Non-negative constant
/// expression".
fn nonNegative(r: *Run, t: *const Ast.TimingCheck, e: Ast.ExprId, what: []const u8) Error!u64 {
    assert(e != .none);
    assert(what.len != 0);
    const v = try limitTicks(r, t, e);
    if (v < 0) return r.failWith(
        .E1148,
        r.file.exprs.mainTok(e),
        "the {s} of `{s}` is a non-negative constant expression (IEEE 1364-2005 §15), and this one is negative",
        .{ what, r.file.str(t.name) },
    );
    assert(v >= 0);
    return @intCast(v);
}

/// Tables 15-3 and 15-6: a "Constant expression", which §15.8 lets be
/// negative when "the negative timing check option is enabled"
/// (`Options.negative_timing`): then the signed limit, an i64's bits, which
/// `solveNegative` turns into delays and adjusted limits. Without it,
/// §15.5.4: the limit is 0, and the delayed signals are copies
/// (`delayedDrivers`).
fn signedLimit(r: *Run, t: *const Ast.TimingCheck, e: Ast.ExprId) Error!u64 {
    assert(e != .none);
    const v = try limitTicks(r, t, e);
    if (!r.opts.negative_timing) assert(@max(v, 0) >= 0);
    return if (r.opts.negative_timing) @bitCast(v) else @intCast(@max(v, 0));
}
