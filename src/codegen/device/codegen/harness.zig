//! Test support for codegen: one Verilog-A source preprocessed, parsed and
//! lowered into MIR, with `gen*` running proof and codegen over it. Used by
//! the codegen tests (`tests/unit.zig`) and the display tests beside
//! `cg_display.zig`. Analysed only by a test. No clause of its own.

const std = @import("std");
const codegen = @import("../codegen.zig");
const Mir = @import("ir").Mir;
const Lower = @import("analog").Lower;
const Lowered = @import("ir").Lowered;
const proof = @import("prove").proof;
const diag = @import("diag");
const Ast = @import("frontend").Ast;
const Preprocessor = @import("frontend").Preprocessor;
const Lexer = @import("frontend").Lexer;
const Parser = @import("frontend").Parser;
const Output = codegen.Output;
const generate = codegen.generate;

/// One source lowered into MIR, owning everything in `arena_state`; `gen*`
/// runs proof and codegen over it. Call `deinit` when done.
pub const Harness = struct {
    arena_state: std.heap.ArenaAllocator,
    file: Ast.SourceFile,
    mir: Mir,
    lowered: Lowered,
    bag: diag.Bag,

    /// Lowers `src` into `out`; diagnostics land in `out.bag`. Everything
    /// `out` holds lives in its arena on `gpa`: free it with `deinit`, or pass
    /// an arena as `gpa` and let it go with that.
    pub fn run(gpa: std.mem.Allocator, src: []const u8, out: *Harness) !void {
        return runOver(gpa, src, &.{}, out);
    }

    /// `run` with §3.4 `--param` compile-time overrides.
    pub fn runOver(gpa: std.mem.Allocator, src: []const u8, over: []const Lower.ParamOverride, out: *Harness) !void {
        out.* = .{
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .file = .empty,
            .mir = .{},
            .lowered = undefined,
            .bag = undefined,
        };
        const arena = out.arena_state.allocator();
        // One diagnostic bag threaded through every stage (diag.zig).
        out.bag = diag.Bag.init(arena);
        const pp = try Preprocessor.process(arena, src, .{ .bag = &out.bag });
        const text = pp.text;
        const toks = try Lexer.Lexer.tokenize(arena, text);
        var p = Parser.Parser.init(arena, text, toks.items(.tag), toks.items(.start), &out.bag);
        const parse = try arena.create(Ast.SourceFile);
        parse.* = try p.parseSourceFile();
        // The annex E prelude came with `Preprocessor.process` (std_defs is on by
        // default), so its modules are the leading entries of `file.modules`.
        // Elaboration writes the overlay, never the parse.
        out.file = parse.overlay(.{ .builtin_modules = Preprocessor.spice_module_count });
        // `directives` as `root.compile` passes them: a §10.3
        // `default_transition` reaches §4.5.8 only through it.
        out.lowered = (try Lower.lower(arena, &out.mir, &out.file, text, toks.items(.start), &out.bag, .{
            .param_overrides = over,
            .directives = pp.directives,
        })).lowered;
    }

    /// `genOut`'s device text.
    pub fn gen(self: *Harness, gpa: std.mem.Allocator) ![]const u8 {
        return (try self.genOut(gpa)).text;
    }

    /// `gen` with §9.4 display tasks emitted: the printing artifact. Reports
    /// to no bag.
    pub fn genDisplay(self: *Harness, gpa: std.mem.Allocator) ![]const u8 {
        var fatal = false;
        return (try self.proveAndGenerate(gpa, .{ .display = .emit }, &fatal)).text;
    }

    /// Proves with `gpa` and generates with the default options into the
    /// harness bag; a fatal generation still returns its output.
    pub fn genOut(self: *Harness, gpa: std.mem.Allocator) !Output {
        var fatal = false;
        return self.proveAndGenerate(gpa, .{ .diags = &self.bag }, &fatal);
    }

    /// Proves and generates with `opts`, `.diags` set to the harness bag.
    /// Fails the test with the bag's count when generation is fatal: every
    /// caller asserts on a device that was meant to compile.
    pub fn genWith(self: *Harness, opts: codegen.Options) !Output {
        var o = opts;
        o.diags = &self.bag;
        var fatal = false;
        const out = try self.proveAndGenerate(std.testing.allocator, o, &fatal);
        if (fatal) return error.GenerationWasFatal;
        return out;
    }

    // ponytail: the harness hands `generate` its arena as the output gpa, so
    // `deinit` reclaims the result with everything else and no test needs a
    // matching free. Ceiling: these fixtures are kilobytes; the arena regrow
    // cost `generate`'s gpa parameter exists to avoid only bites at MB scale.
    // The harness bag is arena-lived and never detached, so unlike the
    // driver's it is still the right one to hand codegen.
    fn proveAndGenerate(self: *Harness, gpa: std.mem.Allocator, opts: codegen.Options, fatal: *bool) !Output {
        const v = try proof.proveOpts(gpa, &self.mir, &self.lowered, .{}, &self.bag);
        defer v.deinit(gpa);
        const a = self.arena_state.allocator();
        return generate(a, a, &self.mir, &self.lowered, v, fatal, opts);
    }

    /// Frees everything `run` lowered and every output generated since.
    pub fn deinit(self: *Harness) void {
        self.arena_state.deinit();
    }
};
