//! `vera`'s argv -> one `Cli` value: what the user typed, flag by flag, in
//! order. `--help`, `--version` and `--explain` answer here; a malformed flag is refused
//! here with exit status 2. Conflicts between well-formed flags are refused
//! after the whole line is read, by `resolve`, whatever their order.
//!
//! The flags, their spelling and every message below are user-visible and
//! frozen. Clauses: LRM 3.4 (`--param`), Annex E.2 (`--spice`), IEEE 1364-2005
//! §13.2 and §13.7.1 (`--libmap`, `-L`).

const std = @import("std");
/// `-Dlanguage=ams`. When false this is an IEEE 1364-2005 tool and the analog
/// backend is comptime-dead.
const ams = @import("build_options").ams;
const vera = @import("vera");
const digital = @import("sim").digital;
/// The native emitter (src/codegen/digital/): `--schedule=` and `--state=`.
const native = @import("digital");
/// The VerA release: what `--version` prints and every device it generates
/// carries (`contract.vera_version`).
const vera_version = @import("contract").vera_version;
const diag = vera.diag;
const Io = std.Io;

/// `--optimize=` names. Zig 0.17 renamed `std.lang.Optimize`'s tags
/// (`fast`, ...); the flag keeps the names it always took.
const optimize_names = std.StaticStringMap(std.lang.Optimize).initComptime(.{
    .{ "Debug", .debug },
    .{ "ReleaseSafe", .safe },
    .{ "ReleaseFast", .fast },
    .{ "ReleaseSmall", .small },
});

