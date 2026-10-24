# Changelog

## Unreleased

## v0.13.0 — 2026-10-23

- **`vera.wasm`**: `zig build -Dtarget=wasm32-wasi` builds VerA as
  WebAssembly, and each release ships `vera-<tag>.wasm`. Checking, linting
  and every `--emit-*` that writes text run in a browser or any WASI host;
  modes that run `zig` (`--run`, `--emit-so`, `--emit-exe`) do not.
- **Noise and `ac_stim` in a potential contribution** are sources in series
  with the branch (§4.6.4.1), on its branch current. They were placed as a
  current between the branch's nodes, a thousandfold error.
- **A module that instantiates itself** without a terminating generate
  (IEEE 1364 §12.1.3) is refused at 256 levels or 2^18 instances instead of
  elaborating without end.
- **Testbenches drive one device.** The `//! tran` and `//! onoise`
  directives are gone; a circuit is a SPICE deck run by ESPice.
- **Device layout** (host-facing):
  - The §9.19 given flags are one bitset, `Model.given__`: set one with
    `model.setGiven(name)`; the `<name>__given` fields are gone.
  - `Setup` copies the card values `eval` reads, so call `setup` before
    `say` as before `eval`. `Setup.b` is a `std.StaticBitSet`.
  - An `integer` parameter that only the card writes gets the narrowest of
    i8/u8/i16/u16 its range allows; write it with a checked cast.
  - `Instance.systf` exists only in a device that declares `systf_calls`.
- An `absdelay` history on a GPU thins silently; W1051 is host-only.
- **`zig build test-spice -Despice=PATH`** runs the `.sp` decks on an ESPice
  release, CPU or GPU, and grades its CSV against each deck's oracle. VerA
  does not depend on ESPice: `build.zig.zon` has no dependencies, and
  nothing in the merge gate fetches or builds ESPice. `lib/sim/spice/`, the in-tree copy of its solver, is
  gone.
- **The fixtures live in the VAMS Conformance Suite** (`tests/conformance`,
  a submodule: `git submodule update --init tests/conformance` after
  cloning), by language and chapter under its `tests/`; what only VerA uses
  is its `vera/`. `zig build conformance` runs the suite's own `conform`
  harness against this build, with the known failures in `tools/vera.xfail`.
  Fixtures compile with no prelude: a source includes `disciplines.vams`
  itself (or `check.vh`, which does), and E0371 names a missing include.
- `--param` sets a string parameter and reaches a `.v` design's top-level
  parameters (a misspelt name is refused); `-v` and `-V` print the version;
  the VS Code extension colors comments and strings.

## v0.12.1 — 2026-10-22

- Building from source needs Zig 0.18.0-dev.349+d924f83bf
  (`minimum_zig_version`); the flake pins it. Auto-Vectorized LLVM is on :)

## v0.12.0 — 2026-10-22

- **`--sim=verilogAMS|verilogA|verilog`** picks the language family.
  `verilogA` is annex C's subset (a digital or mixed-signal construct is
  E0250); `verilog` is IEEE 1364-2005 alone and refuses a `.va` model.
- **`--emit-rtlil`** writes a `.v` design as Yosys RTLIL for synthesis; a
  construct outside the synthesizable subset is refused by name and line.
- **Timing checks** (§15.3): `$skew`, `$timeskew`, `$fullskew` and
  `$nochange` are evaluated (were E1149). A negative `$setuphold`/`$recrem`
  limit is 0, with the delayed signals as copies (§15.5.4).
- **VPI**: an instance's `vpiLineNo` is its instantiation line;
  `vpi_handle_by_index` on a net returns its `vpiNetBit`;
  `vpi_iterate(vpiPort, net)` of an internal net is empty, not an error.
- **`$finish`/`$info`** (§9.7) report the time, or the dc sweep variable and
  value; `$finish(2)` adds memory and CPU use.
- **Nested module definitions** (§6.2.2) are one E0240; the outer module no
  longer ends early.
- The manual documents the predefined `__VERA__` macro (§10.5).
- Fixes: integer/real default initialization, size truncation, zero
  replication, derived natures and domainless disciplines,
  `default_discipline` qualifiers and primitive bridges, runtime `case`
  items, `cross` tolerances and event lists, timing checks in a
  mixed-signal design's digital half, hierarchical analog probes read from
  digital.

## v0.11.5 — 2026-10-20

- Known bug: duplicate or inconsistent non-ANSI task-port declarations are
  not diagnosed.

[Earlier releases](docs/CHANGELOG-HISTORY.md).
