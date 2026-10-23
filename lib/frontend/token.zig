//! Token kinds, the keyword table and the §10.6 reserved-word sets (LRM §2.5-§2.8, §10.6, annex B).
//! In: a word's spelling. Out: its `Tag` (`lookupKeyword`), whether a §10.6 set
//! reserves it (`isReserved`), and the call group the parser files it under.
//! A stored token is `{tag, start}`; its end is recomputed by re-lexing from `start`.
//! `Tag` is ordered `invalid, eof, literals, symbols, keywords`, keywords contiguous and last,
//! so `isKeyword` is one compare. Every keyword tag is `kw_` ++ its source spelling and
//! `keyword_map` is derived from the enum, so adding the tag makes the keyword live.

const std = @import("std");

/// Every lexical token kind (LRM §2.5, §2.8.2, annex B).
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
    const first_keyword: Tag = .kw_module;

    /// Returns the source spelling, for diagnostics. `null` when the tag does not
    /// imply the text (identifiers, literals, `kw_reserved`); slice the source then.
    /// `.dir_outside_module` stands for four directives and returns a
    /// description instead of one spelling.
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

/// One token as stored: 5 bytes of payload. Anything else is recomputed from
/// `start`, so do not add fields.
pub const Stored = struct {
    tag: Tag,
    start: u32,

    // Stored SoA (`Lexer.TokenList`), so a row is these 5 bytes: one tag byte
    // and one offset.
    comptime {
        std.debug.assert(@sizeOf(Tag) == 1);
        std.debug.assert(@typeInfo(Stored).@"struct".field_names.len == 2);
    }
};

/// Every annex B keyword spelling and its tag (LRM §2.8.2), built at comptime
/// from `Tag` and `reserved_keywords`.
/// This is the reference definition. `get` scans a whole length bucket linearly,
/// so the lexer calls `lookupKeyword`, which must agree with it.
const keyword_map = std.StaticStringMap(Tag).initComptime(keyword_kvs);

/// Lane count for the bucket scan, from the target. `null` on a target with no
/// useful `u8` vector, which then uses the scalar loop only.
const kw_lanes = std.simd.suggestVectorLength(u8);

/// The first byte of each keyword, in `keyword_map.keys()` order. A few cache
/// lines, where the map's own scan walks a slice header per key.
///
/// Padded by one lane of 0, which no keyword starts with, so a full-width load
/// at any index below `keys().len` is in bounds and the extra lanes cannot
/// match. The chunk loop can then run past a bucket's end and mask it.
const kw_first: [keyword_map.keys().len + (kw_lanes orelse 1)]u8 = blk: {
    var t: [keyword_map.keys().len + (kw_lanes orelse 1)]u8 = @splat(0);
    for (keyword_map.keys(), 0..) |k, i| t[i] = k[0];
    break :blk t;
};

/// Longest keyword. `kw_len_start[L]..kw_len_start[L+1]` is the run of keys of
/// length L, which relies on `StaticStringMap` sorting its keys by length; the
/// table below fails to compile if it stops doing so.
const kw_max_len: usize = keyword_map.max_len;

const kw_len_start: [kw_max_len + 2]u16 = blk: {
    const keys = keyword_map.keys();
    for (keys[1..], keys[0 .. keys.len - 1]) |b, a| {
        if (b.len < a.len) @compileError("StaticStringMap no longer sorts keys by length");
    }
    var t: [kw_max_len + 2]u16 = undefined;
    for (keyword_map.len_indexes[0 .. kw_max_len + 1], 0..) |off, len| {
        t[len] = @intCast(off);
    }
    t[kw_max_len + 1] = keys.len;
    break :blk t;
};

