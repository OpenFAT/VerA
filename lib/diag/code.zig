//! The diagnostic code catalogue: one stable identifier per diagnosable
//! condition, with its title, LRM clause and `--explain` text.
//!
//! No imports: every stage can name a code without pulling in the renderer,
//! and `diag.zig` imports this file without a cycle.

/// Static documentation for one code; every field is a comptime string literal.
pub const Info = struct {
    /// Headline after `error[E0313]: `: a lowercase noun phrase with no
    /// trailing period, code or location. Fixtures pin the code, not the title,
    /// but a title that changes meaning needs a new code.
    title: []const u8,
    /// LRM clause, e.g. `"5.6.1"`, `"A.6.4"`, `"C.7"`; the renderer prints it
    /// under every diagnostic, so messages never spell it inline. Empty for an
    /// engine limit rather than a language rule (`explain` then says so).
    lrm: []const u8,
    /// Long form for `--explain`: the rule, why it exists, how to satisfy it.
    /// Authored pre-wrapped at 76 columns; `--explain` prints it verbatim.
    explain: []const u8,

    // Budget: three slices, 48 B for each of the catalogue's rows.
    comptime {
        if (@sizeOf(Info) > 48) @compileError("Info grew: every catalogue row pays for it");
    }
};

/// Every diagnosable condition VerA can report. The tag name is the rendered
/// spelling.
///
/// Adding a code:
///   - Codes are stable: fixtures, docs and user scripts pin them. A code is
///     never renumbered or reused; retire one by keeping the field and giving
///     it `retiredInfo`.
///   - The first letter is the severity (`E` error, `W` warning).
///   - The first two digits are the owning stage class:
///       01 lexical and preprocessing    06 numerical safety (proof)
///       02 syntax, annex A (parser)     07 events and timing
///       03 types, disciplines, decls    08 system tasks and functions
///       04 behavioral semantics         09 hierarchy and elaboration
///       05 analog operators and math    10 runtime and artifact contract
pub const Code = enum(u16) {
    // ---------------------------------------------------------------- class 1
    // Preprocessing directives (LRM 10) — preprocessor.zig.
    E0101,
    E0102,
    E0103,
    E0104,
    E0105,
    E0106,
    E0107,
    E0108,
    E0109,
    E0110,
    E0111,
    E0112,
    E0113,
    E0114,
    E0115,
    E0116,
    E0117,
    E0118,
    E0119,
    E0120,
    E0121,
    E0122,
    E0123,
    E0124,
    E0125,
    E0126,
    E0127,
    E0128,
    E0129,
    // Lexical (LRM 2) — reported by parser.zig against a lexer `.invalid` token
    // or a `ValueError` from `Lexer.decode*`.
    E0130,
    E0131,
    E0132,
    E0133,
    E0134,
    E0135,
    E0136,
    E0137,
    E0138,
    E0139,
    E0140,
    E0141,
    E0142,
    E0143,
    E0144,
    E0145,
    // Out of scope (IEEE 1364-2005 §28) — preprocessor.zig.
    E0146,
    E0147,
    // Lexical (LRM 2.7) — parser.zig's string-literal scan.
    E0148,
    W0149,
    E0150,

    // ---------------------------------------------------------------- class 2
    // Syntax / annex A — parser.zig.
    E0201,
    E0202,
    E0203,
    E0204,
    E0205,
    E0206,
    E0207,
    E0208,
    E0209,
    E0210,
    E0211,
    E0212,
    E0213,
    E0214,
    E0215,
    E0216,
    E0217,
    E0218,
    E0219,
    E0220,
    E0221,
    E0222,
    E0223,
    E0224,
    E0225,
    E0226,
    E0227,
    E0228,
    E0229,
    E0230,
    E0231,
    E0232,
    E0233,
    E0234,
    E0235,
    E0236,
    E0237,
    E0238,
    E0239,
    E0240,
    E0241,
    E0242,
    E0243,
    E0244,
    E0245,
    E0246,
    E0247,
    E0248,
    E0249,
    E0250,
    E0254,
    E0255,
    E0256,
    E0257,
    E0258,
    E0295,
    E0296,
    E0297,
    E0289,
    E0290,
    E0291,
    E0292,
    E0293,
    W0250,
    W0251,
    W0252,
    W0253,

    // ---------------------------------------------------------------- class 3
    // Declarations, types, disciplines — lower.zig.
    E0301,
    E0302,
    E0303,
    E0304,
    E0305,
    E0306,
    E0307,
    E0308,
    E0309,
    E0310,
    E0311,
    E0312,
    E0313,
    E0314,
    E0315,
    E0316,
    E0317,
    E0318,
    E0319,
    E0320,
    E0321,
    E0322,
    E0323,
    E0324,
    E0325,
    E0326,
    E0327,
    E0328,
    E0329,
    E0330,
    E0331,
    E0332,
    E0333,
    E0334,
    E0335,
    E0336,
    E0337,
    E0338,
    E0339,
    E0340,
    E0341,
    E0342,
    E0343,
    E0344,
    E0345,
    E0346,
    E0347,
    E0348,
    E0349,
    E0350,
    E0351,
    E0352,
    E0353,
    E0354,
    E0355,
    E0356,
    E0357,
    E0358,
    E0359,
    E0360,
    E0361,
    E0362,
    E0363,
    E0364,
    E0365,
    E0366,
    E0367,
    E0368,
    E0369,
    E0370,
    E0371,
    E0372,
    E0373,
    E0374,
    E0375,
    E0376,
    E0377,

    // ---------------------------------------------------------------- class 4
    // Behavioral semantics: statements and contributions — lower.zig.
    E0401,
    E0402,
    E0403,
    E0404,
    E0405,
    E0406,
    E0407,
    E0408,
    E0409,
    E0410,
    E0411,
    E0412,
    E0413,
    E0414,
    E0415,
    E0416,
    E0417,
    E0418,
    E0419,
    E0420,
    E0421,
    E0422,
    E0423,
    E0424,
    E0425,
    E0426,
    E0427,
    E0428,
    E0429,
    E0430,
    E0431,
    E0432,
    E0433,
    E0434,
    E0435,
    E0436,
    E0437,
    E0438,
    E0439,
    E0440,
    E0477,

    // ---------------------------------------------------------------- class 5
    // Analog operators and math functions — lower.zig.
    E0501,
    E0502,
    E0503,
    E0504,
    E0505,
    E0506,
    E0507,
    E0508,
    E0509,
    E0510,
    E0511,
    E0512,
    E0513,
    E0514,
    E0515,
    E0516,
    E0517,
    E0518,
    E0519,
    E0520,
    E0521,
    E0522,
    E0523,
    E0524,
    E0525,
    E0526,
    E0527,
    E0528,
    E0529,
    E0530,
    E0531,
    E0532,
    E0533,
    E0534,
    E0535,
    E0536,
    E0537,
    E0538,
    E0539,
    E0540,
    E0572,
    E0573,
    E0574,

    // ---------------------------------------------------------------- class 6
    // Numerical safety / finiteness — proof.zig.
    E0601,
    E0602,
    E0603,
    E0604,
    E0605,
    E0606,
    E0607,
    E0608,
    E0609,
    W0650,
    W0651,
    W0652,
    W0653,

    // ---------------------------------------------------------------- class 7
    // Events and timing — lower.zig.
    E0701,
    E0702,
    E0703,
    E0704,
    E0705,
    E0706,
    E0707,
    E0708,
    /// A monitored event under the fixed-grid testbench, which inserts no
    /// timepoint at a crossing or timer.
    W0750,

    // ---------------------------------------------------------------- class 8
    // System tasks and functions — lower.zig.
    E0801,
    E0802,
    E0803,
    E0804,
    E0805,
    E0806,
    E0807,
    E0808,
    E0809,
    E0810,
    E0811,
    E0812,
    E0813,
    E0814,
    E0815,
    E0816,
    E0817,
    E0818,
    E0819,
    W0850,
    W0852,

    // ---------------------------------------------------------------- class 9
    // Hierarchy and elaboration — lower.zig, elaborate.zig.
    E0901,
    E0902,
    E0903,
    E0904,
    E0905,
    E0906,
    E0907,
    E0908,
    E0909,
    E0910,
    E0911,
    E0912,
    E0913,
    E0914,
    E0915,
    E0916,
    E0917,

    // --------------------------------------------------------------- class 10
    // Runtime / artifact contract — codegen.zig, root.zig.
    E1001,
    E1002,
    E1003,
    E1004,
    E1010,
    E1011,
    E1012,
    E1013,
    E1014,
    E1015,
    E1016,
    E1017,
    E1018,
    E1019,
    E1020,
    E1100,
    E1101,
    E1102,
    /// A `.v` design that cannot be a contract device.
    E1103,
    /// A SystemVerilog source.
    E1104,
    /// IEEE 1364-2005 §15: a timing check argument the digital engine
    /// cannot bind (a notifier that is no variable, an event terminal that
    /// is no whole or constant-select vector).
    E1147,
    /// IEEE 1364-2005 Tables 15-1..15-11: a limit or threshold that is not
    /// a non-negative constant expression.
    E1148,
    /// IEEE 1364-2005 §15: a timing check form the digital engine does not
    /// evaluate, refused by name.
    E1149,
    W1150,
    W1151,
    W1152,
    W1153,
    W1154,
    /// A `.v` device whose digital tick is 1 s.
    W1155,
    /// A `$readmem` file address outside the memory, with no bounds given.
    W1156,
    /// IEEE 1364-2005 §17.2.9: a `$readmem` file address outside the
    /// task's range; the load is terminated, the run goes on.
    E1157,
    W1160,
    /// IEEE 1364-2005 §15: a timing check reported a violation at run time.
    W1199,
    W1050,
    W0950,
    W0951,
    E0952,
    E0953,
    E0820,
    E0821,
    E0822,
    E0824,
    E0918,
    E0919,
    E0920,
    E0921,
    E0922,
    E0923,
    E0924,
    E0925,
    E0926,
    E0927,
    E0928,
    E0929,
    E0930,
    E0960,
    E0982,
    E0997,
    E0998,
    E0482,
    E0483,
    E0484,
    E0485,
    E0486,
    E0887,
    E0888,
    E0889,
    E0890,
    /// §9.17.3 a `$limit` argument that is not the form Syntax 9-12 spells.
    E0891,
    /// §9.14 / IEEE 1364-2005 §17.11.1 `$clog2` takes an integral operand.
    E0892,
    /// §9.14 an analog wide operand whose high bits the carrier erased.
    E0893,
    E0894,
    /// §9.17.3 a `$limit` site the device does not honour: the probe is
    /// returned unchanged, which the clause permits.
    W0853,
    /// A `$limit` seed on a branch `seed` does not start: named, never
    /// silently dropped.
    W0854,
    /// §9.16 a `$simprobe` name that does not fold: run-time resolution is
    /// not implemented, and the fallback would answer a valid name wrongly.
    E0823,
    /// `--emit-osdi` of a device with `$vera_reject_step`: OSDI 0.4 has no
    /// slot for a step-rejection request (VD-102).
    E1099,
    /// `--emit-osdi` of a device whose §4.6.4.6 noise generator feeds two
    /// rows: OSDI 0.4 reports them as independent sources (VD-102).
    W1098,
    /// LRM 4.5.7: an absdelay history ring that filled while its window was
    /// still needed now keeps older samples at a coarser spacing.
    W1051,
    /// §9.4.3 the '#' flag on a conversion that has no alternative form.
    E0825,
    /// §9.4.2 Table 9-21's `%%` written with a flag, width or precision.
    E0826,
    /// IEEE 1364-2005 §17.1.1.2 C's '-', '+' or ' ' flag on a digital-context
    /// conversion that is not a real one.
    E0827,
    /// §9.4.3 an analog-context format's field width or precision past
    /// VerA's limit of 2^30.
    E0828,
    /// §9.2 a system function the tables allow in the digital context that
    /// VerA's digital engine does not run, refused by name.
    E0829,

    /// The rendered spelling, `"E0313"`: a static string, one letter and four
    /// digits (the catalogue test pins the shape).
    pub fn name(self: Code) []const u8 {
        return @tagName(self);
    }
};

/// Returns the documentation for `c` with one indexed load.
pub fn info(c: Code) Info {
    return table[@backingInt(c)];
}

// Built at comptime from the exhaustive `infoOf` switch: a code without an arm
// fails to compile, text binds to a code by name, and the switch itself never
// reaches the binary. What does: 370 rows x 48 B = 17.8 KB of `.rodata` plus
// about 214 KB of text, no relocations in the static executable, and nothing
// touched until a diagnostic renders. Rows of u32 offsets into one blob would
// save ~14 KB of the binary and no RSS; not worth a second encoding.
const table = build: {
    const e = @typeInfo(Code).@"enum";
    // Dense values make a tag usable as an index. Retired codes keep their
    // slot, so this holds by construction; the indexing is silently wrong if
    // it ever stops holding.
    for (e.field_names, e.field_values, 0..) |name, value, i| {
        if (value != i) @compileError("Code values must be dense: " ++ name ++ " is out of sequence");
    }
    @setEvalBranchQuota(100 * e.field_names.len);
    var t: [e.field_names.len]Info = undefined;
    for (e.field_values) |value| t[value] = infoOf(@fromBackingInt(@intCast(value)));
    break :build t;
};

fn retiredInfo(explanation: []const u8) Info {
    return .{
        .title = "(retired)",
        .lrm = "",
        .explain = explanation,
    };
}

