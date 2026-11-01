//! An IEEE 1364 expression or lvalue in, an RTLIL sigspec out: a name, a
//! constant, a select of a declared vector, or a `$`-cell per operator over
//! its operands' sigspecs, at §5.4's widths and §5.5's signedness.
//!
//! Clauses: IEEE 1364-2005 §5.1 (operators), §5.2.1 (selects), §5.4.1
//! (Table 5-22's widths), §5.5 (signedness), A.8.5 (lvalues), §17.11.1.
//!
//! Contents:
//! - `pub fn shape(self: *Emitter, e: ExprId) Error!Sig`
//! - `pub fn expr(self: *Emitter, e: ExprId, ctx: u32) Error!Sig`
//! - `pub fn select(self: *Emitter, e: ExprId) Error!Sig`
//! - `pub fn slice(self: *Emitter, root: Sig, s: Sym, hi: i128, lo: i128, tok: u32) Error!Sig`
//! - `pub fn lvalue(self: *Emitter, e: ExprId, in_proc: bool) Error!Sig`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const fold = @import("rtlil_fold.zig");
const rtlil_emitter = @import("rtlil_emitter.zig");
const rtlil_table = @import("rtlil_table.zig");
const Emitter = rtlil_emitter.Emitter;
const Error = rtlil_emitter.Error;
const Sym = rtlil_table.Sym;
const Sig = rtlil_table.Sig;
const Writer = std.Io.Writer;
const ExprId = Ast.ExprId;

/// §5.4.1 the self-determined width of `e`, and §5.5.1 its signedness,
/// computed once per expression (`Emitter.shapes`): `expr` asks it at every
/// level, which would be quadratic in the nesting otherwise.
pub fn shape(self: *Emitter, e: ExprId) Error!Sig {
    assert(e != .none);
    const memo = &self.shapes[@backingInt(e)];
    if (memo.w != 0) return .{ .s = "", .w = memo.w, .signed = memo.signed };
    const s = try shapeOf(self, e);
    assert(s.w >= 1);
    memo.* = .{ .w = s.w, .signed = s.signed };
    return s;
}

