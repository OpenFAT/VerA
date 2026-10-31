const std = @import("std");
const Ast = @import("frontend").Ast;
const constfold = @import("frontend").constfold;
const Lower = @import("Lower.zig");
const lower_constfold = @import("constfold.zig");
const Oom = Lower.Oom;

/// Checks §5.10.3's monitored-event arguments (E0517), in both analog and
/// digital event controls. Numeric bounds apply only to folded operands;
/// cross()'s dependencies between omitted slots are structural.
pub fn checkEventArgBounds(self: *Lower, e: Ast.ExprId, name: []const u8) Oom!bool {
    const args = self.file.exprs.args(e);
    // §5.10.3: a monitored event names what it monitors. A required slot
    // left empty (`cross()`, `timer(, 1n)`, `absdelta(V(a))`) is refused
    // here, before lowering reads the argument that is not there; A.6.5's
    // permission to omit covers only the optional slots.
    var complete = true;
    for (requiredSlots(name), 0..) |slot, i| if (i >= args.len or args[i] == .none) {
        try self.err(self.file.exprs.mainTok(e), .E0517, "`{s}()` requires its {s} argument", .{ name, slot });
        complete = false;
    };
    // A.6.5 writes the enable, every form's last slot, `analog_expression`
    // and not `_or_null`: a comma before it promises one (`timer(0, 1n,
    // 1p, )` derives from nothing).
    const last: ?usize = if (std.mem.eql(u8, name, "absdelta")) 4 else enableSlot(name);
    if (last) |k| if (k < args.len and args[k] == .none) {
        try self.err(self.file.exprs.mainTok(e), .E0517, "`{s}()` has a comma before its enable and no enable", .{name});
        complete = false;
    };
    // ... and nothing derives past the enable.
    if (last) |k| if (args.len > k + 1) {
        try self.err(self.file.exprs.mainTok(e), .E0517, "`{s}()` takes at most {d} arguments, got {d} (A.6.5)", .{ name, k + 1, args.len });
        complete = false;
    };
    if (!complete) return false;
    // "enable ... shall evaluate to an integer" (§5.10.3.1-§5.10.3.3); only a
    // folded non-integral value is refused. absdelta's is checked below.
    if (enableSlot(name)) |k| if (k < args.len and args[k] != .none) {
        if (lower_constfold.foldExpr(self, args[k], false)) |c| {
            if (c != .str and c.asReal() != @round(c.asReal()))
                try self.err(self.file.exprs.mainTok(args[k]), .E0517, "`{s}()` enable shall evaluate to an integer, got {d}", .{ name, c.asReal() });
        }
    };
    if (std.mem.eql(u8, name, "absdelta")) {
        // §5.10.3.4: delta and both tolerances "shall be non-negative";
        // enable "shall evaluate to an integer". These are analog_expression
        // slots: a model card or a runtime value can make them valid, so a
        // declared parameter default is not sufficient to reject the source.
        const bounds = [_][]const u8{ "delta", "time_tol", "expr_tol" };
        for (bounds, 1..) |arg_name, i| {
            if (i >= args.len or args[i] == .none) continue;
            const c = lower_constfold.foldExpr(self, args[i], false) orelse continue;
            if (c == .str or c.asReal() >= 0) continue;
            try self.err(self.file.exprs.mainTok(args[i]), .E0517, "`absdelta()` {s} shall be non-negative, got {d}", .{ arg_name, c.asReal() });
        }
        if (args.len > 4 and args[4] != .none) {
            if (lower_constfold.foldExpr(self, args[4], false)) |c| {
                if (c != .str and c.asReal() != @round(c.asReal()))
                    try self.err(self.file.exprs.mainTok(args[4]), .E0517, "`absdelta()` enable shall evaluate to an integer, got {d}", .{c.asReal()});
            }
        }
        return true;
    }
    const is_cross = std.mem.eql(u8, name, "cross");
    if (std.mem.eql(u8, name, "timer")) {
        if (args.len < 3 or args[2] == .none) return true;
        const c = lower_constfold.constEval(self, args[2]) orelse return true;
        if (c == .str or c.asReal() >= 0) return true;
        try self.err(self.file.exprs.mainTok(args[2]), .E0517, "`timer()` time_tol shall be non-negative, got {d}", .{c.asReal()});
        return true;
    }
    if (!is_cross and !std.mem.eql(u8, name, "above")) return true;
    // §5.10.3.2 above() has no direction: its tolerances start one slot earlier.
    const dir: ?usize = if (is_cross) 1 else null;
    const tol_first: usize = if (is_cross) 2 else 1;

    if (dir) |d| if (d < args.len and args[d] != .none) {
        if (lower_constfold.constEval(self, args[d])) |c| {
            const v = c.asReal();
            // "shall evaluate to integers". Only a folded non-integral value is
            // refused: 0.5 selects no direction, while a real 1.0 evaluates to one.
            if (c != .str and v != @round(v))
                try self.err(self.file.exprs.mainTok(args[d]), .E0517, "`cross()` direction shall evaluate to an integer, got {d}", .{v});
        }
    };

    var tol_given = false;
    for (tol_first..@max(tol_first, @min(tol_first + 2, args.len))) |i| {
        if (args[i] == .none) continue;
        tol_given = true;
        const c = lower_constfold.constEval(self, args[i]) orelse continue;
        if (c == .str) continue;
        const v = c.asReal();
        if (v >= 0) continue;
        try self.err(self.file.exprs.mainTok(args[i]), .E0517, "`{s}()` {s} shall be non-negative, got {d}", .{
            name,
            if (i == tol_first) "time_tol" else "expr_tol",
            v,
        });
    }

    // "If either or both tolerances are defined, then the direction shall also
    // be defined." Elision as such is legal — §5.10.3.1's own `sh` example
    // writes `cross(V(smpl) - thresh, dir, , , en === 1'b1)`, so the error is
    // the missing direction, not the comma.
    if (tol_given) if (dir) |d| {
        if (d >= args.len or args[d] == .none) {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0517);
            b.msg("a tolerance is given but the direction slot is empty", .{});
            b.help("write the direction explicitly; `0` is \"either edge\"", .{});
            try b.emit();
        }
    };
    // §5.10.3.1: "If expr_tol is specified, time_tol shall also be
    // specified". Omission of BOTH tolerances remains legal, including the
    // `sh` example above with a fifth-slot enable.
    if (is_cross and args.len > 3 and args[3] != .none and args[2] == .none) {
        var b = self.errWith(self.file.exprs.mainTok(e), .E0517);
        b.msg("`cross()` expr_tol is given but the time_tol slot is empty", .{});
        b.help("specify time_tol before expr_tol, or omit both tolerances", .{});
        try b.emit();
    }
    return true;
}

