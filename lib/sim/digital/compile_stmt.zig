//! A statement in its scope in, the `Instruction` rows that run it out (`Run.program.code`).
//! Cites: IEEE 1364-2005 §9.2 to §9.9, §8.5.3.3/§8.5.3.4 intra-assignment timing, §17.
//!
//! Contents:
//! - `pub fn position(self: *Run) u32`
//! - `pub fn append(self: *Run, instruction: Instruction) Error!u32`
//! - `pub fn compileStmt(self: *Run, id: Ast.StmtId, depth: u32) Error!void`
//! - `pub fn watcher(self: *Run, step: Instruction, watched: []const u32) Error!u32`
//! AST -> bytecode: one process body or driver expression, in its instance
//! scope, -> `Instruction` rows in `Run.program.code`, each expression's type in
//! `Run.typing.types`, and the static slot lists drivers and `@*` wait on; or E1100
//! before any process has run.
//! Clauses: IEEE 1364-2005 §4.8.1, §5.1.1, §5.1.14, §5.2.1/§5.2.2, §5.5.1
//! Table 5-22, §5.10.4, §6.1, §8.5.3.3/§8.5.3.4, §9.3, §9.5, §9.6, §9.7.1 to
//! §9.7.7, §9.8.2, §10.2.2/§10.2.3, §10.4.4/§10.4.5, §12.7, §17.1 to §17.11,
//! §20.4, A.6.5; VAMS §7.3.6.3 analog probes, §9.14 Table 9-11 `$clog2`,
//! §9.22 driver access.
const std = @import("std");
const assert = std.debug.assert;
const tasks = @import("system_functions.zig").tasks;
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
const compile = @import("compile.zig");
const compile_holds = @import("compile_holds.zig");
const constness = @import("constness.zig");
const expr_types = @import("expr_types.zig");
const system_functions = @import("system_functions.zig");
const wait_lists = @import("wait_lists.zig");
const Instruction = bytecode.Instruction;
const checkDelay = wait_lists.checkDelay;
const checkEvent = wait_lists.checkEvent;
const checkExpr = expr_types.checkExpr;
const checkTarget = wait_lists.checkTarget;
const common = expr_types.common;
const compileEnable = compile.compileEnable;
const compileProcContinuous = compile_holds.compileProcContinuous;
const constantExpression = constness.constantExpression;
const eventReference = wait_lists.eventReference;
const intraTimed = wait_lists.intraTimed;
const notAutomatic = wait_lists.notAutomatic;
const parksOnly = wait_lists.parksOnly;
const readSlots = wait_lists.readSlots;
const readsNoAutomatic = wait_lists.readsNoAutomatic;
const rememberVpiArgument = expr_types.rememberVpiArgument;
const sensitivity = wait_lists.sensitivity;
const typeOf = expr_types.typeOf;
const waitIntra = wait_lists.waitIntra;
const watch = wait_lists.watch;

pub fn position(self: *Run) u32 {
    assert(self.program.code.items.len < std.math.maxInt(u32));
    assert(self.program.scope_of.items.len == self.program.code.items.len); // One scope row per instruction.
    return @intCast(self.program.code.items.len);
}

/// Appends one instruction in the executing scope and returns its pc.
/// Fails at 2^32 - 1 instructions. Invalidates pointers into `Run.program.code`.
pub fn append(self: *Run, instruction: Instruction) Error!u32 {
    if (self.program.code.items.len == std.math.maxInt(u32)) return self.fail(0, "too many digital instructions", .{});
    const at = position(self);
    try self.program.code.append(self.arena, instruction);
    try self.program.scope_of.append(self.arena, self.scope);
    assert(self.program.code.items.len == at + 1);
    assert(self.scope < self.hier.scopes.items.len);
    return at;
}

