# Vague decisions

Each entry below is a point where the Verilog-AMS LRM (`specification/*.html`,
`specification/VAMS-LRM-2023.pdf`) or IEEE 1364-2005 is vague, silent or contradicts
itself, and VerA has to choose a reading. Every entry records that choice,
marked `DECIDED`.

The items come from three places:

- `specification/Vague_Decisions.md` §6 and §3, for choices that had no recorded rationale;
- `specification/CLAUSE-AUDIT.md` §7.5 (open questions).

A citation with `at 8b1514d4` points to a removed audit note. Read it with
`git show 8b1514d4:<path>`.

Some items in §5.1 and §7.5 are house-rule questions rather than readings of a
standard. They are kept here so that every source item has an answer. Each one
says "not an LRM reading" in its **Rule** line.

How to read an entry:

- **Rule** quotes the clause. IEEE 1364-2005 is licensed, so it is quoted at
  most a sentence or two per entry.
- **Decision** is the reading VerA takes. It is grounded in the normative text,
  in the intent of other clauses, and in what VerA already does. A tool's
  behaviour is cited only where it is known; otherwise the entry says it was
  not established.
- **VerA today** describes the code and fixtures as read on 2026-10-04 at
  `3de6b009`. When the decision differs from the code or the documents, the
  entry says `CHANGE NEEDED` and gives the semver class from AGENTS.md §3:
  minor when source is newly accepted or refused or emitted device text
  changes, patch otherwise.
- **Measure impact** names the measures (A, B or C, AGENTS.md §2) the change
  would move. No count is given, because counts are measured, not typed.

As first written, this document changed no code and no fixture, and 51 of
its 90 entries needed a change. Those marked `yes (doc)` need only a document
correction. An entry that has since been implemented says `DONE` in the
summary and has a **Status** line naming what landed.

## Summary

| ID | Clause | Decision | Change needed |
|---|---|---|---|
| VD-001 | AGENTS.md §2, §6 (house rule) | A green fixture with teeth is an ordinary fixture; its header names the wrong implementation it catches | DONE (4ef087d6) |
| VD-002 | VAMS 9.21, Syntax 9-16, Table 9-32 | `";2"` is legal; a null head defaults every dimension, dependent = N + ignored + selector | no |
| VD-003 | AGENTS.md §6 (house rule); VAMS 9.17.2 | Delete invented quotes (done); ship the 9.17.2 smallest-bound fixture | DONE (70c42167) |
| VD-004 | AGENTS.md §0 rule 1 (house rule) | Re-measure figures that gate an assertion; delete prose-only ones | DONE (4ef087d6) |
| VD-005 | IEEE 1364-2005 17.10; VAMS 9.12 Table 9-9 | No 17.10-03 row; re-score 17.10-01/-02 on the existing digital fixtures | DONE (4ef087d6) |
| VD-006 | AGENTS.md §2 (house rule) | A passing `.v` transcript is runtime evidence and may support `verified` | DONE (4ef087d6) |
| VD-007 | VAMS 6.5.7, 7.8.4 rule 3 | A mixed port matching zero connect statements is a named error | DONE (8a719d2a) |
| VD-008 | VAMS 7.4.4, 7.4.4.2 | Basic is the testable normative default; detail mode is required, so its absence is `missing` | DONE (4735daab, detail mode: `segment.zig`) |
| VD-009 | IEEE 1364-2005 13.2.1.1 vs 4.11 | Last same-named module wins with W1152, in both the `.v` and `.va` paths | DONE (5258ed3f) |
| VD-010 | VAMS 5.6.1.3, A.6.5 | Contributions made before an event-triggered `disable` stand | DONE (ea6b1cb6) |
| VD-011 | VAMS 3.4.5, 6.3.3; IEEE 12.2.2.1 | `#(.lp())` on a localparam is E0907 | DONE (2df23aa8) |
| VD-012 | VAMS E.1.2 | Claim SPICE3 `.MODEL` + `.SUBCKT` bodies of R/C/L/V/I/E/F/G/H, model-naming M/Q/J/D (binned models by L and W) and X cards, `PARAMS:` with `{expr}` values over them, `.INCLUDE`/`.LIB`/`.HDL`; node 0 is ground; refuse unreadable body cards, `.PARAM`, nesting, unread expressions, an unbinnable card; E0953 for a behaviourless model | DONE (e7900531, aeb2b5cc; M/Q/J/D, PARAMS:, X, bins #9) |
| VD-013 | VAMS F.2.2, F.1 | Provide `--discipline-resolution=basic\|detail`; a folded pass is fine if results are equal | DONE (4735daab) |
| VD-014 | VAMS A.8.8; IEEE 1364-2005 3.6 | Accept bytes above 0x7F as opaque 8-bit characters, one byte each | DONE (9d434792) |
| VD-015 | VAMS 9.17.3, Syntax 9-12 | A non-access first argument is E0891 (already implemented) | DONE (4ef087d6) |
| VD-016 | project scope | `.v` contract device: implemented | no |
| VD-017 | VAMS 7.3.2; IEEE 1364-2005 17.1.1.4 | An x/z analog display operand is an error; fix E0130's explanation, add a fixture | DONE (73d3f9dd) |
| VD-018 | IEEE 1364-2005 17.2.9 | Excess `$readmem` data: warning, load continues (implemented, W1150) | DONE (4ef087d6) |
| VD-019 | CLAUSE-AUDIT §2 (house rule) | A parsed AST path is not `partial`; re-score AMS-06 on executing fixtures | DONE (4ef087d6) |
| VD-020 | AGENTS.md §2 (house rule) | A kernel unit test never carries `verified` alone | DONE (4ef087d6) |
| VD-021 | VAMS 2.7, A.8.8, G change 2535 | A string stays on one line; a raw newline or continuation is E0138 | no |
| VD-022 | VAMS 2.3, 2.7 Table 2-2 | A raw TAB in a string is legal and is byte 9 | no |
| VD-023 | VAMS 2.9.2 (`op`) | An absent `op` means included; only `"no"` excludes | no |
| VD-024 | VAMS 2.9 Syntax 2-4, A.9.1, Annex B | Only `units` is exempt as a keyword attribute name; other keywords are refused | DONE (8a677e04) |
| VD-025 | VAMS 3.4; IEEE 1364-2005 4.10.1 | "Previously defined" means textual order; a forward reference is E0314 | no |
| VD-026 | VAMS 4.3.1 Table 4-14 | `min`/`max` use the conditional form for value and derivative, folding included | DONE (107333b2) |
| VD-027 | VAMS 8.2 vs 8.4.1 | Nodeset vs `analog initial` order is unobservable; follow 8.2, assert neither | no |
| VD-028 | VAMS 5.10.3.3, 8.3.3 | An `@()` body's effects are committed once per accepted timepoint | no |
| VD-029 | VAMS 8.4.4 example; IEEE 1364-2005 9.2.2 | 9.2.2 governs; the "cancel" is the D2A's driver look-ahead | no |
| VD-030 | VAMS 9.16 | Run-time `$simprobe` names should resolve; until then, refuse by name, never fall back silently | DONE (b5689fbb) |
| VD-031 | VAMS 9.21, 9.21.1 | Refuse a duplicate abscissa only when the conflict is proven; otherwise check at capture | no |
| VD-032 | VAMS 3.7; IEEE 1364-2005 9.7.2, 6.1.2 | A real "change" is IEEE 754 `!=`; the new bits are still stored | DONE (0db0a690) |
| VD-033 | VAMS 3.7; IEEE 1364-2005 11.3 | `m04_01`'s time-0 read of a declaration-assigned wreal is a race; sample after `#0` | DONE (4b6c96d8) |
| VD-034 | VAMS 5.10 Syntax 5-13, 5.10.5, 7.3.6.2 | `posedge`/`negedge` on a continuous operand is E0704; use `cross` | no |
| VD-035 | VAMS 3.3 vs A.2.1.3/A.2.8 | A module-level `string` variable is legal (3.3 governs) | no |
| VD-036 | VAMS 2.7 Table 2-2; IEEE 1364-2005 3.6.3 | An undefined escape keeps the character and drops the backslash, with a named warning | DONE (dac6eb2b) |
| VD-037 | IEEE 1364-2005 5.5.4 | Signed x/z gives all-x for arithmetic and resizing only; bitwise and `?:` keep their bit tables | DONE (4b6c96d8) |
| VD-038 | IEEE 1364-2005 6.1.3, 4.3 | A 1-bit `[0:0]` LHS takes the scalar (gate) delay rule: width decides | DONE (4b6c96d8) |
| VD-039 | IEEE 1364-2005 13.2.2 vs A.1.1 | A `config` in a lib.map is refused (E0244); the prose beats the grammar superset | DONE (14cd4397) |
| VD-040 | IEEE 1364-2005 17.2.9 | File address outside the declared memory with no task bounds: named warning, words skipped | DONE (418338cf) |
| VD-041 | IEEE 1364-2005 17.2.9, 3.5.1 | Address: hex digits plus `_` after the first char (trailing included); x/z/? malformed | DONE (22fb2c50) |
| VD-042 | IEEE 1364-2005 18.4.3.2 | Strength 5..7 is the strong range by number; "(large)" is a slip | DONE (4b6c96d8) |
| VD-043 | IEEE 1364-2005 19.6, 19.11 | `` `resetall `` does not touch the `` `begin_keywords `` region | DONE (ead894ee) |
| VD-044 | IEEE 1364-2005 26.2.4 vs 27.34.2 / VAMS 12.33.2 | Startup routines may only register; VerA refuses other routines then; fixtures walk at cbEndOfCompile | DONE (9425251f) |
| VD-045 | IEEE 1364-2005 26.3.5 vs Annex G | `vpiIsProtected` = `vpiProtected` (10), FALSE on every object | DONE (2b569378) |
| VD-046 | IEEE 1364-2005 26.6.40(c) vs VAMS 11.6.25 note 5 | Current queue listed iff a pending event precedes read-only sync | DONE (65687d0f) |
| VD-047 | VAMS 11.6.25, 12.31.2 | A callback-only time is a vpiTimeQueue entry | no |
| VD-048 | VAMS 12.27 / IEEE 27.26 | `vpi_mcd_printf` returns one expansion's length, regardless of channel count | no |
| VD-049 | VAMS 12.16 / IEEE 27.14 | `vpiIntVal` of a wide object is its low 32 bits | DONE (94512505) |
| VD-050 | IEEE 1364-2005 17.6.5, 17.6.6 | Unknown `q_stat_code`: constant refused; run time gives status 2, value unchanged | DONE (99a70532) |
| VD-051 | IEEE 1364-2005 17.6.5 | Code 3 is the observed peak length | DONE (259c554a) |
| VD-052 | IEEE 1364-2005 17.6.5, 3.5.3 | Means are rounded to nearest (real-to-integer rule), not truncated | DONE (ca0e6529) |
| VD-053 | VAMS 2.7 | Octal escape above \377 is refused with a named error (the LRM permits it) | DONE (35e427ed) |
| VD-054 | VAMS 2.8 | No identifier length limit | no |
| VD-055 | VAMS 4.2.4 | Integer % by zero: E0601 at compile time if provable, runtime report or trap otherwise | no |
| VD-056 | VAMS 4.2.4 | Real % by a runtime zero reports E0601 like the integer path, not NaN | DONE (86e06853) |
| VD-057 | VAMS 4.5.4 | idt without ic: c from the feedback loop when the argument reads an unknown, else 0 (row rewording) | DONE (4ef087d6) |
| VD-058 | VAMS 4.5.5 | idtmod c = 0 is required by the prose; not implementation-defined | DONE (4ef087d6) |
| VD-059 | VAMS 4.5.5 | idtmod integrates inside the device, wrapped each accepted step | no |
| VD-060 | VAMS 4.5.7 | absdelay linear interpolation is required; vera_interp=2 is an extension | DONE (4ef087d6) |
| VD-061 | VAMS 4.5.11 | Pole at s = 0: DC value 0 (in-device state, no loop reading) | no |
| VD-062 | VAMS 4.5.11, 4.5.12 | Card root vectors pair at runtime (1e-9 rel.); an unpaired root gives NaN | no |
| VD-063 | VAMS 4.6.1 | No analysis names beyond Table 4-21; others are false, silently | no |
| VD-064 | VAMS 4.6.3 | The small-signal analysis is named "ac" | no |
| VD-065 | VAMS 5.10.3.1, 7.8 | .v device crossing ttol = card ttol, default min(trise,tfall)/50 | no |
| VD-066 | VAMS 5.10.3.1, 5.10.3.3 | Fixed-grid testbench fires at the next grid point with W0750 | no |
| VD-067 | VAMS 5.10.3.4 | absdelta defaults: time_tol 1 ps (at least the precision), expr_tol 1e-12 | no |
| VD-068 | VAMS 7.4.4 | Basic is the default; detail is selectable; see VD-008 | no |
| VD-069 | VAMS 9.5.7, IEEE 17.2.7 | $ferror returns fixed C errno values on every host | no |
| VD-070 | VAMS 9.7.2 | $stop in a batch run prints and exits 0 | no |
| VD-071 | VAMS 9.13.1 | Omitted seed: deterministic 1 + 7919k per site | no |
| VD-072 | VAMS 9.15 | gmin and sourceScaleFactor become host-written Model fields | DONE (d73ae0cc) |
| VD-073 | VAMS 9.17.3, E.3.4 | Six $limit built-ins; an unknown name returns the probe with W0853 | no |
| VD-074 | VAMS 9.17.3 | Extra $limit args: frame sign, then seed; more declines (W0853) | no |
| VD-075 | VAMS 12.36 | vpiRejectTransientStep = 730 | no |
| VD-076 | VAMS E.1, E.2 | SPICE flavour; see VD-012 | no |
| VD-077 | VAMS E.3.3 | No primitive-shadow warning; W0951 for model/subckt | DONE (no code change: W0951 verified) |
| VD-078 | VAMS 9.15 | Temperature per Model row; IMPLEMENTATION cite §9.10 -> §9.15 | DONE (4ef087d6) |
| VD-079 | VAMS 9.18, Table 9-29 | Card-time domain check for host-set hierarchical system parameters | DONE (76f344c7) |
| VD-080 | IEEE 1364-2005 8.1.2 | No UDP input limit (64 until 2026-10, E1017 retired) | DONE (#29) |
| VD-081 | IEEE 1364-2005 11.4.2 | Source-order FIFO active events; resume in suspend order; interpreter = native | no |
| VD-082 | IEEE 1364-2005 5.1.4, 11.4.2, 11.5, 12.3.10.x (CLAUSE-AUDIT §5.5) | Tagged fixtures assert only the permitted set; VerA's choice pinned untagged | DONE (4ef087d6) |
| VD-083 | IEEE 1364-2005 13.4.4, 13.3.2 | The config no `use` clause names sets the top; zero or several is E0243 | DONE (02af6a29) |
| VD-084 | IEEE 1364-2005 17.2.4.1 | 16-deep pushback, EOF past it; every read routine sees it | DONE (78df5df4) |
| VD-085 | IEEE 1364-2005 17.2.1, 27.25; VAMS 12.24, 12.27 | Lowest free mcd bit from 1; from channel 4 under VPI, one shared table | no |
| VD-086 | IEEE 1364-2005 17.9.1 | One hidden per-run seed from 0 for seedless digital `$random` | no |
| VD-087 | IEEE 1364-2005 19.8 | No `timescale: 1 s / 1 s | no |
| VD-088 | IEEE 1364-2005 5.2.2, 4.8.2 | Invalid real-array read gives +0.0 | no |
| VD-089 | IEEE 1364-2005 17.11.1, 4.10.1; VAMS 9.14 | Host number is an unsized integer for `$clog2` unless a range/type fixes width | DONE (55e391ea) |
| VD-090 | VAMS 9.18, 6.3.6, 3.4.7 | Top-level system parameter values via a top `aliasparam` card slot | no |
| VD-091 | VAMS 10.1; IEEE 1364-2005 19.5 | A relative `` `include `` name is looked for beside the including file, then on `-I`, then among the annex D built-ins | DONE (dfd7e836) |
| VD-092 | VAMS 7.8.1 Figure 7-6, 7.8.4 | Case 2 detail-merged: the §7.8.4 merge rule (two connect modules) governs over the figure's "three" | DONE (#23) |
| VD-093 | VAMS 10.1, Annex D; IEEE 1364-2005 19.5 | `discipline.h` and `constants.h` (the OVI Verilog-A 1.0 names) are built-in aliases of D.1 and D.2 | DONE (#4) |
| VD-094 | VAMS 9.4.1, 9.4.6, 9.5.9 | A device's `$display`/`$write` output belongs to the accepted point, as `$strobe`'s: one `say` per accepted point records all of them (#10); `$debug` and `$fdebug` run per iteration (`contract.SayPass`) | DONE (#10, #29) |
| VD-095 | VAMS 9.21.1, 9.3 | A table capture stays with the instance only once an accepted iteration made it; a rejected step's capture is undone (#18) | DONE (#18) |
| VD-096 | VAMS 3.13.2, 3.13.1, Annex D | The preloaded Annex D natures take part in "the access function of each base nature shall be unique" only when the source includes `disciplines.vams` (or `discipline.h`) | DONE (2026-10-08) |
| VD-097 | VAMS 9.11; IEEE 1364-2005 17.8 | `$realtobits` is an integer pattern with no derivative; its round trip stays `fd-exempt` | no |
| VD-098 | VAMS 12.31.3, 12.8; 4.6.1 Tables 4-21/4-22 | An AC sweep under VPI: its operating point is acbInitialStep at frequency 0, each frequency an acbAcceptedPoint, the last also acbFinalStep; the operating point evaluates as `static` | DONE (#20) |
| VD-099 | IEEE 1364-2005 5.3; VAMS A.8.3, A.8.4 | A min:typ:max expression takes its typical member, in the analog and the digital compile alike; an analog_expression has none (E0295) | DONE (2026-10-08) |
| VD-100 | VAMS 2.9.2, 3.2.1, 3.4.3, 3.6.3.1 | `desc`/`units` reach a host as the optional `decl_meta` table: the device module's own module-scope parameters, variables and nets; a net row has no `units` | DONE (#15) |
| VD-101 | VAMS 9.4.1, 9.4.3, 9.4.5 | A null argument a format conversion consumes: `%s` prints its one space; any other conversion is E0819 | DONE (2026-10-08) |
| VD-102 | OSDI 0.4 (house rule); VAMS 3.2.1, 4.6.4.6 | Under `--emit-osdi`: `$vera_reject_step` is E1099; a shared noise generator is W1098 (independent sources); opvars, acceptance and display are documented gaps | DONE (#24) |
| VD-103 | IEEE 1364-2005 15.5 Table 15-13 | A notifier at x takes 1 on a violation; a vector notifier toggles bit by bit, each bit by the table | DONE (2026-10-08) |
| VD-104 | IEEE 1364-2005 15.1-15.7 | A timing check is judged at its timecheck event, in event order; a reference and a data event at one time are one pair, judged once whichever comes first; a vector edge reads its least significant bit; a condition is read at its event, and $width's and $period's derived data event carries the reference event's | DONE (2026-10-08) |
| VD-105 | IEEE 1364-2005 15.2, 15.3 | A check's first violation is reported as a W1199 warning naming the check, the instance and the times of its timestamp and timecheck events in the instance's time unit, not as transcript text; later violations of the same check toggle its notifier and call cbTchkViolation with no second warning | DONE (2026-10-08) |
| VD-106 | IEEE 1364-2005 C.7; VAMS 12.36 | vpiReset re-elaborates the digital run in place: time 0, every reg and net at its initial value, every scheduled event gone; registered callbacks, value-change watches and put delays and limits stand; stop_value 0 ends a batch run; reset_value and the diagnostic level are not read | DONE (2026-10-08) |
| VD-107 | VAMS 2.7, 3.3, 5.10.3.1 | A string literal operand of a monitored event is 2.7's unsigned integer (`cross("s")` monitors 115); a string-typed value there is E0517 | DONE (2026-10-08) |
| VD-108 | VAMS 9.15, E.2 | Annex E independent sources multiply their value by `sourceScaleFactor`; ESPice's operating point steps gmin, then the sources | DONE (#22) |
| VD-109 | VAMS 4.6.3 | An `ac_stim` name matches only a small-signal analysis of that name (or "ac"/"noise" kinds); it returns 0 in DC and transient (`contract.acStimActive`) | DONE (2026-10-08) |
| VD-110 | VAMS 9.15 Table 9-28 | `$simparam$str` strings reach a device through `Model` u32 indices into `contract.host_strings`; index 0 falls back to the `Instance` slices (GPU always does) | DONE (2026-10-08) |
| VD-111 | VAMS 8.4.3.2, 8.4.4, 8.5.1, 7.3.6.3; IEEE 1364-2005 17.1.3 | A digital `$monitor`'s analog probe is an operand: a report is due when a probe's value changed (VD-032's `!=`), checked at every digital time step and at every analog solution at a tick no digital event reached; time moving inside an argument is no change | DONE (2026-10-08) |
| VD-112 | VAMS 4.5.7 | A full `absdelay` ring keeps its window by thinning its older half, never by refusing (E1012 retired) or shortening the delay; W1051 once per site | DONE (2026-10-15) |
| VD-113 | IEEE 1364-2005 7.11, 7.6, 3.7 | A pass-switch group's net-type strengths (a supply through an uncontrolled `tran`) are settled when elaboration ends, as the nets' initial values, with no time-0 event; interpreter and native alike | DONE (2026-10-15) |
| VD-114 | VAMS 12.22, 12.11, 12.29; IEEE 1364-2005 26.6.16, G | An inter-module path is made on demand from an output and an input port of one size; its 2 or 3 delays are the model's, as a module path's are, and a put warns W0251; every Annex G name is defined, and one VerA does not answer is refused by name | DONE (2026-10-15) |
| VD-115 | VAMS 7.8.5.1, 7.8.5, 7.8.4, 3.9; IEEE 1364-2005 7.1.5 | Every built-in primitive's mixed terminal is bridged like a port, its lower side the `default_discipline` in force at it; enable gates are named `out`, `in`, `enable`; an unnamed primitive is `<gatetype>$<n>`; an instance array's element is `g[k]`, one bridge each; a terminal no bridge takes whole is E0929 | DONE (#29) |
| VD-116 | VAMS 7.3.1, 3.2; IEEE 1364-2005 5.4.1, 5.5.1-5.5.3 | An assignment to a `reg` wider than 32 bits in the analog context is computed at IEEE 1364 context width (the reg's width joins the right-hand side's); every other analog integer stays §3.2's 32 bits | DONE (2026-10-15) |
| VD-117 | VAMS 4.6.1 (Tables 4-21, 4-22), 4.6.2, 3.6.3.2, 5.10.2 | A §3.6.3.2 nodeset is Newton's starting point, applied before the first evaluation, so no evaluation is in a nodeset phase: `analysis("nodeset")` and `initial_step("nodeset")` are 0 in every host | no (#67) |
| VD-118 | VAMS 9.15 Table 9-28, 4.6.1 Table 4-21 | `$simparam$str("analysis_type")` is the Table 4-21 name the point evaluates as: "ic" at a transient's t = 0 operating point, "tran" at every later point | no (#67) |
| VD-119 | IEEE 1364-2005 6.1.3, 7.14 | A vector net's own `delay3` picks one delay for the whole value by §6.1.3's vector rule, as a continuous assignment does; never per bit, never from bit 0 | DONE (#55) |
| VD-121 | VAMS 4.5.13 | `limexp` limits nothing and is exp at every argument: a device sees one iterate, and the clause requires exp at convergence | DONE (#52) |
| VD-122 | VAMS 4.3.2, 4.3.1 Table 4-14 | A run-time ln/log/ln1p/sqrt/pow argument outside its domain is the prover's code from the executable (exit 1), at every evaluation an analysis makes; not for a value setup speculates, nor at the testbench's perturbed self-check points | DONE (#59) |
| VD-123 | VAMS 4.3.1 Table 4-14, 4.3.2 Table 4-15, 9.14 | asinh, acosh, atanh, log10, asin, acos and atan2 run the C algorithm (musl's) with the analytic derivative, one function shared by folder, prover and device; tan stays sin/cos, folded the same way | DONE (#60) |
| VD-124 | VAMS 2.6.1, 3.2; IEEE 1364-2005 3.5.1, 5.4.1 Table 5-22, 17.1.1.3 | An unsized integer literal is 32 bits in the analog context, as an `integer`, and 64 when its value needs more; display conversions size it, and every integer expression, by one rule (`systask.intSize`) | DONE (#77) |
| VD-125 | VAMS 3.4.2 | A value the host writes on the model card is checked against the declared `from`/`exclude` ranges after `derive` (`checkRange`); the testbench stops with E0377, the OSDI library fails setup fatally; only bounds that fold over literals, numeric parameters only | DONE (#80) |

## 1. Open decisions (CLAUSE-AUDIT §7.5)

### VD-001: A labelled regression gate in a row whose job is to fail
- **Source**: `tests/fixtures/MANIFEST.md` §5.8 items 1 and 12 at 8b1514d4.
- **Rule**: not an LRM reading. House rules: AGENTS.md §2 ("A rejection fixture is not positive coverage"; "XFAIL markers are implemented, never deleted") and §6 ("The trap that produces confidently wrong work").
- **Why vague**: X01's two `.op` decks, `file_multiple_dependents.va`, `slew_small_signal_transfer.va`, `invalid_index_write_preserves.va`, `discontinuity_real_degree.va` and A10's three host decks (`bound_step.sp`, `cross_timestep.sp`, `timer_breakpoints.sp`) pass today and exist to catch a named wrong implementation. MANIFEST §5.8 item 12 records that A01 06/07 were measured to go red under the wrong implementations they name.
- **Options**: (a) delete them as non-discriminating; (b) keep them as ordinary fixtures under their `//! lrm` tags; (c) keep them, labelled as regression gates.
- **Decision**: `DECIDED:` (b). A fixture is kept if its expected value is derived from the clause and some wrong implementation fails it. Whether VerA passes today does not matter. A green fixture with teeth is the normal case, not a defect. The test is the one MANIFEST §5.8 item 12 applied: show, in the header, the named wrong implementation and what it prints (`got=... ok=0`). A fixture that no plausible wrong implementation fails is deleted. "Regression gate" is not a separate category and gets no separate counting rule.
- **VerA today**: the `.va` files above exist and carry no `//! xfail`. The `.sp` decks are compile-checked only (`zig build test-spice`, `build.zig`), not executed (ARPice). No change to code. CHANGE NEEDED: a header line in each of the six `.va` files naming the wrong implementation it catches and the value that implementation prints, where the header does not already say so. Patch, documentation only.
- **Measure impact**: none. These files already count in A and C.
- **Status**: DONE (4ef087d6). The four `.va` files in this tree already named their wrong implementation and value except `a04_09`, which now does (a ddx through slew() as identity reads 1 where 0 is wanted). The X01 `.op` decks live in ARPice and the A10 `.sp` decks are compile-only; neither carries a VerA header to change.

### VD-002: Can `";2"` carry a dependent selector with no interpolation control?
- **Source**: MANIFEST §5.8 item 8 at 8b1514d4.
- **Rule**: VAMS 9.21, Syntax 9-16: `table_control_string ::= "[interp_control[;dependent_selector]]"`, `interp_control ::= 1st_dim_table_ctrl_substr_or_null [, ...]`. Table 9-32, first row: `""` or omitted means "Dimensionality of the data is assumed to be N. Column N+1 is taken as the dependent."
- **Why vague**: the bracket nesting makes the selector optional inside a present `interp_control`. Since `interp_control` can be a single null sub-string, `";2"` can be read in two ways. In the first, it is a null control plus selector 2, so the dependent is column N+2. In the second, it is one null sub-string spent on one column plus selector 2, so it is column 1+2 = 3 on a 2-D call. `a05_06` and `a05_07` disagree on this.
- **Options**: (a) one null sub-string is one consumed column (the dependent is column 3 on a 2-D table); (b) an empty head means every dimension takes the default and N comes from `table_inputs` (column N+selector).
- **Decision**: `DECIDED:` (b). Every dimension must consume a column. In Syntax 9-16 a sub-string that is null still controls its dimension with the defaults. It never removes a dimension. Reading (a) would give a 2-D lookup only one independent column, which contradicts Table 9-32's first row ("Column N+1 is taken as the dependent"). The rule is: leading columns = N + number of `I` sub-strings, and dependent = leading + selector. Both of Table 9-32's `I` examples come out right under this rule (`"I,1CC,1CC;3"` gives column 6, `"3,D,I,1;3"` gives column 7).
- **VerA today**: matches. `src/analog/table_model.zig:336-419` `parseTableCtl` gives undeclared trailing dimensions their own columns (`while (d < nd)`, `:408`) and returns `col + sel - 1` (`:418`). The headers of `ch09_system_tasks/ignored_column_and_selector.va` and `file_multiple_dependents.va` already give the two-arm rule. CLAUSE-AUDIT AMS-09 is `verified`. No change.
- **Measure impact**: none.

### VD-003: The quotations and mechanism claims the repair pass invented
- **Status**: DONE (70c42167)
- **Source**: MANIFEST §5.1(b) at 8b1514d4.
- **Rule**: not an LRM reading. House rule: AGENTS.md §6 (the header quotes the LRM sentence) and §0 rule 1.
- **Why vague**: five quotations and two mechanism claims in fixture headers were fabricated. One of them, A10's claim that VerA refuses a second `$bound_step`, was given as the reason no fixture was shipped for VAMS 9.17.2's "smallest currently active" rule.
- **Options**: (a) delete the fabrications; (b) delete them and also ship the coverage the fabrication excused.
- **Decision**: `DECIDED:` (b). Quoted text in a header must be found verbatim in `docs/`, or the quotation is deleted. VAMS 9.17.2 needs a positive fixture: two `$bound_step` calls in one evaluation, where the smaller bound must win.
- **VerA today**: none of the invented strings remains in `tests/fixtures`. I grepped for "selected after generate", "is active on the first point", "paramset for each instance" and "default to the unknown value"; the corrections landed 2026-09-29. No fixture tests the smallest-bound rule: `bound_step.va`, `kernel_control_tasks_together.va` and `spice_sine_source.va` each have one call. CHANGE NEEDED: add `ch09_system_tasks/bound_step_smallest_active_wins.va` (or a host test that reads `inst.bound_step`) with two calls and a hand-derived bound. Patch. It moves A by one fixture and gives 9.17.2 more evidence in C.
- **Measure impact**: A (+1 fixture), C (9.17.2 evidence).

### VD-004: Published figures that do not reproduce
- **Source**: MANIFEST §5.1(d) at 8b1514d4.
- **Rule**: not an LRM reading. House rule: AGENTS.md §0 rule 1 ("Never type a conformance number. Measure it.") and §9's last item.
- **Why vague**: headers state some numbers (accepted-point counts, ngspice digits, bounds) as measured, and re-running them does not reproduce those numbers.
- **Options**: (a) re-measure each one; (b) delete each one; (c) re-measure the ones an assertion depends on and delete the prose-only ones.
- **Decision**: `DECIDED:` (c). A figure that sets a tolerance or a `//! checks` count is re-measured by a command named in the header. A figure that only appears in prose is deleted. A header that is not re-measured in the same commit may not keep a measured figure.
- **VerA today**: see **Status**.
- **Measure impact**: none.
- **Status**: DONE (4ef087d6). Pass figures in `a01_06`, `a01_07`, `a04_09`, `a05_07` and `s01_01` re-run at `ae9633f1` and the command named; `s01_01`'s "all four rows fail today" did not reproduce (all four pass) and was removed.

### VD-005: Does §17.10 get its own digital row?
- **Source**: CLAUSE-AUDIT §7.5 item 2.
- **Rule**: IEEE 1364-2005 17.10 (`$test$plusargs`, `$value$plusargs`), inherited through VAMS 9.12, whose Table 9-9 marks both functions `Yes` in both contexts. House rule: CLAUSE-AUDIT §7.1, where the weaker context sets a split row.
- **Why vague**: §17.9 and §17.11 each have a separate digital row (17.9-14, 17.11-24) and §17.10 does not. The digital gap therefore scored 17.10-01/-02 as `missing (digital)`.
- **Options**: (a) add a `17.10-03 digital` row (total 128); (b) keep one row per function and score both contexts in it.
- **Decision**: `DECIDED:` (b), and the 17.9/17.11 split is not copied. Table 9-9 puts both contexts in one row per function. Measure B is per clause (`tests/fixtures/ieee1364/CLAUSES.tsv` rows 17.10, 17.10.1, 17.10.2), not per CLAUSE-AUDIT ledger row. The digital half now exists, so the original question is moot. Both rows are re-scored on today's evidence.
- **VerA today**: the digital plusargs are implemented (`lib/sim/digital/evaluate.zig`, `compile.zig`). They have positive and refusal `.v` fixtures: `ieee1364/17_system_tasks/plusargs_variable_query.v`, `test_plusargs_absent.v`, `value_plusargs_absent.v`, `test_plusargs_real_rejected.v`, `test_plusargs_arguments_rejected.v`, `value_plusargs_format_rejected.v` and `value_plusargs_arguments_rejected.v`. CLAUSE-AUDIT rows 17.10-01/-02 still read `missing (digital)`. CHANGE NEEDED: re-score CLAUSE-AUDIT 17.10-01/-02 against these fixtures and close §7.5 item 2. Documentation only.
- **Measure impact**: none from the document. Measure B already counts these from CLAUSES.tsv.
- **Status**: DONE (4ef087d6). CLAUSE-AUDIT 17.10-01/-02 re-scored `verified` on the listed `.v` fixtures; §7.5 item 2 closed; §7.1 tally updated.

### VD-006: May `.v` transcript evidence support `verified`?
- **Source**: CLAUSE-AUDIT §7.5 item 6.
- **Rule**: not an LRM reading. House rule: AGENTS.md §2 (an obligation needs a positive behavioural test, an invalid-input test and a recorded result) and CLAUSE-AUDIT §2.
- **Why vague**: four verdicts (17.3-01, 17.7-01, the digital half of 17.11-01, 17.11-24) rest on `zig build test-devices`. That step is outside measure A, and CLAUSE-AUDIT recorded it as failing at 47/66.
- **Options**: (a) only evidence inside `zig build test` counts; (b) any executed transcript suite with a recorded result counts.
- **Decision**: `DECIDED:` (b). A `.v` transcript is the compiler's output run in a host, with its result diffed against a recorded `.expected.txt`. That is exactly the runtime evidence AGENTS.md §2 asks for. Measure B (`zig build test-1364 -- --coverage`) is itself built from these transcripts. The condition is that the step passes: a verdict rests on a transcript only while its step is green, and the name-list diff in AGENTS.md §0 rule 3 applies to it as well.
- **VerA today**: AGENTS.md §0 records every `test-devices` case passing as of 2026-09-24, so the "47/66" in CLAUSE-AUDIT §7.5 item 6 is stale. CHANGE NEEDED: update CLAUSE-AUDIT §7.5 item 6 (documentation only). No verdict changes.
- **Measure impact**: none (confirms B's basis).
- **Status**: DONE (4ef087d6). CLAUSE-AUDIT §7.5 item 6 closed; `zig build test-devices` passes at `ae9633f1` (`tools/conformance.py`).

### VD-007: Discrete and electrical ports on one undeclared net with no connect statement
- **Source**: `docs/conformance-mixed-signal.md:211-215` at 8b1514d4.
- **Rule**: VAMS 6.5.7: "Ports of both analog and digital discipline may be connected to a net provided the appropriate connect statements exist (see 7.7)." VAMS 7.8.4 rule 3: "A connection shall be selected for a port only if one of the connections to the port is digital and the other is analog. In this case, the port shall match one (and only one) connect statement."
- **Why vague**: neither clause names a diagnostic for zero matching statements, and someone could argue the case is legal when nothing actually crosses domains. VerA accepts it.
- **Options**: (a) accept when no behaviour crosses domains; (b) accept silently (today); (c) refuse with a named error.
- **Decision**: `DECIDED:` (c). 7.8.4 defines a mixed signal by the disciplines of its segments, not by activity. Once the net resolves continuous (7.4.4.1) and a port's lower segment is discrete, the port is mixed. "Shall match one (and only one)" is then violated by zero matches as much as by two. 6.5.7's "provided" makes the connection conditional. The new diagnostic is the zero-match counterpart of E0922.
- **VerA today**: `src/elab/insert.zig:61-62`: "A mixed port no statement matches is left joined". E0922 covers only `count > 1` (`:94-99`). `ch07_mixed_signal/basic_resolution_continuous_beats_discrete.va` relies on this acceptance. CHANGE NEEDED: a new E09xx error for a mixed port that matches no connect statement, citing 6.5.7/7.8.4. `basic_resolution_continuous_beats_discrete.va` gets a `connectrules` block (or a trivial connect module), so it still tests 7.4.4.1 resolution. Add a reject fixture with that legal neighbour. Minor: source that was accepted is now refused.
- **Measure impact**: A (one fixture edited, one added), C (7.8.4 and 6.5.7 become two-way).
- **Status**: DONE (8a719d2a). E0927 (`insert.checkUnbridged`, judged after §7.4 resolution); `basic_resolution_continuous_beats_discrete.va` carries a `connectrules` block; `reject_mixed_port_no_connect_statement.va` pins the refusal.

### VD-008: Detail discipline resolution is testable, and its absence is a gap
- **Source**: `docs/conformance-mixed-signal.md:193-201` at 8b1514d4; Vague_Decisions.md §6 row "AMS 7.4.4.2".
- **Rule**: VAMS 7.4.4: "There are two modes for this method of resolution, basic (the default) and detail ... The selection of these discipline resolution modes shall be vendor-specific." VAMS 7.4.4.2 (detail mode).
- **Why vague**: "vendor-specific selection" can be read as permission to offer only one mode. `continuous_net_resolution_modes_agree.va:6-12` reads it that way and argues that a fixture for either mode would fail a conforming compiler.
- **Options**: (a) detail mode is optional, and basic-only conforms; (b) both modes are required, only the selection mechanism is vendor-specific, and basic is the normative default.
- **Decision**: `DECIDED:` (b). The clause defines two modes and makes basic the default. Only how a user selects a mode is left to the vendor. So a fixture that pins basic mode without any selection is not vendor-specific. It tests the normative default. Detail mode is testable once a selector exists, by a fixture that selects it and asserts the Figure 7-4 result. Until then, 7.4.4.2 is `missing`, not implementation-defined. See VD-013 for the selector.
- **VerA today**: basic only (`src/elab/resolve.zig`; Vague_Decisions.md §6 row "AMS 7.4.4.2 ... basic only"). `basic_resolution_continuous_beats_discrete.va` pins basic. CHANGE NEEDED: (1) correct the `continuous_net_resolution_modes_agree.va:6-12` header so it says basic is the testable default and detail is not implemented; (2) re-file IMPLEMENTATION's 7.4.4.2 row as a gap rather than a choice; (3) when VD-013 lands, add a detail-mode fixture. Patch for (1) and (2). Minor for (3), because it adds a CLI option and new resolution results.
- **Measure impact**: C (7.4.4.2 stays one-way until detail mode lands; no change from the documentation fix).
- **Status**: DONE (4735daab, detail mode: `segment.zig`). (1) `continuous_net_resolution_modes_agree.va` header corrected; (2) IMPLEMENTATION's row removed (it is a gap, not a choice); (3) detail mode is implemented: `src/elab/segment.zig` runs F.2.1/F.2.2 step 4 and F.2.2 step 5's top-down pass over the unflattened hierarchy, and `insert.plan` places connect modules where it puts the meeting of the domains. `discipline_resolution_detail_figure_7_4.va` asserts Figure 7-4's five leaf bridges (V = 0.2) against basic's two on Figure 7-3 (`discipline_resolution_basic_figure_7_3.va`, V = 0.5); `auto_insertion_figure_7_6_{basic_merged,detail_merged,detail_split}.va` assert Figure 7-6 Case 1's two, three and five. E0930 is retired. §7.4.4.2 states no prohibition, so `ch07_mixed_signal/CLAUSES.tsv` classifies it `no-prohibition`.

### VD-009: Two modules with one name
- **Source**: `docs/conformance-ieee-config-review.md:32` (CFG-005) at 8b1514d4.
- **Rule**: IEEE 1364-2005 13.2.1.1: "If multiple cells with the same name map to the same library, then the LAST cell encountered shall be written to the library. ... a warning message shall be issued." IEEE 1364-2005 4.11: "Once a name is used to define a module or primitive, the name shall not be used again to declare another module or primitive."
- **Why vague**: the two clauses contradict each other. 4.11 forbids reuse, and 13.2.1.1 prescribes last-wins with a warning for exactly this case (same name, one library, one compiler invocation).
- **Options**: (a) error under 4.11; (b) last wins with a warning under 13.2.1.1; (c) first wins silently.
- **Decision**: `DECIDED:` (b) in both languages. 13.2.1.1 is the specific rule: it names the case and gives a reason (the separate-compile model). 4.11 predates libraries. Option (c) satisfies neither clause. The `.va` path must agree with the `.v` path, so that one design does not elaborate differently depending on which engine reads it.
- **VerA today**: the digital path already conforms. `lib/sim/digital/bind.zig:28-51` emits W1152 and binds the later cell, and `ieee1364/13_configuration/same_name_cell_last_wins.v` pins it. The analog elaborator does not conform: `src/elab/names.zig:131-132` `findModule` returns the first match and does not warn. CHANGE NEEDED: make `findModule` (and the module list it scans) take the last same-named user module, emit W1152, and add a `.va` fixture with two `module leaf` declarations whose behaviour differs. Minor: device text changes for source that is already accepted.
- **Measure impact**: A (+1 fixture), C (13.2.1.1 evidence in the analog path). B already counts the `.v` fixture.
- **Status**: DONE (5258ed3f). `findModule` and `pickTop` take the last definition, `warnRedefinedModules` emits W1152, `wreal.check` binds the same module; `ch06_hierarchy/same_named_module_last_wins.va`.

### VD-010: A disabled block's contributions already made
- **Status**: DONE (ea6b1cb6)
- **Source**: `a03_SPEC.md:170-177` at 8b1514d4.
- **Rule**: VAMS 5.6.1.3: "When solving an analog block during an iteration, multiple contributions to the same potential branch or same flow branch will be additive." VAMS A.6.5 `disable_statement`. In VerA's analog subset only `@(event) disable blk;` is legal (E0401).
- **Why vague**: no clause says whether `disable` withdraws contributions that the block already executed in the same iteration.
- **Options**: (a) contributions executed before the `disable` stand; (b) they are withdrawn.
- **Decision**: `DECIDED:` (a). `disable` transfers control out of the block (IEEE 1364-2005 9.6.2, inherited). It is not a rollback, and no clause describes undoing a statement's effect. 5.6.1.3 makes contributions accumulate as the iteration executes. A contribution that ran therefore added to the branch, and the next iteration starts from nothing anyway (5.6.1.3, "only valid for the current iteration").
- **VerA today**: matches. `src/analog/stmt.zig:134-162` `lowerDisable` jumps to the block exit (`gotoBlock(nb.exit)`), so earlier contributions stay in the accumulated row. No fixture tests it: every `a03_*` disable fixture contributes outside the disabled block. CHANGE NEEDED: add a fixture with `begin : b I(p,n) <+ x; @(initial_step) disable b; I(p,n) <+ y; end` that asserts the branch carries x and not x+y at the event point. Patch, since behaviour is unchanged.
- **Measure impact**: A (+1), C (5.6.1.3 and A.6.5 positive evidence).

### VD-011: `#(.locked())` on a localparam
- **Source**: `docs/conformance-empty-parameter-fix.md` at 8b1514d4 (the cited lines 184-191 are past the file's 102 lines, so the citation is stale).
- **Rule**: VAMS 3.4.5: local parameters "cannot directly be modified with the defparam statement or by the ordered or named parameter value assignment". VAMS 6.3.3: "The parameter expression is optional so the instantiating module can document the existence of a parameter without assigning anything to it." IEEE 1364-2005 12.2.2.1: "Local parameters cannot be overridden".
- **Why vague**: an empty `.name()` modifies nothing, so 3.4.5's prohibition does not strictly apply. But 6.3.3's purpose is documenting a parameter that the instantiator could assign.
- **Options**: (a) accept, because nothing is modified; (b) refuse, because a localparam is not part of the instance's parameter interface.
- **Decision**: `DECIDED:` (b), E0907. Both standards keep localparams out of the parameter value assignment lists entirely (1364 12.2.2.1 says they "are not considered part of the ordered list"). The name list in 6.3.3 names the instantiated module's overridable parameters. Rejecting the name keeps a later edit to `.locked(3)` from becoming the first moment the error appears, and the rejection is also the portable choice.
- **VerA today**: matches. `src/elab/override.zig:176-178` refuses a localparam by name before the empty-value check (`:259-263`, "Validate the name/localparam above even when no value is given"). No fixture pins the empty form: `ch03_data_types/localparam_override_rejected.va` gives a value. CHANGE NEEDED: add `reject_localparam_empty_named_override.va` (`//! reject E0907`) next to a legal `#(.p())` on a plain parameter. Patch.
- **Measure impact**: A (+1), C (3.4.5 refusal paired with its legal neighbour).
- **Status**: DONE (2df23aa8). `ch03_data_types/reject_localparam_empty_named_override.va`.

### VD-012: Which SPICE flavour VerA claims
- **Source**: `h04_SPEC.md:116-119` at 8b1514d4; Vague_Decisions.md §6 row "AMS E.1, E.2".
- **Rule**: VAMS E.1.2 item 1: "whether a particular Verilog-AMS simulator is SPICE compatible, and with which particular variant of SPICE it is compatible, is solely determined by the authors of the simulator."
- **Why vague**: the standard leaves the dialect to the tool. VerA has stated parse limits but no claim, and it skips every card it cannot read without saying so.
- **Options**: (a) claim nothing and skip silently (today); (b) claim a named subset and refuse what falls outside it inside a definition; (c) adopt a full dialect (HSPICE/Spectre `PARAMS:`, `{expr}`, nested `.SUBCKT`).
- **Decision**: `DECIDED:` (b). VerA claims SPICE3 card syntax for `.MODEL` and for flat `.SUBCKT` bodies made of numeric-valued R/C/L/V/I/E/F/G/H cards. `PARAMS:`, `{expr}` values, nested `.SUBCKT`, `.INCLUDE`/`.LIB` and model-referenced body devices (`R1 A B RMOD`) are not claimed. Cards outside a definition (`.tran`, top-level devices) are not module definitions and may still be skipped. A card that cannot be read inside a `.SUBCKT` body is refused with a named E.1.2 diagnostic. Skipping it changes the circuit, for example a dropped R becomes an open, and that is the silent wrong answer AGENTS.md §4 forbids.
- **VerA today**: `lib/frontend/spice_cards.zig:1-4` ("every other card is skipped without a diagnostic"), `:254-260` (an unreadable body card "contributes nothing and is not diagnosed"), `:123-125` (a nested `.SUBCKT` closes early), `:186` (`params:` ends the port list and is ignored). CHANGE NEEDED: (1) a new error for an unreadable card inside a `.SUBCKT` body, for `PARAMS:`/`{}`, and for a nested `.SUBCKT`; (2) state the claim in Vague_Decisions.md §6; (3) add reject fixtures with legal neighbours in `annex_e_spice/`. Minor: netlists that were accepted are now refused. The `.MODEL X SW` E0904 mis-blame is fixed by the same diagnostic.
- **Measure impact**: A (new fixtures), C (E.1.2 refusal evidence).
- **Status**: DONE. The `.MODEL` half (e7900531): a `.MODEL` of a type with no Table E.1 row is recorded and its instance is E0952. The `.SUBCKT` half (aeb2b5cc): unreadable body cards, `PARAMS:`, `{}` and nesting are E0928, reported at the card's line in the netlist.
- **Extended (#9, 2026-10-06)**: the Pam4 project hands VerA transistor-level netlists (schematic and post-layout) whose devices are M cards naming PDK models: `Ma outn inp tail vss nmos_lvt L=21n NFIN=26`, with ASAP7's `.model nmos_lvt bsimcmg type=1 ...` reached through `.lib "asap7.lib" tt`, whose entry `.hdl`s the BSIM-CMG Verilog-A. The claim now also covers: an M/Q/J/D card inside a `.SUBCKT` naming a model, which instantiates (a) the `.MODEL`'s type when that is no Table E.1 row (a Verilog-A module or paramset of the design: the model card's parameters, then the card's own over them, `M=` as E.4.1's `$mfactor`, a positional area as `area`), or (b) the name itself as a module or paramset when no `.MODEL` has it; `.INCLUDE file`, `.LIB file entry` (the lines between `.LIB entry` and `.ENDL`; a library entry met any other way is unread until called) and HSPICE's `.HDL file` (a Verilog-A source of the design, read after the compilation unit) anywhere in the netlist, each relative name looked for beside the file that names it (VD-091's rule); and HSPICE's `k = v`. The netlist's lower-cased names reach a Verilog-AMS module, paramset or parameter regardless of case when nothing matches exactly (E.2.1 from the netlist's side; `elaborate.names.spiceCase`). Refused: a card whose model is a `.MODEL` of a Table E.1 semiconductor type (nmos, pmos, npn, pnp, d, njf, pjf, nmf, pmf), E0953, because those rows have no Behavior and the card would be an open; a binned model (`.MODEL name.N`), a file that cannot be read, a missing `.LIB` entry, an unclosed `.LIB` entry, nesting past 16 files, a non-numeric parameter value and a field after the model or the parameters, E0928. `PARAMS:`, `{expr}`/`.PARAM`, nested `.SUBCKT` and X cards stay refused: none of the Pam4 netlists uses them. Semver: minor (source VerA refused now compiles; `Q` cards that were E0928 now instantiate their model). Fixtures: `annex_e_spice/spice_fet_card_instantiates_model_module.va`, `spice_lib_include_hdl.va`; `reject_spice_fet_card_model_has_no_behaviour.va`, `reject_spice_binned_model.va`, `reject_spice_lib_entry_missing.va`; `reject_spice_unread_device_card.va` moved from a Q card to an S card.
- **Extended (#9 leftovers, 2026-10-08)**: the claim now also covers (`lib/frontend/spice_cards.zig`): HSPICE's subcircuit parameters, `.SUBCKT name ports [PARAMS:] k=v ...` (`PARAMS:` may be unwritten), each a `parameter real` of the module with `v` as its default; `{expr}` and `'expr'` values in a subcircuit's cards and parameter defaults, over the subcircuit's parameters (a default over those before it), translated by `expression`: SPICE numbers (written as real literals, so `{1/3}` is a third, not §4.2.1's integer 0), `+ - * /`, HSPICE's `**` (binding tighter than a unary minus on its left, `-2**2` = -4), parentheses, and the functions whose meaning SPICE and §4.3.1-4.3.2 share (sqrt, exp, abs, min, max, pow, sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, floor, ceil); a `.MODEL` card's values may be expressions over numbers; X cards, `Xname nodes... subckt [PARAMS:] [k=v ...]`, an instance of any module or paramset of that name with `M=` as `$mfactor`; binned models, `.MODEL name.N type ... LMIN= LMAX= WMIN= WMAX=`: a card naming `name` takes the first bin in card order with LMIN <= L < LMAX and WMIN <= W < WMAX (SPICE's rule; an unwritten bound is open), without the four bounds, which only select (the bin is chosen in the reader, so L and W must be numbers on the card); and node 0 inside a subcircuit body is the ground (`ground \0 ;`, §3.6.4), where it was a local net and a card on it an open. Still refused at the card (E0928): `.PARAM` anywhere in a body and any name an expression reads that is no parameter in scope (a top-level `.PARAM` is not read, so the reference has nothing to resolve to); `log` (natural in SPICE, base 10 in §4.3.1), `^`, comparisons, `?:` and every other function; a binned card whose L or W is missing or an expression, or that no bin holds; nested `.SUBCKT`. Semver: minor. Fixtures: `annex_e_spice/spice_subckt_params_expressions.va`, `spice_x_card_subcircuit_instance.va`, `spice_binned_model_selects_by_l_and_w.va`; `reject_spice_expression_value.va` (now a name out of scope), `reject_spice_subckt_params.va` (now `log`), `reject_spice_binned_model.va` (now no bin holds L), each `reject-only` with a neighbour.

### VD-013: "Shall be controlled by a simulator option" (F.2.2)
- **Source**: `annex_f_resolution/COVERAGE.md:16-21` at 8b1514d4.
- **Rule**: VAMS F.2.2 (Annex F is normative): "The selection of this algorithm instead of the default shall be controlled by a simulator option." VAMS F.1: "This annex provides a possible algorithm for achieving the semantics of" 7.4.
- **Why vague**: VerA is a compiler, not a simulator, so the standard does not say what form a "simulator option" takes for it. F.1 also lets an implementation use a different algorithm, which raises the question of whether VerA's single fold of step 5's top-down re-pass is allowed.
- **Options**: (a) declare F.2.2 out of scope; (b) add a compiler option.
- **Decision**: `DECIDED:` (b). The option is `--discipline-resolution=basic|detail` (default `basic`), recorded in the device's metadata. The obligation does not depend on how VerA is packaged. Folding the passes is acceptable under F.1 as long as the results equal the two-pass algorithm. That is an evidence obligation, a distinguishing hierarchical fixture, not a defect. Until the option exists, F.2.2 and 7.4.4.2 are `missing` (VD-008).
- **VerA today**: no such option. Basic mode only (`src/elab/resolve.zig`). CHANGE NEEDED: add the option and detail mode, plus a mode-selecting fixture directive and a Figure 7-4 fixture. Minor. Until then, record F.2.2 as `missing` in CLAUSE-AUDIT.
- **Measure impact**: C (F.2.2 and 7.4.4.2 stay one-way until the option lands).
- **Status**: DONE (4735daab, detail mode: `segment.zig`). `vera --discipline-resolution=basic|detail` and the fixture directive `//! discipline-resolution`. No device metadata row: the mode decides only where connect modules go, which is the device text itself. Folding is not used: `segment.zig` runs the two passes as F.2.2 writes them, step 5 as the walk descends. E0929 is narrowed to an upper connection the pre-insertion pass cannot read; since #11 (2026-10-08) that pass reads the subtree a first walk elaborated (generate blocks, instance arrays, paramsets at any depth, out-of-context declarations below the planned level), so only a generate scheme that does not fold, or a subtree that walk could not elaborate, is left.

### VD-014: UTF-8 bytes above 0x7F in string literals
- **Source**: `annex_a_syntax/COVERAGE.md:332-335` at 8b1514d4.
- **Rule**: VAMS A.8.8: `string_literal ::= " { Any_ASCII_Characters } "`. IEEE 1364-2005 3.6: a string is "a sequence of 8-bit ASCII values, with one 8-bit ASCII value representing one character".
- **Why vague**: ASCII is 7-bit, but 1364 3.6 describes strings as "8-bit ASCII values". Bytes 0x80-0xFF are therefore excluded by the production and included by the storage model.
- **Options**: (a) refuse bytes above 0x7F; (b) accept them as opaque bytes, one byte per character; (c) decode UTF-8 so that a code point is one character.
- **Decision**: `DECIDED:` (b). 1364 3.6 defines a string's value as its bytes, 8 bits each, so a byte above 0x7F has a well-defined value and length. Refusing would break real models that write unit strings like `"°C"` for no semantic gain. Decoding would contradict "one 8-bit ... value representing one character". `"°C"` is three characters to `len()`/`$strlen`-style operations. This is an implementation-defined choice and belongs in Vague_Decisions.md §6.
- **VerA today**: accepted without a diagnostic (COVERAGE note). I found no fixture that asserts the value or length of a non-ASCII string. CHANGE NEEDED: an Vague_Decisions.md §6 row, and a fixture that asserts the byte count of `"°C"` is 3. Patch.
- **Measure impact**: A (+1). C none, since it is implementation-defined.
- **Status**: DONE (9d434792): `ch02_lexical/string_bytes_above_7f.va` pins `"°C"` as three bytes (0xC2B043); Vague_Decisions.md §6 row added.

### VD-015: `$limit(typ*V(a,k), ...)`
- **Source**: found 2026-09-27.
- **Rule**: VAMS 9.17.3, Syntax 9-12: every form is `$limit ( access_function_reference ... )`. The prose says it "returns a real value that is derived from its first argument (the access function reference, such as a branch voltage)".
- **Why vague**: A.8.2's generic `analog_system_function_call` takes any expression, while Syntax 9-12 narrows the first argument. The question was whether to refuse or to warn (W0853).
- **Options**: (a) W0853, with the site declined; (b) an error.
- **Decision**: `DECIDED:` (b). The clause's own syntax is the narrower and more specific rule. The legal way to write it is `$limit(V(a,k), "pnjlim", vte, vcrit, typ)`, with the polarity as VerA's frame-sign argument (AGENTS.md §6), so no expressible model loses anything.
- **VerA today**: already decided and implemented as E0891. `src/analog/sysfunc.zig:160` enforces it, `ch09_system_tasks/limit_scaled_probe_rejected.va` pins it (`//! reject E0891`), and `limit_polarity_sign_argument_honoured.va` is the legal neighbour.
- **Measure impact**: none (already counted).
- **Status**: DONE (4ef087d6). Nothing to change in code or fixtures; the stale open-question row was in a document since removed.

### VD-016: A `.v` design as a contract device
- **Source**: project scope.
- **Rule**: not an LRM reading. Project scope.
- **Why vague**: it was an open product decision, not a reading of the standard.
- **Options**: n/a.
- **Decision**: `DECIDED:` implemented. The device runtime is in `lib/sim/rt/device.zig`, and host tests pass at `15bb97ca` (2026-09-29). Remaining extensions are tracked as GitHub issues.
- **VerA today**: `lib/sim/rt/device.zig`, `tests/host/vdev_host.zig`, `tests/host/vdev_so_host.zig`. No change.
- **Measure impact**: none.

### VD-017: x/z as an analog display operand (17.1-06's analog half)
- **Status**: DONE (73d3f9dd)
- **Source**: CLAUSE-AUDIT §7.5 item 1.
- **Rule**: VAMS 7.3.2: "Accessing digital net and digital binary constant operands are supported within analog context expressions. It is an error if these operands return x or z bit values when solved." x/z are admitted only through `===`, `!==`, `case`/`casex`/`casez` and x/z digit constants used in those comparisons. IEEE 1364-2005 17.1.1.4 (x/z display formatting) is inherited through VAMS 9.4.
- **Why vague**: CLAUSE-AUDIT §4.1 read 7.3.2 as making x/z legal analog display operands, which would make E0130 a refusal of legal source. `s01_SPEC.md` read the refusal as correct.
- **Options**: (a) x/z display operands are legal in analog, so the row is `missing`; (b) an x/z value reaching an analog operand other than a 7.3.2 comparison is an error, so the row is `verified on the prohibition`.
- **Decision**: `DECIDED:` (b). 7.3.2 lists the only constructs through which x/z may be accessed, and says any other operand that yields x/z "is an error". Its own `converter` example marks `var1 = 1'bx;` and `V(anet) <+ 1'bz;` as errors. A `$display` argument is an ordinary operand. 17.1.1.4 still governs the digital context.
- **VerA today**: the refusal matches (E0130, `src/ir/lower.zig:500`, `src/analog/expr.zig:105`; `ch07_mixed_signal/x_literal_unsupported.va`, `xz_contribution_rejected.va`). But E0130's explanation (`lib/diag/code.zig:819-829`) says it is "not a claim that the literal is forbidden by full Verilog-AMS", which contradicts this reading. No fixture tests a display operand. CHANGE NEEDED: (1) rewrite E0130's explanation so that it cites 7.3.2 as a prohibition when the operand is not a 7.3.2 comparison; (2) add `reject_display_x_operand_analog.va` (`$display("%b", 1'bx)`, `//! reject E0130`) with a legal `1'b1` neighbour; (3) re-score CLAUSE-AUDIT 17.1-06 and close §7.5 item 1. Patch, since diagnostic wording is not in AGENTS.md §3's minor list.
- **Measure impact**: A (+1), C (7.3.2 refusal paired with its legal neighbour). B row 17.1.1.4 is unaffected because it is digital.

### VD-018: `d09_91` and excess `$readmem` data
- **Source**: CLAUSE-AUDIT §7.5 item 3.
- **Rule**: IEEE 1364-2005 17.2.9: "A warning message shall be issued if the number of data words in the file differs from the number of words in the range implied by the start through finish addresses and no address specifications appear within the data file."
- **Why vague**: the question was recorded as needing the 1364 text, namely whether excess data is an error. The text answers it: excess data gets a warning, and the load continues.
- **Options**: (a) error; (b) warning, with the excess dropped.
- **Decision**: `DECIDED:` (b), as the clause says. Loading stops at the finish address, and the warning is required.
- **VerA today**: matches. `ieee1364/17_system_tasks/readmem_overflow_rejected.v` is now a positive fixture. It requires W1150 ("memory file data word count does not match load range"), its data file `91_readmem_overflow_rejected.hex` sits beside it, and `.expected.txt` is `11 22 33 44`. CHANGE NEEDED: update CLAUSE-AUDIT 17.2-21 and §7.5 item 3, which still say excess data is dropped silently and that `d09_91` "is run by nothing" (documentation only). Optional: rename the file to drop the misleading `_rejected`. Patch.
- **Measure impact**: none (B already counts it).
- **Status**: DONE (4ef087d6). CLAUSE-AUDIT 17.2-21 and §7.5 item 3 now record W1150 and the positive `d09_91`. The file was not renamed.

### VD-019: A parsed AST path is not `partial` (AMS-06 `driver_update`)
- **Source**: CLAUSE-AUDIT §7.5 item 4.
- **Rule**: not an LRM reading. House rule: CLAUSE-AUDIT §2 verdict definitions and AGENTS.md §2 ("Compiler acceptance is not runtime evidence").
- **Why vague**: CLAUSE-AUDIT §2 does not say whether a construct that parses and survives elaboration counts as "some of the clause".
- **Options**: (a) a surviving AST path counts as `partial`; (b) `partial` requires at least one of the clause's obligations executed with a recorded result.
- **Decision**: `DECIDED:` (b). Parsing is not an obligation of VAMS 9.22.5. The clause's obligation is that the statement executes on every driver update. This is the same line AGENTS.md §2 draws for "it compiles".
- **VerA today**: the premise is stale. `driver_update` now executes (`lib/sim/digital/driver.zig`; AGENTS.md §7). `ch07_mixed_signal/driver_update_without_resolved_change.va` asserts that it fires without a change in the resolved value, and `ch09_system_tasks/driver_update_in_analog_event_rejected.va` is the refusal. CLAUSE-AUDIT row AMS-06 still says `missing`. CHANGE NEEDED: re-score AMS-06 on today's fixtures (at least `partial`, `verified` if both directions hold) and close §7.5 item 4. Documentation only.
- **Measure impact**: none from the document (C is measured by `benchmark -- --coverage`).
- **Status**: DONE (4ef087d6). AMS-06 re-scored `verified` on `m04_12` and `213` (both pass in the strict suite at `ae9633f1`); §7.5 item 4 closed.

### VD-020: Can a kernel unit test support `verified`?
- **Source**: CLAUSE-AUDIT §7.5 item 5.
- **Rule**: not an LRM reading. House rule: AGENTS.md §2: "Neither does a kernel unit test alone, a compiled `.c` file, or a SPICE deck paired with a JSON file: none of them runs the compiler's output in a host."
- **Why vague**: `zMonitor` (17.1-12) and `zCReal` (17.1-04) have unit tests at the exact boundary the device calls. CLAUSE-AUDIT counted those tests as enough in one row and not enough in another.
- **Options**: (a) a kernel test counts where the observable is rendered text; (b) a kernel test never counts alone.
- **Decision**: `DECIDED:` (b), which AGENTS.md §2 already settles. A kernel test can add to a verdict but never carries one.
- **VerA today**: 17.1-12 now has fixture evidence that runs the emitted device. `ch09_system_tasks/monitor_suppresses_an_unchanged_step.va` and `monitor_reports_every_change.va` carry no `//! xfail`, whereas CLAUSE-AUDIT recorded them as failing. 17.1-04 rests on `display_c_format_flags.va` and `s01_01`-`s01_04`. CHANGE NEEDED: re-score 17.1-12 on s01_05/s01_06 (confirm they pass in the FAIL name list first), and re-check that no other row rests on a kernel test alone. Documentation only.
- **Measure impact**: none (documentation).
- **Status**: DONE (4ef087d6). 17.1-12's analog half re-scored on `s01_05`/`s01_06` (both pass, strict suite 0 FAIL at `ae9633f1`); the row is now `partial` (digital governs). No other CLAUSE-AUDIT row rests on a kernel test alone. §7.5 item 5 closed.

## 2. Readings the standards leave open: Verilog-AMS

### VD-021: Multiline string literals
- **Source**: `conformance-strings-ledger-independent-review.md` at 8b1514d4, STR-REVIEW-01.
- **Rule**: VAMS 2.7: "A string literal is a sequence of characters enclosed by double quotes (") and contained on a single line." VAMS A.8.8: `string_literal ::= " { Any_ASCII_Characters } "`. Annex G change 2535: "Corrected definition for multiline strings" (A.8.8). IEEE 1364-2005 3.6 has the same single-line sentence, and its A.8.8 reads `Any_ASCII_Characters_except_new_line`.
- **Why vague**: the AMS prose keeps the inherited single-line rule, while the AMS production dropped the `_except_new_line` qualifier, and the change log calls that a correction "for multiline strings" without saying which direction it corrects in. Neither text says it overrides the other.
- **Options**: (a) refuse a raw newline inside a string (2.7, 1364 3.6); (b) accept it (A.8.8 as printed); (c) also accept the IEEE 1800 `\`-newline continuation.
- **Decision**: `DECIDED:` (a). A raw newline or a `\`-newline continuation inside a string is an error. The prose is the normative sentence that states the rule. The inherited 1364 text agrees with it in both prose and grammar. `Any_ASCII_Characters` is a placeholder that A.8.8 never defines. Change 2535 is informative and does not say what it allowed. Refusing is also the portable choice: what VerA accepts, a 1364-based tool accepts too. If an erratum later allows multiline strings, the rejection fixtures flip and nothing else changes.
- **VerA today**: refused, E0138 (`lib/frontend/lexer.zig` `stringRunaway`, test at :652); the continuation is refused too (lexer.zig:424-434). Fixtures: `ch02_lexical/multiline_string_rejected.va`, `string_line_continuation_rejected.va`, `annex_a_syntax/reject_A_8_8_string_spans_lines.va`, `ieee1364/03_lexical_conventions/string_spans_lines_rejected.v`. No change.
- **Measure impact**: none (pins existing behaviour; the fixtures' headers may cite this entry).

### VD-022: A raw TAB inside a string literal
- **Source**: STR-REVIEW-02.
- **Rule**: VAMS 2.3: "However, spaces and tabs shall be considered significant characters in strings (see 2.7)." VAMS 2.7: "Certain characters can only be used in a string literal when preceded by an introductory character called an escape character", and Table 2-2 lists `\t`.
- **Why vague**: read literally, 2.7 would require a tab to be escaped. 2.3 says that a literal tab in a string is significant, which assumes a literal tab can appear there.
- **Options**: (a) a raw TAB is legal and stands for byte 9; (b) a raw TAB is an error that requires `\t`.
- **Decision**: `DECIDED:` (a). 2.3 is the clause about white space and addresses tabs in strings by name. 2.3 would mean nothing if tabs could not appear unescaped. Table 2-2 shows how to write a tab, not a ban on the raw byte; the same table lists `\n`, and a raw newline is excluded separately by the single-line rule (VD-021). The 1364 parent text gives the same reading. Every mainstream Verilog front end accepts a raw tab in a string, though no specific tool was checked here.
- **VerA today**: accepted, value 9 (`lib/frontend/lexer.zig` `stringContents` copies non-backslash bytes). Fixtures: `ch02_lexical/string_literal_tab_positions.va` (leading, interior and trailing tab, 3 checks), `string_whitespace_significant.va`. No change.
- **Measure impact**: none.

### VD-023: `op` attribute absent: is the value in the operating-point report?
- **Source**: `conformance-attributes-ledger-independent-review.md` ATTR-IR-03.
- **Rule**: VAMS 2.9.2: "If the attribute is specified with the value "no", then the parameter or variable will be omitted from the short report; otherwise, the parameter or variable will be included."
- **Why vague**: the word "otherwise" covers both an explicit "yes" and no `op` attribute at all. The clause also does not say which objects are eligible for the report.
- **Options**: (a) absent means included; (b) absent means excluded and only `op="yes"` is reported; (c) left to the tool.
- **Decision**: `DECIDED:` (a). The sentence makes "no" the only value that excludes, so everything else, absence included, is included. Eligibility is a separate question: the report covers §3.2.1 output variables (module-scope variables carrying `desc` or `units`) and parameters, and `op` only removes items from that set.
- **VerA today**: VerA checks the value domain only (`src/analog/param.zig` `checkAttributes`, E0358; `ch02_lexical/op_attribute_numeric_rejected.va`, `standard_attribute_domain_rejected.va`). The device publishes no operating-point report (no such table in `lib/contract.zig`), so there is nothing to change today. When a report table is added, its default must follow (a).
- **Measure impact**: none now; C (2.9) once a report exists and a fixture compares absent, "yes" and "no".

### VD-024: Keywords as attribute names (`units` is reserved)
- **Source**: ATTR-IR-04.
- **Rule**: VAMS 2.9 Syntax 2-4 and A.9.1: `attr_name ::= identifier`. Annex B reserves `units`. VAMS 2.9.2 standardizes "The units attribute", and its example writes `(* ... units="Ohms" ... *)` unescaped.
- **Why vague**: the standard's own attribute name is a keyword the grammar does not allow as `attr_name`. Read literally, the example is ungrammatical. The text does not say whether the exception covers only `units` or all keywords.
- **Options**: (a) only `units` is exempt and any other keyword is an error; (b) every keyword is accepted as a name; (c) `units` must be escaped.
- **Decision**: `DECIDED:` (a). `units` is legal because 2.9.2 standardizes it and prints it unescaped. Nothing grants the same exception to any other keyword, and IEEE 1364-2005 A.9.1 gives the same `attr_name ::= identifier`. A keyword used as an attribute name is refused with a named diagnostic; the legal form is an escaped identifier (`(* \module = 1 *)`). This keeps VerA's accepted set inside what a 1364/1800 front end accepts.
- **VerA today**: every keyword is accepted as an attribute name (`lib/frontend/parser.zig:580-585`: "every keyword is taken as a name"). CHANGE NEEDED: in `parseAttributes`, accept identifiers, escaped identifiers and `kw_units` only, and refuse any other keyword with E0208 (or a dedicated code) citing 2.9/A.9.1. Add a rejection fixture (`(* module *)`) with its legal neighbours (`(* \module *)`, `(* units = "V" *)`). Semver: minor (VerA newly refuses source).
- **Measure impact**: A (+2 fixtures); C (2.9 gains a refusal with a legal neighbour).
- **Status**: DONE (8a677e04): E0208 with a keyword note, `ch02_lexical/attribute_keyword_name_rejected.va`; legal neighbour `attribute_keyword_name_escaped.va` (`\module`, `units`).

### VD-025: Forward parameter references
- **Source**: `conformance-parameter-core-ledger-review.md:43-45`.
- **Rule**: VAMS 3.4: the initializer "shall be a constant expression, that is, an expression containing only constant numbers and previously defined parameters." IEEE 1364-2005 4.10.1 uses the same words.
- **Why vague**: "previously defined" could mean earlier in the source text or earlier in dependency order. Some tools resolve parameters lazily and accept a forward reference.
- **Options**: (a) textual order, and a forward reference is an error; (b) dependency order, with only cycles refused.
- **Decision**: `DECIDED:` (a). Both standards say "previously", and a parameter port list or an earlier declaration is the only meaning that word has in a one-pass reading. Refusing keeps sources portable to strict tools. Whether Icarus, VCS or OpenVAF accept forward references was not established here.
- **VerA today**: refused, E0314. `ch03_data_types/forward_parameter_reference.va` pins it, and its header shows that swapping the two declarations makes the file legal. No change.
- **Measure impact**: none.

### VD-026: `min`/`max` with NaN or signed zero
- **Status**: DONE (107333b2)
- **Source**: `conformance-minmax-ledger-review.md:97-102`.
- **Rule**: VAMS 4.3.1, Table 4-14: `min(x, y)` has the "Equivalent C function" `fmin(x,y)` and the domain "All x, all y". The same clause says "these functions are defined so: min(x,y) is equivalent to (x < y) ? x : y; max(x,y) is equivalent to (x > y) ? x : y".
- **Why vague**: C `fmin(NaN, 1)` and `fmin(1, NaN)` both return 1, and C leaves the sign of `fmin(-0, +0)` open. The conditional form returns 1 for `min(NaN, 1)`, NaN for `min(1, NaN)`, and +0 for `min(-0, +0)`. The table and the prose disagree on unordered and signed-zero inputs.
- **Options**: (a) the conditional form for value and derivative alike; (b) C `fmin`/`fmax` for the value and the conditional form for the derivative only.
- **Decision**: `DECIDED:` (a). The conditional form is the only one of the two the clause states as a definition ("are defined so"), and it is exact on every input. Taking the value from one rule and the derivative from another could select one operand's value and the other's partials. The "Equivalent C function" column names a function family, not a bit-exact oracle. Constant folding must give the same bits as run time.
- **VerA today**: at run time, `zMin`/`zMax` use `a.lt(b).sel(a, b)` and `b.lt(a).sel(a, b)` (`src/codegen/device/codegen/kernel_text.zig:50-51`), which matches (a). The constant folder uses Zig's `@min`/`@max` for reals (`lib/frontend/constfold.zig:401-402`). Those return the non-NaN operand and leave the sign of a zero result unspecified, so a folded `min(1.0, NaN)` or `max(-0.0, 0.0)` can differ from the same expression at run time. CHANGE NEEDED: fold reals with `if (x < y) x else y` and `if (x > y) x else y`. Add a fixture comparing a folded and an unfolded `min`/`max` on NaN and ±0 operands with `CHECKEQ`/`CHECKX` against `1/x` signs. Semver: patch, or minor if a golden's emitted constant moves.
- **Measure impact**: A (+1 fixture); C (4.3.1 corner cases).

### VD-027: Nodesets before or after `analog initial`
- **Source**: `conformance-scheduling.md:35`.
- **Rule**: VAMS 8.2: "Once analog initial blocks are evaluated, analog net declaration assignments and simulator nodeset values are then applied." VAMS 8.4.1: "It is a one time execution of nodeset statements (3.6.3.2), then the procedural statements in analog initial block, and then the procedural statements in the Verilog initial block".
- **Why vague**: the two clauses give opposite orders for nodesets and `analog initial`.
- **Options**: (a) follow 8.2; (b) follow 8.4.1; (c) establish that the order cannot be observed.
- **Decision**: `DECIDED:` (c), and VerA follows 8.2 where it has to pick. A conforming source cannot observe the order. A 3.6.3.2 initializer "shall be a constant_expression", so it cannot read anything `analog initial` computes. Under 5.2.1, `analog initial` may not contain access functions, so it cannot read a nodeset. Both clauses agree that `analog initial` runs before the digital `initial` blocks. No fixture may assert an order between nodesets and `analog initial`.
- **VerA today**: nodesets are a comptime device table, `u_nodeset: [n]?f64` (`lib/contract.zig:3181-3185`), which the host applies at its solve. `analog initial` runs in `initState`. No change.
- **Measure impact**: none.

### VD-028: Does an `@()` body run once per timepoint or once per Newton iteration?
- **Source**: `a03_SPEC.md:284-291` at 8b1514d4.
- **Rule**: VAMS 5.10.3.3: "At that time point, the event evaluates to True." VAMS 8.3.3: "the behavioral description is evaluated iteratively until the NR method converges."
- **Why vague**: the event is true for the whole timepoint, and the analog block runs once per iteration, so the body could run several times at one timepoint. The text does not say whether its effects (a held counter, a file write) accumulate per iteration.
- **Options**: (a) the body's effects take effect once per accepted timepoint; (b) the effects accumulate per iteration.
- **Decision**: `DECIDED:` (a). The body may run on every iteration of the event timepoint, but each run starts from the last accepted state, and only the converged iteration's assignments and side effects are committed. The standard's own 5.10.2 `bitErrorRate` example counts bits and would give no usable count under (b). Reading (a) also makes the result independent of how many iterations the solver needs, which no source can control.
- **VerA today**: matches (a). Held variables are written back only in `updateState` ("writing from `eval` would latch a Newton iterate the solver may discard", `src/codegen/device/codegen/state.zig:512-525`). Display and file tasks run in the accepted-point phase. Fixtures `ch05_analog_behavior/a03_04`, `a03_05`, `a03_07`, `a03_10` and `a03_12` assume (a). No change.
- **Measure impact**: none.

### VD-029: Chapter 8's "canceling previous event" vs IEEE 9.2.2
- **Source**: `specification/ch8-scheduling.html` editorial note.
- **Rule**: VAMS 8.4.4 Figure 8-6 walkthrough: the nonblocking assign "schedules the actual assignment for 6ns (rounded 1ns delay), canceling previous event." IEEE 1364-2005 9.2.2 performs every queued nonblocking update in order.
- **Why vague**: the AMS example describes a second nonblocking assignment as cancelling the first, which 1364 never does. The example's inverter source is not printed.
- **Options**: (a) the example overrides 9.2.2 for this case; (b) 9.2.2 governs, and "canceling" describes what the D2A sees.
- **Decision**: `DECIDED:` (b). The text is an informative walkthrough, and AMS 1.1 inherits 1364's digital semantics whole. Read under 9.2.2, both updates are queued for 6 ns and performed in order, so B ends at the second value and the walkthrough's final line holds: "Value of B doesn't change". The "cancellation" is the D2A's driver look-ahead (`$driver_next_state`, 9.22) seeing the newer queued value before the transition filter ever starts, so no analog edge appears. No kernel event is removed.
- **VerA today**: the digital kernel performs both nonblocking updates. An earlier fixture that assumed cancellation was withdrawn (AGENTS.md §6, "The second NBA cancels the first"). Driver look-ahead is in `lib/sim/digital/driver.zig`. No change.
- **Measure impact**: none.

### VD-030: `$simprobe` with a name built at run time
- **Status**: DONE (b5689fbb)
- **Source**: `conformance-ch9-review.md:313-316`.
- **Rule**: VAMS 9.16: "The arguments inst_name and param_name are string values, either a string literal, string parameter, or a string variable." Also: "If either the inst_name or param_name cannot be resolved, and the optional expression is not supplied, then an error shall be generated. If the optional expression is supplied, its value will be returned in lieu of raising an error."
- **Why vague**: a string variable's value is known only at run time. The clause does not say whether a tool may treat a name it cannot fold at compile time as "cannot be resolved" and return the fallback.
- **Options**: (a) resolve at run time against the sibling's output variables; (b) treat a non-constant name as unresolved and return the fallback, which is VerA today; (c) refuse a non-constant name with a named implementation-limit diagnostic.
- **Decision**: `DECIDED:` (a) is the reading of the clause. Until VerA implements it, (c) applies. "Cannot be resolved" is about whether the name exists, not about when the tool learns it, so returning the fallback for a valid run-time name gives a wrong answer with no diagnostic. A refusal that names the limit is better (AGENTS.md §4, "never open a gate without an executor").
- **VerA today**: `src/analog/hier_name.zig` (the `$simprobe` lowering, around :360-395) resolves only names that `constStrArg` folds. Otherwise it returns the third argument silently. With no third argument it reports E0817 "names no parameter of the elaborated design", which is misleading for a valid run-time name. CHANGE NEEDED: when either name does not fold, refuse with a dedicated diagnostic citing 9.16 ("a run-time $simprobe name is not supported"), whether or not a fallback is given, and record it as a limit in Vague_Decisions.md §7. Add a rejection fixture (a string variable name with a fallback) with a legal string-parameter neighbour. Semver: minor (VerA newly refuses source).
- **Measure impact**: A (+2 fixtures); C (9.16, refusal with a legal neighbour; the clause stays partial until (a) exists).

### VD-031: `$table_model` duplicate abscissa that cannot be proved equal
- **Source**: `MANIFEST.md:529-532` at 8b1514d4.
- **Rule**: VAMS 9.21: "Within the data set, each point shall be distinct in terms of its independent variable values. If there are two or more data points with the same independent and dependent values, then the duplicates shall be ignored ... If there are two or more data points with the same independent values but different dependent values then an error is generated."
- **Why vague**: the clause does not say when the error is diagnosed. A tool might refuse at elaboration any duplicate abscissa whose dependents it cannot prove equal.
- **Options**: (a) refuse at elaboration whenever equality is unproven; (b) refuse at elaboration only a proven conflict and check the rest when the data is captured (9.21.1, first call); (c) always check at capture.
- **Decision**: `DECIDED:` (b) and (c) both conform, and (a) does not. Under (a), a table whose duplicates turn out identical is refused, even though the clause says those duplicates "shall be ignored". Refusing at compile time is allowed only when both dependents fold and differ. Every other case is checked when the data source is captured.
- **VerA today**: (c). The conflict is checked at the call (`lib/backend/kernels/table_kernels.zig:447-463`, `ztDuplicateError`), and identical duplicates are dropped. `ch09_system_tasks/duplicate_points.va` makes the conflicting dependent `94.0 + V(p,n)` so that no tool can decide it at elaboration. No change.
- **Measure impact**: none.

### VD-032: What counts as a change of a real value (0.0 to -0.0, NaN)
- **Source**: `conformance-wreal.md:15`, WR-006.
- **Rule**: VAMS 3.7 (wreal is a net, and 1.1 inherits 1364). IEEE 1364-2005 9.7.2: "An implicit event shall be detected on any change in the value of the expression." IEEE 1364-2005 6.1.2: "If the new value is different from the previous value, then the new value shall be assigned".
- **Why vague**: 1364 defines "change" for four-state bits only. For a real, "different" could be an IEEE 754 `!=` or a bit-pattern compare. The two differ for ±0, where `==` is true but the bits differ, and for NaN, which is unequal to itself.
- **Options**: (a) IEEE 754 `!=`: ±0 is no change, and a NaN written over a NaN is a change; (b) a bit compare.
- **Decision**: `DECIDED:` (a). It is the language's own real `!=` (1364 4.1.7), so `@(w)` fires exactly when `w != old` would be true in source. "Not a change" governs events only. The variable or net still holds the new bit pattern, so `1.0/w` after writing `-0.0` is `-inf`.
- **VerA today**: events follow (a) (`lib/sim/digital/waiters.zig:134-137`; `tests/fixtures/digital/wreal_event_on_change.v`). The new bits are copied only `if (changed)` (waiters.zig:140), so writing `-0.0` over `+0.0` leaves `+0.0` stored. CHANGE NEEDED: store the planes whenever they differ bitwise, and suppress only the event. Add a `.v` fixture: `r = 0.0; r = -0.0; $display("%g", 1.0/r)` prints `-inf`, and `@(r)` stays silent. Semver: patch (runtime value fix; no accepted/refused source or device text changes).
- **Measure impact**: B (1364 9.7.2 / 4.1.7 evidence); `test-devices` +1 case.
- **Status**: DONE (0db0a690; native_real_events corrected in d9ee5d65).

### VD-033: `m04_01` samples a declaration-assigned wreal at time 0
- **Source**: `conformance-wreal.md:29-34`.
- **Rule**: VAMS 3.7: "wreal nets shall have an initial value of zero." IEEE 1364-2005 11.3 (event regions): "Active events occur at the current simulation time and can be processed in any order." Those active events include a net declaration assignment's first evaluation and an `initial` block.
- **Why vague**: at time 0, `wreal seeded = 2.5;` reads 0.0 until its continuous assignment has run. An `initial` that `$display`s it at time 0 races with that assignment.
- **Options**: (a) keep the fixture's time-0 `2.5` expectation; (b) sample after `#0` (inactive region), when every active continuous-assignment update has been applied.
- **Decision**: `DECIDED:` (b). The fixture as written fails a conforming tool that runs the `initial` first and prints `0`. The undriven-wreal and plain-wire lines have no race and stay at time 0.
- **VerA today**: `tests/fixtures/digital/wreal_undriven_zero.v` prints `decl_assigned_wreal_at_time_zero 2.5` from the first statement of the `initial`, with no delay, and VerA happens to order it after the assignment. CHANGE NEEDED (fixture only): put `#0;` before the `seeded` time-0 display (the two race-free lines may stay before it), and record the race in the header. Semver: patch (test only).
- **Status**: DONE (4b6c96d8). `#0;` precedes the `seeded` display in `tests/fixtures/digital/wreal_undriven_zero.v`; header records the race. Transcript unchanged.
- **Measure impact**: none (a `test-devices` transcript; the expected output text is unchanged).

### VD-034: `posedge V(p)` in an analog event control
- **Source**: `annex_c_analog_subset/COVERAGE.md:192-196`.
- **Rule**: VAMS 5.10, Syntax 5-13: `analog_event_expression ::= expression | posedge expression | negedge expression | ...`. VAMS 5.10.5: "analog behavior can be made sensitive to digital events, including posedge events, negedge events". VAMS 7.3.6.2 times the "digital event, such as posedge or negedge".
- **Why vague**: the grammar derives `posedge` with any operand, including a continuous `V(p)`, but no sentence gives an edge of a continuous signal a meaning. 1364 9.7.2 defines edges only as four-state transitions (0 to 1, x, z and so on).
- **Options**: (a) refuse an edge whose operand is not discrete; (b) define it as a `cross` with direction ±1 at some threshold; (c) apply 1364's real-to-bit conversion to the operand.
- **Decision**: `DECIDED:` (a). 5.10.5 and 7.3.6.2 place `posedge`/`negedge` among the digital events, and the analog way to detect an edge is `cross` (5.10.3.1), which has a threshold and tolerances that a bare edge cannot express. Options (b) and (c) would each invent a threshold the standard never gives. A grammatical construct with no semantics is refused by name rather than given an invented meaning.
- **VerA today**: E0704 "posedge/negedge is digital-only" (`src/analog/event.zig:191-193`, `lib/diag/code.zig:4781`). `annex_c_analog_subset/digital_event_control_rejected.va` and `ch07_mixed_signal/contribution_under_a_digital_event_rejected.va` pin it, and the legal digital-operand neighbour is `ch07_mixed_signal/posedge_in_an_analog_event_control.va`. No change.
- **Measure impact**: none.

### VD-035: A module-level `string` variable
- **Source**: `annex_a_syntax/COVERAGE.md:349-358`.
- **Rule**: VAMS A.2.8: `string_declaration` appears only as an arm of `analog_block_item_declaration`. A.2.1.3's `module_or_generate_item_declaration` does not list it. VAMS 3.3 gives "string variable_name [ = initial_value ] ;" and the example `parameter string default_name = "John Smith"; string myName = default_name;`.
- **Why vague**: Annex A derives no module-level string variable, while 3.3 grants one, and 3.3's example places it at module level next to a parameter.
- **Options**: (a) legal (3.3 governs, and the Annex A omission is a defect); (b) refused per Annex A.
- **Decision**: `DECIDED:` (a). 3.3 is the normative clause that introduces the type, and its example cannot be written inside a block. `real` and `integer` variables are module items, and nothing in the text suggests `string` is meant to be different. Refusing would reject the standard's own example.
- **VerA today**: accepted. `annex_a_syntax/declarations.va` writes `string label = "declarations";` at module level. No change.
- **Measure impact**: none.

### VD-036: An undefined escape such as `"\q"`
- **Source**: `conformance-ams-lexical-core-review.md:170-172`; that file has 82 lines at 8b1514d4, so the cited lines no longer exist.
- **Rule**: VAMS 2.7 / Table 2-2 lists `\n`, `\t`, `\\`, `\"` and `\ddd` only. IEEE 1364-2005 3.6.3, Table 3-1, lists the same five.
- **Why vague**: neither standard says what a backslash followed by any other character means, or whether it is an error.
- **Options**: (a) error; (b) accept, drop the backslash and keep the character; (c) accept and keep both bytes; (d) (b) plus a warning.
- **Decision**: `DECIDED:` (d). The source is lexically a string under A.8.8, so refusing it would reject models that write `"\%"` or similar by habit. Dropping the backslash is the C-family convention and keeps the literal's visible text. Since the meaning is VerA's choice and other tools may differ, a warning names it, so a portability hazard is never silent. What IEEE 1800, Icarus and VCS do with an undefined escape was not established here.
- **VerA today**: (b) with no diagnostic (`lib/frontend/lexer.zig:551-556`, "undefined escapes pass through"). No fixture pins it, and Vague_Decisions.md §6 has no row. CHANGE NEEDED: add a named warning for an escape outside Table 2-2. Add `ch02_lexical/` fixture `//! warn <code>` with `CHECKI("\q", 113)`, and an Vague_Decisions.md §6 row. Semver: patch (warning only; acceptance and device text unchanged).
- **Measure impact**: A (+1 fixture); none of B/C (implementation-defined, AGENTS.md: "a fixture here tests VerA's choice").
- **Status**: DONE (dac6eb2b): W0149, `ch02_lexical/undefined_escape_keeps_character.va`; `string_escapes.va` (`//! nowarn`) is the neighbour that warns nothing.

## 3. Readings the standards leave open: IEEE 1364 and VPI

### VD-037: A signed x/z operand under bitwise and conditional operators
- **Source**: `conformance-ieee-expression-width-review.md` at 8b1514d4, "Source tensions".
- **Rule**: IEEE 1364-2005 5.5.4: "If any bit of a signed value is X or Z, then any nonlogical operation involving the value shall result in the entire resultant value being an X". Against 5.1.10 (bitwise truth tables) and 5.1.13 / Table 5-21 (ambiguous condition results).
- **Why vague**: "nonlogical" is not defined. Read broadly, it covers `&`, `|`, `^` and `?:`, which would make `4'sb10x1 & 4'sb0000` all x even though 5.1.10's bit tables give 0000. The bitwise and conditional clauses give bit-by-bit rules and do not mention signedness.
- **Options**: (a) all x for every non-logical operator, bitwise and conditional included; (b) arithmetic, relational and resizing operations get all x, while bitwise, reduction and conditional operators keep their per-bit tables.
- **Decision**: `DECIDED:` (b). The specific clauses (5.1.10's tables, 5.1.13's Table 5-21) govern their operators. 5.5.4 sits in 5.5 "Signed expressions", whose subject is evaluating arithmetic in a signed type. Its first two sentences cover resizing, so its third sentence covers arithmetic on that resized value. A bitwise operator works on bits, and signedness does not change those bits. Under (a), `0 & x` would give a different answer depending only on whether the operand was declared signed, and nothing else in Clause 5 depends on signedness that way. Icarus/VCS behaviour: not established.
- **VerA today**: Bitwise operators use the bit tables with no signedness check (`lib/sim/digital/evaluate.zig:584`). An x/z condition combines both arms through Table 5-21 (`evaluate.zig:602`). Arithmetic gives all x (`ieee1364/05_expressions/signed_unknown_bits.v`, `expr_unknown_extension.v`). No fixture pins a signed bitwise or conditional case. `CHANGE NEEDED:` add a positive `.v` fixture, for example `4'sb10x1 & 4'sb0000` -> `0000`, `4'sb10x1 | 4'sb0000` -> `10x1`, and `1'bx ? 4'sb10x1 : 4'sb10x1` -> `10x1`. Fixture only, so a patch.
- **Status**: DONE (4b6c96d8). `tests/fixtures/ieee1364/05_expressions/signed_unknown_bitwise.v` pins `&`, `|`, `^`, `~` and an x-condition `?:` on `4'sb10x1`. VerA agrees with the decision.
- **Measure impact**: B: adds positive evidence to 5.5.4 (already `no-prohibition`), so no verdict change. A: +1 fixture.

### VD-038: Delay rule for a singleton `[0:0]` vector continuous assignment
- **Source**: `conformance-vector-delay-fix.md` at 8b1514d4.
- **Rule**: IEEE 1364-2005 6.1.3: "If the left-hand references a scalar net, then the delay shall be treated in the same way as for gate delays", and "If the left-hand references a vector net, then up to three delays can be applied" (nonzero-to-zero falling, to z turn-off, otherwise rising). 4.3 (p. 28): "A net or reg declaration without a range specification shall be considered 1 bit wide and is known as a scalar. Multibit net and reg data types shall be declared by specifying a range, which is known as a vector."
- **Why vague**: `wire [0:0] w` is declared with a range, which suggests vector, but it is 1 bit wide, not "multibit". The two rules differ on a transition to x: the gate rule takes the minimum delay, the vector rule takes the rising delay.
- **Options**: (a) the declaration decides: any range makes it a vector; (b) the width decides: 1 bit takes the scalar (gate) rule.
- **Decision**: `DECIDED:` (b), width. 4.3 defines a vector by being "Multibit", and declaring a range is only how multibit nets are written. IEEE 26.6.5 (Ports, detail c) uses the same test: "vpiScalar and vpiVector shall indicate if the port is 1 bit or more than 1 bit". A 1-bit net has exactly one bit to which gate rise/fall/x/z semantics apply, so the vector rule's coarse "all other cases rising" approximation is not needed.
- **VerA today**: The driver metadata records width only, and width 1 keeps the scalar rule. This is already the decision (`conformance-vector-delay-fix.md` at 8b1514d4: "width1 keeps the scalar rule"). It is uncredited because no fixture covers `[0:0]`. `CHANGE NEEDED:` add a positive fixture with `wire [0:0] w; assign #(7,5,2) w = r;` where 0 -> x waits min = 2, next to a `wire [1:0]` neighbour where the same transition waits 7. Fixture only, so a patch.
- **Status**: DONE (4b6c96d8). `tests/fixtures/ieee1364/06_assignments/one_bit_range_delay.v`: `[0:0]` goes to x after min = 2, the `[1:0]` neighbour after rising = 7. VerA agrees.
- **Measure impact**: B: 6.1.3 gains a pinned case. A: +1 fixture.

### VD-039: A `config` declaration inside a lib.map file
- **Source**: the two clauses quoted under **Rule**.
- **Rule**: IEEE 1364-2005 13.2.2: "The syntax of a lib.map file is limited to library specifications, include statements, and standard Verilog comment syntax." Against A.1.1 / Syntax 13-2: `library_description ::= library_declaration | include_statement | config_declaration`.
- **Why vague**: The prose excludes configs from a map file, but the grammar derives one there.
- **Options**: (a) follow the grammar and accept a config in a map; (b) follow the prose and refuse it.
- **Decision**: `DECIDED:` (b). The prose is the specific normative statement about lib.map files. The grammar box is a superset that also serves `library_text` in general. 13.3 places configs in source text, where they are design elements (19.11 lists "module, primitive, or configuration" as design elements). Refusing loses nothing portable, since the config can move to a source file, while accepting it would create map files other tools may reject. Other tools: not established.
- **VerA today**: `lib/frontend/libmap.zig:161` refuses any keyword other than `library`/`include` with E0244 ("a library map holds `library` and `include` statements only (IEEE 1364-2005 §13.2.2)"). Pinned for a `module` by `ieee1364/13_configuration/source_text_in_map_rejected.v`, with legal neighbour `include_map.v`. No fixture puts a `config` in a map. `CHANGE NEEDED:` add a rejection fixture whose map holds `config cfg; design work.top; endconfig`, `//! reject E0244` and `found \`config\``. Fixture only, so a patch.
- **Measure impact**: B: 13.2.2 rejection evidence for the contested construct. A: +1 fixture.
- **Status**: DONE (14cd4397). `ieee1364/13_configuration/config_in_map_rejected.v` over `libmap/bad/config_in_map.map`.

### VD-040: A `$readmem` file address outside the memory when the task gives no bounds
- **Source**: `conformance-readmem-validation-edges.md:66-70` at 8b1514d4.
- **Rule**: IEEE 1364-2005 17.2.9: "When addressing information is specified both in the system task and in the data file, the addresses in the data file shall be within the address range specified by the system task arguments; otherwise, an error message is issued, and the load operation is terminated."
- **Why vague**: The error rule applies only when the task call also gives addresses. With no task bounds, `@8` into `reg [7:0] m[0:3]` matches no rule.
- **Options**: (a) silently drop the words; (b) treat the declared range as the implied range and apply the error, terminating the load; (c) warn, drop the out-of-range words, and keep loading at later in-range addresses.
- **Decision**: `DECIDED:` (c). A named run-time warning gives the address and the declared range, and words outside the declaration are skipped. (b) would extend an error rule the text explicitly conditions on task arguments, which would turn a run that is legal by the letter into a failure. (a) is a wrong answer with no diagnostic. The clause already uses a warning for the closest sibling case: "A warning message shall be issued if the number of data words in the file differs from the number of words in the range". Other tools: not established.
- **VerA today**: `lib/sim/digital/display.zig:215` drops a word outside `low..high` with no message. `mismatch` (`:229`) is suppressed once the file has an address, so the case is entirely silent. `CHANGE NEEDED:` warn (a new W11xx or a W1150 variant) the first time an unbounded load's file address falls outside the declared range. Add a fixture `reg [7:0] m[0:3]` + `@8` that expects the warning and expects in-range words still loaded. Patch: no source acceptance or device text changes; a run-time warning appears.
- **Measure impact**: B: 17.2.9 (currently `-`) gains a pinned edge. A: +1 fixture.
- **Status**: DONE (418338cf).

### VD-041: x, z and `_` in a `$readmem` file address
- **Source**: `conformance-readmem-validation-edges.md` at 8b1514d4.
- **Rule**: IEEE 1364-2005 17.2.9: "the format is an at character (@) followed by a hexadecimal number ... @hh...h". For data words: "The unknown value (x or X), the high-impedance value (z or Z), and the underscore (_) can be used in specifying a number as in a Verilog HDL source description." 3.5.1: "The underscore character (_) shall be legal anywhere in a number except as the first character."
- **Why vague**: The x/z/_ permission is stated for data numbers. Addresses are "a hexadecimal number" with no statement either way.
- **Options**: (a) accept x/z/_ in addresses as in data; (b) accept `_` only, under 3.5.1; (c) hex digits only.
- **Decision**: `DECIDED:` (b). An address names one word, and an x or z address names none, so refuse it with the malformed-address error. An address is still "a hexadecimal number", and 3.5.1 makes `_` legal anywhere but first, including last. That gives: `@1_0` and `@10_` are legal, `@_10`, `@x` and `@?` are malformed.
- **VerA today**: `lib/sim/digital/display.zig:192` parses with `std.fmt.parseInt(i64, .., 16)`. Measured 2026-10-04: `1_0` -> 16 and `1__0` -> 16 are accepted, `_10`, `x` -> InvalidCharacter, but **`10_` -> InvalidCharacter**, which 3.5.1 allows. Pinned: `ieee1364/17_system_tasks/readmem_edge_address_bad_digit_rejected.v` (`@g`). `CHANGE NEEDED:` accept a trailing `_` in an address (strip underscores after the first character before parsing). Add fixtures: `@x` rejected (malformed address), and `@1_` legal next to it. Patch.
- **Measure impact**: B: 17.2.9 two-way evidence on address spelling. A: +2 fixtures.
- **Status**: DONE (22fb2c50).

### VD-042: Extended VCD strength 5, "large" or "pull"
- **Source**: `conformance-vcd-review.md:137`, EVCD-017.
- **Rule**: IEEE 1364-2005 18.4.3.2: "Strength supply 7 to 5 (large): strong strength / Strength 4 to 1: weak strength". 18.4.3's list: "4 large, 5 pull, 6 strong, 7 supply".
- **Why vague**: The parenthetical calls 5 "large", while the numeric list makes 5 pull and 4 large.
- **Options**: (a) the numbers rule: 5..7 (pull, strong, supply) is the strong range and 1..4 weak; (b) the name rules: large (4) joins the strong range.
- **Decision**: `DECIDED:` (a). The boundary is given numerically twice ("7 to 5", "4 to 1"), and the label is a slip. 18.4.3.2 also limits drivers to "primitives, continuous assignments, and procedural continuous assignments", which drive only the 7.9 driving strengths (supply, strong, pull, weak). large is a trireg charge strength (Table 7-7) and can never appear as a driver's strength, so the name reading has nothing to apply to.
- **VerA today**: `lib/sim/digital/evcd.zig:392-393` uses `>= 5`, the decision. The unit test `evcd.zig:426` covers only strong (6) against weak (3), and no case sits on the 5/4 boundary. `CHANGE NEEDED:` add a pull-vs-weak case to that test (`portState(.inout, pull0, weak0)` -> `d`) or to `ieee1364/18_vcd/port_value_changes.v`. Test only, so a patch.
- **Status**: DONE (4b6c96d8). `tests/fixtures/ieee1364/18_vcd/port_value_changes.v` gains a #6 step: weak 0 in, pull 0 out -> `pl 5 0`. VerA agrees.
- **Measure impact**: B: 18.4.3.2 boundary pinned. Otherwise none.

### VD-043: Does `` `resetall `` reset `` `begin_keywords ``?
- **Source**: `d10_SPEC.md:192-194` at 8b1514d4.
- **Rule**: IEEE 1364-2005 19.6: "When `resetall compiler directive is encountered during compilation, all compiler directives are set to the default values." 19.11: "Each `begin_keywords directive must be paired with an `end_keywords directive. The pair of directives define a region of source code".
- **Why vague**: "all compiler directives" would include the keyword version, but 19.11 defines `` `begin_keywords `` as a paired, nested region. A reset in the middle would leave the following `` `end_keywords `` unmatched.
- **Options**: (a) `` `resetall `` pops the keyword stack to the default; (b) the keyword region is unaffected.
- **Decision**: `DECIDED:` (b). 19.11 says "The `begin_keywords and `end_keywords directives only specify the set of identifiers that are reserved as keywords", and the reserved set holds "until the matching `end_keywords directive is encountered". A region closed only by its matching directive is not a directive setting with a "default value". Under (a), 19.6's recommended usage ("place `resetall at the beginning of each source text file") inside a `` `begin_keywords "1364-1995" `` region would break the pairing rule. VAMS 10.6 inherits this.
- **VerA today**: The parser skips `` `resetall `` at file level (`lib/frontend/parser/source.zig:70`), and the keyword stack (`source.zig:64`, `keywordsDirective`) is untouched. That is the decision, but no fixture pins it. `CHANGE NEEDED:` add a positive fixture: `` `begin_keywords "1364-1995" `` / `` `resetall `` / a module using `uwire` (2005-only) as an identifier / `` `end_keywords ``, compiles. Fixture only, so a patch.
- **Measure impact**: B: 19.6 and 19.11 (both `-`) gain a pinned interaction. A: +1 fixture.
- **Status**: DONE (ead894ee): `ieee1364/19_compiler_directives/resetall_keeps_begin_keywords.v` (uwire under "1364-1995" across a `` `resetall ``); `uwire_in_2005_rejected.v` is the refusal it would hit.

### VD-044: Walking the design inside `vlog_startup_routines`
- **Source**: `conformance-ieee-vpi-interface-review.md:24-31` at 8b1514d4.
- **Rule**: IEEE 1364-2005 26.2.4: "when the routines within the vlog_startup_routines[ ] array are executed, there is very little functionality available. Only two routines can be called at this time: vpi_register_systf() [and] vpi_register_cb()". VAMS 12.33.2 (= IEEE 27.34.2): "A means of initializing system task/function callbacks and performing any other desired task just after the simulator is invoked shall be provided by placing routines in ... vlog_startup_routines."
- **Why vague**: "any other desired task" reads as permission, while 26.2.4 restricts the same phase. The same sentence appears in IEEE 27.34.2, so the clash is inside 1364, not an AMS relaxation. VAMS 12.33.2 adds "This array of C functions shall be for registering system tasks and functions."
- **Options**: (a) allow every routine at startup (VerA today); (b) require phase-correct applications (register at startup, walk at `cbEndOfCompile`/`cbStartOfSimulation`), and have VerA refuse other routines during startup with an error status.
- **Decision**: `DECIDED:` (b). 26.2.4 is the specific rule for the phase. "Any other desired task" is satisfied by registering a callback that runs the task later, which is exactly what VAMS's own example does (`setup_report_cpu` registers a callback). A fixture that walks at startup passes only on tools that build the model early, so it is not portable. VerA should make the misuse visible: in the startup phase, any routine other than `vpi_register_systf`/`vpi_register_cb` (and `vpi_chk_error`) fails with a named `vpi_chk_error` message citing 26.2.4, and `vpi_register_cb` accepts only the four reasons listed there.
- **VerA today**: `src/vpi/root.zig:697` (`runStartupRoutines`) runs the array after the model is built, and every routine works. `tests/fixtures/ch11_vpi/vpi_app.c:501` does its whole walk in `vlog_startup_routines`. Of 77 `.c` fixtures, 42 mention `cbEndOfCompile`/`cbStartOfSimulation`, and the rest work at startup (not each re-read). `CHANGE NEEDED:` (1) move every `.c` fixture's work into a `cbEndOfCompile`/`cbStartOfSimulation` callback; (2) add a startup-phase gate in `src/vpi/root.zig` with an `lrm-reject`/`inherited-reject IEEE 1364-2005 26.2.4` fixture whose legal neighbour is `ieee_pli/systf.c`; (3) reclassify the 26.2.4 row in `ieee1364/CLAUSES.tsv` from `unspecified`. By AGENTS.md §3's list this is a patch (no source, device text or module_specs change), but it makes previously working applications fail, so release it as a minor.
- **Status**: DONE (9425251f). `src/vpi/root.zig` `refused` turns every routine but `vpi_register_systf`, `vpi_register_analog_systf`, `vpi_register_cb` and `vpi_chk_error` away during the startup routines (code `STARTUP`, citing 26.2.4); `vpi_register_cb` takes only cbEndOfCompile, cbStartOfSimulation, cbEndOfSimulation, cbError and cbPLIError there. Every `.c` fixture defers its work to cbEndOfCompile; `ieee_pli/startup_phase.c` pins both sides; 26.2.4 is `-` in `CLAUSES.tsv`. The entry's "four reasons" are six in the clause (cbError and cbPLIError follow a page break).
- **Measure impact**: B: 26.2.4 gains two-way evidence. C: AMS 12.33.2 fixtures become portable. A: every `vpi_runs` fixture touched.

### VD-045: `vpiIsProtected` (prose) vs `vpiProtected` (Annex G)
- **Source**: the two clauses quoted under **Rule**.
- **Rule**: IEEE 1364-2005 26.3.5: "All objects have a vpiIsProtected property ... Access to the vpiType property and the vpiIsProtected property of a protected object shall be permitted for all objects." Annex G vpi_user.h: `#define vpiProtected 10 /* source protected module (boolean) */`, and there is no `vpiIsProtected`. 26.6.1 lists `vpiProtected` as a module property.
- **Why vague**: The property every object must answer has no number in the normative header. The only number belongs to a differently named module property.
- **Options**: (a) leave it undefined and answer only on modules; (b) invent a new constant; (c) treat `vpiIsProtected` as `vpiProtected` (10) and answer it on every object.
- **Decision**: `DECIDED:` (c). Annex G is the ABI, and a made-up number (b) would make applications non-portable. A module "in a decryption envelope" is exactly a "source protected module", so the two coincide where both apply, and (c) makes 26.3.5's "all objects" true. VerA refuses `pragma protect` (E0146), so every object answers FALSE.
- **VerA today**: `src/vpi/vpi_user.h:381` defines `vpiProtected 10`. `src/vpi/property.zig:158-161` answers 0 for modules and `propFail`s every other kind. `CHANGE NEEDED:` add `#define vpiIsProtected vpiProtected` (with a comment citing 26.3.5/Annex G) to `vpi_user.h`. Make `property.zig` answer 0 for every object kind. Add a `.c` fixture asserting `vpi_get(vpiIsProtected, h) == 0` on a net, a reg, a port and a module, and move the 26.3.5 `CLAUSES.tsv` row off `not-supported` for its FALSE half. Patch by AGENTS.md §3 (VPI result, not source or device text).
- **Status**: DONE (2b569378). `vpi_user.h` defines `vpiIsProtected` as `vpiProtected`; `vpi_get` answers 0 for every live handle and refuses a non-object. `ieee_pli/protected.c`; 26.3.5 is `-` in `CLAUSES.tsv`.
- **Measure impact**: B: 26.3.5 `not-supported` -> partial/verified for the FALSE half.

### VD-046: Is the current time queue in a `vpiTimeQueue` iteration?
- **Source**: `conformance-ieee-vpi-objects-review.md:179-186` at 8b1514d4.
- **Rule**: IEEE 1364-2005 26.6.40(c): "The current time queue shall only be returned as part of the iteration if there are events that precede read only sync." VAMS 11.6.25 NOTE 5: "If any events after read only sync remain in the current queue, then it shall not be returned as part of the iteration."
- **Why vague**: The two conditions differ when the current time holds both an active-region event and a `cbReadOnlySynch`. IEEE returns the queue, while VAMS read literally does not.
- **Options**: (a) IEEE: return the queue iff some pending current-time event precedes read-only sync; (b) VAMS literal: omit the queue iff any read-only-sync-or-later item is pending.
- **Decision**: `DECIDED:` (a). It is the positive form of the source rule that VAMS paraphrases. Both agree that a current queue holding only read-only-sync work is omitted, and (a) answers the mixed case the useful way: the simulator still has work to do at this time. Read NOTE 5 as "if only events after read only sync remain".
- **VerA today**: `src/vpi/run.zig:313-343` (`timeQueues`) keeps `t == clock` whenever any scheduler event or time callback is pending at the current time. `src/vpi/callback.zig:187` counts `cbReadOnlySynch` (and `cbReadWriteSynch`) as time callbacks, so a lone pending `cbReadOnlySynch` puts the current queue in the iteration, which is wrong under both readings. `ch11_vpi/cb_time_regions.c` asserts only times strictly greater than now. `CHANGE NEEDED:` at `t == clock`, count only scheduler events and pre-read-only callbacks (`cbReadWriteSynch`), not `cbReadOnlySynch`. Add a `.c` case for each side: only RO-sync pending, so the current queue is absent; an active event pending, so it is present. Patch.
- **Status**: DONE (65687d0f). `callback.pendingTimes` skips a cbReadOnlySynch due at the current time. `ch11_vpi/cb_time_regions.c` walks at t=7 both ways (mixed case: t=7 returned; only RO sync left: first queue t=10).
- **Measure impact**: B: 26.6.40 (`-`) gains evidence. C: VAMS 11.6.25 NOTE 5 pinned.

### VD-047: A callback wake-up at an eventless time is a `vpiTimeQueue` entry
- **Source**: `p02_SPEC.md:382-395` at 8b1514d4.
- **Rule**: VAMS 11.6.25 NOTE 4: "vpi_iterate() shall return NULL if there is nothing left in the simulation queue", and the diagram relates callback to time queue (`vpiParent`). VAMS 12.31.2: "A callback can be set for any time, even if no event is present."
- **Why vague**: No sentence says whether a time that holds only a callback is a time queue.
- **Options**: (a) yes, a time callback is a scheduled wake-up and its time is a queue; (b) only HDL events make a queue.
- **Decision**: `DECIDED:` (a). The simulator must stop at that time to run the callback, so it is in "the simulation queue". The data model gives a callback a time-queue parent, which (b) would leave dangling. Other tools: not established.
- **VerA today**: Matches. `src/vpi/callback.zig:557` (`pendingTimes`) feeds `run.zig:322`. `ch11_vpi/cb_time_regions.c` asserts the t=33 entry. No change.
- **Measure impact**: none.

### VD-048: `vpi_mcd_printf`'s return value for a multi-channel write
- **Source**: `p02_SPEC.md:341-343` at 8b1514d4.
- **Rule**: VAMS 12.27 / IEEE 1364-2005 27.26: "Returns: PLI_INT32 The number of characters written." and "Several channels can be written to simultaneously".
- **Why vague**: For an mcd with k channels, the characters "written" could be one expansion or k times it.
- **Options**: (a) the length of the formatted text, once; (b) the length times the number of channels written.
- **Decision**: `DECIDED:` (a). The routine is defined as the C `fprintf` analogue ("A format string using the C fprintf() format"). Its count describes the message, so a caller can compare it with its own `vsnprintf` length whatever the mcd. Under (b), the same call returns different values as files open and close. A failed channel is reported through EOF and `vpi_chk_error`, not through the count.
- **VerA today**: Matches. `src/vpi/print.zig:746` expects 6 for `"alpha\n"` to two channels, `print.zig:751` expects EOF on failure, and `ch11_vpi/printf_mcd.c` covers it. No change.
- **Measure impact**: none.

### VD-049: `vpiIntVal` read of an object wider than 32 bits
- **Source**: `p02_SPEC.md:426-427` at 8b1514d4.
- **Rule**: VAMS 12.16 Table 12-4 / IEEE 1364-2005 27.14: "vpiIntVal ... Integer value of the handle. Any bits x or z in the value of the object are mapped to a 0". `value.integer` is `PLI_INT32`.
- **Why vague**: Nothing says what a 64-bit `time` or `reg [63:0]` gives when it does not fit in a `PLI_INT32`.
- **Options**: (a) the low 32 bits, two's complement; (b) an error (`vpiBadFormat`); (c) saturate.
- **Decision**: `DECIDED:` (a). This is the language's own rule for putting a wide value in a 32-bit integer: IEEE 5.6, where truncation of the high bits happens without a diagnostic. It is also how the integer-valued C fields are documented, and `vpiVectorVal`/`vpiTimeVal` remain for the full value. (b) would refuse reads of every `time` variable.
- **VerA today**: `src/vpi/value.zig:321` does `@truncate(b.low64())` to u32 and bitcasts it, which matches the decision. No fixture asserts it. `CHANGE NEEDED:` add a `.c` assertion: `reg [63:0] r = 64'h1_8000_0001` reads `vpiIntVal == (PLI_INT32)0x80000001`. Patch.
- **Status**: DONE (94512505). `ch11_vpi/get_value_formats.c` reads `reg [63:0]` 64'h00000001FFFFFFFF as vpiIntVal: -1. VerA already agreed.
- **Measure impact**: B/C: 27.14 / 12.16 gain a pinned edge.

### VD-050: `$q_exam` with a `q_stat_code` outside Table 17-15
- **Source**: `conformance-ieee-queue-review.md:26-47` at 8b1514d4, which cites "17.6.4"; `$q_exam` is IEEE 1364-2005 17.6.5 and its status table is 17.6.6.
- **Rule**: IEEE 1364-2005 17.6.5, Table 17-15 defines codes 1-6. 17.6.6: "All of the queue management tasks and functions return an output status code", and Table 17-16 (0-7) has no "bad statistic code" row.
- **Why vague**: An unknown code has no defined status and no defined value.
- **Options**: (a) status 2 "Undefined q_id"; (b) a new status 8; (c) status 0 with no value; (d) refuse a constant out-of-range code at compile time and give a nonzero status at run time.
- **Decision**: `DECIDED:` (d). A constant `q_stat_code` outside 1..6 is refused with a named diagnostic citing Table 17-15. A run-time value outside it returns status 2 and leaves `q_stat_value` unchanged. 2 is the nearest Table 17-16 row (the request names nothing the queue defines), it stays inside the table every portable caller checks, and a nonzero status is the observable failure. (b) invents a code no other tool knows. (c) reports success for a request that has no answer.
- **VerA today**: `lib/sim/digital/system.zig:128` returns `undefined_id` (2) at run time for any other code and assigns no value (`out[1]` null). A constant bad code is not refused at compile time. `CHANGE NEEDED:` refuse a constant code outside 1..6 (E1100-style, citing Table 17-15), with a rejection fixture whose legal neighbour is `ieee1364/17_system_tasks/q_exam.v`. Add a run-time fixture (code from a variable = 7) expecting status 2 and an unchanged value. Minor (newly refused source).
- **Measure impact**: B: 17.6.5 (`-`) gains two-way evidence. A: +2 fixtures.
- **Status**: DONE (99a70532).

### VD-051: `$q_exam` code 3, "Maximum queue length"
- **Source**: `conformance-ieee-queue-review.md` at 8b1514d4.
- **Rule**: IEEE 1364-2005 17.6.5, Table 17-15: "3 Maximum queue length". The clause introduces the task as providing "statistical information about activity at the queue q_id".
- **Why vague**: "Maximum queue length" may mean the `max_length` given to `$q_initialize` or the largest length the queue has reached.
- **Options**: (a) the configured `max_length`; (b) the observed peak.
- **Decision**: `DECIDED:` (b). The task reports "statistical information about activity", and its siblings (codes 2, 4, 5, 6) are all measurements of history. The configured limit is an input the caller already passed and can read back through `$q_full`'s behaviour, so returning it would not be a statistic.
- **VerA today**: Matches: `system.zig:103` tracks `q.peak` and `:122` returns it. `ieee1364/17_system_tasks/queue_capacity_stats.v` cannot tell the readings apart (both are 2). `CHANGE NEEDED:` add a fixture with `max_length` 4 and a peak of 2 that expects 2. Fixture only, so a patch.
- **Measure impact**: B: 17.6.5 gains a discriminating case. A: +1 fixture.
- **Status**: DONE (259c554a).

### VD-052: `$q_exam` mean statistics (codes 2 and 6) in an integer result
- **Source**: `conformance-ieee-queue-review.md` at 8b1514d4.
- **Rule**: IEEE 1364-2005 17.6.5, Table 17-15: "2 Mean interarrival time", "6 Average wait time in the queue". No rounding rule is given. IEEE 1364-2005 3.5.3: "Real numbers shall be converted to integers by rounding the real number to the nearest integer, rather than by truncating it."
- **Why vague**: A mean is generally not an integer, but `q_stat_value` is an integer argument, and the clause gives no conversion.
- **Options**: (a) truncating integer division (VerA today); (b) the exact mean converted by the language's real-to-integer rule, rounding to nearest with ties away from zero.
- **Decision**: `DECIDED:` (b). When the language puts a non-integral value into an integer it rounds, and it says so explicitly "rather than by truncating it". Truncation is an artefact of computing in integers. An empty population (no interarrivals, no completed waits) stays 0.
- **VerA today**: `lib/sim/digital/system.zig:121` (`interarrival_sum / interarrivals`) and `:127` (`wait_sum / waits`) truncate. No fixture asks codes 2 or 6 (`q_exam.v` deliberately skips them). `CHANGE NEEDED:` compute `(2*sum + n) / (2*n)` (non-negative round half up, which equals ties away from zero here). Add a fixture whose mean is x.5 (for example, arrivals at 0, 2, 5 give a mean interarrival of 2.5, so 3). Patch (run-time value, no source or device text change).
- **Measure impact**: B: 17.6.5 statistics pinned. A: +1 fixture.
- **Status**: DONE (ca0e6529).

## 4. Implementation-defined choices: Verilog-AMS (Vague_Decisions.md §6)

### VD-053: Octal escape above `\377`
- **Source**: Vague_Decisions.md §6 row "AMS 2.7"
- **Rule**: VAMS 2.7, Table 2-2 (and IEEE 1364-2005 3.6.3, same text): "Implementations may issue an error if the character represented is greater than \377."
- **Why vague**: the clause permits an error and says nothing about what a tool that does not issue one should produce. `\400`..`\777` names no byte.
- **Options**: (a) accept and keep the low 8 bits silently (today); (b) accept with a warning; (c) refuse with a named error.
- **Decision**: `DECIDED:` (c), refuse with a named lexer error that cites §2.7. The clause itself offers the error. Any value VerA picks for a 9-bit escape is VerA's own invention, and keeping it silently is a wrong answer with no diagnostic. Source that is legal on every tool cannot use such an escape anyway, because some tool may refuse it, so refusing it costs portable designs nothing. Legal neighbour: `\377`.
- **VerA today**: `lib/frontend/lexer.zig:542-549` accumulates into a u16 and `@truncate`s with no diagnostic (the IMPLEMENTATION row cites 532-539, which is stale). `ch02_lexical/octal_escape_above_377_keeps_low_byte.va` pins the acceptance.
  `CHANGE NEEDED:` a new E01xx "octal escape above \377" diagnostic. Turn the fixture into `//! reject <code>` and add a `\377` legal neighbour. Update the IMPLEMENTATION row. **Minor**, because source that VerA accepted is now refused.
- **Measure impact**: A (the fixture flips to a rejection and a neighbour is added). C: §2.7 gains a pinned invalid form.
- **Status**: DONE (35e427ed): E0148, `ch02_lexical/octal_escape_above_377_rejected.va` and its neighbour `octal_escape_377_largest_byte.va`.

### VD-054: Identifier length limit
- **Source**: Vague_Decisions.md §6 row "AMS 2.8"
- **Rule**: VAMS 2.8: "Implementations may set a limit on the maximum length of identifiers, but the limit shall be at least 1024 characters."
- **Why vague**: the limit is the tool's choice, and an error is required only past whatever limit the tool sets.
- **Options**: a fixed limit of 1024 or more with an error past it; no limit.
- **Decision**: `DECIDED:` no limit. VerA stores identifiers as slices of the source, so no buffer imposes a bound. The only real ceiling is the filesystem's file-name length for build products, and `fileStem` hashes the name to get under it. No limit satisfies "at least 1024", and the error obligation never triggers.
- **VerA today**: `src/main.zig` `fileStem`; codegen's generated names (`src/ir/names.zig` `sanitizeAlloc`, `unitNameAlloc`) size their buffers from the name, so a name past the former 8192-byte buffer (`NameTooLong`) compiles too (#29; `codegen/plan/names.zig` test "a source name of any length plans", 9000 characters). Fixtures `ch02_lexical/identifier_1024_chars.va` and `identifier_1024_char_module_name.va`.
- **Measure impact**: none.

### VD-055: How the integer-modulus zero-divisor error is reported
- **Source**: Vague_Decisions.md §6 row "AMS 4.2.4"
- **Rule**: VAMS 4.2.4: "It shall be an error to pass zero (0) as the second argument to the modulus operator."
- **Why vague**: the clause gives no phase (compile or run time) and no form for the error. A compiled device has no I/O channel.
- **Options**: compile-time only, which misses runtime zeros; a runtime result such as 0 or the dividend, which is silent; a runtime report or trap.
- **Decision**: `DECIDED:` a divisor that is provably zero is E0601 at compile time. A zero found at run time is E0601 plus exit 1 in an executable, and a trap in a device with no host I/O. This is the only reading in which "shall be an error" is never silent. An operand that is never evaluated does not fail.
- **VerA today**: `src/prove/prover.zig`, `src/codegen/device/codegen/render.zig` `imodFn`, E0601 text at `lib/diag/code.zig:4526`. Fixtures `ch04_expressions/modulus_by_zero_rejected.va`, `modulo_integer_dynamic_zero.va`, `modulo_integer_unused_zero.va` and the legal neighbours. No change.
- **Measure impact**: none.

### VD-056: Real modulus by a runtime zero yields NaN
- **Status**: DONE (86e06853)
- **Source**: Vague_Decisions.md §6, the prose note under "Host math" ("Modulus with real operands retains its existing NaN behavior")
- **Rule**: VAMS 4.2.4: "It shall be an error to pass zero (0) as the second argument to the modulus operator." The same clause then gives the real-operand formula `a % b = ((a/b) < 0) ? ... : (a - floor(a/b)*b)`.
- **Why vague**: the error sentence names no operand type. The real formula divides by b, so IEEE arithmetic gives NaN, and that makes NaN look like an acceptable "defined" result.
- **Options**: (a) NaN at run time (today), with W0650 only for losing the finiteness proof; (b) the same runtime report or trap as the integer path.
- **Decision**: `DECIDED:` (b). The error sentence comes before the real formula and covers both types, and VerA already reads it that way at compile time: `real_modulus_zero_rejected.va` pins E0601 for `5.5 % 0.0`. Treating a runtime real zero differently from a compile-time one is a silent wrong answer, and a NaN in a Newton residual surfaces far from its cause.
- **VerA today**: E0601's explain text (`lib/diag/code.zig:4541-4542`) says "real `%`: x % 0.0 is NaN, IEEE-defined". `CHANGE NEEDED:` route a real `%` whose divisor is not provably nonzero through the same runtime E0601 report or trap as `imodFn`. Add a `modulo_real_dynamic_zero.va` rejection-at-run-time fixture beside a legal real-modulus neighbour. Update E0601's explain text and the IMPLEMENTATION note. **Minor**, because emitted device text changes.
- **Measure impact**: A (one new fixture). C: §4.2.4's real half becomes two-way at run time.

### VD-057: `idt` with no `ic`: the starting constant c
- **Source**: Vague_Decisions.md §6 row "AMS 4.5.4, 4.5.5"
- **Rule**: VAMS 4.5.4, Table 4-18: "c is the initial starting point as determined by the simulator and is generally the DC value (the value that makes expr equal to zero)". The prose adds that without ic "the idt operator must be contained within a negative feedback loop that forces its argument to zero. Otherwise the output of the idt operator is undefined."
- **Why vague**: c is left to the simulator, and the output is undefined when no loop exists.
- **Options**: c = 0 always; let the static solve choose c so that expr = 0, which is the DC reading the table says is "generally" used; a mix of the two.
- **Decision**: `DECIDED:` the mix VerA already implements. When the argument reads an unknown, the static solve keeps the row `-x`, so c is whatever the feedback loop forces, as the table and prose describe. When the argument reads no unknown, there is no loop and the output is undefined; VerA takes 0, the value an ic of 0 gives, which keeps the static Jacobian regular. "c = 0" in the IMPLEMENTATION row describes only the second case.
- **VerA today**: `src/analog/analog_op.zig:199-226` (`opIdt`, `readsUnknown`). Fixtures `exhaustive/idt_integral.va` and `ch04_expressions/idt_no_ic_dc_feedback.va`. `CHANGE NEEDED:` documentation only. Reword the IMPLEMENTATION row to say: "argument reads an unknown: the static solve forces it to zero (c from the loop); otherwise c = 0", and cite `idt_no_ic_dc_feedback.va`. Patch.
- **Measure impact**: none.
- **Status**: DONE (4ef087d6). Vague_Decisions.md §6 row reworded and cites `idt_no_ic_dc_feedback.va`.

### VD-058: `idtmod` with no `ic`: the table and the prose disagree
- **Source**: Vague_Decisions.md §6 row "AMS 4.5.4, 4.5.5"
- **Rule**: VAMS 4.5.5, Table 4-19, `idtmod(expr)`: "c is the initial starting point as determined by the simulator". The prose below the table says: "If the initial condition is not specified, it defaults to zero (0). Regardless, the initial condition shall force the DC solution to the system."
- **Why vague**: the table makes c a tool choice, and the prose fixes it at 0.
- **Options**: (a) treat c as tool-defined, as the table does; (b) treat it as 0, as the prose does.
- **Decision**: `DECIDED:` (b). The prose is the more specific normative sentence ("defaults to zero") and is the only one with "shall". VerA's c = 0 is therefore required by the clause, not chosen.
- **VerA today**: `zIdtmod` (`src/codegen/device/codegen/kernel_text.zig:504`) starts at ic, and the ic is 0 when omitted. The header of `ch04_expressions/idtmod_one_argument_starts_at_zero.va` calls the starting point "the tool's choice", and `idtmod.va` "declines" to assert it. `CHANGE NEEDED:` documentation and fixture headers only. Move idtmod out of the implementation-defined row. Rewrite the `idtmod_one_argument_starts_at_zero.va` header to quote the prose sentence as the requirement. Patch.
- **Measure impact**: C. The fixture now evidences a §4.5.5 requirement instead of a tool choice; whether the count moves depends on the §4.5.5 row in `CLAUSE-AUDIT.md`.
- **Status**: DONE (4ef087d6). idtmod removed from the Vague_Decisions.md §6 row; `idtmod_one_argument_starts_at_zero.va` and `idtmod.va` headers quote the prose as the requirement.

### VD-059: Where `idtmod` integrates
- **Source**: Vague_Decisions.md §6 row "AMS 4.5.5" (where)
- **Rule**: VAMS 4.5.5 gives the mathematical integral and the wrap range (`offset <= idtmod < offset+modulus`) and says nothing about numerical method or ownership.
- **Why vague**: the clause does not say whether the integrator is a solver unknown (as `idt` is under §4.5.2) or internal state.
- **Options**: (a) a host unknown, as for `idt`; (b) state inside the device, wrapped on each accepted step.
- **Decision**: `DECIDED:` (b). As a host unknown the unwrapped state grows without bound, and a free-running VCO's phase loses precision with the rounding of |s|. That defeats the operator's purpose (the `ponytail:` note at `src/analog/analog_op.zig:206-209`). Known ceiling: the device integrates with a first-order rule (`zIdtAcc`: `acc + v*dt`) outside the host's truncation-error control. The upgrade is a host unknown that re-bases on each wrap.
- **VerA today**: `src/codegen/device/codegen/kernel_text.zig:500-511` (`zIdtAcc`, `zIdtmod`; the row's `:434` is stale). Fixtures `ch04_expressions/idtmod.va` and `idtmod_offset_window_negative_integrand.va`. No change.
- **Measure impact**: none.

### VD-060: `absdelay` interpolation is not implementation-defined
- **Source**: Vague_Decisions.md §6 row "AMS 4.5.7"
- **Rule**: VAMS 4.5.7: "When calculating the output at time t, the absdelay() operator will use linear interpolation as needed to determine the input around time" max(t - td, 0).
- **Why vague**: it is not vague. The IMPLEMENTATION row lists interpolation as left open, but the clause names linear interpolation.
- **Options**: the row has none to offer; linear is the clause's answer.
- **Decision**: `DECIDED:` linear interpolation is required. `(* vera_interp = 2 *)` (quadratic) is a §2.9 vendor extension that deliberately departs from §4.5.7 on the author's request, and it is not a choice the clause leaves open.
- **VerA today**: linear by default (`src/codegen/device/codegen/kernel_text.zig`, the `absdelay` kernels; `absdelay_vera_interp_linear.va`, `absdelay_vera_interp_quadratic.va`). `CHANGE NEEDED:` documentation only. Move the row's interpolation entry under the `vera_*` attribute row, labelled "departs from §4.5.7 when set", and let `absdelay_vera_interp_linear.va` cite §4.5.7 as a requirement. Patch.
- **Measure impact**: C, if the linear fixture becomes §4.5.7 evidence.
- **Status**: DONE (4ef087d6). The §4.5.7 row is gone; the `vera_*` row says `vera_interp = 2` departs from §4.5.7 when set. `absdelay_vera_interp_linear.va` already tagged `//! lrm 4.5.7` and quoted the requirement.

### VD-061: DC value of a `laplace_*` filter with a pole at s = 0
- **Source**: Vague_Decisions.md §6 row "AMS 4.5.11" (DC)
- **Rule**: VAMS 4.5.11 gives H(s) for each form and says a zero root "is implemented as s". It has no DC rule (unlike §4.5.4's `idt` and §4.5.7's `absdelay`).
- **Why vague**: H(0) is infinite, and the clause gives no initial-state or feedback reading.
- **Options**: (a) 0, the state starting at 0; (b) the `idt` feedback reading, where the static solve forces the input to 0; (c) refuse.
- **Decision**: `DECIDED:` (a). The filter's states live in the device (`filter_kernels`), so no host unknown exists for the static solve to choose. 0 is what §4.5.4 gives an `idt` whose argument has no loop, and refusing a legal filter would be wrong. A common power of s cancels first, so `s/(s + s^2)` is 1. Known divergence: an `idt` in a feedback loop takes its DC from the loop (VD-057), and a `laplace_nd(x, '{1}, '{0,1})` in the same loop does not. A model needing that should use `idt`.
- **VerA today**: `lib/backend/kernels/filter_kernels.zig:95-111` (`zH0`; the row cites the stale `lib/backend/filter_kernels.zig`). Fixture `ch04_expressions/laplace_nd_pole_at_origin.va`. No change beyond the path fix, which goes with VD-057's row edit.
- **Measure impact**: none.

### VD-062: Root vectors from the model card: pairing conjugates at run time
- **Source**: Vague_Decisions.md §6 row "AMS 4.5.11, 4.5.12"
- **Rule**: VAMS 4.5.11.1-4.5.11.3 and 4.5.12.1-4.5.12.3: "If a root is complex, its conjugate shall also be present." 4.5.11 also says a vector "may be represented as ... a reference to a vector parameter".
- **Why vague**: a parameter vector's values arrive with the card, so "shall also be present" cannot be checked at compile time. The clause gives no pairing tolerance and no runtime outcome.
- **Options**: (a) refuse every parameter root vector; (b) pair at run time with a tolerance and give a defined failure for an unpaired root; (c) pair blindly.
- **Decision**: `DECIDED:` (b). A complex root pairs with the first unused root within 1e-9·|a+jb| of its conjugate. An unpaired root makes every coefficient NaN, so the output is visibly wrong in every analysis, never a different filter reported as this one. An odd-length vector is refused at compile time (E0540). Refusing (a) would reject legal designs the clause explicitly allows. 1e-9 relative absorbs card round-off from text such as `1.0e3` against `1000` without merging distinct roots.
- **VerA today**: `src/codegen/device/cg_filters.zig` `filterSide`/`runtimeRoots`, `lib/backend/kernels/filter_kernels.zig:127-165` (`zRootSecs`, `zroot_tol`). Fixtures `laplace_zp_parameter_roots_step.va`, `laplace_np_parameter_roots_unpaired_is_nan.va`, `reject_4_5_11_1_laplace_zp_parameter_roots.va`. No change, apart from fixing the stale `filter_kernels.zig` path in the row.
- **Measure impact**: none.

### VD-063: Analysis names beyond Table 4-21
- **Source**: Vague_Decisions.md §6 row "AMS 4.6.1"
- **Rule**: VAMS 4.6.1: "Any unsupported type names are assumed to not be a match."
- **Why vague**: which names a tool supports beyond the table is the tool's choice.
- **Options**: support vendor names (`pss`, `hb`, `pac`); none.
- **Decision**: `DECIDED:` none. VerA's hosts run only Table 4-22's columns. Any other name is false, as the sentence requires, with no diagnostic: a Spectre-only branch such as `analysis("pss")` is portable source and must compile quietly.
- **VerA today**: `src/codegen/device/codegen/call.zig:896-920` (`analysisMatch`). Fixture `ch04_expressions/analysis_transient.va`. A non-literal argument is already E-coded (`lib/diag/code.zig:4511`). No change.
- **Measure impact**: none.

### VD-064: The small-signal analysis name
- **Source**: Vague_Decisions.md §6 row "AMS 4.6.3"
- **Rule**: VAMS 4.6.3: "The name of a small-signal analysis is implementation dependent, although the expected name (of the equivalent of a SPICE AC analysis) is “ac”, which is the default value of analysis_name."
- **Why vague**: the name is explicitly implementation-dependent.
- **Options**: "ac"; a vendor name.
- **Decision**: `DECIDED:` "ac", the name the clause expects and the default of `ac_stim`, so `ac_stim()` with no name is active in VerA's only small-signal analysis.
- **VerA today**: `src/analog/contrib.zig` (the `ac_stim` lowering), fixture `ch04_expressions/ac_stim_ac_analysis.va`. No change.
- **Measure impact**: none.

### VD-065: `time_tol` of a `.v` contract device's A2D bridge
- **Source**: Vague_Decisions.md §6 row "AMS 5.10.3.1" (`.v` device)
- **Rule**: VAMS 5.10.3.1: time_tol and expr_tol "represent the maximum allowable error between the true crossing point and when the event triggers". Clause 7.8 supplies connect modules but gives a bare `.v` device none.
- **Why vague**: a `.v` device has no connect module, so no source states the crossing's time_tol.
- **Options**: a fixed absolute value; a fraction of the edge time; none (crossings at step ends).
- **Decision**: `DECIDED:` the card's `ttol`, defaulting to min(trise, tfall)/50. Scaling with the edge keeps the timing error proportionate on both nanosecond and microsecond pins, where a fixed absolute value is too tight on one and too loose on the other. The host can override it through the card, and only a step where some process wakes is held to it.
- **VerA today**: `lib/sim/rt/device.zig:461-462`. Covered by `tests/host/vdev_host.zig` ("v_edge and v_any"). No change.
- **Measure impact**: none.

### VD-066: Event tolerances on the fixed-grid testbench
- **Source**: Vague_Decisions.md §6 row "AMS 5.10.3.1, 5.10.3.3"
- **Rule**: VAMS 5.10.3.1 requires the event inside the box set by time_tol and expr_tol. VAMS 5.10.3.3: "If time_tol is not specified, the default time point is at, or just beyond, the time of the event."
- **Why vague**: the tolerances, when absent, are the tool's, and a fixed-grid harness cannot insert a point.
- **Options**: insert points (a variable-step solver); fire at the next grid point with a warning; refuse such fixtures.
- **Decision**: `DECIDED:` the pure analog testbench is a harness, not a host. It fires at the first `//! time` point past the event and says so with W0750. A grid with no `//! analysis` line is `tran`. The device still publishes the event and its breakpoint correctly, and a fixture whose reasoning needs an inserted point runs on the mixed path (AGENTS.md §7).
- **VerA today**: `src/codegen/exe/tb/runner.zig:83` (`warnGridEvents`). Fixture `ch05_analog_behavior/event_cross_fires_on_a_time_grid.va`. A `cross` that writes its own nonzero card-valued tolerances is not vague: its device publishes where a late event should have fired (`Instance.vera_cross_retry__`), and the testbench solves a point there before the late one (`locate`, `ch05_analog_behavior/cross_tolerances_are_not_the_enable.va`).
- **Measure impact**: none.

### VD-067: `absdelta` default tolerances
- **Source**: Vague_Decisions.md §6 row "AMS 5.10.3.4"
- **Rule**: VAMS 5.10.3.4: "If a value of zero (0.0) is specified, the simulator shall apply a suitable value." "If the tolerances are not specified, then the tool (e.g., the simulator) sets them." Also: "A specified time_tol that is smaller than the time precision is ignored and the time precision is used instead."
- **Why vague**: "suitable" is undefined.
- **Options**: tolerances from the expression's nature abstol; small fixed constants.
- **Decision**: `DECIDED:` time_tol 1 ps, at least the digital time precision; expr_tol 1e-12 in the expression's units. The expression may be dimensionless or of any nature, so no nature tolerance applies in general. A tiny expr_tol never suppresses an event the clause requires, and it only lets more reversal events through. The interpolated delta crossing is used where eligible, and otherwise the first time outside the time_tol exclusion, both of which the clause permits.
- **VerA today**: `lib/sim/mixed.zig:161-163` (`default_time_tol`, `default_expr_tol`), `absdeltaArgs`. Fixtures `ch07_mixed_signal/absdelta_runtime_default_tolerances.va`, `absdelta_runtime_time_precision.va`, `absdelta_runtime_time_tol.va`, `absdelta_runtime_reversal.va`. No change.
- **Measure impact**: none.

### VD-068: Discipline resolution mode (basic only)
- **Source**: Vague_Decisions.md §6 row "AMS 7.4.4.2"
- **Rule**: VAMS 7.4.4. This one is decided in VD-008, so see that entry.
- **Decision**: `DECIDED:` as in VD-008. This row only records that `src/elab/resolve.zig` implements basic mode and `ch07_mixed_signal/basic_resolution_continuous_beats_discrete.va` pins it.
- **VerA today**: no change from this row.
- **Measure impact**: see VD-008.

### VD-069: `$ferror` error codes
- **Source**: Vague_Decisions.md §6 row "AMS 9.5.7, 1364 17.2.7"
- **Rule**: VAMS 9.5.7 (and IEEE 1364-2005 17.2.7): "The integral value of the error code is returned in errno. If the most recent operation did not result in an error, then the value returned shall be zero".
- **Why vague**: only zero is defined. Nonzero values and the text are the tool's.
- **Options**: host errno passed through (varies by OS); fixed C/POSIX values; one generic code.
- **Decision**: `DECIDED:` fixed C errno values (ENOENT 2, EIO 5, EBADF 9, EACCES 13, EISDIR 21, EINVAL 22, EMFILE 24, ENOSPC 28), the same numbers on every host. The clause's own example names the variable `errno`, and the file tasks mirror C stdio. Fixing the numbers keeps a design's output identical across hosts, which a pass-through would not. Fixtures assert only "nonzero", so another tool's codes also conform.
- **VerA today**: `lib/backend/kernels/file_kernels.zig:227` (the row's `lib/backend/file_kernels.zig:216` is stale). Fixtures `ch09_system_tasks/ferror.va` and `write_mode_path_65_opens.va`. No change beyond the path fix.
- **Measure impact**: none.

### VD-070: `$stop` in a batch run
- **Source**: Vague_Decisions.md §6 row "AMS 9.7.2"
- **Rule**: VAMS 9.7.2 inherits IEEE 1364-2005 17.4.2: `$stop` "causes simulation to be suspended". VerA's artifacts have no interactive mode to suspend into.
- **Why vague**: the clause assumes an interactive simulator and is silent on batch runs.
- **Options**: exit 0 after the diagnostic; exit nonzero; ignore and continue.
- **Decision**: `DECIDED:` print the `$stop` diagnostic and exit 0, the same as `$finish`. Continuing would run past a point the author asked to halt at, and a nonzero exit would report a deliberate stop as a failure. Icarus `vvp -n` makes `$stop` act like `$finish` in the same way.
- **VerA today**: `src/codegen/device/cg_display.zig:266-272` and the test at `:1109`. Fixture `ch09_system_tasks/stop_terminates.va`. No change. Out of scope here: §12.36 says compliant simulators "must support" `vpiStop`/`vpiReset`; `vpiStop` ends the run as `$stop` does (`src/vpi/run.zig`), and `vpiReset` is VD-106.
- **Measure impact**: none.

### VD-071: Seed of an omitted-seed analog `$random`/`$arandom`
- **Source**: Vague_Decisions.md §6 row "AMS 9.13.1"
- **Rule**: VAMS 9.13.1: the seed "may be omitted, in which case the simulator picks a seed."
- **Why vague**: the clause gives no value, no rule for per-site independence, and no reproducibility rule.
- **Options**: one shared stream; a time- or entropy-based seed; a distinct deterministic seed per site.
- **Decision**: `DECIDED:` a distinct deterministic seed per site, `1 + 7919*k`, where k numbers the non-variable-seed sites in lowering order. Determinism makes reruns reproducible, which fixtures and regression decks need. Distinct sites do not share or correlate a stream, and 7919 is prime and spreads the seeds. Known ceiling: adding a site earlier in the source renumbers later sites' streams.
- **VerA today**: `src/analog/random.zig:127` (the row cites `src/analog/event.zig` `lowerRandom`, which is stale). Covered by `tests/host/revert_host.zig` and `ch09_system_tasks/random_no_seed.va`. No change beyond the path fix.
- **Measure impact**: none.

### VD-072: Which `$simparam` names exist, and whether `gmin` and `sourceScaleFactor` are constants
- **Status**: DONE (d73ae0cc)
- **Source**: Vague_Decisions.md §6 row "AMS 9.15"
- **Rule**: VAMS 9.15: "There is no fixed list of simulation parameters. However, simulators shall accept the strings in Table 9-27 to access commonly-known simulation parameters, if they support the parameter." Table 9-27 describes `gmin` as "Minimum conductance placed in parallel with nonlinear branches" and `sourceScaleFactor` as the "Multiplicative factor for independent sources for source stepping homotopy".
- **Why vague**: the list is open, and the supported set and the values are the tool's.
- **Options**: per name, either a compile-time constant, a host-written `Model` field, or unknown (E0811 when no fallback is given).
- **Decision**: `DECIDED:` keep the list (Table 9-27's `gmin`, `tnom`, `scale`, `shrink`, `sourceScaleFactor`, `iteration`, `timeUnit`/`timePrecision`, plus SPICE's `reltol`/`abstol`/`vntol` and `dt`). Make `gmin` and `sourceScaleFactor` host-written, as `tnom` and the three tolerances already are. Both are host solver settings that a host changes during a run: gmin stepping and source-stepping homotopy are exactly what the table describes them for. A compile-time 1e-12 or 1.0 is the value VerA assumes, not the one the host is using. `scale` and `shrink` stay 1.0, because geometry scaling is applied when the card is built. Unsupported table names (`gdev`, `imax`, `imelt`, `simulatorVersion`) stay unknown, as "if they support the parameter" allows.
- **VerA today**: `src/analog/sysfunc.zig:519-537` returns `gmin` = 1e-12 and `sourceScaleFactor` = 1.0 as constants, with the comment "a device compiled here is never being stepped". `host_simparams` at `:556-561` lists only tnom, reltol, abstol and vntol. `CHANGE NEEDED:` add `gmin__` (default 1e-12) and `source_scale__` (default 1) rows to `host_simparams`, and add a host-written fixture beside `simparam_newton_tolerances_host_written.va`. **Minor**, because emitted device text and `Model` fields change.
- **Measure impact**: A (one new fixture). C: no change.

### VD-073: Which `$limit` built-ins exist, and what an unknown name does
- **Source**: Vague_Decisions.md §6 row "AMS 9.17.3" (built-ins)
- **Rule**: VAMS 9.17.3: "Simulators may support other built-in functions and need not support pnjlim or fetlim. If the string refers to an unknown or unsupported function, the simulator is responsible for determining the appropriate limiting algorithm, just as if no string had been supplied." Also: "the simulator may simply choose to have $limit() return the value of its first argument". Table E.2 lists the preferred names.
- **Why vague**: the set of names and the fallback algorithm are both the tool's.
- **Options**: refuse unknown names; return the probe silently; return the probe with a warning.
- **Decision**: `DECIDED:` support `pnjlim`, `pnjlimds`, `fetlim`, `fetlimds`, `limvds` and `steplim`, which cover Table E.2's names and the compact models' usual calls. An unknown name, or a bare `$limit(x)`, returns the probe, as the clause allows, and warns W0853 naming the reason. A misspelt algorithm silently losing its limiting is a convergence bug the author needs to see. Refusing it would reject legal source.
- **VerA today**: `src/codegen/device/codegen/plan/limit.zig`. Fixture `ch09_system_tasks/limit_unknown_algorithm_returns_probe.va` (`//! warn W0853`) and the `annex_e_spice/limit_*.va` set. No change.
- **Measure impact**: none.

### VD-074: `$limit` arguments past the algorithm's own (sign, seed) and the initial junction seed
- **Source**: Vague_Decisions.md §6 rows "AMS 9.17.3" (arguments; starting value)
- **Rule**: VAMS 9.17.3: "Two additional arguments to the $limit() function are required when the second argument to the limit function is the string “pnjlim”", and one for "fetlim". Nothing is said about further arguments or about the first iteration's value.
- **Why vague**: arguments after the required ones are not addressed, and neither is the starting value of the limiter's state. SPICE's MODEINITJCT, which compact models rely on, has no Verilog-AMS spelling.
- **Options**: refuse extra arguments; ignore them; give them a defined meaning.
- **Decision**: `DECIDED:` an optional frame sign, then an optional seed, both documented in AGENTS.md §6. More arguments decline the site with W0853. Unseeded `pnjlim` legs start at vcrit, which is what SPICE's junction initialisation does. A seed that reads the solution is E0527, and one the tree cannot take is W0854. This is VerA's extension in a slot the clause leaves empty. Portability note: another tool may treat the extra arguments differently, so a model meant to be portable should keep to the required arguments and accept the default seeding.
- **VerA today**: `src/codegen/device/codegen/plan/limit.zig`. Fixtures `limit_polarity_sign_argument_honoured.va`, `limit_too_many_arguments_returns_probe.va`, `annex_e_spice/limit_seed_*.va` and `reject_limit_seed_reads_solution.va`. No change.
- **Measure impact**: none.

### VD-075: The number of `vpiRejectTransientStep`
- **Source**: Vague_Decisions.md §6 row "AMS 12.36"
- **Rule**: VAMS 12.36 defines `vpiRejectTransientStep` ("cause the current analog simulation time point to be rejected"). The LRM prints no `#define` for it, and the other AMS constants in `vpi_user.h` are not from the LRM text either.
- **Why vague**: there is no normative number.
- **Options**: any value outside 1364's `vpi_sim_control` operations (`vpiStop` 66 through `vpiSetInteractiveScope` 69).
- **Decision**: `DECIDED:` 730, the free slot in VerA's AMS constant block (720-744, between `vpiFlowNature` 729 and `vpiPotentialNature` 731). It cannot collide with a 1364 operation. A portable application uses the symbol, never the number.
- **VerA today**: `src/vpi/vpi_user.h:915-918`. Fixture `ch12_vpi_routines/sim_control_reject_step.c`. No change. Note: `vpiTransientFailConverge` (same clause) has no definition, which is a gap outside this entry.
- **Measure impact**: none.

### VD-076: SPICE flavour and primitive behaviour (E.1, E.2)
- **Source**: Vague_Decisions.md §6 row "AMS E.1, E.2"
- **Rule**: VAMS E.1/E.2. This one is decided in VD-012, so see that entry.
- **Decision**: `DECIDED:` as in VD-012. This row records only today's `.MODEL`/`.SUBCKT`-only reader (`lib/frontend/spice_cards.zig`).
- **VerA today**: no change from this row.
- **Measure impact**: see VD-012.

### VD-077: No warning when a module shadows an always-available SPICE primitive
- **Source**: Vague_Decisions.md §6 row "AMS E.3.3"
- **Rule**: VAMS E.3.3: for a primitive, "The Verilog-AMS simulator may issue a warning stating that the Verilog-AMS module or paramset is used instead of the SPICE primitive." For a model or subcircuit it "shall issue an warning message".
- **Why vague**: the primitive warning is optional.
- **Options**: warn; stay silent.
- **Decision**: `DECIDED:` silent for primitives, and W0951 for the required model/subcircuit case. Writing one's own `resistor` or `capacitor` module is routine Verilog-AMS (the LRM's own examples do it), so a warning would fire on ordinary libraries and teach users to ignore warnings. The required half is already implemented.
- **VerA today**: `src/elab/names.zig` `warnSpiceShadows`. Fixtures `annex_e_spice/spice_paramset_primitive_shadow.va`, `spice_module_shadow_warning.va` and `spice_paramset_shadow_warning.va`. No change in code. No change needed.
- **DONE**: re-checked 2026-10-04 on branch w-bugs1: `spice_module_shadow_warning.va` (model), `verilog_module_wins_over_netlist_subckt.va` (subcircuit) and `spice_paramset_shadow_warning.va` each require W0951 and pass.
- **Measure impact**: none.
- **Status**: DONE (4ef087d6). Nothing to change in code or IMPLEMENTATION (its E.3.3 row was already right); the stale row was in a document since removed.

### VD-078: Where a device's temperature lives (ABI 6: the Model row)
- **Source**: Vague_Decisions.md §6 "Device ABI 6" (cites "§9.10")
- **Rule**: VAMS 9.15: "$temperature does not take any input arguments and returns the circuit’s ambient temperature in Kelvin units." §9.10 is "Simulator time system functions" and says nothing about temperature, so the IMPLEMENTATION cite is wrong.
- **Why vague**: "the circuit's ambient temperature" suggests one value per circuit. Per-instance temperature (SPICE `dtemp`/`temp`) is a host feature the LRM does not mention.
- **Options**: per circuit (global); per instance; per Model row.
- **Decision**: `DECIDED:` per Model row. It is a superset of the per-circuit reading the clause describes, and it still lets a host give one instance its own temperature by giving it its own row. It also keeps the whole solve-invariant cache a function of the row: measured `Instance` shrink of 3,520 to 200 bytes on bsim4va.
- **VerA today**: `Model.temperature__`, `contract.host_model_fields` (`lib/contract.zig`). `CHANGE NEEDED:` documentation only. The IMPLEMENTATION "Device ABI 6" prose should cite VAMS §9.15, not §9.10. Patch.
- **Measure impact**: none.
- **Status**: DONE (4ef087d6). IMPLEMENTATION "Device ABI 6" cites §9.15.

### VD-079: Host-supplied hierarchical system parameters outside Table 9-29's domains
- **Status**: DONE (76f344c7)
- **Source**: Vague_Decisions.md §6 prose note "For AMS §9.18, E0890 ..." (dynamic domains not validated)
- **Rule**: VAMS 9.18, Table 9-29, column "Allowed values": `$mfactor > 0`, `$hflip`/`$vflip` = +1 or -1, `0 <= $angle < 360`.
- **Why vague**: the table states allowed values but no "shall be an error" and no point at which a value is checked. A value set on a host card is known only at card time.
- **Options**: check only literals at compile time (today); check card-dependent values when the host writes the card; trust the host.
- **Decision**: `DECIDED:` check at card time. An "allowed values" column is a constraint, and a value outside it, such as `$mfactor = 0`, silently zeroes or flips a device. Card time (`derive`, which runs once per card write) costs nothing per `eval`. The device should report the offending name in the way `checkShape` already reports one, and a host that ignores the report stays the host's choice. §3.4.2 `from`/`exclude` range checks for host-written cards are their own entry point, `checkRange` (VD-125, #80).
- **VerA today**: E0890 for literals only (`lib/diag/code.zig:5003`). There is no card-time check: `src/codegen/device/codegen/file.zig:583` `derive` and `:645` `checkShape` validate nothing about domains. `CHANGE NEEDED:` emit a card-time domain check, either a `checkCard(model) ?[]const u8` returning the first parameter out of Table 9-29's domain or the same check inside `derive`, together with a host test such as `tests/geometry_host.zig` that writes `$mfactor = 0` and expects the name back. **Minor**, because emitted device text changes.
- **Measure impact**: A (a new host test, under `zig build test`). C: §9.18 gains a runtime invalid-input test.

## 5. Implementation-defined choices: IEEE 1364 (Vague_Decisions.md §6, §3)

### VD-080: UDP input limit
- **Source**: Vague_Decisions.md §6 row "1364 8.1.2"; §2 row "UDP inputs".
- **Rule**: IEEE 1364-2005 8.1.2: "Implementations may limit the maximum number of inputs to a UDP, but they shall allow at least 9 inputs for sequential UDPs and 10 inputs for combinational UDPs."
- **Why vague**: the clause sets a floor and leaves the ceiling to the tool.
- **Options**: (a) the floors, 9/10; (b) a fixed larger cap with a named refusal; (c) no cap.
- **Decision**: `DECIDED:` (c), no limit, since 2026-10 (#29): "we are not limiting anyone's freedom in implementation". (b), 64 inputs refused past it with E1017, was the decision until then; E1017 is retired.
- **VerA today**: `lib/frontend/parser/udp.zig` keeps the port list and each table column in growable lists; the digital engine evaluates a table of any width (limits/digital). Fixtures `ieee1364/08_udp/input_minimums.v`, `sequential_64_inputs.v`, `udp_65_inputs.v`; `parser/test.zig` parses 65- and 1000-input tables.
- **Measure impact**: none.

### VD-081: Order of active events
- **Source**: Vague_Decisions.md §6 row "1364 11.4.2".
- **Rule**: IEEE 1364-2005 11.4.2: "active events can be taken off the queue and processed in any order."
- **Why vague**: the order is explicitly nondeterministic; a tool must still run them in some order, and a user sees it in any race.
- **Options**: (a) source-order FIFO; (b) LIFO; (c) randomised order (to flush out races).
- **Decision**: `DECIDED:` (a) processes start in source order from a FIFO queue, and woken processes resume in the order they suspended; the interpreter and native code agree. It is the order users of event-driven simulators expect from a deterministic run (and what Icarus does in the common cases, though no tool's order is a contract), it makes runs reproducible, and the native/interpreter agreement means `--state`/backend choice never changes a racy design's output. Randomising (c) is a debugging aid, not a default.
- **VerA today**: `lib/sim/scheduler.zig`, `lib/sim/digital/exec.zig`; `ieee1364/11_scheduling/sched_fork_arm_chain_order.v`, `sched_fork_arm_wake_order.v`, `sched_node_wake_order.v` pin it and cite no clause, as they must (VD-082). No change.
- **Measure impact**: none.

### VD-082: Tests over clauses that permit several outcomes
- **Source**: Vague_Decisions.md §8 "Unspecified behaviour" (1364 5.1.4, 11.4.2, 11.5, 12.3.10.1, 12.3.10.2).
- **Rule**: e.g. IEEE 1364-2005 11.5: "The simulator is correct in displaying either a 1 or a 0."; 5.1.4: "the entire expression need not be evaluated"; 12.3.10: merging dissimilar nets is permitted, not required.
- **Why vague**: these clauses permit a set of outcomes; a fixture asserting one of them tests the tool, not the standard.
- **Options**: (a) assert VerA's outcome under the clause tag; (b) assert membership in the permitted set, or pick inputs where every permitted outcome agrees, and pin VerA's own order only in untagged fixtures; (c) leave the clause untested.
- **Decision**: `DECIDED:` (b), as CLAUSE-AUDIT §5.5 already says. A clause-tagged fixture may assert only what every conforming tool prints; VerA's particular choice is pinned by a fixture that cites no clause and is listed in Vague_Decisions.md §6.
- **VerA today**: followed: `ieee1364/11_scheduling/sched_allowed_active_race.v` (membership), `ieee1364/12_hierarchy/net_type_warning.v` (merge-independent cells). But `tests/fixtures/ieee1364/CLAUSES.tsv` has 13 `unspecified` rows (5.1.4, 11.4.2, 11.5, 12.3.10.1, 12.3.10.2, 20.2, 26.1, 26.2.4, 26.6.16, 26.6.21, 27.20, 27.34, 27.34.1) and Vague_Decisions.md §8 lists five. `CHANGE NEEDED:` Vague_Decisions.md §8 should list all 13 (or say "every `unspecified` row of CLAUSES.tsv") and name each row's fixture policy. Doc only, patch.
- **Measure impact**: none (B's `unspecified` rows are already classified).
- **Status**: DONE (4ef087d6). Vague_Decisions.md §8 covers every `unspecified` CLAUSES.tsv row and names each group's fixture policy.

### VD-083: Which of several configs configures the design
- **Source**: Vague_Decisions.md §6 row "1364 13.4.4".
- **Rule**: IEEE 1364-2005 13.4.4: "In the case where the config includes a design statement, then the specified cell shall be the top-level module, regardless of the presence of any uninstantiated cells in the rest of the source files."
- **Why vague**: the clause speaks of "the config" as if there were one. With several configs in the compiled source (13.3.2 hierarchical configs reach a second config only through a `use ... :config` clause), nothing says which one sets the top, and the command-line mechanism 13.4.4 assumes is tool-specific.
- **Options**: (a) the first config in source order; (b) the last; (c) the config no other config's `use` clause names, refusing when there are zero or several such; (d) require a CLI flag naming the config.
- **Decision**: `DECIDED:` (c). It is the configuration analogue of 12.1.1's "uninstantiated module is a top", it needs no flag VerA does not have, and it never silently picks between two candidates: two unreferenced configs, or none, is E0243 naming 13.4.4. (d) is what commercial tools do through their command line, but VerA's CLI table (ARCHITECTURE §4.7) was declined; (a)/(b) make the design depend on file order without a diagnostic.
- **VerA today**: implemented: `lib/sim/digital/bind.zig:107-117` `top` (E0243, "configurations `a` and `b` are both unreferenced", "every configuration is named by another's `use` clause"). `ieee1364/13_configuration/hierarchical_config.v` passes and is no longer an xfail. `CHANGE NEEDED:` (1) Vague_Decisions.md §6's row still says "not implemented ... (xfail)": correct it; (2) no fixture pins either E0243 refusal (grep finds neither phrase under `tests/fixtures`): add `two_unreferenced_configs_rejected.v` and `every_config_referenced_rejected.v`, each with `//! reject` on its distinctive phrase, legal neighbour `hierarchical_config.v`. Fixtures and docs only: patch.
- **Measure impact**: A (+2 fixtures); B: gives 13.4.4 its rejection half if the row is not already two-way.
- **Status**: DONE (02af6a29). `two_unreferenced_configs_rejected.v`, `every_config_referenced_rejected.v`; Vague_Decisions.md §6's row corrected.

### VD-084: `$ungetc` pushback depth, and which reads see it
- **Source**: Vague_Decisions.md §6 row "1364 17.2.4.1".
- **Rule**: IEEE 1364-2005 17.2.4.1: `$ungetc` "inserts the character specified by c into the buffer specified by file descriptor fd. The character c shall be returned by the next $fgetc call on that file descriptor." NOTE: "The features of the underlying implementation of file I/O on the host system limit the number of characters that can be pushed back onto a stream."
- **Why vague**: the depth is left to the host; the clause names only `$fgetc` as the reader of a pushed character, though it says the character goes into the descriptor's buffer, which every read routine (17.2.4.2-17.2.4.4) reads.
- **Options**: depth: 1 (C's only guarantee), a fixed N with EOF past it, unbounded. Readers: `$fgetc` only, or every read routine (C `ungetc` semantics).
- **Decision**: `DECIDED:` depth 16 per descriptor, the 17th push returns EOF (the clause's own error value), never a silently dropped character. Every read routine reads the pushback before the file: "the buffer specified by fd" is the descriptor's buffer, and 17.2's routines are modelled on C stdio, where `fgets`/`fscanf`/`fread` after `ungetc` read the pushed character. A push at file position 0 may stay refused (EOF): the NOTE leaves pushback to the host, and C leaves the position after it indeterminate; document it.
- **VerA today**: `lib/backend/kernels/file_kernels.zig:77` `back: [16]u8`, `zFUngetc` at `:518` (EOF when full or at `pos == 0`); the comment at `:75-76` says "`$fgets`/`$fscanf` after an `$ungetc` read the file". Fixture `ieee1364/17_system_tasks/ungetc_pushback_limit.v`. `CHANGE NEEDED:` (1) `$fgets`, `$fscanf` and `$fread` consume `back` before the file, with a fixture (`b_17_2_4_1_ungetc_then_fgets.v`: push "Z", `$fgets` returns a line starting "Z"); this changes the run-time file kernel every generated program links, so minor; (2) IMPLEMENTATION's row should state the position-0 refusal and give the path `lib/backend/kernels/file_kernels.zig` (it says `lib/backend/file_kernels.zig:74`); (3) the doc comment at `file_kernels.zig:514` cites §17.2.4.2 for `$ungetc`, which is 17.2.4.1.
- **Measure impact**: A (+1 fixture); B: strengthens 17.2.4.1.
- **Status**: DONE (78df5df4).

### VD-085: Which bit an mcd `$fopen` returns
- **Source**: Vague_Decisions.md §6 row "1364 17.2.1, 27.25".
- **Rule**: IEEE 1364-2005 17.2.1: "The multichannel descriptor mcd is a 32-bit reg in which a single bit is set indicating which file is opened. The least significant bit (bit 0) of an mcd always refers to the standard output." 27.25: the mcds of `vpi_mcd_open()` and `$fopen` "may be shared". VAMS 12.24/12.27 predefine channel 2 (stderr) and channel 3 (the log file), i.e. mcd bits 1 and 2.
- **Why vague**: 1364 reserves bits 0 and 31 only and says nothing about allocation order; the AMS VPI clauses reserve two more channels that 1364's `$fopen` does not know about.
- **Options**: (a) lowest free bit from 1, always; (b) lowest free bit from 3, always (AMS channels kept free even without VPI); (c) (a) without a VPI application, (b) under one, with one table shared between `$fopen` and `vpi_mcd_open`.
- **Decision**: `DECIDED:` (c). An mcd is an opaque handle: a portable design ORs and passes descriptors and never depends on which bit it got, so the only obligations are "one bit, never 0 or 31, reused after close, shared with VPI". Under VPI the AMS channels must stay distinct, so allocation starts at channel 4; without VPI nothing claims bits 1-2 and (a) keeps the full 30 channels.
- **VerA today**: `lib/backend/kernels/file_kernels.zig` `zFOpen` (first free slot, 30 slots shared by mcds and fds), `src/vpi/print.zig` `share`, `openChannel` (`first_user = 3`, channel 4). Fixture `ieee_pli/mcd.c`. No change. (IMPLEMENTATION cites `lib/backend/file_kernels.zig`; the file is `lib/backend/kernels/file_kernels.zig`.)
- **Measure impact**: none.

### VD-086: The stream of a seedless digital `$random`
- **Source**: Vague_Decisions.md §6 row "1364 17.9.1".
- **Rule**: IEEE 1364-2005 17.9.1, Syntax 17-17 `$random [ ( seed ) ]`: "The seed argument controls the numbers that $random returns so that different seeds generate different random streams."
- **Why vague**: the seed is optional and the clause says nothing about where a seedless call's stream starts, or whether call sites share it.
- **Options**: (a) one hidden seed per run starting at 0, shared by all seedless calls, advanced by the 17.9.3 listing; (b) one hidden seed per call site; (c) a time- or entropy-based seed.
- **Decision**: `DECIDED:` (a). It is reproducible run to run (which (c) is not, and a testbench must be), it uses the 17.9.3 algorithm the standard does give, and a single per-run stream is the common simulator reading (and that of Icarus, to the best of current knowledge: not re-checked). The analog `$random` (VAMS 9.13.1) chooses differently, one seed per omitted-seed site; that is another clause and is decided separately.
- **VerA today**: `lib/sim/digital/root.zig:571` `random_seed: i32 = 0`, advanced in `lib/sim/digital/system.zig:201-205`; unit test `system.zig:860`; fixture `ieee1364/17_system_tasks/seedless_random_starts_at_seed_0.v`. No change.
- **Measure impact**: none.

### VD-087: Time unit and precision with no `` `timescale ``
- **Source**: Vague_Decisions.md §6 row "1364 19.8".
- **Rule**: IEEE 1364-2005 19.8: "If there is no `timescale specified or it has been reset by a `resetall directive, the time unit and precision are simulator-specific. It shall be an error if some modules have a `timescale specified and others do not."
- **Why vague**: explicitly simulator-specific.
- **Options**: 1 s / 1 s; 1 ns / 1 ns; 1 ns / 1 ps; the finest precision in the design.
- **Decision**: `DECIDED:` 1 s / 1 s. It is the conventional Verilog default (Icarus uses it), and with the second sentence (a mix is an error) a design with no `` `timescale `` anywhere is self-consistent in whatever unit it picks, so the least surprising choice is the one most tools share.
- **VerA today**: `lib/sim/digital/root.zig:1248` `default_quantum = .s`; the mix error at `:1362`. Fixtures `ieee1364/19_compiler_directives/no_timescale_is_1s_1s.v` and `some_modules_without_rejected.v`. No change.
- **Measure impact**: none.

### VD-088: A digital real array read with an out-of-range or x/z index
- **Source**: Vague_Decisions.md §6 prose after "Host math".
- **Rule**: IEEE 1364-2005 5.2.2: "If the index is out of the address bounds or if any bit in the address is x or z, then the value of the reference shall be x." 4.8.2: "Individual bits that are x or z in the net or the variable shall be treated as zero upon conversion."
- **Why vague**: 5.2.2 demands "x", but a real has no x encoding (4.8 gives reals no unknown value); the standard does not say what an x-valued real reads as.
- **Options**: (a) +0.0, applying 4.8.2's x/z-to-zero at the real boundary; (b) NaN; (c) refuse such reads.
- **Decision**: `DECIDED:` (a). It is the only reading built from text 1364 does have (4.8.2), it is what IEEE 1800 later wrote down for an invalid read of a `real` array element (0.0), and NaN (b) would invent an encoding that leaks into `$realtobits`. (c) cannot be done for run-time indices.
- **VerA today**: as decided: `ieee1364/04_data_types/native_real_arrays.v` checks invalid indices beside valid elements in the interpreter and the native executable; explicit NaNs from `$bitstoreal` keep their bits. No change.
- **Measure impact**: none.

### VD-089: `$clog2` of a host-bound parameter that carries no width
- **Source**: Vague_Decisions.md §6 row "none (host ABI)", `$clog2`.
- **Rule**: IEEE 1364-2005 17.11.1 (VAMS 9.14 defers to it): "The argument shall be treated as an unsigned value." 4.10.1: "A parameter declaration with no type or range specification shall default to the type and range of the final value assigned to the parameter, after any value overrides have been applied."
- **Why vague**: a host card value (a model-card number written into `Model` at run time) has no Verilog type or width, so 4.10.1's "range of the final value" has no answer for it, and `$clog2` of a value depends on the width it is viewed in only when that width truncates it.
- **Options**: (a) keep the elaborated declaration's width (today: a 4-bit default truncates a host 255 to 15, `$clog2` = 4); (b) treat a host number as an unsized integer literal (3.5.1: at least 32 bits, signed), so the declaration's range applies only where 4.10.1 says overrides cannot change it (a declared range or `integer`).
- **Decision**: `DECIDED:` (b), re-read against the text on 2026-10-04 after a second reading argued for (a). IEEE 1364-2005 12.2, the clause on overrides themselves: "A parameter declaration with no type or range specification shall default to the type and range of the final override value assigned to the parameter." Its 12.2.1 example says the same of an unranged `parameter B = 3'h2`: "when its value is redefined, the parameter type and range take on the type and range of the new value". 4.10.1 adds that such a parameter whose final value "is unsized shall have an implied range with an lsb equal to 0 and an msb equal to an implementation-dependent value of at least 31". VAMS 3.4.1 inherits this ("derived from the type of the final value assigned to the parameter, after any value overrides have been applied, as in IEEE Std 1364 Verilog"). Keeping the declaration's width under an override is what 12.2 gives only a ranged or typed-and-ranged parameter ("An override value shall be converted to the type and range of the parameter"), so (a) would treat `parameter knob = 4'd1` as if it were `parameter [3:0] knob`. The one step the text does not take for us is that a host card value is an override; it replaces the parameter's value the way VAMS 6.4's model card example (a SPICE `.model` turned into paramset overrides) does, so VerA treats it as one. A card value has no Verilog width, so it is unsized: 32 bits per 4.10.1's "at least 31", 64 when the value needs them. Under (a) the same parameter would also read 255 in arithmetic and 15 in `$clog2`. A declared range (`parameter [3:0] p`) or type (`integer`) still fixes the width, because 12.2 converts the override to it.
- **VerA today**: (a): `src/analog/constfold.zig:180-186` `clog2Width`, `clog2Signed`; `ch09_system_tasks/clog2_inferred_parameter_width.va:35-43` asserts `$clog2(knob) == 4` for `parameter knob = 4'd1` with `//! param knob = 255`. `CHANGE NEEDED:` untyped, unranged parameters take a host value's `$clog2` width as 32 (64 when the value needs it); change that fixture's two `knob` checks to 8 with the derivation in its header, and add a ranged neighbour (`parameter [3:0] knob2`, host 255, `$clog2` = 4) to keep the truncating case pinned. Emitted device text changes: minor.
- **Measure impact**: A (fixture expectation); C: VAMS 9.14 evidence becomes consistent with 1364 4.10.1.
- **Status**: DONE (55e391ea): `lowerClog2` selects on `$param_given` between the declaration width and the card value's unsized width; `ch09_system_tasks/clog2_inferred_parameter_width.va` asserts 8 for `knob`, plus ranged (4), negative (32) and past-32-bit (33) card values, with an unset neighbour (4).

### VD-090: Top-level values of the hierarchical system parameters
- **Source**: Vague_Decisions.md §6 row "none (host ABI)", geometric system parameters.
- **Rule**: VAMS 9.18: "The top-level value is the starting value at the top of the hierarchy." 6.3.6 lists the overrides (defparam, instance parameter assignment, paramset), all from inside the design.
- **Why vague**: the LRM gives Table 9-29's top-level starting values but no way for a simulator (a SPICE instance line's `m=`, a placement tool's coordinates) to supply a different starting value for the top module the host instantiates.
- **Options**: (a) the top is always Table 9-29's identities; (b) every top module gets six hidden host-written fields; (c) a top-level §3.4.7 `aliasparam` of the system parameter is a model-card slot the host writes, defaulting to the identity.
- **Decision**: `DECIDED:` (c). It uses a construct 9.18 itself names ("can also be used as targets in parameter alias declarations"), costs nothing in devices that do not declare one, and is what a compact model author already writes (`aliasparam m = $mfactor`) to accept a netlist `m=`. Descendants keep the dependency so the 9.18 combination rules still apply below the top.
- **VerA today**: `src/elab/hier_param.zig`, `src/analog/param.zig` `aliasSystemParam`; fixture `ch09_system_tasks/geometry_top_alias_host.va`. No change.
- **Measure impact**: none.

### VD-091: Where a relative `` `include `` file name is looked for
- **Source**: ARPice's `psp103_nqs.va`, which does `` `include "psp103.va" `` with both files in one directory, failed with E0126 unless the build passed `-I` for that directory (the `arpice-models` CI job, `ae9633f1`).
- **Rule**: VAMS 10.1 lists `` `include `` as "[IEEE Std 1364 Verilog]" and says nothing else about it (10.7 only adds that `` `__FILE__ `` is "the path by which a tool opened the file, not the short name specified in `include"). IEEE 1364-2005 19.5: "The filename can be a full or relative path name."
- **Why vague**: neither standard says what a relative name is relative to: the tool's working directory, the including file's directory, the first source file's directory, or only user-given search paths. Nor does either standard define a search-path option.
- **Options**: (a) only the `-I` directories (VerA before this entry); (b) the including file's directory first, then `-I`; (c) `-I` first, then the including file's directory; (d) the working directory first.
- **Decision**: `DECIDED:` (b). The claim that mainstream tools search the including file's directory first could not be checked against any text available here: 1364-2005 19.5 and VAMS 10.1 are silent, IEEE 1800 was not available, and no other simulator was installed to try. It is therefore not used as the reason. The reasons are these. A model split across files in one directory, like `psp103_nqs.va` and `psp103.va`, should compile wherever the directory is copied, without a build flag that names its own location. A nested include inside a library directory should find its siblings whatever the top file's directory is. (b) is also how C's `#include "..."` behaves, so it is what a model author most likely expects. Looking beside the includer first means a header shipped next to a model wins over a same-named file elsewhere on `-I`, which (c) would invert. (d) makes the result depend on where the tool was started, which no source text can see. "The including file's directory" is per file: an included file's own includes look beside it, not beside the top file. A unit that is not a file (in-memory source) has no such directory. Annex D's built-in headers stay last, so a model's own `disciplines.vams` overrides them as before.
- **VerA today**: before this entry, `lib/frontend/pp/directive.zig` `readInclude` tried only `opts.include_dirs`, then the built-ins, while E0126's `--explain` text already claimed the including file's directory was searched. Implemented in `readInclude`/`includerDir`; E0126's note lists the directories in search order. Semver: minor (source that VerA refused now compiles).
- **Measure impact**: A (+2 fixtures). C: 10.1 / 1364 19.5 gain a positive fixture and a refusal neighbour for the search rule.
- **Status**: DONE (dfd7e836): `ch10_directives/include_searches_the_including_files_directory.va` (a nested include found only beside its includer, and the includer's copy chosen over a `-I` copy), `include_including_dir_is_per_file_rejected.va` (E0126: the directory is per file); Vague_Decisions.md §6 row added.


### VD-092: Figure 7-6 Case 2, detail-merged connect module count
- **Source**: g-resolve's detail-mode work (2026-10-04), building the §7.8.1 Figure 7-6 fixtures.
- **Rule**: VAMS 7.8.1 lists, for Figure 7-6 Case 2 under detail resolution with merged connect modules, three connect modules; 7.8.4's rules for merging connect modules, applied to the same design, give two (derivation by g-resolve, 2026-10-04; re-derived independently from 7.8.1, 7.8.4 and Annex F.2.2 on 2026-10-08, and it agrees: step 2 declares NetB cmos1, so step 5 leaves it digital; the mixed ports are blk1's, blk2's and twoblks' on NetA and mix's blk2 on NetC, which is the figure's own split count of four; merged, the three on NetA share one instance).
- **Why vague**: the worked example and the rule it illustrates disagree. Case 1's three counts (basic merged 2, detail merged 3, detail split 5) agree with 7.8.4 and are pinned by fixtures.
- **Options**: (a) follow the figure's count; (b) follow 7.8.4's rule.
- **Decision**: `DECIDED:` (b). The rule is normative text that every design is held to; the figure's count is one worked instance of it, and the other Case 1 counts confirm the rule as written. A tool that matched the figure would have to break 7.8.4 for every design shaped like Case 2.
- **VerA today**: detail resolution follows 7.8.4 (`src/elab/segment.zig`, `insert.zig`). `ch07_mixed_signal/auto_insertion_figure_7_6_case2_detail_merged.va` builds Case 2 and asserts two connect modules (V = 0.5), with the derivation in its header.
- **Status**: DONE (#23, 2026-10-08).
- **Measure impact**: A (+1 fixture). C: none (7.8.1 is already cited both ways).
### VD-093: The Verilog-A 1.0 header names `discipline.h` and `constants.h`
- **Source**: the external analog suite (`tests/fixtures/external/cmcqa`, 2026-10-05): ominux/cmcqa's r3_cmc 1.0.0 does `` `include "discipline.h" `` and failed with E0126; OpenVAF-Reloaded compiles it. GitHub issue #4.
- **Rule**: VAMS 10.1 takes `` `include `` from IEEE 1364-2005 19.5, which says only that "The filename can be a full or relative path name." Annex D names the standard definitions `disciplines.vams` (D.1) and `constants.vams` (D.2). Neither standard mentions the names the OVI Verilog-A 1.0 reference shipped them under.
- **Why vague**: a file the user did not supply is found only if the tool provides it, and the LRM defines which files a tool provides only by their Annex D names. Whether a tool also answers the pre-LRM names is left to it.
- **Options**: (a) only the Annex D names (VerA before this entry): every Verilog-A 1.0 model needs its user to write a one-line `discipline.h`; (b) both 1.0 names as aliases of the Annex D text, searched last like the Annex D files.
- **Decision**: `DECIDED:` (b). The text is the same text, so no model can see a difference except that it compiles. Searching them last keeps a model's own `discipline.h` (several CMC releases ship one) ahead of the built-in. Any other name, `disciplines.h` included, is still E0126.
- **VerA today**: `lib/frontend/preprocessor.zig` `builtin_includes` maps both names; E0126's explanation lists them. Semver: minor (source VerA refused now compiles).
- **Measure impact**: A (+2 fixtures). C: 10.1 gains a positive fixture and a refusal neighbour for the built-in header names.
- **Status**: DONE: `ch10_directives/include_verilog_a_1_0_header_names.va`, `include_unknown_header_name_rejected.va`.

### VD-094: When a device's `$display` and `$write` output happens
- **Source**: the Pam4 project's request (#10) for a device-side output channel, which asked for `$strobe` at an accepted timepoint and `$display`/`$write` "per evaluation".
- **Rule**: VAMS 9.4.6: "All the display tasks, except $debug, shall not display output unless an iteration has been accepted." VAMS 9.4.1: "$strobe provides the ability to display simulation data when the simulator has converged on a solution for all nodes", "The $display task provides the same capabilities as $strobe. The $write task provides the same capabilities as $strobe, but with no newline. The $debug task provides the capability to display simulation data while the analog simulator is solving the equations; it displays its arguments for each iteration of the analog solver."
- **Why vague**: IEEE 1364's `$display` prints when executed, and the analog block is executed at every Newton iteration, so "per evaluation" is the digital reading carried over. 9.4.1 does not say when `$display` prints; 9.4.6 does.
- **Options**: (a) `$display`/`$write` per evaluation, `$strobe` at the accepted point; (b) every task but `$debug` at the accepted point.
- **Decision**: `DECIDED:` (b). 9.4.6 is the one sentence that says when, and it excepts only `$debug`; per-evaluation output would print the iterates of rejected Newton steps, which 9.4.6 forbids. So a device's `say` (`contract.SaySite`) is called once per accepted point and records `$strobe`, `$display`, `$write`, `$warning` and `$info` alike, which is also what VerA's printing artifact (`--emit-exe`) has always done.
- **VerA today**: `say` runs the display chain at the accepted point the host passes (`src/codegen/device/codegen/dispatch.zig` `emitDisplay`, `src/codegen/device/cg_display.zig` `planSay`). A `$debug` site records through `contract.Say.putDebug`, so a host that also calls `say` after each Newton iteration with `pass = .iteration` shows `$debug` at every iterate, and passes `.accepted` at the accepted point so it is not shown twice (`contract.SayPass`, 2026-10-08). VerA's `--display=record` testbench does (`runner_text.sayIteration`); ESPice still calls `say` with the default `.all`, which shows `$debug` at accepted points only. The printing artifact (`--emit-exe`, `--run`) runs its display unit by the same passes when the module has a `$debug` or `$fdebug` (2026-10-15, #29): the device declares `displayPass(S, x, model, inst, sim, comptime pass: contract.SayPass)` beside `display` (its `.all`), and the testbench calls `.iteration` after each Newton iteration and `.accepted` at the accepted point of a solve that ran any (`runner_text.sayIteration`, `sayPoint`). `$debug` and VAMS 9.5.9's `$fdebug` ("the write operation shall occur even if the evaluation occurred during an iteration that was rejected") run on every pass but `.accepted`; every other display task and §9.5 call on every pass but `.iteration`, where a §9.5 call answers its call site's latched result (`file_kernels.zFRes`), as the core does. A §9.5 call (or `$debug`/`$fdebug`) in `analog initial` runs on `.all` and on the `.iteration` pass of the first iterate (`sim.iteration == 1`): VAMS 5.2.1 executes the block once per analysis, "before a matrix solution is available", so its `$fopen` descriptor exists for the iterations of the first point (`Lowered.Display.analog_initial`, `Gen.init_calls`). A module with neither task emits no `displayPass` and its text is unchanged. **Limit**: a `$fdebug` whose descriptor comes from a `$fopen` in the analog block itself (not `analog initial`) writes, during a point's iterations, to the descriptor that `$fopen` returned at the previous accepted point, so nothing during the first point's iterations: performing the open per iteration would open one descriptor per iterate. Open it in `analog initial`.
- **Measure impact**: A (+1 fixture, `ch09_system_tasks/say_device_records.va`). C: 9.4.1 and 9.4.6 gain a positive citation through the device channel.
- **Status**: DONE (#10) for the accepted-point tasks, and for `$debug` per iteration through the record channel (`ch09_system_tasks/say_debug_every_iteration.va`) and in the printing artifact, with `$fdebug` (#29: `debug_every_iteration.va`, `fdebug_writes_in_rejected_iterations.va`).

### VD-095: What a `$table_model` capture keeps when its step is rejected
- **Source**: GitHub issue #18; the 2026-10-04 conformance pass (§10 "table capture around a rejected step"), and the note in `ch09_system_tasks/table_snapshot_per_instance.va` that left it unasserted.
- **Rule**: VAMS 9.21.1: "The state of the data source is captured on the first call to the table model function. Any change after this point is ignored." VAMS 9.3: "The behavior of a particular system task or function during the iterative evaluation process will be stated in the relevant section for that system task or function, if required. The goal of the defined behavior of a system task or function in the analog context is that a call to a such system task or function in an analog block during an iteration that is rejected should cause no side-effects on the next iteration."
- **Why vague**: 9.21.1 names the first call and says nothing about iterations. A first call can be made by a Newton iterate the solver discards, or inside a step it rejects, and the clause does not say whether that capture stands. 9.3 says the relevant section will state the iterative behaviour "if required"; 9.21.1 states none, so only 9.3's goal speaks.
- **Options**: (a) the first call ever captures, whatever becomes of its iteration (VerA before this entry: `table_ready`, "permanent first-call state; not timestep rollback state"); (b) a capture belongs to its step: it persists through the step's iterations and a rejected step undoes it; (c) a first call fixes the data for the rest of its own evaluation, and the capture stays with the instance only once an accepted iteration made it.
- **Decision**: `DECIDED:` (c). A capture is a side effect of the call, and 9.3's goal forbids a rejected iteration's side effects from reaching the next one. 9.4.6 and 9.7.1 use "iteration" for every evaluation and set "rejected" against "accepted", so a Newton iterate before convergence counts, not only a rejected step. (a) breaks the goal outright, and makes a data source that depends on the solution capture whatever the solver's first guess gave. (b) still lets one discarded iterate decide the data for the converged one. (c) keeps 9.21.1 within an evaluation: a second call of the site, or a loop over it, sees the first call's data (`table_snapshot.va`, `table_snapshot_function.va`). This is also VerA's held-state model (VD-028, VD-094, §5.10): what one evaluation leaves for later ones is latched at an accepted point and reverted with a rejected step. A kept capture is not reset by a new analysis: 9.3 leaves "between different analyses" to the section, and 9.21.1's "any change after this point is ignored" names no end.
- **VerA today**: `Instance.table_kept` marks the kept sites and `table_ready` this evaluation's. Every body with a site starts with `inst.table_ready = inst.table_kept` (`src/codegen/device/codegen/unit.zig` `tableReset`). `updateState` runs the core once at the accepted `x` while a site is uncaptured and keeps what its first calls captured (`src/codegen/device/codegen/state.zig`). `stateCtl` commits and reverts `table_kept`, and `initState` leaves it. A table device now has `updateState` even with no other state, and no `acceptQ`. Semver: minor (device text changes; a capture made by a discarded iteration is no longer kept).
- **Measure impact**: A (+1 fixture). C: 9.21.1 and 9.3 gain a positive fixture.
- **Status**: DONE (#18, 2026-10-08): `ch09_system_tasks/table_capture_rejected_step_recaptures.va`.

### VD-096: Do the preloaded Annex D natures count for §3.13.2's access uniqueness?
- **Source**: the issue wave of 2026-10-08, decided by the user's delegate. `src/analog/discipline.zig` compared natures only within one source file, so a model's own `nature My_V; access = V;` was never compared with Annex D's Voltage, included or not.
- **Rule**: VAMS 3.13.2: "Each access function name, defined before a module is parsed, is automatically added to that module's namespace unless there is another identifier defined with the same name as the access function in that module's namespace. Furthermore, the access function of each base nature shall be unique." 3.13.1: natures "have a global scope". Annex D.1 is `disciplines.vams`, a file a source includes.
- **Why vague**: VerA preloads D.1 into every compilation (a source may use `electrical` without an include), something the LRM does not describe. Whether those natures are "declared" for 3.13.2 when the source never asked for them is not a question the LRM can answer.
- **Options**: (a) never count the preloaded natures (VerA before this entry); (b) always count them, which refuses every model that defines its own `access = V` nature without including D.1; (c) count them exactly when the source includes D.1 (`disciplines.vams`, or its Verilog-A 1.0 name `discipline.h`, VD-093, which resolves to the same built-in text).
- **Decision**: `DECIDED:` (c). With the include, the source has declared Annex D's natures as surely as if it had pasted them, and a second base nature with access `V` or `I` is the collision 3.13.2 forbids (E0335). Without it, the preloaded natures are VerA's convenience, and a model that declares its own `access = V` nature has declared only one. The rest of the comparison follows 3.13.1's one global scope: two of the source's own base natures collide whichever files they are in.
- **VerA today**: `Preprocessor.Output.annex_d_included` is set when an `` `include `` resolves to the built-in D.1 (`lib/frontend/pp/directive.zig` `builtin`); `root.zig` copies it and the prelude's nature count to `Ast.SourceFile.annex_d_included`/`builtin_natures`; `analog/discipline.zig` `checkNatureTable` skips the preloaded natures without the include. Semver: minor (source VerA accepted is refused: a user `access = V`/`I` base nature beside an included D.1). `ch07_mixed_signal/compatible_disciplines_without_resolveto_rejected.va` drops its include for that reason.
- **Measure impact**: A (+2 fixtures). C: 3.13.2:1 gains a refusal for the collision with an included D.1 and a positive neighbour without it.
- **Status**: DONE (2026-10-08): `ch03_data_types/annex_d_access_v_included_rejected.va` (E0335), neighbour `annex_d_access_v_without_include.va`.

### VD-097: The derivative of `$realtobits`
- **Source**: the derivative certificate: `ch09_system_tasks/conversion_functions.va` contributes `$bitstoreal($realtobits(V(p,n)))`, whose value is V(p,n) and whose Jacobian VerA gives as 0, so a central difference disagrees.
- **Rule**: VAMS 9.11 extends `$realtobits` to the analog context and says nothing about derivatives; IEEE 1364-2005 17.8 makes its result the 64-bit pattern of the real, an integer.
- **Why vague**: neither standard says how a simulator linearizes through a conversion to an integer, and the round trip back through `$bitstoreal` is the identity on values.
- **Options**: (a) carry the derivative through the pattern, so the round trip has slope 1; (b) the pattern is an integer, with no derivative, like every integer (VD-026's conditional form, `$rtoi`, `floor`).
- **Decision**: `DECIDED:` (b). The pattern is an integer, a step function of the real it encodes, so its derivative is 0 wherever it has one. Carrying a derivative through it would make one integer expression differentiable, and only for this round trip. A model that wants the slope uses the real. The central difference across a round trip measures the real, not the pattern, so the fixture stays `//! fd-exempt` and cites this entry.
- **VerA today**: an integer carries no derivative lane; `conversion_functions.va` checks the round trip's value bit for bit. No change.
- **Measure impact**: none.

### VD-098: Which analog callbacks an AC analysis delivers under VPI
- **Source**: #20, bringing `ch12_vpi_routines/ac_freq_and_imaginary.c` into `vpi_runs`.
- **Rule**: VAMS 12.31.3: "acbInitialStep Upon acceptance of the first analog solution", "acbFinalStep Upon acceptance of the last analog solution", "acbAcceptedPoint Upon acceptance of the solution at the given time". VAMS 12.8: vpi_get_analog_freq() "shall be used determine the current frequency used in the small-signal analysis. The function shall return zero (0) during DC or transient analysis." VAMS 4.6.1 Table 4-22: in an AC analysis, `analysis("ac")` is 1 at its OP and at its AC points, `analysis("static")` 1 at the OP only.
- **Why vague**: 12.31.3's reasons are worded for time points; no reason names one frequency of a small-signal sweep, and none says whether the operating point an AC analysis starts from is one of its "analog solutions".
- **Options**: (a) no analog callback during an AC sweep; (b) the operating point is the first solution (acbInitialStep, frequency 0), each frequency point an accepted solution (acbAcceptedPoint) and the last one also acbFinalStep; (c) invent a per-frequency reason.
- **Decision**: `DECIDED:` (b). Both are solutions the analysis accepts, and 12.8 exists so an application can tell them apart: at the operating point the frequency is 0 (a DC solution), at a sweep point it is the point's frequency. (a) leaves 12.8's nonzero half and 12.10's imaginary part unobservable to any callback; (c) adds a constant no application can portably use.
- **VerA today**: `src/vpi/analog.zig` `run`/`sweep`: the OP is solved, accepted (acbInitialStep), then one small-signal solve per frequency (`tb` VPI library `vera_vpi_ac`: (G + jωC + acDyn) X = -B from the `ac_gens` phasors), each an acbAcceptedPoint with `freq` set, the last also acbFinalStep. vpi_get_analog_time() and _delta() are 0 throughout. The operating point is evaluated as `static`, not `ac`: the device's `ac_stim` returns its stimulus in every `.ac` evaluation (§4.6.1's "only affect the behavior of a module during small-signal analyses"), so an `.ac` OP would solve the stimulus as a DC source. Consequence: `analysis("ac")` reads 0 at an AC sweep's OP under VPI, where Table 4-22 gives 1. A flow contribution's small-signal flow is not computed (NOTSUPPORTED); potentials and potential-source flows are.
- **Measure impact**: C: 12.8 and 12.10 gain a run positive fixture (both halves of 12.8, and 12.10's imaginary part). A: +1 `vpi_runs` row.
- **Status**: DONE (#20): `ch12_vpi_routines/ac_freq_and_imaginary.c` over `rc_ac.va`.

### VD-099: Which member of a min:typ:max expression a value takes
- **Source**: the Annex A grammar oracle (`tests/conformance/GRAMMAR-DIFF.tsv`, 2026-10-08): 203 sentences with a min:typ:max expression, all refused by a `.va` parse (E0207 at the first `:`), which the `.v` path already read.
- **Rule**: IEEE 1364-2005 5.3: delay expressions "can be specified as three expressions separated by colons ... intended to represent minimum, typical, and maximum values—in that order", "The three values allow a design to be tested with minimum, typical, or maximum delay values", and "The min:typ:max format can be used wherever expressions can appear." VAMS A.8.3 carries `mintypmax_expression` and `constant_mintypmax_expression`; A.2.4 gives one to `param_assignment`, `defparam_assignment` and `specparam_assignment`, A.4.1 to `named_parameter_assignment`, A.7.4 to a path delay; A.8.4 gives `( mintypmax_expression )` to `primary` and `constant_primary` and only `( analog_expression )` to `analog_primary`.
- **Why vague**: 5.3 names three values and says the design can be tested with any one, but not which one a run uses or how it is chosen (IEEE 1364's tools take a command-line switch, typical by default). The analog LRM says nothing about a parameter written as a triple.
- **Options**: (a) typical always; (b) a `--mintypmax=min|typ|max` switch; (c) refuse a triple outside a digital delay.
- **Decision**: `DECIDED:` (a). A compiled device has one value per parameter and VerA has no delay-corner analysis to choose between, so the switch would select one fixed member at compile time, which (a) already is; typical is the member every 1364 tool uses when none is selected. (c) refuses legal text. Inside an analog block or analog function body the parenthesised form is not derived (A.8.4), and VerA refuses it with E0295; a parameter declared there still takes one (A.2.4).
- **VerA today**: `lib/frontend/parser/expr.zig` `parseMinTypMax` keeps the typical member and parses and drops the other two (a misspelled name in a dropped member is not diagnosed); `Parser.analog_expr` gates the parenthesised primary. Semver: minor (source VerA refused now compiles, and one new refusal).
- **Measure impact**: A (+4 fixtures). C: A.8.3, A.8.4, A.2.4, A.4.1 gain positive and refusal evidence.
- **Status**: DONE (2026-10-08): `annex_a_syntax/mintypmax_constant_takes_typical.va`, `mintypmax_delay_takes_typical.va`, `reject_A_8_4_mintypmax_in_analog_expression.va`; `specify_path_delay_mintypmax_list.va` lost its xfail.

### VD-100: Which declarations publish `desc` and `units` to a host
- **Source**: GitHub issue #15, from §10's "`desc`/`units` metadata is not exported" (2026-10-04 conformance pass).
- **Rule**: VAMS 2.9.2: "The desc attribute is used to generate help messages when attached to parameter, variable and net declarations within a module" and "The units attribute is used to describe the units of the parameter or variable which it is attached to within a module." 3.2.1 and 3.4.3: "Units and descriptions specified for block-level [variables, parameters] shall be ignored by the simulator". 3.6.3.1: on a port's net, "the last attribute value shall be used".
- **Why vague**: the clauses say what a simulator does with the text (help messages, an operating-point report) but not how a compiled model hands it to one, nor whether an instantiated child's declarations are the device's.
- **Options**: (a) publish nothing (VerA before this entry); (b) an optional comptime table of the device module's own module-scope declarations; (c) (b) plus every flattened child's, under its instance path.
- **Decision**: `DECIDED:` (b). `decl_meta` (`contract.DeclMeta`) lists parameters, then variables, then nets and ports, each in declaration order, with the last `desc` and `units` by source position (2.9). A net row carries no `units`, which 2.9.2 does not give a net. A named block's declarations are not rows ("shall be ignored"). A flattened child's are not either: the device is the top module, and a child's parameters are not on its card. The table is optional and read by no entry point, so a host that ignores it does nothing new and `abi_version` is unchanged.
- **VerA today**: `src/analog/param.zig` `collectDeclMeta`, `src/codegen/device/codegen/file.zig` `emitDeclMeta`, and the `//! meta` directive (`src/codegen/exe/tb/directive.zig`, `runner.zig`). A net discipline declaration that types a header port now binds its attribute prefix to the port (`parse_net.parseNetNames`), which also adds those attributes to the port's VPI attribute list (IEEE 1364-2005 26.6.42). Semver: minor (emitted device text).
- **Measure impact**: A (+3 fixtures). C: 2.9.2, 3.2.1, 3.4.3 and 3.6.3.1 gain positive fixtures that assert the published text, beside E0358's refusals.
- **Status**: DONE 2026-10-08 (#15): `ch03_data_types/desc_units_parameter_rows.va`, `desc_units_output_variable_rows.va`, `desc_net_rows.va`. Open: the VALUES of output variables (3.2.1 "shall provide access to their values") reach no host hook (§10).

### VD-101: A null argument that a format conversion consumes
- **Source**: the 2026-10-08 issue wave (W2-C): a null argument of a display or `$swrite` list was dropped (`system_task_null_argument_space.va`, an xfail). Giving it its space raised what a conversion that consumes one prints.
- **Rule**: VAMS 9.4.1: "Any null argument produces a single space character in the display. (A null argument is characterized by two adjacent commas (,,) in the argument list.)" VAMS 9.4.5: "For each %s specification which appears in a string, a corresponding argument shall follow the string in the argument list." 9.4.3 pairs each conversion with the argument after the string; VerA's E0810 counts a null argument as one (`checkFormatPairing`).
- **Why vague**: 9.4.1 gives a null argument a rendering, a space, and no value. Nothing says what `$swrite(s, "<%d>", , 7)` prints: the space, the space's character code, nothing, or the 7 under the `%d`.
- **Options**: (a) drop the null argument, so the conversion takes the next argument (VerA before this entry, where every null argument was dropped); (b) the null argument is the one-space string, which `%s` prints as text and every other conversion reads as a value (`%d` prints 32); (c) `%s` prints the space, any other conversion is refused.
- **Decision**: `DECIDED:` (c). The space is the null argument's only meaning, and `%s` prints an argument as its text, so it prints the space. A numeric conversion would print a value the clause never gives: (b) invents 32 from the encoding of the rendering, and (a) shifts every later argument under the wrong conversion. Refusing those is cheaper to undo than either guess.
- **VerA today**: `src/analog/systask.zig` `nullArg` lowers a formatting task's null argument to the string `" "` (display, file and string writers, deferred displays and `$sformat`'s run-time format); `prepareFormatArgs` refuses a conversion other than `%s` that consumes one (E0819). A null descriptor of a file task is E0888. A task that takes no format (a user `$systf`, `$finish`) still drops its null arguments. Semver: minor (device text changes; source VerA accepted is refused).
- **Measure impact**: A (+2 fixtures, 1 xfail removed). C: 9.4.1 gains a passing positive fixture.
- **Status**: DONE (2026-10-08): `ch09_system_tasks/null_argument_consumed_by_s.va`, `null_argument_consumed_by_d_rejected.va` (E0819); `annex_a_syntax/system_task_null_argument_space.va` lost its xfail.

### VD-102: What an OSDI 0.4 library does with what OSDI has no slot for
- **Source**: GitHub issue #24 (`vera --emit-osdi`, `lib/osdi_dyn.zig`), 2026-10-08.
- **Rule**: not an LRM reading: the interface is OSDI 0.4 (OpenVAF-Reloaded `osdi_0_4.h`). The clauses at stake are VAMS 3.2.1 (output variables: "Verilog-AMS simulators shall provide access to their values"), 4.6.4.6 ("Perfectly correlated noise is generated by using the output of one noise function for more than one noise source") and 9.4 (display at an accepted point), and the contract's accept/reject protocol (`contract.UpdateResult`, `stateCtl`).
- **Why vague**: the device publishes hooks OSDI has no slot for. Each one either drops behaviour silently or has to be named.
- **Options**: (a) refuse every device that uses one; (b) build and say nothing; (c) per gap: refuse where the library would ignore what the device asked for, warn where one analysis loses a term, document where no computed value changes.
- **Decision**: `DECIDED:` (c).
  - `$vera_reject_step` (`request_reject_at`): E1099, before the build. The library would accept the step the device asked to reject.
  - Two noise rows of one generator (one `NoiseGen.source`): W1098, and the library reports each row as an independent OSDI noise source, so a noise analysis misses the cross term; DC, AC and transient are exact. `--deny=W1098` refuses. (`PsdTerm.corr_with` is never set by VerA's codegen.)
  - Output variables (opvars): `num_opvars = 0`. No VerA host gets their values yet (§10), so no diagnostic.
  - Acceptance: OSDI has no accept callback. `updateState` and `stateCtl(.commit)` run at every iterate of a static solve, and in a transient at the last point evaluated before the simulator moves time forward, so a rejected step is never committed. A held value in a DC solve advances per Newton iterate, not per accepted point.
  - Display: the library never calls `say`, so a Verilog-A device's `$strobe`/`$display`/`$debug` records are not printed (§10). Without an accept callback a static solve has no point to print at. A `.v` design's device (`rt.Device`, built by `--emit-osdi design.v` since 2026-10-15, #29) prints what each commit above ran, to stderr, so its output follows the approximated acceptance: in a static solve any iterate whose events print, and a time-0 print again at each analysis ngspice sets the instance up for.
  - A static `request_reject_at` ("iterate again", every `.v` device whose outputs move in a DC solve) is `EVAL_RET_FLAG_LIM`, so ngspice counts the iterate unconverged. A transient one stays E1099. `stateCtl(.query)` (a late crossing) has no slot: the response starts at the first point ngspice accepts after the crossing. `pendingBreakpoint` bounds the next step through `bound_step_offset`.
  - `$bound_step` is `bound_step_offset`; a §2.8.3 user `$systf` call fails the build in `contract.validateHost` (the library binds no VPI application).
- **VerA today**: `src/main.zig` `compileAnalog` (E1099, W1098), `lib/osdi_dyn.zig`'s header. Semver: minor (`--emit-osdi` newly refuses a source).
- **Measure impact**: none of A, B or C; `zig build test` gains the two `--emit-osdi` rows in `build.zig`.
- **Status**: DONE 2026-10-08 (#24): `build.zig`'s `--emit-osdi` rows run `ch05_analog_behavior/vera_reject_step_retry.va` (E1099; the same source runs under `--emit-exe` in the suite) and `ch04_expressions/noise_anticorrelated_coefficient.va` (W1098, the library builds).

### VD-103: The notifier a violation finds at x
- **Source**: the digital engine's timing checks (2026-10-08, `lib/sim/digital/tchk.zig`).
- **Rule**: IEEE 1364-2005 15.5: "Whenever a timing violation occurs, the timing check updates the value of the notifier." Table 15-13, BEFORE -> AFTER violation: x -> "Either 0 or 1", 0 -> 1, 1 -> 0, z -> z. The tables type every notifier "Reg".
- **Why vague**: the x row names two outcomes and no rule to pick one; the table speaks of one value, and a reg may be a vector.
- **Options**: x -> 0; x -> 1; per bit or on the whole value for a vector notifier.
- **Decision**: `DECIDED:` x -> 1, and each bit of a vector notifier by the table. Either value is a change the model's notifier-sensitive logic sees (the 15.5 UDP example's `*` row), which is the table's purpose; 1 is what `0 -> 1` gives a notifier the model initialised, so a first violation looks the same whether or not the model initialised it. Per bit is the only reading that applies the table's scalar rows unchanged.
- **VerA today**: `lib/sim/digital/tchk.zig` `toggle`; unit test "VD-103". `ieee1364/15_timing_checks/notifier.v` asserts only the permitted set (0 or 1), as VD-082 requires of a clause-tagged fixture. Semver: minor (with the timing checks).
- **Measure impact**: none beyond the timing checks' own (VD-104).

### VD-104: When a timing check is judged
- **Source**: the digital engine's timing checks (2026-10-08).
- **Rule**: IEEE 1364-2005 15.1: "A transition on the timestamp event signal causes the simulator to record (stamp) the time of transition for future use in evaluating the timing check. A transition on the timecheck event signal causes the simulator to actually evaluate the timing check". 15.2.2: "(beginning of time window) <= (timecheck time) < (end of time window)". 15.2.3: "The $setuphold check shall report a timing violation when the reference and data events occur simultaneously." 15.6: "Reference events and data events shall only be detected by timing checks when their associated conditions are true." 15.3.4: "data event = reference event signal with opposite edge".
- **Why vague**: 11.4.2 lets a time step process its events in any order, and the windows give simultaneous reference and data events a defined answer ($hold violates, $setup does not) that an in-order evaluator gets only for one of the two orders. Nothing says when a condition is read, whether $width's derived data event is conditioned, or which bit of a vector an edge is.
- **Options**: (a) judge at each event as it is processed; (b) defer every judgement to the end of the time step; (c) (a), with the pair at one time judged as a pair.
- **Decision**: `DECIDED:` (c). A check is judged at its timecheck event, as 15.1 says; the latest data event strictly before a reference event is the timestamp of the window before it, and a data event at the reference event's own time is judged with it whichever of the two arrived first (when the data event came first, the reference event judges it), once per data event's time. So every window result is the same for both orders, and the notifier toggles in the time step of the violation, before its monitor region. (b) would move the toggle past the events that made it. A condition is read when its event occurs, and an x (or z) on the conditioning signal of a deterministic form disables its event even where the comparison is true as an expression (`x !== 1'b0`); $width's and $period's derived data event carries the reference event's condition (it is that signal's event); an edge on a vector, or on a part-select, is read on its least significant bit, as 9.7.2's event control is, while an event with no edge is any change of the value (15.7). A pulse $width measured is closed: a second opposite edge with no reference edge between measures nothing.
- **VerA today**: `lib/sim/digital/tchk.zig` (`reference`, `data`, `judge`, `enabled`, `transitionOf`), called from `waiters.store` on a `.tchk` watcher. Fixtures: `ieee1364/15_timing_checks/hold.v` and `setuphold.v` (both orders at one time), `conditions.v`, `vector.v`. Not evaluated, refused by name (E1149): $skew, $timeskew, $fullskew, $nochange, negative $setuphold/$recrem limits and their stamptime/checktime conditions and delayed signals. An analog compile, and the digital half of a mixed design, evaluates none (W0251). Semver: minor (designs VerA ran without checking are now checked or refused).
- **Measure impact**: B: 15.2.1-15.2.6, 15.3.4, 15.3.5 and 15.5 move from not-supported to two-way; 15.2, 15.3 and 15.7 become no-prohibition with positive fixtures; 15.6 gains a positive fixture. A: the new `ieee1364/15_timing_checks/` fixtures; the VPI fixture `tchk_violation.c` loses its xfail.

### VD-105: How a timing violation is reported
- **Source**: the digital engine's timing checks (2026-10-08).
- **Rule**: IEEE 1364-2005 15.2: "Report a timing violation if the data signal transitions within the time window." 15.3: "Report a timing violation if the elapsed time violates the limit."
- **Why vague**: "report" has no form: no message text, channel or time format.
- **Options**: (a) a line in the simulation's output; (b) a diagnostic; (c) the notifier alone.
- **Decision**: `DECIDED:` (b), warning W1199 at the check, its message "`$<check>` in <instance>: timestamp event at <t1>, timecheck event at <t2>" with the times in the instance's time unit (`$realtime`'s scaling). The design's transcript stays the design's own (a), so a model's `$display` output is the same with the checks on or off; the notifier (c) is optional. A diagnostic is reported once per site (the bag's rule for every code, `lib/diag/bag.zig` `emit`), so a check's warning is its FIRST violation's; every later one still toggles the notifier and calls cbTchkViolation, which is where a model counts them. `--allow=W1199` silences the reports and leaves the notifiers toggling.
- **VerA today**: `lib/sim/digital/tchk.zig` `violation`; every `15_timing_checks` positive fixture pins its checks' first reports with `// digital-runner: warning` and the later violations through its notifier transcript. Semver: minor.
- **Measure impact**: none.

### VD-106: What a reset keeps (vpiReset, $reset)
- **Source**: VAMS 12.36's vpiReset, `ch12_vpi_routines/sim_control_reset.c` (an xfail until 2026-10-08), and VD-070's note that vpiReset needed its own entry.
- **Rule**: VAMS 12.36: vpiReset causes "$reset ... to be executed upon return of user VPI function", passed "stop_value, reset_value, diagnostic_level". IEEE 1364-2005 C.7: the tool "Disables all concurrent activity ... (disables, for example, all force and assign statements, the current $monitor system task, and any other active tasks)" and "Cancels all scheduled simulation events"; then "The simulation time is 0. All regs and nets contain their initial values. The tool begins to execute the first procedural statements in all initial and always blocks." "A value of 0 or no argument causes interactive mode to be entered after resetting the tool. A nonzero value passed to $reset causes the tool to begin processing immediately."
- **Why vague**: C.7 lists what the reset clears, not what it keeps: a VPI application's callbacks, its value-change watches, delays and limits it put (27.31), its handles; nor what a tool with no interactive mode does for stop_value 0. reset_value only feeds `$reset_value`.
- **Options**: what stands: (a) everything a host installed; (b) nothing (a new session). stop_value 0: (c) end the run, as VD-070 reads $stop; (d) go on as if nonzero.
- **Decision**: `DECIDED:` (a) and (c). The run is elaborated again in place from the source and options it came from, so every slot, scope, pc and timing check keeps its number and every handle stays valid; the new run's state is the elaborated one, with nothing scheduled but time 0's processes. Registered callbacks stand (a one-shot time callback that fired is gone; one due later fires at that absolute time of the new run), cbStartOfSimulation does not fire again, value-change watches stand, and delays and timing limits an application put stay put: they are the application's annotation of the design, not simulation state. The reset itself is no value change. stop_value 0 ends a batch run there, at time 0, as VD-070 reads the interactive mode $stop enters. VerA has no `$reset` task, `$reset_count` or `$reset_value`, so reset_value has no reader; the diagnostic level prints nothing.
- **VerA today**: `lib/sim/digital/root.zig` `Run.reset`; `src/vpi/run.zig` (`vera_vpi_control`'s vpiReset, `simulate`); `src/vpi/value.zig` `dropScheduled`. Fixtures: `ch12_vpi_routines/sim_control_reset.c` (stop_value 0), `sim_control_reset_run.c` (stop_value 1); `src/vpi/run.zig` tests. Each reset leaves the old run's memory in its arena. Semver: minor (a VPI operation that failed now succeeds).
- **Measure impact**: C: 12.36 gains run positive evidence (vpiReset). A: +1 `vpi_runs` row, one xfail gone.
---

# Part 2: implementation-defined choices and resource limits

Sections 6 to 9 were `specification/Vague_Decisions.md` until 2026-10-04 (a citation of
`Vague_Decisions.md §N` in history means §N+5 here). They are the list
`CLAUSE-AUDIT.md` §5 defines: every choice the LRM leaves to the tool, what
VerA picks and the fixture that pins it; every engine limit, the diagnostic
that fires when a design crosses it and the fixture that crosses it; and the
defects still open. Fixture paths are relative to `tests/fixtures/`. "AMS"
clauses are the Verilog-AMS LRM; "1364" clauses are IEEE 1364-2005.

<!-- ANCHOR: implementation (docs/using/implementation.md includes from here to the end) -->

### VD-107: A string operand of a monitored event
- **Source**: the Annex A grammar oracle's wave 2 list (2026-10-08): "`cross("s")` (a string as the crossing expression) compiles".
- **Rule**: VAMS 2.7: "A string literal used as an operand in expressions and assignments shall be treated as unsigned integer constants represented by a sequence of 8-bit ASCII values". 3.3: "A string literal can be assigned to a string or an integral type" and "A string cannot be assigned to an integral type"; Table 3-3's operators are the ones a string-typed value takes. 5.10.3.1: cross() detects when "the expression crosses zero (0)". A.8.3's analog_expression derives `string`, so the grammar does not separate the cases.
- **Why vague**: no clause of 5.10.3 types the monitored expression, and 3.3 converts a literal to the string type only "when assigned to a string type or used in an expression involving string type operands".
- **Options**: (a) refuse any string operand; (b) a literal is 2.7's integer (`cross("s")` monitors 115), a string-typed value (a `string` variable or parameter) is refused; (c) accept both.
- **Decision**: `DECIDED:` (b). 2.7 gives the literal a number in exactly this position, an operand of an expression with no string-typed operand, so (a) would refuse what 2.7 defines. A string-typed value has no number to cross, compare or wait on, and before this entry VerA passed its storage on as a real with no diagnostic. The same rule covers above(), timer() and absdelta().
- **VerA today**: `src/analog/event.zig` `lowerEventExpr`: each argument goes through `Lower.strNum` (2.7) and one still string-typed is E0517. Semver: minor (a new refusal).
- **Measure impact**: A (+2 fixtures). C: 5.10.3.1 gains a positive and a refusal fixture, 2.7 a positive one.
- **Status**: DONE 2026-10-08: `ch05_analog_behavior/cross_string_literal_is_an_integer.va`, `reject_5_10_3_cross_string_operand.va`.

### VD-108: Do the Annex E sources honour `sourceScaleFactor`, and how does `sim.spice` step an operating point?
- **Source**: GitHub issue #22, from §10's "plain Newton only (no gmin or source stepping)".
- **Rule**: VAMS 9.15 Table 9-27: `gmin`, "Minimum conductance placed in parallel with nonlinear branches"; `sourceScaleFactor`, "Multiplicative factor for independent sources for source stepping homotopy". E.2: "all aspects of SPICE primitives are implementation dependent".
- **Why vague**: the table names the two homotopy knobs but no clause says which sources are "independent sources" a factor reaches, and Table E.1's source rows give no factor. VD-072 made both knobs host-written; nothing in VerA's own sources read the second, so a host that stepped it moved nothing.
- **Options**: (a) leave the Annex E sources unscaled, so source stepping reaches only a model that reads the factor itself; (b) every Table E.1 independent source (the i* and v* rows) multiplies its value by the factor, as SPICE's source stepping scales every source (ngspice CKTsrcFact).
- **Decision**: `DECIDED:` (b), in the static branch and the waveform alike (ngspice scales a transient's own operating point too); a `--spice` V card that controls an F or H, written as a branch rather than a `vsine`, does the same. At the default 1 every value is bit-identical. A deck's operating point is ESPice's ladder: plain Newton (itl1 = 100), then dynamic gmin stepping (ngspice dynamic_gmin: gmin from 1e-3 down to 1e-12 on every voltage row's diagonal, itl2 = 50 per step, a last solve without it), then source stepping (the factor from 0 to 1, 1.5x on success, halved on failure, then a full solve). Both rungs also write `gmin__` and `source_scale__` (`$simparam` reads the rung's value) and restore the deck's.
- **VerA today**: `lib/frontend/pp/annex_e.zig`, `lib/frontend/spice_cards.zig`, ESPice's operating point (`zig build test-spice` runs the decks on ESPice since 2026-10-23). Semver: minor (emitted device text: a design with an Annex E source gains the `source_scale__` Model field and, where the scaled value is card-only, `"sourceScaleFactor"` in `setup_simparams`, so a host that writes the field re-runs `setup`).
- **Measure impact**: A (+1 fixture, `annex_e_spice/primitive_source_scale_factor.va`; +2 `test-spice` decks). C: 9.15 gains positive evidence.
- **Status**: DONE 2026-10-08 (#22).

### VD-109: Which analysis an `ac_stim` name matches
- **Source**: ESPice #10 (2026-10-08): "`analysis_name` also gates §4.6.3 noise sources named per analysis", once Table 9-28's `analysis_name` reaches a device through a GPU-safe channel (VD-110).
- **Rule**: VAMS 4.6.3: "The AC stimulus function returns zero (0) during large-signal analyses (such as DC and transient) as well as on all small-signal analyses using names which do not match analysis_name. The name of a small-signal analysis is implementation dependent, although the expected name (of the equivalent of a SPICE AC analysis) is “ac”". 9.15 Table 9-28: "analysis_name" is "The name of the current analysis (e.g., tran1, mydc)", "analysis_type" "The type of the current analysis (e.g., dc, tran, ac)".
- **Why vague**: 4.6.3's "name of a small-signal analysis" is implementation dependent, and its default "ac" reads as Table 9-28's analysis TYPE, while Table 9-28 gives an analysis a second name, the user's label.
- **Options**: (a) the Table 4-21 kind only (VerA before this entry: `analysis()`'s matcher, which also let `ac_stim("tran")` fire in a transient); (b) the host's label only, so `ac_stim()` dies under a host that labels its AC analysis "ac1"; (c) a small-signal analysis answers to its Table 4-21 spelling ("ac", "noise") and, for any other name, to its host label; never a large-signal analysis.
- **Decision**: `DECIDED:` (c), `contract.acStimActive(name, kind, label)`, which the device's residual and a host gating `ac_gens` both apply. It keeps VD-064 ("ac" is the AC analysis, whatever the host calls it) and is additive: a host that publishes no label gets (a) restricted to the small-signal kinds. A large-signal analysis matches nothing, label or not, as the clause's first half requires.
- **VerA today**: `src/codegen/device/codegen/call.zig` `acStimMatch` (the label read is `contract.hostString`, so a GPU target answers the kind alone), `src/analog/analog_op.zig` (a name that is not "ac"/"noise" makes the device carry the Table 9-28 fields), `lib/contract.zig` `acStimActive`; the VPI host's AC sweep (`vera_vpi_ac`) now skips a stimulus of another name. Semver: minor (emitted device text for an `ac_stim` with another name; `ac_stim("tran")`/`("dc")` no longer fires in a large-signal analysis).
- **Measure impact**: A (+2 fixtures). C: 4.6.3 gains a positive label match and the large-signal half.
- **Status**: DONE (2026-10-08): `ch09_system_tasks/simparam_str_analysis_name_host_table.va`, `ch04_expressions/ac_stim_label_inactive_in_large_signal.va`.

### VD-110: How a host hands Table 9-28's strings to a device it copies to a GPU
- **Source**: ESPice #10 (2026-10-08): `$simparam$str("cwd")`/`("analysis_name")` read host-written `Instance` slices, a host pointer a GPU copy of the Instance cannot carry, and ESPice binds numbers only.
- **Rule**: VAMS 9.15: "Table 9-28 gives a list of simulation string parameter names that shall be supported by $simparam$str"; "cwd" is "The current working directory in which the simulator was started", "analysis_name" "The name of the current analysis".
- **Why vague**: the clause names the strings and leaves where they come from to the simulator; a compiled device needs a channel, and the LRM has no device/host split to say which.
- **Options**: (a) the `Instance` slices only (VerA before this entry); (b) a `u32` index per string in the `Model` row (`cwd_idx__`, `analysis_name_idx__`, host-written like `gmin__`) into a host-owned table, `contract.host_strings`, read on the CPU; (c) a fixed contract table of analysis keywords, which cannot hold a directory or a user label.
- **Decision**: `DECIDED:` (b), beside (a). Index 0 is "not written" and is the default, so a device reads the table at a nonzero index and otherwise the `Instance` slice (`contract.hostString`), and a host that writes neither, or only the slices, sees what it saw before. The index lives in the `Model` row because a host writes run-wide values per row (ESPice's `set_homotopy`), and `setup` never reads it, so a new analysis rewrites it without a `setup`. On an NVPTX or AMDGCN target the table is unreachable and the device answers the slice ("" when unwritten); a host keeps a device whose `Model` has `cwd_idx__` on its CPU path when the strings matter. The table is one per compilation of `contract.zig`, so a `--emit-so` library has its own, set by the host's `dyn` module. Additive: no `abi_version` change.
- **VerA today**: `lib/contract.zig` `host_strings`, `hostString`, `host_model_index_fields`; `src/codegen/device/codegen/file.zig` `emitModel`; `src/codegen/device/codegen/call.zig` (`$simparam$str`). The analog testbench publishes through (b) and leaves the slices "" (`src/codegen/exe/tb/runner.zig`); the mixed and VPI runners still write the slices. Semver: minor (emitted device text: two `Model` fields).
- **Measure impact**: A (+2 fixtures). C: 9.15 gains positive fixtures through the new channel.
- **Status**: DONE (2026-10-08): `ch09_system_tasks/simparam_str_cwd_host_table.va`, `simparam_str_analysis_name_host_table.va`; `simparam_str_cwd_and_analysis_name.va` now runs through (b).

### VD-111: When a digital `$monitor` that probes the analog solution reports
- **Source**: GitHub issue #16 ("$monitor across analog solves: no runner expresses it"). The first fix (2026-10-08) re-checked such a monitor only at digital time steps and compared each probing argument whole, so a change made by an analog solution no digital event shared was reported at the next digital step, and `$realtime` moving inside an argument counted as a change.
- **Rule**: IEEE 1364-2005 17.1.3: "each time a variable or an expression in the argument list changes value—with the exception of the $time, $stime, or $realtime system functions—the entire argument list is displayed at the end of the time step". VAMS 8.5.1: the monitor events "are continuously re-enabled in every successive time step". 8.4.3.2: "Once the analog engine has determined its behavior for a given time, it must communicate the results to other processes in the mixed signal simulation through events and shared variables"; its solution is accepted at "A 'wake up' event ... scheduled for the acceptance time of the process". 8.4.4: "a single event queue logically with a common global time". 7.3.6.3: a probe in a digital expression reads "the analog value calculated for the time corresponding to a real promotion of the digital time".
- **Why vague**: 17.1.3 was written for a kernel whose values change only at events; a probe changes at every analog solution, which the digital kernel sees only if that time is a time step, and the exception names the clock functions without saying whether it holds inside an expression.
- **Options**: (a) check at digital time steps only, comparing each probing argument whole (the first fix); (b) every accepted analog solution is a time step for the monitor (8.4.3.2's wake-up event in 8.4.4's one queue), and each probe is the monitored operand: a report is due when a probe's value changed since the last report, so the clock functions never trigger one, alone or inside an expression; (c) as (b), comparing whole arguments.
- **Decision**: `DECIDED:` (b). A probe is to the digital kernel what a variable operand is, and VerA's digital monitor already reports on an operand's change, not on the argument's value (`monitor_slots`: `a > 2` reports at every change of `a`). (c) would report at a solution where only `$realtime` moved, which is the exception 17.1.3 makes. A change is VD-032's `!=`. An accepted solution at time t is checked at tick ⌊t⌋ when no digital event has run there; the probe reads the solution interpolated to that tick (7.3.6.3). A solution between ticks whose lower tick has run already is reported at the next tick a solution or digital event reaches.
- **VerA today**: `lib/sim/mixed.zig` `step` calls `Run.analogPoint` after each step, which queues `.analog_point` at the solution's tick; `Run.monitor_probes` lists the probes (`compile.sensitivityProbes`), `display.monitorDue` compares them. Semver: minor (what a mixed simulation prints).
- **Measure impact**: A (+1 fixture). C: 8.4.3.2:1, 8.5.1:5 and 7.3.6.3:1 gain a positive fixture; inherited 1364 17.1.3 too.
- **Status**: DONE 2026-10-08 (#16): `ch08_scheduling/monitor_at_analog_only_solutions.va`; `monitor_after_macro_process.va` now checks its 2 ns and 6 ns solutions; `lib/sim/mixed.zig` test "§8.4 / IEEE 1364-2005 §17.1.3 a probing $monitor reports at each analog solution no digital event shares".

### VD-112: The `absdelay` history a device keeps
- **Source**: GitHub issue #29 (no upper limit on a design); the §7 row "`absdelay` history, per site" that ended a run with E1012.
- **Rule**: VAMS 4.5.7: "absdelay() implements the absolute transport delay for continuous waveform", Output(t) = Input(max(t - td, 0)), "using linear interpolation as needed"; "If td becomes greater than maxdelay, maxdelay will be used as a substitute for td". 4.5.15: no state history before t == 0.
- **Why vague**: the clause defines the output over all past time and says nothing about how much history an implementation keeps. A device has no allocator (the contract has none, and a GPU device cannot allocate), so its history is a fixed ring in `Instance`, and something has to happen when a lookback reaches past it.
- **Options**: (a) end the run (the old E1012); (b) answer from the oldest sample kept (a shorter delay reported as this one); (c) keep the window covered at a coarser resolution; (d) grow the ring on the heap (needs an allocator and an instance-teardown hook in the contract).
- **Decision**: `DECIDED:` (c), the user's choice of 2026-10-15. The ring keeps its per-device size (`ceil(maxdelay / 1ps) + 2` samples when maxdelay folds, within [1024, 16384], else 1024). The window is maxdelay, or td when there is none. Before each push at time t, a full ring whose second-oldest sample is later than t - window is thinned: the older half keeps every other sample (the oldest first), the newer half stays whole, and the ring is relaid oldest-first. Otherwise the next push overwrites the oldest sample, as a plain ring does. A lookback interpolates linearly over the samples left, within g^2 * max|x''| / 8 of the input for samples g apart. The run prints W1051 once per site, the first time, with the widest spacing. A run whose ring never thins answers bit for bit as before; the rule is the same on CPU and GPU (no allocation, no target branch); value copies, `stateCtl` twins and batch lanes keep working because the ring stays inline.
- **VerA today**: `lib/backend/kernels/hist_kernels.zig` `zHistThin` (called by `updateState` before each push; the dropped samples stay past the live ones until a push overwrites them, so `zHistRevert` undoes a thinning push exactly), `Instance.<site>__w` the window; `src/codegen/device/codegen/instance.zig` sizes the ring. E1012 is retired. Semver: minor (a run that ended with E1012 now completes).
- **Measure impact**: A (`ch04_expressions/absdelay_history_past_capacity.va` replaces the refusal). C: 4.5.7 gains positive evidence past the old capacity.
- **Status**: DONE 2026-10-15 (#29): `absdelay_history_past_capacity.va`; `lib/backend/kernels/test.zig` "§4.5.7 a full ring thins its older half and keeps its window: against the full history" and the plain-ring bit-identity test.

### VD-113: When a pass-switch group with no driver event is first resolved
- **Source**: GitHub issue #29 (Phase 3 gap list); `ieee1364/07_gate_switch_level/tran_from_supply_undriven.v`, an XFAIL that printed `HiZ z`.
- **Rule**: IEEE 1364-2005 §7.11: "The tran, tranif0, and tranif1 switches shall not affect signal strength across the bidirectional terminals, except that a supply strength shall be reduced to a strong strength." §7.13.3: supply nets "shall have supply driving strengths". §7.6/§8.5.3.5: switch processing considers every device of the switch-connected net.
- **Why vague**: the clauses fix what a switch-connected net shows, not when a group nothing drives first shows it. A supply net through an uncontrolled `tran` onto an undriven wire has no driver and no control to change, so no event ever asks for a resolution; whether its value arrives as a time-0 update event (visible to an `@(c)` armed at time 0) or is the net's initial value is not said.
- **Options**: (a) a time-0 update event per group (the interpreter's `.tran_switch` queue; the native emitter refuses any non-process event queued at elaboration); (b) settle the groups when elaboration ends, as initial values, with every driver still z, so only net-type strengths (supply, tri0/tri1, trireg charge) cross; drivers then resolve at time 0 as before.
- **Decision**: `DECIDED:` (b). It needs no event the native path cannot carry, and a supply net's own value is already an initial value (§3.7), not an event.
- **VerA today**: `lib/sim/digital/root.zig` `elaborateDeep` resolves every net with a switch terminal after `watch` is cleared and before anything is armed; `lib/sim/rt/root.zig` `State.initIn` resolves the same nets before the time-0 processes, so `Nets.sig0` (`%v`) holds the group's signal. Semver: minor (what a design prints).
- **Measure impact**: A (one XFAIL passes). B: inherited 7.11 and 17.1.1.5 gain a passing positive fixture.
- **Status**: DONE 2026-10-15 (#29): `tran_from_supply_undriven.v` (`St1 1`), both engines.

### VD-114: What an inter-module path is, and what its delays do
- **Source**: GitHub issue #29's Phase 3 gaps: `ch12_vpi_routines/intermod_path.c` (an xfail: `vpi_handle_multi(vpiInterModPath, ...)` was always NULL) and `ieee_pli/b_G_vpi_user.c` (77 of Annex G's names undefined).
- **Rule**: VAMS 12.22: "The VPI routine vpi_handle_multi() shall return a handle to objects of type vpiInterModPath associated with a list of output port and input port reference objects. The ports shall be of the same size and can be at different levels of the hierarchy." 12.11 and 12.29: "For inter-module path objects, the no_of_delays value shall be 2 or 3." IEEE 1364-2005 26.6.16 draws the object with vpi_get_delays() and vpi_put_delays() and a double arrow to its ports. 1364 1.7: Annex G's vpi_user.h listing is normative, and "All compliant software tools should use the same ... constant definitions".
- **Why vague**: an inter-module path is where an interconnect delay lives (SDF's INTERCONNECT), and nothing says whether the handle exists before a delay is put on it, what it holds before one is, whether the two ports must share a net, or what a tool that simulates no path delay does with a put. Annex G's listing is normative, but nothing says what a tool does with a name whose question it cannot answer.
- **Options**: the handle: (a) only where an annotation exists (VerA before this entry: never); (b) for any output/input port pair of one size, on demand. A put: (c) applied by the digital engine (a port connection is collapsed into one net, so this means splitting it and adding a transport delay); (d) held by the model, as a module path's delays are (W0251), and read back; (e) refused. Annex G's names: (f) absent unless answered (VerA before this entry); (g) all defined, each one not answered refused by name.
- **Decision**: `DECIDED:` (b), (d) and (g), the coordinator's choice of 2026-10-15. A put on the handle is how an interconnect delay is written, so it exists first; one path per ordered pair (the same handle each time), the first port an output or inout and the second an input or inout, distinct and of one nonzero size; whether a net joins them is not asked (12.22 does not). Its delays start at 0 (nothing was put), a get or put takes 2 or 3 (turn-off is 1364 7.14's min(rise, fall) until a put of three writes it), a put is vpiScaledRealTime in the first port's time unit, as a module path's is, and pulse limits other than the delay are refused. Path delays are not simulated (1364 clause 14 is `not-supported`, CLAUSE-AUDIT.md §5.7), and an interconnect delay is the same kind of annotation, so (c) would open a gate the engine has no executor for; (d) keeps it honest by adding W0251 to the run's diagnostics at each put, so the design's report says no simulation applies it, and a put needs a digital run (NOENGINE without one). (g): `vpi_user.h` defines all 441 names with Annex G's values; a property, object type, relationship or callback reason VerA does not answer returns the routine's failure value with a vpiError (code NOTSUPPORTED) whose message names the constant and why. cbStartOfReset and cbEndOfReset, which VerA can deliver since vpiReset runs (VD-106), fire around each reset.
- **VerA today**: `src/vpi/delays.zig` (`InterModPath`, `interModPath`, `getPathDelays`, `putPathDelays`), `src/vpi/systf.zig` `vpi_handle_multi`; `src/vpi/root.zig` `unansweredType`, `unansweredProp`, `failUnanswered`; `src/vpi/callback.zig` `unansweredReason`, `startOfReset`, `endOfReset`. Semver: minor (a VPI routine that refused now answers; new header names).
- **Measure impact**: A: two `vpi_runs` xfail markers gone (`intermod_path.c` now asserts its refusals too, 39 checks). C: 12.22:1, 12.11:11 and 12.29:11 gain run evidence of both polarities. B: Annex G's constants are all defined.
- **Status**: DONE 2026-10-15 (#29): `ch12_vpi_routines/intermod_path.c`, `ieee_pli/b_G_vpi_user.c`; `src/vpi/test.zig` "§12.22: vpi_handle_multi(vpiInterModPath) is one path per port pair, holding its delays" and "IEEE 1364-2005 §1.7 Annex G: a name VerA does not answer is refused by name"; `src/vpi/run.zig` "IEEE 1364-2005 §27.33.3: cbStartOfReset fires before a vpiReset, cbEndOfReset after it, once each".

### VD-115: Connect modules on a built-in primitive's terminals
- **Source**: GitHub issue #29, phase 3; `ch07_mixed_signal/gate_generated_connect_name_defparam.va` was XFAIL ("an analog compile keeps no gate and insertion walks module instances only"). Numbered 115 because `gaps/switch` and `gaps/vpi` each took 113 on parallel branches; 113 and 114 are left to them.
- **Rule**: VAMS 7.8.5.1 gives built-in primitives port names "for the purpose of naming the connect modules", so 7.8.4's insertion applies to a primitive's ports, and names them left to right: N-input gates `out`, `in1`, `in2`...; N-output gates `out1`, `out2`..., `in`; 3-port MOS switches `source`, `drain`, `gate`; `cmos`/`rcmos` `source`, `drain`, `ngate`, `pgate`; pass switches `source`, `drain`, `gate`; `pullup`/`pulldown` `out`. 3.9: "For digital primitives the domain is discrete and thus the discipline is set via the default_discipline directive". 7.8.5's split name is `SigName__InstName__PortName`.
- **Why vague**: 7.8.5.1 names no ports for the enable gates (`bufif0/1`, `notif0/1`). IEEE 1364-2005 A.3.1 makes a primitive's instance name optional, and neither standard gives an unnamed one an InstName. An instance array's elements (IEEE 1364-2005 7.1.5) are separate instances whose names neither standard spells for 7.8.5.
- **Decision**: a primitive's terminal is a port whose direction is IEEE 1364-2005 A.3.3's (a MOS switch's `source` is its output, `drain` and the controls inputs, a pass switch's two terminals inout) and whose lower connection is the discipline the `default_discipline` in force at the primitive names (none in force: no insertion, and lowering's E0960 judges a continuous net).
  - Enable gates: `out`, `in`, `enable`, left to right in A.3.1's terminal order, after the N-input gates' names.
  - Unnamed: `<gatetype>$<n>` (`and$1`, `pulldown$1`), n counting from 1 the module's unnamed instances of that type in source order. VerA's VPI gives such a primitive no `vpiName`, so there was no existing name to reuse. `$` is an identifier character (IEEE 1364-2005 3.7.1), so a defparam names it unescaped. A source that names a gate `and$1` itself collides with the generated name; that is not diagnosed.
  - Instance arrays: element `k` is `g[k]` (as `expandInstanceArrays` names a module array's element), with a bridge of its own per terminal; a defparam reaches it escaped, `\a__g[1]__in1 .p`.
  - Refused (E0929, "a mixed port's connect module cannot be inserted"), never left joined: a mixed terminal that selects part of a net (`a[1]`), whose net is a vector (an array element's bit), of a primitive an analog parse hoisted out of a generate block, or of a switch instance array.
- **VerA today**: `Ast.primTerms` (`lib/frontend/ast_decl.zig`) is the one naming rule, read by `src/elab/insert.zig` `plan` and by the mixed runner's `bridged` (`lib/sim/digital/elab.zig`), which meet only through the names; `Ast.setPrimTerm` re-points a terminal for both. An array element's bridged terminal is a per-lane override of the one gate row (`LaneSeg`). The flatten now carries the top's switches (it carried its gates and pulls only), and a top with any primitive and connect rules takes the flatten.
- **Measure impact**: A (the XFAIL passes; `gate_connect_bridge_drives_gate_input.va`, `prim_connect_noutput_gate.va`, `prim_connect_enable_gate.va`, `prim_connect_mos_switch.va`, `prim_connect_pass_switch.va`, `prim_connect_pull.va`, `prim_connect_unnamed.va`, `prim_connect_gate_array.va`, `prim_connect_vector_terminal_rejected.va`). C: 7.8.5.1 gains positive evidence for every primitive family.

### VD-116: The width a `reg` wider than 32 bits is computed at in the analog context
- **Source**: GitHub issue #29 (no upper limit on a design); the §7 row "bits of a `reg` the analog context reads", whose E0329 ("reaches above bit 31") refused a select above bit 31 of a `reg` the analog context assigns.
- **Rule**: VAMS 7.3.1 Table 7-1: a discrete bit grouping is read in the continuous context "as integer numbers", 31 bits at most per grouping; 3.2: an `integer` is 32 bits. VAMS says nothing of a `reg` the analog context itself assigns. IEEE 1364-2005 §5.4.1 (Table 5-22): "the bit length of the largest operand, including the left-hand side of an assignment, shall be used"; §5.5.1-§5.5.3: an operand is extended by the sign of the propagated type, the result cut to the left-hand side.
- **Why vague**: the analog context computes every integer at 32 bits; a `reg` of 40 bits it assigns has no stated width rule.
- **Options**: (1) compute the right-hand side at 32 bits and sign-extend it into the `reg`; (2) size the right-hand side as IEEE 1364 does, with the `reg`'s width in the context.
- **Decision**: `DECIDED:` (2), the user's choice of 2026-10-15: the analog block computes the bits the digital engine computes for the same statement over the same operand values. Only an assignment to such a `reg` (and an initializer of one) is sized this way; every other analog integer stays 3.2's 32 bits. An operand keeps its analog type: an `integer` variable or an integer-valued call is a 32-bit signed operand, a real is a real (an integer operand of a real operator is computed at its own width, then converted, §5.5.2). A select of a `reg` is unsigned, of its width. The analog context has no x or z (7.3.2): a literal with one is E0130, a discrete input's x or z is the existing run-time error, and the operations IEEE 1364 gives x for known operands (`/` or `%` by zero, zero to a negative power) give 0, as the analog integer `/` does (W0653). A real converts by rounding half away from zero (§4.8.2) to its low bits; NaN and an infinity convert to 0. The `reg` is held, cached by `vera_timepoint` and copied by `stateCtl` whole. Refused by name (E0329): a concatenation or string operand, an unsized constant past 32 bits, a parameter past 64 bits, a conditional write (a scan task's target), and a digital process reading such a `reg` (the mixed runner copies 64-bit integers).
- **VerA today**: `src/analog/wide.zig` sizes the tree (`Lowered.wide_nodes`, the `$wide`/`$wide$int` calls, the `.wide` value type); `src/codegen/device/codegen/wide.zig` renders it over `lib/backend/kernels/wide_kernels.zig`: a native unsigned integer up to `zw_native_max` (128) bits, 32-bit limbs above it (Knuth's algorithm D for `/` and `%`), no allocation, on CPU and GPU alike. Every wide value and temporary is on the evaluation's stack (§7 row "wide `reg` temporaries"). Semver: minor (source VerA refused now compiles).
- **Measure impact**: A (`ch07_mixed_signal/discrete_bus_part_select_above_31_analog_assigned.va` replaces the refusal; `wide_reg_matches_digital_72.va`, `_300.va` and `_65600.va` compare the analog result with the digital engine's, statement by statement). C: 7.3.1 gains positive evidence; inherited IEEE 1364 5.4.1, 5.5.2 and 5.5.3 too.
- **Status**: DONE 2026-10-15 (#29).

### VD-117: Whether a host has a nodeset phase
- **Source**: GitHub issue #67 (found while fixing #53): no host separates the phase Table 4-22 gives `analysis("nodeset")`, so it reads 0 everywhere.
- **Rule**: VAMS 4.6.1 Table 4-21 names "nodeset" as the phase of an equilibrium point calculation in which nodesets are applied, and Table 4-22's row for it is the first part of the static solve, present only when nodesets are applied. 4.6.2 says the phase may occur in a single-point dc analysis or the first point of a sweep, and never at a later point. 3.6.3.2: a net initializer is used as a nodeset value for the net's potential by the analog solver; 8.2 and 8.4.1 apply nodesets once, at initialization. 5.10.2 Table 5-1 has no "nodeset" column: `initial_step` with a list matches the name of the analysis being run.
- **Why vague**: the LRM never says how a solver applies a nodeset, so it does not say whether the "phase" contains any evaluation. SPICE clamps nodeset nodes for the first iterations (ngspice's INITJCT/INITFIX) and then releases them, which is a phase with evaluations in it; a solver that only starts Newton at the nodeset applies it with no evaluation at all.
- **Options**: (a) the nodeset is the starting point and the phase is empty: no evaluation sees "nodeset"; (b) a clamped first solve with the nodeset unknowns held, evaluated as "nodeset", then the free solve from its answer. Table 4-22 makes "dc" (DC OP), or "ic" and "tran" (TRAN OP), 1 in the same evaluations as "nodeset", which one `contract.AnalysisKind` cannot say (`.nodeset` reads as "static" alone, the AC/NOISE OP shape), so (b) needs a new `SimState` field: a contract ABI change, a minor release, and codegen's `analysisMatch` reading it.
- **Decision**: `DECIDED:` (a). VerA applies a nodeset as Newton's initial guess (`ch03_data_types/nodeset_01_nodeset_is_the_dc_initial_guess.va`) and never clamps it (`nodeset_unclamped_solution.va`), so the phase 4.6.2 permits has no evaluation in it, and `analysis("nodeset")` is 0 at every evaluation of every analysis, with or without nodesets. `initial_step("nodeset")` follows: no analysis is named "nodeset". A model that switches on `analysis("nodeset")` takes its other branch, as under a simulator given no nodesets. Revisit with (b) when a host clamps nodesets.
- **VerA today**: `src/codegen/exe/tb/runner.zig` `pointUnknowns` and `renderVpiLib` seed `x` from `u_nodeset` before the first `solve`; `runner_text.zig` `atPoint` never sets `.nodeset`; `ch03_data_types/spice_op_nodeset_root.sp` (#70) expects ESPice's cold start to seed `x` from `u_nodeset` over the §9.17.3 seeds. No change.
- **Measure impact**: A (+1 fixture). C: 4.6.1 gains the documented "nodeset" reading.
- **Status**: DONE 2026-10-17 (#67): `ch04_expressions/nodeset_phase_has_no_evaluation.va`.

### VD-118: What `$simparam$str("analysis_type")` returns at a transient's operating point
- **Source**: GitHub issue #67; #53 made a transient's t = 0 point evaluate as "ic" in every host.
- **Rule**: VAMS 9.15 Table 9-28: "analysis_type" is the type of the current analysis, with dc, tran and ac as examples. 4.6.1 Table 4-21 lists "ic" as the initial-condition analysis that precedes a transient, and Table 4-22's TRAN OP column makes "ic" 1 and "dc" 0 there.
- **Why vague**: Table 9-28 does not say whether the operating point that opens a transient has the type of the transient ("tran") or of the analysis Table 4-21 names for it ("ic").
- **Options**: (a) "tran" at every point of a transient; (b) the Table 4-21 name of the analysis the point evaluates as, `@tagName(sim.kind)`: "ic" at the t = 0 point, "tran" after.
- **Decision**: `DECIDED:` (b). Table 4-21 calls "ic" an analysis, and one value of `SimState.kind` answers `analysis()`, `initial_step`'s list and this string alike, so a model reading the string sees the same analysis `analysis("ic")` does. A host that wants the transient's own name at that point has `analysis_name` (VD-110).
- **VerA today**: `src/codegen/device/codegen/call.zig` (`$simparam$str`, `@tagName(sim.kind)`), set by `runner_text.zig` `atPoint` and ESPice's transient. No change.
- **Measure impact**: A (+1 fixture). C: 9.15 gains the transient half of "analysis_type".
- **Status**: DONE 2026-10-17 (#67): `ch09_system_tasks/simparam_str_analysis_type_tran_op.va`.
### VD-119: Which delay a vector net's own `delay3` applies
- **Source**: GitHub issue #55 (bug hunt 2026-10-17, finding clauses-04).
- **Rule**: IEEE 1364-2005 6.1.3: for a continuous assignment to a vector net, "If the right-hand side makes a transition from nonzero to zero, then the falling delay shall be used", to z the turn-off delay, "For all other cases, the rising delay shall be used"; for a declaration assignment "the delay is part of the continuous assignment and is not a net delay", and "if the assignment is to a vector net, then the rising and falling delays shall not be applied to the individual bits if the assignment is included in the declaration". 7.14: "Net delays refer to the time it takes from any driver on the net changing value to the time when the net value is updated", with Table 7-9's from/to rules stated for one value.
- **Why vague**: neither clause says how a net delay (`wire [7:0] #(3,5) n;` plus a separate driver) chooses among its delays for a vector. The 6.1.3 sentence contrasting the declaration case suggests a net delay might apply per bit, but no clause states that, and 7.14 speaks of "the net value".
- **Options**: (a) 6.1.3's vector rule over the whole value, as for a continuous assignment; (b) Table 7-9 per bit, each bit on its own schedule; (c) Table 7-9 on bit 0 for the whole value (VerA before #55).
- **Decision**: `DECIDED:` (a). One rule for every vector delay VerA applies, in one place (`Delay.continuous`, `lib/sim/digital/net.zig`), and the net updates as one value, as 7.14's "the net value is updated" reads. (c) has no clause behind it: 1 -> 2 waited the falling delay because bit 0 of 2 is 0. (b) would let a vector show values no driver ever drove (`00000011` between `1` and `2`), from a reading the text only implies. Other tools: iverilog refuses net delays ("sorry: Net delays not supported"); others not established. Revisit if the user prefers (b).
- **VerA today**: `resolution.resolve` (interpreter) and `rt/net.zig` `resolve` (a `.v` `--emit-exe`) both call `Delay.continuous` with the truth of the net's published value; a 1-bit net keeps the gate rule (VD-038). A declaration assignment's delay is that assignment's driver delay, not the net's (`elab.declareNet`, #71), so a second driver of the net is not delayed by it; `decl_assign_delay_is_one_drivers.v` checks it beside `assign #3` and a net delay.
- **Measure impact**: A: +1 fixture (`ieee1364/06_assignments/vector_net_delay.v`, declaration assignment and net delay beside `assign #(3,5)`). B: 6.1.3 gains a positive case.
- **Status**: DONE (#55).

### VD-120: How wide `%d` of a real operand prints
- **Source**: bug hunt 2026-10-17, finding clauses-15 (suspect): the digital engine prints `$display("%d", 7 / 2.0)` as 19 spaces and `4`; iverilog prints `4`.
- **Rule**: IEEE 1364-2005 17.1.1.3: an expression argument is sized automatically, by the largest value the expression can take (a 12-bit expression gets four decimal columns); a zero after `%` overrides it. 4.8.2: a real converts to an integer by rounding, half away from zero; 5.5.1: a real converted by type coercion is signed. 17.8: `$rtoi` returns an `integer`. VAMS 9.4.3 Table 9-22 says only "display in decimal format".
- **Why vague**: a real has no bit width, and no clause gives the integer a real becomes under `%d` a size (4.8.2 converts on assignment, where the target sets it). So no clause fixes the "largest possible value" 17.1.1.3 sizes the field by.
- **Options**: (a) minimal width, as if `%0d` (iverilog); (b) 11 columns, the conversion as a 32-bit `integer`, as `$rtoi` returns; (c) 20 columns, the width of the signed 64-bit integer VerA converts to.
- **Decision**: `DECIDED:` (c), VerA's behaviour, kept. The digital engine reads a real in any integral context as a 64-bit signed integer (`evaluate.eval`), so every real within ±2^63 converts exactly and one beyond it is x; 17.1.1.3 then sizes that operand as it sizes every other one, and the widest value it can hold, -9223372036854775808, takes 20 columns. (b) would size the field for a value the conversion does not produce (a real above 2^31 converts past 32 bits); (a) drops 17.1.1.3 for one operand type. `%0d` is the clause's own escape. Revisit if the user prefers (a).
- **VerA today**: `lib/sim/digital/display.zig` `walk` hands the radix conversions `evaluate.eval(.., 0)`, which gives a real `.{ .width = 64, .signed = true }`; `lib/kernels/fmt.zig` `autoWidth` sizes it. The analog context applies the same rule (#61, 2026-10-18): a real under `%d` converts as a 64-bit signed integer there too (`std.math.lossyCast(i64, @round(x))`), so `src/codegen/device/cg_display.zig` `decimalField` gives it 20 columns, and a device's `say` records it as `%20d`; `ch09_system_tasks/analog_decimal_is_auto_sized.va` pins both signs. VAMS 9.1 ("a superset of IEEE Std 1364 Verilog") and 9.4.1 (the display tasks "extended" to the analog context, with no sizing rule of their own) make 17.1.1.3 the analog rule as well, so the integer half there is the clause, not a choice: 11 columns for an `integer`.
- **Measure impact**: A: +1 fixture (`ieee1364/17_system_tasks/decimal_of_real_width.v`, with `%0d` and a `$rtoi` contrast), and +1 for the analog half (`ch09_system_tasks/analog_decimal_is_auto_sized.va`, #61). B: none (17.1.1.3 already has positive evidence).
- **Status**: DONE 2026-10-17 (no issue: the clauses leave the width open and VerA's choice is consistent with its conversion).

### VD-121: What `limexp` limits, and what it returns at a converged point
- **Source**: bug hunt 2026-10-17, finding clauses-01 (#52).
- **Rule**: VAMS 4.5.13: limexp "returns a real value which is the exponential of its single real argument; however, it internally limits the change of its output from iteration to iteration"; "On any iteration where the change in the output of the limexp() function is bounded, the simulator is prevented from terminating the iteration. Thus, the simulator can only converge when the output of limexp() equals the exponential of the input"; "The apparent behavior of limexp() is not distinguishable from exp()"; "There are different ways of implementing limiting algorithms for the exponential".
- **Why vague**: the clause leaves the limiting algorithm open, and names none. It does not leave the value open: at any point a simulator accepts, limexp is exp.
- **Options**: (a) the SPICE2 tangent continuation as a pure function of the argument, exp(80)·(1 + x − 80) above 80 (VerA until #52, ADMS and others): converges to a wrong current wherever the solution's argument is past 80, with nothing to stop it; (b) a stateful limiter that linearises around the previous iterate's output and holds off convergence while it limits (needs the previous iterate, which `eval` does not have, and a convergence veto the contract does not carry for an expression); (c) no limiting: exp at every argument.
- **Decision**: `DECIDED:` (c). (a) breaks the one sentence the clause makes normative about the result; (b) is a contract change (per-site iterate history and a hook every host must run) for a convergence aid that `$limit` already provides on the junction voltage, where the host owns the previous iterate (VAMS 9.17.3: "$limit() may be used for the exponential as well"). With (c), limexp has exp's value, derivative, overflow (+inf past ln(DBL_MAX)) and finiteness proof (W0650 for an unbounded argument).
- **VerA today**: `src/codegen/device/codegen/call.zig` renders `limexp` as the `exp` opcode's text; `src/prove/prover.zig` `callTransfer` gives it exp's interval and finiteness. Fixtures `exhaustive/limexp.va` (its old `limexp(1000) < 1e300` check tested for the tangent and is withdrawn), `ch04_expressions/limexp_is_exp_at_a_converged_point.va`, `limexp.va`.
- **Measure impact**: A: +1 fixture. C: 4.5.13 gains a positive run past the old knee.
- **Status**: DONE (#52). Models that leaned on the tangent for convergence (ESPice's `mos2.va`, `vdmos.va`, `hicumL2_va.va`, the `veriloga_diode_clamp` deck's `va_diode.va`) now see exp's slope past 80 Vt.

### VD-122: Which run-time evaluations report a Table 4-14 domain error
- **Source**: bug hunt 2026-10-17, finding clauses-08 (#59).
- **Rule**: VAMS 4.3.2: "Input values outside of the valid range for the operator shall report an error." Table 4-14's Domain column: ln and log "x > 0", ln1p "x > -1", sqrt "x >= 0", pow "if x > 0, all y; if x = 0, y > 0; if x < 0, all integer y". The sentence is printed in 4.3.2, above Table 4-15.
- **Why vague**: the sentence sits in 4.3.2, so it can be read as Table 4-15's alone; and it gives no form for the error, nor says which evaluations count (a Newton iterate, a speculative computation, a test harness probing nearby points).
- **Options**: (a) Table 4-15 only (VerA until #59: asin, acos, acosh, atanh reported, ln(0) printed -inf); (b) both tables, at every evaluation of the op; (c) both tables, at every evaluation an analysis makes.
- **Decision**: `DECIDED:` (c). VerA already reads the sentence for Table 4-14 at compile time (E0602-E0604, E0609, `standard_math_domain_rejected.va`), and a constant refused while the same value at run time is silent is the inconsistency #59 names. The executable reports the prover's code with the argument (`error[E0602]: LRM 4.3.2: ln() input value is outside the valid range x > 0: 0`) and exits 1, at a solved point and at a Newton iterate alike; a solver device returns the IEEE value (no transcript, GPU targets included). Not reported: a value `setup` computes outside the guard `eval` runs it under (`prove/setup.zig` `speculable`, unchecked spelling `opcode_zig.Row.checked`), since no evaluation asked for it; such a value out of its domain reaches `eval` as NaN or inf; and the testbench's self-checks at perturbed points (`runner_text.zig` `point`, `vera_domain_muted`), which are not inputs of the analysis. pow at x = 0, y = 0 is admitted, as the prover admits it (IEEE pow(0, 0) = 1).
- **VerA today**: `src/codegen/device/codegen/kernel_text.zig` `zSqrtD`, `zLnD`, `zLn1pD`, `zLog10D`, `zPowK`, `zPow`, `zDomain`; `src/codegen/device/codegen/opcode_zig.zig` `Row.checked`; `src/codegen/device/codegen/render.zig` `renderOp`. Fixtures `ch04_expressions/runtime_{ln,log,sqrt,ln1p,pow,pow_constant_exponent}_domain_rejected.va` (`//! reject-run`) and `runtime_domain_legal_neighbour.va`.
- **Measure impact**: A: +7 fixtures. C: 4.3.1's domains gain the run-time negative half.
- **Status**: DONE (#59).

### VD-123: How accurate Table 4-14/4-15's run-time functions are, and that a fold is the same function
- **Source**: bug hunt 2026-10-17, finding clauses-09 (#60).
- **Rule**: VAMS 4.3.1 Table 4-14 and 4.3.2 Table 4-15 give each function an "Equivalent C function" (log10, asin, acos, atan2, asinh, acosh, atanh, tan) and a domain; no accuracy. 9.14: the `$`-style and traditional names are one function. VD-026: a fold gives the bits run time gives.
- **Why vague**: "Equivalent C function" names a function, not its error; C itself promises none.
- **Options**: (a) the textbook compositions over ln/sqrt/atan (VerA until #60); (b) the C algorithms (musl's, as Zig's `std.math` and compiler_rt carry them) for the value, the analytic derivative grafted on.
- **Decision**: `DECIDED:` (b) where (a) loses accuracy materially, measured with an exact f64 model of each kernel against mpmath (`#60`, 2026-10-18; C libm, glibc, beside it): asinh (a): every digit below |x| = 1e-8 (relative error 1, `x + sqrt(x²+1) - 1` cancels), -inf below -1e8, +inf above 1e154; (b) 1.47 ulp. acosh (a): 2.5e7 ulp near 1, +inf above 1e154; (b) 1.94 ulp. atanh (a): every digit below 1e-8, 2376 ulp in (-1, 1); (b) 1.46 ulp. acos (a), pi/2 - asin: 4.2e7 ulp near 1; asin (a), atan(x/sqrt(1-x²)): 1023 ulp near 1; (b) `std.math`'s, <= 1 ulp (glibc 0.51). log10 (a), ln·0.4343: 1.56 ulp and not exact at powers of ten (log(1e15) = 14.999999999999998); (b) 0.67 ulp, exact at every 10^k. atan2 (a): signed zeros lost (atan2(-0, -1) = +pi), and no derivative on the y axis; (b) C99 F.10.1.4's quadrants and zeros, 1.33 ulp, slope (x dy - y dx)/(x² + y²) everywhere but the origin. tan, sin/cos: 1.76 ulp against glibc's 0.52, kept (not material), and the folder now computes the same quotient. Each function is one function for the folder (`kernels/fold.zig`), the prover's bounds (`prove/transfer.zig`), a host's f64 path (`opcode_zig.host_f64`) and the device's value: `contract.gm.asinh`, `acosh`, `atanh`, `log10`, `atan2`, `tan` (additive, no `abi_version` change; they need no libm, so NVPTX/AMDGCN compile them too), and `std.math.asin`/`acos`. Table 4-15's "atan2(0,0) = 0" is C's atan2(+0, +0); atan2(±0, -0) = ±pi as C gives.
- **VerA today**: `src/codegen/device/codegen/kernel_text.zig` `zGraft`, `zLog10`, `zAsin`, `zAcos`, `zAsinh`, `zAcosh`, `zAtanh`, `zAtan2`; their `opcode_zig` rows pin lanes (a device using one is not `batch_ok`, as `hypot`/`atan2` already were). Bounds in `tests/reference/ulp.zig`; fixture `ch04_expressions/c_math_values_at_run_time.va`.
- **Measure impact**: A: +1 fixture. C: none (4.3.1/4.3.2 already two-way).
- **Status**: DONE (#60).

### VD-124: How wide an unsized integer literal is
- **Source**: va-to-zig translation hunt 2026-10-18 (#77): analog `%h` of `255` printed `ff` and of `-42` sixteen digits, while `%d` (#61) sized both as 32 bits.
- **Rule**: VAMS 2.6.1 and IEEE 1364-2005 3.5.1: "The number of bits that make up an unsized number ... shall be at least 32." IEEE 1364-2005 5.4.1 Table 5-22: "Unsized constant number: Same as integer". VAMS 3.2: an `integer` holds "-2^31 to 2^31-1". 17.1.1.3: radices show leading zeros at the expression's size.
- **Why vague**: 3.5.1 sets only a floor; Table 5-22 ties the size to `integer`, whose own size 1364 also leaves at "at least 32 bits" (4.8), and VAMS 3.2 fixes at 32.
- **Options**: (a) the 64-bit carrier (VerA's radix conversions until #77; fixture 171 asserted `%h` of -42 as sixteen digits); (b) 32 bits, 64 when the value does not fit 32 bits of either sign; (c) 32 bits always, truncating a larger value.
- **Decision**: `DECIDED:` (b). Table 5-22 with VAMS 3.2 gives 32, which is what the analog context computes every integer operation at (VD-116) and what `%d` already used (#61); (a) sized one operand two ways in one statement. A literal whose value needs more than 32 bits keeps 64 so no digit is lost, the reading VD-089 gives a card value.
- **VerA today**: `src/analog/systask.zig` `intSize`, the one width rule for `%d`, `%h`/`%x`/`%o`/`%b` and numeric `%s`; `src/codegen/device/cg_display.zig` pads any recorded width, 64 included. Fixtures `ch09_system_tasks/analog_radix_of_integer_expression_is_32_bits.va`, `display_c_format_flags.va` (now `ffffffd6`).
- **Measure impact**: A: +1 fixture. C: 9.4.3 gains a positive case.
- **Status**: DONE (#77).
### VD-125: When a host-written parameter value is checked against its §3.4.2 range, and what the host gets
- **Source**: va-to-zig translation hunt 2026-10-18 (#80); VD-079's "also unchecked today".
- **Rule**: VAMS 3.4.2: "The parameter value shall be within the range from the smallest value specified to the largest value specified", an `exclude` removes values from it, and "It shall be an error only if the value of the parameter is out of range during simulation."
- **Why vague**: the clause says when it is an error (during simulation), not when an implementation must look, nor how a host that compiled the device separately hears of it. A `#(...)` override is elaborated with the design; a card value exists only when a host writes it.
- **Options**: (a) check only overrides, at compile time (VerA until #80, E0361); (b) check the card in `derive`; (c) a separate optional entry point the host calls after `derive`, beside `checkShape` and `checkCard`; (d) check in `eval`.
- **Decision**: `DECIDED:` (c). `checkRange(&model) ?[]const u8` names the first parameter whose value after `derive` lies in none of its `from` ranges or in one of its `exclude` ranges. After `derive`, so a value reached through an `aliasparam` (§3.4.7) or a default over another parameter (§6.3.4) is the one judged, and so is a default the card leaves alone: the clause is about the value during simulation, wherever it came from. Once per card (zero cost per `eval`, unlike (d)); a separate entry rather than inside `derive` (b) so `derive` stays infallible and a host chooses its refusal, as with `checkShape`. What a host gets: the testbench prints `` error[E0377]: LRM 3.4.2: the model card puts parameter `<name>` outside its declared range `` and exits 1; `--emit-osdi`'s library logs the same code at fatal level and sets `EVAL_RET_FLAG_FATAL` in `setup_model`/`setup_instance` (ngspice stops, as it does for OpenVAF's out-of-bounds error; an `OsdiInitError` list would need a heap the host frees). Not checked: a range whose bound does not fold over literals (`Lowered.Range`: a bound written over another parameter has no single value the device text can carry), a string-set range, and a string parameter. Contract: optional and additive, no `abi_version` change.
- **VerA today**: `src/codegen/device/codegen/file.zig` `emitRangeCheck`; `lib/contract.zig` (`checkRange` in `validate`); `src/codegen/exe/tb/runner_text.zig` `shapeCheck`; `lib/osdi_dyn.zig` `derive`. Fixtures `ch03_data_types/range_card_value_excluded_rejected.va`, `range_card_value_below_from_rejected.va` (`//! reject-run E0377`) and their neighbour `range_card_value_inside.va`.
- **Measure impact**: A: +3 fixtures. C: §3.4.2's value half gains a run-time invalid-input test.
- **Status**: DONE (#80).

## 6. Implementation-defined choices

A fixture here tests VerA's choice, not the clause. A tool that chooses
differently also conforms.

| Clause | What the LRM leaves open | VerA's choice | Code | Fixture |
|---|---|---|---|---|
| AMS 2.7 | an error for an octal escape above `\377` is optional | refused, E0148 (`specification/Vague_Decisions.md` VD-053) | `lib/frontend/lexer.zig` `badEscape`, `lib/frontend/parser/source.zig` `checkEscapes` | `ch02_lexical/octal_escape_above_377_rejected.va`; legal neighbour `octal_escape_377_largest_byte.va` |
| AMS 2.7, 1364 3.6.3 | a backslash before a character Table 2-2 does not list (`"\q"`) | the character is kept and the backslash dropped (`"\q"` is `"q"`), with warning W0149 (`specification/Vague_Decisions.md` VD-036) | `lib/frontend/lexer.zig` `stringContents`, `badEscape`; `lib/frontend/parser/source.zig` `checkEscapes` | `ch02_lexical/undefined_escape_keeps_character.va`; legal neighbour `string_escapes.va` (`//! nowarn`) |
| AMS 2.7, A.8.8; 1364 3.6 | a string byte above 0x7F (A.8.8 says `Any_ASCII_Characters`, 3.6 stores "8-bit ASCII values") | accepted with no diagnostic; each byte is one opaque 8-bit character, so UTF-8 `"°C"` is three characters, 0xC2B043 (`specification/Vague_Decisions.md` VD-014) | `lib/frontend/lexer.zig` `lexString`, `stringContents` (bytes copied as they are) | `ch02_lexical/string_bytes_above_7f.va` |
| AMS 6.5.1, A.1.3 | the name of a null port (`module m(a, , b)`, `.x()`), which the source gives none | the device keeps it as a terminal at its position, so a host's positional binding still lines up, named `\tnull<k>` (k its 1-based position; `Z09null<k>` in the device's `U` enum), a name no source text can spell, so nothing inside reaches it; `.x()` is connected by name as `x`; the digital engine gives it no name | `lib/frontend/parser/module.zig` `nullPortName`, `Ast.Port.connName` | `annex_a_syntax/null_port_connects_nothing.va` |
| 1364 5.3; AMS A.8.3 | which member of a min:typ:max expression a value takes | the typical (middle) one, everywhere: a parameter, localparam, specparam or defparam default, a named parameter override, a delay, a path delay, a timing check offset, and a parenthesised `(a:b:c)` operand; `(a:b:c) + (d:e:f)` is b+e. Not in an analog_expression (E0295, A.8.4) (`specification/Vague_Decisions.md` VD-099) | `lib/frontend/parser/expr.zig` `parseMinTypMax` | `annex_a_syntax/mintypmax_constant_takes_typical.va`, `mintypmax_delay_takes_typical.va`; refusal `reject_A_8_4_mintypmax_in_analog_expression.va` |
| AMS 10.1, 1364 19.5 | where a relative `` `include `` file name is looked for (19.5: "The filename can be a full or relative path name", and nothing more) | a full path is opened as written. A relative one is tried, first hit wins: (1) the directory of the file that holds the `` `include `` (the path it was opened by, `.` for a bare name; a unit that names no file, `<source>`, has none); (2) each `-I` directory in command-line order; (3) the built-in annex D `constants.vams` / `disciplines.vams`, or their Verilog-A 1.0 names `constants.h` / `discipline.h` (VD-093), by basename. Not found: E0126, whose note lists the directories in that order (`specification/Vague_Decisions.md` VD-091) | `lib/frontend/pp/directive.zig` `readInclude`, `includerDir` | `ch10_directives/include_searches_the_including_files_directory.va` (nested include beside its includer; includer before `-I`), `include_including_dir_is_per_file_rejected.va` |
| AMS 2.8 | the identifier length limit, at least 1024 | no limit; a long or escaped module name gets a hashed file stem for its build files | `src/zigbuild/orchestrator.zig` `fileStem` | `ch02_lexical/identifier_1024_chars.va`, `ch02_lexical/identifier_1024_char_module_name.va` |
| AMS 2.9 | vendor attributes | `vera_lte`, `vera_interp`, `vera_nodiff`, `vera_timepoint`, `vera_scratch` (AGENTS.md §6) affect device behavior; `vera_interp = 2` (quadratic, `kernel_text.zig` `zAbsdelayQ`) departs from §4.5.7 when set, which requires linear interpolation (`ch04_expressions/absdelay_vera_interp_linear.va`); IEEE §26.6.42 VPI queries expose attribute names, constant values and parsed owners on modeled source objects | `src/analog/stmt.zig`, `src/vpi/attributes.zig` | `ch05_analog_behavior/charge_sites_lte_attribute.va`, `ch04_expressions/absdelay_vera_interp_quadratic.va`, `ch04_expressions/ddx_vera_nodiff_assignment.va`, `ch05_analog_behavior/vera_timepoint_cache.va`, their `reject_*` neighbours, and `ieee_pli/attributes.c` / `analog_attributes.c` |
| AMS 2.9 | `(* vera_timepoint *)`: what a per-timepoint cache is keyed on, and what drops it | one cache per statement in `Instance`, keyed on `$abstime`, `analysis()` and the two §5.10.2 step flags; filled by `eval`/`evalQ` when the statement ran on a stale cache; dropped by `initState`, `setupInstance`, `updateState` and `stateCtl` commit and revert. A statement may assign scalars, scalarized arrays and memory-backed arrays (held or not); only what a later statement reads is cached. Refused: E0529 (value), E0530 (construct inside), E0531 (reads a value an iteration moves), E0532 (in a loop, analog function or `analog initial`). A device with one declares `mutable_eval` and drops `batch_ok` | `src/analog/stmt.zig` `lowerTimepoint`, `src/prove/setup.zig` `timepointVarying`, `src/codegen/device/codegen/instance.zig` `emitTpHelpers` | `ch05_analog_behavior/vera_timepoint_cache.va`, `reject_vera_timepoint_parameter.va`, `reject_vera_timepoint_probe.va`, `reject_vera_timepoint_contribution.va`, `reject_vera_timepoint_operator.va`, `reject_vera_timepoint_event.va`, `reject_vera_timepoint_reads_iterate.va`, `reject_vera_timepoint_in_loop.va` |
| AMS 2.9 | `(* vera_scratch *)` on a variable declaration: what it starts each evaluation at, and where it is refused | never held (no `held_vars` row, no `Instance` field, no copy in `eval`/`stateCtl`): every evaluation, and every entry to a named block for that block's locals, starts it at its declaration's initializer, the §3.2 zero when there is none. On a string variable it drops the §5.10 hold too. Refused: E0534 (value does not fold without the card), E0535 (on a parameter, net, genvar or statement), E0536 (an `analog initial` or `@(...)` body assigns it and a read may see that value before the same evaluation assigns it again: §5.2.1/§5.10 values exist to be read on other evaluations), E0537 (an `initial` or `always` block or a task assigns it: §7.2.2 makes it digital-owned, and the digital kernel, not an analog evaluation, keeps its value). `= "uninit"`: a memory-backed (runtime-indexed) array starts each evaluation with NO store; the author promises every element is written before it is read in that evaluation, and **a read-before-write is the author's bug**: under runtime safety (Debug, ReleaseSafe) the array is filled with NaN in the value and every derivative lane (`minInt(i64)` for an integer array), so it reads NaN; in ReleaseFast/ReleaseSmall nothing is stored and the value is unspecified but stable, never illegal behaviour: after the `undefined` declaration an empty `asm volatile ("" : : [p] "r" (&a) : .{ .memory = true })` (no instructions; accepted by nvptx64 and amdgcn too) may have written the array, so LLVM must treat its contents as defined. It costs the array's SROA: 201 Ir/eval against 116 without it and 233 for the zero start (4-op tape, `st[0:63]`, 8 lanes). A scalar or scalarized array keeps the zero start. Any other string: E0538; an initializer with `"uninit"`: E0539 | `src/analog/var.zig` `scratchOn`, `scratchMode`, `checkScratchOwners`, `refuseDigitalScratch`, `markHeldVars` (`State.carried`); `src/codegen/device/codegen/render.zig` `emitArrayStmt` | `ch03_data_types/vera_scratch_starts_each_evaluation.va`, `vera_scratch_uninit_tape.va`, `vera_scratch_uninit_reads_nan_when_safe.va`, `reject_vera_scratch_unknown_string.va`, `reject_vera_scratch_uninit_initializer.va`, `reject_vera_scratch_parameter_value.va`, `reject_vera_scratch_on_parameter.va`, `reject_vera_scratch_on_net.va`, `reject_vera_scratch_on_genvar.va`, `reject_vera_scratch_event_value.va`, `reject_vera_scratch_analog_initial.va`, `ch07_mixed_signal/reject_vera_scratch_digital_variable.va` |
| AMS 2.8.3 | `$vera_reject_step(t_retry)`, a VerA system task | in a transient, the accepted step whose solution called it with `t_retry < $abstime` is rejected through `contract.UpdateResult.request_reject_at`; several calls in one evaluation: the earliest wins; ignored in a static solve; no `acceptQ` is emitted, since it cannot carry the request; the analog testbench retries at `t_retry` with the forced unknowns held at the rejected time's values, and the mixed and VPI runners refuse a request; in `analog initial` or an analog function, E0533 | `src/analog/systask.zig` `lowerKernelCtl`, `src/codegen/device/codegen/state.zig` `emitStateMachine`, `src/codegen/exe/tb/runner_text.zig` `retry` | `ch05_analog_behavior/vera_reject_step_retry.va`, `reject_vera_reject_step_analog_initial.va` |
| AMS 4.3.1 (Table 4-14) | the accuracy of `exp`, `ln`, `pow` (the table gives each a C equivalent and a domain, no accuracy; 4.3.2's Table 4-15 functions are unchanged) | faithful: max error ≤ 0.52 ulp (exp, ln) and ≤ 0.55 ulp (pow) against the exactly rounded result over every finite input, IEEE 754 special values, identical bits on every target; the only implementation (the previous compiler_rt/`std.math.pow` path and the GPU musl ports are gone). See "Host math" below | `lib/contract.zig` `gm` (`armExp`, `armLog`, `armPow`, `hexp`, `hlog`, `powV`) | `lib/contract.zig` tests "exp/log/pow stay within the documented bound of an f128 oracle", "... fold at comptime to the bits they run to", "armExp/armPow: the contract's special cases ..." |
| AMS 9.7.3 | what `$fatal`/`$error` do in a DEVICE (`--display=record` or `drop`), which cannot print or stop its host | the status channel: each call in the analog context (the analog block, `analog initial`, a `vera_timepoint` statement, an analog function) is a `contract.StatusSite` in `status_sites`, in source order. The first one an evaluation reaches, under its own guards, latches `Instance.vera_status__ = (severity << 24) \| (site + 1)` (severity 1 fatal, 2 error; `contract.statusCode`) and up to four numeric arguments after its format string in `vera_status_args__` (a string argument reads 0; `$fatal`'s finish_number is not one). The status is sticky: a later site changes nothing until `initState` or `setupInstance` clears it. While it is set, `eval`, `q` and `evalQ` return all-zero rows and charges (value and every derivative lane; checked before and after the core), and `updateState` returns `.ok` without touching the state; the device declares `mutable_eval`, drops `batch_ok` and emits no `acceptQ`. `contract.formatStatus` renders `<file>:<line>: fatal\|error: <message>`. `$warning`/`$info` are recorded by `say` (the AMS 9.4 row below); the printing artifact prints all four and exits on `$fatal` as before. Additive: ABI 5 | `src/analog/systask.zig` `lowerStatus`, `src/codegen/device/codegen/instance.zig` `emitStatusHelpers`, `src/codegen/device/codegen/dispatch.zig`, `lib/contract.zig` `StatusSite`, `formatStatus` | `tests/host/status_host.zig` over `tests/fixtures/ch09_system_tasks/status_ops.va` (analog, `analog initial`, `vera_timepoint`, first-wins, the zero plane, `updateState`), `tests/host/status_gpu.zig` (NVPTX IR and AMDGCN object, under `zig build test`) |
| AMS 9.4, 9.4.1, 9.4.6 | how a DEVICE, which cannot print, shows its display tasks (the LRM assumes a simulator that prints) | the output channel (#10), on by default (`--display=record`; `--display=drop` leaves it out). The device publishes `say_sites` (`contract.SaySite`: one C-style format per task, its file and line, and how many values a record carries) and `say(S, x, model, inst, sim, out: *contract.Say)`, which runs the display chain at `x` and appends one record per task that runs (`site, v0, ...` as f64) to the buffer the host lends; a record that does not fit is counted in `Say.lost`, never cut. A host calls `say` once per accepted point, after the solve and before `updateState`, with the `Instance` `eval` saw (VD-094), and renders with `contract.formatSay` (C11 7.21.6.1 conversions; `%m` is the host's name for the instance). Recorded: `$strobe`, `$display`, `$write` (and the radix forms), `$debug`, `$warning`, `$info`, constant strings spliced into the format (`%s`), `%l` as the module name. Not recorded, W0850: `$monitor`, `$finish`/`$stop`, the §9.5 file family, a string argument that is not a constant, a number under `%s`. `$fatal`/`$error` stay the status channel. `Say.pass` (`contract.SayPass`) picks what one call records: `.all` (the default: every task, `$debug` shown at accepted points only), `.iteration` (`$debug` alone, called after each Newton iteration at its iterate, §9.4.1) and `.accepted` (every task but `$debug`, for a host that runs the iteration passes); a `$debug` site records through `Say.putDebug`. `say` is a separate function, compiled only by a host that calls it, GPU targets included; `eval` changes only where a display task reads a variable before the block writes it, which is then held (§3.2), as in the printing artifact. Additive: no `abi_version` change | `src/codegen/device/cg_display.zig` `planSay`, `emitSay`, `src/codegen/device/codegen/dispatch.zig` `emitDisplay`, `lib/contract.zig` `SaySite`, `Say`, `formatSay`; hosts: `src/codegen/exe/tb/runner_text.zig` `sayPoint`, `sayIteration` | `tests/host/say_host.zig` over `ch09_system_tasks/say_ops.va` (the table, a guarded task, `lost`), `tests/host/say_gpu.zig` (NVPTX IR and AMDGCN object), `ch09_system_tasks/say_device_records.va` (`//! display record`: the testbench prints the device's records), `say_debug_every_iteration.va` (`$debug` at each Newton iterate) |
| AMS 3.6.3.2 | which initializer wins when several hierarchical declarations at the highest level name one node ("a race condition"), and when several local ones do | hierarchical beats local; among hierarchical, the shallowest declaring module, then the first in instance-walk order | `src/elab/resolve.zig` `applyOocInits` | `ch03_data_types/nodeset_hierarchical_declaration.va` |
| AMS 4.2.4 | how a required integer-modulus zero-divisor error is reported | a provably evaluated zero is E0601 at compile time; a runtime zero reports E0601 and exits 1 in the executable, and traps in a solver device without host I/O, including GPU targets | `src/prove/prover.zig`, `src/codegen/device/codegen/render.zig` `imodFn` | `ch04_expressions/modulus_by_zero_rejected.va`, `modulo_integer_dynamic_zero.va`, `modulo_integer_unused_zero.va`; legal neighbours `modulo_integer_dynamic.va`, `modulo_integer_short_circuit.va`, `modulo_integer_parameter.va` |
| AMS 4.5.4 | `idt(x)` with no `ic` starts at "c ... as determined by the simulator" | argument reads an unknown: the static solve forces it to zero (c from the loop); otherwise c = 0. (`idtmod`'s c = 0 is not listed: §4.5.5's prose requires it.) | `src/analog/analog_op.zig` `opIdt`, `readsUnknown` | `exhaustive/idt_integral.va`, `ch04_expressions/idt_no_ic_dc_feedback.va` |
| AMS 4.5.5 | where `idtmod` integrates | inside the device, wrapping each accepted step | `src/codegen/device/codegen/kernel_text.zig` `zIdtmod` | `ch04_expressions/idtmod.va`, `ch04_expressions/idtmod_offset_window_negative_integrand.va` |
| AMS 4.5.11 | the DC value of a `laplace_*` filter whose H(s) has a pole at s = 0 (the clause gives H(s) and no DC rule) | 0, the integrator state starting at 0 as for `idt` above; a power of s common to both sides cancels first, so `s/(s + s²)` is 1; a transient starts from the static point with every past sample of each section equal to it | `lib/backend/kernels/filter_kernels.zig` `zH0`, `zLaplaceStep` | `ch04_expressions/laplace_nd_pole_at_origin.va` |
| AMS 4.5.11, 4.5.12 | a `*_zp`/`*_zd`/`*_np` root vector whose parts the model card sets (a parameter array), where "its conjugate shall also be present" cannot be checked at compile time | a vector whose imaginary parts all fold without the card, and whose card-set real parts pair by their text, keeps the compile-time pairing (one section per real root, one quadratic per conjugate pair). Otherwise its section structure is fixed at `(M + 1) / 2` real sections of degree ≤ 2, filled on every `__sec` read by `zRootSecs`: a root with imaginary part exactly 0 is real and real roots combine two at a time in vector order (a leftover one is a degree-1 section, the runtime degree trim runs it as one); a zero root is §4.5.11's `s` / §4.5.12's z⁻¹; a complex root a + jb pairs with the first unused root within 1e-9·\|a + jb\| of a − jb (`zroot_tol`). A complex root with no such partner makes every coefficient of the cascade NaN, so the filter's output is NaN in every analysis: never a different filter reported as this one. An odd-length root vector is E0540 at compile time | `src/codegen/device/cg_filters.zig` `filterSide`, `runtimeRoots`; `lib/backend/kernels/filter_kernels.zig` `zRootSecs` | `ch04_expressions/laplace_zp_parameter_roots_step.va`, `laplace_zp_parameter_roots_ac.va`, `laplace_np_parameter_roots_unpaired_is_nan.va`, `zi_np_parameter_roots_dc_gain.va`, `reject_4_5_11_1_laplace_zp_parameter_roots.va` |
| AMS 4.5.11 | how a `laplace_*` section is integrated in a transient (the clause gives H(s) only) | the trapezoidal rule (bilinear transform, s = (2/dt)(1 − z⁻¹)/(1 + z⁻¹)), realised for a proper section (numerator degree ≤ denominator degree, after common powers of s cancel) as the controllable canonical states of the monic denominator stepped in increment form, (I − (dt/2)A)Δx = (dt/2)(2(Ax + Bu_prev) + B(u − u_prev)), solved along the companion chain in O(degree). Mathematically the same discrete filter as direct form on the bilinear coefficients, which VerA used until 2026-10-01; numerically, a held input leaves a state with Ax + Bu = 0 where it is, so the steady output is H(0) to rounding. Direct form made the fixed point Σb/Σa, which is roundoff when a pole is slow against the step (Σa ~ (ω·dt)^degree of its terms): a degree-6 section with ω·dt = 1e-5 drifted 5.3e-7 off H(0) in 200 steps, and a fitted line with a 3 kHz pole settled 0.6% low at dt = 0.1 ns. The states are continuous-time, so a step size change needs no history rewrite. An improper section (s/1) keeps direct form I on its bilinear coefficients | `lib/backend/kernels/filter_kernels.zig` `zSsForm`, `zSsStep`, `zSsRest`, `zLaplace`, `zLaplaceStep` | `ch04_expressions/laplace_nd_slow_pole_holds_dc_gain.va`; the transient laplace fixtures (`laplace_nd_ramp_response.va`, `laplace_filters.va`, ...) within their stated tolerances |
| AMS 4.5.14 | when "the start of the analysis" is, for a `laplace_*`/`zi_*` coefficient the solve moves (a constant-expression slot of Table 4-20) | the static solve: there the coefficient is read live, since that solve is the start; `updateState` latches the accepted static value into `Instance` (`<unit>__k`), and every later point, including the whole transient, reads the latch. A transient with no static point first reads 0 (as `absdelay`'s sampled `maxdelay`). A moving `zi_*` period, τ or t0 is still refused | `src/codegen/device/cg_filters.zig` `Coefs`, `src/codegen/device/codegen/call.zig` `sampledCoefs`, `src/codegen/device/codegen/state.zig` `secStep` | `ch04_expressions/laplace_dynamic_coefficient_sampled.va`, `laplace_zp_dynamic_pole_sampled.va`, `zi_nd_dynamic_coefficient_sampled.va` |
| AMS 4.6.1 | analysis names beyond Table 4-21 | none: any other name is false | `src/codegen/device/codegen/call.zig` `analysisMatch` | `ch04_expressions/analysis_transient.va` |
| AMS 4.6.1, 4.6.2 | whether the nodeset phase has evaluations in it | none: a nodeset is Newton's starting point, so `analysis("nodeset")` is 0 at every evaluation (VD-117) | `src/codegen/exe/tb/runner.zig` `pointUnknowns`, `runner_text.zig` `atPoint` | `ch04_expressions/nodeset_phase_has_no_evaluation.va` |
| AMS 9.15 | `$simparam$str("analysis_type")` at a transient's t = 0 point | "ic", the Table 4-21 analysis it evaluates as (VD-118) | `src/codegen/device/codegen/call.zig` `$simparam$str` | `ch09_system_tasks/simparam_str_analysis_type_tran_op.va` |
| AMS 4.6.3 | the small-signal analysis name | `"ac"` (VD-064), and for any other `ac_stim` name the host's Table 9-28 `analysis_name` label of a small-signal analysis (VD-109, `contract.acStimActive`) | `src/analog/contrib.zig` `acAnalysisName`, `src/codegen/device/codegen/call.zig` `acStimMatch` | `ch04_expressions/ac_stim_ac_analysis.va`, `ch09_system_tasks/simparam_str_analysis_name_host_table.va`, `ch04_expressions/ac_stim_label_inactive_in_large_signal.va` |
| AMS 4.5.12 | a `zi_*` filter's τ and t0: the shape of a non-zero transition, the output before the first transition at t0, how the corners are resolved, and an absent τ | samples fall on t0 + k·T. Each sample starts a linear transition, τ long, from the value the previous transition had reached at that instant. Before a positive t0 the output holds H(1) times the operating-point input. The corners are resolved by bounding the step at τ (and T); no breakpoint is published. AC small-signal ignores τ and t0. An absent τ is the abrupt τ = 0 form, not `` `default_transition ``. A τ that does not fold without the card is read from the card; a negative one is E0540 | `src/codegen/device/cg_filters.zig` `filterPlan`; `lib/backend/kernels/filter_kernels.zig` `zZiEvalRamp`, `zZiRamp`; `src/codegen/device/codegen/state.zig` | `ch04_expressions/zi_transition_time_and_first_transition.va`, `zi_negative_transition_time_rejected.va` |
| AMS 5.10.3.1 | the `time_tol` of a `.v` contract device's A2D bridge (7.8 supplies no connect module) | card `ttol`, by default min(trise, tfall)/50; only a step where some process wakes is held to it | `lib/sim/rt/device.zig` `ttol` | `tests/host/vdev_host.zig`, "v_edge and v_any" |
| AMS 5.10.3.1, 5.10.3.3 | `cross`/`above` tolerances and `timer` time_tol when the tool sets them | the fixed-grid testbench (`--run`, `--emit-exe`, no discrete half) inserts no timepoint: the event fires at the first `//! time` point past its time (W0750); a `//! time` grid with no `//! analysis` line is `tran` | `src/codegen/exe/tb/runner.zig` `warnGridEvents`, `src/codegen/exe/tb/directive.zig` | `ch05_analog_behavior/event_cross_fires_on_a_time_grid.va` |
| AMS 5.10.3.4 | absent or zero `absdelta` tolerances and interpolation within the event window | `time_tol` defaults to 1 ps and is at least the digital precision; `expr_tol` defaults to 1e-12 in expression units; delta events use the interpolated delta crossing when eligible, otherwise the first time outside the time-tolerance exclusion; significant reversals use the observed point | `lib/sim/mixed.zig` `absdeltaArgs`, `nextAbsdelta` | `ch07_mixed_signal/absdelta_runtime_default_tolerances.va`, `absdelta_runtime_time_precision.va`, `absdelta_runtime_time_tol.va`, `absdelta_runtime_reversal.va` |
| AMS 9.4.3 | the '#' flag on a conversion outside Table 9-23's C rows: the clause grants "the full formatting capabilities available in the C language" to Table 9-23 only, C has no `%h`/`%b`/`%m`/`%l`/`%r`, and C's `%#x`/`%#o` prefix meets IEEE 1364-2005 §17.1.1.3's automatic sizing with no rule | '#' is C11 7.21.6.1p6's alternative form on `%e`/`%f`/`%g` (the point always prints, `%g` keeps its zeros); on any other conversion, `%m`/`%l`/`%r` included, it is E0825 at compile time, and a `$sformat` format known only at run time copies that specification as text with a warning (#41) | `lib/backend/kernels/str_kernels.zig` `zcFlag`, `zcAltOk`, `zCReal`; `src/analog/systask.zig` `nextConv`, `prepareFormatArgs` | `ch09_system_tasks/real_hash_flag_e_always_prints_the_point.va`, `real_hash_flag_f_always_prints_the_point.va`, `real_hash_flag_g_keeps_trailing_zeros.va`; refusals `real_hash_flag_string_operand_rejected.va`, `hash_flag_without_alternative_form_rejected.va` |
| AMS 9.4.3 | what an explicit `%g` precision counts: the clause's example ("the format specification %10.3g sets a minimum field width of 10 with three (3) fractional digits") contradicts the C grant it illustrates (C11 7.21.6.1p8 counts significant digits) | fractional digits, the example's reading: `%.3g` of 1234.5678 is `1234.568`, the `%.3f` text, with no trailing-zero removal; `%g` with no precision is C's (six significant digits, then zeros stripped), where the two readings agree. The device kernel and the host's rendering of a recorded `Say` (`contract.formatSay`) print the same text (#44) | `lib/backend/kernels/str_kernels.zig` `zCReal`; `lib/contract.zig` `cReal` | `ch09_system_tasks/real_g_conversion_is_significant_digits.va` (no precision; the explicit rows withdrawn); `lib/backend/kernels/test.zig` "a %g precision: the device's zCReal and the host's formatSay print one text" |
| 1364 17.1.1.2, 17.1.1.3; AMS 9.4.7 | C's flags in the digital context: 17.1.1.2 grants "the full formatting capabilities available in the C language" to Table 17-3's real conversions, while 17.1.1.3 sizes the others with no word on '-', '+' or ' ' | on `%e %f %g` every C11 7.21.6.1p6 flag renders (`%08.3f` zero-fills after the sign, `%-8.2f` pads on the right), on §9.4.7's `%r` every one but '#'; on any other conversion '-', '+' and ' ' are E0827 and '#' is E0825, refused at compile time (the format walk validates every literal format) and ending the run for a format held in a variable; leading zeros stay §17.1.1.3's width digits there (`%0d`, `%05d` is width 5) (#43) | `lib/sim/fmt.zig` `spec`, `flagVerdict`; `lib/sim/digital/display.zig` `walk`, `real`; `lib/sim/rt/system.zig` `scanSpec` | `ieee1364/17_system_tasks/real_c_flags.v`; refusal `c_flag_on_integer_rejected.v` |
| AMS 9.4.2, 1364 17.1.1.1 | a flag, width or precision inside the `%%` escape (`%5%`, `%-%`, `%.2%`): Table 9-21 and Table 17-1 list `%%` as two characters, and C11 7.21.6.1p8 ("The complete conversion specification shall be %%") leaves `%5%` undefined, so the real conversions' C grant gives it no meaning | E0826 at compile time, analog (lowering) and digital (the digital engine's format walk) alike; a format known only at run time copies it as text with a warning (analog `$sformat`) or ends the run (digital `$sformat`) (#42) | `src/analog/systask.zig` `nextConv`, `prepareFormatArgs`; `lib/sim/digital/display.zig` `walk`; `lib/sim/rt/system.zig` `scanSpec` | `ch09_system_tasks/percent_escape_with_width_rejected.va`, legal neighbour `percent_escape_prints_one_percent.va`; `ieee1364/17_system_tasks/percent_escape_with_width_rejected.v`, legal neighbour `escape_sequences.v` |
| AMS 9.5.7, 1364 17.2.7 | `$ferror` codes | C errno values (2, 5, 9, 12, 13, 21, 22, 24, 28); fixtures assert only nonzero | `lib/backend/kernels/file_kernels.zig` `zfErrno` | `ch09_system_tasks/ferror.va`, `write_mode_path_65_opens.va` |
| AMS 9.7.2 | what `$stop` does in a batch run | prints and exits 0 | `src/codegen/device/cg_display.zig` `emitSimCtl` | `ch09_system_tasks/stop_terminates.va` |
| AMS 9.13.1 | the seed of an omitted-seed analog `$random` or `$arandom` | one per omitted-seed site, `1 + 7919·k`; `k` counts all non-variable-seed sites in lowering order, including constant/parameter sites | `src/analog/random.zig` `lowerRandom` | `tests/host/revert_host.zig` (numbering/trajectory); `ch09_system_tasks/random_no_seed.va` (width) |
| AMS 9.15 | which `$simparam` names exist ("There is no fixed list of simulation parameters") | Table 9-27's `gmin` (1e-12), `tnom`, `scale`, `shrink` and `sourceScaleFactor` (1), `iteration`, and `timeUnit`/`timePrecision` when a `` `timescale `` is given; beyond the table, SPICE's `reltol`, `abstol` and `vntol`, and `dt`: the host's `SimState.dt` unchanged (the step since the last accepted point, 0 in a static solve; no derivative, never hoisted into `setup`, readable inside `vera_timepoint`). `tnom`, the three tolerances, `gmin` and `sourceScaleFactor` are host-written `Model` fields (`nom_temp__`, `reltol__`, `abstol__`, `vntol__`, `gmin__`, `source_scale__`) defaulting to 27, 1e-3, 1e-12, 1e-6, 1e-12 and 1, since a host steps gmin and the source factor during a run (`specification/Vague_Decisions.md` VD-072); `scale` and `shrink` are 1, because geometry scaling is applied when the card is built; any other name without a fallback is E0811; `$simparam$str` knows Table 9-28's six names and refuses any other literal with E0811 (it has no fallback), and its `"cwd"` and `"analysis_name"` are host-written: `contract.host_strings` at the `Model` row's `cwd_idx__`/`analysis_name_idx__` when nonzero, else the `Instance` slices `cwd`/`analysis_name` (VD-110); the testbench fills the table from its working directory and `//! analysis <kind> [<name>]` | `src/analog/sysfunc.zig` `simparamValueIn`, `host_simparams`, `simparam_str_names` | `ch09_system_tasks/simparam_newton_tolerances_host_written.va`, `simparam_gmin_source_scale_host_written.va`, `simparam_fallback_as_parameter_default.va`, `simparam_minr_hicum_l2_default.va`, `simparam_spice_option_not_known_rejected.va`, `simparam_unknown_no_fallback_rejected.va`, `simparam_dt_is_the_host_step.va`, `exhaustive/environment.va`, `simparam_str_cwd_and_analysis_name.va`, `simparam_str_cwd_host_table.va`, `simparam_str_analysis_name_host_table.va`, `simparam_str_unknown_name_rejected.va` |
| AMS 9.17.3 | the `$limit` built-ins | `pnjlim`, `pnjlimds`, `fetlim`, `fetlimds`, `limvds`, `steplim`; any other name, or a bare `$limit(x)`, returns the probe | `src/codegen/device/codegen/plan/limit.zig` `Alg` | `annex_e_spice/limit_pnj.va`, `limit_fet.va`, `limit_vds.va`, `limit_pnjlimds_bulk_rung.va`, `ch09_system_tasks/limit_steplim_internal_node_honoured.va`, `limit_unknown_algorithm_returns_probe.va` |
| AMS 9.17.3 | arguments past the algorithm's own | an optional frame sign, then an optional seed; more declines the site (W0853) | `src/codegen/device/codegen/plan/limit.zig` `plan` | `ch09_system_tasks/limit_polarity_sign_argument_honoured.va`, `limit_too_few_arguments_returns_probe.va`, `limit_too_many_arguments_returns_probe.va` |
| AMS 9.17.3 | the starting value of a limited branch (SPICE MODEINITJCT) | seeds solved into node values from a 0 V root (ground, else lowest port, else lowest net); an unseeded pnjlim leg starts at vcrit; fetlimds vgd and pnjlimds vbd legs are never seeded; a seed reading the solution is E0527, one the tree cannot take W0854 | `src/codegen/device/codegen/plan/limit.zig` `planSeed` | `annex_e_spice/limit_seed_mos1_initjct.va`, `limit_seed_bsim3_pmos_initjct.va`, `limit_seed_explicit_beats_default.va`, `reject_limit_seed_reads_solution.va` |
| AMS 9.20 | a whole-vector analog_net_reference: the clause admits one, but its validity rules make the target "a scalar continuous node or a scalar element of a continuous vector node" and the alias "the same circuit matrix position" | every element is aliased to the one target node, status 1; a vector target string violates the scalar rule, status 0, and the vector stays local | `src/analog/hier_name.zig` `checkAliasCall`, `aliasVector` | `ch09_system_tasks/node_alias_whole_vector_reference.va`; bit select refused, `node_alias_bit_select_rejected.va` |
| AMS 12.36 | the number of `vpiRejectTransientStep` | 730 | `src/vpi/vpi_user.h` `vpiRejectTransientStep` | `ch12_vpi_routines/sim_control_reject_step.c` |
| AMS 12.22.2, 12.30, 12.32.2 | which arguments of an analog system task its calltf may put a value or a partial on (12.30 lists "nets, regs, variables, memory words, system function calls, sequential UDPs, and schedule events"; 12.22.2 prints only a real variable) | an argument that is a `real` or `integer` variable named alone, read back by the design after the call (`contract.Systf.outs`, `SystfHost.output`); an integer rounds (4.2.1.1); one calltf did not put keeps its value. Any other argument (an access function, a parameter, an expression, an array element, a `reg`) is refused, NOPUT | `src/analog/systask.zig` `systfOutputs`, `src/vpi/analog.zig` `putArg`, `deviceOut` | `ch12_vpi_routines/task_output_jacobian.c` (the put onto `V(q, gnd)` refused, the put onto `icube` taken), `ch11_vpi/systf_analog.c`, `ch12_vpi_routines/derivtf_partials.c` |
| AMS 12.31.3, 12.8 | the analog callbacks an AC sweep delivers | its operating point is acbInitialStep at frequency 0, each frequency an acbAcceptedPoint, the last also acbFinalStep (`Vague_Decisions.md` VD-098) | `src/vpi/analog.zig` `sweep` | `ch12_vpi_routines/ac_freq_and_imaginary.c` |
| AMS 12.16, 1364 27.14 | `vpiIntVal` of an object wider than the `PLI_INT32` it fills | the low 32 bits, two's complement, no error (x and z bits read 0) (`Vague_Decisions.md` VD-049) | `src/vpi/value.zig` `formatInto` | `ch11_vpi/get_value_formats.c` (`reg [63:0]` 64'h00000001FFFFFFFF reads -1) |
| AMS E.3.3 | a warning when an HDL module or paramset shadows an always-available SPICE primitive is optional | no warning for primitive shadowing; W0951 for the required same-name model/subcircuit warning | `src/elab/names.zig` `warnSpiceShadows`, `findModule` | `annex_e_spice/spice_paramset_primitive_shadow.va`, `spice_module_shadow_warning.va`, `spice_paramset_shadow_warning.va`, `spice_shadow_case_neighbour.va`, `verilog_module_wins_over_netlist_subckt.va` |
| AMS 2.8.3 | `$` names VerA uses internally | `$held_int`, `$held_real`, `$idx`, `$limit$old`, `$str$cat`, the `$rng$` family and the others after `$held_int` in `Callee` are reserved (E1014) | `src/ir/callee.zig` `synthetic` | `ch09_system_tasks/reserved_system_function_name_rejected.va` |
| 1364 8.1.2 | the UDP input limit, at least 9 sequential and 10 combinational | none | `lib/frontend/parser/udp.zig` | `ieee1364/08_udp/input_minimums.v`, `sequential_64_inputs.v`, `udp_65_inputs.v` |
| 1364 11.4.2 | the order of active events | processes start in source order from a FIFO queue; woken processes resume in the order they suspended; the interpreter and native code agree | `lib/sim/scheduler.zig` `Scheduler.next`, `lib/sim/digital/waiters.zig` `wake` | `ieee1364/11_scheduling/sched_fork_arm_chain_order.v`, `sched_fork_arm_wake_order.v`, `sched_node_wake_order.v` (no clause cite) |
| 1364 13.4.4 | which of several configs configures the design | the config no other config's `use` clause names; two such, or none, is E0243 (Vague_Decisions VD-083) | `lib/sim/digital/bind.zig` `top` | `ieee1364/13_configuration/hierarchical_config.v`, `two_unreferenced_configs_rejected.v`, `every_config_referenced_rejected.v` |
| 1364 17.2.4.1 | how many characters `$ungetc` can push back | 16 per descriptor; the 17th returns EOF | `lib/backend/kernels/file_kernels.zig` `ZFSlot.back` | `ieee1364/17_system_tasks/ungetc_pushback_limit.v` |
| 1364 17.2.1, 27.25 | which bit an mcd `$fopen` returns | 1 << k for the lowest free slot k from 1; under a VPI application, the lowest free channel from 4, one table with `vpi_mcd_open` (channels 2 and 3 are AMS 12.26's stderr and log) | `lib/backend/kernels/file_kernels.zig` `zFOpen`, `src/vpi/print.zig` `share` | `ieee_pli/mcd.c` |
| 1364 17.9.1 | the stream of a seedless `$random` | one hidden seed per run, starting at 0 | `lib/sim/digital/root.zig` `Run.random_seed` | `ieee1364/17_system_tasks/seedless_random_starts_at_seed_0.v` |
| 1364 19.8 | time unit and precision with no `` `timescale `` | 1 s / 1 s | `lib/sim/digital/root.zig` `default_quantum` | `ieee1364/19_compiler_directives/no_timescale_is_1s_1s.v` |
| 1364 15.5 Table 15-13 | the value a violation gives a notifier at x ("Either 0 or 1"), and a vector notifier | 1; each bit of a vector notifier by the table (`specification/Vague_Decisions.md` VD-103) | `lib/sim/digital/tchk.zig` `toggle` | `tchk.zig` test "VD-103"; `ieee1364/15_timing_checks/notifier.v` asserts only the permitted set |
| 1364 15.1-15.7 | when a timing check is judged (11.4.2's order inside a time step), when a condition is read, which bit a vector's edge is | at the timecheck event, a simultaneous reference/data pair judged once whichever comes first; conditions read at their event; a vector edge on its least significant bit (VD-104) | `lib/sim/digital/tchk.zig` | `ieee1364/15_timing_checks/hold.v`, `setuphold.v`, `conditions.v`, `vector.v` |
| 1364 15.2, 15.3 | how a timing violation is reported | warning W1199 for a check's first violation: the check, the instance, and its two events' times in the instance's time unit; later ones toggle the notifier only (VD-105) | `lib/sim/digital/tchk.zig` `violation` | every `ieee1364/15_timing_checks/` positive fixture (`// digital-runner: warning`) |
| 1364 C.7; AMS 12.36 | what a reset keeps, and stop_value 0 in a run with no interactive mode | the run re-elaborated in place; callbacks, value-change watches and put delays and limits stand; stop_value 0 ends the run; reset_value unread (VD-106) | `lib/sim/digital/root.zig` `Run.reset`, `src/vpi/run.zig` | `ch12_vpi_routines/sim_control_reset.c`, `sim_control_reset_run.c` |
| none (CLI) | `--state=auto` | runs 4-state until a time step starts with no live x or z, then 2-state; an x or z stored later reruns the design 4-state | `lib/sim/rt/root.zig` `auto` | `ieee1364/11_scheduling/auto_state_two.v`, `auto_state_rerun.v`, `auto_state_never_written.v` |
| 1364 26.2.4 | what a routine called while `vlog_startup_routines` run does (the clause allows only `vpi_register_systf` and `vpi_register_cb`, the latter for six reasons, and names no failure) | refused: the routine's documented failure value and a `vpi_chk_error` error, code `STARTUP`, citing 26.2.4; `vpi_register_analog_systf` (VAMS 12.32) and `vpi_chk_error` are allowed; `vpi_register_cb` takes cbEndOfCompile, cbStartOfSimulation, cbEndOfSimulation, cbError and cbPLIError (cbUnresolvedSystf is never delivered) (`Vague_Decisions.md` VD-044) | `src/vpi/root.zig` `refused`, `src/vpi/callback.zig` `startupReason` | `ieee_pli/startup_phase.c`; every `.c` fixture defers its work to cbEndOfCompile (`p02_defer`, `p03_defer`) |
| AMS 12.22; 1364 26.6.16 | when an inter-module path exists, and what a put of its delays does | made on demand for an output (or inout) and an input (or inout) port of one size, one handle per pair; 2 or 3 delays starting at 0, held by the model and read back, never simulated; a put warns W0251 and needs a digital run (`Vague_Decisions.md` VD-114) | `src/vpi/delays.zig` `interModPath`, `putPathDelays` | `ch12_vpi_routines/intermod_path.c` (with its refusals) |
| 1364 G | what a routine does with an Annex G name whose question VerA does not answer | every name is defined with Annex G's value; the question is refused with vpiError, code NOTSUPPORTED, naming the constant and why (`Vague_Decisions.md` VD-114) | `src/vpi/root.zig` `unansweredType`, `unansweredProp`; `src/vpi/callback.zig` `unansweredReason` | `ieee_pli/b_G_vpi_user.c`; `src/vpi/test.zig` |
| 1364 26.3.5, G | the number of `vpiIsProtected`, which Annex G does not define | Annex G's `vpiProtected` (10); every object answers it, FALSE, since `pragma protect` is refused (E0146) (`Vague_Decisions.md` VD-045) | `src/vpi/vpi_user.h` `vpiIsProtected`, `src/vpi/property.zig` `vpi_get` | `ieee_pli/protected.c` |
| 1364 17.2.4.1 | how many characters `$ungetc` can push back, and which reads see them | 16 per descriptor; the 17th returns EOF, as does a push at file position 0 (C leaves the position after it indeterminate). `$fgetc`, `$fgets`, `$fscanf` and `$fread` all read the pushback before the file, and pushback a read leaves unread stays the next input (VD-084) | `lib/backend/kernels/file_kernels.zig` `ZFSlot.back`, `zFUngetc`, `zFGets`, `zFWindow`, `zFTake`; `lib/sim/digital/system.zig` `fileScan`, `finishFileScan` | `ieee1364/17_system_tasks/ungetc_pushback_limit.v`, `ungetc_read_routines.v` |
| 1364 17.6.5, 17.6.6 | a `$q_exam` `q_stat_code` outside Table 17-15's 1 to 6 | a constant one is refused (E1100); one known only at run time returns status 2 and leaves `q_stat_value` unchanged (VD-050) | `lib/sim/digital/compile.zig` `.queue`, `lib/sim/digital/system.zig` `queueStep` | `ieee1364/17_system_tasks/q_exam_code_rejected.v`, `q_exam_code_runtime.v` |
| 1364 17.6.5 | whether `$q_exam` code 3, "Maximum queue length", is the configured `max_length` or the observed peak | the largest length the queue has reached (VD-051) | `lib/sim/digital/system.zig` `queueStep` (`peak`) | `ieee1364/17_system_tasks/q_exam_peak_length.v` |
| 1364 17.6.5, 3.5.3 | how `$q_exam`'s means (code 2, mean interarrival time; code 6, average wait) become the integer `q_stat_value` | the exact mean rounded to the nearest integer, ties away from zero, as §3.5.3 converts a real; 0 with no interarrival or no completed wait (VD-052) | `lib/sim/digital/system.zig` `mean` | `ieee1364/17_system_tasks/q_exam_means_round.v` |
| AMS E.1, E.1.2, E.2 | the SPICE flavour and primitive behaviour | SPICE3 card syntax for `.MODEL` (types npn, pnp, d, nmos, pmos, njf, pjf, nmf, pmf, r, c, l; any other type is a Verilog-A module a body card may name) and for `.SUBCKT` bodies of numeric-valued R/C/L/V/I/E/F/G/H cards and of M/Q/J/D cards naming a model (its `.MODEL`'s module type with the card's parameters, `M=` as `$mfactor`, or a module/paramset of that name); `.INCLUDE`, `.LIB file entry` and `.HDL` anywhere, relative names beside the naming file. Not claimed: `PARAMS:`/`k=v` on a `.SUBCKT` header, `{expr}` values, nested `.SUBCKT`, X/S/other device cards, binned models, model-referenced R/C/L, trailing fields; inside a `.SUBCKT` each is E0928, as is an unreadable `.INCLUDE`/`.LIB`; a card whose model is a Table E.1 semiconductor `.MODEL` (no Behavior) is E0953; cards outside any definition are skipped (VD-012). A `.MODEL` whose type is no Table E.1 row declares no module of its own name, and a Verilog-AMS instance of it is E0952. Netlist names match Verilog-AMS declarations regardless of case (E.2.1). Primitives per each `primitive_*.va` header | `lib/frontend/spice_cards.zig`, `lib/frontend/preprocessor.zig` `process`, `src/elab/names.zig` `spiceCase` | `annex_e_spice/spice_model.va`, `spice_subcircuit.va`, `subckt_body_contributes_equations.va`, `spice_fet_card_instantiates_model_module.va`, `spice_lib_include_hdl.va`, `primitive_*.va`; `reject_spice_subckt_params.va`, `reject_spice_expression_value.va`, `reject_spice_nested_subckt.va`, `reject_spice_model_referenced_card.va`, `reject_spice_unread_device_card.va`, `reject_spice_fet_card_model_has_no_behaviour.va`, `reject_spice_binned_model.va`, `reject_spice_lib_entry_missing.va` |
| 1364 13.2.1.1, 4.11 | two modules with one name in one compilation (13.2.1.1 says the last is the cell with a warning; 4.11 forbids the reuse) | the last definition is the cell, W1152 at it, in both engines (Vague_Decisions VD-009) | `lib/sim/digital/bind.zig` `libraries`; `src/elab/names.zig` `findModule`, `warnRedefinedModules`; `src/elab/elaborate.zig` `pickTop` | `ieee1364/13_configuration/same_name_cell_last_wins.v`, `ch06_hierarchy/same_named_module_last_wins.va` |
| AMS 7.4.4, F.2.2 | how the discipline resolution mode is selected ("vendor-specific"; F.2.2 "a simulator option") | `--discipline-resolution=basic\|detail` (fixtures: `//! discipline-resolution`), default basic; detail is Annex F.2.2 with step 5 | `src/cli/args.zig`, `src/elab/segment.zig` | `ch07_mixed_signal/discipline_resolution_detail_figure_7_4.va`, `discipline_resolution_basic_figure_7_3.va`, `auto_insertion_figure_7_6_*.va`, `discipline_resolution_detail_one_level.va` |
| none (CLI) | debug information in a native artifact | a ReleaseFast/ReleaseSmall `--emit-so` (analog or `.v` device) and `--emit-exe`/`--run` are built `-fstrip`; `--debug-info` keeps DWARF. Debug and ReleaseSafe always keep it (their safety panics print stack traces). Stripping leaves the analog devices' `.text` identical and halves psp103's and bsim4va's build (`docs/measurements/codegen-levers-2026-09-30.md` lever 1) | `src/zigbuild/orchestrator.zig` `strip` | `src/zigbuild/orchestrator.zig` test "an optimized build strips unless debug information is asked for" |
| none (CLI) | how `--emit-so` builds a large device | an LLVM build of at least 768 KiB of device text runs one `zig build-obj` per `contract.DevicePart` (setup, state, eval) in parallel and links them; a `dyn` host with `exportDevicePart` exports each part's entry points from its own object, one without it gets `exportDevice` in the setup object. Smaller devices and the native backend build one object (below it, the split measured no gain for mos1 and a code-layout eval slowdown for txl) | `src/zigbuild/orchestrator.zig` `splits`, `split_min_bytes` | `src/zigbuild/orchestrator.zig` test "a split build links one object per part into a library that runs" |
| none (CLI) | how a large `setup` is emitted and built | a `setup` of at least 256 KiB of emitted text is emitted as `zSetup<k>` chunks of about that size (`setup_chunks.n`), its top-level statements cut where the relooper's shape allows (a labelled block whose `break`s are all in tail position is opened; a two-armed `if` whose arms jump only inside themselves becomes a stored condition guarding each arm statement), values crossing a cut kept in a scratch struct `setup` passes along. Every statement runs once, in order, on the same values: the roots are bit-identical. A split build compiles each chunk in its own object when the `dyn` host declares `SetupValue(D)`, the value scalar it passes `setup`; otherwise `setup` calls the chunks directly. No balanced cut (more than 3/4 in one chunk) keeps one function | `src/codegen/device/codegen/setup_chunk.zig` `chunk_bytes`; `src/zigbuild/orchestrator.zig` `pieceNames` | `src/codegen/device/codegen/setup_chunk.zig` test |
| none (CLI) | how `--emit-so` builds a `.v` device | an LLVM build links the digital engine's design-independent half (`lib/sim/rt/engine.zig`: the event loop and the tick-boundary snapshot) as one object built once per engine sources, compiler, target, CPU and flags, in `vera-engine` under Zig's global cache directory (`ZIG_GLOBAL_CACHE_DIR`, `XDG_CACHE_HOME/zig`, `HOME/.cache/zig`; else the work directory's cache). The key is the compiler's own cache manifest; the object's symbols carry a hash of `State`'s layout and the root options, so a mismatched object fails to link. v_count 17.0 → 4.9 Gi, v_inv 22.2 → 5.1 Gi once the object exists (the first build also builds it, ≈16 Gi); the native backend compiles the whole engine (no gain measured) | `src/zigbuild/orchestrator.zig` `buildEngine`, `src/main.zig` `engineCache` | `src/zigbuild/orchestrator.zig` test "buildEngine reuses its object only while every key component is unchanged", `tests/host/vdev_so_host.zig` |
| none (host ABI) | numeric parameter bindings carry a value without HDL type/width metadata | a card value is an unsized integer (1364 3.5.1, 4.10.1): `$clog2` of a non-local parameter with no type or range, when the card sets it (`$param_given`), reads it as a signed 32-bit integer, or 64-bit when some such card value in the operand does not fit 32 bits; unset, the final elaborated declaration's width and signedness apply as before. A declared range or `integer` keeps its width under a card value; HDL instance overrides supply their own width before code generation (`specification/Vague_Decisions.md` VD-089). Ceiling: one set/unset and one fits-32 decision covers all such parameters of one operand | `src/analog/sysfunc.zig` `lowerClog2`, `hostSized`; `src/analog/constfold.zig` `hostSizedParam`, `clog2Width`, `clog2Signed` | `ch09_system_tasks/clog2_inferred_parameter_width.va`, `clog2_nested_contexts.va` |
| none (host ABI) | how a host supplies top-level geometric system parameters | a declared §3.4.7 alias supplies a real model-card slot, shared by additional aliases of the same system parameter; defaults are Table 9-29's identities and descendants retain the host dependency | `src/elab/hier_param.zig`, `src/analog/param.zig` `aliasSystemParam` | `ch09_system_tasks/geometry_top_alias_host.va` |
| none (host ABI) | what a batch of several operating points (a family whose `V` is a vector of W points) returns when the device decides on a per-point value (a real comparison, a real→integer conversion, a `$limit`/`ddx`-stripped value, a pow with a varying exponent) | exact per point: bit for bit what a scalar family returns for that point alone, divergent batches included. The batch key is the `Model` row (card, temperature, setup cache, port mask) and the `SimState`; nothing else is shared. Each point has its own `Instance`: a device whose `eval` reads per-instance state as a value (a §5.10 held variable, a `$prev` path latch, `$mfactor`) declares `batch_inst` and reads it per point through the batch family's `instLane(T, w)` (`zInst`; an integer field is a lead-protocol decision, `zInstI`); every value computed from such a field is per point too (`Analysis.pointDep`), never folded through `.val()`. Per-instance state no point can carry that way (operator history, a held array, `$limit`'s previous value, plusargs, a host system function) drops `batch_ok`. `updateState`, `stateCtl`, `setupInstance` and `initState` have no batched form: the host calls them per instance. Such a device declares `batch_ok` and `batch_lead`, and its `eval`, `q` and `evalQ` run the lead protocol (`contract.LeadState`). The leader point's outcome steers every decision. Points that disagree are re-run under the next leader, and each point's result comes from a run it never diverged in. A divergent batch costs one run per distinct path, never a wrong value. A vector family without the protocol is a compile error (`zLeads`). `contract.region(D, x, model, inst, sim)` returns a `u16` hash of a point's decision outcomes. Equal decisions give equal signatures, so a batch of equal signatures runs once (a collision costs a re-run, never a wrong value). A scalar family's results are unchanged. Measured in `docs/measurements/batched-lead-2026-10-02.md` | `src/codegen/device/codegen/float/lanes.zig` `leadLanes`, `src/codegen/device/codegen/dispatch.zig` `writeLead`, `src/codegen/device/codegen/kernel_text.zig` `zCmp`, `zRoundI`, `zStrip`, `zPowL`, `zLeads`, `zInst`, `zInstI`, `src/codegen/device/codegen/float/lanes.zig` `instLanes`, `instPin`, `lib/contract.zig` `LeadState`, `leadMergeInto`, `region` | `lib/contract.zig` test "LeadState: ..."; the testbench's batch family (`src/codegen/exe/tb/runner_text.zig` `laneCheck`) runs every `batch_ok` fixture at points 1e-3 apart, and every `batch_lead` fixture also at points 0.37 apart, each point on its own instance (every real and integer field moved apart), against scalar, bit for bit; `ch05_analog_behavior/batch_per_instance_state.va` (held real and integer, `$prev`, a nonlinear-capacitance latch) failed this before `batch_inst`; codegen test "a batch reads each point's own Instance, or the device is not batch_ok" |

### Host math: exp, ln, pow

A device's `exp`, `ln`/`log`-based and `pow` values come from the host's
scalar family (`contract.RefFamily`, the testbench's, a host's own), and
its scalar paths (`$limit`) from `contract.gm`. VerA's
own families and `contract.gm` use, on every target (host, NVPTX, AMDGCN):

* `exp`: ARM optimized-routines' design (musl `pow.c` `exp_inline`,
  `exp_data.c`): 2^(k/128) table, degree-5 polynomial, exact scaling; plus
  1 + (x + x²/2) below |x| = 2^-28 and direct +0/+inf past the rounding
  thresholds. 
* `ln`: ARM's `log.c` (as Zig's compiler_rt carries it; identical results
  to the previous routine).
* `pow`: ARM's `pow.c`, double-double log then exp; replaces
  `std.math.pow`, whose error grew with |y| (20 ulp measured).

**Correct** here means, and each is checked:

1. Max error ≤ 0.52 ulp (exp, ln) and ≤ 0.55 ulp (pow) of the exactly
   rounded result, over every finite input (faithful rounding; LRM Tables
   4-14 sets no accuracy, so this is VerA's choice). Measured below
   against an f128 oracle; `zig build test` checks a fixed sample.
2. IEEE 754 / C99 Annex F special values: exp(±0) = 1, exp(+inf) = +inf,
   exp(−inf) = +0, +inf above ln(DBL_MAX), gradual underflow and +0 below
   −1075 ln 2; ln(±0) = −inf, ln(x < 0) = NaN, ln(+inf) = +inf, ln(1) = +0;
   pow's F.10.4.4 rows (pow(x, ±0) = 1, pow(1, y) = 1, odd/even integer
   exponents of negative and signed-zero bases, NaN for a negative base and
   non-integer exponent); NaN propagates.
3. Derivatives use the value returned: d exp = exp(x)·dx with the same
   exp(x), d ln = dx/x, d pow = c·p/x with the same p (`RefFamily`).
4. One implementation everywhere: no fma (a fused and an unfused build
   round differently; `@mulAdd` is a libcall on baseline x86-64), so host,
   NVPTX and AMDGCN give the same bits. NVPTX `sm_80` PTX of the three
   routines has no `fma`; AMDGCN `gfx90a` has `v_fma` only inside f64
   division's IEEE expansion (`docs/measurements/device-runtime-2026-10-01/gpu_probe.sh`). The comptime fold of the routines (target
   independent) equals their run on the host (`zig build test`). Cost of
   no-fma, measured: ln +2.4 and pow +4.3 ticks per call.
5. The `@Vector(n, f64)` form (`hexp`, `hlog`; the testbench's batch
   family) is the scalar's arithmetic lane for lane; a vector with a
   special lane takes the scalar call for every lane.

These are the only implementation: the previous host path (`@exp`/`@log`,
i.e. compiler_rt or a linked libc, and `std.math.pow`) and the GPU's musl
ports (`softExp`/`softLog`) were removed, so no flag reproduces the
pre-2026-10 bits. The table below is the record of what changed.

Measured 2026-10-01, i9-14900HX (AVX2, no AVX-512), f128 oracle,
200 000 samples per row; ticks are TSC ticks per call (scalar, throughput)
or per element of `@Vector(4, f64)`
(`docs/measurements/device-runtime-2026-10-01/mathtable.zig`):

| function, inputs | before (compiler_rt, std): max / mean ulp / ticks | glibc 2.42 (measurement only) | VerA now | VerA `@Vector(4)` ticks/elem |
|---|---|---|---|---|
| exp, x in [−745, 709] | 0.8811 / 0.2638 / 29.2 | 0.5034 / 0.2502 / 22.8 | 0.5054 / 0.2502 / 20.3 | 22.2 |
| exp, x in [−80, 45] (the compact models) | 0.8480 / 0.2638 / 24.8 | 0.5044 / 0.2499 / 9.1 | 0.5064 / 0.2499 / 9.1 | 4.1 |
| exp, \|x\| < 2^−28 (decay factors) | 0.5329 / 0.2194 / 5.1 | 0.5000 / 0.2194 / 13.1 | 0.5000 / 0.2194 / 8.9 | 7.4 |
| ln, x random bits in (0, inf) | 0.5000 / 0.2500 / 9.5 | 0.5000 / 0.2500 / 9.2 | 0.5000 / 0.2500 / 9.5 | 5.2 |
| ln, subnormal x | 0.5000 / 0.2506 / 116.6 | 0.5000 / 0.2506 / 115.7 | 0.5000 / 0.2506 / 120.2 | — |
| ln, x in [0.9, 1.1] | 0.5175 / 0.2493 / 15.5 | 0.5175 / 0.2493 / 16.5 | 0.5175 / 0.2493 / 15.9 | 17.5 |
| pow, x in [1e−3, 1e12], y in [−3, 18] | 20.34 / 1.7565 / 147.6 | 0.5054 / 0.2498 / 23.1 | 0.5058 / 0.2498 / 29.3 | — |
| pow, psp103's own (x, y) pairs | 8.734 / 0.6904 / 55.1 | 0.4985 / 0.2143 / 22.2 | 0.5057 / 0.2144 / 27.5 | — |

A vector row over a range with special lanes (|x| > 512 for exp, the band
around 1 for ln) falls back to scalar calls, so it costs more than the
scalar row.

For a digital real/realtime array read with an out-of-range or x/z index,
IEEE §5.2.2 specifies an x reference but gives no real unknown encoding.
VerA applies §4.8.2's x/z-to-zero conversion at the real evaluation boundary,
so the read yields +0.0. It does not reinterpret the integer unknown plane
as an IEEE 754 NaN. Valid elements retain their real bit patterns, including
NaNs explicitly supplied by `$bitstoreal`. `ieee1364/04_data_types/native_real_arrays.v`
checks invalid indices beside valid elements in both the interpreter and
native executable.

For AMS §9.18, E0890 diagnoses specified values that fold over literals
outside Table 9-29's domains. A value that depends on model-card parameters
(an instance override over a parameter, or a top-level system alias the card
writes) is checked when the card is written: the device's `checkCard(model)`,
called after `derive`, returns the first such value's name (`path$mfactor`,
or the alias) outside its domain, and null otherwise; it costs `eval`
nothing. The testbench stops with E0890; another host decides what to do with
the name (`specification/Vague_Decisions.md` VD-079). `geometry_parameter_sweep.va`
exercises valid host-dependent values, `geometry_card_mfactor_outside_domain_is_fatal.va`
an invalid card, and `geometry_*_rejected.va` isolates literal domain
errors. The top-level `$mfactor` alias retains its existing ABI: a host using
it must also keep `Instance.mfactor`, which controls automatic scaling,
consistent with the alias's model-card value.

For AMS §4.2.4 integer `%`, zero-divisor checks remain observable even when
the remainder is discarded. Checks in a display-task argument run in that
task's accepted-point phase; `modulo_integer_display_zero.va` exercises an
inlined function that discards the value there. Solver devices that drop
display tasks omit those checks too. A real `%` by a run-time zero is the
same error (the §4.2.4 sentence names no operand type): the executable
reports E0601 and exits 1, a solver device traps (`kernel_text.zig`
`zFmod`, `zModZero`; `ch04_expressions/modulo_real_dynamic_zero.va`).

The device/host contract's conformance checks are opt-in (no clause; a VerA
choice). `lib/contract.zig`'s `validate`, `validateHost`'s host obligations,
`checkFamily` and a Debug device's `su_ok` assert (`setup` ran before `eval`)
run only in a program whose root module declares
`pub const vera_validate_contract = true` (`contract.validating`). VerA turns
them on in `zig build test` (`tools/zrunner.zig`), in every fixture-suite
testbench, in `vera --emit-exe`/`--run` with `--validate-contract`, and always
in `vera --check`. `validateHost`'s version check (`D.vera_version` equals
`contract.vera_version`, which replaced `contract_abi == abi_version` on
2026-10-18) always runs: it is what refuses a stale device. A host that wants the
obligation checks must opt in: the decl in its program's root module, or, for
`vera --emit-so`/`orchestrator.compileRelease`, in its `dyn` module, which the
generated shim (the build's root) forwards. Off, a device build spends
0.4-1.8% fewer instructions (2026-10-01: mos1 2.454 -> 2.417 Gi, bsim4va
eval 8.100 -> 7.958, psp103 eval 14.183 -> 14.125).

### Device ABI 6: the setup cache and the temperature are per Model row

§9.15 leaves where a simulator keeps a device's temperature to the
implementation, and VerA chooses the `Model` row (`contract.abi_version` 6,
2026-10-02; ABI 5 kept it per instance). Every value `setup` computes reads only
the card, the temperature and card-time `$simparam`s, so with the temperature on
the row the whole solve-invariant cache is a function of the row, and instances
that share a row share it. Measured on the emitted devices (bytes, ReleaseFast):

| Device | `Instance` ABI 5 -> 6 | `Model` ABI 5 -> 6 |
|---|---|---|
| mos1 | 744 -> 368 | 344 -> 720 |
| bsim4va | 3,520 -> 200 | 7,408 -> 10,728 |
| psp103 | 3,872 -> 104 | 6,816 -> 10,584 |

Bench outputs (residual, charges, Jacobian at 64 points) are bit-identical on
resistor, diode, mos1, bsim4va, psp103, coupled_ltra and txl, and `evalQ`
cycles moved -0.5% to +0% (in noise).

Host migration from ABI 5:

- **Moved, `Instance` -> `Model`:** `su: Setup` (the solve-invariant cache)
  and, in a Debug program that validates, `su_ok`. Same types, same element
  order; they are the last fields of `Model`.
- **Removed:** `Instance.temperature`. **New:** `Model.temperature__: f64 =
  300.15`, kelvin, host-written, in every device (`contract.host_model_fields`).
  `$temperature` and `$vt` read it, in `setup` and in `eval` alike. A host that
  simulates an instance at its own temperature (`dtemp`, a per-instance `temp`)
  gives that instance its own Model row. There is no per-instance fallback: one
  would need the per-instance cache this removes, and a host still writing
  `inst.temperature` fails to compile instead of running at a stale value.
- **`setup(comptime V: type, model: *Model) void`** (was `(V, *const Model,
  *Instance)`): once per Model row. Call order per row: write the card and
  `temperature__` (and any `nom_temp__`-style host fields), `derive(S,
  &model)`, `checkShape(&model)`, `setup(V, &model)`. Call `setup` again after
  any card, `temperature__` or `setup_simparams` write; `derive` first when the
  card changed.
- **New, optional `setupInstance(model: *const Model, inst: *Instance) void`**,
  emitted only when an instance caches something from the card (VerA's
  `vera_timepoint` caches, a latched §9.7.3 status). Call it for every instance
  of the row after each `setup`, and after an instance write.
- `setup_chunks.exportChunk` chunks now take `(*Model, *anyopaque)`.
- **New, only in a device that calls §9.19 `$port_connected` on one of its own
  ports: `Model.port_connected__: u64`**, all ones by default (every port
  connected, which is what ABI 5 answered), bit p = port p in the module's port
  declaration order. `$port_connected(p)` reads bit p. The host writes it with
  the card, BEFORE `derive`: `derive` and `checkShape` read it if a parameter
  expression calls `$port_connected`, and `setup` and every eval entry read it
  wherever the model does. An instance whose card connects a different set of
  ports (a 4-terminal card on HiSIM_HV's 6-port module) gets its own Model row.
- `contract.validateHost`'s `calls_setup` covers both entries.
- `$mfactor` (still `Instance.mfactor`) is no longer a solve-invariant input:
  instances of one row may differ in it, so a value that reads it is computed
  in `eval`.
- Instance parameters: VerA declares every §3.4 parameter, instance ones (L,
  W, M, NF...) included, as a `Model` field, so there is no per-instance card
  value to cache; a host binds per-instance parameters by giving the instance
  its own row, as for the temperature.

## 7. Resource limits

Each limit is stated here and fails with a named diagnostic. A run-time
limit ends the run with exit status 1; the LRM gives none of these a
truncation rule, so a shorter answer would be a wrong one.

| Limit | Value | Diagnostic | Code | Fixture |
|---|---|---|---|---|
| nesting: parentheses, unary and `?:` chains, binary operators in one chain, statements, generate blocks, braces | none; memory and the OS thread limit. The parser recurses on stack segments of 4,096 levels reserved from memory, every later stage runs on a stack reserved for the depth the parser measured (`lib/base/deep_stack.zig` header: the per-level frame measurements, about 8 million levels under macOS's default thread limit) | E0241 only when the system refuses the reservation, naming the depth | `lib/base/deep_stack.zig`, `lib/frontend/parser.zig` `Parser.segment`, `src/Compilation.zig` `lowerAndProve` | `annex_a_syntax/nesting_past_the_old_parser_limit.va`, `sum_chain_past_the_old_parser_limit.va`, `long_sum_under_the_nesting_limit.va`; `lib/frontend/parser/test.zig` and `src/Compilation.zig` at 100,000 levels |
| macro expansion depth (argument pre-expansion included) | none; memory and the OS thread limit (stack segments of 1,024 levels). A macro that expands itself, directly or through others, never ends and is E0118 at any depth | E0119 only when the system refuses a stack segment | `lib/frontend/preprocessor.zig` `Pp.nested` | `ch10_directives/macro_expansion_past_the_old_128_limit.va`; `lib/frontend/pp/test.zig` at 10,000 nested uses and a 100,000-macro chain |
| `` `include ``, library map `include` and `--spice` `.INCLUDE`/`.LIB` nesting | none. Refused only when nesting cannot end: an `` `include `` of a file already open with every macro as it was then and as many conditionals open (compared by a 64-bit hash of the macro table); a map file, or a netlist file (`.LIB` entry), already being read | E0125 naming the cycle; E0244 and E0928 likewise | `lib/frontend/pp/directive.zig` `handleInclude`, `lib/frontend/libmap.zig` `Loader.read`, `lib/frontend/spice_cards.zig` `Reader.cycle` | `ch10_directives/include_cycle_rejected.va`; legal neighbour `include_self_guarded_past_the_old_limit.va` (one file 40 deep under a changing guard); unit tests in `pp/test.zig`, `libmap.zig`, `spice_cards.zig` |
| source file, `` `include `` file, `--spice` netlist and the files its `.INCLUDE`/`.LIB` cards read; the preprocessed text | 2^32 - 1 bytes: the u32 offsets every stage after the preprocessor locates a token by. A regular file is refused from its size; a stream (a pipe, /dev/zero) is read until it passes the bound. `$table_model` and `noise_table` data files have no bound but memory | E1013 (a file), E0150 (the text macros expand to) | `lib/frontend/preprocessor.zig` `max_text_bytes`, `readText`, `Pp.checkTextSize` | `build.zig`: a sparse 4 GiB file as the source and as the `--spice` netlist under `zig build test`; `pp/test.zig` (a sparse `include, a 17 MiB one, and E0150 through `Options.text_limit`) |
| nets, ports, branch flows and operator states in one module; one vector range | a `u32` row index (2^32 - 2 rows; a module that large runs out of memory first). Was 65535, below IEEE 1364-2005 §4.3.1's 65536-bit vector (#29) | E1015, only on a range whose folded bounds pass the index | `src/analog/node.zig` `max_nodes` | `ch03_data_types/vector_range_past_65535_elements.va` (65537 branch elements); `src/codegen/device/codegen/test.zig` "`U` is enum(u8) to 256 unknowns..." (70000 port elements); `src/analog/node.zig`'s net-declaration test (70001 rows, and E1015 at `[0:5000000000]`) |
| analog-context array or assignment pattern | a `u32` element index (2^32 - 1; an array that large runs out of memory first). Was 2^20 (#29). A large array is a device frame local or an `Instance` field: a host gives `eval` the stack it needs (the testbench sizes a thread, `runner_text.zig` `bigStack`) | E1016, only on bounds whose product passes the index | `src/analog/shape.zig` `max_cells` | `ch03_data_types/array_past_2_20_elements.va` (1048577 elements, indexed at run time); `src/analog/shape.zig`'s bounds test (E1016 at 65536 x 65537) |
| loop generate unrolling (§6.6.1) | none: a scheme that ends is unrolled in full, however many iterations; one that never ends is found by following the condition and step alone until they end or repeat a genvar value (Brent's cycle detection, O(1) memory), and refused naming the value. A genvar is a §3.2 integer whose arithmetic wraps, so `i = i - 1` under `i < 3` ends after 2^31 + 1 iterations and is unrolled: the bound is memory | E0420 | `src/elab/instance.zig` `genvarLoop`, used by `loopInstances` and `src/analog/control.zig` `tryUnrollFor` | `ch06_hierarchy/generate_nonterminating_rejected.va`; legal neighbours `genvar_loop_4097_iterations.va`, `generate_loop_4097_instances.va`, `ch05_analog_behavior/sequential_ifs_10000.va` |
| bits of a `reg` the analog context reads (§7.3.1 allows any 31-bit grouping) | none: every bit of a `reg` a digital process owns (each 32-bit word reaches the device as its own `Model` field, `Lowered.discrete_words`), of one the analog context only reads (its literal initial value, `Lower.reg_consts`), and of one the analog context computes (VD-116, `Ty.wide`, any width). Was bits 0 to 31 of the last (#29) | E0329 only for a select past bit 31 under an explicit D2A event, whose region-1b copy holds bits 0 to 31 | `src/analog/expr.zig` `lowerRegSelect`, `src/analog/wide.zig` | `ch07_mixed_signal/discrete_bus_part_select_above_31_analog_assigned.va`, `discrete_bus_part_select_above_31.va`, `wide_reg_part_select_above_31.va`, `wide_reg_matches_digital_65600.va` |
| wide `reg` temporaries (VD-116) | none: a value of n bits is n/8 bytes on the evaluation's stack; one statement needs at most one per node of its sized tree plus the division's scratch (about 2n/8 bytes), so a host gives `eval` that stack, as for a large array (the testbench sizes its thread, `runner_text.zig` `bigStack`). Measured 2026-10-15 (x86_64, frame sizes of `eval` and the division kernels it calls, four 1-word-to-n statements of `<< | + >> - ^ ~ / %`): 65,536 bits 168 KB ReleaseFast, 461 KB Debug; 1,000,000 bits 2.5 MB ReleaseFast, 7.0 MB Debug | none | `lib/backend/kernels/wide_kernels.zig`, `src/codegen/exe/tb/runner.zig` `wide_bytes` | `ch07_mixed_signal/wide_reg_matches_digital_65600.va` |
| where a connect module can be inserted (§7.8.4) | at the level of the port's upper connection, both connections as §7.4 resolves them before insertion (`segment.zig`), read from the subtree a first walk that inserts nothing elaborated (`Flatten.tree`: generate blocks, instance arrays, paramsets at any depth, out-of-context declarations below the planned level); refused only when that walk left out the deciding segment (a generate scheme that does not fold, a subtree it could not elaborate) | E0929 | `src/elab/insert.zig` `plan`, `checkUnbridged` | no fixture pins the refusal (no legal design is known to reach it); `ch07_mixed_signal/connect_insertion_upper_from_generate_block.va`, `connect_insertion_upper_from_instance_array.va`, `connect_insertion_upper_from_deep_paramset.va` and `connect_insertion_upper_from_ooc_below.va` are the four cases it used to refuse; `connect_insertion_generate_block_port.va` a generate block's own mixed port |
| `.v` contract device pins (one per top-module port bit) | 65535: not a VerA choice, each pin is a bit of one contract mask (`contract.MaskOf`) and Zig's widest integer is u65535. Past 256 pins `U` is `enum(u9)` and wider; every mask decl is declared at any width, so a sparse host family carries one lane per output row | E1103, "more than 65535 pins" | `lib/sim/digital/emit.zig` `deviceRoot` | `build.zig`: `vera --emit-zig tests/fixtures/ch07_mixed_signal/v_pins.v` (65536 pins) under `zig build test`; `tests/host/vdev_host.zig` runs the wide counter (`v_wide`) across packed-plane word boundaries and the 1202-pin `v_huge` on a sparse family |
| `.v` contract device transcript per accepted step (`$display` and the other §17.1 output a step's run prints; held in `State.say` until `stateCtl(.commit)` writes it to stderr, dropped on `.revert`, so a rejected step prints nothing) | 4096 bytes | none: the head is kept and the step's text ends in `...[device transcript cut at 4096 bytes]` | `lib/sim/rt/device.zig` `say_cap` | `tests/host/vdev_host.zig` `v_say` |
| a string an analog device builds while it runs, whose length only the run decides (a string parameter the card sets, a `$fgets` line or `$value$plusargs` value read into it, an array element, a width spelled in a run-time `$sformat` format, a held (§5.10) string that grows by itself every step) | each such piece counts 4096 bytes in the row of the site or held string it reaches. Every other row is sized from what the model can put there (`cg_strcap`: the format text, each conversion at its written width and precision, each operand's own row), never below 4096 bytes, so no replication, concatenation or conversion count the source writes is refused, nor any width or precision up to the format-field limit below. The device has no allocator, which is why a row is sized at all | E1011 at run time | `src/codegen/device/cg_strcap.zig`, `lib/backend/kernels/str_kernels.zig` `zSRow`, `ZStrHeldN`, `zSOver` | `ch09_system_tasks/sformat_runtime_width_past_its_row_rejected.va`; legal neighbours `sformat_runtime_width_within_its_row.va`, `sformat_field_width_over_4096.va`, `sformat_33_conversions.va`, `string_concat_past_4096_bytes.va`, `ch03_data_types/string_replication_past_4096_bytes.va` |
| analog-context format field width and precision (§9.4.3, each conversion's `%[flags][width][.precision]` in a format lowering reads) | 2^30 (1,073,741,824) each: `str_kernels.zCReal` indexes digit positions as i32 (the precision plus f64's 309 integer digits and its rounding position), and `cg_display` sizes a field's scratch as width + precision + 328 bytes; at 2^30 both are exact. Was unchecked: a width that overflowed parsing became maxInt(usize) and the scratch sum overflowed, a panic in a safe compiler build (#45). A format known only at run time (`$sformat` of a string variable) saturates its numbers and is bounded by its row (E1011, the row above); the digital context writes its padding unbuffered and takes any width | E0828 | `src/analog/systask.zig` `max_format_field`, `nextConv`, `prepareFormatArgs`; `src/codegen/device/cg_display.zig` `PrintArg.scratch` | `ch09_system_tasks/format_field_past_its_limit_rejected.va`, legal neighbour `sformat_field_width_over_4096.va`; `src/analog/systask.zig` test "system tasks: arguments a task refuses" (2^30 accepted, 2^30 + 1 and a u64 overflow refused) |
| number literal size | 2^32 - 1 bits, the u32 width every stage carries (a literal allocates two bits per bit of size, so memory runs out first) | E1019 | `lib/frontend/integer.zig` `max_width` | `ieee1364/03_lexical_conventions/literal_size_65536.v`, `literal_size_over_2_24.v`; `integer.zig` tests at 2^24 + 1 and 2^32 |
| analog number literal carrier | 64 bits; wider literals require an exact signed value in the i64 carrier | E0130 | `lib/frontend/integer.zig` `asExactInt` | `ch09_system_tasks/reject_clog2_wide_unsigned_carrier.va`; legal neighbour `clog2_unsigned_width.va` |
| analog `$clog2` expression carrier | arithmetic, unary negation and shifts retain at most 32 bits per intermediate; bitwise/conditional/comparison contexts retain at most 64 bits; above 64 bits only exact wide literals and parameter aliases preserving their width retain proven high bits | E0893 | `lib/frontend/constfold.zig` `intPlan`, `src/analog/constfold.zig` `clog2WideCarrier` | `ch09_system_tasks/reject_clog2_wide_arithmetic.va`, `reject_clog2_wide_arithmetic_default.va`, `reject_clog2_wide_widening.va`; legal neighbours `clog2_nested_contexts.va`, `clog2_unsigned_width.va` |
| §9.5 file I/O memory: open file descriptors, paths remembered for §9.5.1.1, each channel's `$fgets` line and `$fscanf` window | memory: the file kernels grow them from `std.heap.page_allocator` (geometric growth), and only they allocate, only in a `--display=emit` device's side-effect phase, never in `eval`; the contract has no allocator. A line or window stays allocated until the run ends, since a string may still view it | `$fopen` 0 with `$ferror` 12 when a channel or path row cannot be added; E1011 when a line or window cannot grow | `lib/backend/kernels/file_kernels.zig` `zf_gpa`, `zfGrow`, `zFMore` | `ch09_system_tasks/fd_channels_past_30.va`, `write_mode_path_65_opens.va`, `fgets_line_over_4096.va`, `fscanf_window_over_4096.va`; the failures: `lib/backend/kernels/test.zig` over a failing allocator |
| channels opened as multichannel descriptors | 30 (bits 1..30): §9.5.1's own, "limiting an implementation to at most 31 files opened for output via multichannel descriptors" with bit 0 standard output. File descriptors are not mcds and have their own rows (above) | `$fopen` returns 0, `$ferror` 24 | `lib/backend/kernels/file_kernels.zig` `zf_max` | `ch09_system_tasks/mcd_channels_exhausted_at_bit_31.va`, `fd_channels_past_30.va` |
| random distribution count | 1..2147483647, integral | the RNG diagnostics | `lib/backend/kernels/rng_kernels.zig` `zRngDf` | `ch09_system_tasks/189_rng_*_rejected.va` |
| digital: expression and statement nesting, hierarchy depth, nested task and function activations | no count: the walk runs on a thread whose stack `deep_stack.runGuarded` reserves (pages committed only as deep as the walk goes): 1/16 of physical memory, at most 16 GiB (256 MiB on Windows and 32-bit hosts); a contract device called on a host's thread checks against 4 MiB below its first call. Only a walk that exhausts that stack is refused, which is what a recursion with no end meets (it touches the whole reservation first: about 2 GB of RSS on a 31 GB machine) | E1100, "nesting here exhausts the N MiB stack VerA reserved for it" | `lib/base/deep_stack.zig` `runGuarded`, `exhausted` | `ieee1364/10_tasks_functions/recursion_without_end_rejected.v`; legal neighbours `recursion_past_1024.v`, `ieee1364/05_expressions/expression_deeper_than_256.v`, `ieee1364/12_hierarchy/hierarchy_deeper_than_64.v` |
| digital: constant packed-select bounds | signed i64 values; expression width itself is unrestricted | E1100, naming the supported i64 range | `lib/sim/digital/compile.zig` `partBound` | `ieee1364/05_expressions/native_wide_index_bound_limit.v`; legal neighbor `native_wide_index_values.v` |
| `$simprobe` name (AMS 9.16) | resolved at compile time only: a literal or a string parameter; a name that does not fold (a string variable the analog block sets) is refused, fallback or not, since the fallback would answer a valid name wrongly (`specification/Vague_Decisions.md` VD-030) | E0823 | `src/analog/hier_name.zig` `lowerSimprobe` | `ch09_system_tasks/reject_simprobe_runtime_name.va`; legal neighbour `simprobe_string_parameter_name_resolves.va` |
| `absdelay` history | none: a full ring is thinned to keep its window (VD-112) | W1051 at run time, once per site | `lib/backend/kernels/hist_kernels.zig` `zHistThin` | `ch04_expressions/absdelay_history_past_capacity.va` |
| analog device: hierarchical port access `I(<u.p>)` (AMS 5.4.3, A.8.9) | read as the sum of `u`'s own flow contributions at the net its port is joined to: every block of `u`'s hierarchy must be lowered before the read (read from a module above `u`), and `u`'s branches at the net must be flow sources, not a potential source or a §5.6.7 indirect branch. A module's own `I(<a>)`, or `I(pb)` over its §3.12.1 port branch, read inside an instance is that instance's port flow read from inside it, and refused the same way | E0997 | `src/analog/expr.zig` `instancePortFlow`; `src/elab/clone.zig` `ownPortFlow` | `ch05_analog_behavior/port_access_hierarchical_potential_source_rejected.va`, `port_access_own_port_inside_instance_rejected.va`, `port_branch_own_port_inside_instance_rejected.va`; legal neighbour `port_access_hierarchical_instance.va` |
| mixed signal: how tightly a `cross`/`above` in a digital event control is cut (VAMS 5.10.3.1, 7.3.5) | to its `time_tol` and `expr_tol`, or, when `time_tol` is below one ulp of the time (no two times that close exist), to the two adjacent floats around the crossing, whose later one delivers the event. A step takes at most 64 secant cuts, then bisections, `max_cuts` (2214) in all: each cut lands strictly inside the step, so the bound is a proof and the loop asserts it, whatever the monitor reads (NaN included) | none: no source reaches the bound (#35) | `lib/sim/mixed.zig` `max_secant`, `max_cuts`, `step` | `ch07_mixed_signal/cross_time_tol_below_time_resolution.va` (time_tol 1e-30 s across a step); `lib/sim/mixed.zig` test "a step crossing with a time_tol below one ulp of time" |
| digital: events in one time step, and loop iterations inside a process that does not suspend (each pass back to a loop's top: a backward jump, a `repeat`'s next iteration), counted together | 10,000,000, or `--event-budget=N`; interpreter and native executable alike | E1100, "more than N events at time T" or, when a loop pass crosses the budget, "more than N loop iterations and events at time T" (#36) | `lib/sim/digital/root.zig` `max_events_per_tick`, `lib/sim/digital/exec.zig` `loopIteration`, `lib/sim/rt/root.zig` `State.loopIteration` | `ieee1364/11_scheduling/zero_delay_loop_rejected.v`, `ieee1364/09_behavioral_modeling/forever_without_timing_rejected.v` (each at a budget of 1000: the default takes minutes to reach); legal neighbour `untimed_loop_under_budget.v` |
| VPI: vpiResets in one digital run (VAMS 12.36, IEEE 1364-2005 C.7) | 1000; each re-elaborates the design and keeps the old run's memory (VD-106) | E1100, "more than 1000 vpiReset requests in one run", after cbError (#37) | `src/vpi/run.zig` `max_resets`, `simulate` | `ch12_vpi_routines/sim_control_reset_every_run_rejected.c`; legal neighbour `sim_control_reset_run.c`; `src/vpi/run.zig` test "an application that asks vpiReset on every run" |
| `--emit-osdi`: `$simparam` names the simulator passes (`OsdiSimParas.names`, NULL-terminated, uncounted by OSDI 0.4) | 256 before the NULL (ngspice-45 passes 10) | a fatal `osdi_log` line, "the simulator's $simparam names list has no NULL in its first 257 entries", and `EVAL_RET_FLAG_FATAL` from `setup_model`, `setup_instance` or `eval` (#46) | `lib/osdi_dyn.zig` `max_sim_paras`, `hostParams` | `lib/osdi_dyn.zig` test "a $simparam list with no NULL within max_sim_paras is refused fatal" (legal neighbour: 256 names) |
| VPI: passes of the time-queue loop at one time with no event (a time callback that registers another at its own time, IEEE 1364-2005 §27.33.2) | the event budget: 10,000,000, or `--event-budget=N` | E1100, "more than N callback passes at time T", after cbError (#37) | `src/vpi/run.zig` `timeSteps` | `src/vpi/run.zig` test "a read-write callback that registers itself at its own time forever" (a budget of 1000) |
| testbench `//! sweep` product | 4096 points | a `//!` directive error | `src/codegen/exe/root.zig` `max_points` | none (harness input, not source) |
| VPI: automatic named events and dynamic event references in automatic tasks | declaration metadata is available; triggering through VPI requires unimplemented §26.6.20 frame handles | `AUTOMATIC`, naming the activation frame | `src/vpi/value.zig` `vpi_put_value` | `ieee_pli/event_array.c`; static-task event references are the legal neighbor |

### Host changes to paramset selection inputs

AMS §§6.3 and 6.4.2 require overload selection to use the effective parameter
values, including outer `defparam` bindings. VerA selects the module during
elaboration, after applying compile-time card overrides. Parameters read to
admit or exclude members of an overloaded paramset name are shape inputs:
the emitted `checkShape` returns the name of a changed input and the host
must recompile before evaluating that card. This includes numeric and string
inputs, and conservatively includes changes that remain within the same bin.
It is a host execution limit, not an AMS restriction on parameter values.

Parameters used only to supply values through a single-member paramset remain
live through `derive`. `src/elab/paramset.zig` records the selection
dependencies; `tests/host/paramset_host.zig` executes both kinds of host changes
against `ch06_hierarchy/paramset_outer_defparam_shape.va`.

### Timer controls with effects

AMS §5.10.3.3 requires the next event to use the final `start_time` and
`period`. VerA recomputes arithmetic, array reads and analog functions proved
free of effects. A function with output/inout arguments, random/file activity,
or an unproved nested call keeps its original result. If one of that call's
inputs changes afterwards, E0528 reports the unsupported combination instead
of silently retaining an old schedule or repeating effects. This is a limit
on legal AMS, not a prohibition in the LRM.

Compute such a call into a variable before `timer()`, then use or update that
variable as the control. An unchanged effectful leaf remains supported even
when another operand changes; a constant return also needs no recomputation
when an input changes. `src/analog/event.zig` owns this check;
`ch05_analog_behavior/timer_changed_effectful_*_rejected.va` pins the refusals,
`timer_effectful_file_leaf.va` checks one file write per accepted point, and
`tests/host/timer_host.zig` with `tests/fixtures/ch05_analog_behavior/timer_body_precomputed_controls.va` checks
final deadlines and output/inout effects through an emitted device, including
a rejected trial followed by a retry.

## 8. Unspecified behaviour

`CLAUSE-AUDIT.md` §5.5: no test asserts one outcome where the LRM permits
several. This covers every `unspecified` row of `ieee1364/CLAUSES.tsv`, and
each row's last column names its fixture policy. 5.1.4, 11.4.2, 11.5,
12.3.10.1 and 12.3.10.2 permit several outcomes: their fixtures assert
membership in the permitted set
(`ieee1364/11_scheduling/sched_allowed_active_race.v`) or choose inputs
where every permitted outcome agrees
(`ieee1364/12_hierarchy/net_type_warning.v`). 20.2, 26.1, 26.2.4,
26.6.16, 26.6.21, 27.20, 27.34 and 27.34.1 bind the application, name no
failure value, or say no design must produce the object, so no fixture
asserts a refusal or a required object for them. The three
`audit_sched_*_order.v` fixtures pin VerA's documented order (§1 above) and
cite no clause. The `$ferror` fixtures assert only a nonzero code.

## 9. Open defects

None is open. The earlier limit defects below are gone rather than named:
a VPI flow read of one instance's unnamed branch over a node pair other
instances also drive is that instance's own share of the summed row, which a
VPI device publishes beside the rows (`Lowered.contrib_shares`, `vpiShares`;
VAMS 11.6.7, 12.10; `ch12_vpi_routines/derivtf_partials.c`);
an upward defparam (to an ancestor, the declaring instance, an earlier
sibling or a top-level parameter) is applied, IEEE 1364-2005 §12.8.1's
collect-first order run as a second walk (`src/elab/override.zig`
`mayBindEarly`, `seedDefparams`, `seededValue`;
`ch06_hierarchy/defparam_upward_collect_first.va`), and only one whose value
leads back to its own target is E0907;
a direct read of a host-written `integer` parameter is its low 32 bits
(`derive` reduces the i64 carrier; `tests/host/integer_param_host.zig`);
the `absdelay` history counts steps in a u64; unit names count collisions in
a u32; digital `%b`/`%h`/`%s`/`%t`, `%m` and real conversions, `vpi_printf`'s
reals and the testbench's noise, AC-stimulus, charge-site and mixed-signal
name rows are written whole; a mixed-signal crossing the secant cannot close
is bisected to its `time_tol`, or to adjacent floats when `time_tol` is
below one ulp of the time (`lib/sim/mixed.zig` `max_secant`, `max_cuts`; #35).

The testbench's comptime loops over constant Jacobian entries and charge
stamps were measured, not changed: a 40-node resistor mesh (1600 constant
entries) and 200 charge sites build and run, and `lib/contract.zig` sets its
own evaluation quota where it computes those tables.

## 10. Open gaps no fixture pins yet

Pinned gaps are `//! xfail` fixtures, gated by name by the verdict ratchet
(`tests/conformance/VERDICTS.tsv`). These are the rest: found in
the 2026-10-04 conformance pass, with no fixture yet, because a fixture cannot
express them or the work was larger than the pass. Each names its clause.

- ~~**VAMS 5.4.3: a module's own `I(<a>)` inside an instance** reads the flattened net's port flow: the top's port flow when the net is a top port, else E0508~~ refused by name 2026-10-08: now a §7 limit row (E0997, `port_access_own_port_inside_instance_rejected.va`, `port_branch_own_port_inside_instance_rejected.va`). Open: the value itself, which needs a per-instance port-flow unknown (codegen's `x[u] − res[p]` row restricted to the instance's units). A hierarchical `I(<u.a>)` read from above is the instance's own.
- ~~**VAMS 2.9, 3.2.1, 3.4.3, 3.6.3.1: `desc`/`units` metadata** is not exported~~ DONE 2026-10-08 (#15, VD-100): `decl_meta`, asserted by `//! meta`.
- **VAMS 7.8.5.1: connect modules on a primitive's bit.** A primitive terminal on a bit or part of a mixed vector (`and (y, a[1], b)`, or an instance array's element on its bit of a vector), one of a primitive in a generate block, and one of a switch instance array are refused (E0929, VD-115) rather than bridged. A module port connected to a bit of a mixed vector is likewise never bridged (`insert.plan` reads only a whole-net actual), and is not refused.
- **VAMS 3.2.1: output variable values.** `decl_meta` names a module's output variables, but no hook hands a host their values for an operating-point report ("Verilog-AMS simulators shall provide access to their values").
- **`--emit-osdi`: display output.** An OSDI 0.4 library never calls the device's `say`, so its `$strobe`/`$display`/`$debug` records are not printed; OSDI has no accept callback to print them at (VD-102).
- ~~**VAMS 4.5.14, 8.5.3.7: analysis restarts and evaluation counts**, and **8.4: `$monitor` against analog solves**~~ DONE 2026-10-08 (#16). Restarts and counts needed no new runner: under `//! time` each `//! sweep` point is its own analysis (`ch04_expressions/dynamic_constant_argument_resampled_per_analysis.va`), and `//! checks` counts the mixed runner's accepted solutions, one CHECK each (`ch08_scheduling/macro_process_one_solve_for_coincident_events.va`). A digital `$monitor` of an analog probe crashed the engine; it is now checked at every digital time step after its region-3b solve (`ch08_scheduling/monitor_after_macro_process.va`) and at every analog solution at a tick no digital event reached, reporting when a probe moved (VD-111, `ch08_scheduling/monitor_at_analog_only_solutions.va`).
- **VAMS 7.3.3: a probe in a continuous assignment, `@*`, `wait` or an expression event control** is refused (E1100, `ch07_mixed_signal/probe_in_continuous_assign_refused.va`, neighbour `probe_in_procedural_read.va`): "All probes which are legal in a continuous context of a module are also legal in the discrete context", but such a process has no trigger for a change of the solution, which no slot holds. Not #16's (a `$monitor`'s probe is the one place that trigger exists, `Run.analogPoint`); open until the same wake reaches a continuous driver and an event control's suspension.
- ~~**VAMS 4.6.4.6: noise anti-correlation**: `//! noise` has no coefficient field~~ DONE 2026-10-08 (#17): `//! noise ... corr=<j>:<rho>`, `ch04_expressions/noise_anticorrelated_coefficient.va`.
- ~~**VAMS 9.17: no `.va` directive pins a run-time refusal**~~ DONE 2026-10-08 (#21): `//! reject-run <code>` (`ch09_system_tasks/rdist_zero_mean_at_run_time_is_an_error.va`, `ch04_expressions/modulo_integer_dynamic_zero.va`, each with a `//! neighbour`).
- ~~**SPICE decks** run on `sim.spice`'s dense, CPU-only copy of ARPice's solver (`lib/sim/spice/`): plain Newton only (no gmin or source stepping), `.noise ... lin` only, no correlated noise terms.~~ DONE 2026-10-08 (#22, VD-108): the operating point steps gmin, then the sources (`spice_op_gmin_stepping.sp`, `spice_op_source_stepping.sp`); `.noise ... dec|oct` (`spice_noise_dec_sweep.sp`, `spice_noise_shared_generator.sp`, which also runs §4.6.4.6's shared generator through the runner); `PsdTerm.corr_with` (`lib/sim/spice/noise.zig`'s test: no VerA device publishes one). Since 2026-10-23 the decks run on ESPice itself, which has all of these.
