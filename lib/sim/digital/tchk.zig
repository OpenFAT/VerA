//! IEEE 1364-2005 §15 timing checks in the digital run: each instance's
//! A.7.5 `system_timing_check`s (`Ast.TimingCheck`) -> `Tchk` rows bound to
//! the slots their events name (`compile`, `arm`), then, at every change of
//! such a slot (`waiters.store` -> `changed`), the check judged at its
//! timecheck event: §15.2's stability window, §15.3.1-§15.3.3's skew (or,
//! timer-based, when its limit elapses: `expired`), §15.3.4's pulse width,
//! §15.3.5's period or §15.3.6's level window. A violation is reported
//! (W1199), toggles the notifier (§15.5, Table 15-13) and calls
//! `Run.tchk_hook` (VAMS 12.31.4 cbTchkViolation). A form this file does
//! not evaluate (§15.5.2's conditions, a negative $nochange end offset) is
//! refused by name (E1149), never accepted and ignored.
//!
//! When a check is judged (docs/specification/Vague_Decisions.md VD-104): at the event, in
//! the order the time step's events arrive. A reference and a data event
//! at the same time are one pair, judged once whichever comes first, so the
//! window rules do not depend on that order: a data event remembers whether
//! it already reported, and a stamp of the window before the reference is
//! the latest data event strictly before it.
//!
//! Clauses: IEEE 1364-2005 §15.1-§15.7, Tables 15-1 to 15-13, §27.31
//! (`putLimits`); VAMS 12.29, 12.31.4.

const std = @import("std");
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

/// A.7.5.1's twelve commands. The tag is the command without its `$`.
pub const Kind = enum { setup, hold, setuphold, removal, recovery, recrem, skew, timeskew, fullskew, width, period, nochange };

const kinds = std.StaticStringMap(Kind).initComptime(.{
    .{ "$setup", .setup },
    .{ "$hold", .hold },
    .{ "$setuphold", .setuphold },
    .{ "$removal", .removal },
    .{ "$recovery", .recovery },
    .{ "$recrem", .recrem },
    .{ "$skew", .skew },
    .{ "$timeskew", .timeskew },
    .{ "$fullskew", .fullskew },
    .{ "$width", .width },
    .{ "$period", .period },
    .{ "$nochange", .nochange },
});

/// One event of a check: the bits it watches, and what makes a change of
/// them an occurrence.
pub const Event = struct {
    slot: u32 = 0,
    /// A constant select's bits `[lo, lo + width)`, `width` <= 64; `width`
    /// 0 is the whole slot.
    lo: u32 = 0,
    width: u32 = 0,
    /// A select's bits when last seen (values, unknowns), which tell a
    /// change of the select from a change elsewhere in its vector.
    v: u64 = 0,
    x: u64 = 0,
    /// The §15.4 transitions (`Ast.TimingCheck.masks`); 0 is any change of
    /// the value (an event with no edge control).
    mask: u8 = 0,
    /// The §15.6 `&&&` condition, `.none` when unconditioned.
    cond: Ast.ExprId = .none,
};

/// The times of one event's occurrences a check still reads.
pub const Stamp = struct {
    /// The latest occurrence.
    last: ?u64 = null,
    /// The latest occurrence at a time before `last`'s.
    before: ?u64 = null,
    /// An occurrence at `last` already reported a violation.
    reported: bool = false,

    /// An occurrence at `now`.
    fn note(s: *Stamp, now: u64) void {
        if (!s.at(now)) {
            s.before = s.last;
            s.reported = false;
        }
        s.last = now;
    }

    /// Whether the latest occurrence is at `now`.
    fn at(s: Stamp, now: u64) bool {
        return if (s.last) |l| l == now else false;
    }

    /// The latest occurrence strictly before `now`.
    fn earlier(s: Stamp, now: u64) ?u64 {
        return if (s.at(now)) s.before else s.last;
    }
};

/// The skew checks' flags (§15.3.2, §15.3.3) and run-time state.
pub const Flags = packed struct(u8) {
    event_based: bool = false,
    remain_active: bool = false,
    /// A window is open (the check is not dormant): its timestamp event
    /// was `first`, at `Tchk.at[0].last`.
    active: bool = false,
    /// 0 the reference event, 1 the data event (`$fullskew` only).
    first: u1 = 0,
    _: u4 = 0,
};

