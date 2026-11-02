//! The diagnostic catalogue's class 9 rows, hierarchy and elaboration, part a:
//! `E0901` .. `E0918`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .E0901 = .{
        .title = "hierarchical name names nothing in the elaborated design",
        .lrm = "6.7",
        .explain =
        \\A dotted name that resolves to no net, branch, parameter or
        \\constant.
        \\
        \\This is NOT "hierarchy is unsupported" any more — that was E0204,
        \\retired. §6.2.2 instantiation elaborates and `elab/elaborate.zig`
        \\flattens the tree, and because a flattened entity's name IS its
        \\hierarchical path (`elab.sep`), resolving a §6.7 reference is
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
    .E0902 = .{
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
    .E0903 = .{
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
    .E0904 = .{
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
    .E0905 = .{
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
    .E0906 = .{
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
    .E0907 = .{
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
    .E0908 = .{
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
    .E0909 = .{
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
    .E0910 = .{
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
    .E0911 = .{
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
    .E0912 = .{
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
    .E0913 = retiredInfo(
        \\"instantiating a connect module by name is not supported". Retired:
        \\LRM 7.1 says connect modules "can be manually inserted (by the
        \\user) or automatically inserted (by the simulator)", and a
        \\hand-placed one is now inlined like any child, its digital half
        \\running on the mixed-signal runner (E0920 is retired with it). The
        \\number is not reused.
    ),
    .E0914 = .{
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
    .E0915 = .{
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
    .E0916 = .{
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
    .E0917 = .{
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
    .E0918 = .{
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
};
