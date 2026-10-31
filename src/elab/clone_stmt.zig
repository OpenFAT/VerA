//! The statement clone: one statement subtree of a child → new rows in the
//! flat namespace, flow contributions scaled by $mfactor (§6.3.6 rule 1),
//! block labels and `disable` targets joined onto the unit's path (§6.7).
//! Cites: LRM §5.3.2, §6.3.6, §6.7, §7.2.2, A.6.5; IEEE 1364-2005 §9.7.7,
//! §9.8.2.
//!
//! Contents:
//! - `pub fn cloneStmt(self: *Flatten, id: Ast.StmtId) design.Error!Ast.StmtId`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const design = @import("design.zig");
const Flatten = @import("Flatten.zig");
const elaborate = @import("elaborate.zig");
const clone_decl = @import("clone_decl.zig");
const clone_expr = @import("clone_expr.zig");
const flat_name = @import("flat_name.zig");
const access = @import("access.zig");
const sep = design.sep;
const fixture = @import("fixture.zig");

/// Copies one statement and everything under it into the pool, renamed into
/// the unit's flat namespace, scaling flow contributions by $mfactor (§6.3.6).
pub fn cloneStmt(self: *Flatten, id: Ast.StmtId) design.Error!Ast.StmtId {
    if (id == .none) return .none;
    const file = self.ctx.file;
    const tok = file.stmtTok(id);
    const s = file.stmt(id);
    const out: Ast.Stmt = switch (s) {
        .empty => .empty,
        .block => |b| blk: {
            // §5.3.2 a named block's declarations are locals, hidden for the
            // body like a function's formals.
            var hidden: std.ArrayList(clone_decl.HiddenName) = try .initCapacity(self.ctx.arena, b.params.len + b.vars.len + b.events.len);
            for (b.params) |p| clone_decl.hide(self, &hidden, p.name);
            for (b.vars) |v| clone_decl.hide(self, &hidden, v.name);
            for (b.events) |e| clone_decl.hide(self, &hidden, e.name);
            const params = try clone_decl.cloneLocalParams(self, b.params);
            const vars = try clone_decl.cloneLocalVars(self, b.vars);
            // IEEE 1364-2005 A.2.8 a named block's events are locals too:
            // hidden above, so `cloneEvent` keeps each name and clones dims.
            const events = try self.ctx.arena.alloc(Ast.EventDecl, b.events.len);
            for (b.events, events) |e, *o| o.* = try clone_decl.cloneEvent(self, e);
            const body = try self.ctx.arena.alloc(Ast.StmtId, b.body.len);
            for (b.body, body) |src, *o| o.* = try cloneStmt(self, src);
            clone_decl.unhide(self, hidden.items);
            break :blk .{
                .block = .{
                    // §6.7 a block label is a scope name. Renamed with the rest,
                    // so `disable` inside the child still finds it and two
                    // instances do not declare one name twice.
                    .name = if (b.name == .none) .none else try joinLocal(self, b.name),
                    // IEEE 1364-2005 §9.8.2 `fork ... join` stays parallel.
                    .parallel = b.parallel,
                    .params = params,
                    .vars = vars,
                    .events = events,
                    .body = body,
                    // §6.6.3 an external name, relative to the unit: not renamed.
                    .gen_name = b.gen_name,
                },
            };
        },
        // Copied over the source row, so the discrete-only fields (A.6.2's
        // `<=` and intra-assignment timing) survive the clone.
        .assign => |v| blk: {
            var o = v;
            o.target = try clone_expr.cloneExpr(self, v.target);
            o.value = try clone_expr.cloneExpr(self, v.value);
            o.timing = try clone_expr.cloneExpr(self, v.timing);
            // IEEE 1364-2005 §9.7.7 `repeat (count)` reads the unit's names.
            o.timing_repeat = try clone_expr.cloneExpr(self, v.timing_repeat);
            break :blk .{ .assign = o };
        },
        .contribute => |v| blk: {
            const lhs = try cloneTarget(self, v.lhs);
            const rhs = try clone_expr.cloneExpr(self, v.rhs);
            // §6.3.6 rule 1: "all contributions to a branch flow quantity in
            // the analog block shall be multiplied by $mfactor", and the
            // clause adds that "Verilog-AMS does not provide a method to
            // disable" it. A potential contribution is left alone: $mfactor
            // copies in parallel share a potential.
            const x = &self.ctx.file.exprs;
            const scaled = if (x.tag(lhs) == .branch_access or x.tag(lhs) == .port_access)
                try access.mfactorScale(self, rhs, x.strOf(lhs), x.lhs(lhs), .mul, x.mainTok(lhs))
            else
                null;
            break :blk .{ .contribute = .{ .lhs = lhs, .rhs = scaled orelse rhs } };
        },
        .indirect => |v| .{ .indirect = .{
            .lhs = try cloneTarget(self, v.lhs),
            .probe = try clone_expr.cloneExpr(self, v.probe),
            .eqn = try clone_expr.cloneExpr(self, v.eqn),
        } },
        .if_stmt => |v| .{ .if_stmt = .{
            .cond = try clone_expr.cloneExpr(self, v.cond),
            .then_s = try cloneStmt(self, v.then_s),
            .else_s = try cloneStmt(self, v.else_s),
            .is_generate = v.is_generate,
        } },
        .case_stmt => |v| blk: {
            const arms = try self.ctx.arena.alloc(Ast.CaseArm, v.arms.len);
            for (v.arms, arms) |src, *o| {
                const labels = try self.ctx.arena.alloc(Ast.ExprId, src.labels.len);
                for (src.labels, labels) |l, *ol| ol.* = try clone_expr.cloneExpr(self, l);
                o.* = .{ .labels = labels, .body = try cloneStmt(self, src.body) };
            }
            break :blk .{ .case_stmt = .{
                .kind = v.kind,
                .scrutinee = try clone_expr.cloneExpr(self, v.scrutinee),
                .arms = arms,
                .is_generate = v.is_generate,
            } };
        },
        .for_stmt => |v| .{ .for_stmt = .{
            .init = try cloneStmt(self, v.init),
            .cond = try clone_expr.cloneExpr(self, v.cond),
            .step = try cloneStmt(self, v.step),
            .body = try cloneStmt(self, v.body),
        } },
        .while_stmt => |v| .{ .while_stmt = .{
            .cond = try clone_expr.cloneExpr(self, v.cond),
            .body = try cloneStmt(self, v.body),
        } },
        .repeat_stmt => |v| .{ .repeat_stmt = .{
            .count = try clone_expr.cloneExpr(self, v.count),
            .body = try cloneStmt(self, v.body),
        } },
        .event_control => |v| .{
            .event_control = .{
                .event = try clone_expr.cloneExpr(self, v.event),
                .body = try cloneStmt(self, v.body),
                .kind = v.kind, // `#`/`wait` are not `@`
            },
        },
        .event_trigger => |v| .{ .event_trigger = .{ .target = try clone_expr.cloneExpr(self, v.target) } },
        // A.6.5 a block label, spelled as the label itself was joined.
        .disable => |v| .{ .disable = .{ .name = try joinLocal(self, v.name) } },
        .sys_task => |v| blk: {
            // `name` is a system task (`$strobe`, ...), never a name of this unit.
            const args = try self.ctx.arena.alloc(Ast.ExprId, v.args.len);
            for (v.args, args) |src, *o| o.* = try clone_expr.cloneExpr(self, src);
            break :blk .{ .sys_task = .{ .name = v.name, .args = args } };
        },
        .jump => |v| .{ .jump = .{ .kind = v.kind, .value = try clone_expr.cloneExpr(self, v.value) } },
    };
    return file.addStmt(self.ctx.arena, out, tok);
}

