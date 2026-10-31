//! Verilog source -> its IEEE 1364-2005 §17 transcript on `out`, or E1100
//! diagnostics before any process prints anything. The `Run` driver: engine
//! state, §6.2.2 per-instance names (§12.5/§12.6 hierarchical references),
//! and `elaborate`, the spine: preprocess and parse, §19.8 timescales, pass
//! one (`elab.zig`: elaboration into slots, nets and driver rows, §6.5,
//! §6.5.7.1, §19.9), pass two (every driver, switch and process compiled
//! and queued at time 0). `run` then drains the §11 scheduler.
//! Siblings: elab.zig (pass one), compile.zig (AST -> bytecode), exec.zig
//! (interpreter), evaluate.zig (expressions), net.zig (resolution tables),
//! resolution.zig (§7.9 resolution), waiters.zig (the write path), driver.zig
//! (VAMS §9.22 driver access), tchk.zig (§15), display.zig and system.zig
//! (§17), vcd.zig and evcd.zig (§18), bind.zig (§13), vpi.zig (a VPI
//! application's requests). The native emitter over a `Run` is the
//! `digital` module (src/codegen/digital/), which reads the files it names below.
//!
//! The caller's settings live in options.zig, Run's row types in run_rows.zig
//! and the elaboration steps after pass one in elab_steps.zig; this file
//! re-exports every name the other modules reach as `sim.digital.<name>`.
//!
//! Contents:
//! - `pub const Tick`
//! - `pub const exec`
//! - `pub const system`
//! - `pub const Run`
//! - `pub const own_files`
//! - `pub const Options`
//! - `pub const StmtSite`
//! - `pub const StmtHook`
//! - `pub const DoneHook`
//! - `pub const UserSystf`
//! - `pub const UserKind`
//! - `pub const Unit`
//! - `pub const Mixed`
//! - `pub const Param`
//! - `pub const Insert`
//! - `pub const Name`
//! - `pub const SpecExpr`
//! - `pub const TyState`
//! - `pub const Array`
//! - `pub const Span`
//! - `pub const VecRange`
//! - `pub const Standing`
//! - `pub const Watcher`
//! - `pub const Stop`
//! - `pub const Monitor`
//! - `pub const MonitorKind`
//! - `pub const D2aSite`
//! - `pub const PathKey`
//! - `pub const Sub`
//! - `pub const SlotMemo`
//! - `pub const memo_bits`
//! - `pub const ModuleTime`
//! - `pub const Overrides`
//! - `pub const PcRange`
//! - `pub const Frame`
//! - `pub const SlotNets`
//! - `pub const isRoot`
//! - `pub const bindDisables`
//! - `pub const for_emitter = struct`
//! - `for_emitter.compile`
//! - `for_emitter.evaluate`
//! - `for_emitter.display`
//! - `for_emitter.net`
//! - `for_emitter.vcd`
//! - `for_emitter.evcd`
//! - `pub const Error = error`
//! - `pub const max_events_per_tick: u64`
//! - `pub const analog_payload: u32`
//! - `pub fn run(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!void`
//! - `pub fn elaborate(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!Run`
//! - `pub fn expectRun(source: []const u8, expected: []const u8) !void`
//! - `pub fn expectRejected(source: []const u8, message: []const u8) !void`
//! - `N.expr(w: @This(), x: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void`
//! - `N.stmt(w: @This(), st: Ast.StmtId) Error!void`

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const Int = @import("kernels").Integer;
const diag = @import("diag");
const Scheduler = @import("../scheduler.zig").Scheduler;
/// Scheduler ticks. `Time` below is the timescale module, not this.
pub const Tick = @import("../scheduler.zig").Time;
const Time = @import("../time.zig");
const deep = @import("base").deep_stack;
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const display = @import("display.zig");
/// Public for the VPI (src/vpi/value.zig), which writes a value the way a
/// process does (`waiters.store` now, `exec.enqueue` of a `.write` later), so a
/// §12.30 put wakes waiters and value-change watchers like any other write.
pub const exec = @import("exec.zig");
/// §17 system tasks.
pub const system = @import("system.zig");
const driver = @import("driver.zig");
const binding = @import("bind.zig");
const elab = @import("elab.zig");
const waiters = @import("waiters.zig");
const resolution = @import("resolution.zig");
const tchk = @import("tchk.zig");
const vpi = @import("vpi.zig");
const Type = compile.Type;
const Instruction = compile.Instruction;
const Row = exec.Row;
const Delay = @import("net.zig").Delay;
const Net = @import("net.zig").Net;
const NetCold = @import("net.zig").NetCold;
const no_cold = @import("net.zig").no_cold;
const Tran = @import("net.zig").Tran;
const Signal = @import("net.zig").Signal;
const Inertial = @import("net.zig").Inertial;
const no_transition = @import("net.zig").no_transition;
const Driver = @import("net.zig").Driver;
const filled = @import("net.zig").filled;
const setBit = @import("net.zig").setBit;
const Show = display.Show;
const TimeFormat = display.TimeFormat;
/// One elaborated design and its whole simulation state (`Run.zig`).
pub const Run = @import("Run.zig");
const elab_steps = @import("elab_steps.zig");
const options = @import("options.zig");
const run_rows = @import("run_rows.zig");
const calls = elab_steps.calls;
const constantDelay = elab_steps.constantDelay;
const default_quantum = run_rows.default_quantum;
const driverBits = elab_steps.driverBits;
const initVars = elab_steps.initVars;
const mixedTimescales = elab_steps.mixedTimescales;
const netRuns = elab_steps.netRuns;
const processOrder = elab_steps.processOrder;
const processes = elab_steps.processes;
const topDeclares = elab_steps.topDeclares;

/// The descriptor table a `Run` with no `file_io` opens files through.
pub const own_files = system.own;

/// `options.Options`.
pub const Options = options.Options;

/// `options.StmtSite`.
pub const StmtSite = options.StmtSite;

/// `options.StmtHook`.
pub const StmtHook = options.StmtHook;

/// `options.DoneHook`.
pub const DoneHook = options.DoneHook;

/// `options.UserSystf`.
pub const UserSystf = options.UserSystf;

/// `options.UserKind`.
pub const UserKind = options.UserKind;

/// `options.Unit`.
pub const Unit = options.Unit;

/// `options.Mixed`.
pub const Mixed = options.Mixed;

/// `options.Param`.
pub const Param = options.Param;

/// `options.Insert`.
pub const Insert = options.Insert;

/// `run_rows.Name`.
pub const Name = run_rows.Name;

/// `run_rows.SpecExpr`.
pub const SpecExpr = run_rows.SpecExpr;

/// `run_rows.TyState`.
pub const TyState = run_rows.TyState;

/// `run_rows.Array`.
pub const Array = run_rows.Array;

/// `run_rows.Span`.
pub const Span = run_rows.Span;

/// `run_rows.VecRange`.
pub const VecRange = run_rows.VecRange;

/// `run_rows.Standing`.
pub const Standing = run_rows.Standing;

/// `run_rows.Watcher`.
pub const Watcher = run_rows.Watcher;

/// `run_rows.Stop`.
pub const Stop = run_rows.Stop;

/// `run_rows.Monitor`.
pub const Monitor = run_rows.Monitor;

/// `run_rows.MonitorKind`.
pub const MonitorKind = run_rows.MonitorKind;

/// `run_rows.D2aSite`.
pub const D2aSite = run_rows.D2aSite;

/// `run_rows.PathKey`.
pub const PathKey = run_rows.PathKey;

/// `run_rows.Sub`.
pub const Sub = run_rows.Sub;

/// `run_rows.SlotMemo`.
pub const SlotMemo = run_rows.SlotMemo;

