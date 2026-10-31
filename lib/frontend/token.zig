//! Token kinds (LRM §2.5-§2.8, annex B): a tag's spelling in, and the facts
//! the parser asks of a tag out: its spelling (`Tag.lexeme`), whether it is a
//! keyword (`isKeyword`) and which annex A.8.2/A.6.5 call group it names
//! (`callGroup`). The stored token row is `Stored`, `{tag, start}`; its end is
//! recomputed by re-lexing from `start` (lexer.zig).
//! Cites: LRM §2.5, §2.8, §2.8.2, §4.3.2, §4.3.3, §4.5, §4.6, §5.10.3, §10.6,
//! annex A.6.5, A.8.2, annex B; IEEE 1364-2005 §19.
//!
//! `Tag` is ordered `invalid, eof, literals, symbols, directives, keywords`,
//! keywords contiguous and last, so `isKeyword` is one compare. Every keyword
//! tag is `kw_` ++ its source spelling, and keyword.zig derives the keyword
//! table from the enum, so adding the tag makes the keyword live.
//!
//! Contents:
//! - `pub const Tag = enum(u8)`, `Tag.first_keyword: Tag`, `Tag.lexeme(tag: Tag) ?[]const u8`, `Tag.quoted(tag: Tag) ?[]const u8`
//! - `pub const Stored = struct`
//! - `pub const CallGroup = enum(u8)`
//! - `pub fn isKeyword(tag: Tag) bool`
//! - `pub fn callGroup(tag: Tag) CallGroup`

const std = @import("std");
const assert = std.debug.assert;

