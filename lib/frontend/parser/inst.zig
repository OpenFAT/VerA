//! Instances: annex A.4.1 module instantiation (LRM §6.2.2, §6.3), A.3 gate
//! and switch instances, and A.6.2 initial/always constructs -> rows of
//! `parse_module.Body`.
//!
//! LRM clauses cited: §1.1, §2.6.2, §2.9, §6.2.2, §6.3, §6.3.6, §7.1.5, §7.2, §7.2.2,
//! §7.6, §7.7.3, §7.8, §7.12, §7.14, §8.5.3.5, §9.18.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_module = @import("module.zig");
const parse_stmt = @import("stmt.zig");
const parse_net = @import("net.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

/// Parses an A.4.1 module_instantiation (§6.2.2 instances, §6.3 overrides),
/// cursor on the module name, into `b.instances`:
///
///     module_or_paramset_identifier [ #( ... ) ]
///         name [ range ] ( port_connections ) { , name [ range ] ( ... ) } ;
///
/// Every instance in the statement shares one parameter_value_assignment
/// (`integrator #(1.0) I1(...), I2(...)`), so the slice is parsed once. Nothing
/// is resolved here: the module, override values and port nets are all
/// elaboration's questions, including a name that resolves to nothing.
pub fn parseInstantiation(self: *Parser, b: *parse_module.Body) Error!void {
    const module = try self.internTok(self.pos);
    self.pos += 1;
    const params = try parseParamValueAssignment(self);

    while (true) {
        const name_tok = self.pos;
        const name = try self.expectIdent();
        const range: ?Ast.Dim = try parse_decl.optDim(self);
        _ = try self.expect(.lparen);
        var ports: std.ArrayList(Ast.PortConn) = .empty;
        if (!self.eat(.rparen)) {
            while (true) {
                // A.4.1.1 gives both connection forms a leading
                // `{ attribute_instance }`, the slot E.3.2.1's per-port
                // `port_discipline` uses. Collected like any §2.9 attribute
                // and not tied to the port: `Elaborate.primitiveAccess`
                // applies E.3.2 from the connected net instead.
                try self.skipAttributes();
                const tok = self.pos;
                if (self.eat(.dot)) {
                    const pname = try self.expectIdent();
                    _ = try self.expect(.lparen);
                    // §6.2.2 "an unconnected port can be indicated either by
                    // omitting it in the port list or by providing no
                    // expression in the parentheses".
                    const e = if (self.peek() == .rparen) Ast.ExprId.none else try parse_expr.parseExpr(self);
                    _ = try self.expect(.rparen);
                    try ports.append(self.arena, .{ .name = pname, .expr = e, .main_tok = tok });
                } else {
                    // A.4.1 `ordered_port_connection ::= { attribute_instance }
                    // [ expression ]`: a blank still occupies a row, or every
                    // later port would bind to the wrong net.
                    const e = if (self.peek() == .comma or self.peek() == .rparen)
                        Ast.ExprId.none
                    else
                        try parse_expr.parseExpr(self);
                    try ports.append(self.arena, .{ .expr = e, .main_tok = tok });
                }
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.rparen);
        }
        try b.instances.append(self.arena, .{
            .module = module,
            .name = name,
            .range = range,
            .params = params,
            .ports = ports.items,
            .main_tok = name_tok,
        });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// Parses an optional §6.3 / A.4.1 parameter_value_assignment,
/// `#( list_of_parameter_assignments )`: an empty slice when the cursor is not
/// on `#`. A leading `.` marks the named arm; A.4.1 requires a nonempty
/// list entirely in one arm. Shared by instantiation and §7.7.3 connect.
pub fn parseParamValueAssignment(self: *Parser) Error![]const Ast.ParamOverride {
    var params: std.ArrayList(Ast.ParamOverride) = .empty;
    if (self.eat(.hash)) {
        _ = try self.expect(.lparen);
        const first = self.pos;
        if (!self.eat(.rparen)) {
            while (true) {
                const tok = self.pos;
                if (self.eat(.dot)) {
                    // §6.3.6/§9.18 `.$mfactor(expr)`: §9.18 Example 1 prints
                    // `module_b #(.$mfactor(2)) B1(p,n);`, so a system
                    // parameter is admitted as a parameter_identifier.
                    const pname = try self.expectIdentOrSys();
                    _ = try self.expect(.lparen);
                    // A.4.1 `. parameter_identifier ( [ mintypmax_expression ] )`.
                    const v = if (self.peek() == .rparen) Ast.ExprId.none else try parse_expr.parseMinTypMax(self);
                    _ = try self.expect(.rparen);
                    try params.append(self.arena, .{ .name = pname, .value = v, .main_tok = tok });
                } else {
                    const value = try parse_expr.parseExpr(self);
                    try params.append(self.arena, .{
                        .value = value,
                        .main_tok = tok,
                        .scaled_literal_tok = scaledLiteral(self, tok, self.pos),
                    });
                }
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.rparen);
        }
        if (params.items.len == 0) return self.failAt(first, .E0246, "an empty parameter value assignment has no expression or named assignment", .{});
        const named = params.items[0].name != .none;
        for (params.items[1..]) |p| if ((p.name != .none) != named)
            return self.failAt(p.main_tok, .E0246, "instance mixes ordered and named parameter assignments", .{});
    }
    return params.items;
}

/// A.4.1 and A.5.4 share `name #(expr) instance(...)` until elaboration
/// resolves `name`. Keep §2.6.2's lexical evidence for the UDP-delay case,
/// including an operand expression folding discarded. Attribute values are
/// metadata, not operands of the parameter or delay expression.
fn scaledLiteral(self: *const Parser, start: u32, end: u32) ?u32 {
    var in_attr = false;
    for (start..end) |at| switch (self.tags[at]) {
        .attr_open => in_attr = true,
        .attr_close => in_attr = false,
        .real_literal => if (!in_attr) {
            const text = self.tokenText(@intCast(at));
            if (lexer.scaleExp(text[text.len - 1]) != null) return @intCast(at);
        },
        else => {}, // else: only a real literal can carry a §2.6.2 scale factor
    };
    return null;
}

/// Reports E0205 for a module item A.1.4 derives but VerA does not support (an
/// annex B spelling with no production here, a digital `task` in an analog
/// parse, ...) and returns `error.ParseError`.
pub fn unsupportedItem(self: *Parser) Error {
    return self.failAt(self.pos, .E0205, "found {s}", .{self.found(self.pos)});
}

/// Reports E0240 for text no A.1.4 `module_item` alternative derives, a syntax
/// error rather than a missing feature, and returns `error.ParseError`.
pub fn notAModuleItem(self: *Parser) Error {
    return self.failAt(self.pos, .E0240, "found {s}", .{self.found(self.pos)});
}

/// Parses an A.3.1 `gate_instantiation` for A.3.4's computing gate types into
/// `b.gates`, cursor on the gate keyword:
///
///     n_input_gatetype  [drive_strength] [delay2] n_input_gate_instance …
///     n_output_gatetype [drive_strength] [delay2] n_output_gate_instance …
///     enable_gatetype   [drive_strength] [delay3] enable_gate_instance …
///
/// The strength and delay belong to the statement, so every instance shares
/// them. `delay2` is a `delay3` with no turn-off value (§7.2, §7.3: "zero,
/// one, or two delays").
///
/// Outside a digital run the instance is accepted and modelled by nothing,
/// with W0252 (see `gateNotModelled`).
pub fn parseGates(self: *Parser, b: *parse_module.Body) Error!void {
    try gateNotModelled(self);
    const kind: Ast.GateKind = switch (self.peek()) {
        .kw_and => .g_and,
        .kw_nand => .g_nand,
        .kw_or => .g_or,
        .kw_nor => .g_nor,
        .kw_xor => .g_xor,
        .kw_xnor => .g_xnor,
        .kw_buf => .g_buf,
        .kw_not => .g_not,
        .kw_bufif0 => .g_bufif0,
        .kw_bufif1 => .g_bufif1,
        .kw_notif0 => .g_notif0,
        .kw_notif1 => .g_notif1,
        else => unreachable, // else: the caller dispatched on exactly these
    };
    self.pos += 1;
    // A `(` here is ambiguous: A.3.1 makes the instance name optional, so
    // `and (w, a, b);` opens a terminal list with the token a drive strength
    // opens. The word inside settles it, since strength keywords are
    // reserved and no terminal can be one.
    var s0: Ast.Strength = .strong;
    var s1: Ast.Strength = .strong;
    if (self.peek() == .lparen and parse_net.strengthWord(self, self.pos + 1) != null) try parse_net.parseDriveStrength(self, &s0, &s1);
    const enable = switch (kind) {
        .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => true,
        .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor, .g_buf, .g_not => false,
    };
    const delay: Ast.Delay3 = if (self.peek() != .hash) .{} else if (enable) try parse_net.parseDelay3(self) else try parse_net.parseDelay2(self);
    while (true) {
        const tok = self.pos;
        // A.3.1 makes `name_of_gate_instance` optional; `(` after the name
        // tells the two apart, as in `parseSwitch`. A.3.1's
        // `name_of_gate_instance ::= gate_instance_identifier [ range ]` is
        // §7.1.5's instance array.
        var range: ?Ast.Dim = null;
        var name: Ast.StrId = .none;
        if (self.identLike(self.pos)) {
            name = try self.internTok(self.pos);
            self.pos += 1;
            range = try parse_decl.optDim(self);
        }
        _ = try self.expect(.lparen);
        var terms: std.ArrayList(Ast.ExprId) = .empty;
        while (true) {
            try terms.append(self.arena, try parse_expr.parseExpr(self));
            if (!self.eat(.comma)) break;
        }
        _ = try self.expect(.rparen);
        // A.3.3 `output_terminal ::= net_lvalue`: a gate drives its outputs,
        // so each must be a net it can drive. buf/not lead with every
        // terminal but the last as an output; every other gate with one.
        const n_out = switch (kind) {
            .g_buf, .g_not => terms.items.len -| 1,
            .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor, .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => @min(terms.items.len, 1),
        };
        for (terms.items[0..n_out]) |out| if (!try self.walk(self.pos, isNetLvalue, .{ self, out })) return self.failAt(
            self.file.exprs.mainTok(out),
            .E0207,
            "found {s}: a gate's output terminal is a net_lvalue (A.3.3), a net the gate can drive",
            .{self.found(self.file.exprs.mainTok(out))},
        );
        switch (kind) {
            // A.3.1 `( output_terminal { , output_terminal } , input_terminal )`:
            // every terminal but the last is an output, each a separate driver.
            .g_buf, .g_not => {
                if (terms.items.len < 2) return self.failAt(tok, .E0209, "a buf/not gate needs at least one output and one input", .{});
                // The outputs share the one-input slice: `Ast.setPrimTerm`
                // copies a gate's `ins` before it rewrites one.
                const input = terms.items[terms.items.len - 1 ..];
                for (terms.items[0 .. terms.items.len - 1]) |out|
                    try b.gates.append(self.arena, .{ .kind = kind, .out = out, .ins = input, .strength0 = s0, .strength1 = s1, .delay = delay, .range = range, .name = name, .main_tok = tok });
            },
            // A.3.1 `( output_terminal , input_terminal , enable_terminal )`
            .g_bufif0, .g_bufif1, .g_notif0, .g_notif1 => {
                if (terms.items.len != 3) return self.failAt(tok, .E0209, "an enable gate takes an output, a data input and an enable", .{});
                try b.gates.append(self.arena, .{ .kind = kind, .out = terms.items[0], .ins = terms.items[1..], .strength0 = s0, .strength1 = s1, .delay = delay, .range = range, .name = name, .main_tok = tok });
            },
            // A.3.1 `( output_terminal , input_terminal { , input_terminal } )`.
            // IEEE 1364-2005 §7.2: "one output and one or more inputs".
            .g_and, .g_nand, .g_or, .g_nor, .g_xor, .g_xnor => {
                if (terms.items.len < 2) return self.failAt(tok, .E0209, "an n-input gate takes an output and at least one input", .{});
                try b.gates.append(self.arena, .{ .kind = kind, .out = terms.items[0], .ins = terms.items[1..], .strength0 = s0, .strength1 = s1, .delay = delay, .range = range, .name = name, .main_tok = tok });
            },
        }
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// A.8.5 `net_lvalue`: a (hierarchical) net name with optional selects, or a
/// concatenation of net_lvalues.
fn isNetLvalue(self: *const Parser, e: Ast.ExprId) bool {
    const x = &self.file.exprs;
    return switch (x.tag(e)) {
        .ident, .hier_ident => true,
        .index => isNetLvalue(self, x.lhs(e)),
        .concat => for (x.args(e)) |a| {
            if (!isNetLvalue(self, a)) break false;
        } else true,
        else => false, // else: a literal, operator, call, access or pattern names no net; a new name form would be a new arm above
    };
}

/// Warns W0252 for the primitive at the cursor unless the parse is digital.
/// A gate's update is an event (§8.5.3.5), and a compiled analog device has
/// no event queue, so the instance does nothing. The source is derivable from
/// A.3.1 and §1.1 makes it VerA's to accept, so it is a warning, not E0205;
/// `--deny=W0252` refuses it. Under `--run` the discrete engine executes it.
pub fn gateNotModelled(self: *Parser) Error!void {
    if (self.digital) return;
    try self.bag.add(
        .parse,
        .W0252,
        lexer.tokenSpan(self.src, self.starts, self.pos),
        "{s} primitive",
        .{self.found(self.pos)},
    );
}

/// Parses A.3.1's `pulldown`/`pullup` arms into `b.pulls`, cursor on the
/// keyword. They are the only arms with a one-terminal instance and a strength
/// set of their own:
///
///     | pulldown [pulldown_strength] pull_gate_instance { , … } ;
///     | pullup   [pullup_strength]   pull_gate_instance { , … } ;
///     pull_gate_instance ::= [ name_of_gate_instance ] ( output_terminal )
///
/// A.3.2's brackets differ from A.2.2.2's:
///
///     pulldown_strength ::= ( strength0 , strength1 ) | ( strength1 , strength0 )
///             | ( strength0 )
///     pullup_strength   ::= ( strength0 , strength1 ) | ( strength1 , strength0 )
///             | ( strength1 )
///
/// The single-strength arm exists only here, and it must name the side the
/// gate pulls toward (`strength0` for `pulldown`, `strength1` for `pullup`),
/// so `pulldown (strong1)` is E0207. Outside a digital run the instance is
/// accepted and modelled by nothing (W0252); the digital engine executes
/// `b.pulls` and an analog compile never reads it.
pub fn parsePullGate(self: *Parser, b: *parse_module.Body) Error!void {
    try gateNotModelled(self);
    // A.3.2's `strength0`/`strength1` name the side the gate pulls toward:
    // 0 for `pulldown`, 1 for `pullup`, which is also `StrengthWord.side`.
    const side: u8 = if (self.reservedIs(self.pos, "pulldown")) 0 else 1;
    const main_tok = self.pos;
    self.pos += 1;
    // §7.8: "pull strength in the absence of a strength specification", and
    // only the strength on the side the source pulls toward is kept.
    var strength: Ast.Strength = .pull;
    if (self.peek() == .lparen and parse_net.strengthWord(self, self.pos + 1) != null) {
        const tok = self.pos + 1;
        if (self.peekAt(2) == .comma) {
            var s0: Ast.Strength = .strong;
            var s1: Ast.Strength = .strong;
            try parse_net.parseDriveStrength(self, &s0, &s1);
            strength = if (side == 1) s1 else s0;
        } else {
            self.pos += 1;
            const w = parse_net.strengthWord(self, self.pos).?;
            self.pos += 1;
            _ = try self.expect(.rparen);
            if (w.side != side) return self.failAt(
                tok,
                .E0207,
                "a single-strength bracket on this gate is A.3.2's `( strength{d} )`",
                .{side},
            );
            strength = w.level;
        }
    }
    while (true) {
        // A.3.1 makes `name_of_gate_instance` optional here too; `(` after
        // the name tells the two apart, as in `parseGates`.
        var name: Ast.StrId = .none;
        var range: ?Ast.Dim = null;
        if (self.identLike(self.pos)) {
            name = try self.internTok(self.pos);
            self.pos += 1;
            range = try parse_decl.optDim(self);
        }
        _ = try self.expect(.lparen);
        const out = try parse_expr.parseNetLvalue(self); // A.3.3 output_terminal ::= net_lvalue
        try b.pulls.append(self.arena, .{ .out = out, .one = side == 1, .strength = strength, .name = name, .range = range, .main_tok = main_tok });
        _ = try self.expect(.rparen);
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// What distinguishes the four A.3.1 switch arms: how many terminals an
/// instance takes, how many of those lead as A.3.3 `net_lvalue`s (the rest
/// are expressions), and whether a delay may precede the instance list.
/// `shape` describes the A.3.4 class for the diagnostic when an instance
/// closes its list early.
const SwitchArm = struct { terminals: u8, lvalues: u8, delay: bool, shape: []const u8 };

const cmos_shape = "a cmos switch (A.3.4 cmos_switchtype) takes an output, an input, an ncontrol and a pcontrol terminal";
const mos_shape = "a mos switch (A.3.4 mos_switchtype) takes an output, an input and an enable terminal";
const pass_shape = "a pass switch (A.3.4 pass_switchtype) takes two inout terminals";
const pass_en_shape = "a pass-enable switch (A.3.4 pass_en_switchtype) takes two inout terminals and an enable";

/// A.3.4's twelve switch spellings, keyed by spelling because most of them
/// share the `.kw_reserved` tag.
pub const switch_arms = std.StaticStringMap(SwitchArm).initComptime(.{
    // `cmos_switchtype [delay3] ( output , input , ncontrol , pcontrol )`
    .{ "cmos", SwitchArm{ .terminals = 4, .lvalues = 1, .delay = true, .shape = cmos_shape } },
    .{ "rcmos", SwitchArm{ .terminals = 4, .lvalues = 1, .delay = true, .shape = cmos_shape } },
    // `mos_switchtype [delay3] ( output , input , enable )`
    .{ "nmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true, .shape = mos_shape } },
    .{ "pmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true, .shape = mos_shape } },
    .{ "rnmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true, .shape = mos_shape } },
    .{ "rpmos", SwitchArm{ .terminals = 3, .lvalues = 1, .delay = true, .shape = mos_shape } },
    // `pass_switchtype ( inout , inout )`: the one arm with no delay.
    .{ "tran", SwitchArm{ .terminals = 2, .lvalues = 2, .delay = false, .shape = pass_shape } },
    .{ "rtran", SwitchArm{ .terminals = 2, .lvalues = 2, .delay = false, .shape = pass_shape } },
    // `pass_en_switchtype [delay2] ( inout , inout , enable )`. `delay2` is
    // a `delay3` that stops at two values, which `parseDelay3` already
    // returns for a two-value list.
    .{ "tranif0", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true, .shape = pass_en_shape } },
    .{ "tranif1", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true, .shape = pass_en_shape } },
    .{ "rtranif0", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true, .shape = pass_en_shape } },
    .{ "rtranif1", SwitchArm{ .terminals = 3, .lvalues = 2, .delay = true, .shape = pass_en_shape } },
});

/// Parses A.3.1's four switch arms into `b.switches`, cursor on the switch
/// keyword. These are the primitives whose output is a conduction path rather
/// than a computed value:
///
///     | cmos_switchtype    [delay3] cmos_switch_instance         { , … } ;
///     | mos_switchtype     [delay3] mos_switch_instance          { , … } ;
///     | pass_en_switchtype [delay2] pass_enable_switch_instance  { , … } ;
///     | pass_switchtype            pass_switch_instance          { , … } ;
///
///     cmos_switch_instance ::= [ name_of_gate_instance ] ( output_terminal ,
///             input_terminal , ncontrol_terminal , pcontrol_terminal )
///     mos_switch_instance ::= [ name_of_gate_instance ]
///             ( output_terminal , input_terminal , enable_terminal )
///     pass_switch_instance ::= [ name_of_gate_instance ]
///             ( inout_terminal , inout_terminal )
///     pass_enable_switch_instance ::= [ name_of_gate_instance ]
///             ( inout_terminal , inout_terminal , enable_terminal )
///
/// Switches are recorded apart from gates because §7.12's strength reduction
/// and §7.6's bidirectional conduction are not functions of input bits.
/// §8.5.3.5 puts them in the discrete cycle, so the digital engine runs them
/// (under `--run`, and as a mixed module's discrete half); lowering warns
/// W0250 when a module has no discrete half to carry one.
pub fn parseSwitch(self: *Parser, b: *parse_module.Body) Error!void {
    const main_tok = self.pos;
    const spelling = self.tokenText(main_tok);
    const arm = switch_arms.get(spelling).?; // the caller dispatched on exactly these
    const kind = std.meta.stringToEnum(Ast.SwitchKind, spelling).?;
    self.pos += 1;
    const delay: Ast.Delay3 = if (arm.delay and self.peek() == .hash) try parse_net.parseDelay3(self) else .{};
    while (true) {
        const inst_tok = self.pos;
        // A.3.1 makes `name_of_gate_instance ::= gate_instance_identifier
        // [ range ]` optional (`tran (a, b);`); `(` tells the two apart.
        var name: Ast.StrId = .none;
        var range: ?Ast.Dim = null;
        if (self.identLike(self.pos)) {
            name = try self.internTok(self.pos);
            self.pos += 1;
            range = try parse_decl.optDim(self);
        }
        _ = try self.expect(.lparen);
        const terms = try self.arena.alloc(Ast.ExprId, arm.terminals);
        for (terms, 0..) |*t, i| {
            // A list closed early gets the class's terminal list in words
            // instead of a bare "unexpected `)`".
            if (i != 0 and self.peek() == .rparen) return self.failAt(inst_tok, .E0209, "{s}", .{arm.shape});
            if (i != 0) _ = try self.expect(.comma);
            // A.3.3: `output_terminal` and `inout_terminal` are
            // `net_lvalue`s and lead; `input_terminal`, `enable_terminal`,
            // `ncontrol_terminal` and `pcontrol_terminal` are all
            // `expression`, so `cmos (o, d, ~g, g)` is derivable and
            // `cmos (~o, d, ng, g)` is not.
            t.* = if (i < arm.lvalues) try parse_expr.parseNetLvalue(self) else try parse_expr.parseExpr(self);
        }
        _ = try self.expect(.rparen);
        try b.switches.append(self.arena, .{ .kind = kind, .terms = terms, .delay = delay, .name = name, .range = range, .main_tok = inst_tok });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// Parses an A.6.2 `initial` or `always` construct (§7.2.2's discrete
/// context) into `b.discrete`, cursor on the keyword. The body admits the
/// digital statement forms via `in_discrete`, whatever the file's extension.
/// Whether the process can be executed is lowering's question
/// (`Lower.checkDiscreteContext`).
pub fn parseDiscrete(self: *Parser, b: *parse_module.Body) Error!void {
    const main_tok = self.pos;
    const is_always = self.peek() == .kw_always;
    self.pos += 1;
    // IEEE 1364-2005 A.6.2 `initial_construct ::= initial statement`: a
    // statement, not `statement_or_null`.
    if (self.digital and self.peek() == .semicolon)
        return self.failAt(self.pos, .E0209, "found `;`: an {s} construct takes a statement, not a null one", .{if (is_always) "always" else "initial"});
    const saved = self.in_discrete;
    self.in_discrete = true;
    defer self.in_discrete = saved;
    const body = try parse_stmt.parseStmtNoNull(self);
    try b.discrete.append(self.arena, .{
        .is_always = is_always,
        .body = body,
        .main_tok = main_tok,
    });
}
