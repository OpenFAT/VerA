//! The statement rows of the AST (LRM ch5, annex A.6) and the walks over
//! them: `Stmt` in, its expression edges and child statements, or the
//! variables it writes (§5.7, §4.7.2.3, §9.5, §9.13), out. Statements live in
//! `SourceFile`'s pool, addressed by `StmtId`.
//!
//! Contents:
//! - `pub const Timing = enum`
//! - `pub const Stmt = union(enum)`: `JumpKind`
//! - `pub const BlockId = enum(u32)`
//! - `pub const StmtRow = row:`
//! - `pub const ProcContinuous = enum(u8)`
//! - `pub const CaseKind = enum(u8)`
//! - `pub const CaseArm = struct`
//! - `pub const GenItems = struct`
//! - `pub const SeqBlock = struct`
//! - `pub const Edge = enum`
//! - `pub fn stmtEdges(self: *const SourceFile, id: StmtId, v: anytype) !void`
//! - `pub fn stmtWrites(self: *const SourceFile, funcs: []const FuncDecl, id: StmtId, gpa: std.mem.Allocator, out: *std.ArrayList(ExprId)) !void`: `expr`, `stmt`
//! - `pub fn lvalueBase(self: *const SourceFile, e: ExprId) ExprId`

const std = @import("std");
const assert = std.debug.assert;
const ast = @import("ast.zig");
const ExprId = ast.ExprId;
const StmtId = ast.StmtId;
const StrId = ast.StrId;
const SourceFile = ast.SourceFile;
const ParamDecl = ast.ParamDecl;
const VarDecl = ast.VarDecl;
const EventDecl = ast.EventDecl;
const Instance = ast.Instance;
const DiscreteBlock = ast.DiscreteBlock;
const ContAssign = ast.ContAssign;
const GateInst = ast.GateInst;
const PullInst = ast.PullInst;
const SwitchInst = ast.SwitchInst;
const Defparam = ast.Defparam;
const NetDecl = ast.NetDecl;
const Subroutine = ast.Subroutine;
const FuncDecl = ast.FuncDecl;

/// Which of A.6.5's three procedural timing controls a prefixed statement
/// carries. All three suspend the process and then run the same body, so they
/// share `Stmt.event_control`; only what they wait for differs.
pub const Timing = enum {
    /// `@(event)`: an edge, a named event, or `@*` (§5.10, §9.7.5).
    event,
    /// `#delay` (`delay_control`); the statement's `event` is the delay.
    delay,
    /// `wait (expression)`, level sensitive: if the expression is already true
    /// the body runs without suspending at all, and a resumption re-tests it
    /// instead of firing on whichever change woke the process.
    level,
};

