//! A source expression or task call -> its vpiDecompile text, with only the
//! parentheses precedence needs.
//! Cites: IEEE 1364-2005 §5.1.2 (precedence), §26.6.19 g), §26.6.26 b).
//!
//! Contents:
//! - `pub fn decompile(w: *Writer, f: *const Ast.SourceFile, id: Ast.ExprId) Writer.Error!void`
//! - `pub fn decompileCall(w: *Writer, f: *const Ast.SourceFile, id: Ast.StmtId) Writer.Error!void`

const std = @import("std");
const Ast = @import("frontend").Ast;
const Io = std.Io;
const Writer = std.Io.Writer;
const handle = @import("handle.zig");
const iterate = @import("iterate.zig");
const property = @import("property.zig");
const trust = @import("trust.zig");
const schema = @import("schema.zig");
const user = @import("vpi_user.zig");
const run = @import("run.zig");
const Harness = run.Harness;

/// IEEE 1364-2005 §5.1.2 Table 5-4, highest first; every binary operator
/// associates left to right, the conditional right to left.
const unary_prec: u8 = 12;

/// One piece of text still to write: bytes as they are, or an expression,
/// parenthesized as an operand of an operator of precedence `parent` when
/// it binds looser (or as loose, on the right of a left-associative one).
/// The default `parent` 0 never parenthesizes: a plain subexpression.
const Item = union(enum) {
    text: []const u8,
    expr: struct { id: Ast.ExprId, parent: u8 = 0, right: bool = false },
};

