//! The diagnostic catalogue's class 3 rows, types, disciplines and declarations, part b:
//! `E0336` .. `E0353`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

pub const rows = .{
    .E0336 = .{
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
    .E0337 = .{
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
    .E0338 = .{
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
    .E0339 = .{
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
    .E0340 = .{
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
    .E0341 = .{
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
    .E0374 = .{
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
    .E0375 = .{
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
    .E0376 = .{
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
    .E0378 = .{
        .title = "discipline binds an undeclared nature",
        .lrm = "3.6.2.1",
        .explain =
        \\A.1.7's `nature_binding ::= potential_or_flow nature_identifier ;`
        \\names a nature declared with `nature ... endnature` (3.6.1), and
        \\3.6.2.1 makes that nature's `access` the discipline's access
        \\function. A name no nature declares binds nothing, so every
        \\`V(...)` or `I(...)` on a net of the discipline would name nothing.
        \\
        \\    `define DISCIPLINES_VAMS     // annex D's natures are out
        \\    discipline mine;
        \\        potential Voltage;      // E0378: no `nature Voltage`
        \\    enddiscipline
        \\
        \\Declare the nature, or include `disciplines.vams` for annex D's.
        ,
    },
    .E0377 = .{
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
    .E0342 = .{
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
    .E0343 = .{
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
    .E0344 = .{
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

    .E0345 = .{
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
    .E0346 = .{
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
    .E0347 = .{
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
    .E0348 = .{
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
    .E0349 = .{
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
    .E0350 = .{
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
    .E0351 = .{
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
    .E0352 = .{
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
    .E0353 = .{
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
};
