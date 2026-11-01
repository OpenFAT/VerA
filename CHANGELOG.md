# Changelog

## Unreleased

## v0.21.0 — 2026-11-01

On Suite VAMS-CONFORMANCE, we score Verilog-A 2448/2452, Verilog 3611/3611, Verilog-AMS 746/754, Cumulative: 6805/6817.

- **`-D NAME[=TEXT]` reaches a `.v` design** under `--run`, `--elab`,
  `--emit-rtlil`, `--emit-exe` (the interpreted executable keeps them) and
  the contract device; it was refused.
- **The conformance suite is tool-neutral**: VerA runs it through its
  `conform` harness like any other tool (`zig build conformance`,
  `tools/vera.xfail`). VerA's own test inputs moved from the suite's `vera/`
  into `tests/` (`host/`, `canary/`, `rtlil/`, `beh_verilog/`, `osdi/`, and
  `suite.xfail`). The ledgers and clause tables are gone, and with them
  `conformance.py run` and its ratchet, metric, steps, grammar, mutate,
  adversarial, verilator, icarus, comments, lint-cites and ledger-apply
  subcommands, `suite -- ieee1364 --coverage`, the suite's `--verdicts` and
  `--list`, the diagnostic-citation unit test, the external QA suites
  (va-models, cmcqa, hicum-qa, xyce) and the VAMPyRE run.