/// `e` as a sigspec of at least `ctx` bits (§5.4: a context-determined
/// operand is evaluated at the context's width), or exactly its own for a
/// self-determined one. `fit` sizes the result for an assignment.
pub fn expr(self: *Emitter, e: ExprId, ctx: u32) Error!Sig {
    assert(e != .none);
    const ex = &self.file.exprs;
    const tok = ex.mainTok(e);
    try self.deeper(tok);
    const own = try self.shape(e);
    const w = @max(own.w, ctx);
    switch (ex.tag(e)) {
        .int_literal => {
            const l = ex.intLiteral(e);
            return self.constSig(l.value, w, l.signed);
        },
        .logic_literal => return self.logicSig(ex.logicValue(e)),
        .ident => {
            const name = ex.strOf(e);
            const s = self.syms.get(name).?;
            if (s.kind == .param) {
                const v = self.syms.value(name) orelse return self.refuse(tok, "a real parameter in an expression", .{});
                return self.logicSig(v);
            }
            if (self.proc) |p| if (self.syms.rows.items(.redirect_proc)[self.syms.find(name).?] == p.index) return self.syms.temp(name, p.index);
            return .{ .s = try self.id(name), .w = s.width, .signed = s.signed };
        },
        .unary => {
            const op = ex.unOp(e);
            const a = try self.expr(ex.lhs(e), if (op == .plus or op == .minus or op == .bit_not) w else 0);
            return switch (op) {
                .plus => a,
                .minus => self.cell1("$neg", a, w, own.signed),
                .bit_not => self.cell1("$not", a, w, own.signed),
                .logical_not => self.cell1("$logic_not", a, 1, false),
                .reduce_and => self.cell1("$reduce_and", a, 1, false),
                .reduce_or => self.cell1("$reduce_or", a, 1, false),
                .reduce_xor => self.cell1("$reduce_xor", a, 1, false),
                .reduce_xnor => self.cell1("$reduce_xnor", a, 1, false),
                .reduce_nand => self.cell1("$not", try self.cell1("$reduce_and", a, 1, false), 1, false),
                .reduce_nor => self.cell1("$not", try self.cell1("$reduce_or", a, 1, false), 1, false),
            };
        },
        .binary => {
            const op = ex.binOp(e);
            // §5.4.1 Table 5-22: the operands' context widths.
            const a_ctx: u32, const b_ctx: u32 = switch (op) {
                .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => .{ w, w },
                // The right operand is self-determined.
                .pow, .shl, .shr, .ashl, .ashr => .{ w, 0 },
                .logical_and, .logical_or => .{ 0, 0 },
                // A comparison's operands take each other's width.
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge => blk: {
                    const cmp_w = @max((try self.shape(ex.lhs(e))).w, (try self.shape(ex.rhs(e))).w);
                    break :blk .{ cmp_w, cmp_w };
                },
            };
            const a = try self.expr(ex.lhs(e), a_ctx);
            const b = try self.expr(ex.rhs(e), b_ctx);
            const both = a.signed and b.signed;
            return switch (op) {
                .add => self.cell2("$add", a, b, both, w, both),
                .sub => self.cell2("$sub", a, b, both, w, both),
                .mul => self.cell2("$mul", a, b, both, w, both),
                .div => self.cell2("$div", a, b, both, w, both),
                .mod => self.cell2("$mod", a, b, both, w, both),
                .pow => self.cell2("$pow", a, b, both, w, both),
                .bit_and => self.cell2("$and", a, b, both, w, both),
                .bit_or => self.cell2("$or", a, b, both, w, both),
                .bit_xor => self.cell2("$xor", a, b, both, w, both),
                .bit_xnor => self.cell2("$xnor", a, b, both, w, both),
                .eq => self.cell2("$eq", a, b, both, 1, false),
                .neq => self.cell2("$ne", a, b, both, 1, false),
                .case_eq => self.cell2("$eqx", a, b, both, 1, false),
                .case_neq => self.cell2("$nex", a, b, both, 1, false),
                .lt => self.cell2("$lt", a, b, both, 1, false),
                .le => self.cell2("$le", a, b, both, 1, false),
                .gt => self.cell2("$gt", a, b, both, 1, false),
                .ge => self.cell2("$ge", a, b, both, 1, false),
                .logical_and => self.cell2("$logic_and", a, b, false, 1, false),
                .logical_or => self.cell2("$logic_or", a, b, false, 1, false),
                .shl => self.cell2("$shl", a, b, a.signed, w, a.signed),
                .shr => self.cell2("$shr", a, b, a.signed, w, a.signed),
                .ashl => self.cell2("$sshl", a, b, a.signed, w, a.signed),
                .ashr => self.cell2("$sshr", a, b, a.signed, w, a.signed),
            };
        },
        .ternary => {
            const s = try self.bool1(ex.lhs(e));
            const b = try self.fit(try self.expr(ex.rhs(e), w), w);
            const a = try self.fit(try self.expr(ex.ternaryElse(e), w), w);
            return self.mux(s, a, b, w, own.signed);
        },
        .concat => {
            const parts = ex.args(e);
            if (parts.len == 1) return self.fit(try self.expr(parts[0], 0), own.w);
            var buf: Writer.Allocating = .init(self.arena);
            try concatInto(self, e, &buf.writer);
            return .{ .s = buf.written(), .w = own.w };
        },
        .multi_concat => {
            const n = (try self.foldInt(ex.lhs(e), tok)).?;
            const inner = try self.expr(ex.rhs(e), 0);
            const one = try self.fit(inner, (try self.shape(ex.rhs(e))).w);
            var buf: Writer.Allocating = .init(self.arena);
            try buf.writer.writeAll("{");
            for (0..@intCast(n)) |_| try buf.writer.print(" {s}", .{one.s});
            try buf.writer.writeAll(" }");
            return .{ .s = buf.written(), .w = own.w };
        },
        .index => return self.select(e),
        .sys_call => {
            const n = self.str(ex.strOf(e));
            const args = ex.args(e);
            if (std.mem.eql(u8, n, "$clog2")) {
                const v = (try self.foldInt(e, tok)) orelse return self.refuse(tok, "`$clog2` of a non-constant", .{});
                return self.constSig(v, w, true);
            }
            var a = try self.expr(args[0], 0);
            a.signed = std.mem.eql(u8, n, "$signed");
            return a;
        },
        else => unreachable, // else: `shape` refused every other tag
    }
}

