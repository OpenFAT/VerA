//! The diagnostic catalogue's class 8 rows, system tasks and functions, part a:
//! `E0801` .. `E0811`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .E0801 = retiredInfo(
        \\"unsupported system function". Retired: it was a CAPABILITY CLASS —
        \\one code for every ch9 function VerA declined to implement — and the
        \\list is now empty, so the diagnostic could not fire.
        \\
        \\Each name left it for the same reason. `$table_model` (LRM 9.21) got
        \\an interpolator (E0815 covers what it can compile). `$random`,
        \\`$arandom` and the `$dist_*`/`$rdist_*` family (LRM 9.13) turned out
        \\to be pure functions of an inout seed, so a draw cannot vary between
        \\Newton iterations at one point. `$simprobe` (LRM 9.16) is defined for
        \\the analog context by Table 9-13, and its unresolvable case has a
        \\value whenever the clause's fallback argument is supplied — E0817 is
        \\what is left of it, the case with no fallback.
        \\
        \\A function this compiler cannot host now gets a code that names the
        \\rule: E0806 for a digital-only name (LRM 9.2), E0808 for a spelling
        \\the language does not define. The number is not reused.
    ),
    .E0802 = .{
        .title = "$bound_step takes exactly one argument",
        .lrm = "9.17.2",
        .explain = "`$bound_step(max_step)` — one real expression.",
    },
    .E0803 = .{
        .title = "$bound_step argument must be non-negative",
        .lrm = "9.17.2",
        .explain =
        \\The argument is a maximum timestep, so a negative value has no
        \\meaning; the solver would have no bound to honour.
        ,
    },
    .E0804 = .{
        .title = "$discontinuity takes at most one argument",
        .lrm = "9.17.1",
        .explain =
        \\`$discontinuity` optionally takes the degree of the discontinuity
        \\— `$discontinuity(0)` for a value step, `$discontinuity(1)` for a
        \\slope step.
        ,
    },
    .E0805 = .{
        .title = "$discontinuity argument is not a constant expression",
        .lrm = "9.17.1",
        .explain =
        \\The degree is a property of the model's structure, not of the
        \\current operating point, so it must be known at compile time.
        ,
    },
    .E0820 = .{
        .title = "$discontinuity degree must be nonnegative or -1",
        .lrm = "9.17.1",
        .explain = "Nonnegative degrees describe a discontinuity in a derivative of the constitutive equation. The special degree -1 requests another Newton iteration; smaller degrees have no defined meaning.",
    },
    .E0821 = .{
        .title = "system task is not supported in the digital context",
        .lrm = "9.2",
        .explain =
        \\Every 9.2 table has two columns, "Supported in digital context"
        \\and "Supported in analog context". This name's digital cell is No.
        \\9.7 says it of the severity tasks in prose: "Verilog AMS HDL also
        \\supports three new simulation control tasks in the analog context
        \\only; $fatal, $error, $warning" (Table 9-4 adds $info).
        \\
        \\An `initial` or `always` block is the digital context (7.2.2).
        \\Move the call into the analog block, or use a task both columns
        \\allow, such as $display or $finish.
        ,
    },
    .E0887 = .{
        .title = "wrong number of arguments to a system task or function",
        .lrm = "9.5",
        .explain =
        \\Each Clause 9 call prints its argument list: Syntax 9-2 gives
        \\`$fopen(filename)` and `$fopen(filename, type)` and `$fclose(fd)`;
        \\Syntax 9-3 makes the descriptor the first argument of every file
        \\output task; §9.5.4.1 `$fgets(str, fd)`, §9.5.4.2
        \\`$fscanf(fd, format, args)`, §9.5.5 `$ftell(fd)`,
        \\`$fseek(fd, offset, operation)` and `$rewind(fd)`, §9.5.6
        \\`$fflush` with at most one descriptor, §9.5.7 `$ferror(fd, str)`,
        \\§9.5.8 `$feof(fd)`, Syntax 9-5 `$finish [ ( n ) ]`, and §9.12's
        \\IEEE 1364 §17.10 `$test$plusargs(string)` and
        \\`$value$plusargs(user_string, variable)`.
        \\
        \\A call with more or fewer arguments has no defined meaning: an
        \\argument the syntax has no slot for is not "ignored", and a
        \\missing descriptor is not descriptor 0. Supply exactly the list
        \\the clause prints.
        ,
    },
    // §9.14 / IEEE 1364-2005 §17.11.1 `$clog2` takes an integral operand.
    .E0892 = .{
        .title = "$clog2 requires an integer or vector argument",
        .lrm = "9.14",
        .explain = "IEEE 1364-2005 §17.11.1 permits an integer or an arbitrary sized vector, interpreted as unsigned. A real operand has no integral bit width; convert it explicitly with $rtoi if truncation is intended.",
    },
    // §9.14 an analog wide operand whose high bits the carrier erased.
    .E0893 = .{
        .title = "analog $clog2 cannot recover this wide operand's high bits",
        .lrm = "9.14",
        .explain = "Inside an analog $clog2 operand, arithmetic, unary negation and shifts retain at most 32 bits per intermediate. Bitwise, conditional and comparison contexts retain at most 64 bits. Above 64 bits only exact wide literals and parameter aliases preserving their width retain proven high bits. The compiler refuses a wider intermediate rather than inventing erased bits; digital execution preserves arbitrary vector widths.",
    },
    // §9.16 a `$simprobe` name that does not fold: run-time resolution is
    // not implemented, and the fallback would answer a valid name wrongly.
    .E0823 = .{
        .title = "$simprobe name known only at run time, with no fallback",
        .lrm = "9.16",
        .explain =
        \\    $simprobe ( inst_name , param_name [, expression] )
        \\
        \\LRM 9.16: "The arguments inst_name and param_name are string values,
        \\either a string literal, string parameter, or a string variable."
        \\A string variable's value can be set while the analog block runs, so
        \\the clause asks the simulator to resolve the name at run time.
        \\
        \\VerA resolves a run-time name against the elaborated design: every
        \\sibling parameter or output variable the name could be is compared
        \\with it when the probe runs, and the fallback is the value when
        \\none matches. With no fallback, a name that may match no sibling
        \\would need the error §9.16 raises at run time, which VerA cannot
        \\raise yet, so that probe is refused. This is an implementation
        \\limit (specification/Vague_Decisions.md VD-030), not a rule of the
        \\LRM. Give the fallback expression, or spell the name as a literal
        \\or a string parameter.
        ,
    },
    .E0894 = .{
        .title = "an omitted argument or element has no value here",
        .lrm = "A.8.2",
        .explain =
        \\A.8.2's system_function_call admits an empty slot, `$f(a, , c)`,
        \\but only the clause that defines the function can give that slot
        \\a meaning (a default, or "no string supplied"). This function's
        \\clause gives this position none, so the call has no value to
        \\compute. A.8.1's assignment pattern has no empty element at all,
        \\except where §3.6.3.2's bus nodeset reads one as "no nodeset value
        \\for this element". Write the argument or the element.
        ,
    },
    .E0888 = .{
        .title = "descriptor argument is not an integer",
        .lrm = "9.5.2",
        .explain =
        \\§9.5.1: "The multichannel descriptor mcd is a 32-bit integer" and
        \\"The file descriptor fd is a 32-bit value" whose bit 31 is set.
        \\§9.5.2: "The first argument shall be either a multichannel
        \\descriptor or a file descriptor ... A multichannel descriptor is
        \\either a variable or the result of an expression that takes the
        \\form of a 32-bit unsigned integer value."
        \\
        \\A real has no bit 31 and a string is not a 32-bit value, so
        \\neither names an open file. Pass the integer `$fopen` returned.
        ,
    },
    .E0889 = .{
        .title = "$fopen type is not one of Table 9-24's forms",
        .lrm = "9.5.1",
        .explain =
        \\§9.5.1: "type is a string expression containing a character
        \\string of one of the forms in Table 9-24": "r", "rb", "w", "wb",
        \\"a", "ab", "r+", "r+b", "rb+", "w+", "w+b", "wb+", "a+", "a+b"
        \\or "ab+". Any other string opens the file in no mode the clause
        \\defines. Only a type written as a literal can be judged at compile
        \\time.
        ,
    },
    .E0890 = .{
        .title = "hierarchical system parameter outside its allowed values",
        .lrm = "9.18",
        .explain =
        \\§9.18 Table 9-29's "Allowed Values" column: `$mfactor > 0`,
        \\`$hflip = +1 or -1`, `$vflip = +1 or -1`, `0 <= $angle < 360`.
        \\Each specified value must satisfy its domain before it is
        \\combined with the parent's value. Valid angles can sum past
        \\360 degrees: the resolved angle is reduced modulo 360. Flips
        \\and multiplicities multiply; position offsets add. A zero
        \\`$mfactor` would divide branch-flow probes by zero under §6.3.6.
        \\
        \\Only a value that folds without the model card is judged here.
        ,
    },
    // §9.17.3 a `$limit` argument that is not the form Syntax 9-12 spells.
    .E0891 = .{
        .title = "$limit argument is not the form Syntax 9-12 requires",
        .lrm = "9.17.3",
        .explain =
        \\LRM 9.17.3 Syntax 9-12 gives `$limit` three forms:
        \\
        \\    $limit ( access_function_reference )
        \\  | $limit ( access_function_reference , string , arg_list )
        \\  | $limit ( access_function_reference , analog_function_identifier , arg_list )
        \\
        \\The first argument is the probe itself: "It returns a real value
        \\that is derived from its first argument (the access function
        \\reference, such as a branch voltage)". The limiter's state is the
        \\history of that probe across Newton iterations, so an expression
        \\such as `type*V(a,b)` has no place to keep it. The second argument
        \\names the algorithm: a string for one built into the simulator, or
        \\a user-defined analog function (4.7).
        \\
        \\Scale the result instead of the probe, or use VerA's trailing sign
        \\argument for a reversed-polarity junction:
        \\
        \\    vbe = type * $limit(V(b,e), "pnjlim", vte, vcrit, type);
        \\
        \\A string VerA does not implement, or no string at all, is legal:
        \\the simulator then chooses "just as if no string had been
        \\supplied" (W0853).
        ,
    },
    .E0822 = .{
        .title = "binding detection argument is the wrong kind of name",
        .lrm = "9.19",
        .explain =
        \\LRM 9.19: "The $param_given() function takes a single argument,
        \\which must be a parameter identifier", and "The $port_connected()
        \\function takes one argument, which must be a port identifier."
        \\
        \\Both answer a question about the INSTANTIATION — was this
        \\parameter overridden, was this port connected — so a variable or
        \\an internal net has no answer: nothing instantiates it.
        ,
    },
    .E0824 = .{
        .title = "$fatal finish_number is not 0, 1 or 2",
        .lrm = "9.7.3",
        .explain =
        \\LRM 9.7.3 Syntax 9-7:
        \\
        \\    fatal_message_task ::= $fatal [ ( finish_number
        \\                           [ , message_argument ... ] ) ] ;
        \\    finish_number ::= 0 | 1 | 2
        \\
        \\"The first argument passed to $fatal shall be consistent with the
        \\corresponding argument to the Verilog $finish system task", whose
        \\diagnostic levels are Table 9-25's 0, 1 and 2. Write one of those
        \\three numbers; any other value, or one known only at run time, is
        \\not a finish_number.
        ,
    },
    .E0806 = .{
        .title = "system task is not supported in the analog context",
        .lrm = "9.2",
        .explain =
        \\Every Chapter 9 table has a "supported in analog context" column,
        \\and this name's cell says No. The prose subclauses are worded as
        \\PERMISSIONS — §9.5 "extends many of the file operation tasks so
        \\that they can be used in the analog context", and §9.11 permits
        \\$bitstoreal, $realtobits, $rtoi and $itor there. The tables under
        \\§9.2 specify which other names remain digital-only.
        \\
        \\The families, and why each stops at the digital context:
        \\
        \\  Table 9-1 / 9-2 — the b/h/o radix variants of the display and
        \\  file-output tasks. The suffix only picks a DEFAULT radix for
        \\  arguments written without a format specification, which is a
        \\  statement about bit vectors; §9.4.3's per-argument `%b`/`%o`/
        \\  `%h` works fine in an analog block. $monitoron/$monitoroff
        \\  toggle the digital $monitor mechanism.
        \\
        \\  Table 9-2 also — $fgetc, $ungetc and $fread read bytes and bit
        \\  patterns; $readmemb/$readmemh load a memory array and
        \\  $sdf_annotate loads timing onto a digital netlist. Neither
        \\  object exists in the analog context.
        \\
        \\  Table 9-3 / 9-7 — $printtimescale, $timeformat, $time and
        \\  $stime are all about the timescale TICK. The analog kernel has
        \\  no tick: it advances by a continuously variable step. §9.10
        \\  adds $abstime, in seconds, for the analog context, and
        \\  deprecates $realtime there.
        \\
        \\  Table 9-5 / 9-6 — §9.8 and §9.9 are one sentence each: Verilog
        \\  AMS HDL "does not extend" the PLA modeling tasks, and "does not
        \\  extend" the stochastic analysis tasks.
        \\
        \\  Table 9-8 — $signed and $unsigned, and only those two: §9.11
        \\  names $bitstoreal, $realtobits, $rtoi and $itor as the four
        \\  conversions that DO cross into the analog context. Signedness
        \\  reinterpretation presupposes a sized vector, which is the one
        \\  thing a real-valued analog expression never has.
        ,
    },
    .E0807 = .{
        .title = "$stop shall not be used within an analog initial block",
        .lrm = "9.7.2",
        .explain =
        \\§9.7.2: "$stop causes simulation to be suspended at a converged
        \\time point", and an analog initial block runs before there is
        \\one — §5.2.1 executes it once per analysis, ahead of the first
        \\matrix solution.
        \\
        \\$finish is deliberately the opposite: §9.7.1 defines what it
        \\means there ("the simulator shall exit without performing the
        \\simulation"), so it stays legal in an analog initial block.
        \\$stop in an ordinary `analog` block is legal too.
        ,
    },
    .E0808 = .{
        .title = "retired Verilog-A v1.0 spelling",
        .lrm = "G.1",
        .explain =
        \\Annex G Table G.1, "Limiting exponential function": the OVI
        \\Verilog-A v1.0 spelling `$limexp( expression )` was replaced in
        \\v2.0 by `limexp( expression )`.
        \\
        \\It is not an alias. A `$` name is a system function (Clause 9),
        \\and `$limexp` appears in neither Table 9-11 nor A.8.2 — the name
        \\does not exist. 4.5.13 defines the analog operator under the bare
        \\name only.
        \\
        \\Drop the `$`.
        ,
    },
    .E0809 = .{
        .title = "$limit is missing an argument its algorithm requires",
        .lrm = "9.17.3",
        .explain =
        \\LRM 9.17.3 fixes the arity of the two algorithms it names:
        \\
        \\  "fetlim" — "One additional argument to the $limit() function is
        \\    required ...: the third argument to $limit() is generally the
        \\    threshold voltage of the MOS transistor."
        \\  "pnjlim" — "Two additional arguments ... are required ...: the
        \\    third argument ... indicates a step size vte and the fourth
        \\    argument is a critical voltage vcrit."
        \\
        \\This is not the unknown-string case. The same clause lets a
        \\simulator ignore a string it does not recognise ("just as if no
        \\string had been supplied"), and `$limit(V(a,b))` with no string
        \\at all is legal (Syntax 9-12). Naming one of these two is what
        \\imposes the arity.
        ,
    },
    .E0810 = .{
        .title = "not enough arguments for the format specifiers",
        .lrm = "9.4.3",
        .explain =
        \\LRM 9.4.3, stated again in 9.4.1: "for each % character (except
        \\%m, %% and %l) that appears in a string, a corresponding
        \\expression argument shall be supplied after the string."
        \\
        \\The parenthesis is what makes this checkable rather than a
        \\formatting preference: three specifiers consume no operand and
        \\every other one consumes exactly one, so the format string alone
        \\fixes how many arguments are required.
        \\
        \\The reverse is NOT an error. 9.4.3 gives extra arguments a
        \\meaning — "any expression argument with no corresponding format
        \\specification is displayed using the default decimal format" —
        \\so only a shortfall is diagnosed.
        \\
        \\Only a literal format string is counted. A format assembled at
        \\run time has no count to check against.
        ,
    },
    .E0811 = .{
        .title = "simulation parameter is not known",
        .lrm = "9.15",
        .explain =
        \\LRM 9.15 states $simparam in three sentences, one per branch:
        \\"If param_name is known, its value is returned. If param_name is
        \\not known, and the optional expression is not supplied, then an
        \\error is generated. If the optional expression is supplied, its
        \\value is returned if param_name is not known and no error is
        \\generated."
        \\
        \\This is the middle branch. The reason it is an error rather than
        \\a default is that the two are indistinguishable at the call site:
        \\a silent 0.0 reads exactly like a simulator that really does
        \\carry the parameter and really does report zero for it, and a
        \\model that divides by it or compares against it is then wrong
        \\with nothing to point at.
        \\
        \\Two fixes, and the LRM prints both:
        \\
        \\    gmin = $simparam("gmin");                  // must be known
        \\    sourcescale = $simparam("sourceScaleFactor", 1.0);
        \\
        \\The second form is legal for EVERY name, known or not — Table
        \\9-27 is prefaced "simulators shall accept the strings ... if they
        \\support the parameter" — so a model that wants to stay portable
        \\across tools writes the fallback.
        \\
        \\Only a literal name is checked. 9.15 also allows a string
        \\parameter or a string variable, whose value is not available
        \\here, and the fallback is the user's cover for that case.
        \\
        \\"$simparam$str is similar to $simparam" but takes no fallback,
        \\so a literal name outside Table 9-28 ("analysis_name",
        \\"analysis_type", "cwd", "module", "instance", "path") is this
        \\error too.
        ,
    },
};
