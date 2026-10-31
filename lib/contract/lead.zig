//! A batch family and a `batch_lead` device's decisions in, per-point
//! results bit-identical to a scalar family's out: the lead protocol's
//! bookkeeping (`LeadState`), its compile-time gates (`leads`, `instLanes`),
//! its per-point merge (`leadMergeInto`) and the region signature a host
//! buckets points by (`region`).
//! Cites: none (VerA's own batch protocol; the per-point semantics are the
//! scalar family's).
//!
//! A device that declares `batch_lead` decides on per-point values: it
//! compares reals, rounds them to integers, strips their lanes, or runs a
//! kernel that steers on them. A batch family (`V` a vector of W points) that
//! evaluates such a device implements the protocol, and every result it
//! returns is then exactly, bit for bit, what a scalar family computes for
//! that point alone, divergent batches included (they only cost more runs):
//!
//!   on the family S:  `Inner` (the family the runs use: the same `V`/`Of`/
//!                     `con`/`probe`/`sel`/`lift`, with the hooks below and
//!                     without `Inner`), `leadBegin()`, `leadNext() bool`,
//!                     `leadMerge(out: *R, new: R)` (`leadMergeInto`);
//!   on S.Inner:       `decide(op, a, b) bool`, `decideI(a) i64`,
//!                     `strip(a) Of(0)`, `Lane` (a scalar family with the same
//!                     lanes), `lane_count`, `laneOf(a, comptime w)`,
//!                     `fromLanes(comptime m, [lane_count]Lane.Of(m)) Of(m)`.
//!
//! `decide` compares per point and answers the leader's result; a point whose
//! own result differs is marked diverged. The device's entry points run the
//! batch, then while `leadNext()` names a new leader (the first point not yet
//! finished) run it again and `leadMerge` the points that finished in that
//! run: those that never diverged from its leader, so every decision they met
//! was their own. `LeadState` is the bookkeeping. A vector family without the
//! protocol is refused at compile time (`zLeads`).
//!
//! The batch key. Every point of a batched call shares the `Model` row (card,
//! temperature, setup cache, port mask) and the `SimState`; nothing else.
//! Each point has its own `Instance`: a device that reads per-instance state
//! in `eval`/`q`/`evalQ` (a §5.10 held variable, a `$prev` path latch,
//! `$mfactor`) declares `batch_inst`, and its batch family supplies
//!
//!   on the family that runs the core (S.Inner under the protocol, else S):
//!                     `instLane(comptime T: type, comptime w: usize) *const T`,
//!                     point w's `Instance` (T is `D.Instance`), with `Lane`,
//!                     `lane_count` and `fromLanes` as above;
//!
//! the `inst` argument of the batched call is then not read for those fields.
//! A real field reads per point (`zInst`); an integer one is a decision
//! (`zInstI`, the lead protocol). Per-instance state no point can carry this
//! way (operator history, a held array, `$limit`'s previous value) drops
//! `batch_ok`. A vector family without `instLane` is refused at compile time.
//! `updateState`, `setupInstance` and `initState` stay per instance: the host
//! calls them on each instance with its own bias; they have no batched form.
//!
//! Contents:
//! - `pub fn leads(comptime S: type) bool`
//! - `pub fn instLanes(comptime S: type) bool`
//! - `pub fn LeadState(comptime W: usize, comptime sig: bool) type`, with `begin`,
//!   `mark`, `markI`, `keep`, `next`, `regions`
//! - `pub fn leadMergeInto(out: anytype, new: @TypeOf(out.*), keep: anytype) void`
//! - `pub fn region(comptime D: type, x: *const [nU(D)]f64, model: *const D.Model, inst: InstancePtr(D), sim: SimState) u16`,
//!   evaluated with a private family whose `V`, `Of`, `con`, `probe`, `sel`,
//!   `collapse_applied`, `decide`, `decideI` and `strip` record each decision

const std = @import("std");
const assert = std.debug.assert;
const family = @import("family.zig");
const masks = @import("masks.zig");
const sim_state = @import("sim_state.zig");
const testing = std.testing;
const mocks = @import("mock_devices.zig");
const nU = masks.nU;
const InstancePtr = sim_state.InstancePtr;
const SimState = sim_state.SimState;

/// The most points one batched call evaluates: `LeadState`'s bit sets.
const points_max = 32;
/// FNV-1a's offset basis, the region hash's seed.
const sig_seed: u64 = 0xcbf29ce484222325;
/// FNV-1a's 64-bit prime.
const sig_prime: u64 = 0x100000001b3;

