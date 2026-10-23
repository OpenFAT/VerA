//! Annex A.1.2 source_text, A.1.1 library source text, A.1.5 configurations.
//!
//! In: the token stream at file scope. Out: the top-level `Ast` items: module, nature,
//! discipline, connectrules, paramset, library, config and primitive declarations,
//! each parsed by the file that owns its grammar (`udp.zig` for a primitive).
//!
//! LRM clauses cited: §1, §1.1, §2.2, §2.7, §6.2, §6.4, §7.6, §7.7, §10.6.

const std = @import("std");
const parser = @import("../parser.zig");
const Parser = parser.Parser;
const parse_module = @import("module.zig");
const parse_discipline = @import("discipline.zig");
const parse_hier = @import("hier.zig");
const parse_udp = @import("udp.zig");
const parse_paramset = @import("paramset.zig");
const parse_connectrules = @import("connectrules.zig");
const token = @import("../token.zig");
const lexer = @import("../lexer.zig");
const Ast = @import("../ast.zig");
const Error = parser.Error;
const diag = @import("diag");

// -----------------------------------------------------------------------
// A.1.2 source_text
// -----------------------------------------------------------------------

/// Parses the whole token stream as annex A `source_text` and returns
/// `self.file` with every description appended after any seeded ones.
/// Returns `error.ParseError` if any diagnostic was an error; the
/// diagnostics are in `self.bag`.
/// Annex C.4 "the domain binding type discrete shall be an error in
/// Verilog-A": E0250 at each port, net or `reg` naming a discipline of
/// domain discrete. The definition itself is ignored (C.17).
fn refuseDiscreteUses(self: *Parser, disciplines: []const Ast.DisciplineDecl, modules: []const Ast.ModuleDecl) error{OutOfMemory}!void {
    for (modules) |m| {
        for (m.ports) |x| try refuseDiscreteUse(self, disciplines, x.discipline, x.main_tok);
        for (m.nets) |x| try refuseDiscreteUse(self, disciplines, x.discipline, x.main_tok);
        for (m.vars) |x| try refuseDiscreteUse(self, disciplines, x.discipline, x.main_tok);
    }
}

fn refuseDiscreteUse(self: *Parser, disciplines: []const Ast.DisciplineDecl, name: Ast.StrId, tok: u32) error{OutOfMemory}!void {
    if (name == .none) return;
    for (disciplines) |d| if (d.name == name and d.domain == .discrete)
        return self.refuseDigital(tok, "domain discrete");
}

