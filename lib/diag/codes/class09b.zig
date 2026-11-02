//! The diagnostic catalogue's class 9 rows, hierarchy and elaboration, part b:
//! `E0919` .. `E0484`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .E0919 = .{
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
    .E0920 = retiredInfo(
        \\"a child instance's digital processes are not supported in a
        \\mixed-signal design". Retired: the mixed-signal runner now binds a
        \\discrete input by its flattened hierarchical name (`u.q`), and its
        \\digital engine elaborates the same instance tree the analog compile
        \\flattened — the connect modules 7.8.4 inserted included — so a
        \\child's `initial` and `always` blocks run as the top's do. The
        \\number is not reused.
    ),
    .E0921 = .{
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
    .E0922 = .{
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
    .E0927 = .{
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
    .E0928 = .{
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
    .E0929 = .{
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
    .E0930 = retiredInfo(
        \\"detail discipline resolution is not implemented for this signal".
        \\Retired: 7.4.4.2's detail mode (Annex F.2.2, step 5's top-down
        \\pass included) is implemented, so a signal the two modes decide
        \\differently compiles under `--discipline-resolution=detail` with
        \\detail's answer. The number is not reused.
    ),
    .E0923 = .{
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
    .E0924 = .{
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
    .E0925 = .{
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
    .E0926 = .{
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
    .E0960 = .{
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
    .E0982 = .{
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
    .E0997 = .{
        .title = "a hierarchical port access VerA cannot sum",
        .lrm = "5.4.3",
        .explain =
        \\LRM 5.4.3: "The port access function accesses the flow into a port
        \\of a module", and A.8.9 lets the port be hierarchical: `I(<u.p>)`
        \\is the flow into instance u through its own port p.
        \\
        \\When u itself reads it (`I(<a>)`, or `I(pb)` over its 3.12.1 port
        \\branch), or the module that instantiates u does, elaboration keeps
        \\the port on a net of its own, hung from the connected net by a
        \\branch nothing contributes to: the flow is that flow probe's
        \\current (Figure 5-1's ammeter), exact through any source.
        \\
        \\Otherwise the port is joined onto the connected net, and VerA reads
        \\the flow as what u's hierarchy conducts away from it: the sum of
        \\its flow contributions to branches at the net. That sum is refused
        \\when it cannot be exact:
        \\  - the access is read before u's own analog blocks are lowered
        \\    (from a sibling written before u); read it from a module above;
        \\  - u drives the net through a potential source or a 5.6.7
        \\    indirect branch, whose current is a solver unknown (a reader
        \\    two or more levels above u, or a vector port);
        \\  - a vector port read from inside u.
        \\At the top, `I(<a>)` is the host's port current and is read exactly.
        ,
    },
    .E0998 = .{
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
    .E0482 = .{
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
    .E0483 = .{
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
    .E0484 = .{
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
};