/// The catalogue proper; called only by `table`'s comptime initializer.
fn infoOf(c: Code) Info {
    return switch (c) {
        // ------------------------------------------------------------ class 1
        .E0101 => .{
            .title = "unterminated `ifdef",
            .lrm = "10.5",
            .explain =
            \\A `ifdef, `ifndef or `elsif block reached end of file without a
            \\matching `endif. Conditional compilation blocks do not close
            \\implicitly, and they may nest, so a missing `endif silently
            \\swallows the rest of the file.
            \\
            \\The reported location is the end of the source; the unclosed
            \\directive itself is named in the attached note.
            ,
        },
        .E0102 => .{
            .title = "unterminated block comment",
            .lrm = "2.4",
            .explain =
            \\A `/*` comment reached end of file without a closing `*/`.
            \\
            \\LRM 2.4: "Block comments shall not be nested." A `/*` inside a
            \\block comment is therefore ordinary comment text and does NOT
            \\open a second comment, so exactly one `*/` closes the comment
            \\that a given `/*` opened.
            ,
        },
        .E0103 => .{
            .title = "expected a directive or macro name after '`'",
            .lrm = "10",
            .explain =
            \\A backtick must be followed immediately by a compiler directive
            \\keyword (`define, `include, `ifdef, ...) or by the name of a
            \\macro to expand. Whitespace or a non-identifier character after
            \\the backtick has no meaning.
            ,
        },
        .E0104 => .{
            .title = "conditional directive requires a macro name",
            .lrm = "10.5",
            .explain =
            \\`ifdef and `ifndef each take exactly one macro name:
            \\
            \\    `ifdef  NAME
            \\    `ifndef NAME
            \\
            \\The name is not expanded — it is only tested for existence.
            ,
        },
        .E0105 => .{
            .title = "`else / `elsif without `ifdef",
            .lrm = "10.5",
            .explain =
            \\`else and `elsif may only appear inside a conditional block
            \\opened by `ifdef or `ifndef. Check for an extra `endif above
            \\this line that closed the block early.
            ,
        },
        .E0106 => .{
            .title = "`else / `elsif after `else",
            .lrm = "10.5",
            .explain =
            \\A conditional block has at most one `else, and it must be the
            \\last arm. Every `elsif has to precede it.
            ,
        },
        .E0107 => .{
            .title = "`elsif requires a macro name",
            .lrm = "10.5",
            .explain =
            \\`elsif takes exactly one macro name to test, exactly like
            \\`ifdef. Bare `elsif is not a synonym for `else.
            ,
        },
        .E0108 => .{
            .title = "`endif without `ifdef",
            .lrm = "10.5",
            .explain =
            \\This `endif closes a conditional block that was never opened.
            \\Usually one `endif too many, or an `ifdef that was deleted
            \\without its partner.
            ,
        },
        .E0109 => .{
            .title = "`define requires a macro name",
            .lrm = "10.4",
            .explain =
            \\`define takes a macro name, then an optional parenthesised
            \\formal argument list, then the replacement text:
            \\
            \\    `define NAME            text
            \\    `define NAME(a, b)      text using a and b
            \\
            \\LRM 10.4 also reserves the `__VAMS_` prefix for predefined
            \\macros; do not define a macro whose text begins with it.
            ,
        },
        .E0110 => .{
            .title = "malformed formal argument list for `define",
            .lrm = "10.4",
            .explain =
            \\The parentheses after a function-like macro name must contain a
            \\comma-separated list of plain identifiers. Defaults, types and
            \\nested parentheses are not part of the grammar.
            ,
        },
        .E0111 => .{
            .title = "unterminated formal argument list for `define",
            .lrm = "10.4",
            .explain =
            \\The '(' that opened a function-like macro's formal argument list
            \\has no matching ')' before the end of the definition. Remember
            \\that a `define body ends at the first unescaped newline, so a
            \\list continued onto the next line needs a trailing backslash.
            ,
        },
        .E0112 => .{
            .title = "expected ',' or ')' in `define argument list",
            .lrm = "10.4",
            .explain =
            \\Formal arguments of a function-like macro are separated by
            \\commas and closed by a single ')'.
            ,
        },
        .E0113 => .{
            .title = "`undef requires a macro name",
            .lrm = "10.4",
            .explain =
            \\`undef takes exactly one macro name.
            \\
            \\LRM 10.4: `undef "shall have no effect" on a PREDEFINED macro.
            \\Undefining a name that was never defined is likewise harmless —
            \\this error is only about the missing name.
            ,
        },
        .E0114 => retiredInfo(
            \\"unsupported compiler directive". Retired: it had exactly two
            \\subjects left, 10.7's `__FILE__ and `__LINE__, and both are now
            \\expanded. Every other backtick word VerA does not know is an
            \\undefined macro, which is E0115. The number is not reused.
        ),
        .E0115 => .{
            .title = "undefined macro",
            .lrm = "10.4",
            .explain =
            \\This name was used with a leading backtick but never `define'd,
            \\and it is not one of the predefined `__VAMS_*` macros.
            \\
            \\If the definition lives in another file, add an `include for it,
            \\or pass the directory holding it via the include search path.
            \\
            \\Annex D.2's macros (`M_PI`, `P_K` and the rest) are defined by
            \\constants.vams, and `vera` gives them only to a source that
            \\includes it: write `include "constants.vams"` (or "constants.h")
            \\before the first use. VerA ships the file, so no include path is
            \\needed.
            ,
        },
        .E0116 => .{
            .title = "function-like macro used without an argument list",
            .lrm = "10.4",
            .explain =
            \\This macro was defined with a formal argument list, so every use
            \\must supply actual arguments in parentheses. A function-like
            \\macro named without '(' is not a shorthand for its body.
            ,
        },
        .E0117 => .{
            .title = "macro argument count mismatch",
            .lrm = "10.4",
            .explain =
            \\A function-like macro must be invoked with exactly as many
            \\actual arguments as it declares formals. Arguments are split on
            \\top-level commas only: a comma inside nested parentheses, or
            \\inside a string, belongs to the argument that contains it.
            ,
        },
        .E0118 => .{
            .title = "recursive macro expansion",
            .lrm = "10.4",
            .explain =
            \\A macro's expansion refers to the macro currently being expanded.
            \\Text substitution has no fixed point here, so the preprocessor
            \\stops instead of looping.
            \\
            \\The chain of expansions that led back to this macro is listed in
            \\the attached notes.
            ,
        },
        .E0119 => .{
            .title = "macro or `include nesting deeper than memory allows",
            .lrm = "10.4",
            .explain =
            \\Out of memory, not a language rule: VerA sets no bound on how
            \\deep macro expansions (argument pre-expansion included) or
            \\`include files nest. Each level past the caller's stack runs on
            \\a stack reserved from memory, and this error says the operating
            \\system refused that reservation; the message names the depth.
            \\
            \\A macro that expands itself, directly or through others, is
            \\E0118, and a file that includes itself unchanged is E0125: those
            \\never end, at any depth. Until 2026-10 this code was a fixed cap
            \\of 128 nested expansions.
            ,
        },
        .E0120 => .{
            .title = "unterminated macro argument list",
            .lrm = "10.4",
            .explain =
            \\The '(' opening a function-like macro's actual arguments has no
            \\matching ')'. Unlike a `define body, an argument list may span
            \\newlines, so the scan ran to end of file.
            ,
        },
        .E0121 => .{
            .title = "`include requires a file name",
            .lrm = "10.3",
            .explain =
            \\`include takes one double-quoted file name:
            \\
            \\    `include "disciplines.vams"
            ,
        },
        .E0122 => .{
            .title = "`include file name must be quoted",
            .lrm = "10.3",
            .explain =
            \\LRM 10.3 spells the argument of `include as a double-quoted
            \\string. The angle-bracket form C uses is not part of the
            \\Verilog-AMS grammar; the search path is configured by the tool,
            \\not by the quoting style.
            ,
        },
        .E0123 => .{
            .title = "unterminated `include file name",
            .lrm = "10.3",
            .explain =
            \\The opening double quote of an `include file name has no closing
            \\quote on the same line. LRM 2.7 confines a string literal to one
            \\line.
            ,
        },
        .E0124 => .{
            .title = "empty `include file name",
            .lrm = "10.3",
            .explain = "`include \"\" names no file.",
        },
        .E0125 => .{
            .title = "`include cycle",
            .lrm = "10.3",
            .explain =
            \\A file includes itself, directly or through a chain, at a point
            \\where every macro is defined exactly as it was when the file was
            \\opened before (and as many conditionals are open). The
            \\preprocessor's control flow reads nothing else, so the nesting
            \\would repeat forever; IEEE 1364-2005 19.5 requires it to be
            \\finite. The cycle is listed in the attached notes.
            \\
            \\Any finite nesting is read, however deep, including a file that
            \\includes itself under a guard that changes a macro each time.
            \\Guard headers with the usual idiom:
            \\
            \\    `ifndef MY_HEADER
            \\    `define MY_HEADER
            \\    ...
            \\    `endif
            \\
            \\Until 2026-10 this code was a fixed cap of 32 nested files.
            ,
        },
        .E0126 => .{
            .title = "cannot find include file",
            .lrm = "10.3",
            .explain =
            \\The named file was not found. IEEE 1364-2005 19.5 lets the name be
            \\"a full or relative path name" and says no more; VerA opens a full
            \\path as written, and looks for a relative one in the directory of
            \\the file that holds the `include, then in each -I directory in
            \\order, then among the built-in annex D standard definitions
            \\(disciplines.vams, constants.vams, and their Verilog-A 1.0 names
            \\discipline.h and constants.h).
            \\
            \\Note that annex D headers are built in: including them works
            \\with no search path configured at all.
            ,
        },
        .E0127 => .{
            .title = "malformed `default_discipline qualifier",
            .lrm = "10.2",
            .explain =
            \\Syntax 10-1 spells the directive
            \\
            \\    `default_discipline [ discipline_identifier [ qualifier ] ]
            \\
            \\and the qualifier is a CLOSED alternation of fifteen data-type
            \\names: integer, real, reg, wreal, wire, tri, wand, triand, wor,
            \\trior, trireg, tri0, tri1, supply0, supply1.
            \\
            \\A discipline name in that slot is the common typo, because the
            \\two operands are adjacent identifiers. The qualifier selects
            \\WHICH nets the default claims, so more than one directive can be
            \\in force at once "provided each differs in qualifier"; it is not
            \\a second discipline and not free text.
            ,
        },
        .E0128 => .{
            .title = "malformed `line directive",
            .lrm = "10.7",
            .explain =
            \\LRM 10.7 defers to IEEE Std 1364 for `line, whose 19.7 spells it
            \\
            \\    `line number "filename" level
            \\
            \\and says "All parameters in the `line directive are required".
            \\The number is a positive integer, the line number given to the
            \\line FOLLOWING the directive; it is what `__LINE__ then counts
            \\from. The level is 0, 1 or 2 (1: the next line is the first of an
            \\included file, 2: the first after one, 0: any other). Only white
            \\space may follow it on the line.
            ,
        },
        .E0129 => .{
            .title = "malformed `default_transition directive",
            .lrm = "10.3",
            .explain =
            \\LRM 10.3 Syntax 10-2 is
            \\
            \\    `default_transition transition_time
            \\    transition_time ::= constant_expression
            \\
            \\with no brackets round the operand, so it is mandatory. A bare
            \\`default_transition is NOT a request for the simulator default:
            \\10.3 already states that case ("If a `default_transition
            \\directive is not used in the description, transition_time is
            \\controlled by the simulator"), so reading the operand-less form
            \\as it would silently discard a line the author wrote.
            \\
            \\The directive is read in the text stage, before there is a
            \\parser to fold a general constant_expression, so what it accepts
            \\is one LRM 2.6 number — with a Table 2-1 scale factor if you
            \\want one: `default_transition 4n.
            ,
        },
        .E0130 => .{
            .title = "literal requires digital value support in the execution backend",
            .lrm = "2.6.1",
            .explain =
            \\The frontend preserves Verilog-AMS four-state and wide integer
            \\literals; this one reached an analog expression, where it has no
            \\value. Two cases share the code:
            \\
            \\  - an x or z bit (`1'bx`, `4'b10z1`). LRM 7.3.2: "It is an error
            \\    if these operands return x or z bit values when solved." Only
            \\    ===, !==, case/casex/casez and the x/z digits they compare
            \\    against may meet x/z in an analog block, so in any other
            \\    operand, a $display argument included, this is the LRM's
            \\    prohibition, not a VerA limit;
            \\  - a two-state literal wider than the 64-bit carrier the analog
            \\    backend stores integers in. That is an implementation limit
            \\    (specification/Vague_Decisions.md §7), not a rule of the LRM.
            ,
        },
        .E0131 => .{
            .title = "expected a numeric base after the apostrophe",
            .lrm = "2.6.1",
            .explain =
            \\A sized literal is <size>'<base><digits>, where <base> is one of
            \\b/B, o/O, d/D or h/H:
            \\
            \\    8'hFF   4'b1010   16'd65535
            ,
        },
        .E0132 => .{
            .title = "expected a numeric digit after the base",
            .lrm = "2.6.1",
            .explain =
            \\The base specifier must be followed by at least one digit valid
            \\in that base.
            \\
            \\LRM 2.6.1 also makes a sign here illegal: "A plus or minus
            \\operator between the base format and the number is an illegal
            \\syntax", so 8'd -6 must be written -8'd6.
            ,
        },
        .E0133 => .{
            .title = "invalid number literal",
            .lrm = "2.6",
            .explain =
            \\The literal does not match any LRM 2.6 form. The usual causes:
            \\
            \\  - a digit outside the declared base (8'b2)
            \\  - a real without a digit on both sides of the point: LRM 2.6.2
            \\    requires "at least one digit on each side", so .12, 9. and
            \\    4.E3 are all invalid
            \\  - a leading underscore: legal "anywhere in a number except as
            \\    the first character"
            \\  - a scale factor with a space before it, or on an integer:
            \\    LRM 2.6.2 permits no space, and scale factors attach to
            \\    reals only
            ,
        },
        .E0134 => retiredInfo(
            \\"number literal is too long". Retired 2026-10: a real literal of
            \\any length decodes (2.6.2 writes its digits with no length
            \\bound); the 512-byte decode buffer it named is gone. The number
            \\is not reused.
        ),
        .E0135 => .{
            .title = "unsupported keyword set",
            .lrm = "10.6",
            .explain =
            \\`begin_keywords takes a quoted version specifier naming the
            \\keyword set to make active. VerA recognises the Verilog-AMS
            \\and IEEE 1364 sets listed in LRM annex B; an unknown specifier
            \\would silently change which identifiers are reserved.
            ,
        },
        .E0136 => .{
            .title = "`end_keywords without `begin_keywords",
            .lrm = "10.6",
            .explain =
            \\`end_keywords pops the keyword set that `begin_keywords pushed.
            \\This one has nothing to pop.
            ,
        },
        .E0137 => retiredInfo(
            \\"unterminated `begin_keywords". Retired: 10.6 gives the directive
            \\scope "even across source code file boundaries", so an open pair
            \\at end of file is the clause working, not an error. The number is
            \\not reused.
        ),
        .E0138 => .{
            .title = "a string literal may not span lines",
            .lrm = "2.7",
            .explain =
            \\LRM 2.7: "A string literal is a sequence of characters enclosed
            \\by double quotes (") and contained on a single line." Table 2-2
            \\then lists every escape a string may hold -- \n, \t, \\, \" and
            \\\ddd -- and a backslash before a newline is not one of them.
            \\
            \\Continuing a string across a line break is a SystemVerilog
            \\addition (IEEE 1800 5.9). Verilog-AMS is derived from IEEE
            \\1364-2005 (LRM 1.1), whose 3.6 carries the same single-line
            \\rule, so a model that relies on the continuation is using a
            \\vendor extension that this LRM does not grant.
            \\
            \\Keep the literal on one line. A newline in the OUTPUT is what
            \\\n is for:
            \\
            \\    $strobe("first line\nsecond line");
            ,
        },
        .E0139 => .{
            .title = "macro text may not begin with __VAMS_",
            .lrm = "10.4",
            .explain =
            \\LRM 10.4: "To avoid conflicts with predefined Verilog-AMS macros
            \\(10.5), the `define compiler directive's macro text shall not
            \\begin with __VAMS_."
            \\
            \\Syntax 10-3 is what fixes the target of that sentence:
            \\
            \\    text_macro_definition ::= `define text_macro_name macro_text
            \\
            \\macro_text is the SECOND operand, so the prohibition is on the
            \\body. The NAME is unrestricted -- `define __VAMS_MY_FLAG 1 is
            \\legal -- and the rationale agrees: only a body can expand INTO a
            \\10.5 predefined macro and shadow it.
            ,
        },
        .E0140 => .{
            .title = "`default_nettype takes one net type",
            .lrm = "10.1",
            .explain =
            \\LRM 10.1 carries `default_nettype over from IEEE Std 1364
            \\unchanged, and 1364 19.2 gives it a closed grammar with no
            \\brackets round the operand:
            \\
            \\    `default_nettype default_nettype_value
            \\    default_nettype_value ::=
            \\        wire | tri | tri0 | tri1 | wand | triand
            \\      | wor | trior | trireg | uwire | none
            \\
            \\So the operand is MANDATORY and the list is closed. The two
            \\mistakes this catches are a missing operand and a word off the
            \\list -- most often one of 10.2's `default_discipline qualifiers,
            \\which is a longer list for a different directive: `integer`,
            \\`real`, `reg`, `wreal`, `supply0` and `supply1` are qualifiers
            \\but not net types an implicit net may have.
            \\
            \\`none` is the member that does something: it withdraws implicit
            \\nets, so an undeclared identifier used as a net becomes E0365
            \\instead of a silently created wire.
            ,
        },
        .E0141 => .{
            .title = "`unconnected_drive takes pull0 or pull1",
            .lrm = "10.1",
            .explain =
            \\LRM 10.1 carries `unconnected_drive over from IEEE Std 1364
            \\unchanged, and 1364 19.9 makes the operand a two-way
            \\alternation with no bracket round it:
            \\
            \\    `unconnected_drive pull1 | pull0
            \\
            \\The form that takes no operand is a DIFFERENT directive and has
            \\its own row in Table 10-1: `nounconnected_drive. So a bare
            \\`unconnected_drive is not "restore the default", it is a
            \\directive with its operand missing.
            ,
        },
        .E0142 => .{
            .title = "malformed `timescale",
            .lrm = "10.1",
            .explain =
            \\LRM 10.1 carries `timescale over from IEEE Std 1364 unchanged.
            \\1364 19.9 gives it a closed grammar --
            \\
            \\    `timescale <time_unit> / <time_precision>
            \\
            \\-- where each operand is 1, 10 or 100 glued to one of the six
            \\unit names s, ms, us, ns, ps, fs (Table 19-1), plus one semantic
            \\constraint: "The time precision shall be at least as precise as
            \\the time unit". `timescale 1ps/1ns breaks that one.
            \\
            \\Nothing in the analog kernel rescales on this directive -- 9.10
            \\`$abstime` is seconds whatever it says -- but 9.15 Table 9-27
            \\publishes both operands as `$simparam("timeUnit")` and
            \\`$simparam("timePrecision")`, and the digital executor builds its
            \\tick from them. A directive with no reading cannot supply either,
            \\so it is refused where it is written rather than at the far end
            \\of the compilation.
            ,
        },

        .E0143 => .{
            .title = "a compiler directive cannot be a macro name",
            .lrm = "10.4",
            .explain =
            \\LRM 10.4 takes `define from IEEE Std 1364, whose 19.3.1 says: "All
            \\compiler directives shall be considered predefined macro names; it
            \\shall be illegal to redefine a compiler directive as a macro name."
            \\
            \\The directives are the ones 10.1 Table 10-1 lists, `__FILE__ and
            \\`__LINE__ included. After `define include 1, `include would be
            \\ambiguous between the directive and the macro; the rule removes the
            \\question. Rename the macro.
            ,
        },

        .E0144 => .{
            .title = "text after the `include file name",
            .lrm = "10.1",
            .explain =
            \\LRM 10.1 takes `include from IEEE Std 1364, whose 19.5 says: "Only
            \\white space or a comment may appear on the same line as the
            \\`include compiler directive." So
            \\
            \\    `include "fileB" // including fileB
            \\
            \\is legal and anything else after the file name is not. Put it on
            \\the next line.
            ,
        },

        .E0145 => .{
            .title = "macro text splits a string literal",
            .lrm = "10.4",
            .explain =
            \\LRM 10.4 takes `define from IEEE Std 1364, whose 19.3.1 says: "The
            \\text specified for macro text shall not be split across the
            \\following lexical tokens: Comments, Numbers, Strings, Identifiers,
            \\Keywords, Operators", and gives this as illegal:
            \\
            \\    `define first_half "start of string
            \\    $display(`first_half end of string");
            \\
            \\A string literal has to open and close inside one macro's text.
            \\Define the whole string, or pass the text in as an argument.
            ,
        },
        .E0146 => .{
            .title = "protected envelopes are not supported",
            .lrm = "IEEE 1364-2005 28",
            .explain =
            \\IEEE 1364-2005 19.10 lets a tool ignore a `pragma it does not
            \\recognize, but `protect` is not such a pragma: clause 28 reserves
            \\it for protected envelopes, and 28.2 says a tool "shall perform
            \\envelope decryption for all decryption envelopes contained in the
            \\source text". Ignoring the directive would compile the ciphertext
            \\of a decryption envelope as Verilog, or the cleartext of an
            \\encryption envelope as if nobody had asked for it to be hidden.
            \\
            \\VerA does not implement clause 28: it neither encrypts nor
            \\decrypts, so any `pragma protect is refused. Compile the cleartext
            \\source with the protect directives removed. Any other pragma name
            \\still has no effect.
            ,
        },
        .E0150 => .{
            .title = "preprocessed text larger than 4294967295 bytes",
            .lrm = "10.4",
            .explain =
            \\Macro expansion produced more text than the lexer can address:
            \\every later stage locates a token by a 32-bit offset into the
            \\preprocessed text, so it holds at most 2^32 - 1 bytes. This is a
            \\bound of VerA's representation, not a language rule. A macro
            \\that doubles its text at each of 40 levels (2^40 tokens) is the
            \\usual way to reach it. Expand less, or split the design into
            \\files compiled separately.
            \\
            \\Until 2026-10 the bound was 64 MiB of substituted macro bodies.
            ,
        },
        .E0147 => .{
            .title = "`pragma requires a pragma name",
            .lrm = "IEEE 1364-2005 19.10",
            .explain =
            \\IEEE 1364-2005 Syntax 19-9 is `pragma pragma_name [ pragma_expression
            \\{ , pragma_expression } ], and "The pragma specification is
            \\identified by the pragma_name, which follows the `pragma
            \\directive." A `pragma with nothing after it on its line names no
            \\pragma, so it is not the unrecognized pragma 19.10 lets a tool
            \\ignore. Write the pragma's name, or delete the directive.
            ,
        },
        .E0148 => .{
            .title = "octal escape is above \\377",
            .lrm = "2.7",
            .explain =
            \\LRM 2.7 Table 2-2 (and IEEE 1364-2005 3.6.3) lets \ddd name "A
            \\character specified in 1-3 octal digits", and adds:
            \\"Implementations may issue an error if the character represented
            \\is greater than \377." VerA does. A string holds 8-bit bytes, and
            \\\400 through \777 name none, so any byte VerA picked would be its
            \\own invention, and another tool may refuse the escape outright.
            \\
            \\Write the byte you mean: \377 is the largest, and "\477" was
            \\probably "\47" followed by the character 7.
            ,
        },
        .W0149 => .{
            .title = "escape is not in Table 2-2",
            .lrm = "2.7",
            .explain =
            \\LRM 2.7 Table 2-2 (and IEEE 1364-2005 3.6.3) defines five escapes
            \\in a string: \n, \t, \\, \" and \ddd. Neither standard says what
            \\a backslash before any other character means. VerA keeps the
            \\character and drops the backslash, so "\q" is "q" and "\%" is
            \\"%", the C-family convention. Another tool may keep both bytes or
            \\refuse the literal, so the string is not portable.
            \\
            \\Write the character without the backslash, or \\ for a backslash.
            ,
        },

        // ------------------------------------------------------------ class 2
        .E0201 => .{
            .title = "construct is not in the supported subset",
            .lrm = "A.1.2",
            .explain =
            \\Between design elements the parser found a token that begins no
            \\description. LRM A.1.2: "source_text ::= { description }", and a
            \\description is a module (or macromodule or connectmodule),
            \\udp_declaration, config_declaration, paramset_declaration,
            \\nature_declaration, discipline_declaration or
            \\connectrules_declaration. A stray `endmodule`, a net declared
            \\before any module, or a character the lexer could not read lands
            \\here.
            \\
            \\The parser skips to the next description and keeps going, so the
            \\file's other errors are still reported.
            ,
        },
        .E0202 => .{
            .title = "directive is only legal outside a design element",
            .lrm = "10.6",
            .explain =
            \\`begin_keywords and `end_keywords change which identifiers are
            \\reserved words, so LRM 10.6 confines them to the space between
            \\design elements. Placing one inside a module would change the
            \\keyword set halfway through parsing it.
            \\
            \\The clause lists the elements it means, and it is not just
            \\modules: "outside of a design element (module, primitive,
            \\configuration, paramset, connectrules or connectmodule)". Of
            \\those, VerA parses module, connectmodule, paramset and
            \\connectrules, and all four report here.
            ,
        },
        .E0203 => retiredInfo(
            \\"named event declaration is not implemented". Retired: A.2.1.3
            \\`event_declaration` now parses and 5.10.4's trigger/detect pair
            \\lowers, so the condition does not exist to report. A named event is
            \\an ANALOG event — 5.10 lists it as one of three kinds — so refusing
            \\the declaration was refusing part of the subset annex C.2 grants.
            \\
            \\What replaced it: E0705, for a `@(ev)` or `-> ev` naming something
            \\no `event` declaration introduced. The number is not reused.
        ),
        .E0204 => retiredInfo(
            \\"module instantiation is not supported". Retired: A.4.1
            \\module_instantiation now parses and `elab/elaborate.zig` flattens
            \\the instance tree into the one device VerA emits, so the condition does
            \\not exist to report. Annex C.8 keeps clause 6 hierarchy inside the
            \\Verilog-A subset, which made refusing an instance a refusal of part
            \\of the subset.
            \\
            \\What replaced it: E0904 (the instance names no module), E0905 (the
            \\instantiation is recursive), E0906 (the port connections do not
            \\match the port list) and E0907 (an override names no parameter).
            \\The number is not reused.
        ),
        .E0205 => .{
            .title = "unsupported module item",
            .lrm = "A.1.4",
            .explain =
            \\A.1.4 derives this module item, and VerA does not implement it in
            \\this context: an annex B spelling with no production here yet, a
            \\digital `task` in an analog compilation, a `case` generate with
            \\no generate region above it, a `wreal` in a Verilog-A source
            \\(annex C.4), a net array in an analog compilation (the digital
            \\engine runs one; analog lowering has no array of nodes).
            \\
            \\Text that is not a module item at all is E0240, a syntax error.
            ,
        },
        .E0206 => .{
            .title = "identifier is not a port of this module",
            .lrm = "6.5.1",
            .explain =
            \\A port direction declaration (input/output/inout) names an
            \\identifier that does not appear in the module's port list.
            \\
            \\LRM 6.2 also forbids the reverse mistake: "Ports declared in the
            \\list of port declarations shall not be redeclared within the
            \\body of the module."
            ,
        },
        .E0207 => .{
            .title = "unexpected token",
            .lrm = "A.1.2",
            .explain =
            \\The parser needed one specific token here and found another. The
            \\message names both.
            \\
            \\LRM annex A derives all source "from the starting symbol
            \\source_text" (A.1.2); the token here continues no production the
            \\parser was inside. Which production that was depends on where it
            \\stopped, so the caret says what was expected and, where one
            \\applies, the message names the clause.
            \\
            \\When the expected token is a semicolon or a closing bracket, the
            \\real mistake is usually one construct earlier — look at the end
            \\of the previous statement first.
            ,
        },
        .E0208 => .{
            .title = "expected an identifier",
            .lrm = "2.8",
            .explain =
            \\A declaration or reference needs a name here. LRM 2.8: an
            \\identifier is a letter or underscore followed by letters, digits,
            \\underscores and dollar signs — "The first character of an
            \\identifier shall not be a digit or $".
            \\
            \\A name that must not obey those rules can be written as an
            \\escaped identifier: a backslash, the characters, then whitespace.
            ,
        },
        .E0209 => .{
            .title = "expected an expression",
            .lrm = "A.8.3",
            .explain =
            \\An operand was required here and the token found cannot begin
            \\one. Common causes: a trailing binary operator, an empty pair of
            \\parentheses, or a stray comma in an argument list.
            ,
        },
        .E0210 => .{
            .title = "expected ')'",
            .lrm = "A.8.3",
            .explain = "A parenthesised group or argument list is not closed.",
        },
        .E0211 => .{
            .title = "expected 'potential' or 'flow'",
            .lrm = "3.6.2.1",
            .explain =
            \\A discipline body binds its two natures by name:
            \\
            \\    discipline electrical
            \\      potential Voltage;
            \\      flow      Current;
            \\    enddiscipline
            \\
            \\LRM 3.6.2: "Conservative disciplines shall not have the same
            \\nature specified for both the potential and the flow."
            ,
        },
        .E0212 => .{
            .title = "expected 'continuous' or 'discrete'",
            .lrm = "3.6.2.2",
            .explain =
            \\A discipline's domain binding is one of the two keywords
            \\`continuous` and `discrete`.
            \\
            \\Note that annex C.4 makes `discrete` an error in Verilog-A, and
            \\LRM 3.6.2.2 makes it an error for a discrete discipline to carry
            \\nature bindings at all.
            ,
        },
        .E0213 => .{
            .title = "expected a discipline item",
            .lrm = "3.6.2",
            .explain =
            \\Inside `discipline`/`enddiscipline` the legal items are a domain
            \\binding, a potential binding, a flow binding, and attribute
            \\assignments. LRM 3.6.2 forbids nesting: discipline declarations
            \\do not appear inside another discipline, a nature, or a module.
            ,
        },
        .E0214 => .{
            .title = "expected '<+' or '='",
            .lrm = "5.6",
            .explain =
            \\A statement that begins with an access function must continue as
            \\a contribution (`<+`) or as the left side of an indirect
            \\assignment (`==` inside a `V(a,b) : expr == expr` form).
            \\
            \\Plain `=` assigns to a variable, never to a branch.
            ,
        },
        .E0215 => retiredInfo(
            \\"expected an operand". Retired: a parser-recovery artifact that
            \\named no rule — it fired for ANY token that cannot begin an
            \\operand, and by dying first it made the codes that DO state a
            \\rule unreachable. Its one documented customer was reduction xor,
            \\which A.8.6 now parses so that lowering can report the real
            \\4.2.10/annex-C rule as E0320 (see parseUnary's note and
            \\ch04_expressions/reduction_xor_rejected.va, which pinned the
            \\replacement).
            \\
            \\What replaced it: E0209 for a token that genuinely cannot begin
            \\an expression, E0320/E0416 where this artifact was the accidental
            \\messenger. The number is not reused.
        ),
        .E0216 => .{
            .title = "concatenation operand has no bit width",
            .lrm = "4.2.13",
            .explain =
            \\LRM 4.2.13: "Unsized constant numbers shall not be allowed in
            \\concatenations." A concatenation's result width is the sum of its
            \\operand widths, so every operand must state one.
            \\
            \\Write 8'd5 rather than 5.
            ,
        },
        .E0217 => .{
            .title = "concatenation is wider than an integer",
            .lrm = "3.2.1",
            .explain =
            \\LRM 3.2.1 fixes the Verilog-A `integer` at 32 bits, and a
            \\concatenation evaluates to an integer. A wider result has nowhere
            \\to live.
            ,
        },
        .E0218 => .{
            .title = "port redeclared in the module body",
            .lrm = "6.2",
            .explain =
            \\LRM 6.2: "Ports declared in the list of port declarations shall
            \\not be redeclared within the body of the module."
            \\
            \\Syntax 6-1 gives a module header EITHER a `list_of_ports` (bare
            \\identifiers, whose direction and discipline then arrive in the
            \\body, 6.5.2) OR a `list_of_port_declarations` (direction and
            \\discipline in the header). The two are exclusive:
            \\
            \\    module m(p);                  // body MUST declare p
            \\      inout electrical p;
            \\
            \\    module m(inout electrical p); // body must NOT
            \\
            \\Delete the body line, or strip the header down to the bare name.
            \\
            \\The mirror-image mistake — a direction declaration naming an
            \\identifier that is not a port at all — is E0206.
            ,
        },
        .E0219 => .{
            .title = "a null statement is not an analog statement",
            .lrm = "A.6.4",
            .explain =
            \\Annex G.2.2 NULL: "This statement is no longer supported. Certain
            \\functions such as case, conditionals and the event statement do
            \\allow null statements as defined by the syntax."
            \\
            \\The syntax is where that is normative. A.6.4 lists every
            \\`analog_statement` alternative and none of them is `;`; the null
            \\lives only in
            \\
            \\    analog_statement_or_null ::= analog_statement
            \\                               | { attribute_instance } ;
            \\
            \\which is reached from a conditional arm, a case item and an event
            \\statement — and nowhere else. `analog_seq_block` (A.6.3) takes
            \\`{ analog_statement }` and `analog_construct` (A.6.2) takes one,
            \\so a free-standing `;` in either is underivable. The same holds
            \\in an analog function (A.2.6): its items are declarations and its
            \\body one `analog_function_statement`, and neither has a `;` of its
            \\own, so `input a; ; real a;` is refused too.
            \\
            \\Delete it. A deliberately empty conditional arm keeps its `;`.
            ,
        },
        .E0220 => .{
            .title = "empty analysis list on a step event",
            .lrm = "A.6.5",
            .explain =
            \\A.6.5:
            \\
            \\    analog_event_expression ::= ...
            \\      | initial_step [ ( " analysis_identifier "
            \\                         { , " analysis_identifier " } ) ]
            \\      | final_step   [ ( " analysis_identifier "
            \\                         { , " analysis_identifier " } ) ]
            \\
            \\The list inside the parentheses is non-empty and the whole
            \\parenthesised group is what is optional, so `final_step()` has no
            \\derivation. Annex G Table G.2 item 13 states the same conclusion
            \\directly: "@(final_step) without arguments should not have
            \\parenthesis".
            \\
            \\Drop the parentheses, or name at least one analysis (5.10.2,
            \\Table 5-1: "ac", "dc", "tran", "noise", ...).
            ,
        },
        .E0221 => .{
            .title = "a generate block is not a module item",
            .lrm = "6.6",
            .explain =
            \\Syntax 6-8:
            \\
            \\    generate_region ::= generate { module_or_generate_item }
            \\                        endgenerate
            \\    generate_block  ::= module_or_generate_item
            \\                      | begin [ : generate_block_identifier ]
            \\                          { module_or_generate_item } end
            \\
            \\`generate_block` is reached from exactly two places — the body of
            \\a loop_generate_construct and an arm of a
            \\conditional_generate_construct. It is not itself a
            \\module_or_generate_item, so a naked `begin ... end` has no
            \\derivation either directly in a generate region or at module
            \\scope. 6.6 says the same in prose: a generate region is "a textual
            \\span in the module description where generate constructs may
            \\appear", and a named block on its own is not a generate construct.
            \\
            \\Either give the block the `for` or `if` that generates it, or drop
            \\the `begin`/`end` and write the items directly — 6.6 makes the
            \\region itself optional and imposes no scope of its own.
            ,
        },
        .E0222 => .{
            .title = "discrete bit grouping wider than 31 bits",
            .lrm = "7.3.1",
            .explain =
            \\LRM 7.3.1 Table 7-1, the `bit` row: a discrete bit grouping read
            \\from a continuous context becomes an integer, "the lowest bit of
            \\the bit grouping is mapped to the zeroth bit of the integer", and
            \\"the sign bit (bit 31) of the integer is always set to zero (0)".
            \\
            \\That is why the row ends "access of discrete bit groupings with
            \\greater than 31 bits is illegal": bit 31 of a 32-bit grouping has
            \\nowhere left to land. 31 bits is the widest legal grouping, and it
            \\reads as at most +2147483647.
            \\
            \\The parser checks literal ranges; analog lowering also checks
            \\ranges resolved from parameters before forming the read mask.
            ,
        },

        .E0223 => .{
            .title = "replication count in an assignment pattern is not a non-negative constant",
            .lrm = "4.2.14",
            .explain =
            \\A.8.1's second alternative for an assignment pattern is
            \\
            \\    '{ constant_expression { expression { , expression } } }
            \\
            \\and 4.2.14's own example is `'{ 5{0.0} }`. The count says how many
            \\ELEMENTS the pattern has, so it must fold at elaboration like an
            \\array bound: literals and parameters (3.4), never a variable.
            \\4.2.13 makes a replication count "non-negative, non-x and non-z".
            \\
            \\The CONCATENATION form `{n{...}}` is a different rule: 3.3 Table
            \\3-3 lets its multiplier be nonconstant when the result is a string.
            ,
        },
        // 4.7.1's bullet list, and 4.7.2.2's one sentence about `return`, are
        // four separate rules and four separate codes. They are class 2 and not
        // class 5 for the reason class 2 is named after parser.zig: each is a
        // property of the DECLARATION, and lowering only ever sees a function
        // that is called (4.7.3 inlines at the call site), so a violating
        // function nobody calls would go undiagnosed there.
        .E0224 => .{
            .title = "an analog function declares no formal argument",
            .lrm = "4.7.1",
            .explain =
            \\4.7.1's bullet list, verbatim: an analog function "shall have at
            \\least one input argument declared". A.8.2 says the same from the
            \\call side — `analog_function_call ::= analog_function_identifier
            \\( analog_expression { , analog_expression } )` requires at least
            \\one actual.
            \\
            \\A function of no arguments is a constant. Write a localparam.
            ,
        },
        .E0225 => .{
            .title = "an analog function formal argument has no data type",
            .lrm = "4.7.1",
            .explain =
            \\4.7.1's bullet list, verbatim: "all formal arguments shall have an
            \\associated block item declaration specifying the data type of the
            \\argument".
            \\
            \\    analog function real scale;
            \\      input x;
            \\      real x;        // <- this line
            \\      scale = 2.0 * x;
            \\    endfunction
            \\
            \\The type is a separate item: `input real x;` is no A.2.6
            \\analog_function_item_declaration (E0291).
            \\
            \\4.7.1's "if unspecified, the default is real" does NOT apply here:
            \\that sentence is about `analog_function_type`, the FUNCTION's
            \\return type. The bullet list grants a formal no default, it
            \\requires the declaration.
            ,
        },
        .E0226 => .{
            .title = "a named block is not allowed in an analog function",
            .lrm = "4.7.1",
            .explain =
            \\4.7.1's bullet list, verbatim: an analog function "shall not use
            \\named blocks".
            \\
            \\The hazard is concrete. 4.7.2.1 makes the function's own name an
            \\implicitly declared variable holding the return value, and a named
            \\block (5.3.2) may carry its own declarations — one spelled with the
            \\function's name would shadow the return variable and the function
            \\would hand back the initial 0. The LRM bans the construct rather
            \\than specifying the shadowing.
            \\
            \\Drop the label: an unnamed `begin ... end` is unrestricted.
            ,
        },
        .E0227 => .{
            .title = "a return statement in an analog function specifies no expression",
            .lrm = "4.7.2.2",
            .explain =
            \\4.7.2.2, verbatim: "When the return statement is used, the function
            \\shall specify an expression with the return of the correct type for
            \\the function."
            \\
            \\A bare `return;` specifies none. This is not the same rule as
            \\4.7.2.1's default: that clause covers a function which never
            \\returns explicitly at all and says the result is the identifier
            \\variable's value. An explicit return of nothing is a third thing,
            \\and 4.7.2.2 makes it an error rather than a spelling of the
            \\default.
            \\
            \\Write `return <expr>;`, or assign to the function name and fall off
            \\the end.
            ,
        },
        .E0228 => .{
            .title = "a generate region inside another generate region",
            .lrm = "6.6",
            .explain =
            \\LRM 6.6, verbatim: "Generate regions do not nest, and they may only
            \\occur directly within a module."
            \\
            \\Annex A.4.2 says it a second way, by placement: `generate_region`
            \\is a `module_item`, and `module_or_generate_item` — everything a
            \\region or a generate block may contain — does not list it. So an
            \\inner `generate` has no derivation, whether it sits in another
            \\region or in the block of a for- or if-generate.
            \\
            \\The keywords buy nothing inside: 6.6 makes the region "optional"
            \\with "no semantic difference in the module when a generate region is
            \\used", so drop the inner pair. Generate CONSTRUCTS do nest — "all
            \\other module items, including other generate constructs, are allowed
            \\in a generate block" — it is only the region that may not.
            ,
        },
        .E0229 => .{
            .title = "a parameter declaration inside a generate region or block",
            .lrm = "6.6",
            .explain =
            \\LRM 6.6, verbatim: "A generate block is a collection of one or more
            \\module items. A generate block may not contain port declarations,
            \\parameter declarations, specify blocks, or specparam declarations."
            \\
            \\Syntax 6-8 states it structurally: `module_or_generate_item`
            \\admits `local_parameter_declaration ;` and no
            \\`parameter_declaration`.
            \\
            \\The reason is elaboration order. A parameter is what a generate
            \\scheme is allowed to READ — 6.6's own framing is "the ability for
            \\parameter values to affect the structure of the model" — so a
            \\parameter created BY a generate block is a value the elaborator
            \\needs before it exists. 6.3's override would have nothing to attach
            \\to either.
            \\
            \\Write `localparam` instead. It is the form the grammar keeps,
            \\precisely because it carries no override.
            ,
        },
        .E0230 => .{
            .title = "a generate block name collides with another declaration",
            .lrm = "6.6.1",
            .explain =
            \\A named generate block's name is a DECLARATION, not a label.
            \\
            \\LRM 6.6.1, for a loop generate: "If the generate block is named, it
            \\is a declaration of an array of generate block instances ... It
            \\shall be an error if the name of a generate block instance array
            \\conflicts with any other declaration, including any other generate
            \\block instance array."
            \\
            \\LRM 6.6.2, for a conditional one: "its name declares a generate
            \\block instance and is the name for the scope it creates ... Named
            \\generate blocks may not have the same name as any other declaration
            \\in the same scope. Named generate blocks may not have the same name
            \\as blocks in any other generate construct in the same scope, even
            \\if not selected for instantiation."
            \\
            \\"Even if not selected" is why the scheme is never consulted: the
            \\name is declared by the TEXT of the construct. 6.8 states the same
            \\rule generally and repeats the point — "For generate blocks, this
            \\rule applies regardless of whether the generate block is
            \\instantiated".
            \\
            \\What IS permitted, and is not reported here: two blocks in
            \\different arms of ONE conditional generate construct may share a
            \\name, "since at most one is instantiated" (6.6.2), and that extends
            \\through direct nesting — an `else if` chain.
            \\
            \\Rename the block, or rename the declaration it shadows.
            ,
        },
        .E0231 => .{
            .title = "hierarchical index is not a constant expression",
            .lrm = "A.9.3",
            .explain =
            \\A.9.3: `hierarchical_identifier ::= { identifier [ [
            \\constant_expression ] ] . } identifier` — the bracketed index that
            \\selects one element of an instance array is a CONSTANT expression,
            \\and it sits on a segment followed by `.` (the final identifier
            \\takes none).
            \\
            \\VerA folds the index at parse time, because the whole dotted path
            \\is interned as ONE string (`u[0].g`) — the same spelling
            \\elaboration gives the flattened element — and a value that cannot
            \\be folded has no digits to spell. The parser folds literals and
            \\the +,-,*,/ arithmetic over them; a parameter read is not in that
            \\set, and nothing else the grammar admits here is constant at all.
            ,
        },
        .E0232 => .{
            .title = "library map text in a source file",
            .lrm = "A.1.1",
            .explain =
            \\Annex A's preamble names two starting symbols and says which file
            \\each one is for: "The syntax of Verilog-AMS HDL source is derived
            \\from the starting symbol source_text. The syntax of a library map
            \\file is derived from the starting symbol library_text."
            \\
            \\`library_declaration` and `include_statement` are reachable only
            \\from `library_text` (A.1.1). A `.va` is compiled as `source_text`,
            \\whose A.1.2 `description` list is module_declaration,
            \\udp_declaration, config_declaration, paramset_declaration,
            \\nature_declaration, discipline_declaration and
            \\connectrules_declaration — and neither of those two is in it.
            \\
            \\So this is not a stray token that begins nothing (E0201), and the
            \\text is not malformed. It is the right production in the wrong
            \\file, which is why it has a code of its own: no version of VerA
            \\that grows the analog subset will ever make it legal here.
            \\
            \\A `config_declaration` IS in A.1.2's list and is accepted. The
            \\preprocessor's `` `include `` of 10.3 is a different construct
            \\from A.1.1's bare `include` and is unaffected.
            \\
            \\Library map text goes in a map file: `vera --run --libmap FILE`
            \\(IEEE 1364-2005 13.2.1).
            ,
        },
        .E0233 => .{
            .title = "a UDP table symbol is outside the alphabet its column admits",
            .lrm = "A.5.3",
            .explain =
            \\A.5.3 enumerates the UDP alphabets exhaustively, and they are not
            \\the same on both sides of the colon:
            \\
            \\  output_symbol ::= 0 | 1 | x | X
            \\  level_symbol  ::= 0 | 1 | x | X | ? | b | B
            \\  edge_symbol   ::= r | R | f | F | p | P | n | N | *
            \\  next_state    ::= output_symbol | -
            \\
            \\`z` is in none of them, and that is by design rather than by
            \\omission: a UDP models a logic function, not a connection, so the
            \\whole value set is three-valued. High impedance is what the switch
            \\primitives produce.
            \\
            \\The symbols are CHARACTERS, not identifiers — `(01)` is four of
            \\them and `0 0` is two — so this check runs over the characters of
            \\an entry rather than over its tokens, which in this one region of
            \\the grammar carry no meaning of their own.
            ,
        },
        .E0235 => .{
            .title = "not supported inside a generate block",
            .lrm = "6.6.2",
            .explain =
            \\6.6 says a generate block "brings the objects, behavioral
            \\constructs, and module instances within the block into existence",
            \\and its table of generate kinds says how many times: a loop
            \\generate instantiates its block once per iteration, a conditional
            \\generate (if-generate, case-generate) "at most one generate block
            \\... from a set of alternatives".
            \\
            \\VerA keeps the analog bodies of a generate block under its scheme,
            \\an if-generate's module instances too (each child's analog blocks
            \\run under the scheme that brings it into existence), and the
            \\block's initial/always blocks, continuous assignments, gates and
            \\named events, which the digital engine brings into existence as
            \\the scheme selects. It has no generate scope for a loop or case
            \\generate's analog instance, a defparam, or a task or function.
            \\Moved to the module, each would exist exactly once whatever the
            \\scheme said, so
            \\
            \\    if (use_r) begin res #(.r(2k)) u1(p, n); end
            \\
            \\would stamp u1 with use_r = 0, and an if/else would build both
            \\arms. That is a wrong circuit with no message, so the construct
            \\is refused.
            \\
            \\The source is legal: this is a limitation of VerA, not an error in
            \\the model. Write the instance at module level, or select between
            \\instances with a parameter the child module reads.
            ,
        },
        .E0236 => .{
            .title = "`resetall inside a module",
            .lrm = "10.1",
            .explain =
            \\LRM 10.1 takes `resetall from IEEE Std 1364, whose 19.6 says: "It
            \\shall be illegal for the `resetall directive to be specified within
            \\a module or UDP declaration." It resets every compiler directive to
            \\its default, and a module whose directives change halfway through
            \\has no single reading. 19.6 recommends placing it at the beginning
            \\of each source file; put it before the module.
            ,
        },
        .E0237 => .{
            .title = "a paramset statement uses what 6.4.1 forbids",
            .lrm = "6.4.1",
            .explain =
            \\LRM 6.4.1: "Restrictions on statements in a paramset are similar
            \\to those for analog functions. Specifically, a paramset: ...
            \\Shall not use access functions. Shall not use contribution
            \\statements or event control statements. Shall not use named
            \\blocks."
            \\
            \\A paramset is a bundle of parameter values evaluated once per
            \\instance at elaboration; it has no circuit to probe or drive and
            \\no time to wait on. Compute what the statement needs from the
            \\paramset's parameters, and drop the block's label:
            \\
            \\    begin : blk  t = rr; end     // illegal
            \\    begin        t = rr; end     // legal
            ,
        },
        .E0238 => .{
            .title = "a loop generate's index is not a genvar",
            .lrm = "A.4.2",
            .explain =
            \\A.4.2: `loop_generate_construct ::= for ( genvar_initialization ;
            \\genvar_expression ; genvar_iteration ) generate_block`, with
            \\`genvar_initialization ::= genvar_identifier =
            \\constant_expression`. The index is a genvar, the name a
            \\`genvar_declaration` introduces: an integer that exists only
            \\while the loop is unrolled at elaboration, never at run time.
            \\An `integer` or `real` variable is not one, even with the same
            \\name.
            \\
            \\    genvar i;
            \\    for (i = 0; i < 2; i = i + 1) begin : g ... end
            ,
        },
        .E0239 => .{
            .title = "a UDP instance's delay is more than a delay2",
            .lrm = "A.5.4",
            .explain =
            \\A.5.4: `udp_instantiation ::= udp_identifier [ drive_strength ]
            \\[ delay2 ] udp_instance { , udp_instance } ;`, and A.2.2.3:
            \\`delay2 ::= # delay_value | # ( mintypmax_expression [ ,
            \\mintypmax_expression ] )`. A UDP has one output that is never
            \\high impedance, so it takes a rise and a fall delay and no
            \\turn-off delay: at most two values, written in order.
            \\
            \\    my_udp #(1, 2) u (o, a);      // rise 1, fall 2
            \\    my_udp #(1, 2, 3) u (o, a);   // error: three values
            \\
            \\A named `.x(…)` override is not a delay at all: a UDP has no
            \\parameters to override.
            ,
        },
        .E0240 => .{
            .title = "not a module item",
            .lrm = "A.1.4",
            .explain =
            \\The text here begins none of A.1.4's `module_item` alternatives:
            \\port, parameter, net, variable, branch and function declarations,
            \\instances, generate constructs, `analog`/`initial`/`always`
            \\blocks, continuous assignments, gates, specify blocks. It is a
            \\syntax error, not a feature this compiler lacks — compare E0205,
            \\which is a derivable item VerA does not implement.
            \\
            \\Common causes: a `nature` or `discipline` declared inside a
            \\module (both are descriptions of the file, A.1.2), text left over
            \\from a comment that was closed early, a statement written outside
            \\the analog block, or a keyword in upper case.
            ,
        },
        .E0246 => .{
            .title = "invalid module parameter list",
            .lrm = "A.1.3 / A.4.1",
            .explain =
            \\A.1.3 requires at least one parameter declaration in a module's
            \\#(...) header. The declaration starts with `parameter`;
            \\`localparam` belongs in the module body. Omit the whole #(...)
            \\header when the module declares no header parameters.
            \\
            \\A.4.1 likewise requires at least one ordered expression or
            \\named assignment in an instance's #(...). All assignments in
            \\that list use the same form (IEEE 1364-2005 12.2.2). Omit the
            \\whole list to use defaults, or use a named empty value, .P(),
            \\to retain that parameter's default. An empty port list () is
            \\independent of these parameter-list requirements and is legal.
            ,
        },
        .E0247 => .{
            .title = "a scale factor in a digital delay",
            .lrm = "2.6.2",
            .explain =
            \\Verilog-AMS 2.6.2 permits scaled real constants in expressions,
            \\but forbids scale factors when defining digital delays. This
            \\includes delay controls, net and primitive delays, continuous
            \\assignment delays, and module path delays, whether the scaled
            \\literal stands alone or inside a compound delay expression.
            \\
            \\Write digital delays in the module's `timescale units, using
            \\an integer, decimal or scientific value. With `timescale 1ns/1ps,
            \\a five-microsecond delay is #5000 or #5e3, never #5u.
            ,
        },
        .E0248 => .{
            .title = "a UDP table gives one input combination two outputs",
            .lrm = "IEEE 1364-2005 8.1.4",
            .explain =
            \\IEEE 1364-2005 8.1.4: "It is illegal to have the same combination
            \\of inputs, including edges, specified for different outputs."
            \\
            \\A symbol stands for every value it covers (`?` is 0, 1 and x; `b`
            \\is 0 and 1; `p` is (01), (0x) and (x1), per Table 8-1), so two
            \\entries share a combination wherever each column, and a sequential
            \\entry's current state, covers a common value. They conflict when
            \\the next states differ there, `-` reading as the current state:
            \\
            \\    0 ? : 1 ;
            \\    0 0 : 0 ;   // 0 0 is specified for both 1 and 0
            \\
            \\Narrow one entry so the sets no longer meet (`0 1 : 1 ;`), or give
            \\both the same output. A level-sensitive entry overlapping an
            \\edge-sensitive one is not a conflict: 8.8 makes the level entry
            \\dominate.
            ,
        },
        .E0258 => .{
            .title = "a procedural continuous assignment in an analog block",
            .lrm = "A.6.2",
            .explain =
            \\A.6.2 `procedural_continuous_assignments` (`assign`, `deassign`,
            \\`force`, `release`; IEEE 1364-2005 9.3) is an alternative of the
            \\digital A.6.4 `statement` only. None of the eleven alternatives of
            \\`analog_statement` derives it: an analog variable has no driver for
            \\a continuous assignment to override.
            \\
            \\Use an ordinary procedural assignment (`x = 1.0;`), or move the
            \\statement into an `initial` or `always` block, where it is legal.
            ,
        },
        .E0249 => .{
            .title = "a fork-join block in an analog block",
            .lrm = "A.6.3",
            .explain =
            \\A.6.3 `par_block ::= fork ... join` is an alternative of the
            \\digital A.6.4 `statement`. `analog_statement` offers only
            \\`analog_seq_block` (begin/end) in that slot: the analog block is
            \\one ordered evaluation (5.2), with no concurrent processes for a
            \\fork to start.
            \\
            \\Use `begin ... end`, or move the block into an `initial` or
            \\`always` block.
            ,
        },
        .E0250 => .{
            .title = "a construct outside the Verilog-A subset",
            .lrm = "C.7",
            .explain =
            \\`vera --sim=verilogA` compiles the analog language subset annex C
            \\defines, Verilog-A: Verilog-AMS without its digital and
            \\mixed-signal halves. This construct is one the annex removes:
            \\
            \\  - C.4: a `discrete` domain binding, a `wreal` net, or the
            \\    `default_discipline directive;
            \\  - C.5: the case equality operators `===` and `!==`;
            \\  - C.7: digital behavior (an `initial` or `always` block, a
            \\    continuous `assign`, a gate, switch or pull instance, a
            \\    `reg`, a `task` or a digital `function`) and `casex`/`casez`;
            \\  - C.9 and C.16: the mixed-signal descriptions `connectmodule`
            \\    and `connectrules`, and IEEE 1364's `primitive`, `specify`,
            \\    `config` and `library`.
            \\
            \\Compile the model as Verilog-AMS (the default, --sim=verilogAMS)
            \\or remove the construct. Each one is parsed past, so one error
            \\names each.
            ,
        },
        .E0254 => .{
            .title = "a delay control in an analog block",
            .lrm = "A.6.5",
            .explain =
            \\A.6.5 `delay_control ::= # delay_value | # ( mintypmax_expression )`
            \\reaches A.6.4 only through the digital `statement`'s
            \\`procedural_timing_control_statement`. `analog_statement` derives
            \\no `#`: analog time advances by the solver's step control (5.2),
            \\not by a delay in the statement stream.
            \\
            \\Schedule the change with `@(timer(t))` (5.10.3.3), shape it with
            \\`transition` or `absdelay`, or move the statement into an
            \\`initial` or `always` block.
            ,
        },
        .E0255 => .{
            .title = "a wait statement in an analog block",
            .lrm = "A.6.5",
            .explain =
            \\A.6.5 `wait_statement ::= wait ( expression ) statement_or_null`
            \\is a `procedural_timing_control_statement`, which A.6.4 lists under
            \\the digital `statement` only. The analog block is evaluated at every
            \\solution point (5.2) and has no thread to suspend on a level.
            \\
            \\Detect the condition with `@(cross(...))` or `@(above(...))`
            \\(5.10.3), or move the statement into an `always` block.
            ,
        },
        .E0256 => .{
            .title = "a forever loop in an analog block",
            .lrm = "A.6.8",
            .explain =
            \\A.6.8's `analog_loop_statement` is `repeat | while | for`; only the
            \\digital `loop_statement` has `forever`, and A.6.4's
            \\`analog_statement` never reaches it. Annex G.2.1 records the
            \\retirement: "This statement is no longer supported."
            \\
            \\The analog block already runs at every solution point (5.2), so
            \\write its body without the loop. In an `initial` or `always`
            \\block `forever` is legal (IEEE 1364-2005 9.6).
            ,
        },
        .E0257 => .{
            .title = "a charge strength on a net that is not a trireg",
            .lrm = "A.2.1.3",
            .explain =
            \\A.2.1.3 gives `charge_strength ::= ( small ) | ( medium ) | ( large )`
            \\to the `trireg` alternatives of `net_declaration` only (IEEE
            \\1364-2005 4.4.1: a charge strength is the size of a trireg's
            \\capacitance). Any other net type has no stored charge for the
            \\strength to describe, so `wire (small) w;` derives from nothing.
            \\
            \\Declare the net `trireg`, or drop the strength.
            ,
        },
        .E0245 => .{
            .title = "a specify block breaks a clause 14 rule",
            .lrm = "IEEE 1364-2005 14.2",
            .explain =
            \\IEEE 1364-2005 clause 14 constrains where a specify block stands
            \\(14.1: "inside a module declaration") and what its module paths
            \\may say, beyond what annex A.7 parses:
            \\
            \\  - 14.2.1: a source is an input or inout port, a destination an
            \\    output or inout port with only one driver inside the module;
            \\  - 14.2.3: a parallel edge-sensitive path ends at a scalar port
            \\    or a bit-select; Syntax 14-4 puts its polarity after the
            \\    destination, not before `=>`;
            \\  - 14.2.4: `ifnone` takes a simple path; Table 14-1 lists the
            \\    only operators a condition may use; 14.2.4.3 references a
            \\    port the same way in every declaration of one edge-sensitive
            \\    path; 14.2.4.4 forbids `ifnone` and an unconditional path for
            \\    the same module path;
            \\  - 14.2.5: a parallel path joins terminals of the same width;
            \\  - 14.3: a path delay is a constant expression.
            \\
            \\The message names the rule the path breaks.
            ,
        },
        .E0242 => .{
            .title = "a Verilog-AMS construct under an IEEE 1364 language",
            .lrm = "10.6",
            .explain =
            \\`vera --std=1364-1995|1364-2001|1364-2005` compiles plain IEEE
            \\1364 Verilog. That makes the 1364 set the "implementation's
            \\default set of reserved keywords" of LRM 10.6, so every Verilog-AMS
            \\keyword -- `analog`, `discipline`, `ddt`, `sin` ... -- is an
            \\ordinary identifier:
            \\
            \\    reg [3:0] analog;      // legal under --std=1364-2005
            \\
            \\It also means the language has no Verilog-AMS construct. IEEE
            \\1364-2005 annex A has no production for an `analog` block, a
            \\`discipline`, a `nature`, a `branch`, a `paramset` or the rest,
            \\so one of those opening a description or a module item is this
            \\error rather than a confusing syntax error further on.
            \\
            \\Compile Verilog-AMS with the default --std=VAMS-2023. A
            \\`begin_keywords "1364-2005" region inside a Verilog-AMS source is
            \\different: LRM 10.6 says it changes only which words are reserved,
            \\so `analog` still opens an analog block there.
            ,
        },
        .E0241 => .{
            .title = "nested deeper than memory allows",
            .lrm = "",
            .explain =
            \\Out of memory, not a language rule: VerA sets no nesting limit.
            \\The parser and every later stage read nested parentheses, unary
            \\and conditional operators, operator chains, statements and
            \\generate blocks by recursion, on a stack reserved for the depth
            \\the source reaches (`deep_stack`). A chain of binary operators
            \\counts one level per operator: `a + b + c` is two levels deep,
            \\because every later stage walks the tree it builds.
            \\
            \\This error says the operating system refused that reservation
            \\(or, on Windows, the depth needs a stack of 4 GiB or more,
            \\which one thread there cannot have); the message names the
            \\depth. Split the expression through intermediate variables, or
            \\flatten the nested `begin` blocks, or give the process more
            \\memory.
            ,
        },
        .E0243 => .{
            .title = "a configuration rule IEEE 1364-2005 §13.3 forbids",
            .lrm = "IEEE 1364-2005 13.3",
            .explain =
            \\A configuration parses (A.1.5) and still breaks a rule clause 13
            \\states in prose:
            \\
            \\  13.3.1.2  "there cannot be more than one default clause that
            \\            specifies the expansion clause": two `default liblist`.
            \\  13.3.1.4  "It is an error if a library name is included in a
            \\            cell selection clause and the corresponding expansion
            \\            clause is a library list expansion clause":
            \\            `cell lib.c liblist ...`.
            \\  13.3.2    "It shall be an error for an instance clause to specify
            \\            a hierarchical path to an instance that occurs within a
            \\            hierarchy specified by another config."
            \\  13.3.1.1  "The cell or cells identified cannot be configurations
            \\            themselves."
            \\
            \\and, for a file holding several configurations, the one that
            \\configures the design is the one no `use` clause names; more than
            \\one such configuration leaves the design unnamed (13.4.4).
            ,
        },
        .E0244 => .{
            .title = "library map refused",
            .lrm = "IEEE 1364-2005 13.2",
            .explain =
            \\`vera --libmap FILE` reads an IEEE 1364-2005 13.2 library map, and
            \\`-L LIB` names the library search order (13.7.1). Refused:
            \\
            \\  - text other than `library` and `include` statements and
            \\    comments (13.2.2: "The syntax of a lib.map file is limited to
            \\    library specifications, include statements, and standard
            \\    Verilog comment syntax");
            \\  - a `library` naming no file_path_spec (Syntax 13-2);
            \\  - a map file that cannot be read, `include`d or given;
            \\  - a source file matching the path specifications of two
            \\    libraries after 13.2.1.1's resolution order ("it shall be an
            \\    error");
            \\  - `-L` naming a library no map declares (13.7.1: "with the
            \\    definitions of these libraries to be taken from the library
            \\    map file").
            \\
            \\A file no specification matches is compiled into `work` (13.2.1).
            \\A library's `-incdir` paths join the include search path of every
            \\file, not only that library's.
            ,
        },
        .E0297 => .{
            .title = "paramset declares no item",
            .lrm = "A.1.9",
            .explain =
            \\Syntax 6-4 / A.1.9 open every paramset body with
            \\
            \\    paramset_item_declaration { paramset_item_declaration }
            \\
            \\so a paramset declares at least one parameter, local parameter,
            \\aliasparam, integer or real before its statements. A body of
            \\`.name = value;` statements alone is not a paramset_declaration.
            \\Declare the parameter the statements are written in terms of, or
            \\any one parameter, e.g. `parameter real unused_item = 0;`.
            ,
        },
        .E0295 => .{
            .title = "a min:typ:max expression is not an analog expression",
            .lrm = "A.8.4",
            .explain =
            \\IEEE 1364-2005 5.3's `( min : typ : max )` is a primary of a digital
            \\or constant expression only:
            \\
            \\    primary          ::= ... | ( mintypmax_expression )
            \\    constant_primary ::= ... | ( constant_mintypmax_expression )
            \\    analog_primary   ::= ... | ( analog_expression )
            \\
            \\An analog block's statements and an analog function's body are
            \\written in analog_expression (A.6.4, A.8.3), whose parenthesised
            \\primary holds one expression. A parameter default keeps the form
            \\anywhere, analog blocks included, as A.2.4's param_assignment
            \\takes a constant_mintypmax_expression:
            \\
            \\    parameter real td = 1.0 : 2.0 : 3.0;   // typical, 2.0
            \\    analog V(out) <+ td * V(in);
            ,
        },
        .E0296 => .{
            .title = "a forever loop needs a statement, not a null statement",
            .lrm = "A.6.8",
            .explain =
            \\A.6.8 gives the digital loop exactly one body:
            \\
            \\    loop_statement ::= forever statement | ...
            \\
            \\and `statement` has no null alternative — the null lives in
            \\`statement_or_null`, which A.6.8 does not name. So `forever ;` is
            \\not derivable. It would also never end: a forever whose body
            \\cannot suspend runs the process at one simulation time for ever.
            \\
            \\Give it a body with a timing control, e.g.
            \\
            \\    initial forever #5 clk = ~clk;
            \\
            \\The analog `forever` is a different error (E0256): annex G.2.1
            \\retired it, and A.6.8's `analog_loop_statement` has no forever arm.
            ,
        },
        .E0289 => .{
            .title = "a function call has an empty argument",
            .lrm = "A.8.2",
            .explain =
            \\A.8.2 writes every user function call with at least one argument
            \\and no empty slot:
            \\
            \\    analog_function_call ::= analog_function_identifier
            \\        { attribute_instance } ( analog_expression { , analog_expression } )
            \\    function_call ::= hierarchical_function_identifier
            \\        { attribute_instance } ( expression { , expression } )
            \\
            \\so `f(, 1.0)`, `f(1.0, )` and, in an analog expression, `f()` derive
            \\from nothing. Only a system function (`$f(a, , c)`, whose clause
            \\says what the empty slot means) and the slots A.6.5 and A.8.2 mark
            \\`_or_null` take one. A name that is not a declared access function
            \\is read as a user function, so `Vp(, n)` (a missing `(` after `V`)
            \\lands here too: write `V(p, n)`.
            \\
            \\A task enable, `t(a, );`, is A.6.9's task_enable, whose null
            \\argument IEEE 1364-2005 10.2.2 forbids in its own words ("A null
            \\expression shall not be used as an argument in a task-enabling
            \\statement"); the digital engine refuses it there, not here.
            ,
        },
        .E0290 => .{
            .title = "a declaration in an unnamed block",
            .lrm = "A.6.3",
            .explain =
            \\A.6.3 puts a block's declarations inside the bracket that opens
            \\with its name:
            \\
            \\    analog_seq_block ::= begin [ : analog_block_identifier
            \\        { analog_block_item_declaration } ] { analog_statement } end
            \\    seq_block ::= begin [ : block_identifier
            \\        { block_item_declaration } ] { statement } end
            \\
            \\so only a named block declares anything. Name the block, or move
            \\the declaration to the module:
            \\
            \\    analog begin : body
            \\        real x;
            \\        ...
            \\
            \\An analog function's body declares nothing in a block at all: its
            \\locals are function items (A.2.6), and 4.7.1 forbids the name a
            \\block would need (E0226).
            ,
        },
        .E0291 => .{
            .title = "an analog function's direction declaration carries a data type",
            .lrm = "A.2.6",
            .explain =
            \\An analog function declares a formal's direction and its type in
            \\two items (A.2.6, A.2.1.2):
            \\
            \\    analog_function_item_declaration ::= analog_block_item_declaration
            \\        | input_declaration ; | output_declaration ; | inout_declaration ;
            \\    input_declaration ::= input [ discipline_identifier ]
            \\        [ net_type | wreal ] [ signed ] [ range ] list_of_port_identifiers
            \\
            \\and 4.7.1 says the same in words: "all formal arguments shall have an
            \\associated block item declaration specifying the data type". So
            \\`input real x;` is not an analog function item; write
            \\
            \\    input x;
            \\    real x;
            \\
            \\`output integer x;` is the one typed direction A.2.1.2 derives
            \\(`output output_variable_type`). A digital `function` or `task`
            \\takes IEEE 1364-2005's `tf_input_declaration`, where `input real x`
            \\is legal.
            ,
        },
        .E0292 => .{
            .title = "a net declaration mixes initialized and plain names",
            .lrm = "A.2.1.3",
            .explain =
            \\A.2.1.3 gives a net declaration either a list of names or a list
            \\of assignments, never both:
            \\
            \\    net_declaration ::= ...
            \\        | discipline_identifier [ range ] list_of_net_identifiers ;
            \\        | discipline_identifier [ range ] list_of_net_decl_assignments ;
            \\    list_of_net_decl_assignments ::=
            \\        net_decl_assignment { , net_decl_assignment }
            \\    net_decl_assignment ::= ams_net_identifier = expression
            \\
            \\(A.2.3), and so does every net type alternative. `electrical p =
            \\1.5, n;` is neither list; split it:
            \\
            \\    electrical p = 1.5;
            \\    electrical n;
            ,
        },
        .E0293 => .{
            .title = "a module instance has no instance name",
            .lrm = "A.4.1",
            .explain =
            \\A.4.1 names every module instance:
            \\
            \\    module_instance ::=
            \\        name_of_module_instance ( [ list_of_port_connections ] )
            \\    name_of_module_instance ::= module_instance_identifier [ range ]
            \\
            \\The only instance A.5.4 lets go unnamed is a UDP's, which connects
            \\an output and at least one input:
            \\
            \\    udp_instance ::= [ name_of_udp_instance ]
            \\        ( output_terminal , input_terminal { , input_terminal } )
            \\
            \\so `child(s);` is neither. Name the instance: `child c1(s);`.
            ,
        },
        .E0234 => .{
            .title = "a UDP table does not derive from one udp_body",
            .lrm = "A.5.3",
            .explain =
            \\A.5.3 splits the two bodies at the top and never lets them mix:
            \\
            \\  udp_body ::= combinational_body | sequential_body
            \\  combinational_entry ::= level_input_list : output_symbol ;
            \\  sequential_entry ::= seq_input_list : current_state : next_state ;
            \\
            \\So an entry has one colon or two, and every entry of one table has
            \\the same count: a `current_state` column exists in a sequential
            \\body and nowhere else.
            \\
            \\An edge indicator is the other half of the split. `edge_indicator`
            \\and `edge_symbol` appear only under `edge_input_list`, which only a
            \\`sequential_entry` can reach, and `level_symbol` has no edge
            \\alternative. The grammar is stating a semantic impossibility: an
            \\edge is a claim about an input's PREVIOUS value, and a
            \\combinational UDP has no state for a previous value to live in.
            \\
            \\A compiler that accepts an edge in a combinational table has
            \\either promoted the primitive to sequential — inventing state the
            \\source never declared — or is matching `(01)` as a level, which
            \\changes the function.
            ,
        },
        .W0250 => .{
            .title = "switch primitive accepted, and it stamps nothing",
            .lrm = "A.3.1",
            .explain =
            \\A.3.4's ten switch spellings — `cmos`/`rcmos`, `nmos`/`pmos`/
            \\`rnmos`/`rpmos`, `tran`/`rtran`, `tranif0`/`tranif1`/`rtranif0`/
            \\`rtranif1` — open four of A.3.1's nine `gate_instantiation` arms,
            \\and the source is legal: A.1.4 makes `gate_instantiation` a
            \\module_or_generate_item, so the module around it compiles and its
            \\analog block runs.
            \\
            \\(This note used to read A.4.1. A.4.1 is `module_instantiation`;
            \\the annex prints every switch arm under "A.3.1 Primitive
            \\instantiation and instances", which is where W0252 already
            \\pointed for the gate arms of the same production.)
            \\
            \\What the instance does NOT do is contribute to the device. LRM
            \\8.5.3.5 puts switch processing in the DISCRETE simulation cycle: a
            \\switch propagates logic values and strengths between its
            \\terminals, and the LRM gives it no continuous behavior at all. So
            \\there is no equation to stamp, and writing one anyway — a zero-volt
            \\source across the terminals is the obvious guess — would freeze a
            \\convention of VerA's into a model as if the standard had asked for
            \\it.
            \\
            \\This warning exists because the other option is worse. Dropping the
            \\instance in silence gives you a device in which the two nets the
            \\switch was meant to tie are simply unconnected, and nothing in the
            \\output says so.
            \\
            \\  --deny=W0250    refuse the module instead, for a model whose
            \\                  answer depends on the switch conducting
            \\  --allow=W0250   silence it, for a switch that only matters to the
            \\                  digital half a host simulator runs
            \\
            \\The rest of A.3.1's gate types are W0252, which says the same
            \\thing about a primitive that COMPUTES a value rather than one that
            \\merely connects. They used to be E0205 on the ground that the two
            \\cases differ in kind; they do not, and both are now accepted out
            \\loud. See that entry.
            \\
            \\NOT REPORTED under `--run`, where the discrete engine runs the
            \\switch for real: IEEE 1364-2005 §7.6/§7.7 conduction, §7.11/§7.12
            \\strength reduction and the bidirectional flow of a pass switch.
            ,
        },
        .W0252 => .{
            .title = "gate primitive accepted, and it computes nothing",
            .lrm = "A.3.1",
            .explain =
            \\A.3.1's `gate_instantiation`, in a design element being compiled
            \\to an analog device. The source is legal — A.1.4 makes a gate
            \\instantiation a module_or_generate_item, and 1.1 makes "the
            \\complete IEEE Std 1364 Verilog specification" part of Verilog-AMS
            \\HDL — so the module around it compiles and its analog block runs.
            \\
            \\What the instance does NOT do is reach the device. 8.5.3.5 puts
            \\gate-level modeling in the event-driven half of the language: "The
            \\event-driven simulation algorithm described in 11 of IEEE Std 1364
            \\Verilog depends on unidirectional signal flow and can process each
            \\event independently. The inputs are read, the result is computed,
            \\and the update is scheduled. The IEEE Std 1364 Verilog provides
            \\switch-level modeling in addition to behavioral and gate-level
            \\modeling." A compiled analog device has no event queue to schedule
            \\that update on, so the gate's output net keeps whatever the
            \\continuous solver gives it and the gate contributes nothing.
            \\
            \\NOT REPORTED under `--run`, where the discrete engine executes the
            \\gate for real. This is a fact about the artifact being built, not
            \\about the source.
            \\
            \\Same shape as W0250 and the same reasoning: silence is worse. A
            \\dropped gate leaves a design whose output net is simply undriven,
            \\with nothing in the output saying the driver was discarded.
            \\
            \\  --deny=W0252    refuse the module instead, for a model whose
            \\                  answer depends on the gate driving its output
            \\  --allow=W0252   silence it, for a cell whose gates only matter to
            \\                  the digital half a host simulator runs
            \\
            \\A.5.4's `udp_instantiation` is reported here too. A UDP is a
            \\primitive whose function is a table (A.5.3) rather than a keyword,
            \\and the table is a logic function for the same event queue.
            ,
        },
        .W0253 => .{
            .title = "configuration read, and nothing binds through it",
            .lrm = "A.1.5",
            .explain =
            \\A.1.2 puts `config_declaration` in its `description` list, so a
            \\configuration in a source file is derivable from `source_text` and
            \\is not library map text (which is E0232 — a different starting
            \\symbol and a different kind of file).
            \\
            \\What a configuration does is bind an instance to a CELL of a
            \\LIBRARY, at elaboration, through the map its `liblist` and `use`
            \\clauses name. A digital run (`vera --run`/`--emit-exe` on a .v)
            \\binds through it (IEEE 1364-2005 13.3). An analog compile does
            \\not: an instance resolves to a module declared in the source it
            \\was given, by name, so the `design` statement selects nothing,
            \\every `config_rule_statement` below it applies to nothing, and
            \\the elaborated design is exactly what it would have been with the
            \\configuration deleted.
            \\
            \\Same call as W0250 and W0251: silence would be worse, because a
            \\configuration exists precisely to make one instance resolve
            \\differently from the default, and a discarded one leaves the
            \\default in place with nothing in the output saying so.
            \\
            \\  --deny=W0253    refuse the file instead, for a design whose
            \\                  answer depends on the configuration selecting
            \\  --allow=W0253   silence it, for a configuration carried in the
            \\                  source for a downstream tool to read
            ,
        },
        .W0251 => .{
            .title = "specify block read, and part or all of it is not modelled",
            .lrm = "A.7.1",
            .explain =
            \\A.7.1 `specify_block ::= specify { specify_item } endspecify`, and
            \\1.1 — "Verilog-AMS HDL consists of the complete IEEE Std 1364
            \\Verilog specification" — makes it legal source. Annex C.16 does not
            \\exempt it either: `specify` is not among the keywords that clause
            \\lists as unused by Verilog-A.
            \\
            \\So the block is PARSED, not skipped: every `specify_item` arm is
            \\read against its own production, which is why a malformed path or
            \\a timing check of the wrong arity is still an error inside one.
            \\
            \\What the block does NOT do is reach the device. Its whole content
            \\is timing — A.7.2 path delays, A.7.5 system timing checks — and 8
            \\puts all of it in the discrete simulation cycle. A compiled analog
            \\device has no event queue for a path delay to schedule on and no
            \\clock for a $setup to measure against, so there is nothing to
            \\stamp; inventing one would freeze a convention of VerA's into a
            \\model as if the standard had asked for it.
            \\
            \\Same shape as W0250, and for the same reason: dropping it in
            \\silence gives you a cell whose timing the compiler discarded with
            \\nothing in the output saying so.
            \\
            \\A digital run (`vera --run` of a `.v`) is the exception: its event
            \\queue evaluates the timing checks (IEEE 1364-2005 clause 15,
            \\lib/sim/digital/tchk.zig), reporting each violation (W1199) or
            \\refusing a form it does not run (E1149), and applies the module
            \\path delays (14.2-14.4: simple, edge-sensitive and state-dependent
            \\paths, `ifnone`, 1/2/3/6/12 delays, chosen per 14.3.3 when the
            \\destination is scheduled to change). There the warning is only for
            \\the 14.6 pulse controls (pulsestyle, showcancelled, PATHPULSE$),
            \\which are ignored: 14.6's default pulse handling applies instead,
            \\inertial, with the reject and error limits equal to the path delay.
            \\A block without pulse controls raises none. The same engine runs
            \\the digital half of a mixed-signal design and evaluates its timing
            \\checks too, refusing the forms E1149 lists; the analog compile
            \\still names every check, since the analog solver evaluates none.
            \\
            \\  --deny=W0251    refuse the module instead, for a design whose
            \\                  answer depends on the timing being honoured
            \\  --allow=W0251   silence it, for a cell whose specify section only
            \\                  matters to the digital half a host simulator runs
            \\
            \\A `specparam` is not this warning, written as a MODULE item (A.2.1.1,
            \\Syntax 6-1's `non_port_module_item`) or inside the block: it is a
            \\constant declaration with a default, and it elaborates as one
            \\(IEEE 1364-2005 4.10.3 lets the module body read a specparam the
            \\block declares).
            ,
        },

        // ------------------------------------------------------------ class 3
        .E0301, .E0302 => retiredInfo(
            \\"vector ports are not supported" (E0301) and "vector nets are not
            \\supported" (E0302). Both retired: 3.6.3 vector nets and 6.5.2
            \\vector ports now elaborate. Each element becomes its own solver
            \\unknown, named `p[0]`, so the flat node list never learns about
            \\ranges and nothing downstream changed.
            \\
            \\What replaced them: E0350 for 6.5.2.2 (the port's two declarations
            \\give different ranges), E0351 and E0352 for the element reference
            \\itself. The numbers are not reused.
        ),
        .E0303 => .{
            .title = "aliasparam target is not a parameter",
            .lrm = "3.4.7",
            .explain =
            \\`aliasparam` gives a second name to an existing parameter, so its
            \\target must be a parameter declared in the same module.
            \\
            \\LRM 3.4.7 adds two rules worth knowing: the alias identifier
            \\"shall not occur anywhere else in the module", and it is an error
            \\to override one parameter through both its original name and an
            \\alias.
            ,
        },
        .E0304, .E0305 => retiredInfo(
            \\"port branches are not supported" (E0304) and "branch arrays are
            \\not supported" (E0305). Both retired: 3.12.1 `branch (<p>) name;`
            \\resolves to the same 5.4.3 port-flow unknown `I(<p>)` reads, and
            \\A.2.3 `branch (p, n) pair[0:1];` expands into one branch per
            \\element registered under the scalarised name `pair[k]`.
            \\
            \\What replaced them: nothing for the declarations, which are legal.
            \\A port branch left of `<+` is E0407 (5.4.3 forbids the position,
            \\not the name); an out-of-range element is E0352 and the bare base
            \\name is E0351, both shared with vector nets.
        ),
        .E0306 => .{
            .title = "expected a net identifier",
            .lrm = "3.12",
            .explain =
            \\A branch declaration names one or two nets:
            \\
            \\    branch (a, b) ab;      // between two nets
            \\    branch (a)    a_gnd;   // net to ground
            \\
            \\Expressions, constants and ports-by-index are not net names.
            ,
        },
        .E0307 => .{
            .title = "array has no declared dimensions",
            .lrm = "3.2",
            .explain =
            \\An array needs at least one declared range. VerA supports
            \\multiple dimensions; this diagnostic reports missing dimensions
            \\where array storage was required.
            ,
        },
        .E0308 => .{
            .title = "array bound is not a constant expression",
            .lrm = "3.2",
            .explain =
            \\LRM 3.2 requires both bounds of an array declaration to be
            \\constant expressions. They may depend on parameters, but not
            \\on variables or probes. This rule concerns the declared range,
            \\not an index used to read or write an element at runtime.
            ,
        },
        .E0309 => .{
            .title = "identifier is not an array",
            .lrm = "3.2",
            .explain =
            \\This name was indexed with `[...]` but was declared as a scalar.
            \\Check for a shadowing declaration in an inner block.
            ,
        },
        .E0310 => .{
            .title = "array index is out of bounds",
            .lrm = "3.2",
            .explain =
            \\This constant index lies outside the declared range. VerA
            \\diagnoses an out-of-range index when it can resolve that index
            \\at compile time. Array accesses may also use runtime indices;
            \\this diagnostic does not require every index to be constant.
            ,
        },
        .E0311 => .{
            .title = "array index is not a constant expression",
            .lrm = "3.2",
            .explain =
            \\This use of an array element as a target requires a constant
            \\index in VerA. Other array reads and assignments support runtime
            \\indices. This restriction is separate from LRM 3.2's requirement
            \\that the bounds in an array declaration be constant.
            \\
            \\A genvar index works: genvar loops are unrolled (LRM 6.6.1), so
            \\the index is constant in each unrolled copy.
            ,
        },
        .E0312 => .{
            .title = "cannot assign to a parameter",
            .lrm = "3.4",
            .explain =
            \\Parameters are constants of an instance: they are set by the
            \\model card or by a defparam before the analog block runs, and
            \\stay fixed for the whole solve.
            \\
            \\Declare a `real` or `integer` variable for a value that changes.
            ,
        },
        .E0313 => .{
            .title = "unknown variable",
            .lrm = "6.8",
            .explain =
            \\No variable, parameter or genvar with this name is visible here.
            \\Verilog-A scopes are lexical: a name declared inside a named
            \\block (LRM 5.3.2) is not visible outside it.
            ,
        },
        .E0314 => .{
            .title = "unknown identifier",
            .lrm = "6.8",
            .explain =
            \\Nothing with this name is declared in scope — not a variable, a
            \\parameter, a net, a branch, a discipline, or a function.
            ,
        },
        .E0315 => .{
            .title = "net must be read through an access function",
            .lrm = "4.4",
            .explain =
            \\A net names a point in a conservative system, not a number. Ask
            \\for one of its two signals explicitly:
            \\
            \\    V(n)      potential of n relative to ground
            \\    V(a, b)   potential across the branch a-b
            \\    I(a, b)   flow through the branch a-b
            \\
            \\LRM 4.4 also forbids `V(n1, n1)`: a flow access whose two net
            \\expressions name the same signal has no branch to flow through.
            ,
        },
        .E0316 => .{
            .title = "unsupported assignment target",
            .lrm = "5.7",
            .explain =
            \\LRM 5.7: "The left-hand side of a procedural assignment shall be
            \\scalar" — a variable, or one element of a scalarized array.
            ,
        },
        .E0317 => .{
            .title = "a concatenation is not an assignment target",
            .lrm = "5.7",
            .explain =
            \\A concatenation builds a value; it does not name storage. LRM
            \\4.2.13 makes the related rule explicit for replications:
            \\"expressions containing replications shall not appear on the
            \\left-hand side of an assignment".
            \\
            \\Assign to each variable separately.
            ,
        },
        .E0318 => .{
            .title = "bitwise operator requires integer operands",
            .lrm = "4.2.9",
            .explain =
            \\LRM 4.2.1: with a real operand "all other operators are
            \\considered illegal" — bitwise and reduction operators among them.
            \\A real is an IEEE double whose bit pattern is not a modelled
            \\value in Verilog-A.
            \\
            \\Convert explicitly if that is really the intent; LRM 4.2.1.1
            \\rounds a real to integer, away from zero on an exact .5.
            ,
        },
        .E0319 => .{
            .title = "reduction operator requires an integer operand",
            .lrm = "4.2.10",
            .explain =
            \\A reduction folds an operand's bits into one bit, so the operand
            \\must have bits. See E0318.
            ,
        },
        .E0320 => .{
            .title = "xor reductions cannot be used inside the analog block",
            .lrm = "4.2.10",
            .explain =
            \\`^`, `~^` and `^~` as unary reductions are reduction operators,
            \\and LRM 4.2.10 says "The reduction operators can not be used
            \\inside the analog block". Compute the parity you need
            \\arithmetically, or with the binary bitwise operators, which are
            \\supported on integers.
            ,
        },
        .E0321 => .{
            .title = "arithmetic on a string operand",
            .lrm = "3.3",
            .explain =
            \\Strings are message and file-name payloads. They compare and
            \\concatenate; they do not take part in arithmetic.
            \\
            \\LRM 3.3 Table 3-3 defines ==, !=, <, <=, >, >=, concatenation
            \\and replication on the string type, each between two strings or
            \\a string and a string literal, and "A string cannot be assigned to
            \\an integral type". So `s + 1` and `s == 65` are errors for a
            \\string variable or parameter `s`. A string LITERAL is still the
            \\Verilog packed integer of its bytes: `"A" + 1` is 66.
            \\
            \\LRM 3.4: "It shall be an error to assign a numeric value to a
            \\parameter declared as string or to assign a string value to a
            \\real parameter."
            ,
        },
        .E0322 => .{
            .title = "bitwise and shift operators require integer operands",
            .lrm = "4.2.9",
            .explain =
            \\See E0318. Shifts additionally need an integer shift count: a
            \\fractional shift distance has no meaning.
            ,
        },
        .E0323 => retiredInfo(
            \\"case equality is not in the analog subset". Retired: annex C.5
            \\removes `===` and `!==` from the Verilog-A SUBSET only, and 7.3.2
            \\lists both among the features Verilog-AMS supports in the analog
            \\context. On two-state operands they now lower as `==` and `!=`.
            \\
            \\What replaced it: E0369, for a case comparison with a real operand
            \\(4.2.1). The number is not reused.
        ),
        .E0324 => .{
            .title = "arithmetic shifts cannot be used in an analog block",
            .lrm = "4.2.11",
            .explain =
            \\`<<<` and `>>>` are the arithmetic shift operators of IEEE 1364.
            \\LRM 4.2.11: "The arithmetic shift operators can not be used in an
            \\analog block." Use `<<` and `>>`.
            ,
        },
        .E0325 => retiredInfo(
            \\"operator is not in the analog subset". Retired: nothing emits it.
            \\Its one emitter was lowerBinary's dead `else`, reachable only for
            \\`&&` and `||`, which return earlier; d19a227 made that switch
            \\exhaustive and removed it. The number is not reused.
        ),
        .E0326 => .{
            .title = "empty concatenation",
            .lrm = "4.2.13",
            .explain = "`{}` has no operands, so it has no width and no value.",
        },
        .E0327 => .{
            .title = "concatenation operand has no bit width",
            .lrm = "4.2.13",
            .explain =
            \\LRM 4.2.13 accepts only sized constants (LRM 2.6.1), strings
            \\(LRM 3.3) and integer function calls (LRM 4.7.1, 32 bits) as
            \\concatenation operands, because the result width is the sum of
            \\the operand widths.
            \\
            \\A replication constant must additionally be "a non-negative,
            \\non-x and non-z constant expression".
            ,
        },
        .E0328 => retiredInfo(
            \\"string concatenation with a run-time operand is not supported".
            \\Retired: 3.3 Table 3-3 makes both a string-typed concatenation
            \\operand and a nonconstant replication multiplier legal, and the
            \\device now builds such a string while it runs (`$str$cat`,
            \\`$str$repeat`, str_kernels.zig). A nonconstant multiplier that is
            \\not of integral type is E0327. The number is not reused.
        ),
        .E0329 => .{
            .title = "a select or operand the analog context cannot size",
            .lrm = "7.3.1",
            .explain =
            \\7.3.1 Table 7-1 lets the analog context read a bit grouping of a
            \\`reg` as an integer, and a `reg` wider than 32 bits that the
            \\analog context assigns holds every bit IEEE 1364-2005 5.4 gives
            \\it. Each form refused here has no width VerA can compute in the
            \\analog context: an indexed part-select `x[i +: w]`, a select whose
            \\bounds are not constant, a part-select used as a value on its own,
            \\a concatenation or a string in the right-hand side of a wide
            \\`reg`, an unsized constant past 32 bits, a parameter past the
            \\64 bits its `Model` field holds, a conditional write (a scan task's
            \\target) or a digital read of a wide `reg` the analog context
            \\computes, and a select past bit 31 under an explicit D2A event,
            \\whose region-1b copy holds bits 0 to 31. Write a constant select,
            \\or size the operand.
            ,
        },
        .E0330 => .{
            .title = "unsupported index expression",
            .lrm = "3.2",
            .explain =
            \\The base of an array index must resolve to a declared array
            \\name, with one subscript per dimension. Runtime indices are
            \\supported for variable arrays. See E0309, E0310 and E0311 for
            \\the specific name, bounds and target restrictions.
            ,
        },
        .E0331 => .{
            .title = "aliasparam name is already a parameter",
            .lrm = "3.4.7",
            .explain =
            \\LRM 3.4.7: "The alias_identifier shall not occur anywhere else in
            \\the module; in particular, it shall not conflict with a different
            \\parameter_identifier".
            \\
            \\An `aliasparam` is a second NAME for one parameter, not a second
            \\parameter. Pointing it at a name that is already declared silently
            \\rebinds that name for the rest of the module, so
            \\
            \\    parameter real a = 1.0;
            \\    parameter real b = 7.0;
            \\    aliasparam a = b;
            \\    analog I(p,n) <+ V(p,n) * a;    // reads b: gain 7, not 1
            \\
            \\computes with `b` while the source says `a`, and the model card's
            \\`a` field becomes dead — writing it changes nothing.
            \\
            \\Rename the alias, or delete the parameter it collides with.
            ,
        },
        .E0373 => .{
            .title = "aliasparam name used in an expression",
            .lrm = "3.4.7",
            .explain =
            \\An alias supplies an alternate name for parameter overrides.
            \\The equations must reference the original parameter name, not
            \\the alias. This also applies to constant expressions, unused
            \\branches and hierarchical references. Bind through the alias
            \\in an instance, paramset, defparam or host model card, and read
            \\the original name in expressions.
            ,
        },
        .E0332 => .{
            .title = "base nature is missing a required attribute",
            .lrm = "3.6.1.2",
            .explain =
            \\LRM 3.6.1: "Each nature definition ... shall include all the
            \\required attributes specified in 3.6.1.2", and 3.6.1.2 says of
            \\abstol, access and units that each "is required for all base
            \\natures".
            \\
            \\    nature Voltage;
            \\      units  = "V";
            \\      access = V;
            \\      abstol = 1e-6;
            \\    endnature
            \\
            \\A nature that means to inherit them is a DERIVED nature and says
            \\so with a parent: `nature High_Voltage : Voltage;`.
            ,
        },
        .E0333 => .{
            .title = "derived nature redefines `units`",
            .lrm = "3.6.1.2",
            .explain =
            \\LRM 3.6.1.2, units: "It is illegal for a derived nature to define
            \\or change the units; the derived nature always inherits its parent
            \\nature units."
            \\
            \\Units are what makes the parent's tolerance and the child's
            \\comparable at all, so a child in different units is not a
            \\refinement of its parent — it is a different quantity, and wants a
            \\base nature of its own.
            \\
            \\Contrast abstol, which 3.6.1.2 explicitly allows a derived nature
            \\to change.
            ,
        },
        .E0334 => .{
            .title = "derived nature changes `access`",
            .lrm = "3.6.1.2",
            .explain =
            \\LRM 3.6.1.2, access: "It is illegal for a derived nature to change
            \\the access attribute; the derived nature always inherits the
            \\access attribute of its parent nature."
            \\
            \\The access function is how source text names the quantity (LRM
            \\4.4). A derived nature narrows the TOLERANCE of its parent's
            \\quantity, not its spelling, so `V(n)` keeps working on a net whose
            \\discipline binds the derived nature.
            ,
        },
        .E0335 => .{
            .title = "two base natures share an access function",
            .lrm = "3.13.2",
            .explain =
            \\LRM 3.13.2: "the access function of each base nature shall be
            \\unique". The name in an access function call (LRM 4.4) has to
            \\identify one nature, and with two claiming it there is no reading
            \\of `MyAccess(n)` that a compiler could pick.
            \\
            \\Two natures that are meant to be the same quantity are spelled as
            \\one base nature plus a derived nature (LRM 3.6.1.1), which
            \\inherits the access name instead of re-declaring it.
            ,
        },
        .E0336 => .{
            .title = "identifier is already declared as a nature or a discipline",
            .lrm = "3.13.1",
            .explain =
            \\LRM 3.13.1: "Natures and disciplines are defined at the same level
            \\of scope as modules. Thus, identifiers defined as natures or
            \\disciplines have a global scope" — one namespace, and LRM 3.6.1
            \\adds that each nature "shall have a unique identifier".
            \\
            \\The ambiguity is real, not cosmetic: annex A takes a bare
            \\identifier for both `parent_nature ::= nature_identifier` and
            \\`net_declaration ::= discipline_identifier ...`, so a name bound to
            \\both kinds leaves those productions with no unique reading.
            ,
        },
        .E0337 => .{
            .title = "net has no declared discipline",
            .lrm = "3.6.3",
            .explain =
            \\LRM 3.6.3: "Nets declared with a natureless discipline or declared
            \\without a discipline do not have declared natures, so such nets
            \\can not be used in analog behavioral descriptions (because the
            \\access functions are not known)." LRM 6.5.2.1 says the same of a
            \\port: an undeclared type leaves it usable "only in a structural
            \\description".
            \\
            \\This fires on the ACCESS, not on the declaration — LRM 3.6.5
            \\implicit nets are legal right up to the point where behavioral
            \\code asks for a potential or a flow they do not have.
            \\
            \\Declare a discipline for the net: `electrical n;`.
            ,
        },
        .E0338 => .{
            .title = "conservative discipline binds one nature to both halves",
            .lrm = "3.6.2.1",
            .explain =
            \\LRM 3.6.2.1: "Conservative disciplines shall not have the same
            \\nature specified for both the potential and the flow."
            \\
            \\The same clause makes the potential nature's `access` the
            \\potential access function and the flow nature's the flow access
            \\function, so one nature on both bindings gives one name two
            \\meanings and no way to tell them apart at a call site.
            ,
        },
        .E0339 => .{
            .title = "`domain discrete` on a discipline that binds a nature",
            .lrm = "3.6.2.2",
            .explain =
            \\LRM 3.6.2.2: "It is an error for a discipline to have a domain
            \\binding of discrete if it has nature bindings."
            \\
            \\A discrete-domain net is solved by the digital kernel, which has
            \\no continuous quantity for a nature to describe. Drop the nature
            \\binding, or make the domain continuous (which is the default for
            \\a discipline that binds natures).
            ,
        },
        .E0340 => .{
            .title = "nature attribute value of the wrong form",
            .lrm = "3.6.1.2",
            .explain =
            \\LRM 3.6.1.2 fixes the form of each attribute's value:
            \\
            \\  - `access` — "shall be an identifier (by name, not as a
            \\    string)", because it introduces a callable name;
            \\  - `units` — "shall be a string", because LRM 3.11.1's Units
            \\    Value Rule compares two natures on it;
            \\  - `idt_nature`/`ddt_nature` — "the name (not a string) of a
            \\    nature".
            \\
            \\LRM 3.6.1.3 adds of a user-defined attribute that "the value being
            \\assigned to the attribute shall be constant": a nature lives
            \\outside every module (LRM 3.13.1), so no runtime name is in scope
            \\to assign from.
            ,
        },
        .E0341 => .{
            .title = "`idt_nature` does not name a related nature",
            .lrm = "3.6.1.2",
            .explain =
            \\LRM 3.6.1.2: "If specified, the constant expression assigned to
            \\idt_nature shall be the name (not a string) of a nature which is
            \\defined elsewhere." The attribute "is optional; the default value
            \\is the nature itself". A derived nature may override the parent's
            \\value, but "the nature thus specified shall be related (share the
            \\same base nature) to the nature the parent uses for its
            \\idt_nature", which is the parent itself when it gives none.
            \\
            \\`idt(access(...))` takes its tolerance from that nature, so a
            \\dangling or unrelated name leaves the integral with no tolerance
            \\the solver can use.
            ,
        },
        .E0374 => .{
            .title = "`ddt_nature` does not name a related nature",
            .lrm = "3.6.1.2",
            .explain =
            \\LRM 3.6.1.2: "If specified, the constant expression assigned to
            \\ddt_nature shall be the name (not a string) of a nature which is
            \\defined elsewhere." The attribute "is optional; the default value
            \\is the nature itself". A derived nature may override the parent's
            \\value, but "the nature thus specified shall be related (share the
            \\same base nature) to the nature the parent uses for its
            \\ddt_nature", which is the parent itself when it gives none.
            \\
            \\`ddt(access(...))` takes its tolerance from that nature, so a
            \\dangling or unrelated name leaves the derivative with no
            \\tolerance the solver can use. Derive the override from the
            \\parent's ddt_nature: `nature dI : Current; endnature`.
            ,
        },
        .E0375 => .{
            .title = "incompatible hierarchical discipline override",
            .lrm = "3.6.2",
            .explain =
            \\LRM 3.6.2: "It is possible to set the discipline of interconnect
            \\and digital nets through discipline declaration with hierarchical
            \\references to these nets. It shall be an error to hierarchically
            \\override the discipline of a net that was explicitly declared
            \\unless it is a compatible discipline."
            \\
            \\Compatible is LRM 3.11.1's: the same discipline, or the same
            \\domain with compatible potential and flow natures (one derived
            \\from the other, a shared base nature, or the same `units`).
            \\
            \\    module leaf(p); inout p; electrical p; endmodule
            \\    module top; leaf u1(a); rotational u1.p; endmodule  // error
            \\
            \\The leaf's equations were written for its own access functions,
            \\so an incompatible override would rename the quantity they read.
            \\Override only an undeclared net, or one whose discipline the new
            \\one is compatible with.
            ,
        },
        .E0376 => .{
            .title = "port has no direction declaration",
            .lrm = "6.5.2.2",
            .explain =
            \\LRM 6.5.2.2: "Each port shall be declared as input, output, or
            \\inout (bidirectional), in addition to any other declaration (e.g.,
            \\discipline, reg, or wire)." 6.2 says the same of the list of
            \\ports: its identifiers "shall be declared in input, output, and
            \\inout statements within the module definition".
            \\
            \\    module m(c); electrical c; ... endmodule             // error
            \\    module m(c); inout c; electrical c; ... endmodule    // ok
            \\
            \\A discipline declaration is not a direction. Every module of the
            \\compilation is checked, instantiated or not. The digital engine
            \\(`--run` of a `.v` design) reports the same omission as E1100.
            ,
        },
        .E0377 => .{
            .title = "a model-card parameter value is outside its range",
            .lrm = "3.4.2",
            .explain =
            \\LRM 3.4.2: "The parameter value shall be within the range from the
            \\smallest value specified to the largest value specified", minus
            \\what an `exclude` removes, and "It shall be an error only if the
            \\value of the parameter is out of range during simulation."
            \\
            \\    parameter real r = 1 from (0:inf) exclude 2;
            \\
            \\A `#(...)` override is elaborated with the design and judged at
            \\compile time (E0361). A value the HOST writes on the model card
            \\(a `//! param` or `//! psweep` card, a SPICE `.model` line) exists
            \\only when the card is written, so the device's `checkRange`, which
            \\every host calls after `derive`, names the first parameter outside
            \\its ranges. The testbench stops with this code (exit 1); the OSDI
            \\library reports it as a fatal setup error.
            \\
            \\Only bounds that fold over literals are checked: a bound written
            \\over another parameter, and a string-set range, are not
            \\(specification/Vague_Decisions.md VD-125).
            ,
        },
        .E0342 => .{
            .title = "nature or discipline is already declared",
            .lrm = "3.13.1",
            .explain =
            \\LRM 3.6.1: "Each nature definition shall have a unique identifier
            \\as the name of the nature." LRM 3.6.2 says the same of a
            \\discipline, and LRM 3.13.1 puts both in one global scope, so the
            \\second declaration has nowhere to live.
            \\
            \\Two declarations of one name give a net of it two different sets
            \\of access functions. A nature that means to reuse another's
            \\attributes derives from it (LRM 3.6.1.1): `nature b : a;
            \\endnature`.
            ,
        },
        .E0343 => .{
            .title = "duplicate user-defined nature attribute",
            .lrm = "3.6.1.3",
            .explain =
            \\LRM 3.6.1.3: "The name of the attribute shall be unique in the
            \\nature being defined and the value being assigned to the
            \\attribute shall be constant."
            \\
            \\Two assignments to one attribute name leave `<nature>.<attr>`
            \\with no single reading.
            ,
        },
        .E0344 => .{
            .title = "`ground` net is not of a continuous discipline",
            .lrm = "3.6.4",
            .explain =
            \\LRM 3.6.4: "Each ground declaration is associated with an already
            \\declared net of continuous discipline. ... The net must be
            \\assigned a continuous discipline to be declared ground."
            \\
            \\The global reference node is the zero of a potential. A discrete
            \\discipline binds no nature (LRM 3.6.2.2), so there is no potential
            \\for it to be the reference of.
            ,
        },

        .E0345 => .{
            .title = "parameter initializer type conflicts with the parameter's type",
            .lrm = "3.4.1",
            .explain =
            \\LRM 3.4.1: "No conversion shall be applied for strings; it shall
            \\be an error to assign a numeric value to a parameter declared as
            \\string or to assign a string value to a real parameter, whether
            \\that parameter was declared as real or had its type derived from
            \\the type of the value of the constant expression."
            \\
            \\The sentence BEFORE it is the general rule and it is why this one
            \\has to be written down: "If the type of the parameter is specified
            \\as integer or real, and the value assigned to the parameter
            \\conflicts with the type of the parameter, the value is converted
            \\to the type of the parameter." `parameter real size = 10;` is
            \\legal by that rule. String is the one type the conversion does not
            \\reach, in either direction.
            ,
        },
        .E0346 => .{
            .title = "array or string parameter needs an explicit type",
            .lrm = "3.4.1",
            .explain =
            \\LRM 3.4.1: "If the type of a parameter is not specified, it is
            \\derived from the type of the final value assigned to the
            \\parameter, after any value overrides have been applied ... Note
            \\that the type of a string parameter (see 3.4.6) and any of the
            \\array parameters (see 3.4.4) is mandatory." LRM 3.4.4 states the
            \\array half again inside the restriction list it closes with
            \\"Failure to follow these restrictions shall result in an error".
            \\
            \\Inference is defined over the value AFTER overrides, so an untyped
            \\parameter has no type until elaboration — and the two rules that
            \\have to hold before then, 3.4.1's ban on string conversion and
            \\3.4.4's element type, would have nothing to test. An array's
            \\initializer is an assignment pattern, which is not a scalar value
            \\and has no type to derive in the first place.
            \\
            \\    parameter real c[0:3] = '{1.0, 2.0, 3.0, 4.0};
            \\    parameter string kind = "npn";
            ,
        },
        .E0347 => .{
            .title = "value range bounds are in the wrong order",
            .lrm = "3.4.2",
            .explain =
            \\LRM 3.4.2: "The first expression in the range shall be numerically
            \\smaller than the second expression in the range."
            \\
            \\`from [10:1]` describes the empty set — no value is both >= 10 and
            \\<= 1 — so the parameter can never take a legal value, including
            \\its own default. This is decidable from the declaration alone; it
            \\is not the separate question of whether a given override falls
            \\inside a well-formed range.
            ,
        },
        .E0348 => .{
            .title = "reduction operators cannot be used inside the analog block",
            .lrm = "4.2.10",
            .explain =
            \\LRM 4.2.10, the whole clause: "The reduction operators can not be
            \\used inside the analog block and only have meaning when used in
            \\the digital context."
            \\
            \\There is no carve-out and no analog form: `&`, `|`, `~&` and `~|`
            \\are banned exactly as `^`, `~^` and `^~` are (those get E0320,
            \\under the same clause; annex C.5 removes only `===` and `!==`
            \\from Verilog-A).
            \\
            \\A reduction folds a BIT VECTOR, and an analog value is a real
            \\number on a continuous net. Write the test you mean: `x != 0`
            \\for `|x`, `x == -1` for `&x` on a two's-complement integer.
            ,
        },
        .E0349 => .{
            .title = "array parameter initialiser is not an assignment pattern",
            .lrm = "3.4",
            .explain =
            \\LRM 3.4: "For parameters defined as arrays, the initializer shall
            \\be a constant_assignment_pattern expression ... using an
            \\assignment pattern (see 4.2.14), i.e. within '{ and } delimiters."
            \\3.4.4 prints the form:
            \\
            \\    parameter real poles[0:3] = '{ 1.0, 3.198, 4.554, 1.0 };
            \\
            \\The apostrophe is not decoration. Annex G Table G.4 item 2 records
            \\why v2.3 added it: "to distinguish a list of values from the
            \\concatenation operator". Without it `{2.1, 4.5}` is the 4.2.13
            \\concatenation, a different production with a different meaning,
            \\and a front end that accepts it as an initialiser cannot tell the
            \\two apart.
            ,
        },
        .E0350 => .{
            .title = "the two declarations of a vector port give different ranges",
            .lrm = "6.5.2.2",
            .explain =
            \\LRM 6.5.2.2: "A port can be declared in both a port type
            \\declaration and a port direction declaration. If a port is
            \\declared as a vector, the range specification between the two
            \\declarations of a port shall be identical."
            \\
            \\The rule is EVALUATE-equal, not spell-equal — the clause prints
            \\
            \\    input [0:3] in;
            \\    electrical [0:4-1] in;   // valid
            \\
            \\as legal, because `4-1` folds to `3`. Both bounds are folded here
            \\before they are compared, so only a genuine difference in width
            \\or in direction (`[3:0]` against `[0:3]`) is reported.
            ,
        },
        .E0351 => .{
            .title = "not an element of a vector net",
            .lrm = "5.5.2",
            .explain =
            \\LRM 5.5.2: "the access functions can only be applied to scalars
            \\or individual elements of a vector. The scalar element of a
            \\vector is selected with an index, e.g., V(in[1]) accesses the
            \\voltage in[1]."
            \\
            \\Two shapes break that, and both land here:
            \\
            \\  - an index on a net that was declared without a range, where
            \\    there is no element to select;
            \\  - a bare vector name where one signal is required — a vector
            \\    net is a set of nodes, and 1.3.1 gives a potential to each
            \\    one, not to the set.
            \\
            \\Write the index, or declare the net with a range.
            ,
        },
        .E0352 => .{
            .title = "vector index is not a constant inside the declared range",
            .lrm = "3.6.3",
            .explain =
            \\A vector net is scalarised at elaboration — 3.6.3's `electrical
            \\[3:0] p` is four independent nets — so every index must be
            \\decidable then. 5.5.2 says so directly for the looping case: "The
            \\index must be a constant expression, though it may include genvar
            \\variables."
            \\
            \\So an index built from a run-time variable has no element to name,
            \\and an index outside the declared range names a net that was never
            \\declared. Use a literal, a parameter, or the genvar of an
            \\enclosing 5.9.3 analog `for`.
            ,
        },
        .E0353 => .{
            .title = "branch terminals are vectors of different sizes",
            .lrm = "3.12",
            .explain =
            \\LRM 3.12: "If one of the terminals of a branch is a vector net,
            \\then the other terminal shall either be a scalar net or a vector
            \\net of the same size."
            \\
            \\Two vectors of the same size pair one-to-one (Figure 3-1) and a
            \\vector against a scalar fans in (Figure 3-2). Two vectors of
            \\DIFFERENT sizes are neither: there is no pairing the declaration
            \\could mean, so the branch has no size of its own and no element
            \\can be indexed out of it.
            ,
        },

        .E0354 => .{
            .title = "a string value cannot be assigned to a numeric variable",
            .lrm = "3.3",
            .explain =
            \\LRM 3.4.1 states the conversion rule and its one exception: "No
            \\conversion shall be applied for strings; it shall be an error to
            \\assign a numeric value to a parameter declared as string or to
            \\assign a string value to a real parameter." E0345 is that sentence
            \\on a parameter; this is the same rule on a variable, where 3.3
            \\puts strings in their own type alongside integer and real.
            \\
            \\3.3's own worked example is where it bites hardest:
            \\
            \\    b = {5{"Hi"}};     // OK          (b is a string)
            \\    a = {i{"Hi"}};     // OK          (a is a string)
            \\    r = {i{"Hi"}};     // invalid     (r is integral)
            \\
            \\Table 3-3's Replication row says why the third line is the invalid
            \\one: "if multiplier is nonconstant or Str is of type string, the
            \\result is a string containing N concatenated copies". A string has
            \\no width, and an integral target is nothing but a width.
            \\
            \\Declare the target `string`, or compare rather than assign — 3.3's
            \\relational operators on strings yield an integer.
            ,
        },
        .E0355 => .{
            .title = "incompatible disciplines",
            .lrm = "3.11.1",
            .explain =
            \\LRM 3.11: "Certain operations can be done on nets only if the two
            \\(or more) nets are compatible. For example, if an access function
            \\has two nets as arguments, they must be compatible." 3.12 states
            \\the same requirement for the two terminals of a branch
            \\declaration, and 7.4.3 for a continuous-time port connection.
            \\
            \\3.11.1 decides it. Two disciplines are compatible when:
            \\
            \\  - they are the same discipline                (Self Rule);
            \\  - either is DOMAINLESS — declares no `domain` and binds no
            \\    nature                                      (Domainless Rule);
            \\  - otherwise: they agree on domain, and each half's natures are
            \\    compatible. A discipline that binds no nature for a half is
            \\    compatible with anything there    (Non-Existent Binding Rule),
            \\    which is what makes a natureless discipline universal.
            \\
            \\Two natures are compatible when they are the same nature, when one
            \\is derived from the other, when both derive from one base nature,
            \\or when they declare the same `units` string (Units Value Rule).
            \\
            \\3.11.1's own worked case is the one that bites: "electrical and
            \\rotational are incompatible disciplines because the natures for
            \\both potential and flow are not derived from the same base
            \\natures."
            \\
            \\Two nets of different DOMAINS are not joined by fixing a nature.
            \\7.4 says what to write instead: a `connect` statement, so the
            \\elaborator inserts a connect module between the two.
            ,
        },
        .E0356 => .{
            .title = "wrong number of array subscripts",
            .lrm = "3.2",
            .explain =
            \\LRM 3.2 declares an array with one `dimension` per subscript:
            \\
            \\    integer flag_array[0:8][0:3];   // 9 rows of 4
            \\
            \\so `flag_array[3]` names a whole ROW and not a cell. Verilog-AMS
            \\has no array-valued expression outside 3.4.8's assignment patterns
            \\and 5.7's whole-array assignment, so a partial subscript list has
            \\nowhere to be used and is reported here rather than read as the
            \\first element.
            ,
        },
        .E0357 => .{
            .title = "illegal attribute value",
            .lrm = "2.9",
            .explain =
            \\LRM 2.9, Syntax 2-4:
            \\
            \\    attr_spec ::= attr_name [ = constant_expression ]
            \\
            \\Both of the clause's rules about that value land here, because both
            \\say it is not a legal constant_expression.
            \\
            \\1. IT MUST BE CONSTANT. An attribute carries "properties about
            \\objects, statements and groups of statements in the HDL source that
            \\can be used by various tools" — a tool that is not a simulator,
            \\reading the source without solving it. A variable's value exists
            \\only during a solve, so there is no value for such a tool to read.
            \\A parameter IS a constant expression here (A.8.4 constant_primary),
            \\so `(* q = gain *)` is accepted; `(* q = z *)` with `real z` is not.
            \\
            \\2. IT MAY NOT CONTAIN AN ATTRIBUTE INSTANCE. "Nesting of attribute
            \\instances is disallowed. It shall be illegal to specify the value of
            \\an attribute with a constant expression that contains an attribute
            \\instance." A.8.3 gives operators their own attribute slot, so
            \\`(* outer = (1 + (* inner *) 2) *)` is refused by this rule and not
            \\by the grammar.
            ,
        },
        .E0358 => .{
            .title = "standard attribute value is outside its domain",
            .lrm = "2.9.2",
            .explain =
            \\LRM 2.9.2 standardizes four attribute names and fixes the value of
            \\each with a "must":
            \\
            \\    desc          must be assigned a string
            \\    units         must be assigned a string
            \\    op            "yes" or "no"
            \\    multiplicity  "multiply", "divide" or "none"
            \\
            \\These are not free-form tool hints: `multiplicity` picks the
            \\$mfactor scaling of an operating-point report, so a value outside
            \\the listed set has no reading at all.
            \\
            \\Annex E adds a fifth. E.3.2.1: `port_discipline` on an analog
            \\primitive or one of its ports "shall be of type string and the
            \\value must be a valid discipline of domain continuous". On any other
            \\module or port the same clause says it "shall be ignored", and it is.
            \\
            \\Any OTHER attribute name is a tool convention and is not checked —
            \\2.9 leaves its meaning to the tool that reads it.
            ,
        },
        .E0359 => .{
            .title = "nature attribute reference has no constant value",
            .lrm = "5.5.3",
            .explain =
            \\LRM 5.5.3, Syntax 5-4:
            \\
            \\    nature_attribute_reference ::=
            \\        net_identifier . potential_or_flow . nature_attribute_identifier
            \\
            \\and the sentence after it: "This syntax shall not be used for the
            \\access, ddt_nature, or idt_nature attributes of a nature, nor any
            \\other attribute whose value is not a constant expression."
            \\
            \\Those three attributes name an IDENTIFIER — `access` is the access
            \\function itself (`V`), not a number — so there is no value for the
            \\reference to stand for. The same goes for an attribute the nature
            \\never declared.
            \\
            \\`n.potential.abstol` is the form the clause's own twocap example
            \\uses, and it works.
            ,
        },
        .E0360 => .{
            .title = "signal-flow discipline on an `inout` port",
            .lrm = "1.3.4.1",
            .explain =
            \\LRM 1.3.4.1: "Nets of potential signal flow disciplines in modules
            \\may only be bound to `input` or `output` ports of the module, not
            \\to `inout` ports." 1.3.4.2 says the same of flow signal-flow
            \\disciplines.
            \\
            \\A signal-flow net carries ONE nature, so its port direction is the
            \\direction of that one quantity: `input` means the netlist supplies
            \\it, `output` means this module does. `inout` claims both at once,
            \\and there is no conservation law here to reconcile them — that is
            \\what 1.3.1's conserved potential/flow PAIR is for, and a
            \\single-nature discipline has no such pair.
            \\
            \\Declare the port `input` or `output`, or give the net a
            \\conservative discipline (both natures) if it really is a terminal.
            \\
            \\Contributing to an `input` signal-flow port is the sibling rule,
            \\E0425.
            ,
        },
        .E0361 => .{
            .title = "overridden parameter value is outside its range",
            .lrm = "3.4.2",
            .explain =
            \\LRM 3.4.2: "The parameter value shall be within the range from the
            \\smallest value specified to the largest value specified", and an
            \\`exclude` removes a value or an interval from what is left.
            \\
            \\This is the half of 3.4.2 that needs a VALUE. A declared default is
            \\judged only for whether its own bounds are well formed (E0347) —
            \\6.3 makes the interesting value the one an INSTANCE supplied, and a
            \\module compiled on its own has no instance. The check therefore runs
            \\on parameters whose value came from a `#(...)` override, which is
            \\where a model card meets a model's declared legal range.
            \\
            \\3.4.2 states the error at simulation time; VerA elaborates the
            \\instance at compile time, so it is reported here. A value the
            \\host writes on the model card is checked when it is written
            \\(E0377).
            ,
        },
        .E0362 => .{
            .title = "identifier is declared twice in one scope",
            .lrm = "6.8",
            .explain =
            \\LRM 6.8: "An identifier shall be used to declare only one item
            \\within a scope. This rule means it is illegal to declare two or more
            \\variables which have the same name, or to name a task the same as a
            \\variable within the same module, or to give an instance the same name
            \\as the name of the net connected to its output."
            \\
            \\SHADOWING IS NOT THIS. 6.8 lists what opens a scope — modules, named
            \\blocks, analog functions, generate blocks — and an inner scope may
            \\reuse an outer name freely. Only two declarations at the SAME level
            \\are this error, because the second one has no way to be reached.
            \\
            \\What VerA checks is the first clause of that sentence: two variable
            \\declarations of one name in one module or one block. Rename one of
            \\them, or delete it if it was a repeat of the same declaration.
            ,
        },
        .E0363 => .{
            .title = "parameter default is not a constant expression",
            .lrm = "3.4",
            .explain =
            \\A.2.4 gives a parameter assignment a constant_mintypmax_expression,
            \\and 3.4 explains why: "The default_value may not be changed at
            \\runtime" — a parameter is a value fixed before the solve, settable
            \\only per instance (6.3). An expression that reads simulation state
            \\— $abstime, $temperature, $vt, $random, an access function like
            \\V(a,b), an analog operator — has a different value at every point
            \\of the solve, so there is no single number a model card could
            \\carry for it and no moment the default could honestly be read.
            \\
            \\A default MAY reference other parameters (3.4/6.3.4: an update of
            \\the base parameter automatically updates the dependent one); it is
            \\the operating point it may not reference.
            \\
            \\Compute the value in the analog block instead, into a variable:
            \\
            \\    parameter real tj0 = 27;          // overridable constant
            \\    real tj;
            \\    analog tj = $temperature - `P_CELSIUS0;
            ,
        },

        .E0364 => retiredInfo(
            \\"mixed signedness around a shift is not implemented". Retired: a
            \\comparison extends each operand from its own width, as 4.2.9 says
            \\("the smaller operand shall be zero-extended to the size of the
            \\larger operand"), so (a >> n) > 40'h1 is the 32-bit shift's value,
            \\zero-extended, and there is nothing left to refuse. The number is
            \\not reused.
        ),
        .E0368 => .{
            .title = "real value with no integer conversion",
            .lrm = "4.2.1.1",
            .explain =
            \\LRM 4.2.1.1: "Real numbers are converted to integers by rounding
            \\the real number to the nearest integer". An infinity or a NaN has
            \\no nearest integer, so the conversion has no result, and 3.4.1
            \\makes an `integer` parameter's default go through exactly that
            \\conversion: "the value is converted to the type of the parameter
            \\(see 4.2.1.1)".
            \\
            \\There is no in-range stand-in either: 3.2 gives an integer the
            \\range -2**31 to 2**31-1, so a saturated or wrapped value would be
            \\a number the source never produced.
            \\
            \\    parameter integer n = 1.0/0.0;   // no value
            \\    parameter real    r = 1.0/0.0;   // fine: +inf is a real
            \\
            \\Declare it `real`, or fix the expression that overflows.
            ,
        },
        .E0369 => .{
            .title = "case equality on a real operand",
            .lrm = "4.2.1",
            .explain =
            \\`===` and `!==` compare x and z bit-for-bit (IEEE 1364 5.1.8), and
            \\7.3.2 supports them in the analog context on integer and digital
            \\operands. A real has no bits: 4.2.1's Table 4-2, the operators
            \\legal on real operands, lists `==` and `!=` but not these two.
            \\
            \\Use `==` and `!=`. For reals, prefer a tolerance comparison —
            \\`abs(a - b) < tol` — over exact equality.
            ,
        },
        .E0370 => .{
            .title = "discipline overrides an attribute of no bound nature",
            .lrm = "3.6.2.5",
            .explain =
            \\LRM 3.6.2.5: "A discipline can override the value of the bound
            \\nature for the pre-defined attributes ... To do so from a
            \\discipline declaration, the bound nature and attribute needs to
            \\be defined."
            \\
            \\`flow.abstol = 1n;` overrides the abstol of the nature bound to
            \\the discipline's flow. A discipline that binds no flow nature has
            \\no such value to override, and the line would otherwise be
            \\dropped without a word. Bind the nature first:
            \\
            \\    discipline d;
            \\      potential Voltage;
            \\      flow Current;          // the nature the override needs
            \\      flow.abstol = 1n;
            \\    enddiscipline
            \\
            \\The same holds for an attribute the bound nature does not define.
            ,
        },
        .E0371 => .{
            .title = "net declared with an undeclared discipline",
            .lrm = "3.6.3",
            .explain =
            \\A.2.1.3's net declaration is `discipline_identifier
            \\list_of_net_identifiers ;`, and the identifier names a discipline
            \\declared with `discipline ... enddiscipline` (3.6.2) — annex D's
            \\`electrical`, `logic` and the rest, or one of your own. A name no
            \\discipline declares gives the net no domain and no natures, so
            \\nothing downstream can say what it carries.
            \\
            \\The usual cause is a module instance without its parentheses:
            \\
            \\    child c1;      // parsed as a net `c1` of discipline `child`
            \\    child c1();    // A.4.1 module_instance, even with no ports
            \\
            \\Otherwise declare the discipline, or `include "disciplines.vams"`.
            \\
            \\Annex D.1's disciplines (`electrical`, `thermal`, `logic` and the
            \\rest) are declared by disciplines.vams, and `vera` gives them only
            \\to a source that includes it: write `include "disciplines.vams"`
            \\(or "discipline.h") before the first module. VerA ships the file,
            \\so no include path is needed.
            ,
        },
        .E0372 => .{
            .title = "port branch names a net that is not a port",
            .lrm = "3.12.1",
            .explain =
            \\LRM 3.12.1: "A port branch is a special type of branch used to
            \\access the flow into a port of a module (see 5.4.3). It is a branch
            \\between the upper and lower connections of the port." Syntax 3-9
            \\spells it `branch ( < port_identifier > )`. An internal net has
            \\no upper connection — nothing outside the module is joined to it
            \\— so there is no branch between the two for the declaration to
            \\name. Declare the net as a port, or use an ordinary branch
            \\`branch (x, y) b;`.
            ,
        },

        .E0367 => .{
            .title = "implicit net under `default_nettype none",
            .lrm = "3.6.5",
            .explain =
            \\LRM 3.6.5: "Nets can be used in structural descriptions without
            \\being declared. In this case, the net's discipline and domain
            \\binding will be determined by discipline resolution." That is the
            \\rule this name was relying on, and `default_nettype none
            \\withdraws it.
            \\
            \\LRM 10.1 carries `default_nettype over from IEEE Std 1364
            \\unchanged, and 1364 19.2 gives `none` its meaning: with it in
            \\force there is no type for an implicit net to have, so an
            \\undeclared identifier used as a net is an error instead of a
            \\silently created wire. That is the whole point of writing it --
            \\a mistyped net name is otherwise a new floating node, which
            \\simulates, and simulates wrong.
            \\
            \\Two fixes, and which one is right depends on which you meant:
            \\
            \\    electrical n;        declare the net
            \\    `default_nettype wire   go back to implicit nets
            \\
            \\The directive's scope is 10.1's: it runs from where it is
            \\written, across file boundaries, until another `default_nettype
            \\or a `resetall supersedes it.
            ,
        },

        .E0365 => .{
            .title = "net initializer is not a constant expression",
            .lrm = "3.6.3.2",
            .explain =
            \\LRM 3.6.3.2: "The initializer shall be a constant_expression and
            \\will be used as a nodeset value for the potential of the net by
            \\the analog solver."
            \\
            \\A nodeset is the solver's STARTING POINT, chosen before the first
            \\iteration runs. An expression that reads a net potential, a
            \\variable or the simulation state has no value at that moment, so
            \\there is nothing for the initializer to be.
            \\
            \\A parameter reference IS a constant expression (LRM 3.4) and is
            \\accepted: `electrical n = vstart;` is the form a model card tunes.
            ,
        },
        .E0366 => .{
            .title = "net of a non-continuous discipline has an initializer",
            .lrm = "3.6.3.2",
            .explain =
            \\LRM 3.6.3.2: "Nets with continuous disciplines are allowed to have
            \\initializers on their net discipline declarations; however, nets
            \\of non-continuous disciplines are not."
            \\
            \\The initializer is "a nodeset value for the POTENTIAL of the net".
            \\A discrete discipline binds no nature (LRM 3.6.2.2), so the net
            \\has no potential for the value to be a guess at.
            \\
            \\E0344 is the same sentence about `ground`, which needs a
            \\continuous discipline for the same reason.
            ,
        },

        // ------------------------------------------------------------ class 4
        .E0401 => .{
            .title = "`disable` is not an analog statement",
            .lrm = "A.6.4",
            .explain =
            \\A.6.4 derives `analog_statement` without a `disable_statement`
            \\alternative. The only form an analog block admits is the event
            \\statement
            \\
            \\    @(<event>) disable <named_block>;
            \\
            \\which A.6.4 spells as analog_event_statement.
            ,
        },
        .E0402 => .{
            .title = "`disable` does not name a block",
            .lrm = "A.6.5",
            .explain =
            \\A.6.5 gives disable_statement two operands, a
            \\hierarchical_task_identifier and a hierarchical_block_identifier,
            \\and Verilog-AMS gives an analog block no task — so the only legal
            \\operand here is the label of an enclosing named block.
            ,
        },
        .E0403 => .{
            .title = "`return` outside an analog function",
            .lrm = "4.7.1",
            .explain =
            \\LRM 5.11 jump statements are confined to an analog function body.
            \\The analog block itself has no caller to return to — it runs to
            \\completion on every solver evaluation.
            ,
        },
        .E0404 => .{
            .title = "`break` or `continue` outside a loop",
            .lrm = "5.9",
            .explain =
            \\These statements need an enclosing `for`, `while` or `repeat` in
            \\the same function or analog block.
            ,
        },
        .E0405 => .{
            .title = "contribution is not allowed in this context",
            .lrm = "5.2.1",
            .explain =
            \\`<+` adds a term to the system of equations, so it belongs in the
            \\analog block. LRM 4.7.2 keeps analog functions pure: a function
            \\body may compute, but it may not contribute, probe, or use analog
            \\operators.
            \\
            \\Return the value and contribute it at the call site.
            ,
        },
        .E0406 => .{
            .title = "contribution inside an event statement",
            .lrm = "5.10",
            .explain =
            \\The body of an `@(...)` event statement runs only at the instants
            \\the event fires, while a contribution must hold continuously —
            \\the solver re-evaluates it at every iteration of every timepoint.
            \\
            \\Set a variable in the event body and contribute it outside.
            ,
        },
        .E0407 => .{
            .title = "port access function cannot be a contribution target",
            .lrm = "5.4.3",
            .explain =
            \\LRM 5.5.1: "The port access function shall not be used on the
            \\left side of a contribution operator <+."
            \\
            \\`I(<p>)` MEASURES the flow into port p; it does not name a branch
            \\that could receive a contribution. Contribute to the branch
            \\instead: `I(p, gnd) <+ ...`.
            ,
        },
        .E0408 => .{
            .title = "contribution target must be a branch access",
            .lrm = "5.6",
            .explain =
            \\The left side of `<+` is one access function applied to a branch
            \\or a node pair:
            \\
            \\    I(a, b) <+ expr;
            \\    V(br)   <+ expr;
            \\
            \\Not a variable, not a general expression, not a bare net.
            ,
        },
        .E0409 => .{
            .title = "branch is already indirectly assigned",
            .lrm = "5.6.7.2",
            .explain =
            \\A branch is defined either by accumulated `<+` contributions or
            \\by one indirect assignment, never both: LRM 5.6.1.3 accumulates
            \\every contributing path into one value, while LRM 5.6.7 replaces
            \\the branch's equation with the stated constraint.
            \\
            \\Mixing them leaves the branch with two contradictory equations.
            ,
        },
        .E0410 => .{
            .title = "indirect contribution is not allowed in this context",
            .lrm = "5.2.1",
            .explain =
            \\An indirect contribution states a constraint on the whole system,
            \\so it belongs in the analog block. See E0405 for why an analog
            \\function may not contain one.
            ,
        },
        .E0411 => .{
            .title = "indirect contribution inside an event statement",
            .lrm = "5.10",
            .explain =
            \\See E0406: an event body runs at instants, a constraint must hold
            \\continuously.
            ,
        },
        .E0412 => .{
            .title = "indirect contribution in a conditional or loop",
            .lrm = "5.6.7",
            .explain =
            \\LRM 5.6.7: "Indirect branch contributions shall not be used in
            \\conditional or looping statements, unless the conditional
            \\expression is a constant expression."
            \\
            \\A constraint that exists only on some solver iterations changes
            \\the size of the equation system between iterations, which no
            \\Newton solver can follow. A constant condition is fine — it is
            \\resolved at compile time and the branch simply is or is not
            \\emitted.
            ,
        },
        .E0413 => .{
            .title = "indirect contribution target must be a branch access",
            .lrm = "5.6.7",
            .explain =
            \\The left of the `:` names the unknown the constraint solves for:
            \\
            \\    V(out) : I(out) == 0;
            ,
        },
        .E0414 => .{
            .title = "invalid left side of '==' in an indirect contribution",
            .lrm = "5.6.7",
            .explain =
            \\The `==` names the quantity driven to the right-hand value. It
            \\must be an access function, or `ddt`, `idt` or `idtmod` applied
            \\to one:
            \\
            \\    V(out) : I(out)      == 0;
            \\    V(out) : ddt(V(cap)) == i/c;
            ,
        },
        .E0415 => .{
            .title = "branch already has a direct contribution",
            .lrm = "5.6.7.2",
            .explain = "The mirror image of E0409 — see that code.",
        },
        .E0416 => retiredInfo(
            \\"casex/casez are not in the analog subset". Retired: annex C.7's
            \\removal is the Verilog-A SUBSET's rule, and VerA compiles
            \\Verilog-AMS, where §7.3.2 lists "the case, casex, and casez
            \\statements" among the analog context's four-state features. They
            \\lower now (`lower_expr.caseMatch`). The number is not reused.
        ),
        .E0417 => .{
            .title = "genvar loop bound is not a constant expression",
            .lrm = "6.6.1",
            .explain =
            \\A genvar loop is unrolled at compile time, so its initial value,
            \\its condition and its step must all be constant expressions.
            \\
            \\For a loop whose trip count depends on a solver value, use an
            \\ordinary `integer` loop variable — but note that its body may not
            \\contain analog operators (LRM 4.5.15).
            ,
        },
        .E0418 => .{
            .title = "genvar loop condition is not a constant expression",
            .lrm = "6.6.1",
            .explain = "See E0417.",
        },
        .E0419 => .{
            .title = "genvar loop step is not a constant expression",
            .lrm = "6.6.1",
            .explain =
            \\See E0417. LRM 6.6.1 additionally requires that "both the
            \\initialization and iteration assignments shall assign to the same
            \\genvar".
            ,
        },
        .E0485 => retiredInfo(
            \\"genvar loop exceeds the unroll limit". Retired: a loop that ends
            \\after more than 4096 iterations was refused as an engine bound.
            \\Every loop generate that ends is now unrolled in full, however
            \\long; one that never ends is still E0420, found by following the
            \\scheme until it ends or repeats a genvar value, not by a count.
            \\The number is not reused.
        ),
        .E0486 => .{
            .title = "genvar set to x or z",
            .lrm = "6.6.1",
            .explain =
            \\LRM 6.6.1: "It shall be an error if any bit of the genvar is set to
            \\x or z." A genvar is an integer the loop generate scheme folds at
            \\elaboration time, so its initialization and iteration values must
            \\be known two-state integers: an x or z literal reaching either one
            \\is refused here, whatever the trip count.
            ,
        },
        .E0420 => .{
            .title = "genvar loop did not terminate",
            .lrm = "6.6.1",
            .explain =
            \\LRM 6.6.1: "It shall be an error if the loop does not terminate"
            \\and "if a genvar value is repeated during evaluation". The genvar
            \\is the scheme's whole state, and a 3.2 integer, so a scheme either
            \\ends or comes back to a value it had with its condition still
            \\true, and from there runs the same way forever. VerA follows the
            \\condition and step alone, before any copy of the body is made,
            \\until one or the other happens (Brent's cycle detection), and
            \\names the value that repeats. A loop that ends is unrolled in
            \\full however many iterations it takes; there is no count.
            \\
            \\Integer arithmetic wraps at 32 bits (3.2), so `i = i - 1` under
            \\`i < 3` ends after 2^31 + 1 iterations rather than repeating:
            \\write the condition the loop means.
            ,
        },
        .E0421 => .{
            .title = "access function is not allowed in this context",
            .lrm = "4.7.2",
            .explain =
            \\LRM 4.7.2 keeps analog functions pure: the body "shall not
            \\contain" branch contributions, access functions, or analog
            \\operators, because a function is evaluated as a value, not as
            \\part of the equation system.
            \\
            \\Pass the probed value in as an argument.
            ,
        },
        .E0422 => .{
            .title = "analog operator is not allowed in this context",
            .lrm = "4.5.15",
            .explain =
            \\Analog operators (ddt, idt, transition, slew, laplace_*, zi_*,
            \\...) carry state across timepoints, so they must be evaluated
            \\once per timepoint at a fixed place in the block.
            \\
            \\LRM 4.5.15 therefore bars them from analog function bodies and
            \\from any context whose execution count is not fixed. LRM 5.8.4
            \\states the related rule for conditionals: an analog filter may
            \\not sit inside a conditionally executed contribution.
            ,
        },
        .E0423 => .{
            .title = "both quantities of a probe branch are read",
            .lrm = "5.4.2.1",
            .explain =
            \\LRM 1.3.1: "The potential and flow of a probe branch may not both
            \\appear in expressions in a given module." LRM 5.4.2.1 repeats it
            \\with the word: "Using both the potential and the flow of a probe
            \\branch is illegal."
            \\
            \\A branch is a probe when nothing is contributed to it (LRM
            \\1.3.1). LRM 5.4.2.1 then pins ONE of its quantities at zero — the
            \\potential of a flow probe, the flow of a potential probe — and
            \\which one is decided by which the module reads. Reading both asks
            \\for two zeros at once and no branch satisfies that.
            \\
            \\Contribute to the branch to make it a source (LRM 5.4.2.2 then
            \\makes both quantities accessible), or read only one.
            ,
        },

        .E0424 => .{
            .title = "a special floating point value reaches a branch",
            .lrm = "7.3.2.1",
            .explain =
            \\LRM 7.3.2.1: "Floating point arithmetic can produce special values
            \\representing plus and minus infinity and Not-a-Number (NaN) to
            \\represent a bad value. While use of these special numbers in
            \\digital expressions is not an error, it is illegal to assign these
            \\values to a branch through contribution in the analog context."
            \\
            \\A branch value is a row of the residual the solver factors. An
            \\infinity or a NaN in that row destroys the whole matrix, not just
            \\the one entry, so the clause bans it at the contribution rather
            \\than leaving it to be discovered at the first Newton step.
            \\
            \\Only the case that FOLDS is caught here: 1.0/0.0, -1.0/0.0 and
            \\0.0/0.0 are IEEE 754 results of the source's own arithmetic and
            \\are known at compile time. A value that only becomes infinite at
            \\runtime is the finiteness proof's business (see W0650), which is a
            \\warning about what cannot be ruled out and not this rule.
            ,
        },
        .E0425 => .{
            .title = "contribution to an `input` signal-flow port",
            .lrm = "1.3.4.1",
            .explain =
            \\LRM 1.3.4.1: "In that case, potential contributions may not be
            \\made to `input` ports." 1.3.4.2: "Flow contributions may not be
            \\made to input ports in this case."
            \\
            \\A signal-flow port carries one quantity, so its direction IS the
            \\direction of that quantity: an `input` is a value the enclosing
            \\netlist supplies and the module reads. A contribution drives it,
            \\which would make the module and its driver two sources of one
            \\value with nothing to reconcile them — the conservation law that
            \\settles that argument on a conservative net (1.3.1) does not exist
            \\here.
            \\
            \\Contribute to an `output` port instead, and read the input.
            \\
            \\The DECLARATION is legal: a signal-flow discipline on a directional
            \\port is exactly the intended shape. Only the contribution target
            \\is wrong.
            ,
        },
        .E0426 => .{
            .title = "contribution inside a runtime loop",
            .lrm = "5.9",
            .explain =
            \\LRM 5.9, the third of three blanket restrictions on `repeat`,
            \\`while` and the non-genvar `for`: "Contribution statements are
            \\not allowed."
            \\
            \\A device's set of branches is fixed before the solve begins, and
            \\a runtime trip count is not — the number of equations may not
            \\depend on data. The 5.9.3 genvar `for` is exempt because its trip
            \\count is known at elaboration and the loop is unrolled, so the
            \\branches it stamps are all there before the first iteration.
            \\
            \\Accumulate into a variable in the loop and contribute once after
            \\it, or make the loop a genvar loop.
            ,
        },
        .E0427 => .{
            .title = "more than one `default` arm in a case statement",
            .lrm = "5.8.3",
            .explain =
            \\LRM 5.8.3: "The default statement is optional. Use of multiple
            \\default statements in one case statement is illegal."
            \\
            \\Nothing in the clause orders the arms, so a second `default`
            \\leaves the fall-through undefined rather than merely redundant.
            \\Merge them, or give one of them its own label list.
            ,
        },
        .E0428 => .{
            .title = "a generate scheme is not a constant expression",
            .lrm = "6.6",
            .explain =
            \\LRM 6.6, verbatim: "All expressions in generate schemes shall be
            \\constant expressions, deterministic at elaboration time."
            \\
            \\A generate scheme decides what the module CONTAINS, so it has to be
            \\answerable before there is a solution to read: an if-generate
            \\condition, a case-generate selector, and a loop generate's
            \\initialization, condition and step (E0417-E0419). A module variable
            \\or a probe is none of those — the LRM gives such a construct no
            \\semantics at all, which is why this is an error and not a fallback
            \\to a run-time branch.
            \\
            \\A `parameter` IS a constant expression here (A.8.4
            \\constant_primary, and 6.6's whole purpose is "the ability for
            \\parameter values to affect the structure of the model"), so a
            \\parameterized scheme is accepted.
            \\
            \\For a choice that depends on a solver value, write an ordinary
            \\`if` or `case` inside the analog block — but note 5.8.1's
            \\restrictions on analog operators under a non-constant condition.
            ,
        },
        .E0429 => .{
            .title = "incompatible array assignment",
            .lrm = "5.7",
            .explain =
            \\LRM 5.7: "Array assignments shall only be done with arrays that are
            \\compatible. An array, or a slice of such an array, shall be
            \\assignment compatible with any other such array or slice if all the
            \\following conditions are satisfied:
            \\
            \\  - The element types of source and target shall be equivalent.
            \\  - Every dimension of the source array shall have the same number
            \\    of elements as the target array."
            \\
            \\The count is of ELEMENTS, not of indices, which is the clause's own
            \\worked example:
            \\
            \\    int A[10:1];   int B[0:9];   int C[24:1];
            \\    A = B;         // ok. Compatible type and same size
            \\    A = C;         // type check error: different sizes
            \\
            \\Assign the elements one at a time if the shapes genuinely differ —
            \\there is no truncating or padding form of this statement.
            \\
            \\The clause also requires: "The arrays on the LHS and the RHS of the
            \\assignment must be unpacked." A packed vector (`reg [1:0] B`) or a
            \\scalar on the right of a whole array is refused here too.
            ,
        },
        .E0430 => .{
            .title = "analog function called outside the analog context",
            .lrm = "4.7.3",
            .explain =
            \\LRM 4.7.3: an analog user-defined function "shall only be called
            \\within the analog context, either from an analog block or from
            \\within another analog user-defined function". LRM 7.3.7 states the
            \\mixed-signal half: an analog function is not available to a
            \\discrete process.
            \\
            \\The restriction follows from what an analog function IS. LRM 4.7.1
            \\denies it access functions, filters and contribution statements
            \\precisely so that it is a pure value computation ON THE ANALOG
            \\SOLVER'S TIMELINE. An `initial` block runs once before the solve
            \\and an `always` block runs on the digital kernel's own events, so
            \\neither has a timepoint at which the function's value is defined.
            \\
            \\Move the call into the analog block, or into another analog
            \\function that the analog block calls.
            ,
        },
        .E0431 => .{
            .title = "digital value read from an analog initial block",
            .lrm = "5.2.1",
            .explain =
            \\LRM 5.2.1: "Additionally, digital values cannot be accessed from
            \\the analog initial block as they have not yet been assigned when
            \\the analog initial block is executed."
            \\
            \\The rule is about ORDER, not about types. LRM 7.2.2 gives a
            \\variable the domain of the context that assigns it, so a variable
            \\written by an `initial` or `always` block is digital-owned; the
            \\analog initial block runs before any digital process has run, so
            \\such a read has no value to return and would silently produce the
            \\type's zero.
            \\
            \\Read it from the ordinary analog block instead — LRM 7.3.1 Table
            \\7-1 defines that direction — or make the value a parameter or a
            \\localparam if it is genuinely constant.
            ,
        },
        .E0432 => .{
            .title = "variable assigned in both contexts",
            .lrm = "7.2.2",
            .explain =
            \\LRM 7.2.2: "A given variable can be assigned values only in one
            \\context or the other, but not in both. The domain of a variable is
            \\that of the context from which its value is assigned", stated again
            \\two paragraphs later as "It shall be an error to assign to a given
            \\variable in both contexts."
            \\
            \\The two contexts are the CONTINUOUS one (statements in an `analog`
            \\block) and the DISCRETE one (statements in an `initial` or `always`
            \\block). A variable written from both has no domain, so no rule in
            \\clause 7 can say when its value is defined or which kernel owns its
            \\storage.
            \\
            \\Pick one writer. Reading a variable from the other context stays
            \\legal, and is what LRM 7.3.1 Table 7-1 is the conversion table for.
            ,
        },
        .E0433 => .{
            .title = "statement in an initial block is not a constant assignment",
            .lrm = "7.2.2",
            .explain =
            \\A.6.2's `initial_construct ::= initial statement` is legal
            \\Verilog-AMS, and an `initial` block is a digital process whether or
            \\not it has a timing control (IEEE 1364-2005 9.9.1, via LRM 1.1).
            \\VerA runs it in one of two ways. A body of assignments of constant
            \\expressions to scalar module variables is folded: LRM 7.2.2's "the
            \\domain of a variable is that of the context from which its value is
            \\assigned" gives the target to the discrete context, the block runs
            \\once before the analysis, so the variable holds that constant for the
            \\whole analysis and LRM 7.3.1 Table 7-1 says how the continuous
            \\context reads it. Any other body (a system task, a loop, a
            \\non-constant right-hand side, an array element, a delay) runs on the
            \\mixed-signal kernel (LRM 8.5), exactly as the same body behind `#0`.
            \\
            \\This error is the gap between the two: a right-hand side built only
            \\from literals, parameters and constant functions whose value still
            \\does not fold. Write the value as a constant, or as a parameter
            \\(LRM 3.4).
            ,
        },
        .E0434 => .{
            .title = "`->` is not an analog statement",
            .lrm = "A.6.4",
            .explain =
            \\A.6.4 derives `analog_statement` without an `event_trigger`
            \\alternative — `event_trigger` is listed one production over, under
            \\`analog_event_statement`, next to `disable_statement` (E0401). So
            \\the only form an analog block admits is the event statement
            \\
            \\    @(<event>) -> ev;
            \\
            \\which is the spelling LRM 5.10.4's own example uses.
            \\
            \\A bare trigger would have to mean "this event is active at every
            \\timepoint", which hands the event's rate to the solver's step
            \\control rather than to the model.
            ,
        },

        .E0435 => .{
            .title = "a continuous net cannot be written from a discrete context",
            .lrm = "7.3",
            .explain =
            \\LRM 7.3 draws the line in one sentence: "Read operations of nets
            \\and variables in both domains are allowed from both contexts.
            \\WRITE operations of nets and variables are only allowed from the
            \\context of their domain."
            \\
            \\So `V(p) <+ ...` inside an `always` or `initial` block is not a
            \\contribution the simulator can place: §7.2.1 assigns potentials
            \\and flows to the CONTINUOUS domain, and if a digital process
            \\could contribute to a branch then both kernels would own that
            \\node's equation and neither would be solving it.
            \\
            \\§7.3.3 states the permitted half from the other side — "All
            \\continuous nets can be PROBED from a discrete context using
            \\access functions". Probed, not driven. Syntax 7-3 likewise
            \\admits an analog event into a digital sensitivity list without
            \\admitting a contribution into a digital statement.
            \\
            \\This is NOT E0432 (§7.2.2, "assigned in both contexts"), which
            \\is about a variable with two writers and fires only when both
            \\exist. Here there is one writer and it is in the wrong domain.
            \\
            \\Move the contribution into the `analog` block and let the
            \\digital process set a variable the analog block reads — that
            \\read is §7.3's legal direction and Table 7-1 is its conversion.
            ,
        },

        .E0436 => .{
            .title = "a digital function cannot be called from the analog context",
            .lrm = "7.3.7",
            .explain =
            \\LRM 7.3.7 is two sentences and this is the first: "Digital
            \\functions cannot be called from within the analog context.
            \\Analog functions cannot be called from within the digital
            \\context." E0430 is the second.
            \\
            \\The DECLARATION is legal. LRM 4.7 says "Each function can be an
            \\analog user-defined function or a digital function (as defined
            \\in IEEE Std 1364 Verilog)", so a module may hold a digital
            \\function and call it from a digital process; what it may not do
            \\is call it from an `analog` block. The diagnostic therefore
            \\lands on the CALL, never on the `function` keyword.
            \\
            \\A digital function runs in the discrete domain: it is evaluated
            \\once per event, and the analog kernel would have to call it once
            \\per Newton iterate with no event to attach the result to.
            \\
            \\Write `analog function` if the body is analog — it is inlined
            \\into the contribution and its arguments are solver values. If
            \\the body genuinely belongs to the discrete domain, let the
            \\digital process call it and have the analog block read the
            \\variable it wrote (LRM 7.3's legal direction, Table 7-1).
            ,
        },

        .E0437 => .{
            .title = "this discrete process needs a mixed-signal kernel feature VerA does not implement",
            .lrm = "8.5",
            .explain =
            \\The source is legal Verilog-AMS. A module may hold `always` blocks,
            \\continuous `assign`s and timed `initial` blocks beside its `analog`
            \\block (LRM 7.2.2), and LRM 8.5 defines how the two kernels run them
            \\together: the digital events of each time tick execute in the
            \\stratified queue of 8.5.1, and an analog macro-process that reads a
            \\digital value is re-solved when that value changes (8.5, the
            \\implicit D2A event).
            \\
            \\The message names the part of that machinery the construct needs and
            \\VerA does not have. It is a statement about this compiler, not about
            \\the source: the construct becomes accepted when the named feature
            \\lands, and the fixtures that pin it are written to flip then.
            ,
        },

        .E0438 => .{
            .title = "a continuous assignment drives a net, not a variable",
            .lrm = "A.6.1",
            .explain =
            \\A.6.1 derives `continuous_assign ::= assign list_of_net_assignments ;`
            \\with `net_assignment ::= net_lvalue = expression`, and IEEE Std
            \\1364-2005 6.1 (part of Verilog-AMS by LRM 1.1) says why: a
            \\continuous assignment is a DRIVER, and only a net has drivers to
            \\resolve. A variable holds the last value a procedural statement
            \\stored in it.
            \\
            \\Declare the target as a net (`wire`), or assign the variable from
            \\an `always` block.
            ,
        },
        .E0439 => .{
            .title = "hierarchical contribution changes the branch into a switch branch",
            .lrm = "5.6.8.2",
            .explain =
            \\LRM 5.6.8.2 allows a hierarchical direct contribution to a branch
            \\"provided that the branch is suitable for such contributions", and
            \\lists the reasons it is not, among them: "The hierarchical
            \\contribution changes the branch into a switch branch."
            \\
            \\Inside one module, a flow contribution after a potential one is
            \\5.6.1.3's value retention: the module decides, per iteration, which
            \\kind the branch is (5.6.5). Across a module boundary nothing orders
            \\the two analog blocks, so which kind wins is not defined, and the
            \\clause forbids it. Contribute the same access function the owning
            \\module does, or move the decision into that module.
            ,
        },
        .E0440 => .{
            .title = "`break` or `continue` inside an analog for loop",
            .lrm = "5.11",
            .explain =
            \\LRM 5.11: "The continue and break statements cannot be used inside
            \\an analog for loop. Refer 5.9.3." An analog_for's genvar control is
            \\unrolled at elaboration, so there is no runtime iteration for the
            \\jump to leave or skip.
            \\
            \\Nest a procedural `for` (5.9.2) on an integer variable inside the
            \\analog_for and jump out of that, or move the condition into an
            \\`if` around the rest of the body.
            ,
        },
        .E0477 => .{
            .title = "contributions from two module instances close a loop of potential sources",
            .lrm = "5.6.8.1",
            .explain =
            \\LRM 5.6.8.1: "The simulator shall check if the contribution produces
            \\a solvable set of equations, e.g. no voltage source loops created."
            \\5.6.8.2 says the same of hierarchical contributions to a child's
            \\branches.
            \\
            \\A hierarchical contribution creates a NEW unnamed branch in the
            \\module that writes it (5.6.8.1), so `V(drv.x) <+ 1.8` in a parent
            \\sits in parallel with any potential source the instance `drv`
            \\already has on `x`. Two potential sources around one loop fix the
            \\loop's potentials twice (Kirchhoff's voltage law) and leave the
            \\flows around it undetermined, whatever the values, so the system
            \\has no unique solution.
            \\
            \\Only loops that are a potential source on every path are checked: a
            \\switch branch (5.6.5) that is sometimes a flow source is not a loop.
            \\Contribute a flow instead, or contribute to the instance's own
            \\branch (5.6.8.2), which accumulates rather than adding a branch.
            ,
        },

        // ------------------------------------------------------------ class 5
        .E0501 => .{
            .title = "unknown access function",
            .lrm = "3.6.1.2",
            .explain =
            \\An access function name comes from the `access` attribute of a
            \\nature (LRM 3.6.1.2), reached through the discipline bound to the
            \\net. `V` and `I` come from annex D's `disciplines.vams`.
            \\
            \\LRM 4.4 requires that "the access function name shall match the
            \\discipline declaration for the nets, ports, or branch": using
            \\`V` on a net whose discipline binds a differently-named potential
            \\nature is this error, not a silent coercion.
            ,
        },
        .E0502 => .{
            .title = "ddt() requires an argument",
            .lrm = "4.5.3",
            .explain = "`ddt(expr)` differentiates its operand with respect to time.",
        },
        .E0503 => retiredInfo(
            \\"ddt() must be a linear factor of a contribution". Retired: a term
            \\whose ddt is not a linear factor, such as sin(ddt(V(a,b))), is now
            \\resistive, and each ddt in it is one of the new unknowns 4.5.2 lets
            \\an analog operator introduce, with its own row and charge site. So
            \\the condition does not exist to report. The number is not reused.
        ),
        .E0504 => .{
            .title = "ddx() second argument must be an access function",
            .lrm = "4.5.6",
            .explain =
            \\`ddx(expr, V(n))` takes the symbolic partial derivative of expr
            \\with respect to one probe, so the second argument names that
            \\probe and nothing else.
            ,
        },
        .E0505 => .{
            .title = "analog operator does not accept an empty argument",
            .lrm = "4.5.14",
            .explain =
            \\An omitted argument in an analog operator's list means "use the
            \\default". This operator has no default for that position.
            ,
        },
        .E0506 => .{
            .title = "wrong number of arguments to a math function",
            .lrm = "4.3",
            .explain =
            \\LRM 4.3 tables 4-14 and 4-15 fix each math function's arity.
            \\Note `atan2(y, x)` and `hypot(x, y)` take two, while `min`, `max`
            \\and `pow` also take two.
            ,
        },
        .E0507 => .{
            .title = "port access function must be a flow access",
            .lrm = "5.4.3",
            .explain =
            \\`I(<p>)` reads the flow INTO port p from outside the module. A
            \\potential has no such directional meaning at a port boundary, so
            \\the `<...>` form exists only for the flow access function of the
            \\port's discipline.
            \\
            \\For a potential, probe the node: `V(p)`.
            ,
        },
        .E0508 => .{
            .title = "port access function names a net that is not a port",
            .lrm = "5.4.3",
            .explain =
            \\`I(<p>)` measures flow across the module boundary, so p must be
            \\in the module's port list. An internal net has no outside.
            ,
        },
        .E0509 => .{
            .title = "assignment pattern is only legal where an array is expected",
            .lrm = "4.5.11",
            .explain =
            \\The assignment pattern `'{...}` (LRM 4.2.14) is an array value, so
            \\it is accepted only where an array is expected: a Laplace or
            \\Z-transform coefficient vector (4.5.11, 4.5.12), an array
            \\parameter or variable, an array argument. Used as an ordinary
            \\operand it has no value:
            \\
            \\    transition('{1.0, 2.0})            // no: a scalar slot
            \\    laplace_nd(V(p), '{1.0}, '{1.0, 1.0})   // yes
            \\
            \\The plain concatenation `{...}` (4.2.13) is a different operator
            \\and is a value anywhere; in a filter coefficient slot it is E0572.
            ,
        },
        .E0510 => .{
            .title = "recursive analog function",
            .lrm = "4.7.1",
            .explain =
            \\Analog functions are inlined at every call site, so recursion has
            \\no base case to stop the inliner. A compiled device has no call
            \\stack at run time.
            \\
            \\Rewrite as a loop, or unroll to a fixed depth.
            ,
        },
        .E0511 => .{
            .title = "wrong number of arguments to an analog function",
            .lrm = "4.7.2",
            .explain =
            \\An analog function call supplies exactly one actual argument per
            \\declared formal, in order. There are no defaults and no varargs.
            ,
        },
        .E0512 => .{
            .title = "unknown function",
            .lrm = "4.7",
            .explain =
            \\No analog function, math function or analog operator with this
            \\name is in scope. An analog function must be defined in the same
            \\module, before use.
            ,
        },
        .E0513 => .{
            .title = "absdelta() is only allowed in an initial or always block",
            .lrm = "5.10.3.4",
            .explain =
            \\LRM 5.10.3.4: "This function is only allowed in an initial or
            \\always block of a Verilog-AMS module." It samples an analog
            \\signal for DIGITAL code: each change of more than `delta` is an
            \\A2D event scheduled in the digital queue (8.4.6), which an
            \\analog event control has no use for.
            \\
            \\Move the sampler into a digital process:
            \\
            \\    always @(absdelta(V(in), 0.1)) sampled = V(in);
            \\
            \\In the analog block, `cross` or `above` detect a threshold, and
            \\`$bound_step` (LRM 9.17.2) bounds the timestep.
            ,
        },
        .E0514 => .{
            .title = "analog operator under a condition that can change during the solve",
            .lrm = "5.8.1",
            .explain =
            \\LRM 5.8.1: "If any of the conditionally-executed statements
            \\contains an analog operator, the conditional expression shall be
            \\a analysis_or_constant_expression." LRM 5.9 states the same ban
            \\for `repeat`, `while` and non-genvar `for`, without the carve-out.
            \\LRM 4.5.15 names the three conditional forms it covers — "inside
            \\conditional (if, case, or ?:) statements" — so an operator in an
            \\ARM of a `?:` is this rule too, and for the sharpest reason: 4.2.3
            \\makes `?:` short-circuiting, so the arm that is not selected is
            \\not evaluated at all.
            \\
            \\An analog operator is a STATE MACHINE, not a function: `ddt`,
            \\`idt`, `transition`, `slew`, `absdelay`, `laplace_*` and `zi_*`
            \\each carry history from one accepted timestep to the next. The
            \\generated device advances that history once per step, on the
            \\straight-line spine of the analog block. When the operator sits
            \\under a runtime branch, the step on which the branch is off feeds
            \\it the type's zero instead of the real input, so its history is
            \\wrong from then on — and it stays wrong after the branch comes
            \\back. Nothing about the residual looks unusual; the answer is
            \\just no longer the one the source describes.
            \\
            \\THREE CONDITIONS ARE LEGAL and do not warn:
            \\
            \\    if (analysis("dc"))  ...   // analysis_function_call
            \\    if (some_parameter)  ...   // constant_primary: a parameter
            \\    for (i = 0; i < 4; i = i + 1) ...   // genvar: unrolled
            \\
            \\None of them can change while the solve is running, so the
            \\operator's branch is decided once and its history stays whole.
            \\
            \\TO FIX: hoist the operator out of the branch and switch its
            \\RESULT instead of its execution —
            \\
            \\    tmp = ddt(V(a));               // always stepped
            \\    if (en) I(a) <+ tmp;           // only the use is conditional
            \\
            \\`--deny=E0514` makes this the error LRM 5.8.1 says it is. It is a
            \\warning by default only because rejecting it outright would stop
            \\compiling foundry models that have shipped with the bug for years.
            ,
        },
        .E0515 => .{
            .title = "analog operator control argument is not a constant or parameter expression",
            .lrm = "4.5",
            .explain =
            \\The CONSTANT arguments of a §4.5 analog operator (Table 4-20's
            \\"constant expression arguments": the delay, rise/fall times and
            \\time_tol of `transition`, the slew rates of `slew`, a ddt or idt
            \\abstol, the period of a `zi_*` filter) are evaluated by the HOST,
            \\outside the derivative domain the residual is computed in. VerA
            \\renders them as plain f64 expressions over `Model`, so they may be
            \\built from literals, parameters and card-time `$simparam` answers,
            \\through arithmetic, comparisons, `?:` and the math functions.
            \\Anything else has no value at that point.
            \\
            \\An argument that depends on a NODE VOLTAGE is the usual cause, and
            \\it is not a spelling problem: the operator's history is advanced
            \\once per accepted timestep, before the Newton iteration that would
            \\produce such a value.
            \\
            \\    transition(V(a), 0, V(c))        // no: a solve result
            \\    transition(V(a), 0, tr*1e-9)     // yes: parameters only
            \\
            \\A value assigned into a `real` variable first is fine — the
            \\expression is resolved through SSA, not by spelling — but one that
            \\merges two different values on two arms of a runtime `if` is not.
            \\
            \\Table 4-20's DYNAMIC arguments are not this code: `absdelay`'s td
            \\(frozen at its first evaluation without maxdelay, §4.5.7, clamped
            \\to maxdelay with it), `idt`'s ic and assert, `idtmod`'s ic, modulus
            \\and offset. Nor are a filter's coefficients or a signal-valued
            \\`maxdelay`, which §4.5.14 samples at the start of the analysis.
            ,
        },
        .E0516 => .{
            .title = "analog operator argument is outside the range the LRM allows",
            .lrm = "4.5",
            .explain =
            \\Each §4.5 operator states the bound on its control arguments in
            \\one sentence, and each bound is what makes the operator's contract
            \\satisfiable at all:
            \\
            \\  4.5.5  idtmod        "The modulus shall be an expression which
            \\                       evaluates to a positive value." The output
            \\                       range is offset <= idtmod < offset+modulus,
            \\                       which is empty unless modulus > 0.
            \\  4.5.7  absdelay      "In all cases td shall be a positive
            \\                       number." A negative delay asks a history
            \\                       buffer for the future.
            \\  4.5.8  transition    "td, rise_time, fall_time, and time_tol are
            \\                       optional, but if specified shall be
            \\                       non-negative." Zero is allowed and 4.5.8
            \\                       says what each zero means; negative would
            \\                       end a ramp before it starts.
            \\  4.5.9  slew          "max_pos_slew_rate shall be greater than
            \\                       zero (0) and max_neg_slew_rate shall be
            \\                       less than zero (0)." The signs are what say
            \\                       which limit is which.
            \\  4.5.10 last_crossing "The optional direction indicator shall
            \\                       evaluate to an integer expression +1, -1,
            \\                       or 0." An enumeration, not a range.
            \\
            \\Only arguments that FOLD are checked. These slots are typed
            \\analog_expression, so a rise time written over a parameter is
            \\legal and its sign is not knowable here; VerA stays silent rather
            \\than reject what it cannot prove.
            ,
        },
        .E0517 => .{
            .title = "monitored event argument is the wrong type or out of range",
            .lrm = "5.10.3",
            .explain =
            \\LRM 5.10.3.1 constrains cross()'s optional arguments:
            \\
            \\  "The dir and enable arguments, if specified, shall evaluate to
            \\   integers." 0 or absent is both edges, +1 rising, -1 falling.
            \\  "The tolerances (time_tol and expr_tol) ... shall be
            \\   non-negative." A tolerance is the window the crossing time is
            \\   narrowed into; a negative one names an empty window.
            \\  "If either or both tolerances are defined, then the direction
            \\   shall also be defined." A tolerance selects how precisely a
            \\   crossing is resolved, and which crossings count is the
            \\   direction's job — a tolerance without one narrows nothing.
            \\  "If expr_tol is specified, time_tol shall also be specified."
            \\   Supplying only expr_tol leaves the required time bound absent.
            \\
            \\LRM 5.10.3.2 gives above() the same tolerances and no direction,
            \\and 5.10.3.3 gives timer() the same time_tol sentence verbatim.
            \\LRM 5.10.3.4 requires absdelta()'s delta and both tolerances to
            \\be non-negative, and its enable to evaluate to an integer.
            \\Its numeric checks leave model-card and runtime values to
            \\evaluation; a real-valued 1.0 is integral, but 0.5 is not.
            \\
            \\Eliding a slot is not itself an error: Syntax 5-16 types them
            \\analog_expression_or_null and 5.10.3.1's own `sh` example writes
            \\`cross(V(smpl) - thresh, dir, , , en === 1'b1)`. The last slot,
            \\the enable, is analog_expression (A.6.5), so a comma before it
            \\promises one: `timer(0, 1n, 1p, )` is refused.
            \\
            \\A string-typed value (a `string` variable or parameter, 3.3) has
            \\no number to monitor. A string literal does: 2.7 reads it as an
            \\unsigned integer constant, so `cross("s")` monitors 115.
            ,
        },
        .E0518 => .{
            .title = "a zero-transition-time Z-filter cannot be contributed to a branch",
            .lrm = "4.5.12",
            .explain =
            \\LRM 4.5.12, verbatim: "If the transition time is specified as zero
            \\(0), then the output is abruptly discontinuous. A Z-filter with
            \\zero (0) transition time shall not be directly assigned to a
            \\branch."
            \\
            \\The zero transition time is not the error. The same clause makes
            \\the argument optional and "nonnegative", and reading the
            \\discontinuous output into a variable is legal:
            \\
            \\    real y;
            \\    analog begin
            \\      y = zi_zp(V(p, n), '{0.0, 0.0}, '{0.5, 0.0}, 1u, 0.0);
            \\      I(p, n) <+ y;
            \\    end
            \\
            \\What the clause bans is the discontinuity landing directly in the
            \\equation system, where a branch quantity that steps
            \\instantaneously has no derivative for Newton-Raphson to work with.
            ,
        },
        .E0519 => .{
            .title = "noise table is not a usable (frequency, power) table",
            .lrm = "4.6.4.3",
            .explain =
            \\LRM 4.6.4.3: "When the input is a vector it contains pairs of real
            \\numbers: the first number in each pair is the frequency in Hertz
            \\and the second is the power. The vector can either be specified as
            \\an array parameter or an array assignment pattern." And: "Each
            \\frequency value must be unique."
            \\
            \\So a table is an EVEN number of values, at least one pair, with
            \\distinct positive frequencies and non-negative powers. Ordering is
            \\NOT one of the rules — the same clause says "the simulator shall
            \\internally sort the pairs into ascending frequency if required",
            \\and VerA sorts at compile time, so a descending table compiles.
            \\
            \\4.6.4.4's noise_table_log interpolates log(power), so it wants
            \\every power strictly positive as well; log(0) is not a point on a
            \\log-log line.
            \\
            \\All four of A.8.2's `noise_table_input_arg` spellings are
            \\accepted, so the rules above are the whole of what this reports.
            \\
            \\The file form, `noise_table("noise.tbl")`, is read at COMPILE
            \\time: 4.6.4.3 says "the file name argument shall be constant", so
            \\the pairs behind it are compile-time data too, and the name is
            \\resolved against the include path exactly as 9.21's $table_model
            \\data source is. The errors above can therefore also come from the
            \\file's own contents.
            \\
            \\An array PARAMETER is a table the model CARD owns. `noise_tables`
            \\carries its declared defaults, which is all comptime data can
            \\hold, and a `noiseTablePoints(model)` hook beside it carries the
            \\card's own knots; the rules above are checked on the defaults, so
            \\a frequency a card duplicates is the host's problem and not this
            \\diagnostic's.
            \\
            \\The shortest spelling that satisfies every rule above is an
            \\assignment pattern of literals:
            \\
            \\    I(p, n) <+ noise_table('{1.0, 1e-18, 1e6, 1e-24});
            ,
        },
        .E0520 => .{
            .title = "noise generator has no branch to sit on",
            .lrm = "4.6.4",
            .explain =
            \\LRM 1.3.1.1 makes ground the reference node: it is not an unknown
            \\of the system, so it has no row and no column. A contribution
            \\between ground and ground therefore names NO branch — there is
            \\nothing for a current to flow through and nothing for a voltage to
            \\be measured across.
            \\
            \\For the large-signal residual that is harmless, and VerA drops
            \\such a contribution silently: KCL at the reference node is the one
            \\equation the solver does not write. A NOISE generator is different
            \\because it is EXPORTED — `noise_gens` names the (row, col) a host
            \\stamps the generator into, and this one has neither. Dropping it
            \\would delete a declared noise source from the model without
            \\telling anyone, and inventing a row would put noise on a branch
            \\the model never wrote.
            \\
            \\Contribute the source to a real branch: give the generator a node
            \\that is an unknown of the system, even if the other end is ground.
            ,
        },
        .E0521 => .{
            .title = "ac_stim analysis name is not a string literal",
            .lrm = "A.8.2",
            .explain =
            \\A.8.2 writes the quotation marks into the production:
            \\
            \\    ac_stim ( [ " analysis_identifier " [ , analog_expression
            \\                                        [ , analog_expression ] ] ] )
            \\
            \\so the analysis name is a string literal. 4.6.3 makes it select
            \\the small-signal analysis the source is active in, which the
            \\simulator resolves before it solves. A string parameter is allowed
            \\where the LRM says so (4.6.4.3's noise table file name), not here.
            \\
            \\    I(p, n) <+ ac_stim("ac", 2.0, 0.0);
            ,
        },
        .E0522 => .{
            .title = "flicker_noise requires an exponent",
            .lrm = "4.6.4.2",
            .explain =
            \\Syntax 4-4 brackets only the name:
            \\
            \\    flicker_noise ( analog_expression , analog_expression [ , string ] )
            \\
            \\and 4.6.4.2's "pink noise with a power of pwr at 1Hz which varies
            \\in proportion to 1/f^exp" gives the exponent no default. A flat
            \\spectrum is `white_noise(pwr)`; a 1/f source says so:
            \\
            \\    I(p, n) <+ flicker_noise(kf, 1.0);
            ,
        },
        .E0523 => .{
            .title = "vera_lte needs a constant value",
            .lrm = "2.9",
            .explain =
            \\`(* vera_lte = <value> *)` is VerA's attribute for leaving a
            \\charge (a `ddt` site, 5.6.1.2) out of the host's local
            \\truncation-error check, the way SPICE device truncation routines
            \\leave junction charges out. 2.9 makes an attribute value a
            \\constant_expression; VerA additionally needs it before the model
            \\card exists, because the answer is a compile-time table
            \\(`q_lte`). So it may not name a parameter:
            \\
            \\    (* vera_lte = 0 *) I(b, s) <+ ddt(qbs);   // excluded
            \\    (* vera_lte *)     I(g, s) <+ ddt(qgs);   // 1: included
            \\
            \\The attribute is ignored and the site keeps the default (included).
            ,
        },
        .E0524 => .{
            .title = "vera_interp is 1 or 2",
            .lrm = "2.9",
            .explain =
            \\`(* vera_interp = <value> *)` is VerA's attribute for choosing how an
            \\`absdelay` (4.5.7) reads its history between accepted timepoints:
            \\1 is the clause's linear interpolation, 2 is 3-point Lagrange
            \\(quadratic), the reading SPICE's lossless transmission line uses.
            \\The value picks the emitted kernel, so it must fold before the model
            \\card exists and may not name a parameter:
            \\
            \\    y = absdelay (* vera_interp = 2 *) (V(a), td);   // quadratic
            \\    (* vera_interp *) y = absdelay(V(a), td);        // 1: linear
            \\
            \\The attribute is ignored and the site keeps linear interpolation.
            ,
        },
        .E0525 => .{
            .title = "vera_nodiff needs a constant value",
            .lrm = "2.9",
            .explain =
            \\`(* vera_nodiff *)` is VerA's attribute for storing the value of
            \\every assignment inside a statement with no derivative, the frozen
            \\coefficient a SPICE load stamps (ngspice's `geq = ag0 * C`). `= 0`
            \\turns it off inside. The answer decides which derivatives the
            \\emitted device computes, so it must fold before the model card
            \\exists and may not name a parameter:
            \\
            \\    (* vera_nodiff *) begin capgs = capgs; end   // stopped
            \\    (* vera_nodiff = 0 *) c = c;                 // not stopped
            \\
            \\The attribute is ignored and the statement stores derivatives.
            ,
        },
        .E0526 => .{
            .title = "vera_nodiff covers a contribution",
            .lrm = "2.9",
            .explain =
            \\`(* vera_nodiff *)` stops the derivative of the ASSIGNMENTS inside
            \\it. A contribution inside it would leave its branch with no
            \\Jacobian at all, and Newton cannot move a branch it cannot see.
            \\Stop the coefficient instead and contribute outside:
            \\
            \\    (* vera_nodiff *) c = c;
            \\    I(p, n) <+ ddt(c * V(p, n));
            ,
        },
        .E0527 => .{
            .title = "$limit seed reads the solution",
            .lrm = "9.17.3",
            .explain =
            \\A string-form `$limit` takes, after its algorithm's arguments and
            \\its sign, an optional seed: the value the site's branch starts at
            \\before the first Newton iterate (SPICE's MODEINITJCT). 9.17.3
            \\leaves the algorithm's arguments to the implementation. A seed may
            \\read what the device computes from its card and temperature
            \\(mos1load.c's `tVto`), but it is evaluated before any solution
            \\exists, so it may not read a probe or anything computed from one:
            \\
            \\    vgs = type * $limit(V(g, si), "fetlimds", type * vonp, type, type * vtox);  // ok
            \\    vds = $limit(V(di, si), "limvds", 1, V(d, s));                              // no
            ,
        },
        .E0528 => .{
            .title = "changed timer control would repeat a side-effecting call",
            .lrm = "5.10.3.3",
            .explain =
            \\A timer's next event uses the latest start_time and period after
            \\the analog block finishes. VerA recomputes arithmetic, array reads
            \\and effect-free analog functions over their final dependencies.
            \\An input of a side-effecting call changed after the original call,
            \\so retaining its old return gives a stale schedule, while repeating
            \\it would repeat output/inout writes, random draws or file activity.
            \\That combination is an implementation limit, not illegal AMS.
            \\
            \\Compute the effectful call once into a variable before timer(),
            \\then use or update that variable as the timer control. An unchanged
            \\effectful call remains legal and is evaluated only at its original
            \\source position, including when other timer operands change.
            ,
        },
        .E0529 => .{
            .title = "vera_timepoint needs a constant value",
            .lrm = "2.9",
            .explain =
            \\`(* vera_timepoint *)` is VerA's attribute for running a statement
            \\once per timepoint: the first evaluation at a time runs it, and the
            \\later Newton iterations at that time read back what it assigned.
            \\`= 0` turns it off. The answer decides the code the device is built
            \\with, so it must fold before the model card exists and may not name
            \\a parameter:
            \\
            \\    (* vera_timepoint *) w = acc * exp(-h / tau);       // cached
            \\    (* vera_timepoint = 0 *) w = acc * exp(-h / tau);   // not cached
            \\
            \\The attribute is ignored and the statement runs every evaluation.
            ,
        },
        .E0530 => .{
            .title = "not allowed in a vera_timepoint statement",
            .lrm = "2.9",
            .explain =
            \\A `(* vera_timepoint *)` statement runs on the first evaluation of a
            \\timepoint only, and every later evaluation at that time reads back
            \\what it assigned. So it may hold only work whose result cannot move
            \\between Newton iterations, and nothing whose effect is more than its
            \\assignments. It may not contain a probe (4.4) or a `$limit` (9.17.3),
            \\which read the iterate; a contribution (5.6), whose branch would lose
            \\its Jacobian on a cached evaluation; an analog operator that keeps
            \\state (4.5); an event control or trigger (5.10); a system task; or an
            \\assignment to a string variable. Compute the per-timepoint values
            \\inside it and use them outside:
            \\
            \\    (* vera_timepoint *) begin e = exp(-h / tau); w = acc * e; end
            \\    I(p, n) <+ V(p, n) / r + w;
            ,
        },
        .E0531 => .{
            .title = "vera_timepoint statement reads a value that moves between iterations",
            .lrm = "2.9",
            .explain =
            \\A `(* vera_timepoint *)` statement is cached per timepoint, so every
            \\value it reads must be the same at every Newton iteration of that
            \\time: a parameter, `$abstime`, `analysis()`, a held (5.10) variable,
            \\or something computed from those alone. A variable assigned before
            \\the statement from a probe, or under a branch that tests one, is the
            \\iterate in disguise:
            \\
            \\    v = V(p, n);
            \\    (* vera_timepoint *) w = v * 2.0;       // no: v is the iterate
            \\    (* vera_timepoint *) w = tlast * 2.0;   // yes: tlast is held
            ,
        },
        .E0532 => .{
            .title = "vera_timepoint statement runs more than once per evaluation",
            .lrm = "2.9",
            .explain =
            \\A `(* vera_timepoint *)` statement keeps one cached copy of what it
            \\assigns per timepoint. Inside a loop (5.9) it runs several times per
            \\evaluation with different inputs; inside an analog function (4.7) it
            \\runs once per call; inside an `analog initial` block (5.2.1) it runs
            \\once per analysis, never per timepoint. Put the attribute on the
            \\loop, or outside the function's call:
            \\
            \\    (* vera_timepoint *) for (i = 0; i < 3; i = i + 1) e[i] = exp(-h * p[i]);
            \\
            \\The attribute is ignored and the statement runs every evaluation.
            ,
        },
        .E0533 => .{
            .title = "$vera_reject_step outside an analog block",
            .lrm = "2.8.3",
            .explain =
            \\`$vera_reject_step(t_retry)` is VerA's task for asking the host to
            \\reject the transient step it is accepting and retry it ending at
            \\`t_retry` (`contract.UpdateResult.request_reject_at`). `updateState`
            \\reads it off the accepted solution, so it means something only where
            \\a step is accepted: in an analog block. An `analog initial` block
            \\(5.2.1) runs once per analysis and an analog function (4.7) once per
            \\call, so neither has a step to reject:
            \\
            \\    analog begin
            \\        if (late) $vera_reject_step(t_edge);   // yes
            \\    end
            \\    analog initial $vera_reject_step(0.0);    // no
            ,
        },
        .E0534 => .{
            .title = "vera_scratch needs a constant value",
            .lrm = "2.9",
            .explain =
            \\`(* vera_scratch *)` is VerA's attribute for a variable that carries
            \\nothing from one evaluation to the next: every evaluation starts it
            \\at its declaration's initializer, the 3.2 zero when there is none.
            \\`= 0` turns it off. The answer decides whether the device keeps a
            \\slot for the variable, so it must fold before the model card exists
            \\and may not name a parameter:
            \\
            \\    (* vera_scratch *) real st[0:63];       // scratch
            \\    (* vera_scratch = 0 *) real st[0:63];   // held where observable
            \\
            \\The attribute is ignored and the variable is held where observable.
            ,
        },
        .E0535 => .{
            .title = "vera_scratch decorates something other than a variable",
            .lrm = "2.9",
            .explain =
            \\`(* vera_scratch *)` says a VARIABLE (3.2) starts every evaluation
            \\afresh. A parameter (3.4) is a constant, a net (3.6) or a genvar
            \\(3.5) holds no value an evaluation assigns, and a statement is not a
            \\declaration, so on any of those it would mean nothing:
            \\
            \\    (* vera_scratch *) real st[0:63];          // yes
            \\    (* vera_scratch *) parameter real k = 1;   // no
            ,
        },
        .E0536 => .{
            .title = "vera_scratch variable carries a value between evaluations",
            .lrm = "5.10",
            .explain =
            \\A `(* vera_scratch *)` variable starts every evaluation afresh. An
            \\`analog initial` block (5.2.1) runs on the first evaluation only, and
            \\an event statement (5.10) only on the evaluations its event fires, so
            \\a value either assigns is meant for the evaluations that do not run
            \\it. Where a read may see such a value, the variable must be held:
            \\
            \\    @(initial_step) k = 3.0;
            \\    y = k;   // no: k would read 0 on every later evaluation
            \\
            \\Drop the attribute, or assign the variable outside the event.
            ,
        },
        .E0537 => .{
            .title = "vera_scratch variable is written by a digital process",
            .lrm = "7.2.2",
            .explain =
            \\`(* vera_scratch *)` makes a variable start every ANALOG evaluation
            \\afresh. A variable an `initial` or `always` block or a task assigns
            \\belongs to the discrete context (7.2.2), where IEEE 1364-2005 4.2.2
            \\says variables "shall retain value until the next assignment". The
            \\digital kernel keeps that value, and no analog evaluation resets it,
            \\so the attribute would do nothing:
            \\
            \\    (* vera_scratch *) real t;
            \\    always @(posedge clk) t = 1.0;   // no: t is digital-owned
            \\    analog t = V(p, n);               // yes, when only analog writes t
            ,
        },
        .E0538 => .{
            .title = "vera_scratch string value is not \"uninit\"",
            .lrm = "2.9",
            .explain =
            \\`(* vera_scratch *)` takes a number (nonzero on, `0` off) or the one
            \\string `"uninit"`, which drops even the per-evaluation zero start: the
            \\author promises every element is written before it is read in the
            \\same evaluation. Any other string is a misspelling, not a mode:
            \\
            \\    (* vera_scratch = "uninit" *) real st[0:63];   // yes
            \\    (* vera_scratch = "zero" *) real st[0:63];     // no
            \\
            \\The attribute is ignored and the variable is held where observable.
            ,
        },
        .E0539 => .{
            .title = "vera_scratch = \"uninit\" variable has an initializer",
            .lrm = "2.9",
            .explain =
            \\`(* vera_scratch = "uninit" *)` says the variable starts every
            \\evaluation with no value at all; a declaration initializer says it
            \\starts at that value. The two contradict each other:
            \\
            \\    (* vera_scratch = "uninit" *) real st[0:3] = '{1, 2, 3, 4};  // no
            \\    (* vera_scratch *) real st[0:3] = '{1, 2, 3, 4};             // yes
            \\
            \\Drop the initializer, or use plain `vera_scratch`.
            ,
        },
        .E0540 => .{
            .title = "filter root or coefficient vector violates a Laplace or Z-transform filter rule",
            .lrm = "4.5.11",
            .explain =
            \\LRM 4.5.11 (laplace_*) and 4.5.12 (zi_*) constrain the vectors a
            \\filter is built from, and the message names the sentence broken:
            \\
            \\  - a root vector is (real, imaginary) PAIRS, so its length is even;
            \\  - "If a root is complex, its conjugate shall also be present";
            \\  - the denominator is not empty and not identically zero;
            \\  - a zi_* period T is mandatory and positive, its transition time
            \\    nonnegative.
            \\
            \\A zi_* transition time or start time must also be a constant
            \\expression; a nonzero one runs as 4.5.12's tau-long ramp.
            \\
            \\    laplace_zp(V(in), '{-1, 1}, '{-1, 0})          // no: -1+1j alone
            \\    laplace_zp(V(in), '{-1, 1, -1, -1}, '{-1, 0})  // yes: a pair
            ,
        },
        .E0572 => .{
            .title = "filter coefficient argument is not an array",
            .lrm = "4.5.1",
            .explain =
            \\LRM 4.5.1: "Certain analog operators require arrays or vectors to
            \\be passed as arguments: Laplace filters, Z-transform filters ...
            \\An array can either be passed as an array_identifier (e.g. an
            \\array parameter or an array variable) or an array assignment
            \\pattern (see 4.2.14)." The two vector slots of laplace_* and zi_*
            \\(zeros or numerator, poles or denominator) take one of those, even
            \\for a single coefficient:
            \\
            \\    laplace_nd(V(in), 2.0, '{1, 1})      // no: 2.0 is a scalar
            \\    laplace_nd(V(in), {2.0}, '{1, 1})    // no: a concatenation
            \\    laplace_nd(V(in), '{2.0}, '{1, 1})   // yes
            \\
            \\VAMS 2.x wrote the list `{2.0}`. That is the 4.2.13 concatenation
            \\operator, and annex G records the change: "Add apostrophe before
            \\opening { in list of values (to distinguish a list of values from
            \\the concatenation operator)". Empty zeros are the null argument,
            \\`laplace_zp(x, , '{-1, 0})`, not `{}`.
            ,
        },
        .E0573 => .{
            .title = "noise source label is not a string",
            .lrm = "4.6.4",
            .explain =
            \\Syntax 4-4 gives every noise function one optional trailing
            \\argument, typed `string`:
            \\
            \\    white_noise ( analog_expression [ , string ] )
            \\    flicker_noise ( analog_expression , analog_expression [ , string ] )
            \\    noise_table ( noise_table_input_arg [ , string ] )
            \\
            \\LRM 4.6.4.1: "The optional name argument acts as a label for the
            \\noise source used when the simulator outputs the individual
            \\contribution of each noise source". A number in that slot is not
            \\a label, and there is no second power for it to be.
            ,
        },
        .E0574 => .{
            .title = "analysis() argument is not a quoted analysis name",
            .lrm = "4.6.1",
            .explain =
            \\LRM 4.6.1: "The analysis() function takes one or more string
            \\arguments and returns one (1) if any argument matches the current
            \\analysis type." A.8.2 writes the quotation marks into the grammar:
            \\
            \\    analysis ( " analysis_identifier " { , " analysis_identifier " } )
            \\
            \\so `analysis()` with no name, or with a number or a variable, has
            \\nothing Table 4-21 could match.
            ,
        },

        // ------------------------------------------------------------ class 6
        .E0601 => .{
            .title = "zero divisor",
            .lrm = "4.2.4",
            .explain =
            \\LRM 4.2.4: "It shall be an error to pass zero (0) as the second
            \\argument to the modulus operator." VerA rejects a provably-zero
            \\divisor for `%` of either type and for integer `/`.
            \\
            \\A divisor that merely MIGHT be zero is accepted, as every
            \\other domain rule is (provably outside -> error, unprovable ->
            \\accept):
            \\
            \\  - `%` of either type: the executable reports E0601 and exits 1
            \\    when the divisor is zero. A solver device traps without host
            \\    I/O, including on GPU targets. An unexecuted operand does not
            \\    fail. The 4.2.4 sentence names no operand type, so a real zero
            \\    divisor is the same error, not the NaN its formula would give;
            \\  - integer `/`: LRM 4.2.4 gives `/` no zero rule. The device yields
            \\    0 for a zero divisor, and W0653 says so;
            \\  - real `/`: x/0.0 is a well-defined IEEE infinity, which is what
            \\    lets `I <+ V/r` compile for an unranged parameter r (W0650).
            \\
            \\A range excluding zero (LRM 3.4.2) can prove a divisor valid:
            \\
            \\    parameter integer n = 1 from [1:inf);
            \\    parameter integer m = 1 exclude 0;
            \\
            \\or guard the operation with an `if` the prover can see.
            ,
        },
        .E0602 => .{
            .title = "argument of ln/log must be positive",
            .lrm = "4.3.1",
            .explain =
            \\Table 4-14 gives ln(x) and log10(x) the domain x > 0. LRM 4.3.2:
            \\"Input values outside of the valid range for the operator shall
            \\report an error."
            \\
            \\VerA proves this by interval analysis and reports only when
            \\the argument is provably outside the domain — an argument it
            \\cannot decide is accepted and costs the unit its finiteness
            \\proof (W0650), never a rejection.
            \\
            \\An accepted argument that IS outside the domain when it runs is
            \\the same error at run time: the executable (`--run`,
            \\`--emit-exe`, `--check`) prints this code with the value and
            \\exits 1. A solver device has no transcript, so it returns the
            \\IEEE value (NaN, or -inf for ln(0)). The same holds for E0603
            \\to E0607 and E0609.
            \\
            \\Constrain the parameter with `from (0:inf)` (LRM 3.4.2), or guard
            \\the call with `if (x > 0)`.
            ,
        },
        .E0603 => .{
            .title = "argument of ln1p must be greater than -1",
            .lrm = "4.3.1",
            .explain =
            \\ln1p(x) computes ln(1+x), so its domain is x > -1. See E0602 for
            \\how the proof works and how to satisfy it.
            ,
        },
        .E0604 => .{
            .title = "argument of sqrt must be non-negative",
            .lrm = "4.3.1",
            .explain =
            \\Table 4-14 gives sqrt(x) the domain x >= 0. See E0602.
            \\
            \\Constrain with `from [0:inf)`, or write `sqrt(abs(x))` if the
            \\magnitude is what the model means.
            ,
        },
        .E0605 => .{
            .title = "argument of asin/acos must be within [-1, 1]",
            .lrm = "4.3.2",
            .explain =
            \\Table 4-15 gives asin and acos the domain -1 <= x <= 1. See
            \\E0602. Constrain with `from [-1:1]`, or clamp the argument with
            \\`min`/`max` before the call.
            ,
        },
        .E0606 => .{
            .title = "argument of atanh must be within (-1, 1)",
            .lrm = "4.3.2",
            .explain =
            \\Table 4-15 gives atanh the OPEN domain -1 < x < 1; the endpoints
            \\are poles, not values. Constrain with `from (-1:1)` — note the
            \\round brackets, which LRM 3.4.2 uses for an excluded bound.
            ,
        },
        .E0607 => .{
            .title = "argument of acosh must be at least 1",
            .lrm = "4.3.2",
            .explain =
            \\Table 4-15 gives acosh the domain x >= 1. Constrain with
            \\`from [1:inf)`. See E0602.
            ,
        },
        .E0608 => retiredInfo(
            \\"argument of tan is at a pole". Retired: 4.3.2 makes tan
            \\undefined at odd multiples of pi/2, but those are irrational
            \\points and every IEEE double is rational, so no representable
            \\argument — not even a compile-time constant — is ever provably
            \\AT a pole. The reject arm of the prover's three-way domain split
            \\(proof.zig, checkDomain) is empty by construction, and an
            \\argument range that merely SPANS a pole contains pole-free
            \\points, so rejecting it would violate the straddle policy: such
            \\a tan is accepted and the unit compiles `.strict`, where the
            \\near-pole value is a defined IEEE result (W0650 reports the
            \\cost). A code that cannot fire is a lie in the catalogue.
            \\
            \\Nothing replaced it; the condition does not exist to report.
            \\The number is not reused.
        ),
        .E0609 => .{
            .title = "pow() arguments violate the sign rule",
            .lrm = "4.3.1",
            .explain =
            \\Table 4-14 constrains pow(x, y): with x < 0, y must be an
            \\integer, because a negative base raised to a fractional power has
            \\no real value; and with x == 0, y must be non-negative.
            \\
            \\Proved like E0602, and reported at run time like it: an
            \\argument pair outside the domain when it runs is E0609 from the
            \\executable, with exit status 1.
            \\
            \\Use `pow(abs(x), y)` with an explicit sign, or constrain the base
            \\with `from [0:inf)`.
            ,
        },
        .W0650 => .{
            .title = "unit is not provably finite, so it compiles in strict float mode",
            .lrm = "4.3",
            .explain =
            \\THE FINITENESS WARNING. This is not a correctness problem — the
            \\model is legal, it compiles, and it will simulate correctly. It
            \\reports what the model COSTS.
            \\
            \\VerA proves, per source unit (one `<+` target: an access
            \\function plus a node pair), whether every value in that unit's
            \\backward slice is a finite IEEE double. A unit that is proven
            \\finite compiles with @setFloatMode(.optimized), which asserts
            \\"no NaN, no Inf" and lets the backend reassociate, fuse and
            \\vectorize the residual. A unit that is not proven finite compiles
            \\with @setFloatMode(.strict), where infinity is a legal, IEEE-
            \\defined value — correct, but measurably slower, and it does not
            \\vectorize in the batch evaluator.
            \\
            \\LRM 4.3.2 makes exp's domain "All x", and LRM 4.5.13 makes
            \\`limexp` optional, so a model that can overflow to infinity is
            \\CONFORMANT. VerA never rejects one and never inserts a clamp
            \\or a limexp behind your back. It tells you instead.
            \\
            \\The attached notes name the value that broke the proof — a
            \\parameter with no range, a probe with unbounded magnitude, an
            \\unmodelled call — and where it was defined.
            \\
            \\Common causes, and what recovers .optimized:
            \\
            \\  - An unranged parameter feeding exp/sinh/cosh/pow. Add a range
            \\    (LRM 3.4.2): `parameter real vt = 0.026 from (0:1];`
            \\  - A raw probe inside a transcendental: exp(V(a,b)) overflows at
            \\    V > 710. Either bound the argument in the model, or tell the
            \\    engine the solver's compliance limit, which is a property of
            \\    your solver and not of the language:
            \\        proof.Options{ .unknown_bound = 100.0 }
            \\  - A division whose divisor may be zero: real x/0.0 is legal
            \\    (see E0601) but yields an infinity, so it forfeits the proof.
            \\    `exclude 0` on the divisor's parameter recovers it.
            \\  - A parameter whose range explicitly ADMITS infinity, e.g.
            \\    `from [0:inf]`. Closing the bound — `from [0:inf)` — keeps
            \\    the same values and restores finiteness. See W0651.
            \\  - A call the prover does not model (an analog operator, a ch9
            \\    system function). Unmodelled always costs .strict rather than
            \\    risking a wrong .optimized.
            \\
            \\If strict mode is what you want for this model, silence the
            \\warning with `--allow=W0650`.
            ,
        },
        .W0651 => .{
            .title = "parameter range admits infinity",
            .lrm = "3.4.2",
            .explain =
            \\A range whose bound is a CLOSED infinity — `from [0:inf]` — says
            \\that infinity is an acceptable value for this parameter, so the
            \\prover must treat it as a possible input and every unit
            \\downstream forfeits its finiteness proof (W0650).
            \\
            \\This is almost never intended. Writing the bound open,
            \\`from [0:inf)`, admits exactly the same finite values and keeps
            \\the proof:
            \\
            \\    parameter real r = 1k from (0:inf);
            \\
            \\See W0650 for what the proof buys.
            ,
        },
        .W0653 => .{
            .title = "integer division by a divisor that may be zero",
            .lrm = "4.2.4",
            .explain =
            \\The source is LEGAL. LRM 4.2.4 makes only a zero MODULUS divisor an
            \\error ("It shall be an error to pass zero (0) as the second
            \\argument to the modulus operator"); it gives integer `/` no zero
            \\rule, so a divisor the prover cannot show non-zero — typically an
            \\unranged `parameter integer` — is accepted.
            \\
            \\The result still has to be something. IEEE 1364 5.1.5, which this
            \\LRM inherits for integer arithmetic, makes division by zero `x`,
            \\and an analog integer has no `x`. If the divisor is zero at run
            \\time, the generated device yields 0. This warning is how you find
            \\out, because nothing at run time will tell you.
            \\
            \\To silence it, show the prover the divisor is never zero:
            \\
            \\    parameter integer k = 2 exclude 0;
            \\    parameter integer n = 2 from [1:inf);
            \\
            \\or guard the division with an `if (k != 0)` the prover can see, or
            \\accept the 0 explicitly with `--allow=W0653`.
            \\
            \\A divisor that is PROVABLY zero is still an error (E0601), as is an
            \\integer `%` whose divisor cannot be proven non-zero.
            ,
        },
        .W0652 => retiredInfo(
            \\"call is not modelled by the finiteness prover". Retired: nothing
            \\emits it. An unmodelled call (an analog operator, a ch9 system
            \\function) already reaches the user as W0650 on the unit it drags to
            \\.strict, so a second code for the same event was never wired up.
            \\The number is not reused.
        ),

        // ------------------------------------------------------------ class 7
        .E0701 => .{
            .title = "event expression outside '@()'",
            .lrm = "5.10",
            .explain =
            \\`cross`, `above`, `timer`, `initial_step` and `final_step` name
            \\events, not values. They belong in the parentheses of an event
            \\control statement:
            \\
            \\    @(initial_step) begin ... end
            ,
        },
        .E0702 => .{
            .title = "event control is not allowed in this context",
            .lrm = "5.2.1",
            .explain =
            \\An `@(...)` statement schedules work at instants, which only the
            \\analog block can do. LRM 4.7.2 keeps analog functions pure — see
            \\E0405.
            ,
        },
        .E0703 => .{
            .title = "nested event control statement",
            .lrm = "5.10",
            .explain =
            \\A.6.4 derives analog_event_statement with a plain statement body,
            \\so an event statement does not contain another one. Combine the
            \\conditions with `or` instead:
            \\
            \\    @(initial_step or cross(V(a) - 0.5, +1)) ...
            ,
        },
        .E0704 => .{
            .title = "posedge/negedge is digital-only",
            .lrm = "5.10.1",
            .explain =
            \\Edge events observe a discrete signal changing value. In an analog
            \\event control (§7.3.4) the operand must be a digital variable or
            \\net: one a discrete process or continuous assignment writes. The
            \\analog equivalent for a continuous signal is `cross`, which detects
            \\a continuous expression passing through zero in a stated direction:
            \\
            \\    @(cross(V(clk) - vth, +1)) ...    // rising
            ,
        },
        .E0705 => .{
            .title = "not a declared named event",
            .lrm = "5.10.4",
            .explain =
            \\`@ <identifier>` (A.6.5) and `-> <identifier>` (5.10.4) both name a
            \\hierarchical_event_identifier, and the only declaration that
            \\introduces one is A.2.1.3
            \\
            \\    event tick;
            \\
            \\A variable, net or parameter of the same name is not an event: 2.8
            \\gives an event a name but no value, so there is nothing for `@` to
            \\test on one. A misspelling lands here too.
            ,
        },
        .E0706 => .{
            .title = "unsupported event expression",
            .lrm = "5.10",
            .explain =
            \\The supported analog events are `initial_step`, `final_step`,
            \\`cross`, `above` and `timer`, combined with `or`.
            ,
        },
        .E0707 => .{
            .title = "event control statement under a runtime condition or in a loop",
            .lrm = "5.8",
            .explain =
            \\LRM 5.8: "Event control statements (e.g.: timer, cross) cannot be
            \\used inside conditional statements unless the conditional
            \\expression is a constant expression." LRM 5.9 bans them in
            \\`repeat`, `while` and non-genvar `for` outright, and LRM 5.10.3.1
            \\repeats it for `cross` specifically: "it shall not be used inside
            \\an if, case, casex, or casez statement unless the conditional
            \\expression is a genvar expression."
            \\
            \\A monitored event is not a test the residual performs — it is a
            \\detector the kernel advances once per accepted timestep, outside
            \\the Newton loop. Its `prev`/`hit` state therefore moves whether or
            \\not the branch that encloses it ran, so the detector's history and
            \\the code that reads it drift apart. Worse, the enclosing condition
            \\is evaluated inside the residual, where it is re-evaluated several
            \\times per step at different operating points.
            \\
            \\NOTE this is STRICTER than E0514: `if (analysis("dc"))` licenses
            \\an analog operator but NOT an event control statement, because
            \\LRM 5.8 asks for a constant expression here and 5.10.3.1 asks for
            \\a genvar expression.
            \\
            \\TO FIX: put the `@(...)` on the spine of the analog block and make
            \\the STATEMENT it guards do the conditional work —
            \\
            \\    @(cross(V(clk) - 0.5, +1))
            \\      if (en) held = V(in);
            \\
            \\`--deny=E0707` makes this the error the LRM says it is.
            ,
        },
        .E0708 => .{
            .title = "initial_step or final_step in the digital context",
            .lrm = "5.10",
            .explain =
            \\LRM 5.10: "The usage of initial_step and final_step analog events
            \\are not allowed in the digital context." The two events mark the
            \\first and last point of an analog analysis (5.10.2), which only the
            \\analog block runs at. An `initial` or `always` block has its own
            \\start: write `initial` for the first, or move the statement into
            \\the analog block:
            \\
            \\    always @(initial_step) r = 1.0;     // no
            \\    analog @(initial_step) r = 1.0;     // yes
            ,
        },
        .W0750 => .{
            .title = "event fires on the testbench's fixed time grid, not at its own time",
            .lrm = "5.10.3",
            .explain =
            \\LRM 5.10.3.1 has cross() "control the timestep to accurately
            \\resolve the crossing", and 5.10.3.3 has timer() fire at its
            \\scheduled time. A host simulator does that by inserting a
            \\timepoint. The testbench `--run` and `--emit-exe` build for a
            \\model with no discrete half steps only the `//! time` points and
            \\inserts none, so a cross(), above() or timer() event whose time
            \\falls between two declared points fires at the next declared
            \\point, late by up to one grid step. It still fires once, in the
            \\step the crossing occurs in, and the event's statement sees the
            \\values at that point, not at the crossing.
            \\
            \\The device itself is unaffected: a host that places timepoints
            \\from its breakpoints (`nextBreakpoint`, `pendingBreakpoint`)
            \\resolves the event exactly.
            \\
            \\TO FIX: put a `//! time` point on (or just past) each event time
            \\the result depends on, or refine the grid until the lateness does
            \\not matter. `--allow=W0750` silences it.
            ,
        },

        // ------------------------------------------------------------ class 8
        .E0801 => retiredInfo(
            \\"unsupported system function". Retired: it was a CAPABILITY CLASS —
            \\one code for every ch9 function VerA declined to implement — and the
            \\list is now empty, so the diagnostic could not fire.
            \\
            \\Each name left it for the same reason. `$table_model` (LRM 9.21) got
            \\an interpolator (E0815 covers what it can compile). `$random`,
            \\`$arandom` and the `$dist_*`/`$rdist_*` family (LRM 9.13) turned out
            \\to be pure functions of an inout seed, so a draw cannot vary between
            \\Newton iterations at one point. `$simprobe` (LRM 9.16) is defined for
            \\the analog context by Table 9-13, and its unresolvable case has a
            \\value whenever the clause's fallback argument is supplied — E0817 is
            \\what is left of it, the case with no fallback.
            \\
            \\A function this compiler cannot host now gets a code that names the
            \\rule: E0806 for a digital-only name (LRM 9.2), E0808 for a spelling
            \\the language does not define. The number is not reused.
        ),
        .E0802 => .{
            .title = "$bound_step takes exactly one argument",
            .lrm = "9.17.2",
            .explain = "`$bound_step(max_step)` — one real expression.",
        },
        .E0803 => .{
            .title = "$bound_step argument must be non-negative",
            .lrm = "9.17.2",
            .explain =
            \\The argument is a maximum timestep, so a negative value has no
            \\meaning; the solver would have no bound to honour.
            ,
        },
        .E0804 => .{
            .title = "$discontinuity takes at most one argument",
            .lrm = "9.17.1",
            .explain =
            \\`$discontinuity` optionally takes the degree of the discontinuity
            \\— `$discontinuity(0)` for a value step, `$discontinuity(1)` for a
            \\slope step.
            ,
        },
        .E0805 => .{
            .title = "$discontinuity argument is not a constant expression",
            .lrm = "9.17.1",
            .explain =
            \\The degree is a property of the model's structure, not of the
            \\current operating point, so it must be known at compile time.
            ,
        },
        .E0820 => .{
            .title = "$discontinuity degree must be nonnegative or -1",
            .lrm = "9.17.1",
            .explain = "Nonnegative degrees describe a discontinuity in a derivative of the constitutive equation. The special degree -1 requests another Newton iteration; smaller degrees have no defined meaning.",
        },
        .E0821 => .{
            .title = "system task is not supported in the digital context",
            .lrm = "9.2",
            .explain =
            \\Every 9.2 table has two columns, "Supported in digital context"
            \\and "Supported in analog context". This name's digital cell is No.
            \\9.7 says it of the severity tasks in prose: "Verilog AMS HDL also
            \\supports three new simulation control tasks in the analog context
            \\only; $fatal, $error, $warning" (Table 9-4 adds $info).
            \\
            \\An `initial` or `always` block is the digital context (7.2.2).
            \\Move the call into the analog block, or use a task both columns
            \\allow, such as $display or $finish.
            ,
        },
        .E0887 => .{
            .title = "wrong number of arguments to a system task or function",
            .lrm = "9.5",
            .explain =
            \\Each Clause 9 call prints its argument list: Syntax 9-2 gives
            \\`$fopen(filename)` and `$fopen(filename, type)` and `$fclose(fd)`;
            \\Syntax 9-3 makes the descriptor the first argument of every file
            \\output task; §9.5.4.1 `$fgets(str, fd)`, §9.5.4.2
            \\`$fscanf(fd, format, args)`, §9.5.5 `$ftell(fd)`,
            \\`$fseek(fd, offset, operation)` and `$rewind(fd)`, §9.5.6
            \\`$fflush` with at most one descriptor, §9.5.7 `$ferror(fd, str)`,
            \\§9.5.8 `$feof(fd)`, Syntax 9-5 `$finish [ ( n ) ]`, and §9.12's
            \\IEEE 1364 §17.10 `$test$plusargs(string)` and
            \\`$value$plusargs(user_string, variable)`.
            \\
            \\A call with more or fewer arguments has no defined meaning: an
            \\argument the syntax has no slot for is not "ignored", and a
            \\missing descriptor is not descriptor 0. Supply exactly the list
            \\the clause prints.
            ,
        },
        .E0892 => .{
            .title = "$clog2 requires an integer or vector argument",
            .lrm = "9.14",
            .explain = "IEEE 1364-2005 §17.11.1 permits an integer or an arbitrary sized vector, interpreted as unsigned. A real operand has no integral bit width; convert it explicitly with $rtoi if truncation is intended.",
        },
        .E0893 => .{
            .title = "analog $clog2 cannot recover this wide operand's high bits",
            .lrm = "9.14",
            .explain = "Inside an analog $clog2 operand, arithmetic, unary negation and shifts retain at most 32 bits per intermediate. Bitwise, conditional and comparison contexts retain at most 64 bits. Above 64 bits only exact wide literals and parameter aliases preserving their width retain proven high bits. The compiler refuses a wider intermediate rather than inventing erased bits; digital execution preserves arbitrary vector widths.",
        },
        .E0823 => .{
            .title = "$simprobe name known only at run time",
            .lrm = "9.16",
            .explain =
            \\    $simprobe ( inst_name , param_name [, expression] )
            \\
            \\LRM 9.16: "The arguments inst_name and param_name are string values,
            \\either a string literal, string parameter, or a string variable."
            \\A string variable's value can be set while the analog block runs, so
            \\the clause asks the simulator to resolve the name at run time.
            \\
            \\VerA resolves a $simprobe name at compile time, against the
            \\elaborated design, and has no run-time instance table to look one up
            \\in. A name whose value the compiler cannot fold is therefore refused,
            \\with or without the fallback expression: "cannot be resolved" is about
            \\whether the name exists, so returning the fallback for a name that
            \\exists would be a wrong value with no diagnostic. This is an
            \\implementation limit (specification/Vague_Decisions.md §7), not a
            \\rule of the LRM. Spell the name as a literal or a string parameter.
            ,
        },
        .E0894 => .{
            .title = "an omitted argument or element has no value here",
            .lrm = "A.8.2",
            .explain =
            \\A.8.2's system_function_call admits an empty slot, `$f(a, , c)`,
            \\but only the clause that defines the function can give that slot
            \\a meaning (a default, or "no string supplied"). This function's
            \\clause gives this position none, so the call has no value to
            \\compute. A.8.1's assignment pattern has no empty element at all,
            \\except where §3.6.3.2's bus nodeset reads one as "no nodeset value
            \\for this element". Write the argument or the element.
            ,
        },
        .E0888 => .{
            .title = "descriptor argument is not an integer",
            .lrm = "9.5.2",
            .explain =
            \\§9.5.1: "The multichannel descriptor mcd is a 32-bit integer" and
            \\"The file descriptor fd is a 32-bit value" whose bit 31 is set.
            \\§9.5.2: "The first argument shall be either a multichannel
            \\descriptor or a file descriptor ... A multichannel descriptor is
            \\either a variable or the result of an expression that takes the
            \\form of a 32-bit unsigned integer value."
            \\
            \\A real has no bit 31 and a string is not a 32-bit value, so
            \\neither names an open file. Pass the integer `$fopen` returned.
            ,
        },
        .E0889 => .{
            .title = "$fopen type is not one of Table 9-24's forms",
            .lrm = "9.5.1",
            .explain =
            \\§9.5.1: "type is a string expression containing a character
            \\string of one of the forms in Table 9-24": "r", "rb", "w", "wb",
            \\"a", "ab", "r+", "r+b", "rb+", "w+", "w+b", "wb+", "a+", "a+b"
            \\or "ab+". Any other string opens the file in no mode the clause
            \\defines. Only a type written as a literal can be judged at compile
            \\time.
            ,
        },
        .E0890 => .{
            .title = "hierarchical system parameter outside its allowed values",
            .lrm = "9.18",
            .explain =
            \\§9.18 Table 9-29's "Allowed Values" column: `$mfactor > 0`,
            \\`$hflip = +1 or -1`, `$vflip = +1 or -1`, `0 <= $angle < 360`.
            \\Each specified value must satisfy its domain before it is
            \\combined with the parent's value. Valid angles can sum past
            \\360 degrees: the resolved angle is reduced modulo 360. Flips
            \\and multiplicities multiply; position offsets add. A zero
            \\`$mfactor` would divide branch-flow probes by zero under §6.3.6.
            \\
            \\Only a value that folds without the model card is judged here.
            ,
        },
        .E0891 => .{
            .title = "$limit argument is not the form Syntax 9-12 requires",
            .lrm = "9.17.3",
            .explain =
            \\LRM 9.17.3 Syntax 9-12 gives `$limit` three forms:
            \\
            \\    $limit ( access_function_reference )
            \\  | $limit ( access_function_reference , string , arg_list )
            \\  | $limit ( access_function_reference , analog_function_identifier , arg_list )
            \\
            \\The first argument is the probe itself: "It returns a real value
            \\that is derived from its first argument (the access function
            \\reference, such as a branch voltage)". The limiter's state is the
            \\history of that probe across Newton iterations, so an expression
            \\such as `type*V(a,b)` has no place to keep it. The second argument
            \\names the algorithm: a string for one built into the simulator, or
            \\a user-defined analog function (4.7).
            \\
            \\Scale the result instead of the probe, or use VerA's trailing sign
            \\argument for a reversed-polarity junction:
            \\
            \\    vbe = type * $limit(V(b,e), "pnjlim", vte, vcrit, type);
            \\
            \\A string VerA does not implement, or no string at all, is legal:
            \\the simulator then chooses "just as if no string had been
            \\supplied" (W0853).
            ,
        },
        .E0822 => .{
            .title = "binding detection argument is the wrong kind of name",
            .lrm = "9.19",
            .explain =
            \\LRM 9.19: "The $param_given() function takes a single argument,
            \\which must be a parameter identifier", and "The $port_connected()
            \\function takes one argument, which must be a port identifier."
            \\
            \\Both answer a question about the INSTANTIATION — was this
            \\parameter overridden, was this port connected — so a variable or
            \\an internal net has no answer: nothing instantiates it.
            ,
        },
        .E0824 => .{
            .title = "$fatal finish_number is not 0, 1 or 2",
            .lrm = "9.7.3",
            .explain =
            \\LRM 9.7.3 Syntax 9-7:
            \\
            \\    fatal_message_task ::= $fatal [ ( finish_number
            \\                           [ , message_argument ... ] ) ] ;
            \\    finish_number ::= 0 | 1 | 2
            \\
            \\"The first argument passed to $fatal shall be consistent with the
            \\corresponding argument to the Verilog $finish system task", whose
            \\diagnostic levels are Table 9-25's 0, 1 and 2. Write one of those
            \\three numbers; any other value, or one known only at run time, is
            \\not a finish_number.
            ,
        },
        .E0806 => .{
            .title = "system task is not supported in the analog context",
            .lrm = "9.2",
            .explain =
            \\Every Chapter 9 table has a "supported in analog context" column,
            \\and this name's cell says No. The prose subclauses are worded as
            \\PERMISSIONS — §9.5 "extends many of the file operation tasks so
            \\that they can be used in the analog context", and §9.11 permits
            \\$bitstoreal, $realtobits, $rtoi and $itor there. The tables under
            \\§9.2 specify which other names remain digital-only.
            \\
            \\The families, and why each stops at the digital context:
            \\
            \\  Table 9-1 / 9-2 — the b/h/o radix variants of the display and
            \\  file-output tasks. The suffix only picks a DEFAULT radix for
            \\  arguments written without a format specification, which is a
            \\  statement about bit vectors; §9.4.3's per-argument `%b`/`%o`/
            \\  `%h` works fine in an analog block. $monitoron/$monitoroff
            \\  toggle the digital $monitor mechanism.
            \\
            \\  Table 9-2 also — $fgetc, $ungetc and $fread read bytes and bit
            \\  patterns; $readmemb/$readmemh load a memory array and
            \\  $sdf_annotate loads timing onto a digital netlist. Neither
            \\  object exists in the analog context.
            \\
            \\  Table 9-3 / 9-7 — $printtimescale, $timeformat, $time and
            \\  $stime are all about the timescale TICK. The analog kernel has
            \\  no tick: it advances by a continuously variable step. §9.10
            \\  adds $abstime, in seconds, for the analog context, and
            \\  deprecates $realtime there.
            \\
            \\  Table 9-5 / 9-6 — §9.8 and §9.9 are one sentence each: Verilog
            \\  AMS HDL "does not extend" the PLA modeling tasks, and "does not
            \\  extend" the stochastic analysis tasks.
            \\
            \\  Table 9-8 — $signed and $unsigned, and only those two: §9.11
            \\  names $bitstoreal, $realtobits, $rtoi and $itor as the four
            \\  conversions that DO cross into the analog context. Signedness
            \\  reinterpretation presupposes a sized vector, which is the one
            \\  thing a real-valued analog expression never has.
            ,
        },
        .E0807 => .{
            .title = "$stop shall not be used within an analog initial block",
            .lrm = "9.7.2",
            .explain =
            \\§9.7.2: "$stop causes simulation to be suspended at a converged
            \\time point", and an analog initial block runs before there is
            \\one — §5.2.1 executes it once per analysis, ahead of the first
            \\matrix solution.
            \\
            \\$finish is deliberately the opposite: §9.7.1 defines what it
            \\means there ("the simulator shall exit without performing the
            \\simulation"), so it stays legal in an analog initial block.
            \\$stop in an ordinary `analog` block is legal too.
            ,
        },
        .E0808 => .{
            .title = "retired Verilog-A v1.0 spelling",
            .lrm = "G.1",
            .explain =
            \\Annex G Table G.1, "Limiting exponential function": the OVI
            \\Verilog-A v1.0 spelling `$limexp( expression )` was replaced in
            \\v2.0 by `limexp( expression )`.
            \\
            \\It is not an alias. A `$` name is a system function (Clause 9),
            \\and `$limexp` appears in neither Table 9-11 nor A.8.2 — the name
            \\does not exist. 4.5.13 defines the analog operator under the bare
            \\name only.
            \\
            \\Drop the `$`.
            ,
        },
        .E0809 => .{
            .title = "$limit is missing an argument its algorithm requires",
            .lrm = "9.17.3",
            .explain =
            \\LRM 9.17.3 fixes the arity of the two algorithms it names:
            \\
            \\  "fetlim" — "One additional argument to the $limit() function is
            \\    required ...: the third argument to $limit() is generally the
            \\    threshold voltage of the MOS transistor."
            \\  "pnjlim" — "Two additional arguments ... are required ...: the
            \\    third argument ... indicates a step size vte and the fourth
            \\    argument is a critical voltage vcrit."
            \\
            \\This is not the unknown-string case. The same clause lets a
            \\simulator ignore a string it does not recognise ("just as if no
            \\string had been supplied"), and `$limit(V(a,b))` with no string
            \\at all is legal (Syntax 9-12). Naming one of these two is what
            \\imposes the arity.
            ,
        },
        .E0810 => .{
            .title = "not enough arguments for the format specifiers",
            .lrm = "9.4.3",
            .explain =
            \\LRM 9.4.3, stated again in 9.4.1: "for each % character (except
            \\%m, %% and %l) that appears in a string, a corresponding
            \\expression argument shall be supplied after the string."
            \\
            \\The parenthesis is what makes this checkable rather than a
            \\formatting preference: three specifiers consume no operand and
            \\every other one consumes exactly one, so the format string alone
            \\fixes how many arguments are required.
            \\
            \\The reverse is NOT an error. 9.4.3 gives extra arguments a
            \\meaning — "any expression argument with no corresponding format
            \\specification is displayed using the default decimal format" —
            \\so only a shortfall is diagnosed.
            \\
            \\Only a literal format string is counted. A format assembled at
            \\run time has no count to check against.
            ,
        },
        .E0811 => .{
            .title = "simulation parameter is not known",
            .lrm = "9.15",
            .explain =
            \\LRM 9.15 states $simparam in three sentences, one per branch:
            \\"If param_name is known, its value is returned. If param_name is
            \\not known, and the optional expression is not supplied, then an
            \\error is generated. If the optional expression is supplied, its
            \\value is returned if param_name is not known and no error is
            \\generated."
            \\
            \\This is the middle branch. The reason it is an error rather than
            \\a default is that the two are indistinguishable at the call site:
            \\a silent 0.0 reads exactly like a simulator that really does
            \\carry the parameter and really does report zero for it, and a
            \\model that divides by it or compares against it is then wrong
            \\with nothing to point at.
            \\
            \\Two fixes, and the LRM prints both:
            \\
            \\    gmin = $simparam("gmin");                  // must be known
            \\    sourcescale = $simparam("sourceScaleFactor", 1.0);
            \\
            \\The second form is legal for EVERY name, known or not — Table
            \\9-27 is prefaced "simulators shall accept the strings ... if they
            \\support the parameter" — so a model that wants to stay portable
            \\across tools writes the fallback.
            \\
            \\Only a literal name is checked. 9.15 also allows a string
            \\parameter or a string variable, whose value is not available
            \\here, and the fallback is the user's cover for that case.
            \\
            \\"$simparam$str is similar to $simparam" but takes no fallback,
            \\so a literal name outside Table 9-28 ("analysis_name",
            \\"analysis_type", "cwd", "module", "instance", "path") is this
            \\error too.
            ,
        },
        .E0812 => .{
            .title = "invalid use of a node alias system function",
            .lrm = "9.20",
            .explain =
            \\LRM 9.20 states $analog_node_alias() and $analog_port_alias() as
            \\a validity list, and this code carries all of it. One number,
            \\because the six sentences are one rule with one reason: an alias
            \\makes the named node "refer to the same circuit matrix position"
            \\as the hierarchical reference, so it is a TOPOLOGY edit, and
            \\topology is fixed before a solve runs.
            \\
            \\    integer ok;
            \\    electrical local;
            \\    analog initial ok = $analog_node_alias(local, "$root.top.a");
            \\
            \\What the clause requires, in the order it is checked:
            \\
            \\  1. "It shall be an error for the ... system functions to be
            \\     used outside the analog initial block." An ordinary analog
            \\     block runs inside the Newton loop.
            \\  2. They "shall not be used inside conditional (if, case, or
            \\     ?:) statements unless the conditional expression ...
            \\     consists of terms which can not change during the course of
            \\     a simulation". A parameter guard is fine; $abstime is not.
            \\  3. The analog_net_reference "shall be either a scalar or vector
            \\     continuous node declared in the module containing the system
            \\     function call".
            \\  4. "It shall be an error for the analog_net_reference to be a
            \\     port or to be involved in port connections" — a port is
            \\     already bound by the instantiating netlist.
            \\  5. A vector "shall reference the full vector node, it shall be
            \\     an error for it to be a bit select or part select". The
            \\     scalar element goes on the OTHER side of the call.
            \\  6. The hierarchical_reference_string "shall be a constant
            \\     string value (string literal or string parameter)", and it
            \\     shall not name a node that is already the
            \\     analog_net_reference of another alias call.
            \\
            \\An unresolvable reference is NOT an error: the same clause makes
            \\that a return value, "one (1) if the hierarchical_reference_string
            \\points to a valid continuous node and zero (0) otherwise".
            ,
        },
        .E0813 => .{
            .title = "invalid argument to a string formatting or scanning task",
            .lrm = "9.5.3",
            .explain =
            \\LRM 9.5.3 puts the destination first — "the first argument to
            \\$swrite shall be a string variable to which the resulting string
            \\shall be written, instead of a variable specifying the file to
            \\which to write" — and 9.5.4.2 gives $sscanf its output
            \\arguments, one per non-suppressed conversion.
            \\
            \\    string text;  real x;  integer code;
            \\    $sformat(text, "v=%10.4e", V(p,n));
            \\    code = $sscanf(text, "v=%e", x);
            \\
            \\So this fires when a destination is not something that can be
            \\assigned to: a $swrite/$sformat first argument that is not a
            \\`string` variable, an output argument that is a literal or an
            \\expression, or one of the two writers used in expression
            \\position, where it has no destination at all.
            \\
            \\It also fires on a conversion code VerA does not scan. 9.5.4.2's
            \\own list is %d %o %h %x %b %c %f %e %g %s, with the assignment
            \\suppression * and a maximum field width; the strength, 4-state
            \\and timeformat codes (%v, %z, %t) describe values an analog
            \\device does not have. Refusing one is deliberate: a code that
            \\scanned as garbage would still be COUNTED in the return value,
            \\so the model would read a plausible number and never find out.
            ,
        },
        .E0814 => .{
            .title = "a $limit limiter argument is not `input`",
            .lrm = "9.17.3",
            .explain =
            \\LRM 9.17.3, on Syntax 9-12's third form
            \\`$limit(access_function_reference, analog_function_identifier,
            \\arg_list)`: "The arguments of the user-defined function shall all be
            \\declared input."
            \\
            \\The simulator supplies every one of them — "The first argument of
            \\the user-defined function shall be the value of the access function
            \\reference for the current iteration. The second argument shall be
            \\the appropriate internal state; generally, this is the value that
            \\was returned by the $limit() function on the previous iteration" —
            \\so they are the solver's iteration history handed inward. An
            \\`output` or `inout` formal would write back into that history
            \\mid-Newton-step, and 9.17.3 gives that no meaning.
            \\
            \\Return the limited value as the function's own return variable
            \\(4.7.1), which is what $limit() reads.
            ,
        },
        .E0816 => .{
            .title = "a $9.13 probabilistic distribution argument",
            .lrm = "9.13",
            .explain =
            \\Table 9-10's 17 names are supported in the analog context, and
            \\9.13.1/9.13.2 state four rules about their arguments. This fires on
            \\all four, because they are one clause and the message says which:
            \\
            \\THE SEED'S TYPE. "For each system function, the seed argument shall
            \\be an integer", and Syntax 9-9 spells the same rule as grammar:
            \\
            \\    seed ::= integer_variable_identifier
            \\           | integer_parameter_identifier
            \\           | [ sign ] decimal_number
            \\
            \\A real is none of the three, and no coercion is available: an
            \\integer VARIABLE seed is an inout argument, so the function needs a
            \\place to write an updated integer back to.
            \\
            \\THE DOMAIN. "For the $rdist_exponential, $rdist_poisson,
            \\$rdist_chi_square, $rdist_t, and $rdist_erlang functions, the
            \\arguments mean, degree_of_freedom, and k_stage shall be greater
            \\than zero (0). Otherwise an error shall be reported." Not a
            \\warning, not a clamp — and IEEE 1364 17.9.2 states the same domain
            \\for the integer $dist_ twins.
            \\
            \\THE UNIFORM'S ORDER. "In $rdist_uniform, the start and end
            \\arguments are real inputs which bound the values returned. The
            \\start value shall be smaller than the end value." An interval with
            \\start above end is empty, so there is no value to draw from it.
            \\
            \\THE type_string. Syntax 9-8/9-9's optional trailing string
            \\("instance" or "global") says which paramset override owns the
            \\stream, so it is meaningful only inside a 6.4 paramset.
            ,
        },
        .E0818 => .{
            .title = "driver access function outside a connect module",
            .lrm = "9.22",
            .explain =
            \\LRM 9.22, paragraph 3, both sentences: "The driver access functions
            \\described here only access drivers found in ordinary modules and not
            \\to those found in connect modules. Driver access functions can only
            \\be called from connect modules." 9.23 fences its four supplementary
            \\functions the same way and one step tighter — they are "supported in
            \\the digital context of connectmodules" — and Table 9-19 gives every
            \\member of both families "Supported in analog context of
            \\connectmodule: No".
            \\
            \\The two sentences are not in tension: the functions REPORT on
            \\drivers found in ordinary modules, but they may only be CALLED from
            \\a connect module. So the call site alone decides this, with no
            \\netlist, no elaboration and no driver: an ordinary `module` is not a
            \\`connectmodule`, and a call in one is illegal on sight.
            \\
            \\VerA has no `connectmodule` design element, so EVERY call site in a
            \\file VerA can compile is outside one and this diagnostic fires on
            \\every one of them. That is the conforming behaviour, not a
            \\limitation standing in for one: the alternative VerA used to ship
            \\was to answer the constant 0, and a plausible wrong number is the
            \\worst thing a compiler can hand back — 9.22.2/9.22.3/9.23.x take a
            \\driver_index "between 0 and N-1", which for N = 0 is an EMPTY range
            \\with no element 0 to have a value.
            \\
            \\When VerA grows connect modules the rule does not move: it narrows
            \\from "no module has drivers" to "this module is not a connect
            \\module", which is the same test on a wider language.
            ,
        },
        .E0819 => .{
            .title = "format conversion does not match the operand's type",
            .lrm = "9.4.3",
            .explain =
            \\9.4.3 pairs each consuming conversion with the expression argument
            \\that follows the format string. VerA's formatter renders three
            \\operand types — real, integer, string — and most conversions have a
            \\reading for each: %d/%b/%o/%h round a real, and a string operand
            \\under them takes 2.7's "unsigned constant number" view, one byte
            \\per character. Four pairings have no rendering VerA emits:
            \\
            \\    %s over a real, or an integral expression whose width the
            \\    current backend cannot preserve. Integer operands with a known
            \\    supported width render as 9.4.5's sequence of 8-bit ASCII codes.
            \\    Remaining numeric cases are implementation limitations.
            \\
            \\    %c over a string. Table 9-22's %c displays the low byte of an
            \\    INTEGER as a character; a string is not a code. Use %s for the
            \\    text, or index a code out of it.
            \\
            \\    %e/%f/%g/%r (and the %t/%u/%z/%v defaults) over a string.
            \\    There is no numeric field to format; %s prints the text, %d
            \\    prints 2.7's integer view.
            \\
            \\    Any conversion but %s over a null argument (`,,`). 9.4.1 gives a
            \\    null argument "a single space character in the display" and no
            \\    value; %s prints that space (VD-101).
            \\
            \\The diagnostic points to the operand before generated code is
            \\compiled. An unsupported pairing is not necessarily illegal
            \\Verilog-AMS; consult the conformance backlog for implementation gaps.
            ,
        },
        .E0825 => .{
            .title = "'#' flag on a format conversion that has no alternative form",
            .lrm = "9.4.3",
            .explain =
            \\9.4.3: "The format specifications in Table 9-23 are used for real
            \\numbers and have the full formatting capabilities available in the
            \\C language." C11 7.21.6.1 gives '#' its alternative form, which for
            \\%e, %f and %g always prints the decimal point (and for %g keeps the
            \\trailing zeros): `%#.0f` of 2.0 prints "2.", `%#g` of 1.5 prints
            \\"1.50000". VerA implements it there.
            \\
            \\The grant names Table 9-23 only. Table 9-22's conversions (%h %d %o
            \\%b %c %s, and %m %l, which take no argument) are Verilog's, sized
            \\by IEEE 1364-2005 17.1.1.3 rather than by C, and Table 9-23's %r is
            \\2.6.2's engineering notation, which C does not have; no clause says
            \\what '#' does to any of them. Rather than guess (C's `0x` prefix on
            \\an auto-sized %h?), VerA refuses the flag. Drop the '#', or format
            \\the value with %e, %f or %g.
            ,
        },
        .E0826 => .{
            .title = "a flag, width or precision written on `%%`",
            .lrm = "9.4.2",
            .explain =
            \\9.4.1: "The special character string %% indicates the display of
            \\the percent sign character (%)", and Table 9-21 (9.4.2) lists `%%`
            \\as an escape sequence: two characters, nothing between them. A
            \\flag, a width or a precision there (`%5%`, `%-%`, `%.2%`) is no
            \\escape of Table 9-21 and no format specification of Tables 9-22 and
            \\9-23. The real conversions' grant of "the full formatting
            \\capabilities available in the C language" (9.4.3) does not cover it
            \\either: C11 7.21.6.1p8 says "The complete conversion specification
            \\shall be %%", so `%5%` has no meaning in C.
            \\
            \\Rather than guess whether the width pads the `%` or whether the
            \\specification takes an argument, VerA refuses it. Write `%%` for a
            \\percent sign, or `%5s` over "%" for a padded one.
            ,
        },
        .E0827 => .{
            .title = "a C format flag on a digital-context conversion that is not a real one",
            .lrm = "9.4.7",
            .explain =
            \\IEEE 1364-2005 17.1.1.2: "The format specifications in Table 17-3
            \\are used with real numbers and have the full formatting
            \\capabilities available in the C language." In the digital context
            \\VerA therefore renders C11 7.21.6.1's flags on %e, %f and %g (and
            \\on 9.4.7's %r, '#' apart): `%-8.2f` of 2.5 prints "2.50    ",
            \\`%08.3f` of -2.5 prints "-002.500".
            \\
            \\The grant names the real conversions only. The others (%h %d %o %b
            \\%c %s %t %v %m %l) are sized by 17.1.1.3, automatically or by a
            \\written width, and its one override is the zero of `%0d`. No clause
            \\says what '-', '+' or ' ' does to such a field (does `%-h` pad an
            \\auto-sized hex field on the right?), so VerA refuses the flag rather
            \\than read it and print the field as if it were not there. Drop the
            \\flag, or format a real with %e, %f or %g. ('#' outside %e, %f and %g
            \\is E0825.)
            ,
        },
        .E0828 => .{
            .title = "a format field width or precision past VerA's limit",
            .lrm = "9.4.3",
            .explain =
            \\9.4.3 gives the real conversions "the full formatting capabilities
            \\available in the C language", and VerA reads a width and a
            \\precision on every conversion. Neither the clause nor C bounds
            \\them; a device has to. Its field is composed in a buffer sized at
            \\compile time from the width and the precision, and its real
            \\conversion counts digit positions as 32-bit integers, so VerA
            \\takes a width or precision up to 2^30 (1073741824) in an
            \\analog-context format, the limit in specification/Vague_Decisions.md
            \\section 7. A larger one, or one too long to be a number at all, is
            \\refused here rather than overflow the device's arithmetic.
            \\
            \\A field that wide is already a gigabyte of text. Write a smaller
            \\width or precision. (The digital context writes its padding as it
            \\goes and takes any width.)
            ,
        },
        .E0829 => .{
            .title = "system function not run by VerA's digital engine",
            .lrm = "9.2",
            .explain =
            \\Every 9.2 table has a "Supported in digital context" column. This
            \\name's cell is Yes, so the call is legal in an `initial` or
            \\`always` block, and VerA's digital engine does not evaluate it
            \\yet: $arandom and the $rdist_ functions (Table 9-10), $min, $max
            \\and $abs (Table 9-11), $temperature, $vt, $simparam and
            \\$simparam$str (Table 9-12), the hierarchical parameter functions
            \\$mfactor, $xposition, $yposition, $angle, $hflip and $vflip
            \\(Table 9-15), and $table_model (Table 9-18). It is refused by name
            \\rather than run as something else.
            \\
            \\The digital context does run $abstime, $realtime, the IEEE 1364
            \\math functions with $ln1p and $expm1, and the $dist_ functions.
            \\Compute the value in the analog block and read the variable from
            \\the digital process (VAMS 7.3.6.4), or use one of those.
            ,
        },
        .E0817 => .{
            .title = "$simprobe resolves to nothing and has no fallback",
            .lrm = "9.16",
            .explain =
            \\    $simprobe ( inst_name , param_name [, expression] )
            \\
            \\LRM 9.16: "If either the inst_name or param_name cannot be resolved,
            \\and the optional expression is not supplied, then an error shall be
            \\generated. If the optional expression is supplied, its value will be
            \\returned in lieu of raising an error." This is the first sentence.
            \\
            \\VerA resolves the pair as one flat name — `inst_name.param_name` —
            \\against the elaborated design, which is the same identity every 6.7
            \\out-of-module reference uses: a flattened child's parameter is named
            \\by its hierarchical path. So the names that resolve are the ones a
            \\path could reach from this device.
            \\
            \\Supplying the third argument is what makes a probe of something
            \\OUTSIDE this device — a sibling instance the compiler never sees — a
            \\legal call with a defined value. A name built at run time is a
            \\different case, E0823: it is refused, because it may name something
            \\that exists.
            ,
        },
        .E0815 => .{
            .title = "$table_model data source or control string",
            .lrm = "9.21",
            .explain =
            \\    $table_model ( table_inputs , table_data_source
            \\                   [, table_control_string] )
            \\
            \\One lookup expression per dimension, then either a file name or one
            \\array per dimension followed by an output array (9.21.1), then an
            \\optional control string (9.21.2).
            \\
            \\    real y[0:11], x[0:11], f_xy[0:11];
            \\    f = $table_model(0.25, 3.5, y, x, f_xy);
            \\    g = $table_model(0.25, V(a,b), "sample.dat", "1LL,1LL;1");
            \\
            \\This fires on a call whose shape does not add up — a file that
            \\cannot be read or does not hold a rectangular block of numbers,
            \\arrays of differing lengths (they are COLUMNS of one table), fewer
            \\columns than the inputs need, fewer samples than 9.21's "at least
            \\two points per dimension (2^N for N dimensions)", or a dependent
            \\selector naming a column the data source does not have.
            \\
            \\It also fires on an interpolation scheme VerA does not implement.
            \\Table 9-30's `1` (linear) is the one implemented; `D`, `2` and `3`
            \\(closest point, quadratic and cubic splines) and `I` (ignore this
            \\column) are refused rather than substituted, as is Table 9-31's `E`
            \\— "an extrapolation error is reported if the $table_model function
            \\is requested to evaluate a point beyond the interpolation region",
            \\and a compiled residual has no channel to report one on. Extrapolating
            \\anyway is precisely the wrong-number failure `E` exists to prevent.
            \\Table 9-31's `C` and `L` both work.
            ,
        },
        .W0850 => .{
            .title = "task dropped: a device does not print and has no file table",
            .lrm = "9.4",
            .explain =
            \\VerA makes two artifacts out of one .va, and this one is the
            \\DEVICE: a residual function the solver calls inside its Newton
            \\loop, on a batch of instances, possibly on a GPU.
            \\
            \\A print there is not a debugging aid, it is a per-iteration
            \\syscall on a hot loop that also happens not to compile for
            \\SPIR-V or PTX. So a device prints nothing. What it does instead,
            \\by default (`--display=record`), is RECORD: its `say` entry point,
            \\which a host calls once per accepted point (9.4.6: "All the display
            \\tasks, except $debug, shall not display output unless an iteration
            \\has been accepted"), appends each $strobe, $display, $write,
            \\$debug, $warning and $info it runs to a buffer the host lends, as
            \\a site index and its numbers, and the host prints them
            \\(`contract.SaySite`, `contract.formatSay`). A host that also
            \\calls it after each Newton iteration (`contract.SayPass`) shows
            \\$debug at every iteration, as 9.4.1 has it. $fatal and $error
            \\latch the device's status (`contract.StatusSite`), which stops its
            \\rows until the host clears it.
            \\
            \\This warning names what is still dropped, once per call site:
            \\$monitor (9.4.1's change detection is state across accepted steps
            \\a device does not keep), $finish and $stop (eval has no channel to
            \\stop a host's solve), a printing task with a string argument that
            \\is not a constant (a record carries numbers), and, under
            \\`--display=drop`, every display task.
            \\
            \\The model is CONFORMANT; nothing is wrong with it. If the text
            \\is what you wanted, build the other artifact:
            \\
            \\    vera --emit-exe FILE.va       # a runnable testbench
            \\    vera --display=emit ...       # or just the codegen knob
            \\
            \\which lowers the same tasks to `std.debug.print` and gives the
            \\device a `display()` entry point that runs them.
            \\
            \\The LRM 9.5 file family is on the same list, for the same reason
            \\one step further out: a descriptor operation is a side effect, and
            \\`eval` has to stay a pure function of x or the solver's Newton
            \\iteration cannot converge. 9.5.9 agrees — "the file write
            \\operations shall not be performed unless the iteration is
            \\accepted" — so those calls are sequenced in the same per-point
            \\`display()` phase, and a device without one has no file table.
            \\
            \\That is not a stub: 9.5.1 reserves zero for "if a file cannot be
            \\opened", and a device with no table genuinely cannot open one. So
            \\`$fopen` answers 0, and every later call on that 0 has a defined
            \\answer of its own (9.5.4.1's "code is set to zero", 9.5.7's zero
            \\errno with an empty description, 9.5.8's zero).
            \\
            \\Silence it for a model you know prints only under a debug flag
            \\with `--allow=W0850`.
            ,
        },
        .W0852 => .{
            .title = "unregistered system function is left to a VPI host",
            .lrm = "12.32.3",
            .explain =
            \\This `$name` is not a Chapter 9 system function and not an Annex D
            \\or §4.5 operator. LRM 2.8.3 still makes it grammatical, and lists
            \\"defined using the VPI as described in Clause 11 and Clause 12" as
            \\one of the places a system function may come from — §12.32's
            \\vpi_register_analog_systf() is that place, and it hands the
            \\APPLICATION a compiletf routine so the application, not the
            \\compiler, decides what the name means.
            \\
            \\So the source is legal and VerA may not reject it. §12.32.3's own
            \\illustration is a contribution:
            \\
            \\    V(out) <+ $sampler(V(in), period);
            \\
            \\VerA has nothing to ask, so it does not answer: the name is
            \\exported in the device's `systf_calls` table and the call site
            \\reads its value — and its derivatives — from the application the
            \\HOST binds into `Instance.systf`. `contract.validateHost` refuses
            \\to build a host that binds none, so an unregistered systf cannot
            \\reach a simulation with no value behind it.
            \\
            \\WHY A HOST CALL AND NOT A SUBSTITUTE. Everywhere else a substitute
            \\value would contradict a number the LRM fixes, so the unit is
            \\refused outright (E0515, the filter families) rather than quietly
            \\made wrong. An unregistered systf has no such number: the language
            \\defines no value for it at all — §12.32.3's listing never even
            \\initializes sampler->value before the first update callback, and
            \\hands that field straight back through vpi_put_value(). So there
            \\is nothing to be wrong about, only somebody else to ask, and the
            \\artifact carries the question instead of inventing an answer.
            \\
            \\`vera --run` is itself a host and answers zero with zero partials,
            \\which is why a fixture over one of these asserts what does not
            \\depend on the value (§5.3.1: the block runs straight through).
            \\
            \\That is not a licence to be silent, which is what this warning is
            \\for: a misspelled `$abstmie` would otherwise become a binding the
            \\host is asked for. One warning per call site, naming the name.
            \\
            \\  --deny=W0852    refuse the unit instead (the old behaviour)
            \\  --allow=W0852   silence it for a model you know needs a host
            ,
        },

        // ------------------------------------------------------------ class 9
        .E0901 => .{
            .title = "hierarchical name names nothing in the elaborated design",
            .lrm = "6.7",
            .explain =
            \\A dotted name that resolves to no net, branch, parameter or
            \\constant.
            \\
            \\This is NOT "hierarchy is unsupported" any more — that was E0204,
            \\retired. §6.2.2 instantiation elaborates and `elab/elaborate.zig`
            \\flattens the tree, and because a flattened entity's name IS its
            \\hierarchical path (`Elaborate.sep`), resolving a §6.7 reference is
            \\the ordinary lookup under the joined name. So this fires when the
            \\path is simply wrong: a misspelled instance name, an instance that
            \\was never declared, or a name that exists in a sibling rather than
            \\the module named.
            \\
            \\It is deliberately not an implicit net either. §3.6.5 creates one
            \\for an undeclared SIMPLE name in this module; a path naming nothing
            \\names no net anywhere in the design, and inventing one would turn a
            \\typo into a floating node.
            \\
            \\Two neighbours draw the boundary: E0910 is a path that resolves to
            \\a child's VARIABLE, which §6.7.1 forbids outright, and E0904 is an
            \\instance whose MODULE does not exist.
            ,
        },
        .E0902 => .{
            .title = "more than one discipline declaration for one net",
            .lrm = "7.4.4",
            .explain =
            \\LRM 7.4.4, repeated verbatim as step 3 of the discipline
            \\resolution algorithm in F.2.1 and F.2.2: "More than one
            \\conflicting discipline declaration from the same context (in or
            \\out of context) for the same hierarchical segment of a signal is
            \\an error. In this case, conflicting simply means an attempt to
            \\declare more than one discipline regardless of whether the
            \\disciplines are compatible or not."
            \\
            \\So COMPATIBILITY IS NOT THE TEST. Two declarations naming the same
            \\natures, or two natureless `domain continuous` disciplines that
            \\3.11.1's Natureless Discipline Rule makes compatible, are still an
            \\error — the second declaration is the error, not the mismatch.
            \\3.10 says it from the other side: two disciplines at the same level
            \\of precedence for one net is not legal.
            \\
            \\Delete one of the declarations. If the two were meant to describe
            \\different segments, they need different nets.
            ,
        },
        .E0903 => .{
            .title = "unknown discipline on a net with a mixed-port connection",
            .lrm = "F.2.1",
            .explain =
            \\Annex F.2.1 step 4.b (printed verbatim in F.2.2 4.b and 5.b)
            \\resolves an UNDECLARED net from the disciplines of its child
            \\segments whose domain matches the net's. One candidate resolves
            \\the net; more than one is resolved only by a matching connect
            \\statement — "if there is more than one discipline in the list and
            \\the contents of the list match the discipline list of a
            \\resolution connect statement, the net is of the resolved
            \\discipline given by the statement" (7.7.2's
            \\`connect a, b resolveto c;`). "Otherwise the discipline is
            \\unknown. This is legal provided the net has no mixed-port
            \\connections (i.e., it does not connect through a port to a
            \\segment of a different domain). Otherwise this is an error."
            \\
            \\This net is that error: its matching-domain candidates resolve to
            \\no single discipline, no `connect ... resolveto` statement lists
            \\exactly that candidate set, and one of its segments is of the
            \\OTHER domain — so the bridge the insertion phase (7.8) would have
            \\to place has no discipline to bridge to.
            \\
            \\A 7.7.1 INSERTION statement (`connect some_connectmodule;`) does
            \\not help: it names a bridging module and resolves nothing, which
            \\is the difference between the two connectrules_item forms.
            \\Either declare the net's discipline, or add a resolution
            \\statement whose list matches the candidates.
            ,
        },
        .E0904 => .{
            .title = "instance names no module",
            .lrm = "6.2.2",
            .explain =
            \\A module_instantiation's module_or_paramset_identifier has to name a
            \\module (or paramset) declared somewhere in the compilation unit.
            \\A.1.2 puts no order on the descriptions of a source_text, so the
            \\definition may follow the use — but it has to exist.
            \\
            \\VerA compiles one file at a time; a child in another file has to be
            \\`include`d, or the parent has to be compiled with it.
            ,
        },
        .E0905 => .{
            .title = "recursive module instantiation",
            .lrm = "6.2.2",
            .explain =
            \\A module instantiates itself, directly or around a cycle. Verilog-AMS
            \\elaboration builds a finite instance TREE, so a cycle has no
            \\elaboration: each level would create another level forever.
            \\
            \\This is not a depth limit being hit by a deep design (there is
            \\none): the cycle is reported by name, module by module
            \\(`a` → `b` → `a`), with the instance path that closes it. A
            \\generate scheme that would end the recursion (6.6.2) is not
            \\folded on this walk, so any self-instantiation is refused.
            ,
        },
        .E0906 => .{
            .title = "port connections do not match the module's ports",
            .lrm = "6.2.2",
            .explain =
            \\Either the ordered connection list is longer than the module's port
            \\list, or a named connection names a port the module does not
            \\declare, or the two forms are mixed in one list.
            \\
            \\6.2.2 permits FEWER connections than ports: an omitted port and a
            \\blank one are both "not to be connected", and 9.19
            \\`$port_connected` returns 0 for them. What it does not permit is a
            \\connection with no port to attach to.
            ,
        },
        .E0907 => .{
            .title = "override names no parameter of the module",
            .lrm = "6.3",
            .explain =
            \\A `#(...)` parameter value assignment either names a parameter by
            \\name (`.gain(2.0)`) or supplies values "in the order of their
            \\declaration". A name that is not a parameter of the instantiated
            \\module overrides nothing, and an ordered list longer than the
            \\module's parameter list has values with nowhere to go.
            \\
            \\A `localparam` (3.4.5) is deliberately not overridable, so naming
            \\one here is this error too.
            \\
            \\A `defparam` applied before its declaring instance is elaborated
            \\(IEEE 1364-2005 12.8.1) has each parameter its value reads replaced
            \\by that parameter's final value, as far down as the chain goes.
            \\One whose chain comes back to a parameter already in it (its own
            \\target, read through the declaring module's parameters) has no
            \\value, and is this error too, naming the cycle.
            ,
        },
        .E0908 => .{
            .title = "a parameter is overridden more than once",
            .lrm = "6.3.3 / 3.4.7",
            .explain =
            \\6.3.3 forbids another assignment to a parameter name after it has
            \\been assigned a value. Repeating an ordinary named parameter
            \\assignment is an error even when no aliasparam is involved.
            \\
            \\3.4.7 also forbids overriding one parameter through both its
            \\original name and an alias, or through multiple aliases, whether
            \\by name or by defparam. Equal assigned values do not make those
            \\overrides legal. Keep only one override for the parameter.
            ,
        },
        .E0909 => .{
            .title = "instance array range is not an elaboration-time constant",
            .lrm = "6.2.2",
            .explain =
            \\`name_of_module_instance ::= module_instance_identifier [ range ]`
            \\creates one instance per element, so both bounds have to be known
            \\when the instance tree is built.
            \\
            \\The bounds are constant expressions: literals, parameters (3.4) and
            \\the operators over them, folded as an integer. A variable, a
            \\real-valued bound, or a name that is no scalar parameter is not one.
            ,
        },
        .E0910 => .{
            .title = "analog variable accessed hierarchically",
            .lrm = "6.7.1",
            .explain =
            \\LRM 6.7.1, fifth bullet: "It shall be an error to access analog
            \\variables hierarchically."
            \\
            \\The neighbouring bullets in the same list expressly PERMIT it for
            \\branch potentials and flows, for parameters and for analog user
            \\defined functions, so the prohibition is about variables
            \\specifically: a variable is per-evaluation state of one module's
            \\analog block, and reading it from outside makes the answer depend on
            \\which block ran first — which nothing in Clause 5 orders.
            \\
            \\A parameter or a branch probe of the same instance is legal. If the
            \\value really has to cross the boundary, it is an output of the
            \\module, not a variable of it.
            ,
        },
        .E0911 => .{
            .title = "no paramset admits this instance's parameter values",
            .lrm = "6.4.2",
            .explain =
            \\LRM 6.4.2 lets several paramsets share one name — "multiple
            \\paramsets can be declared using the same paramset_identifier" — and
            \\has the elaborator "choose an appropriate paramset from the set that
            \\shares a given name for every instance that references that name".
            \\That is BINNING: one paramset per geometry range, and the instance's
            \\dimensions pick the bin.
            \\
            \\Every candidate here was ruled out by the clause's selection rules:
            \\an override must name an overridable parameter the paramset
            \\declares, every parameter's value — overridden or defaulted — must
            \\lie within that paramset's own declared `from`/`exclude` ranges,
            \\and the module the paramset specializes must declare a port for
            \\each port the instance connects. So either an override or a
            \\connection is misspelled for this set, or the instance falls in a
            \\gap between the bins.
            \\
            \\The OPPOSITE failure — several paramsets still applicable after
            \\6.4.2's tie-breaking rules — is E0914.
            ,
        },
        .E0912 => .{
            .title = "flow contribution scaled by $mfactor twice",
            .lrm = "6.3.6",
            .explain =
            \\LRM 6.3.6, first bullet: "All contributions to a branch flow
            \\quantity in the analog block shall be multiplied by $mfactor", and
            \\the clause adds that "Verilog-AMS does not provide a method to
            \\disable" it. The scaling is the simulator's, and it always happens.
            \\
            \\So an explicit `* $mfactor` (or `/ $mfactor`) in the contributed
            \\value cannot be an opt-out — it is the clause's own `badres`
            \\example, of which 6.3.6 says: "the contributed current would be
            \\multiplied by $mfactor twice, once by the explicit multiplication
            \\and once by the automatic scaling rule. The simulator will generate
            \\an error for this module."
            \\
            \\READING $mfactor is always legal. The clause's companion example
            \\`parares` uses it in a guard — `if (r/$mfactor < 1e-3)` — and says
            \\no error is generated there. Only a multiplicative factor in the
            \\value being contributed is this error, and only for a FLOW: a
            \\potential contribution is not scaled automatically, so there is
            \\nothing for a factor to double.
            ,
        },
        .E0913 => retiredInfo(
            \\"instantiating a connect module by name is not supported". Retired:
            \\LRM 7.1 says connect modules "can be manually inserted (by the
            \\user) or automatically inserted (by the simulator)", and a
            \\hand-placed one is now inlined like any child, its digital half
            \\running on the mixed-signal runner (E0920 is retired with it). The
            \\number is not reused.
        ),
        .E0914 => .{
            .title = "more than one paramset is still applicable",
            .lrm = "6.4.2",
            .explain =
            \\LRM 6.4.2 chooses among same-named paramsets in two phases. The
            \\selection rules ("When choosing an appropriate paramset, the
            \\following rules shall be enforced") cut the overload set down to
            \\the applicable candidates; then "The rules above may not be
            \\sufficient for the simulator to pick a unique paramset, in which
            \\case the following rules shall be applied in order until a unique
            \\paramset has been selected":
            \\
            \\  1. "The paramset with the fewest number of un-overridden
            \\     parameters shall be selected."
            \\  2. "The paramset with the greatest number of local parameters
            \\     with specified ranges shall be selected."
            \\  3. "The paramset with the fewest ports not connected in the
            \\     instance line shall be selected."
            \\
            \\And then: "It shall be an error if there are still more than one
            \\applicable paramset for an instance after application of these
            \\rules." This is that error — the candidates named in the message
            \\tie on all three counts, so the language gives the elaborator no
            \\way to prefer one. Narrow a `from` range, or override one more
            \\parameter, until the instance's values land in exactly one bin.
            \\
            \\ZERO applicable paramsets is the other failure, E0911.
            ,
        },
        .E0915 => .{
            .title = "connect insertion names no connect module",
            .lrm = "7.7.1",
            .explain =
            \\A connect module auto-insertion statement,
            \\`connect connectmodule_identifier ... ;` (A.1.8
            \\connect_insertion), "declares which connect modules are
            \\automatically inserted when mixed nets of the appropriate types
            \\are encountered" — so the identifier has to name a module
            \\declared with the `connectmodule` keyword (7.6, A.1.2's third
            \\module_keyword alternative).
            \\
            \\Either nothing in the compilation declares the name, or the name
            \\is an ordinary module — the message says which. An ordinary
            \\module cannot be an insertion target because a connect module's
            \\discrete half lives in behavioral code the insertion phase owns,
            \\and 7.6's port
            \\disciplines are what "define the default type of disciplines
            \\which shall be bridged".
            ,
        },
        .E0916 => .{
            .title = "connect resolution names no discipline",
            .lrm = "7.7.2",
            .explain =
            \\In `connect d1, d2 resolveto d3;` (A.1.8 connect_resolution)
            \\every identifier is a discipline_identifier: "the discipline
            \\identifiers before the resolveto keyword are the list of
            \\compatible disciplines and the discipline identifier after is
            \\the discipline to be used". A name no discipline declaration
            \\introduces can neither be matched against a net's candidate list
            \\nor assigned to the net, so the whole statement is dead — and a
            \\misspelled discipline here would otherwise silently turn a
            \\resolving design into an E0903 one.
            \\
            \\`exclude` after `resolveto` is not a discipline and is not this
            \\error: it is the keyword that deems the listed disciplines
            \\incompatible (E0917 when they then meet).
            ,
        },
        .E0917 => .{
            .title = "disciplines excluded by a connect resolution share a net",
            .lrm = "7.7.2",
            .explain =
            \\LRM 7.7.2: "If the keyword exclude follows resolveto rather than
            \\a discipline identifier, then the otherwise compatible
            \\disciplines are deemed to be incompatible and an error is
            \\indicated if they are found on the same net." The clause's own
            \\example is two supply families —
            \\
            \\    connect logic18 logic32 resolveto exclude ;
            \\    connect electrical18 electrical32 resolveto exclude ;
            \\
            \\— "these connect statements prevent ports associated with one
            \\supply voltage to be connected to nets associated with the
            \\other."
            \\
            \\The candidate disciplines of this undeclared net (annex F.2.1
            \\step 4.b's list) match an exclude rule's discipline list
            \\under 7.7.2.1, so the connection the rule exists to forbid is present.
            \\Separate the nets, or delete the exclude rule.
            ,
        },
        .E0918 => .{
            .title = "a wreal net has more than one driver",
            .lrm = "6.5.3",
            .explain =
            \\LRM 6.5.3: "There can be a maximum of one driver of a real-valued
            \\net." 3.7 says the same from the declaration side: a wreal "can be
            \\used for real-valued nets which are driven by a single driver,
            \\such as a continuous assignment."
            \\
            \\There is no resolution function to fall back on. Four-state nets
            \\resolve disagreeing drivers through IEEE 1364's tables; two reals
            \\have no resolved value, no x to collapse to and no strength to
            \\break the tie. So a second driver is refused, not resolved.
            \\
            \\Drive the net from one continuous assignment, or compute the
            \\combined value into a real variable and assign that.
            ,
        },
        .E0919 => .{
            .title = "a wreal net is connected to an incompatible net type",
            .lrm = "3.7",
            .explain =
            \\LRM 3.7: "Compatible interconnect are nets of type wire, tri, and
            \\wreal ... When the two nets connected by a port are of net type
            \\wreal and wire/tri, the resulting single net will be assigned as
            \\wreal. Connection to other net types will result in an error."
            \\
            \\The list is closed. A wand, wor, tri0, supply0 or any other net
            \\type is defined by its resolution function, and merging it into a
            \\wreal would silently delete that function.
            \\
            \\Declare the net on the other side of the port as wire, tri or
            \\wreal.
            ,
        },
        .E0920 => retiredInfo(
            \\"a child instance's digital processes are not supported in a
            \\mixed-signal design". Retired: the mixed-signal runner now binds a
            \\discrete input by its flattened hierarchical name (`u.q`), and its
            \\digital engine elaborates the same instance tree the analog compile
            \\flattened — the connect modules 7.8.4 inserted included — so a
            \\child's `initial` and `always` blocks run as the top's do. The
            \\number is not reused.
        ),
        .E0921 => .{
            .title = "parameter array value is not the size its range declares",
            .lrm = "3.4.4",
            .explain =
            \\LRM 3.4.4 lists restrictions on parameter arrays whose failure
            \\"shall result in an error", and two of them are about size:
            \\
            \\  "An array assigned to an instance of a module to override the
            \\   default value of an array parameter shall be of the exact size
            \\   of the parameter array, as determined by its declaration."
            \\
            \\  "If the array size is changed, the parameter array shall be
            \\   assigned an array of the new size from the same module as the
            \\   parameter assignment that changed the parameter array size."
            \\
            \\So `#(.coefficients('{4.0, 5.0}))` onto `coefficients[0:2]` is an
            \\error, not a padded array, and `#(.count(3))` onto
            \\`coefficients[0:count-1] = '{1.0, 2.0}` must come with a new
            \\three-element `coefficients` in the same instantiation.
            ,
        },
        .E0922 => .{
            .title = "a mixed port matches more than one connect statement",
            .lrm = "7.8.4",
            .explain =
            \\LRM 7.8.4: "A connection shall be selected for a port only if one of
            \\the connections to the port is digital and the other is analog. In
            \\this case, the port shall match one (and only one) connect
            \\statement. The module named in the connect statement is the one
            \\which shall be selected for the port."
            \\
            \\Two `connect` statements whose connect modules bridge the same
            \\discipline pair in the same direction (7.6's Table 7-2, after any
            \\7.7.1 overrides) both match such a port, and nothing chooses between
            \\them: 7.7.2.1's "first match" rule is for `resolveto` statements
            \\only. Keep one statement per discipline pair and direction, or use
            \\7.7.1's overrides to make the pairs differ.
            ,
        },
        .E0927 => .{
            .title = "a mixed port matches no connect statement",
            .lrm = "7.8.4",
            .explain =
            \\LRM 6.5.7: "Ports of both analog and digital discipline may be
            \\connected to a net provided the appropriate connect statements exist
            \\(see 7.7)." LRM 7.8.4: "A connection shall be selected for a port only
            \\if one of the connections to the port is digital and the other is
            \\analog. In this case, the port shall match one (and only one) connect
            \\statement."
            \\
            \\A port is mixed by the disciplines of its two connections after 7.4
            \\resolution, not by what the design does with it: a discrete port on a
            \\net that resolved continuous is mixed whether or not anything crosses.
            \\Zero matching statements break "one (and only one)" as two do
            \\(E0922). Add a `connectrules` block with a `connect` statement whose
            \\connect module bridges the two disciplines (7.7.1), or give both
            \\connections disciplines of one domain.
            ,
        },
        .E0928 => .{
            .title = "a SPICE card inside a .SUBCKT is outside VerA's SPICE subset",
            .lrm = "E.1.2",
            .explain =
            \\LRM E.1.2: "whether a particular Verilog-AMS simulator is SPICE
            \\compatible, and with which particular variant of SPICE it is
            \\compatible, is solely determined by the authors of the simulator."
            \\
            \\VerA claims SPICE3 card syntax for `.MODEL` (types npn, pnp, d, nmos,
            \\pmos, njf, pjf, nmf, pmf, r, c, l, or a Verilog-A module), for
            \\`.SUBCKT` bodies made of numeric-valued R, C, L, V, I, E, F, G and H
            \\cards and of M, Q, J and D cards naming a model, and for `.INCLUDE`,
            \\`.LIB file entry` and `.HDL file` anywhere. In a `.SUBCKT`, `PARAMS:`
            \\and `k=v` on the header, a `{expr}` value, a nested `.SUBCKT`, a
            \\model-referenced R/C/L (`R1 A B RMOD`), an `X`, `S` or other device
            \\card, a binned model (`.MODEL NCH.1 ...`) and a trailing field are
            \\not read; nor is a file an `.INCLUDE` or `.LIB` card names that
            \\cannot be read. Skipping such a card would change the circuit (a
            \\dropped R is an open), so the netlist is refused.
            \\
            \\Cards outside any definition (`.TRAN`, top-level devices) are not
            \\module definitions and are still skipped. Rewrite the card with a
            \\numeric value, or write the subcircuit as a Verilog-AMS module.
            ,
        },
        .E0929 => .{
            .title = "a mixed port's connect module cannot be inserted",
            .lrm = "7.8.4",
            .explain =
            \\LRM 7.8.4: "A connection shall be selected for a port only if one of
            \\the connections to the port is digital and the other is analog. In
            \\this case, the port shall match one (and only one) connect
            \\statement." A connect statement matches this port, but VerA decides
            \\where connect modules go before it inlines a level (7.6: "The
            \\disciplines of mixed nets are determined prior to the connect
            \\module insertion phase"), from the subtree a first walk that
            \\inserts nothing elaborated below it: generate schemes evaluated,
            \\instance arrays expanded, paramsets selected, every out-of-context
            \\declaration applied. That walk found no domain for the port's
            \\upper connection, and the net resolved one afterwards: the segment
            \\that decides it sits under a generate scheme that does not fold to
            \\a constant, or in a subtree the first walk could not elaborate.
            \\
            \\This is a limit of VerA, not of the design: declare the upper
            \\connection's discipline at the level of the port, or instantiate
            \\the connect module by hand (7.8).
            \\
            \\A built-in primitive's terminal (7.8.5.1) is refused the same way
            \\when it is mixed and no bridge can take it whole: it selects a bit
            \\or part of the net, its net is a vector (an instance array's
            \\element on its bit), the primitive sits in a generate block, or it
            \\is a switch instance array. Leaving it on the analog node would
            \\let the primitive read or drive a node no connect module converts.
            \\Connect the primitive to a scalar net, or out of the generate block.
            ,
        },
        .E0930 => retiredInfo(
            \\"detail discipline resolution is not implemented for this signal".
            \\Retired: 7.4.4.2's detail mode (Annex F.2.2, step 5's top-down
            \\pass included) is implemented, so a signal the two modes decide
            \\differently compiles under `--discipline-resolution=detail` with
            \\detail's answer. The number is not reused.
        ),
        .E0923 => .{
            .title = "a connect statement's disciplines are not one discrete and one continuous",
            .lrm = "7.8",
            .explain =
            \\LRM 7.8: "Each connect statement designates a module to be a connect
            \\module. When two disciplines are specified in a connect statement,
            \\one shall be discrete and the other continuous."
            \\
            \\That is what makes a connect insertion statement (7.7.1) a bridge
            \\specification: its two disciplines stand for the connect module's
            \\continuous and discrete ports. Two disciplines of one domain are the
            \\7.7.2 `resolveto` form's business, which resolves a net instead of
            \\bridging it.
            ,
        },
        .E0924 => .{
            .title = "parameter declaration makes an out-of-module reference",
            .lrm = "6.7.1",
            .explain =
            \\LRM 6.7.1, third bullet: "Access of parameters can be done
            \\hierarchically. However, parameter declaration statements shall not
            \\make out-of-module references (e.g., for setting default values)."
            \\
            \\Parameter values are computed during elaboration (6.9.4), so a default
            \\that reads another instance's parameter would need the hierarchy
            \\resolved in order to resolve the hierarchy.
            \\
            \\Read the other parameter in the analog block instead, or pass the
            \\value down as an instance parameter override (6.3).
            ,
        },
        .E0925 => .{
            .title = "port and connected net differ in width",
            .lrm = "6.5.7.1",
            .explain =
            \\LRM 6.5.7.1: "A scalar port can be connected to a scalar net and a
            \\vector port can be connected to a vector net or concatenated net
            \\expression of the matching width. The sizes of the ports and net
            \\must match."
            \\
            \\Verilog-AMS does not carry IEEE 1364's truncate-or-extend rule for
            \\a port connection: each element of a vector port is its own node,
            \\so a width mismatch would leave elements joined to nothing.
            \\
            \\Connect a net of the port's width, or a concatenation of that many
            \\scalar nets.
            ,
        },
        .E0926 => .{
            .title = "defparam in a paramset instance hierarchy",
            .lrm = "6.4",
            .explain =
            \\LRM 6.4 forbids a defparam statement in or under the hierarchy of
            \\the module associated with a paramset. Section 6.3.1 states the
            \\same restriction for the hierarchy of a paramset instance, and
            \\6.9.4 relies on it when ordering parameter and generate elaboration.
            \\
            \\The restriction includes descendants and paramset chains. An
            \\unselected conditional-generate arm is not instantiated (6.6.2).
            \\
            \\Pass values through parameter overrides instead, or place the
            \\defparam outside the paramset instance's hierarchy.
            ,
        },
        .E0960 => .{
            .title = "a digital primitive on a continuous net with no default discipline",
            .lrm = "3.9",
            .explain =
            \\LRM 3.9: "For digital primitives the domain is discrete and thus the
            \\discipline is set via the default_discipline directive as it is for
            \\digital modules. If the discipline of digital connections
            \\(vpiLoConn) to a mixed net are unknown then the default_discipline
            \\must be specified (via the directive or other vendor specific
            \\method). If not specified, an error will result during discipline
            \\resolution."
            \\
            \\A gate, a pullup/pulldown or a switch is a digital primitive, and
            \\each of its terminals is a discrete connection. A terminal naming a
            \\net of a continuous discipline (`electrical`) makes that net mixed,
            \\and discipline resolution then needs the primitive side's
            \\discipline. VerA has no vendor-specific method: the
            \\`default_discipline directive in force at the primitive is the only
            \\source, so without one the connection's discipline is unknown and
            \\this is the error the clause promises.
            \\
            \\Write `default_discipline logic (or another discrete
            \\discipline) before the primitive — and, since the net then joins two
            \\domains, a connect statement for the pair (3.11, 7.8) — or connect
            \\the primitive to a discrete net instead.
            ,
        },
        .E0982 => .{
            .title = "connect module port directions are not a Table 7-2 combination",
            .lrm = "7.6",
            .explain =
            \\LRM 7.6: "The directional qualifiers of the discrete port determine
            \\the default scenarios where the module can be instantiated. The
            \\following combinations of directional qualifiers are supported for
            \\the continuous and discrete disciplines of a connect module:" and
            \\Table 7-2 lists exactly three — continuous input with discrete
            \\output, continuous output with discrete input, and inout with inout.
            \\
            \\A connect statement (7.7.1) designates a module to be a connect
            \\module; with any other pair (two inputs, two outputs, one inout)
            \\there is no scenario it can be inserted in. 7.7.1's direction
            \\overrides "are used to define the type of connect module", so the
            \\pair is judged after them.
            \\
            \\Declare the ports as one of the three pairs, or override them in
            \\the connect statement: `connect cm input electrical, output
            \\ddiscrete;`.
            ,
        },
        .E0997 => .{
            .title = "a hierarchical port access VerA cannot sum",
            .lrm = "5.4.3",
            .explain =
            \\LRM 5.4.3: "The port access function accesses the flow into a port
            \\of a module", and A.8.9 lets the port be hierarchical: `I(<u.p>)`
            \\is the flow into instance u through its own port p. Elaboration
            \\joins u's port onto the net it is connected to, so VerA reads the
            \\flow as what u's hierarchy conducts away from that net: the sum of
            \\its flow contributions to branches at the net.
            \\
            \\That sum is refused when it cannot be exact:
            \\  - the access is read before u's own analog blocks are lowered
            \\    (inside u's hierarchy, or from a sibling written before u);
            \\    read it from a module above u;
            \\  - u drives the net through a potential source or a 5.6.7
            \\    indirect branch, whose current is a solver unknown.
            \\
            \\A module's own `I(<a>)` (or `I(pb)` over its 3.12.1 port branch
            \\`branch (<a>) pb;`) inside an instance u is the same quantity,
            \\`I(<u.a>)`, read from inside u, so it is refused too. Read it
            \\from the module that instantiates u. At the top, `I(<a>)` is the
            \\host's port current and is read exactly.
            ,
        },
        .E0998 => .{
            .title = "a hierarchical name reaches into an unnamed generate block",
            .lrm = "6.6.2",
            .explain =
            \\LRM 6.6.2: "If the generate block selected for instantiation is
            \\not named, it still creates a scope; but the declarations within
            \\it cannot be referenced using hierarchical names other than from
            \\within the hierarchy instantiated by the generate block itself."
            \\6.6.1 says the same of a loop generate, and 6.6.3 adds that an
            \\unnamed generate block "has no name that can be used in a
            \\hierarchical name": `genblk<n>` is its name for external
            \\interfaces (VPI, `$simparam$str("path")`), not for the HDL.
            \\
            \\Name the block to reach into it:
            \\
            \\    if (on) begin : g1  sub u(p);  end
            \\    ... g1.u.r ...       // 6.6.2: "Normal rules for hierarchical naming apply"
            ,
        },
        .E0482 => .{
            .title = "a procedural assignment writes a variable, not a net",
            .lrm = "A.6.2",
            .explain =
            \\A.6.2 derives every procedural write from `variable_lvalue`:
            \\`blocking_assignment ::= variable_lvalue = ...`,
            \\`nonblocking_assignment ::= variable_lvalue <= ...`, and the
            \\procedural continuous `assign variable_assignment` and `deassign
            \\variable_lvalue`. Only `force` and `release` also take a
            \\`net_lvalue`.
            \\
            \\LRM 8.5.3 says what each statement schedules — a blocking one
            \\"performs the assignment to the left-hand side", a nonblocking one
            \\"schedules the update as a nonblocking assign update event" — and
            \\both are updates of a stored value. A net holds no stored value:
            \\its value is the resolution of its drivers (E0438 is the mirror,
            \\a continuous assignment to a variable).
            \\
            \\Declare the target as a `reg`/`integer`/`real`, drive the net
            \\with a continuous assignment, or use `force`.
            ,
        },
        .E0483 => .{
            .title = "a switch terminal is a net, not a variable",
            .lrm = "A.3.3",
            .explain =
            \\A.3.3 makes the terminals a switch drives nets:
            \\`inout_terminal ::= net_lvalue` for both terminals of the pass
            \\switches (`tran`, `tranif0`, `tranif1` and the `r` forms) and
            \\`output_terminal ::= net_lvalue` for the output of a MOS or CMOS
            \\switch.
            \\
            \\LRM 8.5.3.5: "Switch processing shall consider all the devices in
            \\a bidirectional switch-connected net before it can determine the
            \\appropriate value for any node on the net" — the switch is a
            \\driver of a NET, resolved with the net's other drivers. A `reg`
            \\has no drivers to resolve.
            \\
            \\Declare the terminal as a `wire`.
            ,
        },
        .E0484 => .{
            .title = "an A2D event must be an analog event control",
            .lrm = "8.5.1",
            .explain =
            \\LRM 8.5.1: "Note that A2D events must be analog event controlled
            \\statements ( e.g., @cross, @timer). These are scheduled just like
            \\other event controlled statements in Verilog-HDL (e.g., @posedge)."
            \\
            \\A continuous value changes continuously; the discrete context sees a
            \\change of one only through a monitored analog event (7.3.5, Syntax
            \\7-3's analog_event_functions), which the analog solver locates in
            \\time. `@(V(a))` or `@(posedge V(a) > 1)` in an `always` block asks
            \\the digital engine to wake on a probe no analog event function
            \\monitors.
            \\
            \\Write the threshold as an event: `@(cross(V(a) - 1, 1))` or
            \\`@(above(V(a) - 1))`.
            \\
            \\LRM 7.3.6.1 adds one more A2D event: "one can also use analog
            \\variables that are only assigned values in analog event statements
            \\in a digital event control statement." A variable the analog block
            \\assigns outside every event statement (`x = V(a);`) moves with the
            \\solution like the probe it copies, so `@(x)` is refused the same
            \\way. Assign it under an event (`@(timer(0, 1n)) x = V(a);`) or
            \\wait on a monitored event of the value.
            ,
        },

        // ----------------------------------------------------------- class 10
        .W0950 => .{
            .title = "multiple discipline resolution rules match",
            .lrm = "7.7.2.1",
            .explain = "The first matching rule is used. Exact matches take precedence over subset matches. Remove the ambiguity to silence this warning.",
        },
        .E0952 => .{
            .title = "a SPICE model names a primitive VerA does not support",
            .lrm = "E.1.2",
            .explain =
            \\E.1.2: "Not all SPICE simulators support the same set of component
            \\primitives. Thus, a particular SPICE netlist can reference a
            \\primitive which is unsupported. Verilog-AMS HDL offers no
            \\alternative in this case other than the possibility that if the
            \\model equations are known, the primitive can be rewritten as a
            \\module."
            \\
            \\A `.MODEL name type` card declares `name` as a model of the SPICE
            \\primitive `type`. VerA reads the types Table E.1 names (r, c, l,
            \\d, npn, pnp, nmos, pmos, njf, pjf, nmf, pmf); any other (`sw`,
            \\`csw`, `ltra`, `urc`, ...) declares no module, and an instance of
            \\the model is this error, at the instance.
            \\
            \\As the clause says, write the primitive's equations as a
            \\Verilog-AMS module of the same name: E.3.3 then selects the module.
            ,
        },
        .E0953 => .{
            .title = "a SPICE device card's model is a primitive with no behaviour",
            .lrm = "E.2",
            .explain =
            \\An M, Q, J or D card inside a `.SUBCKT` names a model, and the model
            \\is a `.MODEL` card of a Table E.1 type: nmos, pmos, npn, pnp, d,
            \\njf, pjf, nmf or pmf. Table E.1 leaves the Behavior column of those
            \\rows (mosfet, bjt, diode, jfet, mesfet) empty, and E.2 says "all
            \\aspects of SPICE primitives are implementation dependent". VerA has
            \\no equations for them, so the card would be a device that conducts
            \\nothing: an open where the netlist has a transistor. It is refused
            \\at the card instead.
            \\
            \\E.1.2 gives the remedy: "if the model equations are known, the
            \\primitive can be rewritten as a module". Give the model as a
            \\Verilog-A module and name the module as the `.MODEL`'s type:
            \\
            \\    .MODEL NCH BSIMCMG TYPE=1 ...     (with BSIMCMG compiled in,
            \\                                       e.g. `.HDL "bsimcmg.va"`)
            \\
            \\or name the module (or a paramset) on the card itself. HSPICE's
            \\`.MODEL NCH NMOS LEVEL=72` is this error: LEVEL selects an HSPICE
            \\built-in, which a Verilog-AMS compiler does not have.
            ,
        },
        .W0951 => .{
            .title = "a Verilog-AMS definition shadows a SPICE model or subcircuit",
            .lrm = "E.3.3",
            .explain =
            \\A Verilog-AMS module or paramset takes precedence over a SPICE
            \\model or subcircuit with the same name. E.3.3 requires this
            \\warning so the selected definition is explicit. Rename one
            \\definition to make both available under distinct names.
            \\
            \\Shadowing an always-available Table E.1 primitive permits an
            \\optional warning; VerA does not warn for that case. Names that
            \\differ in case retain E.2.1's case-sensitive HDL lookup followed
            \\by case-insensitive SPICE lookup.
            ,
        },
        .E1001 => .{
            .title = "source contains no module declaration",
            .lrm = "6.2",
            .explain =
            \\A compilation unit must declare at least one `module`. If the
            \\file holds only `discipline`, `nature` or `` `define `` items, it
            \\is a header — include it from a module instead of compiling it.
            \\
            \\If the file DOES contain a design element, it is one that is not a
            \\device. `primitive` and `library` have no parser at all, and the
            \\earlier diagnostics name which one. A `connectmodule` parses and is
            \\accepted (LRM 7.6, A.1.2's third `module_keyword`) but is still not
            \\a device: LRM 7.6 makes it the bridge the connect module INSERTION
            \\PHASE places on a mixed net, so it is instantiated by the tool and
            \\never elaborated on its own. A `connectrules` block (LRM 7.7)
            \\parses too, and is configuration for that same phase — a source of
            \\connect modules and connect rules alone still has no device. Put
            \\the module that uses them in the same compilation.
            \\
            \\A `paramset` is NOT one of them any more (LRM 6.4), but it is not a
            \\module either: it is a bundle of parameter values FOR a module, so a
            \\file of paramsets alone still has no device to compile. Compile the
            \\file that declares the module and instantiate the paramset from it.
            ,
        },
        .E1002 => retiredInfo(
            \\"generated identifier is too long". Retired: the condition is
            \\real — code generation builds a structural key per unit from the
            \\module name, the role and the target, and a key can overflow the
            \\fixed name buffer (never truncated: truncation would break the
            \\injectivity two distinct units rely on) — but no diagnostic with
            \\this code is ever built. The refusal was codegen's
            \\error.NameTooLong, past an 8192-byte name buffer. Since #29 every
            \\name buffer is sized from the name itself (LRM 2.8 lets an
            \\implementation set no limit, VD-054), so no length is refused. A
            \\catalogue entry for a code that never renders only misleads
            \\`--explain`.
            \\
            \\If codegen ever reports the overflow through the bag, with a
            \\source location, that report takes a NEW number. This one is not
            \\reused.
        ),
        .E1003 => retiredInfo(
            \\"more solver unknowns than the device contract can hold". Retired
            \\(#29): the emitted `U` was an `enum(u8)`, so a device held at most
            \\256 unknowns, below the 256 ports LRM 6.5.2.2 requires an
            \\implementation to accept before its internal nodes. `U` is now an
            \\`enum(u8)` up to 256 unknowns and as wide as the count needs past
            \\them; `lib/contract.zig` takes any unsigned tag of 8 bits or more.
            \\This code is not reused.
        ),
        .E1100 => .{
            .title = "digital source execution failed",
            .lrm = "8.5",
            .explain = "The digital executor supports a documented subset of source processes. Unsupported forms are diagnosed before simulation; timing and capacity failures stop execution explicitly. This does not make legal unsupported Verilog-AMS forms illegal.",
        },
        .E1102 => .{
            .title = "back-annotation from an SDF file is not supported",
            .lrm = "IEEE 1364-2005 17.2.10",
            .explain =
            \\$sdf_annotate (IEEE 1364-2005 17.2.10) runs the SDF annotator of
            \\clause 16, which replaces a design's specify path delays, specparams,
            \\timing check limits and interconnect delays with values read from
            \\an SDF file. VerA does not implement clause 16, and it applies no
            \\specify path delay for one to replace (W0251). Running on as if
            \\the call had succeeded would simulate a design whose timing the
            \\file was meant to set, so the call is refused.
            \\
            \\Write the delays the design needs in its source: a delay control,
            \\a continuous assignment or gate delay, or a module-level specparam
            \\that one of those reads. A timing check's limits are the ones its
            \\source writes (or a VPI application puts, IEEE 1364-2005 27.31).
            ,
        },
        .E1147 => .{
            .title = "a timing check argument the digital engine cannot bind",
            .lrm = "IEEE 1364-2005 15.5",
            .explain =
            \\`vera --run` evaluates a module's timing checks against the
            \\signals their events name and toggles the notifier a violation
            \\updates. It refuses a check whose arguments it cannot bind:
            \\
            \\  - a notifier that is not a variable. 15.5: "The notifier is a
            \\    reg, declared in the module where timing check tasks are
            \\    invoked", and A.7.5.2 `notifier ::= variable_identifier`. A
            \\    net, a real, a parameter or an array has no reg value for
            \\    Table 15-13 to toggle;
            \\  - an event terminal that is not a name, or a constant bit- or
            \\    part-select of at most 64 bits of a vector (A.7.3
            \\    `specify_input_terminal_descriptor ::= input_identifier
            \\    [ [ constant_range_expression ] ]`), or that names a real or
            \\    an array.
            \\
            \\Name a reg as the notifier, and a port (or a constant select of
            \\one) as each event.
            ,
        },
        .E1148 => .{
            .title = "a timing check limit that is not a non-negative constant",
            .lrm = "IEEE 1364-2005 15.1",
            .explain =
            \\15.1: "Like expressions for module path delays, timing check limit
            \\values are constant expressions that can include specparams", and
            \\Tables 15-1, 15-2, 15-4, 15-5, 15-10 and 15-11 give the limit of
            \\$setup, $hold, $removal, $recovery, $width and $period, and
            \\$width's threshold, as a "Non-negative constant expression".
            \\A limit that reads a signal, or one of those six below zero, is
            \\refused. $setuphold and $recrem take negative limits (15.8),
            \\which VerA, without a negative timing check option, takes as 0
            \\(15.5.4).
            ,
        },
        .E1149 => .{
            .title = "a timing check VerA's digital engine does not evaluate",
            .lrm = "IEEE 1364-2005 15",
            .explain =
            \\`vera --run` evaluates all twelve commands (IEEE 1364-2005 15.2,
            \\15.3), their notifiers (15.5), conditioned events (15.6) and
            \\vector signals (15.7), a negative $setuphold or $recrem limit as
            \\0 (15.5.4: VerA has no negative timing check option). It does not
            \\evaluate, and so refuses rather than run a design whose checks
            \\would silently misjudge:
            \\
            \\  - a $setuphold or $recrem stamptime or checktime condition
            \\    (15.5.2), which exists for negative checks;
            \\  - a negative end edge offset of $nochange (15.3.6), a window
            \\    ending before its trailing reference edge.
            \\
            \\The analog solver never evaluates a timing check (W0251).
            ,
        },
        .E1101 => .{
            .title = "design refused under --two-state",
            .lrm = "IEEE 1364-2005 4.1",
            .explain =
            \\`vera --emit-exe --two-state` builds a native executable in which
            \\every x or z the design would create is 0: an uninitialised
            \\variable, an undriven net, an x or z literal bit, an out-of-range
            \\select, a division by zero. That is not the 4-state logic of IEEE
            \\1364-2005 §3.2 and §4.1, and its output differs wherever an x or z
            \\would have arisen.
            \\
            \\A design is refused where an x or z carries meaning, which a run
            \\without them cannot keep: `===` or `!==` against an x or z, a `case`
            \\label with an x or z bit, `$sscanf` (an x or z in its input is EOF,
            \\IEEE 1364-2005 §17.2.4.3), a §17.5.4 plane PLA (a z personality bit
            \\ignores its input), a §7.9 net resolved from strengths or several
            \\drivers or driven by a three-state, switch, UDP or pull driver, and
            \\any design the native code generator does not compile, which runs
            \\only in the 4-state interpreter. Drop `--two-state` to run it with
            \\4-state logic.
            ,
        },
        .E1103 => .{
            .title = "design cannot be a contract device",
            .lrm = "7.8",
            .explain =
            \\`vera --emit-zig`, `--check` and `--emit-so` of a `.v` design build a
            \\contract device an analog host loads: every bit of the top module's
            \\ports is a pin, an `input` bit sensed through an analog-to-digital
            \\bridge and an `output` bit driven through a digital-to-analog one, the
            \\connect modules LRM 7.8 inserts where a digital port meets an
            \\electrical net. The design's processes run natively inside the
            \\device, which saves and restores their state at every tick so a host
            \\can reject a time step.
            \\
            \\The message names what the device cannot hold: an `inout` port (the
            \\analog side would be a driver of a resolved net), a real, integer or
            \\time port, more than 65535 pins (a contract mask is one integer, a bit
            \\per pin, and Zig's widest is u65535), a construct the native code generator
            \\does not compile, a file a device would read, a procedural continuous
            \\assignment, or a logic mode other than 4-state (`--state=4`, the
            \\default for a device; `--state=auto` reruns a design from time 0,
            \\which a host that owns time cannot allow). `vera --run` and
            \\`--emit-exe` still run such a design on its own.
            ,
        },
        .E1104 => .{
            .title = "a SystemVerilog source is not supported",
            .lrm = "",
            .explain =
            \\A `.sv` file is SystemVerilog (IEEE 1800), a different language from
            \\the IEEE 1364-2005 Verilog and Verilog-AMS VerA compiles. Its
            \\constructs (`always_ff`, `logic`, `interface` and the rest) would
            \\otherwise surface as misleading Verilog parse errors, so the file is
            \\refused by its extension. Write the design in IEEE 1364-2005 Verilog
            \\and name it `.v`.
            ,
        },
        .W1150 => .{
            .title = "memory file word count mismatch",
            .lrm = "IEEE 1364-2005 17.2.9",
            .explain = "Without address specifications in the memory file, a data-word count different from the requested load range requires a warning. Available words are loaded within the range; missing words leave existing memory contents unchanged. This warning does not refuse the load.",
        },
        .W1151 => .{
            .title = "probabilistic distribution argument not positive",
            .lrm = "IEEE 1364-2005 17.9.2",
            .explain = "The mean of $dist_exponential, $dist_poisson and $dist_erlang, the degree of freedom of $dist_chi_square and $dist_t, and the k_stage of $dist_erlang shall be greater than 0. The 17.9.3 reference listing prints a warning for such a call and returns 0 without drawing, so the seed argument is not written.",
        },
        .W1152 => .{
            .title = "two cells with one name in one library",
            .lrm = "IEEE 1364-2005 13.2.1.1",
            .explain =
            \\IEEE 1364-2005 13.2.1.1: "If multiple cells with the same name map
            \\to the same library, then the LAST cell encountered shall be
            \\written to the library. ... In the case where multiple modules
            \\with the same name are mapped to the same library in a single
            \\invocation of the compiler, then a warning message shall be
            \\issued." This is that warning; the later definition is the one
            \\every instance binds.
            ,
        },
        .W1153 => .{
            .title = "format specifiers and arguments do not pair up",
            .lrm = "IEEE 1364-2005 17.2.3",
            .explain = "The arguments after $sformat's format are consumed by its format specifiers. If not enough arguments are supplied for the specifiers, or too many are supplied, the application shall issue a warning and continue execution: the variable receives the text formatted so far.",
        },
        .W1154 => .{
            .title = "file output not written",
            .lrm = "IEEE 1364-2005 17.2.1",
            .explain = "$fclose closes the channels a descriptor names and does not allow any further output to them. A $fdisplay or $fwrite whose descriptor names only closed channels, or a file opened only for reading, writes nothing; $ferror reports the error. The simulation continues.",
        },
        .W1155 => .{
            .title = "device digital tick is 1 s",
            .lrm = "IEEE 1364-2005 19.8",
            .explain = "A design with no `timescale directive runs at the simulator's default time unit and precision, which for VerA is 1 s. A contract device built from it delivers every analog-to-digital event at a whole second and schedules every delay in seconds, which an analog host rarely means. Add a `timescale directive (for example `timescale 1ns/1ps) to the design.",
        },
        .W1156 => .{
            .title = "memory file address outside the memory",
            .lrm = "IEEE 1364-2005 17.2.9",
            .explain = "A `$readmemb`/`$readmemh` call with no start or finish argument met an `@` address outside the memory's declared range. The clause's error for an address outside the load range applies only when the task gives addresses, so VerA does not stop the load: the words at addresses outside the memory are skipped, and loading continues at the next in-range address. The warning names the first such address (specification/Vague_Decisions.md VD-040).",
        },
        .E1157 => .{
            .title = "memory file address outside the task's load range",
            .lrm = "IEEE 1364-2005 17.2.9",
            .explain = "A `$readmemb`/`$readmemh` call that gives a start (and finish) address met an `@` address in the file outside that range. §17.2.9 makes that an error that ends the load operation. VerA issues this error and stops that load: the words loaded before the address stay, none after it is loaded, and the simulation goes on. The run exits 1 when it ends, because an error was issued. With no start or finish argument the rule does not apply (W1156).",
        },
        .W1160 => .{
            .title = "dissimilar net types joined through a port",
            .lrm = "IEEE 1364-2005 12.3.10",
            .explain =
            \\IEEE 1364-2005 Table 12-1 gives, for each pair of internal (the
            \\module's) and external (the instantiation's) net types joined by a
            \\port, the net type that dominates, and marks some pairs "warn = A
            \\warning shall be issued": two wired-logic types that disagree
            \\(wand with wor), a pull or charge-storage net meeting another, a
            \\uwire meeting a resolved net, supply0 meeting supply1. VerA joins
            \\the two into the external net and issues this warning.
            ,
        },
        .W1199 => .{
            .title = "timing violation",
            .lrm = "IEEE 1364-2005 15.2",
            .explain =
            \\A timing check of the design detected a violation while `vera
            \\--run` ran it: 15.2's stability window ($setup, $hold, $setuphold,
            \\$removal, $recovery, $recrem) held a transition it forbids, or
            \\15.3.4's $width or 15.3.5's $period measured a pulse or a period
            \\shorter than its limit. The warning is at the check, naming the
            \\instance and the times of its timestamp and timecheck events in
            \\the instance's time unit (specification/Vague_Decisions.md VD-105). Like
            \\every diagnostic it is reported once per site, so it is the
            \\check's FIRST violation; each later one still toggles the
            \\check's notifier as Table 15-13 says (VD-103) and runs a VPI
            \\application's cbTchkViolation callbacks. The run goes on: a
            \\violation is the design's report, not an error of the
            \\simulator's.
            \\
            \\  --allow=W1199    silence the reports (the notifier still toggles)
            ,
        },
        .E1004 => .{
            .title = "unsupported dependent parameter expression",
            .lrm = "6.3.4",
            .explain =
            \\A dependent parameter must follow the final values of the parameters
            \\it references. VerA cannot yet render this expression for the host's
            \\derive callback, so retaining its declared-default value would be wrong.
            \\
            \\Pure two-way conditional expressions and short-circuit logical
            \\operators are supported. Arbitrary constant-function control flow,
            \\loop-carried or multiway values, unsupported operators and expressions
            \\beyond the renderer's recursion limit remain implementation gaps.
            ,
        },
        .E1010 => retiredInfo(
            \\"a display or format call has more than 32 conversions". Retired:
            \\a call with more operands than one Zig format call takes (32) is
            \\now emitted as consecutive calls of at most 32 each, so LRM 9.4.1's
            \\argument list has no bound and the condition does not exist to
            \\report (#29). The number is not reused.
        ),
        .E1011 => .{
            .title = "text exceeds the buffer sized for it",
            .lrm = "",
            .explain =
            \\An engine limit on what a model computes while it runs, not a
            \\language rule. A device has no allocator, so every string it builds
            \\while it runs lives in a row the compiler sized when the model
            \\compiled: each `$sformat`, `$swrite`, file-output, `$monitor` or
            \\string-concatenation site, and each held (LRM 5.10) string. The
            \\size is the longest text the model can put there: the format's own
            \\text, each conversion's widest rendering at its written width and
            \\precision, and each string operand's own size, never below 4096
            \\bytes. No field width, precision, replication or concatenation the
            \\source writes is refused.
            \\
            \\What the compiler cannot know is a string's length that only the
            \\run decides: a string parameter the card sets, a `$fgets` line, a
            \\`$value$plusargs` value, an array element, a width spelled in a
            \\run-time format string, or a held string that grows by itself every
            \\step. Each counts 4096 bytes. Text that outgrows its row ends the
            \\run with this code and exit status 1: LRM 9.5.3 gives no truncation
            \\rule, so a cut or empty string would be a wrong value, not a
            \\shorter right one. A line read from a file has no row of its own;
            \\it grows to fit, and only running out of memory reports this code.
            \\
            \\Format such a string with a literal format, whose widths the
            \\compiler reads, or split the text over several calls: two `$fwrite`
            \\calls to one descriptor write the same bytes as one.
            ,
        },
        .E1012 => retiredInfo(
            \\"absdelay needs a sample older than its history holds". Retired:
            \\a full absdelay ring now thins its older samples instead of
            \\dropping them, so the window (maxdelay, or td) is always covered
            \\and no lookback runs past the history (W1051 reports the first
            \\thinning) (#29). The number is not reused.
        ),
        .E1013 => .{
            .title = "a file is larger than VerA reads",
            .lrm = "",
            .explain =
            \\A source file named on the command line, an `include file (LRM
            \\10.3), a `--spice` netlist or a file its `.INCLUDE` or `.LIB`
            \\card names holds more than 2^32 - 1 bytes. Every later stage
            \\locates a token by a 32-bit offset into the text, so this is a
            \\bound of VerA's representation, not a language rule. A regular
            \\file is refused from its size before it is read; a stream with
            \\no size (a pipe) is read until it passes the bound.
            \\
            \\The data file of a `$table_model` (LRM 9.21) or `noise_table`
            \\(LRM 4.6.4.3) call has no bound but memory. Until 2026-10 the
            \\bounds were 16 MiB (`include and data files) and 64 MiB (the
            \\source and a netlist).
            ,
        },
        .E1014 => .{
            .title = "a system function name VerA reserves",
            .lrm = "",
            .explain =
            \\An engine limit, not a language rule. LRM 2.8.3 lets any `$` name
            \\be a user system function, but VerA spells some of its own
            \\internal calls as `$` names (`$held_real`, `$idx`, `$limit$old`,
            \\`$str$cat`, the `$rng$` family and a few more), and a source call
            \\with one of those spellings would reach code that expects
            \\VerA's own arguments. The call is refused where it is written.
            \\
            \\Rename the system function; a VPI application can register it
            \\under any other `$` name.
            ,
        },
        .E1015 => .{
            .title = "more nets and unknowns than a 32-bit row index holds",
            .lrm = "",
            .explain =
            \\Not a language rule and not a design limit. VerA numbers a
            \\module's nets, ports, branch flows and analog operator states in
            \\one table with 32-bit rows, so a module holds up to 4294967294 of
            \\them and a vector range (LRM 3.6.3) as many elements. Each row
            \\costs lowering state of its own, so a module this size runs out
            \\of memory first; the code fires only on a range whose folded
            \\bounds alone pass the index space (`[0:5000000000]`). Until #29
            \\the rows were 16-bit and the bound was 65535.
            ,
        },
        .E1016 => .{
            .title = "an array or assignment pattern has more elements than a 32-bit index holds",
            .lrm = "",
            .explain =
            \\Not a language rule and not a design limit. VerA indexes the
            \\elements of an analog-context array (LRM 3.2, 3.4.4) and of an
            \\assignment pattern (LRM 4.2.14) with 32 bits, so one holds up to
            \\4294967295 of them. Each element is at least a real of storage,
            \\so an array this size runs out of memory first; the code fires
            \\only on bounds whose product alone passes the index space
            \\(`real a[0:65535][0:65536]`). Until #29 the bound was 2^20.
            ,
        },
        .E1017 => retiredInfo(
            \\"a UDP has more than 64 inputs". Retired 2026-10: IEEE 1364-2005
            \\8.1.2 lets an implementation limit a UDP's inputs, and VerA no
            \\longer does; a table of any width parses and runs. The number
            \\is not reused.
        ),
        .E1018 => retiredInfo(
            \\"the instance tree is more than 64 instances deep". Retired: LRM
            \\6.2.2 bounds nothing about the depth of a finite instance tree,
            \\and VerA now elaborates any depth. A cycle, which no depth would
            \\finish, is still E0905, named module by module. The number is
            \\not reused.
        ),
        .E1019 => .{
            .title = "a number literal's size exceeds 4294967295 bits",
            .lrm = "",
            .explain =
            \\LRM 2.6.1 lets a based number give its size in bits and bounds
            \\nothing about it, and IEEE 1364-2005 4.3.1 asks a tool for
            \\vectors of at least 65536 bits. VerA carries every width as a
            \\32-bit unsigned count, so a size (or the width an unsized
            \\literal's digits need) of 2^32 bits or more cannot be
            \\represented. Any smaller size is taken; memory is the bound
            \\(a literal allocates two bits of value per bit of size).
            \\
            \\Until 2026-10 the bound was 2^24 bits.
            ,
        },
        .E1020 => .{
            .title = "the code generator met a call it cannot render",
            .lrm = "",
            .explain =
            \\A compiler defect, not a language rule. Every call that reaches
            \\code generation was checked by lowering, so a call codegen has no
            \\rendering for, or one whose arguments lowering left malformed, is
            \\an internal inconsistency. The device is refused rather than built
            \\with a placeholder 0 in that place.
            \\
            \\Report it with the source that produced it.
            ,
        },
        .E1099 => .{
            .title = "`--emit-osdi` cannot carry `$vera_reject_step`",
            .lrm = "",
            .explain =
            \\A limit of the OSDI 0.4 interface, not a language rule.
            \\`$vera_reject_step(t)` is VerA's task for asking the host to reject
            \\the transient step it just accepted and retry it ending at `t`
            \\(`contract.UpdateResult.request_reject_at`). An OSDI library has no
            \\return value or callback that carries such a request to the
            \\simulator, so the library would accept every step the device asked
            \\to reject. VerA refuses to build it rather than build a device that
            \\silently ignores the call.
            \\
            \\The same source builds for a host that has the slot: `--emit-so`,
            \\`--emit-exe` and `--run`. For an OSDI simulator, drop the call.
            ,
        },
        .W1098 => .{
            .title = "`--emit-osdi` reports correlated noise rows as independent sources",
            .lrm = "4.6.4.6",
            .explain =
            \\LRM 4.6.4.6: "Perfectly correlated noise is generated by using the
            \\output of one noise function for more than one noise source." The
            \\device publishes such rows with one `source` id
            \\(`contract.NoiseGen.source`), and their cross-spectrum is the
            \\product of their coefficients times the generator's density.
            \\
            \\OSDI 0.4 describes a noise source by its node pair and its density
            \\alone: it has no slot for a correlation between two sources. The
            \\library therefore reports each row as its own independent source,
            \\and a noise analysis of it misses the cross term. DC, AC and
            \\transient analyses are unaffected.
            \\
            \\`--deny=W1098` refuses the build instead.
            ,
        },
        .W1050 => .{
            .title = "parameter default has no compile-time value",
            .lrm = "3.4.1",
            .explain =
            \\LRM 3.4.1 makes a parameter's default a `constant_expression`. This
            \\one is not: it reads a quantity only the simulator has, such as
            \\9.10's `$temperature` or 9.18's `$simparam`. There is nothing to
            \\fold, so the generated `Model` field initializer is 0.
            \\
            \\That is not always wrong — the host writes the model card and can
            \\put the real value in the field before the first solve. It IS
            \\wrong if you expected `Model{}` alone to be usable, because a
            \\temperature of 0 K or a gmin of 0 will not converge.
            \\
            \\A default that is an arithmetic expression over OTHER parameters
            \\does not reach here: 6.3.4 makes it a `derive()` line, and calling
            \\`derive` after writing the card gives it its value.
            \\
            \\Fix it by giving the parameter a constant default and reading the
            \\simulator quantity in the analog block instead, where 9.10 and
            \\9.18 say it is evaluated. Or take the field as the host's to
            \\write, and `--allow=W1050`.
            ,
        },
        .W0853 => .{
            .title = "$limit is not applied at this call",
            .lrm = "9.17.3",
            .explain =
            \\LRM 9.17.3 leaves limiting to the simulator: "In all cases, the
            \\simulator is responsible for determining if limiting should be
            \\applied ... In particular, the simulator may simply choose to have
            \\$limit() return the value of its first argument". So the source
            \\is legal and compiles; this call returns its probe unchanged, and
            \\Newton runs on it without the clamp you asked for.
            \\
            \\VerA's clamps are applied by the host to the node voltages
            \\between the linear solve and the next evaluation, which is what
            \\decides the calls it can honour:
            \\
            \\  - the string names an algorithm VerA implements: pnjlim, fetlim,
            \\    limvds, fetlimds, pnjlimds, steplim. An unknown name, or none,
            \\    leaves the choice to the simulator "just as if no string had
            \\    been supplied", and VerA's choice is none;
            \\  - the first argument is a potential probe V(a) or V(a,b): there
            \\    must be a node to correct. A flow has none (`type*V(a,b)` is
            \\    not an access function reference at all: E0891);
            \\  - the call is not under an `if`: the clamp list has no control
            \\    flow. A polarity guard is the trailing sign argument instead,
            \\    `$limit(V(b,e), "pnjlim", vte, vcrit, type)`;
            \\  - at least one net is internal: the host never moves a port,
            \\    because other devices share it. A junction straight across
            \\    two ports (no series resistance) has nothing to correct. A
            \\    pnjlimds rung is the exception: it writes its bulk, port or not;
            \\  - the arguments the algorithm takes are present and real;
            \\  - a `fetlimds` site is one of two on the same gate, with a
            \\    `limvds` across the two internal channel nodes; a `pnjlimds`
            \\    site is one of two on the same bulk, with a `limvds` across
            \\    their two channel nodes.
            \\
            \\The help line under the warning names the change for this call.
            \\Silence it for a model that converges without the clamp with
            \\`--allow=W0853`.
            ,
        },
        .W0854 => .{
            .title = "$limit seed is not applied here",
            .lrm = "9.17.3",
            .explain =
            \\A `$limit` seed argument starts that site's BRANCH at a value (SPICE's
            \\MODEINITJCT, mos1load.c:397-408), and the host's limited image
            \\holds NODE values. So the seeded branches are solved into nodes as
            \\a tree: each group of connected nets has one root at 0 V (ground,
            \\else its lowest port, else its lowest net), and every other net
            \\follows its branch. A seed that tree cannot take is dropped:
            \\
            \\  - its branch is the vgd leg of a fetlimds ladder or the vbd leg of
            \\    a pnjlimds rung, which is derived through vds;
            \\  - an earlier site already seeds the same pair of nets;
            \\  - it closes a loop: the other branches already fix both its nets.
            \\
            \\A junction with no seed joins the tree at its vcrit.
            ,
        },
        .W1051 => .{
            .title = "absdelay history thinned to cover its delay",
            .lrm = "4.5.7",
            .explain =
            \\LRM 4.5.7 defines absdelay over all past time, Output(t) =
            \\Input(max(t - td, 0)), and states no history rule. A device has
            \\no allocator, so each absdelay site keeps its accepted samples in
            \\a fixed ring inside `Instance`: ceil(maxdelay / 1ps) + 2 samples
            \\when maxdelay folds, clamped to [1024, 16384], else 1024.
            \\
            \\A ring whose oldest sample is still inside the window (maxdelay,
            \\or td when there is none) when it fills is thinned, not cut: the
            \\older half keeps every other sample, the newer half stays whole,
            \\and a lookback interpolates over what is left. The window is
            \\always covered, so the delay is never shortened; what changes is
            \\the resolution of the oldest part of the history. Each thinning
            \\doubles the spacing of the samples it touches. This warning prints
            \\once per site, the first time, with the widest spacing left.
            \\
            \\A run that never fills its ring answers exactly as before. To keep
            \\full resolution, give the call its maxdelay (absdelay(x, td,
            \\td_max)) or take fewer, larger steps across the delay.
            ,
        },
    };
}

test "every code has info and a well-formed name" {
    const std = @import("std");
    const e = @typeInfo(Code).@"enum";
    inline for (e.field_names, e.field_values) |name, value| {
        const c: Code = @fromBackingInt(@intCast(value));
        const i = info(c);

        // The tag name IS the rendered code: one letter, then four digits.
        try std.testing.expectEqual(@as(usize, 5), name.len);
        try std.testing.expect(name[0] == 'E' or name[0] == 'W');
        for (name[1..]) |ch| try std.testing.expect(ch >= '0' and ch <= '9');

        // A title that is empty, capitalised or punctuated renders wrong: it is
        // pasted straight after "error[E0313]: ".
        try std.testing.expect(i.title.len > 0);
        try std.testing.expect(i.title[i.title.len - 1] != '.');
        try std.testing.expect(!(i.title[0] >= 'A' and i.title[0] <= 'Z'));
        try std.testing.expect(i.explain.len > 0);
    }
}

test "a refusal cites the clause that states its rule (#62)" {
    const std = @import("std");
    // §4.2.11: "The arithmetic shift operators can not be used in an analog
    // block." §4.2.10: "The reduction operators can not be used inside the
    // analog block". Annex C.5 removes only `===` and `!==`, so neither is C.
    try std.testing.expectEqualStrings("4.2.11", info(.E0324).lrm);
    try std.testing.expectEqualStrings("4.2.10", info(.E0320).lrm);
    // §3.6.1.2 defines the `access` attribute; the 2023 LRM has no §3.6.1.4.
    try std.testing.expectEqualStrings("3.6.1.2", info(.E0501).lrm);
}

test "a parse error cites the production that derives the text (#68)" {
    const std = @import("std");
    // A.1.2: "source_text ::= { description }". E0201 is a token that begins
    // no description; annex C (the Verilog-A subset) states no such rule.
    try std.testing.expectEqualStrings("A.1.2", info(.E0201).lrm);
    // E0207 fires inside every production; A.1.2's start symbol is the one
    // they all derive from, where the bare "A" named the whole annex.
    try std.testing.expectEqualStrings("A.1.2", info(.E0207).lrm);
}