pub fn parseSourceFile(self: *Parser) Error!Ast.SourceFile {
    try self.access_names.put(self.arena, "V", {});
    try self.access_names.put(self.arena, "I", {});
    try checkEscapes(self);

    // Seeded (`initSeeded`), these already hold the prefix's declarations in
    // source order; unseeded, they are empty.
    var modules: std.ArrayList(Ast.ModuleDecl) = .empty;
    var disciplines: std.ArrayList(Ast.DisciplineDecl) = .empty;
    var natures: std.ArrayList(Ast.NatureDecl) = .empty;
    var paramsets: std.ArrayList(Ast.ParamsetDecl) = .empty;
    var connectrules: std.ArrayList(Ast.ConnectRulesDecl) = .empty;
    var udps: std.ArrayList(Ast.UdpDecl) = .empty;
    var configs: std.ArrayList(Ast.ConfigDecl) = .empty;
    try modules.appendSlice(self.arena, self.file.modules);
    try disciplines.appendSlice(self.arena, self.file.disciplines);
    try natures.appendSlice(self.arena, self.file.natures);
    try paramsets.appendSlice(self.arena, self.file.paramsets);
    try connectrules.appendSlice(self.arena, self.file.connectrules);
    try udps.appendSlice(self.arena, self.file.udps);
    try configs.appendSlice(self.arena, self.file.configs);

    // Every arm but `.eof` consumes: a description, a directive, or
    // `recoverTopLevel`'s one token at least. A pass that loops without
    // moving would loop forever.
    var attr_at: u32 = undefined;
    while (true) : (std.debug.assert(self.pos > attr_at)) {
        attr_at = self.pos;
        try self.skipAttributes();
        const before = self.pos;
        try self.refuseAms();
        if (self.verilog_a) if (self.digitalItem()) |w| try self.refuseDigital(self.pos, w);
        switch (self.peek()) {
            // §3.8: an attribute instance is "a prefix attached to" what follows it.
            .eof => {
                try self.attributesEnd(attr_at);
                break;
            },
            // §10.6: legal only here, "outside of a design element".
            .dir_begin_keywords, .dir_end_keywords => keywordsDirective(self) catch |e| {
                if (e == error.OutOfMemory) return e;
                recoverTopLevel(self, before);
            },
            // IEEE 1364 §19.6: between design elements is where `resetall
            // belongs; the preprocessor has already applied it.
            .dir_resetall, .dir_outside_module => self.pos += 1,
            // A.1.2 `module_keyword ::= module | macromodule`. §6.2: "The
            // keyword macromodule can be used interchangeably with the
            // keyword module to define a module. An implementation may
            // choose to treat module definitions beginning with the
            // macromodule keyword differently." VerA treats them the same.
            // `connectmodule` (§7.6, Syntax 7-4) has the same header, items
            // and `endmodule`; `Ast.ModuleDecl.is_connect` records it.
            .kw_module, .kw_macromodule, .kw_connectmodule => try element(self, before, &modules, parse_module.parseModule(self)),
            .kw_discipline => try element(self, before, &disciplines, parse_discipline.parseDiscipline(self)),
            .kw_nature => try element(self, before, &natures, parse_discipline.parseNature(self)),
            // §6.4 / A.1.9 paramset_declaration. §6.4 makes a paramset
            // instantiable "exactly like a module"; `elab/elaborate.zig`
            // applies it.
            .kw_paramset => try element(self, before, &paramsets, parse_paramset.parseParamset(self)),
            // §7.7 / A.1.8 connectrules_declaration, read by annex F.2
            // discipline resolution (`elab/elaborate.zig`).
            .kw_connectrules => try element(self, before, &connectrules, parse_connectrules.parseConnectRules(self)),
            // Annex B reserves `primitive`, `config`, `library` and
            // `include` without a tag of their own, so the spelling is the
            // dispatch.
            .kw_reserved => {
                const w = self.tokenText(self.pos);
                const r: Error!void = if (std.mem.eql(u8, w, "primitive")) udp: {
                    const u = parse_udp.parseUdpDecl(self) catch |e| break :udp e;
                    break :udp udps.append(self.arena, u);
                } else if (std.mem.eql(u8, w, "config"))
                    parseConfigDecl(self, &configs)
                else if (std.mem.eql(u8, w, "library") or std.mem.eql(u8, w, "include"))
                    parseLibraryDecl(self)
                else if (std.mem.eql(u8, w, "specify"))
                    // IEEE 1364-2005 §14.1: "it shall appear inside a module declaration".
                    self.failAt(self.pos, .E0245, "a specify block outside a module (§14.1)", .{})
                else
                    self.failAt(self.pos, .E0201, "`{s}`", .{self.found(self.pos)});
                r catch |e| {
                    if (e == error.OutOfMemory) return e;
                    recoverTopLevel(self, before);
                };
            },
            else => { // else: not a description: E0201
                try self.report(self.pos, .E0201, "`{s}`", .{self.found(self.pos)});
                recoverTopLevel(self, before);
            },
        }
    }

    // §10.6: `begin_keywords "affects all source code that follows the
    // directive, even across source code file boundaries, until the
    // matching `end_keywords directive is encountered", so a stack still
    // open at end of file is not an error
    // (ch10_directives/begin_keywords_unterminated.va).

    if (self.verilog_a) try refuseDiscreteUses(self, disciplines.items, modules.items);
    self.file.modules = modules.items;
    self.file.disciplines = disciplines.items;
    self.file.natures = natures.items;
    self.file.paramsets = paramsets.items;
    self.file.connectrules = connectrules.items;
    self.file.udps = udps.items;
    self.file.configs = configs.items;
    if (self.failed) return error.ParseError;
    return self.file;
}

