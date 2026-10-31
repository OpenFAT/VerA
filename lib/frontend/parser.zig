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
//!
//! Contents:
//! - `pub const Error = error`
//! - `pub const segment_levels = 4096`
//! - `pub const caller_levels = 512`
//! - `pub const Parser = struct`: `init`, `Seed`, `initSeeded`, `setLanguage`, `refuseAms`, `refuseDigital`, `digitalItem`, `parseSourceFile`, `discreteGrammar`, `peek`, `peekAt`, `eat`, `tokenText`, `reservedIs`, `eatSymbol`, `expect`, `identLike`, `warnOwnMathFn`, `expectIdent`, `expectIdentOrSys`, `internTok`, `skipAttributes`, `attributesEnd`, `pastAttributes`, `ownedAttributes`, `copyAttributes`, `statementAttributes`, `markAttributes`, `rewindAttributes`, `lteSince`, `keepLte`, `recoverStatement`, `report`, `nest`, `enter`, `leave`, `segmentDue`, `descend`, `walk`, `segment`, `failAt`, `failWith`, `found`
//! - `pub const TestResult = struct`: `count`, `code`, `msg`
//! - `pub fn newBag(arena: std.mem.Allocator, src: []const u8) !*diag.Bag`
//! - `pub fn parseForTest(arena: std.mem.Allocator, src: []const u8) !TestResult`

