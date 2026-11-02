//! An `initial` or `always` block in, RTLIL out: an `initial` block of
//! constant assignments as `init` attributes, and an `always` block as one
//! `process` whose body is `assign` and `switch` lines and whose `sync`
//! rules update each reg it writes.
//!
//! Clauses: IEEE 1364-2005 §9.2.1 and §9.2.2 (blocking and nonblocking
//! assignments), §9.4 (`if`, `case`), §9.7 (event controls), §17 (system
//! tasks, dropped: synthesis has no simulation output).
//!
//! Contents:
//! - `pub fn initial(self: *Emitter, d: *const Ast.DiscreteBlock) Error!void`
//! - `pub fn flatten(self: *Emitter, s: StmtId, out: *std.ArrayList(StmtId)) Error!void`
//! - `pub fn always(self: *Emitter, d: *const Ast.DiscreteBlock) Error!void`
//! - `pub fn eventTerms(self: *Emitter, e: ExprId, edges: anytype, level: *bool) Error!void`
//! - `pub fn assigned(self: *Emitter, s: StmtId, out: *std.ArrayList(StrId)) Error!void`
//! - `pub fn stmt(self: *Emitter, p: *Proc, s: StmtId) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const rtlil_emitter = @import("rtlil_emitter.zig");
const rtlil_table = @import("rtlil_table.zig");
const Emitter = rtlil_emitter.Emitter;
const Error = rtlil_emitter.Error;
const Sig = rtlil_table.Sig;
const Proc = rtlil_emitter.Proc;
const Writer = std.Io.Writer;
const ExprId = Ast.ExprId;
const StmtId = Ast.StmtId;
const StrId = Ast.StrId;

/// An `initial` block of `reg = constant;` statements: each is the reg's
/// `init` attribute, which is what synthesis makes of one.
pub fn initial(self: *Emitter, d: *const Ast.DiscreteBlock) Error!void {
    assert(!d.is_always);
    assert(self.proc == null);
    var stmts: std.ArrayList(StmtId) = .empty;
    try self.flatten(d.body, &stmts);
    for (stmts.items) |s| {
        const tok = self.file.stmtTok(s);
        const a = switch (self.file.stmt(s)) {
            .assign => |a| a,
            .empty => continue,
            else => return self.refuse(tok, .E1251, "", .{}), // else: every other statement
        };
        if (a.timing != .none or a.continuous != .none) return self.refuse(tok, .E1252, "", .{});
        if (self.file.exprs.tag(a.target) != .ident) return self.refuse(tok, .E1253, "", .{});
        const name = self.file.exprs.strOf(a.target);
        const r = self.syms.find(name) orelse return self.refuse(tok, .E1224, "`{s}`", .{self.str(name)});
        const sym = self.syms.rows.items(.sym)[r];
        const v = (try self.foldValue(a.value, sym.width, tok, true)) orelse return self.refuse(tok, .E1254, "", .{});
        self.syms.rows.items(.init)[r] = try self.logicSig(try self.convert(v, sym));
    }
}

/// The statements of `s` in order, through unnamed `begin`/`end` nesting.
pub fn flatten(self: *Emitter, s: StmtId, out: *std.ArrayList(StmtId)) Error!void {
    assert(self.proc == null);
    if (s == .none) return;
    try self.deeper(self.file.stmtTok(s));
    switch (self.file.stmt(s)) {
        .block => |b| {
            if (b.vars.len != 0 or b.params.len != 0) return self.refuse(self.file.stmtTok(s), .E1255, "", .{});
            if (b.parallel) return self.refuse(self.file.stmtTok(s), .E1256, "", .{});
            for (b.body) |x| try self.flatten(x, out);
        },
        else => try out.append(self.arena, s), // else: a leaf statement
    }
}

