//! The diagnostic catalogue's class 10 rows, runtime and the artifact contract, part b:
//! `W1199` .. `W1051`, each code's `Info` keyed by its `Code` field
//! name. `code.zig` gathers every class's rows into its table and fails the
//! build on a code without a row or a row for no code. Each row cites its own
//! clause in `.lrm`.
//!
//! Contents:
//! - `pub const rows`

const retiredInfo = @import("../code.zig").retiredInfo;

pub const rows = .{
    // IEEE 1364-2005 §15: a timing check reported a violation at run time.
    .W1199 = .{
        .title = "timing violation",
        .lrm = "IEEE 1364-2005 15.2",
        .explain =
        \\A timing check of the design detected a violation while `vera
        \\--run` ran it: 15.2's stability window ($setup, $hold, $setuphold,
        \\$removal, $recovery, $recrem) held a transition it forbids, or
        \\15.3.4's $width or 15.3.5's $period measured a pulse or a period
        \\shorter than its limit. The warning is at the check, naming the
        \\instance and the times of its timestamp and timecheck events in
        \\the instance's time unit (specification/Vague_Decisions.md VD-105). Like
        \\every diagnostic it is reported once per site, so it is the
        \\check's FIRST violation; each later one still toggles the
        \\check's notifier as Table 15-13 says (VD-103) and runs a VPI
        \\application's cbTchkViolation callbacks. The run goes on: a
        \\violation is the design's report, not an error of the
        \\simulator's.
        \\
        \\  --allow=W1199    silence the reports (the notifier still toggles)
        ,
    },
    .E1004 = .{
        .title = "unsupported dependent parameter expression",
        .lrm = "6.3.4",
        .explain =
        \\A dependent parameter must follow the final values of the parameters
        \\it references. VerA cannot yet render this expression for the host's
        \\derive callback, so retaining its declared-default value would be wrong.
        \\
        \\Pure two-way conditional expressions and short-circuit logical
        \\operators are supported. Arbitrary constant-function control flow,
        \\loop-carried or multiway values, unsupported operators and expressions
        \\beyond the renderer's recursion limit remain implementation gaps.
        ,
    },
    .E1010 = retiredInfo(
        \\"a display or format call has more than 32 conversions". Retired:
        \\a call with more operands than one Zig format call takes (32) is
        \\now emitted as consecutive calls of at most 32 each, so LRM 9.4.1's
        \\argument list has no bound and the condition does not exist to
        \\report (#29). The number is not reused.
    ),
    .E1011 = .{
        .title = "text exceeds the buffer sized for it",
        .lrm = "",
        .explain =
        \\An engine limit on what a model computes while it runs, not a
        \\language rule. A device has no allocator, so every string it builds
        \\while it runs lives in a row the compiler sized when the model
        \\compiled: each `$sformat`, `$swrite`, file-output, `$monitor` or
        \\string-concatenation site, and each held (LRM 5.10) string. The
        \\size is the longest text the model can put there: the format's own
        \\text, each conversion's widest rendering at its written width and
        \\precision, and each string operand's own size, never below 4096
        \\bytes. No field width, precision, replication or concatenation the
        \\source writes is refused.
        \\
        \\What the compiler cannot know is a string's length that only the
        \\run decides: a string parameter the card sets, a `$fgets` line, a
        \\`$value$plusargs` value, an array element, a width spelled in a
        \\run-time format string, or a held string that grows by itself every
        \\step. Each counts 4096 bytes. Text that outgrows its row ends the
        \\run with this code and exit status 1: LRM 9.5.3 gives no truncation
        \\rule, so a cut or empty string would be a wrong value, not a
        \\shorter right one. A line read from a file has no row of its own;
        \\it grows to fit, and only running out of memory reports this code.
        \\
        \\Format such a string with a literal format, whose widths the
        \\compiler reads, or split the text over several calls: two `$fwrite`
        \\calls to one descriptor write the same bytes as one.
        ,
    },
    .E1012 = retiredInfo(
        \\"absdelay needs a sample older than its history holds". Retired:
        \\a full absdelay ring now thins its older samples instead of
        \\dropping them, so the window (maxdelay, or td) is always covered
        \\and no lookback runs past the history (W1051 reports the first
        \\thinning) (#29). The number is not reused.
    ),
    .E1013 = .{
        .title = "a file is larger than VerA reads",
        .lrm = "",
        .explain =
        \\A source file named on the command line, an `include file (LRM
        \\10.3), a `--spice` netlist or a file its `.INCLUDE` or `.LIB`
        \\card names holds more than 2^32 - 1 bytes. Every later stage
        \\locates a token by a 32-bit offset into the text, so this is a
        \\bound of VerA's representation, not a language rule. A regular
        \\file is refused from its size before it is read; a stream with
        \\no size (a pipe) is read until it passes the bound.
        \\
        \\The data file of a `$table_model` (LRM 9.21) or `noise_table`
        \\(LRM 4.6.4.3) call has no bound but memory. Until 2026-10 the
        \\bounds were 16 MiB (`include and data files) and 64 MiB (the
        \\source and a netlist).
        ,
    },
    .E1014 = .{
        .title = "a system function name VerA reserves",
        .lrm = "",
        .explain =
        \\An engine limit, not a language rule. LRM 2.8.3 lets any `$` name
        \\be a user system function, but VerA spells some of its own
        \\internal calls as `$` names (`$held_real`, `$idx`, `$limit$old`,
        \\`$str$cat`, the `$rng$` family and a few more), and a source call
        \\with one of those spellings would reach code that expects
        \\VerA's own arguments. The call is refused where it is written.
        \\
        \\Rename the system function; a VPI application can register it
        \\under any other `$` name.
        ,
    },
    .E1015 = .{
        .title = "more nets and unknowns than a 32-bit row index holds",
        .lrm = "",
        .explain =
        \\Not a language rule and not a design limit. VerA numbers a
        \\module's nets, ports, branch flows and analog operator states in
        \\one table with 32-bit rows, so a module holds up to 4294967294 of
        \\them and a vector range (LRM 3.6.3) as many elements. Each row
        \\costs lowering state of its own, so a module this size runs out
        \\of memory first; the code fires only on a range whose folded
        \\bounds alone pass the index space (`[0:5000000000]`). Until #29
        \\the rows were 16-bit and the bound was 65535.
        ,
    },
    .E1016 = .{
        .title = "an array or assignment pattern has more elements than a 32-bit index holds",
        .lrm = "",
        .explain =
        \\Not a language rule and not a design limit. VerA indexes the
        \\elements of an analog-context array (LRM 3.2, 3.4.4) and of an
        \\assignment pattern (LRM 4.2.14) with 32 bits, so one holds up to
        \\4294967295 of them. Each element is at least a real of storage,
        \\so an array this size runs out of memory first; the code fires
        \\only on bounds whose product alone passes the index space
        \\(`real a[0:65535][0:65536]`). Until #29 the bound was 2^20.
        ,
    },
    .E1017 = retiredInfo(
        \\"a UDP has more than 64 inputs". Retired 2026-10: IEEE 1364-2005
        \\8.1.2 lets an implementation limit a UDP's inputs, and VerA no
        \\longer does; a table of any width parses and runs. The number
        \\is not reused.
    ),
    .E1018 = retiredInfo(
        \\"the instance tree is more than 64 instances deep". Retired: LRM
        \\6.2.2 bounds nothing about the depth of a finite instance tree,
        \\and VerA now elaborates any depth. A cycle, which no depth would
        \\finish, is still E0905, named module by module. The number is
        \\not reused.
    ),
    .E1019 = .{
        .title = "a number literal's size exceeds 4294967295 bits",
        .lrm = "",
        .explain =
        \\LRM 2.6.1 lets a based number give its size in bits and bounds
        \\nothing about it, and IEEE 1364-2005 4.3.1 asks a tool for
        \\vectors of at least 65536 bits. VerA carries every width as a
        \\32-bit unsigned count, so a size (or the width an unsized
        \\literal's digits need) of 2^32 bits or more cannot be
        \\represented. Any smaller size is taken; memory is the bound
        \\(a literal allocates two bits of value per bit of size).
        \\
        \\Until 2026-10 the bound was 2^24 bits.
        ,
    },
    .E1020 = .{
        .title = "the code generator met a call it cannot render",
        .lrm = "",
        .explain =
        \\A compiler defect, not a language rule. Every call that reaches
        \\code generation was checked by lowering, so a call codegen has no
        \\rendering for, or one whose arguments lowering left malformed, is
        \\an internal inconsistency. The device is refused rather than built
        \\with a placeholder 0 in that place.
        \\
        \\Report it with the source that produced it.
        ,
    },
    .E1021 = .{
        .title = "a call has more operands than its 24-bit count holds",
        .lrm = "",
        .explain =
        \\Not a language rule and not a design limit. VerA's IR stores a
        \\call's operand count in 24 bits, so one call takes up to 16777215
        \\operands. An array or assignment pattern passed to a call
        \\(`laplace_nd`'s coefficients, `$table_model`'s data, a
        \\`noise_table`) is one operand per element, so a pattern like
        \\`'{16777216{1.0}}` there passes the count. Split the data, or
        \\compute it with fewer elements.
        ,
    },
    .E1022 = .{
        .title = "a device has more `$fatal` and `$error` sites than its status code holds",
        .lrm = "",
        .explain =
        \\Not a language rule and not a design limit. A device reports the
        \\first §9.7.3 `$fatal` or `$error` its evaluation reaches as one
        \\32-bit status code (`contract.statusCode`): the severity in the top
        \\byte, the site's number in the low 24 bits. So one module's analog
        \\blocks hold up to 16777214 such calls, counting each one a loop or
        \\macro writes out. Fold repeated reports into one call whose
        \\arguments say which case it is.
        ,
    },
    // `--emit-osdi` of a device with `$vera_reject_step`: OSDI 0.4 has no
    // slot for a step-rejection request (VD-102).
    .E1099 = .{
        .title = "`--emit-osdi` cannot carry `$vera_reject_step`",
        .lrm = "",
        .explain =
        \\A limit of the OSDI 0.4 interface, not a language rule.
        \\`$vera_reject_step(t)` is VerA's task for asking the host to reject
        \\the transient step it just accepted and retry it ending at `t`
        \\(`contract.UpdateResult.request_reject_at`). An OSDI library has no
        \\return value or callback that carries such a request to the
        \\simulator, so the library would accept every step the device asked
        \\to reject. VerA refuses to build it rather than build a device that
        \\silently ignores the call.
        \\
        \\The same source builds for a host that has the slot: `--emit-so`,
        \\`--emit-exe` and `--run`. For an OSDI simulator, drop the call.
        ,
    },
    // `--emit-osdi` of a device whose §4.6.4.6 noise generator feeds two
    // rows: OSDI 0.4 reports them as independent sources (VD-102).
    .W1098 = .{
        .title = "`--emit-osdi` reports correlated noise rows as independent sources",
        .lrm = "4.6.4.6",
        .explain =
        \\LRM 4.6.4.6: "Perfectly correlated noise is generated by using the
        \\output of one noise function for more than one noise source." The
        \\device publishes such rows with one `source` id
        \\(`contract.NoiseGen.source`), and their cross-spectrum is the
        \\product of their coefficients times the generator's density.
        \\
        \\OSDI 0.4 describes a noise source by its node pair and its density
        \\alone: it has no slot for a correlation between two sources. The
        \\library therefore reports each row as its own independent source,
        \\and a noise analysis of it misses the cross term. DC, AC and
        \\transient analyses are unaffected.
        \\
        \\`--deny=W1098` refuses the build instead.
        ,
    },
    .W1050 = .{
        .title = "parameter default has no compile-time value",
        .lrm = "3.4.1",
        .explain =
        \\LRM 3.4.1 makes a parameter's default a `constant_expression`. This
        \\one is not: it reads a quantity only the simulator has, such as
        \\9.10's `$temperature` or 9.18's `$simparam`. There is nothing to
        \\fold, so the generated `Model` field initializer is 0.
        \\
        \\That is not always wrong — the host writes the model card and can
        \\put the real value in the field before the first solve. It IS
        \\wrong if you expected `Model{}` alone to be usable, because a
        \\temperature of 0 K or a gmin of 0 will not converge.
        \\
        \\A default that is an arithmetic expression over OTHER parameters
        \\does not reach here: 6.3.4 makes it a `derive()` line, and calling
        \\`derive` after writing the card gives it its value.
        \\
        \\Fix it by giving the parameter a constant default and reading the
        \\simulator quantity in the analog block instead, where 9.10 and
        \\9.18 say it is evaluated. Or take the field as the host's to
        \\write, and `--allow=W1050`.
        ,
    },
    // §9.17.3 a `$limit` site the device does not honour: the probe is
    // returned unchanged, which the clause permits.
    .W0853 = .{
        .title = "$limit is not applied at this call",
        .lrm = "9.17.3",
        .explain =
        \\LRM 9.17.3 leaves limiting to the simulator: "In all cases, the
        \\simulator is responsible for determining if limiting should be
        \\applied ... In particular, the simulator may simply choose to have
        \\$limit() return the value of its first argument". So the source
        \\is legal and compiles; this call returns its probe unchanged, and
        \\Newton runs on it without the clamp you asked for.
        \\
        \\VerA's clamps are applied by the host to the node voltages
        \\between the linear solve and the next evaluation, which is what
        \\decides the calls it can honour:
        \\
        \\  - the string names an algorithm VerA implements: pnjlim, fetlim,
        \\    limvds, fetlimds, pnjlimds, steplim. An unknown name, or none,
        \\    leaves the choice to the simulator "just as if no string had
        \\    been supplied", and VerA's choice is none;
        \\  - the first argument is a potential probe V(a) or V(a,b): there
        \\    must be a node to correct. A flow has none (`type*V(a,b)` is
        \\    not an access function reference at all: E0891);
        \\  - the call is not under an `if`: the clamp list has no control
        \\    flow. A polarity guard is the trailing sign argument instead,
        \\    `$limit(V(b,e), "pnjlim", vte, vcrit, type)`;
        \\  - at least one net is internal: the host never moves a port,
        \\    because other devices share it. A junction straight across
        \\    two ports (no series resistance) has nothing to correct. A
        \\    pnjlimds rung is the exception: it writes its bulk, port or not;
        \\  - the arguments the algorithm takes are present and real;
        \\  - a `fetlimds` site is one of two on the same gate, with a
        \\    `limvds` across the two internal channel nodes; a `pnjlimds`
        \\    site is one of two on the same bulk, with a `limvds` across
        \\    their two channel nodes.
        \\
        \\The help line under the warning names the change for this call.
        \\Silence it for a model that converges without the clamp with
        \\`--allow=W0853`.
        ,
    },
    // A `$limit` seed on a branch `seed` does not start: named, never
    // silently dropped.
    .W0854 = .{
        .title = "$limit seed is not applied here",
        .lrm = "9.17.3",
        .explain =
        \\A `$limit` seed argument starts that site's BRANCH at a value (SPICE's
        \\MODEINITJCT, mos1load.c:397-408), and the host's limited image
        \\holds NODE values. So the seeded branches are solved into nodes as
        \\a tree: each group of connected nets has one root at 0 V (ground,
        \\else its lowest port, else its lowest net), and every other net
        \\follows its branch. A seed that tree cannot take is dropped:
        \\
        \\  - its branch is the vgd leg of a fetlimds ladder or the vbd leg of
        \\    a pnjlimds rung, which is derived through vds;
        \\  - an earlier site already seeds the same pair of nets;
        \\  - it closes a loop: the other branches already fix both its nets.
        \\
        \\A junction with no seed joins the tree at its vcrit.
        ,
    },
    // LRM 4.5.7: an absdelay history ring that filled while its window was
    // still needed now keeps older samples at a coarser spacing.
    .W1051 = .{
        .title = "absdelay history thinned to cover its delay",
        .lrm = "4.5.7",
        .explain =
        \\LRM 4.5.7 defines absdelay over all past time, Output(t) =
        \\Input(max(t - td, 0)), and states no history rule. A device has
        \\no allocator, so each absdelay site keeps its accepted samples in
        \\a fixed ring inside `Instance`: ceil(maxdelay / 1ps) + 2 samples
        \\when maxdelay folds, clamped to [1024, 16384], else 1024.
        \\
        \\A ring whose oldest sample is still inside the window (maxdelay,
        \\or td when there is none) when it fills is thinned, not cut: the
        \\older half keeps every other sample, the newer half stays whole,
        \\and a lookback interpolates over what is left. The window is
        \\always covered, so the delay is never shortened; what changes is
        \\the resolution of the oldest part of the history. Each thinning
        \\doubles the spacing of the samples it touches. This warning prints
        \\once per site, the first time, with the widest spacing left.
        \\
        \\A run that never fills its ring answers exactly as before. To keep
        \\full resolution, give the call its maxdelay (absdelay(x, td,
        \\td_max)) or take fewer, larger steps across the delay.
        ,
    },
};
