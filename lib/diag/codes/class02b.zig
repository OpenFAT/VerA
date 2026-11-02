//! The diagnostic catalogue's class 2 rows, syntax, annex A (parser.zig), part b:
//! `E0229` .. `E0242`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

pub const rows = .{
    .E0229 = .{
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
    .E0230 = .{
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
    .E0231 = .{
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
    .E0232 = .{
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
    .E0233 = .{
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
    .E0235 = .{
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
    .E0236 = .{
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
    .E0237 = .{
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
    .E0238 = .{
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
    .E0239 = .{
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
    .E0240 = .{
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
    .E0246 = .{
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
    .E0247 = .{
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
    .E0248 = .{
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
    .E0258 = .{
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
    .E0249 = .{
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
    .E0250 = .{
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
    .E0254 = .{
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
    .E0255 = .{
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
    .E0256 = .{
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
    .E0257 = .{
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
    .E0245 = .{
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
    .E0242 = .{
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
};