/// Returns the keyword tag spelled `name`, or null (LRM §2.8.2, annex B).
/// Same answer as `keyword_map.get(name)`, found by matching first bytes within
/// the length bucket; the differential test below holds the two together.
pub fn lookupKeyword(name: []const u8) ?Tag {
    // One compare rejects the empty string and everything longer than the
    // longest keyword; `name[0]` is in bounds after it.
    if (name.len -% 1 >= kw_max_len) return null;
    const lo: usize = kw_len_start[name.len];
    const hi: usize = kw_len_start[name.len + 1];

    if (kw_lanes) |lanes| {
        const V = @Vector(lanes, u8);
        const Mask = @Int(.unsigned, lanes);
        const needle: V = @splat(name[0]);
        var i = lo;
        while (i < hi) : (i += lanes) {
            const block: V = kw_first[i..][0..lanes].*;
            var m: Mask = @bitCast(block == needle);
            // Lanes past this bucket belong to the next length and must not
            // match. The padding covers the lanes past the table itself.
            const valid = hi - i;
            if (valid < lanes) m &= (@as(Mask, 1) << @intCast(valid)) - 1;
            while (m != 0) : (m &= m - 1) {
                const k = i + @ctz(m);
                if (std.mem.eql(u8, keyword_map.keys()[k], name)) return keyword_map.values()[k];
            }
        }
        return null;
    }
    return lookupKeywordScalar(name, lo, hi);
}

/// Scalar form of `lookupKeyword`'s bucket scan: the fallback on a target with
/// no vectors, and the second reference in the differential test.
fn lookupKeywordScalar(name: []const u8, lo: usize, hi: usize) ?Tag {
    for (kw_first[lo..hi], lo..) |first, i| {
        if (first == name[0] and std.mem.eql(u8, keyword_map.keys()[i], name)) {
            return keyword_map.values()[i];
        }
    }
    return null;
}

// ---- §10.6 `begin_keywords: which words are reserved ---------------------

/// A §10.6 version_specifier: "the valid set of reserved keywords in effect
/// when a design unit is parsed". Five sets form a chain, oldest first
/// (1364-1995 ⊂ 1364-2001 ⊂ 1364-2005 ⊂ VAMS-2.3 ⊂ VAMS-2023), so a word is
/// reserved in set `s` iff `keyword_intro` dates it no later than `s`; IEEE
/// 1364-2005 §19.11's sixth, "1364-2001-noconfig", is 1364-2001 less
/// `noconfig_words`.
///
/// §10.6: the directives "do not affect the semantics, tokens, and other
/// aspects" of the language. So the lexer ignores the set (`sin` is always
/// `kw_sin`); the parser decides whether the token may stand as an identifier
/// (`Parser.identLike`). Under `begin_keywords "1364-2005", `input sin;` is
/// legal and `analog` still parses.
pub const KeywordSet = enum(u8) {
    v1364_1995,
    v1364_2001,
    /// IEEE 1364-2005 §19.11: "1364-2001" without `noconfig_words`, so it
    /// sits between its neighbours in the chain.
    v1364_2001_noconfig,
    v1364_2005,
    vams_2_3,
    vams_2023,

    /// Parses a §10.6 (IEEE 1364-2005 §19.11) version_specifier. `null` for
    /// any other string; the two standards name exactly these six, so the
    /// caller reports an unknown one.
    pub fn fromSpecifier(text: []const u8) ?KeywordSet {
        return specifier_map.get(text);
    }

    /// Returns the §10.6 version_specifier string that selects `self`, the
    /// inverse of `fromSpecifier`.
    pub fn specifier(self: KeywordSet) []const u8 {
        return switch (self) {
            .v1364_1995 => "1364-1995",
            .v1364_2001 => "1364-2001",
            .v1364_2001_noconfig => "1364-2001-noconfig",
            .v1364_2005 => "1364-2005",
            .vams_2_3 => "VAMS-2.3",
            .vams_2023 => "VAMS-2023",
        };
    }
};

/// The implementation's default set when no `begin_keywords is in effect
/// (§10.6: "the implementation's default set of reserved keywords").
pub const default_keyword_set: KeywordSet = .vams_2023;

