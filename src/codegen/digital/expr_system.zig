//! An integral system function call -> Zig text over `rt.State` and
//! `rt.logic`: time, casts, plusargs, the file and queue functions (which
//! write their output arguments as the interpreter does), the seeded draws,
//! `$clog2` and `$fread`.
//! Cites: IEEE 1364-2005 §4.2.1.4 (`$signed`), §17.2 (file I/O), §17.2.4.3
//! (`$sscanf`), §17.2.4.4 (`$fread`), §17.6.5 (`$q_full`), §17.7.1
//! (`$time`), §17.8, §17.9, §17.10 (plusargs), §17.11 (`$clog2`).
//!
//! Contents:
//! - `pub fn value(em: *Emitter, e: Ast.ExprId, ty: Type) Error!void`
//! - `pub fn fread(em: *Emitter, args: []const Ast.ExprId) Error!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const sim_digital = @import("sim").digital;
const compile = sim_digital.for_emitter.compile;
const Type = compile.Type;
const Emitter = @import("Emitter.zig");
const Error = Emitter.Error;
const assign = @import("assign.zig");
const expr = @import("expr.zig");
const expr_real = @import("expr_real.zig");
const plane_words = @import("plane_words.zig");

const file_io = "§17.2 file I/O, which a 4-state rerun would repeat";