/// The pieces still to write, the next one last. Every piece writes at
/// least one byte (no text is empty, and every expression form writes one
/// of its own), so more pieces than `w` has room for cannot fit: that is
/// `w`'s own `error.WriteFailed`, and the stack never outgrows `w`.
const Todo = struct {
    w: *Writer,
    items: *[schema.name_buf_len]Item,
    len: usize = 0,

    /// One stack for every call: vpi_get_str's text is one static buffer
    /// too (`property.str_buf`), so no two decompiles overlap.
    var stack: [schema.name_buf_len]Item = undefined;

    fn init(w: *Writer) Todo {
        std.debug.assert(w.buffer.len < schema.name_buf_len);
        return .{ .w = w, .items = &stack };
    }

    /// Pushes `it`; an absent operand (`.none`) is no piece.
    fn push(t: *Todo, it: Item) Writer.Error!void {
        switch (it) {
            .text => |x| std.debug.assert(x.len != 0),
            .expr => |e| if (e.id == .none) return,
        }
        if (t.w.end + t.len + 1 > t.w.buffer.len) return error.WriteFailed;
        std.debug.assert(t.len < t.items.len);
        t.items[t.len] = it;
        t.len += 1;
    }

    /// `pieces` in order: pushed last first.
    fn seq(t: *Todo, pieces: []const Item) Writer.Error!void {
        var k = pieces.len;
        while (k > 0) {
            k -= 1;
            try t.push(pieces[k]);
        }
    }

    /// `open`, the items separated by `, `, `close`.
    fn list(t: *Todo, open: []const u8, items: []const Ast.ExprId, close: []const u8) Writer.Error!void {
        std.debug.assert(open.len != 0);
        std.debug.assert(close.len != 0);
        try t.push(.{ .text = close });
        var k = items.len;
        while (k > 0) {
            k -= 1;
            try t.push(.{ .expr = .{ .id = items[k] } });
            if (k != 0) try t.push(.{ .text = ", " });
        }
        try t.push(.{ .text = open });
    }

    /// Writes the pieces until none is left. Each expression is popped
    /// once (its children are its own rows), and each pops at most nine
    /// texts and its list's separators, so the loop is bounded by the
    /// rows of `f`.
    fn drain(t: *Todo, f: *const Ast.SourceFile) Writer.Error!void {
        const pops_max = 16 * @as(usize, f.exprs.len()) + 16;
        var pops: usize = 0;
        while (t.len > 0) : (pops += 1) {
            std.debug.assert(pops < pops_max);
            t.len -= 1;
            switch (t.items[t.len]) {
                .text => |s| try t.w.writeAll(s),
                .expr => |e| try t.expand(f, e.id, e.parent, e.right),
            }
        }
        std.debug.assert(t.len == 0);
    }

    /// `id`'s own text, its subexpressions pushed in place.
    fn expand(t: *Todo, f: *const Ast.SourceFile, id: Ast.ExprId, parent: u8, right: bool) Writer.Error!void {
        std.debug.assert(id != .none); // `push` keeps no absent operand
        std.debug.assert(parent <= unary_prec + 1);
        const ex = &f.exprs;
        const p = precOf(ex, id);
        if (p < parent or (right and p == parent)) {
            try t.w.writeByte('(');
            try t.push(.{ .text = ")" });
        }
        const before = t.w.end + t.len;
        defer std.debug.assert(t.w.end + t.len > before);
        switch (ex.tag(id)) {
            .ident, .hier_ident, .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf, .event_initial_step, .event_final_step => try writeLeaf(t.w, f, id),
            .unary => try t.seq(&.{ .{ .text = unarySpelling(ex.unOp(id)) }, .{ .text = " " }, .{ .expr = .{ .id = ex.lhs(id), .parent = unary_prec } } }),
            .binary => {
                const bp = binaryPrec(ex.binOp(id));
                try t.seq(&.{ .{ .expr = .{ .id = ex.lhs(id), .parent = bp } }, .{ .text = " " }, .{ .text = binarySpelling(ex.binOp(id)) }, .{ .text = " " }, .{ .expr = .{ .id = ex.rhs(id), .parent = bp, .right = true } } });
            },
            .ternary => try t.seq(&.{ .{ .expr = .{ .id = ex.lhs(id), .right = true } }, .{ .text = " ? " }, .{ .expr = .{ .id = ex.rhs(id) } }, .{ .text = " : " }, .{ .expr = .{ .id = ex.ternaryElse(id) } } }),
            .call, .builtin_call, .filter_call, .noise_call, .event_function => {
                try t.list("(", ex.args(id), ")");
                try t.push(.{ .text = f.str(ex.strOf(id)) });
            },
            // A.8.2 system_function_call: the parentheses come with arguments.
            .sys_call => {
                if (ex.args(id).len != 0) try t.list("(", ex.args(id), ")");
                try t.push(.{ .text = f.str(ex.strOf(id)) });
            },
            .branch_access => if (ex.rhs(id) != .none)
                try t.seq(&.{ .{ .text = f.str(ex.strOf(id)) }, .{ .text = "(" }, .{ .expr = .{ .id = ex.lhs(id) } }, .{ .text = ", " }, .{ .expr = .{ .id = ex.rhs(id) } }, .{ .text = ")" } })
            else
                try t.seq(&.{ .{ .text = f.str(ex.strOf(id)) }, .{ .text = "(" }, .{ .expr = .{ .id = ex.lhs(id) } }, .{ .text = ")" } }),
            .port_access => try t.seq(&.{ .{ .text = f.str(ex.strOf(id)) }, .{ .text = "(<" }, .{ .expr = .{ .id = ex.lhs(id) } }, .{ .text = ">)" } }),
            .concat => try t.list("{", ex.args(id), "}"),
            .multi_concat => {
                var inner = ex.rhs(id);
                if (ex.tag(inner) == .concat and ex.args(inner).len == 1 and ex.tag(ex.args(inner)[0]) == .concat) inner = ex.args(inner)[0];
                try t.seq(&.{ .{ .text = "{" }, .{ .expr = .{ .id = ex.lhs(id) } }, .{ .expr = .{ .id = inner } }, .{ .text = "}" } });
            },
            .assign_pattern => try t.list("'{", ex.args(id), "}"),
            .pattern_repl => {
                try t.push(.{ .text = "}" });
                try t.list("{", ex.args(ex.rhs(id)), "}");
                try t.seq(&.{ .{ .text = "'{" }, .{ .expr = .{ .id = ex.lhs(id) } } });
            },
            .index => try t.seq(&.{ .{ .expr = .{ .id = ex.lhs(id), .parent = unary_prec + 1 } }, .{ .text = "[" }, .{ .expr = .{ .id = ex.rhs(id) } }, .{ .text = "]" } }),
            .range => try t.seq(&.{ .{ .expr = .{ .id = ex.lhs(id) } }, .{ .text = ":" }, .{ .expr = .{ .id = ex.rhs(id) } } }),
            .indexed_range => try t.seq(&.{ .{ .expr = .{ .id = ex.lhs(id) } }, .{ .text = if (ex.extraOf(id) == 0) " +: " else " -: " }, .{ .expr = .{ .id = ex.rhs(id) } } }),
            .event_or => try t.seq(&.{ .{ .expr = .{ .id = ex.lhs(id) } }, .{ .text = " or " }, .{ .expr = .{ .id = ex.rhs(id) } } }),
            .event_posedge => try t.seq(&.{ .{ .text = "posedge " }, .{ .expr = .{ .id = ex.lhs(id) } } }),
            .event_negedge => try t.seq(&.{ .{ .text = "negedge " }, .{ .expr = .{ .id = ex.lhs(id) } } }),
            .event_driver_update => try t.seq(&.{ .{ .text = "driver_update " }, .{ .expr = .{ .id = ex.lhs(id) } } }),
        }
    }
};

