//! Test support for the module's tests and `tests/unit.zig`: Verilog-AMS
//! source in, a lowering verdict (the `Lowered` tables, or the diagnostics)
//! out. Analysed only by a test; nothing in the pass calls it.
//!
//! Cites: none (VerA's test harness); the cases that use it cite their clauses.
//!
//! Contents:
//! - `pub const InitError = preprocessor.Error || Parser.Error`
//! - `pub const VerdictError = InitError || Error || error{TestUnexpectedResult}`
//! - `pub const Case = struct`
//! - `pub const Harness = struct` (`init`, `lower`, `lowerOnStack`, `count`, `dump`, `deinit`)
//! - `pub fn expectVerdict(src: []const u8, want: ?diag.Code) VerdictError!void`
//! - `pub fn expectBodyVerdict(decls: []const u8, body: []const u8, want: ?diag.Code) VerdictError!void`
//! - `pub fn expectBodies(cases: []const Case) VerdictError!void`

const std = @import("std");
const assert = std.debug.assert;
const Ast = @import("frontend").Ast;
const lexer = @import("frontend").lexer;
const preprocessor = @import("frontend").preprocessor;
const annex_e = @import("frontend").annex_e;
const Parser = @import("frontend").Parser;
const Mir = @import("ir").Mir;
const diag = @import("diag");
const Lower = @import("Lower.zig");
const Lowered = Lower.Lowered;
const Error = Lower.Error;

/// Every way `Harness.init` fails: the source did not preprocess or parse
/// (its diagnostics are in the harness's bag), or memory ran out.
pub const InitError = preprocessor.Error || Parser.Error;

/// Every way the `expect*` checks fail: `TestUnexpectedResult` when the
/// verdict differs from the one wanted (both are printed), or the harness's
/// own `InitError` and `Lower.Error`.
pub const VerdictError = InitError || Error || error{TestUnexpectedResult};

/// Test support: one rule case for `expectBodies`, a module body and the code
/// it must report, or null for a body that must lower with no error at all.
/// The oracle is the LRM sentence each case cites: every refusal has a legal
/// neighbour beside it, so a blanket refusal fails the table.
pub const Case = struct { src: []const u8, code: ?diag.Code };

/// Test support for the `analog/*.zig` tests: one source file preprocessed
/// (the annex E prelude included), parsed and ready to lower, with the arena
/// and the diagnostic bag a test reads afterwards. Analysed only by a test.
///
/// Pinned in place by `init`: `low` points at `file`, `mir` and `bag`, so the
/// value must not move until `deinit`.
pub const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    file: Ast.SourceFile,
    mir: Mir,
    bag: diag.Bag,
    low: Lower,

    /// Prepares `h` to lower `src`. Every buffer lives in an arena over
    /// `gpa`, which `deinit` frees whatever lowering returned.
    pub fn init(h: *Harness, gpa: std.mem.Allocator, src: []const u8) InitError!void {
        h.* = .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .file = .empty,
            .mir = .{},
            .bag = undefined,
            .low = undefined,
        };
        errdefer h.arena_state.deinit();
        const arena = h.arena_state.allocator();
        h.bag = diag.Bag.init(arena);
        const text = (try preprocessor.process(arena, src, .{ .bag = &h.bag })).text;
        const toks = try lexer.tokenize(arena, text, null);
        var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &h.bag);
        const parse = try arena.create(Ast.SourceFile);
        parse.* = try p.parseSourceFile();
        // The annex E prelude's modules lead `file.modules`. Elaboration
        // writes the overlay, never the parse.
        h.file = parse.overlay(.{ .builtin_modules = annex_e.spice_module_count });
        h.low = Lower.init(arena, &h.mir, &h.file, text, toks.items(.start), &h.bag);
        assert(h.low.file == &h.file);
        assert(h.low.mir == &h.mir);
    }

    /// Lowers the file: the tables, or null when an error was reported.
    /// Any other error (`NoModule`, OOM) is returned.
    pub fn lower(h: *Harness) Error!?Lowered {
        assert(h.low.mir == &h.mir); // `init`'s pin still holds: `h` has not moved
        return h.low.lowerFile() catch |e| switch (e) {
            error.DiagnosticsReported => return null,
            else => |other| return other, // else: anything but a verdict fails the test
        };
    }

    /// Lowers the file as `lower` does, on a thread whose stack is
    /// `stack_bytes`: for a test of a walk whose depth the input controls,
    /// sized so a walk that recursed on that depth would overflow it.
    /// Errors: `lower`'s, or `std.Thread.SpawnError` when no thread starts.
    pub fn lowerOnStack(h: *Harness, stack_bytes: usize) (Error || std.Thread.SpawnError)!?Lowered {
        assert(stack_bytes >= 64 << 10); // below that no lowering fits, recursive or not
        var result: Error!?Lowered = error.NoModule;
        const t = try std.Thread.spawn(.{ .stack_size = stack_bytes }, lowerInto, .{ h, &result });
        t.join();
        return result;
    }

    fn lowerInto(h: *Harness, out: *Error!?Lowered) void {
        out.* = h.lower();
    }

    /// Returns how many diagnostics of `code` were recorded.
    pub fn count(h: *const Harness, code: diag.Code) usize {
        var n: usize = 0;
        for (0..h.bag.count()) |i| n += @intFromBool(h.bag.at(i).code == code);
        assert(n <= h.bag.count());
        return n;
    }

    /// Prints every recorded diagnostic, for a failing test's report.
    pub fn dump(h: *const Harness) void {
        for (0..h.bag.count()) |i| {
            const d = h.bag.at(i);
            std.debug.print("  {t}: {s}\n", .{ d.code, d.message });
        }
    }

    /// Frees everything `init` made.
    pub fn deinit(h: *Harness) void {
        h.low.deinit();
        h.arena_state.deinit();
    }
};