/// The argument slots a §5.10.3 monitored event requires, in order.
fn requiredSlots(name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, name, "cross") or std.mem.eql(u8, name, "above")) return &.{"expr"};
    if (std.mem.eql(u8, name, "timer")) return &.{"start_time"};
    if (std.mem.eql(u8, name, "absdelta")) return &.{ "expr", "delta" };
    return &.{};
}

/// The enable slot of cross (§5.10.3.1), above (§5.10.3.2) and timer
/// (§5.10.3.3); absdelta's is checked with its bounds.
fn enableSlot(name: []const u8) ?usize {
    if (std.mem.eql(u8, name, "cross")) return 4;
    if (std.mem.eql(u8, name, "above") or std.mem.eql(u8, name, "timer")) return 3;
    return null;
}

test requiredSlots {
    // §5.10.3: the monitored quantity, and absdelta's delta besides.
    try std.testing.expectEqual(@as(usize, 1), requiredSlots("cross").len);
    try std.testing.expectEqualStrings("expr", requiredSlots("above")[0]);
    try std.testing.expectEqualStrings("start_time", requiredSlots("timer")[0]);
    try std.testing.expectEqual(@as(usize, 2), requiredSlots("absdelta").len);
    try std.testing.expectEqualStrings("delta", requiredSlots("absdelta")[1]);
    try std.testing.expectEqual(@as(usize, 0), requiredSlots("initial_step").len);
}

test enableSlot {
    // cross(expr, dir, time_tol, expr_tol, enable); above and timer one earlier.
    try std.testing.expectEqual(@as(?usize, 4), enableSlot("cross"));
    try std.testing.expectEqual(@as(?usize, 3), enableSlot("above"));
    try std.testing.expectEqual(@as(?usize, 3), enableSlot("timer"));
    try std.testing.expectEqual(@as(?usize, null), enableSlot("absdelta"));
}

test "§5.10.3 monitored events: argument rules, each beside a legal call" {
    try Lower.expectBodies(&.{
        .{ .src = "analog begin @(cross(V(p) - 0.5, 1, 1n, 1u)) x = 1.0; I(p) <+ x; end", .code = null },
        // §5.10.3.1 the direction "shall evaluate to integers".
        .{ .src = "analog begin @(cross(V(p) - 0.5, 0.5)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // "If either or both tolerances are defined, then the direction shall
        // also be defined."
        .{ .src = "analog begin @(cross(V(p) - 0.5, , 1n)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // "If expr_tol is specified, time_tol shall also be specified."
        .{ .src = "analog begin @(cross(V(p) - 0.5, 1, , 1u)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // A.6.5: the enable is analog_expression, not `_or_null`.
        .{ .src = "analog begin @(cross(V(p) - 0.5, 1, 1n, 1u, )) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // §5.10.3.3 time_tol is non-negative.
        .{ .src = "analog begin @(timer(0, 1n, -1p)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        .{ .src = "analog begin @(timer(0, 1n)) x = 1.0; I(p) <+ x; end", .code = null },
        // §5.10.3.2 the enable "shall evaluate to an integer".
        .{ .src = "analog begin @(above(V(p) - 0.5, 1n, 1u, 0.5)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        .{ .src = "analog begin @(above(V(p) - 0.5)) x = 1.0; I(p) <+ x; end", .code = null },
        // A.6.5: nothing derives past the enable.
        .{ .src = "analog begin @(cross(V(p) - 0.5, 1, 1n, 1u, 1, 1)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        .{ .src = "analog begin @(above(V(p) - 0.5, 1n, 1u, 1, 1)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        .{ .src = "analog begin @(timer(0, 1n, 1p, 1, 1)) x = 1.0; I(p) <+ x; end", .code = .E0517 },
        // §5.10.3.4 absdelta is "only allowed in an initial or always block".
        .{ .src = "analog begin @(absdelta(V(p), 0.1)) x = 1.0; I(p) <+ x; end", .code = .E0513 },
        // §5.10 "Nested event control statements are not allowed."
        .{ .src = "analog begin @(initial_step) @(final_step) x = 1.0; I(p) <+ x; end", .code = .E0703 },
    });
}
