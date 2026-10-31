//! An event control or `@*` in, the slots and select terms a process waits on out, and the reads a deferred or automatic one makes.
//! Cites: IEEE 1364-2005 §9.7.1 to §9.7.7, §10.2.1, §10.2.3; VAMS §7.3.6.3 probes.
//!
//! Contents:
//! - `pub fn sensitivity(self: *Run, e: Ast.ExprId, out: *std.ArrayList(u32)) Error!void`
//! - `pub fn probeTerminal(ex: *const Ast.ExprStore, e: Ast.ExprId) bool`
//! - `pub fn probeName(self: *const Run, a: std.mem.Allocator, e: Ast.ExprId) Error![]const u8`
//! - `pub fn sensitivityProbes(self: *Run, e: Ast.ExprId, out: *std.ArrayList(u32), probes: ?*std.ArrayList(Ast.ExprId)) Error!void`
//! - `pub fn readSlots(self: *Run, id: Ast.StmtId, out: *std.ArrayList(u32)) Error!void`
//! - `pub fn watch(self: *Run, at: u32, out: *std.ArrayList(u32)) Error!void`
//! - `pub fn checkTarget(self: *Run, e: Ast.ExprId) Error!void`
//! - `pub fn parksOnly(s: @FieldType(Ast.Stmt, "assign")) bool`
//! - `pub fn intraTimed(s: @FieldType(Ast.Stmt, "assign")) bool`
//! - `pub fn waitIntra(self: *Run, id: Ast.StmtId, s: @FieldType(Ast.Stmt, "assign")) Error!void`
//! - `pub fn notAutomatic(self: *Run, e: Ast.ExprId, comptime what: []const u8) Error!void`
//! - `pub fn deferredReads(self: *Run, scope: u32, s: Ast.StmtId) Error!void`
//! - `W.expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {}`
//! - `W.stmt(w: @This(), c: Ast.StmtId) Error!void`
//! - `pub fn readsNoAutomatic(self: *Run, e: Ast.ExprId, comptime what: []const u8) Error!void`
//! - `pub fn checkDelay(self: *Run, e: Ast.ExprId) Error!void`
//! - `pub fn checkEvent(self: *Run, e: Ast.ExprId) Error!void`
//! - `pub fn eventReference(self: *Run, e: Ast.ExprId) Error!?u32`
//! - `pub fn selectTerm(self: *Run, e: Ast.ExprId) Error!?SelectTerm`
//! AST -> bytecode: one process body or driver expression, in its instance
//! scope, -> `Instruction` rows in `Run.code`, each expression's type in
//! `Run.types`, and the static slot lists drivers and `@*` wait on; or E1100
//! before any process has run.
//! Clauses: IEEE 1364-2005 §4.8.1, §5.1.1, §5.1.14, §5.2.1/§5.2.2, §5.5.1
//! Table 5-22, §5.10.4, §6.1, §8.5.3.3/§8.5.3.4, §9.3, §9.5, §9.6, §9.7.1 to
//! §9.7.7, §9.8.2, §10.2.2/§10.2.3, §10.4.4/§10.4.5, §12.7, §17.1 to §17.11,
//! §20.4, A.6.5; VAMS §7.3.6.3 analog probes, §9.14 Table 9-11 `$clog2`,
//! §9.22 driver access.
const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const exec = @import("exec.zig");
const evaluate = @import("evaluate.zig");
const deep = @import("base").deep_stack;
const display = @import("display.zig");
const driver = @import("driver.zig");
const system = @import("system.zig");
const elab = @import("elab.zig");
const evcd = @import("evcd.zig");
const vcd = @import("vcd.zig");
const root = @import("root.zig");
const Error = root.Error;
const Run = root.Run;
const SpecExpr = root.SpecExpr;
const expectRun = root.expectRun;
const expectRejected = root.expectRejected;
const filled = @import("net.zig").filled;
const compile_stmt = @import("compile_stmt.zig");
const constness = @import("constness.zig");
const expr_types = @import("expr_types.zig");
const append = compile_stmt.append;
const checkExpr = expr_types.checkExpr;
const constantExpression = constness.constantExpression;
const typeOf = expr_types.typeOf;
const watcher = compile_stmt.watcher;

