//! A §17.1 display task's arguments -> Zig statements that print what
//! `display.display` prints: the format walked at compile time, literal
//! text written as is and each conversion one `rt.State` call on its
//! operand; a format held in a variable walked when the task runs. Also
//! `fn show`, the `$strobe`/`$monitor` lines the monitor region prints.
//! Cites: IEEE 1364-2005 §17.1, §17.1.1.2 Table 17-3, §17.1.1.5 (`%v`),
//! §17.1.2 (`$strobe`), §17.1.3 (`$monitor`), §17.2.3 (`$sformat`), §9.4.7
//! (`%r`), Table 9-22.
//!
//! Contents:
//! - `pub fn show(em: *Emitter, args: []const Ast.ExprId, sh: display.Show, only_first: bool) Error!void`
//! - `pub fn dynamicFormat(em: *Emitter, args: []const Ast.ExprId) Error!void`
//! - `pub fn staticText(em: *Emitter, comptime f: anytype, args: anytype) Error![]const u8`
//! - `pub fn site(em: *Emitter, pc: u32) Error!u32`
//! - `pub fn showSites(em: *Emitter) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const kernels = @import("kernels");
const fmt = kernels.fmt;
const sim_digital = @import("sim").digital;
const compile = sim_digital.for_emitter.compile;
const display = sim_digital.for_emitter.display;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const expr = @import("expr.zig");
const expr_real = @import("expr_real.zig");

/// Writes `display.display` of `args` with defaults `sh`. With
/// `only_first`, `display.sformat`'s walk of a literal format: a second
/// argument warns W1153 at run time.
pub fn show(em: *Emitter, args: []const Ast.ExprId, sh: display.Show, only_first: bool) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    var text: std.ArrayList(u8) = .empty;
    var arg: usize = 0;
    while (arg < args.len) : (arg += 1) {
        const e = args[arg];
        if (only_first and arg != 0) {
            try flush(em, &text);
            try em.print("            s.warn(\"W1153\", \"{f}\", .{{}});\n", .{std.zig.fmtString(display.sformat_mismatch)});
            return;
        }
        if (e == .none) {
            try text.append(em.arena, ' ');
            continue;
        }
        if (ex.tag(e) != .str_literal) {
            try flush(em, &text);
            if (compile.typeOf(r, e).real) {
                // `display.bareReal`'s text: `%#g`, a bare `$realtime` `%.Nf`.
                try em.print("            try s.real(", .{});
                try expr_real.real(em, e);
                if (ex.tag(e) == .sys_call and r.typing.sys_calls[@backingInt(e)].? == .realtime)
                    try em.print(", 'f', 0, {d}, null);\n", .{std.math.log10_int(@as(u64, r.timeOf(r.scope).scale.local_per_unit))})
                else
                    try em.print(", 'g', {d}, -1, null);\n", .{kernels.str_real.zc_alt});
            } else try operand(em, e, sh.radix, null, false);
            continue;
        }
        arg = try literalFormat(em, args, arg, &text);
    }
    if (sh.newline) try text.append(em.arena, '\n');
    try flush(em, &text);
    assert(text.items.len == 0);
}

