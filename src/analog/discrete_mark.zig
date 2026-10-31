const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const Lower = @import("Lower.zig");
const lower_expr_case = @import("expr_case.zig");
const lower_context = @import("context.zig");
const Oom = Lower.Oom;

/// Marks, in `marks` (indexed by `Ast.ExprId`), every expression §7.2.2's
/// discrete context owns in a mixed module (`isMixed`): the bodies of its
/// `initial`/`always` blocks and continuous assignments, plus every module's
/// task bodies. Those run on the four-state kernel, so an x or z literal there
/// is ordinary IEEE 1364. A non-mixed module's `initial` is not marked:
/// `collectInitialState` folds it into analog initial values, where an x has
/// nowhere to live. Asserts that `marks` has one slot per expression id.
pub fn markDiscreteExprs(file: *const Ast.SourceFile, marks: []bool) void {
    assert(marks.len == file.exprs.len());
    const Mark = struct {
        file: *const Ast.SourceFile,
        marks: []bool,
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) error{}!void {
            if (e == .none) return;
            w.marks[@backingInt(e)] = true;
            var buf: [3]Ast.ExprId = undefined;
            for (w.file.exprs.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) error{}!void {
            if (s != .none) try w.file.stmtEdges(s, w);
        }
    };
    // §7.3.2 in an analog block, an x/z literal compared by `===`/`!==` or as a
    // `case`/`casex`/`casez` label is the four-state comparison the clause
    // provides (`lower_expr_case.caseEquality`); anywhere else it stays E0130. Every
    // module, not only a mixed one: the clause's own `a2d` has no discrete block
    // and reads its input net with `dnet === 1'bx`.
    //
    // §6.6.1 a genvar loop's initialization and iteration values are folded at
    // elaboration, never executed, so an x/z literal there is not E0130's: it
    // is §6.6.1's own error ("any bit of the genvar is set to x or z", E0486,
    // `control.tryUnrollFor`).
    const Cmp = struct {
        file: *const Ast.SourceFile,
        marks: []bool,
        genvars: []const Ast.StrId,
        fn lit(w: @This(), e: Ast.ExprId) void {
            if (e != .none and w.file.exprs.tag(e) == .logic_literal) w.marks[@backingInt(e)] = true;
        }
        fn lits(w: @This(), e: Ast.ExprId) void {
            if (e == .none) return;
            w.lit(e);
            var buf: [3]Ast.ExprId = undefined;
            for (w.file.exprs.children(e, &buf)) |c| w.lits(c);
        }
        fn genvarAssign(w: @This(), s: Ast.StmtId) ?Ast.ExprId {
            if (s == .none or w.file.stmt(s) != .assign) return null;
            const a = w.file.stmt(s).assign;
            if (w.file.exprs.tag(a.target) != .ident) return null;
            for (w.genvars) |g| if (g == w.file.exprs.strOf(a.target)) return a.value;
            return null;
        }
        pub fn expr(w: @This(), e: Ast.ExprId, _: Ast.SourceFile.Edge) error{}!void {
            if (e == .none) return;
            const ex = &w.file.exprs;
            if (ex.tag(e) == .binary and (ex.binOp(e) == .case_eq or ex.binOp(e) == .case_neq)) {
                w.lit(ex.lhs(e));
                w.lit(ex.rhs(e));
            }
            var buf: [3]Ast.ExprId = undefined;
            for (ex.children(e, &buf)) |c| try w.expr(c, .read);
        }
        pub fn stmt(w: @This(), s: Ast.StmtId) error{}!void {
            if (s == .none) return;
            switch (w.file.stmt(s)) {
                .case_stmt => |c| for (c.arms) |arm| for (arm.labels) |l| w.lit(l),
                .for_stmt => |f| if (w.genvarAssign(f.init)) |init| {
                    w.lits(init);
                    // The iteration of a genvar loop: whichever name it
                    // assigns, it is folded (or refused as E0419) like init.
                    if (f.step != .none and w.file.stmt(f.step) == .assign) w.lits(w.file.stmt(f.step).assign.value);
                },
                else => {}, // else: only a case statement has labels, a genvar loop a folded scheme
            }
            try w.file.stmtEdges(s, w);
        }
    };
    const w: Mark = .{ .file = file, .marks = marks };
    for (file.modules) |*m| {
        // A task (A.2.7) runs only on the kernel, in any module: the analog
        // backend never executes its body.
        for (m.tasks) |t| w.stmt(t.body) catch unreachable;
        for (m.analog) |blk| (Cmp{ .file = file, .marks = marks, .genvars = m.genvars }).stmt(blk.body) catch unreachable;
        if (!lower_context.isMixed(file, m)) continue;
        for (m.discrete) |blk| w.stmt(blk.body) catch unreachable;
        for (m.assigns) |a| for ([_]Ast.ExprId{ a.target, a.value, a.delay.rise, a.delay.fall, a.delay.off }) |e|
            w.expr(e, .read) catch unreachable;
    }
}