/// One `always @(...) body` as an RTLIL `process`: a temp per reg the
/// body assigns, defaulted to the reg, the body as `assign`/`switch`
/// lines, then a `sync` per edge (or `sync always` for a level list)
/// updating each reg from its temp.
pub fn always(self: *Emitter, d: *const Ast.DiscreteBlock) Error!void {
    assert(d.is_always);
    assert(self.proc == null);
    const tok = d.main_tok;
    const ec = switch (self.file.stmt(d.body)) {
        .event_control => |e| e,
        else => return self.refuse(tok, .E1257, "", .{}), // else: a body that never waits
    };
    if (ec.kind != .event) return self.refuse(tok, .E1258, "", .{});
    var edges: std.ArrayList(struct { pos: bool, sig: Sig }) = .empty;
    var level = ec.event == .none;
    if (ec.event != .none) try self.eventTerms(ec.event, &edges, &level);
    if (level and edges.items.len != 0) return self.refuse(tok, .E1259, "", .{});

    var pw: Writer.Allocating = .init(self.arena);
    var p: Proc = .{ .w = &pw.writer, .index = self.n_procs };
    self.n_procs += 1;
    // The regs this process writes, each with its temp.
    var written: std.ArrayList(StrId) = .empty;
    try self.assigned(ec.body, &written);
    for (written.items) |name| {
        // `assigned` refused every name the module does not declare.
        const r = self.syms.find(name).?;
        const s = self.syms.rows.items(.sym)[r];
        const t: Sig = .{ .s = try self.arena.print("${d}{s}", .{ p.index, try self.id(name) }), .w = s.width, .signed = s.signed };
        try self.wires.writer.print("  wire width {d}{s} {s}\n", .{ t.w, if (t.signed) " signed" else "", t.s });
        self.syms.rows.items(.temp)[r] = t;
        self.syms.rows.items(.temp_proc)[r] = p.index;
        try p.w.print("    assign {s} {s}\n", .{ t.s, try self.id(name) });
    }
    self.proc = &p;
    defer self.proc = null;
    try self.stmt(&p, ec.body);
    const syncs: usize = if (level) 1 else edges.items.len;
    for (0..syncs) |k| {
        if (level) try p.w.writeAll("    sync always\n") else try p.w.print("    sync {s} {s}\n", .{ if (edges.items[k].pos) "posedge" else "negedge", edges.items[k].sig.s });
        for (written.items) |name| try p.w.print("      update {s} {s}\n", .{ try self.id(name), self.syms.temp(name, p.index).s });
    }
    try self.cells.writer.print("  process $proc${d}\n{s}  end\n", .{ p.index, pw.written() });
}

/// The leaves of an A.6.5 event expression: each `posedge x`/`negedge x`
/// is an edge; a bare name is a level (`always @(a or b)` is combinational).
pub fn eventTerms(self: *Emitter, e: ExprId, edges: anytype, level: *bool) Error!void {
    assert(e != .none);
    const ex = &self.file.exprs;
    try self.deeper(ex.mainTok(e));
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
pub fn assigned(self: *Emitter, s: StmtId, out: *std.ArrayList(StrId)) Error!void {
    assert(self.proc == null); // Before the process exists.
    if (s == .none) return;
    const tok = self.file.stmtTok(s);
    try self.deeper(tok);
    switch (self.file.stmt(s)) {
        .assign => {
            var names: std.ArrayList(ExprId) = .empty;
            try self.file.stmtWrites(&.{}, s, self.arena, &names);
            for (names.items) |lv| {
                const base = self.file.lvalueBase(lv);
                if (base == .none) return self.refuse(tok, .E1244, "", .{});
                const name = self.file.exprs.strOf(base);
                if (self.syms.find(name) == null) return self.refuse(tok, .E1224, "`{s}`", .{self.str(name)});
                for (out.items) |have| {
                    if (have == name) break;
                } else try out.append(self.arena, name);
            }
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

/// `s` as `p`'s body lines: assignments to temps, `if` and `case` as
/// `switch`, system tasks dropped; anything else is refused.
pub fn stmt(self: *Emitter, p: *Proc, s: StmtId) Error!void {
    assert(self.proc == p);
    if (s == .none) return;
    const tok = self.file.stmtTok(s);
    try self.deeper(tok);
    const ex = &self.file.exprs;
    switch (self.file.stmt(s)) {
        .empty => {},
        .block => |b| {
            if (b.vars.len != 0 or b.params.len != 0) return self.refuse(tok, .E1255, "", .{});
            if (b.parallel) return self.refuse(tok, .E1256, "", .{});
            for (b.body) |x| try self.stmt(p, x);
        },
        .assign => |a| {
            if (a.timing != .none or a.timing_repeat != .none) return self.refuse(tok, .E1260, "", .{});
            if (a.continuous != .none) return self.refuse(tok, .E1261, "", .{});
            const t = try self.lvalue(a.target, true);
            const v = try self.fit(try self.expr(a.value, t.w), t.w);
            try self.indent(p);
            try p.w.print("assign {s} {s}\n", .{ t.s, v.s });
            if (!a.nonblocking) {
                var names: std.ArrayList(ExprId) = .empty;
                try self.file.stmtWrites(&.{}, s, self.arena, &names);
                for (names.items) |lv| self.syms.rows.items(.redirect_proc)[self.syms.find(ex.strOf(self.file.lvalueBase(lv))).?] = p.index;
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
            if (c.kind != .normal) return self.refuse(tok, .E1262, "", .{});
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
        .for_stmt, .while_stmt, .repeat_stmt => return self.refuse(tok, .E1263, "", .{}),
        .event_control => return self.refuse(tok, .E1264, "", .{}),
        .event_trigger => return self.refuse(tok, .E1265, "", .{}),
        .disable => return self.refuse(tok, .E1266, "", .{}),
        .jump => return self.refuse(tok, .E1267, "", .{}),
        .contribute, .indirect => return self.refuse(tok, .E1268, "", .{}),
    }
}
