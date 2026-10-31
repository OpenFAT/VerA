//! AST -> bytecode: one process body or driver expression, in its instance
//! scope, -> `Instruction` rows in `Run.code`, each expression's type in
//! `Run.types`, and the static slot lists drivers and `@*` wait on; or E1100
//! before any process has run.
//! Cites: IEEE 1364-2005 §4.8.1, §5.1.1, §5.1.14, §5.2.1/§5.2.2, §5.5.1
//! Table 5-22, §5.10.4, §6.1, §8.5.3.3/§8.5.3.4, §9.3, §9.5, §9.6, §9.7.1 to
//! §9.7.7, §9.8.2, §10.2.2/§10.2.3, §10.4.4/§10.4.5, §12.7, §17.1 to §17.11,
//! §20.4, A.6.5; VAMS §7.3.6.3 analog probes, §9.14 Table 9-11 `$clog2`,
//! §9.22 driver access.
//!
//! The bytecode rows are in bytecode.zig, the system function table in
//! system_functions.zig, expression types in expr_types.zig and constness.zig, statements
//! in compile_stmt.zig and compile_holds.zig, sensitivity in sensitivity.zig;
//! this file compiles subroutines and re-exports every name the interpreter and
//! the emitter read as `compile.<name>`.
//!
//! Contents:
//! - `pub const Type`
//! - `pub const real_type`
//! - `pub const Instruction`
//! - `pub const SysFn`
//! - `pub const constantExpression`
//! - `pub const attributeConstantExpression`
//! - `pub const checkAttributes`
//! - `pub const constantFunction`
//! - `pub const notConstant`
//! - `pub const literalWidth`
//! - `pub const stringWidth`
//! - `pub const common`
//! - `pub const typeOf`
//! - `pub const checkExpr`
//! - `pub const append`
//! - `pub const compileStmt`
//! - `pub const Slice`
//! - `pub const Bits`
//! - `pub const sensitivity`
//! - `pub const probeName`
//! - `pub const sensitivityProbes`
//! - `pub const parksOnly`
//! - `pub const eventReference`
//! - `pub const selectTerm`
//! - `pub fn compileSubs(self: *Run) Error!void`
//! - `pub fn compileSub(self: *Run, idx: u32) Error!void`
//! - `pub fn subIn(self: *const Run, scope: u32, name: Ast.StrId) ?u32`
//! - `pub fn checkArgs(self: *Run, decl: *const Ast.Subroutine, args: []const Ast.ExprId, tok: u32) Error!void`
//! - `pub fn enabledTask(self: *Run, scope: u32, name: Ast.StrId, tok: u32, comptime report: bool) Error!?u32`
//! - `pub fn element(self: *const Run, parent: u32, name: Ast.StrId, v: i64) ?u32`
//! - `pub fn compileEnable(self: *Run, name: Ast.StrId, args: []const Ast.ExprId, tok: u32, depth: u32) Error!void`
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
const bytecode = @import("bytecode.zig");
const compile_holds = @import("compile_holds.zig");
const compile_stmt = @import("compile_stmt.zig");
const constness = @import("constness.zig");
const expr_types = @import("expr_types.zig");
const system_functions = @import("system_functions.zig");
const wait_lists = @import("wait_lists.zig");
const checkTarget = wait_lists.checkTarget;
const deferredReads = wait_lists.deferredReads;
const intraTimed = wait_lists.intraTimed;
const position = compile_stmt.position;

/// `bytecode.Type`.
pub const Type = bytecode.Type;

/// `bytecode.real_type`.
pub const real_type = bytecode.real_type;

/// `bytecode.Instruction`.
pub const Instruction = bytecode.Instruction;

/// `system_functions.SysFn`.
pub const SysFn = system_functions.SysFn;

/// `constness.constantExpression`.
pub const constantExpression = constness.constantExpression;

/// `constness.attributeConstantExpression`.
pub const attributeConstantExpression = constness.attributeConstantExpression;

/// `constness.checkAttributes`.
pub const checkAttributes = constness.checkAttributes;

/// `constness.constantFunction`.
pub const constantFunction = constness.constantFunction;

/// `constness.notConstant`.
pub const notConstant = constness.notConstant;

/// `expr_types.literalWidth`.
pub const literalWidth = expr_types.literalWidth;

/// `expr_types.stringWidth`.
pub const stringWidth = expr_types.stringWidth;

/// `expr_types.common`.
pub const common = expr_types.common;

/// `expr_types.typeOf`.
pub const typeOf = expr_types.typeOf;

/// `expr_types.checkExpr`.
pub const checkExpr = expr_types.checkExpr;

/// `compile_stmt.append`.
pub const append = compile_stmt.append;

/// `compile_stmt.compileStmt`.
pub const compileStmt = compile_stmt.compileStmt;

/// `compile_holds.Slice`.
pub const Slice = compile_holds.Slice;

/// `compile_holds.Bits`.
pub const Bits = compile_holds.Bits;

/// `wait_lists.sensitivity`.
pub const sensitivity = wait_lists.sensitivity;

/// `wait_lists.probeName`.
pub const probeName = wait_lists.probeName;

/// `wait_lists.sensitivityProbes`.
pub const sensitivityProbes = wait_lists.sensitivityProbes;

