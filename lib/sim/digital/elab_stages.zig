//! A parsed design and its `Run` in, the same `Run` elaborated and queued at time 0 out: the stages `root.elaborate` runs in order, one transformation each.
//! Cites: IEEE 1364-2005 §4.2.1, §6.1, §7.6, §7.9, §7.11, §8.5, §9.9, §10, §12.1.1, §12.1.3, §14.2.4, §14.3.3, §15, §17.3, §19.8; VAMS §7.8.4.
//!
//! Contents:
//! - `pub const Parsed = struct`
//! - `pub const Top = struct`
//! - `pub fn parse(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag) Error!Parsed`
//! - `pub fn top(r: *Run, opts: Options) Error!Top`
//! - `pub fn timescales(r: *Run, t: Top, times: []const Front.directive_events.TimescaleEvent, tags: []const Front.token.Tag) Error!void`
//! - `pub fn scopes(r: *Run, file: *Ast.SourceFile, t: Top, opts: Options) Error!void`
//! - `pub fn declare(r: *Run, e: *elab.Elab, t: Top, opts: Options) Error!void`
//! - `pub fn drivers(r: *Run, e: *const elab.Elab, t: Top) Error!void`
//! - `pub fn knownZ(r: *Run) Error!void`
//! - `pub fn switches(r: *Run, e: *const elab.Elab) Error!void`
//! - `pub fn netTables(r: *Run, e: *const elab.Elab) Error!void`
//! - `pub fn queueProcesses(r: *Run, e: *const elab.Elab) Error!void`
//! - `pub fn arm(r: *Run, e: *const elab.Elab) Error!void`
//! - `N.expr(w: @This(), x: Ast.ExprId, _: Ast.SourceFile.Edge) Error!void`
//! - `N.stmt(w: @This(), st: Ast.StmtId) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const diag = @import("diag");
const Time = @import("../time.zig");
const compile = @import("compile.zig");
const evaluate = @import("evaluate.zig");
const exec = @import("exec.zig");
const driver = @import("driver.zig");
const elab = @import("elab.zig");
const waiters = @import("waiters.zig");
const resolution = @import("resolution.zig");
const tchk = @import("tchk.zig");
const binding = @import("bind.zig");
const net = @import("net.zig");
const Driver = net.Driver;
const Tran = net.Tran;
const filled = net.filled;
const setBit = net.setBit;
const steps = @import("elab_steps.zig");
const run_rows = @import("run_rows.zig");
const root = @import("root.zig");
const Run = root.Run;
const Error = root.Error;
const Options = root.Options;
const Type = compile.Type;

/// The preprocessed text, its tokens and the parse `elaborate` reads.
pub const Parsed = struct {
    pp: Front.preprocessor.Output,
    starts: []const u32,
    tags: []const Front.token.Tag,
    /// Arena-owned: the returned `Run` points at it. An overlay of the
    /// parse, which elaboration writes; the parse itself stays as parsed.
    file: *Ast.SourceFile,
};

/// The design's first root module, `m`, and every top-level module's
/// index into `file.modules` (`tops[0]` is `m`'s; empty for a mixed run).
pub const Top = struct { m: *const Ast.ModuleDecl, tops: []const u32 };

