//! A `.task` instruction (a §17 system task call) -> the Zig statements of
//! its arm: display and file output, `$finish`, `$timeformat`, the monitor
//! and strobe sites, memory loads, queues, PLAs, string formatting and the
//! §18 dump tasks, each reading its arguments when the interpreter does.
//! Cites: IEEE 1364-2005 §17.1, §17.1.2, §17.1.3, §17.2.2, §17.2.3, §17.2.9,
//! §17.2.10 (refused), §17.3.2, §17.4 (`$finish`), §17.5, §17.5.4, §17.6,
//! §18.1, §18.3.
//!
//! Contents:
//! - `pub fn systemTask(em: *Emitter, pc: u32, t: Task) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const compile = sim_digital.for_emitter.compile;
const display = sim_digital.for_emitter.display;
const vcd = sim_digital.for_emitter.vcd;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const assign = @import("assign.zig");
const expr = @import("expr.zig");
const layout = @import("layout.zig");
const nets = @import("nets.zig");
const show = @import("show.zig");

const Task = @FieldType(compile.Instruction, "task");
const TaskKind = @FieldType(Task, "task");

/// Writes the arm of system task call `t` at `pc`, ending in a `continue`
/// to the next pc (or a `return` from `$finish`).
pub fn systemTask(em: *Emitter, pc: u32, t: Task) Error!void {
    const r = em.r;
    assert(pc < r.program.code.items.len);
    const args = r.program.exprs(t.args);
    const next = pc + 1;
    switch (t.task) {
        .show => |sh| try show.show(em, args, sh, false),
        .finish => |stop| {
            try em.print("            return s.{s}(", .{if (stop) "stopRun" else "finish"});
            if (args.len == 0) try em.print("true", .{}) else {
                try em.print("(L.asInt(", .{});
                const ty = try expr.selfDetermined(em, args[0]);
                try em.print(", {d}, {}) orelse 1) != 0", .{ ty.width, ty.signed });
            }
            const start = r.starts[t.tok];
            const loc = r.bag.locate(.{ .start = start, .end = start }, .none);
            try em.print(", \"{f}\", {d});\n", .{ std.zig.fmtString(r.bag.fileName(loc.file)), loc.offset });
            return;
        },
        // §17.3.2: the three numbers are read when the task runs, an x/z
        // one as 0.
        .timeformat => if (args.len == 0) {
            try em.print("            s.time_format = .{{ .units = {d} }};\n", .{r.time.finest});
        } else {
            try em.print("            s.time_format = .{{ .units = std.math.lossyCast(i32, ", .{});
            try expr.int(em, args[0]);
            try em.print("), .precision = std.math.lossyCast(u32, ", .{});
            try expr.int(em, args[1]);
            try em.print("), .suffix = \"{f}\", .width = std.math.lossyCast(u32, ", .{std.zig.fmtString(r.file.str(r.file.exprs.strOf(args[2])))});
            try expr.int(em, args[3]);
            try em.print(") }};\n", .{});
        },
        .sdf_annotate => return em.refuse("§17.2.10 $sdf_annotate, which the interpreter (`vera --run`) applies"),
        .printtimescale => try em.print("            try s.out.writeAll(\"{f}\");\n", .{std.zig.fmtString(try show.staticText(em, display.printTimescale, .{args}))}),
        // §17.1.2: the call is queued, its arguments are read then.
        .strobe => |sh| {
            if (sh.file) return em.refuse("§17.2.2 $fstrobe: a strobe written to a file descriptor");
            try em.print("            try s.strobe({d});\n", .{try show.site(em, pc)});
        },
        // §17.1.3: one standing monitor, which a change of any slot its
        // arguments read asks to print.
        .monitor => |sh| {
            if (sh.file) return em.refuse("§17.2.2 $fmonitor: a monitor written to a file descriptor");
            for (args) |arg| if (display.comparedOperand(r, arg))
                return em.refuse("§17.1.3 a $monitor argument that is an expression (a select, an operator), which reports only when its value changes");
            var slots: std.ArrayList(u32) = .empty;
            for (args) |arg| if (arg != .none and r.file.exprs.tag(arg) != .str_literal)
                compile.sensitivity(r, arg, &slots) catch return em.refuse("a monitor argument the engine resolves only at run time");
            try em.print("            try s.monitor({d}, &.{{", .{try show.site(em, pc)});
            for (slots.items) |at| try em.print(" {d},", .{at});
            try em.print(" }});\n", .{});
        },
        // "$monitoron shall produce a display immediately".
        .monitor_enable => |on| if (on)
            try em.print("            if (s.monitorEnable(true)) |k| try show(s, k);\n", .{})
        else
            try em.print("            _ = s.monitorEnable(false);\n", .{}),
        .readmem => |radix| try readmem(em, args, radix),
        .queue => |op| try queue(em, args, op),
        .pla => |p| try pla(em, t.tok, args, p),
        .fflush => {},
        .user => return em.refuse("a PLI application's system task, which runs only under a VPI host"),
        .ports => |op| try portTask(em, pc, op, args),
        .fclose => {
            try em.print("            s.fclose(", .{});
            try expr.int64(em, args[0]);
            try em.print(");\n", .{});
        },
        // §17.2.2: the descriptor is read first; an x or z one prints nothing.
        .fshow => |sh| {
            const lb = em.label();
            try em.print("            if (", .{});
            try expr.int64(em, args[0]);
            try em.print(") |d{d}| {{\n            s.capture();\n", .{lb});
            try show.show(em, args[1..], sh, false);
            try em.print("            try s.fshow(d{d});\n            }}\n", .{lb});
        },
        .sshow => |sh| {
            try em.print("            s.capture();\n", .{});
            try show.show(em, args[1..], sh, false);
            try assign.assignChars(em, args[0], "s.captured()");
        },
        .sformat => {
            try em.print("            s.capture();\n", .{});
            if (r.file.exprs.tag(args[1]) == .str_literal)
                try show.show(em, args[1..], .{ .radix = .decimal, .newline = false }, true)
            else
                try show.dynamicFormat(em, args[1..]);
            try assign.assignChars(em, args[0], "s.captured()");
        },
        .dump => |op| try dump(em, t.tok, args, op),
    }
    try em.print("            continue :sw {d};\n", .{next});
}