/// `--help`, and what a command line naming no input prints to stderr.
pub const usage_text =
    \\usage: vera [options] FILE.va
    \\       vera --run|--emit-exe [options] FILE.v [MORE.v ...]
    \\       vera --emit-zig|--check|--emit-so|--emit-osdi|--emit-rtlil [options] FILE.v [MORE.v ...]
    \\       vera --explain CODE
    \\       vera --version | -v | -V
    \\       vera --lsp [options]
    \\
    \\  --lint                  frontend only (parse, lower, prove); no codegen
    \\  --lsp                   a language server on stdin/stdout: --lint's
    \\                          diagnostics and fix-its for each open document;
    \\                          the options here, then the workspace's .vera-flags
    \\  --emit-zig              generate the device; to stdout unless -o is given
    \\  -o PATH                 write the generated device.zig here
    \\  --expect-module=NAME    fail unless the compiled module is called NAME
    \\  --emit-verilog          a behavioural Verilog module of the .va for digital
    \\                          simulation (same name and ports; -o PATH, else stdout)
    \\  --digital-pins LIST|FILE   ports that are logic: a comma/space-separated
    \\                          list, or a file of names (also `(* vera_pin *)`)
    \\  --power-pins            --emit-verilog: supply pins only under
    \\                          `ifdef USE_POWER_PINS
    \\  --vdd=X                 --emit-verilog: logic-high potential in V (default 1.8)
    \\  --emit-rtlil            a .v design as Yosys RTLIL, for synthesis (-o PATH,
    \\                          else stdout); a construct outside the synthesizable
    \\                          subset is refused by name
    \\  --check                 type-check the generated device with zig, running
    \\                          the contract's conformance checks
    \\  --emit-so               build lib<name>.<gen>.so via the orchestrator
    \\  --emit-osdi             build an OSDI 0.4 library (ngspice `pre_osdi`) of a
    \\                          .va or .v: --emit-so under this vera's osdi_dyn.zig,
    \\                          copied to -o PATH (default <module>.osdi); print it
    \\  --emit-exe              build a runnable Verilog-A testbench,
    \\                          or a .v design's executable; print its path
    \\                          (--emit-zig, --check, --emit-so and --emit-osdi of
    \\                          a .v build its top module as a contract device,
    \\                          4-state, E1103)
    \\  --schedule=static|fifo  a .v executable's order of same-time events:
    \\                          combinational logic levelized (static, the
    \\                          default; IEEE 1364 §11.4.1), or the interpreter's
    \\  --state=auto|2|4        a .v executable's logic: 4-state until no live x
    \\                          or z is left, then 2-state, printing what 4-state
    \\                          prints (auto, the default); every x or z is 0,
    \\                          NOT IEEE 1364 4-state logic (2, E1101); 4-state
    \\  --two-state             --state=2
    \\  --event-budget=N        a .v design's events at one time step before a
    \\                          zero-delay loop is refused (default 10000000)
    \\  --run                   run a .v initial-process program, or an analog testbench
    \\  --libmap FILE           read an IEEE 1364 §13.2 library map (repeatable, read
    \\                          in order); each .v file compiles into the library
    \\                          whose file_path_spec matches it, else `work`
    \\  -L LIB                  search LIB for an instance's cell (repeatable, in
    \\                          order; IEEE 1364 §13.7.1); default: map order, then work
    \\  --display=record|drop|emit
    \\                          ch9 display tasks: recorded by the device's `say`
    \\                          for its host to print (default), void, or
    \\                          printed (--emit-exe's default; with record the
    \\                          testbench prints the device's records)
    \\  --jac-f32               mark the device as tolerating an f32 Jacobian
    \\  --jac-f32-host          ...and ask the host to use it on its CPU path
    \\  --validate-contract     run the contract's conformance checks (validate,
    \\                          validateHost, checkFamily, Debug su_ok) in the
    \\                          --emit-exe/--run testbench; off by default. A host
    \\                          gets them only by opting in: `pub const
    \\                          vera_validate_contract = true` in its root module
    \\                          (--emit-so: in the --dyn module). The version check
    \\                          (`vera_version`) is always on
    \\  --contract PATH         root of the `contract` module (default: this vera's
    \\                          own, written under the work directory)
    \\  --dyn PATH              root of the `dyn` module (--emit-so)
    \\  --work-dir DIR          scratch + artifact directory (--emit-so)
    \\  --zig PATH              zig executable to drive (default: zig)
    \\  --optimize=MODE         Debug|ReleaseSafe|ReleaseFast|ReleaseSmall (default: exe Debug, so ReleaseFast)
    \\  --zig-backend=auto|llvm|native   auto: native for Debug on x86_64, else llvm
    \\  --debug-info            keep DWARF in a ReleaseFast/ReleaseSmall --emit-so or
    \\                          --emit-exe artifact (default: stripped; same machine
    \\                          code, about half the LLVM time of a large device)
    \\  -I DIR                  add an `include search directory
    \\  --param NAME=VALUE      compile with the top module's parameter NAME set
    \\                          to VALUE (LRM 3.4): a number, or a string parameter's
    \\                          text (`--param mode=fast`). A parameter that sizes an
    \\                          array, vector or replication, or bounds a genvar
    \\                          loop or selects a generate arm, is fixed at VALUE and
    \\                          the device refuses a card that moves it
    \\                          (`checkShape`); any other stays a card value
    \\  --spice PATH            read a SPICE netlist alongside the source; Annex
    \\                          E.2's .MODEL and .SUBCKT cards in it become
    \\                          module definitions the .va can instantiate
    \\  --no-std-defs           do not prepend the annex D prelude
    \\  --std=SPEC              source language, a `begin_keywords specifier:
    \\                          1364-1995|1364-2001|1364-2005|VAMS-2023
    \\                          (default; 1364-2005 under -Dlanguage=verilog).
    \\                          A 1364 language frees every AMS keyword as an
    \\                          identifier and refuses AMS constructs (E0242)
    \\  --sim=verilogAMS|verilogA|verilog
    \\                          the language family: all of Verilog-AMS (the
    \\                          default), annex C's Verilog-A subset (a digital
    \\                          or mixed-signal construct is E0250; no .v), or
    \\                          IEEE 1364-2005 alone (--std=1364-2005 unless
    \\                          --std names another 1364 set; no .va)
    \\  --diagnostics=text|json how to report (default: text)
    \\  --color=auto|always|never
    \\  --allow/--warn/--deny/--forbid=CODE   per-code lint level
    \\  --unknown-bound=X       solver compliance limit (see --explain W0650)
    \\  --discipline-resolution=basic|detail
    \\                          LRM 7.4.4's mode for undeclared interconnect
    \\                          (default: basic; detail is Annex F.2.2)
    \\
;

/// One command line, as typed. Every slice borrows from the argv iterator,
/// which must outlive this value; the lists and `levels` are owned and freed
/// by `deinit`. A later flag of the same kind overwrites an earlier one
/// except where a field says otherwise.
pub const Cli = struct {
    levels: diag.Levels = .empty,
    /// `-I`, in order.
    include_dirs: std.ArrayList([]const u8) = .empty,
    /// `--param`, in order. `main` appends the testbench's shape cards after
    /// these, so only `[0..n_typed]` of it is what was typed.
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
    /// `--digital-pins`, unparsed: a list or a file (`main` reads it).
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
    display: vera.codegen.Display = .record,
    jac_f32: bool = false,
    jac_f32_host: bool = false,
    // What the user typed, kept apart from the derived state above so
    // conflicting flags are refused by name after the loop, whatever their
    // order.
    lint_flag: bool = false,
    /// `--lsp`: serve, and take no input file.
    lsp: bool = false,
    display_drop_flag: bool = false,
    /// `--display=record`: with `--emit-exe`, the testbench prints what the
    /// device's `say` records instead of printing in the device.
    display_record_flag: bool = false,
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
    zig_backend: ?vera.orchestrator.Backend = null,
    spice_path: ?[]const u8 = null,
    schedule: native.Schedule = .static,
    event_budget: u64 = digital.max_events_per_tick,
    logic: native.Logic = .auto,
    /// `--state=` or `--two-state`, whichever was typed last.
    logic_flag: ?[]const u8 = null,

    /// Frees the lists and the lint levels; `gpa` is the one `parse` was given.
    pub fn deinit(cli: *Cli, gpa: std.mem.Allocator) void {
        cli.levels.deinit(gpa);
        cli.include_dirs.deinit(gpa);
        cli.overrides.deinit(gpa);
        cli.paths.deinit(gpa);
        cli.libmaps.deinit(gpa);
        cli.search.deinit(gpa);
    }
};

/// Reads every argument after argv[0] into `cli`, in order. Returns null to
/// go on, or the process exit code when the line is answered here: 0 after
/// `--help` (usage on `out`), `--version` (`vera <contract.vera_version>` on
/// `out`) or `--explain CODE` (the explanation on `out`),
/// 2 after a malformed flag (the reason on `err`). Stops at the first such
/// flag, so the rest of the line is never read.
/// `args` points at any iterator whose `next()` returns each argument as a
/// `?[]const u8` (or a sentinel slice): `std.process.Args.Iterator`, or a
/// test's fixed list. `cli` borrows every argument it keeps, so the
/// iterator's storage must outlive `cli`. Invalidates nothing; the lists grow
/// in `gpa`, which `Cli.deinit` takes.
pub fn parse(cli: *Cli, gpa: std.mem.Allocator, args: anytype, out: *Io.Writer, err: *Io.Writer) !?u8 {
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try out.writeAll(usage_text);
            return 0;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "-V")) {
            try out.writeAll("vera " ++ vera_version ++ "\n");
            return 0;
        } else if (std.mem.eql(u8, arg, "--explain")) {
            const name = args.next() orelse return try missing(err, "--explain", "a code, e.g. --explain W0650");
            const code = std.meta.stringToEnum(diag.Code, name) orelse {
                try err.print("error: unknown diagnostic code `{s}`\n", .{name});
                return 2;
            };
            try diag.explain(code, out, if (cli.color == .never) .off else .on);
            return 0;
        } else if (std.mem.eql(u8, arg, "--lint")) {
            cli.lint_flag = true;
        } else if (std.mem.eql(u8, arg, "--lsp")) {
            cli.lsp = true;
        } else if (std.mem.eql(u8, arg, "--emit-zig")) {
            cli.emit_zig = true;
            cli.emit_zig_typed = true;
            cli.codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--emit-verilog")) {
            cli.emit_verilog = true;
            cli.codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--emit-rtlil")) {
            cli.emit_rtlil = true;
            cli.codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--digital-pins")) {
            cli.digital_pins = args.next() orelse return try missing(err, "--digital-pins", "a list of ports or a file");
        } else if (std.mem.eql(u8, arg, "--power-pins")) {
            cli.power_pins = true;
        } else if (std.mem.startsWith(u8, arg, "--vdd=")) {
            cli.vdd = std.fmt.parseFloat(f64, arg["--vdd=".len..]) catch 0;
            if (!(cli.vdd > 0) or !std.math.isFinite(cli.vdd)) {
                try err.print("error: `{s}`: not a positive number\n", .{arg});
                return 2;
            }
        } else if (std.mem.eql(u8, arg, "--check")) {
            cli.check = true;
            cli.codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--emit-so")) {
            cli.emit_so = true;
            cli.codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--emit-osdi")) {
            cli.emit_so = true;
            cli.emit_osdi = true;
            cli.codegen_flag = arg;
        } else if (std.mem.eql(u8, arg, "--emit-exe") or std.mem.eql(u8, arg, "--run")) {
            // The testbench IS the display output, so asking for one and then
            // dropping the prints would build an artifact with nothing to say.
            cli.run_exe = cli.run_exe or std.mem.eql(u8, arg, "--run");
            cli.display = .emit;
            cli.codegen_flag = arg;
            cli.exe_flag = arg;
        } else if (std.mem.eql(u8, arg, "--display=emit")) {
            cli.display = .emit;
            cli.display_drop_flag = false;
            cli.display_record_flag = false;
        } else if (std.mem.eql(u8, arg, "--display=drop")) {
            cli.display = .drop;
            cli.display_drop_flag = true;
            cli.display_record_flag = false;
        } else if (std.mem.eql(u8, arg, "--display=record")) {
            cli.display = .record;
            cli.display_drop_flag = false;
            cli.display_record_flag = true;
        } else if (std.mem.eql(u8, arg, "--validate-contract")) {
            cli.validate_contract = true;
        } else if (std.mem.eql(u8, arg, "--jac-f32")) {
            cli.jac_f32 = true;
        } else if (std.mem.eql(u8, arg, "--jac-f32-host")) {
            cli.jac_f32_host = true;
        } else if (std.mem.eql(u8, arg, "--contract")) {
            cli.contract_path = try pathValue(args, err, "--contract", "a path") orelse return 2;
        } else if (std.mem.eql(u8, arg, "--param")) {
            const kv = args.next() orelse return try missing(err, "--param", "NAME=VALUE");
            const eq = std.mem.findScalar(u8, kv, '=') orelse return try missing(err, "--param", "NAME=VALUE");
            // A string parameter takes the text; a numeric one refuses a NaN
            // once its type is known (Compilation, the digital elaboration).
            const text = kv[eq + 1 ..];
            const value = std.fmt.parseFloat(f64, text) catch std.math.nan(f64);
            try cli.overrides.append(gpa, .{ .name = kv[0..eq], .value = value, .text = text });
        } else if (std.mem.eql(u8, arg, "--dyn")) {
            cli.dyn_path = try pathValue(args, err, "--dyn", "a path") orelse return 2;
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            cli.work_dir = try pathValue(args, err, "--work-dir", "a directory") orelse return 2;
        } else if (std.mem.eql(u8, arg, "--debug-info")) {
            cli.debug_info = true;
        } else if (std.mem.eql(u8, arg, "--zig")) {
            cli.zig_exe = try pathValue(args, err, "--zig", "a path") orelse return 2;
        } else if (std.mem.startsWith(u8, arg, "--optimize=")) {
            cli.optimize = optimize_names.get(arg["--optimize=".len..]) orelse {
                try err.print("error: `{s}`: not Debug|ReleaseSafe|ReleaseFast|ReleaseSmall\n", .{arg});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "--two-state")) {
            cli.logic = .two;
            cli.logic_flag = arg;
        } else if (std.mem.startsWith(u8, arg, "--state=")) {
            const v = arg["--state=".len..];
            cli.logic = if (std.mem.eql(u8, v, "auto")) .auto else if (std.mem.eql(u8, v, "2")) .two else if (std.mem.eql(u8, v, "4")) .four else {
                try err.print("error: `{s}`: not auto|2|4\n", .{arg});
                return 2;
            };
            cli.logic_flag = arg;
        } else if (std.mem.startsWith(u8, arg, "--schedule=")) {
            cli.schedule = std.meta.stringToEnum(native.Schedule, arg["--schedule=".len..]) orelse {
                try err.print("error: `{s}`: not static|fifo\n", .{arg});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--event-budget=")) {
            cli.event_budget = std.fmt.parseInt(u64, arg["--event-budget=".len..], 10) catch 0;
            if (cli.event_budget == 0) {
                try err.print("error: `{s}`: not a positive integer\n", .{arg});
                return 2;
            }
        } else if (std.mem.startsWith(u8, arg, "--zig-backend=")) {
            const v = arg["--zig-backend=".len..];
            cli.zig_backend = if (std.mem.eql(u8, v, "auto")) null else if (std.mem.eql(u8, v, "llvm")) .llvm else if (std.mem.eql(u8, v, "native")) .self_hosted else {
                try err.print("error: `{s}`: not auto|llvm|native\n", .{arg});
                return 2;
            };
        } else if (std.mem.eql(u8, arg, "-o")) {
            cli.out_path = try pathValue(args, err, "-o", "a path") orelse return 2;
            cli.emit_zig = true;
            cli.codegen_flag = arg;
        } else if (std.mem.startsWith(u8, arg, "--expect-module=")) {
            cli.expect_module = arg["--expect-module=".len..];
        } else if (std.mem.eql(u8, arg, "--spice")) {
            cli.spice_path = try pathValue(args, err, "--spice", "a path") orelse return 2;
        } else if (std.mem.eql(u8, arg, "--libmap")) {
            try cli.libmaps.append(gpa, try pathValue(args, err, "--libmap", "a library map file") orelse return 2);
        } else if (std.mem.eql(u8, arg, "-L")) {
            try cli.search.append(gpa, args.next() orelse return try missing(err, "-L", "a library name"));
        } else if (std.mem.eql(u8, arg, "-I")) {
            try cli.include_dirs.append(gpa, try pathValue(args, err, "-I", "a directory") orelse return 2);
        } else if (std.mem.startsWith(u8, arg, "--std=")) {
            const set = vera.KeywordSet.fromSpecifier(arg["--std=".len..]) orelse {
                try err.print("error: `{s}`: not a `begin_keywords version specifier\n", .{arg});
                return 2;
            };
            // VerA compiles Verilog-AMS as VAMS-2023 only. "VAMS-2.3" stays a
            // `begin_keywords specifier in source, which §10.6 requires.
            if (set == .vams_2_3) {
                try err.print("error: `{s}`: Verilog-AMS is compiled as VAMS-2023; use `begin_keywords \"VAMS-2.3\" in the source for its keyword set\n", .{arg});
                return 2;
            }
            cli.language = set;
            cli.std_flag = arg;
        } else if (std.mem.startsWith(u8, arg, "--sim=")) {
            cli.sim = vera.Sim.fromFlag(arg["--sim=".len..]) orelse {
                try err.print("error: `{s}`: not verilogAMS|verilogA|verilog\n", .{arg});
                return 2;
            };
            cli.sim_flag = arg;
        } else if (std.mem.eql(u8, arg, "--no-std-defs")) {
            cli.std_defs = false;
        } else if (std.mem.eql(u8, arg, "--diagnostics=json")) {
            cli.json = true;
        } else if (std.mem.eql(u8, arg, "--diagnostics=text")) {
            cli.json = false;
        } else if (std.mem.eql(u8, arg, "--color=always")) {
            cli.color = .always;
        } else if (std.mem.eql(u8, arg, "--color=never")) {
            cli.color = .never;
        } else if (std.mem.eql(u8, arg, "--color=auto")) {
            cli.color = .auto;
        } else if (std.mem.startsWith(u8, arg, "--discipline-resolution=")) {
            cli.discipline_resolution = std.meta.stringToEnum(vera.DisciplineResolution, arg["--discipline-resolution=".len..]) orelse {
                try err.print("error: `{s}`: not basic|detail\n", .{arg});
                return 2;
            };
        } else if (std.mem.startsWith(u8, arg, "--unknown-bound=")) {
            const b = std.fmt.parseFloat(f64, arg["--unknown-bound=".len..]) catch std.math.nan(f64);
            if (std.math.isNan(b)) {
                try err.print("error: `{s}` is not a number\n", .{arg});
                return 2;
            }
            cli.unknown_bound = b;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            // --allow=X / --warn=X / --deny=X / --forbid=X
            const applied = cli.levels.parseFlag(gpa, arg[2..]) catch |e| switch (e) {
                error.CannotAllowError => {
                    try err.print(
                        "error: `{s}`: an error code cannot be allowed or warned away — " ++
                            "it is a statement about the program, not a preference\n",
                        .{arg},
                    );
                    return 2;
                },
                error.Forbidden => {
                    try err.print("error: `{s}`: this code was already --forbid'd\n", .{arg});
                    return 2;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            if (!applied) {
                try err.print("error: unknown option `{s}`\n", .{arg});
                return 2;
            }
        } else try cli.paths.append(gpa, arg);
    }
    return null;
}