/// Preprocesses (or, for a mixed run, takes as given), lexes and parses
/// `source`. A parse error still returns every recovered module, so the
/// `wreal` rule reads them; any error in `bag` then fails.
pub fn parse(arena: std.mem.Allocator, source: []const u8, opts: Options, bag: *diag.Bag) Error!Parsed {
    assert(source.len < std.math.maxInt(u32)); // Byte offsets are u32.
    const pp: Front.preprocessor.Output = if (opts.mixed) |mx| .{
        .text = source,
        .directives = .{ .timescales = try steps.mixedTimescales(arena, mx.timescales) },
    } else Front.preprocessor.process(arena, source, .{ .file_name = opts.file_name, .include_dirs = opts.include_dirs, .defines = opts.defines, .std_defs = false, .more = more: {
        const more = try arena.alloc(Front.preprocessor.File, opts.more.len);
        for (opts.more, more) |u, *f| f.* = .{ .name = u.name, .text = u.text };
        break :more more;
    }, .bag = bag, .std_1364 = @backingInt(opts.language) < @backingInt(Front.keyword.KeywordSet.vams_2_3), .protect_keys = opts.protect_keys }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.PreprocessFailed => error.DigitalFailed,
    };
    var tokens = try Front.lexer.tokenize(arena, pp.text, null);
    var parser = Front.Parser.Parser.init(arena, pp.text, tokens.items(.tag), tokens.items(.start), bag);
    parser.digital = true;
    parser.setLanguage(opts.language);
    const parsed = try arena.create(Ast.SourceFile);
    parsed.* = parser.parseSourceFile() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => parser.file,
    };
    const file = try arena.create(Ast.SourceFile);
    file.* = @as(*const Ast.SourceFile, parsed).overlay(.{});
    try Front.wreal.check(file, tokens.items(.start), bag);
    if (bag.failed()) return error.DigitalFailed;
    assert(tokens.len > 0); // The lexer ends every text with an eof token.
    assert(tokens.items(.start).len == tokens.items(.tag).len);
    return .{ .pp = pp, .starts = tokens.items(.start), .tags = tokens.items(.tag), .file = file };
}

/// The module the design elaborates from: a mixed run's named root, else
/// §12.1.1's top-level modules (`elab.pickTops`). A file with analog
/// declarations, or none of its own, has no digital design.
pub fn top(r: *Run, opts: Options) Error!Top {
    const file = r.file;
    assert(r.starts.len > 0);
    if (opts.mixed) |mx| {
        for (file.modules) |*c| if (file.strings.eql(c.name, mx.top)) return .{ .m = c, .tops = &.{} };
        return r.fail(0, "the mixed-signal root module is not in the source", .{});
    }
    if (file.modules.len == 0 or file.disciplines.len != 0 or file.natures.len != 0 or file.paramsets.len != 0 or file.connectrules.len != 0) return r.fail(0, "digital execution requires ordinary modules and no analog declarations", .{});
    const tops = try elab.pickTops(r, file.modules);
    assert(tops.len >= 1);
    return .{ .m = &file.modules[tops[0]], .tops = tops };
}

/// IEEE 1364 §19.8: a `timescale applies to "all modules that follow this
/// directive until another `timescale compiler directive is read", so each
/// definition takes the last directive before it. A null value is §19.6's
/// `resetall, which returns to "none specified", the simulator-specific
/// default. The preprocessor refuses a malformed directive where it is
/// written (E0142). A mixed design's first timescale is moved to offset 0
/// (`steps.mixedTimescales`). Sets `r.time`.
pub fn timescales(r: *Run, t: Top, times: []const Front.directive_events.TimescaleEvent, tags: []const Front.token.Tag) Error!void {
    const file = r.file;
    assert(tags.len == r.starts.len);
    const Local = struct { unit: Time.Quantum = run_rows.default_quantum, precision: Time.Quantum = run_rows.default_quantum, set: bool = false };
    var finest: Time.Quantum = run_rows.default_quantum;
    var set: usize = 0;
    const locals = try r.arena.alloc(Local, file.modules.len);
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
            const ts = event.value orelse {
                l.* = .{};
                continue;
            };
            l.* = .{
                .unit = Time.Quantum.fromSeconds(ts.unit) catch return r.fail(def.main_tok, "unsupported time unit", .{}),
                .precision = Time.Quantum.fromSeconds(ts.precision) catch return r.fail(def.main_tok, "unsupported time precision", .{}),
                .set = true,
            };
        }
        set += @intFromBool(l.set);
        if (@backingInt(l.precision) < @backingInt(finest)) finest = l.precision;
    }
    if (set != 0 and set != file.modules.len) return r.fail(t.m.main_tok, "§19.8: it shall be an error if some modules have a `timescale specified and others do not", .{});
    // "The smallest time_precision argument of all the `timescale compiler
    // directives in the design determines the precision of the time unit of
    // the simulation": that is the scheduler's tick, and every module's delays
    // are scaled to it.
    const module_times = try r.arena.alloc(root.ModuleTime, file.modules.len);
    for (file.modules, locals, module_times) |*def, l, *mt| mt.* = .{
        .scale = Time.Scale.init(l.unit, l.precision, finest) catch return r.fail(def.main_tok, "invalid timescale", .{}),
        .unit_exp = @backingInt(l.unit),
    };
    r.time.modules = module_times;
    const root_time = module_times[elab.defOf(r, t.m)];
    r.time.scale = root_time.scale;
    r.time.unit_exp = root_time.unit_exp;
    // §17.3: "the default ... is the smallest time precision argument of
    // all the `timescale compiler directives in the source description".
    r.time.format.units = @backingInt(finest);
    r.time.finest = r.time.format.units;
    assert(module_times.len == file.modules.len); // One scale per definition.
    assert(r.time.finest <= root_time.unit_exp);
}

