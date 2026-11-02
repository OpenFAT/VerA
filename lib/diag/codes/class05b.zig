//! The diagnostic catalogue's class 5 rows, analog operators and math, part b:
//! `E0521` .. `E0574`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

pub const rows = .{
    .E0521 = .{
        .title = "ac_stim analysis name is not a string literal",
        .lrm = "A.8.2",
        .explain =
        \\A.8.2 writes the quotation marks into the production:
        \\
        \\    ac_stim ( [ " analysis_identifier " [ , analog_expression
        \\                                        [ , analog_expression ] ] ] )
        \\
        \\so the analysis name is a string literal. 4.6.3 makes it select
        \\the small-signal analysis the source is active in, which the
        \\simulator resolves before it solves. A string parameter is allowed
        \\where the LRM says so (4.6.4.3's noise table file name), not here.
        \\
        \\    I(p, n) <+ ac_stim("ac", 2.0, 0.0);
        ,
    },
    .E0522 = .{
        .title = "flicker_noise requires an exponent",
        .lrm = "4.6.4.2",
        .explain =
        \\Syntax 4-4 brackets only the name:
        \\
        \\    flicker_noise ( analog_expression , analog_expression [ , string ] )
        \\
        \\and 4.6.4.2's "pink noise with a power of pwr at 1Hz which varies
        \\in proportion to 1/f^exp" gives the exponent no default. A flat
        \\spectrum is `white_noise(pwr)`; a 1/f source says so:
        \\
        \\    I(p, n) <+ flicker_noise(kf, 1.0);
        ,
    },
    .E0523 = .{
        .title = "vera_lte needs a constant value",
        .lrm = "2.9",
        .explain =
        \\`(* vera_lte = <value> *)` is VerA's attribute for leaving a
        \\charge (a `ddt` site, 5.6.1.2) out of the host's local
        \\truncation-error check, the way SPICE device truncation routines
        \\leave junction charges out. 2.9 makes an attribute value a
        \\constant_expression; VerA additionally needs it before the model
        \\card exists, because the answer is a compile-time table
        \\(`q_lte`). So it may not name a parameter:
        \\
        \\    (* vera_lte = 0 *) I(b, s) <+ ddt(qbs);   // excluded
        \\    (* vera_lte *)     I(g, s) <+ ddt(qgs);   // 1: included
        \\
        \\The attribute is ignored and the site keeps the default (included).
        ,
    },
    .E0524 = .{
        .title = "vera_interp is 1 or 2",
        .lrm = "2.9",
        .explain =
        \\`(* vera_interp = <value> *)` is VerA's attribute for choosing how an
        \\`absdelay` (4.5.7) reads its history between accepted timepoints:
        \\1 is the clause's linear interpolation, 2 is 3-point Lagrange
        \\(quadratic), the reading SPICE's lossless transmission line uses.
        \\The value picks the emitted kernel, so it must fold before the model
        \\card exists and may not name a parameter:
        \\
        \\    y = absdelay (* vera_interp = 2 *) (V(a), td);   // quadratic
        \\    (* vera_interp *) y = absdelay(V(a), td);        // 1: linear
        \\
        \\The attribute is ignored and the site keeps linear interpolation.
        ,
    },
    .E0525 = .{
        .title = "vera_nodiff needs a constant value",
        .lrm = "2.9",
        .explain =
        \\`(* vera_nodiff *)` is VerA's attribute for storing the value of
        \\every assignment inside a statement with no derivative, the frozen
        \\coefficient a SPICE load stamps (ngspice's `geq = ag0 * C`). `= 0`
        \\turns it off inside. The answer decides which derivatives the
        \\emitted device computes, so it must fold before the model card
        \\exists and may not name a parameter:
        \\
        \\    (* vera_nodiff *) begin capgs = capgs; end   // stopped
        \\    (* vera_nodiff = 0 *) c = c;                 // not stopped
        \\
        \\The attribute is ignored and the statement stores derivatives.
        ,
    },
    .E0526 = .{
        .title = "vera_nodiff covers a contribution",
        .lrm = "2.9",
        .explain =
        \\`(* vera_nodiff *)` stops the derivative of the ASSIGNMENTS inside
        \\it. A contribution inside it would leave its branch with no
        \\Jacobian at all, and Newton cannot move a branch it cannot see.
        \\Stop the coefficient instead and contribute outside:
        \\
        \\    (* vera_nodiff *) c = c;
        \\    I(p, n) <+ ddt(c * V(p, n));
        ,
    },
    .E0527 = .{
        .title = "$limit seed reads the solution",
        .lrm = "9.17.3",
        .explain =
        \\A string-form `$limit` takes, after its algorithm's arguments and
        \\its sign, an optional seed: the value the site's branch starts at
        \\before the first Newton iterate (SPICE's MODEINITJCT). 9.17.3
        \\leaves the algorithm's arguments to the implementation. A seed may
        \\read what the device computes from its card and temperature
        \\(mos1load.c's `tVto`), but it is evaluated before any solution
        \\exists, so it may not read a probe or anything computed from one:
        \\
        \\    vgs = type * $limit(V(g, si), "fetlimds", type * vonp, type, type * vtox);  // ok
        \\    vds = $limit(V(di, si), "limvds", 1, V(d, s));                              // no
        ,
    },
    .E0528 = .{
        .title = "changed timer control would repeat a side-effecting call",
        .lrm = "5.10.3.3",
        .explain =
        \\A timer's next event uses the latest start_time and period after
        \\the analog block finishes. VerA recomputes arithmetic, array reads
        \\and effect-free analog functions over their final dependencies.
        \\An input of a side-effecting call changed after the original call,
        \\so retaining its old return gives a stale schedule, while repeating
        \\it would repeat output/inout writes, random draws or file activity.
        \\That combination is an implementation limit, not illegal AMS.
        \\
        \\Compute the effectful call once into a variable before timer(),
        \\then use or update that variable as the timer control. An unchanged
        \\effectful call remains legal and is evaluated only at its original
        \\source position, including when other timer operands change.
        ,
    },
    .E0529 = .{
        .title = "vera_timepoint needs a constant value",
        .lrm = "2.9",
        .explain =
        \\`(* vera_timepoint *)` is VerA's attribute for running a statement
        \\once per timepoint: the first evaluation at a time runs it, and the
        \\later Newton iterations at that time read back what it assigned.
        \\`= 0` turns it off. The answer decides the code the device is built
        \\with, so it must fold before the model card exists and may not name
        \\a parameter:
        \\
        \\    (* vera_timepoint *) w = acc * exp(-h / tau);       // cached
        \\    (* vera_timepoint = 0 *) w = acc * exp(-h / tau);   // not cached
        \\
        \\The attribute is ignored and the statement runs every evaluation.
        ,
    },
    .E0530 = .{
        .title = "not allowed in a vera_timepoint statement",
        .lrm = "2.9",
        .explain =
        \\A `(* vera_timepoint *)` statement runs on the first evaluation of a
        \\timepoint only, and every later evaluation at that time reads back
        \\what it assigned. So it may hold only work whose result cannot move
        \\between Newton iterations, and nothing whose effect is more than its
        \\assignments. It may not contain a probe (4.4) or a `$limit` (9.17.3),
        \\which read the iterate; a contribution (5.6), whose branch would lose
        \\its Jacobian on a cached evaluation; an analog operator that keeps
        \\state (4.5); an event control or trigger (5.10); a system task; or an
        \\assignment to a string variable. Compute the per-timepoint values
        \\inside it and use them outside:
        \\
        \\    (* vera_timepoint *) begin e = exp(-h / tau); w = acc * e; end
        \\    I(p, n) <+ V(p, n) / r + w;
        ,
    },
    .E0531 = .{
        .title = "vera_timepoint statement reads a value that moves between iterations",
        .lrm = "2.9",
        .explain =
        \\A `(* vera_timepoint *)` statement is cached per timepoint, so every
        \\value it reads must be the same at every Newton iteration of that
        \\time: a parameter, `$abstime`, `analysis()`, a held (5.10) variable,
        \\or something computed from those alone. A variable assigned before
        \\the statement from a probe, or under a branch that tests one, is the
        \\iterate in disguise:
        \\
        \\    v = V(p, n);
        \\    (* vera_timepoint *) w = v * 2.0;       // no: v is the iterate
        \\    (* vera_timepoint *) w = tlast * 2.0;   // yes: tlast is held
        ,
    },
    .E0532 = .{
        .title = "vera_timepoint statement runs more than once per evaluation",
        .lrm = "2.9",
        .explain =
        \\A `(* vera_timepoint *)` statement keeps one cached copy of what it
        \\assigns per timepoint. Inside a loop (5.9) it runs several times per
        \\evaluation with different inputs; inside an analog function (4.7) it
        \\runs once per call; inside an `analog initial` block (5.2.1) it runs
        \\once per analysis, never per timepoint. Put the attribute on the
        \\loop, or outside the function's call:
        \\
        \\    (* vera_timepoint *) for (i = 0; i < 3; i = i + 1) e[i] = exp(-h * p[i]);
        \\
        \\The attribute is ignored and the statement runs every evaluation.
        ,
    },
    .E0533 = .{
        .title = "$vera_reject_step outside an analog block",
        .lrm = "2.8.3",
        .explain =
        \\`$vera_reject_step(t_retry)` is VerA's task for asking the host to
        \\reject the transient step it is accepting and retry it ending at
        \\`t_retry` (`contract.UpdateResult.request_reject_at`). `updateState`
        \\reads it off the accepted solution, so it means something only where
        \\a step is accepted: in an analog block. An `analog initial` block
        \\(5.2.1) runs once per analysis and an analog function (4.7) once per
        \\call, so neither has a step to reject:
        \\
        \\    analog begin
        \\        if (late) $vera_reject_step(t_edge);   // yes
        \\    end
        \\    analog initial $vera_reject_step(0.0);    // no
        ,
    },
    .E0534 = .{
        .title = "vera_scratch needs a constant value",
        .lrm = "2.9",
        .explain =
        \\`(* vera_scratch *)` is VerA's attribute for a variable that carries
        \\nothing from one evaluation to the next: every evaluation starts it
        \\at its declaration's initializer, the 3.2 zero when there is none.
        \\`= 0` turns it off. The answer decides whether the device keeps a
        \\slot for the variable, so it must fold before the model card exists
        \\and may not name a parameter:
        \\
        \\    (* vera_scratch *) real st[0:63];       // scratch
        \\    (* vera_scratch = 0 *) real st[0:63];   // held where observable
        \\
        \\The attribute is ignored and the variable is held where observable.
        ,
    },
    .E0535 = .{
        .title = "vera_scratch decorates something other than a variable",
        .lrm = "2.9",
        .explain =
        \\`(* vera_scratch *)` says a VARIABLE (3.2) starts every evaluation
        \\afresh. A parameter (3.4) is a constant, a net (3.6) or a genvar
        \\(3.5) holds no value an evaluation assigns, and a statement is not a
        \\declaration, so on any of those it would mean nothing:
        \\
        \\    (* vera_scratch *) real st[0:63];          // yes
        \\    (* vera_scratch *) parameter real k = 1;   // no
        ,
    },
    .E0536 = .{
        .title = "vera_scratch variable carries a value between evaluations",
        .lrm = "5.10",
        .explain =
        \\A `(* vera_scratch *)` variable starts every evaluation afresh. An
        \\`analog initial` block (5.2.1) runs on the first evaluation only, and
        \\an event statement (5.10) only on the evaluations its event fires, so
        \\a value either assigns is meant for the evaluations that do not run
        \\it. Where a read may see such a value, the variable must be held:
        \\
        \\    @(initial_step) k = 3.0;
        \\    y = k;   // no: k would read 0 on every later evaluation
        \\
        \\Drop the attribute, or assign the variable outside the event.
        ,
    },
    .E0537 = .{
        .title = "vera_scratch variable is written by a digital process",
        .lrm = "7.2.2",
        .explain =
        \\`(* vera_scratch *)` makes a variable start every ANALOG evaluation
        \\afresh. A variable an `initial` or `always` block or a task assigns
        \\belongs to the discrete context (7.2.2), where IEEE 1364-2005 4.2.2
        \\says variables "shall retain value until the next assignment". The
        \\digital kernel keeps that value, and no analog evaluation resets it,
        \\so the attribute would do nothing:
        \\
        \\    (* vera_scratch *) real t;
        \\    always @(posedge clk) t = 1.0;   // no: t is digital-owned
        \\    analog t = V(p, n);               // yes, when only analog writes t
        ,
    },
    .E0538 = .{
        .title = "vera_scratch string value is not \"uninit\"",
        .lrm = "2.9",
        .explain =
        \\`(* vera_scratch *)` takes a number (nonzero on, `0` off) or the one
        \\string `"uninit"`, which drops even the per-evaluation zero start: the
        \\author promises every element is written before it is read in the
        \\same evaluation. Any other string is a misspelling, not a mode:
        \\
        \\    (* vera_scratch = "uninit" *) real st[0:63];   // yes
        \\    (* vera_scratch = "zero" *) real st[0:63];     // no
        \\
        \\The attribute is ignored and the variable is held where observable.
        ,
    },
    .E0539 = .{
        .title = "vera_scratch = \"uninit\" variable has an initializer",
        .lrm = "2.9",
        .explain =
        \\`(* vera_scratch = "uninit" *)` says the variable starts every
        \\evaluation with no value at all; a declaration initializer says it
        \\starts at that value. The two contradict each other:
        \\
        \\    (* vera_scratch = "uninit" *) real st[0:3] = '{1, 2, 3, 4};  // no
        \\    (* vera_scratch *) real st[0:3] = '{1, 2, 3, 4};             // yes
        \\
        \\Drop the initializer, or use plain `vera_scratch`.
        ,
    },
    .E0540 = .{
        .title = "filter root or coefficient vector violates a Laplace or Z-transform filter rule",
        .lrm = "4.5.11",
        .explain =
        \\LRM 4.5.11 (laplace_*) and 4.5.12 (zi_*) constrain the vectors a
        \\filter is built from, and the message names the sentence broken:
        \\
        \\  - a root vector is (real, imaginary) PAIRS, so its length is even;
        \\  - "If a root is complex, its conjugate shall also be present";
        \\  - the denominator is not empty and not identically zero;
        \\  - a zi_* period T is mandatory and positive, its transition time
        \\    nonnegative.
        \\
        \\A zi_* transition time or start time must also be a constant
        \\expression; a nonzero one runs as 4.5.12's tau-long ramp.
        \\
        \\    laplace_zp(V(in), '{-1, 1}, '{-1, 0})          // no: -1+1j alone
        \\    laplace_zp(V(in), '{-1, 1, -1, -1}, '{-1, 0})  // yes: a pair
        ,
    },
    .E0572 = .{
        .title = "filter coefficient argument is not an array",
        .lrm = "4.5.1",
        .explain =
        \\LRM 4.5.1: "Certain analog operators require arrays or vectors to
        \\be passed as arguments: Laplace filters, Z-transform filters ...
        \\An array can either be passed as an array_identifier (e.g. an
        \\array parameter or an array variable) or an array assignment
        \\pattern (see 4.2.14)." The two vector slots of laplace_* and zi_*
        \\(zeros or numerator, poles or denominator) take one of those, even
        \\for a single coefficient:
        \\
        \\    laplace_nd(V(in), 2.0, '{1, 1})      // no: 2.0 is a scalar
        \\    laplace_nd(V(in), {2.0}, '{1, 1})    // no: a concatenation
        \\    laplace_nd(V(in), '{2.0}, '{1, 1})   // yes
        \\
        \\VAMS 2.x wrote the list `{2.0}`. That is the 4.2.13 concatenation
        \\operator, and annex G records the change: "Add apostrophe before
        \\opening { in list of values (to distinguish a list of values from
        \\the concatenation operator)". Empty zeros are the null argument,
        \\`laplace_zp(x, , '{-1, 0})`, not `{}`.
        ,
    },
    .E0573 = .{
        .title = "noise source label is not a string",
        .lrm = "4.6.4",
        .explain =
        \\Syntax 4-4 gives every noise function one optional trailing
        \\argument, typed `string`:
        \\
        \\    white_noise ( analog_expression [ , string ] )
        \\    flicker_noise ( analog_expression , analog_expression [ , string ] )
        \\    noise_table ( noise_table_input_arg [ , string ] )
        \\
        \\LRM 4.6.4.1: "The optional name argument acts as a label for the
        \\noise source used when the simulator outputs the individual
        \\contribution of each noise source". A number in that slot is not
        \\a label, and there is no second power for it to be.
        ,
    },
    .E0574 = .{
        .title = "analysis() argument is not a quoted analysis name",
        .lrm = "4.6.1",
        .explain =
        \\LRM 4.6.1: "The analysis() function takes one or more string
        \\arguments and returns one (1) if any argument matches the current
        \\analysis type." A.8.2 writes the quotation marks into the grammar:
        \\
        \\    analysis ( " analysis_identifier " { , " analysis_identifier " } )
        \\
        \\so `analysis()` with no name, or with a number or a variable, has
        \\nothing Table 4-21 could match.
        ,
    },
};