/// Refuses the well-formed flags that conflict, whatever order they came in,
/// and settles what they derive: `--display=record` beside a testbench makes
/// it print the device's records, and `--emit-osdi` makes `-o` name the
/// `.osdi` rather than a device. Returns null to go on, or exit status 2
/// with the reason on `err`, or the usage when the line names no input.
/// Runs once, after `parse` returned null.
pub fn resolve(cli: *Cli, err: *Io.Writer) !?u8 {
    // `--sim=verilog` is IEEE 1364 Verilog and the other two are Verilog-AMS
    // keyword sets, so a `--std=` of the other family conflicts; without one,
    // `--sim=verilog` reads as IEEE 1364-2005.
    if (cli.sim_flag) |f| {
        const is_1364 = @backingInt(cli.language) < @backingInt(vera.KeywordSet.vams_2_3);
        if (cli.std_flag) |s| if (is_1364 != (cli.sim == .verilog)) {
            try err.print("error: `{s}` and `{s}` conflict: {s}\n", .{ f, s, if (cli.sim == .verilog) "--sim=verilog compiles IEEE 1364 Verilog" else "Verilog-A is a Verilog-AMS keyword set" });
            return 2;
        };
        if (cli.sim == .verilog and cli.std_flag == null) cli.language = .v1364_2005;
    }
    if (cli.exe_flag) |f| if (cli.display_drop_flag) {
        try err.print(
            "error: `{s}` and `--display=drop` conflict: the testbench IS the display " ++
                "output, and `--display=drop` discards every print\n",
            .{f},
        );
        return 2;
    };
    // §9.4 a testbench over the device a host gets: it prints the records
    // the device's `say` makes, whichever flag came first.
    if (cli.exe_flag != null and cli.display_record_flag) cli.display = .record;
    if (cli.validate_contract and cli.exe_flag == null) {
        try err.writeAll("error: `--validate-contract` turns the checks on in an --emit-exe or --run " ++
            "testbench; --check always runs them\n");
        return 2;
    }
    if (cli.lint_flag) if (cli.codegen_flag) |f| {
        try err.print(
            "error: `--lint` and `{s}` conflict: --lint stops after the frontend " ++
                "and `{s}` needs codegen\n",
            .{ f, f },
        );
        return 2;
    };

    if (cli.lsp) {
        if (cli.lint_flag or cli.codegen_flag != null) {
            try err.print("error: `--lsp` and `{s}` conflict: the server lints each open document itself\n", .{cli.codegen_flag orelse "--lint"});
            return 2;
        }
        if (cli.paths.items.len != 0) {
            try err.writeAll("error: `--lsp` takes no input file: the editor sends the documents\n");
            return 2;
        }
        return null;
    }

    if (cli.emit_verilog) if (cli.check or cli.emit_so or cli.exe_flag != null) {
        try err.writeAll("error: `--emit-verilog` builds no device: it takes neither --check, --emit-so, --emit-exe nor --run\n");
        return 2;
    };

    if (cli.emit_rtlil) {
        if (cli.check or cli.emit_so or cli.emit_zig_typed or cli.exe_flag != null or cli.emit_verilog) {
            try err.writeAll("error: `--emit-rtlil` builds no device: it takes neither --check, --emit-zig, --emit-so, --emit-verilog, --emit-exe nor --run\n");
            return 2;
        }
        cli.emit_zig = false; // `-o` names the RTLIL file
    }

    if (cli.emit_osdi) {
        if (cli.dyn_path != null or cli.emit_zig_typed or cli.exe_flag != null) {
            try err.writeAll("error: `--emit-osdi` builds under this vera's own OSDI dyn: it takes neither --dyn, --emit-zig, --emit-exe nor --run\n");
            return 2;
        }
        cli.emit_zig = false; // `-o` names the .osdi
    }

    // A testbench is its own artifact: beside it a library or a device text
    // was silently not built. `-o` names the executable, so only a typed
    // `--emit-zig` conflicts.
    if (cli.exe_flag) |f| if (cli.emit_so or cli.emit_zig_typed) {
        try err.print("error: `{s}` and `{s}` conflict: one run builds one artifact\n", .{ f, if (cli.emit_so) "--emit-so" else "--emit-zig" });
        return 2;
    };

    if (cli.paths.items.len == 0) {
        try err.writeAll(usage_text);
        return 2;
    }
    return null;
}

