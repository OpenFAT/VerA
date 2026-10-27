# Agents

VerA is a compiler whose consumers pin it (ESPice by commit and hash) or
follow `main` (`nix run github:OmarSiwy/VerA`). Two rules decide everything
below: **every test names its oracle**, and **main is green by machine**.
`TESTING.md` is the oracle map and the tiers; `CONTRIBUTING.md` is the
branch, pin and release policy.

## Skills to load first

Load each with the Skill tool (other agents: read
`~/.claude/skills/<name>/SKILL.md` and the companion files it names). Source:
https://github.com/OmarSiwy/NixOSConfig/tree/main/skills

| Skill | Use it for here |
|---|---|
| `data-oriented-design` | AST, `elab/` and `ir/` tables: the six questions, SoA, narrowest widths, handles |
| `codebase-clean-code` | `Compilation.zig` as the spine, owners by directory, `module_specs` dependency direction (see Layout) |
| `api-design` | Every `pub` function, `lib/contract.zig` (the device ABI), OSDI and VPI: usage code first, caller owns memory and flow |
| `code-style` | File order, ≤500 code lines per file, `check_style.py` |
| `simd-loops` | `lib/kernels`: the plain-loop forms, or `@Vector` with a scalar oracle |
| `doc-comments` | Every `pub` item |
| `ponytail` (ultra) | How little code; never what shape the data takes |
| `assertions` | Contracts, capacities, bounded loops; recursion bounded on input-controlled depth |
| `test-plan`, `tdd` | `TESTING.md`: the oracle map, the tiers, a feature's definition of done |

Language:

| Skill | Use it for here |
|---|---|
| `zig` | Zig 0.18 idioms and the zero-cost probe |

Project-specific:

| Skill | Use it for here |
|---|---|
| `compiler-construction` | The whole pipeline: lexer, parser, `elab/`, `ir/`, lowering, interning, coded diagnostics, goldens |
| `writing-perfect-verilog` | `codegen/digital` and `codegen/verilog`: the Verilog VerA emits, and the IEEE 1364 fixtures |
| `spice-engine` | `codegen/device`: the stamps and derivatives a contract device hands ESPice, finite-difference Jacobian checks |

## The method

Binding on every change, in every project.

### Code

- Five commitments: lean storage, no runtime residue, cheap change,
  contained failure, proof by test.
- Answer the six data questions before writing code. Then: one array per
  field, the narrowest width the stated range allows, typed `u32` handles
  with a sentinel, existence tables instead of flags, hot/cold split, tables
  sized once from a named capacity, a compile-time size assertion on every
  hot struct.
- An abstraction on a hot path carries an assembly probe: FOLDED, IDENTICAL,
  EQUIVALENT or NEGATIVE pass; RESIDUE fails the build. A "no residue" claim
  cites the probe, a speed claim cites a benchmark. Dispatch per batch, never
  per element.
- A seam names what varies and needs a second case today; it sits on the
  cheapest rung (concrete, free function, table, closed enum with exhaustive
  switch, comptime, request table, function-pointer table, `dyn`, plugin).
- Tables, transforms, one spine per pipeline (ifs up, fors down), one owner
  writes each table and everyone else appends requests. Three likely changes
  each have a change radius of zero; the compiler lists every other site.
- APIs start from the caller's code. The caller owns memory and flow:
  requests instead of callbacks, an immediate twin for anything retained.
  Factor at the second real instance.
- Branches: delete, then branchless, then vectorize along a lane axis. The
  `W == 1` instantiation is the scalar oracle; vectorization is verified in
  the assembly.
- GPU: SoA always, the roofline ceiling named with its arithmetic before
  tuning, data kept on the device, fixed-order reductions, the dependency DAG
  recovered before porting. "This belongs on the CPU" is a valid verdict.
- An operating error returns to the caller that can decide; a bug hits an
  assertion. Two or more split, paired assertions per function, a bound on
  every loop, input validated once at the edge, fallible work before the
  commit.
- Pass order: boundary, placement, data, zero-cost proof, contracts, tests,
  branches, lanes. Data layout beats brevity. Every pass keeps NaN gates,
  allocation-failure paths, `errdefer`s, trust-boundary validation and
  tolerances.

### Testing

- The oracle is named before the code and never recomputes the answer the
  way the code does. Cheapest first: assertions, a reference
  implementation, a round trip, a certificate, a metamorphic relation, a
  model, a golden with recorded provenance, a spec example.
- The main bug class is a wrong number with no crash, which coverage and
  fuzzing cannot see. A bug found by a person is a hole in the oracle set:
  it lands with its regression test and the oracle or generator that would
  have caught its class.
- A new test goes red on the bug before it is trusted green.
- Unsupported fails and never skips. A known failure is a named marker in
  the tree; an unexpected pass fails until the marker goes. Name lists are
  compared, never counts.
- A tolerance follows the oracle's own accuracy. Determinism is a test:
  1 job and N jobs give the same bytes, and the order is fixed, not the test.
