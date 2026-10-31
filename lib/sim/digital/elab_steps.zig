//! The elaborated design in, the steps `elaborate` runs after pass one out: `disable` targets bound, net runs, process order (§9.9), the time-0 queue, variable initializers.
//! Cites: IEEE 1364-2005 §6.2.1, §9.9, §10.3, §11.4.2, §19.8.
//!
//! Contents:
//! - `pub fn bindDisables(r: *Run, from: usize) Error!void`
//! - `pub fn mixedTimescales(arena: std.mem.Allocator, events: []const Front.Preprocessor.TimescaleEvent) Error![]const Front.Preprocessor.TimescaleEvent`
//! - `pub fn netRuns(`
//! - `pub fn constantDelay(r: *Run, d: Ast.Delay3) Error!bool`
//! - `pub fn topDeclares(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, name: []const u8) bool`
//! - `pub fn processOrder(r: *Run, e: *const elab.Elab) Error![]const u32`
//! - `pub fn calls(ex: *const Ast.ExprStore, e: Ast.ExprId) bool`
//! - `pub fn driverBits(d: Driver, width: u32) [2]u32`
//! - `pub fn initVars(r: *Run, vars: []const Ast.VarDecl) Error!void`
//! - `pub fn processes(r: *Run, blocks: []const Ast.DiscreteBlock) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const Scheduler = @import("../scheduler.zig").Scheduler;
/// Scheduler ticks. `Time` below is the timescale module, not this.
const Tick = @import("../scheduler.zig").Time;
const Time = @import("../time.zig");
const deep = @import("base").deep_stack;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const display = @import("display.zig");
/// Public for the VPI (src/vpi/value.zig), which writes a value the way a
/// process does (`waiters.store` now, `exec.enqueue` of a `.write` later), so a
/// §12.30 put wakes waiters and value-change watchers like any other write.
const exec = @import("exec.zig");
/// §17 system tasks.
const system = @import("system.zig");
const driver = @import("driver.zig");
const binding = @import("bind.zig");
const elab = @import("elab.zig");
const waiters = @import("waiters.zig");
const resolution = @import("resolution.zig");
const tchk = @import("tchk.zig");
const vpi = @import("vpi.zig");
const Type = compile.Type;
const Instruction = compile.Instruction;
const Row = exec.Row;
const Delay = @import("net.zig").Delay;
const Net = @import("net.zig").Net;
const NetCold = @import("net.zig").NetCold;
const no_cold = @import("net.zig").no_cold;
const Tran = @import("net.zig").Tran;
const Signal = @import("net.zig").Signal;
const Inertial = @import("net.zig").Inertial;
const no_transition = @import("net.zig").no_transition;
const Driver = @import("net.zig").Driver;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const Show = display.Show;
const TimeFormat = display.TimeFormat;
/// One elaborated design and its whole simulation state (`Run.zig`).
const Run = @import("Run.zig");
/// The descriptor table a `Run` with no `file_io` opens files through.
const own_files = system.own;
const root = @import("root.zig");
const Error = root.Error;

/// Binds `r.disables[from..]` to their blocks' pc ranges or their tasks.
/// A function compiled early for a §10.4.5 constant call binds its own at
/// once (`elab.earlyFrame`): it runs before the other processes exist.
pub fn bindDisables(r: *Run, from: usize) Error!void {
    disabling: for (r.disables.items[from..]) |d| {
        var s = d.name.scope;
        while (true) {
            if (r.blocks.get(.{ .scope = s, .str = d.name.str })) |range| {
                r.code.items[d.at] = .{ .disable_block = .{ .start = range.start, .end = range.end } };
                continue :disabling;
            }
            if (!r.scope_info.items[s].lexical) break;
            s = r.scope_info.items[s].parent;
        }
        const idx = r.sub_by_name.get(.{ .scope = r.instanceOf(d.name.scope), .str = d.name.str }) orelse
            return r.fail(d.tok, "undeclared named block or task", .{});
        if (r.subs.items[idx].decl.is_function) return r.fail(d.tok, "§10.3: `disable` cannot name a function, only a named block within one", .{});
        r.code.items[d.at] = .{ .disable_task = idx };
    }
}