/// The language family `vera --sim=` compiles: all of Verilog-AMS, annex C's
/// Verilog-A subset of it (`Parser.verilog_a`: a digital or mixed-signal
/// construct is E0250), or IEEE 1364-2005 Verilog alone (a `.v` design under
/// a 1364 `KeywordSet`, so a Verilog-AMS construct is E0242).
pub const Sim = enum(u8) {
    verilog_ams,
    verilog_a,
    verilog,

    /// Parses the flag's value: `verilogAMS`, `verilogA` or `verilog`.
    pub fn fromFlag(text: []const u8) ?Sim {
        return sim_map.get(text);
    }
};

const sim_map = std.StaticStringMap(Sim).initComptime(.{
    .{ "verilogAMS", Sim.verilog_ams },
    .{ "verilogA", Sim.verilog_a },
    .{ "verilog", Sim.verilog },
});

const specifier_map = std.StaticStringMap(KeywordSet).initComptime(.{
    .{ "1364-1995", KeywordSet.v1364_1995 },
    .{ "1364-2001", KeywordSet.v1364_2001 },
    .{ "1364-2001-noconfig", KeywordSet.v1364_2001_noconfig },
    .{ "1364-2005", KeywordSet.v1364_2005 },
    .{ "VAMS-2.3", KeywordSet.vams_2_3 },
    .{ "VAMS-2023", KeywordSet.vams_2023 },
});

/// Returns whether the keyword spelled `name` is reserved under `set` (LRM §10.6,
/// annex B). Only meaningful for a spelling in `keyword_map`.
pub fn isReserved(name: []const u8, set: KeywordSet) bool {
    if (set == .v1364_2001_noconfig and noconfig_words.has(name)) return false;
    return @backingInt(keyword_intro.get(name) orelse .vams_2_3) <= @backingInt(set);
}

// ---- predicates the lexer/parser want ------------------------------------

/// Returns whether `tag` is a keyword (LRM §2.8.2). Escaped identifiers are
/// never keywords (§2.8.1), so the lexer does not look them up.
pub fn isKeyword(tag: Tag) bool {
    return @backingInt(tag) >= @backingInt(Tag.first_keyword);
}

/// Returns whether `tag` is an annex A.8.2 `analog_built_in_function_name`
/// (LRM §4.3.2, §4.3.3), which the parser turns into `Ast.ExprTag.builtin_call`.
/// `limexp` is not one: A.8.2 lists it as a filter (§4.5.13).
pub fn isMathFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_abs,
        .kw_max,
        .kw_min,
        .kw_pow,
        .kw_sqrt,
        .kw_exp,
        .kw_ln,
        .kw_log,
        .kw_expm1,
        .kw_ln1p,
        .kw_hypot,
        .kw_floor,
        .kw_ceil,
        .kw_sin,
        .kw_cos,
        .kw_tan,
        .kw_asin,
        .kw_acos,
        .kw_atan,
        .kw_atan2,
        .kw_sinh,
        .kw_cosh,
        .kw_tanh,
        .kw_asinh,
        .kw_acosh,
        .kw_atanh,
        => true,
        else => false, // else: not an A.8.2 math function keyword
    };
}

/// Returns whether `tag` is an annex A.8.2 `analog_filter_function_call`
/// (LRM §4.5, `limexp` included), which the parser turns into
/// `Ast.ExprTag.filter_call`. Each occurrence owns runtime state (§4.5.1).
pub fn isFilterFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_ddt,
        .kw_ddx,
        .kw_idt,
        .kw_idtmod,
        .kw_absdelay,
        .kw_transition,
        .kw_slew,
        .kw_last_crossing,
        .kw_limexp, // §4.5.13: A.8.2 lists it here, not with the math builtins
        .kw_laplace_zd,
        .kw_laplace_zp,
        .kw_laplace_nd,
        .kw_laplace_np,
        .kw_zi_zd,
        .kw_zi_zp,
        .kw_zi_nd,
        .kw_zi_np,
        => true,
        else => false, // else: not an A.8.2 analog filter function keyword
    };
}