/// Keywords VerA parses get their own tag. The other annex B keywords (specify,
/// config, switch primitives, the annex C.16 list) all lex to `kw_reserved`: never
/// an identifier, and dispatched by spelling where the parser accepts them.
pub const Tag = enum(u8) {
    invalid,
    eof,

    // ---- literals and identifiers: §2.6, §2.7, §2.8 ------------------------
    identifier, // §2.8
    escaped_identifier, // §2.8.1  (\literally.anything<ws>)
    system_identifier, // §2.8.3  ($name)
    int_literal, // §2.6.1  (incl. sized/based: 4'b1101, 'h1f)
    real_literal, // §2.6.2  (incl. exponent and SI scale suffix)
    string_literal, // §2.7

    // ---- operators: §2.5, table 4-1 -----------------------------------------
    // arithmetic §4.2.4
    plus,
    minus,
    star,
    slash,
    percent,
    star_star, // '**'  power §4.2.4
    // contribution §5.6 / assignment §5.5
    contribute, // '<+'
    arrow, // '->'  §5.10.4 event_trigger (A.6.5)
    assign_eq, // '='
    // relational §4.2.5
    lt,
    gt,
    lt_eq,
    gt_eq,
    // equality §4.2.7 / case equality §4.2.6 (lexed, rejected in Verilog-A per C.5)
    eq_eq,
    bang_eq,
    eq_eq_eq, // '==='
    bang_eq_eq, // '!=='
    // logical §4.2.8
    bang,
    amp_amp,
    pipe_pipe,
    // bitwise §4.2.9 / reduction §4.2.10 (same lexemes; distinguished by parse position)
    tilde,
    amp,
    pipe,
    caret,
    tilde_caret, // '~^'  xnor
    caret_tilde, // '^~'  xnor
    tilde_amp, // '~&'  reduction nand
    tilde_pipe, // '~|'  reduction nor
    // shifts §4.2.11
    lt_lt,
    gt_gt,
    lt_lt_lt, // '<<<' arithmetic shift (not legal in an analog block)
    gt_gt_gt, // '>>>'
    // conditional §4.2.12
    question,
    colon,

    // ---- punctuation -------------------------------------------------------
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace, // §4.2.13 concatenation / §5.x block delimiters are begin/end
    rbrace,
    semicolon,
    comma,
    dot, // hierarchical names §6.x, named port/param association
    at, // event control §5.10
    hash, // parameter override / delay §6.x
    apostrophe_lbrace, // "'{"  assignment pattern §4.2.14
    attr_open, // '(*'  attribute instance §2.9
    attr_close, // '*)'  §2.9

    // ---- directives the preprocessor passes to the parser ------------------
    // The §10.6 pair selects the reserved-keyword set for the design elements
    // that follow and must sit outside a design element, which only the parser
    // can check. See `KeywordSet`.
    dir_begin_keywords, // '`begin_keywords'
    dir_end_keywords, // '`end_keywords'
    /// IEEE 1364 §19.6 `resetall, passed through so the parser can refuse one
    /// "within a module or UDP declaration".
    dir_resetall, // '`resetall'
    /// IEEE 1364 §19.2 `default_nettype, §19.9 `unconnected_drive and
    /// `nounconnected_drive, and LRM §10.3 `default_transition: applied by the
    /// preprocessor and passed through (word alone) so the parser can refuse
    /// one inside a module.
    dir_outside_module,

    // ---- keywords: §2.8.2, annex B -------------------------------------------
    // Everything from here to the end of the enum is a keyword (`isKeyword`
    // depends on it), and each name is "kw_" ++ its source spelling.

    // module & source-text structure §6.2, §6.4, annex A.1
    kw_module,
    kw_macromodule,
    // A.1.2 `module_keyword ::= module | macromodule | connectmodule`. §7.6
    // gives a connect module the module_declaration production, so it ends
    // with `endmodule`; annex B has no `endconnectmodule`.
    kw_connectmodule,
    kw_endmodule,
    kw_paramset,
    kw_endparamset,
    kw_function,
    kw_endfunction,
    kw_analog, // §5.2
    kw_initial, // 'analog initial' §5.2, and A.6.2 initial_construct
    // A.6.2 `always_construct ::= always statement`.
    kw_always,
    // A.6.1 `continuous_assign ::= assign [ drive_strength ] [ delay3 ]
    // list_of_net_assignments ;`, the structural driver of a net (§6.1). Tagged
    // because the digital executor runs it; outside a digital run
    // `parseModuleItem` refuses it (E0205), and A.6.4 has no analog procedural form.
    kw_assign,
    kw_begin,
    kw_end,
    // A.6.5 `wait_statement ::= wait ( expression ) statement_or_null`. Tagged
    // because the digital executor runs it; A.6.4 has no analog statement
    // production for it, so `parseStmt` refuses it in an analog block.
    kw_wait,
    kw_generate, // §6.9
    kw_endgenerate,
    kw_defparam, // §6.3.1 parameter_override (A.1.4)

    // connect specifications §7.7, annex A.1.8: the `connectrules` design element
    // and the keywords of its two item forms. None is on an IEEE 1364 list, so
    // `isReserved` puts all six in `.vams_2_3`. A.1.8's `exclude` shares
    // `kw_exclude` with the §3.4.2 value ranges.
    kw_connectrules,
    kw_endconnectrules,
    kw_connect,
    kw_resolveto,
    kw_merged, // §7.7.4 connect_mode
    kw_split,

    // declarations §3.x
    kw_parameter, // §3.4
    kw_localparam, // §3.4.4
    kw_aliasparam, // §3.4.5
    kw_integer, // §3.3
    kw_real,
    kw_string, // §3.3.3
    kw_realtime,
    kw_time,
    kw_reg,
    kw_event, // §3.3 named event (declared; analog events are @-driven)
    kw_genvar, // §3.11
    kw_branch, // §3.10 branch declaration

    // ports & net types §3.5, §6.5, annex A.2.1.3
    kw_input,
    kw_output,
    kw_inout,
    kw_wire,
    kw_tri,
    kw_tri0,
    kw_tri1,
    kw_triand,
    kw_trior,
    kw_trireg,
    kw_wand,
    kw_wor,
    kw_uwire,
    kw_supply0,
    kw_supply1,
    kw_signed,
    kw_unsigned,
    kw_scalared,
    kw_vectored,

    // A.4.1 `pass_switchtype ::= tran | rtran`, the unconditional bidirectional
    // switch.
    kw_tran,
    kw_rtran,

    // A.3.4 `n_input_gatetype ::= and | nand | or | nor | xor | xnor`,
    // `n_output_gatetype ::= buf | not`, `enable_gatetype ::= bufif0 | bufif1 |
    // notif0 | notif1`. The digital executor computes these from §7.8.5's
    // tables. `or` is `kw_or`, shared with the §5.10.1 event `or`.
    //
    // A.3.1's `pullup`/`pulldown` and A.3.4's other `*_switchtype` spellings
    // stay `.kw_reserved` and are dispatched by spelling (`Parser.reservedIs`,
    // `switch_arms` in parser/inst.zig): no AST node has a slot a tag could
    // select.
    kw_and,
    kw_nand,
    kw_nor,
    kw_xor,
    kw_xnor,
    kw_buf,
    kw_not,
    kw_bufif0,
    kw_bufif1,
    kw_notif0,
    kw_notif1,

    // disciplines & natures §3.6, §3.9, annex D
    kw_discipline,
    kw_enddiscipline,
    kw_nature,
    kw_endnature,
    kw_domain, // §3.6.2.2
    kw_continuous, // §3.6.2.2
    kw_discrete, // §3.6.2.2; an error in Verilog-A (annex C.4), still lexed
    kw_potential, // §3.6.2.1
    kw_flow,
    kw_abstol, // §3.9.1
    kw_access,
    kw_units,
    kw_ddt_nature,
    kw_idt_nature,
    kw_ground, // §3.10.2

    // parameter value ranges §3.4.2
    kw_from,
    kw_exclude,
    kw_inf,

    // control flow §5.7, §5.8
    kw_if,
    kw_else,
    kw_case,
    kw_casex, // not supported in Verilog-A (annex C.7); lexed, then rejected
    kw_casez, // ditto
    kw_endcase,
    kw_default,
    kw_for,
    kw_while,
    kw_repeat,
    kw_forever,
    kw_return, // §5.9 analog function return
    kw_break,
    kw_continue,
    kw_disable,

    // event expressions §5.10
    kw_or, // '@(a or b)' event or; also the digital gate type
    kw_initial_step,
    kw_final_step,
    kw_cross, // §5.10.3
    kw_above, // §5.10.4
    kw_timer, // §5.10.5
    kw_absdelta, // §5.10.6
    // A.6.5 `event_expression ::= … | driver_update expression`: a digital
    // event, so not in `isEventFunction`. §9.22.4 defines it and §9.22
    // confines the family to a connect module.
    kw_driver_update,
    // §5.10.1 digital edges, legal only inside an `event_expression`, so not
    // `isEventFunction` members.
    kw_posedge,
    kw_negedge,

    // analog operators and filters §4.5
    kw_ddt,
    kw_ddx, // §4.5.9
    kw_idt,
    kw_idtmod,
    kw_absdelay, // §4.5.2
    kw_transition, // §4.5.3
    kw_slew, // §4.5.4
    kw_last_crossing, // §4.5.5
    kw_laplace_zd, // §4.5.6
    kw_laplace_zp,
    kw_laplace_nd,
    kw_laplace_np,
    kw_zi_zd, // §4.5.7
    kw_zi_zp,
    kw_zi_nd,
    kw_zi_np,
    // small-signal / noise sources §4.6
    kw_analysis,
    kw_ac_stim,
    kw_white_noise,
    kw_flicker_noise,
    kw_noise_table,
    kw_noise_table_log,

    // math functions §4.3.2 (with domain tables) / §4.3.3 transcendental
    kw_abs,
    kw_max,
    kw_min,
    kw_pow,
    kw_sqrt,
    kw_exp,
    kw_limexp, // §4.5.13 bounded-derivative exp; a filter per A.8.2, not a math builtin
    kw_ln,
    kw_log,
    kw_expm1,
    kw_ln1p,
    kw_hypot,
    kw_floor,
    kw_ceil,
    kw_sin,
    kw_cos,
    kw_tan,
    kw_asin,
    kw_acos,
    kw_atan,
    kw_atan2,
    kw_sinh,
    kw_cosh,
    kw_tanh,
    kw_asinh,
    kw_acosh,
    kw_atanh,

    /// Any annex B keyword without its own tag (see `reserved_keywords`). Never
    /// an identifier. The spelling is not recoverable from the tag; slice the
    /// source at `start`.
    kw_reserved,

    /// First keyword tag; `isKeyword` compares against it.
    pub const first_keyword: Tag = .kw_module;

    /// Returns the source spelling, for diagnostics. `null` when the tag does
    /// not imply the text (identifiers, literals, `kw_reserved`): slice the
    /// source then. `.dir_outside_module` stands for four directives and
    /// returns a description instead of one spelling.
    pub fn lexeme(tag: Tag) ?[]const u8 {
        return switch (tag) {
            .invalid, .eof, .kw_reserved => null,
            .identifier,
            .escaped_identifier,
            .system_identifier,
            .int_literal,
            .real_literal,
            .string_literal,
            => null,

            .plus => "+",
            .minus => "-",
            .star => "*",
            .slash => "/",
            .percent => "%",
            .star_star => "**",
            .contribute => "<+",
            .arrow => "->",
            .assign_eq => "=",
            .lt => "<",
            .gt => ">",
            .lt_eq => "<=",
            .gt_eq => ">=",
            .eq_eq => "==",
            .bang_eq => "!=",
            .eq_eq_eq => "===",
            .bang_eq_eq => "!==",
            .bang => "!",
            .amp_amp => "&&",
            .pipe_pipe => "||",
            .tilde => "~",
            .amp => "&",
            .pipe => "|",
            .caret => "^",
            .tilde_caret => "~^",
            .caret_tilde => "^~",
            .tilde_amp => "~&",
            .tilde_pipe => "~|",
            .lt_lt => "<<",
            .gt_gt => ">>",
            .lt_lt_lt => "<<<",
            .gt_gt_gt => ">>>",
            .question => "?",
            .colon => ":",
            .lparen => "(",
            .rparen => ")",
            .lbracket => "[",
            .rbracket => "]",
            .lbrace => "{",
            .rbrace => "}",
            .semicolon => ";",
            .comma => ",",
            .dot => ".",
            .at => "@",
            .hash => "#",
            .apostrophe_lbrace => "'{",
            .attr_open => "(*",
            .attr_close => "*)",
            .dir_begin_keywords => "`begin_keywords",
            .dir_end_keywords => "`end_keywords",
            .dir_resetall => "`resetall",
            .dir_outside_module => "a directive used only outside a module",

            // Every keyword tag is "kw_" ++ its spelling (naming invariant).
            inline else => |t| comptime if (isKeyword(t)) @tagName(t)[3..] else @compileError("give `." ++ @tagName(t) ++ "` its spelling above"), // else: the keywords; any other tag fails to compile
        };
    }

    /// Returns `lexeme` in backticks, for a diagnostic that names what the user
    /// must type. Comptime-derived from `lexeme`, so the two cannot drift.
    pub fn quoted(tag: Tag) ?[]const u8 {
        return switch (tag) {
            inline else => |t| comptime blk: {
                const l = lexeme(t) orelse break :blk null;
                break :blk "`" ++ l ++ "`";
            },
        };
    }
};