/// `run_rows.memo_bits`.
pub const memo_bits = run_rows.memo_bits;

/// `run_rows.ModuleTime`.
pub const ModuleTime = run_rows.ModuleTime;

/// `run_rows.Overrides`.
pub const Overrides = run_rows.Overrides;

/// `run_rows.PcRange`.
pub const PcRange = run_rows.PcRange;

/// `run_rows.Frame`.
pub const Frame = run_rows.Frame;

/// `run_rows.SlotNets`.
pub const SlotNets = run_rows.SlotNets;

/// `run_rows.isRoot`.
pub const isRoot = run_rows.isRoot;

/// `elab_steps.bindDisables`.
pub const bindDisables = elab_steps.bindDisables;

/// The files the native emitter (the `digital` module: `vera --emit-exe` and
/// `.v` devices) reads besides `Run`, until B4 gives it IR of its own. A
/// namespace, since `net`, `vcd` and `evcd` name locals and fields here.
pub const for_emitter = struct {
    pub const compile = @import("compile.zig");
    pub const evaluate = @import("evaluate.zig");
    pub const display = @import("display.zig");
    pub const net = @import("net.zig");
    pub const vcd = @import("vcd.zig");
    pub const evcd = @import("evcd.zig");
};

/// `DigitalFailed`: a diagnostic is already in the `bag` (E1100 by default,
/// or the rule's own code through `Run.failWith`); the run stops there.
/// `WriteFailed`: the transcript writer `out` failed.
pub const Error = error{DigitalFailed} || std.mem.Allocator.Error || std.Io.Writer.Error;

/// The events one time step may dispatch before `runUntil` calls it a
/// zero-delay loop. Far above any design's settling activity per step.
pub const max_events_per_tick: u64 = 10_000_000;

/// The scheduler payload of the one analog macro-process. Not a `pending`
/// row: the event carries no data, and the scheduler coalesces repeats of it
/// (§8.5.3.7) by payload.
pub const analog_payload: u32 = std.math.maxInt(u32);