/// §26.6.26 b): "a string with a functionally equivalent expression to the
/// original expression within the HDL. Parentheses shall be added only to
/// preserve precedence. Each operand and operator shall be separated by a
/// single space character." A literal is spelled in its own base, and an
/// x/z or wide one in binary. `w` is a `Writer.fixed` of fewer than
/// `schema.name_buf_len` bytes; a text past it is `error.WriteFailed`.
/// Asserts that `id` is `.none` or a row of `f`, and that the text only
/// grows `w`.
///
/// A worklist (`todo`), not a recursion: the expression nests as deep as
/// the source does, on whatever thread the application calls from.
pub fn decompile(w: *Writer, f: *const Ast.SourceFile, id: Ast.ExprId) Writer.Error!void {
    std.debug.assert(id == .none or @backingInt(id) < f.exprs.len());
    if (id == .none) return;
    const before = w.end;
    defer std.debug.assert(w.end >= before);
    var todo: Todo = .init(w);
    try todo.push(.{ .expr = .{ .id = id } });
    try todo.drain(f);
}

/// §26.6.19 g): a system or user task call, "a functionally equivalent
/// system task/function call to what was in the original HDL". Asserts
/// that `id` is a task-call statement of `f` and that its name is written.
pub fn decompileCall(w: *Writer, f: *const Ast.SourceFile, id: Ast.StmtId) Writer.Error!void {
    std.debug.assert(id != .none);
    std.debug.assert(f.stmt(id) == .sys_task);
    const before = w.end;
    const s = f.stmt(id).sys_task;
    try w.writeAll(f.str(s.name));
    var todo: Todo = .init(w);
    if (s.args.len != 0) try todo.list("(", s.args, ")");
    try todo.drain(f);
    std.debug.assert(w.end > before);
}

// ---- private ----

