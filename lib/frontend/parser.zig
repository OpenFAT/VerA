//! Parser: token stream -> `Ast.SourceFile` (SoA stores addressed by u32 handles),
//! by recursive descent with precedence climbing for expressions.
//! LRM annex A (grammar), §4.2.2 (precedence), §6.8 (scopes).
//!
//! The grammar is split across `parser/*.zig`, one file per data domain; each
//! holds free functions taking `self: *Parser`. This file owns the cursor,
//! token text, attribute collection and diagnostics.
//!
//! Spine: `parseSourceFile` (source.zig) dispatches each A.1.2 description to
//! the file that owns its grammar. `parseModule` (module.zig) dispatches each
//! A.1.4 item the same way into the scope's `Body` table, which becomes the
//! `Ast.ModuleDecl` at `endmodule`. Statements (stmt.zig) and expressions
//! (expr.zig) are reached from the items. Every node lands in `file`, the
//! `Ast.SourceFile` stores this parse writes and `parseSourceFile` returns.

const std = @import("std");
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const Ast = @import("ast.zig");
const diag = @import("diag");
const deep_stack = @import("base").deep_stack;

/// `ParseError` unwinds to the nearest recovery point (module item, statement or
/// top-level declaration); its diagnostic is already in the bag.
pub const Error = error{ OutOfMemory, ParseError };

/// Native recursion levels one stack segment holds. Past them the next level
/// runs on a fresh `deep_stack` segment, so nesting is bounded by memory, not
/// by the calling thread's stack (`Parser.segment`).
pub const segment_levels = 4096;
/// Levels the caller's own stack holds before the first segment: half the
/// 1024 the parser ran on any caller's stack before segments existed.
pub const caller_levels = 512;