/// The value after the path-valued `flag`, or null once `missing` printed
/// `error: <flag> needs <what>`: the line ended there, or the value is empty,
/// which names no file. Every path flag reads its value here, so an empty
/// one is refused before anything opens or spawns it (#47).
fn pathValue(args: anytype, err: *Io.Writer, flag: []const u8, what: []const u8) !?[]const u8 {
    const v = args.next() orelse "";
    if (v.len != 0) return v;
    _ = try missing(err, flag, what);
    return null;
}

/// Prints `error: <flag> needs <what>` on `w`; returns exit status 2.
pub fn missing(w: *Io.Writer, flag: []const u8, what: []const u8) !u8 {
    try w.print("error: {s} needs {s}\n", .{ flag, what });
    return 2;
}

// ---------------------------------------------------------------------------
// Tests. Every expected message is the literal this file prints; every value
// is what the flag's text spells.
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A fixed command line, the iterator shape `parse` reads.
const Argv = struct {
    items: []const []const u8,
    i: usize = 0,

    fn next(a: *Argv) ?[]const u8 {
        if (a.i == a.items.len) return null;
        defer a.i += 1;
        return a.items[a.i];
    }
};

/// One command line under test: the `Cli` it fills and what it printed.
const Line = struct {
    cli: Cli = .{},
    out: Io.Writer.Allocating,
    err: Io.Writer.Allocating,

    fn init() Line {
        return .{ .out = .init(testing.allocator), .err = .init(testing.allocator) };
    }

    fn deinit(l: *Line) void {
        l.cli.deinit(testing.allocator);
        l.out.deinit();
        l.err.deinit();
    }

    /// `parse` over `argv` (literals, so they outlive `cli`).
    fn read(l: *Line, argv: []const []const u8) !?u8 {
        var it: Argv = .{ .items = argv };
        return parse(&l.cli, testing.allocator, &it, &l.out.writer, &l.err.writer);
    }

    /// `parse`, then `resolve` when `parse` went on.
    fn settle(l: *Line, argv: []const []const u8) !?u8 {
        if (try l.read(argv)) |code| return code;
        return resolve(&l.cli, &l.err.writer);
    }
};