/// Returns whether `tag` is an annex A.8.2 `analog_small_signal_function_call`
/// (LRM §4.6) other than `analysis`; these become `Ast.ExprTag.noise_call`.
/// The parser folds `analysis` into `Ast.ExprTag.sys_call`.
pub fn isSmallSignalFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_ac_stim,
        .kw_white_noise,
        .kw_flicker_noise,
        .kw_noise_table,
        .kw_noise_table_log,
        => true,
        else => false, // else: not an A.8.2 small-signal function keyword
    };
}

/// Returns whether `tag` is an annex A.6.5 `analog_event_functions` name
/// (LRM §5.10.3), legal only inside `@( ... )`; these become
/// `Ast.ExprTag.event_function`. `initial_step`/`final_step` are not: A.6.5
/// gives them their own alternatives and the AST its own tags.
pub fn isEventFunction(tag: Tag) bool {
    return switch (tag) {
        .kw_cross,
        .kw_above,
        .kw_timer,
        .kw_absdelta,
        => true,
        else => false, // else: not an A.6.5 event function keyword
    };
}

// ---- keyword table construction ------------------------------------------

const KV = struct { []const u8, Tag };

/// Annex B keywords without their own tag: IEEE 1364 primitives, specify and
/// table, config-file keywords, and the annex C.16 "not used by Verilog-A" list.
/// All lex to `.kw_reserved`; being in the map keeps them out of identifiers.
/// A spelling here must not also have a `kw_` tag (checked in `keyword_kvs`).
const reserved_keywords = [_][]const u8{
    // annex C.16. `wreal` (§3.7) declares a discrete real net there is no
    // digital kernel to drive.
    //
    // §2.8.2 makes annex B Table B.1 the whole reservation, and it has neither
    // `net_resolution` (removed by annex G Table G.7 item 5027) nor `assert`
    // (the run reads `asinh`, `assign`), so both are ordinary identifiers
    // (ch10_directives/d10_11, d10_12). `isReserved` models each set by an
    // introduction date only, so it cannot say `net_resolution` was reserved
    // under "VAMS-2.3"; that needs a retirement date as well.
    "wreal",
    // IEEE 1364 digital behavior and structure. Tagged spellings (`assign`,
    // `wait`, the A.3.4 gate types, `posedge`/`negedge`) are not listed here;
    // `keyword_intro` still dates them through `kw_1364_1995`.
    "automatic",
    "cmos",
    "deassign",
    "edge",
    "endprimitive",
    "endspecify",
    "endtable",
    "endtask",
    "force",
    "fork",
    "highz0",
    "highz1",
    "ifnone",
    "join",
    "large",
    "medium",
    "nmos",
    "noshowcancelled",
    "pmos",
    "primitive",
    "pull0",
    "pull1",
    "pulldown",
    "pullup",
    "pulsestyle_ondetect",
    "pulsestyle_onevent",
    "rcmos",
    "release",
    "rnmos",
    // `tranif`/`rtranif` stay untagged: a pass enable switch is a three-terminal
    // gate whose conduction is a logic value, a different construct from `tran`.
    "rpmos",
    "rtranif0",
    "rtranif1",
    "showcancelled",
    "small",
    "specify",
    "specparam",
    "strong0",
    "strong1",
    "table",
    "task",
    "tranif0",
    "tranif1",
    "weak0",
    "weak1",
    // configuration / library (IEEE 1364 clause 13)
    "cell",
    "config",
    "design",
    "endconfig",
    "incdir",
    "include",
    "instance",
    "liblist",
    "library",
    "use",
};

