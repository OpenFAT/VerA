//! A parsed IEEE 1364 source in, its RTLIL modules out: per module, the
//! parameters folded at their defaults, a `wire` per port, net and variable
//! (a null port keeps its header number and has none), and the drivers that
//! are not processes: continuous assigns, net initializers, the A.3.4 value
//! gates and module instances. A construct outside the subset is refused by
//! name; a connection to no port of the module is E1100.
//!
//! Clauses: IEEE 1364-2005 A.1.3 (null and selected ports), §3.2, §4.2,
//! §4.10.1, §6.1, §7.2 to §7.4, §12.1.2 and §12.3.6 (connections), §12.2.
//!
//! Contents:
//! - `pub fn design(self: *Emitter) Error!void`
//! - `pub fn module(self: *Emitter, m: *const Ast.ModuleDecl) Error!void`
//! - `pub fn dim(self: *Emitter, d: Ast.Dim, tok: u32, sym: *Sym) Error!void`
//! - `pub fn params(self: *Emitter, m: *const Ast.ModuleDecl) Error!void`
//! - `pub fn declare(self: *Emitter, m: *const Ast.ModuleDecl) Error!void`
//! - `pub fn redeclared(self: *Emitter, m: *const Ast.ModuleDecl, name: StrId, tok: u32) Error!bool`
//! - `pub fn wireLines(self: *Emitter, m: *const Ast.ModuleDecl) Error!void`
//! - `pub fn wireLine(self: *Emitter, name: StrId, s: Sym, dir: Ast.Direction, port: u32) Error!void`
//! - `pub fn contAssign(self: *Emitter, a: *const Ast.ContAssign) Error!void`
//! - `pub fn gate(self: *Emitter, g: *const Ast.GateInst) Error!void`
//! - `pub fn instance(self: *Emitter, i: *const Ast.Instance) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const fold = @import("rtlil_fold.zig");
const rtlil_emitter = @import("rtlil_emitter.zig");
const Emitter = rtlil_emitter.Emitter;
const Error = rtlil_emitter.Error;
const Sym = rtlil_emitter.Sym;
const Sig = rtlil_emitter.Sig;
const Writer = std.Io.Writer;
const StrId = Ast.StrId;

/// Every module of the file: a UDP or an analog description refuses the
/// whole file, and the text opens with `autoidx 1`.
pub fn design(self: *Emitter) Error!void {
    assert(self.next_id == 0 and self.n_procs == 0);
    assert(self.proc == null);
    const f = self.file;
    if (f.udps.len != 0) return self.refuse(f.udps[0].main_tok, "a user-defined primitive", .{});
    if (f.disciplines.len != 0 or f.natures.len != 0 or f.paramsets.len != 0 or f.connectrules.len != 0)
        return self.refuse(0, "an analog or mixed-signal description: --emit-rtlil is digital only", .{});
    try self.out.writeAll("autoidx 1\n");
    for (f.modules) |*m| try self.module(m);
}