/// One token as stored: a tag byte and a start offset, kept SoA
/// (`lexer.TokenList`), so a row is 5 bytes. Anything else is recomputed from
/// `start`, so do not add fields.
pub const Stored = struct {
    tag: Tag,
    start: u32,

    comptime {
        assert(@sizeOf(Tag) == 1);
        assert(@typeInfo(Stored).@"struct".field_names.len == 2);
    }
};

/// The annex A.8.2 / A.6.5 call production a keyword names, one per tag, so
/// the groups are disjoint by construction. The parser maps each to its
/// `Ast.ExprTag`: `math` to `builtin_call`, `filter` to `filter_call`,
/// `small_signal` to `noise_call`, `event` to `event_function`.
pub const CallGroup = enum(u8) {
    /// Not a call keyword, or one with its own production.
    none,
    /// A.8.2 `analog_built_in_function_name` (§4.3.2, §4.3.3).
    math,
    /// A.8.2 `analog_filter_function_call` (§4.5), `limexp` included: each
    /// occurrence owns runtime state (§4.5.1).
    filter,
    /// A.8.2 `analog_small_signal_function_call` (§4.6) other than
    /// `analysis`, which the parser folds into `sys_call`.
    small_signal,
    /// A.6.5 `analog_event_functions` (§5.10.3), legal only inside `@( )`.
    /// `initial_step`/`final_step` are not: A.6.5 gives them their own
    /// alternatives.
    event,
};

