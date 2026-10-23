//! An IEEE 1364 design in, Yosys RTLIL text out (`vera --emit-rtlil`): the
//! synthesis front door, digital only. One RTLIL `module` per source module,
//! a `wire` per port, net and variable, a `$`-cell per operator, gate and
//! instance, and one `process` per `always` block, which Yosys's `proc` pass
//! lowers; parameters are folded at their defaults. The text is what
//! `write_rtlil` prints, so `read_rtlil` takes it back.
//!
//! The subset is the structural, synthesizable one: ports, scalar and vector
//! nets and regs, `integer`s, continuous assigns, the A.3.4 gates that compute
//! a value, module instances, `always` blocks whose event control is edges
//! or levels and whose body is assignments, `if` and `case`, and an `initial`
//! block of constant assignments (the `init` attribute). Anything else is
//! refused by name (`error.Refused`, `why`), never emitted half-right: the
//! interpreter (`sim.digital`) is the reference for what the design does.
//!
//! ponytail: parameters fold at their defaults and an instance's override is
//! passed to Yosys as a cell parameter, which `hierarchy` can derive only for
//! a module it read from Verilog; emit one module per override set when a
//! parameterized child matters. Generate blocks, memories, loops, functions
//! and real values are refused rather than lowered: `sim.digital.Run` has
//! them elaborated, and an emitter over it (as `emit.zig` is) is the upgrade.
//!
//! Clauses: IEEE 1364-2005 §3.2 (`reg`), §4.2 (`integer`), §5.1 (operators),
//! §5.4 (expression widths), §5.5 (signedness), §6.1 (continuous assigns),
//! §7.2 to §7.4 (gates), §9.2 (assignments), §9.4 (`if`, `case`), §9.7
//! (event controls), §12.1 (instances).

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const constfold = Front.constfold;
const Const = constfold.Const;
const diag = @import("diag");
const digital = @import("sim").digital;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ExprId = Ast.ExprId;
const StmtId = Ast.StmtId;
const StrId = Ast.StrId;

pub const Error = error{ OutOfMemory, WriteFailed, Refused, DigitalFailed };

/// Preprocesses and parses `source` as `vera --run` does (IEEE 1364, no annex
/// D prelude, `opts.more` after it) and returns the RTLIL of every module in
/// it, allocated in `arena`. A source the parser refuses is
/// `error.DigitalFailed` with the diagnostics in `bag`; a construct outside
/// the subset is `error.Refused` with `why` set (`line N: ...`), and nothing
/// is emitted.
pub fn emit(arena: Allocator, source: []const u8, opts: digital.Options, bag: *diag.Bag, why: *[]const u8) Error![]const u8 {
    const pp = Front.Preprocessor.process(arena, source, .{ .file_name = opts.file_name, .include_dirs = opts.include_dirs, .std_defs = false, .more = more: {
        const more = try arena.alloc(Front.Preprocessor.File, opts.more.len);
        for (opts.more, more) |u, *f| f.* = .{ .name = u.name, .text = u.text };
        break :more more;
    }, .bag = bag }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.PreprocessFailed => error.DigitalFailed,
    };
    var tokens = try Front.Lexer.Lexer.tokenize(arena, pp.text);
    var parser = Front.Parser.Parser.init(arena, pp.text, tokens.items(.tag), tokens.items(.start), bag);
    parser.digital = true;
    parser.setLanguage(opts.language);
    const file = try arena.create(Ast.SourceFile);
    file.* = parser.parseSourceFile() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => return error.DigitalFailed,
    };
    var out: Writer.Allocating = .init(arena);
    var e: Emitter = .{ .arena = arena, .file = file, .text = pp.text, .starts = tokens.items(.start), .out = &out.writer, .why = why };
    try e.design();
    return out.written();
}

/// What one name of a module is, for widths, signedness and lvalues.
const Sym = struct {
    width: u32,
    /// The declared `[msb:lsb]`: the right bound, and whether msb >= lsb.
    /// A bit `i` of the source is RTLIL position `i - lsb` when descending
    /// and `lsb - i` when not (Yosys's `upto`).
    lsb: i64 = 0,
    descending: bool = true,
    signed: bool = false,
    kind: enum { wire, reg, param },
    /// A parameter's folded default.
    value: Const = .{ .int = 0 },
};

/// One sigspec: its RTLIL spelling, width and §5.5 signedness.
const Sig = struct { s: []const u8, w: u32, signed: bool = false };

/// The state of one `always` block's `process`.
const Proc = struct {
    /// The process's own writer; it is appended to the module's cells after.
    w: *Writer,
    index: u32,
    /// Per assigned reg: the `$<index>\name` temp the sync updates from.
    temps: std.AutoHashMapUnmanaged(StrId, Sig) = .empty,
    /// The regs a blocking assignment has written so far: a read after it
    /// takes the temp (§9.2.1), a read before it or after a nonblocking one
    /// the reg (§9.2.2).
    redirect: std.AutoHashMapUnmanaged(StrId, void) = .empty,
    indent: usize = 2,
};