/// Statement node (LRM §5), the value `SourceFile.stmt` returns. The pool
/// stores each one as a `StmtRow`, with a `.block`'s `SeqBlock` kept in
/// `SourceFile.blocks`; build one and hand it to `SourceFile.addStmt`.
pub const Stmt = union(enum) {
    /// A.6.4 `analog_statement_or_null ::= ... | ;`
    empty,
    /// §5.3.2 named block with local declarations (A.6.3 analog_seq_block).
    block: SeqBlock,
    /// §5.7 procedural assignment (A.6.2 analog_variable_assignment). `target`
    /// is an lvalue *expression* (`.ident` or `.index`) so array element
    /// assignment (§3.2.2) is representable.
    ///
    /// `timing` is A.6.2's optional `delay_or_event_control` between the `=`
    /// and the expression: the intra-assignment form, which §8.5.3.3 gives a
    /// different meaning from the statement prefix `#5 b = a;`: the right-hand
    /// side is sampled when the statement is reached and only the write waits.
    /// `timing_is_delay` picks `delay_control` over `event_control`, as
    /// `event_control.is_delay` does for the prefix form.
    assign: struct {
        target: ExprId,
        value: ExprId,
        nonblocking: bool = false,
        timing: ExprId = .none,
        timing_is_delay: bool = false,
        /// IEEE 1364-2005 §9.7.7 `repeat ( count ) @ ...`: the event control
        /// waits for `count` occurrences; `.none` without `repeat`.
        timing_repeat: ExprId = .none,
        /// A.6.5's `@*` / `@ (*)` as the event control: `timing` is `.none`
        /// and the list is what this assignment reads (IEEE 1364-2005
        /// §9.7.5), as for the statement form `event_control.event = .none`.
        timing_implicit: bool = false,
        /// IEEE 1364-2005 §9.3 procedural continuous assignments, which only
        /// a digital parse makes: `assign`/`force` (with a `value`) and
        /// `deassign`/`release` (whose `value` is `.none`).
        continuous: ProcContinuous = .none,
    },
    /// §5.6 contribution `V(a,b) <+ expr;`. `lhs` is a `.branch_access` or
    /// `.port_access` node (A.8.5 branch_lvalue).
    contribute: struct { lhs: ExprId, rhs: ExprId },
    /// §5.6.7 indirect contribution `V(x) : I(y) == expr;`
    /// (A.6.10 indirect_contribution_statement). Parsed even where lowering
    /// rejects it, so the error names the feature instead of the syntax.
    indirect: struct { lhs: ExprId, probe: ExprId, eqn: ExprId },
    /// §5.8 conditional. `else_s` is `.none` when absent; `else if` chains
    /// nest in `else_s`.
    if_stmt: struct {
        cond: ExprId,
        then_s: StmtId,
        else_s: StmtId,
        /// Syntax 6-8 `if_generate_construct` rather than A.6.6's
        /// `analog_conditional_statement`. One node, because lowering collapses
        /// a constant condition either way; only the generate form carries
        /// §6.6's constant-expression rule (E0428).
        is_generate: bool = false,
    },
    /// §5.8.3 case (A.6.7), and Syntax 6-8 `case_generate_construct` when
    /// `is_generate`. An arm with `labels.len == 0` is `default`.
    case_stmt: struct {
        kind: CaseKind = .normal,
        scrutinee: ExprId,
        arms: []const CaseArm,
        is_generate: bool = false,
    },
    /// §5.9.2 `for (init; cond; step) body`. Also carries the genvar
    /// loop-generate form (A.4.2); lowering decides whether to unroll by
    /// looking the loop variable up in `ModuleDecl.genvars` (§6.6.1).
    for_stmt: struct { init: StmtId, cond: ExprId, step: StmtId, body: StmtId },
    /// §5.9.1 `while (cond) body`.
    while_stmt: struct { cond: ExprId, body: StmtId },
    /// §5.9 `repeat (count) body`.
    repeat_stmt: struct { count: ExprId, body: StmtId },
    /// §5.10 `@(event) body` (A.6.5 analog_event_control_statement). `event` is
    /// one of the `event_*` expression tags, or an `.ident` naming an event.
    ///
    /// `.none` is A.6.5's `@*` / `@ (*)`: the implicit event expression, whose
    /// terms are every net and variable `body` reads. A.6.5 offers it to
    /// `event_control` only, so an analog block rejects it.
    event_control: struct { event: ExprId, body: StmtId, kind: Timing = .event },
    /// §5.10.4 `-> event;` (A.6.5 `event_trigger`): a hierarchical event
    /// identifier followed by one expression index per array dimension.
    event_trigger: struct { target: ExprId },
    /// §5.11 `disable <block>;` (A.6.5 disable_statement).
    disable: struct { name: StrId },
    /// §5.12 / ch9 analog system task: `$strobe`, `$finish`, `$error`,
    /// `$bound_step` (§9.17.1), `$discontinuity` (§9.17.2), `$limit`
    /// (§9.17.3), and so on. `args` may contain `.none` for an omitted argument
    /// (A.6.9 permits empty argument slots).
    sys_task: struct { name: StrId, args: []const ExprId },
    /// A.6.5 jump_statement: `return` (§4.7.1 analog functions), `break`,
    /// `continue`. `value` is `.none` except for `return expr`.
    jump: struct { kind: JumpKind, value: ExprId = .none },

    /// `return`, `break`, `continue`.
    pub const JumpKind = enum(u8) { ret, brk, cont };
};

/// Handle into `SourceFile.blocks`, the §5.3.2 blocks of the statement pool.
pub const BlockId = enum(u32) { _ };

/// The stored form of a `Stmt`: the same arms, except that `.block` holds a
/// `BlockId` into `SourceFile.blocks`. A `SeqBlock` is 104 bytes and every
/// other arm at most 24, so keeping blocks out of the row makes a row 32
/// bytes instead of 112 (8,239 rows on psp103, 1,806 of them blocks).
pub const StmtRow = row: {
    const u = @typeInfo(Stmt).@"union";
    var types = u.field_types[0..u.field_types.len].*;
    types[std.meta.fieldIndex(Stmt, "block").?] = BlockId;
    break :row @Union(.auto, u.tag_type.?, u.field_names, &types, u.field_attrs);
};

// Budget: the widest non-block arm (24 B) plus the tag; `SeqBlock`, the arm
// kept out of the row, is the 104 B `StmtRow`'s doc names.
comptime {
    assert(@sizeOf(StmtRow) <= 32);
    assert(@sizeOf(SeqBlock) <= 104);
}

/// IEEE 1364-2005 §9.3 A.6.2 `procedural_continuous_assignments`.
pub const ProcContinuous = enum(u8) { none, assign, deassign, force, release };

/// §5.8.3 A.6.7 `case`, `casex`, `casez`. Only `.normal` is meaningful for
/// real-valued analog scrutinees; `casex`/`casez` are kept so the parser can
/// accept them and lowering can diagnose them precisely.
pub const CaseKind = enum(u8) { normal, casex, casez };