/// Writes system function call `e` in context `ty`. Asserts that `e` is
/// an integral `.sys_call`.
pub fn value(em: *Emitter, e: Ast.ExprId, ty: Type) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    assert(ex.tag(e) == .sys_call);
    assert(!ty.real);
    const w = ty.width;
    const sg = ty.signed;
    const args = ex.args(e);
    switch (r.typing.sys_calls[@backingInt(e)].?) {
        .make_signed, .make_unsigned => {
            try em.print("L.rs(", .{});
            const t = try expr.selfDetermined(em, args[0]);
            try em.print(", {d}, {d}, {})", .{ t.width, w, sg });
        },
        .time, .stime => |f| {
            const n = compile.typeOf(r, e);
            const scale = r.timeOf(r.scope).scale;
            try em.print("L.rs(L.k(s.units(.{{ .local_per_unit = {d}, .global_per_local = {d} }}){s}, 0), {d}, {d}, {})", .{
                scale.local_per_unit, scale.global_per_local, if (f == .stime) " & 0xffffffff" else "", n.width, w, sg,
            });
        },
        // §17.10: `vera` takes no plusargs, so every query is "no match": an
        // integer zero, the variable left alone.
        .test_plusargs, .value_plusargs => try em.print("L.rs(L.k(0, 0), 32, {d}, {})", .{ w, sg }),
        // §17.8: `$rtoi` truncates, `$realtobits` is the 64 bits.
        .rtoi => {
            try em.print("L.rs(L.rtoi(", .{});
            try expr_real.real(em, args[0]);
            try em.print("), 32, {d}, {})", .{ w, sg });
        },
        .realtobits => {
            try em.print("L.rs(L.realBits(", .{});
            try expr_real.real(em, args[0]);
            try em.print("), 64, {d}, {})", .{ w, sg });
        },
        // §17.6.5, which also writes its status argument.
        .q_full => {
            const lb = em.label();
            try em.print("L.rs(qf{d}: {{\n            const f{d} = s.queueFull(", .{ lb, lb });
            try expr.int64(em, args[0]);
            try em.print(");\n", .{});
            try assign.assignInt(em, args[1], try em.arena.print("f{d}.status", .{lb}));
            try em.print("            break :qf{d} L.k(@bitCast(f{d}.full), 0);\n            }}, 64, {d}, {})", .{ lb, lb, w, sg });
        },
        // §17.2 on the executable's descriptor table.
        .fopen => {
            em.keepFour(file_io, ex.mainTok(e));
            try em.print("L.rs(L.k(@as(u32, @truncate(@as(u64, @bitCast(try s.fopen(\"{f}\", ", .{std.zig.fmtString(r.file_name)});
            const n = try expr.selfDetermined(em, args[0]);
            try em.print(", {d}, ", .{n.width});
            if (args.len == 1) try em.print("null, 0", .{}) else {
                const m = try expr.selfDetermined(em, args[1]);
                try em.print(", {d}", .{m.width});
            }
            try em.print("))))), 0), 32, {d}, {})", .{ w, sg });
        },
        .fgetc, .ungetc, .ftell, .fseek, .rewind, .feof => |f| {
            try em.print("L.rs(L.k(@as(u32, @truncate(@as(u64, @bitCast(s.fileOp(.{t}", .{f});
            for (0..3) |i| {
                try em.print(", ", .{});
                if (i < args.len) try expr.int64(em, args[i]) else try em.print("null", .{});
            }
            try em.print("))))), 0), 32, {d}, {})", .{ w, sg });
        },
        .fgets => {
            em.keepFour(file_io, ex.mainTok(e));
            const lb = em.label();
            const target = try assign.targetType(em, args[0]);
            try em.print("L.rs(fl{d}: {{\n            const t{d} = try s.fileLine(", .{ lb, lb });
            try expr.int64(em, args[1]);
            try em.print(", {d});\n            if (t{d}.len != 0) {{\n", .{ target.width, lb });
            try assign.assignChars(em, args[0], try em.arena.print("t{d}", .{lb}));
            try em.print("            }}\n            break :fl{d} L.k(@as(u32, @truncate(t{d}.len)), 0);\n            }}, 32, {d}, {})", .{ lb, lb, w, sg });
        },
        .ferror => {
            em.keepFour(file_io, ex.mainTok(e));
            const lb = em.label();
            try em.print("L.rs(fe{d}: {{\n            const f{d} = s.fileError(", .{ lb, lb });
            try expr.int64(em, args[0]);
            try em.print(");\n", .{});
            try assign.assignChars(em, args[1], try em.arena.print("f{d}.text", .{lb}));
            try em.print("            break :fe{d} L.k(@as(u32, @truncate(@as(u64, @bitCast(f{d}.code)))), 0);\n            }}, 32, {d}, {})", .{ lb, lb, w, sg });
        },
        .sscanf, .fscanf => |f| try scan(em, e, f == .fscanf, ty),
        // §17.9, which writes its seed argument back.
        .random, .dist_uniform, .dist_normal, .dist_exponential, .dist_poisson, .dist_chi_square, .dist_t, .dist_erlang => |f| {
            if (args.len == 0) return em.print("L.rs(L.k(@as(u32, @bitCast(s.random())), 0), 32, {d}, {})", .{ w, sg });
            const lb = em.label();
            try em.print("L.rs(rd{d}: {{\n            const d{d} = s.dist(.{t}", .{ lb, lb, f.dist().? });
            for (0..3) |i| {
                if (i >= args.len) {
                    try em.print(", 0", .{});
                    continue;
                }
                try em.print(", @as(i32, @truncate(", .{});
                try expr.int64(em, args[i]);
                try em.print(" orelse 0))", .{});
            }
            try em.print(");\n            if (d{d}) |g{d}| {{\n", .{ lb, lb });
            try assign.assignInt(em, args[0], try em.arena.print("g{d}.seed", .{lb}));
            try em.print("            }}\n            break :rd{d} L.k(@as(u32, @bitCast(if (d{d}) |g{d}| g{d}.value else 0)), 0);\n            }}, 32, {d}, {})", .{ lb, lb, lb, lb, w, sg });
        },
        .clog2 => {
            try em.print("L.rs(L.k(L.clog2(", .{});
            const t = try expr.selfDetermined(em, args[0]);
            try em.print(", {d}), 0), 32, {d}, {})", .{ t.width, w, sg });
        },
        .fread => {
            em.keepFour(file_io, ex.mainTok(e));
            try em.print("L.rs(", .{});
            try fread(em, args);
            try em.print(", 32, {d}, {})", .{ w, sg });
        },
        .user => return em.refuse(expr_real.user_fn),
        else => return em.refuse("a VAMS driver or real system function"), // else: driver access stays with the interpreter; a real function is `real`'s
    }
}