/// The scope tree's roots: `t.m` at scope 0, then (IEEE 1364-2005 §12.1.1)
/// every other top-level module, scoped before any instance so a defparam
/// in it that names another top's parameter (§12.2.1) is registered when
/// that parameter is set; each root's §13 configuration; and a mixed run's
/// VAMS §7.8.4 bridge segments, interned into `file`, the `Run`'s own.
pub fn scopes(r: *Run, file: *Ast.SourceFile, t: Top, opts: Options) Error!void {
    assert(file == r.file);
    const arena = r.arena;
    assert(r.hier.scopes.items.len == 0);
    try r.hier.scopes.append(arena, .{ .parent = 0, .name = t.m.name, .def = elab.defOf(r, t.m) });
    if (t.tops.len > 1) {
        const roots = try arena.alloc(u32, t.tops.len);
        roots[0] = 0;
        for (t.tops[1..], roots[1..]) |d, *s| {
            const other = &file.modules[d];
            s.* = try elab.newScope(r, other.main_tok);
            try r.hier.scopes.append(arena, .{ .parent = s.*, .name = other.name, .def = d });
            for (other.defparams) |dp| try elab.bindDefparam(r, s.*, dp, other.instances);
        }
        r.hier.roots = roots;
    }
    for (r.hier.roots, 0..) |s, k| if (r.hier.binds.get(0)) |b| if (b.cfg) |c|
        try r.hier.binds.put(arena, s, binding.rootCtx(r, c, if (t.tops.len == 0) elab.defOf(r, t.m) else t.tops[k]));
    if (opts.mixed) |mx| {
        // VAMS §7.8.4 each bridge's segment, spelled as the flatten spells it
        // (`bridged` declares it), for the connections re-pointed at it.
        const segs = try arena.alloc(Ast.ExprId, mx.inserts.len);
        for (mx.inserts, segs) |row, *x| {
            // Every other name a row holds is the source's own.
            _ = try file.intern(arena, row.name);
            x.* = try file.exprs.add(arena, .{
                .tag = .ident,
                .main_tok = t.m.main_tok,
                .str = try file.intern(arena, try arena.print("{s}.{s}", .{ row.name, row.lower_port })),
            });
        }
        r.decls.inserts = mx.inserts;
        r.decls.insert_segs = segs;
    }
    assert(r.hier.scopes.items.len >= r.hier.roots.len);
    assert(r.hier.scopes.items[0].name == t.m.name);
}

