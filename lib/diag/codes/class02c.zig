//! The diagnostic catalogue's class 2 rows, syntax, annex A (parser.zig), part c:
//! `E0241` .. `W0251`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

pub const rows = .{
    .E0241 = .{
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
    .E0243 = .{
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
    .E0244 = .{
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
    .E0297 = .{
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
    .E0295 = .{
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
    .E0296 = .{
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
    .E0289 = .{
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
    .E0290 = .{
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
    .E0291 = .{
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
    .E0292 = .{
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
    .E0293 = .{
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
    .E0234 = .{
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
    .W0250 = .{
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
    .W0252 = .{
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
    .W0253 = .{
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
    .W0259 = .{
        .title = "a VAMS-2023 math function name declared as a function",
        .lrm = "10.6",
        .explain =
        \\Annex G.7 (item 7780) made `expm1` and `ln1p` keywords in
        \\VAMS-2023, with built-in meanings (4.3.2). Compact models written
        \\before that (HiSIM-SOI, HiSIM-SOTB) declare their own
        \\`analog function real expm1`, which only a pre-2023 keyword set
        \\(10.6) allows.
        \\
        \\VerA reads the source as its author wrote it: when a file declares
        \\a function of either name, that name is an identifier in the whole
        \\file and every call reaches the declared function, not the
        \\built-in. The two can differ in the last bits: a model's
        \\`exp(x) - 1` loses the precision the built-in keeps near zero.
        \\
        \\Put `begin_keywords "VAMS-2.3" around the model to say which
        \\language it is in, or rename the function to use the built-in.
        ,
    },
    .W0251 = .{
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
        \\destination is scheduled to change) and the 14.6 pulse controls
        \\(PATHPULSE$ limits, pulsestyle_onevent/ondetect, showcancelled), so
        \\it raises no warning there. The same engine runs
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
};