/// IEEE Std 1364-1995 reserved words (102). The oldest set §10.6 names, and a
/// subset of every later one.
const kw_1364_1995 = [_][]const u8{
    "always",    "and",          "assign",     "begin",
    "buf",       "bufif0",       "bufif1",     "case",
    "casex",     "casez",        "cmos",       "deassign",
    "default",   "defparam",     "disable",    "edge",
    "else",      "end",          "endcase",    "endfunction",
    "endmodule", "endprimitive", "endspecify", "endtable",
    "endtask",   "event",        "for",        "force",
    "forever",   "fork",         "function",   "highz0",
    "highz1",    "if",           "ifnone",     "initial",
    "inout",     "input",        "integer",    "join",
    "large",     "macromodule",  "medium",     "module",
    "nand",      "negedge",      "nmos",       "nor",
    "not",       "notif0",       "notif1",     "or",
    "output",    "parameter",    "pmos",       "posedge",
    "primitive", "pull0",        "pull1",      "pulldown",
    "pullup",    "rcmos",        "real",       "realtime",
    "reg",       "release",      "repeat",     "rnmos",
    "rpmos",     "rtran",        "rtranif0",   "rtranif1",
    "scalared",  "small",        "specify",    "specparam",
    "strong0",   "strong1",      "supply0",    "supply1",
    "table",     "task",         "time",       "tran",
    "tranif0",   "tranif1",      "tri",        "tri0",
    "tri1",      "triand",       "trior",      "trireg",
    "vectored",  "wait",         "wand",       "weak0",
    "weak1",     "while",        "wire",       "wor",
    "xnor",      "xor",
};

/// Added by IEEE Std 1364-2001 (21): generate/config/library and signedness.
const kw_1364_2001 = [_][]const u8{
    "automatic",          "cell",          "config",          "design",
    "endconfig",          "endgenerate",   "generate",        "genvar",
    "incdir",             "include",       "instance",        "liblist",
    "library",            "localparam",    "noshowcancelled", "pulsestyle_ondetect",
    "pulsestyle_onevent", "showcancelled", "signed",          "unsigned",
    "use",
};

/// IEEE 1364-2005 §19.11: "the following identifiers are excluded from the
/// reserved list" under "1364-2001-noconfig".
const noconfig_words = std.StaticStringMap(void).initComptime(.{
    .{"cell"},    .{"config"},   .{"design"},  .{"endconfig"}, .{"incdir"},
    .{"include"}, .{"instance"}, .{"liblist"}, .{"library"},   .{"use"},
});

/// Added by IEEE Std 1364-2005 (1).
const kw_1364_2005 = [_][]const u8{"uwire"};

/// Verilog-AMS keywords that postdate the "VAMS-2.3" specifier, per annex G
/// tables G.6 (v2.3.1→v2.4) and G.7 (v2.4→VAMS-2023): `$noise_table_log`
/// (G.6 item 4349), `absdelta` (G.6 item 4803), `return`/`break`/`continue`
/// (G.7 item 830) and `expm1`/`ln1p` (G.7 item 7780). Every other VAMS keyword
/// defaults to `.vams_2_3` (see `isReserved`).
const kw_vams_2023 = [_][]const u8{
    "absdelta", "break", "continue", "expm1", "ln1p", "noise_table_log", "return",
};

const keyword_intro = std.StaticStringMap(KeywordSet).initComptime(intro_kvs);

const IntroKV = struct { []const u8, KeywordSet };

const intro_kvs = kvs: {
    @setEvalBranchQuota(20_000);
    const n = kw_1364_1995.len + kw_1364_2001.len + kw_1364_2005.len + kw_vams_2023.len;
    var out: [n]IntroKV = undefined;
    var i: usize = 0;
    for (.{ kw_1364_1995, kw_1364_2001, kw_1364_2005, kw_vams_2023 }, [_]KeywordSet{
        .v1364_1995, .v1364_2001, .v1364_2005, .vams_2023,
    }) |names, set| {
        for (names) |name| {
            out[i] = .{ name, set };
            i += 1;
        }
    }
    break :kvs out;
};

