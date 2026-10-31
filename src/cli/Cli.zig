//! `vera`'s command line as typed (`args.parse` fills it, `args.resolve`
//! settles it). Every slice borrows from the argv iterator, which must
//! outlive this value; the lists are owned and freed by `deinit`. A later
//! flag of the same kind overwrites an earlier one except where a field says
//! otherwise.
//!
//! Cites: LRM 3.4 (`overrides`), annex C (`sim`), IEEE 1364-2005 §13.2,
//! §13.7.1, §15.5.4, §28 (the `.v` fields).
//!
//! Contents:
//! - fields, one per flag (see `cli/usage.zig`)
//! - `pub fn deinit(cli: *Cli, gpa: Allocator) void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const vera = @import("vera");
const diag = vera.diag;
const Display = vera.Display;
const zigbuild = @import("zigbuild");
const digital = @import("sim").digital;
const native = @import("digital");
/// `-Dlanguage=ams`: a 1364-only vera defaults to IEEE 1364-2005.
const ams = @import("build_options").ams;

levels: diag.Levels = .empty,
/// `-I`, in order.
include_dirs: std.ArrayList([]const u8) = .empty,
/// `-D`, in order, each `NAME` or `NAME=TEXT` as typed.
defines: std.ArrayList([]const u8) = .empty,
/// `--param`, in order: each keeps its text (a string parameter's value)
/// beside the number, NaN when the text is not one.
overrides: std.ArrayList(vera.ParamOverride) = .empty,
/// The input files; `paths[0]` is the one compiled, the rest are `.v`
/// library units.
paths: std.ArrayList([]const u8) = .empty,
libmaps: std.ArrayList([]const u8) = .empty,
/// `-L`, in order.
search: std.ArrayList([]const u8) = .empty,
emit_zig: bool = false,
json: bool = false,
color: enum { auto, always, never } = .auto,
unknown_bound: ?f64 = null,
discipline_resolution: vera.DisciplineResolution = .basic,
std_defs: bool = true,
language: vera.KeywordSet = if (ams) .vams_2023 else .v1364_2005,
/// `--sim=`: the language family. `.verilog` is a `.v` design under a
/// 1364 keyword set; `.verilog_a` annex C's subset of a `.va` (E0250).
sim: vera.Sim = if (ams) .verilog_ams else .verilog,
/// `--sim=` and `--std=` as typed, for `resolve`'s conflict.
sim_flag: ?[]const u8 = null,
std_flag: ?[]const u8 = null,
out_path: ?[]const u8 = null,
expect_module: ?[]const u8 = null,
/// `--emit-verilog`; `-o` then names the Verilog file.
emit_verilog: bool = false,
/// `--emit-rtlil`: a `.v` design as Yosys RTLIL; `-o` then names the file.
emit_rtlil: bool = false,
/// `--digital-pins`, unparsed: a list or a file (the spine reads it).
digital_pins: ?[]const u8 = null,
power_pins: bool = false,
vdd: f64 = 1.8,
check: bool = false,
validate_contract: bool = false,
emit_so: bool = false,
/// `--emit-osdi`; `emit_so` is set too, and `-o` names the `.osdi`.
emit_osdi: bool = false,
/// `--emit-zig` typed, as opposed to implied by `-o`.
emit_zig_typed: bool = false,
/// `--run`; `exe_flag` is set too.
run_exe: bool = false,
display: Display = .record,
jac_f32: bool = false,
jac_f32_host: bool = false,
// What the user typed, kept apart from the derived state above so
// conflicting flags are refused by name after the loop, whatever their
// order.
lint_flag: bool = false,
/// `--elab`: a `.v` design elaborated, not run.
elab: bool = false,
/// `--lsp`: serve, and take no input file.
lsp: bool = false,
/// The last `--display=` typed. `.drop` conflicts with a testbench, and
/// `.record` makes one print what the device's `say` records instead of
/// printing in the device.
display_flag: ?Display = null,
/// The last flag that implies codegen.
codegen_flag: ?[]const u8 = null,
/// `--emit-exe` or `--run`, whichever was typed last.
exe_flag: ?[]const u8 = null,
/// `--contract`; `main` fills in this vera's own when it needs one.
contract_path: ?[]const u8 = null,
dyn_path: ?[]const u8 = null,
work_dir: ?[]const u8 = null,
zig_exe: []const u8 = "zig",
debug_info: bool = false,
/// Null: Debug for a testbench, ReleaseFast otherwise (`main`).
optimize: ?std.lang.Optimize = null,
/// Null: `Backend.auto`.
zig_backend: ?zigbuild.Backend = null,
spice_path: ?[]const u8 = null,
/// `--protect-keys`: the key file for IEEE 1364-2005 §28 decryption
/// envelopes (`frontend.protect.parseKeys`).
protect_keys: ?[]const u8 = null,
schedule: native.Schedule = .static,
event_budget: u64 = digital.max_events_per_tick,
logic: native.Logic = .auto,
/// `--state=` or `--two-state`, whichever was typed last.
logic_flag: ?[]const u8 = null,
/// `--negative-timing`: IEEE 1364-2005 §15.5.4's invocation option.
negative_timing: bool = false,

const Cli = @This();

/// Frees the lists; `gpa` is the one `parse` was given.
pub fn deinit(cli: *Cli, gpa: Allocator) void {
    cli.include_dirs.deinit(gpa);
    cli.defines.deinit(gpa);
    cli.overrides.deinit(gpa);
    cli.paths.deinit(gpa);
    cli.libmaps.deinit(gpa);
    cli.search.deinit(gpa);
    cli.* = undefined;
}