/// `wait_lists.parksOnly`.
pub const parksOnly = wait_lists.parksOnly;

/// `wait_lists.eventReference`.
pub const eventReference = wait_lists.eventReference;

/// `wait_lists.selectTerm`.
pub const selectTerm = wait_lists.selectTerm;

/// Compiles every subroutine that runs synchronously into a body of its own,
/// entered by `.call`: every function, and every task with no timing control
/// (§10.2.1 allows one in a task; §10.4.4 forbids it in a function).
pub fn compileSubs(self: *Run) Error!void {
    // A §10.4.5 constant function call during elaboration compiled its
    // callee already; a second body would register its named blocks twice.
    for (0..self.subs.items.len) |i| if (!self.subs.items[i].compiled) try compileSub(self, @intCast(i));
}

/// Subroutine `idx`'s body at a pc range of its own, unless it is a timed
/// task, which is inlined where it is enabled.
pub fn compileSub(self: *Run, idx: u32) Error!void {
    if (try timed(self, idx)) {
        // §10.2.3 holds whether or not the task is ever enabled.
        const sub = self.subs.items[idx];
        if (sub.decl.automatic) try deferredReads(self, sub.frame.scope, sub.decl.body);
        return;
    }
    const sub = &self.subs.items[idx];
    self.scope = sub.frame.scope;
    self.in_function = sub.decl.is_function;
    defer self.in_function = false;
    sub.entry = position(self);
    sub.compiled = true;
    try compileStmt(self, sub.decl.body, 0);
    _ = try append(self, .stop);
}

/// The task or function `name` names from `scope`: §12.4's generate blocks
/// declare their own (A.1.4), searched before the instance's, then, past
/// the instance, the instances that enclose it. IEEE 1364-2005 §12.7: "if
/// the item is a task, function, named block, or generate block, it
/// continues to search higher level modules until found" (ivtest
/// sv_task_call_instance_lookup: each `child` calls its own parent's task).
pub fn subIn(self: *const Run, scope: u32, name: Ast.StrId) ?u32 {
    var s = scope;
    while (true) : (s = self.scope_info.items[s].parent) {
        if (self.sub_by_name.get(.{ .scope = s, .str = name })) |idx| return idx;
        if (self.prim_names.contains(.{ .scope = s, .str = name })) return null;
        // A root is its own parent (`elaborate`'s other top-level modules).
        if (self.scope_info.items[s].parent == s) return null;
    }
}

/// §10.2.2's argument rules, for an enable and for a call: one argument per
/// formal and none of them null, and an output or inout argument an lvalue
/// the value can be copied back into.
pub fn checkArgs(self: *Run, decl: *const Ast.Subroutine, args: []const Ast.ExprId, tok: u32) Error!void {
    if (args.len != decl.ports.len) return self.fail(tok, "`{s}` takes {d} arguments, not {d}", .{ self.file.str(decl.name), decl.ports.len, args.len });
    const ex = &self.file.exprs;
    for (decl.ports, args) |p, a| {
        if (a == .none) return self.fail(tok, "§10.2.2: null task arguments are not permitted", .{});
        if (p.direction != .input) {
            switch (ex.tag(a)) {
                .ident, .hier_ident, .index, .concat => {},
                else => return self.exprFail(a, "§10.2.2: a task output actual must be a procedural lvalue"), // else: every other form is an expression
            }
            try checkTarget(self, a);
        }
        if (p.direction != .output) try checkExpr(self, a);
    }
}

/// The task an enable of `name` in `scope` names. IEEE 1364-2005 A.6.9
/// `hierarchical_task_identifier`: the parts before the last dot name
/// instances as a §12.5 reference's do, and the task is the last part,
/// declared in the final one. Fails at `tok` when `report`, else is null.
pub fn enabledTask(self: *Run, scope: u32, name: Ast.StrId, tok: u32, comptime report: bool) Error!?u32 {
    const saved = self.scope;
    defer self.scope = saved;
    self.scope = scope;
    const text = self.file.str(name);
    const dot = std.mem.findScalarLast(u8, text, '.') orelse
        return subIn(self, scope, name) orelse if (report) self.fail(tok, "undeclared task `{s}`", .{text}) else null;
    var inst = self.instanceOf(scope);
    var parts = std.mem.splitScalar(u8, text[0..dot], '.');
    var k: usize = 0;
    // §12.4.1 a select a genvar indexes is spelled `g[]` until folded here.
    const indices = self.file.hierIndices(tok);
    var used: usize = 0;
    while (parts.next()) |part| : (k += 1) {
        if (std.mem.endsWith(u8, part, "[]") and std.mem.count(u8, part, "[]") == 1) {
            // Element `v` of the array or loop generate `base`, found by its
            // scope row: `base[v]` is interned only when the source spells it.
            const base = self.file.strings.find(part[0 .. part.len - 2]);
            if (used == indices.len) return self.fail(tok, "§12.5: a hierarchical select has no index", .{});
            const v = (try self.constant(indices[used], tok)).asInt() orelse return self.fail(tok, "§12.5: a hierarchical select's index has an x or z bit", .{});
            used += 1;
            // The first part is found upward from `scope`, as `upward` does.
            var from = if (k == 0) scope else inst;
            var found: ?u32 = null;
            while (base) |b| {
                found = element(self, from, b, v);
                if (found != null or k != 0 or from == 0) break;
                from = self.scope_info.items[from].parent;
            }
            inst = found orelse return if (report) self.fail(tok, "§12.5: `{s}`: an instance select out of range, or of no array", .{part}) else null;
            continue;
        }
        const str = if (std.mem.find(u8, part, "[]") != null) try self.foldSelects(tok, part, indices, &used) else self.file.strings.find(part);
        inst = (if (str) |n| (if (k == 0) self.upward(n) else self.instances.get(.{ .scope = inst, .str = n })) else null) orelse
            return if (report) self.fail(tok, "undeclared instance `{s}` in a hierarchical task name", .{part}) else null;
    }
    const leaf = self.file.strings.find(text[dot + 1 ..]);
    return (if (leaf) |l| self.sub_by_name.get(.{ .scope = inst, .str = l }) else null) orelse
        if (report) self.fail(tok, "undeclared task `{s}`", .{text}) else null;
}