/// An event term that is a constant select of a vector: its bits
/// `[first, first + count)` of `slot`, at most 64 and all in range.
const SelectTerm = struct { slot: u32, first: u32, count: u32 };

/// Appends to `out`, once each, the slots `e` reads: §6.1 "a continuous
/// assignment is evaluated whenever an operand changes". They resolve at
/// compile time, like an event term, so a resumption cannot fail mid-dispatch.
/// An array element operand lists every element of its array. `out`'s items
/// are in `self.arena`.
pub fn sensitivity(self: *Run, e: Ast.ExprId, out: *std.ArrayList(u32)) Error!void {
    assert(e != .none);
    // ponytail: an array element operand watches every element of its array;
    // a per-array wake list if a big memory ever feeds one.
    return sensitivityProbes(self, e, out, null);
}

/// Whether `e` is a VAMS §7.3.3 probe terminal the mixed-signal kernel reads:
/// a simple or a §6.7.1 hierarchical name of a net or a named branch.
pub fn probeTerminal(ex: *const Ast.ExprStore, e: Ast.ExprId) bool {
    return ex.tag(e) == .ident or ex.tag(e) == .hier_ident;
}

/// Probe terminal `e` as the analog solution names it: a hierarchical
/// name's parts joined by `.` (`Lowered.discrete_probes`' keys), in `a`.
pub fn probeName(self: *const Run, a: std.mem.Allocator, e: Ast.ExprId) Error![]const u8 {
    assert(e != .none);
    const ex = &self.file.exprs;
    if (ex.tag(e) == .ident) return self.file.str(ex.strOf(e));
    const ids = ex.nameParts(e);
    const parts = try a.alloc([]const u8, ids.len);
    for (ids, parts) |id, *p| p.* = self.file.str(id);
    return std.mem.join(a, ".", parts);
}

/// `sensitivity`, where each VAMS §7.3.6.3 analog probe is appended to
/// `probes` instead of being refused. A probe reads the analog solution,
/// which no slot holds, so nothing here can wake on it; only `$monitor` has
/// another trigger (its probes are compared at every time step and analog
/// solution, `Run.monitor_probes`). Elsewhere (a continuous assignment,
/// `@*`) a probe would be read once and never again, so it is refused by
/// name rather than silently frozen.
pub fn sensitivityProbes(self: *Run, e: Ast.ExprId, out: *std.ArrayList(u32), probes: ?*std.ArrayList(Ast.ExprId)) Error!void {
    assert(e != .none);
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .int_literal, .logic_literal, .str_literal, .real_literal => {},
        .ident, .hier_ident => try watch(self, try self.slot(e), out),
        .index => {
            // An array element watches every element, since the one an index
            // names is known only when it is read; a vector select its vector.
            if (try self.indexedArray(e)) |arr| {
                const base = try self.slot(self.chainBase(e).base);
                // The elements enter `out` together and in order, so the last
                // one there means all are; before them only the first can be,
                // as a bare name (`$fread`'s memory). `watch` element by
                // element was quadratic in the array's size.
                if (std.mem.findScalar(u32, out.items, base + arr.count - 1) == null) {
                    const has_base = std.mem.findScalar(u32, out.items, base) != null;
                    try out.ensureUnusedCapacity(self.arena, arr.count);
                    for (@intFromBool(has_base)..arr.count) |i| out.appendAssumeCapacity(base + @as(u32, @intCast(i)));
                }
                var x = e;
                while (ex.tag(x) == .index) : (x = ex.lhs(x)) try sensitivityProbes(self, ex.rhs(x), out, probes);
            } else {
                try sensitivityProbes(self, ex.lhs(e), out, probes);
                try sensitivityProbes(self, ex.rhs(e), out, probes);
            }
        },
        .unary, .binary, .multi_concat, .ternary, .sys_call, .concat, .range, .indexed_range, .call => {
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| if (c != .none) try sensitivityProbes(self, c, out, probes);
        },
        .branch_access => if (probes) |p| {
            try p.append(self.arena, e);
        } else return self.exprFail(e, "VAMS §7.3.6.3: an analog probe is re-read here only when this process runs, never when the analog solution changes; read it in a procedural statement or `$monitor`"),
        else => unreachable, // else: checkExpr admitted only the forms above
    }
}

