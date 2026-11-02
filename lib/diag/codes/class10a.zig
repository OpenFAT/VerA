//! The diagnostic catalogue's class 10 rows, runtime and the artifact contract, part a:
//! `W0950` .. `W1160`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    .W0950 = .{
        .title = "multiple discipline resolution rules match",
        .lrm = "7.7.2.1",
        .explain = "The first matching rule is used. Exact matches take precedence over subset matches. Remove the ambiguity to silence this warning.",
    },
    .E0952 = .{
        .title = "a SPICE model names a primitive VerA does not support",
        .lrm = "E.1.2",
        .explain =
        \\E.1.2: "Not all SPICE simulators support the same set of component
        \\primitives. Thus, a particular SPICE netlist can reference a
        \\primitive which is unsupported. Verilog-AMS HDL offers no
        \\alternative in this case other than the possibility that if the
        \\model equations are known, the primitive can be rewritten as a
        \\module."
        \\
        \\A `.MODEL name type` card declares `name` as a model of the SPICE
        \\primitive `type`. VerA reads the types Table E.1 names (r, c, l,
        \\d, npn, pnp, nmos, pmos, njf, pjf, nmf, pmf); any other (`sw`,
        \\`csw`, `ltra`, `urc`, ...) declares no module, and an instance of
        \\the model is this error, at the instance.
        \\
        \\As the clause says, write the primitive's equations as a
        \\Verilog-AMS module of the same name: E.3.3 then selects the module.
        ,
    },
    .E0953 = .{
        .title = "a SPICE device card's model is a primitive with no behaviour",
        .lrm = "E.2",
        .explain =
        \\An M, Q, J or D card inside a `.SUBCKT` names a model, and the model
        \\is a `.MODEL` card of a Table E.1 type: nmos, pmos, npn, pnp, d,
        \\njf, pjf, nmf or pmf. Table E.1 leaves the Behavior column of those
        \\rows (mosfet, bjt, diode, jfet, mesfet) empty, and E.2 says "all
        \\aspects of SPICE primitives are implementation dependent". VerA has
        \\no equations for them, so the card would be a device that conducts
        \\nothing: an open where the netlist has a transistor. It is refused
        \\at the card instead.
        \\
        \\E.1.2 gives the remedy: "if the model equations are known, the
        \\primitive can be rewritten as a module". Give the model as a
        \\Verilog-A module and name the module as the `.MODEL`'s type:
        \\
        \\    .MODEL NCH BSIMCMG TYPE=1 ...     (with BSIMCMG compiled in,
        \\                                       e.g. `.HDL "bsimcmg.va"`)
        \\
        \\or name the module (or a paramset) on the card itself. HSPICE's
        \\`.MODEL NCH NMOS LEVEL=72` is this error: LEVEL selects an HSPICE
        \\built-in, which a Verilog-AMS compiler does not have.
        ,
    },
    .W0951 = .{
        .title = "a Verilog-AMS definition shadows a SPICE model or subcircuit",
        .lrm = "E.3.3",
        .explain =
        \\A Verilog-AMS module or paramset takes precedence over a SPICE
        \\model or subcircuit with the same name. E.3.3 requires this
        \\warning so the selected definition is explicit. Rename one
        \\definition to make both available under distinct names.
        \\
        \\Shadowing an always-available Table E.1 primitive permits an
        \\optional warning; VerA does not warn for that case. Names that
        \\differ in case retain E.2.1's case-sensitive HDL lookup followed
        \\by case-insensitive SPICE lookup.
        ,
    },
    .E1001 = .{
        .title = "source contains no module declaration",
        .lrm = "6.2",
        .explain =
        \\A compilation unit must declare at least one `module`. If the
        \\file holds only `discipline`, `nature` or `` `define `` items, it
        \\is a header — include it from a module instead of compiling it.
        \\
        \\If the file DOES contain a design element, it is one that is not a
        \\device. `primitive` and `library` have no parser at all, and the
        \\earlier diagnostics name which one. A `connectmodule` parses and is
        \\accepted (LRM 7.6, A.1.2's third `module_keyword`) but is still not
        \\a device: LRM 7.6 makes it the bridge the connect module INSERTION
        \\PHASE places on a mixed net, so it is instantiated by the tool and
        \\never elaborated on its own. A `connectrules` block (LRM 7.7)
        \\parses too, and is configuration for that same phase — a source of
        \\connect modules and connect rules alone still has no device. Put
        \\the module that uses them in the same compilation.
        \\
        \\A `paramset` is NOT one of them any more (LRM 6.4), but it is not a
        \\module either: it is a bundle of parameter values FOR a module, so a
        \\file of paramsets alone still has no device to compile. Compile the
        \\file that declares the module and instantiate the paramset from it.
        ,
    },
    .E1002 = retiredInfo(
        \\"generated identifier is too long". Retired: the condition is
        \\real — code generation builds a structural key per unit from the
        \\module name, the role and the target, and a key can overflow the
        \\fixed name buffer (never truncated: truncation would break the
        \\injectivity two distinct units rely on) — but no diagnostic with
        \\this code is ever built. The refusal was codegen's
        \\error.NameTooLong, past an 8192-byte name buffer. Since #29 every
        \\name buffer is sized from the name itself (LRM 2.8 lets an
        \\implementation set no limit, VD-054), so no length is refused. A
        \\catalogue entry for a code that never renders only misleads
        \\`--explain`.
        \\
        \\If codegen ever reports the overflow through the bag, with a
        \\source location, that report takes a NEW number. This one is not
        \\reused.
    ),
    .E1003 = retiredInfo(
        \\"more solver unknowns than the device contract can hold". Retired
        \\(#29): the emitted `U` was an `enum(u8)`, so a device held at most
        \\256 unknowns, below the 256 ports LRM 6.5.2.2 requires an
        \\implementation to accept before its internal nodes. `U` is now an
        \\`enum(u8)` up to 256 unknowns and as wide as the count needs past
        \\them; `lib/contract.zig` takes any unsigned tag of 8 bits or more.
        \\This code is not reused.
    ),
    .E1100 = .{
        .title = "digital source execution failed",
        .lrm = "8.5",
        .explain = "The digital executor supports a documented subset of source processes. Unsupported forms are diagnosed before simulation; timing and capacity failures stop execution explicitly. This does not make legal unsupported Verilog-AMS forms illegal.",
    },
    // IEEE 1364-2005 §17.2.10: an SDF file `$sdf_annotate` cannot read.
    .E1102 = .{
        .title = "an SDF file the annotator cannot read",
        .lrm = "IEEE 1364-2005 17.2.10",
        .explain =
        \\$sdf_annotate (IEEE 1364-2005 17.2.10) reads timing data from an
        \\SDF file into the design: clause 16's mapping of IOPATH,
        \\INTERCONNECT, LABEL, TIMINGCHECK and PATHPULSE onto the module
        \\paths, ports, specparams and timing checks of the instances the
        \\file's CELLs name. The file could not be opened or read, its
        \\parentheses do not balance, it is not one (DELAYFILE ...), or its
        \\TIMESCALE or DIVIDER is malformed. The run stops: carrying on
        \\would simulate a design whose timing the file was meant to set.
        \\
        \\The file is looked for beside the source that names it, then in
        \\the working directory, as a $readmemh file is.
        ,
    },
    // IEEE 1364-2005 §16: an SDF construct the annotator does not apply.
    .W1105 = .{
        .title = "an SDF construct the annotator does not apply",
        .lrm = "IEEE 1364-2005 16.2",
        .explain =
        \\The SDF file holds a construct `vera --run`'s annotator does not
        \\apply, or one that names nothing in the design: a COND, PORT or
        \\DEVICE delay, a skew or no-change check, an INSTANCE no instance
        \\below the annotation scope has, an IOPATH no module path of the
        \\instance matches, a malformed value. That construct is skipped
        \\and the rest of the file is applied. The message gives the file
        \\and line.
        ,
    },
    // IEEE 1364-2005 §15: a timing check argument the digital engine
    // cannot bind (a notifier that is no variable, an event terminal that
    // is no whole or constant-select vector).
    .E1147 = .{
        .title = "a timing check argument the digital engine cannot bind",
        .lrm = "IEEE 1364-2005 15.5",
        .explain =
        \\`vera --run` evaluates a module's timing checks against the
        \\signals their events name and toggles the notifier a violation
        \\updates. It refuses a check whose arguments it cannot bind:
        \\
        \\  - a notifier that is not a variable. 15.5: "The notifier is a
        \\    reg, declared in the module where timing check tasks are
        \\    invoked", and A.7.5.2 `notifier ::= variable_identifier`. A
        \\    net, a real, a parameter or an array has no reg value for
        \\    Table 15-13 to toggle;
        \\  - an event terminal that is not a name, or a constant bit- or
        \\    part-select of at most 64 bits of a vector (A.7.3
        \\    `specify_input_terminal_descriptor ::= input_identifier
        \\    [ [ constant_range_expression ] ]`), or that names a real or
        \\    an array.
        \\
        \\Name a reg as the notifier, and a port (or a constant select of
        \\one) as each event.
        ,
    },
    // IEEE 1364-2005 Tables 15-1..15-11: a limit or threshold that is not
    // a non-negative constant expression.
    .E1148 = .{
        .title = "a timing check limit that is not a non-negative constant",
        .lrm = "IEEE 1364-2005 15.1",
        .explain =
        \\15.1: "Like expressions for module path delays, timing check limit
        \\values are constant expressions that can include specparams", and
        \\Tables 15-1, 15-2, 15-4, 15-5, 15-10 and 15-11 give the limit of
        \\$setup, $hold, $removal, $recovery, $width and $period, and
        \\$width's threshold, as a "Non-negative constant expression".
        \\A limit that reads a signal, or one of those six below zero, is
        \\refused. $setuphold and $recrem take negative limits (15.8),
        \\which VerA, without a negative timing check option, takes as 0
        \\(15.5.4).
        ,
    },
    // IEEE 1364-2005 §15: a timing check form the digital engine does not
    // evaluate, refused by name.
    .E1149 = .{
        .title = "a timing check VerA's digital engine does not evaluate",
        .lrm = "IEEE 1364-2005 15",
        .explain =
        \\`vera --run` evaluates all twelve commands (IEEE 1364-2005 15.2,
        \\15.3), their notifiers (15.5), conditioned events (15.6) and
        \\vector signals (15.7), a negative $setuphold or $recrem limit as
        \\0 (15.5.4: VerA has no negative timing check option). It does not
        \\evaluate, and so refuses rather than run a design whose checks
        \\would silently misjudge:
        \\
        \\  - a $setuphold or $recrem stamptime or checktime condition
        \\    (15.5.2), which exists for negative checks;
        \\  - a negative end edge offset of $nochange (15.3.6), a window
        \\    ending before its trailing reference edge.
        \\
        \\The analog solver never evaluates a timing check (W0251).
        ,
    },
    .E1101 = .{
        .title = "design refused under --two-state",
        .lrm = "IEEE 1364-2005 4.1",
        .explain =
        \\`vera --emit-exe --two-state` builds a native executable in which
        \\every x or z the design would create is 0: an uninitialised
        \\variable, an undriven net, an x or z literal bit, an out-of-range
        \\select, a division by zero. That is not the 4-state logic of IEEE
        \\1364-2005 §3.2 and §4.1, and its output differs wherever an x or z
        \\would have arisen.
        \\
        \\A design is refused where an x or z carries meaning, which a run
        \\without them cannot keep: `===` or `!==` against an x or z, a `case`
        \\label with an x or z bit, `$sscanf` (an x or z in its input is EOF,
        \\IEEE 1364-2005 §17.2.4.3), a §17.5.4 plane PLA (a z personality bit
        \\ignores its input), a §7.9 net resolved from strengths or several
        \\drivers or driven by a three-state, switch, UDP or pull driver, and
        \\any design the native code generator does not compile, which runs
        \\only in the 4-state interpreter. Drop `--two-state` to run it with
        \\4-state logic.
        ,
    },
    // A `.v` design that cannot be a contract device.
    .E1103 = .{
        .title = "design cannot be a contract device",
        .lrm = "7.8",
        .explain =
        \\`vera --emit-zig`, `--check` and `--emit-so` of a `.v` design build a
        \\contract device an analog host loads: every bit of the top module's
        \\ports is a pin, an `input` bit sensed through an analog-to-digital
        \\bridge and an `output` bit driven through a digital-to-analog one, the
        \\connect modules LRM 7.8 inserts where a digital port meets an
        \\electrical net. The design's processes run natively inside the
        \\device, which saves and restores their state at every tick so a host
        \\can reject a time step.
        \\
        \\The message names what the device cannot hold: an `inout` port (the
        \\analog side would be a driver of a resolved net), a real, integer or
        \\time port, more than 65535 pins (a contract mask is one integer, a bit
        \\per pin, and Zig's widest is u65535), a construct the native code generator
        \\does not compile, a file a device would read, a procedural continuous
        \\assignment, or a logic mode other than 4-state (`--state=4`, the
        \\default for a device; `--state=auto` reruns a design from time 0,
        \\which a host that owns time cannot allow). `vera --run` and
        \\`--emit-exe` still run such a design on its own.
        ,
    },
    // A SystemVerilog source.
    .E1104 = .{
        .title = "a SystemVerilog source is not supported",
        .lrm = "",
        .explain =
        \\A `.sv` file is SystemVerilog (IEEE 1800), a different language from
        \\the IEEE 1364-2005 Verilog and Verilog-AMS VerA compiles. Its
        \\constructs (`always_ff`, `logic`, `interface` and the rest) would
        \\otherwise surface as misleading Verilog parse errors, so the file is
        \\refused by its extension. Write the design in IEEE 1364-2005 Verilog
        \\and name it `.v`.
        ,
    },
    .W1150 = .{
        .title = "memory file word count mismatch",
        .lrm = "IEEE 1364-2005 17.2.9",
        .explain = "Without address specifications in the memory file, a data-word count different from the requested load range requires a warning. Available words are loaded within the range; missing words leave existing memory contents unchanged. This warning does not refuse the load.",
    },
    .W1151 = .{
        .title = "probabilistic distribution argument not positive",
        .lrm = "IEEE 1364-2005 17.9.2",
        .explain = "The mean of $dist_exponential, $dist_poisson and $dist_erlang, the degree of freedom of $dist_chi_square and $dist_t, and the k_stage of $dist_erlang shall be greater than 0. The 17.9.3 reference listing prints a warning for such a call and returns 0 without drawing, so the seed argument is not written.",
    },
    .W1152 = .{
        .title = "two cells with one name in one library",
        .lrm = "IEEE 1364-2005 13.2.1.1",
        .explain =
        \\IEEE 1364-2005 13.2.1.1: "If multiple cells with the same name map
        \\to the same library, then the LAST cell encountered shall be
        \\written to the library. ... In the case where multiple modules
        \\with the same name are mapped to the same library in a single
        \\invocation of the compiler, then a warning message shall be
        \\issued." This is that warning; the later definition is the one
        \\every instance binds.
        ,
    },
    .W1153 = .{
        .title = "format specifiers and arguments do not pair up",
        .lrm = "IEEE 1364-2005 17.2.3",
        .explain = "The arguments after $sformat's format are consumed by its format specifiers. If not enough arguments are supplied for the specifiers, or too many are supplied, the application shall issue a warning and continue execution: the variable receives the text formatted so far.",
    },
    .W1154 = .{
        .title = "file output not written",
        .lrm = "IEEE 1364-2005 17.2.1",
        .explain = "$fclose closes the channels a descriptor names and does not allow any further output to them. A $fdisplay or $fwrite whose descriptor names only closed channels, or a file opened only for reading, writes nothing; $ferror reports the error. The simulation continues.",
    },
    // A `.v` device whose digital tick is 1 s.
    .W1155 = .{
        .title = "device digital tick is 1 s",
        .lrm = "IEEE 1364-2005 19.8",
        .explain = "A design with no `timescale directive runs at the simulator's default time unit and precision, which for VerA is 1 s. A contract device built from it delivers every analog-to-digital event at a whole second and schedules every delay in seconds, which an analog host rarely means. Add a `timescale directive (for example `timescale 1ns/1ps) to the design.",
    },
    // A `$readmem` file address outside the memory, with no bounds given.
    .W1156 = .{
        .title = "memory file address outside the memory",
        .lrm = "IEEE 1364-2005 17.2.9",
        .explain = "A `$readmemb`/`$readmemh` call with no start or finish argument met an `@` address outside the memory's declared range. The clause's error for an address outside the load range applies only when the task gives addresses, so VerA does not stop the load: the words at addresses outside the memory are skipped, and loading continues at the next in-range address. The warning names the first such address (specification/Vague_Decisions.md VD-040).",
    },
    // IEEE 1364-2005 §17.2.9: a `$readmem` load that cannot go on (a file
    // address outside the task's range, a malformed word or address, a
    // file that cannot be read, a bound outside the memory); the load is
    // terminated, the run goes on.
    .W1157 = .{
        .title = "a $readmem load terminated",
        .lrm = "IEEE 1364-2005 17.2.9",
        .explain = "A `$readmemb`/`$readmemh` load could not go on: a file address outside the start..finish range the task gives (§17.2.9: \"an error message is issued, and the load operation is terminated\"), a word or `@` address that is not a number in the task's radix (the file \"shall contain only\" white space, comments and such numbers), a file that cannot be opened or read, a file name with an x or z bit, a start or finish address that is x, z or outside the memory. VerA issues this message and stops that load: the words loaded before it stay, none after it is loaded, and the simulation goes on. The run's exit status is untouched, as iverilog's is (specification/Vague_Decisions.md VD-134). With no start or finish argument an address outside the memory is W1156 instead.",
    },
    // IEEE 1364-2005 §15.5.1: negative timing check limits no delayed
    // signals can meet; the most negative one is set to 0.
    .W1162 = .{
        .title = "negative timing check limits that cannot all be met",
        .lrm = "IEEE 1364-2005 15.5.1",
        .explain = "With --negative-timing, $setuphold and $recrem take negative limits through delayed copies of their signals, one delay per signal per instance, chosen so every adjusted limit is non-negative. A set of limits whose windows contradict each other (a setup and hold summing below zero around a cycle of signals) has no such delays. §15.5.1: \"the problem shall be resolved by changing the smallest negative limit value to 0\"; VerA does that, warns once per change, and solves again.",
    },
    // IEEE 1364-2005 §12.2.2.1: more ordered parameter values than the
    // module has parameters; the extra ones are ignored.
    .W1161 = .{
        .title = "extra ordered parameter values ignored",
        .lrm = "IEEE 1364-2005 12.2.2.1",
        .explain = "A module instance's parameter value assignment by ordered list gives more values than the module has parameters (local parameters are not in the list). §12.2.2.1 says what the list's order follows and that it may be shorter, not what a longer one means; VerA ignores the values past the last parameter and warns, as iverilog does (specification/Vague_Decisions.md VD-139).",
    },
    .W1160 = .{
        .title = "dissimilar net types joined through a port",
        .lrm = "IEEE 1364-2005 12.3.10",
        .explain =
        \\IEEE 1364-2005 Table 12-1 gives, for each pair of internal (the
        \\module's) and external (the instantiation's) net types joined by a
        \\port, the net type that dominates, and marks some pairs "warn = A
        \\warning shall be issued": two wired-logic types that disagree
        \\(wand with wor), a pull or charge-storage net meeting another, a
        \\uwire meeting a resolved net, supply0 meeting supply1. VerA joins
        \\the two into the external net and issues this warning.
        ,
    },
};
