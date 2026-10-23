//! Ports, nets and branches: annex A.2.1.2 port declarations (§6.5.2),
//! A.2.1.3 net, `wreal`, `ground` and branch declarations (§3.6.3, §3.7,
//! §3.12) and their A.2.2 strengths and delays -> rows of `Body.ports`,
//! `Body.nets`, `Body.branches` and `Body.vars` (variable ports). A body
//! declaration that names a header port completes that port instead of
//! adding a net, so lowering sees one object per terminal.
//!
//! LRM clauses cited: §3.6.3, §3.6.3.2, §3.7, §3.10, §3.12, §3.12.1, §6.2,
//! §6.5.2, §6.5.2.2, §6.5.3, §6.8, §7.4.4, §7.9, annex C.4/C.8, annex F.2.1;
//! IEEE 1364-2005 §4.4, §4.9.1, §6.1.4, §7.14.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_decl = @import("decl.zig");
const parse_expr = @import("expr.zig");
const parse_hier = @import("hier.zig");
const parse_module = @import("module.zig");
const token = @import("../token.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;

// -----------------------------------------------------------------------
// A.2.1.2 port declarations: LRM §6.5.2
// -----------------------------------------------------------------------

/// Returns the `Ast.Direction` of an A.2.1.2 port direction keyword, or null
/// for any other token.
pub fn portDirection(tag: token.Tag) ?Ast.Direction {
    return switch (tag) {
        .kw_input => .input,
        .kw_output => .output,
        .kw_inout => .inout,
        else => null, // else: not a port_direction keyword
    };
}

/// Parses the A.2.1.2 `[ discipline_identifier ] [ net_type | wreal ]
/// [ signed ]` prefix of a port declaration and returns the discipline, or
/// `.none`. The net type and `signed` are consumed and dropped.
pub fn optDiscipline(self: *Parser) Error!Ast.StrId {
    var kind: Ast.NetKind = .wire;
    var signed = false;
    return optPortType(self, &kind, &signed);
}

/// Same as `optDiscipline`, also storing the net type in `kind` (unchanged
/// when absent) and whether `signed` was present in `signed`. A discipline
/// is an identifier followed by another identifier (the first name), so one
/// token of lookahead decides.
pub fn optPortType(self: *Parser, kind: *Ast.NetKind, signed: *bool) Error!Ast.StrId {
    var disc: Ast.StrId = .none;
    if (self.peek() == .identifier and self.identLike(self.pos + 1)) {
        disc = try self.internTok(self.pos);
        self.pos += 1;
    }
    if (netKind(self.peek())) |k| {
        kind.* = k;
        self.pos += 1;
    } else if (self.reservedIs(self.pos, "wreal")) {
        // A.2.1.2's `[ net_type | wreal ]`: `wreal` is not an A.2.2.1
        // net_type, so `netKind` does not know it. Annex C.4/C.8 remove it
        // from the Verilog-A subset only; in Verilog-AMS §6.5.3 makes a wreal
        // port the way a real value crosses a module boundary.
        kind.* = .wreal;
        self.pos += 1;
    }
    signed.* = self.eat(.kw_signed);
    return disc;
}

/// Parses a §6.5.2 body port declaration, cursor on the direction keyword. It
/// sets the direction and discipline of existing header ports; it does not
/// introduce a terminal. Reports E0206 for a name that is not a header port
/// and E0218 for a port that already has a direction.
pub fn parsePortDecl(self: *Parser, b: *parse_module.Body) Error!void {
    const decl_tok = self.pos;
    const dir = portDirection(self.peek()).?;
    self.pos += 1;
    // A.2.1.2's `[ net_type | wreal ]`, §7.9's resolution input (`Ast.Port.kind`).
    var kind: Ast.NetKind = .wire;
    var signed = false;
    const disc = try optPortType(self, &kind, &signed);
    // A.2.1.2's two variable arms, which only `output` has:
    //
    //     output_declaration ::=
    //         output [ discipline_identifier ] [ net_type | wreal ] [ signed ]
    //             [ range ] list_of_port_identifiers
    //       | output [ discipline_identifier ] reg [ signed ] [ range ]
    //             list_of_variable_port_identifiers
    //       | output output_variable_type list_of_variable_port_identifiers
    //     output_variable_type ::= integer | time
    //
    // `optPortType` has already read the first arm's `[ net_type ]`, so this
    // keyword is what tells the arms apart. A variable port gets a `VarDecl`
    // as well as the direction, and only it may carry A.2.3's
    // `[ = constant_expression ]`.
    const var_storage = try optVarStorage(self, dir);
    if (var_storage != null) signed = self.eat(.kw_signed);
    // §6.5.2.2's "port direction declaration" range. Lowering compares it
    // with the port type declaration's, so it lands in its own field.
    const range: ?Ast.Dim = try parse_decl.optDim(self);
    while (true) {
        const tok = self.pos;
        const name = try self.expectIdent();
        if (var_storage) |storage| try varPort(self, b, storage, name, range, signed, tok);
        if (findPort(b, name)) |p| {
            try self.copyAttributes(decl_tok, p.main_tok);
            if (signed) p.is_signed = true;
            // §6.2 "Ports declared in the list of port declarations shall
            // not be redeclared within the body of the module." Only an ANSI
            // header or an earlier body declaration (§6.8) gives a direction,
            // so a port that has one is already declared.
            if (p.direction != .unspecified) {
                try self.report(tok, .E0218, "`{s}`", .{self.file.str(name)});
            } else {
                p.direction = dir;
                if (disc != .none) p.discipline = disc;
                if (range != null) p.range = range;
                if (kind != .wire) p.kind = kind;
            }
        } else {
            try self.report(tok, .E0206, "`{s}`", .{self.file.str(name)});
        }
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// A.2.1.2's variable arms of `output_declaration`, cursor after the
/// direction and any net type: consumes `integer`, `time` or `reg` and
/// returns the storage it names, or null when none is there. Another
/// direction with one is E0207.
pub fn optVarStorage(self: *Parser, dir: Ast.Direction) Error!?@FieldType(Ast.VarDecl, "storage") {
    const storage: @FieldType(Ast.VarDecl, "storage") = switch (self.peek()) {
        .kw_integer => .variable, // A.2.2.1 output_variable_type
        .kw_time => .time, // …its other alternative
        .kw_reg => .reg, // A.2.1.2's second arm
        else => return null, // else: not a variable-storage keyword
    };
    if (dir != .output) return self.failAt(
        self.pos,
        .E0207,
        "found {s}: A.2.1.2 gives a variable type to `output` only",
        .{self.found(self.pos)},
    );
    self.pos += 1;
    return storage;
}

/// The `VarDecl` of one variable port `name`, cursor after the name: A.2.3
/// `list_of_variable_port_identifiers ::= port_identifier
/// [ = constant_expression ] { , ... }`.
pub fn varPort(self: *Parser, b: *parse_module.Body, storage: @FieldType(Ast.VarDecl, "storage"), name: Ast.StrId, range: ?Ast.Dim, signed: bool, tok: u32) Error!void {
    const init_expr: Ast.ExprId = if (self.eat(.assign_eq)) try parse_expr.parseExpr(self) else .none;
    try b.vars.append(self.arena, .{
        .name = name,
        // Both arms are integral: A.2.2.1's `output_variable_type` is
        // `integer | time`, and §3.4.1 folds `time` to the same
        // representation VerA gives an `integer`; Table 7-1 does the same
        // for a `reg`'s bits.
        .ty = .integer,
        .init = init_expr,
        .storage = storage,
        .packed_range = range,
        .is_signed = signed,
        .main_tok = tok,
    });
}

/// Returns the first header port named `name`, or null. The pointer is
/// invalidated by the next append to `b.ports`.
pub fn findPort(b: *parse_module.Body, name: Ast.StrId) ?*Ast.Port {
    return &b.ports.items[b.port_index.get(name) orelse return null];
}

// -----------------------------------------------------------------------
// A.2.1.3 net declarations and A.2.2 strengths and delays: LRM §3.6.3
// -----------------------------------------------------------------------

/// A.2.2.1 net_type keyword -> `Ast.NetKind`, null for a token that is not
/// one. A declaration naming no net type resolves as `.wire` (§7.9); that
/// default is the caller's, not a spelling's.
pub fn netKind(tag: token.Tag) ?Ast.NetKind {
    return switch (tag) {
        .kw_wire => .wire,
        .kw_tri => .tri,
        .kw_tri0 => .tri0,
        .kw_tri1 => .tri1,
        .kw_triand => .triand,
        .kw_trior => .trior,
        .kw_trireg => .trireg,
        .kw_wand => .wand,
        .kw_wor => .wor,
        .kw_uwire => .uwire,
        .kw_supply0 => .supply0,
        .kw_supply1 => .supply1,
        else => null, // else: not a net_type keyword
    };
}

/// One A.2.2.2 strength keyword: its IEEE 1364-2005 clause 7 level and the
/// side it may occupy. `side` is 0 for `strength0` and `highz0`, 1 for their
/// `1` spellings, and 2 for a `charge_strength` (`small`/`medium`/`large`),
/// which only A.2.1.3's `trireg` alternatives take. The charge words are
/// listed so they can be recognised and refused elsewhere.
pub const StrengthWord = struct { level: Ast.Strength, side: u8 };
comptime {
    std.debug.assert(@sizeOf(StrengthWord) == 2); // a `strength_words` value: two bytes
}
const strength_words = std.StaticStringMap(StrengthWord).initComptime(.{
    .{ "supply0", StrengthWord{ .level = .supply, .side = 0 } },
    .{ "strong0", StrengthWord{ .level = .strong, .side = 0 } },
    .{ "pull0", StrengthWord{ .level = .pull, .side = 0 } },
    .{ "weak0", StrengthWord{ .level = .weak, .side = 0 } },
    .{ "highz0", StrengthWord{ .level = .highz, .side = 0 } },
    .{ "supply1", StrengthWord{ .level = .supply, .side = 1 } },
    .{ "strong1", StrengthWord{ .level = .strong, .side = 1 } },
    .{ "pull1", StrengthWord{ .level = .pull, .side = 1 } },
    .{ "weak1", StrengthWord{ .level = .weak, .side = 1 } },
    .{ "highz1", StrengthWord{ .level = .highz, .side = 1 } },
    // side 2: a charge strength, which belongs to neither.
    .{ "small", StrengthWord{ .level = .small, .side = 2 } },
    .{ "medium", StrengthWord{ .level = .medium, .side = 2 } },
    .{ "large", StrengthWord{ .level = .large, .side = 2 } },
});

/// Returns the strength keyword at token `i`, or null. Every strength spelling
/// lexes as `.kw_reserved` except `supply0`/`supply1`, which are also A.2.2.1
/// net types with their own tags, so both are looked up by spelling.
pub fn strengthWord(self: *const Parser, i: u32) ?StrengthWord {
    return switch (self.tags[i]) {
        .kw_reserved, .kw_supply0, .kw_supply1 => strength_words.get(self.tokenText(i)),
        else => null, // else: no other tag can spell a strength
    };
}

/// Parses an A.2.2.2 `drive_strength` into `s0`/`s1`: one 0-side and one
/// 1-side strength, in either order, not both `highz`. Precondition: the
/// cursor is on a `(` the caller has decided opens a strength.
pub fn parseDriveStrength(self: *Parser, s0: *Ast.Strength, s1: *Ast.Strength) Error!void {
    _ = try self.expect(.lparen);
    const first_tok = self.pos;
    const a = strengthWord(self, self.pos) orelse return self.failAt(self.pos, .E0207, "found {s}, which is not a drive strength", .{self.found(self.pos)});
    self.pos += 1;
    _ = try self.expect(.comma);
    const b = strengthWord(self, self.pos) orelse return self.failAt(self.pos, .E0207, "found {s}, which is not a drive strength", .{self.found(self.pos)});
    self.pos += 1;
    _ = try self.expect(.rparen);
    // `(strong0, pull0)` derives from no alternative of A.2.2.2.
    if (a.side == b.side or a.side == 2 or b.side == 2)
        return self.failAt(first_tok, .E0207, "a drive strength pairs one 0-side with one 1-side strength", .{});
    s0.* = if (a.side == 0) a.level else b.level;
    s1.* = if (a.side == 1) a.level else b.level;
    // A.2.2.2 pairs `highz0`/`highz1` only with a real strength on the other
    // side, and IEEE 1364-2005 §6.1.4 says why: "(highz1, highz0) and
    // (highz0, highz1) shall be treated as illegal constructs".
    if (s0.* == .highz and s1.* == .highz)
        return self.failAt(first_tok, .E0207, "§6.1.4: both drive strengths cannot be high impedance", .{});
}

/// Parses A.2.1.3's `charge_strength ::= ( small ) | ( medium ) | ( large )`,
/// which only `trireg` takes. Reports E0257 for a charge strength on any other
/// net type, so `wire (small) w;` is refused. Cursor on the `(`.
pub fn parseChargeStrength(self: *Parser, kind: Ast.NetKind) Error!Ast.Strength {
    _ = try self.expect(.lparen);
    const tok = self.pos;
    const w = strengthWord(self, self.pos) orelse return self.failAt(tok, .E0207, "found {s}, which is not a charge strength", .{self.found(tok)});
    self.pos += 1;
    _ = try self.expect(.rparen);
    if (kind != .trireg or w.side != 2)
        return self.failAt(tok, .E0257, "a charge strength is only legal on a trireg", .{});
    return w.level;
}

/// A.2.2.3 `delay3 ::= # delay_value | # ( mintypmax_expression [ ,
/// mintypmax_expression [ , mintypmax_expression ] ] )`. Cursor on the `#`.
///
/// One value is all three transitions (IEEE 1364-2005 §7.14). Two leave
/// `off` unset, because the clause derives it as the smaller of the two and
/// that is arithmetic on the evaluated values, not a syntax node.
pub fn parseDelay3(self: *Parser) Error!Ast.Delay3 {
    return parseDelays(self, true);
}

/// A.2.2.3 `delay2`: a `delay3` with no turn-off value, so a third value is
/// E0210.
pub fn parseDelay2(self: *Parser) Error!Ast.Delay3 {
    return parseDelays(self, false);
}

/// Parses an A.2.2.3 `delay_value ::= unsigned_number | real_number |
/// identifier`, the operand of a `#` with no parenthesis (A.6.5's
/// `delay_control` too): one primary, never an expression. `wire #3 [7:0] w`
/// must not read `3[7:0]` (#63), and `buf #d (g, in)` must not read the call
/// `d(g, in)`. A sized or based number is no unsigned_number (E0207): it needs
/// the parenthesized form, `#(4'd2)`.
pub fn parseDelayValue(self: *Parser) Error!Ast.ExprId {
    const tok = self.pos;
    if (self.identLike(tok) and self.peekAt(1) != .dot)
        return self.file.exprs.add(self.arena, .{ .tag = .ident, .main_tok = tok, .str = try self.expectIdent() });
    if (self.peek() == .int_literal and std.mem.findScalar(u8, self.tokenText(tok), '\'') != null)
        return self.failAt(tok, .E0207, "found {s}", .{self.found(tok)});
    return parse_expr.parsePrimary(self);
}

/// The body of `parseDelay3` (`three`) and `parseDelay2`. Holds
/// `in_digital_delay` for the whole bracket, so §2.6.2's scale-factor check
/// (E0247) sees every value, a discarded min/max arm included.
fn parseDelays(self: *Parser, three: bool) Error!Ast.Delay3 {
    const saved_delay = self.in_digital_delay;
    self.in_digital_delay = true;
    defer self.in_digital_delay = saved_delay;
    _ = try self.expect(.hash);
    if (!self.eat(.lparen)) {
        const v = try parseDelayValue(self);
        return .{ .rise = v, .fall = v, .off = v };
    }
    var out: Ast.Delay3 = .{};
    out.rise = try parse_expr.parseMinTypMax(self);
    out.fall = out.rise;
    out.off = out.rise;
    if (self.eat(.comma)) {
        out.fall = try parse_expr.parseMinTypMax(self);
        out.off = if (three and self.eat(.comma)) try parse_expr.parseMinTypMax(self) else .none;
    }
    // After the third value the production admits only `)`. E0210 names the
    // missing parenthesis; E0207 would send the reader to the previous
    // statement.
    if (self.peek() != .rparen) return self.failAt(self.pos, .E0210, "found {s}", .{self.found(self.pos)});
    self.pos += 1;
    return out;
}

/// Parses an A.2.1.3 `list_of_net_identifiers ;` (§3.6.3) after the discipline
/// or net type: an optional range and `delay3`, then the names. A name that is
/// a header port binds the discipline to that port instead of declaring a new
/// net, so lowering sees one object per terminal. The range and delay apply to
/// every name. A §3.6.3.2 `= expression` nodeset is read unless `is_ground`.
pub fn parseNetNames(self: *Parser, b: *parse_module.Body, disc: Ast.StrId, kind: Ast.NetKind, is_ground: bool, st: Ast.NetStrength, signed: bool) Error!void {
    const range: ?Ast.Dim = try parse_decl.optDim(self);
    // A.2.1.3 puts `[ delay3 ]` between the range and the name list, and it
    // belongs to the net, not to the optional assignment: `wire #3 y = ~a;`
    // delays y's own transition. Not gated on `digital`: §1.1 includes all of
    // IEEE 1364, and A.2.1.3 grants the bracket to every alternative. Analog
    // lowering does not read it.
    const delay: Ast.Delay3 = if (self.peek() == .hash) try parseDelay3(self) else .{};
    // A.2.1.3 writes `[ range ] [ delay3 ]` in that order, so a range after
    // the delay is a syntax error, named as one (#63).
    if (delay.rise != .none and self.peek() == .lbracket)
        return self.failAt(self.pos, .E0207, "A.2.1.3: a net's range comes before its delay (`wire [7:0] #3 w;`), found `[` after the delay", .{});
    // A.2.1.3 lists either `list_of_net_identifiers` or
    // `list_of_net_decl_assignments`, never a mix (E0292): the first name
    // decides which.
    var assigns: ?bool = null;
    while (true) {
        const tok = self.pos;
        // Annex F.2.1 step 3 / §3.10 order 1: an out-of-context declaration,
        // `electrical top.middle.bottom.sig;`, "overrides any discipline which
        // may be declared for sig in the module where sig was declared". The
        // dotted name never matches `findPort`, so it lands as a net
        // declaration under its path and elaboration reads it as one.
        const name = try parse_hier.parseDottedPath(self, false, null);
        // A.2.3 `ams_net_identifier ::= net_identifier { dimension }`. The
        // digital engine makes one net per element; analog lowering has no
        // array of nodes, so an analog parse refuses it here.
        const dims = try parse_decl.parseDims(self);
        if (dims.len != 0 and !self.digital) try self.report(tok, .E0205, "a net array (IEEE 1364-2005 §4.9.1) in an analog compilation", .{});
        // §3.6.3.2 `net_decl_assignment`: "the initializer shall be a
        // constant_expression and will be used as a nodeset value for the
        // potential of the net by the analog solver". It is an initial guess
        // for the host's solver, not an assignment. `ground` has no such form
        // (Syntax 3-7), so its `=` stays E0207. Lowering judges both rules:
        // non-constant is E0365, a non-continuous discipline is E0366.
        const nodeset: Ast.ExprId = if (!is_ground and self.eat(.assign_eq))
            try parse_expr.parseExpr(self)
        else
            .none;
        const has_init = nodeset != .none;
        if (assigns) |first| if (first != has_init)
            try self.report(tok, .E0292, "`{s}` {s}, and the first name {s}", .{
                self.file.str(name),
                if (has_init) "has an initializer" else "has no initializer",
                if (has_init) "has none" else "has one",
            });
        if (assigns == null) assigns = has_init;
        // IEEE 1364-2005 §4.4: "Drive strength shall only be used when placing
        // a continuous assignment on a net in the same statement that
        // declares the net."
        if (st.drive and nodeset == .none)
            return self.failAt(tok, .E0207, "§4.4: a drive strength is only legal on a net declaration assignment", .{});
        // Only the first declaration binds. A port that already has a
        // discipline gets a net entry instead, so lowering sees both and can
        // apply §7.4.4 (E0902). The entry adds no node: `internNode` finds the
        // port's slot by name.
        const port = if (is_ground) null else findPort(b, name);
        if (port) |p| {
            // A discipline declaration is §7.4.4's to judge (E0902).
            if (b.ansi and disc == .none) try self.report(tok, .E0218, "`{s}`", .{self.file.str(name)});
            if (signed) p.is_signed = true;
        }
        // IEEE 1364-2005 §12.3.3 completes a port with one type declaration;
        // a second `wire x;` in a digital parse is a net of its own, for the
        // engine's duplicate check (§4.11). A discipline after the net type
        // (`wire x; ddiscrete x;`, VAMS §7.3.2) still completes the port: it
        // sets the discipline and keeps the type already folded.
        const completes: ?*Ast.Port = if (port) |p|
            (if (p.discipline == .none and (!p.typed or disc != .none)) p else null)
        else
            null;
        if (completes) |p| {
            const again = p.typed;
            if (self.digital) p.typed = true;
            // §3.6.3.1: "the description attribute may also be specified on
            // the port declaration line ... the last attribute value shall be
            // used". This line appends no row, so its prefix joins the port's.
            try self.copyAttributes(self.item_tok, p.main_tok);
            p.discipline = disc;
            // §6.5.2.2: this is the port type declaration. Recorded beside the
            // direction declaration's range, not over it (`Ast.Port.type_range`).
            if (!again) p.type_range = range;
            // The net type too: §7.9 resolves by it, so `tri0 p;` on a port
            // must not stay a `wire`. A discipline-only declaration passes
            // `.wire`, A.2.1.3's default.
            if (!again) p.kind = kind;
            // A Port has no initializer slot, so `electrical p = 5.0;` on a
            // header port gets a net entry with no discipline for the
            // nodeset. The empty discipline keeps it out of §7.4.4 (E0902),
            // and `internNode` finds the port's slot without overwriting it.
            if (nodeset != .none) try b.nets.append(self.arena, .{
                .name = name,
                .range = range,
                .init = nodeset,
                .main_tok = tok,
            });
        } else {
            try b.nets.append(self.arena, .{
                .name = name,
                .kind = kind,
                .discipline = disc,
                .is_ground = is_ground,
                .range = range,
                .dims = dims,
                .is_signed = signed,
                .charge = st.charge,
                .strength0 = st.strength0,
                .strength1 = st.strength1,
                .delay = delay,
                .init = nodeset,
                .main_tok = tok,
            });
        }
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// Parses both arms of a §3.12 / A.2.1.3 `branch_declaration`, cursor on
/// `branch`:
///
///     branch ( a [, b] )  list_of_branch_identifiers ;
///     branch ( < p > )    list_of_branch_identifiers ;   // Syntax 3-9
///
/// The second is a §3.12.1 port branch, the quantity `I(<p>)` reads, given a
/// name. A.2.3's optional `[ range ]` per name declares a branch array over
/// one terminal pair; lowering expands it, where the bounds can be folded.
pub fn parseBranchDecl(self: *Parser, b: *parse_module.Body) Error!void {
    self.pos += 1; // 'branch'
    _ = try self.expect(.lparen);
    const is_port_branch = self.eat(.lt);
    const hi = try parse_expr.parseNetRef(self);
    var lo: Ast.ExprId = .none;
    if (is_port_branch) {
        _ = try self.expect(.gt);
    } else if (self.eat(.comma)) {
        lo = try parse_expr.parseNetRef(self);
    }
    _ = try self.expect(.rparen);
    while (true) {
        const name_tok = self.pos;
        const name = try self.expectIdent();
        try b.branches.append(self.arena, .{
            .name = name,
            .hi = hi,
            .lo = lo,
            .is_port_branch = is_port_branch,
            .range = try parse_decl.optDim(self),
            .main_tok = name_tok,
        });
        if (!self.eat(.comma)) break;
    }
    _ = try self.expect(.semicolon);
}

/// Parses A.2.1.3's two `wreal` alternatives, §3.7's real net, into
/// `b.nets`:
///
///     | wreal [ discipline_identifier ] [ range ] list_of_net_identifiers ;
///     | wreal [ discipline_identifier ] [ range ] list_of_net_decl_assignments ;
///
/// `wreal` is not an A.2.2.1 `net_type`, so it takes no strength bracket and
/// no `vectored`/`scalared`. Annex C.4 removes it from the Verilog-A subset
/// only; in Verilog-AMS §3.7 lets the analog block read one.
pub fn parseWrealDecl(self: *Parser, b: *parse_module.Body) Error!void {
    self.pos += 1;
    // `[ discipline_identifier ]`: an identifier followed by another
    // identifier, `optPortType`'s lookahead.
    var ignored: Ast.NetKind = .wire;
    var signed = false;
    const disc = try optPortType(self, &ignored, &signed);
    try parseNetNames(self, b, disc, .wreal, false, .{}, signed);
}
