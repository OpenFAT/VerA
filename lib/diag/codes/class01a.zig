//! The diagnostic catalogue's class 1 rows, lexical and preprocessing (preprocessor.zig, the lexer), part a:
//! `E0101` .. `E0130`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .E0101 = .{
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
    .E0102 = .{
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
    .E0103 = .{
        .title = "expected a directive or macro name after '`'",
        .lrm = "10",
        .explain =
        \\A backtick must be followed immediately by a compiler directive
        \\keyword (`define, `include, `ifdef, ...) or by the name of a
        \\macro to expand. Whitespace or a non-identifier character after
        \\the backtick has no meaning.
        ,
    },
    .E0104 = .{
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
    .E0105 = .{
        .title = "`else / `elsif without `ifdef",
        .lrm = "10.5",
        .explain =
        \\`else and `elsif may only appear inside a conditional block
        \\opened by `ifdef or `ifndef. Check for an extra `endif above
        \\this line that closed the block early.
        ,
    },
    .E0106 = .{
        .title = "`else / `elsif after `else",
        .lrm = "10.5",
        .explain =
        \\A conditional block has at most one `else, and it must be the
        \\last arm. Every `elsif has to precede it.
        ,
    },
    .E0107 = .{
        .title = "`elsif requires a macro name",
        .lrm = "10.5",
        .explain =
        \\`elsif takes exactly one macro name to test, exactly like
        \\`ifdef. Bare `elsif is not a synonym for `else.
        ,
    },
    .E0108 = .{
        .title = "`endif without `ifdef",
        .lrm = "10.5",
        .explain =
        \\This `endif closes a conditional block that was never opened.
        \\Usually one `endif too many, or an `ifdef that was deleted
        \\without its partner.
        ,
    },
    .E0109 = .{
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
    .E0110 = .{
        .title = "malformed formal argument list for `define",
        .lrm = "10.4",
        .explain =
        \\The parentheses after a function-like macro name must contain a
        \\comma-separated list of plain identifiers. Defaults, types and
        \\nested parentheses are not part of the grammar.
        ,
    },
    .E0111 = .{
        .title = "unterminated formal argument list for `define",
        .lrm = "10.4",
        .explain =
        \\The '(' that opened a function-like macro's formal argument list
        \\has no matching ')' before the end of the definition. Remember
        \\that a `define body ends at the first unescaped newline, so a
        \\list continued onto the next line needs a trailing backslash.
        ,
    },
    .E0112 = .{
        .title = "expected ',' or ')' in `define argument list",
        .lrm = "10.4",
        .explain =
        \\Formal arguments of a function-like macro are separated by
        \\commas and closed by a single ')'.
        ,
    },
    .E0113 = .{
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
    .E0114 = retiredInfo(
        \\"unsupported compiler directive". Retired: it had exactly two
        \\subjects left, 10.7's `__FILE__ and `__LINE__, and both are now
        \\expanded. Every other backtick word VerA does not know is an
        \\undefined macro, which is E0115. The number is not reused.
    ),
    .E0115 = .{
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
    .E0116 = .{
        .title = "function-like macro used without an argument list",
        .lrm = "10.4",
        .explain =
        \\This macro was defined with a formal argument list, so every use
        \\must supply actual arguments in parentheses. A function-like
        \\macro named without '(' is not a shorthand for its body.
        ,
    },
    .E0117 = .{
        .title = "macro argument count mismatch",
        .lrm = "10.4",
        .explain =
        \\A function-like macro must be invoked with exactly as many
        \\actual arguments as it declares formals. Arguments are split on
        \\top-level commas only: a comma inside nested parentheses, or
        \\inside a string, belongs to the argument that contains it.
        ,
    },
    .E0118 = .{
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
    .E0119 = .{
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
    .E0120 = .{
        .title = "unterminated macro argument list",
        .lrm = "10.4",
        .explain =
        \\The '(' opening a function-like macro's actual arguments has no
        \\matching ')'. Unlike a `define body, an argument list may span
        \\newlines, so the scan ran to end of file.
        ,
    },
    .E0121 = .{
        .title = "`include requires a file name",
        .lrm = "10.3",
        .explain =
        \\`include takes one double-quoted file name:
        \\
        \\    `include "disciplines.vams"
        ,
    },
    .E0122 = .{
        .title = "`include file name must be quoted",
        .lrm = "10.3",
        .explain =
        \\LRM 10.3 spells the argument of `include as a double-quoted
        \\string. The angle-bracket form C uses is not part of the
        \\Verilog-AMS grammar; the search path is configured by the tool,
        \\not by the quoting style.
        ,
    },
    .E0123 = .{
        .title = "unterminated `include file name",
        .lrm = "10.3",
        .explain =
        \\The opening double quote of an `include file name has no closing
        \\quote on the same line. LRM 2.7 confines a string literal to one
        \\line.
        ,
    },
    .E0124 = .{
        .title = "empty `include file name",
        .lrm = "10.3",
        .explain = "`include \"\" names no file.",
    },
    .E0125 = .{
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
    .E0126 = .{
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
    .E0127 = .{
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
    .E0128 = .{
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
    .E0129 = .{
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
    .E0130 = .{
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
};
