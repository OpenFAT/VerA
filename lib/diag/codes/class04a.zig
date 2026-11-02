//! The diagnostic catalogue's class 4 rows, behavioral semantics, part a:
//! `E0401` .. `E0425`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .E0401 = .{
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
    .E0402 = .{
        .title = "`disable` does not name a block",
        .lrm = "A.6.5",
        .explain =
        \\A.6.5 gives disable_statement two operands, a
        \\hierarchical_task_identifier and a hierarchical_block_identifier,
        \\and Verilog-AMS gives an analog block no task — so the only legal
        \\operand here is the label of an enclosing named block.
        ,
    },
    .E0403 = .{
        .title = "`return` outside an analog function",
        .lrm = "4.7.1",
        .explain =
        \\LRM 5.11 jump statements are confined to an analog function body.
        \\The analog block itself has no caller to return to — it runs to
        \\completion on every solver evaluation.
        ,
    },
    .E0404 = .{
        .title = "`break` or `continue` outside a loop",
        .lrm = "5.9",
        .explain =
        \\These statements need an enclosing `for`, `while` or `repeat` in
        \\the same function or analog block.
        ,
    },
    .E0405 = .{
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
    .E0406 = .{
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
    .E0407 = .{
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
    .E0408 = .{
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
    .E0409 = .{
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
    .E0410 = .{
        .title = "indirect contribution is not allowed in this context",
        .lrm = "5.2.1",
        .explain =
        \\An indirect contribution states a constraint on the whole system,
        \\so it belongs in the analog block. See E0405 for why an analog
        \\function may not contain one.
        ,
    },
    .E0411 = .{
        .title = "indirect contribution inside an event statement",
        .lrm = "5.10",
        .explain =
        \\See E0406: an event body runs at instants, a constraint must hold
        \\continuously.
        ,
    },
    .E0412 = .{
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
    .E0413 = .{
        .title = "indirect contribution target must be a branch access",
        .lrm = "5.6.7",
        .explain =
        \\The left of the `:` names the unknown the constraint solves for:
        \\
        \\    V(out) : I(out) == 0;
        ,
    },
    .E0414 = .{
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
    .E0415 = .{
        .title = "branch already has a direct contribution",
        .lrm = "5.6.7.2",
        .explain = "The mirror image of E0409 — see that code.",
    },
    .E0416 = retiredInfo(
        \\"casex/casez are not in the analog subset". Retired: annex C.7's
        \\removal is the Verilog-A SUBSET's rule, and VerA compiles
        \\Verilog-AMS, where §7.3.2 lists "the case, casex, and casez
        \\statements" among the analog context's four-state features. They
        \\lower now (`expr_case.caseMatch`). The number is not reused.
    ),
    .E0417 = .{
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
    .E0418 = .{
        .title = "genvar loop condition is not a constant expression",
        .lrm = "6.6.1",
        .explain = "See E0417.",
    },
    .E0419 = .{
        .title = "genvar loop step is not a constant expression",
        .lrm = "6.6.1",
        .explain =
        \\See E0417. LRM 6.6.1 additionally requires that "both the
        \\initialization and iteration assignments shall assign to the same
        \\genvar".
        ,
    },
    .E0485 = retiredInfo(
        \\"genvar loop exceeds the unroll limit". Retired: a loop that ends
        \\after more than 4096 iterations was refused as an engine bound.
        \\Every loop generate that ends is now unrolled in full, however
        \\long; one that never ends is still E0420, found by following the
        \\scheme until it ends or repeats a genvar value, not by a count.
        \\The number is not reused.
    ),
    .E0486 = .{
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
    .E0420 = .{
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
    .E0421 = .{
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
    .E0422 = .{
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
    .E0423 = .{
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

    .E0424 = .{
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
    .E0425 = .{
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
};