/// One module: its refusals first, then its tables, then its text, which is
/// written only once every construct in it is emitted.
pub fn module(self: *Emitter, m: *const Ast.ModuleDecl) Error!void {
    assert(self.proc == null);
    assert(m.name != .none);
    self.m = m;
    self.syms = .empty;
    self.values = .empty;
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

/// `sym` sized by a declared `[msb:lsb]`, folded: its §5.4 width and bounds.
/// RTLIL's `offset` and `width` are C `int`s, so a bound past 32 bits
/// signed is refused, and so is a range of more than 2^31 - 1 bits.
pub fn dim(self: *Emitter, d: Ast.Dim, tok: u32, sym: *Sym) Error!void {
    assert(d.msb != .none and d.lsb != .none);
    const msb = (try self.foldInt(d.msb, tok)) orelse return self.refuse(tok, "a range that is not constant", .{});
    const lsb = (try self.foldInt(d.lsb, tok)) orelse return self.refuse(tok, "a range that is not constant", .{});
    if (std.math.cast(i32, msb) == null or std.math.cast(i32, lsb) == null)
        return self.refuse(tok, "a range whose bounds do not fit RTLIL's 32-bit wire offset (`[{d}:{d}]`)", .{ msb, lsb });
    const span = @abs(@as(i64, msb) - lsb) + 1;
    if (span > std.math.maxInt(i32)) return self.refuse(tok, "a range wider than RTLIL's 2^31 - 1 bits (`[{d}:{d}]`)", .{ msb, lsb });
    sym.width = @intCast(span);
    sym.lsb = lsb;
    sym.descending = msb >= lsb;
    assert(sym.width >= 1);
}

/// §12.2: every parameter at its default, folded in declaration order so
/// a later default may read an earlier one. A `[ range ]` is its width,
/// unsigned unless `signed`; `integer` is 32 bits signed and `time` 64
/// unsigned (§4.10.1); otherwise it takes its value's type, signed when
/// declared so. A declared width is the default's context (§5.4.1), as an
/// assignment's left side is, and converts a real default (§4.8.2). A
/// real parameter has no value here: an expression reading it is refused.
pub fn params(self: *Emitter, m: *const Ast.ModuleDecl) Error!void {
    assert(self.values.count() == 0);
    defer assert(self.values.count() <= m.params.len);
    for (m.params) |*p| {
        var sym: Sym = .{ .width = 32, .signed = true, .kind = .param };
        const real_default = self.file.exprs.tag(p.default) == .real_literal;
        if (p.ty == .real or (real_default and p.ty == .unspecified and p.packed_range == null)) {
            try self.syms.put(self.arena, p.name, sym);
            continue;
        }
        if (p.packed_range) |r| {
            try self.dim(r, p.main_tok, &sym);
            sym.signed = p.is_signed;
        } else if (p.ty == .integer) {
            sym.width = if (p.is_time) 64 else 32;
            sym.signed = !p.is_time;
        }
        const declared = p.packed_range != null or p.ty == .integer;
        const v = (try self.foldValue(p.default, if (declared) sym.width else 0, p.main_tok, true)) orelse
            return self.refuse(p.main_tok, "a parameter default that is not constant: `{s}`", .{self.str(p.name)});
        if (!declared) {
            sym.width = v.width;
            sym.signed = v.signed or p.is_signed;
        }
        try self.values.put(self.arena, p.name, try self.convert(v, sym));
        try self.syms.put(self.arena, p.name, sym);
    }
}

/// Every port, net and variable as a `Sym`, before any is used.
pub fn declare(self: *Emitter, m: *const Ast.ModuleDecl) Error!void {
    assert(self.syms.count() <= m.params.len); // Only the parameters so far.
    defer assert(self.syms.count() >= m.params.len);
    for (m.ports) |*p| {
        // A.1.3: a null port is a header position with no net inside.
        if (p.name == .none) continue;
        if (p.concat_rest or p.external_name != .none) return self.refuse(p.main_tok, "a port expression (`.name({{...}})`)", .{});
        if (p.select != null) return self.refuse(p.main_tok, "a port that is a select of its net (`{s}[...]`)", .{self.str(p.name)});
        if (p.kind == .wreal) return self.refuse(p.main_tok, "a wreal port", .{});
        var sym: Sym = .{ .width = 1, .signed = p.is_signed, .kind = .wire };
        const range = p.range orelse p.type_range orelse for (m.vars) |*v| {
            if (v.name == p.name) break v.packed_range;
        } else null;
        if (range) |r| try self.dim(r, p.main_tok, &sym);
        for (m.vars) |*v| if (v.name == p.name) {
            sym.kind = .reg;
            sym.signed = sym.signed or v.is_signed;
            // A `reg` port keeps its range; `output integer`/`time` are §4.2's widths.
            if (v.storage == .time) sym.width = 64 else if (v.storage == .variable and v.ty == .integer) sym.width = 32;
        };
        try self.syms.put(self.arena, p.name, sym);
    }
    for (m.nets) |*n| {
        if (try self.redeclared(m, n.name, n.main_tok)) continue;
        if (n.kind == .wreal) return self.refuse(n.main_tok, "a wreal net", .{});
        if (n.dims.len != 0) return self.refuse(n.main_tok, "a net array", .{});
        var sym: Sym = .{ .width = 1, .signed = n.is_signed, .kind = .wire };
        if (n.range) |r| try self.dim(r, n.main_tok, &sym);
        try self.syms.put(self.arena, n.name, sym);
    }
    for (m.vars) |*v| {
        if (try self.redeclared(m, v.name, v.main_tok)) continue;
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
        if (v.packed_range) |r| try self.dim(r, v.main_tok, &sym);
        try self.syms.put(self.arena, v.name, sym);
    }
}

/// Whether `name`, about to be declared as a net or variable, already is
/// one: a header port's declaration is the port (§12.3.3), true; any other
/// second declaration (§4.10: "illegal to redeclare a name already declared
/// by a net, parameter, or variable declaration") is E1100, as `vera --run`
/// reports it.
pub fn redeclared(self: *Emitter, m: *const Ast.ModuleDecl, name: StrId, tok: u32) Error!bool {
    assert(name != .none);
    const had = self.syms.get(name) orelse return false;
    if (had.kind != .param and isPort(m, name)) return true;
    return self.designError(tok, "duplicate digital variable");
}

/// `wire width W [signed] [offset O] [upto] [input|output|inout K] \name`.
pub fn wireLines(self: *Emitter, m: *const Ast.ModuleDecl) Error!void {
    assert(self.proc == null);
    assert(self.syms.count() >= m.params.len);
    // A port's number is its header position (§12.1.2), null ones counted.
    for (m.ports, 1..) |*p, k| if (p.name != .none) {
        const s = self.syms.get(p.name).?;
        try self.wireLine(p.name, s, p.direction, @intCast(k));
    };
    for (m.nets) |*n| if (!isPort(m, n.name)) try self.wireLine(n.name, self.syms.get(n.name).?, .unspecified, 0);
    for (m.vars) |*v| if (!isPort(m, v.name)) try self.wireLine(v.name, self.syms.get(v.name).?, .unspecified, 0);
}

/// One `wire` line; `port` 0 is no port.
pub fn wireLine(self: *Emitter, name: StrId, s: Sym, dir: Ast.Direction, port: u32) Error!void {
    assert(name != .none);
    assert(s.width >= 1 and s.kind != .param);
    const w = &self.wires.writer;
    if (self.inits.get(name)) |v| try w.print("  attribute \\init {s}\n", .{v.s});
    try w.print("  wire width {d}", .{s.width});
    if (s.signed) try w.writeAll(" signed");
    // Yosys's `offset` is the lower bound either way: [3:10] is `upto offset 3`.
    const offset = if (s.descending) s.lsb else s.lsb - (s.width - 1);
    if (offset != 0) try w.print(" offset {d}", .{offset});
    if (!s.descending and s.width > 1) try w.writeAll(" upto");
    switch (dir) {
        .input => try w.print(" input {d}", .{port}),
        .output => try w.print(" output {d}", .{port}),
        .inout => try w.print(" inout {d}", .{port}),
        .unspecified => {},
    }
    try w.print(" {s}\n", .{try self.id(name)});
}

/// `assign target = value;` as `connect`, the value fit to the target.
pub fn contAssign(self: *Emitter, a: *const Ast.ContAssign) Error!void {
    assert(a.target != .none and a.value != .none);
    assert(self.proc == null);
    const t = try self.lvalue(a.target, false);
    const v = try self.fit(try self.expr(a.value, t.w), t.w);
    try self.cells.writer.print("  connect {s} {s}\n", .{ t.s, v.s });
}

/// A.3.4's twelve value gates over scalar terminals: two inputs are one
/// binary cell, more are a reduction over their concatenation, and the
/// enable gates are `$tribuf`.
pub fn gate(self: *Emitter, g: *const Ast.GateInst) Error!void {
    assert(g.out != .none);
    assert(self.proc == null);
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
pub fn instance(self: *Emitter, i: *const Ast.Instance) Error!void {
    assert(i.module != .none);
    assert(self.proc == null);
    if (i.range != null) return self.refuse(i.main_tok, "an array of instances", .{});
    const child: ?*const Ast.ModuleDecl = for (self.file.modules) |*c| {
        if (c.name == i.module) break c;
    } else null;
    // The child's port widths fold in the child's own parameters.
    var child_syms: std.AutoHashMapUnmanaged(StrId, Sym) = .empty;
    if (child) |c| {
        const saved = self.syms;
        const saved_values = self.values;
        self.syms = .empty;
        self.values = .empty;
        try self.params(c);
        try self.declare(c);
        child_syms = self.syms;
        self.syms = saved;
        self.values = saved_values;
    }
    const w = &self.cells.writer;
    try w.print("  cell {s} {s}\n", .{ try self.id(i.module), try self.id(i.name) });
    for (i.params, 0..) |p, k| {
        const name: StrId = if (p.name != .none) p.name else blk: {
            const c = child orelse return self.refuse(p.main_tok, "an ordered parameter override of `{s}`, which this source does not declare", .{self.str(i.module)});
            if (k >= c.params.len) return self.refuse(p.main_tok, "more parameter overrides than `{s}` declares", .{self.str(c.name)});
            break :blk c.params[k].name;
        };
        const v = (try self.foldInt(p.value, p.main_tok)) orelse return self.refuse(p.main_tok, "a parameter override that is not an integer constant", .{});
        try w.print("    parameter {s} {d}\n", .{ try self.id(name), v });
    }
    for (i.ports, 0..) |c, k| {
        if (c.expr == .none) continue;
        // A design error is the interpreter's own (E1100), not a refusal.
        const port: ?*const Ast.Port = if (child) |ch| blk: {
            if (c.name != .none) {
                for (ch.ports) |*p| if (p.connName() == c.name) break :blk p;
                return self.designError(c.main_tok, "the instantiated module has no such port");
            }
            if (k >= ch.ports.len) return self.designError(c.main_tok, "more port connections than the module has ports");
            break :blk &ch.ports[k];
        } else null;
        // A.1.3: an expression in a null port's position connects nothing.
        if (port) |p| if (p.name == .none) continue;
        if (c.name == .none and port == null) return self.refuse(c.main_tok, "an ordered connection to `{s}`, which this source does not declare", .{self.str(i.module)});
        const pname = if (c.name != .none) c.name else port.?.name;
        // The child's port width is the context when the source declares it.
        const pw: u32 = if (port) |p| child_syms.get(p.name).?.width else 0;
        const s = try self.expr(c.expr, pw);
        try w.print("    connect {s} {s}\n", .{ try self.id(pname), (if (pw != 0) try self.fit(s, pw) else s).s });
    }
    try w.writeAll("  end\n");
}

// ---- private ----

fn isPort(m: *const Ast.ModuleDecl, name: StrId) bool {
    for (m.ports) |*p| if (p.name == name) return true;
    return false;
}
