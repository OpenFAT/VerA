//! A stamp as it is written -> its exact linear coefficients in `Gen.jac.lin`
//! (`k · x[col]` per row and column), the evidence `plan/jac.zig` turns into
//! `jac_const`: a row assigned a term with no unknown in it, a branch relation,
//! a port probe's mirror, or a row written under a runtime condition clears or
//! restates what the row held.
//! Cites: §5.4.2, §5.4.3, §5.6, §5.6.5.
//!
//! Contents:
//! - `pub fn linTerm(self: *Gen, row: u32, col: u32, k: f64) Error!void`
//! - `pub fn linClear(self: *Gen, row: u32) void`
//! - `pub fn linBranch(self: *Gen, row: u32, hi: u32, lo: u32) Error!void`
//! - `pub fn linPortProbe(self: *Gen, u: u32, port: u32, with_x: bool) Error!void`
//! - `pub fn linDynamic(self: *Gen, row: u32) void`

const std = @import("std");
const codegen = @import("../codegen.zig");
const Gen = codegen.Gen;
const gen_mask = @import("mask.zig");
const Lower = @import("ir").Lowered;
const assert = std.debug.assert;
const Error = codegen.Error;

/// Records that row `row` of the half being emitted gains `k · x[col]`. The
/// `lin*` writers mirror the `res[...]` text beside them as `patRow` does:
/// only a ±1 on an unknown is recorded; every other term is a core value
/// whose lanes are already marked.
pub fn linTerm(self: *Gen, row: u32, col: u32, k: f64) Error!void {
    assert(!std.math.isNan(k)); // NaN would poison `jac_const`.
    if (row == Lower.ground or col == Lower.ground) return;
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    assert(row < l.len);
    assert(col < self.names.n_u);
    for (l[row].items) |*t| if (t.col == col) {
        t.k += k;
        return;
    };
    try l[row].append(self.arena, .{ .col = col, .k = 0 + k });
}

/// Records that row `row` is assigned a term with no recorded unknown in it.
pub fn linClear(self: *Gen, row: u32) void {
    assert(row != Lower.ground);
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    l[row].clearRetainingCapacity();
    assert(l[row].items.len == 0);
    // Its guarded constants go with the assignment too, the rest in order.
    if (self.jac.react) return;
    var keep: usize = 0;
    for (self.jac.guarded.items) |e| if (e.row != row) {
        self.jac.guarded.items[keep] = e;
        keep += 1;
    };
    self.jac.guarded.shrinkRetainingCapacity(keep);
}

/// Records that row `row` is assigned `V(hi) − V(lo) − <core value>`: §5.6's branch
/// relation, and §5.4.2.1's zero-potential flow probe.
pub fn linBranch(self: *Gen, row: u32, hi: u32, lo: u32) Error!void {
    assert(row != Lower.ground);
    assert(row < self.names.n_u);
    linClear(self, row);
    try linTerm(self, row, hi, 1);
    try linTerm(self, row, lo, -1);
}

/// Records §5.4.3 `res[u] = x[u] − res[port]` (eval) or `−res[port]` (q):
/// the row is the finished port row negated, so its constants are too.
pub fn linPortProbe(self: *Gen, u: u32, port: u32, with_x: bool) Error!void {
    assert(u < self.names.n_u);
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    assert(u != port);
    l[u].clearRetainingCapacity();
    for (l[port].items) |t| try l[u].append(self.arena, .{ .col = t.col, .k = -t.k });
    if (with_x) try linTerm(self, u, u, 1);
    // The port row's guarded constants are copied too, under the same guard
    // (`emitSwitchRow`): they are eval-only, and each is appended once per row.
    if (self.jac.react) return;
    const k0 = self.jac.guarded.items.len;
    for (0..k0) |k| {
        const e = self.jac.guarded.items[k];
        if (e.row != port) continue;
        try self.jac.guarded.append(self.arena, .{ .row = u, .col = e.col, .g = 0 - e.g, .c = 0 - e.c, .when = e.when });
    }
}

/// Records that row `row` is about to be written under a runtime condition:
/// its constants may not survive, so each of their columns keeps a lane.
pub fn linDynamic(self: *Gen, row: u32) void {
    assert(row != Lower.ground);
    const l = self.jac.lin[@intFromBool(self.jac.react)];
    if (l.len == 0) return;
    for (l[row].items) |t| {
        if (t.k != 0) gen_mask.set(self.jac.deriv_reads, t.col);
    }
}