/// The call group of every tag; a tag not listed is `.none`.
const call_groups = std.enums.EnumArray(Tag, CallGroup).initDefault(.none, .{
    // A.8.2 analog_built_in_function_name: 26 names.
    .kw_abs = .math,
    .kw_max = .math,
    .kw_min = .math,
    .kw_pow = .math,
    .kw_sqrt = .math,
    .kw_exp = .math,
    .kw_ln = .math,
    .kw_log = .math,
    .kw_expm1 = .math,
    .kw_ln1p = .math,
    .kw_hypot = .math,
    .kw_floor = .math,
    .kw_ceil = .math,
    .kw_sin = .math,
    .kw_cos = .math,
    .kw_tan = .math,
    .kw_asin = .math,
    .kw_acos = .math,
    .kw_atan = .math,
    .kw_atan2 = .math,
    .kw_sinh = .math,
    .kw_cosh = .math,
    .kw_tanh = .math,
    .kw_asinh = .math,
    .kw_acosh = .math,
    .kw_atanh = .math,
    // A.8.2 analog_filter_function_call: 17 names, §4.5.13 `limexp` among them.
    .kw_ddt = .filter,
    .kw_ddx = .filter,
    .kw_idt = .filter,
    .kw_idtmod = .filter,
    .kw_absdelay = .filter,
    .kw_transition = .filter,
    .kw_slew = .filter,
    .kw_last_crossing = .filter,
    .kw_limexp = .filter,
    .kw_laplace_zd = .filter,
    .kw_laplace_zp = .filter,
    .kw_laplace_nd = .filter,
    .kw_laplace_np = .filter,
    .kw_zi_zd = .filter,
    .kw_zi_zp = .filter,
    .kw_zi_nd = .filter,
    .kw_zi_np = .filter,
    // A.8.2 analog_small_signal_function_call less `analysis`: 5 names.
    .kw_ac_stim = .small_signal,
    .kw_white_noise = .small_signal,
    .kw_flicker_noise = .small_signal,
    .kw_noise_table = .small_signal,
    .kw_noise_table_log = .small_signal,
    // A.6.5 analog_event_functions: 4 names.
    .kw_cross = .event,
    .kw_above = .event,
    .kw_timer = .event,
    .kw_absdelta = .event,
});

