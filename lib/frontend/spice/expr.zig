//! A SPICE `{expr}` / `'expr'` value in, its real value over the
//! subcircuit's `PARAMS:` out (as Verilog-AMS text), or the reason it is
//! refused. Precedence climbing with an explicit depth-free loop over
//! operators; nesting is bounded by memory.
//! Cites: LRM annex E.1.2 (VerA's claimed subset of HSPICE expressions).
//!
//! Contents:
//! - `pub const expr_fns = [_][]const u8`
//! - `pub const Expr = union(enum)`
//! - `pub fn expression(arena: Allocator, src: []const u8, scope: []const []const u8) Allocator.Error!Expr`
//! - `pub const ExprParser = struct`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const spice_cards = @import("../spice_cards.zig");
const Refusal = spice_cards.Refusal;
const File = spice_cards.File;
const deep_stack = @import("base").deep_stack;
const spice_names = @import("names.zig");
const spiceNumber = spice_names.spiceNumber;
const spell = spice_names.spell;

/// The functions a SPICE expression may call: each means the same in HSPICE
/// and ngspice as in §4.3.1-4.3.2 (`log`, natural in SPICE and base 10 here, is
/// not one).
pub const expr_fns = [_][]const u8{ "sqrt", "exp", "abs", "min", "max", "pow", "sin", "cos", "tan", "asin", "acos", "atan", "sinh", "cosh", "tanh", "floor", "ceil" };

/// What `expression` makes of a SPICE expression.
pub const Expr = union(enum) {
    /// Verilog-AMS source with the same value.
    text: []const u8,
    /// Why it is not read, to follow "the expression value `{...}`".
    refused: []const u8,
};