/// §9.7.5's implicit event expression: every net and variable the statement
/// reads. An assignment target is written, not read, but its subscripts are
/// read. Requires `compileStmt` to have accepted the statement, so every
/// expression in it is type-checked.
pub fn readSlots(self: *Run, id: Ast.StmtId, out: *std.ArrayList(u32)) Error!void {
    if (id == .none) return;
    if (deep.exhausted()) return self.deepFail(self.file.stmtTok(id));
    const ex = &self.file.exprs;
    switch (self.file.stmt(id)) {
        .block => |b| for (b.body) |s| try readSlots(self, s, out),
        .if_stmt => |s| {
            try sensitivity(self, s.cond, out);
            try readSlots(self, s.then_s, out);
            try readSlots(self, s.else_s, out);
        },
        .while_stmt => |s| {
            try sensitivity(self, s.cond, out);
            try readSlots(self, s.body, out);
        },
        .for_stmt => |s| {
            try sensitivity(self, s.cond, out);
            for ([_]Ast.StmtId{ s.init, s.body, s.step }) |part| try readSlots(self, part, out);
        },
        .repeat_stmt => |s| {
            try sensitivity(self, s.count, out);
            try readSlots(self, s.body, out);
        },
        .case_stmt => |s| {
            try sensitivity(self, s.scrutinee, out);
            for (s.arms) |arm| {
                for (arm.labels) |label| try sensitivity(self, label, out);
                try readSlots(self, arm.body, out);
            }
        },
        .assign => |s| {
            if (s.value != .none) try sensitivity(self, s.value, out); // `deassign`/`release` read nothing
            try targetReads(self, s.target, out);
        },
        .sys_task => |s| for (s.args) |a| {
            if (a != .none and ex.tag(a) != .str_literal) try sensitivity(self, a, out);
        },
        // These read nothing. A nested `@` or `#` inside `@*` suspends on
        // its own terms; §9.7.5 takes the list from the reads either way.
        .empty, .disable => {},
        .event_trigger => |s| try targetReads(self, s.target, out),
        .event_control => |s| try readSlots(self, s.body, out),
        else => unreachable, // else: compileStmt admitted only the forms above
    }
}

pub fn watch(self: *Run, at: u32, out: *std.ArrayList(u32)) Error!void {
    if (std.mem.findScalar(u32, out.items, at) != null) return;
    try out.append(self.arena, at);
}

/// §6.2.2/§6.1: a net is driven by a continuous assignment and a variable by
/// a procedural one; neither accepts the other's form.
pub fn checkTarget(self: *Run, e: Ast.ExprId) Error!void {
    assert(e != .none);
    const ex = &self.file.exprs;
    // §9.2 "a concatenation or nested concatenation of any of the above".
    if (ex.tag(e) == .concat) {
        for (ex.args(e)) |x| {
            try checkTarget(self, x);
            if ((try evaluate.targetType(self, x)).real) return self.exprFail(x, "§4.8: a real cannot be a concatenation operand");
        }
        return;
    }
    const net_refused = "a net is driven by a continuous assignment; there is no procedural assignment to a net";
    if (try self.indexedArray(e) != null) {
        const base = try self.slot(self.chainBase(e).base);
        if (self.events.contains(base)) return self.exprFail(e, "§9.7.3: a named event holds no data; it cannot be assigned");
        // §4.9.1 an element of a net array is a net.
        if (self.net_of.contains(base)) return self.exprFail(e, net_refused);
        var x = e;
        while (ex.tag(x) == .index) : (x = ex.lhs(x)) {
            try checkExpr(self, ex.rhs(x));
            if (typeOf(self, ex.rhs(x)).real) return self.exprFail(ex.rhs(x), "§4.8.1: a real is not an array index");
        }
        return;
    }
    // §5.2.1 a bit- or part-select of a variable writes those bits only;
    // typing it as a read folds its bounds and checks its index.
    if (ex.tag(e) == .index) try checkExpr(self, e);
    const at = try self.baseSlot(e);
    if (self.net_of.contains(at)) return self.exprFail(e, net_refused);
    if (self.params.contains(at)) return self.exprFail(e, "§12.2: a parameter is a constant; it cannot be assigned");
    if (self.events.contains(at)) return self.exprFail(e, "§9.7.3: a named event holds no data; it cannot be assigned");
}