/// §5.8.3 one case arm. `labels.len == 0` ⇒ `default`.
pub const CaseArm = struct {
    labels: []const ExprId,
    body: StmtId,
};

/// §6.6 the items of a generate block that the scheme brings into existence
/// with it: its named events, processes and drivers, as `ModuleDecl` holds
/// a module's. The digital engine elaborates them in the block's scope.
pub const GenItems = struct {
    events: []const EventDecl = &.{},
    discrete: []const DiscreteBlock = &.{},
    assigns: []const ContAssign = &.{},
    gates: []const GateInst = &.{},
    pulls: []const PullInst = &.{},
    switches: []const SwitchInst = &.{},
    /// IEEE 1364-2005 §12.2.1 defparams, relative to the block instance.
    defparams: []const Defparam = &.{},
    /// IEEE 1364-2005 §12.4 the block's own nets, declared in its scope.
    nets: []const NetDecl = &.{},
    /// IEEE 1364-2005 A.1.5 `module_or_generate_item_declaration`'s task and
    /// function declarations, scoped to the block (§12.4).
    tasks: []const Subroutine = &.{},
};

/// §5.3.2 sequential block body plus its local declarations
/// (A.6.3 analog_seq_block, A.2.8 analog_block_item_declaration).
/// Local declarations are only legal on a named block (§5.3.2).
/// Not `Block`, which is the MIR's CFG basic block.
pub const SeqBlock = struct {
    name: StrId = .none,
    /// A.6.3 `par_block ::= fork … join` (IEEE 1364-2005 §9.8.2): every
    /// statement starts when the block does, and the block ends when the
    /// last one does. Only a digital parse makes one.
    parallel: bool = false,
    params: []const ParamDecl = &.{},
    vars: []const VarDecl = &.{},
    /// IEEE 1364-2005 A.2.8 a named block's `event` declarations; only a
    /// digital parse keeps one.
    events: []const EventDecl = &.{},
    body: []const StmtId = &.{},
    /// A generate block's module instances (§6.6). The digital engine decides a
    /// digital parse's scheme; elaboration gates an analog if-generate's
    /// (`Flatten.genInstances`).
    instances: []const Instance = &.{},
    /// A digital parse's generate block's other items (§6.6). An analog parse
    /// hoists them to the module instead (`parseGenerateBlock`).
    gen: *const GenItems = &.{},
    /// §6.6.3 a generate block's name for external interfaces: its declared
    /// name, or `genblk<n>` for an unnamed one ("n" the number of its generate
    /// construct in the enclosing scope, zero-padded past any clash). `.none`
    /// for every block that is not a generate block, and for the block §6.6.2's
    /// direct nesting does not treat as a scope. Never a name that hierarchical
    /// references resolve through: "an unnamed generate block has no name that
    /// can be used in a hierarchical name".
    gen_name: StrId = .none,
};

/// What an expression edge of a statement is to that statement.
pub const Edge = enum {
    /// Evaluated for its value.
    read,
    /// §5.7 an assignment target (A.6.2 `variable_lvalue`): written.
    write,
    /// §5.6 a contribution's `branch_lvalue` (A.8.5): the branch driven.
    branch,
};

/// One `stmtEdges` callback, as a test records it.
const Visit = union(enum) {
    expr: struct { e: ExprId, edge: Edge },
    stmt: StmtId,
};

/// A `stmtEdges` visitor that records every callback in order.
const Recorder = struct {
    gpa: std.mem.Allocator,
    seen: std.ArrayList(Visit) = .empty,

    pub fn expr(r: *Recorder, e: ExprId, edge: Edge) std.mem.Allocator.Error!void {
        try r.seen.append(r.gpa, .{ .expr = .{ .e = e, .edge = edge } });
    }
    pub fn stmt(r: *Recorder, s: StmtId) std.mem.Allocator.Error!void {
        try r.seen.append(r.gpa, .{ .stmt = s });
    }
};