/// Writes §17.2.3 `$sformat` of a format held in a variable
/// (`display.sformat`'s dynamic walk): the format is read when the task
/// runs, and each argument is evaluated by whichever conversion it meets
/// there.
pub fn dynamicFormat(em: *Emitter, args: []const Ast.ExprId) Error!void {
    const r = em.r;
    assert(args.len != 0);
    for (args[1..]) |a| {
        if (a == .none) return em.refuse("a null argument after a $sformat format held in a variable");
        // Its strength is kept only where a literal %v marks it read.
        if (r.file.exprs.tag(a) == .ident and r.netlist.slot_nets.get(try em.slot(a)) != null and compile.typeOf(r, a).width == 1)
            return em.refuse("a scalar net after a $sformat format held in a variable, which a %v there would need the strength of");
    }
    if (compile.typeOf(r, args[0]).real) return em.refuse("a $sformat format held in a real");
    const scope = std.zig.fmtString(try staticText(em, display.emitScope, .{}));
    const def = r.hier.scopes.items[r.scope].def;
    const lib = std.zig.fmtString(try em.arena.print("{s}.{s}", .{ r.file.str(r.hier.def_lib[def]), r.file.str(r.file.modules[def].name) }));
    const lb = em.label();
    try em.print("            {{\n            var fb{d}: [{d}]u8 = undefined;\n            var f{d} = S.formatOf(&fb{d}, ", .{ lb, (compile.typeOf(r, args[0]).width + 7) / 8, lb, lb });
    const ft = try expr.selfDetermined(em, args[0]);
    try em.print(", {d});\n            b{d}: {{\n", .{ ft.width, lb });
    for (args[1..], 1..) |a, k| {
        try em.print("            const c{d}_{d} = (try s.nextSpec(&f{d}, \"{f}\", \"{f}\")) orelse break :b{d};\n", .{ lb, k, lb, scope, lib, lb });
        try em.print("            switch (c{d}_{d}.conv) {{\n                'b', 'B', 'o', 'O', 'h', 'H', 'x', 'X', 'd', 'D' => try s.value(", .{ lb, k });
        var t = try expr.selfDetermined(em, a);
        try em.print(", {d}, {}, switch (c{d}_{d}.conv) {{\n                    'b', 'B' => .binary,\n                    'o', 'O' => .octal,\n                    'h', 'H', 'x', 'X' => .hex,\n                    else => .decimal,\n                }}, c{d}_{d}.width, c{d}_{d}.flags & {d} != 0),\n", .{ t.width, t.signed, lb, k, lb, k, lb, k, kernels.str_real.zc_zero });
        if (compile.typeOf(r, a).real) {
            try em.print("                't', 'T' => try s.timeReal(", .{});
            try expr_real.real(em, a);
            try em.print(", {d}, c{d}_{d}.width, c{d}_{d}.precision),\n", .{ r.timeOf(r.scope).unit_exp, lb, k, lb, k });
        } else {
            try em.print("                't', 'T' => try s.time(", .{});
            t = try expr.selfDetermined(em, a);
            try em.print(", {d}, {}, {d}, c{d}_{d}.width, c{d}_{d}.precision),\n", .{ t.width, t.signed, r.timeOf(r.scope).unit_exp, lb, k, lb, k });
        }
        try em.print("                's', 'S', 'c', 'C' => try s.text(", .{});
        t = try expr.selfDetermined(em, a);
        try em.print(", {d}, c{d}_{d}.conv == 'c' or c{d}_{d}.conv == 'C', c{d}_{d}.width),\n", .{ t.width, lb, k, lb, k, lb, k });
        if (compile.typeOf(r, a).width == 1) {
            try em.print("                'v', 'V' => try s.strongStrength(", .{});
            t = try expr.selfDetermined(em, a);
            try em.print(", {d}),\n", .{t.width});
        } else try em.print("                'v', 'V' => return s.fail(\"§17.1.1.5: %v takes a scalar net reference\", .{{}}),\n", .{});
        try em.print("                else => try s.real(", .{});
        try expr_real.real(em, a);
        try em.print(", c{d}_{d}.conv, c{d}_{d}.flags, c{d}_{d}.precision, c{d}_{d}.width),\n            }}\n", .{ lb, k, lb, k, lb, k, lb, k });
    }
    try em.print("            try s.endFormat(&f{d}, \"{f}\", \"{f}\");\n            }}\n            }}\n", .{ lb, scope, lib });
}

/// Returns text the interpreter prints from `em.r` alone at this pc (`%m`,
/// `$printtimescale`), captured once to be written as a literal. Restores
/// `em.r.out`.
pub fn staticText(em: *Emitter, comptime f: anytype, args: anytype) Error![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(em.arena);
    const saved = em.r.out;
    em.r.out = &buf.writer;
    defer em.r.out = saved;
    @call(.auto, f, .{em.r} ++ args) catch return em.refuse("text the engine prints only at run time");
    assert(em.r.out == &buf.writer);
    return buf.written();
}