/// §2.7 Table 2-2 over every string literal still to be parsed, wherever the
/// grammar later takes it: an octal escape above `\377` is E0148, and an
/// escape the table does not list warns W0149 (`stringContents` keeps the
/// character and drops the backslash).
fn checkEscapes(self: *Parser) error{OutOfMemory}!void {
    for (self.tags[self.pos..], self.pos..) |tag, tok| {
        if (tag != .string_literal) continue;
        const span = lexer.tokenSpan(self.src, self.starts, @intCast(tok));
        const text = self.src[span.start..span.end];
        var from: u32 = 0;
        while (lexer.badEscape(text, from)) |b| : (from = b.end) {
            const at: diag.Span = .{ .start = span.start + b.start, .end = span.start + b.end };
            if (b.above_377) self.failed = true;
            try self.bag.add(.parse, if (b.above_377) .E0148 else .W0149, at, "`{s}`", .{text[b.start..b.end]});
        }
    }
}

/// Applies one LRM §10.6 `begin_keywords "<version_specifier>" or
/// `end_keywords at the cursor, selecting which annex B words are reserved
/// for the design elements that follow (see `identLike`). The directives
/// nest, so the previous set is stacked. An unmatched `end_keywords is
/// E0136; an unknown specifier, or one newer than `self.language`, is E0135.
pub fn keywordsDirective(self: *Parser) Error!void {
    const tok = self.pos;
    self.pos += 1;
    if (self.tags[tok] == .dir_end_keywords) {
        self.kw_set = self.kw_stack.pop() orelse
            return self.failAt(tok, .E0136, "", .{});
        return;
    }
    const str = try self.expect(.string_literal);
    const raw = self.tokenText(str);
    const spec = if (raw.len >= 2) raw[1 .. raw.len - 1] else "";
    const known = token.KeywordSet.fromSpecifier(spec);
    // A 1364 language has no Verilog-AMS specifier to name. "1364-2001-noconfig"
    // reserves a subset of "1364-2001" (IEEE 1364-2005 §19.11), so it is no newer.
    const age = if (known == .v1364_2001_noconfig) .v1364_2001 else known;
    const set = if (known != null and @backingInt(age.?) <= @backingInt(self.language)) known.? else return self.failAt(
        str,
        .E0135,
        "`{s}`",
        .{spec},
    );
    try self.kw_stack.append(self.arena, self.kw_set);
    self.kw_set = set;
}

/// Reports E0202 if the cursor is a `begin_keywords or `end_keywords inside
/// the design element `what`. §10.6: "The `begin_keywords and `end_keywords
/// directives can only be specified outside of a design element (module,
/// primitive, configuration, paramset, connectrules or connectmodule)."
/// `parseModuleItem` covers modules itself.
pub fn outsideDesignElement(self: *Parser, what: []const u8) Error!void {
    const t = self.peek();
    if (t != .dir_begin_keywords and t != .dir_end_keywords) return;
    return self.failAt(self.pos, .E0202, "{s} inside a {s}", .{ token.Tag.lexeme(t).?, what });
}

/// Appends one parsed design element to `list`, or on a syntax error
/// recovers to the next element and appends nothing.
fn element(self: *Parser, before: u32, list: anytype, parsed: anytype) error{OutOfMemory}!void {
    const x = parsed catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        recoverTopLevel(self, before);
        return;
    };
    try list.append(self.arena, x);
}

/// Skips to the next token that can start a top-level description (A.1.2),
/// past any `end*` keyword that closes the construct being abandoned.
/// Always advances at least one token.
fn recoverTopLevel(self: *Parser, before: u32) void {
    // The `.eof` arm never fails, so an unmoved cursor is on a real token.
    if (self.pos == before) std.debug.assert(self.peek() != .eof);
    if (self.pos == before) self.pos += 1;
    while (true) : (self.pos += 1) switch (self.peek()) {
        .eof => return,
        // Every keyword `parseSourceFile` dispatches a description on; a
        // missing one lets one bad description swallow the next.
        // `connectmodule` closes with `endmodule`, covered below.
        .kw_module, .kw_macromodule, .kw_connectmodule, .kw_discipline, .kw_nature, .kw_paramset, .kw_connectrules => return,
        .kw_endmodule, .kw_enddiscipline, .kw_endnature, .kw_endparamset, .kw_endconnectrules => {
            self.pos += 1;
            return;
        },
        // A.1.2's `primitive` and `config` open and close with reserved
        // spellings that have no tag.
        .kw_reserved => if (self.reservedIs(self.pos, "endprimitive") or
            self.reservedIs(self.pos, "endconfig"))
        {
            self.pos += 1;
            return;
        } else if (self.reservedIs(self.pos, "primitive") or
            self.reservedIs(self.pos, "config"))
        {
            if (self.pos != before) return;
        },
        else => {}, // else: any other token belongs to the description being skipped
    };
}

