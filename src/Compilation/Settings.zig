//! The settings of one analysis (`Compilation.analyze`): what the command
//! line or a library caller decides about a source before it is read. A
//! plain value; every slice is borrowed and must outlive the call it is
//! passed to (and, for `lint`, the bag that call fills).
//!
//! Cites: §3.4 (`param_overrides`), §3.6.2 (`std_defs`), §7.4.4
//! (`discipline_resolution`), §9.4 (`display`), §10 (`defines`,
//! `include_dirs`), §12.32.1 (`int_systfs`), annex C (`sim`), annex E.2
//! (`spice_netlist`), A.1.2 (`empty_unit_ok`).
//!
//! Contents (fields, each with a default):
//! - `file_name: []const u8`, `include_dirs: []const []const u8`,
//!   `defines: []const []const u8`, `std_defs: bool`,
//!   `require_std_includes: bool`, `language: KeywordSet`, `sim: Sim`
//! - `param_overrides: []const ParamOverride`,
//!   `discipline_resolution: DisciplineResolution`, `empty_unit_ok: bool`
//! - `spice_netlist: []const u8`, `spice_path: []const u8`
//! - `lint: diag.Levels`, `proof: proof.Options`, `display: Display`,
//!   `int_systfs: []const []const u8`

const diag = @import("diag");
const token = @import("frontend").token;
const prove = @import("prove");
const Display = @import("device").codegen.Display;
const ParamOverride = @import("analog").Lower.ParamOverride;
const DisciplineResolution = @import("elab").Elaborate.DisciplineResolution;

/// The name diagnostics print for the top-level source.
file_name: []const u8 = "<source>",
/// Searched in order for an `include, ahead of the built-in annex D files;
/// also where a §9.21.1 `$table_model` data file is found.
include_dirs: []const []const u8 = &.{},
/// `vera -D`: `NAME` or `NAME=TEXT` macros, defined before the source.
defines: []const []const u8 = &.{},
/// Prepends annex D.2 constants.vams and annex D.1 disciplines.vams
/// (§3.6.2). The Table E.1 primitives are prepended either way (annex E.2).
std_defs: bool = true,
/// The source must `include the annex D files it uses: a D.2 macro without
/// constants.vams is E0115, a D.1 discipline without disciplines.vams is
/// E0371. `vera` sets it in every mode, as does the fixture harness; a
/// library caller compiling text it generated keeps the implicit prelude.
require_std_includes: bool = false,
/// The keyword set, `vera --std=`.
language: token.KeywordSet = token.default_keyword_set,
/// `vera --sim=`: all of Verilog-AMS, or annex C's Verilog-A subset, in
/// which a digital or mixed-signal construct is E0250. `.verilog` never
/// reaches the analysis: a `.v` design goes through `sim.digital`.
sim: token.Sim = .verilog_ams,
/// §3.4 compile-time values for the top module's parameters (`--param`).
/// A shape parameter is compiled to its value and its card may not move
/// it; any other stays a run-time card value whose default this replaces.
param_overrides: []const ParamOverride = &.{},
/// §7.4.4 basic or detail discipline resolution.
discipline_resolution: DisciplineResolution = .basic,
/// A source with no module of its own to elaborate (A.1.2's `source_text`
/// of only connect modules, UDPs, disciplines, pragmas, or nothing) is
/// `error.NothingToElaborate` instead of E1001. A check that builds nothing
/// sets it; a request for a device has none to build (§6.2).
empty_unit_ok: bool = false,
/// Annex E.2 SPICE netlist text whose `.MODEL` and `.SUBCKT` cards the
/// source may instantiate. One card per line, `+` continuations included.
spice_netlist: []const u8 = "",
/// The file `spice_netlist` came from, so its `.INCLUDE`, `.LIB` and `.HDL`
/// cards find files beside it; "" resolves them against the working directory.
spice_path: []const u8 = "",
/// Per-code lint levels (`--allow=W0650`, `--deny=W0651`). Borrowed: the
/// bag the analysis fills reads it until that bag is freed.
lint: diag.Levels = .empty,
/// Class-6 knobs (the solver's compliance bound).
proof: prove.proof.Options = .{},
/// What becomes of the model's display tasks (§9.4): `.record` keeps them
/// for the host (`say`), `.drop` removes them, `.emit` prints them in a
/// testbench. Decided here, not at codegen, because lowering keeps or drops
/// what a card could observe, and W0850 names each task a device drops.
display: Display = .drop,
/// §12.32.1 the user analog system functions registered with sysfunctype
/// vpiIntFunc: a call to one returns an integer. With none, every
/// unresolved `$name` returns a real.
int_systfs: []const []const u8 = &.{},