/// `expression`'s recursive descent. Each rule returns its Verilog-AMS
/// text, or null with `why` set.
pub const ExprParser = struct {
    arena: Allocator,
    src: []const u8,
    scope: []const []const u8,
    i: usize = 0,
    why: ?[]const u8 = null,
    /// `unary` frames open; every recursive rule passes through `unary`.
    depth: u32 = 0,

    /// `unary` levels one stack segment holds (`deep_stack`).
    const segment = 1024;

    fn refuse(p: *ExprParser, comptime fmt: []const u8, args: anytype) Allocator.Error!?[]const u8 {
        assert(p.i <= p.src.len);
        const i_in = p.i;
        defer assert(p.i >= i_in);
        if (p.why == null) p.why = try p.arena.print(fmt, args);
        return null;
    }

    fn skip(p: *ExprParser) void {
        assert(p.i <= p.src.len);
        const i_in = p.i;
        defer assert(p.i >= i_in);
        while (p.i < p.src.len and (p.src[p.i] == ' ' or p.src[p.i] == '\t')) p.i += 1;
    }

    /// Consumes `tok` after blanks when it is next. `*` is not taken from
    /// the front of a `**`.
    fn eat(p: *ExprParser, tok: []const u8) bool {
        assert(p.i <= p.src.len);
        const i_in = p.i;
        defer assert(p.i >= i_in);
        p.skip();
        if (!std.mem.startsWith(u8, p.src[p.i..], tok)) return false;
        if (std.mem.eql(u8, tok, "*") and std.mem.startsWith(u8, p.src[p.i..], "**")) return false;
        p.i += tok.len;
        return true;
    }

    /// sum := product (('+' | '-') product)*
    fn sum(p: *ExprParser) Allocator.Error!?[]const u8 {
        assert(p.i <= p.src.len);
        const i_in = p.i;
        defer assert(p.i >= i_in);
        var acc = try p.product() orelse return null;
        while (true) {
            const op: []const u8 = if (p.eat("+")) "+" else if (p.eat("-")) "-" else return acc;
            const rhs = try p.product() orelse return null;
            acc = try p.arena.print("({s} {s} {s})", .{ acc, op, rhs });
        }
    }

    /// product := unary (('*' | '/') unary)*
    fn product(p: *ExprParser) Allocator.Error!?[]const u8 {
        assert(p.i <= p.src.len);
        const i_in = p.i;
        defer assert(p.i >= i_in);
        var acc = try p.unary() orelse return null;
        while (true) {
            const op: []const u8 = if (p.eat("*")) "*" else if (p.eat("/")) "/" else return acc;
            const rhs = try p.unary() orelse return null;
            acc = try p.arena.print("({s} {s} {s})", .{ acc, op, rhs });
        }
    }

    /// unary := ('+' | '-') unary | power
    fn unary(p: *ExprParser) Allocator.Error!?[]const u8 {
        assert(p.i <= p.src.len);
        const i_in = p.i;
        defer assert(p.i >= i_in);
        if (p.depth == 0 or p.depth % segment != 0) return p.unaryHere();
        return deep_stack.run(segment, unaryHere, .{p}) catch |e| switch (e) {
            error.DeepStackUnavailable => p.refuse("nests {d} levels deep, past the stack memory allows", .{p.depth}),
            error.OutOfMemory => |oom| oom,
        };
    }

    fn unaryHere(p: *ExprParser) Allocator.Error!?[]const u8 {
        assert(p.i <= p.src.len);
        const i_in = p.i;
        defer assert(p.i >= i_in);
        p.depth += 1;
        defer p.depth -= 1;
        if (p.eat("-")) return try p.arena.print("(-{s})", .{try p.unary() orelse return null});
        if (p.eat("+")) return p.unary();
        return p.power();
    }

    /// power := atom ('**' unary)?
    fn power(p: *ExprParser) Allocator.Error!?[]const u8 {
        assert(p.i <= p.src.len);
        const i_in = p.i;
        defer assert(p.i >= i_in);
        const base = try p.atom() orelse return null;
        if (!p.eat("**")) return base;
        return try p.arena.print("({s} ** {s})", .{ base, try p.unary() orelse return null });
    }

    /// atom := number | name | function '(' sum (',' sum)* ')' | '(' sum ')'
    fn atom(p: *ExprParser) Allocator.Error!?[]const u8 {
        assert(p.i <= p.src.len);
        const i_in = p.i;
        defer assert(p.i >= i_in);
        p.skip();
        if (p.i == p.src.len) return p.refuse("ends before an operand", .{});
        const c = p.src[p.i];
        if (c == '(') {
            p.i += 1;
            const e = try p.sum() orelse return null;
            if (!p.eat(")")) return p.refuse("has a `(` with no `)`", .{});
            return e;
        }
        if (std.ascii.isDigit(c) or c == '.') {
            const start = p.i;
            while (p.i < p.src.len and (std.ascii.isDigit(p.src[p.i]) or p.src[p.i] == '.')) p.i += 1;
            // A complete exponent only, as `spiceNumber` reads one.
            if (p.i + 1 < p.src.len and p.src[p.i] == 'e') {
                var j = p.i + 1;
                if (p.src[j] == '+' or p.src[j] == '-') j += 1;
                if (j < p.src.len and std.ascii.isDigit(p.src[j])) {
                    while (j < p.src.len and std.ascii.isDigit(p.src[j])) j += 1;
                    p.i = j;
                }
            }
            // The scale letter and any unit letters after it.
            while (p.i < p.src.len and std.ascii.isAlphabetic(p.src[p.i])) p.i += 1;
            const v = spiceNumber(p.src[start..p.i]) orelse return p.refuse("has `{s}`, which is not a number", .{p.src[start..p.i]});
            return try p.arena.print("{e}", .{v});
        }
        if (std.ascii.isAlphabetic(c) or c == '_') {
            const start = p.i;
            while (p.i < p.src.len and (std.ascii.isAlphanumeric(p.src[p.i]) or p.src[p.i] == '_')) p.i += 1;
            const name = p.src[start..p.i];
            if (p.eat("(")) {
                for (expr_fns) |f| {
                    if (std.mem.eql(u8, f, name)) break;
                } else return p.refuse("calls `{s}`, which is not one of sqrt, exp, abs, min, max, pow, sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, floor, ceil", .{name});
                var args: std.ArrayList(u8) = .empty;
                while (true) {
                    const a = try p.sum() orelse return null;
                    if (args.items.len != 0) try args.appendSlice(p.arena, ", ");
                    try args.appendSlice(p.arena, a);
                    if (p.eat(",")) continue;
                    if (p.eat(")")) break;
                    return p.refuse("has a `{s}(` with no `)`", .{name});
                }
                return try p.arena.print("{s}({s})", .{ name, args.items });
            }
            for (p.scope) |s| if (std.mem.eql(u8, s, name)) return try spell(p.arena, name);
            return p.refuse("reads `{s}`, which names no parameter in scope (the subcircuit's PARAMS: before it; a `.param` is not read)", .{name});
        }
        return p.refuse("has `{c}`, which is not read", .{c});
    }
};

/// A SPICE expression (the inside of `{...}` or `'...'`) as Verilog-AMS
/// text. Read: numbers in SPICE's scaled notation, written as real literals
/// (`1k` is `1e3`, and `1/3` is a third, not §4.2.1's integer 0); the names in
/// `scope`, a subcircuit's parameters; `+ - * /`; `**`, HSPICE's power; unary
/// `+` and `-`; parentheses; and the `expr_fns` calls. Power binds tighter
/// than a unary minus on its left (`-2**2` is -4), and every operation is
/// parenthesized, so the grammar's precedence is the text's. Anything else
/// (`.param` names, `^`, comparisons, `?:`, other functions) is refused.
/// Nesting (parentheses, calls, unary signs) has no bound but memory: the
/// recursion continues on a fresh stack segment every `ExprParser.segment`
/// levels.
pub fn expression(arena: Allocator, src: []const u8, scope: []const []const u8) Allocator.Error!Expr {
    var p: ExprParser = .{ .arena = arena, .src = src, .scope = scope };
    const text = try p.sum() orelse return .{ .refused = p.why.? };
    // Every `unary` frame closed on the way out.
    assert(p.depth == 0);
    p.skip();
    if (p.i != src.len) return .{ .refused = try arena.print("has `{s}` after a complete expression", .{src[p.i..]}) };
    return .{ .text = text };
}
