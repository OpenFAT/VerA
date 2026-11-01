//! An IEEE 1364 design in, Yosys RTLIL text out (`vera --emit-rtlil`): the
//! synthesis front door, digital only. One RTLIL `module` per source module,
//! a `wire` per port, net and variable, a `$`-cell per operator, gate and
//! instance, and one `process` per `always` block, which Yosys's `proc` pass
//! lowers; parameters are folded at their defaults. The text is what
//! `write_rtlil` prints, so `read_rtlil` takes it back.
//!
//! The subset is the structural, synthesizable one: ports, scalar and vector
//! nets and regs, `integer`s, continuous assigns, the A.3.4 gates that compute
//! a value, module instances, `always` blocks whose event control is edges
//! or levels and whose body is assignments, `if` and `case`, and an `initial`
//! block of constant assignments (the `init` attribute). Anything else is
//! refused by name (`error.Refused`, `why`), never emitted half-right: the
//! interpreter (`sim.digital`) is the reference for what the design does.
//!
//! ponytail: parameters fold at their defaults and an instance's override is
//! passed to Yosys as a cell parameter, which `hierarchy` can derive only for
//! a module it read from Verilog; emit one module per override set when a
//! parameterized child matters. Generate blocks, memories, loops, functions
//! and real values are refused rather than lowered: `sim.digital.Run` has
//! them elaborated, and an emitter over it (as `Emitter.zig` is) is the upgrade.
//!
//! Clauses: IEEE 1364-2005 §3.2 (`reg`), §4.2 (`integer`), §5.1 (operators),
//! §5.4 (expression widths), §5.5 (signedness), §6.1 (continuous assigns),
//! §7.2 to §7.4 (gates), §9.2 (assignments), §9.4 (`if`, `case`), §9.7
//! (event controls), §12.1 (instances), §12.2 (parameter defaults), §17
//! (system tasks, dropped: synthesis has no simulation output).
//!
//! Contents:
//! - `pub const Error`
//! - `pub fn emit(arena: Allocator, source: []const u8, opts: digital.Options, bag: *diag.Bag, why: *[]const u8) Error![]const u8`

const std = @import("std");
const assert = std.debug.assert;
const Front = @import("frontend");
const Ast = Front.Ast;
const diag = @import("diag");
const deep = @import("base").deep_stack;
const digital = @import("sim").digital;
const Emitter = @import("rtlil_emitter.zig").Emitter;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// `Refused`: a construct outside the subset, named in `emit`'s `why`.
/// `DigitalFailed`: the preprocessor or parser refused the source, or the
/// design is one `vera --run` rejects (E1100), with the diagnostics in the
/// bag. Either way nothing is returned.
pub const Error = @import("rtlil_emitter.zig").Error;

/// Preprocesses and parses `source` as `vera --run` does (IEEE 1364, no annex
/// D prelude, `opts.more` after it) and returns the RTLIL of every module in
/// it, allocated in `arena`. A source the parser refuses, or an instance
/// connection to no port of its module, is `error.DigitalFailed` with the
/// diagnostics in `bag`; a construct outside the subset is `error.Refused`
/// with `why` set (`line N: ...`), and nothing is emitted. Runs on a
/// reserved deep stack (`deep_stack.runGuarded`): the walks recurse on the
/// source's nesting, and one that exhausts the stack is refused.
pub fn emit(arena: Allocator, source: []const u8, opts: digital.Options, bag: *diag.Bag, why: *[]const u8) Error![]const u8 {
    return deep.runGuarded(0, emitDeep, .{ arena, source, opts, bag, why });
}

// ---- private ----

fn emitDeep(arena: Allocator, source: []const u8, opts: digital.Options, bag: *diag.Bag, why: *[]const u8) Error![]const u8 {
    const pp = Front.preprocessor.process(arena, source, .{ .file_name = opts.file_name, .include_dirs = opts.include_dirs, .defines = opts.defines, .std_defs = false, .more = more: {
        const more = try arena.alloc(Front.preprocessor.File, opts.more.len);
        for (opts.more, more) |u, *f| f.* = .{ .name = u.name, .text = u.text };
        break :more more;
    }, .bag = bag }) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.PreprocessFailed => error.DigitalFailed,
    };
    var tokens = try Front.lexer.tokenize(arena, pp.text, null);
    var parser = Front.Parser.Parser.init(arena, pp.text, tokens.items(.tag), tokens.items(.start), bag);
    parser.digital = true;
    parser.setLanguage(opts.language);
    const file = try arena.create(Ast.SourceFile);
    file.* = parser.parseSourceFile() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => return error.DigitalFailed,
    };
    var out: Writer.Allocating = .init(arena);
    var e: Emitter = .{ .arena = arena, .file = file, .text = pp.text, .starts = tokens.items(.start), .out = &out.writer, .why = why, .bag = bag };
    try e.design();
    assert(out.written().len != 0); // `autoidx 1` at least.
    return out.written();
}