/// `Mixed.timescales` with the first event moved to offset 0. The analog
/// compile's text opens with VerA's own Annex D/E prelude, ahead of every
/// directive the source wrote, and §19.8's "some modules have a `timescale
/// specified and others do not" is about the source's modules, not those.
pub fn mixedTimescales(arena: std.mem.Allocator, events: []const Front.Preprocessor.TimescaleEvent) Error![]const Front.Preprocessor.TimescaleEvent {
    const out = try arena.dupe(Front.Preprocessor.TimescaleEvent, events);
    if (out.len != 0) out[0].at = 0;
    return out;
}

/// The rows of `rows` grouped by net, as one counting sort: `items` holds
/// each row index once per net `netOf(row, k)` names (`k` < `per_row`), and
/// net `n`'s run is `items[start[n]..start[n + 1]]`, in row order. The
/// caller frees `start` when it has cut the runs; `items` is what they borrow.
pub fn netRuns(
    arena: std.mem.Allocator,
    n_nets: usize,
    n_items: usize,
    rows: anytype,
    comptime netOf: anytype,
    comptime per_row: usize,
) Error!struct { start: []u32, items: []u32 } {
    const start = try arena.alloc(u32, n_nets + 1);
    @memset(start, 0);
    for (rows) |row| inline for (0..per_row) |k| {
        start[netOf(row, k) + 1] += 1;
    };
    for (1..n_nets + 1) |i| start[i] += start[i - 1];
    const items = try arena.alloc(u32, n_items);
    const fill = try arena.dupe(u32, start[0..n_nets]);
    defer arena.free(fill);
    for (rows, 0..) |row, i| inline for (0..per_row) |k| {
        const net = netOf(row, k);
        items[fill[net]] = @intCast(i);
        fill[net] += 1;
    };
    return .{ .start = start, .items = items };
}

/// Whether every value of `d` is a constant expression. A.2.2.3's
/// `delay_value` and the `mintypmax_expression` in `delay3`'s parentheses may
/// read a variable too (`Run.driver_delays`).
pub fn constantDelay(r: *Run, d: Ast.Delay3) Error!bool {
    // Every value is checked, not only those before the first variable one:
    // `exec.variableDelay` types each of them at run time.
    var constant = true;
    for ([_]Ast.ExprId{ d.rise, d.fall, d.off }) |x| if (x != .none) {
        try compile.checkExpr(r, x);
        constant = constant and compile.constantExpression(r, x);
    };
    return constant;
}

/// Whether top-level module `m` declares a parameter `--param` may set,
/// `name`: one that is not a localparam.
pub fn topDeclares(file: *const Ast.SourceFile, m: *const Ast.ModuleDecl, name: []const u8) bool {
    for (m.params) |p| if (!p.is_local and std.mem.eql(u8, file.str(p.name), name)) return true;
    return false;
}

/// The bits [lo, hi) of its `width`-bit net that driver `d` drives: a port
/// window's, or an instance-array member's one output bit; else all of them.
/// The order `elaborateDeep` queues the process groups of `e` in: index k
/// below `e.insts.items.len` is that instance's module body, the rest are
/// `e.procs` (generate blocks), each visited when the scope tree's post-order
/// walk from the roots reaches its scope.
pub fn processOrder(r: *Run, e: *const elab.Elab) Error![]const u32 {
    const a = r.arena;
    const n = r.scope_info.items.len;
    const groups = try a.alloc(std.ArrayList(u32), n);
    @memset(groups, .empty);
    for (e.insts.items, 0..) |inst, k| try groups[inst.scope].append(a, @intCast(k));
    for (e.procs.items, 0..) |p, k| try groups[p.scope].append(a, @intCast(e.insts.items.len + k));
    const children = try a.alloc(std.ArrayList(u32), n);
    @memset(children, .empty);
    for (r.scope_info.items, 0..) |info, k| if (info.parent != k and k != 0) try children[info.parent].append(a, @intCast(k));
    const BySource = struct {
        fn less(toks: *const std.AutoHashMapUnmanaged(u32, u32), x: u32, y: u32) bool {
            return (toks.get(x) orelse 0) < (toks.get(y) orelse 0);
        }
    };
    for (children) |c| std.sort.block(u32, c.items, &r.scope_toks, BySource.less);
    var out: std.ArrayList(u32) = .empty;
    // An explicit stack: (scope, next child to visit).
    var stack: std.ArrayList([2]u32) = .empty;
    for (r.roots) |root_scope| {
        try stack.append(a, .{ root_scope, 0 });
        while (stack.items.len != 0) {
            const top = &stack.items[stack.items.len - 1];
            const kids = children[top[0]].items;
            if (top[1] < kids.len) {
                const c = kids[top[1]];
                top[1] += 1;
                try stack.append(a, .{ c, 0 });
                continue;
            }
            try out.appendSlice(a, groups[top[0]].items);
            _ = stack.pop();
        }
    }
    std.debug.assert(out.items.len == e.insts.items.len + e.procs.items.len);
    return out.items;
}