/// `argv` stops `parse` with exit status 2 and exactly `want` on stderr.
fn expectRefused(argv: []const []const u8, want: []const u8) !void {
    var l: Line = .init();
    defer l.deinit();
    try testing.expectEqual(@as(?u8, 2), try l.read(argv));
    try testing.expectEqualStrings(want, l.err.written());
    try testing.expectEqualStrings("", l.out.written());
}

/// `argv` through `parse` and `resolve`: `code`, and exactly `want` on stderr.
fn expectSettled(argv: []const []const u8, code: ?u8, want: []const u8) !void {
    var l: Line = .init();
    defer l.deinit();
    try testing.expectEqual(code, try l.settle(argv));
    try testing.expectEqualStrings(want, l.err.written());
}

test "parse: --help and -h print the usage on stdout, exit 0, and read no further" {
    for ([_][]const u8{ "--help", "-h" }) |flag| {
        var l: Line = .init();
        defer l.deinit();
        try testing.expectEqual(@as(?u8, 0), try l.read(&.{ flag, "--no-such-flag" }));
        try testing.expectEqualStrings(usage_text, l.out.written());
        try testing.expectEqualStrings("", l.err.written());
    }
}

test "parse: --version prints contract.vera_version, which is build.zig.zon's .version" {
    // build.zig reads the manifest into `build_options.version`; contract.zig
    // ships alone to hosts, so it keeps the literal and this test holds the
    // two equal.
    try testing.expectEqualStrings(@import("build_options").version, vera_version);
    var l: Line = .init();
    defer l.deinit();
    try testing.expectEqual(@as(?u8, 0), try l.read(&.{ "--version", "--no-such-flag" }));
    try testing.expectEqualStrings("vera " ++ vera_version ++ "\n", l.out.written());
    for ([_][]const u8{ "-v", "-V" }) |flag| {
        var short: Line = .init();
        defer short.deinit();
        try testing.expectEqual(@as(?u8, 0), try short.read(&.{flag}));
        try testing.expectEqualStrings("vera " ++ vera_version ++ "\n", short.out.written());
    }
    try testing.expectEqualStrings("", l.err.written());
}

test "parse: --explain needs a known code, and prints it on stdout" {
    try expectRefused(&.{"--explain"}, "error: --explain needs a code, e.g. --explain W0650\n");
    try expectRefused(&.{ "--explain", "W9999" }, "error: unknown diagnostic code `W9999`\n");
    var l: Line = .init();
    defer l.deinit();
    // `--color=never` first: plain text (docs/using/diagnostics.md).
    try testing.expectEqual(@as(?u8, 0), try l.read(&.{ "--color=never", "--explain", "W0650" }));
    try testing.expect(std.mem.startsWith(u8, l.out.written(), "W0650: "));
    try testing.expect(std.mem.findScalar(u8, l.out.written(), 0x1b) == null);
}

test "parse: a flag that takes a value refuses a line that ends before it" {
    const cases = [_][2][]const u8{
        .{ "--digital-pins", "error: --digital-pins needs a list of ports or a file\n" },
        .{ "--contract", "error: --contract needs a path\n" },
        .{ "--param", "error: --param needs NAME=VALUE\n" },
        .{ "--dyn", "error: --dyn needs a path\n" },
        .{ "--work-dir", "error: --work-dir needs a directory\n" },
        .{ "--zig", "error: --zig needs a path\n" },
        .{ "-o", "error: -o needs a path\n" },
        .{ "--spice", "error: --spice needs a path\n" },
        .{ "--libmap", "error: --libmap needs a library map file\n" },
        .{ "-L", "error: -L needs a library name\n" },
        .{ "-I", "error: -I needs a directory\n" },
    };
    for (cases) |c| try expectRefused(&.{c[0]}, c[1]);
}