/// The scope of element `v` of instance array or loop generate `name`
/// directly under `parent`, or null.
pub fn element(self: *const Run, parent: u32, name: Ast.StrId, v: i64) ?u32 {
    for (self.scope_info.items, 0..) |info, at| {
        if (at != parent and info.parent == parent and info.name == name and info.index == v) return @intCast(at);
    }
    return null;
}

/// §10.2.2 a task enable. An untimed task is one `.call`; a timed one is
/// inlined here (copy in, the body in the task's frame, copy out), so its
/// suspensions are this process's own. A static task shares one frame
/// between every such copy (§10.2.3); an automatic one gets a frame per call
/// site, which is per activation because a site cannot be re-entered while
/// its process is suspended inside it.
pub fn compileEnable(self: *Run, name: Ast.StrId, args: []const Ast.ExprId, tok: u32, depth: u32) Error!void {
    if (self.in_function) return self.fail(tok, "§10.4.4: a function cannot enable a task", .{});
    const idx = (try enabledTask(self, self.scope, name, tok, true)).?;
    const decl = self.subs.items[idx].decl;
    if (decl.is_function) return self.fail(tok, "§10.4: a function is called in an expression, not enabled", .{});
    try checkArgs(self, decl, args, tok);
    if (!try timed(self, idx)) {
        _ = try append(self, .{ .call = .{ .sub = idx, .args = args, .tok = tok } });
        return;
    }
    // A timed task reaching itself would inline forever: that enable, and
    // every later one inside the body, is an activation of one out-of-line
    // copy instead, with a frame per activation (§10.2.3).
    if (self.subs.items[idx].inlining) {
        try outOfLine(self, idx, depth);
        _ = try append(self, .{ .call_timed = .{ .sub = idx, .args = args } });
        return;
    }
    self.subs.items[idx].inlining = true;
    defer self.subs.items[idx].inlining = false;
    const f = if (decl.automatic) try elab.frame(self, decl, self.subs.items[idx].inst) else self.subs.items[idx].frame;
    const start = position(self);
    for (decl.ports, args, f.ports) |p, a, slot| if (p.direction != .output) {
        _ = try append(self, .{ .init_var = .{ .slot = slot, .value = a } });
    };
    const caller = self.scope;
    self.scope = f.scope;
    try compileStmt(self, decl.body, depth + 1);
    self.scope = caller;
    for (decl.ports, args, f.ports) |p, a, slot| if (p.direction != .input) {
        _ = try append(self, .{ .copy_out = .{ .target = a, .slot = slot } });
    };
    try self.subs.items[idx].ranges.append(self.arena, .{ .start = start, .end = position(self) });
}

// ---- private ----

/// Task `idx`'s body compiled once, jumped over where it is emitted, for
/// `.call_timed`. An automatic task gets a frame of its own, which each
/// activation fills in turn; a static one shares its one frame (§10.2.3).
fn outOfLine(self: *Run, idx: u32, depth: u32) Error!void {
    // ponytail: `disable` of the task stops its inlined copies, not these
    // activations; and `repeat` counters and intra-assignment cells are per
    // site, so a body that suspends inside one of them across its own
    // recursion shares it.
    if (self.subs.items[idx].body != null) return;
    const decl = self.subs.items[idx].decl;
    const f = if (decl.automatic) try elab.frame(self, decl, self.subs.items[idx].inst) else self.subs.items[idx].frame;
    const skip = try append(self, .{ .jump = 0 });
    self.subs.items[idx].body = .{ .entry = position(self), .frame = f };
    const caller = self.scope;
    self.scope = f.scope;
    try compileStmt(self, decl.body, depth + 1);
    _ = try append(self, .{ .task_return = idx });
    self.scope = caller;
    self.code.items[skip].jump = position(self);
}

/// Does task `idx` contain a timing control, directly or through a task it
/// enables? Such a task can suspend, so it is inlined where it is enabled.
/// A recursive enable is taken as untimed while it is being asked about.
fn timed(self: *Run, idx: u32) Error!bool {
    const sub = &self.subs.items[idx];
    if (sub.timed) |t| return t;
    sub.timed = false;
    const t = !sub.decl.is_function and try stmtTimed(self, sub.inst, sub.decl.body);
    self.subs.items[idx].timed = t;
    return t;
}

