//! IEEE 1364-2005 §15 timing checks in the digital run: each instance's
//! A.7.5 `system_timing_check`s (`Ast.TimingCheck`) -> `Tchk` rows bound to
//! the slots their events name (`compile`, `arm`), then, at every change of
//! such a slot (`waiters.store` -> `changed`), the check judged at its
//! timecheck event: §15.2's stability window, §15.3.1-§15.3.3's skew (or,
//! timer-based, when its limit elapses: `expired`), §15.3.4's pulse width,
//! §15.3.5's period or §15.3.6's level window. A violation is reported
//! (W1199), toggles the notifier (§15.5, Table 15-13) and calls
//! `Run.checks.hook` (VAMS 12.31.4 cbTchkViolation). A form this file does
//! not evaluate (a negative $nochange end offset) is refused by name
//! (E1149), never accepted and ignored.
//!
//! When a check is judged (docs/specification/Vague_Decisions.md VD-104): at the event, in
//! the order the time step's events arrive. A reference and a data event
//! at the same time are one pair, judged once whichever comes first, so the
//! window rules do not depend on that order: a data event remembers whether
//! it already reported, and a stamp of the window before the reference is
//! the latest data event strictly before it.
//!
//! Cites: IEEE 1364-2005 §15.1-§15.7, Tables 15-1 to 15-13, §27.31
//! (`putLimits`); VAMS 12.29, 12.31.4.
//!
//! The rows are built in tchk_build.zig (the AST checks of each instance, their
//! limits and the §15.5 negative-limit solve); this file judges them and
//! re-exports what the rest of the interpreter calls.
//!
//! Contents:
//! - `pub const compileChecks`
//! - `pub const delayedDrivers`
//! - `pub const solveNegative`
//! - `pub const Kind = enum`
//! - `pub const kinds`
//! - `pub const Event = struct`
//! - `pub const Stamp = struct`
//! - `pub const Flags = packed struct(u8)`
//! - `pub const Checks = struct`
//! - `pub const Tchk = struct`
//! - `pub fn flag(r: *Run, t: *const Ast.TimingCheck, e: Ast.ExprId) Error!bool`
//! - `pub fn notifier(r: *Run, e: Ast.ExprId) Error!?u32`
//! - `pub fn arm(r: *Run) Error!void`
//! - `pub fn putLimits(r: *Run, scope: u32, tok: u32, ticks: []const u64) bool`
//! - `pub fn changed(r: *Run, slot: u32, before: Int.Bit, after: Int.Bit) Error!void`
//! - `pub fn delivered(r: *Run, code: u32, bit: u8) Error!void`
//! - `pub fn expired(r: *Run, i: u32, gen: u32) Error!void`
//! - `pub fn reference(r: *Run, i: u32, now: u64) Error!void`

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
const tchk_build = @import("tchk_build.zig");
const event = tchk_build.event;

/// `tchk_build.compileChecks`.
pub const compileChecks = tchk_build.compileChecks;

/// `tchk_build.delayedDrivers`.
pub const delayedDrivers = tchk_build.delayedDrivers;

/// `tchk_build.solveNegative`.
pub const solveNegative = tchk_build.solveNegative;

/// A.7.5.1's twelve commands. The tag is the command without its `$`.
pub const Kind = enum { setup, hold, setuphold, removal, recovery, recrem, skew, timeskew, fullskew, width, period, nochange };