test "parse: every path-valued flag refuses an empty path; any other is taken as typed" {
    const cases = [_][2][]const u8{
        .{ "--contract", "error: --contract needs a path\n" },
        .{ "--dyn", "error: --dyn needs a path\n" },
        .{ "--work-dir", "error: --work-dir needs a directory\n" },
        .{ "--zig", "error: --zig needs a path\n" },
        .{ "-o", "error: -o needs a path\n" },
        .{ "--spice", "error: --spice needs a path\n" },
        .{ "--libmap", "error: --libmap needs a library map file\n" },
        .{ "-I", "error: -I needs a directory\n" },
    };
    for (cases) |c| try expectRefused(&.{ c[0], "" }, c[1]);
    var l: Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "--zig", "/opt/zig-0.17/zig" });
    try testing.expectEqualStrings("/opt/zig-0.17/zig", l.cli.zig_exe);
}

test "parse: the codegen flags set what they build and name themselves" {
    var l: Line = .init();
    defer l.deinit();
    try testing.expectEqual(@as(?u8, null), try l.read(&.{ "--emit-zig", "m.va" }));
    try testing.expect(l.cli.emit_zig and l.cli.emit_zig_typed);
    try testing.expectEqualStrings("--emit-zig", l.cli.codegen_flag.?);
    try testing.expectEqualStrings("m.va", l.cli.paths.items[0]);

    // `-o` implies the device text but is not `--emit-zig` typed.
    var o: Line = .init();
    defer o.deinit();
    _ = try o.read(&.{ "-o", "dev.zig" });
    try testing.expect(o.cli.emit_zig and !o.cli.emit_zig_typed);
    try testing.expectEqualStrings("dev.zig", o.cli.out_path.?);
    try testing.expectEqualStrings("-o", o.cli.codegen_flag.?);

    var s: Line = .init();
    defer s.deinit();
    _ = try s.read(&.{"--emit-osdi"});
    try testing.expect(s.cli.emit_so and s.cli.emit_osdi);
    try testing.expectEqualStrings("--emit-osdi", s.cli.codegen_flag.?);
}

test "parse: --run sticks once typed; the last of --emit-exe/--run names the testbench" {
    var l: Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "--run", "--emit-exe" });
    try testing.expect(l.cli.run_exe);
    try testing.expectEqualStrings("--emit-exe", l.cli.exe_flag.?);
    try testing.expectEqual(vera.codegen.Display.emit, l.cli.display);

    var e: Line = .init();
    defer e.deinit();
    _ = try e.read(&.{"--emit-exe"});
    try testing.expect(!e.cli.run_exe);
}

test "parse: the last --display wins, and only drop and record are remembered as typed" {
    var l: Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "--display=drop", "--display=emit" });
    try testing.expectEqual(vera.codegen.Display.emit, l.cli.display);
    try testing.expect(!l.cli.display_drop_flag and !l.cli.display_record_flag);
    _ = try l.read(&.{"--display=record"});
    try testing.expect(l.cli.display_record_flag and !l.cli.display_drop_flag);
    _ = try l.read(&.{"--display=drop"});
    try testing.expect(l.cli.display_drop_flag and !l.cli.display_record_flag);
}

test "parse: --vdd is a positive finite number" {
    for ([_][]const u8{ "--vdd=0", "--vdd=-1", "--vdd=nan", "--vdd=inf", "--vdd=", "--vdd=1.2V" }) |flag| {
        var buf: [64]u8 = undefined;
        try expectRefused(&.{flag}, try std.mem.print(&buf, "error: `{s}`: not a positive number\n", .{flag}));
    }
    var l: Line = .init();
    defer l.deinit();
    _ = try l.read(&.{"--vdd=3.3"});
    try testing.expectEqual(@as(f64, 3.3), l.cli.vdd);
}

test "parse: --param splits at the first `=` and keeps the text beside the number" {
    var l: Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "--param", "r=1e3", "--param", "w=-0.5", "--param", "s=1=2" });
    try testing.expectEqual(@as(usize, 3), l.cli.overrides.items.len);
    try testing.expectEqualStrings("r", l.cli.overrides.items[0].name);
    try testing.expectEqual(@as(f64, 1000), l.cli.overrides.items[0].value);
    try testing.expectEqual(@as(f64, -0.5), l.cli.overrides.items[1].value);
    // The first `=` splits, so the value is `1=2`: a string, not a number.
    try testing.expectEqualStrings("1=2", l.cli.overrides.items[2].text);
    try testing.expect(std.math.isNan(l.cli.overrides.items[2].value));
    try expectRefused(&.{ "--param", "r" }, "error: --param needs NAME=VALUE\n");
}

test "parse: a NaN --unknown-bound is not a number" {
    // A NaN compliance limit makes `[-|B|, |B|]` an interval
    // no comparison holds in, so the W0650 proof would rest on nothing.
    try expectRefused(&.{"--unknown-bound=nan"}, "error: `--unknown-bound=nan` is not a number\n");
    var l: Line = .init();
    defer l.deinit();
    _ = try l.read(&.{"--unknown-bound=100"});
    try testing.expectEqual(@as(?f64, 100), l.cli.unknown_bound);
    try expectRefused(&.{"--unknown-bound=x"}, "error: `--unknown-bound=x` is not a number\n");
}

test "parse: --optimize takes the four Zig mode names as the flag always spelled them" {
    var l: Line = .init();
    defer l.deinit();
    const modes = [_]struct { []const u8, std.lang.Optimize }{
        .{ "--optimize=Debug", .debug },
        .{ "--optimize=ReleaseSafe", .safe },
        .{ "--optimize=ReleaseFast", .fast },
        .{ "--optimize=ReleaseSmall", .small },
    };
    for (modes) |m| {
        _ = try l.read(&.{m[0]});
        try testing.expectEqual(m[1], l.cli.optimize.?);
    }
    // 0.17's own tag names are not the flag's.
    try expectRefused(&.{"--optimize=fast"}, "error: `--optimize=fast`: not Debug|ReleaseSafe|ReleaseFast|ReleaseSmall\n");
}