fn stmtTimed(self: *Run, inst: u32, id: Ast.StmtId) Error!bool {
    if (id == .none) return false;
    return switch (self.file.stmt(id)) {
        .event_control => true,
        .assign => |s| intraTimed(s),
        // §9.8.2: the parent waits at the join for arms that run as
        // processes of their own, which only a process can do; a task with a
        // fork is inlined into its caller like one with a timing control.
        .block => |b| if (b.parallel) true else for (b.body) |s| {
            if (try stmtTimed(self, inst, s)) break true;
        } else false,
        .if_stmt => |s| try stmtTimed(self, inst, s.then_s) or try stmtTimed(self, inst, s.else_s),
        .while_stmt => |s| try stmtTimed(self, inst, s.body),
        .repeat_stmt => |s| try stmtTimed(self, inst, s.body),
        .for_stmt => |s| try stmtTimed(self, inst, s.body),
        .case_stmt => |s| for (s.arms) |arm| {
            if (try stmtTimed(self, inst, arm.body)) break true;
        } else false,
        .sys_task => |s| blk: {
            if (self.file.str(s.name)[0] == '$') break :blk false;
            const callee = (try enabledTask(self, inst, s.name, self.file.stmtTok(id), false)) orelse break :blk false;
            break :blk try timed(self, callee);
        },
        else => false, // else: no other statement suspends or nests one
    };
}

test "an array element operand wakes a continuous assignment" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module example;
        \\reg [3:0] mem [0:1];
        \\integer i;
        \\wire [3:0] w;
        \\assign w = mem[i];
        \\initial begin
        \\  i = 0; mem[0] = 4'h1; mem[1] = 4'h2;
        \\  #1 $display("%b", w);
        \\  i = 1;
        \\  #1 $display("%b", w);
        \\  mem[1] = 4'h7;
        \\  #1 $display("%b", w);
        \\  $finish(0);
        \\end
        \\endmodule
    , "0001\n0010\n0111\n");
}

test "§12.7 a task name is searched for in the enclosing instances, and a name no root declares is refused" {
    // Oracle: §12.7 "continues to search higher level modules until found"
    // (ivtest sv_task_call_instance_lookup); each root is its own parent, so
    // the search ends at whichever top-level module it reaches (ivtest
    // constfunccall3 hung there).
    try expectRun(
        \\module c; initial t; endmodule
        \\module m; task t; $display("%m"); endtask c u(); endmodule
    , "m.t\n");
    try expectRejected("module a; initial t; endmodule module b; initial t; endmodule", "undeclared task");
}

