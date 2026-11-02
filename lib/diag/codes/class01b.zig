//! The diagnostic catalogue's class 1 rows, lexical and preprocessing (preprocessor.zig, the lexer), part b:
//! `E0131` .. `E0154`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .E0131 = .{
        .title = "expected a numeric base after the apostrophe",
        .lrm = "2.6.1",
        .explain =
        \\A sized literal is <size>'<base><digits>, where <base> is one of
        \\b/B, o/O, d/D or h/H:
        \\
        \\    8'hFF   4'b1010   16'd65535
        ,
    },
    .E0132 = .{
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
    .E0133 = .{
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
    .E0134 = retiredInfo(
        \\"number literal is too long". Retired 2026-10: a real literal of
        \\any length decodes (2.6.2 writes its digits with no length
        \\bound); the 512-byte decode buffer it named is gone. The number
        \\is not reused.
    ),
    .E0135 = .{
        .title = "unsupported keyword set",
        .lrm = "10.6",
        .explain =
        \\`begin_keywords takes a quoted version specifier naming the
        \\keyword set to make active. VerA recognises the Verilog-AMS
        \\and IEEE 1364 sets listed in LRM annex B; an unknown specifier
        \\would silently change which identifiers are reserved.
        ,
    },
    .E0136 = .{
        .title = "`end_keywords without `begin_keywords",
        .lrm = "10.6",
        .explain =
        \\`end_keywords pops the keyword set that `begin_keywords pushed.
        \\This one has nothing to pop.
        ,
    },
    .E0137 = retiredInfo(
        \\"unterminated `begin_keywords". Retired: 10.6 gives the directive
        \\scope "even across source code file boundaries", so an open pair
        \\at end of file is the clause working, not an error. The number is
        \\not reused.
    ),
    .E0138 = .{
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
    .E0139 = .{
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
    .E0140 = .{
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
    .E0141 = .{
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
    .E0142 = .{
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

    .E0143 = .{
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

    .E0144 = .{
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

    .E0145 = .{
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
    .E0146 = .{
        .title = "a protected envelope VerA cannot process",
        .lrm = "IEEE 1364-2005 28",
        .explain =
        \\IEEE 1364-2005 19.10 lets a tool ignore a `pragma it does not
        \\recognize, but `protect` is not such a pragma: clause 28 reserves
        \\it for protected envelopes, and 28.2 says a tool "shall perform
        \\envelope decryption for all decryption envelopes contained in the
        \\source text, where the proper key is supplied by the user".
        \\
        \\VerA decrypts a `begin_protected` envelope (des-cbc; base64,
        \\uuencode or raw; a key_block's session key; an md5 or sha1
        \\digest_block) with the keys of --protect-keys. It provides no
        \\encryption service, so an encryption envelope (`begin`) is
        \\refused, as are a block outside an envelope, an envelope with no
        \\end_protected, and a method or encoding VerA does not implement.
        \\Ignoring the directive instead would compile ciphertext as
        \\Verilog, or cleartext as if nobody had asked for it to be hidden.
        \\
        \\A model whose cleartext holds a `decrypt_license` or
        \\`runtime_license` pragma is refused too (§28.4.28.2, §28.4.29.2:
        \\"if the application is not licensed ... the application shall
        \\produce an error message"): VerA loads no license library, so it
        \\is never licensed.
        \\
        \\Metadata such as author or comment has an action only inside an
        \\envelope, so outside one it is accepted with no effect. Any other
        \\pragma name still has no effect.
        ,
    },
    .E0150 = .{
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
    .E0147 = .{
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
    .E0148 = .{
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
    .W0149 = .{
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
    .W0151 = .{
        .title = "IEEE 1800 macro text in an IEEE 1364 unit",
        .lrm = "10.4",
        .explain =
        \\IEEE 1800-2017 22.5.1 adds three forms to macro text: `" opens and
        \\closes a string whose formal arguments are still substituted, `\`"
        \\puts a \" inside it, and `` joins two tokens with nothing between
        \\them. VerA reads all three under every standard.
        \\
        \\IEEE 1364-2005 Syntax 19-3 has none of them, so under
        \\--std=1364-* the source is not portable to a 1364 tool. VerA says
        \\so once per `define and expands it as 1800 does.
        \\
        \\  --allow=W0151   silence it, for 1364 code that relies on the
        \\                  1800 forms (iverilog accepts them in -g2005)
        ,
    },

    .E0152 = .{
        .title = "no key for a protected envelope",
        .lrm = "IEEE 1364-2005 28.2",
        .explain =
        \\A decryption envelope names its key by owner and name
        \\(data_keyowner/data_keyname, key_keyowner/key_keyname for a
        \\key_block, digest_keyowner/digest_keyname for a digest_block,
        \\28.4.6-28.4.7). 28.2 decrypts "where the proper key is supplied
        \\by the user", and none was: the key file given to --protect-keys
        \\has no key of that owner and name, or none was given.
        \\
        \\  vera --run --protect-keys keys.json design.v
        \\
        \\The file is JSON: profile.iv_hex (the CBC IV, 16 hex digits) and
        \\keys, each {"owner", "name", "key_hex"}.
        ,
    },
    .E0153 = .{
        .title = "a protected envelope does not decrypt",
        .lrm = "IEEE 1364-2005 28.2",
        .explain =
        \\The key the envelope names was found, but the envelope does not
        \\open with it: the decrypted block's padding is wrong (a wrong key
        \\or IV), the digest_block does not match the decrypted data
        \\(28.4.12), or a block does not decode to the bytes its encoding
        \\says (28.4.3). Nothing of the envelope is compiled.
        ,
    },
    .E0154 = .{
        .title = "more than 65535 source files",
        .lrm = "",
        .explain =
        \\The compilation registered more source files than a diagnostic can
        \\name: every location carries a 16-bit file id, so a compilation
        \\holds at most 65535 files. Each `include registers the file it
        \\reads again, so a header included tens of thousands of times (in
        \\a loop of generated `include lines, say) is the usual way to
        \\reach it. This is a bound of VerA's representation, not a
        \\language rule. Include the file once, or split the design into
        \\files compiled separately.
        ,
    },
};
