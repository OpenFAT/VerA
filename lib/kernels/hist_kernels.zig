//! §4.5.7 absdelay history -> the delayed value a residual reads, and the
//! fixed ring of accepted samples it reads from. Embedded into every device
//! with an absdelay (`kernel_text.hist_txt` drops this paragraph: it cuts at
//! the first blank line) and tested by `tests/unit.zig`, so the ring the
//! tests check is the ring the device runs. LRM: §4.5.7, §4.5.15.

// `std` is `zhs` here for the reason `str_kernels.zig` spells it `zstd`: the
// text sits at the file scope of a device that already declares `const std`.
const zhs = @import("std");

/// §4.5.7 the delayed value, as the residual sees it: Output(t) = Input(t − td).
///
/// Two edges are decided HERE rather than by the ring scan below:
///
///  · dt ≤ 0 is a static analysis — "In DC and operating point analyses,
///    absdelay() returns the value of its input" — so `vin` passes through,
///    derivative and all, exactly like `zTransition`'s DC branch.
///  · a td SHORTER than the step the host just took queries past the newest
///    accepted sample. The only data covering (ts[newest], now] is the
///    CURRENT in-flight value, so the answer interpolates between the newest
///    sample and `vin` — the same linear reading `zHistAt` applies inside
///    the history. That keeps the output continuous in t and carries the
///    f·∂vin derivative the td → 0 (identity) limit requires. The scan used
///    to fall through to the newest sample here, which silently stretched
///    every delay shorter than a step to the step itself. (Clamping was the
///    other candidate; it answers a PAST query with a value from the wrong
///    time and keeps the Jacobian blind to an input the output already
///    partially tracks, so interpolation is the sound choice.)
///
/// Inside the history the delayed value has no dependence on the current
/// unknowns, so it is injected as a constant (derivative 0) — the correct
/// companion model for a pure transport delay. The f ≤ 1 clamp covers a
/// runtime-negative td, which lowering rejects where it can fold.
pub fn zAbsdelay(comptime S: type, vin: S, ts: []const f64, vs: []const f64, head: u64, now: f64, dt: f64, td: f64) S {
    if (dt <= 0.0) return vin;
    // §4.5.15 "no state history prior to time t == 0": nothing has been
    // accepted yet, so the input IS the output. The ring used to be SEEDED
    // full on the first push, which made this unreachable; `head` is a
    // count now, so the empty ring has to answer for itself.
    if (head == 0) return vin;
    const t = now - td;
    const newest: usize = @intCast((head + ts.len - 1) % ts.len);
    if (t > ts[newest]) {
        const span = now - ts[newest];
        if (span <= 0.0) return vin;
        const f = @min((t - ts[newest]) / span, 1.0);
        return vin.scale(f).addC(vs[newest] * (1.0 - f));
    }
    return S.con(zHistAt(ts, vs, head, t));
}
/// §4.5.7 absdelay history: a fixed ring of (t, v) samples, linearly
/// interpolated. `head` is the TOTAL number of accepted samples pushed, not
/// a wrapped index — the ring slot is `head % n`. That one extra fact is
/// what separates the two queries that used to answer the same way: a
/// query before recorded history began, which §4.5.15 settles ("all analog
/// operators are considered to have no state history prior to time t == 0")
/// and `Output(t) = Input(max(t − td, 0))` answers with Input(0); and a
/// query the ring has FORGOTTEN, which the clause settles not at all.
pub fn zHistAt(ts: []const f64, vs: []const f64, head: u64, t: f64) f64 {
    const n = ts.len;
    const wrapped = head > n;
    const oldest: usize = if (wrapped) @intCast(head % n) else 0;
    // O(1) for a query at or before the oldest sample — the scan would walk
    // all n entries to reach the same answer.
    // Before the first sample the operator HAS no history, and Input(0) is
    // the value the formula's max(t − td, 0) floor asks for. A ring that
    // filled keeps its window (`zHistThin`), so a lookback older than the
    // oldest sample is one the window does not hold: a td past maxdelay
    // or a host that never commits. It reads the oldest sample.
    if (t <= ts[oldest]) return vs[oldest];
    // Binary search in age order (c = 0 is the oldest live sample): `lo`
    // ends at the newest sample at or before t, so the bracket is the
    // NEWEST interval holding t, the one a scan from the newest end finds
    // first. O(log n): a 5 ns line at 1 ps looks 5000 samples back.
    // `zAbsdelay` covers t > newest, so t ≤ ts[newest] here.
    const count: usize = @intCast(@min(head, n));
    if (count < 2) return vs[oldest]; // only a NaN t gets here
    var lo: usize = 0;
    var hi: usize = count;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (ts[zhSlot(oldest + mid, n)] <= t) lo = mid else hi = mid;
    }
    const c = @min(lo + 1, count - 1);
    const older = zhSlot(oldest + c - 1, n);
    const newer = zhSlot(oldest + c, n);
    const span = ts[newer] - ts[older];
    if (span <= 0.0) return vs[newer];
    const f = (t - ts[older]) / span;
    return vs[older] + (vs[newer] - vs[older]) * f;
}
/// Ring slot of age-order position `i` past `oldest`, for `i < 2 n`: a
/// subtraction, where `%` is a division per probe of `zHistAt`'s search.
fn zhSlot(i: usize, n: usize) usize {
    return i - n * @intFromBool(i >= n);
}

