//! A statement -> its `.code` row and its children's (§11.6.21-§11.6.24),
//! the §11.6.20 contribution statement included.
//! Cites: VAMS-2023 §5.6.7, §11.6.20-§11.6.24; IEEE 1364-2005 §26.6.3,
//! §26.6.31, §26.6.34, §26.6.38.
//!
//! Contents:
//! - `pub fn stmt(b: *Builder, id: Ast.StmtId) Error!u32`
//! - `pub fn stmtObj(b: *Builder, id: Ast.StmtId) Error!u32`
//! - `pub fn contrib(b: *Builder, lhs: Ast.ExprId, rhs: Ast.ExprId) Error!u32`

const std = @import("std");
const Ast = @import("frontend").Ast;
const code_tables = @import("code_tables.zig");
const schema = @import("schema.zig");
const user = @import("vpi_user.zig");
const Builder = @import("Builder.zig");
const session = @import("session.zig");
const Edge = schema.Edge;
const Error = session.Error;
const List = schema.List;
const Prop = schema.Prop;

/// Builds the object for statement `id` and its children; returns its
/// index, or `none` for `.none` or a statement with no §11.6.21 object.
pub fn stmt(b: *Builder, id: Ast.StmtId) Error!u32 {
    const at = try b.stmtObj(id);
    if (id != .none) try b.attributes(at, .{ .kind = .statement, .tok = b.file.stmtTok(id) }, false);
    if (at != schema.no_obj) b.objects.hot.items[at].stmt = id;
    // IEEE 1364-2005 §26.6.3 stmt -> vpiScope: the innermost task,
    // function or named block around it. At module level the edge is the
    // owner one every object shares. Appended, so a disable's own
    // vpiScope (AMS §11.6.24, the scope it disables) is found first.
    if (at != schema.no_obj and b.inner != schema.no_obj) {
        const o = &b.objects.hot.items[at];
        o.edges = try std.mem.concat(b.arena, Edge, &.{ o.edges, &.{.{ .tag = user.vpiScope, .to = b.inner }} });
    }
    return at;
}