/// Writes §17.2.4.4 `$fread`'s count: a packed target takes one binary
/// word; an entire memory takes words from the requested (or lowest)
/// address upward. Stores use the ordinary assignment path so observers
/// wake for changed values.
pub fn fread(em: *Emitter, args: []const Ast.ExprId) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    assert(args.len >= 2);
    const lb = em.label();
    const base = if (ex.tag(args[0]) == .ident) try em.slot(args[0]) else null;
    const arr = if (base) |at| r.decls.arrays.get(at) else null;
    try em.print("fr{d}: {{\n            const fd{d} = ", .{ lb, lb });
    try expr.int64(em, args[1]);
    try em.print(";\n", .{});
    if (arr) |memory| {
        const at = base.?;
        const width = em.slotWidth(at);
        try em.print("            const first{d}: i64 = ", .{lb});
        if (args.len > 2 and args[2] != .none) {
            try expr.int64(em, args[2]);
            try em.print(" orelse break :fr{d} L.k(0, 0)", .{lb});
        } else try em.print("{d}", .{memory.low});
        try em.print(";\n            const count{d}: i64 = ", .{lb});
        if (args.len > 3) {
            try expr.int64(em, args[3]);
            try em.print(" orelse break :fr{d} L.k(0, 0)", .{lb});
        } else try em.print("{d}", .{memory.count});
        try em.print(";\n            if (first{d} < {d} or first{d} > {d} or count{d} <= 0) break :fr{d} L.k(0, 0);\n", .{ lb, memory.low, lb, memory.high, lb, lb });
        try em.print("            const n{d}: u32 = @intCast(@min(count{d}, {d} - first{d} + 1));\n            var read{d}: i64 = 0;\n            for (0..n{d}) |k{d}| {{\n", .{ lb, lb, memory.high, lb, lb, lb, lb });
        try em.print("            const a{d}: u32 = {d} + @as(u32, @intCast(first{d} - {d})) + @as(u32, @intCast(k{d}));\n", .{ lb, at, lb, memory.low, lb });
        try em.print("            const word{d} = try s.fileWord(fd{d}, {d}, ", .{ lb, lb, width });
        const prior = .{ em.planes.off[at], lb, at, plane_words.words(width) };
        if (width <= 64) try em.print("M.get(s, {d} + (a{d} - {d}) * {d})", prior) else try em.print("M.getw(s, {d} + (a{d} - {d}) * {d}, {d})", prior ++ .{plane_words.words(width)});
        try em.print(");\n            read{d} += word{d}.n;\n            const v{d} = word{d}.value orelse break;\n            ", .{ lb, lb, lb, lb });
        try assign.storeElement(em, at, lb, .blocking);
        try em.print("v{d}, {f});\n            }}\n            break :fr{d} L.k(@as(u32, @truncate(@as(u64, @bitCast(read{d})))), 0);\n            }}", .{ lb, plane_words.full(width), lb, lb });
    } else {
        const ty = try assign.targetType(em, args[0]);
        try em.print("            const word{d} = try s.fileWord(fd{d}, {d}, ", .{ lb, lb, ty.width });
        _ = try expr.selfDetermined(em, args[0]);
        try em.print(");\n            if (word{d}.value) |v{d}| {{\n", .{ lb, lb });
        try assign.assignment(em, args[0], .{ .evaluated = .{ .label = lb, .ty = .{ .width = ty.width, .signed = false } } }, .blocking);
        try em.print("            }}\n            break :fr{d} L.k(@as(u32, @truncate(@as(u64, @bitCast(word{d}.n)))), 0);\n            }}", .{ lb, lb });
    }
}

// ---- private ----