- A flaky test is fixed or quarantined the same day, never retried
  silently.
- Tiers: pre-commit under 10 s, merge under 15 min, nightly, release. A
  release ships on numbers a script checks. The map lives in `TESTING.md`.

### Builds

- A build is a cache keyed on its declared inputs. Every producing step has
  an output argument, every checking step an exit-code check, every file
  read at run time is declared (`addFileInput`) or the step says
  `has_side_effects`. Keys hash contents, never absolute paths.
- Cut the artifact graph where edits land: one object per generated unit,
  narrow imports for shared ones, kernels out of host graphs.
- Zig edit loop: `zig build check --watch -fincremental`, one watch per
  artifact across all worktrees; the result that counts comes from a plain
  build. One global cache per toolchain store path; a worktree symlinks its
  `.zig-cache` to the main checkout's.
- Rust: flags live in `.cargo/config.toml`, never a one-off `RUSTFLAGS`;
  `check`, `build`, `test` and rust-analyzer agree on features, profile and
  target directory (rust-analyzer gets its own).
- Nothing collects a cache. Keep a byte budget per cache and delete old
  entries only while no build runs (the `long-term-garbage-collection`
  skill); a warm cache is kept, never wiped by routine.
- Gate on the exit code: `cmd | tail` swallows it, so use
  `exit "${PIPESTATUS[0]}"`.

### Maintaining

- `main` is green by machine: work lands through a pull request whose merge
  result passed the required checks. No `dev` branch; topic branches are
  deleted after the merge.
- Bots never push to `main`. Generated output ships as a release asset or
  through a gated pull request.
- Every dependency is pinned by commit and content hash, the toolchain by
  `flake.lock`, actions by SHA. A third-party input you hash is mirrored
  somewhere you control.
- The changelog is written by hand, one line per change citing its issue,
  every number in it measured. A release refuses a version mismatch, builds
  every target, checks every artifact and smokes the bundle.
- CI holds: the merge gate, every target compiled, docs that execute,
  reference suites gated by name, a nightly, the downstream contracts, the
  release job.

## Testing

- An oracle is the independent thing that says "this output is wrong". A
  check that recomputes the answer the way the code does passes by
  construction: it is not a test. Name the oracle in the fixture or test
  (`//! lrm` clause, reference tool, certificate, canary) before writing code.
- The main bug class is a wrong number or wrong text with no crash. Coverage
  and fuzzing cannot see it, so reach for a certificate, a reference tool or
  a metamorphic relation first, and an example test last.
- A bug found by a developer, a user or a review is evidence that the oracle
  set is incomplete. Fix it with a new oracle or a new generator feature that
  would have caught its whole class, plus the fixture that reproduces it.
- A known failure is a named, inline marker: `//! xfail` in the fixture, a
  line of `tools/vera.xfail` or of `tests/suite.xfail`. An
  unexpected pass fails the run until the marker goes. Never a skip, never a
  silent retry, never a count.
- A flaky test is fixed or quarantined the same day. A tolerance follows the
  oracle's own accuracy (ngspice at `reltol=1e-3` is not a `1e-6` oracle).
- Nondeterminism is fixed at its order, never in the test: two runs of the
  same command write the same bytes.
- Gate on the exit code. `zig build test 2>&1 | tail` swallows it.

## Maintaining

- `main` is the only long-lived branch and it is always green: work lands
  through a pull request whose merge result passed `test`, `cross`,
  `conformance`, `external` and `nix`. No `dev` branch.
- Nothing reaches `main` but a pull request whose required checks passed:
  the ruleset "main is green" has no bypass. Charts go to the site as an
  artifact; the release job's `sources.json` goes through `nix flake check`
  and then a pull request it dispatches the checks on and auto-merges.
- The changelog is written by hand, one line per change, each fix citing its
  issue. Its numbers are measured: `publish` re-measures them and refuses
  the tag on a mismatch.
- The toolchain is a pinned dependency: the Zig in `flake.nix`,
  `.github/workflows/*` and `sources.json` move together. Actions are pinned
  by SHA; Dependabot moves them.

## Building