test "parse: --state/--two-state, --schedule and --zig-backend" {
    const Logic = native.Logic;
    var l: Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "--two-state", "--state=4" });
    try testing.expectEqual(Logic.four, l.cli.logic);
    try testing.expectEqualStrings("--state=4", l.cli.logic_flag.?);
    _ = try l.read(&.{"--state=auto"});
    try testing.expectEqual(Logic.auto, l.cli.logic);
    _ = try l.read(&.{"--two-state"});
    try testing.expectEqual(Logic.two, l.cli.logic);
    try expectRefused(&.{"--state=3"}, "error: `--state=3`: not auto|2|4\n");

    _ = try l.read(&.{"--schedule=fifo"});
    try testing.expectEqual(native.Schedule.fifo, l.cli.schedule);
    try expectRefused(&.{"--schedule=lifo"}, "error: `--schedule=lifo`: not static|fifo\n");

    _ = try l.read(&.{"--zig-backend=native"});
    try testing.expectEqual(vera.orchestrator.Backend.self_hosted, l.cli.zig_backend.?);
    // `auto` is the default again, not a third backend.
    _ = try l.read(&.{"--zig-backend=auto"});
    try testing.expect(l.cli.zig_backend == null);
    try expectRefused(&.{"--zig-backend=gcc"}, "error: `--zig-backend=gcc`: not auto|llvm|native\n");
}

test "parse: --event-budget is a positive u64" {
    for ([_][]const u8{ "--event-budget=0", "--event-budget=-5", "--event-budget=x", "--event-budget=18446744073709551616" }) |flag| {
        var buf: [96]u8 = undefined;
        try expectRefused(&.{flag}, try std.mem.print(&buf, "error: `{s}`: not a positive integer\n", .{flag}));
    }
    var l: Line = .init();
    defer l.deinit();
    _ = try l.read(&.{"--event-budget=18446744073709551615"});
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), l.cli.event_budget);
}

test "parse: the language, library and reporting flags" {
    var l: Line = .init();
    defer l.deinit();
    _ = try l.read(&.{
        "--std=1364-2005",
        "--no-std-defs",
        "--diagnostics=json",
        "--diagnostics=text",
        "--color=always",
        "--discipline-resolution=detail",
        "--libmap",
        "a.map",
        "--libmap",
        "b.map",
        "-L",
        "lib1",
        "-I",
        "inc",
        "--expect-module=",
    });
    try testing.expectEqual(vera.KeywordSet.v1364_2005, l.cli.language);
    try testing.expect(!l.cli.std_defs and !l.cli.json);
    try testing.expect(l.cli.color == .always);
    try testing.expectEqual(vera.DisciplineResolution.detail, l.cli.discipline_resolution);
    try testing.expectEqual(@as(usize, 2), l.cli.libmaps.items.len);
    try testing.expectEqualStrings("b.map", l.cli.libmaps.items[1]);
    try testing.expectEqualStrings("lib1", l.cli.search.items[0]);
    try testing.expectEqualStrings("inc", l.cli.include_dirs.items[0]);
    // An empty expected name is a name; no module is called that.
    try testing.expectEqualStrings("", l.cli.expect_module.?);
    try expectRefused(&.{"--std=1800-2017"}, "error: `--std=1800-2017`: not a `begin_keywords version specifier\n");
    try expectRefused(&.{"--std=VAMS-2.3"}, "error: `--std=VAMS-2.3`: Verilog-AMS is compiled as VAMS-2023; use `begin_keywords \"VAMS-2.3\" in the source for its keyword set\n");
    try expectRefused(&.{"--discipline-resolution=full"}, "error: `--discipline-resolution=full`: not basic|detail\n");
}

test "parse/resolve: --sim picks the language family, and conflicts with a --std of the other one" {
    var l: Line = .init();
    defer l.deinit();
    try testing.expectEqual(@as(?u8, null), try l.settle(&.{ "--sim=verilog", "m.v" }));
    try testing.expectEqual(vera.Sim.verilog, l.cli.sim);
    try testing.expectEqual(vera.KeywordSet.v1364_2005, l.cli.language);
    var a: Line = .init();
    defer a.deinit();
    try testing.expectEqual(@as(?u8, null), try a.settle(&.{ "--sim=verilogA", "--std=VAMS-2023", "m.va" }));
    try testing.expectEqual(vera.Sim.verilog_a, a.cli.sim);
    // A 1364 set of the user's choice stays.
    var k: Line = .init();
    defer k.deinit();
    try testing.expectEqual(@as(?u8, null), try k.settle(&.{ "--sim=verilog", "--std=1364-2001", "m.v" }));
    try testing.expectEqual(vera.KeywordSet.v1364_2001, k.cli.language);
    try expectRefused(&.{"--sim=vhdl"}, "error: `--sim=vhdl`: not verilogAMS|verilogA|verilog\n");
    try expectSettled(&.{ "--sim=verilog", "--std=VAMS-2023", "m.v" }, 2, "error: `--sim=verilog` and `--std=VAMS-2023` conflict: --sim=verilog compiles IEEE 1364 Verilog\n");
    try expectSettled(&.{ "--std=1364-2005", "--sim=verilogA", "m.va" }, 2, "error: `--sim=verilogA` and `--std=1364-2005` conflict: Verilog-A is a Verilog-AMS keyword set\n");
}

test "parse: lint levels, and what may not be allowed or un-forbidden" {
    var l: Line = .init();
    defer l.deinit();
    _ = try l.read(&.{"--deny=W0650"});
    try testing.expectEqual(diag.Level.deny, l.cli.levels.get(.W0650));
    try expectRefused(&.{"--allow=E0310"}, "error: `--allow=E0310`: an error code cannot be allowed or warned away — " ++
        "it is a statement about the program, not a preference\n");
    try expectRefused(&.{ "--forbid=W0650", "--allow=W0650" }, "error: `--allow=W0650`: this code was already --forbid'd\n");
    try expectRefused(&.{"--deny=W9999"}, "error: unknown option `--deny=W9999`\n");
    try expectRefused(&.{"--no-such-flag"}, "error: unknown option `--no-such-flag`\n");
}

test "parse: every argument that is not a flag is an input, in order" {
    var l: Line = .init();
    defer l.deinit();
    _ = try l.read(&.{ "top.v", "-", "lib.v" });
    try testing.expectEqual(@as(usize, 3), l.cli.paths.items.len);
    try testing.expectEqualStrings("-", l.cli.paths.items[1]);
}

test "resolve: no input prints the usage on stderr" {
    try expectSettled(&.{"--lint"}, 2, usage_text);
}

