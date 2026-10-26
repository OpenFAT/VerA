# Changelog

## Unreleased

- **Operating-point variables:** a device whose module-scope variables carry
  a `desc` (OSDI's opvars, LRM §3.2.1's output variables) declares
  `op_vars`, their names, and `opVars(S, x, ...)`, their values when the
  analog block runs at `x`, read off a slice of the core as `noisePsd` is
  (OmarSiwy/ESPice#236). Not yet in `--emit-osdi`.

## v0.20.0 — 2026-10-25

On Suite VAMS-CONFORMANCE, we score Verilog-A 2452/2452, Verilog 3611/3611, Verilog-AMS 754/754, Cumulative: 6817/6817.

- **No expected failures.** Every Verilog-A, Verilog and Verilog-AMS test in
  the VAMS Conformance Suite passes: `tools/vera.xfail` and the suite's
  `vera/xfail` are empty. Where a test expected what the LRM forbids, the
  suite now expects a refusal citing the clause
  (OmarSiwy/VAMS-Conformance-Suite#1); VerA accepts nothing the LRM forbids.
- **Output to a file is no longer overwritten.** `vera`, the `.v` runtime and
  the VPI host wrote stdout and stderr at fixed offsets, so a warning printed
  after a testbench ran overwrote its output when both went to one file.
  They stream now; a test checks that output to a file equals output to a
  pipe.
- **`vera --run`** honours `//! spice`, `//! discipline-resolution` and
  `//! plusargs`, as the fixture runner did.
- **New options:** `-D NAME[=TEXT]` defines a macro for a Verilog-A/AMS
  source; `--elab` elaborates a `.v` design and runs nothing;
  `--protect-keys FILE` decrypts IEEE 1364 §28 envelopes (VD-127).
- **VPI:** `zig build install` ships `lib/libvera-vpi.a` and
  `include/vpi_user.h`; a C application links them and runs on its design.
  `vpiIsProtected` is TRUE for what a decrypted envelope declares (§26.3.5).
- **Preprocessor:** `` `" `` and `` `\`" `` macro stringification (IEEE 1800
  §22.5.1) under every standard, with W0151 under 1364; `pragma protect`
  metadata; `expm1`/`ln1p` are identifiers before VAMS-2023; an undefined
  macro stays an error (VD-126).
- **Analog:** an access name two disciplines bind resolves on the net's
  discipline, not on declaration order; `cross`/`last_crossing` take a
  run-time direction; a string output formal starts at `""`; analog operators
  check their argument count; a discipline naming an undeclared nature is
  E0378; a continuous assignment may drive an output port with no net type.
- **Paramset ranges** are checked at the declaration (E0347), not only when an
  instance selects the paramset.
- **Digital simulation:**
  - A net behind a delayed driver reads x until its first update (VD-128).
  - `$sdf_annotate` reads SDF 3.0; specify-block pulse limits filter pulses.
  - `%x`, `%t` at any width, `%s` with zero bytes (VD-129) and `$fscanf`
    follow iverilog where the LRM is silent.
  - Time-0 process order follows iverilog (VD-081).
  - A zero-delay `always` runs until the per-time-step event budget ends it
    (VD-133).
  - A failed `$readmem` load is warning W1157 and the run goes on (VD-134).
  - `$finish` ends the run once its time step has drained: other processes,
    nonblocking updates and `$monitor` still run in that step (§17.4.1, as
    iverilog reads it).
  - Task and function names are searched in enclosing instances (§12.7).
  - A MOS switch whose data input is an undriven supply net, a `%d` of a real
    above 2^63, and a vector wider than 64 bits converted to real gave wrong
    values; they are fixed.
- **A SPICE deck scores as SPICE**, not Verilog-AMS, wherever it is filed.
- **Tests:** VPI runs and the file-kernel test no longer share fixed file
  names in `.zig-cache`, which raced between worktrees.

## v0.15.0 — 2026-10-24

On Suite VAMS-CONFORMANCE, we score Verilog-A 1844/2466, Verilog 3106/3607, Verilog-AMS 521/744, Cumulative: 5471/6817.

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