- Run every `zig build` inside `nix develop -c …`. The shell gives each Zig store path its own global cache (`ZIG_GLOBAL_CACHE_DIR=~/.cache/zig-<store path>`). ESPice pins a different build of the same Zig version, so with a shared `~/.cache/zig` the two evict each other's build runner and every `zig build`, even `--help`, takes about 2 minutes. The first build in a fresh cache pays a one-time compile of about 70 s.
- The steps are the tiers (`TESTING.md`): `check` (pre-commit: type-check and `zig fmt --check`), `test` (the merge gate's fast part), `suite -- <mode>` (the fixture runner: `ams`, `devices`, `ieee1364`, `vpi`, `golden`; no mode runs every fixture, timed), `test-spice`, `test-external` (in `nix develop .#external`), `conformance`, `fuzz`, `build-all`, and `test-<module>` for one module's tests.
- Edit loop: keep `zig build check --watch -fincremental` running. `check` type-checks every root without emitting or running anything, so an edit is re-checked in under a second. `zig build test-<module> --watch -fincremental` also works, but each rerun costs the tests' run time.
- After cloning, run `git submodule update --init tests/conformance`: every fixture lives in that submodule. `--recursive` adds the suite's external suites, which only `zig build conformance` runs.
- `zig build -Dtarget=wasm32-wasi` builds `vera.wasm`. The front end and every `--emit-*` that only writes text run there; anything that spawns `zig` cannot. Size budgets are asserted with `<=` so they hold on 32-bit targets.
- VerA does not depend on ESPice; ESPice depends on VerA. `zig build test-spice -Despice=PATH` runs the `.sp` decks on an espice it is handed (an ESPice release, a nix profile or a local build) and grades each against its oracle. That espice compiles the decks' devices with its own VerA, so the step checks compatibility with that release, not this tree; `.github/workflows/spice.yaml` imports a pinned ESPice release and runs it (disabled, by hand only, until ESPice publishes one). Without `-Despice` the step fails. No `zig build` fetches anything.

## Worktrees

- Symlink a new worktree's `.zig-cache` to the main checkout's (`ln -s <main>/.zig-cache <worktree>/.zig-cache`) so they share build results.
- Shared caches share incremental state: run one `--watch -fincremental` per artifact at a time across all worktrees.

## Layout

Laid out like the Zig compiler: `src/` is the compiler, `lib/` is what it
ships, `tests/` the tests, `tools/` the scripts.

- `lib/`: everything a `vera` artifact links or a host compiles against, and
  nothing else. `contract.zig` (the device ABI, installed as
  `share/vera/contract.zig`), `osdi_dyn.zig` (the OSDI 0.4 dyn), `sim/` (the
  runtime of `--emit-exe` executables and `.v` devices) and the modules the
  runtime imports: `base/`, `diag/`, `frontend/`, `kernels/`. `build.zig`
  embeds the whole of `lib/` into `vera` (`simSources`), which writes it out
  beside a build (`src/main.zig`'s `simTree`); `src/zigbuild/exe.zig`'s
  `runtime_modules` names the module roots inside it.
- `src/`: `main.zig` and `cli/` (the driver), `Compilation.zig` (the `vera`
  module: the spine), `elab/`, `ir/`, `analog/`, `prove/` (the analog
  pipeline), `codegen/` (one directory per backend: `device/` the contract
  device for `--emit-zig`/`--emit-so`/`--emit-osdi`, `exe/` the analog
  testbench, `digital/` the `.v` executable, device and `--emit-rtlil`,
  `verilog/` the behavioural `--emit-verilog`), `zigbuild/` (drives `zig`),
  `vpi/` (the VPI library), `dynlib.zig`.
- `tests/`: every file a root the build compiles or runs, and VerA's own
  test inputs in directories beside them: `host/` (the hosts that drive a
  device), `canary/` (the wrong-on-purpose fixtures), `rtlil/`,
  `beh_verilog/` and `osdi/` (the `--emit-rtlil`, `--emit-verilog` and
  `--emit-osdi` inputs), `suite.xfail` (the fixture runner's known
  failures) and the `conformance/` submodule. The roots: `unit.zig` (every module's public-API tests,
  one namespace per module), `suite.zig` (the fixture runner, one namespace
  per mode over the shared harness), `fuzz.zig`, `rng_reference.zig` (+ `.c`),
  `printf_reference.zig`, `codegen_probe.zig`, `host.py` (the host
  observation runners and their `selftest`). A nested namespace may not
  redeclare a file-scope name, so a merged root's file scope declares only
  its namespaces, `main` and the test that references them. `src/` and
  `lib/` keep only the `test` blocks beside the private declaration they
  check, as in Zig's std, and the test support a module exports for the unit
  namespaces (`Lower.Harness`, `codegen.Harness`, `elab/fixture.zig`,
  `prove/fixture.zig`). `conformance/` is the VAMS Conformance Suite, a
  submodule: its `tests/` holds the HDL, C and SPICE inputs by language
  (`verilog-a/`, `verilog-ams/`, `verilog/`, `spice/`, `include/`) and
  chapter. The suite is tool-neutral: VerA runs it through its `conform`
  harness like any other tool, with `tools/vera.xfail` as its baseline.
  `tests/README.md` lists the suites.
- `tools/`: one file per script (`conformance.py`: the release measures and
  fixture-maintenance signals, `report.py`, `doctest.py`, `external_analog.py`
  (the OSDI decks in ngspice), `update-sources.py`), `vera.xfail` and
  `zrunner.zig`.
- A module imports `lib/` freely and `src/` never imports a module above it in
  `build.zig`'s `module_specs`; `lib/` imports nothing from `src/`.
