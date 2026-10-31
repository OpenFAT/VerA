//! Timer controls and an observation time -> the next absolute event
//! deadline, VAMS §5.10.3.3. Device text (`text.timer`), and imported by the
//! mixed coordinator, so both paths count from `start` rather than
//! accumulating periods.
//! Cites: VAMS §5.10.3.3.
//!
//! Contents:
//! - `pub const z_inf: f64`
//! - `pub fn zNextTimer(start: f64, period: f64, t: f64) ?f64`
//! - `pub fn zTimerPending(start: f64, period: f64, t: f64, old_start: f64, old_period: f64, pending: f64) f64`
//! - `pub fn zTimerDue(start: f64, period: f64, t: f64, old_start: f64, old_period: f64, pending: f64) bool`

const ztm = @import("std");

// ---- device text ----

/// +inf, named once so an emitted timer site does no comptime work for it.
pub const z_inf: f64 = ztm.math.inf(f64);

/// Returns the first representable event time strictly after `t` on the grid
/// `start + k*period`, k >= 0. A non-positive or non-finite period has only
/// its `start` event. Null when no such time exists: a non-finite `start` or
/// `t`, a spent one-shot, or a grid whose next event overflows to infinity.
pub fn zNextTimer(start: f64, period: f64, t: f64) ?f64 {
    if (!ztm.math.isFinite(start) or !ztm.math.isFinite(t)) return null;
    const next: ?f64 = if (start > t) start else ztmGrid(start, period, t);
    if (next) |n| ztm.debug.assert(n > t);
    if (next) |n| ztm.debug.assert(!ztm.math.isNan(n));
    return next;
}

/// Returns the deadline after a control change, evaluated before the event
/// condition (§5.10.3.3). Unchanged controls keep `pending`, so a host that
/// steps just past the scheduled event still observes it. Changed controls
/// schedule afresh: now itself when now is on the new grid, never a past
/// one-shot (+inf).
pub fn zTimerPending(start: f64, period: f64, t: f64, old_start: f64, old_period: f64, pending: f64) f64 {
    if (start == old_start and period == old_period) return pending;
    const r: f64 = if (start >= t)
        start
    else if (!(period > 0))
        z_inf
    else
        zNextTimer(start, period, ztm.math.nextAfter(f64, t, -z_inf)) orelse z_inf;
    // A rescheduled deadline is never in the past (NaN compares false).
    ztm.debug.assert(!(r < t));
    return r;
}

/// Returns whether the timer fires at `t`. Enable gates delivery, never the
/// absolute schedule's progress, so this reads the deadline only.
pub fn zTimerDue(start: f64, period: f64, t: f64, old_start: f64, old_period: f64, pending: f64) bool {
    return t >= zTimerPending(start, period, t, old_start, old_period, pending);
}

// ---- private ----

/// The grid event after `t` once `start <= t`, both finite.
fn ztmGrid(start: f64, period: f64, t: f64) ?f64 {
    ztm.debug.assert(start <= t);
    ztm.debug.assert(ztm.math.isFinite(t));
    if (!(period > 0.0) or !ztm.math.isFinite(period)) return null;
    var n = @floor((t - start) / period) + 1.0;
    // Repair a division rounded to either side of a firing count.
    if (n > 1.0 and start + (n - 1.0) * period > t) n -= 1.0;
    if (start + n * period <= t) n += 1.0;
    const next = start + n * period;
    if (ztm.math.isFinite(next) and next > t) return next;
    // A tiny period can vanish in the addition or overflow the count; then
    // consecutive f64 times span an event, and the first time past `t` is
    // it. A finite count with an infinite event is finite-time exhaustion.
    if (next <= t or !ztm.math.isFinite(n)) {
        const future = ztm.math.nextAfter(f64, t, z_inf);
        if (ztm.math.isFinite(future)) return future;
    }
    return null;
}