test "resolve: each conflict is refused by name, in either order" {
    const Case = struct { a: []const u8, b: []const u8, says: []const u8 };
    const cases = [_]Case{
        .{ .a = "--emit-exe", .b = "--display=drop", .says = "error: `--emit-exe` and `--display=drop` conflict: the testbench IS the display output, and `--display=drop` discards every print\n" },
        // `--lint` names the codegen flag, whichever came last.
        .{ .a = "--lint", .b = "--check", .says = "error: `--lint` and `--check` conflict: --lint stops after the frontend and `--check` needs codegen\n" },
        .{ .a = "--emit-verilog", .b = "--emit-so", .says = "error: `--emit-verilog` builds no device: it takes neither --check, --emit-so, --emit-exe nor --run\n" },
        .{ .a = "--emit-rtlil", .b = "--run", .says = "error: `--emit-rtlil` builds no device: it takes neither --check, --emit-zig, --emit-so, --emit-verilog, --emit-exe nor --run\n" },
        .{ .a = "--emit-osdi", .b = "--emit-zig", .says = "error: `--emit-osdi` builds under this vera's own OSDI dyn: it takes neither --dyn, --emit-zig, --emit-exe nor --run\n" },
        .{ .a = "--lsp", .b = "--lint", .says = "error: `--lsp` and `--lint` conflict: the server lints each open document itself\n" },
        .{ .a = "--lsp", .b = "--check", .says = "error: `--lsp` and `--check` conflict: the server lints each open document itself\n" },
    };
    for (cases) |c| {
        try expectSettled(&.{ c.a, c.b, "m.va" }, 2, c.says);
        try expectSettled(&.{ c.b, c.a, "m.va" }, 2, c.says);
    }
    try expectSettled(&.{ "--lsp", "m.va" }, 2, "error: `--lsp` takes no input file: the editor sends the documents\n");
    try expectSettled(&.{ "--lsp", "-I", "inc" }, null, "");
    try expectSettled(&.{ "--validate-contract", "m.va" }, 2, "error: `--validate-contract` turns the checks on in an --emit-exe or --run testbench; --check always runs them\n");
    try expectSettled(&.{ "--emit-osdi", "--dyn", "d.zig", "m.va" }, 2, "error: `--emit-osdi` builds under this vera's own OSDI dyn: it takes neither --dyn, --emit-zig, --emit-exe nor --run\n");
    try expectSettled(&.{ "--run", "--emit-osdi", "m.va" }, 2, "error: `--emit-osdi` builds under this vera's own OSDI dyn: it takes neither --dyn, --emit-zig, --emit-exe nor --run\n");
}

test "resolve: a testbench prints the device's records under --display=record, whichever came first" {
    for ([_][2][]const u8{ .{ "--display=record", "--emit-exe" }, .{ "--emit-exe", "--display=record" } }) |pair| {
        var l: Line = .init();
        defer l.deinit();
        try testing.expectEqual(@as(?u8, null), try l.settle(&.{ pair[0], pair[1], "m.va" }));
        try testing.expectEqual(vera.codegen.Display.record, l.cli.display);
    }
    // --validate-contract is legal beside a testbench.
    try expectSettled(&.{ "--run", "--validate-contract", "m.va" }, null, "");
}

test "resolve: --emit-rtlil makes -o name the RTLIL file, not a device text" {
    var l: Line = .init();
    defer l.deinit();
    try testing.expectEqual(@as(?u8, null), try l.settle(&.{ "--emit-rtlil", "-o", "m.il", "m.v" }));
    try testing.expect(l.cli.emit_rtlil and !l.cli.emit_zig);
    try testing.expectEqualStrings("m.il", l.cli.out_path.?);
}

test "resolve: --emit-osdi makes -o name the library, not a device text" {
    var l: Line = .init();
    defer l.deinit();
    try testing.expectEqual(@as(?u8, null), try l.settle(&.{ "-o", "m.osdi", "--emit-osdi", "m.va" }));
    try testing.expect(!l.cli.emit_zig);
    try testing.expectEqualStrings("m.osdi", l.cli.out_path.?);
}

test "resolve: one run builds one artifact: a testbench beside a library or a typed device text" {
    // The header's rule, "conflicting flags (never last-one-wins)": before,
    // `--emit-exe --emit-so` built the testbench and dropped the library.
    try expectSettled(&.{ "--emit-exe", "--emit-so", "m.va" }, 2, "error: `--emit-exe` and `--emit-so` conflict: one run builds one artifact\n");
    try expectSettled(&.{ "--emit-zig", "--run", "m.va" }, 2, "error: `--run` and `--emit-zig` conflict: one run builds one artifact\n");
    // `-o` beside a testbench names the executable, and `--check` builds
    // nothing, so neither conflicts.
    try expectSettled(&.{ "--emit-exe", "-o", "tb", "m.va" }, null, "");
    try expectSettled(&.{ "--check", "--emit-exe", "m.va" }, null, "");
}

test "parse: the switches set their field and read no value" {
    var l: Line = .init();
    defer l.deinit();
    try testing.expectEqual(@as(?u8, null), try l.read(&.{
        "--lsp",        "--power-pins", "--validate-contract", "--jac-f32",      "--jac-f32-host",
        "--debug-info", "--lint",       "--color=never",       "--emit-verilog", "m.va",
    }));
    const c = l.cli;
    try testing.expect(c.lsp and c.power_pins and c.validate_contract and c.jac_f32 and c.jac_f32_host and c.debug_info and c.lint_flag and c.emit_verilog);
    try testing.expect(c.color == .never);
    try testing.expectEqualStrings("--emit-verilog", c.codegen_flag.?);
    try testing.expectEqualStrings("m.va", c.paths.items[0]);
}

fn parseLine(gpa: std.mem.Allocator) !void {
    var cli: Cli = .{};
    defer cli.deinit(gpa);
    var it: Argv = .{ .items = &.{ "-I", "inc", "--param", "r=1", "--deny=W0650", "--libmap", "a.map", "-L", "lib", "top.v" } };
    var discard: Io.Writer.Discarding = .init(&.{});
    try testing.expectEqual(@as(?u8, null), try parse(&cli, gpa, &it, &discard.writer, &discard.writer));
}

test "parse: `Cli.deinit` frees every list, whichever allocation fails" {
    try testing.checkAllAllocationFailures(testing.allocator, parseLine, .{});
}
