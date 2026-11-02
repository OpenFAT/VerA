//! The diagnostic catalogue's class 6 rows, numerical safety (the proof):
//! `E0601` .. `W0652`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .E0601 = .{
        .title = "zero divisor",
        .lrm = "4.2.4",
        .explain =
        \\LRM 4.2.4: "It shall be an error to pass zero (0) as the second
        \\argument to the modulus operator." VerA rejects a provably-zero
        \\divisor for `%` of either type and for integer `/`.
        \\
        \\A divisor that merely MIGHT be zero is accepted, as every
        \\other domain rule is (provably outside -> error, unprovable ->
        \\accept):
        \\
        \\  - `%` of either type: the executable reports E0601 and exits 1
        \\    when the divisor is zero. A solver device traps without host
        \\    I/O, including on GPU targets. An unexecuted operand does not
        \\    fail. The 4.2.4 sentence names no operand type, so a real zero
        \\    divisor is the same error, not the NaN its formula would give;
        \\  - integer `/`: LRM 4.2.4 gives `/` no zero rule. The device yields
        \\    0 for a zero divisor, and W0653 says so;
        \\  - real `/`: x/0.0 is a well-defined IEEE infinity, which is what
        \\    lets `I <+ V/r` compile for an unranged parameter r (W0650).
        \\
        \\A range excluding zero (LRM 3.4.2) can prove a divisor valid:
        \\
        \\    parameter integer n = 1 from [1:inf);
        \\    parameter integer m = 1 exclude 0;
        \\
        \\or guard the operation with an `if` the prover can see.
        ,
    },
    .E0602 = .{
        .title = "argument of ln/log must be positive",
        .lrm = "4.3.1",
        .explain =
        \\Table 4-14 gives ln(x) and log10(x) the domain x > 0. LRM 4.3.2:
        \\"Input values outside of the valid range for the operator shall
        \\report an error."
        \\
        \\VerA proves this by interval analysis and reports only when
        \\the argument is provably outside the domain — an argument it
        \\cannot decide is accepted and costs the unit its finiteness
        \\proof (W0650), never a rejection.
        \\
        \\An accepted argument that IS outside the domain when it runs is
        \\the same error at run time: the executable (`--run`,
        \\`--emit-exe`, `--check`) prints this code with the value and
        \\exits 1. A solver device has no transcript, so it returns the
        \\IEEE value (NaN, or -inf for ln(0)). The same holds for E0603
        \\to E0607 and E0609.
        \\
        \\Constrain the parameter with `from (0:inf)` (LRM 3.4.2), or guard
        \\the call with `if (x > 0)`.
        ,
    },
    .E0603 = .{
        .title = "argument of ln1p must be greater than -1",
        .lrm = "4.3.1",
        .explain =
        \\ln1p(x) computes ln(1+x), so its domain is x > -1. See E0602 for
        \\how the proof works and how to satisfy it.
        ,
    },
    .E0604 = .{
        .title = "argument of sqrt must be non-negative",
        .lrm = "4.3.1",
        .explain =
        \\Table 4-14 gives sqrt(x) the domain x >= 0. See E0602.
        \\
        \\Constrain with `from [0:inf)`, or write `sqrt(abs(x))` if the
        \\magnitude is what the model means.
        ,
    },
    .E0605 = .{
        .title = "argument of asin/acos must be within [-1, 1]",
        .lrm = "4.3.2",
        .explain =
        \\Table 4-15 gives asin and acos the domain -1 <= x <= 1. See
        \\E0602. Constrain with `from [-1:1]`, or clamp the argument with
        \\`min`/`max` before the call.
        ,
    },
    .E0606 = .{
        .title = "argument of atanh must be within (-1, 1)",
        .lrm = "4.3.2",
        .explain =
        \\Table 4-15 gives atanh the OPEN domain -1 < x < 1; the endpoints
        \\are poles, not values. Constrain with `from (-1:1)` — note the
        \\round brackets, which LRM 3.4.2 uses for an excluded bound.
        ,
    },
    .E0607 = .{
        .title = "argument of acosh must be at least 1",
        .lrm = "4.3.2",
        .explain =
        \\Table 4-15 gives acosh the domain x >= 1. Constrain with
        \\`from [1:inf)`. See E0602.
        ,
    },
    .E0608 = retiredInfo(
        \\"argument of tan is at a pole". Retired: 4.3.2 makes tan
        \\undefined at odd multiples of pi/2, but those are irrational
        \\points and every IEEE double is rational, so no representable
        \\argument — not even a compile-time constant — is ever provably
        \\AT a pole. The reject arm of the prover's three-way domain split
        \\(proof.zig, checkDomain) is empty by construction, and an
        \\argument range that merely SPANS a pole contains pole-free
        \\points, so rejecting it would violate the straddle policy: such
        \\a tan is accepted and the unit compiles `.strict`, where the
        \\near-pole value is a defined IEEE result (W0650 reports the
        \\cost). A code that cannot fire is a lie in the catalogue.
        \\
        \\Nothing replaced it; the condition does not exist to report.
        \\The number is not reused.
    ),
    .E0609 = .{
        .title = "pow() arguments violate the sign rule",
        .lrm = "4.3.1",
        .explain =
        \\Table 4-14 constrains pow(x, y): with x < 0, y must be an
        \\integer, because a negative base raised to a fractional power has
        \\no real value; and with x == 0, y must be non-negative.
        \\
        \\Proved like E0602, and reported at run time like it: an
        \\argument pair outside the domain when it runs is E0609 from the
        \\executable, with exit status 1.
        \\
        \\Use `pow(abs(x), y)` with an explicit sign, or constrain the base
        \\with `from [0:inf)`.
        ,
    },
    .W0650 = .{
        .title = "unit is not provably finite, so it compiles in strict float mode",
        .lrm = "4.3",
        .explain =
        \\THE FINITENESS WARNING. This is not a correctness problem — the
        \\model is legal, it compiles, and it will simulate correctly. It
        \\reports what the model COSTS.
        \\
        \\VerA proves, per source unit (one `<+` target: an access
        \\function plus a node pair), whether every value in that unit's
        \\backward slice is a finite IEEE double. A unit that is proven
        \\finite compiles with @setFloatMode(.optimized), which asserts
        \\"no NaN, no Inf" and lets the backend reassociate, fuse and
        \\vectorize the residual. A unit that is not proven finite compiles
        \\with @setFloatMode(.strict), where infinity is a legal, IEEE-
        \\defined value — correct, but measurably slower, and it does not
        \\vectorize in the batch evaluator.
        \\
        \\LRM 4.3.2 makes exp's domain "All x", and LRM 4.5.13 makes
        \\`limexp` optional, so a model that can overflow to infinity is
        \\CONFORMANT. VerA never rejects one and never inserts a clamp
        \\or a limexp behind your back. It tells you instead.
        \\
        \\The attached notes name the value that broke the proof — a
        \\parameter with no range, a probe with unbounded magnitude, an
        \\unmodelled call — and where it was defined.
        \\
        \\Common causes, and what recovers .optimized:
        \\
        \\  - An unranged parameter feeding exp/sinh/cosh/pow. Add a range
        \\    (LRM 3.4.2): `parameter real vt = 0.026 from (0:1];`
        \\  - A raw probe inside a transcendental: exp(V(a,b)) overflows at
        \\    V > 710. Either bound the argument in the model, or tell the
        \\    engine the solver's compliance limit, which is a property of
        \\    your solver and not of the language:
        \\        proof.Options{ .unknown_bound = 100.0 }
        \\  - A division whose divisor may be zero: real x/0.0 is legal
        \\    (see E0601) but yields an infinity, so it forfeits the proof.
        \\    `exclude 0` on the divisor's parameter recovers it.
        \\  - A parameter whose range explicitly ADMITS infinity, e.g.
        \\    `from [0:inf]`. Closing the bound — `from [0:inf)` — keeps
        \\    the same values and restores finiteness. See W0651.
        \\  - A call the prover does not model (an analog operator, a ch9
        \\    system function). Unmodelled always costs .strict rather than
        \\    risking a wrong .optimized.
        \\
        \\If strict mode is what you want for this model, silence the
        \\warning with `--allow=W0650`.
        ,
    },
    .W0651 = .{
        .title = "parameter range admits infinity",
        .lrm = "3.4.2",
        .explain =
        \\A range whose bound is a CLOSED infinity — `from [0:inf]` — says
        \\that infinity is an acceptable value for this parameter, so the
        \\prover must treat it as a possible input and every unit
        \\downstream forfeits its finiteness proof (W0650).
        \\
        \\This is almost never intended. Writing the bound open,
        \\`from [0:inf)`, admits exactly the same finite values and keeps
        \\the proof:
        \\
        \\    parameter real r = 1k from (0:inf);
        \\
        \\See W0650 for what the proof buys.
        ,
    },
    .W0653 = .{
        .title = "integer division by a divisor that may be zero",
        .lrm = "4.2.4",
        .explain =
        \\The source is LEGAL. LRM 4.2.4 makes only a zero MODULUS divisor an
        \\error ("It shall be an error to pass zero (0) as the second
        \\argument to the modulus operator"); it gives integer `/` no zero
        \\rule, so a divisor the prover cannot show non-zero — typically an
        \\unranged `parameter integer` — is accepted.
        \\
        \\The result still has to be something. IEEE 1364 5.1.5, which this
        \\LRM inherits for integer arithmetic, makes division by zero `x`,
        \\and an analog integer has no `x`. If the divisor is zero at run
        \\time, the generated device yields 0. This warning is how you find
        \\out, because nothing at run time will tell you.
        \\
        \\To silence it, show the prover the divisor is never zero:
        \\
        \\    parameter integer k = 2 exclude 0;
        \\    parameter integer n = 2 from [1:inf);
        \\
        \\or guard the division with an `if (k != 0)` the prover can see, or
        \\accept the 0 explicitly with `--allow=W0653`.
        \\
        \\A divisor that is PROVABLY zero is still an error (E0601), as is an
        \\integer `%` whose divisor cannot be proven non-zero.
        ,
    },
    .W0652 = retiredInfo(
        \\"call is not modelled by the finiteness prover". Retired: nothing
        \\emits it. An unmodelled call (an analog operator, a ch9 system
        \\function) already reaches the user as W0650 on the unit it drags to
        \\.strict, so a second code for the same event was never wired up.
        \\The number is not reused.
    ),
};
