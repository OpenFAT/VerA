//! The diagnostic catalogue's class 4 rows, behavioral semantics, part b:
//! `E0426` .. `E0477`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

pub const rows = .{
    .E0426 = .{
        .title = "contribution inside a runtime loop",
        .lrm = "5.9",
        .explain =
        \\LRM 5.9, the third of three blanket restrictions on `repeat`,
        \\`while` and the non-genvar `for`: "Contribution statements are
        \\not allowed."
        \\
        \\A device's set of branches is fixed before the solve begins, and
        \\a runtime trip count is not — the number of equations may not
        \\depend on data. The 5.9.3 genvar `for` is exempt because its trip
        \\count is known at elaboration and the loop is unrolled, so the
        \\branches it stamps are all there before the first iteration.
        \\
        \\Accumulate into a variable in the loop and contribute once after
        \\it, or make the loop a genvar loop.
        ,
    },
    .E0427 = .{
        .title = "more than one `default` arm in a case statement",
        .lrm = "5.8.3",
        .explain =
        \\LRM 5.8.3: "The default statement is optional. Use of multiple
        \\default statements in one case statement is illegal."
        \\
        \\Nothing in the clause orders the arms, so a second `default`
        \\leaves the fall-through undefined rather than merely redundant.
        \\Merge them, or give one of them its own label list.
        ,
    },
    .E0428 = .{
        .title = "a generate scheme is not a constant expression",
        .lrm = "6.6",
        .explain =
        \\LRM 6.6, verbatim: "All expressions in generate schemes shall be
        \\constant expressions, deterministic at elaboration time."
        \\
        \\A generate scheme decides what the module CONTAINS, so it has to be
        \\answerable before there is a solution to read: an if-generate
        \\condition, a case-generate selector, and a loop generate's
        \\initialization, condition and step (E0417-E0419). A module variable
        \\or a probe is none of those — the LRM gives such a construct no
        \\semantics at all, which is why this is an error and not a fallback
        \\to a run-time branch.
        \\
        \\A `parameter` IS a constant expression here (A.8.4
        \\constant_primary, and 6.6's whole purpose is "the ability for
        \\parameter values to affect the structure of the model"), so a
        \\parameterized scheme is accepted.
        \\
        \\For a choice that depends on a solver value, write an ordinary
        \\`if` or `case` inside the analog block — but note 5.8.1's
        \\restrictions on analog operators under a non-constant condition.
        ,
    },
    .E0429 = .{
        .title = "incompatible array assignment",
        .lrm = "5.7",
        .explain =
        \\LRM 5.7: "Array assignments shall only be done with arrays that are
        \\compatible. An array, or a slice of such an array, shall be
        \\assignment compatible with any other such array or slice if all the
        \\following conditions are satisfied:
        \\
        \\  - The element types of source and target shall be equivalent.
        \\  - Every dimension of the source array shall have the same number
        \\    of elements as the target array."
        \\
        \\The count is of ELEMENTS, not of indices, which is the clause's own
        \\worked example:
        \\
        \\    int A[10:1];   int B[0:9];   int C[24:1];
        \\    A = B;         // ok. Compatible type and same size
        \\    A = C;         // type check error: different sizes
        \\
        \\Assign the elements one at a time if the shapes genuinely differ —
        \\there is no truncating or padding form of this statement.
        \\
        \\The clause also requires: "The arrays on the LHS and the RHS of the
        \\assignment must be unpacked." A packed vector (`reg [1:0] B`) or a
        \\scalar on the right of a whole array is refused here too.
        ,
    },
    .E0430 = .{
        .title = "analog function called outside the analog context",
        .lrm = "4.7.3",
        .explain =
        \\LRM 4.7.3: an analog user-defined function "shall only be called
        \\within the analog context, either from an analog block or from
        \\within another analog user-defined function". LRM 7.3.7 states the
        \\mixed-signal half: an analog function is not available to a
        \\discrete process.
        \\
        \\The restriction follows from what an analog function IS. LRM 4.7.1
        \\denies it access functions, filters and contribution statements
        \\precisely so that it is a pure value computation ON THE ANALOG
        \\SOLVER'S TIMELINE. An `initial` block runs once before the solve
        \\and an `always` block runs on the digital kernel's own events, so
        \\neither has a timepoint at which the function's value is defined.
        \\
        \\Move the call into the analog block, or into another analog
        \\function that the analog block calls.
        ,
    },
    .E0431 = .{
        .title = "digital value read from an analog initial block",
        .lrm = "5.2.1",
        .explain =
        \\LRM 5.2.1: "Additionally, digital values cannot be accessed from
        \\the analog initial block as they have not yet been assigned when
        \\the analog initial block is executed."
        \\
        \\The rule is about ORDER, not about types. LRM 7.2.2 gives a
        \\variable the domain of the context that assigns it, so a variable
        \\written by an `initial` or `always` block is digital-owned; the
        \\analog initial block runs before any digital process has run, so
        \\such a read has no value to return and would silently produce the
        \\type's zero.
        \\
        \\Read it from the ordinary analog block instead — LRM 7.3.1 Table
        \\7-1 defines that direction — or make the value a parameter or a
        \\localparam if it is genuinely constant.
        ,
    },
    .E0432 = .{
        .title = "variable assigned in both contexts",
        .lrm = "7.2.2",
        .explain =
        \\LRM 7.2.2: "A given variable can be assigned values only in one
        \\context or the other, but not in both. The domain of a variable is
        \\that of the context from which its value is assigned", stated again
        \\two paragraphs later as "It shall be an error to assign to a given
        \\variable in both contexts."
        \\
        \\The two contexts are the CONTINUOUS one (statements in an `analog`
        \\block) and the DISCRETE one (statements in an `initial` or `always`
        \\block). A variable written from both has no domain, so no rule in
        \\clause 7 can say when its value is defined or which kernel owns its
        \\storage.
        \\
        \\Pick one writer. Reading a variable from the other context stays
        \\legal, and is what LRM 7.3.1 Table 7-1 is the conversion table for.
        ,
    },
    .E0433 = .{
        .title = "statement in an initial block is not a constant assignment",
        .lrm = "7.2.2",
        .explain =
        \\A.6.2's `initial_construct ::= initial statement` is legal
        \\Verilog-AMS, and an `initial` block is a digital process whether or
        \\not it has a timing control (IEEE 1364-2005 9.9.1, via LRM 1.1).
        \\VerA runs it in one of two ways. A body of assignments of constant
        \\expressions to scalar module variables is folded: LRM 7.2.2's "the
        \\domain of a variable is that of the context from which its value is
        \\assigned" gives the target to the discrete context, the block runs
        \\once before the analysis, so the variable holds that constant for the
        \\whole analysis and LRM 7.3.1 Table 7-1 says how the continuous
        \\context reads it. Any other body (a system task, a loop, a
        \\non-constant right-hand side, an array element, a delay) runs on the
        \\mixed-signal kernel (LRM 8.5), exactly as the same body behind `#0`.
        \\
        \\This error is the gap between the two: a right-hand side built only
        \\from literals, parameters and constant functions whose value still
        \\does not fold. Write the value as a constant, or as a parameter
        \\(LRM 3.4).
        ,
    },
    .E0434 = .{
        .title = "`->` is not an analog statement",
        .lrm = "A.6.4",
        .explain =
        \\A.6.4 derives `analog_statement` without an `event_trigger`
        \\alternative — `event_trigger` is listed one production over, under
        \\`analog_event_statement`, next to `disable_statement` (E0401). So
        \\the only form an analog block admits is the event statement
        \\
        \\    @(<event>) -> ev;
        \\
        \\which is the spelling LRM 5.10.4's own example uses.
        \\
        \\A bare trigger would have to mean "this event is active at every
        \\timepoint", which hands the event's rate to the solver's step
        \\control rather than to the model.
        ,
    },

    .E0435 = .{
        .title = "a continuous net cannot be written from a discrete context",
        .lrm = "7.3",
        .explain =
        \\LRM 7.3 draws the line in one sentence: "Read operations of nets
        \\and variables in both domains are allowed from both contexts.
        \\WRITE operations of nets and variables are only allowed from the
        \\context of their domain."
        \\
        \\So `V(p) <+ ...` inside an `always` or `initial` block is not a
        \\contribution the simulator can place: §7.2.1 assigns potentials
        \\and flows to the CONTINUOUS domain, and if a digital process
        \\could contribute to a branch then both kernels would own that
        \\node's equation and neither would be solving it.
        \\
        \\§7.3.3 states the permitted half from the other side — "All
        \\continuous nets can be PROBED from a discrete context using
        \\access functions". Probed, not driven. Syntax 7-3 likewise
        \\admits an analog event into a digital sensitivity list without
        \\admitting a contribution into a digital statement.
        \\
        \\This is NOT E0432 (§7.2.2, "assigned in both contexts"), which
        \\is about a variable with two writers and fires only when both
        \\exist. Here there is one writer and it is in the wrong domain.
        \\
        \\Move the contribution into the `analog` block and let the
        \\digital process set a variable the analog block reads — that
        \\read is §7.3's legal direction and Table 7-1 is its conversion.
        ,
    },

    .E0436 = .{
        .title = "a digital function cannot be called from the analog context",
        .lrm = "7.3.7",
        .explain =
        \\LRM 7.3.7 is two sentences and this is the first: "Digital
        \\functions cannot be called from within the analog context.
        \\Analog functions cannot be called from within the digital
        \\context." E0430 is the second.
        \\
        \\The DECLARATION is legal. LRM 4.7 says "Each function can be an
        \\analog user-defined function or a digital function (as defined
        \\in IEEE Std 1364 Verilog)", so a module may hold a digital
        \\function and call it from a digital process; what it may not do
        \\is call it from an `analog` block. The diagnostic therefore
        \\lands on the CALL, never on the `function` keyword.
        \\
        \\A digital function runs in the discrete domain: it is evaluated
        \\once per event, and the analog kernel would have to call it once
        \\per Newton iterate with no event to attach the result to.
        \\
        \\Write `analog function` if the body is analog — it is inlined
        \\into the contribution and its arguments are solver values. If
        \\the body genuinely belongs to the discrete domain, let the
        \\digital process call it and have the analog block read the
        \\variable it wrote (LRM 7.3's legal direction, Table 7-1).
        ,
    },

    .E0437 = .{
        .title = "this discrete process needs a mixed-signal kernel feature VerA does not implement",
        .lrm = "8.5",
        .explain =
        \\The source is legal Verilog-AMS. A module may hold `always` blocks,
        \\continuous `assign`s and timed `initial` blocks beside its `analog`
        \\block (LRM 7.2.2), and LRM 8.5 defines how the two kernels run them
        \\together: the digital events of each time tick execute in the
        \\stratified queue of 8.5.1, and an analog macro-process that reads a
        \\digital value is re-solved when that value changes (8.5, the
        \\implicit D2A event).
        \\
        \\The message names the part of that machinery the construct needs and
        \\VerA does not have. It is a statement about this compiler, not about
        \\the source: the construct becomes accepted when the named feature
        \\lands, and the fixtures that pin it are written to flip then.
        ,
    },

    .E0438 = .{
        .title = "a continuous assignment drives a net, not a variable",
        .lrm = "A.6.1",
        .explain =
        \\A.6.1 derives `continuous_assign ::= assign list_of_net_assignments ;`
        \\with `net_assignment ::= net_lvalue = expression`, and IEEE Std
        \\1364-2005 6.1 (part of Verilog-AMS by LRM 1.1) says why: a
        \\continuous assignment is a DRIVER, and only a net has drivers to
        \\resolve. A variable holds the last value a procedural statement
        \\stored in it.
        \\
        \\Declare the target as a net (`wire`), or assign the variable from
        \\an `always` block.
        ,
    },
    .E0439 = .{
        .title = "hierarchical contribution changes the branch into a switch branch",
        .lrm = "5.6.8.2",
        .explain =
        \\LRM 5.6.8.2 allows a hierarchical direct contribution to a branch
        \\"provided that the branch is suitable for such contributions", and
        \\lists the reasons it is not, among them: "The hierarchical
        \\contribution changes the branch into a switch branch."
        \\
        \\Inside one module, a flow contribution after a potential one is
        \\5.6.1.3's value retention: the module decides, per iteration, which
        \\kind the branch is (5.6.5). Across a module boundary nothing orders
        \\the two analog blocks, so which kind wins is not defined, and the
        \\clause forbids it. Contribute the same access function the owning
        \\module does, or move the decision into that module.
        ,
    },
    .E0440 = .{
        .title = "`break` or `continue` inside an analog for loop",
        .lrm = "5.11",
        .explain =
        \\LRM 5.11: "The continue and break statements cannot be used inside
        \\an analog for loop. Refer 5.9.3." An analog_for's genvar control is
        \\unrolled at elaboration, so there is no runtime iteration for the
        \\jump to leave or skip.
        \\
        \\Nest a procedural `for` (5.9.2) on an integer variable inside the
        \\analog_for and jump out of that, or move the condition into an
        \\`if` around the rest of the body.
        ,
    },
    .E0477 = .{
        .title = "contributions from two module instances close a loop of potential sources",
        .lrm = "5.6.8.1",
        .explain =
        \\LRM 5.6.8.1: "The simulator shall check if the contribution produces
        \\a solvable set of equations, e.g. no voltage source loops created."
        \\5.6.8.2 says the same of hierarchical contributions to a child's
        \\branches.
        \\
        \\A hierarchical contribution creates a NEW unnamed branch in the
        \\module that writes it (5.6.8.1), so `V(drv.x) <+ 1.8` in a parent
        \\sits in parallel with any potential source the instance `drv`
        \\already has on `x`. Two potential sources around one loop fix the
        \\loop's potentials twice (Kirchhoff's voltage law) and leave the
        \\flows around it undetermined, whatever the values, so the system
        \\has no unique solution.
        \\
        \\Only loops that are a potential source on every path are checked: a
        \\switch branch (5.6.5) that is sometimes a flow source is not a loop.
        \\Contribute a flow instead, or contribute to the instance's own
        \\branch (5.6.8.2), which accumulates rather than adding a branch.
        ,
    },
};
