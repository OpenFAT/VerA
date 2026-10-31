//! §4.5.7 absdelay history: a fixed ring of accepted (t, v) samples in, the
//! delayed value a residual reads out, plus the ring's push, thinning and
//! revert. Device text (`text.hist`); the ring storage is the caller's
//! (`Instance` fields), so these functions only read and write the slices
//! they are handed.
//! Cites: VAMS §4.5.7, §4.5.15.
//!
//! Contents:
//! - `pub fn zAbsdelay(comptime S: type, vin: S, ts: []const f64, vs: []const f64, head: u64, now: f64, dt: f64, td: f64) S`
//! - `pub fn zHistAt(ts: []const f64, vs: []const f64, head: u64, t: f64) f64`
//! - `pub fn zHistThin(comptime site: []const u8, ts: []f64, vs: []f64, head: *u64, now: f64, w: f64) void`
//! - `pub fn zhKept(n: usize) usize`
//! - `pub fn zHistRevert(ts: []f64, vs: []f64, head: u64, post: u64, t0: f64, v0: f64, t1: f64, v1: f64) void`
//! - `pub fn zHistPush(ts: []f64, vs: []f64, head: *u64, t: f64, v: f64) void`

const zhs = @import("std");

// ---- device text ----

/// A GPU target (`zSpec`'s test): `zHistThin` drops its host-only warning.
const zh_device = switch (@import("builtin").target.cpu.arch) {
    .nvptx64, .amdgcn => true,
    else => false,
};

/// Returns the delayed value as the residual sees it, Output(t) = Input(t - td)
/// (§4.5.7). A static analysis (`dt <= 0`) and an empty ring pass `vin`
/// through, derivative and all ("no state history prior to time t == 0",
/// §4.5.15). A lookback past the newest sample interpolates between it and
/// `vin`, which keeps the output continuous and carries the f·∂vin
/// derivative the td -> 0 limit needs; inside the history the value is a
/// constant (derivative 0), the companion model of a transport delay.
/// Asserts that `ts` and `vs` are one non-empty ring.
pub fn zAbsdelay(comptime S: type, vin: S, ts: []const f64, vs: []const f64, head: u64, now: f64, dt: f64, td: f64) S {
    zhs.debug.assert(ts.len == vs.len);
    zhs.debug.assert(ts.len > 0);
    if (dt <= 0.0) return vin;
    if (head == 0) return vin;
    const t = now - td;
    const newest: usize = @intCast((head + ts.len - 1) % ts.len);
    if (t > ts[newest]) {
        const span = now - ts[newest];
        if (span <= 0.0) return vin;
        // The f <= 1 clamp covers a run-time negative td, which lowering
        // rejects where it can fold.
        const f = @min((t - ts[newest]) / span, 1.0);
        return vin.scale(f).addC(vs[newest] * (1.0 - f));
    }
    return S.con(zHistAt(ts, vs, head, t));
}

/// Returns the ring's linear interpolation at `t`. `head` is the total count
/// of accepted samples, not a wrapped index: slot `head % n`. A `t` at or
/// before the oldest held sample reads that sample, which is Input(0) before
/// history began (§4.5.15's max(t - td, 0)) and the window's edge once a full
/// ring has forgotten older samples. Between samples the bracket is the
/// newest interval holding `t`. O(log n).
/// Asserts that `ts` and `vs` are one non-empty ring.
pub fn zHistAt(ts: []const f64, vs: []const f64, head: u64, t: f64) f64 {
    zhs.debug.assert(ts.len == vs.len);
    zhs.debug.assert(ts.len > 0);
    const n = ts.len;
    const oldest: usize = if (head > n) @intCast(head % n) else 0;
    if (t <= ts[oldest]) return vs[oldest];
    // Callers handle t > newest (`zAbsdelay`), so t <= ts[newest] here.
    const count: usize = @intCast(@min(head, n));
    if (count < 2) return vs[oldest]; // only a NaN t gets here
    // Binary search in age order (c = 0 the oldest live sample): `lo` ends
    // at the newest sample at or before t.
    var lo: usize = 0;
    var hi: usize = count;
    var probes: u32 = 0;
    while (hi - lo > 1) : (probes += 1) {
        zhs.debug.assert(probes < 64);
        const mid = lo + (hi - lo) / 2;
        if (ts[zhSlot(oldest + mid, n)] <= t) lo = mid else hi = mid;
    }
    const c = @min(lo + 1, count - 1);
    zhs.debug.assert(c >= 1);
    const older = zhSlot(oldest + c - 1, n);
    const newer = zhSlot(oldest + c, n);
    const span = ts[newer] - ts[older];
    if (span <= 0.0) return vs[newer];
    const f = (t - ts[older]) / span;
    return vs[older] + (vs[newer] - vs[older]) * f;
}

