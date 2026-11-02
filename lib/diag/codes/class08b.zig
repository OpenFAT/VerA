//! The diagnostic catalogue's class 8 rows, system tasks and functions, part b:
//! `E0812` .. `W0852`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

pub const rows = .{
    .E0812 = .{
        .title = "invalid use of a node alias system function",
        .lrm = "9.20",
        .explain =
        \\LRM 9.20 states $analog_node_alias() and $analog_port_alias() as
        \\a validity list, and this code carries all of it. One number,
        \\because the six sentences are one rule with one reason: an alias
        \\makes the named node "refer to the same circuit matrix position"
        \\as the hierarchical reference, so it is a TOPOLOGY edit, and
        \\topology is fixed before a solve runs.
        \\
        \\    integer ok;
        \\    electrical local;
        \\    analog initial ok = $analog_node_alias(local, "$root.top.a");
        \\
        \\What the clause requires, in the order it is checked:
        \\
        \\  1. "It shall be an error for the ... system functions to be
        \\     used outside the analog initial block." An ordinary analog
        \\     block runs inside the Newton loop.
        \\  2. They "shall not be used inside conditional (if, case, or
        \\     ?:) statements unless the conditional expression ...
        \\     consists of terms which can not change during the course of
        \\     a simulation". A parameter guard is fine; $abstime is not.
        \\  3. The analog_net_reference "shall be either a scalar or vector
        \\     continuous node declared in the module containing the system
        \\     function call".
        \\  4. "It shall be an error for the analog_net_reference to be a
        \\     port or to be involved in port connections" — a port is
        \\     already bound by the instantiating netlist.
        \\  5. A vector "shall reference the full vector node, it shall be
        \\     an error for it to be a bit select or part select". The
        \\     scalar element goes on the OTHER side of the call.
        \\  6. The hierarchical_reference_string "shall be a constant
        \\     string value (string literal or string parameter)", and it
        \\     shall not name a node that is already the
        \\     analog_net_reference of another alias call.
        \\
        \\An unresolvable reference is NOT an error: the same clause makes
        \\that a return value, "one (1) if the hierarchical_reference_string
        \\points to a valid continuous node and zero (0) otherwise".
        ,
    },
    .E0813 = .{
        .title = "invalid argument to a string formatting or scanning task",
        .lrm = "9.5.3",
        .explain =
        \\LRM 9.5.3 puts the destination first — "the first argument to
        \\$swrite shall be a string variable to which the resulting string
        \\shall be written, instead of a variable specifying the file to
        \\which to write" — and 9.5.4.2 gives $sscanf its output
        \\arguments, one per non-suppressed conversion.
        \\
        \\    string text;  real x;  integer code;
        \\    $sformat(text, "v=%10.4e", V(p,n));
        \\    code = $sscanf(text, "v=%e", x);
        \\
        \\So this fires when a destination is not something that can be
        \\assigned to: a $swrite/$sformat first argument that is not a
        \\`string` variable, an output argument that is a literal or an
        \\expression, or one of the two writers used in expression
        \\position, where it has no destination at all.
        \\
        \\It also fires on a conversion code VerA does not scan. 9.5.4.2's
        \\own list is %d %o %h %x %b %c %f %e %g %s, with the assignment
        \\suppression * and a maximum field width; the strength, 4-state
        \\and timeformat codes (%v, %z, %t) describe values an analog
        \\device does not have. Refusing one is deliberate: a code that
        \\scanned as garbage would still be COUNTED in the return value,
        \\so the model would read a plausible number and never find out.
        ,
    },
    .E0814 = .{
        .title = "a $limit limiter argument is not `input`",
        .lrm = "9.17.3",
        .explain =
        \\LRM 9.17.3, on Syntax 9-12's third form
        \\`$limit(access_function_reference, analog_function_identifier,
        \\arg_list)`: "The arguments of the user-defined function shall all be
        \\declared input."
        \\
        \\The simulator supplies every one of them — "The first argument of
        \\the user-defined function shall be the value of the access function
        \\reference for the current iteration. The second argument shall be
        \\the appropriate internal state; generally, this is the value that
        \\was returned by the $limit() function on the previous iteration" —
        \\so they are the solver's iteration history handed inward. An
        \\`output` or `inout` formal would write back into that history
        \\mid-Newton-step, and 9.17.3 gives that no meaning.
        \\
        \\Return the limited value as the function's own return variable
        \\(4.7.1), which is what $limit() reads.
        ,
    },
    .E0816 = .{
        .title = "a $9.13 probabilistic distribution argument",
        .lrm = "9.13",
        .explain =
        \\Table 9-10's 17 names are supported in the analog context, and
        \\9.13.1/9.13.2 state four rules about their arguments. This fires on
        \\all four, because they are one clause and the message says which:
        \\
        \\THE SEED'S TYPE. "For each system function, the seed argument shall
        \\be an integer", and Syntax 9-9 spells the same rule as grammar:
        \\
        \\    seed ::= integer_variable_identifier
        \\           | integer_parameter_identifier
        \\           | [ sign ] decimal_number
        \\
        \\A real is none of the three, and no coercion is available: an
        \\integer VARIABLE seed is an inout argument, so the function needs a
        \\place to write an updated integer back to.
        \\
        \\THE DOMAIN. "For the $rdist_exponential, $rdist_poisson,
        \\$rdist_chi_square, $rdist_t, and $rdist_erlang functions, the
        \\arguments mean, degree_of_freedom, and k_stage shall be greater
        \\than zero (0). Otherwise an error shall be reported." Not a
        \\warning, not a clamp — and IEEE 1364 17.9.2 states the same domain
        \\for the integer $dist_ twins.
        \\
        \\THE UNIFORM'S ORDER. "In $rdist_uniform, the start and end
        \\arguments are real inputs which bound the values returned. The
        \\start value shall be smaller than the end value." An interval with
        \\start above end is empty, so there is no value to draw from it.
        \\
        \\THE type_string. Syntax 9-8/9-9's optional trailing string
        \\("instance" or "global") says which paramset override owns the
        \\stream, so it is meaningful only inside a 6.4 paramset.
        ,
    },
    .E0818 = .{
        .title = "driver access function outside a connect module",
        .lrm = "9.22",
        .explain =
        \\LRM 9.22, paragraph 3, both sentences: "The driver access functions
        \\described here only access drivers found in ordinary modules and not
        \\to those found in connect modules. Driver access functions can only
        \\be called from connect modules." 9.23 fences its four supplementary
        \\functions the same way and one step tighter — they are "supported in
        \\the digital context of connectmodules" — and Table 9-19 gives every
        \\member of both families "Supported in analog context of
        \\connectmodule: No".
        \\
        \\The two sentences are not in tension: the functions REPORT on
        \\drivers found in ordinary modules, but they may only be CALLED from
        \\a connect module. So the call site alone decides this, with no
        \\netlist, no elaboration and no driver: an ordinary `module` is not a
        \\`connectmodule`, and a call in one is illegal on sight.
        \\
        \\VerA has no `connectmodule` design element, so EVERY call site in a
        \\file VerA can compile is outside one and this diagnostic fires on
        \\every one of them. That is the conforming behaviour, not a
        \\limitation standing in for one: the alternative VerA used to ship
        \\was to answer the constant 0, and a plausible wrong number is the
        \\worst thing a compiler can hand back — 9.22.2/9.22.3/9.23.x take a
        \\driver_index "between 0 and N-1", which for N = 0 is an EMPTY range
        \\with no element 0 to have a value.
        \\
        \\When VerA grows connect modules the rule does not move: it narrows
        \\from "no module has drivers" to "this module is not a connect
        \\module", which is the same test on a wider language.
        ,
    },
    .E0819 = .{
        .title = "format conversion does not match the operand's type",
        .lrm = "9.4.3",
        .explain =
        \\9.4.3 pairs each consuming conversion with the expression argument
        \\that follows the format string. VerA's formatter renders three
        \\operand types — real, integer, string — and most conversions have a
        \\reading for each: %d/%b/%o/%h round a real, and a string operand
        \\under them takes 2.7's "unsigned constant number" view, one byte
        \\per character. Four pairings have no rendering VerA emits:
        \\
        \\    %s over a real, or an integral expression whose width the
        \\    current backend cannot preserve. Integer operands with a known
        \\    supported width render as 9.4.5's sequence of 8-bit ASCII codes.
        \\    Remaining numeric cases are implementation limitations.
        \\
        \\    %c over a string. Table 9-22's %c displays the low byte of an
        \\    INTEGER as a character; a string is not a code. Use %s for the
        \\    text, or index a code out of it.
        \\
        \\    %e/%f/%g/%r (and the %t/%u/%z/%v defaults) over a string.
        \\    There is no numeric field to format; %s prints the text, %d
        \\    prints 2.7's integer view.
        \\
        \\    Any conversion but %s over a null argument (`,,`). 9.4.1 gives a
        \\    null argument "a single space character in the display" and no
        \\    value; %s prints that space (VD-101).
        \\
        \\The diagnostic points to the operand before generated code is
        \\compiled. An unsupported pairing is not necessarily illegal
        \\Verilog-AMS; consult the conformance backlog for implementation gaps.
        ,
    },
    .E0825 = .{
        .title = "'#' flag on a format conversion that has no alternative form",
        .lrm = "9.4.3",
        .explain =
        \\9.4.3: "The format specifications in Table 9-23 are used for real
        \\numbers and have the full formatting capabilities available in the
        \\C language." C11 7.21.6.1 gives '#' its alternative form, which for
        \\%e, %f and %g always prints the decimal point (and for %g keeps the
        \\trailing zeros): `%#.0f` of 2.0 prints "2.", `%#g` of 1.5 prints
        \\"1.50000". VerA implements it there.
        \\
        \\The grant names Table 9-23 only. Table 9-22's conversions (%h %d %o
        \\%b %c %s, and %m %l, which take no argument) are Verilog's, sized
        \\by IEEE 1364-2005 17.1.1.3 rather than by C, and Table 9-23's %r is
        \\2.6.2's engineering notation, which C does not have; no clause says
        \\what '#' does to any of them. Rather than guess (C's `0x` prefix on
        \\an auto-sized %h?), VerA refuses the flag. Drop the '#', or format
        \\the value with %e, %f or %g.
        ,
    },
    .E0826 = .{
        .title = "a flag, width or precision written on `%%`",
        .lrm = "9.4.2",
        .explain =
        \\9.4.1: "The special character string %% indicates the display of
        \\the percent sign character (%)", and Table 9-21 (9.4.2) lists `%%`
        \\as an escape sequence: two characters, nothing between them. A
        \\flag, a width or a precision there (`%5%`, `%-%`, `%.2%`) is no
        \\escape of Table 9-21 and no format specification of Tables 9-22 and
        \\9-23. The real conversions' grant of "the full formatting
        \\capabilities available in the C language" (9.4.3) does not cover it
        \\either: C11 7.21.6.1p8 says "The complete conversion specification
        \\shall be %%", so `%5%` has no meaning in C.
        \\
        \\Rather than guess whether the width pads the `%` or whether the
        \\specification takes an argument, VerA refuses it. Write `%%` for a
        \\percent sign, or `%5s` over "%" for a padded one.
        ,
    },
    .E0827 = .{
        .title = "a C format flag on a digital-context conversion that is not a real one",
        .lrm = "9.4.7",
        .explain =
        \\IEEE 1364-2005 17.1.1.2: "The format specifications in Table 17-3
        \\are used with real numbers and have the full formatting
        \\capabilities available in the C language." In the digital context
        \\VerA therefore renders C11 7.21.6.1's flags on %e, %f and %g (and
        \\on 9.4.7's %r, '#' apart): `%-8.2f` of 2.5 prints "2.50    ",
        \\`%08.3f` of -2.5 prints "-002.500".
        \\
        \\The grant names the real conversions only. The others (%h %d %o %b
        \\%c %s %t %v %m %l) are sized by 17.1.1.3, automatically or by a
        \\written width, and its one override is the zero of `%0d`. No clause
        \\says what '-', '+' or ' ' does to such a field (does `%-h` pad an
        \\auto-sized hex field on the right?), so VerA refuses the flag rather
        \\than read it and print the field as if it were not there. Drop the
        \\flag, or format a real with %e, %f or %g. ('#' outside %e, %f and %g
        \\is E0825.)
        ,
    },
    .E0828 = .{
        .title = "a format field width or precision past VerA's limit",
        .lrm = "9.4.3",
        .explain =
        \\9.4.3 gives the real conversions "the full formatting capabilities
        \\available in the C language", and VerA reads a width and a
        \\precision on every conversion. Neither the clause nor C bounds
        \\them; a device has to. Its field is composed in a buffer sized at
        \\compile time from the width and the precision, and its real
        \\conversion counts digit positions as 32-bit integers, so VerA
        \\takes a width or precision up to 2^30 (1073741824) in an
        \\analog-context format, the limit in specification/Vague_Decisions.md
        \\section 7. A larger one, or one too long to be a number at all, is
        \\refused here rather than overflow the device's arithmetic.
        \\
        \\A field that wide is already a gigabyte of text. Write a smaller
        \\width or precision. (The digital context writes its padding as it
        \\goes and takes any width.)
        ,
    },
    .E0829 = .{
        .title = "system function not run by VerA's digital engine",
        .lrm = "9.2",
        .explain =
        \\Every 9.2 table has a "Supported in digital context" column. This
        \\name's cell is Yes, so the call is legal in an `initial` or
        \\`always` block, and VerA's digital engine does not evaluate it
        \\yet: $arandom and the $rdist_ functions (Table 9-10), $min, $max
        \\and $abs (Table 9-11), $temperature, $vt, $simparam and
        \\$simparam$str (Table 9-12), the hierarchical parameter functions
        \\$mfactor, $xposition, $yposition, $angle, $hflip and $vflip
        \\(Table 9-15), and $table_model (Table 9-18). It is refused by name
        \\rather than run as something else.
        \\
        \\The digital context does run $abstime, $realtime, the IEEE 1364
        \\math functions with $ln1p and $expm1, and the $dist_ functions.
        \\Compute the value in the analog block and read the variable from
        \\the digital process (VAMS 7.3.6.4), or use one of those.
        ,
    },
    .E0817 = .{
        .title = "$simprobe resolves to nothing and has no fallback",
        .lrm = "9.16",
        .explain =
        \\    $simprobe ( inst_name , param_name [, expression] )
        \\
        \\LRM 9.16: "If either the inst_name or param_name cannot be resolved,
        \\and the optional expression is not supplied, then an error shall be
        \\generated. If the optional expression is supplied, its value will be
        \\returned in lieu of raising an error." This is the first sentence.
        \\
        \\VerA resolves the pair as one flat name — `inst_name.param_name` —
        \\against the elaborated design, which is the same identity every 6.7
        \\out-of-module reference uses: a flattened child's parameter is named
        \\by its hierarchical path. So the names that resolve are the ones a
        \\path could reach from this device.
        \\
        \\Supplying the third argument is what makes a probe of something
        \\OUTSIDE this device — a sibling instance the compiler never sees — a
        \\legal call with a defined value. A name built at run time is a
        \\different case, E0823: it is refused, because it may name something
        \\that exists.
        ,
    },
    .E0815 = .{
        .title = "$table_model data source or control string",
        .lrm = "9.21",
        .explain =
        \\    $table_model ( table_inputs , table_data_source
        \\                   [, table_control_string] )
        \\
        \\One lookup expression per dimension, then either a file name or one
        \\array per dimension followed by an output array (9.21.1), then an
        \\optional control string (9.21.2).
        \\
        \\    real y[0:11], x[0:11], f_xy[0:11];
        \\    f = $table_model(0.25, 3.5, y, x, f_xy);
        \\    g = $table_model(0.25, V(a,b), "sample.dat", "1LL,1LL;1");
        \\
        \\This fires on a call whose shape does not add up — a file that
        \\cannot be read or does not hold a rectangular block of numbers,
        \\arrays of differing lengths (they are COLUMNS of one table), fewer
        \\columns than the inputs need, fewer samples than 9.21's "at least
        \\two points per dimension (2^N for N dimensions)", or a dependent
        \\selector naming a column the data source does not have.
        \\
        \\It also fires on an interpolation scheme VerA does not implement.
        \\Table 9-30's `1` (linear) is the one implemented; `D`, `2` and `3`
        \\(closest point, quadratic and cubic splines) and `I` (ignore this
        \\column) are refused rather than substituted, as is Table 9-31's `E`
        \\— "an extrapolation error is reported if the $table_model function
        \\is requested to evaluate a point beyond the interpolation region",
        \\and a compiled residual has no channel to report one on. Extrapolating
        \\anyway is precisely the wrong-number failure `E` exists to prevent.
        \\Table 9-31's `C` and `L` both work.
        ,
    },
    .W0850 = .{
        .title = "task dropped: a device does not print and has no file table",
        .lrm = "9.4",
        .explain =
        \\VerA makes two artifacts out of one .va, and this one is the
        \\DEVICE: a residual function the solver calls inside its Newton
        \\loop, on a batch of instances, possibly on a GPU.
        \\
        \\A print there is not a debugging aid, it is a per-iteration
        \\syscall on a hot loop that also happens not to compile for
        \\SPIR-V or PTX. So a device prints nothing. What it does instead,
        \\by default (`--display=record`), is RECORD: its `say` entry point,
        \\which a host calls once per accepted point (9.4.6: "All the display
        \\tasks, except $debug, shall not display output unless an iteration
        \\has been accepted"), appends each $strobe, $display, $write,
        \\$debug, $warning and $info it runs to a buffer the host lends, as
        \\a site index and its numbers, and the host prints them
        \\(`contract.SaySite`, `contract.formatSay`). A host that also
        \\calls it after each Newton iteration (`contract.SayPass`) shows
        \\$debug at every iteration, as 9.4.1 has it. $fatal and $error
        \\latch the device's status (`contract.StatusSite`), which stops its
        \\rows until the host clears it.
        \\
        \\This warning names what is still dropped, once per call site:
        \\$monitor (9.4.1's change detection is state across accepted steps
        \\a device does not keep), $finish and $stop (eval has no channel to
        \\stop a host's solve), a printing task with a string argument that
        \\is not a constant (a record carries numbers), and, under
        \\`--display=drop`, every display task.
        \\
        \\The model is CONFORMANT; nothing is wrong with it. If the text
        \\is what you wanted, build the other artifact:
        \\
        \\    vera --emit-exe FILE.va       # a runnable testbench
        \\    vera --display=emit ...       # or just the codegen knob
        \\
        \\which lowers the same tasks to `std.debug.print` and gives the
        \\device a `display()` entry point that runs them.
        \\
        \\The LRM 9.5 file family is on the same list, for the same reason
        \\one step further out: a descriptor operation is a side effect, and
        \\`eval` has to stay a pure function of x or the solver's Newton
        \\iteration cannot converge. 9.5.9 agrees — "the file write
        \\operations shall not be performed unless the iteration is
        \\accepted" — so those calls are sequenced in the same per-point
        \\`display()` phase, and a device without one has no file table.
        \\
        \\That is not a stub: 9.5.1 reserves zero for "if a file cannot be
        \\opened", and a device with no table genuinely cannot open one. So
        \\`$fopen` answers 0, and every later call on that 0 has a defined
        \\answer of its own (9.5.4.1's "code is set to zero", 9.5.7's zero
        \\errno with an empty description, 9.5.8's zero).
        \\
        \\Silence it for a model you know prints only under a debug flag
        \\with `--allow=W0850`.
        ,
    },
    .W0852 = .{
        .title = "unregistered system function is left to a VPI host",
        .lrm = "12.32.3",
        .explain =
        \\This `$name` is not a Chapter 9 system function and not an Annex D
        \\or §4.5 operator. LRM 2.8.3 still makes it grammatical, and lists
        \\"defined using the VPI as described in Clause 11 and Clause 12" as
        \\one of the places a system function may come from — §12.32's
        \\vpi_register_analog_systf() is that place, and it hands the
        \\APPLICATION a compiletf routine so the application, not the
        \\compiler, decides what the name means.
        \\
        \\So the source is legal and VerA may not reject it. §12.32.3's own
        \\illustration is a contribution:
        \\
        \\    V(out) <+ $sampler(V(in), period);
        \\
        \\VerA has nothing to ask, so it does not answer: the name is
        \\exported in the device's `systf_calls` table and the call site
        \\reads its value — and its derivatives — from the application the
        \\HOST binds into `Instance.systf`. `contract.validateHost` refuses
        \\to build a host that binds none, so an unregistered systf cannot
        \\reach a simulation with no value behind it.
        \\
        \\WHY A HOST CALL AND NOT A SUBSTITUTE. Everywhere else a substitute
        \\value would contradict a number the LRM fixes, so the unit is
        \\refused outright (E0515, the filter families) rather than quietly
        \\made wrong. An unregistered systf has no such number: the language
        \\defines no value for it at all — §12.32.3's listing never even
        \\initializes sampler->value before the first update callback, and
        \\hands that field straight back through vpi_put_value(). So there
        \\is nothing to be wrong about, only somebody else to ask, and the
        \\artifact carries the question instead of inventing an answer.
        \\
        \\`vera --run` is itself a host and answers zero with zero partials,
        \\which is why a fixture over one of these asserts what does not
        \\depend on the value (§5.3.1: the block runs straight through).
        \\
        \\That is not a licence to be silent, which is what this warning is
        \\for: a misspelled `$abstmie` would otherwise become a binding the
        \\host is asked for. One warning per call site, naming the name.
        \\
        \\  --deny=W0852    refuse the unit instead (the old behaviour)
        \\  --allow=W0852   silence it for a model you know needs a host
        ,
    },
};