// -----------------------------------------------------------------------
// A.1.1 library source text, A.1.5 configuration: LRM §1.1
// -----------------------------------------------------------------------

/// Parses one of A.1.1's two library-map-only descriptions, then always
/// fails with E0232:
///
///     library_declaration ::=
///             library library_identifier file_path_spec [ { , file_path_spec } ]
///             [ -incdir file_path_spec { , file_path_spec } ] ;
///     include_statement ::= include file_path_spec ;
///
/// Annex A: "The syntax of Verilog-AMS HDL source is derived from the
/// starting symbol source_text. The syntax of a library map file is derived
/// from the starting symbol library_text", and these hang off
/// `library_text` alone. The production is walked first so the diagnostic
/// lands on the keyword of a construct that parsed. `file_path_spec` is
/// taken as a string literal only.
fn parseLibraryDecl(self: *Parser) Error!void {
    // ponytail: an unquoted `file_path` (`./lib/*.v`, as real map files
    // write it) is not a §2.2 token sequence. A library map file needs its
    // own reader, which is the work E0232 says is absent.
    const kw = self.pos;
    const is_library = self.reservedIs(kw, "library");
    self.pos += 1;
    if (is_library) _ = try self.expectIdent();
    while (true) {
        _ = try self.expect(.string_literal);
        if (!self.eat(.comma)) break;
    }
    // `-incdir file_path_spec { , file_path_spec }`, the one option the
    // production has. The `-` and the keyword are two tokens; §2.2 has no
    // production that joins them, so they are matched as two.
    if (is_library and self.eat(.minus)) {
        if (!self.reservedIs(self.pos, "incdir")) return self.failAt(self.pos, .E0207, "found {s}, and `-` begins only A.1.1's `-incdir`", .{self.found(self.pos)});
        self.pos += 1;
        while (true) {
            _ = try self.expect(.string_literal);
            if (!self.eat(.comma)) break;
        }
    }
    _ = try self.expect(.semicolon);
    return self.failAt(kw, .E0232, "`{s}` is a library_description, and this file is source_text", .{self.tokenText(kw)});
}

/// Parses one A.1.5 `config_declaration`, which A.1.2 lists as a
/// `description`, and appends it to `configs`:
///
///     config_declaration ::=
///             config config_identifier ;
///                 design_statement
///                 {config_rule_statement}
///             endconfig
///     design_statement ::= design { [library_identifier.]cell_identifier } ;
///
/// A digital run binds through it (`sim/digital`); an analog compile binds
/// nothing and warns W0253.
fn parseConfigDecl(self: *Parser, configs: *std.ArrayList(Ast.ConfigDecl)) Error!void {
    const kw = self.pos;
    self.pos += 1;
    const name = try self.expectIdent();
    _ = try self.expect(.semicolon);
    // `design_statement` is mandatory and comes first.
    if (!self.reservedIs(self.pos, "design")) return self.failAt(self.pos, .E0207, "found {s}: a config_declaration begins with its `design` statement", .{self.found(self.pos)});
    self.pos += 1;
    var design: std.ArrayList(Ast.LibCell) = .empty;
    while (self.peek() != .semicolon) try design.append(self.arena, try parseLibCell(self));
    self.pos += 1;
    var rules: std.ArrayList(Ast.ConfigRule) = .empty;
    var rule_at: u32 = undefined;
    while (!self.reservedIs(self.pos, "endconfig")) : (std.debug.assert(self.pos > rule_at)) {
        rule_at = self.pos;
        if (self.peek() == .eof) return self.failAt(self.pos, .E0207, "found {s}: no `endconfig` closes the configuration", .{self.found(self.pos)});
        const rule = try parseConfigRule(self);
        // IEEE 1364-2005 §13.3.1.2: "there cannot be more than one default
        // clause that specifies the expansion clause", and liblist is the one
        // a default takes.
        if (rule.select == .default) for (rules.items) |r| if (r.select == .default)
            return self.failAt(rule.main_tok, .E0243, "more than one default clause specifies a liblist (IEEE 1364-2005 §13.3.1.2)", .{});
        try rules.append(self.arena, rule);
    }
    self.pos += 1;
    if (!self.digital) try self.bag.add(.parse, .W0253, lexer.tokenSpan(self.src, self.starts, kw), "", .{});
    try configs.append(self.arena, .{ .name = name, .design = design.items, .rules = rules.items, .main_tok = kw });
}