/// `base[i]`, `base[hi:lo]`, `base[i +: w]`: a slice of the base, which
/// must name a declared wire or reg; a variable bit index is a `$shiftx`.
pub fn select(self: *Emitter, e: ExprId) Error!Sig {
    assert(self.file.exprs.tag(e) == .index);
    const ex = &self.file.exprs;
    const tok = ex.mainTok(e);
    const base = ex.lhs(e);
    if (ex.tag(base) != .ident) return self.refuse(tok, "a select of something that is not a declared name", .{});
    const name = ex.strOf(base);
    const s = self.syms.get(name) orelse return self.refuse(tok, "`{s}` is not declared in this module", .{self.str(name)});
    if (s.kind == .param) return self.refuse(tok, "a select of a parameter", .{});
    const root = try self.expr(base, 0);
    const sel = ex.rhs(e);
    switch (ex.tag(sel)) {
        .range => {
            const hi = (try self.foldInt(ex.lhs(sel), tok)).?;
            const lo = (try self.foldInt(ex.rhs(sel), tok)).?;
            return self.slice(root, s, @max(hi, lo), @min(hi, lo), tok);
        },
        .indexed_range => {
            const w = (try self.foldInt(ex.rhs(sel), tok)).?;
            const b = (try self.foldInt(ex.lhs(sel), tok)) orelse return self.refuse(tok, "an indexed part-select with a variable base", .{});
            const up = ex.extraOf(sel) == 0;
            // §5.2.1: `+:` runs from the base upward, `-:` downward, in the source's numbering.
            const lo: i128 = if (up) b else @as(i128, b) - w + 1;
            return self.slice(root, s, lo + w - 1, lo, tok);
        },
        else => {}, // else: a bit select
    }
    if (try self.foldInt(sel, tok)) |i| return self.slice(root, s, i, i, tok);
    if (!s.descending) return self.refuse(tok, "a variable bit select of an ascending (`[lo:hi]`) vector", .{});
    var idx = try self.expr(sel, 0);
    if (s.lsb != 0) idx = try self.cell2("$sub", idx, try self.constSig(s.lsb, idx.w, false), false, idx.w, false);
    return self.cell2("$shiftx", root, idx, false, 1, false);
}

/// `root [hi:lo]` in RTLIL positions, bounds in the source's numbering.
pub fn slice(self: *Emitter, root: Sig, s: Sym, hi: i128, lo: i128, tok: u32) Error!Sig {
    assert(s.width >= 1);
    assert(hi >= lo);
    const p_hi = if (s.descending) hi - s.lsb else s.lsb - lo;
    const p_lo = if (s.descending) lo - s.lsb else s.lsb - hi;
    if (p_lo < 0 or p_hi >= s.width) return self.refuse(tok, "a select outside the declared range", .{});
    const w: u32 = @intCast(p_hi - p_lo + 1);
    if (w == s.width) return root;
    return .{
        .s = if (p_hi == p_lo) try self.arena.print("{s} [{d}]", .{ root.s, p_lo }) else try self.arena.print("{s} [{d}:{d}]", .{ root.s, p_hi, p_lo }),
        .w = w,
        .signed = false,
    };
}