/// A name, a literal or an analysis event, written whole.
fn writeLeaf(w: *Writer, f: *const Ast.SourceFile, id: Ast.ExprId) Writer.Error!void {
    const ex = &f.exprs;
    std.debug.assert(id != .none);
    const before = w.end;
    switch (ex.tag(id)) {
        .ident => try w.writeAll(f.str(ex.strOf(id))),
        .hier_ident => for (ex.nameParts(id), 0..) |p, k| {
            if (k != 0) try w.writeByte('.');
            try w.writeAll(f.str(p));
        },
        .int_literal => {
            const lit = ex.intLiteral(id);
            if (lit.width == 0 and lit.radix == 10) return w.print("{d}", .{lit.value});
            const bits: u64 = if (lit.width == 0 or lit.width >= 64) @bitCast(lit.value) else @as(u64, @bitCast(lit.value)) & ((@as(u64, 1) << @intCast(lit.width)) - 1);
            if (lit.width != 0) try w.print("{d}", .{lit.width});
            try w.writeAll(if (lit.signed) "'s" else "'");
            switch (lit.radix) {
                2 => try w.print("b{b}", .{bits}),
                8 => try w.print("o{o}", .{bits}),
                16 => try w.print("h{x}", .{bits}),
                else => try w.print("d{d}", .{bits}),
            }
        },
        .logic_literal => {
            const lit = ex.logicValue(id);
            try w.print("{d}{s}b", .{ lit.width, if (lit.signed) "'s" else "'" });
            var k = lit.width;
            while (k > 0) {
                std.debug.assert(k <= lit.width);
                k -= 1;
                const v = (lit.values()[k / 64] >> @intCast(k % 64)) & 1;
                const u = (lit.unknowns()[k / 64] >> @intCast(k % 64)) & 1;
                try w.writeByte("01zx"[v | (u << 1)]);
            }
        },
        .real_literal => {
            var buf: [400]u8 = undefined;
            const t = std.mem.print(&buf, "{d}", .{ex.realValue(id)}) catch unreachable;
            try w.writeAll(t);
            // A real stays a real: `2.0`, not the integer `2`.
            if (std.mem.findAny(u8, t, ".eEni") == null) try w.writeAll(".0");
        },
        .str_literal => {
            try w.writeByte('"');
            for (f.str(ex.strOf(id))) |c| switch (c) {
                '\\' => try w.writeAll("\\\\"),
                '"' => try w.writeAll("\\\""),
                '\n' => try w.writeAll("\\n"),
                '\t' => try w.writeAll("\\t"),
                0x20...0x21, 0x23...0x5b, 0x5d...0x7e => try w.writeByte(c),
                else => try w.print("\\{o:0>3}", .{c}),
            };
            try w.writeByte('"');
        },
        .pos_inf => try w.writeAll("inf"),
        .neg_inf => try w.writeAll("-inf"),
        .event_initial_step, .event_final_step => {
            try w.writeAll(if (ex.tag(id) == .event_initial_step) "initial_step" else "final_step");
            const names = ex.nameParts(id);
            if (names.len != 0) {
                try w.writeByte('(');
                for (names, 0..) |n, k| try w.print("{s}\"{s}\"", .{ if (k == 0) "" else ", ", f.str(n) });
                try w.writeByte(')');
            }
        },
        else => unreachable, // else: `Todo.expand` writes only these whole
    }
    std.debug.assert(w.end > before);
}

/// Table 5-4's binary ranks: above the conditional's 0, below a unary's.
fn binaryPrec(op: Ast.BinaryOp) u8 {
    const p: u8 = switch (op) {
        .pow => 11,
        .mul, .div, .mod => 10,
        .add, .sub => 9,
        .shl, .shr, .ashl, .ashr => 8,
        .lt, .le, .gt, .ge => 7,
        .eq, .neq, .case_eq, .case_neq => 6,
        .bit_and => 5,
        .bit_xor, .bit_xnor => 4,
        .bit_or => 3,
        .logical_and => 2,
        .logical_or => 1,
    };
    std.debug.assert(p >= 1);
    std.debug.assert(p < unary_prec);
    return p;
}

/// The precedence `id` binds at as an operand: its operator's, or above
/// every operator for a primary.
fn precOf(ex: *const Ast.ExprStore, id: Ast.ExprId) u8 {
    // An operator's operand always exists.
    std.debug.assert(id != .none);
    const p: u8 = switch (ex.tag(id)) {
        .unary => unary_prec,
        .binary => binaryPrec(ex.binOp(id)),
        .ternary => 0,
        // A primary: a literal, a name, a call, a select, a concatenation.
        .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf, .ident, .hier_ident, .call, .builtin_call, .sys_call, .filter_call, .noise_call, .branch_access, .port_access, .concat, .multi_concat, .assign_pattern, .pattern_repl, .index, .range, .indexed_range, .event_or, .event_posedge, .event_negedge, .event_initial_step, .event_final_step, .event_function, .event_driver_update => unary_prec + 1,
    };
    std.debug.assert(p <= unary_prec + 1);
    return p;
}