/// Pass one: storage. Variables, array elements and nets share one slot
/// space, so one `store` publishes all three and wakes the same event
/// waiters. §6.2.2 elaboration walks the instance tree parent-first, which
/// is what lets a port connection resolve against nets that already exist.
/// Then the defparams are checked against the whole hierarchy, every
/// `--param` is checked against a top (a misspelt one would otherwise run
/// the default design), and the driver, net and signal tables are published.
pub fn declare(r: *Run, e: *elab.Elab, t: Top, opts: Options) Error!void {
    const file = r.file;
    const arena = r.arena;
    assert(r.hier.scopes.items.len >= 1);
    // Allocated before pass one: a bound or a parameter is typed and folded
    // while the slot space is still growing (`Run.constant`).
    r.typing.types = try arena.alloc(Type, file.exprs.len());
    r.typing.state = try arena.alloc(root.TyState, file.exprs.len());
    @memset(r.typing.state, .untyped);
    r.typing.sys_calls = try arena.alloc(?compile.SysFn, file.exprs.len());
    @memset(r.typing.sys_calls, null);
    r.growing = &e.values;
    try elab.declare(r, e, t.m, 0, &.{}, &.{}, 0);
    if (t.tops.len > 1) for (r.hier.roots[1..], t.tops[1..]) |s, d| try elab.declare(r, e, &file.modules[d], s, &.{}, &.{}, 0);
    try elab.checkDefparams(r);
    for (opts.params) |o| {
        // `tops[0]`, when there are tops, is `m`.
        const known = steps.topDeclares(file, t.m, o.name) or for (t.tops) |d| {
            if (steps.topDeclares(file, &file.modules[d], o.name)) break true;
        } else false;
        if (!known) return r.fail(t.m.main_tok, "--param {s}: no top-level module declares a parameter `{s}`", .{ o.name, o.name });
    }
    try driver.segregate(r, e);
    r.values = e.values.items;
    r.netlist.nets = e.nets.items;
    r.netlist.cold = e.net_cold;
    r.netlist.signals = e.signals.items;
    try tchk.delayedDrivers(r, e);
    assert(r.values.len == e.values.items.len);
    assert(r.netlist.nets.len == e.nets.items.len);
}

/// Pass two, drivers: §6.1 one continuous assignment is one driver of one
/// net; §7.9 resolution needs them grouped, because every update reads all
/// of a net's drivers. Drivers compile first so that no driver's pc can also
/// be a process's resumption point: a `wait_event` resumes at its own pc
/// plus one, and every instruction from here on belongs to a process.
pub fn drivers(r: *Run, e: *const elab.Elab, t: Top) Error!void {
    const arena = r.arena;
    assert(r.netlist.nets.len == e.nets.items.len);
    if (e.wires.items.len > std.math.maxInt(u32)) return r.fail(t.m.main_tok, "too many continuous assignments", .{});
    r.netlist.drivers = try arena.alloc(Driver, e.wires.items.len);
    for (e.wires.items, 0..) |a, i| {
        r.scope = a.scope;
        var watched: std.ArrayList(u32) = .empty;
        switch (a.source) {
            .bridge => |b| try watched.append(arena, b.src),
            // §7.8.5 a gate re-evaluates on any input change, exactly as a
            // continuous assignment does on any operand change.
            .gate => |g| for (g.ins) |in| {
                try compile.checkExpr(r, in);
                const w = compile.typeOf(r, in).width;
                // A single gate reads a vector input's LSB: §7.1.6 sizes only
                // an array's terminals, and iverilog (gate_connect1) and the
                // other simulators read bit 0.
                if (g.lane != null and w != 1 and w != g.lanes) return r.exprFail(in, "a gate's input terminal is one bit, or one per instance of an array");
                try compile.sensitivity(r, in, &watched);
            },
            .mos => |mo| for ([_]Ast.ExprId{ mo.data, mo.gate }) |in| {
                try compile.checkExpr(r, in);
                // §7.1.6: an instance array's member reads its bit `lane`
                // of a vector terminal, as a gate does.
                const w = compile.typeOf(r, in).width;
                if (w != 1 and !(mo.lane != null and mo.lane.? < w)) return r.exprFail(in, "a switch terminal is one bit, or one per instance of an array");
                try compile.sensitivity(r, in, &watched);
            },
            .udp => |u| for (u.ins) |in| {
                try compile.checkExpr(r, in);
                if (compile.typeOf(r, in).width != 1 and u.lane == null) return r.exprFail(in, "a UDP's input terminal is one bit, or one per instance of an array");
                try compile.sensitivity(r, in, &watched);
            },
            .expr => |x| {
                try compile.checkExpr(r, x.e);
                try compile.sensitivity(r, x.e, &watched);
            },
            .pull => {},
        }
        r.netlist.drivers[i] = .{
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
            .current = try filled(arena, r.netlist.nets[a.net].resolved.width, false, .x),
            .s0 = a.s0,
            .s1 = a.s1,
            .delay = if (try steps.constantDelay(r, a.delay)) try r.declaredDelay3(a.delay, a.tok) else blk: {
                try r.netlist.driver_delays.put(arena, @intCast(i), a.delay);
                break :blk .{ .present = true };
            },
            .tok = a.tok,
        };
        // A UDP's output bit starts at its state: §8.5's initial value for a
        // sequential one, x for a combinational one until its first value.
        if (a.source == .udp) setBit(r.netlist.drivers[i].current, a.source.udp.out_bit orelse 0, a.source.udp.state);
        _ = try exec.enqueue(r, .{ .run_process = try compile.append(r, .{ .continuous = @intCast(i) }) }, null, false);
    }
    assert(r.netlist.drivers.len == e.wires.items.len);
    assert(r.program.code.items.len >= r.netlist.drivers.len); // One process per driver.
}