/// An A.8.5 `net_lvalue` / `variable_lvalue` as a sigspec: a name, a
/// constant select of one, or a concatenation of those. `in_proc`: the
/// name must be a reg the process owns, and its temp is the target.
pub fn lvalue(self: *Emitter, e: ExprId, in_proc: bool) Error!Sig {
    assert(e != .none);
    assert(in_proc == (self.proc != null));
    const ex = &self.file.exprs;
    const tok = ex.mainTok(e);
    try self.deeper(tok);
    switch (ex.tag(e)) {
        .concat => {
            var buf: Writer.Allocating = .init(self.arena);
            const w = try lvalueConcatInto(self, e, in_proc, &buf.writer);
            return .{ .s = buf.written(), .w = w };
        },
        .ident, .index => {
            const base = self.file.lvalueBase(e);
            if (base == .none) return self.refuse(tok, "an assignment target that is not a declared name", .{});
            const name = ex.strOf(base);
            const s = self.syms.get(name) orelse return self.refuse(tok, "`{s}` is not declared in this module", .{self.str(name)});
            if (s.kind == .param) return self.refuse(tok, "an assignment to parameter `{s}`", .{self.str(name)});
            const root: Sig = if (in_proc) blk: {
                const p = self.proc.?;
                if (s.kind != .reg) return self.refuse(tok, "a procedural assignment to the net `{s}`", .{self.str(name)});
                break :blk self.syms.temp(name, p.index);
            } else .{ .s = try self.id(name), .w = s.width, .signed = s.signed };
            if (ex.tag(e) == .ident) return root;
            const sel = ex.rhs(e);
            if (ex.tag(ex.lhs(e)) != .ident) return self.refuse(tok, "a select of a select", .{});
            switch (ex.tag(sel)) {
                .range => {
                    const hi = (try self.foldInt(ex.lhs(sel), tok)) orelse return self.refuse(tok, "a part-select bound that is not constant", .{});
                    const lo = (try self.foldInt(ex.rhs(sel), tok)) orelse return self.refuse(tok, "a part-select bound that is not constant", .{});
                    return self.slice(root, s, @max(hi, lo), @min(hi, lo), tok);
                },
                .indexed_range => return self.refuse(tok, "an indexed part-select as an assignment target", .{}),
                else => {}, // else: a bit select
            }
            const i = (try self.foldInt(sel, tok)) orelse return self.refuse(tok, "a variable bit select as an assignment target", .{});
            return self.slice(root, s, i, i, tok);
        },
        else => return self.refuse(tok, "an assignment target that is not a name, a select or a concatenation", .{}), // else: A.8.5 admits nothing else
    }
}

// ---- private ----

/// `shape` of an expression not yet memoized.
fn shapeOf(self: *Emitter, e: ExprId) Error!Sig {
    assert(e != .none);
    const ex = &self.file.exprs;
    const tok = ex.mainTok(e);
    try self.deeper(tok);
    return switch (ex.tag(e)) {
        .int_literal => blk: {
            const l = ex.intLiteral(e);
            break :blk .{ .s = "", .w = if (l.width == 0) 32 else l.width, .signed = l.signed };
        },
        .logic_literal => blk: {
            const l = ex.logicValue(e);
            break :blk .{ .s = "", .w = l.width, .signed = l.signed };
        },
        .ident => blk: {
            const s = self.syms.get(ex.strOf(e)) orelse return self.refuse(tok, "`{s}` is not declared in this module", .{self.str(ex.strOf(e))});
            break :blk .{ .s = "", .w = s.width, .signed = s.signed };
        },
        .unary => blk: {
            const a = try self.shape(ex.lhs(e));
            break :blk switch (ex.unOp(e)) {
                .plus, .minus, .bit_not => a,
                .logical_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => .{ .s = "", .w = 1 },
            };
        },
        .binary => blk: {
            const a = try self.shape(ex.lhs(e));
            const b = try self.shape(ex.rhs(e));
            break :blk switch (ex.binOp(e)) {
                .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => .{ .s = "", .w = @max(a.w, b.w), .signed = a.signed and b.signed },
                .pow, .shl, .shr, .ashl, .ashr => .{ .s = "", .w = a.w, .signed = a.signed },
                .eq, .neq, .case_eq, .case_neq, .lt, .le, .gt, .ge, .logical_and, .logical_or => .{ .s = "", .w = 1 },
            };
        },
        .ternary => blk: {
            const a = try self.shape(ex.rhs(e));
            const b = try self.shape(ex.ternaryElse(e));
            break :blk .{ .s = "", .w = @max(a.w, b.w), .signed = a.signed and b.signed };
        },
        .concat => blk: {
            var w: u32 = 0;
            for (ex.args(e)) |a| w += (try self.shape(a)).w;
            break :blk .{ .s = "", .w = w };
        },
        .multi_concat => blk: {
            const n = (try self.foldInt(ex.lhs(e), tok)) orelse return self.refuse(tok, "a replication count that is not constant", .{});
            if (n <= 0) return self.refuse(tok, "a replication count of {d}", .{n});
            const rw = @as(i128, (try self.shape(ex.rhs(e))).w) * n;
            if (rw > fold.max_width) return self.refuse(tok, "a replication wider than {d} bits", .{fold.max_width});
            break :blk .{ .s = "", .w = @intCast(rw) };
        },
        .index => blk: {
            if (ex.tag(ex.rhs(e)) == .range) {
                const r = ex.rhs(e);
                const hi = (try self.foldInt(ex.lhs(r), tok)) orelse return self.refuse(tok, "a part-select bound that is not constant", .{});
                const lo = (try self.foldInt(ex.rhs(r), tok)) orelse return self.refuse(tok, "a part-select bound that is not constant", .{});
                // A select wider than any RTLIL wire is outside its declared range.
                const span = @abs(@as(i128, hi) - lo) + 1;
                if (span > std.math.maxInt(i32)) return self.refuse(tok, "a select outside the declared range", .{});
                break :blk .{ .s = "", .w = @intCast(span) };
            }
            if (ex.tag(ex.rhs(e)) == .indexed_range) {
                const w = (try self.foldInt(ex.rhs(ex.rhs(e)), tok)) orelse return self.refuse(tok, "an indexed part-select width that is not constant", .{});
                if (w <= 0) return self.refuse(tok, "an indexed part-select width of {d}", .{w});
                if (w > std.math.maxInt(i32)) return self.refuse(tok, "a select outside the declared range", .{});
                break :blk .{ .s = "", .w = @intCast(w) };
            }
            break :blk .{ .s = "", .w = 1 };
        },
        .sys_call => blk: {
            const n = self.str(ex.strOf(e));
            const args = ex.args(e);
            if (std.mem.eql(u8, n, "$signed") and args.len == 1) break :blk .{ .s = "", .w = (try self.shape(args[0])).w, .signed = true };
            if (std.mem.eql(u8, n, "$unsigned") and args.len == 1) break :blk .{ .s = "", .w = (try self.shape(args[0])).w };
            if (std.mem.eql(u8, n, "$clog2")) break :blk .{ .s = "", .w = 32, .signed = true };
            return self.refuse(tok, "the system function `{s}`", .{n});
        },
        .real_literal => return self.refuse(tok, "a real literal", .{}),
        .str_literal => return self.refuse(tok, "a string literal", .{}),
        .hier_ident => return self.refuse(tok, "a hierarchical reference", .{}),
        .call => return self.refuse(tok, "a function call", .{}),
        else => return self.refuse(tok, "an expression no synthesizable design has here", .{}), // else: analog, event and range tags
    };
}

