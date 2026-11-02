//! The diagnostic catalogue's class 2 rows, syntax, annex A (parser.zig), part a:
//! `E0201` .. `E0228`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .E0201 = .{
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
    .E0202 = .{
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
    .E0203 = retiredInfo(
        \\"named event declaration is not implemented". Retired: A.2.1.3
        \\`event_declaration` now parses and 5.10.4's trigger/detect pair
        \\lowers, so the condition does not exist to report. A named event is
        \\an ANALOG event — 5.10 lists it as one of three kinds — so refusing
        \\the declaration was refusing part of the subset annex C.2 grants.
        \\
        \\What replaced it: E0705, for a `@(ev)` or `-> ev` naming something
        \\no `event` declaration introduced. The number is not reused.
    ),
    .E0204 = retiredInfo(
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
    .E0205 = .{
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
    .E0206 = .{
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
    .E0207 = .{
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
    .E0208 = .{
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
    .E0209 = .{
        .title = "expected an expression",
        .lrm = "A.8.3",
        .explain =
        \\An operand was required here and the token found cannot begin
        \\one. Common causes: a trailing binary operator, an empty pair of
        \\parentheses, or a stray comma in an argument list.
        ,
    },
    .E0210 = .{
        .title = "expected ')'",
        .lrm = "A.8.3",
        .explain = "A parenthesised group or argument list is not closed.",
    },
    .E0211 = .{
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
    .E0212 = .{
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
    .E0213 = .{
        .title = "expected a discipline item",
        .lrm = "3.6.2",
        .explain =
        \\Inside `discipline`/`enddiscipline` the legal items are a domain
        \\binding, a potential binding, a flow binding, and attribute
        \\assignments. LRM 3.6.2 forbids nesting: discipline declarations
        \\do not appear inside another discipline, a nature, or a module.
        ,
    },
    .E0214 = .{
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
    .E0215 = retiredInfo(
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
    .E0216 = .{
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
    .E0217 = .{
        .title = "concatenation is wider than an integer",
        .lrm = "3.2.1",
        .explain =
        \\LRM 3.2.1 fixes the Verilog-A `integer` at 32 bits, and a
        \\concatenation evaluates to an integer. A wider result has nowhere
        \\to live.
        ,
    },
    .E0218 = .{
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
    .E0219 = .{
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
    .E0220 = .{
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
    .E0221 = .{
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
    .E0222 = .{
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

    .E0223 = .{
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
    .E0224 = .{
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
    .E0225 = .{
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
    .E0226 = .{
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
    .E0227 = .{
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
    .E0228 = .{
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
};
