const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Mir = @import("ir").Mir;
const Lower = @import("Lower.zig");
const lower_discrete_mark = @import("discrete_mark.zig");
const lower_expr_name = @import("expr_name.zig");
const lower_branch = @import("branch.zig");
const lower_event_args = @import("event_args.zig");
const lower_format = @import("format.zig");
const lower_sysfunc_context = @import("sysfunc_context.zig");
const lower_context = @import("context.zig");
const DiscreteCtx = lower_context.DiscreteCtx;
const EventRefs = lower_context.EventRefs;
const Edge = lower_discrete_mark.Edge;
const Oom = Lower.Oom;

pub fn checkDiscreteContext(self: *Lower, module: *const Ast.ModuleDecl) Oom!void {
    assert(module.name != .none);
    if (module.discrete.len == 0) return;
    // §7.3.6.1: a named event triggered in the analog context and named in the
    // digital one crosses the A/D boundary as an A2D event, which the
    // mixed-signal kernel does not carry yet. Refused rather than lowered as
    // two unrelated events that never meet. The other direction, a digital
    // trigger the analog block waits on, is §7.3.6.2's explicit D2A
    // (`Lowered.discrete_events`).
    if (self.out.mixed_signal and module.events.len != 0) {
        var dig: EventRefs = .{ .l = self, .module = module };
        for (module.discrete) |blk| try dig.stmt(blk.body);
        var ana: EventRefs = .{ .l = self, .module = module, .triggers_only = true, .skip_carried = true };
        for (module.analog) |blk| try ana.stmt(blk.body);
        for (ana.names.keys(), ana.names.values()) |name, tok| if (dig.names.contains(name))
            try self.err(tok, .E0437, "named event `{s}` is triggered by the analog block and named by a digital process, and the kernel carries such an A2D event only as a statement of a cross/above/timer event control (§7.3.6.1)", .{name});
    }

    var ctx: DiscreteCtx = .{ .mixed = self.out.mixed_signal };
    // Analog functions only. §4.7.3/§7.3.7's rule is that an analog function
    // may not be called from the discrete context; a digital function called
    // from a digital process is the ordinary case and must not be refused.
    for (module.functions) |f| {
        if (!f.is_analog) continue;
        try ctx.funcs.put(self.arena, self.file.str(f.name), {});
    }

    for (module.discrete) |blk| {
        ctx.where = if (blk.is_always) "an always block" else "an initial block";
        try scanContext(self, blk.body, true, blk.main_tok, &ctx);
    }
    // The continuous side second: §7.2.2's conflict and §5.2.1's read are both
    // "this analog statement, against what the discrete blocks own", so the
    // discrete set has to be complete first. §7.2.2 is symmetric; the conflict
    // is reported at the analog statement.
    for (module.analog) |blk| try scanContext(self, blk.body, false, blk.is_initial, &ctx);
}