/// The bits a continuous assignment or a port window leaves at z (a
/// select's other bits, a constant z) are z from the start, not the x of a
/// value still to come: their first evaluation changes nothing there, so it
/// wakes nothing (iverilog's reading; a process armed before it would see a
/// change no driver made). Every net reads as x meanwhile, the value its
/// drivers have not yet given it: a bit is z here only when no operand value
/// can make it otherwise. The nets' own values are restored after.
pub fn knownZ(r: *Run) Error!void {
    assert(r.netlist.drivers.len == 0 or r.netlist.nets.len != 0);
    var scratch = std.heap.ArenaAllocator.init(r.arena);
    defer scratch.deinit();
    const saved = try scratch.allocator().alloc([]u64, r.netlist.nets.len);
    for (r.netlist.nets, saved) |n, *keep| {
        const planes = r.values[n.slot].planes;
        keep.* = try scratch.allocator().dupe(u64, planes);
        const x = try filled(scratch.allocator(), r.values[n.slot].width, false, .x);
        @memcpy(planes, x.planes);
    }
    defer for (r.netlist.nets, saved) |n, keep| @memcpy(r.values[n.slot].planes, keep);
    for (r.netlist.drivers) |*d| {
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
                if (steps.calls(&r.file.exprs, x.e)) continue;
                if (x.slice) |sl| {
                    const whole = try evaluate.eval(r, scratch.allocator(), x.e, sl.total);
                    const part = try filled(scratch.allocator(), d.current.width, false, .z);
                    evaluate.copyBits(part, 0, whole, sl.lo, d.current.width);
                    break :blk part;
                }
                break :blk try evaluate.evalFor(r, scratch.allocator(), x.e, r.slotType(r.netlist.nets[d.net].slot));
            },
            else => continue, // else: a gate, switch, UDP or pull starts at its own unknown
        };
        assert(first.width == d.current.width);
        for (0..d.current.width) |k| if (first.bit(@intCast(k)) == .z) setBit(d.current, @intCast(k), .z);
    }
}