// ---- private ----

/// §17.2.9 `$readmemb`/`$readmemh`: the bounds are read now; the file when
/// the task runs.
fn readmem(em: *Emitter, args: []const Ast.ExprId, radix: @FieldType(TaskKind, "readmem")) Error!void {
    const r = em.r;
    if (em.target == .device) return em.refuse("§17.2.9 $readmemb/$readmemh: a device reads no file");
    if (r.file.exprs.tag(args[0]) != .str_literal) return em.refuse("§17.2.9 $readmemb/$readmemh with a file name held in a variable");
    assert(args.len >= 2);
    const base = try em.slot(args[1]);
    const arr = r.decls.arrays.get(base).?;
    const name = r.file.str(r.file.exprs.strOf(args[0]));
    try em.print("            try s.readmem(\"{f}\", \"{f}\", .{t}, ", .{ std.zig.fmtString(r.file_name), std.zig.fmtString(name), radix });
    try em.print("{d}, {d}, {d}, {d}, {d}, {d}", .{ em.slotWidth(base), base, em.planes.off[base], arr.low, arr.high, args.len - 2 });
    for (2..4) |k| {
        try em.print(", ", .{});
        if (k < args.len) try expr.int64(em, args[k]) else try em.print("null", .{});
    }
    try em.print(");\n", .{});
}

/// §17.6: inputs read, the shared queue engine, then each output written as
/// `evaluate.assignInt` writes it, status last.
fn queue(em: *Emitter, args: []const Ast.ExprId, op: @FieldType(TaskKind, "queue")) Error!void {
    const r = em.r;
    if (em.target == .device) return em.refuse("a §17.6 stochastic queue, whose length a device's state cannot bound");
    assert(args.len == 4);
    const lb = em.label();
    const scale = r.timeOf(r.scope).scale;
    try em.print("            const q{d} = try s.queue(.{t}, ", .{ lb, op });
    try expr.int64(em, args[0]);
    try em.print(", ", .{});
    if (op == .initialize or op == .add or op == .exam) try expr.int64(em, args[1]) else try em.print("null", .{});
    try em.print(", ", .{});
    if (op == .initialize or op == .add) try expr.int64(em, args[2]) else try em.print("null", .{});
    try em.print(", .{{ .local_per_unit = {d}, .global_per_local = {d} }});\n", .{ scale.local_per_unit, scale.global_per_local });
    for (1..3) |k| if (op == .remove or (op == .exam and k == 2)) {
        try em.print("            if (q{d}.out[{d}]) |v{d}| {{\n", .{ lb, k - 1, lb });
        try assign.assignInt(em, args[k], try em.arena.print("v{d}", .{lb}));
        try em.print("            }}\n", .{});
    };
    try assign.assignInt(em, args[3], try em.arena.print("q{d}.status", .{lb}));
}