/// §4.5.7 a full ring keeps its window. Called by `updateState` before it
/// pushes the sample at `now`. A plain ring would overwrite its oldest
/// sample; that is safe once the sample after it is at or before `now - w`
/// (every later lookback, `t' - w` with `t' > now`, lands at or after it), and
/// then nothing happens here. Otherwise the oldest sample is still inside the
/// window `w` (maxdelay, or td), and the ring is thinned instead: the older
/// half keeps every other sample (the oldest first), the newer half stays
/// whole, and the ring is relaid oldest-first with `head` its count, so the
/// next n/4 pushes overwrite nothing a lookback reads. The dropped samples
/// are kept, past the live ones, until a push overwrites them: that is what
/// lets `zHistRevert` undo a thinning push exactly. A ring that never thins
/// answers exactly as a plain ring does. W1051 prints once per site, with the
/// widest spacing left, on a host only: a GPU kernel has no stderr and no
/// mutable global for the once-flag, so it thins silently (same samples).
pub fn zHistThin(comptime site: []const u8, ts: []f64, vs: []f64, head: *u64, now: f64, w: f64) void {
    const n = ts.len;
    // Below 8 samples a thinned ring would keep n - 1 and a revert could not
    // tell its push from a plain one; every device ring holds at least 1024.
    if (head.* < n or n < 8) return;
    const o: usize = @intCast(head.* % n);
    if (!(ts[(o + 1) % n] > now - w)) return;
    zhThin(ts, vs, o);
    head.* = zhKept(n);
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

/// A GPU target (`zSpec`'s test): `zHistThin` drops its host-only warning.
const zh_device = switch (@import("builtin").target.cpu.arch) {
    .nvptx64, .amdgcn => true,
    else => false,
};

/// The samples a thinned ring of `n` keeps: every other one of the older
/// half `n / 2` (the first included), and all of the newer half.
pub fn zhKept(n: usize) usize {
    return (n / 2 + 1) / 2 + (n - n / 2);
}

/// `stateCtl(.revert)` of the push since the last commit. `head` is back to
/// the committed count; `post` is the count the push left. A push that did
/// not thin overwrote slot `head % n`, whose sample the commit kept in
/// (`t0`, `v0`): the plain ring's revert. A thinning push (`post < head`)
/// overwrote the first dropped sample, the ring's second-oldest, which the
/// commit kept in (`t1`, `v1`); it goes back, and the thinning is undone.
pub fn zHistRevert(ts: []f64, vs: []f64, head: u64, post: u64, t0: f64, v0: f64, t1: f64, v1: f64) void {
    const n = ts.len;
    const at: usize = @intCast(head % n);
    if (post >= head) {
        ts[at] = t0;
        vs[at] = v0;
        return;
    }
    const k = zhKept(n);
    ts[k] = t1;
    vs[k] = v1;
    zhUnthin(ts, vs, at);
}

/// Rotates `ts[a..][0..len]` and `vs` alike left by `by`.
fn zhRot(ts: []f64, vs: []f64, a: usize, len: usize, by: usize) void {
    zhs.mem.rotate(f64, ts[a..][0..len], by);
    zhs.mem.rotate(f64, vs[a..][0..len], by);
}

/// The thinning permutation of a full ring whose oldest sample is at slot
/// `o`: oldest-first, then the older half's even samples, the newer half and
/// the older half's odd samples. In place, by rotations: a bottom-up merge
/// moves each block's odd samples past the next block's even ones.
fn zhThin(ts: []f64, vs: []f64, o: usize) void {
    const n = ts.len;
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
/// Records the accepted sample (`t`, `v`) in slot `head % n`, overwriting the
/// oldest once the ring is full, and counts it in `head`.
pub fn zHistPush(ts: []f64, vs: []f64, head: *u64, t: f64, v: f64) void {
    const at: usize = @intCast(head.* % ts.len);
    ts[at] = t;
    vs[at] = v;
    // `head` is a COUNT, and zHistAt reads `head > n` as "the ring has
    // overwritten its oldest sample"; a u64 of accepted steps never wraps.
    head.* += 1;
}