/// Visits every edge of statement `id`: `v.expr(e, edge)` for each of its own
/// expressions and `v.stmt(s)` for each child statement, in source order,
/// except that an assignment's intra-assignment timing (its `repeat` count,
/// then its event or delay) comes after its value. An `-> event` target is
/// an identity, so only its index expressions are visited. A block's own
/// declarations are not statements and are not visited. `.none` operands and
/// children are passed through. `v` is duck-typed (`expr(ExprId, Edge)` and
/// `stmt(StmtId)`, both returning the same error union); this is the
/// statement counterpart of `ExprStore.children`. Asserts that `id` is not
/// `.none`: a missing child is the caller's to skip.
pub fn stmtEdges(self: *const SourceFile, id: StmtId, v: anytype) !void {
    assert(id != .none);
    switch (self.stmt(id)) {
        .empty, .disable => {},
        .event_trigger => |s| try eventIndexEdges(self, s.target, v),
        .block => |b| for (b.body) |s| try v.stmt(s),
        .assign => |a| {
            try v.expr(a.target, .write);
            try v.expr(a.value, .read);
            // IEEE 1364-2005 §9.7.7: `repeat (count)` precedes its event control.
            try v.expr(a.timing_repeat, .read);
            try v.expr(a.timing, .read);
        },
        .contribute => |c| {
            try v.expr(c.lhs, .branch);
            try v.expr(c.rhs, .read);
        },
        .indirect => |c| {
            try v.expr(c.lhs, .branch);
            try v.expr(c.probe, .read);
            try v.expr(c.eqn, .read);
        },
        .if_stmt => |s| {
            try v.expr(s.cond, .read);
            try v.stmt(s.then_s);
            try v.stmt(s.else_s);
        },
        .case_stmt => |s| {
            try v.expr(s.scrutinee, .read);
            for (s.arms) |arm| {
                for (arm.labels) |l| try v.expr(l, .read);
                try v.stmt(arm.body);
            }
        },
        .for_stmt => |s| {
            try v.stmt(s.init);
            try v.expr(s.cond, .read);
            try v.stmt(s.step);
            try v.stmt(s.body);
        },
        .while_stmt => |s| {
            try v.expr(s.cond, .read);
            try v.stmt(s.body);
        },
        .repeat_stmt => |s| {
            try v.expr(s.count, .read);
            try v.stmt(s.body);
        },
        .event_control => |s| {
            try v.expr(s.event, .read);
            try v.stmt(s.body);
        },
        .sys_task => |s| for (s.args) |a| try v.expr(a, .read),
        .jump => |j| try v.expr(j.value, .read),
    }
}

/// Appends to `out`, in source order, every lvalue statement `id` writes
/// through its own expressions. Child statements are not entered; callers
/// walk them with their own scope rules. `funcs` is the enclosing module's
/// §4.7.1 function list, which decides an actual's direction.
///
/// The ways a statement writes a variable:
///   - §5.7 the assignment target;
///   - §4.7.2.3/§4.7.2.4 an actual bound to an `output` or `inout` formal
///     ("the last value assigned to the output argument is then assigned to
///     the corresponding analog variable reference");
///   - §9.13.1/§9.13.2 the seed of `$random`, `$arandom`, `$dist_*` and
///     `$rdist_*` ("If the random_seed argument is specified it is an inout
///     argument");
///   - §9.5.3/§9.5.4 the destinations of `$sscanf`, `$fscanf`, `$fgets`,
///     `$ferror`, and the string `$swrite`/`$sformat` write into.
/// An array actual written as an A.8.1 assignment pattern (§4.7.2.3 "an
/// array assignment pattern of analog variables") yields its elements.
/// The appended ids are the lvalues as written (`x[i]` stays `x[i]`); see
/// `lvalueBase` for the declaration it names. A `.none` `id` appends nothing.
/// Invalidates `out`'s element pointers if it grows; `out` is grown with `gpa`.
pub fn stmtWrites(self: *const SourceFile, funcs: []const FuncDecl, id: StmtId, gpa: std.mem.Allocator, out: *std.ArrayList(ExprId)) std.mem.Allocator.Error!void {
    if (id == .none) return;
    const out_before = out.items.len;
    defer assert(out.items.len >= out_before);
    if (self.stmt(id) == .sys_task) {
        const s = self.stmt(id).sys_task;
        for (sysWrites(self.str(s.name), s.args)) |w| try addLvalue(self, w, gpa, out);
    }
    const Writes = struct {
        file: *const SourceFile,
        funcs: []const FuncDecl,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(ExprId),
        pub fn expr(w: @This(), e: ExprId, edge: Edge) std.mem.Allocator.Error!void {
            switch (edge) {
                .write => try addLvalue(w.file, e, w.gpa, w.out),
                .read => try exprWrites(w.file, w.funcs, e, w.gpa, w.out),
                // A branch is driven, not a variable written.
                .branch => {},
            }
        }
        pub fn stmt(_: @This(), _: StmtId) std.mem.Allocator.Error!void {}
    };
    try stmtEdges(self, id, Writes{ .file = self, .funcs = funcs, .gpa = gpa, .out = out });
}

/// Returns the declared name an lvalue writes: `x`, `x[i]`, `x[i][j]` and a part
/// select `x[3:0]` (an `.index` whose index is a `.range`) all write the
/// declaration `x`. `.none` when the lvalue is not rooted in a plain
/// identifier.
pub fn lvalueBase(self: *const SourceFile, e: ExprId) ExprId {
    var t = e;
    // Each `.index` is a distinct row, so the chain is no longer than the store.
    var hops: u32 = 0;
    while (t != .none and self.exprs.tag(t) == .index) : (hops += 1) {
        assert(hops < self.exprs.len());
        t = self.exprs.lhs(t);
    }
    if (t == .none or self.exprs.tag(t) != .ident) return .none;
    assert(self.exprs.tag(t) == .ident);
    return t;
}

