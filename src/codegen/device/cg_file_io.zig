//! A §9.5 call in the printing artifact's display unit -> its file kernel
//! call: `$fopen`/`$fclose`/`$fflush`, the §9.5.2 output tasks with their
//! §9.4.3 formats, the §9.5.4 readers through their count's latch, and the
//! §9.4.1 monitor's registration and watched values.
//! Cites: §9.4.1, §9.5, §9.5.1, §9.5.2, §9.5.4, §9.5.6, §9.5.9.
//!
//! Contents:
//! - `pub fn emitFileCall(g: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void`
//! - `pub fn emitMonitorArm(g: *Gen, args: []const Mir.Value) Error!void`
//! - `pub fn monitorValues(g: *Gen, ops: []const cg_format.PrintArg) Error!void`
//! - `pub fn monitorKey(g: *const Gen, args: []const Mir.Value) i64`

const std = @import("std");
const assert = std.debug.assert;
const Mir = @import("ir").Mir;
const cg = @import("codegen.zig");
const Gen = cg.Gen;
const Error = cg.Error;
const cg_display = @import("cg_display.zig");
const cg_format = @import("cg_format.zig");

/// Emits one §9.5 call in the display unit. `site` is the call's MIR
/// instruction id, the per-call-site key for its formatted bytes (`zSBuf`).
/// Aborts codegen for a callee `codegen.isFileCall` does not route here.
pub fn emitFileCall(g: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    assert(Mir.callee.isFileCall(c));
    assert(g.cur.emitting_display);
    assert(site < g.mir.instCount());
    const len_before = g.out.items.len;
    // §9.5.1/§9.5.2/§9.5.6: `$fclose`, `$fflush` and the five output tasks are
    // tasks, so `Mir.callee.ty` types them real like every void call, but the
    // kernels return integers. The cast lives here because the value only
    // gives the display chain something to carry (`Lower.sequenceFileCall`).
    const wrap = Mir.callee.ty(c) == .real;
    // `$fscanf$real` is the one real-typed §9.5 call whose kernel (`zScanR`)
    // already returns f64, so it takes no `@floatFromInt`.
    const from_int = c != .@"$fscanf$real";
    // An integer result is latched for the other units (`file_kernels.zFRes`).
    const keep = Mir.callee.ty(c) == .int;
    if (wrap) try g.b("S.con(", .{});
    if (wrap and from_int) try g.b("@as(f64, @floatFromInt(", .{});
    if (keep) try g.b("zFKeep({d}, ", .{site});
    // §9.5.4.1/§9.5.4.2 a read's line is copied when the read runs, so its
    // readers see it however late codegen places them (`zFLatch`).
    const latch = c == .@"$fgets" or c == .@"$fscanf";
    if (latch) try g.b("zFLatch({d}, ", .{site});
    try emitFileCallInner(g, c, args, site);
    if (latch) {
        try g.b(", ", .{});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        try g.b(")", .{});
    }
    if (keep) try g.b(")", .{});
    if (wrap and from_int) try g.b("))", .{});
    if (wrap) try g.b(")", .{});
    assert(g.out.items.len > len_before);
}

/// Emits §9.4.1's registration half: arms the monitor latch of the site keyed
/// by `args[0]` (`str_store.zMonitorArm`).
pub fn emitMonitorArm(g: *Gen, args: []const Mir.Value) Error!void {
    assert(args.len != 0);
    // `call_gate` arms a monitor only in a printing artifact's display unit.
    assert(g.cur.emitting_display);
    assert(g.display == .emit);
    return g.b("S.con(zMonitorArm({d}))", .{monitorKey(g, args)});
}

/// §9.4.1 what a monitor watches: one u64 per argument (a real's or integer's
/// bit pattern, a string's hash) for `zMonitor` to compare with the last
/// reported step. `$abstime` and `$realtime` are left out, "with the exception
/// of the $abstime or $realtime system functions".
pub fn monitorValues(g: *Gen, ops: []const cg_format.PrintArg) Error!void {
    assert(ops.len <= std.math.maxInt(u32));
    const len_before = g.out.items.len;
    try g.b("&[_]u64{{", .{});
    var first = true;
    for (ops) |p| {
        const v = g.an.rv(p.v);
        const def = g.mir.valueDef(v);
        if (def == .inst_result and g.mir.instOp(def.inst_result) == .call) {
            const callee = g.mir.instData(def.inst_result).call.callee;
            if (callee == .@"$abstime" or callee == .@"$realtime") continue;
        }
        if (first) try g.b(" ", .{}) else try g.b(", ", .{});
        first = false;
        switch (g.an.tyOf(v)) {
            .real => {
                try g.b("@as(u64, @bitCast((", .{});
                try g.renderVal(v, .real);
                try g.b(").val()))", .{});
            },
            .int => {
                try g.b("@as(u64, @bitCast(@as(i64, ", .{});
                try g.renderVal(v, .int);
                try g.b(")))", .{});
            },
            .str => {
                try g.b("std.hash.Wyhash.hash(0, ", .{});
                try g.renderVal(v, .str);
                try g.b(")", .{});
            },
            .wide => unreachable, // lowering hands a task no wide value: a whole wide `reg` read is E0222
        }
    }
    if (first) try g.b("}}", .{}) else try g.b(" }}", .{});
    assert(g.out.items.len >= len_before + "&[_]u64{}".len);
}

