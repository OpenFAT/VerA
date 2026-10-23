# Agents

VerA is a compiler whose consumers pin it (ESPice by commit and hash) or
follow `main` (`nix run github:OmarSiwy/VerA`). Two rules decide everything
below: **every test names its oracle**, and **main is green by machine**.
`TESTING.md` is the oracle map and the tiers; `CONTRIBUTING.md` is the
branch, pin and release policy.

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
  line of `tools/vera.xfail`, a row of an external suite's `TRIAGE.md`. An
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
- `zig build -Dtarget=wasm32-wasi` builds `vera.wasm`. The front end and every `--emit-*` that only writes text run there; anything that spawns `zig` cannot. Size budgets are asserted with `<=` so they hold on 32-bit targets.
- `zig build test-spice --fork .` builds ESPice against this tree and runs the `.sp` decks on it. ESPice is a lazy dependency fetched only for this step: ESPice, Gompute and the model tarballs, network once, into `zig-pkg/`. Add `--fork ../ESPice` to build a local ESPice checkout instead. `-Despice=PATH` runs an installed espice and then takes no `--fork`, since an unused fork is an error. `-Dgpu`, `-Dcuda-arch` and `-Dhip-arch` forward to ESPice's build. Once `zig-pkg/` holds ESPice, every `zig build` configures it, and one without `--fork .` also fetches the VerA that ESPice pins; delete `zig-pkg/` to drop it.
- A removed build step takes its tests with it silently, so `tools/conformance.py steps` diffs `zig build -l` against `tests/fixtures/conformance/STEPS.txt`; run `steps --update` when the change is intended.

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
- `tests/`: flat, `fixtures/` its only directory, every other file a root
  the build compiles or runs: `unit.zig` (every module's public-API tests,
  one namespace per module), `suite.zig` (the fixture runner, one namespace
  per mode over the shared harness), `fuzz.zig`, `rng_reference.zig` (+ `.c`),
  `printf_reference.zig`, `codegen_probe.zig`, `host.py` (the host
  observation runners and their `selftest`). A nested namespace may not
  redeclare a file-scope name, so a merged root's file scope declares only
  its namespaces, `main` and the test that references them. `src/` and
  `lib/` keep only the `test` blocks beside the private declaration they
  check, as in Zig's std, and the test support a module exports for the unit
  namespaces (`Lower.Harness`, `codegen.Harness`, `elab/fixture.zig`,
  `prove/fixture.zig`). `fixtures/` holds the HDL, C and SPICE inputs by
  chapter with the host that drives a device beside it, plus `canary/`,
  `beh_verilog/`, `rtlil/`, `conformance/` (ledgers, baselines, registries)
  and `external/`; `tests/README.md` lists the suites.
- `tools/`: one file per script (`conformance.py` owns `run`'s evidence
  accounting and its selftests, `report.py`, `doctest.py`, the three
  `external_*.py` runners, `update-sources.py`) and `zrunner.zig`.
- A module imports `lib/` freely and `src/` never imports a module above it in
  `build.zig`'s `module_specs`; `lib/` imports nothing from `src/`.
