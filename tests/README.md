# Tests

Run commands from the repository root through `nix develop -c`. Keep one
`nix develop -c zig build check --watch -fincremental` running while editing.

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
| `nix develop -c zig build test-spice --fork .` | The `.sp` decks on ESPice (built against this tree), graded against their oracles |
| `nix develop .#external -c zig build test-external` | `--emit-verilog` in verilator and iverilog, `--emit-rtlil` in Yosys, VAMPyRE on the compact models |
| `nix develop -c zig build suite` | Every fixture plus a separate compiler timing pass |
| `nix develop -c zig build suite -- golden <tag>` | Snapshot every fixture's generated code; `-- golden diff [a b]` compares two |
| `nix develop -c python3 tools/conformance.py run` | Execute the principal suites and write a unified evidence report |
| `python3 tests/host.py selftest` | The host oracles fed wrong observations; never evidence |
| `python3 tools/conformance.py selftest` | Regression checks: the subcommands, `run`'s accounting, the fixture layout |

`test` is the development gate; it does not run all language fixtures.
`suite -- ams` fails on failures, unasserted fixtures and expected failures.
`suite -- devices` allows declared expected failures and reports them separately.
The conformance report preserves those distinctions, including each suite's
exit status. An expected AMS failure therefore fails the combined command.
Unexpected failures, missing execution records and unasserted fixtures also
fail the command.

## Layout

`tests/` is flat: `fixtures/` is its only directory, and every other file is
one root the build compiles or runs.

| File | Contents |
|---|---|
| `suite.zig` | The fixture runner (`vera-suite`) behind `suite` (every mode), `test-spice` and the canary in `test`. One namespace per mode (`Suite`, `Devices`, `Native`, `Fuzz`, `Ieee1364`, `CFixtures`, `SpiceDecks`, `Golden`, `Canary`, `SizeSweep`) over the harness they share: `Fixtures` (collection, the verdict algebra, the parallel run), `Analog` (VerA plugged in as the compiler), `Lint`, `Coverage`, `Digital` and `Child` |
| `unit.zig` | The one test compilation that imports every module: each module's public-API tests as a namespace (`parser_tests` … `vpi_tests`, `ulp_tests`), the stage-boundary guard (`exhaustive_tests`), the citation check (`citations_tests`), the allocation-failure sweep (`oom_tests`) and the contract-name claim (`contract_names`) |
| `fuzz.zig` | In-process fuzz targets: `zig build fuzz --fuzz` coverage-guided, replayed seeded under `test` |
| `rng_reference.zig`, `rng_reference.c` | The RNG oracle (`rng_kernels` against the IEEE 1364 §17.9.3 C listing) and, as an executable, its domain refusals, one case per run |
| `printf_reference.zig` | The formatting oracle: `zCReal` against glibc's `snprintf` |
| `codegen_probe.zig` | Hand-built vectorisation probes (`zig build-obj … -femit-asm`); nothing in the build runs it |
| `host.py` | Host observations: `diagnostic_observations` and `paired_compiler_observations` drive the build's `vera`; the profiles bind a real host through an adapter (below); `selftest` |
| `fixtures/` | HDL, C, SPICE and their expected outputs and support inputs, by specification chapter, with the host that drives a device (`*_host.zig`, its `*_gpu.zig` twin, `*_dyn.zig`) beside the device. `canary/`: the wrong-on-purpose fixtures the canary in `test` judges, with their `EXPECT.tsv`; `beh_verilog/` and `rtlil/`: the `--emit-verilog` and `--emit-rtlil` inputs; `conformance/`: the requirement ledger, baselines and registries; `external/`: the external suites' triage |

A dedicated test file is a namespace of `unit.zig`. A `test` block that
checks a file's private declarations stays beside that declaration in `lib/`
or `src/`, as in Zig's own std; what a unit namespace needs from a module is
exported by the module's root (`Lower.Harness`, `codegen.Harness`,
`digital.emit`). The `CLAUSES.tsv` files beside fixture groups classify
specification clauses; they are metadata, not passing tests.

## Fixture names and ownership

Keep the specification chapter directories. Name each case after the behavior
it checks, using lowercase words with underscores: `parameter_range_excluded_interior.va`,
`and_gate_three_delays_rejected.v`. Keep clause and sentence identifiers in
`//! lrm` or `//! inherited` directives. Avoid numbered work batches, `audit_`
and `triage_` prefixes. Keep module identifiers stable when renaming a file.
Name a rejection's forbidden behavior and use `_rejected` for new cases.

Keep a digital case's `.expected.txt` or `.expected.vcd` beside its source with
the same stem. Keep supporting includes, tables and designs near their users.
`//! neighbour` paths are relative to the referring fixture.
`//! design` and host `//! device` paths are relative to `tests/fixtures/`.
Rename these references and golden-output paths together. SPICE `.hdl` paths
must name real files relative to the deck; the harness does not guess filenames.

The AMS runner collects `.va` files with directives and `.v` files with
directives that have no transcript and are not digital rejection cases, and
skips `canary/`. The digital runner owns `.v` transcript cases and
`// digital-runner: reject` cases. A support design without an executable
assertion is not a passing test. Host-only designs use ordinary `//`
documentation rather than `//!` fixture directives unless they also have
their own executable checks.

## Execution-backed coverage

Each `conformance.py run` creates a fresh directory under
`.zig-cache/conformance/`, containing suite logs, per-test results, `report.md`
and `report.json`. `--output=/path` selects a parent directory and `--jobs=N`
limits build and fixture parallelism. Reports include the commit, time and a
content hash covering uncommitted source changes. Editing inputs during a run
invalidates that report. Old result directories are never reused.

