//! The diagnostic catalogue's class 3 rows, types, disciplines and declarations, part c:
//! `E0354` .. `E0366`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .E0354 = .{
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
    .E0355 = .{
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
    .E0356 = .{
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
    .E0357 = .{
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
    .E0358 = .{
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
    .E0359 = .{
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
    .E0360 = .{
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
    .E0361 = .{
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
    .E0362 = .{
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
    .E0363 = .{
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

    .E0364 = retiredInfo(
        \\"mixed signedness around a shift is not implemented". Retired: a
        \\comparison extends each operand from its own width, as 4.2.9 says
        \\("the smaller operand shall be zero-extended to the size of the
        \\larger operand"), so (a >> n) > 40'h1 is the 32-bit shift's value,
        \\zero-extended, and there is nothing left to refuse. The number is
        \\not reused.
    ),
    .E0368 = .{
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
    .E0369 = .{
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
    .E0370 = .{
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
    .E0371 = .{
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
    .E0372 = .{
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

    .E0367 = .{
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

    .E0365 = .{
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
    .E0366 = .{
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
};