/// Returns the `show` index of the `$strobe`/`$monitor` at `pc`, giving it
/// the next one on first use.
pub fn site(em: *Emitter, pc: u32) Error!u32 {
    assert(pc < em.r.program.code.items.len);
    const k = std.mem.findScalar(u32, em.shows.items, pc) orelse blk: {
        try em.shows.append(em.arena, pc);
        break :blk em.shows.items.len - 1;
    };
    assert(em.shows.items[k] == pc);
    return @intCast(k);
}

/// Writes `fn show`: the line of `$strobe` or `$monitor` site k, printed
/// when its `.monitor`-region event comes up, in the scope that wrote it
/// (§17.1.2, §17.1.3).
pub fn showSites(em: *Emitter) Error!void {
    const r = em.r;
    if (em.shows.items.len == 0) return em.print("fn show(_: *S, _: u32) rt.Error!void {{\n    unreachable;\n}}\n\n", .{});
    try em.print("fn show(s: *S, k: u32) rt.Error!void {{\n    @setEvalBranchQuota(1 << 30);\n    switch (k) {{\n", .{});
    for (em.shows.items, 0..) |pc, k| {
        r.scope = r.program.scope_of.items[pc];
        r.pc = pc;
        const t = r.program.code.items[pc].task;
        try em.print("        {d} => {{\n", .{k});
        try show(em, r.program.exprs(t.args), switch (t.task) {
            .strobe, .monitor => |sh| sh,
            else => unreachable, // else: `site` registers only these two
        }, false);
        try em.print("        }},\n", .{});
    }
    try em.print("        else => unreachable,\n    }}\n}}\n\n", .{});
}

// ---- private ----

/// One literal format argument `args[arg]` walked into `text` and calls;
/// returns the index of the last argument it consumed. `display.walk`
/// validated this format: every flag left is one `fmt.flagVerdict` admits,
/// so only a real conversion carries one.
fn literalFormat(em: *Emitter, args: []const Ast.ExprId, first: usize, text: *std.ArrayList(u8)) Error!usize {
    const r = em.r;
    const ex = &r.file.exprs;
    assert(ex.tag(args[first]) == .str_literal);
    var arg = first;
    const format = r.file.str(ex.strOf(args[first]));
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        if (format[i] != '%') {
            try text.append(em.arena, format[i]);
            continue;
        }
        i += 1;
        if (format[i] == '%') {
            try text.append(em.arena, '%');
            continue;
        }
        const sp = fmt.spec(format, &i);
        const width = sp.width;
        const precision = sp.precision;
        // `display.walk`'s '0'/'-' field (`display.fillField`).
        const fill = display.fieldFill(sp, format[i]);
        const zero = fill != null;
        switch (format[i]) {
            'b', 'B', 'o', 'O', 'h', 'H', 'x', 'X', 'd', 'D' => {
                arg += 1;
                try flush(em, text);
                if (zero) try em.print("            s.zeroBegin();\n", .{});
                try operand(em, args[arg], switch (format[i]) {
                    'b', 'B' => .binary,
                    'o', 'O' => .octal,
                    'h', 'H', 'x', 'X' => .hex,
                    else => .decimal,
                }, width, false);
                if (fill) |f| try em.print("            try s.zeroEnd(.{t});\n", .{f});
            },
            't', 'T' => {
                arg += 1;
                try flush(em, text);
                if (zero) try em.print("            s.zeroBegin();\n", .{});
                // A real operand is formatted as it is (#64).
                if (compile.typeOf(r, args[arg]).real) {
                    try em.print("            try s.timeReal(", .{});
                    try expr_real.real(em, args[arg]);
                    try em.print(", {d}, {?d}, {d});\n", .{ r.timeOf(r.scope).unit_exp, width, precision });
                } else {
                    try em.print("            try s.time(", .{});
                    const t = try expr.selfDetermined(em, args[arg]);
                    try em.print(", {d}, {}, {d}, {?d}, {d});\n", .{ t.width, t.signed, r.timeOf(r.scope).unit_exp, width, precision });
                }
                if (fill) |f| try em.print("            try s.zeroEnd(.{t});\n", .{f});
            },
            's', 'S', 'c', 'C' => {
                arg += 1;
                try flush(em, text);
                if (zero) try em.print("            s.zeroBegin();\n", .{});
                try em.print("            try s.text(", .{});
                const t = try expr.selfDetermined(em, args[arg]);
                try em.print(", {d}, {}, {?d});\n", .{ t.width, format[i] == 'c' or format[i] == 'C', width });
                if (fill) |f| try em.print("            try s.zeroEnd(.{t});\n", .{f});
            },
            'm', 'M' => try text.appendSlice(em.arena, try staticText(em, display.emitScope, .{})),
            'l', 'L' => {
                const def = r.hier.scopes.items[r.scope].def;
                try text.appendSlice(em.arena, try em.arena.print("{s}.{s}", .{ r.file.str(r.hier.def_lib[def]), r.file.str(r.file.modules[def].name) }));
            },
            // §17.1.1.2 Table 17-3's real conversions, and §9.4.7's %r.
            'e', 'E', 'f', 'F', 'g', 'G', 'r', 'R' => {
                arg += 1;
                try flush(em, text);
                try em.print("            try s.real(", .{});
                try expr_real.real(em, args[arg]);
                try em.print(", '{c}', {d}, {d}, {?d});\n", .{ format[i], sp.flags, precision, width });
            },
            'v', 'V' => {
                arg += 1;
                try flush(em, text);
                try strengthOf(em, args[arg]);
            },
            'u', 'U', 'z', 'Z' => return em.refuse("§17.1.1.2 %u/%z: unformatted (binary) display output"),
            else => return em.refuse("a display conversion the engine refuses"),
        }
    }
    assert(arg < args.len);
    return arg;
}

