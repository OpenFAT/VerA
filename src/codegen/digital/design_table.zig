//! The emission's tables -> the trailing `const design: rt.Design` literal
//! the runtime starts from: both planes' initial words, the fan-out, node
//! and watcher tables, the `rt.net` rows (nets, drivers, switches, UDPs,
//! module paths), the §18 dump catalog and the §18.3 port dumps, the time-0
//! order, and under `--state=auto` the slots dead at a step boundary.
//! Cites: IEEE 1364-2005 §3.2 (initial x/z), §7.6, §7.9, §7.14, §8
//! (UDP rows), §10.2.1, §14.3, §14.6 (refused pulse styles), §18, §18.3,
//! §18.4.2.
//!
//! Contents:
//! - `pub fn design(em: *Emitter, p: plan.Plan, procs: []const plan.Proc, order: []const u32, schedule: plan.Schedule, activations: bool, two_phase: bool) Error!void`
//! - `pub fn catalog(em: *Emitter) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const sim_digital = @import("sim").digital;
const net = sim_digital.for_emitter.net;
const evcd = sim_digital.for_emitter.evcd;
const vcd = sim_digital.for_emitter.vcd;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const nets = @import("nets.zig");
const plan = @import("plan.zig");
const plane_words = @import("plane_words.zig");
const step_local = @import("step_local.zig");

/// Writes `const design: rt.Design = .{ ... };`. Under `--two-state` an x
/// or z initial value (§3.2) is 0. The cells follow the slots; each is
/// written before it is read.
pub fn design(em: *Emitter, p: plan.Plan, procs: []const plan.Proc, order: []const u32, schedule: plan.Schedule, activations: bool, two_phase: bool) Error!void {
    const r = em.r;
    assert(em.planes.slot_words <= em.planes.total);
    if (two_phase) assert(em.logic == .auto);
    const two = em.logic == .two;
    try em.print("const design: rt.Design = .{{\n    .v = &.{{", .{});
    for (r.values) |v| for (v.values()[0..plane_words.words(v.width)], v.unknowns()[0..plane_words.words(v.width)]) |x, u|
        try em.print(" 0x{x},", .{if (two) x & ~u else x});
    for (em.planes.slot_words..em.planes.total) |_| try em.print(" 0x0,", .{});
    try em.print(" }},\n    .x = &.{{", .{});
    for (r.values) |v| for (v.unknowns()[0..plane_words.words(v.width)]) |x| try em.print(" 0x{x},", .{if (two) 0 else x});
    for (em.planes.slot_words..em.planes.total) |_| try em.print(" 0x0,", .{});
    try em.print(" }},\n    .slots = {d},\n", .{r.values.len});
    try table(em, "fan_start", p.fan_start);
    try table(em, "fan", p.fan);
    try em.print("    .code_len = {d},\n    .repeats = {d},\n    .joins = {d},\n    .subs = {d},\n", .{ r.program.code.items.len, r.rows.repeats.items.len, r.rows.joins.items.len, r.routines.rows.items.len });
    if (activations) try actEvents(em);
    if (plan.dumps(r)) try em.print("    .vcd = &vcd_catalog,\n", .{});
    try netTables(em);
    try portTables(em);
    try table(em, "order", order);
    if (em.forced.part_start.len != 0) try table(em, "part_start", em.forced.part_start);
    if (schedule == .static) {
        try table(em, "comb_start", p.comb_start);
        try em.print("    .comb = &.{{", .{});
        for (p.comb) |c| try em.print(" .{{ .node = {d}, .word = {d}, .mask = 0x{x} }},", .{ c.node, c.word, c.mask });
        try em.print(" }},\n", .{});
        try em.print("    .nodes = {d},\n", .{p.node_pc.len});
        try table(em, "watch_start", p.watch_start);
        try em.print("    .watchers = &.{{", .{});
        for (p.watchers) |w| try em.print(" .{{ .proc = {d}, .pc = {d}, .edge = .{t} }},", .{ w.proc, w.pc, w.edge });
        try em.print(" }},\n    .triggered = {d},\n", .{p.triggered});
    }
    if (two_phase) {
        try em.print("    .dead = &.{{", .{});
        for (try step_local.stepLocal(em, procs)) |at| try em.print(" .{{ {d}, {d} }},", .{ em.planes.off[at], plane_words.words(r.values[at].width) });
        try em.print(" }},\n", .{});
    }
    try em.print("}};\n\n", .{});
}