/// Runs `source` to completion: `elaborate`, then every event. `arena` and
/// `bag` must outlive the call; the transcript goes to `out`.
pub fn run(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!void {
    return deep.runGuarded(0, runDeep, .{ arena, source, opts, bag, out });
}

/// Everything `run` does before the first event dispatches: preprocess,
/// parse, §6.2.2 elaboration, and every driver and process compiled and
/// enqueued at time 0. The returned `Run` owns nothing outside `arena`, so a
/// caller that holds it may step it with `runUntil` for as long as the arena
/// lives, as a mixed-signal coordinator does.
pub fn elaborate(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!Run {
    return deep.runGuarded(0, elaborateDeep, .{ arena, source, opts, bag, out });
}

/// Test helper: runs `source` and expects its transcript to be `expected`
/// exactly; on a refusal prints the rendered diagnostics, then fails.
pub fn expectRun(source: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    run(arena.allocator(), source, .{}, &bag, &output.writer) catch |e| {
        var messages = std.Io.Writer.Allocating.init(arena.allocator());
        try diag.render(&bag, &messages.writer, .{});
        std.debug.print("{s}", .{messages.written()});
        return e;
    };
    try std.testing.expectEqualStrings(expected, output.written());
}

/// Test helper: expects `source` to fail before printing anything, with a
/// rendered diagnostic containing `message`.
pub fn expectRejected(source: []const u8, message: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try std.testing.expectError(error.DigitalFailed, run(arena.allocator(), source, .{}, &bag, &output.writer));
    try std.testing.expectEqualStrings("", output.written());
    var messages = std.Io.Writer.Allocating.init(arena.allocator());
    try diag.render(&bag, &messages.writer, .{});
    try std.testing.expect(std.mem.find(u8, messages.written(), message) != null);
}

// ---- private ----

fn runDeep(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!void {
    var r = try elaborate(arena, source, opts, bag, out);
    // Nothing is `watchAnalog`ed in a digital-only run, so it never stops early.
    _ = try r.runUntil(std.math.maxInt(Tick));
    try @import("evcd.zig").close(&r);
}

fn elaborateDeep(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag, out: *std.Io.Writer) Error!Run {
    const pp: Front.Preprocessor.Output = if (opts.mixed) |mx| .{
        .text = source,
        .directives = .{ .timescales = try mixedTimescales(arena, mx.timescales) },
    } else Front.Preprocessor.process(arena, source, .{ .file_name = opts.file_name, .include_dirs = opts.include_dirs, .defines = opts.defines, .std_defs = false, .more = more: {
        const more = try arena.alloc(Front.Preprocessor.File, opts.more.len);
        for (opts.more, more) |u, *f| f.* = .{ .name = u.name, .text = u.text };
        break :more more;
    }, .bag = bag, .std_1364 = @backingInt(opts.language) < @backingInt(Front.token.KeywordSet.vams_2_3), .protect_keys = opts.protect_keys }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.PreprocessFailed => error.DigitalFailed,
    };
    const text = pp.text;
    const times = pp.directives.timescales;
    const drives = pp.directives.drives;
    var tokens = try Front.Lexer.Lexer.tokenize(arena, text);
    var parser = Front.Parser.Parser.init(arena, text, tokens.items(.tag), tokens.items(.start), bag);
    parser.digital = true;
    parser.setLanguage(opts.language);
    // A failed parse still leaves every recovered module in `parser.file`, and
    // the `wreal` refusal is itself a parse error, so the rules read that.
    // Arena-owned, not a local: the returned `Run` points at it. Elaboration
    // writes an overlay of the parse, never the parse.
    const parse = try arena.create(Ast.SourceFile);
    parse.* = parser.parseSourceFile() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => parser.file,
    };
    const parsed: *const Ast.SourceFile = parse;
    const file = try arena.create(Ast.SourceFile);
    file.* = parsed.overlay(.{});
    try Front.wreal.check(file, tokens.items(.start), bag);
    if (bag.failed()) return error.DigitalFailed;
    var r: Run = .{ .arena = arena, .file = file, .text = text, .starts = tokens.items(.start), .bag = bag, .out = out, .values = &.{}, .scheduler = .empty, .file_name = opts.file_name, .io = opts.io, .drives = drives, .nettypes = pp.directives.nettypes, .analog = .{ .mixed = opts.mixed != null, .a2d_reads = if (opts.mixed) |mx| mx.reads else &.{}, .card = if (opts.mixed) |mx| mx.params else &.{}, .real_card = if (opts.mixed) |mx| mx.real_params else &.{} }, .event_budget = .{ .max = opts.event_budget }, .host = .{ .systf = opts.systf, .stmt_sites = if (opts.stmt_sites) .empty else null }, .source = source, .opts = opts, .scratch_buf = try arena.alloc(u8, exec.scratch_fixed_bytes), .scratch = .init(arena), .resolve_scratch = .init(arena) };
    try binding.libraries(&r, file, opts, pp.more_starts);
    // IEEE 1364-2005 §8.1's rules hold for every UDP declaration, whether or
    // not an instance uses it.
    for (file.udps) |*u| try elab.checkUdp(&r, u);
    var tops: []const u32 = &.{};
    const m = if (opts.mixed) |mx| for (file.modules) |*c| {
        if (file.strings.eql(c.name, mx.top)) break c;
    } else return r.fail(0, "the mixed-signal root module is not in the source", .{}) else blk: {
        if (file.modules.len == 0 or file.disciplines.len != 0 or file.natures.len != 0 or file.paramsets.len != 0 or file.connectrules.len != 0) return r.fail(0, "digital execution requires ordinary modules and no analog declarations", .{});
        tops = try elab.pickTops(&r, file.modules);
        break :blk &file.modules[tops[0]];
    };
    // IEEE 1364 §19.8: a `timescale applies to "all modules that follow this
    // directive until another `timescale compiler directive is read", so each
    // definition takes the last directive before it. A null value is §19.6's
    // `resetall, which returns to "none specified", the simulator-specific
    // default. The preprocessor refuses a malformed directive where it is
    // written (E0142). A mixed design's first timescale is moved to offset 0
    // (`mixedTimescales`).
    const Local = struct { unit: Time.Quantum = default_quantum, precision: Time.Quantum = default_quantum, set: bool = false };
    var finest: Time.Quantum = default_quantum;
    var set: usize = 0;
    const locals = try arena.alloc(Local, file.modules.len);
    const tags = tokens.items(.tag);
    for (file.modules, locals) |*def, *l| {
        l.* = .{};
        // A `timescale between a module's header and its `endmodule`: §19.8
        // gives a directive to "all modules that follow", and 1364 has no
        // "shall" on where it is written; VerA refuses it, as iverilog does
        // (no_timescale_in_module).
        var end = def.main_tok;
        while (end + 1 < tags.len and tags[end] != .kw_endmodule) end += 1;
        for (times) |event| if (event.at > r.starts[def.main_tok] and event.at < r.starts[end])
            return r.fail(def.main_tok, "§19.8: a `timescale directive is written outside a module definition, not inside one", .{});
        for (times) |event| {
            if (event.at > r.starts[def.main_tok]) continue;
            const t = event.value orelse {
                l.* = .{};
                continue;
            };
            l.* = .{
                .unit = Time.Quantum.fromSeconds(t.unit) catch return r.fail(def.main_tok, "unsupported time unit", .{}),
                .precision = Time.Quantum.fromSeconds(t.precision) catch return r.fail(def.main_tok, "unsupported time precision", .{}),
                .set = true,
            };
        }
        set += @intFromBool(l.set);
        if (@backingInt(l.precision) < @backingInt(finest)) finest = l.precision;
    }
    if (set != 0 and set != file.modules.len) return r.fail(m.main_tok, "§19.8: it shall be an error if some modules have a `timescale specified and others do not", .{});
    // "The smallest time_precision argument of all the `timescale compiler
    // directives in the design determines the precision of the time unit of
    // the simulation": that is the scheduler's tick, and every module's delays
    // are scaled to it.
    const module_times = try arena.alloc(ModuleTime, file.modules.len);
    for (file.modules, locals, module_times) |*def, l, *mt| mt.* = .{
        .scale = Time.Scale.init(l.unit, l.precision, finest) catch return r.fail(def.main_tok, "invalid timescale", .{}),
        .unit_exp = @backingInt(l.unit),
    };
    r.time.modules = module_times;
    const root_time = module_times[elab.defOf(&r, m)];
    r.time.scale = root_time.scale;
    r.time.unit_exp = root_time.unit_exp;
    // §17.3: "the default ... is the smallest time precision argument of
    // all the `timescale compiler directives in the source description".
    r.time.format.units = @backingInt(finest);
    r.time.finest = r.time.format.units;
    // Pass one: storage. Variables, array elements and nets share one slot
    // space, so one `store` publishes all three and wakes the same event
    // waiters. §6.2.2 elaboration walks the instance tree parent-first, which
    // is what lets a port connection resolve against nets that already exist.
    var e: elab.Elab = .{};
    try r.scope_info.append(arena, .{ .parent = 0, .name = m.name, .def = elab.defOf(&r, m) });
    // IEEE 1364-2005 §12.1.1 every other top-level module is a root of its
    // own, scoped before any instance so a defparam in it that names another
    // top's parameter (§12.2.1) is registered when that parameter is set.
    if (tops.len > 1) {
        const roots = try arena.alloc(u32, tops.len);
        roots[0] = 0;
        for (tops[1..], roots[1..]) |d, *s| {
            const t = &file.modules[d];
            s.* = try elab.newScope(&r, t.main_tok);
            try r.scope_info.append(arena, .{ .parent = s.*, .name = t.name, .def = d });
            for (t.defparams) |dp| try elab.bindDefparam(&r, s.*, dp, t.instances);
        }
        r.roots = roots;
    }
    for (r.roots, 0..) |s, k| if (r.binds.get(0)) |b| if (b.cfg) |c|
        try r.binds.put(arena, s, binding.rootCtx(&r, c, if (tops.len == 0) elab.defOf(&r, m) else tops[k]));
    if (opts.mixed) |mx| {
        // VAMS §7.8.4 each bridge's segment, spelled as the flatten spells it
        // (`bridged` declares it), for the connections re-pointed at it.
        const segs = try arena.alloc(Ast.ExprId, mx.inserts.len);
        for (mx.inserts, segs) |row, *x| {
            // Every other name a row holds is the source's own.
            _ = try file.intern(arena, row.name);
            x.* = try file.exprs.add(arena, .{
                .tag = .ident,
                .main_tok = m.main_tok,
                .str = try file.intern(arena, try arena.print("{s}.{s}", .{ row.name, row.lower_port })),
            });
        }
        r.inserts = mx.inserts;
        r.insert_segs = segs;
    }
    // Allocated before pass one: a bound or a parameter is typed and folded
    // while the slot space is still growing (`Run.constant`).
    r.types = try arena.alloc(Type, file.exprs.len());
    r.ty_state = try arena.alloc(TyState, file.exprs.len());
    @memset(r.ty_state, .untyped);
    r.sys_calls = try arena.alloc(?compile.SysFn, file.exprs.len());
    @memset(r.sys_calls, null);
    r.growing = &e.values;
    try elab.declare(&r, &e, m, 0, &.{}, &.{}, 0);
    if (tops.len > 1) for (r.roots[1..], tops[1..]) |s, d| try elab.declare(&r, &e, &file.modules[d], s, &.{}, &.{}, 0);
    try elab.checkDefparams(&r);
    // A misspelt `--param` would otherwise run the default design.
    for (opts.params) |o| {
        // `tops[0]`, when there are tops, is `m`.
        const known = topDeclares(file, m, o.name) or for (tops) |d| {
            if (topDeclares(file, &file.modules[d], o.name)) break true;
        } else false;
        if (!known) return r.fail(m.main_tok, "--param {s}: no top-level module declares a parameter `{s}`", .{ o.name, o.name });
    }
    try driver.segregate(&r, &e);
    r.values = e.values.items;
    r.nets = e.nets.items;
    r.net_cold = e.net_cold;
    r.signals = e.signals.items;
    try tchk.delayedDrivers(&r, &e);
    // Pass two: drivers, then processes. §6.1 one continuous assignment is one
    // driver of one net; §7.9 resolution needs them grouped, because every
    // update reads all of a net's drivers.
    //
    // Drivers compile first so that no driver's pc can also be a process's
    // resumption point: a `wait_event` resumes at its own pc plus one, and
    // every instruction from here on belongs to a process.
    if (e.wires.items.len > std.math.maxInt(u32)) return r.fail(m.main_tok, "too many continuous assignments", .{});
    r.drivers = try arena.alloc(Driver, e.wires.items.len);
    for (e.wires.items, 0..) |a, i| {
        r.scope = a.scope;
        var watched: std.ArrayList(u32) = .empty;
        switch (a.source) {
            .bridge => |b| try watched.append(arena, b.src),
            // §7.8.5 a gate re-evaluates on any input change, exactly as a
            // continuous assignment does on any operand change.
            .gate => |g| for (g.ins) |in| {
                try compile.checkExpr(&r, in);
                const w = compile.typeOf(&r, in).width;
                // A single gate reads a vector input's LSB: §7.1.6 sizes only
                // an array's terminals, and iverilog (gate_connect1) and the
                // other simulators read bit 0.
                if (g.lane != null and w != 1 and w != g.lanes) return r.exprFail(in, "a gate's input terminal is one bit, or one per instance of an array");
                try compile.sensitivity(&r, in, &watched);
            },
            .mos => |mo| for ([_]Ast.ExprId{ mo.data, mo.gate }) |in| {
                try compile.checkExpr(&r, in);
                // §7.1.6: an instance array's member reads its bit `lane`
                // of a vector terminal, as a gate does.
                const w = compile.typeOf(&r, in).width;
                if (w != 1 and !(mo.lane != null and mo.lane.? < w)) return r.exprFail(in, "a switch terminal is one bit, or one per instance of an array");
                try compile.sensitivity(&r, in, &watched);
            },
            .udp => |u| for (u.ins) |in| {
                try compile.checkExpr(&r, in);
                if (compile.typeOf(&r, in).width != 1 and u.lane == null) return r.exprFail(in, "a UDP's input terminal is one bit, or one per instance of an array");
                try compile.sensitivity(&r, in, &watched);
            },
            .expr => |x| {
                try compile.checkExpr(&r, x.e);
                try compile.sensitivity(&r, x.e, &watched);
            },
            .pull => {},
        }
        r.drivers[i] = .{
            .net = a.net,
            .source = a.source,
            .scope = a.scope,
            .sensitivity = watched.items,
            // A driver's output is unknown until its first value lands
            // (§4.2.1: "Nets with drivers shall assume the output value of
            // their drivers"; §8.5 Figure 8-1 draws q and qb, behind `buf #3`
            // and `not #5`, unknown until 3 and 5). Only a net with no driver
            // keeps §4.2.1's default z. A sequential UDP's output is its state
            // from the start (§8.5), set below.
            .current = try filled(arena, r.nets[a.net].resolved.width, false, .x),
            .s0 = a.s0,
            .s1 = a.s1,
            .delay = if (try constantDelay(&r, a.delay)) try r.declaredDelay3(a.delay, a.tok) else blk: {
                try r.driver_delays.put(arena, @intCast(i), a.delay);
                break :blk .{ .present = true };
            },
            .tok = a.tok,
        };
        // A UDP's output bit starts at its state: §8.5's initial value for a
        // sequential one, x for a combinational one until its first value.
        if (a.source == .udp) setBit(r.drivers[i].current, a.source.udp.out_bit orelse 0, a.source.udp.state);
        _ = try exec.enqueue(&r, .{ .run_process = try compile.append(&r, .{ .continuous = @intCast(i) }) }, null, false);
    }
    // The bits a continuous assignment or a port window leaves at z (a
    // select's other bits, a constant z) are z from the start, not the x
    // of a value still to come: their first evaluation changes nothing
    // there, so it wakes nothing (iverilog's reading; a process armed
    // before it would see a change no driver made).
    {
        var scratch = std.heap.ArenaAllocator.init(arena);
        defer scratch.deinit();
        // Read every net as x, the value its drivers have not yet given it:
        // a bit is z here only when no operand value can make it otherwise.
        const saved = try scratch.allocator().alloc([]u64, r.nets.len);
        for (r.nets, saved) |n, *keep| {
            const planes = r.values[n.slot].planes;
            keep.* = try scratch.allocator().dupe(u64, planes);
            const x = try filled(scratch.allocator(), r.values[n.slot].width, false, .x);
            @memcpy(planes, x.planes);
        }
        defer for (r.nets, saved) |n, keep| @memcpy(r.values[n.slot].planes, keep);
        for (r.drivers) |*d| {
            r.scope = d.scope;
            const first = switch (d.source) {
                // A window's source may be a net not yet initialized: only
                // the bits outside the window are known to be z.
                .bridge => |b| blk: {
                    const w = try filled(scratch.allocator(), d.current.width, false, .z);
                    for (b.dst_lo..b.dst_lo + b.width) |k| setBit(w, @intCast(k), .x);
                    break :blk w;
                },
                // A call may have side effects (a function writing a module
                // variable): such a driver starts at x throughout.
                .expr => |x| blk: {
                    if (calls(&r.file.exprs, x.e)) continue;
                    if (x.slice) |sl| {
                        const whole = try evaluate.eval(&r, scratch.allocator(), x.e, sl.total);
                        const part = try filled(scratch.allocator(), d.current.width, false, .z);
                        evaluate.copyBits(part, 0, whole, sl.lo, d.current.width);
                        break :blk part;
                    }
                    break :blk try evaluate.evalFor(&r, scratch.allocator(), x.e, r.slotType(r.nets[d.net].slot));
                },
                else => continue, // else: a gate, switch, UDP or pull starts at its own unknown
            };
            for (0..d.current.width) |k| if (first.bit(@intCast(k)) == .z) setBit(d.current, @intCast(k), .z);
        }
    }
    // §7.6: each net knows the pass switches on it, and a controlled one is
    // a process that re-resolves both sides whenever its control changes.
    r.trans = try arena.alloc(Tran, e.trans.items.len);
    for (e.trans.items, r.trans, 0..) |t, *dst, i| {
        dst.* = t.tran;
        r.scope = t.scope;
        // §7.6's delays, a variable read when the control changes as a
        // driver's is (iverilog's rise_fall_delay3).
        if (t.delay.rise != .none) dst.delay = if (try constantDelay(&r, t.delay)) try r.declaredDelay3(t.delay, t.tok) else blk: {
            try r.tran_delays.put(arena, @intCast(i), t.delay);
            break :blk .{ .present = true };
        };
        if (t.tran.ctrl == .none) continue;
        try compile.checkExpr(&r, t.tran.ctrl);
        var watched: std.ArrayList(u32) = .empty;
        try compile.sensitivity(&r, t.tran.ctrl, &watched);
        _ = try exec.enqueue(&r, .{ .run_process = try compile.append(&r, .{ .switch_ctrl = .{ .tran = @intCast(i), .slots = watched.items } }) }, null, false);
    }
    for (r.drivers) |d| if (d.source == .mos and file.exprs.tag(d.source.mos.data) == .ident) {
        r.scope = d.scope;
        if (r.net_of.get(try r.slot(d.source.mos.data))) |net| r.nets[net].strength_read = true;
    };
    // Each net's pass switches and drivers, in declaration order, as runs of
    // one flat array each (a counting sort), not a list per net: a large net
    // array is one net per element and almost none of them has either.
    {
        const at = try netRuns(arena, r.nets.len, e.trans.items.len * 2, e.trans.items, struct {
            fn each(t: anytype, k: usize) u32 {
                return if (k == 0) t.tran.a else t.tran.b;
            }
        }.each, 2);
        defer arena.free(at.start);
        for (0..r.nets.len) |net| if (at.start[net] != at.start[net + 1]) {
            (try r.netColdMut(@intCast(net))).trans = at.items[at.start[net]..at.start[net + 1]];
        };
    }
    {
        const at = try netRuns(arena, r.nets.len, e.wires.items.len, e.wires.items, struct {
            fn each(w: anytype, _: usize) u32 {
                return w.net;
            }
        }.each, 1);
        r.net_driver_start = at.start;
        r.net_drivers = at.items;
        for (r.nets, 0..) |n, net| {
            resolution.initial(&r, @intCast(net));
            // §7.9 `uwire` is the UNRESOLVED net type: a second driver is not a
            // resolution question there, it is an error. §4.6.5's "more than
            // one driver" is per bit: drivers of disjoint selects are legal.
            if (n.kind == .uwire) {
                const ds = r.netDrivers(@intCast(net));
                for (ds, 0..) |a, i| for (ds[i + 1 ..]) |b| {
                    const x = driverBits(r.drivers[a], n.resolved.width);
                    const y = driverBits(r.drivers[b], n.resolved.width);
                    if (x[0] < y[1] and y[0] < x[1]) return r.fail(n.tok, "a uwire net accepts a single driver per bit", .{});
                };
            }
        }
    }
    // §10 subroutine bodies, each on its own pc range before any process, so
    // a synchronous call never runs into a process's code.
    try compile.compileSubs(&r);
    // §9.9 leaves the order of initial and always constructs open; VerA
    // queues them as iverilog does: the scope tree depth first, each
    // instance's and generate block's child scopes (in source order) before
    // its own processes, which keep source order (ivtest contrib/pic's
    // first lines).
    for (try processOrder(&r, &e)) |g| if (g < e.insts.items.len) {
        const inst = e.insts.items[g];
        r.scope = inst.scope;
        try initVars(&r, inst.module.vars);
        if (r.analog.mixed) {
            // The names the digital processes mention, for `analogTriggers`.
            var named: std.AutoHashMapUnmanaged(Ast.StrId, void) = .empty;
            const N = struct {
                f: *const Ast.SourceFile,
                out: *std.AutoHashMapUnmanaged(Ast.StrId, void),
                a: std.mem.Allocator,
                pub fn expr(w: @This(), x: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void {
                    if (x == .none) return;
                    if (w.f.exprs.tag(x) == .ident) try w.out.put(w.a, w.f.exprs.strOf(x), {});
                    var buf: [3]Ast.ExprId = undefined;
                    for (w.f.exprs.children(x, &buf)) |c| try w.expr(c, .read);
                }
                pub fn stmt(w: @This(), st: Ast.StmtId) Error!void {
                    if (st != .none) try w.f.stmtEdges(st, w);
                }
            };
            for (inst.module.discrete) |process| try (N{ .f = r.file, .out = &named, .a = arena }).stmt(process.body);
            try r.analogTriggers(inst.module, &named);
        }
        try processes(&r, inst.module.discrete);
        // IEEE 1364-2005 §15: the instance's timing checks, bound to the
        // slots their events name, in a `.v` run and in the digital half of
        // a mixed-signal design alike.
        try tchk.compileChecks(&r, inst.module.timing_checks);
    } else {
        const p = e.procs.items[g - e.insts.items.len];
        r.scope = p.scope;
        try initVars(&r, p.vars);
        try processes(&r, p.blocks);
    };
    // Last, each ahead of the rest, so the first in source order runs first.
    var left = r.early.items.len;
    while (left > 0) {
        left -= 1;
        try exec.enqueueFirst(&r, .{ .run_process = r.early.items[left] });
    }
    // A.6.5's `disable` names a block that needs no declaration before its
    // use (it may be in another process), so the ranges are bound here, once
    // every process has a pc range.
    // A block is looked for through the enclosing scopes (§12.7); a name
    // that is no block may be a task (§10.3), which has no single range.
    try bindDisables(&r, 0);
    // Pass two may have minted storage (an automatic task inlined at a call
    // site), so the slot space is final only now.
    r.growing = null;
    r.values = e.values.items;
    r.watch = try arena.alloc(std.EnumSet(Watcher), r.values.len);
    @memset(r.watch, .empty);
    // §14.3.3 a module path's source is watched for its last transition; a
    // §14.2.4 condition is type-checked in the scope that declares the path.
    for (r.net_cold.items) |c| for (c.paths) |p| {
        r.watch[p.src].insert(.path);
        if (p.cond != .none) {
            r.scope = p.scope;
            try compile.checkExpr(&r, p.cond);
        }
    };
    // §7.11 "a supply strength shall be reduced to a strong strength" across a
    // pass switch, and §3.7 a net type's own pull, hold from the start: a
    // switch group with no driver event (a supply net through an uncontrolled
    // `tran`) is resolved nowhere else. Every driver is still z here, so this
    // settles only what the net types assert, before anything watches a slot
    // (no event, which the native emitter would refuse). `rt.State.initIn`
    // does the same for its `%v` signals.
    for (r.nets, 0..) |n, k| if (r.netCold(n).trans.len != 0) try resolution.resolve(&r, @intCast(k));
    try tchk.solveNegative(&r);
    try tchk.arm(&r);
    try waiters.buildFanout(&r);
    try driver.arm(&r);
    r.slot_memo = try arena.alloc(SlotMemo, 1 << memo_bits);
    @memset(r.slot_memo, .{});
    r.diag_stage = .run;
    return r;
}

fn testConcatRunAllocation(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    try run(arena.allocator(), "module m; reg [7:0] a; initial begin a={{0{$signed(65'bz)}},{(1+1){4'b10xz}}}; $display(\"%b\",a); end endmodule", .{}, &bag, &output.writer);
    try std.testing.expectEqualStrings("10xz10xz\n", output.written());
}

test {
    _ = elab;
    _ = system;
    _ = @import("vcd.zig");
    _ = @import("evcd.zig");
    _ = @import("driver.zig");
    _ = tchk;
    _ = @import("sdf.zig");
}

// §9.9 gives initial and always constructs no order; VerA starts them as
// iverilog does, and this is iverilog's transcript: child instances' processes
// before their parent's (`processOrder`), a level-controlled always armed
// before the initial that writes its operand (`levelControlled`, ivtest
// pr1026), and a driver of `w[1]` leaving `w[0]` z from the start, so its
// first evaluation is no change of `w` (only the write at 2 is).
test "§9.9 time-0 process order is iverilog's" {
    try expectRun(
        \\module top;
        \\  reg [4:0] index; reg [31:0] foo; reg r; wire [1:0] w;
        \\  initial begin index = 0; #1 $display("foo=%b", foo); end
        \\  always @(*) begin foo = 32'b0; foo[index] = 1'b1; end
        \\  assign w[1] = r;
        \\  always @(w) $display("%0t w=%b", $time, w);
        \\  initial #2 r = 1;
        \\  a ua();
        \\  initial $display("top");
        \\endmodule
        \\module a; initial $display("a"); b ub(); endmodule
        \\module b; initial $display("b"); endmodule
    , "b\na\ntop\nfoo=00000000000000000000000000000001\n2 w=1z\n");
    // A timing control anywhere, a task call (which may wait) or a `wait`
    // keeps an always construct running.
    // A body that waits only on a later pass runs: three passes at time 0
    // without suspending, then `#1`.
    try expectRun("module m; integer n; initial n = 0; always begin if (n < 3) n = n + 1; else begin #1 $display(\"%0d\", n); $finish(0); end end endmodule", "3\n");
    try expectRun("module m; reg c; task t; #2 c = ~c; endtask initial begin c = 0; #5 $display(\"%b\", c); $finish(0); end always t; endmodule", "0\n");
    try expectRun("module m; reg c; initial begin c = 0; #3 c = 1; #1 $display(\"%b\", c); $finish(0); end always begin if (c) wait (!c); else #1; end endmodule", "1\n");
}

test "a zero-delay loop fails by name instead of hanging at one tick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\module m; reg a; initial a = 0; always #0 a = ~a; endmodule
    , .{}, &bag, &output.writer);
    r.event_budget.max = 1000;
    try std.testing.expectError(error.DigitalFailed, r.runUntil(std.math.maxInt(Tick)));
    try std.testing.expectEqual(@as(Tick, 0), r.scheduler.now);
}

test "an always construct with no timing control runs until the event budget ends it (§9.9.2, VD-133)" {
    // Oracle: §9.9.2's own example, `always areg = ~areg;`, which "creates a
    // zero-delay infinite loop" (ISP RAS test_09_09_02_1): legal source.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\module m; reg areg; initial areg = 0; always areg = ~areg; endmodule
    , .{}, &bag, &output.writer);
    r.event_budget.max = 1000;
    try std.testing.expectError(error.DigitalFailed, r.runUntil(std.math.maxInt(Tick)));
    try std.testing.expectEqual(@as(Tick, 0), r.scheduler.now);
    try std.testing.expect(std.mem.indexOf(u8, bag.at(0).message, "keeps simulation time from advancing") != null);
}