test "§3.6 a string operand is packed ASCII, right-justified and truncated on the left" {
    try expectRun(
        \\module m;
        \\reg [31:0] w; reg [15:0] n; reg [7:0] e;
        \\initial begin
        \\  w = "AZ"; n = "ABC"; e = "";
        \\  $display("%h %h %h %b", w, n, e, "AB" == 16'h4142);
        \\end
        \\endmodule
    , "0000415a 4243 00 1\n");
}

test "§17.1.1.6 %m names the instance path and the named blocks around it" {
    // The child instance's process runs first (`root.processOrder`).
    try expectRun(
        \\module leaf; initial begin : outer begin : inner $display("%m %l %s%c", "", 8'h21); end end endmodule
        \\module m; leaf u(); initial $display("%M"); endmodule
        // "" is one zero byte, which %s shows as a space (VD-129; iverilog too).
    , "m.u.outer.inner work.leaf  !\nm\n");
}

test "§12.7 a named block's local shadows the module's, and each instance has its own" {
    try expectRun(
        \\module c; integer v; initial begin v = 1; begin : b integer v; v = 5; v = v + 1; $display("%m %0d", v); end $display("%0d", v); end endmodule
        \\module m; c u(); c w(); endmodule
    , "m.u.b 6\n1\nm.w.b 6\n1\n");
}

test "§5.3 a min:typ:max expression reads its typical member everywhere" {
    try expectRun("module m; initial $display(\"%0d\", (1:2:3) * 10 + (3:2:1)); endmodule", "22\n");
}

test "§3.5.1 an unsized constant is at least 32 bits, and a wider one keeps its value" {
    try expectRun("module m; initial $display(\"%0d %0d\", 2147483648, 4294967312); endmodule", "2147483648 4294967312\n");
}

test "§3.8 an attribute value is a constant expression: a parameter is one, a variable is not" {
    try expectRun("module m; parameter P = 2; (* a = P + 1, b *) initial $display(\"ok\"); endmodule", "ok\n");
    try expectRejected("module m; integer N; (* a = N *) initial $display(N); endmodule", "an attribute value must be a constant expression");
    // §12.4.1 a genvar is a constant inside its generate block.
    try expectRun("module m; genvar g; generate for (g = 0; g < 2; g = g + 1) begin : b (* i = g + 5 *) wire w; end endgenerate initial $display(\"ok\"); endmodule", "ok\n");
}

test "§12.4.1 a genvar-indexed hierarchical task enable names the task in that iteration's block" {
    try expectRun(
        \\module m;
        \\  genvar i;
        \\  generate for (i = 0; i < 2; i = i + 1) begin : g
        \\    task t; $display("g%0d", i); endtask
        \\  end endgenerate
        \\  generate for (i = 0; i < 2; i = i + 1) begin : h
        \\    initial #(i) g[i].t;
        \\  end endgenerate
        \\endmodule
    , "g0\ng1\n");
}

test "unsupported source is rejected before any process side effect" {
    try expectRejected("module m; initial $display(\"before\"); initial forever ; endmodule", "error");
    try expectRejected("module m; wire [1:0] a, b; tran(a,b); initial $display(\"before\"); endmodule", "a scalar net or a bit-select of a vector net");
    try expectRejected("module m; reg c; initial @(c[0]) c = 1; endmodule", "no bits to select");
    // §5.10 "events do not hold any data", so neither direction of the
    // event/variable confusion compiles.
    try expectRejected("module m; event e; initial $display(\"%b\", e); endmodule", "holds no data");
    try expectRejected("module m; reg c; initial -> c; endmodule", "triggers a named event");
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=(a+1)+$bogus(1); end endmodule", "expression form");
    try expectRejected("module m; wire [3:0] w; initial w[0]=1; endmodule", "no procedural assignment to a net");
    // Past Table 9-22 and §17.1.1's %c %s %m %l %t %v, a conversion such as
    // `%y` is refused, and the refusal names the table.
    try expectRejected("module m; initial $display(\"%y\",1); endmodule", "Table 9-22");
    // §17.7: a real conversion needs a real, and `$realtime` is the only one.
    // IEEE 1364-2005 §5.1.1 Table 5-3: a real takes no bitwise, modulus or
    // case operator.
    try expectRejected("module m; real a; integer b; initial b = a % 2; endmodule", "does not take a real operand");
    try expectRejected("module m; real a; reg [3:0] b; initial b = a[1]; endmodule", "a real has no bits");
    try expectRejected("module m; reg a; initial a=1; integer a; endmodule", "duplicate digital");
}

test "nested unsupported forms fail preflight even in unselected conditional arms" {
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=1'b1 ? 1'b0 : $bogus(1); end endmodule", "expression form");
    try expectRejected("module m; reg a; initial begin $display(\"before\"); a=1'b0 && $bogus(1); end endmodule", "expression form");
}

test "an expression or statement of any depth: 256, one past the old bound, and 900" {
    // The parser bounds nesting by memory only: past `caller_levels` it runs
    // on `deep_stack` segments (`lib/frontend/parser.zig`).
    for ([_]usize{ 256, 900 }) |n| {
        var source = std.Io.Writer.Allocating.init(std.testing.allocator);
        defer source.deinit();
        try source.writer.writeAll("module m; integer a; initial begin a=0");
        for (0..n) |_| try source.writer.writeAll("+1");
        try source.writer.writeAll("; $display(\"%0d\", a); end endmodule");
        var want: [16]u8 = undefined;
        try expectRun(source.written(), try std.mem.print(&want, "{d}\n", .{n}));
        source.clearRetainingCapacity();
        try source.writer.writeAll("module m; initial ");
        for (0..n) |_| try source.writer.writeAll("if(1) ");
        try source.writer.writeAll("$display(\"deep\"); endmodule");
        try expectRun(source.written(), "deep\n");
    }
}

test "control flow validates unselected bodies and every case label" {
    try expectRejected("module m; initial begin $display(\"before\"); if(0) $bogustask(\"BAD\"); end endmodule", "system task");
    try expectRejected("module m; initial begin $display(\"before\"); case(1) 1:; $bogus(2):; endcase end endmodule", "expression form");
    try expectRejected("module m; initial begin $display(\"before\"); while(0) @(a); end endmodule", "undeclared digital variable");
    try expectRejected("module m; initial case(1) default:; default:; endcase endmodule", "multiple default");
    try expectRejected("module m; initial case(1) endcase endmodule", "at least one item");
}

test "concatenation validates zero replication structure and constant counts" {
    try expectRejected("module m; initial $display(\"%b\",{0{1'b1}}); endmodule", "immediately enclosing concatenation");
    try expectRejected("module m; initial $display(\"%b\",{{{0{1'b1}}},1'b1}); endmodule", "positive-width operand");
    try expectRejected("module m; initial $display(\"%b\",{}); endmodule", "positive-width operand");
    try expectRejected("module m; initial $display(\"%b\",{{0{$bogus(1)}},1'b1}); endmodule", "expression form");
    try expectRejected("module m; integer n; initial begin $display(\"before\"); $display(\"%b\",{n{1'b1}}); end endmodule", "constant expression");
    try expectRejected("module m; initial $display(\"%b\",{-1{1'b1}}); endmodule", "cannot be negative");
    try expectRejected("module m; initial $display(\"%b\",{1'bx{1'b1}}); endmodule", "cannot contain X or Z");
    try expectRejected("module m; initial $display(\"%b\",{1'bz{1'b1}}); endmodule", "cannot contain X or Z");
    try expectRejected("module m; initial $display(\"%b\",{65'h10000000000000000{1'b1}}); endmodule", "count exceeds");
    try expectRejected("module m; initial $display(\"%b\",{32'h80000000{2'b1}}); endmodule", "width exceeds");
}

test "concat unsized boundary and cast arity are explicit" {
    try expectRejected("module m; initial $display(\"%b\",{1'b1,3}); endmodule", "unsized constant numbers");
    try expectRejected("module m; initial $display(\"%b\",{1+2,1'b1}); endmodule", "unsized arithmetic");
    try expectRejected("module m; initial $display(\"%b\",{8'd1+1,1'b1}); endmodule", "unsized arithmetic");
    try expectRejected("module m; initial $display(\"%b\",$signed()); endmodule", "exactly one integral argument");
    try expectRejected("module m; initial $display(\"%b\",$unsigned(1,2)); endmodule", "exactly one integral argument");
    try expectRejected("module m; initial $display(\"%b\",$signed(1.0)); endmodule", "exactly one integral argument");
}

test "§17.10.2 a $value$plusargs format names only the listed conversions, and no query matches" {
    // `vera --run` takes no plusargs, so both queries are §17.10's "no
    // match": an integer 0, and the variable keeps its 5.
    try expectRun(
        \\module m; integer v;
        \\initial begin v = 5; $display("%0d %0d %0d", $test$plusargs("X"), $value$plusargs("N=%0d", v), v); end
        \\endmodule
    , "0 0 5\n");
    try expectRejected("module m; integer v; initial if ($value$plusargs(\"N=%u\", v)) v = 1; endmodule", "a $value$plusargs format is one of");
}

test "§17.3.2 $timeformat takes no arguments or four, units 0 to -15 and a literal suffix" {
    try expectRun("module m; initial begin $timeformat(-15, 0, \"\", 0); $timeformat; $display(\"ok\"); end endmodule", "ok\n");
    try expectRejected("module m; initial $timeformat(-9, 2); endmodule", "no arguments or exactly four");
    try expectRejected("module m; initial $timeformat(1, 0, \"\", 0); endmodule", "range from 0 to -15");
    try expectRejected("module m; initial $timeformat(-16, 0, \"\", 0); endmodule", "range from 0 to -15");
    try expectRejected("module m; initial $timeformat(-9, 0, 5, 0); endmodule", "suffix must be a string literal");
}

test "§17.2.1 an $fopen type is one of Table 17-7's" {
    try expectRejected("module m; integer f; initial f = $fopen(\"x.txt\", \"q\"); endmodule", "Table 17-7");
}

test "§17.9 a distribution takes its own argument count and a variable seed" {
    try expectRun("module m; integer s, i; initial begin s = 7; i = $random(s); i = $random; $display(\"ok\"); end endmodule", "ok\n");
    try expectRejected("module m; integer s, i; initial i = $dist_uniform(s, 1); endmodule", "wrong number of arguments to a §17.9");
    try expectRejected("module m; integer i; initial i = $random(5); endmodule", "§17.9.1: the seed argument");
    try expectRejected("module m; integer s, i; initial i = $dist_normal(s, 1.5, 2); endmodule", "§17.9.2");
}

test "§17.8 and §17.11.2 conversions and math functions take their own argument types and counts" {
    // $rtoi truncates -2.7 toward zero; $itor(3) is 3.0, which %g prints as 3.
    try expectRun("module m; initial $display(\"%0d %g %g\", $rtoi(-2.7), $itor(3), $pow(2.0, 10.0)); endmodule", "-2 3 1024\n");
    // VD-130 (oracle: iverilog's itor_rtoi gold): an argument of the other
    // type converts first; $rtoi keeps the low 32 bits of a larger value.
    try expectRun("module m; initial $display(\"%0d %g %g %0d %0d\", $rtoi(1'bx), $itor(-1.5), $itor(1.0/0.0), $rtoi((33'b1<<32)+1.0), $rtoi(1.0/0.0)); endmodule", "0 -2 0 1 x\n");
    try expectRejected("module m; integer i; initial i = $realtobits(1); endmodule", "$rtoi and $realtobits convert a real");
    try expectRejected("module m; real r; initial r = $bitstoreal(1.5); endmodule", "$rtoi and $realtobits convert a real");
    try expectRejected("module m; real r; initial r = $pow(2.0); endmodule", "wrong number of arguments to a §17.11.2");
    try expectRejected("module m; integer i; initial i = $time(1); endmodule", "$time and $stime take no arguments");
    // §17.7.3 `$realtime` and VAMS §9.10 `$abstime` (#58) take no arguments:
    // one check, one message.
    try expectRejected("module m; real r; initial r = $realtime(1); endmodule", "$realtime and $abstime take no arguments");
    try expectRejected("module m; real r; initial r = $abstime(1); endmodule", "$realtime and $abstime take no arguments");
    try expectRejected("module m; integer i; initial i = $clog2(); endmodule", "$clog2 takes exactly one argument");
    try expectRejected("module m; integer i; initial i = $clog2(2.0); endmodule", "§17.11.1");
}

test "§5.2.1 a part-select names its more significant bit first; bounds and widths are constant integers" {
    // a = 1010_0110: a[3:0] is its low nibble; c[0:3] the four bits from
    // c's left index; a[2:2] the one bit 2.
    try expectRun(
        \\module m; reg [7:0] a; reg [0:7] c;
        \\initial begin a = 8'b1010_0110; c = 8'b1010_0110; $display("%b %b %b", a[3:0], c[0:3], a[2:2]); end
        \\endmodule
    , "0110 1010 1\n");
    try expectRejected("module m; reg [7:0] a; reg [3:0] b; initial b = a[0:3]; endmodule", "names its more significant bit first");
    try expectRejected("module m; reg [0:7] a; reg [3:0] b; initial b = a[3:0]; endmodule", "names its more significant bit first");
    try expectRejected("module m; reg [7:0] a; reg b; initial b = a[1 +: 0]; endmodule", "width is a positive constant");
    try expectRejected("module m; reg [7:0] a; reg b; initial b = a[1.0:0]; endmodule", "a real is not a part-select bound");
    try expectRejected("module m; reg [7:0] a; real r; reg [1:0] b; initial b = a[r +: 2]; endmodule", "a real is not a part-select index");
    try expectRejected("module m; reg [7:0] a; real r; reg b; initial b = a[r]; endmodule", "a real is not a bit-select index");
    try expectRejected("module m; reg [1:0] a[1:0]; real r; initial a[r] = 2'b10; endmodule", "a real is not an array index");
    try expectRejected("module m; reg [1:0] a[1:0], x; real r; initial x = a[r]; endmodule", "a real is not an array index");
}

test "§5.1.1 a real takes no bitwise operator and is no concatenation operand" {
    // !0.0 is 1: the logical operators take a real.
    try expectRun("module m; real r; initial begin r = 0.0; $display(\"%b\", !r); end endmodule", "1\n");
    try expectRejected("module m; real r; initial $display(\"%b\", ~r); endmodule", "does not take a real operand");
    try expectRejected("module m; real r; initial $display(\"%b\", {r, 1'b0}); endmodule", "a real cannot be a concatenation operand");
}

test "§10.2/§10.4 a task is enabled and a function called, each with one argument per formal" {
    // f(2) is 3; t doubles it into x.
    try expectRun(
        \\module m; integer x;
        \\function integer f(input integer a); f = a + 1; endfunction
        \\task t(input integer a, output integer b); b = a * 2; endtask
        \\initial begin t(f(2), x); $display("%0d", x); end
        \\endmodule
    , "6\n");
    try expectRejected("module m; function integer f(input integer a); f = a; endfunction initial f(1); endmodule", "a function is called in an expression, not enabled");
    try expectRejected("module m; integer x; task t(input integer a); x = a; endtask initial x = t(1); endmodule", "a task is enabled as a statement");
    try expectRejected("module m; integer x; task t(input integer a); x = a; endtask initial t(1, 2); endmodule", "`t` takes 1 arguments, not 2");
    try expectRejected("module m; integer x; task t(output integer a); a = 1; endtask initial t(x + 1); endmodule", "a task output actual must be a procedural lvalue");
}

test "§10.4.4 a function body has no timing, nonblocking or procedural continuous assignment, trigger or enable" {
    const tail = " initial y = f(1); endmodule";
    try expectRejected("module m; integer y; function integer f(input integer a); f <= a; endfunction" ++ tail, "cannot contain a nonblocking assignment");
    try expectRejected("module m; integer y; function integer f(input integer a); #1 f = a; endfunction" ++ tail, "cannot contain a time control");
    try expectRejected("module m; integer y; event e; function integer f(input integer a); begin -> e; f = a; end endfunction" ++ tail, "cannot contain an event trigger");
    try expectRejected("module m; integer y; task t; y = 0; endtask function integer f(input integer a); begin t; f = a; end endfunction" ++ tail, "a function cannot enable a task");
    try expectRejected("module m; integer y; reg q; function integer f(input integer a); begin assign q = 1'b1; f = a; end endfunction" ++ tail, "cannot contain a procedural continuous assignment");
}

test "§10.2.3 an automatic variable is neither a nonblocking target nor monitored" {
    try expectRejected("module m; task automatic t; integer k; k <= 1; endtask initial t; endmodule", "a nonblocking assignment cannot name a variable of an automatic task");
    try expectRejected("module m; task automatic t; integer k; $monitor(\"%0d\", k); endtask initial t; endmodule", "$monitor cannot name a variable of an automatic task");
    // A named block's variable inside an automatic task is automatic too
    // (§10.2.1; iverilog's automatic_error3), whether or not the task is called.
    try expectRejected("module m; reg g; task automatic t; begin : b reg l; g <= @(l) 0; end endtask endmodule", "a nonblocking assignment's event control cannot name a variable of an automatic task");
    try expectRejected("module m; task automatic t; begin : b reg l; l <= 0; end endtask initial t; endmodule", "a nonblocking assignment cannot name a variable of an automatic task");
}

test "§9.3 assign takes a variable, force a variable or net; a select is of a net, by constant" {
    try expectRun("module m; wire w; initial begin force w = 1'b1; #1 $display(\"%b\", w); end endmodule", "1\n");
    try expectRejected("module m; wire w; initial assign w = 1'b1; endmodule", "assign/deassign take a variable; a net is forced");
    const refused = "a procedural continuous assignment names one whole variable or net";
    try expectRejected("module m; reg [3:0] r; initial force r[1:0] = 2'b11; endmodule", refused);
    try expectRejected("module m; wire [3:0] w; integer i; initial force w[i] = 1'b1; endmodule", refused);
}

test "§12.2 a parameter is not an assignment target" {
    try expectRejected("module m; parameter P = 1; initial P = 2; endmodule", "a parameter is a constant; it cannot be assigned");
}

test "A.6.9 a hierarchical task name walks instances before the task" {
    try expectRun("module c; task t; $display(\"in\"); endtask endmodule module m; c u(); initial u.t; endmodule", "in\n");
    try expectRejected("module c; task t; $display(\"in\"); endtask endmodule module m; c u(); initial nope.t; endmodule", "undeclared instance `nope` in a hierarchical task name");
}

test "§17 system task argument forms are checked before any process runs" {
    try expectRejected("module m; initial $stop(0, 1); endmodule", "$stop accepts zero or one argument");
    // §17.2.1's file_name may be a reg holding the characters; a real is no string.
    try expectRejected("module m; reg [7:0] mem [0:3]; real f; initial $readmemh(f, mem); endmodule", "the memory file name is a string, not a real");
    try expectRejected("module m; reg [7:0] mem [0:1][0:1]; initial $readmemh(\"x.hex\", mem); endmodule", "load a one-dimensional unpacked array");
    try expectRejected("module m; initial $readmemh(\"x.hex\"); endmodule", "take (file, memory [, start [, finish]])");
    try expectRejected("module m; initial $q_initialize(1, 1, 5); endmodule", "the §17.6 queue tasks take four arguments");
    try expectRejected("module m; integer v, st; initial $q_exam(1, 7, v, st); endmodule", "Table 17-15's codes 1 to 6");
    try expectRejected("module m; initial $fflush(1, 2); endmodule", "$fflush takes at most one descriptor");
    try expectRejected("module m; initial $printtimescale(m, m); endmodule", "$printtimescale takes at most one hierarchical name");
    try expectRejected("module m; initial $fclose(); endmodule", "$fclose takes one descriptor");
    try expectRejected("module m; initial $sdf_annotate(); endmodule", "$sdf_annotate takes the SDF file name");
    try expectRejected("module m; initial $sdf_annotate(\"x.sdf\"); endmodule", "x.sdf: the SDF file cannot be read");
}

test "§9.7.3 a named event is waited on whole, declared first, and has no edge; a real has no edge" {
    try expectRejected("module m; event e; initial @(posedge e) ; endmodule", "a named event has no value for a posedge or negedge");
    try expectRejected("module m; real r; initial @(posedge r) ; endmodule", "posedge and negedge do not apply to a real variable");
    try expectRejected("module m; initial @(e) ; event e; endmodule", "a named event is declared before it is used");
    try expectRejected("module m; initial -> nope; endmodule", "undeclared named event");
}

test "a delay wider than 64 bits is refused before any process runs" {
    try expectRejected("module m; initial #(65'd1) ; endmodule", "delay values wider than 64 bits");
}

test "§9.6 a repeat count of any width: negative, x or z is zero times; past 64 bits saturates" {
    try expectRun(
        \\module m; integer n;
        \\initial begin
        \\  n = 0; repeat (-1) n = n + 1; $display("%0d", n);
        \\  n = 0; repeat (-65'sd1) n = n + 1; $display("%0d", n);
        \\  n = 0; repeat (65'd2) n = n + 1; $display("%0d", n);
        \\  n = 0; repeat (65'bx) n = n + 1; repeat (70'sbz) n = n + 1; $display("%0d", n);
        \\  repeat (65'h1_0000_0000_0000_0000) begin $display("first"); $finish(0); end
        \\end endmodule
    , "0\n0\n2\n0\nfirst\n");
}

test "§9.7.7 a repeat event control of any width: two occurrences, or none for a count <= 0" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m; reg a, b; event e;
        \\initial begin a = 0; b = 0; #1 -> e; #1 -> e; #1 -> e; end
        \\initial begin a = repeat (65'd2) @(e) 1'b1; $display("a %0t", $time); end
        \\initial begin b = repeat (-65'sd2) @(e) 1'b1; $display("b %0t %b", $time, b); end
        \\endmodule
    , "b 0 1\na 2\n");
}

test "§9.8.2 a fork in a task with no timing control joins before the enable returns" {
    // The arm sets x = 1 and the join completes before `x = x + 1`; the
    // enable completes after the task body does, so $display reads 2. A fork
    // that only queued its arms would let $display read 0.
    try expectRun(
        \\module m; integer x;
        \\task t; begin fork x = 1; join x = x + 1; end endtask
        \\initial begin x = 0; t; $display("%0d", x); end
        \\endmodule
    , "2\n");
}

test "§9.8.2 a fork in a function completes inside the call" {
    // §10.4.4 forbids timing in a function, so each arm runs to its end and
    // the join is complete before the next statement: f(4) is 4 + 1.
    try expectRun(
        \\module m; integer y;
        \\function integer f(input integer a); begin fork f = a; join f = f + 1; end endfunction
        \\initial begin y = f(4); $display("%0d", y); end
        \\endmodule
    , "5\n");
}

test "§12.5 a function called by a hierarchical name in its generate block" {
    // Oracle: iverilog -g2005 prints `2 3` (ivtest pr2350934's form).
    try expectRun(
        \\module m;
        \\  parameter p = 2;
        \\  reg [2:0] d;
        \\  generate if (p == 2) begin : blk
        \\    function [2:0] f; input i; f = p + i; endfunction
        \\  end endgenerate
        \\  initial begin d = blk.f(0); $display("%0d %0d", d, blk.f(1)); end
        \\endmodule
    , "2 3\n");
    try expectRejected("module m; initial $display(blk.f(0)); endmodule", "undeclared function");
}