/// §7.6: each net knows the pass switches on it, and a controlled one is a
/// process that re-resolves both sides whenever its control changes. A
/// switch's §7.6 delays are a variable read when the control changes, as a
/// driver's is (iverilog's rise_fall_delay3). A `mos` driver's data
/// terminal net reads strengths.
pub fn switches(r: *Run, e: *const elab.Elab) Error!void {
    const arena = r.arena;
    assert(r.netlist.drivers.len == e.wires.items.len);
    r.netlist.switches = try arena.alloc(Tran, e.trans.items.len);
    for (e.trans.items, r.netlist.switches, 0..) |t, *dst, i| {
        dst.* = t.tran;
        r.scope = t.scope;
        if (t.delay.rise != .none) dst.delay = if (try steps.constantDelay(r, t.delay)) try r.declaredDelay3(t.delay, t.tok) else blk: {
            try r.netlist.switch_delays.put(arena, @intCast(i), t.delay);
            break :blk .{ .present = true };
        };
        if (t.tran.ctrl == .none) continue;
        try compile.checkExpr(r, t.tran.ctrl);
        var watched: std.ArrayList(u32) = .empty;
        try compile.sensitivity(r, t.tran.ctrl, &watched);
        _ = try exec.enqueue(r, .{ .run_process = try compile.append(r, .{ .switch_ctrl = .{ .tran = @intCast(i), .slots = try r.program.addWords(r.arena, watched.items) } }) }, null, false);
    }
    for (r.netlist.drivers) |d| if (d.source == .mos and r.file.exprs.tag(d.source.mos.data) == .ident) {
        r.scope = d.scope;
        if (r.netlist.slot_nets.get(try r.slot(d.source.mos.data))) |n| r.netlist.nets[n].strength_read = true;
    };
    assert(r.netlist.switches.len == e.trans.items.len);
}

/// Each net's pass switches and drivers, in declaration order, as runs of
/// one flat array each (a counting sort), not a list per net: a large net
/// array is one net per element and almost none of them has either. Then
/// each net's first resolution, and §7.9 `uwire`, the UNRESOLVED net type: a
/// second driver is not a resolution question there, it is an error.
/// §4.6.5's "more than one driver" is per bit: drivers of disjoint selects
/// are legal.
pub fn netTables(r: *Run, e: *const elab.Elab) Error!void {
    const arena = r.arena;
    assert(r.netlist.switches.len == e.trans.items.len);
    {
        const at = try steps.netRuns(arena, r.netlist.nets.len, e.trans.items.len * 2, e.trans.items, struct {
            fn each(t: anytype, k: usize) u32 {
                return if (k == 0) t.tran.a else t.tran.b;
            }
        }.each, 2);
        defer arena.free(at.start);
        for (0..r.netlist.nets.len) |n| if (at.start[n] != at.start[n + 1]) {
            (try r.netColdMut(@intCast(n))).trans = at.items[at.start[n]..at.start[n + 1]];
        };
    }
    const at = try steps.netRuns(arena, r.netlist.nets.len, e.wires.items.len, e.wires.items, struct {
        fn each(w: anytype, _: usize) u32 {
            return w.net;
        }
    }.each, 1);
    r.netlist.driver_start = at.start;
    r.netlist.driver_ids = at.items;
    for (r.netlist.nets, 0..) |n, k| {
        resolution.initial(r, @intCast(k));
        if (n.kind != .uwire) continue;
        const ds = r.netDrivers(@intCast(k));
        for (ds, 0..) |a, i| for (ds[i + 1 ..]) |b| {
            const x = steps.driverBits(r.netlist.drivers[a], n.resolved.width);
            const y = steps.driverBits(r.netlist.drivers[b], n.resolved.width);
            if (x[0] < y[1] and y[0] < x[1]) return r.fail(n.tok, "a uwire net accepts a single driver per bit", .{});
        };
    }
    assert(r.netlist.driver_start.len == r.netlist.nets.len + 1);
    assert(r.netlist.driver_ids.len == r.netlist.drivers.len);
}