test "an untimed loop inside one process fails by name instead of hanging at one tick" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\module m; reg x; initial forever x = 1; endmodule
    , .{}, &bag, &output.writer);
    r.event_budget.max = 1000;
    try std.testing.expectError(error.DigitalFailed, r.runUntil(std.math.maxInt(Tick)));
    try std.testing.expectEqual(@as(Tick, 0), r.scheduler.now);
    try std.testing.expect(std.mem.indexOf(u8, bag.at(0).message, "more than 1000 loop iterations and events at time 0") != null);
}

test "a finite untimed loop under the budget runs to its end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\module m; integer i, n; initial begin n = 0; for (i = 0; i < 900; i = i + 1) n = n + 1; end endmodule
    , .{}, &bag, &output.writer);
    r.event_budget.max = 1000;
    _ = try r.runUntil(std.math.maxInt(Tick));
    try std.testing.expectEqual(@as(?i64, 900), r.values[r.slotOf("n").?].asInt());
}

test "many runUntil calls over a switch-joined net and an extended dump stop growing the run arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The mixed runner calls runUntil once per tick; every toggle of `c`
    // resolves the `tran` group again and changes the dumped port's state.
    const source = try arena.allocator().print(
        \\`timescale 1ns/1ns
        \\module top; reg c; wire a, b; assign a = c; tran t(a, b); leaf u(b);
        \\initial c = 0; always #1 c = ~c;
        \\initial $dumpports(u, ".zig-cache/tmp/{s}/p.evcd");
        \\endmodule
        \\module leaf(p); inout p; wire p; endmodule
    , .{tmp.sub_path});
    var r = try elaborate(arena.allocator(), source, .{ .io = std.testing.io }, &bag, &output.writer);
    var at_warm: usize = 0;
    for (1..2001) |k| {
        _ = try r.runUntil(k);
        if (k == 200) at_warm = arena.queryCapacity();
    }
    try std.testing.expectEqual(at_warm, arena.queryCapacity());
}

test "elaborate + runUntil step the engine one bounded horizon at a time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [3:0] code;
        \\initial begin code = 4'd1; #10 code = 4'd5; #10 code = 4'd9; end
        \\endmodule
    , .{}, &bag, &output.writer);
    const at = r.slotOf("code").?;
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("nope"));
    // Nothing has run: the reg is still §3.2's x.
    try std.testing.expect(r.values[at].hasUnknown());
    _ = try r.runUntil(0);
    try std.testing.expectEqual(@as(?i64, 1), r.values[at].asInt());
    try std.testing.expectEqual(@as(?Tick, 10), r.scheduler.peekTime());
    _ = try r.runUntil(9);
    try std.testing.expectEqual(@as(?i64, 1), r.values[at].asInt());
    _ = try r.runUntil(10);
    try std.testing.expectEqual(@as(?i64, 5), r.values[at].asInt());
    _ = try r.runUntil(std.math.maxInt(Tick));
    try std.testing.expectEqual(@as(?i64, 9), r.values[at].asInt());
    try std.testing.expectEqual(@as(?Tick, null), r.scheduler.peekTime());
}

test "an error raised once elaboration finished, between runUntil calls too, is the run's (#72)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    // An elaboration failure is still a compile error. It has its own bag:
    // `elaborate` refuses to start on a bag that has already failed.
    var compile_bag = diag.Bag.init(arena.allocator());
    try std.testing.expectError(error.DigitalFailed, elaborate(arena.allocator(), "module m; initial disable nope; endmodule\n", .{}, &compile_bag, &output.writer));
    try std.testing.expectEqual(diag.Stage.lower, compile_bag.at(compile_bag.count() - 1).stage);
    var text = std.Io.Writer.Allocating.init(arena.allocator());
    try diag.render(&compile_bag, &text.writer, .{});
    try std.testing.expect(std.mem.find(u8, text.written(), "could not compile due to") != null);
    var bag = diag.Bag.init(arena.allocator());
    var r = try elaborate(arena.allocator(), "module m; reg a; initial #5 a = 1; endmodule\n", .{}, &bag, &output.writer);
    _ = try r.runUntil(1);
    // What a VPI host raises between two `runUntil` calls (`vpi/run.zig`
    // `timeSteps`'s callback-pass cap), and after the last one.
    try std.testing.expectEqual(error.DigitalFailed, r.fail(0, "between", .{}));
    try std.testing.expectEqual(diag.Stage.run, bag.at(bag.count() - 1).stage);
    _ = try r.runUntil(std.math.maxInt(Tick));
    try std.testing.expectEqual(error.DigitalFailed, r.fail(0, "after", .{}));
    try std.testing.expectEqual(diag.Stage.run, bag.at(bag.count() - 1).stage);
    // The run's two errors are no compile failure. A bag holding both kinds
    // counts the compile errors only: tests/unit.zig's "render: a
    // run-time error is no compile failure (#72)".
    var run_text = std.Io.Writer.Allocating.init(arena.allocator());
    try diag.render(&bag, &run_text.writer, .{});
    try std.testing.expect(bag.failed());
    try std.testing.expect(std.mem.find(u8, run_text.written(), "could not compile") == null);
}

test "IEEE 1364 §5.2.1 a bit-select names its bit against the declared range" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [3:0] a; reg [0:3] b; wire [3:0] w; wire hi;
        \\integer i;
        \\assign w = a;
        \\assign hi = w[3];
        \\initial begin
        \\  a = 4'b1010; b = 4'b1000; i = 1;
        \\  #0 $display("%b%b %b %b%b %b %b", a[1], a[0], hi, b[0], b[3], a[i], a[4]);
        \\end
        \\endmodule
    , "10 1 10 1 x\n");
}

test "§12.4 a downward hierarchical reference reads the named instance's net" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module child(a, y);
        \\input a;
        \\output y;
        \\wire a, y;
        \\assign y = ~a;
        \\endmodule
        \\module top;
        \\reg r;
        \\wire w;
        \\child u(r, w);
        \\initial begin r = 1'b0; #0 $display("a=%b y=%b", u.a, u.y); end
        \\endmodule
    , "a=0 y=1\n");
}

test "§12.4 a hierarchical path descends one instance per part" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module leaf(a);
        \\input a;
        \\wire a;
        \\endmodule
        \\module mid(a);
        \\input a;
        \\wire a;
        \\leaf d(a);
        \\endmodule
        \\module top;
        \\reg r;
        \\mid u(r);
        \\initial begin r = 1'b1; #0 $display("%b", u.d.a); end
        \\endmodule
    , "1\n");
}

// §10: an untimed task runs in place, a timed one suspends its caller; a
// static task's storage outlives its activation and an automatic one's does
// not; recursion gets a frame per activation; `disable` of a task ends every
// activation, and the caller resumes after its enable.
test "§10 tasks and functions: copy in/out, lifetimes, recursion, disable" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\reg [7:0] a, b, c; integer n, tails;
        \\function automatic integer fib(input integer k);
        \\  fib = k < 2 ? k : fib(k - 1) + fib(k - 2);
        \\endfunction
        \\function [3:0] low(input [7:0] x); low = x; endfunction
        \\task count(input clr, output [7:0] o); reg [7:0] kept; begin if (clr) kept = 0; kept = kept + 1; o = kept; end endtask
        \\task late(input [7:0] i, output [7:0] o); #2 o = i + 1; endtask
        \\task automatic dive(input integer d); begin if (d == 0) disable dive; else dive(d - 1); tails = tails + 1; end endtask
        \\initial begin
        \\  n = fib(10); a = low(8'hab) + 8'h10;
        \\  count(1'b1, b); count(1'b0, b);
        \\  tails = 0; dive(3);
        \\  late(a, c);
        \\  $display("%0d %h %0d %h %0d %0d", n, a, b, c, tails, $time);
        \\end
        \\endmodule
    , "55 1b 2 1c 0 2\n");
}

// §10.2.3: each activation of an automatic task that suspends and reaches
// itself has its own storage, even while another caller's activations are
// alive; and an actual that is the callee's own formal is read before the
// new activation's frame is initialized.
test "§10.2.3 recursive timed automatic tasks and a formal passed to itself" {
    try expectRun(
        \\`timescale 1ns/1ns
        \\module m;
        \\integer ra, rb;
        \\task automatic sum(input integer n, input integer d, output integer t);
        \\  integer b; begin if (n == 0) t = 0; else begin #d sum(n - 1, d, b); t = b + n; end end
        \\endtask
        \\function automatic integer f(input integer n, input integer k); f = k == 0 ? n : f(n, k - 1); endfunction
        \\initial begin sum(2, 2, ra); $display("%0d ra=%0d", $time, ra); end
        \\initial begin sum(3, 3, rb); $display("%0d rb=%0d f=%0d", $time, rb, f(7, 3)); end
        \\endmodule
    , "4 ra=3\n9 rb=6 f=7\n");
}

