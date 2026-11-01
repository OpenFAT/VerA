# Tests

Run commands from the repository root through `nix develop -c`. Keep one
`nix develop -c zig build check --watch -fincremental` running while editing.
The fixtures live in the `tests/conformance` submodule; after cloning, run
`git submodule update --init tests/conformance` (add `--recursive` for the
external suites `zig build conformance` runs).

| Command | Purpose |
|---|---|
| `nix develop -c zig build check` | The pre-commit tier: type-check every root and `zig fmt --check` |
| `nix develop -c zig build test` | Unit, host, reference, generated-code and harness checks, the canary, host observations, paired refusals and host profiles |
| `nix develop -c zig build test-<module>` | One module's tests (`test-cli`, `test-unit`, …); the edit loop |
| `nix develop -c zig build suite -- ams` | Strict AMS fixtures: compile, execute and judge |
| `nix develop -c zig build suite -- devices` | Digital transcripts and diagnostic cases |
| `nix develop -c zig build suite -- ieee1364` | Only the IEEE 1364 digital cases |
| `nix develop -c zig build test-vpi` | VPI module tests and C applications |
| `nix develop -c zig build suite -- vpi` | C header compatibility; compile only |
| `nix develop -c zig build test-spice -Despice=PATH` | The `.sp` decks on an ESPice release, graded against their oracles. VerA does not build ESPice, so that espice compiles the devices with its own VerA: a compatibility check, not a test of this tree |
| `nix develop .#external -c zig build test-external` | `--emit-verilog` in verilator and iverilog, `--emit-rtlil` of `rtlil/*.v` in Yosys |
| `nix develop .#external -c zig build conformance` | The suite's own `conform` harness against this build's `vera`; known failures in `tools/vera.xfail` |
| `nix develop -c zig build suite` | Every fixture plus a separate compiler timing pass |
| `nix develop -c zig build suite -- golden <tag>` | Snapshot every fixture's generated code; `-- golden diff [a b]` compares two |
| `nix develop .#external -c python3 tools/external_analog.py` | The `osdi/` decks in ngspice over `vera --emit-osdi` libraries, against hand-derived values |
| `python3 tests/host.py selftest` | The host oracles fed wrong observations; never evidence |
| `python3 tools/conformance.py selftest` | Regression checks: the subcommands and the fixture layout |

`test` is the development gate; it does not run all language fixtures.
`suite -- ams` fails on failures, unasserted fixtures and expected failures.
`suite -- devices` allows declared expected failures and reports them separately.
A known failure of the fixture runner is a line of `suite.xfail`; a known
failure of `zig build conformance` is a line of `tools/vera.xfail`. Either
run fails on a listed test that passes.

## Layout

Every file in `tests/` is one root the build compiles or runs; its
directories hold VerA's own test inputs, and `conformance/` is the suite.

| File | Contents |
|---|---|
| `suite.zig` | The fixture runner (`vera-suite`) behind `suite` (every mode), `test-spice` and the canary in `test`. One namespace per mode (`Suite`, `Devices`, `Native`, `Fuzz`, `CFixtures`, `SpiceDecks`, `Golden`, `Canary`, `SizeSweep`) over the harness they share: `Fixtures` (collection, the verdict algebra, the parallel run), `Analog` (VerA plugged in as the compiler), `Lint`, `Coverage`, `Digital` and `Child` |
| `unit.zig` | The one test compilation that imports every module: each module's public-API tests as a namespace (`parser_tests` … `vpi_tests`, `ulp_tests`), the stage-boundary guard (`exhaustive_tests`), the allocation-failure sweep (`oom_tests`) and the contract-name claim (`contract_names`) |
| `fuzz.zig` | In-process fuzz targets: `zig build fuzz --fuzz` coverage-guided, replayed seeded under `test` |
| `rng_reference.zig`, `rng_reference.c` | The RNG oracle (`rng_kernels` against the IEEE 1364 §17.9.3 C listing) and, as an executable, its domain refusals, one case per run |
| `printf_reference.zig` | The formatting oracle: `zCReal` against glibc's `snprintf` |
| `generators.zig` | Generated inputs through every pass (`vera-generators`, `test-generators`, in `test`): `wide`, N-wide and N-deep sources on a 1 MiB stack, one child per row |
| `argv.zig` | The degenerate-argv table (`vera-argv`, `test-argv`, in `test`): every flag `--help` documents x degenerate values through the `vera` process; a signal, a panic or a silent nonzero exit is BAD |
| `codegen_probe.zig` | Vectorisation and branchless probes: built as x86_64_v3 assembly and held to their `expect:` lines by `tools/asm_probe.py` (`zig build test-probe`, in `test`) |
| `host.py` | Host observations: `diagnostic_observations` and `paired_compiler_observations` drive the build's `vera`; the profiles bind a real host through an adapter (below); `selftest` |
| `host/` | The hosts that drive a device: `*_host.zig`, the `*_gpu.zig` twin, `*_dyn.zig`, `vdev_*.zig`, `vpi_host.zig` (in `test`) |
| `canary/` | The wrong-on-purpose fixtures the canary in `test` judges, with their `EXPECT.tsv` |
| `rtlil/`, `beh_verilog/`, `osdi/` | The `--emit-rtlil`, `--emit-verilog` and `--emit-osdi` inputs |
| `vpi_negative/` | The VPI negative-input table (`test`, `test-vpi-negative`): a C application handing every exported `vpi_*` entry point each invalid argument it takes, and the design it probes |
| `suite.xfail` | The fixture runner's known failures: one suite path a line, then `# reason` |
| `conformance/` | The [VAMS Conformance Suite](https://github.com/OpenFAT/VAMS-Conformance-Suite), a submodule: the fixtures (below) and its own `conform` harness, tool configs and external suites |

The suite's corpus is `conformance/tests/`, split by language and then by
specification chapter. The suite is tool-neutral: VerA keeps nothing in it.

| Suite path | Contents | VerA's runner |
|---|---|---|
| `tests/verilog-a/` | Analog-only fixtures: the Annex C subset, with the `.sp` decks beside the models they load | AMS (`suite -- ams`); decks `test-spice` |
| `tests/verilog-ams/` | Fixtures needing the full language; `digital/` holds the mixed-signal `.v` cases, `ch11_vpi/` and `ch12_vpi_routines/` the VPI `.c` applications | AMS; `digital/` the digital runner; `.c` `test-vpi` |
| `tests/verilog/` | IEEE 1364-2005 by clause (`03_lexical_conventions` ...); `pli/` holds the PLI `.c` applications | digital (`suite -- devices`, `suite -- ieee1364`); `.c` `test-vpi` |
| `tests/spice/` | Annex E: SPICE primitives and model cards seen from Verilog-AMS | AMS |
| `tests/include/` | `check.vh` (the `CHECK` macros) and `erfc.vh`, on every compile's include path | |
| `tests/netlist/` | ESPice's decks | none |

A dedicated test file is a namespace of `unit.zig`. A `test` block that
checks a file's private declarations stays beside that declaration in `lib/`
or `src/`, as in Zig's own std; what a unit namespace needs from a module is
exported by the module's root (`Lower.Harness`, `codegen.Harness`,
`digital.emit`).