/// Does intra-assignment control `s` leave its `.sample` only parking the
/// value, the wait compiled after it: a `repeat` count, or an event control
/// on a nonblocking assignment (§9.7.7)?
pub fn parksOnly(s: @FieldType(Ast.Stmt, "assign")) bool {
    return !s.timing_is_delay and (s.nonblocking or s.timing_repeat != .none or s.timing_implicit);
}

/// Whether assignment `s` carries an A.6.2 intra-assignment timing control.
pub fn intraTimed(s: @FieldType(Ast.Stmt, "assign")) bool {
    return s.timing != .none or s.timing_implicit;
}

/// The wait of intra-assignment event control on assignment `id`: its event
/// expression, or for `@*` (`timing_implicit`) the slots the assignment reads,
/// IEEE 1364-2005 §9.7.5's list as `event_control`'s `@*` builds it from a
/// statement.
pub fn waitIntra(self: *Run, id: Ast.StmtId, s: @FieldType(Ast.Stmt, "assign")) Error!void {
    if (!s.timing_implicit) {
        _ = try append(self, .{ .wait_event = s.timing });
        return;
    }
    var watched: std.ArrayList(u32) = .empty;
    try readSlots(self, id, &watched);
    _ = try append(self, .{ .wait_slots = watched.items });
}

/// §10.2.3: an automatic task's variables "shall not be assigned values
/// using nonblocking assignments or procedural continuous assignments" and
/// "shall not be traced with system tasks such as $monitor". `e` is the
/// target, or a traced argument.
pub fn notAutomatic(self: *Run, e: Ast.ExprId, comptime what: []const u8) Error!void {
    assert(e != .none);
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .concat => for (ex.args(e)) |x| try notAutomatic(self, x, what),
        .ident, .hier_ident, .index => if (self.auto_slots.contains(try self.slot(self.chainBase(e).base)))
            return self.exprFail(e, "§10.2.3: " ++ what ++ " cannot name a variable of an automatic task or function"),
        else => {}, // else: an expression names no storage to outlive the activation, its operands are read now
    }
}