// ---- private ----

/// Clones the branch a `<+` or an indirect assignment drives, as opposed to
/// one it reads: §6.3.6's flow-probe division must not fire on it.
fn cloneTarget(self: *Flatten, e: Ast.ExprId) design.Error!Ast.ExprId {
    // A target holds no statement, so no target clone nests inside another,
    // and the reset below cannot end an outer one early.
    assert(!self.contrib_target);
    self.contrib_target = true;
    defer self.contrib_target = false;
    return clone_expr.cloneExpr(self, e);
}

/// A name the unit declares but that `bind` never saw, because it is not a
/// module-level declaration: a §5.3.2 block label. Joined against the unit's
/// path on demand, which the rename map already carries for every other
/// name of the unit.
fn joinLocal(self: *Flatten, name: Ast.StrId) design.Error!Ast.StrId {
    if (self.unit.rename.get(name)) |flat_id| return flat_id;
    // A dotted `disable` target (A.9.3) is a path already, not a label.
    if (std.mem.findScalar(u8, self.ctx.file.str(name), sep) != null) return name;
    // The unit's own path, never one read off a rename entry: a port's entry
    // is the PARENT's net, so it named the parent's scope (or none at the
    // top), and two instances' labels collided.
    return flat_name.join(self, self.unit.path, name);
}