// §10.2.1: an automatic task's variables are each activation's own, so a
// write in one activation is no change an event control in another sees
// (`@f` in `fact`, ivtest recursive_task), and an expression term over them
// is the waiter's own, read when it arms (`@(arr[j])` after `j` is written,
// ivtest automatic_task3). iverilog prints this transcript.
test "§10.2.1 an event control over automatic variables reads its own activation" {
    try expectRun(
        \\module m;
        \\reg [7:0] arr [0:1];
        \\integer r;
        \\task automatic fact(input integer n, output integer f);
        \\  integer t;
        \\  fork
        \\    begin if (n > 1) fact(n - 1, t); else t = 1; #1 f = n * t; end
        \\    @f $display("%0t f=%0d", $time, f);
        \\  join
        \\endtask
        \\task automatic t(input [7:0] v);
        \\  integer j;
        \\  begin j = v - 1; @(arr[j]) $display("%0t v=%0d", $time, v); end
        \\endtask
        \\initial arr[1] = 7;
        \\initial #10 arr[0] = 3;
        \\initial t(1);
        \\initial #1 t(2);
        \\initial begin fact(3, r); $display("%0t r=%0d", $time, r); end
        \\endmodule
    , "1 f=1\n2 f=2\n3 f=6\n3 r=6\n10 v=1\n");
}