// ---- private ----

/// The event target is an identity, not a value read or written. Its
/// index expressions are reads, visited leftmost first like the source.
fn eventIndexEdges(self: *const SourceFile, target: ExprId, v: anytype) @TypeOf(v.expr(target, .read)) {
    assert(target != .none);
    if (self.exprs.tag(target) != .index) return;
    try eventIndexEdges(self, self.exprs.lhs(target), v);
    try v.expr(self.exprs.rhs(target), .read);
}

/// The expression half of `stmtWrites`.
fn exprWrites(self: *const SourceFile, funcs: []const FuncDecl, e: ExprId, gpa: std.mem.Allocator, out: *std.ArrayList(ExprId)) std.mem.Allocator.Error!void {
    if (e == .none) return;
    const ex = &self.exprs;
    switch (ex.tag(e)) {
        // §4.4 a probe's operands are net and branch references, which no
        // expression writes.
        .branch_access, .port_access => return,
        .call => {
            const args = ex.args(e);
            for (funcs) |fd| {
                if (fd.name != ex.strOf(e)) continue;
                for (fd.args, 0..) |formal, i| {
                    if (i >= args.len) break;
                    switch (formal.direction) {
                        .output, .inout => try addLvalue(self, args[i], gpa, out),
                        .input, .unspecified => {},
                    }
                }
                break;
            }
        },
        .sys_call => for (sysWrites(self.str(ex.strOf(e)), ex.args(e))) |w| try addLvalue(self, w, gpa, out),
        else => {}, // else: every other tag writes only through its children
    }
    var buf: [3]ExprId = undefined;
    for (ex.children(e, &buf)) |c| try exprWrites(self, funcs, c, gpa, out);
}

fn addLvalue(self: *const SourceFile, e: ExprId, gpa: std.mem.Allocator, out: *std.ArrayList(ExprId)) std.mem.Allocator.Error!void {
    if (e == .none) return;
    if (self.exprs.tag(e) == .assign_pattern) {
        for (self.exprs.args(e)) |el| try addLvalue(self, el, gpa, out);
        return;
    }
    try out.append(gpa, e);
}

/// The arguments of system function or task `name` that it writes through.
/// The positions are the syntax boxes': Syntax 9-8/9-9 put the seed first,
/// §9.5.3/§9.5.4.2 put the destinations after the source and format, and
/// §9.5.4.1/§9.5.7 put `$fgets`'s string first and `$ferror`'s second.
fn sysWrites(name: []const u8, args: []const ExprId) []const ExprId {
    const eq = std.mem.eql;
    const first = args[0..@min(1, args.len)];
    // §9.13 Table 9-10: all 17 names match one of these four spellings.
    if (eq(u8, name, "$random") or eq(u8, name, "$arandom") or
        std.mem.startsWith(u8, name, "$dist_") or std.mem.startsWith(u8, name, "$rdist_")) return first;
    if (eq(u8, name, "$sscanf") or eq(u8, name, "$fscanf")) return args[@min(2, args.len)..];
    if (eq(u8, name, "$ferror")) return args[@min(1, args.len)..];
    // IEEE 1364 §17.10.2 `$value$plusargs(user_string, variable)`.
    if (eq(u8, name, "$value$plusargs")) return args[@min(1, args.len)..@min(2, args.len)];
    if (eq(u8, name, "$fgets") or eq(u8, name, "$swrite") or eq(u8, name, "$sformat")) return first;
    return &.{};
}

fn expectEdges(f: *const SourceFile, id: StmtId, want: []const Visit) !void {
    var r: Recorder = .{ .gpa = std.testing.allocator };
    defer r.seen.deinit(std.testing.allocator);
    try stmtEdges(f, id, &r);
    try std.testing.expectEqualSlices(Visit, want, r.seen.items);
}

fn identExpr(f: *SourceFile, gpa: std.mem.Allocator, name: []const u8) !ExprId {
    return f.exprs.add(gpa, .{ .tag = .ident, .str = try f.intern(gpa, name) });
}

fn read(e: ExprId) Visit {
    return .{ .expr = .{ .e = e, .edge = .read } };
}