pub fn stmtObj(b: *Builder, id: Ast.StmtId) Error!u32 {
    if (id == .none) return schema.no_obj;
    const f = b.file;
    return switch (f.stmt(id)) {
        .empty => b.code(user.vpiNullStmt, &.{}, &.{}, &.{}),
        .block => |blk| blk: {
            // The block is made — and named — BEFORE its statements, so
            // a `disable` inside it finds it (§11.6.24 disable -> scope).
            const named = blk.name != .none;
            const vt: c_int = if (blk.parallel) (if (named) user.vpiNamedFork else user.vpiFork) else if (named) user.vpiNamedBegin else user.vpiBegin;
            const at = try b.code(vt, &.{}, &.{}, &.{});
            var inner: std.ArrayList(u32) = .empty;
            defer inner.deinit(b.gpa);
            var saved: ?Builder.Saved = null;
            if (named) {
                const local = try b.arena.dupe(u8, f.str(blk.name));
                try b.setName(at, local);
                saved = try b.enter(at, local, &inner);
                if (b.run) |r| b.engine = r.hier.block_scopes.get(.{ .scope = b.engine, .stmt = id }) orelse b.engine;
            }
            const events = try b.eventDecls(blk.events);
            const items = try b.arena.alloc(u32, blk.body.len);
            for (blk.body, items) |s, *item| item.* = try b.stmt(s);
            if (saved) |sv| b.leave(sv);
            const stmts: List = .{ .tag = user.vpiStmt, .items = try b.many(items) };
            b.objects.hot.items[at].lists = if (named)
                try b.arena.dupe(List, &.{ stmts, .{ .tag = user.vpiInternalScope, .items = try b.arena.dupe(u32, inner.items) }, .{ .tag = user.vpiNamedEvent, .items = events.scalars }, .{ .tag = user.vpiNamedEventArray, .items = events.arrays } })
            else
                try b.arena.dupe(List, &.{stmts});
            break :blk at;
        },
        .assign => |a| switch (a.continuous) {
            .none => blk: {
                const lhs = try b.expr(a.target);
                const rhs = try b.expr(a.value);
                // §11.6.22 NOTE: "For delay control and event control
                // associated with assignment, the statement shall always
                // be NULL."
                var dc = schema.no_obj;
                var ec = schema.no_obj;
                var rc = schema.no_obj;
                // An intra-assignment `@*` is the statement form's
                // event control: its vpiCondition is NULL.
                if (a.timing != .none or a.timing_implicit) {
                    const e = try b.expr(a.timing);
                    if (a.timing_is_delay) {
                        dc = try b.code(user.vpiDelayControl, &.{ .{ .tag = user.vpiDelay, .to = e }, .{ .tag = user.vpiStmt, .to = schema.no_obj } }, &.{}, &.{});
                    } else {
                        ec = try b.code(user.vpiEventControl, &.{ .{ .tag = user.vpiCondition, .to = e }, .{ .tag = user.vpiStmt, .to = schema.no_obj } }, &.{}, &.{});
                    }
                    // §26.6.31 a repeat control: its count and its event
                    // control, and no statement.
                    if (a.timing_repeat != .none) {
                        rc = try b.code(user.vpiRepeatControl, &.{ .{ .tag = user.vpiExpr, .to = try b.expr(a.timing_repeat) }, .{ .tag = user.vpiEventControl, .to = ec } }, &.{}, &.{});
                        ec = schema.no_obj;
                    }
                }
                break :blk b.code(user.vpiAssignment, &.{
                    .{ .tag = user.vpiLhs, .to = lhs },
                    .{ .tag = user.vpiRhs, .to = rhs },
                    .{ .tag = user.vpiDelayControl, .to = dc },
                    .{ .tag = user.vpiEventControl, .to = ec },
                    .{ .tag = user.vpiRepeatControl, .to = rc },
                }, &.{}, &.{.{ .prop = user.vpiBlocking, .value = @intFromBool(!a.nonblocking) }});
            },
            // §11.6.24: force and assign stmt draw vpiLhs and vpiRhs;
            // deassign and release draw vpiLhs alone.
            .assign, .force => blk: {
                const at = try b.code(if (a.continuous == .force) user.vpiForce else user.vpiAssignStmt, &.{
                    .{ .tag = user.vpiLhs, .to = try b.expr(a.target) },
                    .{ .tag = user.vpiRhs, .to = try b.expr(a.value) },
                }, &.{}, &.{});
                (try b.objects.coldFor(at)).override_expr = a.value;
                break :blk at;
            },
            .deassign, .release => b.code(if (a.continuous == .release) user.vpiRelease else user.vpiDeassign, &.{
                .{ .tag = user.vpiLhs, .to = try b.expr(a.target) },
            }, &.{}, &.{}),
        },
        .if_stmt => |s| blk: {
            const cond = try b.expr(s.cond);
            const then = try b.stmt(s.then_s);
            if (s.else_s == .none) break :blk b.code(user.vpiIf, &.{
                .{ .tag = user.vpiCondition, .to = cond },
                .{ .tag = user.vpiStmt, .to = then },
            }, &.{}, &.{});
            break :blk b.code(user.vpiIfElse, &.{
                .{ .tag = user.vpiCondition, .to = cond },
                .{ .tag = user.vpiStmt, .to = then },
                .{ .tag = user.vpiElseStmt, .to = try b.stmt(s.else_s) },
            }, &.{}, &.{});
        },
        .case_stmt => |s| blk: {
            const cond = try b.expr(s.scrutinee);
            const items = try b.arena.alloc(u32, s.arms.len);
            for (s.arms, items) |arm, *item| {
                // §11.6.23 NOTE 2: the default item has no expression, so
                // its vpiExpr set is empty and vpi_iterate is NULL.
                const labels = try b.arena.alloc(u32, arm.labels.len);
                for (arm.labels, labels) |l, *label| label.* = try b.expr(l);
                item.* = try b.code(user.vpiCaseItem, &.{.{ .tag = user.vpiStmt, .to = try b.stmt(arm.body) }}, &.{.{ .tag = user.vpiExpr, .items = try b.many(labels) }}, &.{});
            }
            break :blk b.code(user.vpiCase, &.{.{ .tag = user.vpiCondition, .to = cond }}, &.{.{ .tag = user.vpiCaseItem, .items = items }}, &.{.{ .prop = user.vpiCaseType, .value = switch (s.kind) {
                .normal => user.vpiCaseExact,
                .casex => user.vpiCaseX,
                .casez => user.vpiCaseZ,
            } }});
        },
        .for_stmt => |s| b.code(user.vpiFor, &.{
            .{ .tag = user.vpiForInitStmt, .to = try b.stmt(s.init) },
            .{ .tag = user.vpiCondition, .to = try b.expr(s.cond) },
            .{ .tag = user.vpiForIncStmt, .to = try b.stmt(s.step) },
            .{ .tag = user.vpiStmt, .to = try b.stmt(s.body) },
        }, &.{}, &.{}),
        // The parser records `forever s` as `while (1) s` with the `1`
        // on the `forever` keyword itself; IEEE 1364-2005 §26.6.34 draws
        // forever -> stmt alone.
        .while_stmt => |s| if (f.exprs.tag(s.cond) == .int_literal and f.exprs.mainTok(s.cond) == f.stmtTok(id))
            b.code(user.vpiForever, &.{.{ .tag = user.vpiStmt, .to = try b.stmt(s.body) }}, &.{}, &.{})
        else
            b.code(user.vpiWhile, &.{
                .{ .tag = user.vpiCondition, .to = try b.expr(s.cond) },
                .{ .tag = user.vpiStmt, .to = try b.stmt(s.body) },
            }, &.{}, &.{}),
        .repeat_stmt => |s| b.code(user.vpiRepeat, &.{
            .{ .tag = user.vpiCondition, .to = try b.expr(s.count) },
            .{ .tag = user.vpiStmt, .to = try b.stmt(s.body) },
        }, &.{}, &.{}),
        .event_control => |s| switch (s.kind) {
            .delay => blk: {
                const at = try b.code(user.vpiDelayControl, &.{
                    .{ .tag = user.vpiDelay, .to = try b.expr(s.event) },
                    .{ .tag = user.vpiStmt, .to = try b.stmt(s.body) },
                }, &.{}, &.{});
                if (code_tables.literal(f, s.event)) |v| b.objects.hot.items[at].delays = try b.arena.dupe(f64, &.{v});
                break :blk at;
            },
            .event => b.code(user.vpiEventControl, &.{
                .{ .tag = user.vpiCondition, .to = try b.expr(s.event) },
                .{ .tag = user.vpiStmt, .to = try b.stmt(s.body) },
            }, &.{}, &.{}),
            .level => b.code(user.vpiWait, &.{
                .{ .tag = user.vpiCondition, .to = try b.expr(s.event) },
                .{ .tag = user.vpiStmt, .to = try b.stmt(s.body) },
            }, &.{}, &.{}),
        },
        // §11.6.21 event stmt '->' -> named event.
        .event_trigger => |s| b.code(user.vpiEventStmt, &.{.{ .tag = user.vpiNamedEvent, .to = try b.expr(s.target) }}, &.{}, &.{}),
        // disable -> the named block, task or function it disables: AMS
        // §11.6.24 tags the arrow vpiScope, IEEE 1364-2005 §26.6.38
        // vpiExpr, and both are answered.
        .disable => |s| blk: {
            const target = b.lookupAs(f.str(s.name), .scope);
            break :blk b.code(user.vpiDisable, &.{ .{ .tag = user.vpiScope, .to = target }, .{ .tag = user.vpiExpr, .to = target } }, &.{}, &.{});
        },
        .sys_task => |s| blk: {
            const name = f.str(s.name);
            const args = try b.arena.alloc(u32, s.args.len);
            for (s.args, args) |a, *arg| arg.* = if (a == .none) schema.no_obj else try b.expr(a);
            // A.6.9: a name without `$` is a user task enable (§11.6.16
            // task call -> task).
            const user_task = name.len == 0 or name[0] != '$';
            const at = try b.code(if (user_task) user.vpiTaskCall else user.vpiSysTaskCall, if (user_task) &.{.{ .tag = user.vpiTask, .to = b.lookupAs(name, .task) }} else &.{}, &.{.{ .tag = user.vpiArgument, .items = try b.many(args) }}, &.{});
            b.objects.hot.items[at].name = try b.arena.dupe(u8, name);
            b.objects.hot.items[at].in_analog = b.analog != null;
            b.objects.hot.items[at].src_tok = f.stmtTok(id);
            b.objects.hot.items[at].src_stmt = id;
            break :blk at;
        },
        .contribute => |s| b.contrib(s.lhs, s.rhs),
        // §5.6.7's indirect form: the class's `ind flow`/`ind potential`,
        // with vpiLhs the probe it equates and vpiRhs the equation.
        .indirect => |s| blk: {
            const at = try b.contrib(s.lhs, s.eqn);
            const probe = try b.expr(s.probe);
            // Taken after every append: a row pointer does not survive
            // the array growing.
            const o = &b.objects.hot.items[at];
            o.edges = try b.arena.dupe(Edge, &.{
                o.edges[0],
                .{ .tag = user.vpiLhs, .to = probe },
                o.edges[1],
            });
            o.props = try b.arena.dupe(Prop, &.{ o.props[0], .{ .prop = user.vpiDirect, .value = 0 } });
            break :blk at;
        },
        // A jump has no §11.6.21 object.
        .jump => schema.no_obj,
    };
}