/// Whether a `batch_lead` device's entry point runs the protocol for
/// family `S`: yes for a family with `Inner`, no for a run inside it (`S`
/// has `decide`) or a one-point family. A vector family without the
/// protocol cannot evaluate the device exactly, so it is refused here.
pub fn leads(comptime S: type) bool {
    if (@hasDecl(S, "Inner")) return true;
    if (@hasDecl(S, "decide")) return false;
    if (@typeInfo(S.V) == .vector) @compileError("this device decides per operating point (`batch_lead`): a batch family needs the lead protocol (contract.zig `batch_lead`)");
    return false;
}

/// Whether a `batch_inst` device reads its per-instance fields per point
/// through `S.instLane` (a batch family) or from `inst` (a one-point
/// family). A vector family without `instLane` would read point 0's
/// instance for every point, so it is refused here.
pub fn instLanes(comptime S: type) bool {
    if (@hasDecl(S, "instLane")) return true;
    if (@typeInfo(S.V) == .vector) @compileError("this device reads per-instance state (`batch_inst`): a batch family needs `instLane(T, w)`, each point's own `Instance` (contract.zig `batch_inst`)");
    return false;
}

/// The lead protocol's per-call bookkeeping for W points (W <= 32). With
/// `sig`, it also hashes each point's own decision outcomes as `region`
/// does: a point kept from a run took its own path through it, so
/// `regions()` after the call equals `region` at every point, without an
/// extra evaluation (it costs the batched call 2-15% more instructions).
/// Invariant: `div` and the leader's bit never overlap, and `done` only grows.
pub fn LeadState(comptime W: usize, comptime sig: bool) type {
    comptime assert(W >= 1);
    comptime assert(W <= points_max);
    return struct {
        const Bits = @Int(.unsigned, W);
        const all: Bits = std.math.maxInt(Bits);
        const H = @Vector(W, u64);
        leader: std.math.Log2Int(Bits) = 0,
        done: Bits = 0,
        div: Bits = 0,
        h: if (sig) H else void = if (sig) @splat(sig_seed) else {},
        out: if (sig) H else void = if (sig) @splat(sig_seed) else {},

        /// Runs the protocol for the batch about to be evaluated.
        pub fn begin(s: *@This()) void {
            s.* = .{};
            assert(s.done == 0);
        }

        /// The leader's outcome of one decision whose per-point outcomes
        /// are `c`; marks the points that disagree.
        pub fn mark(s: *@This(), c: @Vector(W, bool)) bool {
            if (sig) s.h = sigMix(s.h, @intFromBool(c));
            const bits: Bits = @bitCast(c);
            // Every point agrees: nothing to record (the common case).
            if (bits == 0) return false;
            if (bits == all) return true;
            const l = (bits >> s.leader) & 1 != 0;
            s.div |= bits ^ (if (l) all else 0);
            assert((s.div >> s.leader) & 1 == 0); // The leader agrees with itself.
            return l;
        }

        /// The leader's value of one real→integer decision whose per-point
        /// values are `r`; marks the points whose value differs.
        pub fn markI(s: *@This(), r: @Vector(W, i64)) i64 {
            if (sig) s.h = sigMix(s.h, @as(H, @bitCast(r)));
            const ra: [W]i64 = r;
            const l = ra[s.leader];
            s.div |= ~@as(Bits, @bitCast(r == @as(@Vector(W, i64), @splat(l))));
            assert((s.div >> s.leader) & 1 == 0);
            return l;
        }

        /// The points the run just finished settled: not done before, not
        /// diverged in it.
        pub fn keep(s: *const @This()) @Vector(W, bool) {
            return @bitCast(~s.done & ~s.div);
        }

        /// Marks the last run's points done; false when every point is,
        /// else names the next leader and clears the divergence.
        pub fn next(s: *@This()) bool {
            if (sig) {
                s.out = @select(u64, s.keep(), s.h, s.out);
                s.h = @splat(sig_seed);
            }
            const done_before = s.done;
            s.done |= ~s.done & ~s.div;
            // The leader never diverges from itself, so every run finishes it.
            assert(s.done != done_before);
            if (s.done == all) return false;
            s.leader = @intCast(@ctz(~s.done));
            s.div = 0;
            assert((s.done >> s.leader) & 1 == 0);
            return true;
        }

        /// Each point's `region` signature, once `next()` returned false.
        pub fn regions(s: *const @This()) [W]u16 {
            comptime assert(sig);
            assert(s.done == all);
            // SAFETY: the loop writes all W entries.
            var r: [W]u16 = undefined;
            inline for (0..W) |w| r[w] = sigFold(s.out[w]);
            return r;
        }
    };
}