/// Parser state for one token stream. Every allocation comes from `arena`;
/// `src`, `tags` and `starts` are borrowed and must outlive the produced
/// `Ast.SourceFile`, because every interned name is a slice of `src`.
pub const Parser = struct {
    arena: std.mem.Allocator,
    src: []const u8,
    tags: []const token.Tag,
    starts: []const u32,
    pos: u32 = 0,
    /// AST nesting at the cursor: expression, statement and generate-block
    /// levels (`enter`), plus one per link a loop folds into a left-deep
    /// chain (a binary operator, a select, an event `or`), whose tree every
    /// later walk recurses down.
    depth: u32 = 0,
    /// The largest `depth` this parse reached: the nesting hint later stages
    /// size their `deep_stack` by.
    deepest: u32 = 0,
    /// Native recursion levels open (`enter`), and their count when the
    /// current stack segment began (`segment`).
    seg: deep_stack.Segments = .{},
    file: Ast.SourceFile = .empty,
    /// Shared collector. The cap, the dedupe and the rendering all live there.
    bag: *diag.Bag,
    /// Whether this parse reported an error. The bag is shared across stages and
    /// drops entries at its cap and dedupe set, so its length cannot answer.
    failed: bool = false,
    /// §3.6.1.2 nature `access` names. `name(...)` is a branch probe (§4.4.1)
    /// iff the name is in here, otherwise it is a user function call (§4.7).
    /// Seeded with V/I (disciplines.vams, annex D) and grown by every
    /// `access = X;` nature attribute parsed ahead of the module.
    access_names: std.StringHashMapUnmanaged(void) = .empty,
    /// §10.6 reserved-keyword set in effect, and the sets saved by each open
    /// `begin_keywords directive. See `keywordsDirective` and `identLike`.
    kw_set: token.KeywordSet = token.default_keyword_set,
    kw_stack: std.ArrayList(token.KeywordSet) = .empty,
    /// The language this parse accepts (`vera --std=`), which is also §10.6's
    /// "implementation's default set of reserved keywords". Unlike `kw_set` it
    /// changes what parses: under a 1364 set a Verilog-AMS construct is E0242,
    /// because IEEE 1364-2005 annex A has no production for it. Set it with
    /// `setLanguage`.
    language: token.KeywordSet = token.default_keyword_set,
    /// Parsing annex C's Verilog-A subset (`vera --sim=verilogA`): a digital
    /// or mixed-signal construct is E0250 (`refuseDigital`). The annex D
    /// prelude is seeded from a parse without it, so its `discrete`
    /// disciplines stay silent (C.17).
    verilog_a: bool = false,
    /// Inside an `analog function` body (§4.7.1). Two of that clause's bullets
    /// restrict statements the ordinary statement parser also accepts at
    /// module scope, so only the position tells them apart (E0226, E0227).
    in_analog_fn: bool = false,
    /// Parsing an analog block's or analog function's statements, whose
    /// expressions are A.8.3 analog_expressions: A.8.4's analog_primary is
    /// `( analog_expression )`, with no IEEE 1364-2005 §5.3 min:typ:max
    /// (E0295). A parameter declaration inside clears it (`parseParamDecl`).
    analog_expr: bool = false,
    /// The statement being parsed is an A.6.4 `analog_event_statement`: the
    /// body of an analog `@(...)`, or a statement of an
    /// `analog_event_seq_block` in it, where `{ attribute_instance } ;` is an
    /// alternative (no E0219). `parseStmtBody` clears it for every statement
    /// but a block, whose own statements are event statements again.
    analog_event_block: bool = false,
    /// Parsing for the digital executor (`--run`): admits the digital-only
    /// forms everywhere and keeps digital expression shapes unfolded.
    digital: bool = false,
    /// Inside the body of an `initial` or `always` block (§7.2.2's discrete
    /// context). A.6.2/A.6.5 give that body the digital statement forms (a `#`
    /// delay, `wait`, a nonblocking `<=`, intra-assignment timing) in any
    /// module, so they are admitted by position, not by file extension. An
    /// `analog` block has none of them (A.6.4). See `discreteGrammar`.
    in_discrete: bool = false,
    /// The next primary heads a discrete-grammar statement, so a call there
    /// is A.6.9's `task_enable`, not A.8.2's `function_call`: its null
    /// argument is IEEE 1364-2005 §10.2.2's ("A null expression shall not be
    /// used as an argument in a task-enabling statement"), which the digital
    /// engine refuses, not E0289. `parsePrimary` reads and clears it.
    task_enable_head: bool = false,
    /// §2.6.2 forbids scale factors in digital delay expressions. Kept while
    /// parsing delay_control, delay2/delay3 and path_delay_expression so even
    /// a discarded min/max arm is checked before expression folding.
    in_digital_delay: bool = false,
    /// Inside a §7.6 `connectmodule` body. `parseEventTerm` reads it: A.6.5's
    /// `driver_update` is a digital event, and §9.22 paragraph 3 puts the
    /// driver family inside a connect module.
    in_connect_module: bool = false,
    /// §6.6 nesting depth of generate regions and generate construct bodies,
    /// counted together because both gates it feeds only ask "below a
    /// `generate`?". Syntax 6-8's `module_or_generate_item` has no
    /// `generate_region` ("Generate regions do not nest") and no
    /// `parameter_declaration`, so a nonzero depth refuses both (E0228, E0229).
    gen_depth: u32 = 0,
    /// How many generate constructs (loop/if/case, not regions) enclose the
    /// cursor, and an identity for the outermost one. Together they key §6.6.2's
    /// block name space; see `checkGenBlockNames`.
    gen_construct_depth: u32 = 0,
    gen_construct: u32 = 0,
    /// Set by a loop generate for the one `parseGenerateBlock` call that reads
    /// its body. §6.6.2's direct nesting applies to conditional constructs only,
    /// so a loop body is a scope even when it is one bare `if`.
    gen_loop_body: bool = false,
    /// Set while a §6.4 paramset statement is parsed: §6.4.3's
    /// `.module_output_variable_identifier` is then a primary (`parsePrimary`).
    in_paramset: bool = false,
    /// Every §2.9 `attr_spec` of the module being parsed, flattened. Moved into
    /// the `ModuleDecl` at `endmodule` and cleared; see `parseAttributes`.
    attrs: std.ArrayList(Ast.NatureAttr) = .empty,
    /// Nonzero inside an attribute value, where §2.9 bans a nested attribute
    /// instance (E0357).
    attr_depth: u32 = 0,
    /// Parallel to `file.attributes`: the cursor when each binding was
    /// appended. The cursor only moves back in `rewindAttributes`, which
    /// truncates both, so the column is sorted, and a binding a declaration
    /// at token `t` owns was appended with the cursor at or past `t`. That
    /// makes `bindingsFrom` a binary search instead of a scan of the file.
    /// Not part of `Seed`: `initSeeded` rebuilds it from the seeded bindings.
    attr_at: std.ArrayList(u32) = .empty,
    /// The first token of the module item being parsed: the declaration owner
    /// `skipAttributes` bound the item's §2.9 prefix to. `parseNetNames`
    /// copies that prefix to a header port its declaration types, the one
    /// declaration that appends no row of its own (§3.6.3.1: a port's net
    /// takes the attributes of both lines).
    item_tok: u32 = 0,
    /// Stacks for the lists a construct collects while nested constructs
    /// collect theirs: a user pushes above the mark it took, copies its run
    /// out (into the expression pool, or one exact-size arena slice) and
    /// truncates back to the mark on every path, errors included. One growing
    /// buffer per parse replaces an arena list per construct, whose growth
    /// copies and slack the arena never reclaims.
    scratch_exprs: std.ArrayList(Ast.ExprId) = .empty,
    scratch_stmts: std.ArrayList(Ast.StmtId) = .empty,

    /// Asserts `tags` and `starts` have equal length and end in `.eof`.
    pub fn init(
        arena: std.mem.Allocator,
        src: []const u8,
        tags: []const token.Tag,
        starts: []const u32,
        bag: *diag.Bag,
    ) Parser {
        std.debug.assert(tags.len == starts.len);
        std.debug.assert(tags.len > 0 and tags[tags.len - 1] == .eof);
        return .{
            .arena = arena,
            .src = src,
            .tags = tags,
            .starts = starts,
            .bag = bag,
        };
    }

    /// The state a parse of a leading run of tokens leaves behind, so a parse
    /// of a longer stream that begins with that run can resume instead of
    /// redoing it. Built once per process for the annex D/E prelude by
    /// `Preprocessor.preludeAst`, which asserts that every field not listed
    /// here is back at its `init` value when the prefix parse ends.
    ///
    /// A new `Parser` field that a prefix parse can leave dirty must be added
    /// here too; the prelude AST equivalence test in `pp/test.zig` catches the
    /// omission.
    pub const Seed = struct {
        /// Stores and decl lists. See `Ast.SourceFile.seedFrom` for which half
        /// is copied and which is borrowed, and why the borrow is sound.
        file: Ast.SourceFile,
        /// §3.6.1.2 access names in effect at the seam. A list, not the map:
        /// re-inserting a handful of keys is cheaper than cloning a hash map.
        access_names: []const []const u8,
        /// Token index the prefix parse stopped on: its `.eof`, which is the
        /// first token of the resumed parse.
        pos: u32,
        /// §6.6.2 outermost-construct identity, monotonic over the whole file.
        gen_construct: u32,
    };

    /// `init`, then resumes from `seed`. A null `seed` is exactly `init` (the
    /// `--no-std-defs` path). Precondition: `tags` begins with the token run
    /// `seed` was parsed from.
    pub fn initSeeded(
        arena: std.mem.Allocator,
        src: []const u8,
        tags: []const token.Tag,
        starts: []const u32,
        bag: *diag.Bag,
        seed: ?*const Seed,
    ) std.mem.Allocator.Error!Parser {
        var p = init(arena, src, tags, starts, bag);
        const s = seed orelse return p;
        // `root.zig` guarantees the shared prefix: the same `Prelude` seeded the lexer.
        std.debug.assert(s.pos < tags.len);
        p.pos = s.pos;
        p.gen_construct = s.gen_construct;
        try p.file.seedFrom(arena, &s.file);
        // The prefix appended its bindings before the cursor reached `s.pos`;
        // `s.pos` keeps the column sorted and bounds each owner from above.
        try p.attr_at.appendNTimes(arena, s.pos, p.file.attributes.items.len);
        for (s.access_names) |n| try p.access_names.put(arena, n, {});
        return p;
    }

    /// Parses as `set`'s language: it becomes the §10.6 default keyword set and
    /// the ceiling on `begin_keywords` and on Verilog-AMS constructs (E0242).
    pub fn setLanguage(self: *Parser, set: token.KeywordSet) void {
        self.language = set;
        self.kw_set = set;
    }

    /// Reports E0242 if the token at `pos` opens a Verilog-AMS design element
    /// or module item and `language` is a 1364 set. Called where a description
    /// or a module item is dispatched, which is where every AMS construct
    /// starts; below that, such a keyword can only be an identifier. The
    /// construct is then parsed anyway, so the one error is the only one.
    pub fn refuseAms(self: *Parser) error{OutOfMemory}!void {
        const t = self.peek();
        if (@backingInt(self.language) >= @backingInt(token.KeywordSet.vams_2_3) or !token.isKeyword(t)) return;
        const w = self.tokenText(self.pos);
        if (token.isReserved(w, self.language)) return;
        try self.report(self.pos, .E0242, "`{s}` under \"{s}\"", .{ w, self.language.specifier() });
    }

    /// Reports E0250 at `tok`: `what` is outside annex C's Verilog-A subset,
    /// which `vera --sim=verilogA` compiles. Like `refuseAms`, the construct
    /// is then parsed anyway, so the one error is the only one. Asserts
    /// `verilog_a`.
    pub fn refuseDigital(self: *Parser, tok: u32, what: []const u8) error{OutOfMemory}!void {
        std.debug.assert(self.verilog_a);
        try self.report(tok, .E0250, "`{s}` under --sim=verilogA", .{what});
    }

    /// The spelling at the cursor when it opens a description or module item
    /// annex C removes from Verilog-A, else null. Called where a description
    /// or a module item is dispatched, beside `refuseAms`. C.5's operators,
    /// C.7's `casex`/`casez`, C.4's `discrete` domain and `default_discipline`
    /// are judged where they are parsed.
    pub fn digitalItem(self: *const Parser) ?[]const u8 {
        const t = self.peek();
        return switch (t) {
            // C.9 and C.16: the mixed-signal descriptions.
            .kw_connectmodule,
            .kw_connectrules,
            // C.7 "No digital behavior or events": the discrete context, its
            // drivers and its storage, and §4.7's digital function (an analog
            // one opens with `analog`).
            .kw_initial,
            .kw_always,
            .kw_assign,
            .kw_reg,
            .kw_function,
            .kw_tran,
            .kw_rtran,
            .kw_and,
            .kw_nand,
            .kw_or,
            .kw_nor,
            .kw_xor,
            .kw_xnor,
            .kw_buf,
            .kw_not,
            .kw_bufif0,
            .kw_bufif1,
            .kw_notif0,
            .kw_notif1,
            => token.Tag.lexeme(t).?,
            // The IEEE 1364 spellings annex B reserves without a tag of their
            // own (`parseModuleItemBody`'s `.kw_reserved` arm), and C.4's `wreal`.
            .kw_reserved => blk: {
                const w = self.tokenText(self.pos);
                for ([_][]const u8{ "primitive", "config", "library", "task", "specify", "specparam", "pullup", "pulldown", "wreal" }) |d| {
                    if (std.mem.eql(u8, w, d)) break :blk w;
                }
                break :blk if (parse_inst.switch_arms.has(w)) w else null;
            },
            else => null, // else: every other opener is in the subset, or judged where it is parsed
        };
    }

    // Annex A.1.2 source_text, A.1.1 library source text, A.1.5 configurations
    const parse_source = @import("parser/source.zig");
    /// Parses the whole stream. Returns `error.ParseError` at the end if anything
    /// was reported; the AST is then partial and must not be lowered.
    pub const parseSourceFile = parse_source.parseSourceFile;

    // Annex A.1.2 module_declaration and A.1.4 module_item (LRM §6.2, Clause 3)
    const parse_module = @import("parser/module.zig");

    // Annex A.1.6/A.1.7 natures and disciplines (§3.6)
    const parse_discipline = @import("parser/discipline.zig");

    // Annex A.1.9 paramset (LRM §6.4)
    const parse_paramset = @import("parser/paramset.zig");

    // Annex A.1.8 connectrules (LRM §7.7)
    const parse_connectrules = @import("parser/connectrules.zig");

    // Annex A.5 user-defined primitives and their instances (IEEE 1364-2005 Clause 8)
    const parse_udp = @import("parser/udp.zig");

    // Annex A.2.1.1 parameters (§3.4), A.2.1.3 variables and events, A.2.5 dimensions
    const parse_decl = @import("parser/decl.zig");

    // Annex A.2.1.2/A.2.1.3/A.2.2 port, net and branch declarations, strengths and delays
    const parse_net = @import("parser/net.zig");

    // §6.7 / A.9.3 hierarchical names in declaration positions
    const parse_hier = @import("parser/hier.zig");

    // Annex A.2.6 analog functions (§4.7.1), IEEE 1364-2005 A.2.6/A.2.7 digital functions and tasks
    const parse_function = @import("parser/function.zig");

    // Annex A.4.1 module instantiation (LRM §6.2.2), A.3 gates and switches, A.6.2 initial/always
    const parse_inst = @import("parser/inst.zig");

    // Annex A.4.2 generate constructs (LRM §6.6)
    const parse_generate = @import("parser/generate.zig");

    // Annex A.7 specify blocks (IEEE 1364 Clause 14, inherited through LRM §1.1)
    const parse_specify = @import("parser/specify.zig");

    // Annex A.6.4 analog_statement (LRM Clause 5)
    const parse_stmt = @import("parser/stmt.zig");

    // Annex A.8.3 expressions (§4.1, §4.2 precedence climbing), A.8.2 calls and branch probes
    const parse_expr = @import("parser/expr.zig");

    // Annex A.8.1 concatenations and assignment patterns (§4.2.13, §4.2.14)
    const parse_concat = @import("parser/concat.zig");

    // Literals: §2.6 numbers, §2.7 strings
    const parse_literal = @import("parser/literal.zig");

    // -----------------------------------------------------------------------
    // Token access: LRM §2.2 (the stream), §2.8 (identifiers)
    // -----------------------------------------------------------------------

    /// Whether the A.6.5 forms an analog statement lacks (`#`, `wait`, `<=`,
    /// intra-assignment timing) parse here: in a digital source, or in the
    /// body of an `initial`/`always` block anywhere.
    pub fn discreteGrammar(self: *const Parser) bool {
        return self.digital or self.in_discrete;
    }

    /// Returns the tag at the cursor without consuming it.
    pub fn peek(self: *const Parser) token.Tag {
        return self.tags[self.pos];
    }

    /// Returns the tag `n` tokens ahead, clamped to the final `.eof`.
    pub fn peekAt(self: *const Parser, n: u32) token.Tag {
        const i = self.pos + n;
        return self.tags[@min(i, self.tags.len - 1)];
    }

    /// Consumes the next token if it is `t`; returns whether it did.
    pub fn eat(self: *Parser, t: token.Tag) bool {
        if (self.peek() != t) return false;
        self.pos += 1;
        return true;
    }

    /// Returns the source text of token `i`, without the leading `\` of an
    /// escaped identifier. Tokens store no length, so the lexer re-scans the
    /// lexeme from its start; that is exact because the lexer's `next()` is a
    /// pure function of (src, pos). Cost: one token scan per call.
    pub fn tokenText(self: *const Parser, i: u32) []const u8 {
        // An identifier or keyword is one §2.8 run (`lexIdentOrKeyword`), so its
        // end needs no re-lex and no keyword lookup.
        if (self.tags[i] == .identifier or token.isKeyword(self.tags[i])) {
            const start = self.starts[i];
            var end = start;
            while (end < self.src.len and lexer.isIdentChar(self.src[end])) end += 1;
            return self.src[start..end];
        }
        const lx: lexer.Lexer = .{ .src = self.src };
        const text = lx.tokenText(self.starts[i]);
        // §2.8.1: the `\` opens the identifier but is not part of the name.
        // The terminator is not in the span, so only the head is stripped.
        return if (self.tags[i] == .escaped_identifier) text[1..] else text;
    }

    /// Whether token `i` is the reserved spelling `w`. Annex B's out-of-subset
    /// keywords share the `.kw_reserved` tag, so a grammar that needs one of
    /// them by name asks here.
    pub fn reservedIs(self: *const Parser, i: u32, w: []const u8) bool {
        return self.tags[i] == .kw_reserved and std.mem.eql(u8, self.tokenText(i), w);
    }

    /// Consumes `w` if it is the next token; one of A.7's `=>`, `*>` and `&&&`.
    /// The lexer tags them `.invalid` because outside a specify block none is
    /// an operator, so the spelling is the test.
    pub fn eatSymbol(self: *Parser, w: []const u8) bool {
        if (self.peek() != .invalid or !std.mem.eql(u8, self.tokenText(self.pos), w)) return false;
        self.pos += 1;
        return true;
    }

    /// Byte just past the previous token: where a missing terminator has to be
    /// typed, and so where `expect`'s insertion fix is anchored. `tokenText`
    /// strips an escaped identifier's `\` though it is in the source span,
    /// and `.eof` has no text.
    fn endOfPrev(self: *const Parser) u32 {
        if (self.pos == 0) return self.starts[0];
        const i = self.pos - 1;
        if (self.tags[i] == .eof) return self.starts[i];
        const backslash: u32 = @intFromBool(self.tags[i] == .escaped_identifier);
        return self.starts[i] + backslash + @as(u32, @intCast(self.tokenText(i).len));
    }

    /// Consumes a `t` token and returns its index. Otherwise reports E0207,
    /// with an insertion fix when `t` is a terminator, and returns
    /// `error.ParseError` with the cursor unmoved.
    pub fn expect(self: *Parser, t: token.Tag) Error!u32 {
        if (self.peek() != t) {
            // The title is only "unexpected token", so the caret carries what
            // the grammar wanted here.
            var d = self.failWith(self.pos, .E0207);
            d.msg("found {s}", .{self.found(self.pos)});
            d.point("expected {s}", .{tagDesc(t)});
            // A missing terminator belongs after the previous construct, but
            // the caret lands on whatever came next, often on the next line.
            // The fix points at the column where it has to be typed.
            if (isTerminator(t)) if (token.Tag.lexeme(t)) |text| {
                const at = self.endOfPrev();
                d.suggest(
                    .{ .span = .{ .start = at, .end = at }, .replacement = text },
                    "insert `{s}` after the previous {s}",
                    .{ text, if (t == .semicolon) "statement" else "item" },
                );
            };
            try d.emit();
            return error.ParseError;
        }
        const i = self.pos;
        self.pos += 1;
        return i;
    }

    /// Whether token `i` can stand where the grammar wants an identifier.
    ///
    /// §2.8/§2.8.1 identifiers always can, and so can a keyword the active
    /// §10.6 set does not reserve: under `begin_keywords "1364-2005",
    /// `input sin;` is "OK since sin is not a keyword in 1364-2005". §10.6
    /// also says the directive does "not affect the ... tokens", which is why
    /// this is a parser rule: `analog` stays `kw_analog` in the same module.
    pub fn identLike(self: *const Parser, i: u32) bool {
        const j = @min(i, self.tags.len - 1);
        return switch (self.tags[j]) {
            .identifier, .escaped_identifier => true,
            // Default set ⇒ every keyword is reserved: no text to fetch.
            else => |t| self.kw_set != token.default_keyword_set and // else: a keyword is an identifier only when the keyword set frees it
                token.isKeyword(t) and
                !token.isReserved(self.tokenText(j), self.kw_set),
        };
    }

    /// Consumes a §2.8/§2.8.1 identifier (or a keyword `identLike` frees) and
    /// returns it interned. Reports E0208 otherwise.
    pub fn expectIdent(self: *Parser) Error!Ast.StrId {
        if (!self.identLike(self.pos))
            return self.failAt(self.pos, .E0208, "found {s}", .{self.found(self.pos)});
        const s = try self.internTok(self.pos);
        self.pos += 1;
        return s;
    }

    /// `expectIdent`, or a §9.18 system name (`$mfactor`) where the grammar
    /// admits one as a parameter identifier.
    pub fn expectIdentOrSys(self: *Parser) Error!Ast.StrId {
        if (self.peek() != .system_identifier) return self.expectIdent();
        const s = try self.internTok(self.pos);
        self.pos += 1;
        return s;
    }

    /// Interns token `i`'s text as a name. Each period in an escaped identifier
    /// (§2.8.1: `\x.y ` is the identifier `x.y`) becomes a space, so that after
    /// this point a period in a name always means a hierarchy separator
    /// (`Elaborate.sep`). Without it, `\x.y` inside instance `u` and net `y`
    /// inside `u.x` would flatten to the same `u.x.y`. A space cannot occur in
    /// an identifier, so the mapping is injective; `naming.sanitize` later
    /// spells it `Z20`. Allocates only for an escaped name with a period.
    pub fn internTok(self: *Parser, i: u32) Error!Ast.StrId {
        // The bytes are spelled out, not imported from `ir/`: the frontend owns
        // the source half of this convention and does not depend on the IR.
        const text = self.tokenText(i);
        if (self.tags[i] != .escaped_identifier) return self.file.intern(self.arena, text);
        // IEEE 1364-2005 §3.7.3: a system task or function "shall not be
        // escaped", so `\$display` keeps its `\` and names no system task.
        if (text[0] == '$') return self.file.intern(self.arena, (lexer.Lexer{ .src = self.src }).tokenText(self.starts[i]));
        if (std.mem.findScalar(u8, text, '.') == null)
            return self.file.intern(self.arena, text);
        const buf = try self.arena.dupe(u8, text);
        std.mem.replaceScalar(u8, buf, '.', ' ');
        return self.file.intern(self.arena, buf);
    }

    /// §2.9 Syntax 2-4 / A.9.1:
    ///
    ///     attribute_instance ::= (* attr_spec { , attr_spec } *)
    ///     attr_spec          ::= attr_name [ = constant_expression ]
    ///
    /// Parses any attribute instances at the cursor and appends every spec to
    /// `self.attrs`, which `parseModule` hands to the enclosing module for
    /// validation. Also binds this prefix to the following declaration;
    /// statement and expression callers refine that parsed owner below.
    ///
    /// A malformed attribute is reported and the cursor resynchronized past its
    /// `*)`, so the caller always lands past the instance. Only OOM propagates.
    pub fn skipAttributes(self: *Parser) error{OutOfMemory}!void {
        const mark = self.attrs.items.len;
        self.parseAttributes() catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            // Already reported. Resynchronize past the closing `*)` so one bad
            // attribute does not also cost the decorated declaration a diagnostic.
            while (true) : (self.pos += 1) switch (self.peek()) {
                .eof => return,
                .attr_close => {
                    self.pos += 1;
                    return;
                },
                else => {}, // else: any other token is inside the attribute being skipped
            };
        };
        if (self.attrs.items.len != mark) try self.appendBinding(.{
            .owner = .{ .kind = .declaration, .tok = self.pos },
            .specs = try self.arena.dupe(Ast.NatureAttr, self.attrs.items[mark..]),
        });
    }

    /// For a list loop that ran `skipAttributes` from token `from` and now
    /// stops at its closer (`end`, `endmodule`, end of file, ...). §2.9 makes
    /// an attribute instance "a prefix attached to" what follows it, so one
    /// read here prefixes nothing: E0207 at the instance (#49). Every item
    /// list reports it this way, the file's top level included.
    pub fn attributesEnd(self: *Parser, from: u32) error{OutOfMemory}!void {
        if (self.pos != from) try self.report(from, .E0207, "found {s}: an attribute instance prefixes nothing", .{self.found(self.pos)});
    }

    /// The token past the attribute instances at the cursor, found by
    /// scanning to each `*)` without parsing, so nothing is read, bound or
    /// reported. A statement loop asks it whether a prefix runs into the
    /// loop's closer, which `parseStmt` would otherwise take for the start of
    /// a statement (#66). Cost: the instances' tokens.
    pub fn pastAttributes(self: *const Parser) u32 {
        var i = self.pos;
        while (self.tags[i] == .attr_open) {
            while (self.tags[i] != .attr_close and self.tags[i] != .eof) i += 1;
            if (self.tags[i] == .eof) break;
            i += 1;
        }
        return i;
    }

    /// The one writer of `file.attributes`' rows, keeping `attr_at` beside it.
    /// Asserts a declaration owner is not past the cursor, which is what lets
    /// `bindingsFrom` skip every row appended before the cursor reached it.
    fn appendBinding(self: *Parser, binding: Ast.AttributeBinding) error{OutOfMemory}!void {
        std.debug.assert(self.attr_at.items.len == self.file.attributes.items.len);
        std.debug.assert(binding.owner.kind != .declaration or binding.owner.tok <= self.pos);
        try self.attr_at.ensureUnusedCapacity(self.arena, 1);
        try self.file.attributes.append(self.arena, binding);
        self.attr_at.appendAssumeCapacity(self.pos);
    }

    /// Index of the first `file.attributes` row appended with the cursor at or
    /// past `tok`. No earlier row is owned by a declaration at `tok`.
    /// Cost: O(log n) in the file's bindings.
    fn bindingsFrom(self: *const Parser, tok: u32) usize {
        // Most declarations and statements carry no attribute: then the
        // newest row is older than `tok`, and so is every other.
        const rows = self.attr_at.items;
        if (rows.len == 0 or rows[rows.len - 1] < tok) return rows.len;
        const order = struct {
            fn f(want: u32, at: u32) std.math.Order {
                return std.math.order(want, at);
            }
        }.f;
        return std.sort.lowerBound(u32, rows, tok, order);
    }

    /// `skipAttributes`, then binds what it read to `owner` (an operator or
    /// call suffix, or a statement prefix) instead of the next declaration.
    /// Asserts a `.declaration` owner's token is not past the cursor.
    pub fn ownedAttributes(self: *Parser, owner: Ast.AttributeOwner) error{OutOfMemory}!void {
        std.debug.assert(owner.kind != .declaration or owner.tok <= self.pos); // `attr_at`'s invariant
        const first = self.file.attributes.items.len;
        try self.skipAttributes();
        // §2.9/IEEE §3.8 prohibit attributes inside an attribute value;
        // attr_depth diagnoses them. A successful run adds only this one
        // prefix binding, whose specs include every adjacent instance.
        std.debug.assert(self.file.attributes.items.len <= first + 1);
        for (self.file.attributes.items[first..]) |*a| a.owner = owner;
    }

    /// Gives the declaration at token `to` every attribute binding the
    /// declaration at token `from` has: §2.9 Example 5 puts a prefix on every
    /// name of its list. A binding already copied is not added again. Cost:
    /// the bindings appended since the cursor reached `from` (and `to`), not
    /// the file's.
    pub fn copyAttributes(self: *Parser, from: u32, to: u32) error{OutOfMemory}!void {
        if (from == to) return;
        const count = self.file.attributes.items.len;
        for (self.bindingsFrom(from)..count) |i| {
            const a = self.file.attributes.items[i];
            if (a.owner.kind != .declaration or a.owner.tok != from) continue;
            const exists = for (self.file.attributes.items[self.bindingsFrom(to)..]) |b| {
                if (b.owner.kind == .declaration and b.owner.tok == to and b.specs.ptr == a.specs.ptr) break true;
            } else false;
            if (!exists) try self.appendBinding(.{ .owner = .{ .kind = .declaration, .tok = to }, .specs = a.specs });
        }
    }

    /// Rebinds the declaration-owned attributes at token `tok` to the
    /// statement that starts there. `skipAttributes` binds a prefix to a
    /// declaration, and lookahead may have read a statement's prefix before
    /// knowing it was one. Cost: the bindings appended since the cursor
    /// reached `tok`.
    pub fn statementAttributes(self: *Parser, tok: u32) void {
        for (self.file.attributes.items[self.bindingsFrom(tok)..]) |*a| if (a.owner.kind == .declaration and a.owner.tok == tok) {
            a.owner.kind = .statement;
        };
    }

    /// Where a speculative `skipAttributes` started: the cursor and the
    /// lengths of `attrs` and `file.attributes`. Both tables only grow while
    /// it is held, so the lengths are enough to undo the read.
    /// Both lengths are bounded by the token count, which is a `u32`.
    const AttrMark = struct { pos: u32, specs: u32, bindings: u32 };
    comptime {
        std.debug.assert(@sizeOf(AttrMark) == 12);
    }

    /// Returns the mark `rewindAttributes` undoes a speculative read back to.
    pub fn markAttributes(self: *const Parser) AttrMark {
        return .{ .pos = self.pos, .specs = @intCast(self.attrs.items.len), .bindings = @intCast(self.file.attributes.items.len) };
    }

    /// Hands attribute instances read since `m` back to the token stream: the
    /// cursor returns to `m` and their specs and bindings are dropped, so
    /// whatever the instance prefixes collects it again. Asserts the cursor
    /// has not moved back past `m`.
    pub fn rewindAttributes(self: *Parser, m: AttrMark) void {
        std.debug.assert(m.pos <= self.pos);
        self.pos = m.pos;
        self.attrs.shrinkRetainingCapacity(m.specs);
        self.file.attributes.shrinkRetainingCapacity(m.bindings);
        self.attr_at.shrinkRetainingCapacity(m.bindings);
    }

    /// The last spec of each VerA attribute in `self.attrs[mark..]` (§2.9:
    /// "the last attribute value shall be used"), in `lte_kinds` order.
    pub fn lteSince(self: *const Parser, mark: usize) [lte_kinds.len]?Ast.NatureAttr {
        var out: [lte_kinds.len]?Ast.NatureAttr = @splat(null);
        for (self.attrs.items[mark..]) |a| for (&out, lte_kinds) |*o, k| {
            if (std.mem.eql(u8, self.file.str(a.name), @tagName(k))) o.* = a;
        };
        return out;
    }

    /// Records `lteSince`'s finds against statement `stmt` or call `expr`.
    pub fn keepLte(self: *Parser, specs: [lte_kinds.len]?Ast.NatureAttr, stmt: Ast.StmtId, expr: Ast.ExprId) error{OutOfMemory}!void {
        for (specs, lte_kinds) |f, k| if (f) |a| try self.file.lte_attrs.append(
            self.arena,
            .{ .kind = k, .stmt = stmt, .expr = expr, .value = a.value, .main_tok = a.main_tok },
        );
    }
    const lte_kinds = std.enums.values(@FieldType(Ast.LteAttr, "kind"));

    fn parseAttributes(self: *Parser) Error!void {
        while (self.peek() == .attr_open) {
            // §2.9: "Nesting of attribute instances is disallowed." An attribute
            // value is a full `parseExpr`, and A.8.3 gives an operator its own
            // `{ attribute_instance }` slot, so without this check
            // `(* outer = (1 + (* inner *) 2) *)` would parse cleanly.
            if (self.attr_depth != 0) {
                var d = self.failWith(self.pos, .E0357);
                d.msg("the value contains an attribute instance", .{});
                d.note("§2.9: \"Nesting of attribute instances is disallowed\"", .{});
                try d.emit();
                return error.ParseError;
            }
            self.pos += 1;
            self.attr_depth += 1;
            defer self.attr_depth -= 1;
            while (true) {
                const tok = self.pos;
                // `attr_name ::= identifier` (A.9.1), but §2.9.2's own `units`
                // is an annex B keyword (`kw_units`) it prints unescaped. No
                // clause grants any other keyword that exception (VD-024).
                if (!self.identLike(tok) and self.peek() != .kw_units) {
                    if (!token.isKeyword(self.peek()))
                        return self.failAt(tok, .E0208, "found {s}", .{self.found(tok)});
                    var d = self.failWith(tok, .E0208);
                    d.msg("found keyword `{s}`: an attribute name is an identifier", .{self.tokenText(tok)});
                    d.note("§2.9 / A.9.1: `attr_name ::= identifier`; only §2.9.2's `units` is exempt", .{});
                    d.help("escape it: `\\{s} `", .{self.tokenText(tok)});
                    try d.emit();
                    return error.ParseError;
                }
                const name = try self.internTok(tok);
                self.pos += 1;
                // §2.9: "If the value is not specified, then ... the default
                // value is 1." `.none` stands for that default.
                const value: Ast.ExprId = if (self.eat(.assign_eq))
                    try parse_expr.parseExpr(self)
                else
                    .none;
                try self.attrs.append(self.arena, .{ .name = name, .value = value, .main_tok = tok });
                if (!self.eat(.comma)) break;
            }
            _ = try self.expect(.attr_close);
        }
    }

    /// Resynchronize after a bad statement or module item: past the next `;`,
    /// or up to a keyword that closes the enclosing construct. Always moves
    /// past `before`. Asserts that a failure which consumed nothing did not
    /// fail on `.eof`: every caller loops only while the item it parses is
    /// not at the end, and stepping past `.eof` would leave the stream.
    pub inline fn recoverStatement(self: *Parser, before: u32) void {
        if (self.pos == before) std.debug.assert(self.peek() != .eof);
        if (self.pos == before) self.pos += 1;
        while (true) : (self.pos += 1) switch (self.peek()) {
            .eof,
            .kw_end,
            .kw_endmodule,
            .kw_endfunction,
            .kw_endgenerate,
            .kw_endcase,
            .kw_endnature,
            .kw_enddiscipline,
            .kw_analog,
            => return,
            .semicolon => {
                self.pos += 1;
                return;
            },
            else => {}, // else: any other token is inside the statement being skipped
        };
    }

    // -----------------------------------------------------------------------
    // Diagnostics
    // -----------------------------------------------------------------------

    /// `failAt` for a site that reports and carries on: the file is refused
    /// (`failed`) and parsing continues. Only OOM propagates.
    pub fn report(self: *Parser, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        switch (self.failAt(tok, code, fmt, args)) {
            error.ParseError => {},
            error.OutOfMemory => |e| return e,
        }
    }

    /// Counts one level of AST nesting toward `deepest`; the caller restores
    /// `depth`. A recursive grammar function calls `enter` instead.
    pub fn nest(self: *Parser) void {
        self.depth += 1;
        self.deepest = @max(self.deepest, self.depth);
    }

    /// Opens one level of recursion: `nest` plus a native frame. The caller
    /// pairs it with `defer self.leave()`, and first asks `segmentDue`.
    pub fn enter(self: *Parser) void {
        self.nest();
        self.seg.frames += 1;
    }

    /// Closes the level `enter` opened.
    pub fn leave(self: *Parser) void {
        self.depth -= 1;
        self.seg.frames -= 1;
    }

    /// Whether the current stack segment is full (`caller_levels` frames on
    /// the caller's stack, `segment_levels` on a segment), so the next
    /// recursion must run through `segment`.
    pub fn segmentDue(self: *const Parser) bool {
        return self.seg.due(caller_levels, segment_levels);
    }

    /// Calls the grammar function `f(args)` as one more native level: on a
    /// fresh segment when this one is full. For a recursion that reaches no
    /// `enter` site (the right-associative `?:` arm, a nested generate
    /// region).
    pub fn descend(self: *Parser, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        if (self.segmentDue()) return self.segment(f, args);
        self.seg.frames += 1;
        defer self.seg.frames -= 1;
        return @call(.auto, f, args);
    }

    /// Runs the parse-time AST walk `f(args)`, which recurses once per level
    /// of a subtree this parse built, on a `deep_stack` reserved for
    /// `deepest` (in place while that is shallow). E0241 at `tok` when that
    /// stack cannot be reserved.
    pub fn walk(self: *Parser, tok: u32, comptime f: anytype, args: anytype) Error!@typeInfo(@TypeOf(f)).@"fn".return_type.? {
        return deep_stack.run(self.deepest, f, args) catch
            self.failAt(tok, .E0241, "{d} levels deep", .{self.deepest});
    }

    /// Runs the grammar function `f(args)` on a fresh stack segment of
    /// `segment_levels` levels (`deep_stack.run`). A segment that cannot be
    /// reserved is E0241, naming the depth reached.
    pub fn segment(self: *Parser, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        return self.seg.segment(segment_levels, f, args) catch |e| switch (e) {
            error.DeepStackUnavailable => self.failAt(self.pos, .E0241, "{d} levels deep", .{self.depth}),
            else => |other| other,
        };
    }

    /// Marks the parse failed, adds `code` at token `tok` to the bag, and returns
    /// `error.ParseError` for the caller to propagate (`error.OutOfMemory` if the
    /// bag cannot grow). An unterminated string at `tok` is reported as E0138
    /// instead of `code`.
    pub fn failAt(self: *Parser, tok: u32, code: diag.Code, comptime fmt: []const u8, args: anytype) Error {
        self.failed = true;
        const span = lexer.tokenSpan(self.src, self.starts, tok);
        if (tok < self.tags.len and self.tags[tok] == .invalid) {
            if (try self.failRunawayString(span)) return error.ParseError;
        }
        try self.bag.add(.parse, code, span, fmt, args);
        return error.ParseError;
    }

    /// Reports E0138 when the `.invalid` token at `span` is a §2.7 string that
    /// runs off its line, which would otherwise read only "found invalid token".
    /// Checked here in the funnel because the token is reachable from both
    /// statement and module-item position. Returns whether it emitted.
    fn failRunawayString(self: *Parser, span: diag.Span) Error!bool {
        const kind = lexer.stringRunaway(self.src, span);
        if (kind == .none) return false;

        var d = self.bag.build(.parse, .E0138, span);
        d.point("this literal is still open at the end of the line", .{});
        if (kind == .line_continuation) {
            d.note(
                "the trailing `\\` is an IEEE 1800 SystemVerilog continuation (§5.9); " ++
                    "Verilog-AMS derives from IEEE 1364-2005, which has no such escape",
                .{},
            );
        }
        d.help("keep the literal on one line — `\\n` inside it is what breaks the output", .{});
        try d.emit();
        return true;
    }

    /// `failAt`'s diagnostic, opened for labels, notes and suggestions. Marks
    /// the parse failed; the caller must `emit` and then return
    /// `error.ParseError` itself.
    pub fn failWith(self: *Parser, tok: u32, code: diag.Code) diag.Builder {
        self.failed = true;
        return self.bag.build(.parse, code, lexer.tokenSpan(self.src, self.starts, tok));
    }

    /// Human name of the token at `i`, for the "found ..." half of a message.
    pub fn found(self: *const Parser, i: u32) []const u8 {
        return switch (self.tags[i]) {
            .identifier,
            .escaped_identifier,
            .system_identifier,
            .int_literal,
            .real_literal,
            .string_literal,
            .kw_reserved,
            => self.tokenText(i),
            else => |t| tagDesc(t), // else: every other tag implies its own text
        };
    }
};

