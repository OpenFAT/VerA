//! `--emit-verilog`: an analysed `.va` in, the behavioural Verilog module of
//! the same name and ports out (`-o PATH`, else `Outcome.text`). The
//! abstraction is `verilog`'s (`src/codegen/verilog`); this reads the
//! `--digital-pins` file or list and reports a refusal.
//!
//! Cites: none of the LRM's beyond the emitter's.
//!
//! Contents:
//! - `pub fn emit(gpa: Allocator, io: Io, arena: Allocator, result: *const Result, v: Request.Verilog, out_path: ?[]const u8, in_path: []const u8, err: *Io.Writer, o: *Outcome) request.CompileError!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const preprocessor = @import("frontend").preprocessor;
const beh_verilog = @import("verilog");
const request = @import("request.zig");
const Request = request.Request;
const Outcome = request.Outcome;
const Result = @import("Result.zig");
const readFailed = @import("read_failed.zig").readFailed;

/// Emits the module to `out_path`, else onto `o.text` (arena); `gpa` backs
/// the emitter's scratch, freed before this returns. A model the
/// abstraction cannot take is refused (status 1) with nothing written; a pin
/// file that exists and cannot be read is status 2.
/// Asserts that `in_path` names the source.
pub fn emit(
    gpa: Allocator,
    io: Io,
    arena: Allocator,
    result: *const Result,
    v: Request.Verilog,
    out_path: ?[]const u8,
    in_path: []const u8,
    err: *Io.Writer,
    o: *Outcome,
) request.CompileError!void {
    assert(in_path.len != 0);
    assert(o.text.len == 0);
    // `--digital-pins` names a file of pins when one exists, else is the list.
    var digital: std.ArrayList([]const u8) = .empty;
    if (v.digital_pins) |spec| {
        const text = preprocessor.readText(io, .cwd(), spec, arena) catch |e| switch (e) {
            error.FileNotFound => spec,
            else => {
                try readFailed(err, spec, e);
                return o.done(2);
            },
        };
        var it = std.mem.tokenizeAny(u8, text, ", \t\r\n");
        while (it.next()) |n| try digital.append(arena, n);
    }
    var why: beh_verilog.Refusal = undefined;
    var out: Io.Writer.Allocating = .init(arena);
    beh_verilog.emit(gpa, result.mir, result.lowered, .{
        .digital = digital.items,
        .power_pins = v.power_pins,
        .vdd = v.vdd,
        .source = std.fs.path.basename(in_path),
    }, &out.writer, &why) catch |e| switch (e) {
        error.Refused => {
            try err.print("error: {s}: --emit-verilog: {f}\n", .{ in_path, why });
            return o.done(1);
        },
        // `Allocating` reports its own allocation failure as `WriteFailed`.
        error.OutOfMemory, error.WriteFailed => return error.OutOfMemory,
    };
    const text = out.written();
    if (out_path) |p| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text }) catch |e| {
            try err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
            return o.done(1);
        };
    } else o.text = text;
}