const std = @import("std");
const assert = std.debug.assert;
const token = @import("token.zig");
const lexer = @import("lexer.zig");
const keyword = @import("keyword.zig");
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
    kw_set: keyword.KeywordSet = keyword.default_keyword_set,
    kw_stack: std.ArrayList(keyword.KeywordSet) = .empty,
    /// The language this parse accepts (`vera --std=`), which is also §10.6's
    /// "implementation's default set of reserved keywords". Unlike `kw_set` it
    /// changes what parses: under a 1364 set a Verilog-AMS construct is E0242,
    /// because IEEE 1364-2005 annex A has no production for it. Set it with
    /// `setLanguage`.
    language: keyword.KeywordSet = keyword.default_keyword_set,
    /// Parsing annex C's Verilog-A subset (`vera --sim=verilogA`): a digital
    /// or mixed-signal construct is E0250 (`refuseDigital`). The annex D
    /// prelude is seeded from a parse without it, so its `discrete`
    /// disciplines stay silent (C.17).
    verilog_a: bool = false,
    /// `expm1` (bit 0) and `ln1p` (bit 1) are names here, not VAMS-2023's
    /// built-ins: the file declares a function so named, as models written
    /// before annex G.7 item 7780 reserved them do (HiSIM-SOI's
    /// `analog function real expm1`). `identLike` frees them in the whole
    /// file, so its calls reach that function; the declaration warns W0259.
    own_math_fns: u2 = 0,
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
            .own_math_fns = ownMathFns(tags),
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
    pub fn setLanguage(self: *Parser, set: keyword.KeywordSet) void {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        self.language = set;
        self.kw_set = set;
    }

    /// Reports E0242 if the token at `pos` opens a Verilog-AMS design element
    /// or module item and `language` is a 1364 set. Called where a description
    /// or a module item is dispatched, which is where every AMS construct
    /// starts; below that, such a keyword can only be an identifier. The
    /// construct is then parsed anyway, so the one error is the only one.
    pub fn refuseAms(self: *Parser) error{OutOfMemory}!void {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        const t = self.peek();
        if (@backingInt(self.language) >= @backingInt(keyword.KeywordSet.vams_2_3) or !token.isKeyword(t)) return;
        const w = self.tokenText(self.pos);
        if (keyword.isReserved(w, self.language)) return;
        try self.report(self.pos, .E0242, "`{s}` under \"{s}\"", .{ w, self.language.specifier() });
    }

    /// Reports E0250 at `tok`: `what` is outside annex C's Verilog-A subset,
    /// which `vera --sim=verilogA` compiles. Like `refuseAms`, the construct
    /// is then parsed anyway, so the one error is the only one. Asserts
    /// `verilog_a`.
    pub fn refuseDigital(self: *Parser, tok: u32, what: []const u8) error{OutOfMemory}!void {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
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

    /// Parses the whole stream. Returns `error.ParseError` at the end if anything
    /// was reported; the AST is then partial and must not be lowered.
    pub const parseSourceFile = parse_source.parseSourceFile;

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
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
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
        const text = lexer.tokenText(self.src, self.starts[i]);
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
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        if (self.peek() != .invalid or !std.mem.eql(u8, self.tokenText(self.pos), w)) return false;
        self.pos += 1;
        return true;
    }

    /// Consumes a `t` token and returns its index. Otherwise reports E0207,
    /// with an insertion fix when `t` is a terminator, and returns
    /// `error.ParseError` with the cursor unmoved.
    pub fn expect(self: *Parser, t: token.Tag) Error!u32 {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
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
            .kw_expm1 => self.own_math_fns & 1 != 0 or !keyword.isReserved("expm1", self.kw_set),
            .kw_ln1p => self.own_math_fns & 2 != 0 or !keyword.isReserved("ln1p", self.kw_set),
            // Default set ⇒ every keyword is reserved: no text to fetch.
            else => |t| self.kw_set != keyword.default_keyword_set and // else: a keyword is an identifier only when the keyword set frees it
                token.isKeyword(t) and
                !keyword.isReserved(self.tokenText(j), self.kw_set),
        };
    }

    /// W0259 if the function name at the cursor is `expm1`/`ln1p` and the
    /// active §10.6 set reserves it: `own_math_fns` is what frees it.
    pub fn warnOwnMathFn(self: *Parser) error{OutOfMemory}!void {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        const t = self.peek();
        if (t != .kw_expm1 and t != .kw_ln1p) return;
        const w = self.tokenText(self.pos);
        if (!keyword.isReserved(w, self.kw_set)) return;
        try self.bag.add(.parse, .W0259, lexer.tokenSpan(self.src, self.starts, self.pos), "`{s}` is a built-in under \"{s}\"; calls in this file reach the declared function", .{ w, self.kw_set.specifier() });
    }

    /// Consumes a §2.8/§2.8.1 identifier (or a keyword `identLike` frees) and
    /// returns it interned. Reports E0208 otherwise.
    pub fn expectIdent(self: *Parser) Error!Ast.StrId {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        if (!self.identLike(self.pos))
            return self.failAt(self.pos, .E0208, "found {s}", .{self.found(self.pos)});
        const s = try self.internTok(self.pos);
        self.pos += 1;
        return s;
    }

    /// `expectIdent`, or a §9.18 system name (`$mfactor`) where the grammar
    /// admits one as a parameter identifier.
    pub fn expectIdentOrSys(self: *Parser) Error!Ast.StrId {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
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
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        // The bytes are spelled out, not imported from `ir/`: the frontend owns
        // the source half of this convention and does not depend on the IR.
        const text = self.tokenText(i);
        if (self.tags[i] != .escaped_identifier) return self.file.intern(self.arena, text);
        // IEEE 1364-2005 §3.7.3: a system task or function "shall not be
        // escaped", so `\$display` keeps its `\` and names no system task.
        if (text[0] == '$') return self.file.intern(self.arena, lexer.tokenText(self.src, self.starts[i]));
        if (std.mem.findScalar(u8, text, '.') == null)
            return self.file.intern(self.arena, text);
        const buf = try self.arena.dupe(u8, text);
        std.mem.replaceScalar(u8, buf, '.', ' ');
        return self.file.intern(self.arena, buf);
    }

    // §2.9 attribute instances and their owners (parser/attributes.zig).
    pub const skipAttributes = parse_attr.skipAttributes;
    pub const attributesEnd = parse_attr.attributesEnd;
    pub const pastAttributes = parse_attr.pastAttributes;
    pub const ownedAttributes = parse_attr.ownedAttributes;
    pub const copyAttributes = parse_attr.copyAttributes;
    pub const statementAttributes = parse_attr.statementAttributes;
    pub const markAttributes = parse_attr.markAttributes;
    pub const rewindAttributes = parse_attr.rewindAttributes;
    pub const lteSince = parse_attr.lteSince;
    pub const keepLte = parse_attr.keepLte;

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
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        switch (self.failAt(tok, code, fmt, args)) {
            error.ParseError => {},
            error.OutOfMemory => |e| return e,
        }
    }

    /// Counts one level of AST nesting toward `deepest`; the caller restores
    /// `depth`. A recursive grammar function calls `enter` instead.
    pub fn nest(self: *Parser) void {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        self.depth += 1;
        self.deepest = @max(self.deepest, self.depth);
    }

    /// Opens one level of recursion: `nest` plus a native frame. The caller
    /// pairs it with `defer self.leave()`, and first asks `segmentDue`.
    pub fn enter(self: *Parser) void {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        self.nest();
        self.seg.frames += 1;
    }

    /// Closes the level `enter` opened.
    pub fn leave(self: *Parser) void {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
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
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
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
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        return deep_stack.run(self.deepest, f, args) catch
            self.failAt(tok, .E0241, "{d} levels deep", .{self.deepest});
    }

    /// Runs the grammar function `f(args)` on a fresh stack segment of
    /// `segment_levels` levels (`deep_stack.run`). A segment that cannot be
    /// reserved is E0241, naming the depth reached.
    pub fn segment(self: *Parser, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
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
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        self.failed = true;
        const span = lexer.tokenSpan(self.src, self.starts, tok);
        if (tok < self.tags.len and self.tags[tok] == .invalid) {
            if (try self.failRunawayString(span)) return error.ParseError;
        }
        try self.bag.add(.parse, code, span, fmt, args);
        return error.ParseError;
    }

    /// `failAt`'s diagnostic, opened for labels, notes and suggestions. Marks
    /// the parse failed; the caller must `emit` and then return
    /// `error.ParseError` itself.
    pub fn failWith(self: *Parser, tok: u32, code: diag.Code) diag.Builder {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
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

    // ---- private ----

    // Annex A.1.2 source_text, A.1.1 library source text, A.1.5 configurations
    const parse_source = @import("parser/source.zig");
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
    // §2.9 attribute instances
    const parse_attr = @import("parser/attributes.zig");

    /// `own_math_fns` for `tags`: which of `expm1`/`ln1p` (bit 0/1) some
    /// `function [real|integer] NAME` declares. One pass over the tags, so a
    /// call ahead of the declaration reads the same way as one after it.
    fn ownMathFns(tags: []const token.Tag) u2 {
        var bits: u2 = 0;
        for (tags, 0..) |t, i| {
            if (t != .kw_expm1 and t != .kw_ln1p) continue;
            if (i == 0) continue;
            const before = tags[i - 1];
            const declared = before == .kw_function or
                ((before == .kw_real or before == .kw_integer) and i >= 2 and tags[i - 2] == .kw_function);
            if (declared) bits |= if (t == .kw_expm1) 1 else 2;
        }
        return bits;
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

    /// Reports E0138 when the `.invalid` token at `span` is a §2.7 string that
    /// runs off its line, which would otherwise read only "found invalid token".
    /// Checked here in the funnel because the token is reachable from both
    /// statement and module-item position. Returns whether it emitted.
    fn failRunawayString(self: *Parser, span: diag.Span) Error!bool {
        assert(self.pos < self.tags.len);
        const pos_in = self.pos;
        defer assert(self.pos >= pos_in);
        const kind = @import("token_value.zig").stringRunaway(self.src, span);
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
};

/// A parsed file and the bag holding its diagnostics (`parseForTest`).
pub const TestResult = struct {
    file: Ast.SourceFile,
    bag: *diag.Bag,

    /// Diagnostics the bag kept, warnings included: its cap and dedupe
    /// have already dropped the rest.
    pub fn count(self: TestResult) usize {
        return self.bag.count();
    }

    /// The `i`th diagnostic's code, in report order. `i` must be below `count`.
    pub fn code(self: TestResult, i: usize) diag.Code {
        return self.bag.at(i).code;
    }

    /// The `i`th diagnostic's message, the headline under its code's title.
    /// `i` must be below `count`.
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
    var list = try lexer.tokenize(arena, src, null);
    const bag = try newBag(arena, src);
    var p = Parser.init(arena, src, list.items(.tag), list.items(.start), bag);
    const file = p.parseSourceFile() catch |e| switch (e) {
        error.ParseError => p.file,
        else => return e,
    };
    return .{ .file = file, .bag = bag };
}

// ---- private ----

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
    _ = Parser.parse_attr;
}