fn unarySpelling(op: Ast.UnaryOp) []const u8 {
    const s: []const u8 = switch (op) {
        .plus => "+",
        .minus => "-",
        .logical_not => "!",
        .bit_not => "~",
        .reduce_and => "&",
        .reduce_nand => "~&",
        .reduce_or => "|",
        .reduce_nor => "~|",
        .reduce_xor => "^",
        .reduce_xnor => "~^",
    };
    std.debug.assert(s.len >= 1);
    std.debug.assert(s.len <= 2);
    return s;
}

fn binarySpelling(op: Ast.BinaryOp) []const u8 {
    const s: []const u8 = switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .pow => "**",
        .eq => "==",
        .neq => "!=",
        .case_eq => "===",
        .case_neq => "!==",
        .lt => "<",
        .le => "<=",
        .gt => ">",
        .ge => ">=",
        .logical_and => "&&",
        .logical_or => "||",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .bit_xnor => "~^",
        .shl => "<<",
        .shr => ">>",
        .ashl => "<<<",
        .ashr => ">>>",
    };
    std.debug.assert(s.len >= 1);
    std.debug.assert(s.len <= 3);
    return s;
}

test "§26.6.26 b) vpiDecompile adds parentheses only where precedence needs them" {
    var h: Harness = undefined;
    try h.init(
        \\module t;
        \\  reg [7:0] x, a, b, c, d;
        \\  initial x = (a + b) * c - (d - a) - b ? {2{a[1:0], 1'b1}} : ~(a & 4'hF) + -2.5;
        \\endmodule
    );
    defer h.deinit();
    const procs = iterate.vpi_iterate(user.vpiProcess, handle.vpi_handle_by_name("t", null));
    const init = iterate.vpi_scan(procs);
    _ = trust.vpi_free_object(procs);
    const rhs = handle.vpi_handle(user.vpiRhs, handle.vpi_handle(user.vpiStmt, init));
    try std.testing.expectEqualStrings(
        "(a + b) * c - (d - a) - b ? {2{a[1:0], 1'b1}} : ~ (a & 4'hf) + - 2.5",
        std.mem.span(property.vpi_get_str(user.vpiDecompile, rhs)),
    );
}

test "§26.6.26 b): an equal-precedence right operand keeps its parentheses; literals keep their base" {
    // IEEE 1364-2005 §5.1.2: every binary operator associates left to right,
    // `**` included, and the conditional right to left. So `a - (b - c)` and
    // `a ** (b ** c)` need theirs, `a - b - c` none, and a conditional as a
    // condition needs them where one as the else-branch does not.
    var h: Harness = undefined;
    try h.init(
        \\module t;
        \\  reg [7:0] a, b, c;
        \\  wire [7:0] w1, w2, w3, w4, w5;
        \\  assign w1 = a - (b - c);
        \\  assign w2 = a - b - c;
        \\  assign w3 = a ** (b ** c);
        \\  assign w4 = (a ? b : c) ? 8'sd5 : 4'hF;
        \\  assign w5 = a ? b : c ? 4'b1x0z : 42;
        \\endmodule
    );
    defer h.deinit();
    const itr = iterate.vpi_iterate(user.vpiContAssign, handle.vpi_handle_by_name("t", null));
    for ([_][]const u8{
        "a - (b - c)",
        "a - b - c",
        "a ** (b ** c)",
        "(a ? b : c) ? 8'sd5 : 4'hf",
        "a ? b : c ? 4'b1x0z : 42",
    }) |want| {
        const assign = iterate.vpi_scan(itr) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(want, std.mem.span(property.vpi_get_str(user.vpiDecompile, handle.vpi_handle(user.vpiRhs, assign))));
    }
    try std.testing.expect(iterate.vpi_scan(itr) == null);
}