/// One entry per spelling. A spelling listed twice (a tagged keyword left in
/// `reserved_keywords`) would make `lookupKeyword`'s answer depend on the
/// order `StaticStringMap`'s unstable sort leaves the two in, so it is a
/// compile error here.
const keyword_kvs = kvs: {
    @setEvalBranchQuota(20_000);
    const fields = @typeInfo(Tag).@"enum".field_names[@backingInt(Tag.first_keyword)..@backingInt(Tag.kw_reserved)];
    const n = reserved_keywords.len + fields.len;

    var out: [n]KV = undefined;
    var i: usize = 0;
    for (fields) |f| {
        out[i] = .{ f[3..], @field(Tag, f) };
        i += 1;
    }
    for (reserved_keywords) |name| {
        out[i] = .{ name, .kw_reserved };
        i += 1;
    }
    // Tag names are unique by construction, so a duplicate is a reserved
    // spelling that also has a tag, or one listed twice.
    for (reserved_keywords, 0..) |name, j| {
        if (@hasField(Tag, "kw_" ++ name)) @compileError("keyword spelled twice: " ++ name);
        for (reserved_keywords[0..j]) |b| if (std.mem.eql(u8, name, b)) @compileError("keyword spelled twice: " ++ name);
    }
    break :kvs out;
};

// ---- checks ---------------------------------------------------------------

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

test "keyword_map: spelling round-trips through lexeme" {
    for (keyword_map.keys(), keyword_map.values()) |key, tag| {
        if (tag == .kw_reserved) continue;
        try std.testing.expectEqualStrings(key, Tag.lexeme(tag).?);
    }
    try std.testing.expectEqual(Tag.kw_module, keyword_map.get("module").?);
    try std.testing.expectEqual(Tag.kw_initial_step, keyword_map.get("initial_step").?);
    try std.testing.expectEqual(Tag.kw_posedge, keyword_map.get("posedge").?);
    try std.testing.expectEqual(Tag.kw_reserved, keyword_map.get("primitive").?);
    // Not keywords: system function names (§2.8.3) and ordinary identifiers.
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("temperature"));
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("V"));
    // Nor these two, and the reason is the map's own definition: §2.8.2 makes
    // Annex B the list of all keywords and the 2023 Table B.1 carries neither.
    // Annex G item 5027 took `net_resolution` off it on purpose; `assert` was
    // never on it (the run is `asinh`, `assign`). Pinned here because both are
    // easy to re-add from an older printing. ch10_directives/d10_11, d10_12.
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("assert"));
    try std.testing.expectEqual(@as(?Tag, null), keyword_map.get("net_resolution"));
}

test "lookupKeyword: differential against keyword_map, which stays the reference" {
    // Every spelling is checked three ways: the vector loop that ships, the
    // scalar reference next to it, and `keyword_map.get`, which is §2.8.2's
    // actual definition. A miscompare here is a silent miscompile: a keyword
    // read as an identifier, or the reverse.
    const check = struct {
        fn all(s: []const u8) !void {
            const want = keyword_map.get(s);
            try std.testing.expectEqual(want, lookupKeyword(s));
            if (s.len >= 1 and s.len <= kw_max_len) {
                const lo: usize = kw_len_start[s.len];
                const hi: usize = kw_len_start[s.len + 1];
                try std.testing.expectEqual(want, lookupKeywordScalar(s, lo, hi));
            }
        }
    }.all;

    // 1. Every keyword is still found. This is the only way the scan can be
    //    wrong in the direction that matters: a missed keyword changes the
    //    parse of legal source.
    for (keyword_map.keys()) |key| try check(key);

    // 2. Random spellings. Lengths sweep 0 .. 3× the lane count (32 lanes on
    //    x86_64_v3 → 0..96), so every bucket boundary, the empty case and
    //    everything past the longest keyword are exercised.
    var prng: std.Random.DefaultPrng = .init(0x2820);
    const rand = prng.random();
    var buf: [3 * 64 + 2]u8 = undefined;
    const max_len = 3 * (kw_lanes orelse 32);
    const alphabet = "abcdefghijklmnopqrstuvwxyz_0123456789ABZ";
    for (0..20_000) |_| {
        const len = rand.intRangeAtMost(usize, 0, max_len);
        for (buf[0..len]) |*b| b.* = alphabet[rand.uintLessThan(usize, alphabet.len)];
        try check(buf[0..len]);
    }
    try check("");
    try check("\xffodule");
    try check(&@as([32]u8, @splat('m')));

    // 3. Near misses, where a scan that stops one lane early actually shows up:
    //    every keyword with one byte dropped, one appended, and its first byte
    //    replaced by one no keyword starts with.
    for (keyword_map.keys()) |key| {
        @memcpy(buf[0..key.len], key);
        try check(buf[0 .. key.len - 1]);
        buf[key.len] = '_';
        try check(buf[0 .. key.len + 1]);
        buf[0] = 'q';
        try check(buf[0..key.len]);
    }
}

