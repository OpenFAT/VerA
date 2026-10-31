//! IEEE 1364-2005 §13 binding: an instance (or the design's top) -> the
//! `file.modules` row it is bound to, through the library each source file
//! maps into (§13.2.3), the search order (§13.5.1, §13.7.1) and the rules of
//! the configuration in force (§13.3).
//!
//! IEEE 1364-2005 clauses cited: §13.2.1.1, §13.2.3, §13.3.1.1 to §13.3.1.6,
//! §13.3.2, §13.4.4, §13.5.1.
//!
//! Contents:
//! - `pub const Ctx = struct`
//! - `pub fn libraries(r: *Run, file: *Ast.SourceFile, opts: root.Options, more_starts: []const u32) Error!void`
//! - `pub fn top(r: *Run) Error!?[]const u32`
//! - `pub fn rootCtx(r: *const Run, ci: u32, def: u32) Ctx`
//! - `pub fn child(r: *Run, parent: u32, inst: *const Ast.Instance) Error!struct { def: u32, ctx: Ctx }`

const std = @import("std");
const Front = @import("frontend");
const Ast = Front.Ast;
const root = @import("root.zig");
const Run = root.Run;
const Error = root.Error;
const expectRun = root.expectRun;
const expectRejected = root.expectRejected;

/// What an instance scope's children bind under.
pub const Ctx = struct {
    /// The `file.configs` row whose rules apply; null binds by search order.
    cfg: ?u32 = null,
    /// The scope's §13.3.1.3 `inst_name`, from its config's top cell.
    path: []const u8 = "",
    /// §13.3.1.5 the library list inherited downward; null or empty is the
    /// parent cell's library.
    liblist: ?[]const Ast.StrId = null,
};

/// The libraries of `file`'s modules and configs: each is its source file's
/// (`opts.lib`, then `opts.more[k].lib` from `more_starts[k]` on). Also the
/// search order, and W1152 for each cell a later same-named one replaces.
/// Sets `r.def_lib`, `r.cfg_lib` and `r.search`, all in `r.arena`; must run
/// before `top` or `child`.
pub fn libraries(r: *Run, file: *Ast.SourceFile, opts: root.Options, more_starts: []const u32) Error!void {
    const arena = r.arena;
    const libs = try arena.alloc(Ast.StrId, 1 + opts.more.len);
    libs[0] = try file.intern(arena, opts.lib);
    for (opts.more, libs[1..]) |u, *l| l.* = try file.intern(arena, u.lib);
    const def_lib = try arena.alloc(Ast.StrId, file.modules.len);
    for (file.modules, def_lib) |m, *l| l.* = libs[unitOf(r, more_starts, m.main_tok)];
    const cfg_lib = try arena.alloc(Ast.StrId, file.configs.len);
    for (file.configs, cfg_lib) |c, *l| l.* = libs[unitOf(r, more_starts, c.main_tok)];
    var order: std.ArrayList(Ast.StrId) = try .initCapacity(arena, if (opts.search.len != 0) opts.search.len else libs.len);
    if (opts.search.len != 0) {
        for (opts.search) |s| order.appendAssumeCapacity(try file.intern(arena, s));
    } else for (libs) |l| if (std.mem.findScalar(Ast.StrId, order.items, l) == null) order.appendAssumeCapacity(l);
    r.def_lib = def_lib;
    r.cfg_lib = cfg_lib;
    r.search = order.items;
    // §13.2.1.1: "In the case where multiple modules with the same name are
    // mapped to the same library in a single invocation of the compiler,
    // then a warning message shall be issued."
    for (file.modules, 0..) |m, i| for (file.modules[i + 1 ..], def_lib[i + 1 ..]) |later, l| {
        if (later.name != m.name or l != def_lib[i]) continue;
        const at = r.starts[later.main_tok];
        try r.bag.add(.lower, .W1152, .{ .start = at, .end = at }, "`{s}.{s}` is defined again; this later definition is the cell", .{ file.str(l), file.str(m.name) });
        break;
    };
}

/// The design's tops: the `design` cells of the configuration no `use`
/// clause names (§13.4.4: "the specified cell shall be the top-level module,
/// regardless of the presence of any uninstantiated cells"), or null when the
/// source holds no configuration. Records scope 0's `Ctx`.
pub fn top(r: *Run) Error!?[]const u32 {
    const configs = r.file.configs;
    var root_cfg: ?u32 = null;
    for (configs, 0..) |c, i| {
        if (referenced(r, @intCast(i))) continue;
        if (root_cfg != null) return r.failWith(.E0243, c.main_tok, "configurations `{s}` and `{s}` are both unreferenced, so neither is the design's (IEEE 1364-2005 §13.4.4)", .{ r.file.str(configs[root_cfg.?].name), r.file.str(c.name) });
        root_cfg = @intCast(i);
    }
    const ci = root_cfg orelse {
        if (configs.len != 0) return r.failWith(.E0243, configs[0].main_tok, "every configuration is named by another's `use` clause, so none is the design's (IEEE 1364-2005 §13.4.4)", .{});
        return null;
    };
    const c = configs[ci];
    const defs = try r.arena.alloc(u32, c.design.len);
    for (c.design, defs) |cell, *d| d.* = try designCell(r, ci, cell);
    try r.binds.put(r.arena, 0, rootCtx(r, ci, defs[0]));
    return defs;
}