test "statement pool keeps handles and token column in lockstep" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);

    const lhs = try f.exprs.add(gpa, .{ .tag = .branch_access, .str = try f.intern(gpa, "I") });
    const rhs = try f.exprs.addInt(gpa, 0, 0);
    const s0 = try f.addStmt(gpa, .{ .contribute = .{ .lhs = lhs, .rhs = rhs } }, 7);
    const s1 = try f.addStmt(gpa, .empty, 9);
    const blk = try f.addStmt(gpa, .{ .block = .{ .body = &.{ s0, s1 } } }, 6);

    try std.testing.expectEqual(@as(u32, 7), f.stmtTok(s0));
    try std.testing.expectEqual(@as(u32, 6), f.stmtTok(blk));
    switch (f.stmt(blk)) {
        .block => |b| try std.testing.expectEqual(@as(usize, 2), b.body.len),
        else => return error.WrongTag,
    }
    switch (f.stmt(s0)) {
        .contribute => |c| try std.testing.expectEqual(lhs, c.lhs),
        else => return error.WrongTag,
    }

    // A block edited in place is the block every later read sees.
    const name = try f.intern(gpa, "genblk1");
    f.seqBlockMut(blk).gen_name = name;
    var it = f.seqBlocks();
    try std.testing.expectEqual(name, it.next().?.gen_name);
    try std.testing.expectEqual(null, it.next());
    try std.testing.expectEqual(name, f.stmt(blk).block.gen_name);
}

test "stmtEdges: an assignment's edges, its repeat count included, in the documented order" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);
    const q = try identExpr(&f, gpa, "q");
    const d = try identExpr(&f, gpa, "d");
    const n = try identExpr(&f, gpa, "n");
    const clk = try identExpr(&f, gpa, "clk");
    const ev = try f.exprs.add(gpa, .{ .tag = .event_posedge, .lhs = clk });
    // IEEE 1364-2005 §9.7.7 `q <= repeat (n) @(posedge clk) d;`: `n` is read.
    const s = try f.addStmt(gpa, .{ .assign = .{ .target = q, .value = d, .nonblocking = true, .timing = ev, .timing_repeat = n } }, 0);
    try expectEdges(&f, s, &.{ .{ .expr = .{ .e = q, .edge = .write } }, read(d), read(n), read(ev) });
    // Without the timing, the `.none` slots still come through.
    const plain = try f.addStmt(gpa, .{ .assign = .{ .target = q, .value = d } }, 0);
    try expectEdges(&f, plain, &.{ .{ .expr = .{ .e = q, .edge = .write } }, read(d), read(.none), read(.none) });
}

test "stmtEdges: every other arm, operands then children in source order" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);
    const a = try identExpr(&f, gpa, "a");
    const b = try identExpr(&f, gpa, "b");
    const c = try identExpr(&f, gpa, "c");
    const s0 = try f.addStmt(gpa, .empty, 0);
    const s1 = try f.addStmt(gpa, .empty, 0);
    const br = try f.exprs.add(gpa, .{ .tag = .branch_access, .lhs = a });
    const branch: Visit = .{ .expr = .{ .e = br, .edge = .branch } };

    try expectEdges(&f, s0, &.{});
    try expectEdges(&f, try f.addStmt(gpa, .{ .disable = .{ .name = f.exprs.strOf(a) } }, 0), &.{});
    try expectEdges(&f, try f.addStmt(gpa, .{ .block = .{ .body = &.{ s0, s1 } } }, 0), &.{ .{ .stmt = s0 }, .{ .stmt = s1 } });
    try expectEdges(&f, try f.addStmt(gpa, .{ .contribute = .{ .lhs = br, .rhs = b } }, 0), &.{ branch, read(b) });
    try expectEdges(&f, try f.addStmt(gpa, .{ .indirect = .{ .lhs = br, .probe = b, .eqn = c } }, 0), &.{ branch, read(b), read(c) });
    try expectEdges(&f, try f.addStmt(gpa, .{ .if_stmt = .{ .cond = a, .then_s = s0, .else_s = .none } }, 0), &.{ read(a), .{ .stmt = s0 }, .{ .stmt = .none } });
    const arms = [_]CaseArm{ .{ .labels = &.{ b, c }, .body = s0 }, .{ .labels = &.{}, .body = s1 } };
    try expectEdges(&f, try f.addStmt(gpa, .{ .case_stmt = .{ .scrutinee = a, .arms = &arms } }, 0), &.{ read(a), read(b), read(c), .{ .stmt = s0 }, .{ .stmt = s1 } });
    try expectEdges(&f, try f.addStmt(gpa, .{ .for_stmt = .{ .init = s0, .cond = a, .step = s1, .body = s0 } }, 0), &.{ .{ .stmt = s0 }, read(a), .{ .stmt = s1 }, .{ .stmt = s0 } });
    try expectEdges(&f, try f.addStmt(gpa, .{ .while_stmt = .{ .cond = a, .body = s0 } }, 0), &.{ read(a), .{ .stmt = s0 } });
    try expectEdges(&f, try f.addStmt(gpa, .{ .repeat_stmt = .{ .count = a, .body = s0 } }, 0), &.{ read(a), .{ .stmt = s0 } });
    try expectEdges(&f, try f.addStmt(gpa, .{ .event_control = .{ .event = a, .body = s0, .kind = .delay } }, 0), &.{ read(a), .{ .stmt = s0 } });
    try expectEdges(&f, try f.addStmt(gpa, .{ .sys_task = .{ .name = f.exprs.strOf(a), .args = &.{ b, .none, c } } }, 0), &.{ read(b), read(.none), read(c) });
    try expectEdges(&f, try f.addStmt(gpa, .{ .jump = .{ .kind = .ret, .value = b } }, 0), &.{read(b)});
    try expectEdges(&f, try f.addStmt(gpa, .{ .jump = .{ .kind = .brk } }, 0), &.{read(.none)});
}