/// Returns whether `tag` is a keyword (LRM §2.8.2). Escaped identifiers are
/// never keywords (§2.8.1), so the lexer does not look them up.
pub fn isKeyword(tag: Tag) bool {
    const keyword = @backingInt(tag) >= @backingInt(Tag.first_keyword);
    if (keyword) assert(tag != .eof);
    if (!keyword) assert(tag != .kw_reserved);
    return keyword;
}

/// Returns the annex A.8.2 / A.6.5 call production `tag` names, or `.none`.
pub fn callGroup(tag: Tag) CallGroup {
    const group = call_groups.get(tag);
    if (group != .none) assert(isKeyword(tag));
    return group;
}

// ---- private ----

test "layout invariant: keyword block is contiguous and last" {
    // Every kw_* tag is >= first_keyword, and nothing before it is a keyword.
    @setEvalBranchQuota(20_000);
    inline for (@typeInfo(Tag).@"enum".field_names) |f| {
        const is_kw_name = comptime std.mem.startsWith(u8, f, "kw_");
        try std.testing.expectEqual(is_kw_name, isKeyword(@field(Tag, f)));
    }
    try std.testing.expect(!isKeyword(.eof));
    try std.testing.expect(!isKeyword(.attr_close));
}

test "call groups match annex A.8.2/A.6.5 exactly and are disjoint" {
    // Oracle: the grammar's own counts. analog_built_in_function_name = 26,
    // analog_filter_function_call = 17, analog_small_signal_function_call
    // less `analysis` = 5, analog_event_functions = 4. Disjoint because each
    // tag has one group.
    var counts = std.enums.EnumArray(CallGroup, u32).initFill(0);
    for (std.enums.values(Tag)) |t| counts.getPtr(callGroup(t)).* += 1;
    try std.testing.expectEqual(26, counts.get(.math));
    try std.testing.expectEqual(17, counts.get(.filter));
    try std.testing.expectEqual(5, counts.get(.small_signal));
    try std.testing.expectEqual(4, counts.get(.event));
    // §4.5.13: limexp is a filter, never a math builtin (proof.zig must not
    // put a domain on it, codegen must give it state).
    try std.testing.expectEqual(CallGroup.filter, callGroup(.kw_limexp));
    // §5.10.2 step events are their own Ast tags, not `event_function`s.
    try std.testing.expectEqual(CallGroup.none, callGroup(.kw_initial_step));
    try std.testing.expectEqual(CallGroup.none, callGroup(.kw_final_step));
    try std.testing.expectEqual(CallGroup.none, callGroup(.kw_analysis));
}

test "Tag.quoted is lexeme in backticks, and null exactly where lexeme is" {
    for (std.enums.values(Tag)) |t| {
        if (Tag.lexeme(t)) |l| {
            const q = Tag.quoted(t).?;
            try std.testing.expectEqual(l.len + 2, q.len);
            try std.testing.expect(q[0] == '`' and q[q.len - 1] == '`');
            try std.testing.expectEqualStrings(l, q[1 .. q.len - 1]);
        } else try std.testing.expectEqual(@as(?[]const u8, null), Tag.quoted(t));
    }
    // The tags whose text is the source's, not the tag's.
    for ([_]Tag{ .invalid, .eof, .identifier, .escaped_identifier, .system_identifier, .int_literal, .real_literal, .string_literal, .kw_reserved }) |t| {
        try std.testing.expectEqual(@as(?[]const u8, null), Tag.lexeme(t));
    }
}
