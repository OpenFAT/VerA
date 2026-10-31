//! E.2.1 from the netlist's side: the netlist-derived modules' instances →
//! the same instances with module and parameter names respelled to the
//! Verilog-AMS declarations they match regardless of case.
//! Cites: LRM E.2.1, §9.18.
//!
//! Contents:
//! - `pub fn spiceCase(arena: std.mem.Allocator, file: *Ast.SourceFile) std.mem.Allocator.Error!void`

const std = @import("std");
const Ast = @import("frontend").Ast;

/// E.2.1 from the netlist's side. SPICE is case-insensitive and the netlist
/// is lower-cased at ingest (`spice_cards`), so a module, paramset or
/// parameter name a card writes (`.model nch bsim4`, `M1 ... nch W=1u`)
/// matches the Verilog-AMS declaration regardless of case when nothing
/// matches exactly: `module BSIM4` and its `W`. Rewrites the instances of
/// the netlist-derived modules to the declared spellings before elaboration
/// reads any of them (§6.2.2's top selection included). An exact match is
/// never moved, and a name two declarations fold to stays as written for
/// `findModule` and E0904/E0907 to judge.
pub fn spiceCase(arena: std.mem.Allocator, file: *Ast.SourceFile) std.mem.Allocator.Error!void {
    const end = @min(file.builtin_modules, file.modules.len);
    const start = end - @min(file.netlist_modules, end);
    var mods: ?[]Ast.ModuleDecl = null;
    for (start..end) |mi| {
        const insts = file.modules[mi].instances;
        var fixed: ?[]Ast.Instance = null;
        for (insts, 0..) |inst, ii| {
            const to = try caseInstance(arena, file, inst) orelse continue;
            if (fixed == null) fixed = try arena.dupe(Ast.Instance, insts);
            fixed.?[ii] = to;
        }
        const list = fixed orelse continue;
        if (mods == null) mods = try arena.dupe(Ast.ModuleDecl, file.modules);
        mods.?[mi].instances = list;
    }
    if (mods) |list| file.modules = list;
}

// ---- private ----

/// `inst` with its module and parameter names respelled as `spiceCase`
/// says, or null when nothing moves.
fn caseInstance(arena: std.mem.Allocator, file: *const Ast.SourceFile, inst: Ast.Instance) std.mem.Allocator.Error!?Ast.Instance {
    var out = inst;
    const Decl = struct { name: Ast.StrId, params: []const Ast.ParamDecl, aliases: []const Ast.AliasParam };
    var exact: ?Decl = null;
    var folded: ?Decl = null;
    var folds: usize = 0;
    const want = file.str(inst.module);
    for (file.modules) |m| {
        const d: Decl = .{ .name = m.name, .params = m.params, .aliases = m.aliasparams };
        if (m.name == inst.module) exact = exact orelse d else if (std.ascii.eqlIgnoreCase(file.str(m.name), want)) {
            if (folded == null or folded.?.name != m.name) folds += 1;
            folded = d;
        }
    }
    for (file.paramsets) |ps| {
        const d: Decl = .{ .name = ps.name, .params = ps.params, .aliases = ps.aliasparams };
        if (ps.name == inst.module) exact = exact orelse d else if (std.ascii.eqlIgnoreCase(file.str(ps.name), want)) {
            if (folded == null or folded.?.name != ps.name) folds += 1;
            folded = d;
        }
    }
    const d = exact orelse if (folds == 1) folded.? else return null;
    out.module = d.name;

    var params: ?[]Ast.ParamOverride = null;
    for (inst.params, 0..) |o, k| {
        if (o.name == .none) continue;
        const name = file.str(o.name);
        // §9.18 hierarchical system parameters are not the module's.
        if (name.len == 0 or name[0] == '$') continue;
        var to: ?Ast.StrId = null;
        var n: usize = 0;
        for (d.params) |p| {
            if (p.name == o.name) break;
            if (std.ascii.eqlIgnoreCase(file.str(p.name), name)) {
                to = p.name;
                n += 1;
            }
        } else for (d.aliases) |al| {
            if (al.alias == o.name) break;
            if (std.ascii.eqlIgnoreCase(file.str(al.alias), name)) {
                to = al.alias;
                n += 1;
            }
        } else if (n == 1) {
            if (params == null) params = try arena.dupe(Ast.ParamOverride, inst.params);
            params.?[k].name = to.?;
        }
    }
    if (params) |p| out.params = p;
    if (out.module == inst.module and params == null) return null;
    return out;
}