/// Writes `vcd_catalog`: `vcd.catalog` of the design, with each slot's
/// plane word.
pub fn catalog(em: *Emitter) Error!void {
    assert(plan.dumps(em.r));
    const c = vcd.catalog(em.r, em.arena, em.planes.off) catch return em.refuse("a §18 dump catalog the engine cannot build");
    try em.print("const vcd_catalog: rt.vcd.Catalog = .{{\n    .scopes = &.{{", .{});
    for (c.scopes) |sc| try em.print("\n        .{{ .line = \"{f}\", .parent = {d}, .lexical = {}, .child = {} }},", .{ std.zig.fmtString(sc.line), sc.parent, sc.lexical, sc.child });
    try em.print("\n    }},\n", .{});
    try table(em, "var_start", c.var_start);
    try em.print("    .vars = &.{{", .{});
    for (c.vars) |v| try em.print("\n        .{{ .slot = {d}, .off = {d}, .width = {d}, .real = {}, .event = {}, .head = \"{f}\", .tail = \"{f}\" }},", .{ v.slot, v.off, v.width, v.real, v.event, std.zig.fmtString(v.head), std.zig.fmtString(v.tail) });
    try em.print("\n    }},\n    .finest = {d},\n}};\n\n", .{c.finest});
}

// ---- private ----

/// `.<name> = &.{ ... },` of `items`.
fn table(em: *Emitter, name: []const u8, items: []const u32) Error!void {
    assert(name.len != 0);
    try em.print("    .{s} = &.{{", .{name});
    for (items) |v| try em.print(" {d},", .{v});
    try em.print(" }},\n", .{});
}

/// `rt.Design.act_events`: per slot, 1 + the automatic timed task whose
/// out-of-line body declares that named event, in its own scope or a block
/// nested there (§10.2.1, `waiters.eventContext`), else 0.
fn actEvents(em: *Emitter) Error!void {
    const r = em.r;
    assert(em.timed.items.len != 0);
    const owner = try em.arena.alloc(u32, r.values.len);
    @memset(owner, 0);
    var it = r.decls.events.iterator();
    while (it.next()) |ev| for (em.timed.items) |idx| {
        const sub = r.routines.rows.items[idx];
        if (!sub.decl.automatic) continue;
        var scope = ev.value_ptr.scope;
        // A lexical chain climbs at most the scope tree.
        var climbs: usize = 0;
        while (scope != sub.body.?.frame.scope) : (climbs += 1) {
            assert(climbs <= r.hier.scopes.items.len);
            const info = r.hier.scopes.items[scope];
            if (!info.lexical) break;
            scope = info.parent;
        } else owner[ev.key_ptr.*] = idx + 1;
    };
    try table(em, "act_events", owner);
}

