//! The diagnostic catalogue's class 5 rows, analog operators and math, part a:
//! `E0501` .. `E0520`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .E0501 = .{
        .title = "unknown access function",
        .lrm = "3.6.1.2",
        .explain =
        \\An access function name comes from the `access` attribute of a
        \\nature (LRM 3.6.1.2), reached through the discipline bound to the
        \\net. `V` and `I` come from annex D's `disciplines.vams`.
        \\
        \\LRM 4.4 requires that "the access function name shall match the
        \\discipline declaration for the nets, ports, or branch": using
        \\`V` on a net whose discipline binds a differently-named potential
        \\nature is this error, not a silent coercion.
        ,
    },
    .E0502 = .{
        .title = "ddt() requires an argument",
        .lrm = "4.5.3",
        .explain = "`ddt(expr)` differentiates its operand with respect to time.",
    },
    .E0503 = retiredInfo(
        \\"ddt() must be a linear factor of a contribution". Retired: a term
        \\whose ddt is not a linear factor, such as sin(ddt(V(a,b))), is now
        \\resistive, and each ddt in it is one of the new unknowns 4.5.2 lets
        \\an analog operator introduce, with its own row and charge site. So
        \\the condition does not exist to report. The number is not reused.
    ),
    .E0504 = .{
        .title = "ddx() second argument must be an access function",
        .lrm = "4.5.6",
        .explain =
        \\`ddx(expr, V(n))` takes the symbolic partial derivative of expr
        \\with respect to one probe, so the second argument names that
        \\probe and nothing else.
        ,
    },
    .E0505 = .{
        .title = "analog operator does not accept an empty argument",
        .lrm = "4.5.14",
        .explain =
        \\An omitted argument in an analog operator's list means "use the
        \\default". This operator has no default for that position.
        ,
    },
    .E0506 = .{
        .title = "wrong number of arguments to a math function or analog operator",
        .lrm = "4.3",
        .explain =
        \\LRM 4.3 tables 4-14 and 4-15 fix each math function's arity.
        \\Note `atan2(y, x)` and `hypot(x, y)` take two, while `min`, `max`
        \\and `pow` also take two. A.8.2 Syntax 4-3 fixes the longest
        \\argument list of each §4.5 analog operator: `transition` takes at
        \\most five, `ddt` two, `absdelay` three.
        ,
    },
    .E0507 = .{
        .title = "port access function must be a flow access",
        .lrm = "5.4.3",
        .explain =
        \\`I(<p>)` reads the flow INTO port p from outside the module. A
        \\potential has no such directional meaning at a port boundary, so
        \\the `<...>` form exists only for the flow access function of the
        \\port's discipline.
        \\
        \\For a potential, probe the node: `V(p)`.
        ,
    },
    .E0508 = .{
        .title = "port access function names a net that is not a port",
        .lrm = "5.4.3",
        .explain =
        \\`I(<p>)` measures flow across the module boundary, so p must be
        \\in the module's port list. An internal net has no outside.
        ,
    },
    .E0509 = .{
        .title = "assignment pattern is only legal where an array is expected",
        .lrm = "4.5.11",
        .explain =
        \\The assignment pattern `'{...}` (LRM 4.2.14) is an array value, so
        \\it is accepted only where an array is expected: a Laplace or
        \\Z-transform coefficient vector (4.5.11, 4.5.12), an array
        \\parameter or variable, an array argument. Used as an ordinary
        \\operand it has no value:
        \\
        \\    transition('{1.0, 2.0})            // no: a scalar slot
        \\    laplace_nd(V(p), '{1.0}, '{1.0, 1.0})   // yes
        \\
        \\The plain concatenation `{...}` (4.2.13) is a different operator
        \\and is a value anywhere; in a filter coefficient slot it is E0572.
        ,
    },
    .E0510 = .{
        .title = "recursive analog function",
        .lrm = "4.7.1",
        .explain =
        \\Analog functions are inlined at every call site, so recursion has
        \\no base case to stop the inliner. A compiled device has no call
        \\stack at run time.
        \\
        \\Rewrite as a loop, or unroll to a fixed depth.
        ,
    },
    .E0511 = .{
        .title = "wrong number of arguments to an analog function",
        .lrm = "4.7.2",
        .explain =
        \\An analog function call supplies exactly one actual argument per
        \\declared formal, in order. There are no defaults and no varargs.
        ,
    },
    .E0512 = .{
        .title = "unknown function",
        .lrm = "4.7",
        .explain =
        \\No analog function, math function or analog operator with this
        \\name is in scope. An analog function must be defined in the same
        \\module, before use.
        ,
    },
    .E0513 = .{
        .title = "absdelta() is only allowed in an initial or always block",
        .lrm = "5.10.3.4",
        .explain =
        \\LRM 5.10.3.4: "This function is only allowed in an initial or
        \\always block of a Verilog-AMS module." It samples an analog
        \\signal for DIGITAL code: each change of more than `delta` is an
        \\A2D event scheduled in the digital queue (8.4.6), which an
        \\analog event control has no use for.
        \\
        \\Move the sampler into a digital process:
        \\
        \\    always @(absdelta(V(in), 0.1)) sampled = V(in);
        \\
        \\In the analog block, `cross` or `above` detect a threshold, and
        \\`$bound_step` (LRM 9.17.2) bounds the timestep.
        ,
    },
    .E0514 = .{
        .title = "analog operator under a condition that can change during the solve",
        .lrm = "5.8.1",
        .explain =
        \\LRM 5.8.1: "If any of the conditionally-executed statements
        \\contains an analog operator, the conditional expression shall be
        \\a analysis_or_constant_expression." LRM 5.9 states the same ban
        \\for `repeat`, `while` and non-genvar `for`, without the carve-out.
        \\LRM 4.5.15 names the three conditional forms it covers — "inside
        \\conditional (if, case, or ?:) statements" — so an operator in an
        \\ARM of a `?:` is this rule too, and for the sharpest reason: 4.2.3
        \\makes `?:` short-circuiting, so the arm that is not selected is
        \\not evaluated at all.
        \\
        \\An analog operator is a STATE MACHINE, not a function: `ddt`,
        \\`idt`, `transition`, `slew`, `absdelay`, `laplace_*` and `zi_*`
        \\each carry history from one accepted timestep to the next. The
        \\generated device advances that history once per step, on the
        \\straight-line spine of the analog block. When the operator sits
        \\under a runtime branch, the step on which the branch is off feeds
        \\it the type's zero instead of the real input, so its history is
        \\wrong from then on — and it stays wrong after the branch comes
        \\back. Nothing about the residual looks unusual; the answer is
        \\just no longer the one the source describes.
        \\
        \\THREE CONDITIONS ARE LEGAL and do not warn:
        \\
        \\    if (analysis("dc"))  ...   // analysis_function_call
        \\    if (some_parameter)  ...   // constant_primary: a parameter
        \\    for (i = 0; i < 4; i = i + 1) ...   // genvar: unrolled
        \\
        \\None of them can change while the solve is running, so the
        \\operator's branch is decided once and its history stays whole.
        \\
        \\TO FIX: hoist the operator out of the branch and switch its
        \\RESULT instead of its execution —
        \\
        \\    tmp = ddt(V(a));               // always stepped
        \\    if (en) I(a) <+ tmp;           // only the use is conditional
        \\
        \\`--deny=E0514` makes this the error LRM 5.8.1 says it is. It is a
        \\warning by default only because rejecting it outright would stop
        \\compiling foundry models that have shipped with the bug for years.
        ,
    },
    .E0515 = .{
        .title = "analog operator control argument is not a constant or parameter expression",
        .lrm = "4.5",
        .explain =
        \\The CONSTANT arguments of a §4.5 analog operator (Table 4-20's
        \\"constant expression arguments": the delay, rise/fall times and
        \\time_tol of `transition`, the slew rates of `slew`, a ddt or idt
        \\abstol, the period of a `zi_*` filter) are evaluated by the HOST,
        \\outside the derivative domain the residual is computed in. VerA
        \\renders them as plain f64 expressions over `Model`, so they may be
        \\built from literals, parameters and card-time `$simparam` answers,
        \\through arithmetic, comparisons, `?:` and the math functions.
        \\Anything else has no value at that point.
        \\
        \\An argument that depends on a NODE VOLTAGE is the usual cause, and
        \\it is not a spelling problem: the operator's history is advanced
        \\once per accepted timestep, before the Newton iteration that would
        \\produce such a value.
        \\
        \\    transition(V(a), 0, V(c))        // no: a solve result
        \\    transition(V(a), 0, tr*1e-9)     // yes: parameters only
        \\
        \\A value assigned into a `real` variable first is fine — the
        \\expression is resolved through SSA, not by spelling — but one that
        \\merges two different values on two arms of a runtime `if` is not.
        \\
        \\Table 4-20's DYNAMIC arguments are not this code: `absdelay`'s td
        \\(frozen at its first evaluation without maxdelay, §4.5.7, clamped
        \\to maxdelay with it), `idt`'s ic and assert, `idtmod`'s ic, modulus
        \\and offset. Nor are a filter's coefficients or a signal-valued
        \\`maxdelay`, which §4.5.14 samples at the start of the analysis.
        ,
    },
    .E0516 = .{
        .title = "analog operator argument is outside the range the LRM allows",
        .lrm = "4.5",
        .explain =
        \\Each §4.5 operator states the bound on its control arguments in
        \\one sentence, and each bound is what makes the operator's contract
        \\satisfiable at all:
        \\
        \\  4.5.5  idtmod        "The modulus shall be an expression which
        \\                       evaluates to a positive value." The output
        \\                       range is offset <= idtmod < offset+modulus,
        \\                       which is empty unless modulus > 0.
        \\  4.5.7  absdelay      "In all cases td shall be a positive
        \\                       number." A negative delay asks a history
        \\                       buffer for the future.
        \\  4.5.8  transition    "td, rise_time, fall_time, and time_tol are
        \\                       optional, but if specified shall be
        \\                       non-negative." Zero is allowed and 4.5.8
        \\                       says what each zero means; negative would
        \\                       end a ramp before it starts.
        \\  4.5.9  slew          "max_pos_slew_rate shall be greater than
        \\                       zero (0) and max_neg_slew_rate shall be
        \\                       less than zero (0)." The signs are what say
        \\                       which limit is which.
        \\  4.5.10 last_crossing "The optional direction indicator shall
        \\                       evaluate to an integer expression +1, -1,
        \\                       or 0." An enumeration, not a range.
        \\
        \\Only arguments that FOLD are checked. These slots are typed
        \\analog_expression, so a rise time written over a parameter is
        \\legal and its sign is not knowable here; VerA stays silent rather
        \\than reject what it cannot prove.
        ,
    },
    .E0517 = .{
        .title = "monitored event argument is the wrong type or out of range",
        .lrm = "5.10.3",
        .explain =
        \\LRM 5.10.3.1 constrains cross()'s optional arguments:
        \\
        \\  "The dir and enable arguments, if specified, shall evaluate to
        \\   integers." 0 or absent is both edges, +1 rising, -1 falling.
        \\  "The tolerances (time_tol and expr_tol) ... shall be
        \\   non-negative." A tolerance is the window the crossing time is
        \\   narrowed into; a negative one names an empty window.
        \\  "If either or both tolerances are defined, then the direction
        \\   shall also be defined." A tolerance selects how precisely a
        \\   crossing is resolved, and which crossings count is the
        \\   direction's job — a tolerance without one narrows nothing.
        \\  "If expr_tol is specified, time_tol shall also be specified."
        \\   Supplying only expr_tol leaves the required time bound absent.
        \\
        \\LRM 5.10.3.2 gives above() the same tolerances and no direction,
        \\and 5.10.3.3 gives timer() the same time_tol sentence verbatim.
        \\LRM 5.10.3.4 requires absdelta()'s delta and both tolerances to
        \\be non-negative, and its enable to evaluate to an integer.
        \\Its numeric checks leave model-card and runtime values to
        \\evaluation; a real-valued 1.0 is integral, but 0.5 is not.
        \\
        \\Eliding a slot is not itself an error: Syntax 5-16 types them
        \\analog_expression_or_null and 5.10.3.1's own `sh` example writes
        \\`cross(V(smpl) - thresh, dir, , , en === 1'b1)`. The last slot,
        \\the enable, is analog_expression (A.6.5), so a comma before it
        \\promises one: `timer(0, 1n, 1p, )` is refused.
        \\
        \\A string-typed value (a `string` variable or parameter, 3.3) has
        \\no number to monitor. A string literal does: 2.7 reads it as an
        \\unsigned integer constant, so `cross("s")` monitors 115.
        ,
    },
    .E0518 = .{
        .title = "a zero-transition-time Z-filter cannot be contributed to a branch",
        .lrm = "4.5.12",
        .explain =
        \\LRM 4.5.12, verbatim: "If the transition time is specified as zero
        \\(0), then the output is abruptly discontinuous. A Z-filter with
        \\zero (0) transition time shall not be directly assigned to a
        \\branch."
        \\
        \\The zero transition time is not the error. The same clause makes
        \\the argument optional and "nonnegative", and reading the
        \\discontinuous output into a variable is legal:
        \\
        \\    real y;
        \\    analog begin
        \\      y = zi_zp(V(p, n), '{0.0, 0.0}, '{0.5, 0.0}, 1u, 0.0);
        \\      I(p, n) <+ y;
        \\    end
        \\
        \\What the clause bans is the discontinuity landing directly in the
        \\equation system, where a branch quantity that steps
        \\instantaneously has no derivative for Newton-Raphson to work with.
        ,
    },
    .E0519 = .{
        .title = "noise table is not a usable (frequency, power) table",
        .lrm = "4.6.4.3",
        .explain =
        \\LRM 4.6.4.3: "When the input is a vector it contains pairs of real
        \\numbers: the first number in each pair is the frequency in Hertz
        \\and the second is the power. The vector can either be specified as
        \\an array parameter or an array assignment pattern." And: "Each
        \\frequency value must be unique."
        \\
        \\So a table is an EVEN number of values, at least one pair, with
        \\distinct positive frequencies and non-negative powers. Ordering is
        \\NOT one of the rules — the same clause says "the simulator shall
        \\internally sort the pairs into ascending frequency if required",
        \\and VerA sorts at compile time, so a descending table compiles.
        \\
        \\4.6.4.4's noise_table_log interpolates log(power), so it wants
        \\every power strictly positive as well; log(0) is not a point on a
        \\log-log line.
        \\
        \\All four of A.8.2's `noise_table_input_arg` spellings are
        \\accepted, so the rules above are the whole of what this reports.
        \\
        \\The file form, `noise_table("noise.tbl")`, is read at COMPILE
        \\time: 4.6.4.3 says "the file name argument shall be constant", so
        \\the pairs behind it are compile-time data too, and the name is
        \\resolved against the include path exactly as 9.21's $table_model
        \\data source is. The errors above can therefore also come from the
        \\file's own contents.
        \\
        \\An array PARAMETER is a table the model CARD owns. `noise_tables`
        \\carries its declared defaults, which is all comptime data can
        \\hold, and a `noiseTablePoints(model)` hook beside it carries the
        \\card's own knots; the rules above are checked on the defaults, so
        \\a frequency a card duplicates is the host's problem and not this
        \\diagnostic's.
        \\
        \\The shortest spelling that satisfies every rule above is an
        \\assignment pattern of literals:
        \\
        \\    I(p, n) <+ noise_table('{1.0, 1e-18, 1e6, 1e-24});
        ,
    },
    .E0520 = .{
        .title = "noise generator has no branch to sit on",
        .lrm = "4.6.4",
        .explain =
        \\LRM 1.3.1.1 makes ground the reference node: it is not an unknown
        \\of the system, so it has no row and no column. A contribution
        \\between ground and ground therefore names NO branch — there is
        \\nothing for a current to flow through and nothing for a voltage to
        \\be measured across.
        \\
        \\For the large-signal residual that is harmless, and VerA drops
        \\such a contribution silently: KCL at the reference node is the one
        \\equation the solver does not write. A NOISE generator is different
        \\because it is EXPORTED — `noise_gens` names the (row, col) a host
        \\stamps the generator into, and this one has neither. Dropping it
        \\would delete a declared noise source from the model without
        \\telling anyone, and inventing a row would put noise on a branch
        \\the model never wrote.
        \\
        \\Contribute the source to a real branch: give the generator a node
        \\that is an unknown of the system, even if the other end is ground.
        ,
    },
};