pub const kinds = std.StaticStringMap(Kind).initComptime(.{
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
        if (s.last) |l| assert(l <= now); // Time never runs back.
        if (!s.at(now)) {
            s.before = s.last;
            s.reported = false;
        }
        s.last = now;
        assert(s.at(now));
    }

    /// Whether the latest occurrence is at `now`.
    fn at(s: Stamp, now: u64) bool {
        if (s.last) |l| assert(l <= now); // A stamp is never in the future.
        if (s.before) |b| assert(b <= s.last.?); // `before` is the occurrence preceding `last`.
        return if (s.last) |l| l == now else false;
    }

    /// The latest occurrence strictly before `now`.
    fn earlier(s: Stamp, now: u64) ?u64 {
        if (s.before) |b| assert(b <= now);
        const t = if (s.at(now)) s.before else s.last;
        if (t) |v| assert(v <= now);
        return t;
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

/// IEEE 1364-2005 §15 a run's timing checks: one row per check, in
/// elaboration order; the rows each watched slot's change reaches; the
/// §15.5.1 delays of each row's reference [0] and data [1] signal (parallel
/// to `rows`, empty when no negative limit made one, `solveNegative`); and
/// the host's violation callback (VAMS 12.31.4 cbTchkViolation, installed by
/// the VPI; nothing in the engine reads it).
pub const Checks = struct {
    rows: std.ArrayList(Tchk) = .empty,
    /// The checks a watched slot wakes, each as `check * 2 + event`.
    by_slot: std.AutoHashMapUnmanaged(u32, std.ArrayList(u32)) = .empty,
    delay: std.ArrayList([2]u64) = .empty,
    hook: ?*const fn (r: *Run, check: u32) void = null,
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
    /// `$setuphold`/`$recrem`'s stamptime and checktime conditions
    /// (A.7.5.1 arguments 6 and 7), `.none` when absent: an event is a
    /// timestamp only while the first holds and a timecheck only while the
    /// second does, read as §15.6 reads a `&&&` condition (`enabled`).
    stamp_cond: Ast.ExprId = .none,
    check_cond: Ast.ExprId = .none,
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
        std.debug.assert(@sizeOf(Tchk) == 208);
    }
};

/// Tables 15-8 and 15-9: an event_based_flag or remain_active_flag, a
/// "Constant expression", set when nonzero.
pub fn flag(r: *Run, t: *const Ast.TimingCheck, e: Ast.ExprId) Error!bool {
    assert(t.name != .none);
    if (e == .none) return false;
    assert(@backingInt(e) < r.file.exprs.len());
    const tok = r.file.exprs.mainTok(e);
    try compile.checkExpr(r, e);
    if (!compile.constantExpression(r, e))
        return r.failWith(.E1148, tok, "a flag of `{s}` is a constant expression (IEEE 1364-2005 Table 15-8); this one reads a signal", .{r.file.str(t.name)});
    if (compile.typeOf(r, e).real) return try evaluate.evalReal(r, r.arena, e) != 0;
    return ((try r.constant(e, tok)).asInt() orelse return r.failWith(.E1148, tok, "a flag of `{s}` has an x or z bit", .{r.file.str(t.name)})) != 0;
}

/// §15.5: "The notifier is a reg, declared in the module where timing check
/// tasks are invoked". A.7.5.2 `notifier ::= variable_identifier`.
pub fn notifier(r: *Run, e: Ast.ExprId) Error!?u32 {
    if (e == .none) return null;
    const ex = &r.file.exprs;
    if (ex.tag(e) != .ident and ex.tag(e) != .hier_ident) return r.failWith(.E1147, ex.mainTok(e), "a notifier is a variable identifier (A.7.5.2)", .{});
    const at = try r.slot(e);
    assert(at < r.values.len);
    if (r.netlist.slot_nets.contains(at) or r.decls.reals.contains(at) or r.decls.arrays.contains(at) or r.decls.events.contains(at) or r.decls.params.contains(at))
        return r.failWith(.E1147, ex.mainTok(e), "this notifier is not a reg (IEEE 1364-2005 §15.5: \"The notifier is a reg\")", .{});
    return at;
}

/// Files every check under the slots its events watch. After `Run.waits.watch`
/// exists, so once per run.
pub fn arm(r: *Run) Error!void {
    assert(r.checks.rows.items.len < std.math.maxInt(u32) / 2); // `i * 2 + k` codes fit.
    for (r.checks.rows.items, 0..) |c, i| {
        const n: usize = if (c.kind == .width or c.kind == .period) 1 else 2;
        for (c.ev[0..n], 0..) |ev, k| {
            r.waits.watch[ev.slot].insert(.tchk);
            const gop = try r.checks.by_slot.getOrPut(r.arena, ev.slot);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            try gop.value_ptr.append(r.arena, @intCast(i * 2 + k));
            assert(r.waits.watch[ev.slot].contains(.tchk));
        }
    }
}

/// IEEE 1364-2005 §27.31 / VAMS 12.29 vpi_put_delays on check (`scope`,
/// `tok`): `ticks` are its limits in A.7.5.1's written order. False when no
/// check is there.
pub fn putLimits(r: *Run, scope: u32, tok: u32, ticks: []const u64) bool {
    assert(ticks.len <= 2);
    assert(scope < r.hier.scopes.items.len);
    var hit = false;
    for (r.checks.rows.items) |*c| {
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

/// `waiters.store` changed `slot`, whose least significant bit went from
/// `before` to `after`: every check watching it judges the change.
pub fn changed(r: *Run, slot: u32, before: Int.Bit, after: Int.Bit) Error!void {
    assert(slot < r.values.len);
    const list = r.checks.by_slot.get(slot) orelse return;
    for (list.items) |code| {
        const i = code / 2;
        assert(i < r.checks.rows.items.len);
        const k: usize = code % 2;
        const bit = transitionOf(r, &r.checks.rows.items[i].ev[k], before, after) orelse continue;
        // §15.5.1 a delayed signal: the check sees the change later.
        const delay = if (r.checks.delay.items.len != 0) r.checks.delay.items[i][k] else 0;
        if (delay != 0) {
            _ = try exec.enqueue(r, .{ .tchk_event = .{ .code = code, .bit = bit } }, delay, false);
            continue;
        }
        try judge(r, i, k, bit);
    }
}

/// §15.5.3: a change `changed` delayed reaches its check now, "when the
/// delayed signals as measured by the adjusted timing check values are in
/// violation".
pub fn delivered(r: *Run, code: u32, bit: u8) Error!void {
    assert(code / 2 < r.checks.rows.items.len);
    try judge(r, code / 2, code % 2, bit);
}

/// §15.3.2: "A violation shall be reported immediately upon an elapse of
/// time after the reference event equal to the limit, and the check shall
/// become dormant": the timer of skew check `i` started at generation `gen`
/// ran out, unless a later window or a data event retired it.
/// $nochange's data event deferred to the inactive events is judged here.
pub fn expired(r: *Run, i: u32, gen: u32) Error!void {
    assert(i < r.checks.rows.items.len);
    const c = &r.checks.rows.items[i];
    if (c.kind == .nochange) return noChange(r, i, r.scheduler.now);
    if (!c.flags.active or c.gen != gen) return;
    sleep(c);
    assert(!c.flags.active);
    try violation(r, i, c.at[0].last.?, r.scheduler.now);
}

/// A reference event at `now`: the timecheck of the window before it,
/// "(timecheck time) - limit < (timestamp time) < (timecheck time)" with
/// the latest data event before `now` as the timestamp (§15.2.1, §15.2.4,
/// and the data-first half of §15.2.3/§15.2.6), and the second of a
/// simultaneous pair whose data event came first.
pub fn reference(r: *Run, i: u32, now: u64) Error!void {
    assert(i < r.checks.rows.items.len);
    assert(now == r.scheduler.now);
    const c = &r.checks.rows.items[i];
    if (try enabled(r, c.scope, c.stamp_cond)) c.at[0].note(now);
    if (!try enabled(r, c.scope, c.check_cond)) return;
    if (c.lim[0] > 0) if (c.at[1].earlier(now)) |d| if (d +| c.lim[0] > now) try violation(r, i, d, now);
    if (simultaneous(c) and c.at[1].at(now) and !c.at[1].reported) {
        c.at[1].reported = true;
        try violation(r, i, now, now);
    }
}

// ---- private ----

/// The §15.4 transition (`Ast.TimingCheck.transition`, 0 for none) that a
/// change of the slot made of `ev`'s bits, read on their least significant
/// bit (VD-104), or null when it left them alone. §15.7: "the transition of
/// one or more bits of a vector is considered a single transition".
fn transitionOf(r: *Run, ev: *Event, before: Int.Bit, after: Int.Bit) ?u8 {
    if (ev.width == 0) return Ast.TimingCheck.transition(bitChar(before), bitChar(after));
    assert(ev.width <= 64);
    assert(ev.slot < r.values.len);
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
    assert(bit < 1 << 6); // `TimingCheck.transition`: one of bits 0..5, or 0.
    assert(bit & (bit -% 1) == 0); // At most one transition.
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
    assert(scope < r.hier.scopes.items.len);
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
    assert(scope == r.scope);
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
    assert(i < r.checks.rows.items.len);
    assert(k < 2);
    const c = &r.checks.rows.items[i];
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
    assert(k < 2);
    const c = &r.checks.rows.items[i];
    assert(c.kind == .skew or c.kind == .timeskew or c.kind == .fullskew);
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
    assert(c.flags.active);
    if (!c.flags.event_based) _ = try exec.enqueue(r, .{ .tchk_expiry = .{ .check = i, .gen = c.gen } }, c.lim[k], false);
}

/// A skew check goes dormant; its pending timer is stale.
fn sleep(c: *Tchk) void {
    const gen = c.gen;
    c.flags.active = false;
    c.gen +%= 1;
    assert(c.gen != gen); // A stale expiry never matches again.
    assert(!c.flags.active);
}

/// §15.3.6: data event at `d` against $nochange `i`'s latest level,
/// "(leading reference edge time) - start_edge_offset < (data event time)
/// < (trailing reference edge time) + end_edge_offset", the trailing edge
/// unbounded while the level lasts; one report per data event's time.
// ponytail: a trailing edge an NBA makes lands after the deferred judgement
// (`judge`), so that pair still violates; judge in the monitor region if it
// matters.
fn noChange(r: *Run, i: u32, d: u64) Error!void {
    const c = &r.checks.rows.items[i];
    assert(c.kind == .nochange);
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
    assert(c.lim.len == 2);
    assert(c.kind != .width);
    return switch (c.kind) {
        .setup, .removal => false,
        .hold, .recovery, .setuphold, .recrem => c.lim[0] > 0 or c.lim[1] > 0,
        .width, .period, .skew, .timeskew, .fullskew, .nochange => unreachable, // judged by `judge` itself
    };
}

/// A data event at `now`: the timecheck of the window after the latest
/// reference event, "(timestamp time) <= (timecheck time) < (timestamp
/// time) + limit" (§15.2.2, §15.2.5, and the reference-first half of
/// §15.2.3/§15.2.6); one report per data event's time.
fn data(r: *Run, i: u32, now: u64) Error!void {
    assert(i < r.checks.rows.items.len);
    assert(now == r.scheduler.now);
    const c = &r.checks.rows.items[i];
    if (try enabled(r, c.scope, c.stamp_cond)) c.at[1].note(now);
    if (!try enabled(r, c.scope, c.check_cond)) return;
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
    assert(i < r.checks.rows.items.len);
    assert(stamp <= check or r.checks.rows.items[i].kind == .nochange);
    const c = r.checks.rows.items[i];
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
    if (r.checks.hook) |hook| hook(r, i);
}

/// Table 15-13 on each bit of notifier `at`: 0 -> 1, 1 -> 0, z -> z, and
/// x -> "Either 0 or 1", which is 1 here (VD-103).
fn toggle(r: *Run, at: u32) Error!void {
    assert(at < r.values.len);
    const cur = r.values[at];
    assert(cur.planes.len % 2 == 0);
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

test "§15.5.3: with negative timing on, a shared delayed reference detects a violation late" {
    // The suite's negative_timing_notifier_toggles_at_delayed_detection.v,
    // derived by hand: `$setuphold(posedge clk, d, -2, 5, na)` needs clk's
    // one delayed signal at least 2 ticks (1 more for the margin) after d's,
    // so the second check, `$setuphold(posedge clk, e, 3, 3, nb)`, sees e's
    // change at 99 against clk's edge at 100 only at the delayed edge, after
    // 101. With the option off the limit is 0 and the violation is at 100.
    const src =
        \\`timescale 1ns/1ns
        \\module c(input clk, input d, input e);
        \\  reg na, nb;
        \\  initial #1 begin na = 0; nb = 0; end
        \\  specify
        \\    $setuphold(posedge clk, d, -2, 5, na);
        \\    $setuphold(posedge clk, e, 3, 3, nb);
        \\  endspecify
        \\endmodule
        \\module t;
        \\  reg clk = 0, d = 0, e = 0;
        \\  c u(clk, d, e);
        \\  initial begin
        \\    #99 e = 1;
        \\    #1 clk = 1;
        \\    #1 $display("%0d %b %b", $time, u.na, u.nb);
        \\    #39 $display("%0d %b %b", $time, u.na, u.nb);
        \\  end
        \\endmodule
    ;
    for ([_]struct { on: bool, want: []const u8 }{
        .{ .on = true, .want = "101 0 0\n140 0 1\n" },
        .{ .on = false, .want = "101 0 1\n140 0 1\n" },
    }) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var bag = @import("diag").Bag.init(arena.allocator());
        var out = std.Io.Writer.Allocating.init(arena.allocator());
        try root.run(arena.allocator(), src, .{ .negative_timing = case.on }, &bag, &out.writer);
        try std.testing.expectEqualStrings(case.want, out.written());
    }
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