/// Every identifier an analog statement tree reads, split by §8.4.3.2: a read
/// inside a statement guarded by an explicit D2A event (`guarded`) does not
/// make the block implicitly sensitive, and §8.5.3.6 gives it the region-1b
/// value; every other read (`names`) is a live, implicitly sensitive input.
pub const Reads = struct {
    l: *Lower,
    /// Digital-owned values and digitally triggered named events.
    digital: *const std.StringHashMapUnmanaged(void),
    /// Unguarded reads, counted.
    names: std.StringHashMapUnmanaged(u32) = .empty,
    guarded: std.StringHashMapUnmanaged(void) = .empty,
    /// §7.3.2 reads as an operand of `===`/`!==` or as a `case` subject,
    /// counted: a name all of whose reads are these is read four-state.
    xz: std.StringHashMapUnmanaged(u32) = .empty,
    sites: std.ArrayList(Site) = .empty,
    in_d2a: bool = false,
    const Site = struct { term: Ast.ExprId, name: []const u8, edge: Edge };

    pub fn stmt(w: *Reads, s: Ast.StmtId) Oom!void {
        if (s == .none) return;
        switch (w.l.file.stmt(s)) {
            .event_control => |c| if (c.kind == .event and c.event != .none) {
                const before = w.sites.items.len;
                try w.eventTerms(c.event);
                const prev = w.in_d2a;
                defer w.in_d2a = prev;
                if (w.sites.items.len != before) w.in_d2a = true;
                return w.stmt(c.body);
            },
            .case_stmt => |c| try w.caseOperand(c.scrutinee),
            else => {}, // else: every other statement is read edge by edge
        }
        try w.l.file.stmtEdges(s, w);
    }

    /// §7.3.4 Syntax 7-2: an `or` list's digital terms are explicit D2A sites;
    /// the rest (cross, timer, an analog named event) are read as expressions.
    fn eventTerms(w: *Reads, e: Ast.ExprId) Oom!void {
        const ex = &w.l.file.exprs;
        if (ex.tag(e) == .event_or) {
            try w.eventTerms(ex.lhs(e));
            return w.eventTerms(ex.rhs(e));
        }
        if (lower_context.d2aTerm(w.l.file, e, w.digital)) |t|
            return w.sites.append(w.l.arena, .{ .term = e, .name = t.name, .edge = t.edge });
        // A bare name that is not digital is an analog named event, not a read.
        if (ex.tag(e) != .ident) try w.expr(e, .read);
    }

    fn caseOperand(w: *Reads, e: Ast.ExprId) Oom!void {
        const ex = &w.l.file.exprs;
        if (w.in_d2a or e == .none or ex.tag(e) != .ident) return;
        const n = try w.xz.getOrPutValue(w.l.arena, w.l.file.str(ex.strOf(e)), 0);
        n.value_ptr.* += 1;
    }

    /// Every unguarded read of `name` is §7.3.2's four-state comparison, so an
    /// x or z it holds is a value and not the clause's error.
    pub fn fourStateOnly(w: *const Reads, name: []const u8) bool {
        const n = w.xz.get(name) orelse return false;
        return n == w.names.get(name).?;
    }

    pub fn expr(w: *Reads, e: Ast.ExprId, _: Ast.SourceFile.Edge) Oom!void {
        if (e == .none) return;
        const ex = &w.l.file.exprs;
        if (ex.tag(e) == .ident) {
            const name = w.l.file.str(ex.strOf(e));
            if (w.in_d2a) try w.guarded.put(w.l.arena, name, {}) else (try w.names.getOrPutValue(w.l.arena, name, 0)).value_ptr.* += 1;
        }
        if (ex.tag(e) == .binary and (ex.binOp(e) == .case_eq or ex.binOp(e) == .case_neq)) {
            try w.caseOperand(ex.lhs(e));
            try w.caseOperand(ex.rhs(e));
        }
        var buf: [3]Ast.ExprId = undefined;
        for (ex.children(e, &buf)) |c| {
            // §4.4: a bare name in `V(d)` is the net the access function is
            // applied to, not a Table 7-1 read of its digital value. Making it
            // a discrete input would drop the node and turn a ddiscrete net's
            // E0501 ("binds no potential nature") into a false E0337 ("has no
            // discipline"). An index expression inside the argument is a read.
            if (c != .none and ex.tag(e) == .branch_access and ex.tag(c) == .ident) continue;
            try w.expr(c, .read);
        }
    }
};

pub const Edge = @FieldType(Lower.Lowered.DiscreteEvent, "edge");

test markDiscreteExprs {
    // §7.3.2: in an analog block an x or z literal is a value only as a
    // `case` label or an operand of `===`/`!==`; anywhere else it stays
    // E0130's. Only literals with an unknown bit are counted, so the
    // prelude's two-state literals do not enter.
    var h: Lower.Harness = undefined;
    try h.init(std.testing.allocator,
        \\module m(p);
        \\  inout p; electrical p;
        \\  integer k;
        \\  analog begin
        \\    case (k) 1'bx: k = 1; endcase
        \\    k = (k === 1'bz) + 2'bx1;
        \\    I(p) <+ V(p);
        \\  end
        \\endmodule
    );
    defer h.deinit();
    const ex = &h.file.exprs;
    const marks = try std.testing.allocator.alloc(bool, ex.len());
    defer std.testing.allocator.free(marks);
    @memset(marks, false);
    markDiscreteExprs(&h.file, marks);
    var marked: usize = 0;
    var unmarked: usize = 0;
    for (marks, 0..) |m, i| {
        const e: Ast.ExprId = @fromBackingInt(@intCast(i));
        if (ex.tag(e) != .logic_literal) continue;
        if (!ex.logicValue(e).hasUnknown()) continue;
        if (m) marked += 1 else unmarked += 1;
    }
    try std.testing.expectEqual(2, marked);
    try std.testing.expectEqual(1, unmarked);
}