/// Writes §17.1.1.5 `%v` of `e`, which `display.walk` proved a scalar: a
/// net's resolved signal (`display.walk` marked it `strength_read`, so it
/// has an `rt.net` row whose fold keeps it), an undriven net's own pull,
/// else the value at strong strength.
fn strengthOf(em: *Emitter, e: Ast.ExprId) Error!void {
    const r = em.r;
    assert(e != .none);
    const net = if (r.file.exprs.tag(e) == .ident) r.netlist.slot_nets.get(try em.slot(e)) else null;
    if (net) |k| {
        // §7.6: a pass switch drives a net with no driver of its own
        // (`display.walk`'s test, which the interpreter prints by).
        if (r.netDrivers(k).len == 0 and r.netCold(r.netlist.nets[k]).trans.len == 0) {
            var buf: std.Io.Writer.Allocating = .init(em.arena);
            display.strength(&buf.writer, sim_digital.for_emitter.net.netPull(r.netlist.nets[k].kind)) catch return error.OutOfMemory;
            return em.print("            try s.out.writeAll(\"{s}\");\n", .{buf.written()});
        }
        const ix = em.rt.netRow(k) orelse return em.refuse("a %v of a net the executable does not resolve");
        return em.print("            try s.netStrength({d});\n", .{ix});
    }
    try em.print("            try s.strongStrength(", .{});
    const t = try expr.selfDetermined(em, e);
    try em.print(", {d});\n", .{t.width});
}

/// Writes the literal text gathered so far, if any, and empties `text`.
fn flush(em: *Emitter, text: *std.ArrayList(u8)) Error!void {
    if (text.items.len == 0) return;
    try em.print("            try s.out.writeAll(\"{f}\");\n", .{std.zig.fmtString(text.items)});
    text.clearRetainingCapacity();
    assert(text.items.len == 0);
}

/// Writes one `%b %o %h %d` operand, or an argument with no format.
fn operand(em: *Emitter, e: Ast.ExprId, radix: fmt.Radix, width: ?u64, zero: bool) Error!void {
    assert(e != .none);
    if (compile.typeOf(em.r, e).real) {
        try em.print("            try s.realValue(", .{});
        try expr_real.real(em, e);
        return em.print(", .{t}, {?d});\n", .{ radix, width });
    }
    try em.print("            try s.value(", .{});
    const t = try expr.selfDetermined(em, e);
    try em.print(", {d}, {}, .{t}, {?d}, {});\n", .{ t.width, t.signed, radix, width, zero });
}