test "stmtEdges: an event trigger's target is an identity; its indices are reads, leftmost first" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);
    const ev = try identExpr(&f, gpa, "ev");
    const i = try identExpr(&f, gpa, "i");
    const j = try identExpr(&f, gpa, "j");
    const evi = try f.exprs.add(gpa, .{ .tag = .index, .lhs = ev, .rhs = i });
    const evij = try f.exprs.add(gpa, .{ .tag = .index, .lhs = evi, .rhs = j });
    // §5.10.4 `-> ev[i][j];`
    try expectEdges(&f, try f.addStmt(gpa, .{ .event_trigger = .{ .target = evij } }, 0), &.{ read(i), read(j) });
    try expectEdges(&f, try f.addStmt(gpa, .{ .event_trigger = .{ .target = ev } }, 0), &.{});
}

test "stmtWrites: assignment targets, output and inout actuals, assignment patterns" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);
    const x = try identExpr(&f, gpa, "x");
    const y = try identExpr(&f, gpa, "y");
    const z = try identExpr(&f, gpa, "z");
    const w = try identExpr(&f, gpa, "w");
    // analog function real g; input a; output b; inout c; ... (§4.7.2.3)
    const g = try f.intern(gpa, "g");
    const formals = [_]ast.FuncArg{
        .{ .name = try f.intern(gpa, "a"), .ty = .real, .direction = .input },
        .{ .name = try f.intern(gpa, "b"), .ty = .real, .direction = .output },
        .{ .name = try f.intern(gpa, "c"), .ty = .real, .direction = .inout },
    };
    const funcs = [_]FuncDecl{.{ .name = g, .ret_ty = .real, .args = &formals, .body = .none }};
    var out: std.ArrayList(ExprId) = .empty;
    defer out.deinit(gpa);

    // x = g(y, z, w): x is assigned, z and w are written through, y is not.
    const call = try f.exprs.add(gpa, .{ .tag = .call, .str = g, .extra = try f.exprs.addExprList(gpa, &.{ y, z, w }) });
    try f.stmtWrites(&funcs, try f.addStmt(gpa, .{ .assign = .{ .target = x, .value = call } }, 0), gpa, &out);
    try std.testing.expectEqualSlices(ExprId, &.{ x, z, w }, out.items);

    // §4.7.2.3 an array actual written as an assignment pattern: each element.
    out.clearRetainingCapacity();
    const pattern = try f.exprs.add(gpa, .{ .tag = .assign_pattern, .extra = try f.exprs.addExprList(gpa, &.{ z, w }) });
    const call2 = try f.exprs.add(gpa, .{ .tag = .call, .str = g, .extra = try f.exprs.addExprList(gpa, &.{ y, pattern, x }) });
    try f.stmtWrites(&funcs, try f.addStmt(gpa, .{ .sys_task = .{ .name = try f.intern(gpa, "$strobe"), .args = &.{call2} } }, 0), gpa, &out);
    try std.testing.expectEqualSlices(ExprId, &.{ z, w, x }, out.items);

    // Fewer actuals than formals, an unknown function, a contribution's
    // branch, and `.none`: nothing is written.
    out.clearRetainingCapacity();
    const short = try f.exprs.add(gpa, .{ .tag = .call, .str = g, .extra = try f.exprs.addExprList(gpa, &.{y}) });
    const unknown = try f.exprs.add(gpa, .{ .tag = .call, .str = try f.intern(gpa, "h"), .extra = try f.exprs.addExprList(gpa, &.{ y, z, w }) });
    const sum = try f.exprs.add(gpa, .{ .tag = .binary, .lhs = short, .rhs = unknown, .extra = @backingInt(ast.BinaryOp.add) });
    const br = try f.exprs.add(gpa, .{ .tag = .branch_access, .lhs = y });
    try f.stmtWrites(&funcs, try f.addStmt(gpa, .{ .contribute = .{ .lhs = br, .rhs = sum } }, 0), gpa, &out);
    try f.stmtWrites(&funcs, .none, gpa, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "stmtWrites: a system task's or function's destinations (§9.5, §9.13)" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);
    const seed = try identExpr(&f, gpa, "seed");
    const n = try identExpr(&f, gpa, "n");
    const s = try identExpr(&f, gpa, "s");
    const a = try identExpr(&f, gpa, "a");
    const b = try identExpr(&f, gpa, "b");
    var out: std.ArrayList(ExprId) = .empty;
    defer out.deinit(gpa);

    // `$random(seed);` as a task.
    try f.stmtWrites(&.{}, try f.addStmt(gpa, .{ .sys_task = .{ .name = try f.intern(gpa, "$random"), .args = &.{seed} } }, 0), gpa, &out);
    try std.testing.expectEqualSlices(ExprId, &.{seed}, out.items);

    // `n = $sscanf(s, "%d %d", a, b);`: the count and both destinations.
    out.clearRetainingCapacity();
    const fmt = try f.exprs.add(gpa, .{ .tag = .str_literal, .str = try f.intern(gpa, "%d %d") });
    const scan = try f.exprs.add(gpa, .{ .tag = .sys_call, .str = try f.intern(gpa, "$sscanf"), .extra = try f.exprs.addExprList(gpa, &.{ s, fmt, a, b }) });
    try f.stmtWrites(&.{}, try f.addStmt(gpa, .{ .assign = .{ .target = n, .value = scan } }, 0), gpa, &out);
    try std.testing.expectEqualSlices(ExprId, &.{ n, a, b }, out.items);
}