test "§10.6 keyword sets nest, and the intro table cannot drift from annex B" {
    // Anti-drift: every name that has an introduction date must actually be a
    // keyword. A typo here would silently un-reserve nothing at all.
    for (keyword_intro.keys()) |name| {
        if (keyword_map.get(name) == null) {
            std.debug.print("keyword_intro names a non-keyword: {s}\n", .{name});
            return error.NotAKeyword;
        }
    }
    // Counts straight from the standards (see the array doc comments).
    try std.testing.expectEqual(102, kw_1364_1995.len);
    try std.testing.expectEqual(21, kw_1364_2001.len);

    // The five sets are a chain: reserved in an older set ⇒ reserved in every
    // newer one. `sin` is the LRM §10.6 worked example.
    for (keyword_map.keys()) |name| {
        var prev = false;
        for ([_]KeywordSet{ .v1364_1995, .v1364_2001, .v1364_2005, .vams_2_3, .vams_2023 }) |s| {
            const now = isReserved(name, s);
            try std.testing.expect(!prev or now); // monotone
            prev = now;
        }
        try std.testing.expect(isReserved(name, .vams_2023)); // annex B is the union
    }
    try std.testing.expect(!isReserved("sin", .v1364_2005));
    try std.testing.expect(isReserved("sin", .vams_2_3));
    try std.testing.expect(isReserved("module", .v1364_1995));
    try std.testing.expect(!isReserved("localparam", .v1364_1995));
    try std.testing.expect(isReserved("localparam", .v1364_2001));
    try std.testing.expect(!isReserved("uwire", .v1364_2001));
    try std.testing.expect(isReserved("uwire", .v1364_2005));
    try std.testing.expect(!isReserved("config", .v1364_2001_noconfig)); // §19.11
    try std.testing.expect(isReserved("generate", .v1364_2001_noconfig));
    try std.testing.expect(!isReserved("uwire", .v1364_2001_noconfig));
    try std.testing.expect(!isReserved("ln1p", .vams_2_3)); // annex G.7 item 7780
    try std.testing.expect(isReserved("ln1p", .vams_2023));
    // §10.6 version_specifier strings, all five of them.
    try std.testing.expectEqual(KeywordSet.v1364_1995, KeywordSet.fromSpecifier("1364-1995").?);
    try std.testing.expectEqual(KeywordSet.v1364_2001, KeywordSet.fromSpecifier("1364-2001").?);
    try std.testing.expectEqual(KeywordSet.v1364_2005, KeywordSet.fromSpecifier("1364-2005").?);
    try std.testing.expectEqual(KeywordSet.vams_2_3, KeywordSet.fromSpecifier("VAMS-2.3").?);
    try std.testing.expectEqual(KeywordSet.vams_2023, KeywordSet.fromSpecifier("VAMS-2023").?);
    try std.testing.expectEqual(@as(?KeywordSet, null), KeywordSet.fromSpecifier("1800-2017"));
}