const Emitter = struct {
    arena: Allocator,
    file: *const Ast.SourceFile,
    text: []const u8,
    starts: []const u32,
    out: *Writer,
    why: *[]const u8,
    /// The module being emitted.
    m: *const Ast.ModuleDecl = undefined,
    syms: std.AutoHashMapUnmanaged(StrId, Sym) = .empty,
    /// `initial` constants, by reg (the `init` attribute).
    inits: std.AutoHashMapUnmanaged(StrId, Sig) = .empty,
    /// The module's `wire` lines, then its cells, connects and processes:
    /// RTLIL declares a wire before a use.
    wires: Writer.Allocating = undefined,
    cells: Writer.Allocating = undefined,
    /// The `always` block being emitted, whose temps a read may take.
    proc: ?*Proc = null,
    /// `$vera$wN` and `$vera$cN`, unique in the file.
    next_id: u32 = 0,
    n_procs: u32 = 0,

    const Self = @This();

    fn refuse(self: *Self, tok: u32, comptime fmt: []const u8, args: anytype) Error {
        const at = if (tok < self.starts.len) self.starts[tok] else 0;
        const line = 1 + std.mem.count(u8, self.text[0..@min(at, self.text.len)], "\n");
        const what = try self.arena.print(fmt, args);
        self.why.* = try self.arena.print("line {d}: {s}", .{ line, what });
        return error.Refused;
    }

    fn str(self: *const Self, name: StrId) []const u8 {
        return self.file.str(name);
    }

    /// `\name`; an escaped identifier's own backslash is the same one.
    fn id(self: *Self, name: StrId) ![]const u8 {
        const s = self.str(name);
        return self.arena.print("\\{s}", .{if (s.len != 0 and s[0] == '\\') s[1..] else s});
    }

    fn fresh(self: *Self, comptime kind: u8) ![]const u8 {
        self.next_id += 1;
        return self.arena.print("$vera${c}{d}", .{ kind, self.next_id });
    }

    /// A new private wire of `w` bits, declared in the module.
    fn temp(self: *Self, w: u32, signed: bool) !Sig {
        const name = try self.fresh('w');
        try self.wires.writer.print("  wire width {d}{s} {s}\n", .{ w, if (signed) " signed" else "", name });
        return .{ .s = name, .w = w, .signed = signed };
    }

    // -----------------------------------------------------------------------
    // The design and its modules
    // -----------------------------------------------------------------------

    fn design(self: *Self) Error!void {
        const f = self.file;
        if (f.udps.len != 0) return self.refuse(f.udps[0].main_tok, "a user-defined primitive", .{});
        if (f.disciplines.len != 0 or f.natures.len != 0 or f.paramsets.len != 0 or f.connectrules.len != 0)
            return self.refuse(0, "an analog or mixed-signal description: --emit-rtlil is digital only", .{});
        try self.out.writeAll("autoidx 1\n");
        for (f.modules) |*m| try self.module(m);
    }

    fn module(self: *Self, m: *const Ast.ModuleDecl) Error!void {
        self.m = m;
        self.syms = .empty;
        self.inits = .empty;
        self.wires = .init(self.arena);
        self.cells = .init(self.arena);
        if (m.analog.len != 0) return self.refuse(m.analog[0].main_tok, "an analog block", .{});
        if (m.is_connect) return self.refuse(m.main_tok, "a connectmodule", .{});
        if (m.genvars.len != 0) return self.refuse(m.main_tok, "a generate construct", .{});
        if (m.defparams.len != 0) return self.refuse(m.defparams[0].main_tok, "a defparam", .{});
        if (m.tasks.len != 0) return self.refuse(m.tasks[0].main_tok, "a task or function", .{});
        if (m.functions.len != 0) return self.refuse(m.functions[0].main_tok, "a function", .{});
        if (m.events.len != 0) return self.refuse(m.events[0].main_tok, "a named event", .{});
        if (m.pulls.len != 0) return self.refuse(m.pulls[0].main_tok, "a pullup or pulldown", .{});
        if (m.switches.len != 0) return self.refuse(m.switches[0].main_tok, "a switch primitive", .{});
        if (m.branches.len != 0) return self.refuse(m.branches[0].main_tok, "a branch", .{});

        try self.params(m);
        try self.declare(m);
        // `initial` first: its constants are attributes on the wire lines.
        for (m.discrete) |*d| if (!d.is_always) try self.initial(d);
        try self.wireLines(m);
        for (m.assigns) |*a| try self.contAssign(a);
        for (m.nets) |*n| if (n.init != .none) {
            const t = self.syms.get(n.name).?;
            const v = try self.fit(try self.expr(n.init, t.width), t.width);
            try self.cells.writer.print("  connect {s} {s}\n", .{ try self.id(n.name), v.s });
        };
        for (m.gates) |*g| try self.gate(g);
        for (m.instances) |*i| try self.instance(i);
        for (m.discrete) |*d| if (d.is_always) try self.always(d);

        try self.out.print("module {s}\n", .{try self.id(m.name)});
        try self.out.writeAll(self.wires.written());
        try self.out.writeAll(self.cells.written());
        try self.out.writeAll("end\n");
    }

    /// The §5.4 width of a declared `[msb:lsb]`, folded, and its bounds.
    fn dim(self: *Self, d: Ast.Dim, tok: u32) Error!struct { w: u32, lsb: i64, descending: bool } {
        const msb = (try self.foldInt(d.msb)) orelse return self.refuse(tok, "a range that is not constant", .{});
        const lsb = (try self.foldInt(d.lsb)) orelse return self.refuse(tok, "a range that is not constant", .{});
        const span = @abs(msb - lsb) + 1;
        if (span > std.math.maxInt(u32)) return self.refuse(tok, "a range wider than 2^32 bits", .{});
        return .{ .w = @intCast(span), .lsb = lsb, .descending = msb >= lsb };
    }

    /// §12.2: every parameter at its default, folded in declaration order so
    /// a later default may read an earlier one. Width and sign follow A.2.1.1:
    /// a `[ range ]` sizes it unsigned, anything else is a signed 32-bit integer.
    fn params(self: *Self, m: *const Ast.ModuleDecl) Error!void {
        for (m.params) |*p| {
            const v = constfold.fold(self.file, p.default, Env{ .e = self }) orelse return self.refuse(p.main_tok, "a parameter default that is not constant: `{s}`", .{self.str(p.name)});
            var sym: Sym = .{ .width = 32, .signed = true, .kind = .param, .value = v };
            if (p.packed_range) |r| {
                const d = try self.dim(r, p.main_tok);
                sym = .{ .width = d.w, .lsb = d.lsb, .descending = d.descending, .signed = p.is_signed, .kind = .param, .value = v };
            }
            try self.syms.put(self.arena, p.name, sym);
        }
    }

    /// Every port, net and variable as a `Sym`, before any is used.
    fn declare(self: *Self, m: *const Ast.ModuleDecl) Error!void {
        for (m.ports) |*p| {
            if (p.concat_rest or p.external_name != .none) return self.refuse(p.main_tok, "a port expression (`.name({{...}})`)", .{});
            if (p.kind == .wreal) return self.refuse(p.main_tok, "a wreal port", .{});
            var sym: Sym = .{ .width = 1, .signed = p.is_signed, .kind = .wire };
            const range = p.range orelse p.type_range orelse for (m.vars) |*v| {
                if (v.name == p.name) break v.packed_range;
            } else null;
            if (range) |r| {
                const d = try self.dim(r, p.main_tok);
                sym.width = d.w;
                sym.lsb = d.lsb;
                sym.descending = d.descending;
            }
            for (m.vars) |*v| if (v.name == p.name) {
                sym.kind = .reg;
                sym.signed = sym.signed or v.is_signed;
                // A `reg` port keeps its range; `output integer`/`time` are §4.2's widths.
                if (v.storage == .time) sym.width = 64 else if (v.storage == .variable and v.ty == .integer) sym.width = 32;
            };
            try self.syms.put(self.arena, p.name, sym);
        }
        for (m.nets) |*n| {
            if (self.syms.contains(n.name)) continue;
            if (n.kind == .wreal) return self.refuse(n.main_tok, "a wreal net", .{});
            if (n.dims.len != 0) return self.refuse(n.main_tok, "a net array", .{});
            var sym: Sym = .{ .width = 1, .signed = n.is_signed, .kind = .wire };
            if (n.range) |r| {
                const d = try self.dim(r, n.main_tok);
                sym.width = d.w;
                sym.lsb = d.lsb;
                sym.descending = d.descending;
            }
            try self.syms.put(self.arena, n.name, sym);
        }
        for (m.vars) |*v| {
            if (self.syms.contains(v.name)) continue;
            if (v.dims.len != 0) return self.refuse(v.main_tok, "a memory (`{s}` has unpacked dimensions)", .{self.str(v.name)});
            var sym: Sym = .{ .width = 1, .signed = v.is_signed, .kind = .reg };
            switch (v.storage) {
                .time => sym.width = 64,
                .reg => {},
                .variable => switch (v.ty) {
                    .real => return self.refuse(v.main_tok, "a real variable", .{}),
                    .string => return self.refuse(v.main_tok, "a string variable", .{}),
                    .integer => sym.width = 32,
                    .unspecified => {},
                },
            }
            if (v.packed_range) |r| {
                const d = try self.dim(r, v.main_tok);
                sym.width = d.w;
                sym.lsb = d.lsb;
                sym.descending = d.descending;
            }
            try self.syms.put(self.arena, v.name, sym);
        }
    }

    /// `wire width W [signed] [offset O] [upto] [input|output|inout K] \name`.
    fn wireLines(self: *Self, m: *const Ast.ModuleDecl) Error!void {
        for (m.ports, 1..) |*p, k| {
            const s = self.syms.get(p.name).?;
            try self.wireLine(p.name, s, p.direction, @intCast(k));
        }
        for (m.nets) |*n| if (!isPort(m, n.name)) try self.wireLine(n.name, self.syms.get(n.name).?, .unspecified, 0);
        for (m.vars) |*v| if (!isPort(m, v.name)) try self.wireLine(v.name, self.syms.get(v.name).?, .unspecified, 0);
    }

    fn wireLine(self: *Self, name: StrId, s: Sym, dir: Ast.Direction, port: u32) Error!void {
        const w = &self.wires.writer;
        if (self.inits.get(name)) |v| try w.print("  attribute \\init {s}\n", .{v.s});
        try w.print("  wire width {d}", .{s.width});
        if (s.signed) try w.writeAll(" signed");
        if (s.lsb != 0) try w.print(" offset {d}", .{s.lsb});
        if (!s.descending and s.width > 1) try w.writeAll(" upto");
        switch (dir) {
            .input => try w.print(" input {d}", .{port}),
            .output => try w.print(" output {d}", .{port}),
            .inout => try w.print(" inout {d}", .{port}),
            .unspecified => {},
        }
        try w.print(" {s}\n", .{try self.id(name)});
    }

    fn isPort(m: *const Ast.ModuleDecl, name: StrId) bool {
        for (m.ports) |*p| if (p.name == name) return true;
        return false;
    }

    // -----------------------------------------------------------------------
    // Constants
    // -----------------------------------------------------------------------

    /// `constfold`'s environment: a parameter answers its value, width and sign.
    const Env = struct {
        e: *Self,
        pub fn leaf(env: Env, x: ExprId) ?Const {
            if (env.e.file.exprs.tag(x) != .ident) return null;
            const s = env.e.syms.get(env.e.file.exprs.strOf(x)) orelse return null;
            return if (s.kind == .param) s.value else null;
        }
        pub fn signed(env: Env, x: ExprId) ?bool {
            if (env.e.file.exprs.tag(x) != .ident) return null;
            const s = env.e.syms.get(env.e.file.exprs.strOf(x)) orelse return null;
            return s.signed;
        }
        pub fn width(env: Env, x: ExprId) ?u32 {
            if (env.e.file.exprs.tag(x) != .ident) return null;
            const s = env.e.syms.get(env.e.file.exprs.strOf(x)) orelse return null;
            return s.width;
        }
    };

    /// `e` as an integer constant, or null when it is not constant.
    fn foldInt(self: *Self, e: ExprId) Error!?i64 {
        const c = constfold.fold(self.file, e, Env{ .e = self }) orelse return null;
        return c.asIntExact();
    }

    /// `W'bits` of the two's complement of `v`.
    fn constSig(self: *Self, v: i64, w: u32, signed: bool) !Sig {
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
    fn logicSig(self: *Self, l: @import("kernels").Integer.Literal) !Sig {
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

    // -----------------------------------------------------------------------
    // Expressions
    // -----------------------------------------------------------------------

    /// §5.4.1 the self-determined width of `e`, and §5.5.1 its signedness.
    fn shape(self: *Self, e: ExprId) Error!Sig {
        const ex = &self.file.exprs;
        const tok = ex.mainTok(e);
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
                const n = (try self.foldInt(ex.lhs(e))) orelse return self.refuse(tok, "a replication count that is not constant", .{});
                break :blk .{ .s = "", .w = @intCast(@as(i64, (try self.shape(ex.rhs(e))).w) * n) };
            },
            .index => blk: {
                if (ex.tag(ex.rhs(e)) == .range) {
                    const r = ex.rhs(e);
                    const hi = (try self.foldInt(ex.lhs(r))) orelse return self.refuse(tok, "a part-select bound that is not constant", .{});
                    const lo = (try self.foldInt(ex.rhs(r))) orelse return self.refuse(tok, "a part-select bound that is not constant", .{});
                    break :blk .{ .s = "", .w = @intCast(@abs(hi - lo) + 1) };
                }
                if (ex.tag(ex.rhs(e)) == .indexed_range) {
                    const w = (try self.foldInt(ex.rhs(ex.rhs(e)))) orelse return self.refuse(tok, "an indexed part-select width that is not constant", .{});
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

    /// `e` as a sigspec of at least `ctx` bits (§5.4: a context-determined
    /// operand is evaluated at the context's width), or exactly its own for a
    /// self-determined one. `fit` sizes the result for an assignment.
    fn expr(self: *Self, e: ExprId, ctx: u32) Error!Sig {
        const ex = &self.file.exprs;
        const tok = ex.mainTok(e);
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
                    const v = s.value.asIntExact() orelse return self.refuse(tok, "a real parameter in an expression", .{});
                    return self.constSig(v, s.width, s.signed);
                }
                if (self.proc) |p| if (p.redirect.contains(name)) return p.temps.get(name).?;
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
                const arith = switch (op) {
                    .add, .sub, .mul, .div, .mod, .bit_and, .bit_or, .bit_xor, .bit_xnor => true,
                    else => false, // else: comparisons, logic and shifts size their operands themselves
                };
                // §5.4.1: a comparison's operands take each other's width.
                const cmp_w = @max((try self.shape(ex.lhs(e))).w, (try self.shape(ex.rhs(e))).w);
                const a = try self.expr(ex.lhs(e), if (arith) w else if (op == .pow or op == .shl or op == .shr or op == .ashl or op == .ashr) w else if (op == .logical_and or op == .logical_or) 0 else cmp_w);
                const b = try self.expr(ex.rhs(e), if (arith) w else if (op == .logical_and or op == .logical_or or op == .pow or op == .shl or op == .shr or op == .ashl or op == .ashr) 0 else cmp_w);
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
                try buf.writer.writeAll("{");
                for (parts) |a| {
                    const s = try self.expr(a, 0);
                    try buf.writer.print(" {s}", .{(try self.fit(s, (try self.shape(a)).w)).s});
                }
                try buf.writer.writeAll(" }");
                return .{ .s = buf.written(), .w = own.w };
            },
            .multi_concat => {
                const n = (try self.foldInt(ex.lhs(e))).?;
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
                    const v = (try self.foldInt(e)) orelse return self.refuse(tok, "`$clog2` of a non-constant", .{});
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
    fn select(self: *Self, e: ExprId) Error!Sig {
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
                const hi = (try self.foldInt(ex.lhs(sel))).?;
                const lo = (try self.foldInt(ex.rhs(sel))).?;
                return self.slice(root, s, @max(hi, lo), @min(hi, lo), tok);
            },
            .indexed_range => {
                const w = (try self.foldInt(ex.rhs(sel))).?;
                const b = (try self.foldInt(ex.lhs(sel))) orelse return self.refuse(tok, "an indexed part-select with a variable base", .{});
                const up = ex.extraOf(sel) == 0;
                // §5.2.1: `+:` runs from the base upward, `-:` downward, in the source's numbering.
                const lo = if (up) b else b - w + 1;
                return self.slice(root, s, lo + w - 1, lo, tok);
            },
            else => {}, // else: a bit select
        }
        if (try self.foldInt(sel)) |i| return self.slice(root, s, i, i, tok);
        if (!s.descending) return self.refuse(tok, "a variable bit select of an ascending (`[lo:hi]`) vector", .{});
        var idx = try self.expr(sel, 0);
        if (s.lsb != 0) idx = try self.cell2("$sub", idx, try self.constSig(s.lsb, idx.w, false), false, idx.w, false);
        return self.cell2("$shiftx", root, idx, false, 1, false);
    }

    /// `root [hi:lo]` in RTLIL positions, bounds in the source's numbering.
    fn slice(self: *Self, root: Sig, s: Sym, hi: i64, lo: i64, tok: u32) Error!Sig {
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

    /// `sig` as exactly `w` bits: truncated, or extended per its sign (§5.5).
    fn fit(self: *Self, sig: Sig, w: u32) Error!Sig {
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
    fn bool1(self: *Self, e: ExprId) Error!Sig {
        const s = try self.expr(e, 0);
        if (s.w == 1) return s;
        return self.cell1("$reduce_bool", s, 1, false);
    }

    fn cell1(self: *Self, kind: []const u8, a: Sig, yw: u32, ysigned: bool) Error!Sig {
        const y = try self.temp(yw, ysigned);
        try self.cells.writer.print(
            "  cell {s} {s}\n    parameter \\A_SIGNED {d}\n    parameter \\A_WIDTH {d}\n    parameter \\Y_WIDTH {d}\n    connect \\A {s}\n    connect \\Y {s}\n  end\n",
            .{ kind, try self.fresh('c'), @intFromBool(a.signed), a.w, yw, a.s, y.s },
        );
        return y;
    }

    fn cell2(self: *Self, kind: []const u8, a: Sig, b: Sig, signed: bool, yw: u32, ysigned: bool) Error!Sig {
        const y = try self.temp(yw, ysigned);
        try self.cells.writer.print(
            "  cell {s} {s}\n    parameter \\A_SIGNED {d}\n    parameter \\A_WIDTH {d}\n    parameter \\B_SIGNED {d}\n    parameter \\B_WIDTH {d}\n    parameter \\Y_WIDTH {d}\n    connect \\A {s}\n    connect \\B {s}\n    connect \\Y {s}\n  end\n",
            .{ kind, try self.fresh('c'), @intFromBool(signed and a.signed), a.w, @intFromBool(signed and b.signed), b.w, yw, a.s, b.s, y.s },
        );
        return y;
    }

    /// `$mux`: `s` selects `b` over `a`, both `w` wide.
    fn mux(self: *Self, s: Sig, a: Sig, b: Sig, w: u32, signed: bool) Error!Sig {
        const y = try self.temp(w, signed);
        try self.cells.writer.print(
            "  cell $mux {s}\n    parameter \\WIDTH {d}\n    connect \\A {s}\n    connect \\B {s}\n    connect \\S {s}\n    connect \\Y {s}\n  end\n",
            .{ try self.fresh('c'), w, a.s, b.s, s.s, y.s },
        );
        return y;
    }

    // -----------------------------------------------------------------------
    // Drivers: continuous assigns, gates, instances
    // -----------------------------------------------------------------------

    /// An A.8.5 `net_lvalue` / `variable_lvalue` as a sigspec: a name, a
    /// constant select of one, or a concatenation of those. `in_proc`: the
    /// name must be a reg the process owns, and its temp is the target.
    fn lvalue(self: *Self, e: ExprId, in_proc: bool) Error!Sig {
        const ex = &self.file.exprs;
        const tok = ex.mainTok(e);
        switch (ex.tag(e)) {
            .concat => {
                var buf: Writer.Allocating = .init(self.arena);
                var w: u32 = 0;
                try buf.writer.writeAll("{");
                for (ex.args(e)) |a| {
                    const s = try self.lvalue(a, in_proc);
                    w += s.w;
                    try buf.writer.print(" {s}", .{s.s});
                }
                try buf.writer.writeAll(" }");
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
                    break :blk p.temps.get(name).?;
                } else .{ .s = try self.id(name), .w = s.width, .signed = s.signed };
                if (ex.tag(e) == .ident) return root;
                const sel = ex.rhs(e);
                if (ex.tag(ex.lhs(e)) != .ident) return self.refuse(tok, "a select of a select", .{});
                switch (ex.tag(sel)) {
                    .range => {
                        const hi = (try self.foldInt(ex.lhs(sel))) orelse return self.refuse(tok, "a part-select bound that is not constant", .{});
                        const lo = (try self.foldInt(ex.rhs(sel))) orelse return self.refuse(tok, "a part-select bound that is not constant", .{});
                        return self.slice(root, s, @max(hi, lo), @min(hi, lo), tok);
                    },
                    .indexed_range => return self.refuse(tok, "an indexed part-select as an assignment target", .{}),
                    else => {}, // else: a bit select
                }
                const i = (try self.foldInt(sel)) orelse return self.refuse(tok, "a variable bit select as an assignment target", .{});
                return self.slice(root, s, i, i, tok);
            },
            else => return self.refuse(tok, "an assignment target that is not a name, a select or a concatenation", .{}), // else: A.8.5 admits nothing else
        }
    }

    fn contAssign(self: *Self, a: *const Ast.ContAssign) Error!void {
        const t = try self.lvalue(a.target, false);
        const v = try self.fit(try self.expr(a.value, t.w), t.w);
        try self.cells.writer.print("  connect {s} {s}\n", .{ t.s, v.s });
    }

    /// A.3.4's twelve value gates over scalar terminals: two inputs are one
    /// binary cell, more are a reduction over their concatenation, and the
    /// enable gates are `$tribuf`.
    fn gate(self: *Self, g: *const Ast.GateInst) Error!void {
        if (g.range != null) return self.refuse(g.main_tok, "an array of gate instances", .{});
        const out = try self.lvalue(g.out, false);
        const ins = try self.arena.alloc(Sig, g.ins.len);
        for (g.ins, ins) |e, *s| s.* = try self.fit(try self.expr(e, 0), 1);
        const y: Sig = switch (g.kind) {
            .g_buf => ins[0],
            .g_not => try self.cell1("$not", ins[0], 1, false),
            .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor => blk: {
                const reduce: []const u8 = switch (g.kind) {
                    .g_and, .g_nand => "$reduce_and",
                    .g_or, .g_nor => "$reduce_or",
                    .g_xor => "$reduce_xor",
                    .g_xnor => "$reduce_xnor",
                    else => unreachable, // else: the arm admits only the six value gates
                };
                var buf: Writer.Allocating = .init(self.arena);
                try buf.writer.writeAll("{");
                for (ins) |s| try buf.writer.print(" {s}", .{s.s});
                try buf.writer.writeAll(" }");
                const v = try self.cell1(reduce, .{ .s = buf.written(), .w = @intCast(ins.len) }, 1, false);
                break :blk if (g.kind == .g_nand or g.kind == .g_nor) try self.cell1("$not", v, 1, false) else v;
            },
            .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => blk: {
                const data = if (g.kind == .g_notif0 or g.kind == .g_notif1) try self.cell1("$not", ins[0], 1, false) else ins[0];
                const en = if (g.kind == .g_bufif0 or g.kind == .g_notif0) try self.cell1("$not", ins[1], 1, false) else ins[1];
                const yy = try self.temp(1, false);
                try self.cells.writer.print(
                    "  cell $tribuf {s}\n    parameter \\WIDTH 1\n    connect \\A {s}\n    connect \\EN {s}\n    connect \\Y {s}\n  end\n",
                    .{ try self.fresh('c'), data.s, en.s, yy.s },
                );
                break :blk yy;
            },
        };
        try self.cells.writer.print("  connect {s} {s}\n", .{ out.s, (try self.fit(y, out.w)).s });
    }

    /// `cell \Module \name` with each connection; an ordered list or an
    /// ordered parameter override needs the module's own declaration.
    fn instance(self: *Self, i: *const Ast.Instance) Error!void {
        if (i.range != null) return self.refuse(i.main_tok, "an array of instances", .{});
        const child: ?*const Ast.ModuleDecl = for (self.file.modules) |*c| {
            if (c.name == i.module) break c;
        } else null;
        // The child's port widths fold in the child's own parameters.
        var child_syms: std.AutoHashMapUnmanaged(StrId, Sym) = .empty;
        if (child) |c| {
            const saved = self.syms;
            self.syms = .empty;
            try self.params(c);
            try self.declare(c);
            child_syms = self.syms;
            self.syms = saved;
        }
        const w = &self.cells.writer;
        try w.print("  cell {s} {s}\n", .{ try self.id(i.module), try self.id(i.name) });
        for (i.params, 0..) |p, k| {
            const name: StrId = if (p.name != .none) p.name else blk: {
                const c = child orelse return self.refuse(p.main_tok, "an ordered parameter override of `{s}`, which this source does not declare", .{self.str(i.module)});
                if (k >= c.params.len) return self.refuse(p.main_tok, "more parameter overrides than `{s}` declares", .{self.str(c.name)});
                break :blk c.params[k].name;
            };
            const v = (try self.foldInt(p.value)) orelse return self.refuse(p.main_tok, "a parameter override that is not an integer constant", .{});
            try w.print("    parameter {s} {d}\n", .{ try self.id(name), v });
        }
        for (i.ports, 0..) |c, k| {
            if (c.expr == .none) continue;
            const port: ?*const Ast.Port = if (child) |ch| blk: {
                if (c.name != .none) {
                    for (ch.ports) |*p| if (p.connName() == c.name) break :blk p;
                    return self.refuse(c.main_tok, "`{s}` has no port `{s}`", .{ self.str(ch.name), self.str(c.name) });
                }
                if (k >= ch.ports.len) return self.refuse(c.main_tok, "more connections than `{s}` has ports", .{self.str(ch.name)});
                break :blk &ch.ports[k];
            } else null;
            if (c.name == .none and port == null) return self.refuse(c.main_tok, "an ordered connection to `{s}`, which this source does not declare", .{self.str(i.module)});
            const pname = if (c.name != .none) c.name else port.?.name;
            // The child's port width is the context when the source declares it.
            const pw: u32 = if (port) |p| child_syms.get(p.name).?.width else 0;
            const s = try self.expr(c.expr, pw);
            try w.print("    connect {s} {s}\n", .{ try self.id(pname), (if (pw != 0) try self.fit(s, pw) else s).s });
        }
        try w.writeAll("  end\n");
    }

    // -----------------------------------------------------------------------
    // Processes
    // -----------------------------------------------------------------------

    /// An `initial` block of `reg = constant;` statements: each is the reg's
    /// `init` attribute, which is what synthesis makes of one.
    fn initial(self: *Self, d: *const Ast.DiscreteBlock) Error!void {
        var stmts: std.ArrayList(StmtId) = .empty;
        try self.flatten(d.body, &stmts);
        for (stmts.items) |s| {
            const tok = self.file.stmtTok(s);
            const a = switch (self.file.stmt(s)) {
                .assign => |a| a,
                .empty => continue,
                else => return self.refuse(tok, "an initial block with anything but `reg = constant;`", .{}), // else: every other statement
            };
            if (a.timing != .none or a.continuous != .none) return self.refuse(tok, "an initial assignment with a delay or event control", .{});
            if (self.file.exprs.tag(a.target) != .ident) return self.refuse(tok, "an initial assignment to a select", .{});
            const name = self.file.exprs.strOf(a.target);
            const sym = self.syms.get(name) orelse return self.refuse(tok, "`{s}` is not declared in this module", .{self.str(name)});
            const v = (try self.foldInt(a.value)) orelse return self.refuse(tok, "an initial value that is not constant", .{});
            try self.inits.put(self.arena, name, try self.constSig(v, sym.width, false));
        }
    }

    /// The statements of `s` in order, through unnamed `begin`/`end` nesting.
    fn flatten(self: *Self, s: StmtId, out: *std.ArrayList(StmtId)) Error!void {
        if (s == .none) return;
        switch (self.file.stmt(s)) {
            .block => |b| {
                if (b.vars.len != 0 or b.params.len != 0) return self.refuse(self.file.stmtTok(s), "a block with local declarations", .{});
                if (b.parallel) return self.refuse(self.file.stmtTok(s), "a fork-join block", .{});
                for (b.body) |x| try self.flatten(x, out);
            },
            else => try out.append(self.arena, s), // else: a leaf statement
        }
    }

    /// One `always @(...) body` as an RTLIL `process`: a temp per reg the
    /// body assigns, defaulted to the reg, the body as `assign`/`switch`
    /// lines, then a `sync` per edge (or `sync always` for a level list)
    /// updating each reg from its temp.
    fn always(self: *Self, d: *const Ast.DiscreteBlock) Error!void {
        const tok = d.main_tok;
        const ec = switch (self.file.stmt(d.body)) {
            .event_control => |e| e,
            else => return self.refuse(tok, "an always block without an event control", .{}), // else: a body that never waits
        };
        if (ec.kind != .event) return self.refuse(tok, "an always block that waits on a delay or a level", .{});
        var edges: std.ArrayList(struct { pos: bool, sig: Sig }) = .empty;
        var level = ec.event == .none;
        if (ec.event != .none) try self.eventTerms(ec.event, &edges, &level);
        if (level and edges.items.len != 0) return self.refuse(tok, "an event control mixing edges and levels", .{});

        var pw: Writer.Allocating = .init(self.arena);
        var p: Proc = .{ .w = &pw.writer, .index = self.n_procs };
        self.n_procs += 1;
        // The regs this process writes, each with its temp.
        var written: std.ArrayList(StrId) = .empty;
        try self.assigned(ec.body, &written);
        for (written.items) |name| {
            const s = self.syms.get(name).?;
            const t: Sig = .{ .s = try self.arena.print("${d}{s}", .{ p.index, try self.id(name) }), .w = s.width, .signed = s.signed };
            try self.wires.writer.print("  wire width {d}{s} {s}\n", .{ t.w, if (t.signed) " signed" else "", t.s });
            try p.temps.put(self.arena, name, t);
            try p.w.print("    assign {s} {s}\n", .{ t.s, try self.id(name) });
        }
        self.proc = &p;
        defer self.proc = null;
        try self.stmt(&p, ec.body);
        const syncs: usize = if (level) 1 else edges.items.len;
        for (0..syncs) |k| {
            if (level) try p.w.writeAll("    sync always\n") else try p.w.print("    sync {s} {s}\n", .{ if (edges.items[k].pos) "posedge" else "negedge", edges.items[k].sig.s });
            for (written.items) |name| try p.w.print("      update {s} {s}\n", .{ try self.id(name), p.temps.get(name).?.s });
        }
        try self.cells.writer.print("  process $proc${d}\n{s}  end\n", .{ p.index, pw.written() });
    }

    /// The leaves of an A.6.5 event expression: each `posedge x`/`negedge x`
    /// is an edge; a bare name is a level (`always @(a or b)` is combinational).
    fn eventTerms(self: *Self, e: ExprId, edges: anytype, level: *bool) Error!void {
        const ex = &self.file.exprs;
        switch (ex.tag(e)) {
            .event_or => {
                try self.eventTerms(ex.lhs(e), edges, level);
                try self.eventTerms(ex.rhs(e), edges, level);
            },
            .event_posedge, .event_negedge => {
                const s = try self.expr(ex.lhs(e), 0);
                try edges.append(self.arena, .{ .pos = ex.tag(e) == .event_posedge, .sig = try self.fit(s, 1) });
            },
            else => level.* = true, // else: a level-sensitive term
        }
    }

    /// Every reg `s` assigns, once each, in first-write order.
    fn assigned(self: *Self, s: StmtId, out: *std.ArrayList(StrId)) Error!void {
        if (s == .none) return;
        const tok = self.file.stmtTok(s);
        switch (self.file.stmt(s)) {
            .assign => |a| {
                var names: std.ArrayList(ExprId) = .empty;
                try self.file.stmtWrites(&.{}, s, self.arena, &names);
                for (names.items) |lv| {
                    const base = self.file.lvalueBase(lv);
                    if (base == .none) return self.refuse(tok, "an assignment target that is not a declared name", .{});
                    const name = self.file.exprs.strOf(base);
                    for (out.items) |have| {
                        if (have == name) break;
                    } else try out.append(self.arena, name);
                }
                _ = a;
            },
            .block => |b| for (b.body) |x| try self.assigned(x, out),
            .if_stmt => |i| {
                try self.assigned(i.then_s, out);
                try self.assigned(i.else_s, out);
            },
            .case_stmt => |c| for (c.arms) |arm| try self.assigned(arm.body, out),
            else => {}, // else: refused or ignored by `stmt`
        }
    }

    fn stmt(self: *Self, p: *Proc, s: StmtId) Error!void {
        if (s == .none) return;
        const tok = self.file.stmtTok(s);
        const ex = &self.file.exprs;
        switch (self.file.stmt(s)) {
            .empty => {},
            .block => |b| {
                if (b.vars.len != 0 or b.params.len != 0) return self.refuse(tok, "a block with local declarations", .{});
                if (b.parallel) return self.refuse(tok, "a fork-join block", .{});
                for (b.body) |x| try self.stmt(p, x);
            },
            .assign => |a| {
                if (a.timing != .none or a.timing_repeat != .none) return self.refuse(tok, "an intra-assignment delay or event control", .{});
                if (a.continuous != .none) return self.refuse(tok, "a procedural continuous assignment (`assign`/`force`)", .{});
                const t = try self.lvalue(a.target, true);
                const v = try self.fit(try self.expr(a.value, t.w), t.w);
                try self.indent(p);
                try p.w.print("assign {s} {s}\n", .{ t.s, v.s });
                if (!a.nonblocking) {
                    var names: std.ArrayList(ExprId) = .empty;
                    try self.file.stmtWrites(&.{}, s, self.arena, &names);
                    for (names.items) |lv| try p.redirect.put(self.arena, ex.strOf(self.file.lvalueBase(lv)), {});
                }
            },
            .if_stmt => |i| {
                const c = try self.bool1(i.cond);
                try self.indent(p);
                try p.w.print("switch {s}\n", .{c.s});
                p.indent += 1;
                try self.indent(p);
                try p.w.writeAll("case 1'1\n");
                p.indent += 1;
                try self.stmt(p, i.then_s);
                p.indent -= 1;
                if (i.else_s != .none) {
                    try self.indent(p);
                    try p.w.writeAll("case\n");
                    p.indent += 1;
                    try self.stmt(p, i.else_s);
                    p.indent -= 1;
                }
                p.indent -= 1;
                try self.indent(p);
                try p.w.writeAll("end\n");
            },
            .case_stmt => |c| {
                if (c.kind != .normal) return self.refuse(tok, "a casex or casez", .{});
                const sel = try self.expr(c.scrutinee, 0);
                try self.indent(p);
                try p.w.print("switch {s}\n", .{sel.s});
                p.indent += 1;
                for (c.arms) |arm| {
                    try self.indent(p);
                    try p.w.writeAll("case");
                    for (arm.labels, 0..) |l, k| {
                        const v = try self.fit(try self.expr(l, sel.w), sel.w);
                        try p.w.print("{s} {s}", .{ if (k == 0) "" else ",", v.s });
                    }
                    try p.w.writeAll("\n");
                    p.indent += 1;
                    try self.stmt(p, arm.body);
                    p.indent -= 1;
                }
                p.indent -= 1;
                try self.indent(p);
                try p.w.writeAll("end\n");
            },
            // §17: a display or file task is simulation output, which synthesis has none of.
            .sys_task => {},
            .for_stmt, .while_stmt, .repeat_stmt => return self.refuse(tok, "a loop in an always block", .{}),
            .event_control => return self.refuse(tok, "a nested event or delay control", .{}),
            .event_trigger => return self.refuse(tok, "an event trigger", .{}),
            .disable => return self.refuse(tok, "a disable statement", .{}),
            .jump => return self.refuse(tok, "a jump statement", .{}),
            .contribute, .indirect => return self.refuse(tok, "an analog contribution", .{}),
        }
    }

    fn indent(self: *Self, p: *Proc) Error!void {
        _ = self;
        for (0..p.indent) |_| try p.w.writeAll("  ");
    }
};

// ---------------------------------------------------------------------------
// Tests: `tests/unit.zig` emits designs and reads the text back;
// `zig build test-external` has Yosys read it.
// ---------------------------------------------------------------------------

test "constSig: two's complement, MSB first, past 64 bits sign-extended" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var why: []const u8 = "";
    var e: Emitter = .{ .arena = arena.allocator(), .file = undefined, .text = "", .starts = &.{}, .out = undefined, .why = &why };
    try std.testing.expectEqualStrings("4'0101", (try e.constSig(5, 4, false)).s);
    try std.testing.expectEqualStrings("4'1111", (try e.constSig(-1, 4, true)).s);
    try std.testing.expectEqualStrings("1'0", (try e.constSig(2, 1, false)).s);
    try std.testing.expectEqualStrings("66'111111111111111111111111111111111111111111111111111111111111111111", (try e.constSig(-1, 66, true)).s);
}