// §6.2.1: the initializer is an initial-block assignment at time 0, so a
// net assigned from the variable tracks it, and a later write replaces it.
test "§6.2.1 a variable declaration assignment is a time-0 write" {
    try expectRun(
        \\module m;
        \\reg [7:0] v = 2*3+1; integer i = -5; time t = 64'd9;
        \\wire [7:0] w = v;
        \\initial begin #1 $display("%0d %0d %0d %0d", v, w, i, t); v = 12; #1 $display("%0d", w); end
        \\endmodule
    , "7 7 -5 9\n12\n");
}

test "§19.8 no timescale is the simulator's own unit, not an error" {
    // "If there is no `timescale specified or it has been reset by a
    // `resetall directive, the time unit and precision are simulator-specific."
    try expectRun("module m; wire w; reg a; assign #3 w = a; initial begin a = 1; #2 $display(\"%b %0d\", w, $time); #1 $display(\"%b %t\", w, $time); end endmodule", "x 2\n1                    3\n");
    try expectRun("`timescale 1ns/1ps\n`resetall\nmodule m; initial #1 $display(\"%0d %g\", $time, $realtime); endmodule", "1 1\n");
}

test "timescale provenance rejects malformed or later directives" {
    // The preprocessor refuses all three (E0142), so the message names the
    // directive rather than the consumer that could not use it.
    try expectRejected("`timescale 2ns/1ps\nmodule m; initial #1 ; endmodule", "is not a `timescale");
    try expectRejected("`timescale 1ns/1ps junk\nmodule m; initial #1 ; endmodule", "is not a `timescale");
    try expectRejected("`timescale 1ps/1ns\nmodule m; initial #1 ; endmodule", "coarser than the time unit");
    try expectRejected("`timescale 1ns/1ns\nmodule m; initial #(128'd1) ; endmodule", "wider than 64");
    // §19.8: "It shall be an error if some modules have a `timescale
    // specified and others do not": here `resetall takes it from `top`.
    try expectRejected("`timescale 1ns/1ns\nmodule a; endmodule\n`resetall\nmodule top; a u(); endmodule", "others do not");
    try expectRejected("`timescale 1ns/1ps\nmodule top;\n`timescale 1us/1ns\nendmodule", "outside a module definition");
}