/// The `Ctx` of config `ci`'s top-level module `def`: §13.3.1.3's instance
/// names start at "the name of the cell in the design statement".
pub fn rootCtx(r: *const Run, ci: u32, def: u32) Ctx {
    return .{ .cfg = ci, .path = r.file.str(r.file.modules[def].name), .liblist = defaultList(r.file.configs[ci]) };
}

/// §13.3 the module `inst`, declared in instance scope `parent`, binds to,
/// and the `Ctx` its own children bind under. Fails, with the library list
/// it searched named, when no library holds the cell; E0243 for an instance
/// clause reaching inside another config's hierarchy (§13.3.2).
pub fn child(r: *Run, parent: u32, inst: *const Ast.Instance) Error!struct { def: u32, ctx: Ctx } {
    const up = r.binds.get(r.instanceOf(parent)) orelse Ctx{};
    const ci = up.cfg orelse return .{ .def = try search(r, r.search, inst.module, inst.main_tok), .ctx = .{} };
    const cfg = r.file.configs[ci];
    const parent_lib = r.def_lib[r.scope_info.items[parent].def];
    // ponytail: a generate block between the parent instance and `inst` is
    // not spelled into the path, so an instance clause cannot reach inside one.
    const path = try r.arena.print("{s}.{s}", .{ up.path, r.file.str(inst.name) });
    // §13.3.1.2: "The default clause selects all instances that do not match
    // a more specific selection clause"; an instance clause names one
    // instance, a cell clause every instance of a cell.
    const rule: ?Ast.ConfigRule = for (cfg.rules) |x| {
        if (x.select == .instance and r.file.strings.eql(x.select.instance, path)) break x;
    } else for (cfg.rules) |x| {
        if (x.select != .cell or x.select.cell.cell != inst.module) continue;
        // §13.3.1.4 "If the optional library name is specified, then the
        // selection rule applies to any instance that is bound or is under
        // consideration for being bound to the selected library and cell."
        if (x.select.cell.lib != .none) {
            const d = lookup(r, try listOr(r, up.liblist, parent_lib), inst.module) orelse continue;
            if (r.def_lib[d] != x.select.cell.lib) continue;
        }
        break x;
    } else null;
    const x = rule orelse return .{
        .def = try search(r, try listOr(r, up.liblist, parent_lib), inst.module, inst.main_tok),
        .ctx = .{ .cfg = ci, .path = path, .liblist = up.liblist },
    };
    switch (x.expand) {
        .liblist => |l| return .{
            .def = try search(r, try listOr(r, l, parent_lib), inst.module, inst.main_tok),
            .ctx = .{ .cfg = ci, .path = path, .liblist = l },
        },
        .use => |u| {
            // §13.3.1.6 "If the library name is omitted, the library shall be
            // inherited from the parent cell."
            const lib = if (u.lib != .none) u.lib else parent_lib;
            if (u.config or find(r, lib, u.cell) == null) if (subConfig(r, lib, u.cell)) |sub| {
                // §13.3.2 "It shall be an error for an instance clause to
                // specify a hierarchical path to an instance that occurs
                // within a hierarchy specified by another config."
                for (cfg.rules) |o| if (o.select == .instance) {
                    const p = r.file.str(o.select.instance);
                    if (p.len > path.len and std.mem.startsWith(u8, p, path) and p[path.len] == '.')
                        return r.failWith(.E0243, o.main_tok, "instance clause `{s}` names an instance inside `{s}`, whose hierarchy another config (`{s}`) specifies (IEEE 1364-2005 §13.3.2)", .{ p, path, r.file.str(u.cell) });
                };
                const s = r.file.configs[sub];
                if (s.design.len != 1) return r.fail(s.main_tok, "a configuration bound to an instance names one design cell (IEEE 1364-2005 §13.3.2)", .{});
                const d = try designCell(r, sub, s.design[0]);
                return .{ .def = d, .ctx = rootCtx(r, sub, d) };
            };
            if (u.config) return r.fail(x.main_tok, "library `{s}` holds no configuration `{s}`", .{ r.file.str(lib), r.file.str(u.cell) });
            // §13.3.1.6 "The use clause has no effect on the current value of
            // the library list."
            return .{ .def = try module(r, lib, u.cell, x.main_tok), .ctx = .{ .cfg = ci, .path = path, .liblist = up.liblist } };
        },
    }
}

// ---- private ----

fn unitOf(r: *const Run, more_starts: []const u32, tok: u32) usize {
    const at = r.starts[tok];
    var k: usize = 0;
    while (k < more_starts.len and more_starts[k] <= at) k += 1;
    return k;
}