/// Keeps a full ring's window `w` (maxdelay, or td) before `updateState`
/// pushes the sample at `now`. A plain ring overwrites its oldest sample;
/// that is safe once the sample after it is at or before `now - w`, and then
/// this does nothing. Otherwise the ring is thinned: the older half keeps
/// every other sample (the oldest first), the newer half stays whole, the
/// ring is relaid oldest-first and `head` becomes its count, so the next
/// n/4 pushes overwrite nothing a lookback reads. The dropped samples stay
/// past the live ones until a push overwrites them, which is what lets
/// `zHistRevert` undo a thinning push. W1051 prints once per `site` on a
/// host; a GPU kernel has no stderr, so it thins silently.
/// Asserts that `ts` and `vs` are one ring.
pub fn zHistThin(comptime site: []const u8, ts: []f64, vs: []f64, head: *u64, now: f64, w: f64) void {
    zhs.debug.assert(ts.len == vs.len);
    const n = ts.len;
    // Below 8 samples a thinned ring would keep n - 1 and a revert could not
    // tell its push from a plain one; every device ring holds at least 1024.
    if (head.* < n or n < 8) return;
    const o: usize = @intCast(head.* % n);
    if (!(ts[(o + 1) % n] > now - w)) return;
    zhThin(ts, vs, o);
    head.* = zhKept(n);
    zhs.debug.assert(head.* < n);
    if (comptime zh_device) return;
    const Once = struct {
        const name = site;
        var warned = false;
    };
    if (Once.warned) return;
    Once.warned = true;
    var gap: f64 = 0.0;
    for (1..@as(usize, @intCast(head.*))) |i| gap = @max(gap, ts[i] - ts[i - 1]);
    zhs.debug.print("warning[W1051]: absdelay `{s}`: its {d}-sample history filled inside its {e} s window; " ++
        "older samples are now {e} s apart; see `vera --explain W1051`\n", .{ site, n, w, gap });
}

/// Returns how many samples a thinned ring of `n` keeps: every other one of
/// the older half `n / 2` (the first included), and all of the newer half.
pub fn zhKept(n: usize) usize {
    const k = (n / 2 + 1) / 2 + (n - n / 2);
    zhs.debug.assert(k <= n);
    zhs.debug.assert(k >= n / 2);
    return k;
}

/// Undoes the push since the last commit (`stateCtl(.revert)`). `head` is the
/// committed count, `post` the count the push left. A plain push overwrote
/// slot `head % n`, whose sample the commit kept in (`t0`, `v0`). A thinning
/// push (`post < head`) overwrote the ring's first dropped sample, kept in
/// (`t1`, `v1`); it goes back and the thinning is undone.
/// Asserts that `ts` and `vs` are one non-empty ring.
pub fn zHistRevert(ts: []f64, vs: []f64, head: u64, post: u64, t0: f64, v0: f64, t1: f64, v1: f64) void {
    zhs.debug.assert(ts.len == vs.len);
    zhs.debug.assert(ts.len > 0);
    const n = ts.len;
    const at: usize = @intCast(head % n);
    if (post >= head) {
        ts[at] = t0;
        vs[at] = v0;
        return;
    }
    // Only a thinning push lowers the count, and only a full ring thins.
    zhs.debug.assert(head >= n);
    const k = zhKept(n);
    ts[k] = t1;
    vs[k] = v1;
    zhUnthin(ts, vs, at);
}

/// Records the accepted sample (`t`, `v`) in slot `head % n`, overwriting
/// the oldest once the ring is full, and counts it in `head`, which as a
/// u64 of accepted steps never wraps.
/// Asserts that `ts` and `vs` are one non-empty ring.
pub fn zHistPush(ts: []f64, vs: []f64, head: *u64, t: f64, v: f64) void {
    zhs.debug.assert(ts.len == vs.len);
    zhs.debug.assert(ts.len > 0);
    const at: usize = @intCast(head.* % ts.len);
    ts[at] = t;
    vs[at] = v;
    head.* += 1;
}

// ---- private ----

/// Ring slot of age-order position `i` past the oldest, for `i < 2n`: a
/// subtraction, where `%` is a division per probe of `zHistAt`'s search.
fn zhSlot(i: usize, n: usize) usize {
    zhs.debug.assert(i < 2 * n);
    const s = i - n * @intFromBool(i >= n);
    zhs.debug.assert(s < n);
    return s;
}

/// The thinning permutation of a full ring whose oldest sample is at slot
/// `o`: oldest-first, then the older half's even samples, the newer half
/// and the older half's odd samples. In place, by rotations: a bottom-up
/// merge moves each block's odd samples past the next block's even ones.
fn zhThin(ts: []f64, vs: []f64, o: usize) void {
    const n = ts.len;
    zhs.debug.assert(n >= 8);
    zhs.debug.assert(o < n);
    const h = n / 2;
    zhRot(ts, vs, 0, n, o);
    var b: usize = 2;
    while (b < h) : (b *= 2) {
        var s: usize = 0;
        while (s + b < h) : (s += 2 * b) {
            const r = @min(b, h - s - b);
            zhRot(ts, vs, s + b / 2, b / 2 + (r + 1) / 2, b / 2);
        }
    }
    zhRot(ts, vs, (h + 1) / 2, n - (h + 1) / 2, h / 2);
}

/// `zhThin` undone: the same rotations, reversed, in reverse order.
fn zhUnthin(ts: []f64, vs: []f64, o: usize) void {
    const n = ts.len;
    zhs.debug.assert(n >= 8);
    zhs.debug.assert(o < n);
    const h = n / 2;
    const ce = (h + 1) / 2;
    zhRot(ts, vs, ce, n - ce, (n - ce) - h / 2);
    var b: usize = 2;
    while (b * 2 < h) b *= 2;
    while (b >= 2) : (b /= 2) {
        if (b >= h) continue;
        var s: usize = 0;
        while (s + b < h) : (s += 2 * b) {
            const r = @min(b, h - s - b);
            zhRot(ts, vs, s + b / 2, b / 2 + (r + 1) / 2, (r + 1) / 2);
        }
    }
    zhRot(ts, vs, 0, n, (n - o) % n);
}

/// Rotates `ts[a..][0..len]` and `vs` alike left by `by`.
fn zhRot(ts: []f64, vs: []f64, a: usize, len: usize, by: usize) void {
    zhs.debug.assert(a + len <= ts.len);
    zhs.debug.assert(by <= len);
    zhs.mem.rotate(f64, ts[a..][0..len], by);
    zhs.mem.rotate(f64, vs[a..][0..len], by);
}