/// Appends statement `id`'s bytecode, compiled in the executing scope, at
/// the end of `Run.program.code`. `depth` is the statement nesting so far, bounded
/// by the stack `deep.runGuarded` reserved. Every expression is type-checked here,
/// so nothing a process runs can fail to type at run time.
pub fn compileStmt(self: *Run, id: Ast.StmtId, depth: u32) Error!void {
    assert(id != .none);
    const scope = self.scope;
    defer assert(self.scope == scope); // A block's own scope is left on its way out.
    const tok = self.file.stmtTok(id);
    if (deep.exhausted()) return self.deepFail(tok);
    try site(self, id);
    switch (self.file.stmt(id)) {
        .empty => {},
        .block => |b| {
            // IEEE 1364-2005 §12.7: a named block's declarations are a scope
            // of their own, searched before the one around it, so a local
            // shadows a module variable of the same name. The block's name
            // stays in the enclosing scope, where `disable` finds it.
            // Pass one made the scope (`root.blockScopes`), except in an
            // automatic activation's copy, which gets one here.
            // ponytail: `%m` inside such a block names the block but not the
            // named blocks around it.
            const outer = self.scope;
            defer self.scope = outer;
            if (self.hier.block_scopes.get(.{ .scope = outer, .stmt = id })) |inner| {
                self.scope = inner;
            } else if (b.vars.len != 0 or b.params.len != 0 or b.events.len != 0) {
                self.scope = try elab.blockScope(self, outer, id);
            }
            const start = position(self);
            // §9.8.2 in a function: §10.4.4 leaves no arm a timing control,
            // so each runs to its end, and running them one after another,
            // in order, is one execution of the parallel block, joined
            // before the call returns. A queued arm would outlive the call.
            if (b.parallel and !self.routines.in_function) try compileFork(self, b.body, depth) else for (b.body) |s| try compileStmt(self, s, depth + 1);
            self.scope = outer;
            if (b.name != .none) {
                const entry = try self.program.blocks.getOrPut(self.arena, .{ .scope = self.scope, .str = b.name });
                if (entry.found_existing) return self.fail(tok, "duplicate named block", .{});
                // `end` is one past the block, which is the statement
                // execution continues with once the block is terminated.
                entry.value_ptr.* = .{ .start = start, .end = position(self), .depth = depth };
            }
        },
        // A.6.5 `disable_statement`. The range is patched in once every
        // process exists (`Run.program.disables`).
        .disable => |s| {
            const first = position(self);
            const at = try append(self, .{ .disable_block = .{ .start = 0, .end = 0 } });
            try doneSite(self, id, first);
            try self.program.disables.append(self.arena, .{ .at = at, .name = .{ .scope = self.scope, .str = s.name }, .tok = tok });
        },
        .if_stmt => |s| {
            if (s.is_generate) return self.fail(tok, "conditional generate is not implemented", .{});
            try checkExpr(self, s.cond);
            const test_pc = try append(self, .{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
            try compileStmt(self, s.then_s, depth + 1);
            if (s.else_s == .none) {
                self.program.code.items[test_pc].branch.otherwise = position(self);
            } else {
                const end_pc = try append(self, .{ .jump = 0 });
                self.program.code.items[test_pc].branch.otherwise = position(self);
                try compileStmt(self, s.else_s, depth + 1);
                self.program.code.items[end_pc].jump = position(self);
            }
        },
        .while_stmt => |s| {
            try checkExpr(self, s.cond);
            const test_pc = try append(self, .{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
            try compileStmt(self, s.body, depth + 1);
            _ = try append(self, .{ .jump = test_pc });
            self.program.code.items[test_pc].branch.otherwise = position(self);
        },
        .for_stmt => |s| {
            try compileStmt(self, s.init, depth + 1);
            try checkExpr(self, s.cond);
            const test_pc = try append(self, .{ .branch = .{ .condition = s.cond, .otherwise = 0 } });
            try compileStmt(self, s.body, depth + 1);
            try site(self, id);
            try compileStmt(self, s.step, depth + 1);
            _ = try append(self, .{ .jump = test_pc });
            self.program.code.items[test_pc].branch.otherwise = position(self);
        },
        .repeat_stmt => |s| {
            try checkExpr(self, s.count);
            const counter = try repeatCounter(self, tok);
            const test_pc = try append(self, .{ .repeat_start = .{ .count = s.count, .counter = counter, .end = 0 } });
            const body_pc = position(self);
            try compileStmt(self, s.body, depth + 1);
            try site(self, id);
            _ = try append(self, .{ .repeat_next = .{ .counter = counter, .body = body_pc } });
            self.program.code.items[test_pc].repeat_start.end = position(self);
        },
        .case_stmt => |s| {
            if (s.is_generate) return self.fail(tok, "case generate is not implemented", .{});
            if (s.arms.len == 0) return self.fail(tok, "a case statement requires at least one item", .{});
            try checkExpr(self, s.scrutinee);
            var ty = typeOf(self, s.scrutinee);
            var have_default = false;
            for (s.arms) |arm| {
                if (arm.labels.len == 0) {
                    if (have_default) return self.fail(tok, "a case statement cannot have multiple default items", .{});
                    have_default = true;
                }
                for (arm.labels) |label| {
                    try checkExpr(self, label);
                    ty = common(ty, typeOf(self, label));
                }
            }
            if (s.arms.len > std.math.maxInt(u32) - self.program.case_targets.items.len) return self.fail(tok, "too many case targets", .{});
            const targets: u32 = @intCast(self.program.case_targets.items.len);
            try self.program.case_targets.appendNTimes(self.arena, 0, s.arms.len);
            const dispatch = try append(self, .{ .case_select = .{ .statement = id, .targets = targets, .fallback = 0, .ty = ty } });
            const exits = try self.arena.alloc(u32, s.arms.len);
            for (s.arms, 0..) |arm, i| {
                self.program.case_targets.items[targets + i] = position(self);
                if (arm.labels.len == 0) self.program.code.items[dispatch].case_select.fallback = position(self);
                try compileStmt(self, arm.body, depth + 1);
                exits[i] = try append(self, .{ .jump = 0 });
            }
            const end = position(self);
            if (!have_default) self.program.code.items[dispatch].case_select.fallback = end;
            for (exits) |at| self.program.code.items[at].jump = end;
        },
        .assign => |s| if (s.continuous != .none) {
            const first = position(self);
            try compileProcContinuous(self, s.target, s.value, s.continuous, tok);
            try doneSite(self, id, first);
        } else {
            // §10.4.4: "Functions shall not contain any time-controlled
            // statements" and "shall not have any nonblocking assignments".
            if (self.routines.in_function and s.nonblocking) return self.fail(tok, "§10.4.4: a function body cannot contain a nonblocking assignment", .{});
            if (self.routines.in_function and intraTimed(s)) return self.fail(tok, "§10.4.4: a function body cannot contain a time control", .{});
            try checkTarget(self, s.target);
            if (s.nonblocking) try notAutomatic(self, s.target, "a nonblocking assignment");
            // Its event control is waited on after the activation may be gone.
            if (s.nonblocking and !s.timing_is_delay and s.timing != .none) try readsNoAutomatic(self, s.timing, "a nonblocking assignment's event control");
            try checkExpr(self, s.value);
            if (!intraTimed(s)) {
                _ = try append(self, .{ .assign = .{ .target = s.target, .value = s.value, .nonblocking = s.nonblocking } });
                return;
            }
            // A.6.2's intra-assignment `delay_or_event_control`, §8.5.3.3.
            if (s.timing_is_delay) try checkDelay(self, s.timing) else {
                if (!s.timing_implicit) try checkEvent(self, s.timing);
                if (s.timing_repeat != .none) try checkExpr(self, s.timing_repeat);
            }
            if (self.rows.holds.items.len == std.math.maxInt(u32)) return self.fail(tok, "too many intra-assignment timing controls", .{});
            const cell: u32 = @intCast(self.rows.holds.items.len);
            try self.rows.holds.append(self.arena, try filled(self.arena, 1, false, .x));
            _ = try append(self, .{ .sample = .{ .statement = id, .cell = cell } });
            // §8.5.3.4: a nonblocking one with a delay schedules the update
            // and falls through, so it has no resumption point and needs no
            // `deposit`.
            if (s.nonblocking and s.timing_is_delay) return;
            if (!parksOnly(s)) {
                _ = try append(self, .{ .deposit = .{ .statement = id, .cell = cell } });
                return;
            }
            // A nonblocking one with an event control falls through too: a
            // process of its own waits and then queues the update.
            // ponytail: the value is parked per site, so a second sample
            // before the first's event replaces it.
            var skip: ?u32 = null;
            if (s.nonblocking) {
                _ = try append(self, .{ .pla_start = .{ .at = position(self) + 2, .now = true } });
                skip = try append(self, .{ .jump = 0 });
            }
            // §9.7.7 `repeat (n) @(e)`: n occurrences, none when n <= 0.
            if (s.timing_repeat != .none) {
                const counter = try repeatCounter(self, tok);
                const test_pc = try append(self, .{ .repeat_start = .{ .count = s.timing_repeat, .counter = counter, .end = 0 } });
                const body_pc = position(self);
                try waitIntra(self, id, s);
                _ = try append(self, .{ .repeat_next = .{ .counter = counter, .body = body_pc } });
                self.program.code.items[test_pc].repeat_start.end = position(self);
            } else try waitIntra(self, id, s);
            _ = try append(self, .{ .deposit = .{ .statement = id, .cell = cell } });
            if (skip) |at| {
                _ = try append(self, .stop);
                self.program.code.items[at].jump = position(self);
            }
        },
        // A.6.5 `event_trigger`: resolve the declaration here; array
        // indices choose one of its element slots when the trigger runs.
        .event_trigger => |s| {
            if (self.routines.in_function) return self.fail(tok, "§10.4.4: a function body cannot contain an event trigger", .{});
            const base = self.chainBase(s.target).base;
            if (self.file.exprs.tag(base) == .ident and self.lookup(self.scope, self.file.exprs.strOf(base)) == null)
                return self.fail(tok, "undeclared named event", .{});
            const at = (try eventReference(self, s.target)) orelse return self.fail(tok, "§5.10.4: `->` triggers a named event, not a variable or net", .{});
            _ = try append(self, .{ .trigger = if (self.file.exprs.tag(s.target) == .index) .{ .indexed = s.target } else .{ .slot = at } });
        },
        .event_control => |s| {
            if (self.routines.in_function) return self.fail(tok, "§10.4.4: a function body cannot contain a time control", .{});
            // A.6.5 `@*`. The terms come from the body, so the body has to
            // be type-checked before they can be read off it: emit the wait
            // with an empty list, compile the body, then patch the list in.
            if (s.event == .none) {
                const at = try append(self, .{ .wait_slots = .empty });
                try compileStmt(self, s.body, depth + 1);
                var watched: std.ArrayList(u32) = .empty;
                try readSlots(self, s.body, &watched);
                // §9.7.5's list is what the statement reads. One that reads
                // nothing is an empty list, which nothing can trigger: the
                // process suspends forever, as `@` on a never-changing net
                // would. §9.7.5 states no restriction against it.
                self.program.code.items[at].wait_slots = try self.program.addWords(self.arena, watched.items);
                return;
            }
            switch (s.kind) {
                .event => {
                    try checkEvent(self, s.event);
                    _ = try append(self, .{ .wait_event = s.event });
                },
                .delay => {
                    try checkDelay(self, s.event);
                    _ = try append(self, .{ .delay = .{ .amount = s.event, .tok = tok } });
                },
                // A.6.5 `wait_statement`: the condition's operands are the
                // wake-up list, but unlike `@` they only bring the process
                // back to the same pc to re-test the level.
                .level => {
                    try checkExpr(self, s.event);
                    var watched: std.ArrayList(u32) = .empty;
                    try sensitivity(self, s.event, &watched);
                    // IEEE 1364-2005 §9.7.6 tests the level first. An empty
                    // list is legal: true continues, false suspends forever.
                    _ = try append(self, .{ .wait_level = .{ .cond = s.event, .slots = try self.program.addWords(self.arena, watched.items) } });
                },
            }
            try compileStmt(self, s.body, depth + 1);
        },
        .sys_task => |s| {
            const name = self.file.str(s.name);
            if (name[0] != '$') return compileEnable(self, s.name, s.args, tok, depth);
            // IEEE 1364-2005 §20.4, as for a function (`infer`).
            if (self.host.systf) |u| if (u.kind(name)) |k| if (k == .task) {
                for (s.args) |arg| try rememberVpiArgument(self, arg);
                _ = try append(self, .{ .task = .{ .task = .user, .args = try self.program.addExprs(self.arena, s.args), .tok = tok } });
                return;
            };
            // §17.4.2 Syntax 17-12 `$stop [ ( n ) ]`, refused by the runner
            // below either way.
            if (std.mem.eql(u8, name, "$stop") and s.args.len > 1) return self.fail(tok, "$stop accepts zero or one argument", .{});
            if (evcd.tasks.get(name)) |op| {
                try evcd.check(self, op, s.args, tok);
                _ = try append(self, .{ .task = .{ .task = .{ .ports = op }, .args = try self.program.addExprs(self.arena, s.args), .tok = tok } });
                return;
            }
            const task = tasks.get(name) orelse return self.fail(tok, "digital system task `{s}` is not implemented", .{name});
            switch (task) {
                // All three format the same surface, so all three are
                // validated by the same dry run.
                .show, .strobe, .monitor => |sh| {
                    if (task == .monitor) for (s.args) |a| if (a != .none) try notAutomatic(self, a, "$monitor");
                    try display.display(self, s.args, null, sh);
                },
                .monitor_enable => if (s.args.len != 0)
                    return self.fail(tok, "$monitoron and $monitoroff take no arguments", .{}),
                .timeformat => {
                    // §17.3.2 Syntax 17-10: no arguments (Table 17-11's
                    // defaults), or all four. The three numbers are read once
                    // when the task runs, so an expression is legal and a
                    // later change to it is not tracked.
                    const ex = &self.file.exprs;
                    if (s.args.len != 0 and s.args.len != 4) return self.fail(tok, "$timeformat takes no arguments or exactly four", .{});
                    if (s.args.len == 4) {
                        for ([_]Ast.ExprId{ s.args[0], s.args[1], s.args[3] }) |a| {
                            if (a == .none) return self.fail(tok, "$timeformat's units, precision and minimum width are required", .{});
                            try checkExpr(self, a);
                        }
                        if (s.args[2] == .none or ex.tag(s.args[2]) != .str_literal)
                            return self.exprFail(s.args[2], "$timeformat's suffix must be a string literal");
                        // "The units number argument shall be an integer in
                        // the range from 0 to -15" (Table 17-10).
                        if (constantExpression(self, s.args[0])) if ((try self.constant(s.args[0], tok)).asInt()) |u|
                            if (u > 0 or u < -15) return self.exprFail(s.args[0], "§17.3.2: $timeformat's units number shall be in the range from 0 to -15");
                    }
                },
                .readmem => {
                    const ex = &self.file.exprs;
                    if (s.args.len < 2 or s.args.len > 4)
                        return self.fail(tok, "$readmemb/$readmemh take (file, memory [, start [, finish]])", .{});
                    // Syntax 17-7's `" file_name "` is §17.2.1's placeholder,
                    // "a character string or ... a reg containing a character
                    // string": a literal, or an integral expression whose
                    // characters are read when the task runs (pr690, pr704).
                    if (s.args[0] == .none) return self.fail(tok, "§17.2.9 Syntax 17-7: the memory file name is a string", .{});
                    if (ex.tag(s.args[0]) != .str_literal) {
                        try checkExpr(self, s.args[0]);
                        if (typeOf(self, s.args[0]).real) return self.exprFail(s.args[0], "§17.2.9: the memory file name is a string, not a real");
                    }
                    // ponytail: one dimension; §17.2.9's order over several
                    // is the row-major walk, when a source loads one.
                    const arr = if (s.args[1] == .none or ex.tag(s.args[1]) != .ident) null else self.decls.arrays.get(try self.slot(s.args[1]));
                    if (arr == null or arr.?.rest.len != 0)
                        return self.exprFail(s.args[1], "$readmemb/$readmemh load a one-dimensional unpacked array");
                    // Syntax 17-7 prints `" file_name "`, a string literal;
                    // `start_addr`/`finish_addr` are expressions, read when
                    // the task runs ("executed at any time during simulation").
                    for (s.args[2..]) |a| {
                        if (a == .none) return self.fail(tok, "$readmemb/$readmemh take (file, memory [, start [, finish]])", .{});
                        try checkExpr(self, a);
                    }
                },
                // §17.6: four arguments, the last the status; which of the
                // others are written depends on the task.
                .queue => |op| {
                    if (s.args.len != 4) return self.fail(tok, "the §17.6 queue tasks take four arguments", .{});
                    for (s.args, 0..) |a, i| {
                        if (a == .none) return self.fail(tok, "the §17.6 queue tasks take four arguments", .{});
                        const written = i == 3 or (op == .remove and i != 0) or (op == .exam and i == 2);
                        if (written) try checkTarget(self, a) else try checkExpr(self, a);
                    }
                    // §17.6.5 Table 17-15 defines codes 1 to 6; a constant
                    // outside them asks for nothing (VD-050). A run-time one
                    // gets status 2 (`queueStep`).
                    if (op == .exam and constantExpression(self, s.args[1])) if ((try self.constant(s.args[1], tok)).asInt()) |c|
                        if (c < 1 or c > 6) return self.exprFail(s.args[1], "§17.6.5: a $q_exam q_stat_code is one of Table 17-15's codes 1 to 6");
                },
                // §17.5 `(memory, inputs, outputs)`. An asynchronous array is
                // its own process from here on: the loop is compiled out of
                // line, jumped over, and started by `.pla_start`.
                .pla => |p| {
                    if (s.args.len != 3 or s.args[0] == .none or s.args[1] == .none or s.args[2] == .none)
                        return self.fail(tok, "a §17.5 PLA task takes (memory, inputs, outputs)", .{});
                    const ex = &self.file.exprs;
                    const arr = if (ex.tag(s.args[0]) != .ident) null else self.decls.arrays.get(try self.slot(s.args[0]));
                    if (arr == null or arr.?.rest.len != 0) return self.exprFail(s.args[0], "a §17.5 personality is a one-dimensional memory");
                    // §17.5.3: "PLA input terms, output terms, and memory
                    // shall be specified in ascending order".
                    // ponytail: the bit range only; `Array` keeps no word-range direction.
                    const rows = self.vecRange(try self.slot(s.args[0]));
                    if (rows.msb > rows.lsb) return self.exprFail(s.args[0], "§17.5.3: a PLA personality's bit range is ascending, as in reg [1:n]");
                    try checkExpr(self, s.args[1]);
                    try checkTarget(self, s.args[2]);
                    if (p.async_) {
                        var sync = p;
                        sync.async_ = false;
                        var watched: std.ArrayList(u32) = .empty;
                        const base = try self.slot(s.args[0]);
                        for (0..arr.?.count) |i| try watch(self, base + @as(u32, @intCast(i)), &watched);
                        try sensitivity(self, s.args[1], &watched);
                        const loop = try watcher(self, .{ .task = .{ .task = .{ .pla = sync }, .args = try self.program.addExprs(self.arena, s.args), .tok = tok } }, watched.items);
                        _ = try append(self, .{ .pla_start = .{ .at = loop } });
                        return;
                    }
                },
                .dump => |op| try vcd.check(self, op, s.args, tok),
                .ports => unreachable, // `evcd.tasks` is looked up first
                // §17.2.2: the descriptor, then `$display`'s own arguments.
                .fshow => |sh| {
                    if (s.args.len == 0 or s.args[0] == .none) return self.fail(tok, "a §17.2.2 file output task's first argument is a descriptor", .{});
                    try checkExpr(self, s.args[0]);
                    try display.display(self, s.args[1..], null, sh);
                },
                // §17.2.3: the variable, then `$fwrite`'s own arguments; for
                // `$sformat` a format first ("always interprets its second
                // argument ... as a format string").
                .sshow, .sformat => {
                    if (s.args.len == 0 or s.args[0] == .none) return self.fail(tok, "a §17.2.3 string output task's first argument is a variable", .{});
                    try checkTarget(self, s.args[0]);
                    if (task == .sshow) try display.display(self, s.args[1..], null, task.sshow) else {
                        if (s.args.len < 2 or s.args[1] == .none) return self.fail(tok, "$sformat's second argument is its format", .{});
                        try display.sformat(self, s.args[1..], null);
                    }
                },
                // §17.2.10 Syntax 17-8: the file, then up to six optional
                // arguments; the second names a module instance.
                .sdf_annotate => {
                    if (s.args.len == 0 or s.args.len > 7 or s.args[0] == .none) return self.fail(tok, "§17.2.10: $sdf_annotate takes the SDF file name and up to six optional arguments", .{});
                    for (s.args, 0..) |a, i| if (a != .none) {
                        if (i == 1) _ = try display.timescaleScope(self, a) else try checkExpr(self, a);
                    };
                },
                // §17.3.1 Syntax 17-9.
                .printtimescale => {
                    if (s.args.len > 1) return self.fail(tok, "$printtimescale takes at most one hierarchical name", .{});
                    if (s.args.len == 1) _ = try display.timescaleScope(self, s.args[0]);
                },
                .fclose => {
                    if (s.args.len != 1 or s.args[0] == .none) return self.fail(tok, "$fclose takes one descriptor", .{});
                    try checkExpr(self, s.args[0]);
                },
                // §17.2.6 `$fflush ( mcd )`, `( fd )` or `( )`.
                // `tasks` names no application's task; `Run.host.systf` did above.
                .user => unreachable,
                .fflush => {
                    if (s.args.len > 1) return self.fail(tok, "$fflush takes at most one descriptor", .{});
                    for (s.args) |a| if (a != .none) try checkExpr(self, a);
                },
                // §17.4.1: the argument is an expression selecting how much
                // is printed (0, 1 or 2), read when the task runs.
                .finish => |stop| {
                    const task_name = if (stop) "$stop" else "$finish";
                    if (s.args.len > 1) return self.fail(tok, "{s} accepts zero or one argument", .{task_name});
                    if (s.args.len == 1) {
                        if (s.args[0] == .none) return self.fail(tok, "{s}'s argument is an expression", .{task_name});
                        try checkExpr(self, s.args[0]);
                    }
                },
            }
            _ = try append(self, .{ .task = .{ .task = task, .args = try self.program.addExprs(self.arena, s.args), .tok = tok } });
        },
        else => return self.fail(tok, "this digital statement is not implemented", .{}), // else: the analog statements (contribution, indirect, jump), refused out loud
    }
}

/// An out-of-line process that runs `step`, then waits on `watched` and
/// loops; the code around it jumps over it, so it runs only once started.
/// Returns its first pc; it ends at the next `position`.
pub fn watcher(self: *Run, step: Instruction, watched: []const u32) Error!u32 {
    const skip = try append(self, .{ .jump = 0 });
    const start = position(self);
    _ = try append(self, step);
    _ = try append(self, .{ .wait_slots = try self.program.addWords(self.arena, watched) });
    _ = try append(self, .{ .jump = start });
    self.program.code.items[skip].jump = position(self);
    assert(self.program.code.items[skip].jump == start + 3);
    assert(self.program.code.items[start + 1] == .wait_slots);
    return start;
}

// ---- private ----

/// Records that statement `id` is reached at the next instruction
/// (`Run.host.stmt_sites`).
fn site(self: *Run, id: Ast.StmtId) Error!void {
    assert(id != .none);
    const sites = &(self.host.stmt_sites orelse return);
    assert(self.scope < self.hier.scopes.items.len);
    try sites.append(self.arena, .{ .scope = self.instanceOf(self.scope), .stmt = id, .pc = position(self) });
}

/// Records statement `id`, compiled from `first` to the last instruction so
/// far, for `Run.host.done_hook` (`Run.host.done_sites`).
fn doneSite(self: *Run, id: Ast.StmtId, first: u32) Error!void {
    assert(id != .none);
    if (self.host.stmt_sites == null) return;
    assert(first < position(self));
    try self.host.done_sites.put(self.arena, position(self) - 1, .{ .scope = self.instanceOf(self.scope), .stmt = id, .pc = first });
}

/// A new `Run.rows.repeats` counter, for one `repeat` loop or §9.7.7 repeat
/// event control. Fails at 2^32 - 1 counters.
fn repeatCounter(self: *Run, tok: u32) Error!u32 {
    assert(tok < self.starts.len);
    if (self.rows.repeats.items.len == std.math.maxInt(u32)) return self.fail(tok, "too many repeat counters", .{});
    try self.rows.repeats.append(self.arena, 0);
    assert(self.rows.repeats.items.len > 0);
    return @intCast(self.rows.repeats.items.len - 1);
}

/// IEEE 1364-2005 §9.8.2 a parallel block: each statement is compiled as an
/// arm ending in `.join_arm`; `.fork` starts them all and suspends the parent
/// until the last one is back, which resumes it at the end of the block.
fn compileFork(self: *Run, body: []const Ast.StmtId, depth: u32) Error!void {
    assert(self.rows.joins.items.len < std.math.maxInt(u32));
    const join: u32 = @intCast(self.rows.joins.items.len);
    try self.rows.joins.append(self.arena, 0);
    const arms = try self.arena.alloc(u32, body.len);
    // The arm pcs are known only as each arm compiles; the list is filled in
    // `Program.words` after the last one.
    const at = try append(self, .{ .fork = .{ .arms = .empty, .join = join, .end = 0 } });
    const ends = try self.arena.alloc(u32, body.len);
    for (body, arms, ends) |s, *arm, *end| {
        arm.* = position(self);
        try compileStmt(self, s, depth + 1);
        end.* = try append(self, .{ .join_arm = .{ .join = join, .end = 0 } });
    }
    self.program.code.items[at].fork.arms = try self.program.addWords(self.arena, arms);
    self.program.code.items[at].fork.end = position(self);
    for (ends) |e| self.program.code.items[e].join_arm.end = position(self);
    assert(self.program.wordsOf(self.program.code.items[at].fork.arms).len == body.len);
}