/// `rt.Design.nets`/`drivers`/`trans`/`udps`: `Run.netlist`'s rows of the
/// `nets.resolvedNets` nets, as `rt.net` reads them.
fn netTables(em: *Emitter) Error!void {
    const r = em.r;
    if (em.rt.nets.len == 0) return;
    var conds: u32 = 0;
    try em.print("    .nets = &.{{", .{});
    for (em.rt.nets) |k| {
        const n = r.netlist.nets[k];
        const c = r.netCold(n);
        var strong = !n.strength_read and c.trans.len == 0;
        for (r.netDrivers(k)) |di| {
            const d = r.netlist.drivers[di];
            const or_z = switch (d.source) {
                .gate => |g| !nets.logicGate(g.kind),
                .mos => true,
                .expr, .bridge, .udp, .pull => false,
            };
            strong = strong and !or_z and d.s0 == .strong and d.s1 == .strong;
        }
        try em.print("\n        .{{ .kind = .{t}, .slot = {d}, .off = {d}, .width = {d}, .drivers = &.{{", .{ n.kind, n.slot, em.planes.off[n.slot], r.values[n.slot].width });
        for (r.netDrivers(k)) |di| try em.print(" {d},", .{em.rt.driverRow(di).?});
        try em.print(" }}, .strong = {}, .delay = {f}, .charge = .{t}, .decay = {?d}", .{ strong, fmtDelay(c.delay), n.charge, c.decay });
        if (c.paths.len == 0) {
            try em.print(" }},", .{});
            continue;
        }
        // `rt` runs the default pulse handling only (`resolution.pulse`).
        if (c.ondetect or c.showcancelled) return em.refuse("IEEE 1364-2005 §14.6.4 pulsestyle_ondetect or showcancelled, which the interpreter (`vera --run`) applies");
        for (c.paths) |p| if (p.reject != null or p.err != null) return em.refuse("IEEE 1364-2005 §14.6.1 PATHPULSE$ limits, which the interpreter (`vera --run`) applies");
        // §14.3 its module paths, a condition as `pathCond<i>` in `drivers.pathConds`' order.
        try em.print(", .paths = &.{{", .{});
        for (c.paths) |p| {
            try em.print("\n            .{{ .src = {d}, .src_off = {d}, .src_bit = {d}, .edge = .{t}, .ifnone = {}, .cond = ", .{ p.src, em.planes.off[p.src], p.src_bit, p.edge, p.ifnone });
            if (p.cond != .none) {
                try em.print("&Code(false).pathCond{d}", .{conds});
                conds += 1;
            } else try em.print("null", .{});
            try em.print(", .table = .{{", .{});
            for (p.table) |row| try em.print(" .{{ {d}, {d}, {d}, {d} }},", .{ row[0], row[1], row[2], row[3] });
            try em.print(" }} }},", .{});
        }
        try em.print(" }} }},", .{});
    }
    try em.print("\n    }},\n    .drivers = &.{{", .{});
    var udps: std.ArrayList(*const net.Udp) = try .initCapacity(em.arena, em.rt.drivers.len);
    for (em.rt.drivers) |di| {
        const d = r.netlist.drivers[di];
        r.scope = d.scope;
        try em.print("\n        .{{ .net = {d}, .s0 = .{t}, .s1 = .{t}, .delay = {f}, .init = .{t}, .delay_bit = ", .{ em.rt.netRow(d.net).?, d.s0, d.s1, fmtDelay(d.delay), d.current.bit(if (d.source == .udp) d.source.udp.out_bit orelse 0 else 0) });
        switch (d.source) {
            .expr => try em.print("null, .source = .expr }},", .{}),
            .gate => |g| try em.print("{d}, .source = .{{ .gate = {d} }} }},", .{ g.out_bit orelse 0, g.out_bit orelse 0 }),
            .udp => |u| {
                try em.print("{d}, .source = .{{ .udp = {d} }} }},", .{ u.out_bit orelse 0, udps.items.len });
                udps.appendAssumeCapacity(u);
            },
            .mos => |m| {
                if (m.lane != null or m.out_bit != null) return em.refuse("§7.1.6 a MOS switch of an instance array with vector terminals (one lane each)");
                var data_net: ?u32 = null;
                if (r.file.exprs.tag(m.data) == .ident) if (r.netlist.slot_nets.get(try em.slot(m.data))) |k| {
                    data_net = em.rt.netRow(k);
                };
                try em.print("0, .source = .{{ .mos = .{{ .n_type = {}, .resistive = {}, .data_net = {?d} }} }} }},", .{ m.n_type, m.resistive, data_net });
            },
            .bridge => |b| try em.print("0, .source = .{{ .bridge = .{{ .src_off = {d}, .src_lo = {d}, .dst_lo = {d}, .width = {d}, .ext = {d}, .sign_at = {?d} }} }} }},", .{ em.planes.off[b.src], b.src_lo, b.dst_lo, b.width, b.ext, b.sign_at }),
            .pull => |b| try em.print("0, .source = .{{ .pull = .{t} }} }},", .{b}),
        }
    }
    try em.print("\n    }},\n", .{});
    if (r.netlist.switches.len != 0) {
        try em.print("    .trans = &.{{", .{});
        for (r.netlist.switches) |t| try em.print("\n        .{{ .a = {d}, .b = {d}, .a_bit = {d}, .b_bit = {d}, .on = .{t}, .state = .{t}, .resistive = {}, .delay = {f} }},", .{
            em.rt.netRow(t.a).?, em.rt.netRow(t.b).?, t.a_bit, t.b_bit, t.on, t.state, t.resistive, fmtDelay(t.delay),
        });
        try em.print("\n    }},\n", .{});
    }
    if (udps.items.len == 0) return;
    try udpTables(em, udps.items);
}