/// §10 subroutine bodies, each on its own pc range before any process, so a
/// synchronous call never runs into a process's code; then every process.
/// §9.9 leaves the order of initial and always constructs open; VerA queues
/// them as iverilog does: the scope tree depth first, each instance's and
/// generate block's child scopes (in source order) before its own
/// processes, which keep source order (ivtest contrib/pic's first lines).
/// The early processes go last, each ahead of the rest, so the first in
/// source order runs first. Then A.6.5's `disable` targets, bound once
/// every process has a pc range: a block is looked for through the
/// enclosing scopes (§12.7); a name that is no block may be a task (§10.3).
pub fn queueProcesses(r: *Run, e: *const elab.Elab) Error!void {
    assert(r.netlist.drivers.len == e.wires.items.len);
    try compile.compileSubs(r);
    for (try steps.processOrder(r, e)) |g| if (g < e.insts.items.len) {
        const inst = e.insts.items[g];
        r.scope = inst.scope;
        try steps.initVars(r, inst.module.vars);
        if (r.analog.mixed) try r.analogTriggers(inst.module, try mentioned(r, inst.module.discrete));
        try steps.processes(r, inst.module.discrete);
        // IEEE 1364-2005 §15: the instance's timing checks, bound to the
        // slots their events name, in a `.v` run and in the digital half of
        // a mixed-signal design alike.
        try tchk.compileChecks(r, inst.module.timing_checks);
    } else {
        const p = e.procs.items[g - e.insts.items.len];
        r.scope = p.scope;
        try steps.initVars(r, p.vars);
        try steps.processes(r, p.blocks);
    };
    var left = r.program.early.items.len;
    while (left > 0) {
        left -= 1;
        try exec.enqueueFirst(r, .{ .run_process = r.program.early.items[left] });
    }
    try steps.bindDisables(r, 0);
    assert(left == 0);
    assert(r.program.scope_of.items.len == r.program.code.items.len);
}

/// The last of elaboration: the slot space is final now (pass two may have
/// minted storage, an automatic task inlined at a call site), so each slot
/// gets its watch set; §14.3.3 a module path's source is watched for its
/// last transition and its §14.2.4 condition is type-checked in the scope
/// that declares the path. §7.11 "a supply strength shall be reduced to a
/// strong strength" across a pass switch, and §3.7 a net type's own pull,
/// hold from the start: a switch group with no driver event (a supply net
/// through an uncontrolled `tran`) is resolved nowhere else. Every driver
/// is still z here, so this settles only what the net types assert, before
/// anything watches a slot (no event, which the native emitter would
/// refuse); `rt.State.initIn` does the same for its `%v` signals. Then §15
/// negative limits, the timing checks, the fan-out and VAMS §9.22 drivers
/// are armed, and the slot memo is sized.
pub fn arm(r: *Run, e: *const elab.Elab) Error!void {
    const arena = r.arena;
    assert(r.growing != null);
    r.growing = null;
    r.values = e.values.items;
    r.waits.watch = try arena.alloc(std.EnumSet(root.Watcher), r.values.len);
    @memset(r.waits.watch, .empty);
    for (r.netlist.cold.items) |c| for (c.paths) |p| {
        r.waits.watch[p.src].insert(.path);
        if (p.cond != .none) {
            r.scope = p.scope;
            try compile.checkExpr(r, p.cond);
        }
    };
    for (r.netlist.nets, 0..) |n, k| if (r.netCold(n).trans.len != 0) try resolution.resolve(r, @intCast(k));
    try tchk.solveNegative(r);
    try tchk.arm(r);
    try waiters.buildFanout(r);
    try driver.arm(r);
    r.decls.slot_memo = try arena.alloc(root.SlotMemo, 1 << root.memo_bits);
    @memset(r.decls.slot_memo, .{});
    r.diag_stage = .run;
    assert(r.growing == null);
    assert(r.waits.watch.len == r.values.len);
}

// ---- private ----

/// The names the digital processes `discrete` mention, for
/// `Run.analogTriggers`.
fn mentioned(r: *Run, discrete: []const Ast.DiscreteBlock) Error!*std.AutoHashMapUnmanaged(Ast.StrId, void) {
    assert(r.analog.mixed);
    const named = try r.arena.create(std.AutoHashMapUnmanaged(Ast.StrId, void));
    named.* = .empty;
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
    for (discrete) |process| try (N{ .f = r.file, .out = named, .a = r.arena }).stmt(process.body);
    assert(named.count() <= r.file.exprs.len());
    return named;
}