/// One timing check of one instance.
pub const Tchk = struct {
    kind: Kind,
    flags: Flags = .{},
    /// The instance whose specify block wrote it.
    scope: u32,
    /// The command's token: the report's site, and the key a host's object
    /// for it carries (VPI's `src_tok`).
    tok: u32,
    /// The skew checks' timer: bumped by every window opened, satisfied or
    /// put to sleep, so an `exec.Pending.tchk_expiry` carrying an older
    /// one is stale.
    gen: u32 = 0,
    /// [0] the reference event, [1] the data event. `$width` and `$period`
    /// watch [0] only; [1] is their data event derived from it (its `mask`
    /// the opposite or the same edges, its condition the same).
    ev: [2]Event = .{ .{}, .{} },
    /// In ticks. The window checks: [0] the window before the reference
    /// event (setup, removal), [1] the window after it (hold, recovery).
    /// `$width`: [0] the limit, [1] the threshold. `$period`: [0]. The
    /// skew checks: [0] the limit after a reference event, [1] (`$fullskew`)
    /// after a data event. `$nochange`: [0] the start offset, an i64's
    /// bits (Table 15-12 lets it be negative), [1] the end offset.
    lim: [2]u64 = .{ 0, 0 },
    notifier: ?u32 = null,
    /// Run-time: the occurrences of [0] and [1] (`$width`: [0] is the
    /// pulse's open timestamp, cleared once measured; the skew checks:
    /// [0].last the open window's timestamp event; `$nochange`: [0].last
    /// the leading reference edge, [0].before the trailing one, null while
    /// the level lasts).
    at: [2]Stamp = .{ .{}, .{} },

    // Budget: `changed` reads one row per watching check per change. The
    // optional stamps (16 B each) are the slack a sentinel would reclaim.
    comptime {
        std.debug.assert(@sizeOf(Event) == 40);
        std.debug.assert(@sizeOf(Stamp) == 40);
        std.debug.assert(@sizeOf(Tchk) == 200);
    }
};

// ---- elaboration -----------------------------------------------------------

/// Binds the A.7.5 checks of the instance being elaborated (`r.scope`) into
/// `r.tchks`. Refuses (E1149) an argument `judge` does not evaluate.
pub fn compileChecks(r: *Run, checks: []const Ast.TimingCheck) Error!void {
    for (checks) |*t| try compileOne(r, t);
}

fn arg(t: *const Ast.TimingCheck, k: usize) Ast.ExprId {
    return if (k < t.args.len) t.args[k] else .none;
}