// IEEE 1364 §19.8: a `timescale applies to the modules that follow it, until
// the next one; the simulation's tick is the finest precision of all (1 ps).
// `top`'s #3 is 3 ns. `sub`'s #0.004 is 4 ns, which its $realtime reads in its
// own 1 us unit as 0.004; its #1 more is 1004 ns, and $time rounds 1.004 us to
// 1. A directive after the last module applies to nothing and is not an error.
test "§19.8 each module definition runs in the timescale written before it" {
    try expectRun(
        \\`timescale 1ns/1ps
        \\module top;
        \\  sub u();
        \\  initial #3 $display("top %0d", $time);
        \\endmodule
        \\`timescale 1us/1ps
        \\module sub;
        \\  initial begin #0.004 $display("sub %g", $realtime); #1 $display("sub %0d", $time); end
        \\endmodule
        \\`timescale 1ms/1us
    , "top 3\nsub 0.004\nsub 1\n");
}

test "VAMS §7.3.6.4 an analog variable a continuous assign reads is declared and written by the coordinator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var out = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(), "module m; real level; wire hi; assign hi = level > 0.5; endmodule\n", .{ .mixed = .{ .top = "m", .timescales = &.{}, .reads = &.{"level"} } }, &bag, &out.writer);
    _ = try r.runUntil(0);
    try r.a2dWrite(r.slotOf("level").?, 0.75, false);
    _ = try r.runUntil(0);
    try std.testing.expectEqual(@as(?i64, 1), r.values[r.slotOf("hi").?].asInt());
}

test "source concat allocation failures clean up preflight and execution arenas" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testConcatRunAllocation, .{});
}

test "VecRange.position counts from the least significant declared bit" {
    const down: VecRange = .{ .msb = 7, .lsb = 0 };
    const up: VecRange = .{ .msb = 0, .lsb = 7 };
    const off: VecRange = .{ .msb = 10, .lsb = 3 };
    try std.testing.expectEqual(@as(i64, 7), down.position(7));
    try std.testing.expectEqual(@as(i64, 0), down.position(0));
    try std.testing.expectEqual(@as(i64, 7), up.position(0));
    try std.testing.expectEqual(@as(i64, 0), up.position(7));
    try std.testing.expectEqual(@as(i64, 0), off.position(3));
    try std.testing.expectEqual(@as(i64, 7), off.position(10));
    // Outside the range: a position outside [0, width).
    try std.testing.expectEqual(@as(i64, -1), off.position(2));
    try std.testing.expectEqual(@as(i64, 8), off.position(11));
    // §5.2.1: a distant index saturates rather than overflowing.
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), off.position(std.math.minInt(i64)));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), up.position(std.math.minInt(i64)));
}

test SlotNets {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var t: SlotNets = .{};
    try std.testing.expectEqual(@as(?u32, null), t.get(0));
    try t.put(a, 3, 7);
    // The rows it grew over are variables' slots, not net 0's.
    try std.testing.expectEqual(@as(?u32, null), t.get(0));
    try std.testing.expectEqual(@as(?u32, null), t.get(2));
    try std.testing.expectEqual(@as(?u32, 7), t.get(3));
    try std.testing.expectEqual(@as(?u32, null), t.get(4));
    try t.put(a, 1, 0);
    try std.testing.expect(t.contains(1));
    try std.testing.expectEqual(@as(?u32, 0), t.get(1));
    try std.testing.expect(!t.contains(2));
}

test netRuns {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Pair = struct { a: u32, b: u32 };
    const rows = [_]Pair{ .{ .a = 2, .b = 0 }, .{ .a = 0, .b = 2 }, .{ .a = 2, .b = 1 } };
    // Grouped by `a`: net 0 holds row 1, net 1 nothing, net 2 rows 0 and 2,
    // each run in row order.
    const by_a = try netRuns(a, 3, rows.len, &rows, struct {
        fn each(r: anytype, _: usize) u32 {
            return r.a;
        }
    }.each, 1);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 1, 3 }, by_a.start);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0, 2 }, by_a.items);
    // Two nets per row (a pass switch's two terminals): a row is in each
    // net's run once.
    const both = try netRuns(a, 3, rows.len * 2, &rows, struct {
        fn each(r: anytype, k: usize) u32 {
            return if (k == 0) r.a else r.b;
        }
    }.each, 2);
    try std.testing.expectEqualSlices(u32, &.{ 0, 2, 3, 6 }, both.start);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 0, 1, 2 }, both.items);
}

test PathKey {
    var buf = "u.p".*;
    const key: PathKey = .{ .scope = 1, .path = "u.p" };
    const ctx: PathKey.Ctx = .{};
    // The path's bytes are the key, not where they live.
    try std.testing.expect(ctx.eql(key, .{ .scope = 1, .path = &buf }));
    try std.testing.expectEqual(ctx.hash(key), ctx.hash(.{ .scope = 1, .path = &buf }));
    try std.testing.expect(!ctx.eql(key, .{ .scope = 2, .path = "u.p" }));
    try std.testing.expect(!ctx.eql(key, .{ .scope = 1, .path = "u.q" }));
}

test "§12.7 a name resolves outward through blocks and stops at the instance" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    const r = try elaborate(arena.allocator(),
        \\module m; reg a; initial begin : b reg c; c = a; end endmodule
    , .{}, &bag, &output.writer);
    const a_str = r.file.strings.find("a").?;
    const b_str = r.file.strings.find("b").?;
    const c_str = r.file.strings.find("c").?;
    const block = r.instances.get(.{ .scope = 0, .str = b_str }).?;
    // From the block, `a` is the instance's; from the instance, `c` is no
    // name at all (§12.7: a block's names are not its parent's).
    try std.testing.expectEqual(r.slotOf("a"), r.lookup(block, a_str));
    try std.testing.expect(r.lookup(block, c_str) != null);
    try std.testing.expectEqual(@as(?u32, null), r.lookup(0, c_str));
    try std.testing.expectEqual(@as(?u32, null), r.slotOf("c"));
    // A block shares its instance's parameters and is part of it.
    try std.testing.expectEqual(@as(u32, 0), r.instanceOf(block));
    try std.testing.expectEqual(@as(u32, 0), r.specOf(block));
    try std.testing.expect(isRoot(&r, 0));
}

test "§12.1.1 every module nothing instantiates is a root of its own" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = diag.Bag.init(arena.allocator());
    var output = std.Io.Writer.Allocating.init(arena.allocator());
    var r = try elaborate(arena.allocator(),
        \\module a; reg x; endmodule
        \\module b; reg y; endmodule
    , .{}, &bag, &output.writer);
    try std.testing.expectEqual(@as(usize, 2), r.roots.len);
    for (r.roots) |s| try std.testing.expect(isRoot(&r, s));
    // From inside one root, the other is found by its module's name.
    r.scope = r.roots[0];
    const other = r.upward(r.scope_info.items[r.roots[1]].name).?;
    try std.testing.expectEqual(r.roots[1], other);
}

test "§3.3 a packed range wider than u32 bits is refused, not wrapped" {
    try expectRejected("module m; reg [4294967295:0] a; endmodule", "packed range is outside the supported u32 width");
}

test "A.2.2.3 a driver's variable delay is read when the driver schedules" {
    // y follows x 3 units late, then 1 unit late once d is 1: at t5, where
    // the first delay would still hold it until t6.
    try expectRun(
        \\module m;
        \\reg [31:0] d; reg x; wire y;
        \\assign #d y = x;
        \\initial begin
        \\  d = 3; x = 0;
        \\  #2 $display("%b", y);
        \\  #1 $display("%b", y);
        \\  d = 1; x = 1;
        \\  #2 $display("%b", y);
        \\  $finish(0);
        \\end
        \\endmodule
    , "x\n0\n1\n");
}

test "§12.4.1 a genvar-indexed hierarchical name finds its iteration's scope unspelled" {
    // No `g[0]` or `g[1]` appears in the source.
    try expectRun(
        \\module m;
        \\  genvar i;
        \\  generate for (i = 0; i < 2; i = i + 1) begin : g reg r; end endgenerate
        \\  generate for (i = 0; i < 2; i = i + 1) begin : s
        \\    initial begin g[i].r = i; #1 $display("%0d %b", i, g[i].r); end
        \\  end endgenerate
        \\endmodule
    , "0 0\n1 1\n");
    try expectRejected(
        \\module m;
        \\  genvar i;
        \\  generate for (i = 0; i < 2; i = i + 1) begin : g reg r; end endgenerate
        \\  generate for (i = 1; i < 3; i = i + 1) begin : s initial g[i].r = 0; end endgenerate
        \\endmodule
    , "`g[2]`: an instance select out of range");
}

test "§4.6.5 uwire drivers of disjoint bits are legal" {
    try expectRun(
        \\module m;
        \\uwire [3:0] w;
        \\assign w[1:0] = 2'b01; assign w[3:2] = 2'b10;
        \\initial #1 $display("%b", w);
        \\endmodule
    , "1001\n");
    try expectRejected("module m; uwire [3:0] w; assign w[2:0] = 0; assign w[3:2] = 0; endmodule", "single driver per bit");
}

test "§7.9 a uwire with two drivers is an error, not a resolution" {
    try expectRejected("module m; uwire w; assign w = 1'b0; assign w = 1'b1; endmodule", "a uwire net accepts a single driver per bit");
}

test "a name is visible from its declaration on (iverilog's decl_before_use)" {
    // A variable or localparam read before it is declared is refused; a
    // block's later local leaves the outer name in view, and §4.5's
    // implicit net is the scope's from its start.
    try expectRejected("module m; initial begin v = 1; end reg v; endmodule", "a name is used before its declaration");
    try expectRejected("module m; initial $display(\"%b\", w); localparam w = 8'hAA; endmodule", "a name is used before its declaration");
    try expectRun("module m; integer w = 5; initial begin : b $display(\"%0d\", w); end endmodule", "5\n");
    try expectRun("module m; buf (a, c); buf (c, 1'b1); initial #1 $display(\"%b\", a); endmodule", "1\n");
}

test "§7.6 a pass switch's variable delay is read when its control changes" {
    // iverilog's rise_fall_delay3: tranif1 #(d, 1) turns on d after en rises.
    try expectRun("`timescale 1ns/1ns\nmodule m; reg [7:0] d = 3; reg en; wire i = 1; wire o; tranif1 #(d, 1) t(o, i, en); initial begin en = 0; #1 en = 1; #2 $display(\"%b\", o); #1 $display(\"%b\", o); end endmodule", "z\n1\n");
}