/// §11.6.20: a contribution to a branch. The branch is the one the
/// access names when it names a declared branch; `vpiFlow` is whether the
/// access is the branch discipline's flow access.
pub fn contrib(b: *Builder, lhs: Ast.ExprId, rhs: Ast.ExprId) Error!u32 {
    const f = b.file;
    var branch = schema.no_obj;
    var flow: c_int = 0;
    if (f.exprs.tag(lhs) == .branch_access) {
        const first = f.exprs.lhs(lhs);
        if (b.analog) |an| if (f.exprs.tag(first) == .ident and f.exprs.rhs(lhs) == .none) {
            if (an.branches.get(f.str(f.exprs.strOf(first)))) |br| {
                branch = br;
                if (b.objects.coldOf(br).disc) |di| if (an.flow_access.get(di)) |acc| {
                    flow = @intFromBool(std.mem.eql(u8, acc, f.str(f.exprs.strOf(lhs))));
                };
            }
        };
    }
    return b.code(user.vpiContrib, &.{
        .{ .tag = user.vpiBranch, .to = branch },
        .{ .tag = user.vpiRhs, .to = try b.expr(rhs) },
    }, &.{}, &.{
        .{ .prop = user.vpiFlow, .value = flow },
        .{ .prop = user.vpiDirect, .value = 1 },
    });
}