/// §17.2.4.3 `$sscanf`/`$fscanf` call `e`: each output argument assigned as
/// the scan reaches it, the count in context `ty`.
fn scan(em: *Emitter, e: Ast.ExprId, from_file: bool, ty: Type) Error!void {
    const r = em.r;
    const ex = &r.file.exprs;
    const args = ex.args(e);
    assert(args.len >= 2);
    const w = ty.width;
    const sg = ty.signed;
    // `rt.State.scan` gives the scanner no time scale and no output widths.
    if (ex.tag(args[1]) == .str_literal) {
        const fm = r.file.str(ex.strOf(args[1]));
        if (scanNeedsContext(fm))
            return em.refuse("§17.2.4.3 a $sscanf/$fscanf %t (scaled by $timeformat), %u/%z (unformatted) or %m (the scope's path) conversion");
    }
    try em.xMeaning("`$sscanf`/`$fscanf`, which answer EOF for an x or z in the input or format", ex.mainTok(e));
    const lb = em.label();
    try em.print("L.rs(sc{d}: {{\n            var arena{d} = std.heap.ArenaAllocator.init(s.gpa);\n            defer arena{d}.deinit();\n", .{ lb, lb, lb });
    if (from_file) {
        em.keepFour(file_io, ex.mainTok(e));
        try em.print("            const file{d} = try s.scanFile(arena{d}.allocator(), ", .{ lb, lb });
        try expr.int64(em, args[0]);
        try em.print(", ", .{});
    } else {
        try em.print("            var c{d} = try s.scan(arena{d}.allocator(), ", .{ lb, lb });
        const in = try expr.selfDetermined(em, args[0]);
        try em.print(", {d}, ", .{in.width});
    }
    const fm = try expr.selfDetermined(em, args[1]);
    try em.print(", {d}, {d});\n", .{ fm.width, args.len - 2 });
    if (from_file) try em.print("            var c{d} = file{d}.scan;\n", .{ lb, lb });
    try em.print("            while (c{d}.next()) |x{d}| switch (x{d}.arg) {{\n", .{ lb, lb, lb });
    for (args[2..], 0..) |arg, k| {
        try em.print("            {d} => switch (x{d}.value) {{\n            .bits => |v{d}| {{\n", .{ k, lb, lb });
        try assign.assignWord(em, arg, try em.arena.print("L.k(v{d}[0], v{d}[1])", .{ lb, lb }), .{ .width = 64, .signed = true });
        try em.print("            }},\n            .chars => |t{d}| {{\n", .{lb});
        try assign.assignChars(em, arg, try em.arena.print("t{d}", .{lb}));
        try em.print("            }},\n            .real => |f{d}| {{\n", .{lb});
        try assign.assignWord(em, arg, try em.arena.print("L.k(@bitCast(@as(f64, f{d})), 0)", .{lb}), compile.real_type);
        try em.print("            }},\n            }},\n", .{});
    }
    try em.print("            else => unreachable,\n            }};\n", .{});
    if (from_file) try em.print("            s.finishFileScan(file{d}, c{d});\n", .{ lb, lb });
    try em.print("            break :sc{d} L.k(@as(u32, @truncate(@as(u64, @bitCast(c{d}.result)))), 0);\n            }}, 32, {d}, {})", .{ lb, lb, w, sg });
}

/// Whether scan format `fm` has a `%t`, `%u`, `%z` or `%m` conversion, after
/// any `*` and field width.
fn scanNeedsContext(fm: []const u8) bool {
    var i: usize = 0;
    while (i < fm.len) : (i += 1) {
        assert(i < fm.len);
        if (fm[i] != '%') continue;
        i += 1;
        while (i < fm.len and (fm[i] == '*' or std.ascii.isDigit(fm[i]))) i += 1;
        if (i < fm.len) switch (std.ascii.toLower(fm[i])) {
            't', 'u', 'z', 'm' => return true,
            else => {},
        };
    }
    return false;
}

test scanNeedsContext {
    // §17.2.4.3 Table 17-8: %t, %u, %z, %m need what `rt.State.scan` lacks.
    try std.testing.expect(scanNeedsContext("%d %t"));
    try std.testing.expect(scanNeedsContext("%*5u"));
    try std.testing.expect(scanNeedsContext("%M"));
    try std.testing.expect(!scanNeedsContext("%d %h %s %%"));
    try std.testing.expect(!scanNeedsContext("trailing %"));
}
