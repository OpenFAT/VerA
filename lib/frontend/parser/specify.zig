//! Annex A.7 specify blocks (IEEE 1364 Clause 14, inherited through LRM §1.1).
//!
//! In: tokens from `specify` to `endspecify`, and module-level `specparam`.
//! Out: `ModuleDecl.paths` and `.timing_checks`, and specparams (module-level or
//! inside the block) as local parameters.
//!
//! LRM clauses cited: §1.1, §2.6.2, §2.8, §3.4.1, §3.4.5, §8, §11.6.15, §14.2.6.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_module = @import("module.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.7 specify blocks: LRM §1.1 (1364 is part of the language), §8
// -----------------------------------------------------------------------

/// Parses one A.7.1 `specify_block ::= specify { specify_item } endspecify`
/// into `b.paths` and `b.timing_checks`, then warns W0251: in an analog
/// compile naming the block's timing checks, in a digital parse only when
/// the block holds a path delay or a pulse control.
///
/// The block is legal source under §1.1, and annex C.16 does not exempt it.
/// Its content is §8 scheduling (A.7.2 path delays, A.7.5 timing checks):
/// §11.6.15's VPI objects read what is recorded, an analog device applies
/// none of it, and the digital engine runs the timing checks only. The
/// block is parsed rather than skipped so a typo in a path declaration is
/// still an error.
pub fn parseSpecifyBlock(self: *Parser, b: *parse_module.Body) Error!void {
    const open = self.pos;
    const first = b.timing_checks.items.len;
    self.pos += 1; // `specify`
    var item_at: u32 = undefined;
    while (!self.reservedIs(self.pos, "endspecify")) : (std.debug.assert(self.pos > item_at)) {
        item_at = self.pos;
        if (self.peek() == .eof or self.peek() == .kw_endmodule)
            return self.failAt(self.pos, .E0207, "found {s}: no `endspecify` closes the specify block", .{self.found(self.pos)});
        try parseSpecifyItem(self, b);
    }
    self.pos += 1; // `endspecify`
    // A digital run (`vera --run`) evaluates the §15 timing checks (or
    // refuses one by name, E1149) and every §14 module path. What it ignores
    // is §14.6's pulse controls, so a digital parse warns only for those.
    if (self.digital) {
        if (!pulseControls(self, open)) return;
        return self.bag.add(
            .parse,
            .W0251,
            lexer.tokenSpan(self.src, self.starts, open),
            "its §14.6 pulse controls are ignored: the default pulse handling applies (inertial, with reject and error limits equal to the path delay)",
            .{},
        );
    }
    // A timing check is the one item whose loss a design notices by name (a
    // violation it expected to be told about), so each is listed.
    const checks = b.timing_checks.items[first..];
    const tail = " never evaluated by the analog solver";
    var n: usize = if (checks.len == 0) 0 else tail.len + 2 * (checks.len - 1);
    for (checks) |t| n += self.tokenText(t.main_tok).len;
    var names: std.ArrayList(u8) = try .initCapacity(self.arena, n);
    for (checks, 0..) |t, i| {
        if (i != 0) names.appendSliceAssumeCapacity(", ");
        names.appendSliceAssumeCapacity(self.tokenText(t.main_tok));
    }
    if (checks.len != 0) names.appendSliceAssumeCapacity(tail);
    std.debug.assert(names.items.len == n);
    try self.bag.add(
        .parse,
        .W0251,
        lexer.tokenSpan(self.src, self.starts, open),
        "{s}",
        .{names.items},
    );
}

/// Whether the block opened at token `open` and closed just before
/// `self.pos` writes a §14.6 pulse control: an A.7.1 pulsestyle or
/// showcancelled declaration, or an A.2.4 `PATHPULSE$` specparam.
fn pulseControls(self: *const Parser, open: u32) bool {
    for (open..self.pos) |at| {
        const w = self.tokenText(@intCast(at));
        if (std.mem.startsWith(u8, w, "PATHPULSE$")) return true;
        if (self.tags[at] == .kw_reserved and pulse_words.has(w)) return true;
    }
    return false;
}

/// A.7.1's `pulsestyle_declaration` and `showcancelled_declaration` keywords,
/// all `.kw_reserved`, so the spelling is the test.
const pulse_words = std.StaticStringMap(void).initComptime(.{ .{"pulsestyle_onevent"}, .{"pulsestyle_ondetect"}, .{"showcancelled"}, .{"noshowcancelled"} });

