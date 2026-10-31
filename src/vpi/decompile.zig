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
const user = @import("vpi_user.zig");
const run = @import("run.zig");
const Harness = run.Harness;

/// IEEE 1364-2005 §5.1.2 Table 5-4, highest first; every binary operator
/// associates left to right, the conditional right to left.
const unary_prec: u8 = 12;

/// §26.6.26 b): "a string with a functionally equivalent expression to the
/// original expression within the HDL. Parentheses shall be added only to
/// preserve precedence. Each operand and operator shall be separated by a
/// single space character." A literal is spelled in its own base, and an
/// x/z or wide one in binary.
pub fn decompile(w: *Writer, f: *const Ast.SourceFile, id: Ast.ExprId) Writer.Error!void {
    if (id == .none) return;
    const ex = &f.exprs;
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
        .unary => {
            try w.writeAll(unarySpelling(ex.unOp(id)));
            try w.writeByte(' ');
            try operand(w, f, ex.lhs(id), unary_prec, false);
        },
        .binary => {
            const p = binaryPrec(ex.binOp(id));
            try operand(w, f, ex.lhs(id), p, false);
            try w.print(" {s} ", .{binarySpelling(ex.binOp(id))});
            try operand(w, f, ex.rhs(id), p, true);
        },
        .ternary => {
            try operand(w, f, ex.lhs(id), 0, true);
            try w.writeAll(" ? ");
            try decompile(w, f, ex.rhs(id));
            try w.writeAll(" : ");
            try decompile(w, f, ex.ternaryElse(id));
        },
        .call, .builtin_call, .filter_call, .noise_call, .event_function => {
            try w.writeAll(f.str(ex.strOf(id)));
            try list(w, f, "(", ex.args(id), ")");
        },
        // A.8.2 system_function_call: the parentheses come with arguments.
        .sys_call => {
            try w.writeAll(f.str(ex.strOf(id)));
            if (ex.args(id).len != 0) try list(w, f, "(", ex.args(id), ")");
        },
        .branch_access => {
            try w.print("{s}(", .{f.str(ex.strOf(id))});
            try decompile(w, f, ex.lhs(id));
            if (ex.rhs(id) != .none) try w.writeAll(", ");
            try decompile(w, f, ex.rhs(id));
            try w.writeByte(')');
        },
        .port_access => {
            try w.print("{s}(<", .{f.str(ex.strOf(id))});
            try decompile(w, f, ex.lhs(id));
            try w.writeAll(">)");
        },
        .concat => try list(w, f, "{", ex.args(id), "}"),
        .multi_concat => {
            var inner = ex.rhs(id);
            if (ex.tag(inner) == .concat and ex.args(inner).len == 1 and ex.tag(ex.args(inner)[0]) == .concat) inner = ex.args(inner)[0];
            try w.writeByte('{');
            try decompile(w, f, ex.lhs(id));
            try decompile(w, f, inner);
            try w.writeByte('}');
        },
        .assign_pattern => try list(w, f, "'{", ex.args(id), "}"),
        .pattern_repl => {
            try w.writeAll("'{");
            try decompile(w, f, ex.lhs(id));
            try list(w, f, "{", ex.args(ex.rhs(id)), "}");
            try w.writeByte('}');
        },
        .index => {
            try operand(w, f, ex.lhs(id), unary_prec + 1, false);
            try w.writeByte('[');
            try decompile(w, f, ex.rhs(id));
            try w.writeByte(']');
        },
        .range => {
            try decompile(w, f, ex.lhs(id));
            try w.writeByte(':');
            try decompile(w, f, ex.rhs(id));
        },
        .indexed_range => {
            try decompile(w, f, ex.lhs(id));
            try w.writeAll(if (ex.extraOf(id) == 0) " +: " else " -: ");
            try decompile(w, f, ex.rhs(id));
        },
        .event_or => {
            try decompile(w, f, ex.lhs(id));
            try w.writeAll(" or ");
            try decompile(w, f, ex.rhs(id));
        },
        .event_posedge => {
            try w.writeAll("posedge ");
            try decompile(w, f, ex.lhs(id));
        },
        .event_negedge => {
            try w.writeAll("negedge ");
            try decompile(w, f, ex.lhs(id));
        },
        .event_driver_update => {
            try w.writeAll("driver_update ");
            try decompile(w, f, ex.lhs(id));
        },
        .event_initial_step, .event_final_step => {
            try w.writeAll(if (ex.tag(id) == .event_initial_step) "initial_step" else "final_step");
            const names = ex.nameParts(id);
            if (names.len != 0) {
                try w.writeByte('(');
                for (names, 0..) |n, k| try w.print("{s}\"{s}\"", .{ if (k == 0) "" else ", ", f.str(n) });
                try w.writeByte(')');
            }
        },
    }
}

/// §26.6.19 g): a system or user task call, "a functionally equivalent
/// system task/function call to what was in the original HDL".
pub fn decompileCall(w: *Writer, f: *const Ast.SourceFile, id: Ast.StmtId) Writer.Error!void {
    const s = f.stmt(id).sys_task;
    try w.writeAll(f.str(s.name));
    if (s.args.len != 0) try list(w, f, "(", s.args, ")");
}

// ---- private ----

fn list(w: *Writer, f: *const Ast.SourceFile, open: []const u8, items: []const Ast.ExprId, close: []const u8) Writer.Error!void {
    try w.writeAll(open);
    for (items, 0..) |e, k| {
        if (k != 0) try w.writeAll(", ");
        try decompile(w, f, e);
    }
    try w.writeAll(close);
}

fn binaryPrec(op: Ast.BinaryOp) u8 {
    return switch (op) {
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
}

/// The precedence `id` binds at as an operand: its operator's, or above
/// every operator for a primary.
fn precOf(ex: *const Ast.ExprStore, id: Ast.ExprId) u8 {
    return switch (ex.tag(id)) {
        .unary => unary_prec,
        .binary => binaryPrec(ex.binOp(id)),
        .ternary => 0,
        // A primary: a literal, a name, a call, a select, a concatenation.
        .int_literal, .logic_literal, .real_literal, .str_literal, .pos_inf, .neg_inf, .ident, .hier_ident, .call, .builtin_call, .sys_call, .filter_call, .noise_call, .branch_access, .port_access, .concat, .multi_concat, .assign_pattern, .pattern_repl, .index, .range, .indexed_range, .event_or, .event_posedge, .event_negedge, .event_initial_step, .event_final_step, .event_function, .event_driver_update => unary_prec + 1,
    };
}

/// An operand of an operator of precedence `parent`, parenthesized when it
/// binds looser, or as loose on the right of a left-associative operator.
fn operand(w: *Writer, f: *const Ast.SourceFile, id: Ast.ExprId, parent: u8, right: bool) Writer.Error!void {
    const p = precOf(&f.exprs, id);
    const wrap = p < parent or (right and p == parent);
    if (wrap) try w.writeByte('(');
    try decompile(w, f, id);
    if (wrap) try w.writeByte(')');
}

fn unarySpelling(op: Ast.UnaryOp) []const u8 {
    return switch (op) {
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
}

fn binarySpelling(op: Ast.BinaryOp) []const u8 {
    return switch (op) {
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