The unified run also executes a fresh AMS `--perturb` pass. Its verdicts are
recorded separately in `ams-perturbed.tsv`: passing means the changed expected
values were rejected. Only a matching passing normal assertion can gain
discrimination evidence. Missing, loose or failed perturbations cannot upgrade
it, and perturbations never replace the normal fixture verdict.

A clause is **covered** when a test that cites it passed in that run. A failing
or expected-failing test makes that clause **failing**, even if another test
passes. A clause classified as not supported is **unsupported**, even when its
rejection tests pass. **Not run** means a citation exists without passing
execution; **uncovered** means a testable clause has no registered test. A
clause that `GAPS.tsv` dispositions as `no-fixed-oracle` is **not applicable**:
it is a non-normative, optional or explicitly unspecified heading with no
unconditional executable outcome, so it is neither a missing test nor a
failure. Classifications remain in the denominator and are listed separately.
A refusal tests a prohibition, not support for the refused construct; positive
and negative evidence are available separately in the JSON.

Clause coverage is a map of exercised requirements, not a percentage of all
possible language behavior. The AMS sentence ledger gives a stricter view:
a bare clause citation does not cover every sentence in that clause. IEEE
1364 currently has a clause inventory, not a sentence ledger. Static
`--coverage` inventories and the older release measures remain available;
they count citations and do not establish execution.

## Specialized tests

Some behavior needs accepted/rejected solver steps, a host parameter write,
callbacks, or an independent numerical reference. Register its exact assertion
in `fixtures/conformance/SPECIALIZED.tsv`, with the source, executable
artifact, standard, clause or sentence, polarity and a description of what it
checks. SPICE registrations use artifact `spice` and the deck's path relative
to `fixtures/` as the test name. Its `.expected.json` supplies the assertions.
Every deck records its actual pass, fail or skip result; a compile-only deck
earns no runtime coverage.

`zig build test -Dtest-results=/absolute/directory` records each named test's
pass, fail, skip or expected-failure status. Emitted-device artifact names are
`<host stem>--<device stem>` so different parameterizations never overwrite
one another. A registration must match the exact executed test. Skips and
missing results earn no coverage. Sentence credit also requires the correct
polarity; do not tag every sentence merely because a test exercises its clause.

C applications with `//! design` are discovered automatically. A VPI result
marker is written only after its expected exit, stdout and stderr checks pass.
A compile-only C fixture supplies ABI evidence but no runtime clause coverage.
The VPI acceptance application also has named `// evidence: xfail <ID>` checks.
They require matching runtime output and retain their XPASS guards, so a
resolved gap cannot silently remain marked as expected failure. These checks
are registered in the same specialized catalog. Clause-only failures are
listed separately when no exact sentence can be assigned.

The reporting regressions explicitly check these rules. During structural
cleanup, preserve the case inventory and compare per-case verdicts after
translating renamed paths. Update references before removing old paths; both
build discovery and evidence accounting read fixture headers.

## Known conformance gaps

`fixtures/conformance/GAPS.tsv` accounts for every non-covered clause and
mandatory unmeasured sentence in the report preceding the gap regressions. It
is a review inventory, not execution evidence. Its entries distinguish
executable tests, pending host profiles, conditional requirements and
headings without a fixed behavioral oracle.

`fixtures/conformance/FEATURE_GAPS.tsv` groups the new failing checks into
concrete behavior gaps. This is a defined work breakdown, not a claim that a
language has an objectively fixed number of features. It does not count each
repeated test or each parent/child specification heading as a separate
feature. The unified report measures these groups from the current execution:
any failure keeps the group failing, and every check must pass before it is
covered.

New regression cases assert the required result. `//! xfail` and Python's
`expectedFailure` preserve the known failure; an unexpected pass fails the
suite so the marker must be removed after implementation. No engine behavior
is changed by adding a case.

`test`'s diagnostic observations build and run the exact CLI artifact, then check the
diagnostics around `$finish` and `$info`. It excludes testbench progress labels
from its oracle: a runner timestamp is not a timestamp in a task diagnostic.
Compilation/setup errors fail normally. Use
`python3 tests/host.py diagnostic_observations --vera zig-out/bin/vera --strict` to return nonzero
for the known failures too. The unified conformance run records its exact
named assertions alongside the other specialized tests.

`fixtures/conformance/PROFILES.json` describes test inputs and oracles
requiring an additional host interface, such as negative-timing invocation
options or model reports. `.v.in`/`.expected.txt.in` are inactive conditional
scenarios, not runnable digital cases. They earn no coverage until the actual
host interface is bound and the assertions run. Do not invent an option
spelling or fail an unspecified choice just to make an uncovered row red.

The executable report/help, equation-tolerance and conditional capability
assertions use the explicit adapter protocol below. They belong to the
development gate and record exact named skips until a real host adapter is
configured. Synthetic oracle regression tests earn no language conformance
credit.

Protected ciphertext regressions have public test keys and an explicit
profile in `fixtures/ieee1364/28_protected_envelopes/known_keys.json`.
The local README explains the key-provider prerequisite and the independent
OpenSSL vector check. Current rejection at the protect directive is recorded
as XFAIL; it is not evidence of a cryptographic comparison.

## Host profile adapters

`nix develop -c zig build test` also runs the registered conditional
assertions (`host.py`'s `PROFILES`). Without a real adapter they record
**skip**, not pass. These tests also belong to `zig build test`, and their
named results enter the unified report. Compiling a support model or passing
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

`fixtures/conformance/PROFILES.json` records these prerequisites and their
exact test names. Absent interfaces remain pending there even after the
assertions have been written. `host.py selftest` deliberately feeds wrong
observations to the oracles; only the host runners are registered in
`SPECIALIZED.tsv`.
