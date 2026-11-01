//! The state `rtlil.emit` carries through one source, and the sigspec and
//! cell writers every transformation shares: a module's symbol and value
//! tables, its wire and cell text, the `always` block being emitted, the
//! fresh-name counter, and the refusal (`why`, uncoded) or design error
//! (E1100, in the bag) that ends the run. The transformations are
//! `rtlil_module.zig` (the design, its declarations and drivers),
//! `rtlil_expr.zig` (expressions and lvalues), `rtlil_proc.zig` (`initial`
//! and `always` blocks) and `rtlil_fold.zig` (constants).
//!
//! Clauses: IEEE 1364-2005 §5.5 (an operand's extension), §12.1.2 (E1100).
//!
//! Contents:
//! - `pub const Error`
//! - `pub const Proc`
//! - `pub const Shape`
//! - `pub const Emitter`
//! - `pub const design = rtlil_module.design`
//! - `pub const module = rtlil_module.module`
//! - `pub const dim = rtlil_module.dim`
//! - `pub const params = rtlil_module.params`
//! - `pub const declare = rtlil_module.declare`
//! - `pub const redeclared = rtlil_module.redeclared`
//! - `pub const wireLines = rtlil_module.wireLines`
//! - `pub const wireLine = rtlil_module.wireLine`
//! - `pub const contAssign = rtlil_module.contAssign`
//! - `pub const gate = rtlil_module.gate`
//! - `pub const instance = rtlil_module.instance`
//! - `pub const shape = rtlil_expr.shape`
//! - `pub const expr = rtlil_expr.expr`
//! - `pub const select = rtlil_expr.select`
//! - `pub const slice = rtlil_expr.slice`
//! - `pub const lvalue = rtlil_expr.lvalue`
//! - `pub const initial = rtlil_proc.initial`
//! - `pub const flatten = rtlil_proc.flatten`
//! - `pub const always = rtlil_proc.always`
//! - `pub const eventTerms = rtlil_proc.eventTerms`
//! - `pub const assigned = rtlil_proc.assigned`
//! - `pub const stmt = rtlil_proc.stmt`
//! - `pub fn refuse(self: *Emitter, tok: u32, comptime fmt: []const u8, args: anytype) Error`
//! - `pub fn deeper(self: *Emitter, tok: u32) Error!void`
//! - `pub fn designError(self: *Emitter, tok: u32, comptime message: []const u8) Error`
//! - `pub fn str(self: *const Emitter, name: StrId) []const u8`
//! - `pub fn id(self: *Emitter, name: StrId) ![]const u8`
//! - `pub fn fresh(self: *Emitter, comptime kind: u8) ![]const u8`
//! - `pub fn temp(self: *Emitter, w: u32, signed: bool) !Sig`
//! - `pub fn foldValue(self: *Emitter, e: ExprId, ctx: u32, tok: u32, comptime real: bool) Error!?fold.Literal`
//! - `pub fn foldInt(self: *Emitter, e: ExprId, tok: u32) Error!?i64`
//! - `pub fn convert(self: *Emitter, v: fold.Literal, sym: Sym) Error!fold.Literal`
//! - `pub fn constSig(self: *Emitter, v: i64, w: u32, signed: bool) !Sig`
//! - `pub fn logicSig(self: *Emitter, l: Integer.Literal) !Sig`
//! - `pub fn fit(self: *Emitter, sig: Sig, w: u32) Error!Sig`
//! - `pub fn bool1(self: *Emitter, e: ExprId) Error!Sig`
//! - `pub fn cell1(self: *Emitter, kind: []const u8, a: Sig, yw: u32, ysigned: bool) Error!Sig`
//! - `pub fn cell2(self: *Emitter, kind: []const u8, a: Sig, b: Sig, signed: bool, yw: u32, ysigned: bool) Error!Sig`
//! - `pub fn mux(self: *Emitter, s: Sig, a: Sig, b: Sig, w: u32, signed: bool) Error!Sig`
//! - `pub fn indent(self: *Emitter, p: *Proc) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const diag = @import("diag");
const deep = @import("base").deep_stack;
const Integer = @import("kernels").Integer;
const fold = @import("rtlil_fold.zig");
const rtlil_table = @import("rtlil_table.zig");
const rtlil_module = @import("rtlil_module.zig");
const rtlil_expr = @import("rtlil_expr.zig");
const rtlil_proc = @import("rtlil_proc.zig");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ExprId = Ast.ExprId;
const StrId = Ast.StrId;
const Table = rtlil_table.Table;
const Sym = rtlil_table.Sym;
const Sig = rtlil_table.Sig;