/// Name of an expected token in a diagnostic. Punctuation is spelled as the
/// character to type, in backticks (from `token.Tag.quoted`); categories with
/// no fixed spelling stay prose.
fn tagDesc(t: token.Tag) []const u8 {
    return switch (t) {
        .eof => "end of file",
        .invalid => "invalid token",
        .identifier, .escaped_identifier => "an identifier",
        .system_identifier => "a system task or function name",
        .int_literal => "an integer literal",
        .real_literal => "a real literal",
        .string_literal => "a string literal",
        .kw_reserved => "a reserved keyword",
        else => token.Tag.quoted(t) orelse @tagName(t), // else: every other tag implies its own text
    };
}

/// Tokens that close something: when one is missing, the place to type it is
/// the end of the construct before it. Drives the insertion fix in `expect`.
fn isTerminator(t: token.Tag) bool {
    return switch (t) {
        .semicolon, .comma, .rparen, .rbracket, .rbrace => true,
        else => false, // else: not a list or statement terminator
    };
}

/// A parsed file and the bag holding its diagnostics (`parseForTest`).
pub const TestResult = struct {
    file: Ast.SourceFile,
    bag: *diag.Bag,

    pub fn count(self: TestResult) usize {
        return self.bag.count();
    }

    pub fn code(self: TestResult, i: usize) diag.Code {
        return self.bag.at(i).code;
    }

    pub fn msg(self: TestResult, i: usize) []const u8 {
        return self.bag.at(i).message;
    }
};