## Adding a fixture

A fixture is a file of the suite: commit it in `tests/conformance` first, then
move VerA's submodule pointer. Put it under its language directory: a source
that uses anything Annex C excludes from Verilog-A (digital behavior, `wreal`,
`discrete`, `===`, x/z literals, ...) goes in `verilog-ams/`, a 1364 case in
`verilog/<clause>/`, the rest in `verilog-a/`. Fixtures compile with no
prelude: a `.va` writes `` `include "disciplines.vams" `` (and
`constants.vams`) itself, or includes `check.vh`, which includes both; a
missing include is E0371. A `.v` case states its compile options as
`//@ std SPEC`, `//@ libmap FILE`, `//@ files FILE...` and `//@ liblist LIB`,
paths relative to the case; a case about the zero-delay event budget sets
it with `//! event-budget N` (`vera --event-budget=N`, a VerA line the
suite's harness ignores). A known VerA gap is a line of `suite.xfail`
(and of `tools/vera.xfail` when `conform` fails it too), not a directive in
the fixture. A host goes in
`host/`, its `//! device` line naming the device by its
suite path (`//! device tests/verilog-a/ch05_analog_behavior/timer_fixed.va`).

Keep the specification chapter directories. Name each case after the behavior
it checks, using lowercase words with underscores: `parameter_range_excluded_interior.va`,
`and_gate_three_delays_rejected.v`. Keep clause and sentence identifiers in
`//! lrm` or `//! inherited` directives. Avoid numbered work batches, `audit_`
and `triage_` prefixes. Keep module identifiers stable when renaming a file.
Name a rejection's forbidden behavior and use `_rejected` for new cases.

Keep a digital case's `.expected.txt` or `.expected.vcd` beside its source with
the same stem. Keep supporting includes, tables and designs near their users.
`//! neighbour` and a `.c`'s `//! design` paths are relative to the referring
file; a host's `//! device` path is relative to the suite root.
Rename these references and golden-output paths together. SPICE `.hdl` paths
must name real files relative to the deck; the harness does not guess filenames.

The AMS runner collects, under `verilog-a/`, `verilog-ams/` and `spice/`,
`.va` files with directives and `.v` files with directives that have no
transcript and are not digital rejection cases. The digital runner owns
`verilog/` and `verilog-ams/digital/`: `.v` transcript cases and `//! reject`
cases. `netlist/` and VerA's `canary/` are outside both. A support design without an executable
assertion is not a passing test. Host-only designs use ordinary `//`
documentation rather than `//!` fixture directives unless they also have
their own executable checks.

## Known failures

New regression cases assert the required result. A line of `suite.xfail`
(the fixture's suite path, then `# reason`) and Python's `expectedFailure`
preserve the known failure; an unexpected pass fails the suite so the marker
must be removed after implementation. No engine behavior is changed by adding
a case.

`test`'s diagnostic observations build and run the exact CLI artifact, then check the
diagnostics around `$finish` and `$info`. It excludes testbench progress labels
from its oracle: a runner timestamp is not a timestamp in a task diagnostic.
Compilation/setup errors fail normally. Use
`python3 tests/host.py diagnostic_observations --vera zig-out/bin/vera --strict` to return nonzero
for the known failures too.

`.v.in`/`.expected.txt.in` are inactive conditional scenarios, not runnable
digital cases: they need a host interface VerA does not expose yet. Do not
invent an option spelling or fail an unspecified choice to make one run.

The executable report/help, equation-tolerance and conditional capability
assertions use the explicit adapter protocol below. They belong to the
development gate and record exact named skips until a real host adapter is
configured. Synthetic oracle regression tests earn no language conformance
credit.

Protected ciphertext regressions have public test keys and an explicit
profile in `conformance/tests/verilog/28_protected_envelopes/known_keys.json`.
The local README explains the key-provider prerequisite and the independent
OpenSSL vector check. Current rejection at the protect directive is recorded
as XFAIL; it is not evidence of a cryptographic comparison.

## Host profile adapters

`nix develop -c zig build test` also runs the registered conditional
assertions (`host.py`'s `PROFILES`). Without a real adapter they record
**skip**, not pass. Compiling a support model or passing
its local checks alone supplies no host-observation credit. Testing an oracle
against synthetic data supplies no language conformance credit.

Set `VERA_HOST_PROFILE_ADAPTER=/absolute/path/to/executable` to bind a host.
Each runner also accepts `--adapter /path` and `--results /path.tsv`. The
adapter is executed directly, without a shell, once per observation. It reads
one JSON object from stdin:

```json
{
  "schema_version": 1,
  "scenario": "model_help",
  "source": "/absolute/path/to/model_help_descriptions.va",
  "work_dir": "/temporary/scenario/directory",
  "setup": {"model": "help_model"}
}
```

It must invoke the real simulator/host with this input, wait for completion,
and return actual observations:

```json
{
  "schema_version": 1,
  "status": "ok",
  "observations": {"help_text": "...actual host help..."}
}
```

If the required interface or applicability is absent, return
`{"schema_version":1,"status":"unavailable","reason":"specific missing capability"}`.
A nonzero adapter exit, malformed response, timeout, or violated assertion fails
the test. Do not use `unavailable` to hide an observed wrong result. Adapter
stderr is available for failure details; stdout is reserved for the response.

The adapter is responsible for binding the exact host under test and exposing
its observations faithfully. It must not return expected constants, replay
saved output, derive report values from declaration metadata, or reconstruct
solver gates on the test side. A successful synthetic adapter validates only
the test protocol. The repository does not provide a simulator adapter for
capabilities that its host has not yet exposed.

| Scenario | Assertions and response contract |
|---|---|
| `operating_point_reports` | `ReportObservations` documents raw short/full/parameter reports, token spans, and solved state before/after reporting. Hidden values, alias duplication, scaling and physical current are checked independently. |
| `model_help` | The same runner requires actual help output for the requested module or paramset, separately. |
| `indirect_equation_tolerance` | `IndirectEquationObservations` documents the live equality tolerance, solved circuit, and signed residual-gate probes. Unknown tolerances such as `u_abstol` do not satisfy this observation. |
| `absdelta_unconsumed_events_rejected` | `AbsdeltaRejectionObservations` specifies pending events from a genuine trial, acceptance/rejection decisions, queue disposal, and clean retries. A normal crossing count or reconstructed queue is insufficient. |
| `identifier_length_limit` | `ConditionalObservations` first requests `operation=describe`: return integer `limit`, its `documentation`, and `diagnostic_code`. If there is no documented finite limit, report unavailable. The test generates two inputs and requests `operation=compile`; return actual `exit_code`, `stdout`, `stderr`, and structured `diagnostics` records with `level` and `code`. A diagnostic code appearing in source text or a warning is insufficient. |
| `input_position_restore_failure` | The same runner requests healthy and fault-injected rejected reads of `41 73\n`. Return `trial_values`, `iteration_rejected`, `restore_attempted`, `fatal`, `retry_values`, `simulation_terminated`, and `continued_after_restore`. The fault also exposes `backing_position_restorable`, `buffer_replay_available`, `restore_failed`, and the actual `diagnostic`. The fault must make restoration impossible through both the backing stream and any buffer; an ordinary non-seekable stream is insufficient. A fatal outcome must terminate simulation, though the adapter process itself may remain alive. |
| `driver_type_unavailable` | Bind exactly one genuinely opaque driver at the requested net. Return integer `opaque_driver_count`, `opaque_driver_index`, `opaque_driver_type`, `known_driver_count`, `known_driver_type`, boolean `opaque_type_available`/`known_type_available`, `unavailable_reason`, and `vpi_errors`. Unknown type is required only for the opaque driver; the reg control must report `DRIVER_BEHAVIORAL`. Do not turn off known information just to fabricate applicability. |

`host.py selftest` deliberately feeds wrong observations to the oracles.