/// `rtlil.Error`: `Refused` names a construct outside the subset in `why`;
/// `DigitalFailed` leaves the diagnostics in the bag.
pub const Error = error{ OutOfMemory, WriteFailed, Refused, DigitalFailed };

/// The state of one `always` block's `process`. Its temps, and the regs a
/// blocking assignment has written so far, are the module rows' `temp` and
/// `redirect_proc` columns under its `index`: a read after a blocking write
/// takes the temp (§9.2.1), a read before it or after a nonblocking one the
/// reg (§9.2.2).
pub const Proc = struct {
    /// The process's own writer; it is appended to the module's cells after.
    w: *Writer,
    index: u32,
    indent: usize = 2,
};

/// An expression's memoized `shape`: `w` 0 is not yet shaped (every
/// shaped expression is at least one bit wide).
pub const Shape = struct { w: u32 = 0, signed: bool = false };

/// One source's emission: the tables of the module being emitted, the text
/// written so far, and where a refusal goes.
pub const Emitter = struct {
    arena: Allocator,
    file: *const Ast.SourceFile,
    text: []const u8,
    starts: []const u32,
    out: *Writer,
    why: *[]const u8,
    bag: *diag.Bag,
    /// The module being emitted.
    m: *const Ast.ModuleDecl = undefined,
    /// The names `shape`, `expr` and `lvalue` read: `own` while a module is
    /// emitted, `child` while an instance folds its module's port widths.
    syms: *Table = undefined,
    own: Table = undefined,
    child: Table = undefined,
    /// Per `ExprId` of the file, its `shape` once computed: an expression
    /// belongs to one module, so the memo holds across modules.
    shapes: []Shape = &.{},
    /// The module's `wire` lines, then its cells, connects and processes:
    /// RTLIL declares a wire before a use.
    wires: Writer.Allocating = undefined,
    cells: Writer.Allocating = undefined,
    /// The `always` block being emitted, whose temps a read may take.
    proc: ?*Proc = null,
    /// `$vera$wN` and `$vera$cN`, unique in the file.
    next_id: u32 = 0,
    n_procs: u32 = 0,

    /// Every module of the file, after the design-level refusals (`rtlil_module`).
    pub const design = rtlil_module.design;
    /// One source module as one RTLIL `module` (`rtlil_module`).
    pub const module = rtlil_module.module;
    /// A declared `[msb:lsb]` folded into a `Sym`, or refused past RTLIL's `int`s.
    pub const dim = rtlil_module.dim;
    /// A module's parameters at their §12.2 types, into `syms` and `values`.
    pub const params = rtlil_module.params;
    /// Every port, net and variable of a module as a `Sym`.
    pub const declare = rtlil_module.declare;
    /// Whether a net or variable redeclares a port (merged) or anything else (E1100).
    pub const redeclared = rtlil_module.redeclared;
    /// A module's `wire` lines, ports first by header position.
    pub const wireLines = rtlil_module.wireLines;
    /// One `wire` line: width, sign, offset, `upto` and port number.
    pub const wireLine = rtlil_module.wireLine;
    /// A §6.1 continuous assign as a `connect`.
    pub const contAssign = rtlil_module.contAssign;
    /// An A.3.4 value gate as its cells and a `connect`.
    pub const gate = rtlil_module.gate;
    /// A module instance as a `cell`; a connection to no port is E1100.
    pub const instance = rtlil_module.instance;
    /// An expression's §5.4.1 self-determined width and §5.5.1 sign (`rtlil_expr`).
    pub const shape = rtlil_expr.shape;
    /// An expression as a sigspec, at a context width (`rtlil_expr`).
    pub const expr = rtlil_expr.expr;
    /// A bit-, part- or indexed part-select of a declared name.
    pub const select = rtlil_expr.select;
    /// A select in RTLIL bit positions, refused outside the declared range.
    pub const slice = rtlil_expr.slice;
    /// An assignment target as a sigspec, a process's temp inside one.
    pub const lvalue = rtlil_expr.lvalue;
    /// An `initial` block of constants as `init` attributes (`rtlil_proc`).
    pub const initial = rtlil_proc.initial;
    /// A block's statements through unnamed `begin`/`end` nesting.
    pub const flatten = rtlil_proc.flatten;
    /// An `always` block as one `process` (`rtlil_proc`).
    pub const always = rtlil_proc.always;
    /// An event expression's edges and levels.
    pub const eventTerms = rtlil_proc.eventTerms;
    /// The regs a statement writes, in first-write order.
    pub const assigned = rtlil_proc.assigned;
    /// A statement as a process's `assign` and `switch` lines.
    pub const stmt = rtlil_proc.stmt;

    /// Sets `why` to `line N: <what>` at token `tok` and returns `error.Refused`:
    /// a construct outside the subset, uncoded like every `--emit-rtlil` refusal.
    pub fn refuse(self: *Emitter, tok: u32, comptime fmt: []const u8, args: anytype) Error {
        const at = if (tok < self.starts.len) self.starts[tok] else 0;
        const line = 1 + std.mem.count(u8, self.text[0..@min(at, self.text.len)], "\n");
        const what = try self.arena.print(fmt, args);
        self.why.* = try self.arena.print("line {d}: {s}", .{ line, what });
        return error.Refused;
    }

    /// Refuses the step at token `tok` when it is within reach of the end
    /// of the stack `rtlil.emit` reserved (`deep_stack.exhausted`): every
    /// walk whose depth the source controls calls it before it recurses.
    pub fn deeper(self: *Emitter, tok: u32) Error!void {
        if (deep.exhausted()) return self.refuse(tok, deep.message, .{deep.mib()});
    }

    /// A design `vera --run` rejects, in its words: E1100 in the bag.
    pub fn designError(self: *Emitter, tok: u32, comptime message: []const u8) Error {
        assert(tok < self.starts.len);
        const at = self.starts[tok];
        self.bag.add(.lower, .E1100, .{ .start = at, .end = at }, message, .{}) catch return error.OutOfMemory;
        return error.DigitalFailed;
    }

    /// The interned text of `name`.
    pub fn str(self: *const Emitter, name: StrId) []const u8 {
        return self.file.str(name);
    }

    /// `\name`; an escaped identifier's own backslash is the same one.
    pub fn id(self: *Emitter, name: StrId) ![]const u8 {
        const s = self.str(name);
        return self.arena.print("\\{s}", .{if (s.len != 0 and s[0] == '\\') s[1..] else s});
    }

    /// A name no source identifier can take (`$vera$` and a counter).
    pub fn fresh(self: *Emitter, comptime kind: u8) ![]const u8 {
        self.next_id += 1;
        return self.arena.print("$vera${c}{d}", .{ kind, self.next_id });
    }

    /// A new private wire of `w` bits, declared in the module.
    pub fn temp(self: *Emitter, w: u32, signed: bool) !Sig {
        assert(w >= 1);
        const name = try self.fresh('w');
        try self.wires.writer.print("  wire width {d}{s} {s}\n", .{ w, if (signed) " signed" else "", name });
        return .{ .s = name, .w = w, .signed = signed };
    }

    /// `e` folded by IEEE 1364's rules (`rtlil_fold`) in a context `ctx`
    /// bits wide, or null when it is not constant.
    /// `real`: `e` is an assignment's right side, which may be a real literal.
    pub fn foldValue(self: *Emitter, e: ExprId, ctx: u32, tok: u32, comptime real: bool) Error!?fold.Literal {
        assert(e != .none);
        const folded = if (real) fold.assigned(self.arena, self.file, self.syms, e, ctx) else fold.fold(self.arena, self.file, self.syms, e, ctx);
        return folded catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TooWide => self.refuse(tok, "a constant wider than {d} bits", .{fold.max_width}),
            error.TooDeep => self.refuse(tok, "a constant expression nested deeper than {d} operators", .{fold.max_depth}),
        };
    }

    /// `e` as an integer constant, self-determined, or null when it is not
    /// constant, holds an x or z bit or is outside 64 bits signed.
    pub fn foldInt(self: *Emitter, e: ExprId, tok: u32) Error!?i64 {
        const v = (try self.foldValue(e, 0, tok, false)) orelse return null;
        return v.asExactInt();
    }

    /// `v` truncated or extended (by its own sign, §5.5) to `sym`'s type.
    pub fn convert(self: *Emitter, v: fold.Literal, sym: Sym) Error!fold.Literal {
        assert(sym.width != 0);
        var out = v.resize(self.arena, sym.width, if (v.signed) .sign else .zero) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ZeroSize => unreachable, // `sym.width` is asserted nonzero
        };
        out.signed = sym.signed;
        assert(out.width == sym.width);
        return out;
    }

    /// `W'bits` of the two's complement of `v`.
    pub fn constSig(self: *Emitter, v: i64, w: u32, signed: bool) !Sig {
        assert(w >= 1);
        var buf: Writer.Allocating = .init(self.arena);
        try buf.writer.print("{d}'", .{w});
        var i: u32 = w;
        while (i > 0) : (i -= 1) {
            const bit: u1 = if (i - 1 >= 64) @intCast(@as(u64, @bitCast(v)) >> 63) else @intCast((@as(u64, @bitCast(v)) >> @intCast(i - 1)) & 1);
            try buf.writer.writeByte('0' + @as(u8, bit));
        }
        return .{ .s = buf.written(), .w = w, .signed = signed };
    }

    /// A four-state literal, bit for bit (`x` and `z` are RTLIL constants too).
    pub fn logicSig(self: *Emitter, l: Integer.Literal) !Sig {
        assert(l.width >= 1);
        var buf: Writer.Allocating = .init(self.arena);
        try buf.writer.print("{d}'", .{l.width});
        var i: u32 = l.width;
        while (i > 0) : (i -= 1) {
            const k = i - 1;
            const word = k / 64;
            const v = if (word < l.values().len) (l.values()[word] >> @intCast(k % 64)) & 1 else 0;
            const u = if (word < l.unknowns().len) (l.unknowns()[word] >> @intCast(k % 64)) & 1 else 0;
            try buf.writer.writeByte(if (u == 0) ('0' + @as(u8, @intCast(v))) else if (v == 0) 'z' else 'x');
        }
        return .{ .s = buf.written(), .w = l.width, .signed = l.signed };
    }

    /// `sig` as exactly `w` bits: truncated, or extended per its sign (§5.5).
    pub fn fit(self: *Emitter, sig: Sig, w: u32) Error!Sig {
        assert(w >= 1 and sig.w >= 1);
        if (sig.w == w) return sig;
        if (sig.w > w) return .{ .s = try self.arena.print("{s} [{d}:0]", .{ sig.s, w - 1 }), .w = w, .signed = sig.signed };
        if (sig.signed) return self.cell1("$pos", sig, w, true);
        return .{ .s = try self.arena.print("{{ {d}'{s} {s} }}", .{ w - sig.w, try zeros(self.arena, w - sig.w), sig.s }), .w = w, .signed = false };
    }

    fn zeros(arena: Allocator, n: u32) ![]const u8 {
        const z = try arena.alloc(u8, n);
        @memset(z, '0');
        return z;
    }

    /// `e` as one bit: a wider value is `$reduce_bool`ed (§4.1.9's truth).
    pub fn bool1(self: *Emitter, e: ExprId) Error!Sig {
        const s = try self.expr(e, 0);
        if (s.w == 1) return s;
        return self.cell1("$reduce_bool", s, 1, false);
    }

    /// A unary `$`-cell over `a`, its `Y` a fresh `yw`-bit wire.
    pub fn cell1(self: *Emitter, kind: []const u8, a: Sig, yw: u32, ysigned: bool) Error!Sig {
        assert(kind[0] == '$');
        assert(a.w >= 1 and yw >= 1);
        const y = try self.temp(yw, ysigned);
        try self.cells.writer.print(
            "  cell {s} {s}\n    parameter \\A_SIGNED {d}\n    parameter \\A_WIDTH {d}\n    parameter \\Y_WIDTH {d}\n    connect \\A {s}\n    connect \\Y {s}\n  end\n",
            .{ kind, try self.fresh('c'), @intFromBool(a.signed), a.w, yw, a.s, y.s },
        );
        return y;
    }

    /// A binary `$`-cell over `a` and `b`, signed only when `signed`.
    pub fn cell2(self: *Emitter, kind: []const u8, a: Sig, b: Sig, signed: bool, yw: u32, ysigned: bool) Error!Sig {
        assert(kind[0] == '$');
        assert(a.w >= 1 and b.w >= 1 and yw >= 1);
        const y = try self.temp(yw, ysigned);
        try self.cells.writer.print(
            "  cell {s} {s}\n    parameter \\A_SIGNED {d}\n    parameter \\A_WIDTH {d}\n    parameter \\B_SIGNED {d}\n    parameter \\B_WIDTH {d}\n    parameter \\Y_WIDTH {d}\n    connect \\A {s}\n    connect \\B {s}\n    connect \\Y {s}\n  end\n",
            .{ kind, try self.fresh('c'), @intFromBool(signed and a.signed), a.w, @intFromBool(signed and b.signed), b.w, yw, a.s, b.s, y.s },
        );
        return y;
    }

    /// `$mux`: `s` selects `b` over `a`, both `w` wide.
    pub fn mux(self: *Emitter, s: Sig, a: Sig, b: Sig, w: u32, signed: bool) Error!Sig {
        assert(s.w == 1);
        assert(a.w == w and b.w == w);
        const y = try self.temp(w, signed);
        try self.cells.writer.print(
            "  cell $mux {s}\n    parameter \\WIDTH {d}\n    connect \\A {s}\n    connect \\B {s}\n    connect \\S {s}\n    connect \\Y {s}\n  end\n",
            .{ try self.fresh('c'), w, a.s, b.s, s.s, y.s },
        );
        return y;
    }

    /// `p`'s current indentation, two spaces a level.
    pub fn indent(self: *Emitter, p: *Proc) Error!void {
        assert(self.proc == p);
        try p.w.splatByteAll(' ', 2 * p.indent);
    }
};

test "constSig: two's complement, MSB first, past 64 bits sign-extended" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    var e: Emitter = .{ .arena = arena.allocator(), .file = undefined, .text = "", .starts = &.{}, .out = undefined, .why = &why, .bag = undefined };
    try std.testing.expectEqualStrings("4'0101", (try e.constSig(5, 4, false)).s);
    try std.testing.expectEqualStrings("4'1111", (try e.constSig(-1, 4, true)).s);
    try std.testing.expectEqualStrings("1'0", (try e.constSig(2, 1, false)).s);
    try std.testing.expectEqualStrings("66'111111111111111111111111111111111111111111111111111111111111111111", (try e.constSig(-1, 66, true)).s);
}