/// §13.2.1.1 "the LAST cell encountered shall be written to the library":
/// the last module named `cell` in `lib`.
fn find(r: *const Run, lib: Ast.StrId, cell: Ast.StrId) ?u32 {
    var i = r.file.modules.len;
    while (i > 0) {
        i -= 1;
        if (r.file.modules[i].name == cell and r.def_lib[i] == lib) return @intCast(i);
    }
    return null;
}

/// §13.3.1.5 "the specified library list is searched in the specified order".
fn lookup(r: *const Run, list: []const Ast.StrId, cell: Ast.StrId) ?u32 {
    for (list) |lib| if (find(r, lib, cell)) |d| return d;
    return null;
}

fn search(r: *Run, list: []const Ast.StrId, cell: Ast.StrId, tok: u32) Error!u32 {
    if (lookup(r, list, cell)) |d| return d;
    var names: std.ArrayList(u8) = .empty;
    for (list, 0..) |lib, k| {
        if (k != 0) try names.append(r.arena, ' ');
        try names.appendSlice(r.arena, r.file.str(lib));
    }
    return r.fail(tok, "undeclared module in instantiation: no library of the search order ({s}) holds cell `{s}`", .{ names.items, r.file.str(cell) });
}

fn module(r: *Run, lib: Ast.StrId, cell: Ast.StrId, tok: u32) Error!u32 {
    return find(r, lib, cell) orelse r.fail(tok, "undeclared module in instantiation: library `{s}` holds no cell `{s}`", .{ r.file.str(lib), r.file.str(cell) });
}

/// §13.3.1.5 "If no library list clause is selected or if the selected
/// library list is empty, then the library list contains the single name
/// that is the library in which the cell containing the unbound instance is
/// found (i.e., the parent cell's library)."
fn listOr(r: *Run, list: ?[]const Ast.StrId, parent_lib: Ast.StrId) Error![]const Ast.StrId {
    if (list) |l| if (l.len != 0) return l;
    return r.arena.dupe(Ast.StrId, &.{parent_lib});
}

/// §13.3.1.1 a config's design cell: "If the library identifier is omitted,
/// then the library that contains the config shall be used".
fn designCell(r: *Run, ci: u32, d: Ast.LibCell) Error!u32 {
    return module(r, if (d.lib != .none) d.lib else r.cfg_lib[ci], d.cell, r.file.configs[ci].main_tok);
}

fn defaultList(c: Ast.ConfigDecl) ?[]const Ast.StrId {
    for (c.rules) |rule| if (rule.select == .default) return rule.expand.liblist;
    return null;
}

/// Is config `ci` the target of some `use` clause? `:config` says so; so
/// does a use naming a cell that no module has.
fn referenced(r: *const Run, ci: u32) bool {
    const name = r.file.configs[ci].name;
    for (r.file.configs) |c| for (c.rules) |rule| switch (rule.expand) {
        .use => |u| if (u.cell == name and (u.config or !isModule(r, name))) return true,
        .liblist => {},
    };
    return false;
}

fn isModule(r: *const Run, name: Ast.StrId) bool {
    for (r.file.modules) |m| if (m.name == name) return true;
    return false;
}

fn subConfig(r: *const Run, lib: Ast.StrId, name: Ast.StrId) ?u32 {
    for (r.file.configs, r.cfg_lib, 0..) |c, l, i| if (c.name == name and l == lib) return @intCast(i);
    return null;
}

test "§13.3.1.3/§13.3.1.4 an instance clause and a cell clause bind the cell their use names" {
    // top.u is named by the instance clause; top.w falls to the default, the
    // parent cell's library work, where leaf is leaf.
    try expectRun(
        \\config cfg; design top; instance top.u use other; endconfig
        \\module leaf; initial $display("leaf %m"); endmodule
        \\module other; initial $display("other %m"); endmodule
        \\module top; leaf u(); leaf w(); endmodule
    , "other top.u\nleaf top.w\n");
    // A cell clause selects every instance of the cell.
    try expectRun(
        \\config cfg; design top; cell leaf use other; endconfig
        \\module leaf; initial $display("leaf %m"); endmodule
        \\module other; initial $display("other %m"); endmodule
        \\module top; leaf u(); leaf w(); endmodule
    , "other top.u\nother top.w\n");
}

test "§13.2.1.1 the last same-named cell of a library is the one bound" {
    try expectRun(
        \\module leaf; initial $display("first"); endmodule
        \\module leaf; initial $display("second"); endmodule
        \\module top; leaf u(); endmodule
    , "second\n");
}

test "§13.4.4 a design names an existing cell, and one configuration is unreferenced" {
    try expectRejected("config cfg; design nope; endconfig module top; endmodule", "holds no cell `nope`");
    try expectRejected("config a; design top; endconfig config b; design top; endconfig module top; endmodule", "are both unreferenced");
    try expectRejected("module top; nope u(); endmodule", "no library of the search order (work) holds cell `nope`");
}
