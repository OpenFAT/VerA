# Changelog

## Unreleased

## v0.13.0 — 2026-10-23

| Measure | Number | Remaining to v1.0.0 | Command |
|---|---|---|---|
| **A** — fixtures behaving as stated | **2759 / 2759 — 100.0%** | 0 rows | `zig build benchmark -- --strict` |
| &nbsp;&nbsp;↳ FAIL · unasserted · XFAIL | 0 · 0 · 0 | all three to 0 | same run |
| **C** — clauses with both citation polarities (static) | **489 / 612 — 79.9%** | 1 clauses | `zig build benchmark -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited | 0 · 1 · 0 | requires rule-level review | same run |
| &nbsp;&nbsp;↳ classified under `CLAUSE-AUDIT.md` §5 (`CLAUSES.tsv`) | 122 | reviewed claims, not evidence | same run |
| **B** — IEEE 1364-2005 clauses with both citation polarities (static) | **397 / 808 — 49.1%** | 9 clauses | `zig build test-1364 -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited · classified | 8 · 1 · 0 · 402 | §§17–18 obligation detail: `specification/CLAUSE-AUDIT.md` §7.1 | same run |
| `zig build test` | **pass** | pass | `zig build test` |
| `zig build test-devices` | **pass** | pass | `zig build test-devices` |

`--strict` exit code **0** — 0 only when FAIL, unasserted and XFAIL are all 0.
A, B and C are measured by this script and nothing else may write them.

B and C count citations without executing fixtures. It is not a conformance score:
XFAILs and implementation-limit rejections can supply citations, and a clause
can contain multiple untested rules. See `specification/CLAUSE-AUDIT.md`.

- **`zig build test-spice`** runs the `.sp` decks on ESPice and grades its
  CSV against each deck's oracle. ESPice is `build.zig.zon`'s lazy `espice`
  dependency, built with `--fork .` so that its devices are compiled by this
  tree's compiler, or an installed espice with `-Despice=PATH`, CPU or GPU.
  Unknown `--` arguments reach espice (`-- --backend=cuda`). The pin is
  ESPice ec53a724; the decks also need what ESPice is adding for them (a
  repeatable `-I DIR` for `.hdl` includes, the operating-point cold start
  seeded from a device's `u_nodeset`, and `noise_table`/`noise_table_log`
  PSDs, `PsdTerm.coeff` and §4.6.4.6 correlation in its noise analysis), so
  `test-spice` passes on the first ESPice commit that carries them, which the
  next release pins.
- A noise function, or an `ac_stim`, in a potential contribution is a source
  in series with its branch (§4.6.4.1): `noise_gens` and `ac_gens` place it
  `row == col` on the branch-current unknown (`flow(a,b)`) with the branch
  row's sign in `PsdTerm.coeff` (a negative magnitude for a stimulus). It was
  placed as a current between the branch's nodes, a thousandfold error in
  `spice_noise_series_voltage.sp`, which now grades it on ESPice.