/// Test support, the one check every `analog/*.zig` table of cases goes
/// through: lowers `src` and compares the verdict with `want`. Null means it
/// lowers with no error at all; a code means at least one diagnostic of that
/// code was reported. On a mismatch, prints the source and every diagnostic.
pub fn expectVerdict(src: []const u8, want: ?diag.Code) VerdictError!void {
    assert(src.len != 0);
    var h: Harness = undefined;
    try h.init(std.testing.allocator, src);
    defer h.deinit();
    const out = try h.lower();
    const ok = if (want) |code| h.count(code) != 0 else out != null and h.bag.err_count == 0;
    if (ok) return;
    std.debug.print("want {s}, got:\n", .{if (want) |code| @tagName(code) else "no error"});
    h.dump();
    std.debug.print("source:\n{s}\n", .{src});
    return error.TestUnexpectedResult;
}

/// Test support: `expectVerdict` over a two-terminal module `m(p, n)` whose
/// module-scope declarations are `decls` and whose analog block is `body`,
/// followed by one `I(p, n) <+ V(p, n)` so the module has an equation.
pub fn expectBodyVerdict(decls: []const u8, body: []const u8, want: ?diag.Code) VerdictError!void {
    if (want) |code| assert(@tagName(code)[0] == 'E'); // a verdict is an error code or none
    const src = try std.testing.allocator.print(
        \\module m(p, n);
        \\  inout p, n;
        \\  electrical p, n;
        \\{s}
        \\  analog begin
        \\{s}
        \\    I(p, n) <+ V(p, n);
        \\  end
        \\endmodule
    , .{ decls, body });
    defer std.testing.allocator.free(src);
    return expectVerdict(src, want);
}

/// Test support: `expectVerdict` over every case, stopping at the first that
/// fails. Each `src` is a module body with electrical ports `p` and `q`, a real
/// parameter `g`, and the variables `x`, `r` (real), `iv`, `seed` (integer)
/// and `sv` (string).
pub fn expectBodies(cases: []const Case) VerdictError!void {
    assert(cases.len != 0);
    const gpa = std.testing.allocator;
    for (cases) |c| {
        const src = try gpa.print(
            \\module m(p, q);
            \\  inout p, q;
            \\  electrical p, q;
            \\  parameter real g = 1.0;
            \\  real x, r;
            \\  integer iv, seed;
            \\  string sv;
            \\{s}
            \\endmodule
        , .{c.src});
        defer gpa.free(src);
        try expectVerdict(src, c.code);
    }
}

// ---- private ----