/// Parses one A.7.1 `specify_item`, any of the five arms:
///
///     specify_item ::=
///             specparam_declaration
///             | pulsestyle_declaration
///             | showcancelled_declaration
///             | path_declaration
///             | system_timing_check
fn parseSpecifyItem(self: *Parser, b: *parse_module.Body) Error!void {
    switch (self.peek()) {
        .kw_reserved => {
            const w = self.tokenText(self.pos);
            // A.2.1.1's declaration as a specify_item. A specify block is
            // no scope (IEEE 1364-2005 4.10.3 lets the body use it, e.g. as a
            // §9.7.1 delay), so it joins the module's specparams.
            if (std.mem.eql(u8, w, "specparam")) return parseSpecparamDecl(self, &b.params);
            // A.7.1 `pulsestyle_declaration` / `showcancelled_declaration`,
            // four keywords over one `list_of_path_outputs ;`.
            if (pulse_words.has(w)) {
                self.pos += 1;
                // A.7.2's `list_of_path_outputs` has no parentheses of its
                // own, and IEEE 1364-2005 §14.6.4.2's examples write none
                // (`pulsestyle_ondetect out, out_b;`). A pair is reported,
                // then read, so the block's other items still parse.
                const paren = self.peek() == .lparen;
                if (paren) try self.report(self.pos, .E0207, "found `(`: A.7.1's `{s}` takes list_of_path_outputs, written without parentheses", .{w});
                if (paren) self.pos += 1;
                _ = try parseSpecifyTerminalList(self);
                if (paren) _ = try self.expect(.rparen);
                _ = try self.expect(.semicolon);
                return;
            }
            // A.7.2 `state_dependent_path_declaration ::= … | ifnone
            // simple_path_declaration`.
            if (std.mem.eql(u8, w, "ifnone")) {
                self.pos += 1;
                return parsePathDeclaration(self, b, .none, true);
            }
            return self.failAt(self.pos, .E0207, "found {s}, which begins no A.7.1 specify_item", .{self.found(self.pos)});
        },
        // A.7.2 `state_dependent_path_declaration ::= if ( module_path_expression )`
        // followed by a simple or edge-sensitive path.
        .kw_if => {
            self.pos += 1;
            _ = try self.expect(.lparen);
            const cond = try parse_expr.parseExpr(self);
            _ = try self.expect(.rparen);
            return parsePathDeclaration(self, b, cond, false);
        },
        .lparen => return parsePathDeclaration(self, b, .none, false),
        .system_identifier => return parseTimingCheck(self, b),
        else => return self.failAt(self.pos, .E0207, "found {s}, which begins no A.7.1 specify_item", .{self.found(self.pos)}), // else: begins no A.7.1 specify_item: E0207
    }
}

/// Parses A.7.3 `specify_input_terminal_descriptor ::= input_identifier
/// [ [ constant_range_expression ] ]` or its output twin. They differ only
/// in which port directions the name may have, which is judged where the
/// ports are known, not here.
fn parseSpecifyTerminal(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    const name = try self.expectIdent();
    const e = try self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = tok, .str = name });
    return if (self.peek() == .lbracket) parse_expr.parseSelectAt(self, e, self.pos) else e;
}

/// Parses A.7.2 `list_of_path_inputs` or `list_of_path_outputs`, the same
/// comma-separated run of A.7.3 descriptors under two names. Returns an
/// arena slice of at least one descriptor.
fn parseSpecifyTerminalList(self: *Parser) Error![]const Ast.ExprId {
    var out: std.ArrayList(Ast.ExprId) = .empty;
    while (true) {
        try out.append(self.arena, try parseSpecifyTerminal(self));
        if (!self.eat(.comma)) return out.items;
    }
}