test "sysWrites: the argument positions the syntax boxes write through" {
    const a = [4]ExprId{ @fromBackingInt(0), @fromBackingInt(1), @fromBackingInt(2), @fromBackingInt(3) };
    const cases = [_]struct { name: []const u8, args: []const ExprId, want: []const ExprId }{
        // Syntax 9-8/9-9: the seed comes first; Table 9-10's 17 names.
        .{ .name = "$random", .args = a[0..1], .want = a[0..1] },
        .{ .name = "$arandom", .args = a[0..2], .want = a[0..1] },
        .{ .name = "$dist_uniform", .args = a[0..3], .want = a[0..1] },
        .{ .name = "$rdist_poisson", .args = a[0..2], .want = a[0..1] },
        // §9.5.3/§9.5.4.2: after the source and the format.
        .{ .name = "$sscanf", .args = a[0..4], .want = a[2..4] },
        .{ .name = "$fscanf", .args = a[0..3], .want = a[2..3] },
        // §9.5.7 `$ferror(fd, str)`, §9.5.4.1 `$fgets(str, fd)`.
        .{ .name = "$ferror", .args = a[0..2], .want = a[1..2] },
        .{ .name = "$fgets", .args = a[0..2], .want = a[0..1] },
        .{ .name = "$swrite", .args = a[0..3], .want = a[0..1] },
        .{ .name = "$sformat", .args = a[0..3], .want = a[0..1] },
        // IEEE 1364 §17.10.2 `$value$plusargs(user_string, variable)`.
        .{ .name = "$value$plusargs", .args = a[0..2], .want = a[1..2] },
        .{ .name = "$display", .args = a[0..2], .want = a[0..0] },
        .{ .name = "$dist", .args = a[0..2], .want = a[0..0] },
        .{ .name = "random", .args = a[0..1], .want = a[0..0] },
    };
    for (cases) |c| {
        try std.testing.expectEqualSlices(ExprId, c.want, sysWrites(c.name, c.args));
        // An empty argument list is never indexed past its end.
        try std.testing.expectEqual(@as(usize, 0), sysWrites(c.name, &.{}).len);
    }
}

test "lvalueBase walks selects down to the declared name" {
    const gpa = std.testing.allocator;
    var f: SourceFile = .empty;
    defer f.deinit(gpa);
    const x = try identExpr(&f, gpa, "x");
    const i = try identExpr(&f, gpa, "i");
    const xi = try f.exprs.add(gpa, .{ .tag = .index, .lhs = x, .rhs = i });
    const xij = try f.exprs.add(gpa, .{ .tag = .index, .lhs = xi, .rhs = i });
    const r = try f.exprs.add(gpa, .{ .tag = .range, .lhs = i, .rhs = i });
    const part = try f.exprs.add(gpa, .{ .tag = .index, .lhs = x, .rhs = r });
    const call = try f.exprs.add(gpa, .{ .tag = .call, .str = f.exprs.strOf(x), .extra = try f.exprs.addExprList(gpa, &.{}) });
    const call_i = try f.exprs.add(gpa, .{ .tag = .index, .lhs = call, .rhs = i });
    for ([_]ExprId{ x, xi, xij, part }) |e| try std.testing.expectEqual(x, f.lvalueBase(e));
    for ([_]ExprId{ call, call_i, .none }) |e| try std.testing.expectEqual(ExprId.none, f.lvalueBase(e));
}
