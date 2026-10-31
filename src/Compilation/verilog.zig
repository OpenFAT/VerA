//! `--emit-verilog`: an analysed `.va` in, the behavioural Verilog module of
//! the same name and ports out (`-o PATH`, else `Outcome.text`). The
//! abstraction is `verilog`'s (`src/codegen/verilog`); this reads the
//! `--digital-pins` file or list and reports a refusal.
//!
//! Cites: none of the LRM's beyond the emitter's.
//!
//! Contents:
//! - `pub fn emit(io: Io, arena: Allocator, result: *const Result, v: Request.Verilog, out_path: ?[]const u8, in_path: []const u8, err: *Io.Writer, o: *Outcome) request.CompileError!void`

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Preprocessor = @import("frontend").Preprocessor;
const beh_verilog = @import("verilog");
const request = @import("request.zig");
const Request = request.Request;
const Outcome = request.Outcome;
const Result = @import("Result.zig");
const readFailed = @import("read_failed.zig").readFailed;

/// Emits the module to `out_path`, else onto `o.text` (arena). A model the
/// abstraction cannot take is refused (status 1) with nothing written; a pin
/// file that exists and cannot be read is status 2.
/// Asserts that `in_path` names the source.
pub fn emit(
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
        const text = Preprocessor.readText(io, .cwd(), spec, arena) catch |e| switch (e) {
            error.FileNotFound => spec,
            else => {
                try readFailed(err, spec, e);
                return o.done(2);
            },
        };
        var it = std.mem.tokenizeAny(u8, text, ", \t\r\n");
        while (it.next()) |n| try digital.append(arena, n);
    }
    var why: []const u8 = "";
    const text = beh_verilog.emit(arena, result.mir, result.lowered, .{
        .digital = digital.items,
        .power_pins = v.power_pins,
        .vdd = v.vdd,
        .source = std.fs.path.basename(in_path),
    }, &why) catch |e| switch (e) {
        error.Refused => {
            try err.print("error: {s}: --emit-verilog: {s}\n", .{ in_path, why });
            return o.done(1);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (out_path) |p| {
        Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = text }) catch |e| {
            try err.print("error: cannot write `{s}`: {t}\n", .{ p, e });
            return o.done(1);
        };
    } else o.text = text;
}