/// §17.5: the outputs through a cell as wide as they are.
fn pla(em: *Emitter, tok: u32, args: []const Ast.ExprId, p: @FieldType(TaskKind, "pla")) Error!void {
    const r = em.r;
    assert(args.len >= 3);
    const base = try em.slot(args[0]);
    const ty = try assign.targetType(em, args[2]);
    if (ty.real) return em.refuse("a §17.5 PLA writing a real");
    if (p.plane) try em.xMeaning("a §17.5.4 plane PLA, whose z personality bits mean \"ignore this input\"", tok);
    em.keepFour("a §17.5 PLA, whose outputs are x where no row decides", tok);
    const at = try layout.cellOf(&em.planes, em.arena, layout.scratchCell(ty.width), ty.width);
    try em.print("            try s.pla(.{{ .logic = .@\"{t}\", .plane = {}, .async_ = false }}, {d}, {d}, {d}, ", .{
        p.logic, p.plane, em.planes.off[base], r.decls.arrays.get(base).?.count, em.slotWidth(base),
    });
    const in = try expr.selfDetermined(em, args[1]);
    try em.print(", {d}, {d}, {d});\n", .{ in.width, at, ty.width });
    try assign.assignment(em, args[2], .{ .stored = .{ .off = at, .ty = .{ .width = ty.width, .signed = false } } }, .blocking);
}

/// §18.1: the arguments are read now; the targets were resolved at
/// elaboration.
fn dump(em: *Emitter, tok: u32, args: []const Ast.ExprId, op: @FieldType(TaskKind, "dump")) Error!void {
    const r = em.r;
    switch (op) {
        .file => if (args.len == 1) {
            try em.print("            try s.dumpFile(", .{});
            const n = try expr.selfDetermined(em, args[0]);
            try em.print(", {d}, \"{f}\");\n", .{ n.width, std.zig.fmtString(vcd.callText(r.text, r.starts[tok])) });
        },
        .vars => {
            try em.print("            try s.dumpVars(", .{});
            if (args.len == 0) {
                try em.print("0, &.{{", .{});
                for (r.hier.roots) |sc| try em.print(" .{{ .scope = {d} }},", .{sc});
                try em.print(" }});\n", .{});
            } else {
                try expr.int64(em, args[0]);
                try em.print(", &.{{", .{});
                for (args[1..]) |e| switch (vcd.target(r, e) catch return em.refuse("a $dumpvars target the engine resolves only at run time")) {
                    .scope => |sc| try em.print(" .{{ .scope = {d} }},", .{sc}),
                    .slot => |sl| try em.print(" .{{ .slot = {d} }},", .{sl}),
                };
                try em.print(" }});\n", .{});
            }
        },
        .limit => {
            assert(args.len != 0);
            try em.print("            s.dumps.vcd.limit = std.math.lossyCast(u64, ", .{});
            try expr.int(em, args[0]);
            try em.print(");\n", .{});
        },
        .off, .on, .all, .flush => try em.print("            try s.dumpControl(.{t});\n", .{op}),
    }
}

/// One §18.3 task at `pc` (`evcd.task`): a `$dumpports` call selects its
/// file; the others act on the file their last argument names, or on every
/// file. A name no `$dumpports` gives is ignored.
fn portTask(em: *Emitter, pc: u32, op: @FieldType(TaskKind, "ports"), args: []const Ast.ExprId) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    if (op == .ports) {
        for (em.port_files, 0..) |f, k| if (f.pc == pc) return em.print("            try s.portsSelect({d});\n", .{k});
        unreachable; // `nets.portDumps` listed every call
    }
    const given = nets.portArgs(args);
    var k: ?usize = null;
    if (given.len != 0 and (op != .limit or given.len == 2)) {
        const e = given[given.len - 1];
        if (ex.tag(e) != .str_literal) return em.refuse("a §18.3 file name held in a variable");
        const name = r.file.str(ex.strOf(e));
        k = for (em.port_files, 0..) |f, i| {
            if (std.mem.eql(u8, f.name, name)) break i;
        } else return;
    }
    if (k) |i| assert(i < em.port_files.len);
    try em.print("            try s.portsControl(.{t}, {?d}, ", .{ op, k });
    if (op == .limit) {
        try em.print("std.math.lossyCast(u64, ", .{});
        try expr.int(em, given[0]);
        try em.print("));\n", .{});
    } else try em.print("0);\n", .{});
}