/// The site key `Lower.armMonitor` put first in a monitor's registration and
/// report: a literal, so it can key a comptime latch.
pub fn monitorKey(g: *const Gen, args: []const Mir.Value) i64 {
    assert(args.len != 0);
    const def = g.mir.valueDef(g.an.rv(args[0]));
    assert(def == .int_const);
    // `Lower.armMonitor` numbers the sites from 0.
    assert(def.int_const >= 0);
    return def.int_const;
}

// ---- private ----

fn emitFileCallInner(g: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    assert(Mir.callee.isFileCall(c));
    assert(site < g.mir.instCount());
    switch (c) {
        // §9.5.2's five output tasks, and the two descriptor tasks that take no
        // text (`callee.zig`'s `.file_out` family).
        .@"$fdisplay",
        .@"$fwrite",
        .@"$fstrobe",
        .@"$fmonitor",
        .@"$fdebug",
        .@"$fclose",
        .@"$fflush",
        => return emitFileWrite(g, c, args, site),
        // §9.5.1 Syntax 9-2: one argument is a multichannel descriptor, two are a
        // file descriptor. The presence of the type argument IS the discriminator,
        // and it is the only thing that decides which encoding comes back.
        .@"$fopen" => {
            try g.b("zFOpen(", .{});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.f_zero, .str);
            try g.b(", ", .{});
            if (args.len > 1) try g.renderVal(args[1], .str) else try g.b("\"\"", .{});
            return g.b(", {s})", .{if (args.len > 1) "false" else "true"});
        },
        // The one-argument descriptor operations, in clause order.
        .@"$fgets", .@"$ftell", .@"$feof", .@"$ferror" => {
            try g.b("{s}(", .{switch (c) {
                .@"$fgets" => "zFGets", // §9.5.4.1: the character count
                .@"$ftell" => "zFTell", // §9.5.5
                .@"$feof" => "zFEof", // §9.5.8
                else => "zFError", // else: `$ferror`, the one left (§9.5.7) — the errno
            }});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
            return g.b(")", .{});
        },
        // §9.5.5 `$rewind(fd)` "is equivalent to $fseek (fd,0,0)": the clause's own
        // words, so it is the same kernel with the constants written in.
        .@"$rewind" => {
            try g.b("zFSeek(", .{});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
            return g.b(", 0, 0)", .{});
        },
        .@"$fseek" => {
            try g.b("zFSeek(", .{});
            try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 1) args[1] else Mir.Value.zero, .int);
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 2) args[2] else Mir.Value.zero, .int);
            return g.b(")", .{});
        },
        // §9.5.4.2 the count. Composed here because `file_kernels.zig` cannot
        // call `str_scan.zScan` (each kernel file compiles alone). Scan the
        // unread window, widened until the scan stops inside it, then consume
        // exactly `zScan.used`: "the offending input character is left
        // unread". Operands are (fd, format); the item readers below re-scan
        // the window `zFTake` leaves latched.
        .@"$fscanf" => {
            const fd = if (args.len > 0) args[0] else Mir.Value.zero;
            try g.b("zk{d}: while (true) {{ const zw = zFWindow(", .{site});
            try g.renderVal(fd, .int);
            try g.b("); const zr = zScan(zw, ", .{});
            try g.renderVal(if (args.len > 1) args[1] else Mir.Value.f_zero, .str);
            // A scan that read to the end of a full window runs again over a
            // wider one (`file_kernels.zFMore`).
            try g.b(", -1); if (zFMore(", .{});
            try g.renderVal(fd, .int);
            try g.b(", zr.used)) continue; break :zk{d} zFTake(", .{site});
            try g.renderVal(fd, .int);
            return g.b(", zr.n, @intCast(zr.used)); }}", .{});
        },
        // The synthetic readers, all of which take the count first; see
        // `file_kernels.zFLine` for why that operand is there and why it is read.
        .@"$fgets$str" => return emitReadLine(g, args),
        .@"$ferror$str" => return emitLine(g, args, "zFErrorStr"),
        // §9.5.4.2's items: the same three flavours `$sscanf` has, over the line the
        // count's read latched. `(count, fd, format, item)`.
        .@"$fscanf$int", .@"$fscanf$real", .@"$fscanf$str" => {
            try g.b("{s}(", .{switch (c) {
                .@"$fscanf$int" => "zScanI",
                .@"$fscanf$real" => "zScanR",
                else => "zScanS", // else: `$fscanf$str`, the one left
            }});
            try emitReadLine(g, args);
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 2) args[2] else Mir.Value.f_zero, .str);
            try g.b(", ", .{});
            try g.renderVal(if (args.len > 3) args[3] else Mir.Value.zero, .int);
            return g.b(")", .{});
        },
        else => return g.abort(.E1020, "VerA: unhandled §9.5 call `{s}`", .{@tagName(c)}), // else: `emitCall` routes only `callee.isFileCall` here, and every one of those has a prong above
    }
}

