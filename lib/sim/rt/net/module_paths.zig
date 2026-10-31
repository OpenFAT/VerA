//! A change of a module path's source in, the path delay its destination takes out.
//! Cites: IEEE 1364-2005 §14.3.3 (module path delays), §14.6.
//!
//! Contents:
//! - `pub fn seedPaths(t: *Nets, gpa: std.mem.Allocator, v: []const u64, x: []const u64) Error!void`
//! - `pub fn pathSeen(s: *State, slot: u32) void`
//! - `pub fn pathDelay(s: *State, n: Net, cv: []const u64, cx: []const u64, res: []const u64) Error!?u64`

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const dnet = @import("../../digital/net.zig");
const Handle = @import("../../scheduler.zig").Handle;
const design = @import("../design.zig");
const State = @import("../State.zig");
const Error = design.Error;
const logic = @import("../logic/root.zig");
const Bit = logic.Bit;
const Signal = dnet.Signal;
const testing = std.testing;
const driving = @import("driving.zig");
const layout = @import("layout.zig");
const Net = layout.Net;
const Nets = layout.Nets;
const Path = layout.Path;
const bitAt = driving.bitAt;
const bitOf = driving.bitOf;

/// §14.3.3 the module path sources of `t.nets`, each with its value at time
/// 0 (`v`/`x`, the design's initial plane words), the "before" of its first
/// transition (`pathSeen`). Allocated from `gpa` for the whole run.
pub fn seedPaths(t: *Nets, gpa: std.mem.Allocator, v: []const u64, x: []const u64) Error!void {
    std.debug.assert(t.src_ix.count() == 0); // once, from `State.initIn`
    var last: std.ArrayList([2]u64) = .empty;
    var offs: std.ArrayList(u32) = .empty;
    for (t.nets) |net| for (net.paths) |p| {
        const g = try t.src_ix.getOrPut(gpa, p.src);
        if (g.found_existing) continue;
        g.value_ptr.* = @intCast(last.items.len);
        try last.append(gpa, .{ v[p.src_off], x[p.src_off] });
        try offs.append(gpa, p.src_off);
    };
    t.src_last = last.items;
    t.src_off = offs.items;
    t.src_seen = try gpa.alloc(?dnet.PathEdge, last.items.len);
    @memset(t.src_seen, null);
}

/// §14.3.3 slot `slot` changed: when a module path source transitions, its
/// time and its low word before and after (`waiters.store`'s `.path`).
pub fn pathSeen(s: *State, slot: u32) void {
    const t = &s.nets;
    const i = t.src_ix.get(slot) orelse return;
    const now: [2]u64 = .{ s.v[t.src_off[i]], s.x[t.src_off[i]] };
    t.src_seen[i] = .{ .time = s.sched.now, .before = t.src_last[i], .after = now };
    t.src_last[i] = now;
}

/// IEEE 1364-2005 §14.3.3 `resolution.pathDelay`: of the paths into net `n`
/// whose source "has transitioned most recently in time" and whose
/// condition is true, on its edge (§14.2.3) and an `ifnone` one only while
/// no state-dependent path from its source is (§14.2.4.4), the smallest
/// delay for each bit's transition from `cv`/`cx` to `res`, counted from the
/// source's transition (§14.4). Null when no path is active.
pub fn pathDelay(s: *State, n: Net, cv: []const u64, cx: []const u64, res: []const u64) Error!?u64 {
    if (n.paths.len == 0) return null;
    const t = &s.nets;
    var latest: ?u64 = null;
    for (n.paths) |p| if (t.src_seen[t.src_ix.get(p.src).?]) |c| {
        latest = @max(latest orelse c.time, c.time);
    };
    const at = latest orelse return null;
    const nw = cv.len;
    var best: ?u64 = null;
    for (n.paths) |p| {
        if (!try pathActive(s, n.paths, p, at)) continue;
        for (0..n.width) |i| {
            const a = bitOf(cv, cx, @intCast(i));
            const b = bitAt(res[0 .. 2 * nw], @intCast(i));
            if (a == b) continue;
            const d = p.table[@backingInt(a)][@backingInt(b)];
            best = @min(best orelse d, d);
        }
    }
    const d = best orelse return null;
    return (at + d) -| s.sched.now;
}

// ---- private ----

fn pathActive(s: *State, paths: []const Path, p: Path, at: u64) Error!bool {
    if (!pathFired(s, p, at)) return false;
    if (p.ifnone) {
        for (paths) |q| if (q.src == p.src and !q.ifnone and (q.cond != null or q.edge != .none) and pathFired(s, q, at) and (q.cond == null or try q.cond.?(s))) return false;
        return true;
    }
    return if (p.cond) |c| try c(s) else true;
}

/// `resolution.pathFired`.
fn pathFired(s: *const State, p: Path, at: u64) bool {
    const t = &s.nets;
    const c = t.src_seen[t.src_ix.get(p.src).?] orelse return false;
    if (c.time != at) return false;
    if (p.edge == .none or p.src_bit >= 64) return true;
    const before = bitOf(c.before[0..1], c.before[1..2], p.src_bit);
    const after = bitOf(c.after[0..1], c.after[1..2], p.src_bit);
    if (before == after) return false;
    return if (p.edge == .posedge) before == .zero or after == .one else before == .one or after == .zero;
}