- `lib/sim/spice/` (the one-device copy of ESPice's CPU solver) and the
  `//! tran` / `//! onoise` testbench directives are gone: a testbench drives
  one device, and a circuit is a deck ESPice runs.
  `ch09_system_tasks/bound_step_below_minimum_step.va` went with them
  (§9.17.2's minimum-step floor is the simulator's).
- **`zig build conformance`** runs the VAMS Conformance Suite
  (`tests/conformance`, a submodule: `git submodule update --init --recursive
  tests/conformance`) through its `conform` harness from `nix develop
  .#external`, against this build's vera; `tools/vera.xfail` lists the known
  failures, seeded from the first full run (7846 tests: 4389 pass, 2316
  known failures, 1141 skipped; the largest cluster is annex C.4's `domain
  discrete` refused in the included `disciplines.vams` under
  `--sim=verilogA`). `CONFORM_JOBS` caps the harness's parallelism. The
  digital external suites (`tools/external_digital.py`, `ivtest`, `sv-tests`,
  `iverilog-diff`) moved into the suite.
- A `.v` module instantiating itself without a terminating generate (IEEE
  1364-2005 §12.1.3) is refused at 256 levels or 2^18 instances instead of
  elaborated without end (ivtest `pr2728812c` reached 25 GB).
- `zHistThin`'s W1051 warning and its once-flag are host-only: a GPU kernel
  thins an `absdelay` ring silently (same samples), without touching stderr
  or a mutable global.
- `Instance.systf` exists only in a device that declares `systf_calls`: 8 bytes
  fewer per instance of every other device (`Lowered.Uses.systf`).
- `Setup` holds a copy of every card value `eval` reads, beside the derived
  values, so an evaluation touches `su` alone: bsimcmg's core read 171 of
  the card's 1,901 fields over 74 cache lines; packed they are 22. A device
  with nothing derived keeps reading the card. `say` reads the copies too, so
  a host calls `setup` before it, as before `eval`.
- `Setup.b`, the invariant flags `eval` branches on, is a `std.StaticBitSet`
  (bsimcmg: 316 bytes to 40, one cache line).
- An `integer` parameter's `Model` field is the narrowest of i8/u8/i16/u16 its
  declared `from` range and default allow when the card alone writes it; a
  host writes one with a checked cast. Every other integer keeps the i64
  carrier and `derive`'s reduction to its low 32 bits.
- The §9.19 given flags are one bitset, `Model.given__`, with
  `Model.given_params` naming the bits and `model.setGiven(name)` raising one:
  the `<name>__given` fields are gone (bsimcmg: 514 bytes to 65). A host that
  set them by name calls `setGiven` instead; VerA's OSDI dyn and testbench do.

## v0.12.1 — 2026-10-22

| Measure | Number | Remaining to v1.0.0 | Command |
|---|---|---|---|
| **A** — fixtures behaving as stated | **2759 / 2759 — 100.0%** | 0 rows | `zig build benchmark -- --strict` |
| &nbsp;&nbsp;↳ FAIL · unasserted · XFAIL | 0 · 0 · 0 | all three to 0 | same run |
| **C** — clauses with both citation polarities (static) | **489 / 612 — 79.9%** | 1 clauses | `zig build benchmark -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited | 0 · 1 · 0 | requires rule-level review | same run |
| &nbsp;&nbsp;↳ classified under `CLAUSE-AUDIT.md` §5 (`CLAUSES.tsv`) | 122 | reviewed claims, not evidence | same run |
| **B** — IEEE 1364-2005 clauses with both citation polarities (static) | **397 / 808 — 49.1%** | 9 clauses | `zig build test-1364 -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited · classified | 8 · 1 · 0 · 402 | §§17–18 obligation detail: `specification/CLAUSE-AUDIT.md` §7.1 | same run |
| `zig build test` | **pass** | pass | `zig build test` |
| `zig build test-devices` | **pass** | pass | `zig build test-devices` |

`--strict` exit code **0** — 0 only when FAIL, unasserted and XFAIL are all 0.
A, B and C are measured by this script and nothing else may write them.

B and C count citations without executing fixtures. It is not a conformance score:
XFAILs and implementation-limit rejections can supply citations, and a clause
can contain multiple untested rules. See `specification/CLAUSE-AUDIT.md`.

- CI builds and tests with the Zig the dev shell pins (0.18.0-dev.349+d924f83bf),
  not 0.17.0; `minimum_zig_version` follows, and the flake finds a dev Zig
  release by version in zig-overlay.
- `tests/host.py` reads sources as UTF-8 (Windows defaulted to cp1252).
- iverilog-diff triage covers the new §15.3 skew/nochange, SDF, protect
  metadata and non-ANSI task-port fixtures.

## v0.12.0 — 2026-10-22

| Measure | Number | Remaining to v1.0.0 | Command |
|---|---|---|---|
| **A** — fixtures behaving as stated | **2759 / 2759 — 100.0%** | 0 rows | `zig build benchmark -- --strict` |
| &nbsp;&nbsp;↳ FAIL · unasserted · XFAIL | 0 · 0 · 0 | all three to 0 | same run |
| **C** — clauses with both citation polarities (static) | **489 / 612 — 79.9%** | 1 clauses | `zig build benchmark -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited | 0 · 1 · 0 | requires rule-level review | same run |
| &nbsp;&nbsp;↳ classified under `CLAUSE-AUDIT.md` §5 (`CLAUSES.tsv`) | 122 | reviewed claims, not evidence | same run |
| **B** — IEEE 1364-2005 clauses with both citation polarities (static) | **397 / 808 — 49.1%** | 9 clauses | `zig build test-1364 -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited · classified | 8 · 1 · 0 · 402 | §§17–18 obligation detail: `specification/CLAUSE-AUDIT.md` §7.1 | same run |
| `zig build test` | **pass** | pass | `zig build test` |
| `zig build test-devices` | **pass** | pass | `zig build test-devices` |

`--strict` exit code **0** — 0 only when FAIL, unasserted and XFAIL are all 0.
A, B and C are measured by this script and nothing else may write them.

B and C count citations without executing fixtures. It is not a conformance score:
XFAILs and implementation-limit rejections can supply citations, and a clause
can contain multiple untested rules. See `specification/CLAUSE-AUDIT.md`.

- **Layout**: the tree is laid out like the Zig compiler. `src/` is the
  compiler (`Compilation.zig`, `elab/`, `ir/`, `analog/`, `prove/`, one
  backend per directory under `codegen/`, `zigbuild/`, `vpi/`, `cli/`); `lib/`
  is only what a built artifact links or a host compiles against
  (`contract.zig`, `osdi_dyn.zig`, `sim/`, `base/`, `diag/`, `frontend/`,
  `kernels/`), and `vera` embeds all of it. `tools/contract.zig` is now
  `lib/contract.zig` (still installed as `share/vera/contract.zig`). The
  runtime module table that `--emit-exe` and `--emit-so` build against is one
  list (`zigbuild.runtime_modules`). `tests/` is flat: `fixtures/` is its
  only directory (the hosts that drive a device, the canary, `--emit-verilog`
  and `--emit-rtlil` inputs and the conformance ledgers moved under it), and
  every other file is one root: `unit.zig` holds every module's public-API
  tests as a namespace (a `test` block beside the private declaration it
  checks stays in `src/` or `lib/`), `suite.zig` the whole fixture runner,
  `host.py` every host observation runner and its selftests;
  `tools/conformance.py` owns `run`'s evidence accounting. The one-child
  directories are flat: `src/analog/lower/`, `src/elab/elaborate/`,
  `src/prove/proof/` and `src/vpi/model/` are their parents
  (`vpi/model_analog.zig`, `vpi/model_digital.zig`).
- **Nested module definitions** (§6.2.2): a `module` inside a module is one
  E0240 and the nested definition is skipped whole, so its `endmodule` no
  longer closes the outer module and leaves a stray `endmodule` (E0201).
- The manual documents the predefined `__VERA__` macro (LRM §10.5), and the
  two Annex F.2.2 pass-boundary observations parse their fixtures through
  the preprocessor, so both run.
- **`--sim=verilogAMS|verilogA|verilog`** picks the language family. `verilogA`
  compiles annex C's subset: a digital or mixed-signal construct is **E0250**
  (`vera --explain E0250`), and a `.v` design is refused. `verilog` is IEEE
  1364-2005 alone (`--std=1364-2005` unless `--std` names another 1364 set)
  and refuses a `.va` model. A `--std` of the other family conflicts.
- **`--emit-rtlil`**: a `.v` design as Yosys RTLIL, for synthesis. One module
  per source module, a `process` per `always` block, parameters at their
  defaults; a construct outside the synthesizable subset is refused by name
  with its line. `zig build test-rtlil` has Yosys read, `proc` and
  `check -assert` `tests/fixtures/rtlil/*.v`.

- **Timing checks** (IEEE 1364-2005 §15.3): `$skew`, `$timeskew`, `$fullskew`
  and `$nochange` are evaluated, with timer- and event-based skew and
  `remain_active`; they were E1149. A negative `$setuphold`/`$recrem` limit is
  0 with the delayed signals as copies (§15.5.4), as without the negative
  timing check option.
- **VPI**: an instance's `vpiLineNo` is its instantiation line, a valid
  `vpi_handle_by_index` on a net returns its one-bit `vpiNetBit`, and
  `vpi_iterate(vpiPort, net)` of an internal net is an empty set without an error.
- **`$finish`/`$info` context** (§9.7): the time, or in a dc sweep the swept
  variable and value, or initialization; `$finish(2)` adds memory and CPU use.
- Fixes: integer/real default initialization, size truncation, zero
  replication, derived natures and domainless disciplines, `default_discipline`
  qualifiers and primitive bridges, runtime `case` items, `cross` tolerances
  and event lists (a crossing outside its box gets its own point), timing checks
  in a mixed-signal design's digital half, and hierarchical analog probes read
  from digital.

- Organized fixtures and unified execution reports, including specialized host tests.
- Added **49 conformance checks: 42 expected failures and 7 passes**, grouped into
  [21 behavior gaps](tests/fixtures/conformance/FEATURE_GAPS.tsv). No engine implementation changes.
- Recorded remaining [gaps](tests/fixtures/conformance/GAPS.tsv) and
  [pending host scenarios](tests/fixtures/conformance/PROFILES.json); they earn no passing credit.

### Current evidence — 2026-10-20

Measured with `nix develop -c python3 tools/conformance.py run --jobs=8`.

- **AMS mandatory requirements (E3+): 523 / 1435 (36.4%)**; 889 executed below E3, 13 unexecuted, 10 failing.
- **AMS clauses: 582 / 612 (95.1%)**; 8 failing, 22 uncovered.
- **IEEE 1364 clauses: 575 / 808 (71.2%)**; 87 failing, 45 unsupported, 101 uncovered.

These measure test evidence, not the percentage of compiler features implemented.
E3 requires passing, discriminating checks for every required polarity. Clause
coverage is coarser and retains optional/non-normative sections. IEEE 1364 has
no requirement-level ledger yet, so its comparable requirement percentage is unknown.
Missing fixtures remain in the existing denominators and receive no credit.

Validation: 4,096 fixture/C passes and 36 XFAILs; 48 specialized passes and
9 XFAILs; 12 SPICE passes. These categories overlap. No unexpected failures;
the strict AMS gate exits 1 because expected failures remain.

### v1.0 target: 100% verified mandatory-requirement coverage

- Complete and review the requirement inventory for **both Verilog-AMS 2023 and IEEE 1364-2005**.
- Give every applicable mandatory requirement passing E3-or-better evidence,
  including specialized host tests and every required positive/negative case.
- Require zero failures, XFAILs, skipped required checks, unasserted cases or missing results.
- Document conditional applicability, implementation-defined choices and justified
  exclusions. Unsupported mandatory behavior remains a gap.

<!-- Evidence: 2026-10-20T17:50:46.787602+00:00; source SHA-256 dd5b723adf52a4968a2fb5749840dcbbfdeb225997f7b354765c50555c8fbdc9 -->

## v0.11.5 — 2026-10-20

- Re-triaged external IEEE suites: removed 229 resolved disagreements and classified
  97 new ones. Duplicate or inconsistent non-ANSI task-port declarations remain a known bug.

<details>
<summary>Historical release measurements (A: fixture pass rate; B/C: static citations)</summary>

| Measure | Number | Remaining to v1.0.0 | Command |
|---|---|---|---|
| **A** — fixtures behaving as stated | **2750 / 2750 — 100.0%** | 0 rows | `zig build benchmark -- --strict` |
| &nbsp;&nbsp;↳ FAIL · unasserted · XFAIL | 0 · 0 · 0 | all three to 0 | same run |
| **C** — clauses with both citation polarities (static) | **490 / 612 — 80.1%** | 0 clauses | `zig build benchmark -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited | 0 · 0 · 0 | requires rule-level review | same run |
| &nbsp;&nbsp;↳ classified under `CLAUSE-AUDIT.md` §5 (`CLAUSES.tsv`) | 122 | reviewed claims, not evidence | same run |
| **B** — IEEE 1364-2005 clauses with both citation polarities (static) | **383 / 808 — 47.4%** | 4 clauses | `zig build test-1364 -- --coverage` |
| &nbsp;&nbsp;↳ positive-only · rejection-only · uncited · classified | 3 · 1 · 0 · 421 | §§17–18 obligation detail: `specification/CLAUSE-AUDIT.md` §7.1 | same run |
| `zig build test` | **pass** | pass | `zig build test` |
| `zig build test-devices` | **pass** | pass | `zig build test-devices` |

`--strict` exit code **0** — 0 only when FAIL, unasserted and XFAIL are all 0.
A, B and C are measured by this script and nothing else may write them.

B and C count citations without executing fixtures. It is not a conformance score:
XFAILs and implementation-limit rejections can supply citations, and a clause
can contain multiple untested rules. See `specification/CLAUSE-AUDIT.md`.

</details>

[Earlier releases](docs/CHANGELOG-HISTORY.md).