/// A concatenation of two or more parts as `{ a b ... }` into `w`. A part
/// that is itself one is written in place rather than built and copied, so
/// nested concatenations cost their length, not its square; the bytes are
/// what `expr` gives the part, since a concatenation's sigspec is exactly
/// its own width.
fn concatInto(self: *Emitter, e: ExprId, w: *Writer) Error!void {
    const ex = &self.file.exprs;
    assert(ex.tag(e) == .concat);
    assert(ex.args(e).len >= 2);
    try self.deeper(ex.mainTok(e));
    try w.writeAll("{");
    for (ex.args(e)) |a| {
        if (ex.tag(a) == .concat and ex.args(a).len >= 2) {
            try w.writeByte(' ');
            try concatInto(self, a, w);
            continue;
        }
        const s = try self.expr(a, 0);
        try w.print(" {s}", .{(try self.fit(s, (try self.shape(a)).w)).s});
    }
    try w.writeAll(" }");
}

/// An lvalue concatenation as `{ a b ... }` into `w`, nested ones in place
/// (as `concatInto`); returns its width.
fn lvalueConcatInto(self: *Emitter, e: ExprId, in_proc: bool, w: *Writer) Error!u32 {
    const ex = &self.file.exprs;
    assert(ex.tag(e) == .concat);
    try self.deeper(ex.mainTok(e));
    var width: u32 = 0;
    try w.writeAll("{");
    for (ex.args(e)) |a| {
        if (ex.tag(a) == .concat) {
            try w.writeByte(' ');
            width += try lvalueConcatInto(self, a, in_proc, w);
            continue;
        }
        const s = try self.lvalue(a, in_proc);
        width += s.w;
        try w.print(" {s}", .{s.s});
    }
    try w.writeAll(" }");
    assert(width >= 1);
    return width;
}