- **Operating-point variables:** a device whose module-scope variables carry
  a `desc` or `units` (LRM §3.2.1's output variables) declares
  `op_vars`, their names, and `opVars(S, x, ...)`, their values when the
  analog block runs at `x`, read off a slice of the core as `noisePsd` is
  (OpenFAT/EGSpice#236). Not yet in `--emit-osdi`.
- **`--run` accepts the conformance harness's `//! stdout`, `//! expect`,
  `//! diagnostic` and `//! exit any` lines** instead of refusing them as an
  unknown directive; the harness reads them, `--run` drops them. Seven ch09
  report tests ran into it. `//! lrm-reject` and `//! inherited-reject` are
  checked as `lrm` and `inherited` are.
- **The VPI analog host runs a mixed-signal design** (VAMS §8.4): its
  digital half is elaborated beside the analog library and stepped by the
  mixed kernel, VPI reads its variables, and a tentative solution an
  application rejects through acbConvergenceTest is solved again halfway
  back, so a `cross` or `absdelta` event of the rejected solution is never
  delivered (§8.4.7). A design whose analog block reads a digital value, or
  with an explicit D2A event, a connect module or a digital read of an analog
  variable, is refused by name (`reject_step_cross_event.c`,
  `reject_step_absdelta_events.c`).
- **The analog block reads an element of a digital array** (§7.3.1 Table
  7-1, `reg [0:9] r[0:7]`): each element of a one-dimensional array the
  digital context owns is its own host-set input, read at a constant index
  or selected at a run-time one. Was E0309 (`clog2_reg_analog_conversion.va`).
- **`--negative-timing`**, IEEE 1364-2005 §15.5.4's option: `$setuphold`
  and `$recrem` take negative limits. Each instance's signals get the least
  delays that keep every adjusted limit a tick or more (§15.5.1), the
  checks see their changes that much later, and so their notifiers toggle
  at the delayed detection (§15.5.3); limits no delays can meet zero the
  most negative one (W1162). Off, a negative limit is still 0
  (`negative_setuphold_window_shifts.v`, `negative_recrem_window_shifts.v`,
  `negative_timing_notifier_toggles_at_delayed_detection.v`).
- **The flow into an instance's port is read exactly** (§5.4.3, §3.12.1,
  §6.7.1): a port whose flow the instance itself reads (`I(<a>)`, `I(pb)`),
  or the module instantiating it reads (`I(<u.a>)`, `I(u.branch(<a>))`),
  keeps a net of its own hung from the connected net by a flow probe, so the
  read is that probe's current, through a potential source too. Was E0997
  (`port_access_own_port_inside_instance.va`,
  `port_branch_own_port_inside_instance.va`,
  `port_access_hierarchical_potential_source.va`).
- **A named block's local hides the module's variable of that name** in
  the checks that run before lowering (IEEE 1364-2005 §12.6): an analog
  `begin : b integer value; value = ...; end` beside a digital `reg value`
  is neither E0432 (assigned in both contexts) nor E0316
  (`clog2_reg_analog_conversion.va`).
- **`$simprobe` takes a name known only at run time** (§9.16: "or a string
  variable"): the probe compares it with every sibling parameter or output
  variable it could name and returns the fallback when none matches. With
  no fallback such a probe is still E0823 (VD-030)
  (`simprobe_runtime_name_resolves.va`).
- **A protected envelope's `digest_decrypt_key` is read** (IEEE 1364-2005
  §28.4.20): the digest key and method come from the key_block's cleartext,
  and each `digest_block` checks the key_block or data_block just before it
  (§28.4.22.2), not always the data (`protected_digest_decrypt_key.v`).
- **An analog assignment to a `reg` is refused** (E0316, §5.7: the
  left-hand side "shall be ... an integer, real, or string identifier or an
  element of an integer, real or string array"), of any width and for a
  bit or part of one. This revises VD-116, which sized such an assignment
  to a `reg` wider than 32 bits; `wide_host` and `wide_gpu` go with it
  (`analog_assignment_to_reg_vector_rejected.va`).
- **The VPI analog host places a time point at each timer instant**
  (§5.10.3.3), as `--run` does, instead of stepping on its fixed grid past
  it: the library exports `vera_vpi_breakpoint`
  (`reject_step_table_capture.c`, `reject_step_held_sformat_string.c`).
- **A protected model that needs a license is refused** (E0146,
  IEEE 1364-2005 §28.4.28.2/§28.4.29.2): VerA loads no license library, so
  a `decrypt_license` or `runtime_license` pragma in the cleartext means
  it is not licensed. Before, VerA decrypted and ran the model anyway.
- **A terminated `$readmem` load fires VPI's `cbError`** (VAMS 12.31.4,
  IEEE 1364-2005 §17.2.9 "an error message is issued"), with
  `vpi_chk_error` reporting it inside the callback; the run still goes on
  (VD-134). The VPI host now prints the warnings a run survives, W1157
  among them (`cb_error_chk_error.c`).
- **`//! print none` leaves only the model's own output**: the title, each
  point's `--- point N ---` header with its bias and `t`/`dt`, and the
  reject and crossing notes go too, so a report test such as
  `info_in_transient_reports_time.va` sees only what the model printed.
  The gates' `FAIL` lines and `next_bp` stay.
- **`$fatal` runs on every Newton iterate** (§9.7.3: it "terminates the
  simulation without checking whether the iteration would be rejected"),
  not only at the accepted point; a `$fatal` with no `$debug` or `$fdebug`
  beside it was skipped on a vetoed iterate
  (`fatal_on_vetoed_iterate_terminates.va`).
- **The nix package's analog VPI apps no longer segfault.** The sandbox has
  no `/usr/bin/env`, so Zig built `libvera-vpi.a` for static musl, where
  `std.DynLib` is `ElfDynLib`: it applies no relocations, and
  `vera_vpi_open` stored through an unrelocated pointer (33 suite tests).
  `flake.nix` now names the glibc target, and `src/dynlib.zig` refuses to
  compile on Linux without glibc.
- **Installing without Nix:** `tools/install.sh` installs a release from
  `sources.json` on Linux and macOS, checks the tarball's sha256, caches it
  and keeps versions side by side. Each release also ships a `.deb`, an
  `.rpm` and an Arch package (each installed and run by its own package
  manager before upload), the AUR `PKGBUILD` (`vera-bin`) and a Homebrew
  formula; the AUR and the `OmarSiwy/homebrew-vera` tap are updated when
  their secrets are set.

- **The device contract is a directory** (#98): `lib/contract.zig` is a
  root importing `lib/contract/`, one transformation per file. A host that
  copies the single file must ship `share/vera/contract/` beside it; the
  ABI, `SimState` and every public name are unchanged. The flake, AUR,
  Homebrew, `.deb`/`.rpm` and `tools/install.sh` install the tree.
- **`%e` with a precision of 59 or more prints the number** instead of `?`,
  and **`acosh(x)` for x ≤ -2 is NaN** (C99), not a finite value (#98).
- **Every module is rewritten** to one transformation per file, with typed
  handles, named error sets, bounded loops and asserted contracts (#95-#113).
  On the 23121 golden files, the only differences are the kernel text each
  device embeds (now its kernel files' own bytes), the ten kernel helpers a
  split device no longer re-exports, and the runner text that names the
  regrouped digital `Run`.
- **`--emit-rtlil` refusals are coded** (E1200-E1278, one per construct, at
  its line), and four fixtures that panicked emit RTLIL or a refusal: null
  ports, a connection to no port (E1100), a range past RTLIL's 32-bit offset,
  and a port-header select, which was emitted full width (#113, #114).
  Constants fold by IEEE 1364-2005 rules (`HI-7` was folded to -8), an
  ascending range's offset is its lower bound, and an escaped name keeps its
  `.` and `\`.
- **Inputs that aborted `vera` are refused or accepted**: `vera ""`, an empty
  path to `--spice`/`--protect-keys`/`--digital-pins`, a defparam through an
  escaped name holding `[` or `.` (`\a__g[1]__in1`), a display-only device's
  noise and AC tables, `ac_stim` with four arguments (E0506), a NaN noise-table
  knot, and a 5000-statement chain, 5000-arm `case` or 5000-deep else-if or
  `begin` nest on a 1 MiB thread (#114).
- **Device codegen is linear on long select chains**: a 5000-arm `case` takes
  2.05 s in Debug, from 68.2 s (#114).
- **VPI**: the analog library's runner reports the device's `mem_bytes` as
  `--emit-exe` does (it said 0); ports answer `vpiLowConn` and `vpiHighConn`;
  `vpiName` keeps a `.` inside an escaped name; a derivtf with NULL partials
  (BADPARTIALS), a callback with no context (NOCTX), a non-`$` call name and a
  zero-length transient window are refused (#114).
- **E0154**: more than 65535 source files through an include tree is a coded
  error, not a crash; a design nested past the reserved stack while
  elaborating is E0241 (#114).
- **`--emit-exe`** refuses a negative `//! time`, a time at or past 2^64
  ticks, more than 64 explicit D2A event ports (E0437, which the emitted Zig
  failed to compile) and `//! checks N` past 2^32-1 (#108, #114).
- **A cached `--emit-osdi` or `--emit-so` rebuilds when a file of its module
  changes**: the artifact key hashed only the root file (#100).
- **The suite compares names, never counts**: `suite -- ams` printed its first
  FAIL lines under zig build's summary, where they were lost; it now prints
  its FAIL and XFAIL names after the summary and holds them to
  `tests/suite.xfail`. A skipped test fails, and the suite's work directories
  moved out of the shared `.zig-cache` to `.vera-work/` (#101, #114).
- **New oracles under `zig build test`**: a degenerate-argv table, wide-input
  and escaped-identifier generators through every pass, a VPI negative-input
  table, an `--emit-so` golden with VPI contributions, `--emit-verilog` and
  `--emit-rtlil` goldens, a compile of every runner template and an assembly
  probe of the branchless limit kernels (#114).
- **Twelve conformance fixtures are expected failures** (`tools/vera.xfail`):
  they still expect what this release's own changes above revise (an analog
  assignment to a `reg` is E0316, an instance port's flow is read exactly, a
  run-time `$simprobe` name is accepted). The suite's fixtures follow in
  OpenFAT/VAMS-Conformance-Suite.

## v0.20.0 — 2026-10-25

On Suite VAMS-CONFORMANCE, we score Verilog-A 2452/2452, Verilog 3611/3611, Verilog-AMS 754/754, Cumulative: 6817/6817.

- **No expected failures.** Every Verilog-A, Verilog and Verilog-AMS test in
  the VAMS Conformance Suite passes: `tools/vera.xfail` and the suite's
  `vera/xfail` are empty. Where a test expected what the LRM forbids, the
  suite now expects a refusal citing the clause
  (OpenFAT/VAMS-Conformance-Suite#1); VerA accepts nothing the LRM forbids.
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