/// `leadMerge`'s walk: copies from `new` into `out` the points `keep` names,
/// through arrays and structs (tuples included) down to values that declare
/// `leadKeep(self: *T, new: T, keep)`. A compile error names the first type
/// with no per-point merge.
pub fn leadMergeInto(out: anytype, new: @TypeOf(out.*), keep: anytype) void {
    const T = @TypeOf(out.*);
    switch (@typeInfo(T)) {
        .array => for (out, new) |*o, n| leadMergeInto(o, n, keep),
        .@"struct" => |s| if (@hasDecl(T, "leadKeep")) {
            out.leadKeep(new, keep);
        } else inline for (s.field_names) |name| leadMergeInto(&@field(out, name), @field(new, name), keep),
        else => @compileError("leadMergeInto: no per-point merge for " ++ @typeName(T)),
    }
}

/// A `batch_lead` device's region signature at the operating point `x`: a
/// 16-bit hash of the outcome of every decision its `eval` makes there (the
/// comparisons, roundings and strips the lead protocol watches), in order.
/// Two points with the same decision sequence have the same signature, so a
/// batch of points with equal signatures runs once (no divergence), up to
/// hash collisions, which cost only a re-run. Correctness never depends on
/// it: a batched call is exact per point either way. Cost: one value-only
/// `eval`, of which the optimizer keeps only what the decisions read (setup
/// values are read from the `Model` row, not recomputed; `inst` is the
/// point's own instance, whose held values and latches the decisions may
/// read). That cone can be most of
/// the model: measured 0.25-0.74 of a scalar `evalQ`
/// (`git show 6e59b3d4^:docs/measurements/batched-lead-2026-10-02.md`). So a host buckets on the
/// signatures a batched call already produced (`LeadState.regions`, equal
/// to this value at every point) and calls `region` only for a point that
/// has none yet. A device without `batch_lead` never diverges: its
/// signature is the comptime constant 0, and a host skips the call.
/// Not reentrant: one thread's calls must not interleave (the hash lives in
/// a thread-local).
pub fn region(comptime D: type, x: *const [nU(D)]f64, model: *const D.Model, inst: InstancePtr(D), sim: SimState) u16 {
    const Sig = Signature(nU(D));
    if (comptime !@hasDecl(D, "batch_lead")) return 0; // never divergent
    Sig.h = sig_seed;
    _ = D.eval(Sig, x, model, inst, sim);
    const r = sigFold(Sig.h);
    Sig.h = sig_seed;
    return r;
}

// ---- private ----

/// FNV-1a step of the region hash, on one point (`u64`) or W (`@Vector`).
fn sigMix(h: anytype, v: anytype) @TypeOf(h) {
    const T = @TypeOf(h);
    const vv: T = if (@typeInfo(T) == .vector) @intCast(v) else v;
    return (h ^ vv) *% @as(T, if (@typeInfo(T) == .vector) @splat(sig_prime) else sig_prime);
}

/// The 64-bit hash folded to the 16-bit signature.
fn sigFold(h: u64) u16 {
    return @truncate(h ^ (h >> 16) ^ (h >> 32) ^ (h >> 48));
}

/// The value family `region` evaluates with: `RefFamily`'s lane-free values,
/// and the lead protocol's decision hooks recording outcomes into `h`.
fn Signature(comptime n: usize) type {
    const F = family.RefFamily(f64, &@as([n]u8, @splat(family.no_lane)), .{});
    return struct {
        pub const V = F.V;
        pub const Of = F.Of;
        pub const con = F.con;
        pub const probe = F.probe;
        pub const sel = F.sel;
        pub const collapse_applied = F.collapse_applied;
        // A family's hooks are free functions of the family type, with no
        // receiver to carry the hash, so it is a thread-local the one caller,
        // `region`, seeds before and reads after its `eval`.
        threadlocal var h: u64 = 0;
        fn mix(v: u64) void {
            h = sigMix(h, v);
        }
        pub fn decide(comptime op: std.math.CompareOperator, a: anytype, b: anytype) bool {
            const r = std.math.compare(a.val(), op, b.val());
            mix(@intFromBool(r));
            return r;
        }
        pub fn decideI(a: anytype) i64 {
            const r = std.math.lossyCast(i64, @round(a.val()));
            mix(@bitCast(r));
            return r;
        }
        pub fn strip(a: anytype) Of(0) {
            return F.con(a.val());
        }
    };
}