/// Parses one A.7.2 `path_declaration` into `b.paths`, any arm:
///
///     parallel_path_description ::=
///             ( specify_input_terminal_descriptor [ polarity_operator ]
///               => specify_output_terminal_descriptor )
///     full_path_description ::=
///             ( list_of_path_inputs [ polarity_operator ] *> list_of_path_outputs )
///     parallel_edge_sensitive_path_description ::=
///             ( [ edge_identifier ] specify_input_terminal_descriptor =>
///               ( specify_output_terminal_descriptor [ polarity_operator ]
///                 : data_source_expression ) )
///
/// The descriptions differ only in which optional pieces are present:
/// `=>` versus `*>` chooses parallel from full, and a `(` after the arrow
/// chooses edge-sensitive from simple. The caller has consumed any
/// `if (…)` or `ifnone` prefix, passed as `cond` and `ifnone`.
fn parsePathDeclaration(self: *Parser, b: *parse_module.Body, cond: Ast.ExprId, ifnone: bool) Error!void {
    const main_tok = self.pos;
    _ = try self.expect(.lparen);
    // A.7.4 `edge_identifier ::= posedge | negedge`, present only on the
    // two edge-sensitive descriptions.
    const edge: Ast.SpecEdge = if (self.eat(.kw_posedge)) .posedge else if (self.eat(.kw_negedge)) .negedge else .none;
    const src_tok = self.pos;
    const sources = try parseSpecifyTerminalList(self);
    // A.7.4 `polarity_operator ::= + | -`.
    const polarity = eatPolarity(self);
    const parallel = self.eatSymbol("=>");
    if (!parallel and !self.eatSymbol("*>")) return self.failAt(
        self.pos,
        .E0207,
        "found {s}: a path description connects its terminals with `=>` or `*>`",
        .{self.found(self.pos)},
    );
    // A.7.2: both `=>` arms put one `specify_input_terminal_descriptor`
    // before the arrow and one output descriptor after it; lists are the
    // full path's (`*>`).
    const dst_tok = self.pos;
    var data: Ast.ExprId = .none;
    var data_polarity: Ast.SpecPolarity = .none;
    if (self.peek() == .lparen) {
        if (ifnone) try self.report(main_tok, .E0245, "ifnone takes a simple path (Syntax 14-5), not an edge-sensitive one", .{});
        if (polarity != .none) try self.report(main_tok, .E0245, "an edge-sensitive path writes its polarity after the destination (Syntax 14-4), not before the arrow", .{});
    }
    if (cond != .none) if (try self.walk(self.pos, badOperator, .{ self, cond })) |at|
        try self.report(self.file.exprs.mainTok(at), .E0245, "a state-dependent path's condition uses only Table 14-1's operators (§14.2.4.1)", .{});
    const outputs = if (self.eat(.lparen)) edge: {
        // The edge-sensitive arms: the outputs, a polarity and the
        // `data_source_expression` the path's value comes from.
        const outs = try parseSpecifyTerminalList(self);
        data_polarity = eatPolarity(self);
        _ = try self.expect(.colon);
        data = try parse_expr.parseExpr(self);
        _ = try self.expect(.rparen);
        break :edge outs;
    } else try parseSpecifyTerminalList(self);
    if (parallel and (sources.len != 1 or outputs.len != 1)) return self.failAt(
        if (sources.len != 1) src_tok else dst_tok,
        .E0207,
        "a parallel path (`=>`) connects one source to one destination, and this one lists {d} source(s) and {d} destination(s); lists need the full path `*>` (A.7.2)",
        .{ sources.len, outputs.len },
    );
    _ = try self.expect(.rparen);
    _ = try self.expect(.assign_eq);
    // A.7.4 `path_delay_value ::= list_of_path_delay_expressions
    // | ( list_of_path_delay_expressions )`. The parenthesis is read here,
    // not by `parseExpr`, because `( tplh , tphl )` is a list of two.
    const bracketed = self.eat(.lparen);
    const delay_tok = self.pos;
    const saved_delay = self.in_digital_delay;
    self.in_digital_delay = true;
    defer self.in_digital_delay = saved_delay;
    // A.7.4 `list_of_path_delay_expressions` has five arms: one value,
    // rise/fall, rise/fall/z, the six transition delays and the twelve. A
    // longer list is refused below, so the delays past 12 are only counted.
    var delays: [12]Ast.ExprId = undefined;
    var n_delays: usize = 0;
    while (true) {
        const d = try parse_expr.parseMinTypMax(self);
        if (n_delays < delays.len) delays[n_delays] = d;
        n_delays += 1;
        if (!self.eat(.comma)) break;
    }
    switch (n_delays) {
        1, 2, 3, 6, 12 => {},
        else => return self.failAt(
            delay_tok,
            .E0207,
            "a path delay lists 1, 2, 3, 6 or 12 values (A.7.4 list_of_path_delay_expressions), not {d}",
            .{n_delays},
        ),
    }
    if (bracketed) _ = try self.expect(.rparen);
    _ = try self.expect(.semicolon);
    try b.paths.append(self.arena, .{
        .full = !parallel,
        .edge = edge,
        .polarity = polarity,
        .cond = cond,
        .ifnone = ifnone,
        .ins = sources,
        .outs = outputs,
        .data = data,
        .data_polarity = data_polarity,
        .delays = try self.arena.dupe(Ast.ExprId, delays[0..n_delays]),
        .main_tok = main_tok,
    });
}