/// The §10.2.3 checks a timed automatic task's body gets when compiled, for
/// one that is inlined only where enabled: what a nonblocking assignment
/// writes or waits on, and a procedural continuous assignment's target and
/// value, in the scope `scope` its names resolve in.
pub fn deferredReads(self: *Run, scope: u32, s: Ast.StmtId) Error!void {
    assert(scope < self.scope_info.items.len);
    if (s == .none) return;
    const W = struct {
        r: *Run,
        scope: u32,
        pub fn expr(_: @This(), _: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {}
        pub fn stmt(w: @This(), c: Ast.StmtId) Error!void {
            try deferredReads(w.r, w.scope, c);
        }
    };
    const saved = self.scope;
    defer self.scope = saved;
    self.scope = scope;
    switch (self.file.stmt(s)) {
        .block => self.scope = self.block_scopes.get(.{ .scope = scope, .stmt = s }) orelse scope,
        .assign => |a| if (a.continuous != .none) {
            try notAutomatic(self, a.target, "a procedural continuous assignment");
            try readsNoAutomatic(self, a.value, "a procedural continuous assignment");
        } else if (a.nonblocking) {
            try notAutomatic(self, a.target, "a nonblocking assignment");
            if (!a.timing_is_delay) try readsNoAutomatic(self, a.timing, "a nonblocking assignment's event control");
        },
        else => {}, // else: no other statement outlives the activation
    }
    try self.file.stmtEdges(s, W{ .r = self, .scope = self.scope });
}

/// §10.2.3 `notAutomatic` for an expression read after the activation may
/// have ended: none of its operands names an automatic variable. A
/// hierarchical name cannot reach one (§10.2.1), so only plain names count.
pub fn readsNoAutomatic(self: *Run, e: Ast.ExprId, comptime what: []const u8) Error!void {
    const ex = &self.file.exprs;
    if (e == .none) return;
    if (ex.tag(e) == .ident) {
        if (self.lookup(self.scope, ex.strOf(e))) |at| if (self.auto_slots.contains(at))
            return self.exprFail(e, "§10.2.3: " ++ what ++ " cannot name a variable of an automatic task or function");
        return;
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| try readsNoAutomatic(self, c, what);
}

/// §9.7.1 a delay is a "delay_value", which A.8.3 makes
/// `unsigned_number | real_number | ...`, so `#0.5` is legal. A real delay
/// is rounded to the module's precision at run time (`Scale.realDelay`), not
/// truncated to its unit, so a sub-unit delay keeps its meaning.
pub fn checkDelay(self: *Run, e: Ast.ExprId) Error!void {
    assert(e != .none);
    try checkExpr(self, e);
    if (typeOf(self, e).width > 64) return self.exprFail(e, "delay values wider than 64 bits are not implemented");
}

/// Event terms resolve to watched slots at compile time; an indexed named
/// event also validates each index for selection at an occurrence.
pub fn checkEvent(self: *Run, e: Ast.ExprId) Error!void {
    assert(e != .none);
    const ex = &self.file.exprs;
    if (try eventReference(self, e) != null) return;
    switch (ex.tag(e)) {
        .event_or => {
            try checkEvent(self, ex.lhs(e));
            try checkEvent(self, ex.rhs(e));
        },
        // §4.8.1: real variables are prohibited in "Edge descriptors
        // (posedge, negedge) applied to real variables".
        .event_posedge, .event_negedge => {
            const x = ex.lhs(e);
            if (try eventReference(self, x) != null) return self.exprFail(e, "§9.7.3: a named event has no value for a posedge or negedge");
            if (ex.tag(x) != .ident and ex.tag(x) != .hier_ident) {
                if (try selectTerm(self, x) != null) return;
                try exprTerm(self, x);
            }
            // An `auto_terms` expression is never real.
            if (!self.auto_terms.contains(.{ .scope = self.scope, .e = x }) and self.reals.contains(try self.termSlot(x)))
                return self.exprFail(e, "§4.8.1: posedge and negedge do not apply to a real variable");
        },
        .hier_ident => _ = try self.scalarSlot(e),
        .ident => if (self.events.get(try self.scalarSlot(e))) |decl| if (ex.mainTok(e) < decl.tok)
            return self.exprFail(e, "§9.7.3: a named event is declared before it is used"),
        // VAMS §7.3.5 an analog event in a discrete event control: the
        // mixed-signal kernel monitors it and delivers an A2D event.
        .event_function => try self.registerMonitor(e),
        // VAMS §9.22.5 `driver_update signal`.
        .event_driver_update => try driver.checkUpdate(self, e),
        else => if (try selectTerm(self, e) == null) try exprTerm(self, e), // else: every other term is an expression (A.6.5 `event_expression ::= expression`)
    }
}

/// §9.7.3: a scalar event or exactly one selected array element. Only the
/// indices are value expressions; neither the array nor an event holds data.
pub fn eventReference(self: *Run, e: Ast.ExprId) Error!?u32 {
    assert(e != .none);
    const ex = &self.file.exprs;
    const c = self.chainBase(e);
    if (ex.tag(c.base) != .ident and ex.tag(c.base) != .hier_ident) return null;
    const at = try self.slot(c.base);
    const decl = self.events.get(at) orelse return null;
    if (ex.tag(c.base) == .ident and ex.mainTok(e) < decl.tok) return self.exprFail(e, "§9.7.3: a named event is declared before it is used");
    const dimensions: usize = if (self.arrays.get(at)) |arr| arr.rest.len + 1 else 0;
    if (c.depth != dimensions) return self.exprFail(e, "§9.7.3: a named event array requires one index per dimension");
    var x = e;
    while (ex.tag(x) == .index) : (x = ex.lhs(x)) {
        const i = ex.rhs(x);
        if (ex.tag(i) == .range or ex.tag(i) == .indexed_range) return self.exprFail(i, "§9.7.3: an event array takes an index, not a part-select");
        try checkExpr(self, i);
        if (typeOf(self, i).real) return self.exprFail(i, "§9.7.3: an event array index must be integral");
    }
    return at;
}

/// §9.7.2 a constant bit- or part-select of a whole vector (not an array
/// element, a real or an event) as a term watching those bits of the vector
/// itself, so every update of the vector is tested at once, as a whole-name
/// term is (§11.6.3). Null for any other term, which gets a hidden slot
/// (`exprTerm`).
pub fn selectTerm(self: *Run, e: Ast.ExprId) Error!?SelectTerm {
    assert(e != .none);
    const ex = &self.file.exprs;
    if (ex.tag(e) != .index) return null;
    const v = ex.lhs(e);
    if (ex.tag(v) != .ident and ex.tag(v) != .hier_ident) return null;
    const at = try self.slot(v);
    if (self.arrays.contains(at) or self.events.contains(at) or self.reals.contains(at)) return null;
    const rg = ex.rhs(e);
    switch (ex.tag(rg)) {
        .range => {},
        .indexed_range => if (!constantExpression(self, ex.lhs(rg))) return null,
        else => if (!constantExpression(self, rg)) return null, // else: a bit-select's index
    }
    try checkExpr(self, e);
    const sel = (try evaluate.selection(self, self.arena, e)) orelse return null;
    if (sel.first < 0 or sel.count > 64 or sel.first + sel.count > self.values[at].width) return null;
    return .{ .slot = at, .first = @intCast(sel.first), .count = sel.count };
}

// ---- private ----

/// An element lvalue reads its subscript; `sensitivity` on the whole
/// `.index` would also add the array's own elements.
fn targetReads(self: *Run, target: Ast.ExprId, out: *std.ArrayList(u32)) Error!void {
    assert(target != .none);
    const ex = &self.file.exprs;
    if (ex.tag(target) == .concat) {
        for (ex.args(target)) |arg| try targetReads(self, arg, out);
        return;
    }
    var x = target;
    while (ex.tag(x) == .index) : (x = ex.lhs(x)) try sensitivity(self, ex.rhs(x), out);
}

/// IEEE 1364-2005 §9.7.2: "An implicit event shall be detected on any change
/// in the value of the expression", and not on an operand change that leaves
/// it alone. A hidden slot follows `e`, kept equal to it by an out-of-line
/// process of its own started at time 0, and the term watches that slot.
fn exprTerm(self: *Run, e: Ast.ExprId) Error!void {
    assert(e != .none);
    try checkExpr(self, e);
    if (self.auto_terms.contains(.{ .scope = self.scope, .e = e })) return;
    const ty = typeOf(self, e);
    if (!ty.real and ty.width <= 64) {
        var reads: std.ArrayList(u32) = .empty;
        try sensitivity(self, e, &reads);
        for (reads.items) |at| if (self.auto_slots.contains(at))
            return self.auto_terms.put(self.arena, .{ .scope = self.scope, .e = e }, reads.items);
    }
    const entry = try self.term_slots.getOrPut(self.arena, .{ .scope = self.scope, .e = e });
    if (entry.found_existing) return;
    const g = self.growing.?;
    const at: u32 = @intCast(g.items.len);
    entry.value_ptr.* = at;
    try g.append(self.arena, try filled(self.arena, ty.width, ty.signed, if (ty.real) .zero else .x));
    if (ty.real) try self.reals.put(self.arena, at, {});
    self.values = g.items;
    var watched: std.ArrayList(u32) = .empty;
    try sensitivity(self, e, &watched);
    const start = try watcher(self, .{ .init_var = .{ .slot = at, .value = e } }, watched.items);
    _ = try exec.enqueue(self, .{ .run_process = start }, null, false);
}