/// Collect discrete §7.2.2 assignment targets, then check the continuous side
/// for both-context assignments and §5.2.1 digital reads in `analog initial`.
/// The context is compile-time: each walk keeps its own early exits and visits.
/// Runs only in a module that has a discrete block.
///
/// ponytail: a name declared in a named block inside the discrete body shadows
/// the module-level one, and this scan does not model that; `self.vars.contains`
/// keeps it to names the module declared, but a block-local `integer x`
/// shadowing a module-level `real x` is still recorded. Give `Ast.SeqBlock` a
/// scope walk here if a model needs it.
fn scanContext(self: *Lower, id: Ast.StmtId, comptime discrete: bool, context: if (discrete) u32 else bool, ctx: *DiscreteCtx) Oom!void {
    assert(id == .none or @backingInt(id) < self.stmtCount());
    if (id == .none or (!discrete and ctx.assigned.count() == 0)) return;
    const pushed = try ctx.shadows.enter(self, id);
    defer ctx.shadows.leave(pushed);
    const is_initial = if (discrete) {} else context;
    const ex = &self.file.exprs;
    // Every variable the statement writes, not only an assignment target: an
    // output actual and a `$random` seed assign too (`stmtWrites`). The target
    // of `bus[3] = ...` is the array, so `lvalueBase` walks down to the name —
    // §7.2.2's domain is a property of the declaration.
    const funcs: []const Ast.FuncDecl = if (self.module) |m| m.functions else &.{};
    var writes: std.ArrayList(Ast.ExprId) = .empty;
    defer writes.deinit(self.arena);
    try self.file.stmtWrites(funcs, id, self.arena, &writes);
    for (writes.items) |w| {
        const t = self.file.lvalueBase(w);
        if (t == .none) continue;
        const name = self.file.str(ex.strOf(t));
        if (ctx.shadows.hides(name)) continue;
        if (discrete) {
            if (self.vars.contains(name) or self.out.discrete_inputs.contains(name)) try ctx.assigned.put(self.arena, name, context);
        } else if (ctx.assigned.get(name)) |dtok| {
            var b = self.errWith(self.file.exprs.mainTok(t), .E0432);
            b.msg("`{s}`", .{name});
            b.label(
                self.tokenSpan(dtok),
                "`{s}` is also assigned here, in the discrete context",
                .{name},
            );
            try b.emit();
        }
    }
    // Every edge but the four arms below, which read less than all of them.
    const Walk = struct {
        l: *Lower,
        context: if (discrete) u32 else bool,
        ctx: *DiscreteCtx,
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
            try scanContextExpr(w.l, e, discrete, if (discrete) {} else w.context, w.ctx);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) Oom!void {
            try scanContext(w.l, s, discrete, w.context, w.ctx);
        }
    };
    // §8.5.1 "Note that A2D events must be analog event controlled statements
    // (e.g., @cross, @timer)": a digital event control that waits on a
    // probe's value (`@(V(a))`, `@(posedge V(a) > 1)`) would be an A2D event
    // no analog event function monitors — §7.3.5's cross/above/absdelta are
    // how the discrete context sees a continuous value change.
    if (discrete and self.file.stmt(id) == .event_control) {
        const c = self.file.stmt(id).event_control;
        if (c.kind == .event and c.event != .none) if (probeOutsideEventFn(self.file, c.event)) |p|
            try self.err(ex.mainTok(p), .E0484, "`{s}(...)` in the event control of {s}", .{ self.file.str(ex.strOf(p)), ctx.where });
        // §7.3.6.1 admits "analog variables that are only assigned values in
        // analog event statements"; one the analog block assigns outside
        // every event statement changes with the solution, as a probe does.
        if (c.kind == .event and c.event != .none) if (freeVarOutsideEventFn(self, c.event)) |v|
            try self.err(ex.mainTok(v), .E0484, "`{s}`, which the analog block assigns outside any event statement, in the event control of {s}", .{ self.file.str(ex.strOf(v)), ctx.where });
    }
    // A.6.2: a blocking, nonblocking or procedural `assign`/`deassign` write
    // is to a `variable_lvalue`; only `force`/`release` also take a net.
    if (discrete and self.file.stmt(id) == .assign) {
        const a = self.file.stmt(id).assign;
        const t = self.file.lvalueBase(a.target);
        if (a.continuous != .force and a.continuous != .release and t != .none) if (self.module) |m| {
            if (lower_context.isNetName(m, ex.strOf(t)))
                try self.err(ex.mainTok(t), .E0482, "`{s}` is a net, and {s}", .{ self.file.str(ex.strOf(t)), switch (a.continuous) {
                    .assign => "a procedural `assign` (§8.5.3.2) writes a variable",
                    .deassign => "`deassign` (§8.5.3.2) releases a variable",
                    .none, .force, .release => if (a.nonblocking) "a nonblocking assignment (§8.5.3.4) updates a variable" else "a blocking assignment (§8.5.3.3) updates a variable",
                } });
        };
    }
    // §9.2's digital column: a task whose "Supported in digital context" cell
    // is No (§9.7: "$fatal, $error, $warning" are "in the analog context
    // only"). Named by the table's own words, not by what VerA can execute.
    if (discrete) if (self.file.stmt(id) == .sys_task) {
        const st = self.file.stmt(id).sys_task;
        const n = self.file.str(st.name);
        if (lower_sysfunc_context.isAnalogOnlySysFunc(n)) try self.err(self.file.stmtTok(id), .E0821, "`{s}` in {s}", .{ n, ctx.where })
        // §9.4.3's pairing rule — "For each % character (except %m, %% and
        // %l) that appears in a string, a corresponding expression argument
        // shall be supplied" — is a property of the format text, so it holds in
        // the digital context too, where §9.4.7 adds %r to the letters it
        // counts. Judged here, before the digital kernel would meet the gap at
        // run time.
        else if (Mir.callee.takesFormat(.fromName(n)))
            try lower_format.checkFormatPairing(self, self.file.stmtTok(id), st.args);
    };
    switch (self.file.stmt(id)) {
        // The target is a write, collected above; only the value is read.
        .assign => |a| try scanContextExpr(self, a.value, discrete, is_initial, ctx),
        // §7.3, the write half: "Read operations of nets and variables in both
        // domains are allowed from both contexts. Write operations of nets and
        // variables are only allowed from the context of their domain." A `<+`
        // here writes a continuous net from the discrete context, so it is
        // refused even when the block itself is already refused (E0205 is
        // about VerA; §7.3 is about the source).
        //
        // Not E0432 (§7.2.2, "assigned in both contexts"): that needs two
        // writers. Here there is one writer, in the wrong domain.
        .contribute => |s| if (discrete) {
            try self.err(self.file.exprs.mainTok(s.lhs), .E0435, "contributed from {s}", .{ctx.where});
        } else try scanContextExpr(self, s.rhs, discrete, is_initial, ctx),
        .indirect => |s| if (discrete) {
            try self.err(self.file.exprs.mainTok(s.lhs), .E0435, "indirectly contributed from {s}", .{ctx.where});
        } else try scanContextExpr(self, s.eqn, discrete, is_initial, ctx),
        .jump => {},
        else => try self.file.stmtEdges(id, Walk{ .l = self, .context = context, .ctx = ctx }), // else: stmtEdges is exhaustive
    }
}