/// Whether expression `e` calls a function, user or system.
pub fn calls(ex: *const Ast.ExprStore, e: Ast.ExprId) bool {
    if (e == .none) return false;
    switch (ex.tag(e)) {
        .call, .sys_call => return true,
        else => {}, // else: an operator or operand, whose operands are searched
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (calls(ex, c)) return true;
    return false;
}

pub fn driverBits(d: Driver, width: u32) [2]u32 {
    const bit: ?u32 = switch (d.source) {
        .bridge => |b| return .{ b.dst_lo, b.dst_lo + b.width + b.ext },
        .gate => |g| g.out_bit,
        .mos => |m| m.out_bit,
        .udp => |u| u.out_bit,
        .expr, .pull => null,
    };
    return if (bit) |b| .{ b, b + 1 } else .{ 0, width };
}

/// Compiles each of `blocks` in `r.scope` and queues it at time 0.
/// IEEE 1364-2005 §6.2.1: a variable declaration assignment "shall be the
/// same as" an initial block making the assignment, so each initializer of
/// `vars`, declared in `r.scope`, is one, queued ahead of the scope's own
/// processes. A mixed module's initialized variables are the analog block's
/// and were never declared here.
pub fn initVars(r: *Run, vars: []const Ast.VarDecl) Error!void {
    for (vars) |v| if (v.init != .none) {
        const at = r.names.get(.{ .scope = r.scope, .str = v.name }) orelse continue;
        try compile.checkExpr(r, v.init);
        // §6.2.1: "The assignment shall be to a constant expression."
        if (!compile.constantExpression(r, v.init)) return r.exprFail(v.init, "§6.2.1: a constant expression is required here");
        const start = try compile.append(r, .{ .init_var = .{ .slot = at, .value = v.init } });
        _ = try compile.append(r, .stop);
        _ = try exec.enqueue(r, .{ .run_process = start }, null, false);
    };
}

pub fn processes(r: *Run, blocks: []const Ast.DiscreteBlock) Error!void {
    for (blocks) |process| {
        const start: u32 = @intCast(r.code.items.len);
        try compile.compileStmt(r, process.body, 0);
        _ = try compile.append(r, if (process.is_always)
            .{ .restart = .{ .target = start, .tok = process.main_tok } }
        else
            .stop);
        if (process.is_always and try levelControlled(r, process.body)) {
            try r.early.append(r.arena, start);
        } else _ = try exec.enqueue(r, .{ .run_process = start }, null, false);
    }
}

// ---- private ----

/// Whether `body`, an always construct's, starts with an event control on
/// levels only (`@(a or b[0])`, `@*`): no posedge or negedge, no named event.
/// §9.9 gives initial and always constructs no order; VerA starts these
/// first at time 0, ahead of every driver and process (`Run.early`), so
/// they see the time-0 changes the others make, as iverilog does (ivtest
/// pr1026, pr1956211, pr2986528).
fn levelControlled(r: *Run, body: Ast.StmtId) Error!bool {
    const st = r.file.stmt(body);
    if (st != .event_control or st.event_control.kind != .event) return false;
    const L = struct {
        fn level(rr: *Run, e: Ast.ExprId) Error!bool {
            assert(e != .none);
            const ex = &rr.file.exprs;
            return switch (ex.tag(e)) {
                .event_or => try level(rr, ex.lhs(e)) and try level(rr, ex.rhs(e)),
                .event_posedge, .event_negedge, .event_function, .event_driver_update => false,
                .ident, .hier_ident, .index => (try compile.eventReference(rr, e)) == null,
                else => true, // else: an expression term
            };
        }
    };
    return st.event_control.event == .none or try L.level(r, st.event_control.event);
}