/// The first operation in `e` that IEEE 1364-2005 Table 14-1 does not list,
/// or null.
fn badOperator(self: *const Parser, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    switch (ex.tag(e)) {
        .unary => switch (ex.unOp(e)) {
            .plus, .minus => return e,
            .logical_not, .bit_not, .reduce_and, .reduce_nand, .reduce_or, .reduce_nor, .reduce_xor, .reduce_xnor => {},
        },
        .binary => switch (ex.binOp(e)) {
            .eq, .neq, .logical_and, .logical_or, .bit_and, .bit_or, .bit_xor, .bit_xnor => {},
            .add, .sub, .mul, .div, .mod, .pow, .case_eq, .case_neq, .lt, .le, .gt, .ge, .shl, .shr, .ashl, .ashr => return e,
        },
        else => {}, // else: an operand, a select, a concatenation or `?:`, whose children are checked below
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (badOperator(self, c)) |at| return at;
    return null;
}

/// How a path terminal names its port (§14.2.4.3).
const Reference = enum { whole, bit, part };

fn reference(self: *const Parser, t: Ast.ExprId) Reference {
    const ex = &self.file.exprs;
    if (ex.tag(t) != .index) return .whole;
    return switch (ex.tag(ex.rhs(t))) {
        .range, .indexed_range => .part,
        else => .bit, // else: any other index is a bit-select's
    };
}

/// The port a path terminal names, as A.7.3 writes it: a name with an
/// optional select.
fn terminalName(self: *const Parser, t: Ast.ExprId) Ast.StrId {
    const ex = &self.file.exprs;
    return ex.strOf(if (ex.tag(t) == .index) ex.lhs(t) else t);
}

fn portNamed(b: *const parse_module.Body, name: Ast.StrId) ?Ast.Port {
    return b.ports.items[b.port_index.get(name) orelse return null];
}

/// A terminal's width when its port's range and its select are literal.
fn terminalWidth(self: *const Parser, b: *const parse_module.Body, t: Ast.ExprId) ?u64 {
    const ex = &self.file.exprs;
    if (ex.tag(t) == .index) {
        const rg = ex.rhs(t);
        return switch (ex.tag(rg)) {
            .range => parse_decl.literalWidth(self, .{ .msb = ex.lhs(rg), .lsb = ex.rhs(rg) }),
            // A negative width (`+: 4'shf` is -1) has no width to compare;
            // the part-select's legality is elaboration's question.
            .indexed_range => if (ex.tag(ex.rhs(rg)) == .int_literal) std.math.cast(u64, ex.intValue(ex.rhs(rg))) else null,
            else => 1, // else: a bit-select
        };
    }
    const p = portNamed(b, terminalName(self, t)) orelse return null;
    return if (p.range orelse p.type_range) |d| parse_decl.literalWidth(self, d) else 1;
}

/// Whether the delay expression `e` reads a variable, net or port.
fn readsSignal(self: *const Parser, b: *const parse_module.Body, e: Ast.ExprId) ?Ast.ExprId {
    if (e == .none) return null;
    const ex = &self.file.exprs;
    if (ex.tag(e) == .ident) {
        const name = ex.strOf(e);
        for (b.vars.items) |v| if (v.name == name) return e;
        for (b.nets.items) |n| if (n.name == name) return e;
        return if (portNamed(b, name) != null) e else null;
    }
    var buf: [3]Ast.ExprId = undefined;
    for (ex.children(e, &buf)) |c| if (readsSignal(self, b, c)) |at| return at;
    return null;
}

/// IEEE 1364-2005 §14.2-§14.3's rules on the module's paths that need its
/// ports and drivers, so run once the whole module is parsed. Each broken
/// rule is reported (E0245) and the parse goes on; only OOM propagates.
pub fn checkPaths(self: *Parser, b: *const parse_module.Body) Error!void {
    const ex = &self.file.exprs;
    for (b.paths.items, 0..) |p, i| {
        for (p.ins) |t| {
            const port = portNamed(b, terminalName(self, t));
            if (port == null or (port.?.direction != .input and port.?.direction != .inout))
                try self.report(ex.mainTok(t), .E0245, "module path source `{s}` is not an input or inout port (§14.2.1)", .{self.file.str(terminalName(self, t))});
        }
        for (p.outs) |t| {
            const name = terminalName(self, t);
            const port = portNamed(b, name);
            if (port == null or (port.?.direction != .output and port.?.direction != .inout))
                try self.report(ex.mainTok(t), .E0245, "module path destination `{s}` is not an output or inout port (§14.2.1)", .{self.file.str(name)});
            // One driver per bit: `buf b0(P[0], ...); buf b1(P[1], ...);`
            // drive P once each. A select that does not fold covers it all.
            const n_drv = b.assigns.items.len + b.gates.items.len;
            const shared = outer: for (0..n_drv) |j| {
                const dj = driverTarget(b, j);
                if (terminalName(self, dj) != name) continue;
                for (0..j) |k| {
                    const dk = driverTarget(b, k);
                    if (terminalName(self, dk) == name and bitsOverlap(driverBits(self, dj), driverBits(self, dk))) break :outer true;
                }
            } else false;
            if (shared) try self.report(ex.mainTok(t), .E0245, "module path destination `{s}` has more than one driver on a bit; §14.2.1 allows only one driver inside the module", .{self.file.str(name)});
        }
        if (!p.full) {
            const src = p.ins[0];
            const dst = p.outs[0];
            if (p.data != .none) {
                if (reference(self, dst) != .bit and (terminalWidth(self, b, dst) orelse 1) != 1)
                    try self.report(ex.mainTok(dst), .E0245, "the destination of a parallel edge-sensitive path is a scalar port or a bit-select (§14.2.3)", .{});
            } else if (terminalWidth(self, b, src)) |ws| if (terminalWidth(self, b, dst)) |wd| if (ws != wd)
                try self.report(p.main_tok, .E0245, "a parallel path joins terminals of the same number of bits (§14.2.5), not {d} and {d}", .{ ws, wd });
        }
        for (p.delays) |d| if (try self.walk(self.pos, readsSignal, .{ self, b, d })) |at|
            try self.report(ex.mainTok(at), .E0245, "a module path delay is a constant expression (§14.3); `{s}` is a signal", .{self.file.str(ex.strOf(at))});
        for (b.paths.items[0..i]) |q| {
            // §14.2.4.3: the declarations of one edge-sensitive path name
            // each port the same way.
            if (p.data != .none and q.data != .none and p.ins.len == 1 and q.ins.len == 1 and p.outs.len == 1 and q.outs.len == 1 and
                terminalName(self, p.ins[0]) == terminalName(self, q.ins[0]) and terminalName(self, p.outs[0]) == terminalName(self, q.outs[0]) and
                (reference(self, p.ins[0]) != reference(self, q.ins[0]) or reference(self, p.outs[0]) != reference(self, q.outs[0])))
                try self.report(p.main_tok, .E0245, "a port is referenced in the same way in all declarations of one edge-sensitive path (§14.2.4.3)", .{});
            // §14.2.4.4: not both `ifnone` and an unconditional simple path.
            if (p.ifnone != q.ifnone and p.data == .none and q.data == .none and samePath(self, p, q) and
                (if (p.ifnone) q.cond == .none else p.cond == .none))
                try self.report(p.main_tok, .E0245, "an ifnone path and an unconditional path for the same module path (§14.2.4.4)", .{});
        }
    }
}

/// The `j`th driver inside the module: the continuous assignments, then the
/// gate outputs.
fn driverTarget(b: *const parse_module.Body, j: usize) Ast.ExprId {
    const n = b.assigns.items.len;
    return if (j < n) b.assigns.items[j].target else b.gates.items[j - n].out;
}

/// The bits a driver's target selects, low to high, when the select is
/// literal; null for the whole signal or a select that does not fold.
fn driverBits(self: *const Parser, t: Ast.ExprId) ?[2]i128 {
    const ex = &self.file.exprs;
    if (ex.tag(t) != .index) return null;
    const rg = ex.rhs(t);
    switch (ex.tag(rg)) {
        .int_literal => return .{ parse_decl.literalValue(self, rg), parse_decl.literalValue(self, rg) },
        .range => {
            if (ex.tag(ex.lhs(rg)) != .int_literal or ex.tag(ex.rhs(rg)) != .int_literal) return null;
            const a = parse_decl.literalValue(self, ex.lhs(rg));
            const c = parse_decl.literalValue(self, ex.rhs(rg));
            return .{ @min(a, c), @max(a, c) };
        },
        else => return null, // else: an indexed part-select or a select that does not fold
    }
}

fn bitsOverlap(a: ?[2]i128, c: ?[2]i128) bool {
    const x = a orelse return true;
    const y = c orelse return true;
    return x[0] <= y[1] and y[0] <= x[1];
}

fn samePath(self: *const Parser, p: Ast.SpecPath, q: Ast.SpecPath) bool {
    if (p.full != q.full or p.ins.len != q.ins.len or p.outs.len != q.outs.len) return false;
    for (p.ins, q.ins) |a, c| if (terminalName(self, a) != terminalName(self, c)) return false;
    for (p.outs, q.outs) |a, c| if (terminalName(self, a) != terminalName(self, c)) return false;
    return true;
}

fn eatPolarity(self: *Parser) Ast.SpecPolarity {
    if (self.eat(.plus)) return .positive;
    if (self.eat(.minus)) return .negative;
    return .none;
}

/// A.7.5.1's twelve `system_timing_check` commands and their argument
/// counts `{ mandatory, mandatory + optional }`, counted off A.7.5.1: e.g.
/// `$setup ( data_event , reference_event , timing_check_limit
/// [ , [ notifier ] ] ) ;` is 3 and 4.
pub const timing_checks = std.StaticStringMap(struct { u8, u8 }).initComptime(.{
    .{ "$setup", .{ 3, 4 } },
    .{ "$hold", .{ 3, 4 } },
    .{ "$setuphold", .{ 4, 9 } },
    .{ "$recovery", .{ 3, 4 } },
    .{ "$removal", .{ 3, 4 } },
    .{ "$recrem", .{ 4, 9 } },
    .{ "$skew", .{ 3, 4 } },
    .{ "$timeskew", .{ 3, 6 } },
    .{ "$fullskew", .{ 4, 7 } },
    .{ "$period", .{ 2, 3 } },
    .{ "$width", .{ 2, 4 } },
    .{ "$nochange", .{ 4, 5 } },
});

/// The widest `timing_checks` arity.
const max_timing_args = blk: {
    var m: u8 = 0;
    for (timing_checks.values()) |a| m = @max(m, a[1]);
    break :blk m;
};

/// The two commands whose first argument is a `controlled_reference_event`.
const controlled_first = std.StaticStringMap(void).initComptime(.{ .{"$period"}, .{"$width"} });

/// Parses one A.7.5.1 `system_timing_check` into `b.timing_checks`. A.7.1
/// admits no other system task in a specify block, so a name not in
/// `timing_checks` is E0207, as is a wrong argument count.
fn parseTimingCheck(self: *Parser, b: *parse_module.Body) Error!void {
    const tok = self.pos;
    // Past the widest arity the count is refused below, so those slots are
    // only counted.
    var args: [max_timing_args]Ast.ExprId = undefined;
    var edges: [max_timing_args]Ast.SpecEdge = undefined;
    var masks: [max_timing_args]u8 = undefined;
    var conds: [max_timing_args]Ast.ExprId = undefined;
    const arity = timing_checks.get(self.tokenText(tok)) orelse return self.failAt(
        tok,
        .E0207,
        "found {s}: A.7.1 admits only A.7.5.1's twelve timing checks inside a specify block",
        .{self.found(tok)},
    );
    self.pos += 1;
    _ = try self.expect(.lparen);
    var n: u8 = 0;
    if (self.peek() != .rparen) while (true) {
        // A.7.5.1 writes the optional arguments `[ , [ notifier ] ]`, the
        // comma outside the inner bracket, so a slot may be present and
        // empty. That is why an argument is counted before it is read.
        n +|= 1;
        const arg = self.pos;
        var slot: Ast.ExprId = .none;
        var ev: Ast.SpecEdge = .none;
        var mask: u8 = 0;
        var cond: Ast.ExprId = .none;
        const controlled = self.peek() != .comma and self.peek() != .rparen and
            try parseTimingCheckArg(self, &slot, &ev, &mask, &cond, mintypmaxArg(self.tokenText(tok), n));
        if (n <= max_timing_args) {
            args[n - 1] = slot;
            edges[n - 1] = ev;
            masks[n - 1] = mask;
            conds[n - 1] = cond;
        }
        // A.7.5.2: only `reference_event`, `data_event` and
        // `controlled_reference_event` are `timing_check_event`s. Every
        // command's are its first one (`$period`, `$width`) or two; the
        // limits, flags, offsets and notifier after them are expressions
        // and identifiers that take no event control and no `&&&`.
        if (n > eventArgs(self.tokenText(tok)) and (ev != .none or cond != .none)) return self.failAt(
            arg,
            .E0207,
            "found {s}: argument {d} of `{s}` is not an event, so it takes no event control or `&&&` condition (A.7.5.2)",
            .{ self.found(arg), n, self.tokenText(tok) },
        );
        // A.7.5.1's mandatory arguments are not bracketed, so none of them
        // may be left empty (only `[ , [ notifier ] ]` and its kin may).
        if (n <= arity[0] and slot == .none) return self.failAt(
            arg,
            .E0207,
            "found {s}: argument {d} of `{s}` is required (A.7.5.1)",
            .{ self.found(arg), n, self.tokenText(tok) },
        );
        // A.7.5.1 `$width ( controlled_reference_event , timing_check_limit
        // [ , threshold [ , notifier ] ] )` brackets neither of its two
        // optional arguments on its own, and §15.3.4: "If the notifier is
        // present, a non-null value for the threshold shall also be
        // present", calling `$width ( negedge clr, lim, , notif );` illegal.
        if (n > arity[0] and slot == .none and std.mem.eql(u8, self.tokenText(tok), "$width")) return self.failAt(
            arg,
            .E0207,
            "found {s}: `$width`'s threshold and notifier are not null arguments (A.7.5.1, §15.3.4)",
            .{self.found(arg)},
        );
        // A.7.5.1: `$period` and `$width` open with a
        // `controlled_reference_event`, and A.7.5.3's
        // `controlled_timing_check_event` makes its event control
        // mandatory, unlike `timing_check_event`'s bracketed one.
        if (n == 1 and !controlled and controlled_first.has(self.tokenText(tok))) return self.failAt(
            arg,
            .E0207,
            "`{s}` timing check requires an event control (posedge, negedge or edge) on its reference event (A.7.5.3 controlled_timing_check_event)",
            .{self.tokenText(tok)},
        );
        // A.7.5.2 `notifier ::= variable_identifier`, the reg a violation
        // toggles. A.7.5.1 puts it first among the optional arguments of
        // every command, except `$width`, whose optional `threshold` comes
        // before it.
        const notifier: u8 = if (std.mem.eql(u8, self.tokenText(tok), "$width")) 4 else arity[0] + 1;
        if (n == notifier and self.pos != arg and
            !(self.pos == arg + 1 and (self.tags[arg] == .identifier or self.tags[arg] == .escaped_identifier)))
            return self.failAt(arg, .E0207, "found {s}: the notifier argument of `{s}` names a variable (A.7.5.2 notifier ::= variable_identifier)", .{ self.found(arg), self.tokenText(tok) });
        if (!self.eat(.comma)) break;
    };
    _ = try self.expect(.rparen);
    _ = try self.expect(.semicolon);
    if (n < arity[0] or n > arity[1]) return self.failAt(
        tok,
        .E0207,
        "`{s}` takes {d} to {d} arguments, not {d}",
        .{ self.tokenText(tok), arity[0], arity[1], n },
    );
    try b.timing_checks.append(self.arena, .{
        .name = try self.internTok(tok),
        .args = try self.arena.dupe(Ast.ExprId, args[0..n]),
        .edges = try self.arena.dupe(Ast.SpecEdge, edges[0..n]),
        .masks = try self.arena.dupe(u8, masks[0..n]),
        .conds = try self.arena.dupe(Ast.ExprId, conds[0..n]),
        .main_tok = tok,
    });
}

/// How many of a command's leading arguments are A.7.5.2 events: one for
/// the `controlled_reference_event` commands, two (reference and data) for
/// the rest.
fn eventArgs(name: []const u8) u8 {
    return if (controlled_first.has(name)) 1 else 2;
}

/// Parses one argument of an A.7.5.1 command into `slot` and `ev`, and
/// returns whether it had an event control. A.7.5.2's argument productions
/// are all `expression` except the two event slots, which A.7.5.3 gives a
/// prefix and a suffix:
///
///     timing_check_event ::= [ timing_check_event_control ]
///             specify_terminal_descriptor [ &&& timing_check_condition ]
///     timing_check_event_control ::= posedge | negedge | edge_control_specifier
///
/// Every argument accepts that union; `parseTimingCheck` enforces the
/// mandatory control of a `controlled_reference_event` (`$period`,
/// `$width`) and refuses one on an argument that is no event. `mask` is the
/// control's `TimingCheck.masks` entry, `cond` its `&&&` condition.
fn parseTimingCheckArg(self: *Parser, slot: *Ast.ExprId, ev: *Ast.SpecEdge, mask: *u8, cond: *Ast.ExprId, mtm: MinTypMaxArg) Error!bool {
    ev.* = if (self.eat(.kw_posedge)) .posedge else if (self.eat(.kw_negedge)) .negedge else .none;
    mask.* = switch (ev.*) {
        .posedge => Ast.TimingCheck.posedge_mask,
        .negedge => Ast.TimingCheck.negedge_mask,
        .none, .edge => 0,
    };
    var controlled = ev.* != .none;
    if (!controlled and self.reservedIs(self.pos, "edge")) {
        controlled = true;
        ev.* = .edge;
        // A.7.5.3 `edge_control_specifier ::= edge [ edge_descriptor
        // { , edge_descriptor } ]`. The descriptors are two-character
        // symbols (`01`, `z1`, `0x`) that lex as numbers or identifiers
        // depending on their characters, so each is read as the characters
        // of its tokens up to the next `,` or `]`.
        self.pos += 1;
        // The brackets are the production's own (§15.4: "the keyword edge
        // followed by a square-bracketed list"), so a bare `edge clk`
        // names no transition and is refused.
        _ = try self.expect(.lbracket);
        while (true) {
            const at = self.pos;
            var d: [3]u8 = undefined;
            var n: usize = 0;
            while (self.peek() != .comma and self.peek() != .rbracket) : (self.pos += 1) {
                if (self.peek() == .eof) return self.failAt(self.pos, .E0210, "found {s}", .{self.found(self.pos)});
                for (self.tokenText(self.pos)) |c| {
                    if (n < d.len) d[n] = std.ascii.toLower(c);
                    n += 1;
                }
            }
            if (n != 2 or !edgeDescriptor(d[0], d[1])) return self.failAt(at, .E0207, "found {s}, not an A.7.5.3 edge descriptor (01, 10, or 0 or 1 paired with x or z)", .{self.found(at)});
            mask.* |= Ast.TimingCheck.transition(d[0], d[1]);
            if (self.eat(.rbracket)) break;
            self.pos += 1; // `,`
        }
    }
    slot.* = switch (mtm) {
        .no => try parse_expr.parseExpr(self),
        .yes => try parse_expr.parseMinTypMax(self),
        // `terminal_identifier [ constant_mintypmax_expression ]`.
        .select => if (self.identLike(self.pos) and self.peekAt(1) == .lbracket) sel: {
            const base = try parse_expr.parsePrimary(self);
            const at = try self.expect(.lbracket);
            const i = try parse_expr.parseMinTypMax(self);
            _ = try self.expect(.rbracket);
            break :sel try self.file.exprs.add(self.arena, .{ .tag = .index, .main_tok = at, .lhs = base, .rhs = i });
        } else try parse_expr.parseExpr(self),
    };
    // A.7.5.3's `&&&`, which is three tokens' worth of `&` in a stream that
    // has no tag for it.
    cond.* = if (self.eatSymbol("&&&")) try parse_expr.parseExpr(self) else .none;
    return controlled;
}

const MinTypMaxArg = enum { no, yes, select };

/// Which A.7.5.2 argument productions are `mintypmax_expression`: the
/// stamptime and checktime conditions (6th, 7th) of `$setuphold` and
/// `$recrem`, whose delayed reference and data (8th, 9th) take one as their
/// select, and `$nochange`'s two edge offsets (3rd, 4th). The rest are
/// `expression` or narrower.
fn mintypmaxArg(name: []const u8, n: u8) MinTypMaxArg {
    if (std.mem.eql(u8, name, "$nochange")) return if (n == 3 or n == 4) .yes else .no;
    if (!std.mem.eql(u8, name, "$setuphold") and !std.mem.eql(u8, name, "$recrem")) return .no;
    return switch (n) {
        6, 7 => .yes,
        8, 9 => .select,
        else => .no,
    };
}

/// A.7.5.3 `edge_descriptor ::= 01 | 10 | z_or_x zero_or_one | zero_or_one
/// z_or_x`, its two characters lower-cased.
fn edgeDescriptor(a: u8, b: u8) bool {
    const a01 = a == '0' or a == '1';
    const b01 = b == '0' or b == '1';
    const axz = a == 'x' or a == 'z';
    const bxz = b == 'x' or b == 'z';
    return (a01 and b01 and a != b) or (axz and b01) or (a01 and bxz);
}

/// Parses one A.2.1.1 `specparam_declaration ::= specparam [ range ]
/// list_of_specparam_assignments ;` with A.2.4's assignments:
///
///     specparam_assignment ::=
///             specparam_identifier = constant_mintypmax_expression
///             | pulse_control_specparam
///
/// `out` is the module's parameter list, for both the Syntax 6-1
/// module-item form and an A.7.1 `specify_item`: each specparam becomes a
/// §3.4.5 `localparam` (a constant with a mandatory default that no
/// `parameter_value_assignment` can name).
///
/// A.2.4's `pulse_control_specparam`, `PATHPULSE$[input$output] = (
/// reject_limit_value [ , error_limit_value ] )`, is parsed and dropped: it
/// declares no constant, and the pulse limits it sets are §14.6's simulation,
/// which VerA does not run (W0251).
pub fn parseSpecparamDecl(self: *Parser, out: *std.ArrayList(Ast.ParamDecl)) Error!void {
    // ponytail: 1364's specparams are what SDF back-annotation overrides,
    // and a `localparam` cannot be overridden. VerA reads no SDF; reading
    // it needs separate storage.
    self.pos += 1; // `specparam`
    const packed_range: ?Ast.Dim = try parse_decl.optDim(self);
    while (true) {
        const tok = self.pos;
        const name = try self.expectIdent();
        _ = try self.expect(.assign_eq);
        if (std.mem.startsWith(u8, self.file.str(name), "PATHPULSE$")) {
            _ = try self.expect(.lparen);
            _ = try parse_expr.parseMinTypMax(self);
            if (self.eat(.comma)) _ = try parse_expr.parseMinTypMax(self);
            _ = try self.expect(.rparen);
            if (!self.eat(.comma)) break;
            continue;
        }
        const default = try parse_expr.parseMinTypMax(self);
        try out.append(self.arena, .{
            .name = name,
            .ty = .unspecified, // §3.4.1: derived from the default, as for `parameter`
            .default = default,
            .is_local = true,
            .is_spec = true,
            .packed_range = packed_range,
            .main_tok = tok,
        });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}