/// Syntax 13-1 `[library_identifier.]cell_identifier`, without the suffix.
fn parseLibCell(self: *Parser) Error!Ast.LibCell {
    const first = try self.expectIdent();
    if (!self.eat(.dot)) return .{ .cell = first };
    return .{ .lib = first, .cell = try self.expectIdent() };
}

/// Parses one A.1.5 `config_rule_statement`. The five alternatives are
/// three left clauses over two right ones; `default` pairs with `liblist`
/// alone:
///
///     default_clause ::= default
///     inst_clause ::= instance inst_name
///     inst_name ::= topmodule_identifier { . instance_identifier }
///     cell_clause ::= cell [ library_identifier . ] cell_identifier
///     liblist_clause ::= liblist { library_identifier }
///     use_clause ::= use [ library_identifier . ] cell_identifier [ : config ]
fn parseConfigRule(self: *Parser) Error!Ast.ConfigRule {
    const tok = self.pos;
    // `default` is the one A.1.5 word with a tag, shared with A.6.7's
    // `case` default.
    const is_default = self.peek() == .kw_default;
    const is_instance = self.reservedIs(tok, "instance");
    if (!is_default and !is_instance and !self.reservedIs(tok, "cell"))
        return self.failAt(tok, .E0207, "found {s}, which begins no A.1.5 config_rule_statement", .{self.found(tok)});
    self.pos += 1;
    var rule: Ast.ConfigRule = .{ .select = .default, .expand = .{ .liblist = &.{} }, .main_tok = tok };
    if (is_instance) rule.select = .{ .instance = try parse_hier.parseDottedPath(self, false, null) } else if (!is_default) rule.select = .{ .cell = try parseLibCell(self) };
    if (self.reservedIs(self.pos, "liblist")) {
        // IEEE 1364-2005 §13.3.1.4: "It is an error if a library name is
        // included in a cell selection clause and the corresponding expansion
        // clause is a library list expansion clause."
        if (rule.select == .cell and rule.select.cell.lib != .none)
            return self.failAt(tok, .E0243, "a cell clause with a library name takes `use`, not `liblist` (IEEE 1364-2005 §13.3.1.4)", .{});
        self.pos += 1;
        // `liblist { library_identifier }`: no commas, and the empty list
        // is legal (it clears an inherited list).
        var libs: std.ArrayList(Ast.StrId) = .empty;
        while (self.peek() != .semicolon) try libs.append(self.arena, try self.expectIdent());
        rule.expand = .{ .liblist = libs.items };
    } else if (!is_default and self.reservedIs(self.pos, "use")) {
        self.pos += 1;
        var target = try parseLibCell(self);
        // `[ : config ]`: the literal keyword, not a name.
        if (self.eat(.colon)) {
            if (!self.reservedIs(self.pos, "config"))
                return self.failAt(self.pos, .E0207, "found {s}: a use_clause's `:` is followed by the word `config`", .{self.found(self.pos)});
            self.pos += 1;
            target.config = true;
        }
        rule.expand = .{ .use = target };
    } else return self.failAt(
        self.pos,
        .E0207,
        "found {s}: a {s} pairs with `liblist`{s}",
        .{ self.found(self.pos), self.tokenText(tok), if (is_default) "" else " or `use`" },
    );
    _ = try self.expect(.semicolon);
    return rule;
}