/// `rt.Design.udps`: §8 each UDP driver's table rows.
fn udpTables(em: *Emitter, udps: []const *const net.Udp) Error!void {
    assert(udps.len != 0);
    try em.print("    .udps = &.{{", .{});
    for (udps) |u| {
        try em.print("\n        .{{ .sequential = {}, .ins = {d}, .state = .{t}, .rows = &.{{", .{ u.sequential, u.ins.len, u.state });
        for (u.rows) |row| {
            try em.print("\n            .{{ .state = {d}, .out = {d}, .edge_at = {?d}, .ins = &.{{", .{ row.state, row.out, row.edge_at });
            for (row.ins) |sym| switch (sym) {
                .level => |c| try em.print(" .{{ .level = {d} }},", .{c}),
                .pair => |pr| try em.print(" .{{ .pair = .{{ {d}, {d} }} }},", .{ pr[0], pr[1] }),
                .letter => |c| try em.print(" .{{ .letter = {d} }},", .{c}),
            };
            try em.print(" }} }},", .{});
        }
        try em.print("\n        }} }},", .{});
    }
    try em.print("\n    }},\n", .{});
}

fn fmtDelay(d: net.Delay) std.fmt.Alt(net.Delay, delayText) {
    return .{ .data = d };
}

fn delayText(d: net.Delay, out: *std.Io.Writer) std.Io.Writer.Error!void {
    try out.print(".{{ .rise = {d}, .fall = {d}, .off = {d}, .present = {} }}", .{ d.rise, d.fall, d.off, d.present });
}

/// `rt.Design.ports_dump`: each `nets.PortFile` with its header text and ports.
fn portTables(em: *Emitter) Error!void {
    const r = em.r;
    if (em.port_files.len == 0) return;
    try em.print("    .ports_dump = &.{{", .{});
    for (em.port_files) |f| {
        var head: std.Io.Writer.Allocating = .init(em.arena);
        const w = &head.writer;
        var ports: std.Io.Writer.Allocating = .init(em.arena);
        const pw = &ports.writer;
        var n: u32 = 0;
        // §18.4.2: "$scope module <full instance path> $end", then one
        // `$var port <size> <n> <name> $end` per port (`evcd.tick`).
        for (f.scopes) |sc| {
            w.writeAll("$scope module ") catch return error.OutOfMemory;
            evcd.path(r, w, sc) catch return error.OutOfMemory;
            w.writeAll(" $end\n") catch return error.OutOfMemory;
            for (r.file.modules[r.hier.scopes.items[sc].def].ports) |mp| {
                const slot = r.hier.names.get(.{ .scope = sc, .str = mp.name }) orelse continue;
                const width = r.values[slot].width;
                w.writeAll("$var port ") catch return error.OutOfMemory;
                if (width == 1) w.writeAll("1") catch return error.OutOfMemory else {
                    const range = r.vecRange(slot);
                    w.print("[{d}:{d}]", .{ range.msb, range.lsb }) catch return error.OutOfMemory;
                }
                w.print(" <{d} {s} $end\n", .{ n, r.file.str(mp.name) }) catch return error.OutOfMemory;
                n += 1;
                pw.print("\n            .{{ .off = {d}, .width = {d}, .dir = .{t}, ", .{ em.planes.off[slot], width, mp.direction }) catch return error.OutOfMemory;
                if (r.netlist.slot_nets.get(slot)) |k| {
                    pw.print(".net = {d}, .inside = &.{{", .{em.rt.netRow(k) orelse return em.refuse("a dumped port whose net the executable does not resolve")}) catch return error.OutOfMemory;
                    for (r.netDrivers(k)) |d| pw.print(" {},", .{evcd.below(r, r.netlist.drivers[d].scope, sc)}) catch return error.OutOfMemory;
                    pw.writeAll(" } },") catch return error.OutOfMemory;
                } else pw.writeAll("},") catch return error.OutOfMemory;
            }
            w.writeAll("$upscope $end\n") catch return error.OutOfMemory;
        }
        w.writeAll("$enddefinitions $end\n") catch return error.OutOfMemory;
        try em.print("\n        .{{ .name = \"{f}\", .call = \"{f}\", .finest = {d}, .header = \"{f}\", .ports = &.{{{s}\n        }} }},", .{
            std.zig.fmtString(f.name), std.zig.fmtString(f.call), r.time.finest, std.zig.fmtString(head.written()), ports.written(),
        });
    }
    try em.print("\n    }},\n", .{});
}