test "LeadState: the leader decides, disagreeing points re-run, every point finishes once" {
    var s: LeadState(4, true) = .{};
    s.begin();
    // Run 1, leader 0: points 1 and 3 disagree on the first decision.
    try testing.expect(s.mark(.{ true, false, true, false }));
    try testing.expect(!s.mark(.{ false, false, false, false })); // all agree
    try testing.expectEqual(@Vector(4, bool){ true, false, true, false }, s.keep());
    try testing.expect(s.next());
    try testing.expectEqual(@as(u2, 1), s.leader);
    // Run 2, leader 1: point 3 agrees this time.
    try testing.expect(!s.mark(.{ true, false, true, false }));
    try testing.expectEqual(@Vector(4, bool){ false, true, false, true }, s.keep());
    try testing.expect(!s.next());
}

test "LeadState.markI: the leader's integer decides; a point that rounds elsewhere re-runs" {
    var s: LeadState(4, false) = .{};
    s.begin();
    try testing.expectEqual(@as(i64, 3), s.markI(.{ 3, 3, 4, 3 }));
    try testing.expectEqual(@Vector(4, bool){ true, true, false, true }, s.keep());
    try testing.expect(s.next());
    try testing.expectEqual(@as(u2, 2), s.leader);
    // Run 2 under point 2: the others differ, but they are done.
    try testing.expectEqual(@as(i64, 4), s.markI(.{ 3, 3, 4, 3 }));
    try testing.expectEqual(@Vector(4, bool){ false, false, true, false }, s.keep());
    try testing.expect(!s.next());

    // One point: every decision is unanimous, and one run finishes it.
    var one: LeadState(1, false) = .{};
    one.begin();
    try testing.expect(one.mark(.{true}));
    try testing.expect(!one.mark(.{false}));
    try testing.expect(!one.next());
}

test "LeadState.regions: each point's signature hashes its own decisions, as `region` does" {
    var s: LeadState(2, true) = .{};
    s.begin();
    // Run 1, leader 0: point 1 decides the other way and diverges.
    try testing.expect(s.mark(.{ true, false }));
    try testing.expect(s.next());
    // Run 2, leader 1, on its own decision; point 0 is done.
    try testing.expect(!s.mark(.{ true, false }));
    try testing.expect(!s.next());
    const r = s.regions();
    try testing.expectEqual(sigFold(sigMix(sig_seed, @as(u64, 1))), r[0]);
    try testing.expectEqual(sigFold(sigMix(sig_seed, @as(u64, 0))), r[1]);
}

test "region: the hash of a point's decision sequence; 0 for a device that never diverges" {
    // 1.5 > 0.5, then round(1.5) = 2: two outcomes, in order.
    const want = sigFold(sigMix(sigMix(sig_seed, @as(u64, 1)), @as(u64, 2)));
    try testing.expectEqual(want, region(mocks.MockLead, &.{ 1.5, 0.5 }, &.{}, &.{}, .{}));
    // 0.25 > 2 is false, and round(0.25) = 0.
    const off = sigFold(sigMix(sigMix(sig_seed, @as(u64, 0)), @as(u64, 0)));
    try testing.expectEqual(off, region(mocks.MockLead, &.{ 0.25, 2 }, &.{}, &.{}, .{}));
    try testing.expectEqual(@as(u16, 0), region(mocks.MockR, &.{ 1, 0 }, &.{}, &.{}, .{}));
}

test "leadMergeInto: through structs and arrays to each value's own per-point keep" {
    const Pt = struct {
        v: @Vector(2, f64),
        pub fn leadKeep(self: *@This(), new: @This(), keep: @Vector(2, bool)) void {
            self.v = @select(f64, keep, new.v, self.v);
        }
    };
    const R = struct { a: Pt, b: [2]Pt };
    var out: R = .{ .a = .{ .v = .{ 1, 2 } }, .b = .{ .{ .v = .{ 3, 4 } }, .{ .v = .{ 5, 6 } } } };
    const new: R = .{ .a = .{ .v = .{ 10, 20 } }, .b = .{ .{ .v = .{ 30, 40 } }, .{ .v = .{ 50, 60 } } } };
    leadMergeInto(&out, new, @Vector(2, bool){ false, true });
    try testing.expectEqual(@Vector(2, f64){ 1, 20 }, out.a.v);
    try testing.expectEqual(@Vector(2, f64){ 3, 40 }, out.b[0].v);
    try testing.expectEqual(@Vector(2, f64){ 5, 60 }, out.b[1].v);
}