test "call groups match annex A.8.2/A.6.5 exactly and are disjoint" {
    // One group per Ast.ExprTag the parser produces. Counts come straight from
    // the grammar: analog_built_in_function_name = 26, analog_filter_function_
    // call = 17, analog_small_signal_function_call = 5, analog_event_functions
    // = 4. If a tag lands in two groups the parser would pick the wrong tag.
    var counts = [_]u32{ 0, 0, 0, 0 };
    inline for (@typeInfo(Tag).@"enum".field_names) |f| {
        const t: Tag = @field(Tag, f);
        var n: u32 = 0;
        if (isMathFunction(t)) {
            counts[0] += 1;
            n += 1;
        }
        if (isFilterFunction(t)) {
            counts[1] += 1;
            n += 1;
        }
        if (isSmallSignalFunction(t)) {
            counts[2] += 1;
            n += 1;
        }
        if (isEventFunction(t)) {
            counts[3] += 1;
            n += 1;
        }
        try std.testing.expect(n <= 1);
    }
    try std.testing.expectEqual([_]u32{ 26, 17, 5, 4 }, counts);
    // §4.5.13: limexp is a filter, never a math builtin (proof.zig must not
    // put a domain on it, codegen must give it state).
    try std.testing.expect(isFilterFunction(.kw_limexp) and !isMathFunction(.kw_limexp));
    // §5.10.2 step events are their own Ast tags, not `event_function`s.
    try std.testing.expect(!isEventFunction(.kw_initial_step) and !isEventFunction(.kw_final_step));
}

test "§10.6 every version_specifier round-trips; nothing else is one" {
    for (std.enums.values(KeywordSet)) |set| {
        try std.testing.expectEqual(set, KeywordSet.fromSpecifier(set.specifier()).?);
    }
    // §10.6 and IEEE 1364-2005 §19.11 name exactly six strings.
    try std.testing.expectEqual(@as(?KeywordSet, null), KeywordSet.fromSpecifier(""));
    try std.testing.expectEqual(@as(?KeywordSet, null), KeywordSet.fromSpecifier("1364-2005 "));
    try std.testing.expectEqual(@as(?KeywordSet, null), KeywordSet.fromSpecifier("VAMS-2.4"));
}

test "§19.11 1364-2001-noconfig is 1364-2001 less exactly the ten config words" {
    for (keyword_map.keys()) |name| {
        // Between its neighbours in the chain.
        if (isReserved(name, .v1364_1995)) try std.testing.expect(isReserved(name, .v1364_2001_noconfig));
        if (isReserved(name, .v1364_2001_noconfig)) try std.testing.expect(isReserved(name, .v1364_2001));
        const differs = isReserved(name, .v1364_2001) != isReserved(name, .v1364_2001_noconfig);
        try std.testing.expectEqual(noconfig_words.has(name), differs);
    }
    try std.testing.expectEqual(@as(usize, 10), noconfig_words.keys().len);
    // An annex B keyword no 1364 list dates is a Verilog-AMS word: `wreal`
    // (§3.7) is free under 1364-2005 and reserved from VAMS-2.3 on.
    try std.testing.expect(!isReserved("wreal", .v1364_2005));
    try std.testing.expect(isReserved("wreal", .vams_2_3));
    // Annex G Table G.6 item 4803: `absdelta` arrived after VAMS-2.3.
    try std.testing.expect(!isReserved("absdelta", .vams_2_3));
    try std.testing.expect(isReserved("absdelta", .vams_2023));
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

test "lookupKeyword is case-sensitive and whole-word (§2.8: identifiers are case sensitive)" {
    try std.testing.expectEqual(Tag.kw_module, lookupKeyword("module").?);
    try std.testing.expectEqual(@as(?Tag, null), lookupKeyword("Module"));
    try std.testing.expectEqual(@as(?Tag, null), lookupKeyword("MODULE"));
    try std.testing.expectEqual(@as(?Tag, null), lookupKeyword("modul"));
    try std.testing.expectEqual(@as(?Tag, null), lookupKeyword("modules"));
    // The longest keyword sits in the last bucket, and is found there.
    var longest: []const u8 = "";
    for (keyword_map.keys()) |k| if (k.len > longest.len) {
        longest = k;
    };
    try std.testing.expectEqual(kw_max_len, longest.len);
    try std.testing.expectEqual(keyword_map.get(longest).?, lookupKeyword(longest).?);
}