/// Returns a diagnostic bag for `src` as the single file `test.va`,
/// allocated in `arena`. For tests.
pub fn newBag(arena: std.mem.Allocator, src: []const u8) !*diag.Bag {
    const bag = try arena.create(diag.Bag);
    bag.* = diag.Bag.init(arena);
    try bag.setSingleFile("test.va", src);
    return bag;
}

/// Lexes and parses `src` as an analog source. A `ParseError` still returns
/// the partial file, so a test can inspect both it and the diagnostics.
/// For tests (`tests/unit.zig`, `constfold.zig`'s).
pub fn parseForTest(arena: std.mem.Allocator, src: []const u8) !TestResult {
    var list = try lexer.Lexer.tokenize(arena, src);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);
    const file = p.parseSourceFile() catch |e| switch (e) {
        error.ParseError => p.file,
        else => return e,
    };
    return .{ .file = file, .bag = bag };
}

test {
    _ = Parser.parse_source;
    _ = Parser.parse_module;
    _ = Parser.parse_discipline;
    _ = Parser.parse_paramset;
    _ = Parser.parse_connectrules;
    _ = Parser.parse_udp;
    _ = Parser.parse_decl;
    _ = Parser.parse_net;
    _ = Parser.parse_hier;
    _ = Parser.parse_function;
    _ = Parser.parse_inst;
    _ = Parser.parse_generate;
    _ = Parser.parse_specify;
    _ = Parser.parse_stmt;
    _ = Parser.parse_expr;
    _ = Parser.parse_concat;
    _ = Parser.parse_literal;
}