/// The line a `$fgets`/`$fscanf` reader reads: its count's site latch
/// (`zFLineAt`), so the value is the one the read statement left. A count that
/// is not a direct read call (no site to name) reads the channel (`zFLine`).
fn emitReadLine(g: *Gen, args: []const Mir.Value) Error!void {
    assert(args.len >= 2); // A synthetic reader carries its count and fd.
    const n = if (args.len > 0) args[0] else Mir.Value.zero;
    const def = g.mir.valueDef(g.an.rv(n));
    if (def == .inst_result and g.mir.instOp(def.inst_result) == .call) {
        const callee = g.mir.instData(def.inst_result).call.callee;
        if (callee == .@"$fgets" or callee == .@"$fscanf") {
            try g.b("zFLineAt({d}, ", .{@backingInt(def.inst_result)});
            try g.renderVal(n, .int);
            return g.b(")", .{});
        }
    }
    return emitLine(g, args, "zFLine");
}

/// The first two operands every synthetic reader carries: count, then fd.
inline fn emitLine(g: *Gen, args: []const Mir.Value, comptime kernel: []const u8) Error!void {
    comptime assert(kernel.len != 0);
    assert(args.len >= 2);
    const len_before = g.out.items.len;
    try g.b(kernel ++ "(", .{});
    try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
    try g.b(", ", .{});
    try g.renderVal(if (args.len > 1) args[1] else Mir.Value.zero, .int);
    try g.b(")", .{});
    assert(g.out.items.len > len_before + kernel.len);
}

/// §9.5.2's five output tasks, plus `$fclose`/`$fflush`. The descriptor is
/// `args[0]`; the rest is formatted as the §9.4.1 task of the same base name
/// (`$fwrite`, like `$write`, does not end the line). Syntax 9-3 has no
/// radix-suffixed spelling, so the default conversion is the operand's own.
fn emitFileWrite(g: *Gen, c: Mir.Callee, args: []const Mir.Value, site: usize) Error!void {
    assert(Mir.callee.isFileCall(c));
    // §9.5.1 `$fclose` and §9.5.6 `$fflush` take a descriptor and no text.
    if (c == .@"$fclose" or c == .@"$fflush") {
        try g.b("{s}(", .{if (c == .@"$fclose") "zFClose" else "zFFlush"});
        try g.renderVal(if (args.len > 0) args[0] else Mir.Value.zero, .int);
        return g.b(")", .{});
    }
    // §9.4.1 a monitor report carries its site key ahead of the descriptor.
    const mon = c == .@"$fmonitor";
    if (mon) assert(args.len > 0);
    const all = if (mon) args[1..] else args;
    const rest = if (all.len > 0) all[1..] else all;
    assert(rest.len <= args.len);
    var fmt: std.ArrayList(u8) = .empty;
    var ops: cg_display.Ops = .empty;
    try cg_display.buildArgs(g, rest, &fmt, &ops);
    // `appendConv` writes a `{…}` per operand.
    assert(ops.items.len <= fmt.items.len);
    // The §9.4.1 task §9.5.2 names this one after decides the newline:
    // `$write` is the member that does not end the line, and so is `$fwrite`.
    if (cg_display.endsLine(c)) try fmt.append(g.arena, '\n');

    // The text is formatted into this call site's own scratch row and then
    // written, which is `emitStringFormat`'s sink with a descriptor instead of a
    // string variable. An overrun is E1011, as for §9.5.3.
    try g.b("zf: {{ ", .{});
    try cg_display.emitScratch(g, ops.items, site);
    // §9.5.2 makes `$fmonitor` "just like" `$monitor` with a descriptor in
    // front, so §9.4.1's change condition travels with it: the record is
    // composed either way, and `zMonitor` decides whether it is written.
    if (mon) try g.b("const zt = ", .{}) else try g.b("break :zf zFPut(", .{});
    if (!mon) {
        try g.renderVal(if (all.len > 0) all[0] else Mir.Value.zero, .int);
        try g.b(", ", .{});
    }
    try cg_display.emitBufPrint(g, fmt.items, ops.items, site);
    if (mon) {
        try g.b("; break :zf if (zMonitor({d}, ", .{monitorKey(g, args)});
        try monitorValues(g, ops.items);
        try g.b(", zt)) |zm| zFPut(", .{});
        try g.renderVal(if (all.len > 0) all[0] else Mir.Value.zero, .int);
        try g.b(", zm) else 0; }}", .{});
    } else try g.b("); }}", .{});
}
