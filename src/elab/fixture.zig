//! Test fixtures for the elaboration unit: source text → a parsed
//! `Ast.SourceFile` plus the `Ctx` `elaborate` takes, through the lexer,
//! parser and (for Annex E's prelude) preprocessor the compiler runs, so a
//! test of any `elab/` file starts from Verilog-AMS text. Test-only:
//! only `test` blocks reach it. LRM Annex E (the prelude).

const std = @import("std");
const elaborate = @import("elaborate.zig");
const Ast = @import("frontend").Ast;
const Lexer = @import("frontend").Lexer;
const Parser = @import("frontend").Parser;
const Preprocessor = @import("frontend").Preprocessor;
const diag = @import("diag");

/// One compilation for a test: the arena every parse and elaboration row
/// lives in, the file elaboration writes and its diagnostics. Free with
/// `deinit`.
pub const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    /// The overlay of the parse (`Ast.SourceFile.overlay`), as the spine
    /// makes it; the parse itself lives in `arena`.
    file: Ast.SourceFile = .empty,
    bag: diag.Bag = undefined,
    src: []const u8 = "",
    starts: []const u32 = &.{},

    /// Frees the parse, every elaboration of it and the bag.
    pub fn deinit(self: *Fixture) void {
        self.arena.deinit();
    }

    /// Returns the `Ctx` that elaborates this fixture: basic discipline
    /// resolution, no `--param` overrides. Its bag is undefined until a
    /// `parse*` has run.
    pub fn ctx(self: *Fixture) elaborate.Ctx {
        return .{
            .arena = self.arena.allocator(),
            .file = &self.file,
            .src = self.src,
            .tok_starts = self.starts,
            .bag = &self.bag,
        };
    }
};

/// Parses `text` into `out` with no prelude, so only the disciplines and
/// modules `text` declares exist. `text` must outlive `out`.
pub fn parse(out: *Fixture, text: []const u8) !void {
    const arena = out.arena.allocator();
    out.src = text;
    out.bag = diag.Bag.init(arena);
    var toks = try Lexer.Lexer.tokenize(arena, text);
    out.starts = toks.items(.start);
    var p = Parser.Parser.init(arena, text, toks.items(.tag), out.starts, &out.bag);
    const parsed = try arena.create(Ast.SourceFile);
    parsed.* = try p.parseSourceFile();
    out.file = parsed.overlay(.{});
}

/// Annex E: the prelude is a prefix of `modules` only if the preprocessor ran,
/// so this goes through it and sets `builtin_modules` as `root.zig` stage 3
/// does. `text` must outlive `out`.
pub fn parseWithPrelude(out: *Fixture, text: []const u8) !void {
    const arena = out.arena.allocator();
    out.bag = diag.Bag.init(arena);
    out.src = (try Preprocessor.process(arena, text, .{ .bag = &out.bag })).text;
    var toks = try Lexer.Lexer.tokenize(arena, out.src);
    out.starts = toks.items(.start);
    var p = Parser.Parser.init(arena, out.src, toks.items(.tag), out.starts, &out.bag);
    const parsed = try arena.create(Ast.SourceFile);
    parsed.* = try p.parseSourceFile();
    out.file = parsed.overlay(.{ .builtin_modules = Preprocessor.spice_module_count });
}

/// Returns a `Flatten` over `f`'s file before any walk: no table seeded, no
/// unit entered, and an empty generate-instance list for every module, so a
/// transform can be called on its own. Rows live in `f`'s arena.
pub fn flatten(f: *Fixture) !elaborate.Flatten {
    const gen = try f.arena.allocator().alloc([]const Ast.Instance, f.file.modules.len);
    for (gen) |*g| g.* = &.{};
    return .{ .ctx = f.ctx(), .gen_instances = gen };
}

/// Returns whether `bag` holds a diagnostic with `code`, wherever it sorts,
/// so a test does not depend on a warning the parser reported first.
pub fn hasCode(bag: *const diag.Bag, code: diag.Code) bool {
    for (0..bag.count()) |i| if (bag.at(i).code == code) return true;
    return false;
}

/// Returns the module `name` of `file` (the first so named), or null.
pub fn moduleNamed(file: *const Ast.SourceFile, name: []const u8) ?*const Ast.ModuleDecl {
    for (file.modules) |*m| if (std.mem.eql(u8, file.str(m.name), name)) return m;
    return null;
}

/// Returns the flat parameter `name` of the elaborated `top`, or null.
pub fn paramNamed(file: *const Ast.SourceFile, top: *const Ast.ModuleDecl, name: []const u8) ?Ast.ParamDecl {
    for (top.params) |p| if (std.mem.eql(u8, file.str(p.name), name)) return p;
    return null;
}

/// Returns the flat net `name` of the elaborated `top`, or null.
pub fn netNamed(file: *const Ast.SourceFile, top: *const Ast.ModuleDecl, name: []const u8) ?Ast.NetDecl {
    for (top.nets) |n| if (std.mem.eql(u8, file.str(n.name), name)) return n;
    return null;
}

/// Returns the interned id of `s`, which a parsed source must already hold.
pub fn id(file: *const Ast.SourceFile, s: []const u8) ?Ast.StrId {
    return file.strings.find(s);
}