/// Every expression reachable from a context statement (`ExprStore.children`).
/// §5.2.1: "digital values cannot be accessed from the analog initial block as
/// they have not yet been assigned when the analog initial block is executed."
/// Only the read is diagnosed, and only inside an `analog initial`; the same
/// read from the ordinary analog block is what §7.3.1 Table 7-1 is the
/// conversion table for.
fn scanContextExpr(self: *Lower, e: Ast.ExprId, comptime discrete: bool, is_initial: if (discrete) void else bool, ctx: *DiscreteCtx) Oom!void {
    assert(e == .none or self.exprValid(e));
    if (e == .none or (!discrete and !is_initial)) return;
    const ex = &self.file.exprs;
    const tag = ex.tag(e);
    if (discrete) {
        // §4.5.15, verbatim: analog operators "can not be used inside an initial
        // or always block". Same code as the analog-function-body and
        // analog-initial cases, because it is the same sentence's family of
        // contexts: an operator carries state from one accepted timepoint to the
        // next, and none of these has a timepoint to advance.
        if (tag == .filter_call) try self.err(self.file.exprs.mainTok(e), .E0422, "not allowed in {s}", .{ctx.where});
        if (tag == .sys_call and lower_sysfunc_context.isAnalogOnlySysFunc(self.file.str(ex.strOf(e))))
            try self.err(ex.mainTok(e), .E0821, "`{s}` in {s}", .{ self.file.str(ex.strOf(e)), ctx.where });
        // §5.10: "The usage of initial_step and final_step analog events are
        // not allowed in the digital context."
        if (tag == .event_initial_step or tag == .event_final_step)
            try self.err(ex.mainTok(e), .E0708, "`{s}` in {s}, the digital context", .{
                if (tag == .event_initial_step) "initial_step" else "final_step", ctx.where,
            });
        // What the mixed-signal kernel cannot do yet, named by the clause that
        // asks for it. Both are legal Verilog-AMS (§7.3.3/§7.3.5).
        // `cross`/`above` are monitored (§7.3.5) and `V(a)`/`V(a, b)` probed
        // (§7.3.6.3) by the mixed-signal kernel.
        if (ctx.mixed) switch (tag) {
            .event_function => {
                const name = self.file.str(ex.strOf(e));
                if (!std.mem.eql(u8, name, "cross") and !std.mem.eql(u8, name, "above") and !std.mem.eql(u8, name, "absdelta"))
                    try self.err(ex.mainTok(e), .E0437, "`{s}` in {s} is §7.3.6.1's A2D event, and the kernel monitors only cross(), above() and absdelta()", .{ name, ctx.where });
            },
            .branch_access => if (!std.mem.eql(u8, self.file.str(ex.strOf(e)), "V") or !probeTerminal(ex, ex.lhs(e)) or
                (ex.rhs(e) != .none and !probeTerminal(ex, ex.rhs(e))))
                try self.err(ex.mainTok(e), .E0437, "an analog probe in {s} is §7.3.6.3's promoted-time read, and the kernel reads only V(net), V(net, net) and V(branch)", .{ctx.where})
            else for ([_]Ast.ExprId{ ex.lhs(e), ex.rhs(e) }) |t| {
                if (t != .none) try recordProbeTerminal(self, t, ex.rhs(e) == .none);
            },
            .port_access => try self.err(ex.mainTok(e), .E0437, "a port flow probe in {s} is §7.3.6.3's promoted-time read, and the kernel reads only V(net) and V(net, net)", .{ctx.where}),
            else => {}, // else: every other tag is executable or judged elsewhere
        };
        // §7.3.5 "The arguments to these events are in the continuous
        // context": a monitored event in a digital event control is the
        // §5.10.3 function itself, so its argument rules hold here as they
        // do in an analog block (E0517), and a call inside its arguments is
        // a call from the continuous context, so §7.3.7's first sentence
        // (E0436) applies to a digital function there.
        if (tag == .event_function) {
            _ = try lower_event_args.checkEventArgBounds(self, e, self.file.str(ex.strOf(e)));
            for (ex.args(e)) |a| try digitalCallsIn(self, a);
        }
        // §7.3.3 "All probes which are legal in a continuous context of a
        // module are also legal in the discrete context" — and the probe is
        // one "using access functions": the access function has to belong to
        // the net's discipline in either context (§4.4, E0501/E0337). Only a
        // declared net that is an analog node is judged; a digital-owned
        // name never became one (`declareDiscreteInputs`).
        if (tag == .branch_access) if (self.access_kind.get(self.file.str(ex.strOf(e)))) |global| {
            for ([_]Ast.ExprId{ ex.lhs(e), ex.rhs(e) }) |arg| {
                if (arg == .none or ex.tag(arg) != .ident) continue;
                const node = self.node_voltages.get(self.file.str(ex.strOf(arg))) orelse continue;
                const access = try lower_branch.accessOn(self, e, self.file.str(ex.strOf(e)), global, node, Lower.ground);
                try lower_branch.checkAccessMatch(self, e, self.file.str(ex.strOf(e)), access, node);
            }
        };
        if (tag == .call) {
            const name = self.file.str(ex.strOf(e));
            if (ctx.funcs.contains(name)) {
                var b = self.errWith(self.file.exprs.mainTok(e), .E0430);
                b.msg("`{s}`", .{name});
                b.note(
                    "an analog function shall only be called from an analog block " ++
                        "or from another analog function",
                    .{},
                );
                try b.emit();
            }
        }
    } else if (tag == .ident) {
        const name = self.file.str(ex.strOf(e));
        if (ctx.assigned.get(name)) |dtok| {
            var b = self.errWith(self.file.exprs.mainTok(e), .E0431);
            b.msg("`{s}`", .{name});
            b.label(self.tokenSpan(dtok), "`{s}` is assigned here, in the discrete context", .{name});
            try b.emit();
        }
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| try scanContextExpr(self, c, discrete, is_initial, ctx);
}

/// Whether `e` is a terminal the mixed-signal kernel's digital `V(...)` probe
/// reads: a simple or a §6.7.1 hierarchical name of a net or a named branch.
fn probeTerminal(ex: *const Ast.ExprStore, e: Ast.ExprId) bool {
    return ex.tag(e) == .ident or ex.tag(e) == .hier_ident;
}

/// Records digital probe terminal `t` in `Lowered.discrete_probes`, under the
/// name the digital half spells it (its parts joined by `.`): the node pair
/// of the named branch it names when it is a probe's `only` argument, else
/// its net and ground. §6.7.1 a hierarchical name that names neither is
/// E0901, as in the analog block; a simple one the digital half resolves.
fn recordProbeTerminal(self: *Lower, t: Ast.ExprId, only: bool) Oom!void {
    assert(t == .none or self.exprValid(t));
    const ex = &self.file.exprs;
    const key = if (ex.tag(t) == .ident) self.file.str(ex.strOf(t)) else blk: {
        var parts: std.ArrayList([]const u8) = .empty;
        for (ex.nameParts(t)) |p| try parts.append(self.arena, self.file.str(p));
        break :blk try std.mem.join(self.arena, ".", parts.items);
    };
    if (self.out.discrete_probes.contains(key)) return;
    const name = if (ex.tag(t) == .ident) key else try lower_expr_name.flatName(self, t);
    const branch = if (only) self.branches.get(name) else null;
    const pair: [2]u32 = if (branch) |b| .{ b.hi, b.lo } else if (self.node_voltages.get(name)) |n| .{ n, Lower.ground } else {
        if (ex.tag(t) == .hier_ident) try self.err(ex.mainTok(t), .E0901, "`{s}` names no net or branch in the elaborated design", .{name});
        return;
    };
    var nodes: [2][]const u8 = undefined;
    for (pair, &nodes) |n, *out| out.* = if (n == Lower.ground) "" else self.out.nodeName(n);
    try self.out.discrete_probes.put(self.arena, key, nodes);
}

/// §7.3.7 "Digital functions cannot be called from within the analog
/// context", for an expression the LRM puts in the continuous context while
/// it is written inside a digital process: the arguments of a monitored
/// event (§7.3.5). The same code and wording as `lower_func.lowerUserCall`'s
/// call from an analog block.
fn digitalCallsIn(self: *Lower, e: Ast.ExprId) Oom!void {
    assert(e == .none or self.exprValid(e));
    if (e == .none) return;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .call) if (self.module) |m| for (m.functions) |*fd| {
        if (fd.name != ex.strOf(e) or fd.is_analog) continue;
        var b = self.errWith(ex.mainTok(e), .E0436);
        b.msg("`{s}`, in the arguments of an analog event, which §7.3.5 puts in the continuous context", .{self.file.str(fd.name)});
        b.label(self.tokenSpan(fd.main_tok), "`{s}` is declared here, without `analog`", .{self.file.str(fd.name)});
        try b.emit();
        break;
    };
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| try digitalCallsIn(self, c);
}