fn compileOne(r: *Run, t: *const Ast.TimingCheck) Error!void {
    const name = r.file.str(t.name);
    const kind = kinds.get(name).?; // the parser admits A.7.5.1's twelve commands only
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
            // §15.5.1, §15.5.2: the timestamp and timecheck conditions
            // serve negative timing checks (§15.8). The delayed signals are
            // driven (`delayedDrivers`).
            for (5..7) |k| if (arg(t, k) != .none) return r.failWith(
                .E1149,
                r.file.exprs.mainTok(arg(t, k)),
                "argument {d} of `{s}` (a stamptime or checktime condition, or a delayed signal: IEEE 1364-2005 §15.5.1, §15.5.2) is not evaluated by VerA's digital engine",
                .{ k + 1, name },
            );
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
    try r.tchks.append(r.arena, c);
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
    for (e.insts.items) |inst| for (inst.module.timing_checks) |*t| {
        const name = r.file.str(t.name);
        if (!std.mem.eql(u8, name, "$setuphold") and !std.mem.eql(u8, name, "$recrem")) continue;
        r.scope = inst.scope;
        for ([_][2]usize{ .{ 7, 0 }, .{ 8, 1 } }) |pair| {
            const dst_e = arg(t, pair[0]);
            if (dst_e == .none) continue;
            const src = try terminal(r, t.args[pair[1]]);
            const dst = try terminal(r, dst_e);
            const net = r.net_of.get(dst.slot) orelse
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

/// A.7.3 a `specify_terminal_descriptor`: a name, or a constant select of one.
fn terminal(r: *Run, e: Ast.ExprId) Error!struct { slot: u32, lo: u32, width: u32 } {
    const ex = &r.file.exprs;
    switch (ex.tag(e)) {
        .ident, .hier_ident => {
            const at = try r.slot(e);
            return .{ .slot = at, .lo = 0, .width = r.values[at].width };
        },
        else => { // else: a select, which `selectTerm` admits; every other form is refused there
            const sel = (try compile.selectTerm(r, e)) orelse
                return r.failWith(.E1147, ex.mainTok(e), "a timing check terminal names a port or a constant select of one (A.7.3)", .{});
            return .{ .slot = sel.slot, .lo = @intCast(sel.first), .width = sel.count };
        },
    }
}

/// Event argument `k`: A.7.3's `specify_terminal_descriptor`, a name or a
/// constant bit- or part-select of one, with its control and condition.
fn event(r: *Run, t: *const Ast.TimingCheck, k: usize) Error!Event {
    const e = t.args[k]; // the parser refuses an empty mandatory argument
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
    if (r.reals.contains(ev.slot) or r.arrays.contains(ev.slot) or r.events.contains(ev.slot) or r.params.contains(ev.slot))
        return r.failWith(.E1147, ex.mainTok(e), "a timing check event names a net or a variable with a logic value (A.7.3)", .{});
    if (ev.cond != .none) try compile.checkExpr(r, ev.cond);
    return ev;
}

/// A limit's value in the instance's time unit, converted to ticks, with
/// its sign. Tables 15-1..15-12: "constant expression".
fn limitTicks(r: *Run, t: *const Ast.TimingCheck, e: Ast.ExprId) Error!i64 {
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
    const v = try limitTicks(r, t, e);
    if (v < 0) return r.failWith(
        .E1148,
        r.file.exprs.mainTok(e),
        "the {s} of `{s}` is a non-negative constant expression (IEEE 1364-2005 §15), and this one is negative",
        .{ what, r.file.str(t.name) },
    );
    return @intCast(v);
}

/// Tables 15-3 and 15-6: a "Constant expression", which §15.8 lets be
/// negative when "the negative timing check option is enabled". VerA has
/// no such option, so §15.5.4's behaviour without it: the limit is 0, and
/// the delayed signals are copies (`delayedDrivers`).
fn signedLimit(r: *Run, t: *const Ast.TimingCheck, e: Ast.ExprId) Error!u64 {
    return @intCast(@max(try limitTicks(r, t, e), 0));
}

/// Tables 15-8 and 15-9: an event_based_flag or remain_active_flag, a
/// "Constant expression", set when nonzero.
fn flag(r: *Run, t: *const Ast.TimingCheck, e: Ast.ExprId) Error!bool {
    if (e == .none) return false;
    const tok = r.file.exprs.mainTok(e);
    try compile.checkExpr(r, e);
    if (!compile.constantExpression(r, e))
        return r.failWith(.E1148, tok, "a flag of `{s}` is a constant expression (IEEE 1364-2005 Table 15-8); this one reads a signal", .{r.file.str(t.name)});
    if (compile.typeOf(r, e).real) return try evaluate.evalReal(r, r.arena, e) != 0;
    return ((try r.constant(e, tok)).asInt() orelse return r.failWith(.E1148, tok, "a flag of `{s}` has an x or z bit", .{r.file.str(t.name)})) != 0;
}

/// §15.5: "The notifier is a reg, declared in the module where timing check
/// tasks are invoked". A.7.5.2 `notifier ::= variable_identifier`.
fn notifier(r: *Run, e: Ast.ExprId) Error!?u32 {
    if (e == .none) return null;
    const ex = &r.file.exprs;
    if (ex.tag(e) != .ident and ex.tag(e) != .hier_ident) return r.failWith(.E1147, ex.mainTok(e), "a notifier is a variable identifier (A.7.5.2)", .{});
    const at = try r.slot(e);
    if (r.net_of.contains(at) or r.reals.contains(at) or r.arrays.contains(at) or r.events.contains(at) or r.params.contains(at))
        return r.failWith(.E1147, ex.mainTok(e), "this notifier is not a reg (IEEE 1364-2005 §15.5: \"The notifier is a reg\")", .{});
    return at;
}

/// Files every check under the slots its events watch. After `Run.watch`
/// exists, so once per run.
pub fn arm(r: *Run) Error!void {
    for (r.tchks.items, 0..) |c, i| {
        const n: usize = if (c.kind == .width or c.kind == .period) 1 else 2;
        for (c.ev[0..n], 0..) |ev, k| {
            r.watch[ev.slot].insert(.tchk);
            const gop = try r.tchk_by_slot.getOrPut(r.arena, ev.slot);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(r.arena, @intCast(i * 2 + k));
        }
    }
}

/// IEEE 1364-2005 §27.31 / VAMS 12.29 vpi_put_delays on check (`scope`,
/// `tok`): `ticks` are its limits in A.7.5.1's written order. False when no
/// check is there.
pub fn putLimits(r: *Run, scope: u32, tok: u32, ticks: []const u64) bool {
    var hit = false;
    for (r.tchks.items) |*c| {
        if (c.scope != scope or c.tok != tok or ticks.len == 0) continue;
        switch (c.kind) {
            .setup, .removal, .width, .period => c.lim[0] = ticks[0],
            .hold, .recovery => c.lim[1] = ticks[0],
            .setuphold => if (ticks.len == 2) {
                c.lim = .{ ticks[0], ticks[1] };
            },
            .recrem => if (ticks.len == 2) {
                c.lim = .{ ticks[1], ticks[0] };
            },
            .skew, .timeskew => c.lim[0] = ticks[0],
            .fullskew, .nochange => if (ticks.len == 2) {
                c.lim = .{ ticks[0], ticks[1] };
            },
        }
        hit = true;
    }
    return hit;
}

// ---- the run ---------------------------------------------------------------

/// `waiters.store` changed `slot`, whose least significant bit went from
/// `before` to `after`: every check watching it judges the change.
pub fn changed(r: *Run, slot: u32, before: Int.Bit, after: Int.Bit) Error!void {
    const list = r.tchk_by_slot.get(slot) orelse return;
    for (list.items) |code| {
        const i = code / 2;
        const k: usize = code % 2;
        const bit = transitionOf(r, &r.tchks.items[i].ev[k], before, after) orelse continue;
        try judge(r, i, k, bit);
    }
}

/// The §15.4 transition (`Ast.TimingCheck.transition`, 0 for none) that a
/// change of the slot made of `ev`'s bits, read on their least significant
/// bit (VD-104), or null when it left them alone. §15.7: "the transition of
/// one or more bits of a vector is considered a single transition".
fn transitionOf(r: *Run, ev: *Event, before: Int.Bit, after: Int.Bit) ?u8 {
    if (ev.width == 0) return Ast.TimingCheck.transition(bitChar(before), bitChar(after));
    const now = waiters.termBits(r.values[ev.slot], ev.lo, ev.width);
    if (now[0] == ev.v and now[1] == ev.x) return null;
    const b = planeBit(ev.v, ev.x);
    ev.v = now[0];
    ev.x = now[1];
    return Ast.TimingCheck.transition(bitChar(b), bitChar(planeBit(now[0], now[1])));
}

/// Whether a change making transition `bit` is an occurrence of an event
/// with edges `mask` (0: any change of the value, §15.1's plain event).
fn matches(mask: u8, bit: u8) bool {
    return mask == 0 or (mask & bit) != 0;
}

/// §15.6: whether condition `cond` of a check in `scope` lets its event be
/// detected now. "When comparisons are deterministic, an x value on the
/// conditioning signal shall not enable the timing check. For
/// nondeterministic comparisons, an x on the conditioning signal shall
/// enable the timing check", and of a vector "the least significant bit ...
/// is used": `===`, `!==`, `~` and a bare expression are deterministic;
/// `==` and `!=` against a scalar constant are not.
fn enabled(r: *Run, scope: u32, cond: Ast.ExprId) Error!bool {
    if (cond == .none) return true;
    const ex = &r.file.exprs;
    const saved = r.scope;
    defer r.scope = saved;
    r.scope = scope;
    var scratch = std.heap.ArenaAllocator.init(r.arena);
    defer scratch.deinit();
    const a = scratch.allocator();
    const Op = enum { plain, invert, eq, neq, case_eq, case_neq };
    var op: Op = .plain;
    var signal = cond;
    var want: Int.Bit = .one;
    switch (ex.tag(cond)) {
        .unary => if (ex.unOp(cond) == .bit_not) {
            op = .invert;
            signal = ex.lhs(cond);
        },
        .binary => if (ex.tag(ex.rhs(cond)) == .int_literal or ex.tag(ex.rhs(cond)) == .logic_literal) {
            op = switch (ex.binOp(cond)) {
                .eq => .eq,
                .neq => .neq,
                .case_eq => .case_eq,
                .case_neq => .case_neq,
                else => .plain, // else: any other operator is A.7.5.3's bare `expression`
            };
            if (op != .plain) {
                signal = ex.lhs(cond);
                want = (try evaluate.eval(r, a, ex.rhs(cond), 0)).bit(0);
            }
        },
        else => {}, // else: any other expression is A.7.5.3's bare `expression`
    }
    const s = (try evaluate.eval(r, a, signal, 0)).bit(0);
    const known = s == .zero or s == .one;
    return switch (op) {
        .plain => s == .one,
        .invert => s == .zero,
        // Deterministic: "an x value on the conditioning signal shall not
        // enable the timing check", though `x !== 1'b0` is true as an
        // expression.
        .case_eq => known and s == want,
        .case_neq => known and s != want,
        .eq => !known or s == want,
        .neq => !known or s != want,
    };
}

/// Check `i`'s event `k` occurred if its edges name transition `bit` and
/// its condition holds; judge the check.
fn judge(r: *Run, i: u32, k: usize, bit: u8) Error!void {
    const c = &r.tchks.items[i];
    const now = r.scheduler.now;
    switch (c.kind) {
        // §15.3.4: "threshold < (timecheck time) - (timestamp time) < limit",
        // the timestamp the reference edge and the timecheck the opposite
        // one. A transition both name (an edge list and its own opposite)
        // closes the pulse before it opens the next.
        .width => {
            if (matches(c.ev[1].mask, bit) and try enabled(r, c.scope, c.ev[1].cond)) if (c.at[0].last) |ts| {
                c.at[0].last = null;
                const w = now - ts;
                if (c.lim[1] < w and w < c.lim[0]) try violation(r, i, ts, now);
            };
            if (matches(c.ev[0].mask, bit) and try enabled(r, c.scope, c.ev[0].cond)) c.at[0].last = now;
        },
        // §15.3.5: "(timecheck time) - (timestamp time) < limit", between
        // one reference edge and the next.
        .period => {
            if (!matches(c.ev[0].mask, bit) or !try enabled(r, c.scope, c.ev[0].cond)) return;
            if (c.at[0].last) |ts| if (now - ts < c.lim[0]) try violation(r, i, ts, now);
            c.at[0].last = now;
        },
        .setup, .hold, .setuphold, .removal, .recovery, .recrem => {
            if (!matches(c.ev[k].mask, bit) or !try enabled(r, c.scope, c.ev[k].cond)) return;
            if (k == 0) try reference(r, i, now) else try data(r, i, now);
        },
        .skew, .timeskew, .fullskew => {
            if (!matches(c.ev[k].mask, bit)) return;
            // §15.3.2: "The check shall also become dormant if it detects a
            // reference event when its condition is false."
            if (!try enabled(r, c.scope, c.ev[k].cond)) {
                if (k == c.flags.first) sleep(c);
                return;
            }
            try skew(r, i, k, now);
        },
        .nochange => if (k == 0) {
            // §15.3.6: the level from the leading edge (`ev[0].mask`) to
            // the trailing, opposite one. A leading edge also judges the
            // latest data event, which a positive start offset puts inside
            // the window before it.
            if (matches(Ast.TimingCheck.opposite(c.ev[0].mask), bit) and c.at[0].last != null and c.at[0].before == null) c.at[0].before = now;
            if (!matches(c.ev[0].mask, bit) or !try enabled(r, c.scope, c.ev[0].cond)) return;
            c.at[0] = .{ .last = now };
            if (c.at[1].last) |d| try noChange(r, i, d);
        } else {
            if (!matches(c.ev[1].mask, bit) or !try enabled(r, c.scope, c.ev[1].cond)) return;
            c.at[1].note(now);
            // With a zero end offset, a trailing edge later in this time
            // step closes the window before `now`: judge after the active
            // events (VD-104).
            if (c.lim[1] == 0 and c.at[0].last != null and c.at[0].before == null)
                _ = try exec.enqueue(r, .{ .tchk_expiry = .{ .check = i, .gen = c.gen } }, 0, false)
            else
                try noChange(r, i, now);
        },
    }
}

/// §15.3.1-§15.3.3: event `k` of skew check `i` at `now`. With no window
/// open, or of the kind that opened it, it is a timestamp event: it opens
/// a new one ("A second consecutive reference event shall cancel the old
/// wait for the data event and begin a new one"; $fullskew's data event
/// too, §15.3.3: "the reference and data events can transition in either
/// order"). Otherwise it is the timecheck event, and violates when
/// "(timecheck time) - (timestamp time) > limit", so a simultaneous pair
/// never does. A timer-based check (no event_based_flag) is judged by
/// `expired` instead, and a data event within the limit puts it to sleep
/// ("if a data event occurs within the limit, then a violation shall not be
/// reported and the check shall immediately become dormant"); an
/// event-based one sleeps after its first violation unless
/// remain_active_flag is set (§15.3.2).
fn skew(r: *Run, i: u32, k: usize, now: u64) Error!void {
    const c = &r.tchks.items[i];
    if (c.flags.active and k != c.flags.first) {
        const ts = c.at[0].last.?; // an open window has its timestamp
        if (now - ts > c.lim[c.flags.first]) {
            if (!c.flags.remain_active) sleep(c);
            try violation(r, i, ts, now);
        } else if (!c.flags.event_based) sleep(c);
        return;
    }
    if (k == 1 and c.kind != .fullskew) return;
    sleep(c);
    c.flags.active = true;
    c.flags.first = @intCast(k);
    c.at[0].last = now;
    if (!c.flags.event_based) _ = try exec.enqueue(r, .{ .tchk_expiry = .{ .check = i, .gen = c.gen } }, c.lim[k], false);
}

/// §15.3.2: "A violation shall be reported immediately upon an elapse of
/// time after the reference event equal to the limit, and the check shall
/// become dormant": the timer of skew check `i` started at generation `gen`
/// ran out, unless a later window or a data event retired it.
/// $nochange's data event deferred to the inactive events is judged here.
pub fn expired(r: *Run, i: u32, gen: u32) Error!void {
    const c = &r.tchks.items[i];
    if (c.kind == .nochange) return noChange(r, i, r.scheduler.now);
    if (!c.flags.active or c.gen != gen) return;
    sleep(c);
    try violation(r, i, c.at[0].last.?, r.scheduler.now);
}

/// A skew check goes dormant; its pending timer is stale.
fn sleep(c: *Tchk) void {
    c.flags.active = false;
    c.gen +%= 1;
}

/// §15.3.6: data event at `d` against $nochange `i`'s latest level,
/// "(leading reference edge time) - start_edge_offset < (data event time)
/// < (trailing reference edge time) + end_edge_offset", the trailing edge
/// unbounded while the level lasts; one report per data event's time.
// ponytail: a trailing edge an NBA makes lands after the deferred judgement
// (`judge`), so that pair still violates; judge in the monitor region if it
// matters.
fn noChange(r: *Run, i: u32, d: u64) Error!void {
    const c = &r.tchks.items[i];
    const lead = c.at[0].last orelse return;
    const start: i64 = @bitCast(c.lim[0]);
    const after = @as(i64, @intCast(lead)) - start < @as(i64, @intCast(d));
    const before = if (c.at[0].before) |trail| d < trail + c.lim[1] else true;
    if (after and before and !c.at[1].reported) {
        c.at[1].reported = true;
        try violation(r, i, lead, d);
    }
}

/// Whether a reference and a data event at the same time violate: never for
/// $setup and $removal ("The end points of the time window are not part of
/// the violation region"), for $hold and $recovery when the window after
/// the reference is open ("(beginning of time window) <= (timecheck time)"),
/// and for $setuphold and $recrem unless both limits are zero ("shall report
/// a timing violation when the reference and data events occur
/// simultaneously").
fn simultaneous(c: *const Tchk) bool {
    return switch (c.kind) {
        .setup, .removal => false,
        .hold, .recovery, .setuphold, .recrem => c.lim[0] > 0 or c.lim[1] > 0,
        .width, .period, .skew, .timeskew, .fullskew, .nochange => unreachable, // judged by `judge` itself
    };
}

/// A reference event at `now`: the timecheck of the window before it,
/// "(timecheck time) - limit < (timestamp time) < (timecheck time)" with
/// the latest data event before `now` as the timestamp (§15.2.1, §15.2.4,
/// and the data-first half of §15.2.3/§15.2.6), and the second of a
/// simultaneous pair whose data event came first.
fn reference(r: *Run, i: u32, now: u64) Error!void {
    const c = &r.tchks.items[i];
    c.at[0].note(now);
    if (c.lim[0] > 0) if (c.at[1].earlier(now)) |d| if (d +| c.lim[0] > now) try violation(r, i, d, now);
    if (simultaneous(c) and c.at[1].at(now) and !c.at[1].reported) {
        c.at[1].reported = true;
        try violation(r, i, now, now);
    }
}

/// A data event at `now`: the timecheck of the window after the latest
/// reference event, "(timestamp time) <= (timecheck time) < (timestamp
/// time) + limit" (§15.2.2, §15.2.5, and the reference-first half of
/// §15.2.3/§15.2.6); one report per data event's time.
fn data(r: *Run, i: u32, now: u64) Error!void {
    const c = &r.tchks.items[i];
    c.at[1].note(now);
    const ts = c.at[0].last orelse return;
    const hit = if (ts == now) simultaneous(c) else now < ts +| c.lim[1];
    if (hit and !c.at[1].reported) {
        c.at[1].reported = true;
        try violation(r, i, ts, now);
    }
}

/// Check `i` detected a violation between its timestamp event at `stamp`
/// and its timecheck event at `check`: report it (W1199, VD-105; the bag
/// keeps one diagnostic per site, so a check's later violations add no
/// warning), toggle its notifier (Table 15-13, VD-103), and tell the host.
fn violation(r: *Run, i: u32, stamp: u64, check: u64) Error!void {
    const c = r.tchks.items[i];
    if (r.bag.enabled(.W1199)) {
        var path: std.Io.Writer.Allocating = .init(r.arena);
        defer path.deinit();
        @import("evcd.zig").path(r, &path.writer, c.scope) catch return error.OutOfMemory;
        const scale = r.timeOf(c.scope).scale;
        const start = r.starts[@min(c.tok, r.starts.len - 1)];
        try r.bag.add(r.stage(), .W1199, .{ .start = start, .end = start }, "`${s}` in {s}: timestamp event at {d}, timecheck event at {d}", .{
            @tagName(c.kind),
            path.written(),
            scale.realAt(stamp),
            scale.realAt(check),
        });
    }
    if (c.notifier) |at| try toggle(r, at);
    if (r.tchk_hook) |hook| hook(r, i);
}

/// Table 15-13 on each bit of notifier `at`: 0 -> 1, 1 -> 0, z -> z, and
/// x -> "Either 0 or 1", which is 1 here (VD-103).
fn toggle(r: *Run, at: u32) Error!void {
    const cur = r.values[at];
    var small: [2]u64 = undefined;
    const planes = if (cur.planes.len <= small.len) small[0..cur.planes.len] else try r.arena.alloc(u64, cur.planes.len);
    const words = cur.planes.len / 2;
    for (0..words) |w| {
        const v = cur.planes[w];
        const u = cur.planes[words + w];
        planes[w] = (v ^ ~u) & wordMask(cur.width, w);
        planes[words + w] = u & ~v;
    }
    try waiters.store(r, at, planes);
}

test "Table 15-13 per bit, and the stamp a window reads" {
    var s: Stamp = .{};
    s.note(3);
    s.note(5);
    try std.testing.expectEqual(@as(?u64, 3), s.earlier(5));
    s.note(5);
    try std.testing.expectEqual(@as(?u64, 3), s.earlier(5));
    try std.testing.expectEqual(@as(?u64, 5), s.earlier(6));
    try std.testing.expectEqual(@as(u8, Ast.TimingCheck.negedge_mask), Ast.TimingCheck.opposite(Ast.TimingCheck.posedge_mask));
    try std.testing.expect(matches(Ast.TimingCheck.posedge_mask, Ast.TimingCheck.transition('z', '1')));
    try std.testing.expect(!matches(Ast.TimingCheck.posedge_mask, Ast.TimingCheck.transition('1', 'x')));
    try std.testing.expectEqual(@as(u8, 0), Ast.TimingCheck.transition('x', 'z'));
}

test "§15.2.2: a $hold pair at one time violates whichever event comes first" {
    try root.expectRun(
        \\`timescale 1ns/1ns
        \\module c(clk, d);
        \\  input clk, d;
        \\  reg n;
        \\  initial #1 n = 1'b0;
        \\  always @(n) $display("%0d n=%b", $time, n);
        \\  specify
        \\    $hold(posedge clk, d, 3, n);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg clk, d;
        \\  c u(clk, d);
        \\  initial begin
        \\    clk = 0; d = 0;
        \\    #10 clk = 1; d = 1;
        \\    #5 clk = 0;
        \\    #5 d = 0; clk = 1;
        \\    #3 d = 1;
        \\  end
        \\endmodule
    , "1 n=0\n10 n=1\n20 n=0\n");
}

test "§15.5.1: with non-negative limits a delayed signal is its signal undelayed" {
    try root.expectRun(
        \\module c(clk, d);
        \\  input clk; input [1:0] d;
        \\  wire dclk; wire [1:0] dd;
        \\  always @(dclk or dd) $display("%0d %b %b", $time, dclk, dd[1]);
        \\  specify
        \\    $setuphold(posedge clk, d[1], 0, 0, , , , dclk, dd[1]);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg clk; reg [1:0] d;
        \\  c u(clk, d);
        \\  initial begin
        \\    #1 clk = 0; d = 2'b10;
        \\    #1 clk = 1;
        \\  end
        \\endmodule
    , "1 0 1\n2 1 1\n");
}

test "VD-103: a notifier a violation finds at x takes 1" {
    try root.expectRun(
        \\`timescale 1ns/1ns
        \\module c(clk, d);
        \\  input clk, d;
        \\  reg n;
        \\  specify
        \\    $setup(d, posedge clk, 5, n);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg clk, d;
        \\  c u(clk, d);
        \\  initial begin
        \\    clk = 0; d = 0;
        \\    #10 d = 1;
        \\    #2 clk = 1;
        \\    #1 $display("%b", u.n);
        \\  end
        \\endmodule
    , "1\n");
}

test "§15.6: an x on a deterministic condition's signal disables the event, though `x !== 1'b0` is true" {
    try root.expectRun(
        \\`timescale 1ns/1ns
        \\module c(clk, d, en);
        \\  input clk, d, en;
        \\  reg nc, nn;
        \\  initial #1 begin nc = 1'b0; nn = 1'b0; end
        \\  specify
        \\    $setup(d, posedge clk &&& (en !== 1'b0), 5, nc);
        \\    $setup(d, posedge clk &&& (en != 1'b0), 5, nn);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg clk, d, en;
        \\  c u(clk, d, en);
        \\  initial begin
        \\    clk = 0; d = 0;
        \\    #10 d = 1;
        \\    #2 clk = 1;
        \\    #1 $display("%b %b", u.nc, u.nn);
        \\  end
        \\endmodule
    , "0 1\n");
}

test "§15.3.5 $period: one reference edge to the next closer than the limit" {
    // Posedges at 10, 15 and 30: 15 - 10 = 5 < 10 violates at 15; 30 - 15 =
    // 15 does not. The first posedge has no earlier one to measure from, and
    // clk's x -> 0 at time 0 is no posedge.
    try root.expectRun(
        \\`timescale 1ns/1ns
        \\module c(clk);
        \\  input clk;
        \\  reg n;
        \\  initial #1 n = 1'b0;
        \\  always @(n) $display("%0d n=%b", $time, n);
        \\  specify
        \\    $period(posedge clk, 10, n);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg clk;
        \\  c u(clk);
        \\  initial begin
        \\    clk = 0;
        \\    #10 clk = 1; #2 clk = 0;
        \\    #3 clk = 1; #5 clk = 0;
        \\    #10 clk = 1;
        \\  end
        \\endmodule
    , "1 n=0\n15 n=1\n");
}

test "§15.3.4 $width: a pulse narrower than the limit and wider than the threshold" {
    // The pulse from the posedge at 10 to the negedge at 13 is 3 wide, and
    // 0 < 3 < 6 violates at 13; the one from 20 to 30 is 10 wide and does
    // not.
    try root.expectRun(
        \\`timescale 1ns/1ns
        \\module c(clk);
        \\  input clk;
        \\  reg n;
        \\  initial #1 n = 1'b0;
        \\  always @(n) $display("%0d n=%b", $time, n);
        \\  specify
        \\    $width(posedge clk, 6, 0, n);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg clk;
        \\  c u(clk);
        \\  initial begin
        \\    clk = 0;
        \\    #10 clk = 1; #3 clk = 0;
        \\    #7 clk = 1; #10 clk = 0;
        \\  end
        \\endmodule
    , "1 n=0\n13 n=1\n");
}

test "§15.2.5 $recovery: a data event within the limit after the reference" {
    // Table 15-5: the reference (rst's posedge) is the timestamp and the data
    // event (clk's posedge) the timecheck: 10 <= 12 < 10 + 4 violates at 12;
    // the later pair, 23 and 33, is 10 apart and does not.
    try root.expectRun(
        \\`timescale 1ns/1ns
        \\module c(rst, clk);
        \\  input rst, clk;
        \\  reg n;
        \\  initial #1 n = 1'b0;
        \\  always @(n) $display("%0d n=%b", $time, n);
        \\  specify
        \\    $recovery(posedge rst, posedge clk, 4, n);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg rst, clk;
        \\  c u(rst, clk);
        \\  initial begin
        \\    rst = 0; clk = 0;
        \\    #10 rst = 1; #2 clk = 1;
        \\    #5 clk = 0; #5 rst = 0;
        \\    #1 rst = 1; #10 clk = 1;
        \\  end
        \\endmodule
    , "1 n=0\n12 n=1\n");
}

test "§15.2.4 $removal: a data event within the limit before the reference" {
    // Table 15-4: the reference (rst's posedge) is the timecheck and the data
    // event (clk's posedge) the timestamp: 14 - 4 < 11 < 14 violates at 14;
    // clk's posedge at 20 against rst's at 30 is outside 26..30.
    try root.expectRun(
        \\`timescale 1ns/1ns
        \\module c(rst, clk);
        \\  input rst, clk;
        \\  reg n;
        \\  initial #1 n = 1'b0;
        \\  always @(n) $display("%0d n=%b", $time, n);
        \\  specify
        \\    $removal(posedge rst, posedge clk, 4, n);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg rst, clk;
        \\  c u(rst, clk);
        \\  initial begin
        \\    rst = 0; clk = 0;
        \\    #11 clk = 1; #3 rst = 1;
        \\    #1 clk = 0; #5 clk = 1;
        \\    #5 rst = 0; #5 rst = 1;
        \\  end
        \\endmodule
    , "1 n=0\n14 n=1\n");
}

test "Table 15-13: a violation turns a notifier's 1 to 0 and leaves its z" {
    // Two $period checks on one clock, one violation each at 15.
    try root.expectRun(
        \\`timescale 1ns/1ns
        \\module c(clk);
        \\  input clk;
        \\  reg n1, nz;
        \\  initial begin n1 = 1'b1; nz = 1'bz; end
        \\  specify
        \\    $period(posedge clk, 10, n1);
        \\    $period(posedge clk, 10, nz);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg clk;
        \\  c u(clk);
        \\  initial begin
        \\    clk = 0;
        \\    #10 clk = 1; #2 clk = 0; #3 clk = 1;
        \\    #1 $display("%b %b", u.n1, u.nz);
        \\  end
        \\endmodule
    , "0 z\n");
}

test "§15.6 a plain condition enables its event only while it is 1" {
    // `&&& en` with en = 0 hides the posedge at 15, so no period is measured
    // from 10 to 15; en = 1 from then on lets 25 against 30 violate.
    try root.expectRun(
        \\`timescale 1ns/1ns
        \\module c(clk, en);
        \\  input clk, en;
        \\  reg n;
        \\  initial #1 n = 1'b0;
        \\  always @(n) $display("%0d n=%b", $time, n);
        \\  specify
        \\    $period(posedge clk &&& en, 10, n);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg clk, en;
        \\  c u(clk, en);
        \\  initial begin
        \\    clk = 0; en = 1;
        \\    #10 clk = 1; #2 clk = 0;
        \\    en = 0; #3 clk = 1; #2 clk = 0;
        \\    en = 1; #8 clk = 1; #2 clk = 0;
        \\    #3 clk = 1;
        \\  end
        \\endmodule
    , "1 n=0\n30 n=1\n");
}

test "simultaneous: which window checks a same-time pair violates" {
    var c: Tchk = .{ .kind = .setup, .scope = 0, .tok = 0 };
    // "The end points of the time window are not part of the violation
    // region" of a window before the reference.
    try std.testing.expect(!simultaneous(&c));
    c.kind = .removal;
    try std.testing.expect(!simultaneous(&c));
    // A window after the reference holds its own start.
    c.kind = .hold;
    c.lim = .{ 0, 3 };
    try std.testing.expect(simultaneous(&c));
    c.kind = .recovery;
    try std.testing.expect(simultaneous(&c));
    c.kind = .setuphold;
    c.lim = .{ 0, 0 };
    try std.testing.expect(!simultaneous(&c));
    c.lim = .{ 2, 0 };
    try std.testing.expect(simultaneous(&c));
}