test "§6.7 a child's block label joins its own instance path, whatever else the child declares" {
    // `kid` declares nothing but a port, bound to the top's `p`. Two
    // instances are two scopes, so the two labels must differ: otherwise
    // §5.3.2's static block locals of both would share one location.
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u1(p); kid u2(p); endmodule
        \\module kid(a); inout a; electrical a; analog begin : blk I(a) <+ V(a); end endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 2), d.top.analog.len);
    try std.testing.expectEqualStrings("u1.blk", f.file.str(f.file.stmt(d.top.analog[0].body).block.name));
    try std.testing.expectEqualStrings("u2.blk", f.file.str(f.file.stmt(d.top.analog[1].body).block.name));
}

test "§5.11 a disable inside a child names that child's flattened block" {
    // A.6.5 `disable` names an enclosing block, so it must be spelled as the
    // block's label is after the join, or lowering finds no such block.
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u(p); endmodule
        \\module kid(a); inout a; electrical a; parameter real g = 1.0;
        \\  analog begin : blk @(initial_step) disable blk; I(a) <+ g * V(a); end
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    const blk = f.file.stmt(d.top.analog[0].body).block;
    try std.testing.expectEqualStrings("u.blk", f.file.str(blk.name));
    const ev = f.file.stmt(blk.body[0]).event_control;
    try std.testing.expectEqual(blk.name, f.file.stmt(ev.body).disable.name);
}

test "§7.2.2 a child's discrete statements are copied whole: fork/join stays parallel, a repeat count is renamed" {
    // IEEE 1364-2005 §9.8.2 `fork ... join` starts every statement at once,
    // and §9.7.7's `repeat (n) @(...)` counts with the CHILD's `n`.
    var f: fixture.Fixture = .{ .arena = .init(std.testing.allocator) };
    defer f.deinit();
    try fixture.parse(&f,
        \\module top(p); inout p; electrical p; kid u(p); endmodule
        \\module kid(a); inout a; electrical a; parameter integer n = 2; reg q, c;
        \\  initial fork q = 0; join
        \\  initial q = repeat (n) @(posedge c) 1;
        \\endmodule
    );
    const d = try elaborate.elaborate(f.ctx());
    try std.testing.expectEqual(@as(usize, 2), d.top.discrete.len);
    try std.testing.expect(f.file.stmt(d.top.discrete[0].body).block.parallel);
    const count = f.file.stmt(d.top.discrete[1].body).assign.timing_repeat;
    try std.testing.expectEqualStrings("u.n", f.file.str(f.file.exprs.strOf(count)));
}