/// The first branch or port probe in event expression `e` that no analog
/// event function (`cross`, `above`, `timer`, `absdelta`) encloses, or null.
fn probeOutsideEventFn(file: *const Ast.SourceFile, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none) return null;
    const ex = &file.exprs;
    switch (ex.tag(e)) {
        .event_function => return null,
        .branch_access, .port_access => return e,
        else => {}, // else: every other node is searched through its children
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (probeOutsideEventFn(file, c)) |p| return p;
    return null;
}

/// The first analog variable in `e`, outside an analog event function's
/// arguments, that no analog event statement assigns (a `Lowered.discrete_reads`
/// name not held as `.event`), or null.
fn freeVarOutsideEventFn(self: *const Lower, e: Ast.ExprId) ?Ast.ExprId {
    assert(e == .none or self.exprValid(e));
    if (e == .none) return null;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .event_function => return null,
        .ident => {
            const name = self.file.str(ex.strOf(e));
            if (self.out.discrete_reads.contains(name) and self.var_state.held_names.get(name) != .event) return e;
            return null;
        },
        else => {}, // else: every other node is searched through its children
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (freeVarOutsideEventFn(self, c)) |v| return v;
    return null;
}

test "checkDiscreteContext: §5.2.1 and §7.2.2 judge the analog side against the digital writes" {
    // §5.2.1: "digital values cannot be accessed from the analog initial
    // block" (E0431); the ordinary analog block reads one through §7.3.1.
    try Lower.expectBodyVerdict(
        "  real d, y;\n  initial d = 1.0;\n  analog initial begin\n    y = d;\n  end",
        "",
        .E0431,
    );
    try Lower.expectBodyVerdict("  real d, y;\n  initial d = 1.0;", "    y = d;", null);
    // §7.2.2: "It shall be an error to assign to a given variable in both
    // contexts" (E0432).
    try Lower.expectBodyVerdict("  real x;\n  initial x = 1.0;", "    x = 2.0;", .E0432);
    // §5.10: initial_step "not allowed in the digital context" (E0708).
    try Lower.expectBodyVerdict("  real x;\n  initial @(initial_step) x = 1.0;", "", .E0708);
}
